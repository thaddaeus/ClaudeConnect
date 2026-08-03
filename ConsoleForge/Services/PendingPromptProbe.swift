import Foundation

/// Answers exactly one question about a Claude Code session: **is it blocked on the
/// user right now?**
///
/// Claude Code rings the terminal bell at the end of every turn, not only when it
/// needs something. The bell alone therefore can't distinguish "I finished, your
/// move" from "I am stuck waiting for you to approve this." This reads the session's
/// persisted JSONL transcript to tell them apart.
///
/// The signal is an unresolved `tool_use`: Claude writes the assistant message
/// containing a tool call to disk *before* the call resolves, and the matching
/// `tool_result` is only appended once the tool returns — which, for an
/// `AskUserQuestion` or a permission prompt, means once the user answers. A
/// `tool_use` with no `tool_result` is Claude unable to proceed.
///
/// A caller must only consult this **on a bell**. An unresolved `tool_use` is also
/// briefly true while an auto-approved tool is merely executing (a slow `Bash` or a
/// sub-agent can sit unresolved for a minute), so on its own it would read as
/// "needs input" during ordinary work. The bell is what narrows it to a turn
/// boundary; this narrows the bell to a real prompt.
///
/// A caller must also **not probe the instant the bell arrives**. Claude appends the
/// assistant record carrying the pending `tool_use` a beat after the tool begins —
/// measured at ~115ms — so an immediate read can miss a prompt that is already on
/// screen and wrongly report `false`. `TabActivityTracker` waits, and re-reads before
/// it acts on a `false`.
///
/// Reads the transcript file only — never scrapes the terminal, needs no hooks, and
/// nothing leaves the machine.
enum PendingPromptProbe {
    /// `true` = blocked on the user, `false` = not blocked, `nil` = couldn't tell
    /// (no transcript, unreadable, unparseable). Callers should treat `nil` as
    /// "assume it needs attention" rather than silently clearing the indicator.
    ///
    /// Pure file IO — call it off the main thread.
    static func isAwaitingUser(workingDirectory: String) -> Bool? {
        // Location logic is shared with TranscriptTailer — see ClaudeTranscript. This
        // caller has no pinned session id to hand it, so it keeps the historical
        // newest-transcript-in-the-project-directory behaviour.
        guard let url = ClaudeTranscript.url(workingDirectory: workingDirectory,
                                             claudeSessionID: nil) else { return nil }
        guard let lines = tailLines(of: url), !lines.isEmpty else { return nil }

        var pending = Set<String>()
        for line in lines {
            guard let message = line["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { continue }
            for b in blocks {
                switch b["type"] as? String {
                case "tool_use":
                    if let id = b["id"] as? String { pending.insert(id) }
                case "tool_result":
                    if let id = b["tool_use_id"] as? String { pending.remove(id) }
                default:
                    break
                }
            }
        }
        // Truncation can only drop the head of the file, and a `tool_result` always
        // follows its `tool_use` — so any id still in the set was genuinely never
        // resolved, not merely resolved off-window.
        return !pending.isEmpty
    }

    // MARK: - Read the tail

    /// Only the end of the file matters — a pending call lives at the tail, and
    /// transcripts grow without bound.
    private static let tailByteWindow = 512 * 1024

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
        return ClaudeTranscript.decodeLines(text)
    }
}
