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

    func session(for id: UUID?) -> TerminalSession? {
        guard let id else { return nil }
        return sessions[id]
    }

    /// Update the live terminal-area size and keep every session (active + detached)
    /// in lockstep. Call this before `reconcile` so newly created sessions start at
    /// the real size rather than the placeholder.
    func setSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        currentSize = size
        if CFDebug.geometry {
            print("[geom] setSize container=\(Int(size.width))×\(Int(size.height)) sessions=\(sessions.count)")
        }
        for session in sessions.values {
            session.resize(to: size)
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

        // Mount the new terminal.
        if let session, let target {
            target.frame = container.bounds
            target.autoresizingMask = [.width, .height]
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
