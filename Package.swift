// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ExePort",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ExePortKit", targets: ["ExePortKit"]),
        .executable(name: "exeport", targets: ["exeport"]),
    ],
    targets: [
        .target(name: "ExePortKit", resources: [.copy("Resources/runtime-manifest.json")]),
        // The CLI logic is a library so tests can drive it; `exeport` is only the entry point.
        .target(name: "ExePortCLI", dependencies: ["ExePortKit"]),
        .executableTarget(name: "exeport", dependencies: ["ExePortCLI"]),
        .testTarget(name: "ExePortKitTests", dependencies: ["ExePortKit"]),
        .testTarget(name: "ExePortCLITests", dependencies: ["ExePortCLI"]),
    ]
)
