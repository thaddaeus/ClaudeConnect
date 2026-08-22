import XCTest
@testable import ConsoleForge

/// Opening a document as a tab.
///
/// The rule that matters most here is the one from Phase B: a document lives in the
/// DOCUMENT strip, and opening one must never move `activeTabID` — that is the console
/// strip's selection, and moving it unmounts the live terminal view.
@MainActor
final class DocumentTabTests: XCTestCase {

    private func tempFile(_ name: String = "note.md") throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cf-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try "# hello".write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    func testOpeningADocumentDoesNotMoveTheConsoleSelection() throws {
        let store = SessionStore(inMemory: true)
        let console = store.addSession()
        store.openTab(sessionID: console.id)
        let activeBefore = store.activeTabID

        _ = store.openDocumentTab(path: try tempFile(), parentTabID: console.id)

        XCTAssertEqual(store.activeTabID, activeBefore,
                       "moving activeTabID would unmount the terminal view")
    }

    func testTheDocumentLandsInTheDocumentStripNotTheConsoleStrip() throws {
        let store = SessionStore(inMemory: true)
        let console = store.addSession()
        store.openTab(sessionID: console.id)

        let id = store.openDocumentTab(path: try tempFile(), parentTabID: console.id)

        XCTAssertTrue(store.documentTabIDs.contains(id))
        XCTAssertFalse(store.terminalTabIDs.contains(id),
                       "a document has no PTY — every launch path filters on terminalTabIDs")
    }

    func testOpeningTheSameFileTwiceReusesItsTab() throws {
        let store = SessionStore(inMemory: true)
        let console = store.addSession()
        store.openTab(sessionID: console.id)
        let path = try tempFile()

        let first = store.openDocumentTab(path: path, parentTabID: console.id)
        let second = store.openDocumentTab(path: path, parentTabID: console.id)

        XCTAssertEqual(first, second, "the same file must not accumulate duplicate tabs")
        XCTAssertEqual(store.documentTabIDs.filter { $0 == first }.count, 1)
    }

    func testTheDocumentIsParentedToTheTabThatOpenedIt() throws {
        let store = SessionStore(inMemory: true)
        let console = store.addSession()
        store.openTab(sessionID: console.id)

        let id = store.openDocumentTab(path: try tempFile(), parentTabID: console.id)

        XCTAssertEqual(store.session(for: id)?.parentTabID, console.id,
                       "grouping is what makes a spoke's report findable next to its tab")
    }

    /// A tilde path is what a session will actually pass — the CLI expands it, but the
    /// store must not depend on that having happened.
    func testATildePathIsExpandedRatherThanTakenLiterally() throws {
        let store = SessionStore(inMemory: true)
        let console = store.addSession()
        store.openTab(sessionID: console.id)

        let id = store.openDocumentTab(path: "~/.zshrc", parentTabID: console.id)

        let stored = store.session(for: id)?.documentPath ?? ""
        XCTAssertFalse(stored.hasPrefix("~"), "stored as \(stored)")
    }
}
