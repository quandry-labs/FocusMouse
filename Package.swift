// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "FocusMouse",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FocusMouse",
            path: "Sources/FocusMouse"
        ),
        .testTarget(
            name: "FocusMouseTests",
            dependencies: ["FocusMouse"],
            path: "Tests/FocusMouseTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
