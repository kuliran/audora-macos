@testable @_spi(CoachContextQualification) @_spi(ChatCreationAuthorityTesting) @_spi(InvocationTesting) import AudoraApplication
import AudoraDomain
import Foundation
import XCTest

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class ChatFeatureTests: XCTestCase {
    func testAdmissionCooldownBlocksSendUntilItsExactDeadlineRefreshes() async throws {
        let aggregate = try Self.aggregate(draftText: "Coach this exact Draft.")
        let store = RecordingChatStore(catalog: [.available(aggregate)])
        let reopensAt = try UTCInstant("2026-08-30T12:01:00.000Z")
        let gateway = ProjectedAdmissionInvocationGateway(
            availability: .cooldown(reopensAt: reopensAt)
        )
        let scheduler = ControlledAdmissionRefreshScheduler()
        let feature = makeFeature(
            store: store,
            admissionRefreshScheduler: scheduler,
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))

        await feature.send(.sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft))

        let blockedRequests = await gateway.requests
        let blockedLocks = await store.pendingLocks
        let cooldownState = await feature.currentState
        XCTAssertEqual(blockedRequests, [])
        XCTAssertEqual(blockedLocks, [])
        XCTAssertEqual(
            cooldownState.admissionAvailability,
            .cooldown(reopensAt: reopensAt)
        )
        await scheduler.waitUntilScheduled()
        let deadlines = await scheduler.deadlines
        XCTAssertEqual(deadlines, [reopensAt])

        await gateway.setAvailability(.available)
        await scheduler.resume()
        while await feature.currentState.admissionAvailability != .available {
            await Task.yield()
        }
        await feature.send(.sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft))

        let reopenedRequests = await gateway.requests
        let reopenedLocks = await store.pendingLocks
        XCTAssertEqual(reopenedRequests.count, 1)
        XCTAssertEqual(
            reopenedLocks,
            [],
            "the Invocation gateway, not ChatStore, owns Pending installation"
        )
    }

    func testAdmissionCooldownRetainsFailedPendingTurnWithoutLaunchingRetry() async throws {
        let aggregate = try Self.aggregate(draftText: "Retry this exact Draft.")
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120000000Z-5KMN"),
            draftID: aggregate.chat.draft.draftID,
            draftVersion: aggregate.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120000000Z-6PQR"
            ),
            failure: .coachContextCannotFit
        )
        let locked = try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            pendingUserTurn: pending
        )
        let store = RecordingChatStore(catalog: [.available(locked)])
        let gateway = ProjectedAdmissionInvocationGateway(
            availability: .cooldown(
                reopensAt: try UTCInstant("2026-08-30T12:01:00.000Z")
            )
        )
        let feature = makeFeature(
            store: store,
            admissionRefreshScheduler: ControlledAdmissionRefreshScheduler(),
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, locked.chat.id))

        await feature.send(.retryPendingUserTurn(Self.context, pending.id))

        let requests = await gateway.requests
        let state = await feature.currentState
        XCTAssertEqual(requests, [])
        XCTAssertEqual(Self.openAggregate(in: state)?.pendingUserTurn, pending)
        XCTAssertEqual(state.composer, .locked(locked.chat.draft, pending))
    }

    func testRetryProjectsTheExactPendingAsFailureFreeWhileInvocationIsSuspended() async throws {
        let aggregate = try Self.aggregate(draftText: "Retry this exact Draft.")
        let failedPending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120000000Z-5KMN"),
            draftID: aggregate.chat.draft.draftID,
            draftVersion: aggregate.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120000000Z-6PQR"
            ),
            failure: .coachProviderError
        )
        let failedAggregate = try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            pendingUserTurn: failedPending
        )
        let processingPending = failedPending.replacingFailure(nil)
        let processingAggregate = try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            pendingUserTurn: processingPending
        )
        let gateway = SuspendedRetryInvocationGateway()
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(failedAggregate)]),
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))

        let failedState = await feature.currentState
        XCTAssertEqual(
            Self.openAggregate(in: failedState)?.pendingUserTurn?.failure,
            .coachProviderError
        )
        XCTAssertTrue(failedState.isCoachResponseRetryableFailure(failedPending))

        async let retry: Void = feature.send(
            .retryPendingUserTurn(Self.context, failedPending.id)
        )
        await gateway.waitUntilRetryIsSuspended()

        let state = await feature.currentState
        XCTAssertEqual(state.selection, .open(processingAggregate))
        XCTAssertEqual(
            state.composer,
            .locked(processingAggregate.chat.draft, processingPending)
        )
        XCTAssertEqual(state.activity, .invokingCoach(aggregate.chat.id))
        XCTAssertNil(state.notice)
        XCTAssertNil(state.operationallyInterruptedInvocation)
        XCTAssertFalse(state.isCoachResponseRetryableFailure(processingPending))

        await gateway.resume(
            with: .interrupted(failedAggregate, .providerFailed)
        )
        await retry

        let terminalState = await feature.currentState
        XCTAssertEqual(terminalState.selection, .open(failedAggregate))
        XCTAssertEqual(
            terminalState.composer,
            .locked(failedAggregate.chat.draft, failedPending)
        )
        XCTAssertNil(terminalState.activity)
    }

    func testRetryInterruptedWithoutSnapshotRestoresExactFailedPendingAndActions()
        async throws
    {
        let aggregate = try Self.aggregate(draftText: "Keep this failed Draft.")
        let failedPending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120000000Z-5KMN"),
            draftID: aggregate.chat.draft.draftID,
            draftVersion: aggregate.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120000000Z-6PQR"
            ),
            failure: .coachProviderError
        )
        let failedAggregate = try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            pendingUserTurn: failedPending
        )
        let gateway = SuspendedRetryInvocationGateway()
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(failedAggregate)]),
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))

        async let retry: Void = feature.send(
            .retryPendingUserTurn(Self.context, failedPending.id)
        )
        await gateway.waitUntilRetryIsSuspended()
        await gateway.resume(with: .interrupted(nil, .providerFailed))
        await retry

        let state = await feature.currentState
        XCTAssertEqual(state.selection, .open(failedAggregate))
        XCTAssertEqual(
            state.composer,
            .locked(failedAggregate.chat.draft, failedPending)
        )
        XCTAssertTrue(state.isCoachResponseRetryableFailure(failedPending))
        XCTAssertNil(state.operationallyInterruptedInvocation)
        XCTAssertNil(
            state.notice,
            "the restored typed failure card is the terminal copy"
        )
        XCTAssertNil(state.activity)
    }

    func testRejectedRetryRestoresTheAuthoritativeFailedPending() async throws {
        let aggregate = try Self.aggregate(draftText: "Preserve this failed Retry.")
        let failedPending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120000000Z-5KMN"),
            draftID: aggregate.chat.draft.draftID,
            draftVersion: aggregate.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120000000Z-6PQR"
            ),
            failure: .coachProviderError
        )
        let failedAggregate = try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            pendingUserTurn: failedPending
        )
        let gateway = SuspendedRetryInvocationGateway()
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(failedAggregate)]),
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))

        async let retry: Void = feature.send(
            .retryPendingUserTurn(Self.context, failedPending.id)
        )
        await gateway.waitUntilRetryIsSuspended()
        await gateway.resume(
            with: .rejected(nil, .activeInvocation)
        )
        await retry

        let state = await feature.currentState
        XCTAssertEqual(state.selection, .open(failedAggregate))
        XCTAssertEqual(
            state.composer,
            .locked(failedAggregate.chat.draft, failedPending)
        )
        XCTAssertEqual(state.notice, .coachBusy)
        XCTAssertNil(state.activity)
    }

    func testUnavailableRejectedRetryKeepsFailedPendingLockedAndUsesRetryCopy()
        async throws
    {
        let reasons: [InvocationRejectionReason] = [
            .admissionUnavailable,
            .contextChanged,
            .persistenceUnavailable,
            .identityCollisionExhausted(lastCollision: .freshDraftID),
        ]
        for reason in reasons {
            let aggregate = try Self.aggregate(
                draftText: "Keep this failed Retry locked."
            )
            let failedPending = PendingUserTurn(
                id: try PendingUserTurnID("ptu-20260830T120000000Z-5KMN"),
                draftID: aggregate.chat.draft.draftID,
                draftVersion: aggregate.chat.draft.version,
                responsePositionID: try ChatResponsePositionID(
                    "rsp-20260830T120000000Z-6PQR"
                ),
                failure: .coachProviderError
            )
            let failedAggregate = try ChatAggregate(
                chat: aggregate.chat,
                memory: aggregate.memory,
                pendingUserTurn: failedPending
            )
            let gateway = SuspendedRetryInvocationGateway()
            let feature = makeFeature(
                store: RecordingChatStore(catalog: [.available(failedAggregate)]),
                invocations: gateway
            )
            await feature.send(.start(Self.context))
            await feature.send(.open(Self.context, aggregate.chat.id))

            async let retry: Void = feature.send(
                .retryPendingUserTurn(Self.context, failedPending.id)
            )
            await gateway.waitUntilRetryIsSuspended()
            let rejectedCurrent = reason == .contextChanged
                ? failedAggregate
                : nil
            await gateway.resume(with: .rejected(rejectedCurrent, reason))
            await retry

            let state = await feature.currentState
            XCTAssertEqual(
                state.selection,
                .open(failedAggregate),
                String(describing: reason)
            )
            XCTAssertEqual(
                state.composer,
                .locked(failedAggregate.chat.draft, failedPending),
                String(describing: reason)
            )
            XCTAssertEqual(
                state.notice,
                .coachRetryUnavailable,
                String(describing: reason)
            )
            XCTAssertNil(state.activity, String(describing: reason))
        }
    }

    func testDelayedConfirmFromPreviousLibraryContextIsRejectedAfterSwitch() async {
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

        await feature.sendCurrentNewChatConfirmation(firstContext)

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

    func testConfirmedZeroSelectionCommitsCanonicalEmptyChatBeforeSelectingIt() async throws {
        let store = RecordingChatStore()
        let feature = makeFeature(store: store)
        await feature.send(.start(Self.context))

        await feature.send(.beginNewChat(Self.context))
        await feature.sendCurrentNewChatConfirmation(Self.context)

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

        await feature.send(.beginNewChat(Self.context))
        await feature.sendCurrentNewChatConfirmation(Self.context)

        let seedCount = await store.createSeeds.count
        let collisionAuthorityRetentions =
            await store.createCollisionAuthorityRetentions
        let state = await feature.currentState
        XCTAssertEqual(seedCount, 3)
        XCTAssertEqual(collisionAuthorityRetentions, [true, true, false])
        XCTAssertEqual(state.notice, .createCollisionLimitReached)
    }

    func testProfileConflictRequiresFreshConfirmationBeforeRetryingCurrentGeneration()
        async throws
    {
        let store = RecordingChatStore(
            createOutcomes: [.profileStatementGenerationChanged(9)]
        )
        let feature = makeFeature(
            store: store,
            profileReader: SequencedProfileReader(generations: [7, 9])
        )
        await feature.send(.start(Self.context))

        await feature.send(.beginNewChat(Self.context))
        await feature.sendCurrentNewChatConfirmation(Self.context)

        let generationsBeforeFreshConfirmation = await store.createSeeds.map(
            \.aggregate.chat.profileStatementGenerationAtCreation
        )
        XCTAssertEqual(generationsBeforeFreshConfirmation, [7])
        let requotedState = await feature.currentState
        XCTAssertNil(Self.openAggregate(in: requotedState))
        guard case let .ready(requotedPicker) = requotedState.newChatPicker else {
            return XCTFail("the picker must remain open for a fresh confirmation")
        }
        XCTAssertTrue(requotedPicker.permitsConfirmation)

        await feature.sendCurrentNewChatConfirmation(Self.context)

        let generationsAfterFreshConfirmation = await store.createSeeds.map(
            \.aggregate.chat.profileStatementGenerationAtCreation
        )
        XCTAssertEqual(generationsAfterFreshConfirmation, [7, 9])
        let committedState = await feature.currentState
        XCTAssertEqual(
            Self.openAggregate(in: committedState)?.chat.profileStatementGenerationAtCreation,
            9
        )
    }

    func testProfileGrowthDuringCreateRequotesPickerAndRequiresFreshConfirmationBeforeRetry()
        async throws
    {
        let source = GrowingNewChatProfileSnapshotPort()
        let store = ProfileChangingCreateStore(source: source)
        let feature = makeFeature(
            store: store,
            coachContext: ChatFeatureBoundCoachContextFixture(
                attachmentSource: EmptyChatAttachmentSource(),
                base: DefaultCoachContextFeature(
                    source: source,
                    configurationAuthorityID:
                        chatFeatureConfigurationStamp.authorityID
                )
            )
        )
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))

        guard case let .ready(initialPicker) = await feature.currentState.newChatPicker,
              case let .available(initialQuote) = initialPicker.feasibility
        else {
            return XCTFail("the initial live Profile quote must permit confirmation")
        }
        XCTAssertTrue(initialQuote.context.fits)

        await feature.sendCurrentNewChatConfirmation(Self.context)

        let seeds = await store.createSeeds
        XCTAssertEqual(seeds.count, 1)
        let state = await feature.currentState
        XCTAssertNil(Self.openAggregate(in: state))
        guard case let .ready(refreshedPicker) = state.newChatPicker,
              case let .available(refreshedQuote) = refreshedPicker.feasibility
        else {
            return XCTFail("the changed Profile must be projected into the creation picker")
        }
        XCTAssertGreaterThan(
            refreshedQuote.context.completeInputTokens,
            initialQuote.context.completeInputTokens
        )
        XCTAssertFalse(refreshedQuote.context.fits)
        XCTAssertEqual(refreshedPicker.issue, .contextCannotFit)
        XCTAssertFalse(refreshedPicker.permitsConfirmation)

        await feature.sendCurrentNewChatConfirmation(Self.context)

        let createCountAfterBlockedConfirmation = await store.createSeeds.count
        XCTAssertEqual(createCountAfterBlockedConfirmation, 1)
    }

    func testContextDriftAfterDisplayedQuoteRequiresFreshConfirmation() async throws {
        let source = GrowingNewChatProfileSnapshotPort()
        let store = RecordingChatStore()
        let feature = makeFeature(
            store: store,
            coachContext: ChatFeatureBoundCoachContextFixture(
                attachmentSource: EmptyChatAttachmentSource(),
                base: DefaultCoachContextFeature(
                    source: source,
                    configurationAuthorityID:
                        chatFeatureConfigurationStamp.authorityID
                )
            )
        )
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))

        guard case let .ready(initialPicker) = await feature.currentState.newChatPicker,
              case let .available(initialQuote) = initialPicker.feasibility
        else {
            return XCTFail("the initial live-context quote must permit confirmation")
        }
        XCTAssertTrue(initialPicker.permitsConfirmation)
        await source.installExpandedProfile()

        await feature.sendCurrentNewChatConfirmation(Self.context)

        let seedsBeforeFreshConfirmation = await store.createSeeds
        XCTAssertEqual(seedsBeforeFreshConfirmation.count, 0)
        guard case let .ready(refreshedPicker) = await feature.currentState.newChatPicker,
              case let .available(refreshedQuote) = refreshedPicker.feasibility
        else {
            return XCTFail("context drift must project the replacement quote")
        }
        XCTAssertGreaterThan(
            refreshedQuote.context.completeInputTokens,
            initialQuote.context.completeInputTokens
        )
        XCTAssertTrue(refreshedPicker.permitsConfirmation)

        await feature.sendCurrentNewChatConfirmation(Self.context)

        let seedsAfterFreshConfirmation = await store.createSeeds
        XCTAssertEqual(seedsAfterFreshConfirmation.count, 1)
    }

    func testRepeatedProfileConflictsRequireOneFreshConfirmationEach() async throws {
        let store = RecordingChatStore(
            createOutcomes: [
                .profileStatementGenerationChanged(8),
                .profileStatementGenerationChanged(9),
            ]
        )
        let feature = makeFeature(
            store: store,
            profileReader: SequencedProfileReader(generations: [7, 8, 9])
        )
        await feature.send(.start(Self.context))

        await feature.send(.beginNewChat(Self.context))
        await feature.sendCurrentNewChatConfirmation(Self.context)

        let firstConfirmationSeeds = await store.createSeeds
        XCTAssertEqual(
            firstConfirmationSeeds.map(
                \.aggregate.chat.profileStatementGenerationAtCreation
            ),
            [7]
        )

        await feature.sendCurrentNewChatConfirmation(Self.context)

        let secondConfirmationSeeds = await store.createSeeds
        XCTAssertEqual(
            secondConfirmationSeeds.map(
                \.aggregate.chat.profileStatementGenerationAtCreation
            ),
            [7, 8]
        )

        await feature.sendCurrentNewChatConfirmation(Self.context)

        let finalSeeds = await store.createSeeds
        XCTAssertEqual(
            finalSeeds.map(\.aggregate.chat.profileStatementGenerationAtCreation),
            [7, 8, 9]
        )
        let committedState = await feature.currentState
        XCTAssertEqual(
            Self.openAggregate(in: committedState)?.chat.profileStatementGenerationAtCreation,
            9
        )
    }

    func testQueuedConfirmationCannotAdoptReplacementQuoteToken() async throws {
        let aggregate = try Self.aggregate()
        let store = RecordingChatStore(
            catalog: [.available(aggregate)],
            createOutcomes: [.profileStatementGenerationChanged(9)],
            suspendNextDraftSave: true
        )
        let scheduler = ControlledChatAutosaveScheduler()
        let feature = makeFeature(
            store: store,
            profileReader: SequencedProfileReader(generations: [7, 9]),
            autosaveScheduler: scheduler
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        await feature.send(
            .editDraft(
                Self.context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: "Keep this draft durable before creating."
            )
        )
        await scheduler.waitUntilScheduled()
        await feature.send(.beginNewChat(Self.context))
        guard case let .ready(initialPicker) = await feature.currentState.newChatPicker,
              let tokenA = initialPicker.confirmationToken
        else {
            return XCTFail("the initial quote must publish confirmation A")
        }

        async let firstConfirmation: Void = feature.send(
            .confirmNewChat(Self.context, tokenA)
        )
        await store.waitUntilDraftSaveStarts()
        await feature.send(.confirmNewChat(Self.context, tokenA))
        await store.resumeDraftSave()
        await firstConfirmation

        let seedsAfterStaleConfirmation = await store.createSeeds
        XCTAssertEqual(seedsAfterStaleConfirmation.count, 1)
        let replacementState = await feature.currentState
        guard case let .ready(replacementPicker) = replacementState.newChatPicker,
              let tokenB = replacementPicker.confirmationToken
        else {
            return XCTFail("the profile conflict must publish replacement confirmation B")
        }
        XCTAssertNotEqual(tokenB, tokenA)

        await feature.send(.confirmNewChat(Self.context, tokenB))

        let seedsAfterCurrentConfirmation = await store.createSeeds
        XCTAssertEqual(seedsAfterCurrentConfirmation.count, 2)
        let committedState = await feature.currentState
        XCTAssertNotNil(Self.openAggregate(in: committedState))
    }

    func testStaleProposalTokenCannotPublishOrCreateButCurrentTokenSucceeds()
        async throws
    {
        let candidate = try Self.attachmentCandidate()
        let coordinator = ScriptedNewChatCoachContext(candidates: [candidate])
        let store = RecordingChatStore()
        let feature = makeFeature(store: store, coachContext: coordinator)
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))
        guard case let .ready(initialPicker) = await feature.currentState.newChatPicker,
              let row = initialPicker.allRows.first,
              let staleToken = initialPicker.confirmationToken
        else {
            return XCTFail("the initial proposal must be confirmable")
        }

        await feature.send(.toggleNewChatAttachment(Self.context, row.id))

        let selectedState = await feature.currentState
        guard case let .ready(selectedPicker) = selectedState.newChatPicker,
              let currentToken = selectedPicker.confirmationToken
        else {
            return XCTFail("the selected proposal must publish a fresh token")
        }
        XCTAssertNotEqual(currentToken, staleToken)

        await feature.send(.confirmNewChat(Self.context, staleToken))

        let stateAfterStaleConfirmation = await feature.currentState
        let seedsAfterStaleConfirmation = await store.createSeeds
        let resolutionCountAfterStaleConfirmation = await coordinator.resolutionCount
        XCTAssertEqual(stateAfterStaleConfirmation, selectedState)
        XCTAssertTrue(seedsAfterStaleConfirmation.isEmpty)
        XCTAssertEqual(resolutionCountAfterStaleConfirmation, 0)

        await feature.send(.confirmNewChat(Self.context, currentToken))

        let seeds = await store.createSeeds
        XCTAssertEqual(seeds.count, 1)
        XCTAssertEqual(seeds.first?.aggregate.chat.attachments.values.count, 1)
    }

    func testConfigurationCannotAdvanceAcrossSuspendedCreateCommit() async throws {
        let coordinator = AdvancingConfigurationChatContextFixture(
            base: DefaultCoachContextFeature(
                source: AlwaysFitCoachContextSnapshotPort()
            )
        )
        let store = SuspendedCreateStore(coordinator: coordinator)
        let feature = makeFeature(store: store, coachContext: coordinator)
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))

        async let confirmation: Void = feature.sendCurrentNewChatConfirmation(Self.context)
        await store.waitUntilCreateStarts()
        async let advancement: Void = coordinator.advanceConfiguration()
        await coordinator.waitUntilAdvanceIsRequested()
        await store.resumeCreate()
        await confirmation
        await advancement

        let generationAtCommit = await store.configurationGenerationAtCommit
        XCTAssertEqual(generationAtCommit, 1)
        let state = await feature.currentState
        XCTAssertNotNil(Self.openAggregate(in: state))
        let currentGeneration = await coordinator.currentGeneration
        XCTAssertEqual(currentGeneration, 2)
    }

    func testCancelCannotClosePickerAfterDurableCreationStarts() async {
        let store = SuspendedCreateStore(result: .committed)
        let feature = makeFeature(store: store)
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))

        async let confirmation: Void = feature.sendCurrentNewChatConfirmation(Self.context)
        await store.waitUntilCreateStarts()
        let creatingState = await feature.currentState
        XCTAssertEqual(creatingState.activity, .creating)

        await feature.send(.cancelNewChat(Self.context))

        let stateAfterCancel = await feature.currentState
        XCTAssertEqual(stateAfterCancel.activity, .creating)
        guard case .ready = stateAfterCancel.newChatPicker else {
            await store.resumeCreate()
            await confirmation
            return XCTFail("durable creation must keep the picker until it resolves")
        }
        await store.resumeCreate()
        await confirmation

        let committedState = await feature.currentState
        XCTAssertNotNil(Self.openAggregate(in: committedState))
        XCTAssertEqual(committedState.newChatPicker, .closed)
    }

    func testCancelInterruptsSuspendedAttachmentCatalogAndClosesPicker() async {
        let coordinator = ScriptedNewChatCoachContext(suspendCatalog: true)
        let feature = makeFeature(
            store: RecordingChatStore(),
            coachContext: coordinator
        )
        await feature.send(.start(Self.context))
        let context = Self.context

        let loading = Task { await feature.send(.beginNewChat(context)) }
        await coordinator.waitUntilCatalogStarts()
        await feature.send(.cancelNewChat(context))
        await loading.value
        await coordinator.waitUntilCancellationIsObserved()

        let state = await feature.currentState
        let observedCancellation = await coordinator.observedCancellation
        XCTAssertEqual(state.newChatPicker, .closed)
        XCTAssertTrue(observedCancellation)
    }

    func testOrderlyTerminationCancelsSuspendedAttachmentCatalogAndFlushesDirtyDraft()
        async throws
    {
        let aggregate = try Self.aggregate()
        let store = RecordingChatStore(catalog: [.available(aggregate)])
        let scheduler = ControlledChatAutosaveScheduler()
        let coordinator = ScriptedNewChatCoachContext(suspendCatalog: true)
        let feature = makeFeature(
            store: store,
            autosaveScheduler: scheduler,
            coachContext: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        await feature.send(
            .editDraft(
                Self.context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: "Flush after cancelling the Session catalog."
            )
        )
        await scheduler.waitUntilScheduled()

        async let loading: Void = feature.send(.beginNewChat(Self.context))
        await coordinator.waitUntilCatalogStarts()
        async let mayTerminate: Bool = feature.flushForOrderlyTermination()

        await loading
        let terminationSucceeded = await mayTerminate
        let savedDrafts = await store.savedDrafts
        let state = await feature.currentState
        XCTAssertTrue(terminationSucceeded)
        XCTAssertEqual(
            savedDrafts.map(\.replacement.text),
            ["Flush after cancelling the Session catalog."]
        )
        XCTAssertEqual(state.newChatPicker, .closed)
    }

    func testCancelInterruptsSuspendedPostResolutionCreationQuoteAndClosesPicker()
        async throws
    {
        let candidate = try Self.attachmentCandidate()
        let coordinator = ScriptedNewChatCoachContext(
            candidates: [candidate],
            suspendedQuoteNumber: 3,
            rejectsCreationLease: true
        )
        let feature = makeFeature(
            store: RecordingChatStore(),
            coachContext: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))
        guard case let .ready(picker) = await feature.currentState.newChatPicker,
              let attachmentID = picker.allRows.first?.id
        else {
            return XCTFail("expected one projected attachment")
        }
        await feature.send(.toggleNewChatAttachment(Self.context, attachmentID))

        async let quoting: Void = feature.sendCurrentNewChatConfirmation(Self.context)
        await coordinator.waitUntilQuoteStarts()
        await feature.send(.cancelNewChat(Self.context))
        await quoting
        await coordinator.waitUntilCancellationIsObserved()

        let state = await feature.currentState
        let observedCancellation = await coordinator.observedCancellation
        let resolutionCount = await coordinator.resolutionCount
        XCTAssertEqual(state.newChatPicker, .closed)
        XCTAssertTrue(observedCancellation)
        XCTAssertEqual(resolutionCount, 1)
    }

    func testOrderlyTerminationCancelsSuspendedNewChatQuoteAndFlushesDirtyDraft()
        async throws
    {
        let aggregate = try Self.aggregate()
        let store = RecordingChatStore(catalog: [.available(aggregate)])
        let scheduler = ControlledChatAutosaveScheduler()
        let coordinator = ScriptedNewChatCoachContext(suspendedQuoteNumber: 1)
        let feature = makeFeature(
            store: store,
            autosaveScheduler: scheduler,
            coachContext: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        await feature.send(
            .editDraft(
                Self.context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: "Flush after cancelling the creation quote."
            )
        )
        await scheduler.waitUntilScheduled()

        async let quoting: Void = feature.send(.beginNewChat(Self.context))
        await coordinator.waitUntilQuoteStarts()
        async let mayTerminate: Bool = feature.flushForOrderlyTermination()

        await quoting
        let terminationSucceeded = await mayTerminate
        let savedDrafts = await store.savedDrafts
        let state = await feature.currentState
        XCTAssertTrue(terminationSucceeded)
        XCTAssertEqual(
            savedDrafts.map(\.replacement.text),
            ["Flush after cancelling the creation quote."]
        )
        XCTAssertEqual(state.newChatPicker, .closed)
    }

    func testCancelInterruptsSuspendedAttachmentResolutionAndClosesPicker()
        async throws
    {
        let candidate = try Self.attachmentCandidate()
        let coordinator = ScriptedNewChatCoachContext(
            candidates: [candidate],
            suspendResolution: true
        )
        let feature = makeFeature(
            store: RecordingChatStore(),
            coachContext: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))
        guard case let .ready(picker) = await feature.currentState.newChatPicker,
              let attachmentID = picker.allRows.first?.id
        else {
            return XCTFail("expected one projected attachment")
        }
        await feature.send(.toggleNewChatAttachment(Self.context, attachmentID))

        async let resolving: Void = feature.sendCurrentNewChatConfirmation(Self.context)
        await coordinator.waitUntilResolutionStarts()
        await feature.send(.cancelNewChat(Self.context))
        await resolving
        await coordinator.waitUntilCancellationIsObserved()

        let state = await feature.currentState
        let observedCancellation = await coordinator.observedCancellation
        XCTAssertEqual(state.newChatPicker, .closed)
        XCTAssertTrue(observedCancellation)
    }

    func testOrderlyTerminationCancelsSuspendedExactAttachmentResolutionAndFlushesDirtyDraft()
        async throws
    {
        let aggregate = try Self.aggregate()
        let candidate = try Self.attachmentCandidate()
        let store = RecordingChatStore(catalog: [.available(aggregate)])
        let scheduler = ControlledChatAutosaveScheduler()
        let coordinator = ScriptedNewChatCoachContext(
            candidates: [candidate],
            suspendResolution: true
        )
        let feature = makeFeature(
            store: store,
            autosaveScheduler: scheduler,
            coachContext: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        await feature.send(
            .editDraft(
                Self.context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: "Flush after cancelling exact attachment resolution."
            )
        )
        await scheduler.waitUntilScheduled()
        await feature.send(.beginNewChat(Self.context))
        guard case let .ready(picker) = await feature.currentState.newChatPicker,
              let attachmentID = picker.allRows.first?.id
        else {
            return XCTFail("expected one projected attachment")
        }
        await feature.send(.toggleNewChatAttachment(Self.context, attachmentID))

        async let resolving: Void = feature.sendCurrentNewChatConfirmation(Self.context)
        await coordinator.waitUntilResolutionStarts()
        async let mayTerminate: Bool = feature.flushForOrderlyTermination()

        await resolving
        let terminationSucceeded = await mayTerminate
        let savedDrafts = await store.savedDrafts
        let state = await feature.currentState
        XCTAssertTrue(terminationSucceeded)
        XCTAssertEqual(
            savedDrafts.map(\.replacement.text),
            ["Flush after cancelling exact attachment resolution."]
        )
        XCTAssertEqual(state.newChatPicker, .closed)
    }

    func testCancelReturnsBeforeNoncooperativeExactAttachmentResolutionAndLateResultCannotCreate()
        async throws
    {
        let candidate = try Self.attachmentCandidate()
        let coordinator = ScriptedNewChatCoachContext(
            candidates: [candidate],
            suspendResolutionNoncooperatively: true
        )
        let store = RecordingChatStore()
        let feature = makeFeature(store: store, coachContext: coordinator)
        let context = Self.context
        await feature.send(.start(context))
        await feature.send(.beginNewChat(context))
        guard case let .ready(picker) = await feature.currentState.newChatPicker,
              let attachmentID = picker.allRows.first?.id
        else {
            return XCTFail("expected one projected attachment")
        }
        await feature.send(.toggleNewChatAttachment(context, attachmentID))

        let confirmation = CompletionProbe<Void>()
        Task {
            await feature.sendCurrentNewChatConfirmation(context)
            await confirmation.complete(())
        }
        await coordinator.waitUntilResolutionStarts()
        await feature.send(.cancelNewChat(context))

        let confirmationCompleted = await confirmation.completesWithinYieldBudget()
        let cancelledState = await feature.currentState
        let seedsBeforeLateResolution = await store.createSeeds
        XCTAssertTrue(confirmationCompleted)
        XCTAssertEqual(cancelledState.newChatPicker, .closed)
        XCTAssertTrue(seedsBeforeLateResolution.isEmpty)

        await coordinator.resumeResolution()
        _ = await confirmation.completesWithinYieldBudget()
        let seedsAfterLateResolution = await store.createSeeds
        XCTAssertTrue(seedsAfterLateResolution.isEmpty)
    }

    func testCancelReturnsDuringNoncooperativeCreationLeaseAcquireAndLateLeaseSelfReleases()
        async
    {
        let coordinator = ScriptedNewChatCoachContext(
            suspendLeaseAcquisitionNoncooperatively: true
        )
        let store = RecordingChatStore()
        let feature = makeFeature(store: store, coachContext: coordinator)
        let context = Self.context
        await feature.send(.start(context))
        await feature.send(.beginNewChat(context))

        let confirmation = CompletionProbe<Void>()
        Task {
            await feature.sendCurrentNewChatConfirmation(context)
            await confirmation.complete(())
        }
        await coordinator.waitUntilLeaseAcquisitionStarts()
        await feature.send(.cancelNewChat(context))

        let confirmationCompleted = await confirmation.completesWithinYieldBudget()
        let cancelledState = await feature.currentState
        let seedsBeforeLateAcquire = await store.createSeeds
        XCTAssertTrue(confirmationCompleted)
        XCTAssertEqual(cancelledState.newChatPicker, .closed)
        XCTAssertTrue(seedsBeforeLateAcquire.isEmpty)

        await coordinator.resumeLeaseAcquisition()
        _ = await confirmation.completesWithinYieldBudget()
        await coordinator.waitUntilCreationLeaseReleaseCount(1)
        let releaseCount = await coordinator.creationLeaseReleaseCount
        let seedsAfterLateAcquire = await store.createSeeds
        XCTAssertEqual(releaseCount, 1)
        XCTAssertTrue(seedsAfterLateAcquire.isEmpty)
    }

    func testCancelReleasesAcquiredCreationLeaseWhileProfileReadIgnoresCancellation()
        async
    {
        let coordinator = ScriptedNewChatCoachContext()
        let profile = NoncooperativeProfileReader()
        let store = RecordingChatStore()
        let feature = makeFeature(
            store: store,
            profileReader: profile,
            coachContext: coordinator
        )
        let context = Self.context
        await feature.send(.start(context))
        await feature.send(.beginNewChat(context))

        let confirmation = CompletionProbe<Void>()
        Task {
            await feature.sendCurrentNewChatConfirmation(context)
            await confirmation.complete(())
        }
        await profile.waitUntilReadStarts()
        await feature.send(.cancelNewChat(context))

        let confirmationCompleted = await confirmation.completesWithinYieldBudget()
        await coordinator.waitUntilCreationLeaseReleaseCount(1)
        let releaseCount = await coordinator.creationLeaseReleaseCount
        let cancelledState = await feature.currentState
        let seedsBeforeLateProfile = await store.createSeeds
        XCTAssertTrue(confirmationCompleted)
        XCTAssertEqual(releaseCount, 1)
        XCTAssertEqual(cancelledState.newChatPicker, .closed)
        XCTAssertTrue(seedsBeforeLateProfile.isEmpty)

        await profile.resume()
        _ = await confirmation.completesWithinYieldBudget()
        let seedsAfterLateProfile = await store.createSeeds
        XCTAssertTrue(seedsAfterLateProfile.isEmpty)
    }

    func testCancelReturnsAndReleasesFeatureBeforeSuspendedLeaseCleanupCompletes()
        async
    {
        let coordinator = ScriptedNewChatCoachContext(
            suspendCreationLeaseReleaseNoncooperatively: true
        )
        let profile = NoncooperativeProfileReader()
        let store = RecordingChatStore()
        var feature: DefaultChatFeature? = makeFeature(
            store: store,
            profileReader: profile,
            coachContext: coordinator
        )
        weak var observedFeature = feature
        let context = Self.context
        await feature?.send(.start(context))
        await feature?.send(.beginNewChat(context))

        let confirmation = CompletionProbe<Void>()
        Task { [weak feature] in
            await feature?.sendCurrentNewChatConfirmation(context)
            await confirmation.complete(())
        }
        await profile.waitUntilReadStarts()

        let cancellation = CompletionProbe<Void>()
        Task { [weak feature] in
            await feature?.send(.cancelNewChat(context))
            await cancellation.complete(())
        }
        await coordinator.waitUntilCreationLeaseReleaseStarts()

        let cancellationReturned = await cancellation.completesWithinYieldBudget()
        let confirmationReturned = await confirmation.completesWithinYieldBudget()
        let stateBeforeCleanup = await feature?.currentState
        let seedsBeforeCleanup = await store.createSeeds
        feature = nil
        for _ in 0 ..< 10_000 where observedFeature != nil {
            await Task.yield()
        }
        let featureReleasedBeforeCleanup = observedFeature == nil

        await coordinator.resumeCreationLeaseRelease()
        await coordinator.waitUntilCreationLeaseReleaseCount(1)
        await profile.resume()
        _ = await cancellation.completesWithinYieldBudget()
        _ = await confirmation.completesWithinYieldBudget()
        let releaseCount = await coordinator.creationLeaseReleaseCount
        let seedsAfterLateProfile = await store.createSeeds

        XCTAssertTrue(cancellationReturned)
        XCTAssertTrue(confirmationReturned)
        XCTAssertEqual(stateBeforeCleanup?.newChatPicker, .closed)
        XCTAssertTrue(seedsBeforeCleanup.isEmpty)
        XCTAssertTrue(featureReleasedBeforeCleanup)
        XCTAssertEqual(releaseCount, 1)
        XCTAssertTrue(seedsAfterLateProfile.isEmpty)
    }

    func testOrderlyTerminationReturnsAndReleasesFeatureBeforeSuspendedLeaseCleanupCompletes()
        async
    {
        let coordinator = ScriptedNewChatCoachContext(
            suspendCreationLeaseReleaseNoncooperatively: true
        )
        let profile = NoncooperativeProfileReader()
        let store = RecordingChatStore()
        var feature: DefaultChatFeature? = makeFeature(
            store: store,
            profileReader: profile,
            coachContext: coordinator
        )
        weak var observedFeature = feature
        let context = Self.context
        await feature?.send(.start(context))
        await feature?.send(.beginNewChat(context))

        let confirmation = CompletionProbe<Void>()
        Task { [weak feature] in
            await feature?.sendCurrentNewChatConfirmation(context)
            await confirmation.complete(())
        }
        await profile.waitUntilReadStarts()

        let termination = CompletionProbe<Void>()
        Task { [weak feature] in
            await feature?.beginOrderlyTermination()
            await termination.complete(())
        }
        await coordinator.waitUntilCreationLeaseReleaseStarts()

        let terminationReturned = await termination.completesWithinYieldBudget()
        let confirmationReturned = await confirmation.completesWithinYieldBudget()
        let stateBeforeCleanup = await feature?.currentState
        let seedsBeforeCleanup = await store.createSeeds
        feature = nil
        for _ in 0 ..< 10_000 where observedFeature != nil {
            await Task.yield()
        }
        let featureReleasedBeforeCleanup = observedFeature == nil

        await coordinator.resumeCreationLeaseRelease()
        await coordinator.waitUntilCreationLeaseReleaseCount(1)
        await profile.resume()
        _ = await termination.completesWithinYieldBudget()
        _ = await confirmation.completesWithinYieldBudget()
        let releaseCount = await coordinator.creationLeaseReleaseCount
        let seedsAfterLateProfile = await store.createSeeds

        XCTAssertTrue(terminationReturned)
        XCTAssertTrue(confirmationReturned)
        XCTAssertEqual(stateBeforeCleanup?.newChatPicker, .closed)
        XCTAssertTrue(seedsBeforeCleanup.isEmpty)
        XCTAssertTrue(featureReleasedBeforeCleanup)
        XCTAssertEqual(releaseCount, 1)
        XCTAssertTrue(seedsAfterLateProfile.isEmpty)
    }

    func testMissingProfilePublishesFailureBeforeSuspendedLeaseCleanupCompletes()
        async
    {
        let coordinator = ScriptedNewChatCoachContext(
            suspendCreationLeaseReleaseNoncooperatively: true
        )
        let store = RecordingChatStore()
        let feature = makeFeature(
            store: store,
            profileReader: MissingProfileReader(),
            coachContext: coordinator
        )
        let context = Self.context
        await feature.send(.start(context))
        await feature.send(.beginNewChat(context))

        let confirmation = CompletionProbe<Void>()
        Task {
            await feature.sendCurrentNewChatConfirmation(context)
            await confirmation.complete(())
        }
        await coordinator.waitUntilCreationLeaseReleaseStarts()

        let confirmationReturned = await confirmation.completesWithinYieldBudget()
        let stateBeforeCleanup = await feature.currentState
        let seedsBeforeCleanup = await store.createSeeds

        await coordinator.resumeCreationLeaseRelease()
        await coordinator.waitUntilCreationLeaseReleaseCount(1)
        _ = await confirmation.completesWithinYieldBudget()
        let releaseCount = await coordinator.creationLeaseReleaseCount

        XCTAssertTrue(confirmationReturned)
        XCTAssertEqual(stateBeforeCleanup.notice, .createFailed)
        XCTAssertNil(stateBeforeCleanup.activity)
        XCTAssertTrue(seedsBeforeCleanup.isEmpty)
        XCTAssertEqual(releaseCount, 1)
    }

    func testCommittedChatPublishesAndReleasesFeatureBeforeSuspendedLeaseCleanupCompletes()
        async
    {
        let coordinator = ScriptedNewChatCoachContext(
            suspendCreationLeaseReleaseNoncooperatively: true
        )
        let store = RecordingChatStore()
        var feature: DefaultChatFeature? = makeFeature(
            store: store,
            coachContext: coordinator
        )
        weak var observedFeature = feature
        let context = Self.context
        await feature?.send(.start(context))
        await feature?.send(.beginNewChat(context))

        let confirmation = CompletionProbe<Void>()
        Task { [weak feature] in
            await feature?.sendCurrentNewChatConfirmation(context)
            await confirmation.complete(())
        }
        await coordinator.waitUntilCreationLeaseReleaseStarts()

        let confirmationReturned = await confirmation.completesWithinYieldBudget()
        let stateBeforeCleanup = await feature?.currentState
        let seedsBeforeCleanup = await store.createSeeds
        feature = nil
        for _ in 0 ..< 10_000 where observedFeature != nil {
            await Task.yield()
        }
        let featureReleasedBeforeCleanup = observedFeature == nil

        await coordinator.resumeCreationLeaseRelease()
        await coordinator.waitUntilCreationLeaseReleaseCount(1)
        _ = await confirmation.completesWithinYieldBudget()
        let releaseCount = await coordinator.creationLeaseReleaseCount

        XCTAssertTrue(confirmationReturned)
        XCTAssertEqual(stateBeforeCleanup?.newChatPicker, .closed)
        XCTAssertNil(stateBeforeCleanup?.activity)
        XCTAssertNotNil(stateBeforeCleanup.flatMap(Self.openAggregate(in:)))
        XCTAssertEqual(seedsBeforeCleanup.count, 1)
        XCTAssertTrue(featureReleasedBeforeCleanup)
        XCTAssertEqual(releaseCount, 1)
    }

    func testCancelDuringNoncooperativePrecommitClockNeverEntersCreatingOrCreates()
        async
    {
        let coordinator = ScriptedNewChatCoachContext()
        let clock = NoncooperativeNewChatClock()
        let store = RecordingChatStore()
        let feature = makeFeature(
            store: store,
            clock: clock,
            coachContext: coordinator
        )
        let context = Self.context
        await feature.send(.start(context))
        await feature.send(.beginNewChat(context))

        let confirmation = CompletionProbe<Void>()
        Task {
            await feature.sendCurrentNewChatConfirmation(context)
            await confirmation.complete(())
        }
        await clock.waitUntilReadStarts()
        let stateBeforeCancel = await feature.currentState
        XCTAssertNil(stateBeforeCancel.activity)
        await feature.send(.cancelNewChat(context))

        let confirmationCompleted = await confirmation.completesWithinYieldBudget()
        await coordinator.waitUntilCreationLeaseReleaseCount(1)
        let releaseCount = await coordinator.creationLeaseReleaseCount
        let cancelledState = await feature.currentState
        let seedsBeforeLateClock = await store.createSeeds
        XCTAssertTrue(confirmationCompleted)
        XCTAssertEqual(releaseCount, 1)
        XCTAssertNil(cancelledState.activity)
        XCTAssertTrue(seedsBeforeLateClock.isEmpty)

        await clock.resume()
        _ = await confirmation.completesWithinYieldBudget()
        let seedsAfterLateClock = await store.createSeeds
        XCTAssertTrue(seedsAfterLateClock.isEmpty)
    }

    func testOrderlyTerminationCancelsNoncooperativePrecommitIDReleasesLeaseAndFlushesDraft()
        async throws
    {
        let aggregate = try Self.aggregate()
        let store = RecordingChatStore(catalog: [.available(aggregate)])
        let scheduler = ControlledChatAutosaveScheduler()
        let coordinator = ScriptedNewChatCoachContext()
        let identifiers = NoncooperativeNewChatIdentifiers()
        let feature = makeFeature(
            store: store,
            chatIDGenerator: identifiers,
            draftIDGenerator: identifiers,
            memoryIDGenerator: identifiers,
            autosaveScheduler: scheduler,
            coachContext: coordinator
        )
        let context = Self.context
        await feature.send(.start(context))
        await feature.send(.open(context, aggregate.chat.id))
        await feature.send(
            .editDraft(
                context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: "Flush while cancelling precommit identity work."
            )
        )
        await scheduler.waitUntilScheduled()
        await feature.send(.beginNewChat(context))

        let confirmation = CompletionProbe<Void>()
        Task {
            await feature.sendCurrentNewChatConfirmation(context)
            await confirmation.complete(())
        }
        await identifiers.waitUntilChatIDRequestStarts()
        let stateBeforeTermination = await feature.currentState
        XCTAssertNil(stateBeforeTermination.activity)
        let termination = CompletionProbe<Bool>()
        Task {
            await termination.complete(await feature.flushForOrderlyTermination())
        }

        let terminationCompleted = await termination.completesWithinYieldBudget()
        let terminationValue = await termination.value
        await coordinator.waitUntilCreationLeaseReleaseCount(1)
        let releaseCount = await coordinator.creationLeaseReleaseCount
        let terminatedState = await feature.currentState
        let savedDrafts = await store.savedDrafts
        let seedsBeforeLateID = await store.createSeeds
        XCTAssertTrue(terminationCompleted)
        XCTAssertEqual(terminationValue, true)
        XCTAssertEqual(releaseCount, 1)
        XCTAssertEqual(terminatedState.newChatPicker, .closed)
        XCTAssertEqual(
            savedDrafts.map(\.replacement.text),
            ["Flush while cancelling precommit identity work."]
        )
        XCTAssertTrue(seedsBeforeLateID.isEmpty)

        await identifiers.resumeChatIDRequest()
        _ = await confirmation.completesWithinYieldBudget()
        let seedsAfterLateID = await store.createSeeds
        XCTAssertTrue(seedsAfterLateID.isEmpty)
    }

    func testOpenRetriesOneConfigurationRaceWithoutMutatingPinnedAttachments()
        async throws
    {
        let attachment = try Self.attachment()
        let attachments = try ChatAttachments(validating: [attachment])
        let candidate = try Self.attachmentCandidate()
        let resolved = try ResolvedChatAttachment(
            attachment: attachment,
            resolution: .available(candidate)
        )
        let coordinator = ScriptedNewChatCoachContext(
            candidates: [candidate],
            resolutionOutcomes: [
                .configurationChanged,
                .resolved([resolved], configuration: chatFeatureConfigurationStamp),
            ]
        )
        let aggregate = try Self.aggregate(attachments: attachments)
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(aggregate)]),
            coachContext: coordinator
        )
        await feature.send(.start(Self.context))

        await feature.send(.open(Self.context, aggregate.chat.id))

        let state = await feature.currentState
        let resolutionCount = await coordinator.resolutionCount
        XCTAssertEqual(state.openedAttachments, .resolved([resolved]))
        XCTAssertEqual(resolutionCount, 2)
        XCTAssertEqual(Self.openAggregate(in: state)?.chat.attachments, attachments)
    }

    func testAttachmentUnavailableAtAtomicCreateKeepsPickerOpenForRepair()
        async throws
    {
        let candidate = try Self.attachmentCandidate()
        let coordinator = ScriptedNewChatCoachContext(candidates: [candidate])
        let store = RecordingChatStore(createOutcomes: [.attachmentUnavailable])
        let feature = makeFeature(store: store, coachContext: coordinator)
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))
        guard case let .ready(picker) = await feature.currentState.newChatPicker,
              let attachmentID = picker.allRows.first?.id
        else {
            return XCTFail("expected one projected attachment")
        }
        await feature.send(.toggleNewChatAttachment(Self.context, attachmentID))

        await feature.sendCurrentNewChatConfirmation(Self.context)

        let state = await feature.currentState
        guard case let .ready(repairedPicker) = state.newChatPicker else {
            return XCTFail("atomic evidence failure must keep the picker open")
        }
        XCTAssertEqual(repairedPicker.issue, .attachmentUnavailable)
        XCTAssertNil(Self.openAggregate(in: state))
        let seeds = await store.createSeeds
        XCTAssertEqual(seeds.count, 1)
        XCTAssertEqual(seeds.first?.aggregate.chat.attachments.values.count, 1)
    }

    func testAttachmentDisappearingDuringSuspendedCreateInstallsNothing()
        async throws
    {
        let candidate = try Self.attachmentCandidate()
        let coordinator = ScriptedNewChatCoachContext(candidates: [candidate])
        let store = SuspendedCreateStore(result: .attachmentUnavailable)
        let feature = makeFeature(store: store, coachContext: coordinator)
        await feature.send(.start(Self.context))
        await feature.send(.beginNewChat(Self.context))
        guard case let .ready(picker) = await feature.currentState.newChatPicker,
              let attachmentID = picker.allRows.first?.id
        else {
            return XCTFail("expected one projected attachment")
        }
        await feature.send(.toggleNewChatAttachment(Self.context, attachmentID))

        async let confirmation: Void = feature.sendCurrentNewChatConfirmation(Self.context)
        await store.waitUntilCreateStarts()
        let seedsAtFinalBoundary = await store.createSeeds
        XCTAssertEqual(
            seedsAtFinalBoundary.first?.aggregate.chat.attachments.values.count,
            1
        )
        await store.resumeCreate()
        await confirmation

        let state = await feature.currentState
        guard case let .ready(repairedPicker) = state.newChatPicker else {
            return XCTFail("atomic evidence race must keep the picker open")
        }
        XCTAssertEqual(repairedPicker.issue, .attachmentUnavailable)
        XCTAssertNil(Self.openAggregate(in: state))
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

    func testRenamePreservesAnExistingPendingUserTurn() async throws {
        let original = try Self.aggregate(draftText: "Locked synthetic Draft")
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120001000Z-5KMN"),
            draftID: original.chat.draft.draftID,
            draftVersion: original.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120001000Z-6PQR"
            )
        )
        let locked = try ChatAggregate(
            chat: original.chat,
            memory: original.memory,
            pendingUserTurn: pending
        )
        let store = RecordingChatStore(catalog: [.available(locked)])
        let feature = makeFeature(store: store)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, locked.chat.id))

        await feature.send(
            .rename(
                Self.context,
                locked.chat.id,
                title: "Pending Reflection",
                expectedRevision: locked.chat.manifestRevision
            )
        )

        let state = await feature.currentState
        let renamed = try XCTUnwrap(Self.openAggregate(in: state))
        XCTAssertEqual(renamed.chat.title, try ChatTitle("Pending Reflection"))
        XCTAssertEqual(renamed.pendingUserTurn, pending)
        XCTAssertEqual(renamed.chat.draft, locked.chat.draft)
    }

    func testRenameRebasesOnlyItsOwnedDirtyDraftFlush() async throws {
        let original = try Self.aggregate()
        let store = RecordingChatStore(catalog: [.available(original)])
        let scheduler = ControlledChatAutosaveScheduler()
        let feature = makeFeature(store: store, autosaveScheduler: scheduler)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, original.chat.id))
        await feature.send(
            .editDraft(
                Self.context,
                original.chat.id,
                original.chat.draft.draftID,
                text: "Keep this Draft while renaming."
            )
        )
        await scheduler.waitUntilScheduled()

        await feature.send(
            .rename(
                Self.context,
                original.chat.id,
                title: "Renamed After Draft",
                expectedRevision: original.chat.manifestRevision
            )
        )

        let state = await feature.currentState
        let renamed = try XCTUnwrap(Self.openAggregate(in: state))
        XCTAssertEqual(renamed.chat.title, try ChatTitle("Renamed After Draft"))
        XCTAssertEqual(renamed.chat.draft.text, "Keep this Draft while renaming.")
        XCTAssertEqual(renamed.chat.manifestRevision, 2)
        XCTAssertNil(state.notice)
        let calls = await store.calls
        XCTAssertEqual(calls, [.loadCatalog, .load, .saveDraft, .rename])
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

    func testDirtyDraftAutosavesOnTheTwoSecondDeadline() async throws {
        let aggregate = try Self.aggregate()
        let store = RecordingChatStore(catalog: [.available(aggregate)])
        let scheduler = ControlledChatAutosaveScheduler()
        let feature = makeFeature(store: store, autosaveScheduler: scheduler)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))

        await feature.send(
            .editDraft(
                Self.context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: "Help me sharpen this synthetic opening."
            )
        )

        await scheduler.waitUntilScheduled()
        let requestedNanoseconds = await scheduler.requestedNanoseconds
        XCTAssertEqual(requestedNanoseconds, [2_000_000_000])
        let dirtyState = await feature.currentState
        guard case let .editable(dirtyDraft, isDirty) = dirtyState.composer else {
            return XCTFail("expected editable Draft")
        }
        XCTAssertTrue(isDirty)
        XCTAssertEqual(dirtyDraft.version, 1)

        await scheduler.resume()
        await store.waitForSavedDraftCount(1)

        let savedDrafts = await store.savedDrafts
        let saved = try XCTUnwrap(savedDrafts.first)
        XCTAssertEqual(saved.replacement.version, 1)
        XCTAssertEqual(saved.replacement.text,
                       "Help me sharpen this synthetic opening.")
        let cleanState = await feature.currentState
        guard case let .editable(cleanDraft, clean) = cleanState.composer else {
            return XCTFail("expected editable Draft")
        }
        XCTAssertFalse(clean)
        XCTAssertEqual(cleanDraft, saved.replacement)
    }

    func testEditDuringInFlightAutosaveStartsItsOwnTwoSecondDeadline() async throws {
        let aggregate = try Self.aggregate()
        let store = RecordingChatStore(
            catalog: [.available(aggregate)],
            suspendNextDraftSave: true
        )
        let scheduler = ControlledChatAutosaveScheduler()
        let feature = makeFeature(store: store, autosaveScheduler: scheduler)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        await feature.send(
            .editDraft(
                Self.context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: "First version"
            )
        )
        await scheduler.waitForScheduleCount(1)
        await scheduler.resume()
        await store.waitUntilDraftSaveStarts()

        await feature.send(
            .editDraft(
                Self.context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: "Second version"
            )
        )

        await scheduler.waitForScheduleCount(2)
        let requested = await scheduler.requestedNanoseconds
        XCTAssertEqual(requested, [2_000_000_000, 2_000_000_000])

        await scheduler.resume()
        await store.resumeDraftSave()
        await store.waitForSavedDraftCount(2)
        let saved = await store.savedDrafts
        XCTAssertEqual(saved.map(\.replacement.version), [1, 2])
        XCTAssertEqual(saved.map(\.replacement.text), ["First version", "Second version"])
    }

    func testRapidEditsAreQueuedWhileTheClockIsSuspendedWithoutDroppingText() async throws {
        let aggregate = try Self.aggregate()
        let store = RecordingChatStore(catalog: [.available(aggregate)])
        let scheduler = ControlledChatAutosaveScheduler()
        let clock = SuspendedFirstChatClock()
        let feature = makeFeature(
            store: store,
            clock: clock,
            autosaveScheduler: scheduler
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))

        async let firstEdit: Void = feature.send(
            .editDraft(
                Self.context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: "First synthetic keystroke"
            )
        )
        await clock.waitUntilFirstRequestIsSuspended()

        await feature.send(
            .editDraft(
                Self.context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: "First synthetic keystroke, then the rest"
            )
        )
        await clock.resumeFirstRequest()
        await firstEdit

        let state = await feature.currentState
        guard case let .editable(draft, isDirty) = state.composer else {
            return XCTFail("expected editable Draft")
        }
        XCTAssertTrue(isDirty)
        XCTAssertEqual(draft.version, 2)
        XCTAssertEqual(draft.text, "First synthetic keystroke, then the rest")
    }

    func testSendCapturedBeforeSuspendedEditCannotLockTheLaterDraft() async throws {
        let aggregate = try Self.aggregate()
        let store = RecordingChatStore(catalog: [.available(aggregate)])
        let scheduler = ControlledChatAutosaveScheduler()
        let clock = SuspendedFirstChatClock()
        let feature = makeFeature(
            store: store,
            clock: clock,
            autosaveScheduler: scheduler
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))

        async let edit: Void = feature.send(
            .editDraft(
                Self.context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: "Send this complete synthetic Draft."
            )
        )
        await clock.waitUntilFirstRequestIsSuspended()
        await feature.send(
            .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )
        await clock.resumeFirstRequest()
        await edit

        let state = await feature.currentState
        guard case let .editable(draft, isDirty) = state.composer else {
            return XCTFail("expected the later Draft to remain editable")
        }
        XCTAssertTrue(isDirty)
        XCTAssertEqual(draft.text, "Send this complete synthetic Draft.")
        XCTAssertEqual(draft.version, 1)
        let calls = await store.calls
        XCTAssertEqual(calls, [.loadCatalog, .load])
    }

    func testOpenQueuedBehindSuspendedEditFlushesBeforeChangingSelection() async throws {
        let first = try Self.aggregate()
        let second = try Self.aggregate(
            chat: "cht-20260830T120100000Z-5KMN",
            draft: "drf-20260830T120100000Z-6PQR",
            memory: "mem-20260830T120100000Z-7STV",
            title: "Second Chat"
        )
        let store = RecordingChatStore(catalog: [.available(first), .available(second)])
        let scheduler = ControlledChatAutosaveScheduler()
        let clock = SuspendedFirstChatClock()
        let feature = makeFeature(
            store: store,
            clock: clock,
            autosaveScheduler: scheduler
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, first.chat.id))

        async let edit: Void = feature.send(
            .editDraft(
                Self.context,
                first.chat.id,
                first.chat.draft.draftID,
                text: "Flush before opening the second Chat."
            )
        )
        await clock.waitUntilFirstRequestIsSuspended()
        await feature.send(.open(Self.context, second.chat.id))
        await clock.resumeFirstRequest()
        await edit

        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state)?.chat.id, second.chat.id)
        let savedDrafts = await store.savedDrafts
        XCTAssertEqual(
            savedDrafts.map(\.replacement.text),
            ["Flush before opening the second Chat."]
        )
        let calls = await store.calls
        XCTAssertEqual(calls, [.loadCatalog, .load, .saveDraft, .load])
    }

    func testEditAdmittedBeforeQueuedOpenCannotLeakIntoTheNewChat() async throws {
        let first = try Self.aggregate()
        let second = try Self.aggregate(
            chat: "cht-20260830T120100000Z-5KMN",
            draft: "drf-20260830T120100000Z-6PQR",
            memory: "mem-20260830T120100000Z-7STV",
            title: "Second Chat"
        )
        let store = RecordingChatStore(catalog: [.available(first), .available(second)])
        let scheduler = ControlledChatAutosaveScheduler()
        let clock = SuspendedFirstChatClock()
        let feature = makeFeature(
            store: store,
            clock: clock,
            autosaveScheduler: scheduler
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, first.chat.id))

        async let edit: Void = feature.send(
            .editDraft(
                Self.context,
                first.chat.id,
                first.chat.draft.draftID,
                text: "Belongs only to the first Chat."
            )
        )
        await clock.waitUntilFirstRequestIsSuspended()
        await feature.send(.open(Self.context, second.chat.id))
        await feature.send(
            .editDraft(
                Self.context,
                first.chat.id,
                first.chat.draft.draftID,
                text: "Stale text must not cross Chat identity."
            )
        )
        await clock.resumeFirstRequest()
        await edit

        let state = await feature.currentState
        guard case let .editable(draft, isDirty) = state.composer else {
            return XCTFail("expected the second Chat Draft")
        }
        XCTAssertEqual(Self.openAggregate(in: state)?.chat.id, second.chat.id)
        XCTAssertEqual(draft, second.chat.draft)
        XCTAssertFalse(isDirty)
        let savedDrafts = await store.savedDrafts
        XCTAssertEqual(savedDrafts.map(\.replacement.text), ["Belongs only to the first Chat."])
    }

    func testOrderlyTerminationWaitsForSuspendedEditAndFlushesItsFinalVersion() async throws {
        let aggregate = try Self.aggregate()
        let store = RecordingChatStore(catalog: [.available(aggregate)])
        let scheduler = ControlledChatAutosaveScheduler()
        let clock = SuspendedFirstChatClock()
        let feature = makeFeature(
            store: store,
            clock: clock,
            autosaveScheduler: scheduler
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))

        async let edit: Void = feature.send(
            .editDraft(
                Self.context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: "Flush before orderly termination."
            )
        )
        await clock.waitUntilFirstRequestIsSuspended()
        async let mayTerminate: Bool = feature.flushForOrderlyTermination()
        await Task.yield()
        let savesWhileEditIsSuspended = await store.savedDrafts
        XCTAssertEqual(savesWhileEditIsSuspended, [])

        await clock.resumeFirstRequest()
        await edit
        let terminationAllowed = await mayTerminate
        XCTAssertTrue(terminationAllowed)

        let savedDrafts = await store.savedDrafts
        XCTAssertEqual(savedDrafts.map(\.replacement.version), [1])
        XCTAssertEqual(savedDrafts.map(\.replacement.text), [
            "Flush before orderly termination.",
        ])
    }

    func testSendCancelsAutosaveFlushesAndLocksOneExactPendingUserTurn() async throws {
        let aggregate = try Self.aggregate()
        let store = RecordingChatStore(catalog: [.available(aggregate)])
        let scheduler = ControlledChatAutosaveScheduler()
        let gateway = RecordingInterruptedInvocationGateway()
        let feature = makeFeature(
            store: store,
            autosaveScheduler: scheduler,
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        await feature.send(
            .editDraft(
                Self.context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: "Keep this exact synthetic Draft."
            )
        )
        await scheduler.waitUntilScheduled()
        let expectedDraft = try await Self.editableDraft(in: feature)

        await feature.send(
            .sendDraft(Self.context, aggregate.chat.id, expectedDraft)
        )

        let state = await feature.currentState
        guard case let .open(lockedAggregate) = state.selection,
              case let .locked(lockedDraft, pending) = state.composer
        else {
            return XCTFail("expected one locked Pending User Turn")
        }
        XCTAssertEqual(lockedDraft.text, "Keep this exact synthetic Draft.")
        XCTAssertEqual(pending.draftID, lockedDraft.draftID)
        XCTAssertEqual(pending.draftVersion, lockedDraft.version)
        XCTAssertEqual(lockedAggregate.pendingUserTurn, pending)
        XCTAssertEqual(lockedAggregate.chat.messageIDs, [])
        let calls = await store.calls
        XCTAssertEqual(calls, [.loadCatalog, .load, .saveDraft])
        let preparations = await gateway.preparations
        XCTAssertEqual(preparations.count, 1)
        XCTAssertEqual(preparations.first?.observedAggregate.chat.draft, lockedDraft)
        XCTAssertEqual(preparations.first?.pendingUserTurn, pending)
    }

    func testStopBypassesSuspendedSendAndPublishesOnlyInterruptedPending()
        async throws
    {
        let aggregate = try Self.aggregate(
            draftText: "Stop this exact synthetic response."
        )
        let gateway = StoppableInvocationGateway()
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(aggregate)]),
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))

        async let sending: Void = feature.send(
            .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )
        let authority = await gateway.waitUntilInvocationIsSuspended()
        let processingState = await feature.currentState
        XCTAssertEqual(processingState.coachInvocationStopAuthority, authority)
        XCTAssertEqual(processingState.activity, .invokingCoach(aggregate.chat.id))

        async let stopping: Void = feature.send(
            .stopCoachResponse(Self.context, authority)
        )
        await gateway.waitUntilStopStarts()

        let stoppingState = await feature.currentState
        XCTAssertEqual(stoppingState.activity, .stoppingCoach(aggregate.chat.id))

        await gateway.resumeReap()
        await stopping
        await sending

        let finalState = await feature.currentState
        guard case let .open(finalAggregate) = finalState.selection,
              let pending = finalAggregate.pendingUserTurn
        else { return XCTFail("Stop must retain the exact locked Pending") }
        XCTAssertEqual(pending.failure, .coachResponseInterrupted)
        XCTAssertEqual(finalAggregate.chat.messageIDs, [])
        XCTAssertEqual(finalState.composer, .locked(finalAggregate.chat.draft, pending))
        XCTAssertNil(finalState.activity)
        XCTAssertNil(finalState.coachInvocationStopAuthority)
        let stops = await gateway.stops
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops.first?.authority, authority)
        XCTAssertEqual(stops.first?.request.library, Self.scope)
        XCTAssertEqual(stops.first?.request.chatID, aggregate.chat.id)
        XCTAssertEqual(stops.first?.request.pendingUserTurnID, pending.id)
    }

    func testFilterChangePreservesSuspendedInvocationsExactStopAuthority()
        async throws
    {
        let aggregate = try Self.aggregate(
            draftText: "Keep Stop available while filtering Chats."
        )
        let gateway = StoppableInvocationGateway()
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(aggregate)]),
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        async let sending: Void = feature.send(
            .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )
        let authority = await gateway.waitUntilInvocationIsSuspended()

        let filter = try ChatFilterQuery("not the selected Chat")
        await feature.send(.setFilter(Self.context, filter))

        let filteredState = await feature.currentState
        XCTAssertEqual(filteredState.filterQuery, filter)
        XCTAssertEqual(filteredState.coachInvocationStopAuthority, authority)
        XCTAssertEqual(filteredState.activity, .invokingCoach(aggregate.chat.id))

        async let stopping: Void = feature.send(
            .stopCoachResponse(Self.context, authority)
        )
        await gateway.waitUntilStopStarts()
        await gateway.resumeReap()
        await stopping
        await sending

        let finalState = await feature.currentState
        XCTAssertEqual(
            Self.openAggregate(in: finalState)?.pendingUserTurn?.failure,
            .coachResponseInterrupted
        )
        let stops = await gateway.stops
        XCTAssertEqual(stops.map(\.authority), [authority])
    }

    func testStopDuringRetryKeepsInterruptedStateAfterRetryContinuationFinishes()
        async throws
    {
        let aggregate = try Self.aggregate(
            draftText: "Stop this retried synthetic response."
        )
        let failedPending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120000000Z-5KMN"),
            draftID: aggregate.chat.draft.draftID,
            draftVersion: aggregate.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120000000Z-6PQR"
            ),
            failure: .coachProviderError
        )
        let failedAggregate = try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            pendingUserTurn: failedPending
        )
        let gateway = StoppableRetryInvocationGateway(
            failedAggregate: failedAggregate
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(failedAggregate)]),
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))

        async let retrying: Void = feature.send(
            .retryPendingUserTurn(Self.context, failedPending.id)
        )
        let authority = await gateway.waitUntilRetryIsSuspended()
        let processingState = await feature.currentState
        XCTAssertEqual(processingState.coachInvocationStopAuthority, authority)
        XCTAssertEqual(processingState.activity, .invokingCoach(aggregate.chat.id))
        XCTAssertNil(
            Self.openAggregate(in: processingState)?.pendingUserTurn?.failure
        )

        async let stopping: Void = feature.send(
            .stopCoachResponse(Self.context, authority)
        )
        await gateway.waitUntilStopStarts()
        await gateway.resumeReap()
        await stopping

        let stoppedState = await feature.currentState
        guard case let .open(stoppedAggregate) = stoppedState.selection,
              let stoppedPending = stoppedAggregate.pendingUserTurn
        else { return XCTFail("Stop must install the interrupted Retry state") }
        XCTAssertEqual(stoppedPending.failure, .coachResponseInterrupted)
        XCTAssertEqual(stoppedAggregate.chat.messageIDs, [])
        XCTAssertNil(stoppedState.activity)
        XCTAssertNil(stoppedState.coachInvocationStopAuthority)

        await gateway.finishStoppedRetry()
        await retrying

        let finalState = await feature.currentState
        XCTAssertEqual(finalState.selection, .open(stoppedAggregate))
        XCTAssertEqual(
            finalState.composer,
            .locked(stoppedAggregate.chat.draft, stoppedPending)
        )
        XCTAssertNil(finalState.activity)
        XCTAssertNil(finalState.coachInvocationStopAuthority)
    }

    func testStaleStopAuthorityCannotStopReplacementAttempt() async throws {
        let aggregate = try Self.aggregate(
            draftText: "Keep the replacement attempt authoritative."
        )
        let gateway = StoppableInvocationGateway()
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(aggregate)]),
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        async let sending: Void = feature.send(
            .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )
        let authority = await gateway.waitUntilInvocationIsSuspended()
        let forged = InvocationStopAuthority(
            testingRequest: StopCoachInvocationRequest(
                library: authority.library,
                chatID: authority.chatID,
                pendingUserTurnID: authority.pendingUserTurnID
            ),
            invocationID: authority.invocationID,
            attemptID: authority.attemptID,
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000399"
            )!
        )

        await feature.send(.stopCoachResponse(Self.context, forged))

        let stops = await gateway.stops
        let currentAuthority = await feature.currentState
            .coachInvocationStopAuthority
        XCTAssertEqual(stops.count, 0)
        XCTAssertEqual(
            currentAuthority,
            authority
        )
        await gateway.finishWithoutStop()
        await sending
    }

    func testOrderlyTerminationStopsAndReapsSuspendedCoachBeforeFlushing()
        async throws
    {
        let aggregate = try Self.aggregate(
            draftText: "Stop this response before orderly termination."
        )
        let gateway = StoppableInvocationGateway()
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(aggregate)]),
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        async let sending: Void = feature.send(
            .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )
        _ = await gateway.waitUntilInvocationIsSuspended()

        async let terminationSucceeded: Bool = feature.flushForOrderlyTermination()
        await gateway.waitUntilStopStarts()
        let stoppingState = await feature.currentState
        XCTAssertEqual(stoppingState.activity, .stoppingCoach(aggregate.chat.id))

        await gateway.resumeReap()
        let didTerminate = await terminationSucceeded
        XCTAssertTrue(didTerminate)
        await sending
        let state = await feature.currentState
        XCTAssertEqual(
            Self.openAggregate(in: state)?.pendingUserTurn?.failure,
            .coachResponseInterrupted
        )
        XCTAssertNil(state.activity)
    }

    func testOrderlyTerminationFailsClosedWhenCoachCannotBeReaped()
        async throws
    {
        let aggregate = try Self.aggregate(
            draftText: "Keep this Draft locked when reaping cannot be proven."
        )
        let gateway = UnreapableStoppableInvocationGateway()
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(aggregate)]),
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        async let sending: Void = feature.send(
            .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )
        let authority = await gateway.waitUntilInvocationIsSuspended()

        let mayTerminate = await feature.flushForOrderlyTermination()
        await sending

        XCTAssertFalse(mayTerminate)
        let state = await feature.currentState
        XCTAssertEqual(state.activity, .stoppingCoach(aggregate.chat.id))
        XCTAssertEqual(state.coachInvocationStopAuthority, authority)
        XCTAssertEqual(
            Self.openAggregate(in: state)?.pendingUserTurn?.failure,
            nil,
            "an unreaped Invocation cannot fabricate a durable interruption"
        )
        let stopCount = await gateway.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testAdmissionRefreshCannotEraseAuthorityWhileUnreapableStopReturns()
        async throws
    {
        let aggregate = try Self.aggregate(
            draftText: "Keep exact Stop authority through admission refresh."
        )
        let gateway = AdmissionRefreshDuringUnreapableStopGateway()
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(aggregate)]),
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        async let sending: Void = feature.send(
            .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )
        let authority = await gateway.waitUntilInvocationIsSuspended()

        async let mayTerminate: Bool = feature.flushForOrderlyTermination()
        await gateway.waitUntilStopStarts()
        await gateway.finishInvocationAsStopped()
        await gateway.waitUntilAdmissionRefreshStarts()

        let refreshingState = await feature.currentState
        XCTAssertEqual(refreshingState.activity, .stoppingCoach(aggregate.chat.id))
        XCTAssertEqual(
            refreshingState.coachInvocationStopAuthority,
            authority,
            "the detached invocation's refresh must not erase in-flight Stop"
        )

        await gateway.resumeAdmissionRefresh()
        await sending
        let refreshedState = await feature.currentState
        XCTAssertEqual(refreshedState.coachInvocationStopAuthority, authority)
        XCTAssertEqual(refreshedState.activity, .stoppingCoach(aggregate.chat.id))

        await gateway.finishStopAsUnableToReap()
        let terminationAllowed = await mayTerminate

        XCTAssertFalse(terminationAllowed)
        let finalState = await feature.currentState
        XCTAssertEqual(finalState.activity, .stoppingCoach(aggregate.chat.id))
        XCTAssertEqual(finalState.coachInvocationStopAuthority, authority)
        XCTAssertNil(
            Self.openAggregate(in: finalState)?.pendingUserTurn?.failure
        )
    }

    func testUnreapedStopCanRetrySameAuthorityThenTerminationSucceeds()
        async throws
    {
        let aggregate = try Self.aggregate(
            draftText: "Retry exact reaping before orderly termination."
        )
        let gateway = RetryableUnreapedInvocationGateway()
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(aggregate)]),
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        async let sending: Void = feature.send(
            .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )
        let authority = await gateway.waitUntilInvocationIsSuspended()
        let stopCommand = ChatCommand.stopCoachResponse(Self.context, authority)

        await feature.send(stopCommand)
        let unreapedState = await feature.currentState
        XCTAssertEqual(unreapedState.coachInvocationStopAuthority, authority)
        XCTAssertEqual(unreapedState.activity, .stoppingCoach(aggregate.chat.id))

        await feature.send(stopCommand)
        await sending

        let reapedState = await feature.currentState
        XCTAssertNil(reapedState.coachInvocationStopAuthority)
        XCTAssertNil(reapedState.activity)
        XCTAssertEqual(
            Self.openAggregate(in: reapedState)?.pendingUserTurn?.failure,
            .coachResponseInterrupted
        )
        let stopCount = await gateway.stopCount
        XCTAssertEqual(stopCount, 2)
        let mayTerminate = await feature.flushForOrderlyTermination()
        XCTAssertTrue(mayTerminate)
    }

    func testOrderlyTerminationRetriesUnreapedStopAfterSupersedingChatContext()
        async throws
    {
        let aggregate = try Self.aggregate(
            draftText: "Keep the unreaped provider latched across Libraries."
        )
        let gateway = AdmissionRefreshDuringUnreapableStopGateway()
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(aggregate)]),
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        async let sending: Void = feature.send(
            .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )
        let authority = await gateway.waitUntilInvocationIsSuspended()
        async let stopping: Void = feature.send(
            .stopCoachResponse(Self.context, authority)
        )
        await gateway.waitUntilStopStarts()

        await feature.send(.start(Self.secondContext))
        await gateway.finishInvocationAsStopped()
        await gateway.waitUntilAdmissionRefreshStarts()
        await gateway.resumeAdmissionRefresh()
        await sending

        let oldContextState = await feature.currentState(in: Self.scope)
        let replacementContextState = await feature.currentState(
            in: Self.secondScope
        )
        XCTAssertNil(oldContextState)
        XCTAssertNotNil(replacementContextState)
        XCTAssertEqual(
            replacementContextState?.selection,
            ChatFeatureState.Selection.none
        )
        XCTAssertNil(replacementContextState?.coachInvocationStopAuthority)

        await gateway.finishStopAsUnableToReap()
        await stopping
        let terminationAllowed = await feature.flushForOrderlyTermination()

        XCTAssertTrue(
            terminationAllowed,
            "termination must retry the detached exact authority"
        )
        let stopCount = await gateway.stopCount
        XCTAssertEqual(stopCount, 2)
        let finalState = await feature.currentState
        XCTAssertEqual(finalState.selection, .none)
        XCTAssertNil(finalState.coachInvocationStopAuthority)
    }

    func testAutomaticTranscriptFailureRetainsDetachedReapAuthorityAcrossLibraryReplacement()
        async throws
    {
        let aggregate = try Self.aggregate(
            draftText: "Retain automatic transcript failure reaping."
        )
        let gateway = RetryableUnreapedInvocationGateway()
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(aggregate)]),
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        async let sending: Void = feature.send(
            .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )
        let authority = await gateway.waitUntilInvocationIsSuspended()

        await feature.send(.start(Self.secondContext))
        await gateway.finishInvocationAsProviderReapPending()
        await sending

        let replacementState = await feature.currentState
        XCTAssertEqual(replacementState.selection, .none)
        XCTAssertNil(replacementState.coachInvocationStopAuthority)

        let firstTermination = await feature.flushForOrderlyTermination()
        XCTAssertFalse(firstTermination)
        let secondTermination = await feature.flushForOrderlyTermination()
        XCTAssertTrue(secondTermination)

        let stopAuthorities = await gateway.stopAuthorities
        let stopRequests = await gateway.stopRequests
        XCTAssertEqual(stopAuthorities, [authority, authority])
        XCTAssertEqual(
            stopRequests,
            [
                StopCoachInvocationRequest(
                    library: authority.library,
                    chatID: authority.chatID,
                    pendingUserTurnID: authority.pendingUserTurnID
                ),
                StopCoachInvocationRequest(
                    library: authority.library,
                    chatID: authority.chatID,
                    pendingUserTurnID: authority.pendingUserTurnID
                ),
            ]
        )
        let invocationCount = await gateway.invocationCount
        XCTAssertEqual(invocationCount, 1)
    }

    func testRetryTranscriptFailureRetainsDetachedReapAuthorityAcrossLibraryReplacement()
        async throws
    {
        let aggregate = try Self.aggregate(
            draftText: "Retain Retry transcript failure reaping."
        )
        let failedPending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120000000Z-5KMN"),
            draftID: aggregate.chat.draft.draftID,
            draftVersion: aggregate.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120000000Z-6PQR"
            ),
            failure: .coachProviderError
        )
        let failedAggregate = try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            pendingUserTurn: failedPending
        )
        let gateway = RetryableUnreapedInvocationGateway(
            retryAggregate: failedAggregate
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(failedAggregate)]),
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, failedAggregate.chat.id))
        async let retrying: Void = feature.send(
            .retryPendingUserTurn(Self.context, failedPending.id)
        )
        let authority = await gateway.waitUntilInvocationIsSuspended()

        await feature.send(.start(Self.secondContext))
        await gateway.finishInvocationAsProviderReapPending()
        await retrying

        let firstTermination = await feature.flushForOrderlyTermination()
        let secondTermination = await feature.flushForOrderlyTermination()
        XCTAssertFalse(firstTermination)
        XCTAssertTrue(secondTermination)
        let stopAuthorities = await gateway.stopAuthorities
        XCTAssertEqual(stopAuthorities, [authority, authority])
        let invocationCount = await gateway.invocationCount
        XCTAssertEqual(invocationCount, 1)
    }

    func testReplacementLibraryCannotStartCoachUntilDetachedAuthorityIsReaped()
        async throws
    {
        let aggregate = try Self.aggregate(
            draftText: "Fence the next Library behind exact provider reaping."
        )
        let gateway = RetryableUnreapedInvocationGateway(
            suspendSecondReap: true
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(aggregate)]),
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        async let firstSending: Void = feature.send(
            .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )
        let firstAuthority = await gateway.waitUntilInvocationIsSuspended()

        await feature.send(
            .stopCoachResponse(Self.context, firstAuthority)
        )
        await firstSending
        await feature.send(.start(Self.secondContext))
        await feature.send(.open(Self.secondContext, aggregate.chat.id))
        async let successorSending: Void = feature.send(
            .sendDraft(
                Self.secondContext,
                aggregate.chat.id,
                aggregate.chat.draft
            )
        )

        await gateway.waitUntilSecondReapStarts()
        let launchesBeforeReap = await gateway.invocationCount
        XCTAssertEqual(
            launchesBeforeReap,
            1,
            "a replacement Library must not start a provider behind an unreaped process"
        )

        await gateway.resumeSecondReap()
        _ = await gateway.waitUntilInvocationCount(2)
        let launchesAfterReap = await gateway.invocationCount
        XCTAssertEqual(launchesAfterReap, 2)
        await gateway.finishInvocationAsStopped()
        await successorSending
    }

    func testSendLeavesDraftEditableWhenAnotherInvocationOwnsTheLibrary() async throws {
        let aggregate = try Self.aggregate(draftText: "Keep this Draft editable.")
        let store = RecordingChatStore(catalog: [.available(aggregate)])
        let gateway = BusyPreparingInvocationGateway()
        let feature = makeFeature(store: store, invocations: gateway)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))

        await feature.send(
            .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )

        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state), aggregate)
        XCTAssertEqual(state.composer, .editable(aggregate.chat.draft, isDirty: false))
        XCTAssertEqual(state.notice, .coachBusy)
        XCTAssertNil(state.activity)
        let locks = await store.pendingLocks
        XCTAssertEqual(locks, [])
    }

    func testSupersedingLibraryAbandonsPreparedPendingBeforeInvocationStarts() async throws {
        let aggregate = try Self.aggregate(draftText: "Do not outlive this Library.")
        let store = RecordingChatStore(catalog: [.available(aggregate)])
        let gateway = SuspendedPreparingInvocationGateway()
        let feature = makeFeature(store: store, invocations: gateway)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))

        async let send: Void = feature.send(
            .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )
        await gateway.waitUntilPreparationStarts()
        await feature.send(.start(Self.secondContext))
        await gateway.resumePreparation()
        await send

        let abandoned = await gateway.abandoned
        let invocationCount = await gateway.invocationCount
        let loadedScopes = await store.loadedScopes
        XCTAssertEqual(abandoned.count, 1)
        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(loadedScopes, [Self.scope, Self.secondScope])
    }

    func testOperationalInterruptionProjectsRetryForTheExactUnchangedPendingIntent() async throws {
        let aggregate = try Self.aggregate(draftText: "Retry this exact Draft.")
        let expectedPending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120000000Z-5KMN"),
            draftID: aggregate.chat.draft.draftID,
            draftVersion: aggregate.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120000000Z-6PQR"
            )
        )
        let staleGatewaySnapshot = try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            pendingUserTurn: expectedPending
        )
        let store = RecordingChatStore(catalog: [.available(aggregate)])
        let gateway = OperationallyInterruptedInvocationGateway(
            fallback: staleGatewaySnapshot
        )
        let feature = makeFeature(store: store, invocations: gateway)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))

        await feature.send(
            .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )

        let interruptedState = await feature.currentState
        guard case let .open(locked) = interruptedState.selection,
              let pending = locked.pendingUserTurn
        else { return XCTFail("the exact Pending must remain selected") }
        let expectedRequest = PendingCoachInvocationRequest(
            library: Self.scope,
            chatID: aggregate.chat.id,
            pendingUserTurnID: pending.id
        )
        XCTAssertNil(pending.failure, "the Application must not fake a durable write")
        XCTAssertEqual(
            interruptedState.operationallyInterruptedInvocation,
            expectedRequest
        )
        XCTAssertTrue(interruptedState.isCoachResponseInterrupted(pending))

        await feature.send(
            .rename(
                Self.context,
                aggregate.chat.id,
                title: "Renamed while Retry remains exact",
                expectedRevision: locked.chat.manifestRevision
            )
        )
        let renamedState = await feature.currentState
        XCTAssertEqual(
            renamedState.operationallyInterruptedInvocation,
            expectedRequest,
            "an unrelated authoritative rename does not resolve terminal uncertainty"
        )
        XCTAssertTrue(renamedState.isCoachResponseInterrupted(pending))

        await feature.send(.retryPendingUserTurn(Self.context, pending.id))

        let requests = await gateway.requests
        let retryState = await feature.currentState
        XCTAssertEqual(requests, [expectedRequest, expectedRequest])
        XCTAssertEqual(
            Self.openAggregate(in: retryState)?.chat.title,
            try ChatTitle("Renamed while Retry remains exact"),
            "an older operational fallback cannot regress newer Application state"
        )
    }

    func testOperationalRetryClearsTransientAuthorityWhileInvocationIsSuspended() async throws {
        let aggregate = try Self.aggregate(draftText: "Retry this uncertain Draft.")
        let gateway = OperationalInterruptionThenSuspendedRetryGateway()
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(aggregate)]),
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        await feature.send(
            .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )

        let interrupted = await feature.currentState
        guard case let .open(locked) = interrupted.selection,
              let pending = locked.pendingUserTurn,
              let interruption = interrupted.operationallyInterruptedInvocation
        else { return XCTFail("expected an operationally interrupted Pending") }
        XCTAssertTrue(interrupted.isCoachResponseRetryableFailure(pending))

        async let retry: Void = feature.send(
            .retryPendingUserTurn(Self.context, pending.id)
        )
        await gateway.waitUntilRetryIsSuspended()

        let processing = await feature.currentState
        XCTAssertNil(processing.operationallyInterruptedInvocation)
        XCTAssertEqual(
            Self.openAggregate(in: processing)?.pendingUserTurn,
            pending.replacingFailure(nil)
        )
        XCTAssertEqual(processing.activity, .invokingCoach(aggregate.chat.id))
        XCTAssertFalse(
            processing.isCoachResponseRetryableFailure(
                pending.replacingFailure(nil)
            )
        )

        await gateway.resume(
            with: .rejected(nil, .activeInvocation)
        )
        await retry

        let rejected = await feature.currentState
        XCTAssertEqual(rejected.operationallyInterruptedInvocation, interruption)
        XCTAssertEqual(
            Self.openAggregate(in: rejected)?.pendingUserTurn,
            pending
        )
        XCTAssertTrue(rejected.isCoachResponseRetryableFailure(pending))
        XCTAssertEqual(rejected.notice, .coachBusy)
    }

    func testOperationalRetryInterruptedWithoutSnapshotRestoresExactAuthorityAndFallback()
        async throws
    {
        let aggregate = try Self.aggregate(
            draftText: "Keep this uncertain Draft locked."
        )
        let gateway = OperationalInterruptionThenSuspendedRetryGateway()
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(aggregate)]),
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        await feature.send(
            .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )

        let interrupted = await feature.currentState
        guard case let .open(fallback) = interrupted.selection,
              let pending = fallback.pendingUserTurn,
              let authority = interrupted.operationallyInterruptedInvocation
        else { return XCTFail("expected the exact operational Retry authority") }

        async let retry: Void = feature.send(
            .retryPendingUserTurn(Self.context, pending.id)
        )
        await gateway.waitUntilRetryIsSuspended()
        await gateway.resume(
            with: .interrupted(nil, .persistenceUnavailable)
        )
        await retry

        let state = await feature.currentState
        XCTAssertEqual(state.selection, .open(fallback))
        XCTAssertEqual(
            state.composer,
            .locked(fallback.chat.draft, pending)
        )
        XCTAssertEqual(state.operationallyInterruptedInvocation, authority)
        XCTAssertTrue(state.isCoachResponseRetryableFailure(pending))
        XCTAssertEqual(state.notice, .coachResponseInterrupted)
        XCTAssertNil(state.activity)
    }

    func testOperationalRetryRestoresAuthorityFromFailureFreeRejectedCurrent() async throws {
        let aggregate = try Self.aggregate(draftText: "Retry this returned current Draft.")
        let gateway = OperationalInterruptionThenSuspendedRetryGateway()
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(aggregate)]),
            invocations: gateway
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        await feature.send(
            .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )

        let interrupted = await feature.currentState
        guard case let .open(locked) = interrupted.selection,
              let pending = locked.pendingUserTurn,
              let interruption = interrupted.operationallyInterruptedInvocation
        else { return XCTFail("expected an operationally interrupted Pending") }

        async let retry: Void = feature.send(
            .retryPendingUserTurn(Self.context, pending.id)
        )
        await gateway.waitUntilRetryIsSuspended()
        let processing = await feature.currentState
        let processingAggregate = try XCTUnwrap(
            Self.openAggregate(in: processing)
        )

        await gateway.resume(
            with: .rejected(processingAggregate, .persistenceUnavailable)
        )
        await retry

        let rejected = await feature.currentState
        XCTAssertEqual(rejected.selection, .open(processingAggregate))
        XCTAssertEqual(rejected.operationallyInterruptedInvocation, interruption)
        XCTAssertTrue(rejected.isCoachResponseRetryableFailure(pending))
        XCTAssertEqual(rejected.notice, .coachRetryUnavailable)
        XCTAssertNil(rejected.activity)
    }

    func testTypedProviderFailuresRemainRetryableCoachResponseFailures() throws {
        let transcriptFailure = PendingUserTurnFailure.coachTranscriptReadFailed(
            try CoachTranscriptReadFailureSummary(
                sessions: [
                    CoachTranscriptReadFailureSession(
                        sessionAttachmentID: try ChatSessionAttachmentID(
                            "attachment-1"
                        ),
                        displayLabel: "Opening practice"
                    ),
                ],
                additionalSessionCount: 0
            )
        )
        for failure in [
            PendingUserTurnFailure.coachProviderError,
            .coachResponseInvalid,
            .coachResponseInterrupted,
            transcriptFailure,
        ] {
            let pending = PendingUserTurn(
                id: try PendingUserTurnID("ptu-20260830T120000000Z-5KMN"),
                draftID: try ChatDraftID("drf-20260830T120000000Z-4GHJ"),
                draftVersion: 1,
                responsePositionID: try ChatResponsePositionID(
                    "rsp-20260830T120000000Z-6PQR"
                ),
                failure: failure
            )
            XCTAssertTrue(
                ChatFeatureState().isCoachResponseRetryableFailure(pending),
                failure.rawValue
            )
        }
    }

    func testTypedInvocationFailureCardSuppressesRedundantInterruptionNotice() async throws {
        for (failure, reason) in [
            (
                PendingUserTurnFailure.coachProviderError,
                InvocationInterruptionReason.providerFailed
            ),
            (
                PendingUserTurnFailure.coachResponseInvalid,
                InvocationInterruptionReason.invalidProviderResponse
            ),
        ] {
            let aggregate = try Self.aggregate(
                draftText: "Keep this synthetic Draft locked."
            )
            let store = RecordingChatStore(catalog: [.available(aggregate)])
            let gateway = TypedTerminalInvocationGateway(
                failure: failure,
                reason: reason
            )
            let feature = makeFeature(store: store, invocations: gateway)
            await feature.send(.start(Self.context))
            await feature.send(.open(Self.context, aggregate.chat.id))

            await feature.send(
                .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
            )

            let state = await feature.currentState
            XCTAssertEqual(
                Self.openAggregate(in: state)?.pendingUserTurn?.failure,
                failure,
                failure.rawValue
            )
            XCTAssertNil(
                state.notice,
                "the authoritative \(failure.rawValue) card must not be contradicted"
            )
        }
    }

    func testGenericInterruptionStillProjectsInterruptionNotice() async throws {
        let aggregate = try Self.aggregate(
            draftText: "Keep this interrupted synthetic Draft locked."
        )
        let store = RecordingChatStore(catalog: [.available(aggregate)])
        let gateway = TypedTerminalInvocationGateway(
            failure: .coachResponseInterrupted,
            reason: .persistenceUnavailable
        )
        let feature = makeFeature(store: store, invocations: gateway)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))

        await feature.send(
            .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )

        let state = await feature.currentState
        XCTAssertEqual(
            Self.openAggregate(in: state)?.pendingUserTurn?.failure,
            .coachResponseInterrupted
        )
        XCTAssertEqual(state.notice, .coachResponseInterrupted)
    }

    func testOperationalRetryClearsItsProjectionWhenThePendingHasVanished() async throws {
        let aggregate = try Self.aggregate(draftText: "Retry this exact Draft.")
        let store = RecordingChatStore(
            catalog: [.available(aggregate)],
            loadOutcomes: [.loaded(aggregate), .missing]
        )
        let gateway = VanishingOperationalRetryInvocationGateway()
        let feature = makeFeature(store: store, invocations: gateway)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        await feature.send(
            .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )

        guard case let .open(locked) = await feature.currentState.selection,
              let pending = locked.pendingUserTurn
        else { return XCTFail("the first interruption must retain the exact Pending") }

        await feature.send(.retryPendingUserTurn(Self.context, pending.id))

        let refreshed = await feature.currentState
        XCTAssertNil(refreshed.operationallyInterruptedInvocation)
        XCTAssertEqual(refreshed.selection, .none)
        XCTAssertNil(refreshed.composer)
        XCTAssertEqual(refreshed.notice, .chatMissing)

        await feature.send(.retryPendingUserTurn(Self.context, pending.id))
        let requests = await gateway.requests
        XCTAssertEqual(requests.count, 2, "a vanished Pending cannot retain Retry authority")
    }

    func testCanceledAutosaveReconciliationNeverClearsSendLockingActivity() async throws {
        let aggregate = try Self.aggregate()
        let store = RecordingChatStore(
            catalog: [.available(aggregate)],
            suspendNextDraftSave: true
        )
        let scheduler = ControlledChatAutosaveScheduler()
        let pendingIDs = SuspendedPendingUserTurnIDGenerator()
        let feature = makeFeature(
            store: store,
            pendingUserTurnIDGenerator: pendingIDs,
            autosaveScheduler: scheduler
        )
        let recorder = ChatStateRecorder()
        let collector = Task {
            for await state in feature.states {
                await recorder.append(state)
            }
        }
        await recorder.waitForStateCount(1)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        await feature.send(
            .editDraft(
                Self.context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: "Lock this exact Draft."
            )
        )
        await scheduler.waitUntilScheduled()
        await scheduler.resume()
        await store.waitUntilDraftSaveStarts()
        let expectedDraft = try await Self.editableDraft(in: feature)

        async let send: Void = feature.send(
            .sendDraft(Self.context, aggregate.chat.id, expectedDraft)
        )
        await recorder.waitUntilActivity(.lockingDraft(aggregate.chat.id))
        await store.resumeDraftSave()
        await pendingIDs.waitUntilRequested()

        let activities = await recorder.activitiesAfterFirst(
            .lockingDraft(aggregate.chat.id)
        )
        XCTAssertFalse(activities.contains(nil), "Send transiently became editable")

        await pendingIDs.resume()
        await send
        collector.cancel()
    }

    func testCanceledFailedAutosaveNeverClearsSendLockingActivity() async throws {
        let aggregate = try Self.aggregate()
        let store = RecordingChatStore(
            catalog: [.available(aggregate)],
            draftSaveOutcomes: [.failed],
            suspendNextDraftSave: true
        )
        let scheduler = ControlledChatAutosaveScheduler()
        let pendingIDs = SuspendedPendingUserTurnIDGenerator()
        let feature = makeFeature(
            store: store,
            pendingUserTurnIDGenerator: pendingIDs,
            autosaveScheduler: scheduler
        )
        let recorder = ChatStateRecorder()
        let collector = Task {
            for await state in feature.states {
                await recorder.append(state)
            }
        }
        await recorder.waitForStateCount(1)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        await feature.send(
            .editDraft(
                Self.context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: "Lock this Draft after the failed autosave."
            )
        )
        await scheduler.waitUntilScheduled()
        await scheduler.resume()
        await store.waitUntilDraftSaveStarts()
        let expectedDraft = try await Self.editableDraft(in: feature)

        async let send: Void = feature.send(
            .sendDraft(Self.context, aggregate.chat.id, expectedDraft)
        )
        await recorder.waitUntilActivity(.lockingDraft(aggregate.chat.id))
        await store.resumeDraftSave()
        await pendingIDs.waitUntilRequested()

        let activities = await recorder.activitiesAfterFirst(
            .lockingDraft(aggregate.chat.id)
        )
        XCTAssertFalse(activities.contains(nil), "Send transiently became editable")
        let saved = await store.savedDrafts
        XCTAssertEqual(saved.count, 2, "foreground Send must retry the canceled autosave")

        await pendingIDs.resume()
        await send
        collector.cancel()
    }

    func testCanceledAutosaveStalePendingEndsSendWithNoActiveCommand() async throws {
        let aggregate = try Self.aggregate()
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120001000Z-5KMN"),
            draftID: aggregate.chat.draft.draftID,
            draftVersion: 1,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120001000Z-6PQR"
            )
        )
        let externallyLockedDraft = try aggregate.chat.draft.edited(
            text: "Already locked elsewhere.",
            at: UTCInstant("2026-08-30T12:00:01.000Z")
        )
        let externallyLocked = try ChatAggregate(
            chat: aggregate.chat.replacingDraft(with: externallyLockedDraft),
            memory: aggregate.memory,
            pendingUserTurn: pending
        )
        let store = RecordingChatStore(
            catalog: [.available(aggregate)],
            draftSaveOutcomes: [.stale(externallyLocked)],
            suspendNextDraftSave: true
        )
        let scheduler = ControlledChatAutosaveScheduler()
        let feature = makeFeature(store: store, autosaveScheduler: scheduler)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        await feature.send(
            .editDraft(
                Self.context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: "Attempt to send this Draft."
            )
        )
        await scheduler.waitUntilScheduled()
        await scheduler.resume()
        await store.waitUntilDraftSaveStarts()
        let expectedDraft = try await Self.editableDraft(in: feature)

        async let send: Void = feature.send(
            .sendDraft(Self.context, aggregate.chat.id, expectedDraft)
        )
        while await feature.currentState.activity != .lockingDraft(aggregate.chat.id) {
            await Task.yield()
        }
        await store.resumeDraftSave()
        await send

        let state = await feature.currentState
        guard case let .locked(draft, installedPending) = state.composer else {
            return XCTFail("expected the externally locked Draft")
        }
        XCTAssertEqual(draft, externallyLockedDraft)
        XCTAssertEqual(installedPending, pending)
        XCTAssertNil(state.activity)
    }

    func testSendNeverLocksANewerSameIdentityDraftFromStaleAutosave() async throws {
        let aggregate = try Self.aggregate()
        let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
        let capturedDraft = try aggregate.chat.draft.edited(
            text: "Send this exact Draft.",
            at: instant
        )
        let concurrentDraft = try capturedDraft.edited(
            text: "Changed by another writer.",
            at: instant
        )
        let concurrent = try ChatAggregate(
            chat: aggregate.chat.replacingDraft(with: concurrentDraft),
            memory: aggregate.memory
        )
        let store = RecordingChatStore(
            catalog: [.available(aggregate)],
            draftSaveOutcomes: [.stale(concurrent)],
            suspendNextDraftSave: true
        )
        let scheduler = ControlledChatAutosaveScheduler()
        let feature = makeFeature(store: store, autosaveScheduler: scheduler)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        await feature.send(
            .editDraft(
                Self.context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: capturedDraft.text
            )
        )
        await scheduler.waitUntilScheduled()
        await scheduler.resume()
        await store.waitUntilDraftSaveStarts()

        async let send: Void = feature.send(
            .sendDraft(Self.context, aggregate.chat.id, capturedDraft)
        )
        while await feature.currentState.activity != .lockingDraft(aggregate.chat.id) {
            await Task.yield()
        }
        await store.resumeDraftSave()
        await send

        let pendingLocks = await store.pendingLocks
        XCTAssertTrue(pendingLocks.isEmpty, "Send must not rebind to a newer Draft version")
        let state = await feature.currentState
        guard case let .editable(draft, false) = state.composer else {
            return XCTFail("expected the concurrent Draft as clean recovery state")
        }
        XCTAssertEqual(draft, concurrentDraft)
        XCTAssertEqual(state.notice, .draftChanged)
        XCTAssertNil(state.activity)
    }

    func testOpenRefusesCanceledAutosaveConflictAndKeepsRecoveryVisible() async throws {
        let first = try Self.aggregate()
        let second = try Self.aggregate(
            chat: "cht-20260830T120100000Z-5KMN",
            draft: "drf-20260830T120100000Z-6PQR",
            memory: "mem-20260830T120100000Z-7STV",
            title: "Second Chat"
        )
        let externallyLockedDraft = try first.chat.draft.edited(
            text: "Locked by another writer.",
            at: UTCInstant("2026-08-30T12:00:01.000Z")
        )
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120001000Z-5KMN"),
            draftID: externallyLockedDraft.draftID,
            draftVersion: externallyLockedDraft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120001000Z-6PQR"
            )
        )
        let externallyLocked = try ChatAggregate(
            chat: first.chat.replacingDraft(with: externallyLockedDraft),
            memory: first.memory,
            pendingUserTurn: pending
        )
        let store = RecordingChatStore(
            catalog: [.available(first), .available(second)],
            draftSaveOutcomes: [.stale(externallyLocked)],
            suspendNextDraftSave: true
        )
        let scheduler = ControlledChatAutosaveScheduler()
        let feature = makeFeature(store: store, autosaveScheduler: scheduler)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, first.chat.id))
        await feature.send(
            .editDraft(
                Self.context,
                first.chat.id,
                first.chat.draft.draftID,
                text: "Do not hide this conflict."
            )
        )
        await scheduler.waitUntilScheduled()
        await scheduler.resume()
        await store.waitUntilDraftSaveStarts()

        async let open: Void = feature.send(.open(Self.context, second.chat.id))
        await store.resumeDraftSave()
        await open

        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state), externallyLocked)
        XCTAssertEqual(state.composer, .locked(externallyLockedDraft, pending))
        XCTAssertEqual(state.notice, .draftChanged)
        let calls = await store.calls
        XCTAssertEqual(calls, [.loadCatalog, .load, .saveDraft])
    }

    func testDiscardUnlocksTheSamePopulatedDraftWithoutAbandonmentHistory() async throws {
        let aggregate = try Self.aggregate()
        let store = RecordingChatStore(catalog: [.available(aggregate)])
        let scheduler = ControlledChatAutosaveScheduler()
        let feature = makeFeature(store: store, autosaveScheduler: scheduler)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        await feature.send(
            .editDraft(
                Self.context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: "Do not abandon this Draft."
            )
        )
        await scheduler.waitUntilScheduled()
        let expectedDraft = try await Self.editableDraft(in: feature)
        await feature.send(
            .sendDraft(Self.context, aggregate.chat.id, expectedDraft)
        )
        let lockedState = await feature.currentState
        guard case let .locked(_, pending) = lockedState.composer else {
            return XCTFail("expected locked Draft")
        }

        await feature.send(.discardPendingUserTurn(Self.context, pending.id))

        let state = await feature.currentState
        guard case let .open(unlocked) = state.selection,
              case let .editable(draft, isDirty) = state.composer
        else {
            return XCTFail("expected unlocked Draft")
        }
        XCTAssertFalse(isDirty)
        XCTAssertEqual(draft.text, "Do not abandon this Draft.")
        XCTAssertNil(unlocked.pendingUserTurn)
        XCTAssertEqual(unlocked.chat.messageIDs, [])
    }

    func testNavigationCancelsTimerButFlushesFinalDirtyVersionBeforeOpeningNextChat() async throws {
        let first = try Self.aggregate()
        let second = try Self.aggregate(
            chat: "cht-20260830T120100000Z-5KMN",
            draft: "drf-20260830T120100000Z-6PQR",
            memory: "mem-20260830T120100000Z-7STV",
            title: "Second Chat"
        )
        let store = RecordingChatStore(catalog: [.available(first), .available(second)])
        let scheduler = ControlledChatAutosaveScheduler()
        let feature = makeFeature(store: store, autosaveScheduler: scheduler)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, first.chat.id))
        await feature.send(
            .editDraft(
                Self.context,
                first.chat.id,
                first.chat.draft.draftID,
                text: "Flush me before navigation."
            )
        )
        await scheduler.waitUntilScheduled()

        await feature.send(.open(Self.context, second.chat.id))

        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state)?.chat.id, second.chat.id)
        let savedDrafts = await store.savedDrafts
        XCTAssertEqual(savedDrafts.map(\.replacement.text), ["Flush me before navigation."])
        let calls = await store.calls
        XCTAssertEqual(calls, [.loadCatalog, .load, .saveDraft, .load])
    }

    func testLibrarySwitchDrainsStartedAutosaveBeforeAuthorityChangesAndFencesOldContext() async throws {
        let aggregate = try Self.aggregate()
        let store = RecordingChatStore(
            catalog: [.available(aggregate)],
            suspendNextDraftSave: true
        )
        let scheduler = ControlledChatAutosaveScheduler()
        let feature = makeFeature(store: store, autosaveScheduler: scheduler)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        await feature.send(
            .editDraft(
                Self.context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: "Library A durable text"
            )
        )
        await scheduler.waitUntilScheduled()
        await scheduler.resume()
        await store.waitUntilDraftSaveStarts()

        async let switchToB: Void = feature.send(.start(Self.secondContext))
        await Task.yield()

        let stateWhileSaveIsPending = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: stateWhileSaveIsPending)?.chat.id,
                       aggregate.chat.id)
        let oldScopedState = await feature.currentState(in: Self.scope)
        let prematureNewState = await feature.currentState(in: Self.secondScope)
        let loadedBeforeResume = await store.loadedScopes
        XCTAssertNotNil(oldScopedState)
        XCTAssertNil(prematureNewState)
        XCTAssertEqual(loadedBeforeResume, [Self.scope])

        await store.resumeDraftSave()
        await switchToB
        let loadedAfterResume = await store.loadedScopes
        XCTAssertEqual(loadedAfterResume, [Self.scope, Self.secondScope])

        let returnedContext = ChatCommandContext(
            libraryScope: Self.scope,
            generation: 3
        )
        await feature.send(.start(returnedContext))
        await feature.send(.open(returnedContext, aggregate.chat.id))
        await feature.send(
            .editDraft(
                Self.context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: "stale model must be ignored"
            )
        )

        let reopened = await feature.currentState
        guard case let .editable(reopenedDraft, _) = reopened.composer else {
            return XCTFail("expected reopened editable Draft")
        }
        XCTAssertEqual(reopenedDraft.text, "Library A durable text")
        let saveCount = await store.savedDrafts.count
        XCTAssertEqual(saveCount, 1)
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

    func testOpenProfileProposalBlocksDraftEditingAndCoachSend() async throws {
        let aggregate = try Self.aggregateWithProfileProposal(
            draftText: "Do not send while this decision is unresolved."
        )
        let store = RecordingChatStore(catalog: [.available(aggregate)])
        let invocations = RecordingInterruptedInvocationGateway()
        let feature = makeFeature(store: store, invocations: invocations)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))

        let opened = await feature.currentState
        XCTAssertFalse(ChatInteractionPolicy.allowsComposerEditing(in: opened))
        XCTAssertFalse(ChatInteractionPolicy.allowsCoachInvocation(in: opened))

        await feature.send(
            .editDraft(
                Self.context,
                aggregate.chat.id,
                aggregate.chat.draft.draftID,
                text: "This edit must be ignored."
            )
        )
        await feature.send(
            .sendDraft(Self.context, aggregate.chat.id, aggregate.chat.draft)
        )

        let terminal = await feature.currentState
        let savedDraftCount = await store.savedDrafts.count
        let preparationCount = await invocations.preparations.count
        let invocationCount = await invocations.requests.count
        XCTAssertEqual(Self.openAggregate(in: terminal), aggregate)
        XCTAssertEqual(terminal.composer, .editable(aggregate.chat.draft, isDirty: false))
        XCTAssertEqual(savedDraftCount, 0)
        XCTAssertEqual(preparationCount, 0)
        XCTAssertEqual(invocationCount, 0)
    }

    func testOpenAssessesExactProfileEffectBeforeExposingCurrentReviewActions()
        async throws
    {
        let aggregate = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(aggregate.profileProposal)
        let coordinator = RecordingProfileProposalCoordinator()
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(aggregate)]),
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))

        await feature.send(.open(Self.context, aggregate.chat.id))

        let requests = await coordinator.assessmentRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.library, Self.scope)
        XCTAssertEqual(requests.first?.base, aggregate)
        XCTAssertEqual(
            requests.first?.sourceEffectIdentity,
            .proposal(proposal.id)
        )
        let state = await feature.currentState
        XCTAssertEqual(
            state.profileEffectReview,
            .current(.proposal(proposal.id))
        )
        XCTAssertFalse(
            ChatInteractionPolicy.allowsProfileReconsideration(in: state)
        )
    }

    func testStaleProfileEffectOffersReconsiderNotAcceptAndKeepsDiscard()
        async throws
    {
        let aggregate = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(aggregate.profileProposal)
        let basis = try ProfileReconsiderationBasis(
            sourceEffect: .proposal(proposal),
            baseProfile: ProfileSnapshot(nullAtStatementGeneration: 7),
            latestProfile: ProfileSnapshot(nullAtStatementGeneration: 8)
        )
        let resolved = try Self.resolvingProfileProposal(in: aggregate)
        let coordinator = RecordingProfileProposalCoordinator(
            assessmentOutcomes: [.stale(aggregate, basis)],
            discardOutcomes: [.committed(resolved)]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(aggregate)]),
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))

        let stale = await feature.currentState
        XCTAssertEqual(stale.profileEffectReview, .stale(basis))
        XCTAssertTrue(
            ChatInteractionPolicy.allowsProfileReconsideration(in: stale)
        )

        await feature.send(.acceptProfileProposal(Self.context, proposal.id))
        let acceptedCount = await coordinator.acceptMutations.count
        XCTAssertEqual(acceptedCount, 0)

        await feature.send(.discardProfileProposal(Self.context, proposal.id))
        let discardedCount = await coordinator.discardMutations.count
        XCTAssertEqual(discardedCount, 1)
        let discarded = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: discarded), resolved)
        XCTAssertNil(discarded.profileEffectReview)
    }

    func testReconsiderStaleProfileEffectPreparesExactIntentAndInstallsReviewedReplacement()
        async throws
    {
        let source = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(source.profileProposal)
        let basis = try Self.staleReconsiderationBasis(for: source)
        let processing = try Self.installingProfileReconsideration(in: source)
        let reconsideration = try XCTUnwrap(processing.profileReconsideration)
        let completedAt = try UTCInstant("2026-09-09T12:10:00.000Z")
        let replacement = try ProfileChangeProposal.reconsidered(
            id: ProfileChangeProposalID(
                "prp-20260909T121000000Z-1ABC"
            ),
            basis: basis,
            responsePositionID: reconsideration.resultResponsePositionID,
            changes: [
                .add(
                    statement: ProfileProposedStatement(
                        statementID: ProfileStatementID(
                            "stm-20260909T121000000Z-2DEF"
                        ),
                        statementKind: .goal,
                        wording: "Lead with the main point before adding detail.",
                        evidence: []
                    )
                ),
            ],
            createdAt: completedAt
        )
        let coachMessage = try ChatMessage(
            id: ChatMessageID("msg-20260909T121000000Z-3GHJ"),
            responsePositionID: reconsideration.resultResponsePositionID,
            content: .coach(markdown: "I reconsidered that suggestion."),
            coachProfile: basis.latestProfile.provenance,
            createdAt: completedAt
        )
        let published = try processing.publishingReconsideration(
            expected: reconsideration,
            basis: basis,
            preparedProfile: basis.latestProfile.provenance,
            coachMessage: coachMessage,
            outcome: .replacement(replacement),
            at: completedAt
        )
        let gateway = RecordingProfileReconsiderationInvocationGateway(
            outcome: .published(published, try await Self.quote(for: source))
        )
        let coordinator = RecordingProfileProposalCoordinator(
            assessmentOutcomes: [
                .stale(source, basis),
                .stale(source, basis),
            ]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(source)]),
            invocations: gateway,
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, source.chat.id))

        await feature.send(
            .reconsiderProfileEffect(Self.context, .proposal(proposal.id))
        )

        let requests = await gateway.newRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.library, Self.scope)
        XCTAssertEqual(requests.first?.observedAggregate, source)
        XCTAssertEqual(requests.first?.basis, basis)
        XCTAssertEqual(
            requests.first?.reconsideration.sourceEffectIdentity,
            .proposal(proposal.id)
        )
        XCTAssertEqual(
            requests.first?.reconsideration.resultResponsePositionID,
            reconsideration.resultResponsePositionID
        )
        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state), published)
        XCTAssertNil(Self.openAggregate(in: state)?.profileReconsideration)
        XCTAssertEqual(
            state.profileEffectReview,
            .current(.proposal(replacement.id))
        )
        XCTAssertNil(state.activity)
        XCTAssertNil(state.notice)
    }

    func testWithdrawnReconsiderationShowsOnlyExactTenSecondTransientNotice()
        async throws
    {
        let source = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(source.profileProposal)
        let basis = try Self.staleReconsiderationBasis(for: source)
        let processing = try Self.installingProfileReconsideration(in: source)
        let reconsideration = try XCTUnwrap(processing.profileReconsideration)
        let completedAt = try UTCInstant("2026-09-09T12:20:00.000Z")
        let withdrawn = try processing.publishingReconsideration(
            expected: reconsideration,
            basis: basis,
            preparedProfile: basis.latestProfile.provenance,
            coachMessage: nil,
            outcome: .withdrawal,
            at: completedAt
        )
        let gateway = RecordingProfileReconsiderationInvocationGateway(
            outcome: .withdrawn(withdrawn, try await Self.quote(for: source))
        )
        let coordinator = RecordingProfileProposalCoordinator(
            assessmentOutcomes: [
                .stale(source, basis),
                .stale(source, basis),
            ]
        )
        let noticeScheduler = ControlledChatTransientNoticeScheduler()
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(source)]),
            transientNoticeScheduler: noticeScheduler,
            invocations: gateway,
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, source.chat.id))

        await feature.send(
            .reconsiderProfileEffect(Self.context, .proposal(proposal.id))
        )
        await noticeScheduler.waitUntilScheduled()

        let visible = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: visible), withdrawn)
        XCTAssertNil(Self.openAggregate(in: visible)?.profileEffect)
        XCTAssertNil(Self.openAggregate(in: visible)?.profileReconsideration)
        XCTAssertNil(visible.profileEffectReview)
        XCTAssertEqual(
            visible.transientNotice,
            .suggestionNoLongerRelevant
        )
        let durations = await noticeScheduler.requestedNanoseconds
        XCTAssertEqual(durations, [10_000_000_000])

        await noticeScheduler.resume()
        while await feature.currentState.transientNotice != nil {
            await Task.yield()
        }
        let cleared = await feature.currentState
        XCTAssertNil(cleared.transientNotice)
    }

    func testWithdrawnReconsiderationNoticeExpiresAfterMissingNavigation()
        async throws
    {
        let source = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(source.profileProposal)
        let basis = try Self.staleReconsiderationBasis(for: source)
        let processing = try Self.installingProfileReconsideration(in: source)
        let reconsideration = try XCTUnwrap(processing.profileReconsideration)
        let withdrawn = try processing.publishingReconsideration(
            expected: reconsideration,
            basis: basis,
            preparedProfile: basis.latestProfile.provenance,
            coachMessage: nil,
            outcome: .withdrawal,
            at: UTCInstant("2026-09-09T12:20:00.000Z")
        )
        let gateway = RecordingProfileReconsiderationInvocationGateway(
            outcome: .withdrawn(withdrawn, try await Self.quote(for: source))
        )
        let coordinator = RecordingProfileProposalCoordinator(
            assessmentOutcomes: [
                .stale(source, basis),
                .stale(source, basis),
            ]
        )
        let noticeScheduler = ControlledChatTransientNoticeScheduler()
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(source)]),
            transientNoticeScheduler: noticeScheduler,
            invocations: gateway,
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, source.chat.id))
        await feature.send(
            .reconsiderProfileEffect(Self.context, .proposal(proposal.id))
        )
        await noticeScheduler.waitUntilScheduled()

        let missingID = try ChatID("cht-20260909T122100000Z-1ABC")
        await feature.send(.open(Self.context, missingID))
        let navigating = await feature.currentState
        XCTAssertEqual(
            navigating.transientNotice,
            .suggestionNoLongerRelevant
        )

        await noticeScheduler.resume()
        for _ in 0 ..< 1_000 {
            if await feature.currentState.transientNotice == nil { break }
            await Task.yield()
        }
        let cleared = await feature.currentState
        XCTAssertNil(cleared.transientNotice)
        XCTAssertEqual(cleared.selection, .none)
        XCTAssertEqual(cleared.notice, .chatMissing)
    }

    func testProviderFailureRetainsExactReconsiderationAsRetryable()
        async throws
    {
        let source = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(source.profileProposal)
        let basis = try Self.staleReconsiderationBasis(for: source)
        let processing = try Self.installingProfileReconsideration(in: source)
        let reconsideration = try XCTUnwrap(processing.profileReconsideration)
        let failed = try Self.replacingProfileReconsideration(
            in: processing,
            with: reconsideration.replacingFailure(.coachProviderError)
        )
        let gateway = RecordingProfileReconsiderationInvocationGateway(
            outcome: .interrupted(failed, .providerFailed)
        )
        let coordinator = RecordingProfileProposalCoordinator(
            assessmentOutcomes: [
                .stale(source, basis),
                .stale(source, basis),
                .stale(failed, basis),
            ]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(source)]),
            invocations: gateway,
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, source.chat.id))

        await feature.send(
            .reconsiderProfileEffect(Self.context, .proposal(proposal.id))
        )

        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state), failed)
        XCTAssertEqual(
            Self.openAggregate(in: state)?.profileEffect,
            source.profileEffect
        )
        let retained = try XCTUnwrap(
            Self.openAggregate(in: state)?.profileReconsideration
        )
        XCTAssertEqual(retained, failed.profileReconsideration)
        XCTAssertTrue(state.isProfileReconsiderationRetryableFailure(retained))
        XCTAssertEqual(state.profileEffectReview, .stale(basis))
        XCTAssertNil(state.activity)
    }

    func testFailureFreeOperationalInterruptionRetriesOnlyItsExactLiveRequest()
        async throws
    {
        let source = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(source.profileProposal)
        let sourceIdentity = ChatProfileEffectIdentity.proposal(proposal.id)
        let basis = try Self.staleReconsiderationBasis(for: source)
        let processing = try Self.installingProfileReconsideration(in: source)
        let reconsideration = try XCTUnwrap(processing.profileReconsideration)
        let request = ProfileReconsiderationInvocationRequest(
            library: Self.scope,
            chatID: source.chat.id,
            sourceEffectIdentity: sourceIdentity,
            resultResponsePositionID: reconsideration.resultResponsePositionID
        )
        let completedAt = try UTCInstant("2026-09-09T12:25:00.000Z")
        let withdrawn = try processing.publishingReconsideration(
            expected: reconsideration,
            basis: basis,
            preparedProfile: basis.latestProfile.provenance,
            coachMessage: nil,
            outcome: .withdrawal,
            at: completedAt
        )
        let quote = try await Self.quote(for: source)
        let gateway = RecordingProfileReconsiderationInvocationGateway(
            outcome: .operationallyInterrupted(
                processing,
                request,
                .persistenceUnavailable
            ),
            operationalOutcome: .withdrawn(withdrawn, quote)
        )
        let coordinator = RecordingProfileProposalCoordinator(
            assessmentOutcomes: [
                .stale(source, basis),
                .stale(source, basis),
                .stale(processing, basis),
            ]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(source)]),
            invocations: gateway,
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, source.chat.id))
        await feature.send(
            .reconsiderProfileEffect(Self.context, sourceIdentity)
        )

        let interrupted = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: interrupted), processing)
        XCTAssertEqual(
            interrupted.operationallyInterruptedProfileReconsideration,
            request
        )
        XCTAssertTrue(
            interrupted.isProfileReconsiderationRetryableFailure(
                reconsideration
            )
        )

        await feature.send(
            .retryProfileReconsideration(Self.context, sourceIdentity)
        )

        let operationalRequests = await gateway.operationalRequests
        XCTAssertEqual(operationalRequests, [request])
        let newRequests = await gateway.newRequests
        XCTAssertEqual(newRequests.count, 1)
        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state), withdrawn)
        XCTAssertNil(
            state.operationallyInterruptedProfileReconsideration
        )
        XCTAssertNil(Self.openAggregate(in: state)?.profileReconsideration)
        XCTAssertNil(state.activity)
    }

    func testOperationalReconsiderationRetrySurvivesNavigationAwayAndBack()
        async throws
    {
        let source = try Self.aggregateWithProfileProposal()
        let other = try Self.aggregate(
            chat: "cht-20260909T122600000Z-1ABC",
            draft: "drf-20260909T122600000Z-2DEF",
            memory: "mem-20260909T122600000Z-3GHJ",
            title: "Other Chat"
        )
        let proposal = try XCTUnwrap(source.profileProposal)
        let sourceIdentity = ChatProfileEffectIdentity.proposal(proposal.id)
        let basis = try Self.staleReconsiderationBasis(for: source)
        let processing = try Self.installingProfileReconsideration(in: source)
        let reconsideration = try XCTUnwrap(processing.profileReconsideration)
        let request = ProfileReconsiderationInvocationRequest(
            library: Self.scope,
            chatID: source.chat.id,
            sourceEffectIdentity: sourceIdentity,
            resultResponsePositionID: reconsideration.resultResponsePositionID
        )
        let withdrawn = try processing.publishingReconsideration(
            expected: reconsideration,
            basis: basis,
            preparedProfile: basis.latestProfile.provenance,
            coachMessage: nil,
            outcome: .withdrawal,
            at: UTCInstant("2026-09-09T12:27:00.000Z")
        )
        let gateway = RecordingProfileReconsiderationInvocationGateway(
            outcome: .operationallyInterrupted(
                processing,
                request,
                .persistenceUnavailable
            ),
            operationalOutcome: .withdrawn(
                withdrawn,
                try await Self.quote(for: source)
            )
        )
        let coordinator = RecordingProfileProposalCoordinator(
            assessmentOutcomes: [
                .stale(source, basis),
                .stale(source, basis),
                .stale(processing, basis),
                .stale(processing, basis),
            ]
        )
        let store = RecordingChatStore(
            catalog: [.available(source), .available(other)],
            loadOutcomes: [
                .loaded(source),
                .loaded(other),
                .loaded(processing),
            ]
        )
        let feature = makeFeature(
            store: store,
            invocations: gateway,
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, source.chat.id))
        await feature.send(
            .reconsiderProfileEffect(Self.context, sourceIdentity)
        )

        await feature.send(.open(Self.context, other.chat.id))
        let otherState = await feature.currentState
        XCTAssertNil(
            otherState.operationallyInterruptedProfileReconsideration
        )
        await feature.send(.open(Self.context, source.chat.id))

        let restored = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: restored), processing)
        XCTAssertEqual(
            restored.operationallyInterruptedProfileReconsideration,
            request
        )
        XCTAssertTrue(
            restored.isProfileReconsiderationRetryableFailure(reconsideration)
        )

        await feature.send(
            .retryProfileReconsideration(Self.context, sourceIdentity)
        )

        let operationalRequests = await gateway.operationalRequests
        let newRequests = await gateway.newRequests
        let completed = await feature.currentState
        XCTAssertEqual(operationalRequests, [request])
        XCTAssertEqual(newRequests.count, 1)
        XCTAssertEqual(
            Self.openAggregate(in: completed),
            withdrawn
        )
    }

    func testMultipleOperationalReconsiderationRetriesRestoreByExactChat()
        async throws
    {
        let sourceA = try Self.aggregateWithProfileProposal()
        let sourceB = try Self.aggregateWithProfileProposal(
            chat: "cht-20260909T122800000Z-1ABC",
            draft: "drf-20260909T122800000Z-2DEF",
            memory: "mem-20260909T122800000Z-3GHJ"
        )
        let basisA = try Self.staleReconsiderationBasis(for: sourceA)
        let basisB = try Self.staleReconsiderationBasis(for: sourceB)
        let processingA = try Self.installingProfileReconsideration(in: sourceA)
        let processingB = try Self.installingProfileReconsideration(in: sourceB)
        let sidecarA = try XCTUnwrap(processingA.profileReconsideration)
        let sidecarB = try XCTUnwrap(processingB.profileReconsideration)
        let identityA = try XCTUnwrap(sourceA.profileEffect?.identity)
        let identityB = try XCTUnwrap(sourceB.profileEffect?.identity)
        let requestA = ProfileReconsiderationInvocationRequest(
            library: Self.scope,
            chatID: sourceA.chat.id,
            sourceEffectIdentity: identityA,
            resultResponsePositionID: sidecarA.resultResponsePositionID
        )
        let requestB = ProfileReconsiderationInvocationRequest(
            library: Self.scope,
            chatID: sourceB.chat.id,
            sourceEffectIdentity: identityB,
            resultResponsePositionID: sidecarB.resultResponsePositionID
        )
        let gateway = RecordingProfileReconsiderationInvocationGateway(
            outcomes: [
                .operationallyInterrupted(
                    processingA,
                    requestA,
                    .persistenceUnavailable
                ),
                .operationallyInterrupted(
                    processingB,
                    requestB,
                    .persistenceUnavailable
                ),
            ]
        )
        let coordinator = RecordingProfileProposalCoordinator(
            assessmentOutcomes: [
                .stale(sourceA, basisA),
                .stale(sourceA, basisA),
                .stale(sourceB, basisB),
                .stale(sourceB, basisB),
                .stale(processingA, basisA),
                .stale(processingB, basisB),
            ]
        )
        let store = RecordingChatStore(
            catalog: [.available(sourceA), .available(sourceB)],
            loadOutcomes: [
                .loaded(sourceA),
                .loaded(sourceB),
                .loaded(processingA),
                .loaded(processingB),
            ]
        )
        let feature = makeFeature(
            store: store,
            invocations: gateway,
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, sourceA.chat.id))
        await feature.send(.reconsiderProfileEffect(Self.context, identityA))
        await feature.send(.open(Self.context, sourceB.chat.id))
        await feature.send(.reconsiderProfileEffect(Self.context, identityB))

        await feature.send(.open(Self.context, sourceA.chat.id))
        let restoredA = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: restoredA), processingA)
        XCTAssertEqual(
            restoredA.operationallyInterruptedProfileReconsideration,
            requestA
        )

        await feature.send(.open(Self.context, sourceB.chat.id))
        let restoredB = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: restoredB), processingB)
        XCTAssertEqual(
            restoredB.operationallyInterruptedProfileReconsideration,
            requestB
        )
    }

    func testBlockedOperationalReconsiderationRetryRetainsItsExactLiveRequest()
        async throws
    {
        let source = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(source.profileProposal)
        let sourceIdentity = ChatProfileEffectIdentity.proposal(proposal.id)
        let basis = try Self.staleReconsiderationBasis(for: source)
        let processing = try Self.installingProfileReconsideration(in: source)
        let reconsideration = try XCTUnwrap(processing.profileReconsideration)
        let request = ProfileReconsiderationInvocationRequest(
            library: Self.scope,
            chatID: source.chat.id,
            sourceEffectIdentity: sourceIdentity,
            resultResponsePositionID: reconsideration.resultResponsePositionID
        )
        let gateway = RecordingProfileReconsiderationInvocationGateway(
            outcome: .operationallyInterrupted(
                processing,
                request,
                .persistenceUnavailable
            ),
            operationalOutcome: .rejected(nil, .activeInvocation)
        )
        let coordinator = RecordingProfileProposalCoordinator(
            assessmentOutcomes: [
                .stale(source, basis),
                .stale(source, basis),
                .stale(processing, basis),
                .stale(processing, basis),
            ]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(source)]),
            invocations: gateway,
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, source.chat.id))
        await feature.send(
            .reconsiderProfileEffect(Self.context, sourceIdentity)
        )

        await feature.send(
            .retryProfileReconsideration(Self.context, sourceIdentity)
        )

        let operationalRequests = await gateway.operationalRequests
        XCTAssertEqual(operationalRequests, [request])
        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state), processing)
        XCTAssertEqual(
            state.operationallyInterruptedProfileReconsideration,
            request
        )
        XCTAssertTrue(
            state.isProfileReconsiderationRetryableFailure(reconsideration)
        )
        XCTAssertEqual(state.notice, .coachBusy)
        XCTAssertNil(state.activity)
    }

    func testOperationalReconsiderationRetryKeepsNewerRenameOverOldFallback()
        async throws
    {
        let source = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(source.profileProposal)
        let sourceIdentity = ChatProfileEffectIdentity.proposal(proposal.id)
        let basis = try Self.staleReconsiderationBasis(for: source)
        let processing = try Self.installingProfileReconsideration(in: source)
        let reconsideration = try XCTUnwrap(processing.profileReconsideration)
        let request = ProfileReconsiderationInvocationRequest(
            library: Self.scope,
            chatID: source.chat.id,
            sourceEffectIdentity: sourceIdentity,
            resultResponsePositionID: reconsideration.resultResponsePositionID
        )
        let renamedExpected = try RenameChatMutation(
            library: Self.scope,
            base: processing,
            title: ChatTitle("Renamed during Reconsider Retry"),
            updatedAt: await FixedChatClock().now()
        ).replacement
        let oldFallback = ProfileReconsiderationInvocationTryOutcome
            .operationallyInterrupted(
                processing,
                request,
                .persistenceUnavailable
            )
        let gateway = RecordingProfileReconsiderationInvocationGateway(
            outcome: oldFallback,
            operationalOutcome: oldFallback
        )
        let coordinator = RecordingProfileProposalCoordinator(
            assessmentOutcomes: [
                .stale(source, basis),
                .stale(source, basis),
                .stale(renamedExpected, basis),
            ]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(source)]),
            invocations: gateway,
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, source.chat.id))
        await feature.send(
            .reconsiderProfileEffect(Self.context, sourceIdentity)
        )

        await feature.send(
            .rename(
                Self.context,
                source.chat.id,
                title: "Renamed during Reconsider Retry",
                expectedRevision: processing.chat.manifestRevision
            )
        )
        let renamedState = await feature.currentState
        let renamed = try XCTUnwrap(Self.openAggregate(in: renamedState))
        XCTAssertGreaterThan(
            renamed.chat.manifestRevision,
            processing.chat.manifestRevision
        )

        await feature.send(
            .retryProfileReconsideration(Self.context, sourceIdentity)
        )

        let state = await feature.currentState
        XCTAssertEqual(
            Self.openAggregate(in: state)?.chat.title,
            try ChatTitle("Renamed during Reconsider Retry")
        )
        XCTAssertEqual(
            Self.openAggregate(in: state)?.chat.manifestRevision,
            renamed.chat.manifestRevision
        )
        XCTAssertEqual(
            state.operationallyInterruptedProfileReconsideration,
            request
        )
    }

    func testVanishedOperationalRetryAuthorityReloadsDurableChatState()
        async throws
    {
        let source = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(source.profileProposal)
        let sourceIdentity = ChatProfileEffectIdentity.proposal(proposal.id)
        let basis = try Self.staleReconsiderationBasis(for: source)
        let processing = try Self.installingProfileReconsideration(in: source)
        let reconsideration = try XCTUnwrap(processing.profileReconsideration)
        let request = ProfileReconsiderationInvocationRequest(
            library: Self.scope,
            chatID: source.chat.id,
            sourceEffectIdentity: sourceIdentity,
            resultResponsePositionID: reconsideration.resultResponsePositionID
        )
        let gateway = RecordingProfileReconsiderationInvocationGateway(
            outcome: .operationallyInterrupted(
                processing,
                request,
                .persistenceUnavailable
            ),
            operationalOutcome: .rejected(nil, .eligibilityChanged)
        )
        let coordinator = RecordingProfileProposalCoordinator(
            assessmentOutcomes: [
                .stale(source, basis),
                .stale(source, basis),
                .stale(processing, basis),
                .stale(processing, basis),
                .stale(source, basis),
            ]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(source)]),
            invocations: gateway,
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, source.chat.id))
        await feature.send(
            .reconsiderProfileEffect(Self.context, sourceIdentity)
        )

        await feature.send(
            .retryProfileReconsideration(Self.context, sourceIdentity)
        )

        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state), source)
        XCTAssertNil(
            state.operationallyInterruptedProfileReconsideration
        )
        XCTAssertNil(Self.openAggregate(in: state)?.profileReconsideration)
        XCTAssertEqual(state.profileEffectReview, .stale(basis))
        XCTAssertNil(state.activity)
    }

    func testRevokedOperationalRetryIsNotRestoredByExactLookingSidecar()
        async throws
    {
        let source = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(source.profileProposal)
        let sourceIdentity = ChatProfileEffectIdentity.proposal(proposal.id)
        let basis = try Self.staleReconsiderationBasis(for: source)
        let processing = try Self.installingProfileReconsideration(in: source)
        let reconsideration = try XCTUnwrap(processing.profileReconsideration)
        let request = ProfileReconsiderationInvocationRequest(
            library: Self.scope,
            chatID: source.chat.id,
            sourceEffectIdentity: sourceIdentity,
            resultResponsePositionID: reconsideration.resultResponsePositionID
        )
        let gateway = RecordingProfileReconsiderationInvocationGateway(
            outcome: .operationallyInterrupted(
                processing,
                request,
                .persistenceUnavailable
            ),
            operationalOutcome: .rejected(nil, .eligibilityChanged)
        )
        let coordinator = RecordingProfileProposalCoordinator(
            assessmentOutcomes: [
                .stale(source, basis),
                .stale(source, basis),
                .stale(processing, basis),
                .stale(processing, basis),
                .stale(processing, basis),
            ]
        )
        let feature = makeFeature(
            store: RecordingChatStore(
                catalog: [.available(source)],
                loadOutcomes: [.loaded(source), .loaded(processing)]
            ),
            invocations: gateway,
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, source.chat.id))
        await feature.send(
            .reconsiderProfileEffect(Self.context, sourceIdentity)
        )
        await feature.send(
            .retryProfileReconsideration(Self.context, sourceIdentity)
        )

        let reloaded = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: reloaded), processing)
        XCTAssertNil(
            reloaded.operationallyInterruptedProfileReconsideration
        )
        XCTAssertFalse(
            reloaded.isProfileReconsiderationRetryableFailure(reconsideration)
        )

        await feature.send(
            .retryProfileReconsideration(Self.context, sourceIdentity)
        )
        let operationalRequests = await gateway.operationalRequests
        XCTAssertEqual(operationalRequests, [request])
    }

    func testDiscardFailedReconsiderationRestoresStaleReconsiderAndDiscardState()
        async throws
    {
        let source = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(source.profileProposal)
        let basis = try Self.staleReconsiderationBasis(for: source)
        let processing = try Self.installingProfileReconsideration(in: source)
        let reconsideration = try XCTUnwrap(processing.profileReconsideration)
        let failed = try Self.replacingProfileReconsideration(
            in: processing,
            with: reconsideration.replacingFailure(.coachResponseInvalid)
        )
        let discardedAt = await FixedChatClock().now()
        let restored = try failed.discardingReconsiderationFailure(
            expected: try XCTUnwrap(failed.profileReconsideration),
            at: discardedAt
        )
        let coordinator = RecordingProfileProposalCoordinator(
            assessmentOutcomes: [
                .stale(failed, basis),
                .stale(restored, basis),
            ],
            reconsiderationDiscardOutcomes: [.committed(restored)]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(failed)]),
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, failed.chat.id))

        await feature.send(
            .discardProfileReconsiderationFailure(
                Self.context,
                .proposal(proposal.id)
            )
        )

        let mutations = await coordinator.reconsiderationDiscardMutations
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations.first?.library, Self.scope)
        XCTAssertEqual(mutations.first?.base, failed)
        XCTAssertEqual(
            mutations.first?.sourceEffectIdentity,
            .proposal(proposal.id)
        )
        XCTAssertEqual(mutations.first?.discardedAt, discardedAt)
        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state), restored)
        XCTAssertNil(Self.openAggregate(in: state)?.profileReconsideration)
        XCTAssertEqual(state.profileEffectReview, .stale(basis))
        XCTAssertTrue(
            ChatInteractionPolicy.allowsProfileReconsideration(in: state)
        )
        XCTAssertNil(state.activity)
        XCTAssertNil(state.notice)
    }

    func testReconsiderStopRoutesOnlyTheExactObservedAttemptAuthority()
        async throws
    {
        let source = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(source.profileProposal)
        let basis = try Self.staleReconsiderationBasis(for: source)
        let processing = try Self.installingProfileReconsideration(in: source)
        let interrupted = try Self.replacingProfileReconsideration(
            in: processing,
            with: try XCTUnwrap(processing.profileReconsideration)
                .replacingFailure(.coachResponseInterrupted)
        )
        let gateway = StoppableProfileReconsiderationInvocationGateway(
            interrupted: interrupted
        )
        let coordinator = RecordingProfileProposalCoordinator(
            assessmentOutcomes: [
                .stale(source, basis),
                .stale(source, basis),
                .stale(interrupted, basis),
            ]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(source)]),
            invocations: gateway,
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, source.chat.id))

        async let reconsider: Void = feature.send(
            .reconsiderProfileEffect(Self.context, .proposal(proposal.id))
        )
        let authority = await gateway.waitUntilInvocationIsSuspended()
        let wrongAuthority = ProfileReconsiderationInvocationStopAuthority(
            testingRequest: StopProfileReconsiderationInvocationRequest(
                library: authority.library,
                chatID: authority.chatID,
                sourceEffectIdentity: authority.sourceEffectIdentity,
                resultResponsePositionID: authority.resultResponsePositionID
            ),
            invocationID: authority.invocationID,
            attemptID: authority.attemptID,
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000411"
            )!
        )

        await feature.send(
            .stopProfileReconsideration(Self.context, wrongAuthority)
        )
        let callsAfterWrongAuthority = await gateway.stopCalls
        XCTAssertEqual(callsAfterWrongAuthority.count, 0)

        await feature.send(
            .stopProfileReconsideration(Self.context, authority)
        )
        await reconsider

        let calls = await gateway.stopCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.authority, authority)
        XCTAssertEqual(
            calls.first?.request,
            StopProfileReconsiderationInvocationRequest(
                library: authority.library,
                chatID: authority.chatID,
                sourceEffectIdentity: authority.sourceEffectIdentity,
                resultResponsePositionID: authority.resultResponsePositionID
            )
        )
        let state = await feature.currentState
        XCTAssertEqual(
            Self.openAggregate(in: state)?.profileReconsideration?.failure,
            .coachResponseInterrupted
        )
        XCTAssertNil(state.profileReconsiderationStopAuthority)
        XCTAssertNil(state.activity)
    }

    func testReconsiderStopInstallsAuthoritativeSourceRemovalWithoutOperationalRetry()
        async throws
    {
        let source = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(source.profileProposal)
        let basis = try Self.staleReconsiderationBasis(for: source)
        let processing = try Self.installingProfileReconsideration(in: source)
        let current = try ChatAggregate(
            chat: try processing.chat.renamed(
                to: ChatTitle("Source Removed"),
                at: await FixedChatClock().now()
            ),
            memory: processing.memory,
            messages: processing.messages
        )
        let gateway = StoppableProfileReconsiderationInvocationGateway(
            stopOutcome: .persistenceUnavailable(current)
        )
        let coordinator = RecordingProfileProposalCoordinator(
            assessmentOutcomes: [
                .stale(source, basis),
                .stale(source, basis),
            ]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(source)]),
            invocations: gateway,
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, source.chat.id))

        async let reconsider: Void = feature.send(
            .reconsiderProfileEffect(Self.context, .proposal(proposal.id))
        )
        let authority = await gateway.waitUntilInvocationIsSuspended()
        await feature.send(
            .stopProfileReconsideration(Self.context, authority)
        )
        await reconsider

        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state), current)
        XCTAssertNil(state.operationallyInterruptedProfileReconsideration)
        XCTAssertNil(state.profileEffectReview)
        XCTAssertNil(state.profileReconsiderationStopAuthority)
        XCTAssertNil(state.activity)
        XCTAssertEqual(state.notice, .profileReconsiderationUnavailable)
    }

    func testFailedProposalReconsiderationBlocksDirectSourceDiscardCommand()
        async throws
    {
        let source = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(source.profileProposal)
        let basis = try Self.staleReconsiderationBasis(for: source)
        let processing = try Self.installingProfileReconsideration(in: source)
        let failed = try Self.replacingProfileReconsideration(
            in: processing,
            with: try XCTUnwrap(processing.profileReconsideration)
                .replacingFailure(.coachResponseInvalid)
        )
        let coordinator = RecordingProfileProposalCoordinator(
            assessmentOutcomes: [.stale(failed, basis)]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(failed)]),
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, failed.chat.id))

        await feature.send(
            .discardProfileProposal(Self.context, proposal.id)
        )

        let discarded = await coordinator.discardMutations
        let state = await feature.currentState
        XCTAssertEqual(discarded, [])
        XCTAssertEqual(Self.openAggregate(in: state), failed)
    }

    func testFailedEvidenceReconsiderationBlocksDirectSourceDiscardCommand()
        async throws
    {
        let empty = try Self.aggregate(
            draftText: "Keep this evidence while reconsidering.",
            attachments: ChatAttachments(validating: [Self.attachment()])
        )
        let source = try Self.aggregateWithProfileEvidencePublication(from: empty)
        let publication = try XCTUnwrap(source.profileEvidencePublication)
        let append = try XCTUnwrap(publication.evidenceAppends.first)
        let target = try ProfileStatement(
            statementID: append.target.statementID,
            statementKind: append.target.statementKind,
            wording: append.target.wording,
            supportingSessionCount: 0,
            evidence: []
        )
        let base = try ProfileRevision(
            revisionID: ProfileRevisionID(
                "prf-20260909T123000000Z-1ABC"
            ),
            parentRevisionID: nil,
            generation: 7,
            statementGeneration: 7,
            createdAt: source.chat.updatedAt,
            statements: [target]
        )
        let basis = try ProfileReconsiderationBasis(
            sourceEffect: .evidencePublication(publication),
            baseProfile: ProfileSnapshot(revision: base),
            latestProfile: ProfileSnapshot(nullAtStatementGeneration: 8)
        )
        let processing = try Self.installingProfileReconsideration(
            in: source,
            resultResponsePosition: "rsp-20260909T123100000Z-2DEF"
        )
        let failed = try Self.replacingProfileReconsideration(
            in: processing,
            with: try XCTUnwrap(processing.profileReconsideration)
                .replacingFailure(.coachResponseInterrupted)
        )
        let coordinator = RecordingProfileProposalCoordinator(
            assessmentOutcomes: [.stale(failed, basis)]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(failed)]),
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, failed.chat.id))

        await feature.send(
            .discardProfileEvidencePublication(
                Self.context,
                publication.responsePositionID
            )
        )

        let discarded = await coordinator.evidenceDiscardMutations
        let state = await feature.currentState
        XCTAssertEqual(discarded, [])
        XCTAssertEqual(Self.openAggregate(in: state), failed)
    }

    func testReconsiderAdmissionRejectionLeavesExactSourceEffectUnchanged()
        async throws
    {
        let source = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(source.profileProposal)
        let basis = try Self.staleReconsiderationBasis(for: source)
        let gateway = RecordingProfileReconsiderationInvocationGateway(
            preparation: .activeInvocation,
            outcome: .rejected(nil, .activeInvocation)
        )
        let coordinator = RecordingProfileProposalCoordinator(
            assessmentOutcomes: [
                .stale(source, basis),
                .stale(source, basis),
            ]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(source)]),
            invocations: gateway,
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, source.chat.id))

        await feature.send(
            .reconsiderProfileEffect(Self.context, .proposal(proposal.id))
        )

        let newRequests = await gateway.newRequests
        let invokedPrepared = await gateway.invokedPrepared
        XCTAssertEqual(newRequests.count, 1)
        XCTAssertEqual(invokedPrepared.count, 0)
        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state), source)
        XCTAssertEqual(Self.openAggregate(in: state)?.profileEffect, source.profileEffect)
        XCTAssertNil(Self.openAggregate(in: state)?.profileReconsideration)
        XCTAssertEqual(state.profileEffectReview, .stale(basis))
        XCTAssertEqual(state.notice, .coachBusy)
        XCTAssertNil(state.activity)
    }

    func testPreparedReconsiderRaceRejectionRestoresSourceWithoutSidecar()
        async throws
    {
        let source = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(source.profileProposal)
        let basis = try Self.staleReconsiderationBasis(for: source)
        let gateway = RecordingProfileReconsiderationInvocationGateway(
            outcome: .rejected(nil, .activeInvocation)
        )
        let coordinator = RecordingProfileProposalCoordinator(
            assessmentOutcomes: [
                .stale(source, basis),
                .stale(source, basis),
                .stale(source, basis),
            ]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(source)]),
            invocations: gateway,
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, source.chat.id))

        await feature.send(
            .reconsiderProfileEffect(
                Self.context,
                .proposal(proposal.id)
            )
        )

        let newRequestCount = await gateway.newRequests.count
        let invokedPreparedCount = await gateway.invokedPrepared.count
        XCTAssertEqual(newRequestCount, 1)
        XCTAssertEqual(invokedPreparedCount, 1)
        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state), source)
        XCTAssertNil(Self.openAggregate(in: state)?.profileReconsideration)
        XCTAssertEqual(state.profileEffectReview, .stale(basis))
        XCTAssertEqual(state.notice, .coachBusy)
        XCTAssertNil(state.activity)
    }

    func testFailedProfileEffectAssessmentFailsClosedWithoutResolutionActions()
        async throws
    {
        let aggregate = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(aggregate.profileProposal)
        let coordinator = RecordingProfileProposalCoordinator(
            assessmentOutcomes: [.failed]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(aggregate)]),
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))

        let state = await feature.currentState
        XCTAssertEqual(
            state.profileEffectReview,
            .unavailable(.proposal(proposal.id))
        )
        XCTAssertEqual(state.notice, .profileEffectAssessmentFailed)

        await feature.send(.acceptProfileProposal(Self.context, proposal.id))
        await feature.send(.discardProfileProposal(Self.context, proposal.id))
        let acceptedCount = await coordinator.acceptMutations.count
        let discardedCount = await coordinator.discardMutations.count
        XCTAssertEqual(acceptedCount, 0)
        XCTAssertEqual(discardedCount, 0)
    }

    func testPublishedPureEvidenceFailureKeepsExactOperationAndBlocksAnotherSend()
        async throws
    {
        let attachments = try ChatAttachments(
            validating: [Self.attachment()]
        )
        let base = try Self.aggregate(
            draftText: "Keep this evidence with my Profile.",
            attachments: attachments
        )
        let published = try Self.aggregateWithProfileEvidencePublication(
            from: base
        )
        let quote = try await Self.quote(for: base)
        let invocations = PublishedProfileEvidenceInvocationGateway(
            published: published,
            quote: quote
        )
        let coordinator = RecordingProfileProposalCoordinator(
            evidencePublishOutcomes: [.failed]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(base)]),
            invocations: invocations,
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, base.chat.id))

        await feature.send(.sendDraft(Self.context, base.chat.id, base.chat.draft))

        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state), published)
        XCTAssertEqual(
            Self.openAggregate(in: state)?.profileEvidencePublication,
            published.profileEvidencePublication
        )
        XCTAssertNil(state.activity)
        XCTAssertNil(state.notice)
        XCTAssertFalse(ChatInteractionPolicy.allowsComposerEditing(in: state))
        XCTAssertFalse(ChatInteractionPolicy.allowsCoachInvocation(in: state))
        let mutations = await coordinator.evidencePublishMutations
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations.first?.library, Self.scope)
        XCTAssertEqual(mutations.first?.base, published)
        XCTAssertEqual(
            mutations.first?.responsePositionID,
            try ChatResponsePositionID("rsp-20260830T120000000Z-6PQR")
        )
        XCTAssertEqual(
            mutations.first?.intendedRevisionID,
            try ProfileRevisionID("prf-20260830T120000000Z-6PQR")
        )
        let invocationCount = await invocations.invocationCount
        XCTAssertEqual(invocationCount, 1)
    }

    func testPublishedPureEvidenceAppliesLocallyAndResolvesSilently()
        async throws
    {
        let attachments = try ChatAttachments(
            validating: [Self.attachment()]
        )
        let base = try Self.aggregate(
            draftText: "Keep this evidence with my Profile.",
            attachments: attachments
        )
        let published = try Self.aggregateWithProfileEvidencePublication(
            from: base
        )
        let resolved = try Self.resolvingProfileEvidencePublication(
            in: published
        )
        let invocations = PublishedProfileEvidenceInvocationGateway(
            published: published,
            quote: try await Self.quote(for: base)
        )
        let coordinator = RecordingProfileProposalCoordinator(
            evidencePublishOutcomes: [.committed(resolved)]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(base)]),
            invocations: invocations,
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, base.chat.id))

        await feature.send(.sendDraft(Self.context, base.chat.id, base.chat.draft))

        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state), resolved)
        XCTAssertEqual(
            Self.openAggregate(in: state)?.messages,
            published.messages
        )
        XCTAssertEqual(Self.openAggregate(in: state)?.memory, published.memory)
        XCTAssertNil(Self.openAggregate(in: state)?.profileEvidencePublication)
        XCTAssertNil(state.activity)
        XCTAssertNil(state.notice)
        XCTAssertTrue(ChatInteractionPolicy.allowsComposerEditing(in: state))
        let invocationCount = await invocations.invocationCount
        let evidenceMutationCount = await coordinator.evidencePublishMutations.count
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(evidenceMutationCount, 1)
    }

    func testRetryProfileEvidencePublicationRepeatsOnlyTheLocalUnion()
        async throws
    {
        let base = try Self.aggregate(
            draftText: "Already published.",
            attachments: ChatAttachments(validating: [Self.attachment()])
        )
        let failed = try Self.aggregateWithProfileEvidencePublication(from: base)
        let resolved = try Self.resolvingProfileEvidencePublication(in: failed)
        let invocations = RecordingInterruptedInvocationGateway()
        let coordinator = RecordingProfileProposalCoordinator(
            evidencePublishOutcomes: [.committed(resolved)]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(failed)]),
            invocations: invocations,
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, failed.chat.id))
        let responsePositionID = try XCTUnwrap(
            failed.profileEvidencePublication?.responsePositionID
        )

        await feature.send(
            .retryProfileEvidencePublication(Self.context, responsePositionID)
        )

        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state), resolved)
        XCTAssertNil(Self.openAggregate(in: state)?.profileEvidencePublication)
        XCTAssertNil(state.activity)
        XCTAssertNil(state.notice)
        XCTAssertTrue(ChatInteractionPolicy.allowsComposerEditing(in: state))
        let evidenceMutations = await coordinator.evidencePublishMutations
        XCTAssertEqual(evidenceMutations.map(\.base), [failed])
        XCTAssertEqual(
            evidenceMutations.map(\.intendedRevisionID),
            [try ProfileRevisionID("prf-20260830T120000000Z-6PQR")]
        )
        let preparationCount = await invocations.preparations.count
        let invocationCount = await invocations.requests.count
        XCTAssertEqual(preparationCount, 0)
        XCTAssertEqual(invocationCount, 0)
    }

    func testDiscardProfileEvidencePublicationKeepsPublishedTurnAndMemory()
        async throws
    {
        let base = try Self.aggregate(
            draftText: "Already published.",
            attachments: ChatAttachments(validating: [Self.attachment()])
        )
        let failed = try Self.aggregateWithProfileEvidencePublication(from: base)
        let resolved = try Self.resolvingProfileEvidencePublication(in: failed)
        let invocations = RecordingInterruptedInvocationGateway()
        let coordinator = RecordingProfileProposalCoordinator(
            evidenceDiscardOutcomes: [.committed(resolved)]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(failed)]),
            invocations: invocations,
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, failed.chat.id))
        let responsePositionID = try XCTUnwrap(
            failed.profileEvidencePublication?.responsePositionID
        )

        await feature.send(
            .discardProfileEvidencePublication(Self.context, responsePositionID)
        )

        let state = await feature.currentState
        let current = try XCTUnwrap(Self.openAggregate(in: state))
        XCTAssertEqual(current, resolved)
        XCTAssertEqual(current.messages, failed.messages)
        XCTAssertEqual(current.memory, failed.memory)
        XCTAssertNil(current.profileEvidencePublication)
        XCTAssertNil(state.activity)
        XCTAssertNil(state.notice)
        XCTAssertTrue(ChatInteractionPolicy.allowsComposerEditing(in: state))
        let discarded = await coordinator.evidenceDiscardMutations
        XCTAssertEqual(discarded.map(\.base), [failed])
        let retried = await coordinator.evidencePublishMutations.count
        XCTAssertEqual(retried, 0)
        let preparationCount = await invocations.preparations.count
        let invocationCount = await invocations.requests.count
        XCTAssertEqual(preparationCount, 0)
        XCTAssertEqual(invocationCount, 0)
    }

    func testAcceptProfileProposalDispatchesOnceAndInstallsResolvedAggregate()
        async throws
    {
        let aggregate = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(aggregate.profileProposal)
        let resolved = try Self.resolvingProfileProposal(in: aggregate)
        let coordinator = RecordingProfileProposalCoordinator(
            acceptOutcomes: [.committed(resolved)]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(aggregate)]),
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))

        await feature.send(.acceptProfileProposal(Self.context, proposal.id))

        let mutations = await coordinator.acceptMutations
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations.first?.library, Self.scope)
        XCTAssertEqual(mutations.first?.base, aggregate)
        XCTAssertEqual(mutations.first?.proposalID, proposal.id)
        XCTAssertEqual(
            mutations.first?.acceptedAt,
            try UTCInstant("2026-08-30T12:00:00.000Z")
        )
        XCTAssertEqual(
            mutations.first?.intendedRevisionID,
            try ProfileRevisionID("prf-20260830T120300000Z-7QRS")
        )
        XCTAssertEqual(
            mutations.first?.writeIntentID,
            try ProfileWriteIntentID("pwi-20260830T120300000Z-7QRS")
        )
        let discardMutationCount = await coordinator.discardMutations.count
        XCTAssertEqual(discardMutationCount, 0)

        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state), resolved)
        XCTAssertNil(Self.openAggregate(in: state)?.profileProposal)
        XCTAssertNil(state.activity)
        XCTAssertNil(state.notice)
        XCTAssertTrue(ChatInteractionPolicy.allowsComposerEditing(in: state))
    }

    func testDiscardProfileProposalDispatchesOnceAndInstallsResolvedAggregate()
        async throws
    {
        let aggregate = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(aggregate.profileProposal)
        let resolved = try Self.resolvingProfileProposal(in: aggregate)
        let coordinator = RecordingProfileProposalCoordinator(
            discardOutcomes: [.committed(resolved)]
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(aggregate)]),
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))

        await feature.send(.discardProfileProposal(Self.context, proposal.id))

        let mutations = await coordinator.discardMutations
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations.first?.library, Self.scope)
        XCTAssertEqual(mutations.first?.base, aggregate)
        XCTAssertEqual(mutations.first?.proposalID, proposal.id)
        let acceptMutationCount = await coordinator.acceptMutations.count
        XCTAssertEqual(acceptMutationCount, 0)

        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state), resolved)
        XCTAssertNil(Self.openAggregate(in: state)?.profileProposal)
        XCTAssertNil(state.activity)
        XCTAssertNil(state.notice)
        XCTAssertTrue(ChatInteractionPolicy.allowsComposerEditing(in: state))
    }

    func testFirstProfileProposalResolutionSerializesOppositeStaleCommand()
        async throws
    {
        let aggregate = try Self.aggregateWithProfileProposal()
        let proposal = try XCTUnwrap(aggregate.profileProposal)
        let resolved = try Self.resolvingProfileProposal(in: aggregate)
        let coordinator = RecordingProfileProposalCoordinator(
            acceptOutcomes: [.committed(resolved)],
            suspendFirstAccept: true
        )
        let feature = makeFeature(
            store: RecordingChatStore(catalog: [.available(aggregate)]),
            profileProposals: coordinator
        )
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))

        async let accept: Void = feature.send(
            .acceptProfileProposal(Self.context, proposal.id)
        )
        await coordinator.waitUntilFirstAcceptIsSuspended()

        await feature.send(.discardProfileProposal(Self.context, proposal.id))
        let suspendedAcceptCount = await coordinator.acceptMutations.count
        let suspendedDiscardCount = await coordinator.discardMutations.count
        let suspendedState = await feature.currentState
        XCTAssertEqual(suspendedAcceptCount, 1)
        XCTAssertEqual(suspendedDiscardCount, 0)
        XCTAssertEqual(
            suspendedState.activity,
            .acceptingProfileProposal(aggregate.chat.id)
        )

        await coordinator.resumeFirstAccept()
        await accept

        let terminalAcceptCount = await coordinator.acceptMutations.count
        let terminalDiscardCount = await coordinator.discardMutations.count
        XCTAssertEqual(terminalAcceptCount, 1)
        XCTAssertEqual(
            terminalDiscardCount,
            0,
            "the queued opposite action is stale after the first resolution commits"
        )
        let state = await feature.currentState
        XCTAssertEqual(Self.openAggregate(in: state), resolved)
        XCTAssertNil(state.activity)
        XCTAssertNil(state.notice)
    }

    func testFailedProfileProposalOutcomesKeepProposalAndClearActivity()
        async throws
    {
        let acceptAggregate = try Self.aggregateWithProfileProposal()
        let acceptProposal = try XCTUnwrap(acceptAggregate.profileProposal)
        let acceptCoordinator = RecordingProfileProposalCoordinator(
            acceptOutcomes: [.failed]
        )
        let acceptFeature = makeFeature(
            store: RecordingChatStore(catalog: [.available(acceptAggregate)]),
            profileProposals: acceptCoordinator
        )
        await acceptFeature.send(.start(Self.context))
        await acceptFeature.send(.open(Self.context, acceptAggregate.chat.id))

        await acceptFeature.send(
            .acceptProfileProposal(Self.context, acceptProposal.id)
        )

        let acceptState = await acceptFeature.currentState
        XCTAssertEqual(Self.openAggregate(in: acceptState), acceptAggregate)
        XCTAssertEqual(
            Self.openAggregate(in: acceptState)?.profileProposal,
            acceptProposal
        )
        XCTAssertNil(acceptState.activity)
        XCTAssertEqual(acceptState.notice, .profileProposalAcceptFailed)
        XCTAssertFalse(ChatInteractionPolicy.allowsComposerEditing(in: acceptState))

        let discardAggregate = try Self.aggregateWithProfileProposal(
            chat: "cht-20260830T121000000Z-8TVW",
            draft: "drf-20260830T121000000Z-9XYZ",
            memory: "mem-20260830T121000000Z-ABCD"
        )
        let discardProposal = try XCTUnwrap(discardAggregate.profileProposal)
        let discardCoordinator = RecordingProfileProposalCoordinator(
            discardOutcomes: [.failed]
        )
        let discardFeature = makeFeature(
            store: RecordingChatStore(catalog: [.available(discardAggregate)]),
            profileProposals: discardCoordinator
        )
        await discardFeature.send(.start(Self.context))
        await discardFeature.send(.open(Self.context, discardAggregate.chat.id))

        await discardFeature.send(
            .discardProfileProposal(Self.context, discardProposal.id)
        )

        let discardState = await discardFeature.currentState
        XCTAssertEqual(Self.openAggregate(in: discardState), discardAggregate)
        XCTAssertEqual(
            Self.openAggregate(in: discardState)?.profileProposal,
            discardProposal
        )
        XCTAssertNil(discardState.activity)
        XCTAssertEqual(discardState.notice, .profileProposalDiscardFailed)
        XCTAssertFalse(ChatInteractionPolicy.allowsComposerEditing(in: discardState))
    }

    private func makeFeature(
        store: any ChatStorePort,
        profileReader: any ProfileStatementGenerationReading = FixedProfileReader(),
        clock: any ChatClock = FixedChatClock(),
        chatIDGenerator: any ChatIDGenerator = FixedChatIDs(),
        draftIDGenerator: any ChatDraftIDGenerator = FixedChatIDs(),
        memoryIDGenerator: any CoachMemoryIDGenerator = FixedChatIDs(),
        pendingUserTurnIDGenerator: any PendingUserTurnIDGenerator = FixedChatIDs(),
        autosaveScheduler: any ChatAutosaveScheduling = ImmediateChatAutosaveScheduler(),
        transientNoticeScheduler: any ChatTransientNoticeScheduling =
            ImmediateChatTransientNoticeScheduler(),
        admissionRefreshScheduler: any ChatAdmissionRefreshScheduling =
            ImmediateAdmissionRefreshScheduler(),
        invocations: any Invocations = RecordingInterruptedInvocationGateway(),
        profileProposals: any ProfileProposalCoordinating =
            UnavailableProfileProposalCoordinator(),
        coachContext: any ChatCoachContextCoordinating = ChatFeatureBoundCoachContextFixture(
            attachmentSource: EmptyChatAttachmentSource(),
            base: DefaultCoachContextFeature(
                source: AlwaysFitCoachContextSnapshotPort(),
                configurationAuthorityID:
                    chatFeatureConfigurationStamp.authorityID
            )
        )
    ) -> DefaultChatFeature {
        DefaultChatFeature(
            store: store,
            profileReader: profileReader,
            clock: clock,
            chatIDGenerator: chatIDGenerator,
            draftIDGenerator: draftIDGenerator,
            memoryIDGenerator: memoryIDGenerator,
            pendingUserTurnIDGenerator: pendingUserTurnIDGenerator,
            responsePositionIDGenerator: FixedChatIDs(),
            autosaveScheduler: autosaveScheduler,
            transientNoticeScheduler: transientNoticeScheduler,
            admissionRefreshScheduler: admissionRefreshScheduler,
            coachContext: coachContext,
            invocations: invocations,
            profileProposals: profileProposals
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
        draftText: String = "",
        attachments: ChatAttachments = .empty
    ) throws -> ChatAggregate {
        let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
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

    private static func aggregateWithProfileProposal(
        chat: String = "cht-20260830T120000000Z-2ABC",
        draft: String = "drf-20260830T120000000Z-3DEF",
        memory: String = "mem-20260830T120000000Z-4GHJ",
        draftText: String = "Continue coaching me after this decision."
    ) throws -> ChatAggregate {
        let base = try aggregate(
            chat: chat,
            draft: draft,
            memory: memory,
            draftText: draftText
        )
        let instant = try UTCInstant("2026-08-30T12:03:00.000Z")
        let responsePositionID = try ChatResponsePositionID(
            "rsp-20260830T120300000Z-6PQR"
        )
        let profile = CoachProfileProvenance(
            revisionID: nil,
            statementGeneration: 7
        )
        let messages = [
            try ChatMessage(
                id: ChatMessageID("msg-20260830T120300000Z-5KMN"),
                responsePositionID: responsePositionID,
                content: .user(text: "Remember my speaking goal."),
                createdAt: instant
            ),
            try ChatMessage(
                id: ChatMessageID("msg-20260830T120300000Z-7QRS"),
                responsePositionID: responsePositionID,
                content: .coach(markdown: "I have a Profile suggestion for you."),
                coachProfile: profile,
                createdAt: instant
            ),
        ]
        let chatWithMessages = try Chat(
            id: base.chat.id,
            manifestRevision: base.chat.manifestRevision,
            title: base.chat.title,
            createdAt: base.chat.createdAt,
            updatedAt: instant,
            creation: base.chat.creation,
            profileStatementGenerationAtCreation:
                base.chat.profileStatementGenerationAtCreation,
            attachments: base.chat.attachments,
            draft: base.chat.draft,
            messageIDs: messages.map(\.id),
            currentMemoryID: base.chat.currentMemoryID
        )
        let proposed = try ProfileProposedStatement(
            statementID: ProfileStatementID(
                "stm-20260830T120300000Z-8TVW"
            ),
            statementKind: .goal,
            wording: "Speak with a clear structure in technical discussions.",
            evidence: []
        )
        let proposal = try ProfileChangeProposal(
            id: ProfileChangeProposalID("prp-20260830T120300000Z-7QRS"),
            chatID: base.chat.id,
            responsePositionID: responsePositionID,
            baseProfile: profile,
            changes: [.add(statement: proposed)],
            createdAt: instant
        )
        return try ChatAggregate(
            chat: chatWithMessages,
            memory: base.memory,
            messages: messages,
            profileProposal: proposal
        )
    }

    private static func aggregateWithProfileEvidencePublication(
        from base: ChatAggregate
    ) throws -> ChatAggregate {
        let completedAt = try UTCInstant("2026-08-30T12:01:00.000Z")
        let responsePositionID = try ChatResponsePositionID(
            "rsp-20260830T120000000Z-6PQR"
        )
        guard let attachment = base.chat.attachments.values.first else {
            throw TestError.unexpectedState
        }
        let messages = [
            try ChatMessage(
                id: ChatMessageID("msg-20260830T120100000Z-7QRS"),
                responsePositionID: responsePositionID,
                content: .user(text: base.chat.draft.text),
                createdAt: completedAt
            ),
            try ChatMessage(
                id: ChatMessageID("msg-20260830T120100000Z-8TVW"),
                responsePositionID: responsePositionID,
                content: .coach(markdown: "I linked this reflection to your Profile."),
                coachProfile: CoachProfileProvenance(
                    revisionID: nil,
                    statementGeneration: 7
                ),
                createdAt: completedAt
            ),
        ]
        let memory = try CoachMemory(
            memoryID: CoachMemoryID("mem-20260830T120100000Z-9XYZ"),
            chatID: base.chat.id,
            generalNotes: "Keep practicing deliberate transitions.",
            sessionSummaries: [],
            attachments: base.chat.attachments
        )
        let freshDraft = try ChatDraft(
            draftID: ChatDraftID("drf-20260830T120100000Z-ABCD"),
            version: 0,
            text: "",
            updatedAt: completedAt
        )
        let chat = try Chat(
            id: base.chat.id,
            manifestRevision: base.chat.manifestRevision + 1,
            title: base.chat.title,
            createdAt: base.chat.createdAt,
            updatedAt: completedAt,
            creation: base.chat.creation,
            profileStatementGenerationAtCreation:
                base.chat.profileStatementGenerationAtCreation,
            attachments: base.chat.attachments,
            draft: freshDraft,
            messageIDs: messages.map(\.id),
            currentMemoryID: memory.memoryID
        )
        let target = try ProfileProposalTarget(
            statementID: ProfileStatementID(
                "stm-20260830T115900000Z-5KMN"
            ),
            statementKind: .goal,
            wording: "Pause briefly between points."
        )
        let evidence = try EvidenceReference(
            sessionID: attachment.sessionID,
            transcriptRevisionID: attachment.transcriptRevisionID,
            target: .audioEvent(
                audioEventID: AudioEventID("a000001")
            ),
            display: EvidenceReferenceDisplay(
                sessionLabel: "Planning reflection",
                trustedText: "Silent pause",
                startMilliseconds: 100,
                endMilliseconds: 200
            )
        )
        let publication = try ProfileEvidencePublication(
            chatID: base.chat.id,
            responsePositionID: responsePositionID,
            evidenceAppends: [
                ProfileEvidenceAppend(target: target, evidence: [evidence]),
            ],
            createdAt: completedAt
        )
        return try ChatAggregate(
            chat: chat,
            memory: memory,
            messages: messages,
            profileEvidencePublication: publication
        )
    }

    private static func quote(for aggregate: ChatAggregate) async throws
        -> CoachContextQuote
    {
        let context = DefaultCoachContextFeature(
            source: AlwaysFitCoachContextSnapshotPort()
        )
        let outcome = await context.quoteChat(
            CoachContextChatQuoteRequest(
                library: scope,
                chatID: aggregate.chat.id,
                draft: aggregate.chat.draft
            )
        )
        guard case let .available(quote) = outcome else {
            throw TestError.unexpectedState
        }
        return quote
    }

    private static func resolvingProfileProposal(
        in aggregate: ChatAggregate
    ) throws -> ChatAggregate {
        try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            messages: aggregate.messages,
            pendingUserTurn: aggregate.pendingUserTurn
        )
    }

    private static func resolvingProfileEvidencePublication(
        in aggregate: ChatAggregate
    ) throws -> ChatAggregate {
        try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            messages: aggregate.messages,
            pendingUserTurn: aggregate.pendingUserTurn,
            profileProposal: aggregate.profileProposal
        )
    }

    private static func staleReconsiderationBasis(
        for aggregate: ChatAggregate
    ) throws -> ProfileReconsiderationBasis {
        try ProfileReconsiderationBasis(
            sourceEffect: try XCTUnwrap(aggregate.profileEffect),
            baseProfile: ProfileSnapshot(nullAtStatementGeneration: 7),
            latestProfile: ProfileSnapshot(nullAtStatementGeneration: 8)
        )
    }

    private static func installingProfileReconsideration(
        in aggregate: ChatAggregate,
        resultResponsePosition: String =
            "rsp-20260830T120000000Z-6PQR"
    ) throws -> ChatAggregate {
        let effect = try XCTUnwrap(aggregate.profileEffect)
        return try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            messages: aggregate.messages,
            profileEffect: effect,
            profileReconsideration: ProfileReconsideration(
                sourceEffect: effect,
                resultResponsePositionID: try ChatResponsePositionID(
                    resultResponsePosition
                )
            )
        )
    }

    private static func replacingProfileReconsideration(
        in aggregate: ChatAggregate,
        with reconsideration: ProfileReconsideration
    ) throws -> ChatAggregate {
        try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            messages: aggregate.messages,
            profileEffect: aggregate.profileEffect,
            profileReconsideration: reconsideration
        )
    }

    private static func attachment() throws -> ChatSessionAttachment {
        ChatSessionAttachment(
            attachmentID: try ChatSessionAttachmentID("attachment-000001"),
            sessionID: try SessionID("ses-20260830T120100000Z-5KMN"),
            transcriptRevisionID: try TranscriptRevisionID(
                "trv-20260830T120200000Z-6PQR"
            )
        )
    }

    private static func attachmentCandidate() throws -> ChatAttachmentCandidate {
        let attachment = try attachment()
        return try ChatAttachmentCandidate(
            sessionID: attachment.sessionID,
            transcriptRevisionID: attachment.transcriptRevisionID,
            displayLabel: "Synthetic session",
            durationMilliseconds: 1_000,
            approximateTranscriptTokens: 16,
            delivery: .inline
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

    private static func editableDraft(
        in feature: DefaultChatFeature
    ) async throws -> ChatDraft {
        guard case let .editable(draft, _) = await feature.currentState.composer else {
            throw TestError.unexpectedState
        }
        return draft
    }
}

private actor RecordingProfileProposalCoordinator: ProfileProposalCoordinating {
    private var assessmentOutcomes: [ProfileEffectAssessmentOutcome]
    private var acceptOutcomes: [ProfileProposalMutationOutcome]
    private var discardOutcomes: [ProfileProposalMutationOutcome]
    private var evidencePublishOutcomes:
        [ProfileEvidencePublicationMutationOutcome]
    private var evidenceDiscardOutcomes:
        [ProfileEvidencePublicationMutationOutcome]
    private var reconsiderationDiscardOutcomes: [ProfileEffectMutationOutcome]
    private var suspendFirstAccept: Bool
    private var firstAcceptContinuation: CheckedContinuation<Void, Never>?
    private(set) var acceptMutations: [AcceptProfileProposalMutation] = []
    private(set) var assessmentRequests: [AssessProfileEffectRequest] = []
    private(set) var discardMutations: [DiscardProfileProposalMutation] = []
    private(set) var evidencePublishMutations: [PublishProfileEvidenceMutation] = []
    private(set) var evidenceDiscardMutations:
        [DiscardProfileEvidencePublicationMutation] = []
    private(set) var reconsiderationDiscardMutations:
        [DiscardProfileReconsiderationFailureMutation] = []

    init(
        assessmentOutcomes: [ProfileEffectAssessmentOutcome] = [],
        acceptOutcomes: [ProfileProposalMutationOutcome] = [],
        discardOutcomes: [ProfileProposalMutationOutcome] = [],
        evidencePublishOutcomes: [ProfileEvidencePublicationMutationOutcome] = [],
        evidenceDiscardOutcomes: [ProfileEvidencePublicationMutationOutcome] = [],
        reconsiderationDiscardOutcomes: [ProfileEffectMutationOutcome] = [],
        suspendFirstAccept: Bool = false
    ) {
        self.assessmentOutcomes = assessmentOutcomes
        self.acceptOutcomes = acceptOutcomes
        self.discardOutcomes = discardOutcomes
        self.evidencePublishOutcomes = evidencePublishOutcomes
        self.evidenceDiscardOutcomes = evidenceDiscardOutcomes
        self.reconsiderationDiscardOutcomes = reconsiderationDiscardOutcomes
        self.suspendFirstAccept = suspendFirstAccept
    }

    func assess(
        _ request: AssessProfileEffectRequest
    ) async -> ProfileEffectAssessmentOutcome {
        assessmentRequests.append(request)
        guard !assessmentOutcomes.isEmpty else { return .current(request.base) }
        return assessmentOutcomes.removeFirst()
    }

    func accept(
        _ mutation: AcceptProfileProposalMutation
    ) async -> ProfileProposalMutationOutcome {
        acceptMutations.append(mutation)
        if suspendFirstAccept {
            suspendFirstAccept = false
            await withCheckedContinuation { firstAcceptContinuation = $0 }
        }
        guard !acceptOutcomes.isEmpty else { return .failed }
        return acceptOutcomes.removeFirst()
    }

    func discard(
        _ mutation: DiscardProfileProposalMutation
    ) async -> ProfileProposalMutationOutcome {
        discardMutations.append(mutation)
        guard !discardOutcomes.isEmpty else { return .failed }
        return discardOutcomes.removeFirst()
    }

    func publishEvidence(
        _ mutation: PublishProfileEvidenceMutation
    ) async -> ProfileEvidencePublicationMutationOutcome {
        evidencePublishMutations.append(mutation)
        guard !evidencePublishOutcomes.isEmpty else { return .failed }
        return evidencePublishOutcomes.removeFirst()
    }

    func discardEvidence(
        _ mutation: DiscardProfileEvidencePublicationMutation
    ) async -> ProfileEvidencePublicationMutationOutcome {
        evidenceDiscardMutations.append(mutation)
        guard !evidenceDiscardOutcomes.isEmpty else { return .failed }
        return evidenceDiscardOutcomes.removeFirst()
    }

    func discardReconsiderationFailure(
        _ mutation: DiscardProfileReconsiderationFailureMutation
    ) async -> ProfileEffectMutationOutcome {
        reconsiderationDiscardMutations.append(mutation)
        guard !reconsiderationDiscardOutcomes.isEmpty else { return .failed }
        return reconsiderationDiscardOutcomes.removeFirst()
    }

    func waitUntilFirstAcceptIsSuspended() async {
        while firstAcceptContinuation == nil { await Task.yield() }
    }

    func resumeFirstAccept() {
        firstAcceptContinuation?.resume()
        firstAcceptContinuation = nil
    }
}

private actor RecordingProfileReconsiderationInvocationGateway: Invocations {
    enum Preparation: Sendable {
        case prepared
        case activeInvocation
        case failed
    }

    private let preparation: Preparation
    private var outcomes: [ProfileReconsiderationInvocationTryOutcome]
    private let operationalOutcome: ProfileReconsiderationInvocationTryOutcome?
    private(set) var newRequests: [NewProfileReconsiderationInvocationRequest] = []
    private(set) var invokedPrepared: [PreparedProfileReconsiderationInvocation] = []
    private(set) var operationalRequests:
        [ProfileReconsiderationInvocationRequest] = []
    private(set) var abandoned: [PreparedProfileReconsiderationInvocation] = []

    init(
        preparation: Preparation = .prepared,
        outcome: ProfileReconsiderationInvocationTryOutcome,
        operationalOutcome: ProfileReconsiderationInvocationTryOutcome? = nil
    ) {
        self.preparation = preparation
        outcomes = [outcome]
        self.operationalOutcome = operationalOutcome
    }

    init(
        preparation: Preparation = .prepared,
        outcomes: [ProfileReconsiderationInvocationTryOutcome],
        operationalOutcome: ProfileReconsiderationInvocationTryOutcome? = nil
    ) {
        self.preparation = preparation
        self.outcomes = outcomes
        self.operationalOutcome = operationalOutcome
    }

    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        .available
    }

    func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
        .failed
    }

    func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async {}

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome {
        .rejected(prepared.aggregate, .eligibilityChanged)
    }

    func tryInvoke(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationTryOutcome {
        .rejected(nil, .eligibilityChanged)
    }

    func prepareNewProfileReconsiderationInvocation(
        _ request: NewProfileReconsiderationInvocationRequest
    ) async -> NewProfileReconsiderationInvocationOutcome {
        newRequests.append(request)
        switch preparation {
        case .prepared:
            return .prepared(
                try! PreparedProfileReconsiderationInvocation(
                    preparing: request
                )
            )
        case .activeInvocation:
            return .activeInvocation
        case .failed:
            return .failed
        }
    }

    func abandonPreparedProfileReconsiderationInvocation(
        _ prepared: PreparedProfileReconsiderationInvocation
    ) async {
        abandoned.append(prepared)
    }

    func tryReconsiderProfileChange(
        _ prepared: PreparedProfileReconsiderationInvocation
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        invokedPrepared.append(prepared)
        guard outcomes.count > 1 else {
            return outcomes.first ?? .rejected(nil, .persistenceUnavailable)
        }
        return outcomes.removeFirst()
    }

    func tryReconsiderProfileChange(
        _ request: ProfileReconsiderationInvocationRequest
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        operationalRequests.append(request)
        return operationalOutcome ?? .rejected(nil, .eligibilityChanged)
    }
}

private actor StoppableProfileReconsiderationInvocationGateway: Invocations {
    struct StopCall: Equatable, Sendable {
        let request: StopProfileReconsiderationInvocationRequest
        let authority: ProfileReconsiderationInvocationStopAuthority
    }

    private let stopOutcome: ProfileReconsiderationInvocationStopOutcome
    private var prepared: PreparedProfileReconsiderationInvocation?
    private var authority: ProfileReconsiderationInvocationStopAuthority?
    private var invocationContinuation:
        CheckedContinuation<ProfileReconsiderationInvocationTryOutcome, Never>?
    private(set) var stopCalls: [StopCall] = []

    init(interrupted: ChatAggregate) {
        stopOutcome = .interrupted(interrupted)
    }

    init(stopOutcome: ProfileReconsiderationInvocationStopOutcome) {
        self.stopOutcome = stopOutcome
    }

    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        .available
    }

    func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
        .failed
    }

    func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async {}

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome {
        .rejected(prepared.aggregate, .eligibilityChanged)
    }

    func tryInvoke(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationTryOutcome {
        .rejected(nil, .eligibilityChanged)
    }

    func prepareNewProfileReconsiderationInvocation(
        _ request: NewProfileReconsiderationInvocationRequest
    ) async -> NewProfileReconsiderationInvocationOutcome {
        .prepared(
            try! PreparedProfileReconsiderationInvocation(preparing: request)
        )
    }

    func tryReconsiderProfileChange(
        _ prepared: PreparedProfileReconsiderationInvocation
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        await tryReconsiderProfileChange(
            prepared,
            observingStopAuthority: { _ in }
        )
    }

    func tryReconsiderProfileChange(
        _ prepared: PreparedProfileReconsiderationInvocation,
        observingStopAuthority observer:
            @escaping ProfileReconsiderationInvocationStopAuthorityObserver
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        self.prepared = prepared
        let authority = ProfileReconsiderationInvocationStopAuthority(
            testingRequest: StopProfileReconsiderationInvocationRequest(
                prepared.request
            ),
            invocationID: try! CoachInvocationID(
                "inv-20260909T123000000Z-1ABC"
            ),
            attemptID: try! CoachProviderAttemptID(
                "atm-20260909T123000000Z-2DEF"
            ),
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000410"
            )!
        )
        self.authority = authority
        await observer(authority)
        return await withCheckedContinuation {
            invocationContinuation = $0
        }
    }

    func stopProfileReconsideration(
        _ request: StopProfileReconsiderationInvocationRequest,
        authority: ProfileReconsiderationInvocationStopAuthority
    ) async -> ProfileReconsiderationInvocationStopOutcome {
        stopCalls.append(StopCall(request: request, authority: authority))
        guard self.authority == authority,
              authority.library == request.library,
              authority.chatID == request.chatID,
              authority.sourceEffectIdentity == request.sourceEffectIdentity,
              authority.resultResponsePositionID ==
                request.resultResponsePositionID,
              prepared?.request == ProfileReconsiderationInvocationRequest(
                library: request.library,
                chatID: request.chatID,
                sourceEffectIdentity: request.sourceEffectIdentity,
                resultResponsePositionID: request.resultResponsePositionID
              )
        else { return .staleAuthority }
        invocationContinuation?.resume(returning: .stopped)
        invocationContinuation = nil
        self.authority = nil
        return stopOutcome
    }

    func waitUntilInvocationIsSuspended()
        async -> ProfileReconsiderationInvocationStopAuthority
    {
        while authority == nil || invocationContinuation == nil {
            await Task.yield()
        }
        return authority!
    }
}

/// Legacy Chat feature fixtures stop at the single typed Invocation boundary.
/// The feature retains its already-installed lock while this recorder reports
/// an interruption without fabricating provider execution in these tests.
private actor StoppableInvocationGateway: Invocations {
    struct StopCall: Equatable, Sendable {
        let request: StopCoachInvocationRequest
        let authority: InvocationStopAuthority
    }

    private var prepared: PreparedPendingCoachInvocation?
    private var authority: InvocationStopAuthority?
    private var invocationContinuation:
        CheckedContinuation<InvocationTryOutcome, Never>?
    private var reapContinuation: CheckedContinuation<Void, Never>?
    private var stopStarted = false
    private(set) var stops: [StopCall] = []

    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        .available
    }

    func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
        .prepared(try! PreparedPendingCoachInvocation(preparing: request))
    }

    func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async {}

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome {
        await tryInvoke(prepared, observingStopAuthority: { _ in })
    }

    func tryInvoke(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationTryOutcome {
        .rejected(nil, .eligibilityChanged)
    }

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation,
        observingStopAuthority observer: @escaping InvocationStopAuthorityObserver
    ) async -> InvocationTryOutcome {
        self.prepared = prepared
        let authority = InvocationStopAuthority(
            testingRequest: StopCoachInvocationRequest(
                library: prepared.request.library,
                chatID: prepared.request.chatID,
                pendingUserTurnID: prepared.request.pendingUserTurnID
            ),
            invocationID: try! CoachInvocationID(
                "inv-20260830T120000000Z-5KMN"
            ),
            attemptID: try! CoachProviderAttemptID(
                "atm-20260830T120000000Z-6NPQ"
            ),
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000398"
            )!
        )
        self.authority = authority
        await observer(authority)
        return await withCheckedContinuation { invocationContinuation = $0 }
    }

    func stop(
        _ request: StopCoachInvocationRequest,
        authority: InvocationStopAuthority
    ) async -> InvocationStopOutcome {
        stops.append(StopCall(request: request, authority: authority))
        guard self.authority == authority,
              authority.library == request.library,
              authority.chatID == request.chatID,
              authority.pendingUserTurnID == request.pendingUserTurnID,
              let prepared,
              let pending = prepared.aggregate.pendingUserTurn
        else { return .staleAuthority }
        stopStarted = true
        await withCheckedContinuation { reapContinuation = $0 }
        let terminal = try! ChatAggregate(
            chat: prepared.aggregate.chat,
            memory: prepared.aggregate.memory,
            pendingUserTurn: pending.replacingFailure(
                .coachResponseInterrupted
            )
        )
        invocationContinuation?.resume(
            returning: .interrupted(nil, .persistenceUnavailable)
        )
        invocationContinuation = nil
        self.authority = nil
        return .interrupted(terminal)
    }

    func waitUntilInvocationIsSuspended() async -> InvocationStopAuthority {
        while authority == nil || invocationContinuation == nil {
            await Task.yield()
        }
        return authority!
    }

    func waitUntilStopStarts() async {
        while !stopStarted || reapContinuation == nil { await Task.yield() }
    }

    func resumeReap() {
        reapContinuation?.resume()
        reapContinuation = nil
    }

    func finishWithoutStop() {
        invocationContinuation?.resume(
            returning: .interrupted(nil, .providerFailed)
        )
        invocationContinuation = nil
        authority = nil
    }
}

private actor StoppableRetryInvocationGateway: Invocations {
    private let failedAggregate: ChatAggregate
    private var authority: InvocationStopAuthority?
    private var retryContinuation:
        CheckedContinuation<InvocationTryOutcome, Never>?
    private var reapContinuation: CheckedContinuation<Void, Never>?
    private var stopStarted = false

    init(failedAggregate: ChatAggregate) {
        self.failedAggregate = failedAggregate
    }

    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        .available
    }

    func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
        .prepared(try! PreparedPendingCoachInvocation(preparing: request))
    }

    func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async {}

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome {
        .rejected(prepared.aggregate, .eligibilityChanged)
    }

    func tryInvoke(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationTryOutcome {
        await tryInvoke(request, observingStopAuthority: { _ in })
    }

    func tryInvoke(
        _ request: PendingCoachInvocationRequest,
        observingStopAuthority observer: @escaping InvocationStopAuthorityObserver
    ) async -> InvocationTryOutcome {
        guard request.chatID == failedAggregate.chat.id,
              request.pendingUserTurnID == failedAggregate.pendingUserTurn?.id
        else { return .rejected(nil, .eligibilityChanged) }
        let authority = InvocationStopAuthority(
            testingRequest: StopCoachInvocationRequest(
                library: request.library,
                chatID: request.chatID,
                pendingUserTurnID: request.pendingUserTurnID
            ),
            invocationID: try! CoachInvocationID(
                "inv-20260830T120000000Z-5KMN"
            ),
            attemptID: try! CoachProviderAttemptID(
                "atm-20260830T120000000Z-6NPQ"
            ),
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000397"
            )!
        )
        self.authority = authority
        await observer(authority)
        return await withCheckedContinuation { retryContinuation = $0 }
    }

    func stop(
        _ request: StopCoachInvocationRequest,
        authority: InvocationStopAuthority
    ) async -> InvocationStopOutcome {
        guard self.authority == authority,
              authority.library == request.library,
              authority.chatID == request.chatID,
              authority.pendingUserTurnID == request.pendingUserTurnID,
              let pending = failedAggregate.pendingUserTurn
        else { return .staleAuthority }
        stopStarted = true
        await withCheckedContinuation { reapContinuation = $0 }
        self.authority = nil
        return .interrupted(
            try! ChatAggregate(
                chat: failedAggregate.chat,
                memory: failedAggregate.memory,
                pendingUserTurn: pending.replacingFailure(
                    .coachResponseInterrupted
                )
            )
        )
    }

    func waitUntilRetryIsSuspended() async -> InvocationStopAuthority {
        while authority == nil || retryContinuation == nil {
            await Task.yield()
        }
        return authority!
    }

    func waitUntilStopStarts() async {
        while !stopStarted || reapContinuation == nil { await Task.yield() }
    }

    func resumeReap() {
        reapContinuation?.resume()
        reapContinuation = nil
    }

    func finishStoppedRetry() {
        retryContinuation?.resume(returning: .stopped)
        retryContinuation = nil
    }
}

private actor RetryableUnreapedInvocationGateway: Invocations {
    private let suspendSecondReap: Bool
    private let retryAggregate: ChatAggregate?
    private var authority: InvocationStopAuthority?
    private var aggregate: ChatAggregate?
    private var invocationContinuation:
        CheckedContinuation<InvocationTryOutcome, Never>?
    private var secondReapContinuation: CheckedContinuation<Void, Never>?
    private(set) var invocationCount = 0
    private(set) var stopCount = 0
    private(set) var stopRequests: [StopCoachInvocationRequest] = []
    private(set) var stopAuthorities: [InvocationStopAuthority] = []

    init(
        suspendSecondReap: Bool = false,
        retryAggregate: ChatAggregate? = nil
    ) {
        self.suspendSecondReap = suspendSecondReap
        self.retryAggregate = retryAggregate
    }

    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        .available
    }

    func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
        .prepared(try! PreparedPendingCoachInvocation(preparing: request))
    }

    func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async {}

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome {
        await tryInvoke(prepared, observingStopAuthority: { _ in })
    }

    func tryInvoke(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationTryOutcome {
        await tryInvoke(request, observingStopAuthority: { _ in })
    }

    func tryInvoke(
        _ request: PendingCoachInvocationRequest,
        observingStopAuthority observer: @escaping InvocationStopAuthorityObserver
    ) async -> InvocationTryOutcome {
        guard let retryAggregate,
              retryAggregate.chat.id == request.chatID,
              retryAggregate.pendingUserTurn?.id == request.pendingUserTurnID
        else { return .rejected(nil, .eligibilityChanged) }
        invocationCount += 1
        let authority = InvocationStopAuthority(
            testingRequest: StopCoachInvocationRequest(
                library: request.library,
                chatID: request.chatID,
                pendingUserTurnID: request.pendingUserTurnID
            ),
            invocationID: try! CoachInvocationID(
                "inv-20260830T120000000Z-7QRS"
            ),
            attemptID: try! CoachProviderAttemptID(
                "atm-20260830T120000000Z-8TVW"
            ),
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000397"
            )!
        )
        self.authority = authority
        aggregate = retryAggregate
        await observer(authority)
        return await withCheckedContinuation { invocationContinuation = $0 }
    }

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation,
        observingStopAuthority observer: @escaping InvocationStopAuthorityObserver
    ) async -> InvocationTryOutcome {
        invocationCount += 1
        let authority = InvocationStopAuthority(
            testingRequest: StopCoachInvocationRequest(
                library: prepared.request.library,
                chatID: prepared.request.chatID,
                pendingUserTurnID: prepared.request.pendingUserTurnID
            ),
            invocationID: try! CoachInvocationID(
                "inv-20260830T120000000Z-7QRS"
            ),
            attemptID: try! CoachProviderAttemptID(
                "atm-20260830T120000000Z-8TVW"
            ),
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000397"
            )!
        )
        self.authority = authority
        aggregate = prepared.aggregate
        await observer(authority)
        return await withCheckedContinuation { invocationContinuation = $0 }
    }

    func stop(
        _ request: StopCoachInvocationRequest,
        authority: InvocationStopAuthority
    ) async -> InvocationStopOutcome {
        guard self.authority == authority,
              authority.library == request.library,
              authority.chatID == request.chatID,
              authority.pendingUserTurnID == request.pendingUserTurnID
        else { return .staleAuthority }
        stopCount += 1
        stopRequests.append(request)
        stopAuthorities.append(authority)
        if stopCount == 1 {
            invocationContinuation?.resume(returning: .stopped)
            invocationContinuation = nil
            return .unableToReap
        }
        if suspendSecondReap, stopCount == 2 {
            await withCheckedContinuation { secondReapContinuation = $0 }
        }
        guard let aggregate, let pending = aggregate.pendingUserTurn else {
            return .persistenceUnavailable(aggregate)
        }
        self.authority = nil
        return .interrupted(
            try! ChatAggregate(
                chat: aggregate.chat,
                memory: aggregate.memory,
                pendingUserTurn: pending.replacingFailure(
                    .coachResponseInterrupted
                )
            )
        )
    }

    func waitUntilInvocationIsSuspended() async -> InvocationStopAuthority {
        while authority == nil || invocationContinuation == nil {
            await Task.yield()
        }
        return authority!
    }

    func waitUntilSecondReapStarts() async {
        while stopCount < 2 || secondReapContinuation == nil {
            await Task.yield()
        }
    }

    func resumeSecondReap() {
        secondReapContinuation?.resume()
        secondReapContinuation = nil
    }

    func waitUntilInvocationCount(_ expected: Int) async -> InvocationStopAuthority {
        while invocationCount < expected || authority == nil ||
            invocationContinuation == nil
        {
            await Task.yield()
        }
        return authority!
    }

    func finishInvocationAsStopped() {
        invocationContinuation?.resume(returning: .stopped)
        invocationContinuation = nil
    }

    func finishInvocationAsProviderReapPending() {
        guard let authority else { return }
        invocationContinuation?.resume(
            returning: .providerReapPending(authority)
        )
        invocationContinuation = nil
    }
}

private actor UnreapableStoppableInvocationGateway: Invocations {
    private var authority: InvocationStopAuthority?
    private var invocationContinuation:
        CheckedContinuation<InvocationTryOutcome, Never>?
    private(set) var stopCount = 0

    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        .available
    }

    func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
        .prepared(try! PreparedPendingCoachInvocation(preparing: request))
    }

    func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async {}

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome {
        await tryInvoke(prepared, observingStopAuthority: { _ in })
    }

    func tryInvoke(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationTryOutcome {
        .rejected(nil, .eligibilityChanged)
    }

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation,
        observingStopAuthority observer: @escaping InvocationStopAuthorityObserver
    ) async -> InvocationTryOutcome {
        let authority = InvocationStopAuthority(
            testingRequest: StopCoachInvocationRequest(
                library: prepared.request.library,
                chatID: prepared.request.chatID,
                pendingUserTurnID: prepared.request.pendingUserTurnID
            ),
            invocationID: try! CoachInvocationID(
                "inv-20260830T120000000Z-5KMN"
            ),
            attemptID: try! CoachProviderAttemptID(
                "atm-20260830T120000000Z-6NPQ"
            ),
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000396"
            )!
        )
        self.authority = authority
        await observer(authority)
        return await withCheckedContinuation { invocationContinuation = $0 }
    }

    func stop(
        _ request: StopCoachInvocationRequest,
        authority: InvocationStopAuthority
    ) async -> InvocationStopOutcome {
        guard self.authority == authority,
              authority.library == request.library,
              authority.chatID == request.chatID,
              authority.pendingUserTurnID == request.pendingUserTurnID
        else { return .staleAuthority }
        stopCount += 1
        invocationContinuation?.resume(returning: .stopped)
        invocationContinuation = nil
        return .unableToReap
    }

    func waitUntilInvocationIsSuspended() async -> InvocationStopAuthority {
        while authority == nil || invocationContinuation == nil {
            await Task.yield()
        }
        return authority!
    }
}

private actor AdmissionRefreshDuringUnreapableStopGateway: Invocations {
    private var admissionCallCount = 0
    private var admissionRefreshContinuation: CheckedContinuation<Void, Never>?
    private var authority: InvocationStopAuthority?
    private var invocationContinuation:
        CheckedContinuation<InvocationTryOutcome, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var stopStarted = false
    private(set) var stopCount = 0

    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        admissionCallCount += 1
        if admissionCallCount == 2 {
            await withCheckedContinuation {
                admissionRefreshContinuation = $0
            }
        }
        return .available
    }

    func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
        .prepared(try! PreparedPendingCoachInvocation(preparing: request))
    }

    func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async {}

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome {
        await tryInvoke(prepared, observingStopAuthority: { _ in })
    }

    func tryInvoke(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationTryOutcome {
        .rejected(nil, .eligibilityChanged)
    }

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation,
        observingStopAuthority observer: @escaping InvocationStopAuthorityObserver
    ) async -> InvocationTryOutcome {
        let authority = InvocationStopAuthority(
            testingRequest: StopCoachInvocationRequest(
                library: prepared.request.library,
                chatID: prepared.request.chatID,
                pendingUserTurnID: prepared.request.pendingUserTurnID
            ),
            invocationID: try! CoachInvocationID(
                "inv-20260830T120000000Z-5KMN"
            ),
            attemptID: try! CoachProviderAttemptID(
                "atm-20260830T120000000Z-6NPQ"
            ),
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000395"
            )!
        )
        self.authority = authority
        await observer(authority)
        return await withCheckedContinuation { invocationContinuation = $0 }
    }

    func stop(
        _ request: StopCoachInvocationRequest,
        authority: InvocationStopAuthority
    ) async -> InvocationStopOutcome {
        guard self.authority == authority,
              authority.library == request.library,
              authority.chatID == request.chatID,
              authority.pendingUserTurnID == request.pendingUserTurnID
        else { return .staleAuthority }
        stopCount += 1
        if stopCount > 1 {
            self.authority = nil
            return .noActiveInvocation
        }
        stopStarted = true
        await withCheckedContinuation { stopContinuation = $0 }
        return .unableToReap
    }

    func waitUntilInvocationIsSuspended() async -> InvocationStopAuthority {
        while authority == nil || invocationContinuation == nil {
            await Task.yield()
        }
        return authority!
    }

    func waitUntilStopStarts() async {
        while !stopStarted || stopContinuation == nil { await Task.yield() }
    }

    func finishInvocationAsStopped() {
        invocationContinuation?.resume(returning: .stopped)
        invocationContinuation = nil
    }

    func waitUntilAdmissionRefreshStarts() async {
        while admissionCallCount < 2 || admissionRefreshContinuation == nil {
            await Task.yield()
        }
    }

    func resumeAdmissionRefresh() {
        admissionRefreshContinuation?.resume()
        admissionRefreshContinuation = nil
    }

    func finishStopAsUnableToReap() {
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

private actor RecordingInterruptedInvocationGateway: Invocations {
    private(set) var preparations: [NewPendingCoachInvocationRequest] = []
    private(set) var requests: [PendingCoachInvocationRequest] = []

    func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
        preparations.append(request)
        return .prepared(
            try! PreparedPendingCoachInvocation(preparing: request)
        )
    }

    func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async {}

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome {
        await tryInvoke(prepared.request)
    }

    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        .available
    }

    func tryInvoke(_ request: PendingCoachInvocationRequest) async -> InvocationTryOutcome {
        requests.append(request)
        return .interrupted(nil, .providerFailed)
    }
}

private actor PublishedProfileEvidenceInvocationGateway: Invocations {
    private let published: ChatAggregate
    private let quote: CoachContextQuote
    private(set) var invocationCount = 0

    init(published: ChatAggregate, quote: CoachContextQuote) {
        self.published = published
        self.quote = quote
    }

    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        .available
    }

    func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
        .prepared(try! PreparedPendingCoachInvocation(preparing: request))
    }

    func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async {}

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome {
        invocationCount += 1
        guard prepared.aggregate.chat.id == published.chat.id,
              prepared.aggregate.pendingUserTurn?.responsePositionID ==
                published.profileEvidencePublication?.responsePositionID
        else { return .rejected(prepared.aggregate, .eligibilityChanged) }
        return .published(published, quote)
    }

    func tryInvoke(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationTryOutcome {
        .rejected(nil, .eligibilityChanged)
    }
}

private actor TypedTerminalInvocationGateway: Invocations {
    private let failure: PendingUserTurnFailure
    private let reason: InvocationInterruptionReason

    init(
        failure: PendingUserTurnFailure,
        reason: InvocationInterruptionReason
    ) {
        self.failure = failure
        self.reason = reason
    }

    func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
        .prepared(try! PreparedPendingCoachInvocation(preparing: request))
    }

    func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async {}

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome {
        guard let pending = prepared.aggregate.pendingUserTurn else {
            return .interrupted(nil, reason)
        }
        let terminal = try! ChatAggregate(
            chat: prepared.aggregate.chat,
            memory: prepared.aggregate.memory,
            pendingUserTurn: pending.replacingFailure(failure)
        )
        return .interrupted(terminal, reason)
    }

    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        .available
    }

    func tryInvoke(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationTryOutcome {
        .interrupted(nil, reason)
    }
}

private actor BusyPreparingInvocationGateway: Invocations {
    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        .available
    }

    func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
        .activeInvocation
    }

    func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async {}

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome {
        .rejected(prepared.aggregate, .activeInvocation)
    }

    func tryInvoke(_ request: PendingCoachInvocationRequest) async -> InvocationTryOutcome {
        .rejected(nil, .activeInvocation)
    }
}

private actor SuspendedPreparingInvocationGateway: Invocations {
    private var preparation: NewPendingCoachInvocationRequest?
    private var preparationContinuation: CheckedContinuation<Void, Never>?
    private(set) var abandoned: [PreparedPendingCoachInvocation] = []
    private(set) var invocationCount = 0

    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        .available
    }

    func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
        preparation = request
        await withCheckedContinuation { preparationContinuation = $0 }
        return .prepared(
            try! PreparedPendingCoachInvocation(preparing: request)
        )
    }

    func waitUntilPreparationStarts() async {
        while preparation == nil { await Task.yield() }
    }

    func resumePreparation() {
        preparationContinuation?.resume()
        preparationContinuation = nil
    }

    func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async {
        abandoned.append(prepared)
    }

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome {
        invocationCount += 1
        return .interrupted(prepared.aggregate, .providerFailed)
    }

    func tryInvoke(_ request: PendingCoachInvocationRequest) async -> InvocationTryOutcome {
        invocationCount += 1
        return .interrupted(nil, .providerFailed)
    }
}

private actor SuspendedRetryInvocationGateway: Invocations {
    private var request: PendingCoachInvocationRequest?
    private var continuation: CheckedContinuation<InvocationTryOutcome, Never>?

    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        .available
    }

    func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
        .prepared(try! PreparedPendingCoachInvocation(preparing: request))
    }

    func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async {}

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome {
        await tryInvoke(prepared.request)
    }

    func tryInvoke(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationTryOutcome {
        self.request = request
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilRetryIsSuspended() async {
        while request == nil || continuation == nil { await Task.yield() }
    }

    func resume(with outcome: InvocationTryOutcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

private actor OperationallyInterruptedInvocationGateway: Invocations {
    private let fallback: ChatAggregate?
    private(set) var requests: [PendingCoachInvocationRequest] = []

    init(fallback: ChatAggregate? = nil) {
        self.fallback = fallback
    }

    func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
        .prepared(try! PreparedPendingCoachInvocation(preparing: request))
    }

    func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async {}

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome {
        await tryInvoke(prepared.request)
    }

    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        .available
    }

    func tryInvoke(_ request: PendingCoachInvocationRequest) async -> InvocationTryOutcome {
        requests.append(request)
        return .operationallyInterrupted(fallback, request, .persistenceUnavailable)
    }
}

private actor OperationalInterruptionThenSuspendedRetryGateway: Invocations {
    private var retryRequest: PendingCoachInvocationRequest?
    private var continuation: CheckedContinuation<InvocationTryOutcome, Never>?

    func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
        .prepared(try! PreparedPendingCoachInvocation(preparing: request))
    }

    func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async {}

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome {
        .operationallyInterrupted(
            prepared.aggregate,
            prepared.request,
            .persistenceUnavailable
        )
    }

    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        .available
    }

    func tryInvoke(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationTryOutcome {
        retryRequest = request
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilRetryIsSuspended() async {
        while retryRequest == nil || continuation == nil { await Task.yield() }
    }

    func resume(with outcome: InvocationTryOutcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

private actor VanishingOperationalRetryInvocationGateway: Invocations {
    private(set) var requests: [PendingCoachInvocationRequest] = []

    func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
        .prepared(try! PreparedPendingCoachInvocation(preparing: request))
    }

    func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async {}

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome {
        await tryInvoke(prepared.request)
    }

    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        .available
    }

    func tryInvoke(_ request: PendingCoachInvocationRequest) async -> InvocationTryOutcome {
        requests.append(request)
        if requests.count == 1 {
            return .operationallyInterrupted(nil, request, .persistenceUnavailable)
        }
        return .rejected(nil, .eligibilityChanged)
    }
}

private actor ProjectedAdmissionInvocationGateway: Invocations {
    private var availability: InvocationAdmissionAvailability
    private(set) var requests: [PendingCoachInvocationRequest] = []

    init(availability: InvocationAdmissionAvailability) {
        self.availability = availability
    }

    func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
        .prepared(try! PreparedPendingCoachInvocation(preparing: request))
    }

    func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async {}

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome {
        await tryInvoke(prepared.request)
    }

    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        availability
    }

    func setAvailability(_ value: InvocationAdmissionAvailability) {
        availability = value
    }

    func tryInvoke(_ request: PendingCoachInvocationRequest) async -> InvocationTryOutcome {
        requests.append(request)
        return .interrupted(nil, .providerFailed)
    }
}

extension DefaultChatFeature {
    func sendCurrentNewChatConfirmation(_ context: ChatCommandContext) async {
        let token: NewChatConfirmationToken
        if case let .ready(snapshot) = currentState.newChatPicker,
           let currentToken = snapshot.confirmationToken
        {
            token = currentToken
        } else {
            token = NewChatConfirmationToken()
        }
        await send(.confirmNewChat(context, token))
    }
}

private let chatFeatureConfigurationStamp = CoachContextConfigurationStamp(
    authorityID: UUID(uuidString: "00000000-0000-0000-0000-000000000125")!,
    generation: 1
)
private let chatFeatureEvidenceAuthority = ChatCreationEvidenceAuthority(
    testingValue: UUID(uuidString: "00000000-0000-0000-0000-000000000225")!
)

private struct ChatFeatureBoundCoachContextFixture: ChatCoachContextCoordinating {
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

private actor ScriptedNewChatCoachContext: ChatCoachContextCoordinating {
    private let candidates: [ChatAttachmentCandidate]
    private let suspendCatalog: Bool
    private let suspendResolution: Bool
    private let suspendResolutionNoncooperatively: Bool
    private let suspendedQuoteNumber: Int?
    private let rejectsCreationLease: Bool
    private let suspendLeaseAcquisitionNoncooperatively: Bool
    private let suspendCreationLeaseReleaseNoncooperatively: Bool
    private var resolutionOutcomes: [ChatAttachmentResolutionOutcome]
    private var catalogStarted = false
    private var resolutionStarted = false
    private var resolutionContinuation: CheckedContinuation<Void, Never>?
    private var quoteStarted = false
    private var quoteCount = 0
    private var leaseAcquisitionStarted = false
    private var leaseAcquisitionContinuation: CheckedContinuation<Void, Never>?
    private var creationLeaseReleaseStarted = false
    private var creationLeaseReleaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var observedCancellation = false
    private(set) var resolutionCount = 0
    private(set) var creationLeaseReleaseCount = 0

    init(
        candidates: [ChatAttachmentCandidate] = [],
        suspendCatalog: Bool = false,
        suspendResolution: Bool = false,
        suspendResolutionNoncooperatively: Bool = false,
        suspendedQuoteNumber: Int? = nil,
        rejectsCreationLease: Bool = false,
        suspendLeaseAcquisitionNoncooperatively: Bool = false,
        suspendCreationLeaseReleaseNoncooperatively: Bool = false,
        resolutionOutcomes: [ChatAttachmentResolutionOutcome] = []
    ) {
        self.candidates = candidates
        self.suspendCatalog = suspendCatalog
        self.suspendResolution = suspendResolution
        self.suspendResolutionNoncooperatively = suspendResolutionNoncooperatively
        self.suspendedQuoteNumber = suspendedQuoteNumber
        self.rejectsCreationLease = rejectsCreationLease
        self.suspendLeaseAcquisitionNoncooperatively =
            suspendLeaseAcquisitionNoncooperatively
        self.suspendCreationLeaseReleaseNoncooperatively =
            suspendCreationLeaseReleaseNoncooperatively
        self.resolutionOutcomes = resolutionOutcomes
    }

    func loadAttachmentCandidates(
        in library: LibraryScope
    ) async -> ChatAttachmentCatalogOutcome {
        if suspendCatalog {
            catalogStarted = true
            await suspendUntilCancelled()
        }
        return .loaded(candidates, configuration: chatFeatureConfigurationStamp)
    }

    func resolveAttachments(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentResolutionOutcome {
        resolutionCount += 1
        if suspendResolutionNoncooperatively, !attachments.values.isEmpty {
            resolutionStarted = true
            await withCheckedContinuation { resolutionContinuation = $0 }
        } else if suspendResolution, !attachments.values.isEmpty {
            resolutionStarted = true
            await suspendUntilCancelled()
        }
        if !resolutionOutcomes.isEmpty {
            return resolutionOutcomes.removeFirst()
        }
        let resolved: [ResolvedChatAttachment] = attachments.values.compactMap {
            attachment in
            guard let candidate = candidates.first(where: {
                $0.sessionID == attachment.sessionID &&
                    $0.transcriptRevisionID == attachment.transcriptRevisionID
            }) else { return nil }
            return try? ResolvedChatAttachment(
                attachment: attachment,
                resolution: .available(candidate)
            )
        }
        guard resolved.count == attachments.values.count else { return .failed }
        return .resolved(resolved, configuration: chatFeatureConfigurationStamp)
    }

    func quoteNewChatBoundToConfiguration(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> ConfigurationBoundChatCreationQuoteOutcome {
        quoteCount += 1
        if quoteCount == suspendedQuoteNumber {
            quoteStarted = true
            await suspendUntilCancelled()
        }
        return .providerUnavailable(
            previouslyQualifiedProviderUnavailableCapacityLowerBound(),
            authority: ChatCreationQuoteAuthority(
                configuration: chatFeatureConfigurationStamp,
                evidence: chatFeatureEvidenceAuthority
            )
        )
    }

    func acquireNewChatCreationLease(
        _ authority: ChatCreationQuoteAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        guard authority.configuration == chatFeatureConfigurationStamp else {
            return .stale
        }
        guard !rejectsCreationLease else { return .stale }
        if suspendLeaseAcquisitionNoncooperatively {
            leaseAcquisitionStarted = true
            await withCheckedContinuation { leaseAcquisitionContinuation = $0 }
        }
        return .acquired(
            CoachContextAuthorityLease { [weak self] in
                await self?.releaseCreationLease()
            }
        )
    }

    func quoteNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> ChatCreationQuoteOutcome {
        .unavailable(.providerUnavailable)
    }

    func quoteChat(
        _ request: CoachContextChatQuoteRequest
    ) async -> CoachContextQuoteOutcome {
        .unavailable(.providerUnavailable)
    }

    func preparePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextPendingPreparationOutcome {
        .unavailable(.providerUnavailable)
    }

    func isPreparedContextCurrent(
        _ prepared: PreparedCoachLaunchContext
    ) async -> Bool {
        false
    }

    func waitUntilCatalogStarts() async {
        while !catalogStarted { await Task.yield() }
    }

    func waitUntilQuoteStarts() async {
        while !quoteStarted { await Task.yield() }
    }

    func waitUntilResolutionStarts() async {
        while !resolutionStarted { await Task.yield() }
    }

    func resumeResolution() {
        resolutionContinuation?.resume()
        resolutionContinuation = nil
    }

    func waitUntilLeaseAcquisitionStarts() async {
        while !leaseAcquisitionStarted { await Task.yield() }
    }

    func resumeLeaseAcquisition() {
        leaseAcquisitionContinuation?.resume()
        leaseAcquisitionContinuation = nil
    }

    func waitUntilCancellationIsObserved() async {
        while !observedCancellation { await Task.yield() }
    }

    func waitUntilCreationLeaseReleaseCount(_ count: Int) async {
        while creationLeaseReleaseCount < count { await Task.yield() }
    }

    func waitUntilCreationLeaseReleaseStarts() async {
        while !creationLeaseReleaseStarted { await Task.yield() }
    }

    func resumeCreationLeaseRelease() {
        creationLeaseReleaseContinuation?.resume()
        creationLeaseReleaseContinuation = nil
    }

    private func releaseCreationLease() async {
        creationLeaseReleaseStarted = true
        if suspendCreationLeaseReleaseNoncooperatively {
            await withCheckedContinuation {
                creationLeaseReleaseContinuation = $0
            }
        }
        creationLeaseReleaseCount += 1
    }

    private func suspendUntilCancelled() async {
        do {
            try await Task.sleep(nanoseconds: .max)
        } catch {
            observedCancellation = true
        }
    }
}

private actor AdvancingConfigurationChatContextFixture:
    ChatCoachContextCoordinating
{
    private let base: any CoachContextCoordinating
    private let authorityID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000225"
    )!
    private var generation: UInt64 = 1
    private var advanceRequested = false
    private var activeLeaseID: UUID?
    private var advancementWaiters: [CheckedContinuation<Void, Never>] = []

    init(base: any CoachContextCoordinating) {
        self.base = base
    }

    var currentGeneration: UInt64 { generation }

    func advanceConfiguration() async {
        advanceRequested = true
        if activeLeaseID != nil {
            await withCheckedContinuation { advancementWaiters.append($0) }
        }
        generation += 1
    }

    func waitUntilAdvanceIsRequested() async {
        while !advanceRequested { await Task.yield() }
    }

    func loadAttachmentCandidates(
        in library: LibraryScope
    ) async -> ChatAttachmentCatalogOutcome {
        .loaded([], configuration: stamp)
    }

    func resolveAttachments(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentResolutionOutcome {
        .resolved([], configuration: stamp)
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
                    configuration: stamp,
                    evidence: chatFeatureEvidenceAuthority
                )
            )
        case .unavailable(.providerUnavailable):
            return .providerUnavailable(
                previouslyQualifiedProviderUnavailableCapacityLowerBound(),
                authority: ChatCreationQuoteAuthority(
                    configuration: stamp,
                    evidence: chatFeatureEvidenceAuthority
                )
            )
        case let .unavailable(reason):
            return .unavailable(reason)
        }
    }

    func acquireNewChatCreationLease(
        _ authority: ChatCreationQuoteAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        guard activeLeaseID == nil, authority.configuration == stamp else {
            return .stale
        }
        let leaseID = UUID()
        activeLeaseID = leaseID
        return .acquired(
            CoachContextAuthorityLease { [weak self] in
                await self?.releaseLease(leaseID)
            }
        )
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

    private var stamp: CoachContextConfigurationStamp {
        CoachContextConfigurationStamp(
            authorityID: authorityID,
            generation: generation
        )
    }

    private func releaseLease(_ leaseID: UUID) {
        guard activeLeaseID == leaseID else { return }
        activeLeaseID = nil
        let waiters = advancementWaiters
        advancementWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private enum SuspendedCreateResult {
    case committed
    case attachmentUnavailable
}

private actor SuspendedCreateStore: ChatStorePort {
    private let coordinator: AdvancingConfigurationChatContextFixture?
    private let result: SuspendedCreateResult
    private var createStarted = false
    private var createContinuation: CheckedContinuation<Void, Never>?
    private(set) var configurationGenerationAtCommit: UInt64?
    private(set) var createSeeds: [NewChatSeed] = []

    init(coordinator: AdvancingConfigurationChatContextFixture) {
        self.coordinator = coordinator
        result = .committed
    }

    init(result: SuspendedCreateResult) {
        coordinator = nil
        self.result = result
    }

    func waitUntilCreateStarts() async {
        while !createStarted { await Task.yield() }
    }

    func resumeCreate() {
        createContinuation?.resume()
        createContinuation = nil
    }

    func loadCatalog(in library: LibraryScope) async -> ChatCatalogOutcome {
        .loaded([])
    }

    func create(_ commit: NewChatCommit) async -> ChatMutationOutcome {
        let seed = commit.seed
        createSeeds.append(seed)
        createStarted = true
        await withCheckedContinuation { createContinuation = $0 }
        if let coordinator {
            configurationGenerationAtCommit = await coordinator.currentGeneration
        }
        switch result {
        case .committed: return .committed(seed.aggregate)
        case .attachmentUnavailable: return .attachmentUnavailable
        }
    }

    func rename(_ mutation: RenameChatMutation) async -> ChatMutationOutcome { .failed }
    func saveDraft(_ mutation: SaveChatDraftMutation) async -> ChatMutationOutcome { .failed }
    func lockPendingUserTurn(
        _ mutation: LockPendingUserTurnMutation
    ) async -> ChatMutationOutcome { .failed }
    func replacePendingUserTurn(
        _ mutation: ReplacePendingUserTurnMutation
    ) async -> ChatMutationOutcome { .failed }
    func discardPendingUserTurn(
        _ mutation: DiscardPendingUserTurnMutation
    ) async -> ChatMutationOutcome { .failed }
    func load(_ chatID: ChatID, in library: LibraryScope) async -> ChatLoadOutcome {
        .missing
    }
}

private struct EmptyChatAttachmentSource: ChatSessionAttachmentSource {
    func loadCandidates(
        in library: LibraryScope
    ) async -> ChatAttachmentCatalogOutcome {
        .loaded([], configuration: chatFeatureConfigurationStamp)
    }

    func resolve(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentResolutionOutcome {
        .resolved([], configuration: chatFeatureConfigurationStamp)
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

    func create(_ commit: NewChatCommit) async -> ChatMutationOutcome { .failed }
    func rename(_ mutation: RenameChatMutation) async -> ChatMutationOutcome { .failed }
    func saveDraft(_ mutation: SaveChatDraftMutation) async -> ChatMutationOutcome { .failed }
    func lockPendingUserTurn(
        _ mutation: LockPendingUserTurnMutation
    ) async -> ChatMutationOutcome { .failed }
    func replacePendingUserTurn(
        _ mutation: ReplacePendingUserTurnMutation
    ) async -> ChatMutationOutcome { .failed }
    func discardPendingUserTurn(
        _ mutation: DiscardPendingUserTurnMutation
    ) async -> ChatMutationOutcome { .failed }
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

    func create(_ commit: NewChatCommit) async -> ChatMutationOutcome { .failed }
    func rename(_ mutation: RenameChatMutation) async -> ChatMutationOutcome { .failed }
    func saveDraft(_ mutation: SaveChatDraftMutation) async -> ChatMutationOutcome { .failed }
    func lockPendingUserTurn(
        _ mutation: LockPendingUserTurnMutation
    ) async -> ChatMutationOutcome { .failed }
    func replacePendingUserTurn(
        _ mutation: ReplacePendingUserTurnMutation
    ) async -> ChatMutationOutcome { .failed }
    func discardPendingUserTurn(
        _ mutation: DiscardPendingUserTurnMutation
    ) async -> ChatMutationOutcome { .failed }
    func load(_ chatID: ChatID, in library: LibraryScope) async -> ChatLoadOutcome { .missing }
}

private enum TestError: Error { case unexpectedState }

private struct AlwaysFitCoachContextSnapshotPort: CoachContextSnapshotPort {
    func resolveNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        do {
            return .resolved(
                try CoachContextResolvedSnapshot(
                    input: CoachContextQuoteInput(
                        profile: .object(["statements": .array([])]),
                        memory: .object([
                            "generalNotes": .string(""),
                            "sessionSummaries": .array([]),
                        ]),
                        creation: request.creation,
                        attachments: []
                    ),
                    configuration: configuration(),
                    authority: CoachContextSnapshotAuthority(
                        binding: .newChat(
                            library: request.library,
                            attachments: request.attachments,
                            creation: request.creation
                        ),
                        contextGeneration: 1,
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
    ) async -> CoachContextSnapshotOutcome {
        snapshot(
            for: request.draft,
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
            for: request.draft,
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
        for draft: ChatDraft,
        binding: CoachContextSnapshotBinding
    ) -> CoachContextSnapshotOutcome {
        do {
            return .resolved(
                try CoachContextResolvedSnapshot(
                    input: CoachContextQuoteInput(
                        profile: .object(["statements": .array([])]),
                        memory: .object([
                            "generalNotes": .string(""),
                            "sessionSummaries": .array([]),
                        ]),
                        history: [],
                        currentDraft: draft.text
                    ),
                    configuration: configuration(),
                    authority: CoachContextSnapshotAuthority(
                        binding: binding,
                        contextGeneration: 1,
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

    private func configuration() throws -> CoachContextConfiguration {
        try CoachContextConfiguration(
            descriptor: CoachProviderDescriptor(
                displayName: "Synthetic ChatFeature fixture",
                contextBudget: CoachContextBudget(
                    contextWindowTokens: 100_000,
                    responseReservedTokens: 32,
                    safetyMarginTokens: 8
                ),
                coachMemoryMaxTokens: 1
            ),
            policy: CoachProviderEstimationPolicy(
                providerIdentifier: "synthetic-chat-feature-v1",
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

private actor GrowingNewChatProfileSnapshotPort: CoachContextSnapshotPort {
    private var profileText = "Initial Profile"
    private var contextGeneration: UInt64 = 1
    private let configurationGeneration: UInt64 = 1
    private var activeLeaseID: UUID?
    private var oversizedProfilePending = false

    func installOversizedProfile() {
        guard activeLeaseID == nil else {
            oversizedProfilePending = true
            return
        }
        applyOversizedProfile()
    }

    func installExpandedProfile() {
        precondition(activeLeaseID == nil)
        profileText = String(repeating: "expanded-profile ", count: 8)
        contextGeneration += 1
    }

    private func applyOversizedProfile() {
        profileText = String(repeating: "expanded-profile ", count: 256)
        contextGeneration += 1
    }

    func resolveNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        do {
            return .resolved(
                try CoachContextResolvedSnapshot(
                    input: CoachContextQuoteInput(
                        profile: .object([
                            "statements": .array([.string(profileText)]),
                        ]),
                        memory: .object([
                            "generalNotes": .string(""),
                            "sessionSummaries": .array([]),
                        ]),
                        creation: request.creation,
                        attachments: []
                    ),
                    configuration: try configuration(),
                    authority: CoachContextSnapshotAuthority(
                        binding: .newChat(
                            library: request.library,
                            attachments: request.attachments,
                            creation: request.creation
                        ),
                        contextGeneration: contextGeneration,
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
        authority.contextGeneration == contextGeneration &&
            authority.configurationGeneration == configurationGeneration
    }

    func currentQualifiedConfiguration()
        async -> CoachQualifiedConfigurationOutcome
    {
        .knownQualified(
            configuration: try! configuration(),
            configurationGeneration: configurationGeneration
        )
    }

    func isCurrentConfiguration(_ generation: UInt64) async -> Bool {
        generation == configurationGeneration
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
        if oversizedProfilePending {
            oversizedProfilePending = false
            applyOversizedProfile()
        }
    }

    private func configuration() throws -> CoachContextConfiguration {
        try CoachContextConfiguration(
            descriptor: CoachProviderDescriptor(
                displayName: "Growing Profile fixture",
                contextBudget: CoachContextBudget(
                    contextWindowTokens: 2_000,
                    responseReservedTokens: 32,
                    safetyMarginTokens: 8
                ),
                coachMemoryMaxTokens: 1
            ),
            policy: CoachProviderEstimationPolicy(
                providerIdentifier: "growing-profile-fixture-v1",
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

private actor ProfileChangingCreateStore: ChatStorePort {
    private let source: GrowingNewChatProfileSnapshotPort
    private(set) var createSeeds: [NewChatSeed] = []

    init(source: GrowingNewChatProfileSnapshotPort) {
        self.source = source
    }

    func loadCatalog(in library: LibraryScope) async -> ChatCatalogOutcome {
        .loaded([])
    }

    func create(_ commit: NewChatCommit) async -> ChatMutationOutcome {
        let seed = commit.seed
        createSeeds.append(seed)
        guard createSeeds.count == 1 else { return .committed(seed.aggregate) }
        await source.installOversizedProfile()
        return .profileStatementGenerationChanged(9)
    }

    func rename(_ mutation: RenameChatMutation) async -> ChatMutationOutcome { .failed }
    func saveDraft(_ mutation: SaveChatDraftMutation) async -> ChatMutationOutcome { .failed }
    func lockPendingUserTurn(
        _ mutation: LockPendingUserTurnMutation
    ) async -> ChatMutationOutcome { .failed }
    func replacePendingUserTurn(
        _ mutation: ReplacePendingUserTurnMutation
    ) async -> ChatMutationOutcome { .failed }
    func discardPendingUserTurn(
        _ mutation: DiscardPendingUserTurnMutation
    ) async -> ChatMutationOutcome { .failed }
    func load(_ chatID: ChatID, in library: LibraryScope) async -> ChatLoadOutcome {
        .missing
    }
}

private actor RecordingChatStore: ChatStorePort {
    enum Call: Equatable {
        case loadCatalog, create, rename, load, saveDraft, lockPendingUserTurn,
             replacePendingUserTurn, discardPendingUserTurn
    }

    private let catalog: [ChatCatalogEntry]
    private var aggregates: [ChatID: ChatAggregate]
    private var createOutcomes: [ChatMutationOutcome]
    private var renameOutcomes: [ChatMutationOutcome]
    private var loadOutcomes: [ChatLoadOutcome]
    private var draftSaveOutcomes: [ChatMutationOutcome]
    private var suspendNextDraftSave: Bool
    private var draftSaveStarted = false
    private var draftSaveContinuation: CheckedContinuation<Void, Never>?
    private(set) var createSeeds: [NewChatSeed] = []
    private(set) var createCollisionAuthorityRetentions: [Bool] = []
    private(set) var calls: [Call] = []
    private(set) var loadedScopes: [LibraryScope] = []
    private(set) var savedDrafts: [SaveChatDraftMutation] = []
    private(set) var pendingLocks: [LockPendingUserTurnMutation] = []
    private(set) var pendingReplacements: [ReplacePendingUserTurnMutation] = []

    init(
        catalog: [ChatCatalogEntry] = [],
        createOutcomes: [ChatMutationOutcome] = [],
        renameOutcomes: [ChatMutationOutcome] = [],
        loadOutcomes: [ChatLoadOutcome] = [],
        draftSaveOutcomes: [ChatMutationOutcome] = [],
        suspendNextDraftSave: Bool = false
    ) {
        self.catalog = catalog
        aggregates = Dictionary(
            uniqueKeysWithValues: catalog.compactMap { entry in
                guard case let .available(aggregate) = entry else { return nil }
                return (aggregate.chat.id, aggregate)
            }
        )
        self.createOutcomes = createOutcomes
        self.renameOutcomes = renameOutcomes
        self.loadOutcomes = loadOutcomes
        self.draftSaveOutcomes = draftSaveOutcomes
        self.suspendNextDraftSave = suspendNextDraftSave
    }

    func loadCatalog(in library: LibraryScope) -> ChatCatalogOutcome {
        calls.append(.loadCatalog)
        loadedScopes.append(library)
        return .loaded(catalog.map { entry in
            guard case let .available(original) = entry,
                  let current = aggregates[original.chat.id]
            else { return entry }
            return .available(current)
        })
    }

    func create(_ commit: NewChatCommit) -> ChatMutationOutcome {
        let seed = commit.seed
        calls.append(.create)
        createSeeds.append(seed)
        createCollisionAuthorityRetentions.append(
            commit.retainsEvidenceAuthorityOnCollision
        )
        if !createOutcomes.isEmpty { return createOutcomes.removeFirst() }
        aggregates[seed.aggregate.chat.id] = seed.aggregate
        return .committed(seed.aggregate)
    }

    func rename(_ mutation: RenameChatMutation) -> ChatMutationOutcome {
        calls.append(.rename)
        if !renameOutcomes.isEmpty { return renameOutcomes.removeFirst() }
        aggregates[mutation.chatID] = mutation.replacement
        return .committed(mutation.replacement)
    }

    func saveDraft(_ mutation: SaveChatDraftMutation) async -> ChatMutationOutcome {
        calls.append(.saveDraft)
        savedDrafts.append(mutation)
        if suspendNextDraftSave {
            suspendNextDraftSave = false
            draftSaveStarted = true
            await withCheckedContinuation { draftSaveContinuation = $0 }
        }
        if !draftSaveOutcomes.isEmpty { return draftSaveOutcomes.removeFirst() }
        guard let existing = aggregates[mutation.chatID] else { return .failed }
        guard existing.pendingUserTurn == nil,
              mutation.replacement.draftID == existing.chat.draft.draftID
        else { return .stale(existing) }
        if mutation.replacement.version < existing.chat.draft.version {
            return .stale(existing)
        }
        if mutation.replacement.version == existing.chat.draft.version {
            return mutation.replacement == existing.chat.draft
                ? .committed(existing)
                : .stale(existing)
        }
        guard
              let chat = try? existing.chat.replacingDraft(with: mutation.replacement),
              let committed = try? ChatAggregate(
                  chat: chat,
                  memory: existing.memory,
                  pendingUserTurn: existing.pendingUserTurn
              )
        else {
            return .failed
        }
        aggregates[mutation.chatID] = committed
        return .committed(committed)
    }

    func waitUntilDraftSaveStarts() async {
        while !draftSaveStarted { await Task.yield() }
    }

    func resumeDraftSave() {
        draftSaveContinuation?.resume()
        draftSaveContinuation = nil
    }

    func lockPendingUserTurn(
        _ mutation: LockPendingUserTurnMutation
    ) -> ChatMutationOutcome {
        calls.append(.lockPendingUserTurn)
        pendingLocks.append(mutation)
        guard let current = aggregates[mutation.chatID],
              current.pendingUserTurn == nil,
              current.chat.draft.draftID == mutation.pendingUserTurn.draftID,
              current.chat.draft.version == mutation.pendingUserTurn.draftVersion,
              let locked = try? ChatAggregate(
                  chat: current.chat,
                  memory: current.memory,
                  pendingUserTurn: mutation.pendingUserTurn
              )
        else {
            return aggregates[mutation.chatID].map(ChatMutationOutcome.stale) ?? .failed
        }
        aggregates[mutation.chatID] = locked
        return .committed(locked)
    }

    func replacePendingUserTurn(
        _ mutation: ReplacePendingUserTurnMutation
    ) -> ChatMutationOutcome {
        calls.append(.replacePendingUserTurn)
        pendingReplacements.append(mutation)
        guard let current = aggregates[mutation.chatID] else { return .failed }
        if current.pendingUserTurn == mutation.replacement { return .committed(current) }
        guard current.pendingUserTurn == mutation.base,
              let replaced = try? ChatAggregate(
                  chat: current.chat,
                  memory: current.memory,
                  pendingUserTurn: mutation.replacement
              )
        else {
            return .stale(current)
        }
        aggregates[mutation.chatID] = replaced
        return .committed(replaced)
    }

    func discardPendingUserTurn(
        _ mutation: DiscardPendingUserTurnMutation
    ) -> ChatMutationOutcome {
        calls.append(.discardPendingUserTurn)
        guard let current = aggregates[mutation.chatID],
              current.pendingUserTurn == mutation.pendingUserTurn,
              let unlocked = try? ChatAggregate(
                  chat: current.chat,
                  memory: current.memory
              )
        else {
            return aggregates[mutation.chatID].map(ChatMutationOutcome.stale) ?? .failed
        }
        aggregates[mutation.chatID] = unlocked
        return .committed(unlocked)
    }

    func waitForSavedDraftCount(_ count: Int) async {
        while savedDrafts.count < count { await Task.yield() }
    }

    func load(_ chatID: ChatID, in library: LibraryScope) -> ChatLoadOutcome {
        calls.append(.load)
        if !loadOutcomes.isEmpty { return loadOutcomes.removeFirst() }
        if let value = aggregates[chatID] { return .loaded(value) }
        return .missing
    }

}

private struct FixedProfileReader: ProfileStatementGenerationReading {
    func statementGeneration(in library: LibraryScope) async -> UInt64? { 7 }
}

private struct MissingProfileReader: ProfileStatementGenerationReading {
    func statementGeneration(in library: LibraryScope) async -> UInt64? { nil }
}

private actor NoncooperativeProfileReader: ProfileStatementGenerationReading {
    private var continuation: CheckedContinuation<UInt64?, Never>?

    func statementGeneration(in library: LibraryScope) async -> UInt64? {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilReadStarts() async {
        while continuation == nil { await Task.yield() }
    }

    func resume() {
        continuation?.resume(returning: 7)
        continuation = nil
    }
}

private actor SequencedProfileReader: ProfileStatementGenerationReading {
    private var generations: [UInt64]

    init(generations: [UInt64]) {
        self.generations = generations
    }

    func statementGeneration(in library: LibraryScope) async -> UInt64? {
        guard !generations.isEmpty else { return nil }
        return generations.removeFirst()
    }
}

private struct FixedChatClock: ChatClock {
    func now() async -> UTCInstant { try! UTCInstant("2026-08-30T12:00:00.000Z") }
}

private actor NoncooperativeNewChatClock: ChatClock {
    private let instant = try! UTCInstant("2026-08-30T12:00:00.000Z")
    private var continuation: CheckedContinuation<UTCInstant, Never>?

    func now() async -> UTCInstant {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilReadStarts() async {
        while continuation == nil { await Task.yield() }
    }

    func resume() {
        continuation?.resume(returning: instant)
        continuation = nil
    }
}

private actor SuspendedFirstChatClock: ChatClock {
    private let instant = try! UTCInstant("2026-08-30T12:00:00.000Z")
    private var requestCount = 0
    private var firstContinuation: CheckedContinuation<UTCInstant, Never>?

    func now() async -> UTCInstant {
        requestCount += 1
        guard requestCount == 1 else { return instant }
        return await withCheckedContinuation { firstContinuation = $0 }
    }

    func waitUntilFirstRequestIsSuspended() async {
        while firstContinuation == nil { await Task.yield() }
    }

    func resumeFirstRequest() {
        firstContinuation?.resume(returning: instant)
        firstContinuation = nil
    }
}

private struct FixedChatIDs:
    ChatIDGenerator,
    ChatDraftIDGenerator,
    CoachMemoryIDGenerator,
    PendingUserTurnIDGenerator,
    ChatResponsePositionIDGenerator
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

private actor NoncooperativeNewChatIdentifiers:
    ChatIDGenerator,
    ChatDraftIDGenerator,
    CoachMemoryIDGenerator
{
    private var chatContinuation: CheckedContinuation<ChatID, Never>?

    func generateChatID(at instant: UTCInstant) async -> ChatID {
        await withCheckedContinuation { chatContinuation = $0 }
    }

    func generateChatDraftID(at instant: UTCInstant) async -> ChatDraftID {
        try! ChatDraftID("drf-20260830T120000000Z-3DEF")
    }

    func generateCoachMemoryID(at instant: UTCInstant) async -> CoachMemoryID {
        try! CoachMemoryID("mem-20260830T120000000Z-4GHJ")
    }

    func waitUntilChatIDRequestStarts() async {
        while chatContinuation == nil { await Task.yield() }
    }

    func resumeChatIDRequest() {
        chatContinuation?.resume(
            returning: try! ChatID("cht-20260830T120000000Z-2ABC")
        )
        chatContinuation = nil
    }
}

private actor CompletionProbe<Value: Sendable> {
    private(set) var value: Value?

    func complete(_ value: Value) {
        self.value = value
    }

    func completesWithinYieldBudget(_ budget: Int = 10_000) async -> Bool {
        for _ in 0 ..< budget {
            if value != nil { return true }
            await Task.yield()
        }
        return value != nil
    }
}

private struct ImmediateChatAutosaveScheduler: ChatAutosaveScheduling {
    func sleep(forNanoseconds nanoseconds: UInt64) async throws {}
}

private struct ImmediateChatTransientNoticeScheduler:
    ChatTransientNoticeScheduling
{
    func sleep(forNanoseconds nanoseconds: UInt64) async throws {}
}

private struct ImmediateAdmissionRefreshScheduler: ChatAdmissionRefreshScheduling {
    func sleep(until deadline: UTCInstant) async throws {}
}

private actor ControlledAdmissionRefreshScheduler: ChatAdmissionRefreshScheduling {
    private(set) var deadlines: [UTCInstant] = []
    private var continuation: CheckedContinuation<Void, Error>?

    func sleep(until deadline: UTCInstant) async throws {
        deadlines.append(deadline)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilScheduled() async {
        while deadlines.isEmpty { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    private func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private actor ControlledChatAutosaveScheduler: ChatAutosaveScheduling {
    private(set) var requestedNanoseconds: [UInt64] = []
    private var continuation: CheckedContinuation<Void, Error>?

    func sleep(forNanoseconds nanoseconds: UInt64) async throws {
        requestedNanoseconds.append(nanoseconds)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilScheduled() async {
        while requestedNanoseconds.isEmpty { await Task.yield() }
    }

    func waitForScheduleCount(_ count: Int) async {
        while requestedNanoseconds.count < count { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    private func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private actor ControlledChatTransientNoticeScheduler:
    ChatTransientNoticeScheduling
{
    private(set) var requestedNanoseconds: [UInt64] = []
    private var continuation: CheckedContinuation<Void, Error>?

    func sleep(forNanoseconds nanoseconds: UInt64) async throws {
        requestedNanoseconds.append(nanoseconds)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilScheduled() async {
        while requestedNanoseconds.isEmpty { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    private func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private actor SuspendedPendingUserTurnIDGenerator: PendingUserTurnIDGenerator {
    private var continuation: CheckedContinuation<Void, Never>?
    private var wasRequested = false

    func generatePendingUserTurnID(at instant: UTCInstant) async -> PendingUserTurnID {
        wasRequested = true
        await withCheckedContinuation { continuation = $0 }
        return try! PendingUserTurnID("ptu-20260830T120000000Z-5KMN")
    }

    func waitUntilRequested() async {
        while !wasRequested { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ChatStateRecorder {
    private var states: [ChatFeatureState] = []

    func append(_ state: ChatFeatureState) {
        states.append(state)
    }

    func waitForStateCount(_ count: Int) async {
        while states.count < count { await Task.yield() }
    }

    func waitUntilActivity(_ activity: ChatFeatureState.Activity) async {
        while !states.contains(where: { $0.activity == activity }) {
            await Task.yield()
        }
    }

    func activitiesAfterFirst(
        _ activity: ChatFeatureState.Activity
    ) -> [ChatFeatureState.Activity?] {
        guard let index = states.firstIndex(where: { $0.activity == activity }) else {
            return []
        }
        return states[index...].map(\.activity)
    }
}
