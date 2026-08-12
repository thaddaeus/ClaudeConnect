import SwiftUI
import AppKit

/// The window's slot container. Resolves the layout to frames and positions each
/// section into its slot.
///
/// TERMINAL SAFETY — the load-bearing rule of this file (tasks 9543 / 9487):
/// every section is rendered EXACTLY ONCE, at a structurally fixed position in the
/// ZStack, and moved only by changing its `.frame` + `.offset`. Nothing is ever
/// re-parented in the view tree, so `TerminalContainerView` (and the `WKWebView`)
/// keep their identity across every move, pin, float and splitter drag. The console's
/// container NSView reports its new bounds through the existing `frameDidChange`
/// path into `TerminalSessionManager.setSize`, which is still the SINGLE source of
/// frame changes for mounted terminal views and still coalesces on its 140 ms
/// trailing debounce. This file must never set a frame on a terminal view, and must
/// never animate a slot rect.
struct WorkspaceView: View {
    @Environment(LayoutStore.self) private var layout

    @State private var browser: BrowserModel?
    @State private var draggingSection: SectionKind?
    @State private var hoveredDropSlot: SlotID?
    @State private var splitterDrag: SplitterDrag?
    @State private var floatDrag: FloatDrag?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let resolved = layout.layout.resolve(in: size, minWidths: Self.minWidths)

            ZStack(alignment: .topLeading) {
                // Leftover that no flexible slot absorbed shows through here as
                // deliberate empty space (acceptance criterion 4).
                Color(nsColor: .underPageBackgroundColor)
                    .frame(width: size.width, height: size.height)

                consoleSection(resolved, size)

                if layout.isOpen(.browser) {
                    browserSection(resolved, size)
                }

                collapsedRails(resolved, size)

                splitterHandles(resolved, size)

                if draggingSection != nil {
                    dropTargets(size)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .onAppear(perform: syncBrowserModel)
        .onChange(of: layout.isOpen(.browser)) { _, _ in syncBrowserModel() }
        .onChange(of: browser?.currentURL) { _, url in
            if let url { layout.setBrowserURL(url) }
        }
    }

    // MARK: - Sections

    /// Per-section width floors handed to the layout engine. The console's is a
    /// standard 80-column terminal at the live font; below that it collapses to a rail
    /// instead of rendering a terminal too narrow to be read.
    private static var minWidths: [SectionKind: CGFloat] {
        [.console: TerminalMetrics.minimumWidth, .browser: 320]
    }

    private func consoleSection(_ resolved: ResolvedWorkspaceLayout, _ size: CGSize) -> some View {
        // The console always holds a slot (WorkspaceLayout.normalize guarantees it)
        // and never floats, so it always has a frame — zero-width while collapsed.
        let slot = layout.slot(holding: .console) ?? SlotConfiguration(id: .center, section: .console)
        let rect = resolved.renderFrame(for: slot.id, height: size.height)
            ?? CGRect(origin: .zero, size: size)
        return sectionFrame(kind: .console, slot: slot, rect: rect, size: size) {
            TerminalContainerView()
        }
    }

    @ViewBuilder
    private func browserSection(_ resolved: ResolvedWorkspaceLayout, _ size: CGSize) -> some View {
        if let slot = layout.slot(holding: .browser),
           let rect = resolved.renderFrame(for: slot.id, height: size.height),
           let browser {
            sectionFrame(kind: .browser, slot: slot, rect: rect, size: size) {
                BrowserSectionView(model: browser)
            }
        }
    }

    /// Chrome + geometry for one section. `rect` is in workspace coordinates.
    private func sectionFrame<Content: View>(
        kind: SectionKind,
        slot: SlotConfiguration,
        rect: CGRect,
        size: CGSize,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            if layout.showsSectionChrome {
                SectionHeaderView(
                    kind: kind,
                    slot: slot,
                    layout: layout,
                    draggingSection: $draggingSection,
                    onFloatingMove: slot.isFloating ? { translation in
                        moveFloating(slot.id, by: translation, base: rect, in: size)
                    } : nil,
                    onFloatingMoveEnded: { floatDrag = nil }
                )
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .clipped()
        .background(Color(nsColor: .windowBackgroundColor))
        .modifier(FloatingDecoration(isFloating: slot.isFloating))
        .overlay(alignment: .bottomTrailing) {
            if slot.isFloating {
                floatResizeHandle(slot.id, base: rect, in: size)
            }
        }
        .offset(x: rect.minX, y: rect.minY)
        // No .animation here on purpose: an animated slot rect would emit a frame per
        // tick straight into the terminal resize path.
        .zIndex(slot.isFloating ? 10 : 0)
    }

    // MARK: - Collapsed rails

    /// A section that cannot reach its minimum width is not rendered — but it is not
    /// gone either. It leaves a rail carrying its glyph, which is both the signal that
    /// it is still there and the way back. Without this, dragging a splitter too far
    /// would take the splitter with it and strand the section in the menus.
    @ViewBuilder
    private func collapsedRails(_ resolved: ResolvedWorkspaceLayout, _ size: CGSize) -> some View {
        ForEach(SlotID.allCases) { id in
            if let rect = resolved.collapsed[id], let kind = layout[id].section {
                Button {
                    layout.restore(id, minFraction: Double((Self.minWidths[kind]
                        ?? WorkspaceLayout.minSlotWidth) / max(size.width, 1)))
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 11))
                        Image(systemName: "chevron.compact.right")
                            .font(.system(size: 9))
                        Spacer()
                    }
                    .padding(.top, 6)
                    .frame(width: rect.width, height: rect.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .trailing) { Divider() }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(collapsedHelp(kind))
                .offset(x: rect.minX, y: rect.minY)
                .zIndex(4)
            }
        }
    }

    private func collapsedHelp(_ kind: SectionKind) -> String {
        let reason = kind == .console
            ? "narrower than a standard \(TerminalMetrics.standardColumns)-column terminal"
            : "too narrow to show"
        return "\(kind.title) is hidden — \(reason). Click to restore."
    }

    // MARK: - Splitters

    @ViewBuilder
    private func splitterHandles(_ resolved: ResolvedWorkspaceLayout, _ size: CGSize) -> some View {
        ForEach(resolved.splitters) { splitter in
            Rectangle()
                .fill(Color.clear)
                .frame(width: 8, height: size.height)
                .overlay {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1)
                }
                .contentShape(Rectangle())
                .offset(x: splitter.x - 4, y: 0)
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(splitterGesture(splitter, resolved, size))
                .zIndex(5)
        }
    }

    private func splitterGesture(_ splitter: SplitterPosition,
                                 _ resolved: ResolvedWorkspaceLayout,
                                 _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard size.width > 0 else { return }
                // Keyed by the gesture's start location as well as the splitter, because
                // dragging a section past its minimum collapses it — which removes this
                // splitter mid-gesture, so `onEnded` never fires and stale state would
                // otherwise be reused as the base for the next drag.
                let drag: SplitterDrag
                if let existing = splitterDrag,
                   existing.id == splitter.id,
                   existing.startX == value.startLocation.x {
                    drag = existing
                } else {
                    let leadingWidth = resolved.tiled[splitter.leading]?.width ?? 0
                    let trailingWidth = resolved.tiled[splitter.trailing]?.width ?? 0
                    drag = SplitterDrag(
                        id: splitter.id,
                        startX: value.startLocation.x,
                        leading: splitter.leading,
                        trailing: splitter.trailing,
                        leadingFraction: Double(leadingWidth / size.width),
                        // A flexible trailing slot absorbs the change on its own and
                        // must NOT be pinned by the drag.
                        trailingFraction: layout[splitter.trailing].isPinned
                            ? Double(trailingWidth / size.width) : nil
                    )
                    splitterDrag = drag
                }
                let delta = Double(value.translation.width / size.width)
                layout.resizeBoundary(
                    leading: drag.leading,
                    trailing: drag.trailing,
                    leadingFraction: drag.leadingFraction + delta,
                    trailingFraction: drag.trailingFraction.map { $0 - delta },
                    windowWidth: size.width
                )
            }
            .onEnded { _ in splitterDrag = nil }
    }

    // MARK: - Floating

    private func moveFloating(_ id: SlotID, by translation: CGSize, base: CGRect, in size: CGSize) {
        let origin = floatDrag?.origin ?? {
            let state = FloatDrag(slot: id, origin: base.origin)
            floatDrag = state
            return state.origin
        }()
        let moved = CGRect(x: origin.x + translation.width,
                           y: origin.y + translation.height,
                           width: base.width,
                           height: base.height)
        layout.setFloatingFrame(id, moved, in: size)
    }

    private func floatResizeHandle(_ id: SlotID, base: CGRect, in size: CGSize) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = floatDrag?.origin ?? {
                            let state = FloatDrag(slot: id, origin: CGPoint(x: base.width, y: base.height))
                            floatDrag = state
                            return state.origin
                        }()
                        let resized = CGRect(
                            x: base.minX,
                            y: base.minY,
                            width: max(WorkspaceLayout.minSlotWidth, start.x + value.translation.width),
                            height: max(180, start.y + value.translation.height)
                        )
                        layout.setFloatingFrame(id, resized, in: size)
                    }
                    .onEnded { _ in floatDrag = nil }
            )
            .padding(3)
    }

    // MARK: - Drag a section into a slot

    /// Raised only while a section header is being dragged. Empty slots have no frame
    /// of their own, so the workspace is divided into one drop zone per slot for the
    /// duration of the drag — that is what makes "move to ANY available slot" reachable
    /// by drag and not just by menu.
    private func dropTargets(_ size: CGSize) -> some View {
        HStack(spacing: 8) {
            ForEach(SlotID.allCases) { id in
                dropZone(id)
            }
        }
        .padding(10)
        .frame(width: size.width, height: size.height)
        .background(Color.black.opacity(0.18))
        .contentShape(Rectangle())
        .onTapGesture { endDrag() }
        .zIndex(50)
    }

    private func dropZone(_ id: SlotID) -> some View {
        let isTarget = hoveredDropSlot == id
        let occupant = layout[id].section
        return RoundedRectangle(cornerRadius: 8)
            .fill(isTarget ? Color.accentColor.opacity(0.30) : Color.black.opacity(0.25))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isTarget ? Color.accentColor : Color.white.opacity(0.5),
                                  style: StrokeStyle(lineWidth: isTarget ? 2 : 1, dash: [6, 4]))
            }
            .overlay {
                VStack(spacing: 4) {
                    Text(id.title)
                        .font(.system(size: 13, weight: .semibold))
                    if let occupant, occupant != draggingSection {
                        Text("swap with \(occupant.title)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else if occupant == nil {
                        Text("available")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.white)
            }
            .onDrop(of: [.text],
                    isTargeted: Binding(get: { hoveredDropSlot == id },
                                        set: { hoveredDropSlot = $0 ? id : nil })) { _ in
                guard let dragged = draggingSection else { return false }
                layout.move(dragged, to: id)
                endDrag()
                return true
            }
    }

    private func endDrag() {
        draggingSection = nil
        hoveredDropSlot = nil
    }

    // MARK: - Browser lifecycle

    /// The web view lives as long as the browser section is open. Closing the section
    /// releases it; reopening starts it back at the last page.
    private func syncBrowserModel() {
        if layout.isOpen(.browser) {
            if browser == nil { browser = BrowserModel(initialURL: layout.browserURL) }
        } else {
            browser = nil
        }
    }

    // MARK: - Drag state

    private struct SplitterDrag {
        var id: String
        var startX: CGFloat
        var leading: SlotID
        var trailing: SlotID
        var leadingFraction: Double
        var trailingFraction: Double?
    }

    private struct FloatDrag {
        var slot: SlotID
        var origin: CGPoint
    }
}

/// Border + shadow that make a floating section read as an overlay rather than a tile.
///
/// Deliberately branch-free: an `if isFloating { … } else { content }` would put the
/// section in a different arm of a `_ConditionalContent` per state, changing its
/// structural identity — so every float toggle would dismantle and rebuild the hosted
/// NSView (reloading the page, remounting a terminal). Same shape either way, only the
/// values change.
private struct FloatingDecoration: ViewModifier {
    let isFloating: Bool

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: isFloating ? 8 : 0))
            .overlay {
                RoundedRectangle(cornerRadius: isFloating ? 8 : 0)
                    .strokeBorder(isFloating ? Color(nsColor: .separatorColor) : .clear, lineWidth: 1)
            }
            .shadow(color: .black.opacity(isFloating ? 0.35 : 0),
                    radius: isFloating ? 14 : 0,
                    y: isFloating ? 6 : 0)
    }
}
