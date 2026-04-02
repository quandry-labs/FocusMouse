// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "FocusMouse",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FocusMouse",
            path: "Sources/FocusMouse",
            resources: [.process("../../Resources")]
        ),
        .testTarget(
            name: "FocusMouseTests",
            dependencies: ["FocusMouse"],
            path: "Tests/FocusMouseTests"
        ),
    ]
)
