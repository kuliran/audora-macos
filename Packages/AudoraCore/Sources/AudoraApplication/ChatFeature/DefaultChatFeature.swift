import AudoraDomain
import Foundation

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public actor DefaultChatFeature: ChatFeature {
    private static let maximumCollisionAttempts = 3
    private static let maximumProfileRebases = 3

    private let store: any ChatStorePort
    private let profileReader: any ProfileStatementGenerationReading
    private let clock: any ChatClock
    private let chatIDGenerator: any ChatIDGenerator
    private let draftIDGenerator: any ChatDraftIDGenerator
    private let memoryIDGenerator: any CoachMemoryIDGenerator

    private var activeContext: ChatCommandContext?
    private var state = ChatFeatureState()
    private var operationInFlight = false
    private var pendingStart: ChatCommandContext?
    private var continuations: [Int: AsyncStream<ChatFeatureState>.Continuation] = [:]
    private var nextSubscriberID = 0

    public init(
        store: any ChatStorePort,
        profileReader: any ProfileStatementGenerationReading,
        clock: any ChatClock,
        chatIDGenerator: any ChatIDGenerator,
        draftIDGenerator: any ChatDraftIDGenerator,
        memoryIDGenerator: any CoachMemoryIDGenerator
    ) {
        self.store = store
        self.profileReader = profileReader
        self.clock = clock
        self.chatIDGenerator = chatIDGenerator
        self.draftIDGenerator = draftIDGenerator
        self.memoryIDGenerator = memoryIDGenerator
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
            if let activeContext,
               context.generation <= activeContext.generation {
                return
            }
            activeContext = context
            pendingStart = context
            state = ChatFeatureState(
                catalog: .loading,
                filterQuery: .empty,
                selection: .none
            )
            publish()
            guard !operationInFlight else { return }
            operationInFlight = true
            defer { operationInFlight = false }
            await drainPendingStarts()
            return
        }
        guard command.context == activeContext else { return }
        if case let .setFilter(_, query) = command {
            setFilter(query)
            return
        }
        guard !operationInFlight else { return }
        operationInFlight = true
        defer { operationInFlight = false }

        switch command {
        case .start:
            break
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
        case .setFilter:
            break
        }
        await drainPendingStarts()
    }

    private func drainPendingStarts() async {
        while let context = pendingStart {
            pendingStart = nil
            guard context == activeContext else { continue }
            await start(in: context)
        }
    }

    private func start(in context: ChatCommandContext) async {
        let outcome = await store.loadCatalog(in: context.libraryScope)
        guard context == activeContext else { return }
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
        guard context == activeContext, case .ready = state.catalog else { return }
        let library = context.libraryScope
        state = replacing(activity: .creating, notice: nil)
        publish()

        let observedStatementGeneration = await profileReader.statementGeneration(in: library)
        guard context == activeContext else { return }
        guard var statementGeneration = observedStatementGeneration else {
            state = replacing(activity: nil, notice: .createFailed)
            publish()
            return
        }
        let instant = await clock.now()
        guard context == activeContext else { return }

        var collisionAttempts = 0
        var profileRebases = 0
        while true {
            let chatID = await chatIDGenerator.generateChatID(at: instant)
            guard context == activeContext else { return }
            let draftID = await draftIDGenerator.generateChatDraftID(at: instant)
            guard context == activeContext else { return }
            let memoryID = await memoryIDGenerator.generateCoachMemoryID(at: instant)
            guard context == activeContext else { return }
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
            guard context == activeContext else { return }
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
        guard context == activeContext, case .ready = state.catalog else { return }
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
            guard context == activeContext else { return }
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
        guard context == activeContext else { return }
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
        guard context == activeContext else { return }
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
            activity: state.activity,
            notice: nil
        )
        publish()
    }

    private func open(_ chatID: ChatID, context: ChatCommandContext) async {
        guard context == activeContext, case .ready = state.catalog else { return }
        let library = context.libraryScope
        state = replacing(selection: .opening(chatID), activity: nil, notice: nil)
        publish()
        let outcome = await store.load(chatID, in: library)
        guard context == activeContext else { return }
        switch outcome {
        case let .loaded(aggregate):
            install(aggregate, selection: .open(aggregate), notice: nil)
        case let .frozen(frozen):
            install(frozen, selection: .frozen(frozen), notice: .chatFrozen)
        case .missing:
            state = replacing(
                selection: ChatFeatureState.Selection.none,
                activity: nil,
                notice: .chatMissing
            )
            publish()
        case .readOnlyLibrary:
            state = replacing(
                selection: ChatFeatureState.Selection.none,
                activity: nil,
                notice: .readOnlyLibrary
            )
            publish()
        case .failed:
            state = replacing(
                selection: ChatFeatureState.Selection.none,
                activity: nil,
                notice: .chatOpenFailed
            )
            publish()
        }
    }

    private func install(
        _ aggregate: ChatAggregate,
        selection: ChatFeatureState.Selection,
        notice: ChatNotice?
    ) {
        var rows = currentAllRows.filter { $0.chatID != aggregate.chat.id }
        rows.append(ChatRowSnapshot(aggregate: aggregate))
        finishInstall(rows: rows, selection: selection, notice: notice)
    }

    private func install(
        _ frozen: FrozenChatSnapshot,
        selection: ChatFeatureState.Selection,
        notice: ChatNotice?
    ) {
        var rows = currentAllRows.filter { $0.chatID != frozen.chatID }
        rows.append(ChatRowSnapshot(frozen: frozen))
        finishInstall(rows: rows, selection: selection, notice: notice)
    }

    private func finishInstall(
        rows: [ChatRowSnapshot],
        selection: ChatFeatureState.Selection,
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
        activity: ChatFeatureState.Activity?,
        notice: ChatNotice?
    ) -> ChatFeatureState {
        ChatFeatureState(
            catalog: state.catalog,
            filterQuery: state.filterQuery,
            selection: selection ?? state.selection,
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
             let .open(context, _):
            context
        }
    }
}
