import XCTest
@testable import ConsoleForge

/// An empty cell always RESERVES space — the columns have to line up — but it should only
/// DRAW itself when the drawing tells the user something.
///
/// Observed 2026-08-28: opening Web Output into `bottomCenter` made the bottom row live
/// across all three live columns, so a two-panel window rendered THREE labelled dashed
/// rectangles (topCenter, bottomLeft, bottomRight). One panel manufactured three empty
/// ones, and the grid was effectively announcing its own internal structure at the user.
final class GapPaintingTests: XCTestCase {

    /// The reported bug, stated directly.
    func testAnIncidentalEmptyCellDoesNotPaintItself() {
        XCTAssertFalse(WorkspaceLayout.shouldPaintGap(held: false, isDragging: false))
    }

    /// Mid-drag it is a real drop target the pointer aims at, so it must be visible.
    func testEveryEmptyCellPaintsWhileADragIsInFlight() {
        XCTAssertTrue(WorkspaceLayout.shouldPaintGap(held: false, isDragging: true))
        XCTAssertTrue(WorkspaceLayout.shouldPaintGap(held: true, isDragging: true))
    }

    /// A pinned-and-empty column is a position the user deliberately held open. Hiding it
    /// would leave them no evidence of their own reservation.
    func testADeliberatelyHeldColumnStaysVisibleWhenIdle() {
        XCTAssertTrue(WorkspaceLayout.shouldPaintGap(held: true, isDragging: false))
    }

    /// The screenshot's exact arrangement: console topLeft, Safari topRight, Web Output
    /// bottomCenter — 2 live rows x 3 live columns, 3 occupied, 3 incidental gaps. None of
    /// them should paint while idle; all should while dragging.
    func testTheReportedThreePanelArrangementShowsNoPlaceholdersWhenIdle() {
        let incidentalGaps = 3
        let paintedIdle = (0..<incidentalGaps).filter {
            _ in WorkspaceLayout.shouldPaintGap(held: false, isDragging: false)
        }.count
        let paintedDragging = (0..<incidentalGaps).filter {
            _ in WorkspaceLayout.shouldPaintGap(held: false, isDragging: true)
        }.count
        XCTAssertEqual(paintedIdle, 0)
        XCTAssertEqual(paintedDragging, incidentalGaps)
    }
}
