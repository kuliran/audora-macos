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
            .editDraft(Self.context, text: "First synthetic keystroke")
        )
        await clock.waitUntilFirstRequestIsSuspended()

        await feature.send(
            .editDraft(Self.context, text: "First synthetic keystroke, then the rest")
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

    func testSendQueuedBehindSuspendedEditLocksThatExactDraft() async throws {
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
            .editDraft(Self.context, text: "Send this complete synthetic Draft.")
        )
        await clock.waitUntilFirstRequestIsSuspended()
        await feature.send(.sendDraft(Self.context))
        await clock.resumeFirstRequest()
        await edit

        let state = await feature.currentState
        guard case let .locked(draft, pending) = state.composer else {
            return XCTFail("expected queued Send to lock the Draft")
        }
        XCTAssertEqual(draft.text, "Send this complete synthetic Draft.")
        XCTAssertEqual(draft.version, 1)
        XCTAssertEqual(pending.draftID, draft.draftID)
        XCTAssertEqual(pending.draftVersion, draft.version)
        let calls = await store.calls
        XCTAssertEqual(calls, [.loadCatalog, .load, .saveDraft, .lockPendingUserTurn])
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
            .editDraft(Self.context, text: "Flush before opening the second Chat.")
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
            .editDraft(Self.context, text: "Belongs only to the first Chat.")
        )
        await clock.waitUntilFirstRequestIsSuspended()
        await feature.send(.open(Self.context, second.chat.id))
        await feature.send(
            .editDraft(Self.context, text: "Stale text must not cross Chat identity.")
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
            .editDraft(Self.context, text: "Flush before orderly termination.")
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
            .editDraft(Self.context, text: "Keep this exact synthetic Draft.")
        )
        await scheduler.waitUntilScheduled()

        await feature.send(.sendDraft(Self.context))

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

    func testDiscardUnlocksTheSamePopulatedDraftWithoutAbandonmentHistory() async throws {
        let aggregate = try Self.aggregate()
        let store = RecordingChatStore(catalog: [.available(aggregate)])
        let scheduler = ControlledChatAutosaveScheduler()
        let feature = makeFeature(store: store, autosaveScheduler: scheduler)
        await feature.send(.start(Self.context))
        await feature.send(.open(Self.context, aggregate.chat.id))
        await feature.send(.editDraft(Self.context, text: "Do not abandon this Draft."))
        await scheduler.waitUntilScheduled()
        await feature.send(.sendDraft(Self.context))
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
        await feature.send(.editDraft(Self.context, text: "Flush me before navigation."))
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
        await feature.send(.editDraft(Self.context, text: "Library A durable text"))
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
        await feature.send(.editDraft(Self.context, text: "stale model must be ignored"))

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
        autosaveScheduler: any ChatAutosaveScheduling = ImmediateChatAutosaveScheduler()
    ) -> DefaultChatFeature {
        DefaultChatFeature(
            store: store,
            profileReader: FixedProfileReader(),
            clock: clock,
            chatIDGenerator: FixedChatIDs(),
            draftIDGenerator: FixedChatIDs(),
            memoryIDGenerator: FixedChatIDs(),
            pendingUserTurnIDGenerator: FixedChatIDs(),
            responsePositionIDGenerator: FixedChatIDs(),
            autosaveScheduler: autosaveScheduler
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
    func saveDraft(_ mutation: SaveChatDraftMutation) async -> ChatMutationOutcome { .failed }
    func lockPendingUserTurn(
        _ mutation: LockPendingUserTurnMutation
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
    func discardPendingUserTurn(
        _ mutation: DiscardPendingUserTurnMutation
    ) async -> ChatMutationOutcome { .failed }
    func load(_ chatID: ChatID, in library: LibraryScope) async -> ChatLoadOutcome { .missing }
}

private enum TestError: Error { case unexpectedState }

private actor RecordingChatStore: ChatStorePort {
    enum Call: Equatable {
        case loadCatalog, create, rename, load, saveDraft, lockPendingUserTurn,
             discardPendingUserTurn
    }

    private let catalog: [ChatCatalogEntry]
    private var aggregates: [ChatID: ChatAggregate]
    private var createOutcomes: [ChatMutationOutcome]
    private var renameOutcomes: [ChatMutationOutcome]
    private var loadOutcomes: [ChatLoadOutcome]
    private var suspendNextDraftSave: Bool
    private var draftSaveStarted = false
    private var draftSaveContinuation: CheckedContinuation<Void, Never>?
    private(set) var createSeeds: [NewDevelopmentChatSeed] = []
    private(set) var calls: [Call] = []
    private(set) var loadedScopes: [LibraryScope] = []
    private(set) var savedDrafts: [SaveChatDraftMutation] = []
    private(set) var pendingLocks: [LockPendingUserTurnMutation] = []

    init(
        catalog: [ChatCatalogEntry] = [],
        createOutcomes: [ChatMutationOutcome] = [],
        renameOutcomes: [ChatMutationOutcome] = [],
        loadOutcomes: [ChatLoadOutcome] = [],
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

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    private func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
