import AudoraDomain

public enum CoachContextRequestError: Error, Equatable, Sendable {
    case pendingDraftMismatch
    case notCapacityFailure
}

public struct CoachContextNewChatQuoteRequest: Equatable, Sendable {
    public let library: LibraryScope
    public let attachments: ChatAttachments
    public let creation: ChatCreation

    public init(
        library: LibraryScope,
        attachments: ChatAttachments,
        creationKind: ChatCreationKind,
        originAttachmentID: ChatSessionAttachmentID? = nil
    ) throws {
        self.library = library
        self.attachments = attachments
        creation = try ChatCreation(
            kind: creationKind,
            originAttachmentID: originAttachmentID,
            attachments: attachments
        )
    }
}

public struct CoachContextChatQuoteRequest: Equatable, Sendable {
    public let library: LibraryScope
    public let chatID: ChatID
    public let draft: ChatDraft

    public init(library: LibraryScope, chatID: ChatID, draft: ChatDraft) {
        self.library = library
        self.chatID = chatID
        self.draft = draft
    }
}

public struct CoachContextPendingTurnRequest: Equatable, Sendable {
    public let library: LibraryScope
    public let chatID: ChatID
    public let draft: ChatDraft
    public let pendingUserTurn: PendingUserTurn

    public init(
        library: LibraryScope,
        chatID: ChatID,
        draft: ChatDraft,
        pendingUserTurn: PendingUserTurn
    ) throws {
        guard pendingUserTurn.draftID == draft.draftID,
              pendingUserTurn.draftVersion == draft.version
        else {
            throw CoachContextRequestError.pendingDraftMismatch
        }
        self.library = library
        self.chatID = chatID
        self.draft = draft
        self.pendingUserTurn = pendingUserTurn
    }
}

/// Typed output consumed by the future attachment picker without mutating a Chat.
public struct CoachContextCreateNewChatRecoveryIntent: Equatable, Sendable {
    public let sourceChatID: ChatID
    public let sourcePendingUserTurnID: PendingUserTurnID
    public let suggestedAttachments: ChatAttachments

    public init(chat: Chat, pendingUserTurn: PendingUserTurn) throws {
        guard pendingUserTurn.draftID == chat.draft.draftID,
              pendingUserTurn.draftVersion == chat.draft.version
        else {
            throw CoachContextRequestError.pendingDraftMismatch
        }
        guard pendingUserTurn.failure == .coachContextCannotFit else {
            throw CoachContextRequestError.notCapacityFailure
        }
        sourceChatID = chat.id
        sourcePendingUserTurnID = pendingUserTurn.id
        suggestedAttachments = chat.attachments
    }
}

/// Stable identity resolved by a context snapshot. Generations cover mutable
/// Profile/Memory/history/attachment projections and provider configuration,
/// which cannot be fenced by comparing serialized text.
enum CoachContextSnapshotBinding: Equatable, Sendable {
    case newChat(
        library: LibraryScope,
        attachments: ChatAttachments,
        creation: ChatCreation
    )
    case chat(
        library: LibraryScope,
        chatID: ChatID,
        draftID: ChatDraftID,
        draftVersion: UInt64
    )
    case pending(
        library: LibraryScope,
        chatID: ChatID,
        draftID: ChatDraftID,
        draftVersion: UInt64,
        pendingUserTurnID: PendingUserTurnID,
        responsePositionID: ChatResponsePositionID
    )
}

struct CoachContextSnapshotAuthority: Equatable, Sendable {
    let binding: CoachContextSnapshotBinding
    let contextGeneration: UInt64
    let configurationGeneration: UInt64
    let profile: CoachProfileProvenance

    init(
        binding: CoachContextSnapshotBinding,
        contextGeneration: UInt64,
        configurationGeneration: UInt64,
        profile: CoachProfileProvenance
    ) {
        self.binding = binding
        self.contextGeneration = contextGeneration
        self.configurationGeneration = configurationGeneration
        self.profile = profile
    }
}

private extension CoachContextNewChatQuoteRequest {
    var snapshotBinding: CoachContextSnapshotBinding {
        .newChat(library: library, attachments: attachments, creation: creation)
    }
}

private extension CoachContextChatQuoteRequest {
    var snapshotBinding: CoachContextSnapshotBinding {
        .chat(
            library: library,
            chatID: chatID,
            draftID: draft.draftID,
            draftVersion: draft.version
        )
    }
}

private extension CoachContextPendingTurnRequest {
    var snapshotBinding: CoachContextSnapshotBinding {
        .pending(
            library: library,
            chatID: chatID,
            draftID: draft.draftID,
            draftVersion: draft.version,
            pendingUserTurnID: pendingUserTurn.id,
            responsePositionID: pendingUserTurn.responsePositionID
        )
    }
}

/// Internal-adapter value after current Profile, Memory, history, and evidence resolve.
/// It never crosses the product-facing CoachContextFeature interface.
struct CoachContextResolvedSnapshot: Sendable {
    let input: CoachContextQuoteInput
    let configuration: CoachContextConfiguration
    let authority: CoachContextSnapshotAuthority

    init(
        input: CoachContextQuoteInput,
        configuration: CoachContextConfiguration,
        authority: CoachContextSnapshotAuthority
    ) throws {
        self.input = input
        self.configuration = configuration
        self.authority = authority
    }
}

enum CoachContextSnapshotOutcome: Sendable {
    case resolved(CoachContextResolvedSnapshot)
    case providerUnavailable
    case sourceUnavailable
    case staleState
}

/// Outbound seam hidden behind DefaultCoachContextFeature.
protocol CoachContextSnapshotPort: Sendable {
    func resolveNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome

    func resolveChat(
        _ request: CoachContextChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome

    func resolvePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextSnapshotOutcome

    /// Revalidates the exact external-context and provider-configuration
    /// generations after deterministic measurement completes.
    func isCurrent(_ authority: CoachContextSnapshotAuthority) async -> Bool
}

public enum CoachContextUnavailableReason: String, Error, Equatable, Sendable {
    case providerUnavailable
    case sourceUnavailable
    case staleState
    case invalidContext
}

public enum CoachContextQuoteOutcome: Equatable, Sendable {
    case available(CoachContextQuote)
    case unavailable(CoachContextUnavailableReason)
}

public enum ChatCreationQuoteOutcome: Equatable, Sendable {
    case available(ChatCreationQuote)
    case unavailable(CoachContextUnavailableReason)
}

enum CoachContextPendingPreparationOutcome: Equatable, Sendable {
    case prepared(PreparedCoachLaunchContext)
    case messageTooLong(maximumUTF8Bytes: Int)
    case cannotFit(CoachContextCapacityFailure)
    case unavailable(CoachContextUnavailableReason)
}

/// Exact bytes plus the identity/configuration fence required by the future #22
/// admission coordinator. This module does not invoke a provider.
struct PreparedCoachLaunchContext: Equatable, Sendable {
    let quote: CoachContextQuote
    let exchange: CanonicalCoachExchange
    let authority: CoachContextSnapshotAuthority

    init(
        measured: MeasuredCoachLaunchContext,
        authority: CoachContextSnapshotAuthority
    ) {
        quote = measured.quote
        exchange = measured.exchange
        self.authority = authority
    }
}

/// Product-facing advisory boundary. Only stable Domain identity crosses this interface.
public protocol CoachContextFeature: Sendable {
    func quoteNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> ChatCreationQuoteOutcome

    func quoteChat(
        _ request: CoachContextChatQuoteRequest
    ) async -> CoachContextQuoteOutcome

}

/// Application-internal preflight seam. Its exact serialized exchange is reserved
/// for the future provider/admission coordinator owned by #22.
protocol CoachContextPendingPreparing: Sendable {
    func preparePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextPendingPreparationOutcome

    /// Final generation fence used after durable admission/Invocation install and
    /// immediately before provider launch.
    func isPreparedContextCurrent(
        _ prepared: PreparedCoachLaunchContext
    ) async -> Bool
}

typealias CoachContextCoordinating = CoachContextFeature & CoachContextPendingPreparing

public struct DefaultCoachContextFeature: CoachContextFeature, CoachContextPendingPreparing, Sendable {
    private let source: any CoachContextSnapshotPort
    private let capacity: CoachContextCapacity

    /// Live composition fails closed until a provider descriptor is qualified.
    public init() {
        source = UnavailableCoachContextSnapshotPort()
        capacity = CoachContextCapacity()
    }

    init(
        source: any CoachContextSnapshotPort,
        capacity: CoachContextCapacity = CoachContextCapacity()
    ) {
        self.source = source
        self.capacity = capacity
    }

    public func quoteNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> ChatCreationQuoteOutcome {
        switch await source.resolveNewChat(request) {
        case let .resolved(snapshot):
            guard snapshot.authority.binding == request.snapshotBinding,
                  snapshot.input.trigger == .chatCreation(request.creation)
            else {
                return .unavailable(.staleState)
            }
            do {
                let quote = try capacity.quoteNewChat(
                    snapshot.input,
                    configuration: snapshot.configuration
                )
                guard await source.isCurrent(snapshot.authority) else {
                    return .unavailable(.staleState)
                }
                return .available(quote)
            } catch {
                return .unavailable(.invalidContext)
            }
        case .providerUnavailable:
            return .unavailable(.providerUnavailable)
        case .sourceUnavailable:
            return .unavailable(.sourceUnavailable)
        case .staleState:
            return .unavailable(.staleState)
        }
    }

    public func quoteChat(
        _ request: CoachContextChatQuoteRequest
    ) async -> CoachContextQuoteOutcome {
        switch await source.resolveChat(request) {
        case let .resolved(snapshot):
            guard snapshot.authority.binding == request.snapshotBinding,
                  snapshot.input.trigger == .userMessage(request.draft.text)
            else {
                return .unavailable(.staleState)
            }
            do {
                let quote = try capacity.quoteChat(
                    snapshot.input,
                    configuration: snapshot.configuration
                )
                guard await source.isCurrent(snapshot.authority) else {
                    return .unavailable(.staleState)
                }
                return .available(quote)
            } catch {
                return .unavailable(.invalidContext)
            }
        case .providerUnavailable:
            return .unavailable(.providerUnavailable)
        case .sourceUnavailable:
            return .unavailable(.sourceUnavailable)
        case .staleState:
            return .unavailable(.staleState)
        }
    }

    func preparePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextPendingPreparationOutcome {
        guard request.draft.text.utf8.count <=
            CoachContextInputLimits.maximumUserMessageUTF8Bytes
        else {
            return .messageTooLong(
                maximumUTF8Bytes: CoachContextInputLimits.maximumUserMessageUTF8Bytes
            )
        }
        switch await source.resolvePendingUserTurn(request) {
        case let .resolved(snapshot):
            guard snapshot.authority.binding == request.snapshotBinding,
                  snapshot.input.trigger == .userMessage(request.draft.text)
            else {
                return .unavailable(.staleState)
            }
            do {
                let measured = try capacity.prepareForLaunch(
                    snapshot.input,
                    configuration: snapshot.configuration
                )
                guard await source.isCurrent(snapshot.authority) else {
                    return .unavailable(.staleState)
                }
                return .prepared(
                    PreparedCoachLaunchContext(
                        measured: measured,
                        authority: snapshot.authority
                    )
                )
            } catch let error as CoachContextPreparationError {
                switch error {
                case let .messageTooLong(quote):
                    guard await source.isCurrent(snapshot.authority) else {
                        return .unavailable(.staleState)
                    }
                    return .messageTooLong(
                        maximumUTF8Bytes: quote.maximumUserMessageUTF8Bytes
                    )
                case let .cannotFit(failure):
                    guard await source.isCurrent(snapshot.authority) else {
                        return .unavailable(.staleState)
                    }
                    return .cannotFit(failure)
                }
            } catch {
                return .unavailable(.invalidContext)
            }
        case .providerUnavailable:
            return .unavailable(.providerUnavailable)
        case .sourceUnavailable:
            return .unavailable(.sourceUnavailable)
        case .staleState:
            return .unavailable(.staleState)
        }
    }

    func isPreparedContextCurrent(
        _ prepared: PreparedCoachLaunchContext
    ) async -> Bool {
        await source.isCurrent(prepared.authority)
    }
}

/// Live fail-closed source used until a provider/model configuration is qualified.
struct UnavailableCoachContextSnapshotPort: CoachContextSnapshotPort {
    init() {}

    func resolveNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        .providerUnavailable
    }

    func resolveChat(
        _ request: CoachContextChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        .providerUnavailable
    }

    func resolvePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextSnapshotOutcome {
        .providerUnavailable
    }

    func isCurrent(_ authority: CoachContextSnapshotAuthority) async -> Bool {
        false
    }
}
