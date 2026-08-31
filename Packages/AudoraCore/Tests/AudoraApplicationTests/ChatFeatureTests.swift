@testable import AudoraApplication
import AudoraDomain
import XCTest

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class ChatFeatureTests: XCTestCase {
    func testDelayedCreateFromPreviousLibraryContextIsRejectedAfterSwitch() async {
        let store = RecordingChatStore()
        let feature = makeFeature(store: store)
        let firstContext = ChatCommandContext(
            libraryScope: Self.scope,
            generation: 1
        )
        let secondContext = ChatCommandContext(
            libraryScope: Self.secondScope,
            generation: 2
        )
        await feature.send(.start(firstContext))
        await feature.send(.start(secondContext))

        await feature.send(.createDevelopmentChat(firstContext))

        let calls = await store.calls
        XCTAssertEqual(calls, [.loadCatalog, .loadCatalog])
        let state = await feature.currentState
        XCTAssertNil(Self.openAggregate(in: state))
    }

    func testDelayedOlderStartCannotRestorePreviousLibraryAuthority() async {
        let store = RecordingChatStore()
        let feature = makeFeature(store: store)

        await feature.send(.start(Self.secondContext))
        await feature.send(.start(Self.context))

        let currentSecondState = await feature.currentState(in: Self.secondScope)
        let staleFirstState = await feature.currentState(in: Self.scope)
        XCTAssertNotNil(currentSecondState)
        XCTAssertNil(staleFirstState)
        let loadedScopes = await store.loadedScopes
        XCTAssertEqual(loadedScopes, [Self.secondScope])
    }

    func testCreateCommitsCanonicalEmptyDevelopmentChatBeforeSelectingIt() async throws {
        let store = RecordingChatStore()
        let feature = makeFeature(store: store)
        await feature.send(.start(Self.context))

        await feature.send(.createDevelopmentChat(Self.context))

        let seeds = await store.createSeeds
        let seed = try XCTUnwrap(seeds.first)
        XCTAssertEqual(seed.library, Self.scope)
        XCTAssertEqual(seed.aggregate, try Self.aggregate())
        let state = await feature.currentState
        XCTAssertEqual(state.selection, .open(seed.aggregate))
        XCTAssertEqual(
            try Self.rows(in: state).allRows.map(\.chatID),
            [seed.aggregate.chat.id]
        )
    }

    func testCreateRetriesOnlyCollisionsAndStopsAtBoundedLimit() async throws {
        let store = RecordingChatStore(createOutcomes: [.collision, .collision, .collision])
        let feature = makeFeature(store: store)
        await feature.send(.start(Self.context))

        await feature.send(.createDevelopmentChat(Self.context))

        let seedCount = await store.createSeeds.count
        let state = await feature.currentState
        XCTAssertEqual(seedCount, 3)
        XCTAssertEqual(state.notice, .createCollisionLimitReached)
    }

    func testCreateRebuildsAgainstTheProfileGenerationObservedAtInstall() async throws {
        let store = RecordingChatStore(
            createOutcomes: [.profileStatementGenerationChanged(9)]
        )
        let feature = makeFeature(store: store)
        await feature.send(.start(Self.context))

        await feature.send(.createDevelopmentChat(Self.context))

        let generations = await store.createSeeds.map(
            \.aggregate.chat.profileStatementGenerationAtCreation
        )
        XCTAssertEqual(generations, [7, 9])
        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state)?.chat.profileStatementGenerationAtCreation, 9)
    }

    func testProfileRebasesDoNotConsumeTheCollisionRetryBudget() async throws {
        let store = RecordingChatStore(
            createOutcomes: [
                .profileStatementGenerationChanged(8),
                .profileStatementGenerationChanged(9),
                .collision,
                .collision,
            ]
        )
        let feature = makeFeature(store: store)
        await feature.send(.start(Self.context))

        await feature.send(.createDevelopmentChat(Self.context))

        let seeds = await store.createSeeds
        XCTAssertEqual(seeds.count, 5)
        XCTAssertEqual(
            seeds.map(\.aggregate.chat.profileStatementGenerationAtCreation),
            [7, 8, 9, 9, 9]
        )
        let state = await feature.currentState
        XCTAssertNil(state.notice)
        XCTAssertNotNil(Self.openAggregate(in: state))
    }

    func testProfileRebaseLimitIsNotReportedAsCollisionExhaustion() async throws {
        let store = RecordingChatStore(
            createOutcomes: [
                .profileStatementGenerationChanged(8),
                .profileStatementGenerationChanged(9),
                .profileStatementGenerationChanged(10),
            ]
        )
        let feature = makeFeature(store: store)
        await feature.send(.start(Self.context))

        await feature.send(.createDevelopmentChat(Self.context))

        let state = await feature.currentState
        XCTAssertEqual(state.notice, .createFailed)
    }

    func testRenamePreservesIdentityAndOpenSelectionEvenWhenFilterHidesRow() async throws {
        let original = try Self.aggregate()
        let store = RecordingChatStore(catalog: [.available(original)])
        let feature = makeFeature(store: store)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, original.chat.id))
        await feature.send(.setFilter(Self.context, try ChatFilterQuery("new")))

        await feature.send(
            .rename(
                Self.context,
                original.chat.id,
                title: "Speaking Goals",
                expectedRevision: 0
            )
        )

        let state = await feature.currentState
        let renamed = try XCTUnwrap(Self.openAggregate(in: state))
        XCTAssertEqual(renamed.chat.id, original.chat.id)
        XCTAssertEqual(renamed.chat.draft, original.chat.draft)
        XCTAssertEqual(renamed.chat.attachments, original.chat.attachments)
        XCTAssertEqual(renamed.memory, original.memory)
        XCTAssertEqual(renamed.chat.manifestRevision, 1)
        XCTAssertEqual(try Self.rows(in: state).visibleRows, [])
    }

    func testFilterIsPureCaseAndDiacriticInsensitive() async throws {
        let first = try Self.aggregate(title: "Café Practice")
        let second = try Self.aggregate(
            chat: "cht-20260830T120100000Z-5KMN",
            draft: "drf-20260830T120100000Z-6PQR",
            memory: "mem-20260830T120100000Z-7STV",
            title: "Pitch"
        )
        let store = RecordingChatStore(catalog: [.available(first), .available(second)])
        let feature = makeFeature(store: store)
        await feature.send(.start(Self.context))
        let callsBefore = await store.calls

        await feature.send(.setFilter(Self.context, try ChatFilterQuery("CAFE")))

        let state = await feature.currentState
        XCTAssertEqual(try Self.rows(in: state).visibleRows.map(\.chatID), [first.chat.id])
        let callsAfter = await store.calls
        XCTAssertEqual(callsAfter, callsBefore)
    }

    func testStateStreamRetainsOnlyNewestSnapshotForSuspendedSubscriber() async throws {
        let feature = makeFeature(store: RecordingChatStore())
        await feature.send(.start(Self.context))
        var iterator = feature.states.makeAsyncIterator()
        _ = await iterator.next()

        await feature.send(.setFilter(Self.context, try ChatFilterQuery("first")))
        await feature.send(.setFilter(Self.context, try ChatFilterQuery("second")))
        await feature.send(.setFilter(Self.context, try ChatFilterQuery("latest")))

        let latest = await iterator.next()
        XCTAssertEqual(latest?.filterQuery, try ChatFilterQuery("latest"))
    }

    func testFilterChangedWhileCatalogLoadIsSuspendedIsReappliedToLoadedRows() async throws {
        let first = try Self.aggregate(title: "Café Practice")
        let second = try Self.aggregate(
            chat: "cht-20260830T120100000Z-5KMN",
            draft: "drf-20260830T120100000Z-6PQR",
            memory: "mem-20260830T120100000Z-7STV",
            title: "Pitch"
        )
        let store = SuspendedCatalogChatStore(catalog: [.available(first), .available(second)])
        let feature = makeFeature(store: store)

        async let start: Void = feature.send(.start(Self.context))
        await store.waitUntilCatalogLoadStarts()
        await feature.send(.setFilter(Self.context, try ChatFilterQuery("cafe")))
        await store.resumeCatalogLoad()
        await start

        let state = await feature.currentState
        XCTAssertEqual(state.filterQuery, try ChatFilterQuery("cafe"))
        XCTAssertEqual(try Self.rows(in: state).visibleRows.map(\.chatID), [first.chat.id])
    }

    func testLatestStartIsNotDroppedWhenAnEarlierLibraryLoadIsSuspended() async throws {
        let first = try Self.aggregate(title: "First Library Chat")
        let second = try Self.aggregate(
            chat: "cht-20260830T120100000Z-5KMN",
            draft: "drf-20260830T120100000Z-6PQR",
            memory: "mem-20260830T120100000Z-7STV",
            title: "Second Library Chat"
        )
        let store = SequencedSuspendedCatalogChatStore()
        let feature = makeFeature(store: store)

        async let firstStart: Void = feature.send(.start(Self.context))
        await store.waitForCatalogLoadCount(1)
        async let secondStart: Void = feature.send(.start(Self.secondContext))
        await Task.yield()
        await store.resumeCatalogLoad(in: Self.scope, with: [.available(first)])
        await store.waitForCatalogLoadCount(2)

        let stateWhileLatestLoadIsPending = await feature.currentState
        XCTAssertEqual(stateWhileLatestLoadIsPending.catalog, .loading)

        await store.resumeCatalogLoad(in: Self.secondScope, with: [.available(second)])
        await firstStart
        await secondStart

        let state = await feature.currentState
        XCTAssertEqual(try Self.rows(in: state).allRows.map(\.chatID), [second.chat.id])
        let scopes = await store.loadedScopes
        XCTAssertEqual(scopes, [Self.scope, Self.secondScope])
    }

    func testPendingLibraryFilterIsPreservedWhilePreviousCatalogLoadIsSuspended() async throws {
        let first = try Self.aggregate(title: "First Library Chat")
        let second = try Self.aggregate(
            chat: "cht-20260830T120100000Z-5KMN",
            draft: "drf-20260830T120100000Z-6PQR",
            memory: "mem-20260830T120100000Z-7STV",
            title: "Second Library Chat"
        )
        let store = SequencedSuspendedCatalogChatStore()
        let feature = makeFeature(store: store)
        let query = try ChatFilterQuery("Second")

        async let firstStart: Void = feature.send(.start(Self.context))
        await store.waitForCatalogLoadCount(1)
        await feature.send(.start(Self.secondContext))
        await feature.send(.setFilter(Self.secondContext, query))
        await store.resumeCatalogLoad(in: Self.scope, with: [.available(first)])
        await store.waitForCatalogLoadCount(2)

        let pendingState = await feature.currentState
        XCTAssertEqual(pendingState.catalog, .loading)
        XCTAssertEqual(pendingState.filterQuery, query)

        await store.resumeCatalogLoad(in: Self.secondScope, with: [.available(second)])
        await firstStart

        let state = await feature.currentState
        XCTAssertEqual(state.filterQuery, query)
        XCTAssertEqual(try Self.rows(in: state).visibleRows.map(\.chatID), [second.chat.id])
    }

    func testOldFilterIsRejectedAfterReturningToTheSameLibraryWithNewGeneration() async throws {
        let store = RecordingChatStore()
        let feature = makeFeature(store: store)
        let returnedContext = ChatCommandContext(
            libraryScope: Self.scope,
            generation: 3
        )
        await feature.send(.start(Self.context))
        await feature.send(.start(Self.secondContext))
        await feature.send(.start(returnedContext))

        await feature.send(
            .setFilter(Self.context, try ChatFilterQuery("stale first visit"))
        )

        let stateAfterStaleFilter = await feature.currentState
        XCTAssertEqual(stateAfterStaleFilter.filterQuery, .empty)

        await feature.send(
            .setFilter(returnedContext, try ChatFilterQuery("current visit"))
        )
        let currentState = await feature.currentState
        XCTAssertEqual(currentState.filterQuery, try ChatFilterQuery("current visit"))
        let calls = await store.calls
        XCTAssertEqual(calls, [.loadCatalog, .loadCatalog, .loadCatalog])
    }

    func testOpenRestoresNonemptyDraftWithoutAnySubmitCapabilityOrMutation() async throws {
        let aggregate = try Self.aggregate(draftText: "Keep this local draft")
        let store = RecordingChatStore(catalog: [.available(aggregate)])
        let feature = makeFeature(store: store)
        await feature.send(.start(Self.context))

        await feature.send(.open(Self.context, aggregate.chat.id))

        let state = await feature.currentState
        let calls = await store.calls
        XCTAssertEqual(Self.openAggregate(in: state), aggregate)
        XCTAssertEqual(calls, [.loadCatalog, .load])
    }

    func testOpenPreservesReadOnlyLibraryAsTheSpecificRecoveryNotice() async throws {
        let aggregate = try Self.aggregate()
        let store = RecordingChatStore(
            catalog: [.available(aggregate)],
            loadOutcomes: [.readOnlyLibrary]
        )
        let feature = makeFeature(store: store)
        await feature.send(.start(Self.context))

        await feature.send(.open(Self.context, aggregate.chat.id))

        let state = await feature.currentState
        XCTAssertEqual(state.selection, .none)
        XCTAssertEqual(state.notice, .readOnlyLibrary)
    }

    func testOpenFailureDoesNotMislabelTheChatAsFrozenCorruption() async throws {
        let aggregate = try Self.aggregate()
        let store = RecordingChatStore(
            catalog: [.available(aggregate)],
            loadOutcomes: [.failed]
        )
        let feature = makeFeature(store: store)
        await feature.send(.start(Self.context))

        await feature.send(.open(Self.context, aggregate.chat.id))

        let state = await feature.currentState
        XCTAssertEqual(state.selection, .none)
        XCTAssertEqual(state.notice, .chatOpenFailed)
    }

    func testStaleRenameInstallsCurrentAggregateWithoutOverwritingIt() async throws {
        let original = try Self.aggregate()
        let current = try Self.aggregate(title: "Other Writer", revision: 1)
        let store = RecordingChatStore(
            catalog: [.available(original)],
            renameOutcomes: [.stale(current)]
        )
        let feature = makeFeature(store: store)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, original.chat.id))

        await feature.send(
            .rename(Self.context, original.chat.id, title: "Mine", expectedRevision: 0)
        )

        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state), current)
        XCTAssertEqual(state.notice, .staleRename)
    }

    private func makeFeature(store: any ChatStorePort) -> DefaultChatFeature {
        DefaultChatFeature(
            store: store,
            profileReader: FixedProfileReader(),
            clock: FixedChatClock(),
            chatIDGenerator: FixedChatIDs(),
            draftIDGenerator: FixedChatIDs(),
            memoryIDGenerator: FixedChatIDs()
        )
    }

    private static let scope = LibraryScope(
        libraryID: try! LibraryID("lib-20260830T115900000Z-2ABC")
    )

    private static let secondScope = LibraryScope(
        libraryID: try! LibraryID("lib-20260830T121000000Z-3DEF")
    )

    private static let context = ChatCommandContext(
        libraryScope: scope,
        generation: 1
    )

    private static let secondContext = ChatCommandContext(
        libraryScope: secondScope,
        generation: 2
    )

    private static func aggregate(
        chat: String = "cht-20260830T120000000Z-2ABC",
        draft: String = "drf-20260830T120000000Z-3DEF",
        memory: String = "mem-20260830T120000000Z-4GHJ",
        title: String = "New Chat",
        revision: UInt64 = 0,
        draftText: String = ""
    ) throws -> ChatAggregate {
        let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
        let attachments = ChatAttachments.empty
        let chatID = try ChatID(chat)
        let memoryID = try CoachMemoryID(memory)
        let chatValue = try Chat(
            id: chatID,
            manifestRevision: revision,
            title: ChatTitle(title),
            createdAt: instant,
            updatedAt: instant,
            creation: ChatCreation(
                kind: .newChat,
                originAttachmentID: nil,
                attachments: attachments
            ),
            profileStatementGenerationAtCreation: 7,
            attachments: attachments,
            draft: ChatDraft(
                draftID: ChatDraftID(draft),
                version: 0,
                text: draftText,
                updatedAt: instant
            ),
            messageIDs: [],
            currentMemoryID: memoryID
        )
        return try ChatAggregate(
            chat: chatValue,
            memory: CoachMemory(
                memoryID: memoryID,
                chatID: chatID,
                generalNotes: "",
                sessionSummaries: [],
                attachments: attachments
            )
        )
    }

    private static func rows(in state: ChatFeatureState) throws -> ChatCatalogSnapshot {
        guard case let .ready(snapshot) = state.catalog else {
            throw TestError.unexpectedState
        }
        return snapshot
    }

    private static func openAggregate(in state: ChatFeatureState) -> ChatAggregate? {
        guard case let .open(aggregate) = state.selection else { return nil }
        return aggregate
    }
}

private actor SuspendedCatalogChatStore: ChatStorePort {
    private let catalog: [ChatCatalogEntry]
    private var loadStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(catalog: [ChatCatalogEntry]) {
        self.catalog = catalog
    }

    func waitUntilCatalogLoadStarts() async {
        while !loadStarted { await Task.yield() }
    }

    func resumeCatalogLoad() {
        continuation?.resume()
        continuation = nil
    }

    func loadCatalog(in library: LibraryScope) async -> ChatCatalogOutcome {
        loadStarted = true
        await withCheckedContinuation { continuation = $0 }
        return .loaded(catalog)
    }

    func create(_ seed: NewDevelopmentChatSeed) async -> ChatMutationOutcome { .failed }
    func rename(_ mutation: RenameChatMutation) async -> ChatMutationOutcome { .failed }
    func load(_ chatID: ChatID, in library: LibraryScope) async -> ChatLoadOutcome { .missing }
}

private actor SequencedSuspendedCatalogChatStore: ChatStorePort {
    private(set) var loadedScopes: [LibraryScope] = []
    private var continuations: [LibraryID: CheckedContinuation<ChatCatalogOutcome, Never>] = [:]

    func waitForCatalogLoadCount(_ count: Int) async {
        while loadedScopes.count < count { await Task.yield() }
    }

    func resumeCatalogLoad(in scope: LibraryScope, with catalog: [ChatCatalogEntry]) {
        continuations.removeValue(forKey: scope.libraryID)?.resume(returning: .loaded(catalog))
    }

    func loadCatalog(in library: LibraryScope) async -> ChatCatalogOutcome {
        loadedScopes.append(library)
        return await withCheckedContinuation { continuation in
            continuations[library.libraryID] = continuation
        }
    }

    func create(_ seed: NewDevelopmentChatSeed) async -> ChatMutationOutcome { .failed }
    func rename(_ mutation: RenameChatMutation) async -> ChatMutationOutcome { .failed }
    func load(_ chatID: ChatID, in library: LibraryScope) async -> ChatLoadOutcome { .missing }
}

private enum TestError: Error { case unexpectedState }

private actor RecordingChatStore: ChatStorePort {
    enum Call: Equatable { case loadCatalog, create, rename, load }

    private let catalog: [ChatCatalogEntry]
    private var createOutcomes: [ChatMutationOutcome]
    private var renameOutcomes: [ChatMutationOutcome]
    private var loadOutcomes: [ChatLoadOutcome]
    private(set) var createSeeds: [NewDevelopmentChatSeed] = []
    private(set) var calls: [Call] = []
    private(set) var loadedScopes: [LibraryScope] = []

    init(
        catalog: [ChatCatalogEntry] = [],
        createOutcomes: [ChatMutationOutcome] = [],
        renameOutcomes: [ChatMutationOutcome] = [],
        loadOutcomes: [ChatLoadOutcome] = []
    ) {
        self.catalog = catalog
        self.createOutcomes = createOutcomes
        self.renameOutcomes = renameOutcomes
        self.loadOutcomes = loadOutcomes
    }

    func loadCatalog(in library: LibraryScope) -> ChatCatalogOutcome {
        calls.append(.loadCatalog)
        loadedScopes.append(library)
        return .loaded(catalog)
    }

    func create(_ seed: NewDevelopmentChatSeed) -> ChatMutationOutcome {
        calls.append(.create)
        createSeeds.append(seed)
        if !createOutcomes.isEmpty { return createOutcomes.removeFirst() }
        return .committed(seed.aggregate)
    }

    func rename(_ mutation: RenameChatMutation) -> ChatMutationOutcome {
        calls.append(.rename)
        if !renameOutcomes.isEmpty { return renameOutcomes.removeFirst() }
        return .committed(mutation.replacement)
    }

    func load(_ chatID: ChatID, in library: LibraryScope) -> ChatLoadOutcome {
        calls.append(.load)
        if !loadOutcomes.isEmpty { return loadOutcomes.removeFirst() }
        for entry in catalog {
            if case let .available(value) = entry, value.chat.id == chatID {
                return .loaded(value)
            }
        }
        return .missing
    }
}

private struct FixedProfileReader: ProfileStatementGenerationReading {
    func statementGeneration(in library: LibraryScope) async -> UInt64? { 7 }
}

private struct FixedChatClock: ChatClock {
    func now() async -> UTCInstant { try! UTCInstant("2026-08-30T12:00:00.000Z") }
}

private struct FixedChatIDs: ChatIDGenerator, ChatDraftIDGenerator, CoachMemoryIDGenerator {
    func generateChatID(at instant: UTCInstant) async -> ChatID {
        try! ChatID("cht-20260830T120000000Z-2ABC")
    }

    func generateChatDraftID(at instant: UTCInstant) async -> ChatDraftID {
        try! ChatDraftID("drf-20260830T120000000Z-3DEF")
    }

    func generateCoachMemoryID(at instant: UTCInstant) async -> CoachMemoryID {
        try! CoachMemoryID("mem-20260830T120000000Z-4GHJ")
    }
}
