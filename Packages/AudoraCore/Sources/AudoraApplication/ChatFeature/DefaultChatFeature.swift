import AudoraDomain
import Foundation

private enum QueuedChatAction: Sendable {
    case command(ChatCommand)
    case draftEdit(
        context: ChatCommandContext,
        text: String,
        chatID: ChatID,
        draftID: ChatDraftID
    )
    case sendDraft(
        context: ChatCommandContext,
        chatID: ChatID,
        draft: ChatDraft
    )
}

private struct ScheduledAutosave: Sendable {
    let context: ChatCommandContext
    let chatID: ChatID
}

private enum DraftSaveDisposition: Equatable, Sendable {
    case notAttempted
    case durable
    case retryable
    case terminal
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public actor DefaultChatFeature: ChatFeature {
    private static let maximumCollisionAttempts = 3
    private static let maximumProfileRebases = 3
    public static let draftAutosaveIntervalNanoseconds: UInt64 = 2_000_000_000

    private let store: any ChatStorePort
    private let profileReader: any ProfileStatementGenerationReading
    private let clock: any ChatClock
    private let chatIDGenerator: any ChatIDGenerator
    private let draftIDGenerator: any ChatDraftIDGenerator
    private let memoryIDGenerator: any CoachMemoryIDGenerator
    private let pendingUserTurnIDGenerator: any PendingUserTurnIDGenerator
    private let responsePositionIDGenerator: any ChatResponsePositionIDGenerator
    private let autosaveScheduler: any ChatAutosaveScheduling
    private let coachContext: any ChatCoachContextCoordinating

    private var activeContext: ChatCommandContext?
    private var requestedContext: ChatCommandContext?
    private var newChatAttachmentFilterQuery = ChatAttachmentFilterQuery.empty
    private var newChatAttachmentConfigurationStamp:
        CoachContextConfigurationStamp?
    private var state = ChatFeatureState()
    private var operationInFlight = false
    private var operationIdleWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingStart: ChatCommandContext?
    private var queuedActions: [QueuedChatAction] = []
    private var autosaveTimer: (id: UInt64, task: Task<Void, Never>)?
    private var autosaveWrite: (id: UInt64, task: Task<DraftSaveDisposition, Never>)?
    private var autosaveDueAfterWrite: ScheduledAutosave?
    private var nextAutosaveID: UInt64 = 0
    private var suppressAutosaveScheduling = false
    private var continuations: [Int: AsyncStream<ChatFeatureState>.Continuation] = [:]
    private var nextSubscriberID = 0

    public init(
        store: any ChatStorePort,
        profileReader: any ProfileStatementGenerationReading,
        clock: any ChatClock,
        chatIDGenerator: any ChatIDGenerator,
        draftIDGenerator: any ChatDraftIDGenerator,
        memoryIDGenerator: any CoachMemoryIDGenerator,
        pendingUserTurnIDGenerator: any PendingUserTurnIDGenerator,
        responsePositionIDGenerator: any ChatResponsePositionIDGenerator,
        autosaveScheduler: any ChatAutosaveScheduling = SystemChatAutosaveScheduler()
    ) {
        self.store = store
        self.profileReader = profileReader
        self.clock = clock
        self.chatIDGenerator = chatIDGenerator
        self.draftIDGenerator = draftIDGenerator
        self.memoryIDGenerator = memoryIDGenerator
        self.pendingUserTurnIDGenerator = pendingUserTurnIDGenerator
        self.responsePositionIDGenerator = responsePositionIDGenerator
        self.autosaveScheduler = autosaveScheduler
        coachContext = DefaultCoachContextFeature()
    }

    @_spi(CoachContextQualification)
    public init(
        store: any ChatStorePort,
        profileReader: any ProfileStatementGenerationReading,
        clock: any ChatClock,
        chatIDGenerator: any ChatIDGenerator,
        draftIDGenerator: any ChatDraftIDGenerator,
        memoryIDGenerator: any CoachMemoryIDGenerator,
        pendingUserTurnIDGenerator: any PendingUserTurnIDGenerator,
        responsePositionIDGenerator: any ChatResponsePositionIDGenerator,
        autosaveScheduler: any ChatAutosaveScheduling = SystemChatAutosaveScheduler(),
        attachmentEvidenceSource: any ChatSessionAttachmentEvidenceSource
    ) {
        self.store = store
        self.profileReader = profileReader
        self.clock = clock
        self.chatIDGenerator = chatIDGenerator
        self.draftIDGenerator = draftIDGenerator
        self.memoryIDGenerator = memoryIDGenerator
        self.pendingUserTurnIDGenerator = pendingUserTurnIDGenerator
        self.responsePositionIDGenerator = responsePositionIDGenerator
        self.autosaveScheduler = autosaveScheduler
        coachContext = DefaultCoachContextFeature(
            attachmentEvidenceSource: attachmentEvidenceSource
        )
    }

    init(
        store: any ChatStorePort,
        profileReader: any ProfileStatementGenerationReading,
        clock: any ChatClock,
        chatIDGenerator: any ChatIDGenerator,
        draftIDGenerator: any ChatDraftIDGenerator,
        memoryIDGenerator: any CoachMemoryIDGenerator,
        pendingUserTurnIDGenerator: any PendingUserTurnIDGenerator,
        responsePositionIDGenerator: any ChatResponsePositionIDGenerator,
        autosaveScheduler: any ChatAutosaveScheduling = SystemChatAutosaveScheduler(),
        coachContext: any ChatCoachContextCoordinating
    ) {
        self.store = store
        self.profileReader = profileReader
        self.clock = clock
        self.chatIDGenerator = chatIDGenerator
        self.draftIDGenerator = draftIDGenerator
        self.memoryIDGenerator = memoryIDGenerator
        self.pendingUserTurnIDGenerator = pendingUserTurnIDGenerator
        self.responsePositionIDGenerator = responsePositionIDGenerator
        self.autosaveScheduler = autosaveScheduler
        self.coachContext = coachContext
    }

    public var currentState: ChatFeatureState { state }

    public func currentState(in scope: LibraryScope) -> ChatFeatureState? {
        activeContext?.libraryScope == scope ? state : nil
    }

    public nonisolated var states: AsyncStream<ChatFeatureState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            Task { await self.addSubscriber(continuation) }
        }
    }

    public func send(_ command: ChatCommand) async {
        if case let .start(context) = command {
            if let newest = requestedContext ?? activeContext,
               context.generation <= newest.generation {
                return
            }
            requestedContext = context
            pendingStart = context
            guard !operationInFlight else { return }
            operationInFlight = true
            defer { finishOperation() }
            await drainWork()
            return
        }
        if contextForImmediateCommand(command) == requestedContext {
            switch command {
            case let .setFilter(_, query):
                setFilter(query)
                return
            case let .setNewChatAttachmentFilter(_, query):
                setNewChatAttachmentFilter(query)
                return
            default:
                break
            }
        }
        guard isCurrent(command.context) else { return }
        switch command {
        case let .editDraft(context, chatID, draftID, text):
            guard case let .open(aggregate) = state.selection,
                  case let .editable(draft, _) = state.composer,
                  aggregate.chat.id == chatID,
                  aggregate.pendingUserTurn == nil,
                  aggregate.chat.draft.draftID == draftID,
                  draft.draftID == draftID
            else {
                return
            }
            queuedActions.append(
                .draftEdit(
                    context: context,
                    text: text,
                    chatID: chatID,
                    draftID: draftID
                )
            )
        case let .sendDraft(context, chatID, expectedDraft):
            guard case let .open(aggregate) = state.selection,
                  case let .editable(draft, _) = state.composer,
                  aggregate.chat.id == chatID,
                  aggregate.pendingUserTurn == nil,
                  aggregate.chat.draft.draftID == expectedDraft.draftID,
                  draft == expectedDraft
            else {
                return
            }
            queuedActions.append(
                .sendDraft(
                    context: context,
                    chatID: chatID,
                    draft: expectedDraft
                )
            )
        case .start, .setFilter:
            return
        default:
            queuedActions.append(.command(command))
        }
        guard !operationInFlight else { return }
        operationInFlight = true
        defer { finishOperation() }
        await drainWork()
    }

    private func drainWork() async {
        while true {
            await drainQueuedActions()
            if pendingStart != nil {
                await drainPendingStarts()
                continue
            }
            guard !queuedActions.isEmpty else { return }
        }
    }

    private func drainQueuedActions() async {
        while !queuedActions.isEmpty {
            let action = queuedActions.removeFirst()
            switch action {
            case let .draftEdit(context, text, chatID, draftID):
                guard activeContext == context,
                      case let .open(aggregate) = state.selection,
                      aggregate.chat.id == chatID,
                      aggregate.pendingUserTurn == nil,
                      case let .editable(draft, _) = state.composer,
                      draft.draftID == draftID
                else {
                    continue
                }
                await editDraft(text, context: context)
            case let .sendDraft(context, chatID, expectedDraft):
                guard activeContext == context,
                      case let .open(aggregate) = state.selection,
                      aggregate.chat.id == chatID,
                      aggregate.pendingUserTurn == nil,
                      case let .editable(draft, _) = state.composer,
                      draft == expectedDraft
                else {
                    continue
                }
                await sendDraft(
                    context: context,
                    expectedChatID: chatID,
                    expectedDraft: expectedDraft
                )
            case let .command(command):
                guard activeContext == command.context else { continue }
                await perform(command)
            }
        }
    }

    private func perform(_ command: ChatCommand) async {
        switch command {
        case let .beginNewChat(context):
            await beginNewChat(context: context)
        case let .toggleNewChatAttachment(context, attachmentID):
            await toggleNewChatAttachment(attachmentID, context: context)
        case let .cancelNewChat(context):
            cancelNewChat(context: context)
        case let .confirmNewChat(context):
            await confirmNewChat(context: context)
        case let .rename(context, chatID, title, expectedRevision):
            await rename(
                chatID,
                rawTitle: title,
                expectedRevision: expectedRevision,
                context: context
            )
        case let .open(context, chatID):
            await open(chatID, context: context)
        case let .refreshContextQuote(context, chatID, expectedDraft):
            await refreshContextQuote(
                chatID: chatID,
                expectedDraft: expectedDraft,
                context: context
            )
        case let .retryPendingUserTurn(context, pendingUserTurnID):
            await retryPendingUserTurn(pendingUserTurnID, context: context)
        case let .createNewChatFromCapacityFailure(context, pendingUserTurnID):
            createNewChatFromCapacityFailure(pendingUserTurnID, context: context)
        case let .discardPendingUserTurn(context, pendingUserTurnID):
            await discardPendingUserTurn(pendingUserTurnID, context: context)
        case .start, .setFilter, .setNewChatAttachmentFilter,
             .editDraft, .sendDraft:
            break
        }
    }

    private func beginNewChat(
        context: ChatCommandContext,
        remainingConfigurationRefreshAttempts: Int = 1
    ) async {
        guard isActive(context), case .ready = state.catalog else { return }
        newChatAttachmentFilterQuery = .empty
        newChatAttachmentConfigurationStamp = nil
        state = replacing(
            newChatPicker: .loading,
            activity: nil,
            notice: nil
        )
        publish()
        let outcome = await coachContext.loadAttachmentCandidates(
            in: context.libraryScope
        )
        guard isCurrent(context) else { return }
        switch outcome {
        case let .loaded(candidates, configuration):
            do {
                let rows = try attachmentRows(from: candidates)
                newChatAttachmentConfigurationStamp = configuration
                let query = newChatAttachmentFilterQuery
                let snapshot = ChatAttachmentPickerSnapshot(
                    allRows: rows,
                    visibleRows: filtered(rows, by: query),
                    selectedAttachmentIDs: [],
                    filterQuery: query,
                    feasibility: .quoting
                )
                state = replacing(
                    newChatPicker: .ready(snapshot),
                    activity: nil,
                    notice: nil
                )
                publish()
                await quoteNewChatSelection(snapshot, context: context)
            } catch {
                newChatAttachmentConfigurationStamp = nil
                state = replacing(
                    newChatPicker: .failed,
                    activity: nil,
                    notice: .attachmentCatalogFailed
                )
                publish()
            }
        case .configurationChanged
            where remainingConfigurationRefreshAttempts > 0:
            await beginNewChat(
                context: context,
                remainingConfigurationRefreshAttempts:
                    remainingConfigurationRefreshAttempts - 1
            )
        case .configurationChanged:
            newChatAttachmentConfigurationStamp = nil
            state = replacing(
                newChatPicker: .failed,
                activity: nil,
                notice: .attachmentCatalogFailed
            )
            publish()
        case .readOnlyLibrary:
            newChatAttachmentConfigurationStamp = nil
            state = replacing(
                newChatPicker: .failed,
                activity: nil,
                notice: .readOnlyLibrary
            )
            publish()
        case .failed:
            newChatAttachmentConfigurationStamp = nil
            state = replacing(
                newChatPicker: .failed,
                activity: nil,
                notice: .attachmentCatalogFailed
            )
            publish()
        }
    }

    private func setNewChatAttachmentFilter(_ query: ChatAttachmentFilterQuery) {
        newChatAttachmentFilterQuery = query
        guard case let .ready(snapshot) = state.newChatPicker else { return }
        let replacement = ChatAttachmentPickerSnapshot(
            allRows: snapshot.allRows,
            visibleRows: filtered(snapshot.allRows, by: query),
            selectedAttachmentIDs: snapshot.selectedAttachmentIDs,
            filterQuery: query,
            feasibility: snapshot.feasibility,
            issue: snapshot.issue
        )
        state = replacing(
            newChatPicker: .ready(replacement),
            activity: state.activity,
            notice: nil
        )
        publish()
    }

    private func toggleNewChatAttachment(
        _ attachmentID: ChatSessionAttachmentID,
        context: ChatCommandContext
    ) async {
        guard isActive(context), case let .ready(snapshot) = state.newChatPicker,
              snapshot.allRows.contains(where: { $0.id == attachmentID })
        else { return }
        var selected = snapshot.selectedAttachmentIDs
        if selected.contains(attachmentID) {
            selected.remove(attachmentID)
        } else {
            guard selected.count < ChatAttachments.maximumCount else {
                let replacement = ChatAttachmentPickerSnapshot(
                    allRows: snapshot.allRows,
                    visibleRows: snapshot.visibleRows,
                    selectedAttachmentIDs: snapshot.selectedAttachmentIDs,
                    filterQuery: snapshot.filterQuery,
                    feasibility: snapshot.feasibility,
                    issue: .selectionLimitReached(
                        maximum: ChatAttachments.maximumCount
                    )
                )
                state = replacing(
                    newChatPicker: .ready(replacement),
                    activity: state.activity,
                    notice: nil
                )
                publish()
                return
            }
            selected.insert(attachmentID)
        }
        let replacement = ChatAttachmentPickerSnapshot(
            allRows: snapshot.allRows,
            visibleRows: snapshot.visibleRows,
            selectedAttachmentIDs: selected,
            filterQuery: snapshot.filterQuery,
            feasibility: .quoting,
            issue: nil
        )
        state = replacing(
            newChatPicker: .ready(replacement),
            activity: state.activity,
            notice: nil
        )
        publish()
        await quoteNewChatSelection(replacement, context: context)
    }

    private func cancelNewChat(context: ChatCommandContext) {
        guard isActive(context) else { return }
        newChatAttachmentFilterQuery = .empty
        newChatAttachmentConfigurationStamp = nil
        state = replacing(
            newChatPicker: .closed,
            activity: state.activity,
            notice: nil
        )
        publish()
    }

    private func confirmNewChat(context: ChatCommandContext) async {
        guard isActive(context), case let .ready(snapshot) = state.newChatPicker,
              snapshot.permitsConfirmation,
              let attachments = try? selectedAttachments(in: snapshot),
              let expectedConfiguration = newChatAttachmentConfigurationStamp
        else { return }
        let resolution = await coachContext.resolveAttachments(
            attachments,
            in: context.libraryScope
        )
        guard isCurrent(context) else { return }
        if case .configurationChanged = resolution {
            await refreshNewChatPickerForConfigurationChange(
                preserving: attachments,
                context: context,
                remainingQuoteRefreshAttempts: 0
            )
            return
        }
        guard case let .resolved(resolved, resolvedConfiguration) = resolution else {
            updatePickerIssue(.attachmentUnavailable)
            return
        }
        guard resolvedConfiguration == expectedConfiguration else {
            await refreshNewChatPickerForConfigurationChange(
                preserving: attachments,
                context: context,
                remainingQuoteRefreshAttempts: 0
            )
            return
        }
        guard resolved.count == attachments.values.count,
              zip(resolved, attachments.values).allSatisfy({ item, expected in
                  item.attachment == expected && {
                      if case .available = item.resolution { return true }
                      return false
                  }()
              })
        else {
            updatePickerIssue(.attachmentUnavailable)
            return
        }

        let quote = await authoritativeCreationQuote(
            attachments: attachments,
            context: context
        )
        guard isCurrent(context) else { return }
        switch quote {
        case let .available(_, configuration)
            where configuration != expectedConfiguration:
            await refreshNewChatPickerForConfigurationChange(
                preserving: attachments,
                context: context,
                remainingQuoteRefreshAttempts: 0
            )
            return
        case let .available(value, _) where !value.context.fits:
            updatePickerFeasibility(
                .available(value),
                issue: .contextCannotFit
            )
            return
        case let .providerUnavailable(configuration)
            where configuration != expectedConfiguration:
            await refreshNewChatPickerForConfigurationChange(
                preserving: attachments,
                context: context,
                remainingQuoteRefreshAttempts: 0
            )
            return
        case .providerUnavailable:
            break
        case let .unavailable(reason):
            updatePickerFeasibility(
                .unavailable(reason),
                issue: .contextUnavailable(reason)
            )
            return
        case .available:
            break
        }
        guard await coachContext.isCurrentAttachmentConfiguration(
            expectedConfiguration
        ) else {
            await refreshNewChatPickerForConfigurationChange(
                preserving: attachments,
                context: context,
                remainingQuoteRefreshAttempts: 0
            )
            return
        }
        await createDevelopmentChat(
            context: context,
            attachments: attachments,
            expectedConfiguration: expectedConfiguration
        )
    }

    private func quoteNewChatSelection(
        _ expected: ChatAttachmentPickerSnapshot,
        context: ChatCommandContext,
        remainingConfigurationRefreshAttempts: Int = 1
    ) async {
        guard let attachments = try? selectedAttachments(in: expected),
              let expectedConfiguration = newChatAttachmentConfigurationStamp
        else {
            updatePickerFeasibility(
                .unavailable(.invalidContext),
                issue: .contextUnavailable(.invalidContext)
            )
            return
        }
        let outcome = await authoritativeCreationQuote(
            attachments: attachments,
            context: context
        )
        guard isCurrent(context), case let .ready(current) = state.newChatPicker,
              current.selectedAttachmentIDs == expected.selectedAttachmentIDs
        else { return }
        switch outcome {
        case let .available(quote, configuration):
            guard configuration == expectedConfiguration else {
                if remainingConfigurationRefreshAttempts > 0 {
                    await refreshNewChatPickerForConfigurationChange(
                        preserving: attachments,
                        context: context,
                        remainingQuoteRefreshAttempts:
                            remainingConfigurationRefreshAttempts - 1
                    )
                } else {
                    updatePickerFeasibility(
                        .unavailable(.staleState),
                        issue: .contextUnavailable(.staleState)
                    )
                }
                return
            }
            updatePickerFeasibility(
                .available(quote),
                issue: quote.context.fits ? nil : .contextCannotFit
            )
        case let .providerUnavailable(configuration):
            guard configuration == expectedConfiguration else {
                if remainingConfigurationRefreshAttempts > 0 {
                    await refreshNewChatPickerForConfigurationChange(
                        preserving: attachments,
                        context: context,
                        remainingQuoteRefreshAttempts:
                            remainingConfigurationRefreshAttempts - 1
                    )
                } else {
                    updatePickerFeasibility(
                        .unavailable(.staleState),
                        issue: .contextUnavailable(.staleState)
                    )
                }
                return
            }
            updatePickerFeasibility(.unavailable(.providerUnavailable), issue: nil)
        case let .unavailable(reason):
            updatePickerFeasibility(
                .unavailable(reason),
                issue: .contextUnavailable(reason)
            )
        }
    }

    private func authoritativeCreationQuote(
        attachments: ChatAttachments,
        context: ChatCommandContext
    ) async -> ConfigurationBoundChatCreationQuoteOutcome {
        do {
            return await coachContext.quoteNewChatBoundToConfiguration(
                try CoachContextNewChatQuoteRequest(
                    library: context.libraryScope,
                    attachments: attachments,
                    creationKind: .newChat
                )
            )
        } catch {
            return .unavailable(.invalidContext)
        }
    }

    /// A provider/model change invalidates both the displayed row projection and
    /// its quote. Reload from immutable Session/Revision identity, preserve any
    /// still-present selection, and require an explicit subsequent confirmation.
    private func refreshNewChatPickerForConfigurationChange(
        preserving attachments: ChatAttachments,
        context: ChatCommandContext,
        remainingQuoteRefreshAttempts: Int
    ) async {
        let outcome = await coachContext.loadAttachmentCandidates(
            in: context.libraryScope
        )
        guard isCurrent(context), case let .ready(current) = state.newChatPicker else {
            return
        }
        guard case let .loaded(candidates, configuration) = outcome,
              let rows = try? attachmentRows(from: candidates)
        else {
            updatePickerFeasibility(
                .unavailable(.staleState),
                issue: .contextUnavailable(.staleState)
            )
            return
        }
        let selectedPairs = Set(attachments.values.map(attachmentPairKey))
        let selectedIDs = Set(rows.compactMap { row in
            selectedPairs.contains(attachmentPairKey(row.attachment))
                ? row.id
                : nil
        })
        let refreshed = ChatAttachmentPickerSnapshot(
            allRows: rows,
            visibleRows: filtered(rows, by: current.filterQuery),
            selectedAttachmentIDs: selectedIDs,
            filterQuery: current.filterQuery,
            feasibility: .quoting,
            issue: selectedIDs.count == selectedPairs.count
                ? nil
                : .attachmentUnavailable
        )
        newChatAttachmentConfigurationStamp = configuration
        state = replacing(
            newChatPicker: .ready(refreshed),
            activity: state.activity,
            notice: nil
        )
        publish()
        guard refreshed.issue == nil else { return }
        await quoteNewChatSelection(
            refreshed,
            context: context,
            remainingConfigurationRefreshAttempts:
                remainingQuoteRefreshAttempts
        )
    }

    private func attachmentPairKey(_ attachment: ChatSessionAttachment) -> String {
        attachment.sessionID.rawValue + "\u{0}" +
            attachment.transcriptRevisionID.rawValue
    }

    private func updatePickerFeasibility(
        _ feasibility: ChatCreationFeasibility,
        issue: ChatAttachmentPickerIssue?
    ) {
        guard case let .ready(snapshot) = state.newChatPicker else { return }
        let replacement = ChatAttachmentPickerSnapshot(
            allRows: snapshot.allRows,
            visibleRows: snapshot.visibleRows,
            selectedAttachmentIDs: snapshot.selectedAttachmentIDs,
            filterQuery: snapshot.filterQuery,
            feasibility: feasibility,
            issue: issue
        )
        state = replacing(
            newChatPicker: .ready(replacement),
            activity: state.activity,
            notice: nil
        )
        publish()
    }

    private func updatePickerIssue(_ issue: ChatAttachmentPickerIssue) {
        guard case let .ready(snapshot) = state.newChatPicker else { return }
        let replacement = ChatAttachmentPickerSnapshot(
            allRows: snapshot.allRows,
            visibleRows: snapshot.visibleRows,
            selectedAttachmentIDs: snapshot.selectedAttachmentIDs,
            filterQuery: snapshot.filterQuery,
            feasibility: snapshot.feasibility,
            issue: issue
        )
        state = replacing(
            newChatPicker: .ready(replacement),
            activity: state.activity,
            notice: nil
        )
        publish()
    }

    private func attachmentRows(
        from candidates: [ChatAttachmentCandidate]
    ) throws -> [ChatAttachmentPickerRow] {
        guard candidates.count <= ChatAttachmentCandidate.maximumCatalogCount else {
            throw ChatAttachmentCatalogError.tooManyCandidates
        }
        let ordered = candidates.sorted { lhs, rhs in
            let left = folded(lhs.displayLabel)
            let right = folded(rhs.displayLabel)
            if left != right { return left < right }
            if lhs.sessionID != rhs.sessionID {
                return lhs.sessionID.rawValue < rhs.sessionID.rawValue
            }
            return lhs.transcriptRevisionID.rawValue < rhs.transcriptRevisionID.rawValue
        }
        var seenPairs: Set<String> = []
        return try ordered.enumerated().map { index, candidate in
            let pairKey = candidate.sessionID.rawValue + "\u{0}" +
                candidate.transcriptRevisionID.rawValue
            guard seenPairs.insert(pairKey).inserted else {
                throw ChatAttachmentsError.duplicateSessionRevision
            }
            let attachment = ChatSessionAttachment(
                attachmentID: try ChatSessionAttachmentID(
                    String(format: "attachment-%06d", index + 1)
                ),
                sessionID: candidate.sessionID,
                transcriptRevisionID: candidate.transcriptRevisionID
            )
            return ChatAttachmentPickerRow(
                attachment: attachment,
                candidate: candidate
            )
        }
    }

    private func selectedAttachments(
        in snapshot: ChatAttachmentPickerSnapshot
    ) throws -> ChatAttachments {
        try ChatAttachments(
            validating: snapshot.allRows.compactMap { row in
                snapshot.selectedAttachmentIDs.contains(row.id) ? row.attachment : nil
            }
        )
    }

    private func drainPendingStarts() async {
        while let context = pendingStart {
            pendingStart = nil
            guard context == requestedContext else { continue }
            if let activeContext {
                guard await flushSelectedDraft(in: activeContext) else {
                    requestedContext = activeContext
                    pendingStart = nil
                    return
                }
                guard context == requestedContext else { continue }
            }
            activeContext = context
            state = ChatFeatureState(
                catalog: .loading,
                filterQuery: state.filterQuery,
                selection: .none,
                newChatPicker: .closed,
                openedAttachments: .notRequested
            )
            newChatAttachmentFilterQuery = .empty
            newChatAttachmentConfigurationStamp = nil
            publish()
            await start(in: context)
        }
    }

    private func start(in context: ChatCommandContext) async {
        let outcome = await store.loadCatalog(in: context.libraryScope)
        guard isCurrent(context) else { return }
        switch outcome {
        case let .loaded(entries):
            let query = state.filterQuery
            state = ChatFeatureState(
                catalog: readyCatalog(from: entries, query: query),
                filterQuery: query,
                selection: .none,
                newChatPicker: .closed,
                openedAttachments: .notRequested
            )
        case .readOnlyLibrary:
            let query = state.filterQuery
            state = ChatFeatureState(
                catalog: .failed,
                filterQuery: query,
                selection: .none,
                newChatPicker: .closed,
                openedAttachments: .notRequested,
                notice: .readOnlyLibrary
            )
        case .failed:
            let query = state.filterQuery
            state = ChatFeatureState(
                catalog: .failed,
                filterQuery: query,
                selection: .none,
                newChatPicker: .closed,
                openedAttachments: .notRequested,
                notice: .catalogFailed
            )
        }
        publish()
    }

    private func createDevelopmentChat(
        context: ChatCommandContext,
        attachments: ChatAttachments,
        expectedConfiguration: CoachContextConfigurationStamp
    ) async {
        guard isActive(context), case .ready = state.catalog else { return }
        guard await flushSelectedDraft(in: context) else { return }
        let library = context.libraryScope
        state = replacing(activity: .creating, notice: nil)
        publish()

        let observedStatementGeneration = await profileReader.statementGeneration(in: library)
        guard isActive(context) else { return }
        guard var statementGeneration = observedStatementGeneration else {
            state = replacing(activity: nil, notice: .createFailed)
            publish()
            return
        }
        let instant = await clock.now()
        guard isActive(context) else { return }

        var collisionAttempts = 0
        var profileRebases = 0
        while true {
            let chatID = await chatIDGenerator.generateChatID(at: instant)
            guard isActive(context) else { return }
            let draftID = await draftIDGenerator.generateChatDraftID(at: instant)
            guard isActive(context) else { return }
            let memoryID = await memoryIDGenerator.generateCoachMemoryID(at: instant)
            guard isActive(context) else { return }
            let seed: NewDevelopmentChatSeed
            do {
                seed = try NewDevelopmentChatSeed(
                    library: library,
                    chatID: chatID,
                    draftID: draftID,
                    memoryID: memoryID,
                    instant: instant,
                    profileStatementGeneration: statementGeneration,
                    attachments: attachments
                )
            } catch {
                state = replacing(activity: nil, notice: .createFailed)
                publish()
                return
            }

            guard await coachContext.isCurrentAttachmentConfiguration(
                expectedConfiguration
            ) else {
                state = replacing(activity: nil, notice: nil)
                publish()
                await refreshNewChatPickerForConfigurationChange(
                    preserving: attachments,
                    context: context,
                    remainingQuoteRefreshAttempts: 0
                )
                return
            }

            let outcome = await store.create(seed)
            guard isActive(context) else { return }
            switch outcome {
            case let .committed(committed):
                newChatAttachmentFilterQuery = .empty
                newChatAttachmentConfigurationStamp = nil
                state = replacing(
                    newChatPicker: .closed,
                    activity: state.activity,
                    notice: state.notice
                )
                install(committed, selection: .open(committed), notice: nil)
                await resolveOpenedAttachments(for: committed, context: context)
                await refreshContextAdvisory(
                    for: committed,
                    draft: committed.chat.draft,
                    context: context
                )
                return
            case .collision:
                collisionAttempts += 1
                guard collisionAttempts < Self.maximumCollisionAttempts else {
                    state = replacing(activity: nil, notice: .createCollisionLimitReached)
                    publish()
                    return
                }
                continue
            case let .profileStatementGenerationChanged(current):
                profileRebases += 1
                guard profileRebases < Self.maximumProfileRebases else {
                    state = replacing(activity: nil, notice: .createFailed)
                    publish()
                    return
                }
                statementGeneration = current
                continue
            case let .frozen(frozen):
                install(frozen, selection: .frozen(frozen), notice: .chatFrozen)
                return
            case .readOnlyLibrary:
                state = replacing(activity: nil, notice: .readOnlyLibrary)
                publish()
                return
            case .stale, .failed:
                state = replacing(activity: nil, notice: .createFailed)
                publish()
                return
            }
        }
    }

    private func rename(
        _ chatID: ChatID,
        rawTitle: String,
        expectedRevision: UInt64,
        context: ChatCommandContext
    ) async {
        guard isActive(context), case .ready = state.catalog else { return }
        let ownedDirtyDraftBeforeFlush: (aggregate: ChatAggregate, draft: ChatDraft)? = {
            guard case let .open(aggregate) = state.selection,
                  aggregate.chat.id == chatID,
                  case let .editable(draft, true) = state.composer,
                  aggregate.chat.draft.draftID == draft.draftID
            else {
                return nil
            }
            return (aggregate, draft)
        }()
        guard await flushSelectedDraft(in: context) else { return }
        let library = context.libraryScope
        let title: ChatTitle
        do {
            title = try ChatTitle(rawTitle)
        } catch {
            state = replacing(activity: nil, notice: .invalidTitle)
            publish()
            return
        }
        let base: ChatAggregate
        if case let .open(aggregate) = state.selection, aggregate.chat.id == chatID {
            base = aggregate
        } else {
            let outcome = await store.load(chatID, in: library)
            guard isActive(context) else { return }
            switch outcome {
            case let .loaded(aggregate):
                base = aggregate
            case let .frozen(frozen):
                install(frozen, selection: .frozen(frozen), notice: .chatFrozen)
                return
            case .missing:
                state = replacing(activity: nil, notice: .chatMissing)
                publish()
                return
            case .readOnlyLibrary:
                state = replacing(activity: nil, notice: .readOnlyLibrary)
                publish()
                return
            case .failed:
                state = replacing(activity: nil, notice: .renameFailed)
                publish()
                return
            }
        }
        let effectiveExpectedRevision: UInt64 = {
            guard let before = ownedDirtyDraftBeforeFlush,
                  before.aggregate.chat.manifestRevision == expectedRevision,
                  before.aggregate.chat.title == base.chat.title,
                  base.chat.draft == before.draft
            else {
                return expectedRevision
            }
            let (ownedRevision, overflow) = expectedRevision.addingReportingOverflow(1)
            return !overflow && base.chat.manifestRevision == ownedRevision
                ? ownedRevision
                : expectedRevision
        }()
        guard base.chat.manifestRevision == effectiveExpectedRevision else {
            install(
                base,
                selection: selectionReplacing(chatID, with: .open(base)),
                notice: .staleRename
            )
            return
        }
        if base.chat.title == title {
            state = replacing(activity: nil, notice: nil)
            publish()
            return
        }

        state = replacing(activity: .renaming(chatID), notice: nil)
        publish()
        let instant = await clock.now()
        guard isActive(context) else { return }
        let mutation: RenameChatMutation
        do {
            mutation = try RenameChatMutation(
                library: library,
                base: base,
                title: title,
                updatedAt: instant
            )
        } catch {
            state = replacing(activity: nil, notice: .renameFailed)
            publish()
            return
        }
        let outcome = await store.rename(mutation)
        guard isActive(context) else { return }
        switch outcome {
        case let .committed(committed):
            let selection = selectionReplacing(chatID, with: .open(committed))
            install(committed, selection: selection, notice: nil)
        case let .stale(current):
            let selection = selectionReplacing(chatID, with: .open(current))
            install(current, selection: selection, notice: .staleRename)
        case let .frozen(frozen):
            let selection = selectionReplacing(chatID, with: .frozen(frozen))
            install(frozen, selection: selection, notice: .chatFrozen)
        case .readOnlyLibrary:
            state = replacing(activity: nil, notice: .readOnlyLibrary)
            publish()
        case .collision, .failed:
            state = replacing(activity: nil, notice: .renameFailed)
            publish()
        case .profileStatementGenerationChanged:
            state = replacing(activity: nil, notice: .renameFailed)
            publish()
        }
    }

    private func setFilter(_ query: ChatFilterQuery) {
        guard case let .ready(catalog) = state.catalog else {
            state = ChatFeatureState(
                catalog: state.catalog,
                filterQuery: query,
                selection: state.selection,
                composer: state.composer,
                contextAdvisory: state.contextAdvisory,
                createNewChatRecoveryIntent: state.createNewChatRecoveryIntent,
                newChatPicker: state.newChatPicker,
                openedAttachments: state.openedAttachments,
                activity: state.activity,
                notice: state.notice
            )
            publish()
            return
        }
        state = ChatFeatureState(
            catalog: .ready(
                ChatCatalogSnapshot(
                    allRows: catalog.allRows,
                    visibleRows: filtered(catalog.allRows, by: query)
                )
            ),
            filterQuery: query,
            selection: state.selection,
            composer: state.composer,
            contextAdvisory: state.contextAdvisory,
            createNewChatRecoveryIntent: state.createNewChatRecoveryIntent,
            newChatPicker: state.newChatPicker,
            openedAttachments: state.openedAttachments,
            activity: state.activity,
            notice: nil
        )
        publish()
    }

    private func open(_ chatID: ChatID, context: ChatCommandContext) async {
        guard isActive(context), case .ready = state.catalog else { return }
        guard await flushSelectedDraft(in: context) else { return }
        let library = context.libraryScope
        state = replacing(
            selection: .opening(chatID),
            composer: nil,
            replacesComposer: true,
            openedAttachments: .notRequested,
            activity: nil,
            notice: nil
        )
        publish()
        let outcome = await store.load(chatID, in: library)
        guard isActive(context) else { return }
        switch outcome {
        case let .loaded(aggregate):
            install(aggregate, selection: .open(aggregate), notice: nil)
            await resolveOpenedAttachments(for: aggregate, context: context)
            await refreshContextAdvisory(
                for: aggregate,
                draft: aggregate.chat.draft,
                context: context
            )
        case let .frozen(frozen):
            install(frozen, selection: .frozen(frozen), notice: .chatFrozen)
        case .missing:
            state = replacing(
                selection: ChatFeatureState.Selection.none,
                composer: nil,
                replacesComposer: true,
                activity: nil,
                notice: .chatMissing
            )
            publish()
        case .readOnlyLibrary:
            state = replacing(
                selection: ChatFeatureState.Selection.none,
                composer: nil,
                replacesComposer: true,
                activity: nil,
                notice: .readOnlyLibrary
            )
            publish()
        case .failed:
            state = replacing(
                selection: ChatFeatureState.Selection.none,
                composer: nil,
                replacesComposer: true,
                activity: nil,
                notice: .chatOpenFailed
            )
            publish()
        }
    }

    public func flushForOrderlyTermination() async -> Bool {
        while operationInFlight {
            await withCheckedContinuation { operationIdleWaiters.append($0) }
        }
        operationInFlight = true
        defer { finishOperation() }
        while true {
            await drainWork()
            guard let activeContext else { return true }
            guard await flushSelectedDraft(in: activeContext) else { return false }
            if queuedActions.isEmpty, pendingStart == nil { return true }
        }
    }

    private func refreshContextAdvisory(
        for aggregate: ChatAggregate,
        draft: ChatDraft,
        context: ChatCommandContext
    ) async {
        guard isActive(context),
              case let .open(selected) = state.selection,
              selected.chat.id == aggregate.chat.id,
              state.composer?.draft == draft
        else {
            return
        }
        guard draft.text.utf8.count <=
            CoachContextInputLimits.maximumUserMessageUTF8Bytes
        else {
            state = replacing(
                contextAdvisory: .messageTooLong(
                    maximumUTF8Bytes: CoachContextInputLimits.maximumUserMessageUTF8Bytes
                ),
                clearsRecoveryIntent: true,
                activity: state.activity,
                notice: state.notice
            )
            publish()
            return
        }
        state = replacing(
            contextAdvisory: .quoting,
            clearsRecoveryIntent: true,
            activity: state.activity,
            notice: state.notice
        )
        publish()
        let outcome = await coachContext.quoteChat(
            CoachContextChatQuoteRequest(
                library: context.libraryScope,
                chatID: aggregate.chat.id,
                draft: draft
            )
        )
        guard isActive(context),
              case let .open(current) = state.selection,
              current.chat.id == aggregate.chat.id,
              state.composer?.draft == draft
        else {
            return
        }
        let advisory: CoachContextAdvisoryState
        switch outcome {
        case let .available(quote):
            advisory = .available(quote)
        case let .unavailable(reason):
            advisory = .unavailable(reason)
        }
        state = replacing(
            contextAdvisory: advisory,
            activity: state.activity,
            notice: state.notice
        )
        publish()
    }

    private func resolveOpenedAttachments(
        for aggregate: ChatAggregate,
        context: ChatCommandContext
    ) async {
        guard isActive(context), case let .open(selected) = state.selection,
              selected.chat.id == aggregate.chat.id,
              selected.chat.attachments == aggregate.chat.attachments
        else { return }
        state = replacing(
            openedAttachments: .resolving(aggregate.chat.attachments),
            activity: state.activity,
            notice: state.notice
        )
        publish()
        let outcome = await coachContext.resolveAttachments(
            aggregate.chat.attachments,
            in: context.libraryScope
        )
        guard isCurrent(context), case let .open(current) = state.selection,
              current.chat.id == aggregate.chat.id,
              current.chat.attachments == aggregate.chat.attachments
        else { return }
        switch outcome {
        case let .resolved(resolved, _)
            where resolved.count == aggregate.chat.attachments.values.count &&
                zip(resolved, aggregate.chat.attachments.values).allSatisfy({ item, expected in
                    item.attachment == expected
                }):
            state = replacing(
                openedAttachments: .resolved(resolved),
                activity: state.activity,
                notice: state.notice
            )
        case .resolved, .configurationChanged, .readOnlyLibrary, .failed:
            state = replacing(
                openedAttachments: .failed,
                activity: state.activity,
                notice: state.notice
            )
        }
        publish()
    }

    private func refreshContextQuote(
        chatID: ChatID,
        expectedDraft: ChatDraft,
        context: ChatCommandContext
    ) async {
        guard isActive(context),
              case let .open(aggregate) = state.selection,
              aggregate.chat.id == chatID,
              state.composer?.draft == expectedDraft
        else {
            return
        }
        await refreshContextAdvisory(
            for: aggregate,
            draft: expectedDraft,
            context: context
        )
    }

    private func finishOperation() {
        operationInFlight = false
        let waiters = operationIdleWaiters
        operationIdleWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func editDraft(_ text: String, context: ChatCommandContext) async {
        guard activeContext == context,
              case let .open(aggregate) = state.selection,
              case let .editable(draft, _) = state.composer,
              aggregate.pendingUserTurn == nil
        else {
            return
        }
        let instant = await clock.now()
        guard activeContext == context,
              case let .open(current) = state.selection,
              current.chat.id == aggregate.chat.id,
              case let .editable(currentDraft, _) = state.composer,
              currentDraft == draft
        else {
            return
        }
        do {
            let edited = try draft.edited(text: text, at: instant)
            state = replacing(
                composer: .editable(edited, isDirty: true),
                replacesComposer: true,
                activity: nil,
                notice: nil
            )
            publish()
            scheduleAutosave(for: context, chatID: aggregate.chat.id)
            await refreshContextAdvisory(
                for: aggregate,
                draft: edited,
                context: context
            )
        } catch {
            state = replacing(activity: nil, notice: .invalidDraft)
            publish()
        }
    }

    private func sendDraft(
        context: ChatCommandContext,
        expectedChatID: ChatID,
        expectedDraft: ChatDraft
    ) async {
        guard isActive(context),
              case let .open(aggregate) = state.selection,
              aggregate.chat.id == expectedChatID,
              case let .editable(draft, _) = state.composer,
              draft == expectedDraft,
              aggregate.pendingUserTurn == nil,
              draft.text.unicodeScalars.contains(where: { !$0.properties.isWhitespace })
        else {
            state = replacing(activity: nil, notice: .invalidDraft)
            publish()
            return
        }
        state = replacing(activity: .lockingDraft(aggregate.chat.id), notice: nil)
        publish()
        guard await flushSelectedDraft(in: context), isActive(context),
              case let .open(flushed) = state.selection,
              case let .editable(flushedDraft, false) = state.composer,
              flushed.chat.id == expectedChatID,
              flushed.chat.draft == flushedDraft,
              flushed.pendingUserTurn == nil
        else {
            return
        }
        guard flushedDraft == expectedDraft else {
            state = replacing(activity: nil, notice: .draftChanged)
            publish()
            return
        }

        state = replacing(activity: .lockingDraft(flushed.chat.id), notice: nil)
        publish()
        let instant = await clock.now()
        guard isActive(context) else { return }
        let pendingID = await pendingUserTurnIDGenerator.generatePendingUserTurnID(at: instant)
        guard isActive(context) else { return }
        let responsePositionID = await responsePositionIDGenerator
            .generateChatResponsePositionID(at: instant)
        guard isActive(context) else { return }
        let pending = PendingUserTurn(
            id: pendingID,
            draftID: flushedDraft.draftID,
            draftVersion: flushedDraft.version,
            responsePositionID: responsePositionID
        )
        let request: CoachContextPendingTurnRequest
        do {
            request = try CoachContextPendingTurnRequest(
                library: context.libraryScope,
                chatID: flushed.chat.id,
                draft: flushedDraft,
                pendingUserTurn: pending
            )
        } catch {
            state = replacing(activity: nil, notice: .coachContextUnavailable)
            publish()
            return
        }
        let preparation = await coachContext.preparePendingUserTurn(request)
        guard isActive(context),
              case let .open(current) = state.selection,
              current.chat.id == flushed.chat.id,
              current.pendingUserTurn == nil,
              case let .editable(currentDraft, false) = state.composer,
              currentDraft == flushedDraft
        else {
            return
        }

        let pendingToInstall: PendingUserTurn
        switch preparation {
        case let .prepared(prepared):
            pendingToInstall = pending
            state = replacing(
                contextAdvisory: .available(prepared.quote),
                clearsRecoveryIntent: true,
                activity: .lockingDraft(flushed.chat.id),
                notice: nil
            )
        case let .cannotFit(failure):
            pendingToInstall = pending.replacingFailure(.coachContextCannotFit)
            state = replacing(
                contextAdvisory: .available(failure.quote),
                clearsRecoveryIntent: true,
                activity: .lockingDraft(flushed.chat.id),
                notice: nil
            )
        case let .messageTooLong(maximumUTF8Bytes):
            state = replacing(
                contextAdvisory: .messageTooLong(
                    maximumUTF8Bytes: maximumUTF8Bytes
                ),
                clearsRecoveryIntent: true,
                activity: nil,
                notice: .messageMustBeShortened
            )
            publish()
            return
        case let .unavailable(reason):
            state = replacing(
                contextAdvisory: .unavailable(reason),
                clearsRecoveryIntent: true,
                activity: nil,
                notice: .coachContextUnavailable
            )
            publish()
            return
        }
        publish()
        let outcome = await store.lockPendingUserTurn(
            LockPendingUserTurnMutation(
                library: context.libraryScope,
                chatID: flushed.chat.id,
                pendingUserTurn: pendingToInstall
            )
        )
        guard isActive(context) else { return }
        applyPendingMutationOutcome(
            outcome,
            expectedChatID: flushed.chat.id,
            expectedPending: pendingToInstall,
            operationFailure: .pendingUserTurnFailed
        )
    }

    private func discardPendingUserTurn(
        _ pendingUserTurnID: PendingUserTurnID,
        context: ChatCommandContext
    ) async {
        guard isActive(context),
              case let .open(aggregate) = state.selection,
              let pending = aggregate.pendingUserTurn,
              pending.id == pendingUserTurnID,
              case let .locked(draft, locked) = state.composer,
              locked == pending,
              draft == aggregate.chat.draft
        else {
            return
        }
        state = replacing(
            clearsRecoveryIntent: true,
            activity: .discardingPendingUserTurn(aggregate.chat.id),
            notice: nil
        )
        publish()
        let outcome = await store.discardPendingUserTurn(
            DiscardPendingUserTurnMutation(
                library: context.libraryScope,
                chatID: aggregate.chat.id,
                pendingUserTurn: pending
            )
        )
        guard isActive(context) else { return }
        applyPendingMutationOutcome(
            outcome,
            expectedChatID: aggregate.chat.id,
            expectedPending: nil,
            operationFailure: .pendingUserTurnFailed
        )
    }

    private func retryPendingUserTurn(
        _ pendingUserTurnID: PendingUserTurnID,
        context: ChatCommandContext
    ) async {
        guard isActive(context),
              case let .open(aggregate) = state.selection,
              let pending = aggregate.pendingUserTurn,
              pending.id == pendingUserTurnID,
              pending.failure == .coachContextCannotFit,
              case let .locked(draft, locked) = state.composer,
              locked == pending,
              draft == aggregate.chat.draft
        else {
            return
        }
        state = replacing(
            clearsRecoveryIntent: true,
            activity: .retryingPendingUserTurn(aggregate.chat.id),
            notice: nil
        )
        publish()
        let request: CoachContextPendingTurnRequest
        do {
            request = try CoachContextPendingTurnRequest(
                library: context.libraryScope,
                chatID: aggregate.chat.id,
                draft: draft,
                pendingUserTurn: pending
            )
        } catch {
            state = replacing(activity: nil, notice: .coachContextUnavailable)
            publish()
            return
        }
        let preparation = await coachContext.preparePendingUserTurn(request)
        guard isActive(context),
              case let .open(current) = state.selection,
              current.chat.id == aggregate.chat.id,
              current.pendingUserTurn == pending,
              case let .locked(currentDraft, currentPending) = state.composer,
              currentDraft == draft,
              currentPending == pending
        else {
            return
        }
        switch preparation {
        case let .prepared(prepared):
            let replacement = pending.replacingFailure(nil)
            state = replacing(
                contextAdvisory: .available(prepared.quote),
                activity: .retryingPendingUserTurn(aggregate.chat.id),
                notice: nil
            )
            publish()
            let mutation: ReplacePendingUserTurnMutation
            do {
                mutation = try ReplacePendingUserTurnMutation(
                    library: context.libraryScope,
                    chatID: aggregate.chat.id,
                    base: pending,
                    replacement: replacement
                )
            } catch {
                state = replacing(activity: nil, notice: .pendingUserTurnFailed)
                publish()
                return
            }
            let outcome = await store.replacePendingUserTurn(
                mutation
            )
            guard isActive(context) else { return }
            applyPendingMutationOutcome(
                outcome,
                expectedChatID: aggregate.chat.id,
                expectedPending: replacement,
                operationFailure: .pendingUserTurnFailed
            )
        case let .cannotFit(failure):
            state = replacing(
                contextAdvisory: .available(failure.quote),
                activity: nil,
                notice: nil
            )
            publish()
        case let .messageTooLong(maximumUTF8Bytes):
            state = replacing(
                contextAdvisory: .messageTooLong(
                    maximumUTF8Bytes: maximumUTF8Bytes
                ),
                activity: nil,
                notice: .messageMustBeShortened
            )
            publish()
        case let .unavailable(reason):
            state = replacing(
                contextAdvisory: .unavailable(reason),
                activity: nil,
                notice: .coachContextUnavailable
            )
            publish()
        }
    }

    private func createNewChatFromCapacityFailure(
        _ pendingUserTurnID: PendingUserTurnID,
        context: ChatCommandContext
    ) {
        guard isActive(context),
              case let .open(aggregate) = state.selection,
              let pending = aggregate.pendingUserTurn,
              pending.id == pendingUserTurnID,
              pending.failure == .coachContextCannotFit,
              case let .locked(draft, locked) = state.composer,
              locked == pending,
              draft == aggregate.chat.draft,
              let intent = try? CoachContextCreateNewChatRecoveryIntent(
                  chat: aggregate.chat,
                  pendingUserTurn: pending
              )
        else {
            return
        }
        state = replacing(
            recoveryIntent: intent,
            activity: nil,
            notice: nil
        )
        publish()
    }

    private func scheduleAutosave(for context: ChatCommandContext, chatID: ChatID) {
        guard !suppressAutosaveScheduling,
              autosaveTimer == nil,
              autosaveDueAfterWrite == nil
        else {
            return
        }
        nextAutosaveID &+= 1
        let id = nextAutosaveID
        let scheduler = autosaveScheduler
        let task = Task { [weak self] in
            do {
                try await scheduler.sleep(
                    forNanoseconds: Self.draftAutosaveIntervalNanoseconds
                )
                guard !Task.isCancelled else {
                    await self?.finishAutosaveTimer(id: id)
                    return
                }
                await self?.autosaveDeadlineReached(
                    id: id,
                    request: ScheduledAutosave(context: context, chatID: chatID)
                )
            } catch {
                await self?.finishAutosaveTimer(id: id)
            }
        }
        autosaveTimer = (id, task)
    }

    private func autosaveDeadlineReached(
        id: UInt64,
        request: ScheduledAutosave
    ) {
        guard autosaveTimer?.id == id else { return }
        autosaveTimer = nil
        guard !suppressAutosaveScheduling,
              isCurrent(request.context),
              case let .open(aggregate) = state.selection,
              aggregate.chat.id == request.chatID,
              case .editable(_, true) = state.composer
        else {
            return
        }
        guard autosaveWrite == nil else {
            autosaveDueAfterWrite = request
            return
        }
        startAutosaveWrite(request)
    }

    private func startAutosaveWrite(_ request: ScheduledAutosave) {
        guard !suppressAutosaveScheduling, autosaveWrite == nil else { return }
        nextAutosaveID &+= 1
        let id = nextAutosaveID
        let task = Task<DraftSaveDisposition, Never> { [weak self] in
            guard let self else { return .notAttempted }
            return await self.performAutosaveWrite(id: id, request: request)
        }
        autosaveWrite = (id, task)
    }

    private func performAutosaveWrite(
        id: UInt64,
        request: ScheduledAutosave
    ) async -> DraftSaveDisposition {
        guard autosaveWrite?.id == id,
              isCurrent(request.context),
              case let .open(aggregate) = state.selection,
              aggregate.chat.id == request.chatID,
              case let .editable(draft, true) = state.composer
        else {
            finishAutosaveWrite(id: id, shouldReschedule: false)
            return .notAttempted
        }
        let outcome = await store.saveDraft(
            SaveChatDraftMutation(
                library: request.context.libraryScope,
                chatID: request.chatID,
                replacement: draft
            )
        )
        let wasCancelled = Task.isCancelled
        let disposition: DraftSaveDisposition
        if activeContext == request.context {
            disposition = reconcileDraftSave(
                outcome,
                expectedChatID: request.chatID,
                expectedDraft: draft,
                failureNotice: .draftSaveFailed,
                preserveActivityForRetry: wasCancelled
            )
        } else {
            disposition = .notAttempted
        }
        finishAutosaveWrite(id: id, shouldReschedule: !wasCancelled)
        return disposition
    }

    private func finishAutosaveTimer(id: UInt64) {
        guard autosaveTimer?.id == id else { return }
        autosaveTimer = nil
    }

    private func finishAutosaveWrite(id: UInt64, shouldReschedule: Bool) {
        guard autosaveWrite?.id == id else { return }
        autosaveWrite = nil
        guard !suppressAutosaveScheduling else {
            autosaveDueAfterWrite = nil
            return
        }
        if let due = autosaveDueAfterWrite {
            autosaveDueAfterWrite = nil
            startAutosaveWrite(due)
            return
        }
        guard shouldReschedule,
              let activeContext,
              requestedContext == activeContext,
              case let .open(aggregate) = state.selection,
              case .editable(_, true) = state.composer
        else {
            return
        }
        scheduleAutosave(for: activeContext, chatID: aggregate.chat.id)
    }

    private func quiesceAutosave() async -> DraftSaveDisposition {
        suppressAutosaveScheduling = true
        autosaveDueAfterWrite = nil
        var disposition = DraftSaveDisposition.notAttempted
        while let active = autosaveTimer {
            active.task.cancel()
            await active.task.value
            if autosaveTimer?.id == active.id {
                autosaveTimer = nil
            }
        }
        while let active = autosaveWrite {
            active.task.cancel()
            let completed = await active.task.value
            if completed != .notAttempted {
                disposition = completed
            }
            if autosaveWrite?.id == active.id {
                autosaveWrite = nil
            }
        }
        suppressAutosaveScheduling = false
        return disposition
    }

    private func flushSelectedDraft(in context: ChatCommandContext) async -> Bool {
        let quiesced = await quiesceAutosave()
        guard activeContext == context else { return false }
        guard quiesced != .terminal else { return false }
        guard case let .open(aggregate) = state.selection,
              case let .editable(draft, isDirty) = state.composer
        else {
            return quiesced != .retryable
        }
        guard isDirty else { return quiesced != .retryable }
        let outcome = await store.saveDraft(
            SaveChatDraftMutation(
                library: context.libraryScope,
                chatID: aggregate.chat.id,
                replacement: draft
            )
        )
        guard activeContext == context else { return false }
        let disposition = reconcileDraftSave(
            outcome,
            expectedChatID: aggregate.chat.id,
            expectedDraft: draft,
            failureNotice: .draftSaveFailed
        )
        if disposition == .retryable,
           requestedContext == activeContext,
           case .editable(_, true) = state.composer
        {
            scheduleAutosave(for: context, chatID: aggregate.chat.id)
        }
        return disposition == .durable
    }

    @discardableResult
    private func reconcileDraftSave(
        _ outcome: ChatMutationOutcome,
        expectedChatID: ChatID,
        expectedDraft: ChatDraft,
        failureNotice: ChatNotice,
        preserveActivityForRetry: Bool = false
    ) -> DraftSaveDisposition {
        let preservedActivity = state.activity
        let retryActivity = preserveActivityForRetry ? preservedActivity : nil
        switch outcome {
        case let .committed(current), let .stale(current):
            guard current.chat.id == expectedChatID,
                  current.chat.draft.draftID == expectedDraft.draftID
            else {
                state = replacing(activity: retryActivity, notice: failureNotice)
                publish()
                return .retryable
            }
            let notice: ChatNotice? = {
                if case .stale = outcome { return .draftChanged }
                return nil
            }()
            if current.pendingUserTurn != nil {
                install(
                    current,
                    selection: .open(current),
                    notice: .draftChanged
                )
                return .terminal
            }
            if case let .editable(local, _) = state.composer,
               local.draftID == current.chat.draft.draftID,
               local.version > current.chat.draft.version
            {
                install(
                    current,
                    selection: .open(current),
                    notice: notice,
                    composer: .editable(local, isDirty: true),
                    activity: retryActivity
                )
                return .retryable
            }
            let isExpectedDraft = current.chat.draft == expectedDraft
            install(
                current,
                selection: .open(current),
                notice: notice,
                activity: isExpectedDraft ? preservedActivity : nil
            )
            return isExpectedDraft ? .durable : .terminal
        case let .frozen(frozen):
            install(frozen, selection: .frozen(frozen), notice: .chatFrozen)
            return .terminal
        case .readOnlyLibrary:
            state = replacing(activity: retryActivity, notice: .readOnlyLibrary)
            publish()
        case .collision, .profileStatementGenerationChanged, .failed:
            state = replacing(activity: retryActivity, notice: failureNotice)
            publish()
        }
        return .retryable
    }

    private func applyPendingMutationOutcome(
        _ outcome: ChatMutationOutcome,
        expectedChatID: ChatID,
        expectedPending: PendingUserTurn?,
        operationFailure: ChatNotice
    ) {
        switch outcome {
        case let .committed(current):
            guard current.chat.id == expectedChatID,
                  current.pendingUserTurn == expectedPending
            else {
                state = replacing(activity: nil, notice: operationFailure)
                publish()
                return
            }
            install(current, selection: .open(current), notice: nil)
        case let .stale(current):
            install(current, selection: .open(current), notice: .draftChanged)
        case let .frozen(frozen):
            install(frozen, selection: .frozen(frozen), notice: .chatFrozen)
        case .readOnlyLibrary:
            state = replacing(activity: nil, notice: .readOnlyLibrary)
            publish()
        case .collision, .profileStatementGenerationChanged, .failed:
            state = replacing(activity: nil, notice: operationFailure)
            publish()
        }
    }

    private func composer(for aggregate: ChatAggregate) -> ChatComposerState {
        if let pending = aggregate.pendingUserTurn {
            return .locked(aggregate.chat.draft, pending)
        }
        return .editable(aggregate.chat.draft, isDirty: false)
    }

    private func isCurrent(_ context: ChatCommandContext) -> Bool {
        activeContext == context && requestedContext == context
    }

    private func isActive(_ context: ChatCommandContext) -> Bool {
        activeContext == context
    }

    private func install(
        _ aggregate: ChatAggregate,
        selection: ChatFeatureState.Selection,
        notice: ChatNotice?,
        composer override: ChatComposerState? = nil,
        activity: ChatFeatureState.Activity? = nil
    ) {
        var rows = currentAllRows.filter { $0.chatID != aggregate.chat.id }
        rows.append(ChatRowSnapshot(aggregate: aggregate))
        let installedComposer: ChatComposerState?
        if case let .open(selected) = selection, selected.chat.id == aggregate.chat.id {
            installedComposer = override ?? composer(for: aggregate)
        } else {
            installedComposer = state.composer
        }
        finishInstall(
            rows: rows,
            selection: selection,
            composer: installedComposer,
            activity: activity,
            notice: notice
        )
    }

    private func install(
        _ frozen: FrozenChatSnapshot,
        selection: ChatFeatureState.Selection,
        notice: ChatNotice?
    ) {
        var rows = currentAllRows.filter { $0.chatID != frozen.chatID }
        rows.append(ChatRowSnapshot(frozen: frozen))
        let composer: ChatComposerState?
        if case let .frozen(selected) = selection, selected.chatID == frozen.chatID {
            composer = nil
        } else {
            composer = state.composer
        }
        finishInstall(
            rows: rows,
            selection: selection,
            composer: composer,
            activity: nil,
            notice: notice
        )
    }

    private func finishInstall(
        rows: [ChatRowSnapshot],
        selection: ChatFeatureState.Selection,
        composer: ChatComposerState?,
        activity: ChatFeatureState.Activity?,
        notice: ChatNotice?
    ) {
        let sorted = sortedRows(rows)
        let preservesSelectedChat: Bool = {
            guard case let .open(previous) = state.selection,
                  case let .open(next) = selection
            else {
                return false
            }
            return previous.chat.id == next.chat.id
        }()
        state = ChatFeatureState(
            catalog: .ready(
                ChatCatalogSnapshot(
                    allRows: sorted,
                    visibleRows: filtered(sorted, by: state.filterQuery)
                )
            ),
            filterQuery: state.filterQuery,
            selection: selection,
            composer: composer,
            contextAdvisory: preservesSelectedChat
                ? state.contextAdvisory
                : .notRequested,
            createNewChatRecoveryIntent: preservesSelectedChat
                ? state.createNewChatRecoveryIntent
                : nil,
            newChatPicker: state.newChatPicker,
            openedAttachments: preservesSelectedChat
                ? state.openedAttachments
                : .notRequested,
            activity: activity,
            notice: notice
        )
        publish()
    }

    private var currentAllRows: [ChatRowSnapshot] {
        guard case let .ready(catalog) = state.catalog else { return [] }
        return catalog.allRows
    }

    private func readyCatalog(
        from entries: [ChatCatalogEntry],
        query: ChatFilterQuery
    ) -> ChatFeatureState.Catalog {
        let rows = sortedRows(entries.map { entry in
            switch entry {
            case let .available(aggregate): ChatRowSnapshot(aggregate: aggregate)
            case let .frozen(frozen): ChatRowSnapshot(frozen: frozen)
            }
        })
        return .ready(
            ChatCatalogSnapshot(
                allRows: rows,
                visibleRows: filtered(rows, by: query)
            )
        )
    }

    private func sortedRows(_ rows: [ChatRowSnapshot]) -> [ChatRowSnapshot] {
        rows.sorted { lhs, rhs in
            switch (lhs.updatedAt, rhs.updatedAt) {
            case let (.some(left), .some(right)) where left != right:
                return left.rawValue > right.rawValue
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.chatID.rawValue < rhs.chatID.rawValue
            }
        }
    }

    private func filtered(
        _ rows: [ChatRowSnapshot],
        by query: ChatFilterQuery
    ) -> [ChatRowSnapshot] {
        let needle = folded(query.rawValue)
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in
            guard let title = row.title else { return false }
            return folded(title.rawValue).contains(needle)
        }
    }

    private func filtered(
        _ rows: [ChatAttachmentPickerRow],
        by query: ChatAttachmentFilterQuery
    ) -> [ChatAttachmentPickerRow] {
        let needle = folded(query.rawValue)
        guard !needle.isEmpty else { return rows }
        return rows.filter { folded($0.displayLabel).contains(needle) }
    }

    private func folded(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func selectionReplacing(
        _ chatID: ChatID,
        with replacement: ChatFeatureState.Selection
    ) -> ChatFeatureState.Selection {
        switch state.selection {
        case let .open(aggregate) where aggregate.chat.id == chatID:
            replacement
        case let .frozen(frozen) where frozen.chatID == chatID:
            replacement
        case let .opening(openingID) where openingID == chatID:
            replacement
        default:
            state.selection
        }
    }

    private func replacing(
        selection: ChatFeatureState.Selection? = nil,
        composer: ChatComposerState? = nil,
        replacesComposer: Bool = false,
        contextAdvisory: CoachContextAdvisoryState? = nil,
        recoveryIntent: CoachContextCreateNewChatRecoveryIntent? = nil,
        clearsRecoveryIntent: Bool = false,
        newChatPicker: NewChatAttachmentPickerState? = nil,
        openedAttachments: OpenedChatAttachmentsState? = nil,
        activity: ChatFeatureState.Activity?,
        notice: ChatNotice?
    ) -> ChatFeatureState {
        ChatFeatureState(
            catalog: state.catalog,
            filterQuery: state.filterQuery,
            selection: selection ?? state.selection,
            composer: replacesComposer ? composer : state.composer,
            contextAdvisory: contextAdvisory ?? state.contextAdvisory,
            createNewChatRecoveryIntent: clearsRecoveryIntent
                ? nil
                : recoveryIntent ?? state.createNewChatRecoveryIntent,
            newChatPicker: newChatPicker ?? state.newChatPicker,
            openedAttachments: openedAttachments ?? state.openedAttachments,
            activity: activity,
            notice: notice
        )
    }

    private func addSubscriber(
        _ continuation: AsyncStream<ChatFeatureState>.Continuation
    ) {
        let id = nextSubscriberID
        nextSubscriberID += 1
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        continuations[id] = continuation
        continuation.yield(state)
    }

    private func removeSubscriber(_ id: Int) {
        continuations.removeValue(forKey: id)
    }

    private func publish() {
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }
}

private extension ChatCommand {
    var context: ChatCommandContext {
        switch self {
        case let .start(context), let .beginNewChat(context),
             let .cancelNewChat(context),
             let .confirmNewChat(context):
            context
        case let .setNewChatAttachmentFilter(context, _),
             let .toggleNewChatAttachment(context, _),
             let .rename(context, _, _, _), let .setFilter(context, _),
             let .open(context, _), let .editDraft(context, _, _, _),
             let .refreshContextQuote(context, _, _),
             let .sendDraft(context, _, _),
             let .retryPendingUserTurn(context, _),
             let .createNewChatFromCapacityFailure(context, _),
             let .discardPendingUserTurn(context, _):
            context
        }
    }
}

private func contextForImmediateCommand(
    _ command: ChatCommand
) -> ChatCommandContext? {
    switch command {
    case let .setFilter(context, _),
         let .setNewChatAttachmentFilter(context, _):
        context
    default:
        nil
    }
}
