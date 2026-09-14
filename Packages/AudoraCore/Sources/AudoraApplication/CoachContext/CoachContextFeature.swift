import AudoraDomain
import Foundation

public enum CoachContextRequestError: Error, Equatable, Sendable {
    case pendingDraftMismatch
    case notCapacityFailure
    case reconsiderationUnavailable
    case reconsiderationSourceMismatch
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

/// Exact Chat/Profile authority used to prepare one Reconsider Invocation.
/// Memory, history, and attachment evidence are resolved freshly by the snapshot
/// source; no Pending User Turn or synthetic Draft participates in this path.
struct CoachContextReconsiderRequest: Equatable, Sendable {
    let library: LibraryScope
    let chat: Chat
    let sourceEffect: ChatProfileEffect
    let reconsideration: ProfileReconsideration
    let basis: ProfileReconsiderationBasis
    let trigger: CoachContextReconsiderTrigger

    init(
        library: LibraryScope,
        aggregate: ChatAggregate,
        basis: ProfileReconsiderationBasis
    ) throws {
        guard let sourceEffect = aggregate.profileEffect,
              let reconsideration = aggregate.profileReconsideration
        else { throw CoachContextRequestError.reconsiderationUnavailable }
        guard aggregate.chat.id == basis.sourceChatID,
              sourceEffect == basis.sourceEffect,
              reconsideration.sourceEffectIdentity == sourceEffect.identity
        else { throw CoachContextRequestError.reconsiderationSourceMismatch }

        self.library = library
        chat = aggregate.chat
        self.sourceEffect = sourceEffect
        self.reconsideration = reconsideration
        self.basis = basis
        trigger = try CoachContextReconsiderTrigger(
            basis: basis,
            attachments: aggregate.chat.attachments
        )
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
    case reconsider(CoachContextReconsiderRequest)
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

extension CoachContextReconsiderRequest {
    var snapshotBinding: CoachContextSnapshotBinding { .reconsider(self) }
}

/// Internal-adapter value after current Profile, Memory, history, and evidence resolve.
/// It never crosses the product-facing CoachContextFeature interface.
enum CoachContextResolvedSnapshotError: Error, Equatable, Sendable {
    case profileProjectionMismatch
}

struct CoachContextResolvedSnapshot: Sendable {
    let input: CoachContextQuoteInput
    let configuration: CoachContextConfiguration
    let authority: CoachContextSnapshotAuthority
    let profileProjection: CoachProfileContextProjection

    var profileEvidence: CoachProfileEvidenceObligations {
        profileProjection.evidenceObligations
    }

    init(
        input: CoachContextQuoteInput,
        configuration: CoachContextConfiguration,
        authority: CoachContextSnapshotAuthority,
        profileProjection: CoachProfileContextProjection
    ) throws {
        guard input.profile == profileProjection.value,
              authority.profile == profileProjection.provenance
        else {
            throw CoachContextResolvedSnapshotError.profileProjectionMismatch
        }
        self.input = input
        self.configuration = configuration
        self.authority = authority
        self.profileProjection = profileProjection
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

    init(release: @escaping @Sendable () async -> Void) {
        releaseAction = release
    }

    func release() async {
        guard let action = releaseAction else { return }
        releaseAction = nil
        await action()
    }

    /// Transfers cleanup to a task that owns only this one-shot lease. Callers
    /// can publish their terminal result without inheriting adapter release latency.
    nonisolated func releaseDetached() {
        let ownedLease = self
        Task.detached { await ownedLease.release() }
    }
}

enum CoachContextAuthorityLeaseOutcome: Sendable {
    case acquired(CoachContextAuthorityLease)
    case stale
}

/// The one provider/model configuration currently qualified for this app
/// process. A provider can be temporarily unavailable while this complete
/// deterministic capacity authority remains known.
enum CoachQualifiedConfigurationOutcome: Sendable {
    case knownQualified(
        configuration: CoachContextConfiguration,
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

    func resolveReconsider(
        _ request: CoachContextReconsiderRequest
    ) async -> CoachContextSnapshotOutcome

    /// Revalidates the exact external-context and provider-configuration
    /// generations after deterministic measurement completes.
    func isCurrent(_ authority: CoachContextSnapshotAuthority) async -> Bool

    /// Reads the same configuration generation used by quote and final
    /// preparation. Attachment projection must never capture a parallel policy.
    func currentQualifiedConfiguration()
        async -> CoachQualifiedConfigurationOutcome

    func isCurrentConfiguration(_ configurationGeneration: UInt64) async -> Bool

    /// Acquires an opaque lease only while the exact snapshot/configuration
    /// authority is current. Mutable adapters must defer generation advancement
    /// until the returned lease is released.
    func acquireAuthorityLease(
        _ authority: CoachContextSourceLeaseAuthority
    ) async -> CoachContextAuthorityLeaseOutcome
}

/// Explicit fail-closed opt-in for snapshot sources that cannot resolve the
/// Profile Reconsideration context.
protocol ProfileReconsiderationUnavailableCoachContextSnapshotPort:
    CoachContextSnapshotPort
{}

extension CoachContextSnapshotPort {
    func currentQualifiedConfiguration()
        async -> CoachQualifiedConfigurationOutcome
    {
        .unavailable
    }

    func isCurrentConfiguration(_ configurationGeneration: UInt64) async -> Bool {
        false
    }

}

extension ProfileReconsiderationUnavailableCoachContextSnapshotPort {
    func resolveReconsider(
        _ request: CoachContextReconsiderRequest
    ) async -> CoachContextSnapshotOutcome {
        .sourceUnavailable
    }
}

struct CoachAttachmentProjectionConfiguration: Sendable {
    let configuration: CoachContextConfiguration
    let stamp: CoachContextConfigurationStamp

    var policy: CoachAttachmentProjectionPolicy {
        configuration.policy.attachmentProjectionPolicy
    }
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
        switch await source.currentQualifiedConfiguration() {
        case let .knownQualified(configuration, configurationGeneration):
            return .configured(
                CoachAttachmentProjectionConfiguration(
                    configuration: configuration,
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
    case externalProcessingDisallowed
    case externalProcessingPolicyUnavailable
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

enum CoachContextReconsiderPreparationOutcome: Equatable, Sendable {
    case prepared(PreparedCoachLaunchContext)
    case cannotFit(CoachContextCapacityFailure)
    case unavailable(CoachContextUnavailableReason)
}

enum ConfigurationBoundChatCreationQuoteOutcome: Equatable, Sendable {
    case available(
        ChatCreationQuote,
        authority: ChatCreationQuoteAuthority
    )
    case providerUnavailable(
        ChatCreationCapacityLowerBound,
        authority: ChatCreationQuoteAuthority
    )
    case unavailable(CoachContextUnavailableReason)
}

struct ChatCreationQuoteAuthority: Equatable, Sendable {
    let context: CoachContextSnapshotAuthority?
    let configuration: CoachContextConfigurationStamp
    let evidence: ChatCreationEvidenceAuthority

    init(
        context: CoachContextSnapshotAuthority? = nil,
        configuration: CoachContextConfigurationStamp,
        evidence: ChatCreationEvidenceAuthority
    ) {
        self.context = context
        self.configuration = configuration
        self.evidence = evidence
    }
}

/// Exact bytes plus the identity/configuration fence required by Invocation
/// admission. This module does not invoke a provider.
struct PreparedCoachLaunchContext: Equatable, Sendable {
    let quote: CoachContextQuote
    let exchange: CanonicalCoachExchange
    let providerBinding: CoachProviderConfigurationBinding
    let authority: CoachContextSnapshotAuthority

    init(
        measured: MeasuredCoachLaunchContext,
        providerBinding: CoachProviderConfigurationBinding,
        authority: CoachContextSnapshotAuthority
    ) {
        quote = measured.quote
        exchange = measured.exchange
        self.providerBinding = providerBinding
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

/// Application-internal preflight seam. Its exact serialized exchange is consumed
/// by the Invocation admission coordinator without provider-side reconstruction.
protocol CoachContextPendingPreparing: Sendable {
    func preparePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextPendingPreparationOutcome

    func prepareReconsider(
        _ request: CoachContextReconsiderRequest
    ) async -> CoachContextReconsiderPreparationOutcome

    /// Final generation fence used after durable admission/Invocation install and
    /// immediately before provider launch.
    func isPreparedContextCurrent(
        _ prepared: PreparedCoachLaunchContext
    ) async -> Bool
}

/// Explicit fail-closed opt-in for coordinators that cannot prepare Profile
/// Reconsideration launches.
protocol ProfileReconsiderationUnavailableCoachContextPreparing:
    CoachContextPendingPreparing
{}

extension ProfileReconsiderationUnavailableCoachContextPreparing {
    func prepareReconsider(
        _ request: CoachContextReconsiderRequest
    ) async -> CoachContextReconsiderPreparationOutcome {
        .unavailable(.sourceUnavailable)
    }
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
    private let attachmentCapacityPreparer: any ChatAttachmentCapacityPreparing
    private let externalProcessingAuthorizer: CoachExternalProcessingAuthorizer

    /// Live composition fails closed until one complete provider configuration
    /// and its transport have passed qualification.
    public init() {
        let source = UnavailableCoachContextSnapshotPort()
        self.source = source
        capacity = CoachContextCapacity()
        configurationAuthority = CoachContextConfigurationAuthority(source: source)
        attachmentSource = MissingQualifiedConfigurationChatSessionAttachmentSource()
        attachmentCapacityPreparer = UnavailableChatAttachmentCapacityPreparer()
        externalProcessingAuthorizer = CoachExternalProcessingAuthorizer()
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
        let projectedAttachmentSource = ProjectedChatSessionAttachmentSource(
            evidenceSource: attachmentEvidenceSource,
            configurationAuthority: configurationAuthority
        )
        attachmentSource = projectedAttachmentSource
        attachmentCapacityPreparer = projectedAttachmentSource
        externalProcessingAuthorizer = CoachExternalProcessingAuthorizer(
            sourceIfAvailable:
                attachmentEvidenceSource as? any CoachEvidenceUsePolicySource
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
        attachmentCapacityPreparer = UnavailableChatAttachmentCapacityPreparer()
        externalProcessingAuthorizer = CoachExternalProcessingAuthorizer()
    }

    /// Internal dependency-complete initializer used by focused adapters and
    /// tests. No attachment authority or evidence is synthesized here.
    init(
        source: any CoachContextSnapshotPort,
        attachmentCapacityPreparer: any ChatAttachmentCapacityPreparing,
        evidenceUsePolicySource: (any CoachEvidenceUsePolicySource)? = nil,
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
        self.attachmentCapacityPreparer = attachmentCapacityPreparer
        externalProcessingAuthorizer = CoachExternalProcessingAuthorizer(
            sourceIfAvailable: evidenceUsePolicySource
        )
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
        let projectedAttachmentSource = ProjectedChatSessionAttachmentSource(
            evidenceSource: attachmentEvidenceSource,
            configurationAuthority: configurationAuthority
        )
        attachmentSource = projectedAttachmentSource
        attachmentCapacityPreparer = projectedAttachmentSource
        externalProcessingAuthorizer = CoachExternalProcessingAuthorizer(
            sourceIfAvailable:
                attachmentEvidenceSource as? any CoachEvidenceUsePolicySource
        )
    }

    init(
        source: any CoachContextSnapshotPort,
        evidenceUsePolicySource: any CoachEvidenceUsePolicySource,
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
        attachmentCapacityPreparer = UnavailableChatAttachmentCapacityPreparer()
        externalProcessingAuthorizer = CoachExternalProcessingAuthorizer(
            source: evidenceUsePolicySource
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
        let preparedAttachments: [PreparedCoachAttachment]
        let preparedConfiguration: CoachContextConfigurationStamp
        let evidenceAuthority: ChatCreationEvidenceAuthority
        switch await attachmentCapacityPreparer.prepareCapacityAttachments(
            request.attachments,
            in: request.library
        ) {
        case let .prepared(prepared, configuration, authority):
            preparedAttachments = prepared
            preparedConfiguration = configuration
            evidenceAuthority = authority
        case .configurationChanged:
            return .unavailable(.staleState)
        case .qualifiedConfigurationUnavailable:
            return .unavailable(.sourceUnavailable)
        case .attachmentUnavailable:
            return .unavailable(.invalidContext)
        case .externalProcessingDisallowed:
            return .unavailable(.externalProcessingDisallowed)
        case .invalidContext:
            return .unavailable(.invalidContext)
        case .failed:
            return .unavailable(.sourceUnavailable)
        }
        switch await source.resolveNewChat(request) {
        case let .resolved(snapshot):
            guard snapshot.authority.binding == request.snapshotBinding,
                  snapshot.input.trigger == .chatCreation(request.creation),
                  snapshot.input.attachments == preparedAttachments
            else {
                return .unavailable(.staleState)
            }
            if let reason = await externalProcessingAuthorizer.unavailableReason(
                for: snapshot.profileEvidence,
                in: request.library
            ) {
                return .unavailable(reason)
            }
            let configuration = configurationAuthority.stamp(
                for: snapshot.authority.configurationGeneration
            )
            guard configuration == preparedConfiguration else {
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
                        configuration: configuration,
                        evidence: evidenceAuthority
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
            guard preparedConfiguration == configuration.stamp else {
                return .unavailable(.staleState)
            }
            guard await configurationAuthority.isCurrent(configuration.stamp) else {
                return .unavailable(.staleState)
            }
            do {
                return .providerUnavailable(
                    try capacity.lowerBoundNewChat(
                        creation: request.creation,
                        attachments: preparedAttachments,
                        configuration: configuration.configuration
                    ),
                    authority: ChatCreationQuoteAuthority(
                        context: nil,
                        configuration: configuration.stamp,
                        evidence: evidenceAuthority
                    )
                )
            } catch {
                return .unavailable(.invalidContext)
            }
        case .sourceUnavailable:
            return .unavailable(.sourceUnavailable)
        case .staleState:
            return .unavailable(.staleState)
        }
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
            if let reason = await externalProcessingAuthorizer.unavailableReason(
                for: snapshot.profileEvidence,
                in: request.library
            ) {
                return .unavailable(reason)
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
            if let reason = await externalProcessingAuthorizer.unavailableReason(
                for: snapshot.profileEvidence,
                in: request.library
            ) {
                return .unavailable(reason)
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
                        providerBinding: snapshot.configuration.providerBinding,
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

    func prepareReconsider(
        _ request: CoachContextReconsiderRequest
    ) async -> CoachContextReconsiderPreparationOutcome {
        switch await source.resolveReconsider(request) {
        case let .resolved(snapshot):
            guard snapshot.authority.binding == request.snapshotBinding,
                  snapshot.authority.profile ==
                    request.basis.latestProfile.provenance,
                  snapshot.profileProjection == CoachProfileContextProjection(
                    snapshot: request.basis.latestProfile,
                    attachments: request.chat.attachments
                  ),
                  snapshot.input.trigger ==
                    .reconsiderProfileChange(request.trigger)
            else {
                return .unavailable(.staleState)
            }
            if let reason = await externalProcessingAuthorizer.unavailableReason(
                for: snapshot.profileEvidence,
                in: request.library
            ) {
                return .unavailable(reason)
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
                        providerBinding: snapshot.configuration.providerBinding,
                        authority: snapshot.authority
                    )
                )
            } catch let error as CoachContextPreparationError {
                switch error {
                case .messageTooLong:
                    return .unavailable(.invalidContext)
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
struct UnavailableCoachContextSnapshotPort:
    ProfileReconsiderationUnavailableCoachContextSnapshotPort
{
    init() {}

    func resolveNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        .sourceUnavailable
    }

    func resolveChat(
        _ request: CoachContextChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        .sourceUnavailable
    }

    func resolvePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextSnapshotOutcome {
        .sourceUnavailable
    }

    func isCurrent(_ authority: CoachContextSnapshotAuthority) async -> Bool {
        false
    }

    func acquireAuthorityLease(
        _ authority: CoachContextSourceLeaseAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        .stale
    }
}
