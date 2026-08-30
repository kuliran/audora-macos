import AudoraDomain

public enum ChatCommand: Equatable, Sendable {
    case start(LibraryScope)
    case createDevelopmentChat
    case rename(ChatID, title: String, expectedRevision: UInt64)
    case setFilter(ChatFilterQuery)
    case open(ChatID)
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol ChatFeature: Sendable {
    var currentState: ChatFeatureState { get async }
    var states: AsyncStream<ChatFeatureState> { get }

    func currentState(in scope: LibraryScope) async -> ChatFeatureState?
    func send(_ command: ChatCommand) async
}
