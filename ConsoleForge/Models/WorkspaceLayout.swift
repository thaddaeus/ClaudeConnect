import Foundation
import CoreGraphics

/// Movable content. A section lives in exactly one slot, or nowhere (closed).
///
/// Sections are named by ENGINE, not by role: "Safari" is the in-app WKWebView, and
/// Phase C's managed Chrome will be its own case alongside it. A generic "Browser"
/// label would go ambiguous the moment there are two of them. The raw values are the
/// persistence keys in `layout.json` — never rename them.
enum SectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case console
    case browser
    case webConsole

    var id: String { rawValue }

    var title: String {
        switch self {
        case .console: "Console"
        case .browser: "Safari"
        case .webConsole: "Web Output"
        }
    }

    /// What the section actually is, for tooltips and menu help.
    var detail: String? {
        switch self {
        case .console: nil
        case .browser: "In-app WebKit (WKWebView) — the engine Safari uses."
        case .webConsole: "console.* calls, errors and fetch/XHR requests captured from the Safari panel."
        }
    }

    var symbol: String {
        switch self {
        case .console: "terminal"
        case .browser: "safari"
        case .webConsole: "list.bullet.rectangle"
        }
    }

    /// The console is the app — it always occupies a slot and never floats
    /// (everything else floats *over* it).
    var isClosable: Bool { self != .console }
    var canFloat: Bool { self != .console }
}

/// The Y axis. Rows stack top → bottom and size themselves exactly like columns do,
/// as a fraction of the window HEIGHT or flexible. A row with nothing in it takes no
/// height at all, so a single-row layout is indistinguishable from the X-only one.
enum SlotRow: String, Codable, CaseIterable, Identifiable, Sendable {
    case top
    case bottom

    var id: String { rawValue }
    var title: String { self == .top ? "Top" : "Bottom" }
    var order: Int { self == .top ? 0 : 1 }
}

/// The X axis within a row.
enum SlotColumn: String, Codable, CaseIterable, Identifiable, Sendable {
    case left
    case center
    case right

    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: "Left"
        case .center: "Center"
        case .right: "Right"
        }
    }
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// A fixed position in the window: one cell of the row × column grid. A slot is
/// "available" when no section occupies it.
///
/// Flat cases rather than a struct of (row, column) so this stays a `String` enum —
/// the raw values are `layout.json` keys and every dictionary in the resolver is keyed
/// by them. Legacy files wrote the pre-Y names `left`/`center`/`right`; those decode
/// into the top row (see `SlotID.init(legacy:)`).
enum SlotID: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeft, topCenter, topRight
    case bottomLeft, bottomCenter, bottomRight

    var id: String { rawValue }

    var row: SlotRow {
        switch self {
        case .topLeft, .topCenter, .topRight: .top
        case .bottomLeft, .bottomCenter, .bottomRight: .bottom
        }
    }

    var column: SlotColumn {
        switch self {
        case .topLeft, .bottomLeft: .left
        case .topCenter, .bottomCenter: .center
        case .topRight, .bottomRight: .right
        }
    }

    static func at(_ row: SlotRow, _ column: SlotColumn) -> SlotID {
        SlotID.allCases.first { $0.row == row && $0.column == column }!
    }

    var title: String { "\(row.title) \(column.title)" }

    /// Left-to-right order WITHIN a row.
    var order: Int { column.order }

    /// Which window edge a section floating in this slot stays pinned to. Floating is
    /// a DOCKED overlay, not a free window: the panel keeps the edge its slot came
    /// from and only stops consuming layout space.
    var floatsToTrailingEdge: Bool { column == .right }

    /// Accepts the pre-Y names so an existing `layout.json` keeps working: a layout
    /// written before rows existed was all one row, and that row is the top one.
    init?(legacy raw: String) {
        if let exact = SlotID(rawValue: raw) { self = exact; return }
        switch raw {
        case "left": self = .topLeft
        case "center": self = .topCenter
        case "right": self = .topRight
        default: return nil
        }
    }
}

/// How a row sizes itself.
///
/// Deliberately NOT the slot model. **Pinning is a WIDTH concept only** — there is no
/// pinned/flexible switch on a row. A lone row simply FILLS the height; height is only
/// constrained once a second row sits under the first, and then this is the share each
/// takes. The row splitter is what sets it.
struct RowConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id: SlotRow
    /// Share of the window height, consulted only when more than one row is live.
    var heightFraction: Double

    init(id: SlotRow, heightFraction: Double? = nil) {
        self.id = id
        self.heightFraction = heightFraction ?? (id == .top ? 0.65 : 0.35)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let row = try c.decode(SlotRow.self, forKey: .id)
        id = row
        heightFraction = try c.decodeIfPresent(Double.self, forKey: .heightFraction)
            ?? (row == .top ? 0.65 : 0.35)
    }
}

/// Everything a single slot decides for itself. Size and display are independent,
/// and every slot carries its own copy — pinning is per-slot and combinatorial, not
/// one global policy with a single pinned pane.
struct SlotConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id: SlotID
    /// The section currently in this slot, or nil when the slot is available.
    var section: SectionKind?
    /// PINNED: `pinnedFraction` of the WINDOW. FLEXIBLE: absorbs leftover.
    var isPinned: Bool = false
    /// Fraction of the window width. Kept even while flexible so un-pinning and
    /// re-pinning returns to the last explicit size.
    var pinnedFraction: Double = 0.4
    /// FLOATING: overlays the tiled sections and consumes no layout space. The panel
    /// stays docked to its slot's edge and keeps `pinnedFraction` as its width.
    var isFloating: Bool = false
    /// COLLAPSED by choice — the user dragged past the minimum and released, hit the
    /// collapse control, or maximized a sibling. Distinct from the *forced* collapse
    /// `resolve` applies when the window is simply too narrow: that one is derived and
    /// evaporates when the window grows, this one persists until the user undoes it.
    var isCollapsed: Bool = false

    init(id: SlotID,
         section: SectionKind? = nil,
         isPinned: Bool = false,
         pinnedFraction: Double = 0.4,
         isFloating: Bool = false,
         isCollapsed: Bool = false) {
        self.id = id
        self.section = section
        self.isPinned = isPinned
        self.pinnedFraction = pinnedFraction
        self.isFloating = isFloating
        self.isCollapsed = isCollapsed
    }

    /// Tolerant decoding: a layout file written by an older build is missing keys a
    /// newer one adds, and the synthesized decoder would throw the whole layout away.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Legacy ids (pre-Y `left`/`center`/`right`) land in the top row.
        id = SlotID(legacy: try c.decode(String.self, forKey: .id)) ?? .topCenter
        section = try c.decodeIfPresent(SectionKind.self, forKey: .section)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        pinnedFraction = try c.decodeIfPresent(Double.self, forKey: .pinnedFraction) ?? 0.4
        isFloating = try c.decodeIfPresent(Bool.self, forKey: .isFloating) ?? false
        isCollapsed = try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
    }
}

/// One layout per window: which section sits in which slot, and how each slot sizes
/// and displays itself. Persisted whole.
struct WorkspaceLayout: Codable, Equatable, Sendable {
    var slots: [SlotConfiguration]
    var rows: [RowConfiguration]
    /// Last page the browser section had loaded, so reopening it lands back there.
    var browserURL: String?

    init(slots: [SlotConfiguration] = WorkspaceLayout.defaultSlots,
         rows: [RowConfiguration] = WorkspaceLayout.defaultRows,
         browserURL: String? = nil) {
        self.slots = slots
        self.rows = rows
        self.browserURL = browserURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slots = try c.decodeIfPresent([SlotConfiguration].self, forKey: .slots) ?? WorkspaceLayout.defaultSlots
        rows = try c.decodeIfPresent([RowConfiguration].self, forKey: .rows) ?? WorkspaceLayout.defaultRows
        browserURL = try c.decodeIfPresent(String.self, forKey: .browserURL)
        normalize()
    }

    /// Console in the top-centre slot, flexible and tiled. The bottom row is empty, so
    /// it takes no height — on screen this is identical to the pre-Y layout.
    static var defaultSlots: [SlotConfiguration] {
        SlotID.allCases.map { id in
            SlotConfiguration(id: id, section: id == .topCenter ? .console : nil)
        }
    }

    static var defaultRows: [RowConfiguration] {
        SlotRow.allCases.map { RowConfiguration(id: $0) }
    }

    subscript(row: SlotRow) -> RowConfiguration {
        get { rows.first { $0.id == row } ?? RowConfiguration(id: row) }
        set {
            if let idx = rows.firstIndex(where: { $0.id == row }) { rows[idx] = newValue }
            else { rows.append(newValue) }
        }
    }

    func slots(in row: SlotRow) -> [SlotConfiguration] {
        SlotID.allCases.filter { $0.row == row }.map { self[$0] }
    }

    // MARK: - Access

    subscript(id: SlotID) -> SlotConfiguration {
        get { slots.first { $0.id == id } ?? SlotConfiguration(id: id) }
        set {
            if let idx = slots.firstIndex(where: { $0.id == id }) {
                slots[idx] = newValue
            } else {
                slots.append(newValue)
            }
        }
    }

    /// The slot holding `section`, or nil when the section is closed.
    func slot(holding section: SectionKind) -> SlotConfiguration? {
        slots.first { $0.section == section }
    }

    func isOpen(_ section: SectionKind) -> Bool {
        slot(holding: section) != nil
    }

    var openSectionCount: Int {
        slots.filter { $0.section != nil }.count
    }

    /// Repair anything a hand-edited or older layout file could get wrong: exactly one
    /// config per slot, no section in two slots at once, the console always placed,
    /// and the console never floating.
    mutating func normalize() {
        var repaired: [SlotConfiguration] = []
        var seenSections: Set<SectionKind> = []
        for id in SlotID.allCases {
            var config = slots.first { $0.id == id } ?? SlotConfiguration(id: id)
            config.id = id
            if let section = config.section, !seenSections.insert(section).inserted {
                config.section = nil
            }
            config.pinnedFraction = min(max(config.pinnedFraction, WorkspaceLayout.minPinnedFraction), 1.0)
            if config.section?.canFloat == false { config.isFloating = false }
            if config.section == nil { config.isFloating = false; config.isCollapsed = false }
            repaired.append(config)
        }
        // The console must always have a home.
        if !seenSections.contains(.console) {
            let target = repaired.firstIndex { $0.section == nil } ?? 1
            repaired[target].section = .console
            repaired[target].isFloating = false
        }
        slots = repaired
        rows = SlotRow.allCases.map { row in
            var config = rows.first { $0.id == row } ?? RowConfiguration(id: row)
            config.id = row
            config.heightFraction = min(max(config.heightFraction, WorkspaceLayout.minPinnedFraction), 1.0)
            return config
        }
    }

    /// Bring a collapsed slot back, at the size it was collapsed AT.
    ///
    /// A PIN SURVIVES A COLLAPSE — collapsing is a visibility change, not a licence to
    /// rewrite the sizing rule, and holding an exact fraction is the entire point of
    /// pinning. The pin is only raised to the section's floor, so a slot cannot expand
    /// straight back into a forced collapse. Pinned neighbours and reserved gaps are
    /// then scaled down until there is room, because this is the only escape from a rail
    /// and it has to always succeed.
    mutating func expand(_ id: SlotID, minFraction: Double) {
        self[id].isCollapsed = false
        // A floating panel overlays: it needs no room made for it and must not be
        // re-docked into the tiled flow.
        guard !self[id].isFloating else { return }

        let want: Double
        if self[id].isPinned {
            want = Swift.max(self[id].pinnedFraction, minFraction)
            self[id].pinnedFraction = want
        } else {
            want = minFraction
        }

        // Reserved gaps claim width exactly like pinned sections, so they belong in this
        // sum too — otherwise a hole could crowd the restored slot straight back into a
        // collapse. Collapsed neighbours claim nothing and are excluded.
        let others = slots.filter { $0.id != id && !$0.isFloating && $0.isPinned && !$0.isCollapsed }
        let sum = others.reduce(0.0) { $0 + $1.pinnedFraction }
        let budget = Swift.max(0, 1.0 - want)
        if sum > budget, sum > 0 {
            let scale = budget / sum
            for other in others {
                self[other.id].pinnedFraction =
                    Swift.max(other.pinnedFraction * scale, WorkspaceLayout.minPinnedFraction)
            }
        }
    }

    static let minPinnedFraction: Double = 0.02
    /// Fallback floor for a section that declares no minimum of its own.
    static let minSlotWidth: CGFloat = 240
    /// Fallback floor for a row whose sections declare no minimum height.
    static let minRowHeight: CGFloat = 140
    /// Width of the rail a collapsed section leaves behind.
    ///
    /// Width of the RAIL STRIPE down the right edge. Every collapsed section — from any
    /// slot, tiled or floating — becomes a tab in this one stripe, the way an IDE's tool
    /// windows do. One stripe, not one strip per slot, so collapsing more panels never
    /// eats more width.
    ///
    /// The stripe is reserved space: the tiled layout, the gaps and the floating
    /// overlays all stop at its leading edge, so "full width" means full width of the
    /// content area and nothing is ever drawn underneath a rail.
    static let collapsedRailWidth: CGFloat = 34
    /// Height of one tab in the stripe, stacked from the top.
    static let collapsedRailHeight: CGFloat = 148

    // MARK: - Size arithmetic

    /// Resolve slots to frames in a workspace of `size`.
    ///
    /// The rules, in order:
    /// 1. A pinned slot takes its exact fraction OF THE WINDOW — not of its siblings —
    ///    so it holds that fraction no matter how many neighbours it has, and keeps it
    ///    when one closes.
    /// 2. Leftover after all pins is split evenly among FLEXIBLE tiled slots.
    /// 3. With no flexible slot the leftover STAYS EMPTY; nothing stretches into it.
    ///    The empty space is placed at the positions of the slots that gave it up (a
    ///    floating slot leaves its former width behind as a gap), so pinned tiled
    ///    slots do not move when a neighbour is floated. Any remainder trails at the
    ///    right edge.
    /// 4. Pins summing over the available width scale down proportionally.
    /// 5. Flexible slots are guaranteed `minSlotWidth`; pins scale down to make room.
    /// 6. A slot that cannot reach its section's minimum width COLLAPSES to a rail
    ///    rather than rendering a uselessly narrow section. For the console that
    ///    minimum is a standard 80-column terminal (`TerminalMetrics.minimumWidth`) —
    ///    below it, output written to wrap at 80 wraps mid-word instead. The last
    ///    remaining tiled slot never collapses; something has to be on screen.
    ///
    /// `minWidths` is supplied by the view layer, which knows the terminal font.
    /// `minWidths` / `minHeights` are supplied by the view layer, which knows the
    /// terminal font.
    func resolve(in size: CGSize,
                 minWidths: [SectionKind: CGFloat] = [:],
                 minHeights: [SectionKind: CGFloat] = [:]) -> ResolvedWorkspaceLayout {
        var result = ResolvedWorkspaceLayout()
        guard size.width > 0, size.height > 0 else { return result }

        let occupied = slots.filter { $0.section != nil }
        let floatingCollapsed = Set(occupied.filter { $0.isFloating && $0.isCollapsed }.map(\.id))

        func floorWidth(_ slot: SlotConfiguration) -> CGFloat {
            slot.section.flatMap { minWidths[$0] } ?? WorkspaceLayout.minSlotWidth
        }
        func floorHeight(_ slot: SlotConfiguration) -> CGFloat {
            slot.section.flatMap { minHeights[$0] } ?? WorkspaceLayout.minRowHeight
        }

        // Slots the user collapsed on purpose start out collapsed — including the last
        // one. There used to be a "never leave the window empty" guard here that quietly
        // un-collapsed the console, which meant the collapse button did NOTHING whenever
        // the console was the only tiled section. A rail is always present and always
        // reversible, so an all-collapsed workspace is a legitimate place to be, not a
        // dead end. (The FORCED-collapse loop below keeps its own guard: a window merely
        // getting narrow must never hide your last panel.)
        var collapsed = Set(slots.filter { $0.section != nil && !$0.isFloating && $0.isCollapsed }.map(\.id))

        // Forced-collapse pass, now per ROW: a slot is starved by its own row's width,
        // not by the whole window. Bounded by the slot count.
        var widths: [SlotID: CGFloat] = [:]
        var heights: [SlotRow: CGFloat] = [:]
        var stripeWidth: CGFloat = 0
        var contentWidth: CGFloat = size.width
        while true {
            stripeWidth = (collapsed.isEmpty && floatingCollapsed.isEmpty)
                ? 0 : WorkspaceLayout.collapsedRailWidth
            contentWidth = max(0, size.width - stripeWidth)

            let liveRows = SlotRow.allCases.filter { row in
                slots(in: row).contains { slot in
                    (slot.section != nil && !slot.isFloating && !collapsed.contains(slot.id))
                        || (slot.section == nil && slot.isPinned)
                }
            }
            heights = rowHeights(live: liveRows, minHeights: minHeights, size: size)

            widths = [:]
            for row in liveRows {
                let inRow = slots(in: row)
                let active = inRow.filter { $0.section != nil && !$0.isFloating && !collapsed.contains($0.id) }
                let gaps = inRow.filter { $0.section == nil && $0.isPinned }
                widths.merge(tileWidths(active: active, gaps: gaps,
                                        contentWidth: contentWidth,
                                        windowWidth: size.width)) { a, _ in a }
            }

            var starvedID: SlotID?
            for row in liveRows {
                let active = slots(in: row).filter {
                    $0.section != nil && !$0.isFloating && !collapsed.contains($0.id)
                }
                guard active.count > 1 else { continue }
                if let starved = active.first(where: { (widths[$0.id] ?? 0) + 0.5 < floorWidth($0) }) {
                    starvedID = starved.id
                    break
                }
            }
            guard let starvedID else { break }
            collapsed.insert(starvedID)
        }
        result.railStripeWidth = stripeWidth

        // A slot that could not be collapsed — the last one standing in its row — must
        // still not be laid out below its floor. A lone console pinned at a tiny
        // fraction (a leftover from a splitter drag) was laid out at ~24pt, TWO COLUMNS,
        // and a resumed history flooding in at that width corrupts the SwiftTerm buffer
        // for good. Slots merely pinned small ALONGSIDE others are untouched, so a lone
        // 50% pin still leaves 50% empty.
        for row in SlotRow.allCases {
            let survivors = slots(in: row).filter {
                $0.section != nil && !$0.isFloating && !collapsed.contains($0.id)
            }
            guard survivors.count == 1, let only = survivors.first else { continue }
            let reserved = slots(in: row)
                .filter { $0.section == nil && $0.isPinned }
                .reduce(0) { $0 + (widths[$1.id] ?? 0) }
            widths[only.id] = min(max(widths[only.id] ?? 0, floorWidth(only)),
                                  max(0, contentWidth - reserved))
        }

        // Floating slots overlay the whole content area at full height — they are not
        // members of a row — docked to their slot's edge, consuming no layout space. A
        // full-width overlay stops at the rail stripe rather than running under it.
        for slot in occupied where slot.isFloating && !slot.isCollapsed {
            let width = min(max(CGFloat(slot.pinnedFraction) * size.width, floorWidth(slot)), contentWidth)
            let x = slot.id.floatsToTrailingEdge ? contentWidth - width : 0
            result.floating[slot.id] = CGRect(x: x, y: 0, width: width, height: size.height)
        }

        // Lay each row out in turn, running the X arithmetic inside it.
        var y: CGFloat = 0
        var previousRow: SlotRow?
        for row in SlotRow.allCases {
            guard let rowHeight = heights[row], rowHeight > 0 else { continue }
            if let previousRow {
                result.rowSplitters.append(RowSplitterPosition(above: previousRow, below: row, y: y))
            }
            var x: CGFloat = 0
            var previousTiled: SlotID?
            for id in SlotID.allCases where id.row == row {
                // Collapsed sections are tabs in the stripe, not positions in the flow.
                guard !collapsed.contains(id), let width = widths[id] else { continue }
                if self[id].section == nil {
                    // A reserved gap: real layout space, owned by a slot, holding a
                    // position open. Not a section, so no splitter runs across it.
                    result.gaps[id] = CGRect(x: x, y: y, width: width, height: rowHeight)
                    x += width
                    previousTiled = nil
                    continue
                }
                result.tiled[id] = CGRect(x: x, y: y, width: width, height: rowHeight)
                if let previousTiled {
                    result.splitters.append(SplitterPosition(leading: previousTiled, trailing: id,
                                                             x: x, y: y, height: rowHeight))
                }
                x += width
                previousTiled = id
            }
            result.emptyTrailingWidth = max(result.emptyTrailingWidth, contentWidth - x)
            y += rowHeight
            previousRow = row
        }
        result.rowHeights = heights

        // Collapsed sections are PARKED OFF-CANVAS at a usable size rather than squashed
        // to zero. A zero-width container is a degenerate geometry sitting one unguarded
        // frame write away from reflowing the SwiftTerm buffer to a couple of columns —
        // which is permanent. Parked off the left edge at real dimensions, the hosted
        // view keeps its identity AND a sane size, so collapse and expand cause no
        // reflow at all.
        for id in SlotID.allCases where collapsed.contains(id) || floatingCollapsed.contains(id) {
            let parkedWidth = max(floorWidth(self[id]), contentWidth)
            let parkedHeight = max(floorHeight(self[id]), heights[id.row] ?? size.height)
            result.parked[id] = CGRect(x: -(parkedWidth + 40), y: 0,
                                       width: parkedWidth, height: parkedHeight)
        }

        // The stripe: every collapsed section, wherever its slot sits, stacked as tabs
        // down the right edge. One stripe for the whole grid, not one per row.
        var tabY: CGFloat = 0
        for id in SlotID.allCases where collapsed.contains(id) || floatingCollapsed.contains(id) {
            let height = min(WorkspaceLayout.collapsedRailHeight, max(0, size.height - tabY))
            result.collapsed[id] = CGRect(x: contentWidth, y: tabY, width: stripeWidth, height: height)
            tabY += height
        }
        return result
    }

    /// The Y pass: how tall each live row is.
    ///
    /// A LONE ROW FILLS. Height is only constrained once a second row sits under the
    /// first — that is the whole rule, and it is why rows have no pinned/flexible
    /// switch: pinning is a width concept. With two rows live they split the height by
    /// their `heightFraction`, floored at the tallest minimum their sections declare
    /// (the console's is 24 terminal rows). If the floors cannot both fit, both scale
    /// down proportionally rather than one vanishing — a row is load-bearing.
    private func rowHeights(live: [SlotRow],
                            minHeights: [SectionKind: CGFloat],
                            size: CGSize) -> [SlotRow: CGFloat] {
        guard !live.isEmpty else { return [:] }
        guard live.count > 1 else { return [live[0]: size.height] }

        func floor(_ row: SlotRow) -> Double {
            let points = slots(in: row).compactMap(\.section)
                .map { minHeights[$0] ?? WorkspaceLayout.minRowHeight }.max()
                ?? WorkspaceLayout.minRowHeight
            return Double(points) / Double(size.height)
        }

        // Normalise the declared shares over the live rows, then raise each to its floor.
        let declared = live.reduce(0.0) { $0 + self[$1].heightFraction }
        var fractions: [SlotRow: Double] = [:]
        var floors: [SlotRow: Double] = [:]
        for row in live {
            let share = declared > 0 ? self[row].heightFraction / declared : 1.0 / Double(live.count)
            let f = Swift.min(floor(row), 1.0 / Double(live.count))
            floors[row] = f
            fractions[row] = Swift.max(share, f)
        }

        // Raising to floors can overflow. Take the excess from rows that have SLACK
        // above their own floor, proportionally — never by scaling everything down,
        // which would push a floored row straight back under its minimum. That is what
        // squeezed the console below 24 terminal rows when the row under it asked for
        // 95%. Only if the floors alone cannot fit does everything scale.
        var excess = fractions.values.reduce(0, +) - 1.0
        if excess > 0 {
            let slack = live.reduce(0.0) { $0 + Swift.max(0, (fractions[$1] ?? 0) - (floors[$1] ?? 0)) }
            if slack >= excess, slack > 0 {
                for row in live {
                    let rowSlack = Swift.max(0, (fractions[row] ?? 0) - (floors[row] ?? 0))
                    fractions[row] = (fractions[row] ?? 0) - excess * (rowSlack / slack)
                }
            } else {
                let total = fractions.values.reduce(0, +)
                if total > 0 { for (row, f) in fractions { fractions[row] = f / total } }
            }
            excess = 0
        }
        return fractions.mapValues { CGFloat($0) * size.height }
    }

    /// One sizing pass over the slots still tiled IN ONE ROW. Widths are computed purely
    /// as fractions of the window so they always sum to ≤ 1 — a slot is never widened
    /// past its share to meet a floor, because that would silently overflow the row.
    /// Falling short of the floor is what the collapse pass acts on instead.
    private func tileWidths(active: [SlotConfiguration],
                            gaps: [SlotConfiguration],
                            contentWidth: CGFloat,
                            windowWidth: CGFloat) -> [SlotID: CGFloat] {
        guard !active.isEmpty || !gaps.isEmpty, contentWidth > 0, windowWidth > 0 else { return [:] }
        // Fractions stay OF THE WINDOW, so a pinned 50% is still exactly 50% of the
        // window. The rail stripe only shrinks the BUDGET they have to fit inside — it
        // must never become the thing fractions are measured against, or every pin would
        // silently shrink the moment a panel collapsed.
        let budget = Double(contentWidth) / Double(windowWidth)

        let flexible = active.filter { !$0.isPinned }
        // Reserved gaps claim window space exactly like a pinned section does — that is
        // what stops a flexible neighbour swallowing the hole.
        var pinnedSum = (active.filter(\.isPinned) + gaps).reduce(0.0) { $0 + $1.pinnedFraction }

        // Reserve a share for the flexible slots, then fit the pins into what is left.
        // With no flexible slot `reserved` is 0 and this degenerates to the plain
        // over-100% proportional scale-down.
        let reserved = min(Double(flexible.count) * Double(WorkspaceLayout.minSlotWidth) / Double(windowWidth),
                           budget * 0.9)
        var pinScale = 1.0
        let pinBudget = max(0, budget - reserved)
        if pinnedSum > pinBudget, pinnedSum > 0 {
            pinScale = pinBudget / pinnedSum
            pinnedSum = pinBudget
        }

        let leftover = max(0, budget - pinnedSum)
        let flexEach = flexible.isEmpty ? 0 : leftover / Double(flexible.count)

        var widths: [SlotID: CGFloat] = [:]
        for slot in active + gaps {
            let fraction = slot.isPinned ? slot.pinnedFraction * pinScale : flexEach
            widths[slot.id] = CGFloat(fraction) * windowWidth
        }
        return widths
    }
}

/// A draggable vertical boundary between two adjacent tiled slots in one row.
struct SplitterPosition: Equatable, Identifiable {
    var leading: SlotID
    var trailing: SlotID
    var x: CGFloat
    /// The splitter only spans its own row.
    var y: CGFloat
    var height: CGFloat
    var id: String { "\(leading.rawValue)-\(trailing.rawValue)" }
}

/// A draggable horizontal boundary between two rows — the Y axis's splitter.
struct RowSplitterPosition: Equatable, Identifiable {
    var above: SlotRow
    var below: SlotRow
    var y: CGFloat
    var id: String { "\(above.rawValue)-\(below.rawValue)" }
}

struct ResolvedWorkspaceLayout: Equatable {
    /// Frames for occupied, tiled slots.
    var tiled: [SlotID: CGRect] = [:]
    /// Frames for occupied, floating slots (overlaid; consume no layout space).
    var floating: [SlotID: CGRect] = [:]
    /// Off-canvas frames for collapsed sections, at a usable width — see `renderFrame`.
    var parked: [SlotID: CGRect] = [:]
    /// Width of the right-edge rail stripe, 0 when nothing is collapsed. Everything
    /// else is laid out to the left of it.
    var railStripeWidth: CGFloat = 0
    /// Reserved empty space owned by a pinned, sectionless slot — a hole held open for
    /// a panel that is not there yet, and a drop target that fills it exactly.
    var gaps: [SlotID: CGRect] = [:]
    /// Rails for slots too narrow to render their section. The section stays alive and
    /// unresized behind the rail; clicking it restores the slot.
    var collapsed: [SlotID: CGRect] = [:]
    var splitters: [SplitterPosition] = []
    var rowSplitters: [RowSplitterPosition] = []
    /// Resolved height of each live row; absent rows have none and take no space.
    var rowHeights: [SlotRow: CGFloat] = [:]
    /// Widest leftover that no flexible slot absorbed in any row, rendered as empty
    /// space at the trailing edge.
    var emptyTrailingWidth: CGFloat = 0

    func frame(for id: SlotID) -> CGRect? {
        tiled[id] ?? floating[id]
    }

    /// Where a section should be RENDERED: its tile or float, or its off-canvas parking
    /// frame when collapsed.
    ///
    /// A collapsed section stays in the view tree — the hosted NSView (a live terminal,
    /// a loaded page) is never dismantled — and it stays at a USABLE width. It used to
    /// park at zero width, which left a degenerate container sitting one unguarded frame
    /// write away from reflowing the SwiftTerm buffer to a couple of columns. Parked off
    /// the left edge at a real width instead, collapsing and expanding cause no reflow
    /// at all.
    func renderFrame(for id: SlotID, height: CGFloat) -> CGRect? {
        tiled[id] ?? floating[id] ?? parked[id]
    }
}
