import SwiftUI

struct TerminalContainerView: View {
    @Environment(SessionStore.self) private var store
    @State private var tabStates: [UUID: SessionState] = [:]

    var body: some View {
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
                    ForEach(store.openTabIDs, id: \.self) { sessionID in
                        if let config = store.session(for: sessionID) {
                            terminalTab(for: config, sessionID: sessionID)
                                .opacity(store.activeTabID == sessionID ? 1 : 0)
                                .allowsHitTesting(store.activeTabID == sessionID)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func terminalTab(for config: SessionConfiguration, sessionID: UUID) -> some View {
        let state = tabStates[sessionID] ?? .idle

        ZStack {
            SwiftTermView(
                configuration: config,
                isActive: store.activeTabID == sessionID,
                onProcessTerminated: { exitCode in
                    tabStates[sessionID] = .terminated(exitCode)
                }
            )
            .onAppear {
                tabStates[sessionID] = .running
            }

            if case .terminated(let code) = state {
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
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("ClaudeConnect")
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

    private func restartSession(_ sessionID: UUID) {
        // Remove and re-add to force view recreation
        store.closeTab(sessionID: sessionID)
        tabStates.removeValue(forKey: sessionID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            store.openTab(sessionID: sessionID)
        }
    }
}
