import Foundation

/// The per-strip tab order, as pure arithmetic over ids.
///
/// Lifted out of `SessionStore` deliberately. Phase A's third bug was a sizing rule that
/// lived only in the store, so no harness could reach it and nothing caught it going
/// wrong. Contiguity is the same shape of claim — task 9736 criterion 10 asserts that
/// reordering inside one strip cannot corrupt grouping in another — so it gets the same
/// treatment: no file system, no AppKit, no PTY, nothing but ids.
///
/// THE MODEL. `open` is one flat list holding BOTH kinds; each strip is that list
/// filtered to its own `ViewKind`. Only the relative order within a strip is meaningful,
/// and interleaving with the other kind carries no meaning at all. A group (a parent and
/// the children naming it) must be a contiguous run WITHIN a strip — which is as strong
/// as the invariant can be once a parent in the console strip has children in the
/// document strip, because no run spans both.
struct TabStripModel: Equatable {
    /// Every open tab, both kinds, in flat order.
    private(set) var open: [UUID]
    private let kinds: [UUID: ViewKind]
    private let parentsByChild: [UUID: UUID]

    init(open: [UUID], kinds: [UUID: ViewKind], parents: [UUID: UUID]) {
        self.open = open
        self.kinds = kinds
        self.parentsByChild = parents
    }

    // MARK: - Reads

    func kind(of id: UUID) -> ViewKind { kinds[id] ?? .terminal }

    /// The declared parent, whether or not it is still open.
    func declaredParent(of id: UUID) -> UUID? { parentsByChild[id] }

    /// The group parent of an open tab, when that parent is itself still open. May live
    /// in the other strip — that is the whole point of Phase B's parenting.
    func groupParent(of id: UUID) -> UUID? {
        guard let pid = parentsByChild[id], open.contains(pid) else { return nil }
        return pid
    }

    func strip(_ kind: ViewKind) -> [UUID] {
        open.filter { self.kind(of: $0) == kind }
    }

    func children(of parent: UUID) -> [UUID] {
        open.filter { parentsByChild[$0] == parent }
    }

    func children(of parent: UUID, in kind: ViewKind) -> [UUID] {
        children(of: parent).filter { self.kind(of: $0) == kind }
    }

    // MARK: - Insertion

    /// Where a newly opened tab goes, as an index into the flat `open` list: inside its
    /// group's contiguous run IN ITS OWN STRIP, or at the end of that strip when
    /// ungrouped.
    ///
    /// Note the last clause — end of the STRIP, not end of the flat list. Appending
    /// globally would let a new document tab jump ahead of console tabs opened after it,
    /// and the two strips' orders would drift apart for no reason a user could see.
    func insertionIndex(kind: ViewKind, parent: UUID?) -> Int {
        let strip = strip(kind)

        func afterFlat(_ id: UUID) -> Int {
            (open.firstIndex(of: id).map { $0 + 1 }) ?? open.count
        }

        if let parent {
            // Join the existing siblings in this strip, keeping the run contiguous.
            if let lastSibling = strip.last(where: { parentsByChild[$0] == parent }) {
                return afterFlat(lastSibling)
            }
            // First child, and the parent shares the strip: land right after it. This is
            // exactly the pre-Phase-B rule for a spawned console tab.
            if open.contains(parent), self.kind(of: parent) == kind {
                return afterFlat(parent)
            }
        }
        return strip.last.map(afterFlat) ?? open.count
    }

    // MARK: - Reorder

    /// Move `id` before `target` (or to the end of its strip when `target` is nil), and
    /// report every tab that left its group as a result.
    ///
    /// Everything happens on the strip-local array; the result is written back over the
    /// positions that kind already held. That is what makes criterion 10 STRUCTURAL
    /// rather than a promise — the other kind's slots are copied through verbatim, so a
    /// reorder here provably cannot move a tab there.
    @discardableResult
    mutating func move(_ id: UUID, before target: UUID?) -> [UUID] {
        guard open.contains(id) else { return [] }
        let kind = kind(of: id)
        // A drop onto a tab of the other kind is not a reorder — there is no meaningful
        // position for it across strips.
        if let target, self.kind(of: target) != kind { return [] }

        var strip = strip(kind)
        // A parent moves with its children as one block — but only the children sharing
        // its strip. A console tab's document children live in a different list and stay
        // exactly where they are.
        let block = [id] + children(of: id, in: kind)
        // Dropping a group onto itself is a no-op.
        if let target, block.contains(target) { return [] }

        strip.removeAll { block.contains($0) }

        var insertAt = strip.count
        if let target, var targetIdx = strip.firstIndex(of: target) {
            // Don't split a foreign group: dropping onto one of its members places the
            // moved block before the whole group instead.
            if let targetParent = groupParent(of: target),
               parentsByChild[id] != targetParent,
               let runStart = runStart(parent: targetParent, in: strip) {
                targetIdx = runStart
            }
            insertAt = targetIdx
        }
        strip.insert(contentsOf: block, at: insertAt)
        rewrite(kind, to: strip)

        return leftGroup(id, in: kind) ? [id] : []
    }

    /// Write `newOrder` back over the positions `kind` already occupies, leaving every
    /// other kind's position untouched.
    private mutating func rewrite(_ kind: ViewKind, to newOrder: [UUID]) {
        guard newOrder.count == strip(kind).count else { return }
        var next = newOrder.makeIterator()
        open = open.map { id in
            self.kind(of: id) == kind ? (next.next() ?? id) : id
        }
    }

    /// Where a group's contiguous run begins inside one strip.
    ///
    /// When the parent shares the strip (a console tab's console children) the run starts
    /// at the parent itself, as it always did. When the parent is in the OTHER strip —
    /// a console tab's document children — there is no parent to anchor to, so the run
    /// starts at the group's first member.
    private func runStart(parent: UUID, in strip: [UUID]) -> Int? {
        if let parentIdx = strip.firstIndex(of: parent) { return parentIdx }
        return strip.firstIndex { parentsByChild[$0] == parent }
    }

    /// Did the move break `id`'s group? If so `id` — the tab the user dragged — is the
    /// one that leaves it.
    ///
    /// Stated as "every member of the group occupies consecutive positions", NOT as the
    /// old "is the moved tab inside the run that starts at its parent". That scan
    /// silently passed the case this file exists to get right: with the parent in the
    /// OTHER strip there is no anchor, so a run scanned from the group's FIRST member
    /// found the dragged tab sitting at the head of its own one-tab run and called the
    /// group intact — while the sibling it had just been torn away from was stranded
    /// three positions down. Consecutiveness cannot be fooled that way, and it reduces to
    /// exactly the old rule when the parent does share the strip (plus the parent-first
    /// requirement below).
    private func leftGroup(_ id: UUID, in kind: ViewKind) -> Bool {
        guard let pid = groupParent(of: id) else { return false }
        let strip = strip(kind)
        var indices: [Int] = []
        var parentIndex: Int?
        for (index, tab) in strip.enumerated() {
            if tab == pid {
                parentIndex = index
                indices.append(index)
            } else if parentsByChild[tab] == pid {
                indices.append(index)
            }
        }
        // A lone member is contiguous with itself.
        guard indices.count > 1, let lo = indices.min(), let hi = indices.max() else { return false }
        if hi - lo != indices.count - 1 { return true }
        // When the parent shares the strip it heads its own run, as it always has.
        if let parentIndex, parentIndex != lo { return true }
        return false
    }
}
