import Foundation

struct ProcessParams {
    let executable: String
    let args: [String]
    let environment: [String]?
    let workingDirectory: String
}

/// Resolves the login shell environment once at startup.
/// Must be called from AppDelegate before any SwiftUI views are created.
class ShellEnvironment {
    static let shared = ShellEnvironment()

    let environment: [String]
    let path: String
    let claudePath: String?

    private init() {
        // Resolve login environment synchronously by reading pipe data
        // (readDataToEndOfFile blocks until process exits, no need for waitUntilExit)
        var env: [String] = []
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "env"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                env = output
                    .components(separatedBy: .newlines)
                    .filter { $0.contains("=") }
            }
        } catch {
            print("Failed to read login environment: \(error)")
        }

        // Extract PATH
        var resolvedPath = "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
        for entry in env {
            if entry.hasPrefix("PATH=") {
                resolvedPath = String(entry.dropFirst(5))
                break
            }
        }
        self.path = resolvedPath

        // Set TERM
        env.removeAll { $0.hasPrefix("TERM=") }
        env.append("TERM=xterm-256color")
        self.environment = env

        // Resolve claude binary
        var found: String? = nil
        let pathDirs = resolvedPath.components(separatedBy: ":")
        for dir in pathDirs {
            let candidate = (dir as NSString).appendingPathComponent("claude")
            if FileManager.default.isExecutableFile(atPath: candidate) {
                found = candidate
                break
            }
        }
        self.claudePath = found
    }
}

struct ClaudeProcessBuilder {

    static func build(from config: SessionConfiguration) -> ProcessParams {
        let shell = ShellEnvironment.shared
        let claudePath = shell.claudePath ?? "claude"

        var args: [String] = []

        if let model = config.model, !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }

        if let mode = config.permissionMode {
            args.append(contentsOf: ["--permission-mode", mode.rawValue])
        }

        if let effort = config.effortLevel, !effort.isEmpty {
            args.append(contentsOf: ["--effort", effort])
        }

        if let prompt = config.systemPrompt, !prompt.isEmpty {
            args.append(contentsOf: ["--system-prompt", prompt])
        }

        if let prompt = config.appendSystemPrompt, !prompt.isEmpty {
            args.append(contentsOf: ["--append-system-prompt", prompt])
        }

        if let tools = config.allowedTools, !tools.isEmpty {
            args.append("--allowedTools")
            args.append(contentsOf: tools)
        }

        if let tools = config.disallowedTools, !tools.isEmpty {
            args.append("--disallowedTools")
            args.append(contentsOf: tools)
        }

        if let mcp = config.mcpConfigPath, !mcp.isEmpty {
            args.append(contentsOf: ["--mcp-config", mcp])
        }

        if config.continueSession {
            args.append("--continue")
        }

        // Parse additional flags
        let extraFlags = config.additionalFlags
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        args.append(contentsOf: extraFlags)

        // Initial prompt as positional argument (no -p flag, which would make it non-interactive)
        if let prompt = config.initialPrompt, !prompt.isEmpty {
            args.append(prompt)
        }

        let workDir = (config.workingDirectory as NSString).expandingTildeInPath

        return ProcessParams(
            executable: claudePath,
            args: args,
            environment: shell.environment,
            workingDirectory: workDir
        )
    }
}
