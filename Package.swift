// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Kestra",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Kestra", targets: ["Kestra"])
    ],
    targets: [
        .executableTarget(
            name: "Kestra",
            path: "Sources/Kestra",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "KestraTests",
            dependencies: ["Kestra"]
        )
    ]
)
