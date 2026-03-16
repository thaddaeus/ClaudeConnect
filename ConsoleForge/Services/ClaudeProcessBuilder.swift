import Foundation

struct ProcessParams {
    let executable: String
    let args: [String]
    let environment: [String]?
    let workingDirectory: String
}

/// Resolves shell and tool paths at startup without forking.
class ShellEnvironment {
    static let shared = ShellEnvironment()

    /// The user's login shell (e.g. /bin/zsh)
    let shell: String

    /// Absolute path to the claude binary, or nil if not found
    let claudePath: String?

    private init() {
        // Read login shell from passwd entry, fallback to /bin/zsh
        let pw = getpwuid(getuid())
        if let shellPtr = pw?.pointee.pw_shell {
            self.shell = String(cString: shellPtr)
        } else {
            self.shell = "/bin/zsh"
        }

        // Search common directories for the claude binary (no fork needed)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let searchDirs = [
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            "\(home)/.nvm/versions/node/*/bin",  // nvm
            "\(home)/.volta/bin",                  // volta
            "\(home)/.npm-global/bin",
        ]

        var found: String? = nil
        let fm = FileManager.default
        for dir in searchDirs {
            if dir.contains("*") {
                // Glob-style: expand with directory enumeration
                let parent = (dir as NSString).deletingLastPathComponent
                let pattern = (dir as NSString).lastPathComponent
                if let contents = try? fm.contentsOfDirectory(atPath: (parent as NSString).deletingLastPathComponent) {
                    for entry in contents {
                        let full = ((parent as NSString).deletingLastPathComponent as NSString)
                            .appendingPathComponent(entry)
                        let candidate = (full as NSString).appendingPathComponent(pattern)
                            .appending("/claude")
                        if fm.isExecutableFile(atPath: candidate) {
                            found = candidate
                            break
                        }
                    }
                }
            } else {
                let candidate = (dir as NSString).appendingPathComponent("claude")
                if fm.isExecutableFile(atPath: candidate) {
                    found = candidate
                    break
                }
            }
            if found != nil { break }
        }
        self.claudePath = found
    }
}

struct ClaudeProcessBuilder {

    static func build(from config: SessionConfiguration) -> ProcessParams {
        let env = ShellEnvironment.shared

        // Build the claude command string with all arguments
        // Priority: user setting > auto-detected > bare name for shell PATH lookup
        let userPath = UserDefaults.standard.string(forKey: "claudeBinaryPath") ?? ""
        let claudeBinary: String
        if !userPath.isEmpty, FileManager.default.isExecutableFile(atPath: userPath) {
            claudeBinary = userPath
        } else {
            claudeBinary = env.claudePath ?? "claude"
        }
        var parts: [String] = [claudeBinary]

        if let model = config.model, !model.isEmpty {
            parts.append(contentsOf: ["--model", shellQuote(model)])
        }

        if let mode = config.permissionMode {
            parts.append(contentsOf: ["--permission-mode", mode.rawValue])
        }

        if let effort = config.effortLevel, !effort.isEmpty {
            parts.append(contentsOf: ["--effort", effort])
        }

        if let prompt = config.systemPrompt, !prompt.isEmpty {
            parts.append(contentsOf: ["--system-prompt", shellQuote(prompt)])
        }

        // Build append system prompt: user's text + ConsoleForge tab instructions if enabled
        var appendPromptParts: [String] = []
        if let prompt = config.appendSystemPrompt, !prompt.isEmpty {
            appendPromptParts.append(prompt)
        }
        if config.openInConsoleForge {
            appendPromptParts.append(Self.consoleForgeTabPrompt)
        }
        if !appendPromptParts.isEmpty {
            parts.append(contentsOf: ["--append-system-prompt", shellQuote(appendPromptParts.joined(separator: "\n\n"))])
        }

        if let tools = config.allowedTools, !tools.isEmpty {
            parts.append("--allowedTools")
            parts.append(contentsOf: tools.map { shellQuote($0) })
        }

        if let tools = config.disallowedTools, !tools.isEmpty {
            parts.append("--disallowedTools")
            parts.append(contentsOf: tools.map { shellQuote($0) })
        }

        if let mcp = config.mcpConfigPath, !mcp.isEmpty {
            parts.append(contentsOf: ["--mcp-config", shellQuote(mcp)])
        }

        if config.continueSession {
            parts.append("--continue")
        }

        // Parse additional flags
        let extraFlags = config.additionalFlags
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        parts.append(contentsOf: extraFlags)

        // Initial prompt as positional argument (no -p flag, which would make it non-interactive)
        if let prompt = config.initialPrompt, !prompt.isEmpty {
            parts.append(shellQuote(prompt))
        }

        let workDir = (config.workingDirectory as NSString).expandingTildeInPath
        let command = parts.joined(separator: " ")

        // Spawn the user's login shell which will resolve PATH and run claude
        // Using -l for login shell (loads .zprofile for PATH), -c for command
        // Avoid -i (interactive) which loads .zshrc plugins/completions and slows startup
        return ProcessParams(
            executable: env.shell,
            args: ["-l", "-c", command],
            environment: nil,  // Let the login shell set up its own environment
            workingDirectory: workDir
        )
    }

    /// Instructions appended to the system prompt when "Open in ConsoleForge" is enabled
    private static let consoleForgeTabPrompt = """
    IMPORTANT: You are running inside ConsoleForge, a tabbed terminal app. \
    When you need to open a new terminal tab (e.g. for worktrees, parallel tasks, or spawning sub-agents in separate terminals), \
    you MUST use the `consoleforge-tab` CLI tool instead of osascript or Terminal.app. \
    This ensures new tabs open inside ConsoleForge rather than in a separate Terminal window.

    Usage: consoleforge-tab [options]
      --name NAME              Tab name
      --cwd PATH               Working directory
      --model MODEL            Claude model (opus, sonnet, haiku)
      --permission-mode MODE   Permission mode (default, plan, auto-edit, full-auto, bypassPermissions)
      --effort LEVEL           Effort level (low, medium, high, max)
      --system-prompt TEXT     Replace system prompt
      --append-system-prompt TEXT  Append to system prompt
      --prompt TEXT             Initial prompt (sent as first message)
      --mcp-config PATH        MCP config file path
      --flag FLAG              Additional CLI flag (can be repeated)
      --color HEX              Tab color (e.g. "#FF2D55")
      --continue               Continue previous session

    Example: consoleforge-tab --name "Feature Work" --cwd /path/to/worktree --prompt "Implement the feature"
    """

    /// Shell-quote a string to safely embed in a command
    private static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        // If it contains no special characters, return as-is
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@,"))
        if s.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return s
        }
        // Wrap in single quotes, escaping any existing single quotes
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
