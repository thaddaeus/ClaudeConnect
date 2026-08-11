import Foundation
import CoreGraphics

/// Movable content. A section lives in exactly one slot, or nowhere (closed).
enum SectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case console
    case browser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .console: "Console"
        case .browser: "Browser"
        }
    }

    var symbol: String {
        switch self {
        case .console: "terminal"
        case .browser: "globe"
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
}

/// A floating slot's frame, stored as fractions of the workspace so it survives a
/// window resize and a display change.
struct NormalizedRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let defaultFloating = NormalizedRect(x: 0.42, y: 0.10, width: 0.52, height: 0.66)

    func resolved(in size: CGSize, minWidth: CGFloat, minHeight: CGFloat) -> CGRect {
        let w = min(max(width * size.width, minWidth), size.width)
        let h = min(max(height * size.height, minHeight), size.height)
        let px = min(max(x * size.width, 0), max(0, size.width - w))
        let py = min(max(y * size.height, 0), max(0, size.height - h))
        return CGRect(x: px, y: py, width: w, height: h)
    }

    static func from(_ rect: CGRect, in size: CGSize) -> NormalizedRect {
        guard size.width > 0, size.height > 0 else { return .defaultFloating }
        return NormalizedRect(x: rect.minX / size.width,
                              y: rect.minY / size.height,
                              width: rect.width / size.width,
                              height: rect.height / size.height)
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
    /// FLOATING: overlays the tiled sections and consumes no layout space.
    var isFloating: Bool = false
    var floatingFrame: NormalizedRect = .defaultFloating

    init(id: SlotID,
         section: SectionKind? = nil,
         isPinned: Bool = false,
         pinnedFraction: Double = 0.4,
         isFloating: Bool = false,
         floatingFrame: NormalizedRect = .defaultFloating) {
        self.id = id
        self.section = section
        self.isPinned = isPinned
        self.pinnedFraction = pinnedFraction
        self.isFloating = isFloating
        self.floatingFrame = floatingFrame
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
        floatingFrame = try c.decodeIfPresent(NormalizedRect.self, forKey: .floatingFrame) ?? .defaultFloating
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
            if config.section == nil { config.isFloating = false }
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

    static let minPinnedFraction: Double = 0.1
    /// No occupied tiled slot is ever laid out narrower than this. A terminal reflowed
    /// to a handful of columns and back is exactly the buffer-model corruption this
    /// project has been burned by twice.
    static let minSlotWidth: CGFloat = 240

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
    func resolve(in size: CGSize) -> ResolvedWorkspaceLayout {
        var result = ResolvedWorkspaceLayout()
        guard size.width > 0, size.height > 0 else { return result }

        let occupied = slots.filter { $0.section != nil }
        let tiled = occupied.filter { !$0.isFloating }.sorted { $0.id.order < $1.id.order }

        for slot in occupied where slot.isFloating {
            result.floating[slot.id] = slot.floatingFrame.resolved(
                in: size, minWidth: WorkspaceLayout.minSlotWidth, minHeight: 180)
        }

        guard !tiled.isEmpty else { return result }

        let flexible = tiled.filter { !$0.isPinned }
        // Widths are computed purely as fractions so they always sum to ≤ 1 — a slot
        // is floored by raising its FRACTION, never by widening the resolved frame
        // (which would silently overflow the window).
        let minFraction = min(Double(WorkspaceLayout.minSlotWidth) / Double(size.width), 0.4)
        var effectivePin: [SlotID: Double] = [:]
        for slot in tiled where slot.isPinned {
            effectivePin[slot.id] = max(slot.pinnedFraction, minFraction)
        }
        var pinnedSum = effectivePin.values.reduce(0, +)

        // Rule 5 then rule 4: reserve the flexible minimum, then fit the pins into
        // whatever is left. With no flexible slot `reserved` is 0 and this degenerates
        // to the plain over-100% proportional scale-down.
        let reserved = min(Double(flexible.count) * minFraction, 0.9)
        var pinScale = 1.0
        let pinBudget = max(0, 1.0 - reserved)
        if pinnedSum > pinBudget, pinnedSum > 0 {
            pinScale = pinBudget / pinnedSum
            pinnedSum = pinBudget
        }

        let leftover = max(0, 1.0 - pinnedSum)
        let flexEach = flexible.isEmpty ? 0 : leftover / Double(flexible.count)

        // Rule 3: unabsorbed leftover is handed back to the holes — floating slots
        // first, at the width they used to occupy — so the pinned tiles stay put.
        var holeWidths: [SlotID: Double] = [:]
        if flexible.isEmpty, leftover > 0 {
            var claims: [SlotID: Double] = [:]
            for slot in slots where slot.isFloating && slot.section != nil && slot.isPinned {
                claims[slot.id] = slot.pinnedFraction
            }
            let claimSum = claims.values.reduce(0, +)
            let claimScale = claimSum > leftover ? leftover / claimSum : 1.0
            for (id, claim) in claims {
                holeWidths[id] = claim * claimScale
            }
        }

        var x: CGFloat = 0
        var previousTiled: SlotID?
        for id in SlotID.allCases {
            if let hole = holeWidths[id] {
                x += CGFloat(hole) * size.width
                previousTiled = nil          // a gap breaks adjacency: no splitter across it
                continue
            }
            guard let slot = tiled.first(where: { $0.id == id }) else { continue }
            let fraction = slot.isPinned ? (effectivePin[id] ?? 0) * pinScale : flexEach
            let width = CGFloat(fraction) * size.width
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
    var splitters: [SplitterPosition] = []
    /// Leftover that no flexible slot absorbed, rendered as empty space at the
    /// trailing edge.
    var emptyTrailingWidth: CGFloat = 0

    func frame(for id: SlotID) -> CGRect? {
        tiled[id] ?? floating[id]
    }
}
