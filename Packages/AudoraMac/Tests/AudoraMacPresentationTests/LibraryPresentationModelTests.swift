import AudoraApplication
import AudoraDomain
import AudoraMacPresentation
import XCTest

@MainActor
final class LibraryPresentationModelTests: XCTestCase {
    func testStartSendsOneTypedCommandAndProjectsTheFinalSnapshot() async {
        let feature = ScriptedLibraryFeature(
            snapshots: [
                LibraryFeatureState(selection: .awaitingBootstrap),
                LibraryFeatureState(
                    selection: .noLibrarySelected(recentAvailable: false)
                ),
            ]
        )
        let model = LibraryPresentationModel(feature: feature)

        await model.start()
        await model.start()

        XCTAssertEqual(
            model.snapshot,
            LibraryFeatureState(
                selection: .noLibrarySelected(recentAvailable: false)
            )
        )
        let commands = await feature.commands
        XCTAssertEqual(commands, [.start])
    }

    func testRepeatedOpenFocusesAndReopensTheSameSingletonWindowIdentity() {
        let access = FakeMainWindowAccess()
        let coordinator = MainWindowCoordinator(access: access)
        let originalIdentity = access.mainWindowIdentity
        coordinator.registerReopenAction { access.restoreExistingWindow() }

        let first = coordinator.focusExistingMainWindow()
        let second = coordinator.focusExistingMainWindow()
        access.simulateClosedWindow()
        let reopened = coordinator.focusExistingMainWindow()

        XCTAssertEqual(first, originalIdentity)
        XCTAssertEqual(second, originalIdentity)
        XCTAssertEqual(reopened, originalIdentity)
        XCTAssertEqual(access.focusCount, 3)
        XCTAssertEqual(access.reopenCount, 1)
        XCTAssertEqual(access.windowConstructionCount, 1)
    }

    func testRootInteractionPolicyKeepsRevealAvailableDuringRecordingAndImport() throws {
        let libraryID = try LibraryID("lib-20260830T120000000Z-1ABC")
        let library = LibraryFeatureState(
            selection: .active(
                ActiveLibrarySnapshot(
                    libraryID: libraryID,
                    preferences: .defaults,
                    profile: .nullProfile(statementCount: 0)
                )
            )
        )
        let recording = RecordingFeatureState.active(
            RecordingSnapshot(
                recordingID: try RecordingID("rec-20260830T120000000Z-2ABC"),
                sessionID: try SessionID("ses-20260830T120000000Z-3DEF"),
                elapsedFrames: 16_000,
                level: .measured(0.25),
                mute: .live,
                noticeID: 1
            ),
            confirmation: .none
        )

        let duringRecording = LibraryInteractionPolicy.availability(
            library: library,
            audioImport: AudioImportFeatureState(status: .idle),
            recording: recording
        )
        XCTAssertTrue(duringRecording.canRevealLibrary)
        XCTAssertFalse(duringRecording.canMutateLibrarySelection)
        XCTAssertFalse(duringRecording.canUseAudioImportControls)
        XCTAssertTrue(duringRecording.canUseRecordingControls)

        let duringImport = LibraryInteractionPolicy.availability(
            library: library,
            audioImport: AudioImportFeatureState(status: .copying),
            recording: .idle
        )
        XCTAssertTrue(duringImport.canRevealLibrary)
        XCTAssertFalse(duringImport.canMutateLibrarySelection)
        XCTAssertTrue(duringImport.canUseAudioImportControls)
        XCTAssertFalse(duringImport.canUseRecordingControls)
    }
}

private actor ScriptedLibraryFeature: LibraryFeature {
    nonisolated let states: AsyncStream<LibraryFeatureState>

    private let state: LibraryFeatureState
    private(set) var commands: [LibraryCommand] = []

    init(snapshots: [LibraryFeatureState]) {
        state = snapshots.last ?? LibraryFeatureState(selection: .awaitingBootstrap)
        states = AsyncStream { continuation in
            for snapshot in snapshots {
                continuation.yield(snapshot)
            }
            continuation.finish()
        }
    }

    var currentState: LibraryFeatureState {
        state
    }

    func send(_ command: LibraryCommand) async {
        commands.append(command)
    }
}

@MainActor
private final class FakeMainWindowAccess: MainWindowAccess {
    private let originalWindow = NSObject()
    private var installed = true
    private(set) var focusCount = 0
    private(set) var reopenCount = 0
    private(set) var windowConstructionCount = 1

    var mainWindowIdentity: ObjectIdentifier? {
        installed ? ObjectIdentifier(originalWindow) : nil
    }

    func focusMainWindow() {
        focusCount += 1
    }

    func simulateClosedWindow() {
        installed = false
    }

    func restoreExistingWindow() {
        reopenCount += 1
        installed = true
    }
}
