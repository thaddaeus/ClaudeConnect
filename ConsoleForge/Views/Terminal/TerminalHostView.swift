import SwiftUI
import SwiftTerm

/// Debug toggles. Enable geometry tracing with:
///   defaults write <bundle-id> CFDebugGeometry -bool YES
/// (read once at launch — relaunch to change). When on, the resize pipeline logs the
/// triple `container px → SwiftTerm cols×rows → PTY winsize` so a row/height desync is
/// provable rather than eyeballed. See task 9528.
enum CFDebug {
    static let geometry = UserDefaults.standard.bool(forKey: "CFDebugGeometry")
}

/// Retains one `TerminalSession` per open tab, independent of the view hierarchy.
/// Only the active session's view is mounted (see `TerminalHostView`); the rest
/// keep running detached. The manager creates/destroys sessions in `reconcile`
/// to track the set of open tabs.
@MainActor
@Observable
final class TerminalSessionManager {
    private(set) var sessions: [UUID: TerminalSession] = [:]

    /// The live terminal-area size. New sessions are born at this size and all
    /// existing sessions are resized to it, so a tab is never reflowed from a stale
    /// placeholder size on first mount (which corrupts the SwiftTerm buffer model).
    private(set) var currentSize = CGSize(width: 800, height: 600)

    /// True once the first real size has been applied. The bootstrap size must land
    /// synchronously — `handleSizeChange` reconciles right after `setSize` returns
    /// and sessions must be born at the real size (task 9528) — so only sizes after
    /// the first are debounced.
    private var hasAppliedRealSize = false
    /// Latest size seen during an in-flight resize burst; applied when the trailing
    /// debounce fires.
    private var pendingSize: CGSize?
    private var resizeDebounce: Task<Void, Never>?
    private var settleNudge: Task<Void, Never>?
    /// Intermediate sizes swallowed since the last apply, for CFDebugGeometry.
    private var coalescedCount = 0

    /// Trailing debounce for resize bursts. The animated fullscreen enter/exit
    /// (~0.5s) fires frameDidChange at many intermediate sizes; reflowing SwiftTerm
    /// and SIGWINCHing the PTY at each one makes Claude redraw its bottom-anchored
    /// TUI at several wrong widths (transient garble + orphaned prompt lines in
    /// scrollback). Only the final geometry should reach the terminal (task 9543).
    private static let debounceInterval: Duration = .milliseconds(140)
    /// Delay after the final geometry lands before re-delivering SIGWINCH, so the
    /// nudge arrives after the transition (and the child's own resize handling)
    /// has settled.
    private static let nudgeDelay: Duration = .milliseconds(300)

    func session(for id: UUID?) -> TerminalSession? {
        guard let id else { return nil }
        return sessions[id]
    }

    /// Update the live terminal-area size and keep every session (active + detached)
    /// in lockstep. Call this before `reconcile` so newly created sessions start at
    /// the real size rather than the placeholder.
    ///
    /// The first real size applies synchronously; later sizes are coalesced with a
    /// trailing debounce so a burst of intermediate geometries (animated fullscreen
    /// transition, live window drag) produces exactly one SwiftTerm reflow + PTY
    /// winsize at the final size.
    func setSize(_ size: CGSize) {
        // A degenerate geometry is REJECTED outright, not clamped and not applied. The
        // old `> 1` test let a ~27pt container through as a two-column grid, and a
        // resumed session flooding its history in at two columns re-breaks every
        // wrapped line permanently — widening again cannot undo it. Anything this
        // small is a container mid-collapse or mid-transition, so the last good size
        // is the correct thing to keep.
        guard TerminalMetrics.isUsable(size) else {
            GeometryTrace.shared.record("rejected",
                "container=\(Int(size.width))×\(Int(size.height)) " +
                "(\(TerminalMetrics.columns(forWidth: size.width)) cols) — keeping " +
                "\(Int(currentSize.width))×\(Int(currentSize.height))")
            if CFDebug.geometry {
                print("[geom] REJECTED degenerate container=\(Int(size.width))×\(Int(size.height))")
            }
            return
        }
        GeometryTrace.shared.noteContainer(size)
        GeometryTrace.shared.record("setSize",
            "container=\(Int(size.width))×\(Int(size.height)) " +
            "(\(TerminalMetrics.columns(forWidth: size.width)) cols) " +
            (hasAppliedRealSize ? "→ debounce" : "→ apply (first)"))
        guard hasAppliedRealSize else {
            hasAppliedRealSize = true
            applySize(size)
            return
        }
        pendingSize = size
        coalescedCount += 1
        resizeDebounce?.cancel()
        resizeDebounce = Task { [weak self] in
            do { try await Task.sleep(for: Self.debounceInterval) } catch { return }
            guard let self else { return }
            self.resizeDebounce = nil
            if let pending = self.pendingSize, pending != self.currentSize {
                self.applySize(pending)
            }
            self.pendingSize = nil
            self.coalescedCount = 0
        }
    }

    private func applySize(_ size: CGSize) {
        GeometryTrace.shared.record("applied",
            "container=\(Int(size.width))×\(Int(size.height)) sessions=\(sessions.count) coalesced=\(coalescedCount)")
        currentSize = size
        if CFDebug.geometry {
            print("[geom] setSize container=\(Int(size.width))×\(Int(size.height)) sessions=\(sessions.count) coalesced=\(coalescedCount)")
        }
        coalescedCount = 0
        for session in sessions.values {
            session.resize(to: size)
        }
        scheduleSettleNudge()
    }

    /// After the final geometry lands and the transition settles, re-deliver
    /// SIGWINCH to each child (task 9543 part 2). A child that already handled the
    /// resize treats it as a no-op (node emits 'resize' only when the dimensions
    /// actually changed); a child that missed or raced the original signal repaints
    /// its idle prompt/status instead of staying garbled until the next output.
    private func scheduleSettleNudge() {
        settleNudge?.cancel()
        settleNudge = Task { [weak self] in
            do { try await Task.sleep(for: Self.nudgeDelay) } catch { return }
            guard let self else { return }
            self.settleNudge = nil
            for session in self.sessions.values {
                session.nudgeRedraw()
            }
        }
    }

    /// Recover the grid after an event that can desync SwiftTerm + the PTY from the
    /// view WITHOUT a reliable frame change: display sleep/wake, an external display
    /// connecting/disconnecting, or a forced un-fullscreen. The trigger that exposed
    /// this: fullscreen on an external display, the Mac sleeps, the external is
    /// unplugged, and the lid opens to a windowed app on the built-in screen — the
    /// window geometry changes while asleep, and the wake/fullscreen observers only
    /// *repaint* (redrawing the stale layout), never re-assert the size or make Claude
    /// regenerate its output. So: re-assert the TRUE current size to every session,
    /// repaint from the buffer model, then (after the geometry settles) force each
    /// child to redraw its full TUI at the correct size — overwriting a corrupted or
    /// stale-width live region that a plain repaint can't fix. `size` is the
    /// container's real bounds, read at call time (not the possibly-stale cached size).
    func resync(to size: CGSize) {
        guard TerminalMetrics.isUsable(size) else { return }
        resizeDebounce?.cancel()
        resizeDebounce = nil
        pendingSize = nil
        if CFDebug.geometry {
            print("[geom] resync container=\(Int(size.width))×\(Int(size.height)) sessions=\(sessions.count)")
        }
        GeometryTrace.shared.record("resync", "container=\(Int(size.width))×\(Int(size.height))")
        currentSize = size
        for session in sessions.values {
            session.resize(to: size)   // re-assert frame → SwiftTerm reflow → PTY winsize (no-op if unchanged)
            session.forceFullRepaint() // redraw the rendered surface from the buffer model
        }
        // After AppKit settles the new geometry, force a full child redraw so an idle
        // Claude regenerates its bottom-anchored TUI at the correct width.
        settleNudge?.cancel()
        settleNudge = Task { [weak self] in
            do { try await Task.sleep(for: Self.nudgeDelay) } catch { return }
            guard let self else { return }
            self.settleNudge = nil
            for session in self.sessions.values {
                session.forceRedraw()
            }
        }
    }

    /// Bring the live session set in line with `openIDs`: shut down + drop any
    /// session whose id has left the open set, and create a session for any new
    /// id. `resolveLaunch` yields the launch config (with its pinned Claude
    /// session id) and whether to resume it; both flow into the new session.
    func reconcile(
        openIDs: [UUID],
        resolveLaunch: (UUID) -> (config: SessionConfiguration, resume: Bool)?,
        onOutput: @escaping (UUID) -> Void,
        onBell: @escaping (UUID) -> Void,
        onTerminated: @escaping (UUID, Int32?) -> Void
    ) {
        let openSet = Set(openIDs)

        // Drop sessions for tabs that are gone.
        for (id, session) in sessions where !openSet.contains(id) {
            session.shutdown()
            sessions.removeValue(forKey: id)
        }

        // Create sessions for newly opened tabs.
        for id in openIDs where sessions[id] == nil {
            guard let launch = resolveLaunch(id) else { continue }
            let session = TerminalSession(sessionID: id, configuration: launch.config, resume: launch.resume, initialSize: currentSize)
            wire(session, id: id, onOutput: onOutput, onBell: onBell, onTerminated: onTerminated)
            sessions[id] = session
        }
    }

    /// Tear down one session and recreate it (used by Restart). The replacement
    /// launches with the given config/resume (see `SessionStore.resolveLaunch`,
    /// which pins a fresh Claude session id for the restart) and re-wires callbacks.
    func restart(
        id: UUID,
        configuration: SessionConfiguration,
        resume: Bool = false,
        onOutput: @escaping (UUID) -> Void,
        onBell: @escaping (UUID) -> Void,
        onTerminated: @escaping (UUID, Int32?) -> Void
    ) {
        sessions[id]?.shutdown()
        let session = TerminalSession(sessionID: id, configuration: configuration, resume: resume, initialSize: currentSize)
        wire(session, id: id, onOutput: onOutput, onBell: onBell, onTerminated: onTerminated)
        sessions[id] = session
    }

    func shutdownAll() {
        resizeDebounce?.cancel()
        settleNudge?.cancel()
        for session in sessions.values {
            session.shutdown()
        }
        sessions.removeAll()
    }

    private func wire(
        _ session: TerminalSession,
        id: UUID,
        onOutput: @escaping (UUID) -> Void,
        onBell: @escaping (UUID) -> Void,
        onTerminated: @escaping (UUID, Int32?) -> Void
    ) {
        session.onOutputReceived = { onOutput(id) }
        session.onBellReceived = { onBell(id) }
        session.onProcessTerminated = { code in onTerminated(id, code) }
    }
}

/// Hosts a single (the active) `TerminalSession`'s `TerminalView` inside a
/// container NSView. Swapping `session` removes the previous terminal view
/// (calling `unmount`) and adds the new one (calling `mount`). Inactive
/// terminals stay detached but alive — owned by `TerminalSessionManager`.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession?
    /// Called with the live terminal-area size whenever the container's frame changes.
    /// The container's bounds always reflect the real area (window size, fullscreen
    /// mode, and sidebar width all flow through the view hierarchy to it), so this is
    /// the authoritative, AppKit-driven size source — wired to the manager's `setSize`.
    let onContainerResize: (CGSize) -> Void
    /// Called with the container's real bounds after a sleep/wake or display
    /// reconfiguration settles — wired to the manager's `resync`, which re-asserts the
    /// size and forces a redraw (a plain frame change isn't guaranteed across these
    /// events, and the existing repaint-only handlers can't fix a stale-width grid).
    let onResync: (CGSize) -> Void

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.autoresizingMask = [.width, .height]
        // The terminal view's frame intentionally trails the container during a
        // resize burst (coalesced sizing, task 9543) — clip so an old-size terminal
        // can't paint outside the terminal area while the window is shrinking.
        container.clipsToBounds = true

        // The single source of truth for the terminal-area size. SwiftUI's
        // GeometryReader is unreliable across the animated fullscreen↔windowed
        // transition — it can fail to re-fire, leaving the grid's ROW count stale so
        // Claude's bottom-anchored input box overstrikes (task 9528). AppKit's
        // frameDidChange fires on every real geometry change, so we drive resize from
        // the container's actual bounds instead.
        container.postsFrameChangedNotifications = true
        context.coordinator.container = container
        context.coordinator.onResize = onContainerResize
        context.coordinator.onResync = onResync
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: container,
            queue: .main
        ) { [weak coordinator = context.coordinator] note in
            MainActor.assumeIsolated {
                guard let view = note.object as? NSView else { return }
                coordinator?.onResize?(view.bounds.size)
            }
        }

        // Display sleep/wake and screen reconfiguration (e.g. fullscreen on an
        // external display → sleep → unplug → lid open to a windowed app on the
        // built-in screen) change the window geometry while the app is asleep, so a
        // `frameDidChange` for the final size isn't guaranteed and the grid can be left
        // desynced. Re-read the TRUE bounds once AppKit settles and force a re-sync.
        let resyncAfterSettle: @Sendable (Notification) -> Void = { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let coordinator, let view = coordinator.container else { return }
                    coordinator.onResync?(view.bounds.size)
                }
            }
        }
        context.coordinator.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: resyncAfterSettle
        )
        context.coordinator.screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: resyncAfterSettle
        )
        return container
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let obs = coordinator.frameObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = coordinator.wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let obs = coordinator.screenObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        coordinator.frameObserver = nil
        coordinator.wakeObserver = nil
        coordinator.screenObserver = nil
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Keep the callbacks current (SwiftUI hands us fresh closures each pass).
        context.coordinator.onResize = onContainerResize
        context.coordinator.onResync = onResync

        let current = container.subviews.first as? TerminalView
        let target = session?.terminalView

        // Same view already mounted — nothing to do.
        if current === target { return }

        // Swap out the previous terminal (if any).
        if let current {
            // Find the session that owns the outgoing view to pause its link.
            context.coordinator.mountedSession?.unmount()
            current.removeFromSuperview()
        }
        context.coordinator.mountedSession = nil

        // Mount the new terminal. No autoresizing mask: AppKit would resize the
        // mounted view at every frame of an animated window transition, reflowing
        // SwiftTerm at each intermediate size and bypassing the manager's coalesced
        // setSize path — which is the single source of frame changes for mounted
        // and detached terminals alike (task 9543).
        if let session, let target {
            // The LAST unguarded frame write in the app, and the one that bit: mounting
            // into a container that is collapsed, zero-width or mid-transition would set
            // the terminal's frame directly here, reflowing the buffer to a couple of
            // columns and bypassing setSize's floor entirely. Adopt the container's
            // geometry only when it is a usable terminal size; otherwise leave the view
            // at the good size it already has and let the next real frameDidChange
            // correct it through the coalesced path.
            if TerminalMetrics.isUsable(container.bounds.size) {
                target.frame = container.bounds
            }
            target.autoresizingMask = []
            container.addSubview(target)
            context.coordinator.mountedSession = session
            session.mount()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        /// The session whose view is currently mounted, so we can call `unmount`
        /// on it when swapping (the outgoing view's owning session isn't always
        /// the new `session` value).
        var mountedSession: TerminalSession?
        /// The hosted container view, so the sleep/wake + screen observers can read its
        /// real bounds at fire time. Weak — AppKit owns it.
        weak var container: NSView?
        /// Latest resize callback (refreshed each `updateNSView`).
        var onResize: ((CGSize) -> Void)?
        /// Latest resync callback (refreshed each `updateNSView`).
        var onResync: ((CGSize) -> Void)?
        /// Token for the container's frame-change observer, removed on dismantle.
        var frameObserver: NSObjectProtocol?
        /// Tokens for the sleep/wake + screen-reconfiguration observers.
        var wakeObserver: NSObjectProtocol?
        var screenObserver: NSObjectProtocol?
    }
}
