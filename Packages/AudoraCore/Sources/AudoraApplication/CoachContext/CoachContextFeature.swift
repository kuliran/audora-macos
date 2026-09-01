import AudoraDomain
import Foundation

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

    init(
        binding: CoachContextSnapshotBinding,
        contextGeneration: UInt64,
        configurationGeneration: UInt64
    ) {
        self.binding = binding
        self.contextGeneration = contextGeneration
        self.configurationGeneration = configurationGeneration
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

enum CoachContextSourceLeaseAuthority: Equatable, Sendable {
    case snapshot(CoachContextSnapshotAuthority)
    case configuration(generation: UInt64)
}

actor CoachContextAuthorityLease {
    private var releaseAction: (@Sendable () async -> Void)?

    init(release: @escaping @Sendable () async -> Void = {}) {
        releaseAction = release
    }

    func release() async {
        guard let action = releaseAction else { return }
        releaseAction = nil
        await action()
    }
}

enum CoachContextAuthorityLeaseOutcome: Sendable {
    case acquired(CoachContextAuthorityLease)
    case stale
}

/// The one provider/model projection policy currently qualified for this app
/// process. A provider can be temporarily unavailable while this configuration
/// remains known; absence of a qualified policy is represented separately.
enum CoachAttachmentProjectionPolicyOutcome: Sendable {
    case knownQualified(
        policy: CoachAttachmentProjectionPolicy,
        configurationGeneration: UInt64
    )
    case unavailable
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

    /// Reads the same configuration generation used by quote and final
    /// preparation. Attachment projection must never capture a parallel policy.
    func currentAttachmentProjectionPolicy()
        async -> CoachAttachmentProjectionPolicyOutcome

    func isCurrentConfiguration(_ configurationGeneration: UInt64) async -> Bool

    /// Acquires an opaque lease only while the exact snapshot/configuration
    /// authority is current. Mutable adapters must defer generation advancement
    /// until the returned lease is released.
    func acquireAuthorityLease(
        _ authority: CoachContextSourceLeaseAuthority
    ) async -> CoachContextAuthorityLeaseOutcome
}

extension CoachContextSnapshotPort {
    func currentAttachmentProjectionPolicy()
        async -> CoachAttachmentProjectionPolicyOutcome
    {
        .unavailable
    }

    func isCurrentConfiguration(_ configurationGeneration: UInt64) async -> Bool {
        false
    }

    /// Explicit opt-in for fixtures and adapters whose generations are immutable.
    /// Mutable sources must implement lease acquisition and defer their writes.
    func acquireImmutableAuthorityLease(
        _ authority: CoachContextSourceLeaseAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        let current: Bool
        switch authority {
        case let .snapshot(snapshot):
            current = await isCurrent(snapshot)
        case let .configuration(generation):
            current = await isCurrentConfiguration(generation)
        }
        return current
            ? .acquired(CoachContextAuthorityLease())
            : .stale
    }
}

struct CoachAttachmentProjectionConfiguration: Sendable {
    let policy: CoachAttachmentProjectionPolicy
    let stamp: CoachContextConfigurationStamp
}

enum CoachAttachmentProjectionConfigurationOutcome: Sendable {
    case configured(CoachAttachmentProjectionConfiguration)
    case unavailable
}

protocol CoachAttachmentProjectionConfigurationAuthority: Sendable {
    func currentAttachmentProjectionConfiguration()
        async -> CoachAttachmentProjectionConfigurationOutcome
    func isCurrent(_ stamp: CoachContextConfigurationStamp) async -> Bool
}

private struct CoachContextConfigurationAuthority:
    CoachAttachmentProjectionConfigurationAuthority,
    Sendable
{
    let authorityID: UUID
    let source: any CoachContextSnapshotPort

    init(source: any CoachContextSnapshotPort, authorityID: UUID = UUID()) {
        self.source = source
        self.authorityID = authorityID
    }

    func currentAttachmentProjectionConfiguration()
        async -> CoachAttachmentProjectionConfigurationOutcome
    {
        switch await source.currentAttachmentProjectionPolicy() {
        case let .knownQualified(policy, configurationGeneration):
            return .configured(
                CoachAttachmentProjectionConfiguration(
                    policy: policy,
                    stamp: stamp(for: configurationGeneration)
                )
            )
        case .unavailable:
            return .unavailable
        }
    }

    func isCurrent(_ stamp: CoachContextConfigurationStamp) async -> Bool {
        guard owns(stamp) else { return false }
        return await source.isCurrentConfiguration(stamp.generation)
    }

    func owns(_ stamp: CoachContextConfigurationStamp) -> Bool {
        stamp.authorityID == authorityID
    }

    func stamp(for configurationGeneration: UInt64) -> CoachContextConfigurationStamp {
        CoachContextConfigurationStamp(
            authorityID: authorityID,
            generation: configurationGeneration
        )
    }
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

enum ConfigurationBoundChatCreationQuoteOutcome: Equatable, Sendable {
    case available(
        ChatCreationQuote,
        authority: ChatCreationQuoteAuthority
    )
    case providerUnavailable(authority: ChatCreationQuoteAuthority)
    case unavailable(CoachContextUnavailableReason)
}

struct ChatCreationQuoteAuthority: Equatable, Sendable {
    let context: CoachContextSnapshotAuthority?
    let configuration: CoachContextConfigurationStamp

    init(
        context: CoachContextSnapshotAuthority? = nil,
        configuration: CoachContextConfigurationStamp
    ) {
        self.context = context
        self.configuration = configuration
    }
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
}

typealias CoachContextCoordinating = CoachContextFeature & CoachContextPendingPreparing

protocol ChatCoachContextCoordinating:
    CoachContextFeature,
    CoachContextPendingPreparing,
    Sendable
{
    func loadAttachmentCandidates(
        in library: LibraryScope
    ) async -> ChatAttachmentCatalogOutcome

    func resolveAttachments(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentResolutionOutcome

    func quoteNewChatBoundToConfiguration(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> ConfigurationBoundChatCreationQuoteOutcome

    func isCurrentAttachmentConfiguration(
        _ stamp: CoachContextConfigurationStamp
    ) async -> Bool

    func acquireNewChatCreationLease(
        _ authority: ChatCreationQuoteAuthority
    ) async -> CoachContextAuthorityLeaseOutcome
}

public struct DefaultCoachContextFeature:
    CoachContextFeature,
    CoachContextPendingPreparing,
    ChatCoachContextCoordinating,
    Sendable
{
    private let source: any CoachContextSnapshotPort
    private let capacity: CoachContextCapacity
    private let configurationAuthority: CoachContextConfigurationAuthority
    private let attachmentSource: any ChatSessionAttachmentSource

    /// Live composition fails closed until a provider descriptor is qualified.
    public init() {
        let source = UnavailableCoachContextSnapshotPort()
        self.source = source
        capacity = CoachContextCapacity()
        configurationAuthority = CoachContextConfigurationAuthority(source: source)
        attachmentSource = UnavailableChatSessionAttachmentSource()
    }

    @_spi(CoachContextQualification)
    public init(
        attachmentEvidenceSource: any ChatSessionAttachmentEvidenceSource
    ) {
        let source = UnavailableCoachContextSnapshotPort()
        let configurationAuthority = CoachContextConfigurationAuthority(source: source)
        self.source = source
        capacity = CoachContextCapacity()
        self.configurationAuthority = configurationAuthority
        attachmentSource = ProjectedChatSessionAttachmentSource(
            evidenceSource: attachmentEvidenceSource,
            configurationAuthority: configurationAuthority
        )
    }

    init(
        source: any CoachContextSnapshotPort,
        capacity: CoachContextCapacity = CoachContextCapacity(),
        configurationAuthorityID: UUID = UUID()
    ) {
        self.source = source
        self.capacity = capacity
        configurationAuthority = CoachContextConfigurationAuthority(
            source: source,
            authorityID: configurationAuthorityID
        )
        attachmentSource = UnavailableChatSessionAttachmentSource()
    }

    init(
        source: any CoachContextSnapshotPort,
        attachmentEvidenceSource: any ChatSessionAttachmentEvidenceSource,
        capacity: CoachContextCapacity = CoachContextCapacity(),
        configurationAuthorityID: UUID = UUID()
    ) {
        let configurationAuthority = CoachContextConfigurationAuthority(
            source: source,
            authorityID: configurationAuthorityID
        )
        self.source = source
        self.capacity = capacity
        self.configurationAuthority = configurationAuthority
        attachmentSource = ProjectedChatSessionAttachmentSource(
            evidenceSource: attachmentEvidenceSource,
            configurationAuthority: configurationAuthority
        )
    }

    func loadAttachmentCandidates(
        in library: LibraryScope
    ) async -> ChatAttachmentCatalogOutcome {
        await attachmentSource.loadCandidates(in: library)
    }

    func resolveAttachments(
        _ attachments: ChatAttachments,
        in library: LibraryScope
    ) async -> ChatAttachmentResolutionOutcome {
        await attachmentSource.resolve(attachments, in: library)
    }

    func quoteNewChatBoundToConfiguration(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> ConfigurationBoundChatCreationQuoteOutcome {
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
                return .available(
                    quote,
                    authority: ChatCreationQuoteAuthority(
                        context: snapshot.authority,
                        configuration: configurationAuthority.stamp(
                            for: snapshot.authority.configurationGeneration
                        )
                    )
                )
            } catch {
                return .unavailable(.invalidContext)
            }
        case .providerUnavailable:
            guard case let .configured(configuration) =
                await configurationAuthority
                    .currentAttachmentProjectionConfiguration()
            else {
                return .unavailable(.sourceUnavailable)
            }
            guard await configurationAuthority.isCurrent(configuration.stamp) else {
                return .unavailable(.staleState)
            }
            return .providerUnavailable(
                authority: ChatCreationQuoteAuthority(
                    context: nil,
                    configuration: configuration.stamp
                )
            )
        case .sourceUnavailable:
            return .unavailable(.sourceUnavailable)
        case .staleState:
            return .unavailable(.staleState)
        }
    }

    func isCurrentAttachmentConfiguration(
        _ stamp: CoachContextConfigurationStamp
    ) async -> Bool {
        await configurationAuthority.isCurrent(stamp)
    }

    func acquireNewChatCreationLease(
        _ authority: ChatCreationQuoteAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        guard configurationAuthority.owns(authority.configuration) else {
            return .stale
        }
        let sourceAuthority: CoachContextSourceLeaseAuthority
        if let context = authority.context {
            guard context.configurationGeneration == authority.configuration.generation else {
                return .stale
            }
            sourceAuthority = .snapshot(context)
        } else {
            sourceAuthority = .configuration(
                generation: authority.configuration.generation
            )
        }
        return await source.acquireAuthorityLease(sourceAuthority)
    }

    public func quoteNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> ChatCreationQuoteOutcome {
        switch await quoteNewChatBoundToConfiguration(request) {
        case let .available(quote, _):
            return .available(quote)
        case .providerUnavailable:
            return .unavailable(.providerUnavailable)
        case let .unavailable(reason):
            return .unavailable(reason)
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
}

/// Live fail-closed source used until a provider/model configuration is qualified.
struct UnavailableCoachContextSnapshotPort: CoachContextSnapshotPort {
    /// The locally qualified conservative projection remains usable while no
    /// provider transport is installed. Quote requests still report
    /// `providerUnavailable`; absence of this policy would fail the picker.
    private static let attachmentProjectionPolicy =
        try! CoachAttachmentProjectionPolicy(
            maximumInlineTranscriptTokens: 8_192,
            tokenEstimator: .utf8ByteUpperBound()
        )

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

    func currentAttachmentProjectionPolicy()
        async -> CoachAttachmentProjectionPolicyOutcome
    {
        .knownQualified(
            policy: Self.attachmentProjectionPolicy,
            configurationGeneration: 1
        )
    }

    func isCurrentConfiguration(_ configurationGeneration: UInt64) async -> Bool {
        configurationGeneration == 1
    }

    func acquireAuthorityLease(
        _ authority: CoachContextSourceLeaseAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        guard authority == .configuration(generation: 1) else { return .stale }
        return .acquired(CoachContextAuthorityLease())
    }
}
