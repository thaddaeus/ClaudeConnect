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
    var openInClaudeConnect: Bool = false
    var folderID: UUID?

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
        openInClaudeConnect = try c.decodeIfPresent(Bool.self, forKey: .openInClaudeConnect) ?? false
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
    }

    init() {}

    enum PermissionMode: String, Codable, CaseIterable, Identifiable {
        case `default` = "default"
        case plan = "plan"
        case autoEdit = "auto-edit"
        case fullAuto = "full-auto"
        case bypassPermissions = "bypassPermissions"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .default: return "Default"
            case .plan: return "Plan"
            case .autoEdit: return "Auto Edit"
            case .fullAuto: return "Full Auto"
            case .bypassPermissions: return "Bypass Permissions"
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
