@testable @_spi(CoachContextQualification) import AudoraApplication
import AudoraDomain
import Foundation
import XCTest

final class CoachContextFeatureTests: XCTestCase {
    func testQuoteAndPreflightResolveOnlyStableChatAndPendingTurnIdentity() async throws {
        let aggregate = try fixtureAggregate()
        let configuration = try fixtureConfiguration()
        let source = RecordingCoachContextSnapshotPort(configuration: configuration)
        let feature = DefaultCoachContextFeature(source: source)
        let chatRequest = CoachContextChatQuoteRequest(
            library: Self.scope,
            chatID: aggregate.chat.id,
            draft: aggregate.chat.draft
        )
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120001000Z-5KMN"),
            draftID: aggregate.chat.draft.draftID,
            draftVersion: aggregate.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120001000Z-6PQR"
            )
        )
        let pendingRequest = try CoachContextPendingTurnRequest(
            library: Self.scope,
            chatID: aggregate.chat.id,
            draft: aggregate.chat.draft,
            pendingUserTurn: pending
        )

        let quote = await feature.quoteChat(chatRequest)
        let preparation = await feature.preparePendingUserTurn(pendingRequest)

        guard case let .available(advisory) = quote,
              case let .prepared(prepared) = preparation
        else {
            return XCTFail("expected both advisory and exact preparation")
        }
        XCTAssertEqual(advisory, prepared.quote)
        let requests = await source.requests
        XCTAssertEqual(requests, [.chat(chatRequest), .pending(pendingRequest)])
    }

    func testQuoteNewChatUsesCreationContextWithoutFabricatingUserText() async throws {
        let source = RecordingCoachContextSnapshotPort(
            configuration: try fixtureConfiguration()
        )
        let feature = DefaultCoachContextFeature(source: source)
        let request = try CoachContextNewChatQuoteRequest(
            library: Self.scope,
            attachments: .empty,
            creationKind: .newChat
        )

        let outcome = await feature.quoteNewChat(request)

        guard case let .available(quote) = outcome else {
            return XCTFail("creation context should be quotable without a Draft")
        }
        XCTAssertEqual(quote.context.messageLength, .eligible)
        XCTAssertEqual(
            quote.context.categoryCosts[.draft],
            CoachContextComponentCost(utf8ByteCount: 0, estimatedTokenCount: 0)
        )
        XCTAssertGreaterThan(
            quote.context.categoryCosts[.framing]?.utf8ByteCount ?? 0,
            0
        )
        let triggers = await source.resolvedTriggers
        XCTAssertEqual(triggers, [.chatCreation(request.creation)])
    }

    func testProviderUnavailableExceptionRequiresExplicitKnownCurrentConfiguration()
        async throws
    {
        let request = try CoachContextNewChatQuoteRequest(
            library: Self.scope,
            attachments: .empty,
            creationKind: .newChat
        )
        let knownFeature =
            previouslyQualifiedProviderUnavailableCoachContextFixture()

        let knownConfiguration = await knownFeature.quoteNewChat(request)
        let missingConfiguration = await DefaultCoachContextFeature(
            source: UnconfiguredProviderUnavailableSnapshotPort()
        ).quoteNewChat(request)

        XCTAssertEqual(
            knownConfiguration,
            .unavailable(.providerUnavailable)
        )
        XCTAssertEqual(
            missingConfiguration,
            .unavailable(.sourceUnavailable)
        )

        guard case let .providerUnavailable(lowerBound, authority) =
            await knownFeature.quoteNewChatBoundToConfiguration(request)
        else {
            return XCTFail("expected the explicit known configuration authority")
        }
        XCTAssertFalse(lowerBound.provesImpossible)
        guard case let .acquired(lease) =
            await knownFeature.acquireNewChatCreationLease(authority)
        else {
            return XCTFail("expected the known configuration to remain leasable")
        }
        await lease.release()
    }

    func testLiveCompositionReportsSourceUnavailableWithoutQualifiedContext()
        async throws
    {
        let aggregate = try fixtureAggregate()
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120001000Z-5KMN"),
            draftID: aggregate.chat.draft.draftID,
            draftVersion: aggregate.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120001000Z-6PQR"
            )
        )
        let feature = DefaultCoachContextFeature()
        let newChatRequest = try CoachContextNewChatQuoteRequest(
            library: Self.scope,
            attachments: .empty,
            creationKind: .newChat
        )
        let chatRequest = CoachContextChatQuoteRequest(
            library: Self.scope,
            chatID: aggregate.chat.id,
            draft: aggregate.chat.draft
        )
        let pendingRequest = try CoachContextPendingTurnRequest(
            library: Self.scope,
            chatID: aggregate.chat.id,
            draft: aggregate.chat.draft,
            pendingUserTurn: pending
        )

        let newChat = await feature.quoteNewChat(newChatRequest)
        let chat = await feature.quoteChat(chatRequest)
        let preparation = await feature.preparePendingUserTurn(pendingRequest)

        XCTAssertEqual(newChat, .unavailable(.sourceUnavailable))
        XCTAssertEqual(chat, .unavailable(.sourceUnavailable))
        XCTAssertEqual(preparation, .unavailable(.sourceUnavailable))
    }

    func testOversizedPendingDraftShortCircuitsBeforeEvenFailClosedResolution() async throws {
        let aggregate = try fixtureAggregate(
            draftText: String(
                repeating: "x",
                count: CoachContextInputLimits.maximumUserMessageUTF8Bytes + 1
            )
        )
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120001000Z-5KMN"),
            draftID: aggregate.chat.draft.draftID,
            draftVersion: aggregate.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120001000Z-6PQR"
            )
        )
        let request = try CoachContextPendingTurnRequest(
            library: Self.scope,
            chatID: aggregate.chat.id,
            draft: aggregate.chat.draft,
            pendingUserTurn: pending
        )

        let outcome = await DefaultCoachContextFeature().preparePendingUserTurn(request)

        XCTAssertEqual(
            outcome,
            .messageTooLong(
                maximumUTF8Bytes: CoachContextInputLimits.maximumUserMessageUTF8Bytes
            )
        )
    }

    func testPreflightRejectsSuspendedSameTextIdentityAndAuthorityRace() async throws {
        let aggregate = try fixtureAggregate(draftText: "Identical text")
        let source = SuspendingAuthoritySnapshotPort(
            configuration: try fixtureConfiguration(contextWindow: 64)
        )
        let feature = DefaultCoachContextFeature(source: source)
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120001000Z-5KMN"),
            draftID: aggregate.chat.draft.draftID,
            draftVersion: aggregate.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120001000Z-6PQR"
            )
        )
        let request = try CoachContextPendingTurnRequest(
            library: Self.scope,
            chatID: aggregate.chat.id,
            draft: aggregate.chat.draft,
            pendingUserTurn: pending
        )

        let task = Task { await feature.preparePendingUserTurn(request) }
        await source.waitUntilValidationStarts()
        let replacement = try ChatDraft(
            draftID: ChatDraftID("drf-20260830T120002000Z-7RST"),
            version: aggregate.chat.draft.version + 1,
            text: aggregate.chat.draft.text,
            updatedAt: aggregate.chat.draft.updatedAt
        )
        await source.advance(
            to: replacement,
            contextGeneration: 2,
            configurationGeneration: 2
        )
        await source.resumeValidation()

        let outcome = await task.value
        XCTAssertEqual(outcome, .unavailable(.staleState))
        let measuredDrafts = await source.measuredDrafts
        XCTAssertEqual(measuredDrafts, [aggregate.chat.draft])
        let currentDraft = await source.currentDraft
        XCTAssertEqual(currentDraft, replacement)
    }

    func testPreflightRejectsSameTextSnapshotBoundToAnotherDraftVersion() async throws {
        let aggregate = try fixtureAggregate(draftText: "Identical text")
        let wrongDraft = try ChatDraft(
            draftID: ChatDraftID("drf-20260830T120002000Z-7RST"),
            version: aggregate.chat.draft.version + 1,
            text: aggregate.chat.draft.text,
            updatedAt: aggregate.chat.draft.updatedAt
        )
        let source = WrongBindingSnapshotPort(
            configuration: try fixtureConfiguration(),
            wrongDraft: wrongDraft
        )
        let feature = DefaultCoachContextFeature(source: source)
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120001000Z-5KMN"),
            draftID: aggregate.chat.draft.draftID,
            draftVersion: aggregate.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120001000Z-6PQR"
            )
        )
        let request = try CoachContextPendingTurnRequest(
            library: Self.scope,
            chatID: aggregate.chat.id,
            draft: aggregate.chat.draft,
            pendingUserTurn: pending
        )

        let outcome = await feature.preparePendingUserTurn(request)

        XCTAssertEqual(outcome, .unavailable(.staleState))
        let validationCount = await source.validationCount
        XCTAssertEqual(validationCount, 0)
    }

    func testPendingTurnRequestRejectsAnyDraftIdentityDrift() throws {
        let aggregate = try fixtureAggregate()
        let otherDraft = try ChatDraft(
            draftID: aggregate.chat.draft.draftID,
            version: aggregate.chat.draft.version + 1,
            text: aggregate.chat.draft.text,
            updatedAt: aggregate.chat.draft.updatedAt
        )
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120001000Z-5KMN"),
            draftID: aggregate.chat.draft.draftID,
            draftVersion: aggregate.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120001000Z-6PQR"
            )
        )

        XCTAssertThrowsError(
            try CoachContextPendingTurnRequest(
                library: Self.scope,
                chatID: aggregate.chat.id,
                draft: otherDraft,
                pendingUserTurn: pending
            )
        ) { error in
            XCTAssertEqual(error as? CoachContextRequestError, .pendingDraftMismatch)
        }
    }

    func testCreateNewChatRecoveryCarriesImmutablePinsWithoutCreatingAnything() throws {
        let aggregate = try fixtureAggregate()
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120001000Z-5KMN"),
            draftID: aggregate.chat.draft.draftID,
            draftVersion: aggregate.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120001000Z-6PQR"
            ),
            failure: .coachContextCannotFit
        )

        let intent = try CoachContextCreateNewChatRecoveryIntent(
            chat: aggregate.chat,
            pendingUserTurn: pending
        )

        XCTAssertEqual(intent.sourceChatID, aggregate.chat.id)
        XCTAssertEqual(intent.sourcePendingUserTurnID, pending.id)
        XCTAssertEqual(intent.suggestedAttachments, aggregate.chat.attachments)
    }

    private static let scope = LibraryScope(
        libraryID: try! LibraryID("lib-20260830T115900000Z-2ABC")
    )

    private func fixtureAggregate(draftText: String = "Current Draft") throws -> ChatAggregate {
        let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
        let base = try ChatAggregate.emptyDevelopmentChat(
            chatID: ChatID("cht-20260830T120000000Z-2ABC"),
            draftID: ChatDraftID("drf-20260830T120000000Z-3DEF"),
            memoryID: CoachMemoryID("mem-20260830T120000000Z-4GHJ"),
            instant: instant,
            profileStatementGeneration: 0
        )
        let draft = try base.chat.draft.edited(text: draftText, at: instant)
        return try ChatAggregate(
            chat: base.chat.replacingDraft(with: draft),
            memory: base.memory
        )
    }

    private func fixtureConfiguration(
        contextWindow: Int = 10_000
    ) throws -> CoachContextConfiguration {
        try CoachContextConfiguration(
            descriptor: CoachProviderDescriptor(
                displayName: "Synthetic fixture",
                contextBudget: CoachContextBudget(
                    contextWindowTokens: contextWindow,
                    responseReservedTokens: 32,
                    safetyMarginTokens: 8
                ),
                coachMemoryMaxTokens: 1
            ),
            policy: CoachProviderEstimationPolicy(
                providerIdentifier: "synthetic-fixture-v1",
                responseCollectorByteCeiling: 8_192,
                framing: CoachProviderFraming(),
                attachmentProjectionPolicy: try CoachAttachmentProjectionPolicy(
                    maximumInlineTranscriptTokens: 8_192,
                    tokenEstimator: .utf8ByteUpperBound()
                )
            )
        )
    }
}

private struct UnconfiguredProviderUnavailableSnapshotPort:
    CoachContextSnapshotPort
{
    func resolveNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        .providerUnavailable
    }

    func resolveChat(
        _ request: CoachContextChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        .providerUnavailable
    }

    func resolvePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextSnapshotOutcome {
        .providerUnavailable
    }

    func isCurrent(_ authority: CoachContextSnapshotAuthority) async -> Bool {
        false
    }

    func acquireAuthorityLease(
        _ authority: CoachContextSourceLeaseAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        .stale
    }
}

private actor RecordingCoachContextSnapshotPort: CoachContextSnapshotPort {
    enum Request: Equatable {
        case newChat(CoachContextNewChatQuoteRequest)
        case chat(CoachContextChatQuoteRequest)
        case pending(CoachContextPendingTurnRequest)
    }

    private let configuration: CoachContextConfiguration
    private(set) var requests: [Request] = []
    private(set) var resolvedTriggers: [CoachContextTrigger] = []

    init(configuration: CoachContextConfiguration) {
        self.configuration = configuration
    }

    func resolveNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        requests.append(.newChat(request))
        do {
            let input = try CoachContextQuoteInput(
                profile: Self.profile,
                memory: Self.memory,
                creation: request.creation
            )
            resolvedTriggers.append(input.trigger)
            return .resolved(
                try CoachContextResolvedSnapshot(
                    input: input,
                    configuration: configuration,
                    authority: CoachContextSnapshotAuthority(
                        binding: .newChat(
                            library: request.library,
                            attachments: request.attachments,
                            creation: request.creation
                        ),
                        contextGeneration: 1,
                        configurationGeneration: 1
                    )
                )
            )
        } catch {
            return .sourceUnavailable
        }
    }

    func resolveChat(
        _ request: CoachContextChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        requests.append(.chat(request))
        return snapshot(
            draft: request.draft,
            binding: .chat(
                library: request.library,
                chatID: request.chatID,
                draftID: request.draft.draftID,
                draftVersion: request.draft.version
            )
        )
    }

    func resolvePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextSnapshotOutcome {
        requests.append(.pending(request))
        return snapshot(
            draft: request.draft,
            binding: .pending(
                library: request.library,
                chatID: request.chatID,
                draftID: request.draft.draftID,
                draftVersion: request.draft.version,
                pendingUserTurnID: request.pendingUserTurn.id,
                responsePositionID: request.pendingUserTurn.responsePositionID
            )
        )
    }

    func isCurrent(_ authority: CoachContextSnapshotAuthority) async -> Bool {
        authority.contextGeneration == 1 && authority.configurationGeneration == 1
    }

    func acquireAuthorityLease(
        _ authority: CoachContextSourceLeaseAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        await acquireImmutableAuthorityLease(authority)
    }

    private func snapshot(
        draft: ChatDraft,
        binding: CoachContextSnapshotBinding
    ) -> CoachContextSnapshotOutcome {
        do {
            let input = try CoachContextQuoteInput(
                profile: Self.profile,
                memory: Self.memory,
                history: [.user(text: "Earlier")],
                currentDraft: draft.text
            )
            resolvedTriggers.append(input.trigger)
            return .resolved(
                try CoachContextResolvedSnapshot(
                    input: input,
                    configuration: configuration,
                    authority: CoachContextSnapshotAuthority(
                        binding: binding,
                        contextGeneration: 1,
                        configurationGeneration: 1
                    )
                )
            )
        } catch {
            return .sourceUnavailable
        }
    }

    private static let profile = CanonicalJSONValue.object([
        "statements": .array([]),
    ])
    private static let memory = CanonicalJSONValue.object([
        "generalNotes": .string("Remember"),
        "sessionSummaries": .array([]),
    ])
}

private actor SuspendingAuthoritySnapshotPort: CoachContextSnapshotPort {
    private let configuration: CoachContextConfiguration
    private var contextGeneration: UInt64 = 1
    private var configurationGeneration: UInt64 = 1
    private(set) var currentDraft: ChatDraft?
    private(set) var measuredDrafts: [ChatDraft] = []
    private var validationStarted = false
    private var validationStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var validationContinuation: CheckedContinuation<Void, Never>?

    init(configuration: CoachContextConfiguration) {
        self.configuration = configuration
    }

    func resolveNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        .sourceUnavailable
    }

    func resolveChat(
        _ request: CoachContextChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        .sourceUnavailable
    }

    func resolvePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextSnapshotOutcome {
        currentDraft = request.draft
        measuredDrafts.append(request.draft)
        do {
            return .resolved(
                try CoachContextResolvedSnapshot(
                    input: CoachContextQuoteInput(
                        profile: .object(["statements": .array([])]),
                        memory: .object([
                            "generalNotes": .string("Same serialized context"),
                            "sessionSummaries": .array([]),
                        ]),
                        history: [.user(text: "Unchanged history text")],
                        currentDraft: request.draft.text
                    ),
                    configuration: configuration,
                    authority: CoachContextSnapshotAuthority(
                        binding: .pending(
                            library: request.library,
                            chatID: request.chatID,
                            draftID: request.draft.draftID,
                            draftVersion: request.draft.version,
                            pendingUserTurnID: request.pendingUserTurn.id,
                            responsePositionID: request.pendingUserTurn.responsePositionID
                        ),
                        contextGeneration: contextGeneration,
                        configurationGeneration: configurationGeneration
                    )
                )
            )
        } catch {
            return .sourceUnavailable
        }
    }

    func isCurrent(_ authority: CoachContextSnapshotAuthority) async -> Bool {
        validationStarted = true
        let waiters = validationStartWaiters
        validationStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            validationContinuation = continuation
        }
        return authority.contextGeneration == contextGeneration &&
            authority.configurationGeneration == configurationGeneration
    }

    func acquireAuthorityLease(
        _ authority: CoachContextSourceLeaseAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        await acquireImmutableAuthorityLease(authority)
    }

    func waitUntilValidationStarts() async {
        guard !validationStarted else { return }
        await withCheckedContinuation { continuation in
            validationStartWaiters.append(continuation)
        }
    }

    func advance(
        to draft: ChatDraft,
        contextGeneration: UInt64,
        configurationGeneration: UInt64
    ) {
        currentDraft = draft
        self.contextGeneration = contextGeneration
        self.configurationGeneration = configurationGeneration
    }

    func resumeValidation() {
        validationContinuation?.resume()
        validationContinuation = nil
    }
}

private actor WrongBindingSnapshotPort: CoachContextSnapshotPort {
    private let configuration: CoachContextConfiguration
    private let wrongDraft: ChatDraft
    private(set) var validationCount = 0

    init(configuration: CoachContextConfiguration, wrongDraft: ChatDraft) {
        self.configuration = configuration
        self.wrongDraft = wrongDraft
    }

    func resolveNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        .sourceUnavailable
    }

    func resolveChat(
        _ request: CoachContextChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        .sourceUnavailable
    }

    func resolvePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextSnapshotOutcome {
        do {
            return .resolved(
                try CoachContextResolvedSnapshot(
                    input: CoachContextQuoteInput(
                        profile: .object(["statements": .array([])]),
                        memory: .object([
                            "generalNotes": .string("Same serialized context"),
                            "sessionSummaries": .array([]),
                        ]),
                        history: [],
                        currentDraft: request.draft.text
                    ),
                    configuration: configuration,
                    authority: CoachContextSnapshotAuthority(
                        binding: .pending(
                            library: request.library,
                            chatID: request.chatID,
                            draftID: wrongDraft.draftID,
                            draftVersion: wrongDraft.version,
                            pendingUserTurnID: request.pendingUserTurn.id,
                            responsePositionID: request.pendingUserTurn.responsePositionID
                        ),
                        contextGeneration: 99,
                        configurationGeneration: 99
                    )
                )
            )
        } catch {
            return .sourceUnavailable
        }
    }

    func isCurrent(_ authority: CoachContextSnapshotAuthority) async -> Bool {
        validationCount += 1
        return true
    }

    func acquireAuthorityLease(
        _ authority: CoachContextSourceLeaseAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        await acquireImmutableAuthorityLease(authority)
    }
}
