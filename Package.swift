// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MagicKettle",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MagicKettleKit", targets: ["MagicKettleKit"]),
        .executable(name: "kettle", targets: ["kettle"]),
    ],
    targets: [
        .target(name: "MagicKettleKit", resources: [.copy("Resources/runtime-manifest.json"),
                                                    .copy("Resources/game-modules.json"),
                                                    .copy("Resources/chromium-helper.exe"),
                                                    .copy("Resources/window-keeper.exe"),
                                                    .copy("Resources/store-windows.exe"),
                                                    .copy("Resources/disc-changer.exe")]),
        // The CLI logic is a library so tests can drive it; `kettle` is only the entry point.
        .target(name: "MagicKettleCLI", dependencies: ["MagicKettleKit"]),
        .executableTarget(name: "kettle", dependencies: ["MagicKettleCLI"]),
        .testTarget(name: "MagicKettleKitTests", dependencies: ["MagicKettleKit"]),
        .testTarget(name: "MagicKettleCLITests", dependencies: ["MagicKettleCLI"]),
    ]
)
