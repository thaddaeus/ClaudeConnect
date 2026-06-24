import SwiftUI

struct ContentView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Update notifications are handled by Sparkle (App menu →
            // "Check for Updates…" + scheduled background checks).
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
