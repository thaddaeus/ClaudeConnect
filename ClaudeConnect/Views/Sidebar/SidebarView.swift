import SwiftUI

struct SidebarView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    var body: some View {
        List {
            ForEach(store.folders) { folder in
                folderSection(folder)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    let session = store.addSession()
                    store.editingSessionID = session.id
                    openWindow(id: "session-editor")
                } label: {
                    Label("New Session", systemImage: "plus")
                }

                Button {
                    showNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            }
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                if !newFolderName.isEmpty {
                    store.addFolder(name: newFolderName)
                    newFolderName = ""
                }
            }
            Button("Cancel", role: .cancel) {
                newFolderName = ""
            }
        }
    }

    @ViewBuilder
    private func folderSection(_ folder: SessionFolder) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { folder.isExpanded },
                set: { _ in store.toggleFolder(id: folder.id) }
            )
        ) {
            let folderSessions = store.sessionsInFolder(folder.id)
            ForEach(folderSessions) { session in
                sessionRow(session)
            }
        } label: {
            HStack {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(folder.name)
                    .fontWeight(.medium)
                Spacer()
                Text("\(store.sessionsInFolder(folder.id).count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
            .contextMenu {
                Button("Rename...") {
                    let name = folder.name
                    store.renameFolder(id: folder.id, name: name)
                }
                if folder.id != store.folders.first?.id {
                    Divider()
                    Button("Delete Folder", role: .destructive) {
                        store.deleteFolder(id: folder.id)
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: SessionConfiguration) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.tabColor)
                .frame(width: 8, height: 8)

            Image(systemName: session.tabIconName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(session.name)
                .lineLimit(1)

            Spacer()

            if store.openTabIDs.contains(session.id) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            store.openTab(sessionID: session.id)
        }
        .contextMenu {
            Button("Open") {
                store.openTab(sessionID: session.id)
            }
            Button("Edit...") {
                store.editingSessionID = session.id
                openWindow(id: "session-editor")
            }
            Button("Duplicate") {
                store.duplicateSession(id: session.id)
            }
            Divider()
            Menu("Move to Folder") {
                ForEach(store.folders) { folder in
                    if folder.id != session.folderID {
                        Button(folder.name) {
                            var updated = session
                            updated.folderID = folder.id
                            store.updateSession(updated)
                        }
                    }
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                store.deleteSession(id: session.id)
            }
        }
    }
}
