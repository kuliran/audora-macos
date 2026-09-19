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
        let feature = DefaultCoachContextFeature(
            testSourceWithNoAttachments: source,
            configurationGeneration: 1
        )
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

    func testEmptyOnlyCapacityFixtureRejectsSelectedEvidenceBeforeResolution()
        async throws
    {
        let source = RecordingCoachContextSnapshotPort(
            configuration: try fixtureConfiguration()
        )
        let feature = DefaultCoachContextFeature(
            testSourceWithNoAttachments: source,
            configurationGeneration: 1
        )
        let attachment = ChatSessionAttachment(
            attachmentID: try ChatSessionAttachmentID("attachment-000001"),
            sessionID: try SessionID("ses-20260830T110000000Z-5JKM"),
            transcriptRevisionID: try TranscriptRevisionID(
                "trv-20260830T113000000Z-6NPQ"
            )
        )
        let request = try CoachContextNewChatQuoteRequest(
            library: Self.scope,
            attachments: ChatAttachments(validating: [attachment]),
            creationKind: .newChat
        )

        let outcome = await feature.quoteNewChat(request)

        XCTAssertEqual(outcome, .unavailable(.invalidContext))
        let requests = await source.requests
        XCTAssertEqual(requests, [])
    }

    func testEmptyOnlyCapacityFixtureRejectsConfigurationStampDrift()
        async throws
    {
        let source = RecordingCoachContextSnapshotPort(
            configuration: try fixtureConfiguration()
        )
        let feature = DefaultCoachContextFeature(
            testSourceWithNoAttachments: source,
            configurationGeneration: 2
        )
        let request = try CoachContextNewChatQuoteRequest(
            library: Self.scope,
            attachments: .empty,
            creationKind: .newChat
        )

        let outcome = await feature.quoteNewChat(request)

        XCTAssertEqual(outcome, .unavailable(.staleState))
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

    func testResolvedSnapshotRejectsCanonicalProfileThatDoesNotMatchTypedProjection()
        throws
    {
        let aggregate = try fixtureAggregate()
        let profileProjection = CoachProfileContextProjection(
            snapshot: ProfileSnapshot(nullAtStatementGeneration: 0),
            attachments: .empty
        )
        let mismatchedInput = try CoachContextQuoteInput(
            profile: .object([
                "statements": .array([.string("Forged Profile value")]),
            ]),
            memory: .object([:]),
            history: [],
            currentDraft: aggregate.chat.draft.text
        )

        XCTAssertThrowsError(
            try CoachContextResolvedSnapshot(
                input: mismatchedInput,
                configuration: fixtureConfiguration(),
                authority: CoachContextSnapshotAuthority(
                    binding: .chat(
                        library: Self.scope,
                        chatID: aggregate.chat.id,
                        draftID: aggregate.chat.draft.draftID,
                        draftVersion: aggregate.chat.draft.version
                    ),
                    contextGeneration: 1,
                    configurationGeneration: 1,
                    profile: profileProjection.provenance
                ),
                profileProjection: profileProjection
            )
        ) { error in
            XCTAssertEqual(
                error as? CoachContextResolvedSnapshotError,
                .profileProjectionMismatch
            )
        }
    }

    func testResolvedSnapshotRejectsAuthorityProvenanceThatDoesNotMatchProjection()
        throws
    {
        let aggregate = try fixtureAggregate()
        let profileProjection = CoachProfileContextProjection(
            snapshot: ProfileSnapshot(nullAtStatementGeneration: 0),
            attachments: .empty
        )
        let input = try CoachContextQuoteInput(
            profile: profileProjection.value,
            memory: .object([:]),
            history: [],
            currentDraft: aggregate.chat.draft.text
        )

        XCTAssertThrowsError(
            try CoachContextResolvedSnapshot(
                input: input,
                configuration: fixtureConfiguration(),
                authority: CoachContextSnapshotAuthority(
                    binding: .chat(
                        library: Self.scope,
                        chatID: aggregate.chat.id,
                        draftID: aggregate.chat.draft.draftID,
                        draftVersion: aggregate.chat.draft.version
                    ),
                    contextGeneration: 1,
                    configurationGeneration: 1,
                    profile: CoachProfileProvenance(
                        revisionID: nil,
                        statementGeneration: 1
                    )
                ),
                profileProjection: profileProjection
            )
        ) { error in
            XCTAssertEqual(
                error as? CoachContextResolvedSnapshotError,
                .profileProjectionMismatch
            )
        }
    }

    func testDeniedProfileEvidenceBlocksWholePreparationBeforeProviderRequestPlanning()
        async throws
    {
        let aggregate = try fixtureAggregate()
        let profile = try profileWithEvidence()
        let estimation = CoachEstimationObservation()
        let policySource = RecordingCoachEvidencePolicySource(mode: .denied)
        let source = PolicyBoundCoachContextSnapshotPort(
            configuration: try fixtureConfiguration(
                tokenEstimator: try CoachTokenEstimator(
                    identifier: "profile-policy-gate-fixture-v1",
                    mode: .exact,
                    maximumUTF8BytesPerToken: 1,
                    implementation: { bytes in
                        estimation.record(bytes)
                        return bytes.count
                    }
                )
            ),
            profile: profile
        )
        let feature = DefaultCoachContextFeature(
            source: source,
            evidenceUsePolicySource: policySource
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

        let outcome = await feature.preparePendingUserTurn(request)

        XCTAssertEqual(outcome, .unavailable(.externalProcessingDisallowed))
        XCTAssertEqual(estimation.values, [])
        let requestedSources = await policySource.requestedSources
        XCTAssertEqual(
            requestedSources,
            CoachProfileEvidenceObligations(profile: profile).sources
        )
    }

    func testDeniedProfileEvidenceBlocksNewChatBeforeProviderRequestPlanning()
        async throws
    {
        let profile = try profileWithEvidence()
        let policySource = RecordingCoachEvidencePolicySource(mode: .denied)
        let authorityID = UUID()
        let feature = DefaultCoachContextFeature(
            testSourceWithNoAttachments: PolicyBoundCoachContextSnapshotPort(
                configuration: try fixtureConfiguration(),
                profile: profile
            ),
            configurationGeneration: 1,
            configurationAuthorityID: authorityID,
            evidenceUsePolicySource: policySource
        )
        let request = try CoachContextNewChatQuoteRequest(
            library: Self.scope,
            attachments: .empty,
            creationKind: .newChat
        )

        let outcome = await feature.quoteNewChat(request)

        XCTAssertEqual(outcome, .unavailable(.externalProcessingDisallowed))
        let requestedSources = await policySource.requestedSources
        XCTAssertEqual(
            requestedSources,
            CoachProfileEvidenceObligations(profile: profile).sources
        )
    }

    func testUnresolvableProfileEvidenceFailsClosedWithTypedReason() async throws {
        let aggregate = try fixtureAggregate()
        let profile = try profileWithEvidence()
        let policySource = RecordingCoachEvidencePolicySource(mode: .unavailable)
        let feature = DefaultCoachContextFeature(
            source: PolicyBoundCoachContextSnapshotPort(
                configuration: try fixtureConfiguration(),
                profile: profile
            ),
            evidenceUsePolicySource: policySource
        )
        let request = CoachContextChatQuoteRequest(
            library: Self.scope,
            chatID: aggregate.chat.id,
            draft: aggregate.chat.draft
        )

        let outcome = await feature.quoteChat(request)

        XCTAssertEqual(
            outcome,
            .unavailable(.externalProcessingPolicyUnavailable)
        )
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
        contextWindow: Int = 10_000,
        tokenEstimator: CoachTokenEstimator = .utf8ByteUpperBound()
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
                framing: .testZero,
                attachmentProjectionPolicy: try CoachAttachmentProjectionPolicy(
                    maximumInlineTranscriptTokens: 8_192,
                    tokenEstimator: tokenEstimator
                )
            )
        )
    }

    private func profileWithEvidence() throws -> ProfileSnapshot {
        let evidence = try EvidenceReference(
            sessionID: SessionID("ses-20260830T110000000Z-5KMN"),
            transcriptRevisionID: TranscriptRevisionID(
                "trv-20260830T111000000Z-6PQR"
            ),
            target: .wordRange(
                startWordID: TranscriptWordID("w000000"),
                endWordID: TranscriptWordID("w000000")
            ),
            display: EvidenceReferenceDisplay(
                sessionLabel: "Policy-bound Session",
                trustedText: "hello",
                startMilliseconds: 0,
                endMilliseconds: 100
            )
        )
        let statement = try ProfileStatement(
            statementID: ProfileStatementID("stm-20260830T115900000Z-7STV"),
            statementKind: .speakingObservation,
            wording: "A complete policy-bound statement.",
            supportingSessionCount: 1,
            evidence: [evidence]
        )
        return ProfileSnapshot(
            revision: try ProfileRevision(
                revisionID: ProfileRevisionID("prf-20260830T115900000Z-8WXY"),
                parentRevisionID: nil,
                generation: 1,
                statementGeneration: 1,
                createdAt: UTCInstant("2026-08-30T11:59:00.000Z"),
                statements: [statement]
            )
        )
    }
}

private final class CoachEstimationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Data] = []

    var values: [Data] { lock.withLock { recorded } }

    func record(_ value: Data) {
        lock.withLock { recorded.append(value) }
    }
}

private actor RecordingCoachEvidencePolicySource: CoachEvidenceUsePolicySource {
    enum Mode { case denied, unavailable }

    let mode: Mode
    private(set) var requestedSources: [CoachEvidencePolicySourceIdentity] = []

    init(mode: Mode) { self.mode = mode }

    func resolveUsePolicies(
        for sources: [CoachEvidencePolicySourceIdentity],
        in library: LibraryScope
    ) async -> [CoachEvidenceUsePolicyResolution] {
        requestedSources = sources
        return sources.map { source in
            switch mode {
            case .denied:
                .resolved(source: source, policy: Self.deniedPolicy)
            case .unavailable:
                .unavailable(source: source)
            }
        }
    }

    private static let deniedPolicy = try! EngineUsePolicy(
        policyID: "profile-policy-denied-v1",
        coveredArtifacts: [.transcriptRevision],
        privateLocalUseAllowed: true,
        privateExportAllowed: true,
        externalProcessingAllowed: false,
        publicDistributionAllowed: false,
        commercialUseAllowed: false,
        licenseReference: "test-license",
        licenseSHA256: String(repeating: "b", count: 64)
    )
}

private actor PolicyBoundCoachContextSnapshotPort:
    ProfileReconsiderationUnavailableCoachContextSnapshotPort
{
    let configuration: CoachContextConfiguration
    let profile: ProfileSnapshot

    init(configuration: CoachContextConfiguration, profile: ProfileSnapshot) {
        self.configuration = configuration
        self.profile = profile
    }

    func resolveNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        snapshot(
            input: try? CoachContextQuoteInput(
                profile: CoachContextProfileProjector(attachments: .empty)
                    .profile(profile),
                memory: .object([:]),
                creation: request.creation
            ),
            binding: .newChat(
                library: request.library,
                attachments: request.attachments,
                creation: request.creation
            )
        )
    }

    func resolveChat(
        _ request: CoachContextChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        snapshot(
            input: try? CoachContextQuoteInput(
                profile: CoachContextProfileProjector(attachments: .empty)
                    .profile(profile),
                memory: .object([:]),
                history: [],
                currentDraft: request.draft.text
            ),
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
        snapshot(
            input: try? CoachContextQuoteInput(
                profile: CoachContextProfileProjector(attachments: .empty)
                    .profile(profile),
                memory: .object([:]),
                history: [],
                currentDraft: request.draft.text
            ),
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
        true
    }

    func acquireAuthorityLease(
        _ authority: CoachContextSourceLeaseAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        await acquireTestImmutableAuthorityLease(authority)
    }

    private func snapshot(
        input: CoachContextQuoteInput?,
        binding: CoachContextSnapshotBinding
    ) -> CoachContextSnapshotOutcome {
        guard let input else { return .sourceUnavailable }
        return .resolved(
            try! CoachContextResolvedSnapshot(
                input: input,
                configuration: configuration,
                authority: CoachContextSnapshotAuthority(
                    binding: binding,
                    contextGeneration: 1,
                    configurationGeneration: 1,
                    profile: profile.provenance
                ),
                profileProjection: CoachProfileContextProjection(
                    snapshot: profile,
                    attachments: .empty
                )
            )
        )
    }
}

private struct UnconfiguredProviderUnavailableSnapshotPort:
    ProfileReconsiderationUnavailableCoachContextSnapshotPort
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

private actor RecordingCoachContextSnapshotPort:
    ProfileReconsiderationUnavailableCoachContextSnapshotPort
{
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
            let profileProjection = Self.profileProjection
            let input = try CoachContextQuoteInput(
                profile: profileProjection.value,
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
                        configurationGeneration: 1,
                        profile: profileProjection.provenance
                    ),
                    profileProjection: profileProjection
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
        await acquireTestImmutableAuthorityLease(authority)
    }

    private func snapshot(
        draft: ChatDraft,
        binding: CoachContextSnapshotBinding
    ) -> CoachContextSnapshotOutcome {
        do {
            let profileProjection = Self.profileProjection
            let input = try CoachContextQuoteInput(
                profile: profileProjection.value,
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
                        configurationGeneration: 1,
                        profile: profileProjection.provenance
                    ),
                    profileProjection: profileProjection
                )
            )
        } catch {
            return .sourceUnavailable
        }
    }

    private static let profileProjection = CoachProfileContextProjection(
        snapshot: ProfileSnapshot(nullAtStatementGeneration: 0),
        attachments: .empty
    )
    private static let memory = CanonicalJSONValue.object([
        "generalNotes": .string("Remember"),
        "sessionSummaries": .array([]),
    ])
}

private actor SuspendingAuthoritySnapshotPort:
    ProfileReconsiderationUnavailableCoachContextSnapshotPort
{
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
            let profileProjection = CoachProfileContextProjection(
                snapshot: ProfileSnapshot(nullAtStatementGeneration: 0),
                attachments: .empty
            )
            return .resolved(
                try CoachContextResolvedSnapshot(
                    input: CoachContextQuoteInput(
                        profile: profileProjection.value,
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
                        configurationGeneration: configurationGeneration,
                        profile: profileProjection.provenance
                    ),
                    profileProjection: profileProjection
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
        await acquireTestImmutableAuthorityLease(authority)
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

private actor WrongBindingSnapshotPort:
    ProfileReconsiderationUnavailableCoachContextSnapshotPort
{
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
            let profileProjection = CoachProfileContextProjection(
                snapshot: ProfileSnapshot(nullAtStatementGeneration: 0),
                attachments: .empty
            )
            return .resolved(
                try CoachContextResolvedSnapshot(
                    input: CoachContextQuoteInput(
                        profile: profileProjection.value,
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
                        configurationGeneration: 99,
                        profile: profileProjection.provenance
                    ),
                    profileProjection: profileProjection
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
        await acquireTestImmutableAuthorityLease(authority)
    }
}
