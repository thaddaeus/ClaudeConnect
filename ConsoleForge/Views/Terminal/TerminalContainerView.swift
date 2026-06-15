import SwiftUI

struct TerminalContainerView: View {
    @Environment(SessionStore.self) private var store
    @Environment(TabActivityTracker.self) private var activityTracker
    @State private var tabStates: [UUID: SessionState] = [:]
    @State private var manager = TerminalSessionManager()
    /// Gates session creation until the real terminal-area size is known, so sessions
    /// are never born at the placeholder size (whose reflow-on-mount corrupts the
    /// SwiftTerm buffer — especially for restored/--resume tabs).
    @State private var hasRealSize = false

    var body: some View {
        // Reference activeTabID in body so the view recomputes (and the host
        // re-evaluates `session:`) whenever the active tab changes.
        let activeID = store.activeTabID

        VStack(spacing: 0) {
            // Tab bar
            if !store.openTabIDs.isEmpty {
                TerminalTabBar()
            }

            // Terminal area
            ZStack {
                if store.openTabIDs.isEmpty {
                    emptyState
                } else {
                    TerminalHostView(session: manager.session(for: activeID),
                                     onContainerResize: handleSizeChange,
                                     onResync: { manager.resync(to: $0) })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Terminated overlay for the ACTIVE session only.
                    if let activeID,
                       case .terminated(let code)? = tabStates[activeID] {
                        terminatedOverlay(code: code, sessionID: activeID)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // Bootstrap the live terminal-area size: `initial: true` fires with the
                // first laid-out size so sessions are sized before they're created. The
                // authoritative ONGOING size source is the container NSView's
                // frameDidChange (see TerminalHostView.onContainerResize) — SwiftUI's
                // GeometryReader can miss the animated fullscreen transition.
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: proxy.size, initial: true) { _, newSize in
                            handleSizeChange(newSize)
                        }
                }
            }
            .onAppear { reconcile() }
            .onChange(of: store.openTabIDs) { _, _ in reconcile() }
            .onChange(of: store.activeTabID) { _, newID in
                if let tabID = newID {
                    activityTracker.didFocusTab(tabID: tabID)
                }
            }
        }
    }

    private func terminatedOverlay(code: Int32?, sessionID: UUID) -> some View {
        VStack(spacing: 12) {
            Text("Process exited with code \(code ?? -1)")
                .foregroundStyle(.secondary)
            Button("Restart") {
                restartSession(sessionID)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.7))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("ConsoleForge")
                .font(.title)
                .fontWeight(.semibold)
            Text("Create a session in the sidebar,\nthen double-click to launch.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("⌘N for new session")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Session lifecycle

    /// Bring the manager's live sessions in line with the open tabs, wiring the
    /// per-tab callbacks (output/bell/exit tracking + terminated overlay state +
    /// close event emission) exactly as the old per-tab `SwiftTermView` did.
    /// Feed the live terminal-area size to the manager (resizing all live sessions in
    /// lockstep). The first real size flips `hasRealSize` and kicks the initial
    /// reconcile, so sessions are created already sized to the real area.
    private func handleSizeChange(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        manager.setSize(size)
        if !hasRealSize {
            hasRealSize = true
            reconcile()
        }
    }

    private func reconcile() {
        // Wait for a real size — otherwise sessions would be born at the placeholder
        // size and reflow-corrupt on first mount. handleSizeChange re-invokes us.
        guard hasRealSize else { return }
        manager.reconcile(
            openIDs: store.openTabIDs,
            resolveLaunch: { id in store.resolveLaunch(for: id) },
            onOutput: { id in
                activityTracker.didReceiveOutput(
                    tabID: id,
                    isActive: store.activeTabID == id
                )
            },
            onBell: { id in
                activityTracker.didReceiveBell(
                    tabID: id,
                    isActive: store.activeTabID == id
                )
            },
            onTerminated: { id, exitCode in
                handleTermination(id: id, exitCode: exitCode)
            }
        )
        // Newly created sessions start running.
        for id in store.openTabIDs where tabStates[id] == nil {
            tabStates[id] = .running
        }
    }

    private func handleTermination(id: UUID, exitCode: Int32?) {
        tabStates[id] = .terminated(exitCode)
        activityTracker.didTerminate(tabID: id, exitCode: exitCode)
        // Only emit process-exit if the tab is still open (not already closed by
        // user or self-close, which would have emitted their own event).
        if store.openTabIDs.contains(id) {
            let tabName = store.session(for: id)?.name ?? "Unknown"
            TabEventWriter.emitClose(tabID: id, tabName: tabName, reason: .processExit, exitCode: exitCode)
        }
    }

    private func restartSession(_ sessionID: UUID) {
        guard let launch = store.resolveLaunch(for: sessionID) else { return }
        tabStates[sessionID] = .running
        manager.restart(
            id: sessionID,
            configuration: launch.config,
            resume: launch.resume,
            onOutput: { id in
                activityTracker.didReceiveOutput(
                    tabID: id,
                    isActive: store.activeTabID == id
                )
            },
            onBell: { id in
                activityTracker.didReceiveBell(
                    tabID: id,
                    isActive: store.activeTabID == id
                )
            },
            onTerminated: { id, exitCode in
                handleTermination(id: id, exitCode: exitCode)
            }
        )
    }
}
