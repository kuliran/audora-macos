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

    func testLibrarySelectionWaitsForSuspendedDraftFlushBeforeSendingCommand() async {
        let chat = SuspendedNavigationChatFeature()
        let library = ScriptedLibraryFeature(
            snapshots: [LibraryFeatureState(selection: .awaitingBootstrap)]
        )
        let chatDispatcher = ChatCommandDispatcher(feature: chat)
        let selection = DefaultLibrarySelectionFeature(library: library, chat: chat)
        let dispatcher = LibrarySelectionCommandDispatcher(
            feature: selection,
            chatDispatcher: chatDispatcher
        )

        let navigation = dispatcher.enqueue(.close)
        XCTAssertTrue(chatDispatcher.isLibraryNavigationPending)
        await chat.waitUntilFlushIsSuspended()

        let commandsWhileFlushIsSuspended = await library.commands
        XCTAssertEqual(commandsWhileFlushIsSuspended, [])

        await chat.resumeFlush(succeeded: true)
        let navigationSucceeded = await navigation.value
        let commandsAfterFlush = await library.commands
        XCTAssertTrue(navigationSucceeded)
        XCTAssertEqual(commandsAfterFlush, [.close])
        XCTAssertFalse(chatDispatcher.isLibraryNavigationPending)
    }

    func testFailedDraftFlushRejectsExternalLibraryReplacement() async throws {
        let chat = SuspendedNavigationChatFeature()
        let library = ScriptedLibraryFeature(
            snapshots: [LibraryFeatureState(selection: .awaitingBootstrap)]
        )
        let chatDispatcher = ChatCommandDispatcher(feature: chat)
        let selection = DefaultLibrarySelectionFeature(library: library, chat: chat)
        let dispatcher = LibrarySelectionCommandDispatcher(
            feature: selection,
            chatDispatcher: chatDispatcher
        )
        let token = try XCTUnwrap(LibraryOpenRequestToken("external_1"))

        let navigation = dispatcher.enqueue(.openExternal(token))
        XCTAssertTrue(chatDispatcher.isLibraryNavigationPending)
        await chat.waitUntilFlushIsSuspended()
        await chat.resumeFlush(succeeded: false)

        let navigationSucceeded = await navigation.value
        let commandsAfterFailedFlush = await library.commands
        XCTAssertFalse(navigationSucceeded)
        XCTAssertEqual(commandsAfterFailedFlush, [])
        XCTAssertFalse(chatDispatcher.isLibraryNavigationPending)
    }

    func testDraftEditCannotCrossFlushToLibraryCommandBoundary() async throws {
        let chat = RecordingNavigationChatFeature()
        let chatDispatcher = ChatCommandDispatcher(feature: chat)
        let library = SuspendedLibrarySelectionFeature()
        let selection = DefaultLibrarySelectionFeature(library: library, chat: chat)
        let dispatcher = LibrarySelectionCommandDispatcher(
            feature: selection,
            chatDispatcher: chatDispatcher
        )
        let context = ChatCommandContext(
            libraryScope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        let chatID = try ChatID("cht-20260830T120000000Z-2ABC")
        let draftID = try ChatDraftID("drf-20260830T120000000Z-3DEF")

        let navigation = dispatcher.enqueue(.close)
        await library.waitUntilCommandIsSuspended()
        let lateEdit = chatDispatcher.enqueue(
            .editDraft(context, chatID, draftID, text: "must not cross Libraries")
        )
        let deferredStart = chatDispatcher.enqueue(.start(context))
        await lateEdit.value

        let chatCommandsBeforeLibraryChange = await chat.commands
        XCTAssertTrue(chatDispatcher.isLibraryNavigationPending)
        XCTAssertEqual(chatCommandsBeforeLibraryChange, [])

        await library.resumeCommand()
        let navigationSucceeded = await navigation.value
        await deferredStart.value
        let chatCommandsAfterLibraryChange = await chat.commands
        XCTAssertTrue(navigationSucceeded)
        XCTAssertFalse(chatDispatcher.isLibraryNavigationPending)
        XCTAssertEqual(chatCommandsAfterLibraryChange, [.start(context)])
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

private actor SuspendedNavigationChatFeature: ChatFeature {
    nonisolated let states = AsyncStream<ChatFeatureState> { _ in }

    private var flushContinuation: CheckedContinuation<Bool, Never>?

    var currentState: ChatFeatureState {
        ChatFeatureState(catalog: .loading)
    }

    func currentState(in scope: LibraryScope) -> ChatFeatureState? {
        nil
    }

    func send(_ command: ChatCommand) async {}

    func flushForOrderlyTermination() async -> Bool {
        await withCheckedContinuation { continuation in
            flushContinuation = continuation
        }
    }

    func waitUntilFlushIsSuspended() async {
        while flushContinuation == nil { await Task.yield() }
    }

    func resumeFlush(succeeded: Bool) {
        flushContinuation?.resume(returning: succeeded)
        flushContinuation = nil
    }
}

private actor RecordingNavigationChatFeature: ChatFeature {
    nonisolated let states = AsyncStream<ChatFeatureState> { _ in }

    private(set) var commands: [ChatCommand] = []

    var currentState: ChatFeatureState {
        ChatFeatureState(catalog: .loading)
    }

    func currentState(in scope: LibraryScope) -> ChatFeatureState? {
        nil
    }

    func send(_ command: ChatCommand) {
        commands.append(command)
    }

    func flushForOrderlyTermination() -> Bool {
        true
    }
}

private actor SuspendedLibrarySelectionFeature: LibraryFeature {
    nonisolated let states = AsyncStream<LibraryFeatureState> { _ in }

    private var commandContinuation: CheckedContinuation<Void, Never>?

    var currentState: LibraryFeatureState {
        LibraryFeatureState(selection: .awaitingBootstrap)
    }

    func send(_ command: LibraryCommand) async {
        await withCheckedContinuation { continuation in
            commandContinuation = continuation
        }
    }

    func waitUntilCommandIsSuspended() async {
        while commandContinuation == nil { await Task.yield() }
    }

    func resumeCommand() {
        commandContinuation?.resume()
        commandContinuation = nil
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
