// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Rum",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RumKit", targets: ["RumKit"]),
        .executable(name: "rum", targets: ["rum"]),
    ],
    targets: [
        .target(name: "RumKit"),
        // The CLI logic is a library so tests can drive it; `rum` is only the entry point.
        .target(name: "RumCLI", dependencies: ["RumKit"]),
        .executableTarget(name: "rum", dependencies: ["RumCLI"]),
        .testTarget(name: "RumKitTests", dependencies: ["RumKit"]),
        .testTarget(name: "RumCLITests", dependencies: ["RumCLI"]),
    ]
)
