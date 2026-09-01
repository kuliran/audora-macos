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
            XCTAssertNil(
                LibraryRootInteractionPolicy.admittedProcessingAction(
                    .retry,
                    in: presentation,
                    isChatBoundaryPending: false
                )
            )
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
        let commands = await feature.recordedCommands()

        XCTAssertEqual(model.state?.title, "Offline model is not prepared")
        XCTAssertEqual(commands, [.start, .prepare, .reinstall, .retry])
    }

    func testPendingChatBoundaryStillAdmitsAndEmitsProcessingCancel() async throws {
        let feature = ScriptedSessionProcessingFeature(snapshots: [])
        let model = SessionProcessingPresentationModel(feature: feature)

        let admitted = LibraryRootInteractionPolicy.admittedProcessingAction(
            .cancel,
            isChatBoundaryPending: true
        )
        XCTAssertEqual(admitted, .cancel)
        XCTAssertNil(
            LibraryRootInteractionPolicy.admittedProcessingAction(
                .start,
                isChatBoundaryPending: true
            )
        )
        XCTAssertNil(
            LibraryRootInteractionPolicy.admittedProcessingAction(
                .retry,
                isChatBoundaryPending: true
            )
        )

        model.perform(try XCTUnwrap(admitted))
        await feature.waitForCommandCount(1)
        let commands = await feature.recordedCommands()
        XCTAssertEqual(commands, [.cancel])
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

private actor ScriptedSessionProcessingFeature: SessionProcessingFeature {
    nonisolated let states: AsyncStream<SessionProcessingFeatureState>

    private let state: SessionProcessingFeatureState
    private var commands: [SessionProcessingCommand] = []

    init(snapshots: [SessionProcessingFeatureState]) {
        state = snapshots.last ?? .unavailable(
            SessionProcessingUnavailableSnapshot(
                selection: nil,
                reason: .noSession,
                actions: []
            )
        )
        states = AsyncStream { continuation in
            for snapshot in snapshots { continuation.yield(snapshot) }
            continuation.finish()
        }
    }

    var currentState: SessionProcessingFeatureState { state }

    func send(_ command: SessionProcessingCommand) { commands.append(command) }

    func reserveLibraryNavigation() async -> Bool { false }

    func finishLibraryNavigation(didMutateLibrary: Bool) async {}

    func recordedCommands() -> [SessionProcessingCommand] { commands }

    func waitForCommandCount(_ expected: Int) async {
        while commands.count < expected { await Task.yield() }
    }
}
