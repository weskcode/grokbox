// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GrokboxCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "GrokboxCore", targets: ["GrokboxCore"])
    ],
    targets: [
        .target(
            name: "GrokboxCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GrokboxCoreTests",
            dependencies: ["GrokboxCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
