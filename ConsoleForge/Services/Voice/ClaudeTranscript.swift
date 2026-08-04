import Foundation

/// Locates the JSONL transcript Claude Code writes for a session, and decodes the
/// records that matter to us.
///
/// Claude Code writes one `<session-id>.jsonl` per session under
/// `~/.claude/projects/<cwd-with-slashes-as-dashes>/`, appended live as the turn
/// progresses. Two readers need that file — `PendingPromptProbe` (is this session
/// blocked?) and `TranscriptTailer` (what did it just say?) — so the location logic
/// lives here rather than in either of them.
///
/// Resolution prefers the tab's **pinned** session id: `ClaudeProcessBuilder` launches
/// every fresh tab with `--session-id <uuid>`, so the filename is known exactly and two
/// tabs sharing a working directory are never confused for one another. Only when that
/// file is absent — a `--continue` tab, which owns no pinned id, or a version of Claude
/// that named the file differently — does it fall back to "newest transcript in the
/// project directory."
enum ClaudeTranscript {

    // MARK: - Locate

    /// The transcript for a tab, preferring its pinned Claude session id.
    ///
    /// - Parameters:
    ///   - workingDirectory: the tab's cwd (tilde allowed).
    ///   - claudeSessionID: the id pinned via `--session-id`, when the tab owns one.
    static func url(workingDirectory: String, claudeSessionID: UUID?) -> URL? {
        let dirs = projectDirectories(workingDirectory: workingDirectory)
        guard !dirs.isEmpty else { return nil }

        // Exact match on the pinned id — unambiguous even with several tabs in one cwd.
        if let sessionID = claudeSessionID {
            for dir in dirs {
                let exact = dir.appendingPathComponent("\(sessionID.uuidString.lowercased()).jsonl")
                if FileManager.default.fileExists(atPath: exact.path) { return exact }
                // Claude has written the id in both cases across versions; check as-is too.
                let asIs = dir.appendingPathComponent("\(sessionID.uuidString).jsonl")
                if FileManager.default.fileExists(atPath: asIs.path) { return asIs }
            }
            // A pinned tab's transcript is that file or nothing. Falling through to
            // "newest in the directory" here is actively harmful: a tab that has not
            // taken its first turn has no file yet, so the fallback hands back some
            // OTHER session's transcript — usually a dead one — and the caller attaches
            // to it, seeks to its end, and waits forever for appends that never come.
            // Returning nil lets the tailer keep waiting for the real file to appear.
            return nil
        }

        // No pinned id (a `--continue` tab): "newest" is the only signal available.
        return newestTranscript(in: dirs)
    }

    /// Newest `.jsonl` across the candidate project directories.
    ///
    /// Caveat: with no pinned id, two sessions sharing a working directory make "newest"
    /// ambiguous. That misreads *which* session, never *whether* one.
    static func newestTranscript(in dirs: [URL]) -> URL? {
        var newest: (url: URL, date: Date)?
        for dir in dirs {
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

    /// Candidate project directories for a working directory: the encoded-name primary
    /// if it exists, otherwise any directory whose transcripts record this cwd.
    static func projectDirectories(workingDirectory: String) -> [URL] {
        let cwd = (workingDirectory as NSString).expandingTildeInPath
        guard !cwd.isEmpty else { return [] }
        let projects = ("~/.claude/projects" as NSString).expandingTildeInPath
        let projectsURL = URL(fileURLWithPath: projects, isDirectory: true)

        // Claude encodes the project dir name by replacing path separators with "-".
        let primary = projectsURL.appendingPathComponent(cwd.replacingOccurrences(of: "/", with: "-"))
        if FileManager.default.fileExists(atPath: primary.path) {
            return [primary]
        }
        // Fallback for paths some Claude versions encode differently (e.g. containing ".").
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: projectsURL, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { dir in
            guard let any = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "jsonl" }),
                  let head = try? String(contentsOf: any, encoding: .utf8).prefix(4096) else { return false }
            return head.contains("\"cwd\":\"\(cwd)\"")
        }
    }

    // MARK: - Decode

    /// One assistant text block, tagged with the record it came from so a re-read of the
    /// same bytes can be discarded rather than spoken twice.
    struct AssistantMessage {
        /// The transcript record's `uuid` — stable across re-reads, unique per record.
        let recordID: String
        /// The concatenated `text` blocks of that record, in order.
        let text: String
    }

    /// Parse one JSONL line into an assistant message, or nil if it isn't one.
    ///
    /// Only `content[].type == "text"` is taken. Thinking blocks are deliberately
    /// excluded (they are Claude's reasoning, not its reply), as are `tool_use` inputs —
    /// which are file contents, diffs, and command lines, and unlistenable.
    static func assistantMessage(fromLine line: [String: Any]) -> AssistantMessage? {
        guard line["type"] as? String == "assistant",
              let recordID = line["uuid"] as? String,
              let message = line["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return nil }

        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return nil }
        return AssistantMessage(recordID: recordID, text: text)
    }

    /// Decode newline-delimited JSON into dictionaries, skipping unparseable lines.
    static func decodeLines(_ text: String) -> [[String: Any]] {
        text.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return obj
        }
    }
}
