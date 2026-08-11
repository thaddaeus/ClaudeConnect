import SwiftUI

/// The thin strip at the top of each section: a drag handle for moving the section
/// into another slot, and the layout menu. Only shown once there is more than one
/// section open (see `LayoutStore.showsSectionChrome`).
struct SectionHeaderView: View {
    let kind: SectionKind
    let slot: SlotConfiguration
    let layout: LayoutStore
    /// Set while this header is the drag source, so the workspace can raise its
    /// slot drop targets. Unused while floating.
    @Binding var draggingSection: SectionKind?
    /// Supplied only for a floating section: dragging its header repositions the
    /// overlay instead of reassigning its slot.
    var onFloatingMove: ((CGSize) -> Void)?
    var onFloatingMoveEnded: (() -> Void)?

    var body: some View {
        Group {
            if slot.isFloating, let onFloatingMove {
                bar.gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { onFloatingMove($0.translation) }
                        .onEnded { _ in onFloatingMoveEnded?() }
                )
            } else {
                bar.onDrag {
                    draggingSection = kind
                    return NSItemProvider(object: kind.rawValue as NSString)
                }
            }
        }
        .contextMenu {
            SectionLayoutMenu(kind: kind, layout: layout)
        }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.symbol)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(kind.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            sizeBadge

            Spacer(minLength: 4)

            Menu {
                SectionLayoutMenu(kind: kind, layout: layout)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)

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
            }
        }
        .padding(.horizontal, 8)
        .frame(height: SectionHeaderView.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .help(slot.isFloating
              ? "Drag to move the floating \(kind.title)"
              : "Drag to move \(kind.title) into another slot")
    }

    static let height: CGFloat = 24

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
                Button(slot.isFloating ? "Dock" : "Float over console") {
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

/// Menu-bar entry point, so the layout is reachable even when the console is the
/// only open section (in which case no headers are drawn).
struct LayoutCommands: Commands {
    let layout: LayoutStore

    var body: some Commands {
        CommandMenu("Layout") {
            Button(layout.isOpen(.browser) ? "Hide Browser" : "Show Browser") {
                layout.toggle(.browser)
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])

            Divider()

            ForEach(SectionKind.allCases) { kind in
                Menu(kind.title) {
                    SectionLayoutMenu(kind: kind, layout: layout)
                }
            }

            Divider()

            Button("Reset Layout") { layout.resetToDefault() }
        }
    }
}
