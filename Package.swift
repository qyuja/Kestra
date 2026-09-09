// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "IslandBarDemo",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "IslandBarDemo", targets: ["IslandBarDemo"])
    ],
    targets: [
        .executableTarget(
            name: "IslandBarDemo",
            path: "Sources/IslandBarDemo",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "IslandBarDemoTests",
            dependencies: ["IslandBarDemo"]
        )
    ]
)
