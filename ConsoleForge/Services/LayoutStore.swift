import Foundation
import SwiftUI

/// What a live splitter drag is doing to the sections either side of it, so the
/// workspace can show it rather than letting a section vanish without warning.
enum BoundaryFeedback: Equatable {
    case free
    /// Sitting on the minimum width of the sections named here. The drag is clamped.
    case atMinimum(Set<SlotID>)
    /// Dragged far enough past the minimum that releasing will collapse them.
    case willCollapse(Set<SlotID>)

    /// A SET, because a column boundary governs every cell in the column — dragging it
    /// shut takes both rows with it. A float-edge drag names exactly one.
    var slots: Set<SlotID> {
        switch self {
        case .free: []
        case .atMinimum(let ids), .willCollapse(let ids): ids
        }
    }

    var isCollapsing: Bool {
        if case .willCollapse = self { return true }
        return false
    }
}

/// Owns the window's slot layout and persists it.
///
/// Layout is PER-WINDOW, not per-tab: switching console tabs swaps only what the
/// console slot shows, never the arrangement. Kept in its own file (`layout.json`)
/// rather than folded into `sessions.json` so a layout the user is unhappy with can
/// be deleted without touching their sessions.
@MainActor
@Observable
final class LayoutStore {
    private(set) var layout: WorkspaceLayout

    private var loaded = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Live workspace width and the per-section width floors, published by
    /// `WorkspaceView` (which is the layer that knows the terminal font). Held here so
    /// every entry point — header control, context menu, menu bar — can work out a
    /// section's minimum fraction without the caller threading geometry through.
    @ObservationIgnored var workspaceWidth: CGFloat = 1200
    @ObservationIgnored var sectionMinWidths: [SectionKind: CGFloat] = [:]

    /// The floor a single CELL's section needs, as a fraction of the window. Used for
    /// floating panels, which are not members of the grid.
    func minFraction(_ id: SlotID) -> Double {
        let min = layout[id].section.flatMap { sectionMinWidths[$0] } ?? WorkspaceLayout.minSlotWidth
        return Double(min / max(workspaceWidth, 1))
    }

    /// The floor a COLUMN needs: the widest minimum of the sections currently in it,
    /// because one width has to serve every cell. An empty column falls back to the
    /// generic slot floor.
    func minFraction(_ column: SlotColumn) -> Double {
        let points = layout.slots(in: column).compactMap(\.section)
            .map { sectionMinWidths[$0] ?? WorkspaceLayout.minSlotWidth }.max()
            ?? WorkspaceLayout.minSlotWidth
        return Double(points / max(workspaceWidth, 1))
    }

    /// Sections in this column that a width change would act on — what a boundary drag
    /// clamps against and what releasing past the floor would collapse.
    func liveSlots(in column: SlotColumn) -> Set<SlotID> {
        Set(SlotID.allCases.filter {
            $0.column == column && layout[$0].section != nil
                && !layout[$0].isFloating && !layout[$0].isCollapsed
        })
    }

    private static var storageURL: URL {
        AppChannel.supportDirectory().appendingPathComponent("layout.json")
    }

    init() {
        var initial = WorkspaceLayout()
        if let data = try? Data(contentsOf: Self.storageURL),
           let decoded = try? JSONDecoder().decode(WorkspaceLayout.self, from: data) {
            initial = decoded
        }
        initial.normalize()
        layout = initial
        loaded = true
    }

    // MARK: - Reads

    subscript(id: SlotID) -> SlotConfiguration { layout[id] }

    func slot(holding section: SectionKind) -> SlotConfiguration? { layout.slot(holding: section) }
    func isOpen(_ section: SectionKind) -> Bool { layout.isOpen(section) }
    func isFloating(_ section: SectionKind) -> Bool { layout.slot(holding: section)?.isFloating ?? false }

    /// Section headers only appear once there is more than one section to arrange —
    /// a lone console looks exactly as it did before slots existed. That intent survives
    /// task 990035: what was wrong was never the quiet header, it was that NOTHING else
    /// was on screen either. The always-on rail (`SectionRailView`) now carries the
    /// discoverability, so the header stays a second-section refinement.
    var showsSectionChrome: Bool { layout.openSectionCount > 1 }

    var browserURL: String? { layout.browserURL }

    /// What the always-on rail shows for a section. Three states, because "closed" and
    /// "collapsed" are genuinely different things — a closed section has been discarded,
    /// a collapsed one is still loaded and parked off-canvas — and the rail is the only
    /// place both are visible at once.
    enum RailState: Equatable {
        case visible
        case collapsed
        case closed
    }

    /// A section is off screen in TWO ways and the rail has to tell neither apart: the
    /// user collapsed it (`isCollapsed`, in the model), or `resolve` FORCED it out
    /// because its row could not reach the section's floor. The forced one is derived
    /// per layout pass and deliberately never written back — so the caller passes in the
    /// resolved parking set, and the rail stops claiming a starved console is on screen.
    func railState(_ section: SectionKind, parked: Set<SlotID>) -> RailState {
        guard let slot = layout.slot(holding: section) else { return .closed }
        return (slot.isCollapsed || parked.contains(slot.id)) ? .collapsed : .visible
    }

    /// One click on a rail row: put the section on screen, or park it back on the rail.
    ///
    /// Deliberately a SHOW/HIDE switch and never a close button. Closing discards a
    /// panel — the browser's page, the document's scroll position — so it stays a
    /// deliberate act in a menu or on the header's X. Everything this does is reversible
    /// by clicking the same row again.
    func toggleVisible(_ section: SectionKind, parked: Set<SlotID>) {
        guard let slot = layout.slot(holding: section) else {
            open(section)
            return
        }
        if slot.isCollapsed {
            normal(slot.id)
        } else if parked.contains(slot.id) {
            // FORCED out: nothing in the model says "collapsed", so un-collapsing it
            // would change nothing and the row would look dead. What starved it is that
            // its row has no width to spare, so claim the floor as an explicit pin —
            // `expand` then scales the pinned neighbours down until it fits. Getting off
            // a rail has to always succeed; that is the rule the whole control rests on.
            let floor = minFraction(slot.id.column)
            pin(slot.id, fraction: floor)
            restore(slot.id, minFraction: floor)
        } else {
            collapse(slot.id)
        }
    }

    // MARK: - Mutations

    /// What a move would DISPLACE, and where that panel would end up.
    ///
    /// One section per slot is the rule, so moving into an occupied cell sends its
    /// occupant to the cell you came from. The UI states that as an outcome — "Safari
    /// moves to Top Center" — rather than as the mechanism ("swap with Safari"), which
    /// described the implementation and read as a warning (task 990039 §2). Returns nil
    /// when the target is empty and nothing is disturbed.
    func displacement(moving section: SectionKind, to target: SlotID)
        -> (section: SectionKind, destination: SlotID)? {
        guard let source = layout.slot(holding: section), source.id != target,
              let occupant = layout[target].section, occupant != section else { return nil }
        return (occupant, source.id)
    }

    /// Move a section into `target`. If another section already holds that slot the
    /// two trade places, so a move never silently closes anything — see
    /// `displacement(moving:to:)` for how that is shown before it happens.
    func move(_ section: SectionKind, to target: SlotID) {
        guard let source = layout.slot(holding: section), source.id != target else { return }
        let displaced = layout[target].section
        layout[target].section = section
        layout[source.id].section = displaced
        if displaced?.canFloat == false { layout[source.id].isFloating = false }
        if layout[source.id].section == nil {
            layout[source.id].isFloating = false
            layout[source.id].isCollapsed = false
            // Moving a panel is repositioning it, not reserving where it used to be — so
            // if the move emptied its COLUMN outright, the column releases its pin
            // rather than stranding a phantom reserved strip that shoves everything
            // sideways. Closing a pinned section still holds its space (see `close`);
            // that is the deliberate way to keep a hole. A column that still holds
            // something keeps its width, because the remaining cell needs it.
            if layout.isEmpty(source.id.column) { layout[source.id.column].isPinned = false }
        }
        commit()
    }

    /// Open a closed section in the first available slot (preferring the far side of
    /// the window from the console), or focus it if already open.
    func open(_ section: SectionKind) {
        guard !layout.isOpen(section) else { return }
        // Prefer the far side of the top row, then the bottom row, then anywhere.
        let preferred: [SlotID] = [.topRight, .topLeft, .bottomCenter, .bottomLeft, .bottomRight, .topCenter]
        guard let target = preferred.first(where: { layout[$0].section == nil }) else { return }
        layout[target].section = section
        commit()
    }

    /// Closing DISCARDS the panel but HOLDS ITS SPACE. A pinned column keeps its
    /// fraction with nothing in it — that is what stops the console resizing when a
    /// browser closes, and it is now simply what a pinned column does rather than a
    /// separate "reserved gap" concept.
    func close(_ section: SectionKind) {
        guard section.isClosable, let slot = layout.slot(holding: section) else { return }
        layout[slot.id].section = nil
        layout[slot.id].isFloating = false
        layout[slot.id].isCollapsed = false
        commit()
    }

    func toggle(_ section: SectionKind) {
        layout.isOpen(section) ? close(section) : open(section)
    }

    /// Make the section owning `kind`'s tab strip visible — opening it if closed and
    /// un-collapsing it if it is parked in the rail.
    ///
    /// Opening a tab whose strip is not on screen would otherwise leave it invisible but
    /// live: still in `openTabIDs`, still counted by the close-with-children prompt, and
    /// with nothing to click. Called on every document open.
    func revealStrip(for kind: ViewKind) {
        guard let section = SectionKind.allCases.first(where: { $0.stripKind == kind }) else { return }
        open(section)
        if let slot = layout.slot(holding: section), slot.isCollapsed {
            normal(slot.id)
        }
    }

    /// Pinning a section pins ITS COLUMN — width is a column property, so "hold this
    /// panel at 40%" and "hold this column at 40%" are the same statement. The cell
    /// under it (or over it) is held to the same width, which is what makes the grid a
    /// grid.
    func pin(_ id: SlotID, fraction: Double) { pin(id.column, fraction: fraction) }

    func pin(_ column: SlotColumn, fraction: Double) {
        layout[column].isPinned = true
        layout[column].pinnedFraction = min(max(fraction, WorkspaceLayout.minPinnedFraction), 1.0)
        commit()
    }

    func makeFlexible(_ id: SlotID) { makeFlexible(id.column) }

    func makeFlexible(_ column: SlotColumn) {
        layout[column].isPinned = false
        commit()
    }

    func isPinned(_ id: SlotID) -> Bool { layout[id.column].isPinned }
    func pinnedFraction(_ id: SlotID) -> Double { layout[id.column].pinnedFraction }
    /// How the column behind a slot is sized. A named accessor rather than a second
    /// `subscript` overload: `SlotID` and `SlotColumn` are both string enums, and the
    /// pair made every `layout[$0]` inside a closure ambiguous.
    func column(_ column: SlotColumn) -> ColumnConfiguration { layout[column] }

    func setFloating(_ id: SlotID, _ floating: Bool) {
        guard layout[id].section?.canFloat == true else { return }
        layout[id].isFloating = floating
        commit()
    }

    /// Drag of a floating panel's INNER edge. Only the panel's own width changes —
    /// the tiled layout underneath is not consulted and never moves, which is the
    /// whole point of floating. Same detent as a tiled splitter: clamps at the floor,
    /// and `.willCollapse` past the overshoot is committed by the caller on release.
    @discardableResult
    func resizeFloating(_ id: SlotID, toFraction fraction: Double, windowWidth: CGFloat) -> BoundaryFeedback {
        let width = max(windowWidth, 1)
        let floor = max(minFraction(id), WorkspaceLayout.minPinnedFraction)
        let overshoot = Double(Self.collapseOvershoot / width)

        var feedback = BoundaryFeedback.free
        if fraction < floor - overshoot {
            feedback = .willCollapse([id])
        } else if fraction <= floor {
            feedback = .atMinimum([id])
        }
        layout[id].floatingFraction = min(max(fraction, floor), 1.0)
        commit()
        return feedback
    }

    /// How far past a section's minimum width the pointer must travel before releasing
    /// will collapse it. The section stops at its minimum and *stays* there for this
    /// distance — the detent that stops a drag from snapping shut the instant it
    /// touches the floor.
    static let collapseOvershoot: CGFloat = 56

    /// Drag of the boundary between two adjacent live COLUMNS. The leading column
    /// becomes pinned at the dragged fraction (that is what a splitter means); a
    /// trailing column that is *also* pinned gives up exactly what the leading one
    /// gained, so the pair keeps its combined share and nothing beyond the boundary
    /// moves.
    ///
    /// One drag, both rows — the boundary is the column's, so the cells above and below
    /// it change together. That is the grid, and it is why there is no way to drag the
    /// two halves of a column into disagreeing widths.
    ///
    /// No section is ever laid out below its minimum: the drag CLAMPS at the widest
    /// floor in the column. Dragging further returns `.willCollapse`, and it is the
    /// caller's release that commits the collapse — nothing disappears mid-gesture.
    @discardableResult
    func resizeBoundary(leading: SlotColumn, trailing: SlotColumn,
                        leadingFraction: Double, trailingFraction: Double?,
                        windowWidth: CGFloat) -> BoundaryFeedback {
        let width = max(windowWidth, 1)
        let leadFloor = max(minFraction(leading), WorkspaceLayout.minPinnedFraction)
        let trailFloor = max(minFraction(trailing), WorkspaceLayout.minPinnedFraction)
        let overshoot = Double(Self.collapseOvershoot / width)

        var feedback = BoundaryFeedback.free
        if leadingFraction < leadFloor - overshoot {
            feedback = .willCollapse(liveSlots(in: leading))
        } else if leadingFraction <= leadFloor {
            feedback = .atMinimum(liveSlots(in: leading))
        }

        guard let trailingFraction else {
            let clamped = min(max(leadingFraction, leadFloor), 1.0 - WorkspaceLayout.minPinnedFraction)
            layout[leading].isPinned = true
            layout[leading].pinnedFraction = clamped
            commit()
            return feedback
        }

        let total = leadingFraction + trailingFraction
        if total - leadingFraction < trailFloor - overshoot {
            feedback = .willCollapse(liveSlots(in: trailing))
        } else if total - leadingFraction <= trailFloor, case .free = feedback {
            feedback = .atMinimum(liveSlots(in: trailing))
        }

        // Both floors have to fit inside the pair's combined share; if they don't,
        // split it and let the forced-collapse pass sort it out.
        let newLeading = total - trailFloor < leadFloor
            ? total / 2
            : min(max(leadingFraction, leadFloor), total - trailFloor)
        layout[leading].isPinned = true
        layout[leading].pinnedFraction = newLeading
        layout[trailing].isPinned = true
        layout[trailing].pinnedFraction = max(total - newLeading, WorkspaceLayout.minPinnedFraction)
        commit()
        return feedback
    }

    /// Commit what a boundary or float-edge drag was warning about: hide every section
    /// the feedback named. A column boundary names both of its cells, because dragging
    /// a column shut closes the column.
    func collapse(_ ids: Set<SlotID>) {
        guard !ids.isEmpty else { return }
        for id in ids where layout[id].section != nil { layout[id].isCollapsed = true }
        if let maximized = maximizedSlot, ids.contains(maximized) { maximizedSlot = nil }
        commit()
    }

    // MARK: - Collapse / Normal / Maximize

    /// The slot currently taking the full window, if any.
    private(set) var maximizedSlot: SlotID?
    /// Layout as it was before the current maximize, so Normal is a true undo.
    @ObservationIgnored private var restorePoint: WorkspaceLayout?

    enum SizeState: Equatable {
        case collapsed
        case normal
        case maximized
    }

    func sizeState(_ id: SlotID) -> SizeState {
        if layout[id].isCollapsed { return .collapsed }
        if maximizedSlot == id { return .maximized }
        return .normal
    }

    func collapse(_ id: SlotID) {
        guard layout[id].section != nil else { return }
        layout[id].isCollapsed = true
        if maximizedSlot == id { maximizedSlot = nil }
        commit()
    }

    /// Full width.
    ///
    /// A FLOATING panel simply widens to the whole window — it is an overlay, so it
    /// takes no space from anything and the tiled layout underneath is untouched.
    /// A TILED section has to actually take the room, so every other tiled section
    /// collapses to a rail; floating ones still stay put. `normal` puts it all back.
    func maximize(_ id: SlotID) {
        guard layout[id].section != nil else { return }
        if restorePoint == nil { restorePoint = layout }
        layout[id].isCollapsed = false
        if layout[id].isFloating {
            layout[id].floatingFraction = 1.0
        } else {
            // Full width means "take the whole content area", so its column goes
            // flexible AND every other column releases its pin — a reserved strip left
            // pinned would hold a hole open across a section that is meant to be filling
            // the window. `normal` restores all of it from the restore point.
            for column in SlotColumn.allCases { layout[column].isPinned = false }
            for slot in layout.slots where slot.id != id && slot.section != nil && !slot.isFloating {
                layout[slot.id].isCollapsed = true
            }
        }
        maximizedSlot = id
        commit()
    }

    /// Back to the arrangement before the maximize, or — if there was none — visible
    /// again at the size it was collapsed at, with pinned neighbours scaled down to make
    /// room. Always succeeds; it is the only way off a rail.
    func normal(_ id: SlotID) {
        if let restorePoint, maximizedSlot != nil {
            layout = restorePoint
            self.restorePoint = nil
            maximizedSlot = nil
            layout[id].isCollapsed = false
            commit()
            return
        }
        restorePoint = nil
        maximizedSlot = nil
        restore(id, minFraction: layout[id].isFloating ? minFraction(id) : minFraction(id.column))
    }

    /// Bring a collapsed slot back at the size it was collapsed at. The arithmetic
    /// lives in `WorkspaceLayout.expand` so it is testable without a store.
    func restore(_ id: SlotID, minFraction: Double) {
        layout.expand(id, minFraction: minFraction)
        commit()
    }

    /// Drag of the horizontal boundary between two rows. Rows have no pinned/flexible
    /// switch — pinning is a width concept — so this simply sets how the live rows split
    /// the height. `resolve` floors each row at its sections' minimum before applying it.
    func resizeRows(above: SlotRow, below: SlotRow, aboveFraction: Double) {
        let clamped = min(max(aboveFraction, 0.05), 0.95)
        layout[above].heightFraction = clamped
        layout[below].heightFraction = 1.0 - clamped
        commit()
    }

    func setBrowserURL(_ url: String?) {
        guard layout.browserURL != url else { return }
        layout.browserURL = url
        save()
    }

    func resetToDefault() {
        layout = WorkspaceLayout(browserURL: layout.browserURL)
        commit()
    }

    // MARK: - Persistence

    private func commit() {
        layout.normalize()
        save()
    }

    private func save() {
        guard loaded else { return }
        let snapshot = layout
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: Self.storageURL, options: .atomic)
            } catch {
                print("Failed to save layout: \(error)")
            }
        }
    }
}
