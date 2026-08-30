// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AudoraTranscriptReadBrokerQualification",
    platforms: [
        .macOS(.v13),
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
    ],
    targets: [
        .target(
            name: "AudoraTranscriptReadBroker",
            dependencies: [
                .product(
                    name: "AudoraCodexCLIQualification",
                    package: "CodexCLI"
                ),
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
