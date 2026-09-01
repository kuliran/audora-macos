import AudoraDomain

public struct ChatCommandContext: Equatable, Sendable {
    public let libraryScope: LibraryScope
    public let generation: UInt64

    public init(libraryScope: LibraryScope, generation: UInt64) {
        self.libraryScope = libraryScope
        self.generation = generation
    }
}

public enum ChatCommand: Equatable, Sendable {
    case start(ChatCommandContext)
    case beginNewChat(ChatCommandContext)
    case setNewChatAttachmentFilter(ChatCommandContext, ChatAttachmentFilterQuery)
    case toggleNewChatAttachment(ChatCommandContext, ChatSessionAttachmentID)
    case cancelNewChat(ChatCommandContext)
    case confirmNewChat(ChatCommandContext, NewChatConfirmationToken)
    case rename(
        ChatCommandContext,
        ChatID,
        title: String,
        expectedRevision: UInt64
    )
    case setFilter(ChatCommandContext, ChatFilterQuery)
    case open(ChatCommandContext, ChatID)
    case editDraft(
        ChatCommandContext,
        ChatID,
        ChatDraftID,
        text: String
    )
    case refreshContextQuote(ChatCommandContext, ChatID, ChatDraft)
    case sendDraft(ChatCommandContext, ChatID, ChatDraft)
    case retryPendingUserTurn(ChatCommandContext, PendingUserTurnID)
    case createNewChatFromCapacityFailure(ChatCommandContext, PendingUserTurnID)
    case discardPendingUserTurn(ChatCommandContext, PendingUserTurnID)
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol ChatFeature: Sendable {
    var currentState: ChatFeatureState { get async }
    var states: AsyncStream<ChatFeatureState> { get }

    func currentState(in scope: LibraryScope) async -> ChatFeatureState?
    func send(_ command: ChatCommand) async
    /// Begins the lifecycle fence used by orderly termination. Idempotently
    /// rejects queued or later transient work and requests cancellation of any
    /// transient work already running before it returns; durable mutations
    /// remain ordered.
    func beginOrderlyTermination() async
    func flushForOrderlyTermination() async -> Bool
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public extension ChatFeature {
    /// Default for adapters that own no transient work or local admission state.
    func beginOrderlyTermination() async {}
}
