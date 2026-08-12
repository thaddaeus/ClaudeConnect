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
    /// Lives at workspace scope, not inside the browser: the log outlives any one page
    /// and is read by a different section.
    @State private var webLog = WebConsoleLog()
    @State private var draggingSection: SectionKind?
    @State private var hoveredDropSlot: SlotID?
    @State private var splitterDrag: SplitterDrag?
    @State private var floatEdgeDrag: FloatEdgeDrag?
    @State private var dragFeedback: BoundaryFeedback = .free

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let resolved = layout.layout.resolve(in: size, minWidths: Self.minWidths)

            ZStack(alignment: .topLeading) {
                // Leftover that no flexible slot absorbed shows through here as
                // deliberate empty space (acceptance criterion 4).
                Color(nsColor: .underPageBackgroundColor)
                    .frame(width: size.width, height: size.height)

                if resolved.tiled.isEmpty && resolved.floating.isEmpty {
                    allCollapsedHint(resolved, size)
                }

                consoleSection(resolved, size)

                if layout.isOpen(.browser) {
                    browserSection(resolved, size)
                }

                if layout.isOpen(.webConsole) {
                    webConsoleSection(resolved, size)
                }

                reservedGaps(resolved, size)

                collapsedRails(resolved, size)

                splitterHandles(resolved, size)

                dragReadouts(resolved, size)

                if draggingSection != nil {
                    dropTargets(size)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            // Collapsed sections are parked off the left edge; clip so they cannot
            // paint over the sidebar.
            .clipped()
            // Publish the live geometry so the store can work out a section's minimum
            // fraction on its own — the header control, the context menu and the
            // menu-bar Layout menu then all reach the same answer without threading
            // geometry through three call sites.
            .onChange(of: size, initial: true) { _, newSize in
                layout.workspaceWidth = newSize.width
                layout.sectionMinWidths = Self.minWidths
            }
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
        [.console: TerminalMetrics.minimumWidth, .browser: 320, .webConsole: 300]
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

    @ViewBuilder
    private func webConsoleSection(_ resolved: ResolvedWorkspaceLayout, _ size: CGSize) -> some View {
        if let slot = layout.slot(holding: .webConsole),
           let rect = resolved.renderFrame(for: slot.id, height: size.height) {
            sectionFrame(kind: .webConsole, slot: slot, rect: rect, size: size) {
                WebConsoleSectionView(log: webLog)
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
                    currentFraction: size.width > 0 ? Double(rect.width / size.width) : 0,
                    draggingSection: $draggingSection
                )
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .clipped()
        .background(Color(nsColor: .windowBackgroundColor))
        .modifier(FloatingDecoration(isFloating: slot.isFloating))
        .overlay(alignment: slot.id.floatsToTrailingEdge ? .leading : .trailing) {
            if slot.isFloating {
                floatEdgeGrabber(slot.id, base: rect, in: size)
            }
        }
        .offset(x: rect.minX, y: rect.minY)
        // No .animation here on purpose: an animated slot rect would emit a frame per
        // tick straight into the terminal resize path.
        .zIndex(slot.isFloating ? 10 : 0)
    }

    /// Everything is collapsed into the stripe. Say so, rather than showing a blank
    /// window that reads as a crash.
    private func allCollapsedHint(_ resolved: ResolvedWorkspaceLayout, _ size: CGSize) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "sidebar.trailing")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("All panels are collapsed")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Pick one from the rail on the right to bring it back.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(width: max(0, size.width - resolved.railStripeWidth), height: size.height)
    }

    // MARK: - Reserved gaps

    /// A pinned, empty slot: a hole the user deliberately left open. It is real layout
    /// space owned by a slot, so it reads as a reserved position rather than a rendering
    /// bug, and dropping a section on it fills it at exactly that width. Once there is a
    /// document reader and a console-output panel, this is where they land.
    @ViewBuilder
    private func reservedGaps(_ resolved: ResolvedWorkspaceLayout, _ size: CGSize) -> some View {
        ForEach(SlotID.allCases) { id in
            if let rect = resolved.gaps[id] {
                let percent = Int((layout[id].pinnedFraction * 100).rounded())
                VStack(spacing: 3) {
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: 14))
                    Text("\(id.title) · \(percent)%")
                        .font(.system(size: 10, weight: .medium))
                    Text("reserved")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .frame(width: rect.width, height: rect.height)
                .background(Color(nsColor: .underPageBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor),
                                      style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .padding(4)
                }
                .contentShape(Rectangle())
                .help("\(id.title) is held open at \(percent)% for a panel to drop into. Right-click to release it.")
                .contextMenu { SlotGapMenu(id: id, layout: layout) }
                .onDrop(of: [.text],
                        isTargeted: Binding(get: { hoveredDropSlot == id },
                                            set: { hoveredDropSlot = $0 ? id : nil })) { _ in
                    guard let dragged = draggingSection else { return false }
                    layout.move(dragged, to: id)
                    endDrag()
                    return true
                }
                .offset(x: rect.minX, y: rect.minY)
                .zIndex(1)
            }
        }
    }

    // MARK: - Collapsed rails

    /// Collapsed sections become tabs in one stripe down the RIGHT edge, wherever their
    /// slot sits — the way an IDE parks its tool windows. The stripe is reserved space
    /// (see `railStripeWidth`), so nothing is ever drawn underneath a tab and its menu
    /// button cannot end up clipped by the window edge.
    @ViewBuilder
    private func collapsedRails(_ resolved: ResolvedWorkspaceLayout, _ size: CGSize) -> some View {
        if resolved.railStripeWidth > 0 {
            Rectangle()
                .fill(Color(nsColor: .underPageBackgroundColor))
                .frame(width: resolved.railStripeWidth, height: size.height)
                .overlay(alignment: .leading) { Divider() }
                .offset(x: size.width - resolved.railStripeWidth)
                .zIndex(13)
        }
        ForEach(SlotID.allCases) { id in
            if let rect = resolved.collapsed[id], let kind = layout[id].section {
                VStack(spacing: 6) {
                    Button {
                        layout.normal(id)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "chevron.compact.left")
                                .font(.system(size: 12, weight: .semibold))
                            Image(systemName: kind.symbol)
                                .font(.system(size: 13))
                            Text(kind.title)
                                .font(.system(size: 10, weight: .medium))
                                .fixedSize()
                                .rotationEffect(.degrees(90))
                                .frame(width: rect.width)
                                .padding(.vertical, 16)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Expand \(kind.title)")

                    Spacer(minLength: 0)

                    Menu {
                        SectionLayoutMenu(kind: kind, layout: layout)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: rect.width, height: 22)
                    .help("\(kind.title) layout options")
                }
                .padding(.vertical, 8)
                .foregroundStyle(.secondary)
                .frame(width: rect.width, height: rect.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .padding(.horizontal, 2)
                .contextMenu { SectionLayoutMenu(kind: kind, layout: layout) }
                .help(collapsedHelp(kind))
                .offset(x: rect.minX, y: rect.minY)
                .zIndex(14)
            }
        }
    }

    private func collapsedHelp(_ kind: SectionKind) -> String {
        let reason = kind == .console
            ? "narrower than a standard \(TerminalMetrics.standardColumns)-column terminal"
            : "too narrow to show"
        return "\(kind.title) is collapsed — \(reason). Click to restore, or use the controls above."
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
                        .fill(splitterColor(splitter))
                        .frame(width: splitterIsActive(splitter) ? 3 : 1)
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

    /// The splitter thickens and changes colour as the drag reaches a section's floor,
    /// so the resistance is visible at the pointer as well as in the readout.
    private func splitterIsActive(_ splitter: SplitterPosition) -> Bool {
        guard let id = dragFeedback.slot else { return false }
        return id == splitter.leading || id == splitter.trailing
    }

    private func splitterColor(_ splitter: SplitterPosition) -> Color {
        guard splitterIsActive(splitter) else { return Color(nsColor: .separatorColor) }
        return splitterActiveColor
    }

    private var splitterActiveColor: Color {
        if case .willCollapse = dragFeedback { return .orange }
        return .accentColor
    }

    private func splitterGesture(_ splitter: SplitterPosition,
                                 _ resolved: ResolvedWorkspaceLayout,
                                 _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard size.width > 0 else { return }
                let leadingMin = Self.minWidths[layout[splitter.leading].section ?? .console]
                    ?? WorkspaceLayout.minSlotWidth
                let trailingMin = Self.minWidths[layout[splitter.trailing].section ?? .console]
                    ?? WorkspaceLayout.minSlotWidth
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
                dragFeedback = layout.resizeBoundary(
                    leading: drag.leading,
                    trailing: drag.trailing,
                    leadingFraction: drag.leadingFraction + delta,
                    trailingFraction: drag.trailingFraction.map { $0 - delta },
                    windowWidth: size.width,
                    leadingMin: leadingMin,
                    trailingMin: trailingMin
                )
            }
            .onEnded { _ in
                // Collapse commits on RELEASE, never mid-drag: the section holds at its
                // minimum while the pointer runs past it, and only letting go hides it.
                if case .willCollapse(let id) = dragFeedback {
                    layout.collapse(id)
                }
                dragFeedback = .free
                splitterDrag = nil
            }
    }

    /// Live readout over each section adjacent to the splitter being dragged. For the
    /// console that is `cols × rows`, the only dimensions a terminal user thinks in —
    /// and it turns accented at the 80-column floor, so hitting the minimum is
    /// something you SEE rather than something that just happens.
    @ViewBuilder
    private func dragReadouts(_ resolved: ResolvedWorkspaceLayout, _ size: CGSize) -> some View {
        let subjects: [SlotID] = splitterDrag.map { [$0.leading, $0.trailing] }
            ?? floatEdgeDrag.map { [$0.slot] } ?? []
        if !subjects.isEmpty {
            ForEach(subjects, id: \.self) { id in
                if let rect = resolved.frame(for: id), let kind = layout[id].section {
                    readout(for: kind, rect: rect, isSubject: dragFeedback.slot == id)
                        .offset(x: rect.midX - 70, y: rect.midY - 18)
                        .frame(width: 140, height: 36)
                        .zIndex(20)
                }
            }
        }
    }

    private func readout(for kind: SectionKind, rect: CGRect, isSubject: Bool) -> some View {
        let collapsing = isSubject && { if case .willCollapse = dragFeedback { return true } else { return false } }()
        let atMin = isSubject && !collapsing
        let text: String
        if collapsing {
            text = "Release to hide"
        } else if kind == .console {
            // The terminal area is the slot minus the section header and the tab bar.
            let chrome = SectionHeaderView.height + 36
            text = "\(TerminalMetrics.columns(forWidth: rect.width)) × \(TerminalMetrics.rows(forHeight: max(0, rect.height - chrome)))"
        } else {
            text = "\(Int(rect.width)) pt"
        }
        return Text(text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(collapsing ? Color.orange : (atMin ? Color.accentColor : Color.black.opacity(0.7)),
                        in: Capsule())
            .overlay(alignment: .bottom) {
                if atMin {
                    Text(kind == .console ? "minimum — \(TerminalMetrics.standardColumns) columns" : "minimum")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                        .offset(y: 16)
                }
            }
    }

    // MARK: - Floating

    /// A floating panel is DOCKED: it keeps its slot's edge and full height, and only
    /// its width is adjustable. Dragging this grabber changes that width and nothing
    /// else — the tiled sections underneath are not consulted and do not move, which is
    /// the entire point of floating. Overshooting the floor collapses it to an edge rail
    /// on release, exactly like a tiled splitter.
    private func floatEdgeGrabber(_ id: SlotID, base: CGRect, in size: CGSize) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .overlay {
                Rectangle()
                    .fill(floatEdgeDrag?.slot == id ? splitterActiveColor : Color(nsColor: .separatorColor))
                    .frame(width: floatEdgeDrag?.slot == id ? 3 : 1)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard size.width > 0 else { return }
                        let drag: FloatEdgeDrag
                        if let existing = floatEdgeDrag,
                           existing.slot == id, existing.startX == value.startLocation.x {
                            drag = existing
                        } else {
                            drag = FloatEdgeDrag(slot: id, startX: value.startLocation.x,
                                                 fraction: Double(base.width / size.width))
                            floatEdgeDrag = drag
                        }
                        // Dragging the inner edge outward widens the panel; which
                        // direction that is depends on the edge it is docked to.
                        let delta = Double(value.translation.width / size.width)
                        let signed = id.floatsToTrailingEdge ? -delta : delta
                        dragFeedback = layout.resizeFloating(id, toFraction: drag.fraction + signed,
                                                             windowWidth: size.width)
                    }
                    .onEnded { _ in
                        if case .willCollapse(let collapsing) = dragFeedback {
                            layout.collapse(collapsing)
                        }
                        dragFeedback = .free
                        floatEdgeDrag = nil
                    }
            )
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
            if browser == nil { browser = BrowserModel(initialURL: layout.browserURL, log: webLog) }
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

    private struct FloatEdgeDrag {
        var slot: SlotID
        var startX: CGFloat
        /// The panel's width fraction when the drag began.
        var fraction: Double
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
