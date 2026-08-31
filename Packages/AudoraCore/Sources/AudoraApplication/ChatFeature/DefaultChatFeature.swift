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
        draftID: ChatDraftID
    )
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

    private var activeContext: ChatCommandContext?
    private var requestedContext: ChatCommandContext?
    private var state = ChatFeatureState()
    private var operationInFlight = false
    private var operationIdleWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingStart: ChatCommandContext?
    private var queuedActions: [QueuedChatAction] = []
    private var autosaveTask: (id: UInt64, task: Task<Void, Never>)?
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
        case let .editDraft(context, text):
            guard case let .open(aggregate) = state.selection,
                  case let .editable(draft, _) = state.composer,
                  aggregate.pendingUserTurn == nil,
                  aggregate.chat.draft.draftID == draft.draftID
            else {
                return
            }
            queuedActions.append(
                .draftEdit(
                    context: context,
                    text: text,
                    chatID: aggregate.chat.id,
                    draftID: draft.draftID
                )
            )
        case let .sendDraft(context):
            guard case let .open(aggregate) = state.selection,
                  case let .editable(draft, _) = state.composer,
                  aggregate.pendingUserTurn == nil,
                  aggregate.chat.draft.draftID == draft.draftID
            else {
                return
            }
            queuedActions.append(
                .sendDraft(
                    context: context,
                    chatID: aggregate.chat.id,
                    draftID: draft.draftID
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
            case let .sendDraft(context, chatID, draftID):
                guard activeContext == context else { continue }
                await sendDraft(
                    context: context,
                    expectedChatID: chatID,
                    expectedDraftID: draftID
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
        guard base.chat.manifestRevision == expectedRevision else {
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
        } catch {
            state = replacing(activity: nil, notice: .invalidDraft)
            publish()
        }
    }

    private func sendDraft(
        context: ChatCommandContext,
        expectedChatID: ChatID,
        expectedDraftID: ChatDraftID
    ) async {
        guard isActive(context),
              case let .open(aggregate) = state.selection,
              aggregate.chat.id == expectedChatID,
              case let .editable(draft, _) = state.composer,
              draft.draftID == expectedDraftID,
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
              flushedDraft.draftID == expectedDraftID,
              flushed.chat.draft == flushedDraft,
              flushed.pendingUserTurn == nil
        else {
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
        let outcome = await store.lockPendingUserTurn(
            LockPendingUserTurnMutation(
                library: context.libraryScope,
                chatID: flushed.chat.id,
                pendingUserTurn: pending
            )
        )
        guard isActive(context) else { return }
        applyPendingMutationOutcome(
            outcome,
            expectedChatID: flushed.chat.id,
            expectedPending: pending,
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

    private func scheduleAutosave(for context: ChatCommandContext, chatID: ChatID) {
        guard !suppressAutosaveScheduling, autosaveTask == nil else { return }
        nextAutosaveID &+= 1
        let id = nextAutosaveID
        let scheduler = autosaveScheduler
        let task = Task { [weak self] in
            do {
                try await scheduler.sleep(
                    forNanoseconds: Self.draftAutosaveIntervalNanoseconds
                )
                guard !Task.isCancelled else {
                    await self?.finishAutosave(id: id, shouldReschedule: false)
                    return
                }
                await self?.autosaveDue(id: id, context: context, chatID: chatID)
            } catch {
                await self?.finishAutosave(id: id, shouldReschedule: false)
            }
        }
        autosaveTask = (id, task)
    }

    private func autosaveDue(
        id: UInt64,
        context: ChatCommandContext,
        chatID: ChatID
    ) async {
        guard autosaveTask?.id == id,
              isCurrent(context),
              case let .open(aggregate) = state.selection,
              aggregate.chat.id == chatID,
              case let .editable(draft, true) = state.composer
        else {
            finishAutosave(id: id, shouldReschedule: false)
            return
        }
        let outcome = await store.saveDraft(
            SaveChatDraftMutation(
                library: context.libraryScope,
                chatID: chatID,
                replacement: draft
            )
        )
        let wasCancelled = Task.isCancelled
        if activeContext == context {
            _ = reconcileDraftSave(
                outcome,
                expectedChatID: chatID,
                expectedDraft: draft,
                failureNotice: .draftSaveFailed
            )
        }
        finishAutosave(id: id, shouldReschedule: !wasCancelled)
    }

    private func finishAutosave(id: UInt64, shouldReschedule: Bool) {
        guard autosaveTask?.id == id else { return }
        autosaveTask = nil
        guard shouldReschedule, !suppressAutosaveScheduling,
              let activeContext,
              requestedContext == activeContext,
              case let .open(aggregate) = state.selection,
              case .editable(_, true) = state.composer
        else {
            return
        }
        scheduleAutosave(for: activeContext, chatID: aggregate.chat.id)
    }

    private func quiesceAutosave() async {
        suppressAutosaveScheduling = true
        while let active = autosaveTask {
            active.task.cancel()
            await active.task.value
            if autosaveTask?.id == active.id {
                autosaveTask = nil
            }
        }
        suppressAutosaveScheduling = false
    }

    private func flushSelectedDraft(in context: ChatCommandContext) async -> Bool {
        await quiesceAutosave()
        guard activeContext == context else { return false }
        guard case let .open(aggregate) = state.selection,
              case let .editable(draft, isDirty) = state.composer
        else {
            return true
        }
        guard isDirty else { return true }
        let outcome = await store.saveDraft(
            SaveChatDraftMutation(
                library: context.libraryScope,
                chatID: aggregate.chat.id,
                replacement: draft
            )
        )
        guard activeContext == context else { return false }
        let committed = reconcileDraftSave(
            outcome,
            expectedChatID: aggregate.chat.id,
            expectedDraft: draft,
            failureNotice: .draftSaveFailed
        )
        if !committed,
           requestedContext == activeContext,
           case .editable(_, true) = state.composer
        {
            scheduleAutosave(for: context, chatID: aggregate.chat.id)
        }
        return committed
    }

    @discardableResult
    private func reconcileDraftSave(
        _ outcome: ChatMutationOutcome,
        expectedChatID: ChatID,
        expectedDraft: ChatDraft,
        failureNotice: ChatNotice
    ) -> Bool {
        switch outcome {
        case let .committed(current), let .stale(current):
            guard current.chat.id == expectedChatID,
                  current.chat.draft.draftID == expectedDraft.draftID
            else {
                state = replacing(activity: nil, notice: failureNotice)
                publish()
                return false
            }
            let notice: ChatNotice? = {
                if case .stale = outcome { return .draftChanged }
                return nil
            }()
            if current.pendingUserTurn != nil {
                install(current, selection: .open(current), notice: .draftChanged)
                return false
            }
            if case let .editable(local, _) = state.composer,
               local.draftID == current.chat.draft.draftID,
               local.version > current.chat.draft.version
            {
                install(
                    current,
                    selection: .open(current),
                    notice: notice,
                    composer: .editable(local, isDirty: true)
                )
                return false
            }
            install(current, selection: .open(current), notice: notice)
            return current.chat.draft == expectedDraft
        case let .frozen(frozen):
            install(frozen, selection: .frozen(frozen), notice: .chatFrozen)
        case .readOnlyLibrary:
            state = replacing(activity: nil, notice: .readOnlyLibrary)
            publish()
        case .collision, .profileStatementGenerationChanged, .failed:
            state = replacing(activity: nil, notice: failureNotice)
            publish()
        }
        return false
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
        composer override: ChatComposerState? = nil
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
        finishInstall(rows: rows, selection: selection, composer: composer, notice: notice)
    }

    private func finishInstall(
        rows: [ChatRowSnapshot],
        selection: ChatFeatureState.Selection,
        composer: ChatComposerState?,
        notice: ChatNotice?
    ) {
        let sorted = sortedRows(rows)
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
        activity: ChatFeatureState.Activity?,
        notice: ChatNotice?
    ) -> ChatFeatureState {
        ChatFeatureState(
            catalog: state.catalog,
            filterQuery: state.filterQuery,
            selection: selection ?? state.selection,
            composer: replacesComposer ? composer : state.composer,
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
             let .open(context, _), let .editDraft(context, _),
             let .sendDraft(context), let .discardPendingUserTurn(context, _):
            context
        }
    }
}
