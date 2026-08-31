import AudoraApplication
@testable import AudoraMacInfrastructure
import XCTest

final class CrisperPinnedQualificationRuntimeTests: XCTestCase {
    func testReviewedBlockedArtifactsCannotLaunchProductionProfile() async throws {
        let root = repositoryRoot()
        let runtime = CrisperPinnedQualificationRuntime(
            engineLockData: try Data(
                contentsOf: root.appendingPathComponent(
                    "Qualification/CrisperBenchmark/engine-lock.v1.json"
                )
            ),
            qualificationArtifactData: try Data(
                contentsOf: root.appendingPathComponent(
                    "Qualification/CrisperBenchmark/results/2026-08-30-local-preflight.json"
                )
            )
        )

        let resolution = await runtime.resolve()

        XCTAssertEqual(
            resolution,
            .unavailable(
                .qualificationBlocked(
                    profileID: "crisperwhisper-2-small-transformers-mps-v1"
                )
            )
        )
    }

    func testLockDriftFailsClosedInsteadOfSelectingAnotherEngine() async throws {
        let root = repositoryRoot()
        var lock = try Data(
            contentsOf: root.appendingPathComponent(
                "Qualification/CrisperBenchmark/engine-lock.v1.json"
            )
        )
        lock.append(0x20)
        let runtime = CrisperPinnedQualificationRuntime(
            engineLockData: lock,
            qualificationArtifactData: try Data(
                contentsOf: root.appendingPathComponent(
                    "Qualification/CrisperBenchmark/results/2026-08-30-local-preflight.json"
                )
            )
        )

        let resolution = await runtime.resolve()
        XCTAssertEqual(resolution, .unavailable(.runtimeLockMismatch))
    }

    func testMissingBundledProofRemainsExplicitlyUnavailable() async {
        let runtime = CrisperPinnedQualificationRuntime()

        let resolution = await runtime.resolve()
        XCTAssertEqual(
            resolution,
            .unavailable(
                .qualificationBlocked(
                    profileID: "crisperwhisper-2-small-transformers-mps-v1"
                )
            )
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
