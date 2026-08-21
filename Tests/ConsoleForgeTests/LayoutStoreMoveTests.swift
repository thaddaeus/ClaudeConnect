import XCTest
@testable import ConsoleForge

/// Moving a section between slots.
///
/// Every case below is a PERMUTATION OF AN OCCUPIED TARGET. That is deliberate: v0.9.7
/// shipped with 28 resolver assertions and a green geometry pass and still broke this,
/// because every existing check moved sections between EMPTY cells. The infrastructure
/// was not missing; the permutation was.
@MainActor
final class LayoutStoreMoveTests: XCTestCase {

    /// v0.9.7 regression, fixed in v0.9.8. `move` swapped `.section` only, so
    /// `isCollapsed` / `isFloating` stayed with the CELL and each section inherited the
    /// other's presentation: the arriving panel went dark, the parked one appeared.
    func testMovingOntoAParkedSectionDoesNotInheritItsParkedState() throws {
        let store = LayoutStore(layout: try Fixture.layout("parked-in-occupied-cell"))
        XCTAssertEqual(store[.topLeft].section, .console)
        XCTAssertTrue(store[.topRight].isCollapsed, "fixture: Safari starts parked")

        store.move(.console, to: .topRight)

        XCTAssertEqual(store[.topRight].section, .console)
        XCTAssertFalse(store[.topRight].isCollapsed,
                       "the section you placed must be VISIBLE where you placed it")
        XCTAssertEqual(store[.topLeft].section, .browser)
        XCTAssertTrue(store[.topLeft].isCollapsed,
                      "the displaced section keeps its OWN state — it was parked, it stays parked")
    }

    func testMovingAParkedSectionOntoAVisibleOneKeepsItParked() throws {
        let store = LayoutStore(layout: try Fixture.layout("parked-in-occupied-cell"))
        store.move(.browser, to: .topLeft)   // the parked one moves onto the console

        XCTAssertTrue(store[.topLeft].isCollapsed, "still parked; a move is not an unhide")
        XCTAssertFalse(store[.topRight].isCollapsed, "and the displaced console is visible")
    }

    func testFloatingTravelsWithTheSectionIncludingItsWidth() throws {
        let store = LayoutStore(layout: try Fixture.layout("floating-narrow-right"))
        XCTAssertTrue(store[.topRight].isFloating)
        XCTAssertEqual(store[.topRight].floatingFraction, 0.33, accuracy: 0.001)

        store.move(.browser, to: .bottomRight)

        XCTAssertTrue(store[.bottomRight].isFloating, "it was floating; it still is")
        XCTAssertEqual(store[.bottomRight].floatingFraction, 0.33, accuracy: 0.001,
                       "and at the width it had, not the default")
        XCTAssertFalse(store[.topRight].isFloating, "the vacated cell is not left floating")
    }

    func testASectionThatCannotFloatNeverInheritsFloating() throws {
        let store = LayoutStore(layout: try Fixture.layout("floating-narrow-right"))
        store.move(.console, to: .topRight)   // onto the floating Safari
        XCTAssertFalse(store[.topRight].isFloating,
                       "the console cannot float, whatever the cell it arrives in was doing")
    }

    func testMovingOutOfACellLeavesItCleanRatherThanCollapsed() throws {
        let store = LayoutStore(layout: try Fixture.layout("parked-in-occupied-cell"))
        store.move(.browser, to: .bottomLeft)   // parked section to an EMPTY cell
        XCTAssertNil(store[.topRight].section)
        XCTAssertFalse(store[.topRight].isCollapsed,
                       "an empty cell must not keep a collapsed flag for the next arrival")
    }
}
