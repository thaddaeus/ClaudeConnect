// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ConsoleForge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ConsoleForge", targets: ["ConsoleForge"]),
    ],
    dependencies: [
        // Was pinned to the bare revision 0f2af750 for PR #500 (kitty keyboard
        // sequences misinterpreted as cursor restore); that fix ships in every
        // tag from v1.13.0 on, so the pin is a release tag again.
        //
        // EXACT, never `from:`. SwiftTerm owns the buffer model behind the
        // permanent-garble class (tasks 9543 / 9487), so a bump is a change to
        // be verified — `./scripts/geometry-pass.py` on beta — not a floor to
        // float on. Two things in v1.16.0+ are why that is not paranoia: the
        // cell width now snaps to the NEAREST device pixel instead of rounding
        // up (Menlo 11 is 6.5pt at 2x, 7.0pt at 1x — the cell is backing-scale
        // dependent, and `TerminalMetrics` mirrors that arithmetic), and the
        // per-cell write path gained semantic/bidi state (~12% slower
        // insertCharacter in SwiftTerm's own benchmark).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git",
                 exact: "1.19.0"),
        // Sparkle auto-update framework. Distributed as a prebuilt binary artifact
        // (Sparkle.framework + the generate_keys / generate_appcast tools).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3"),
    ],
    targets: [
        .executableTarget(
            name: "ConsoleForge",
            dependencies: ["SwiftTerm", "Sparkle"],
            path: "ConsoleForge",
            exclude: ["Assets.xcassets"],
            linkerSettings: [
                // Resolve the Sparkle.framework embedded at Contents/Frameworks in
                // the packaged .app. The binary links @rpath/Sparkle.framework/...;
                // without this rpath only the dev build (framework sitting next to the
                // binary in .build, found via @loader_path) would load it, and a
                // dev.sh hot-swap into /Applications would crash on the missing dylib.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
    ]
)
