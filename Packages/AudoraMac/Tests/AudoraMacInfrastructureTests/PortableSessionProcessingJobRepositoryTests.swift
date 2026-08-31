import AudoraApplication
import AudoraDomain
@testable import AudoraMacInfrastructure
import Foundation
import XCTest

final class PortableSessionProcessingJobRepositoryTests: XCTestCase {
    func testQueuedJobAndCASStateAreDurableAcrossRepositoryInstances() async throws {
        try await withLibrary { root, libraryID in
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let queued = try makeJob(state: .queued)

            let createResult = await repository.create(queued)
            XCTAssertEqual(createResult, .written(queued))
            let jobData = try Data(
                contentsOf: root
                    .appendingPathComponent("jobs")
                    .appendingPathComponent(queued.jobID.rawValue)
                    .appendingPathComponent("job.json")
            )
            let jobObject = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: jobData) as? [String: Any]
            )
            XCTAssertTrue(jobObject["expectedSelectedRevisionId"] is NSNull)
            let running = queued.replacing(state: .running)
            let transitionResult = await repository.transition(running, from: .queued)
            XCTAssertEqual(transitionResult, .written(running))
            let reopened = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )

            let reloaded = await reopened.latest(
                for: try makeSelection(libraryID: libraryID)
            )
            XCTAssertEqual(reloaded, .loaded(running))
        }
    }

    func testStaleTransitionCannotOverwriteCurrentState() async throws {
        try await withLibrary { root, libraryID in
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let queued = try makeJob(state: .queued)
            _ = await repository.create(queued)
            let running = queued.replacing(state: .running)
            _ = await repository.transition(running, from: .queued)

            let stale = running.replacing(
                state: .failed,
                failure: .engineFailed
            )
            let transitionResult = await repository.transition(stale, from: .queued)
            XCTAssertEqual(transitionResult, .stale)
            let reloaded = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )
            XCTAssertEqual(reloaded, .loaded(running))
        }
    }

    func testCancellationIntentAndAuthorityAreDurableAndCannotBeCleared() async throws {
        try await withLibrary { root, libraryID in
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let queued = try makeJob(state: .queued)
            _ = await repository.create(queued)
            let running = queued.replacing(state: .running)
            _ = await repository.transition(running, from: .queued)
            let requestedAt = try UTCInstant("2026-08-30T12:05:30.000Z")
            let requested = running.replacing(
                state: .running,
                cancellationRequestedAt: requestedAt
            )

            let requestResult = await repository.transition(requested, from: .running)
            let requestedReload = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )
            XCTAssertEqual(requestResult, .written(requested))
            XCTAssertEqual(requestedReload, .loaded(requested))

            let data = try Data(
                contentsOf: root
                    .appendingPathComponent("jobs")
                    .appendingPathComponent(queued.jobID.rawValue)
                    .appendingPathComponent("job.json")
            )
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(object["schemaVersion"] as? Int, 2)
            XCTAssertEqual(
                object["cancellationAuthorityId"] as? String,
                queued.cancellationAuthorityID?.rawValue
            )
            XCTAssertEqual(object["cancellationRequestedAt"] as? String, requestedAt.rawValue)

            let cleared = requested.replacing(
                state: .cancelled,
                cancellationRequestedAt: nil
            )
            let clearResult = await repository.transition(cleared, from: .running)
            let afterClear = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )
            XCTAssertEqual(clearResult, .failed)
            XCTAssertEqual(afterClear, .loaded(requested))
        }
    }

    func testV2StartSelectionBaselineIsRequiredAndDurable() async throws {
        try await withLibrary { root, libraryID in
            let baseline = try TranscriptRevisionID(
                "trv-20260830T120400000Z-4EFG"
            )
            let queued = try makeJob(
                state: .queued,
                expectedSelectedRevisionID: baseline
            )
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )

            let createResult = await repository.create(queued)
            XCTAssertEqual(createResult, .written(queued))
            let data = try Data(
                contentsOf: root
                    .appendingPathComponent("jobs")
                    .appendingPathComponent(queued.jobID.rawValue)
                    .appendingPathComponent("job.json")
            )
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(
                object["expectedSelectedRevisionId"] as? String,
                baseline.rawValue
            )
            let reopened = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )
            guard case let .loaded(job) = reopened else {
                return XCTFail("expected v2 baseline reopen")
            }
            XCTAssertTrue(job.hasCapturedSelectionBaseline)
            XCTAssertEqual(job.expectedSelectedRevisionID, baseline)
        }
    }

    func testLegacyV1JobReopensWithoutInventingCancellationAuthority() async throws {
        try await withLibrary { root, libraryID in
            let jobID = "job-20260830T120500000Z-5GHJ"
            let jobDirectory = root.appendingPathComponent("jobs")
                .appendingPathComponent(jobID)
            try FileManager.default.createDirectory(
                at: jobDirectory,
                withIntermediateDirectories: false
            )
            let legacy: [String: Any] = [
                "schemaVersion": 1,
                "jobId": jobID,
                "sessionId": "ses-20260830T120100000Z-2CDE",
                "revisionId": "trv-20260830T120600000Z-6JKM",
                "profileId": "synthetic-qualified-v1",
                "createdAt": "2026-08-30T12:05:00.000Z",
                "state": "running",
            ]
            try JSONSerialization.data(
                withJSONObject: legacy,
                options: [.sortedKeys]
            ).write(to: jobDirectory.appendingPathComponent("job.json"))

            let result = await PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            ).latest(for: try makeSelection(libraryID: libraryID))

            guard case let .loaded(job) = result else {
                return XCTFail("expected exact legacy v1 reopen")
            }
            XCTAssertEqual(job.state, .running)
            XCTAssertFalse(job.hasCapturedSelectionBaseline)
            XCTAssertNil(job.expectedSelectedRevisionID)
            XCTAssertNil(job.cancellationAuthorityID)
            XCTAssertNil(job.cancellationRequestedAt)
        }
    }

    func testV2JobMissingStartSelectionBaselineFailsClosed() async throws {
        try await withLibrary { root, libraryID in
            let jobID = "job-20260830T120500000Z-5GHJ"
            let jobDirectory = root.appendingPathComponent("jobs")
                .appendingPathComponent(jobID)
            try FileManager.default.createDirectory(
                at: jobDirectory,
                withIntermediateDirectories: false
            )
            let incompleteV2: [String: Any] = [
                "schemaVersion": 2,
                "jobId": jobID,
                "sessionId": "ses-20260830T120100000Z-2CDE",
                "revisionId": "trv-20260830T120600000Z-6JKM",
                "profileId": "synthetic-qualified-v1",
                "createdAt": "2026-08-30T12:05:00.000Z",
                "state": "running",
                "cancellationAuthorityId": "cancel-job-repository",
            ]
            try JSONSerialization.data(
                withJSONObject: incompleteV2,
                options: [.sortedKeys]
            ).write(to: jobDirectory.appendingPathComponent("job.json"))

            let result = await PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            ).latest(for: try makeSelection(libraryID: libraryID))

            XCTAssertEqual(result, .integrityMismatch)
        }
    }

    func testUnexpectedPartialOrSymlinkFailsClosed() async throws {
        try await withLibrary { root, libraryID in
            let jobs = root.appendingPathComponent("jobs", isDirectory: true)
            try FileManager.default.createDirectory(
                at: jobs.appendingPathComponent("unexpected.partial", isDirectory: true),
                withIntermediateDirectories: false
            )
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let partialResult = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )
            XCTAssertEqual(partialResult, .integrityMismatch)

            try FileManager.default.removeItem(
                at: jobs.appendingPathComponent("unexpected.partial")
            )
            let outside = root.deletingLastPathComponent()
                .appendingPathComponent("outside-synthetic", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outside,
                withIntermediateDirectories: false
            )
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createSymbolicLink(
                at: jobs.appendingPathComponent(
                    "job-20260830T120500000Z-5GHJ",
                    isDirectory: true
                ),
                withDestinationURL: outside
            )

            let symlinkResult = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )
            XCTAssertEqual(symlinkResult, .integrityMismatch)
        }
    }

    private func withLibrary(
        _ body: (URL, LibraryID) async throws -> Void
    ) async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-processing-jobs-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Practice.audoralibrary")
        let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
        let libraryID = try LibraryID("lib-20260830T120000000Z-2ABC")
        _ = try PortableLibraryPersistence().create(
            at: root,
            seed: NewLibrarySeed(
                libraryID: libraryID,
                createdAt: instant,
                preferences: .defaults,
                profileHead: ProfileHead(
                    generation: 0,
                    statementGeneration: 0,
                    selection: .null,
                    updatedAt: instant
                )
            )
        )
        try await body(root, libraryID)
    }

    private func makeSelection(
        libraryID: LibraryID
    ) throws -> SessionProcessingSelection {
        SessionProcessingSelection(
            scope: LibraryScope(libraryID: libraryID),
            sessionID: try SessionID("ses-20260830T120100000Z-2CDE")
        )
    }

    private func makeJob(
        state: SessionProcessingJobState,
        expectedSelectedRevisionID: TranscriptRevisionID? = nil
    ) throws
        -> SessionProcessingJob
    {
        SessionProcessingJob(
            jobID: try TranscriptionJobID("job-20260830T120500000Z-5GHJ"),
            sessionID: try SessionID("ses-20260830T120100000Z-2CDE"),
            revisionID: try TranscriptRevisionID("trv-20260830T120600000Z-6JKM"),
            profileID: "synthetic-qualified-v1",
            createdAt: try UTCInstant("2026-08-30T12:05:00.000Z"),
            state: state,
            expectedSelectedRevisionID: expectedSelectedRevisionID,
            cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                "cancel-job-repository"
            )
        )
    }
}

private extension SessionProcessingJob {
    func replacing(
        state: SessionProcessingJobState,
        failure: SessionProcessingFailureReason? = nil,
        cancellationRequestedAt: UTCInstant? = nil
    ) -> SessionProcessingJob {
        SessionProcessingJob(
            jobID: jobID,
            sessionID: sessionID,
            revisionID: revisionID,
            profileID: profileID,
            createdAt: createdAt,
            state: state,
            expectedSelectedRevisionID: expectedSelectedRevisionID,
            cancellationAuthorityID: cancellationAuthorityID!,
            cancellationRequestedAt: cancellationRequestedAt,
            candidateArtifactSHA256: candidateArtifactSHA256,
            failure: failure
        )
    }
}
