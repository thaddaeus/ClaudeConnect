import Foundation
import XCTest
@testable import ConsoleForge

/// Loads the shared fixtures in `Tests/Fixtures`.
///
/// The SAME files the live harnesses in `scripts/` copy into the beta support directory.
/// That is the point: a permutation checked here and one driven through the real UI must
/// start from identical state, or the two tiers quietly diverge and each assumes the other
/// covered the case.
enum Fixture {
    static func layout(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> WorkspaceLayout {
        let data = try Data(contentsOf: url("layout/\(name).json", file: file, line: line))
        var layout = try JSONDecoder().decode(WorkspaceLayout.self, from: data)
        // Decode alone is not the state the app runs on — `normalize` is what repairs and
        // migrates. Tests must see what the app sees.
        layout.normalize()
        return layout
    }

    static func url(_ relative: String, file: StaticString = #filePath, line: UInt = #line) -> URL {
        // Resolved from the SOURCE TREE, not a test bundle, precisely so the python
        // harnesses in `scripts/` can read the identical path. A bundle-only lookup
        // would split the two tiers onto different copies.
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // ConsoleForgeTests
            .deletingLastPathComponent()   // Tests
        let onDisk = root.appendingPathComponent("Fixtures/\(relative)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: onDisk.path),
                      "fixture not found: \(relative)", file: file, line: line)
        return onDisk
    }
}
