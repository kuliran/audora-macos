import AudoraDomain

public protocol ChatStorePort: Sendable {
    func loadCatalog(in library: LibraryScope) async -> ChatCatalogOutcome
    func create(_ seed: NewDevelopmentChatSeed) async -> ChatMutationOutcome
    func rename(_ mutation: RenameChatMutation) async -> ChatMutationOutcome
    func load(_ chatID: ChatID, in library: LibraryScope) async -> ChatLoadOutcome
}

public protocol ChatClock: Sendable {
    func now() async -> UTCInstant
}

public protocol ChatIDGenerator: Sendable {
    func generateChatID(at instant: UTCInstant) async -> ChatID
}

public protocol ChatDraftIDGenerator: Sendable {
    func generateChatDraftID(at instant: UTCInstant) async -> ChatDraftID
}

public protocol CoachMemoryIDGenerator: Sendable {
    func generateCoachMemoryID(at instant: UTCInstant) async -> CoachMemoryID
}

public protocol ProfileStatementGenerationReading: Sendable {
    func statementGeneration(in library: LibraryScope) async -> UInt64?
}

public struct NewDevelopmentChatSeed: Equatable, Sendable {
    public let library: LibraryScope
    public let aggregate: ChatAggregate

    public init(
        library: LibraryScope,
        chatID: ChatID,
        draftID: ChatDraftID,
        memoryID: CoachMemoryID,
        instant: UTCInstant,
        profileStatementGeneration: UInt64
    ) throws {
        self.library = library
        aggregate = try ChatAggregate.emptyDevelopmentChat(
            chatID: chatID,
            draftID: draftID,
            memoryID: memoryID,
            instant: instant,
            profileStatementGeneration: profileStatementGeneration
        )
    }
}

public struct RenameChatMutation: Equatable, Sendable {
    public let library: LibraryScope
    public let base: ChatAggregate
    public let replacement: ChatAggregate

    public init(
        library: LibraryScope,
        base: ChatAggregate,
        title: ChatTitle,
        updatedAt: UTCInstant
    ) throws {
        self.library = library
        self.base = base
        replacement = try ChatAggregate(
            chat: base.chat.renamed(to: title, at: updatedAt),
            memory: base.memory
        )
    }

    public var chatID: ChatID { base.chat.id }
    public var expectedRevision: UInt64 { base.chat.manifestRevision }
}

public enum ChatCatalogEntry: Equatable, Sendable {
    case available(ChatAggregate)
    case frozen(FrozenChatSnapshot)
}

public enum ChatCatalogOutcome: Equatable, Sendable {
    case loaded([ChatCatalogEntry])
    case readOnlyLibrary
    case failed
}

public enum ChatMutationOutcome: Equatable, Sendable {
    case committed(ChatAggregate)
    case collision
    case profileStatementGenerationChanged(UInt64)
    case stale(ChatAggregate)
    case frozen(FrozenChatSnapshot)
    case readOnlyLibrary
    case failed
}

public enum ChatLoadOutcome: Equatable, Sendable {
    case loaded(ChatAggregate)
    case frozen(FrozenChatSnapshot)
    case missing
    case readOnlyLibrary
    case failed
}
