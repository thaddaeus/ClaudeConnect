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
}

class CommandWatcher {
    var onCommand: ((TabCommand) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1

    static var commandsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ClaudeConnect/commands", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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
