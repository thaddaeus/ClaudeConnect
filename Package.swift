// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ConsoleForge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ConsoleForge", targets: ["ConsoleForge"]),
    ],
    dependencies: [
        // Pinned to commit that fixes kitty keyboard protocol sequences being
        // misinterpreted as cursor restore (PR #500). Can revert to `from: "1.12.0"`
        // once a tagged release includes this fix.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git",
                 revision: "0f2af750fbc4b1c508b82fe863b907d19cca9ff9"),
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
