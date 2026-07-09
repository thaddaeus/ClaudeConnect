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

    /// How long a background tab must be quiet (no new output) before its dot flips
    /// from working (green) to settled (gray). 0 disables the transition.
    @ObservationIgnored var settleSeconds: Double = 3

    /// Per-tab debounce timers for the `settled` trigger.
    @ObservationIgnored private var settleTimers: [UUID: DispatchWorkItem] = [:]

    func activity(for tabID: UUID) -> TabActivity {
        activities[tabID] ?? .idle
    }

    /// Called when terminal output is received on a tab
    func didReceiveOutput(tabID: UUID, isActive: Bool) {
        if !isActive {
            unreadTabs.insert(tabID)
            // Don't override bell state with mere output
            if activities[tabID] != .bell {
                setState(.output, for: tabID)
            }
            // Each output chunk on a background tab restarts the settle timer; when it
            // elapses with no further output, that's the "turn finished" trailing edge.
            restartSettleTimer(for: tabID)
        } else {
            // The focused tab is being watched — never settle-alert it.
            cancelSettleTimer(for: tabID)
            setState(.active, for: tabID)
        }
    }

    /// Called when a bell character is received on a tab
    func didReceiveBell(tabID: UUID, isActive: Bool) {
        if !isActive {
            bellTabs.insert(tabID)
            activities[tabID] = .bell
            // A bell is itself the attention signal; don't also settle it.
            cancelSettleTimer(for: tabID)
        }
    }

    /// Called when the user switches to a tab — clears its indicators
    func didFocusTab(tabID: UUID) {
        bellTabs.remove(tabID)
        unreadTabs.remove(tabID)
        cancelSettleTimer(for: tabID)
        // A dead process stays .exited (red dot) — focusing can't revive it.
        guard activities[tabID] != .exited else { return }
        setState(.active, for: tabID)
    }

    /// Called when a tab's process terminates
    func didTerminate(tabID: UUID) {
        cancelSettleTimer(for: tabID)
        activities[tabID] = .exited
    }

    /// Called when a tab is closed — the tab no longer exists, unlike `.exited`
    /// where the tab stays open showing a dead process.
    func removeTab(tabID: UUID) {
        cancelSettleTimer(for: tabID)
        activities.removeValue(forKey: tabID)
        bellTabs.remove(tabID)
        unreadTabs.remove(tabID)
    }

    // MARK: - State plumbing

    private func setState(_ newState: TabActivity, for tabID: UUID) {
        guard activities[tabID] != newState else { return }
        activities[tabID] = newState
    }

    private func restartSettleTimer(for tabID: UUID) {
        cancelSettleTimer(for: tabID)
        guard settleSeconds > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settleTimers[tabID] = nil
            // The turn finished — flip the dot from working to settled.
            if self.activities[tabID] == .output {
                self.activities[tabID] = .settled
            }
        }
        settleTimers[tabID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds, execute: work)
    }

    private func cancelSettleTimer(for tabID: UUID) {
        settleTimers[tabID]?.cancel()
        settleTimers[tabID] = nil
    }
}

enum TabActivity {
    /// Tab is focused or no notable state
    case idle
    /// Tab is focused and actively receiving output
    case active
    /// Tab has unread output (background tab received data)
    case output
    /// Background tab went quiet after output — its turn finished
    case settled
    /// Tab received a bell — likely needs user attention (permission prompt, question)
    case bell
    /// Tab's process terminated (tab still open showing the dead session)
    case exited

    var indicatorColor: Color {
        switch self {
        case .idle: .gray
        case .active: .green
        case .output: .blue
        case .settled: .gray
        case .bell: .yellow
        case .exited: .red
        }
    }

    /// Pure STATUS color for the tab bar dot — identity color lives on the tab's
    /// outline, so the dot only answers "what is this session doing?":
    /// working (green), needs input (amber), idle/settled (gray), exited (red).
    var statusDotColor: Color {
        switch self {
        case .active, .output: .green
        case .bell: .orange
        case .idle, .settled: Color.gray.opacity(0.55)
        case .exited: .red
        }
    }

    /// Color that should override a tab's identity color to grab the user's attention.
    /// Returns nil for non-urgent states so the tab's own color can show through.
    /// Used by single-dot UIs (tab bar) where activity and identity share one indicator.
    var attentionColor: Color? {
        switch self {
        case .bell: .yellow
        case .idle, .active, .output, .settled, .exited: nil
        }
    }
}
