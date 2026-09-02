import AudoraDomain
import Foundation

public protocol ChatStorePort: Sendable {
    func loadCatalog(in library: LibraryScope) async -> ChatCatalogOutcome
    func create(_ seed: NewDevelopmentChatSeed) async -> ChatMutationOutcome
    func rename(_ mutation: RenameChatMutation) async -> ChatMutationOutcome
    func saveDraft(_ mutation: SaveChatDraftMutation) async -> ChatMutationOutcome
    func lockPendingUserTurn(
        _ mutation: LockPendingUserTurnMutation
    ) async -> ChatMutationOutcome
    func replacePendingUserTurn(
        _ mutation: ReplacePendingUserTurnMutation
    ) async -> ChatMutationOutcome
    func discardPendingUserTurn(
        _ mutation: DiscardPendingUserTurnMutation
    ) async -> ChatMutationOutcome
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

public protocol PendingUserTurnIDGenerator: Sendable {
    func generatePendingUserTurnID(at instant: UTCInstant) async -> PendingUserTurnID
}

public protocol ChatResponsePositionIDGenerator: Sendable {
    func generateChatResponsePositionID(at instant: UTCInstant) async -> ChatResponsePositionID
}

public protocol ChatAutosaveScheduling: Sendable {
    func sleep(forNanoseconds nanoseconds: UInt64) async throws
}

public struct SystemChatAutosaveScheduler: ChatAutosaveScheduling {
    public init() {}

    public func sleep(forNanoseconds nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

public protocol ChatAdmissionRefreshScheduling: Sendable {
    func sleep(until deadline: UTCInstant) async throws
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
            memory: base.memory,
            pendingUserTurn: base.pendingUserTurn
        )
    }

    public var chatID: ChatID { base.chat.id }
    public var expectedRevision: UInt64 { base.chat.manifestRevision }
}

public struct SaveChatDraftMutation: Equatable, Sendable {
    public let library: LibraryScope
    public let chatID: ChatID
    public let replacement: ChatDraft

    public init(
        library: LibraryScope,
        chatID: ChatID,
        replacement: ChatDraft
    ) {
        self.library = library
        self.chatID = chatID
        self.replacement = replacement
    }
}

public struct LockPendingUserTurnMutation: Equatable, Sendable {
    public let library: LibraryScope
    public let chatID: ChatID
    public let pendingUserTurn: PendingUserTurn

    public init(
        library: LibraryScope,
        chatID: ChatID,
        pendingUserTurn: PendingUserTurn
    ) {
        self.library = library
        self.chatID = chatID
        self.pendingUserTurn = pendingUserTurn
    }
}

public enum ReplacePendingUserTurnMutationError: Error, Equatable, Sendable {
    case identityChanged
}

/// A compare-and-swap update for the retryable failure on one Pending User Turn.
///
/// The base value is the durable comparison authority. The replacement is
/// constrained to the same Pending User Turn, Draft version, and reserved
/// response position so a retry cannot silently become another send.
public struct ReplacePendingUserTurnMutation: Equatable, Sendable {
    public let library: LibraryScope
    public let chatID: ChatID
    public let base: PendingUserTurn
    public let replacement: PendingUserTurn

    public init(
        library: LibraryScope,
        chatID: ChatID,
        base: PendingUserTurn,
        replacement: PendingUserTurn
    ) throws {
        guard base.id == replacement.id,
              base.draftID == replacement.draftID,
              base.draftVersion == replacement.draftVersion,
              base.responsePositionID == replacement.responsePositionID
        else {
            throw ReplacePendingUserTurnMutationError.identityChanged
        }
        self.library = library
        self.chatID = chatID
        self.base = base
        self.replacement = replacement
    }
}

public struct DiscardPendingUserTurnMutation: Equatable, Sendable {
    public let library: LibraryScope
    public let chatID: ChatID
    public let pendingUserTurn: PendingUserTurn

    public init(
        library: LibraryScope,
        chatID: ChatID,
        pendingUserTurn: PendingUserTurn
    ) {
        self.library = library
        self.chatID = chatID
        self.pendingUserTurn = pendingUserTurn
    }
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
