@testable @_spi(CoachContextQualification) @_spi(InvocationInfrastructure) @_spi(ChatCreationAuthorityTesting) import AudoraApplication
import AudoraContracts
import AudoraDomain
import Foundation
import XCTest

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class ChatFeatureScenarioTests: XCTestCase {
    func testEveryChatFeatureScenarioMatchesTheSwiftFeature() async throws {
        let resources: [ContractResource] = [
            .createDevelopmentChatScenario,
            .draftSendDiscardChatScenario,
            .contextCapacityRecoveryChatScenario,
            .fakeProviderSuccessDevelopmentChatScenario,
            .renameChatScenario,
            .filterChatsScenario,
            .relaunchChatScenario,
            .staleRenameChatScenario,
            .wrongLibraryChatScenario,
            .corruptChatScenario,
            .newerChatScenario,
            .collisionChatScenario,
            .providerUnavailableNewChatScenario,
            .invalidContextNewChatScenario,
            .attachmentDisappearsDuringCreateChatScenario,
            .cancelDuringNewChatQuoteScenario,
            .cancelDuringAttachmentResolutionScenario,
            .suspendedLibrarySwitchChatScenario,
        ]

        for resource in resources {
            let dto = try JSONDecoder().decode(
                ChatFeatureScenarioDTO.self,
                from: ContractResources.data(for: resource)
            )
            XCTAssertEqual(dto.schemaVersion, 1, dto.scenarioId)

            let recorder = ChatScenarioRecorder()
            let initial = try dto.initialChats.map(aggregate)
            let store = ChatScenarioStore(
                initial: initial,
                events: dto.dependencyTrace.filter { $0.port == "chatStore" },
                recorder: recorder,
                suspendFirstCatalogLoad: dto.suspendedEffect == "firstCatalogLoad"
            )
            let scripted = ChatScenarioScript(events: dto.dependencyTrace, recorder: recorder)
            let attachmentSource = ChatScenarioAttachmentSource(
                events: dto.dependencyTrace.filter { $0.port == "attachmentSource" },
                recorder: recorder
            )
            let coachContextSource = ScenarioCoachContextSnapshotPort(
                mode: dto.contextCapacityMode ?? "alwaysFits",
                events: dto.dependencyTrace.filter { $0.port == "coachContext" },
                recorder: recorder
            )
            let baseCoachContext = DefaultCoachContextFeature(
                source: coachContextSource
            )
            let invocations: any ScenarioMeasuringInvocations =
                try ScenarioFakeInvocationGateway(
                    store: store,
                    source: coachContextSource,
                    providerIsAvailable: dto.providerAvailability == "available"
                )
            let feature = DefaultChatFeature(
                store: store,
                profileReader: scripted,
                clock: scripted,
                chatIDGenerator: scripted,
                draftIDGenerator: scripted,
                memoryIDGenerator: scripted,
                pendingUserTurnIDGenerator: scripted,
                responsePositionIDGenerator: scripted,
                admissionRefreshScheduler: ScenarioAdmissionRefreshScheduler(),
                coachContext: ScenarioBoundCoachContext(
                    attachmentSource: attachmentSource,
                    base: baseCoachContext,
                    providerUnavailable:
                        dto.dependencyTrace.contains {
                            $0.port == "coachContext" &&
                                $0.effect == "quoteNewChat" &&
                                $0.outcome.rendered == "providerUnavailable"
                        },
                    rejectsCreationLease:
                        dto.suspendedEffect ==
                            "newChatQuoteAfterAttachmentResolution"
                ),
                invocations: invocations
            )
            let scope = LibraryScope(libraryID: try LibraryID(dto.libraryId))
            var commandGeneration: UInt64 = 1
            var commandContext = ChatCommandContext(
                libraryScope: scope,
                generation: commandGeneration
            )
            var completedInvocationTarget = 0

            if dto.suspendedEffect == "firstCatalogLoad" {
                let firstContext = commandContext
                let firstStart = Task { await feature.send(.start(firstContext)) }
                await store.waitUntilFirstCatalogLoadStarts()
                guard let switchCommand = dto.commands.first else {
                    throw ScenarioFailure.script
                }
                let switchState = await feature.currentState
                let applicationSwitch = try contextualizedCommand(
                    switchCommand,
                    activeState: switchState,
                    activeContext: &commandContext,
                    generation: &commandGeneration
                )
                await feature.send(applicationSwitch)
                await store.resumeFirstCatalogLoad()
                await firstStart.value
                for command in dto.commands.dropFirst() {
                    let activeState = await feature.currentState
                    let applicationCommand = try contextualizedCommand(
                        command,
                        activeState: activeState,
                        activeContext: &commandContext,
                        generation: &commandGeneration
                    )
                    await feature.send(applicationCommand)
                    if command.startsInvocation,
                       completedInvocationTarget < dto.expectedInvocationCalls
                    {
                        completedInvocationTarget += 1
                        await invocations.waitUntilInvocationCompletes(
                            completedInvocationTarget
                        )
                        await assertUnavailableProviderFailureIsClassified(
                            dto,
                            feature: feature,
                            invocations: invocations
                        )
                    }
                }
            } else if dto.suspendedEffect == "firstAttachmentResolution" ||
                        dto.suspendedEffect ==
                            "newChatQuoteAfterAttachmentResolution"
            {
                await feature.send(.start(commandContext))
                guard let confirmationIndex = dto.commands.firstIndex(where: {
                    $0.kind == "confirmNewChat"
                }), confirmationIndex + 1 < dto.commands.count,
                      dto.commands[confirmationIndex + 1].kind == "cancelNewChat"
                else {
                    throw ScenarioFailure.script
                }
                for command in dto.commands[..<confirmationIndex] {
                    let activeState = await feature.currentState
                    let applicationCommand = try contextualizedCommand(
                        command,
                        activeState: activeState,
                        activeContext: &commandContext,
                        generation: &commandGeneration
                    )
                    await feature.send(applicationCommand)
                }
                let confirmationState = await feature.currentState
                let confirmation = try contextualizedCommand(
                    dto.commands[confirmationIndex],
                    activeState: confirmationState,
                    activeContext: &commandContext,
                    generation: &commandGeneration
                )
                async let suspendedConfirmation: Void = feature.send(confirmation)
                if dto.suspendedEffect == "firstAttachmentResolution" {
                    await attachmentSource.waitUntilCancelledResolutionStarts()
                } else {
                    await coachContextSource.waitUntilCancelledNewChatQuoteStarts()
                }
                let cancellationState = await feature.currentState
                let cancellation = try contextualizedCommand(
                    dto.commands[confirmationIndex + 1],
                    activeState: cancellationState,
                    activeContext: &commandContext,
                    generation: &commandGeneration
                )
                await feature.send(cancellation)
                await suspendedConfirmation
                for command in dto.commands.dropFirst(confirmationIndex + 2) {
                    let activeState = await feature.currentState
                    let applicationCommand = try contextualizedCommand(
                        command,
                        activeState: activeState,
                        activeContext: &commandContext,
                        generation: &commandGeneration
                    )
                    await feature.send(applicationCommand)
                }
            } else {
                await feature.send(.start(commandContext))
                for command in dto.commands {
                    let activeState = await feature.currentState
                    let applicationCommand = try contextualizedCommand(
                        command,
                        activeState: activeState,
                        activeContext: &commandContext,
                        generation: &commandGeneration
                    )
                    await feature.send(applicationCommand)
                    if command.startsInvocation,
                       completedInvocationTarget < dto.expectedInvocationCalls
                    {
                        completedInvocationTarget += 1
                        await invocations.waitUntilInvocationCompletes(
                            completedInvocationTarget
                        )
                        await assertUnavailableProviderFailureIsClassified(
                            dto,
                            feature: feature,
                            invocations: invocations
                        )
                    }
                }
            }

            let state = await feature.currentState
            let invocationCounts = await invocations.counts()
            XCTAssertEqual(
                invocationCounts.invocations,
                dto.expectedInvocationCalls,
                dto.scenarioId
            )
            XCTAssertEqual(
                invocationCounts.provider,
                dto.expectedProviderCalls,
                dto.scenarioId
            )
            XCTAssertEqual(
                invocationCounts.admission,
                dto.expectedAdmissionCalls,
                dto.scenarioId
            )
            XCTAssertEqual(
                catalogStatus(state),
                dto.expectedState.catalogStatus ?? "ready",
                dto.scenarioId
            )
            XCTAssertEqual(allChatIDs(state), dto.expectedState.allChatIds, dto.scenarioId)
            XCTAssertEqual(visibleChatIDs(state), dto.expectedState.visibleChatIds, dto.scenarioId)
            XCTAssertEqual(selectedChatID(state),
                           dto.expectedState.selectedChatId, dto.scenarioId)
            XCTAssertEqual(selectedChat(state)?.chat.title.rawValue,
                           dto.expectedState.selectedTitle, dto.scenarioId)
            XCTAssertEqual(selectedChat(state)?.chat.manifestRevision,
                           dto.expectedState.selectedRevision, dto.scenarioId)
            XCTAssertEqual(
                selectionAvailability(state),
                dto.expectedState.selectedAvailability ??
                    (dto.expectedState.selectedChatId == nil ? nil : "open"),
                dto.scenarioId
            )
            XCTAssertEqual(
                selectedFrozenReason(state),
                dto.expectedState.selectedFrozenReason,
                dto.scenarioId
            )
            if let expected = dto.expectedState.selectedDraftText {
                XCTAssertEqual(selectedChat(state)?.chat.draft.text, expected, dto.scenarioId)
            }
            if let expected = dto.expectedState.selectedDraftVersion {
                XCTAssertEqual(selectedChat(state)?.chat.draft.version, expected, dto.scenarioId)
            }
            if let expected = dto.expectedState.selectedMessageIds {
                XCTAssertEqual(
                    selectedChat(state)?.chat.messageIDs.map(\.rawValue),
                    expected,
                    dto.scenarioId
                )
            }
            if let expected = dto.expectedState.composerStatus {
                XCTAssertEqual(composerStatus(state), expected, dto.scenarioId)
            }
            if let expected = dto.expectedState.pendingUserTurnId {
                XCTAssertEqual(
                    selectedChat(state)?.pendingUserTurn?.id.rawValue,
                    expected,
                    dto.scenarioId
                )
            }
            if let expected = dto.expectedState.responsePositionId {
                XCTAssertEqual(
                    selectedChat(state)?.pendingUserTurn?.responsePositionID.rawValue,
                    expected,
                    dto.scenarioId
                )
            }
            if let expected = dto.expectedState.pendingFailure {
                XCTAssertEqual(
                    selectedChat(state)?.pendingUserTurn?.failure?.rawValue,
                    expected,
                    dto.scenarioId
                )
            }
            XCTAssertEqual(state.notice?.rawValue, dto.expectedState.notice, dto.scenarioId)
            if let expected = dto.expectedState.newChatPickerStatus {
                XCTAssertEqual(newChatPickerStatus(state), expected, dto.scenarioId)
            }
            if let expected = dto.expectedState.newChatFilterQuery {
                XCTAssertEqual(newChatPicker(state)?.filterQuery.rawValue, expected, dto.scenarioId)
            }
            if let expected = dto.expectedState.newChatAllAttachmentIds {
                XCTAssertEqual(
                    newChatPicker(state)?.allRows.map(\.id.rawValue),
                    expected,
                    dto.scenarioId
                )
            }
            if let expected = dto.expectedState.newChatVisibleAttachmentIds {
                XCTAssertEqual(
                    newChatPicker(state)?.visibleRows.map(\.id.rawValue),
                    expected,
                    dto.scenarioId
                )
            }
            if let expected = dto.expectedState.newChatSelectedAttachmentIds {
                XCTAssertEqual(
                    newChatPicker(state)?.allRows.compactMap {
                        newChatPicker(state)?.selectedAttachmentIDs.contains($0.id) == true
                            ? $0.id.rawValue
                            : nil
                    },
                    expected,
                    dto.scenarioId
                )
            }
            if let expected = dto.expectedState.newChatFeasibility {
                XCTAssertEqual(newChatFeasibility(state), expected, dto.scenarioId)
            }
            if let expected = dto.expectedState.newChatIssue {
                XCTAssertEqual(newChatIssue(state), expected, dto.scenarioId)
            }
            if let expected = dto.expectedState.openedAttachmentStatuses {
                XCTAssertEqual(openedAttachmentStatuses(state), expected, dto.scenarioId)
            }
            let recordedEvents = await recorder.events
            XCTAssertEqual(recordedEvents, dto.dependencyTrace.map(\.signature), dto.scenarioId)
            let expectedCommittedChats = try dto.dependencyTrace.compactMap {
                event -> ChatAggregate? in
                guard event.port == "chatStore", event.effect == "create",
                      event.outcome.rendered == "committed", let chat = event.chat
                else { return nil }
                return try aggregate(chat)
            }
            let actualCommittedChats = await recorder.committedChats
            XCTAssertEqual(actualCommittedChats, expectedCommittedChats, dto.scenarioId)
        }
    }

    private func assertUnavailableProviderFailureIsClassified(
        _ scenario: ChatFeatureScenarioDTO,
        feature: DefaultChatFeature,
        invocations: any ScenarioMeasuringInvocations,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let counts = await invocations.counts()
        guard scenario.providerAvailability == "unavailable", counts.provider > 0 else {
            return
        }
        let state = await feature.currentState
        XCTAssertEqual(
            selectedChat(state)?.pendingUserTurn?.failure,
            .coachProviderError,
            scenario.scenarioId,
            file: file,
            line: line
        )
    }

    private func aggregate(_ dto: ChatScenarioSnapshotDTO) throws -> ChatAggregate {
        let attachments = try ChatAttachments(
            validating: dto.attachments.map {
                ChatSessionAttachment(
                    attachmentID: try ChatSessionAttachmentID($0.attachmentId),
                    sessionID: try SessionID($0.sessionId),
                    transcriptRevisionID: try TranscriptRevisionID($0.transcriptRevisionId)
                )
            }
        )
        let chatID = try ChatID(dto.chatId)
        let memoryID = try CoachMemoryID(dto.memoryId)
        let chat = try Chat(
            id: chatID,
            manifestRevision: dto.manifestRevision,
            title: ChatTitle(dto.title),
            createdAt: UTCInstant(dto.createdAt),
            updatedAt: UTCInstant(dto.updatedAt),
            creation: ChatCreation(
                kind: .newChat,
                originAttachmentID: nil,
                attachments: attachments
            ),
            profileStatementGenerationAtCreation: 0,
            attachments: attachments,
            draft: ChatDraft(
                draftID: ChatDraftID(dto.draftId),
                version: dto.draftVersion,
                text: dto.draftText,
                updatedAt: UTCInstant(dto.updatedAt)
            ),
            messageIDs: try dto.messageIds.map(ChatMessageID.init),
            currentMemoryID: memoryID
        )
        return try ChatAggregate(
            chat: chat,
            memory: CoachMemory(
                memoryID: memoryID,
                chatID: chatID,
                generalNotes: dto.memoryGeneralNotes,
                sessionSummaries: try dto.memorySessionSummaries.map {
                    CoachMemorySessionSummary(
                        sessionAttachmentID: try ChatSessionAttachmentID($0.sessionAttachmentId),
                        notes: $0.notes
                    )
                },
                attachments: attachments
            )
        )
    }

    private func catalogStatus(_ state: ChatFeatureState) -> String {
        switch state.catalog {
        case .ready: "ready"
        case .failed: "failed"
        case .notLoaded: "notLoaded"
        case .loading: "loading"
        }
    }

    private func allChatIDs(_ state: ChatFeatureState) -> [String] {
        guard case let .ready(catalog) = state.catalog else { return [] }
        return catalog.allRows.map(\.chatID.rawValue)
    }

    private func visibleChatIDs(_ state: ChatFeatureState) -> [String] {
        guard case let .ready(catalog) = state.catalog else { return [] }
        return catalog.visibleRows.map(\.chatID.rawValue)
    }

    private func selectedChat(_ state: ChatFeatureState) -> ChatAggregate? {
        guard case let .open(aggregate) = state.selection else { return nil }
        return aggregate
    }

    private func selectedChatID(_ state: ChatFeatureState) -> String? {
        switch state.selection {
        case let .open(aggregate): aggregate.chat.id.rawValue
        case let .frozen(frozen): frozen.chatID.rawValue
        case let .opening(chatID): chatID.rawValue
        case .none: nil
        }
    }

    private func selectionAvailability(_ state: ChatFeatureState) -> String? {
        switch state.selection {
        case .open: "open"
        case .frozen: "frozen"
        case .none, .opening: nil
        }
    }

    private func selectedFrozenReason(_ state: ChatFeatureState) -> String? {
        guard case let .frozen(frozen) = state.selection else { return nil }
        return frozen.reason.rawValue
    }

    private func composerStatus(_ state: ChatFeatureState) -> String? {
        switch state.composer {
        case .editable: "editable"
        case .locked: "locked"
        case nil: nil
        }
    }

    private func newChatPickerStatus(_ state: ChatFeatureState) -> String {
        switch state.newChatPicker {
        case .closed: "closed"
        case .loading: "loading"
        case .ready: "ready"
        case .failed: "failed"
        }
    }

    private func newChatPicker(
        _ state: ChatFeatureState
    ) -> ChatAttachmentPickerSnapshot? {
        guard case let .ready(snapshot) = state.newChatPicker else { return nil }
        return snapshot
    }

    private func newChatFeasibility(_ state: ChatFeatureState) -> String? {
        guard let snapshot = newChatPicker(state) else { return nil }
        return switch snapshot.feasibility {
        case .quoting: "quoting"
        case let .available(quote): quote.context.fits ? "fits" : "cannotFit"
        case let .providerUnavailable(lowerBound):
            lowerBound.provesImpossible ? "cannotFit" : "providerUnavailable"
        case let .unavailable(reason): reason.rawValue
        }
    }

    private func newChatIssue(_ state: ChatFeatureState) -> String? {
        guard let issue = newChatPicker(state)?.issue else { return nil }
        return switch issue {
        case .selectionLimitReached: "selectionLimitReached"
        case .attachmentUnavailable: "attachmentUnavailable"
        case .contextCannotFit: "contextCannotFit"
        case let .contextUnavailable(reason): reason.rawValue
        case .qualifiedConfigurationUnavailable:
            "qualifiedConfigurationUnavailable"
        }
    }

    private func openedAttachmentStatuses(
        _ state: ChatFeatureState
    ) -> [ChatOpenedAttachmentStatusDTO]? {
        guard case let .resolved(resolutions) = state.openedAttachments else { return nil }
        return resolutions.map { resolved in
            let status: String
            switch resolved.resolution {
            case .available: status = "available"
            case let .unavailable(reason): status = reason.rawValue
            }
            return ChatOpenedAttachmentStatusDTO(
                attachmentId: resolved.attachment.attachmentID.rawValue,
                status: status
            )
        }
    }
}

private struct ChatFeatureScenarioDTO: Decodable {
    let schemaVersion: UInt32
    let scenarioId: String
    let libraryId: String
    let initialChats: [ChatScenarioSnapshotDTO]
    let commands: [ChatScenarioCommandDTO]
    let dependencyTrace: [ChatDependencyEventDTO]
    let expectedState: ChatScenarioStateDTO
    let expectedProviderCalls: Int
    let expectedInvocationCalls: Int
    let expectedAdmissionCalls: Int
    let providerAvailability: String?
    let contextCapacityMode: String?
    let suspendedEffect: String?
}

private struct ChatScenarioSnapshotDTO: Decodable {
    let chatId: String
    let draftId: String
    let memoryId: String
    let manifestRevision: UInt64
    let title: String
    let createdAt: String
    let updatedAt: String
    let creationKind: String
    let attachments: [ChatAttachmentDTO]
    let draftText: String
    let draftVersion: UInt64
    let messageIds: [String]
    let memoryGeneralNotes: String
    let memorySessionSummaries: [ChatMemorySummaryDTO]
}

private struct ChatAttachmentDTO: Decodable {
    let attachmentId: String
    let sessionId: String
    let transcriptRevisionId: String
}

private struct ChatMemorySummaryDTO: Decodable {
    let sessionAttachmentId: String
    let notes: String
}

private struct ChatScenarioCommandDTO: Decodable {
    let kind: String
    let libraryId: String?
    let chatId: String?
    let title: String?
    let expectedRevision: UInt64?
    let query: String?
    let text: String?
    let pendingUserTurnId: String?
    let attachmentId: String?

    var startsInvocation: Bool {
        kind == "sendDraft" || kind == "retryPendingUserTurn"
    }

    func applicationCommand(
        context: ChatCommandContext,
        activeChatID: ChatID?,
        activeDraft: ChatDraft?,
        newChatConfirmationToken: NewChatConfirmationToken?
    ) throws -> ChatCommand {
        switch kind {
            case "beginNewChat":
                guard libraryId == nil, chatId == nil, title == nil,
                      expectedRevision == nil, query == nil, text == nil,
                      pendingUserTurnId == nil, attachmentId == nil
                else {
                    throw ScenarioFailure.command
                }
                return .beginNewChat(context)
            case "setNewChatAttachmentFilter":
                guard libraryId == nil, chatId == nil, title == nil,
                      expectedRevision == nil, let query, text == nil,
                      pendingUserTurnId == nil, attachmentId == nil
                else {
                    throw ScenarioFailure.command
                }
                return .setNewChatAttachmentFilter(
                    context,
                    try ChatAttachmentFilterQuery(query)
                )
            case "toggleNewChatAttachment":
                guard libraryId == nil, chatId == nil, title == nil,
                      expectedRevision == nil, query == nil, text == nil,
                      pendingUserTurnId == nil, let attachmentId
                else {
                    throw ScenarioFailure.command
                }
                return .toggleNewChatAttachment(
                    context,
                    try ChatSessionAttachmentID(attachmentId)
                )
            case "cancelNewChat":
                guard libraryId == nil, chatId == nil, title == nil,
                      expectedRevision == nil, query == nil, text == nil,
                      pendingUserTurnId == nil, attachmentId == nil
                else {
                    throw ScenarioFailure.command
                }
                return .cancelNewChat(context)
            case "confirmNewChat":
                guard libraryId == nil, chatId == nil, title == nil,
                      expectedRevision == nil, query == nil, text == nil,
                      pendingUserTurnId == nil, attachmentId == nil
                else {
                    throw ScenarioFailure.command
                }
                return .confirmNewChat(
                    context,
                    newChatConfirmationToken ?? NewChatConfirmationToken()
                )
            case "rename":
                guard libraryId == nil, let chatId, let title, let expectedRevision,
                      query == nil, text == nil, pendingUserTurnId == nil
                else {
                    throw ScenarioFailure.command
                }
                return .rename(context, try ChatID(chatId), title: title,
                               expectedRevision: expectedRevision)
            case "setFilter":
                guard libraryId == nil, let query, chatId == nil, title == nil,
                      expectedRevision == nil, text == nil, pendingUserTurnId == nil
                else {
                    throw ScenarioFailure.command
                }
                return .setFilter(context, try ChatFilterQuery(query))
            case "open":
                guard libraryId == nil, let chatId, title == nil,
                      expectedRevision == nil, query == nil, text == nil,
                      pendingUserTurnId == nil
                else {
                    throw ScenarioFailure.command
                }
                return .open(context, try ChatID(chatId))
            case "editDraft":
                guard libraryId == nil, chatId == nil, title == nil,
                      expectedRevision == nil, query == nil, let text,
                      pendingUserTurnId == nil, let activeChatID, let activeDraft
                else {
                    throw ScenarioFailure.command
                }
                return .editDraft(context, activeChatID, activeDraft.draftID, text: text)
            case "sendDraft":
                guard libraryId == nil, chatId == nil, title == nil,
                      expectedRevision == nil, query == nil, text == nil,
                      pendingUserTurnId == nil, let activeChatID, let activeDraft
                else {
                    throw ScenarioFailure.command
                }
                return .sendDraft(context, activeChatID, activeDraft)
            case "refreshContextQuote":
                guard libraryId == nil, chatId == nil, title == nil,
                      expectedRevision == nil, query == nil, text == nil,
                      pendingUserTurnId == nil, let activeChatID, let activeDraft
                else {
                    throw ScenarioFailure.command
                }
                return .refreshContextQuote(context, activeChatID, activeDraft)
            case "discardPendingUserTurn":
                guard libraryId == nil, chatId == nil, title == nil,
                      expectedRevision == nil, query == nil, text == nil,
                      let pendingUserTurnId
                else {
                    throw ScenarioFailure.command
                }
                return .discardPendingUserTurn(
                    context,
                    try PendingUserTurnID(pendingUserTurnId)
                )
            case "retryPendingUserTurn":
                guard libraryId == nil, chatId == nil, title == nil,
                      expectedRevision == nil, query == nil, text == nil,
                      let pendingUserTurnId
                else {
                    throw ScenarioFailure.command
                }
                return .retryPendingUserTurn(
                    context,
                    try PendingUserTurnID(pendingUserTurnId)
                )
            case "createNewChatFromCapacityFailure":
                guard libraryId == nil, chatId == nil, title == nil,
                      expectedRevision == nil, query == nil, text == nil,
                      let pendingUserTurnId
                else {
                    throw ScenarioFailure.command
                }
                return .createNewChatFromCapacityFailure(
                    context,
                    try PendingUserTurnID(pendingUserTurnId)
                )
            case "start":
                guard let libraryId, chatId == nil, title == nil,
                      expectedRevision == nil, query == nil, text == nil,
                      pendingUserTurnId == nil
                else {
                    throw ScenarioFailure.command
                }
                let scope = LibraryScope(libraryID: try LibraryID(libraryId))
                guard context.libraryScope == scope else {
                    throw ScenarioFailure.command
                }
                return .start(context)
            default:
                throw ScenarioFailure.command
        }
    }
}

private func contextualizedCommand(
    _ command: ChatScenarioCommandDTO,
    activeState: ChatFeatureState,
    activeContext: inout ChatCommandContext,
    generation: inout UInt64
) throws -> ChatCommand {
    if command.kind == "start" {
        guard let libraryID = command.libraryId else {
            throw ScenarioFailure.command
        }
        generation &+= 1
        activeContext = ChatCommandContext(
            libraryScope: LibraryScope(libraryID: try LibraryID(libraryID)),
            generation: generation
        )
    }
    let identity: (ChatID, ChatDraft)? = {
        guard case let .open(aggregate) = activeState.selection,
              case let .editable(draft, _) = activeState.composer,
              aggregate.chat.draft.draftID == draft.draftID
        else {
            return nil
        }
        return (aggregate.chat.id, draft)
    }()
    return try command.applicationCommand(
        context: activeContext,
        activeChatID: identity?.0,
        activeDraft: identity?.1,
        newChatConfirmationToken: {
            guard case let .ready(snapshot) = activeState.newChatPicker else {
                return nil
            }
            return snapshot.confirmationToken
        }()
    )
}

private struct ChatDependencyEventDTO: Decodable {
    let port: String
    let effect: String
    let outcome: ChatDependencyEventOutcomeDTO
    let chat: ChatScenarioSnapshotDTO?
    let libraryId: String?
    let chatIds: [String]?
    let reason: String?
    let candidates: [NewChatAttachmentCandidateDTO]?
    let resolutions: [ChatAttachmentResolutionDTO]?
    let fits: Bool?

    var signature: String { "\(port):\(effect):\(outcome.rendered)" }
}

private struct NewChatAttachmentCandidateDTO: Decodable {
    let sessionId: String
    let transcriptRevisionId: String
    let displayLabel: String
    let durationMilliseconds: UInt64
    let approximateTranscriptTokens: Int
    let delivery: String

    func candidate() throws -> ChatAttachmentCandidate {
        guard let delivery = ChatAttachmentDelivery(rawValue: delivery) else {
            throw ScenarioFailure.script
        }
        return try ChatAttachmentCandidate(
            sessionID: SessionID(sessionId),
            transcriptRevisionID: TranscriptRevisionID(transcriptRevisionId),
            displayLabel: displayLabel,
            durationMilliseconds: durationMilliseconds,
            approximateTranscriptTokens: approximateTranscriptTokens,
            delivery: delivery
        )
    }
}

private struct ChatAttachmentResolutionDTO: Decodable {
    let attachment: ChatAttachmentDTO
    let status: String
    let candidate: NewChatAttachmentCandidateDTO?

    func resolution() throws -> ResolvedChatAttachment {
        let attachment = ChatSessionAttachment(
            attachmentID: try ChatSessionAttachmentID(attachment.attachmentId),
            sessionID: try SessionID(attachment.sessionId),
            transcriptRevisionID: try TranscriptRevisionID(
                attachment.transcriptRevisionId
            )
        )
        let value: ChatAttachmentResolution
        if status == "available", let candidate {
            value = .available(try candidate.candidate())
        } else if let reason = ChatAttachmentUnavailableReason(rawValue: status),
                  candidate == nil {
            value = .unavailable(reason)
        } else {
            throw ScenarioFailure.script
        }
        return try ResolvedChatAttachment(
            attachment: attachment,
            resolution: value
        )
    }
}

private enum ChatDependencyEventOutcomeDTO: Decodable {
    case text(String)
    case nonnegativeWholeNumber(UInt64)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let text = try? value.decode(String.self) {
            self = .text(text)
        } else {
            self = .nonnegativeWholeNumber(try value.decode(UInt64.self))
        }
    }

    var rendered: String {
        switch self {
        case let .text(value): value
        case let .nonnegativeWholeNumber(value): String(value)
        }
    }
}

private struct ChatScenarioStateDTO: Decodable {
    let allChatIds: [String]
    let visibleChatIds: [String]
    let catalogStatus: String?
    let selectedChatId: String?
    let selectedTitle: String?
    let selectedRevision: UInt64?
    let selectedAvailability: String?
    let selectedFrozenReason: String?
    let selectedDraftText: String?
    let selectedDraftVersion: UInt64?
    let selectedMessageIds: [String]?
    let composerStatus: String?
    let pendingUserTurnId: String?
    let responsePositionId: String?
    let pendingFailure: String?
    let notice: String?
    let newChatPickerStatus: String?
    let newChatFilterQuery: String?
    let newChatAllAttachmentIds: [String]?
    let newChatVisibleAttachmentIds: [String]?
    let newChatSelectedAttachmentIds: [String]?
    let newChatFeasibility: String?
    let newChatIssue: String?
    let openedAttachmentStatuses: [ChatOpenedAttachmentStatusDTO]?
}

private struct ChatOpenedAttachmentStatusDTO: Decodable, Equatable {
    let attachmentId: String
    let status: String
}

private enum ScenarioFailure: Error { case command, script }

private func suspendUntilTaskCancellation() async {
    do {
        try await Task.sleep(nanoseconds: .max)
    } catch {}
}

private actor ChatScenarioRecorder {
    private(set) var events: [String] = []
    private(set) var committedChats: [ChatAggregate] = []

    func append(port: String, effect: String, outcome: String) {
        events.append("\(port):\(effect):\(outcome)")
    }

    func appendCommittedChat(_ aggregate: ChatAggregate) {
        committedChats.append(aggregate)
    }
}

private actor ChatScenarioStore: ChatStorePort {
    private var chats: [ChatID: ChatAggregate]
    private var events: [ChatDependencyEventDTO]
    private let recorder: ChatScenarioRecorder
    private let suspendFirstCatalogLoad: Bool
    private var firstCatalogLoadStarted = false
    private var firstCatalogLoadContinuation: CheckedContinuation<Void, Never>?

    init(
        initial: [ChatAggregate],
        events: [ChatDependencyEventDTO],
        recorder: ChatScenarioRecorder,
        suspendFirstCatalogLoad: Bool
    ) {
        chats = Dictionary(uniqueKeysWithValues: initial.map { ($0.chat.id, $0) })
        self.events = events
        self.recorder = recorder
        self.suspendFirstCatalogLoad = suspendFirstCatalogLoad
    }

    func waitUntilFirstCatalogLoadStarts() async {
        while !firstCatalogLoadStarted { await Task.yield() }
    }

    func resumeFirstCatalogLoad() {
        firstCatalogLoadContinuation?.resume()
        firstCatalogLoadContinuation = nil
    }

    func loadCatalog(in library: LibraryScope) async -> ChatCatalogOutcome {
        guard let event = consume(effect: "loadCatalog") else {
            XCTFail("missing scripted loadCatalog event")
            return .failed
        }
        if let expectedLibraryID = event.libraryId {
            XCTAssertEqual(library.libraryID.rawValue, expectedLibraryID)
        }
        if suspendFirstCatalogLoad, !firstCatalogLoadStarted {
            firstCatalogLoadStarted = true
            await withCheckedContinuation { firstCatalogLoadContinuation = $0 }
        }
        await record(event)
        switch event.outcome.rendered {
        case "loaded":
            let selected: [ChatAggregate]
            if let chatIds = event.chatIds {
                selected = chatIds.compactMap { rawValue in
                    guard let chatID = try? ChatID(rawValue) else { return nil }
                    return chats[chatID]
                }
            } else {
                selected = Array(chats.values)
            }
            return .loaded(selected.map(ChatCatalogEntry.available))
        case "readOnlyLibrary":
            return .readOnlyLibrary
        default:
            return .failed
        }
    }

    func create(_ commit: NewChatCommit) async -> ChatMutationOutcome {
        let seed = commit.seed
        guard let event = consume(effect: "create") else {
            XCTFail("missing scripted create event")
            return .failed
        }
        await record(event)
        switch event.outcome.rendered {
        case "committed":
            chats[seed.aggregate.chat.id] = seed.aggregate
            await recorder.appendCommittedChat(seed.aggregate)
            return .committed(seed.aggregate)
        case "collision":
            return .collision
        case "attachmentUnavailable":
            return .attachmentUnavailable
        case "readOnlyLibrary":
            return .readOnlyLibrary
        default:
            return .failed
        }
    }

    func rename(_ mutation: RenameChatMutation) async -> ChatMutationOutcome {
        guard let event = consume(effect: "rename"),
              let current = chats[mutation.chatID]
        else {
            XCTFail("missing scripted rename event or Chat")
            return .failed
        }
        await record(event)
        if event.outcome.rendered == "stale" || current != mutation.base {
            return .stale(current)
        }
        guard event.outcome.rendered == "committed" else { return .failed }
        let updated = mutation.replacement
        chats[mutation.chatID] = updated
        return .committed(updated)
    }

    func saveDraft(_ mutation: SaveChatDraftMutation) async -> ChatMutationOutcome {
        guard let event = consume(effect: "saveDraft"),
              let current = chats[mutation.chatID]
        else {
            XCTFail("missing scripted Draft save event or Chat")
            return .failed
        }
        await record(event)
        guard event.outcome.rendered == "committed",
              current.pendingUserTurn == nil,
              current.chat.draft.draftID == mutation.replacement.draftID,
              mutation.replacement.version >= current.chat.draft.version
        else {
            return .stale(current)
        }
        if mutation.replacement == current.chat.draft { return .committed(current) }
        guard let updatedChat = try? current.chat.replacingDraft(with: mutation.replacement),
              let updated = try? ChatAggregate(chat: updatedChat, memory: current.memory)
        else {
            return .failed
        }
        chats[mutation.chatID] = updated
        return .committed(updated)
    }

    func lockPendingUserTurn(
        _ mutation: LockPendingUserTurnMutation
    ) async -> ChatMutationOutcome {
        guard let event = consume(effect: "lockPendingUserTurn"),
              let current = chats[mutation.chatID]
        else {
            XCTFail("missing scripted Pending User Turn lock event or Chat")
            return .failed
        }
        await record(event)
        guard event.outcome.rendered == "committed",
              current.pendingUserTurn == nil,
              current.chat.draft.draftID == mutation.pendingUserTurn.draftID,
              current.chat.draft.version == mutation.pendingUserTurn.draftVersion,
              let locked = try? ChatAggregate(
                  chat: current.chat,
                  memory: current.memory,
                  pendingUserTurn: mutation.pendingUserTurn
              )
        else {
            return .stale(current)
        }
        chats[mutation.chatID] = locked
        return .committed(locked)
    }

    func replacePendingUserTurn(
        _ mutation: ReplacePendingUserTurnMutation
    ) async -> ChatMutationOutcome {
        guard let event = consume(effect: "replacePendingUserTurn"),
              let current = chats[mutation.chatID]
        else {
            XCTFail("missing scripted Pending User Turn replacement event or Chat")
            return .failed
        }
        await record(event)
        guard event.outcome.rendered == "committed" else { return .failed }
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
        chats[mutation.chatID] = replaced
        return .committed(replaced)
    }

    func discardPendingUserTurn(
        _ mutation: DiscardPendingUserTurnMutation
    ) async -> ChatMutationOutcome {
        guard let event = consume(effect: "discardPendingUserTurn"),
              let current = chats[mutation.chatID]
        else {
            XCTFail("missing scripted Pending User Turn discard event or Chat")
            return .failed
        }
        await record(event)
        guard event.outcome.rendered == "committed",
              current.pendingUserTurn == mutation.pendingUserTurn,
              let unlocked = try? ChatAggregate(chat: current.chat, memory: current.memory)
        else {
            return .stale(current)
        }
        chats[mutation.chatID] = unlocked
        return .committed(unlocked)
    }

    func load(_ chatID: ChatID, in library: LibraryScope) async -> ChatLoadOutcome {
        guard let event = consume(effect: "load") else {
            XCTFail("missing scripted load event")
            return .failed
        }
        await record(event)
        switch event.outcome.rendered {
        case "loaded":
            guard let aggregate = chats[chatID] else { return .missing }
            return .loaded(aggregate)
        case "frozen":
            guard let reason = event.reason.flatMap({ FrozenChatReason(rawValue: $0) }) else {
                return .failed
            }
            return .frozen(FrozenChatSnapshot(chatID: chatID, reason: reason))
        case "missing":
            return .missing
        case "readOnlyLibrary":
            return .readOnlyLibrary
        default:
            return .failed
        }
    }

    func invocationSnapshot(_ chatID: ChatID) -> ChatAggregate? {
        chats[chatID]
    }

    func commitInvocationPublication(
        _ mutation: PublishCoachInvocationMutation
    ) -> InvocationPublicationOutcome {
        guard chats[mutation.invocation.chatID] == mutation.base else {
            return .stale(chats[mutation.invocation.chatID])
        }
        chats[mutation.invocation.chatID] = mutation.replacement
        return .committed(mutation.replacement)
    }

    private func consume(effect: String) -> ChatDependencyEventDTO? {
        guard let index = events.firstIndex(where: { $0.effect == effect }) else {
            return nil
        }
        return events.remove(at: index)
    }

    private func record(_ event: ChatDependencyEventDTO) async {
        await recorder.append(
            port: event.port,
            effect: event.effect,
            outcome: event.outcome.rendered
        )
    }
}

private struct ScenarioInvocationCounts: Equatable, Sendable {
    let invocations: Int
    let provider: Int
    let admission: Int
}

private protocol ScenarioMeasuringInvocations: Invocations {
    func counts() async -> ScenarioInvocationCounts
    func waitUntilInvocationCompletes(_ count: Int) async
}

private actor ScenarioFakeInvocationGateway: ScenarioMeasuringInvocations {
    private let coordinator: DefaultInvocations
    private let admission: ScenarioInvocationAdmission
    private let provider: ScenarioSyntheticProvider
    private var invocationCalls = 0
    private var completedInvocationCalls = 0
    private var completionWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    init(
        store: ChatScenarioStore,
        source: ScenarioCoachContextSnapshotPort,
        providerIsAvailable: Bool
    ) throws {
        let persistence = ScenarioInvocationPersistence(store: store)
        let admission = ScenarioInvocationAdmission()
        let provider = ScenarioSyntheticProvider(isAvailable: providerIsAvailable)
        self.admission = admission
        self.provider = provider
        coordinator = DefaultInvocations(
            persistence: persistence,
            admission: admission,
            provider: provider,
            coachContext: DefaultCoachContextFeature(source: source),
            clock: ScenarioInvocationClock(),
            identities: try ScenarioInvocationIdentities()
        )
    }

    func tryInvoke(_ request: PendingCoachInvocationRequest) async -> InvocationTryOutcome {
        invocationCalls += 1
        let outcome = await coordinator.tryInvoke(request)
        recordInvocationCompletion()
        return outcome
    }

    func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
        await coordinator.prepareNewInvocation(request)
    }

    func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async {
        await coordinator.abandonPreparedInvocation(prepared)
    }

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome {
        invocationCalls += 1
        let outcome = await coordinator.tryInvoke(prepared)
        recordInvocationCompletion()
        return outcome
    }

    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        await coordinator.admissionAvailability(in: library)
    }

    func counts() async -> ScenarioInvocationCounts {
        ScenarioInvocationCounts(
            invocations: invocationCalls,
            provider: await provider.callCount,
            admission: await admission.callCount
        )
    }

    func waitUntilInvocationCompletes(_ count: Int) async {
        guard completedInvocationCalls < count else { return }
        await withCheckedContinuation { continuation in
            completionWaiters.append((count, continuation))
        }
    }

    private func recordInvocationCompletion() {
        completedInvocationCalls += 1
        var pending: [
            (count: Int, continuation: CheckedContinuation<Void, Never>)
        ] = []
        for waiter in completionWaiters {
            if waiter.count <= completedInvocationCalls {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        completionWaiters = pending
    }
}

private actor ScenarioInvocationPersistence: InvocationPersistencePort {
    private let store: ChatScenarioStore
    private var reserved: PendingCoachInvocationRequest?
    private var active: CoachInvocation?

    init(store: ChatScenarioStore) { self.store = store }

    func openNewPendingInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> InvocationPendingSessionPreparationOutcome {
        switch await prepareNewPendingInvocation(request) {
        case let .prepared(authority):
            return .opened(
                ScenarioPendingInvocationSession(
                    persistence: self,
                    authority: authority
                )
            )
        case let .stale(current): return .stale(current)
        case let .frozen(frozen): return .frozen(frozen)
        case .readOnlyLibrary: return .readOnlyLibrary
        case .activeExists: return .blockedByActiveInvocation
        case .unavailable: return .unavailable
        }
    }

    func openPendingInvocation(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingSessionAcquisitionOutcome {
        switch await acquirePendingInvocation(request) {
        case let .acquired(authority):
            return .opened(
                ScenarioPendingInvocationSession(
                    persistence: self,
                    authority: authority
                )
            )
        case let .ineligible(current): return .ineligible(current)
        case .activeExists: return .blockedByActiveInvocation
        case .unavailable: return .unavailable
        }
    }

    func prepareNewPendingInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> InvocationPendingPreparationOutcome {
        guard active == nil, reserved == nil else { return .activeExists }
        switch await store.lockPendingUserTurn(request.lockMutation) {
        case let .committed(aggregate):
            let pendingRequest = PendingCoachInvocationRequest(
                library: request.library,
                chatID: request.chatID,
                pendingUserTurnID: request.pendingUserTurn.id
            )
            guard let authority = try? InvocationPendingAuthority(
                request: pendingRequest,
                aggregate: aggregate
            ) else { return .unavailable }
            reserved = pendingRequest
            return .prepared(authority)
        case let .stale(current): return .stale(current)
        case let .frozen(frozen): return .frozen(frozen)
        case .readOnlyLibrary: return .readOnlyLibrary
        default: return .unavailable
        }
    }

    func acquirePendingInvocation(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingAcquisitionOutcome {
        guard active == nil, reserved == nil else { return .activeExists }
        guard let aggregate = await store.invocationSnapshot(request.chatID) else {
            return .ineligible(nil)
        }
        guard let authority = try? InvocationPendingAuthority(
            request: request,
            aggregate: aggregate
        ) else { return .ineligible(aggregate) }
        reserved = request
        return .acquired(authority)
    }

    func revalidatePendingInvocation(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingResolutionOutcome {
        guard reserved == authority.request else { return .unavailable }
        guard let aggregate = await store.invocationSnapshot(authority.request.chatID)
        else {
            reserved = nil
            return .ineligible(nil)
        }
        guard let current = try? InvocationPendingAuthority(
            request: authority.request,
            aggregate: aggregate
        ) else {
            reserved = nil
            return .ineligible(aggregate)
        }
        return .eligible(current)
    }

    func installInvocation(
        _ mutation: InstallCoachInvocationMutation
    ) async -> InvocationInstallOutcome {
        guard active == nil else { return .activeExists }
        guard await store.invocationSnapshot(mutation.invocation.chatID) ==
            mutation.authority.aggregate
        else {
            return .stale(await store.invocationSnapshot(mutation.invocation.chatID))
        }
        if mutation.authority.aggregate != mutation.processingAggregate,
           let base = mutation.authority.aggregate.pendingUserTurn,
           let replacement = mutation.processingAggregate.pendingUserTurn
        {
            guard let processingMutation = try? ReplacePendingUserTurnMutation(
                library: mutation.authority.request.library,
                chatID: mutation.authority.request.chatID,
                base: base,
                replacement: replacement
            ) else { return .failed }
            guard case .committed = await store.replacePendingUserTurn(
                processingMutation
            ) else { return .failed }
        }
        reserved = nil
        active = mutation.invocation
        return .installed(mutation.invocation)
    }

    func cancelInvocationReservation(
        _ request: PendingCoachInvocationRequest
    ) async {
        if reserved == request { reserved = nil }
    }

    func checkLaunchIdentity(
        _ identity: InvocationLaunchIdentity,
        for authority: InvocationPendingAuthority
    ) async -> InvocationLaunchIdentityAvailabilityOutcome {
        guard await store.invocationSnapshot(authority.request.chatID) ==
            authority.aggregate
        else { return .stale(await store.invocationSnapshot(authority.request.chatID)) }
        return .available
    }

    func markContextCapacityFailure(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome {
        await markPendingFailure(authority, failure: .coachContextCannotFit)
    }

    func markInterruptedNewSend(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome {
        await markPendingFailure(authority, failure: .coachResponseInterrupted)
    }

    private func markPendingFailure(
        _ authority: InvocationPendingAuthority,
        failure: PendingUserTurnFailure
    ) async -> InvocationPendingMutationOutcome {
        if reserved == authority.request { reserved = nil }
        let failed = authority.pendingUserTurn.replacingFailure(failure)
        guard let mutation = try? ReplacePendingUserTurnMutation(
            library: authority.request.library,
            chatID: authority.request.chatID,
            base: authority.pendingUserTurn,
            replacement: failed
        ) else { return .failed }
        return pendingOutcome(await store.replacePendingUserTurn(mutation))
    }

    func rejectNewSend(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome {
        if reserved == authority.request { reserved = nil }
        return pendingOutcome(
            await store.discardPendingUserTurn(
                DiscardPendingUserTurnMutation(
                    library: authority.request.library,
                    chatID: authority.request.chatID,
                    pendingUserTurn: authority.pendingUserTurn
                )
            )
        )
    }

    func abortInstalledNewSend(
        _ invocation: CoachInvocation,
        failure: PendingUserTurnFailure
    ) async -> InvocationPendingMutationOutcome {
        guard active == invocation,
              let aggregate = await store.invocationSnapshot(invocation.chatID),
              let pending = aggregate.pendingUserTurn
        else { return .stale(await store.invocationSnapshot(invocation.chatID)) }
        active = nil
        guard let mutation = try? ReplacePendingUserTurnMutation(
            library: LibraryScope(libraryID: invocation.libraryID),
            chatID: invocation.chatID,
            base: pending,
            replacement: pending.replacingFailure(failure)
        ) else { return .failed }
        return pendingOutcome(
            await store.replacePendingUserTurn(mutation)
        )
    }

    func publish(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationOutcome {
        guard active == mutation.invocation else {
            return .stale(await store.invocationSnapshot(mutation.invocation.chatID))
        }
        let outcome = await store.commitInvocationPublication(mutation)
        if case .committed = outcome { active = nil }
        return outcome
    }

    private func pendingOutcome(
        _ outcome: ChatMutationOutcome
    ) -> InvocationPendingMutationOutcome {
        switch outcome {
        case let .committed(value): .committed(value)
        case let .stale(value): .stale(value)
        default: .failed
        }
    }
}

private actor ScenarioPendingInvocationSession: InvocationPendingPersistenceSession {
    private enum State {
        case pending(InvocationPendingAuthority)
        case finished
    }

    nonisolated let authority: InvocationPendingAuthority
    private let persistence: ScenarioInvocationPersistence
    private var state: State

    init(
        persistence: ScenarioInvocationPersistence,
        authority: InvocationPendingAuthority
    ) {
        self.persistence = persistence
        self.authority = authority
        state = .pending(authority)
    }

    func revalidate() async -> InvocationPendingResolutionOutcome {
        guard case let .pending(current) = state else { return .unavailable }
        let outcome = await persistence.revalidatePendingInvocation(current)
        switch outcome {
        case let .eligible(updated): state = .pending(updated)
        case .ineligible: state = .finished
        case .unavailable: break
        }
        return outcome
    }

    func checkLaunchIdentity(
        _ identity: InvocationLaunchIdentity
    ) async -> InvocationLaunchIdentityAvailabilityOutcome {
        guard case let .pending(current) = state else { return .unavailable }
        let outcome = await persistence.checkLaunchIdentity(identity, for: current)
        if case let .stale(aggregate) = outcome,
           let aggregate,
           let updated = try? InvocationPendingAuthority(
               request: current.request,
               aggregate: aggregate
           )
        {
            state = .pending(updated)
        }
        return outcome
    }

    func install(
        _ mutation: InstallCoachInvocationMutation
    ) async -> InvocationSessionInstallOutcome {
        guard case let .pending(current) = state,
              current == mutation.authority
        else { return .failed }
        switch await persistence.installInvocation(mutation) {
        case let .installed(invocation):
            state = .finished
            return .installed(
                ScenarioActiveInvocationSession(
                    persistence: persistence,
                    invocation: invocation,
                    processingAggregate: mutation.processingAggregate
                )
            )
        case .activeExists: return .blockedByActiveInvocation
        case let .stale(aggregate):
            if let aggregate,
               let updated = try? InvocationPendingAuthority(
                   request: current.request,
                   aggregate: aggregate
               )
            {
                state = .pending(updated)
            }
            return .stale(aggregate)
        case .failed: return .failed
        }
    }

    func terminate(
        _ termination: InvocationPendingTermination
    ) async -> InvocationTerminalPersistenceOutcome {
        guard case let .pending(current) = state else {
            return .recovered(.unavailable)
        }
        state = .finished
        let outcome: InvocationPendingMutationOutcome
        switch termination {
        case .contextCapacityFailure:
            outcome = await persistence.markContextCapacityFailure(current)
        case .interrupted:
            outcome = await persistence.markInterruptedNewSend(current)
        case .rejected:
            outcome = await persistence.rejectNewSend(current)
        }
        switch outcome {
        case let .committed(aggregate): return .committed(aggregate)
        case let .stale(current): return .stale(current)
        case .failed:
            return .recovered(
                await persistence.recoverPendingAfterTerminalFailure(current.request)
            )
        }
    }

    func abandon() async {
        guard case let .pending(current) = state else { return }
        state = .finished
        await persistence.cancelInvocationReservation(current.request)
    }
}

private actor ScenarioActiveInvocationSession: InvocationActivePersistenceSession {
    nonisolated let invocation: CoachInvocation
    nonisolated let processingAggregate: ChatAggregate
    private let persistence: ScenarioInvocationPersistence
    private var isActive = true

    init(
        persistence: ScenarioInvocationPersistence,
        invocation: CoachInvocation,
        processingAggregate: ChatAggregate
    ) {
        self.persistence = persistence
        self.invocation = invocation
        self.processingAggregate = processingAggregate
    }

    func installNextAttempt(
        _ mutation: InstallNextCoachProviderAttemptMutation
    ) async -> InvocationNextAttemptInstallOutcome {
        .failed
    }

    func abort(
        failure: PendingUserTurnFailure
    ) async -> InvocationTerminalPersistenceOutcome {
        guard isActive else { return .recovered(.unavailable) }
        isActive = false
        switch await persistence.abortInstalledNewSend(
            invocation,
            failure: failure
        ) {
        case let .committed(aggregate): return .committed(aggregate)
        case let .stale(current): return .stale(current)
        case .failed:
            return .recovered(
                await persistence.recoverPendingAfterTerminalFailure(
                    PendingCoachInvocationRequest(
                        library: LibraryScope(libraryID: invocation.libraryID),
                        chatID: invocation.chatID,
                        pendingUserTurnID: invocation.pendingUserTurnID
                    )
                )
            )
        }
    }

    func publish(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationOutcome {
        guard isActive, mutation.invocation == invocation else { return .failed }
        let outcome = await persistence.publish(mutation)
        if case .committed = outcome { isActive = false }
        return outcome
    }

    func recoverPublished(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationRecoveryOutcome {
        guard isActive, mutation.invocation == invocation else { return .unavailable }
        let outcome = await persistence.recoverPublishedInvocation(mutation)
        if case .published = outcome { isActive = false }
        return outcome
    }
}

private actor ScenarioInvocationAdmission: InvocationAdmissionPort {
    private(set) var callCount = 0

    func availability(
        library: LibraryScope,
        at instant: UTCInstant
    ) async -> InvocationAdmissionAvailability {
        .available
    }

    func claim(
        library: LibraryScope,
        at instant: UTCInstant
    ) async -> InvocationAdmissionClaimOutcome {
        callCount += 1
        return .admitted
    }
}

private actor ScenarioSyntheticProvider: SyntheticCoachProviderPort {
    private let isAvailable: Bool
    private(set) var callCount = 0

    init(isAvailable: Bool) {
        self.isAvailable = isAvailable
    }

    func run(_ request: SyntheticCoachProviderRequest) async -> CoachProviderAttemptOutcome {
        callCount += 1
        guard isAvailable else { return .userRetryableFailure }
        return .complete(markdown: "A complete **synthetic** Coach response.")
    }
}

private actor ScenarioInvocationClock: ChatClock {
    private var instants = [
        try! UTCInstant("2026-08-30T12:00:02.000Z"),
        try! UTCInstant("2026-08-30T12:00:03.000Z"),
    ]

    func now() async -> UTCInstant {
        instants.isEmpty
            ? try! UTCInstant("2026-08-30T12:00:03.000Z")
            : instants.removeFirst()
    }
}

private struct ScenarioInvocationIdentities: InvocationIdentityGenerating {
    private let identity: InvocationLaunchIdentity

    init() throws {
        identity = InvocationLaunchIdentity(
            invocationID: try CoachInvocationID("inv-20260830T120002000Z-5KMN"),
            attemptID: try CoachProviderAttemptID("atm-20260830T120002000Z-6PQR"),
            idempotencyValue: try ProviderIdempotencyValue("synthetic-attempt-6PQR"),
            userMessageID: try ChatMessageID("msg-20260830T120003000Z-7STV"),
            coachMessageID: try ChatMessageID("msg-20260830T120003000Z-8WXY"),
            freshDraftID: try ChatDraftID("drf-20260830T120003000Z-9Z23")
        )
    }

    func generateInvocationID(at instant: UTCInstant) async -> CoachInvocationID {
        identity.invocationID
    }

    func generateAttemptIdentity(
        at instant: UTCInstant,
        ordinal: UInt8,
        kind: CoachProviderAttemptKind,
        transcriptHandleCount: Int
    ) async -> InvocationAttemptIdentity {
        identity.attemptIdentity
    }
}

private actor ChatScenarioScript:
    ChatClock, ChatIDGenerator, ChatDraftIDGenerator, CoachMemoryIDGenerator,
    PendingUserTurnIDGenerator, ChatResponsePositionIDGenerator,
    ProfileStatementGenerationReading
{
    private var events: [ChatDependencyEventDTO]
    private let recorder: ChatScenarioRecorder

    init(events: [ChatDependencyEventDTO], recorder: ChatScenarioRecorder) {
        self.events = events.filter {
            $0.port != "chatStore" && $0.port != "attachmentSource" &&
                $0.port != "coachContext"
        }
        self.recorder = recorder
    }

    func statementGeneration(in library: LibraryScope) async -> UInt64? {
        guard let event = consume(port: "profileHead", effect: "readStatementGeneration"),
              let value = UInt64(event.outcome.rendered)
        else { return nil }
        await record(event)
        return value
    }

    func now() async -> UTCInstant {
        let event = consume(port: "clock", effect: "now")!
        await record(event)
        return try! UTCInstant(event.outcome.rendered)
    }

    func generateChatID(at instant: UTCInstant) async -> ChatID {
        let event = consume(port: "chatIdGenerator", effect: "next")!
        await record(event)
        return try! ChatID(event.outcome.rendered)
    }

    func generateChatDraftID(at instant: UTCInstant) async -> ChatDraftID {
        let event = consume(port: "chatDraftIdGenerator", effect: "next")!
        await record(event)
        return try! ChatDraftID(event.outcome.rendered)
    }

    func generateCoachMemoryID(at instant: UTCInstant) async -> CoachMemoryID {
        let event = consume(port: "coachMemoryIdGenerator", effect: "next")!
        await record(event)
        return try! CoachMemoryID(event.outcome.rendered)
    }

    func generatePendingUserTurnID(at instant: UTCInstant) async -> PendingUserTurnID {
        let event = consume(port: "pendingUserTurnIdGenerator", effect: "next")!
        await record(event)
        return try! PendingUserTurnID(event.outcome.rendered)
    }

    func generateChatResponsePositionID(
        at instant: UTCInstant
    ) async -> ChatResponsePositionID {
        let event = consume(port: "chatResponsePositionIdGenerator", effect: "next")!
        await record(event)
        return try! ChatResponsePositionID(event.outcome.rendered)
    }

    private func consume(port: String, effect: String) -> ChatDependencyEventDTO? {
        guard let index = events.firstIndex(where: { $0.port == port && $0.effect == effect }) else {
            return nil
        }
        return events.remove(at: index)
    }

    private func record(_ event: ChatDependencyEventDTO) async {
        await recorder.append(
            port: event.port,
            effect: event.effect,
            outcome: event.outcome.rendered
        )
    }
}

private let developmentScenarioConfigurationStamp = CoachContextConfigurationStamp(
    authorityID: UUID(uuidString: "00000000-0000-0000-0000-000000000225")!,
    generation: 1
)
private let developmentScenarioEvidenceAuthority = ChatCreationEvidenceAuthority(
    testingValue: UUID(uuidString: "00000000-0000-0000-0000-000000000226")!
)

private struct ScenarioBoundCoachContext: ChatCoachContextCoordinating {
    let attachmentSource: any ChatSessionAttachmentSource
    let base: any CoachContextCoordinating
    let providerUnavailable: Bool
    let rejectsCreationLease: Bool

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
        let outcome = await base.quoteNewChat(request)
        let classifiedOutcome: ChatCreationQuoteOutcome =
            providerUnavailable && outcome == .unavailable(.sourceUnavailable)
                ? .unavailable(.providerUnavailable)
                : outcome
        switch classifiedOutcome {
        case let .available(quote):
            return .available(
                quote,
                authority: ChatCreationQuoteAuthority(
                    configuration: developmentScenarioConfigurationStamp,
                    evidence: developmentScenarioEvidenceAuthority
                )
            )
        case .unavailable(.providerUnavailable):
            return .providerUnavailable(
                scenarioProviderUnavailableCapacityLowerBound(),
                authority: ChatCreationQuoteAuthority(
                    configuration: developmentScenarioConfigurationStamp,
                    evidence: developmentScenarioEvidenceAuthority
                )
            )
        case let .unavailable(reason):
            return .unavailable(reason)
        }
    }

    func acquireNewChatCreationLease(
        _ authority: ChatCreationQuoteAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        guard authority.configuration == developmentScenarioConfigurationStamp else {
            return .stale
        }
        guard !rejectsCreationLease else { return .stale }
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

private actor ChatScenarioAttachmentSource: ChatSessionAttachmentSource {
    private var events: [ChatDependencyEventDTO]
    private let recorder: ChatScenarioRecorder
    private var cancelledResolutionStarted = false

    init(events: [ChatDependencyEventDTO], recorder: ChatScenarioRecorder) {
        self.events = events
        self.recorder = recorder
    }

    func loadCandidates(
        in library: LibraryScope
    ) async -> ChatAttachmentCatalogOutcome {
        guard let event = consume(effect: "loadCandidates") else {
            XCTFail("missing scripted attachment catalog event")
            return .failed
        }
        await record(event)
        switch event.outcome.rendered {
        case "loaded":
            do {
                return .loaded(
                    try (event.candidates ?? []).map { try $0.candidate() },
                    configuration: developmentScenarioConfigurationStamp
                )
            } catch {
                XCTFail("invalid scripted attachment candidate: \(error)")
                return .failed
            }
        case "readOnlyLibrary":
            return .readOnlyLibrary
        case "qualifiedConfigurationUnavailable":
            return .qualifiedConfigurationUnavailable
        default:
            return .failed
        }
    }

    func resolve(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentResolutionOutcome {
        guard let event = consume(effect: "resolveAttachments") else {
            XCTFail("missing scripted attachment resolution event")
            return .failed
        }
        if event.outcome.rendered == "cancelled" {
            cancelledResolutionStarted = true
            await suspendUntilTaskCancellation()
            await record(event)
            return .failed
        }
        await record(event)
        switch event.outcome.rendered {
        case "resolved":
            do {
                let resolved = try (event.resolutions ?? []).map { try $0.resolution() }
                XCTAssertEqual(resolved.map(\.attachment), attachments.values)
                return .resolved(
                    resolved,
                    configuration: developmentScenarioConfigurationStamp
                )
            } catch {
                XCTFail("invalid scripted attachment resolution: \(error)")
                return .failed
            }
        case "readOnlyLibrary":
            return .readOnlyLibrary
        case "qualifiedConfigurationUnavailable":
            return .qualifiedConfigurationUnavailable
        default:
            return .failed
        }
    }

    func waitUntilCancelledResolutionStarts() async {
        while !cancelledResolutionStarted { await Task.yield() }
    }

    private func consume(effect: String) -> ChatDependencyEventDTO? {
        guard let index = events.firstIndex(where: { $0.effect == effect }) else {
            return nil
        }
        return events.remove(at: index)
    }

    private func record(_ event: ChatDependencyEventDTO) async {
        await recorder.append(
            port: event.port,
            effect: event.effect,
            outcome: event.outcome.rendered
        )
    }
}

private func scenarioProviderUnavailableCapacityLowerBound()
    -> ChatCreationCapacityLowerBound
{
    try! CoachContextCapacity().lowerBoundNewChat(
        creation: try! ChatCreation(
            kind: .newChat,
            originAttachmentID: nil,
            attachments: .empty
        ),
        attachments: [],
        configuration: try! CoachContextConfiguration(
            descriptor: CoachProviderDescriptor(
                displayName: "Scenario provider-unavailable fixture",
                contextBudget: CoachContextBudget(
                    contextWindowTokens: 100_000,
                    responseReservedTokens: 32,
                    safetyMarginTokens: 8
                ),
                coachMemoryMaxTokens: 1
            ),
            policy: CoachProviderEstimationPolicy(
                providerIdentifier: "scenario-provider-unavailable-v1",
                responseCollectorByteCeiling: 8_192,
                framing: CoachProviderFraming(),
                attachmentProjectionPolicy: try! CoachAttachmentProjectionPolicy(
                    maximumInlineTranscriptTokens: 8_192,
                    tokenEstimator: .utf8ByteUpperBound()
                )
            )
        )
    )
}

private actor ScenarioCoachContextSnapshotPort: CoachContextSnapshotPort {
    private let mode: String
    private var events: [ChatDependencyEventDTO]
    private let recorder: ChatScenarioRecorder
    private var pendingResolutionCount = 0
    private var cancelledNewChatQuoteStarted = false

    init(
        mode: String,
        events: [ChatDependencyEventDTO],
        recorder: ChatScenarioRecorder
    ) {
        self.mode = mode
        self.events = events
        self.recorder = recorder
    }

    func resolveNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        guard let event = consume(effect: "quoteNewChat") else {
            XCTFail("missing scripted New Chat quote event")
            return .sourceUnavailable
        }
        if event.outcome.rendered == "cancelled" {
            cancelledNewChatQuoteStarted = true
            await suspendUntilTaskCancellation()
            await record(event)
            return .sourceUnavailable
        }
        await record(event)
        switch event.outcome.rendered {
        case "available":
            guard let fits = event.fits else {
                XCTFail("scripted available quote is missing fits")
                return .sourceUnavailable
            }
            return newChatSnapshot(for: request, fits: fits)
        case "providerUnavailable":
            return .providerUnavailable
        case "staleState":
            return .staleState
        case "invalidContext":
            return invalidContextSnapshot(for: request)
        case "sourceUnavailable":
            return .sourceUnavailable
        default:
            XCTFail("unsupported scripted New Chat quote outcome: \(event.outcome.rendered)")
            return .sourceUnavailable
        }
    }

    func waitUntilCancelledNewChatQuoteStarts() async {
        while !cancelledNewChatQuoteStarted { await Task.yield() }
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
            ),
            contextWindow: 100_000
        )
    }

    func resolvePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextSnapshotOutcome {
        pendingResolutionCount += 1
        let contextWindow = mode == "cannotFitThenFits" && pendingResolutionCount == 1
            ? 64
            : 100_000
        return snapshot(
            for: request.draft,
            binding: .pending(
                library: request.library,
                chatID: request.chatID,
                draftID: request.draft.draftID,
                draftVersion: request.draft.version,
                pendingUserTurnID: request.pendingUserTurn.id,
                responsePositionID: request.pendingUserTurn.responsePositionID
            ),
            contextWindow: contextWindow
        )
    }

    func isCurrent(_ authority: CoachContextSnapshotAuthority) async -> Bool {
        authority.contextGeneration == UInt64(pendingResolutionCount + 1) &&
            authority.configurationGeneration == UInt64(pendingResolutionCount + 1)
    }

    func acquireAuthorityLease(
        _ authority: CoachContextSourceLeaseAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        await acquireImmutableAuthorityLease(authority)
    }

    func currentQualifiedConfiguration()
        async -> CoachQualifiedConfigurationOutcome
    {
        .knownQualified(
            configuration: try! qualifiedConfiguration(),
            configurationGeneration: UInt64(pendingResolutionCount + 1)
        )
    }

    func isCurrentConfiguration(_ configurationGeneration: UInt64) async -> Bool {
        configurationGeneration == UInt64(pendingResolutionCount + 1)
    }

    private func qualifiedConfiguration() throws -> CoachContextConfiguration {
        try CoachContextConfiguration(
            descriptor: CoachProviderDescriptor(
                displayName: "Synthetic scenario fixture",
                contextBudget: CoachContextBudget(
                    contextWindowTokens: 100_000,
                    responseReservedTokens: 32,
                    safetyMarginTokens: 8
                ),
                coachMemoryMaxTokens: 1
            ),
            policy: CoachProviderEstimationPolicy(
                providerIdentifier: "synthetic-scenario-v1",
                responseCollectorByteCeiling: 8_192,
                framing: CoachProviderFraming(),
                attachmentProjectionPolicy: try CoachAttachmentProjectionPolicy(
                    maximumInlineTranscriptTokens: 8_192,
                    tokenEstimator: .utf8ByteUpperBound()
                )
            )
        )
    }

    private func newChatSnapshot(
        for request: CoachContextNewChatQuoteRequest,
        fits: Bool
    ) -> CoachContextSnapshotOutcome {
        do {
            let transcriptBytes = fits ? 32 : 1_000
            let prepared = request.attachments.values.map { attachment in
                PreparedCoachAttachment.inline(
                    requestValue: .object([
                        "sessionAttachmentId": .string(
                            attachment.attachmentID.rawValue
                        ),
                        "displayLabel": .string("Synthetic Session"),
                        "transcript": .object([
                            "text": .string(
                                String(repeating: "x", count: transcriptBytes)
                            ),
                        ]),
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
                        attachments: prepared
                    ),
                    configuration: try CoachContextConfiguration(
                        descriptor: CoachProviderDescriptor(
                            displayName: "Synthetic scenario fixture",
                            contextBudget: CoachContextBudget(
                                contextWindowTokens: fits ? 100_000 : 400,
                                responseReservedTokens: 32,
                                safetyMarginTokens: 8
                            ),
                            coachMemoryMaxTokens: 1
                        ),
                        policy: CoachProviderEstimationPolicy(
                            providerIdentifier: "synthetic-scenario-v1",
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
                        contextGeneration: UInt64(pendingResolutionCount + 1),
                        configurationGeneration: UInt64(pendingResolutionCount + 1),
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

    private func invalidContextSnapshot(
        for request: CoachContextNewChatQuoteRequest
    ) -> CoachContextSnapshotOutcome {
        do {
            let rejectingEstimator = try CoachTokenEstimator(
                identifier: "synthetic-invalid-context-v1",
                mode: .exact,
                maximumUTF8BytesPerToken: 1,
                implementation: { _ in -1 }
            )
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
                    configuration: try CoachContextConfiguration(
                        descriptor: CoachProviderDescriptor(
                            displayName: "Synthetic invalid-context fixture",
                            contextBudget: CoachContextBudget(
                                contextWindowTokens: 100_000,
                                responseReservedTokens: 32,
                                safetyMarginTokens: 8
                            ),
                            coachMemoryMaxTokens: 1
                        ),
                        policy: CoachProviderEstimationPolicy(
                            providerIdentifier: "synthetic-invalid-context-v1",
                            responseCollectorByteCeiling: 8_192,
                            framing: CoachProviderFraming(),
                            attachmentProjectionPolicy:
                                try CoachAttachmentProjectionPolicy(
                                    maximumInlineTranscriptTokens: 8_192,
                                    tokenEstimator: rejectingEstimator
                                )
                        )
                    ),
                    authority: CoachContextSnapshotAuthority(
                        binding: .newChat(
                            library: request.library,
                            attachments: request.attachments,
                            creation: request.creation
                        ),
                        contextGeneration: UInt64(pendingResolutionCount + 1),
                        configurationGeneration: UInt64(pendingResolutionCount + 1),
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

    private func consume(effect: String) -> ChatDependencyEventDTO? {
        guard let index = events.firstIndex(where: { $0.effect == effect }) else {
            return nil
        }
        return events.remove(at: index)
    }

    private func record(_ event: ChatDependencyEventDTO) async {
        await recorder.append(
            port: event.port,
            effect: event.effect,
            outcome: event.outcome.rendered
        )
    }

    private func snapshot(
        for draft: ChatDraft,
        binding: CoachContextSnapshotBinding,
        contextWindow: Int
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
                    configuration: try CoachContextConfiguration(
                        descriptor: CoachProviderDescriptor(
                            displayName: "Synthetic scenario fixture",
                            contextBudget: CoachContextBudget(
                                contextWindowTokens: contextWindow,
                                responseReservedTokens: 16,
                                safetyMarginTokens: 8
                            ),
                            coachMemoryMaxTokens: 1
                        ),
                        policy: CoachProviderEstimationPolicy(
                            providerIdentifier: "synthetic-scenario-v1",
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
                        binding: binding,
                        contextGeneration: UInt64(pendingResolutionCount + 1),
                        configurationGeneration: UInt64(pendingResolutionCount + 1),
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
}

private struct ScenarioAdmissionRefreshScheduler: ChatAdmissionRefreshScheduling {
    func sleep(until deadline: UTCInstant) async throws {}
}
