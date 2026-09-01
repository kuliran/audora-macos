@testable @_spi(CoachContextQualification) import AudoraApplication
import AudoraDomain
import Foundation
import XCTest

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class ChatFeatureTests: XCTestCase {
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

        await feature.send(.confirmNewChat(firstContext))

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
        await feature.send(.confirmNewChat(Self.context))

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
        await feature.send(.confirmNewChat(Self.context))

        let seedCount = await store.createSeeds.count
        let state = await feature.currentState
        XCTAssertEqual(seedCount, 3)
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
        await feature.send(.confirmNewChat(Self.context))

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

        await feature.send(.confirmNewChat(Self.context))

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

        await feature.send(.confirmNewChat(Self.context))

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

        await feature.send(.confirmNewChat(Self.context))

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

        await feature.send(.confirmNewChat(Self.context))

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

        await feature.send(.confirmNewChat(Self.context))

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
        await feature.send(.confirmNewChat(Self.context))

        let firstConfirmationSeeds = await store.createSeeds
        XCTAssertEqual(
            firstConfirmationSeeds.map(
                \.aggregate.chat.profileStatementGenerationAtCreation
            ),
            [7]
        )

        await feature.send(.confirmNewChat(Self.context))

        let secondConfirmationSeeds = await store.createSeeds
        XCTAssertEqual(
            secondConfirmationSeeds.map(
                \.aggregate.chat.profileStatementGenerationAtCreation
            ),
            [7, 8]
        )

        await feature.send(.confirmNewChat(Self.context))

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

        async let confirmation: Void = feature.send(.confirmNewChat(Self.context))
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

        async let confirmation: Void = feature.send(.confirmNewChat(Self.context))
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

        async let quoting: Void = feature.send(.confirmNewChat(Self.context))
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

        async let resolving: Void = feature.send(.confirmNewChat(Self.context))
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

        async let resolving: Void = feature.send(.confirmNewChat(Self.context))
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
            await feature.send(.confirmNewChat(context))
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
            await feature.send(.confirmNewChat(context))
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
            await feature.send(.confirmNewChat(context))
            await confirmation.complete(())
        }
        await profile.waitUntilReadStarts()
        await feature.send(.cancelNewChat(context))

        let confirmationCompleted = await confirmation.completesWithinYieldBudget()
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
            await feature.send(.confirmNewChat(context))
            await confirmation.complete(())
        }
        await clock.waitUntilReadStarts()
        let stateBeforeCancel = await feature.currentState
        XCTAssertNil(stateBeforeCancel.activity)
        await feature.send(.cancelNewChat(context))

        let confirmationCompleted = await confirmation.completesWithinYieldBudget()
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
            await feature.send(.confirmNewChat(context))
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

        await feature.send(.confirmNewChat(Self.context))

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

        async let confirmation: Void = feature.send(.confirmNewChat(Self.context))
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
        let feature = makeFeature(store: store, autosaveScheduler: scheduler)
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
        XCTAssertEqual(calls, [.loadCatalog, .load, .saveDraft, .lockPendingUserTurn])
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

    private func makeFeature(
        store: any ChatStorePort,
        profileReader: any ProfileStatementGenerationReading = FixedProfileReader(),
        clock: any ChatClock = FixedChatClock(),
        chatIDGenerator: any ChatIDGenerator = FixedChatIDs(),
        draftIDGenerator: any ChatDraftIDGenerator = FixedChatIDs(),
        memoryIDGenerator: any CoachMemoryIDGenerator = FixedChatIDs(),
        pendingUserTurnIDGenerator: any PendingUserTurnIDGenerator = FixedChatIDs(),
        autosaveScheduler: any ChatAutosaveScheduling = ImmediateChatAutosaveScheduler(),
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
            coachContext: coachContext
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

private let chatFeatureConfigurationStamp = CoachContextConfigurationStamp(
    authorityID: UUID(uuidString: "00000000-0000-0000-0000-000000000125")!,
    generation: 1
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

    func isCurrentAttachmentConfiguration(
        _ stamp: CoachContextConfigurationStamp
    ) async -> Bool {
        await base.isCurrentAttachmentConfiguration(stamp)
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
}

private actor ScriptedNewChatCoachContext: ChatCoachContextCoordinating {
    private let candidates: [ChatAttachmentCandidate]
    private let suspendCatalog: Bool
    private let suspendResolution: Bool
    private let suspendResolutionNoncooperatively: Bool
    private let suspendedQuoteNumber: Int?
    private let rejectsCreationLease: Bool
    private let suspendLeaseAcquisitionNoncooperatively: Bool
    private var resolutionOutcomes: [ChatAttachmentResolutionOutcome]
    private var catalogStarted = false
    private var resolutionStarted = false
    private var resolutionContinuation: CheckedContinuation<Void, Never>?
    private var quoteStarted = false
    private var quoteCount = 0
    private var leaseAcquisitionStarted = false
    private var leaseAcquisitionContinuation: CheckedContinuation<Void, Never>?
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
            authority: ChatCreationQuoteAuthority(
                configuration: chatFeatureConfigurationStamp
            )
        )
    }

    func isCurrentAttachmentConfiguration(
        _ stamp: CoachContextConfigurationStamp
    ) async -> Bool {
        stamp == chatFeatureConfigurationStamp
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
                await self?.recordCreationLeaseRelease()
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

    private func recordCreationLeaseRelease() {
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
        switch await base.quoteNewChat(request) {
        case let .available(quote):
            return .available(
                quote,
                authority: ChatCreationQuoteAuthority(configuration: stamp)
            )
        case .unavailable(.providerUnavailable):
            return .providerUnavailable(
                authority: ChatCreationQuoteAuthority(configuration: stamp)
            )
        case let .unavailable(reason):
            return .unavailable(reason)
        }
    }

    func isCurrentAttachmentConfiguration(
        _ candidate: CoachContextConfigurationStamp
    ) async -> Bool {
        candidate == stamp
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

    func create(_ seed: NewChatSeed) async -> ChatMutationOutcome {
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

    func create(_ seed: NewChatSeed) async -> ChatMutationOutcome { .failed }
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

    func create(_ seed: NewChatSeed) async -> ChatMutationOutcome { .failed }
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
                        configurationGeneration: 1
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
                        configurationGeneration: configurationGeneration
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

    func currentAttachmentProjectionPolicy()
        async -> CoachAttachmentProjectionPolicyOutcome
    {
        .knownQualified(
            policy: try! CoachAttachmentProjectionPolicy(
                maximumInlineTranscriptTokens: 8_192,
                tokenEstimator: .utf8ByteUpperBound()
            ),
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
                    contextWindowTokens: 512,
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

    func create(_ seed: NewChatSeed) async -> ChatMutationOutcome {
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

    func create(_ seed: NewChatSeed) -> ChatMutationOutcome {
        calls.append(.create)
        createSeeds.append(seed)
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
