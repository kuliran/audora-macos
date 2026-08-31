// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AudoraCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AudoraDomain", targets: ["AudoraDomain"]),
        .library(name: "AudoraApplication", targets: ["AudoraApplication"]),
        .library(name: "AudoraContracts", targets: ["AudoraContracts"]),
    ],
    targets: [
        .target(name: "AudoraDomain"),
        .target(
            name: "AudoraApplication",
            dependencies: ["AudoraDomain"]
        ),
        .target(
            name: "AudoraContracts",
            resources: [
                .copy("Resources/Examples"),
                .copy("Resources/Scenarios"),
                .copy("Resources/Schemas"),
            ]
        ),
        .testTarget(
            name: "AudoraDomainTests",
            dependencies: ["AudoraDomain"]
        ),
        .testTarget(
            name: "AudoraApplicationTests",
            dependencies: ["AudoraApplication", "AudoraDomain"]
        ),
        .testTarget(
            name: "AudoraContractsTests",
            dependencies: ["AudoraContracts", "AudoraDomain"]
        ),
        .testTarget(
            name: "AudoraFeatureScenarioTests",
            dependencies: [
                "AudoraApplication",
                "AudoraContracts",
                "AudoraDomain",
            ]
        ),
    ]
)
