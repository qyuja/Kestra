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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "Kestra",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
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
