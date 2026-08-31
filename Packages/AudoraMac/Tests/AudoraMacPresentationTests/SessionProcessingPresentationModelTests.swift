import AudoraApplication
import AudoraDomain
import AudoraMacPresentation
import XCTest

@MainActor
final class SessionProcessingPresentationModelTests: XCTestCase {
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

    func testNonterminalRelaunchStateDoesNotOfferIssue16Controls() throws {
        let job = SessionProcessingJob(
            jobID: try TranscriptionJobID("job-20260830T120500000Z-5GHJ"),
            sessionID: try SessionID("ses-20260830T120100000Z-2CDE"),
            revisionID: try TranscriptRevisionID("trv-20260830T120600000Z-6JKM"),
            profileID: "synthetic-qualified-v1",
            createdAt: try UTCInstant("2026-08-30T12:05:00.000Z"),
            state: .running
        )

        let presentation = SessionProcessingPresentationMapper.map(
            .recoveryRequired(job)
        )

        XCTAssertEqual(presentation.status, .recoveryRequired)
        XCTAssertEqual(presentation.actions, [])
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

    func recordedCommands() -> [SessionProcessingCommand] { commands }

    func waitForCommandCount(_ expected: Int) async {
        while commands.count < expected { await Task.yield() }
    }
}
