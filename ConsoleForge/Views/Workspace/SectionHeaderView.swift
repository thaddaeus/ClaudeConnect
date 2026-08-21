import SwiftUI

/// The thin strip at the top of each section: a drag handle for moving the section
/// into another slot, and the layout menu. Only shown once there is more than one
/// section open (see `LayoutStore.showsSectionChrome`) — a lone console still looks
/// exactly as it did before slots existed.
///
/// The header COEXISTS with the always-on rail (`SectionRailView`); the rail did not
/// replace it. The header is the drag source for moving a section between slots and it
/// carries pin-at-current-width, both of which need the section's live geometry and a
/// wide target — neither survives a 34pt stripe. The rail answers "what exists and how
/// do I get at it"; the header answers "how big is THIS one, and where does it go".
struct SectionHeaderView: View {
    let kind: SectionKind
    let slot: SlotConfiguration
    let layout: LayoutStore
    /// The section's live width as a fraction of the window, so the pin button can pin
    /// it exactly where it already is rather than snapping to a preset.
    let currentFraction: Double
    /// Set while this header is the drag source, so the workspace can raise its
    /// slot drop targets. Unused while floating.
    @Binding var draggingSection: SectionKind?
    @State private var isPickingSlot = false

    var body: some View {
        // One drag behaviour in every state. A floating panel is docked to its slot's
        // edge, so dragging its header into another slot RE-ANCHORS it — which is the
        // only positioning a docked overlay has.
        bar
        .onDrag {
            draggingSection = kind
            return NSItemProvider(object: kind.rawValue as NSString)
        }
        .contextMenu {
            SectionLayoutMenu(kind: kind, layout: layout)
        }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            // Icon only — the header strip is 24pt of stolen height, so the section's
            // kind is carried by its glyph (safari vs. terminal, and Phase C's Chrome
            // beside them). The full name lives in the tooltip and every menu.
            Image(systemName: kind.symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            sizeBadge

            Spacer(minLength: 4)

            placePicker

            // PIN IS A SIZING CONTROL — it fixes the width — so it lives with the other
            // sizing controls. It used to sit at the far LEFT of the bar with a Spacer
            // between it and the Normal / Full Width segments, which meant the one
            // control that decides how wide a panel is was the one you had to hunt for
            // (task 990039 §3).
            pinToggle

            sizeStateControl

            Menu {
                SectionLayoutMenu(kind: kind, layout: layout)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)

            // Collapse sits immediately before Close, because that is where the hand
            // goes to make a panel go away — reaching for ✕ and losing the whole panel
            // was the actual failure. Same glyph for every section: all rails park in
            // the right-edge stripe, so collapsing always means "push it that way".
            Button {
                layout.collapse(slot.id)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Collapse \(kind.title) to the right rail — it stays loaded")

            if kind.isClosable {
                Button {
                    layout.close(kind)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close \(kind.title) — discards it. Use ❯ to collapse instead.")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: SectionHeaderView.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { layout.collapse(slot.id) }
        .help(helpText)
    }

    /// Pin the section AT ITS CURRENT WIDTH, or release it back to flexible. This is
    /// the control that makes a hole: a pinned section keeps its exact fraction of the
    /// window, and the slot keeps that pin when the section is moved out or closed —
    /// so the space it held stays reserved for whatever drops in next.
    private var pinToggle: some View {
        let column = layout.column(slot.id.column)
        return Button {
            if column.isPinned {
                layout.makeFlexible(slot.id)
            } else {
                layout.pin(slot.id, fraction: currentFraction)
            }
        } label: {
            Image(systemName: column.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 10))
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(column.isPinned ? Color.accentColor : Color.secondary)
        .help(column.isPinned
              ? "The \(slot.id.column.title) column is pinned at \(Int((column.pinnedFraction * 100).rounded()))% of the window — click to make it flexible again"
              : "Pin the \(slot.id.column.title) column at this width. It holds that width for the cell above or below too, and keeps it when the panel is closed.")
    }

    /// The spatial way to move a section: a 2 × 3 picture of the grid rather than a
    /// list of nine text rows. Hovering a cell says exactly what would be displaced and
    /// where it would land, so a move is committed with its consequence already on
    /// screen (task 990039 §2).
    private var placePicker: some View {
        Button {
            isPickingSlot = true
        } label: {
            Image(systemName: "square.grid.3x2")
                .font(.system(size: 10))
                .frame(width: 20, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Place \(kind.title) — pick a cell of the grid")
        .popover(isPresented: $isPickingSlot, arrowEdge: .bottom) {
            SlotGridPicker(kind: kind, layout: layout, isPresented: $isPickingSlot)
        }
    }

    /// How big — Normal or Full Width — with the live state lit. Collapse is NOT a
    /// segment here: "how big" and "shown or hidden" are different questions, and
    /// having collapse buried among two lookalike glyphs is why ✕ got hit instead. It
    /// has its own button next to Close.
    private var sizeStateControl: some View {
        HStack(spacing: 0) {
            stateButton(.normal, symbol: "rectangle.split.2x1",
                        help: "\(kind.title) at its normal size")
            stateButton(.maximized, symbol: "arrow.left.and.line.vertical.and.arrow.right",
                        help: "\(kind.title) full width — collapses the other tiled sections")
        }
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
    }

    private func stateButton(_ state: LayoutStore.SizeState, symbol: String, help: String) -> some View {
        let isActive = layout.sizeState(slot.id) == state
        return Button {
            switch state {
            case .collapsed: layout.collapse(slot.id)
            case .normal:    layout.normal(slot.id)
            case .maximized: layout.maximize(slot.id)
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .frame(width: 20, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        .background(isActive ? Color(nsColor: .controlBackgroundColor) : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .help(help)
    }

    static let height: CGFloat = 24

    /// The header shows only a glyph, so the tooltip carries the section's name.
    private var helpText: String {
        let drag = slot.isFloating
            ? "Drag to re-anchor the floating \(kind.title) to another edge"
            : "Drag to move \(kind.title) into another slot"
        let fold = "Double-click to collapse"
        guard let detail = kind.detail else { return "\(kind.title)\n\(drag)\n\(fold)" }
        return "\(kind.title) — \(detail)\n\(drag)\n\(fold)"
    }

    @ViewBuilder
    private var sizeBadge: some View {
        if slot.isFloating {
            badge("Floating")
        } else if layout.column(slot.id.column).isPinned {
            badge("\(Int((layout.column(slot.id.column).pinnedFraction * 100).rounded()))%")
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color(nsColor: .quaternaryLabelColor), in: Capsule())
    }
}

/// The per-section layout controls, shared by the header menu, the header's context
/// menu, and the menu-bar Layout menu — one definition, three places.
struct SectionLayoutMenu: View {
    let kind: SectionKind
    let layout: LayoutStore

    private static let pinPresets: [Double] = [0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 0.75]

    var body: some View {
        if let slot = layout.slot(holding: kind) {
            // Named for what it does to the panel, and each row states the OUTCOME for
            // whatever is already there — "Top Right — Safari moves to Top Center" —
            // rather than the mechanism, which is what "swap with Safari" exposed. The
            // spatial picker in the section header shows the same thing as a picture.
            Menu("Place in") {
                ForEach(SlotID.allCases) { target in
                    Button {
                        layout.move(kind, to: target)
                    } label: {
                        if let displaced = layout.displacement(moving: kind, to: target) {
                            Text("\(target.title) — \(displaced.section.title) moves to \(displaced.destination.title)")
                        } else {
                            Text(target.title)
                        }
                    }
                    .disabled(target == slot.id)
                }
            }

            Menu("Size") {
                Button("Collapse") { layout.collapse(slot.id) }
                    .disabled(layout.sizeState(slot.id) == .collapsed)
                Button("Normal") { layout.normal(slot.id) }
                    .disabled(layout.sizeState(slot.id) == .normal)
                Button("Full Width") { layout.maximize(slot.id) }
                    .disabled(layout.sizeState(slot.id) == .maximized)
                Divider()
                Button("Flexible") { layout.makeFlexible(slot.id) }
                    .disabled(!layout.column(slot.id.column).isPinned)
                Divider()
                // "Pin at 50%" pins the COLUMN — width is a column property — so the
                // cell above or below this one is held to the same 50%. The menu name is
                // unchanged because it is what the geometry harness drives by name.
                ForEach(Self.pinPresets, id: \.self) { fraction in
                    Button("Pin at \(Int((fraction * 100).rounded()))%") {
                        layout.pin(slot.id, fraction: fraction)
                    }
                }
            }

            if kind.canFloat {
                Button(slot.isFloating ? "Dock into the layout" : "Float over the layout") {
                    layout.setFloating(slot.id, !slot.isFloating)
                }
            }

            if kind.isClosable {
                Divider()
                Button("Close \(kind.title)") { layout.close(kind) }
            }
        } else {
            Button("Open \(kind.title)") { layout.open(kind) }
        }
    }
}

/// Controls for an EMPTY CELL of the grid: what to put in it, and how wide its column
/// should be.
///
/// This replaced the old reserved-gap menu, because a reserved gap is no longer its own
/// concept — an empty cell of a live column already holds its space, and "reserved"
/// simply means that column is pinned with nothing in it.
struct SlotCellMenu: View {
    let id: SlotID
    let layout: LayoutStore

    var body: some View {
        let column = layout.column(id.column)
        Text(column.isPinned
             ? "\(id.title) — \(id.column.title) column held at \(Int((column.pinnedFraction * 100).rounded()))%"
             : "\(id.title) — \(id.column.title) column, flexible")
        Divider()
        ForEach(SectionKind.allCases) { kind in
            if !layout.isOpen(kind) {
                Button("Open \(kind.title) here") {
                    layout.open(kind)
                    layout.move(kind, to: id)
                }
            } else if layout.slot(holding: kind)?.id != id {
                Button("Move \(kind.title) here") { layout.move(kind, to: id) }
            }
        }
        Divider()
        ColumnWidthMenuItems(column: id.column, layout: layout)
    }
}

/// The width controls for one column, shared by the empty-cell menu and the Layout
/// menu's Columns submenu.
struct ColumnWidthMenuItems: View {
    let column: SlotColumn
    let layout: LayoutStore

    var body: some View {
        ForEach([0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0], id: \.self) { fraction in
            Button("Hold \(Int((fraction * 100).rounded()))%") { layout.pin(column, fraction: fraction) }
        }
        Button("Flexible") { layout.makeFlexible(column) }
            .disabled(!layout.column(column).isPinned)
    }
}

/// The arrangement half of the Layout menu: every section's own controls, the reserved
/// gaps, and Reset. Shared by the menu bar and by the rail's menu button, so the window
/// is never a poorer entry point than the menu bar — which is what task 990035 was
/// about. One definition, two places.
struct WorkspaceLayoutMenu: View {
    let layout: LayoutStore

    var body: some View {
        ForEach(SectionKind.allCases) { kind in
            Menu(kind.title) {
                SectionLayoutMenu(kind: kind, layout: layout)
            }
        }

        Divider()

        // Columns are the X axis of the grid and the only place a tiled width is
        // decided, so they get their own entry rather than hiding behind "reserve a
        // gap": pinning a column with nothing in it IS reserving the position, and
        // pinning one that holds a panel is how you stop it moving.
        Menu("Columns") {
            ForEach(SlotColumn.allCases) { column in
                Menu(layout.column(column).isPinned
                     ? "\(column.title) — \(Int((layout.column(column).pinnedFraction * 100).rounded()))%"
                     : "\(column.title) — flexible") {
                    ColumnWidthMenuItems(column: column, layout: layout)
                }
            }
        }

        Divider()

        Button("Reset Layout") { layout.resetToDefault() }
    }
}

/// Menu-bar entry point. The same controls also live in the workspace rail's menu
/// button (see `SectionRailView`), so they are reachable without the menu bar.
struct LayoutCommands: Commands {
    let layout: LayoutStore
    let store: SessionStore
    let chrome: ManagedChrome

    private var agentBrowserRunning: Bool {
        store.activeTabID.map { chrome.isRunning($0, .headless) } ?? false
    }

    var body: some Commands {
        CommandMenu("Layout") {
            Button(layout.isOpen(.browser) ? "Hide Safari" : "Show Safari") {
                layout.toggle(.browser)
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])

            // Chrome belongs HERE, beside the other browser, even though it is not a
            // slot section. Two commands, not one, because the two browsers exist for
            // different people: the window is for you, the headless one is for the agent
            // and deliberately has nothing to look at.
            Button("Open Browser Window") {
                guard let active = store.activeTabID else { return }
                chrome.open(tabID: active, mode: .windowed)
            }
            .keyboardShortcut("b", modifiers: [.command, .option])
            .disabled(store.activeTabID == nil || !chrome.isAvailable)

            Button(agentBrowserRunning ? "Stop Agent Browser" : "Start Agent Browser") {
                guard let active = store.activeTabID else { return }
                if chrome.isRunning(active, .headless) { chrome.terminate(active, .headless) }
                else { chrome.open(tabID: active, mode: .headless) }
            }
            .disabled(store.activeTabID == nil || !chrome.isAvailable)

            Button(layout.isOpen(.webConsole) ? "Hide Web Output" : "Show Web Output") {
                layout.toggle(.webConsole)
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])

            Button(layout.isOpen(.editor) ? "Hide Documents" : "Show Documents") {
                layout.toggle(.editor)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])

            Divider()

            WorkspaceLayoutMenu(layout: layout)

            // Beta only. Production ships no geometry buffer, no file handle, no HUD.
            if GeometryTrace.isEnabled {
                Divider()
                Button(GeometryTrace.shared.isOverlayVisible
                       ? "Hide Geometry Debug" : "Show Geometry Debug") {
                    GeometryTrace.shared.isOverlayVisible.toggle()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}


/// A 2 × 3 picture of the grid, for placing one section.
///
/// The list of nine "Top Left — swap with Console" rows it replaced exposed the
/// mechanism instead of the intent, and read as a warning rather than a choice (task
/// 990039 §2). Here the cells are laid out the way the window is, each shows what is in
/// it, and hovering one spells out what would be displaced and where it would land — so
/// the consequence is visible BEFORE the click, which is the part that was missing.
struct SlotGridPicker: View {
    let kind: SectionKind
    let layout: LayoutStore
    @Binding var isPresented: Bool

    @State private var hovered: SlotID?

    private var current: SlotID? { layout.slot(holding: kind)?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Place \(kind.title)")
                .font(.system(size: 12, weight: .semibold))

            VStack(spacing: 4) {
                ForEach(SlotRow.allCases) { row in
                    HStack(spacing: 4) {
                        ForEach(SlotID.allCases.filter { $0.row == row }) { cell($0) }
                    }
                }
            }

            // One line, always present so the popover does not resize as the pointer
            // moves across the grid.
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 230, height: 26, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private var caption: String {
        guard let hovered else { return "Pick where \(kind.title) should sit." }
        if hovered == current { return "\(kind.title) is already in \(hovered.title)." }
        if let displaced = layout.displacement(moving: kind, to: hovered) {
            return "\(kind.title) → \(hovered.title). \(displaced.section.title) moves to \(displaced.destination.title)."
        }
        return "\(kind.title) → \(hovered.title). Nothing else moves."
    }

    private func cell(_ id: SlotID) -> some View {
        let occupant = layout[id].section
        let isCurrent = id == current
        let isHovered = hovered == id
        return Button {
            layout.move(kind, to: id)
            isPresented = false
        } label: {
            VStack(spacing: 2) {
                Image(systemName: occupant?.symbol ?? "rectangle.dashed")
                    .font(.system(size: 13))
                Text(occupant?.title ?? id.title)
                    .font(.system(size: 9))
                    .lineLimit(1)
            }
            .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            .opacity(occupant == nil ? 0.65 : 1)
            .frame(width: 74, height: 44)
            .background(isHovered ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isCurrent ? Color.accentColor : Color(nsColor: .separatorColor),
                                  style: StrokeStyle(lineWidth: isCurrent ? 1.5 : 1,
                                                     dash: occupant == nil ? [4, 3] : []))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
        .accessibilityLabel("\(id.title)\(occupant.map { ", holding \($0.title)" } ?? ", empty")")
    }
}
