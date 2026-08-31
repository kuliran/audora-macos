import AudoraApplication
import AudoraDomain
import Combine

public enum NewChatAttachmentPickerAction: Equatable, Sendable {
    case toggle(ChatSessionAttachmentID)
    case defaultAction
    case cancelAction
}

@MainActor
public final class ChatPresentationModel: ObservableObject {
    private static var lastIssuedCommandGeneration: UInt64 = 0

    @Published public private(set) var snapshot = ChatFeatureState()
    @Published public var filterText = ""
    @Published public var newChatAttachmentFilterText = ""

    private let feature: any ApplicationCommandFeature
    private let dispatcher: ChatCommandDispatcher
    private var startedLibrary: LibraryID?
    private var commandContext: ChatCommandContext?
    private var projectedStateContext: ChatCommandContext?
    private var stateConsumer: Task<Void, Never>?

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

        let stream = feature.chatStates
        let consumer = Task { @MainActor [weak self] in
            guard let self else { return }
            var states = stream.makeAsyncIterator()
            while !Task.isCancelled, let next = await states.next() {
                guard context == commandContext else { return }
                if projectedStateContext != context {
                    guard await feature.currentChatState(in: scope) == next else { continue }
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
            if let current = await feature.currentChatState(in: scope) {
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

    public func beginNewChat() {
        guard let context = commandContext else { return }
        newChatAttachmentFilterText = ""
        send(.beginNewChat(context))
    }

    public func updateNewChatAttachmentFilter(_ value: String) {
        newChatAttachmentFilterText = value
        guard let context = commandContext,
              let query = try? ChatAttachmentFilterQuery(value)
        else { return }
        send(.setNewChatAttachmentFilter(context, query))
    }

    public func toggleNewChatAttachment(_ attachmentID: ChatSessionAttachmentID) {
        guard let context = commandContext else { return }
        send(.toggleNewChatAttachment(context, attachmentID))
    }

    public func performNewChatAttachmentPickerAction(
        _ action: NewChatAttachmentPickerAction
    ) {
        switch action {
        case let .toggle(attachmentID): toggleNewChatAttachment(attachmentID)
        case .defaultAction: confirmNewChat()
        case .cancelAction: cancelNewChat()
        }
    }

    public func cancelNewChat() {
        guard let context = commandContext else { return }
        send(.cancelNewChat(context))
    }

    public func confirmNewChat() {
        guard let context = commandContext else { return }
        send(.confirmNewChat(context))
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

    /// Re-resolves current Profile, Memory, history, attachments, and provider
    /// configuration without changing the Chat or invoking a provider.
    public func refreshContextQuote() {
        guard let context = commandContext,
              case let .open(aggregate) = snapshot.selection,
              let draft = snapshot.composer?.draft
        else {
            return
        }
        send(.refreshContextQuote(context, aggregate.chat.id, draft))
    }

    public func discardPendingUserTurn(_ pendingUserTurnID: PendingUserTurnID) {
        guard let context = commandContext else { return }
        send(.discardPendingUserTurn(context, pendingUserTurnID))
    }

    public func retryPendingUserTurn(_ pendingUserTurnID: PendingUserTurnID) {
        guard let context = commandContext else { return }
        send(.retryPendingUserTurn(context, pendingUserTurnID))
    }

    public func createNewChatFromCapacityFailure(
        _ pendingUserTurnID: PendingUserTurnID
    ) {
        guard let context = commandContext else { return }
        send(.createNewChatFromCapacityFailure(context, pendingUserTurnID))
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
