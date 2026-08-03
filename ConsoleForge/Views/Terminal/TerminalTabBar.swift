import SwiftUI
import UniformTypeIdentifiers

struct TerminalTabBar: View {
    @Environment(SessionStore.self) private var store
    @Environment(TabActivityTracker.self) private var activityTracker
    @Environment(VoiceController.self) private var voice
    @State private var hoveredTabID: UUID?
    @State private var draggingTabID: UUID?
    @State private var dropTargetTabID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            tabStrip
            voiceToggle
        }
        .frame(height: 36)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var tabStrip: some View {
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
    }

    /// Shows/hides the voice sidecar. Lit green while something is being spoken, so the
    /// state is readable with the panel collapsed.
    private var voiceToggle: some View {
        Button {
            voice.isPanelVisible.toggle()
        } label: {
            Image(systemName: voice.speech.isSpeaking ? "waveform" : "speaker.wave.2")
                .font(.system(size: 12))
                .foregroundStyle(voiceToggleColor)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 6)
        .help(voice.isPanelVisible ? "Hide voice panel" : "Show voice panel")
    }

    private var voiceToggleColor: Color {
        if voice.speech.isSpeaking { return .green }
        return voice.isEnabled ? .primary : Color.secondary.opacity(0.5)
    }

    /// The parent tab's color when `session` is a grouped child whose parent is open.
    private func groupParentColor(for session: SessionConfiguration) -> Color? {
        guard let pid = session.parentTabID,
              store.openTabIDs.contains(pid),
              let parent = store.session(for: pid) else { return nil }
        return parent.tabColor
    }

    /// Whether the active tab is a grouped child of `session` — the parent's
    /// trailing edge dims so the focused child reads as sitting in front.
    private func isParentOfActiveTab(_ session: SessionConfiguration) -> Bool {
        guard let activeID = store.activeTabID, activeID != session.id,
              let active = store.session(for: activeID) else { return false }
        return active.parentTabID == session.id
    }

    /// Whether the active tab belongs to the group anchored at `parentID` —
    /// the parent itself or one of its grouped children. When focus leaves the
    /// group, its colors dim like any other inactive tab.
    private func groupHasFocus(parentID: UUID) -> Bool {
        guard let activeID = store.activeTabID else { return false }
        if activeID == parentID { return true }
        return store.session(for: activeID)?.parentTabID == parentID
    }

    /// Whether `session` is the last member of its group in tab order — the next
    /// tab is neither its parent nor a sibling child of the same parent.
    private func isLastInGroup(_ session: SessionConfiguration) -> Bool {
        guard let pid = session.parentTabID,
              let idx = store.openTabIDs.firstIndex(of: session.id) else { return false }
        let nextIdx = idx + 1
        guard nextIdx < store.openTabIDs.count else { return true }
        let nextID = store.openTabIDs[nextIdx]
        if nextID == pid { return false }
        if let next = store.session(for: nextID), next.parentTabID == pid { return false }
        return true
    }

    private func tabButton(session: SessionConfiguration, isActive: Bool) -> some View {
        let activity = activityTracker.activity(for: session.id)
        let isHovered = hoveredTabID == session.id
        let parentColor = groupParentColor(for: session)
        let capsGroup = parentColor != nil && isLastInGroup(session)
        let yieldsToChild = isParentOfActiveTab(session)
        return HStack(spacing: 6) {
            Circle()
                .fill(activity.statusDotColor)
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
        .overlay(alignment: .leading) {
            if dropTargetTabID == session.id {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            // Identity color: left+top+right outline (open bottom), dimmed when
            // inactive. A group parent whose CHILD has focus keeps left+top at
            // full strength (the group's anchor color) but dims its trailing
            // edge, so the focused child reads as sitting in front of it. When
            // focus leaves the group entirely the parent dims like any other
            // tab. The dot above is pure status; this is the tab's color. On
            // grouped children the outline shifts down (and, on the last tab of
            // a group, inward) to make room for the parent's stripe, and drops
            // its left edge so the group reads as one connected strip.
            TabIdentityOutline(cornerRadius: 4,
                               topInset: parentColor != nil ? 1.5 : 0,
                               trailingInset: capsGroup ? 1.5 : 0,
                               includeLeading: parentColor == nil,
                               includeTrailing: !yieldsToChild)
                .stroke(session.tabColor.opacity(isActive || yieldsToChild ? 1 : 0.4),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            if yieldsToChild {
                TabTrailingEdge(cornerRadius: 4,
                                topInset: parentColor != nil ? 1.5 : 0,
                                trailingInset: capsGroup ? 1.5 : 0)
                    .stroke(session.tabColor.opacity(0.4),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        .overlay {
            // Group linkage: a full-thickness band of the parent's color across
            // the top, stacked ABOVE the child's own identity color. Full
            // strength while focus is inside the group (so the group reads as
            // one continuous line), dimmed with the rest of the group when
            // focus is elsewhere. On the last tab of the group it turns the
            // corner and runs down the right edge, closing the group bracket.
            if let parentColor, let pid = session.parentTabID {
                TabGroupStripe(cornerRadius: 4, capTrailing: capsGroup)
                    .stroke(parentColor.opacity(groupHasFocus(parentID: pid) ? 1 : 0.4),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .butt))
            }
        }
        .opacity(draggingTabID == session.id ? 0.4 : 1)
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

// MARK: - Tab outline shapes

/// Left + top + right edges with rounded top corners and an OPEN bottom —
/// strokes a tab's identity color without closing the shape into a box.
/// `topInset`/`trailingInset` shift those edges inward so a group-parent stripe
/// can stack outside them at full thickness. With `includeLeading: false`
/// (grouped children) the left edge and top-left arc are dropped and the top
/// line starts flush at the tab's leading edge, connecting it to the tab
/// before it. With `includeTrailing: false` the path stops at the end of the
/// top edge so `TabTrailingEdge` can be stroked separately at a different
/// opacity.
struct TabIdentityOutline: Shape {
    var cornerRadius: CGFloat
    var topInset: CGFloat = 0
    var trailingInset: CGFloat = 0
    var includeLeading: Bool = true
    var includeTrailing: Bool = true

    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = 0.75 // keeps the 1.5pt stroke inside the tab's bounds
        let minX = rect.minX + inset
        let maxX = rect.maxX - inset - trailingInset
        let top = rect.minY + inset + topInset
        var p = Path()
        if includeLeading {
            p.move(to: CGPoint(x: minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: minX, y: top + cornerRadius))
            p.addArc(center: CGPoint(x: minX + cornerRadius, y: top + cornerRadius),
                     radius: cornerRadius,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        } else {
            p.move(to: CGPoint(x: rect.minX, y: top))
        }
        p.addLine(to: CGPoint(x: maxX - cornerRadius, y: top))
        guard includeTrailing else { return p }
        p.addArc(center: CGPoint(x: maxX - cornerRadius, y: top + cornerRadius),
                 radius: cornerRadius,
                 startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
        p.addLine(to: CGPoint(x: maxX, y: rect.maxY))
        return p
    }
}

/// The trailing portion of `TabIdentityOutline` — top-right arc + right edge —
/// as its own shape, so a group parent can dim just this edge while a child has
/// focus. Geometry mirrors `TabIdentityOutline` exactly.
struct TabTrailingEdge: Shape {
    var cornerRadius: CGFloat
    var topInset: CGFloat = 0
    var trailingInset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = 0.75
        let maxX = rect.maxX - inset - trailingInset
        let top = rect.minY + inset + topInset
        var p = Path()
        p.move(to: CGPoint(x: maxX - cornerRadius, y: top))
        p.addArc(center: CGPoint(x: maxX - cornerRadius, y: top + cornerRadius),
                 radius: cornerRadius,
                 startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
        p.addLine(to: CGPoint(x: maxX, y: rect.maxY))
        return p
    }
}

/// The group parent's stripe on a spawned tab: a full-width band across the very
/// top, sitting ABOVE the child's (down-shifted) identity outline. Runs edge to
/// edge so consecutive siblings' stripes read as one continuous line. With
/// `capTrailing` (last tab in the group) it rounds the top-right corner and runs
/// down the right edge, closing the group bracket.
struct TabGroupStripe: Shape {
    var cornerRadius: CGFloat
    var capTrailing: Bool

    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = 0.75 // centers the 1.5pt stroke inside the tab's bounds
        let y = rect.minY + inset
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: y))
        if capTrailing {
            let maxX = rect.maxX - inset
            p.addLine(to: CGPoint(x: maxX - cornerRadius, y: y))
            p.addArc(center: CGPoint(x: maxX - cornerRadius, y: y + cornerRadius),
                     radius: cornerRadius,
                     startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
            p.addLine(to: CGPoint(x: maxX, y: rect.maxY))
        } else {
            p.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return p
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
