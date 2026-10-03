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
            exclude: ["Package.swift", "Tests", "App", "Views", "Resources", "Sources"],
            sources: ["Models", "Services"]
        ),
        .target(
            name: "TetherHostRuntime",
            dependencies: ["TetherHostCore"],
            path: "App",
            exclude: ["TetherHostApp.swift"]
        ),
        .testTarget(
            name: "TetherHostCoreTests",
            dependencies: ["TetherHostCore"],
            path: "Tests/TetherHostCoreTests"
        ),
        .testTarget(
            name: "TetherHostRuntimeTests",
            dependencies: ["TetherHostRuntime", "TetherHostCore"],
            path: "Tests/TetherHostRuntimeTests"
        )
    ]
)
