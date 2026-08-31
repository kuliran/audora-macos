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
    case createDevelopmentChat(ChatCommandContext)
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
    case sendDraft(ChatCommandContext, ChatID, ChatDraft)
    case discardPendingUserTurn(ChatCommandContext, PendingUserTurnID)
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol ChatFeature: Sendable {
    var currentState: ChatFeatureState { get async }
    var states: AsyncStream<ChatFeatureState> { get }

    func currentState(in scope: LibraryScope) async -> ChatFeatureState?
    func send(_ command: ChatCommand) async
    func flushForOrderlyTermination() async -> Bool
}
