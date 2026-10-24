// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EscApp",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EscAppKit", targets: ["EscAppKit"]),
        .executable(name: "escapp", targets: ["escapp"]),
    ],
    targets: [
        .target(name: "EscAppKit", resources: [.copy("Resources/runtime-manifest.json"),
                                                .copy("Resources/chromium-helper.exe"),
                                                .copy("Resources/window-keeper.exe"),
                                                .copy("Resources/store-windows.exe")]),
        // The CLI logic is a library so tests can drive it; `escapp` is only the entry point.
        .target(name: "EscAppCLI", dependencies: ["EscAppKit"]),
        .executableTarget(name: "escapp", dependencies: ["EscAppCLI"]),
        .testTarget(name: "EscAppKitTests", dependencies: ["EscAppKit"]),
        .testTarget(name: "EscAppCLITests", dependencies: ["EscAppCLI"]),
    ]
)
