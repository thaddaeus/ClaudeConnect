import SwiftUI

struct ContentView: View {
    @Environment(SessionStore.self) private var store
    @Environment(UpdateChecker.self) private var updateChecker
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            if updateChecker.updateAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("ClaudeConnect v\(updateChecker.latestVersion) is available.")
                        .fontWeight(.medium)
                    Button("Download") {
                        if let url = URL(string: updateChecker.downloadURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                    Button {
                        updateChecker.updateAvailable = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.blue.opacity(0.15))
            }

            NavigationSplitView {
                SidebarView()
            } detail: {
                TerminalContainerView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            for session in store.sessions where session.autoStart {
                store.openTab(sessionID: session.id)
            }
        }
    }
}
