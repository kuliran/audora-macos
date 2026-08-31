@testable import AudoraApplication
import AudoraDomain
import Foundation
import XCTest

final class ChatContextCapacityTransitionTests: XCTestCase {
    func testExplicitRefreshRequotesCurrentExternalContextWithoutChatMutation() async throws {
        let aggregate = try Self.aggregate(draftText: "Current Draft")
        let store = CapacityChatStore(aggregate: aggregate)
        let source = DynamicCapacitySnapshotPort(pendingWindows: [])
        let feature = makeFeature(store: store, source: source)

        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        guard case let .available(firstQuote) = await feature.currentState.contextAdvisory else {
            return XCTFail("opening must quote current external context")
        }

        await source.updateProfile(String(repeating: "profile ", count: 200))
        await feature.send(
            .refreshContextQuote(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )

        let refreshed = await feature.currentState
        guard case let .available(secondQuote) = refreshed.contextAdvisory else {
            return XCTFail("refresh must publish the newly resolved quote")
        }
        XCTAssertGreaterThan(secondQuote.completeInputTokens, firstQuote.completeInputTokens)
        XCTAssertEqual(refreshed.composer?.draft, aggregate.chat.draft)
        let pendingLockCount = await store.pendingLockCount
        let pendingReplacementCount = await store.pendingReplacementCount
        XCTAssertEqual(pendingLockCount, 0)
        XCTAssertEqual(pendingReplacementCount, 0)
    }

    func testIndividuallyOversizedMessageRemainsEditableAndNeverLocksPending() async throws {
        let text = String(
            repeating: "x",
            count: CoachContextInputLimits.maximumUserMessageUTF8Bytes + 1
        )
        let aggregate = try Self.aggregate(draftText: text)
        let store = CapacityChatStore(aggregate: aggregate)
        let source = DynamicCapacitySnapshotPort(pendingWindows: [100_000])
        let feature = makeFeature(store: store, source: source)

        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        await feature.send(.sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft))

        let state = await feature.currentState
        guard case let .editable(draft, false) = state.composer else {
            return XCTFail("an oversized message must remain editable")
        }
        XCTAssertEqual(draft, aggregate.chat.draft)
        XCTAssertEqual(state.notice, .messageMustBeShortened)
        XCTAssertEqual(
            state.contextAdvisory,
            .messageTooLong(
                maximumUTF8Bytes: CoachContextInputLimits.maximumUserMessageUTF8Bytes
            )
        )
        let pendingLockCount = await store.pendingLockCount
        let chatResolutionCount = await source.chatResolutionCount
        let pendingResolutionCount = await source.pendingResolutionCount
        XCTAssertEqual(pendingLockCount, 0)
        XCTAssertEqual(chatResolutionCount, 0)
        XCTAssertEqual(pendingResolutionCount, 0)
    }

    func testCapacityFailureRecoveryPreservesPendingIdentityAndUnlocksSameDraft() async throws {
        let aggregate = try Self.aggregate(draftText: "Keep this exact Draft")
        let store = CapacityChatStore(aggregate: aggregate)
        let source = DynamicCapacitySnapshotPort(pendingWindows: [64, 100_000])
        let feature = makeFeature(store: store, source: source)

        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        await feature.send(.sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft))

        let failedState = await feature.currentState
        guard case let .locked(failedDraft, failedPending) = failedState.composer else {
            return XCTFail("a capacity miss must install a durable Pending User Turn")
        }
        XCTAssertEqual(failedDraft, aggregate.chat.draft)
        XCTAssertEqual(failedPending.failure, .coachContextCannotFit)
        guard case let .available(failedQuote) = failedState.contextAdvisory else {
            return XCTFail("the authoritative failure quote must be projected")
        }
        XCTAssertFalse(failedQuote.fits)

        await feature.send(
            .createNewChatFromCapacityFailure(Self.context, failedPending.id)
        )
        let intent = await feature.currentState.createNewChatRecoveryIntent
        XCTAssertEqual(intent?.sourceChatID, aggregate.chat.id)
        XCTAssertEqual(intent?.sourcePendingUserTurnID, failedPending.id)

        await feature.send(.retryPendingUserTurn(Self.context, failedPending.id))

        let retriedState = await feature.currentState
        guard case let .locked(retriedDraft, retriedPending) = retriedState.composer else {
            return XCTFail("#22 still owns execution after a successful retry")
        }
        XCTAssertEqual(retriedDraft, failedDraft)
        XCTAssertEqual(retriedPending.id, failedPending.id)
        XCTAssertEqual(retriedPending.draftID, failedPending.draftID)
        XCTAssertEqual(retriedPending.draftVersion, failedPending.draftVersion)
        XCTAssertEqual(retriedPending.responsePositionID, failedPending.responsePositionID)
        XCTAssertNil(retriedPending.failure)
        XCTAssertNil(retriedState.createNewChatRecoveryIntent)
        let pendingReplacementCount = await store.pendingReplacementCount
        XCTAssertEqual(pendingReplacementCount, 1)

        await feature.send(.discardPendingUserTurn(Self.context, retriedPending.id))

        let discardedState = await feature.currentState
        guard case let .editable(discardedDraft, false) = discardedState.composer else {
            return XCTFail("Discard must unlock the same populated Draft")
        }
        XCTAssertEqual(discardedDraft, aggregate.chat.draft)
        let pendingDrafts = await source.pendingDrafts
        XCTAssertEqual(pendingDrafts, [failedDraft, failedDraft])
    }

    private func makeFeature(
        store: CapacityChatStore,
        source: DynamicCapacitySnapshotPort
    ) -> DefaultChatFeature {
        DefaultChatFeature(
            store: store,
            profileReader: CapacityProfileReader(),
            clock: CapacityClock(),
            chatIDGenerator: CapacityIDs(),
            draftIDGenerator: CapacityIDs(),
            memoryIDGenerator: CapacityIDs(),
            pendingUserTurnIDGenerator: CapacityIDs(),
            responsePositionIDGenerator: CapacityIDs(),
            autosaveScheduler: CapacityAutosaveScheduler(),
            coachContext: DefaultCoachContextFeature(source: source)
        )
    }

    private static let scope = LibraryScope(
        libraryID: try! LibraryID("lib-20260830T115900000Z-2ABC")
    )
    private static let context = ChatCommandContext(libraryScope: scope, generation: 1)

    private static func aggregate(draftText: String) throws -> ChatAggregate {
        let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
        let base = try ChatAggregate.emptyDevelopmentChat(
            chatID: ChatID("cht-20260830T120000000Z-2ABC"),
            draftID: ChatDraftID("drf-20260830T120000000Z-3DEF"),
            memoryID: CoachMemoryID("mem-20260830T120000000Z-4GHJ"),
            instant: instant,
            profileStatementGeneration: 7
        )
        let draft = try base.chat.draft.edited(text: draftText, at: instant)
        return try ChatAggregate(
            chat: base.chat.replacingDraft(with: draft),
            memory: base.memory
        )
    }
}

private actor DynamicCapacitySnapshotPort: CoachContextSnapshotPort {
    private var pendingWindows: [Int]
    private var profileText = "Synthetic profile"
    private var contextGeneration: UInt64 = 1
    private var configurationGeneration: UInt64 = 0
    private(set) var pendingDrafts: [ChatDraft] = []
    private(set) var chatResolutionCount = 0
    private(set) var pendingResolutionCount = 0

    init(pendingWindows: [Int]) {
        self.pendingWindows = pendingWindows
    }

    func updateProfile(_ text: String) {
        profileText = text
        contextGeneration += 1
    }

    func resolveNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        .sourceUnavailable
    }

    func resolveChat(
        _ request: CoachContextChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        chatResolutionCount += 1
        return snapshot(
            draft: request.draft,
            binding: .chat(
                library: request.library,
                chatID: request.chatID,
                draftID: request.draft.draftID,
                draftVersion: request.draft.version
            ),
            contextWindow: 100_000
        )
    }

    func resolvePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextSnapshotOutcome {
        pendingResolutionCount += 1
        pendingDrafts.append(request.draft)
        let contextWindow = pendingWindows.isEmpty ? 100_000 : pendingWindows.removeFirst()
        return snapshot(
            draft: request.draft,
            binding: .pending(
                library: request.library,
                chatID: request.chatID,
                draftID: request.draft.draftID,
                draftVersion: request.draft.version,
                pendingUserTurnID: request.pendingUserTurn.id,
                responsePositionID: request.pendingUserTurn.responsePositionID
            ),
            contextWindow: contextWindow
        )
    }

    func isCurrent(_ authority: CoachContextSnapshotAuthority) async -> Bool {
        authority.contextGeneration == contextGeneration &&
            authority.configurationGeneration == configurationGeneration
    }

    private func snapshot(
        draft: ChatDraft,
        binding: CoachContextSnapshotBinding,
        contextWindow: Int
    ) -> CoachContextSnapshotOutcome {
        do {
            configurationGeneration += 1
            return .resolved(
                try CoachContextResolvedSnapshot(
                    input: CoachContextQuoteInput(
                        profile: .object([
                            "statements": .array([.string(profileText)]),
                        ]),
                        memory: .object([
                            "generalNotes": .string("Synthetic memory"),
                            "sessionSummaries": .array([]),
                        ]),
                        history: [
                            .user(text: "Earlier user text\nkept exactly"),
                            .coach(markdownBlocks: ["Coach block one", "Coach block two"]),
                        ],
                        currentDraft: draft.text
                    ),
                    configuration: try CoachContextConfiguration(
                        descriptor: CoachProviderDescriptor(
                            displayName: "Synthetic fixture",
                            contextBudget: CoachContextBudget(
                                contextWindowTokens: contextWindow,
                                responseReservedTokens: 16,
                                safetyMarginTokens: 8
                            ),
                            coachMemoryMaxTokens: 1
                        ),
                        policy: CoachProviderEstimationPolicy(
                            providerIdentifier: "synthetic-fixture-v1",
                            responseCollectorByteCeiling: 8_192,
                            framing: CoachProviderFraming(),
                            tokenEstimator: .utf8ByteUpperBound()
                        )
                    ),
                    authority: CoachContextSnapshotAuthority(
                        binding: binding,
                        contextGeneration: contextGeneration,
                        configurationGeneration: configurationGeneration
                    )
                )
            )
        } catch {
            return .sourceUnavailable
        }
    }
}

private actor CapacityChatStore: ChatStorePort {
    private var aggregate: ChatAggregate
    private(set) var pendingLockCount = 0
    private(set) var pendingReplacementCount = 0

    init(aggregate: ChatAggregate) {
        self.aggregate = aggregate
    }

    func loadCatalog(in library: LibraryScope) async -> ChatCatalogOutcome {
        .loaded([.available(aggregate)])
    }

    func create(_ seed: NewDevelopmentChatSeed) async -> ChatMutationOutcome { .failed }
    func rename(_ mutation: RenameChatMutation) async -> ChatMutationOutcome { .failed }

    func saveDraft(_ mutation: SaveChatDraftMutation) async -> ChatMutationOutcome {
        mutation.replacement == aggregate.chat.draft ? .committed(aggregate) : .stale(aggregate)
    }

    func lockPendingUserTurn(
        _ mutation: LockPendingUserTurnMutation
    ) async -> ChatMutationOutcome {
        pendingLockCount += 1
        guard aggregate.pendingUserTurn == nil,
              aggregate.chat.draft.draftID == mutation.pendingUserTurn.draftID,
              aggregate.chat.draft.version == mutation.pendingUserTurn.draftVersion,
              let replacement = try? ChatAggregate(
                  chat: aggregate.chat,
                  memory: aggregate.memory,
                  pendingUserTurn: mutation.pendingUserTurn
              )
        else {
            return .stale(aggregate)
        }
        aggregate = replacement
        return .committed(replacement)
    }

    func replacePendingUserTurn(
        _ mutation: ReplacePendingUserTurnMutation
    ) async -> ChatMutationOutcome {
        pendingReplacementCount += 1
        guard aggregate.pendingUserTurn == mutation.base,
              let replacement = try? ChatAggregate(
                  chat: aggregate.chat,
                  memory: aggregate.memory,
                  pendingUserTurn: mutation.replacement
              )
        else {
            return .stale(aggregate)
        }
        aggregate = replacement
        return .committed(replacement)
    }

    func discardPendingUserTurn(
        _ mutation: DiscardPendingUserTurnMutation
    ) async -> ChatMutationOutcome {
        guard aggregate.pendingUserTurn == mutation.pendingUserTurn,
              let replacement = try? ChatAggregate(
                  chat: aggregate.chat,
                  memory: aggregate.memory
              )
        else {
            return .stale(aggregate)
        }
        aggregate = replacement
        return .committed(replacement)
    }

    func load(_ chatID: ChatID, in library: LibraryScope) async -> ChatLoadOutcome {
        chatID == aggregate.chat.id ? .loaded(aggregate) : .missing
    }
}

private struct CapacityProfileReader: ProfileStatementGenerationReading {
    func statementGeneration(in library: LibraryScope) async -> UInt64? { 7 }
}

private struct CapacityClock: ChatClock {
    func now() async -> UTCInstant { try! UTCInstant("2026-08-30T12:00:01.000Z") }
}

private struct CapacityIDs: ChatIDGenerator, ChatDraftIDGenerator,
    CoachMemoryIDGenerator, PendingUserTurnIDGenerator, ChatResponsePositionIDGenerator
{
    func generateChatID(at instant: UTCInstant) async -> ChatID {
        try! ChatID("cht-20260830T120001000Z-5KMN")
    }

    func generateChatDraftID(at instant: UTCInstant) async -> ChatDraftID {
        try! ChatDraftID("drf-20260830T120001000Z-6PQR")
    }

    func generateCoachMemoryID(at instant: UTCInstant) async -> CoachMemoryID {
        try! CoachMemoryID("mem-20260830T120001000Z-7STV")
    }

    func generatePendingUserTurnID(at instant: UTCInstant) async -> PendingUserTurnID {
        try! PendingUserTurnID("ptu-20260830T120001000Z-8WXY")
    }

    func generateChatResponsePositionID(
        at instant: UTCInstant
    ) async -> ChatResponsePositionID {
        try! ChatResponsePositionID("rsp-20260830T120001000Z-9Z23")
    }
}

private struct CapacityAutosaveScheduler: ChatAutosaveScheduling {
    func sleep(forNanoseconds nanoseconds: UInt64) async throws {}
}
