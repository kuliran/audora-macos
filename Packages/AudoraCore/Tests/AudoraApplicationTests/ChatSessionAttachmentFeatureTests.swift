@testable @_spi(CoachContextQualification) @_spi(ChatCreationAuthorityTesting) import AudoraApplication
import AudoraDomain
import Foundation
import XCTest

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class ChatSessionAttachmentFeatureTests: XCTestCase {
    func testCandidateTokenCostRepresentsMaximumSupportedCanonicalEvidence()
        throws
    {
        let sessionID = try SessionID("ses-20260830T110000000Z-5JKM")
        let revisionID = try TranscriptRevisionID("trv-20260830T113000000Z-6NPQ")

        XCTAssertEqual(
            ChatAttachmentCandidate.maximumApproximateTranscriptTokens,
            67_108_864
        )
        XCTAssertNoThrow(
            try ChatAttachmentCandidate(
                sessionID: sessionID,
                transcriptRevisionID: revisionID,
                displayLabel: "Maximum canonical evidence",
                durationMilliseconds: 1,
                approximateTranscriptTokens: 67_108_864,
                delivery: .onDemand
            )
        )
        XCTAssertThrowsError(
            try ChatAttachmentCandidate(
                sessionID: sessionID,
                transcriptRevisionID: revisionID,
                displayLabel: "Beyond canonical evidence",
                durationMilliseconds: 1,
                approximateTranscriptTokens: 67_108_865,
                delivery: .onDemand
            )
        ) { error in
            XCTAssertEqual(
                error as? ChatAttachmentCandidateError,
                .invalidTranscriptCost
            )
        }
    }

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

    func testOnlyFeasibleQualifiedProviderOutagePermitsCreationWithoutAQuote() {
        XCTAssertTrue(
            ChatCreationFeasibility.providerUnavailable(
                previouslyQualifiedProviderUnavailableCapacityLowerBound()
            ).permitsCreation
        )
        XCTAssertFalse(
            ChatCreationFeasibility.unavailable(.providerUnavailable).permitsCreation
        )
        XCTAssertFalse(
            ChatCreationFeasibility.unavailable(.invalidContext).permitsCreation
        )
        XCTAssertFalse(
            ChatCreationFeasibility.unavailable(.sourceUnavailable).permitsCreation
        )
    }

    func testLiveEvidenceCompositionFailsClosedWithoutQualifiedConfiguration()
        async throws
    {
        let feature = DefaultCoachContextFeature(
            attachmentEvidenceSource: AttachmentEvidenceSourceForFeature(
                evidence: try attachmentEvidence()
            )
        )
        let request = try CoachContextNewChatQuoteRequest(
            library: Self.scope,
            attachments: .empty,
            creationKind: .newChat
        )

        let catalog = await feature.loadAttachmentCandidates(in: Self.scope)
        let defaultCatalog = await DefaultCoachContextFeature()
            .loadAttachmentCandidates(in: Self.scope)
        let quote = await feature.quoteNewChat(request)

        XCTAssertEqual(catalog, .qualifiedConfigurationUnavailable)
        XCTAssertEqual(defaultCatalog, .qualifiedConfigurationUnavailable)
        XCTAssertEqual(quote, .unavailable(.sourceUnavailable))
    }

    func testKnownQualifiedConfigurationWithoutAnAttachmentAdapterStaysGenericFailure()
        async
    {
        let feature = previouslyQualifiedProviderUnavailableCoachContextFixture()

        let catalog = await feature.loadAttachmentCandidates(in: Self.scope)

        XCTAssertEqual(catalog, .failed)
    }

    func testProviderUnavailableRejectsEvidenceThatCannotFitQualifiedInputCeiling()
        async throws
    {
        let evidence = try attachmentEvidence(
            transcriptText: String(repeating: "x", count: 1_000)
        )
        let context = DefaultCoachContextFeature(
            source: try KnownQualifiedProviderUnavailableCapacitySource(
                contextWindow: 400
            ),
            attachmentEvidenceSource: AttachmentEvidenceSourceForFeature(
                evidence: evidence
            ),
            configurationAuthorityID:
                attachmentFeatureConfigurationStamp.authorityID
        )
        let store = AttachmentChatStoreFixture()
        let feature = makeFeature(coordinatedContext: context, store: store)
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))
        guard case let .ready(initial) = await feature.currentState.newChatPicker,
              let row = initial.allRows.first
        else { return XCTFail("Expected exact projected evidence") }

        await feature.send(.toggleNewChatAttachment(Self.context, row.id))

        guard case let .ready(rejected) = await feature.currentState.newChatPicker else {
            return XCTFail("Expected the impossible selection to remain visible")
        }
        XCTAssertEqual(rejected.issue, .contextCannotFit)
        XCTAssertFalse(rejected.permitsConfirmation)

        await feature.sendCurrentNewChatConfirmation(Self.context)

        let createdSeed = await store.createdSeed
        XCTAssertNil(createdSeed)
    }

    func testNewChatPreservesMissingQualifiedConfigurationAsSpecificRecovery()
        async throws
    {
        let context = DefaultCoachContextFeature(
            attachmentEvidenceSource: AttachmentEvidenceSourceForFeature(
                evidence: try attachmentEvidence()
            )
        )
        let feature = makeFeature(
            coordinatedContext: context,
            store: AttachmentChatStoreFixture()
        )
        await feature.send(.start(Self.context))

        await feature.send(.beginNewChat(Self.context))

        let state = await feature.currentState
        XCTAssertEqual(state.newChatPicker, .failed)
        XCTAssertEqual(state.notice, .qualifiedCoachConfigurationUnavailable)
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
        for (index, row) in initial.allRows
            .prefix(ChatAttachments.maximumCount)
            .enumerated()
        {
            await feature.send(.toggleNewChatAttachment(Self.context, row.id))
            guard case let .ready(intermediate) = await feature.currentState.newChatPicker else {
                return XCTFail("Selection \(index + 1) must keep the picker ready")
            }
            XCTAssertTrue(
                intermediate.permitsConfirmation,
                "Selection \(index + 1) must remain confirmable; issue: " +
                    String(describing: intermediate.issue)
            )
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

        await feature.sendCurrentNewChatConfirmation(Self.context)

        let seed = await store.createdSeed
        XCTAssertEqual(seed?.aggregate.chat.attachments, .empty)
        XCTAssertEqual(seed?.aggregate.chat.creation.kind, .newChat)
        XCTAssertNil(seed?.aggregate.chat.creation.originAttachmentID)
    }

    func testConfirmMissingQualifiedConfigurationKeepsExactSelectionAndRequiresFreshConfirmation()
        async throws
    {
        let candidate = try candidate(
            session: "ses-20260830T110000000Z-5KMN",
            revision: "trv-20260830T111000000Z-6PQR",
            label: "Pinned during configuration outage"
        )
        let source = AttachmentSourceFixture(
            candidates: [candidate],
            configurationUnavailableOnResolve: true
        )
        let store = AttachmentChatStoreFixture()
        let feature = makeFeature(source: source, store: store)
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))
        guard case let .ready(initial) = await feature.currentState.newChatPicker,
              let row = initial.allRows.first
        else { return XCTFail("Expected the exact candidate") }
        await feature.send(.toggleNewChatAttachment(Self.context, row.id))
        guard case let .ready(quoted) = await feature.currentState.newChatPicker,
              let quotedToken = quoted.confirmationToken
        else { return XCTFail("Expected a quoted exact selection") }

        await feature.send(.confirmNewChat(Self.context, quotedToken))

        let createdSeed = await store.createdSeed
        XCTAssertNil(createdSeed)
        let state = await feature.currentState
        XCTAssertEqual(state.notice, .qualifiedCoachConfigurationUnavailable)
        guard case let .ready(blocked) = state.newChatPicker else {
            return XCTFail("The ready picker and exact pins must survive the outage")
        }
        XCTAssertEqual(blocked.allRows, quoted.allRows)
        XCTAssertEqual(blocked.visibleRows, quoted.visibleRows)
        XCTAssertEqual(blocked.selectedAttachmentIDs, quoted.selectedAttachmentIDs)
        let selectedRows = blocked.allRows.filter {
            blocked.selectedAttachmentIDs.contains($0.id)
        }
        XCTAssertEqual(selectedRows.map(\.attachment.sessionID), [candidate.sessionID])
        XCTAssertEqual(
            selectedRows.map(\.attachment.transcriptRevisionID),
            [candidate.transcriptRevisionID]
        )
        XCTAssertEqual(blocked.issue, .qualifiedConfigurationUnavailable)
        XCTAssertNil(blocked.confirmationToken)
        XCTAssertFalse(blocked.permitsConfirmation)
    }

    func testConfigurationRecoveryReprojectsExactSelectionsAndRequiresFreshConfirmation()
        async throws
    {
        let first = try candidate(
            session: "ses-20260830T110000000Z-5KMN",
            revision: "trv-20260830T111000000Z-6PQR",
            label: "First original projection",
            tokens: 100
        )
        let second = try candidate(
            session: "ses-20260830T112000000Z-7STV",
            revision: "trv-20260830T113000000Z-8WXY",
            label: "Second original projection",
            tokens: 200
        )
        let source = AttachmentSourceFixture(candidates: [first, second])
        let store = AttachmentChatStoreFixture()
        let feature = makeFeature(source: source, store: store)
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))
        guard case let .ready(initial) = await feature.currentState.newChatPicker else {
            return XCTFail("Expected the initial projection")
        }
        for row in initial.allRows {
            await feature.send(.toggleNewChatAttachment(Self.context, row.id))
        }
        guard case let .ready(quoted) = await feature.currentState.newChatPicker,
              let staleToken = quoted.confirmationToken
        else { return XCTFail("Expected the exact quoted selections") }
        await source.setConfigurationUnavailableOnResolve(true)
        await feature.send(.confirmNewChat(Self.context, staleToken))

        let refreshedFirst = try candidate(
            session: first.sessionID.rawValue,
            revision: first.transcriptRevisionID.rawValue,
            label: "First refreshed projection",
            tokens: 300,
            delivery: .onDemand
        )
        let refreshedSecond = try candidate(
            session: second.sessionID.rawValue,
            revision: second.transcriptRevisionID.rawValue,
            label: "Second refreshed projection",
            tokens: 400,
            delivery: .onDemand
        )
        await source.replaceCandidates([refreshedFirst, refreshedSecond])
        await source.setConfigurationUnavailableOnResolve(false)

        await feature.send(.beginNewChat(Self.context))

        guard case let .ready(recovered) = await feature.currentState.newChatPicker,
              let freshToken = recovered.confirmationToken
        else { return XCTFail("Expected a recovered, freshly quoted picker") }
        XCTAssertEqual(recovered.allRows.map(\.displayLabel), [
            "First refreshed projection", "Second refreshed projection",
        ])
        XCTAssertEqual(recovered.allRows.map(\.approximateTranscriptTokens), [300, 400])
        let selectedRows = recovered.allRows.filter {
            recovered.selectedAttachmentIDs.contains($0.id)
        }
        XCTAssertEqual(selectedRows.map(\.attachment.sessionID), [
            first.sessionID, second.sessionID,
        ])
        XCTAssertEqual(selectedRows.map(\.attachment.transcriptRevisionID), [
            first.transcriptRevisionID, second.transcriptRevisionID,
        ])
        XCTAssertNotEqual(freshToken, staleToken)
        XCTAssertNil(recovered.issue)
        let recoveredState = await feature.currentState
        XCTAssertNil(recoveredState.notice)
        XCTAssertTrue(recovered.permitsConfirmation)
        let seedBeforeFreshConfirmation = await store.createdSeed
        XCTAssertNil(seedBeforeFreshConfirmation)

        await feature.send(.confirmNewChat(Self.context, freshToken))

        let createdSeed = await store.createdSeed
        let created = try XCTUnwrap(createdSeed)
        XCTAssertEqual(created.aggregate.chat.attachments.values.map(\.sessionID), [
            first.sessionID, second.sessionID,
        ])
        XCTAssertEqual(
            created.aggregate.chat.attachments.values.map(\.transcriptRevisionID),
            [first.transcriptRevisionID, second.transcriptRevisionID]
        )
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
        await feature.sendCurrentNewChatConfirmation(Self.context)

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
        let aggregate = try ChatAggregate.newChat(
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
        guard case let .ready(quoted) = await feature.currentState.newChatPicker else {
            return XCTFail("Expected the selected proposal to remain ready")
        }
        XCTAssertTrue(quoted.permitsConfirmation, "Expected a confirmable quote: \(quoted)")
        await source.markUnavailable(candidate)

        await feature.sendCurrentNewChatConfirmation(Self.context)

        let rejectedSeed = await store.createdSeed
        let rejectedState = await feature.currentState
        XCTAssertNil(rejectedSeed)
        XCTAssertNil(rejectedState.notice)
        guard case let .ready(rejectedPicker) = rejectedState.newChatPicker else {
            return XCTFail("Rejected selection must remain open")
        }
        XCTAssertEqual(rejectedPicker.issue, .attachmentUnavailable)
        XCTAssertFalse(rejectedPicker.permitsConfirmation)

        await feature.sendCurrentNewChatConfirmation(Self.context)

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
            contextWindow: 20_000,
            transcriptBytes: 1_000
        )
        let feature = makeFeature(
            coordinatedContext: CapacityBoundCoachContextFixture(
                attachmentSource: source,
                base: DefaultCoachContextFeature(
                    source: capacity,
                    configurationAuthorityID:
                        attachmentFeatureConfigurationStamp.authorityID
                )
            ),
            store: store,
        )
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))
        guard case let .ready(picker) = await feature.currentState.newChatPicker,
              let row = picker.allRows.first
        else { return XCTFail("Expected candidate") }

        await feature.send(.toggleNewChatAttachment(Self.context, row.id))
        await capacity.replaceContextWindow(400)
        await feature.sendCurrentNewChatConfirmation(Self.context)

        let rejectedSeed = await store.createdSeed
        let rejectedState = await feature.currentState
        XCTAssertNil(rejectedSeed)
        XCTAssertNil(rejectedState.notice)
        guard case let .ready(rejectedPicker) = rejectedState.newChatPicker else {
            return XCTFail("Rejected selection must remain open")
        }
        XCTAssertEqual(rejectedPicker.issue, .contextCannotFit)
        XCTAssertFalse(rejectedPicker.permitsConfirmation)

        await feature.sendCurrentNewChatConfirmation(Self.context)

        let quoteCount = await capacity.newChatResolutionCount
        XCTAssertEqual(quoteCount, 3)
    }

    func testProviderConfigurationChangeRefreshesProjectionBeforeCreation()
        async throws
    {
        let evidence = try attachmentEvidence()
        let authority = ChangingAttachmentConfigurationSource()
        let store = AttachmentChatStoreFixture()
        let feature = makeFeature(
            coordinatedContext: DefaultCoachContextFeature(
                source: authority,
                attachmentEvidenceSource:
                    AttachmentEvidenceSourceForFeature(evidence: evidence)
            ),
            store: store
        )
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))
        guard case let .ready(initial) = await feature.currentState.newChatPicker,
              let initialRow = initial.allRows.first
        else { return XCTFail("Expected the initial configured projection") }
        XCTAssertEqual(initialRow.approximateTranscriptTokens, 10)
        XCTAssertEqual(initialRow.delivery, .inline)
        await feature.send(
            .toggleNewChatAttachment(Self.context, initialRow.id)
        )

        await authority.advanceConfiguration()
        await feature.sendCurrentNewChatConfirmation(Self.context)

        let seedBeforeFreshConfirmation = await store.createdSeed
        XCTAssertNil(seedBeforeFreshConfirmation)
        guard case let .ready(refreshed) = await feature.currentState.newChatPicker,
              let refreshedRow = refreshed.allRows.first
        else { return XCTFail("Expected a refreshed configured projection") }
        XCTAssertEqual(refreshedRow.approximateTranscriptTokens, 20)
        XCTAssertEqual(refreshedRow.delivery, .onDemand)
        XCTAssertEqual(refreshed.selectedAttachmentIDs, Set([refreshedRow.id]))
        XCTAssertTrue(refreshed.permitsConfirmation)

        await feature.sendCurrentNewChatConfirmation(Self.context)

        let committedSeed = await store.createdSeed
        XCTAssertNotNil(committedSeed)
    }

    func testEqualGenerationFromDifferentConfigurationAuthorityCannotCreate()
        async throws
    {
        let candidate = try candidate(
            session: "ses-20260830T110000000Z-5KMN",
            revision: "trv-20260830T111000000Z-6PQR",
            label: "Authority rehearsal"
        )
        let coordinator = MismatchedAttachmentAuthorityFixture(
            attachmentSource: AttachmentSourceFixture(candidates: [candidate]),
            base: previouslyQualifiedProviderUnavailableCoachContextFixture()
        )
        let store = AttachmentChatStoreFixture()
        let feature = makeFeature(
            coordinatedContext: coordinator,
            store: store
        )
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))
        guard case let .ready(initial) = await feature.currentState.newChatPicker,
              let row = initial.allRows.first
        else { return XCTFail("Expected initial picker") }
        await feature.send(.toggleNewChatAttachment(Self.context, row.id))

        await coordinator.replaceConfigurationAuthorityWithoutChangingGeneration()
        await feature.sendCurrentNewChatConfirmation(Self.context)

        let seed = await store.createdSeed
        XCTAssertNil(seed)
        guard case let .ready(rejected) = await feature.currentState.newChatPicker else {
            return XCTFail("A mismatched authority must keep the picker open")
        }
        XCTAssertEqual(rejected.issue, .contextUnavailable(.staleState))
        XCTAssertFalse(rejected.permitsConfirmation)
        XCTAssertEqual(rejected.selectionCount, 1)
    }

    func testStaleEvidenceAuthorityAtPersistenceReopensPickerAndRequiresFreshConfirmation()
        async throws
    {
        let candidate = try candidate(
            session: "ses-20260830T110000000Z-5KMN",
            revision: "trv-20260830T111000000Z-6PQR",
            label: "Root-bound rehearsal"
        )
        let source = AttachmentSourceFixture(candidates: [candidate])
        let store = AttachmentChatStoreFixture(
            createOutcomes: [.creationAuthorityChanged]
        )
        let feature = makeFeature(source: source, store: store)
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))
        guard case let .ready(initial) = await feature.currentState.newChatPicker,
              let row = initial.allRows.first
        else { return XCTFail("Expected the root-bound candidate") }
        await feature.send(.toggleNewChatAttachment(Self.context, row.id))
        guard case let .ready(quoted) = await feature.currentState.newChatPicker,
              let quotedToken = quoted.confirmationToken
        else { return XCTFail("Expected an exact quoted authority") }

        await feature.send(.confirmNewChat(Self.context, quotedToken))

        guard case let .ready(requoted) = await feature.currentState.newChatPicker,
              let freshToken = requoted.confirmationToken
        else { return XCTFail("A stale root authority must reopen the picker") }
        XCTAssertNotEqual(freshToken, quotedToken)
        XCTAssertEqual(requoted.selectionCount, 1)
        let rejectedSeed = await store.createdSeed
        XCTAssertNil(rejectedSeed)

        await feature.send(.confirmNewChat(Self.context, freshToken))

        let committedSeed = await store.createdSeed
        XCTAssertNotNil(committedSeed)
    }

    private func makeFeature(
        source: any ChatSessionAttachmentSource,
        store: AttachmentChatStoreFixture = AttachmentChatStoreFixture(),
        coachContext: any CoachContextCoordinating =
            previouslyQualifiedProviderUnavailableCoachContextFixture()
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
            coachContext: AttachmentBoundCoachContextFixture(
                attachmentSource: source,
                base: coachContext
            )
        )
    }

    private func makeFeature(
        coordinatedContext: any ChatCoachContextCoordinating,
        store: AttachmentChatStoreFixture
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
            coachContext: coordinatedContext
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

    private func attachmentEvidence(
        transcriptText: String = "hello"
    ) throws -> ChatAttachmentEvidence {
        let fingerprint = try AudioFingerprint(
            sha256: String(repeating: "a", count: 64)
        )
        let timeRange = try SessionTimeRange(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            sessionDurationMilliseconds: 1_000
        )
        let usePolicy = try EngineUsePolicy(
            policyID: "configuration-refresh-fixture-v1",
            coveredArtifacts: [.transcriptRevision],
            privateLocalUseAllowed: true,
            privateExportAllowed: true,
            externalProcessingAllowed: false,
            publicDistributionAllowed: false,
            commercialUseAllowed: false,
            licenseReference: "test-license",
            licenseSHA256: String(repeating: "b", count: 64)
        )
        return ChatAttachmentEvidence(
            displayLabel: "Configuration rehearsal",
            revision: try TranscriptRevision(
                revisionID: TranscriptRevisionID(
                    "trv-20260830T111000000Z-6PQR"
                ),
                sessionID: SessionID("ses-20260830T110000000Z-5KMN"),
                jobID: TranscriptionJobID("job-20260830T110500000Z-7STV"),
                createdAt: UTCInstant("2026-08-30T11:10:00.000Z"),
                durationMilliseconds: 1_000,
                audioFingerprint: fingerprint,
                sourceFingerprints: [
                    TranscriptSourceFingerprint(
                        audioSourceID: .microphone,
                        fingerprint: fingerprint
                    ),
                ],
                candidateArtifactFingerprint: AudioFingerprint(
                    sha256: String(repeating: "c", count: 64)
                ),
                engine: TranscriptEngineProvenance(
                    provider: "crisperwhisper",
                    model: "small",
                    revision: "configuration-refresh-v1",
                    language: "en",
                    mode: "verbatim",
                    decodingOptionsSHA256: String(repeating: "d", count: 64),
                    qualification: TranscriptEngineQualification(
                        qualificationProfileID: "configuration-refresh-v1",
                        engineLockSHA256: String(repeating: "e", count: 64),
                        runtimeIdentity: "configuration-runtime-v1",
                        runtimeLockSHA256: String(repeating: "f", count: 64),
                        compatibilityPatchID: "configuration-patch-v1"
                    ),
                    usePolicy: usePolicy
                ),
                lines: [
                    TranscriptLine(
                        lineID: TranscriptLineID("l000000"),
                        order: 0,
                        audioSourceID: .microphone,
                        timeRange: timeRange,
                        text: transcriptText,
                        words: [
                            TranscriptWord(
                                wordID: TranscriptWordID("w000000"),
                                ordinal: 0,
                                text: transcriptText,
                                displayRange: LineTextRange(
                                    startUTF8Byte: 0,
                                    endUTF8Byte: transcriptText.utf8.count
                                ),
                                timeRange: timeRange,
                                confidence: 0.99,
                                wordKind: .lexical
                            ),
                        ]
                    ),
                ],
                audioEvents: []
            )
        )
    }
}

private let attachmentFeatureConfigurationStamp = CoachContextConfigurationStamp(
    authorityID: UUID(uuidString: "00000000-0000-0000-0000-000000000025")!,
    generation: 1
)
private let attachmentFeatureEvidenceAuthority = ChatCreationEvidenceAuthority(
    testingValue: UUID(uuidString: "00000000-0000-0000-0000-000000000125")!
)

private struct AttachmentBoundCoachContextFixture: ChatCoachContextCoordinating {
    let attachmentSource: any ChatSessionAttachmentSource
    let base: any CoachContextCoordinating

    func loadAttachmentCandidates(
        in library: LibraryScope
    ) async -> ChatAttachmentCatalogOutcome {
        await attachmentSource.loadCandidates(in: library)
    }

    func resolveAttachments(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentResolutionOutcome {
        await attachmentSource.resolve(attachments, in: library)
    }

    func quoteNewChatBoundToConfiguration(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> ConfigurationBoundChatCreationQuoteOutcome {
        switch await fixtureNewChatQuotePreservingProviderOutage(
            from: base,
            request: request
        ) {
        case let .available(quote):
            return .available(
                quote,
                authority: ChatCreationQuoteAuthority(
                    configuration: attachmentFeatureConfigurationStamp,
                    evidence: attachmentFeatureEvidenceAuthority
                )
            )
        case .unavailable(.providerUnavailable):
            return .providerUnavailable(
                previouslyQualifiedProviderUnavailableCapacityLowerBound(),
                authority: ChatCreationQuoteAuthority(
                    configuration: attachmentFeatureConfigurationStamp,
                    evidence: attachmentFeatureEvidenceAuthority
                )
            )
        case let .unavailable(reason):
            return .unavailable(reason)
        }
    }

    func acquireNewChatCreationLease(
        _ authority: ChatCreationQuoteAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        guard authority.configuration == attachmentFeatureConfigurationStamp else {
            return .stale
        }
        return .acquired(CoachContextAuthorityLease())
    }

    func quoteNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> ChatCreationQuoteOutcome {
        await base.quoteNewChat(request)
    }

    func quoteChat(
        _ request: CoachContextChatQuoteRequest
    ) async -> CoachContextQuoteOutcome {
        await base.quoteChat(request)
    }

    func preparePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextPendingPreparationOutcome {
        await base.preparePendingUserTurn(request)
    }

    func isPreparedContextCurrent(
        _ prepared: PreparedCoachLaunchContext
    ) async -> Bool {
        await base.isPreparedContextCurrent(prepared)
    }
}

private struct AttachmentEvidenceSourceForFeature:
    ChatSessionAttachmentEvidenceSource
{
    let evidence: ChatAttachmentEvidence

    func forEachEvidence(
        in library: LibraryScope,
        _ visit: @escaping @Sendable (ChatAttachmentEvidence) throws -> Void
    ) async -> ChatAttachmentEvidenceTraversalOutcome {
        do {
            try Task.checkCancellation()
            try visit(evidence)
            return .completed
        } catch {
            return .failed
        }
    }

    func forEachResolvedEvidence(
        _ attachments: ChatAttachments,
        in library: LibraryScope,
        _ visit: @escaping @Sendable (ResolvedChatAttachmentEvidence) throws -> Void
    ) async -> ChatAttachmentEvidenceTraversalOutcome {
        do {
            for attachment in attachments.values {
                try Task.checkCancellation()
                try visit(
                    ResolvedChatAttachmentEvidence(
                        attachment: attachment,
                        resolution: attachment.sessionID == evidence.sessionID &&
                            attachment.transcriptRevisionID ==
                            evidence.transcriptRevisionID
                            ? .available(evidence)
                            : .unavailable(.missing)
                    )
                )
            }
            return .completedWithAuthority(attachmentFeatureEvidenceAuthority)
        } catch {
            return .failed
        }
    }
}

private struct CapacityBoundCoachContextFixture: ChatCoachContextCoordinating {
    let attachmentSource: any ChatSessionAttachmentSource
    let base: DefaultCoachContextFeature

    func loadAttachmentCandidates(
        in library: LibraryScope
    ) async -> ChatAttachmentCatalogOutcome {
        await attachmentSource.loadCandidates(in: library)
    }

    func resolveAttachments(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentResolutionOutcome {
        await attachmentSource.resolve(attachments, in: library)
    }

    func quoteNewChatBoundToConfiguration(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> ConfigurationBoundChatCreationQuoteOutcome {
        await base.quoteNewChatBoundToConfiguration(request)
    }

    func acquireNewChatCreationLease(
        _ authority: ChatCreationQuoteAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        await base.acquireNewChatCreationLease(authority)
    }

    func quoteNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> ChatCreationQuoteOutcome {
        await base.quoteNewChat(request)
    }

    func quoteChat(
        _ request: CoachContextChatQuoteRequest
    ) async -> CoachContextQuoteOutcome {
        await base.quoteChat(request)
    }

    func preparePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextPendingPreparationOutcome {
        await base.preparePendingUserTurn(request)
    }

    func isPreparedContextCurrent(
        _ prepared: PreparedCoachLaunchContext
    ) async -> Bool {
        await base.isPreparedContextCurrent(prepared)
    }
}

private actor ChangingAttachmentConfigurationSource: CoachContextSnapshotPort {
    private var configurationGeneration: UInt64 = 1
    private var activeLeaseID: UUID?
    private var advancementWaiters: [CheckedContinuation<Void, Never>] = []

    func advanceConfiguration() async {
        if activeLeaseID != nil {
            await withCheckedContinuation { advancementWaiters.append($0) }
        }
        configurationGeneration += 1
    }

    func currentQualifiedConfiguration()
        async -> CoachQualifiedConfigurationOutcome
    {
        let policy = projectionPolicy()
        return .knownQualified(
            configuration: try! configuration(policy: policy),
            configurationGeneration: configurationGeneration
        )
    }

    func isCurrentConfiguration(_ candidate: UInt64) async -> Bool {
        candidate == configurationGeneration
    }

    func resolveNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        do {
            let policy = projectionPolicy()
            let attachments = try request.attachments.values.map { attachment in
                let handle = try PreparedCoachTranscriptHandle(
                    "00000000-0000-0000-0000-000000000025"
                )
                if policy.maximumInlineTranscriptTokens == 15,
                   configurationGeneration == 1
                {
                    return PreparedCoachAttachment.inline(
                        requestValue: .object([
                            "displayLabel": .string("Configuration rehearsal"),
                            "kind": .string("inline"),
                            "sessionAttachmentId": .string(
                                attachment.attachmentID.rawValue
                            ),
                            "transcript": .object(["lines": .array([])]),
                        ])
                    )
                }
                return PreparedCoachAttachment.onDemand(
                    requestValue: .object([
                        "displayLabel": .string("Configuration rehearsal"),
                        "kind": .string("onDemand"),
                        "sessionAttachmentId": .string(
                            attachment.attachmentID.rawValue
                        ),
                        "sessionTranscriptHandle": .string(handle.rawValue),
                    ]),
                    sessionTranscriptHandle: handle,
                    transcriptDisclosure: .object([
                        "sessionAttachmentId": .string(
                            attachment.attachmentID.rawValue
                        ),
                        "transcript": .object(["lines": .array([])]),
                    ])
                )
            }
            return .resolved(
                try CoachContextResolvedSnapshot(
                    input: CoachContextQuoteInput(
                        profile: .object(["statements": .array([])]),
                        memory: .object([
                            "generalNotes": .string(""),
                            "sessionSummaries": .array([]),
                        ]),
                        creation: request.creation,
                        attachments: attachments
                    ),
                    configuration: configuration(policy: policy),
                    authority: CoachContextSnapshotAuthority(
                        binding: .newChat(
                            library: request.library,
                            attachments: request.attachments,
                            creation: request.creation
                        ),
                        contextGeneration: 1,
                        configurationGeneration: configurationGeneration,
                        profile: CoachProfileProvenance(
                            revisionID: nil,
                            statementGeneration: 0
                        )
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
        .sourceUnavailable
    }

    func resolvePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextSnapshotOutcome {
        .sourceUnavailable
    }

    func isCurrent(_ authority: CoachContextSnapshotAuthority) async -> Bool {
        authority.contextGeneration == 1 &&
            authority.configurationGeneration == configurationGeneration
    }

    func acquireAuthorityLease(
        _ authority: CoachContextSourceLeaseAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        guard activeLeaseID == nil else { return .stale }
        let current: Bool
        switch authority {
        case let .snapshot(snapshot):
            current = await isCurrent(snapshot)
        case let .configuration(generation):
            current = generation == configurationGeneration
        }
        guard current else { return .stale }
        let leaseID = UUID()
        activeLeaseID = leaseID
        return .acquired(
            CoachContextAuthorityLease { [weak self] in
                await self?.releaseLease(leaseID)
            }
        )
    }

    private func releaseLease(_ leaseID: UUID) {
        guard activeLeaseID == leaseID else { return }
        activeLeaseID = nil
        let waiters = advancementWaiters
        advancementWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func projectionPolicy() -> CoachAttachmentProjectionPolicy {
        let tokens = configurationGeneration == 1 ? 10 : 20
        return try! CoachAttachmentProjectionPolicy(
            maximumInlineTranscriptTokens: 15,
            tokenEstimator: try! CoachTokenEstimator(
                identifier: "configuration-(configurationGeneration)-fixture-v1",
                mode: .exact,
                maximumUTF8BytesPerToken: 4,
                implementation: { _ in tokens }
            )
        )
    }

    private func configuration(
        policy: CoachAttachmentProjectionPolicy
    ) throws -> CoachContextConfiguration {
        try CoachContextConfiguration(
            descriptor: CoachProviderDescriptor(
                displayName: "Changing provider fixture",
                contextBudget: CoachContextBudget(
                    contextWindowTokens: 100_000,
                    responseReservedTokens: 32,
                    safetyMarginTokens: 8
                ),
                coachMemoryMaxTokens: 1
            ),
            policy: CoachProviderEstimationPolicy(
                providerIdentifier:
                    "configuration-(configurationGeneration)-fixture-v1",
                responseCollectorByteCeiling: 8_192,
                framing: CoachProviderFraming(),
                attachmentProjectionPolicy: policy
            )
        )
    }
}

private actor MismatchedAttachmentAuthorityFixture:
    ChatCoachContextCoordinating
{
    private let attachmentSource: any ChatSessionAttachmentSource
    private let base: any CoachContextCoordinating
    private var replaced = false
    private let originalStamp = CoachContextConfigurationStamp(
        authorityID: UUID(uuidString: "00000000-0000-0000-0000-000000000425")!,
        generation: 1
    )
    private let replacementStamp = CoachContextConfigurationStamp(
        authorityID: UUID(uuidString: "00000000-0000-0000-0000-000000000426")!,
        generation: 1
    )

    init(
        attachmentSource: any ChatSessionAttachmentSource,
        base: any CoachContextCoordinating
    ) {
        self.attachmentSource = attachmentSource
        self.base = base
    }

    func replaceConfigurationAuthorityWithoutChangingGeneration() {
        replaced = true
    }

    func loadAttachmentCandidates(
        in library: LibraryScope
    ) async -> ChatAttachmentCatalogOutcome {
        switch await attachmentSource.loadCandidates(in: library) {
        case let .loaded(candidates, _):
            return .loaded(candidates, configuration: originalStamp)
        case .configurationChanged:
            return .configurationChanged
        case .qualifiedConfigurationUnavailable:
            return .qualifiedConfigurationUnavailable
        case .readOnlyLibrary:
            return .readOnlyLibrary
        case .failed:
            return .failed
        }
    }

    func resolveAttachments(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentResolutionOutcome {
        switch await attachmentSource.resolve(attachments, in: library) {
        case let .resolved(resolved, _):
            return .resolved(
                resolved,
                configuration: replaced ? replacementStamp : originalStamp
            )
        case .configurationChanged:
            return .configurationChanged
        case .qualifiedConfigurationUnavailable:
            return .qualifiedConfigurationUnavailable
        case .readOnlyLibrary:
            return .readOnlyLibrary
        case .failed:
            return .failed
        }
    }

    func quoteNewChatBoundToConfiguration(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> ConfigurationBoundChatCreationQuoteOutcome {
        let stamp = replaced ? replacementStamp : originalStamp
        switch await fixtureNewChatQuotePreservingProviderOutage(
            from: base,
            request: request
        ) {
        case let .available(quote):
            return .available(
                quote,
                authority: ChatCreationQuoteAuthority(
                    configuration: stamp,
                    evidence: attachmentFeatureEvidenceAuthority
                )
            )
        case .unavailable(.providerUnavailable):
            return .providerUnavailable(
                previouslyQualifiedProviderUnavailableCapacityLowerBound(),
                authority: ChatCreationQuoteAuthority(
                    configuration: stamp,
                    evidence: attachmentFeatureEvidenceAuthority
                )
            )
        case let .unavailable(reason):
            return .unavailable(reason)
        }
    }

    func acquireNewChatCreationLease(
        _ authority: ChatCreationQuoteAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        guard authority.configuration == (replaced ? replacementStamp : originalStamp) else {
            return .stale
        }
        return .acquired(CoachContextAuthorityLease())
    }

    func quoteNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> ChatCreationQuoteOutcome {
        await base.quoteNewChat(request)
    }

    func quoteChat(
        _ request: CoachContextChatQuoteRequest
    ) async -> CoachContextQuoteOutcome {
        await base.quoteChat(request)
    }

    func preparePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextPendingPreparationOutcome {
        await base.preparePendingUserTurn(request)
    }

    func isPreparedContextCurrent(
        _ prepared: PreparedCoachLaunchContext
    ) async -> Bool {
        await base.isPreparedContextCurrent(prepared)
    }
}

private actor AttachmentSourceFixture: ChatSessionAttachmentSource {
    private var candidates: [ChatAttachmentCandidate]
    private var configurationUnavailableOnResolve: Bool
    private var unavailable: [String: ChatAttachmentUnavailableReason] = [:]
    private(set) var resolvedRequests: [ChatAttachments] = []

    init(
        candidates: [ChatAttachmentCandidate],
        configurationUnavailableOnResolve: Bool = false
    ) {
        self.candidates = candidates
        self.configurationUnavailableOnResolve = configurationUnavailableOnResolve
    }

    func loadCandidates(in library: LibraryScope) async -> ChatAttachmentCatalogOutcome {
        .loaded(
            candidates,
            configuration: attachmentFeatureConfigurationStamp
        )
    }

    func resolve(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentResolutionOutcome {
        resolvedRequests.append(attachments)
        guard !configurationUnavailableOnResolve else {
            return .qualifiedConfigurationUnavailable
        }
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
        }, configuration: attachmentFeatureConfigurationStamp)
    }

    func markUnavailable(
        _ candidate: ChatAttachmentCandidate,
        reason: ChatAttachmentUnavailableReason = .missing
    ) {
        unavailable[
            candidate.sessionID.rawValue + ":" + candidate.transcriptRevisionID.rawValue
        ] = reason
    }

    func replaceCandidates(_ replacement: [ChatAttachmentCandidate]) {
        candidates = replacement
    }

    func setConfigurationUnavailableOnResolve(_ unavailable: Bool) {
        configurationUnavailableOnResolve = unavailable
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
        return .loaded(
            candidates,
            configuration: attachmentFeatureConfigurationStamp
        )
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
    private(set) var createdSeed: NewChatSeed?
    private var existing: ChatAggregate?
    private(set) var mutationCount = 0
    private var createOutcomes: [ChatMutationOutcome]

    init(
        existing: ChatAggregate? = nil,
        createOutcomes: [ChatMutationOutcome] = []
    ) {
        self.existing = existing
        self.createOutcomes = createOutcomes
    }

    func loadCatalog(in library: LibraryScope) async -> ChatCatalogOutcome {
        .loaded(existing.map { [.available($0)] } ?? [])
    }
    func create(_ commit: NewChatCommit) async -> ChatMutationOutcome {
        let seed = commit.seed
        mutationCount += 1
        if !createOutcomes.isEmpty {
            return createOutcomes.removeFirst()
        }
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
    private var contextWindow: Int
    private var contextGeneration: UInt64 = 1
    private let transcriptBytes: Int
    private(set) var newChatResolutionCount = 0

    init(contextWindow: Int, transcriptBytes: Int = 32) {
        self.contextWindow = contextWindow
        self.transcriptBytes = transcriptBytes
    }

    func replaceContextWindow(_ replacement: Int) {
        contextWindow = replacement
        contextGeneration += 1
    }

    func resolveNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
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
                        contextGeneration: contextGeneration,
                        configurationGeneration: 1,
                        profile: CoachProfileProvenance(
                            revisionID: nil,
                            statementGeneration: 0
                        )
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
        authority.contextGeneration == contextGeneration &&
            authority.configurationGeneration == 1
    }

    func acquireAuthorityLease(
        _ authority: CoachContextSourceLeaseAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        await acquireImmutableAuthorityLease(authority)
    }
}

private struct KnownQualifiedProviderUnavailableCapacitySource:
    CoachContextSnapshotPort
{
    private let configurationGeneration: UInt64 = 1
    let configuration: CoachContextConfiguration

    init(contextWindow: Int) throws {
        configuration = try CoachContextConfiguration(
            descriptor: CoachProviderDescriptor(
                displayName: "Previously qualified unavailable fixture",
                contextBudget: CoachContextBudget(
                    contextWindowTokens: contextWindow,
                    responseReservedTokens: 32,
                    safetyMarginTokens: 8
                ),
                coachMemoryMaxTokens: 1
            ),
            policy: CoachProviderEstimationPolicy(
                providerIdentifier: "previously-qualified-unavailable-v1",
                responseCollectorByteCeiling: 8_192,
                framing: CoachProviderFraming(),
                attachmentProjectionPolicy: try CoachAttachmentProjectionPolicy(
                    maximumInlineTranscriptTokens: 8_192,
                    tokenEstimator: .utf8ByteUpperBound()
                )
            )
        )
    }

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

    func currentQualifiedConfiguration()
        async -> CoachQualifiedConfigurationOutcome
    {
        .knownQualified(
            configuration: configuration,
            configurationGeneration: configurationGeneration
        )
    }

    func isCurrentConfiguration(_ candidate: UInt64) async -> Bool {
        candidate == configurationGeneration
    }

    func acquireAuthorityLease(
        _ authority: CoachContextSourceLeaseAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        guard authority == .configuration(generation: configurationGeneration) else {
            return .stale
        }
        return .acquired(CoachContextAuthorityLease())
    }
}
