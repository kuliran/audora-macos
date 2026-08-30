// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AudoraCore",
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
            resources: [.process("Resources")]
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
            dependencies: ["AudoraContracts"]
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
