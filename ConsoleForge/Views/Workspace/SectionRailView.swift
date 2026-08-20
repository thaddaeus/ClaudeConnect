import SwiftUI

/// The always-on rail down the trailing edge: one row per SECTION, in every state.
///
/// WHY IT IS ALWAYS THERE. Section headers only appear once a second section is open
/// (`LayoutStore.showsSectionChrome`), so from the default state — a lone console —
/// the window used to reveal nothing at all: no header, no rail, and therefore no hint
/// that slots, Safari, Web Output or Documents exist. The whole slot feature was
/// reachable only from the menu bar, which you have to already know about. The rail is
/// the fix: every section has a row here whether it is on screen, parked, or closed, so
/// one click opens it and the layout controls never vanish.
///
/// IT COSTS THE CONSOLE NOTHING. The stripe it draws into is already reserved by
/// `WorkspaceLayout.resolve` — `railStripeWidth` has been a permanent gutter since the
/// jump-on-collapse fix, and it is `collapsedRailWidth` wide whether or not anything is
/// collapsed. This view fills that gutter; it does not widen it, and it never touches a
/// frame. That is also why opening or closing a section cannot move the console: the
/// rail's width is a constant, not a function of what is open.
///
/// IT REPLACES THE PER-COLLAPSED-SECTION TAB rather than sitting beside it. Two
/// representations of the same collapsed section could not both fit in a 34pt stripe,
/// and a fixed list of four rows reads better than tabs that appear and disappear.
/// Collapse itself is unchanged: the section is still parked off-canvas at its last
/// live size and still restored by one click — the click just lands on its rail row.
struct SectionRailView: View {
    let layout: LayoutStore
    /// Width of the reserved stripe, straight from the resolver. Never computed here.
    let width: CGFloat
    let height: CGFloat

    /// A rail row is the full width of the stripe by `rowHeight` tall — a 34 × 34pt hit
    /// rectangle. That is bigger in BOTH axes than any control this app already ships
    /// (the section header's buttons are 18×16 and 20×16 inside a 24pt bar) and than a
    /// standard AppKit push button (21pt tall). It is also not the 22pt rail that failed
    /// before: that one was 22pt WIDE and carried the entire header — pin, two size
    /// segments, menu, collapse, close — so each target was about 22×11pt. One control
    /// per row at 34×34 has 4.7× that area.
    static let rowHeight: CGFloat = 34
    private static let menuHeight: CGFloat = 30

    var body: some View {
        VStack(spacing: 2) {
            ForEach(SectionKind.allCases) { kind in
                row(kind)
            }

            Spacer(minLength: 0)

            layoutMenu
        }
        .padding(.vertical, 6)
        .frame(width: width, height: height, alignment: .top)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(alignment: .leading) { Divider() }
    }

    // MARK: - Rows

    private func row(_ kind: SectionKind) -> some View {
        let state = layout.railState(kind)
        return Button {
            layout.toggleVisible(kind)
        } label: {
            Image(systemName: kind.symbol)
                .font(.system(size: 14))
                .foregroundStyle(tint(state))
                .frame(width: width, height: Self.rowHeight)
                // The hit rectangle is the whole row, not the glyph.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(alignment: .center) { chip(state) }
        // The "it is parked, not gone" cue, and the same glyph the collapsed tab used.
        .overlay(alignment: .leading) {
            if state == .collapsed {
                Image(systemName: "chevron.compact.left")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 1)
            }
        }
        .contextMenu { SectionLayoutMenu(kind: kind, layout: layout) }
        .help(help(kind, state))
        .accessibilityLabel(kind.title)
        .accessibilityValue(accessibilityValue(state))
    }

    @ViewBuilder
    private func chip(_ state: LayoutStore.RailState) -> some View {
        switch state {
        case .visible:
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(0.18))
                .padding(.horizontal, 2)
        case .collapsed:
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.6))
                .padding(.horizontal, 2)
        case .closed:
            Color.clear
        }
    }

    private func tint(_ state: LayoutStore.RailState) -> Color {
        switch state {
        case .visible: .accentColor
        case .collapsed: .secondary
        // Not `.tertiary`: a closed section is the one the rail most needs to advertise,
        // so it stays legible rather than fading into the gutter.
        case .closed: .secondary
        }
    }

    private func accessibilityValue(_ state: LayoutStore.RailState) -> String {
        switch state {
        case .visible: "on screen"
        case .collapsed: "collapsed to the rail"
        case .closed: "closed"
        }
    }

    private func help(_ kind: SectionKind, _ state: LayoutStore.RailState) -> String {
        let action: String
        switch state {
        case .visible:
            action = "Click to collapse it to this rail — it stays loaded."
        case .collapsed:
            let from = layout.slot(holding: kind).map { " from \($0.id.title)" } ?? ""
            action = "Collapsed\(from). Click to bring it back."
        case .closed:
            action = "Click to open it."
        }
        guard let detail = kind.detail else { return "\(kind.title)\n\(action)" }
        return "\(kind.title) — \(detail)\n\(action)"
    }

    // MARK: - Menu

    /// The layout menu, in the window rather than only in the menu bar. With a lone
    /// console open this is the only place the arrangement controls exist on screen,
    /// which is the point of the whole rail.
    private var layoutMenu: some View {
        Menu {
            WorkspaceLayoutMenu(layout: layout)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12))
                .frame(width: width, height: Self.menuHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .frame(width: width, height: Self.menuHeight)
        .help("Layout options — arrange, pin, float or reset the panels")
        .accessibilityLabel("Layout options")
    }
}
