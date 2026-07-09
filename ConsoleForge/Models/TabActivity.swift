import SwiftUI

/// Tracks activity state for an open tab to show visual indicators
/// when a session needs the user's attention.
@Observable
class TabActivityTracker {
    /// Per-tab activity state
    private(set) var activities: [UUID: TabActivity] = [:]

    /// How long a background tab must be quiet (no new output) before its dot flips
    /// from working (green) to settled (gray). 0 disables the transition.
    @ObservationIgnored var settleSeconds: Double = 3

    /// Resolves a tab's working directory, so a bell can be checked against that
    /// session's transcript. Set by the app; the tracker stays free of a `SessionStore`
    /// dependency. When this is nil, or returns nil, a bell falls back to the old
    /// always-alert behaviour rather than silently going quiet.
    @ObservationIgnored var workingDirectory: ((UUID) -> String?)?

    /// Per-tab debounce timers for the `settled` trigger.
    @ObservationIgnored private var settleTimers: [UUID: DispatchWorkItem] = [:]

    /// Per-tab probe counter. Bumped whenever a tab's state is decided by something
    /// more authoritative than an in-flight probe (focus, exit, close, a newer bell),
    /// so a slow transcript read can't land late and stomp it.
    @ObservationIgnored private var probeGeneration: [UUID: Int] = [:]

    /// Claude writes the assistant record that contains a pending `tool_use` to the
    /// transcript a beat *after* the tool starts — measured at ~115ms. Probing the
    /// instant the bell arrives can therefore read a transcript that hasn't caught up,
    /// see nothing pending, and gray out a live permission prompt. Wait first.
    @ObservationIgnored private let bellProbeDelay: TimeInterval = 0.4

    /// Before clearing the amber dot we re-read once more. A false "pending" merely
    /// leaves the dot amber a moment longer; a false "clear" silently drops an alert
    /// the user is waiting on. Only the second failure mode is worth guarding.
    @ObservationIgnored private let clearConfirmDelay: TimeInterval = 0.6

    /// Floor on how often a belled tab re-reads its transcript while output streams.
    /// Output arrives per chunk; the transcript is a file read.
    @ObservationIgnored private let reprobeThrottle: TimeInterval = 1.0

    /// When each tab last kicked a probe, for `reprobeThrottle`.
    @ObservationIgnored private var lastProbeAt: [UUID: Date] = [:]

    func activity(for tabID: UUID) -> TabActivity {
        activities[tabID] ?? .idle
    }

    /// Called when terminal output is received on a tab
    func didReceiveOutput(tabID: UUID, isActive: Bool) {
        if !isActive {
            if activities[tabID] == .bell {
                // Never let raw output clear a pending prompt — while Claude waits it
                // still repaints its spinner and status line, which is exactly why the
                // old code refused to budge here. But once the prompt is answered,
                // Claude can stream for minutes and the settle timer never fires, so
                // the amber dot would sit there through a whole turn of real work.
                // Ask the transcript instead of the bytes, at a rate a file read can
                // stand.
                reprobeWhileBelled(tabID)
            } else {
                setState(.output, for: tabID)
            }
            // Each output chunk on a background tab restarts the settle timer; when it
            // elapses with no further output, that's the "turn finished" trailing edge.
            restartSettleTimer(for: tabID)
        } else {
            // The focused tab is being watched — never settle-alert it.
            cancelSettleTimer(for: tabID)
            invalidateProbe(for: tabID)
            setState(.active, for: tabID)
        }
    }

    /// Called when a bell character is received on a tab.
    ///
    /// Claude Code rings the bell at the end of *every* turn, so a bell by itself
    /// says only "a turn boundary happened" — not "I need you." Asking the transcript
    /// whether the session is actually blocked is what separates the two. Until the
    /// answer arrives the dot keeps whatever it had, so a plain turn-end bell never
    /// flashes amber on its way to gray.
    func didReceiveBell(tabID: UUID, isActive: Bool) {
        guard !isActive else { return }
        // A bell is a turn boundary; the settle timer is about to be redundant.
        cancelSettleTimer(for: tabID)
        schedulePromptProbe(for: tabID, after: bellProbeDelay)
    }

    /// Called when the user switches to a tab — clears its indicators
    func didFocusTab(tabID: UUID) {
        cancelSettleTimer(for: tabID)
        invalidateProbe(for: tabID)
        // A dead process stays .exited (red dot) — focusing can't revive it.
        guard activities[tabID] != .exited else { return }
        setState(.active, for: tabID)
    }

    /// Called when a tab's process terminates
    func didTerminate(tabID: UUID) {
        cancelSettleTimer(for: tabID)
        invalidateProbe(for: tabID)
        activities[tabID] = .exited
    }

    /// Called when a tab is closed — the tab no longer exists, unlike `.exited`
    /// where the tab stays open showing a dead process.
    func removeTab(tabID: UUID) {
        cancelSettleTimer(for: tabID)
        invalidateProbe(for: tabID)
        activities.removeValue(forKey: tabID)
        probeGeneration.removeValue(forKey: tabID)
        lastProbeAt.removeValue(forKey: tabID)
    }

    // MARK: - Pending-prompt probe

    /// Re-read the transcript for a belled tab that is streaming output again, no more
    /// than once per `reprobeThrottle`. If the prompt has been answered the probe
    /// clears the dot; the next output chunk then paints it green (working).
    private func reprobeWhileBelled(_ tabID: UUID) {
        let now = Date()
        if let last = lastProbeAt[tabID], now.timeIntervalSince(last) < reprobeThrottle { return }
        schedulePromptProbe(for: tabID, after: 0)
    }

    /// Ask the session's transcript whether it is blocked on the user, and set the dot
    /// from the answer: amber only when something is genuinely pending.
    ///
    /// Reading the transcript is file IO, so it runs off the main thread and the result
    /// is applied back on main. A generation check discards the answer if the tab was
    /// focused, closed, or belled again while the read was in flight.
    ///
    /// `confirmationsLeft` guards the one-way door: a probe that says "nothing pending"
    /// re-reads once before it is allowed to clear the dot.
    private func schedulePromptProbe(for tabID: UUID, after delay: TimeInterval, confirmationsLeft: Int = 1) {
        // Bump first: this supersedes any probe already scheduled or in flight.
        let generation = bumpProbe(for: tabID)
        lastProbeAt[tabID] = Date()

        guard let cwd = workingDirectory?(tabID), !cwd.isEmpty else {
            // No working directory to inspect — can't tell, so assume it wants us.
            applyProbe(nil, to: tabID, confirmationsLeft: 0)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.probeGeneration[tabID] == generation else { return }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let awaiting = PendingPromptProbe.isAwaitingUser(workingDirectory: cwd)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.probeGeneration[tabID] == generation else { return }
                    self.applyProbe(awaiting, to: tabID, confirmationsLeft: confirmationsLeft)
                }
            }
        }
    }

    /// `nil` means the probe couldn't tell (no transcript, unreadable). Treat that as
    /// needing attention — a missed alert is worse than a stale one.
    ///
    /// No check for a missing tab: focus, exit, and close all bump the generation, so
    /// a probe that reaches here is for a tab that still wants a dot — including one
    /// whose first-ever event was this bell.
    private func applyProbe(_ awaiting: Bool?, to tabID: UUID, confirmationsLeft: Int) {
        guard activities[tabID] != .exited else { return }

        guard let awaiting else {
            activities[tabID] = .bell   // couldn't tell
            return
        }
        if awaiting {
            activities[tabID] = .bell
        } else if confirmationsLeft > 0 {
            // Don't clear on a single read — the transcript may just be lagging.
            schedulePromptProbe(for: tabID, after: clearConfirmDelay, confirmationsLeft: 0)
        } else {
            activities[tabID] = .settled
        }
    }

    @discardableResult
    private func bumpProbe(for tabID: UUID) -> Int {
        let next = (probeGeneration[tabID] ?? 0) + 1
        probeGeneration[tabID] = next
        return next
    }

    /// Abandon any in-flight probe for this tab.
    private func invalidateProbe(for tabID: UUID) {
        bumpProbe(for: tabID)
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
            switch self.activities[tabID] {
            case .output:
                // The turn finished — flip the dot from working to settled.
                self.activities[tabID] = .settled
            case .bell:
                // The tab was belled, then went quiet again. If the prompt has since
                // been answered — from the terminal, or remotely via Claude Code's
                // `/rc` — nothing is pending any more and the amber dot is stale.
                // Quiet already, so no need to wait out the transcript's write lag.
                self.schedulePromptProbe(for: tabID, after: 0)
            default:
                break
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
