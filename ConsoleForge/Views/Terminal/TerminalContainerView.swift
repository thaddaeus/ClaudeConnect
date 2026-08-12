import SwiftUI

struct TerminalContainerView: View {
    @Environment(SessionStore.self) private var store
    @Environment(TabActivityTracker.self) private var activityTracker
    /// Owned by the app (see `ConsoleForgeApp`), not this view — the voice channel
    /// needs to reach a tab's PTY too.
    @Environment(TerminalSessionManager.self) private var manager
    @Environment(VoiceController.self) private var voice
    @State private var tabStates: [UUID: SessionState] = [:]

    var body: some View {
        // Reference activeTabID in body so the view recomputes (and the host
        // re-evaluates `session:`) whenever the active tab changes.
        let activeID = store.activeTabID

        HStack(spacing: 0) {
            terminalColumn(activeID: activeID)

            if voice.isPanelVisible {
                Divider()
                VoicePanel()
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: voice.isPanelVisible)
    }

    private func terminalColumn(activeID: UUID?) -> some View {
        VStack(spacing: 0) {
            // Tab bar
            if !store.terminalTabIDs.isEmpty {
                TerminalTabBar()
            }

            // Terminal area
            ZStack {
                if store.terminalTabIDs.isEmpty {
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
            // Sessions are created once the terminal area's size has SETTLED, not when
            // the first one arrives — see TerminalSessionManager.setSize.
            .onChange(of: manager.hasAppliedRealSize) { _, _ in reconcile() }
            .onChange(of: store.terminalTabIDs) { _, _ in reconcile() }
            .onChange(of: store.activeTabID) { _, newID in
                if let tabID = newID {
                    activityTracker.didFocusTab(tabID: tabID)
                }
                // Only the active tab is audible.
                voice.retargetToActiveTab()
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
    /// lockstep). The manager debounces and flips `hasAppliedRealSize` on the SETTLED
    /// size, which is what kicks the initial reconcile — so sessions are created already
    /// sized to the area they will actually occupy.
    private func handleSizeChange(_ size: CGSize) {
        // Same floor the manager applies, checked here too: a degenerate geometry must
        // not reach the resize path at all, or sessions would be BORN two columns wide
        // and a resumed history would flood in at that width.
        guard TerminalMetrics.isUsable(size) else { return }
        manager.setSize(size)
    }

    private func reconcile() {
        // Wait for a SETTLED size — otherwise sessions are born at the placeholder, or
        // at a transient mid-launch geometry, and reflow-corrupt. The manager's
        // hasAppliedRealSize re-invokes us when it lands.
        guard manager.hasAppliedRealSize else { return }
        manager.reconcile(
            // CONSOLE STRIP ONLY. A document tab has no PTY and must never reach
            // TerminalSession / ClaudeProcessBuilder (task 9736 criterion 11).
            openIDs: store.terminalTabIDs,
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
        for id in store.terminalTabIDs where tabStates[id] == nil {
            tabStates[id] = .running
        }
    }

    private func handleTermination(id: UUID, exitCode: Int32?) {
        tabStates[id] = .terminated(exitCode)
        activityTracker.didTerminate(tabID: id)
        // Only emit process-exit if the tab is still open (not already closed by
        // user or self-close, which would have emitted their own event).
        if store.terminalTabIDs.contains(id) {
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
