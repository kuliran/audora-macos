import AudoraApplication
import AudoraDomain
import Combine

@MainActor
public final class ChatPresentationModel: ObservableObject {
    private static var lastIssuedCommandGeneration: UInt64 = 0

    @Published public private(set) var snapshot = ChatFeatureState()
    @Published public var filterText = ""

    private let feature: any ChatFeature
    private let dispatcher: ChatCommandDispatcher
    private var startedLibrary: LibraryID?
    private var commandContext: ChatCommandContext?
    private var projectedStateContext: ChatCommandContext?
    private var stateConsumer: Task<Void, Never>?

    public init(feature: any ChatFeature) {
        let dispatcher = ChatCommandDispatcher(feature: feature)
        self.feature = feature
        self.dispatcher = dispatcher
    }

    public init(dispatcher: ChatCommandDispatcher) {
        feature = dispatcher.feature
        self.dispatcher = dispatcher
    }

    public func start(in scope: LibraryScope) async {
        guard !Task.isCancelled else { return }
        guard startedLibrary != scope.libraryID else { return }
        startedLibrary = scope.libraryID
        let context = Self.issueCommandContext(for: scope)
        commandContext = context

        stateConsumer?.cancel()
        snapshot = ChatFeatureState(
            catalog: .loading,
            filterQuery: .empty,
            selection: .none
        )
        filterText = ""

        let stream = feature.states
        let consumer = Task { @MainActor [weak self] in
            guard let self else { return }
            var states = stream.makeAsyncIterator()
            while !Task.isCancelled, let next = await states.next() {
                guard context == commandContext else { return }
                if projectedStateContext != context {
                    guard await feature.currentState(in: scope) == next else { continue }
                    guard context == commandContext, !Task.isCancelled else { return }
                    projectedStateContext = context
                }
                snapshot = next
            }
        }
        stateConsumer = consumer

        await withTaskCancellationHandler {
            await dispatcher.sendAndWait(.start(context))
            guard !Task.isCancelled else {
                consumer.cancel()
                return
            }
            if let current = await feature.currentState(in: scope) {
                guard context == commandContext, !Task.isCancelled else {
                    consumer.cancel()
                    return
                }
                projectedStateContext = context
                snapshot = current
            }
            await consumer.value
        } onCancel: {
            consumer.cancel()
        }
        guard context == commandContext, !Task.isCancelled else { return }
        stateConsumer = nil
    }

    private static func issueCommandContext(
        for scope: LibraryScope
    ) -> ChatCommandContext {
        precondition(lastIssuedCommandGeneration < UInt64.max)
        lastIssuedCommandGeneration += 1
        return ChatCommandContext(
            libraryScope: scope,
            generation: lastIssuedCommandGeneration
        )
    }

    public func createDevelopmentChat() {
        guard let context = commandContext else { return }
        send(.createDevelopmentChat(context))
    }

    public func open(_ chatID: ChatID) {
        guard let context = commandContext else { return }
        send(.open(context, chatID))
    }

    public func rename(
        _ chatID: ChatID,
        title: String,
        expectedRevision: UInt64
    ) {
        guard let context = commandContext else { return }
        send(
            .rename(
                context,
                chatID,
                title: title,
                expectedRevision: expectedRevision
            )
        )
    }

    public func updateDraft(_ text: String) {
        guard let context = commandContext,
              case let .open(aggregate) = snapshot.selection,
              case let .editable(draft, _) = snapshot.composer,
              aggregate.chat.draft.draftID == draft.draftID
        else {
            return
        }
        send(.editDraft(context, aggregate.chat.id, draft.draftID, text: text))
    }

    public func sendDraft() {
        guard let context = commandContext,
              case let .open(aggregate) = snapshot.selection,
              case let .editable(draft, _) = snapshot.composer,
              aggregate.chat.draft.draftID == draft.draftID
        else {
            return
        }
        send(.sendDraft(context, aggregate.chat.id, draft))
    }

    public func discardPendingUserTurn(_ pendingUserTurnID: PendingUserTurnID) {
        guard let context = commandContext else { return }
        send(.discardPendingUserTurn(context, pendingUserTurnID))
    }

    private func send(_ command: ChatCommand) {
        dispatcher.enqueue(command)
    }

    public func updateFilter(_ value: String) {
        filterText = value
        guard let query = try? ChatFilterQuery(value) else { return }
        guard let context = commandContext else { return }
        send(.setFilter(context, query))
    }

    public func clearFilter() {
        updateFilter("")
    }
}
