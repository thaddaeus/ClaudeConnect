import Foundation
import SwiftUI

/// What a live splitter drag is doing to the sections either side of it, so the
/// workspace can show it rather than letting a section vanish without warning.
enum BoundaryFeedback: Equatable {
    case free
    /// Sitting on a section's minimum width. The drag is clamped here.
    case atMinimum(SlotID)
    /// Dragged far enough past the minimum that releasing will collapse it.
    case willCollapse(SlotID)

    var slot: SlotID? {
        switch self {
        case .free: nil
        case .atMinimum(let id), .willCollapse(let id): id
        }
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

    func minFraction(_ id: SlotID) -> Double {
        let min = layout[id].section.flatMap { sectionMinWidths[$0] } ?? WorkspaceLayout.minSlotWidth
        return Double(min / max(workspaceWidth, 1))
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
    /// a lone console looks exactly as it did before slots existed.
    var showsSectionChrome: Bool { layout.openSectionCount > 1 }

    var browserURL: String? { layout.browserURL }

    // MARK: - Mutations

    /// Move a section into `target`. If another section already holds that slot the
    /// two swap, so a move never silently closes anything.
    func move(_ section: SectionKind, to target: SlotID) {
        guard let source = layout.slot(holding: section), source.id != target else { return }
        let displaced = layout[target].section
        layout[target].section = section
        layout[source.id].section = displaced
        if displaced?.canFloat == false { layout[source.id].isFloating = false }
        if layout[source.id].section == nil { layout[source.id].isFloating = false }
        commit()
    }

    /// Open a closed section in the first available slot (preferring the far side of
    /// the window from the console), or focus it if already open.
    func open(_ section: SectionKind) {
        guard !layout.isOpen(section) else { return }
        let preferred: [SlotID] = [.right, .left, .center]
        guard let target = preferred.first(where: { layout[$0].section == nil }) else { return }
        layout[target].section = section
        commit()
    }

    func close(_ section: SectionKind) {
        guard section.isClosable, let slot = layout.slot(holding: section) else { return }
        // Keep the slot's own size/display settings — reopening lands back in the same
        // arrangement — and only vacate it.
        layout[slot.id].section = nil
        layout[slot.id].isFloating = false
        commit()
    }

    func toggle(_ section: SectionKind) {
        layout.isOpen(section) ? close(section) : open(section)
    }

    func pin(_ id: SlotID, fraction: Double) {
        layout[id].isPinned = true
        layout[id].pinnedFraction = min(max(fraction, WorkspaceLayout.minPinnedFraction), 1.0)
        commit()
    }

    func makeFlexible(_ id: SlotID) {
        layout[id].isPinned = false
        commit()
    }

    func setFloating(_ id: SlotID, _ floating: Bool) {
        guard layout[id].section?.canFloat == true else { return }
        layout[id].isFloating = floating
        commit()
    }

    func setFloatingFrame(_ id: SlotID, _ rect: CGRect, in size: CGSize) {
        layout[id].floatingFrame = NormalizedRect.from(rect, in: size)
        commit()
    }

    /// How far past a section's minimum width the pointer must travel before releasing
    /// will collapse it. The section stops at its minimum and *stays* there for this
    /// distance — the detent that stops a drag from snapping shut the instant it
    /// touches the floor.
    static let collapseOvershoot: CGFloat = 56

    /// Drag of the boundary between two adjacent tiled slots. The leading slot becomes
    /// pinned at the dragged fraction (that is what a splitter means); a trailing slot
    /// that is *also* pinned gives up exactly what the leading one gained, so the pair
    /// keeps its combined share and nothing beyond the boundary moves.
    ///
    /// Neither section is ever laid out below its minimum: the drag CLAMPS there.
    /// Dragging further returns `.willCollapse`, and it is the caller's release that
    /// commits the collapse — nothing disappears mid-gesture.
    @discardableResult
    func resizeBoundary(leading: SlotID, trailing: SlotID, leadingFraction: Double,
                        trailingFraction: Double?, windowWidth: CGFloat,
                        leadingMin: CGFloat, trailingMin: CGFloat) -> BoundaryFeedback {
        let width = max(windowWidth, 1)
        let leadFloor = max(Double(leadingMin / width), WorkspaceLayout.minPinnedFraction)
        let trailFloor = max(Double(trailingMin / width), WorkspaceLayout.minPinnedFraction)
        let overshoot = Double(Self.collapseOvershoot / width)

        var feedback = BoundaryFeedback.free
        if leadingFraction < leadFloor - overshoot {
            feedback = .willCollapse(leading)
        } else if leadingFraction <= leadFloor {
            feedback = .atMinimum(leading)
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
            feedback = .willCollapse(trailing)
        } else if total - leadingFraction <= trailFloor, case .free = feedback {
            feedback = .atMinimum(trailing)
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
        guard layout[id].section != nil, !layout[id].isFloating else { return }
        layout[id].isCollapsed = true
        if maximizedSlot == id { maximizedSlot = nil }
        commit()
    }

    /// Full width. Every other TILED section collapses to a rail to make room —
    /// floating sections are untouched, since they overlay rather than compete for
    /// width. `normal` puts it all back.
    func maximize(_ id: SlotID) {
        guard layout[id].section != nil, !layout[id].isFloating else { return }
        if restorePoint == nil { restorePoint = layout }
        layout[id].isCollapsed = false
        layout[id].isPinned = false
        for slot in layout.slots where slot.id != id && slot.section != nil && !slot.isFloating {
            layout[slot.id].isCollapsed = true
        }
        maximizedSlot = id
        commit()
    }

    /// Back to the arrangement before the maximize, or — if there was none — simply
    /// visible and flexible again, with pinned neighbours scaled down until this slot
    /// clears `minFraction`. Always succeeds; it is the only way off a rail.
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
        restore(id, minFraction: minFraction(id))
    }

    /// Bring a collapsed slot back: make it flexible, and if pinned neighbours are what
    /// crowded it out, scale them down until `minFraction` of the window is free. The
    /// only escape from a rail, so it must always succeed.
    func restore(_ id: SlotID, minFraction: Double) {
        layout[id].isPinned = false
        layout[id].isFloating = false
        layout[id].isCollapsed = false
        let others = layout.slots.filter {
            $0.id != id && $0.section != nil && !$0.isFloating && $0.isPinned
        }
        let sum = others.reduce(0.0) { $0 + $1.pinnedFraction }
        let budget = max(0, 1.0 - minFraction)
        if sum > budget, sum > 0 {
            let scale = budget / sum
            for other in others {
                layout[other.id].pinnedFraction =
                    max(other.pinnedFraction * scale, WorkspaceLayout.minPinnedFraction)
            }
        }
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
