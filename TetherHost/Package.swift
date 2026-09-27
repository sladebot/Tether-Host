// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TetherHost",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TetherHostCore", targets: ["TetherHostCore"])
    ],
    targets: [
        .target(
            name: "TetherHostCore",
            path: ".",
            exclude: ["Package.swift", "Tests", "App", "Views", "Resources"],
            sources: ["Models", "Services"]
        ),
        .testTarget(
            name: "TetherHostCoreTests",
            dependencies: ["TetherHostCore"],
            path: "Tests/TetherHostCoreTests"
        )
    ]
)
