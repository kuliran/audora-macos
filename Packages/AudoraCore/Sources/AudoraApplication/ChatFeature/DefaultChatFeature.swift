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
    private let coachContext: any CoachContextCoordinating
    private let invocations: any Invocations

    private var activeContext: ChatCommandContext?
    private var requestedContext: ChatCommandContext?
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
        autosaveScheduler: any ChatAutosaveScheduling = SystemChatAutosaveScheduler(),
        invocations: any Invocations
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
        self.invocations = invocations
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
        coachContext: any CoachContextCoordinating,
        invocations: any Invocations
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
        self.invocations = invocations
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
        if case let .setFilter(context, query) = command,
           context == requestedContext {
            setFilter(query)
            return
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
        case let .createDevelopmentChat(context):
            await createDevelopmentChat(context: context)
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
        case .start, .setFilter, .editDraft, .sendDraft:
            break
        }
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
                selection: .none
            )
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
                selection: .none
            )
        case .readOnlyLibrary:
            let query = state.filterQuery
            state = ChatFeatureState(
                catalog: .failed,
                filterQuery: query,
                selection: .none,
                notice: .readOnlyLibrary
            )
        case .failed:
            let query = state.filterQuery
            state = ChatFeatureState(
                catalog: .failed,
                filterQuery: query,
                selection: .none,
                notice: .catalogFailed
            )
        }
        publish()
    }

    private func createDevelopmentChat(context: ChatCommandContext) async {
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
                    profileStatementGeneration: statementGeneration
                )
            } catch {
                state = replacing(activity: nil, notice: .createFailed)
                publish()
                return
            }

            let outcome = await store.create(seed)
            guard isActive(context) else { return }
            switch outcome {
            case let .committed(committed):
                install(committed, selection: .open(committed), notice: nil)
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
            activity: nil,
            notice: nil
        )
        publish()
        let outcome = await store.load(chatID, in: library)
        guard isActive(context) else { return }
        switch outcome {
        case let .loaded(aggregate):
            install(aggregate, selection: .open(aggregate), notice: nil)
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
        guard flushedDraft.text.utf8.count <=
            CoachContextInputLimits.maximumUserMessageUTF8Bytes
        else {
            state = replacing(
                contextAdvisory: .messageTooLong(
                    maximumUTF8Bytes: CoachContextInputLimits.maximumUserMessageUTF8Bytes
                ),
                clearsRecoveryIntent: true,
                activity: nil,
                notice: .messageMustBeShortened
            )
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
        await lockAndInvoke(
            pending,
            aggregate: flushed,
            gateway: invocations,
            context: context
        )
    }

    private func lockAndInvoke(
        _ pending: PendingUserTurn,
        aggregate: ChatAggregate,
        gateway: any Invocations,
        context: ChatCommandContext
    ) async {
        let lockOutcome = await store.lockPendingUserTurn(
            LockPendingUserTurnMutation(
                library: context.libraryScope,
                chatID: aggregate.chat.id,
                pendingUserTurn: pending
            )
        )
        guard isActive(context) else { return }
        let locked: ChatAggregate
        switch lockOutcome {
        case let .committed(current)
            where current.chat.id == aggregate.chat.id &&
            current.pendingUserTurn == pending:
            locked = current
            install(
                current,
                selection: .open(current),
                notice: nil,
                activity: .invokingCoach(current.chat.id)
            )
        case let .stale(current):
            install(current, selection: .open(current), notice: .draftChanged)
            return
        case let .frozen(frozen):
            install(frozen, selection: .frozen(frozen), notice: .chatFrozen)
            return
        case .readOnlyLibrary:
            state = replacing(activity: nil, notice: .readOnlyLibrary)
            publish()
            return
        case .collision, .profileStatementGenerationChanged, .failed, .committed:
            state = replacing(activity: nil, notice: .pendingUserTurnFailed)
            publish()
            return
        }

        let outcome = await gateway.tryInvoke(
            PendingCoachInvocationRequest(
                library: context.libraryScope,
                chatID: locked.chat.id,
                pendingUserTurnID: pending.id
            )
        )
        guard isActive(context) else { return }
        switch outcome {
        case let .published(current, quote):
            state = replacing(
                contextAdvisory: .available(quote),
                clearsRecoveryIntent: true,
                activity: nil,
                notice: nil
            )
            install(current, selection: .open(current), notice: nil)
        case let .contextCapacityFailure(current, quote):
            state = replacing(
                contextAdvisory: .available(quote),
                clearsRecoveryIntent: true,
                activity: nil,
                notice: nil
            )
            install(current, selection: .open(current), notice: nil)
        case let .rejected(current, reason):
            let notice = notice(for: reason)
            if case let .messageMustBeShortened(maximumUTF8Bytes) = reason {
                state = replacing(
                    contextAdvisory: .messageTooLong(
                        maximumUTF8Bytes: maximumUTF8Bytes
                    ),
                    clearsRecoveryIntent: true,
                    activity: nil,
                    notice: notice
                )
            } else if case let .contextUnavailable(reason) = reason {
                state = replacing(
                    contextAdvisory: .unavailable(reason),
                    clearsRecoveryIntent: true,
                    activity: nil,
                    notice: notice
                )
            }
            if let current {
                install(current, selection: .open(current), notice: notice)
            } else {
                state = replacing(activity: nil, notice: .coachResponseInterrupted)
                publish()
            }
        case let .interrupted(current, _):
            if let current {
                install(
                    current,
                    selection: .open(current),
                    notice: .coachResponseInterrupted
                )
            } else {
                state = replacing(activity: nil, notice: .coachResponseInterrupted)
                publish()
            }
        }
    }

    private func notice(for rejection: InvocationRejectionReason) -> ChatNotice {
        switch rejection {
        case .activeInvocation:
            .coachBusy
        case .admissionCooldown, .clockRollback, .admissionLedgerFull:
            .coachAdmissionLimited
        case .messageMustBeShortened:
            .messageMustBeShortened
        case .contextUnavailable:
            .coachContextUnavailable
        case .eligibilityChanged, .contextChanged, .admissionUnavailable,
             .persistenceUnavailable:
            .coachSendUnavailable
        }
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
        case let .start(context), let .createDevelopmentChat(context):
            context
        case let .rename(context, _, _, _), let .setFilter(context, _),
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
