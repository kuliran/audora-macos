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
                state: .running
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

    init() throws {
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
            expectedSelectedRevisionID: nil
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
        return .written(job)
    }

    func transition(
        _ job: SessionProcessingJob,
        from expected: SessionProcessingJobState
    ) async -> SessionProcessingJobWriteResult {
        states.append(job.state)
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
    private(set) var requests: [TranscriptionRequest] = []

    init(result: Result<VerifiedTranscriptionCandidate, TranscriptionEngineFailure>) {
        self.result = result
    }

    func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> VerifiedTranscriptionCandidate {
        requests.append(request)
        return try result.get()
    }
}

private actor SuspendedEngineProbe: TranscriptionEngine {
    private let result: VerifiedTranscriptionCandidate
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var requests: [TranscriptionRequest] = []

    init(result: VerifiedTranscriptionCandidate) {
        self.result = result
    }

    func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> VerifiedTranscriptionCandidate {
        requests.append(request)
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
}

private actor RevisionProbe: TranscriptRevisionRepository {
    private(set) var selected: TranscriptRevision?
    private(set) var publishCount = 0
    private(set) var expectedSelectedRevisionIDs: [TranscriptRevisionID?] = []

    func publishAndSelect(
        _ revision: TranscriptRevision,
        expectedSelectedRevisionID: TranscriptRevisionID?
    ) async throws -> ReopenedTranscriptRevisionSnapshot {
        publishCount += 1
        expectedSelectedRevisionIDs.append(expectedSelectedRevisionID)
        selected = revision
        return ReopenedTranscriptRevisionSnapshot(
            revisionIDs: [revision.revisionID],
            selectedRevisionID: revision.revisionID,
            selectedRevision: revision
        )
    }

    func reopenSelected(
        sessionID: SessionID
    ) async throws -> ReopenedTranscriptRevisionSnapshot {
        guard let selected else {
            throw TranscriptRevisionRepositoryFailure.sessionUnavailable
        }
        return ReopenedTranscriptRevisionSnapshot(
            revisionIDs: [selected.revisionID],
            selectedRevisionID: selected.revisionID,
            selectedRevision: selected
        )
    }
}

private struct FixedProcessingClock: SessionProcessingClock {
    let instant: UTCInstant

    init(_ instant: UTCInstant) { self.instant = instant }

    func now() async -> UTCInstant { instant }
}

private struct FixedProcessingIdentifiers: SessionProcessingIDGenerator {
    let jobID: TranscriptionJobID
    let revisionID: TranscriptRevisionID

    func generateJobID(at instant: UTCInstant) async -> TranscriptionJobID { jobID }

    func generateRevisionID(at instant: UTCInstant) async -> TranscriptRevisionID {
        revisionID
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
