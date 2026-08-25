import XCTest
@testable import ConsoleForge

/// Focus when a session spawns a tab through `consoleforge-tab`.
///
/// The acceptance criteria are the two sentences of the rule, one test each:
/// the tab selection follows the tab you are on, and the APP never comes forward
/// unless you are already in it.
final class SpawnFocusTests: XCTestCase {

    private let hub = UUID()
    private let other = UUID()

    // MARK: - The regression (#28 fixed the tab, not the app)

    /// THE REPORTED BUG. A hub sitting on the active tab while the user works in another
    /// application satisfied #28's "you're on the spawning tab" rule perfectly, so every
    /// spoke it launched called `NSApp.activate(ignoringOtherApps:)` and kicked the user
    /// out of whatever they were doing.
    ///
    /// Fails against the pre-fix rule (`activatesApp == selectsTab`), which returns true
    /// here.
    func testSpokeDoesNotPullTheAppForwardWhenYouAreInAnotherApp() {
        let focus = SpawnFocus(parentTabID: hub, activeTabID: hub, appIsFrontmost: false)

        XCTAssertFalse(focus.activatesApp,
                       "a background app must never take the screen from another app")
    }

    /// The other half of the same case: not taking the screen must not also mean losing
    /// the tab. It is selected, so it is in front when you come back on your own.
    func testTheSpokeIsStillSelectedWhileYouAreAway() {
        let focus = SpawnFocus(parentTabID: hub, activeTabID: hub, appIsFrontmost: false)

        XCTAssertTrue(focus.selectsTab,
                      "selection moves inside a window you are not looking at; it costs nothing")
    }

    // MARK: - What #28 established, unchanged

    func testSpawningFromTheTabYouAreOnFocusesItWhenYouAreInTheApp() {
        let focus = SpawnFocus(parentTabID: hub, activeTabID: hub, appIsFrontmost: true)

        XCTAssertTrue(focus.selectsTab)
        XCTAssertTrue(focus.activatesApp)
    }

    func testSpawningFromATabYouAreNotOnOpensInTheBackground() {
        let focus = SpawnFocus(parentTabID: hub, activeTabID: other, appIsFrontmost: true)

        XCTAssertFalse(focus.selectsTab,
                       "a hub spawning spokes must not yank you off the tab you are reading")
        XCTAssertFalse(focus.activatesApp)
    }

    /// No live parent — never had one, or it died and resolution left it nil. There is no
    /// "tab you are on" to follow, so it opens in the background rather than defaulting
    /// to focus.
    func testATabWithNoLiveParentNeverTakesFocus() {
        for frontmost in [true, false] {
            let focus = SpawnFocus(parentTabID: nil, activeTabID: nil, appIsFrontmost: frontmost)

            XCTAssertFalse(focus.selectsTab)
            XCTAssertFalse(focus.activatesApp)
        }
    }

    /// A nil parent must not match a nil selection into "the parent is active".
    func testNilParentDoesNotMatchAnEmptySelection() {
        let focus = SpawnFocus(parentTabID: nil, activeTabID: nil, appIsFrontmost: true)

        XCTAssertFalse(focus.selectsTab)
    }
}
