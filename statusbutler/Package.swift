// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "StatusButler",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "StatusButler", targets: ["StatusButler"])
    ],
    targets: [
        .target(
            name: "StatusButlerCore",
            path: "Sources/StatusButlerCore"
        ),
        .executableTarget(
            name: "StatusButler",
            dependencies: ["StatusButlerCore"],
            path: "Sources/StatusButler"
        ),
        .testTarget(
            name: "StatusButlerCoreTests",
            dependencies: ["StatusButlerCore"],
            path: "Tests/StatusButlerCoreTests"
        )
    ]
)
