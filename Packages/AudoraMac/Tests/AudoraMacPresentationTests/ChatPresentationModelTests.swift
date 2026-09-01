import AudoraApplication
import AudoraDomain
@testable import AudoraMacPresentation
import Foundation
import XCTest

@MainActor
final class ChatPresentationModelTests: XCTestCase {
    func testInvocationControlPresentationExposesTheSameUnavailableReasonWithoutHover() throws {
        let reopensAt = try UTCInstant("2026-08-30T12:01:00.000Z")

        XCTAssertEqual(
            ChatInvocationAdmissionPresentation.unavailableReason(
                for: .cooldown(reopensAt: reopensAt)
            ),
            "Coach admission reopens at 2026-08-30T12:01:00.000Z."
        )
        XCTAssertEqual(
            ChatInvocationAdmissionPresentation.unavailableReason(for: .unavailable),
            "Coach admission availability could not be checked."
        )
        XCTAssertNil(
            ChatInvocationAdmissionPresentation.unavailableReason(for: .available)
        )
    }

    func testStartScopesTheFeatureAndPublishesItsInitialSnapshot() async throws {
        let state = ChatFeatureState(catalog: .ready(ChatCatalogSnapshot(allRows: [], visibleRows: [])))
        let feature = RecordingPresentationChatFeature(initial: state)
        let model = makeChatPresentationModel(feature: feature)
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )

        await model.start(in: scope)

        XCTAssertEqual(model.snapshot, state)
        let commands = await feature.commands
        let context = try XCTUnwrap(startContexts(in: commands).first)
        XCTAssertEqual(commands, [.start(context)])
        XCTAssertEqual(context.libraryScope, scope)
    }

    func testFilterInputDispatchesOnlyValidatedPureFilterCommands() async throws {
        let state = ChatFeatureState(
            catalog: .ready(ChatCatalogSnapshot(allRows: [], visibleRows: []))
        )
        let feature = RecordingPresentationChatFeature(initial: state)
        let model = makeChatPresentationModel(feature: feature)
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        await model.start(in: scope)
        let startCommands = await feature.commands
        let context = try XCTUnwrap(startContexts(in: startCommands).first)

        model.updateFilter("reflection")
        await waitForCommandCount(2, in: feature)
        let validCommands = await feature.commands
        XCTAssertEqual(
            validCommands,
            [.start(context), .setFilter(context, try ChatFilterQuery("reflection"))]
        )

        model.updateFilter("unsafe\u{0000}filter")
        await Task.yield()
        let commandsAfterInvalidInput = await feature.commands
        XCTAssertEqual(commandsAfterInvalidInput, validCommands)
    }

    func testUserActionsCaptureTheCurrentLibraryCommandContext() async throws {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let chatID = try ChatID("cht-20260830T120000000Z-2ABC")
        let aggregate = try aggregate(
            in: scope,
            chatID: chatID.rawValue,
            draftID: "drf-20260830T120000000Z-3DEF",
            memoryID: "mem-20260830T120000000Z-4GHJ",
            title: "New Chat"
        )
        let row = ChatRowSnapshot(aggregate: aggregate)
        let state = ChatFeatureState(
            catalog: .ready(ChatCatalogSnapshot(allRows: [row], visibleRows: [row])),
            selection: .open(aggregate),
            composer: .editable(aggregate.chat.draft, isDirty: false)
        )
        let feature = RecordingPresentationChatFeature(initial: state)
        let model = makeChatPresentationModel(feature: feature)
        await model.start(in: scope)
        let startCommands = await feature.commands
        let context = try XCTUnwrap(startContexts(in: startCommands).first)

        model.createDevelopmentChat()
        await waitForCommandCount(2, in: feature)
        model.open(chatID)
        await waitForCommandCount(3, in: feature)
        model.rename(chatID, title: "Focused Practice", expectedRevision: 4)
        await waitForCommandCount(4, in: feature)
        model.updateDraft("A synthetic coaching Draft")
        await waitForCommandCount(5, in: feature)
        model.refreshContextQuote()
        await waitForCommandCount(6, in: feature)
        model.sendDraft()
        await waitForCommandCount(7, in: feature)
        let pendingID = try PendingUserTurnID("ptu-20260830T120000000Z-5KMN")
        model.retryPendingUserTurn(pendingID)
        await waitForCommandCount(8, in: feature)
        model.createNewChatFromCapacityFailure(pendingID)
        await waitForCommandCount(9, in: feature)
        model.discardPendingUserTurn(pendingID)
        await waitForCommandCount(10, in: feature)

        let commands = await feature.commands
        XCTAssertEqual(
            commands,
            [
                .start(context),
                .createDevelopmentChat(context),
                .open(context, chatID),
                .rename(context, chatID, title: "Focused Practice", expectedRevision: 4),
                .editDraft(
                    context,
                    aggregate.chat.id,
                    aggregate.chat.draft.draftID,
                    text: "A synthetic coaching Draft"
                ),
                .refreshContextQuote(
                    context,
                    aggregate.chat.id,
                    aggregate.chat.draft
                ),
                .sendDraft(context, aggregate.chat.id, aggregate.chat.draft),
                .retryPendingUserTurn(context, pendingID),
                .createNewChatFromCapacityFailure(context, pendingID),
                .discardPendingUserTurn(context, pendingID),
            ]
        )
    }

    func testRenameEditorTaskIdentityChangesBetweenRevisionZeroChats() throws {
        let first = ChatRenameEditorTaskID(
            chatID: try ChatID("cht-20260830T120000000Z-2ABC"),
            manifestRevision: 0
        )
        let second = ChatRenameEditorTaskID(
            chatID: try ChatID("cht-20260830T120100000Z-5KMN"),
            manifestRevision: 0
        )

        XCTAssertNotEqual(first, second)
    }

    func testEveryChatNoticeAccessibilityLabelContainsItsHumanRecoveryText() {
        let notices: [ChatNotice] = [
            .invalidTitle,
            .createFailed,
            .createCollisionLimitReached,
            .renameFailed,
            .staleRename,
            .chatMissing,
            .chatOpenFailed,
            .chatFrozen,
            .catalogFailed,
            .readOnlyLibrary,
            .coachContextUnavailable,
            .messageMustBeShortened,
        ]

        for notice in notices {
            let recoveryText = ChatNoticePresentation.recoveryText(for: notice)
            XCTAssertEqual(
                ChatNoticePresentation.accessibilityLabel(for: notice),
                "Chat notice: \(recoveryText)",
                notice.rawValue
            )
        }
    }

    func testCoachContextPresentationExplainsAllNineNonadditiveCategories() {
        XCTAssertEqual(
            CoachContextQuotePresentation.summary(
                completeInputTokens: 642,
                inputCeilingTokens: 4_032
            ),
            "~642 / 4032 input tokens"
        )
        XCTAssertEqual(
            CoachContextCostCategory.allCases.map(
                CoachContextQuotePresentation.categoryLabel
            ),
            [
                "Profile", "Coach Memory", "Prior chat history", "Current Draft",
                "Provider framing", "Attachments", "Transcript exchange reserve",
                "Response reserve", "Safety margin",
            ]
        )
    }

    func testLaterScopeWinsWhenOlderStateSubscriptionIsSuspended() async throws {
        let firstScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let secondScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T121000000Z-3DEF")
        )
        let latestState = ChatFeatureState(notice: .catalogFailed)
        let feature = SuspendedInitialPresentationChatFeature(latestState: latestState)
        let model = makeChatPresentationModel(feature: feature)

        let firstStart = Task { await model.start(in: firstScope) }
        await feature.waitForSubscriptionCount(1)
        let secondStart = Task { await model.start(in: secondScope) }
        await feature.waitForCommandCount(2)
        await feature.resumeFirstSubscription(with: ChatFeatureState(notice: .createFailed))
        await firstStart.value
        await secondStart.value

        XCTAssertEqual(model.snapshot, latestState)
        let commands = await feature.commands
        let contexts = startContexts(in: commands)
        XCTAssertEqual(contexts.map(\.libraryScope), [firstScope, secondScope])
        XCTAssertEqual(Set(contexts.map(\.generation)).count, 2)
    }

    func testRecreatedModelsFenceDelayedOldActionAcrossAtoBtoAVisits() async throws {
        let firstScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let secondScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T121000000Z-3DEF")
        )
        let feature = SuspendedOldActionPresentationChatFeature()
        let firstVisit = makeChatPresentationModel(feature: feature)
        await firstVisit.start(in: firstScope)
        firstVisit.updateFilter("stale first visit")
        await feature.waitForFilterSuspension()

        let secondVisit = makeChatPresentationModel(feature: feature)
        await secondVisit.start(in: secondScope)
        let returnedVisit = makeChatPresentationModel(feature: feature)
        await returnedVisit.start(in: firstScope)

        await feature.resumeFilter()
        await feature.waitForFilterCompletion()

        let commands = await feature.commands
        let contexts = startContexts(in: commands)
        XCTAssertEqual(
            contexts.map(\.libraryScope),
            [firstScope, secondScope, firstScope]
        )
        XCTAssertEqual(Set(contexts.map(\.generation)).count, 3)
        XCTAssertNotEqual(contexts.first, contexts.last)
        let returnedState = await feature.currentState(in: firstScope)
        let state = try XCTUnwrap(returnedState)
        XCTAssertEqual(state.filterQuery, .empty)
    }

    func testLibrarySwitchImmediatelyHidesPriorTitlesWhileNextCatalogLoadSuspends() async throws {
        let firstScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let secondScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T121000000Z-3DEF")
        )
        let firstAggregate = try aggregate(
            in: firstScope,
            chatID: "cht-20260830T120000000Z-2ABC",
            draftID: "drf-20260830T120000000Z-3DEF",
            memoryID: "mem-20260830T120000000Z-4GHJ",
            title: "First Library Chat"
        )
        let secondAggregate = try aggregate(
            in: secondScope,
            chatID: "cht-20260830T121000000Z-5KMN",
            draftID: "drf-20260830T121000000Z-6PQR",
            memoryID: "mem-20260830T121000000Z-7STV",
            title: "Second Library Chat"
        )
        let firstState = readyState(
            for: firstAggregate,
            filterQuery: try ChatFilterQuery("First"),
            selection: .open(firstAggregate)
        )
        let secondState = readyState(for: secondAggregate)
        let feature = SuspendedLibrarySwitchPresentationChatFeature(
            firstScope: firstScope,
            secondScope: secondScope,
            firstState: firstState,
            secondState: secondState
        )
        let model = makeChatPresentationModel(feature: feature)

        await model.start(in: firstScope)
        model.filterText = "First"
        let switchTask = Task { await model.start(in: secondScope) }
        await feature.waitForSecondLoadSuspension()

        XCTAssertEqual(
            model.snapshot,
            ChatFeatureState(catalog: .loading, filterQuery: .empty, selection: .none)
        )
        XCTAssertEqual(model.filterText, "")
        if case let .ready(catalog) = model.snapshot.catalog {
            XCTFail("Leaked prior-Library titles: \(catalog.visibleRows.compactMap(\.title))")
        }

        await feature.resumeSecondLoad()
        await switchTask.value

        XCTAssertEqual(model.snapshot, secondState)
        let commands = await feature.commands
        let contexts = startContexts(in: commands)
        XCTAssertEqual(contexts.map(\.libraryScope), [firstScope, secondScope])
        XCTAssertEqual(Set(contexts.map(\.generation)).count, 2)
    }

    func testLateSubscriptionReconcilesReadyStateAfterMissingLoading() async throws {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T121000000Z-3DEF")
        )
        let aggregate = try aggregate(
            in: scope,
            chatID: "cht-20260830T121000000Z-5KMN",
            draftID: "drf-20260830T121000000Z-6PQR",
            memoryID: "mem-20260830T121000000Z-7STV",
            title: "Late Library Chat"
        )
        let ready = readyState(for: aggregate)
        let feature = LateSubscriptionPresentationChatFeature(finalState: ready)
        let model = makeChatPresentationModel(feature: feature)

        let start = Task { await model.start(in: scope) }
        await feature.waitForStart()
        await feature.completeLateSubscription()
        await start.value

        XCTAssertEqual(model.snapshot, ready)
        let commands = await feature.commands
        let context = try XCTUnwrap(startContexts(in: commands).first)
        XCTAssertEqual(commands, [.start(context)])
        XCTAssertEqual(context.libraryScope, scope)
    }

    func testLateSubscriptionReconcilesFailedStateAfterMissingLoading() async throws {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T121100000Z-4GHJ")
        )
        let failed = ChatFeatureState(catalog: .failed, notice: .catalogFailed)
        let feature = LateSubscriptionPresentationChatFeature(finalState: failed)
        let model = makeChatPresentationModel(feature: feature)

        let start = Task { await model.start(in: scope) }
        await feature.waitForStart()
        await feature.completeLateSubscription()
        await start.value

        XCTAssertEqual(model.snapshot, failed)
        let commands = await feature.commands
        let context = try XCTUnwrap(startContexts(in: commands).first)
        XCTAssertEqual(commands, [.start(context)])
        XCTAssertEqual(context.libraryScope, scope)
    }

    private func waitForCommandCount(
        _ count: Int,
        in feature: RecordingPresentationChatFeature
    ) async {
        while await feature.commands.count < count { await Task.yield() }
    }

    private func startContexts(in commands: [ChatCommand]) -> [ChatCommandContext] {
        commands.compactMap { command in
            guard case let .start(context) = command else { return nil }
            return context
        }
    }

    private func aggregate(
        in scope: LibraryScope,
        chatID: String,
        draftID: String,
        memoryID: String,
        title: String
    ) throws -> ChatAggregate {
        let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
        let seed = try NewDevelopmentChatSeed(
            library: scope,
            chatID: ChatID(chatID),
            draftID: ChatDraftID(draftID),
            memoryID: CoachMemoryID(memoryID),
            instant: instant,
            profileStatementGeneration: 7
        )
        return try RenameChatMutation(
            library: scope,
            base: seed.aggregate,
            title: ChatTitle(title),
            updatedAt: instant
        ).replacement
    }

    private func readyState(
        for aggregate: ChatAggregate,
        filterQuery: ChatFilterQuery = .empty,
        selection: ChatFeatureState.Selection = .none
    ) -> ChatFeatureState {
        let row = ChatRowSnapshot(aggregate: aggregate)
        return ChatFeatureState(
            catalog: .ready(ChatCatalogSnapshot(allRows: [row], visibleRows: [row])),
            filterQuery: filterQuery,
            selection: selection
        )
    }
}

@MainActor
private func makeChatPresentationModel(
    feature: any ChatFeature
) -> ChatPresentationModel {
    let application = DefaultApplicationCommandFeature(
        library: PassivePresentationLibraryFeature(),
        chat: feature
    )
    return ChatPresentationModel(
        dispatcher: ChatCommandDispatcher(feature: application)
    )
}

private actor PassivePresentationLibraryFeature: LibraryFeature {
    nonisolated let states = AsyncStream<LibraryFeatureState> { continuation in
        continuation.finish()
    }

    var currentState: LibraryFeatureState {
        LibraryFeatureState(selection: .awaitingBootstrap)
    }

    func send(_ command: LibraryCommand) async {}
}

private actor SuspendedOldActionPresentationChatFeature: ChatFeature {
    nonisolated var states: AsyncStream<ChatFeatureState> {
        AsyncStream { continuation in continuation.finish() }
    }

    private var state = ChatFeatureState(
        catalog: .ready(ChatCatalogSnapshot(allRows: [], visibleRows: []))
    )
    private var activeContext: ChatCommandContext?
    private var filterContinuation: CheckedContinuation<Void, Never>?
    private var filterIsSuspended = false
    private var filterIsComplete = false
    private(set) var commands: [ChatCommand] = []

    var currentState: ChatFeatureState { state }

    func currentState(in scope: LibraryScope) -> ChatFeatureState? {
        activeContext?.libraryScope == scope ? state : nil
    }

    func flushForOrderlyTermination() async -> Bool { true }

    func send(_ command: ChatCommand) async {
        commands.append(command)
        switch command {
        case let .start(context):
            activeContext = context
            state = ChatFeatureState(
                catalog: .ready(ChatCatalogSnapshot(allRows: [], visibleRows: []))
            )
        case let .setFilter(context, query):
            filterIsSuspended = true
            await withCheckedContinuation { filterContinuation = $0 }
            if context == activeContext {
                state = ChatFeatureState(
                    catalog: state.catalog,
                    filterQuery: query,
                    selection: state.selection
                )
            }
            filterIsComplete = true
        case .createDevelopmentChat, .rename, .open, .editDraft,
             .refreshContextQuote, .sendDraft,
             .retryPendingUserTurn, .createNewChatFromCapacityFailure,
             .discardPendingUserTurn:
            break
        }
    }

    func waitForFilterSuspension() async {
        while !filterIsSuspended { await Task.yield() }
    }

    func resumeFilter() {
        filterContinuation?.resume()
        filterContinuation = nil
    }

    func waitForFilterCompletion() async {
        while !filterIsComplete { await Task.yield() }
    }
}

private actor RecordingPresentationChatFeature: ChatFeature {
    nonisolated var states: AsyncStream<ChatFeatureState> { streams.makeStream() }

    private nonisolated let streams: RecordingPresentationStateStreams
    private let state: ChatFeatureState
    private var activeScope: LibraryScope?
    private(set) var commands: [ChatCommand] = []

    init(initial: ChatFeatureState = ChatFeatureState()) {
        state = initial
        streams = RecordingPresentationStateStreams(state: initial)
    }

    var currentState: ChatFeatureState { state }

    func currentState(in scope: LibraryScope) -> ChatFeatureState? {
        activeScope == scope ? state : nil
    }

    func flushForOrderlyTermination() async -> Bool { true }

    func send(_ command: ChatCommand) {
        commands.append(command)
        if case let .start(context) = command {
            activeScope = context.libraryScope
            streams.publishStart()
        }
    }
}

private final class RecordingPresentationStateStreams: @unchecked Sendable {
    private let lock = NSLock()
    private let state: ChatFeatureState
    private var continuation: AsyncStream<ChatFeatureState>.Continuation?

    init(state: ChatFeatureState) {
        self.state = state
    }

    func makeStream() -> AsyncStream<ChatFeatureState> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
            continuation.yield(state)
        }
    }

    func publishStart() {
        let continuation = lock.withLock { () -> AsyncStream<ChatFeatureState>.Continuation? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.yield(ChatFeatureState(catalog: .loading))
        continuation?.yield(state)
        continuation?.finish()
    }
}

private actor SuspendedInitialPresentationChatFeature: ChatFeature {
    nonisolated var states: AsyncStream<ChatFeatureState> { streams.makeStream() }

    private nonisolated let streams: SequencedPresentationStateStreams
    private let latestState: ChatFeatureState
    private var activeScope: LibraryScope?
    private(set) var commands: [ChatCommand] = []

    init(latestState: ChatFeatureState) {
        self.latestState = latestState
        streams = SequencedPresentationStateStreams(latestState: latestState)
    }

    var currentState: ChatFeatureState { latestState }

    func currentState(in scope: LibraryScope) -> ChatFeatureState? {
        activeScope == scope ? latestState : nil
    }

    func flushForOrderlyTermination() async -> Bool { true }

    func send(_ command: ChatCommand) {
        commands.append(command)
        if case let .start(context) = command {
            activeScope = context.libraryScope
        }
    }

    func waitForSubscriptionCount(_ count: Int) async {
        while streams.subscriptionCount < count { await Task.yield() }
    }

    func waitForCommandCount(_ count: Int) async {
        while commands.count < count { await Task.yield() }
    }

    func resumeFirstSubscription(with state: ChatFeatureState) {
        streams.finishFirst(with: state)
    }
}

private final class SequencedPresentationStateStreams: @unchecked Sendable {
    private let lock = NSLock()
    private let latestState: ChatFeatureState
    private var nextSubscription = 0
    private var firstContinuation: AsyncStream<ChatFeatureState>.Continuation?

    init(latestState: ChatFeatureState) {
        self.latestState = latestState
    }

    var subscriptionCount: Int {
        lock.withLock { nextSubscription }
    }

    func makeStream() -> AsyncStream<ChatFeatureState> {
        let subscription = lock.withLock { () -> Int in
            defer { nextSubscription += 1 }
            return nextSubscription
        }
        return AsyncStream { continuation in
            if subscription == 0 {
                lock.withLock { firstContinuation = continuation }
            } else {
                continuation.yield(ChatFeatureState(catalog: .loading))
                continuation.yield(latestState)
                continuation.finish()
            }
        }
    }

    func finishFirst(with state: ChatFeatureState) {
        let continuation = lock.withLock { () -> AsyncStream<ChatFeatureState>.Continuation? in
            defer { firstContinuation = nil }
            return firstContinuation
        }
        continuation?.yield(state)
        continuation?.finish()
    }
}

private actor SuspendedLibrarySwitchPresentationChatFeature: ChatFeature {
    nonisolated var states: AsyncStream<ChatFeatureState> { streams.makeStream() }

    private nonisolated let streams: LibrarySwitchPresentationStateStreams
    private let firstScope: LibraryScope
    private let secondScope: LibraryScope
    private let secondState: ChatFeatureState
    private var state: ChatFeatureState
    private var activeScope: LibraryScope?
    private var secondLoadContinuation: CheckedContinuation<Void, Never>?
    private var secondLoadIsSuspended = false
    private(set) var commands: [ChatCommand] = []

    init(
        firstScope: LibraryScope,
        secondScope: LibraryScope,
        firstState: ChatFeatureState,
        secondState: ChatFeatureState
    ) {
        self.firstScope = firstScope
        self.secondScope = secondScope
        self.secondState = secondState
        state = firstState
        streams = LibrarySwitchPresentationStateStreams(firstState: firstState)
    }

    var currentState: ChatFeatureState { state }

    func currentState(in scope: LibraryScope) -> ChatFeatureState? {
        activeScope == scope ? state : nil
    }

    func flushForOrderlyTermination() async -> Bool { true }

    func send(_ command: ChatCommand) async {
        commands.append(command)
        guard case let .start(context) = command else { return }
        let scope = context.libraryScope
        activeScope = scope
        if scope == firstScope { return }
        guard scope == secondScope else { return }

        state = ChatFeatureState(catalog: .loading, filterQuery: .empty, selection: .none)
        streams.yield(state)
        secondLoadIsSuspended = true
        await withCheckedContinuation { continuation in
            secondLoadContinuation = continuation
        }
        state = secondState
        streams.yield(state)
        streams.finish()
    }

    func waitForSecondLoadSuspension() async {
        while !secondLoadIsSuspended { await Task.yield() }
    }

    func resumeSecondLoad() {
        secondLoadContinuation?.resume()
        secondLoadContinuation = nil
    }
}

private final class LibrarySwitchPresentationStateStreams: @unchecked Sendable {
    private let lock = NSLock()
    private let firstState: ChatFeatureState
    private var nextSubscription = 0
    private var activeContinuation: AsyncStream<ChatFeatureState>.Continuation?

    init(firstState: ChatFeatureState) {
        self.firstState = firstState
    }

    func makeStream() -> AsyncStream<ChatFeatureState> {
        let subscription = lock.withLock { () -> Int in
            defer { nextSubscription += 1 }
            return nextSubscription
        }
        return AsyncStream { continuation in
            continuation.yield(firstState)
            if subscription == 0 {
                continuation.finish()
            } else {
                lock.withLock { activeContinuation = continuation }
            }
        }
    }

    func yield(_ state: ChatFeatureState) {
        lock.withLock { activeContinuation }?.yield(state)
    }

    func finish() {
        let continuation = lock.withLock { () -> AsyncStream<ChatFeatureState>.Continuation? in
            defer { activeContinuation = nil }
            return activeContinuation
        }
        continuation?.finish()
    }
}

private actor LateSubscriptionPresentationChatFeature: ChatFeature {
    nonisolated var states: AsyncStream<ChatFeatureState> { stream.makeStream() }

    private nonisolated let stream = LatePresentationStateStream()
    private let finalState: ChatFeatureState
    private var activeScope: LibraryScope?
    private var pendingScope: LibraryScope?
    private(set) var commands: [ChatCommand] = []

    init(finalState: ChatFeatureState) {
        self.finalState = finalState
    }

    var currentState: ChatFeatureState { finalState }

    func currentState(in scope: LibraryScope) -> ChatFeatureState? {
        activeScope == scope ? finalState : nil
    }

    func flushForOrderlyTermination() async -> Bool { true }

    func send(_ command: ChatCommand) {
        commands.append(command)
        guard case let .start(context) = command else { return }
        pendingScope = context.libraryScope
    }

    func waitForStart() async {
        while commands.isEmpty { await Task.yield() }
    }

    func completeLateSubscription() {
        activeScope = pendingScope
        pendingScope = nil
        stream.finish(with: finalState)
    }
}

private final class LatePresentationStateStream: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<ChatFeatureState>.Continuation?

    func makeStream() -> AsyncStream<ChatFeatureState> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func finish(with state: ChatFeatureState) {
        let continuation = lock.withLock { () -> AsyncStream<ChatFeatureState>.Continuation? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.yield(state)
        continuation?.finish()
    }
}
