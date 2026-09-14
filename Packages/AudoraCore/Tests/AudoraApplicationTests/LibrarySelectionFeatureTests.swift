@testable @_spi(InvocationTesting) import AudoraApplication
import AudoraDomain
import XCTest

private struct UnusedReviewFeature: ReviewFeature {
    let currentState = ReviewFeatureState.unavailable(
        selection: nil,
        reason: .noSession
    )
    let states = AsyncStream<ReviewFeatureState> { $0.finish() }

    func send(_ command: ReviewCommand) async {}
    func reserveLibraryNavigation() async -> Bool { true }
    func finishLibraryNavigation(_ result: LibraryCommandResult) async {}
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@MainActor
final class ApplicationCommandFeatureTests: XCTestCase {
    func testChatBoundaryRejectsDirectProcessingStartAndRetry() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedBoundaryChatFeature(trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let processing = NavigationActivationProcessingProbe()
        let feature = DefaultApplicationCommandFeature(
            library: library,
            chat: chat,
            sessionProcessing: processing
        )
        let context = ChatCommandContext(
            libraryScope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        let chatID = try ChatID("cht-20260830T120000000Z-2ABC")

        let boundary = feature.enqueue(.open(context, chatID))
        await chat.waitUntilCommandStarts()

        XCTAssertFalse(
            feature.isSessionProcessingCommandAdmitted(.start)
        )
        XCTAssertFalse(
            feature.isSessionProcessingCommandAdmitted(.retry)
        )
        let startWasAdmitted = await feature.send(SessionProcessingCommand.start)
        let retryWasAdmitted = await feature.send(SessionProcessingCommand.retry)
        XCTAssertFalse(startWasAdmitted)
        XCTAssertFalse(retryWasAdmitted)
        let processingCommands = await processing.commands
        XCTAssertEqual(processingCommands, [])

        await chat.resume()
        await boundary.value

        let startAfterBoundary = await feature.send(SessionProcessingCommand.start)
        XCTAssertTrue(startAfterBoundary)
        let commandsAfterBoundary = await processing.commands
        XCTAssertEqual(commandsAfterBoundary, [.start])
    }

    func testChatBoundaryAdmitsDirectProcessingCancel() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedBoundaryChatFeature(trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let processing = NavigationActivationProcessingProbe()
        let feature = DefaultApplicationCommandFeature(
            library: library,
            chat: chat,
            sessionProcessing: processing
        )
        let context = ChatCommandContext(
            libraryScope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        let chatID = try ChatID("cht-20260830T120000000Z-2ABC")
        let processingSelection = SessionProcessingSelection(
            scope: context.libraryScope,
            sessionID: try SessionID("ses-20260830T120100000Z-2CDE")
        )

        let boundary = feature.enqueue(.open(context, chatID))
        await chat.waitUntilCommandStarts()

        XCTAssertTrue(
            feature.isSessionProcessingCommandAdmitted(.cancel)
        )
        XCTAssertTrue(
            feature.isSessionProcessingCommandAdmitted(
                .selectSession(processingSelection)
            )
        )
        XCTAssertTrue(
            feature.isSessionProcessingCommandAdmitted(.clearSelection)
        )
        let selectionWasAdmitted = await feature.send(
            .selectSession(processingSelection)
        )
        let clearWasAdmitted = await feature.send(.clearSelection)
        let cancelWasAdmitted = await feature.send(SessionProcessingCommand.cancel)
        XCTAssertTrue(selectionWasAdmitted)
        XCTAssertTrue(clearWasAdmitted)
        XCTAssertTrue(cancelWasAdmitted)
        let processingCommands = await processing.commands
        XCTAssertEqual(
            processingCommands,
            [.selectSession(processingSelection), .clearSelection, .cancel]
        )

        await chat.resume()
        await boundary.value
    }

    func testChatBoundaryAdmissionIsSynchronousAndRejectsLateDraftMutation() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedBoundaryChatFeature(trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)
        var admissionStates = feature.admissionStates.makeAsyncIterator()
        let initialAdmission = await admissionStates.next()
        XCTAssertEqual(initialAdmission, .idle)
        let context = ChatCommandContext(
            libraryScope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        let chatID = try ChatID("cht-20260830T120000000Z-2ABC")
        let draftID = try ChatDraftID("drf-20260830T120000000Z-3DEF")

        let boundary = feature.enqueue(.open(context, chatID))
        XCTAssertEqual(
            feature.admissionState,
            ApplicationCommandAdmissionState(isChatBoundaryPending: true)
        )
        let pendingAdmission = await admissionStates.next()
        XCTAssertEqual(pendingAdmission, feature.admissionState)
        await chat.waitUntilCommandStarts()

        let lateEdit = feature.enqueue(
            .editDraft(context, chatID, draftID, text: "must be rejected")
        )
        await lateEdit.value
        let commandsWhileSuspended = await chat.commands
        XCTAssertEqual(commandsWhileSuspended, [.open(context, chatID)])

        await chat.resume()
        await boundary.value
        XCTAssertEqual(feature.admissionState, .idle)
        let finalAdmission = await admissionStates.next()
        XCTAssertEqual(finalAdmission, .idle)
    }

    func testNewChatConfirmationBeginsAnApplicationBoundary() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedBoundaryChatFeature(trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)
        let context = ChatCommandContext(
            libraryScope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        let token = NewChatConfirmationToken()

        let boundary = feature.enqueue(.confirmNewChat(context, token))

        XCTAssertTrue(feature.admissionState.isChatBoundaryPending)
        await chat.waitUntilCommandStarts()
        let commandsWhileSuspended = await chat.commands
        XCTAssertEqual(commandsWhileSuspended, [.confirmNewChat(context, token)])
        await chat.resume()
        await boundary.value
        XCTAssertEqual(feature.admissionState, .idle)
    }

    func testNewChatCancelBypassesSuspendedConfirmationInApplicationFIFO() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedNewChatPickerApplicationChatFeature()
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)
        let context = ChatCommandContext(
            libraryScope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        let token = NewChatConfirmationToken()

        let confirmation = feature.enqueue(.confirmNewChat(context, token))
        XCTAssertTrue(feature.admissionState.isChatBoundaryPending)
        await chat.waitUntilConfirmationStarts()
        let cancel = feature.enqueue(.cancelNewChat(context))
        for _ in 0..<100 { await Task.yield() }
        let deliveredWhileConfirmationWasSuspended = await chat.cancelReceived
        if !deliveredWhileConfirmationWasSuspended {
            await chat.forceResumeConfirmation()
        }
        await cancel.value
        await confirmation.value

        XCTAssertTrue(deliveredWhileConfirmationWasSuspended)
        XCTAssertFalse(feature.admissionState.isChatBoundaryPending)
        let commands = await chat.commands
        XCTAssertEqual(
            commands,
            [.confirmNewChat(context, token), .cancelNewChat(context)]
        )
    }

    func testCoachStopBypassesSuspendedSendInApplicationFIFO() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedCoachApplicationChatFeature()
        let feature = DefaultApplicationCommandFeature(
            library: SelectionLibraryFeature(trace: trace),
            chat: chat
        )
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let context = ChatCommandContext(libraryScope: scope, generation: 1)
        let chatID = try ChatID("cht-20260830T120000000Z-2ABC")
        let pendingID = try PendingUserTurnID(
            "ptu-20260830T120000000Z-5KMN"
        )
        let draft = try ChatDraft(
            draftID: ChatDraftID("drf-20260830T120000000Z-3DEF"),
            version: 0,
            text: "Stop while this Send is suspended.",
            updatedAt: UTCInstant("2026-08-30T12:00:00.000Z")
        )
        let authority = InvocationStopAuthority(
            testingRequest: StopCoachInvocationRequest(
                library: scope,
                chatID: chatID,
                pendingUserTurnID: pendingID
            ),
            invocationID: try CoachInvocationID(
                "inv-20260830T120000000Z-5KMN"
            ),
            attemptID: try CoachProviderAttemptID(
                "atm-20260830T120000000Z-6NPQ"
            ),
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000397"
            )!
        )

        let send = feature.enqueue(.sendDraft(context, chatID, draft))
        XCTAssertTrue(feature.admissionState.isChatBoundaryPending)
        await chat.waitUntilSendStarts()

        let stop = feature.enqueue(.stopCoachResponse(context, authority))
        for _ in 0 ..< 100 { await Task.yield() }
        let stopArrivedBeforeSendFinished = await chat.stopReceived
        if !stopArrivedBeforeSendFinished {
            await chat.forceResumeSend()
        }
        await stop.value
        await send.value

        let commands = await chat.commands
        XCTAssertTrue(stopArrivedBeforeSendFinished)
        XCTAssertFalse(feature.admissionState.isChatBoundaryPending)
        XCTAssertEqual(
            commands,
            [
                .sendDraft(context, chatID, draft),
                .stopCoachResponse(context, authority),
            ]
        )
    }

    func testTerminationBeginsChatLifecycleBeforeDrainingApplicationFIFO()
        async throws
    {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedNewChatPickerApplicationChatFeature()
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)
        let context = ChatCommandContext(
            libraryScope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        let token = NewChatConfirmationToken()

        let confirmation = feature.enqueue(.confirmNewChat(context, token))
        await chat.waitUntilConfirmationStarts()

        let termination = feature.flushForOrderlyTermination()
        for _ in 0..<100 { await Task.yield() }
        let terminationBegan = await chat.orderlyTerminationBegan
        if !terminationBegan {
            await chat.forceResumeConfirmation()
        }

        let terminationSucceeded = await termination.value
        await confirmation.value
        let flushCallCount = await chat.flushCallCount
        XCTAssertTrue(terminationSucceeded)
        XCTAssertTrue(terminationBegan)
        XCTAssertEqual(flushCallCount, 1)
    }

    func testOneApplicationFIFOOrdersDraftSendDeferredStartAndTermination() async throws {
        let firstScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let secondScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T121000000Z-3DEF")
        )
        let firstContext = ChatCommandContext(libraryScope: firstScope, generation: 1)
        let secondContext = ChatCommandContext(libraryScope: secondScope, generation: 2)
        let chatID = try ChatID("cht-20260830T120000000Z-2ABC")
        let draft = try ChatDraft(
            draftID: ChatDraftID("drf-20260830T120000000Z-3DEF"),
            version: 0,
            text: "",
            updatedAt: UTCInstant("2026-08-30T12:00:00.000Z")
        )
        let trace = LibrarySelectionTrace()
        let chat = SuspendedOrderedApplicationChatFeature()
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)

        await feature.enqueue(.start(firstContext)).value
        let firstEdit = feature.enqueue(
            .editDraft(firstContext, chatID, draft.draftID, text: "A")
        )
        await chat.waitUntilFirstEditStarts()
        let secondEdit = feature.enqueue(
            .editDraft(firstContext, chatID, draft.draftID, text: "AB")
        )
        let send = feature.enqueue(.sendDraft(firstContext, chatID, draft))
        let deferredStart = feature.enqueue(.start(secondContext))
        let termination = feature.flushForOrderlyTermination()

        XCTAssertEqual(
            feature.admissionState,
            ApplicationCommandAdmissionState(
                isChatBoundaryPending: true,
                isOrderlyTerminationPending: true
            )
        )
        let commandsWhileSuspended = await chat.commands
        let flushesWhileSuspended = await chat.flushCallCount
        XCTAssertEqual(
            commandsWhileSuspended,
            [
                .start(firstContext),
                .editDraft(firstContext, chatID, draft.draftID, text: "A"),
            ]
        )
        XCTAssertEqual(flushesWhileSuspended, 0)

        await chat.resumeFirstEdit()
        await firstEdit.value
        await secondEdit.value
        await send.value
        await deferredStart.value
        let terminationSucceeded = await termination.value

        XCTAssertTrue(terminationSucceeded)
        let commands = await chat.commands
        XCTAssertEqual(
            commands,
            [
                .start(firstContext),
                .editDraft(firstContext, chatID, draft.draftID, text: "A"),
                .editDraft(firstContext, chatID, draft.draftID, text: "AB"),
                .sendDraft(firstContext, chatID, draft),
                .start(secondContext),
            ]
        )
        let finalFlushCount = await chat.flushCallCount
        XCTAssertEqual(finalFlushCount, 1)
    }

    func testSelectionFlushesChatBeforeSendingOneTypedLibraryIntent() async {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)

        let succeeded = await feature.enqueue(.close).value

        XCTAssertTrue(succeeded)
        let events = await trace.events
        XCTAssertEqual(events, ["chat.flush", "library.close"])
    }

    func testChatAndLibraryIntentsShareOneFIFOAndFenceLaterChatIngress() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedCrossFeatureChatFeature(trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)
        let edit = try makeEditCommand(text: "accepted before Library selection")
        let lateEdit = try makeEditCommand(text: "rejected after Library selection")

        let editReceipt = feature.enqueue(edit)
        await chat.waitUntilCommandStarts()
        let selectionReceipt = feature.enqueue(.close)
        await feature.enqueue(lateEdit).value

        let eventsWhileChatIsSuspended = await trace.events
        XCTAssertEqual(eventsWhileChatIsSuspended, ["chat.edit"])
        XCTAssertTrue(feature.admissionState.isLibraryNavigationPending)

        await chat.resume()
        await editReceipt.value
        let selectionSucceeded = await selectionReceipt.value

        XCTAssertTrue(selectionSucceeded)
        let events = await trace.events
        XCTAssertEqual(events, ["chat.edit", "chat.flush", "library.close"])
        let commands = await chat.commands
        XCTAssertEqual(commands, [edit])
    }

    func testFailedChatFlushRejectsLibrarySelectionInsideApplication() async {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: false, trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)

        let succeeded = await feature.enqueue(.chooseExisting).value

        XCTAssertFalse(succeeded)
        let events = await trace.events
        XCTAssertEqual(events, ["chat.flush"])
    }

    func testLibrarySelectionFencesReviewBeforeFlushAndFinishesExactActivation()
        async throws
    {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let snapshot = ActiveLibrarySnapshot(
            libraryID: try LibraryID("lib-20260830T120000000Z-2ABC"),
            preferences: .defaults,
            profile: .nullProfile(statementCount: 0)
        )
        let library = IdenticalReplacementLibraryFeature(
            snapshot: snapshot,
            trace: trace
        )
        let review = NavigationReviewLifecycleProbe(trace: trace)
        let feature = DefaultApplicationCommandFeature(
            library: library,
            chat: chat
        )
        feature.installReviewLibraryNavigationLifecycle(review)

        let succeeded = await feature.enqueue(.chooseExisting).value

        let activation = LibraryActivation(
            scope: LibraryScope(libraryID: snapshot.libraryID),
            generation: 2
        )
        XCTAssertTrue(succeeded)
        let completions = await review.completions
        XCTAssertEqual(completions, [.activated(activation)])
        let events = await trace.events
        XCTAssertEqual(
            events,
            [
                "review.navigation.reserve",
                "chat.flush",
                "library.identicalReplacement",
                "review.navigation.finish",
            ]
        )
    }

    func testFailedChatFlushRestoresReservedReviewBeforeBoundaryReopens() async {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: false, trace: trace)
        let review = NavigationReviewLifecycleProbe(trace: trace)
        let feature = DefaultApplicationCommandFeature(
            library: SelectionLibraryFeature(trace: trace),
            chat: chat
        )
        feature.installReviewLibraryNavigationLifecycle(review)

        let succeeded = await feature.enqueue(.close).value

        XCTAssertFalse(succeeded)
        let completions = await review.completions
        XCTAssertEqual(completions, [.noSelectionMutation])
        let isReserved = await review.isReserved
        XCTAssertFalse(isReserved)
        let events = await trace.events
        XCTAssertEqual(
            events,
            [
                "review.navigation.reserve",
                "chat.flush",
                "review.navigation.finish",
            ]
        )
    }

    func testReviewAuthorityRejectsLibrarySelectionBeforeChatOrRootMutation()
        async
    {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let review = NavigationReviewLifecycleProbe(
            trace: trace,
            permitsReservation: false
        )
        let feature = DefaultApplicationCommandFeature(
            library: SelectionLibraryFeature(trace: trace),
            chat: chat
        )
        feature.installReviewLibraryNavigationLifecycle(review)

        let succeeded = await feature.enqueue(.close).value

        XCTAssertFalse(succeeded)
        let events = await trace.events
        XCTAssertEqual(events, ["review.navigation.reserve"])
    }

    func testCatalogMutationFlushesAndReloadsChatInsideApplicationBoundary()
        async throws
    {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let catalog = SelectionLibraryCatalogFeature(trace: trace)
        let activation = LibraryActivation(
            scope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        let feature = DefaultApplicationCommandFeature(
            library: ExactActivationLibraryFeature(activation: activation),
            chat: chat,
            libraryCatalog: catalog
        )
        let aggregate = LibraryAggregate.chat(
            try ChatID("cht-20260830T120000000Z-2ABC")
        )

        let catalogFeature = ApplicationCoordinatedLibraryCatalogFeature(
            application: feature,
            review: UnusedReviewFeature()
        )
        let result = await catalogFeature.send(
            .moveToTrash(activation, [aggregate])
        )

        XCTAssertEqual(
            result,
            .mutation(
                [
                    LibraryAggregateMutationResult(
                        aggregate: aggregate,
                        outcome: .succeeded
                    ),
                ],
                catalog: .available(
                    LibraryCatalogSnapshot(
                        active: [],
                        trash: [librarySelectionCatalogRow(aggregate)]
                    )
                )
            )
        )
        XCTAssertEqual(feature.admissionState, .idle)
        let events = await trace.events
        XCTAssertEqual(
            events,
            ["chat.catalog.prepare", "catalog.mutate", "chat.catalog.reload"]
        )
    }

    func testCatalogMutationDoesNotTouchStorageWhenChatCannotFlush()
        async throws
    {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: false, trace: trace)
        let catalog = SelectionLibraryCatalogFeature(trace: trace)
        let activation = LibraryActivation(
            scope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        let feature = DefaultApplicationCommandFeature(
            library: ExactActivationLibraryFeature(activation: activation),
            chat: chat,
            libraryCatalog: catalog
        )
        let aggregate = LibraryAggregate.chat(
            try ChatID("cht-20260830T120000000Z-2ABC")
        )

        let catalogFeature = ApplicationCoordinatedLibraryCatalogFeature(
            application: feature,
            review: UnusedReviewFeature()
        )
        let result = await catalogFeature.send(
            .moveToTrash(activation, [aggregate])
        )

        XCTAssertEqual(
            result,
            .mutation(
                [
                    LibraryAggregateMutationResult(
                        aggregate: aggregate,
                        outcome: .unavailable
                    ),
                ],
                catalog: .unavailable
            )
        )
        XCTAssertEqual(feature.admissionState, .idle)
        let events = await trace.events
        XCTAssertEqual(events, ["chat.catalog.prepare"])
    }

    func testStaleCatalogMutationDoesNotQuiesceTheReplacementChat()
        async throws
    {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let catalog = SelectionLibraryCatalogFeature(trace: trace)
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let currentActivation = LibraryActivation(scope: scope, generation: 2)
        let feature = DefaultApplicationCommandFeature(
            library: ExactActivationLibraryFeature(
                activation: currentActivation
            ),
            chat: chat,
            libraryCatalog: catalog
        )
        let aggregate = LibraryAggregate.chat(
            try ChatID("cht-20260830T120000000Z-2ABC")
        )

        let catalogFeature = ApplicationCoordinatedLibraryCatalogFeature(
            application: feature,
            review: UnusedReviewFeature()
        )
        let result = await catalogFeature.send(
            .moveToTrash(
                LibraryActivation(scope: scope, generation: 1),
                [aggregate]
            )
        )

        XCTAssertEqual(
            result,
            .mutation(
                [
                    LibraryAggregateMutationResult(
                        aggregate: aggregate,
                        outcome: .unavailable
                    ),
                ],
                catalog: .unavailable
            )
        )
        XCTAssertEqual(feature.admissionState, .idle)
        let events = await trace.events
        XCTAssertEqual(events, [])
    }

    func testSessionCatalogMutationCoordinatesEveryDependentLifecycleInOrder()
        async throws
    {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let catalog = SelectionLibraryCatalogFeature(trace: trace)
        let processing = CatalogLifecycleProcessingProbe(trace: trace)
        let review = CatalogLifecycleReviewProbe(trace: trace)
        let activation = LibraryActivation(
            scope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        let feature = DefaultApplicationCommandFeature(
            library: ExactActivationLibraryFeature(activation: activation),
            chat: chat,
            libraryCatalog: catalog,
            sessionProcessing: processing
        )
        let aggregate = LibraryAggregate.session(
            try SessionID("ses-20260830T120000000Z-2ABC")
        )

        let catalogFeature = ApplicationCoordinatedLibraryCatalogFeature(
            application: feature,
            review: review
        )
        let receipt = Task {
            await catalogFeature.send(.moveToTrash(activation, [aggregate]))
        }
        for _ in 0..<100 where !feature.admissionState.isLibraryCatalogMutationPending {
            await Task.yield()
        }
        XCTAssertTrue(feature.admissionState.isLibraryCatalogMutationPending)
        XCTAssertFalse(
            feature.isSessionProcessingCommandAdmitted(
                .selectSession(
                    SessionProcessingSelection(
                        scope: activation.scope,
                        sessionID: try SessionID(
                            "ses-20260830T120100000Z-3CDE"
                        )
                    )
                )
            )
        )
        let result = await receipt.value

        guard case let .mutation(results, _) = result else {
            return XCTFail("expected coordinated mutation")
        }
        XCTAssertEqual(results.first?.outcome, .succeeded)
        XCTAssertEqual(feature.admissionState, .idle)
        let events = await trace.events
        XCTAssertEqual(
            events,
            [
                "processing.catalog.reserve",
                "review.catalog.reserve",
                "chat.catalog.prepare",
                "catalog.mutate",
                "processing.catalog.finish",
                "review.catalog.finish",
                "chat.catalog.reload",
            ]
        )
    }

    func testInexactPostWriteReloadInvalidatesSessionParticipantsInsteadOfRebinding()
        async throws
    {
        let trace = LibrarySelectionTrace()
        let activation = LibraryActivation(
            scope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        let aggregate = LibraryAggregate.session(
            try SessionID("ses-20260830T120000000Z-2ABC")
        )
        let processing = CatalogLifecycleProcessingProbe(trace: trace)
        let review = CatalogLifecycleReviewProbe(trace: trace)
        let feature = DefaultApplicationCommandFeature(
            library: ExactActivationLibraryFeature(activation: activation),
            chat: SelectionChatFeature(flushResult: true, trace: trace),
            libraryCatalog: InexactReloadLibraryCatalogFeature(),
            sessionProcessing: processing
        )

        let catalogFeature = ApplicationCoordinatedLibraryCatalogFeature(
            application: feature,
            review: review
        )
        _ = await catalogFeature.send(.moveToTrash(activation, [aggregate]))

        let processingCompletions = await processing.completions
        let reviewCompletions = await review.completions
        XCTAssertEqual(processingCompletions, [.completed(.unavailable)])
        XCTAssertEqual(reviewCompletions, [.completed(.unavailable)])
        XCTAssertEqual(feature.admissionState, .idle)
    }

    func testBusySessionProcessingRejectsCatalogMutationBeforeOtherQuiescence()
        async throws
    {
        let trace = LibrarySelectionTrace()
        let activation = LibraryActivation(
            scope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        let aggregate = LibraryAggregate.session(
            try SessionID("ses-20260830T120000000Z-2ABC")
        )
        let feature = DefaultApplicationCommandFeature(
            library: ExactActivationLibraryFeature(activation: activation),
            chat: SelectionChatFeature(flushResult: true, trace: trace),
            libraryCatalog: SelectionLibraryCatalogFeature(trace: trace),
            sessionProcessing: CatalogLifecycleProcessingProbe(
                trace: trace,
                permitsReservation: false
            )
        )

        let catalogFeature = ApplicationCoordinatedLibraryCatalogFeature(
            application: feature,
            review: CatalogLifecycleReviewProbe(trace: trace)
        )
        let result = await catalogFeature.send(
            .moveToTrash(activation, [aggregate])
        )

        XCTAssertEqual(result, .mutationRefused([
            LibraryAggregateMutationResult(
                aggregate: aggregate,
                outcome: .busy
            ),
        ]))
        let events = await trace.events
        XCTAssertEqual(events, ["processing.catalog.reserve"])
    }

    func testBusyReviewRollsBackProcessingReservationAndReleasesBoundary()
        async throws
    {
        let trace = LibrarySelectionTrace()
        let activation = LibraryActivation(
            scope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        let aggregate = LibraryAggregate.session(
            try SessionID("ses-20260830T120000000Z-2ABC")
        )
        let processing = CatalogLifecycleProcessingProbe(trace: trace)
        let feature = DefaultApplicationCommandFeature(
            library: ExactActivationLibraryFeature(activation: activation),
            chat: SelectionChatFeature(flushResult: true, trace: trace),
            libraryCatalog: SelectionLibraryCatalogFeature(trace: trace),
            sessionProcessing: processing
        )
        let catalogFeature = ApplicationCoordinatedLibraryCatalogFeature(
            application: feature,
            review: CatalogLifecycleReviewProbe(
                trace: trace,
                permitsReservation: false
            )
        )

        let result = await catalogFeature.send(
            .moveToTrash(activation, [aggregate])
        )

        XCTAssertEqual(result, .mutationRefused([
            LibraryAggregateMutationResult(
                aggregate: aggregate,
                outcome: .busy
            ),
        ]))
        let processingCompletions = await processing.completions
        let events = await trace.events
        XCTAssertEqual(processingCompletions, [.aborted])
        XCTAssertEqual(feature.admissionState, .idle)
        XCTAssertEqual(
            events,
            [
                "processing.catalog.reserve",
                "review.catalog.reserve",
                "processing.catalog.finish",
            ]
        )
    }

    func testChatPreparationFailureRollsBackSessionParticipantsInReverseOrder()
        async throws
    {
        let trace = LibrarySelectionTrace()
        let activation = LibraryActivation(
            scope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        let aggregate = LibraryAggregate.session(
            try SessionID("ses-20260830T120000000Z-2ABC")
        )
        let processing = CatalogLifecycleProcessingProbe(trace: trace)
        let review = CatalogLifecycleReviewProbe(trace: trace)
        let feature = DefaultApplicationCommandFeature(
            library: ExactActivationLibraryFeature(activation: activation),
            chat: SelectionChatFeature(flushResult: false, trace: trace),
            libraryCatalog: SelectionLibraryCatalogFeature(trace: trace),
            sessionProcessing: processing
        )
        let catalogFeature = ApplicationCoordinatedLibraryCatalogFeature(
            application: feature,
            review: review
        )

        let result = await catalogFeature.send(
            .moveToTrash(activation, [aggregate])
        )

        XCTAssertEqual(result, .mutation([
            LibraryAggregateMutationResult(
                aggregate: aggregate,
                outcome: .unavailable
            ),
        ], catalog: .unavailable))
        let processingCompletions = await processing.completions
        let reviewCompletions = await review.completions
        let events = await trace.events
        XCTAssertEqual(processingCompletions, [.aborted])
        XCTAssertEqual(reviewCompletions, [.aborted])
        XCTAssertEqual(feature.admissionState, .idle)
        XCTAssertEqual(
            events,
            [
                "processing.catalog.reserve",
                "review.catalog.reserve",
                "chat.catalog.prepare",
                "review.catalog.finish",
                "processing.catalog.finish",
            ]
        )
    }

    func testProcessingAuthorityRejectsLibrarySelectionBeforeChatOrRootMutation()
        async throws
    {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let job = SessionProcessingJob(
            jobID: try TranscriptionJobID("job-20260830T120200000Z-3DEF"),
            sessionID: try SessionID("ses-20260830T120100000Z-2CDE"),
            revisionID: try TranscriptRevisionID("trv-20260830T120300000Z-4FGH"),
            profileID: "synthetic-qualified-v1",
            createdAt: try UTCInstant("2026-08-30T12:03:00.000Z"),
            state: .running,
            cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                "cancel-library-selection"
            )
        )
        let processing = FixedSessionProcessingFeature(.recoveryRequired(job))
        let feature = DefaultApplicationCommandFeature(
            library: library,
            chat: chat,
            sessionProcessing: processing
        )

        let succeeded = await feature.enqueue(.close).value

        XCTAssertFalse(succeeded)
        let events = await trace.events
        XCTAssertEqual(events, [])
    }

    func testReservedLibraryNavigationRejectsStartRacingSuspendedChatFlush()
        async
    {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedTerminationChatFeature(flushResult: true, trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let processing = NavigationReservationProcessingProbe()
        let feature = DefaultApplicationCommandFeature(
            library: library,
            chat: chat,
            sessionProcessing: processing
        )

        let navigation = feature.enqueue(LibrarySelectionIntent.close)
        await chat.waitUntilFlushStarts()
        await processing.send(.start)
        await chat.resume()

        let succeeded = await navigation.value
        let acceptedStartCount = await processing.acceptedStartCount
        let isReserved = await processing.isNavigationReserved
        XCTAssertTrue(succeeded)
        XCTAssertEqual(acceptedStartCount, 0)
        XCTAssertFalse(isReserved)
        let events = await trace.events
        XCTAssertEqual(events, ["chat.flush", "library.close"])
    }

    func testSuccessfulIdenticalLibraryReplacementExplicitlyActivatesProcessing()
        async throws
    {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let snapshot = ActiveLibrarySnapshot(
            libraryID: try LibraryID("lib-20260830T120000000Z-2ABC"),
            preferences: .defaults,
            profile: .nullProfile(statementCount: 0)
        )
        let library = IdenticalReplacementLibraryFeature(
            snapshot: snapshot,
            trace: trace
        )
        let processing = NavigationActivationProcessingProbe()
        let feature = DefaultApplicationCommandFeature(
            library: library,
            chat: chat,
            sessionProcessing: processing
        )

        let succeeded = await feature.enqueue(.chooseExisting).value

        XCTAssertTrue(succeeded)
        let commands = await processing.commands
        XCTAssertEqual(
            commands,
            [
                .activateLibraryAuthority(
                    LibraryActivation(
                        scope: LibraryScope(libraryID: snapshot.libraryID),
                        generation: 2
                    )
                ),
            ]
        )
        let navigationMutations = await processing.navigationMutations
        XCTAssertEqual(navigationMutations, [true])
    }

    func testInitialRestoreExplicitlyActivatesProcessingThroughApplicationCoordinator()
        async throws
    {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let snapshot = ActiveLibrarySnapshot(
            libraryID: try LibraryID("lib-20260830T120000000Z-2ABC"),
            preferences: .defaults,
            profile: .nullProfile(statementCount: 0)
        )
        let library = IdenticalReplacementLibraryFeature(
            snapshot: snapshot,
            activationGeneration: 1,
            trace: trace
        )
        let processing = NavigationActivationProcessingProbe()
        let feature = DefaultApplicationCommandFeature(
            library: library,
            chat: chat,
            sessionProcessing: processing
        )

        let succeeded = await feature.enqueue(.start).value

        XCTAssertTrue(succeeded)
        let libraryCommands = await library.commands
        XCTAssertEqual(libraryCommands, [.start])
        let processingCommands = await processing.commands
        XCTAssertEqual(
            processingCommands,
            [
                .activateLibraryAuthority(
                    LibraryActivation(
                        scope: LibraryScope(libraryID: snapshot.libraryID),
                        generation: 1
                    )
                ),
            ]
        )
        let navigationMutations = await processing.navigationMutations
        XCTAssertEqual(navigationMutations, [true])
    }

    func testExternalOpenQueuedDuringInitialRestoreActivatesBothExactAuthorities()
        async throws
    {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let initialScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120000000Z-2ABC")
        )
        let externalScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T121000000Z-3DEF")
        )
        let library = SuspendedActivationLibraryFeature(
            results: [
                .activated(LibraryActivation(scope: initialScope, generation: 1)),
                .activated(LibraryActivation(scope: externalScope, generation: 2)),
            ]
        )
        let processing = NavigationActivationProcessingProbe()
        let review = NavigationReviewLifecycleProbe(trace: trace)
        let feature = DefaultApplicationCommandFeature(
            library: library,
            chat: chat,
            sessionProcessing: processing
        )
        feature.installReviewLibraryNavigationLifecycle(review)
        let token = try XCTUnwrap(LibraryOpenRequestToken("queued_external"))

        let startup = feature.enqueue(LibrarySelectionIntent.start)
        await library.waitForCommandCount(1)
        let external = feature.enqueue(.openExternal(token))
        let externalCompletion = BooleanReceiptProbe()
        let externalWaiter = Task {
            await externalCompletion.complete(await external.value)
        }

        XCTAssertTrue(feature.admissionState.isLibraryNavigationPending)
        for _ in 0..<100 { await Task.yield() }
        if let earlyResult = await externalCompletion.result {
            await library.resumeNextCommand()
            _ = await startup.value
            await externalWaiter.value
            return XCTFail(
                "queued external open returned early with \(earlyResult)"
            )
        }
        await library.resumeNextCommand()
        await library.waitForCommandCount(2)
        XCTAssertTrue(feature.admissionState.isLibraryNavigationPending)
        let reviewReservationCount = await review.reserveCallCount
        let reviewRemainsReserved = await review.isReserved
        XCTAssertEqual(reviewReservationCount, 1)
        XCTAssertTrue(reviewRemainsReserved)
        await library.resumeNextCommand()

        let startupSucceeded = await startup.value
        await externalWaiter.value
        let externalSucceeded = await externalCompletion.result
        XCTAssertTrue(startupSucceeded)
        XCTAssertEqual(externalSucceeded, true)
        XCTAssertEqual(feature.admissionState, .idle)
        let libraryCommands = await library.commands
        XCTAssertEqual(libraryCommands, [.start, .openExternal(token)])
        let processingCommands = await processing.commands
        XCTAssertEqual(
            processingCommands,
            [
                .activateLibraryAuthority(
                    LibraryActivation(scope: initialScope, generation: 1)
                ),
                .activateLibraryAuthority(
                    LibraryActivation(scope: externalScope, generation: 2)
                ),
            ]
        )
        let reviewCompletions = await review.completions
        XCTAssertEqual(
            reviewCompletions,
            [.activated(LibraryActivation(scope: externalScope, generation: 2))]
        )
    }

    func testFailedLibraryNavigationDoesNotActivateOrInvalidateProcessing()
        async throws
    {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let snapshot = ActiveLibrarySnapshot(
            libraryID: try LibraryID("lib-20260830T120000000Z-2ABC"),
            preferences: .defaults,
            profile: .nullProfile(statementCount: 0)
        )
        let library = FailedReplacementLibraryFeature(
            snapshot: snapshot,
            trace: trace
        )
        let processing = NavigationActivationProcessingProbe()
        let feature = DefaultApplicationCommandFeature(
            library: library,
            chat: chat,
            sessionProcessing: processing
        )

        let succeeded = await feature.enqueue(.chooseExisting).value

        XCTAssertFalse(succeeded)
        let commands = await processing.commands
        XCTAssertEqual(commands, [])
        let navigationMutations = await processing.navigationMutations
        XCTAssertEqual(navigationMutations, [false])
    }

    func testSelectionFencesLateChatIngressUntilLibrarySendCompletes() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SelectionChatFeature(flushResult: true, trace: trace)
        let library = SuspendedSelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)
        let context = ChatCommandContext(
            libraryScope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        let chatID = try ChatID("cht-20260830T120000000Z-2ABC")
        let draftID = try ChatDraftID("drf-20260830T120000000Z-3DEF")

        let selection = feature.enqueue(.close)
        await library.waitUntilSendStarts()
        await feature.enqueue(
            .editDraft(context, chatID, draftID, text: "late edit")
        ).value
        await library.resume()

        let succeeded = await selection.value
        XCTAssertTrue(succeeded)
        let commands = await chat.commands
        XCTAssertTrue(commands.isEmpty, "late Chat ingress crossed the Application boundary")
    }

    func testSuccessfulTerminationFencesChatIngressDuringFlushAndAfterReturn() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedTerminationChatFeature(flushResult: true, trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)
        let edit = try makeEditCommand(text: "late edit")

        let termination = feature.flushForOrderlyTermination()
        await chat.waitUntilFlushStarts()
        await feature.enqueue(edit).value
        await chat.resume()

        let succeeded = await termination.value
        XCTAssertTrue(succeeded)
        await feature.enqueue(edit).value
        let selectionSucceeded = await feature.enqueue(.close).value

        XCTAssertFalse(selectionSucceeded)
        let commands = await chat.commands
        XCTAssertTrue(commands.isEmpty, "Chat ingress reopened after successful termination flush")
        let events = await trace.events
        XCTAssertEqual(events, ["chat.flush"])
    }

    func testFailedTerminationReopensChatIngressAfterRejectingCommandsDuringFlush() async throws {
        let trace = LibrarySelectionTrace()
        let chat = SuspendedTerminationChatFeature(flushResult: false, trace: trace)
        let library = SelectionLibraryFeature(trace: trace)
        let feature = DefaultApplicationCommandFeature(library: library, chat: chat)
        let edit = try makeEditCommand(text: "edit after failure")

        let termination = feature.flushForOrderlyTermination()
        await chat.waitUntilFlushStarts()
        await feature.enqueue(edit).value
        await chat.resume()

        let succeeded = await termination.value
        XCTAssertFalse(succeeded)
        await feature.enqueue(edit).value

        let commands = await chat.commands
        XCTAssertEqual(commands, [edit])
    }

    private func makeEditCommand(text: String) throws -> ChatCommand {
        let context = ChatCommandContext(
            libraryScope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
            ),
            generation: 1
        )
        return try .editDraft(
            context,
            ChatID("cht-20260830T120000000Z-2ABC"),
            ChatDraftID("drf-20260830T120000000Z-3DEF"),
            text: text
        )
    }
}

private actor FixedSessionProcessingFeature: SessionProcessingFeature {
    nonisolated let states: AsyncStream<SessionProcessingFeatureState>
    private let state: SessionProcessingFeatureState

    init(_ state: SessionProcessingFeatureState) {
        self.state = state
        states = AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    var currentState: SessionProcessingFeatureState { state }

    func send(_ command: SessionProcessingCommand) async {}

    func reserveLibraryNavigation() async -> Bool {
        !state.ownsLibraryMutationAuthority
    }

    func finishLibraryNavigation(didMutateLibrary: Bool) async {}
}

private actor NavigationReservationProcessingProbe: SessionProcessingFeature {
    nonisolated let states = AsyncStream<SessionProcessingFeatureState> { continuation in
        continuation.finish()
    }
    private var navigationReserved = false
    private(set) var acceptedStartCount = 0

    var currentState: SessionProcessingFeatureState {
        .unavailable(
            SessionProcessingUnavailableSnapshot(
                selection: nil,
                reason: .noSession,
                actions: []
            )
        )
    }

    var isNavigationReserved: Bool { navigationReserved }

    func send(_ command: SessionProcessingCommand) async {
        if command == .start, !navigationReserved { acceptedStartCount += 1 }
    }

    func reserveLibraryNavigation() async -> Bool {
        guard !navigationReserved else { return false }
        navigationReserved = true
        return true
    }

    func finishLibraryNavigation(didMutateLibrary: Bool) async {
        navigationReserved = false
    }
}

private actor NavigationActivationProcessingProbe: SessionProcessingFeature {
    nonisolated let states = AsyncStream<SessionProcessingFeatureState> { continuation in
        continuation.finish()
    }
    private(set) var commands: [SessionProcessingCommand] = []
    private(set) var navigationMutations: [Bool] = []

    var currentState: SessionProcessingFeatureState {
        .unavailable(
            SessionProcessingUnavailableSnapshot(
                selection: nil,
                reason: .noSession,
                actions: []
            )
        )
    }

    func send(_ command: SessionProcessingCommand) async {
        commands.append(command)
    }

    func reserveLibraryNavigation() async -> Bool { true }

    func finishLibraryNavigation(didMutateLibrary: Bool) async {
        navigationMutations.append(didMutateLibrary)
    }
}

private actor NavigationReviewLifecycleProbe: ReviewLibraryNavigationLifecycle {
    private let trace: LibrarySelectionTrace
    private let permitsReservation: Bool
    private(set) var isReserved = false
    private(set) var reserveCallCount = 0
    private(set) var completions: [LibraryCommandResult] = []

    init(
        trace: LibrarySelectionTrace,
        permitsReservation: Bool = true
    ) {
        self.trace = trace
        self.permitsReservation = permitsReservation
    }

    func reserveLibraryNavigation() async -> Bool {
        reserveCallCount += 1
        await trace.append("review.navigation.reserve")
        guard permitsReservation, !isReserved else { return false }
        isReserved = true
        return true
    }

    func finishLibraryNavigation(_ result: LibraryCommandResult) async {
        guard isReserved else { return }
        completions.append(result)
        isReserved = false
        await trace.append("review.navigation.finish")
    }
}

private actor LibrarySelectionTrace {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

private actor SelectionChatFeature: ChatFeature {
    nonisolated let states = AsyncStream<ChatFeatureState> { continuation in
        continuation.finish()
    }

    private let flushResult: Bool
    private let trace: LibrarySelectionTrace
    private(set) var commands: [ChatCommand] = []

    init(flushResult: Bool, trace: LibrarySelectionTrace) {
        self.flushResult = flushResult
        self.trace = trace
    }

    var currentState: ChatFeatureState { ChatFeatureState() }

    func currentState(in context: ChatCommandContext) -> ChatFeatureState? { nil }

    func send(_ command: ChatCommand) async {
        commands.append(command)
    }

    func prepareForLibraryCatalogMutation(
        for activation: LibraryActivation
    ) async -> Bool {
        await trace.append("chat.catalog.prepare")
        return flushResult
    }

    func reloadAfterLibraryCatalogMutation(
        for activation: LibraryActivation
    ) async -> Bool {
        await trace.append("chat.catalog.reload")
        return true
    }

    func flushForOrderlyTermination() async -> Bool {
        await trace.append("chat.flush")
        return flushResult
    }
}

private actor SelectionLibraryCatalogFeature:
    LibraryCatalogFeature,
    LibraryCatalogMutationFeature
{
    private let trace: LibrarySelectionTrace

    init(trace: LibrarySelectionTrace) {
        self.trace = trace
    }

    func send(
        _ command: LibraryCatalogCommand
    ) async -> LibraryCatalogCommandResult {
        await trace.append("catalog.mutate")
        switch command {
        case let .moveToTrash(_, aggregates):
            let ordered = aggregates.sorted()
            return .mutation(
                ordered.map {
                    LibraryAggregateMutationResult(
                        aggregate: $0,
                        outcome: .succeeded
                    )
                },
                catalog: .available(
                    LibraryCatalogSnapshot(
                        active: [],
                        trash: ordered.map(librarySelectionCatalogRow)
                    )
                )
            )
        case .refresh, .restore:
            return command.unavailableResult
        }
    }

    func send(
        _ command: LibraryCatalogCommand,
        lifecycle: any LibraryCatalogMutationLifecycle
    ) async -> LibraryCatalogCommandResult {
        switch await lifecycle.prepareForLibraryCatalogMutation(command) {
        case .prepared:
            break
        case .refused:
            return command.refusedResult
        case .unavailable:
            return command.unavailableResult
        }
        let result = await send(command)
        guard await lifecycle.reloadAfterLibraryCatalogMutation(
            command,
            result: result
        ) else {
            return command.unavailableResult
        }
        return result
    }
}

private actor InexactReloadLibraryCatalogFeature:
    LibraryCatalogFeature,
    LibraryCatalogMutationFeature
{
    func send(
        _ command: LibraryCatalogCommand
    ) async -> LibraryCatalogCommandResult {
        command.unavailableResult
    }

    func send(
        _ command: LibraryCatalogCommand,
        lifecycle: any LibraryCatalogMutationLifecycle
    ) async -> LibraryCatalogCommandResult {
        switch await lifecycle.prepareForLibraryCatalogMutation(command) {
        case .prepared:
            break
        case .refused:
            return command.refusedResult
        case .unavailable:
            return command.unavailableResult
        }
        let result = command.unavailableResult
        let inexactCommand: LibraryCatalogCommand = switch command {
        case let .moveToTrash(activation, aggregates):
            .restore(activation, aggregates)
        case let .restore(activation, aggregates):
            .moveToTrash(activation, aggregates)
        case .refresh:
            command
        }
        _ = await lifecycle.reloadAfterLibraryCatalogMutation(
            inexactCommand,
            result: result
        )
        return result
    }
}

private actor CatalogLifecycleProcessingProbe: SessionProcessingFeature {
    nonisolated let states = AsyncStream<SessionProcessingFeatureState> {
        $0.finish()
    }

    private let trace: LibrarySelectionTrace
    private let permitsReservation: Bool
    private var nextToken: UInt64 = 1
    private(set) var completions: [LibraryCatalogSessionMutationCompletion] = []

    init(
        trace: LibrarySelectionTrace,
        permitsReservation: Bool = true
    ) {
        self.trace = trace
        self.permitsReservation = permitsReservation
    }

    var currentState: SessionProcessingFeatureState {
        .unavailable(
            SessionProcessingUnavailableSnapshot(
                selection: nil,
                reason: .noSession,
                actions: []
            )
        )
    }

    func send(_ command: SessionProcessingCommand) async {}

    func reserveLibraryNavigation() async -> Bool { false }

    func finishLibraryNavigation(didMutateLibrary: Bool) async {}

    func reserveLibraryCatalogSessionMutation(
        _ mutation: LibraryCatalogSessionMutation
    ) async -> LibraryCatalogSessionMutationLease? {
        await trace.append("processing.catalog.reserve")
        guard permitsReservation else { return nil }
        let lease = LibraryCatalogSessionMutationLease(
            token: nextToken,
            mutation: mutation
        )
        nextToken += 1
        return lease
    }

    func finishLibraryCatalogSessionMutation(
        _ lease: LibraryCatalogSessionMutationLease,
        completion: LibraryCatalogSessionMutationCompletion
    ) async -> LibraryCatalogSessionMutationFinishResult {
        completions.append(completion)
        await trace.append("processing.catalog.finish")
        return .consumed
    }
}

private actor CatalogLifecycleReviewProbe: ReviewFeature {
    nonisolated let states = AsyncStream<ReviewFeatureState> { $0.finish() }
    private let trace: LibrarySelectionTrace
    private let permitsReservation: Bool
    private var nextToken: UInt64 = 1
    private(set) var completions: [LibraryCatalogSessionMutationCompletion] = []

    init(
        trace: LibrarySelectionTrace,
        permitsReservation: Bool = true
    ) {
        self.trace = trace
        self.permitsReservation = permitsReservation
    }

    var currentState: ReviewFeatureState {
        .unavailable(selection: nil, reason: .noSession)
    }

    func send(_ command: ReviewCommand) async {}

    func reserveLibraryNavigation() async -> Bool { true }

    func finishLibraryNavigation(_ result: LibraryCommandResult) async {}

    func reserveLibraryCatalogSessionMutation(
        _ mutation: LibraryCatalogSessionMutation
    ) async -> LibraryCatalogSessionMutationLease? {
        await trace.append("review.catalog.reserve")
        guard permitsReservation else { return nil }
        let lease = LibraryCatalogSessionMutationLease(
            token: nextToken,
            mutation: mutation
        )
        nextToken += 1
        return lease
    }

    func finishLibraryCatalogSessionMutation(
        _ lease: LibraryCatalogSessionMutationLease,
        completion: LibraryCatalogSessionMutationCompletion
    ) async -> LibraryCatalogSessionMutationFinishResult {
        completions.append(completion)
        await trace.append("review.catalog.finish")
        return .consumed
    }
}

private actor SuspendedBoundaryChatFeature: ChatFeature {
    nonisolated let states = AsyncStream<ChatFeatureState> { continuation in
        continuation.finish()
    }

    private let trace: LibrarySelectionTrace
    private var commandStarted = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var commands: [ChatCommand] = []

    init(trace: LibrarySelectionTrace) {
        self.trace = trace
    }

    var currentState: ChatFeatureState { ChatFeatureState() }

    func currentState(in context: ChatCommandContext) -> ChatFeatureState? { nil }

    func send(_ command: ChatCommand) async {
        commands.append(command)
        commandStarted = true
        await withCheckedContinuation { continuation = $0 }
    }

    func flushForOrderlyTermination() async -> Bool { true }

    func waitUntilCommandStarts() async {
        while !commandStarted { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SuspendedNewChatPickerApplicationChatFeature: ChatFeature {
    nonisolated let states = AsyncStream<ChatFeatureState> { continuation in
        continuation.finish()
    }

    private var confirmationStarted = false
    private var confirmationContinuation: CheckedContinuation<Void, Never>?
    private(set) var cancelReceived = false
    private(set) var orderlyTerminationBegan = false
    private(set) var flushCallCount = 0
    private(set) var commands: [ChatCommand] = []

    var currentState: ChatFeatureState { ChatFeatureState() }

    func currentState(in context: ChatCommandContext) -> ChatFeatureState? { nil }

    func send(_ command: ChatCommand) async {
        commands.append(command)
        switch command {
        case .confirmNewChat:
            confirmationStarted = true
            await withCheckedContinuation { confirmationContinuation = $0 }
        case .cancelNewChat:
            cancelReceived = true
            confirmationContinuation?.resume()
            confirmationContinuation = nil
        default:
            break
        }
    }

    func beginOrderlyTermination() async {
        orderlyTerminationBegan = true
        confirmationContinuation?.resume()
        confirmationContinuation = nil
    }

    func flushForOrderlyTermination() async -> Bool {
        flushCallCount += 1
        return true
    }

    func waitUntilConfirmationStarts() async {
        while !confirmationStarted { await Task.yield() }
    }

    func forceResumeConfirmation() {
        confirmationContinuation?.resume()
        confirmationContinuation = nil
    }
}

private actor SuspendedCoachApplicationChatFeature: ChatFeature {
    nonisolated let states = AsyncStream<ChatFeatureState> { continuation in
        continuation.finish()
    }

    private var sendStarted = false
    private var sendContinuation: CheckedContinuation<Void, Never>?
    private(set) var stopReceived = false
    private(set) var commands: [ChatCommand] = []

    var currentState: ChatFeatureState { ChatFeatureState() }

    func currentState(in context: ChatCommandContext) -> ChatFeatureState? { nil }

    func send(_ command: ChatCommand) async {
        commands.append(command)
        switch command {
        case .sendDraft:
            sendStarted = true
            await withCheckedContinuation { sendContinuation = $0 }
        case .stopCoachResponse:
            stopReceived = true
            sendContinuation?.resume()
            sendContinuation = nil
        default:
            break
        }
    }

    func flushForOrderlyTermination() async -> Bool { true }

    func waitUntilSendStarts() async {
        while !sendStarted { await Task.yield() }
    }

    func forceResumeSend() {
        sendContinuation?.resume()
        sendContinuation = nil
    }
}

private actor SuspendedOrderedApplicationChatFeature: ChatFeature {
    nonisolated let states = AsyncStream<ChatFeatureState> { continuation in
        continuation.finish()
    }

    private var firstEditStarted = false
    private var firstEditContinuation: CheckedContinuation<Void, Never>?
    private(set) var commands: [ChatCommand] = []
    private(set) var flushCallCount = 0

    var currentState: ChatFeatureState { ChatFeatureState() }

    func currentState(in context: ChatCommandContext) -> ChatFeatureState? { nil }

    func send(_ command: ChatCommand) async {
        commands.append(command)
        guard case .editDraft = command, !firstEditStarted else { return }
        firstEditStarted = true
        await withCheckedContinuation { firstEditContinuation = $0 }
    }

    func flushForOrderlyTermination() async -> Bool {
        flushCallCount += 1
        return true
    }

    func waitUntilFirstEditStarts() async {
        while !firstEditStarted { await Task.yield() }
    }

    func resumeFirstEdit() {
        firstEditContinuation?.resume()
        firstEditContinuation = nil
    }
}

private actor SuspendedCrossFeatureChatFeature: ChatFeature {
    nonisolated let states = AsyncStream<ChatFeatureState> { continuation in
        continuation.finish()
    }

    private let trace: LibrarySelectionTrace
    private var commandStarted = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var commands: [ChatCommand] = []

    init(trace: LibrarySelectionTrace) {
        self.trace = trace
    }

    var currentState: ChatFeatureState { ChatFeatureState() }

    func currentState(in context: ChatCommandContext) -> ChatFeatureState? { nil }

    func send(_ command: ChatCommand) async {
        commands.append(command)
        await trace.append("chat.edit")
        commandStarted = true
        await withCheckedContinuation { continuation = $0 }
    }

    func flushForOrderlyTermination() async -> Bool {
        await trace.append("chat.flush")
        return true
    }

    func waitUntilCommandStarts() async {
        while !commandStarted { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SuspendedTerminationChatFeature: ChatFeature {
    nonisolated let states = AsyncStream<ChatFeatureState> { continuation in
        continuation.finish()
    }

    private let flushResult: Bool
    private let trace: LibrarySelectionTrace
    private var flushStarted = false
    private var flushCount = 0
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var commands: [ChatCommand] = []

    init(flushResult: Bool, trace: LibrarySelectionTrace) {
        self.flushResult = flushResult
        self.trace = trace
    }

    var currentState: ChatFeatureState { ChatFeatureState() }

    func currentState(in context: ChatCommandContext) -> ChatFeatureState? { nil }

    func send(_ command: ChatCommand) async {
        commands.append(command)
    }

    func flushForOrderlyTermination() async -> Bool {
        await trace.append("chat.flush")
        flushCount += 1
        guard flushCount == 1 else { return flushResult }
        flushStarted = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilFlushStarts() async {
        while !flushStarted { await Task.yield() }
    }

    func resume() {
        continuation?.resume(returning: flushResult)
        continuation = nil
    }
}

private actor SuspendedSelectionLibraryFeature: LibraryFeature {
    nonisolated let states = AsyncStream<LibraryFeatureState> { continuation in
        continuation.finish()
    }

    private let trace: LibrarySelectionTrace
    private var sendStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(trace: LibrarySelectionTrace) {
        self.trace = trace
    }

    var currentState: LibraryFeatureState {
        LibraryFeatureState(selection: .awaitingBootstrap)
    }

    func send(_ command: LibraryCommand) async -> LibraryCommandResult {
        await trace.append("library.suspended")
        sendStarted = true
        await withCheckedContinuation { continuation = $0 }
        return .deactivated
    }

    func waitUntilSendStarts() async {
        while !sendStarted { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SelectionLibraryFeature: LibraryFeature {
    nonisolated let states = AsyncStream<LibraryFeatureState> { continuation in
        continuation.finish()
    }

    private let trace: LibrarySelectionTrace

    init(trace: LibrarySelectionTrace) {
        self.trace = trace
    }

    var currentState: LibraryFeatureState {
        LibraryFeatureState(selection: .awaitingBootstrap)
    }

    func send(_ command: LibraryCommand) async -> LibraryCommandResult {
        switch command {
        case .close:
            await trace.append("library.close")
            return .deactivated
        default:
            await trace.append("library.other")
            return .deactivated
        }
    }
}

private actor ExactActivationLibraryFeature: LibraryFeature {
    nonisolated let states = AsyncStream<LibraryFeatureState> { continuation in
        continuation.finish()
    }

    private let activation: LibraryActivation

    init(activation: LibraryActivation) {
        self.activation = activation
    }

    var currentState: LibraryFeatureState {
        LibraryFeatureState(
            selection: .active(
                ActiveLibrarySnapshot(
                    libraryID: activation.scope.libraryID,
                    preferences: .defaults,
                    profile: .nullProfile(statementCount: 0),
                    activationGeneration: activation.generation
                )
            )
        )
    }

    func send(_ command: LibraryCommand) async -> LibraryCommandResult {
        .noSelectionMutation
    }
}

private actor IdenticalReplacementLibraryFeature: LibraryFeature {
    nonisolated let states = AsyncStream<LibraryFeatureState> { continuation in
        continuation.finish()
    }

    private let snapshot: ActiveLibrarySnapshot
    private let activationGeneration: UInt64
    private let trace: LibrarySelectionTrace
    private(set) var commands: [LibraryCommand] = []

    init(
        snapshot: ActiveLibrarySnapshot,
        activationGeneration: UInt64 = 2,
        trace: LibrarySelectionTrace
    ) {
        self.snapshot = snapshot
        self.activationGeneration = activationGeneration
        self.trace = trace
    }

    var currentState: LibraryFeatureState {
        LibraryFeatureState(selection: .active(snapshot))
    }

    func send(_ command: LibraryCommand) async -> LibraryCommandResult {
        commands.append(command)
        await trace.append("library.identicalReplacement")
        return .activated(
            LibraryActivation(
                scope: LibraryScope(libraryID: snapshot.libraryID),
                generation: activationGeneration
            )
        )
    }
}

private actor FailedReplacementLibraryFeature: LibraryFeature {
    nonisolated let states = AsyncStream<LibraryFeatureState> { continuation in
        continuation.finish()
    }

    private let snapshot: ActiveLibrarySnapshot
    private let trace: LibrarySelectionTrace

    init(snapshot: ActiveLibrarySnapshot, trace: LibrarySelectionTrace) {
        self.snapshot = snapshot
        self.trace = trace
    }

    var currentState: LibraryFeatureState {
        LibraryFeatureState(
            selection: .active(snapshot),
            notice: .candidateUnavailable
        )
    }

    func send(_ command: LibraryCommand) async -> LibraryCommandResult {
        await trace.append("library.failedReplacement")
        return .noSelectionMutation
    }
}

private actor SuspendedActivationLibraryFeature: LibraryFeature {
    nonisolated let states = AsyncStream<LibraryFeatureState> { continuation in
        continuation.finish()
    }

    private var results: [LibraryCommandResult]
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var commands: [LibraryCommand] = []

    init(results: [LibraryCommandResult]) {
        self.results = results
    }

    var currentState: LibraryFeatureState {
        LibraryFeatureState(selection: .awaitingBootstrap)
    }

    func send(_ command: LibraryCommand) async -> LibraryCommandResult {
        commands.append(command)
        await withCheckedContinuation { continuations.append($0) }
        return results.removeFirst()
    }

    func waitForCommandCount(_ count: Int) async {
        while commands.count < count { await Task.yield() }
    }

    func resumeNextCommand() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private actor BooleanReceiptProbe {
    private(set) var result: Bool?

    func complete(_ result: Bool) {
        self.result = result
    }
}

private func librarySelectionCatalogRow(
    _ aggregate: LibraryAggregate
) -> LibraryCatalogRow {
    let instant = try! UTCInstant("2026-08-30T12:00:00.000Z")
    switch aggregate {
    case let .session(sessionID):
        return .session(
            sessionID,
            LibrarySessionCatalogMetadata(
                acquisition: .recorded,
                createdAt: instant,
                hasSelectedTranscript: true
            )
        )
    case let .chat(chatID):
        return .chat(
            chatID,
            LibraryChatCatalogMetadata(
                title: .newChat,
                createdAt: instant,
                updatedAt: instant
            )
        )
    }
}
