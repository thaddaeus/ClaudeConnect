import XCTest
@testable import ConsoleForge

/// Tier 1: the pure grid arithmetic. No app, no AppKit, no SwiftTerm.
///
/// Every case here is a SITUATION that actually occurred, named so the situation is
/// legible without the ticket. Where a case exists because something shipped broken, the
/// test says so — a regression test that does not name its regression gets deleted by
/// someone tidying up in a year.
final class WorkspaceLayoutTests: XCTestCase {

    // MARK: - Columns are real (task 990039)

    func testBottomRightSitsUnderTopRightAtTheSameWidth() {
        var l = WorkspaceLayout()
        l[.topRight].section = .browser
        l[.bottomRight].section = .webConsole
        let r = l.resolve(in: CGSize(width: 1200, height: 800))
        let top = try? XCTUnwrap(r.tiled[.topRight])
        let bottom = try? XCTUnwrap(r.tiled[.bottomRight])
        guard let top, let bottom else { return XCTFail("both cells should be laid out") }
        XCTAssertEqual(top.minX, bottom.minX, accuracy: 0.5,
                       "a column owns one x for the whole window")
        XCTAssertEqual(top.width, bottom.width, accuracy: 0.5,
                       "…and one width; rows used to pack independently from x=0")
    }

    func testALoneSectionInTheBottomRowDoesNotSlideToTheLeftEdge() {
        // Shipped broken before 990039: alone in its row, a bottomRight panel began at
        // x = 0 and swallowed the full width, because rows packed occupied slots only.
        var l = WorkspaceLayout()
        l[.topLeft].section = .console
        l[.bottomRight].section = .webConsole
        let size = CGSize(width: 1200, height: 800)
        let r = l.resolve(in: size)
        guard let bottom = r.tiled[.bottomRight] else { return XCTFail("bottomRight missing") }
        XCTAssertGreaterThan(bottom.minX, 0, "it belongs to the right column, not the left edge")
        XCTAssertLessThan(bottom.width, size.width * 0.9, "and must not swallow the row")
    }

    // MARK: - Migration

    func testPreColumnLayoutKeepsTheWidthItWasSavedWith() throws {
        let l = try Fixture.layout("pre-column-legacy")
        XCTAssertEqual(l[.topLeft].section, .console,
                       "a pre-Y `left` id decodes into the top row")
        XCTAssertTrue(l[.left].isPinned,
                      "and its slot pin is lifted onto the COLUMN, so the width survives")
        XCTAssertEqual(l[.left].pinnedFraction, 0.5, accuracy: 0.001)
        let r = l.resolve(in: CGSize(width: 1000, height: 700))
        XCTAssertFalse(r.tiled.isEmpty, "a legacy file still resolves to something on screen")
    }

    // MARK: - The console floor

    func testConsoleKeepsItsWidthWhenASiblingCloses() {
        var l = WorkspaceLayout()
        l[.topLeft].section = .console
        l[.left].isPinned = true
        l[.left].pinnedFraction = 0.5
        l[.topRight].section = .browser
        let size = CGSize(width: 1400, height: 800)
        let withSibling = l.resolve(in: size).tiled[.topLeft]?.width
        l[.topRight].section = nil
        let alone = l.resolve(in: size).tiled[.topLeft]?.width
        XCTAssertEqual(withSibling, alone,
                       "the whole point of pinning: closing a browser must not resize the console")
    }
}
