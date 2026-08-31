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

    func testUnqualifiedPinnedProfileNeverCreatesAJobOrLaunchesAnEngine() async throws {
        let fixture = try ProcessingFixture()
        let runtime = RuntimeProbe(
            .unavailable(.qualificationBlocked(profileID: fixture.profile.profileID))
        )
        let model = ModelProbe(.ready)
        let jobs = JobProbe()
        let engine = EngineProbe(result: .failure(.launchFailed))
        let feature = DefaultSessionProcessingFeature(
            source: SourceProbe(.available(fixture.source)),
            runtime: runtime,
            model: model,
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
        await feature.send(.start)

        guard case let .unavailable(unavailable) = await feature.currentState else {
            return XCTFail("expected explicit pinned-profile failure")
        }
        XCTAssertEqual(
            unavailable.reason,
            .qualificationBlocked(profileID: fixture.profile.profileID)
        )
        XCTAssertEqual(unavailable.actions, [])
        let persistedStates = await jobs.states
        let engineRequests = await engine.requests
        let modelVerificationCount = await model.verificationCount
        XCTAssertEqual(persistedStates, [])
        XCTAssertEqual(engineRequests.count, 0)
        XCTAssertEqual(modelVerificationCount, 0)
    }

    func testMissingModelCanBePreparedThenRetriedWithoutChangingEngine() async throws {
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
        await feature.send(.retry)

        guard case .completed = await feature.currentState else {
            return XCTFail("expected successful retry after explicit preparation")
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

    func testRelaunchKeepsQueuedWorkQueuedWithoutCheckingOrLaunchingAWorker()
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

        guard case let .queued(snapshot) = await feature.currentState else {
            return XCTFail("expected queued work to remain queued")
        }
        XCTAssertEqual(snapshot.job, queued)
        let presenceCount = await engine.presenceQueryCount()
        let requestCount = await engine.requestCount()
        let persistedStates = await jobs.states
        XCTAssertEqual(presenceCount, 0)
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(persistedStates, [])
    }

    func testRelaunchResumesHashValidConfinedCandidatePublicationIdempotently()
        async throws
    {
        let fixture = try ProcessingFixture(selectedRevisionID: true)
        let validating = fixture.job(
            state: .validating,
            expectedSelectedRevisionID: nil,
            candidateArtifactSHA256: fixture.candidateFingerprint.sha256
        )
        let jobs = JobProbe(latest: validating)
        let revisions = RevisionProbe(selected: try fixture.validatedRevision())
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
        XCTAssertEqual(completed.selectedRevisionID, fixture.revisionID)
        let recoveryCount = await engine.recoveryCount()
        let publishCount = await revisions.publishCountValue()
        let persistedStates = await jobs.states
        let expectedSelections = await revisions.expectedSelectedRevisionIDs
        XCTAssertEqual(recoveryCount, 0)
        XCTAssertEqual(publishCount, 0)
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
        let feature = DefaultSessionProcessingFeature(
            source: SourceProbe(.available(fixture.source)),
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

        guard case let .unavailable(unavailable) = await feature.currentState else {
            return XCTFail("expected no Session state")
        }
        XCTAssertEqual(unavailable.reason, .noSession)
        XCTAssertEqual(unavailable.actions, [])
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

    func testRetryRereadsSelectionAfterPublicationCommittedButJobCompletionFailed()
        async throws
    {
        let fixture = try ProcessingFixture()
        let refreshedSource = SessionTranscriptionSource(
            selection: fixture.selection,
            audioCapabilityID: fixture.source.audioCapabilityID,
            durationMilliseconds: fixture.source.durationMilliseconds,
            audioFingerprint: fixture.source.audioFingerprint,
            sourceFingerprints: fixture.source.sourceFingerprints,
            expectedSelectedRevisionID: fixture.revisionID
        )
        let source = SourceProbe([
            .available(fixture.source),
            .available(refreshedSource),
        ])
        let jobs = JobProbe(
            failingTransitionState: .completed,
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
        guard case let .failed(failure) = await feature.currentState else {
            return XCTFail("expected installed selection needing refresh")
        }
        XCTAssertEqual(failure.reason, .installedNeedsRefresh)

        await feature.send(.retry)

        guard case .completed = await feature.currentState else {
            return XCTFail("expected Retry to use the refreshed selected Revision")
        }
        let loadCount = await source.loadCount
        let expectedSelections = await revisions.expectedSelectedRevisionIDs
        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(expectedSelections, [nil, fixture.revisionID])
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
        candidateArtifactSHA256: String? = nil
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
            candidateArtifactSHA256: candidateArtifactSHA256
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
}

private actor RuntimeProbe: TranscriptionRuntimePort {
    private let resolution: TranscriptionRuntimeResolution

    init(_ resolution: TranscriptionRuntimeResolution) {
        self.resolution = resolution
    }

    func resolve() async -> TranscriptionRuntimeResolution { resolution }

    func prepare(_ action: SessionProcessingRecoveryAction) async
        -> TranscriptionRuntimeResolution
    {
        resolution
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

private actor JobProbe: SessionProcessingJobPort {
    private let latestValue: SessionProcessingJob?
    private let failingTransitionState: SessionProcessingJobState?
    private var remainingTransitionFailures: Int
    private(set) var states: [SessionProcessingJobState] = []
    private(set) var snapshots: [SessionProcessingJob] = []

    init(
        latest: SessionProcessingJob? = nil,
        failingTransitionState: SessionProcessingJobState? = nil,
        transitionFailureCount: Int = 0
    ) {
        latestValue = latest
        self.failingTransitionState = failingTransitionState
        remainingTransitionFailures = transitionFailureCount
    }

    func latest(for selection: SessionProcessingSelection) async
        -> SessionProcessingJobLoadResult
    {
        latestValue.map(SessionProcessingJobLoadResult.loaded) ?? .none
    }

    func create(_ job: SessionProcessingJob) async -> SessionProcessingJobWriteResult {
        states.append(job.state)
        snapshots.append(job)
        return .written(job)
    }

    func transition(
        _ job: SessionProcessingJob,
        from expected: SessionProcessingJobState
    ) async -> SessionProcessingJobWriteResult {
        states.append(job.state)
        snapshots.append(job)
        if job.state == failingTransitionState, remainingTransitionFailures > 0 {
            remainingTransitionFailures -= 1
            return .failed
        }
        return .written(job)
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
