import SwiftUI

/// The thin strip at the top of each section: a drag handle for moving the section
/// into another slot, and the layout menu. Only shown once there is more than one
/// section open (see `LayoutStore.showsSectionChrome`).
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

            pinToggle

            sizeBadge

            Spacer(minLength: 4)

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
        Button {
            if slot.isPinned {
                layout.makeFlexible(slot.id)
            } else {
                layout.pin(slot.id, fraction: currentFraction)
            }
        } label: {
            Image(systemName: slot.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 10))
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(slot.isPinned ? Color.accentColor : Color.secondary)
        .help(slot.isPinned
              ? "Pinned at \(Int((slot.pinnedFraction * 100).rounded()))% of the window — click to make it flexible again"
              : "Pin \(kind.title) at its current width. The slot keeps the pin when the section leaves, holding the space open.")
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
        } else if slot.isPinned {
            badge("\(Int((slot.pinnedFraction * 100).rounded()))%")
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
            Menu("Move to") {
                ForEach(SlotID.allCases) { target in
                    Button {
                        layout.move(kind, to: target)
                    } label: {
                        if let occupant = layout[target].section, occupant != kind {
                            Text("\(target.title) — swap with \(occupant.title)")
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
                    .disabled(!slot.isPinned)
                Divider()
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

/// Controls for a reserved gap — a pinned slot holding space open with nothing in it.
struct SlotGapMenu: View {
    let id: SlotID
    let layout: LayoutStore

    var body: some View {
        Text("\(id.title) — reserved at \(Int((layout[id].pinnedFraction * 100).rounded()))%")
        Divider()
        ForEach([0.25, 1.0 / 3.0, 0.5], id: \.self) { fraction in
            Button("Hold \(Int((fraction * 100).rounded()))%") { layout.pin(id, fraction: fraction) }
        }
        Divider()
        Button("Release this gap") { layout.makeFlexible(id) }
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
    }
}

/// Menu-bar entry point, so the layout is reachable even when the console is the
/// only open section (in which case no headers are drawn).
struct LayoutCommands: Commands {
    let layout: LayoutStore

    var body: some Commands {
        CommandMenu("Layout") {
            Button(layout.isOpen(.browser) ? "Hide Safari" : "Show Safari") {
                layout.toggle(.browser)
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])

            Button(layout.isOpen(.webConsole) ? "Hide Web Output" : "Show Web Output") {
                layout.toggle(.webConsole)
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])

            Divider()

            ForEach(SectionKind.allCases) { kind in
                Menu(kind.title) {
                    SectionLayoutMenu(kind: kind, layout: layout)
                }
            }

            Divider()

            Menu("Reserve a Gap") {
                ForEach(SlotID.allCases) { id in
                    if layout[id].section == nil {
                        Menu(id.title) { SlotGapMenu(id: id, layout: layout) }
                    }
                }
            }

            Divider()

            Button("Reset Layout") { layout.resetToDefault() }

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
