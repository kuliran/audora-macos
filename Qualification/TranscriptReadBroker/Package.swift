// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AudoraTranscriptReadBrokerQualification",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "AudoraTranscriptReadBroker",
            targets: ["AudoraTranscriptReadBroker"]
        ),
        .executable(
            name: "transcript-read-broker-qualification",
            targets: ["TranscriptReadBrokerQualificationCommand"]
        ),
    ],
    dependencies: [
        .package(path: "../CodexCLI"),
        .package(path: "../../Packages/AudoraCore"),
    ],
    targets: [
        .target(
            name: "AudoraTranscriptReadBroker",
            dependencies: [
                .product(
                    name: "AudoraCodexCLIQualification",
                    package: "CodexCLI"
                ),
                .product(name: "AudoraApplication", package: "AudoraCore"),
            ]
        ),
        .executableTarget(
            name: "TranscriptReadBrokerQualificationCommand",
            dependencies: ["AudoraTranscriptReadBroker"]
        ),
        .testTarget(
            name: "AudoraTranscriptReadBrokerTests",
            dependencies: [
                "AudoraTranscriptReadBroker",
                .product(
                    name: "AudoraCodexCLIQualification",
                    package: "CodexCLI"
                ),
            ]
        ),
    ]
)
