import AudoraApplication
import AudoraDomain
import AudoraMacPresentation
import XCTest

@MainActor
final class RecordingPresentationModelTests: XCTestCase {
    func testMapperExposesElapsedLevelMuteAndFiveMinuteWarningAccessibly() throws {
        let state = RecordingPresentationMapper.map(
            .active(
                RecordingSnapshot(
                    recordingID: try recordingID(),
                    sessionID: try sessionID(),
                    elapsedFrames: CanonicalRecordingLimits.fiveMinuteWarningFrame,
                    level: .unavailable(.muted),
                    mute: .muted,
                    noticeID: 7
                ),
                confirmation: .none
            )
        )
        XCTAssertEqual(state.elapsed, "40:00")
        // This exact value is rendered as visible text next to the meter; it
        // is not only an accessibility value on a zero-filled ProgressView.
        XCTAssertEqual(state.levelValue, "Unavailable")
        XCTAssertNil(state.levelFraction)
        XCTAssertEqual(state.muteStateValue, "Muted")
        XCTAssertEqual(state.muteActionLabel, "Unmute microphone")
        XCTAssertEqual(state.warningText, "5 minutes remaining")
        XCTAssertEqual(state.announcement, "5 minutes remaining")
        XCTAssertTrue(state.canStop)
        XCTAssertTrue(state.canCancel)
    }

    func testCountdownAnnouncesOnlyBoundedMilestones() throws {
        let ordinarySecond = RecordingPresentationMapper.map(
            .active(
                RecordingSnapshot(
                    recordingID: try recordingID(),
                    sessionID: try sessionID(),
                    elapsedFrames: CanonicalRecordingLimits.maximumFrames - 59 * 16_000,
                    level: .measured(0.4),
                    mute: .live,
                    noticeID: 8
                ),
                confirmation: .none
            )
        )
        XCTAssertEqual(ordinarySecond.warningText, "Automatic stop in 59 seconds")
        XCTAssertNil(ordinarySecond.announcement)

        let milestone = RecordingPresentationMapper.map(
            .active(
                RecordingSnapshot(
                    recordingID: try recordingID(),
                    sessionID: try sessionID(),
                    elapsedFrames: CanonicalRecordingLimits.maximumFrames - 30 * 16_000,
                    level: .measured(0.4),
                    mute: .live,
                    noticeID: 9
                ),
                confirmation: .none
            )
        )
        XCTAssertEqual(milestone.announcement, "Automatic stop in 30 seconds")
    }

    func testAutomaticStopExplanationPersistsThroughSealingAndCompletion() throws {
        let snapshot = RecordingSnapshot(
            recordingID: try recordingID(),
            sessionID: try sessionID(),
            elapsedFrames: CanonicalRecordingLimits.maximumFrames,
            level: .unavailable(.stale),
            mute: .live,
            noticeID: 10
        )
        let sealing = RecordingPresentationMapper.map(
            .sealing(snapshot, reason: .durationLimit)
        )
        XCTAssertEqual(
            sealing.persistentExplanation,
            "Recording stopped at the 45-minute limit. Your audio is being sealed."
        )

        let receipt = try SessionSealedReceipt(
            libraryID: libraryID(),
            recordingID: snapshot.recordingID,
            sessionID: snapshot.sessionID,
            frameCount: snapshot.elapsedFrames,
            fingerprint: AudioFingerprint(sha256: String(repeating: "a", count: 64))
        )
        let completed = RecordingPresentationMapper.map(
            .completed(SealedSessionSnapshot(receipt: receipt), notice: .durationLimit)
        )
        XCTAssertEqual(completed.elapsed, "45:00")
        XCTAssertTrue(completed.persistentExplanation?.contains("45-minute limit") == true)
        XCTAssertTrue(completed.canRecord)
    }

    func testRecoveryProjectionOffersExactActionsAndNeverResume() throws {
        let item = RecordingRecoveryItem(
            recordingID: try recordingID(),
            sessionID: try sessionID(),
            startedAt: try UTCInstant("2026-08-30T12:00:00.000Z"),
            durableFrameCount: 32_000,
            availability: .discardOnly
        )
        let state = RecordingPresentationMapper.map(
            .recoveryRequired(RecordingRecoveryCatalog(items: [item]))
        )
        XCTAssertEqual(state.status, .recoveryRequired)
        XCTAssertEqual(state.recoveryItems.count, 1)
        XCTAssertFalse(state.recoveryItems[0].canSeal)
        XCTAssertTrue(state.recoveryItems[0].canDiscard)
        let projected = [state.title, state.detail ?? ""].joined(separator: " ")
        XCTAssertFalse(projected.localizedCaseInsensitiveContains("resume"))
    }

    func testLibraryInspectionDisablesRecordAndCommittedCleanupNeverOffersDiscard() throws {
        let scope = LibraryScope(libraryID: try libraryID())
        let selecting = RecordingPresentationMapper.map(.selectingLibrary(scope))
        XCTAssertEqual(selecting.status, .selectingLibrary)
        XCTAssertFalse(selecting.canRecord)

        let item = RecordingRecoveryItem(
            recordingID: try recordingID(),
            sessionID: try sessionID(),
            startedAt: try UTCInstant("2026-08-30T12:00:00.000Z"),
            durableFrameCount: 16_000,
            availability: .committedCleanup
        )
        let cleanup = RecordingPresentationMapper.map(
            .recoveryRequired(RecordingRecoveryCatalog(items: [item]))
        )
        XCTAssertTrue(cleanup.recoveryItems[0].canSeal)
        XCTAssertFalse(cleanup.recoveryItems[0].canDiscard)
        XCTAssertEqual(cleanup.recoveryItems[0].sealActionLabel, "Retry Cleanup")
    }

    func testNewerRecordingRootIsVisiblyReadOnlyAndOffersNoMutation() throws {
        let item = RecordingRecoveryItem(
            recordingID: try recordingID(),
            sessionID: try sessionID(),
            startedAt: try UTCInstant("2026-08-30T12:00:00.000Z"),
            durableFrameCount: 0,
            availability: .readOnlyNewerSchema
        )

        let projection = RecordingPresentationMapper.map(
            .recoveryRequired(RecordingRecoveryCatalog(items: [item]))
        )

        XCTAssertFalse(projection.recoveryItems[0].canSeal)
        XCTAssertFalse(projection.recoveryItems[0].canDiscard)
        XCTAssertEqual(projection.recoveryItems[0].statusText, "Requires a newer Audora")
        XCTAssertTrue(projection.detail?.contains("preserved read-only") == true)
    }

    func testModelPostsSemanticAnnouncementOnceAndSendsTypedCommands() async throws {
        let snapshot = RecordingSnapshot(
            recordingID: try recordingID(),
            sessionID: try sessionID(),
            elapsedFrames: CanonicalRecordingLimits.fiveMinuteWarningFrame,
            level: .measured(0.3),
            mute: .live,
            noticeID: 42
        )
        let feature = ScriptedRecordingFeature(
            states: [
                .active(snapshot, confirmation: .none),
                .active(snapshot, confirmation: .none),
            ]
        )
        let poster = RecordingAnnouncementRecorder()
        let model = RecordingPresentationModel(feature: feature, announcements: poster)
        await model.start()
        XCTAssertEqual(poster.values, ["5 minutes remaining"])

        model.send(.stop)
        for _ in 0..<20 { await Task.yield() }
        let commands = await feature.commands
        XCTAssertEqual(commands, [.stop])
    }
}

private actor ScriptedRecordingFeature: RecordingFeature {
    nonisolated let states: AsyncStream<RecordingFeatureState>
    nonisolated let sealedSessions = SessionSealedNotifications.finished
    private let state: RecordingFeatureState
    private(set) var commands: [RecordingCommand] = []

    init(states: [RecordingFeatureState]) {
        state = states.last ?? .idle
        self.states = AsyncStream { continuation in
            for state in states { continuation.yield(state) }
            continuation.finish()
        }
    }

    var currentState: RecordingFeatureState { state }
    func send(_ command: RecordingCommand) { commands.append(command) }
    func shutdown() {}
}

@MainActor
private final class RecordingAnnouncementRecorder: AccessibilityAnnouncementPosting {
    private(set) var values: [String] = []
    func post(_ announcement: String) { values.append(announcement) }
}

private func recordingID() throws -> RecordingID {
    try RecordingID("rec-20260830T120000000Z-2ABC")
}

private func sessionID() throws -> SessionID {
    try SessionID("ses-20260830T120000000Z-3DEF")
}

private func libraryID() throws -> LibraryID {
    try LibraryID("lib-20260830T120000000Z-1ABC")
}
