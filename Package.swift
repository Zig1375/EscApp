// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Plaviox",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PlavioxKit", targets: ["PlavioxKit"]),
        .executable(name: "plaviox", targets: ["plaviox"]),
    ],
    targets: [
        .target(name: "PlavioxKit", resources: [.copy("Resources/runtime-manifest.json"),
                                                .copy("Resources/game-modules.json"),
                                                .copy("Resources/chromium-helper.exe"),
                                                .copy("Resources/window-keeper.exe"),
                                                .copy("Resources/store-windows.exe")]),
        // The CLI logic is a library so tests can drive it; `plaviox` is only the entry point.
        .target(name: "PlavioxCLI", dependencies: ["PlavioxKit"]),
        .executableTarget(name: "plaviox", dependencies: ["PlavioxCLI"]),
        .testTarget(name: "PlavioxKitTests", dependencies: ["PlavioxKit"]),
        .testTarget(name: "PlavioxCLITests", dependencies: ["PlavioxCLI"]),
    ]
)
