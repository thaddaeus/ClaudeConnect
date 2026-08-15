import Foundation

struct TabCommand: Codable {
    var action: String = "open-tab"
    var name: String?
    var workingDirectory: String?
    var model: String?
    var permissionMode: String?
    var effort: String?
    var systemPrompt: String?
    var appendSystemPrompt: String?
    var initialPrompt: String?
    var mcpConfigPath: String?
    var additionalFlags: [String]?
    var tabColor: String?
    var continueSession: Bool?
    /// The spawning tab's id (CLI fills it from $CONSOLEFORGE_TAB_ID) — groups the
    /// new tab under the tab the command was run in.
    var parentTabID: String?
    /// Tab ID for close-tab action (matches CONSOLEFORGE_TAB_ID env var)
    var tabID: String?
    /// Page to load for the `browser-window` and `browser-navigate` actions.
    var url: String?
    /// `--browser`: give the spawned tab its own managed browser.
    var usesManagedBrowser: Bool?

    // MARK: - In-app browser control (see BrowserControl)

    /// Correlates a command with its reply in `responses/`. Present only for the
    /// verbs that answer; the fire-and-forget ones leave it nil and nothing is written.
    var requestID: String?
    /// JavaScript for `browser-eval`.
    var script: String?
    /// Absolute scroll position for `browser-scroll`; wins over `scrollBy`.
    var scrollTo: Double?
    /// Relative scroll delta for `browser-scroll`.
    var scrollBy: Double?
    /// Where `browser-screenshot` should write its PNG. Defaults into the channel's
    /// support directory when absent.
    var path: String?
}

class CommandWatcher {
    var onCommand: ((TabCommand) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1

    /// Per-channel, so beta and production never watch the same directory —
    /// otherwise both apps race to claim each command file and the wrong one
    /// opens the tab.
    static var commandsDirectory: URL {
        AppChannel.supportDirectory("commands")
    }

    func start() {
        let dir = Self.commandsDirectory

        // Process any commands that were written while the app was not running
        processCommandFiles()

        // Watch the directory for new files
        dirFD = open(dir.path, O_EVTONLY)
        guard dirFD >= 0 else {
            print("CommandWatcher: Failed to open directory for watching: \(dir.path)")
            return
        }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: .write,
            queue: .main
        )

        source?.setEventHandler { [weak self] in
            self?.processCommandFiles()
        }

        source?.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 {
                close(fd)
                self?.dirFD = -1
            }
        }

        source?.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func processCommandFiles() {
        let dir = Self.commandsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let command = try JSONDecoder().decode(TabCommand.self, from: data)
                try FileManager.default.removeItem(at: file)
                onCommand?(command)
            } catch {
                print("CommandWatcher: Failed to process \(file.lastPathComponent): \(error)")
                // Remove malformed files to avoid reprocessing
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
