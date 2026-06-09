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

    func session(for id: UUID?) -> TerminalSession? {
        guard let id else { return nil }
        return sessions[id]
    }

    /// Bring the live session set in line with `openIDs`: shut down + drop any
    /// session whose id has left the open set, and create a session for any new
    /// id (applying the ephemeral-resume launch rule and wiring the callbacks).
    func reconcile(
        openIDs: [UUID],
        makeConfig: (UUID) -> SessionConfiguration?,
        isResuming: (UUID) -> Bool,
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
            guard let config = makeConfig(id) else { continue }
            let launchConfig = resolvedLaunchConfig(config, isResuming: isResuming(id))
            let session = TerminalSession(sessionID: id, configuration: launchConfig)
            wire(session, id: id, onOutput: onOutput, onBell: onBell, onTerminated: onTerminated)
            sessions[id] = session
        }
    }

    /// Tear down one session and recreate it (used by Restart). The replacement
    /// uses the given configuration verbatim and re-wires the callbacks.
    func restart(
        id: UUID,
        configuration: SessionConfiguration,
        onOutput: @escaping (UUID) -> Void,
        onBell: @escaping (UUID) -> Void,
        onTerminated: @escaping (UUID, Int32?) -> Void
    ) {
        sessions[id]?.shutdown()
        let session = TerminalSession(sessionID: id, configuration: configuration)
        wire(session, id: id, onOutput: onOutput, onBell: onBell, onTerminated: onTerminated)
        sessions[id] = session
    }

    func shutdownAll() {
        for session in sessions.values {
            session.shutdown()
        }
        sessions.removeAll()
    }

    private func resolvedLaunchConfig(_ config: SessionConfiguration, isResuming: Bool) -> SessionConfiguration {
        // Ephemeral tabs restored after app restart resume their Claude session.
        guard isResuming else { return config }
        var c = config
        c.continueSession = true
        c.initialPrompt = nil
        return c
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
