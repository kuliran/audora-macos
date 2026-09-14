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
    case stopCoachResponse(ChatCommandContext, InvocationStopAuthority)
    case stopProfileReconsideration(
        ChatCommandContext,
        ProfileReconsiderationInvocationStopAuthority
    )
    case retryPendingUserTurn(ChatCommandContext, PendingUserTurnID)
    case createNewChatFromCapacityFailure(ChatCommandContext, PendingUserTurnID)
    case discardPendingUserTurn(ChatCommandContext, PendingUserTurnID)
    case acceptProfileProposal(ChatCommandContext, ProfileChangeProposalID)
    case discardProfileProposal(ChatCommandContext, ProfileChangeProposalID)
    case retryProfileEvidencePublication(
        ChatCommandContext,
        ChatResponsePositionID
    )
    case discardProfileEvidencePublication(
        ChatCommandContext,
        ChatResponsePositionID
    )
    case reconsiderProfileEffect(
        ChatCommandContext,
        ChatProfileEffectIdentity
    )
    case retryProfileReconsideration(
        ChatCommandContext,
        ChatProfileEffectIdentity
    )
    case discardProfileReconsiderationFailure(
        ChatCommandContext,
        ChatProfileEffectIdentity
    )
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol ChatFeature: Sendable {
    var currentState: ChatFeatureState { get async }
    var states: AsyncStream<ChatFeatureState> { get }

    func currentState(in context: ChatCommandContext) async -> ChatFeatureState?
    func send(_ command: ChatCommand) async
    /// Quiesces transient Chat work and durably flushes the selected Draft
    /// before a whole-Library aggregate mutation may begin.
    func prepareForLibraryCatalogMutation(
        for activation: LibraryActivation
    ) async -> Bool
    /// Reloads Chat ownership after a catalog mutation, reopening the prior
    /// selection only when that exact Chat remains active.
    func reloadAfterLibraryCatalogMutation(
        for activation: LibraryActivation
    ) async -> Bool
    /// Begins the lifecycle fence used by orderly termination. Idempotently
    /// rejects queued or later transient work and requests cancellation of any
    /// transient work already running before it returns; durable mutations
    /// remain ordered.
    func beginOrderlyTermination() async
    func flushForOrderlyTermination() async -> Bool
}

public extension ChatFeature {
    /// Implementations without an explicit catalog lifecycle cannot safely
    /// authorize aggregate mutation.
    func prepareForLibraryCatalogMutation(
        for activation: LibraryActivation
    ) async -> Bool {
        false
    }

    /// A missing reload implementation is an explicit unavailable result, not
    /// a successful no-op.
    func reloadAfterLibraryCatalogMutation(
        for activation: LibraryActivation
    ) async -> Bool {
        false
    }
}
