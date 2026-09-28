// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgentDeputy",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "AgentDeputy", targets: ["AgentDeputy"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "AgentDeputy",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/AgentDeputy",
            resources: [
                .process("Resources"),
                .copy("../../agentdeputy-logo/logo-template.svg")
            ]
        ),
        .testTarget(
            name: "AgentDeputyTests",
            dependencies: ["AgentDeputy"]
        )
    ]
)
