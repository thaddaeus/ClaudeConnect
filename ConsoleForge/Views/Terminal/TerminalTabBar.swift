import SwiftUI
import UniformTypeIdentifiers

struct TerminalTabBar: View {
    @Environment(SessionStore.self) private var store
    @Environment(TabActivityTracker.self) private var activityTracker
    @State private var hoveredTabID: UUID?
    @State private var draggingTabID: UUID?
    @State private var dropTargetTabID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(store.openTabIDs, id: \.self) { sessionID in
                    if let session = store.session(for: sessionID) {
                        tabButton(session: session, isActive: store.activeTabID == sessionID)
                            .onDrag {
                                draggingTabID = sessionID
                                return NSItemProvider(object: sessionID.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: TabDropDelegate(
                                tabID: sessionID,
                                store: store,
                                draggingTabID: $draggingTabID,
                                dropTargetTabID: $dropTargetTabID
                            ))
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 36)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func tabButton(session: SessionConfiguration, isActive: Bool) -> some View {
        let activity = activityTracker.activity(for: session.id)
        let isHovered = hoveredTabID == session.id
        return HStack(spacing: 6) {
            Circle()
                .fill(activity.attentionColor ?? session.tabColor)
                .frame(width: 8, height: 8)

            Image(systemName: session.tabIconName)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(session.name)
                .font(.system(size: 12))
                .lineLimit(1)

            Button {
                store.closeTab(sessionID: session.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isActive || isHovered ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            isActive
                ? Color(nsColor: .selectedControlColor).opacity(0.3)
                : (isHovered ? Color.primary.opacity(0.06) : .clear)
        )
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle()
                    .fill(session.tabColor)
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .leading) {
            if dropTargetTabID == session.id {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
            }
        }
        .opacity(draggingTabID == session.id ? 0.4 : 1)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredTabID = hovering ? session.id : nil
        }
        .onTapGesture {
            store.switchToTab(sessionID: session.id)
        }
        .contextMenu {
            if session.isEphemeral {
                Button {
                    store.saveEphemeralSession(id: session.id)
                } label: {
                    Label("Save to Sidebar", systemImage: "square.and.arrow.down")
                }

                Divider()
            }

            Button(role: .destructive) {
                store.closeTab(sessionID: session.id)
            } label: {
                Label("Close Tab", systemImage: "xmark")
            }
        }
    }
}

// MARK: - Tab Drop Delegate

struct TabDropDelegate: DropDelegate {
    let tabID: UUID
    let store: SessionStore
    @Binding var draggingTabID: UUID?
    @Binding var dropTargetTabID: UUID?

    func dropEntered(info: DropInfo) {
        withAnimation(.easeInOut(duration: 0.15)) {
            dropTargetTabID = tabID
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropTargetTabID == tabID {
            withAnimation(.easeInOut(duration: 0.15)) {
                dropTargetTabID = nil
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        if let dragging = draggingTabID, dragging != tabID {
            withAnimation(.easeInOut(duration: 0.2)) {
                store.moveTab(id: dragging, before: tabID)
            }
        }
        draggingTabID = nil
        dropTargetTabID = nil
        return true
    }
}
