@_spi(ChatConfirmationTesting) @_spi(InvocationTesting) import AudoraApplication
import AudoraDomain
@testable import AudoraMacPresentation
import Foundation
import XCTest

@MainActor
final class ChatPresentationModelTests: XCTestCase {
    func testCanonicalCoachFailureCardsProjectExactHeadingsAndBodies() {
        XCTAssertEqual(
            CoachResponseFailurePresentation.card(for: .coachProviderError),
            CoachResponseFailureCardPresentation(
                heading: "Coach provider error",
                body: "The coach could not complete the request."
            )
        )
        XCTAssertEqual(
            CoachResponseFailurePresentation.card(for: .coachResponseInvalid),
            CoachResponseFailureCardPresentation(
                heading: "Coach response couldn't be used",
                body: "The coach returned an incomplete or invalid response."
            )
        )
        XCTAssertEqual(
            CoachResponseFailurePresentation.card(
                for: .coachResponseInterrupted
            ),
            CoachResponseFailureCardPresentation(
                heading: "Coach response was interrupted",
                body: nil
            )
        )
        XCTAssertEqual(
            CoachResponseFailurePresentation.card(for: nil),
            CoachResponseFailureCardPresentation(
                heading: "Coach response was interrupted",
                body: nil
            )
        )
    }

    func testTranscriptFailureCardResolvesOnlyCurrentChatAttachments() throws {
        let firstAttachmentID = try ChatSessionAttachmentID("attachment-1")
        let secondAttachmentID = try ChatSessionAttachmentID("attachment-2")
        let otherAttachmentID = try ChatSessionAttachmentID("attachment-other")
        let firstSessionID = try SessionID("ses-20260830T120000000Z-1ABC")
        let attachments = try ChatAttachments(
            validating: [
                ChatSessionAttachment(
                    attachmentID: firstAttachmentID,
                    sessionID: firstSessionID,
                    transcriptRevisionID: try TranscriptRevisionID(
                        "trv-20260830T120000000Z-2DEF"
                    )
                ),
                ChatSessionAttachment(
                    attachmentID: otherAttachmentID,
                    sessionID: try SessionID(
                        "ses-20260830T120000000Z-3GHJ"
                    ),
                    transcriptRevisionID: try TranscriptRevisionID(
                        "trv-20260830T120000000Z-4JKM"
                    )
                ),
            ]
        )
        let failure = PendingUserTurnFailure.coachTranscriptReadFailed(
            try CoachTranscriptReadFailureSummary(
                sessions: [
                    CoachTranscriptReadFailureSession(
                        sessionAttachmentID: firstAttachmentID,
                        displayLabel: "Opening practice"
                    ),
                    CoachTranscriptReadFailureSession(
                        sessionAttachmentID: secondAttachmentID,
                        displayLabel: "Weekly review"
                    ),
                ],
                additionalSessionCount: 0
            )
        )

        XCTAssertEqual(
            CoachResponseFailurePresentation.card(
                for: failure,
                attachments: attachments
            ),
            CoachResponseFailureCardPresentation(
                heading: "Some Sessions couldn't be read",
                body: "The Coach stopped before publishing anything. Open the affected Sessions, then Retry.",
                sessionLinks: [
                    CoachResponseFailureSessionLinkPresentation(
                        attachmentID: firstAttachmentID,
                        displayLabel: "Opening practice",
                        sessionID: firstSessionID
                    ),
                ],
                additionalSessionCount: 0
            )
        )
    }

    func testTranscriptFailureSessionLinkRoutesToProcessingAndReview() throws {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120000000Z-1ABC")
        )
        let attachmentID = try ChatSessionAttachmentID("attachment-1")
        let sessionID = try SessionID("ses-20260830T120000000Z-2DEF")
        let attachments = try ChatAttachments(
            validating: [
                ChatSessionAttachment(
                    attachmentID: attachmentID,
                    sessionID: sessionID,
                    transcriptRevisionID: try TranscriptRevisionID(
                        "trv-20260830T120000000Z-3GHJ"
                    )
                ),
            ]
        )
        let summary = try CoachTranscriptReadFailureSummary(
            sessions: [
                CoachTranscriptReadFailureSession(
                    sessionAttachmentID: attachmentID,
                    displayLabel: "Opening practice"
                ),
            ],
            additionalSessionCount: 0
        )
        let link = try XCTUnwrap(
            CoachResponseFailurePresentation.card(
                for: .coachTranscriptReadFailed(summary),
                attachments: attachments
            ).sessionLinks.first
        )
        var processingSelections: [SessionProcessingSelection] = []
        var reviewSelections: [ReviewSelection] = []
        let routing = LibrarySessionLinkRouting(
            scope: scope,
            selectProcessing: { processingSelections.append($0) },
            selectReview: { reviewSelections.append($0) }
        )
        let renderedLink = CoachResponseFailureSessionLinkView(
            link: link,
            onOpenSession: routing.openSession
        )

        renderedLink.openSession()

        XCTAssertEqual(
            processingSelections,
            [SessionProcessingSelection(scope: scope, sessionID: sessionID)]
        )
        XCTAssertEqual(
            reviewSelections,
            [ReviewSelection(scope: scope, sessionID: sessionID)]
        )
    }

    func testEvidenceLinkRoutesExactReferenceToProcessingAndReview() throws {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120000000Z-1ABC")
        )
        let reference = try EvidenceReference(
            sessionID: SessionID("ses-20260830T120000000Z-2DEF"),
            transcriptRevisionID: TranscriptRevisionID(
                "trv-20260830T120000000Z-3GHJ"
            ),
            target: .wordRange(
                startWordID: TranscriptWordID("w000001"),
                endWordID: TranscriptWordID("w000002")
            ),
            display: EvidenceReferenceDisplay(
                sessionLabel: "Opening practice",
                trustedText: "A trusted phrase",
                startMilliseconds: 100,
                endMilliseconds: 300
            )
        )
        var processingSelections: [SessionProcessingSelection] = []
        var openedEvidence: [(EvidenceReference, LibraryScope)] = []
        let routing = LibrarySessionLinkRouting(
            scope: scope,
            selectProcessing: { processingSelections.append($0) },
            selectReview: { _ in },
            openReviewEvidence: { openedEvidence.append(($0, $1)) }
        )

        routing.openEvidence(reference)

        XCTAssertEqual(
            processingSelections,
            [SessionProcessingSelection(scope: scope, sessionID: reference.sessionID)]
        )
        XCTAssertEqual(openedEvidence.count, 1)
        XCTAssertEqual(openedEvidence[0].0, reference)
        XCTAssertEqual(openedEvidence[0].1, scope)
    }

    func testTranscriptFailureCardBoundsLinksAndSummarizesAdditionalSessions()
        throws
    {
        let attachmentIDs = try (1 ... 3).map {
            try ChatSessionAttachmentID("attachment-\($0)")
        }
        let sessionIDs = try (1 ... 3).map {
            try SessionID("ses-20260830T120000000Z-\($0)ABC")
        }
        let attachments = try ChatAttachments(
            validating: try zip(attachmentIDs, sessionIDs).enumerated().map {
                index, pair in
                ChatSessionAttachment(
                    attachmentID: pair.0,
                    sessionID: pair.1,
                    transcriptRevisionID: try TranscriptRevisionID(
                        "trv-20260830T120000000Z-\(index + 1)DEF"
                    )
                )
            }
        )
        let summary = try CoachTranscriptReadFailureSummary(
            sessions: try attachmentIDs.enumerated().map { index, attachmentID in
                try CoachTranscriptReadFailureSession(
                    sessionAttachmentID: attachmentID,
                    displayLabel: "Session \(index + 1)"
                )
            },
            additionalSessionCount: 2
        )

        let card = CoachResponseFailurePresentation.card(
            for: .coachTranscriptReadFailed(summary),
            attachments: attachments
        )

        XCTAssertEqual(card.sessionLinks.count, 3)
        XCTAssertEqual(card.sessionLinks.map(\.displayLabel), [
            "Session 1", "Session 2", "Session 3",
        ])
        XCTAssertEqual(card.sessionLinks.map(\.sessionID), sessionIDs)
        XCTAssertEqual(card.additionalSessionCount, 2)
    }

    func testRetryableCoachFailureActionsUseCauseNeutralAccessibilityLabels() {
        for failure in [
            PendingUserTurnFailure.coachProviderError,
            .coachResponseInvalid,
        ] {
            XCTAssertEqual(
                CoachResponseFailurePresentation.retryAccessibilityLabel(
                    for: failure
                ),
                "Retry Coach Response"
            )
            XCTAssertEqual(
                CoachResponseFailurePresentation.discardAccessibilityLabel(
                    for: failure
                ),
                "Discard Coach Response"
            )
        }
    }

    func testRejectedRetryNoticeSaysTheDraftRemainsLockedAndNamesRecoveryActions()
    {
        let recoveryText =
            "The Coach could not accept this Retry. " +
            "Your Draft remains locked; Retry or Discard."

        XCTAssertEqual(
            ChatNoticePresentation.recoveryText(for: .coachRetryUnavailable),
            recoveryText
        )
        XCTAssertEqual(
            ChatNoticePresentation.accessibilityLabel(
                for: .coachRetryUnavailable
            ),
            "Chat notice: \(recoveryText)"
        )
        XCTAssertEqual(
            ChatNoticePresentation.recoveryText(for: .coachSendUnavailable),
            "The Coach could not accept this Send. Your Draft is still editable."
        )
    }

    func testProcessingPendingTurnExposesOnlyStopWithAccessibleLabel() throws {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let base = try aggregate(
            in: scope,
            chatID: "cht-20260830T120000000Z-2ABC",
            draftID: "drf-20260830T120000000Z-3DEF",
            memoryID: "mem-20260830T120000000Z-4GHJ",
            title: "Processing Retry"
        )
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120000000Z-5KMN"),
            draftID: base.chat.draft.draftID,
            draftVersion: base.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120000000Z-6PQR"
            )
        )
        let processing = try ChatAggregate(
            chat: base.chat,
            memory: base.memory,
            pendingUserTurn: pending
        )
        let authority = InvocationStopAuthority(
            testingRequest: StopCoachInvocationRequest(
                library: scope,
                chatID: processing.chat.id,
                pendingUserTurnID: pending.id
            ),
            invocationID: try CoachInvocationID(
                "inv-20260830T120000000Z-5KMN"
            ),
            attemptID: try CoachProviderAttemptID(
                "atm-20260830T120000000Z-6NPQ"
            ),
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000324"
            )!
        )
        let row = ChatRowSnapshot(aggregate: processing)
        let state = ChatFeatureState(
            catalog: .ready(
                ChatCatalogSnapshot(allRows: [row], visibleRows: [row])
            ),
            selection: .open(processing),
            composer: .locked(processing.chat.draft, pending),
            admissionAvailability: .unavailable,
            coachInvocationStopAuthority: authority,
            activity: .invokingCoach(processing.chat.id)
        )

        let presentation = PendingUserTurnPresentation.project(
            pending,
            state: state
        )

        XCTAssertEqual(presentation, .processing)
        XCTAssertFalse(presentation.showsAdmissionUnavailableReason)
        XCTAssertEqual(presentation.recoveryActions, [.stopCoachResponse])
        XCTAssertEqual(
            presentation.recoveryActions.map(\.accessibilityLabel),
            ["Stop Coach Response"]
        )

        let stoppingState = ChatFeatureState(
            catalog: state.catalog,
            selection: state.selection,
            composer: state.composer,
            admissionAvailability: state.admissionAvailability,
            activity: .stoppingCoach(processing.chat.id)
        )
        let stoppingPresentation = PendingUserTurnPresentation.project(
            pending,
            state: stoppingState
        )
        XCTAssertEqual(stoppingPresentation, .stopping)
        XCTAssertFalse(stoppingPresentation.showsAdmissionUnavailableReason)
        XCTAssertEqual(stoppingPresentation.recoveryActions, [.stopCoachResponse])

        let duringApplicationBoundary = CoachResponseStopInteractionPresentation(
            admissionState: ApplicationCommandAdmissionState(
                isChatBoundaryPending: true
            ),
            chatState: state
        )
        XCTAssertTrue(
            duringApplicationBoundary.isEnabled,
            "Stop bypasses the active Send boundary and admission availability"
        )
        XCTAssertFalse(
            CoachResponseStopInteractionPresentation(
                admissionState: ApplicationCommandAdmissionState(
                    isOrderlyTerminationPending: true
                ),
                chatState: state
            ).isEnabled
        )
        XCTAssertTrue(
            CoachResponseStopInteractionPresentation(
                admissionState: .idle,
                chatState: ChatFeatureState(
                    catalog: state.catalog,
                    selection: state.selection,
                    composer: state.composer,
                    coachInvocationStopAuthority: authority,
                    activity: .stoppingCoach(processing.chat.id)
                )
            ).isEnabled
        )
    }

    func testStopActionCapturesCurrentContextAndOpaqueAuthority() async throws {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let aggregate = try aggregate(
            in: scope,
            chatID: "cht-20260830T120000000Z-2ABC",
            draftID: "drf-20260830T120000000Z-3DEF",
            memoryID: "mem-20260830T120000000Z-4GHJ",
            title: "Stopping"
        )
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120000000Z-5KMN"),
            draftID: aggregate.chat.draft.draftID,
            draftVersion: aggregate.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120000000Z-6PQR"
            )
        )
        let processing = try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            pendingUserTurn: pending
        )
        let authority = InvocationStopAuthority(
            testingRequest: StopCoachInvocationRequest(
                library: scope,
                chatID: processing.chat.id,
                pendingUserTurnID: pending.id
            ),
            invocationID: try CoachInvocationID(
                "inv-20260830T120000000Z-5KMN"
            ),
            attemptID: try CoachProviderAttemptID(
                "atm-20260830T120000000Z-6NPQ"
            ),
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000325"
            )!
        )
        let row = ChatRowSnapshot(aggregate: processing)
        let feature = RecordingPresentationChatFeature(
            initial: ChatFeatureState(
                catalog: .ready(
                    ChatCatalogSnapshot(allRows: [row], visibleRows: [row])
                ),
                selection: .open(processing),
                composer: .locked(processing.chat.draft, pending),
                coachInvocationStopAuthority: authority,
                activity: .invokingCoach(processing.chat.id)
            )
        )
        let model = makeChatPresentationModel(feature: feature)
        await model.start(in: activation(for: scope))
        let initialCommands = await feature.commands
        let context = try XCTUnwrap(
            startContexts(in: initialCommands).first
        )

        model.stopCoachResponse()
        await waitForCommandCount(2, in: feature)

        let commands = await feature.commands
        XCTAssertEqual(
            commands,
            [.start(context), .stopCoachResponse(context, authority)]
        )
    }

    func testInvocationControlPresentationExposesTheSameUnavailableReasonWithoutHover() throws {
        let reopensAt = try UTCInstant("2026-08-30T12:01:00.000Z")

        XCTAssertEqual(
            ChatInvocationAdmissionPresentation.unavailableReason(
                for: .cooldown(reopensAt: reopensAt)
            ),
            "Coach admission reopens at 2026-08-30T12:01:00.000Z."
        )
        XCTAssertEqual(
            ChatInvocationAdmissionPresentation.unavailableReason(for: .unavailable),
            "Coach admission availability could not be checked."
        )
        XCTAssertNil(
            ChatInvocationAdmissionPresentation.unavailableReason(for: .available)
        )
    }

    func testStartScopesTheFeatureAndPublishesItsInitialSnapshot() async throws {
        let state = ChatFeatureState(catalog: .ready(ChatCatalogSnapshot(allRows: [], visibleRows: [])))
        let feature = RecordingPresentationChatFeature(initial: state)
        let model = makeChatPresentationModel(feature: feature)
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )

        await model.start(in: activation(for: scope))

        XCTAssertEqual(model.snapshot, state)
        let commands = await feature.commands
        let context = try XCTUnwrap(startContexts(in: commands).first)
        XCTAssertEqual(commands, [.start(context)])
        XCTAssertEqual(context.libraryScope, scope)
        XCTAssertEqual(context.generation, 1)
    }

    func testReplacementActivationOfSameLibraryRestartsWithFreshContext()
        async throws
    {
        let state = ChatFeatureState(
            catalog: .ready(ChatCatalogSnapshot(allRows: [], visibleRows: []))
        )
        let feature = RecordingPresentationChatFeature(initial: state)
        let model = makeChatPresentationModel(feature: feature)
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let firstActivation = activation(for: scope, generation: 41)
        let replacementActivation = activation(for: scope, generation: 42)

        await model.start(in: firstActivation)
        await model.start(in: replacementActivation)

        let contexts = startContexts(in: await feature.commands)
        XCTAssertEqual(contexts.map(\.libraryScope), [scope, scope])
        XCTAssertEqual(contexts.map(\.generation), [41, 42])
    }

    func testReplacementActivationNeverProjectsPriorGenerationStateWhileStartSuspends()
        async throws
    {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let prior = ChatFeatureState(notice: .catalogFailed)
        let replacement = ChatFeatureState(notice: .createFailed)
        let feature = SuspendedSameLibraryReplacementChatFeature(
            prior: prior,
            replacement: replacement
        )
        let model = makeChatPresentationModel(feature: feature)
        await model.start(in: activation(for: scope, generation: 41))
        XCTAssertEqual(model.snapshot, prior)

        let replacementStart = Task {
            await model.start(in: activation(for: scope, generation: 42))
        }
        await feature.waitUntilReplacementStartSuspends()

        XCTAssertEqual(
            model.snapshot,
            ChatFeatureState(
                catalog: .loading,
                filterQuery: .empty,
                selection: .none
            )
        )

        await feature.resumeReplacementStart()
        await replacementStart.value
        XCTAssertEqual(model.snapshot, replacement)
    }

    func testFilterInputDispatchesOnlyValidatedPureFilterCommands() async throws {
        let state = ChatFeatureState(
            catalog: .ready(ChatCatalogSnapshot(allRows: [], visibleRows: []))
        )
        let feature = RecordingPresentationChatFeature(initial: state)
        let model = makeChatPresentationModel(feature: feature)
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        await model.start(in: activation(for: scope))
        let startCommands = await feature.commands
        let context = try XCTUnwrap(startContexts(in: startCommands).first)

        model.updateFilter("reflection")
        await waitForCommandCount(2, in: feature)
        let validCommands = await feature.commands
        XCTAssertEqual(
            validCommands,
            [.start(context), .setFilter(context, try ChatFilterQuery("reflection"))]
        )

        model.updateFilter("unsafe\u{0000}filter")
        await Task.yield()
        let commandsAfterInvalidInput = await feature.commands
        XCTAssertEqual(commandsAfterInvalidInput, validCommands)
    }

    func testNewChatKeyboardInteractionsDispatchSearchManyToggleDefaultAndCancel() async throws {
        let confirmationToken = NewChatConfirmationToken(
            testingValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000325"
            )!
        )
        let feature = RecordingPresentationChatFeature(
            initial: ChatFeatureState(
                catalog: .ready(ChatCatalogSnapshot(allRows: [], visibleRows: [])),
                newChatPicker: .ready(
                    ChatAttachmentPickerSnapshot(
                        allRows: [],
                        visibleRows: [],
                        selectedAttachmentIDs: [],
                        filterQuery: .empty,
                        feasibility: .quoting,
                        confirmationToken: confirmationToken
                    )
                )
            )
        )
        let model = makeChatPresentationModel(feature: feature)
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let first = try ChatSessionAttachmentID("attachment-000001")
        let second = try ChatSessionAttachmentID("attachment-000002")
        await model.start(in: activation(for: scope))
        let startCommands = await feature.commands
        let context = try XCTUnwrap(
            startContexts(in: startCommands).first
        )

        model.beginNewChat()
        await waitForCommandCount(2, in: feature)
        model.updateNewChatAttachmentFilter("café")
        await waitForCommandCount(3, in: feature)
        model.performNewChatAttachmentPickerAction(.toggle(first))
        await waitForCommandCount(4, in: feature)
        model.performNewChatAttachmentPickerAction(.toggle(second))
        await waitForCommandCount(5, in: feature)
        model.performNewChatAttachmentPickerAction(.defaultAction)
        await waitForCommandCount(6, in: feature)
        model.performNewChatAttachmentPickerAction(.cancelAction)
        await waitForCommandCount(7, in: feature)

        let commands = await feature.commands
        XCTAssertEqual(
            commands,
            [
                .start(context),
                .beginNewChat(context),
                .setNewChatAttachmentFilter(
                    context,
                    try ChatAttachmentFilterQuery("café")
                ),
                .toggleNewChatAttachment(context, first),
                .toggleNewChatAttachment(context, second),
                .confirmNewChat(context, confirmationToken),
                .cancelNewChat(context),
            ]
        )
    }

    func testNewChatConfigurationRecoveryDispatchesCandidateReprojection() async throws {
        let feature = RecordingPresentationChatFeature(
            initial: ChatFeatureState(
                catalog: .ready(ChatCatalogSnapshot(allRows: [], visibleRows: [])),
                newChatPicker: .ready(
                    ChatAttachmentPickerSnapshot(
                        allRows: [],
                        visibleRows: [],
                        selectedAttachmentIDs: [],
                        filterQuery: .empty,
                        feasibility: .unavailable(.sourceUnavailable),
                        issue: .qualifiedConfigurationUnavailable
                    )
                )
            )
        )
        let model = makeChatPresentationModel(feature: feature)
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        await model.start(in: activation(for: scope))
        let startCommands = await feature.commands
        let context = try XCTUnwrap(startContexts(in: startCommands).first)

        model.retryNewChatConfiguration()
        await waitForCommandCount(2, in: feature)

        let commands = await feature.commands
        XCTAssertEqual(commands, [.start(context), .beginNewChat(context)])
    }

    func testNewChatSheetProjectionKeepsCancellationAvailableUntilDurableCreation() {
        let readyState = ChatFeatureState(
            catalog: .ready(ChatCatalogSnapshot(allRows: [], visibleRows: []))
        )
        let open = NewChatSheetInteractionPresentation(
            admissionState: .idle,
            chatState: readyState
        )

        XCTAssertTrue(open.allowsControlInteraction)
        XCTAssertTrue(open.allowsCancellation)
        XCTAssertFalse(open.preventsInteractiveDismissal)
        XCTAssertNil(open.busyAccessibilityLabel)

        let resolvingOrQuoting = NewChatSheetInteractionPresentation(
            admissionState: ApplicationCommandAdmissionState(
                isChatBoundaryPending: true
            ),
            chatState: readyState
        )
        XCTAssertFalse(resolvingOrQuoting.allowsControlInteraction)
        XCTAssertTrue(resolvingOrQuoting.allowsCancellation)
        XCTAssertFalse(resolvingOrQuoting.preventsInteractiveDismissal)
        XCTAssertEqual(
            resolvingOrQuoting.busyAccessibilityLabel,
            "New Chat is busy. Search, Session selection, and Create Chat are temporarily unavailable. Cancel remains available."
        )

        let libraryNavigation = NewChatSheetInteractionPresentation(
            admissionState: ApplicationCommandAdmissionState(
                isLibraryNavigationPending: true
            ),
            chatState: readyState
        )
        XCTAssertFalse(libraryNavigation.allowsControlInteraction)
        XCTAssertTrue(libraryNavigation.allowsCancellation)
        XCTAssertFalse(libraryNavigation.preventsInteractiveDismissal)

        let orderlyTermination = NewChatSheetInteractionPresentation(
            admissionState: ApplicationCommandAdmissionState(
                isOrderlyTerminationPending: true
            ),
            chatState: readyState
        )
        XCTAssertFalse(orderlyTermination.allowsControlInteraction)
        XCTAssertFalse(orderlyTermination.allowsCancellation)
        XCTAssertTrue(orderlyTermination.preventsInteractiveDismissal)

        let creating = NewChatSheetInteractionPresentation(
            admissionState: ApplicationCommandAdmissionState(
                isChatBoundaryPending: true
            ),
            chatState: ChatFeatureState(
                catalog: .ready(ChatCatalogSnapshot(allRows: [], visibleRows: [])),
                activity: .creating
            )
        )
        XCTAssertFalse(creating.allowsControlInteraction)
        XCTAssertFalse(creating.allowsCancellation)
        XCTAssertTrue(creating.preventsInteractiveDismissal)
        XCTAssertEqual(
            creating.busyAccessibilityLabel,
            "New Chat is being created. Search, Session selection, Cancel, and Create Chat are unavailable."
        )
    }

    func testUserActionsCaptureTheCurrentLibraryCommandContext() async throws {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let chatID = try ChatID("cht-20260830T120000000Z-2ABC")
        let aggregate = try aggregate(
            in: scope,
            chatID: chatID.rawValue,
            draftID: "drf-20260830T120000000Z-3DEF",
            memoryID: "mem-20260830T120000000Z-4GHJ",
            title: "New Chat"
        )
        let row = ChatRowSnapshot(aggregate: aggregate)
        let state = ChatFeatureState(
            catalog: .ready(ChatCatalogSnapshot(allRows: [row], visibleRows: [row])),
            selection: .open(aggregate),
            composer: .editable(aggregate.chat.draft, isDirty: false)
        )
        let feature = RecordingPresentationChatFeature(initial: state)
        let model = makeChatPresentationModel(feature: feature)
        await model.start(in: activation(for: scope))
        let startCommands = await feature.commands
        let context = try XCTUnwrap(startContexts(in: startCommands).first)

        model.open(chatID)
        await waitForCommandCount(2, in: feature)
        model.rename(chatID, title: "Focused Practice", expectedRevision: 4)
        await waitForCommandCount(3, in: feature)
        model.updateDraft("A synthetic coaching Draft")
        await waitForCommandCount(4, in: feature)
        model.refreshContextQuote()
        await waitForCommandCount(5, in: feature)
        model.sendDraft()
        await waitForCommandCount(6, in: feature)
        let pendingID = try PendingUserTurnID("ptu-20260830T120000000Z-5KMN")
        model.retryPendingUserTurn(pendingID)
        await waitForCommandCount(7, in: feature)
        model.createNewChatFromCapacityFailure(pendingID)
        await waitForCommandCount(8, in: feature)
        model.discardPendingUserTurn(pendingID)
        await waitForCommandCount(9, in: feature)

        let commands = await feature.commands
        XCTAssertEqual(
            commands,
            [
                .start(context),
                .open(context, chatID),
                .rename(context, chatID, title: "Focused Practice", expectedRevision: 4),
                .editDraft(
                    context,
                    aggregate.chat.id,
                    aggregate.chat.draft.draftID,
                    text: "A synthetic coaching Draft"
                ),
                .refreshContextQuote(
                    context,
                    aggregate.chat.id,
                    aggregate.chat.draft
                ),
                .sendDraft(context, aggregate.chat.id, aggregate.chat.draft),
                .retryPendingUserTurn(context, pendingID),
                .createNewChatFromCapacityFailure(context, pendingID),
                .discardPendingUserTurn(context, pendingID),
            ]
        )
    }

    func testProfileProposalCardProjectsEveryChangeAndOnlyAcceptDiscard() throws {
        let chatID = try ChatID("cht-20260909T120000000Z-1ABC")
        let proposal = try profileProposal(for: chatID)

        let card = ProfileProposalCardPresentation(proposal)

        XCTAssertEqual(card.proposalID, proposal.id)
        XCTAssertEqual(
            card.changes,
            [
                ProfileProposalChangePresentation(
                    operation: .add,
                    statementKindLabel: "Goal",
                    currentWording: nil,
                    proposedWording: "Pause after each main idea.",
                    evidence: [try evidenceReference(index: 1)]
                ),
                ProfileProposalChangePresentation(
                    operation: .replace,
                    statementKindLabel: "Speaking observation",
                    currentWording: "I rush transitions between ideas.",
                    proposedWording: "I can make transitions easier to follow.",
                    evidence: [try evidenceReference(index: 2)]
                ),
                ProfileProposalChangePresentation(
                    operation: .retire,
                    statementKindLabel: "Coaching preference",
                    currentWording: "Give me a long written debrief.",
                    proposedWording: nil,
                    evidence: [try evidenceReference(index: 3)]
                ),
            ]
        )
        XCTAssertEqual(
            card.evidenceAppends,
            [
                ProfileEvidenceAppendPresentation(
                    statementKindLabel: "Self-assessment",
                    targetWording: "I speak clearly when I slow down.",
                    evidence: [try evidenceReference(index: 4)]
                ),
            ]
        )
        XCTAssertEqual(
            card.changes.map(\.heading),
            [
                "Add Goal",
                "Replace Speaking observation",
                "Retire Coaching preference",
            ]
        )
        XCTAssertEqual(
            card.evidenceAppends.map(\.heading),
            ["Add evidence to Self-assessment"]
        )
        XCTAssertEqual(
            ProfileProposalCardPresentation.explanatoryCopy,
            "Want to change this suggestion? Discard it, continue chatting with the coach, then ask the coach to remember the result."
        )
        XCTAssertEqual(
            ProfileProposalCardPresentation.actionTitles,
            ["Accept", "Discard"]
        )
        XCTAssertFalse(
            ProfileProposalCardPresentation.actionTitles.contains("Discuss")
        )
    }

    func testProfileEffectActionsReplaceAcceptAndLocalRetryWhenStale()
        throws
    {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260909T121000000Z-1ABC")
        )
        let base = try aggregate(
            in: scope,
            chatID: "cht-20260909T121100000Z-2DEF",
            draftID: "drf-20260909T121100000Z-3GHJ",
            memoryID: "mem-20260909T121100000Z-4KMN",
            title: "Profile action projection",
            attachments: try profileProposalAttachments()
        )
        let proposal = try profileProposal(for: base.chat.id)
        let sourceIdentity = ChatProfileEffectIdentity.proposal(proposal.id)
        let proposed = try ChatAggregate(
            chat: base.chat,
            memory: base.memory,
            profileEffect: .proposal(proposal)
        )
        let basis = try staleBasis(for: proposal)

        let current = ChatFeatureState(
            catalog: .ready(
                ChatCatalogSnapshot(allRows: [], visibleRows: [])
            ),
            selection: .open(proposed),
            profileEffectReview: .current(sourceIdentity)
        )
        XCTAssertEqual(
            ProfileEffectRecoveryPresentation.actions(
                for: sourceIdentity,
                in: current
            ),
            [.acceptProposal, .discardEffect]
        )

        let stale = ChatFeatureState(
            catalog: current.catalog,
            selection: .open(proposed),
            admissionAvailability: .available,
            profileEffectReview: .stale(basis)
        )
        let staleActions = ProfileEffectRecoveryPresentation.actions(
            for: sourceIdentity,
            in: stale
        )
        XCTAssertEqual(staleActions, [.reconsider, .discardEffect])
        XCTAssertFalse(staleActions.contains(.acceptProposal))
        XCTAssertFalse(staleActions.contains(.retryEvidencePublication))

        let failedReconsideration = ProfileReconsideration(
            sourceEffect: .proposal(proposal),
            resultResponsePositionID: try ChatResponsePositionID(
                "rsp-20260909T121200000Z-5PQR"
            ),
            failure: .coachResponseInterrupted
        )
        let failed = try ChatAggregate(
            chat: base.chat,
            memory: base.memory,
            profileEffect: .proposal(proposal),
            profileReconsideration: failedReconsideration
        )
        let retryable = ChatFeatureState(
            catalog: current.catalog,
            selection: .open(failed),
            admissionAvailability: .available,
            profileEffectReview: .stale(basis)
        )
        XCTAssertEqual(
            ProfileEffectRecoveryPresentation.actions(
                for: sourceIdentity,
                in: retryable
            ),
            [.retryReconsideration, .discardReconsiderationFailure]
        )

        let activeReconsideration = failedReconsideration.replacingFailure(nil)
        let processing = try ChatAggregate(
            chat: base.chat,
            memory: base.memory,
            profileEffect: .proposal(proposal),
            profileReconsideration: activeReconsideration
        )
        let stopRequest = StopProfileReconsiderationInvocationRequest(
            library: scope,
            chatID: base.chat.id,
            sourceEffectIdentity: sourceIdentity,
            resultResponsePositionID:
                activeReconsideration.resultResponsePositionID
        )
        let stopAuthority = ProfileReconsiderationInvocationStopAuthority(
            testingRequest: stopRequest,
            invocationID: try CoachInvocationID(
                "inv-20260909T121300000Z-6RST"
            ),
            attemptID: try CoachProviderAttemptID(
                "atm-20260909T121300000Z-7VWX"
            ),
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000327"
            )!
        )
        let stopping = ChatFeatureState(
            catalog: current.catalog,
            selection: .open(processing),
            admissionAvailability: .available,
            profileReconsiderationStopAuthority: stopAuthority,
            profileEffectReview: .stale(basis),
            activity: .reconsideringProfileEffect(base.chat.id)
        )
        XCTAssertEqual(
            ProfileEffectRecoveryPresentation.actions(
                for: sourceIdentity,
                in: stopping
            ),
            [.stopReconsideration]
        )
        XCTAssertTrue(
            ProfileReconsiderationStopInteractionPresentation(
                admissionState: .idle,
                chatState: stopping
            ).isEnabled
        )
    }

    func testProfileProposalActionsCaptureCurrentContextAndExactProposalID()
        async throws
    {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260909T115900000Z-1ABC")
        )
        let base = try aggregate(
            in: scope,
            chatID: "cht-20260909T120000000Z-2DEF",
            draftID: "drf-20260909T120000000Z-3GHJ",
            memoryID: "mem-20260909T120000000Z-4KMN",
            title: "Profile review",
            attachments: try profileProposalAttachments()
        )
        let proposal = try profileProposal(for: base.chat.id)
        let proposed = try ChatAggregate(
            chat: base.chat,
            memory: base.memory,
            profileProposal: proposal
        )
        let row = ChatRowSnapshot(aggregate: proposed)
        let state = ChatFeatureState(
            catalog: .ready(
                ChatCatalogSnapshot(allRows: [row], visibleRows: [row])
            ),
            selection: .open(proposed),
            composer: .editable(proposed.chat.draft, isDirty: false),
            admissionAvailability: .available,
            profileEffectReview: .current(.proposal(proposal.id))
        )
        let feature = RecordingPresentationChatFeature(initial: state)
        let model = makeChatPresentationModel(feature: feature)
        await model.start(in: activation(for: scope))
        let startCommands = await feature.commands
        let context = try XCTUnwrap(
            startContexts(in: startCommands).first
        )

        model.acceptProfileProposal(proposal.id)
        await waitForCommandCount(2, in: feature)
        model.discardProfileProposal(proposal.id)
        await waitForCommandCount(3, in: feature)

        let commands = await feature.commands
        XCTAssertEqual(
            commands,
            [
                .start(context),
                .acceptProfileProposal(context, proposal.id),
                .discardProfileProposal(context, proposal.id),
            ]
        )
    }

    func testStaleProfileEffectActionsCaptureExactIdentityAndFailureLifecycle()
        async throws
    {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260909T123000000Z-1ABC")
        )
        let base = try aggregate(
            in: scope,
            chatID: "cht-20260909T123100000Z-2DEF",
            draftID: "drf-20260909T123100000Z-3GHJ",
            memoryID: "mem-20260909T123100000Z-4KMN",
            title: "Reconsider Profile",
            attachments: try profileProposalAttachments()
        )
        let proposal = try profileProposal(for: base.chat.id)
        let basis = try staleBasis(for: proposal)
        let reconsideration = ProfileReconsideration(
            sourceEffect: .proposal(proposal),
            resultResponsePositionID: try ChatResponsePositionID(
                "rsp-20260909T123200000Z-5PQR"
            ),
            failure: .coachResponseInterrupted
        )
        let failed = try ChatAggregate(
            chat: base.chat,
            memory: base.memory,
            profileEffect: .proposal(proposal),
            profileReconsideration: reconsideration
        )
        let row = ChatRowSnapshot(aggregate: failed)
        let state = ChatFeatureState(
            catalog: .ready(
                ChatCatalogSnapshot(allRows: [row], visibleRows: [row])
            ),
            selection: .open(failed),
            composer: .editable(failed.chat.draft, isDirty: false),
            admissionAvailability: .available,
            profileEffectReview: .stale(basis)
        )
        let feature = RecordingPresentationChatFeature(initial: state)
        let model = makeChatPresentationModel(feature: feature)
        await model.start(in: activation(for: scope))
        let startCommands = await feature.commands
        let context = try XCTUnwrap(
            startContexts(in: startCommands).first
        )

        let sourceIdentity = ChatProfileEffectIdentity.proposal(proposal.id)
        model.retryProfileReconsideration(sourceIdentity)
        await waitForCommandCount(2, in: feature)
        model.discardProfileReconsiderationFailure(sourceIdentity)
        await waitForCommandCount(3, in: feature)

        let commands = await feature.commands
        XCTAssertEqual(
            commands,
            [
                .start(context),
                .retryProfileReconsideration(context, sourceIdentity),
                .discardProfileReconsiderationFailure(
                    context,
                    sourceIdentity
                ),
            ]
        )

        let operationalReconsideration = reconsideration.replacingFailure(nil)
        let operationalAggregate = try ChatAggregate(
            chat: base.chat,
            memory: base.memory,
            profileEffect: .proposal(proposal),
            profileReconsideration: operationalReconsideration
        )
        let operationalRequest = ProfileReconsiderationInvocationRequest(
            library: scope,
            chatID: base.chat.id,
            sourceEffectIdentity: sourceIdentity,
            resultResponsePositionID:
                operationalReconsideration.resultResponsePositionID
        )
        let operationalState = ChatFeatureState(
            catalog: state.catalog,
            selection: .open(operationalAggregate),
            composer: .editable(
                operationalAggregate.chat.draft,
                isDirty: false
            ),
            admissionAvailability: .available,
            operationallyInterruptedProfileReconsideration:
                operationalRequest,
            profileEffectReview: .stale(basis)
        )
        XCTAssertEqual(
            ProfileEffectRecoveryPresentation.actions(
                for: sourceIdentity,
                in: operationalState
            ),
            [.retryReconsideration]
        )
        let operationalFeature = RecordingPresentationChatFeature(
            initial: operationalState
        )
        let operationalModel = makeChatPresentationModel(
            feature: operationalFeature
        )
        await operationalModel.start(in: activation(for: scope))
        let operationalStartCommands = await operationalFeature.commands
        let operationalContext = try XCTUnwrap(
            startContexts(in: operationalStartCommands).first
        )

        operationalModel.retryProfileReconsideration(sourceIdentity)
        await waitForCommandCount(2, in: operationalFeature)

        let operationalCommands = await operationalFeature.commands
        XCTAssertEqual(
            operationalCommands,
            [
                .start(operationalContext),
                .retryProfileReconsideration(
                    operationalContext,
                    sourceIdentity
                ),
            ]
        )
    }

    func testStopProfileReconsiderationRoutesExactSnapshotAuthority()
        async throws
    {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260909T123500000Z-1ABC")
        )
        let base = try aggregate(
            in: scope,
            chatID: "cht-20260909T123600000Z-2DEF",
            draftID: "drf-20260909T123600000Z-3GHJ",
            memoryID: "mem-20260909T123600000Z-4KMN",
            title: "Stop Reconsider",
            attachments: try profileProposalAttachments()
        )
        let proposal = try profileProposal(for: base.chat.id)
        let sourceIdentity = ChatProfileEffectIdentity.proposal(proposal.id)
        let reconsideration = ProfileReconsideration(
            sourceEffectIdentity: sourceIdentity,
            resultResponsePositionID: try ChatResponsePositionID(
                "rsp-20260909T123700000Z-5PQR"
            )
        )
        let processing = try ChatAggregate(
            chat: base.chat,
            memory: base.memory,
            profileEffect: .proposal(proposal),
            profileReconsideration: reconsideration
        )
        let request = StopProfileReconsiderationInvocationRequest(
            library: scope,
            chatID: base.chat.id,
            sourceEffectIdentity: sourceIdentity,
            resultResponsePositionID:
                reconsideration.resultResponsePositionID
        )
        let authority = ProfileReconsiderationInvocationStopAuthority(
            testingRequest: request,
            invocationID: try CoachInvocationID(
                "inv-20260909T123700000Z-6RST"
            ),
            attemptID: try CoachProviderAttemptID(
                "atm-20260909T123700000Z-7VWX"
            ),
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000328"
            )!
        )
        let state = ChatFeatureState(
            catalog: .ready(
                ChatCatalogSnapshot(allRows: [], visibleRows: [])
            ),
            selection: .open(processing),
            admissionAvailability: .available,
            profileReconsiderationStopAuthority: authority,
            profileEffectReview: .stale(try staleBasis(for: proposal)),
            activity: .reconsideringProfileEffect(base.chat.id)
        )
        let feature = RecordingPresentationChatFeature(initial: state)
        let model = makeChatPresentationModel(feature: feature)
        await model.start(in: activation(for: scope))
        let startCommands = await feature.commands
        let context = try XCTUnwrap(startContexts(in: startCommands).first)

        model.stopProfileReconsideration()
        await waitForCommandCount(2, in: feature)

        let commands = await feature.commands
        XCTAssertEqual(
            commands,
            [
                .start(context),
                .stopProfileReconsideration(context, authority),
            ]
        )
    }

    func testStaleProfileEffectReconsiderActionRequiresNoFailureSidecar()
        async throws
    {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260909T124000000Z-1ABC")
        )
        let base = try aggregate(
            in: scope,
            chatID: "cht-20260909T124100000Z-2DEF",
            draftID: "drf-20260909T124100000Z-3GHJ",
            memoryID: "mem-20260909T124100000Z-4KMN",
            title: "Stale Profile",
            attachments: try profileProposalAttachments()
        )
        let proposal = try profileProposal(for: base.chat.id)
        let basis = try staleBasis(for: proposal)
        let stale = try ChatAggregate(
            chat: base.chat,
            memory: base.memory,
            profileEffect: .proposal(proposal)
        )
        let row = ChatRowSnapshot(aggregate: stale)
        let state = ChatFeatureState(
            catalog: .ready(
                ChatCatalogSnapshot(allRows: [row], visibleRows: [row])
            ),
            selection: .open(stale),
            composer: .editable(stale.chat.draft, isDirty: false),
            admissionAvailability: .available,
            profileEffectReview: .stale(basis)
        )
        let feature = RecordingPresentationChatFeature(initial: state)
        let model = makeChatPresentationModel(feature: feature)
        await model.start(in: activation(for: scope))
        let startCommands = await feature.commands
        let context = try XCTUnwrap(
            startContexts(in: startCommands).first
        )

        let sourceIdentity = ChatProfileEffectIdentity.proposal(proposal.id)
        model.reconsiderProfileEffect(sourceIdentity)
        await waitForCommandCount(2, in: feature)

        let commands = await feature.commands
        XCTAssertEqual(
            commands,
            [
                .start(context),
                .reconsiderProfileEffect(context, sourceIdentity),
            ]
        )
    }

    func testUnresolvedProfileProposalBlocksDraftEditsAndSendProjection()
        async throws
    {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260909T125900000Z-1ABC")
        )
        let base = try aggregate(
            in: scope,
            chatID: "cht-20260909T130000000Z-2DEF",
            draftID: "drf-20260909T130000000Z-3GHJ",
            memoryID: "mem-20260909T130000000Z-4KMN",
            title: "Blocked Draft",
            attachments: try profileProposalAttachments()
        )
        let proposal = try profileProposal(for: base.chat.id)
        let proposed = try ChatAggregate(
            chat: base.chat,
            memory: base.memory,
            profileProposal: proposal
        )
        let row = ChatRowSnapshot(aggregate: proposed)
        let state = ChatFeatureState(
            catalog: .ready(
                ChatCatalogSnapshot(allRows: [row], visibleRows: [row])
            ),
            selection: .open(proposed),
            composer: .editable(proposed.chat.draft, isDirty: false),
            admissionAvailability: .available
        )
        let feature = RecordingPresentationChatFeature(initial: state)
        let model = makeChatPresentationModel(feature: feature)
        await model.start(in: activation(for: scope))

        XCTAssertFalse(ChatInteractionPolicy.allowsComposerEditing(in: state))
        model.updateDraft("This edit must remain local to the disabled control.")
        model.sendDraft()
        await Task.yield()

        let commands = await feature.commands
        let context = try XCTUnwrap(startContexts(in: commands).first)
        XCTAssertEqual(commands, [.start(context)])
    }

    func testProfileProposalActivityAndNoticesHaveActionableCopy() throws {
        let chatID = try ChatID("cht-20260909T140000000Z-1ABC")
        XCTAssertEqual(
            ChatActivityPresentation.progressLabel(
                for: .acceptingProfileProposal(chatID)
            ),
            "Accepting Profile changes…"
        )
        XCTAssertEqual(
            ChatActivityPresentation.progressLabel(
                for: .discardingProfileProposal(chatID)
            ),
            "Discarding Profile changes…"
        )
        XCTAssertEqual(
            ChatNoticePresentation.recoveryText(
                for: .profileProposalAcceptFailed
            ),
            "The Profile changes could not be accepted. Review the proposal and try again."
        )
        XCTAssertEqual(
            ChatNoticePresentation.recoveryText(
                for: .profileProposalDiscardFailed
            ),
            "The Profile proposal could not be discarded. Review it and try again."
        )
        XCTAssertEqual(
            ChatNoticePresentation.recoveryText(for: .profileProposalStale),
            "The Profile changed elsewhere, so this suggestion must be reconsidered before it can be accepted."
        )
        XCTAssertEqual(
            ChatNoticePresentation.recoveryText(
                for: .profileEffectAssessmentFailed
            ),
            "The current Profile could not be compared with this suggestion. Reopen the Chat and try again."
        )
    }

    func testProfileEvidencePublicationFailureCardDescribesEveryExactAppend()
        throws
    {
        let chatID = try ChatID("cht-20260909T150000000Z-1ABC")
        let publication = try profileEvidencePublication(for: chatID)
        let firstReference = try evidenceReference(index: 1)
        let firstAttachment = ChatSessionAttachment(
            attachmentID: try ChatSessionAttachmentID("publication-evidence-1"),
            sessionID: firstReference.sessionID,
            transcriptRevisionID: firstReference.transcriptRevisionID
        )
        let resolved = try ResolvedChatAttachment(
            attachment: firstAttachment,
            resolution: .available(
                try ChatAttachmentCandidate(
                    sessionID: firstReference.sessionID,
                    transcriptRevisionID: firstReference.transcriptRevisionID,
                    displayLabel: "Planning reflection",
                    durationMilliseconds: 30_000,
                    approximateTranscriptTokens: 120,
                    delivery: .inline
                )
            )
        )

        let card = try XCTUnwrap(
            ProfileEvidencePublicationFailurePresentation.card(
                for: publication,
                openedAttachments: .resolved([resolved])
            )
        )

        XCTAssertEqual(card.responsePositionID, publication.responsePositionID)
        XCTAssertEqual(card.heading, "Profile evidence couldn't be saved")
        XCTAssertEqual(
            card.updates,
            [
                "Add evidence from “Planning reflection” to “Pause briefly between points.”",
                "Add evidence from “Session 2” to “Keep conclusions concise.”",
            ]
        )
        XCTAssertEqual(card.actionTitles, ["Retry", "Discard"])
        XCTAssertEqual(
            card.accessibilityLabel,
            "Profile evidence couldn't be saved. " +
                "Add evidence from “Planning reflection” to " +
                "“Pause briefly between points.” " +
                "Add evidence from “Session 2” to " +
                "“Keep conclusions concise.”"
        )
    }

    func testAbsentEvidencePublicationProducesNoFailureCard() throws {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260909T155900000Z-1ABC")
        )
        let aggregate = try aggregate(
            in: scope,
            chatID: "cht-20260909T160000000Z-2DEF",
            draftID: "drf-20260909T160000000Z-3GHJ",
            memoryID: "mem-20260909T160000000Z-4KMN",
            title: "Silent publication"
        )

        XCTAssertNil(
            ProfileEvidencePublicationFailurePresentation.card(
                for: aggregate.profileEvidencePublication,
                openedAttachments: .notRequested
            )
        )
    }

    func testAutomaticProfileEvidencePublicationStaysSilentWhileItSucceeds()
        throws
    {
        let chatID = try ChatID("cht-20260909T162000000Z-1ABC")
        let publication = try profileEvidencePublication(for: chatID)

        XCTAssertNil(
            ProfileEvidencePublicationFailurePresentation.card(
                for: publication,
                openedAttachments: .notRequested,
                activity: .publishingProfileEvidence(chatID)
            )
        )
        XCTAssertNotNil(
            ProfileEvidencePublicationFailurePresentation.card(
                for: publication,
                openedAttachments: .notRequested,
                activity: .retryingProfileEvidencePublication(chatID)
            )
        )
    }

    func testProfileEvidencePublicationFailureActionsCaptureExactResponsePosition()
        async throws
    {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260909T165900000Z-1ABC")
        )
        let base = try aggregate(
            in: scope,
            chatID: "cht-20260909T170000000Z-2DEF",
            draftID: "drf-20260909T170000000Z-3GHJ",
            memoryID: "mem-20260909T170000000Z-4KMN",
            title: "Publication recovery",
            attachments: try profileProposalAttachments()
        )
        let publication = try profileEvidencePublication(for: base.chat.id)
        let failed = try aggregate(
            byStaging: publication,
            on: base
        )
        let row = ChatRowSnapshot(aggregate: failed)
        let state = ChatFeatureState(
            catalog: .ready(
                ChatCatalogSnapshot(allRows: [row], visibleRows: [row])
            ),
            selection: .open(failed),
            composer: .editable(failed.chat.draft, isDirty: false),
            admissionAvailability: .cooldown(
                reopensAt: try UTCInstant("2026-09-09T17:01:00.000Z")
            ),
            profileEffectReview: .current(
                .evidencePublication(publication.responsePositionID)
            )
        )
        let feature = RecordingPresentationChatFeature(initial: state)
        let model = makeChatPresentationModel(feature: feature)
        await model.start(in: activation(for: scope))
        let startCommands = await feature.commands
        let context = try XCTUnwrap(startContexts(in: startCommands).first)

        model.retryProfileEvidencePublication(publication.responsePositionID)
        await waitForCommandCount(2, in: feature)
        model.discardProfileEvidencePublication(publication.responsePositionID)
        await waitForCommandCount(3, in: feature)

        let commands = await feature.commands
        XCTAssertEqual(
            commands,
            [
                .start(context),
                .retryProfileEvidencePublication(
                    context,
                    publication.responsePositionID
                ),
                .discardProfileEvidencePublication(
                    context,
                    publication.responsePositionID
                ),
            ]
        )
    }

    func testProfileEvidencePublicationFailureBlocksDraftEditsAndSendProjection()
        async throws
    {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260909T175900000Z-1ABC")
        )
        let base = try aggregate(
            in: scope,
            chatID: "cht-20260909T180000000Z-2DEF",
            draftID: "drf-20260909T180000000Z-3GHJ",
            memoryID: "mem-20260909T180000000Z-4KMN",
            title: "Blocked by publication",
            attachments: try profileProposalAttachments()
        )
        let publication = try profileEvidencePublication(for: base.chat.id)
        let failed = try aggregate(
            byStaging: publication,
            on: base
        )
        let row = ChatRowSnapshot(aggregate: failed)
        let state = ChatFeatureState(
            catalog: .ready(
                ChatCatalogSnapshot(allRows: [row], visibleRows: [row])
            ),
            selection: .open(failed),
            composer: .editable(failed.chat.draft, isDirty: false),
            admissionAvailability: .available
        )
        let feature = RecordingPresentationChatFeature(initial: state)
        let model = makeChatPresentationModel(feature: feature)
        await model.start(in: activation(for: scope))

        XCTAssertFalse(ChatInteractionPolicy.allowsComposerEditing(in: state))
        model.updateDraft("This must stay in the disabled control.")
        model.sendDraft()
        await Task.yield()

        let commands = await feature.commands
        let context = try XCTUnwrap(startContexts(in: commands).first)
        XCTAssertEqual(commands, [.start(context)])
    }

    func testProfileEvidencePublicationActivitiesHaveActionableCopy() throws {
        let chatID = try ChatID("cht-20260909T190000000Z-1ABC")
        XCTAssertNil(
            ChatActivityPresentation.progressLabel(
                for: .publishingProfileEvidence(chatID)
            )
        )
        XCTAssertEqual(
            ChatActivityPresentation.progressLabel(
                for: .retryingProfileEvidencePublication(chatID)
            ),
            "Retrying Profile evidence…"
        )
        XCTAssertEqual(
            ChatActivityPresentation.progressLabel(
                for: .discardingProfileEvidencePublication(chatID)
            ),
            "Discarding Profile evidence…"
        )
    }

    func testChatRowIndicatorPresentationKeepsActivityAndProfileAccessible()
        throws
    {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let aggregate = try aggregate(
            in: scope,
            chatID: "cht-20260830T120000000Z-2ABC",
            draftID: "drf-20260830T120000000Z-3DEF",
            memoryID: "mem-20260830T120000000Z-4GHJ",
            title: "Weekly reflection"
        )
        let presentation = ChatRowIndicatorPresentation(
            indicators: ChatRowIndicators(
                activity: .interrupted,
                profileUpdate: .pendingApproval
            )
        )

        XCTAssertEqual(
            presentation.activitySymbolName,
            "exclamationmark.circle.fill"
        )
        XCTAssertEqual(
            presentation.profileSymbolName,
            "person.crop.circle.badge.questionmark"
        )
        XCTAssertEqual(
            presentation.accessibilityLabel(
                for: ChatRowSnapshot(aggregate: aggregate)
            ),
            "Open Chat, Weekly reflection. Coach response needs attention. " +
                "Profile changes awaiting approval."
        )
    }

    func testChatRowIndicatorPresentationDistinguishesEveryVisibleState() {
        let cases: [
            (
                ChatRowIndicators,
                activityLabel: String?,
                activitySymbol: String?,
                profileLabel: String?,
                profileSymbol: String?
            )
        ] = [
            (
                ChatRowIndicators(activity: .idle, profileUpdate: .none),
                nil,
                nil,
                nil,
                nil
            ),
            (
                ChatRowIndicators(activity: .processing, profileUpdate: .none),
                "Coach response in progress",
                nil,
                nil,
                nil
            ),
            (
                ChatRowIndicators(activity: .newMessage, profileUpdate: .none),
                "New Coach message",
                "circle.fill",
                nil,
                nil
            ),
            (
                ChatRowIndicators(
                    activity: .idle,
                    profileUpdate: .publicationFailure
                ),
                nil,
                nil,
                "Profile update could not be saved",
                "exclamationmark.triangle.fill"
            ),
        ]

        for value in cases {
            let presentation = ChatRowIndicatorPresentation(
                indicators: value.0
            )
            XCTAssertEqual(
                presentation.activityAccessibilityLabel,
                value.activityLabel
            )
            XCTAssertEqual(
                presentation.activitySymbolName,
                value.activitySymbol
            )
            XCTAssertEqual(
                presentation.profileAccessibilityLabel,
                value.profileLabel
            )
            XCTAssertEqual(
                presentation.profileSymbolName,
                value.profileSymbol
            )
        }
    }

    func testFrozenChatRowAccessibilityNamesItsAvailability() throws {
        let chatID = try ChatID("cht-20260909T190000000Z-1ABC")
        let row = ChatRowSnapshot(
            frozen: FrozenChatSnapshot(
                chatID: chatID,
                reason: .newerSchema
            )
        )
        let presentation = ChatRowIndicatorPresentation(
            indicators: ChatFeatureState().indicators(
                for: row,
                isUnread: true
            )
        )

        XCTAssertFalse(presentation.hasVisibleIndicator)
        XCTAssertEqual(
            presentation.accessibilityLabel(for: row),
            "Open unavailable Chat. Chat is read-only."
        )
    }

    func testOnlyCoachExecutionActivitiesUseTheChatRowSpinner() throws {
        let chatID = try ChatID("cht-20260909T190000000Z-1ABC")
        let rowSpinnerActivities: [ChatFeatureState.Activity] = [
            .invokingCoach(chatID),
            .stoppingCoach(chatID),
            .retryingPendingUserTurn(chatID),
            .reconsideringProfileEffect(chatID),
            .stoppingProfileReconsideration(chatID),
        ]
        for activity in rowSpinnerActivities {
            XCTAssertTrue(
                ChatActivityPresentation.usesChatRowSpinner(for: activity)
            )
        }
        XCTAssertFalse(
            ChatActivityPresentation.usesChatRowSpinner(
                for: .publishingProfileEvidence(chatID)
            )
        )
        XCTAssertFalse(
            ChatActivityPresentation.usesChatRowSpinner(
                for: .acceptingProfileProposal(chatID)
            )
        )
        XCTAssertGreaterThan(
            SlowChatRowSpinner.rotationDuration,
            1,
            "the row spinner must keep the RFC's deliberately slow cadence"
        )
        XCTAssertTrue(
            ChatActivityPresentation.usesVisibleChatRowSpinner(
                for: .invokingCoach(chatID),
                visibleChatIDs: [chatID]
            )
        )
        XCTAssertFalse(
            ChatActivityPresentation.usesVisibleChatRowSpinner(
                for: .invokingCoach(chatID),
                visibleChatIDs: []
            ),
            "a filtered active row must move the sole spinner to activity copy"
        )
    }

    func testUnreadResponseTrackerBaselinesMarksFiltersAndAcknowledgesOnOpen()
        throws
    {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let base = try aggregate(
            in: scope,
            chatID: "cht-20260830T120000000Z-2ABC",
            draftID: "drf-20260830T120000000Z-3DEF",
            memoryID: "mem-20260830T120000000Z-4GHJ",
            title: "Unread lifecycle",
            attachments: profileProposalAttachments()
        )
        let completed = try aggregate(
            byStaging: profileEvidencePublication(for: base.chat.id),
            on: base
        )
        let row = ChatRowSnapshot(aggregate: completed)
        let catalog = ChatCatalogSnapshot(
            allRows: [row],
            visibleRows: [row]
        )
        var tracker = ChatUnreadResponseTracker()

        tracker.observe(readyState(for: base))
        XCTAssertTrue(tracker.unreadChatIDs.isEmpty)

        tracker.observe(readyState(for: completed))
        XCTAssertEqual(tracker.unreadChatIDs, [base.chat.id])
        tracker.observe(readyState(for: completed))
        XCTAssertEqual(
            tracker.unreadChatIDs,
            [base.chat.id],
            "replaying an identical snapshot must be idempotent"
        )

        tracker.observe(
            ChatFeatureState(
                catalog: .ready(
                    ChatCatalogSnapshot(allRows: [row], visibleRows: [])
                ),
                filterQuery: try ChatFilterQuery("no match"),
                selection: .opening(base.chat.id)
            )
        )
        XCTAssertEqual(
            tracker.unreadChatIDs,
            [base.chat.id],
            "filtering and an uncompleted Open must retain unread state"
        )

        tracker.observe(
            ChatFeatureState(
                catalog: .ready(catalog),
                selection: .open(completed)
            )
        )
        XCTAssertTrue(tracker.unreadChatIDs.isEmpty)
    }

    func testUnreadResponseTrackerBaselinesNewRowsAndPrunesFrozenRows()
        throws
    {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let first = try aggregate(
            in: scope,
            chatID: "cht-20260830T120000000Z-2ABC",
            draftID: "drf-20260830T120000000Z-3DEF",
            memoryID: "mem-20260830T120000000Z-4GHJ",
            title: "First"
        )
        let secondBase = try aggregate(
            in: scope,
            chatID: "cht-20260830T121000000Z-5KMN",
            draftID: "drf-20260830T121000000Z-6PQR",
            memoryID: "mem-20260830T121000000Z-7QRS",
            title: "Second",
            attachments: profileProposalAttachments()
        )
        let secondCompleted = try aggregate(
            byStaging: profileEvidencePublication(for: secondBase.chat.id),
            on: secondBase
        )
        let firstRow = ChatRowSnapshot(aggregate: first)
        let secondRow = ChatRowSnapshot(aggregate: secondCompleted)
        var tracker = ChatUnreadResponseTracker()

        tracker.observe(readyState(for: first))
        tracker.observe(
            ChatFeatureState(
                catalog: .ready(
                    ChatCatalogSnapshot(
                        allRows: [firstRow, secondRow],
                        visibleRows: [firstRow, secondRow]
                    )
                )
            )
        )
        XCTAssertTrue(
            tracker.unreadChatIDs.isEmpty,
            "a newly discovered row establishes its own baseline"
        )

        var unreadTracker = ChatUnreadResponseTracker()
        unreadTracker.observe(readyState(for: secondBase))
        unreadTracker.observe(readyState(for: secondCompleted))
        XCTAssertEqual(unreadTracker.unreadChatIDs, [secondBase.chat.id])
        let frozen = ChatRowSnapshot(
            frozen: FrozenChatSnapshot(
                chatID: secondBase.chat.id,
                reason: .corrupt
            )
        )
        unreadTracker.observe(
            ChatFeatureState(
                catalog: .ready(
                    ChatCatalogSnapshot(
                        allRows: [frozen],
                        visibleRows: [frozen]
                    )
                )
            )
        )
        XCTAssertTrue(unreadTracker.unreadChatIDs.isEmpty)
    }

    func testUnreadResponseTrackerNeverMarksInitialOrSelectedHistory() throws {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let base = try aggregate(
            in: scope,
            chatID: "cht-20260830T120000000Z-2ABC",
            draftID: "drf-20260830T120000000Z-3DEF",
            memoryID: "mem-20260830T120000000Z-4GHJ",
            title: "Selected response",
            attachments: profileProposalAttachments()
        )
        let completed = try aggregate(
            byStaging: profileEvidencePublication(for: base.chat.id),
            on: base
        )

        var relaunchTracker = ChatUnreadResponseTracker()
        relaunchTracker.observe(readyState(for: completed))
        XCTAssertTrue(relaunchTracker.unreadChatIDs.isEmpty)

        var selectedTracker = ChatUnreadResponseTracker()
        selectedTracker.observe(readyState(for: base, selection: .open(base)))
        selectedTracker.observe(
            readyState(for: completed, selection: .open(completed))
        )
        XCTAssertTrue(selectedTracker.unreadChatIDs.isEmpty)

        selectedTracker.reset()
        selectedTracker.observe(readyState(for: completed))
        XCTAssertTrue(selectedTracker.unreadChatIDs.isEmpty)
    }

    func testRenameEditorTaskIdentityChangesBetweenRevisionZeroChats() throws {
        let first = ChatRenameEditorTaskID(
            chatID: try ChatID("cht-20260830T120000000Z-2ABC"),
            manifestRevision: 0
        )
        let second = ChatRenameEditorTaskID(
            chatID: try ChatID("cht-20260830T120100000Z-5KMN"),
            manifestRevision: 0
        )

        XCTAssertNotEqual(first, second)
    }

    func testEveryChatNoticeAccessibilityLabelContainsItsHumanRecoveryText() {
        let notices: [ChatNotice] = [
            .invalidTitle,
            .createFailed,
            .createCollisionLimitReached,
            .renameFailed,
            .staleRename,
            .chatMissing,
            .chatOpenFailed,
            .chatFrozen,
            .catalogFailed,
            .readOnlyLibrary,
            .coachContextUnavailable,
            .messageMustBeShortened,
            .attachmentCatalogFailed,
            .qualifiedCoachConfigurationUnavailable,
            .profileProposalAcceptFailed,
            .profileProposalDiscardFailed,
            .profileProposalStale,
            .profileEffectAssessmentFailed,
            .profileReconsiderationUnavailable,
            .profileReconsiderationDiscardFailed,
        ]

        for notice in notices {
            let recoveryText = ChatNoticePresentation.recoveryText(for: notice)
            XCTAssertEqual(
                ChatNoticePresentation.accessibilityLabel(for: notice),
                "Chat notice: \(recoveryText)",
                notice.rawValue
            )
        }
    }

    func testNewChatPickerIssuesHaveDistinctActionableRecoveryText() {
        XCTAssertEqual(
            NewChatAttachmentPickerPresentation.recoveryText(
                for: .selectionLimitReached(maximum: 128)
            ),
            "You can attach up to 128 Sessions. Deselect a Session before adding another."
        )
        XCTAssertEqual(
            NewChatAttachmentPickerPresentation.recoveryText(
                for: .attachmentUnavailable
            ),
            "A selected Session changed or is no longer available. Change the selection and try again."
        )
        XCTAssertEqual(
            NewChatAttachmentPickerPresentation.recoveryText(
                for: .contextCannotFit
            ),
            "These Sessions cannot fit together in this coach's context. Remove a Session."
        )
        XCTAssertEqual(
            NewChatAttachmentPickerPresentation.recoveryText(
                for: .contextUnavailable(.sourceUnavailable)
            ),
            "Current Coach context could not be loaded. Reopen the Chat and try again."
        )
        XCTAssertEqual(
            NewChatAttachmentPickerPresentation.recoveryText(
                for: .contextUnavailable(.externalProcessingDisallowed)
            ),
            "Coach processing is blocked because this context includes transcript-derived material whose engine policy does not permit external processing."
        )
        XCTAssertEqual(
            NewChatAttachmentPickerPresentation.recoveryText(
                for: .contextUnavailable(.externalProcessingPolicyUnavailable)
            ),
            "Coach processing is blocked because the engine policy for supporting transcript evidence could not be verified."
        )
        XCTAssertEqual(
            NewChatAttachmentPickerPresentation.recoveryText(
                for: .qualifiedConfigurationUnavailable
            ),
            "No qualified Coach configuration is available. Check again after installing a configuration update."
        )
    }

    func testMissingQualifiedConfigurationAndTemporaryTransportHaveDistinctRecoveryCopy() {
        XCTAssertEqual(
            ChatNoticePresentation.recoveryText(
                for: .qualifiedCoachConfigurationUnavailable
            ),
            "No qualified Coach configuration is available. Install an Audora update with a qualified configuration before creating a Chat."
        )
        XCTAssertEqual(
            NewChatAttachmentPickerPresentation.providerUnavailableRecoveryText,
            "Coach transport is temporarily unavailable. You can create this Chat locally and try coaching later."
        )
    }

    func testNewChatPickerIssueIsAnnouncedOnceAcrossStateReconciliation() async throws {
        let issue = ChatAttachmentPickerIssue.attachmentUnavailable
        let state = ChatFeatureState(
            catalog: .ready(ChatCatalogSnapshot(allRows: [], visibleRows: [])),
            newChatPicker: .ready(
                ChatAttachmentPickerSnapshot(
                    allRows: [],
                    visibleRows: [],
                    selectedAttachmentIDs: [],
                    filterQuery: .empty,
                    feasibility: .unavailable(.sourceUnavailable),
                    issue: issue
                )
            )
        )
        let feature = RecordingPresentationChatFeature(initial: state)
        let announcements = ChatAnnouncementRecorder()
        let model = makeChatPresentationModel(
            feature: feature,
            announcements: announcements
        )
        await model.start(
            in: activation(
                for: LibraryScope(
                    libraryID: try LibraryID(
                        "lib-20260830T115900000Z-2ABC"
                    )
                )
            )
        )

        XCTAssertEqual(
            announcements.values,
            [NewChatAttachmentPickerPresentation.accessibilityAnnouncement(for: issue)]
        )
    }

    func testNewChatPickerIssueIsAnnouncedAgainAfterCloseAndReopen() async throws {
        let issue = ChatAttachmentPickerIssue.contextCannotFit
        let catalog = ChatCatalogSnapshot(allRows: [], visibleRows: [])
        let issueState = ChatFeatureState(
            catalog: .ready(catalog),
            newChatPicker: .ready(
                ChatAttachmentPickerSnapshot(
                    allRows: [],
                    visibleRows: [],
                    selectedAttachmentIDs: [],
                    filterQuery: .empty,
                    feasibility: .unavailable(.sourceUnavailable),
                    issue: issue
                )
            )
        )
        let closedState = ChatFeatureState(
            catalog: .ready(catalog),
            newChatPicker: .closed
        )
        let feature = PickerLifecyclePresentationChatFeature(
            states: [issueState, closedState, issueState]
        )
        let announcements = ChatAnnouncementRecorder()
        let model = makeChatPresentationModel(
            feature: feature,
            announcements: announcements
        )

        await model.start(
            in: activation(
                for: LibraryScope(
                    libraryID: try LibraryID(
                        "lib-20260830T115900000Z-2ABC"
                    )
                )
            )
        )

        let announcement = NewChatAttachmentPickerPresentation.accessibilityAnnouncement(
            for: issue
        )
        XCTAssertEqual(announcements.values, [announcement, announcement])
    }

    @MainActor
    func testUnavailableEvidenceActivationIsAnnounced() {
        let announcements = ChatAnnouncementRecorder()
        let model = makeChatPresentationModel(
            feature: RecordingPresentationChatFeature(initial: ChatFeatureState()),
            announcements: announcements
        )

        model.announceEvidenceUnavailable("The supporting Session is in Trash.")

        XCTAssertEqual(
            announcements.values,
            ["Evidence unavailable. The supporting Session is in Trash."]
        )
    }

    func testWithdrawnSuggestionNoticeUsesExactAccessibleCopyAndReannounces()
        async throws
    {
        let notice = ChatTransientNotice.suggestionNoLongerRelevant
        XCTAssertEqual(
            ChatTransientNoticePresentation.text(for: notice),
            "Suggestion is no longer relevant."
        )
        XCTAssertEqual(
            ChatTransientNoticePresentation.accessibilityLabel(for: notice),
            "Suggestion is no longer relevant."
        )
        let feature = PickerLifecyclePresentationChatFeature(
            states: [
                ChatFeatureState(transientNotice: notice),
                ChatFeatureState(),
                ChatFeatureState(transientNotice: notice),
            ]
        )
        let announcements = ChatAnnouncementRecorder()
        let model = makeChatPresentationModel(
            feature: feature,
            announcements: announcements
        )

        await model.start(
            in: activation(
                for: LibraryScope(
                    libraryID: try LibraryID(
                        "lib-20260909T165900000Z-1ABC"
                    )
                )
            )
        )

        XCTAssertEqual(
            announcements.values,
            [
                "Suggestion is no longer relevant.",
                "Suggestion is no longer relevant.",
            ]
        )
    }

    func testCoachContextPresentationExplainsAllNineNonadditiveCategories() {
        XCTAssertEqual(
            CoachContextQuotePresentation.summary(
                completeInputTokens: 642,
                inputCeilingTokens: 4_032
            ),
            "~642 / 4032 input tokens"
        )
        XCTAssertEqual(
            CoachContextCostCategory.allCases.map(
                CoachContextQuotePresentation.categoryLabel
            ),
            [
                "Profile", "Coach Memory", "Prior chat history", "Current Draft",
                "Provider framing", "Attachments", "Transcript exchange reserve",
                "Response reserve", "Safety margin",
            ]
        )
    }

    func testNewChatCreationLiveContextUsesTheFullWindowAndTotalReservedUsage() {
        let presentation = NewChatCreationContextPresentation(
            totalContextTokens: 682,
            inputCeilingTokens: 4_032,
            reservedResponseTokens: 32,
            safetyMarginTokens: 8,
            profileTokens: 128
        )

        XCTAssertEqual(presentation.usedTokens, 682)
        XCTAssertEqual(presentation.maximumTokens, 4_072)
        XCTAssertEqual(
            presentation.summary,
            "~682 / 4072 total context tokens"
        )
        XCTAssertEqual(
            presentation.profileContribution,
            "Current Profile: ~128 tokens"
        )
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Estimated total context, 682 of 4072 tokens"
        )
    }

    func testNewChatCreationProviderOutageShowsTheAvailableLowerBoundAndProfile() {
        let presentation = NewChatCreationContextPresentation(
            minimumTotalContextTokens: 420,
            inputCeilingTokens: 4_032,
            reservedResponseTokens: 32,
            safetyMarginTokens: 8,
            minimumProfileTokens: 12
        )

        XCTAssertEqual(presentation.usedTokens, 420)
        XCTAssertEqual(presentation.maximumTokens, 4_072)
        XCTAssertEqual(
            presentation.summary,
            "At least ~420 / 4072 total context tokens"
        )
        XCTAssertEqual(
            presentation.profileContribution,
            "Profile lower bound: ~12 tokens"
        )
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Minimum total context, at least 420 of 4072 tokens"
        )
    }

    func testLaterScopeWinsWhenOlderStateSubscriptionIsSuspended() async throws {
        let firstScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let secondScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T121000000Z-3DEF")
        )
        let latestState = ChatFeatureState(notice: .catalogFailed)
        let feature = SuspendedInitialPresentationChatFeature(latestState: latestState)
        let model = makeChatPresentationModel(feature: feature)

        let firstStart = Task {
            await model.start(in: activation(for: firstScope, generation: 1))
        }
        await feature.waitForSubscriptionCount(1)
        let secondStart = Task {
            await model.start(in: activation(for: secondScope, generation: 2))
        }
        await feature.waitForCommandCount(2)
        await feature.resumeFirstSubscription(with: ChatFeatureState(notice: .createFailed))
        await firstStart.value
        await secondStart.value

        XCTAssertEqual(model.snapshot, latestState)
        let commands = await feature.commands
        let contexts = startContexts(in: commands)
        XCTAssertEqual(contexts.map(\.libraryScope), [firstScope, secondScope])
        XCTAssertEqual(Set(contexts.map(\.generation)).count, 2)
    }

    func testRecreatedModelsFenceDelayedOldActionAcrossAtoBtoAVisits() async throws {
        let firstScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let secondScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T121000000Z-3DEF")
        )
        let feature = SuspendedOldActionPresentationChatFeature()
        let firstVisit = makeChatPresentationModel(feature: feature)
        await firstVisit.start(in: activation(for: firstScope, generation: 1))
        firstVisit.updateFilter("stale first visit")
        await feature.waitForFilterSuspension()

        let secondVisit = makeChatPresentationModel(feature: feature)
        await secondVisit.start(in: activation(for: secondScope, generation: 2))
        let returnedVisit = makeChatPresentationModel(feature: feature)
        await returnedVisit.start(in: activation(for: firstScope, generation: 3))

        await feature.resumeFilter()
        await feature.waitForFilterCompletion()

        let commands = await feature.commands
        let contexts = startContexts(in: commands)
        XCTAssertEqual(
            contexts.map(\.libraryScope),
            [firstScope, secondScope, firstScope]
        )
        XCTAssertEqual(Set(contexts.map(\.generation)).count, 3)
        XCTAssertNotEqual(contexts.first, contexts.last)
        let returnedState = await feature.currentState(
            in: try XCTUnwrap(contexts.last)
        )
        let state = try XCTUnwrap(returnedState)
        XCTAssertEqual(state.filterQuery, .empty)
    }

    func testLibrarySwitchImmediatelyHidesPriorTitlesWhileNextCatalogLoadSuspends() async throws {
        let firstScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T115900000Z-2ABC")
        )
        let secondScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T121000000Z-3DEF")
        )
        let firstAggregate = try aggregate(
            in: firstScope,
            chatID: "cht-20260830T120000000Z-2ABC",
            draftID: "drf-20260830T120000000Z-3DEF",
            memoryID: "mem-20260830T120000000Z-4GHJ",
            title: "First Library Chat"
        )
        let secondAggregate = try aggregate(
            in: secondScope,
            chatID: "cht-20260830T121000000Z-5KMN",
            draftID: "drf-20260830T121000000Z-6PQR",
            memoryID: "mem-20260830T121000000Z-7STV",
            title: "Second Library Chat"
        )
        let firstState = readyState(
            for: firstAggregate,
            filterQuery: try ChatFilterQuery("First"),
            selection: .open(firstAggregate)
        )
        let secondState = readyState(for: secondAggregate)
        let feature = SuspendedLibrarySwitchPresentationChatFeature(
            firstScope: firstScope,
            secondScope: secondScope,
            firstState: firstState,
            secondState: secondState
        )
        let model = makeChatPresentationModel(feature: feature)

        await model.start(in: activation(for: firstScope, generation: 1))
        model.filterText = "First"
        let switchTask = Task {
            await model.start(in: activation(for: secondScope, generation: 2))
        }
        await feature.waitForSecondLoadSuspension()

        XCTAssertEqual(
            model.snapshot,
            ChatFeatureState(catalog: .loading, filterQuery: .empty, selection: .none)
        )
        XCTAssertEqual(model.filterText, "")
        if case let .ready(catalog) = model.snapshot.catalog {
            XCTFail("Leaked prior-Library titles: \(catalog.visibleRows.compactMap(\.title))")
        }

        await feature.resumeSecondLoad()
        await switchTask.value

        XCTAssertEqual(model.snapshot, secondState)
        let commands = await feature.commands
        let contexts = startContexts(in: commands)
        XCTAssertEqual(contexts.map(\.libraryScope), [firstScope, secondScope])
        XCTAssertEqual(Set(contexts.map(\.generation)).count, 2)
    }

    func testLateSubscriptionReconcilesReadyStateAfterMissingLoading() async throws {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T121000000Z-3DEF")
        )
        let aggregate = try aggregate(
            in: scope,
            chatID: "cht-20260830T121000000Z-5KMN",
            draftID: "drf-20260830T121000000Z-6PQR",
            memoryID: "mem-20260830T121000000Z-7STV",
            title: "Late Library Chat"
        )
        let ready = readyState(for: aggregate)
        let feature = LateSubscriptionPresentationChatFeature(finalState: ready)
        let model = makeChatPresentationModel(feature: feature)

        let start = Task {
            await model.start(in: activation(for: scope))
        }
        await feature.waitForStart()
        await feature.completeLateSubscription()
        await start.value

        XCTAssertEqual(model.snapshot, ready)
        let commands = await feature.commands
        let context = try XCTUnwrap(startContexts(in: commands).first)
        XCTAssertEqual(commands, [.start(context)])
        XCTAssertEqual(context.libraryScope, scope)
    }

    func testLateSubscriptionReconcilesFailedStateAfterMissingLoading() async throws {
        let scope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T121100000Z-4GHJ")
        )
        let failed = ChatFeatureState(catalog: .failed, notice: .catalogFailed)
        let feature = LateSubscriptionPresentationChatFeature(finalState: failed)
        let model = makeChatPresentationModel(feature: feature)

        let start = Task {
            await model.start(in: activation(for: scope))
        }
        await feature.waitForStart()
        await feature.completeLateSubscription()
        await start.value

        XCTAssertEqual(model.snapshot, failed)
        let commands = await feature.commands
        let context = try XCTUnwrap(startContexts(in: commands).first)
        XCTAssertEqual(commands, [.start(context)])
        XCTAssertEqual(context.libraryScope, scope)
    }

    private func waitForCommandCount(
        _ count: Int,
        in feature: RecordingPresentationChatFeature
    ) async {
        while await feature.commands.count < count { await Task.yield() }
    }

    private func activation(
        for scope: LibraryScope,
        generation: UInt64 = 1
    ) -> LibraryActivation {
        LibraryActivation(scope: scope, generation: generation)
    }

    private func startContexts(in commands: [ChatCommand]) -> [ChatCommandContext] {
        commands.compactMap { command in
            guard case let .start(context) = command else { return nil }
            return context
        }
    }

    private func profileProposal(
        for chatID: ChatID
    ) throws -> ProfileChangeProposal {
        let replaceTarget = try ProfileProposalTarget(
            statementID: ProfileStatementID(
                "stm-20260909T110000000Z-1ABC"
            ),
            statementKind: .speakingObservation,
            wording: "I rush transitions between ideas."
        )
        let retireTarget = try ProfileProposalTarget(
            statementID: ProfileStatementID(
                "stm-20260909T110000000Z-2DEF"
            ),
            statementKind: .coachingPreference,
            wording: "Give me a long written debrief."
        )
        let appendTarget = try ProfileProposalTarget(
            statementID: ProfileStatementID(
                "stm-20260909T110000000Z-3GHJ"
            ),
            statementKind: .selfAssessment,
            wording: "I speak clearly when I slow down."
        )
        return try ProfileChangeProposal(
            id: ProfileChangeProposalID("prp-20260909T120000000Z-4KMN"),
            chatID: chatID,
            responsePositionID: ChatResponsePositionID(
                "rsp-20260909T120000000Z-5PQR"
            ),
            baseProfile: CoachProfileProvenance(
                revisionID: ProfileRevisionID(
                    "prf-20260909T105900000Z-6RST"
                ),
                statementGeneration: 7
            ),
            changes: [
                .add(
                    statement: try ProfileProposedStatement(
                        statementID: ProfileStatementID(
                            "stm-20260909T120000000Z-7VWX"
                        ),
                        statementKind: .goal,
                        wording: "Pause after each main idea.",
                        evidence: [try evidenceReference(index: 1)]
                    )
                ),
                .replace(
                    target: replaceTarget,
                    replacement: try ProfileProposedStatement(
                        statementID: ProfileStatementID(
                            "stm-20260909T120000000Z-8XYZ"
                        ),
                        statementKind: .speakingObservation,
                        wording: "I can make transitions easier to follow.",
                        evidence: [try evidenceReference(index: 2)]
                    )
                ),
                .retire(
                    target: retireTarget,
                    evidence: [try evidenceReference(index: 3)]
                ),
            ],
            evidenceAppends: [
                try ProfileEvidenceAppend(
                    target: appendTarget,
                    evidence: [try evidenceReference(index: 4)]
                ),
            ],
            createdAt: UTCInstant("2026-09-09T12:00:00.000Z")
        )
    }

    private func staleBasis(
        for proposal: ProfileChangeProposal
    ) throws -> ProfileReconsiderationBasis {
        let sourceStatements = try [
            ProfileStatement(
                statementID: try ProfileStatementID(
                    "stm-20260909T110000000Z-1ABC"
                ),
                statementKind: .speakingObservation,
                wording: "I rush transitions between ideas.",
                supportingSessionCount: 0,
                evidence: []
            ),
            ProfileStatement(
                statementID: try ProfileStatementID(
                    "stm-20260909T110000000Z-2DEF"
                ),
                statementKind: .coachingPreference,
                wording: "Give me a long written debrief.",
                supportingSessionCount: 0,
                evidence: []
            ),
            ProfileStatement(
                statementID: try ProfileStatementID(
                    "stm-20260909T110000000Z-3GHJ"
                ),
                statementKind: .selfAssessment,
                wording: "I speak clearly when I slow down.",
                supportingSessionCount: 0,
                evidence: []
            ),
        ]
        let base = try ProfileRevision(
            revisionID: try XCTUnwrap(proposal.baseProfile.revisionID),
            parentRevisionID: nil,
            generation: 7,
            statementGeneration: proposal.baseProfile.statementGeneration,
            createdAt: UTCInstant("2026-09-09T11:00:00.000Z"),
            statements: sourceStatements
        )
        let latest = try ProfileRevision(
            revisionID: try ProfileRevisionID(
                "prf-20260909T123000000Z-9ABC"
            ),
            parentRevisionID: base.revisionID,
            generation: 8,
            statementGeneration: 8,
            createdAt: UTCInstant("2026-09-09T12:30:00.000Z"),
            statements: sourceStatements
        )
        return try ProfileReconsiderationBasis(
            sourceEffect: .proposal(proposal),
            baseProfile: ProfileSnapshot(revision: base),
            latestProfile: ProfileSnapshot(revision: latest)
        )
    }

    private func profileEvidencePublication(
        for chatID: ChatID
    ) throws -> ProfileEvidencePublication {
        try ProfileEvidencePublication(
            chatID: chatID,
            responsePositionID: ChatResponsePositionID(
                "rsp-20260909T150000000Z-5PQR"
            ),
            evidenceAppends: [
                try ProfileEvidenceAppend(
                    target: ProfileProposalTarget(
                        statementID: ProfileStatementID(
                            "stm-20260909T145900000Z-6RST"
                        ),
                        statementKind: .speakingObservation,
                        wording: "Pause briefly between points."
                    ),
                    evidence: [try evidenceReference(index: 1)]
                ),
                try ProfileEvidenceAppend(
                    target: ProfileProposalTarget(
                        statementID: ProfileStatementID(
                            "stm-20260909T145900000Z-7VWX"
                        ),
                        statementKind: .growthDirection,
                        wording: "Keep conclusions concise."
                    ),
                    evidence: [try evidenceReference(index: 2)]
                ),
            ],
            createdAt: UTCInstant("2026-09-09T15:00:00.000Z")
        )
    }

    private func aggregate(
        byStaging publication: ProfileEvidencePublication,
        on base: ChatAggregate
    ) throws -> ChatAggregate {
        let userMessage = try ChatMessage(
            id: ChatMessageID("msg-20260909T150000000Z-8XYZ"),
            responsePositionID: publication.responsePositionID,
            content: .user(text: "Please reflect on this Session."),
            createdAt: publication.createdAt
        )
        let coachMessage = try ChatMessage(
            id: ChatMessageID("msg-20260909T150000000Z-9ABC"),
            responsePositionID: publication.responsePositionID,
            content: .coach(markdown: "Pause between ideas and stay concise."),
            coachProfile: CoachProfileProvenance(
                revisionID: ProfileRevisionID(
                    "prf-20260909T145900000Z-1DEF"
                ),
                statementGeneration: 7
            ),
            createdAt: publication.createdAt
        )
        let publishedChat = try Chat(
            id: base.chat.id,
            manifestRevision: base.chat.manifestRevision + 1,
            title: base.chat.title,
            createdAt: base.chat.createdAt,
            updatedAt: publication.createdAt,
            creation: base.chat.creation,
            profileStatementGenerationAtCreation:
                base.chat.profileStatementGenerationAtCreation,
            attachments: base.chat.attachments,
            draft: base.chat.draft,
            messageIDs: [userMessage.id, coachMessage.id],
            currentMemoryID: base.chat.currentMemoryID
        )
        return try ChatAggregate(
            chat: publishedChat,
            memory: base.memory,
            messages: [userMessage, coachMessage],
            profileEvidencePublication: publication
        )
    }

    private func evidenceReference(index: Int) throws -> EvidenceReference {
        try EvidenceReference(
            sessionID: SessionID(
                "ses-20260909T100000000Z-\(index)ABC"
            ),
            transcriptRevisionID: TranscriptRevisionID(
                "trv-20260909T100000000Z-\(index)DEF"
            ),
            target: .wordRange(
                startWordID: TranscriptWordID(
                    String(format: "w%06d", index * 2 - 1)
                ),
                endWordID: TranscriptWordID(
                    String(format: "w%06d", index * 2)
                )
            ),
            display: EvidenceReferenceDisplay(
                sessionLabel: "Session \(index)",
                trustedText: "Trusted evidence \(index)",
                startMilliseconds: UInt64(index * 1_000),
                endMilliseconds: UInt64(index * 1_000 + 500)
            )
        )
    }

    private func profileProposalAttachments() throws -> ChatAttachments {
        try ChatAttachments(
            validating: (1 ... 4).map { index in
                ChatSessionAttachment(
                    attachmentID: try ChatSessionAttachmentID(
                        "proposal-evidence-\(index)"
                    ),
                    sessionID: try SessionID(
                        "ses-20260909T100000000Z-\(index)ABC"
                    ),
                    transcriptRevisionID: try TranscriptRevisionID(
                        "trv-20260909T100000000Z-\(index)DEF"
                    )
                )
            }
        )
    }

    private func aggregate(
        in scope: LibraryScope,
        chatID: String,
        draftID: String,
        memoryID: String,
        title: String,
        attachments: ChatAttachments = .empty
    ) throws -> ChatAggregate {
        let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
        let seed = try NewChatSeed(
            library: scope,
            chatID: ChatID(chatID),
            draftID: ChatDraftID(draftID),
            memoryID: CoachMemoryID(memoryID),
            instant: instant,
            profileStatementGeneration: 7,
            attachments: attachments
        )
        return try RenameChatMutation(
            library: scope,
            base: seed.aggregate,
            title: ChatTitle(title),
            updatedAt: instant
        ).replacement
    }

    private func readyState(
        for aggregate: ChatAggregate,
        filterQuery: ChatFilterQuery = .empty,
        selection: ChatFeatureState.Selection = .none
    ) -> ChatFeatureState {
        let row = ChatRowSnapshot(aggregate: aggregate)
        return ChatFeatureState(
            catalog: .ready(ChatCatalogSnapshot(allRows: [row], visibleRows: [row])),
            filterQuery: filterQuery,
            selection: selection
        )
    }
}

@MainActor
private func makeChatPresentationModel(
    feature: any ChatFeature,
    announcements: (any AccessibilityAnnouncementPosting)? = nil
) -> ChatPresentationModel {
    let application = DefaultApplicationCommandFeature(
        library: PassivePresentationLibraryFeature(),
        chat: feature
    )
    return ChatPresentationModel(
        dispatcher: ChatCommandDispatcher(feature: application),
        announcements: announcements
    )
}

@MainActor
private final class ChatAnnouncementRecorder: AccessibilityAnnouncementPosting {
    private(set) var values: [String] = []

    func post(_ announcement: String) {
        values.append(announcement)
    }
}

private actor PassivePresentationLibraryFeature: LibraryFeature {
    nonisolated let states = AsyncStream<LibraryFeatureState> { continuation in
        continuation.finish()
    }

    var currentState: LibraryFeatureState {
        LibraryFeatureState(selection: .awaitingBootstrap)
    }

    func send(_ command: LibraryCommand) async -> LibraryCommandResult {
        .noSelectionMutation
    }
}

private actor SuspendedOldActionPresentationChatFeature: ChatFeature {
    nonisolated var states: AsyncStream<ChatFeatureState> {
        AsyncStream { continuation in continuation.finish() }
    }

    private var state = ChatFeatureState(
        catalog: .ready(ChatCatalogSnapshot(allRows: [], visibleRows: []))
    )
    private var activeContext: ChatCommandContext?
    private var filterContinuation: CheckedContinuation<Void, Never>?
    private var filterIsSuspended = false
    private var filterIsComplete = false
    private(set) var commands: [ChatCommand] = []

    var currentState: ChatFeatureState { state }

    func currentState(in context: ChatCommandContext) -> ChatFeatureState? {
        activeContext == context ? state : nil
    }

    func flushForOrderlyTermination() async -> Bool { true }

    func send(_ command: ChatCommand) async {
        commands.append(command)
        switch command {
        case let .start(context):
            activeContext = context
            state = ChatFeatureState(
                catalog: .ready(ChatCatalogSnapshot(allRows: [], visibleRows: []))
            )
        case let .setFilter(context, query):
            filterIsSuspended = true
            await withCheckedContinuation { filterContinuation = $0 }
            if context == activeContext {
                state = ChatFeatureState(
                    catalog: state.catalog,
                    filterQuery: query,
                    selection: state.selection
                )
            }
            filterIsComplete = true
        case .beginNewChat, .setNewChatAttachmentFilter, .toggleNewChatAttachment,
             .cancelNewChat, .confirmNewChat,
             .rename, .open, .editDraft,
             .refreshContextQuote, .sendDraft,
             .stopCoachResponse, .stopProfileReconsideration,
             .retryPendingUserTurn, .createNewChatFromCapacityFailure,
             .discardPendingUserTurn, .acceptProfileProposal,
             .discardProfileProposal, .retryProfileEvidencePublication,
             .discardProfileEvidencePublication, .reconsiderProfileEffect,
             .retryProfileReconsideration,
             .discardProfileReconsiderationFailure:
            break
        }
    }

    func waitForFilterSuspension() async {
        while !filterIsSuspended { await Task.yield() }
    }

    func resumeFilter() {
        filterContinuation?.resume()
        filterContinuation = nil
    }

    func waitForFilterCompletion() async {
        while !filterIsComplete { await Task.yield() }
    }
}

private actor SuspendedSameLibraryReplacementChatFeature: ChatFeature {
    nonisolated var states: AsyncStream<ChatFeatureState> {
        streams.makeStream()
    }

    private nonisolated let streams: SameLibraryReplacementStateStreams
    private let prior: ChatFeatureState
    private let replacement: ChatFeatureState
    private var state: ChatFeatureState
    private var activeContext: ChatCommandContext?
    private var startCount = 0
    private var replacementStartIsSuspended = false
    private var replacementStartContinuation: CheckedContinuation<Void, Never>?

    init(prior: ChatFeatureState, replacement: ChatFeatureState) {
        self.prior = prior
        self.replacement = replacement
        state = prior
        streams = SameLibraryReplacementStateStreams(initial: prior)
    }

    var currentState: ChatFeatureState { state }

    func currentState(in context: ChatCommandContext) -> ChatFeatureState? {
        activeContext == context ? state : nil
    }

    func send(_ command: ChatCommand) async {
        guard case let .start(context) = command else { return }
        startCount += 1
        if startCount == 2 {
            replacementStartIsSuspended = true
            await withCheckedContinuation {
                replacementStartContinuation = $0
            }
        }
        activeContext = context
        state = startCount == 1 ? prior : replacement
        streams.publish(state)
    }

    func flushForOrderlyTermination() async -> Bool { true }

    func waitUntilReplacementStartSuspends() async {
        while !replacementStartIsSuspended { await Task.yield() }
    }

    func resumeReplacementStart() {
        replacementStartContinuation?.resume()
        replacementStartContinuation = nil
    }
}

private final class SameLibraryReplacementStateStreams: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ChatFeatureState
    private var continuation: AsyncStream<ChatFeatureState>.Continuation?

    init(initial: ChatFeatureState) {
        current = initial
    }

    func makeStream() -> AsyncStream<ChatFeatureState> {
        AsyncStream { continuation in
            let initial = lock.withLock { () -> ChatFeatureState in
                self.continuation = continuation
                return current
            }
            continuation.yield(initial)
        }
    }

    func publish(_ state: ChatFeatureState) {
        let continuation = lock.withLock {
            current = state
            let currentContinuation = self.continuation
            self.continuation = nil
            return currentContinuation
        }
        continuation?.yield(state)
        continuation?.finish()
    }
}

private actor RecordingPresentationChatFeature: ChatFeature {
    nonisolated var states: AsyncStream<ChatFeatureState> { streams.makeStream() }

    private nonisolated let streams: RecordingPresentationStateStreams
    private let state: ChatFeatureState
    private var activeContext: ChatCommandContext?
    private(set) var commands: [ChatCommand] = []

    init(initial: ChatFeatureState = ChatFeatureState()) {
        state = initial
        streams = RecordingPresentationStateStreams(state: initial)
    }

    var currentState: ChatFeatureState { state }

    func currentState(in context: ChatCommandContext) -> ChatFeatureState? {
        activeContext == context ? state : nil
    }

    func flushForOrderlyTermination() async -> Bool { true }

    func send(_ command: ChatCommand) {
        commands.append(command)
        if case let .start(context) = command {
            activeContext = context
            streams.publishStart()
        }
    }
}

private actor PickerLifecyclePresentationChatFeature: ChatFeature {
    nonisolated var states: AsyncStream<ChatFeatureState> { streams.makeStream() }

    private nonisolated let streams: PickerLifecyclePresentationStateStreams
    private let snapshots: [ChatFeatureState]
    private let finalState: ChatFeatureState
    private var activeContext: ChatCommandContext?

    init(states snapshots: [ChatFeatureState]) {
        self.snapshots = snapshots
        finalState = snapshots.last ?? ChatFeatureState()
        streams = PickerLifecyclePresentationStateStreams()
    }

    var currentState: ChatFeatureState { finalState }

    func currentState(in context: ChatCommandContext) -> ChatFeatureState? {
        activeContext == context ? finalState : nil
    }

    func flushForOrderlyTermination() async -> Bool { true }

    func send(_ command: ChatCommand) {
        if case let .start(context) = command {
            activeContext = context
            streams.publish(snapshots)
        }
    }
}

private final class PickerLifecyclePresentationStateStreams: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<ChatFeatureState>.Continuation?

    func makeStream() -> AsyncStream<ChatFeatureState> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func publish(_ states: [ChatFeatureState]) {
        let continuation = lock.withLock {
            () -> AsyncStream<ChatFeatureState>.Continuation? in
            defer { self.continuation = nil }
            return self.continuation
        }
        for state in states {
            continuation?.yield(state)
        }
        continuation?.finish()
    }
}

private final class RecordingPresentationStateStreams: @unchecked Sendable {
    private let lock = NSLock()
    private let state: ChatFeatureState
    private var continuation: AsyncStream<ChatFeatureState>.Continuation?

    init(state: ChatFeatureState) {
        self.state = state
    }

    func makeStream() -> AsyncStream<ChatFeatureState> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
            continuation.yield(state)
        }
    }

    func publishStart() {
        let continuation = lock.withLock { () -> AsyncStream<ChatFeatureState>.Continuation? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.yield(ChatFeatureState(catalog: .loading))
        continuation?.yield(state)
        continuation?.finish()
    }
}

private actor SuspendedInitialPresentationChatFeature: ChatFeature {
    nonisolated var states: AsyncStream<ChatFeatureState> { streams.makeStream() }

    private nonisolated let streams: SequencedPresentationStateStreams
    private let latestState: ChatFeatureState
    private var activeContext: ChatCommandContext?
    private(set) var commands: [ChatCommand] = []

    init(latestState: ChatFeatureState) {
        self.latestState = latestState
        streams = SequencedPresentationStateStreams(latestState: latestState)
    }

    var currentState: ChatFeatureState { latestState }

    func currentState(in context: ChatCommandContext) -> ChatFeatureState? {
        activeContext == context ? latestState : nil
    }

    func flushForOrderlyTermination() async -> Bool { true }

    func send(_ command: ChatCommand) {
        commands.append(command)
        if case let .start(context) = command {
            activeContext = context
        }
    }

    func waitForSubscriptionCount(_ count: Int) async {
        while streams.subscriptionCount < count { await Task.yield() }
    }

    func waitForCommandCount(_ count: Int) async {
        while commands.count < count { await Task.yield() }
    }

    func resumeFirstSubscription(with state: ChatFeatureState) {
        streams.finishFirst(with: state)
    }
}

private final class SequencedPresentationStateStreams: @unchecked Sendable {
    private let lock = NSLock()
    private let latestState: ChatFeatureState
    private var nextSubscription = 0
    private var firstContinuation: AsyncStream<ChatFeatureState>.Continuation?

    init(latestState: ChatFeatureState) {
        self.latestState = latestState
    }

    var subscriptionCount: Int {
        lock.withLock { nextSubscription }
    }

    func makeStream() -> AsyncStream<ChatFeatureState> {
        let subscription = lock.withLock { () -> Int in
            defer { nextSubscription += 1 }
            return nextSubscription
        }
        return AsyncStream { continuation in
            if subscription == 0 {
                lock.withLock { firstContinuation = continuation }
            } else {
                continuation.yield(ChatFeatureState(catalog: .loading))
                continuation.yield(latestState)
                continuation.finish()
            }
        }
    }

    func finishFirst(with state: ChatFeatureState) {
        let continuation = lock.withLock { () -> AsyncStream<ChatFeatureState>.Continuation? in
            defer { firstContinuation = nil }
            return firstContinuation
        }
        continuation?.yield(state)
        continuation?.finish()
    }
}

private actor SuspendedLibrarySwitchPresentationChatFeature: ChatFeature {
    nonisolated var states: AsyncStream<ChatFeatureState> { streams.makeStream() }

    private nonisolated let streams: LibrarySwitchPresentationStateStreams
    private let firstScope: LibraryScope
    private let secondScope: LibraryScope
    private let secondState: ChatFeatureState
    private var state: ChatFeatureState
    private var activeContext: ChatCommandContext?
    private var secondLoadContinuation: CheckedContinuation<Void, Never>?
    private var secondLoadIsSuspended = false
    private(set) var commands: [ChatCommand] = []

    init(
        firstScope: LibraryScope,
        secondScope: LibraryScope,
        firstState: ChatFeatureState,
        secondState: ChatFeatureState
    ) {
        self.firstScope = firstScope
        self.secondScope = secondScope
        self.secondState = secondState
        state = firstState
        streams = LibrarySwitchPresentationStateStreams(firstState: firstState)
    }

    var currentState: ChatFeatureState { state }

    func currentState(in context: ChatCommandContext) -> ChatFeatureState? {
        activeContext == context ? state : nil
    }

    func flushForOrderlyTermination() async -> Bool { true }

    func send(_ command: ChatCommand) async {
        commands.append(command)
        guard case let .start(context) = command else { return }
        let scope = context.libraryScope
        activeContext = context
        if scope == firstScope { return }
        guard scope == secondScope else { return }

        state = ChatFeatureState(catalog: .loading, filterQuery: .empty, selection: .none)
        streams.yield(state)
        secondLoadIsSuspended = true
        await withCheckedContinuation { continuation in
            secondLoadContinuation = continuation
        }
        state = secondState
        streams.yield(state)
        streams.finish()
    }

    func waitForSecondLoadSuspension() async {
        while !secondLoadIsSuspended { await Task.yield() }
    }

    func resumeSecondLoad() {
        secondLoadContinuation?.resume()
        secondLoadContinuation = nil
    }
}

private final class LibrarySwitchPresentationStateStreams: @unchecked Sendable {
    private let lock = NSLock()
    private let firstState: ChatFeatureState
    private var nextSubscription = 0
    private var activeContinuation: AsyncStream<ChatFeatureState>.Continuation?

    init(firstState: ChatFeatureState) {
        self.firstState = firstState
    }

    func makeStream() -> AsyncStream<ChatFeatureState> {
        let subscription = lock.withLock { () -> Int in
            defer { nextSubscription += 1 }
            return nextSubscription
        }
        return AsyncStream { continuation in
            continuation.yield(firstState)
            if subscription == 0 {
                continuation.finish()
            } else {
                lock.withLock { activeContinuation = continuation }
            }
        }
    }

    func yield(_ state: ChatFeatureState) {
        lock.withLock { activeContinuation }?.yield(state)
    }

    func finish() {
        let continuation = lock.withLock { () -> AsyncStream<ChatFeatureState>.Continuation? in
            defer { activeContinuation = nil }
            return activeContinuation
        }
        continuation?.finish()
    }
}

private actor LateSubscriptionPresentationChatFeature: ChatFeature {
    nonisolated var states: AsyncStream<ChatFeatureState> { stream.makeStream() }

    private nonisolated let stream = LatePresentationStateStream()
    private let finalState: ChatFeatureState
    private var activeContext: ChatCommandContext?
    private var pendingContext: ChatCommandContext?
    private(set) var commands: [ChatCommand] = []

    init(finalState: ChatFeatureState) {
        self.finalState = finalState
    }

    var currentState: ChatFeatureState { finalState }

    func currentState(in context: ChatCommandContext) -> ChatFeatureState? {
        activeContext == context ? finalState : nil
    }

    func flushForOrderlyTermination() async -> Bool { true }

    func send(_ command: ChatCommand) {
        commands.append(command)
        guard case let .start(context) = command else { return }
        pendingContext = context
    }

    func waitForStart() async {
        while commands.isEmpty { await Task.yield() }
    }

    func completeLateSubscription() {
        activeContext = pendingContext
        pendingContext = nil
        stream.finish(with: finalState)
    }
}

private final class LatePresentationStateStream: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<ChatFeatureState>.Continuation?

    func makeStream() -> AsyncStream<ChatFeatureState> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func finish(with state: ChatFeatureState) {
        let continuation = lock.withLock { () -> AsyncStream<ChatFeatureState>.Continuation? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.yield(state)
        continuation?.finish()
    }
}
