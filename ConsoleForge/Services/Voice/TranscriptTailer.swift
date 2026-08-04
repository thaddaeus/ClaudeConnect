import Foundation

/// Follows one tab's Claude transcript and reports each new assistant message once.
///
/// This is the speech-out source. It reads the transcript rather than the terminal
/// deliberately: the JSONL carries Claude's prose already separated from ANSI escapes,
/// the spinner, the status line, and the redrawn TUI — none of which can be spoken.
///
/// Only one tab is followed at a time (`retarget`), because only the active tab is
/// audible. Retargeting to a file mid-turn starts from the file's **end**, not its
/// beginning: switching tabs should pick up what is said from now on, never replay the
/// backlog.
@MainActor
final class TranscriptTailer {

    /// Called on the main actor with each newly-appended assistant message, in order.
    var onMessage: ((ClaudeTranscript.AssistantMessage) -> Void)?

    /// The tab currently being followed, if any.
    private(set) var targetTabID: UUID?

    private var url: URL?
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    /// Byte offset already consumed — everything before this has been reported.
    private var offset: UInt64 = 0
    /// Record uuids already reported. A file-system event can fire more than once for
    /// one append, and a rotated/truncated file is re-read from 0; neither should speak
    /// the same sentence twice.
    private var seenRecordIDs: Set<String> = []
    /// Retry timer for the window between a tab launching and Claude creating its
    /// transcript (the file does not exist until the first turn).
    private var waitForFileTask: Task<Void, Never>?

    // MARK: - Targeting

    /// Follow a different tab's transcript. Passing `nil` stops following anything.
    ///
    /// `workingDirectory` and `claudeSessionID` come from the tab's
    /// `SessionConfiguration`; the pinned id is what makes two tabs in the same
    /// directory resolvable to different files.
    func retarget(tabID: UUID?, workingDirectory: String?, claudeSessionID: UUID?) {
        guard tabID != targetTabID else { return }
        stop()
        targetTabID = tabID

        guard let tabID, let workingDirectory, !workingDirectory.isEmpty else { return }
        attach(workingDirectory: workingDirectory, claudeSessionID: claudeSessionID, tabID: tabID)
    }

    func stop() {
        waitForFileTask?.cancel()
        waitForFileTask = nil
        source?.cancel()
        source = nil
        url = nil
        offset = 0
        seenRecordIDs.removeAll()
        targetTabID = nil
    }

    // MARK: - Attach

    private func attach(workingDirectory: String, claudeSessionID: UUID?, tabID: UUID) {
        guard let found = ClaudeTranscript.url(workingDirectory: workingDirectory,
                                               claudeSessionID: claudeSessionID) else {
            // A tab that has not taken its first turn yet has no transcript. Poll for it
            // rather than going permanently silent.
            scheduleWaitForFile(workingDirectory: workingDirectory,
                                claudeSessionID: claudeSessionID, tabID: tabID)
            return
        }

        let fd = open(found.path, O_EVTONLY)
        guard fd >= 0 else {
            scheduleWaitForFile(workingDirectory: workingDirectory,
                                claudeSessionID: claudeSessionID, tabID: tabID)
            return
        }

        url = found
        fileDescriptor = fd
        // Start at the end — see the type comment on replaying backlog.
        offset = (try? FileHandle(forReadingFrom: found).seekToEnd()) ?? 0

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let mask = src.data
            if mask.contains(.delete) || mask.contains(.rename) {
                // Claude rotated or replaced the file — re-resolve from scratch.
                self.stopKeepingTarget()
                self.attach(workingDirectory: workingDirectory,
                            claudeSessionID: claudeSessionID, tabID: tabID)
                return
            }
            self.readAppended()
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
                self?.fileDescriptor = -1
            }
        }
        source = src
        src.resume()
    }

    /// Tear down the watch but keep `targetTabID`, so a rotation can re-attach to the
    /// same tab without `retarget`'s same-tab early return swallowing it.
    private func stopKeepingTarget() {
        waitForFileTask?.cancel()
        waitForFileTask = nil
        source?.cancel()
        source = nil
        url = nil
        offset = 0
        // seenRecordIDs is intentionally kept: a rotated file can repeat records.
    }

    private func scheduleWaitForFile(workingDirectory: String, claudeSessionID: UUID?, tabID: UUID) {
        waitForFileTask?.cancel()
        waitForFileTask = Task { [weak self] in
            // Runs until the transcript appears or this tab stops being the target.
            //
            // Deliberately unbounded: a tab can sit open for an hour before its first
            // prompt, and a deadline here means "opened a tab, came back later, started
            // working, never heard a word" — silently, with the panel still reporting
            // that voice is on. The loop costs one `stat` per interval and is cancelled
            // by `stop()`/`retarget`, so outliving the tab is not a risk.
            var interval: Duration = .seconds(1)
            while true {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.targetTabID == tabID else { return }
                if ClaudeTranscript.url(workingDirectory: workingDirectory,
                                        claudeSessionID: claudeSessionID) != nil {
                    self.waitForFileTask = nil
                    self.attach(workingDirectory: workingDirectory,
                                claudeSessionID: claudeSessionID, tabID: tabID)
                    return
                }
                // Back off once the first-turn window has clearly passed, so a tab left
                // open all day isn't polling every second.
                if interval < .seconds(5) { interval = .seconds(5) }
            }
        }
    }

    // MARK: - Read

    /// Read everything appended since the last read and report any assistant messages.
    private func readAppended() {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset {
            // Truncated — treat as a fresh file. `seenRecordIDs` prevents a re-speak.
            offset = 0
        }
        guard size > offset else { return }

        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }

        let text = String(decoding: data, as: UTF8.self)
        // A final line with no trailing newline is a partial append — leave it in the
        // file for the next event rather than parsing half a record.
        let endsClean = text.hasSuffix("\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var consumed = data.count
        if !endsClean, let partial = lines.popLast() {
            consumed -= partial.utf8.count
        }
        offset += UInt64(consumed)

        for line in lines where !line.isEmpty {
            guard let obj = ClaudeTranscript.decodeLines(line).first,
                  let message = ClaudeTranscript.assistantMessage(fromLine: obj) else { continue }
            guard seenRecordIDs.insert(message.recordID).inserted else { continue }
            onMessage?(message)
        }
        // The dedupe set is never pruned: a uuid is ~36 bytes, a long session holds a
        // few thousand, and dropping one risks re-speaking a paragraph after a
        // truncation — the one failure this set exists to prevent.
    }
}
