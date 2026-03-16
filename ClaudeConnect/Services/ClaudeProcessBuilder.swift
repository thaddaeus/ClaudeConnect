import Foundation

struct ProcessParams {
    let executable: String
    let args: [String]
    let environment: [String]?
    let workingDirectory: String
}

/// Resolves the user's login shell once at startup.
/// Instead of forking to read `env` (which crashes under hardened runtime),
/// we spawn the login shell via PTY and let it resolve PATH naturally.
class ShellEnvironment {
    static let shared = ShellEnvironment()

    /// The user's login shell (e.g. /bin/zsh)
    let shell: String

    private init() {
        // Read login shell from passwd entry, fallback to /bin/zsh
        let pw = getpwuid(getuid())
        if let shellPtr = pw?.pointee.pw_shell {
            self.shell = String(cString: shellPtr)
        } else {
            self.shell = "/bin/zsh"
        }
    }
}

struct ClaudeProcessBuilder {

    static func build(from config: SessionConfiguration) -> ProcessParams {
        let env = ShellEnvironment.shared

        // Build the claude command string with all arguments
        var parts: [String] = ["claude"]

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

        // Build append system prompt: user's text + ClaudeConnect tab instructions if enabled
        var appendPromptParts: [String] = []
        if let prompt = config.appendSystemPrompt, !prompt.isEmpty {
            appendPromptParts.append(prompt)
        }
        if config.openInClaudeConnect {
            appendPromptParts.append(Self.claudeConnectTabPrompt)
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

    /// Instructions appended to the system prompt when "Open in ClaudeConnect" is enabled
    private static let claudeConnectTabPrompt = """
    IMPORTANT: You are running inside ClaudeConnect, a tabbed terminal app. \
    When you need to open a new terminal tab (e.g. for worktrees, parallel tasks, or spawning sub-agents in separate terminals), \
    you MUST use the `claude-connect-tab` CLI tool instead of osascript or Terminal.app. \
    This ensures new tabs open inside ClaudeConnect rather than in a separate Terminal window.

    Usage: claude-connect-tab [options]
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

    Example: claude-connect-tab --name "Feature Work" --cwd /path/to/worktree --prompt "Implement the feature"
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
