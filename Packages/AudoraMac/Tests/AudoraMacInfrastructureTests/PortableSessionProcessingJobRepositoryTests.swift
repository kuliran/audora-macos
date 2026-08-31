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

    private func makeJob(state: SessionProcessingJobState) throws
        -> SessionProcessingJob
    {
        SessionProcessingJob(
            jobID: try TranscriptionJobID("job-20260830T120500000Z-5GHJ"),
            sessionID: try SessionID("ses-20260830T120100000Z-2CDE"),
            revisionID: try TranscriptRevisionID("trv-20260830T120600000Z-6JKM"),
            profileID: "synthetic-qualified-v1",
            createdAt: try UTCInstant("2026-08-30T12:05:00.000Z"),
            state: state
        )
    }
}

private extension SessionProcessingJob {
    func replacing(
        state: SessionProcessingJobState,
        failure: SessionProcessingFailureReason? = nil
    ) -> SessionProcessingJob {
        SessionProcessingJob(
            jobID: jobID,
            sessionID: sessionID,
            revisionID: revisionID,
            profileID: profileID,
            createdAt: createdAt,
            state: state,
            candidateArtifactSHA256: candidateArtifactSHA256,
            failure: failure
        )
    }
}
