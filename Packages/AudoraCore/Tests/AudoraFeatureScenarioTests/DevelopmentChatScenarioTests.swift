@testable @_spi(CoachContextQualification) @_spi(InvocationInfrastructure) import AudoraApplication
import AudoraContracts
import AudoraDomain
import Foundation
import XCTest

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class DevelopmentChatScenarioTests: XCTestCase {
    func testEveryDevelopmentChatScenarioMatchesTheSwiftFeature() async throws {
        let resources: [ContractResource] = [
            .createDevelopmentChatScenario,
            .draftSendDiscardDevelopmentChatScenario,
            .contextCapacityRecoveryDevelopmentChatScenario,
            .fakeProviderSuccessDevelopmentChatScenario,
            .renameDevelopmentChatScenario,
            .filterDevelopmentChatsScenario,
            .relaunchDevelopmentChatScenario,
            .staleRenameDevelopmentChatScenario,
            .wrongLibraryDevelopmentChatScenario,
            .corruptDevelopmentChatScenario,
            .newerDevelopmentChatScenario,
            .collisionDevelopmentChatScenario,
            .providerUnavailableDevelopmentChatScenario,
            .suspendedLibrarySwitchDevelopmentChatScenario,
        ]

        for resource in resources {
            let dto = try JSONDecoder().decode(
                DevelopmentChatScenarioDTO.self,
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
            let contextSource = ScenarioCoachContextSnapshotPort(
                mode: dto.contextCapacityMode ?? "alwaysFits"
            )
            let invocations: any ScenarioMeasuringInvocations = if dto.expectedProviderCalls > 0 {
                try ScenarioFakeInvocationGateway(store: store, source: contextSource)
            } else {
                ScenarioContextInvocationGateway(store: store, source: contextSource)
            }
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
                coachContext: DefaultCoachContextFeature(
                    source: contextSource
                ),
                invocations: invocations
            )
            let scope = LibraryScope(libraryID: try LibraryID(dto.libraryId))
            var commandGeneration: UInt64 = 1
            var commandContext = ChatCommandContext(
                libraryScope: scope,
                generation: commandGeneration
            )

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

    private func aggregate(_ dto: DevelopmentChatSnapshotDTO) throws -> ChatAggregate {
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
}

private struct DevelopmentChatScenarioDTO: Decodable {
    let schemaVersion: UInt32
    let scenarioId: String
    let libraryId: String
    let initialChats: [DevelopmentChatSnapshotDTO]
    let commands: [DevelopmentChatCommandDTO]
    let dependencyTrace: [DevelopmentChatEventDTO]
    let expectedState: DevelopmentChatStateDTO
    let expectedProviderCalls: Int
    let expectedInvocationCalls: Int
    let expectedAdmissionCalls: Int
    let providerAvailability: String?
    let contextCapacityMode: String?
    let suspendedEffect: String?
}

private struct DevelopmentChatSnapshotDTO: Decodable {
    let chatId: String
    let draftId: String
    let memoryId: String
    let manifestRevision: UInt64
    let title: String
    let createdAt: String
    let updatedAt: String
    let creationKind: String
    let attachments: [DevelopmentChatAttachmentDTO]
    let draftText: String
    let draftVersion: UInt64
    let messageIds: [String]
    let memoryGeneralNotes: String
    let memorySessionSummaries: [DevelopmentChatMemorySummaryDTO]
}

private struct DevelopmentChatAttachmentDTO: Decodable {
    let attachmentId: String
    let sessionId: String
    let transcriptRevisionId: String
}

private struct DevelopmentChatMemorySummaryDTO: Decodable {
    let sessionAttachmentId: String
    let notes: String
}

private struct DevelopmentChatCommandDTO: Decodable {
    let kind: String
    let libraryId: String?
    let chatId: String?
    let title: String?
    let expectedRevision: UInt64?
    let query: String?
    let text: String?
    let pendingUserTurnId: String?

    func applicationCommand(
        context: ChatCommandContext,
        activeChatID: ChatID?,
        activeDraft: ChatDraft?
    ) throws -> ChatCommand {
        switch kind {
            case "createDevelopmentChat":
                guard libraryId == nil, chatId == nil, title == nil,
                      expectedRevision == nil, query == nil, text == nil,
                      pendingUserTurnId == nil
                else {
                    throw ScenarioFailure.command
                }
                return .createDevelopmentChat(context)
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
    _ command: DevelopmentChatCommandDTO,
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
        activeDraft: identity?.1
    )
}

private struct DevelopmentChatEventDTO: Decodable {
    let port: String
    let effect: String
    let outcome: DevelopmentChatEventOutcomeDTO
    let chat: DevelopmentChatSnapshotDTO?
    let libraryId: String?
    let chatIds: [String]?
    let reason: String?

    var signature: String { "\(port):\(effect):\(outcome.rendered)" }
}

private enum DevelopmentChatEventOutcomeDTO: Decodable {
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

private struct DevelopmentChatStateDTO: Decodable {
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
}

private enum ScenarioFailure: Error { case command, script }

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
    private var events: [DevelopmentChatEventDTO]
    private let recorder: ChatScenarioRecorder
    private let suspendFirstCatalogLoad: Bool
    private var firstCatalogLoadStarted = false
    private var firstCatalogLoadContinuation: CheckedContinuation<Void, Never>?

    init(
        initial: [ChatAggregate],
        events: [DevelopmentChatEventDTO],
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

    func create(_ seed: NewDevelopmentChatSeed) async -> ChatMutationOutcome {
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

    private func consume(effect: String) -> DevelopmentChatEventDTO? {
        guard let index = events.firstIndex(where: { $0.effect == effect }) else {
            return nil
        }
        return events.remove(at: index)
    }

    private func record(_ event: DevelopmentChatEventDTO) async {
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
}

private actor ScenarioContextInvocationGateway: ScenarioMeasuringInvocations {
    private let store: ChatScenarioStore
    private let context: DefaultCoachContextFeature
    private(set) var callCount = 0

    init(store: ChatScenarioStore, source: ScenarioCoachContextSnapshotPort) {
        self.store = store
        context = DefaultCoachContextFeature(source: source)
    }

    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        .available
    }

    func tryInvoke(_ request: PendingCoachInvocationRequest) async -> InvocationTryOutcome {
        callCount += 1
        guard let locked = await store.invocationSnapshot(request.chatID),
              let pending = locked.pendingUserTurn,
              pending.id == request.pendingUserTurnID,
              let contextRequest = try? CoachContextPendingTurnRequest(
                  library: request.library,
                  chatID: request.chatID,
                  draft: locked.chat.draft,
                  pendingUserTurn: pending
              )
        else { return .rejected(nil, .eligibilityChanged) }

        switch await context.preparePendingUserTurn(contextRequest) {
        case .prepared:
            return .interrupted(nil, .providerFailed)
        case let .cannotFit(failure):
            let failed = pending.replacingFailure(.coachContextCannotFit)
            guard let mutation = try? ReplacePendingUserTurnMutation(
                library: request.library,
                chatID: request.chatID,
                base: pending,
                replacement: failed
            ) else { return .interrupted(locked, .persistenceUnavailable) }
            guard case let .committed(current) = await store.replacePendingUserTurn(mutation)
            else { return .interrupted(locked, .persistenceUnavailable) }
            return .contextCapacityFailure(current, failure.quote)
        case let .messageTooLong(maximumUTF8Bytes):
            return .rejected(locked, .messageMustBeShortened(
                maximumUTF8Bytes: maximumUTF8Bytes
            ))
        case let .unavailable(reason):
            return .rejected(locked, .contextUnavailable(reason))
        }
    }

    func counts() async -> ScenarioInvocationCounts {
        ScenarioInvocationCounts(invocations: callCount, provider: 0, admission: 0)
    }
}

private actor ScenarioFakeInvocationGateway: ScenarioMeasuringInvocations {
    private let coordinator: DefaultInvocations
    private let admission: ScenarioInvocationAdmission
    private let provider: ScenarioSyntheticProvider
    private var invocationCalls = 0

    init(
        store: ChatScenarioStore,
        source: ScenarioCoachContextSnapshotPort
    ) throws {
        let persistence = ScenarioInvocationPersistence(store: store)
        let admission = ScenarioInvocationAdmission()
        let provider = ScenarioSyntheticProvider()
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
        return await coordinator.tryInvoke(request)
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
}

private actor ScenarioInvocationPersistence: InvocationPersistencePort {
    private let store: ChatScenarioStore
    private var active: CoachInvocation?

    init(store: ChatScenarioStore) { self.store = store }

    func resolvePending(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingResolutionOutcome {
        guard let aggregate = await store.invocationSnapshot(request.chatID) else {
            return .ineligible(nil)
        }
        guard let authority = try? InvocationPendingAuthority(
            request: request,
            aggregate: aggregate
        ) else { return .ineligible(aggregate) }
        return .eligible(authority)
    }

    func reserveInvocation(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationActiveCheckOutcome {
        active == nil ? .none : .exists
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
        active = mutation.invocation
        return .installed(mutation.invocation)
    }

    func cancelInvocationReservation(
        _ request: PendingCoachInvocationRequest
    ) async {}

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
        pendingOutcome(
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
        _ invocation: CoachInvocation
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
            replacement: pending.replacingFailure(.coachResponseInterrupted)
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
    private(set) var callCount = 0

    func run(_ request: SyntheticCoachProviderRequest) async throws -> String {
        callCount += 1
        return "A complete **synthetic** Coach response."
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

    func generate(at instant: UTCInstant) async -> InvocationLaunchIdentity { identity }
}

private actor ChatScenarioScript:
    ChatClock, ChatIDGenerator, ChatDraftIDGenerator, CoachMemoryIDGenerator,
    PendingUserTurnIDGenerator, ChatResponsePositionIDGenerator,
    ProfileStatementGenerationReading
{
    private var events: [DevelopmentChatEventDTO]
    private let recorder: ChatScenarioRecorder

    init(events: [DevelopmentChatEventDTO], recorder: ChatScenarioRecorder) {
        self.events = events.filter { $0.port != "chatStore" }
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

    private func consume(port: String, effect: String) -> DevelopmentChatEventDTO? {
        guard let index = events.firstIndex(where: { $0.port == port && $0.effect == effect }) else {
            return nil
        }
        return events.remove(at: index)
    }

    private func record(_ event: DevelopmentChatEventDTO) async {
        await recorder.append(
            port: event.port,
            effect: event.effect,
            outcome: event.outcome.rendered
        )
    }
}

private actor ScenarioCoachContextSnapshotPort: CoachContextSnapshotPort {
    private let mode: String
    private var pendingResolutionCount = 0

    init(mode: String) {
        self.mode = mode
    }

    func resolveNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        .sourceUnavailable
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
                            tokenEstimator: .utf8ByteUpperBound()
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
