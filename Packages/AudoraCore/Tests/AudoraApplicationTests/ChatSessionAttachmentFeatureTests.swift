@testable @_spi(CoachContextQualification) import AudoraApplication
import AudoraDomain
import Foundation
import XCTest

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class ChatSessionAttachmentFeatureTests: XCTestCase {
    func testAttachmentMetadataUsesBoundedUnicodeScalarsAndRejectsControls() throws {
        let boundary = String(repeating: "😀", count: 256)
        let sessionID = try SessionID("ses-20260830T110000000Z-5JKM")
        let revisionID = try TranscriptRevisionID("trv-20260830T113000000Z-6NPQ")

        XCTAssertNoThrow(
            try ChatAttachmentCandidate(
                sessionID: sessionID,
                transcriptRevisionID: revisionID,
                displayLabel: boundary,
                durationMilliseconds: 1,
                approximateTranscriptTokens: 0,
                delivery: .inline
            )
        )
        XCTAssertNoThrow(try ChatAttachmentFilterQuery(boundary))

        let overLimit = boundary + "😀"
        XCTAssertThrowsError(
            try ChatAttachmentCandidate(
                sessionID: sessionID,
                transcriptRevisionID: revisionID,
                displayLabel: overLimit,
                durationMilliseconds: 1,
                approximateTranscriptTokens: 0,
                delivery: .inline
            )
        ) { error in
            XCTAssertEqual(error as? ChatAttachmentCandidateError, .invalidDisplayLabel)
        }
        XCTAssertThrowsError(try ChatAttachmentFilterQuery(overLimit)) { error in
            XCTAssertEqual(error as? ChatAttachmentFilterQueryError, .tooLong)
        }

        for rejected in ["", "nul\u{0}", "control\u{1F}", "delete\u{7F}", "c1\u{9F}"] {
            XCTAssertThrowsError(
                try ChatAttachmentCandidate(
                    sessionID: sessionID,
                    transcriptRevisionID: revisionID,
                    displayLabel: rejected,
                    durationMilliseconds: 1,
                    approximateTranscriptTokens: 0,
                    delivery: .inline
                )
            )
            if !rejected.isEmpty {
                XCTAssertThrowsError(try ChatAttachmentFilterQuery(rejected))
            }
        }
    }

    func testOnlyProviderUnavailabilityPermitsCreationWithoutAQuote() {
        XCTAssertTrue(
            ChatCreationFeasibility.unavailable(.providerUnavailable).permitsCreation
        )
        XCTAssertFalse(
            ChatCreationFeasibility.unavailable(.invalidContext).permitsCreation
        )
        XCTAssertFalse(
            ChatCreationFeasibility.unavailable(.sourceUnavailable).permitsCreation
        )
    }

    func testCatalogAndCandidateMetadataAreBoundedBeforePresentation() async throws {
        XCTAssertThrowsError(
            try ChatAttachmentCandidate(
                sessionID: SessionID("ses-20260830T110000000Z-5KMN"),
                transcriptRevisionID: TranscriptRevisionID(
                    "trv-20260830T111000000Z-6PQR"
                ),
                displayLabel: "Bounded Session",
                durationMilliseconds: 90_000,
                approximateTranscriptTokens:
                    ChatAttachmentCandidate.maximumApproximateTranscriptTokens + 1,
                delivery: .inline
            )
        )
        let one = try candidate(
            session: "ses-20260830T110000000Z-5KMN",
            revision: "trv-20260830T111000000Z-6PQR",
            label: "Bounded Session"
        )
        let feature = makeFeature(
            source: AttachmentSourceFixture(
                candidates: Array(
                    repeating: one,
                    count: ChatAttachmentCandidate.maximumCatalogCount + 1
                )
            )
        )
        await feature.send(.start(Self.context))

        await feature.send(.beginNewChat(Self.context))

        let state = await feature.currentState
        XCTAssertEqual(state.newChatPicker, .failed)
        XCTAssertEqual(state.notice, .attachmentCatalogFailed)
    }

    func testNewChatPickerSearchesCandidatesAndAllowsZeroSelections() async throws {
        let source = AttachmentSourceFixture(
            candidates: [
                try candidate(
                    session: "ses-20260830T110000000Z-5KMN",
                    revision: "trv-20260830T111000000Z-6PQR",
                    label: "Café rehearsal"
                ),
                try candidate(
                    session: "ses-20260830T112000000Z-7STV",
                    revision: "trv-20260830T113000000Z-8WXY",
                    label: "Pitch practice"
                ),
            ]
        )
        let feature = makeFeature(source: source)
        await feature.send(.start(Self.context))

        await feature.send(.beginNewChat(Self.context))
        await feature.send(
            .setNewChatAttachmentFilter(
                Self.context,
                try ChatAttachmentFilterQuery("CAFE")
            )
        )

        let state = await feature.currentState
        guard case let .ready(picker) = state.newChatPicker else {
            return XCTFail("Expected a ready attachment picker")
        }
        XCTAssertEqual(picker.allRows.count, 2)
        XCTAssertEqual(picker.visibleRows.map(\.displayLabel), ["Café rehearsal"])
        XCTAssertEqual(picker.selectedAttachmentIDs, [])
        XCTAssertEqual(picker.selectionCount, 0)
    }

    func testSelectionLimitIsPickerLocalAndKeepsTheValidSelectionConfirmable() async throws {
        let candidates = try (0...ChatAttachments.maximumCount).map { index in
            try candidate(
                session: String(
                    format: "ses-20260830T110000%03dZ-5KMN",
                    index
                ),
                revision: String(
                    format: "trv-20260830T111000%03dZ-6PQR",
                    index
                ),
                label: String(format: "Session %03d", index)
            )
        }
        let feature = makeFeature(source: AttachmentSourceFixture(candidates: candidates))
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))
        guard case let .ready(initial) = await feature.currentState.newChatPicker else {
            return XCTFail("Expected ready picker")
        }
        for row in initial.allRows.prefix(ChatAttachments.maximumCount) {
            await feature.send(.toggleNewChatAttachment(Self.context, row.id))
        }

        await feature.send(
            .toggleNewChatAttachment(
                Self.context,
                initial.allRows[ChatAttachments.maximumCount].id
            )
        )

        let state = await feature.currentState
        guard case let .ready(picker) = state.newChatPicker else {
            return XCTFail("Expected ready picker")
        }
        XCTAssertEqual(picker.selectionCount, ChatAttachments.maximumCount)
        XCTAssertEqual(
            picker.issue,
            .selectionLimitReached(maximum: ChatAttachments.maximumCount)
        )
        XCTAssertTrue(picker.permitsConfirmation)
        XCTAssertNil(state.notice)
    }

    func testZeroSelectionsCreateAnOrdinaryChatWithNoPins() async {
        let source = AttachmentSourceFixture(candidates: [])
        let store = AttachmentChatStoreFixture()
        let feature = makeFeature(source: source, store: store)
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))

        await feature.send(.confirmNewChat(Self.context))

        let seed = await store.createdSeed
        XCTAssertEqual(seed?.aggregate.chat.attachments, .empty)
        XCTAssertEqual(seed?.aggregate.chat.creation.kind, .newChat)
        XCTAssertNil(seed?.aggregate.chat.creation.originAttachmentID)
    }

    func testSearchEnteredDuringCatalogLoadAppliesToTheLoadedPicker() async throws {
        let candidates = try [
            candidate(
                session: "ses-20260830T110000000Z-5KMN",
                revision: "trv-20260830T111000000Z-6PQR",
                label: "Café rehearsal"
            ),
            candidate(
                session: "ses-20260830T112000000Z-7STV",
                revision: "trv-20260830T113000000Z-8WXY",
                label: "Pitch practice"
            ),
        ]
        let source = SuspendedAttachmentCatalogSource(candidates: candidates)
        let feature = makeFeature(source: source)
        await feature.send(.start(Self.context))

        async let begin: Void = feature.send(.beginNewChat(Self.context))
        await source.waitUntilLoadStarts()
        await feature.send(
            .setNewChatAttachmentFilter(
                Self.context,
                try ChatAttachmentFilterQuery("CAFE")
            )
        )
        await source.resumeLoad()
        await begin

        guard case let .ready(picker) = await feature.currentState.newChatPicker else {
            return XCTFail("Expected a ready attachment picker")
        }
        XCTAssertEqual(picker.filterQuery, try ChatAttachmentFilterQuery("CAFE"))
        XCTAssertEqual(picker.visibleRows.map(\.displayLabel), ["Café rehearsal"])
    }

    func testManySelectionsCreateOneChatWithDeterministicChatScopedPins() async throws {
        let source = AttachmentSourceFixture(
            candidates: [
                try candidate(
                    session: "ses-20260830T112000000Z-7STV",
                    revision: "trv-20260830T113000000Z-8WXY",
                    label: "Zulu practice",
                    duration: 120_000,
                    tokens: 900,
                    delivery: .onDemand
                ),
                try candidate(
                    session: "ses-20260830T110000000Z-5KMN",
                    revision: "trv-20260830T111000000Z-6PQR",
                    label: "Alpha rehearsal",
                    duration: 90_000,
                    tokens: 450,
                    delivery: .inline
                ),
            ]
        )
        let store = AttachmentChatStoreFixture()
        let feature = makeFeature(
            source: source,
            store: store,
            coachContext: DefaultCoachContextFeature(
                source: AttachmentCapacitySource(contextWindow: 20_000)
            )
        )
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))

        guard case let .ready(initial) = await feature.currentState.newChatPicker else {
            return XCTFail("Expected ready picker")
        }
        XCTAssertEqual(initial.allRows.map(\.displayLabel), ["Alpha rehearsal", "Zulu practice"])
        XCTAssertEqual(initial.allRows.map(\.durationMilliseconds), [90_000, 120_000])
        XCTAssertEqual(initial.allRows.map(\.approximateTranscriptTokens), [450, 900])
        XCTAssertEqual(initial.allRows.map(\.delivery), [.inline, .onDemand])
        guard case let .available(quote) = initial.feasibility else {
            return XCTFail("Expected live creation quote")
        }
        XCTAssertGreaterThan(quote.context.categoryCosts[.profile]?.estimatedTokenCount ?? 0, 0)

        for row in initial.allRows {
            await feature.send(.toggleNewChatAttachment(Self.context, row.id))
        }
        await feature.send(.confirmNewChat(Self.context))

        let seed = await store.createdSeed
        XCTAssertEqual(
            seed?.aggregate.chat.attachments.values.map(\.attachmentID.rawValue),
            ["attachment-000001", "attachment-000002"]
        )
        XCTAssertEqual(
            seed?.aggregate.chat.attachments.values.map(\.sessionID.rawValue),
            [
                "ses-20260830T110000000Z-5KMN",
                "ses-20260830T112000000Z-7STV",
            ]
        )
        XCTAssertEqual(seed?.aggregate.chat.creation.kind, .newChat)
        XCTAssertNil(seed?.aggregate.chat.creation.originAttachmentID)
        guard case let .open(reopened) = await feature.currentState.selection else {
            return XCTFail("Committed Chat should open")
        }
        XCTAssertEqual(reopened.chat.attachments, seed?.aggregate.chat.attachments)
        let resolvedRequests = await source.resolvedRequests
        XCTAssertEqual(
            resolvedRequests,
            [seed!.aggregate.chat.attachments, seed!.aggregate.chat.attachments]
        )
    }

    func testOpeningChatResolvesExactPinsWithoutMutatingStore() async throws {
        let candidates = try [
            candidate(
                session: "ses-20260830T110000000Z-5KMN",
                revision: "trv-20260830T111000000Z-6PQR",
                label: "Available Session"
            ),
            candidate(
                session: "ses-20260830T112000000Z-7STV",
                revision: "trv-20260830T113000000Z-8WXY",
                label: "Missing Session"
            ),
            candidate(
                session: "ses-20260830T114000000Z-9Z23",
                revision: "trv-20260830T115000000Z-2ABC",
                label: "Trashed Session"
            ),
            candidate(
                session: "ses-20260830T120000000Z-3DEF",
                revision: "trv-20260830T121000000Z-4GHJ",
                label: "Corrupt Session"
            ),
        ]
        let attachments = try ChatAttachments(
            validating: try candidates.enumerated().map { index, candidate in
                ChatSessionAttachment(
                    attachmentID: try ChatSessionAttachmentID("attachment-\(index + 1)"),
                    sessionID: candidate.sessionID,
                    transcriptRevisionID: candidate.transcriptRevisionID
                )
            }
        )
        let aggregate = try ChatAggregate.developmentChat(
            chatID: ChatID("cht-20260830T120000000Z-2ABC"),
            draftID: ChatDraftID("drf-20260830T120000000Z-3DEF"),
            memoryID: CoachMemoryID("mem-20260830T120000000Z-4GHJ"),
            instant: UTCInstant("2026-08-30T12:00:00.000Z"),
            profileStatementGeneration: 7,
            attachments: attachments
        )
        let source = AttachmentSourceFixture(candidates: candidates)
        await source.markUnavailable(candidates[1], reason: .missing)
        await source.markUnavailable(candidates[2], reason: .inTrash)
        await source.markUnavailable(candidates[3], reason: .corrupt)
        let store = AttachmentChatStoreFixture(existing: aggregate)
        let feature = makeFeature(source: source, store: store)
        await feature.send(.start(Self.context))

        await feature.send(.open(Self.context, aggregate.chat.id))

        let state = await feature.currentState
        guard case let .open(reopened) = state.selection,
              case let .resolved(resolved) = state.openedAttachments
        else { return XCTFail("Expected opened Chat with resolved immutable attachments") }
        XCTAssertEqual(reopened.chat.attachments, attachments)
        XCTAssertEqual(resolved.map(\.attachment), attachments.values)
        XCTAssertEqual(
            resolved.map(\.resolution),
            [
                .available(candidates[0]),
                .unavailable(.missing),
                .unavailable(.inTrash),
                .unavailable(.corrupt),
            ]
        )
        let mutationCount = await store.mutationCount
        XCTAssertEqual(mutationCount, 0)
    }

    func testConfirmRejectsARevisionThatBecameUnavailable() async throws {
        let candidate = try candidate(
            session: "ses-20260830T110000000Z-5KMN",
            revision: "trv-20260830T111000000Z-6PQR",
            label: "Pinned rehearsal"
        )
        let source = AttachmentSourceFixture(candidates: [candidate])
        let store = AttachmentChatStoreFixture()
        let feature = makeFeature(source: source, store: store)
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))
        guard case let .ready(picker) = await feature.currentState.newChatPicker,
              let row = picker.allRows.first
        else { return XCTFail("Expected candidate") }
        await feature.send(.toggleNewChatAttachment(Self.context, row.id))
        await source.markUnavailable(candidate)

        await feature.send(.confirmNewChat(Self.context))

        let rejectedSeed = await store.createdSeed
        let rejectedState = await feature.currentState
        XCTAssertNil(rejectedSeed)
        XCTAssertNil(rejectedState.notice)
        guard case let .ready(rejectedPicker) = rejectedState.newChatPicker else {
            return XCTFail("Rejected selection must remain open")
        }
        XCTAssertEqual(rejectedPicker.issue, .attachmentUnavailable)
        XCTAssertFalse(rejectedPicker.permitsConfirmation)

        await feature.send(.confirmNewChat(Self.context))

        let resolvedRequests = await source.resolvedRequests
        XCTAssertEqual(resolvedRequests.count, 1)

        await feature.send(.toggleNewChatAttachment(Self.context, row.id))

        guard case let .ready(recoveredPicker) = await feature.currentState.newChatPicker else {
            return XCTFail("Expected selection change to keep the picker open")
        }
        XCTAssertNil(recoveredPicker.issue)
        XCTAssertTrue(recoveredPicker.permitsConfirmation)
    }

    func testConfirmRejectsAuthoritativeOverCapacityQuote() async throws {
        let source = AttachmentSourceFixture(
            candidates: [try candidate(
                session: "ses-20260830T110000000Z-5KMN",
                revision: "trv-20260830T111000000Z-6PQR",
                label: "Large rehearsal"
            )]
        )
        let store = AttachmentChatStoreFixture()
        let capacity = AttachmentCapacitySource(
            contextWindows: [20_000, 20_000, 400],
            transcriptBytes: 1_000
        )
        let feature = makeFeature(
            source: source,
            store: store,
            coachContext: DefaultCoachContextFeature(
                source: capacity
            )
        )
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))
        guard case let .ready(picker) = await feature.currentState.newChatPicker,
              let row = picker.allRows.first
        else { return XCTFail("Expected candidate") }

        await feature.send(.toggleNewChatAttachment(Self.context, row.id))
        await feature.send(.confirmNewChat(Self.context))

        let rejectedSeed = await store.createdSeed
        let rejectedState = await feature.currentState
        XCTAssertNil(rejectedSeed)
        XCTAssertNil(rejectedState.notice)
        guard case let .ready(rejectedPicker) = rejectedState.newChatPicker else {
            return XCTFail("Rejected selection must remain open")
        }
        XCTAssertEqual(rejectedPicker.issue, .contextCannotFit)
        XCTAssertFalse(rejectedPicker.permitsConfirmation)

        await feature.send(.confirmNewChat(Self.context))

        let quoteCount = await capacity.newChatResolutionCount
        XCTAssertEqual(quoteCount, 3)
    }

    private func makeFeature(
        source: any ChatSessionAttachmentSource,
        store: AttachmentChatStoreFixture = AttachmentChatStoreFixture(),
        coachContext: any CoachContextCoordinating = DefaultCoachContextFeature()
    ) -> DefaultChatFeature {
        DefaultChatFeature(
            store: store,
            profileReader: AttachmentProfileReaderFixture(),
            clock: AttachmentClockFixture(),
            chatIDGenerator: AttachmentIDsFixture(),
            draftIDGenerator: AttachmentIDsFixture(),
            memoryIDGenerator: AttachmentIDsFixture(),
            pendingUserTurnIDGenerator: AttachmentIDsFixture(),
            responsePositionIDGenerator: AttachmentIDsFixture(),
            autosaveScheduler: AttachmentAutosaveFixture(),
            coachContext: coachContext,
            attachmentSource: source
        )
    }

    private static let scope = LibraryScope(
        libraryID: try! LibraryID("lib-20260830T100000000Z-2ABC")
    )

    private static let context = ChatCommandContext(
        libraryScope: scope,
        generation: 1
    )

    private func candidate(
        session: String,
        revision: String,
        label: String,
        duration: UInt64 = 90_000,
        tokens: Int = 450,
        delivery: ChatAttachmentDelivery = .inline
    ) throws -> ChatAttachmentCandidate {
        try ChatAttachmentCandidate(
            sessionID: SessionID(session),
            transcriptRevisionID: TranscriptRevisionID(revision),
            displayLabel: label,
            durationMilliseconds: duration,
            approximateTranscriptTokens: tokens,
            delivery: delivery
        )
    }
}

private actor AttachmentSourceFixture: ChatSessionAttachmentSource {
    let candidates: [ChatAttachmentCandidate]
    private var unavailable: [String: ChatAttachmentUnavailableReason] = [:]
    private(set) var resolvedRequests: [ChatAttachments] = []

    init(candidates: [ChatAttachmentCandidate]) {
        self.candidates = candidates
    }

    func loadCandidates(in library: LibraryScope) async -> ChatAttachmentCatalogOutcome {
        .loaded(candidates)
    }

    func resolve(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentResolutionOutcome {
        resolvedRequests.append(attachments)
        return .resolved(attachments.values.map { attachment in
            let key = attachment.sessionID.rawValue + ":" +
                attachment.transcriptRevisionID.rawValue
            let candidate = candidates.first {
                $0.sessionID == attachment.sessionID &&
                    $0.transcriptRevisionID == attachment.transcriptRevisionID
            }
            return try! ResolvedChatAttachment(
                attachment: attachment,
                resolution: unavailable[key].map(ChatAttachmentResolution.unavailable)
                    ?? candidate.map(ChatAttachmentResolution.available)
                    ?? .unavailable(.missing)
            )
        })
    }

    func markUnavailable(
        _ candidate: ChatAttachmentCandidate,
        reason: ChatAttachmentUnavailableReason = .missing
    ) {
        unavailable[
            candidate.sessionID.rawValue + ":" + candidate.transcriptRevisionID.rawValue
        ] = reason
    }
}

private actor SuspendedAttachmentCatalogSource: ChatSessionAttachmentSource {
    private let candidates: [ChatAttachmentCandidate]
    private var loadStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(candidates: [ChatAttachmentCandidate]) {
        self.candidates = candidates
    }

    func loadCandidates(in library: LibraryScope) async -> ChatAttachmentCatalogOutcome {
        loadStarted = true
        await withCheckedContinuation { continuation = $0 }
        return .loaded(candidates)
    }

    func resolve(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentResolutionOutcome {
        .failed
    }

    func waitUntilLoadStarts() async {
        while !loadStarted { await Task.yield() }
    }

    func resumeLoad() {
        continuation?.resume()
        continuation = nil
    }
}

private actor AttachmentChatStoreFixture: ChatStorePort {
    private(set) var createdSeed: NewDevelopmentChatSeed?
    private var existing: ChatAggregate?
    private(set) var mutationCount = 0

    init(existing: ChatAggregate? = nil) {
        self.existing = existing
    }

    func loadCatalog(in library: LibraryScope) async -> ChatCatalogOutcome {
        .loaded(existing.map { [.available($0)] } ?? [])
    }
    func create(_ seed: NewDevelopmentChatSeed) async -> ChatMutationOutcome {
        mutationCount += 1
        createdSeed = seed
        existing = seed.aggregate
        return .committed(seed.aggregate)
    }
    func rename(_ mutation: RenameChatMutation) async -> ChatMutationOutcome {
        mutationCount += 1
        return .failed
    }
    func saveDraft(_ mutation: SaveChatDraftMutation) async -> ChatMutationOutcome {
        mutationCount += 1
        return .failed
    }
    func lockPendingUserTurn(
        _ mutation: LockPendingUserTurnMutation
    ) async -> ChatMutationOutcome {
        mutationCount += 1
        return .failed
    }
    func replacePendingUserTurn(
        _ mutation: ReplacePendingUserTurnMutation
    ) async -> ChatMutationOutcome {
        mutationCount += 1
        return .failed
    }
    func discardPendingUserTurn(
        _ mutation: DiscardPendingUserTurnMutation
    ) async -> ChatMutationOutcome {
        mutationCount += 1
        return .failed
    }
    func load(_ chatID: ChatID, in library: LibraryScope) async -> ChatLoadOutcome {
        guard let existing, existing.chat.id == chatID else { return .missing }
        return .loaded(existing)
    }
}

private struct AttachmentProfileReaderFixture: ProfileStatementGenerationReading {
    func statementGeneration(in library: LibraryScope) async -> UInt64? { 7 }
}

private struct AttachmentClockFixture: ChatClock {
    func now() async -> UTCInstant { try! UTCInstant("2026-08-30T12:00:00.000Z") }
}

private struct AttachmentIDsFixture: ChatIDGenerator, ChatDraftIDGenerator,
    CoachMemoryIDGenerator, PendingUserTurnIDGenerator, ChatResponsePositionIDGenerator
{
    func generateChatID(at instant: UTCInstant) async -> ChatID {
        try! ChatID("cht-20260830T120000000Z-2ABC")
    }

    func generateChatDraftID(at instant: UTCInstant) async -> ChatDraftID {
        try! ChatDraftID("drf-20260830T120000000Z-3DEF")
    }

    func generateCoachMemoryID(at instant: UTCInstant) async -> CoachMemoryID {
        try! CoachMemoryID("mem-20260830T120000000Z-4GHJ")
    }

    func generatePendingUserTurnID(at instant: UTCInstant) async -> PendingUserTurnID {
        try! PendingUserTurnID("ptu-20260830T120000000Z-5KMN")
    }

    func generateChatResponsePositionID(
        at instant: UTCInstant
    ) async -> ChatResponsePositionID {
        try! ChatResponsePositionID("rsp-20260830T120000000Z-6PQR")
    }
}

private struct AttachmentAutosaveFixture: ChatAutosaveScheduling {
    func sleep(forNanoseconds nanoseconds: UInt64) async throws {}
}

private actor AttachmentCapacitySource: CoachContextSnapshotPort {
    private let contextWindows: [Int]
    private let transcriptBytes: Int
    private(set) var newChatResolutionCount = 0

    init(contextWindow: Int, transcriptBytes: Int = 32) {
        contextWindows = [contextWindow]
        self.transcriptBytes = transcriptBytes
    }

    init(contextWindows: [Int], transcriptBytes: Int = 32) {
        precondition(!contextWindows.isEmpty)
        self.contextWindows = contextWindows
        self.transcriptBytes = transcriptBytes
    }

    func resolveNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        let contextWindow = contextWindows[
            min(newChatResolutionCount, contextWindows.count - 1)
        ]
        newChatResolutionCount += 1
        do {
            let prepared = request.attachments.values.map { attachment in
                PreparedCoachAttachment.inline(
                    requestValue: .object([
                        "sessionAttachmentId": .string(attachment.attachmentID.rawValue),
                        "displayLabel": .string("Synthetic Session"),
                        "transcript": .object([
                            "text": .string(String(repeating: "x", count: transcriptBytes)),
                        ]),
                    ])
                )
            }
            return .resolved(
                try CoachContextResolvedSnapshot(
                    input: CoachContextQuoteInput(
                        profile: .object([
                            "statements": .array([
                                .object([
                                    "id": .string("profile-statement-1"),
                                    "wording": .string("Synthetic current Profile"),
                                ]),
                            ]),
                        ]),
                        memory: .object([
                            "generalNotes": .string(""),
                            "sessionSummaries": .array([]),
                        ]),
                        creation: request.creation,
                        attachments: prepared
                    ),
                    configuration: try CoachContextConfiguration(
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
                            attachmentProjectionPolicy:
                                try CoachAttachmentProjectionPolicy(
                                    maximumInlineTranscriptTokens: 8_192,
                                    tokenEstimator: .utf8ByteUpperBound()
                                )
                        )
                    ),
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
    ) async -> CoachContextSnapshotOutcome { .sourceUnavailable }

    func resolvePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextSnapshotOutcome { .sourceUnavailable }

    func isCurrent(_ authority: CoachContextSnapshotAuthority) async -> Bool {
        authority.contextGeneration == 1 && authority.configurationGeneration == 1
    }
}
