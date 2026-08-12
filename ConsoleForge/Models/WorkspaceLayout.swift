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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .console: "Console"
        case .browser: "Safari"
        }
    }

    /// What the section actually is, for tooltips and menu help.
    var detail: String? {
        switch self {
        case .console: nil
        case .browser: "In-app WebKit (WKWebView) — the engine Safari uses. Web Inspector enabled."
        }
    }

    var symbol: String {
        switch self {
        case .console: "terminal"
        case .browser: "safari"
        }
    }

    /// The console is the app — it always occupies a slot and never floats
    /// (everything else floats *over* it).
    var isClosable: Bool { self != .console }
    var canFloat: Bool { self != .console }
}

/// A fixed position in the window. Slots are laid out left → right in declaration
/// order; a slot is "available" when no section occupies it.
enum SlotID: String, Codable, CaseIterable, Identifiable, Sendable {
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

    /// Left-to-right tiling order (declaration order).
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// Which window edge a section floating in this slot stays pinned to. Floating is
    /// a DOCKED overlay, not a free window: the panel keeps the edge its slot came
    /// from and only stops consuming layout space.
    var floatsToTrailingEdge: Bool { self == .right }
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
        id = try c.decode(SlotID.self, forKey: .id)
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
    /// Last page the browser section had loaded, so reopening it lands back there.
    var browserURL: String?

    init(slots: [SlotConfiguration] = WorkspaceLayout.defaultSlots, browserURL: String? = nil) {
        self.slots = slots
        self.browserURL = browserURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slots = try c.decodeIfPresent([SlotConfiguration].self, forKey: .slots) ?? WorkspaceLayout.defaultSlots
        browserURL = try c.decodeIfPresent(String.self, forKey: .browserURL)
        normalize()
    }

    /// Console in the center slot, flexible and tiled — identical on screen to the
    /// pre-slot single-pane layout.
    static var defaultSlots: [SlotConfiguration] {
        SlotID.allCases.map { id in
            SlotConfiguration(id: id, section: id == .center ? .console : nil)
        }
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
    }

    static let minPinnedFraction: Double = 0.02
    /// Fallback floor for a section that declares no minimum of its own.
    static let minSlotWidth: CGFloat = 240
    /// Width of the rail a collapsed section leaves behind — enough for its glyph, and
    /// the only way back, so a section can never be shrunk into oblivion.
    static let collapsedRailWidth: CGFloat = 22

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
    func resolve(in size: CGSize, minWidths: [SectionKind: CGFloat] = [:]) -> ResolvedWorkspaceLayout {
        var result = ResolvedWorkspaceLayout()
        guard size.width > 0, size.height > 0 else { return result }

        let occupied = slots.filter { $0.section != nil }
        let allTiled = occupied.filter { !$0.isFloating }.sorted { $0.id.order < $1.id.order }

        func floorWidth(_ slot: SlotConfiguration) -> CGFloat {
            slot.section.flatMap { minWidths[$0] } ?? WorkspaceLayout.minSlotWidth
        }
        func anchored(_ id: SlotID, width: CGFloat) -> CGRect {
            CGRect(x: id.floatsToTrailingEdge ? size.width - width : 0,
                   y: 0, width: width, height: size.height)
        }

        // Floating slots overlay the tiled ones at full height, docked to their slot's
        // edge, and consume no layout space in ANY state — collapsed included. Nothing
        // here touches the tiled arithmetic below, which is the point: toggling or
        // resizing a floating panel must never move what is underneath it.
        for slot in occupied where slot.isFloating {
            if slot.isCollapsed {
                result.collapsed[slot.id] = anchored(slot.id, width: WorkspaceLayout.collapsedRailWidth)
            } else {
                let width = min(max(CGFloat(slot.pinnedFraction) * size.width, floorWidth(slot)), size.width)
                result.floating[slot.id] = anchored(slot.id, width: width)
            }
        }

        guard !allTiled.isEmpty else { return result }

        // Slots the user collapsed on purpose start out collapsed. Never leave the
        // window with nothing in it — the console (failing that, the first tiled slot)
        // always survives.
        var collapsed = Set(allTiled.filter(\.isCollapsed).map(\.id))
        if collapsed.count == allTiled.count,
           let keep = allTiled.first(where: { $0.section == .console }) ?? allTiled.first {
            collapsed.remove(keep.id)
        }

        // Forced-collapse pass: widen the collapsed set one slot at a time until every
        // surviving slot clears its floor. Bounded by the slot count, so at most a
        // couple of iterations.
        var widths: [SlotID: CGFloat] = [:]
        while true {
            let active = allTiled.filter { !collapsed.contains($0.id) }
            widths = tileWidths(active: active, railCount: collapsed.count, size: size)
            guard active.count > 1,
                  let starved = active.first(where: { (widths[$0.id] ?? 0) + 0.5 < floorWidth($0) })
            else { break }
            collapsed.insert(starved.id)
        }

        // The loop above stops before collapsing the last slot standing, which left a
        // hole: a lone console still pinned at a tiny fraction (a leftover from a
        // splitter drag) was laid out at its fraction — ~24pt, TWO COLUMNS — and a
        // resumed history flooding in at that width corrupts the SwiftTerm buffer for
        // good. A slot that cannot be collapsed gets its floor instead, capped at the
        // space actually available. Slots that are merely pinned small alongside others
        // are untouched, so a lone 50% pin still leaves 50% empty (rule 3).
        let survivors = allTiled.filter { !collapsed.contains($0.id) }
        if survivors.count == 1, let only = survivors.first {
            let available = size.width - CGFloat(collapsed.count) * WorkspaceLayout.collapsedRailWidth
            widths[only.id] = min(max(widths[only.id] ?? 0, floorWidth(only)), max(0, available))
        }

        var x: CGFloat = 0
        var previousTiled: SlotID?
        for id in SlotID.allCases {
            if collapsed.contains(id) {
                result.collapsed[id] = CGRect(x: x, y: 0,
                                              width: WorkspaceLayout.collapsedRailWidth,
                                              height: size.height)
                x += WorkspaceLayout.collapsedRailWidth
                previousTiled = nil          // a rail breaks adjacency: no splitter across it
                continue
            }
            guard let width = widths[id] else { continue }
            result.tiled[id] = CGRect(x: x, y: 0, width: width, height: size.height)
            if let previousTiled {
                result.splitters.append(SplitterPosition(leading: previousTiled, trailing: id, x: x))
            }
            x += width
            previousTiled = id
        }
        result.emptyTrailingWidth = max(0, size.width - x)
        return result
    }

    /// One sizing pass over the slots that are still tiled. Widths are computed purely
    /// as fractions of the window so they always sum to ≤ 1 — a slot is never widened
    /// past its share to meet a floor, because that would silently overflow the window.
    /// Falling short of the floor is what the collapse pass acts on instead.
    private func tileWidths(active: [SlotConfiguration],
                            railCount: Int,
                            size: CGSize) -> [SlotID: CGFloat] {
        guard !active.isEmpty else { return [:] }
        // Rails come off the top; the rest of the window is what fractions divide.
        let usable = max(0, Double(size.width) - Double(railCount) * Double(WorkspaceLayout.collapsedRailWidth))
        let budget = usable / Double(size.width)

        let flexible = active.filter { !$0.isPinned }
        var pinnedSum = active.filter(\.isPinned).reduce(0.0) { $0 + $1.pinnedFraction }

        // Reserve a share for the flexible slots, then fit the pins into what is left.
        // With no flexible slot `reserved` is 0 and this degenerates to the plain
        // over-100% proportional scale-down (rule 4).
        let reserved = min(Double(flexible.count) * Double(WorkspaceLayout.minSlotWidth) / Double(size.width),
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
        for slot in active {
            let fraction = slot.isPinned ? slot.pinnedFraction * pinScale : flexEach
            widths[slot.id] = CGFloat(fraction) * size.width
        }

        return widths
    }
}

/// A draggable boundary between two adjacent tiled slots.
struct SplitterPosition: Equatable, Identifiable {
    var leading: SlotID
    var trailing: SlotID
    var x: CGFloat
    var id: String { "\(leading.rawValue)-\(trailing.rawValue)" }
}

struct ResolvedWorkspaceLayout: Equatable {
    /// Frames for occupied, tiled slots.
    var tiled: [SlotID: CGRect] = [:]
    /// Frames for occupied, floating slots (overlaid; consume no layout space).
    var floating: [SlotID: CGRect] = [:]
    /// Rails for slots too narrow to render their section. The section stays alive and
    /// unresized behind the rail; clicking it restores the slot.
    var collapsed: [SlotID: CGRect] = [:]
    var splitters: [SplitterPosition] = []
    /// Leftover that no flexible slot absorbed, rendered as empty space at the
    /// trailing edge.
    var emptyTrailingWidth: CGFloat = 0

    func frame(for id: SlotID) -> CGRect? {
        tiled[id] ?? floating[id]
    }

    /// Where a section should be RENDERED: its tile or float, or a zero-width sliver at
    /// its rail when collapsed. Collapsed sections stay in the view tree at zero width
    /// rather than being removed — the hosted NSView (a live terminal, a loaded page) is
    /// then never dismantled, and the terminal is never resized, because a zero width
    /// is rejected by the guard on the way into `TerminalSessionManager.setSize`.
    func renderFrame(for id: SlotID, height: CGFloat) -> CGRect? {
        if let frame = tiled[id] ?? floating[id] { return frame }
        if let rail = collapsed[id] {
            return CGRect(x: rail.minX, y: 0, width: 0, height: height)
        }
        return nil
    }
}
