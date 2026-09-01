@testable import AudoraApplication
import AudoraDomain
import XCTest

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@MainActor
final class ApplicationCommandFeatureTests: XCTestCase {
    func testChatBoundaryAdmissionIsSynchronousAndRejectsLateDraftMutation() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedBoundaryChatFeature(trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)
        var admissionStates = feature.admissionStates.makeAsyncIterator()
        let initialAdmission = await admissionStates.next()
        XCTAssertEqual(initialAdmission, .idle)
        let context = ChatCommandContext(
            libraryScope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        let chatID = try ChatID("cht-20260830T120000000Z-2ABC")
        let draftID = try ChatDraftID("drf-20260830T120000000Z-3DEF")

        let boundary = feature.enqueue(.open(context, chatID))
        XCTAssertEqual(
            feature.admissionState,
            ApplicationCommandAdmissionState(isChatBoundaryPending: true)
        )
        let pendingAdmission = await admissionStates.next()
        XCTAssertEqual(pendingAdmission, feature.admissionState)
        await chat.waitUntilCommandStarts()

        let lateEdit = feature.enqueue(
            .editDraft(context, chatID, draftID, text: "must be rejected")
        )
        await lateEdit.value
        let commandsWhileSuspended = await chat.commands
        XCTAssertEqual(commandsWhileSuspended, [.open(context, chatID)])

        await chat.resume()
        await boundary.value
        XCTAssertEqual(feature.admissionState, .idle)
        let finalAdmission = await admissionStates.next()
        XCTAssertEqual(finalAdmission, .idle)
    }

    func testNewChatConfirmationBeginsAnApplicationBoundary() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedBoundaryChatFeature(trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)
        let context = ChatCommandContext(
            libraryScope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )

        let boundary = feature.enqueue(.confirmNewChat(context))

        XCTAssertTrue(feature.admissionState.isChatBoundaryPending)
        await chat.waitUntilCommandStarts()
        let commandsWhileSuspended = await chat.commands
        XCTAssertEqual(commandsWhileSuspended, [.confirmNewChat(context)])
        await chat.resume()
        await boundary.value
        XCTAssertEqual(feature.admissionState, .idle)
    }

    func testOneApplicationFIFOOrdersDraftSendDeferredStartAndTermination() async throws {
        let firstScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let secondScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T121000000Z-3DEF")
        )
        let firstContext = ChatCommandContext(libraryScope: firstScope, generation: 1)
        let secondContext = ChatCommandContext(libraryScope: secondScope, generation: 2)
        let chatID = try ChatID("cht-20260830T120000000Z-2ABC")
        let draft = try ChatDraft(
            draftID: ChatDraftID("drf-20260830T120000000Z-3DEF"),
            version: 0,
            text: "",
            updatedAt: UTCInstant("2026-08-30T12:00:00.000Z")
        )
        let trace = LibrarySelectionTrace()
        let chat = SuspendedOrderedApplicationChatFeature()
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)

        await feature.enqueue(.start(firstContext)).value
        let firstEdit = feature.enqueue(
            .editDraft(firstContext, chatID, draft.draftID, text: "A")
        )
        await chat.waitUntilFirstEditStarts()
        let secondEdit = feature.enqueue(
            .editDraft(firstContext, chatID, draft.draftID, text: "AB")
        )
        let send = feature.enqueue(.sendDraft(firstContext, chatID, draft))
        let deferredStart = feature.enqueue(.start(secondContext))
        let termination = feature.flushForOrderlyTermination()

        XCTAssertEqual(
            feature.admissionState,
            ApplicationCommandAdmissionState(
                isChatBoundaryPending: true,
                isOrderlyTerminationPending: true
            )
        )
        let commandsWhileSuspended = await chat.commands
        let flushesWhileSuspended = await chat.flushCallCount
        XCTAssertEqual(
            commandsWhileSuspended,
            [
                .start(firstContext),
                .editDraft(firstContext, chatID, draft.draftID, text: "A"),
            ]
        )
        XCTAssertEqual(flushesWhileSuspended, 0)

        await chat.resumeFirstEdit()
        await firstEdit.value
        await secondEdit.value
        await send.value
        await deferredStart.value
        let terminationSucceeded = await termination.value

        XCTAssertTrue(terminationSucceeded)
        let commands = await chat.commands
        XCTAssertEqual(
            commands,
            [
                .start(firstContext),
                .editDraft(firstContext, chatID, draft.draftID, text: "A"),
                .editDraft(firstContext, chatID, draft.draftID, text: "AB"),
                .sendDraft(firstContext, chatID, draft),
                .start(secondContext),
            ]
        )
        let finalFlushCount = await chat.flushCallCount
        XCTAssertEqual(finalFlushCount, 1)
    }

    func testSelectionFlushesChatBeforeSendingOneTypedLibraryIntent() async {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)

        let succeeded = await feature.enqueue(.close).value

        XCTAssertTrue(succeeded)
        let events = await trace.events
        XCTAssertEqual(events, ["chat.flush", "library.close"])
    }

    func testChatAndLibraryIntentsShareOneFIFOAndFenceLaterChatIngress() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedCrossFeatureChatFeature(trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)
        let edit = try makeEditCommand(text: "accepted before Library selection")
        let lateEdit = try makeEditCommand(text: "rejected after Library selection")

        let editReceipt = feature.enqueue(edit)
        await chat.waitUntilCommandStarts()
        let selectionReceipt = feature.enqueue(.close)
        await feature.enqueue(lateEdit).value

        let eventsWhileChatIsSuspended = await trace.events
        XCTAssertEqual(eventsWhileChatIsSuspended, ["chat.edit"])
        XCTAssertTrue(feature.admissionState.isLibraryNavigationPending)

        await chat.resume()
        await editReceipt.value
        let selectionSucceeded = await selectionReceipt.value

        XCTAssertTrue(selectionSucceeded)
        let events = await trace.events
        XCTAssertEqual(events, ["chat.edit", "chat.flush", "library.close"])
        let commands = await chat.commands
        XCTAssertEqual(commands, [edit])
    }

    func testFailedChatFlushRejectsLibrarySelectionInsideApplication() async {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: false, trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)

        let succeeded = await feature.enqueue(.chooseExisting).value

        XCTAssertFalse(succeeded)
        let events = await trace.events
        XCTAssertEqual(events, ["chat.flush"])
    }

    func testSelectionFencesLateChatIngressUntilLibrarySendCompletes() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let library = SuspendedSelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)
        let context = ChatCommandContext(
            libraryScope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        let chatID = try ChatID("cht-20260830T120000000Z-2ABC")
        let draftID = try ChatDraftID("drf-20260830T120000000Z-3DEF")

        let selection = feature.enqueue(.close)
        await library.waitUntilSendStarts()
        await feature.enqueue(
            .editDraft(context, chatID, draftID, text: "late edit")
        ).value
        await library.resume()

        let succeeded = await selection.value
        XCTAssertTrue(succeeded)
        let commands = await chat.commands
        XCTAssertTrue(commands.isEmpty, "late Chat ingress crossed the Application boundary")
    }

    func testSuccessfulTerminationFencesChatIngressDuringFlushAndAfterReturn() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedTerminationChatFeature(flushResult: true, trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)
        let edit = try makeEditCommand(text: "late edit")

        let termination = feature.flushForOrderlyTermination()
        await chat.waitUntilFlushStarts()
        await feature.enqueue(edit).value
        await chat.resume()

        let succeeded = await termination.value
        XCTAssertTrue(succeeded)
        await feature.enqueue(edit).value
        let selectionSucceeded = await feature.enqueue(.close).value

        XCTAssertFalse(selectionSucceeded)
        let commands = await chat.commands
        XCTAssertTrue(commands.isEmpty, "Chat ingress reopened after successful termination flush")
        let events = await trace.events
        XCTAssertEqual(events, ["chat.flush"])
    }

    func testFailedTerminationReopensChatIngressAfterRejectingCommandsDuringFlush() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedTerminationChatFeature(flushResult: false, trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)
        let edit = try makeEditCommand(text: "edit after failure")

        let termination = feature.flushForOrderlyTermination()
        await chat.waitUntilFlushStarts()
        await feature.enqueue(edit).value
        await chat.resume()

        let succeeded = await termination.value
        XCTAssertFalse(succeeded)
        await feature.enqueue(edit).value

        let commands = await chat.commands
        XCTAssertEqual(commands, [edit])
    }

    private func makeEditCommand(text: String) throws -> ChatCommand {
        let context = ChatCommandContext(
            libraryScope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        return try .editDraft(
            context,
            ChatID("cht-20260830T120000000Z-2ABC"),
            ChatDraftID("drf-20260830T120000000Z-3DEF"),
            text: text
        )
    }
}

private actor LibrarySelectionTrace {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

private actor SelectionChatFeature: ChatFeature {
    nonisolated let states = AsyncStream<ChatFeatureState> { continuation in
        continuation.finish()
    }

    private let flushResult: Bool
    private let trace: LibrarySelectionTrace
    private(set) var commands: [ChatCommand] = []

    init(flushResult: Bool, trace: LibrarySelectionTrace) {
        self.flushResult = flushResult
        self.trace = trace
    }

    var currentState: ChatFeatureState { ChatFeatureState() }

    func currentState(in scope: LibraryScope) -> ChatFeatureState? { nil }

    func send(_ command: ChatCommand) async {
        commands.append(command)
    }

    func flushForOrderlyTermination() async -> Bool {
        await trace.append("chat.flush")
        return flushResult
    }
}

private actor SuspendedBoundaryChatFeature: ChatFeature {
    nonisolated let states = AsyncStream<ChatFeatureState> { continuation in
        continuation.finish()
    }

    private let trace: LibrarySelectionTrace
    private var commandStarted = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var commands: [ChatCommand] = []

    init(trace: LibrarySelectionTrace) {
        self.trace = trace
    }

    var currentState: ChatFeatureState { ChatFeatureState() }

    func currentState(in scope: LibraryScope) -> ChatFeatureState? { nil }

    func send(_ command: ChatCommand) async {
        commands.append(command)
        commandStarted = true
        await withCheckedContinuation { continuation = $0 }
    }

    func flushForOrderlyTermination() async -> Bool { true }

    func waitUntilCommandStarts() async {
        while !commandStarted { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SuspendedOrderedApplicationChatFeature: ChatFeature {
    nonisolated let states = AsyncStream<ChatFeatureState> { continuation in
        continuation.finish()
    }

    private var firstEditStarted = false
    private var firstEditContinuation: CheckedContinuation<Void, Never>?
    private(set) var commands: [ChatCommand] = []
    private(set) var flushCallCount = 0

    var currentState: ChatFeatureState { ChatFeatureState() }

    func currentState(in scope: LibraryScope) -> ChatFeatureState? { nil }

    func send(_ command: ChatCommand) async {
        commands.append(command)
        guard case .editDraft = command, !firstEditStarted else { return }
        firstEditStarted = true
        await withCheckedContinuation { firstEditContinuation = $0 }
    }

    func flushForOrderlyTermination() async -> Bool {
        flushCallCount += 1
        return true
    }

    func waitUntilFirstEditStarts() async {
        while !firstEditStarted { await Task.yield() }
    }

    func resumeFirstEdit() {
        firstEditContinuation?.resume()
        firstEditContinuation = nil
    }
}

private actor SuspendedCrossFeatureChatFeature: ChatFeature {
    nonisolated let states = AsyncStream<ChatFeatureState> { continuation in
        continuation.finish()
    }

    private let trace: LibrarySelectionTrace
    private var commandStarted = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var commands: [ChatCommand] = []

    init(trace: LibrarySelectionTrace) {
        self.trace = trace
    }

    var currentState: ChatFeatureState { ChatFeatureState() }

    func currentState(in scope: LibraryScope) -> ChatFeatureState? { nil }

    func send(_ command: ChatCommand) async {
        commands.append(command)
        await trace.append("chat.edit")
        commandStarted = true
        await withCheckedContinuation { continuation = $0 }
    }

    func flushForOrderlyTermination() async -> Bool {
        await trace.append("chat.flush")
        return true
    }

    func waitUntilCommandStarts() async {
        while !commandStarted { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SuspendedTerminationChatFeature: ChatFeature {
    nonisolated let states = AsyncStream<ChatFeatureState> { continuation in
        continuation.finish()
    }

    private let flushResult: Bool
    private let trace: LibrarySelectionTrace
    private var flushStarted = false
    private var flushCount = 0
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var commands: [ChatCommand] = []

    init(flushResult: Bool, trace: LibrarySelectionTrace) {
        self.flushResult = flushResult
        self.trace = trace
    }

    var currentState: ChatFeatureState { ChatFeatureState() }

    func currentState(in scope: LibraryScope) -> ChatFeatureState? { nil }

    func send(_ command: ChatCommand) async {
        commands.append(command)
    }

    func flushForOrderlyTermination() async -> Bool {
        await trace.append("chat.flush")
        flushCount += 1
        guard flushCount == 1 else { return flushResult }
        flushStarted = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilFlushStarts() async {
        while !flushStarted { await Task.yield() }
    }

    func resume() {
        continuation?.resume(returning: flushResult)
        continuation = nil
    }
}

private actor SuspendedSelectionLibraryFeature: LibraryFeature {
    nonisolated let states = AsyncStream<LibraryFeatureState> { continuation in
        continuation.finish()
    }

    private let trace: LibrarySelectionTrace
    private var sendStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(trace: LibrarySelectionTrace) {
        self.trace = trace
    }

    var currentState: LibraryFeatureState {
        LibraryFeatureState(selection: .awaitingBootstrap)
    }

    func send(_ command: LibraryCommand) async {
        await trace.append("library.suspended")
        sendStarted = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilSendStarts() async {
        while !sendStarted { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SelectionLibraryFeature: LibraryFeature {
    nonisolated let states = AsyncStream<LibraryFeatureState> { continuation in
        continuation.finish()
    }

    private let trace: LibrarySelectionTrace

    init(trace: LibrarySelectionTrace) {
        self.trace = trace
    }

    var currentState: LibraryFeatureState {
        LibraryFeatureState(selection: .awaitingBootstrap)
    }

    func send(_ command: LibraryCommand) async {
        switch command {
        case .close:
            await trace.append("library.close")
        default:
            await trace.append("library.other")
        }
    }
}
