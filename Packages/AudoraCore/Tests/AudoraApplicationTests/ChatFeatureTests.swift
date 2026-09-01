@testable @_spi(CoachContextQualification) import AudoraApplication
import AudoraDomain
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

    func testCreateRebuildsAgainstTheProfileGenerationObservedAtInstall() async throws {
        let store = RecordingChatStore(
            createOutcomes: [.profileStatementGenerationChanged(9)]
        )
        let feature = makeFeature(store: store)
        await feature.send(.start(Self.context))

        await feature.send(.beginNewChat(Self.context))
        await feature.send(.confirmNewChat(Self.context))

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

        await feature.send(.beginNewChat(Self.context))
        await feature.send(.confirmNewChat(Self.context))

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

        await feature.send(.beginNewChat(Self.context))
        await feature.send(.confirmNewChat(Self.context))

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
        clock: any ChatClock = FixedChatClock(),
        pendingUserTurnIDGenerator: any PendingUserTurnIDGenerator = FixedChatIDs(),
        autosaveScheduler: any ChatAutosaveScheduling = ImmediateChatAutosaveScheduler()
    ) -> DefaultChatFeature {
        DefaultChatFeature(
            store: store,
            profileReader: FixedProfileReader(),
            clock: clock,
            chatIDGenerator: FixedChatIDs(),
            draftIDGenerator: FixedChatIDs(),
            memoryIDGenerator: FixedChatIDs(),
            pendingUserTurnIDGenerator: pendingUserTurnIDGenerator,
            responsePositionIDGenerator: FixedChatIDs(),
            autosaveScheduler: autosaveScheduler,
            coachContext: DefaultCoachContextFeature(
                source: AlwaysFitCoachContextSnapshotPort()
            ),
            attachmentSource: EmptyChatAttachmentSource()
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

    private static func editableDraft(
        in feature: DefaultChatFeature
    ) async throws -> ChatDraft {
        guard case let .editable(draft, _) = await feature.currentState.composer else {
            throw TestError.unexpectedState
        }
        return draft
    }
}

private struct EmptyChatAttachmentSource: ChatSessionAttachmentSource {
    func loadCandidates(
        in library: LibraryScope
    ) async -> ChatAttachmentCatalogOutcome {
        .loaded([])
    }

    func resolve(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentResolutionOutcome {
        .resolved([])
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

    func create(_ seed: NewDevelopmentChatSeed) async -> ChatMutationOutcome { .failed }
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
    private(set) var createSeeds: [NewDevelopmentChatSeed] = []
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

    func create(_ seed: NewDevelopmentChatSeed) -> ChatMutationOutcome {
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

private struct FixedChatClock: ChatClock {
    func now() async -> UTCInstant { try! UTCInstant("2026-08-30T12:00:00.000Z") }
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
