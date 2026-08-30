// swift-tools-version: 5.10

import PackageDescription

let package = Package(
  name: "AudoraReleaseExecution",
  platforms: [
    .macOS("15.0")
  ],
  products: [
    .library(
      name: "ReleaseExecutionCore",
      targets: ["ReleaseExecutionCore"]
    ),
    .executable(
      name: "release-execution-spike",
      targets: ["ReleaseExecutionSpike"]
    ),
  ],
  targets: [
    .target(
      name: "ReleaseExecutionPOSIX",
      publicHeadersPath: "include"
    ),
    .target(
      name: "ReleaseExecutionCore",
      dependencies: ["ReleaseExecutionPOSIX"]
    ),
    .executableTarget(
      name: "ReleaseExecutionSpike",
      dependencies: ["ReleaseExecutionCore"]
    ),
    .testTarget(
      name: "ReleaseExecutionCoreTests",
      dependencies: ["ReleaseExecutionCore"]
    ),
  ]
)
