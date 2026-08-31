// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AudoraCodexCLIQualification",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "AudoraCodexCLIQualification",
            targets: ["AudoraCodexCLIQualification"]
        ),
        .executable(
            name: "codex-cli-qualification",
            targets: ["CodexCLIQualificationCommand"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/AudoraCore"),
    ],
    targets: [
        .target(
            name: "AudoraCodexCLIQualification",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "CodexCLIQualificationCommand",
            dependencies: ["AudoraCodexCLIQualification"]
        ),
        .testTarget(
            name: "AudoraCodexCLIQualificationTests",
            dependencies: [
                "AudoraCodexCLIQualification",
                .product(name: "AudoraApplication", package: "AudoraCore"),
            ]
        ),
    ]
)
