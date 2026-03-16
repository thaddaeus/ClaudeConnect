// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ConsoleForge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ConsoleForge", targets: ["ConsoleForge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.0.0"),
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
