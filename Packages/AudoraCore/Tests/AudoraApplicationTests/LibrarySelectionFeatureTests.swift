@testable import AudoraApplication
import AudoraDomain
import XCTest

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class LibrarySelectionFeatureTests: XCTestCase {
    func testSelectionFlushesChatBeforeSendingOneTypedLibraryIntent() async {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultLibrarySelectionFeature(library: library, chat: chat)

        let succeeded = await feature.send(.close)

        XCTAssertTrue(succeeded)
        let events = await trace.events
        XCTAssertEqual(events, ["chat.flush", "library.close"])
    }

    func testFailedChatFlushRejectsLibrarySelectionInsideApplication() async {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: false, trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultLibrarySelectionFeature(library: library, chat: chat)

        let succeeded = await feature.send(.chooseExisting)

        XCTAssertFalse(succeeded)
        let events = await trace.events
        XCTAssertEqual(events, ["chat.flush"])
    }

    func testSelectionFencesLateChatIngressUntilLibrarySendCompletes() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let library = SuspendedSelectionLibraryFeature(trace: trace)
        let feature = DefaultLibrarySelectionFeature(library: library, chat: chat)
        let context = ChatCommandContext(
            libraryScope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        let chatID = try ChatID("cht-20260830T120000000Z-2ABC")
        let draftID = try ChatDraftID("drf-20260830T120000000Z-3DEF")

        async let selectionSucceeded = feature.send(.close)
        await library.waitUntilSendStarts()
        await feature.send(.editDraft(context, chatID, draftID, text: "late edit"))
        await library.resume()

        let succeeded = await selectionSucceeded
        XCTAssertTrue(succeeded)
        let commands = await chat.commands
        XCTAssertTrue(commands.isEmpty, "late Chat ingress crossed the Application boundary")
    }

    func testSuccessfulTerminationFencesChatIngressDuringFlushAndAfterReturn() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedTerminationChatFeature(flushResult: true, trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultLibrarySelectionFeature(library: library, chat: chat)
        let edit = try makeEditCommand(text: "late edit")

        async let terminationSucceeded = feature.flushForOrderlyTermination()
        await chat.waitUntilFlushStarts()
        await feature.send(edit)
        await chat.resume()

        let succeeded = await terminationSucceeded
        XCTAssertTrue(succeeded)
        await feature.send(edit)
        let selectionSucceeded = await feature.send(.close)

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
        let feature = DefaultLibrarySelectionFeature(library: library, chat: chat)
        let edit = try makeEditCommand(text: "edit after failure")

        async let terminationSucceeded = feature.flushForOrderlyTermination()
        await chat.waitUntilFlushStarts()
        await feature.send(edit)
        await chat.resume()

        let succeeded = await terminationSucceeded
        XCTAssertFalse(succeeded)
        await feature.send(edit)

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
