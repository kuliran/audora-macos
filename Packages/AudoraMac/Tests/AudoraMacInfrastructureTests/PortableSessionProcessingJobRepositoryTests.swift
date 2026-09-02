import AudoraApplication
import AudoraContracts
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
            let queued = try makeJob(state: .queued)

            let result = await repository.create(queued)

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
                [".\(queued.jobID.rawValue).partial"]
            )
            var expectedBytes = try encodedJob(queued)
            expectedBytes.append(0x0A)
            XCTAssertEqual(
                try Data(
                    contentsOf: displaced.appendingPathComponent("jobs")
                        .appendingPathComponent(".\(queued.jobID.rawValue).partial")
                        .appendingPathComponent("job.json")
                ),
                expectedBytes
            )
        }
    }

    func testLibraryManifestSwapImmediatelyBeforeCreateCommitRejectsMutation()
        async throws
    {
        try await withLibrary { root, libraryID in
            let parent = root.deletingLastPathComponent()
            let replacement = parent.appendingPathComponent(
                "Replacement.audoralibrary",
                isDirectory: true
            )
            let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
            _ = try PortableLibraryPersistence().create(
                at: replacement,
                seed: NewLibrarySeed(
                    libraryID: try LibraryID("lib-20260830T120000000Z-9RST"),
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
            let replacementManifest = try Data(
                contentsOf: replacement.appendingPathComponent("library.json")
            )
            let targetManifest = root.appendingPathComponent("library.json")
            let expected = try makeJob(state: .queued)
            let partial = root.appendingPathComponent("jobs", isDirectory: true)
                .appendingPathComponent(
                    ".\(expected.jobID.rawValue).partial",
                    isDirectory: true
                )
            let final = root.appendingPathComponent("jobs", isDirectory: true)
                .appendingPathComponent(expected.jobID.rawValue, isDirectory: true)
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID,
                reconciliationFault: { point in
                    guard point == .beforeJobMutationCommit else { return }
                    try replacementManifest.write(to: targetManifest, options: .atomic)
                }
            )

            let result = await repository.create(expected)

            XCTAssertEqual(result, .failed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
            XCTAssertEqual(try Data(contentsOf: targetManifest), replacementManifest)
        }
    }

    func testCreateRejectsPreparedPartialDirectorySubstitutionBeforeCommit()
        async throws
    {
        try await withLibrary { root, libraryID in
            let expected = try makeJob(state: .queued)
            let substitute = SessionProcessingJob(
                jobID: expected.jobID,
                sessionID: expected.sessionID,
                revisionID: expected.revisionID,
                profileID: "substituted-qualified-v1",
                createdAt: expected.createdAt,
                state: .queued,
                expectedSelectedRevisionID: expected.expectedSelectedRevisionID,
                cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                    "cancel-substituted-create"
                )
            )
            let jobs = root.appendingPathComponent("jobs", isDirectory: true)
            let partial = jobs.appendingPathComponent(
                ".\(expected.jobID.rawValue).partial",
                isDirectory: true
            )
            let displaced = jobs.appendingPathComponent(
                ".\(expected.jobID.rawValue).partial.displaced",
                isDirectory: true
            )
            let final = jobs.appendingPathComponent(
                expected.jobID.rawValue,
                isDirectory: true
            )
            var expectedBytes = try encodedJob(expected)
            expectedBytes.append(0x0A)
            let substituteBytes = try encodedJob(substitute)
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID,
                reconciliationFault: { point in
                    guard point == .beforeJobMutationCommit else { return }
                    try FileManager.default.moveItem(at: partial, to: displaced)
                    try FileManager.default.createDirectory(
                        at: partial,
                        withIntermediateDirectories: false
                    )
                    try substituteBytes.write(
                        to: partial.appendingPathComponent("job.json")
                    )
                }
            )

            let result = await repository.create(expected)

            XCTAssertEqual(result, .failed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
            XCTAssertEqual(
                try? Data(contentsOf: partial.appendingPathComponent("job.json")),
                substituteBytes
            )
            XCTAssertEqual(
                try? Data(contentsOf: displaced.appendingPathComponent("job.json")),
                expectedBytes
            )
        }
    }

    func testCreateRejectsSameInodePreparedManifestMutationBeforeCommit()
        async throws
    {
        try await withLibrary { root, libraryID in
            let expected = try makeJob(state: .queued)
            let jobs = root.appendingPathComponent("jobs", isDirectory: true)
            let partial = jobs.appendingPathComponent(
                ".\(expected.jobID.rawValue).partial",
                isDirectory: true
            )
            let manifest = partial.appendingPathComponent("job.json")
            let final = jobs.appendingPathComponent(
                expected.jobID.rawValue,
                isDirectory: true
            )
            var preparedMutatedBytes = try encodedJob(expected)
            preparedMutatedBytes.append(0x0A)
            let profile = Data("synthetic-qualified-v1".utf8)
            let profileRange = try XCTUnwrap(
                preparedMutatedBytes.range(of: profile)
            )
            preparedMutatedBytes[profileRange.lowerBound] = 120
            let mutatedBytes = preparedMutatedBytes
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID,
                reconciliationFault: { point in
                    guard point == .beforeJobMutationCommit else { return }
                    let handle = try FileHandle(forWritingTo: manifest)
                    try handle.truncate(atOffset: 0)
                    try handle.write(contentsOf: mutatedBytes)
                    try handle.synchronize()
                    try handle.close()
                }
            )

            let result = await repository.create(expected)

            XCTAssertEqual(result, .failed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
            XCTAssertEqual(try Data(contentsOf: manifest), mutatedBytes)
        }
    }

    func testCreateRejectsPreparedPartialWithUnexpectedEntryBeforeCommit()
        async throws
    {
        try await withLibrary { root, libraryID in
            let expected = try makeJob(state: .queued)
            let partial = root.appendingPathComponent("jobs", isDirectory: true)
                .appendingPathComponent(
                    ".\(expected.jobID.rawValue).partial",
                    isDirectory: true
                )
            let unexpected = partial.appendingPathComponent("unexpected")
            let final = root.appendingPathComponent("jobs", isDirectory: true)
                .appendingPathComponent(expected.jobID.rawValue, isDirectory: true)
            let suspectBytes = Data("suspect".utf8)
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID,
                reconciliationFault: { point in
                    guard point == .beforeJobMutationCommit else { return }
                    try suspectBytes.write(to: unexpected)
                }
            )

            let result = await repository.create(expected)

            XCTAssertEqual(result, .failed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
            XCTAssertEqual(try Data(contentsOf: unexpected), suspectBytes)
            var expectedBytes = try encodedJob(expected)
            expectedBytes.append(0x0A)
            XCTAssertEqual(
                try Data(contentsOf: partial.appendingPathComponent("job.json")),
                expectedBytes
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

    func testExactLookupDoesNotFollowNewerJobForSameSession() async throws {
        try await withLibrary { root, libraryID in
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let original = try makeJob(state: .queued)
            let newer = SessionProcessingJob(
                jobID: try TranscriptionJobID("job-20260830T120700000Z-7MNP"),
                sessionID: original.sessionID,
                revisionID: try TranscriptRevisionID(
                    "trv-20260830T120800000Z-8NPQ"
                ),
                profileID: original.profileID,
                createdAt: try UTCInstant("2026-08-30T12:07:00.000Z"),
                state: .queued,
                expectedSelectedRevisionID: nil,
                cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                    "cancel-newer-job-repository"
                )
            )
            let originalWrite = await repository.create(original)
            let newerWrite = await repository.create(newer)
            let selection = try makeSelection(libraryID: libraryID)
            let latest = await repository.latest(for: selection)
            let exact = await repository.load(
                jobID: original.jobID,
                for: selection
            )

            XCTAssertEqual(originalWrite, .written(original))
            XCTAssertEqual(newerWrite, .written(newer))
            XCTAssertEqual(latest, .loaded(newer))
            XCTAssertEqual(exact, .loaded(original))
        }
    }

    func testClockRollbackKeepsTheLaterCreatedAttemptCurrentAcrossRelaunch()
        async throws
    {
        try await withLibrary { root, libraryID in
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let first = SessionProcessingJob(
                jobID: try TranscriptionJobID("job-20260830T121000000Z-8NPQ"),
                sessionID: try SessionID("ses-20260830T120100000Z-2CDE"),
                revisionID: try TranscriptRevisionID(
                    "trv-20260830T121100000Z-9RST"
                ),
                profileID: "synthetic-qualified-v1",
                createdAt: try UTCInstant("2026-08-30T12:10:00.000Z"),
                state: .queued,
                expectedSelectedRevisionID: nil,
                cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                    "cancel-first-causal-attempt"
                )
            )
            let retryAfterClockRollback = SessionProcessingJob(
                jobID: try TranscriptionJobID("job-20260830T110000000Z-3DEF"),
                sessionID: first.sessionID,
                revisionID: try TranscriptRevisionID(
                    "trv-20260830T110100000Z-4EFG"
                ),
                profileID: first.profileID,
                createdAt: try UTCInstant("2026-08-30T11:00:00.000Z"),
                state: .queued,
                expectedSelectedRevisionID: nil,
                cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                    "cancel-clock-rollback-retry"
                )
            )

            let firstWrite = await repository.create(first)
            let retryWrite = await repository.create(retryAfterClockRollback)
            XCTAssertEqual(firstWrite, .written(first))
            XCTAssertEqual(retryWrite, .written(retryAfterClockRollback))

            let reopened = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let selection = try makeSelection(libraryID: libraryID)
            let latest = await reopened.latest(for: selection)
            XCTAssertEqual(latest, .loaded(retryAfterClockRollback))
            let inventory = await reopened.inventory(
                for: LibraryScope(libraryID: libraryID)
            )
            guard case let .available(value) = inventory else {
                return XCTFail("expected causal inventory")
            }
            XCTAssertEqual(value.jobs, [first, retryAfterClockRollback])
        }
    }

    func testCreatedAttemptIndexUsesThePackagedContractExampleShape() async throws {
        try await withLibrary { root, libraryID in
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let queued = try makeJob(state: .queued)
            let write = await repository.create(queued)
            XCTAssertEqual(write, .written(queued))

            let emitted = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(
                        contentsOf: root.appendingPathComponent("jobs/.attempts.json")
                    )
                ) as? NSDictionary
            )
            let example = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: ContractResources.data(
                        for: .sessionProcessingAttemptIndexExample
                    )
                ) as? NSDictionary
            )
            XCTAssertEqual(emitted, example)
        }
    }

    func testRelaunchRepairsACrashedAttemptReservationBeforeAcceptingTheRetry()
        async throws
    {
        try await withLibrary { root, libraryID in
            let first = try makeJob(state: .queued)
            let retry = SessionProcessingJob(
                jobID: try TranscriptionJobID("job-20260830T110000000Z-3DEF"),
                sessionID: first.sessionID,
                revisionID: try TranscriptRevisionID(
                    "trv-20260830T110100000Z-4EFG"
                ),
                profileID: first.profileID,
                createdAt: try UTCInstant("2026-08-30T11:00:00.000Z"),
                state: .queued,
                expectedSelectedRevisionID: nil,
                cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                    "cancel-crashed-causal-retry"
                )
            )
            let writer = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let firstWrite = await writer.create(first)
            XCTAssertEqual(firstWrite, .written(first))
            let interruptedWriter = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID,
                reconciliationFault: { point in
                    guard point == .afterAttemptReservationBeforeJobInstall else {
                        return
                    }
                    throw CausalAttemptTestFault.injectedCrash
                }
            )

            let interrupted = await interruptedWriter.create(retry)
            XCTAssertEqual(interrupted, .failed)

            let reopened = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let selection = try makeSelection(libraryID: libraryID)
            let afterCrash = await reopened.latest(for: selection)
            XCTAssertEqual(afterCrash, .loaded(first))
            let retriedWrite = await reopened.create(retry)
            XCTAssertEqual(retriedWrite, .written(retry))
            let afterRetry = await reopened.latest(for: selection)
            XCTAssertEqual(afterRetry, .loaded(retry))
        }
    }

    func testNewerAttemptIndexFreezesEveryRepositoryOperationWithoutRecovery()
        async throws
    {
        for indexName in [".attempts.json", ".attempts.json.partial"] {
            try await assertNewerAttemptIndexFreezesEveryRepositoryOperation(
                indexName: indexName
            )
        }
    }

    private func assertNewerAttemptIndexFreezesEveryRepositoryOperation(
        indexName: String
    ) async throws {
        try await withLibrary { root, libraryID in
            let jobs = root.appendingPathComponent("jobs", isDirectory: true)
            let existing = try makeJob(state: .queued)
            let existingDirectory = jobs.appendingPathComponent(
                existing.jobID.rawValue,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: existingDirectory,
                withIntermediateDirectories: false
            )
            let existingBytes = try encodedJob(existing)
            try existingBytes.write(
                to: existingDirectory.appendingPathComponent("job.json")
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: existingDirectory.appendingPathComponent(
                        "job.json.partial"
                    ).path
                )
            )

            let newerIndex = try ContractResources.data(
                for: .rejectedNewerSessionProcessingAttemptIndex
            )
            let index = jobs.appendingPathComponent(indexName)
            try newerIndex.write(to: index)
            let pendingCreate = jobs.appendingPathComponent(
                ".job-20260830T120700000Z-7MNP.partial",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: pendingCreate,
                withIntermediateDirectories: false
            )
            let sentinel = Data("newer-writer-owned".utf8)
            try sentinel.write(to: pendingCreate.appendingPathComponent("sentinel"))

            let before = try snapshotTree(at: jobs)
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let scope = LibraryScope(libraryID: libraryID)
            let selection = try makeSelection(libraryID: libraryID)
            let replacement = SessionProcessingJob(
                jobID: try TranscriptionJobID("job-20260830T120800000Z-8NPQ"),
                sessionID: existing.sessionID,
                revisionID: try TranscriptRevisionID(
                    "trv-20260830T120900000Z-9RST"
                ),
                profileID: existing.profileID,
                createdAt: try UTCInstant("2026-08-30T12:08:00.000Z"),
                state: .queued,
                expectedSelectedRevisionID: nil,
                cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                    "cancel-newer-index-frozen"
                )
            )

            let inventory = await repository.inventory(for: scope)
            let latest = await repository.latest(for: selection)
            let exact = await repository.load(
                jobID: existing.jobID,
                for: selection
            )
            let create = await repository.create(replacement)
            let transition = await repository.transition(
                existing.replacing(state: .running),
                from: .queued
            )

            XCTAssertEqual(inventory, .unsupportedSchema(version: 2))
            XCTAssertEqual(latest, .unsupportedSchema(version: 2))
            XCTAssertEqual(exact, .unsupportedSchema(version: 2))
            XCTAssertEqual(create, .failed)
            XCTAssertEqual(transition, .failed)
            XCTAssertEqual(try snapshotTree(at: jobs), before)
        }
    }

    func testCreateAtJobCapacityFailsBeforeDirectoryOrAttemptPointerMutation()
        async throws
    {
        try await withLibrary { root, libraryID in
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID,
                creationJobCountLimit: 1
            )
            let first = try makeJob(state: .queued)
            let firstWrite = await repository.create(first)
            XCTAssertEqual(firstWrite, .written(first))
            let jobs = root.appendingPathComponent("jobs", isDirectory: true)
            let pointer = jobs.appendingPathComponent(".attempts.json")
            let pointerBefore = try Data(contentsOf: pointer)
            let retry = SessionProcessingJob(
                jobID: try TranscriptionJobID("job-20260830T120700000Z-7MNP"),
                sessionID: first.sessionID,
                revisionID: try TranscriptRevisionID(
                    "trv-20260830T120800000Z-8NPQ"
                ),
                profileID: first.profileID,
                createdAt: try UTCInstant("2026-08-30T12:06:00.000Z"),
                state: .queued,
                expectedSelectedRevisionID: nil,
                cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                    "cancel-capacity-retry"
                )
            )

            let result = await repository.create(retry)

            XCTAssertEqual(result, .failed)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: jobs.appendingPathComponent(retry.jobID.rawValue).path
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: jobs.appendingPathComponent(
                        ".\(retry.jobID.rawValue).partial"
                    ).path
                )
            )
            XCTAssertEqual(try Data(contentsOf: pointer), pointerBefore)
            let latest = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )
            XCTAssertEqual(latest, .loaded(first))
        }
    }

    func testMigratedLegacyCurrentYieldsToASequencedRollbackRetryCompletion()
        async throws
    {
        try await withLibrary { root, libraryID in
            let legacy = try makeJob(state: .queued)
            let legacyDirectory = root.appendingPathComponent("jobs")
                .appendingPathComponent(legacy.jobID.rawValue)
            try FileManager.default.createDirectory(
                at: legacyDirectory,
                withIntermediateDirectories: false
            )
            try encodedJob(legacy, attemptSequence: nil).write(
                to: legacyDirectory.appendingPathComponent("job.json")
            )
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let selection = try makeSelection(libraryID: libraryID)
            let migrated = await repository.latest(for: selection)
            XCTAssertEqual(migrated, .loaded(legacy))

            let retry = SessionProcessingJob(
                jobID: try TranscriptionJobID("job-20260830T110000000Z-3DEF"),
                sessionID: legacy.sessionID,
                revisionID: try TranscriptRevisionID(
                    "trv-20260830T110100000Z-4EFG"
                ),
                profileID: legacy.profileID,
                createdAt: try UTCInstant("2026-08-30T11:00:00.000Z"),
                state: .queued,
                expectedSelectedRevisionID: nil,
                cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                    "cancel-migrated-clock-retry"
                )
            )
            let create = await repository.create(retry)
            XCTAssertEqual(create, .written(retry))
            let running = retry.replacing(state: .running)
            let runningWrite = await repository.transition(running, from: .queued)
            XCTAssertEqual(runningWrite, .written(running))
            let hash = String(repeating: "a", count: 64)
            let validating = running.replacing(
                state: .validating,
                candidateArtifactSHA256: hash
            )
            let validatingWrite = await repository.transition(
                validating,
                from: .running
            )
            XCTAssertEqual(validatingWrite, .written(validating))
            let completed = validating.replacing(
                state: .completed,
                candidateArtifactSHA256: hash
            )
            let completedWrite = await repository.transition(
                completed,
                from: .validating
            )
            XCTAssertEqual(completedWrite, .written(completed))

            let reopened = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let latest = await reopened.latest(for: selection)
            XCTAssertEqual(latest, .loaded(completed))
            let inventory = await reopened.inventory(
                for: LibraryScope(libraryID: libraryID)
            )
            guard case let .available(value) = inventory else {
                return XCTFail("expected migrated causal inventory")
            }
            XCTAssertEqual(value.jobs, [legacy, completed])
        }
    }

    func testInventoryReturnsClassifiedValidJobsBesideAMalformedSibling()
        async throws
    {
        try await withLibrary { root, libraryID in
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let valid = try makeJob(state: .queued)
            let validWrite = await repository.create(valid)
            XCTAssertEqual(validWrite, .written(valid))
            let malformedDirectory = root.appendingPathComponent("jobs")
                .appendingPathComponent("job-20260830T120700000Z-7MNP")
            try FileManager.default.createDirectory(
                at: malformedDirectory,
                withIntermediateDirectories: false
            )
            try Data("not-json".utf8).write(
                to: malformedDirectory.appendingPathComponent("job.json")
            )

            let inventory = await repository.inventory(
                for: LibraryScope(libraryID: libraryID)
            )
            guard case let .available(value) = inventory else {
                return XCTFail("expected classified partial inventory")
            }
            XCTAssertEqual(value.jobs, [valid])
            XCTAssertFalse(value.isComplete)

            let latest = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )
            XCTAssertEqual(latest, .integrityMismatch)
        }
    }

    func testCorruptAttemptRootStillInventoriesAValidRunningWorkerWithoutMutation()
        async throws
    {
        let corruptRoots = [
            Data("corrupt-pointer".utf8),
            Data(#"{"schemaVersion":1,"sessions":"corrupt"}"#.utf8),
        ]
        for indexName in [".attempts.json", ".attempts.json.partial"] {
            for corruptRoot in corruptRoots {
                try await assertCorruptAttemptRootStillInventoriesAValidRunningWorker(
                    indexName: indexName,
                    corruptRoot: corruptRoot
                )
            }
        }
    }

    private func assertCorruptAttemptRootStillInventoriesAValidRunningWorker(
        indexName: String,
        corruptRoot: Data
    ) async throws {
        try await withLibrary { root, libraryID in
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let queued = try makeJob(state: .queued)
            let queuedWrite = await repository.create(queued)
            XCTAssertEqual(queuedWrite, .written(queued))
            let running = queued.replacing(state: .running)
            let runningWrite = await repository.transition(running, from: .queued)
            XCTAssertEqual(runningWrite, .written(running))
            try corruptRoot.write(
                to: root.appendingPathComponent("jobs/\(indexName)")
            )
            let jobs = root.appendingPathComponent("jobs", isDirectory: true)
            let before = try snapshotTree(at: jobs)
            let replacement = SessionProcessingJob(
                jobID: try TranscriptionJobID("job-20260830T120800000Z-8NPQ"),
                sessionID: running.sessionID,
                revisionID: try TranscriptRevisionID(
                    "trv-20260830T120900000Z-9RST"
                ),
                profileID: running.profileID,
                createdAt: try UTCInstant("2026-08-30T12:08:00.000Z"),
                state: .queued,
                expectedSelectedRevisionID: nil,
                cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                    "cancel-corrupt-index"
                )
            )

            let create = await repository.create(replacement)
            let transition = await repository.transition(
                running.replacing(state: .validating),
                from: .running
            )
            XCTAssertEqual(create, .failed)
            XCTAssertEqual(transition, .failed)
            XCTAssertEqual(try snapshotTree(at: jobs), before)

            let inventory = await repository.inventory(
                for: LibraryScope(libraryID: libraryID)
            )
            guard case let .available(value) = inventory else {
                return XCTFail("expected independently classified running Job")
            }
            XCTAssertEqual(value.jobs, [running])
            XCTAssertFalse(value.isComplete)
            let latest = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )
            XCTAssertEqual(latest, .integrityMismatch)
            XCTAssertEqual(try snapshotTree(at: jobs), before)
        }
    }

    func testMissingAttemptPointerStillInventoriesASequencedRunningWorker()
        async throws
    {
        try await withLibrary { root, libraryID in
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let queued = try makeJob(state: .queued)
            _ = await repository.create(queued)
            let running = queued.replacing(state: .running)
            _ = await repository.transition(running, from: .queued)
            try FileManager.default.removeItem(
                at: root.appendingPathComponent("jobs/.attempts.json")
            )

            let inventory = await repository.inventory(
                for: LibraryScope(libraryID: libraryID)
            )
            guard case let .available(value) = inventory else {
                return XCTFail("expected independently classified sequenced Job")
            }
            XCTAssertEqual(value.jobs, [running])
            XCTAssertFalse(value.isComplete)
            let latest = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )
            XCTAssertEqual(latest, .integrityMismatch)
        }
    }

    func testAttemptSequenceAboveContractMaximumIsExcludedFromPartialInventory()
        async throws
    {
        try await withLibrary { root, libraryID in
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let valid = try makeJob(state: .queued)
            let createResult = await repository.create(valid)
            XCTAssertEqual(createResult, .written(valid))
            let oversized = SessionProcessingJob(
                jobID: try TranscriptionJobID("job-20260830T120700000Z-7MNP"),
                sessionID: valid.sessionID,
                revisionID: try TranscriptRevisionID(
                    "trv-20260830T120800000Z-8NPQ"
                ),
                profileID: valid.profileID,
                createdAt: try UTCInstant("2026-08-30T12:07:00.000Z"),
                state: .queued,
                expectedSelectedRevisionID: nil,
                cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                    "cancel-oversized-attempt-sequence"
                )
            )
            let oversizedDirectory = root.appendingPathComponent("jobs")
                .appendingPathComponent(oversized.jobID.rawValue)
            try FileManager.default.createDirectory(
                at: oversizedDirectory,
                withIntermediateDirectories: false
            )
            try encodedJob(
                oversized,
                attemptSequence: 9_007_199_254_740_992
            ).write(to: oversizedDirectory.appendingPathComponent("job.json"))

            let inventory = await repository.inventory(
                for: LibraryScope(libraryID: libraryID)
            )

            guard case let .available(value) = inventory else {
                return XCTFail("expected independently classified valid Job")
            }
            XCTAssertEqual(value.jobs, [valid])
            XCTAssertFalse(value.isComplete)
            let latest = await repository.latest(
                for: try makeSelection(libraryID: libraryID)
            )
            XCTAssertEqual(
                latest,
                .integrityMismatch
            )
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

    func testTransitionRejectsPreparedPartialFileSubstitutionBeforeCommit()
        async throws
    {
        try await withLibrary { root, libraryID in
            let queued = try makeJob(state: .queued)
            let running = queued.replacing(state: .running)
            let substitute = queued.replacing(
                state: .failed,
                failure: .engineFailed
            )
            let writer = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID
            )
            let createResult = await writer.create(queued)
            XCTAssertEqual(createResult, .written(queued))
            let directory = root.appendingPathComponent("jobs", isDirectory: true)
                .appendingPathComponent(queued.jobID.rawValue, isDirectory: true)
            let installed = directory.appendingPathComponent("job.json")
            let partial = directory.appendingPathComponent("job.json.partial")
            let displaced = directory.appendingPathComponent(
                "job.json.partial.displaced"
            )
            let installedBytes = try Data(contentsOf: installed)
            let runningBytes = try encodedJob(running)
            let substituteBytes = try encodedJob(substitute)
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID,
                reconciliationFault: { point in
                    guard point == .beforeJobMutationCommit else { return }
                    try FileManager.default.moveItem(at: partial, to: displaced)
                    try substituteBytes.write(to: partial)
                }
            )

            let result = await repository.transition(running, from: .queued)

            XCTAssertEqual(result, .failed)
            XCTAssertEqual(try Data(contentsOf: installed), installedBytes)
            XCTAssertEqual(try? Data(contentsOf: partial), substituteBytes)
            var expectedRunningBytes = runningBytes
            expectedRunningBytes.append(0x0A)
            XCTAssertEqual(try? Data(contentsOf: displaced), expectedRunningBytes)
        }
    }

    func testTransitionRejectsPreparedPartialWithUnexpectedEntryBeforeCommit()
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
            let directory = root.appendingPathComponent("jobs", isDirectory: true)
                .appendingPathComponent(queued.jobID.rawValue, isDirectory: true)
            let installed = directory.appendingPathComponent("job.json")
            let partial = directory.appendingPathComponent("job.json.partial")
            let unexpected = directory.appendingPathComponent("unexpected")
            let installedBytes = try Data(contentsOf: installed)
            var runningBytes = try encodedJob(running)
            runningBytes.append(0x0A)
            let suspectBytes = Data("suspect".utf8)
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID,
                reconciliationFault: { point in
                    guard point == .beforeJobMutationCommit else { return }
                    try suspectBytes.write(to: unexpected)
                }
            )

            let result = await repository.transition(running, from: .queued)

            XCTAssertEqual(result, .failed)
            XCTAssertEqual(try Data(contentsOf: installed), installedBytes)
            XCTAssertEqual(try Data(contentsOf: partial), runningBytes)
            XCTAssertEqual(try Data(contentsOf: unexpected), suspectBytes)
        }
    }

    func testTransitionRejectsSameInodePreparedPartialMutationBeforeCommit()
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
            let directory = root.appendingPathComponent("jobs", isDirectory: true)
                .appendingPathComponent(queued.jobID.rawValue, isDirectory: true)
            let installed = directory.appendingPathComponent("job.json")
            let partial = directory.appendingPathComponent("job.json.partial")
            let installedBytes = try Data(contentsOf: installed)
            var preparedMutatedBytes = try encodedJob(running)
            preparedMutatedBytes.append(0x0A)
            let profile = Data("synthetic-qualified-v1".utf8)
            let profileRange = try XCTUnwrap(
                preparedMutatedBytes.range(of: profile)
            )
            preparedMutatedBytes[profileRange.lowerBound] = 120
            let mutatedBytes = preparedMutatedBytes
            let repository = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: libraryID,
                reconciliationFault: { point in
                    guard point == .beforeJobMutationCommit else { return }
                    let handle = try FileHandle(forWritingTo: partial)
                    try handle.truncate(atOffset: 0)
                    try handle.write(contentsOf: mutatedBytes)
                    try handle.synchronize()
                    try handle.close()
                }
            )

            let result = await repository.transition(running, from: .queued)

            XCTAssertEqual(result, .failed)
            XCTAssertEqual(try Data(contentsOf: installed), installedBytes)
            XCTAssertEqual(try Data(contentsOf: partial), mutatedBytes)
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
            XCTAssertEqual(object["schemaVersion"] as? Int, 3)
            XCTAssertEqual(object["attemptSequence"] as? Int, 1)
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

    func testV3StartSelectionBaselineAndAttemptSequenceAreDurable() async throws {
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

    private func encodedJob(
        _ job: SessionProcessingJob,
        attemptSequence: UInt64? = 1
    ) throws -> Data {
        var object: [String: Any] = [
            "schemaVersion": attemptSequence == nil ? 2 : 3,
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
        if let attemptSequence { object["attemptSequence"] = attemptSequence }
        if let cancellationRequestedAt = job.cancellationRequestedAt {
            object["cancellationRequestedAt"] = cancellationRequestedAt.rawValue
        }
        if let candidateArtifactSHA256 = job.candidateArtifactSHA256 {
            object["candidateArtifactSha256"] = candidateArtifactSHA256
        }
        if let failure = job.failure { object["failure"] = failure.rawValue }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func snapshotTree(at root: URL) throws -> [String: Data?] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        )
        var snapshot: [String: Data?] = [:]
        while let entry = enumerator.nextObject() as? URL {
            let relative = String(entry.path.dropFirst(root.path.count + 1))
            let isDirectory = try entry.resourceValues(forKeys: [.isDirectoryKey])
                .isDirectory == true
            snapshot[relative] = isDirectory ? nil : try Data(contentsOf: entry)
        }
        return snapshot
    }
}

private enum CausalAttemptTestFault: Error {
    case injectedCrash
}

private extension SessionProcessingJob {
    func replacing(
        state: SessionProcessingJobState,
        failure: SessionProcessingFailureReason? = nil,
        cancellationRequestedAt: UTCInstant? = nil,
        candidateArtifactSHA256: String? = nil
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
            candidateArtifactSHA256:
                candidateArtifactSHA256 ?? self.candidateArtifactSHA256,
            failure: failure
        )
    }
}
