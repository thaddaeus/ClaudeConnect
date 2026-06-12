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
        guard size.width > 1, size.height > 1 else { return }
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
        context.coordinator.onResize = onContainerResize
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
        return container
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let obs = coordinator.frameObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        coordinator.frameObserver = nil
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Keep the resize callback current (SwiftUI hands us a fresh closure each pass).
        context.coordinator.onResize = onContainerResize

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
            target.frame = container.bounds
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
        /// Latest resize callback (refreshed each `updateNSView`).
        var onResize: ((CGSize) -> Void)?
        /// Token for the container's frame-change observer, removed on dismantle.
        var frameObserver: NSObjectProtocol?
    }
}
