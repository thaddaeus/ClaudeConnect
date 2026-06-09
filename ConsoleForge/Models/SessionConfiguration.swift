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
    /// The Claude CLI session id this tab owns. Pinned on a fresh launch via
    /// `--session-id` and re-attached on restore via `--resume`, so a restored
    /// tab continues ITS OWN conversation instead of "the most recent in this
    /// directory" (`--continue`) — which would interleave tabs sharing a cwd.
    var claudeSessionID: UUID?

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
        claudeSessionID = try c.decodeIfPresent(UUID.self, forKey: .claudeSessionID)
    }

    init() {}

    enum PermissionMode: String, Codable, CaseIterable, Identifiable {
        case `default` = "default"
        case plan = "plan"
        case acceptEdits = "acceptEdits"
        case auto = "auto"
        case dontAsk = "dontAsk"
        case bypassPermissions = "bypassPermissions"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .default: return "Default"
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
