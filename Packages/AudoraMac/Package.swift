// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AudoraMac",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "AudoraMacInfrastructure",
            targets: ["AudoraMacInfrastructure"]
        ),
        .library(
            name: "AudoraMacPresentation",
            targets: ["AudoraMacPresentation"]
        ),
    ],
    dependencies: [
        .package(path: "../AudoraCore"),
    ],
    targets: [
        .target(
            name: "AudoraMacInfrastructure",
            dependencies: [
                .product(name: "AudoraApplication", package: "AudoraCore"),
                .product(name: "AudoraDomain", package: "AudoraCore"),
            ]
        ),
        .target(
            name: "AudoraMacPresentation",
            dependencies: [
                .product(name: "AudoraApplication", package: "AudoraCore"),
                .product(name: "AudoraDomain", package: "AudoraCore"),
            ]
        ),
        .testTarget(
            name: "AudoraMacInfrastructureTests",
            dependencies: [
                "AudoraMacInfrastructure",
                .product(name: "AudoraApplication", package: "AudoraCore"),
                .product(name: "AudoraContracts", package: "AudoraCore"),
                .product(name: "AudoraDomain", package: "AudoraCore"),
            ]
        ),
        .testTarget(
            name: "AudoraMacPresentationTests",
            dependencies: [
                "AudoraMacPresentation",
                .product(name: "AudoraApplication", package: "AudoraCore"),
                .product(name: "AudoraDomain", package: "AudoraCore"),
            ]
        ),
    ]
)
