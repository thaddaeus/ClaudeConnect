import SwiftUI

struct SessionEditorWindow: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let sessionID = store.editingSessionID,
               let session = store.session(for: sessionID) {
                SessionEditorView(
                    session: session,
                    onSave: { updated in
                        store.updateSession(updated)
                        store.editingSessionID = nil
                        dismissWindow(id: "session-editor")
                    },
                    onSaveAndLaunch: { updated in
                        store.updateSession(updated)
                        store.openTab(sessionID: updated.id)
                        store.editingSessionID = nil
                        dismissWindow(id: "session-editor")
                    },
                    onCancel: {
                        store.editingSessionID = nil
                        dismissWindow(id: "session-editor")
                    }
                )
            } else {
                Text("No session selected")
                    .foregroundStyle(.secondary)
                    .frame(width: 520, height: 400)
            }
        }
        .onAppear {
            // Ensure this window can receive keyboard input (critical for swift run)
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: {
                    $0.identifier?.rawValue.contains("session-editor") == true
                        || $0.title == "Edit Session"
                }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}
