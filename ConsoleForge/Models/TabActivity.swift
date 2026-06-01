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

    /// Optional sink for companion events. Set by the app to forward transitions to
    /// `CompanionService` without the tracker taking a hard dependency on networking
    /// or the session store (the wiring layer enriches signals with tab metadata).
    @ObservationIgnored var onCompanionEvent: ((CompanionSignal) -> Void)?

    /// How long a background tab must be quiet (no new output) before it emits a
    /// `settled` event. Mirrors `CompanionSettings.settleSeconds`; 0 disables it.
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
            // A bell is itself the attention signal; don't also settle-alert.
            cancelSettleTimer(for: tabID)
            // Emit unconditionally (not via setState) — each bell is a fresh turn-end
            // and should push, even if the tab was already in .bell.
            emit(tabID, .bell)
        }
    }

    /// Called when the user switches to a tab — clears its indicators
    func didFocusTab(tabID: UUID) {
        bellTabs.remove(tabID)
        unreadTabs.remove(tabID)
        cancelSettleTimer(for: tabID)
        setState(.active, for: tabID)
    }

    /// Called when a tab's process terminates
    func didTerminate(tabID: UUID, exitCode: Int32? = nil) {
        cancelSettleTimer(for: tabID)
        activities[tabID] = .idle
        emit(tabID, .exited, exitCode: exitCode)
    }

    /// Called when a tab is closed
    func removeTab(tabID: UUID) {
        cancelSettleTimer(for: tabID)
        activities.removeValue(forKey: tabID)
        bellTabs.remove(tabID)
        unreadTabs.remove(tabID)
    }

    // MARK: - Companion event plumbing

    /// Updates a tab's activity state and emits a snapshot companion event only when
    /// the state actually changes — output arrives per-chunk, so emitting on every
    /// chunk would be a firehose. The settle timer still restarts on every chunk.
    private func setState(_ newState: TabActivity, for tabID: UUID) {
        guard activities[tabID] != newState else { return }
        activities[tabID] = newState
        emit(tabID, newState.companionState)
    }

    private func emit(_ tabID: UUID, _ state: CompanionState, exitCode: Int32? = nil) {
        onCompanionEvent?(CompanionSignal(tabId: tabID, state: state, exitCode: exitCode))
    }

    private func restartSettleTimer(for tabID: UUID) {
        cancelSettleTimer(for: tabID)
        guard settleSeconds > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settleTimers[tabID] = nil
            self.emit(tabID, .settled)
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

    /// The companion-event equivalent of this UI activity state.
    var companionState: CompanionState {
        switch self {
        case .idle: .idle
        case .active: .active
        case .output: .output
        case .bell: .bell
        }
    }
}
