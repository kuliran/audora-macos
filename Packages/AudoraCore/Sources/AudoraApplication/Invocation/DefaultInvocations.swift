import AudoraDomain
import Foundation

public struct PendingCoachInvocationRequest: Equatable, Hashable, Sendable {
    public let library: LibraryScope
    public let chatID: ChatID
    public let pendingUserTurnID: PendingUserTurnID

    public init(
        library: LibraryScope,
        chatID: ChatID,
        pendingUserTurnID: PendingUserTurnID
    ) {
        self.library = library
        self.chatID = chatID
        self.pendingUserTurnID = pendingUserTurnID
    }
}

public enum ProfileReconsiderationInvocationRequestError:
    Error,
    Equatable,
    Sendable
{
    case sourceEffectMismatch
    case reconsiderationAlreadyExists
    case reconsiderationMissing
    case resultPositionMismatch
    case retryFailureRequired
    case chatBusy
}

/// Stable durable identity of one Chat-owned Reconsider intent. Unlike an
/// answer Invocation it never names a Pending User Turn or Draft.
public struct ProfileReconsiderationInvocationRequest: Equatable, Sendable {
    public let library: LibraryScope
    public let chatID: ChatID
    public let sourceEffectIdentity: ChatProfileEffectIdentity
    public let resultResponsePositionID: ChatResponsePositionID

    public init(
        library: LibraryScope,
        chatID: ChatID,
        sourceEffectIdentity: ChatProfileEffectIdentity,
        resultResponsePositionID: ChatResponsePositionID
    ) {
        self.library = library
        self.chatID = chatID
        self.sourceEffectIdentity = sourceEffectIdentity
        self.resultResponsePositionID = resultResponsePositionID
    }
}

/// One newly requested Reconsider operation before its sidecar is installed.
/// Persistence owns the atomic sidecar installation and Library liveness claim.
public struct NewProfileReconsiderationInvocationRequest: Equatable, Sendable {
    public let library: LibraryScope
    public let observedAggregate: ChatAggregate
    public let reconsideration: ProfileReconsideration
    public let basis: ProfileReconsiderationBasis

    public init(
        library: LibraryScope,
        observedAggregate: ChatAggregate,
        reconsideration: ProfileReconsideration,
        basis: ProfileReconsiderationBasis
    ) throws {
        guard observedAggregate.profileEffect == basis.sourceEffect,
              observedAggregate.chat.id == basis.sourceChatID,
              reconsideration.sourceEffectIdentity == basis.sourceEffect.identity
        else {
            throw ProfileReconsiderationInvocationRequestError
                .sourceEffectMismatch
        }
        guard observedAggregate.profileReconsideration == nil else {
            throw ProfileReconsiderationInvocationRequestError
                .reconsiderationAlreadyExists
        }
        guard observedAggregate.pendingUserTurn == nil else {
            throw ProfileReconsiderationInvocationRequestError.chatBusy
        }
        guard reconsideration.failure == nil else {
            throw ProfileReconsiderationInvocationRequestError
                .retryFailureRequired
        }
        _ = try ChatAggregate(
            chat: observedAggregate.chat,
            memory: observedAggregate.memory,
            messages: observedAggregate.messages,
            profileEffect: basis.sourceEffect,
            profileReconsideration: reconsideration
        )
        self.library = library
        self.observedAggregate = observedAggregate
        self.reconsideration = reconsideration
        self.basis = basis
    }

    public var request: ProfileReconsiderationInvocationRequest {
        ProfileReconsiderationInvocationRequest(
            library: library,
            chatID: observedAggregate.chat.id,
            sourceEffectIdentity: reconsideration.sourceEffectIdentity,
            resultResponsePositionID: reconsideration.resultResponsePositionID
        )
    }
}

/// A user Retry over one exact failed sidecar and a freshly assessed stale basis.
public struct RetryProfileReconsiderationInvocationRequest: Equatable, Sendable {
    public let library: LibraryScope
    public let observedAggregate: ChatAggregate
    public let basis: ProfileReconsiderationBasis

    public init(
        library: LibraryScope,
        observedAggregate: ChatAggregate,
        basis: ProfileReconsiderationBasis
    ) throws {
        guard observedAggregate.profileEffect == basis.sourceEffect,
              observedAggregate.chat.id == basis.sourceChatID
        else {
            throw ProfileReconsiderationInvocationRequestError
                .sourceEffectMismatch
        }
        guard let reconsideration = observedAggregate.profileReconsideration else {
            throw ProfileReconsiderationInvocationRequestError
                .reconsiderationMissing
        }
        guard reconsideration.sourceEffectIdentity == basis.sourceEffect.identity
        else {
            throw ProfileReconsiderationInvocationRequestError
                .sourceEffectMismatch
        }
        guard reconsideration.failure != nil else {
            throw ProfileReconsiderationInvocationRequestError
                .retryFailureRequired
        }
        guard observedAggregate.pendingUserTurn == nil else {
            throw ProfileReconsiderationInvocationRequestError.chatBusy
        }
        self.library = library
        self.observedAggregate = observedAggregate
        self.basis = basis
    }

    public var request: ProfileReconsiderationInvocationRequest {
        let reconsideration = observedAggregate.profileReconsideration!
        return ProfileReconsiderationInvocationRequest(
            library: library,
            chatID: observedAggregate.chat.id,
            sourceEffectIdentity: reconsideration.sourceEffectIdentity,
            resultResponsePositionID: reconsideration.resultResponsePositionID
        )
    }
}

/// Opaque one-shot capability proving that persistence installed the exact new
/// Reconsider sidecar while retaining its Library-wide liveness lease.
public struct PreparedProfileReconsiderationInvocation: Equatable, Sendable {
    public let request: ProfileReconsiderationInvocationRequest
    public let aggregate: ChatAggregate
    public let basis: ProfileReconsiderationBasis
    fileprivate let capabilityID: UUID

    fileprivate init(
        authority: InvocationProfileReconsiderationAuthority,
        capabilityID: UUID = UUID()
    ) {
        request = authority.request
        aggregate = authority.aggregate
        basis = authority.basis
        self.capabilityID = capabilityID
    }

    init(preparing newRequest: NewProfileReconsiderationInvocationRequest)
        throws
    {
        let aggregate = try ChatAggregate(
            chat: newRequest.observedAggregate.chat,
            memory: newRequest.observedAggregate.memory,
            messages: newRequest.observedAggregate.messages,
            profileEffect: newRequest.observedAggregate.profileEffect,
            profileReconsideration: newRequest.reconsideration
        )
        self.init(
            authority: try InvocationProfileReconsiderationAuthority(
                request: newRequest.request,
                aggregate: aggregate,
                basis: newRequest.basis
            )
        )
    }
}

public enum NewProfileReconsiderationInvocationOutcome: Equatable, Sendable {
    case prepared(PreparedProfileReconsiderationInvocation)
    case stale(ChatAggregate)
    case frozen(FrozenChatSnapshot)
    case readOnlyLibrary
    case activeInvocation
    case failed
}

public enum NewPendingCoachInvocationRequestError: Error, Equatable, Sendable {
    case pendingAlreadyExists
    case draftMismatch
    case failedPending
}

/// One exact new-Send intent observed by Chat before Invocation persistence
/// acquires Library-wide liveness. Persistence installs this Pending only while
/// it owns that liveness namespace.
public struct NewPendingCoachInvocationRequest: Equatable, Sendable {
    public let library: LibraryScope
    public let observedAggregate: ChatAggregate
    public let pendingUserTurn: PendingUserTurn

    public init(
        library: LibraryScope,
        observedAggregate: ChatAggregate,
        pendingUserTurn: PendingUserTurn
    ) throws {
        guard observedAggregate.pendingUserTurn == nil else {
            throw NewPendingCoachInvocationRequestError.pendingAlreadyExists
        }
        guard pendingUserTurn.draftID == observedAggregate.chat.draft.draftID,
              pendingUserTurn.draftVersion == observedAggregate.chat.draft.version
        else {
            throw NewPendingCoachInvocationRequestError.draftMismatch
        }
        guard pendingUserTurn.failure == nil else {
            throw NewPendingCoachInvocationRequestError.failedPending
        }
        self.library = library
        self.observedAggregate = observedAggregate
        self.pendingUserTurn = pendingUserTurn
    }

    public var chatID: ChatID { observedAggregate.chat.id }

    var lockMutation: LockPendingUserTurnMutation {
        LockPendingUserTurnMutation(
            library: library,
            chatID: chatID,
            pendingUserTurn: pendingUserTurn
        )
    }
}

/// Opaque, one-shot Application capability proving that persistence installed
/// the exact Pending while retaining its Library and Pending-file authority.
public struct PreparedPendingCoachInvocation: Equatable, Sendable {
    public let request: PendingCoachInvocationRequest
    public let aggregate: ChatAggregate
    fileprivate let capabilityID: UUID

    fileprivate init(
        authority: InvocationPendingAuthority,
        capabilityID: UUID = UUID()
    ) {
        request = authority.request
        aggregate = authority.aggregate
        self.capabilityID = capabilityID
    }

    init(preparing newRequest: NewPendingCoachInvocationRequest) throws {
        let aggregate = try ChatAggregate(
            chat: newRequest.observedAggregate.chat,
            memory: newRequest.observedAggregate.memory,
            messages: newRequest.observedAggregate.messages,
            pendingUserTurn: newRequest.pendingUserTurn,
            profileProposal: newRequest.observedAggregate.profileProposal,
            profileEvidencePublication:
                newRequest.observedAggregate.profileEvidencePublication
        )
        let request = PendingCoachInvocationRequest(
            library: newRequest.library,
            chatID: newRequest.chatID,
            pendingUserTurnID: newRequest.pendingUserTurn.id
        )
        self.init(
            authority: try InvocationPendingAuthority(
                request: request,
                aggregate: aggregate
            )
        )
    }
}

public enum NewPendingCoachInvocationOutcome: Equatable, Sendable {
    case prepared(PreparedPendingCoachInvocation)
    case stale(ChatAggregate)
    case frozen(FrozenChatSnapshot)
    case readOnlyLibrary
    case activeInvocation
    case failed
}

public enum InvocationRejectionReason: Equatable, Sendable {
    case eligibilityChanged
    case activeInvocation
    case messageMustBeShortened(maximumUTF8Bytes: Int)
    case contextUnavailable(CoachContextUnavailableReason)
    case contextChanged
    case admissionCooldown
    case clockRollback
    case admissionLedgerFull
    case admissionUnavailable
    case persistenceUnavailable
    case identityCollisionExhausted(lastCollision: InvocationLaunchIdentityCollision)
}

public enum InvocationInterruptionReason: Equatable, Sendable {
    case providerFailed
    case invalidProviderResponse
    case retryInfrastructureFailed
    case publicationConflict
    case persistenceUnavailable
}

public enum InvocationTryOutcome: Equatable, Sendable {
    case published(ChatAggregate, CoachContextQuote)
    case contextCapacityFailure(ChatAggregate, CoachContextQuote)
    case rejected(ChatAggregate?, InvocationRejectionReason)
    case interrupted(ChatAggregate?, InvocationInterruptionReason)
    /// Persistence could not prove a terminal write. The aggregate is only the
    /// last observed durable snapshot; this exact request is the Application's
    /// transient authority for presenting a safe Retry without fabricating a
    /// persisted Pending failure.
    case operationallyInterrupted(
        ChatAggregate?,
        PendingCoachInvocationRequest,
        InvocationInterruptionReason
    )
    /// The exact Stop capability won. The Stop caller owns terminal state
    /// publication; the original Invocation continuation must have no effect.
    case stopped
    /// Transcript access terminated the Attempt and provider absence could not
    /// yet be proven. The Application must retain this exact process-live
    /// authority until a later Stop confirms reaping.
    case providerReapPending(InvocationStopAuthority)
}

public enum ProfileReconsiderationInvocationTryOutcome: Equatable, Sendable {
    case published(ChatAggregate, CoachContextQuote)
    /// Successful zero-effect replacement. Presentation uses this exact result
    /// for the transient "Suggestion is no longer relevant" notice.
    case withdrawn(ChatAggregate, CoachContextQuote)
    case contextCapacityFailure(ChatAggregate, CoachContextQuote)
    case rejected(ChatAggregate?, InvocationRejectionReason)
    case interrupted(ChatAggregate?, InvocationInterruptionReason)
    case operationallyInterrupted(
        ChatAggregate?,
        ProfileReconsiderationInvocationRequest,
        InvocationInterruptionReason
    )
    case stopped
    case providerReapPending(ProfileReconsiderationInvocationStopAuthority)
}

public enum InvocationAdmissionAvailability: Equatable, Sendable {
    case available
    case cooldown(reopensAt: UTCInstant)
    case unavailable
}

public struct StopCoachInvocationRequest: Equatable, Sendable {
    public let library: LibraryScope
    public let chatID: ChatID
    public let pendingUserTurnID: PendingUserTurnID

    public init(
        library: LibraryScope,
        chatID: ChatID,
        pendingUserTurnID: PendingUserTurnID
    ) {
        self.library = library
        self.chatID = chatID
        self.pendingUserTurnID = pendingUserTurnID
    }
}

/// Opaque, process-live authority for stopping one exact Provider Attempt.
/// A replacement Attempt always receives a different capability.
public struct InvocationStopAuthority: Equatable, Sendable {
    public let library: LibraryScope
    public let chatID: ChatID
    public let pendingUserTurnID: PendingUserTurnID
    public let invocationID: CoachInvocationID
    public let attemptID: CoachProviderAttemptID
    fileprivate let capabilityID: UUID

    fileprivate init(
        request: StopCoachInvocationRequest,
        invocationID: CoachInvocationID,
        attemptID: CoachProviderAttemptID,
        capabilityID: UUID = UUID()
    ) {
        library = request.library
        chatID = request.chatID
        pendingUserTurnID = request.pendingUserTurnID
        self.invocationID = invocationID
        self.attemptID = attemptID
        self.capabilityID = capabilityID
    }

    @_spi(InvocationTesting)
    public init(
        testingRequest request: StopCoachInvocationRequest,
        invocationID: CoachInvocationID,
        attemptID: CoachProviderAttemptID,
        capabilityID: UUID
    ) {
        self.init(
            request: request,
            invocationID: invocationID,
            attemptID: attemptID,
            capabilityID: capabilityID
        )
    }

    fileprivate func matches(_ request: StopCoachInvocationRequest) -> Bool {
        library == request.library &&
            chatID == request.chatID &&
            pendingUserTurnID == request.pendingUserTurnID
    }
}

public enum InvocationStopOutcome: Equatable, Sendable {
    case interrupted(ChatAggregate)
    case staleAuthority
    case noActiveInvocation
    case unableToReap
    case persistenceUnavailable(ChatAggregate?)
}

public struct StopProfileReconsiderationInvocationRequest: Equatable, Sendable {
    public let library: LibraryScope
    public let chatID: ChatID
    public let sourceEffectIdentity: ChatProfileEffectIdentity
    public let resultResponsePositionID: ChatResponsePositionID

    public init(
        library: LibraryScope,
        chatID: ChatID,
        sourceEffectIdentity: ChatProfileEffectIdentity,
        resultResponsePositionID: ChatResponsePositionID
    ) {
        self.library = library
        self.chatID = chatID
        self.sourceEffectIdentity = sourceEffectIdentity
        self.resultResponsePositionID = resultResponsePositionID
    }

    public init(_ request: ProfileReconsiderationInvocationRequest) {
        self.init(
            library: request.library,
            chatID: request.chatID,
            sourceEffectIdentity: request.sourceEffectIdentity,
            resultResponsePositionID: request.resultResponsePositionID
        )
    }
}

/// Exact process-live authority for stopping one Reconsider provider Attempt.
/// It cannot be substituted for answer Stop authority or a replacement Attempt.
public struct ProfileReconsiderationInvocationStopAuthority:
    Equatable,
    Sendable
{
    public let library: LibraryScope
    public let chatID: ChatID
    public let sourceEffectIdentity: ChatProfileEffectIdentity
    public let resultResponsePositionID: ChatResponsePositionID
    public let invocationID: CoachInvocationID
    public let attemptID: CoachProviderAttemptID
    fileprivate let capabilityID: UUID

    fileprivate init(
        request: StopProfileReconsiderationInvocationRequest,
        invocationID: CoachInvocationID,
        attemptID: CoachProviderAttemptID,
        capabilityID: UUID = UUID()
    ) {
        library = request.library
        chatID = request.chatID
        sourceEffectIdentity = request.sourceEffectIdentity
        resultResponsePositionID = request.resultResponsePositionID
        self.invocationID = invocationID
        self.attemptID = attemptID
        self.capabilityID = capabilityID
    }

    @_spi(InvocationTesting)
    public init(
        testingRequest request: StopProfileReconsiderationInvocationRequest,
        invocationID: CoachInvocationID,
        attemptID: CoachProviderAttemptID,
        capabilityID: UUID
    ) {
        self.init(
            request: request,
            invocationID: invocationID,
            attemptID: attemptID,
            capabilityID: capabilityID
        )
    }

    fileprivate func matches(
        _ request: StopProfileReconsiderationInvocationRequest
    ) -> Bool {
        library == request.library &&
            chatID == request.chatID &&
            sourceEffectIdentity == request.sourceEffectIdentity &&
            resultResponsePositionID == request.resultResponsePositionID
    }
}

public enum ProfileReconsiderationInvocationStopOutcome: Equatable, Sendable {
    case interrupted(ChatAggregate)
    case staleAuthority
    case noActiveInvocation
    case unableToReap
    case persistenceUnavailable(ChatAggregate?)
}

public typealias ProfileReconsiderationInvocationStopAuthorityObserver =
    @Sendable (ProfileReconsiderationInvocationStopAuthority) async -> Void

public typealias InvocationStopAuthorityObserver =
    @Sendable (InvocationStopAuthority) async -> Void

public protocol Invocations: Sendable {
    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability

    func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome

    func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome

    func tryInvoke(_ request: PendingCoachInvocationRequest) async -> InvocationTryOutcome

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation,
        observingStopAuthority observer: @escaping InvocationStopAuthorityObserver
    ) async -> InvocationTryOutcome

    func tryInvoke(
        _ request: PendingCoachInvocationRequest,
        observingStopAuthority observer: @escaping InvocationStopAuthorityObserver
    ) async -> InvocationTryOutcome

    func stop(
        _ request: StopCoachInvocationRequest,
        authority: InvocationStopAuthority
    ) async -> InvocationStopOutcome

    func prepareNewProfileReconsiderationInvocation(
        _ request: NewProfileReconsiderationInvocationRequest
    ) async -> NewProfileReconsiderationInvocationOutcome

    func abandonPreparedProfileReconsiderationInvocation(
        _ prepared: PreparedProfileReconsiderationInvocation
    ) async

    func tryReconsiderProfileChange(
        _ prepared: PreparedProfileReconsiderationInvocation
    ) async -> ProfileReconsiderationInvocationTryOutcome

    func tryReconsiderProfileChange(
        _ request: RetryProfileReconsiderationInvocationRequest
    ) async -> ProfileReconsiderationInvocationTryOutcome

    func tryReconsiderProfileChange(
        _ request: ProfileReconsiderationInvocationRequest
    ) async -> ProfileReconsiderationInvocationTryOutcome

    func tryReconsiderProfileChange(
        _ prepared: PreparedProfileReconsiderationInvocation,
        observingStopAuthority observer:
            @escaping ProfileReconsiderationInvocationStopAuthorityObserver
    ) async -> ProfileReconsiderationInvocationTryOutcome

    func tryReconsiderProfileChange(
        _ request: RetryProfileReconsiderationInvocationRequest,
        observingStopAuthority observer:
            @escaping ProfileReconsiderationInvocationStopAuthorityObserver
    ) async -> ProfileReconsiderationInvocationTryOutcome

    func tryReconsiderProfileChange(
        _ request: ProfileReconsiderationInvocationRequest,
        observingStopAuthority observer:
            @escaping ProfileReconsiderationInvocationStopAuthorityObserver
    ) async -> ProfileReconsiderationInvocationTryOutcome

    func stopProfileReconsideration(
        _ request: StopProfileReconsiderationInvocationRequest,
        authority: ProfileReconsiderationInvocationStopAuthority
    ) async -> ProfileReconsiderationInvocationStopOutcome
}

/// Explicit fail-closed opt-in for adapters that do not expose Profile
/// Reconsideration. Capable gateways conform to `Invocations` directly and
/// implement the complete capability, including stop observers.
public protocol ProfileReconsiderationUnavailableInvocations: Invocations {}

public extension Invocations {
    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        .unavailable
    }

    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation,
        observingStopAuthority observer: @escaping InvocationStopAuthorityObserver
    ) async -> InvocationTryOutcome {
        await tryInvoke(prepared)
    }

    func tryInvoke(
        _ request: PendingCoachInvocationRequest,
        observingStopAuthority observer: @escaping InvocationStopAuthorityObserver
    ) async -> InvocationTryOutcome {
        await tryInvoke(request)
    }

    func stop(
        _ request: StopCoachInvocationRequest,
        authority: InvocationStopAuthority
    ) async -> InvocationStopOutcome {
        .noActiveInvocation
    }
}

public extension ProfileReconsiderationUnavailableInvocations {
    func prepareNewProfileReconsiderationInvocation(
        _ request: NewProfileReconsiderationInvocationRequest
    ) async -> NewProfileReconsiderationInvocationOutcome {
        .failed
    }

    func abandonPreparedProfileReconsiderationInvocation(
        _ prepared: PreparedProfileReconsiderationInvocation
    ) async {}

    func tryReconsiderProfileChange(
        _ prepared: PreparedProfileReconsiderationInvocation
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        .rejected(prepared.aggregate, .persistenceUnavailable)
    }

    func tryReconsiderProfileChange(
        _ request: RetryProfileReconsiderationInvocationRequest
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        .rejected(request.observedAggregate, .persistenceUnavailable)
    }

    func tryReconsiderProfileChange(
        _ request: ProfileReconsiderationInvocationRequest
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        .rejected(nil, .eligibilityChanged)
    }

    func tryReconsiderProfileChange(
        _ prepared: PreparedProfileReconsiderationInvocation,
        observingStopAuthority observer:
            @escaping ProfileReconsiderationInvocationStopAuthorityObserver
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        await tryReconsiderProfileChange(prepared)
    }

    func tryReconsiderProfileChange(
        _ request: RetryProfileReconsiderationInvocationRequest,
        observingStopAuthority observer:
            @escaping ProfileReconsiderationInvocationStopAuthorityObserver
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        await tryReconsiderProfileChange(request)
    }

    func tryReconsiderProfileChange(
        _ request: ProfileReconsiderationInvocationRequest,
        observingStopAuthority observer:
            @escaping ProfileReconsiderationInvocationStopAuthorityObserver
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        await tryReconsiderProfileChange(request)
    }

    func stopProfileReconsideration(
        _ request: StopProfileReconsiderationInvocationRequest,
        authority: ProfileReconsiderationInvocationStopAuthority
    ) async -> ProfileReconsiderationInvocationStopOutcome {
        .noActiveInvocation
    }
}

@_spi(InvocationInfrastructure)
public enum InvocationPendingAuthorityError: Error, Equatable, Sendable {
    case requestMismatch
    case missingPending
    case failedPending
    case draftMismatch
}

@_spi(InvocationInfrastructure)
public struct InvocationPendingAuthority: Equatable, Sendable {
    public let request: PendingCoachInvocationRequest
    public let aggregate: ChatAggregate
    public let pendingUserTurn: PendingUserTurn

    public init(
        request: PendingCoachInvocationRequest,
        aggregate: ChatAggregate
    ) throws {
        guard aggregate.chat.id == request.chatID else {
            throw InvocationPendingAuthorityError.requestMismatch
        }
        guard let pending = aggregate.pendingUserTurn,
              pending.id == request.pendingUserTurnID
        else {
            throw InvocationPendingAuthorityError.missingPending
        }
        guard pending.draftID == aggregate.chat.draft.draftID,
              pending.draftVersion == aggregate.chat.draft.version
        else {
            throw InvocationPendingAuthorityError.draftMismatch
        }
        self.request = request
        self.aggregate = aggregate
        pendingUserTurn = pending
    }
}

@_spi(InvocationInfrastructure)
public enum InvocationProfileReconsiderationAuthorityError:
    Error,
    Equatable,
    Sendable
{
    case requestMismatch
    case sourceEffectMismatch
    case missingReconsideration
    case resultPositionMismatch
    case pendingUserTurnPresent
}

/// Exact current aggregate + freshly assessed Profile basis held behind one
/// persistence liveness lease.
@_spi(InvocationInfrastructure)
public struct InvocationProfileReconsiderationAuthority:
    Equatable,
    Sendable
{
    public let request: ProfileReconsiderationInvocationRequest
    public let aggregate: ChatAggregate
    public let reconsideration: ProfileReconsideration
    public let basis: ProfileReconsiderationBasis

    public init(
        request: ProfileReconsiderationInvocationRequest,
        aggregate: ChatAggregate,
        basis: ProfileReconsiderationBasis
    ) throws {
        guard aggregate.chat.id == request.chatID,
              basis.sourceChatID == request.chatID
        else {
            throw InvocationProfileReconsiderationAuthorityError
                .requestMismatch
        }
        guard let sourceEffect = aggregate.profileEffect,
              sourceEffect == basis.sourceEffect,
              sourceEffect.identity == request.sourceEffectIdentity
        else {
            throw InvocationProfileReconsiderationAuthorityError
                .sourceEffectMismatch
        }
        guard let reconsideration = aggregate.profileReconsideration else {
            throw InvocationProfileReconsiderationAuthorityError
                .missingReconsideration
        }
        guard reconsideration.sourceEffectIdentity ==
                request.sourceEffectIdentity,
              reconsideration.resultResponsePositionID ==
                request.resultResponsePositionID
        else {
            throw InvocationProfileReconsiderationAuthorityError
                .resultPositionMismatch
        }
        guard aggregate.pendingUserTurn == nil else {
            throw InvocationProfileReconsiderationAuthorityError
                .pendingUserTurnPresent
        }
        self.request = request
        self.aggregate = aggregate
        self.reconsideration = reconsideration
        self.basis = basis
    }
}

@_spi(InvocationInfrastructure)
public enum InvocationProfileReconsiderationResolutionOutcome:
    Equatable,
    Sendable
{
    case eligible(InvocationProfileReconsiderationAuthority)
    case ineligible(ChatAggregate?)
    case unavailable
}

@_spi(InvocationInfrastructure)
public enum InvocationProfileReconsiderationSessionPreparationOutcome:
    Sendable
{
    case opened(any InvocationProfileReconsiderationPersistenceSession)
    case stale(ChatAggregate)
    case frozen(FrozenChatSnapshot)
    case readOnlyLibrary
    case blockedByActiveInvocation
    case unavailable
}

@_spi(InvocationInfrastructure)
public enum InvocationProfileReconsiderationSessionAcquisitionOutcome:
    Sendable
{
    case opened(any InvocationProfileReconsiderationPersistenceSession)
    case ineligible(ChatAggregate?)
    case blockedByActiveInvocation
    case unavailable
}

@_spi(InvocationInfrastructure)
public enum InvocationPendingResolutionOutcome: Equatable, Sendable {
    case eligible(InvocationPendingAuthority)
    case ineligible(ChatAggregate?)
    case unavailable
}

@_spi(InvocationInfrastructure)
public enum InvocationPendingAcquisitionOutcome: Equatable, Sendable {
    case acquired(InvocationPendingAuthority)
    case ineligible(ChatAggregate?)
    case activeExists
    case unavailable
}

@_spi(InvocationInfrastructure)
public enum InvocationPendingPreparationOutcome: Equatable, Sendable {
    case prepared(InvocationPendingAuthority)
    case stale(ChatAggregate)
    case frozen(FrozenChatSnapshot)
    case readOnlyLibrary
    case activeExists
    case unavailable
}

@_spi(InvocationInfrastructure)
public struct InvocationAttemptIdentity: Equatable, Sendable {
    public let attemptID: CoachProviderAttemptID
    public let idempotencyValue: ProviderIdempotencyValue
    public let userMessageID: ChatMessageID
    public let coachMessageID: ChatMessageID
    public let freshDraftID: ChatDraftID
    public let transcriptHandles: [PreparedCoachTranscriptHandle]

    public init(
        attemptID: CoachProviderAttemptID,
        idempotencyValue: ProviderIdempotencyValue,
        userMessageID: ChatMessageID,
        coachMessageID: ChatMessageID,
        freshDraftID: ChatDraftID,
        transcriptHandles: [PreparedCoachTranscriptHandle] = []
    ) {
        self.attemptID = attemptID
        self.idempotencyValue = idempotencyValue
        self.userMessageID = userMessageID
        self.coachMessageID = coachMessageID
        self.freshDraftID = freshDraftID
        self.transcriptHandles = transcriptHandles
    }

    func makeAttempt(
        ordinal: UInt8,
        kind: CoachProviderAttemptKind
    ) throws -> CoachProviderAttempt {
        try CoachProviderAttempt(
            id: attemptID,
            ordinal: ordinal,
            kind: kind,
            providerIdempotencyValue: idempotencyValue,
            transcriptHandles: transcriptHandles,
            publicationAuthority: try CoachProviderAttemptPublicationAuthority(
                userMessageID: userMessageID,
                coachMessageID: coachMessageID,
                freshDraftID: freshDraftID
            )
        )
    }
}

/// Fresh Attempt authority for Reconsider. It deliberately has no user-message
/// or fresh-Draft identity because neither artifact exists on this intent path.
@_spi(InvocationInfrastructure)
public struct InvocationProfileReconsiderationAttemptIdentity:
    Equatable,
    Sendable
{
    public let attemptID: CoachProviderAttemptID
    public let idempotencyValue: ProviderIdempotencyValue
    public let coachMessageID: ChatMessageID
    public let transcriptHandles: [PreparedCoachTranscriptHandle]

    public init(
        attemptID: CoachProviderAttemptID,
        idempotencyValue: ProviderIdempotencyValue,
        coachMessageID: ChatMessageID,
        transcriptHandles: [PreparedCoachTranscriptHandle] = []
    ) {
        self.attemptID = attemptID
        self.idempotencyValue = idempotencyValue
        self.coachMessageID = coachMessageID
        self.transcriptHandles = transcriptHandles
    }

    func makeAttempt(
        ordinal: UInt8,
        kind: CoachProviderAttemptKind
    ) throws -> CoachProviderAttempt {
        try CoachProviderAttempt(
            id: attemptID,
            ordinal: ordinal,
            kind: kind,
            providerIdempotencyValue: idempotencyValue,
            transcriptHandles: transcriptHandles,
            publicationAuthority: .reconsiderProfileChange(
                coachMessageID: coachMessageID
            )
        )
    }
}

@_spi(InvocationInfrastructure)
public struct InvocationLaunchIdentity: Equatable, Sendable {
    public let invocationID: CoachInvocationID
    public let attemptIdentity: InvocationAttemptIdentity

    public var attemptID: CoachProviderAttemptID { attemptIdentity.attemptID }
    public var idempotencyValue: ProviderIdempotencyValue {
        attemptIdentity.idempotencyValue
    }
    public var userMessageID: ChatMessageID { attemptIdentity.userMessageID }
    public var coachMessageID: ChatMessageID { attemptIdentity.coachMessageID }
    public var freshDraftID: ChatDraftID { attemptIdentity.freshDraftID }
    public var transcriptHandles: [PreparedCoachTranscriptHandle] {
        attemptIdentity.transcriptHandles
    }

    public init(
        invocationID: CoachInvocationID,
        attemptIdentity: InvocationAttemptIdentity
    ) {
        self.invocationID = invocationID
        self.attemptIdentity = attemptIdentity
    }

    public init(
        invocationID: CoachInvocationID,
        attemptID: CoachProviderAttemptID,
        idempotencyValue: ProviderIdempotencyValue,
        userMessageID: ChatMessageID,
        coachMessageID: ChatMessageID,
        freshDraftID: ChatDraftID
    ) {
        self.invocationID = invocationID
        attemptIdentity = InvocationAttemptIdentity(
            attemptID: attemptID,
            idempotencyValue: idempotencyValue,
            userMessageID: userMessageID,
            coachMessageID: coachMessageID,
            freshDraftID: freshDraftID
        )
    }
}

@_spi(InvocationInfrastructure)
public struct InvocationProfileReconsiderationLaunchIdentity:
    Equatable,
    Sendable
{
    public let invocationID: CoachInvocationID
    public let attemptIdentity: InvocationProfileReconsiderationAttemptIdentity

    public var attemptID: CoachProviderAttemptID {
        attemptIdentity.attemptID
    }

    public var idempotencyValue: ProviderIdempotencyValue {
        attemptIdentity.idempotencyValue
    }

    public var coachMessageID: ChatMessageID {
        attemptIdentity.coachMessageID
    }

    public var transcriptHandles: [PreparedCoachTranscriptHandle] {
        attemptIdentity.transcriptHandles
    }

    public init(
        invocationID: CoachInvocationID,
        attemptIdentity: InvocationProfileReconsiderationAttemptIdentity
    ) {
        self.invocationID = invocationID
        self.attemptIdentity = attemptIdentity
    }
}

@_spi(InvocationInfrastructure)
public protocol InvocationIdentityGenerating: Sendable {
    func generateInvocationID(at instant: UTCInstant) async -> CoachInvocationID

    func generateAttemptIdentity(
        at instant: UTCInstant,
        ordinal: UInt8,
        kind: CoachProviderAttemptKind,
        transcriptHandleCount: Int
    ) async -> InvocationAttemptIdentity

    func generateProfileReconsiderationAttemptIdentity(
        at instant: UTCInstant,
        ordinal: UInt8,
        kind: CoachProviderAttemptKind,
        transcriptHandleCount: Int
    ) async -> InvocationProfileReconsiderationAttemptIdentity
}

@_spi(InvocationInfrastructure)
public extension InvocationIdentityGenerating {
    /// Source-compatible fallback for identity stores that have not yet split
    /// answer and Reconsider allocation. Only the Reconsider-safe fields cross
    /// into durable or provider authority.
    func generateProfileReconsiderationAttemptIdentity(
        at instant: UTCInstant,
        ordinal: UInt8,
        kind: CoachProviderAttemptKind,
        transcriptHandleCount: Int
    ) async -> InvocationProfileReconsiderationAttemptIdentity {
        let legacy = await generateAttemptIdentity(
            at: instant,
            ordinal: ordinal,
            kind: kind,
            transcriptHandleCount: transcriptHandleCount
        )
        return InvocationProfileReconsiderationAttemptIdentity(
            attemptID: legacy.attemptID,
            idempotencyValue: legacy.idempotencyValue,
            coachMessageID: legacy.coachMessageID,
            transcriptHandles: legacy.transcriptHandles
        )
    }
}

public enum InvocationLaunchIdentityCollision: String, CaseIterable, Equatable, Sendable {
    case invocationID
    case attemptID
    case providerIdempotencyValue
    case userMessageID
    case coachMessageID
    case freshDraftID
    case transcriptHandle
}

@_spi(InvocationInfrastructure)
public enum InvocationLaunchIdentityAvailabilityOutcome: Equatable, Sendable {
    case available
    case collision(InvocationLaunchIdentityCollision)
    case stale(ChatAggregate?)
    case unavailable
}

@_spi(InvocationInfrastructure)
public struct InstallCoachInvocationMutation: Equatable, Sendable {
    public let authority: InvocationPendingAuthority
    public let invocation: CoachInvocation
    /// The exact Chat generation visible while the installed Invocation owns
    /// provider work. Retry clears a prior terminal descriptor before provider
    /// authority can escape; a first Send is already in this state.
    public let processingAggregate: ChatAggregate

    public init(
        authority: InvocationPendingAuthority,
        invocationID: CoachInvocationID,
        attemptIdentity: InvocationAttemptIdentity,
        preparedProfile: CoachProfileProvenance,
        admittedAt: UTCInstant
    ) throws {
        self.authority = authority
        processingAggregate = try ChatAggregate(
            chat: authority.aggregate.chat,
            memory: authority.aggregate.memory,
            messages: authority.aggregate.messages,
            pendingUserTurn: authority.pendingUserTurn.replacingFailure(nil),
            profileProposal: authority.aggregate.profileProposal,
            profileEvidencePublication:
                authority.aggregate.profileEvidencePublication
        )
        invocation = try CoachInvocation(
            id: invocationID,
            attempt: attemptIdentity.makeAttempt(ordinal: 1, kind: .standard),
            library: authority.request.library,
            chatID: authority.request.chatID,
            pendingUserTurn: authority.pendingUserTurn,
            preparedProfile: preparedProfile,
            expectedManifestRevision: authority.aggregate.chat.manifestRevision,
            admittedAt: admittedAt
        )
        try invocation.validate(against: authority.aggregate)
    }

    public init(
        authority: InvocationPendingAuthority,
        identity: InvocationLaunchIdentity,
        preparedProfile: CoachProfileProvenance,
        admittedAt: UTCInstant
    ) throws {
        try self.init(
            authority: authority,
            invocationID: identity.invocationID,
            attemptIdentity: identity.attemptIdentity,
            preparedProfile: preparedProfile,
            admittedAt: admittedAt
        )
    }
}

@_spi(InvocationInfrastructure)
public struct InstallProfileReconsiderationInvocationMutation:
    Equatable,
    Sendable
{
    public let authority: InvocationProfileReconsiderationAuthority
    public let invocation: CoachInvocation
    public let processingAggregate: ChatAggregate

    public init(
        authority: InvocationProfileReconsiderationAuthority,
        identity: InvocationProfileReconsiderationLaunchIdentity,
        preparedProfile: CoachProfileProvenance,
        admittedAt: UTCInstant
    ) throws {
        self.authority = authority
        let processingReconsideration = authority.reconsideration
            .replacingFailure(nil)
        processingAggregate = try ChatAggregate(
            chat: authority.aggregate.chat,
            memory: authority.aggregate.memory,
            messages: authority.aggregate.messages,
            profileEffect: authority.aggregate.profileEffect,
            profileReconsideration: processingReconsideration
        )
        invocation = try CoachInvocation(
            id: identity.invocationID,
            attempt: identity.attemptIdentity.makeAttempt(
                ordinal: 1,
                kind: .standard
            ),
            library: authority.request.library,
            chatID: authority.request.chatID,
            profileReconsideration: processingReconsideration,
            preparedProfile: preparedProfile,
            expectedManifestRevision:
                authority.aggregate.chat.manifestRevision,
            admittedAt: admittedAt
        )
        try invocation.validate(against: processingAggregate)
    }
}

@_spi(InvocationInfrastructure)
public enum InvocationInstallOutcome: Equatable, Sendable {
    case installed(CoachInvocation)
    case activeExists
    case stale(ChatAggregate?)
    case failed
}

@_spi(InvocationInfrastructure)
public enum InvocationPendingMutationOutcome: Equatable, Sendable {
    case committed(ChatAggregate)
    case stale(ChatAggregate?)
    case failed
}

@_spi(InvocationInfrastructure)
public enum InstallNextCoachProviderAttemptMutationError: Error, Equatable, Sendable {
    case identityCollision(InvocationLaunchIdentityCollision)
}

@_spi(InvocationInfrastructure)
public struct InstallNextCoachProviderAttemptMutation: Equatable, Sendable {
    public let base: CoachInvocation
    public let replacement: CoachInvocation

    public init(
        base: CoachInvocation,
        identity: InvocationAttemptIdentity,
        kind: CoachProviderAttemptKind
    ) throws {
        self.base = base
        let nextOrdinal = base.attempt.ordinal + 1
        let next = try identity.makeAttempt(ordinal: nextOrdinal, kind: kind)
        do {
            replacement = try base.installingAttempt(next)
        } catch let error as CoachInvocationAttemptInstallError {
            let collision: InvocationLaunchIdentityCollision = switch error {
            case .attemptIDCollision: .attemptID
            case .providerIdempotencyValueCollision: .providerIdempotencyValue
            case .userMessageIDCollision: .userMessageID
            case .coachMessageIDCollision: .coachMessageID
            case .freshDraftIDCollision: .freshDraftID
            case .transcriptHandleCollision: .transcriptHandle
            }
            throw InstallNextCoachProviderAttemptMutationError.identityCollision(
                collision
            )
        }
    }
}

@_spi(InvocationInfrastructure)
public struct InstallNextProfileReconsiderationAttemptMutation:
    Equatable,
    Sendable
{
    public let base: CoachInvocation
    public let replacement: CoachInvocation

    public init(
        base: CoachInvocation,
        identity: InvocationProfileReconsiderationAttemptIdentity,
        kind: CoachProviderAttemptKind
    ) throws {
        self.base = base
        let next = try identity.makeAttempt(
            ordinal: base.attempt.ordinal + 1,
            kind: kind
        )
        do {
            replacement = try base.installingAttempt(next)
        } catch let error as CoachInvocationAttemptInstallError {
            let collision: InvocationLaunchIdentityCollision = switch error {
            case .attemptIDCollision: .attemptID
            case .providerIdempotencyValueCollision: .providerIdempotencyValue
            case .userMessageIDCollision: .userMessageID
            case .coachMessageIDCollision: .coachMessageID
            case .freshDraftIDCollision: .freshDraftID
            case .transcriptHandleCollision: .transcriptHandle
            }
            throw InstallNextCoachProviderAttemptMutationError
                .identityCollision(collision)
        }
    }
}

@_spi(InvocationInfrastructure)
public enum InvocationNextAttemptInstallOutcome: Sendable {
    case installed(any InvocationActivePersistenceSession)
    case collision(InvocationLaunchIdentityCollision)
    case stale(ChatAggregate?)
    case failed
}

@_spi(InvocationInfrastructure)
public enum PublishCoachInvocationMutationError: Error, Equatable, Sendable {
    /// The validated batch contains state whose durable publication belongs to
    /// a later vertical slice. Publishing only its prose would be partial.
    case unsupportedResponseComponent
}

@_spi(InvocationInfrastructure)
public struct PublishCoachInvocationMutation: Equatable, Sendable {
    public let base: ChatAggregate
    public let invocation: CoachInvocation
    public let userMessage: ChatMessage
    public let coachMessage: ChatMessage
    public let freshDraft: ChatDraft
    public let replacementMemory: CoachMemory?
    public let profileProposal: ProfileChangeProposal?
    public let profileEvidencePublication: ProfileEvidencePublication?
    public let replacement: ChatAggregate

    /// Internal construction seam for persistence tests over app-owned
    /// Markdown. External infrastructure cannot manufacture a publication;
    /// untrusted provider bytes enter only through the whole-batch validator.
    init(
        base: ChatAggregate,
        invocation: CoachInvocation,
        coachMarkdown: String,
        replacementMemory: CoachMemory? = nil,
        completedAt: UTCInstant
    ) throws {
        try self.init(
            base: base,
            invocation: invocation,
            coachBlocks: [.markdown(coachMarkdown)],
            replacementMemory: replacementMemory,
            completedAt: completedAt
        )
    }

    init(
        base: ChatAggregate,
        invocation: CoachInvocation,
        coachBlocks: [CoachMessageBlock],
        replacementMemory: CoachMemory? = nil,
        profileProposal: ProfileChangeProposal? = nil,
        profileEvidencePublication: ProfileEvidencePublication? = nil,
        completedAt: UTCInstant
    ) throws {
        self.base = base
        self.invocation = invocation
        guard case let .answerPendingUserTurn(
            userMessageID,
            coachMessageID,
            freshDraftID
        )? = invocation.attempt.publicationAuthority else {
            throw CoachInvocationError.attemptPublicationAuthorityRequired
        }
        userMessage = try ChatMessage(
            id: userMessageID,
            responsePositionID: invocation.responsePositionID,
            content: .user(text: base.chat.draft.text),
            createdAt: completedAt
        )
        coachMessage = try ChatMessage(
            id: coachMessageID,
            responsePositionID: invocation.responsePositionID,
            content: .coach(blocks: coachBlocks),
            coachProfile: invocation.preparedProfile,
            createdAt: completedAt
        )
        freshDraft = try ChatDraft(
            draftID: freshDraftID,
            version: 0,
            text: "",
            updatedAt: completedAt
        )
        self.replacementMemory = replacementMemory
        self.profileProposal = profileProposal
        self.profileEvidencePublication = profileEvidencePublication
        replacement = try base.publishingTurn(
            invocation: invocation,
            userMessage: userMessage,
            coachMessage: coachMessage,
            freshDraft: freshDraft,
            replacementMemory: replacementMemory,
            profileProposal: profileProposal,
            profileEvidencePublication: profileEvidencePublication,
            at: completedAt
        )
    }

    init(
        base: ChatAggregate,
        invocation: CoachInvocation,
        validatedResponse: ValidatedCoachResponse,
        replacementMemory: CoachMemory?,
        completedAt: UTCInstant
    ) throws {
        guard validatedResponse.isSupportedByCurrentPublicationSlice,
              Self.matchesValidatedMemory(
                  validatedResponse.newMemory,
                  replacement: replacementMemory,
                  base: base.memory
              )
        else {
            throw PublishCoachInvocationMutationError.unsupportedResponseComponent
        }
        let proposal = try Self.materializeProfileProposal(
            from: validatedResponse,
            base: base,
            invocation: invocation,
            completedAt: completedAt
        )
        let evidencePublication = try Self.materializeProfileEvidencePublication(
            from: validatedResponse,
            base: base,
            invocation: invocation,
            completedAt: completedAt
        )
        try self.init(
            base: base,
            invocation: invocation,
            coachBlocks: validatedResponse.publicationBlocks,
            replacementMemory: replacementMemory,
            profileProposal: proposal,
            profileEvidencePublication: evidencePublication,
            completedAt: completedAt
        )
    }

    private static func materializeProfileEvidencePublication(
        from response: ValidatedCoachResponse,
        base: ChatAggregate,
        invocation: CoachInvocation,
        completedAt: UTCInstant
    ) throws -> ProfileEvidencePublication? {
        guard response.proposedProfileEdits.isEmpty,
              !response.appendedProfileEvidence.isEmpty
        else { return nil }
        return try ProfileEvidencePublication(
            chatID: base.chat.id,
            responsePositionID: invocation.responsePositionID,
            evidenceAppends: response.appendedProfileEvidence.map {
                try ProfileEvidenceAppend(
                    target: $0.target,
                    evidence: $0.evidence
                )
            },
            createdAt: completedAt
        )
    }

    private static func materializeProfileProposal(
        from response: ValidatedCoachResponse,
        base: ChatAggregate,
        invocation: CoachInvocation,
        completedAt: UTCInstant
    ) throws -> ProfileChangeProposal? {
        guard !response.proposedProfileEdits.isEmpty else { return nil }
        guard let sourceMessageID = invocation.attempt.publicationAuthority?
            .coachMessageID,
              let baseProfile = invocation.preparedProfile,
              let proposalID = try? ProfileChangeProposalID(
                  derivedProfileID(prefix: "prp-", source: sourceMessageID.rawValue)
              )
        else { throw PublishCoachInvocationMutationError.unsupportedResponseComponent }

        var nextStatementOrdinal = 0
        func allocateStatementID() throws -> ProfileStatementID {
            defer { nextStatementOrdinal += 1 }
            return try ProfileStatementID(
                derivedProfileID(
                    prefix: "stm-",
                    source: sourceMessageID.rawValue,
                    ordinal: nextStatementOrdinal
                )
            )
        }
        var changes: [ProfileProposalChange] = []
        var semanticTargetIndexes: [ProfileStatementID: Int] = [:]
        for proposal in response.proposedProfileEdits {
            switch proposal.edit {
            case let .add(kind, wording):
                if let index = changes.firstIndex(where: { change in
                    guard case let .add(existing) = change else { return false }
                    return existing.statementKind == kind &&
                        existing.wording == wording
                }), case let .add(existing) = changes[index] {
                    changes[index] = .add(
                        statement: try ProfileProposedStatement(
                            statementID: existing.statementID,
                            statementKind: existing.statementKind,
                            wording: existing.wording,
                            evidence: existing.evidence + proposal.evidence
                        )
                    )
                    continue
                }
                changes.append(.add(
                    statement: try ProfileProposedStatement(
                        statementID: allocateStatementID(),
                        statementKind: kind,
                        wording: wording,
                        evidence: proposal.evidence
                    )
                ))
            case let .replace(target, wording):
                if let index = semanticTargetIndexes[target.statementID],
                   case let .replace(existingTarget, existing) = changes[index],
                   existingTarget == target,
                   existing.wording == wording
                {
                    changes[index] = .replace(
                        target: target,
                        replacement: try ProfileProposedStatement(
                            statementID: existing.statementID,
                            statementKind: existing.statementKind,
                            wording: existing.wording,
                            evidence: existing.evidence + proposal.evidence
                        )
                    )
                    continue
                }
                semanticTargetIndexes[target.statementID] = changes.count
                changes.append(.replace(
                    target: target,
                    replacement: try ProfileProposedStatement(
                        statementID: allocateStatementID(),
                        statementKind: target.statementKind,
                        wording: wording,
                        evidence: proposal.evidence
                    )
                ))
            case let .retire(target):
                if let index = semanticTargetIndexes[target.statementID],
                   case let .retire(existingTarget, existingEvidence) =
                    changes[index], existingTarget == target
                {
                    changes[index] = .retire(
                        target: target,
                        evidence: existingEvidence + proposal.evidence
                    )
                    continue
                }
                semanticTargetIndexes[target.statementID] = changes.count
                changes.append(.retire(
                    target: target,
                    evidence: proposal.evidence
                ))
            }
        }
        let appends = try response.appendedProfileEvidence.map {
            try ProfileEvidenceAppend(target: $0.target, evidence: $0.evidence)
        }
        return try ProfileChangeProposal(
            id: proposalID,
            chatID: base.chat.id,
            responsePositionID: invocation.responsePositionID,
            baseProfile: baseProfile,
            changes: changes,
            evidenceAppends: appends,
            createdAt: completedAt
        )
    }

    private static func derivedProfileID(
        prefix: String,
        source: String,
        ordinal: Int = 0
    ) -> String {
        let sourceTail = String(source.dropFirst(4))
        guard ordinal > 0 else { return prefix + sourceTail }
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var tail = Array(sourceTail)
        var carry = ordinal
        for index in stride(from: tail.count - 1, through: tail.count - 4, by: -1) {
            guard let digit = alphabet.firstIndex(of: tail[index]) else {
                return prefix + sourceTail
            }
            let value = digit + carry
            tail[index] = alphabet[value % alphabet.count]
            carry = value / alphabet.count
        }
        // Wrap the fixed-width suffix just like the portable ID allocator. The
        // response envelope cannot contain 32^4 semantic edits, so every
        // ordinal in one validated batch remains distinct even at `ZZZZ`.
        return prefix + String(tail)
    }

    private static func matchesValidatedMemory(
        _ validated: ValidatedCoachResponseMemory?,
        replacement: CoachMemory?,
        base: CoachMemory
    ) -> Bool {
        guard let validated else { return replacement == nil }
        if validated.hasSameCanonicalContent(as: base) {
            return replacement == nil
        }
        guard let replacement else { return false }
        return validated.hasSameCanonicalContent(as: replacement)
    }

    init(
        base: ChatAggregate,
        invocation: CoachInvocation,
        identity: InvocationLaunchIdentity,
        coachMarkdown: String,
        completedAt: UTCInstant
    ) throws {
        guard invocation.id == identity.invocationID,
              invocation.attempt.id == identity.attemptID,
              invocation.attempt.publicationAuthority ==
              (try CoachProviderAttemptPublicationAuthority(
                  userMessageID: identity.userMessageID,
                  coachMessageID: identity.coachMessageID,
                  freshDraftID: identity.freshDraftID
              ))
        else { throw CoachInvocationError.attemptPublicationAuthorityRequired }
        try self.init(
            base: base,
            invocation: invocation,
            coachMarkdown: coachMarkdown,
            completedAt: completedAt
        )
    }
}

@_spi(InvocationInfrastructure)
public struct PublishProfileReconsiderationInvocationMutation:
    Equatable,
    Sendable
{
    public let base: ChatAggregate
    public let invocation: CoachInvocation
    public let reconsideration: ProfileReconsideration
    public let basis: ProfileReconsiderationBasis
    public let coachMessage: ChatMessage?
    public let replacementMemory: CoachMemory?
    public let replacementProposal: ProfileChangeProposal?
    public let isWithdrawal: Bool
    public let replacement: ChatAggregate

    init(
        base: ChatAggregate,
        invocation: CoachInvocation,
        reconsideration: ProfileReconsideration,
        basis: ProfileReconsiderationBasis,
        validatedResponse: ValidatedCoachResponse,
        replacementMemory: CoachMemory?,
        completedAt: UTCInstant
    ) throws {
        guard validatedResponse.profileEffectPublicationMode == .reviewRequired,
              validatedResponse.isSupportedByCurrentPublicationSlice,
              Self.matchesValidatedMemory(
                  validatedResponse.newMemory,
                  replacement: replacementMemory,
                  base: base.memory
              ),
              let preparedProfile = invocation.preparedProfile
        else {
            throw PublishCoachInvocationMutationError
                .unsupportedResponseComponent
        }
        try invocation.validate(against: base)
        guard base.profileReconsideration == reconsideration,
              basis.sourceEffect == base.profileEffect,
              reconsideration.sourceEffectIdentity == basis.sourceEffect.identity,
              reconsideration.resultResponsePositionID ==
                invocation.responsePositionID,
              case let .reconsiderProfileChange(coachMessageID)? =
                invocation.attempt.publicationAuthority
        else {
            throw PublishCoachInvocationMutationError
                .unsupportedResponseComponent
        }

        let coachMessage: ChatMessage? = if validatedResponse.messageBlocks.isEmpty {
            nil
        } else {
            try ChatMessage(
                id: coachMessageID,
                responsePositionID: reconsideration.resultResponsePositionID,
                content: .coach(blocks: validatedResponse.publicationBlocks),
                coachProfile: preparedProfile,
                createdAt: completedAt
            )
        }
        let replacementProposal = try Self.materializeReplacementProposal(
            from: validatedResponse,
            basis: basis,
            responsePositionID: reconsideration.resultResponsePositionID,
            sourceMessageID: coachMessageID,
            completedAt: completedAt
        )
        let outcome: ProfileReconsiderationPublicationOutcome
        if let replacementProposal {
            outcome = .replacement(replacementProposal)
        } else {
            outcome = .withdrawal
        }

        self.base = base
        self.invocation = invocation
        self.reconsideration = reconsideration
        self.basis = basis
        self.coachMessage = coachMessage
        self.replacementMemory = replacementMemory
        self.replacementProposal = replacementProposal
        isWithdrawal = replacementProposal == nil
        replacement = try base.publishingReconsideration(
            expected: reconsideration,
            basis: basis,
            preparedProfile: preparedProfile,
            coachMessage: coachMessage,
            replacementMemory: replacementMemory,
            outcome: outcome,
            at: completedAt
        )
    }

    private static func materializeReplacementProposal(
        from response: ValidatedCoachResponse,
        basis: ProfileReconsiderationBasis,
        responsePositionID: ChatResponsePositionID,
        sourceMessageID: ChatMessageID,
        completedAt: UTCInstant
    ) throws -> ProfileChangeProposal? {
        guard !response.proposedProfileEdits.isEmpty ||
            !response.appendedProfileEvidence.isEmpty ||
            !basis.retainedActiveEvidenceAppends.isEmpty
        else { return nil }

        guard let proposalID = try? ProfileChangeProposalID(
            derivedProfileID(prefix: "prp-", source: sourceMessageID.rawValue)
        ) else {
            throw PublishCoachInvocationMutationError
                .unsupportedResponseComponent
        }
        var nextStatementOrdinal = 0
        func allocateStatementID() throws -> ProfileStatementID {
            defer { nextStatementOrdinal += 1 }
            return try ProfileStatementID(
                derivedProfileID(
                    prefix: "stm-",
                    source: sourceMessageID.rawValue,
                    ordinal: nextStatementOrdinal
                )
            )
        }

        var changes: [ProfileProposalChange] = []
        var semanticTargetIndexes: [ProfileStatementID: Int] = [:]
        for proposal in response.proposedProfileEdits {
            switch proposal.edit {
            case let .add(kind, wording):
                if let index = changes.firstIndex(where: { change in
                    guard case let .add(existing) = change else { return false }
                    return existing.statementKind == kind &&
                        existing.wording == wording
                }), case let .add(existing) = changes[index] {
                    changes[index] = .add(
                        statement: try ProfileProposedStatement(
                            statementID: existing.statementID,
                            statementKind: existing.statementKind,
                            wording: existing.wording,
                            evidence: existing.evidence + proposal.evidence
                        )
                    )
                    continue
                }
                changes.append(.add(
                    statement: try ProfileProposedStatement(
                        statementID: allocateStatementID(),
                        statementKind: kind,
                        wording: wording,
                        evidence: proposal.evidence
                    )
                ))
            case let .replace(target, wording):
                if let index = semanticTargetIndexes[target.statementID],
                   case let .replace(existingTarget, existing) = changes[index],
                   existingTarget == target,
                   existing.wording == wording
                {
                    changes[index] = .replace(
                        target: target,
                        replacement: try ProfileProposedStatement(
                            statementID: existing.statementID,
                            statementKind: existing.statementKind,
                            wording: existing.wording,
                            evidence: existing.evidence + proposal.evidence
                        )
                    )
                    continue
                }
                semanticTargetIndexes[target.statementID] = changes.count
                changes.append(.replace(
                    target: target,
                    replacement: try ProfileProposedStatement(
                        statementID: allocateStatementID(),
                        statementKind: target.statementKind,
                        wording: wording,
                        evidence: proposal.evidence
                    )
                ))
            case let .retire(target):
                if let index = semanticTargetIndexes[target.statementID],
                   case let .retire(existingTarget, existingEvidence) =
                    changes[index], existingTarget == target
                {
                    changes[index] = .retire(
                        target: target,
                        evidence: existingEvidence + proposal.evidence
                    )
                    continue
                }
                semanticTargetIndexes[target.statementID] = changes.count
                changes.append(.retire(
                    target: target,
                    evidence: proposal.evidence
                ))
            }
        }
        let returnedAppends = try response.appendedProfileEvidence.map {
            try ProfileEvidenceAppend(target: $0.target, evidence: $0.evidence)
        }
        return try ProfileChangeProposal.reconsidered(
            id: proposalID,
            basis: basis,
            responsePositionID: responsePositionID,
            changes: changes,
            evidenceAppends: returnedAppends,
            createdAt: completedAt
        )
    }

    private static func derivedProfileID(
        prefix: String,
        source: String,
        ordinal: Int = 0
    ) -> String {
        let sourceTail = String(source.dropFirst(4))
        guard ordinal > 0 else { return prefix + sourceTail }
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var tail = Array(sourceTail)
        var carry = ordinal
        for index in stride(
            from: tail.count - 1,
            through: tail.count - 4,
            by: -1
        ) {
            guard let digit = alphabet.firstIndex(of: tail[index]) else {
                return prefix + sourceTail
            }
            let value = digit + carry
            tail[index] = alphabet[value % alphabet.count]
            carry = value / alphabet.count
        }
        return prefix + String(tail)
    }

    private static func matchesValidatedMemory(
        _ validated: ValidatedCoachResponseMemory?,
        replacement: CoachMemory?,
        base: CoachMemory
    ) -> Bool {
        guard let validated else { return replacement == nil }
        if validated.hasSameCanonicalContent(as: base) {
            return replacement == nil
        }
        guard let replacement else { return false }
        return validated.hasSameCanonicalContent(as: replacement)
    }
}

@_spi(InvocationInfrastructure)
public enum InvocationPublicationOutcome: Equatable, Sendable {
    case committed(ChatAggregate)
    case stale(ChatAggregate?)
    case failed
}

@_spi(InvocationInfrastructure)
public enum InvocationPublicationRecoveryOutcome: Equatable, Sendable {
    /// Persistence proved the exact intended publication, including its
    /// immutable message records, while allowing valid later Chat metadata and
    /// fresh-Draft revisions.
    case published(ChatAggregate)
    case notPublished
    case unavailable
}

@_spi(InvocationInfrastructure)
public enum InvocationPendingSessionPreparationOutcome: Sendable {
    case opened(any InvocationPendingPersistenceSession)
    case stale(ChatAggregate)
    case frozen(FrozenChatSnapshot)
    case readOnlyLibrary
    case blockedByActiveInvocation
    case unavailable
}

@_spi(InvocationInfrastructure)
public enum InvocationPendingSessionAcquisitionOutcome: Sendable {
    case opened(any InvocationPendingPersistenceSession)
    case ineligible(ChatAggregate?)
    case blockedByActiveInvocation
    case unavailable
}

@_spi(InvocationInfrastructure)
public enum InvocationPendingTermination: Sendable {
    case contextCapacityFailure
    case interrupted
    case rejected
}

@_spi(InvocationInfrastructure)
public enum InvocationTerminalPersistenceOutcome: Equatable, Sendable {
    case committed(ChatAggregate)
    case stale(ChatAggregate?)
    /// The terminal write failed after releasing liveness. Persistence has
    /// already reconciled and reread the exact Pending before returning.
    case recovered(InvocationPendingResolutionOutcome)
}

@_spi(InvocationInfrastructure)
public enum InvocationSessionInstallOutcome: Sendable {
    case installed(any InvocationActivePersistenceSession)
    case blockedByActiveInvocation
    case stale(ChatAggregate?)
    case failed
}

/// Stateful, one-shot persistence authority for one exact Pending. The
/// capability owns its Library-wide liveness lease and the transition into an
/// active Invocation, so callers cannot mix requests or invoke active-only
/// persistence operations before installation.
@_spi(InvocationInfrastructure)
public protocol InvocationPendingPersistenceSession: Sendable {
    var authority: InvocationPendingAuthority { get }

    func revalidate() async -> InvocationPendingResolutionOutcome

    /// Checks every durable identity namespace while this exact Pending lease
    /// remains held.
    func checkLaunchIdentity(
        _ identity: InvocationLaunchIdentity
    ) async -> InvocationLaunchIdentityAvailabilityOutcome

    func install(
        _ mutation: InstallCoachInvocationMutation
    ) async -> InvocationSessionInstallOutcome

    /// Completes a pre-install path and releases liveness. A failed terminal
    /// write is reconciled and reread before the method returns.
    func terminate(
        _ termination: InvocationPendingTermination
    ) async -> InvocationTerminalPersistenceOutcome

    func abandon() async
}

/// Stateful persistence authority for one exact installed Invocation. Pending
/// operations are absent from this interface; publication and abort cannot be
/// directed at another Invocation.
@_spi(InvocationInfrastructure)
public protocol InvocationActivePersistenceSession: Sendable {
    var invocation: CoachInvocation { get }
    var processingAggregate: ChatAggregate { get }

    /// Atomically replaces the exact current Attempt while this session keeps
    /// the Library Invocation liveness lease. The returned session is the only
    /// authority allowed to launch or publish the replacement Attempt.
    func installNextAttempt(
        _ mutation: InstallNextCoachProviderAttemptMutation
    ) async -> InvocationNextAttemptInstallOutcome

    /// Persists the classified UserRetryable failure while retiring this
    /// Invocation. Every adapter must preserve this classification.
    func abort(
        failure: PendingUserTurnFailure
    ) async -> InvocationTerminalPersistenceOutcome

    func publish(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationOutcome

    func recoverPublished(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationRecoveryOutcome
}

@_spi(InvocationInfrastructure)
public extension InvocationActivePersistenceSession {
    /// Releases liveness with the generic interruption descriptor used by
    /// stop/crash recovery when no more specific terminal reason exists.
    func abort() async -> InvocationTerminalPersistenceOutcome {
        await abort(failure: .coachResponseInterrupted)
    }
}

@_spi(InvocationInfrastructure)
public enum InvocationProfileReconsiderationTermination: Sendable {
    /// Releases the lease. A provisional new sidecar is removed atomically;
    /// an existing failed Retry sidecar is left unchanged.
    case rejected
    /// Retires pre-launch work with an exact typed retry failure while keeping
    /// the stale source effect and sidecar identity installed.
    case failed(PendingUserTurnFailure)
}

@_spi(InvocationInfrastructure)
public enum InvocationProfileReconsiderationTerminalPersistenceOutcome:
    Equatable,
    Sendable
{
    case committed(ChatAggregate)
    case stale(ChatAggregate?)
    case recovered(InvocationProfileReconsiderationResolutionOutcome)
}

@_spi(InvocationInfrastructure)
public enum InvocationProfileReconsiderationSessionInstallOutcome: Sendable {
    case installed(any InvocationProfileReconsiderationActivePersistenceSession)
    case blockedByActiveInvocation
    case stale(ChatAggregate?)
    case failed
}

@_spi(InvocationInfrastructure)
public enum InvocationProfileReconsiderationNextAttemptInstallOutcome: Sendable {
    case installed(any InvocationProfileReconsiderationActivePersistenceSession)
    case collision(InvocationLaunchIdentityCollision)
    case stale(ChatAggregate?)
    case failed
}

/// One-shot pre-install persistence authority. Infrastructure owns whether the
/// sidecar was provisionally installed (new) or already durable (Retry), and
/// applies `rejected` accordingly without ever deleting the source effect.
@_spi(InvocationInfrastructure)
public protocol InvocationProfileReconsiderationPersistenceSession: Sendable {
    var authority: InvocationProfileReconsiderationAuthority { get }

    func revalidate()
        async -> InvocationProfileReconsiderationResolutionOutcome

    func checkLaunchIdentity(
        _ identity: InvocationProfileReconsiderationLaunchIdentity
    ) async -> InvocationLaunchIdentityAvailabilityOutcome

    func install(
        _ mutation: InstallProfileReconsiderationInvocationMutation
    ) async -> InvocationProfileReconsiderationSessionInstallOutcome

    func terminate(
        _ termination: InvocationProfileReconsiderationTermination
    ) async -> InvocationProfileReconsiderationTerminalPersistenceOutcome

    func abandon() async
}

/// Active-only persistence authority for one exact installed Reconsider
/// Invocation. Publication, abort, and Attempt replacement cannot be redirected
/// to an answer or another sidecar.
@_spi(InvocationInfrastructure)
public protocol InvocationProfileReconsiderationActivePersistenceSession:
    Sendable
{
    var invocation: CoachInvocation { get }
    var processingAggregate: ChatAggregate { get }
    var reconsideration: ProfileReconsideration { get }
    var basis: ProfileReconsiderationBasis { get }

    func installNextAttempt(
        _ mutation: InstallNextProfileReconsiderationAttemptMutation
    ) async -> InvocationProfileReconsiderationNextAttemptInstallOutcome

    func abort(
        failure: PendingUserTurnFailure
    ) async -> InvocationProfileReconsiderationTerminalPersistenceOutcome

    func publish(
        _ mutation: PublishProfileReconsiderationInvocationMutation
    ) async -> InvocationPublicationOutcome

    func recoverPublished(
        _ mutation: PublishProfileReconsiderationInvocationMutation
    ) async -> InvocationPublicationRecoveryOutcome
}

@_spi(InvocationInfrastructure)
public protocol InvocationPersistencePort: Sendable {
    /// Opens a session after acquiring Library-wide liveness and atomically
    /// installing the exact new Pending.
    func openNewPendingInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> InvocationPendingSessionPreparationOutcome

    /// Opens a session after acquiring Library-wide liveness and resolving the
    /// exact durable Pending.
    func openPendingInvocation(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingSessionAcquisitionOutcome

    /// Runs only after the terminal owner has released its liveness lease.
    /// Persistence may reconcile an interrupted Invocation/Pending and then
    /// reread the exact Pending so Application can distinguish durable state
    /// from an operational retry projection.
    func recoverPendingAfterTerminalFailure(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingResolutionOutcome

    /// Proves an exact already-published response from authoritative storage.
    /// Application must not infer publication from aggregate shape or IDs.
    func recoverPublishedInvocation(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationRecoveryOutcome

    /// Acquires Library-wide liveness and atomically installs the provisional
    /// sidecar without removing the exact stale source effect.
    func openNewProfileReconsiderationInvocation(
        _ request: NewProfileReconsiderationInvocationRequest
    ) async -> InvocationProfileReconsiderationSessionPreparationOutcome

    /// Acquires liveness for an existing failed sidecar and freshly assessed
    /// basis. The reserved result response position is reused unchanged.
    func openRetryProfileReconsiderationInvocation(
        _ request: RetryProfileReconsiderationInvocationRequest
    ) async -> InvocationProfileReconsiderationSessionAcquisitionOutcome

    /// Reacquires a failure-free sidecar only for a process-live operational
    /// Retry. The caller owns the transient exact-request capability; persistence
    /// reconciles any old Invocation and freshly reassesses the Profile basis.
    func openOperationalProfileReconsiderationInvocation(
        _ request: ProfileReconsiderationInvocationRequest
    ) async -> InvocationProfileReconsiderationSessionAcquisitionOutcome

    func recoverProfileReconsiderationAfterTerminalFailure(
        _ request: ProfileReconsiderationInvocationRequest
    ) async -> InvocationProfileReconsiderationResolutionOutcome

    func recoverPublishedProfileReconsideration(
        _ mutation: PublishProfileReconsiderationInvocationMutation
    ) async -> InvocationPublicationRecoveryOutcome
}

/// Explicit fail-closed opt-in for persistence adapters that do not support
/// Profile Reconsideration transactions.
@_spi(InvocationInfrastructure)
public protocol ProfileReconsiderationUnavailableInvocationPersistencePort:
    InvocationPersistencePort
{}

@_spi(InvocationInfrastructure)
public extension InvocationPersistencePort {
    func recoverPendingAfterTerminalFailure(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingResolutionOutcome {
        .unavailable
    }

    func recoverPublishedInvocation(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationRecoveryOutcome {
        .unavailable
    }
}

@_spi(InvocationInfrastructure)
public extension ProfileReconsiderationUnavailableInvocationPersistencePort {
    func openNewProfileReconsiderationInvocation(
        _ request: NewProfileReconsiderationInvocationRequest
    ) async -> InvocationProfileReconsiderationSessionPreparationOutcome {
        .unavailable
    }

    func openRetryProfileReconsiderationInvocation(
        _ request: RetryProfileReconsiderationInvocationRequest
    ) async -> InvocationProfileReconsiderationSessionAcquisitionOutcome {
        .unavailable
    }

    func openOperationalProfileReconsiderationInvocation(
        _ request: ProfileReconsiderationInvocationRequest
    ) async -> InvocationProfileReconsiderationSessionAcquisitionOutcome {
        .unavailable
    }

    func recoverProfileReconsiderationAfterTerminalFailure(
        _ request: ProfileReconsiderationInvocationRequest
    ) async -> InvocationProfileReconsiderationResolutionOutcome {
        .unavailable
    }

    func recoverPublishedProfileReconsideration(
        _ mutation: PublishProfileReconsiderationInvocationMutation
    ) async -> InvocationPublicationRecoveryOutcome {
        .unavailable
    }
}

@_spi(InvocationInfrastructure)
public enum InvocationAdmissionClaimOutcome: Equatable, Sendable {
    case admitted
    /// The ledger rename succeeded, so the debit may be committed, but its
    /// parent-directory durability could not be proven.
    case commitUncertain
    case cooldown(lastAdmittedAt: UTCInstant, reopensAt: UTCInstant)
    case clockRollback(lastAdmittedAt: UTCInstant)
    case ledgerFull
    case unavailable
}

@_spi(InvocationInfrastructure)
public protocol InvocationAdmissionPort: Sendable {
    func availability(
        library: LibraryScope,
        at instant: UTCInstant
    ) async -> InvocationAdmissionAvailability

    func claim(
        library: LibraryScope,
        at instant: UTCInstant
    ) async -> InvocationAdmissionClaimOutcome
}

@_spi(InvocationInfrastructure)
public extension InvocationAdmissionPort {
    func availability(
        library: LibraryScope,
        at instant: UTCInstant
    ) async -> InvocationAdmissionAvailability {
        .unavailable
    }
}

private actor ProviderAttemptCompletion {
    enum Resolution: Sendable {
        case provider(CoachProviderAttemptOutcome)
        case transcript(AttemptTranscriptAccessTerminalStatus)
        case stopped
    }

    private var resolution: Resolution?
    private var waiters: [CheckedContinuation<Resolution, Never>] = []

    func wait() async -> Resolution {
        if let resolution { return resolution }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func complete(_ resolution: Resolution) {
        guard self.resolution == nil else { return }
        self.resolution = resolution
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume(returning: resolution) }
    }
}

private final class ProviderAttemptTranscriptReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    private var unfinishedReadCount = 0
    private var closurePreemptedRead = false

    @discardableResult
    func close() -> Bool {
        lock.withLock {
            open = false
            if unfinishedReadCount > 0 {
                closurePreemptedRead = true
            }
            return closurePreemptedRead
        }
    }

    func beginRead() -> Bool {
        lock.withLock {
            guard open else { return false }
            unfinishedReadCount += 1
            return true
        }
    }

    func authorize<Result>(_ result: Result) -> Result? {
        lock.withLock {
            precondition(unfinishedReadCount > 0)
            unfinishedReadCount -= 1
            return open ? result : nil
        }
    }
}

struct ProviderAttemptTranscriptAccess: Sendable {
    let handles: [PreparedCoachTranscriptHandle]

    private let capability: AttemptTranscriptAccessCapability
    private let broker: AttemptTranscriptAccessBroker
    private let completion: ProviderAttemptCompletion
    private let gate: ProviderAttemptTranscriptReadGate

    fileprivate init(
        grant: AttemptTranscriptAccessGrant,
        completion: ProviderAttemptCompletion
    ) {
        handles = grant.exchange.transcriptHandles
        capability = grant.capability
        broker = grant.broker
        self.completion = completion
        gate = ProviderAttemptTranscriptReadGate()
    }

    /// Module-local construction used to exercise the final disclosure fence
    /// without exposing the coordinator's completion actor.
    init(grant: AttemptTranscriptAccessGrant) {
        self.init(grant: grant, completion: ProviderAttemptCompletion())
    }

    /// The provider can request one typed nonempty subset. Capability material
    /// never becomes model-visible or printable.
    func read(
        transportRequestID: AttemptTranscriptTransportRequestID,
        handles: [PreparedCoachTranscriptHandle]
    ) async -> AttemptTranscriptAccessResult {
        await read(
            transportRequestID: transportRequestID,
            handles: handles,
            beforeFinalAuthorization: {}
        )
    }

    /// Module-local race seam used to suspend after the broker has prepared a
    /// result but before the final provider-disclosure authorization fence.
    func readForTesting(
        transportRequestID: AttemptTranscriptTransportRequestID,
        handles: [PreparedCoachTranscriptHandle],
        beforeFinalAuthorization: @escaping @Sendable () async -> Void
    ) async -> AttemptTranscriptAccessResult {
        await read(
            transportRequestID: transportRequestID,
            handles: handles,
            beforeFinalAuthorization: beforeFinalAuthorization
        )
    }

    private func read(
        transportRequestID: AttemptTranscriptTransportRequestID,
        handles: [PreparedCoachTranscriptHandle],
        beforeFinalAuthorization: @escaping @Sendable () async -> Void
    ) async -> AttemptTranscriptAccessResult {
        guard gate.beginRead() else { return .rejected(.closed) }
        let result = await broker.read(
            capability: capability,
            transportRequestID: transportRequestID,
            handles: handles
        )
        let terminalStatus: AttemptTranscriptAccessTerminalStatus?
        switch result {
        case .rejected:
            // A third read, an altered replay, or another closed-broker access
            // is terminal even when the broker's prior status was `completed`.
            terminalStatus = .rejected
        case .delivered:
            switch await broker.status() {
            case let .terminal(status):
                terminalStatus = switch status {
                case .sessionUnavailable, .contextCannotFit, .rejected:
                    status
                case .completed, .revoked:
                    nil
                }
            case .open, .checking, .replayable:
                terminalStatus = nil
            }
        }

        await beforeFinalAuthorization()
        // This is the last authorization point after every broker suspension.
        // Stop/finalization can therefore prevent transcript bytes from escaping.
        guard let authorized = gate.authorize(result) else {
            return .rejected(.closed)
        }
        if let terminalStatus {
            // The Invocation coordinator must win before a non-cooperative
            // provider can continue after receiving a terminal tool response.
            // Terminal responses contain no transcript bytes, so completing the
            // coordinator before returning them does not reopen disclosure.
            await completion.complete(.transcript(terminalStatus))
        }
        return authorized
    }

    /// Module-local race harness: stages a broker terminal before the normal
    /// coordinator notification, so Stop's handoff fence can be verified.
    func stageReadBeforeTerminalReportForTesting(
        transportRequestID: AttemptTranscriptTransportRequestID,
        handles: [PreparedCoachTranscriptHandle]
    ) async -> AttemptTranscriptAccessResult {
        guard gate.beginRead() else { return .rejected(.closed) }
        let result = await broker.read(
            capability: capability,
            transportRequestID: transportRequestID,
            handles: handles
        )
        return gate.authorize(result) ?? .rejected(.closed)
    }

    func closeReads() {
        gate.close()
    }

    func brokerStatusForTesting() async -> AttemptTranscriptAccessBrokerStatus {
        await broker.status()
    }

    fileprivate func finalize(
        reason: AttemptTranscriptAccessRevocationReason
    ) async -> AttemptTranscriptAccessBrokerStatus {
        let preemptedRead = gate.close()
        let brokerStatus = await broker.finalize(reason: reason)
        return preemptedRead ? .checking : brokerStatus
    }

    fileprivate func revoke(reason: AttemptTranscriptAccessRevocationReason) async {
        gate.close()
        await broker.revoke(reason: reason)
    }
}

enum CoachProviderAttemptControl: Equatable, Sendable {
    case standard
    case shorterRepair(instruction: String)
}

enum CoachProviderAttemptOutcome: Equatable, Sendable {
    case complete(CoachProviderCompleteResponse)
    case autoRetryableFailure
    case userRetryableFailure
    case responseOverflow

    /// Convenience for deterministic provider doubles. The coordinator still
    /// receives opaque JSON bytes and applies the complete response validator.
    static func complete(markdown: String) -> Self {
        .complete(.singleMarkdown(markdown))
    }
}

enum CoachProviderAttemptCancellationOutcome: Equatable, Sendable {
    case reaped
    case alreadyAbsent
    case unableToConfirm
}

struct SyntheticCoachProviderRequest: Sendable {
    let attemptID: CoachProviderAttemptID
    let attemptOrdinal: UInt8
    let attemptKind: CoachProviderAttemptKind
    let providerIdempotencyValue: ProviderIdempotencyValue
    let exchange: AttemptBoundCoachExchange
    let transcriptAccess: ProviderAttemptTranscriptAccess?
    let outputTokenCeiling: Int
    let pinnedInstruction: String
    let control: CoachProviderAttemptControl
}

protocol SyntheticCoachProviderPort: Sendable {
    func run(_ request: SyntheticCoachProviderRequest) async -> CoachProviderAttemptOutcome

    /// Idempotently requests cooperative cancellation, then force-terminates
    /// and reaps the exact Attempt within the supplied grace bound. Success is
    /// returned only after process absence is proven.
    func cancelAndReap(
        attemptID: CoachProviderAttemptID,
        graceMilliseconds: Int64
    ) async -> CoachProviderAttemptCancellationOutcome
}

extension SyntheticCoachProviderPort {
    func cancelAndReap(
        attemptID: CoachProviderAttemptID,
        graceMilliseconds: Int64
    ) async -> CoachProviderAttemptCancellationOutcome {
        .unableToConfirm
    }
}

struct DeterministicSyntheticCoachProvider: SyntheticCoachProviderPort {
    static let markdown = "This is a complete synthetic coaching response."

    func run(_ request: SyntheticCoachProviderRequest) async -> CoachProviderAttemptOutcome {
        .complete(markdown: Self.markdown)
    }

    func cancelAndReap(
        attemptID: CoachProviderAttemptID,
        graceMilliseconds: Int64
    ) async -> CoachProviderAttemptCancellationOutcome {
        .alreadyAbsent
    }
}

@_spi(InvocationInfrastructure)
public protocol InvocationRetrySleeping: Sendable {
    func sleep(milliseconds: Int64) async throws
}

@_spi(InvocationInfrastructure)
public struct TaskInvocationRetrySleeper: InvocationRetrySleeping {
    public init() {}

    public func sleep(milliseconds: Int64) async throws {
        guard milliseconds >= 0 else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}

@_spi(InvocationInfrastructure)
public protocol InvocationRetryTiming: Sendable {
    /// Returns a process-local monotonic millisecond reading. Only differences
    /// between readings are meaningful.
    func nowMilliseconds() -> UInt64
}

@_spi(InvocationInfrastructure)
public struct ContinuousInvocationRetryTiming: InvocationRetryTiming {
    private let origin: ContinuousClock.Instant

    public init() {
        origin = ContinuousClock.now
    }

    public func nowMilliseconds() -> UInt64 {
        let components = origin.duration(to: ContinuousClock.now).components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        let (whole, overflow) = UInt64(components.seconds)
            .multipliedReportingOverflow(by: 1_000)
        guard !overflow else { return UInt64.max }
        let fractional = UInt64(components.attoseconds) / 1_000_000_000_000_000
        let (total, additionOverflow) = whole.addingReportingOverflow(fractional)
        return additionOverflow ? UInt64.max : total
    }
}

@_spi(InvocationInfrastructure)
public enum InvocationRetryDiagnosticReason: String, Equatable, Sendable {
    case contextCapacityExceeded
    case admissionCommitUncertain
    case admissionCooldown
    case admissionClockRollback
    case admissionLedgerFull
    case admissionUnavailable
    case preparedContextStale
    case relaunchedInvocationInterrupted
    case coachResponseStopped
    case providerAutoRetryable
    case providerUserRetryable
    case automaticRetriesExhausted
    case responseOverflowRepair
    case shorterRepairProviderFailure
    case responseOverflowRepeated
    case responseOverflowAttemptLimitReached
    case retryScheduleUnavailable
    case retrySleepFailed
    case missingAttemptTransportAuthority
    case unreapedProviderBlockedSuccessor
    case attemptTranscriptAccessLaunchFailed
    case transcriptSessionUnavailable
    case transcriptContextCannotFit
    case transcriptAccessProtocolFailure
    case nextAttemptIdentityCollisionExhausted
    case nextAttemptConstructionFailed
    case nextAttemptInstallationFailed
    case nextAttemptBecameStale
    case responseValidationUnavailable
    case responseCollectorLimitExceeded
    case responseTokenLimitExceeded
    case responseEncodingInvalid
    case responseSchemaInvalid
    case responseMarkdownUnsafe
    case responseMemoryInvalid
    case responseMemoryLimitExceeded
    case responseEvidenceInvalid
    case responseProfileTargetInvalid
    case responseProfileEffectsConflict
    case responsePublicationUnsupported
    case invalidCompleteResponse
    case publicationConflict
    case publicationPersistenceUnavailable
}

@_spi(InvocationInfrastructure)
public enum InvocationRetryDiagnosticClassification: String, Equatable, Sendable {
    case contextCapacity
    case admissionRejected
    case interruption
    case providerAutoRetryable
    case providerUserRetryable
    case invalidProviderResponse
    case transcriptReadFailure
    case retryInfrastructureFailure
    case publicationConflict
    case persistenceUnavailable
}

@_spi(InvocationInfrastructure)
public enum InvocationRetryDiagnosticDisposition: String, Equatable, Sendable {
    case automaticRetry
    case userRetryableFailure
}

/// Bounded numeric projections of the already-qualified frozen context. No
/// provider payload, user-authored value, capability, or storage location can
/// cross the diagnostics seam.
@_spi(InvocationInfrastructure)
public struct InvocationRetryDiagnosticContext: Equatable, Sendable {
    /// Zero denotes a metric that was unavailable at the recovery boundary; it
    /// never authorizes reconstructing or persisting private request content.
    public static let unavailable = InvocationRetryDiagnosticContext(
        requestUTF8Bytes: 0,
        completeModelInputUTF8Bytes: 0,
        transcriptReadRequestUTF8Bytes: 0,
        transcriptReadResponseUTF8Bytes: 0,
        completeInputTokens: 0,
        inputCeilingTokens: 0,
        memoryUTF8Bytes: 0
    )

    public let requestUTF8Bytes: Int
    public let completeModelInputUTF8Bytes: Int
    public let transcriptReadRequestUTF8Bytes: Int
    public let transcriptReadResponseUTF8Bytes: Int
    public let completeInputTokens: Int
    public let inputCeilingTokens: Int
    public let memoryUTF8Bytes: Int

    public init(
        requestUTF8Bytes: Int,
        completeModelInputUTF8Bytes: Int,
        transcriptReadRequestUTF8Bytes: Int,
        transcriptReadResponseUTF8Bytes: Int,
        completeInputTokens: Int,
        inputCeilingTokens: Int,
        memoryUTF8Bytes: Int
    ) {
        self.requestUTF8Bytes = requestUTF8Bytes
        self.completeModelInputUTF8Bytes = completeModelInputUTF8Bytes
        self.transcriptReadRequestUTF8Bytes = transcriptReadRequestUTF8Bytes
        self.transcriptReadResponseUTF8Bytes = transcriptReadResponseUTF8Bytes
        self.completeInputTokens = completeInputTokens
        self.inputCeilingTokens = inputCeilingTokens
        self.memoryUTF8Bytes = memoryUTF8Bytes
    }
}

/// Metadata-only evidence that one automatic or user-visible retry became
/// necessary. The closed interface deliberately cannot carry provider output,
/// Draft/Message/Memory text, transcript data, paths, credentials, capabilities,
/// idempotency values, or transcript handles.
@_spi(InvocationInfrastructure)
public struct InvocationRetryDiagnosticEvent: Equatable, Sendable {
    public let reason: InvocationRetryDiagnosticReason
    public let classification: InvocationRetryDiagnosticClassification
    public let disposition: InvocationRetryDiagnosticDisposition
    /// Identity is absent when the product exposes Retry before an Invocation
    /// or provider Attempt has been durably installed.
    public let invocationID: CoachInvocationID?
    public let attemptID: CoachProviderAttemptID?
    public let attemptOrdinal: UInt8?
    /// One-based retry decision cycle when an Attempt exists. Multiple
    /// decisions on one Attempt intentionally share it.
    public let retryNumber: UInt8?
    public let occurredAt: UTCInstant
    public let durationMilliseconds: UInt64
    public let context: InvocationRetryDiagnosticContext

    public init(
        reason: InvocationRetryDiagnosticReason,
        classification: InvocationRetryDiagnosticClassification,
        disposition: InvocationRetryDiagnosticDisposition,
        invocationID: CoachInvocationID?,
        attemptID: CoachProviderAttemptID?,
        attemptOrdinal: UInt8?,
        retryNumber: UInt8?,
        occurredAt: UTCInstant,
        durationMilliseconds: UInt64,
        context: InvocationRetryDiagnosticContext
    ) {
        self.reason = reason
        self.classification = classification
        self.disposition = disposition
        self.invocationID = invocationID
        self.attemptID = attemptID
        self.attemptOrdinal = attemptOrdinal
        self.retryNumber = retryNumber
        self.occurredAt = occurredAt
        self.durationMilliseconds = durationMilliseconds
        self.context = context
    }
}

@_spi(InvocationInfrastructure)
public protocol InvocationRetryDiagnostics: Sendable {
    /// Copies the metadata into a bounded in-memory enqueue and returns. An
    /// adapter must not suspend, block on I/O, or perform durable work here.
    func enqueue(_ event: InvocationRetryDiagnosticEvent)
}

@_spi(InvocationInfrastructure)
public struct DiscardingInvocationRetryDiagnostics: InvocationRetryDiagnostics {
    public init() {}

    public func enqueue(_ event: InvocationRetryDiagnosticEvent) {}
}

public actor DefaultInvocations: Invocations {
    private actor BackoffCompletion {
        enum Resolution: Sendable {
            case elapsed
            case failed
            case stopped
        }

        private var resolution: Resolution?
        private var waiters: [CheckedContinuation<Resolution, Never>] = []

        func wait() async -> Resolution {
            if let resolution { return resolution }
            return await withCheckedContinuation { waiters.append($0) }
        }

        func complete(_ resolution: Resolution) {
            guard self.resolution == nil else { return }
            self.resolution = resolution
            let waiters = waiters
            self.waiters.removeAll(keepingCapacity: false)
            for waiter in waiters { waiter.resume(returning: resolution) }
        }
    }

    private enum ActiveInvocationWork {
        case provider(Task<Void, Never>, ProviderAttemptCompletion)
        case backoff(Task<Void, Never>, BackoffCompletion)
        case transition(Task<NextAttemptResolution, Never>)
        case reapPending(InvocationTryOutcome?)
        case stopping

        func cancel() {
            switch self {
            case let .provider(task, _): task.cancel()
            case let .backoff(task, _): task.cancel()
            case let .transition(task): task.cancel()
            case .reapPending, .stopping: break
            }
        }
    }

    private enum ActiveProfileReconsiderationWork {
        case provider(Task<Void, Never>, ProviderAttemptCompletion)
        case backoff(Task<Void, Never>, BackoffCompletion)
        case transition(Task<ProfileReconsiderationNextAttemptResolution, Never>)
        case reapPending(ProfileReconsiderationInvocationTryOutcome?)
        case stopping

        func cancel() {
            switch self {
            case let .provider(task, _): task.cancel()
            case let .backoff(task, _): task.cancel()
            case let .transition(task): task.cancel()
            case .reapPending, .stopping: break
            }
        }
    }

    private struct ActiveInvocationControl {
        let runID: UUID
        let authority: InvocationStopAuthority
        var session: any InvocationActivePersistenceSession
        let fallback: ChatAggregate
        let diagnosticContext: InvocationRetryDiagnosticContext
        let startedAtMilliseconds: UInt64
        let transcriptAccess: ProviderAttemptTranscriptAccess?
        var work: ActiveInvocationWork
        var isRevoked: Bool
        var retainedTranscriptTerminalStatus: AttemptTranscriptAccessTerminalStatus?
    }

    private struct ActiveProfileReconsiderationControl {
        let runID: UUID
        let authority: ProfileReconsiderationInvocationStopAuthority
        var session:
            any InvocationProfileReconsiderationActivePersistenceSession
        let fallback: ChatAggregate
        let diagnosticContext: InvocationRetryDiagnosticContext
        let startedAtMilliseconds: UInt64
        let transcriptAccess: ProviderAttemptTranscriptAccess?
        var work: ActiveProfileReconsiderationWork
        var isRevoked: Bool
        var retainedTranscriptTerminalStatus:
            AttemptTranscriptAccessTerminalStatus?
    }

    private struct PublicationRecoveryIntent: Sendable {
        let mutation: PublishCoachInvocationMutation
        let quote: CoachContextQuote
    }

    private struct ProfileReconsiderationPublicationRecoveryIntent: Sendable {
        let mutation: PublishProfileReconsiderationInvocationMutation
        let quote: CoachContextQuote
    }

    private enum PublicationRecoveryResolution {
        case published(InvocationTryOutcome)
        case notPublished
        case unavailable(PublicationRecoveryIntent)
    }

    private enum ProfileReconsiderationPublicationRecoveryResolution {
        case published(ProfileReconsiderationInvocationTryOutcome)
        case notPublished
        case unavailable(ProfileReconsiderationPublicationRecoveryIntent)
    }

    private enum TerminalRecoveryResolution {
        case published(InvocationTryOutcome)
        case eligible(InvocationPendingAuthority)
        case ineligible(ChatAggregate?, unresolvedPublication: PublicationRecoveryIntent?)
        case unavailable(unresolvedPublication: PublicationRecoveryIntent?)
    }

    private enum ProfileReconsiderationTerminalRecoveryResolution {
        case published(ProfileReconsiderationInvocationTryOutcome)
        case eligible(InvocationProfileReconsiderationAuthority)
        case ineligible(
            ChatAggregate?,
            unresolvedPublication:
                ProfileReconsiderationPublicationRecoveryIntent?
        )
        case unavailable(
            unresolvedPublication:
                ProfileReconsiderationPublicationRecoveryIntent?
        )
    }

    private enum NextAttemptResolution {
        case installed(any InvocationActivePersistenceSession)
        case terminal(InvocationTryOutcome)
        case revoked(any InvocationActivePersistenceSession)
    }

    private enum ProfileReconsiderationNextAttemptResolution {
        case installed(
            any InvocationProfileReconsiderationActivePersistenceSession
        )
        case terminal(ProfileReconsiderationInvocationTryOutcome)
        case revoked(
            any InvocationProfileReconsiderationActivePersistenceSession
        )
    }

    private struct OperationalRetrySnapshot: Sendable {
        let fallback: ChatAggregate
        let publication: PublicationRecoveryIntent?
    }

    private struct OperationalProfileReconsiderationRetrySnapshot: Sendable {
        let request: ProfileReconsiderationInvocationRequest
        let fallback: ChatAggregate
        let publication: ProfileReconsiderationPublicationRecoveryIntent?
    }

    static let maximumLaunchIdentityCandidates = 4
    static let providerCancellationGraceMilliseconds: Int64 = 2_000
    static let automaticRetryDelaysMilliseconds: [Int64] = [5_000, 10_000, 15_000]
    static let shorterRepairInstruction = """
    The previous Attempt exceeded the response limit. Return a materially shorter \
    complete response. Preserve the direct answer, remove repetition and optional \
    detail, and never return partial JSON.
    """

    static func pinnedInstruction(outputTokenCeiling: Int) -> String {
        CoachProviderPinnedInstruction.standard(
            outputTokenCeiling: outputTokenCeiling
        )
    }

    private static func pinnedInstruction(
        base: String,
        attemptKind: CoachProviderAttemptKind
    ) -> String {
        switch attemptKind {
        case .standard:
            base
        case .shorterRepair:
            base + " " + shorterRepairInstruction
        }
    }
    private let persistence: any InvocationPersistencePort
    private let admission: any InvocationAdmissionPort
    private let provider: any SyntheticCoachProviderPort
    private let coachContext: any CoachContextCoordinating
    private let clock: any ChatClock
    private let identities: any InvocationIdentityGenerating
    private let memoryIDGenerator: any CoachMemoryIDGenerator
    private let retrySleeper: any InvocationRetrySleeping
    private let retryDiagnostics: any InvocationRetryDiagnostics
    private let retryTiming: any InvocationRetryTiming
    private let transcriptAvailability: AttemptTranscriptAvailabilitySource
    private var inFlightRequests: Set<PendingCoachInvocationRequest> = []
    private var preparedSessions: [
        UUID: any InvocationPendingPersistenceSession
    ] = [:]
    private var operationalRetrySnapshots: [
        PendingCoachInvocationRequest: OperationalRetrySnapshot
    ] = [:]
    private var operationalProfileReconsiderationRetrySnapshots:
        [OperationalProfileReconsiderationRetrySnapshot] = []
    private var activeInvocationControls: [UUID: ActiveInvocationControl] = [:]
    private var inFlightProfileReconsiderationRequests:
        [ProfileReconsiderationInvocationRequest] = []
    private var preparedProfileReconsiderationSessions: [
        UUID: any InvocationProfileReconsiderationPersistenceSession
    ] = [:]
    private var activeProfileReconsiderationControls: [
        UUID: ActiveProfileReconsiderationControl
    ] = [:]

    private var hasUnreapedProviderAuthority: Bool {
        activeInvocationControls.values.contains { $0.isRevoked } ||
            activeProfileReconsiderationControls.values.contains {
                $0.isRevoked
            }
    }

    init(
        persistence: any InvocationPersistencePort,
        admission: any InvocationAdmissionPort,
        provider: any SyntheticCoachProviderPort,
        coachContext: any CoachContextCoordinating,
        clock: any ChatClock,
        identities: any InvocationIdentityGenerating,
        memoryIDGenerator: any CoachMemoryIDGenerator,
        retrySleeper: any InvocationRetrySleeping = TaskInvocationRetrySleeper(),
        retryDiagnostics: any InvocationRetryDiagnostics =
            DiscardingInvocationRetryDiagnostics(),
        retryTiming: any InvocationRetryTiming = ContinuousInvocationRetryTiming(),
        transcriptAvailability: AttemptTranscriptAvailabilitySource = .allAvailable
    ) {
        self.persistence = persistence
        self.admission = admission
        self.provider = provider
        self.coachContext = coachContext
        self.clock = clock
        self.identities = identities
        self.memoryIDGenerator = memoryIDGenerator
        self.retrySleeper = retrySleeper
        self.retryDiagnostics = retryDiagnostics
        self.retryTiming = retryTiming
        self.transcriptAvailability = transcriptAvailability
    }

    /// Production composition seam. Exact preparation and the synthetic provider
    /// remain behind this coordinator; Infrastructure supplies only durable
    /// persistence, admission, time, and stable identities.
    @_spi(InvocationInfrastructure)
    public init(
        persistence: any InvocationPersistencePort,
        admission: any InvocationAdmissionPort,
        clock: any ChatClock,
        identities: any InvocationIdentityGenerating,
        memoryIDGenerator: any CoachMemoryIDGenerator,
        retrySleeper: any InvocationRetrySleeping = TaskInvocationRetrySleeper(),
        retryDiagnostics: any InvocationRetryDiagnostics =
            DiscardingInvocationRetryDiagnostics(),
        retryTiming: any InvocationRetryTiming = ContinuousInvocationRetryTiming(),
        transcriptAvailability: AttemptTranscriptAvailabilitySource
    ) {
        self.persistence = persistence
        self.admission = admission
        provider = DeterministicSyntheticCoachProvider()
        coachContext = DefaultCoachContextFeature()
        self.clock = clock
        self.identities = identities
        self.memoryIDGenerator = memoryIDGenerator
        self.retrySleeper = retrySleeper
        self.retryDiagnostics = retryDiagnostics
        self.retryTiming = retryTiming
        self.transcriptAvailability = transcriptAvailability
    }

    public func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
        guard !hasUnreapedProviderAuthority else {
            return .activeInvocation
        }
        switch await persistence.openNewPendingInvocation(request) {
        case let .opened(session):
            let authority = session.authority
            let prepared = PreparedPendingCoachInvocation(authority: authority)
            preparedSessions[prepared.capabilityID] = session
            return .prepared(prepared)
        case let .stale(current):
            return .stale(current)
        case let .frozen(frozen):
            return .frozen(frozen)
        case .readOnlyLibrary:
            return .readOnlyLibrary
        case .blockedByActiveInvocation:
            return .activeInvocation
        case .unavailable:
            return .failed
        }
    }

    public func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async {
        guard let session = preparedSessions[prepared.capabilityID],
              session.authority.request == prepared.request,
              session.authority.aggregate == prepared.aggregate
        else { return }
        preparedSessions.removeValue(forKey: prepared.capabilityID)
        await session.abandon()
    }

    public func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome {
        await tryInvoke(prepared, observingStopAuthority: { _ in })
    }

    public func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation,
        observingStopAuthority observer: @escaping InvocationStopAuthorityObserver
    ) async -> InvocationTryOutcome {
        guard let session = preparedSessions[prepared.capabilityID],
              session.authority.request == prepared.request,
              session.authority.aggregate == prepared.aggregate
        else {
            return .rejected(nil, .eligibilityChanged)
        }
        preparedSessions.removeValue(forKey: prepared.capabilityID)
        let request = prepared.request
        guard !hasUnreapedProviderAuthority,
              inFlightRequests.insert(request).inserted
        else {
            await session.abandon()
            return .rejected(nil, .activeInvocation)
        }
        defer { inFlightRequests.remove(request) }

        return await invoke(session, observingStopAuthority: observer)
    }

    public func tryInvoke(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationTryOutcome {
        await tryInvoke(request, observingStopAuthority: { _ in })
    }

    public func tryInvoke(
        _ request: PendingCoachInvocationRequest,
        observingStopAuthority observer: @escaping InvocationStopAuthorityObserver
    ) async -> InvocationTryOutcome {
        guard !hasUnreapedProviderAuthority,
              inFlightRequests.insert(request).inserted
        else {
            return .rejected(nil, .activeInvocation)
        }
        defer { inFlightRequests.remove(request) }

        if let retryOutcome = await recoverOperationalRetryIfNeeded(request) {
            return retryOutcome
        }

        let session: any InvocationPendingPersistenceSession
        switch await persistence.openPendingInvocation(request) {
        case let .opened(opened):
            session = opened
        case let .ineligible(current):
            return .rejected(current, .eligibilityChanged)
        case .blockedByActiveInvocation:
            return .rejected(nil, .activeInvocation)
        case .unavailable:
            return .rejected(nil, .persistenceUnavailable)
        }

        return await invoke(session, observingStopAuthority: observer)
    }

    public func prepareNewProfileReconsiderationInvocation(
        _ request: NewProfileReconsiderationInvocationRequest
    ) async -> NewProfileReconsiderationInvocationOutcome {
        guard !hasUnreapedProviderAuthority else {
            return .activeInvocation
        }
        switch await persistence.openNewProfileReconsiderationInvocation(
            request
        ) {
        case let .opened(session):
            let authority = session.authority
            guard authority.request == request.request,
                  authority.basis == request.basis
            else {
                await session.abandon()
                return .failed
            }
            let prepared = PreparedProfileReconsiderationInvocation(
                authority: authority
            )
            preparedProfileReconsiderationSessions[prepared.capabilityID] =
                session
            return .prepared(prepared)
        case let .stale(current):
            return .stale(current)
        case let .frozen(frozen):
            return .frozen(frozen)
        case .readOnlyLibrary:
            return .readOnlyLibrary
        case .blockedByActiveInvocation:
            return .activeInvocation
        case .unavailable:
            return .failed
        }
    }

    public func abandonPreparedProfileReconsiderationInvocation(
        _ prepared: PreparedProfileReconsiderationInvocation
    ) async {
        guard let session = preparedProfileReconsiderationSessions[
            prepared.capabilityID
        ],
            session.authority.request == prepared.request,
            session.authority.aggregate == prepared.aggregate,
            session.authority.basis == prepared.basis
        else { return }
        preparedProfileReconsiderationSessions.removeValue(
            forKey: prepared.capabilityID
        )
        await session.abandon()
    }

    public func tryReconsiderProfileChange(
        _ prepared: PreparedProfileReconsiderationInvocation
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        await tryReconsiderProfileChange(
            prepared,
            observingStopAuthority: { _ in }
        )
    }

    public func tryReconsiderProfileChange(
        _ prepared: PreparedProfileReconsiderationInvocation,
        observingStopAuthority observer:
            @escaping ProfileReconsiderationInvocationStopAuthorityObserver
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        guard let session = preparedProfileReconsiderationSessions[
            prepared.capabilityID
        ],
            session.authority.request == prepared.request,
            session.authority.aggregate == prepared.aggregate,
            session.authority.basis == prepared.basis
        else {
            return .rejected(nil, .eligibilityChanged)
        }
        preparedProfileReconsiderationSessions.removeValue(
            forKey: prepared.capabilityID
        )
        guard beginProfileReconsideration(prepared.request) else {
            await session.abandon()
            return .rejected(nil, .activeInvocation)
        }
        defer { endProfileReconsideration(prepared.request) }
        return await invokeProfileReconsideration(
            session,
            observingStopAuthority: observer
        )
    }

    public func tryReconsiderProfileChange(
        _ request: RetryProfileReconsiderationInvocationRequest
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        await tryReconsiderProfileChange(
            request,
            observingStopAuthority: { _ in }
        )
    }

    public func tryReconsiderProfileChange(
        _ request: RetryProfileReconsiderationInvocationRequest,
        observingStopAuthority observer:
            @escaping ProfileReconsiderationInvocationStopAuthorityObserver
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        guard beginProfileReconsideration(request.request) else {
            return .rejected(nil, .activeInvocation)
        }
        defer { endProfileReconsideration(request.request) }

        let session: any InvocationProfileReconsiderationPersistenceSession
        switch await persistence.openRetryProfileReconsiderationInvocation(
            request
        ) {
        case let .opened(opened):
            guard opened.authority.request == request.request,
                  opened.authority.basis == request.basis
            else {
                await opened.abandon()
                return .rejected(nil, .eligibilityChanged)
            }
            session = opened
        case let .ineligible(current):
            return .rejected(current, .eligibilityChanged)
        case .blockedByActiveInvocation:
            return .rejected(nil, .activeInvocation)
        case .unavailable:
            return .rejected(nil, .persistenceUnavailable)
        }
        return await invokeProfileReconsideration(
            session,
            observingStopAuthority: observer
        )
    }

    public func tryReconsiderProfileChange(
        _ request: ProfileReconsiderationInvocationRequest
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        await tryReconsiderProfileChange(
            request,
            observingStopAuthority: { _ in }
        )
    }

    public func tryReconsiderProfileChange(
        _ request: ProfileReconsiderationInvocationRequest,
        observingStopAuthority observer:
            @escaping ProfileReconsiderationInvocationStopAuthorityObserver
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        guard var snapshot = operationalProfileReconsiderationRetrySnapshots
            .first(where: { $0.request == request })
        else { return .rejected(nil, .eligibilityChanged) }
        guard beginProfileReconsideration(request) else {
            return .rejected(nil, .activeInvocation)
        }
        defer { endProfileReconsideration(request) }

        if let publication = snapshot.publication {
            switch await resolveProfileReconsiderationPublicationRecovery(
                publication
            ) {
            case let .published(outcome):
                return outcome
            case .notPublished:
                snapshot = OperationalProfileReconsiderationRetrySnapshot(
                    request: request,
                    fallback: snapshot.fallback,
                    publication: nil
                )
                rememberOperationalProfileReconsiderationRetry(
                    request: request,
                    fallback: snapshot.fallback,
                    publication: nil
                )
            case let .unavailable(unresolvedPublication):
                return retainOperationalProfileReconsiderationRetry(
                    request: request,
                    fallback: snapshot.fallback,
                    publication: unresolvedPublication
                )
            }
        }

        let session: any InvocationProfileReconsiderationPersistenceSession
        switch await persistence
            .openOperationalProfileReconsiderationInvocation(request)
        {
        case let .opened(opened):
            guard opened.authority.request == request,
                  opened.authority.reconsideration.failure == nil
            else {
                let current = opened.authority.aggregate
                await opened.abandon()
                removeOperationalProfileReconsiderationRetry(request)
                return opened.authority.request == request
                    ? .interrupted(current, .persistenceUnavailable)
                    : .rejected(current, .eligibilityChanged)
            }
            removeOperationalProfileReconsiderationRetry(request)
            session = opened
        case let .ineligible(current):
            removeOperationalProfileReconsiderationRetry(request)
            return .rejected(current, .eligibilityChanged)
        case .blockedByActiveInvocation:
            return .rejected(nil, .activeInvocation)
        case .unavailable:
            return retainOperationalProfileReconsiderationRetry(
                request: request,
                fallback: snapshot.fallback,
                publication: snapshot.publication
            )
        }
        let outcome = await invokeProfileReconsideration(
            session,
            observingStopAuthority: observer
        )
        if case let .rejected(current?, reason) = outcome,
           reason != .eligibilityChanged,
           current.chat.id == request.chatID,
           current.profileEffect?.identity == request.sourceEffectIdentity,
           let reconsideration = current.profileReconsideration,
           reconsideration.sourceEffectIdentity ==
            request.sourceEffectIdentity,
           reconsideration.resultResponsePositionID ==
            request.resultResponsePositionID,
           reconsideration.failure == nil
        {
            rememberOperationalProfileReconsiderationRetry(
                request: request,
                fallback: current
            )
        }
        return outcome
    }

    private func beginProfileReconsideration(
        _ request: ProfileReconsiderationInvocationRequest
    ) -> Bool {
        guard !hasUnreapedProviderAuthority,
              !inFlightProfileReconsiderationRequests.contains(request)
        else { return false }
        inFlightProfileReconsiderationRequests.append(request)
        return true
    }

    private func endProfileReconsideration(
        _ request: ProfileReconsiderationInvocationRequest
    ) {
        inFlightProfileReconsiderationRequests.removeAll { $0 == request }
    }

    private func invokeProfileReconsideration(
        _ session: any InvocationProfileReconsiderationPersistenceSession,
        observingStopAuthority observer:
            @escaping ProfileReconsiderationInvocationStopAuthorityObserver
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        let firstAuthority = session.authority
        let request = firstAuthority.request
        let contextRequest: CoachContextReconsiderRequest
        do {
            contextRequest = try CoachContextReconsiderRequest(
                library: request.library,
                aggregate: firstAuthority.aggregate,
                basis: firstAuthority.basis
            )
        } catch {
            return await rejectProfileReconsideration(
                session,
                fallback: firstAuthority.aggregate,
                reason: .eligibilityChanged
            )
        }

        let prepared: PreparedCoachLaunchContext
        switch await coachContext.prepareReconsider(contextRequest) {
        case let .prepared(value):
            prepared = value
        case let .cannotFit(failure):
            return await failProfileReconsiderationBeforeInstall(
                session,
                fallback: firstAuthority.aggregate,
                request: request,
                failure: .coachContextCannotFit,
                outcome: { current in
                    .contextCapacityFailure(current, failure.quote)
                }
            )
        case let .unavailable(reason):
            return await failProfileReconsiderationBeforeInstall(
                session,
                fallback: firstAuthority.aggregate,
                request: request,
                failure: .coachResponseInterrupted,
                outcome: { current in
                    .rejected(current, .contextUnavailable(reason))
                }
            )
        }

        let finalAuthority: InvocationProfileReconsiderationAuthority
        switch await session.revalidate() {
        case let .eligible(authority) where authority == firstAuthority:
            finalAuthority = authority
        case let .eligible(authority):
            return await rejectProfileReconsideration(
                session,
                fallback: authority.aggregate,
                reason: .eligibilityChanged
            )
        case let .ineligible(current):
            return .rejected(current, .eligibilityChanged)
        case .unavailable:
            return await failProfileReconsiderationBeforeInstall(
                session,
                fallback: firstAuthority.aggregate,
                request: request,
                failure: .coachResponseInterrupted,
                outcome: { current in
                    .interrupted(current, .persistenceUnavailable)
                }
            )
        }

        let identityInstant = await clock.now()
        var invocationID = await identities.generateInvocationID(
            at: identityInstant
        )
        var selectedIdentity: InvocationProfileReconsiderationLaunchIdentity?
        var lastCollision: InvocationLaunchIdentityCollision?
        for _ in 0 ..< Self.maximumLaunchIdentityCandidates {
            let attemptIdentity = await identities
                .generateProfileReconsiderationAttemptIdentity(
                    at: identityInstant,
                    ordinal: 1,
                    kind: .standard,
                    transcriptHandleCount:
                        prepared.exchange.preparedTranscriptHandles.count
                )
            guard attemptIdentity.transcriptHandles.count ==
                prepared.exchange.preparedTranscriptHandles.count,
                (try? attemptIdentity.makeAttempt(
                    ordinal: 1,
                    kind: .standard
                )) != nil
            else {
                return await rejectProfileReconsideration(
                    session,
                    fallback: finalAuthority.aggregate,
                    reason: .persistenceUnavailable
                )
            }
            let candidate = InvocationProfileReconsiderationLaunchIdentity(
                invocationID: invocationID,
                attemptIdentity: attemptIdentity
            )
            switch await session.checkLaunchIdentity(candidate) {
            case .available:
                selectedIdentity = candidate
            case let .collision(collision):
                lastCollision = collision
                if collision == .invocationID {
                    invocationID = await identities.generateInvocationID(
                        at: identityInstant
                    )
                }
                continue
            case let .stale(current):
                await session.abandon()
                return .rejected(current, .eligibilityChanged)
            case .unavailable:
                return await failProfileReconsiderationBeforeInstall(
                    session,
                    fallback: finalAuthority.aggregate,
                    request: request,
                    failure: .coachResponseInterrupted,
                    outcome: { current in
                        .interrupted(current, .persistenceUnavailable)
                    }
                )
            }
            break
        }
        guard let identity = selectedIdentity else {
            return await rejectProfileReconsideration(
                session,
                fallback: finalAuthority.aggregate,
                reason: .identityCollisionExhausted(
                    lastCollision: lastCollision ?? .invocationID
                )
            )
        }

        do {
            try AttemptTranscriptAccessGrantIssuer().preflight(
                exchange: prepared.exchange,
                freshHandles: identity.transcriptHandles,
                pinnedInstruction: prepared.exchange.pinnedInstruction
            )
        } catch AttemptTranscriptAccessGrantIssueError.contextCannotFit {
            return await failProfileReconsiderationBeforeInstall(
                session,
                fallback: finalAuthority.aggregate,
                request: request,
                failure: .coachContextCannotFit,
                outcome: { current in
                    .contextCapacityFailure(current, prepared.quote)
                }
            )
        } catch {
            return await failProfileReconsiderationBeforeInstall(
                session,
                fallback: finalAuthority.aggregate,
                request: request,
                failure: .coachResponseInterrupted,
                outcome: { current in
                    .interrupted(current, .retryInfrastructureFailed)
                }
            )
        }

        let admittedAt = await clock.now()
        switch await admission.claim(
            library: request.library,
            at: admittedAt
        ) {
        case .admitted:
            break
        case .commitUncertain:
            return await failProfileReconsiderationBeforeInstall(
                session,
                fallback: finalAuthority.aggregate,
                request: request,
                failure: .coachResponseInterrupted,
                outcome: { current in
                    .interrupted(current, .persistenceUnavailable)
                }
            )
        case .cooldown:
            return await rejectProfileReconsideration(
                session,
                fallback: finalAuthority.aggregate,
                reason: .admissionCooldown
            )
        case .clockRollback:
            return await rejectProfileReconsideration(
                session,
                fallback: finalAuthority.aggregate,
                reason: .clockRollback
            )
        case .ledgerFull:
            return await rejectProfileReconsideration(
                session,
                fallback: finalAuthority.aggregate,
                reason: .admissionLedgerFull
            )
        case .unavailable:
            return await rejectProfileReconsideration(
                session,
                fallback: finalAuthority.aggregate,
                reason: .admissionUnavailable
            )
        }

        let install: InstallProfileReconsiderationInvocationMutation
        do {
            install = try InstallProfileReconsiderationInvocationMutation(
                authority: finalAuthority,
                identity: identity,
                preparedProfile: prepared.authority.profile,
                admittedAt: admittedAt
            )
        } catch {
            return await failProfileReconsiderationBeforeInstall(
                session,
                fallback: finalAuthority.aggregate,
                request: request,
                failure: .coachResponseInterrupted,
                outcome: { current in
                    .interrupted(current, .persistenceUnavailable)
                }
            )
        }

        let activeSession:
            any InvocationProfileReconsiderationActivePersistenceSession
        switch await session.install(install) {
        case let .installed(installed):
            activeSession = installed
        case .blockedByActiveInvocation:
            return await rejectProfileReconsideration(
                session,
                fallback: finalAuthority.aggregate,
                reason: .activeInvocation
            )
        case let .stale(current):
            await session.abandon()
            return .rejected(current, .eligibilityChanged)
        case .failed:
            return await failProfileReconsiderationBeforeInstall(
                session,
                fallback: finalAuthority.aggregate,
                request: request,
                failure: .coachResponseInterrupted,
                outcome: { current in
                    .interrupted(current, .persistenceUnavailable)
                }
            )
        }

        guard await coachContext.isPreparedContextCurrent(prepared) else {
            let current = await abortProfileReconsideration(
                activeSession,
                fallback: activeSession.processingAggregate,
                request: request,
                failure: .coachResponseInterrupted,
                reason: .persistenceUnavailable
            )
            if case let .interrupted(aggregate, _) = current {
                return .rejected(aggregate, .contextChanged)
            }
            return current
        }

        return await runProfileReconsideration(
            activeSession,
            prepared: prepared,
            observingStopAuthority: observer
        )
    }

    private func rejectProfileReconsideration(
        _ session: any InvocationProfileReconsiderationPersistenceSession,
        fallback: ChatAggregate,
        reason: InvocationRejectionReason
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        let request = session.authority.request
        switch await session.terminate(.rejected) {
        case let .committed(current):
            return .rejected(current, reason)
        case let .stale(current):
            return profileReconsiderationTerminalOutcome(
                current: current,
                fallback: fallback,
                request: request,
                outcome: { .rejected($0, .eligibilityChanged) }
            )
        case let .recovered(.eligible(authority)):
            return profileReconsiderationTerminalOutcome(
                current: authority.aggregate,
                fallback: fallback,
                request: request,
                outcome: { .rejected($0, reason) }
            )
        case let .recovered(.ineligible(current)):
            return profileReconsiderationTerminalOutcome(
                current: current,
                fallback: fallback,
                request: request,
                outcome: { .rejected($0, .eligibilityChanged) }
            )
        case .recovered(.unavailable):
            return profileReconsiderationTerminalOutcome(
                current: nil,
                fallback: fallback,
                request: request,
                outcome: { .rejected($0, .persistenceUnavailable) }
            )
        }
    }

    private func failProfileReconsiderationBeforeInstall(
        _ session: any InvocationProfileReconsiderationPersistenceSession,
        fallback: ChatAggregate,
        request: ProfileReconsiderationInvocationRequest,
        failure: PendingUserTurnFailure,
        outcome: (ChatAggregate) -> ProfileReconsiderationInvocationTryOutcome
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        switch await session.terminate(.failed(failure)) {
        case let .committed(current):
            return profileReconsiderationTerminalOutcome(
                current: current,
                fallback: fallback,
                request: request,
                outcome: outcome
            )
        case let .stale(current):
            return profileReconsiderationTerminalOutcome(
                current: current,
                fallback: fallback,
                request: request,
                outcome: outcome
            )
        case let .recovered(.eligible(authority)):
            return profileReconsiderationTerminalOutcome(
                current: authority.aggregate,
                fallback: fallback,
                request: request,
                outcome: outcome
            )
        case let .recovered(.ineligible(current)):
            return profileReconsiderationTerminalOutcome(
                current: current,
                fallback: fallback,
                request: request,
                outcome: outcome
            )
        case .recovered(.unavailable):
            return retainOperationalProfileReconsiderationRetry(
                request: request,
                fallback: fallback
            )
        }
    }

    private func abortProfileReconsideration(
        _ session:
            any InvocationProfileReconsiderationActivePersistenceSession,
        fallback: ChatAggregate,
        request: ProfileReconsiderationInvocationRequest,
        failure: PendingUserTurnFailure,
        reason: InvocationInterruptionReason
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        switch await session.abort(failure: failure) {
        case let .committed(current):
            return profileReconsiderationTerminalOutcome(
                current: current,
                fallback: fallback,
                request: request,
                outcome: { .interrupted($0, reason) }
            )
        case let .stale(current):
            return profileReconsiderationTerminalOutcome(
                current: current,
                fallback: fallback,
                request: request,
                outcome: { .interrupted($0, reason) }
            )
        case let .recovered(.eligible(authority)):
            return profileReconsiderationTerminalOutcome(
                current: authority.aggregate,
                fallback: fallback,
                request: request,
                outcome: { .interrupted($0, reason) }
            )
        case let .recovered(.ineligible(current)):
            return profileReconsiderationTerminalOutcome(
                current: current,
                fallback: fallback,
                request: request,
                outcome: { .interrupted($0, reason) }
            )
        case .recovered(.unavailable):
            return retainOperationalProfileReconsiderationRetry(
                request: request,
                fallback: fallback
            )
        }
    }

    private func interruptProfileReconsiderationPublicationAndAbort(
        _ session:
            any InvocationProfileReconsiderationActivePersistenceSession,
        fallback: ChatAggregate,
        request: ProfileReconsiderationInvocationRequest,
        reason: InvocationInterruptionReason,
        publication: ProfileReconsiderationPublicationRecoveryIntent
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        let priorRecovery = await resolveProfileReconsiderationPublicationRecovery(
            publication,
            using: session
        )
        if case let .published(outcome) = priorRecovery { return outcome }

        return switch await session.abort(
            failure: .coachResponseInterrupted
        ) {
        case let .committed(current):
            profileReconsiderationTerminalOutcome(
                current: current,
                fallback: fallback,
                request: request,
                outcome: { .interrupted($0, reason) }
            )
        case let .stale(current):
            await profileReconsiderationOutcomeAfterStaleAbort(
                current: current,
                fallback: fallback,
                request: request,
                reason: reason,
                publication: publication,
                priorRecovery: priorRecovery
            )
        case let .recovered(resolution):
            await profileReconsiderationOutcomeAfterRecoveredAbort(
                resolution,
                fallback: fallback,
                request: request,
                reason: reason,
                publication: publication,
                priorRecovery: priorRecovery
            )
        }
    }

    private func profileReconsiderationOutcomeAfterStaleAbort(
        current: ChatAggregate?,
        fallback: ChatAggregate,
        request: ProfileReconsiderationInvocationRequest,
        reason: InvocationInterruptionReason,
        publication: ProfileReconsiderationPublicationRecoveryIntent,
        priorRecovery:
            ProfileReconsiderationPublicationRecoveryResolution
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        if case .notPublished = priorRecovery {
            return profileReconsiderationTerminalOutcome(
                current: current,
                fallback: fallback,
                request: request,
                outcome: { .interrupted($0, reason) }
            )
        }
        switch await resolveProfileReconsiderationPublicationRecovery(
            publication
        ) {
        case let .published(outcome):
            return outcome
        case .notPublished:
            return profileReconsiderationTerminalOutcome(
                current: current,
                fallback: fallback,
                request: request,
                outcome: { .interrupted($0, reason) }
            )
        case .unavailable:
            return await profileReconsiderationInterruptionAfterTerminalFailure(
                request: request,
                fallback: fallback,
                reason: reason,
                publication: publication
            )
        }
    }

    private func profileReconsiderationOutcomeAfterRecoveredAbort(
        _ resolution: InvocationProfileReconsiderationResolutionOutcome,
        fallback: ChatAggregate,
        request: ProfileReconsiderationInvocationRequest,
        reason: InvocationInterruptionReason,
        publication: ProfileReconsiderationPublicationRecoveryIntent,
        priorRecovery:
            ProfileReconsiderationPublicationRecoveryResolution
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        if case .notPublished = priorRecovery {
            return profileReconsiderationOutcomeAfterTerminalResolution(
                resolution,
                fallback: fallback,
                request: request,
                reason: reason
            )
        }
        switch await resolveProfileReconsiderationPublicationRecovery(
            publication
        ) {
        case let .published(outcome):
            return outcome
        case .notPublished:
            return profileReconsiderationOutcomeAfterTerminalResolution(
                resolution,
                fallback: fallback,
                request: request,
                reason: reason
            )
        case .unavailable:
            return retainOperationalProfileReconsiderationRetry(
                request: request,
                fallback: fallback,
                publication: publication
            )
        }
    }

    private func profileReconsiderationOutcomeAfterTerminalResolution(
        _ resolution: InvocationProfileReconsiderationResolutionOutcome,
        fallback: ChatAggregate,
        request: ProfileReconsiderationInvocationRequest,
        reason: InvocationInterruptionReason
    ) -> ProfileReconsiderationInvocationTryOutcome {
        switch resolution {
        case let .eligible(authority):
            return profileReconsiderationTerminalOutcome(
                current: authority.aggregate,
                fallback: fallback,
                request: request,
                outcome: { .interrupted($0, reason) }
            )
        case let .ineligible(current):
            return profileReconsiderationTerminalOutcome(
                current: current,
                fallback: fallback,
                request: request,
                outcome: { .interrupted($0, reason) }
            )
        case .unavailable:
            return retainOperationalProfileReconsiderationRetry(
                request: request,
                fallback: fallback
            )
        }
    }

    private func profileReconsiderationInterruptionAfterTerminalFailure(
        request: ProfileReconsiderationInvocationRequest,
        fallback: ChatAggregate,
        reason: InvocationInterruptionReason,
        publication: ProfileReconsiderationPublicationRecoveryIntent?
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        switch await resolveProfileReconsiderationTerminalRecovery(
            request: request,
            publication: publication
        ) {
        case let .published(outcome):
            return outcome
        case let .eligible(authority):
            return profileReconsiderationTerminalOutcome(
                current: authority.aggregate,
                fallback: fallback,
                request: request,
                outcome: { .interrupted($0, reason) }
            )
        case let .ineligible(current, unresolvedPublication):
            if let unresolvedPublication {
                return retainOperationalProfileReconsiderationRetry(
                    request: request,
                    fallback: fallback,
                    publication: unresolvedPublication
                )
            }
            return profileReconsiderationTerminalOutcome(
                current: current,
                fallback: fallback,
                request: request,
                outcome: { .interrupted($0, reason) }
            )
        case let .unavailable(unresolvedPublication):
            return retainOperationalProfileReconsiderationRetry(
                request: request,
                fallback: fallback,
                publication: unresolvedPublication
            )
        }
    }

    private func resolveProfileReconsiderationTerminalRecovery(
        request: ProfileReconsiderationInvocationRequest,
        publication: ProfileReconsiderationPublicationRecoveryIntent?
    ) async -> ProfileReconsiderationTerminalRecoveryResolution {
        var unresolvedPublication:
            ProfileReconsiderationPublicationRecoveryIntent?
        if let publication {
            switch await resolveProfileReconsiderationPublicationRecovery(
                publication
            ) {
            case let .published(outcome):
                return .published(outcome)
            case .notPublished:
                break
            case let .unavailable(unresolved):
                unresolvedPublication = unresolved
            }
        }

        return switch await persistence
            .recoverProfileReconsiderationAfterTerminalFailure(request)
        {
        case let .eligible(authority):
            if let unresolvedPublication {
                .unavailable(
                    unresolvedPublication: unresolvedPublication
                )
            } else {
                .eligible(authority)
            }
        case let .ineligible(current):
            .ineligible(
                current,
                unresolvedPublication: unresolvedPublication
            )
        case .unavailable:
            .unavailable(unresolvedPublication: unresolvedPublication)
        }
    }

    private func resolveProfileReconsiderationPublicationRecovery(
        _ publication: ProfileReconsiderationPublicationRecoveryIntent,
        using session:
            (any InvocationProfileReconsiderationActivePersistenceSession)? = nil
    ) async -> ProfileReconsiderationPublicationRecoveryResolution {
        let recovery: InvocationPublicationRecoveryOutcome
        if let session {
            recovery = await session.recoverPublished(publication.mutation)
        } else {
            recovery = await persistence.recoverPublishedProfileReconsideration(
                publication.mutation
            )
        }
        switch recovery {
        case let .published(aggregate):
            removeOperationalProfileReconsiderationRetry(
                profileReconsiderationPublicationRequest(
                    for: publication.mutation
                )
            )
            return .published(
                publication.mutation.isWithdrawal
                    ? .withdrawn(aggregate, publication.quote)
                    : .published(aggregate, publication.quote)
            )
        case .notPublished:
            return .notPublished
        case .unavailable:
            return .unavailable(publication)
        }
    }

    private func profileReconsiderationPublicationRequest(
        for mutation: PublishProfileReconsiderationInvocationMutation
    ) -> ProfileReconsiderationInvocationRequest {
        ProfileReconsiderationInvocationRequest(
            library: LibraryScope(libraryID: mutation.invocation.libraryID),
            chatID: mutation.invocation.chatID,
            sourceEffectIdentity: mutation.reconsideration.sourceEffectIdentity,
            resultResponsePositionID:
                mutation.reconsideration.resultResponsePositionID
        )
    }

    private func profileReconsiderationTerminalOutcome(
        current: ChatAggregate?,
        fallback: ChatAggregate,
        request: ProfileReconsiderationInvocationRequest,
        outcome: (ChatAggregate) -> ProfileReconsiderationInvocationTryOutcome
    ) -> ProfileReconsiderationInvocationTryOutcome {
        guard let current else {
            return retainOperationalProfileReconsiderationRetry(
                request: request,
                fallback: fallback
            )
        }
        guard current.chat.id == request.chatID,
              current.profileEffect?.identity == request.sourceEffectIdentity,
              let reconsideration = current.profileReconsideration,
              reconsideration.sourceEffectIdentity ==
                request.sourceEffectIdentity,
              reconsideration.resultResponsePositionID ==
                request.resultResponsePositionID
        else {
            removeOperationalProfileReconsiderationRetry(request)
            return outcome(current)
        }
        guard reconsideration.failure != nil else {
            return retainOperationalProfileReconsiderationRetry(
                request: request,
                fallback: current
            )
        }
        removeOperationalProfileReconsiderationRetry(request)
        return outcome(current)
    }

    private func retainOperationalProfileReconsiderationRetry(
        request: ProfileReconsiderationInvocationRequest,
        fallback: ChatAggregate,
        publication: ProfileReconsiderationPublicationRecoveryIntent? = nil
    ) -> ProfileReconsiderationInvocationTryOutcome {
        rememberOperationalProfileReconsiderationRetry(
            request: request,
            fallback: fallback,
            publication: publication
        )
        return .operationallyInterrupted(
            fallback,
            request,
            .persistenceUnavailable
        )
    }

    private func rememberOperationalProfileReconsiderationRetry(
        request: ProfileReconsiderationInvocationRequest,
        fallback: ChatAggregate,
        publication: ProfileReconsiderationPublicationRecoveryIntent? = nil
    ) {
        removeOperationalProfileReconsiderationRetry(request)
        operationalProfileReconsiderationRetrySnapshots.append(
            OperationalProfileReconsiderationRetrySnapshot(
                request: request,
                fallback: fallback,
                publication: publication
            )
        )
    }

    private func removeOperationalProfileReconsiderationRetry(
        _ request: ProfileReconsiderationInvocationRequest
    ) {
        operationalProfileReconsiderationRetrySnapshots.removeAll {
            $0.request == request
        }
    }

    private func runProfileReconsideration(
        _ installedSession:
            any InvocationProfileReconsiderationActivePersistenceSession,
        prepared: PreparedCoachLaunchContext,
        observingStopAuthority observer:
            @escaping ProfileReconsiderationInvocationStopAuthorityObserver
    ) async -> ProfileReconsiderationInvocationTryOutcome {
        var activeSession = installedSession
        let processingAggregate = installedSession.processingAggregate
        guard let request = profileReconsiderationRequest(
            for: installedSession.invocation
        ) else {
            return await abortProfileReconsideration(
                installedSession,
                fallback: processingAggregate,
                request: installedSessionRequest(installedSession),
                failure: .coachResponseInterrupted,
                reason: .retryInfrastructureFailed
            )
        }
        let runID = UUID()
        defer { clearActiveProfileReconsiderationControl(runID: runID) }

        providerAttempts: while true {
            let invocation = activeSession.invocation
            let attempt = invocation.attempt
            let startedAt = retryTiming.nowMilliseconds()
            guard let transportAuthority = attempt.transportAuthority else {
                return await abortProfileReconsideration(
                    activeSession,
                    fallback: processingAggregate,
                    request: request,
                    failure: .coachResponseInterrupted,
                    reason: .retryInfrastructureFailed
                )
            }
            let pinnedInstruction = Self.pinnedInstruction(
                base: prepared.exchange.pinnedInstruction,
                attemptKind: attempt.kind
            )
            let completion = ProviderAttemptCompletion()
            let attemptExchange: AttemptBoundCoachExchange
            let transcriptAccess: ProviderAttemptTranscriptAccess?
            if prepared.exchange.preparedTranscriptHandles.isEmpty,
               transportAuthority.transcriptHandles.isEmpty
            {
                attemptExchange = AttemptBoundCoachExchange(
                    request: prepared.exchange.request,
                    transcriptHandles: []
                )
                transcriptAccess = nil
            } else {
                do {
                    let grant = try AttemptTranscriptAccessGrantIssuer().issue(
                        exchange: prepared.exchange,
                        freshHandles: transportAuthority.transcriptHandles,
                        pinnedInstruction: pinnedInstruction,
                        availabilityChecker: transcriptAvailability.checker(
                            library: request.library,
                            chatID: request.chatID
                        )
                    )
                    attemptExchange = grant.exchange
                    transcriptAccess = ProviderAttemptTranscriptAccess(
                        grant: grant,
                        completion: completion
                    )
                } catch {
                    return await abortProfileReconsideration(
                        activeSession,
                        fallback: processingAggregate,
                        request: request,
                        failure: .coachResponseInterrupted,
                        reason: .retryInfrastructureFailed
                    )
                }
            }
            guard !hasUnreapedProviderAuthority else {
                transcriptAccess?.closeReads()
                return await abortProfileReconsideration(
                    activeSession,
                    fallback: processingAggregate,
                    request: request,
                    failure: .coachResponseInterrupted,
                    reason: .retryInfrastructureFailed
                )
            }
            let control: CoachProviderAttemptControl = switch attempt.kind {
            case .standard:
                .standard
            case .shorterRepair:
                .shorterRepair(instruction: Self.shorterRepairInstruction)
            }
            let providerRequest = SyntheticCoachProviderRequest(
                attemptID: attempt.id,
                attemptOrdinal: attempt.ordinal,
                attemptKind: attempt.kind,
                providerIdempotencyValue:
                    transportAuthority.providerIdempotencyValue,
                exchange: attemptExchange,
                transcriptAccess: transcriptAccess,
                outputTokenCeiling: prepared.quote.reservedResponseTokens,
                pinnedInstruction: pinnedInstruction,
                control: control
            )
            let provider = self.provider
            let providerTask = Task {
                let result = await provider.run(providerRequest)
                await completion.complete(.provider(result))
            }
            let stopAuthority = ProfileReconsiderationInvocationStopAuthority(
                request: StopProfileReconsiderationInvocationRequest(request),
                invocationID: invocation.id,
                attemptID: attempt.id
            )
            activeProfileReconsiderationControls[
                stopAuthority.capabilityID
            ] = ActiveProfileReconsiderationControl(
                runID: runID,
                authority: stopAuthority,
                session: activeSession,
                fallback: processingAggregate,
                diagnosticContext: diagnosticContext(for: prepared),
                startedAtMilliseconds: startedAt,
                transcriptAccess: transcriptAccess,
                work: .provider(providerTask, completion),
                isRevoked: false,
                retainedTranscriptTerminalStatus: nil
            )
            await observer(stopAuthority)
            guard isProfileReconsiderationCompletionAuthorized(
                runID: runID,
                authority: stopAuthority
            ) else { return .stopped }

            let completionResult = await completion.wait()
            guard isProfileReconsiderationCompletionAuthorized(
                runID: runID,
                authority: stopAuthority
            ) else { return .stopped }

            let providerOutcome: CoachProviderAttemptOutcome?
            var transcriptStatus: AttemptTranscriptAccessBrokerStatus?
            var providerReaped = false
            switch completionResult {
            case .stopped:
                return .stopped
            case let .provider(value):
                providerOutcome = value
                if let transcriptAccess {
                    let reason: AttemptTranscriptAccessRevocationReason =
                        switch value {
                        case .complete: .attemptCompleted
                        case .autoRetryableFailure, .userRetryableFailure:
                            .providerFailed
                        case .responseOverflow: .protocolFailure
                        }
                    let status = await transcriptAccess.finalize(reason: reason)
                    transcriptStatus = status == .checking
                        ? .terminal(.rejected)
                        : status
                }
            case let .transcript(status):
                providerOutcome = nil
                transcriptStatus = .terminal(status)
                recordProfileReconsiderationTranscriptTerminalStatus(
                    status,
                    runID: runID,
                    authority: stopAuthority
                )
                transcriptAccess?.closeReads()
                providerTask.cancel()
                let cancellation = await provider.cancelAndReap(
                    attemptID: attempt.id,
                    graceMilliseconds:
                        Self.providerCancellationGraceMilliseconds
                )
                guard isProfileReconsiderationCompletionAuthorized(
                    runID: runID,
                    authority: stopAuthority
                ) else { return .stopped }
                guard cancellation == .reaped ||
                    cancellation == .alreadyAbsent
                else {
                    retainUnreapedProfileReconsiderationControl(
                        runID: runID,
                        authority: stopAuthority,
                        transcriptStatus: status
                    )
                    return .providerReapPending(stopAuthority)
                }
                providerReaped = true
            }

            if case let .terminal(status)? = transcriptStatus,
               status != .completed
            {
                recordProfileReconsiderationTranscriptTerminalStatus(
                    status,
                    runID: runID,
                    authority: stopAuthority
                )
                if !providerReaped {
                    providerTask.cancel()
                    let cancellation = await provider.cancelAndReap(
                        attemptID: attempt.id,
                        graceMilliseconds:
                            Self.providerCancellationGraceMilliseconds
                    )
                    guard isProfileReconsiderationCompletionAuthorized(
                        runID: runID,
                        authority: stopAuthority
                    ) else { return .stopped }
                    guard cancellation == .reaped ||
                        cancellation == .alreadyAbsent
                    else {
                        retainUnreapedProfileReconsiderationControl(
                            runID: runID,
                            authority: stopAuthority,
                            transcriptStatus: status
                        )
                        return .providerReapPending(stopAuthority)
                    }
                }
                guard claimProfileReconsiderationCompletion(
                    runID: runID,
                    authority: stopAuthority
                ) else { return .stopped }
                let failure = retainedTerminalFailure(for: status)
                let reason: InvocationInterruptionReason = switch status {
                case .sessionUnavailable:
                    .providerFailed
                case .contextCannotFit:
                    .retryInfrastructureFailed
                case .rejected, .revoked, .completed:
                    .invalidProviderResponse
                }
                let aborted = await abortProfileReconsideration(
                    activeSession,
                    fallback: processingAggregate,
                    request: request,
                    failure: failure,
                    reason: reason
                )
                if status == .contextCannotFit,
                   case let .interrupted(current?, _) = aborted
                {
                    return .contextCapacityFailure(current, prepared.quote)
                }
                return aborted
            }
            guard let providerOutcome else {
                return await abortProfileReconsideration(
                    activeSession,
                    fallback: processingAggregate,
                    request: request,
                    failure: .coachResponseInvalid,
                    reason: .invalidProviderResponse
                )
            }

            switch providerOutcome {
            case let .complete(response):
                let completedAt = await clock.now()
                let publication: PublishProfileReconsiderationInvocationMutation
                do {
                    try invocation.validate(against: processingAggregate)
                    let validationContext = try CoachResponseValidationContext(
                        prepared: prepared,
                        base: processingAggregate
                    )
                    let validated = try CoachResponseValidator().validate(
                        response,
                        in: validationContext
                    )
                    let memory = try await replacementMemory(
                        from: validated,
                        base: processingAggregate,
                        at: completedAt
                    )
                    publication = try PublishProfileReconsiderationInvocationMutation(
                        base: processingAggregate,
                        invocation: invocation,
                        reconsideration: activeSession.reconsideration,
                        basis: activeSession.basis,
                        validatedResponse: validated,
                        replacementMemory: memory,
                        completedAt: completedAt
                    )
                } catch {
                    guard claimProfileReconsiderationCompletion(
                        runID: runID,
                        authority: stopAuthority
                    ) else { return .stopped }
                    return await abortProfileReconsideration(
                        activeSession,
                        fallback: processingAggregate,
                        request: request,
                        failure: .coachResponseInvalid,
                        reason: .invalidProviderResponse
                    )
                }
                guard claimProfileReconsiderationCompletion(
                    runID: runID,
                    authority: stopAuthority
                ) else { return .stopped }
                switch await activeSession.publish(publication) {
                case let .committed(current):
                    return publication.isWithdrawal
                        ? .withdrawn(current, prepared.quote)
                        : .published(current, prepared.quote)
                case let .stale(current):
                    return await interruptProfileReconsiderationPublicationAndAbort(
                        activeSession,
                        fallback: current ?? processingAggregate,
                        request: request,
                        reason: .publicationConflict,
                        publication:
                            ProfileReconsiderationPublicationRecoveryIntent(
                                mutation: publication,
                                quote: prepared.quote
                            )
                    )
                case .failed:
                    return await interruptProfileReconsiderationPublicationAndAbort(
                        activeSession,
                        fallback: processingAggregate,
                        request: request,
                        reason: .persistenceUnavailable,
                        publication:
                            ProfileReconsiderationPublicationRecoveryIntent(
                                mutation: publication,
                                quote: prepared.quote
                            )
                    )
                }

            case .userRetryableFailure:
                guard claimProfileReconsiderationCompletion(
                    runID: runID,
                    authority: stopAuthority
                ) else { return .stopped }
                return await abortProfileReconsideration(
                    activeSession,
                    fallback: processingAggregate,
                    request: request,
                    failure: .coachProviderError,
                    reason: .providerFailed
                )

            case .autoRetryableFailure:
                guard attempt.kind == .standard,
                      attempt.ordinal < CoachProviderAttempt.maximumOrdinal
                else {
                    guard claimProfileReconsiderationCompletion(
                        runID: runID,
                        authority: stopAuthority
                    ) else { return .stopped }
                    return await abortProfileReconsideration(
                        activeSession,
                        fallback: processingAggregate,
                        request: request,
                        failure: .coachProviderError,
                        reason: .providerFailed
                    )
                }
                let index = Int(attempt.ordinal - 1)
                guard Self.automaticRetryDelaysMilliseconds.indices
                    .contains(index)
                else {
                    guard claimProfileReconsiderationCompletion(
                        runID: runID,
                        authority: stopAuthority
                    ) else { return .stopped }
                    return await abortProfileReconsideration(
                        activeSession,
                        fallback: processingAggregate,
                        request: request,
                        failure: .coachResponseInterrupted,
                        reason: .retryInfrastructureFailed
                    )
                }
                let sleeper = self.retrySleeper
                let backoff = BackoffCompletion()
                let backoffTask = Task {
                    do {
                        try await sleeper.sleep(
                            milliseconds:
                                Self.automaticRetryDelaysMilliseconds[index]
                        )
                        await backoff.complete(.elapsed)
                    } catch {
                        await backoff.complete(.failed)
                    }
                }
                updateActiveProfileReconsiderationWork(
                    .backoff(backoffTask, backoff),
                    runID: runID,
                    authority: stopAuthority
                )
                await observer(stopAuthority)
                switch await backoff.wait() {
                case .stopped:
                    return .stopped
                case .failed:
                    guard claimProfileReconsiderationCompletion(
                        runID: runID,
                        authority: stopAuthority
                    ) else { return .stopped }
                    return await abortProfileReconsideration(
                        activeSession,
                        fallback: processingAggregate,
                        request: request,
                        failure: .coachResponseInterrupted,
                        reason: .retryInfrastructureFailed
                    )
                case .elapsed:
                    break
                }
                let transition = Task {
                    await self.installNextProfileReconsiderationAttempt(
                        after: activeSession,
                        kind: .standard,
                        prepared: prepared,
                        fallback: processingAggregate,
                        request: request,
                        runID: runID,
                        authority: stopAuthority
                    )
                }
                updateActiveProfileReconsiderationWork(
                    .transition(transition),
                    runID: runID,
                    authority: stopAuthority
                )
                switch await transition.value {
                case let .installed(next):
                    guard claimProfileReconsiderationCompletion(
                        runID: runID,
                        authority: stopAuthority
                    ) else { return .stopped }
                    activeSession = next
                case let .terminal(outcome):
                    return outcome
                case .revoked:
                    return .stopped
                }

            case .responseOverflow:
                guard attempt.kind == .standard,
                      attempt.ordinal < CoachProviderAttempt.maximumOrdinal
                else {
                    guard claimProfileReconsiderationCompletion(
                        runID: runID,
                        authority: stopAuthority
                    ) else { return .stopped }
                    return await abortProfileReconsideration(
                        activeSession,
                        fallback: processingAggregate,
                        request: request,
                        failure: .coachResponseInvalid,
                        reason: .invalidProviderResponse
                    )
                }
                let transition = Task {
                    await self.installNextProfileReconsiderationAttempt(
                        after: activeSession,
                        kind: .shorterRepair,
                        prepared: prepared,
                        fallback: processingAggregate,
                        request: request,
                        runID: runID,
                        authority: stopAuthority
                    )
                }
                updateActiveProfileReconsiderationWork(
                    .transition(transition),
                    runID: runID,
                    authority: stopAuthority
                )
                switch await transition.value {
                case let .installed(next):
                    guard claimProfileReconsiderationCompletion(
                        runID: runID,
                        authority: stopAuthority
                    ) else { return .stopped }
                    activeSession = next
                case let .terminal(outcome):
                    return outcome
                case .revoked:
                    return .stopped
                }
            }
        }
    }

    private func installNextProfileReconsiderationAttempt(
        after session:
            any InvocationProfileReconsiderationActivePersistenceSession,
        kind: CoachProviderAttemptKind,
        prepared: PreparedCoachLaunchContext,
        fallback: ChatAggregate,
        request: ProfileReconsiderationInvocationRequest,
        runID: UUID,
        authority: ProfileReconsiderationInvocationStopAuthority
    ) async -> ProfileReconsiderationNextAttemptResolution {
        let ordinal = session.invocation.attempt.ordinal + 1
        for _ in 0 ..< Self.maximumLaunchIdentityCandidates {
            guard isProfileReconsiderationCompletionAuthorized(
                runID: runID,
                authority: authority
            ) else { return .revoked(session) }
            let identity = await identities
                .generateProfileReconsiderationAttemptIdentity(
                    at: await clock.now(),
                    ordinal: ordinal,
                    kind: kind,
                    transcriptHandleCount:
                        prepared.exchange.preparedTranscriptHandles.count
                )
            let mutation: InstallNextProfileReconsiderationAttemptMutation
            do {
                mutation = try InstallNextProfileReconsiderationAttemptMutation(
                    base: session.invocation,
                    identity: identity,
                    kind: kind
                )
                try AttemptTranscriptAccessGrantIssuer().preflight(
                    exchange: prepared.exchange,
                    freshHandles: identity.transcriptHandles,
                    pinnedInstruction: Self.pinnedInstruction(
                        base: prepared.exchange.pinnedInstruction,
                        attemptKind: kind
                    )
                )
            } catch let error as InstallNextCoachProviderAttemptMutationError {
                if case .identityCollision = error { continue }
                return .terminal(
                    await abortProfileReconsideration(
                        session,
                        fallback: fallback,
                        request: request,
                        failure: .coachResponseInterrupted,
                        reason: .retryInfrastructureFailed
                    )
                )
            } catch AttemptTranscriptAccessGrantIssueError.contextCannotFit {
                return .terminal(
                    await abortProfileReconsideration(
                        session,
                        fallback: fallback,
                        request: request,
                        failure: .coachContextCannotFit,
                        reason: .retryInfrastructureFailed
                    )
                )
            } catch {
                return .terminal(
                    await abortProfileReconsideration(
                        session,
                        fallback: fallback,
                        request: request,
                        failure: .coachResponseInterrupted,
                        reason: .retryInfrastructureFailed
                    )
                )
            }
            guard isProfileReconsiderationCompletionAuthorized(
                runID: runID,
                authority: authority
            ) else { return .revoked(session) }
            switch await session.installNextAttempt(mutation) {
            case let .installed(next):
                return .installed(next)
            case .collision:
                continue
            case let .stale(current):
                return .terminal(
                    await abortProfileReconsideration(
                        session,
                        fallback: current ?? fallback,
                        request: request,
                        failure: .coachResponseInterrupted,
                        reason: .persistenceUnavailable
                    )
                )
            case .failed:
                return .terminal(
                    await abortProfileReconsideration(
                        session,
                        fallback: fallback,
                        request: request,
                        failure: .coachResponseInterrupted,
                        reason: .retryInfrastructureFailed
                    )
                )
            }
        }
        return .terminal(
            await abortProfileReconsideration(
                session,
                fallback: fallback,
                request: request,
                failure: .coachResponseInterrupted,
                reason: .retryInfrastructureFailed
            )
        )
    }

    private func profileReconsiderationRequest(
        for invocation: CoachInvocation
    ) -> ProfileReconsiderationInvocationRequest? {
        guard case let .reconsiderProfileChange(
            sourceEffectIdentity,
            resultResponsePositionID
        ) = invocation.intent else { return nil }
        return ProfileReconsiderationInvocationRequest(
            library: LibraryScope(libraryID: invocation.libraryID),
            chatID: invocation.chatID,
            sourceEffectIdentity: sourceEffectIdentity,
            resultResponsePositionID: resultResponsePositionID
        )
    }

    private func installedSessionRequest(
        _ session:
            any InvocationProfileReconsiderationActivePersistenceSession
    ) -> ProfileReconsiderationInvocationRequest {
        ProfileReconsiderationInvocationRequest(
            library: LibraryScope(libraryID: session.invocation.libraryID),
            chatID: session.invocation.chatID,
            sourceEffectIdentity:
                session.reconsideration.sourceEffectIdentity,
            resultResponsePositionID:
                session.reconsideration.resultResponsePositionID
        )
    }

    private func invoke(
        _ session: any InvocationPendingPersistenceSession,
        observingStopAuthority observer: @escaping InvocationStopAuthorityObserver
    ) async -> InvocationTryOutcome {
        let firstAuthority = session.authority
        let request = firstAuthority.request
        let draft = firstAuthority.aggregate.chat.draft
        guard draft.text.utf8.count <= CoachContextInputLimits.maximumUserMessageUTF8Bytes else {
            return await reject(
                session,
                fallback: firstAuthority,
                reason: .messageMustBeShortened(
                    maximumUTF8Bytes: CoachContextInputLimits.maximumUserMessageUTF8Bytes
                )
            )
        }
        guard draft.text.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) else {
            return await reject(session, fallback: firstAuthority, reason: .eligibilityChanged)
        }

        let contextRequest: CoachContextPendingTurnRequest
        do {
            contextRequest = try CoachContextPendingTurnRequest(
                library: request.library,
                chatID: request.chatID,
                draft: draft,
                pendingUserTurn: firstAuthority.pendingUserTurn
            )
        } catch {
            return await reject(session, fallback: firstAuthority, reason: .eligibilityChanged)
        }

        let prepared: PreparedCoachLaunchContext
        switch await coachContext.preparePendingUserTurn(contextRequest) {
        case let .prepared(value):
            prepared = value
        case let .cannotFit(failure):
            let outcome: InvocationTryOutcome = switch await session.terminate(
                .contextCapacityFailure
            ) {
            case let .committed(aggregate):
                .contextCapacityFailure(aggregate, failure.quote)
            case let .stale(current):
                .rejected(current, .eligibilityChanged)
            case let .recovered(resolution):
                interruptionAfterTerminalRecovery(
                    resolution,
                    request: firstAuthority.request,
                    fallback: firstAuthority.aggregate
                )
            }
            if presentsUserRetry(outcome, request: request) {
                await recordRetryDiagnostic(
                    reason: .contextCapacityExceeded,
                    classification: .contextCapacity,
                    disposition: .userRetryableFailure,
                    invocation: nil,
                    context: diagnosticContext(for: failure.quote),
                    durationMilliseconds: 0
                )
            }
            return outcome
        case let .messageTooLong(maximumUTF8Bytes):
            return await reject(
                session,
                fallback: firstAuthority,
                reason: .messageMustBeShortened(maximumUTF8Bytes: maximumUTF8Bytes)
            )
        case let .unavailable(reason):
            return await reject(
                session,
                fallback: firstAuthority,
                reason: .contextUnavailable(reason)
            )
        }

        let finalAuthority: InvocationPendingAuthority
        switch await session.revalidate() {
        case let .eligible(authority) where authority == firstAuthority:
            finalAuthority = authority
        case let .eligible(authority):
            return await reject(session, fallback: authority, reason: .eligibilityChanged)
        case let .ineligible(current):
            return .rejected(current, .eligibilityChanged)
        case .unavailable:
            return await reject(
                session,
                fallback: firstAuthority,
                reason: .persistenceUnavailable
            )
        }

        let identityInstant = await clock.now()
        var invocationID = await identities.generateInvocationID(at: identityInstant)
        var selectedIdentity: InvocationLaunchIdentity?
        var lastCollision: InvocationLaunchIdentityCollision?
        for _ in 0 ..< Self.maximumLaunchIdentityCandidates {
            let attemptIdentity = await identities.generateAttemptIdentity(
                at: identityInstant,
                ordinal: 1,
                kind: .standard,
                transcriptHandleCount: prepared.exchange.preparedTranscriptHandles.count
            )
            guard attemptIdentity.transcriptHandles.count ==
                prepared.exchange.preparedTranscriptHandles.count,
                (try? attemptIdentity.makeAttempt(ordinal: 1, kind: .standard)) != nil
            else {
                return await reject(
                    session,
                    fallback: finalAuthority,
                    reason: .persistenceUnavailable
                )
            }
            let candidate = InvocationLaunchIdentity(
                invocationID: invocationID,
                attemptIdentity: attemptIdentity
            )
            switch await session.checkLaunchIdentity(candidate) {
            case .available:
                selectedIdentity = candidate
            case let .collision(collision):
                lastCollision = collision
                if collision == .invocationID {
                    invocationID = await identities.generateInvocationID(at: identityInstant)
                }
                continue
            case let .stale(current):
                if let current,
                   let currentAuthority = try? InvocationPendingAuthority(
                       request: request,
                       aggregate: current
                   )
                {
                    return await reject(
                        session,
                        fallback: currentAuthority,
                        reason: .eligibilityChanged
                    )
                }
                await session.abandon()
                return .rejected(current, .eligibilityChanged)
            case .unavailable:
                return await reject(
                    session,
                    fallback: finalAuthority,
                    reason: .persistenceUnavailable
                )
            }
            break
        }
        guard let identity = selectedIdentity else {
            return await reject(
                session,
                fallback: finalAuthority,
                reason: .identityCollisionExhausted(
                    lastCollision: lastCollision ?? .invocationID
                )
            )
        }

        do {
            try AttemptTranscriptAccessGrantIssuer().preflight(
                exchange: prepared.exchange,
                freshHandles: identity.transcriptHandles,
                pinnedInstruction: prepared.exchange.pinnedInstruction
            )
        } catch AttemptTranscriptAccessGrantIssueError.contextCannotFit {
            let outcome: InvocationTryOutcome = switch await session.terminate(
                .contextCapacityFailure
            ) {
            case let .committed(aggregate):
                .contextCapacityFailure(aggregate, prepared.quote)
            case let .stale(current):
                .rejected(current, .eligibilityChanged)
            case let .recovered(resolution):
                interruptionAfterTerminalRecovery(
                    resolution,
                    request: request,
                    fallback: finalAuthority.aggregate
                )
            }
            if presentsUserRetry(outcome, request: request) {
                await recordRetryDiagnostic(
                    reason: .transcriptContextCannotFit,
                    classification: .contextCapacity,
                    disposition: .userRetryableFailure,
                    invocation: nil,
                    context: diagnosticContext(for: prepared),
                    durationMilliseconds: 0
                )
            }
            return outcome
        } catch {
            return await reject(
                session,
                fallback: finalAuthority,
                reason: .persistenceUnavailable
            )
        }

        // Identity discovery may scan every durable namespace. Debit against a
        // fresh instant so the rolling window starts when admission is claimed,
        // not when that potentially slow preflight began.
        let admittedAt = await clock.now()
        switch await admission.claim(library: request.library, at: admittedAt) {
        case .admitted:
            break
        case .commitUncertain:
            let outcome = await interruptPending(
                session,
                fallback: finalAuthority,
                reason: .persistenceUnavailable
            )
            if presentsUserRetry(outcome, request: request) {
                await recordRetryDiagnostic(
                    reason: .admissionCommitUncertain,
                    classification: .interruption,
                    disposition: .userRetryableFailure,
                    invocation: nil,
                    context: diagnosticContext(for: prepared),
                    durationMilliseconds: 0
                )
            }
            return outcome
        case .cooldown:
            return await rejectAdmission(
                session,
                fallback: finalAuthority,
                request: request,
                prepared: prepared,
                reason: .admissionCooldown,
                diagnosticReason: .admissionCooldown
            )
        case .clockRollback:
            return await rejectAdmission(
                session,
                fallback: finalAuthority,
                request: request,
                prepared: prepared,
                reason: .clockRollback,
                diagnosticReason: .admissionClockRollback
            )
        case .ledgerFull:
            return await rejectAdmission(
                session,
                fallback: finalAuthority,
                request: request,
                prepared: prepared,
                reason: .admissionLedgerFull,
                diagnosticReason: .admissionLedgerFull
            )
        case .unavailable:
            return await rejectAdmission(
                session,
                fallback: finalAuthority,
                request: request,
                prepared: prepared,
                reason: .admissionUnavailable,
                diagnosticReason: .admissionUnavailable
            )
        }

        let install: InstallCoachInvocationMutation
        do {
            install = try InstallCoachInvocationMutation(
                authority: finalAuthority,
                identity: identity,
                preparedProfile: prepared.authority.profile,
                admittedAt: admittedAt
            )
        } catch {
            return await interruptPending(
                session,
                fallback: finalAuthority,
                reason: .persistenceUnavailable
            )
        }

        var activeSession: any InvocationActivePersistenceSession
        switch await session.install(install) {
        case let .installed(installed):
            activeSession = installed
        case .blockedByActiveInvocation:
            return await interruptPending(
                session,
                fallback: finalAuthority,
                reason: .persistenceUnavailable
            )
        case let .stale(current):
            if let current,
               let currentAuthority = try? InvocationPendingAuthority(
                   request: request,
                   aggregate: current
               )
            {
                return await interruptPending(
                    session,
                    fallback: currentAuthority,
                    reason: .persistenceUnavailable
                )
            }
            await session.abandon()
            return .rejected(current, .eligibilityChanged)
        case .failed:
            return await interruptPending(
                session,
                fallback: finalAuthority,
                reason: .persistenceUnavailable
            )
        }
        let processingAggregate = activeSession.processingAggregate
        guard await coachContext.isPreparedContextCurrent(prepared) else {
            let invocation = activeSession.invocation
            let outcome: InvocationTryOutcome = switch await activeSession.abort() {
            case let .committed(aggregate):
                .rejected(aggregate, .contextChanged)
            case let .stale(current):
                outcomeAfterStaleContextAbort(
                    current: current,
                    fallback: processingAggregate,
                    invocation: invocation
                )
            case let .recovered(resolution):
                interruptionAfterTerminalRecovery(
                    resolution,
                    request: finalAuthority.request,
                    fallback: processingAggregate
                )
            }
            if presentsUserRetry(outcome, request: request) {
                await recordRetryDiagnostic(
                    reason: .preparedContextStale,
                    classification: .interruption,
                    disposition: .userRetryableFailure,
                    invocation: invocation,
                    context: diagnosticContext(for: prepared),
                    durationMilliseconds: 0
                )
            }
            return outcome
        }

        let completedProviderResponse: (
            response: CoachProviderCompleteResponse,
            startedAtMilliseconds: UInt64,
            stopAuthority: InvocationStopAuthority
        )
        let runID = UUID()
        defer { clearActiveInvocationControl(runID: runID) }
        providerAttempts: while true {
            let invocation = activeSession.invocation
            let attempt = invocation.attempt
            let attemptStartedAt = retryTiming.nowMilliseconds()
            guard let transportAuthority = attempt.transportAuthority else {
                return await interruptAndAbortRecordingUserRetry(
                    activeSession,
                    fallback: processingAggregate,
                    reason: .retryInfrastructureFailed,
                    diagnosticReason: .missingAttemptTransportAuthority,
                    classification: .retryInfrastructureFailure,
                    prepared: prepared,
                    startedAt: attemptStartedAt
                )
            }
            let control: CoachProviderAttemptControl = switch attempt.kind {
            case .standard:
                .standard
            case .shorterRepair:
                .shorterRepair(instruction: Self.shorterRepairInstruction)
            }
            let outputTokenCeiling = prepared.quote.reservedResponseTokens
            let pinnedInstruction = Self.pinnedInstruction(
                base: prepared.exchange.pinnedInstruction,
                attemptKind: attempt.kind
            )
            let providerCompletion = ProviderAttemptCompletion()
            let attemptExchange: AttemptBoundCoachExchange
            let transcriptAccess: ProviderAttemptTranscriptAccess?
            if prepared.exchange.preparedTranscriptHandles.isEmpty,
               transportAuthority.transcriptHandles.isEmpty
            {
                attemptExchange = AttemptBoundCoachExchange(
                    request: prepared.exchange.request,
                    transcriptHandles: []
                )
                transcriptAccess = nil
            } else {
                do {
                    let grant = try AttemptTranscriptAccessGrantIssuer().issue(
                        exchange: prepared.exchange,
                        freshHandles: transportAuthority.transcriptHandles,
                        pinnedInstruction: pinnedInstruction,
                        availabilityChecker: transcriptAvailability.checker(
                            library: request.library,
                            chatID: request.chatID
                        )
                    )
                    attemptExchange = grant.exchange
                    transcriptAccess = ProviderAttemptTranscriptAccess(
                        grant: grant,
                        completion: providerCompletion
                    )
                } catch {
                    return await interruptAndAbortRecordingUserRetry(
                        activeSession,
                        fallback: processingAggregate,
                        reason: .retryInfrastructureFailed,
                        diagnosticReason: .attemptTranscriptAccessLaunchFailed,
                        classification: .retryInfrastructureFailure,
                        prepared: prepared,
                        startedAt: attemptStartedAt
                    )
                }
            }
            guard !activeInvocationControls.values.contains(where: {
                $0.runID != runID && $0.isRevoked
            }) else {
                transcriptAccess?.closeReads()
                return await interruptAndAbortRecordingUserRetry(
                    activeSession,
                    fallback: processingAggregate,
                    reason: .retryInfrastructureFailed,
                    diagnosticReason: .unreapedProviderBlockedSuccessor,
                    classification: .retryInfrastructureFailure,
                    prepared: prepared,
                    startedAt: attemptStartedAt
                )
            }
            let providerRequest = SyntheticCoachProviderRequest(
                attemptID: attempt.id,
                attemptOrdinal: attempt.ordinal,
                attemptKind: attempt.kind,
                providerIdempotencyValue:
                    transportAuthority.providerIdempotencyValue,
                exchange: attemptExchange,
                transcriptAccess: transcriptAccess,
                outputTokenCeiling: outputTokenCeiling,
                pinnedInstruction: pinnedInstruction,
                control: control
            )
            let provider = self.provider
            let providerTask = Task {
                let outcome = await provider.run(providerRequest)
                await providerCompletion.complete(.provider(outcome))
            }
            let stopAuthority = InvocationStopAuthority(
                request: stopRequest(for: invocation),
                invocationID: invocation.id,
                attemptID: attempt.id
            )
            activeInvocationControls[stopAuthority.capabilityID] = ActiveInvocationControl(
                runID: runID,
                authority: stopAuthority,
                session: activeSession,
                fallback: processingAggregate,
                diagnosticContext: diagnosticContext(for: prepared),
                startedAtMilliseconds: attemptStartedAt,
                transcriptAccess: transcriptAccess,
                work: .provider(providerTask, providerCompletion),
                isRevoked: false,
                retainedTranscriptTerminalStatus: nil
            )
            await observer(stopAuthority)
            guard isCompletionAuthorized(runID: runID, authority: stopAuthority) else {
                return stoppedInvocationOutcome(fallback: processingAggregate)
            }
            let completion = await providerCompletion.wait()
            guard isCompletionAuthorized(runID: runID, authority: stopAuthority) else {
                return stoppedInvocationOutcome(fallback: processingAggregate)
            }
            let outcome: CoachProviderAttemptOutcome?
            let transcriptStatus: AttemptTranscriptAccessBrokerStatus?
            var providerWasReapedForTranscriptTerminal = false
            switch completion {
            case .stopped:
                return stoppedInvocationOutcome(fallback: processingAggregate)
            case let .provider(value):
                outcome = value
                if let transcriptAccess {
                    let revocationReason: AttemptTranscriptAccessRevocationReason =
                        switch value {
                        case .complete: .attemptCompleted
                        case .autoRetryableFailure, .userRetryableFailure:
                            .providerFailed
                        case .responseOverflow: .protocolFailure
                        }
                    let finalizedStatus = await transcriptAccess.finalize(
                        reason: revocationReason
                    )
                    transcriptStatus = finalizedStatus == .checking
                        ? .terminal(.rejected)
                        : finalizedStatus
                } else {
                    transcriptStatus = nil
                }
            case let .transcript(status):
                outcome = nil
                transcriptStatus = .terminal(status)
                recordTranscriptTerminalStatus(
                    status,
                    runID: runID,
                    authority: stopAuthority
                )
                transcriptAccess?.closeReads()
                providerTask.cancel()
                let cancellation = await provider.cancelAndReap(
                    attemptID: attempt.id,
                    graceMilliseconds: Self.providerCancellationGraceMilliseconds
                )
                guard isCompletionAuthorized(
                    runID: runID,
                    authority: stopAuthority
                ) else {
                    return stoppedInvocationOutcome(fallback: processingAggregate)
                }
                guard cancellation == .reaped || cancellation == .alreadyAbsent else {
                    retainUnreapedProviderControl(
                        runID: runID,
                        authority: stopAuthority,
                        transcriptStatus: status
                    )
                    return .providerReapPending(stopAuthority)
                }
                providerWasReapedForTranscriptTerminal = true
            }
            guard isCompletionAuthorized(runID: runID, authority: stopAuthority) else {
                return stoppedInvocationOutcome(fallback: processingAggregate)
            }

            if case let .terminal(status)? = transcriptStatus,
               status != .completed
            {
                recordTranscriptTerminalStatus(
                    status,
                    runID: runID,
                    authority: stopAuthority
                )
                if !providerWasReapedForTranscriptTerminal {
                    providerTask.cancel()
                    let cancellation = await provider.cancelAndReap(
                        attemptID: attempt.id,
                        graceMilliseconds: Self.providerCancellationGraceMilliseconds
                    )
                    guard isCompletionAuthorized(
                        runID: runID,
                        authority: stopAuthority
                    ) else {
                        return stoppedInvocationOutcome(fallback: processingAggregate)
                    }
                    guard cancellation == .reaped || cancellation == .alreadyAbsent
                    else {
                        retainUnreapedProviderControl(
                            runID: runID,
                            authority: stopAuthority,
                            transcriptStatus: status
                        )
                        return .providerReapPending(stopAuthority)
                    }
                }

                guard claimCompletion(runID: runID, authority: stopAuthority) else {
                    return stoppedInvocationOutcome(fallback: processingAggregate)
                }
                switch status {
                case let .sessionUnavailable(sessions):
                    guard let terminalFailure = transcriptReadFailure(
                        sessions: sessions
                    ) else {
                        return await interruptAndAbortRecordingUserRetry(
                            activeSession,
                            fallback: processingAggregate,
                            reason: .invalidProviderResponse,
                            diagnosticReason: .transcriptAccessProtocolFailure,
                            classification: .invalidProviderResponse,
                            prepared: prepared,
                            startedAt: attemptStartedAt
                        )
                    }
                    return await interruptAndAbortRecordingUserRetry(
                        activeSession,
                        fallback: processingAggregate,
                        reason: .providerFailed,
                        diagnosticReason: .transcriptSessionUnavailable,
                        classification: .transcriptReadFailure,
                        prepared: prepared,
                        startedAt: attemptStartedAt,
                        terminalFailure: terminalFailure
                    )
                case .contextCannotFit:
                    return await abortTranscriptContextCannotFit(
                        activeSession,
                        fallback: processingAggregate,
                        prepared: prepared,
                        startedAt: attemptStartedAt
                    )
                case .rejected, .revoked:
                    return await interruptAndAbortRecordingUserRetry(
                        activeSession,
                        fallback: processingAggregate,
                        reason: .invalidProviderResponse,
                        diagnosticReason: .transcriptAccessProtocolFailure,
                        classification: .invalidProviderResponse,
                        prepared: prepared,
                        startedAt: attemptStartedAt
                    )
                case .completed:
                    preconditionFailure("handled above")
                }
            }
            guard let outcome else {
                preconditionFailure("terminal transcript completion was not handled")
            }
            switch outcome {
            case let .complete(response):
                completedProviderResponse = (response, attemptStartedAt, stopAuthority)
                break providerAttempts
            case .userRetryableFailure:
                guard claimCompletion(runID: runID, authority: stopAuthority) else {
                    return stoppedInvocationOutcome(fallback: processingAggregate)
                }
                return await interruptAndAbortRecordingUserRetry(
                    activeSession,
                    fallback: processingAggregate,
                    reason: .providerFailed,
                    diagnosticReason: .providerUserRetryable,
                    classification: .providerUserRetryable,
                    prepared: prepared,
                    startedAt: attemptStartedAt
                )
            case .autoRetryableFailure:
                guard attempt.kind == .standard,
                      attempt.ordinal < CoachProviderAttempt.maximumOrdinal
                else {
                    guard claimCompletion(runID: runID, authority: stopAuthority) else {
                        return stoppedInvocationOutcome(fallback: processingAggregate)
                    }
                    return await interruptAndAbortRecordingUserRetry(
                        activeSession,
                        fallback: processingAggregate,
                        reason: .providerFailed,
                        diagnosticReason: attempt.kind == .shorterRepair
                            ? .shorterRepairProviderFailure
                            : .automaticRetriesExhausted,
                        classification: .providerUserRetryable,
                        prepared: prepared,
                        startedAt: attemptStartedAt
                    )
                }
                let delayIndex = Int(attempt.ordinal - 1)
                guard Self.automaticRetryDelaysMilliseconds.indices.contains(delayIndex)
                else {
                    guard claimCompletion(runID: runID, authority: stopAuthority) else {
                        return stoppedInvocationOutcome(fallback: processingAggregate)
                    }
                    return await interruptAndAbortRecordingUserRetry(
                        activeSession,
                        fallback: processingAggregate,
                        reason: .retryInfrastructureFailed,
                        diagnosticReason: .retryScheduleUnavailable,
                        classification: .retryInfrastructureFailure,
                        prepared: prepared,
                        startedAt: attemptStartedAt
                    )
                }
                await recordRetryDiagnostic(
                    reason: .providerAutoRetryable,
                    classification: .providerAutoRetryable,
                    disposition: .automaticRetry,
                    invocation: invocation,
                    prepared: prepared,
                    startedAt: attemptStartedAt
                )
                guard isCompletionAuthorized(runID: runID, authority: stopAuthority) else {
                    return stoppedInvocationOutcome(fallback: processingAggregate)
                }
                let retrySleeper = self.retrySleeper
                let backoffCompletion = BackoffCompletion()
                let backoffTask = Task {
                    do {
                        try await retrySleeper.sleep(
                            milliseconds: Self.automaticRetryDelaysMilliseconds[delayIndex]
                        )
                        await backoffCompletion.complete(.elapsed)
                    } catch {
                        await backoffCompletion.complete(.failed)
                    }
                }
                updateActiveInvocationWork(
                    .backoff(backoffTask, backoffCompletion),
                    runID: runID,
                    authority: stopAuthority
                )
                await observer(stopAuthority)
                guard isCompletionAuthorized(
                    runID: runID,
                    authority: stopAuthority
                ) else {
                    return stoppedInvocationOutcome(fallback: processingAggregate)
                }
                switch await backoffCompletion.wait() {
                case .stopped:
                    return stoppedInvocationOutcome(fallback: processingAggregate)
                case .elapsed:
                    guard isCompletionAuthorized(
                        runID: runID,
                        authority: stopAuthority
                    ) else {
                        return stoppedInvocationOutcome(fallback: processingAggregate)
                    }
                case .failed:
                    guard claimCompletion(runID: runID, authority: stopAuthority) else {
                        return stoppedInvocationOutcome(fallback: processingAggregate)
                    }
                    return await interruptAndAbortRecordingUserRetry(
                        activeSession,
                        fallback: processingAggregate,
                        reason: .retryInfrastructureFailed,
                        diagnosticReason: .retrySleepFailed,
                        classification: .retryInfrastructureFailure,
                        prepared: prepared,
                        startedAt: attemptStartedAt
                    )
                }
                let transitionTask = Task {
                    await self.installNextAttempt(
                        after: activeSession,
                        kind: .standard,
                        prepared: prepared,
                        fallback: processingAggregate,
                        startedAt: attemptStartedAt,
                        runID: runID,
                        authority: stopAuthority
                    )
                }
                updateActiveInvocationWork(
                    .transition(transitionTask),
                    runID: runID,
                    authority: stopAuthority
                )
                switch await transitionTask.value {
                case let .installed(next):
                    guard claimCompletion(runID: runID, authority: stopAuthority) else {
                        return stoppedInvocationOutcome(fallback: processingAggregate)
                    }
                    activeSession = next
                case let .terminal(outcome):
                    return outcome
                case .revoked:
                    return stoppedInvocationOutcome(fallback: processingAggregate)
                }
            case .responseOverflow:
                guard attempt.kind == .standard,
                      attempt.ordinal < CoachProviderAttempt.maximumOrdinal
                else {
                    guard claimCompletion(runID: runID, authority: stopAuthority) else {
                        return stoppedInvocationOutcome(fallback: processingAggregate)
                    }
                    return await interruptAndAbortRecordingUserRetry(
                        activeSession,
                        fallback: processingAggregate,
                        reason: .invalidProviderResponse,
                        diagnosticReason: attempt.kind == .shorterRepair
                            ? .responseOverflowRepeated
                            : .responseOverflowAttemptLimitReached,
                        classification: .invalidProviderResponse,
                        prepared: prepared,
                        startedAt: attemptStartedAt
                    )
                }
                await recordRetryDiagnostic(
                    reason: .responseOverflowRepair,
                    classification: .invalidProviderResponse,
                    disposition: .automaticRetry,
                    invocation: invocation,
                    prepared: prepared,
                    startedAt: attemptStartedAt
                )
                let transitionTask = Task {
                    await self.installNextAttempt(
                        after: activeSession,
                        kind: .shorterRepair,
                        prepared: prepared,
                        fallback: processingAggregate,
                        startedAt: attemptStartedAt,
                        runID: runID,
                        authority: stopAuthority
                    )
                }
                updateActiveInvocationWork(
                    .transition(transitionTask),
                    runID: runID,
                    authority: stopAuthority
                )
                switch await transitionTask.value {
                case let .installed(next):
                    guard claimCompletion(runID: runID, authority: stopAuthority) else {
                        return stoppedInvocationOutcome(fallback: processingAggregate)
                    }
                    activeSession = next
                case let .terminal(outcome):
                    return outcome
                case .revoked:
                    return stoppedInvocationOutcome(fallback: processingAggregate)
                }
            }
        }

        let completedAt = await clock.now()
        let invocation = activeSession.invocation
        let publication: PublishCoachInvocationMutation
        do {
            try invocation.validate(against: processingAggregate)
            let validationContext = try CoachResponseValidationContext(
                prepared: prepared,
                base: processingAggregate
            )
            let validatedResponse = try CoachResponseValidator().validate(
                completedProviderResponse.response,
                in: validationContext
            )
            let replacementMemory = try await replacementMemory(
                from: validatedResponse,
                base: processingAggregate,
                at: completedAt
            )
            publication = try PublishCoachInvocationMutation(
                base: processingAggregate,
                invocation: invocation,
                validatedResponse: validatedResponse,
                replacementMemory: replacementMemory,
                completedAt: completedAt
            )
        } catch {
            let diagnosticReason = Self.completeResponseDiagnosticReason(error)
            guard claimCompletion(
                runID: runID,
                authority: completedProviderResponse.stopAuthority
            ) else {
                return stoppedInvocationOutcome(fallback: processingAggregate)
            }
            return await interruptAndAbortRecordingUserRetry(
                activeSession,
                fallback: processingAggregate,
                reason: .invalidProviderResponse,
                diagnosticReason: diagnosticReason,
                classification: .invalidProviderResponse,
                prepared: prepared,
                startedAt: completedProviderResponse.startedAtMilliseconds
            )
        }

        guard claimCompletion(
            runID: runID,
            authority: completedProviderResponse.stopAuthority
        ) else {
            return stoppedInvocationOutcome(fallback: processingAggregate)
        }
        switch await activeSession.publish(publication) {
        case let .committed(aggregate):
            return .published(aggregate, prepared.quote)
        case let .stale(current):
            return await interruptPublicationAndAbort(
                activeSession,
                fallback: current ?? processingAggregate,
                reason: .publicationConflict,
                publication: PublicationRecoveryIntent(
                    mutation: publication,
                    quote: prepared.quote
                ),
                diagnosticReason: .publicationConflict,
                classification: .publicationConflict,
                prepared: prepared,
                startedAt: completedProviderResponse.startedAtMilliseconds
            )
        case .failed:
            return await interruptPublicationAndAbort(
                activeSession,
                fallback: processingAggregate,
                reason: .persistenceUnavailable,
                publication: PublicationRecoveryIntent(
                    mutation: publication,
                    quote: prepared.quote
                ),
                diagnosticReason: .publicationPersistenceUnavailable,
                classification: .persistenceUnavailable,
                prepared: prepared,
                startedAt: completedProviderResponse.startedAtMilliseconds
            )
        }
    }

    private func replacementMemory(
        from response: ValidatedCoachResponse,
        base: ChatAggregate,
        at instant: UTCInstant
    ) async throws -> CoachMemory? {
        guard let value = response.newMemory,
              !value.hasSameCanonicalContent(as: base.memory)
        else { return nil }

        for _ in 0 ..< Self.maximumLaunchIdentityCandidates {
            let memoryID = await memoryIDGenerator.generateCoachMemoryID(at: instant)
            guard memoryID != base.memory.memoryID else { continue }
            return try value.materialize(memoryID: memoryID, for: base)
        }
        throw InvocationPublicationError.replacementMemoryIdentityReused
    }

    private static func completeResponseDiagnosticReason(
        _ error: any Error
    ) -> InvocationRetryDiagnosticReason {
        if let validation = error as? CoachResponseValidationError {
            return switch validation {
            case .missingValidationAuthority, .invalidPreparedContext:
                .responseValidationUnavailable
            case .responseByteLimitExceeded:
                .responseCollectorLimitExceeded
            case .responseTokenLimitExceeded:
                .responseTokenLimitExceeded
            case .invalidUTF8:
                .responseEncodingInvalid
            case .invalidJSON, .duplicateJSONKey, .schemaMismatch,
                 .messageBlocksRequired:
                .responseSchemaInvalid
            case .unsafeMarkdown:
                .responseMarkdownUnsafe
            case .invalidMemory:
                .responseMemoryInvalid
            case .memoryTokenLimitExceeded:
                .responseMemoryLimitExceeded
            case .invalidEvidencePointer:
                .responseEvidenceInvalid
            case .danglingProfileTarget:
                .responseProfileTargetInvalid
            case .conflictingProfileEffects:
                .responseProfileEffectsConflict
            }
        }
        if let publication = error as? PublishCoachInvocationMutationError,
           publication == .unsupportedResponseComponent
        {
            return .responsePublicationUnsupported
        }
        return .invalidCompleteResponse
    }

    private func installNextAttempt(
        after session: any InvocationActivePersistenceSession,
        kind: CoachProviderAttemptKind,
        prepared: PreparedCoachLaunchContext,
        fallback: ChatAggregate,
        startedAt: UInt64,
        runID: UUID,
        authority: InvocationStopAuthority
    ) async -> NextAttemptResolution {
        let ordinal = session.invocation.attempt.ordinal + 1
        var lastCollision: InvocationLaunchIdentityCollision?
        for _ in 0 ..< Self.maximumLaunchIdentityCandidates {
            guard isCompletionAuthorized(runID: runID, authority: authority) else {
                return .revoked(session)
            }
            let identity = await identities.generateAttemptIdentity(
                at: await clock.now(),
                ordinal: ordinal,
                kind: kind,
                transcriptHandleCount: prepared.exchange.preparedTranscriptHandles.count
            )
            let mutation: InstallNextCoachProviderAttemptMutation
            do {
                mutation = try InstallNextCoachProviderAttemptMutation(
                    base: session.invocation,
                    identity: identity,
                    kind: kind
                )
            } catch let error as InstallNextCoachProviderAttemptMutationError {
                switch error {
                case let .identityCollision(collision):
                    lastCollision = collision
                    continue
                }
            } catch {
                return await finishFailedAttemptTransition(
                    session,
                    fallback: fallback,
                    diagnosticReason: .nextAttemptConstructionFailed,
                    prepared: prepared,
                    startedAt: startedAt,
                    runID: runID,
                    authority: authority
                )
            }
            do {
                try AttemptTranscriptAccessGrantIssuer().preflight(
                    exchange: prepared.exchange,
                    freshHandles: identity.transcriptHandles,
                    pinnedInstruction: Self.pinnedInstruction(
                        base: prepared.exchange.pinnedInstruction,
                        attemptKind: kind
                    )
                )
            } catch AttemptTranscriptAccessGrantIssueError.contextCannotFit {
                guard claimCompletion(runID: runID, authority: authority) else {
                    return .revoked(session)
                }
                return .terminal(
                    await abortTranscriptContextCannotFit(
                        session,
                        fallback: fallback,
                        prepared: prepared,
                        startedAt: startedAt
                    )
                )
            } catch {
                return await finishFailedAttemptTransition(
                    session,
                    fallback: fallback,
                    diagnosticReason: .attemptTranscriptAccessLaunchFailed,
                    prepared: prepared,
                    startedAt: startedAt,
                    runID: runID,
                    authority: authority
                )
            }
            guard isCompletionAuthorized(runID: runID, authority: authority) else {
                return .revoked(session)
            }
            switch await session.installNextAttempt(mutation) {
            case let .installed(next):
                guard isCompletionAuthorized(runID: runID, authority: authority) else {
                    return .revoked(next)
                }
                return .installed(next)
            case let .collision(collision):
                lastCollision = collision
                continue
            case let .stale(current):
                return await finishFailedAttemptTransition(
                    session,
                    fallback: current ?? fallback,
                    diagnosticReason: .nextAttemptBecameStale,
                    prepared: prepared,
                    startedAt: startedAt,
                    runID: runID,
                    authority: authority
                )
            case .failed:
                return await finishFailedAttemptTransition(
                    session,
                    fallback: fallback,
                    diagnosticReason: .nextAttemptInstallationFailed,
                    prepared: prepared,
                    startedAt: startedAt,
                    runID: runID,
                    authority: authority
                )
            }
        }
        _ = lastCollision
        return await finishFailedAttemptTransition(
            session,
            fallback: fallback,
            diagnosticReason: .nextAttemptIdentityCollisionExhausted,
            prepared: prepared,
            startedAt: startedAt,
            runID: runID,
            authority: authority
        )
    }

    private func finishFailedAttemptTransition(
        _ session: any InvocationActivePersistenceSession,
        fallback: ChatAggregate,
        diagnosticReason: InvocationRetryDiagnosticReason,
        prepared: PreparedCoachLaunchContext,
        startedAt: UInt64,
        runID: UUID,
        authority: InvocationStopAuthority
    ) async -> NextAttemptResolution {
        guard claimCompletion(runID: runID, authority: authority) else {
            return .revoked(session)
        }
        return .terminal(
            await interruptAndAbortRecordingUserRetry(
                session,
                fallback: fallback,
                reason: .persistenceUnavailable,
                diagnosticReason: diagnosticReason,
                classification: .retryInfrastructureFailure,
                prepared: prepared,
                startedAt: startedAt
            )
        )
    }

    private func transcriptReadFailure(
        sessions: [AttemptTranscriptFailureSession]
    ) -> PendingUserTurnFailure? {
        guard !sessions.isEmpty,
              sessions.count <= ChatAttachments.maximumCount,
              let additionalCount = UInt8(
                  exactly: max(
                      0,
                      sessions.count -
                          CoachTranscriptReadFailureSummary.maximumLinkedSessionCount
                  )
              )
        else { return nil }
        do {
            let linked = try sessions
                .prefix(CoachTranscriptReadFailureSummary.maximumLinkedSessionCount)
                .map {
                    try CoachTranscriptReadFailureSession(
                        sessionAttachmentID: $0.sessionAttachmentID,
                        displayLabel: $0.displayLabel
                    )
                }
            return .coachTranscriptReadFailed(
                try CoachTranscriptReadFailureSummary(
                    sessions: linked,
                    additionalSessionCount: additionalCount
                )
            )
        } catch {
            return nil
        }
    }

    private func abortTranscriptContextCannotFit(
        _ session: any InvocationActivePersistenceSession,
        fallback: ChatAggregate,
        prepared: PreparedCoachLaunchContext,
        startedAt: UInt64
    ) async -> InvocationTryOutcome {
        let outcome = await interruptAndAbortRecordingUserRetry(
            session,
            fallback: fallback,
            reason: .retryInfrastructureFailed,
            diagnosticReason: .transcriptContextCannotFit,
            classification: .contextCapacity,
            prepared: prepared,
            startedAt: startedAt,
            terminalFailure: .coachContextCannotFit
        )
        if case let .interrupted(current?, _) = outcome,
           current.pendingUserTurn?.failure == .coachContextCannotFit
        {
            return .contextCapacityFailure(current, prepared.quote)
        }
        return outcome
    }

    private func recordRetryDiagnostic(
        reason: InvocationRetryDiagnosticReason,
        classification: InvocationRetryDiagnosticClassification,
        disposition: InvocationRetryDiagnosticDisposition,
        invocation: CoachInvocation,
        prepared: PreparedCoachLaunchContext,
        startedAt: UInt64
    ) async {
        await recordRetryDiagnostic(
            reason: reason,
            classification: classification,
            disposition: disposition,
            invocation: invocation,
            context: diagnosticContext(for: prepared),
            durationMilliseconds: elapsedMilliseconds(since: startedAt)
        )
    }

    private func recordRetryDiagnostic(
        reason: InvocationRetryDiagnosticReason,
        classification: InvocationRetryDiagnosticClassification,
        disposition: InvocationRetryDiagnosticDisposition,
        invocation: CoachInvocation?,
        context: InvocationRetryDiagnosticContext,
        durationMilliseconds: UInt64
    ) async {
        let occurredAt = await clock.now()
        retryDiagnostics.enqueue(
            InvocationRetryDiagnosticEvent(
                reason: reason,
                classification: classification,
                disposition: disposition,
                invocationID: invocation?.id,
                attemptID: invocation?.attempt.id,
                attemptOrdinal: invocation?.attempt.ordinal,
                retryNumber: invocation?.attempt.ordinal,
                occurredAt: occurredAt,
                durationMilliseconds: durationMilliseconds,
                context: context
            )
        )
    }

    private func diagnosticContext(
        for quote: CoachContextQuote
    ) -> InvocationRetryDiagnosticContext {
        InvocationRetryDiagnosticContext(
            requestUTF8Bytes: 0,
            completeModelInputUTF8Bytes: 0,
            transcriptReadRequestUTF8Bytes: 0,
            transcriptReadResponseUTF8Bytes: 0,
            completeInputTokens: quote.completeInputTokens,
            inputCeilingTokens: quote.inputCeilingTokens,
            memoryUTF8Bytes: quote.categoryCosts[.memory]?.utf8ByteCount ?? 0
        )
    }

    private func diagnosticContext(
        for prepared: PreparedCoachLaunchContext
    ) -> InvocationRetryDiagnosticContext {
        let exchange = prepared.exchange
        let quote = prepared.quote
        return InvocationRetryDiagnosticContext(
            requestUTF8Bytes: exchange.request.count,
            completeModelInputUTF8Bytes: exchange.completeModelInput.count,
            transcriptReadRequestUTF8Bytes: exchange.transcriptReadRequest?.count ?? 0,
            transcriptReadResponseUTF8Bytes: exchange.transcriptReadResponse?.count ?? 0,
            completeInputTokens: quote.completeInputTokens,
            inputCeilingTokens: quote.inputCeilingTokens,
            memoryUTF8Bytes: quote.categoryCosts[.memory]?.utf8ByteCount ?? 0
        )
    }

    private func rejectAdmission(
        _ session: any InvocationPendingPersistenceSession,
        fallback: InvocationPendingAuthority,
        request: PendingCoachInvocationRequest,
        prepared: PreparedCoachLaunchContext,
        reason: InvocationRejectionReason,
        diagnosticReason: InvocationRetryDiagnosticReason
    ) async -> InvocationTryOutcome {
        let outcome = await reject(session, fallback: fallback, reason: reason)
        guard presentsUserRetry(outcome, request: request) else { return outcome }
        await recordRetryDiagnostic(
            reason: diagnosticReason,
            classification: .admissionRejected,
            disposition: .userRetryableFailure,
            invocation: nil,
            context: diagnosticContext(for: prepared),
            durationMilliseconds: 0
        )
        return outcome
    }

    private func presentsUserRetry(
        _ outcome: InvocationTryOutcome,
        request: PendingCoachInvocationRequest
    ) -> Bool {
        switch outcome {
        case let .contextCapacityFailure(current, _):
            return current.chat.id == request.chatID &&
                current.pendingUserTurn?.id == request.pendingUserTurnID &&
                current.pendingUserTurn?.failure != nil
        case let .rejected(current, _), let .interrupted(current, _):
            return current?.chat.id == request.chatID &&
                current?.pendingUserTurn?.id == request.pendingUserTurnID &&
                current?.pendingUserTurn?.failure != nil
        case let .operationallyInterrupted(_, retryRequest, _):
            return retryRequest == request
        case .published, .stopped, .providerReapPending:
            return false
        }
    }

    private func elapsedMilliseconds(since startedAt: UInt64) -> UInt64 {
        let current = retryTiming.nowMilliseconds()
        guard current >= startedAt else { return 0 }
        return current - startedAt
    }

    public func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        let instant = await clock.now()
        return await admission.availability(library: library, at: instant)
    }

    public func stopProfileReconsideration(
        _ request: StopProfileReconsiderationInvocationRequest,
        authority: ProfileReconsiderationInvocationStopAuthority
    ) async -> ProfileReconsiderationInvocationStopOutcome {
        guard var control = activeProfileReconsiderationControls[
            authority.capabilityID
        ] else {
            return activeProfileReconsiderationControls.values.contains {
                $0.authority.matches(request)
            } ? .staleAuthority : .noActiveInvocation
        }
        let retriesUnreapedProvider: Bool = if control.isRevoked {
            switch control.work {
            case .provider, .reapPending: true
            case .backoff, .transition, .stopping: false
            }
        } else {
            false
        }
        guard (!control.isRevoked || retriesUnreapedProvider),
              control.authority == authority,
              authority.matches(request)
        else { return .staleAuthority }

        control.isRevoked = true
        let work = control.work
        control.work = .stopping
        activeProfileReconsiderationControls[authority.capabilityID] = control
        control.transcriptAccess?.closeReads()
        if let transcriptAccess = control.transcriptAccess,
           case let .terminal(status) = await transcriptAccess.finalize(
               reason: .cancelled
           ),
           control.retainedTranscriptTerminalStatus == nil
        {
            switch status {
            case .sessionUnavailable, .contextCannotFit, .rejected:
                control.retainedTranscriptTerminalStatus = status
                activeProfileReconsiderationControls[
                    authority.capabilityID
                ] = control
            case .completed, .revoked:
                break
            }
        }
        switch work {
        case let .provider(_, completion):
            await completion.complete(.stopped)
        case let .backoff(_, completion):
            await completion.complete(.stopped)
        case .transition, .reapPending, .stopping:
            break
        }
        work.cancel()

        let cancellation = await provider.cancelAndReap(
            attemptID: authority.attemptID,
            graceMilliseconds: Self.providerCancellationGraceMilliseconds
        )
        var sessionToAbort = control.session
        if case let .transition(task) = work {
            switch await task.value {
            case let .installed(next), let .revoked(next):
                sessionToAbort = next
            case let .terminal(outcome):
                guard cancellation == .reaped ||
                    cancellation == .alreadyAbsent
                else {
                    control.work = .reapPending(outcome)
                    activeProfileReconsiderationControls[
                        authority.capabilityID
                    ] = control
                    return .unableToReap
                }
                activeProfileReconsiderationControls.removeValue(
                    forKey: authority.capabilityID
                )
                return profileReconsiderationStopOutcome(
                    from: outcome,
                    request: request,
                    fallback: control.fallback
                )
            }
        }
        guard cancellation == .reaped || cancellation == .alreadyAbsent else {
            control.session = sessionToAbort
            control.work = .reapPending(nil)
            activeProfileReconsiderationControls[authority.capabilityID] = control
            return .unableToReap
        }
        if case let .reapPending(outcome?) = work {
            activeProfileReconsiderationControls.removeValue(
                forKey: authority.capabilityID
            )
            return profileReconsiderationStopOutcome(
                from: outcome,
                request: request,
                fallback: control.fallback
            )
        }

        let terminal = await sessionToAbort.abort(
            failure: retainedTerminalFailure(
                for: control.retainedTranscriptTerminalStatus
            )
        )
        let outcome: ProfileReconsiderationInvocationStopOutcome =
            switch terminal {
            case let .committed(current):
                .interrupted(current)
            case let .stale(current):
                profileReconsiderationStopPersistenceUnavailable(
                    current: current,
                    request: request,
                    fallback: control.fallback
                )
            case let .recovered(.eligible(current)):
                if current.reconsideration.failure != nil {
                    .interrupted(current.aggregate)
                } else {
                    profileReconsiderationStopPersistenceUnavailable(
                        current: current.aggregate,
                        request: request,
                        fallback: control.fallback
                    )
                }
            case let .recovered(.ineligible(current)):
                profileReconsiderationStopPersistenceUnavailable(
                    current: current,
                    request: request,
                    fallback: control.fallback
                )
            case .recovered(.unavailable):
                profileReconsiderationStopPersistenceUnavailable(
                    current: nil,
                    request: request,
                    fallback: control.fallback
                )
            }
        activeProfileReconsiderationControls.removeValue(
            forKey: authority.capabilityID
        )
        return outcome
    }

    private func profileReconsiderationStopOutcome(
        from outcome: ProfileReconsiderationInvocationTryOutcome,
        request: StopProfileReconsiderationInvocationRequest,
        fallback: ChatAggregate
    ) -> ProfileReconsiderationInvocationStopOutcome {
        switch outcome {
        case let .interrupted(current, _):
            guard let current,
                  current.chat.id == request.chatID,
                  current.profileReconsideration?.sourceEffectIdentity ==
                    request.sourceEffectIdentity,
                  current.profileReconsideration?.resultResponsePositionID ==
                    request.resultResponsePositionID
            else {
                return profileReconsiderationStopPersistenceUnavailable(
                    current: current,
                    request: request,
                    fallback: fallback
                )
            }
            return .interrupted(current)
        case let .operationallyInterrupted(current, retry, _)
            where retry.library == request.library &&
            retry.chatID == request.chatID &&
            retry.sourceEffectIdentity == request.sourceEffectIdentity &&
            retry.resultResponsePositionID == request.resultResponsePositionID:
            return .persistenceUnavailable(current ?? fallback)
        case let .rejected(current, _):
            return profileReconsiderationStopPersistenceUnavailable(
                current: current,
                request: request,
                fallback: fallback
            )
        case let .contextCapacityFailure(current, _),
             let .published(current, _),
             let .withdrawn(current, _):
            return .persistenceUnavailable(current)
        case .providerReapPending:
            return .unableToReap
        case .operationallyInterrupted, .stopped:
            return profileReconsiderationStopPersistenceUnavailable(
                current: nil,
                request: request,
                fallback: fallback
            )
        }
    }

    private func profileReconsiderationStopPersistenceUnavailable(
        current: ChatAggregate?,
        request: StopProfileReconsiderationInvocationRequest,
        fallback: ChatAggregate
    ) -> ProfileReconsiderationInvocationStopOutcome {
        let observed = current ?? fallback
        let retry = ProfileReconsiderationInvocationRequest(
            library: request.library,
            chatID: request.chatID,
            sourceEffectIdentity: request.sourceEffectIdentity,
            resultResponsePositionID: request.resultResponsePositionID
        )
        if observed.chat.id == retry.chatID,
           observed.profileEffect?.identity == retry.sourceEffectIdentity,
           let reconsideration = observed.profileReconsideration,
           reconsideration.sourceEffectIdentity == retry.sourceEffectIdentity,
           reconsideration.resultResponsePositionID ==
            retry.resultResponsePositionID,
           reconsideration.failure == nil
        {
            rememberOperationalProfileReconsiderationRetry(
                request: retry,
                fallback: observed
            )
        }
        return .persistenceUnavailable(observed)
    }

    private func isProfileReconsiderationCompletionAuthorized(
        runID: UUID,
        authority: ProfileReconsiderationInvocationStopAuthority
    ) -> Bool {
        guard let control = activeProfileReconsiderationControls[
            authority.capabilityID
        ] else { return false }
        return control.runID == runID &&
            control.authority == authority &&
            !control.isRevoked
    }

    private func updateActiveProfileReconsiderationWork(
        _ work: ActiveProfileReconsiderationWork,
        runID: UUID,
        authority: ProfileReconsiderationInvocationStopAuthority
    ) {
        guard var control = activeProfileReconsiderationControls[
            authority.capabilityID
        ],
            control.runID == runID,
            control.authority == authority,
            !control.isRevoked
        else { return }
        control.work = work
        activeProfileReconsiderationControls[authority.capabilityID] = control
    }

    private func claimProfileReconsiderationCompletion(
        runID: UUID,
        authority: ProfileReconsiderationInvocationStopAuthority
    ) -> Bool {
        guard isProfileReconsiderationCompletionAuthorized(
            runID: runID,
            authority: authority
        ) else { return false }
        activeProfileReconsiderationControls.removeValue(
            forKey: authority.capabilityID
        )
        return true
    }

    private func clearActiveProfileReconsiderationControl(runID: UUID) {
        guard let control = activeProfileReconsiderationControls.values
            .first(where: { $0.runID == runID }),
            !control.isRevoked
        else { return }
        activeProfileReconsiderationControls.removeValue(
            forKey: control.authority.capabilityID
        )
    }

    private func recordProfileReconsiderationTranscriptTerminalStatus(
        _ status: AttemptTranscriptAccessTerminalStatus,
        runID: UUID,
        authority: ProfileReconsiderationInvocationStopAuthority
    ) {
        guard var control = activeProfileReconsiderationControls[
            authority.capabilityID
        ],
            control.runID == runID,
            control.authority == authority,
            !control.isRevoked
        else { return }
        control.retainedTranscriptTerminalStatus = status
        activeProfileReconsiderationControls[authority.capabilityID] = control
    }

    private func retainUnreapedProfileReconsiderationControl(
        runID: UUID,
        authority: ProfileReconsiderationInvocationStopAuthority,
        transcriptStatus: AttemptTranscriptAccessTerminalStatus
    ) {
        guard var control = activeProfileReconsiderationControls[
            authority.capabilityID
        ],
            control.runID == runID,
            control.authority == authority,
            !control.isRevoked
        else { return }
        control.isRevoked = true
        control.retainedTranscriptTerminalStatus = transcriptStatus
        control.work = .reapPending(nil)
        activeProfileReconsiderationControls[authority.capabilityID] = control
    }

    public func stop(
        _ request: StopCoachInvocationRequest,
        authority: InvocationStopAuthority
    ) async -> InvocationStopOutcome {
        guard var control = activeInvocationControls[authority.capabilityID] else {
            return activeInvocationControls.values.contains { candidate in
                candidate.authority.matches(request)
            } ? .staleAuthority : .noActiveInvocation
        }
        let retriesUnreapedProvider: Bool = if control.isRevoked {
            switch control.work {
            case .provider, .reapPending: true
            case .backoff, .transition, .stopping: false
            }
        } else {
            false
        }
        guard (!control.isRevoked || retriesUnreapedProvider),
              control.authority == authority,
              authority.matches(request)
        else { return .staleAuthority }

        // Stop wins at this actor-isolated assignment. Every provider/backoff
        // continuation checks this fence before it can advance or publish.
        control.isRevoked = true
        let work = control.work
        control.work = .stopping
        activeInvocationControls[authority.capabilityID] = control
        // Revoke transcript disclosure immediately after the Stop fence wins,
        // before provider cancellation or process reap can suspend.
        control.transcriptAccess?.closeReads()
        if let transcriptAccess = control.transcriptAccess,
           case let .terminal(status) = await transcriptAccess.finalize(
               reason: .cancelled
           ),
           control.retainedTranscriptTerminalStatus == nil
        {
            // Only provider-visible transcript failures may replace an ordinary
            // user interruption. In particular, a repeated Stop observes the
            // broker's own `.revoked(.cancelled)` terminal and must not turn it
            // into an invalid-response failure.
            switch status {
            case .sessionUnavailable, .contextCannotFit, .rejected:
                // A terminal broker result may have won immediately before Stop,
                // while its coordinator signal was still being handed off.
                control.retainedTranscriptTerminalStatus = status
                activeInvocationControls[authority.capabilityID] = control
            case .completed, .revoked:
                break
            }
        }
        switch work {
        case let .provider(_, completion):
            await completion.complete(.stopped)
        case let .backoff(_, completion):
            await completion.complete(.stopped)
        case .transition, .reapPending, .stopping:
            break
        }
        work.cancel()

        let cancellation = await provider.cancelAndReap(
            attemptID: authority.attemptID,
            graceMilliseconds: Self.providerCancellationGraceMilliseconds
        )

        var sessionToAbort: any InvocationActivePersistenceSession = control.session
        if case let .transition(transitionTask) = work {
            switch await transitionTask.value {
            case let .installed(next):
                sessionToAbort = next
                retainRevokedInvocationSession(
                    next,
                    runID: control.runID,
                    authority: authority
                )
            case let .terminal(outcome):
                guard cancellation == .reaped || cancellation == .alreadyAbsent else {
                    control.work = .reapPending(outcome)
                    activeInvocationControls[authority.capabilityID] = control
                    return .unableToReap
                }
                return await completeStoppedInvocation(
                    stopOutcome(
                        from: outcome,
                        request: request,
                        fallback: control.fallback
                    ),
                    control: control,
                    authority: authority
                )
            case let .revoked(current):
                sessionToAbort = current
                retainRevokedInvocationSession(
                    current,
                    runID: control.runID,
                    authority: authority
                )
            }
        }

        guard cancellation == .reaped || cancellation == .alreadyAbsent else {
            // The process may still exist. Keep the exact current persistence
            // session and Library liveness lease behind a state-independent
            // reap marker. Provider completion, backoff cancellation, or a
            // next-Attempt transition may already have consumed the old work.
            control.session = sessionToAbort
            control.work = .reapPending(nil)
            activeInvocationControls[authority.capabilityID] = control
            return .unableToReap
        }

        if case let .reapPending(terminalOutcome?) = work {
            return await completeStoppedInvocation(
                stopOutcome(
                    from: terminalOutcome,
                    request: request,
                    fallback: control.fallback
                ),
                control: control,
                authority: authority
            )
        }

        let terminalFailure = retainedTerminalFailure(
            for: control.retainedTranscriptTerminalStatus
        )
        let terminal = await sessionToAbort.abort(failure: terminalFailure)
        let outcome: InvocationStopOutcome = switch terminal {
        case let .committed(aggregate):
            .interrupted(aggregate)
        case let .stale(current):
            if let current,
               current.chat.id == request.chatID,
               current.pendingUserTurn?.id == request.pendingUserTurnID,
               current.pendingUserTurn?.failure == terminalFailure
            {
                .interrupted(current)
            } else {
                .persistenceUnavailable(current ?? control.fallback)
            }
        case let .recovered(.eligible(pendingAuthority)):
            pendingAuthority.pendingUserTurn.failure == terminalFailure
                ? .interrupted(pendingAuthority.aggregate)
                : .persistenceUnavailable(pendingAuthority.aggregate)
        case let .recovered(.ineligible(current)):
            .persistenceUnavailable(current)
        case .recovered(.unavailable):
            .persistenceUnavailable(control.fallback)
        }
        return await completeStoppedInvocation(
            outcome,
            control: control,
            authority: authority
        )
    }

    private func completeStoppedInvocation(
        _ outcome: InvocationStopOutcome,
        control: ActiveInvocationControl,
        authority: InvocationStopAuthority
    ) async -> InvocationStopOutcome {
        finishStoppedInvocation(authority: authority)
        let presentsExactRetry: Bool = switch outcome {
        case .interrupted:
            true
        case let .persistenceUnavailable(current):
            current?.chat.id == authority.chatID &&
                current?.pendingUserTurn?.id == authority.pendingUserTurnID &&
                current?.pendingUserTurn?.failure == nil
        case .staleAuthority, .noActiveInvocation, .unableToReap:
            false
        }
        if presentsExactRetry {
            let diagnostic = retainedTerminalDiagnostic(
                for: control.retainedTranscriptTerminalStatus
            )
            await recordRetryDiagnostic(
                reason: diagnostic.reason,
                classification: diagnostic.classification,
                disposition: .userRetryableFailure,
                invocation: control.session.invocation,
                context: control.diagnosticContext,
                durationMilliseconds: elapsedMilliseconds(
                    since: control.startedAtMilliseconds
                )
            )
        }
        return outcome
    }

    private func stopOutcome(
        from outcome: InvocationTryOutcome,
        request: StopCoachInvocationRequest,
        fallback: ChatAggregate
    ) -> InvocationStopOutcome {
        switch outcome {
        case let .interrupted(current, _):
            guard let current,
                  current.chat.id == request.chatID,
                  current.pendingUserTurn?.id == request.pendingUserTurnID,
                  current.pendingUserTurn?.failure == .coachResponseInterrupted
            else { return .persistenceUnavailable(current ?? fallback) }
            return .interrupted(current)
        case let .operationallyInterrupted(current, retryRequest, _)
            where retryRequest.library == request.library &&
            retryRequest.chatID == request.chatID &&
            retryRequest.pendingUserTurnID == request.pendingUserTurnID:
            return .persistenceUnavailable(current ?? fallback)
        case let .rejected(current, _):
            return .persistenceUnavailable(current ?? fallback)
        case let .contextCapacityFailure(current, _):
            return .persistenceUnavailable(current)
        case let .published(current, _):
            return .persistenceUnavailable(current)
        case .providerReapPending:
            return .unableToReap
        case .operationallyInterrupted, .stopped:
            return .persistenceUnavailable(fallback)
        }
    }

    private func stopRequest(
        for invocation: CoachInvocation
    ) -> StopCoachInvocationRequest {
        StopCoachInvocationRequest(
            library: LibraryScope(libraryID: invocation.libraryID),
            chatID: invocation.chatID,
            pendingUserTurnID: invocation.pendingUserTurnID
        )
    }

    private func isCompletionAuthorized(
        runID: UUID,
        authority: InvocationStopAuthority
    ) -> Bool {
        guard let control = activeInvocationControls[authority.capabilityID] else {
            return false
        }
        return control.runID == runID &&
            control.authority == authority &&
            !control.isRevoked
    }

    private func updateActiveInvocationWork(
        _ work: ActiveInvocationWork,
        runID: UUID,
        authority: InvocationStopAuthority
    ) {
        guard var control = activeInvocationControls[authority.capabilityID],
              control.runID == runID,
              control.authority == authority,
              !control.isRevoked
        else { return }
        control.work = work
        activeInvocationControls[authority.capabilityID] = control
    }

    private func retainRevokedInvocationSession(
        _ session: any InvocationActivePersistenceSession,
        runID: UUID,
        authority: InvocationStopAuthority
    ) {
        guard var control = activeInvocationControls[authority.capabilityID],
              control.runID == runID,
              control.authority == authority,
              control.isRevoked
        else { return }
        control.session = session
        activeInvocationControls[authority.capabilityID] = control
    }

    private func retainUnreapedProviderControl(
        runID: UUID,
        authority: InvocationStopAuthority,
        transcriptStatus: AttemptTranscriptAccessTerminalStatus
    ) {
        guard var control = activeInvocationControls[authority.capabilityID],
              control.runID == runID,
              control.authority == authority,
              !control.isRevoked,
              case .provider = control.work
        else { return }
        // No terminal persistence is allowed while process absence is
        // uncertain. Keep the exact session and Library lease, but fence every
        // stale continuation. The same Stop authority may retry exact reaping.
        control.isRevoked = true
        control.retainedTranscriptTerminalStatus = transcriptStatus
        control.work = .reapPending(nil)
        activeInvocationControls[authority.capabilityID] = control
    }

    private func recordTranscriptTerminalStatus(
        _ status: AttemptTranscriptAccessTerminalStatus,
        runID: UUID,
        authority: InvocationStopAuthority
    ) {
        guard var control = activeInvocationControls[authority.capabilityID],
              control.runID == runID,
              control.authority == authority,
              !control.isRevoked
        else { return }
        control.retainedTranscriptTerminalStatus = status
        activeInvocationControls[authority.capabilityID] = control
    }

    private func retainedTerminalFailure(
        for status: AttemptTranscriptAccessTerminalStatus?
    ) -> PendingUserTurnFailure {
        switch status {
        case let .sessionUnavailable(sessions):
            transcriptReadFailure(sessions: sessions) ?? .coachResponseInvalid
        case .contextCannotFit:
            .coachContextCannotFit
        case .rejected:
            .coachResponseInvalid
        case .completed, .revoked, nil:
            .coachResponseInterrupted
        }
    }

    private func retainedTerminalDiagnostic(
        for status: AttemptTranscriptAccessTerminalStatus?
    ) -> (
        reason: InvocationRetryDiagnosticReason,
        classification: InvocationRetryDiagnosticClassification
    ) {
        switch status {
        case .sessionUnavailable:
            (.transcriptSessionUnavailable, .transcriptReadFailure)
        case .contextCannotFit:
            (.transcriptContextCannotFit, .contextCapacity)
        case .rejected:
            (.transcriptAccessProtocolFailure, .invalidProviderResponse)
        case .completed, .revoked, nil:
            (.coachResponseStopped, .interruption)
        }
    }

    private func claimCompletion(
        runID: UUID,
        authority: InvocationStopAuthority
    ) -> Bool {
        guard isCompletionAuthorized(runID: runID, authority: authority) else {
            return false
        }
        activeInvocationControls.removeValue(forKey: authority.capabilityID)
        return true
    }

    private func clearActiveInvocationControl(runID: UUID) {
        guard let control = activeInvocationControls.values.first(where: {
            $0.runID == runID
        }),
              control.runID == runID,
              !control.isRevoked
        else { return }
        activeInvocationControls.removeValue(forKey: control.authority.capabilityID)
    }

    private func finishStoppedInvocation(authority: InvocationStopAuthority) {
        guard let control = activeInvocationControls[authority.capabilityID],
              control.authority == authority,
              control.isRevoked
        else { return }
        activeInvocationControls.removeValue(forKey: authority.capabilityID)
    }

    private func stoppedInvocationOutcome(
        fallback _: ChatAggregate
    ) -> InvocationTryOutcome {
        // The Stop caller alone owns installation of its post-reap terminal
        // aggregate. The original invocation task must not race that durable
        // result with its older processing snapshot.
        .stopped
    }

    private func interruptAndAbort(
        _ session: any InvocationActivePersistenceSession,
        fallback: ChatAggregate,
        reason: InvocationInterruptionReason,
        terminalFailure overrideTerminalFailure: PendingUserTurnFailure? = nil,
        publication: PublicationRecoveryIntent? = nil
    ) async -> InvocationTryOutcome {
        let invocation = session.invocation
        var publicationRecovery: PublicationRecoveryResolution?
        if let publication {
            let resolution = await resolvePublicationRecovery(
                publication,
                using: session
            )
            if case let .published(outcome) = resolution { return outcome }
            publicationRecovery = resolution
        }
        let terminalFailure: PendingUserTurnFailure
        if let overrideTerminalFailure {
            terminalFailure = overrideTerminalFailure
        } else {
            terminalFailure = switch reason {
            case .providerFailed: .coachProviderError
            case .invalidProviderResponse: .coachResponseInvalid
            case .retryInfrastructureFailed, .publicationConflict,
                 .persistenceUnavailable:
                .coachResponseInterrupted
            }
        }
        return switch await session.abort(failure: terminalFailure) {
        case let .committed(aggregate):
            await outcomeAfterAbort(
                current: aggregate,
                fallback: fallback,
                reason: reason,
                invocation: invocation,
                publication: publication,
                priorRecovery: publicationRecovery
            )
        case let .stale(current):
            await outcomeAfterAbort(
                current: current,
                fallback: fallback,
                reason: reason,
                invocation: invocation,
                publication: publication,
                priorRecovery: publicationRecovery
            )
        case let .recovered(resolution):
            await outcomeAfterRecoveredAbort(
                resolution,
                request: pendingRequest(for: invocation),
                fallback: fallback,
                publication: publication,
                priorRecovery: publicationRecovery
            )
        }
    }

    private func interruptAndAbortRecordingUserRetry(
        _ session: any InvocationActivePersistenceSession,
        fallback: ChatAggregate,
        reason: InvocationInterruptionReason,
        diagnosticReason: InvocationRetryDiagnosticReason,
        classification: InvocationRetryDiagnosticClassification,
        prepared: PreparedCoachLaunchContext,
        startedAt: UInt64,
        terminalFailure: PendingUserTurnFailure? = nil
    ) async -> InvocationTryOutcome {
        let invocation = session.invocation
        let context = diagnosticContext(for: prepared)
        let durationMilliseconds = elapsedMilliseconds(since: startedAt)
        let outcome = await interruptAndAbort(
            session,
            fallback: fallback,
            reason: reason,
            terminalFailure: terminalFailure
        )
        guard presentsUserRetry(
            outcome,
            request: pendingRequest(for: invocation)
        ) else { return outcome }
        await recordRetryDiagnostic(
            reason: diagnosticReason,
            classification: classification,
            disposition: .userRetryableFailure,
            invocation: invocation,
            context: context,
            durationMilliseconds: durationMilliseconds
        )
        return outcome
    }

    private func interruptPublicationAndAbort(
        _ session: any InvocationActivePersistenceSession,
        fallback: ChatAggregate,
        reason: InvocationInterruptionReason,
        publication: PublicationRecoveryIntent,
        diagnosticReason: InvocationRetryDiagnosticReason,
        classification: InvocationRetryDiagnosticClassification,
        prepared: PreparedCoachLaunchContext,
        startedAt: UInt64
    ) async -> InvocationTryOutcome {
        let invocation = session.invocation
        let outcome = await interruptAndAbort(
            session,
            fallback: fallback,
            reason: reason,
            publication: publication
        )
        guard presentsPublicationRetry(
            outcome,
            request: pendingRequest(for: invocation)
        ) else { return outcome }
        await recordRetryDiagnostic(
            reason: diagnosticReason,
            classification: classification,
            disposition: .userRetryableFailure,
            invocation: invocation,
            prepared: prepared,
            startedAt: startedAt
        )
        return outcome
    }

    private func presentsPublicationRetry(
        _ outcome: InvocationTryOutcome,
        request: PendingCoachInvocationRequest
    ) -> Bool {
        switch outcome {
        case let .interrupted(current, _):
            return current?.chat.id == request.chatID &&
                current?.pendingUserTurn?.id == request.pendingUserTurnID &&
                current?.pendingUserTurn?.failure != nil
        case let .operationallyInterrupted(_, retryRequest, _):
            return retryRequest == request
        case .published, .contextCapacityFailure, .rejected, .stopped,
             .providerReapPending:
            return false
        }
    }

    private func outcomeAfterRecoveredAbort(
        _ pendingResolution: InvocationPendingResolutionOutcome,
        request: PendingCoachInvocationRequest,
        fallback: ChatAggregate,
        publication: PublicationRecoveryIntent?,
        priorRecovery: PublicationRecoveryResolution?
    ) async -> InvocationTryOutcome {
        guard let publication else {
            return interruptionAfterTerminalRecovery(
                pendingResolution,
                request: request,
                fallback: fallback
            )
        }
        if case .notPublished? = priorRecovery {
            return interruptionAfterTerminalRecovery(
                pendingResolution,
                request: request,
                fallback: fallback
            )
        }
        switch await resolvePublicationRecovery(publication) {
        case let .published(outcome):
            return outcome
        case .notPublished:
            return interruptionAfterTerminalRecovery(
                pendingResolution,
                request: request,
                fallback: fallback
            )
        case .unavailable:
            return retainOperationalRetry(
                request: request,
                fallback: fallback,
                publication: publication
            )
        }
    }

    private func outcomeAfterAbort(
        current: ChatAggregate?,
        fallback: ChatAggregate,
        reason: InvocationInterruptionReason,
        invocation: CoachInvocation,
        publication: PublicationRecoveryIntent?,
        priorRecovery: PublicationRecoveryResolution?
    ) async -> InvocationTryOutcome {
        guard let publication else {
            return interruptionAfterUncommittedAbort(
                current: current,
                fallback: fallback,
                reason: reason,
                invocation: invocation
            )
        }
        if case .notPublished? = priorRecovery {
            return interruptionAfterUncommittedAbort(
                current: current,
                fallback: fallback,
                reason: reason,
                invocation: invocation
            )
        }
        switch await resolvePublicationRecovery(publication) {
        case let .published(outcome):
            return outcome
        case .notPublished:
            return interruptionAfterUncommittedAbort(
                current: current,
                fallback: fallback,
                reason: reason,
                invocation: invocation
            )
        case .unavailable:
            return await interruptionAfterTerminalFailure(
                request: pendingRequest(for: invocation),
                fallback: fallback,
                publication: publication
            )
        }
    }

    private func interruptionAfterUncommittedAbort(
        current: ChatAggregate?,
        fallback: ChatAggregate,
        reason: InvocationInterruptionReason,
        invocation: CoachInvocation
    ) -> InvocationTryOutcome {
        let observed = current ?? fallback
        let request = pendingRequest(for: invocation)
        guard observed.chat.id == request.chatID,
              let pending = observed.pendingUserTurn,
              pending.id == request.pendingUserTurnID,
              pending.failure == nil
        else { return .interrupted(observed, reason) }
        return retainOperationalRetry(
            request: request,
            fallback: observed,
            publication: nil
        )
    }

    private func outcomeAfterStaleContextAbort(
        current: ChatAggregate?,
        fallback: ChatAggregate,
        invocation: CoachInvocation
    ) -> InvocationTryOutcome {
        let observed = current ?? fallback
        let request = pendingRequest(for: invocation)
        guard observed.chat.id == request.chatID,
              let pending = observed.pendingUserTurn,
              pending.id == request.pendingUserTurnID,
              pending.failure == nil
        else { return .rejected(current, .contextChanged) }
        return retainOperationalRetry(
            request: request,
            fallback: observed,
            publication: nil
        )
    }

    private func pendingRequest(
        for invocation: CoachInvocation
    ) -> PendingCoachInvocationRequest {
        PendingCoachInvocationRequest(
            library: LibraryScope(libraryID: invocation.libraryID),
            chatID: invocation.chatID,
            pendingUserTurnID: invocation.pendingUserTurnID
        )
    }

    private func resolvePublicationRecovery(
        _ publication: PublicationRecoveryIntent,
        using session: (any InvocationActivePersistenceSession)? = nil
    ) async -> PublicationRecoveryResolution {
        let recovery: InvocationPublicationRecoveryOutcome
        if let session {
            recovery = await session.recoverPublished(publication.mutation)
        } else {
            recovery = await persistence.recoverPublishedInvocation(publication.mutation)
        }
        switch recovery {
        case let .published(aggregate):
            operationalRetrySnapshots.removeValue(
                forKey: pendingRequest(for: publication.mutation.invocation)
            )
            return .published(.published(aggregate, publication.quote))
        case .notPublished:
            return .notPublished
        case .unavailable:
            return .unavailable(publication)
        }
    }

    private func interruptPending(
        _ session: any InvocationPendingPersistenceSession,
        fallback authority: InvocationPendingAuthority,
        reason: InvocationInterruptionReason
    ) async -> InvocationTryOutcome {
        switch await session.terminate(.interrupted) {
        case let .committed(aggregate):
            .interrupted(aggregate, reason)
        case let .stale(current):
            .interrupted(current ?? authority.aggregate, reason)
        case let .recovered(resolution):
            interruptionAfterTerminalRecovery(
                resolution,
                request: authority.request,
                fallback: authority.aggregate
            )
        }
    }

    private func interruptionAfterTerminalRecovery(
        _ resolution: InvocationPendingResolutionOutcome,
        request: PendingCoachInvocationRequest,
        fallback: ChatAggregate
    ) -> InvocationTryOutcome {
        switch resolution {
        case let .eligible(authority):
            return interruptionOutcome(current: authority.aggregate, request: request)
        case let .ineligible(current):
            return interruptionOutcome(current: current, request: request)
        case .unavailable:
            return retainOperationalRetry(
                request: request,
                fallback: fallback,
                publication: nil
            )
        }
    }

    private func interruptionAfterTerminalFailure(
        request: PendingCoachInvocationRequest,
        fallback: ChatAggregate,
        publication: PublicationRecoveryIntent? = nil
    ) async -> InvocationTryOutcome {
        switch await resolveTerminalRecovery(
            request: request,
            publication: publication
        ) {
        case let .published(outcome):
            return outcome
        case let .eligible(authority):
            return interruptionOutcome(
                current: authority.aggregate,
                request: request
            )
        case let .ineligible(current, unresolvedPublication):
            if let unresolvedPublication {
                return retainOperationalRetry(
                    request: request,
                    fallback: fallback,
                    publication: unresolvedPublication
                )
            }
            return interruptionOutcome(current: current, request: request)
        case let .unavailable(unresolvedPublication):
            return retainOperationalRetry(
                request: request,
                fallback: fallback,
                publication: unresolvedPublication
            )
        }
    }

    private func resolveTerminalRecovery(
        request: PendingCoachInvocationRequest,
        publication: PublicationRecoveryIntent?
    ) async -> TerminalRecoveryResolution {
        var unresolvedPublication: PublicationRecoveryIntent?
        if let publication {
            switch await resolvePublicationRecovery(publication) {
            case let .published(outcome):
                return .published(outcome)
            case .notPublished:
                break
            case let .unavailable(unresolved):
                unresolvedPublication = unresolved
            }
        }

        return switch await persistence.recoverPendingAfterTerminalFailure(request) {
        case let .eligible(authority):
            .eligible(authority)
        case let .ineligible(current):
            .ineligible(current, unresolvedPublication: unresolvedPublication)
        case .unavailable:
            .unavailable(unresolvedPublication: unresolvedPublication)
        }
    }

    private func retainOperationalRetry(
        request: PendingCoachInvocationRequest,
        fallback: ChatAggregate,
        publication: PublicationRecoveryIntent?
    ) -> InvocationTryOutcome {
        operationalRetrySnapshots[request] = OperationalRetrySnapshot(
            fallback: fallback,
            publication: publication
        )
        return .operationallyInterrupted(
            fallback,
            request,
            .persistenceUnavailable
        )
    }

    private func interruptionOutcome(
        current: ChatAggregate?,
        request: PendingCoachInvocationRequest
    ) -> InvocationTryOutcome {
        guard let current,
              current.chat.id == request.chatID,
              let pending = current.pendingUserTurn,
              pending.id == request.pendingUserTurnID
        else {
            operationalRetrySnapshots.removeValue(forKey: request)
            return .interrupted(current, .persistenceUnavailable)
        }
        guard pending.failure != nil else {
            operationalRetrySnapshots[request] = OperationalRetrySnapshot(
                fallback: current,
                publication: nil
            )
            return .operationallyInterrupted(
                current,
                request,
                .persistenceUnavailable
            )
        }
        operationalRetrySnapshots.removeValue(forKey: request)
        return .interrupted(current, .persistenceUnavailable)
    }

    private func recoverOperationalRetryIfNeeded(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationTryOutcome? {
        guard let snapshot = operationalRetrySnapshots[request] else { return nil }
        switch await resolveTerminalRecovery(
            request: request,
            publication: snapshot.publication
        ) {
        case let .published(outcome):
            return outcome
        case let .eligible(authority):
            guard authority.pendingUserTurn.failure != nil else {
                return retainOperationalRetry(
                    request: request,
                    fallback: authority.aggregate,
                    publication: nil
                )
            }
            operationalRetrySnapshots.removeValue(forKey: request)
            return nil
        case let .ineligible(current, unresolvedPublication):
            if let unresolvedPublication {
                return retainOperationalRetry(
                    request: request,
                    fallback: snapshot.fallback,
                    publication: unresolvedPublication
                )
            }
            operationalRetrySnapshots.removeValue(forKey: request)
            return .rejected(current, .eligibilityChanged)
        case let .unavailable(unresolvedPublication):
            return retainOperationalRetry(
                request: request,
                fallback: snapshot.fallback,
                publication: unresolvedPublication
            )
        }
    }

    private func reject(
        _ session: any InvocationPendingPersistenceSession,
        fallback authority: InvocationPendingAuthority,
        reason: InvocationRejectionReason
    ) async -> InvocationTryOutcome {
        if authority.pendingUserTurn.failure != nil {
            await session.abandon()
            return .rejected(authority.aggregate, reason)
        }
        return switch await session.terminate(.rejected) {
        case let .committed(aggregate):
            .rejected(aggregate, reason)
        case let .stale(current):
            .rejected(current, .eligibilityChanged)
        case let .recovered(resolution):
            interruptionAfterTerminalRecovery(
                resolution,
                request: authority.request,
                fallback: authority.aggregate
            )
        }
    }
}
