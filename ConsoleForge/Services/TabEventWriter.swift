import Foundation

/// Writes tab lifecycle events as JSON files so external tools (e.g. consoleforge-tab --wait-for-close)
/// can observe when tabs close and why.
enum TabEventWriter {
    /// Why the tab was closed.
    enum CloseReason: String, Codable {
        /// Tab closed itself via `consoleforge-tab --close-self`
        case selfClose = "self-close"
        /// User closed the tab manually (click X, Cmd+W, context menu)
        case manual = "manual"
        /// The process inside the tab exited on its own
        case processExit = "process-exit"
    }

    struct TabCloseEvent: Codable {
        let tabID: String
        let tabName: String
        let reason: String
        let exitCode: Int32?
        let timestamp: String
    }

    static var eventsDirectory: URL {
        AppChannel.supportDirectory("events")
    }

    static func emitClose(tabID: UUID, tabName: String, reason: CloseReason, exitCode: Int32? = nil) {
        let formatter = ISO8601DateFormatter()
        let event = TabCloseEvent(
            tabID: tabID.uuidString,
            tabName: tabName,
            reason: reason.rawValue,
            exitCode: exitCode,
            timestamp: formatter.string(from: Date())
        )

        let filename = "\(tabID.uuidString).json"
        let url = eventsDirectory.appendingPathComponent(filename)
        let tmpURL = url.appendingPathExtension("tmp")

        do {
            let data = try JSONEncoder().encode(event)
            try data.write(to: tmpURL, options: .atomic)
            try FileManager.default.moveItem(at: tmpURL, to: url)
        } catch {
            print("TabEventWriter: Failed to write event for \(tabID): \(error)")
        }
    }

    /// Clean up stale event files older than 1 hour.
    static func cleanupStaleEvents() {
        let dir = eventsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
        ) else { return }

        let cutoff = Date().addingTimeInterval(-3600)
        for file in files where file.pathExtension == "json" {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let created = attrs[.creationDate] as? Date,
               created < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
