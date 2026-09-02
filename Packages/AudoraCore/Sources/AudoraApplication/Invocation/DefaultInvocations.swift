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
            pendingUserTurn: newRequest.pendingUserTurn
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
}

public enum InvocationAdmissionAvailability: Equatable, Sendable {
    case available
    case cooldown(reopensAt: UTCInstant)
    case unavailable
}

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
}

public extension Invocations {
    func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        .unavailable
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
public protocol InvocationIdentityGenerating: Sendable {
    func generateInvocationID(at instant: UTCInstant) async -> CoachInvocationID

    func generateAttemptIdentity(
        at instant: UTCInstant,
        ordinal: UInt8,
        kind: CoachProviderAttemptKind,
        transcriptHandleCount: Int
    ) async -> InvocationAttemptIdentity
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
            pendingUserTurn: authority.pendingUserTurn.replacingFailure(nil)
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
public enum InvocationNextAttemptInstallOutcome: Sendable {
    case installed(any InvocationActivePersistenceSession)
    case collision(InvocationLaunchIdentityCollision)
    case stale(ChatAggregate?)
    case failed
}

@_spi(InvocationInfrastructure)
public struct PublishCoachInvocationMutation: Equatable, Sendable {
    public let base: ChatAggregate
    public let invocation: CoachInvocation
    public let userMessage: ChatMessage
    public let coachMessage: ChatMessage
    public let freshDraft: ChatDraft
    public let replacement: ChatAggregate

    public init(
        base: ChatAggregate,
        invocation: CoachInvocation,
        coachMarkdown: String,
        completedAt: UTCInstant
    ) throws {
        self.base = base
        self.invocation = invocation
        guard let authority = invocation.attempt.publicationAuthority else {
            throw CoachInvocationError.attemptPublicationAuthorityRequired
        }
        userMessage = try ChatMessage(
            id: authority.userMessageID,
            responsePositionID: invocation.responsePositionID,
            content: .user(text: base.chat.draft.text),
            createdAt: completedAt
        )
        coachMessage = try ChatMessage(
            id: authority.coachMessageID,
            responsePositionID: invocation.responsePositionID,
            content: .coach(markdown: coachMarkdown),
            coachProfile: invocation.preparedProfile,
            createdAt: completedAt
        )
        freshDraft = try ChatDraft(
            draftID: authority.freshDraftID,
            version: 0,
            text: "",
            updatedAt: completedAt
        )
        replacement = try base.publishingTurn(
            invocation: invocation,
            userMessage: userMessage,
            coachMessage: coachMessage,
            freshDraft: freshDraft,
            at: completedAt
        )
    }

    public init(
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
}

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

struct ProviderAttemptTranscriptAccess: Equatable, Sendable {
    let handles: [PreparedCoachTranscriptHandle]
}

enum CoachProviderAttemptControl: Equatable, Sendable {
    case standard
    case shorterRepair(instruction: String)
}

enum CoachProviderAttemptOutcome: Equatable, Sendable {
    case complete(markdown: String)
    case autoRetryableFailure
    case userRetryableFailure
    case responseOverflow
}

struct SyntheticCoachProviderRequest: Sendable {
    let invocation: CoachInvocation
    let attempt: CoachProviderAttempt
    let exchange: CanonicalCoachExchange
    let transcriptAccess: ProviderAttemptTranscriptAccess
    let outputTokenCeiling: Int
    let pinnedInstruction: String
    let control: CoachProviderAttemptControl
}

protocol SyntheticCoachProviderPort: Sendable {
    func run(_ request: SyntheticCoachProviderRequest) async -> CoachProviderAttemptOutcome
}

struct DeterministicSyntheticCoachProvider: SyntheticCoachProviderPort {
    static let markdown = "This is a complete synthetic coaching response."

    func run(_ request: SyntheticCoachProviderRequest) async -> CoachProviderAttemptOutcome {
        .complete(markdown: Self.markdown)
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
    case nextAttemptIdentityCollisionExhausted
    case nextAttemptConstructionFailed
    case nextAttemptInstallationFailed
    case nextAttemptBecameStale
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
    private struct PublicationRecoveryIntent: Sendable {
        let mutation: PublishCoachInvocationMutation
        let quote: CoachContextQuote
    }

    private enum PublicationRecoveryResolution {
        case published(InvocationTryOutcome)
        case notPublished
        case unavailable(PublicationRecoveryIntent)
    }

    private enum TerminalRecoveryResolution {
        case published(InvocationTryOutcome)
        case eligible(InvocationPendingAuthority)
        case ineligible(ChatAggregate?, unresolvedPublication: PublicationRecoveryIntent?)
        case unavailable(unresolvedPublication: PublicationRecoveryIntent?)
    }

    private enum NextAttemptResolution {
        case installed(any InvocationActivePersistenceSession)
        case terminal(InvocationTryOutcome)
    }

    private struct OperationalRetrySnapshot: Sendable {
        let fallback: ChatAggregate
        let publication: PublicationRecoveryIntent?
    }

    static let maximumLaunchIdentityCandidates = 4
    static let automaticRetryDelaysMilliseconds: [Int64] = [5_000, 10_000, 15_000]
    static let shorterRepairInstruction = """
    The previous Attempt exceeded the response limit. Return a materially shorter \
    complete response. Preserve the direct answer, remove repetition and optional \
    detail, and never return partial JSON.
    """

    static func pinnedInstruction(outputTokenCeiling: Int) -> String {
        "Return one complete structured response that fits within the " +
            "\(outputTokenCeiling)-token output allowance."
    }
    private let persistence: any InvocationPersistencePort
    private let admission: any InvocationAdmissionPort
    private let provider: any SyntheticCoachProviderPort
    private let coachContext: any CoachContextCoordinating
    private let clock: any ChatClock
    private let identities: any InvocationIdentityGenerating
    private let retrySleeper: any InvocationRetrySleeping
    private let retryDiagnostics: any InvocationRetryDiagnostics
    private let retryTiming: any InvocationRetryTiming
    private var inFlightRequests: Set<PendingCoachInvocationRequest> = []
    private var preparedSessions: [
        UUID: any InvocationPendingPersistenceSession
    ] = [:]
    private var operationalRetrySnapshots: [
        PendingCoachInvocationRequest: OperationalRetrySnapshot
    ] = [:]

    init(
        persistence: any InvocationPersistencePort,
        admission: any InvocationAdmissionPort,
        provider: any SyntheticCoachProviderPort,
        coachContext: any CoachContextCoordinating,
        clock: any ChatClock,
        identities: any InvocationIdentityGenerating,
        retrySleeper: any InvocationRetrySleeping = TaskInvocationRetrySleeper(),
        retryDiagnostics: any InvocationRetryDiagnostics =
            DiscardingInvocationRetryDiagnostics(),
        retryTiming: any InvocationRetryTiming = ContinuousInvocationRetryTiming()
    ) {
        self.persistence = persistence
        self.admission = admission
        self.provider = provider
        self.coachContext = coachContext
        self.clock = clock
        self.identities = identities
        self.retrySleeper = retrySleeper
        self.retryDiagnostics = retryDiagnostics
        self.retryTiming = retryTiming
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
        retrySleeper: any InvocationRetrySleeping = TaskInvocationRetrySleeper(),
        retryDiagnostics: any InvocationRetryDiagnostics =
            DiscardingInvocationRetryDiagnostics(),
        retryTiming: any InvocationRetryTiming = ContinuousInvocationRetryTiming()
    ) {
        self.persistence = persistence
        self.admission = admission
        provider = DeterministicSyntheticCoachProvider()
        coachContext = DefaultCoachContextFeature()
        self.clock = clock
        self.identities = identities
        self.retrySleeper = retrySleeper
        self.retryDiagnostics = retryDiagnostics
        self.retryTiming = retryTiming
    }

    public func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
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
        guard let session = preparedSessions[prepared.capabilityID],
              session.authority.request == prepared.request,
              session.authority.aggregate == prepared.aggregate
        else {
            return .rejected(nil, .eligibilityChanged)
        }
        preparedSessions.removeValue(forKey: prepared.capabilityID)
        let request = prepared.request
        guard inFlightRequests.insert(request).inserted else {
            await session.abandon()
            return .rejected(nil, .activeInvocation)
        }
        defer { inFlightRequests.remove(request) }

        return await invoke(session)
    }

    public func tryInvoke(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationTryOutcome {
        guard inFlightRequests.insert(request).inserted else {
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

        return await invoke(session)
    }

    private func invoke(
        _ session: any InvocationPendingPersistenceSession
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
            markdown: String,
            startedAtMilliseconds: UInt64
        )
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
            let attemptInstruction: String = switch control {
            case .standard:
                ""
            case let .shorterRepair(instruction):
                " \(instruction)"
            }
            let pinnedInstruction = Self.pinnedInstruction(
                outputTokenCeiling: outputTokenCeiling
            ) + attemptInstruction
            let outcome = await provider.run(
                SyntheticCoachProviderRequest(
                    invocation: invocation,
                    attempt: attempt,
                    exchange: prepared.exchange,
                    transcriptAccess: ProviderAttemptTranscriptAccess(
                        handles: transportAuthority.transcriptHandles
                    ),
                    outputTokenCeiling: outputTokenCeiling,
                    pinnedInstruction: pinnedInstruction,
                    control: control
                )
            )
            switch outcome {
            case let .complete(markdown):
                completedProviderResponse = (markdown, attemptStartedAt)
                break providerAttempts
            case .userRetryableFailure:
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
                do {
                    try await retrySleeper.sleep(
                        milliseconds: Self.automaticRetryDelaysMilliseconds[delayIndex]
                    )
                } catch {
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
                switch await installNextAttempt(
                    after: activeSession,
                    kind: .standard,
                    prepared: prepared,
                    fallback: processingAggregate,
                    startedAt: attemptStartedAt
                ) {
                case let .installed(next): activeSession = next
                case let .terminal(outcome): return outcome
                }
            case .responseOverflow:
                guard attempt.kind == .standard,
                      attempt.ordinal < CoachProviderAttempt.maximumOrdinal
                else {
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
                switch await installNextAttempt(
                    after: activeSession,
                    kind: .shorterRepair,
                    prepared: prepared,
                    fallback: processingAggregate,
                    startedAt: attemptStartedAt
                ) {
                case let .installed(next): activeSession = next
                case let .terminal(outcome): return outcome
                }
            }
        }

        let completedAt = await clock.now()
        let invocation = activeSession.invocation
        let publication: PublishCoachInvocationMutation
        do {
            publication = try PublishCoachInvocationMutation(
                base: processingAggregate,
                invocation: invocation,
                coachMarkdown: completedProviderResponse.markdown,
                completedAt: completedAt
            )
        } catch {
            return await interruptAndAbortRecordingUserRetry(
                activeSession,
                fallback: processingAggregate,
                reason: .invalidProviderResponse,
                diagnosticReason: .invalidCompleteResponse,
                classification: .invalidProviderResponse,
                prepared: prepared,
                startedAt: completedProviderResponse.startedAtMilliseconds
            )
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

    private func installNextAttempt(
        after session: any InvocationActivePersistenceSession,
        kind: CoachProviderAttemptKind,
        prepared: PreparedCoachLaunchContext,
        fallback: ChatAggregate,
        startedAt: UInt64
    ) async -> NextAttemptResolution {
        let ordinal = session.invocation.attempt.ordinal + 1
        var lastCollision: InvocationLaunchIdentityCollision?
        for _ in 0 ..< Self.maximumLaunchIdentityCandidates {
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
                return .terminal(
                    await interruptAndAbortRecordingUserRetry(
                        session,
                        fallback: fallback,
                        reason: .persistenceUnavailable,
                        diagnosticReason: .nextAttemptConstructionFailed,
                        classification: .retryInfrastructureFailure,
                        prepared: prepared,
                        startedAt: startedAt
                    )
                )
            }
            switch await session.installNextAttempt(mutation) {
            case let .installed(next):
                return .installed(next)
            case let .collision(collision):
                lastCollision = collision
                continue
            case let .stale(current):
                return .terminal(
                    await interruptAndAbortRecordingUserRetry(
                        session,
                        fallback: current ?? fallback,
                        reason: .persistenceUnavailable,
                        diagnosticReason: .nextAttemptBecameStale,
                        classification: .retryInfrastructureFailure,
                        prepared: prepared,
                        startedAt: startedAt
                    )
                )
            case .failed:
                return .terminal(
                    await interruptAndAbortRecordingUserRetry(
                        session,
                        fallback: fallback,
                        reason: .persistenceUnavailable,
                        diagnosticReason: .nextAttemptInstallationFailed,
                        classification: .retryInfrastructureFailure,
                        prepared: prepared,
                        startedAt: startedAt
                    )
                )
            }
        }
        _ = lastCollision
        return .terminal(
            await interruptAndAbortRecordingUserRetry(
                session,
                fallback: fallback,
                reason: .persistenceUnavailable,
                diagnosticReason: .nextAttemptIdentityCollisionExhausted,
                classification: .retryInfrastructureFailure,
                prepared: prepared,
                startedAt: startedAt
            )
        )
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
        case .published:
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

    private func interruptAndAbort(
        _ session: any InvocationActivePersistenceSession,
        fallback: ChatAggregate,
        reason: InvocationInterruptionReason,
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
        let terminalFailure: PendingUserTurnFailure = switch reason {
        case .providerFailed: .coachProviderError
        case .invalidProviderResponse: .coachResponseInvalid
        case .retryInfrastructureFailed, .publicationConflict,
             .persistenceUnavailable:
            .coachResponseInterrupted
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
        startedAt: UInt64
    ) async -> InvocationTryOutcome {
        let invocation = session.invocation
        let context = diagnosticContext(for: prepared)
        let durationMilliseconds = elapsedMilliseconds(since: startedAt)
        let outcome = await interruptAndAbort(
            session,
            fallback: fallback,
            reason: reason
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
        case .published, .contextCapacityFailure, .rejected:
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
