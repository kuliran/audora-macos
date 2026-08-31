import AudoraApplication
import AudoraDomain
@testable import AudoraMacInfrastructure
import Foundation
import XCTest

final class PortableSessionProcessingJobRepositoryTests: XCTestCase {
    func testRootReplacementWithSameLibraryIDCannotReceivePreexistingAuthorityMutation()
        async throws
    {
        try await withLibrary { root, libraryID in
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let parent = root.deletingLastPathComponent()
            let displaced = parent.appendingPathComponent(
                "Original.audoralibrary",
                isDirectory: true
            )
            try FileManager.default.moveItem(at: root, to: displaced)
            let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
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
            let queued = try makeJob(state: .queued)

            let result = await repository.create(queued)

            XCTAssertEqual(result, .failed)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: root.appendingPathComponent("jobs").path
                ),
                []
            )
        }
    }

    func testRootSwapImmediatelyBeforeCreateCommitCannotRedirectMutation()
        async throws
    {
        try await withLibrary { root, libraryID in
            let parent = root.deletingLastPathComponent()
            let replacement = parent.appendingPathComponent(
                "Replacement.audoralibrary",
                isDirectory: true
            )
            let displaced = parent.appendingPathComponent(
                "Displaced.audoralibrary",
                isDirectory: true
            )
            let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
            _ = try PortableLibraryPersistence().create(
                at: replacement,
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
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID,
                reconciliationFault: { point in
                    guard point == .beforeJobMutationCommit else { return }
                    try FileManager.default.moveItem(at: root, to: displaced)
                    try FileManager.default.moveItem(at: replacement, to: root)
                }
            )

            let result = await repository.create(try makeJob(state: .queued))

            XCTAssertEqual(result, .failed)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: root.appendingPathComponent("jobs").path
                ),
                []
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: displaced.appendingPathComponent("jobs").path
                ),
                []
            )
        }
    }

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

    func testExactOwnedCreationPartialIsRemovedAndDoesNotStrandRelaunch()
        async throws
    {
        try await withLibrary { root, libraryID in
            let jobs = root.appendingPathComponent("jobs", isDirectory: true)
            let queued = try makeJob(state: .queued)
            let partial = jobs.appendingPathComponent(
                ".\(queued.jobID.rawValue).partial",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: partial,
                withIntermediateDirectories: false
            )
            try encodedJob(queued).write(
                to: partial.appendingPathComponent("job.json")
            )
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )

            let result = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )

            XCTAssertEqual(result, .none)
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        }
    }

    func testSameInodeCreationManifestMutationBeforeCleanupIsPreservedAndRejected()
        async throws
    {
        try await withLibrary { root, libraryID in
            let queued = try makeJob(state: .queued)
            let partial = root.appendingPathComponent("jobs", isDirectory: true)
                .appendingPathComponent(
                    ".\(queued.jobID.rawValue).partial",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: partial,
                withIntermediateDirectories: false
            )
            let manifest = partial.appendingPathComponent("job.json")
            let initialBytes = try encodedJob(queued)
            var mutation = initialBytes
            mutation[mutation.index(before: mutation.endIndex)] = 93
            let mutatedBytes = mutation
            try initialBytes.write(to: manifest)
            let initialInode = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: manifest.path)[
                    .systemFileNumber
                ] as? NSNumber
            )
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID,
                reconciliationFault: { point in
                    guard point == .beforeCreationPartialUnlink else { return }
                    let handle = try FileHandle(forWritingTo: manifest)
                    try handle.write(contentsOf: mutatedBytes)
                    try handle.synchronize()
                    try handle.close()
                }
            )

            let result = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )
            let finalInode = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: manifest.path)[
                    .systemFileNumber
                ] as? NSNumber
            )

            XCTAssertEqual(result, .integrityMismatch)
            XCTAssertEqual(finalInode, initialInode)
            XCTAssertEqual(try Data(contentsOf: manifest), mutatedBytes)
        }
    }

    func testCreationPartialReplacementBeforeCleanupFailsClosedWithoutDeletingIt()
        async throws
    {
        try await withLibrary { root, libraryID in
            let queued = try makeJob(state: .queued)
            let jobs = root.appendingPathComponent("jobs", isDirectory: true)
            let partial = jobs.appendingPathComponent(
                ".\(queued.jobID.rawValue).partial",
                isDirectory: true
            )
            let displaced = jobs.appendingPathComponent(
                ".\(queued.jobID.rawValue).partial.displaced",
                isDirectory: true
            )
            let manifestBytes = try encodedJob(queued)
            try FileManager.default.createDirectory(
                at: partial,
                withIntermediateDirectories: false
            )
            try manifestBytes.write(to: partial.appendingPathComponent("job.json"))
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID,
                reconciliationFault: { point in
                    guard point == .beforeCreationPartialUnlink else { return }
                    try FileManager.default.moveItem(at: partial, to: displaced)
                    try FileManager.default.createDirectory(
                        at: partial,
                        withIntermediateDirectories: false
                    )
                    try manifestBytes.write(
                        to: partial.appendingPathComponent("job.json")
                    )
                }
            )

            let result = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )

            XCTAssertEqual(result, .integrityMismatch)
            XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: displaced.path))
        }
    }

    func testCreationPartialWithEntryInjectedAtCleanupIsBytePreservedAndRejected()
        async throws
    {
        try await withLibrary { root, libraryID in
            let queued = try makeJob(state: .queued)
            let partial = root.appendingPathComponent("jobs", isDirectory: true)
                .appendingPathComponent(
                    ".\(queued.jobID.rawValue).partial",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: partial,
                withIntermediateDirectories: false
            )
            let manifest = partial.appendingPathComponent("job.json")
            let manifestBytes = try encodedJob(queued)
            try manifestBytes.write(to: manifest)
            let unexpected = partial.appendingPathComponent("unexpected")
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID,
                reconciliationFault: { point in
                    guard point == .beforeCreationPartialUnlink else { return }
                    try Data("suspect".utf8).write(to: unexpected)
                }
            )

            let result = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )

            XCTAssertEqual(result, .integrityMismatch)
            XCTAssertEqual(try Data(contentsOf: manifest), manifestBytes)
            XCTAssertEqual(try Data(contentsOf: unexpected), Data("suspect".utf8))
        }
    }

    func testExactOwnedTransitionPartialIsDiscardedAndInstalledManifestWins()
        async throws
    {
        try await withLibrary { root, libraryID in
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let queued = try makeJob(state: .queued)
            let createResult = await repository.create(queued)
            XCTAssertEqual(createResult, .written(queued))
            let jobDirectory = root.appendingPathComponent("jobs", isDirectory: true)
                .appendingPathComponent(queued.jobID.rawValue, isDirectory: true)
            let transitionPartial = jobDirectory.appendingPathComponent(
                "job.json.partial"
            )
            try encodedJob(queued.replacing(state: .running)).write(
                to: transitionPartial
            )

            let result = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )

            XCTAssertEqual(result, .loaded(queued))
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: transitionPartial.path)
            )
        }
    }

    func testNearMatchCrashResidueRemainsAndFailsClosed() async throws {
        try await withLibrary { root, libraryID in
            let jobs = root.appendingPathComponent("jobs", isDirectory: true)
            let queued = try makeJob(state: .queued)
            let nearCreation = jobs.appendingPathComponent(
                ".\(queued.jobID.rawValue).partial.backup",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: nearCreation,
                withIntermediateDirectories: false
            )
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )

            let nearCreationResult = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )
            XCTAssertEqual(nearCreationResult, .integrityMismatch)
            XCTAssertTrue(FileManager.default.fileExists(atPath: nearCreation.path))

            try FileManager.default.removeItem(at: nearCreation)
            let createResult = await repository.create(queued)
            XCTAssertEqual(createResult, .written(queued))
            let nearTransition = jobs
                .appendingPathComponent(queued.jobID.rawValue, isDirectory: true)
                .appendingPathComponent("job.json.partial.backup")
            try encodedJob(queued.replacing(state: .running)).write(
                to: nearTransition
            )

            let nearTransitionResult = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )
            XCTAssertEqual(nearTransitionResult, .integrityMismatch)
            XCTAssertTrue(FileManager.default.fileExists(atPath: nearTransition.path))
        }
    }

    func testTransitionPartialReplacementBeforeCleanupFailsClosedWithoutDeletingIt()
        async throws
    {
        try await withLibrary { root, libraryID in
            let queued = try makeJob(state: .queued)
            let running = queued.replacing(state: .running)
            let writer = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let createResult = await writer.create(queued)
            XCTAssertEqual(createResult, .written(queued))
            let jobDirectory = root.appendingPathComponent("jobs", isDirectory: true)
                .appendingPathComponent(queued.jobID.rawValue, isDirectory: true)
            let partial = jobDirectory.appendingPathComponent("job.json.partial")
            let displaced = jobDirectory.appendingPathComponent(
                "job.json.partial.displaced"
            )
            let replacementBytes = try encodedJob(running)
            try replacementBytes.write(to: partial)
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID,
                reconciliationFault: { point in
                    guard point == .beforeTransitionPartialUnlink else { return }
                    try FileManager.default.moveItem(at: partial, to: displaced)
                    try replacementBytes.write(to: partial)
                }
            )

            let result = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )

            XCTAssertEqual(result, .integrityMismatch)
            XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: displaced.path))
        }
    }

    func testTransitionPartialWithEntryInjectedAtCleanupIsBytePreservedAndRejected()
        async throws
    {
        try await withLibrary { root, libraryID in
            let queued = try makeJob(state: .queued)
            let running = queued.replacing(state: .running)
            let writer = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let createResult = await writer.create(queued)
            XCTAssertEqual(createResult, .written(queued))
            let jobDirectory = root.appendingPathComponent("jobs", isDirectory: true)
                .appendingPathComponent(queued.jobID.rawValue, isDirectory: true)
            let partial = jobDirectory.appendingPathComponent("job.json.partial")
            let partialBytes = try encodedJob(running)
            try partialBytes.write(to: partial)
            let unexpected = jobDirectory.appendingPathComponent("unexpected")
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID,
                reconciliationFault: { point in
                    guard point == .beforeTransitionPartialUnlink else { return }
                    try Data("suspect".utf8).write(to: unexpected)
                }
            )

            let result = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )

            XCTAssertEqual(result, .integrityMismatch)
            XCTAssertEqual(try Data(contentsOf: partial), partialBytes)
            XCTAssertEqual(try Data(contentsOf: unexpected), Data("suspect".utf8))
        }
    }

    func testMismatchedDirectoryJobIdentityNeverDeletesTransitionPartial()
        async throws
    {
        try await withLibrary { root, libraryID in
            let directoryJob = try makeJob(state: .queued)
            let storedJob = SessionProcessingJob(
                jobID: try TranscriptionJobID("job-20260830T120900000Z-9RST"),
                sessionID: directoryJob.sessionID,
                revisionID: try TranscriptRevisionID(
                    "trv-20260830T120900000Z-9RST"
                ),
                profileID: directoryJob.profileID,
                createdAt: directoryJob.createdAt,
                state: .queued,
                expectedSelectedRevisionID:
                    directoryJob.expectedSelectedRevisionID,
                cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                    "cancel-mismatched-job-directory"
                )
            )
            let jobDirectory = root.appendingPathComponent("jobs", isDirectory: true)
                .appendingPathComponent(
                    directoryJob.jobID.rawValue,
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: jobDirectory,
                withIntermediateDirectories: false
            )
            let current = jobDirectory.appendingPathComponent("job.json")
            let partial = jobDirectory.appendingPathComponent("job.json.partial")
            let currentBytes = try encodedJob(storedJob)
            let partialBytes = try encodedJob(storedJob.replacing(state: .running))
            try currentBytes.write(to: current)
            try partialBytes.write(to: partial)
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )

            let result = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )

            XCTAssertEqual(result, .integrityMismatch)
            XCTAssertEqual(try Data(contentsOf: current), currentBytes)
            XCTAssertEqual(try Data(contentsOf: partial), partialBytes)
        }
    }

    func testSameInodeTransitionPartialMutationBeforeCleanupIsPreservedAndRejected()
        async throws
    {
        try await withLibrary { root, libraryID in
            let queued = try makeJob(state: .queued)
            let running = queued.replacing(state: .running)
            let writer = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let createResult = await writer.create(queued)
            XCTAssertEqual(createResult, .written(queued))
            let partial = root.appendingPathComponent("jobs", isDirectory: true)
                .appendingPathComponent(queued.jobID.rawValue, isDirectory: true)
                .appendingPathComponent("job.json.partial")
            let initialBytes = try encodedJob(running)
            var mutation = initialBytes
            mutation[mutation.index(before: mutation.endIndex)] = 93
            let mutatedBytes = mutation
            try initialBytes.write(to: partial)
            let initialInode = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: partial.path)[
                    .systemFileNumber
                ] as? NSNumber
            )
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID,
                reconciliationFault: { point in
                    guard point == .beforeTransitionPartialUnlink else { return }
                    let handle = try FileHandle(forWritingTo: partial)
                    try handle.write(contentsOf: mutatedBytes)
                    try handle.synchronize()
                    try handle.close()
                }
            )

            let result = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )
            let finalInode = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: partial.path)[
                    .systemFileNumber
                ] as? NSNumber
            )

            XCTAssertEqual(result, .integrityMismatch)
            XCTAssertEqual(finalInode, initialInode)
            XCTAssertEqual(try Data(contentsOf: partial), mutatedBytes)
        }
    }

    func testSameInodeInstalledManifestMutationBeforePartialCleanupIsPreservedAndRejected()
        async throws
    {
        try await withLibrary { root, libraryID in
            let queued = try makeJob(state: .queued)
            let running = queued.replacing(state: .running)
            let writer = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let createResult = await writer.create(queued)
            XCTAssertEqual(createResult, .written(queued))
            let jobDirectory = root.appendingPathComponent("jobs", isDirectory: true)
                .appendingPathComponent(queued.jobID.rawValue, isDirectory: true)
            let installed = jobDirectory.appendingPathComponent("job.json")
            let partial = jobDirectory.appendingPathComponent("job.json.partial")
            try encodedJob(running).write(to: partial)
            let initialBytes = try Data(contentsOf: installed)
            var mutation = initialBytes
            mutation[mutation.index(before: mutation.endIndex)] = 93
            let mutatedBytes = mutation
            let initialInode = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: installed.path)[
                    .systemFileNumber
                ] as? NSNumber
            )
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID,
                reconciliationFault: { point in
                    guard point == .beforeTransitionPartialUnlink else { return }
                    let handle = try FileHandle(forWritingTo: installed)
                    try handle.write(contentsOf: mutatedBytes)
                    try handle.synchronize()
                    try handle.close()
                }
            )

            let result = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )
            let finalInode = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: installed.path)[
                    .systemFileNumber
                ] as? NSNumber
            )

            XCTAssertEqual(result, .integrityMismatch)
            XCTAssertEqual(finalInode, initialInode)
            XCTAssertEqual(try Data(contentsOf: installed), mutatedBytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
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

    private func encodedJob(_ job: SessionProcessingJob) throws -> Data {
        var object: [String: Any] = [
            "schemaVersion": 2,
            "jobId": job.jobID.rawValue,
            "sessionId": job.sessionID.rawValue,
            "revisionId": job.revisionID.rawValue,
            "profileId": job.profileID,
            "createdAt": job.createdAt.rawValue,
            "state": job.state.rawValue,
            "expectedSelectedRevisionId": job.expectedSelectedRevisionID?.rawValue
                ?? NSNull(),
            "cancellationAuthorityId": try XCTUnwrap(
                job.cancellationAuthorityID
            ).rawValue,
        ]
        if let cancellationRequestedAt = job.cancellationRequestedAt {
            object["cancellationRequestedAt"] = cancellationRequestedAt.rawValue
        }
        if let candidateArtifactSHA256 = job.candidateArtifactSHA256 {
            object["candidateArtifactSha256"] = candidateArtifactSHA256
        }
        if let failure = job.failure { object["failure"] = failure.rawValue }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
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
