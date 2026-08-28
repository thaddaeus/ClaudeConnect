import XCTest
@testable import ConsoleForge

/// A column holding exactly ONE section spans the live rows.
///
/// Rows exist to divide a column between two sections. Where there is only one, there is
/// nothing to divide, and the row boundary was pure loss. Reported 2026-08-28 with a
/// screenshot: console topLeft, Safari topRight, Web Output bottomCenter — one panel in
/// the bottom row made that row live across ALL live columns, so the left and right
/// columns each had to leave their bottom cell empty. Three panels, three dead cells, and
/// a console shortened for nothing.
final class ColumnSpanTests: XCTestCase {

    private let size = CGSize(width: 1600, height: 900)

    /// `defaultSlots` seeds a console into `.topCenter`, so a bare `WorkspaceLayout()`
    /// is NOT an empty grid. Every case here places its own sections and would otherwise
    /// be quietly testing a phantom fourth panel.
    private func emptyLayout() -> WorkspaceLayout {
        WorkspaceLayout(slots: SlotID.allCases.map { SlotConfiguration(id: $0, section: nil) })
    }

    /// The exact reported arrangement.
    private func reportedLayout() -> WorkspaceLayout {
        var l = emptyLayout()
        l[.topLeft].section = .console
        l[.topRight].section = .browser
        l[.bottomCenter].section = .webConsole
        return l
    }

    func testTheReportedArrangementLeavesNoEmptyCellsAtAll() {
        let r = reportedLayout().resolve(in: size)
        XCTAssertTrue(r.gaps.isEmpty,
                      "one panel in the bottom row should not cost two dead cells; got \(r.gaps.keys)")
        XCTAssertEqual(Set(r.tiled.keys), [.topLeft, .topRight, .bottomCenter])
    }

    func testEachLoneSectionFillsItsColumnTopToBottom() {
        let r = reportedLayout().resolve(in: size)
        for id in [SlotID.topLeft, .topRight, .bottomCenter] {
            guard let rect = r.tiled[id] else { return XCTFail("\(id) missing") }
            XCTAssertEqual(rect.minY, 0, accuracy: 0.5, "\(id) should start at the top")
            XCTAssertEqual(rect.height, size.height, accuracy: 0.5,
                           "\(id) is alone in its column, so it owns the column's height")
        }
    }

    /// The console is the reason this matters: it was being shortened by a row it had
    /// nothing in.
    func testTheConsoleIsNotShortenedByAPanelInAnotherColumnsBottomRow() {
        var lone = emptyLayout()
        lone[.topLeft].section = .console
        let alone = lone.resolve(in: size).tiled[.topLeft]?.height
        let withNeighbour = reportedLayout().resolve(in: size).tiled[.topLeft]?.height
        XCTAssertEqual(alone, withNeighbour,
                       "Web Output living in another column must not cost the console height")
    }

    /// The rule is per column, so a genuinely divided column still splits into rows.
    func testAColumnHoldingTwoSectionsStillSplitsIntoRows() {
        var l = emptyLayout()
        l[.topRight].section = .browser
        l[.bottomRight].section = .webConsole
        let r = l.resolve(in: size)
        guard let top = r.tiled[.topRight], let bottom = r.tiled[.bottomRight] else {
            return XCTFail("both cells should be laid out")
        }
        XCTAssertLessThan(top.height, size.height, "a divided column does not span")
        XCTAssertGreaterThan(bottom.minY, 0, "the second section sits below the first")
        XCTAssertEqual(top.height + bottom.height, size.height, accuracy: 1.0)
    }

    /// A row splitter divides a column between two sections. With every column spanning
    /// there is no such column, so the handle would edit a number nothing renders.
    func testNoRowSplitterIsOfferedWhenEveryColumnSpans() {
        XCTAssertTrue(reportedLayout().resolve(in: size).rowSplitters.isEmpty)
    }

    func testARowSplitterIsStillOfferedWhenAColumnIsActuallyDivided() {
        var l = emptyLayout()
        l[.topLeft].section = .console
        l[.topRight].section = .browser
        l[.bottomRight].section = .webConsole
        XCTAssertFalse(l.resolve(in: size).rowSplitters.isEmpty,
                       "the right column is divided, so its boundary is draggable")
    }

    /// A column deliberately pinned and EMPTY is a reservation, not a span — there is no
    /// occupant to stretch, and the held space must stay held.
    func testAPinnedEmptyColumnStillHoldsItsSpace() {
        var l = emptyLayout()
        l[.topLeft].section = .console
        l[.bottomRight].section = .webConsole
        l[.center].isPinned = true
        l[.center].pinnedFraction = 0.25
        let r = l.resolve(in: size)
        XCTAssertTrue(r.gaps.keys.contains { $0.column == .center },
                      "a pinned empty column is a position held open, and must still show")
    }

    /// Single-row layouts are unchanged by any of this.
    func testASingleLiveRowIsUnaffected() {
        var l = emptyLayout()
        l[.topLeft].section = .console
        l[.topRight].section = .browser
        let r = l.resolve(in: size)
        XCTAssertTrue(r.gaps.isEmpty)
        for id in [SlotID.topLeft, .topRight] {
            XCTAssertEqual(r.tiled[id]?.height ?? 0, size.height, accuracy: 0.5)
        }
    }
}
