import AudoraApplication
import AudoraDomain
import AudoraMacPresentation
import XCTest

@MainActor
final class SessionProcessingPresentationModelTests: XCTestCase {
    func testActivePhaseProgressAndApproximateETAStayExplicit() throws {
        let source = try makeSource()
        let job = makeJob(state: .running)

        let loading = SessionProcessingPresentationMapper.map(
            .running(
                SessionProcessingActiveSnapshot(
                    source: source,
                    job: job,
                    phase: .loadingModel
                )
            )
        )
        XCTAssertEqual(loading.phase, .loadingModel)
        XCTAssertEqual(loading.progress, .indeterminate)
        XCTAssertNil(loading.approximateETASeconds)
        XCTAssertEqual(loading.actions, [.cancel])

        let transcribing = SessionProcessingPresentationMapper.map(
            .running(
                SessionProcessingActiveSnapshot(
                    source: source,
                    job: job,
                    phase: .transcribing,
                    progress: SessionProcessingProgress(
                        completedWindows: 2,
                        totalWindows: 4,
                        approximateETASeconds: 5
                    )
                )
            )
        )
        XCTAssertEqual(transcribing.phase, .transcribing)
        XCTAssertEqual(
            transcribing.progress,
            .measurable(completedWindows: 2, totalWindows: 4)
        )
        XCTAssertEqual(transcribing.approximateETASeconds, 5)
        XCTAssertTrue(transcribing.detail?.contains("may change") == true)
    }

    func testQueuedAndTerminalStatesDoNotExposeStaleProgressOrNoOpControls() throws {
        let source = try makeSource()
        let queued = makeJob(state: .queued)
        let cancelled = makeJob(state: .cancelled)

        let queuedPresentation = SessionProcessingPresentationMapper.map(
            .queued(
                SessionProcessingRecoverableSnapshot(
                    source: source,
                    job: queued,
                    actions: []
                )
            )
        )
        XCTAssertNil(queuedPresentation.phase)
        XCTAssertNil(queuedPresentation.progress)
        XCTAssertEqual(queuedPresentation.actions, [])

        let cancelledPresentation = SessionProcessingPresentationMapper.map(
            .cancelled(
                SessionProcessingRecoverableSnapshot(
                    source: source,
                    job: cancelled,
                    actions: [.retry]
                )
            )
        )
        XCTAssertNil(cancelledPresentation.phase)
        XCTAssertNil(cancelledPresentation.progress)
        XCTAssertNil(cancelledPresentation.approximateETASeconds)
        XCTAssertEqual(cancelledPresentation.actions, [.retry])
    }

    func testBlockedQualificationOffersNoImpossibleRepairAndExplainsReleaseRecovery()
        throws
    {
        let selection = try makeSelection()
        let state = SessionProcessingFeatureState.unavailable(
            SessionProcessingUnavailableSnapshot(
                selection: selection,
                reason: .qualificationBlocked(profileID: "crisper-profile-v1"),
                actions: []
            )
        )

        let presentation = SessionProcessingPresentationMapper.map(state)

        XCTAssertEqual(presentation.status, .unavailable)
        XCTAssertEqual(presentation.title, "Offline transcription isn’t qualified")
        XCTAssertTrue(presentation.detail?.contains("crisper-profile-v1") == true)
        XCTAssertTrue(presentation.detail?.contains("Audora update") == true)
        XCTAssertEqual(presentation.actions, [])
    }

    func testNewerJobIndexDirectsCompatibleUpdateWithoutRetry() {
        let presentation = SessionProcessingPresentationMapper.map(
            .unavailable(
                SessionProcessingUnavailableSnapshot(
                    selection: nil,
                    reason: .jobIndexSchemaNewer(version: 2),
                    actions: []
                )
            )
        )

        XCTAssertEqual(presentation.status, .unavailable)
        XCTAssertEqual(presentation.title, "Processing needs a newer Audora")
        XCTAssertTrue(presentation.detail?.contains("schema version 2") == true)
        XCTAssertTrue(presentation.detail?.contains("compatible update") == true)
        XCTAssertEqual(presentation.actions, [])
    }

    func testLibraryJobIndexFailuresStayVisibleAndAdmitNoProcessingAction() {
        let cases: [(SessionProcessingUnavailableReason, String)] = [
            (.jobIndexUnavailable, "unavailable"),
            (.jobIndexIntegrityMismatch, "could not be verified"),
            (.jobIndexIncomplete, "incomplete"),
        ]

        for (reason, expectedTitleText) in cases {
            let presentation = SessionProcessingPresentationMapper.map(
                .unavailable(
                    SessionProcessingUnavailableSnapshot(
                        selection: nil,
                        reason: reason,
                        actions: []
                    )
                )
            )

            XCTAssertEqual(presentation.status, .unavailable)
            XCTAssertTrue(
                presentation.title.localizedCaseInsensitiveContains(
                    expectedTitleText
                )
            )
            XCTAssertTrue(presentation.detail?.contains("Library") == true)
            XCTAssertEqual(presentation.actions, [])
        }
    }

    func testModelProjectsStatesAndSendsTypedStartAndRecoveryCommands() async throws {
        let source = try makeSource()
        let feature = ScriptedSessionProcessingFeature(
            snapshots: [
                .ready(SessionProcessingReadySnapshot(source: source)),
                .unavailable(
                    SessionProcessingUnavailableSnapshot(
                        selection: source.selection,
                        reason: .modelMissing,
                        actions: [.prepare, .reinstall, .retry]
                    )
                ),
            ]
        )
        let model = SessionProcessingPresentationModel(feature: feature)

        await model.start()
        await model.start()
        model.perform(.start)
        model.perform(.prepare)
        model.perform(.reinstall)
        model.perform(.retry)
        await feature.waitForCommandCount(4)
        let commands = feature.recordedCommands()

        XCTAssertEqual(model.state?.title, "Offline model is not prepared")
        XCTAssertEqual(commands, [.start, .prepare, .reinstall, .retry])
    }

    func testModelProjectsApplicationAdmissionAndDispatchesThroughThatSeam()
        async
    {
        let feature = ScriptedSessionProcessingFeature(
            snapshots: [],
            admittedCommands: [.cancel]
        )
        let model = SessionProcessingPresentationModel(feature: feature)

        XCTAssertFalse(model.isAdmitted(.start))
        XCTAssertFalse(model.isAdmitted(.retry))
        XCTAssertTrue(model.isAdmitted(.cancel))

        model.perform(.start)
        model.perform(.retry)
        model.perform(.cancel)
        await feature.waitForAttemptCount(3)

        XCTAssertEqual(feature.attemptedCommands, [.start, .retry, .cancel])
        XCTAssertEqual(feature.recordedCommands(), [.cancel])
    }

    func testNonterminalRelaunchStateDoesNotOfferIssue16Controls() throws {
        let job = SessionProcessingJob(
            jobID: try TranscriptionJobID("job-20260830T120500000Z-5GHJ"),
            sessionID: try SessionID("ses-20260830T120100000Z-2CDE"),
            revisionID: try TranscriptRevisionID("trv-20260830T120600000Z-6JKM"),
            profileID: "synthetic-qualified-v1",
            createdAt: try UTCInstant("2026-08-30T12:05:00.000Z"),
            state: .running,
            cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                "cancel-presentation"
            )
        )

        let presentation = SessionProcessingPresentationMapper.map(
            .recoveryRequired(job)
        )

        XCTAssertEqual(presentation.status, .recoveryRequired)
        XCTAssertEqual(presentation.actions, [])
    }

    func testCanonicalRevisionIntegrityFailureOffersNoRetranscriptionAction() {
        let presentation = SessionProcessingPresentationMapper.map(
            .failed(
                SessionProcessingFailedSnapshot(
                    job: makeJob(state: .completed),
                    reason: .canonicalRevisionIntegrityFailed,
                    actions: []
                )
            )
        )

        XCTAssertEqual(presentation.status, .failed)
        XCTAssertEqual(presentation.actions, [])
        XCTAssertTrue(presentation.detail?.contains("cannot be safely replaced") == true)
    }

    func testCompletedCopyDoesNotClaimJobRevisionIsSelectedAfterReviewChange()
        throws
    {
        let jobRevisionID = try TranscriptRevisionID(
            "trv-20260830T120600000Z-6JKM"
        )
        let reviewRevisionID = try TranscriptRevisionID(
            "trv-20260830T120700000Z-7MNP"
        )
        let presentation = SessionProcessingPresentationMapper.map(
            .completed(
                SessionProcessingCompletedSnapshot(
                    sessionID: try SessionID("ses-20260830T120100000Z-2CDE"),
                    jobID: try TranscriptionJobID(
                        "job-20260830T120500000Z-5GHJ"
                    ),
                    revisionID: jobRevisionID,
                    selectedRevisionID: reviewRevisionID
                )
            )
        )

        XCTAssertEqual(presentation.title, "Transcription completed")
        XCTAssertTrue(presentation.detail?.contains("another") == true)
        XCTAssertFalse(presentation.detail?.contains("is selected") == true)
    }

    private func makeSelection() throws -> SessionProcessingSelection {
        SessionProcessingSelection(
            scope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T120000000Z-1ABC")
            ),
            sessionID: try SessionID("ses-20260830T120100000Z-2CDE")
        )
    }

    private func makeSource() throws -> SessionTranscriptionSource {
        let fingerprint = try AudioFingerprint(
            sha256: String(repeating: "1", count: 64)
        )
        return SessionTranscriptionSource(
            selection: try makeSelection(),
            audioCapabilityID: try SessionTranscriptionAudioCapabilityID(
                "cap-presentation"
            ),
            durationMilliseconds: 2_000,
            audioFingerprint: fingerprint,
            sourceFingerprints: [
                TranscriptSourceFingerprint(
                    audioSourceID: try AudioSourceID("src-0001"),
                    fingerprint: fingerprint
                ),
            ],
            expectedSelectedRevisionID: nil
        )
    }

    private func makeJob(state: SessionProcessingJobState) -> SessionProcessingJob {
        SessionProcessingJob(
            jobID: try! TranscriptionJobID("job-20260830T120500000Z-5GHJ"),
            sessionID: try! SessionID("ses-20260830T120100000Z-2CDE"),
            revisionID: try! TranscriptRevisionID("trv-20260830T120600000Z-6JKM"),
            profileID: "synthetic-qualified-v1",
            createdAt: try! UTCInstant("2026-08-30T12:05:00.000Z"),
            state: state,
            cancellationAuthorityID: try! TranscriptionCancellationAuthorityID(
                "cancel-presentation"
            )
        )
    }
}

@MainActor
private final class ScriptedSessionProcessingFeature:
    ApplicationSessionProcessingFeature
{
    let sessionProcessingStates: AsyncStream<SessionProcessingFeatureState>

    private let state: SessionProcessingFeatureState
    private let admittedCommands: [SessionProcessingCommand]?
    private var commands: [SessionProcessingCommand] = []
    private(set) var attemptedCommands: [SessionProcessingCommand] = []

    init(
        snapshots: [SessionProcessingFeatureState],
        admittedCommands: [SessionProcessingCommand]? = nil
    ) {
        state = snapshots.last ?? .unavailable(
            SessionProcessingUnavailableSnapshot(
                selection: nil,
                reason: .noSession,
                actions: []
            )
        )
        self.admittedCommands = admittedCommands
        sessionProcessingStates = AsyncStream { continuation in
            for snapshot in snapshots { continuation.yield(snapshot) }
            continuation.finish()
        }
    }

    func currentSessionProcessingState() async -> SessionProcessingFeatureState? {
        state
    }

    func isSessionProcessingCommandAdmitted(
        _ command: SessionProcessingCommand
    ) -> Bool {
        admittedCommands?.contains(command) ?? true
    }

    func send(_ command: SessionProcessingCommand) async -> Bool {
        attemptedCommands.append(command)
        guard isSessionProcessingCommandAdmitted(command) else { return false }
        commands.append(command)
        return true
    }

    func recordedCommands() -> [SessionProcessingCommand] { commands }

    func waitForCommandCount(_ expected: Int) async {
        while commands.count < expected { await Task.yield() }
    }

    func waitForAttemptCount(_ expected: Int) async {
        while attemptedCommands.count < expected { await Task.yield() }
    }
}
