import Foundation

/// Reads a Claude Code session's JSONL transcript and extracts structured content
/// for the companion: the last user prompt, the last assistant response, and any
/// blocking question/permission prompt (with its options).
///
/// This reads the persisted transcript file — it never scrapes the terminal/ANSI
/// stream and requires no hooks or change to how `claude` is launched. Claude Code
/// writes one `<session-id>.jsonl` per session under
/// `~/.claude/projects/<cwd-with-slashes-as-dashes>/`, updated live; the
/// most-recently-modified file in that directory is the active session.
///
/// Caveat (Phase 1): if two sessions share a working directory, "newest file" can
/// pick the wrong one. Acceptable for v1; refine later by matching the `cwd` field
/// or session start time.
enum TranscriptReader {
    struct Snapshot: Equatable, Sendable {
        var lastPrompt: String?
        var lastResponse: String?
        var question: CompanionQuestion?
    }

    // The phone shows a short smart-tail preview per card but expands to the full
    // last turn on tap, so we ship the whole turn (bounded for a sane payload) and
    // let the PWA derive the snippet. The response aggregates every text block of
    // the last assistant turn; a generous cap keeps the conclusion (the part that
    // matters) instead of the old head-truncation that dropped it.
    private static let maxPromptChars = 4000
    private static let maxResponseChars = 16000
    private static let maxTitleChars = 500
    private static let maxOptionChars = 160
    // Only parse the end of the file; pending prompts/recent turns live at the tail.
    private static let tailByteWindow = 512 * 1024

    /// Read the active transcript for `workingDirectory`. Returns nil if no
    /// transcript is found. Safe to call off the main thread (pure file IO).
    static func read(workingDirectory: String) -> Snapshot? {
        guard let url = newestTranscriptURL(workingDirectory: workingDirectory) else { return nil }
        guard let lines = tailLines(of: url) else { return nil }
        return parse(lines: lines)
    }

    // MARK: - Locate the transcript

    private static func newestTranscriptURL(workingDirectory: String) -> URL? {
        let cwd = (workingDirectory as NSString).expandingTildeInPath
        guard !cwd.isEmpty else { return nil }
        let projects = (("~/.claude/projects" as NSString).expandingTildeInPath) as String
        let projectsURL = URL(fileURLWithPath: projects, isDirectory: true)

        // Claude encodes the project dir name by replacing path separators with "-".
        // Primary candidate handles the common case; if it's missing (e.g. a path
        // containing "." which some Claude versions also encode), fall back to
        // scanning for the dir whose transcripts record this cwd.
        let primary = projectsURL.appendingPathComponent(cwd.replacingOccurrences(of: "/", with: "-"))
        let candidateDirs: [URL]
        if FileManager.default.fileExists(atPath: primary.path) {
            candidateDirs = [primary]
        } else {
            candidateDirs = projectDirsMatching(cwd: cwd, in: projectsURL)
        }

        var newest: (url: URL, date: Date)?
        for dir in candidateDirs {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files where f.pathExtension == "jsonl" {
                let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if newest == nil || date > newest!.date { newest = (f, date) }
            }
        }
        return newest?.url
    }

    /// Fallback: find project dirs whose newest transcript's first line records the
    /// target `cwd`. Bounded to keep it cheap.
    private static func projectDirsMatching(cwd: String, in projectsURL: URL) -> [URL] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: projectsURL, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { dir in
            guard let any = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "jsonl" }),
                  let head = try? String(contentsOf: any, encoding: .utf8).prefix(4096) else { return false }
            return head.contains("\"cwd\":\"\(cwd)\"")
        }
    }

    // MARK: - Read the tail

    private static func tailLines(of url: URL) -> [[String: Any]]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailByteWindow) ? size - UInt64(tailByteWindow) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        // Drop a leading partial line when we started mid-file.
        if start > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        return text.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return obj
        }
    }

    // MARK: - Parse

    private static func parse(lines: [[String: Any]]) -> Snapshot {
        // Index of the last real user prompt (a user message with text content, not
        // a tool_result carrier). Everything after it is the response to it.
        var lastPromptIdx: Int?
        var lastPrompt: String?
        for (i, line) in lines.enumerated() {
            guard (line["type"] as? String) == "user",
                  let message = line["message"] as? [String: Any] else { continue }
            if let text = userPromptText(from: message["content"]) {
                lastPromptIdx = i
                lastPrompt = text
            }
        }

        // Assistant text after the last prompt = the response. Track pending tool_use
        // (a tool call with no matching tool_result yet) = the blocking question.
        var responseParts: [String] = []
        var pendingTool: (id: String, name: String, input: [String: Any])?
        var resolvedToolIds = Set<String>()

        let startIdx = lastPromptIdx.map { $0 + 1 } ?? 0
        for line in lines[min(startIdx, lines.count)...] {
            guard let type = line["type"] as? String,
                  let message = line["message"] as? [String: Any] else { continue }
            let content = message["content"]
            if type == "assistant", let blocks = content as? [[String: Any]] {
                for b in blocks {
                    switch b["type"] as? String {
                    case "text":
                        if let t = (b["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                            responseParts.append(t)
                        }
                    case "tool_use":
                        if let id = b["id"] as? String, let name = b["name"] as? String {
                            pendingTool = (id, name, b["input"] as? [String: Any] ?? [:])
                        }
                    default: break
                    }
                }
            } else if type == "user", let blocks = content as? [[String: Any]] {
                for b in blocks where (b["type"] as? String) == "tool_result" {
                    if let id = b["tool_use_id"] as? String { resolvedToolIds.insert(id) }
                }
            }
        }

        var question: CompanionQuestion?
        if let pending = pendingTool, !resolvedToolIds.contains(pending.id) {
            question = makeQuestion(name: pending.name, input: pending.input)
        }

        return Snapshot(
            lastPrompt: lastPrompt.map { truncate($0, maxPromptChars) },
            lastResponse: responseParts.isEmpty ? nil : truncate(responseParts.joined(separator: "\n\n"), maxResponseChars),
            question: question
        )
    }

    /// A user prompt is plain string content, or an array containing a text block.
    /// Pure tool_result arrays (tool returns) are not prompts.
    private static func userPromptText(from content: Any?) -> String? {
        if let s = content as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { b -> String? in
                (b["type"] as? String) == "text" ? (b["text"] as? String) : nil
            }
            let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func makeQuestion(name: String, input: [String: Any]) -> CompanionQuestion {
        if name == "AskUserQuestion", let questions = input["questions"] as? [[String: Any]],
           let first = questions.first {
            let title = (first["question"] as? String) ?? "Question"
            let options = (first["options"] as? [[String: Any]])?.compactMap { $0["label"] as? String } ?? []
            return CompanionQuestion(
                kind: "question",
                title: truncate(title, maxTitleChars),
                options: options.map { truncate($0, maxOptionChars) })
        }
        // Pending tool approval — Claude's permission prompt has a fixed option set.
        return CompanionQuestion(
            kind: "permission",
            title: truncate(permissionTitle(name: name, input: input), maxTitleChars),
            options: ["Yes", "Yes, and don't ask again", "No"])
    }

    private static func permissionTitle(name: String, input: [String: Any]) -> String {
        switch name {
        case "Bash":
            let cmd = (input["command"] as? String) ?? ""
            return "Run command: \(cmd)"
        case "Edit", "Write", "NotebookEdit":
            let path = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent } ?? "a file"
            return "\(name) \(path)?"
        case "Read":
            let path = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent } ?? "a file"
            return "Read \(path)?"
        default:
            return "Allow \(name)?"
        }
    }

    private static func truncate(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
    }
}
