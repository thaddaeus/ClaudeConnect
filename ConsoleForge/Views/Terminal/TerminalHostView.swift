import SwiftUI
import SwiftTerm

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

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.autoresizingMask = [.width, .height]
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
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
    }
}
