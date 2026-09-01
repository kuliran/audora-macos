@testable import AudoraApplication
import AudoraDomain
import XCTest

final class SessionProcessingFeatureTests: XCTestCase {
    func testQualifiedOfflineRunPublishesOnlyThroughTranscriptPublisher() async throws {
        let fixture = try ProcessingFixture()
        let runtime = RuntimeProbe(.qualified(fixture.profile))
        let model = ModelProbe(.ready)
        let jobs = JobProbe()
        let revisions = RevisionProbe()
        let engine = EngineProbe(
            result: .success(
                VerifiedTranscriptionCandidate(
                    candidate: fixture.candidate,
                    artifactFingerprint: fixture.candidateFingerprint
                )
            )
        )
        let feature = DefaultSessionProcessingFeature(
            source: SourceProbe(.available(fixture.source)),
            runtime: runtime,
            model: model,
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        await feature.send(.start)

        guard case let .completed(completed) = await feature.currentState else {
            return XCTFail("expected selected immutable Revision")
        }
        XCTAssertEqual(completed.jobID, fixture.jobID)
        XCTAssertEqual(completed.selectedRevisionID, fixture.revisionID)
        let persistedStates = await jobs.states
        let engineRequests = await engine.requests
        let publishCount = await revisions.publishCount
        let selectedRevisionID = await revisions.selected?.revisionID
        XCTAssertEqual(persistedStates, [.queued, .running, .validating, .completed])
        XCTAssertEqual(engineRequests.count, 1)
        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(selectedRevisionID, fixture.revisionID)
    }

    func testLoadingIsIndeterminateAndWindowProgressNeverRegressesWhileETAMayRise()
        async throws
    {
        let fixture = try ProcessingFixture()
        let engine = SuspendedEngineProbe(
            result: VerifiedTranscriptionCandidate(
                candidate: fixture.candidate,
                artifactFingerprint: fixture.candidateFingerprint
            )
        )
        let feature = DefaultSessionProcessingFeature(
            source: SourceProbe(.available(fixture.source)),
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: JobProbe(),
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: RevisionProbe()),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        let run = Task { await feature.send(.start) }
        await engine.waitUntilTranscriptionStarts()

        await engine.emit(.phase(.loadingModel))
        guard case let .running(loading) = await feature.currentState else {
            return XCTFail("expected active model loading")
        }
        XCTAssertEqual(loading.phase, .loadingModel)
        XCTAssertNil(loading.progress)

        await engine.emit(.phase(.transcribing))
        await engine.emit(.progress(completed: 1, total: 4, etaSeconds: 3))
        await engine.emit(.progress(completed: 0, total: 4, etaSeconds: 1))
        await engine.emit(.progress(completed: 2, total: 4, etaSeconds: 5))
        await engine.emit(.phase(.loadingModel))
        guard case let .running(transcribing) = await feature.currentState else {
            return XCTFail("expected measurable transcription")
        }
        XCTAssertEqual(transcribing.phase, .transcribing)
        XCTAssertEqual(
            transcribing.progress,
            SessionProcessingProgress(
                completedWindows: 2,
                totalWindows: 4,
                approximateETASeconds: 5
            )
        )

        await engine.releaseTranscription()
        await run.value
    }

    func testCancelPersistsAuthorityReapsOnceAndRejectsLateCandidateAndProgress()
        async throws
    {
        let fixture = try ProcessingFixture()
        let cancelledAt = try UTCInstant("2026-08-30T12:07:00.000Z")
        let controlID = try TranscriptionCancellationAuthorityID(
            "cancel-synthetic-authority"
        )
        let jobs = JobProbe()
        let revisions = RevisionProbe()
        let engine = CancellableEngineProbe(
            lateResult: VerifiedTranscriptionCandidate(
                candidate: fixture.candidate,
                artifactFingerprint: fixture.candidateFingerprint
            )
        )
        let feature = DefaultSessionProcessingFeature(
            source: SourceProbe(.available(fixture.source)),
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: SequencedProcessingClock([fixture.createdAt, cancelledAt]),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID,
                cancellationAuthorityID: controlID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        let run = Task { await feature.send(.start) }
        await engine.waitUntilTranscriptionStarts()
        let cancellation = Task { await feature.send(.cancel) }
        await engine.waitUntilCancellationStarts()

        await feature.send(.cancel)
        await engine.releaseCancellation()
        await cancellation.value
        await run.value

        guard case let .cancelled(cancelled) = await feature.currentState else {
            return XCTFail("expected a retryable cancelled job")
        }
        XCTAssertEqual(cancelled.job.state, .cancelled)
        XCTAssertEqual(cancelled.job.cancellationAuthorityID, controlID)
        XCTAssertEqual(cancelled.job.cancellationRequestedAt, cancelledAt)
        XCTAssertEqual(cancelled.actions, [.retry])
        let cancellationCount = await engine.cancelledControls.count
        let publishCount = await revisions.publishCount
        let persistedStates = await jobs.snapshots.map(\.state)
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(persistedStates, [.queued, .running, .running, .cancelled])

        let terminal = await feature.currentState
        await engine.emit(.progress(completed: 4, total: 4, etaSeconds: 0))
        let afterLateProgress = await feature.currentState
        XCTAssertEqual(afterLateProgress, terminal)
    }

    func testCandidateValidationCASWinningCancelRaceCompletesWithoutWorkerCancellation()
        async throws
    {
        let fixture = try ProcessingFixture()
        let candidate = VerifiedTranscriptionCandidate(
            candidate: fixture.candidate,
            artifactFingerprint: fixture.candidateFingerprint
        )
        let newerJob = SessionProcessingJob(
            jobID: try TranscriptionJobID("job-20260830T120700000Z-7MNP"),
            sessionID: fixture.selection.sessionID,
            revisionID: try TranscriptRevisionID(
                "trv-20260830T120700000Z-7MNP"
            ),
            profileID: fixture.profile.profileID,
            createdAt: try UTCInstant("2026-08-30T12:07:00.000Z"),
            state: .running,
            expectedSelectedRevisionID: fixture.source.expectedSelectedRevisionID,
            cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                "cancel-newer-same-session-job"
            )
        )
        let jobs = CandidateWinsCancellationJobProbe(newerLatest: newerJob)
        let revisions = RevisionProbe()
        let engine = CandidateWinsCancellationEngineProbe(candidate: candidate)
        let feature = DefaultSessionProcessingFeature(
            source: SourceProbe(.available(fixture.source)),
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: SequencedProcessingClock([
                fixture.createdAt,
                try UTCInstant("2026-08-30T12:07:00.000Z"),
            ]),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        let run = Task { await feature.send(.start) }
        await engine.waitUntilTranscriptionStarts()
        await engine.releaseTranscription()
        await jobs.waitUntilValidatingIsDurable()

        let cancellation = Task { await feature.send(.cancel) }
        await jobs.waitUntilCancellationCASLoses()
        await cancellation.value

        let stateBeforeOriginalCASReturns = await feature.currentState
        let cancellationCount = await engine.cancellationCount
        let recoveryCount = await engine.recoveryCount
        let publishCount = await revisions.publishCountValue()
        let durableBeforeOriginalCASReturns = await jobs.currentState

        await jobs.releaseValidatingWrite()
        await run.value

        guard case let .completed(completed) = stateBeforeOriginalCASReturns else {
            return XCTFail("the first durable validating outcome must complete")
        }
        XCTAssertEqual(completed.jobID, fixture.jobID)
        XCTAssertEqual(completed.revisionID, fixture.revisionID)
        XCTAssertEqual(cancellationCount, 0)
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(durableBeforeOriginalCASReturns, .completed)
        guard case .completed = await feature.currentState else {
            return XCTFail("late original CAS return must not replace completion")
        }
        let finalPublishCount = await revisions.publishCountValue()
        XCTAssertEqual(finalPublishCount, 1)
    }

    func testCandidateCASWinningCancelRaceSurfacesDurablePublicationFailure()
        async throws
    {
        let fixture = try ProcessingFixture()
        let candidate = VerifiedTranscriptionCandidate(
            candidate: fixture.candidate,
            artifactFingerprint: fixture.candidateFingerprint
        )
        let newerRevisionID = try TranscriptRevisionID(
            "trv-20260830T120700000Z-7MNP"
        )
        let newerJob = SessionProcessingJob(
            jobID: try TranscriptionJobID("job-20260830T120700000Z-7MNP"),
            sessionID: fixture.selection.sessionID,
            revisionID: newerRevisionID,
            profileID: fixture.profile.profileID,
            createdAt: try UTCInstant("2026-08-30T12:07:00.000Z"),
            state: .running,
            expectedSelectedRevisionID: nil,
            cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                "cancel-newer-publication-race"
            )
        )
        let jobs = CandidateWinsCancellationJobProbe(newerLatest: newerJob)
        let revisions = SelectionCASRevisionProbe(
            selectedRevisionID: newerRevisionID
        )
        let engine = CandidateWinsCancellationEngineProbe(candidate: candidate)
        let feature = DefaultSessionProcessingFeature(
            source: SourceProbe(.available(fixture.source)),
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: SequencedProcessingClock([
                fixture.createdAt,
                try UTCInstant("2026-08-30T12:08:00.000Z"),
            ]),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        let run = Task { await feature.send(.start) }
        await engine.waitUntilTranscriptionStarts()
        await engine.releaseTranscription()
        await jobs.waitUntilValidatingIsDurable()

        let cancellation = Task { await feature.send(.cancel) }
        await jobs.waitUntilCancellationCASLoses()
        await cancellation.value

        guard case let .failed(failure) = await feature.currentState else {
            return XCTFail("durable validating failure must remain visible")
        }
        XCTAssertEqual(failure.reason, .staleSelection)
        XCTAssertEqual(failure.actions, [.retry])
        XCTAssertEqual(failure.job?.state, .failed)
        let durableState = await jobs.currentState
        let cancellationCount = await engine.cancellationCount
        let transcriptionCount = await engine.transcriptionCount
        XCTAssertEqual(durableState, .failed)
        XCTAssertEqual(cancellationCount, 0)
        XCTAssertEqual(transcriptionCount, 1)

        await jobs.releaseValidatingWrite()
        await run.value

        guard case let .failed(final) = await feature.currentState else {
            return XCTFail("late candidate CAS response must preserve failure")
        }
        XCTAssertEqual(final.reason, .staleSelection)
        XCTAssertEqual(final.actions, [.retry])
        let expectedSelections = await revisions.expectedSelectedRevisionIDs
        let finalCancellationCount = await engine.cancellationCount
        let finalTranscriptionCount = await engine.transcriptionCount
        XCTAssertEqual(expectedSelections, [nil])
        XCTAssertEqual(finalCancellationCount, 0)
        XCTAssertEqual(finalTranscriptionCount, 1)
    }

    func testSelectionDuringCancellationAppliesOnlyAfterCancelledStateIsDurable()
        async throws
    {
        let fixture = try ProcessingFixture()
        let secondSelection = SessionProcessingSelection(
            scope: fixture.selection.scope,
            sessionID: try SessionID("ses-20260830T120200000Z-3DEF")
        )
        let secondSource = SessionTranscriptionSource(
            selection: secondSelection,
            audioCapabilityID: try SessionTranscriptionAudioCapabilityID(
                "cap-second-synthetic-source"
            ),
            durationMilliseconds: fixture.source.durationMilliseconds,
            audioFingerprint: fixture.source.audioFingerprint,
            sourceFingerprints: fixture.source.sourceFingerprints,
            expectedSelectedRevisionID: nil
        )
        let source = SourceProbe([
            .available(fixture.source),
            .available(secondSource),
        ])
        let jobs = JobProbe()
        let engine = CancellableEngineProbe(
            lateResult: VerifiedTranscriptionCandidate(
                candidate: fixture.candidate,
                artifactFingerprint: fixture.candidateFingerprint
            )
        )
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: RevisionProbe()),
            clock: SequencedProcessingClock([
                fixture.createdAt,
                try UTCInstant("2026-08-30T12:07:00.000Z"),
            ]),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        let run = Task { await feature.send(.start) }
        await engine.waitUntilTranscriptionStarts()
        let cancellation = Task { await feature.send(.cancel) }
        await engine.waitUntilCancellationStarts()

        await feature.send(.selectSession(secondSelection))
        await run.value
        guard case .cancelling = await feature.currentState else {
            return XCTFail("selection must wait for durable cancellation")
        }
        let loadsBeforeReap = await source.loadCount
        XCTAssertEqual(loadsBeforeReap, 1)

        await engine.releaseCancellation()
        await cancellation.value

        guard case let .ready(ready) = await feature.currentState else {
            return XCTFail("expected the newest Session after cancellation finalized")
        }
        XCTAssertEqual(ready.source.selection, secondSelection)
        let persistedStates = await jobs.snapshots.map(\.state)
        let sourceLoadCount = await source.loadCount
        XCTAssertEqual(persistedStates, [.queued, .running, .running, .cancelled])
        XCTAssertEqual(sourceLoadCount, 2)
    }

    func testLibraryActivationRunsAfterUnconfirmedCancellationWhileOldRunRemains()
        async throws
    {
        let fixture = try ProcessingFixture()
        let activationScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120000000Z-9XYZ")
        )
        let abandoned = SessionProcessingJob(
            jobID: try TranscriptionJobID("job-20260830T120800000Z-8NPQ"),
            sessionID: try SessionID("ses-20260830T120800000Z-8NPQ"),
            revisionID: try TranscriptRevisionID(
                "trv-20260830T120800000Z-8NPQ"
            ),
            profileID: fixture.profile.profileID,
            createdAt: try UTCInstant("2026-08-30T12:08:00.000Z"),
            state: .queued,
            cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                "cancel-abandoned-next-library"
            )
        )
        let reconciliationID = try SessionProcessingReconciliationID(
            "reconcile-after-unconfirmed-cancel"
        )
        let jobs = JobProbe(
            inventoryResult: .available(
                SessionProcessingJobInventory(
                    reconciliationID: reconciliationID,
                    scope: activationScope,
                    jobs: [abandoned]
                )
            )
        )
        let engine = UnconfirmedCancellationEngineProbe(
            lateResult: VerifiedTranscriptionCandidate(
                candidate: fixture.candidate,
                artifactFingerprint: fixture.candidateFingerprint
            )
        )
        let feature = DefaultSessionProcessingFeature(
            source: SourceProbe(.available(fixture.source)),
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: RevisionProbe()),
            clock: SequencedProcessingClock([
                fixture.createdAt,
                try UTCInstant("2026-08-30T12:07:00.000Z"),
            ]),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        let run = Task { await feature.send(.start) }
        await engine.waitUntilTranscriptionStarts()
        let cancellation = Task { await feature.send(.cancel) }
        await engine.waitUntilCancellationStarts()

        await feature.send(.activateLibrary(activationScope))
        await engine.releaseCancellationAsUnconfirmed()
        await cancellation.value

        let finished = await jobs.finishedReconciliationIDs
        let abandonedTransitions = await jobs.snapshots.filter {
            $0.jobID == abandoned.jobID
        }
        XCTAssertEqual(finished, [reconciliationID])
        XCTAssertEqual(abandonedTransitions.map(\.state), [.interrupted])
        guard case .recoveryRequired = await feature.currentState else {
            return XCTFail("old unconfirmed worker must retain recovery authority")
        }

        await engine.releaseTranscription()
        await run.value
    }

    func testFailedCancellationPersistenceKeepsRecoveryFenceWhenReapIsUnconfirmed()
        async throws
    {
        let fixture = try ProcessingFixture()
        let activationScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120000000Z-9XYZ")
        )
        let abandoned = SessionProcessingJob(
            jobID: try TranscriptionJobID("job-20260830T120800000Z-8NPQ"),
            sessionID: try SessionID("ses-20260830T120800000Z-8NPQ"),
            revisionID: try TranscriptRevisionID(
                "trv-20260830T120800000Z-8NPQ"
            ),
            profileID: fixture.profile.profileID,
            createdAt: try UTCInstant("2026-08-30T12:08:00.000Z"),
            state: .queued,
            cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                "cancel-abandoned-persistence-failure"
            )
        )
        let reconciliationID = try SessionProcessingReconciliationID(
            "reconcile-after-persistence-failure"
        )
        let jobs = JobProbe(
            inventoryResult: .available(
                SessionProcessingJobInventory(
                    reconciliationID: reconciliationID,
                    scope: activationScope,
                    jobs: [abandoned]
                )
            ),
            failingCancellationRequestCount: 1
        )
        let revisions = RevisionProbe()
        let engine = UnconfirmedCancellationEngineProbe(
            lateResult: VerifiedTranscriptionCandidate(
                candidate: fixture.candidate,
                artifactFingerprint: fixture.candidateFingerprint
            )
        )
        let feature = DefaultSessionProcessingFeature(
            source: SourceProbe(.available(fixture.source)),
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: SequencedProcessingClock([
                fixture.createdAt,
                try UTCInstant("2026-08-30T12:07:00.000Z"),
            ]),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        let run = Task { await feature.send(.start) }
        await engine.waitUntilTranscriptionStarts()
        let cancellation = Task { await feature.send(.cancel) }
        await engine.waitUntilCancellationStarts()

        await feature.send(.activateLibrary(activationScope))
        await engine.releaseCancellationAsUnconfirmed()
        await cancellation.value

        guard case let .recoveryRequired(authoritative) = await feature.currentState
        else {
            return XCTFail("unconfirmed worker must retain recovery authority")
        }
        XCTAssertEqual(authoritative.jobID, fixture.jobID)
        XCTAssertNotNil(authoritative.cancellationAuthorityID)
        XCTAssertNil(authoritative.cancellationRequestedAt)
        let finishedReconciliations = await jobs.finishedReconciliationIDs
        let abandonedStates = await jobs.snapshots.filter {
            $0.jobID == abandoned.jobID
        }.map(\.state)
        XCTAssertEqual(finishedReconciliations, [reconciliationID])
        XCTAssertEqual(
            abandonedStates,
            [.interrupted]
        )

        await engine.releaseTranscription()
        await run.value

        guard case let .recoveryRequired(afterLateResult) = await feature.currentState
        else { return XCTFail("late worker result must remain fenced") }
        let publishCount = await revisions.publishCountValue()
        XCTAssertEqual(afterLateResult.jobID, fixture.jobID)
        XCTAssertEqual(publishCount, 0)
    }

    func testFailedCancellationPersistenceBecomesRetryableOnlyAfterReapProof()
        async throws
    {
        let fixture = try ProcessingFixture()
        let jobs = JobProbe(failingCancellationRequestCount: 1)
        let revisions = RevisionProbe()
        let engine = CancellableEngineProbe(
            lateResult: VerifiedTranscriptionCandidate(
                candidate: fixture.candidate,
                artifactFingerprint: fixture.candidateFingerprint
            )
        )
        let feature = DefaultSessionProcessingFeature(
            source: SourceProbe(.available(fixture.source)),
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: SequencedProcessingClock([
                fixture.createdAt,
                try UTCInstant("2026-08-30T12:07:00.000Z"),
            ]),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        let run = Task { await feature.send(.start) }
        await engine.waitUntilTranscriptionStarts()
        let cancellation = Task { await feature.send(.cancel) }
        await engine.waitUntilCancellationStarts()
        await engine.releaseCancellation()
        await cancellation.value
        await run.value

        guard case let .failed(failure) = await feature.currentState else {
            return XCTFail("reaped worker may expose the durable retry path")
        }
        XCTAssertEqual(failure.reason, .jobPersistenceFailed)
        XCTAssertEqual(failure.actions, [.retry])
        XCTAssertEqual(failure.job?.state, .running)
        XCTAssertNil(failure.job?.cancellationRequestedAt)
        let cancellationCount = await engine.cancelledControls.count
        let publishCount = await revisions.publishCountValue()
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(publishCount, 0)
    }

    func testUnqualifiedPinnedProfileNeverCreatesAJobOrLaunchesAnEngine() async throws {
        let fixture = try ProcessingFixture()
        let runtime = RuntimeProbe(
            .unavailable(.qualificationBlocked(profileID: fixture.profile.profileID))
        )
        let source = SourceProbe(.available(fixture.source))
        let model = ModelProbe(.ready)
        let jobs = JobProbe()
        let revisions = RevisionProbe()
        let engine = EngineProbe(result: .failure(.launchFailed))
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: runtime,
            model: model,
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        await feature.send(.start)

        guard case let .unavailable(unavailable) = await feature.currentState else {
            return XCTFail("expected explicit pinned-profile failure")
        }
        XCTAssertEqual(
            unavailable.reason,
            .qualificationBlocked(profileID: fixture.profile.profileID)
        )
        XCTAssertEqual(unavailable.actions, [])
        let blockedState = await feature.currentState
        let resolutionCountBeforeSecondStart = await runtime.resolutionCount

        await feature.send(.start)

        let persistedStates = await jobs.states
        let engineRequests = await engine.requests
        let modelVerificationCount = await model.verificationCount
        let resolutionCountAfterSecondStart = await runtime.resolutionCount
        let sourceLoadCount = await source.loadCount
        let publishCount = await revisions.publishCountValue()
        let stateAfterSecondStart = await feature.currentState
        XCTAssertEqual(persistedStates, [])
        XCTAssertEqual(engineRequests.count, 0)
        XCTAssertEqual(modelVerificationCount, 0)
        XCTAssertEqual(resolutionCountBeforeSecondStart, 1)
        XCTAssertEqual(resolutionCountAfterSecondStart, resolutionCountBeforeSecondStart)
        XCTAssertEqual(sourceLoadCount, 1)
        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(stateAfterSecondStart, blockedState)
    }

    func testStartIsInertForRetryOnlyTerminalStates() async throws {
        let fixture = try ProcessingFixture()
        let terminalJobs = [
            fixture.job(state: .cancelled),
            fixture.job(state: .interrupted),
            fixture.job(state: .failed, failure: .engineFailed),
        ]

        for terminalJob in terminalJobs {
            let source = SourceProbe(.available(fixture.source))
            let runtime = RuntimeProbe(.qualified(fixture.profile))
            let model = ModelProbe(.ready)
            let jobs = JobProbe(latest: terminalJob)
            let revisions = RevisionProbe()
            let engine = EngineProbe(
                result: .success(
                    VerifiedTranscriptionCandidate(
                        candidate: fixture.candidate,
                        artifactFingerprint: fixture.candidateFingerprint
                    )
                )
            )
            let feature = DefaultSessionProcessingFeature(
                source: source,
                runtime: runtime,
                model: model,
                acoustics: AcousticProbe(fixture.evidence),
                jobs: jobs,
                engine: engine,
                publisher: TranscriptRevisionPublisher(repository: revisions),
                clock: FixedProcessingClock(fixture.createdAt),
                identifiers: FixedProcessingIdentifiers(
                    jobID: fixture.jobID,
                    revisionID: fixture.revisionID
                )
            )

            await feature.send(.selectSession(fixture.selection))
            let stateBeforeStart = await feature.currentState

            await feature.send(.start)

            let stateAfterStart = await feature.currentState
            let sourceLoadCount = await source.loadCount
            let runtimeResolutionCount = await runtime.resolutionCount
            let modelVerificationCount = await model.verificationCount
            let persistedStates = await jobs.states
            let engineRequestCount = await engine.requestCount()
            let publishCount = await revisions.publishCountValue()
            XCTAssertEqual(stateAfterStart, stateBeforeStart, "\(terminalJob.state)")
            XCTAssertEqual(sourceLoadCount, 1, "\(terminalJob.state)")
            XCTAssertEqual(runtimeResolutionCount, 0, "\(terminalJob.state)")
            XCTAssertEqual(modelVerificationCount, 0, "\(terminalJob.state)")
            XCTAssertEqual(persistedStates, [], "\(terminalJob.state)")
            XCTAssertEqual(engineRequestCount, 0, "\(terminalJob.state)")
            XCTAssertEqual(publishCount, 0, "\(terminalJob.state)")
        }
    }

    func testMissingModelCanBePreparedThenStartedWithoutChangingEngine() async throws {
        let fixture = try ProcessingFixture()
        let runtime = RuntimeProbe(.qualified(fixture.profile))
        let model = ModelProbe(.missing, preparation: .ready)
        let jobs = JobProbe()
        let revisions = RevisionProbe()
        let engine = EngineProbe(
            result: .success(
                VerifiedTranscriptionCandidate(
                    candidate: fixture.candidate,
                    artifactFingerprint: fixture.candidateFingerprint
                )
            )
        )
        let feature = DefaultSessionProcessingFeature(
            source: SourceProbe(.available(fixture.source)),
            runtime: runtime,
            model: model,
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        await feature.send(.start)
        guard case let .unavailable(unavailable) = await feature.currentState else {
            return XCTFail("expected missing model")
        }
        XCTAssertEqual(unavailable.reason, .modelMissing)

        await feature.send(.prepare)
        await feature.send(.start)

        guard case .completed = await feature.currentState else {
            return XCTFail("expected successful Start after explicit preparation")
        }
        let preparationActions = await model.preparationActions
        let requestProfileIDs = await engine.requests.map(\.profileID)
        XCTAssertEqual(preparationActions, [.prepare])
        XCTAssertEqual(requestProfileIDs, [fixture.profile.profileID])
    }

    func testRejectedCandidateNeverChangesSelectionAndPersistsFailure() async throws {
        let fixture = try ProcessingFixture()
        let invalidCandidate = fixture.candidate.replacing(sessionID: "ses-wrong")
        let jobs = JobProbe()
        let revisions = RevisionProbe()
        let feature = DefaultSessionProcessingFeature(
            source: SourceProbe(.available(fixture.source)),
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: EngineProbe(
                result: .success(
                    VerifiedTranscriptionCandidate(
                        candidate: invalidCandidate,
                        artifactFingerprint: fixture.candidateFingerprint
                    )
                )
            ),
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        await feature.send(.start)

        guard case let .failed(failure) = await feature.currentState else {
            return XCTFail("expected validation failure")
        }
        XCTAssertEqual(failure.reason, .candidateRejected)
        XCTAssertEqual(failure.actions, [.retry])
        let persistedStates = await jobs.states
        let selectedRevision = await revisions.selected
        let publishCount = await revisions.publishCount
        XCTAssertEqual(persistedStates, [.queued, .running, .validating, .failed])
        XCTAssertNil(selectedRevision)
        XCTAssertEqual(publishCount, 0)
    }

    func testRelaunchDoesNotInventRecoveryForNonterminalJob() async throws {
        let fixture = try ProcessingFixture()
        let jobs = JobProbe(
            latest: SessionProcessingJob(
                jobID: fixture.jobID,
                sessionID: fixture.source.selection.sessionID,
                revisionID: fixture.revisionID,
                profileID: fixture.profile.profileID,
                createdAt: fixture.createdAt,
                state: .running,
                cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                    "cancel-relaunch-authority"
                )
            )
        )
        let engine = EngineProbe(result: .failure(.launchFailed))
        let feature = DefaultSessionProcessingFeature(
            source: SourceProbe(.available(fixture.source)),
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: RevisionProbe()),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))

        guard case let .recoveryRequired(job) = await feature.currentState else {
            return XCTFail("expected future recovery seam")
        }
        XCTAssertEqual(job.state, .running)
        let persistedStates = await jobs.states
        let engineRequests = await engine.requests
        XCTAssertEqual(persistedStates, [])
        XCTAssertEqual(engineRequests.count, 0)
    }

    func testRelaunchInterruptsRunningJobOnlyAfterOwnedProcessIsProvenAbsent()
        async throws
    {
        let fixture = try ProcessingFixture()
        let running = fixture.job(state: .running)
        let jobs = JobProbe(latest: running)
        let engine = EngineProbe(
            result: .failure(.launchFailed),
            presence: .absent
        )
        let feature = fixture.makeFeature(jobs: jobs, engine: engine)

        await feature.send(.selectSession(fixture.selection))

        guard case let .interrupted(interrupted) = await feature.currentState else {
            return XCTFail("expected retryable interruption after absence proof")
        }
        XCTAssertEqual(interrupted.job.state, .interrupted)
        XCTAssertEqual(interrupted.actions, [.retry])
        let presenceQueries = await engine.presenceQueries
        let persistedStates = await jobs.states
        XCTAssertEqual(presenceQueries, [running.executionReference])
        XCTAssertEqual(persistedStates, [.interrupted])
    }

    func testRelaunchReapsPresentOwnedWorkerBeforeInterrupting() async throws {
        let fixture = try ProcessingFixture()
        let running = fixture.job(state: .running)
        let jobs = JobProbe(latest: running)
        let engine = EngineProbe(
            result: .failure(.launchFailed),
            presence: .present,
            cancellation: .reaped
        )
        let feature = fixture.makeFeature(jobs: jobs, engine: engine)

        await feature.send(.selectSession(fixture.selection))

        guard case let .interrupted(interrupted) = await feature.currentState else {
            return XCTFail("expected interruption only after owned orphan reap")
        }
        XCTAssertEqual(interrupted.job.state, .interrupted)
        let cancellations = await engine.cancelledExecutions
        let persistedStates = await jobs.states
        XCTAssertEqual(cancellations, [running.executionReference])
        XCTAssertEqual(persistedStates, [.interrupted])
    }

    func testRelaunchFinalizesDurableCancellationAsCancelledAfterAbsence()
        async throws
    {
        let fixture = try ProcessingFixture()
        let cancelledAt = try UTCInstant("2026-08-30T12:07:00.000Z")
        let running = try XCTUnwrap(
            fixture.job(state: .running).requestingCancellation(at: cancelledAt)
        )
        let jobs = JobProbe(latest: running)
        let engine = EngineProbe(
            result: .failure(.launchFailed),
            presence: .absent
        )
        let feature = fixture.makeFeature(jobs: jobs, engine: engine)

        await feature.send(.selectSession(fixture.selection))

        guard case let .cancelled(cancelled) = await feature.currentState else {
            return XCTFail("expected durable cancellation to finish as cancelled")
        }
        XCTAssertEqual(cancelled.job.cancellationRequestedAt, cancelledAt)
        XCTAssertEqual(cancelled.actions, [.retry])
        let persistedStates = await jobs.states
        XCTAssertEqual(persistedStates, [.cancelled])
    }

    func testRelaunchInterruptsDurableQueuedWorkWithoutCheckingOrLaunchingAWorker()
        async throws
    {
        let fixture = try ProcessingFixture()
        let queued = fixture.job(state: .queued)
        let jobs = JobProbe(latest: queued)
        let engine = EngineProbe(
            result: .failure(.launchFailed),
            presence: .absent
        )
        let feature = fixture.makeFeature(jobs: jobs, engine: engine)

        await feature.send(.selectSession(fixture.selection))

        guard case let .interrupted(snapshot) = await feature.currentState else {
            return XCTFail("expected queued crash window to become retryable")
        }
        XCTAssertEqual(snapshot.job.state, .interrupted)
        XCTAssertEqual(snapshot.job.jobID, queued.jobID)
        XCTAssertEqual(snapshot.job.sessionID, queued.sessionID)
        XCTAssertEqual(snapshot.source, fixture.source)
        XCTAssertEqual(snapshot.actions, [.retry])
        let presenceCount = await engine.presenceQueryCount()
        let requestCount = await engine.requestCount()
        let persistedStates = await jobs.states
        XCTAssertEqual(presenceCount, 0)
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(persistedStates, [.interrupted])
    }

    func testSelectingValidatingJobWithUnavailableCorruptOrMismatchedSourceInterruptsIt()
        async throws
    {
        let fixture = try ProcessingFixture()
        let validating = fixture.job(
            state: .validating,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )
        let otherSelection = SessionProcessingSelection(
            scope: fixture.selection.scope,
            sessionID: try SessionID("ses-20260830T121000000Z-0RST")
        )
        let mismatchedSource = SessionTranscriptionSource(
            selection: otherSelection,
            audioCapabilityID: fixture.source.audioCapabilityID,
            durationMilliseconds: fixture.source.durationMilliseconds,
            audioFingerprint: fixture.source.audioFingerprint,
            sourceFingerprints: fixture.source.sourceFingerprints,
            expectedSelectedRevisionID: nil
        )
        let cases: [(SessionTranscriptionSourceResult, SessionProcessingUnavailableReason)] = [
            (.unavailable, .sourceUnavailable),
            (.integrityMismatch, .sourceIntegrityMismatch),
            (.available(mismatchedSource), .sourceIntegrityMismatch),
        ]

        for (result, expectedReason) in cases {
            let jobs = JobProbe(latest: validating)
            let feature = DefaultSessionProcessingFeature(
                source: SourceProbe(result),
                runtime: RuntimeProbe(.qualified(fixture.profile)),
                model: ModelProbe(.ready),
                acoustics: AcousticProbe(fixture.evidence),
                jobs: jobs,
                engine: EngineProbe(result: .failure(.launchFailed)),
                publisher: TranscriptRevisionPublisher(repository: RevisionProbe()),
                clock: FixedProcessingClock(fixture.createdAt),
                identifiers: FixedProcessingIdentifiers(
                    jobID: fixture.jobID,
                    revisionID: fixture.revisionID
                )
            )

            await feature.send(.selectSession(fixture.selection))

            let persisted = await jobs.snapshots
            guard case let .unavailable(snapshot) = await feature.currentState else {
                return XCTFail("expected source failure to remain visible")
            }
            XCTAssertEqual(snapshot.reason, expectedReason)
            XCTAssertEqual(persisted.map(\.state), [.interrupted])
        }
    }

    func testLibraryActivationReconcilesEveryQueuedJobWithoutSelectingASession()
        async throws
    {
        let fixture = try ProcessingFixture()
        let secondSelection = SessionProcessingSelection(
            scope: fixture.selection.scope,
            sessionID: try SessionID("ses-20260830T120200000Z-3DEF")
        )
        let secondSource = SessionTranscriptionSource(
            selection: secondSelection,
            audioCapabilityID: try SessionTranscriptionAudioCapabilityID(
                "cap-second-relaunch-source"
            ),
            durationMilliseconds: fixture.source.durationMilliseconds,
            audioFingerprint: fixture.source.audioFingerprint,
            sourceFingerprints: fixture.source.sourceFingerprints,
            expectedSelectedRevisionID: nil
        )
        let firstJob = fixture.job(state: .queued)
        let secondJob = SessionProcessingJob(
            jobID: try TranscriptionJobID("job-20260830T120700000Z-7MNP"),
            sessionID: secondSelection.sessionID,
            revisionID: try TranscriptRevisionID("trv-20260830T120700000Z-7MNP"),
            profileID: fixture.profile.profileID,
            createdAt: try UTCInstant("2026-08-30T12:07:00.000Z"),
            state: .queued,
            cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                "cancel-second-relaunch"
            )
        )
        let reconciliationID = try SessionProcessingReconciliationID(
            "reconcile-synthetic-library"
        )
        let source = ReconciliationSourceProbe(
            sources: [fixture.source, secondSource],
            reconciliationID: reconciliationID
        )
        let jobs = JobProbe(
            inventoryResult: .available(
                SessionProcessingJobInventory(
                    reconciliationID: reconciliationID,
                    scope: fixture.selection.scope,
                    jobs: [firstJob, secondJob]
                )
            )
        )
        let engine = EngineProbe(
            result: .failure(.launchFailed),
            presence: .present,
            cancellation: .reaped
        )
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: RevisionProbe()),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.activateLibrary(fixture.selection.scope))

        let current = await feature.currentState
        let reconciled = await jobs.snapshots
        let loadedSelections = await source.selections
        let finished = await jobs.finishedReconciliationIDs
        let presenceCount = await engine.presenceQueryCount()
        let requestCount = await engine.requestCount()
        XCTAssertEqual(
            current,
            .unavailable(
                SessionProcessingUnavailableSnapshot(
                    selection: nil,
                    reason: .noSession,
                    actions: []
                )
            )
        )
        XCTAssertEqual(reconciled.map(\.jobID), [firstJob.jobID, secondJob.jobID])
        XCTAssertEqual(reconciled.map(\.state), [.interrupted, .interrupted])
        XCTAssertEqual(loadedSelections, [])
        XCTAssertEqual(finished, [reconciliationID])
        XCTAssertEqual(presenceCount, 0)
        XCTAssertEqual(requestCount, 0)
    }

    func testLibraryActivationStaleTransitionRetainsTheExactDurableWinner()
        async throws
    {
        let fixture = try ProcessingFixture()
        let queued = fixture.job(state: .queued)
        let winner = fixture.job(state: .failed, failure: .engineFailed)
        let reconciliationID = try SessionProcessingReconciliationID(
            "reconcile-stale-transition-winner"
        )
        let jobs = ActivationTransitionProbe(
            scope: fixture.selection.scope,
            reconciliationID: reconciliationID,
            inventoried: queued,
            transitionResult: .stale,
            exactLoadResult: .loaded(winner)
        )
        let source = SourceProbe(.available(fixture.source))
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: EngineProbe(result: .failure(.launchFailed)),
            publisher: TranscriptRevisionPublisher(repository: RevisionProbe()),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.activateLibrary(fixture.selection.scope))
        await feature.send(.selectSession(fixture.selection))

        guard case let .failed(failure) = await feature.currentState else {
            return XCTFail("the exact first durable winner must remain observable")
        }
        XCTAssertEqual(failure.job, winner)
        XCTAssertEqual(failure.reason, .engineFailed)
        XCTAssertEqual(failure.actions, [.retry])
        let exactLoads = await jobs.exactLoadCount
        let latestLoads = await jobs.latestLoadCount
        let finished = await jobs.finishedReconciliationIDs
        XCTAssertEqual(exactLoads, 1)
        XCTAssertEqual(latestLoads, 0)
        XCTAssertEqual(finished, [reconciliationID])
    }

    func testLibraryActivationImmediatelyResumesStaleValidatingWinnerWithoutSelection()
        async throws
    {
        let fixture = try ProcessingFixture()
        let queued = fixture.job(state: .queued)
        let validating = fixture.job(
            state: .validating,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )
        let reconciliationID = try SessionProcessingReconciliationID(
            "reconcile-stale-validating-winner"
        )
        let jobs = ActivationWinnerProbe(
            scope: fixture.selection.scope,
            reconciliationID: reconciliationID,
            inventoried: queued,
            firstWinner: validating
        )
        let source = ReconciliationSourceProbe(
            sources: [fixture.source],
            reconciliationID: reconciliationID
        )
        let engine = EngineProbe(
            result: .failure(.launchFailed),
            recovered: .available(
                VerifiedTranscriptionCandidate(
                    candidate: fixture.candidate,
                    artifactFingerprint: fixture.candidateFingerprint
                )
            )
        )
        let revisions = RevisionProbe()
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.activateLibrary(fixture.selection.scope))

        let durable = await jobs.currentJob
        let recovered = await engine.recoveryJobs
        let sourceLoads = await source.selections
        let publishCount = await revisions.publishCountValue()
        let finished = await jobs.finishedReconciliationIDs
        XCTAssertEqual(durable?.state, .completed)
        XCTAssertEqual(recovered, [validating])
        XCTAssertEqual(sourceLoads, [fixture.selection])
        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(finished, [reconciliationID])
        guard case let .unavailable(state) = await feature.currentState else {
            return XCTFail("launch reconciliation must not select a Session")
        }
        XCTAssertEqual(state.reason, .noSession)
    }

    func testLibraryActivationImmediatelyVerifiesStaleCompletedWinnerWithoutSelection()
        async throws
    {
        let fixture = try ProcessingFixture()
        let queued = fixture.job(state: .queued)
        let completed = fixture.job(
            state: .completed,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )
        let reconciliationID = try SessionProcessingReconciliationID(
            "reconcile-stale-completed-winner"
        )
        let jobs = ActivationWinnerProbe(
            scope: fixture.selection.scope,
            reconciliationID: reconciliationID,
            inventoried: queued,
            firstWinner: completed
        )
        let source = ReconciliationSourceProbe(
            sources: [fixture.source],
            reconciliationID: reconciliationID
        )
        let engine = EngineProbe(result: .failure(.launchFailed))
        let revisions = RevisionProbe()
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.activateLibrary(fixture.selection.scope))

        let durable = await jobs.currentJob
        let sourceLoads = await source.selections
        let exactReopens = await revisions.exactReopenCount
        let publishCount = await revisions.publishCountValue()
        let requestCount = await engine.requestCount()
        let recoveryCount = await engine.recoveryCount()
        let finished = await jobs.finishedReconciliationIDs
        XCTAssertEqual(durable, completed)
        XCTAssertEqual(sourceLoads, [fixture.selection])
        XCTAssertEqual(exactReopens, 1)
        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(recoveryCount, 0)
        XCTAssertEqual(finished, [reconciliationID])
        guard case let .unavailable(state) = await feature.currentState else {
            return XCTFail("launch reconciliation must not select a Session")
        }
        XCTAssertEqual(state.reason, .noSession)
    }

    func testLibraryActivationContinuesBackgroundControlForStaleRunningWinnerWithoutSelection()
        async throws
    {
        let fixture = try ProcessingFixture()
        let queued = fixture.job(state: .queued)
        let running = fixture.job(state: .running)
        let reconciliationID = try SessionProcessingReconciliationID(
            "reconcile-stale-running-winner"
        )
        let jobs = ActivationWinnerProbe(
            scope: fixture.selection.scope,
            reconciliationID: reconciliationID,
            inventoried: queued,
            firstWinner: running
        )
        let source = ReconciliationSourceProbe(
            sources: [fixture.source],
            reconciliationID: reconciliationID
        )
        let engine = EngineProbe(
            result: .failure(.launchFailed),
            presence: .absent
        )
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: RevisionProbe()),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.activateLibrary(fixture.selection.scope))

        let durable = await jobs.currentJob
        let presenceQueries = await engine.presenceQueries
        let sourceLoads = await source.selections
        let transitionCount = await jobs.transitionCount
        XCTAssertEqual(durable?.state, .interrupted)
        XCTAssertEqual(presenceQueries, [running.executionReference])
        XCTAssertEqual(sourceLoads, [])
        XCTAssertEqual(transitionCount, 2)
        guard case let .unavailable(state) = await feature.currentState else {
            return XCTFail("launch reconciliation must not select a Session")
        }
        XCTAssertEqual(state.reason, .noSession)
    }

    func testLibraryActivationInterruptsStaleValidatingWinnerWhenSourceCapabilityFails()
        async throws
    {
        let fixture = try ProcessingFixture()
        let queued = fixture.job(state: .queued)
        let validating = fixture.job(
            state: .validating,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )

        for (index, sourceResult) in [
            SessionTranscriptionSourceResult.unavailable,
            .integrityMismatch,
        ].enumerated() {
            let reconciliationID = try SessionProcessingReconciliationID(
                "reconcile-stale-validating-source-\(index)"
            )
            let jobs = ActivationWinnerProbe(
                scope: fixture.selection.scope,
                reconciliationID: reconciliationID,
                inventoried: queued,
                firstWinner: validating
            )
            let source = ReconciliationSourceProbe(
                result: sourceResult,
                reconciliationID: reconciliationID
            )
            let engine = EngineProbe(result: .failure(.launchFailed))
            let revisions = RevisionProbe()
            let feature = DefaultSessionProcessingFeature(
                source: source,
                runtime: RuntimeProbe(.qualified(fixture.profile)),
                model: ModelProbe(.ready),
                acoustics: AcousticProbe(fixture.evidence),
                jobs: jobs,
                engine: engine,
                publisher: TranscriptRevisionPublisher(repository: revisions),
                clock: FixedProcessingClock(fixture.createdAt),
                identifiers: FixedProcessingIdentifiers(
                    jobID: fixture.jobID,
                    revisionID: fixture.revisionID
                )
            )

            await feature.send(.activateLibrary(fixture.selection.scope))

            let durable = await jobs.currentJob
            let sourceLoads = await source.selections
            let recoveryCount = await engine.recoveryCount()
            let publishCount = await revisions.publishCountValue()
            let transitionCount = await jobs.transitionCount
            XCTAssertEqual(durable?.state, .interrupted, "case \(index)")
            XCTAssertEqual(sourceLoads, [fixture.selection], "case \(index)")
            XCTAssertEqual(recoveryCount, 0, "case \(index)")
            XCTAssertEqual(publishCount, 0, "case \(index)")
            XCTAssertEqual(transitionCount, 2, "case \(index)")
        }
    }

    func testLibraryActivationStopsWhenStaleExactLoadDoesNotAdvanceTheJob()
        async throws
    {
        let fixture = try ProcessingFixture()
        let queued = fixture.job(state: .queued)
        let reconciliationID = try SessionProcessingReconciliationID(
            "reconcile-stale-identical-winner"
        )
        let jobs = ActivationWinnerProbe(
            scope: fixture.selection.scope,
            reconciliationID: reconciliationID,
            inventoried: queued,
            firstWinner: queued
        )
        let source = ReconciliationSourceProbe(
            sources: [fixture.source],
            reconciliationID: reconciliationID
        )
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: EngineProbe(result: .failure(.launchFailed)),
            publisher: TranscriptRevisionPublisher(repository: RevisionProbe()),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.activateLibrary(fixture.selection.scope))

        let durable = await jobs.currentJob
        let transitionCount = await jobs.transitionCount
        let exactLoadCount = await jobs.exactLoadCount
        let sourceLoads = await source.selections
        let finished = await jobs.finishedReconciliationIDs
        XCTAssertEqual(durable, queued)
        XCTAssertEqual(transitionCount, 1)
        XCTAssertEqual(exactLoadCount, 1)
        XCTAssertEqual(sourceLoads, [])
        XCTAssertEqual(finished, [reconciliationID])
    }

    func testLibraryActivationUnconfirmedTransitionRequiresObservableRecovery()
        async throws
    {
        let fixture = try ProcessingFixture()
        let queued = fixture.job(state: .queued)

        for (index, result) in [
            SessionProcessingJobWriteResult.collision,
            .failed,
        ].enumerated() {
            let reconciliationID = try SessionProcessingReconciliationID(
                "reconcile-unconfirmed-transition-\(index)"
            )
            let jobs = ActivationTransitionProbe(
                scope: fixture.selection.scope,
                reconciliationID: reconciliationID,
                inventoried: queued,
                transitionResult: result,
                exactLoadResult: .none
            )
            let source = SourceProbe(.available(fixture.source))
            let feature = DefaultSessionProcessingFeature(
                source: source,
                runtime: RuntimeProbe(.qualified(fixture.profile)),
                model: ModelProbe(.ready),
                acoustics: AcousticProbe(fixture.evidence),
                jobs: jobs,
                engine: EngineProbe(result: .failure(.launchFailed)),
                publisher: TranscriptRevisionPublisher(repository: RevisionProbe()),
                clock: FixedProcessingClock(fixture.createdAt),
                identifiers: FixedProcessingIdentifiers(
                    jobID: fixture.jobID,
                    revisionID: fixture.revisionID
                )
            )

            await feature.send(.activateLibrary(fixture.selection.scope))
            await feature.send(.selectSession(fixture.selection))

            guard case let .recoveryRequired(authority) = await feature.currentState
            else {
                XCTFail("unconfirmed launch persistence must require recovery")
                continue
            }
            XCTAssertEqual(authority, queued)
            let sourceLoads = await source.loadCount
            let exactLoads = await jobs.exactLoadCount
            let latestLoads = await jobs.latestLoadCount
            let finished = await jobs.finishedReconciliationIDs
            XCTAssertEqual(sourceLoads, 0, "case \(index)")
            XCTAssertEqual(exactLoads, 0, "case \(index)")
            XCTAssertEqual(latestLoads, 0, "case \(index)")
            XCTAssertEqual(finished, [reconciliationID], "case \(index)")
        }
    }

    func testLibraryActivationReapsRunningWorkerWhenSessionAudioIsUnavailable()
        async throws
    {
        let fixture = try ProcessingFixture()
        let running = fixture.job(state: .running)
        let reconciliationID = try SessionProcessingReconciliationID(
            "reconcile-missing-session"
        )
        let source = ReconciliationSourceProbe(
            sources: [],
            reconciliationID: reconciliationID
        )
        let jobs = JobProbe(
            inventoryResult: .available(
                SessionProcessingJobInventory(
                    reconciliationID: reconciliationID,
                    scope: fixture.selection.scope,
                    jobs: [running]
                )
            )
        )
        let engine = EngineProbe(
            result: .failure(.launchFailed),
            presence: .present,
            cancellation: .reaped
        )
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: RevisionProbe()),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.activateLibrary(fixture.selection.scope))

        let persisted = await jobs.snapshots
        let presenceQueries = await engine.presenceQueries
        let cancellations = await engine.cancelledExecutions
        let sourceLoads = await source.selections
        XCTAssertEqual(persisted.map(\.state), [.interrupted])
        XCTAssertEqual(presenceQueries, [running.executionReference])
        XCTAssertEqual(cancellations, [running.executionReference])
        XCTAssertEqual(sourceLoads, [])
    }

    func testLibraryActivationInterruptsValidatingJobWhenSealedSourceIsUnavailable()
        async throws
    {
        let fixture = try ProcessingFixture()
        let validating = fixture.job(
            state: .validating,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )
        let reconciliationID = try SessionProcessingReconciliationID(
            "reconcile-missing-validating-source"
        )
        let source = ReconciliationSourceProbe(
            sources: [],
            reconciliationID: reconciliationID
        )
        let jobs = JobProbe(
            inventoryResult: .available(
                SessionProcessingJobInventory(
                    reconciliationID: reconciliationID,
                    scope: fixture.selection.scope,
                    jobs: [validating]
                )
            )
        )
        let engine = EngineProbe(result: .failure(.launchFailed))
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: RevisionProbe()),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.activateLibrary(fixture.selection.scope))

        let persisted = await jobs.snapshots
        let sourceLoads = await source.selections
        XCTAssertEqual(persisted.map(\.state), [.interrupted])
        XCTAssertEqual(sourceLoads, [fixture.selection])
    }

    func testLibraryActivationInterruptsValidatingJobWhenSealedSourceIsCorruptOrMismatched()
        async throws
    {
        let fixture = try ProcessingFixture()
        let validating = fixture.job(
            state: .validating,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )
        let otherSelection = SessionProcessingSelection(
            scope: fixture.selection.scope,
            sessionID: try SessionID("ses-20260830T120900000Z-9QRS")
        )
        let mismatchedSource = SessionTranscriptionSource(
            selection: otherSelection,
            audioCapabilityID: fixture.source.audioCapabilityID,
            durationMilliseconds: fixture.source.durationMilliseconds,
            audioFingerprint: fixture.source.audioFingerprint,
            sourceFingerprints: fixture.source.sourceFingerprints,
            expectedSelectedRevisionID: nil
        )
        let cases: [SessionTranscriptionSourceResult] = [
            .integrityMismatch,
            .available(mismatchedSource),
        ]

        for (index, result) in cases.enumerated() {
            let reconciliationID = try SessionProcessingReconciliationID(
                "reconcile-invalid-validating-source-\(index)"
            )
            let source = ReconciliationSourceProbe(
                result: result,
                reconciliationID: reconciliationID
            )
            let jobs = JobProbe(
                inventoryResult: .available(
                    SessionProcessingJobInventory(
                        reconciliationID: reconciliationID,
                        scope: fixture.selection.scope,
                        jobs: [validating]
                    )
                )
            )
            let feature = DefaultSessionProcessingFeature(
                source: source,
                runtime: RuntimeProbe(.qualified(fixture.profile)),
                model: ModelProbe(.ready),
                acoustics: AcousticProbe(fixture.evidence),
                jobs: jobs,
                engine: EngineProbe(result: .failure(.launchFailed)),
                publisher: TranscriptRevisionPublisher(repository: RevisionProbe()),
                clock: FixedProcessingClock(fixture.createdAt),
                identifiers: FixedProcessingIdentifiers(
                    jobID: fixture.jobID,
                    revisionID: fixture.revisionID
                )
            )

            await feature.send(.activateLibrary(fixture.selection.scope))

            let persisted = await jobs.snapshots
            XCTAssertEqual(persisted.map(\.state), [.interrupted])
        }
    }

    func testLibraryActivationValidatesCompletedJobButSkipsOtherTerminalJobs()
        async throws
    {
        let fixture = try ProcessingFixture()
        let completed = fixture.job(
            state: .completed,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )
        let otherTerminalJobs = try [
            SessionProcessingJobState.failed,
            .cancelled,
            .interrupted,
        ].enumerated().map { index, state in
            SessionProcessingJob(
                jobID: try TranscriptionJobID(
                    "job-20260830T120700000Z-\(index)ABC"
                ),
                sessionID: fixture.selection.sessionID,
                revisionID: try TranscriptRevisionID(
                    "trv-20260830T120700000Z-\(index)ABC"
                ),
                profileID: fixture.profile.profileID,
                createdAt: try UTCInstant(
                    "2026-08-30T12:07:0\(index).000Z"
                ),
                state: state,
                cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                    "cancel-terminal-\(index)"
                ),
                failure: state == .failed ? .engineFailed : nil
            )
        }
        let reconciliationID = try SessionProcessingReconciliationID(
            "reconcile-completed-and-terminal"
        )
        let source = ReconciliationSourceProbe(
            sources: [fixture.source],
            reconciliationID: reconciliationID
        )
        let jobs = JobProbe(
            inventoryResult: .available(
                SessionProcessingJobInventory(
                    reconciliationID: reconciliationID,
                    scope: fixture.selection.scope,
                    jobs: [completed] + otherTerminalJobs
                )
            )
        )
        let revisions = RevisionProbe(retained: [try fixture.validatedRevision()])
        let engine = EngineProbe(result: .failure(.launchFailed))
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.activateLibrary(fixture.selection.scope))

        let sourceLoads = await source.selections
        let exactReopens = await revisions.exactReopenCount
        let transitions = await jobs.snapshots
        let presenceCount = await engine.presenceQueryCount()
        let requestCount = await engine.requestCount()
        XCTAssertEqual(sourceLoads, [fixture.selection])
        XCTAssertEqual(exactReopens, 1)
        XCTAssertEqual(transitions, [])
        XCTAssertEqual(presenceCount, 0)
        XCTAssertEqual(requestCount, 0)
        guard case let .unavailable(state) = await feature.currentState else {
            return XCTFail("activation must not replace the Session UI selection")
        }
        XCTAssertEqual(state.reason, .noSession)
    }

    func testLibraryActivationFailsClosedForInvalidCompletedAuthorityWithoutRerun()
        async throws
    {
        let fixture = try ProcessingFixture()
        let validCompleted = fixture.job(
            state: .completed,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )
        let mismatchedProfile = SessionProcessingJob(
            jobID: fixture.jobID,
            sessionID: fixture.selection.sessionID,
            revisionID: fixture.revisionID,
            profileID: "different-qualified-profile-v1",
            createdAt: fixture.createdAt,
            state: .completed,
            cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                "cancel-invalid-completed"
            ),
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )

        for index in 0..<3 {
            let reconciliationID = try SessionProcessingReconciliationID(
                "reconcile-invalid-completed-\(index)"
            )
            let sourceResult: SessionTranscriptionSourceResult = index == 0
                ? .integrityMismatch
                : .available(fixture.source)
            let source = ReconciliationSourceProbe(
                result: sourceResult,
                reconciliationID: reconciliationID
            )
            let job = index == 2 ? mismatchedProfile : validCompleted
            let jobs = JobProbe(
                inventoryResult: .available(
                    SessionProcessingJobInventory(
                        reconciliationID: reconciliationID,
                        scope: fixture.selection.scope,
                        jobs: [job]
                    )
                )
            )
            let revisions = RevisionProbe(
                retained: index == 1 ? [] : [try fixture.validatedRevision()]
            )
            let engine = EngineProbe(result: .failure(.launchFailed))
            let feature = DefaultSessionProcessingFeature(
                source: source,
                runtime: RuntimeProbe(.qualified(fixture.profile)),
                model: ModelProbe(.ready),
                acoustics: AcousticProbe(fixture.evidence),
                jobs: jobs,
                engine: engine,
                publisher: TranscriptRevisionPublisher(repository: revisions),
                clock: FixedProcessingClock(fixture.createdAt),
                identifiers: FixedProcessingIdentifiers(
                    jobID: fixture.jobID,
                    revisionID: fixture.revisionID
                )
            )

            await feature.send(.activateLibrary(fixture.selection.scope))

            let sourceLoads = await source.selections
            let exactReopens = await revisions.exactReopenCount
            let transitions = await jobs.snapshots
            let requestCount = await engine.requestCount()
            let recoveryCount = await engine.recoveryCount()
            let publishCount = await revisions.publishCountValue()
            XCTAssertEqual(sourceLoads, [fixture.selection], "case \(index)")
            XCTAssertEqual(exactReopens, index == 0 ? 0 : 1, "case \(index)")
            XCTAssertEqual(transitions, [], "case \(index)")
            XCTAssertEqual(requestCount, 0, "case \(index)")
            XCTAssertEqual(recoveryCount, 0, "case \(index)")
            XCTAssertEqual(publishCount, 0, "case \(index)")
            guard case let .unavailable(state) = await feature.currentState else {
                XCTFail("activation must keep UI suppressed, case \(index)")
                continue
            }
            XCTAssertEqual(state.reason, .noSession, "case \(index)")

            await feature.send(.selectSession(fixture.selection))
            guard case let .failed(recovery) = await feature.currentState else {
                XCTFail("invalid completed authority must open recovery, case \(index)")
                continue
            }
            XCTAssertEqual(
                recovery.reason,
                .canonicalRevisionIntegrityFailed,
                "case \(index)"
            )
            XCTAssertEqual(recovery.actions, [], "case \(index)")
            await feature.send(.start)
            await feature.send(.retry)
            let requestsAfterCommands = await engine.requestCount()
            let publicationsAfterCommands = await revisions.publishCountValue()
            XCTAssertEqual(requestsAfterCommands, 0, "case \(index)")
            XCTAssertEqual(publicationsAfterCommands, 0, "case \(index)")
        }
    }

    func testRelaunchCompletesExactInstalledValidatingRevisionWithNoSelection()
        async throws
    {
        let fixture = try ProcessingFixture()
        let validating = fixture.job(
            state: .validating,
            expectedSelectedRevisionID: nil,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )
        let jobs = JobProbe(latest: validating)
        let revisions = RevisionProbe(retained: [try fixture.validatedRevision()])
        let engine = EngineProbe(
            result: .failure(.launchFailed),
            recovered: .unavailable
        )
        let feature = fixture.makeFeature(
            jobs: jobs,
            engine: engine,
            revisions: revisions
        )

        await feature.send(.selectSession(fixture.selection))

        guard case let .completed(completed) = await feature.currentState else {
            return XCTFail("expected resumed idempotent publication")
        }
        XCTAssertEqual(completed.revisionID, fixture.revisionID)
        XCTAssertNil(completed.selectedRevisionID)
        let recoveryCount = await engine.recoveryCount()
        let publishCount = await revisions.publishCountValue()
        let exactReopenCount = await revisions.exactReopenCount
        let persistedStates = await jobs.states
        let expectedSelections = await revisions.expectedSelectedRevisionIDs
        XCTAssertEqual(recoveryCount, 0)
        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(exactReopenCount, 1)
        XCTAssertEqual(persistedStates, [.completed])
        XCTAssertEqual(expectedSelections, [])
    }

    func testRelaunchValidationUsesStartBaselineAndRejectsNewerSelection()
        async throws
    {
        let fixture = try ProcessingFixture()
        let newerRevisionID = try TranscriptRevisionID(
            "trv-20260830T120700000Z-7MNP"
        )
        let currentSource = SessionTranscriptionSource(
            selection: fixture.source.selection,
            audioCapabilityID: fixture.source.audioCapabilityID,
            durationMilliseconds: fixture.source.durationMilliseconds,
            audioFingerprint: fixture.source.audioFingerprint,
            sourceFingerprints: fixture.source.sourceFingerprints,
            expectedSelectedRevisionID: newerRevisionID
        )
        let validating = fixture.job(
            state: .validating,
            expectedSelectedRevisionID: nil,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )
        let jobs = JobProbe(latest: validating)
        let revisions = SelectionCASRevisionProbe(selectedRevisionID: newerRevisionID)
        let engine = EngineProbe(
            result: .failure(.launchFailed),
            recovered: .available(
                VerifiedTranscriptionCandidate(
                    candidate: fixture.candidate,
                    artifactFingerprint: fixture.candidateFingerprint
                )
            )
        )
        let feature = DefaultSessionProcessingFeature(
            source: SourceProbe(.available(currentSource)),
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))

        guard case let .failed(failure) = await feature.currentState else {
            return XCTFail("expected stale selection instead of overwrite")
        }
        XCTAssertEqual(failure.reason, .staleSelection)
        let expectedSelections = await revisions.expectedSelectedRevisionIDs
        let selectedRevisionID = await revisions.selectedRevisionID
        XCTAssertEqual(expectedSelections, [nil])
        XCTAssertEqual(selectedRevisionID, newerRevisionID)
        let persistedStates = await jobs.states
        XCTAssertEqual(persistedStates, [.failed])
    }

    func testRelaunchInterruptsValidatingJobWhenStagedCandidateIsCorrupt()
        async throws
    {
        let fixture = try ProcessingFixture()
        let validating = fixture.job(
            state: .validating,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )
        let jobs = JobProbe(latest: validating)
        let revisions = RevisionProbe()
        let engine = EngineProbe(
            result: .failure(.launchFailed),
            recovered: .integrityMismatch
        )
        let feature = fixture.makeFeature(
            jobs: jobs,
            engine: engine,
            revisions: revisions
        )

        await feature.send(.selectSession(fixture.selection))

        guard case let .interrupted(interrupted) = await feature.currentState else {
            return XCTFail("expected corrupt staging to become interruption")
        }
        XCTAssertEqual(interrupted.job.state, .interrupted)
        let publishCount = await revisions.publishCountValue()
        let persistedStates = await jobs.states
        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(persistedStates, [.interrupted])
    }

    func testRelaunchAcceptsCompletedJobOnlyWhenCanonicalRevisionAlsoReopens()
        async throws
    {
        let fixture = try ProcessingFixture(selectedRevisionID: true)
        let completed = fixture.job(
            state: .completed,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )
        let revisions = RevisionProbe(selected: try fixture.validatedRevision())
        let feature = fixture.makeFeature(
            jobs: JobProbe(latest: completed),
            engine: EngineProbe(result: .failure(.launchFailed)),
            revisions: revisions
        )

        await feature.send(.selectSession(fixture.selection))

        guard case let .completed(snapshot) = await feature.currentState else {
            return XCTFail("expected matching canonical completion")
        }
        XCTAssertEqual(snapshot.jobID, fixture.jobID)
        XCTAssertEqual(snapshot.selectedRevisionID, fixture.revisionID)
        let exactReopenCount = await revisions.exactReopenCount
        XCTAssertEqual(exactReopenCount, 1)
    }

    func testSelectedCompletedRevisionDurationMismatchFailsCanonicalIntegrity()
        async throws
    {
        let fixture = try ProcessingFixture(selectedRevisionID: true)
        let completed = fixture.job(
            state: .completed,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )
        let revisions = RevisionProbe(
            selected: try fixture.validatedRevisionWithDuration(3_000)
        )
        let engine = EngineProbe(result: .failure(.launchFailed))
        let feature = fixture.makeFeature(
            jobs: JobProbe(latest: completed),
            engine: engine,
            revisions: revisions
        )

        await feature.send(.selectSession(fixture.selection))

        guard case let .failed(failure) = await feature.currentState else {
            return XCTFail("duration-mismatched completion must fail closed")
        }
        XCTAssertEqual(failure.reason, .canonicalRevisionIntegrityFailed)
        XCTAssertEqual(failure.actions, [])
        await feature.send(.start)
        await feature.send(.retry)
        let requests = await engine.requestCount()
        let publications = await revisions.publishCountValue()
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(publications, 0)
    }

    func testActivationCachesCompletedRevisionDurationMismatchWithoutRerun()
        async throws
    {
        let fixture = try ProcessingFixture()
        let completed = fixture.job(
            state: .completed,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )
        let reconciliationID = try SessionProcessingReconciliationID(
            "reconcile-duration-mismatch"
        )
        let source = ReconciliationSourceProbe(
            result: .available(fixture.source),
            reconciliationID: reconciliationID
        )
        let jobs = JobProbe(
            inventoryResult: .available(
                SessionProcessingJobInventory(
                    reconciliationID: reconciliationID,
                    scope: fixture.selection.scope,
                    jobs: [completed]
                )
            )
        )
        let revisions = RevisionProbe(
            retained: [try fixture.validatedRevisionWithDuration(3_000)]
        )
        let engine = EngineProbe(result: .failure(.launchFailed))
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.activateLibrary(fixture.selection.scope))

        guard case let .unavailable(activationState) = await feature.currentState
        else { return XCTFail("activation must keep UI selection suppressed") }
        XCTAssertEqual(activationState.reason, .noSession)
        let sourceLoads = await source.selections
        let exactReopens = await revisions.exactReopenCount
        XCTAssertEqual(sourceLoads, [fixture.selection])
        XCTAssertEqual(exactReopens, 1)

        await feature.send(.selectSession(fixture.selection))

        guard case let .failed(failure) = await feature.currentState else {
            return XCTFail("selection must open cached canonical recovery")
        }
        XCTAssertEqual(failure.reason, .canonicalRevisionIntegrityFailed)
        XCTAssertEqual(failure.actions, [])
        let requests = await engine.requestCount()
        let publications = await revisions.publishCountValue()
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(publications, 0)
    }

    func testRelaunchRejectsCompletedJobWhoseManifestProvenanceDiffersFromRevision()
        async throws
    {
        let fixture = try ProcessingFixture(selectedRevisionID: true)
        let cancellationAuthorityID = try TranscriptionCancellationAuthorityID(
            "cancel-fixture-authority"
        )
        let mismatchedJobs = [
            SessionProcessingJob(
                jobID: fixture.jobID,
                sessionID: fixture.selection.sessionID,
                revisionID: fixture.revisionID,
                profileID: "different-qualified-profile-v1",
                createdAt: fixture.createdAt,
                state: .completed,
                expectedSelectedRevisionID: nil,
                cancellationAuthorityID: cancellationAuthorityID,
                candidateArtifactSHA256: fixture.candidateFingerprint.sha256
            ),
            SessionProcessingJob(
                jobID: fixture.jobID,
                sessionID: fixture.selection.sessionID,
                revisionID: fixture.revisionID,
                profileID: fixture.profile.profileID,
                createdAt: try UTCInstant("2026-08-30T12:06:01.000Z"),
                state: .completed,
                expectedSelectedRevisionID: nil,
                cancellationAuthorityID: cancellationAuthorityID,
                candidateArtifactSHA256: fixture.candidateFingerprint.sha256
            ),
        ]

        for completed in mismatchedJobs {
            let revisions = RevisionProbe(selected: try fixture.validatedRevision())
            let feature = fixture.makeFeature(
                jobs: JobProbe(latest: completed),
                engine: EngineProbe(result: .failure(.launchFailed)),
                revisions: revisions
            )

            await feature.send(.selectSession(fixture.selection))

            guard case let .failed(failure) = await feature.currentState else {
                XCTFail("expected mismatched completed manifest to fail closed")
                continue
            }
            XCTAssertEqual(failure.reason, .canonicalRevisionIntegrityFailed)
            XCTAssertEqual(failure.actions, [])
            let exactReopenCount = await revisions.exactReopenCount
            XCTAssertEqual(exactReopenCount, 1)
        }
    }

    func testCompletedJobRemainsValidAfterAnotherRevisionIsSelectedAndCanRetranscribe()
        async throws
    {
        let fixture = try ProcessingFixture()
        let completed = fixture.job(
            state: .completed,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )
        let completedRevision = try fixture.validatedRevision()
        let selectedRevisionID = try TranscriptRevisionID(
            "trv-20260830T120700000Z-7MNP"
        )
        let selectedRevision = try TranscriptRevision(
            revisionID: selectedRevisionID,
            sessionID: completedRevision.sessionID,
            jobID: try TranscriptionJobID("job-20260830T120700000Z-7MNP"),
            createdAt: try UTCInstant("2026-08-30T12:07:00.000Z"),
            durationMilliseconds: completedRevision.durationMilliseconds,
            audioFingerprint: completedRevision.audioFingerprint,
            sourceFingerprints: completedRevision.sourceFingerprints,
            candidateArtifactFingerprint: try AudioFingerprint(
                sha256: String(repeating: "7", count: 64)
            ),
            engine: completedRevision.engine,
            lines: completedRevision.lines,
            audioEvents: completedRevision.audioEvents
        )
        let currentSource = SessionTranscriptionSource(
            selection: fixture.source.selection,
            audioCapabilityID: fixture.source.audioCapabilityID,
            durationMilliseconds: fixture.source.durationMilliseconds,
            audioFingerprint: fixture.source.audioFingerprint,
            sourceFingerprints: fixture.source.sourceFingerprints,
            expectedSelectedRevisionID: selectedRevisionID
        )
        let jobs = JobProbe(latest: completed)
        let revisions = RevisionProbe(
            selected: selectedRevision,
            retained: [completedRevision]
        )
        let engine = EngineProbe(result: .failure(.launchFailed))
        let retranscriptionJobID = try TranscriptionJobID(
            "job-20260830T120800000Z-8NPQ"
        )
        let retranscriptionRevisionID = try TranscriptRevisionID(
            "trv-20260830T120800000Z-8NPQ"
        )
        let feature = DefaultSessionProcessingFeature(
            source: SourceProbe(.available(currentSource)),
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: retranscriptionJobID,
                revisionID: retranscriptionRevisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))

        guard case let .completed(reconciled) = await feature.currentState else {
            return XCTFail("expected retained completed Revision to stay valid")
        }
        XCTAssertEqual(reconciled.selectedRevisionID, selectedRevisionID)

        await feature.send(.start)

        let requests = await engine.requests
        let snapshots = await jobs.snapshots
        let selectedAfterStart = await revisions.selected?.revisionID
        let publishCount = await revisions.publishCount
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.jobID, retranscriptionJobID)
        XCTAssertEqual(requests.first?.revisionID, retranscriptionRevisionID)
        XCTAssertNotEqual(requests.first?.jobID, completed.jobID)
        XCTAssertEqual(snapshots.first?.expectedSelectedRevisionID, selectedRevisionID)
        XCTAssertEqual(selectedAfterStart, selectedRevisionID)
        XCTAssertEqual(publishCount, 0)
    }

    func testRelaunchCompletedJobWithMissingCanonicalRevisionIsNotRerunnable()
        async throws
    {
        let fixture = try ProcessingFixture(selectedRevisionID: true)
        let completed = fixture.job(
            state: .completed,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )
        let engine = EngineProbe(result: .failure(.launchFailed))
        let feature = fixture.makeFeature(
            jobs: JobProbe(latest: completed),
            engine: engine
        )

        await feature.send(.selectSession(fixture.selection))

        guard case let .failed(failure) = await feature.currentState else {
            return XCTFail("expected canonical completion recovery error")
        }
        XCTAssertEqual(failure.reason, .canonicalRevisionIntegrityFailed)
        XCTAssertEqual(failure.actions, [])

        await feature.send(.retry)
        await feature.send(.start)

        let requestCount = await engine.requestCount()
        XCTAssertEqual(requestCount, 0)
        guard case let .failed(afterCommands) = await feature.currentState else {
            return XCTFail("expected integrity failure to remain visible")
        }
        XCTAssertEqual(afterCommands.reason, .canonicalRevisionIntegrityFailed)
    }

    func testRepairCommandsCannotRecoverMissingCanonicalRevision() async throws {
        let fixture = try ProcessingFixture(selectedRevisionID: true)
        let completed = fixture.job(
            state: .completed,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )

        for command in [SessionProcessingCommand.prepare, .reinstall] {
            let runtime = RuntimeProbe(.qualified(fixture.profile))
            let engine = EngineProbe(result: .failure(.launchFailed))
            let feature = DefaultSessionProcessingFeature(
                source: SourceProbe(.available(fixture.source)),
                runtime: runtime,
                model: ModelProbe(.ready),
                acoustics: AcousticProbe(fixture.evidence),
                jobs: JobProbe(latest: completed),
                engine: engine,
                publisher: TranscriptRevisionPublisher(repository: RevisionProbe()),
                clock: FixedProcessingClock(fixture.createdAt),
                identifiers: FixedProcessingIdentifiers(
                    jobID: fixture.jobID,
                    revisionID: fixture.revisionID
                )
            )

            await feature.send(.selectSession(fixture.selection))
            await feature.send(command)

            let preparationActions = await runtime.preparationActions
            let requestCount = await engine.requestCount()
            XCTAssertEqual(preparationActions, [], "\(command)")
            XCTAssertEqual(requestCount, 0, "\(command)")
            guard case let .failed(failure) = await feature.currentState else {
                XCTFail("\(command) must preserve the integrity failure")
                continue
            }
            XCTAssertEqual(failure.reason, .canonicalRevisionIntegrityFailed)
            XCTAssertEqual(failure.actions, [])
        }
    }

    func testRetryIsInertWhenReadyDoesNotAdvertiseRetry() async throws {
        let fixture = try ProcessingFixture()
        let source = SourceProbe(.available(fixture.source))
        let jobs = JobProbe()
        let revisions = RevisionProbe()
        let engine = EngineProbe(
            result: .success(
                VerifiedTranscriptionCandidate(
                    candidate: fixture.candidate,
                    artifactFingerprint: fixture.candidateFingerprint
                )
            )
        )
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        let stateBeforeRetry = await feature.currentState
        guard case .ready = stateBeforeRetry else {
            return XCTFail("expected ready before stale Retry")
        }

        await feature.send(.retry)

        let stateAfterRetry = await feature.currentState
        let sourceLoadCount = await source.loadCount
        let persistedStates = await jobs.states
        let engineRequestCount = await engine.requestCount()
        let publishCount = await revisions.publishCountValue()
        let selectedRevisionID = await revisions.selected?.revisionID
        XCTAssertEqual(stateAfterRetry, stateBeforeRetry)
        XCTAssertEqual(sourceLoadCount, 1)
        XCTAssertEqual(persistedStates, [])
        XCTAssertEqual(engineRequestCount, 0)
        XCTAssertEqual(publishCount, 0)
        XCTAssertNil(selectedRevisionID)
    }

    func testRetryIsInertWhenCompletedDoesNotAdvertiseRetry() async throws {
        let fixture = try ProcessingFixture(selectedRevisionID: true)
        let completed = fixture.job(
            state: .completed,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )
        let source = SourceProbe(.available(fixture.source))
        let jobs = JobProbe(latest: completed)
        let revisions = RevisionProbe(selected: try fixture.validatedRevision())
        let engine = EngineProbe(result: .failure(.launchFailed))
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        let stateBeforeRetry = await feature.currentState
        guard case .completed = stateBeforeRetry else {
            return XCTFail("expected completed before stale Retry")
        }
        let selectedBeforeRetry = await revisions.selected?.revisionID

        await feature.send(.retry)

        let stateAfterRetry = await feature.currentState
        let sourceLoadCount = await source.loadCount
        let persistedStates = await jobs.states
        let engineRequestCount = await engine.requestCount()
        let publishCount = await revisions.publishCountValue()
        let selectedAfterRetry = await revisions.selected?.revisionID
        XCTAssertEqual(stateAfterRetry, stateBeforeRetry)
        XCTAssertEqual(sourceLoadCount, 1)
        XCTAssertEqual(persistedStates, [])
        XCTAssertEqual(engineRequestCount, 0)
        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(selectedAfterRetry, selectedBeforeRetry)
    }

    func testRetryStopsWhenRefreshReopensCompletedJob() async throws {
        let fixture = try ProcessingFixture(selectedRevisionID: true)
        let completed = fixture.job(
            state: .completed,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )
        let source = SourceProbe([
            .unavailable,
            .available(fixture.source),
        ])
        let jobs = JobProbe(latest: completed)
        let revisions = RevisionProbe(selected: try fixture.validatedRevision())
        let runtime = RuntimeProbe(.qualified(fixture.profile))
        let engine = EngineProbe(
            result: .success(
                VerifiedTranscriptionCandidate(
                    candidate: fixture.candidate,
                    artifactFingerprint: fixture.candidateFingerprint
                )
            )
        )
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: runtime,
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        guard case let .unavailable(unavailable) = await feature.currentState else {
            return XCTFail("expected retryable source failure before refresh")
        }
        XCTAssertEqual(unavailable.actions, [.retry])

        await feature.send(.retry)

        guard case let .completed(reopened) = await feature.currentState else {
            return XCTFail("expected refreshed durable completion")
        }
        let sourceLoadCount = await source.loadCount
        let persistedStates = await jobs.states
        let engineRequestCount = await engine.requestCount()
        let runtimeResolutionCount = await runtime.resolutionCount
        let publishCount = await revisions.publishCountValue()
        let selectedRevisionID = await revisions.selected?.revisionID
        XCTAssertEqual(reopened.jobID, completed.jobID)
        XCTAssertEqual(sourceLoadCount, 2)
        XCTAssertEqual(persistedStates, [])
        XCTAssertEqual(engineRequestCount, 0)
        XCTAssertEqual(runtimeResolutionCount, 0)
        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(selectedRevisionID, fixture.revisionID)
    }

    func testRetryDoesNotLaunchAfterJobStoreRefreshFailure() async throws {
        let fixture = try ProcessingFixture()
        let loadFailures: [SessionProcessingJobLoadResult] = [
            .integrityMismatch,
            .unavailable,
        ]

        for loadFailure in loadFailures {
            let source = SourceProbe([
                .unavailable,
                .available(fixture.source),
            ])
            let runtime = RuntimeProbe(.qualified(fixture.profile))
            let model = ModelProbe(.ready)
            let jobs = JobProbe(latestResult: loadFailure)
            let revisions = RevisionProbe()
            let engine = EngineProbe(
                result: .success(
                    VerifiedTranscriptionCandidate(
                        candidate: fixture.candidate,
                        artifactFingerprint: fixture.candidateFingerprint
                    )
                )
            )
            let feature = DefaultSessionProcessingFeature(
                source: source,
                runtime: runtime,
                model: model,
                acoustics: AcousticProbe(fixture.evidence),
                jobs: jobs,
                engine: engine,
                publisher: TranscriptRevisionPublisher(repository: revisions),
                clock: FixedProcessingClock(fixture.createdAt),
                identifiers: FixedProcessingIdentifiers(
                    jobID: fixture.jobID,
                    revisionID: fixture.revisionID
                )
            )

            await feature.send(.selectSession(fixture.selection))
            await feature.send(.retry)

            guard case let .failed(failure) = await feature.currentState else {
                XCTFail("expected persistent Job-store failure for \(loadFailure)")
                continue
            }
            let sourceLoadCount = await source.loadCount
            let runtimeResolutionCount = await runtime.resolutionCount
            let modelVerificationCount = await model.verificationCount
            let persistedStates = await jobs.states
            let engineRequestCount = await engine.requestCount()
            let publishCount = await revisions.publishCountValue()
            let selectedRevisionID = await revisions.selected?.revisionID
            XCTAssertNil(failure.job, "\(loadFailure)")
            XCTAssertEqual(failure.reason, .jobPersistenceFailed, "\(loadFailure)")
            XCTAssertEqual(failure.actions, [.retry], "\(loadFailure)")
            XCTAssertEqual(sourceLoadCount, 2, "\(loadFailure)")
            XCTAssertEqual(runtimeResolutionCount, 0, "\(loadFailure)")
            XCTAssertEqual(modelVerificationCount, 0, "\(loadFailure)")
            XCTAssertEqual(persistedStates, [], "\(loadFailure)")
            XCTAssertEqual(engineRequestCount, 0, "\(loadFailure)")
            XCTAssertEqual(publishCount, 0, "\(loadFailure)")
            XCTAssertNil(selectedRevisionID, "\(loadFailure)")
        }
    }

    func testRetryDoesNotLaunchAfterQueuedReconciliationCASFailure() async throws {
        let fixture = try ProcessingFixture()
        let queued = fixture.job(state: .queued)
        let source = SourceProbe([
            .unavailable,
            .available(fixture.source),
        ])
        let runtime = RuntimeProbe(.qualified(fixture.profile))
        let model = ModelProbe(.ready)
        let jobs = JobProbe(
            latest: queued,
            failingTransitionState: .interrupted,
            transitionFailureCount: 1
        )
        let revisions = RevisionProbe()
        let engine = EngineProbe(
            result: .success(
                VerifiedTranscriptionCandidate(
                    candidate: fixture.candidate,
                    artifactFingerprint: fixture.candidateFingerprint
                )
            )
        )
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: runtime,
            model: model,
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        await feature.send(.retry)

        guard case let .failed(failure) = await feature.currentState else {
            return XCTFail("expected failed queued reconciliation")
        }
        let sourceLoadCount = await source.loadCount
        let runtimeResolutionCount = await runtime.resolutionCount
        let modelVerificationCount = await model.verificationCount
        let persistedStates = await jobs.states
        let engineRequestCount = await engine.requestCount()
        let publishCount = await revisions.publishCountValue()
        let selectedRevisionID = await revisions.selected?.revisionID
        XCTAssertEqual(failure.job?.state, .queued)
        XCTAssertEqual(failure.reason, .jobPersistenceFailed)
        XCTAssertEqual(failure.actions, [.retry])
        XCTAssertEqual(sourceLoadCount, 2)
        XCTAssertEqual(runtimeResolutionCount, 0)
        XCTAssertEqual(modelVerificationCount, 0)
        XCTAssertEqual(persistedStates, [.interrupted])
        XCTAssertEqual(engineRequestCount, 0)
        XCTAssertEqual(publishCount, 0)
        XCTAssertNil(selectedRevisionID)
    }

    func testRetryDoesNotLaunchAfterValidationFailureCASIsRejected() async throws {
        let fixture = try ProcessingFixture()
        let validating = fixture.job(
            state: .validating,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )
        let invalidCandidate = fixture.candidate.replacing(sessionID: "ses-wrong")
        let source = SourceProbe(.available(fixture.source))
        let runtime = RuntimeProbe(.qualified(fixture.profile))
        let model = ModelProbe(.ready)
        let jobs = JobProbe(
            latest: validating,
            failingTransitionState: .failed,
            transitionFailureCount: 2
        )
        let revisions = RevisionProbe()
        let engine = EngineProbe(
            result: .failure(.launchFailed),
            recovered: .available(
                VerifiedTranscriptionCandidate(
                    candidate: invalidCandidate,
                    artifactFingerprint: fixture.candidateFingerprint
                )
            )
        )
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: runtime,
            model: model,
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        await feature.send(.retry)

        guard case let .failed(failure) = await feature.currentState else {
            return XCTFail("expected rejected validation-failure CAS")
        }
        let sourceLoadCount = await source.loadCount
        let runtimeResolutionCount = await runtime.resolutionCount
        let modelVerificationCount = await model.verificationCount
        let persistedStates = await jobs.states
        let engineRequestCount = await engine.requestCount()
        let recoveryCount = await engine.recoveryCount()
        let publishCount = await revisions.publishCountValue()
        XCTAssertEqual(failure.job?.state, .validating)
        XCTAssertEqual(failure.reason, .jobPersistenceFailed)
        XCTAssertEqual(failure.actions, [.retry])
        XCTAssertEqual(sourceLoadCount, 2)
        XCTAssertEqual(runtimeResolutionCount, 2)
        XCTAssertEqual(modelVerificationCount, 0)
        XCTAssertEqual(persistedStates, [.failed, .failed])
        XCTAssertEqual(engineRequestCount, 0)
        XCTAssertEqual(recoveryCount, 2)
        XCTAssertEqual(publishCount, 0)
    }

    func testRetryLaunchesAfterDurableRetryableTerminalRefresh() async throws {
        let fixture = try ProcessingFixture()
        let retryableJobs = [
            fixture.job(state: .cancelled),
            fixture.job(state: .interrupted),
            fixture.job(state: .failed, failure: .engineFailed),
        ]

        for retryableJob in retryableJobs {
            let source = SourceProbe(.available(fixture.source))
            let jobs = JobProbe(latest: retryableJob)
            let revisions = RevisionProbe()
            let engine = EngineProbe(
                result: .success(
                    VerifiedTranscriptionCandidate(
                        candidate: fixture.candidate,
                        artifactFingerprint: fixture.candidateFingerprint
                    )
                )
            )
            let feature = DefaultSessionProcessingFeature(
                source: source,
                runtime: RuntimeProbe(.qualified(fixture.profile)),
                model: ModelProbe(.ready),
                acoustics: AcousticProbe(fixture.evidence),
                jobs: jobs,
                engine: engine,
                publisher: TranscriptRevisionPublisher(repository: revisions),
                clock: FixedProcessingClock(fixture.createdAt),
                identifiers: FixedProcessingIdentifiers(
                    jobID: fixture.jobID,
                    revisionID: fixture.revisionID
                )
            )

            await feature.send(.selectSession(fixture.selection))
            await feature.send(.retry)

            guard case .completed = await feature.currentState else {
                XCTFail("expected durable \(retryableJob.state) Retry to launch")
                continue
            }
            let sourceLoadCount = await source.loadCount
            let persistedStates = await jobs.states
            let engineRequestCount = await engine.requestCount()
            let publishCount = await revisions.publishCountValue()
            XCTAssertEqual(sourceLoadCount, 2, "\(retryableJob.state)")
            XCTAssertEqual(
                persistedStates,
                [.queued, .running, .validating, .completed],
                "\(retryableJob.state)"
            )
            XCTAssertEqual(engineRequestCount, 1, "\(retryableJob.state)")
            XCTAssertEqual(publishCount, 1, "\(retryableJob.state)")
        }
    }

    func testRetryRereadsPreviouslyUnavailableSealedSourceBeforeStarting() async throws {
        let fixture = try ProcessingFixture()
        let source = SourceProbe([.unavailable, .available(fixture.source)])
        let engine = EngineProbe(
            result: .success(
                VerifiedTranscriptionCandidate(
                    candidate: fixture.candidate,
                    artifactFingerprint: fixture.candidateFingerprint
                )
            )
        )
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: JobProbe(),
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: RevisionProbe()),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        guard case let .unavailable(unavailable) = await feature.currentState else {
            return XCTFail("expected unavailable source")
        }
        XCTAssertEqual(unavailable.actions, [.retry])

        await feature.send(.retry)

        guard case .completed = await feature.currentState else {
            return XCTFail("expected Retry to reread source and complete")
        }
        let sourceLoadCount = await source.loadCount
        let engineRequestCount = await engine.requests.count
        XCTAssertEqual(sourceLoadCount, 2)
        XCTAssertEqual(engineRequestCount, 1)
    }

    func testNoSessionDoesNotAdvertiseANoOpRecoveryAction() async throws {
        let fixture = try ProcessingFixture()
        let source = SourceProbe(.available(fixture.source))
        let runtime = RuntimeProbe(.qualified(fixture.profile))
        let model = ModelProbe(.ready)
        let jobs = JobProbe()
        let revisions = RevisionProbe()
        let engine = EngineProbe(result: .failure(.launchFailed))
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: runtime,
            model: model,
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        guard case let .unavailable(unavailable) = await feature.currentState else {
            return XCTFail("expected no Session state")
        }
        XCTAssertEqual(unavailable.reason, .noSession)
        XCTAssertEqual(unavailable.actions, [])

        let stateBeforeStart = await feature.currentState
        await feature.send(.start)

        let stateAfterStart = await feature.currentState
        let sourceLoadCount = await source.loadCount
        let runtimeResolutionCount = await runtime.resolutionCount
        let modelVerificationCount = await model.verificationCount
        let persistedStates = await jobs.states
        let engineRequestCount = await engine.requestCount()
        let publishCount = await revisions.publishCountValue()
        XCTAssertEqual(stateAfterStart, stateBeforeStart)
        XCTAssertEqual(sourceLoadCount, 0)
        XCTAssertEqual(runtimeResolutionCount, 0)
        XCTAssertEqual(modelVerificationCount, 0)
        XCTAssertEqual(persistedStates, [])
        XCTAssertEqual(engineRequestCount, 0)
        XCTAssertEqual(publishCount, 0)
    }

    func testLatestSelectionIsReplayedWhenPreviousSourceLoadIsSuspended() async throws {
        let fixture = try ProcessingFixture()
        let secondSelection = SessionProcessingSelection(
            scope: fixture.selection.scope,
            sessionID: try SessionID("ses-20260830T120200000Z-3DEF")
        )
        let secondSource = SessionTranscriptionSource(
            selection: secondSelection,
            audioCapabilityID: try SessionTranscriptionAudioCapabilityID(
                "cap-second-synthetic-source"
            ),
            durationMilliseconds: fixture.source.durationMilliseconds,
            audioFingerprint: fixture.source.audioFingerprint,
            sourceFingerprints: fixture.source.sourceFingerprints,
            expectedSelectedRevisionID: nil
        )
        let source = SuspendedSelectionSourceProbe(
            first: fixture.source,
            second: secondSource
        )
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: JobProbe(),
            engine: EngineProbe(result: .failure(.launchFailed)),
            publisher: TranscriptRevisionPublisher(repository: RevisionProbe()),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        let first = Task { await feature.send(.selectSession(fixture.selection)) }
        await source.waitUntilFirstLoadStarts()
        await feature.send(.selectSession(secondSelection))
        await source.releaseFirstLoad()
        await first.value

        guard case let .ready(ready) = await feature.currentState else {
            return XCTFail("expected the newest Session selection")
        }
        XCTAssertEqual(ready.source.selection, secondSelection)
        let selections = await source.selections
        XCTAssertEqual(selections, [fixture.selection, secondSelection])
    }

    func testInstalledNeedsRefreshKeepsValidatingAndExactReopenCompletesOriginalJob()
        async throws
    {
        let fixture = try ProcessingFixture()
        let newerRevisionID = try TranscriptRevisionID(
            "trv-20260830T120700000Z-7MNP"
        )
        let installedRevision = try fixture.validatedRevision()
        let newerRevision = try TranscriptRevision(
            revisionID: newerRevisionID,
            sessionID: installedRevision.sessionID,
            jobID: try TranscriptionJobID("job-20260830T120700000Z-7MNP"),
            createdAt: try UTCInstant("2026-08-30T12:07:00.000Z"),
            durationMilliseconds: installedRevision.durationMilliseconds,
            audioFingerprint: installedRevision.audioFingerprint,
            sourceFingerprints: installedRevision.sourceFingerprints,
            candidateArtifactFingerprint: try AudioFingerprint(
                sha256: String(repeating: "7", count: 64)
            ),
            engine: installedRevision.engine,
            lines: installedRevision.lines,
            audioEvents: installedRevision.audioEvents
        )
        let refreshedSource = SessionTranscriptionSource(
            selection: fixture.selection,
            audioCapabilityID: fixture.source.audioCapabilityID,
            durationMilliseconds: fixture.source.durationMilliseconds,
            audioFingerprint: fixture.source.audioFingerprint,
            sourceFingerprints: fixture.source.sourceFingerprints,
            expectedSelectedRevisionID: newerRevisionID
        )
        let source = SourceProbe([
            .available(fixture.source),
            .available(refreshedSource),
        ])
        let jobs = JobProbe(tracksLatestWrites: true)
        let revisions = InstalledNeedsRefreshRevisionProbe()
        let engine = EngineProbe(
            result: .success(
                VerifiedTranscriptionCandidate(
                    candidate: fixture.candidate,
                    artifactFingerprint: fixture.candidateFingerprint
                )
            )
        )
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        await feature.send(.start)
        guard case let .recoveryRequired(authoritative) = await feature.currentState else {
            return XCTFail("expected validating recovery authority after install")
        }
        XCTAssertEqual(authoritative.state, .validating)
        XCTAssertEqual(authoritative.jobID, fixture.jobID)

        // Recovery authority is not a retranscription affordance. A stale or
        // programmatic Retry must remain inert until a fresh sealed-source read.
        await feature.send(.retry)
        let loadCountAfterRetry = await source.loadCount
        let requestCountAfterRetry = await engine.requestCount()
        XCTAssertEqual(loadCountAfterRetry, 1)
        XCTAssertEqual(requestCountAfterRetry, 1)

        // A later review may select another retained Revision before relaunch.
        // Recovery must complete this exact installed Job without republishing
        // against its stale start-time selection baseline.
        await revisions.select(newerRevision)
        await feature.send(.selectSession(fixture.selection))

        guard case let .completed(completed) = await feature.currentState else {
            return XCTFail("expected exact installed Revision reopen to complete the Job")
        }
        XCTAssertEqual(completed.revisionID, fixture.revisionID)
        XCTAssertEqual(completed.selectedRevisionID, newerRevisionID)
        let loadCount = await source.loadCount
        let publishCount = await revisions.publishCount
        let exactReopenCount = await revisions.exactReopenCount
        let selectedReopenCount = await revisions.selectedReopenCount
        let persistedStates = await jobs.states
        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(exactReopenCount, 1)
        XCTAssertEqual(selectedReopenCount, 0)
        XCTAssertEqual(
            persistedStates,
            [.queued, .running, .validating, .completed]
        )
    }

    func testLatestSelectionIsReplayedAfterCurrentEngineRunFinishes() async throws {
        let fixture = try ProcessingFixture()
        let secondSelection = SessionProcessingSelection(
            scope: fixture.selection.scope,
            sessionID: try SessionID("ses-20260830T120200000Z-3DEF")
        )
        let secondSource = SessionTranscriptionSource(
            selection: secondSelection,
            audioCapabilityID: try SessionTranscriptionAudioCapabilityID(
                "cap-second-synthetic-source"
            ),
            durationMilliseconds: fixture.source.durationMilliseconds,
            audioFingerprint: fixture.source.audioFingerprint,
            sourceFingerprints: fixture.source.sourceFingerprints,
            expectedSelectedRevisionID: nil
        )
        let source = SourceProbe([
            .available(fixture.source),
            .available(secondSource),
        ])
        let engine = SuspendedEngineProbe(
            result: VerifiedTranscriptionCandidate(
                candidate: fixture.candidate,
                artifactFingerprint: fixture.candidateFingerprint
            )
        )
        let feature = DefaultSessionProcessingFeature(
            source: source,
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: JobProbe(),
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: RevisionProbe()),
            clock: FixedProcessingClock(fixture.createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        let run = Task { await feature.send(.start) }
        await engine.waitUntilTranscriptionStarts()
        await feature.send(.selectSession(secondSelection))
        await engine.releaseTranscription()
        await run.value

        guard case let .ready(ready) = await feature.currentState else {
            return XCTFail("expected the queued Session selection after the run")
        }
        XCTAssertEqual(ready.source.selection, secondSelection)
        let loadCount = await source.loadCount
        XCTAssertEqual(loadCount, 2)
    }

    func testFailureCASWinsCancelRaceForEngineThrowAndCandidateHashRejection()
        async throws
    {
        for reason in [
            SessionProcessingFailureReason.engineFailed,
            .candidateRejected,
        ] {
            try await assertFailureCancelRace(reason: reason, order: .failureWins)
        }
    }

    func testCancellationCASWinsRaceAgainstEngineThrowAndCandidateHashRejection()
        async throws
    {
        for reason in [
            SessionProcessingFailureReason.engineFailed,
            .candidateRejected,
        ] {
            try await assertFailureCancelRace(reason: reason, order: .cancellationWins)
        }
    }

    private func assertFailureCancelRace(
        reason: SessionProcessingFailureReason,
        order: FailureCancellationRaceOrder
    ) async throws {
        let fixture = try ProcessingFixture()
        let newerJob = SessionProcessingJob(
            jobID: try TranscriptionJobID("job-20260830T120700000Z-7MNP"),
            sessionID: fixture.selection.sessionID,
            revisionID: try TranscriptRevisionID(
                "trv-20260830T120700000Z-7MNP"
            ),
            profileID: fixture.profile.profileID,
            createdAt: try UTCInstant("2026-08-30T12:07:00.000Z"),
            state: .running,
            expectedSelectedRevisionID: nil,
            cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                "cancel-newer-failure-race"
            )
        )
        let jobs = FailureCancellationRaceJobProbe(
            order: order,
            newerLatest: newerJob
        )
        let engineResult: Result<
            VerifiedTranscriptionCandidate,
            TranscriptionEngineFailure
        >
        switch reason {
        case .engineFailed:
            engineResult = .failure(.launchFailed)
        case .candidateRejected:
            engineResult = .success(
                VerifiedTranscriptionCandidate(
                    candidate: fixture.candidate,
                    artifactFingerprint: try AudioFingerprint(
                        sha256: String(repeating: "9", count: 64)
                    )
                )
            )
        default:
            return XCTFail("unsupported race failure reason")
        }
        let engine = FailureCancellationRaceEngineProbe(result: engineResult)
        let revisions = RevisionProbe()
        let feature = DefaultSessionProcessingFeature(
            source: SourceProbe(.available(fixture.source)),
            runtime: RuntimeProbe(.qualified(fixture.profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(fixture.evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: SequencedProcessingClock([
                fixture.createdAt,
                try UTCInstant("2026-08-30T12:08:00.000Z"),
            ]),
            identifiers: FixedProcessingIdentifiers(
                jobID: fixture.jobID,
                revisionID: fixture.revisionID
            )
        )

        await feature.send(.selectSession(fixture.selection))
        let run = Task { await feature.send(.start) }
        await engine.waitUntilTranscriptionStarts()
        await engine.releaseTranscription()
        await jobs.waitUntilFailureAttemptStarts()

        let cancellation = Task { await feature.send(.cancel) }
        switch order {
        case .failureWins:
            await jobs.waitUntilCancellationCASLoses()
            await cancellation.value
            guard case let .failed(snapshot) = await feature.currentState else {
                return XCTFail("durable failure must remain the first accepted outcome")
            }
            XCTAssertEqual(snapshot.reason, reason)
            XCTAssertEqual(snapshot.actions, [.retry])
            XCTAssertEqual(snapshot.job?.jobID, fixture.jobID)
            let cancellationCount = await engine.cancellationCount
            XCTAssertEqual(cancellationCount, 0)
        case .cancellationWins:
            await cancellation.value
            guard case let .cancelled(snapshot) = await feature.currentState else {
                return XCTFail("durable cancellation must remain the first outcome")
            }
            XCTAssertEqual(snapshot.job.jobID, fixture.jobID)
            XCTAssertEqual(snapshot.actions, [.retry])
            let cancellationCount = await engine.cancellationCount
            XCTAssertEqual(cancellationCount, 1)
        }

        await jobs.releaseFailureWrite()
        await run.value

        switch order {
        case .failureWins:
            guard case let .failed(snapshot) = await feature.currentState else {
                return XCTFail("late failure CAS response must preserve failure")
            }
            XCTAssertEqual(snapshot.reason, reason)
            XCTAssertEqual(snapshot.actions, [.retry])
        case .cancellationWins:
            guard case .cancelled = await feature.currentState else {
                return XCTFail("late stale failure CAS must not emit persistence failure")
            }
        }
        let publishCount = await revisions.publishCountValue()
        XCTAssertEqual(publishCount, 0)
    }
}

private enum FailureCancellationRaceOrder {
    case failureWins
    case cancellationWins
}

private struct ProcessingFixture {
    let selection: SessionProcessingSelection
    let source: SessionTranscriptionSource
    let evidence: SessionVoicedRangeEvidence
    let profile: QualifiedTranscriptionProfile
    let jobID: TranscriptionJobID
    let revisionID: TranscriptRevisionID
    let createdAt: UTCInstant
    let candidateFingerprint: AudioFingerprint
    let candidate: TranscriptionCandidate

    init(selectedRevisionID: Bool = false) throws {
        let scope = LibraryScope(libraryID: try LibraryID("lib-20260830T120000000Z-1ABC"))
        let sessionID = try SessionID("ses-20260830T120100000Z-2CDE")
        let sourceID = try AudioSourceID("src-0001")
        let audioFingerprint = try AudioFingerprint(
            sha256: String(repeating: "1", count: 64)
        )
        let sourceFingerprint = TranscriptSourceFingerprint(
            audioSourceID: sourceID,
            fingerprint: audioFingerprint
        )
        let policy = try EngineUsePolicy(
            policyID: "crisper-evaluation-v1",
            coveredArtifacts: [.transcriptRevision],
            privateLocalUseAllowed: true,
            privateExportAllowed: true,
            externalProcessingAllowed: false,
            publicDistributionAllowed: false,
            commercialUseAllowed: false,
            licenseReference: "https://example.invalid/pinned-license",
            licenseSHA256: String(repeating: "2", count: 64)
        )
        let qualification = try TranscriptEngineQualification(
            qualificationProfileID: "synthetic-qualified-v1",
            engineLockSHA256: String(repeating: "6", count: 64),
            runtimeIdentity: "synthetic-runtime-v1",
            runtimeLockSHA256: String(repeating: "4", count: 64),
            compatibilityPatchID: "synthetic-progress-patch-v1"
        )
        let provenance = try TranscriptEngineProvenance(
            provider: "crisperwhisper",
            model: "small",
            revision: "model-revision-v1",
            language: "en",
            mode: "verbatim",
            decodingOptionsSHA256: String(repeating: "3", count: 64),
            qualification: qualification,
            usePolicy: policy
        )
        profile = try QualifiedTranscriptionProfile(
            profileID: "synthetic-qualified-v1",
            protocolVersion: 1,
            runtimeVersion: "synthetic-runtime-v1",
            packageLockSHA256: String(repeating: "4", count: 64),
            modelRevision: "model-revision-v1",
            compatibilityPatchID: "synthetic-progress-patch-v1",
            engine: provenance
        )
        jobID = try TranscriptionJobID("job-20260830T120500000Z-5GHJ")
        revisionID = try TranscriptRevisionID("trv-20260830T120600000Z-6JKM")
        createdAt = try UTCInstant("2026-08-30T12:06:00.000Z")
        candidateFingerprint = try AudioFingerprint(
            sha256: String(repeating: "5", count: 64)
        )
        selection = SessionProcessingSelection(scope: scope, sessionID: sessionID)
        source = SessionTranscriptionSource(
            selection: selection,
            audioCapabilityID: try SessionTranscriptionAudioCapabilityID(
                "cap-synthetic-source"
            ),
            durationMilliseconds: 2_000,
            audioFingerprint: audioFingerprint,
            sourceFingerprints: [sourceFingerprint],
            expectedSelectedRevisionID: selectedRevisionID ? revisionID : nil
        )
        evidence = SessionVoicedRangeEvidence(
            qualificationProfileID: profile.profileID,
            extractorID: "synthetic-vad-v1",
            audioFingerprint: audioFingerprint,
            voicedRanges: [
                try SessionTimeRange(
                    startMilliseconds: 0,
                    endMilliseconds: 2_000,
                    sessionDurationMilliseconds: 2_000
                ),
            ]
        )
        candidate = TranscriptionCandidate(
            schemaVersion: 1,
            jobID: jobID.rawValue,
            sessionID: sessionID.rawValue,
            revisionID: revisionID.rawValue,
            durationMilliseconds: 2_000,
            audioFingerprintSHA256: audioFingerprint.sha256,
            sourceFingerprints: [
                CandidateTranscriptSourceFingerprint(
                    audioSourceID: sourceID.rawValue,
                    sha256: audioFingerprint.sha256
                ),
            ],
            candidateArtifactSHA256: candidateFingerprint.sha256,
            engine: CandidateTranscriptEngineProvenance(
                provider: provenance.provider,
                model: provenance.model,
                revision: provenance.revision,
                language: provenance.language,
                mode: provenance.mode,
                decodingOptionsSHA256: provenance.decodingOptionsSHA256,
                qualification: CandidateTranscriptEngineQualification(
                    schemaVersion: TranscriptEngineQualification.schemaVersion,
                    qualificationProfileID: qualification.qualificationProfileID,
                    engineLockSHA256: qualification.engineLockSHA256,
                    runtimeIdentity: qualification.runtimeIdentity,
                    runtimeLockSHA256: qualification.runtimeLockSHA256,
                    compatibilityPatchID: qualification.compatibilityPatchID
                )
            ),
            lines: [
                CandidateTranscriptLine(
                    lineID: "l000000",
                    order: 0,
                    audioSourceID: sourceID.rawValue,
                    timeRange: CandidateSessionTimeRange(
                        startMilliseconds: 0,
                        endMilliseconds: 2_000
                    ),
                    text: "Hello world.",
                    words: [
                        CandidateTranscriptWord(
                            wordID: "w000000",
                            ordinal: 0,
                            text: "Hello",
                            displayRange: CandidateLineTextRange(
                                startUTF8Byte: 0,
                                endUTF8Byte: 5
                            ),
                            timeRange: CandidateSessionTimeRange(
                                startMilliseconds: 0,
                                endMilliseconds: 800
                            ),
                            confidence: 0.99,
                            wordKind: .lexical
                        ),
                        CandidateTranscriptWord(
                            wordID: "w000001",
                            ordinal: 1,
                            text: "world",
                            displayRange: CandidateLineTextRange(
                                startUTF8Byte: 6,
                                endUTF8Byte: 11
                            ),
                            timeRange: CandidateSessionTimeRange(
                                startMilliseconds: 900,
                                endMilliseconds: 1_800
                            ),
                            confidence: 0.98,
                            wordKind: .lexical
                        ),
                    ]
                ),
            ],
            audioEvents: []
        )
    }

    func job(
        state: SessionProcessingJobState,
        expectedSelectedRevisionID: TranscriptRevisionID? = nil,
        candidateArtifactSHA256: String? = nil,
        failure: SessionProcessingFailureReason? = nil
    ) -> SessionProcessingJob {
        SessionProcessingJob(
            jobID: jobID,
            sessionID: selection.sessionID,
            revisionID: revisionID,
            profileID: profile.profileID,
            createdAt: createdAt,
            state: state,
            expectedSelectedRevisionID: expectedSelectedRevisionID,
            cancellationAuthorityID: try! TranscriptionCancellationAuthorityID(
                "cancel-fixture-authority"
            ),
            candidateArtifactSHA256: candidateArtifactSHA256,
            failure: failure
        )
    }

    func makeFeature(
        jobs: JobProbe,
        engine: EngineProbe,
        revisions: RevisionProbe = RevisionProbe()
    ) -> DefaultSessionProcessingFeature {
        DefaultSessionProcessingFeature(
            source: SourceProbe(.available(source)),
            runtime: RuntimeProbe(.qualified(profile)),
            model: ModelProbe(.ready),
            acoustics: AcousticProbe(evidence),
            jobs: jobs,
            engine: engine,
            publisher: TranscriptRevisionPublisher(repository: revisions),
            clock: FixedProcessingClock(createdAt),
            identifiers: FixedProcessingIdentifiers(
                jobID: jobID,
                revisionID: revisionID
            )
        )
    }

    func validatedRevision() throws -> TranscriptRevision {
        try TranscriptCandidateValidator().validate(
            candidate,
            against: TranscriptPublicationContext(
                jobID: jobID,
                sessionID: selection.sessionID,
                revisionID: revisionID,
                createdAt: createdAt,
                durationMilliseconds: source.durationMilliseconds,
                audioFingerprint: source.audioFingerprint,
                sourceFingerprints: source.sourceFingerprints,
                verifiedCandidateArtifactFingerprint: candidateFingerprint,
                engine: profile.engine,
                voicedRanges: evidence.voicedRanges
            )
        )
    }

    func validatedRevisionWithDuration(
        _ durationMilliseconds: UInt64
    ) throws -> TranscriptRevision {
        let revision = try validatedRevision()
        return try TranscriptRevision(
            revisionID: revision.revisionID,
            sessionID: revision.sessionID,
            jobID: revision.jobID,
            createdAt: revision.createdAt,
            durationMilliseconds: durationMilliseconds,
            audioFingerprint: revision.audioFingerprint,
            sourceFingerprints: revision.sourceFingerprints,
            candidateArtifactFingerprint: revision.candidateArtifactFingerprint,
            engine: revision.engine,
            lines: revision.lines,
            audioEvents: revision.audioEvents
        )
    }
}

private actor RuntimeProbe: TranscriptionRuntimePort {
    private let resolution: TranscriptionRuntimeResolution
    private(set) var preparationActions: [SessionProcessingRecoveryAction] = []
    private(set) var resolutionCount = 0

    init(_ resolution: TranscriptionRuntimeResolution) {
        self.resolution = resolution
    }

    func resolve() async -> TranscriptionRuntimeResolution {
        resolutionCount += 1
        return resolution
    }

    func prepare(_ action: SessionProcessingRecoveryAction) async
        -> TranscriptionRuntimeResolution
    {
        preparationActions.append(action)
        return resolution
    }

    func executionCapability(
        for profile: QualifiedTranscriptionProfile
    ) async -> VerifiedTranscriptionRuntime? {
        guard case .qualified = resolution else { return nil }
        return VerifiedTranscriptionRuntime(
            capabilityID: try! TranscriptionRuntimeCapabilityID(
                "runtime-synthetic-capability"
            ),
            profileID: profile.profileID,
            runtimeIdentity: profile.runtimeVersion
        )
    }
}

private actor ModelProbe: TranscriptionModelPort {
    private var resolution: TranscriptionModelResolution
    private let preparation: TranscriptionModelResolution
    private(set) var verificationCount = 0
    private(set) var preparationActions: [SessionProcessingRecoveryAction] = []

    init(
        _ resolution: TranscriptionModelResolution,
        preparation: TranscriptionModelResolution? = nil
    ) {
        self.resolution = resolution
        self.preparation = preparation ?? resolution
    }

    func verify(_ profile: QualifiedTranscriptionProfile) async
        -> TranscriptionModelResolution
    {
        verificationCount += 1
        return resolution
    }

    func prepare(
        _ action: SessionProcessingRecoveryAction,
        profile: QualifiedTranscriptionProfile
    ) async -> TranscriptionModelResolution {
        preparationActions.append(action)
        resolution = preparation
        return resolution
    }

    func executionCapability(
        for profile: QualifiedTranscriptionProfile
    ) async -> VerifiedTranscriptionModel? {
        guard resolution == .ready else { return nil }
        return VerifiedTranscriptionModel(
            capabilityID: try! TranscriptionModelCapabilityID(
                "model-synthetic-capability"
            ),
            profileID: profile.profileID,
            modelRevision: profile.modelRevision
        )
    }
}

private actor AcousticProbe: SessionAcousticEvidencePort {
    private let evidence: SessionVoicedRangeEvidence

    init(_ evidence: SessionVoicedRangeEvidence) {
        self.evidence = evidence
    }

    func resolve(
        for source: SessionTranscriptionSource,
        profile: QualifiedTranscriptionProfile
    ) async -> SessionAcousticEvidenceResolution {
        .qualified(evidence)
    }
}

private actor ActivationTransitionProbe: SessionProcessingJobPort {
    private let scope: LibraryScope
    private let reconciliationID: SessionProcessingReconciliationID
    private let inventoried: SessionProcessingJob
    private let transitionResult: SessionProcessingJobWriteResult
    private let exactLoadResult: SessionProcessingJobLoadResult
    private(set) var exactLoadCount = 0
    private(set) var latestLoadCount = 0
    private(set) var finishedReconciliationIDs: [SessionProcessingReconciliationID]
        = []

    init(
        scope: LibraryScope,
        reconciliationID: SessionProcessingReconciliationID,
        inventoried: SessionProcessingJob,
        transitionResult: SessionProcessingJobWriteResult,
        exactLoadResult: SessionProcessingJobLoadResult
    ) {
        self.scope = scope
        self.reconciliationID = reconciliationID
        self.inventoried = inventoried
        self.transitionResult = transitionResult
        self.exactLoadResult = exactLoadResult
    }

    func inventory(
        for scope: LibraryScope
    ) async -> SessionProcessingJobInventoryResult {
        guard scope == self.scope else { return .unavailable }
        return .available(
            SessionProcessingJobInventory(
                reconciliationID: reconciliationID,
                scope: scope,
                jobs: [inventoried]
            )
        )
    }

    func finishReconciliation(
        _ reconciliationID: SessionProcessingReconciliationID
    ) async {
        finishedReconciliationIDs.append(reconciliationID)
    }

    func latest(for selection: SessionProcessingSelection) async
        -> SessionProcessingJobLoadResult
    {
        latestLoadCount += 1
        return .loaded(inventoried)
    }

    func load(
        jobID: TranscriptionJobID,
        for selection: SessionProcessingSelection
    ) async -> SessionProcessingJobLoadResult {
        exactLoadCount += 1
        guard jobID == inventoried.jobID,
              selection.scope == scope,
              selection.sessionID == inventoried.sessionID
        else { return .none }
        return exactLoadResult
    }

    func create(_ job: SessionProcessingJob) async -> SessionProcessingJobWriteResult {
        .failed
    }

    func transition(
        _ job: SessionProcessingJob,
        from expected: SessionProcessingJobState
    ) async -> SessionProcessingJobWriteResult {
        transitionResult
    }
}

private actor ActivationWinnerProbe: SessionProcessingJobPort {
    private let scope: LibraryScope
    private let reconciliationID: SessionProcessingReconciliationID
    private let inventoried: SessionProcessingJob
    private let firstWinner: SessionProcessingJob
    private(set) var transitionCount = 0
    private(set) var exactLoadCount = 0
    private(set) var currentJob: SessionProcessingJob?
    private(set) var finishedReconciliationIDs: [SessionProcessingReconciliationID]
        = []

    init(
        scope: LibraryScope,
        reconciliationID: SessionProcessingReconciliationID,
        inventoried: SessionProcessingJob,
        firstWinner: SessionProcessingJob
    ) {
        self.scope = scope
        self.reconciliationID = reconciliationID
        self.inventoried = inventoried
        self.firstWinner = firstWinner
        currentJob = inventoried
    }

    func inventory(
        for scope: LibraryScope
    ) async -> SessionProcessingJobInventoryResult {
        guard scope == self.scope else { return .unavailable }
        return .available(
            SessionProcessingJobInventory(
                reconciliationID: reconciliationID,
                scope: scope,
                jobs: [inventoried]
            )
        )
    }

    func finishReconciliation(
        _ reconciliationID: SessionProcessingReconciliationID
    ) async {
        finishedReconciliationIDs.append(reconciliationID)
    }

    func latest(for selection: SessionProcessingSelection) async
        -> SessionProcessingJobLoadResult
    {
        currentJob.map(SessionProcessingJobLoadResult.loaded) ?? .none
    }

    func load(
        jobID: TranscriptionJobID,
        for selection: SessionProcessingSelection
    ) async -> SessionProcessingJobLoadResult {
        exactLoadCount += 1
        guard jobID == inventoried.jobID,
              selection.scope == scope,
              selection.sessionID == inventoried.sessionID,
              let currentJob
        else { return .none }
        return .loaded(currentJob)
    }

    func create(_ job: SessionProcessingJob) async -> SessionProcessingJobWriteResult {
        .failed
    }

    func transition(
        _ job: SessionProcessingJob,
        from expected: SessionProcessingJobState
    ) async -> SessionProcessingJobWriteResult {
        transitionCount += 1
        if transitionCount == 1 {
            currentJob = firstWinner
            return .stale
        }
        currentJob = job
        return .written(job)
    }
}

private actor JobProbe: SessionProcessingJobPort {
    private let latestResult: SessionProcessingJobLoadResult
    private let inventoryResult: SessionProcessingJobInventoryResult
    private let tracksLatestWrites: Bool
    private let failingTransitionState: SessionProcessingJobState?
    private var remainingTransitionFailures: Int
    private var remainingCancellationRequestFailures: Int
    private var durableLatest: SessionProcessingJob?
    private(set) var states: [SessionProcessingJobState] = []
    private(set) var snapshots: [SessionProcessingJob] = []
    private(set) var finishedReconciliationIDs: [SessionProcessingReconciliationID]
        = []

    init(
        latest: SessionProcessingJob? = nil,
        latestResult: SessionProcessingJobLoadResult? = nil,
        inventoryResult: SessionProcessingJobInventoryResult = .unavailable,
        tracksLatestWrites: Bool = false,
        failingTransitionState: SessionProcessingJobState? = nil,
        transitionFailureCount: Int = 0,
        failingCancellationRequestCount: Int = 0
    ) {
        self.latestResult = latestResult ?? latest.map {
            SessionProcessingJobLoadResult.loaded($0)
        } ?? .none
        self.inventoryResult = inventoryResult
        self.tracksLatestWrites = tracksLatestWrites
        durableLatest = latest
        self.failingTransitionState = failingTransitionState
        remainingTransitionFailures = transitionFailureCount
        remainingCancellationRequestFailures = failingCancellationRequestCount
    }

    func inventory(
        for scope: LibraryScope
    ) async -> SessionProcessingJobInventoryResult {
        inventoryResult
    }

    func finishReconciliation(
        _ reconciliationID: SessionProcessingReconciliationID
    ) async {
        finishedReconciliationIDs.append(reconciliationID)
    }

    func latest(for selection: SessionProcessingSelection) async
        -> SessionProcessingJobLoadResult
    {
        if tracksLatestWrites {
            return durableLatest.map(SessionProcessingJobLoadResult.loaded) ?? .none
        }
        return latestResult
    }

    func load(
        jobID: TranscriptionJobID,
        for selection: SessionProcessingSelection
    ) async -> SessionProcessingJobLoadResult {
        let result = tracksLatestWrites
            ? durableLatest.map(SessionProcessingJobLoadResult.loaded) ?? .none
            : latestResult
        guard case let .loaded(job) = result else { return result }
        return job.jobID == jobID && job.sessionID == selection.sessionID
            ? .loaded(job)
            : .none
    }

    func create(_ job: SessionProcessingJob) async -> SessionProcessingJobWriteResult {
        states.append(job.state)
        snapshots.append(job)
        if tracksLatestWrites { durableLatest = job }
        return .written(job)
    }

    func transition(
        _ job: SessionProcessingJob,
        from expected: SessionProcessingJobState
    ) async -> SessionProcessingJobWriteResult {
        states.append(job.state)
        snapshots.append(job)
        if job.state == .running, job.cancellationRequestedAt != nil,
           remainingCancellationRequestFailures > 0
        {
            remainingCancellationRequestFailures -= 1
            return .failed
        }
        if job.state == failingTransitionState, remainingTransitionFailures > 0 {
            remainingTransitionFailures -= 1
            return .failed
        }
        if tracksLatestWrites { durableLatest = job }
        return .written(job)
    }
}

private actor CandidateWinsCancellationJobProbe: SessionProcessingJobPort {
    private var durable: SessionProcessingJob?
    private let newerLatest: SessionProcessingJob?
    private var validatingWriteContinuation: CheckedContinuation<Void, Never>?
    private var validatingIsDurable = false
    private var cancellationCASLost = false

    init(newerLatest: SessionProcessingJob? = nil) {
        self.newerLatest = newerLatest
    }

    var currentState: SessionProcessingJobState? { durable?.state }

    func latest(for selection: SessionProcessingSelection) async
        -> SessionProcessingJobLoadResult
    {
        if validatingIsDurable, let newerLatest { return .loaded(newerLatest) }
        return durable.map(SessionProcessingJobLoadResult.loaded) ?? .none
    }

    func load(
        jobID: TranscriptionJobID,
        for selection: SessionProcessingSelection
    ) async -> SessionProcessingJobLoadResult {
        guard let durable, durable.jobID == jobID,
              durable.sessionID == selection.sessionID
        else { return .none }
        return .loaded(durable)
    }

    func create(_ job: SessionProcessingJob) async -> SessionProcessingJobWriteResult {
        guard durable == nil, job.state == .queued else { return .collision }
        durable = job
        return .written(job)
    }

    func transition(
        _ job: SessionProcessingJob,
        from expected: SessionProcessingJobState
    ) async -> SessionProcessingJobWriteResult {
        guard let current = durable, current.state == expected else {
            if job.state == .running, job.cancellationRequestedAt != nil {
                cancellationCASLost = true
            }
            return .stale
        }
        durable = job
        if job.state == .validating {
            validatingIsDurable = true
            await withCheckedContinuation { continuation in
                validatingWriteContinuation = continuation
            }
        }
        return .written(job)
    }

    func waitUntilValidatingIsDurable() async {
        while !validatingIsDurable { await Task.yield() }
    }

    func waitUntilCancellationCASLoses() async {
        while !cancellationCASLost { await Task.yield() }
    }

    func releaseValidatingWrite() {
        validatingWriteContinuation?.resume()
        validatingWriteContinuation = nil
    }
}

private actor FailureCancellationRaceJobProbe: SessionProcessingJobPort {
    private let order: FailureCancellationRaceOrder
    private let newerLatest: SessionProcessingJob
    private var durable: SessionProcessingJob?
    private var failureWriteContinuation: CheckedContinuation<Void, Never>?
    private var failureAttemptStarted = false
    private var failureIsDurable = false
    private var cancellationCASLost = false

    init(
        order: FailureCancellationRaceOrder,
        newerLatest: SessionProcessingJob
    ) {
        self.order = order
        self.newerLatest = newerLatest
    }

    func latest(for selection: SessionProcessingSelection) async
        -> SessionProcessingJobLoadResult
    {
        if failureIsDurable { return .loaded(newerLatest) }
        return durable.map(SessionProcessingJobLoadResult.loaded) ?? .none
    }

    func load(
        jobID: TranscriptionJobID,
        for selection: SessionProcessingSelection
    ) async -> SessionProcessingJobLoadResult {
        guard let durable, durable.jobID == jobID,
              durable.sessionID == selection.sessionID
        else { return .none }
        return .loaded(durable)
    }

    func create(_ job: SessionProcessingJob) async -> SessionProcessingJobWriteResult {
        guard durable == nil, job.state == .queued else { return .collision }
        durable = job
        return .written(job)
    }

    func transition(
        _ job: SessionProcessingJob,
        from expected: SessionProcessingJobState
    ) async -> SessionProcessingJobWriteResult {
        if job.state == .failed, expected == .running {
            guard let current = durable, current.state == expected,
                  current.jobID == job.jobID
            else { return .stale }
            failureAttemptStarted = true
            switch order {
            case .failureWins:
                durable = job
                failureIsDurable = true
                await suspendFailureWrite()
                // The durable winner is exact even if the caller cannot
                // distinguish an acknowledgement loss from a failed write.
                return .failed
            case .cancellationWins:
                await suspendFailureWrite()
                guard let current = durable, current.state == expected,
                      current.jobID == job.jobID,
                      current.cancellationRequestedAt == nil
                else { return .stale }
                durable = job
                return .written(job)
            }
        }

        guard let current = durable, current.state == expected,
              current.jobID == job.jobID
        else {
            if job.state == .running, job.cancellationRequestedAt != nil {
                cancellationCASLost = true
            }
            return .stale
        }
        durable = job
        return .written(job)
    }

    func waitUntilFailureAttemptStarts() async {
        while !failureAttemptStarted { await Task.yield() }
    }

    func waitUntilCancellationCASLoses() async {
        while !cancellationCASLost { await Task.yield() }
    }

    func releaseFailureWrite() {
        failureWriteContinuation?.resume()
        failureWriteContinuation = nil
    }

    private func suspendFailureWrite() async {
        await withCheckedContinuation { continuation in
            failureWriteContinuation = continuation
        }
    }
}

private actor SourceProbe: SessionTranscriptionSourcePort {
    private var results: [SessionTranscriptionSourceResult]
    private(set) var loadCount = 0

    init(_ result: SessionTranscriptionSourceResult) {
        results = [result]
    }

    init(_ results: [SessionTranscriptionSourceResult]) {
        self.results = results
    }

    func load(_ selection: SessionProcessingSelection) async
        -> SessionTranscriptionSourceResult
    {
        loadCount += 1
        guard !results.isEmpty else { return .unavailable }
        if results.count == 1 { return results[0] }
        return results.removeFirst()
    }
}

private actor ReconciliationSourceProbe: SessionTranscriptionSourcePort {
    private let sources: [SessionTranscriptionSource]
    private let forcedResult: SessionTranscriptionSourceResult?
    private let reconciliationID: SessionProcessingReconciliationID
    private(set) var selections: [SessionProcessingSelection] = []

    init(
        sources: [SessionTranscriptionSource],
        reconciliationID: SessionProcessingReconciliationID
    ) {
        self.sources = sources
        forcedResult = nil
        self.reconciliationID = reconciliationID
    }

    init(
        result: SessionTranscriptionSourceResult,
        reconciliationID: SessionProcessingReconciliationID
    ) {
        sources = []
        forcedResult = result
        self.reconciliationID = reconciliationID
    }

    func load(_ selection: SessionProcessingSelection) async
        -> SessionTranscriptionSourceResult
    {
        .unavailable
    }

    func load(
        _ selection: SessionProcessingSelection,
        reconciliationID: SessionProcessingReconciliationID
    ) async -> SessionTranscriptionSourceResult {
        selections.append(selection)
        guard reconciliationID == self.reconciliationID else {
            return .unavailable
        }
        if let forcedResult { return forcedResult }
        guard
              let source = sources.first(where: { $0.selection == selection })
        else { return .unavailable }
        return .available(source)
    }
}

private actor SuspendedSelectionSourceProbe: SessionTranscriptionSourcePort {
    private let first: SessionTranscriptionSource
    private let second: SessionTranscriptionSource
    private var firstLoadContinuation: CheckedContinuation<Void, Never>?
    private(set) var selections: [SessionProcessingSelection] = []

    init(first: SessionTranscriptionSource, second: SessionTranscriptionSource) {
        self.first = first
        self.second = second
    }

    func load(_ selection: SessionProcessingSelection) async
        -> SessionTranscriptionSourceResult
    {
        selections.append(selection)
        if selections.count == 1 {
            await withCheckedContinuation { continuation in
                firstLoadContinuation = continuation
            }
            return .available(first)
        }
        return .available(second)
    }

    func waitUntilFirstLoadStarts() async {
        while firstLoadContinuation == nil { await Task.yield() }
    }

    func releaseFirstLoad() {
        firstLoadContinuation?.resume()
        firstLoadContinuation = nil
    }
}

private actor EngineProbe: TranscriptionEngine {
    private let result: Result<VerifiedTranscriptionCandidate, TranscriptionEngineFailure>
    private let presence: TranscriptionWorkerPresence
    private let recovered: StagedTranscriptionCandidateResolution
    private let cancellation: TranscriptionCancellationOutcome
    private(set) var requests: [TranscriptionRequest] = []
    private(set) var presenceQueries: [TranscriptionExecutionReference] = []
    private(set) var recoveryJobs: [SessionProcessingJob] = []
    private(set) var cancelledExecutions: [TranscriptionExecutionReference] = []

    init(
        result: Result<VerifiedTranscriptionCandidate, TranscriptionEngineFailure>,
        presence: TranscriptionWorkerPresence = .unknown,
        recovered: StagedTranscriptionCandidateResolution = .unavailable,
        cancellation: TranscriptionCancellationOutcome = .unableToConfirm
    ) {
        self.result = result
        self.presence = presence
        self.recovered = recovered
        self.cancellation = cancellation
    }

    func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> VerifiedTranscriptionCandidate {
        requests.append(request)
        return try result.get()
    }

    func workerPresence(
        for execution: TranscriptionExecutionReference
    ) async -> TranscriptionWorkerPresence {
        presenceQueries.append(execution)
        return presence
    }

    func cancel(
        _ execution: TranscriptionExecutionReference
    ) async -> TranscriptionCancellationOutcome {
        cancelledExecutions.append(execution)
        return cancellation
    }

    func recoverCandidate(
        for job: SessionProcessingJob
    ) async -> StagedTranscriptionCandidateResolution {
        recoveryJobs.append(job)
        return recovered
    }

    func presenceQueryCount() -> Int { presenceQueries.count }
    func requestCount() -> Int { requests.count }
    func recoveryCount() -> Int { recoveryJobs.count }
}

private actor SuspendedEngineProbe: TranscriptionEngine {
    private let result: VerifiedTranscriptionCandidate
    private var continuation: CheckedContinuation<Void, Never>?
    private var eventSink: (@Sendable (TranscriptionEvent) async -> Void)?
    private(set) var requests: [TranscriptionRequest] = []

    init(result: VerifiedTranscriptionCandidate) {
        self.result = result
    }

    func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> VerifiedTranscriptionCandidate {
        requests.append(request)
        eventSink = events
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return result
    }

    func waitUntilTranscriptionStarts() async {
        while continuation == nil { await Task.yield() }
    }

    func releaseTranscription() {
        continuation?.resume()
        continuation = nil
    }

    func emit(_ event: TranscriptionEvent) async {
        await eventSink?(event)
    }
}

private actor CandidateWinsCancellationEngineProbe: TranscriptionEngine {
    private let candidate: VerifiedTranscriptionCandidate
    private var transcriptionContinuation: CheckedContinuation<Void, Never>?
    private(set) var cancellationCount = 0
    private(set) var recoveryCount = 0
    private(set) var transcriptionCount = 0

    init(candidate: VerifiedTranscriptionCandidate) {
        self.candidate = candidate
    }

    func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> VerifiedTranscriptionCandidate {
        transcriptionCount += 1
        await withCheckedContinuation { continuation in
            transcriptionContinuation = continuation
        }
        return candidate
    }

    func cancel(
        _ execution: TranscriptionExecutionReference
    ) async -> TranscriptionCancellationOutcome {
        cancellationCount += 1
        return .reaped
    }

    func recoverCandidate(
        for job: SessionProcessingJob
    ) async -> StagedTranscriptionCandidateResolution {
        recoveryCount += 1
        return .available(candidate)
    }

    func waitUntilTranscriptionStarts() async {
        while transcriptionContinuation == nil { await Task.yield() }
    }

    func releaseTranscription() {
        transcriptionContinuation?.resume()
        transcriptionContinuation = nil
    }
}

private actor FailureCancellationRaceEngineProbe: TranscriptionEngine {
    private let result: Result<
        VerifiedTranscriptionCandidate,
        TranscriptionEngineFailure
    >
    private var transcriptionContinuation: CheckedContinuation<Void, Never>?
    private(set) var cancellationCount = 0

    init(
        result: Result<VerifiedTranscriptionCandidate, TranscriptionEngineFailure>
    ) {
        self.result = result
    }

    func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> VerifiedTranscriptionCandidate {
        await withCheckedContinuation { continuation in
            transcriptionContinuation = continuation
        }
        return try result.get()
    }

    func cancel(
        _ execution: TranscriptionExecutionReference
    ) async -> TranscriptionCancellationOutcome {
        cancellationCount += 1
        return .reaped
    }

    func waitUntilTranscriptionStarts() async {
        while transcriptionContinuation == nil { await Task.yield() }
    }

    func releaseTranscription() {
        transcriptionContinuation?.resume()
        transcriptionContinuation = nil
    }
}

private actor CancellableEngineProbe: TranscriptionEngine {
    private let lateResult: VerifiedTranscriptionCandidate
    private var transcriptionContinuation: CheckedContinuation<Void, Never>?
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private var eventSink: (@Sendable (TranscriptionEvent) async -> Void)?
    private(set) var cancelledControls: [TranscriptionExecutionReference] = []

    init(lateResult: VerifiedTranscriptionCandidate) {
        self.lateResult = lateResult
    }

    func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> VerifiedTranscriptionCandidate {
        eventSink = events
        await withCheckedContinuation { continuation in
            transcriptionContinuation = continuation
        }
        return lateResult
    }

    func cancel(
        _ execution: TranscriptionExecutionReference
    ) async -> TranscriptionCancellationOutcome {
        cancelledControls.append(execution)
        transcriptionContinuation?.resume()
        transcriptionContinuation = nil
        await withCheckedContinuation { continuation in
            cancellationContinuation = continuation
        }
        return .reaped
    }

    func workerPresence(
        for execution: TranscriptionExecutionReference
    ) async -> TranscriptionWorkerPresence {
        .absent
    }

    func recoverCandidate(
        for job: SessionProcessingJob
    ) async -> StagedTranscriptionCandidateResolution {
        .unavailable
    }

    func waitUntilTranscriptionStarts() async {
        while transcriptionContinuation == nil { await Task.yield() }
    }

    func waitUntilCancellationStarts() async {
        while cancellationContinuation == nil { await Task.yield() }
    }

    func releaseCancellation() {
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }

    func emit(_ event: TranscriptionEvent) async {
        await eventSink?(event)
    }
}

private actor UnconfirmedCancellationEngineProbe: TranscriptionEngine {
    private let lateResult: VerifiedTranscriptionCandidate
    private var transcriptionContinuation: CheckedContinuation<Void, Never>?
    private var cancellationContinuation:
        CheckedContinuation<TranscriptionCancellationOutcome, Never>?

    init(lateResult: VerifiedTranscriptionCandidate) {
        self.lateResult = lateResult
    }

    func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> VerifiedTranscriptionCandidate {
        await withCheckedContinuation { continuation in
            transcriptionContinuation = continuation
        }
        return lateResult
    }

    func cancel(
        _ execution: TranscriptionExecutionReference
    ) async -> TranscriptionCancellationOutcome {
        await withCheckedContinuation { continuation in
            cancellationContinuation = continuation
        }
    }

    func waitUntilTranscriptionStarts() async {
        while transcriptionContinuation == nil { await Task.yield() }
    }

    func waitUntilCancellationStarts() async {
        while cancellationContinuation == nil { await Task.yield() }
    }

    func releaseCancellationAsUnconfirmed() {
        cancellationContinuation?.resume(returning: .unableToConfirm)
        cancellationContinuation = nil
    }

    func releaseTranscription() {
        transcriptionContinuation?.resume()
        transcriptionContinuation = nil
    }
}

private actor RevisionProbe: TranscriptRevisionRepository {
    private(set) var selected: TranscriptRevision?
    private var retained: [TranscriptRevisionID: TranscriptRevision]
    private(set) var publishCount = 0
    private(set) var reopenCount = 0
    private(set) var exactReopenCount = 0
    private(set) var expectedSelectedRevisionIDs: [TranscriptRevisionID?] = []

    init(
        selected: TranscriptRevision? = nil,
        retained: [TranscriptRevision] = []
    ) {
        self.selected = selected
        self.retained = Dictionary(
            uniqueKeysWithValues: retained.map { ($0.revisionID, $0) }
        )
        if let selected { self.retained[selected.revisionID] = selected }
    }

    func publishAndSelect(
        _ revision: TranscriptRevision,
        expectedSelectedRevisionID: TranscriptRevisionID?
    ) async throws -> ReopenedTranscriptRevisionSnapshot {
        publishCount += 1
        expectedSelectedRevisionIDs.append(expectedSelectedRevisionID)
        selected = revision
        retained[revision.revisionID] = revision
        return ReopenedTranscriptRevisionSnapshot(
            revisionIDs: Array(retained.keys),
            selectedRevisionID: revision.revisionID,
            selectedRevision: revision
        )
    }

    func reopenSelected(
        sessionID: SessionID
    ) async throws -> ReopenedTranscriptRevisionSnapshot {
        reopenCount += 1
        guard let selected else {
            throw TranscriptRevisionRepositoryFailure.sessionUnavailable
        }
        return ReopenedTranscriptRevisionSnapshot(
            revisionIDs: Array(retained.keys),
            selectedRevisionID: selected.revisionID,
            selectedRevision: selected
        )
    }

    func reopenRevision(
        sessionID: SessionID,
        revisionID: TranscriptRevisionID
    ) async throws -> TranscriptRevision {
        exactReopenCount += 1
        guard let revision = retained[revisionID], revision.sessionID == sessionID else {
            throw TranscriptRevisionRepositoryFailure.sessionUnavailable
        }
        return revision
    }

    func publishCountValue() -> Int { publishCount }
}

private actor SelectionCASRevisionProbe: TranscriptRevisionRepository {
    private(set) var selectedRevisionID: TranscriptRevisionID?
    private(set) var expectedSelectedRevisionIDs: [TranscriptRevisionID?] = []

    init(selectedRevisionID: TranscriptRevisionID?) {
        self.selectedRevisionID = selectedRevisionID
    }

    func publishAndSelect(
        _ revision: TranscriptRevision,
        expectedSelectedRevisionID: TranscriptRevisionID?
    ) async throws -> ReopenedTranscriptRevisionSnapshot {
        expectedSelectedRevisionIDs.append(expectedSelectedRevisionID)
        guard selectedRevisionID == expectedSelectedRevisionID else {
            throw TranscriptRevisionRepositoryFailure.staleSelection
        }
        selectedRevisionID = revision.revisionID
        return ReopenedTranscriptRevisionSnapshot(
            revisionIDs: [revision.revisionID],
            selectedRevisionID: revision.revisionID,
            selectedRevision: revision
        )
    }

    func reopenSelected(
        sessionID: SessionID
    ) async throws -> ReopenedTranscriptRevisionSnapshot {
        throw TranscriptRevisionRepositoryFailure.sessionUnavailable
    }

    func reopenRevision(
        sessionID: SessionID,
        revisionID: TranscriptRevisionID
    ) async throws -> TranscriptRevision {
        throw TranscriptRevisionRepositoryFailure.sessionUnavailable
    }
}

/// Simulates the manifest-last crash boundary where the immutable Revision and
/// selected pointer are already installed, but the repository cannot complete
/// its mandatory reopen before returning to Application.
private actor InstalledNeedsRefreshRevisionProbe: TranscriptRevisionRepository {
    private var installed: TranscriptRevision?
    private var selected: TranscriptRevision?
    private(set) var publishCount = 0
    private(set) var selectedReopenCount = 0
    private(set) var exactReopenCount = 0

    func publishAndSelect(
        _ revision: TranscriptRevision,
        expectedSelectedRevisionID: TranscriptRevisionID?
    ) async throws -> ReopenedTranscriptRevisionSnapshot {
        publishCount += 1
        installed = revision
        selected = revision
        throw TranscriptRevisionRepositoryFailure.installedNeedsRefresh
    }

    func reopenSelected(
        sessionID: SessionID
    ) async throws -> ReopenedTranscriptRevisionSnapshot {
        selectedReopenCount += 1
        guard let selected, selected.sessionID == sessionID else {
            throw TranscriptRevisionRepositoryFailure.sessionUnavailable
        }
        return ReopenedTranscriptRevisionSnapshot(
            revisionIDs: [selected.revisionID],
            selectedRevisionID: selected.revisionID,
            selectedRevision: selected
        )
    }

    func reopenRevision(
        sessionID: SessionID,
        revisionID: TranscriptRevisionID
    ) async throws -> TranscriptRevision {
        exactReopenCount += 1
        guard let installed, installed.sessionID == sessionID,
              installed.revisionID == revisionID
        else { throw TranscriptRevisionRepositoryFailure.sessionUnavailable }
        return installed
    }

    func select(_ revision: TranscriptRevision) {
        selected = revision
    }
}

private struct FixedProcessingClock: SessionProcessingClock {
    let instant: UTCInstant

    init(_ instant: UTCInstant) { self.instant = instant }

    func now() async -> UTCInstant { instant }
}

private actor SequencedProcessingClock: SessionProcessingClock {
    private var instants: [UTCInstant]

    init(_ instants: [UTCInstant]) { self.instants = instants }

    func now() async -> UTCInstant {
        precondition(!instants.isEmpty)
        if instants.count == 1 { return instants[0] }
        return instants.removeFirst()
    }
}

private struct FixedProcessingIdentifiers: SessionProcessingIDGenerator {
    let jobID: TranscriptionJobID
    let revisionID: TranscriptRevisionID
    let cancellationAuthorityID: TranscriptionCancellationAuthorityID

    init(
        jobID: TranscriptionJobID,
        revisionID: TranscriptRevisionID,
        cancellationAuthorityID: TranscriptionCancellationAuthorityID = try!
            TranscriptionCancellationAuthorityID("cancel-fixed-authority")
    ) {
        self.jobID = jobID
        self.revisionID = revisionID
        self.cancellationAuthorityID = cancellationAuthorityID
    }

    func generateJobID(at instant: UTCInstant) async -> TranscriptionJobID { jobID }

    func generateRevisionID(at instant: UTCInstant) async -> TranscriptRevisionID {
        revisionID
    }

    func generateCancellationAuthorityID(
        at instant: UTCInstant
    ) async -> TranscriptionCancellationAuthorityID {
        cancellationAuthorityID
    }
}

private extension TranscriptionCandidate {
    func replacing(sessionID: String) -> TranscriptionCandidate {
        TranscriptionCandidate(
            schemaVersion: schemaVersion,
            jobID: jobID,
            sessionID: sessionID,
            revisionID: revisionID,
            durationMilliseconds: durationMilliseconds,
            audioFingerprintSHA256: audioFingerprintSHA256,
            sourceFingerprints: sourceFingerprints,
            candidateArtifactSHA256: candidateArtifactSHA256,
            engine: engine,
            lines: lines,
            audioEvents: audioEvents
        )
    }
}
