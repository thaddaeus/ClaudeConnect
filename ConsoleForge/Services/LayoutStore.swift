import Foundation
import SwiftUI

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

    /// Drag of the boundary between two adjacent tiled slots. The leading slot becomes
    /// pinned at the dragged fraction (that is what a splitter means); a trailing slot
    /// that is *also* pinned gives up exactly what the leading one gained, so the pair
    /// keeps its combined share and nothing beyond the boundary moves.
    func resizeBoundary(leading: SlotID, trailing: SlotID, leadingFraction: Double,
                        trailingFraction: Double?, windowWidth: CGFloat) {
        let floor = max(Double(WorkspaceLayout.minSlotWidth) / Double(max(windowWidth, 1)),
                        WorkspaceLayout.minPinnedFraction)
        guard let trailingFraction else {
            layout[leading].isPinned = true
            layout[leading].pinnedFraction = min(max(leadingFraction, floor), 1.0 - floor)
            commit()
            return
        }
        let total = leadingFraction + trailingFraction
        let newLeading = min(max(leadingFraction, floor), max(floor, total - floor))
        layout[leading].isPinned = true
        layout[leading].pinnedFraction = newLeading
        layout[trailing].isPinned = true
        layout[trailing].pinnedFraction = max(total - newLeading, floor)
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
