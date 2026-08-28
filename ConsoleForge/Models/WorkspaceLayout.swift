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
    /// The `layout.json` key stays `editor` (the name the spec and every work note use)
    /// even though what shipped is a READ-ONLY viewer — renaming a persistence key to
    /// track a scope decision would orphan every saved layout. The user-facing name says
    /// what it does.
    case editor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .console: "Console"
        case .browser: "Safari"
        case .webConsole: "Web Output"
        case .editor: "Documents"
        }
    }

    /// What the section actually is, for tooltips and menu help.
    var detail: String? {
        switch self {
        case .console: nil
        case .browser: "In-app WebKit (WKWebView) — the engine Safari uses."
        case .webConsole: "console.* calls, errors and fetch/XHR requests captured from the Safari panel."
        case .editor: "Read-only file viewer. Each document tab is parented to the console tab it was opened from."
        }
    }

    var symbol: String {
        switch self {
        case .console: "terminal"
        case .browser: "safari"
        case .webConsole: "list.bullet.rectangle"
        case .editor: "doc.text"
        }
    }

    /// The console is the app — it always occupies a slot and never floats
    /// (everything else floats *over* it).
    var isClosable: Bool { self != .console }
    var canFloat: Bool { self != .console }

    /// The kind of tab this section's strip holds, if it owns one. A strip filters
    /// `openTabIDs` down to its own kind and enforces group contiguity inside that
    /// filtered list — there is no global contiguity to enforce once a parent and its
    /// children live in different strips (task 9736 criterion 10).
    var stripKind: ViewKind? {
        switch self {
        case .console: .terminal
        case .editor: .document
        case .browser, .webConsole: nil
        }
    }
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

/// The X axis — a REAL column, shared down every row.
///
/// A column has one x-position and one width for the whole window, so `bottomRight`
/// is genuinely under `topRight`. That is the entire point of task 990039: the names
/// promised a grid and the engine packed each row independently, so the right-hand
/// slot began at the left edge and a lone section in a row swallowed it. Width is a
/// property of THIS type (`ColumnConfiguration`), never of an individual cell.
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

/// How a COLUMN sizes itself. The X-axis twin of `RowConfiguration`, and the only
/// place a tiled width is decided.
///
/// Width lives here rather than on the cell because a column is shared: `topRight` and
/// `bottomRight` are the same column and must be the same width, or they are not a
/// grid. It also makes the old "reserved gap" a plain consequence rather than a second
/// concept — a PINNED column holds its fraction whether or not anything is in it, so
/// closing the only panel in a column leaves the hole exactly where it was.
struct ColumnConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id: SlotColumn
    /// PINNED: `pinnedFraction` of the WINDOW, held no matter what else is open.
    /// FLEXIBLE: an even share of whatever the pins leave over.
    var isPinned: Bool = false
    /// Fraction of the window width. Kept even while flexible so un-pinning and
    /// re-pinning returns to the last explicit size.
    var pinnedFraction: Double = 0.4

    init(id: SlotColumn, isPinned: Bool = false, pinnedFraction: Double = 0.4) {
        self.id = id
        self.isPinned = isPinned
        self.pinnedFraction = pinnedFraction
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(SlotColumn.self, forKey: .id)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        pinnedFraction = try c.decodeIfPresent(Double.self, forKey: .pinnedFraction) ?? 0.4
    }
}

/// Everything a single CELL decides for itself: what is in it, and whether that
/// content is floating or collapsed.
///
/// Deliberately NOT where width lives — that is `ColumnConfiguration`. A cell that
/// owned its own width is exactly what made `bottomRight` a different size and a
/// different position from `topRight`. The one width still kept here is the FLOATING
/// one, because a floating panel is an overlay docked to an edge and is not a member
/// of the grid at all.
struct SlotConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id: SlotID
    /// The section currently in this slot, or nil when the slot is available.
    var section: SectionKind?
    /// Width this section takes WHILE FLOATING, as a fraction of the window. The JSON
    /// key stays `pinnedFraction`: it is what pre-column files wrote, and renaming a
    /// persistence key to track a scope change would orphan every saved layout.
    var floatingFraction: Double = 0.4
    /// FLOATING: overlays the tiled sections and consumes no layout space. The panel
    /// stays docked to its slot's edge and keeps `floatingFraction` as its width.
    var isFloating: Bool = false
    /// COLLAPSED by choice — the user dragged past the minimum and released, hit the
    /// collapse control, or maximized a sibling. Distinct from the *forced* collapse
    /// `resolve` applies when the window is simply too narrow: that one is derived and
    /// evaporates when the window grows, this one persists until the user undoes it.
    var isCollapsed: Bool = false

    /// Pre-column files pinned each SLOT. Read on decode purely to seed the column
    /// pins (`WorkspaceLayout.adoptLegacySlotPins`) and never written back — it is
    /// absent from `CodingKeys`, so the synthesized encoder skips it.
    var legacyPinned: Bool = false

    init(id: SlotID,
         section: SectionKind? = nil,
         floatingFraction: Double = 0.4,
         isFloating: Bool = false,
         isCollapsed: Bool = false) {
        self.id = id
        self.section = section
        self.floatingFraction = floatingFraction
        self.isFloating = isFloating
        self.isCollapsed = isCollapsed
    }

    enum CodingKeys: String, CodingKey {
        case id, section, isFloating, isCollapsed
        case floatingFraction = "pinnedFraction"
    }

    /// Tolerant decoding: a layout file written by an older build is missing keys a
    /// newer one adds, and the synthesized decoder would throw the whole layout away.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Legacy ids (pre-Y `left`/`center`/`right`) land in the top row.
        id = SlotID(legacy: try c.decode(String.self, forKey: .id)) ?? .topCenter
        section = try c.decodeIfPresent(SectionKind.self, forKey: .section)
        floatingFraction = try c.decodeIfPresent(Double.self, forKey: .floatingFraction) ?? 0.4
        isFloating = try c.decodeIfPresent(Bool.self, forKey: .isFloating) ?? false
        isCollapsed = try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        legacyPinned = try LegacyPin(from: decoder).isPinned
    }

    /// The pre-column `isPinned` key, decoded through its own container so it can be
    /// read without appearing in `CodingKeys` (and therefore without being re-encoded).
    private struct LegacyPin: Decodable {
        var isPinned: Bool = false
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        }
        enum K: String, CodingKey { case isPinned }
    }
}

/// One layout per window: which section sits in which slot, and how each slot sizes
/// and displays itself. Persisted whole.
struct WorkspaceLayout: Codable, Equatable, Sendable {
    var slots: [SlotConfiguration]
    var rows: [RowConfiguration]
    var columns: [ColumnConfiguration]
    /// Last page the browser section had loaded, so reopening it lands back there.
    var browserURL: String?

    init(slots: [SlotConfiguration] = WorkspaceLayout.defaultSlots,
         rows: [RowConfiguration] = WorkspaceLayout.defaultRows,
         columns: [ColumnConfiguration] = WorkspaceLayout.defaultColumns,
         browserURL: String? = nil) {
        self.slots = slots
        self.rows = rows
        self.columns = columns
        self.browserURL = browserURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slots = try c.decodeIfPresent([SlotConfiguration].self, forKey: .slots) ?? WorkspaceLayout.defaultSlots
        rows = try c.decodeIfPresent([RowConfiguration].self, forKey: .rows) ?? WorkspaceLayout.defaultRows
        let storedColumns = try c.decodeIfPresent([ColumnConfiguration].self, forKey: .columns)
        columns = storedColumns ?? WorkspaceLayout.defaultColumns
        browserURL = try c.decodeIfPresent(String.self, forKey: .browserURL)
        // A pre-column file has no `columns` key at all. Its widths were per-slot, so
        // lift each pinned slot's fraction onto its column — a saved arrangement keeps
        // the widths it had instead of springing back to an even split (criterion 8).
        if storedColumns == nil { adoptLegacySlotPins() }
        normalize()
    }

    /// Seed the column pins from a pre-column layout file. The TOP row wins where both
    /// cells of a column were pinned: the top row is where every pre-Y layout lived, so
    /// it is the one the user actually sized.
    private mutating func adoptLegacySlotPins() {
        for column in SlotColumn.allCases {
            let candidates = SlotID.allCases
                .filter { $0.column == column }
                .sorted { $0.row.order < $1.row.order }
                .map { self[$0] }
            guard let pinned = candidates.first(where: { $0.legacyPinned }) else { continue }
            self[column].isPinned = true
            self[column].pinnedFraction = pinned.floatingFraction
        }
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

    /// Every column flexible. With only the centre one live, the console fills the
    /// content area exactly as it did before columns existed.
    static var defaultColumns: [ColumnConfiguration] {
        SlotColumn.allCases.map { ColumnConfiguration(id: $0) }
    }

    subscript(row: SlotRow) -> RowConfiguration {
        get { rows.first { $0.id == row } ?? RowConfiguration(id: row) }
        set {
            if let idx = rows.firstIndex(where: { $0.id == row }) { rows[idx] = newValue }
            else { rows.append(newValue) }
        }
    }

    subscript(column: SlotColumn) -> ColumnConfiguration {
        get { columns.first { $0.id == column } ?? ColumnConfiguration(id: column) }
        set {
            if let idx = columns.firstIndex(where: { $0.id == column }) { columns[idx] = newValue }
            else { columns.append(newValue) }
        }
    }

    func slots(in row: SlotRow) -> [SlotConfiguration] {
        SlotID.allCases.filter { $0.row == row }.map { self[$0] }
    }

    func slots(in column: SlotColumn) -> [SlotConfiguration] {
        SlotID.allCases.filter { $0.column == column }.map { self[$0] }
    }

    /// Does this column hold any section at all — on screen or merely collapsed?
    /// A column with nothing left in it is what `move` releases the pin on.
    /// Whether an empty cell should PAINT itself, as opposed to merely reserving space.
    ///
    /// Every live row x live column with nothing in it is a gap, so a single panel in the
    /// bottom row of one column makes gaps of the bottom cell of every OTHER live column
    /// too. Opening Web Output into bottomCenter turned a two-panel window into three
    /// labelled dashed rectangles — the grid announcing its own internal structure at the
    /// user, which is not information anyone asked for.
    ///
    /// So the space is still reserved (the columns must line up), but it is only DRAWN
    /// when drawing it says something:
    ///   * mid-drag, when it is a live drop target the pointer can aim at, or
    ///   * when the column is pinned and empty — a position deliberately held open, which
    ///     the user set and would otherwise have no evidence of.
    /// An incidental empty cell is neither, and stays quiet.
    static func shouldPaintGap(held: Bool, isDragging: Bool) -> Bool {
        held || isDragging
    }

    func isEmpty(_ column: SlotColumn) -> Bool {
        slots(in: column).allSatisfy { $0.section == nil }
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
            config.floatingFraction = min(max(config.floatingFraction, WorkspaceLayout.minPinnedFraction), 1.0)
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
        columns = SlotColumn.allCases.map { column in
            var config = columns.first { $0.id == column } ?? ColumnConfiguration(id: column)
            config.id = column
            config.pinnedFraction = min(max(config.pinnedFraction, WorkspaceLayout.minPinnedFraction), 1.0)
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

        let column = id.column
        let want: Double
        if self[column].isPinned {
            want = Swift.max(self[column].pinnedFraction, minFraction)
            self[column].pinnedFraction = want
        } else {
            want = minFraction
        }

        // Every other pinned column claims window width — including one that is merely
        // RESERVED (pinned with nothing in it), which is the successor of the old
        // pinned-empty slot. Scale them down until the restored column fits: this is
        // the only escape from a rail and it has to always succeed.
        let others = SlotColumn.allCases.filter { $0 != column && self[$0].isPinned }
        let sum = others.reduce(0.0) { $0 + self[$1].pinnedFraction }
        let budget = Swift.max(0, 1.0 - want)
        if sum > budget, sum > 0 {
            let scale = budget / sum
            for other in others {
                self[other].pinnedFraction =
                    Swift.max(self[other].pinnedFraction * scale, WorkspaceLayout.minPinnedFraction)
            }
        }
    }

    static let minPinnedFraction: Double = 0.02
    /// Fallback floor for a section that declares no minimum of its own.
    static let minSlotWidth: CGFloat = 240
    /// Fallback floor for a row whose sections declare no minimum height.
    static let minRowHeight: CGFloat = 140
    /// Width of the RAIL STRIPE down the right edge — the one constant this whole
    /// feature rests on.
    ///
    /// The stripe is ALWAYS reserved and is always exactly this wide: it holds one row
    /// per section whether that section is on screen, collapsed, or closed
    /// (`SectionRailView`). Because the width never varies with what is open, opening or
    /// closing a panel cannot move the console — the same reason the fractions are of
    /// the WINDOW rather than of whatever happens to be beside them.
    ///
    /// It is reserved space, not an overlay: the tiled layout, the gaps and the floating
    /// panels all stop at its leading edge, so "full width" means full width of the
    /// content area and nothing is ever drawn underneath the rail.
    ///
    /// 34pt gives each row a 34 × 34pt hit rectangle — see `SectionRailView.rowHeight`
    /// for why that is enough and why the old 22pt rail was not.
    static let collapsedRailWidth: CGFloat = 34

    // MARK: - Size arithmetic

    /// Resolve the grid to frames in a workspace of `size`.
    ///
    /// THE GRID IS REAL (task 990039). A column has ONE x and ONE width for the whole
    /// window, so `bottomRight` sits under `topRight` and a section dropped there does
    /// not slide to the left edge or swallow its row. The rules, in order:
    /// 1. A column is LIVE when any of its cells shows a section, or when the column is
    ///    PINNED — a pinned column holds its width with nothing in it, which is how a
    ///    position is reserved. A dead column takes no space at all, so the default
    ///    single-console layout still fills the window.
    /// 2. A pinned column takes its exact fraction OF THE WINDOW — not of its
    ///    neighbours — so it keeps that fraction when one of them closes.
    /// 3. Leftover after all pins is split evenly among FLEXIBLE live columns.
    /// 4. With no flexible column the leftover STAYS EMPTY, and it falls where the
    ///    MISSING columns are: `left` starts at the leading edge, `right` ends at the
    ///    trailing edge, `center` is centred between them. Pinning the right column to
    ///    50% therefore leaves the empty half on the LEFT.
    /// 5. Pins summing over the available width scale down proportionally; flexible
    ///    columns keep a `minSlotWidth` floor.
    /// 6. A cell that cannot reach its section's minimum width COLLAPSES to the rail
    ///    rather than rendering a useless sliver. For the console that minimum is a
    ///    standard 80-column terminal (`TerminalMetrics.minimumWidth`) — below it,
    ///    output written to wrap at 80 wraps mid-word instead. The last section on
    ///    screen never collapses; something has to be visible.
    /// 7. An EMPTY cell of a live column is a GAP: real space the grid owns, so no
    ///    neighbour can silently absorb what a named slot holds, and a drop lands there
    ///    exactly.
    ///
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
        func isVisible(_ id: SlotID) -> Bool {
            let slot = self[id]
            return slot.section != nil && !slot.isFloating && !collapsed.contains(id)
        }

        // The rail stripe is ALWAYS reserved, whether or not anything is collapsed.
        // Sizing it to the collapsed set made the whole layout jump — every panel
        // resized the moment one collapsed or expanded, which is exactly what pinning
        // exists to prevent. A permanent gutter costs 34pt once and keeps the geometry
        // stable through every collapse; it is also where further controls will go.
        let stripeWidth = WorkspaceLayout.collapsedRailWidth
        let contentWidth = max(0, size.width - stripeWidth)
        result.railStripeWidth = stripeWidth

        // Forced-collapse pass. A cell is starved by ITS COLUMN's width — the width
        // every other cell in that column also gets — so this is ONE pass over the grid
        // rather than one per row. Bounded by the slot count.
        var widths: [SlotColumn: CGFloat] = [:]
        var heights: [SlotRow: CGFloat] = [:]
        var liveColumns: [SlotColumn] = []
        var liveRows: [SlotRow] = []
        while true {
            let visible = Set(SlotID.allCases.filter(isVisible))
            liveColumns = SlotColumn.allCases.filter { column in
                self[column].isPinned || visible.contains { $0.column == column }
            }
            liveRows = SlotRow.allCases.filter { row in visible.contains { $0.row == row } }
            widths = columnWidths(live: liveColumns, contentWidth: contentWidth, windowWidth: size.width)
            heights = rowHeights(live: liveRows, visible: visible, minHeights: minHeights, size: size)

            guard visible.count > 1 else { break }
            guard let starved = SlotID.allCases.first(where: {
                visible.contains($0) && (widths[$0.column] ?? 0) + 0.5 < floorWidth(self[$0])
            }) else { break }
            collapsed.insert(starved)
        }

        // The last section standing cannot be collapsed, so its COLUMN is widened to the
        // section's floor instead. A lone console pinned at a tiny fraction (a leftover
        // from a splitter drag) was otherwise laid out at ~24pt — TWO COLUMNS — and a
        // resumed history flooding in at that width corrupts the SwiftTerm buffer for
        // good. Columns merely pinned small ALONGSIDE others are untouched, so a lone
        // 50% pin still leaves 50% empty.
        let visible = SlotID.allCases.filter(isVisible)
        if visible.count == 1, let only = visible.first {
            let reserved = liveColumns
                .filter { $0 != only.column }
                .reduce(0) { $0 + (widths[$1] ?? 0) }
            widths[only.column] = min(max(widths[only.column] ?? 0, floorWidth(self[only])),
                                      max(0, contentWidth - reserved))
        }

        // Column origins — rule 4. `left` is anchored to the leading edge and `right` to
        // the trailing one, so leftover width falls where the MISSING columns are rather
        // than always trailing off the right. This is what makes "Right" mean the right.
        let leftWidth = widths[.left] ?? 0
        let centerWidth = widths[.center] ?? 0
        let rightWidth = widths[.right] ?? 0
        var origins: [SlotColumn: CGFloat] = [:]
        origins[.left] = 0
        origins[.right] = max(leftWidth, contentWidth - rightWidth)
        let between = max(0, (origins[.right] ?? contentWidth) - leftWidth)
        origins[.center] = leftWidth + max(0, (between - centerWidth) / 2)
        for column in liveColumns {
            guard let width = widths[column], let x = origins[column] else { continue }
            result.columnFrames[column] = CGRect(x: x, y: 0, width: width, height: size.height)
        }

        // Floating slots overlay the whole content area at full height — they are not
        // members of the grid — docked to their slot's edge, consuming no layout space.
        // A full-width overlay stops at the rail stripe rather than running under it.
        for slot in occupied where slot.isFloating && !slot.isCollapsed {
            let width = min(max(CGFloat(slot.floatingFraction) * size.width, floorWidth(slot)), contentWidth)
            let x = slot.id.floatsToTrailingEdge ? contentWidth - width : 0
            result.floating[slot.id] = CGRect(x: x, y: 0, width: width, height: size.height)
        }

        // Walk the grid: a section where there is one, a GAP where the column is live
        // and the cell is not. The gap is the whole of rule 7 — the space a named slot
        // owns, held open, and a drop target that fills it exactly.
        //
        // A column holding exactly ONE section SPANS the live rows. Rows exist to divide
        // a column between two sections; where there is only one, there is nothing to
        // divide, and the row boundary was pure loss — Web Output alone in bottomCenter
        // made a bottom row that the left and right columns then had to leave empty, so
        // one panel cost two dead cells and shortened the console for nothing. This is
        // the same rule the engine already applies to a lone ROW filling the height,
        // finally applied per COLUMN.
        let visibleCells = Set(SlotID.allCases.filter(isVisible))
        var spanning: [SlotColumn: SlotID] = [:]
        for column in liveColumns {
            let inColumn = visibleCells.filter { $0.column == column && liveRows.contains($0.row) }
            if inColumn.count == 1, let only = inColumn.first { spanning[column] = only }
        }
        let liveHeight = liveRows.reduce(0) { $0 + (heights[$1] ?? 0) }
        // A row splitter divides a column between two sections. If EVERY live column
        // spans, it would be a handle that edits a number nothing renders.
        let anyColumnIsDivided = liveColumns.contains { spanning[$0] == nil }

        var y: CGFloat = 0
        var previousRow: SlotRow?
        for row in SlotRow.allCases {
            guard liveRows.contains(row), let rowHeight = heights[row], rowHeight > 0 else { continue }
            if let previousRow, anyColumnIsDivided {
                result.rowSplitters.append(RowSplitterPosition(above: previousRow, below: row, y: y))
            }
            for column in liveColumns {
                guard let width = widths[column], width > 0, let x = origins[column] else { continue }
                let id = SlotID.at(row, column)
                if let sole = spanning[column] {
                    // Emitted once, at full height; the column's other cell is consumed
                    // by the span and is NOT a gap — there is no space left to hold open.
                    if id == sole {
                        result.tiled[id] = CGRect(x: x, y: 0, width: width, height: liveHeight)
                    }
                    continue
                }
                let rect = CGRect(x: x, y: y, width: width, height: rowHeight)
                if isVisible(id) { result.tiled[id] = rect } else { result.gaps[id] = rect }
            }
            y += rowHeight
            previousRow = row
        }
        result.rowHeights = heights

        // ONE splitter per boundary between adjacent live columns, spanning every live
        // row — the boundary is at the same x in each of them, so a per-row handle would
        // be several controls for one number. Columns that are not touching (leftover
        // sitting between them) have no shared boundary and nothing to trade.
        let totalHeight = liveRows.reduce(0) { $0 + (heights[$1] ?? 0) }
        for (index, column) in liveColumns.enumerated() where index > 0 {
            let leading = liveColumns[index - 1]
            guard let x = origins[column], let leadingX = origins[leading],
                  let leadingWidth = widths[leading], totalHeight > 0 else { continue }
            guard abs((leadingX + leadingWidth) - x) < 0.5 else { continue }
            result.splitters.append(ColumnSplitterPosition(leading: leading, trailing: column,
                                                           x: x, y: 0, height: totalHeight))
        }

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

        // Collapsed sections used to get a tall tab of their own in the stripe, banded by
        // the row they came from. The rail now lists every section at a fixed position
        // whether it is collapsed or not, so a per-collapsed-section rect would be a
        // SECOND representation of the same thing inside a 34pt gutter. The rail reads
        // `isCollapsed` off the layout directly; the resolver owes it only the stripe
        // width, which never changes.
        return result
    }

    /// The Y pass: how tall each live row is.
    ///
    /// A LONE ROW FILLS. Height is only constrained once a second row sits under the
    /// first — that is the whole rule, and it is why rows have no pinned/flexible
    /// switch: pinning is a width concept. With two rows live they split the height by
    /// their `heightFraction`, floored at the tallest minimum their VISIBLE sections
    /// declare (the console's is 24 terminal rows). If the floors cannot both fit, both
    /// scale down proportionally rather than one vanishing — a row is load-bearing.
    private func rowHeights(live: [SlotRow],
                            visible: Set<SlotID>,
                            minHeights: [SectionKind: CGFloat],
                            size: CGSize) -> [SlotRow: CGFloat] {
        guard !live.isEmpty else { return [:] }
        guard live.count > 1 else { return [live[0]: size.height] }

        func floor(_ row: SlotRow) -> Double {
            let points = SlotID.allCases
                .filter { $0.row == row && visible.contains($0) }
                .compactMap { self[$0].section }
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

    /// One sizing pass over the LIVE COLUMNS. Widths are computed purely as fractions of
    /// the window so they always sum to ≤ 1 — a column is never widened past its share
    /// to meet a floor, because that would silently overflow the grid. Falling short of
    /// the floor is what the collapse pass acts on instead.
    private func columnWidths(live: [SlotColumn],
                              contentWidth: CGFloat,
                              windowWidth: CGFloat) -> [SlotColumn: CGFloat] {
        guard !live.isEmpty, contentWidth > 0, windowWidth > 0 else { return [:] }
        // Fractions stay OF THE WINDOW, so a pinned 50% is still exactly 50% of the
        // window. The rail stripe only shrinks the BUDGET they have to fit inside — it
        // must never become the thing fractions are measured against, or every pin would
        // silently shrink the moment a panel collapsed.
        let budget = Double(contentWidth) / Double(windowWidth)

        let flexible = live.filter { !self[$0].isPinned }
        var pinnedSum = live.filter { self[$0].isPinned }.reduce(0.0) { $0 + self[$1].pinnedFraction }

        // Reserve a share for the flexible columns, then fit the pins into what is left.
        // With no flexible column `reserved` is 0 and this degenerates to the plain
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

        var widths: [SlotColumn: CGFloat] = [:]
        for column in live {
            let config = self[column]
            let fraction = config.isPinned ? config.pinnedFraction * pinScale : flexEach
            widths[column] = CGFloat(fraction) * windowWidth
        }
        return widths
    }
}

/// A draggable vertical boundary between two adjacent live COLUMNS.
///
/// One handle for the whole boundary, spanning every live row: a column has a single
/// width, so a per-row splitter would be two controls editing one number — and the two
/// could be dragged to disagree, which is the class of bug the grid exists to remove.
struct ColumnSplitterPosition: Equatable, Identifiable {
    var leading: SlotColumn
    var trailing: SlotColumn
    var x: CGFloat
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
    /// Width of the right-edge rail stripe. Always reserved and always the same —
    /// `WorkspaceLayout.collapsedRailWidth` — so that opening, closing or collapsing a
    /// section can never change it, and therefore can never move the console. Everything
    /// else is laid out to the left of it.
    var railStripeWidth: CGFloat = 0
    /// EMPTY CELLS of live columns: the space a named slot owns with nothing in it, so
    /// no neighbour can absorb it, and a drop target that fills it exactly. A cell whose
    /// whole column is pinned and empty is a RESERVED position — the successor of the
    /// old pinned-empty slot.
    var gaps: [SlotID: CGRect] = [:]
    /// x and width of each live column, full window height. The grid's spine: every
    /// cell in a column takes its x and width from here.
    var columnFrames: [SlotColumn: CGRect] = [:]
    var splitters: [ColumnSplitterPosition] = []
    var rowSplitters: [RowSplitterPosition] = []
    /// Resolved height of each live row; absent rows have none and take no space.
    var rowHeights: [SlotRow: CGFloat] = [:]

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
