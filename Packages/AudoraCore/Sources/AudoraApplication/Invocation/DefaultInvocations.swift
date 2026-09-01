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
        replacement = try base.installingAttempt(
            identity.makeAttempt(ordinal: nextOrdinal, kind: kind)
        )
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
    private let persistence: any InvocationPersistencePort
    private let admission: any InvocationAdmissionPort
    private let provider: any SyntheticCoachProviderPort
    private let coachContext: any CoachContextCoordinating
    private let clock: any ChatClock
    private let identities: any InvocationIdentityGenerating
    private let retrySleeper: any InvocationRetrySleeping
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
        retrySleeper: any InvocationRetrySleeping = TaskInvocationRetrySleeper()
    ) {
        self.persistence = persistence
        self.admission = admission
        self.provider = provider
        self.coachContext = coachContext
        self.clock = clock
        self.identities = identities
        self.retrySleeper = retrySleeper
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
        retrySleeper: any InvocationRetrySleeping = TaskInvocationRetrySleeper()
    ) {
        self.persistence = persistence
        self.admission = admission
        provider = DeterministicSyntheticCoachProvider()
        coachContext = DefaultCoachContextFeature()
        self.clock = clock
        self.identities = identities
        self.retrySleeper = retrySleeper
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
            switch await session.terminate(.contextCapacityFailure) {
            case let .committed(aggregate):
                return .contextCapacityFailure(aggregate, failure.quote)
            case let .stale(current):
                return .rejected(current, .eligibilityChanged)
            case let .recovered(resolution):
                return interruptionAfterTerminalRecovery(
                    resolution,
                    request: firstAuthority.request,
                    fallback: firstAuthority.aggregate
                )
            }
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
            return await interruptPending(
                session,
                fallback: finalAuthority,
                reason: .persistenceUnavailable
            )
        case .cooldown:
            return await reject(session, fallback: finalAuthority, reason: .admissionCooldown)
        case .clockRollback:
            return await reject(session, fallback: finalAuthority, reason: .clockRollback)
        case .ledgerFull:
            return await reject(session, fallback: finalAuthority, reason: .admissionLedgerFull)
        case .unavailable:
            return await reject(session, fallback: finalAuthority, reason: .admissionUnavailable)
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
            switch await activeSession.abort() {
            case let .committed(aggregate):
                return .rejected(aggregate, .contextChanged)
            case let .stale(current):
                return .rejected(current, .contextChanged)
            case let .recovered(resolution):
                return interruptionAfterTerminalRecovery(
                    resolution,
                    request: finalAuthority.request,
                    fallback: processingAggregate
                )
            }
        }

        let coachMarkdown: String
        providerAttempts: while true {
            let invocation = activeSession.invocation
            let attempt = invocation.attempt
            guard let transportAuthority = attempt.transportAuthority else {
                return await interruptAndAbort(
                    activeSession,
                    fallback: processingAggregate,
                    reason: .persistenceUnavailable
                )
            }
            let control: CoachProviderAttemptControl = switch attempt.kind {
            case .standard:
                .standard
            case .shorterRepair:
                .shorterRepair(instruction: Self.shorterRepairInstruction)
            }
            let outcome = await provider.run(
                SyntheticCoachProviderRequest(
                    invocation: invocation,
                    attempt: attempt,
                    exchange: prepared.exchange,
                    transcriptAccess: ProviderAttemptTranscriptAccess(
                        handles: transportAuthority.transcriptHandles
                    ),
                    control: control
                )
            )
            switch outcome {
            case let .complete(markdown):
                coachMarkdown = markdown
                break providerAttempts
            case .userRetryableFailure:
                return await interruptAndAbort(
                    activeSession,
                    fallback: processingAggregate,
                    reason: .providerFailed
                )
            case .autoRetryableFailure:
                guard attempt.kind == .standard,
                      attempt.ordinal < CoachProviderAttempt.maximumOrdinal
                else {
                    return await interruptAndAbort(
                        activeSession,
                        fallback: processingAggregate,
                        reason: .providerFailed
                    )
                }
                let delayIndex = Int(attempt.ordinal - 1)
                guard Self.automaticRetryDelaysMilliseconds.indices.contains(delayIndex)
                else {
                    return await interruptAndAbort(
                        activeSession,
                        fallback: processingAggregate,
                        reason: .providerFailed
                    )
                }
                do {
                    try await retrySleeper.sleep(
                        milliseconds: Self.automaticRetryDelaysMilliseconds[delayIndex]
                    )
                } catch {
                    return await interruptAndAbort(
                        activeSession,
                        fallback: processingAggregate,
                        reason: .providerFailed
                    )
                }
                switch await installNextAttempt(
                    after: activeSession,
                    kind: .standard,
                    prepared: prepared,
                    fallback: processingAggregate
                ) {
                case let .installed(next): activeSession = next
                case let .terminal(outcome): return outcome
                }
            case .responseOverflow:
                guard attempt.kind == .standard,
                      attempt.ordinal < CoachProviderAttempt.maximumOrdinal
                else {
                    return await interruptAndAbort(
                        activeSession,
                        fallback: processingAggregate,
                        reason: .invalidProviderResponse
                    )
                }
                switch await installNextAttempt(
                    after: activeSession,
                    kind: .shorterRepair,
                    prepared: prepared,
                    fallback: processingAggregate
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
                coachMarkdown: coachMarkdown,
                completedAt: completedAt
            )
        } catch {
            return await interruptAndAbort(
                activeSession,
                fallback: processingAggregate,
                reason: .invalidProviderResponse
            )
        }

        switch await activeSession.publish(publication) {
        case let .committed(aggregate):
            return .published(aggregate, prepared.quote)
        case let .stale(current):
            return await interruptAndAbort(
                activeSession,
                fallback: current ?? processingAggregate,
                reason: .publicationConflict,
                publication: PublicationRecoveryIntent(
                    mutation: publication,
                    quote: prepared.quote
                )
            )
        case .failed:
            return await interruptAndAbort(
                activeSession,
                fallback: processingAggregate,
                reason: .persistenceUnavailable,
                publication: PublicationRecoveryIntent(
                    mutation: publication,
                    quote: prepared.quote
                )
            )
        }
    }

    private func installNextAttempt(
        after session: any InvocationActivePersistenceSession,
        kind: CoachProviderAttemptKind,
        prepared: PreparedCoachLaunchContext,
        fallback: ChatAggregate
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
            } catch {
                return .terminal(
                    await interruptAndAbort(
                        session,
                        fallback: fallback,
                        reason: .persistenceUnavailable
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
                    await interruptAndAbort(
                        session,
                        fallback: current ?? fallback,
                        reason: .persistenceUnavailable
                    )
                )
            case .failed:
                return .terminal(
                    await interruptAndAbort(
                        session,
                        fallback: fallback,
                        reason: .persistenceUnavailable
                    )
                )
            }
        }
        _ = lastCollision
        return .terminal(
            await interruptAndAbort(
                session,
                fallback: fallback,
                reason: .persistenceUnavailable
            )
        )
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
        case .publicationConflict, .persistenceUnavailable: .coachResponseInterrupted
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
            return .interrupted(current ?? fallback, reason)
        }
        if case .notPublished? = priorRecovery {
            return .interrupted(current ?? fallback, reason)
        }
        switch await resolvePublicationRecovery(publication) {
        case let .published(outcome):
            return outcome
        case .notPublished:
            return .interrupted(current ?? fallback, reason)
        case .unavailable:
            return await interruptionAfterTerminalFailure(
                request: pendingRequest(for: invocation),
                fallback: fallback,
                publication: publication
            )
        }
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
