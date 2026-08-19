import Foundation
import SwiftUI

struct SessionConfiguration: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = "New Session"
    var workingDirectory: String = "~"
    var model: String?
    var allowedTools: [String]?
    var disallowedTools: [String]?
    var systemPrompt: String?
    var appendSystemPrompt: String?
    var initialPrompt: String?
    var permissionMode: PermissionMode?
    var mcpConfigPath: String?
    var autoStart: Bool = false
    var tabColorHex: String = "#007AFF"
    var tabIconName: String = "terminal"
    var effortLevel: String?
    var additionalFlags: String = ""
    var continueSession: Bool = false
    var openInConsoleForge: Bool = true
    var isEphemeral: Bool = false
    var folderID: UUID?
    /// The open tab that spawned this one (via `consoleforge-tab` run inside that
    /// tab). Grouped tabs stay adjacent in the tab bar and draw the parent's color
    /// on the leading half of their top border. Cleared when the parent closes or
    /// this tab is dragged out of the group.
    var parentTabID: UUID?
    /// The Claude CLI session id this tab owns. Pinned on a fresh launch via
    /// `--session-id` and re-attached on restore via `--resume`, so a restored
    /// tab continues ITS OWN conversation instead of "the most recent in this
    /// directory" (`--continue`) — which would interleave tabs sharing a cwd.
    var claudeSessionID: UUID?
    /// Give this tab its OWN managed browser, which its agent drives through the
    /// chrome-devtools MCP instead of letting that MCP launch a headed Chrome of its own.
    ///
    /// OFF by default, and that default is the whole point: a headless Chrome costs
    /// 100-200MB and Claude Code starts MCP servers when a session starts, not on first
    /// tool use — so "every tab gets one" is 1.5-3GB across a real day's tabs. Set it
    /// where the decision is actually known: a hub spawning a worktree knows whether that
    /// worktree does web work (`consoleforge-tab --browser`).
    var usesManagedBrowser: Bool = false
    /// Terminal (a PTY) or document (a file). Defaults to `.terminal` so every session
    /// written before Phase B decodes unchanged. See `ViewKind`.
    var viewKind: ViewKind = .terminal
    /// The file a `.document` tab shows. Nil on terminal tabs.
    var documentPath: String?

    var isTerminal: Bool { viewKind.isTerminal }

    // Custom decoder to handle missing keys from older sessions.json files
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New Session"
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? "~"
        model = try c.decodeIfPresent(String.self, forKey: .model)
        allowedTools = try c.decodeIfPresent([String].self, forKey: .allowedTools)
        disallowedTools = try c.decodeIfPresent([String].self, forKey: .disallowedTools)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        appendSystemPrompt = try c.decodeIfPresent(String.self, forKey: .appendSystemPrompt)
        initialPrompt = try c.decodeIfPresent(String.self, forKey: .initialPrompt)
        permissionMode = try c.decodeIfPresent(PermissionMode.self, forKey: .permissionMode)
        mcpConfigPath = try c.decodeIfPresent(String.self, forKey: .mcpConfigPath)
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        tabColorHex = try c.decodeIfPresent(String.self, forKey: .tabColorHex) ?? "#007AFF"
        tabIconName = try c.decodeIfPresent(String.self, forKey: .tabIconName) ?? "terminal"
        effortLevel = try c.decodeIfPresent(String.self, forKey: .effortLevel)
        additionalFlags = try c.decodeIfPresent(String.self, forKey: .additionalFlags) ?? ""
        continueSession = try c.decodeIfPresent(Bool.self, forKey: .continueSession) ?? false
        openInConsoleForge = try c.decodeIfPresent(Bool.self, forKey: .openInConsoleForge) ?? true
        isEphemeral = try c.decodeIfPresent(Bool.self, forKey: .isEphemeral) ?? false
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        parentTabID = try c.decodeIfPresent(UUID.self, forKey: .parentTabID)
        claudeSessionID = try c.decodeIfPresent(UUID.self, forKey: .claudeSessionID)
        // Absent on every session written before Phase B — and those are all terminals.
        usesManagedBrowser = try c.decodeIfPresent(Bool.self, forKey: .usesManagedBrowser) ?? false
        viewKind = try c.decodeIfPresent(ViewKind.self, forKey: .viewKind) ?? .terminal
        documentPath = try c.decodeIfPresent(String.self, forKey: .documentPath)
    }

    /// A read-only document tab, parented to the console tab it was opened from.
    static func document(path: String, parentTabID: UUID?) -> SessionConfiguration {
        var config = SessionConfiguration()
        config.viewKind = .document
        config.documentPath = path
        config.name = (path as NSString).lastPathComponent
        config.workingDirectory = (path as NSString).deletingLastPathComponent
        config.tabIconName = "doc.text"
        config.parentTabID = parentTabID
        return config
    }

    init() {}

    enum PermissionMode: String, Codable, CaseIterable, Identifiable {
        // The CLI renamed this mode to `manual`; "default" survives only as a
        // decode alias below, because it is the stored rawValue in every
        // sessions.json written before now.
        case manual = "manual"
        case plan = "plan"
        case acceptEdits = "acceptEdits"
        case auto = "auto"
        case dontAsk = "dontAsk"
        case bypassPermissions = "bypassPermissions"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .manual: return "Manual"
            case .plan: return "Plan"
            case .acceptEdits: return "Accept Edits"
            case .auto: return "Auto"
            case .dontAsk: return "Don't Ask"
            case .bypassPermissions: return "Bypass Permissions"
            }
        }

        /// Decode legacy values from saved sessions
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "auto-edit": self = .acceptEdits
            case "full-auto": self = .auto
            // Renamed upstream. 2.1.235 still accepts `default` as an unlisted alias,
            // so nothing was broken while we sent it — but the CLI lists `manual`, and a
            // picker offering a retired name cannot offer the current one.
            case "default": self = .manual
            default:
                guard let mode = PermissionMode(rawValue: raw) else {
                    throw DecodingError.dataCorruptedError(
                        in: try decoder.singleValueContainer(),
                        debugDescription: "Unknown permission mode: \(raw)"
                    )
                }
                self = mode
            }
        }
    }

    var tabColor: Color {
        Color(hex: tabColorHex) ?? .blue
    }
}

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let int = UInt64(hex, radix: 16) else { return nil }
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
