import AudoraDomain
import Foundation

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public actor DefaultChatFeature: ChatFeature {
    private static let maximumCreateAttempts = 3

    private struct PendingStart: Sendable {
        let scope: LibraryScope
        let generation: UInt64
    }

    private let store: any ChatStorePort
    private let profileReader: any ProfileStatementGenerationReading
    private let clock: any ChatClock
    private let chatIDGenerator: any ChatIDGenerator
    private let draftIDGenerator: any ChatDraftIDGenerator
    private let memoryIDGenerator: any CoachMemoryIDGenerator

    private var library: LibraryScope?
    private var state = ChatFeatureState()
    private var operationInFlight = false
    private var pendingStart: PendingStart?
    private var startGeneration: UInt64 = 0
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
        library == scope ? state : nil
    }

    public nonisolated var states: AsyncStream<ChatFeatureState> {
        AsyncStream { continuation in
            Task { await self.addSubscriber(continuation) }
        }
    }

    public func send(_ command: ChatCommand) async {
        if case let .setFilter(query) = command {
            setFilter(query)
            return
        }
        if case let .start(scope) = command {
            startGeneration &+= 1
            pendingStart = PendingStart(scope: scope, generation: startGeneration)
            guard !operationInFlight else { return }
            operationInFlight = true
            defer { operationInFlight = false }
            await drainPendingStarts()
            return
        }
        guard !operationInFlight else { return }
        operationInFlight = true
        defer { operationInFlight = false }

        switch command {
        case .start:
            break
        case .createDevelopmentChat:
            await createDevelopmentChat()
        case let .rename(chatID, title, expectedRevision):
            await rename(chatID, rawTitle: title, expectedRevision: expectedRevision)
        case let .open(chatID):
            await open(chatID)
        case .setFilter:
            break
        }
        await drainPendingStarts()
    }

    private func drainPendingStarts() async {
        while let request = pendingStart {
            pendingStart = nil
            await start(in: request.scope, generation: request.generation)
        }
    }

    private func start(in scope: LibraryScope, generation: UInt64) async {
        library = scope
        state = ChatFeatureState(
            catalog: .loading,
            filterQuery: .empty,
            selection: .none
        )
        publish()

        let outcome = await store.loadCatalog(in: scope)
        guard generation == startGeneration else { return }
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

    private func createDevelopmentChat() async {
        guard let library, case .ready = state.catalog else { return }
        state = replacing(activity: .creating, notice: nil)
        publish()

        guard var statementGeneration = await profileReader.statementGeneration(in: library) else {
            state = replacing(activity: nil, notice: .createFailed)
            publish()
            return
        }
        let instant = await clock.now()

        for _ in 0..<Self.maximumCreateAttempts {
            let chatID = await chatIDGenerator.generateChatID(at: instant)
            let draftID = await draftIDGenerator.generateChatDraftID(at: instant)
            let memoryID = await memoryIDGenerator.generateCoachMemoryID(at: instant)
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

            switch await store.create(seed) {
            case let .committed(committed):
                install(committed, selection: .open(committed), notice: nil)
                return
            case .collision:
                continue
            case let .profileStatementGenerationChanged(current):
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

        state = replacing(activity: nil, notice: .createCollisionLimitReached)
        publish()
    }

    private func rename(
        _ chatID: ChatID,
        rawTitle: String,
        expectedRevision: UInt64
    ) async {
        guard let library, case .ready = state.catalog else { return }
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
            switch await store.load(chatID, in: library) {
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
        switch await store.rename(mutation) {
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

    private func open(_ chatID: ChatID) async {
        guard let library, case .ready = state.catalog else { return }
        state = replacing(selection: .opening(chatID), activity: nil, notice: nil)
        publish()
        switch await store.load(chatID, in: library) {
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
                notice: .chatFrozen
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
