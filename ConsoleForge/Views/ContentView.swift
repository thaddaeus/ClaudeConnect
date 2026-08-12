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
                // The detail area is the workspace: a slot container that hosts the
                // console (tab bar + terminals) and the browser. Layout is per-window,
                // so switching console tabs never rearranges it.
                WorkspaceView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            // Auto-start is a LAUNCH concept: it opens a tab so a PTY comes up. A
            // document has no process to start (task 9736 criterion 11).
            for session in store.sessions where session.autoStart && session.isTerminal {
                store.openTab(sessionID: session.id)
            }
        }
        // A parent must not close out from under its children (Tadd's call, 2026-08-10).
        // Raised only when the children are DOCUMENT tabs, so existing terminal
        // worktree-tab grouping keeps its silent-orphan behaviour until that is
        // separately agreed (task 9736 criterion 12). Three buttons rather than two:
        // closing a tab is not reversible, so "changed my mind" has to be reachable.
        .confirmationDialog(
            "Close “\(store.pendingClose?.tabName ?? "")”?",
            isPresented: Binding(get: { store.pendingClose != nil },
                                 set: { if !$0 { store.cancelPendingClose() } }),
            titleVisibility: .visible,
            presenting: store.pendingClose
        ) { pending in
            Button("Close All", role: .destructive) {
                store.resolvePendingClose(closeChildren: true)
            }
            Button(pending.children.count == 1 ? "Keep It Open" : "Keep Them Open") {
                store.resolvePendingClose(closeChildren: false)
            }
            Button("Cancel", role: .cancel) { store.cancelPendingClose() }
        } message: { pending in
            let count = pending.children.count
            Text("\(count) \(count == 1 ? "document" : "documents") opened from this tab "
                 + "\(count == 1 ? "is" : "are") still open:\n"
                 + pending.childNames.joined(separator: "\n"))
        }
    }
}
