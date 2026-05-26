import SwiftUI

/// Tracks activity state for an open tab to show visual indicators
/// when a session needs the user's attention.
@Observable
class TabActivityTracker {
    /// Per-tab activity state
    private(set) var activities: [UUID: TabActivity] = [:]

    /// Tabs that have received a bell since the user last viewed them
    private var bellTabs: Set<UUID> = []

    /// Tabs that have received output since the user last viewed them
    private var unreadTabs: Set<UUID> = []

    func activity(for tabID: UUID) -> TabActivity {
        activities[tabID] ?? .idle
    }

    /// Called when terminal output is received on a tab
    func didReceiveOutput(tabID: UUID, isActive: Bool) {
        if !isActive {
            unreadTabs.insert(tabID)
            // Don't override bell state with mere output
            if activities[tabID] != .bell {
                activities[tabID] = .output
            }
        } else {
            activities[tabID] = .active
        }
    }

    /// Called when a bell character is received on a tab
    func didReceiveBell(tabID: UUID, isActive: Bool) {
        if !isActive {
            bellTabs.insert(tabID)
            activities[tabID] = .bell
        }
    }

    /// Called when the user switches to a tab — clears its indicators
    func didFocusTab(tabID: UUID) {
        bellTabs.remove(tabID)
        unreadTabs.remove(tabID)
        activities[tabID] = .active
    }

    /// Called when a tab's process terminates
    func didTerminate(tabID: UUID) {
        activities[tabID] = .idle
    }

    /// Called when a tab is closed
    func removeTab(tabID: UUID) {
        activities.removeValue(forKey: tabID)
        bellTabs.remove(tabID)
        unreadTabs.remove(tabID)
    }
}

enum TabActivity {
    /// Tab is focused or no notable state
    case idle
    /// Tab is focused and actively receiving output
    case active
    /// Tab has unread output (background tab received data)
    case output
    /// Tab received a bell — likely needs user attention (permission prompt, question)
    case bell

    var indicatorColor: Color {
        switch self {
        case .idle: .gray
        case .active: .green
        case .output: .blue
        case .bell: .yellow
        }
    }

    /// Color that should override a tab's identity color to grab the user's attention.
    /// Returns nil for non-urgent states so the tab's own color can show through.
    /// Used by single-dot UIs (tab bar) where activity and identity share one indicator.
    var attentionColor: Color? {
        switch self {
        case .bell: .yellow
        case .idle, .active, .output: nil
        }
    }
}
