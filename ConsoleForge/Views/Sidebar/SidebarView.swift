import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag & Drop Transfer

extension UTType {
    static let consoleForgeSession = UTType(exportedAs: "com.thaddaeus.consoleforge.session")
}

struct SessionTransfer: Codable, Transferable {
    let sessionID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .consoleForgeSession)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(SessionStore.self) private var store
    @Environment(TabActivityTracker.self) private var activityTracker
    @Environment(\.openWindow) private var openWindow
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renamingFolderID: UUID?
    @State private var renameFolderName = ""
    @State private var hoveredSessionID: UUID?
    @State private var dropTargetFolderID: UUID?
    @State private var draggingSessionID: UUID?
    @State private var dropTargetSessionID: UUID?

    var body: some View {
        List {
            ForEach(store.folders) { folder in
                folderSection(folder)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ProfileBar()
        }
        .onTapGesture {
            // Resign terminal first responder so text fields can receive input
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        // `.navigation` pins these to the LEADING edge, over the sidebar they act on.
        // Left on the default placement SwiftUI hands them to the window's unified
        // toolbar, which spreads across every pane — so New Folder drifted to the far
        // right of the window, nowhere near the list it creates a folder in, and got
        // worse with each pane added.
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    let session = store.addSession()
                    store.editingSessionID = session.id
                    openWindow(id: "session-editor")
                } label: {
                    // Both glyphs are from the `badge.plus` family, which is the grammar
                    // Apple uses for "create one of these" (Finder's New Folder is
                    // literally folder.badge.plus). A bare `plus` said "add something"
                    // without saying what, which is the same ambiguity as putting it in
                    // the wrong place. There is no terminal.badge.plus, so a session —
                    // which opens as its own working surface — takes the window glyph.
                    Label("New Session", systemImage: "macwindow.badge.plus")
                }
                .help("New session — a saved configuration you launch as a tab (⌘N)")

                Button {
                    showNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .help("New folder — a group to organise sessions in (⇧⌘N)")
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
        .alert("Rename Folder", isPresented: Binding(
            get: { renamingFolderID != nil },
            set: { if !$0 { renamingFolderID = nil } }
        )) {
            TextField("Folder name", text: $renameFolderName)
            Button("Rename") {
                if let id = renamingFolderID, !renameFolderName.isEmpty {
                    store.renameFolder(id: id, name: renameFolderName)
                }
                renamingFolderID = nil
            }
            Button("Cancel", role: .cancel) {
                renamingFolderID = nil
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
                    .onDrag {
                        draggingSessionID = session.id
                        return NSItemProvider(object: session.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: SessionDropDelegate(
                        sessionID: session.id,
                        folderID: folder.id,
                        store: store,
                        draggingSessionID: $draggingSessionID,
                        dropTargetSessionID: $dropTargetSessionID
                    ))
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
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(dropTargetFolderID == folder.id ? Color.accentColor.opacity(0.2) : .clear)
            )
            .onDrop(of: [.text], delegate: FolderDropDelegate(
                folderID: folder.id,
                store: store,
                draggingSessionID: $draggingSessionID,
                dropTargetFolderID: $dropTargetFolderID
            ))
            .contextMenu {
                Button("Rename...") {
                    renameFolderName = folder.name
                    renamingFolderID = folder.id
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
        let isHovered = hoveredSessionID == session.id
        return HStack(spacing: 8) {
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
                    .fill(activityTracker.activity(for: session.id).indicatorColor)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color.primary.opacity(0.06) : .clear)
        )
        .onHover { hovering in
            hoveredSessionID = hovering ? session.id : nil
        }
        .opacity(draggingSessionID == session.id ? 0.4 : 1)
        .overlay(alignment: .top) {
            if dropTargetSessionID == session.id {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
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
                            store.moveSession(id: session.id, toFolder: folder.id)
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

// MARK: - Drop Delegates

struct SessionDropDelegate: DropDelegate {
    let sessionID: UUID
    let folderID: UUID
    let store: SessionStore
    @Binding var draggingSessionID: UUID?
    @Binding var dropTargetSessionID: UUID?

    func dropEntered(info: DropInfo) {
        withAnimation(.easeInOut(duration: 0.15)) {
            dropTargetSessionID = sessionID
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropTargetSessionID == sessionID {
            withAnimation(.easeInOut(duration: 0.15)) {
                dropTargetSessionID = nil
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        if let dragging = draggingSessionID, dragging != sessionID {
            withAnimation(.easeInOut(duration: 0.2)) {
                store.reorderSession(id: dragging, toFolder: folderID, before: sessionID)
            }
        }
        draggingSessionID = nil
        dropTargetSessionID = nil
        return true
    }
}

struct FolderDropDelegate: DropDelegate {
    let folderID: UUID
    let store: SessionStore
    @Binding var draggingSessionID: UUID?
    @Binding var dropTargetFolderID: UUID?

    func dropEntered(info: DropInfo) {
        dropTargetFolderID = folderID
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropTargetFolderID == folderID {
            dropTargetFolderID = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        if let dragging = draggingSessionID {
            store.reorderSession(id: dragging, toFolder: folderID, before: nil)
        }
        draggingSessionID = nil
        dropTargetFolderID = nil
        return true
    }
}
