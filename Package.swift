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
    ],
    targets: [
        .executableTarget(
            name: "ConsoleForge",
            dependencies: ["SwiftTerm"],
            path: "ConsoleForge",
            exclude: ["Assets.xcassets"]
        ),
    ]
)
