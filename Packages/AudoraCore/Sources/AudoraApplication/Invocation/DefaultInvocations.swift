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
public struct InvocationLaunchIdentity: Equatable, Sendable {
    public let invocationID: CoachInvocationID
    public let attemptID: CoachProviderAttemptID
    public let idempotencyValue: ProviderIdempotencyValue
    public let userMessageID: ChatMessageID
    public let coachMessageID: ChatMessageID
    public let freshDraftID: ChatDraftID

    public init(
        invocationID: CoachInvocationID,
        attemptID: CoachProviderAttemptID,
        idempotencyValue: ProviderIdempotencyValue,
        userMessageID: ChatMessageID,
        coachMessageID: ChatMessageID,
        freshDraftID: ChatDraftID
    ) {
        self.invocationID = invocationID
        self.attemptID = attemptID
        self.idempotencyValue = idempotencyValue
        self.userMessageID = userMessageID
        self.coachMessageID = coachMessageID
        self.freshDraftID = freshDraftID
    }
}

@_spi(InvocationInfrastructure)
public protocol InvocationIdentityGenerating: Sendable {
    func generate(at instant: UTCInstant) async -> InvocationLaunchIdentity
}

public enum InvocationLaunchIdentityCollision: String, CaseIterable, Equatable, Sendable {
    case invocationID
    case attemptID
    case providerIdempotencyValue
    case userMessageID
    case coachMessageID
    case freshDraftID
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

    public init(
        authority: InvocationPendingAuthority,
        identity: InvocationLaunchIdentity,
        preparedProfile: CoachProfileProvenance,
        admittedAt: UTCInstant
    ) throws {
        self.authority = authority
        invocation = try CoachInvocation(
            id: identity.invocationID,
            attemptID: identity.attemptID,
            providerIdempotencyValue: identity.idempotencyValue,
            library: authority.request.library,
            chatID: authority.request.chatID,
            pendingUserTurn: authority.pendingUserTurn,
            preparedProfile: preparedProfile,
            expectedManifestRevision: authority.aggregate.chat.manifestRevision,
            admittedAt: admittedAt
        )
        try invocation.validate(against: authority.aggregate)
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
        identity: InvocationLaunchIdentity,
        coachMarkdown: String,
        completedAt: UTCInstant
    ) throws {
        self.base = base
        self.invocation = invocation
        userMessage = try ChatMessage(
            id: identity.userMessageID,
            responsePositionID: invocation.responsePositionID,
            content: .user(text: base.chat.draft.text),
            createdAt: completedAt
        )
        coachMessage = try ChatMessage(
            id: identity.coachMessageID,
            responsePositionID: invocation.responsePositionID,
            content: .coach(markdown: coachMarkdown),
            coachProfile: invocation.preparedProfile,
            createdAt: completedAt
        )
        freshDraft = try ChatDraft(
            draftID: identity.freshDraftID,
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
public protocol InvocationPersistencePort: Sendable {
    /// Acquires Library-wide Invocation liveness before atomically installing
    /// and binding the exact new Pending. Every non-prepared result owns no
    /// liveness lease.
    func prepareNewPendingInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> InvocationPendingPreparationOutcome

    /// Acquires the Library-wide Invocation liveness authority before reading
    /// and resolving this exact Pending. Any non-acquired result owns no lease.
    func acquirePendingInvocation(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingAcquisitionOutcome

    /// Rereads the exact Pending while the acquisition lease remains held.
    /// Persistence releases that lease before returning `.ineligible`.
    func revalidatePendingInvocation(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingResolutionOutcome

    func installInvocation(
        _ mutation: InstallCoachInvocationMutation
    ) async -> InvocationInstallOutcome

    /// Releases only this exact pending reservation when no current Pending
    /// authority remains available for a terminal mutation.
    func cancelInvocationReservation(
        _ request: PendingCoachInvocationRequest
    ) async

    /// Persistence owns every durable identity namespace. This check runs while
    /// the exact Pending/Library reservation is held and before admission debit.
    func checkLaunchIdentity(
        _ identity: InvocationLaunchIdentity,
        for authority: InvocationPendingAuthority
    ) async -> InvocationLaunchIdentityAvailabilityOutcome

    func markContextCapacityFailure(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome

    /// Releases the exact pre-install reservation while durably retaining the
    /// Pending intent as an interrupted user-retryable failure.
    func markInterruptedNewSend(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome

    /// Runs only after the terminal owner has released its liveness lease.
    /// Persistence may reconcile an interrupted Invocation/Pending and then
    /// reread the exact Pending so Application can distinguish durable state
    /// from an operational retry projection.
    func recoverPendingAfterTerminalFailure(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingResolutionOutcome

    func rejectNewSend(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome

    func abortInstalledNewSend(
        _ invocation: CoachInvocation
    ) async -> InvocationPendingMutationOutcome

    func publish(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationOutcome

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

struct SyntheticCoachProviderRequest: Sendable {
    let invocation: CoachInvocation
    let exchange: CanonicalCoachExchange
}

protocol SyntheticCoachProviderPort: Sendable {
    func run(_ request: SyntheticCoachProviderRequest) async throws -> String
}

struct DeterministicSyntheticCoachProvider: SyntheticCoachProviderPort {
    static let markdown = "This is a complete synthetic coaching response."

    func run(_ request: SyntheticCoachProviderRequest) async throws -> String {
        Self.markdown
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

    private struct OperationalRetrySnapshot: Sendable {
        let fallback: ChatAggregate
        let publication: PublicationRecoveryIntent?
    }

    static let maximumLaunchIdentityCandidates = 4
    private let persistence: any InvocationPersistencePort
    private let admission: any InvocationAdmissionPort
    private let provider: any SyntheticCoachProviderPort
    private let coachContext: any CoachContextCoordinating
    private let clock: any ChatClock
    private let identities: any InvocationIdentityGenerating
    private var inFlightRequests: Set<PendingCoachInvocationRequest> = []
    private var preparedAuthorities: [UUID: InvocationPendingAuthority] = [:]
    private var operationalRetrySnapshots: [
        PendingCoachInvocationRequest: OperationalRetrySnapshot
    ] = [:]

    init(
        persistence: any InvocationPersistencePort,
        admission: any InvocationAdmissionPort,
        provider: any SyntheticCoachProviderPort,
        coachContext: any CoachContextCoordinating,
        clock: any ChatClock,
        identities: any InvocationIdentityGenerating
    ) {
        self.persistence = persistence
        self.admission = admission
        self.provider = provider
        self.coachContext = coachContext
        self.clock = clock
        self.identities = identities
    }

    /// Production composition seam. Exact preparation and the synthetic provider
    /// remain behind this coordinator; Infrastructure supplies only durable
    /// persistence, admission, time, and stable identities.
    @_spi(InvocationInfrastructure)
    public init(
        persistence: any InvocationPersistencePort,
        admission: any InvocationAdmissionPort,
        clock: any ChatClock,
        identities: any InvocationIdentityGenerating
    ) {
        self.persistence = persistence
        self.admission = admission
        provider = DeterministicSyntheticCoachProvider()
        coachContext = DefaultCoachContextFeature()
        self.clock = clock
        self.identities = identities
    }

    public func prepareNewInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> NewPendingCoachInvocationOutcome {
        switch await persistence.prepareNewPendingInvocation(request) {
        case let .prepared(authority):
            let prepared = PreparedPendingCoachInvocation(authority: authority)
            preparedAuthorities[prepared.capabilityID] = authority
            return .prepared(prepared)
        case let .stale(current):
            return .stale(current)
        case let .frozen(frozen):
            return .frozen(frozen)
        case .readOnlyLibrary:
            return .readOnlyLibrary
        case .activeExists:
            return .activeInvocation
        case .unavailable:
            return .failed
        }
    }

    public func abandonPreparedInvocation(
        _ prepared: PreparedPendingCoachInvocation
    ) async {
        guard let authority = preparedAuthorities[prepared.capabilityID],
              authority.request == prepared.request,
              authority.aggregate == prepared.aggregate
        else { return }
        preparedAuthorities.removeValue(forKey: prepared.capabilityID)
        await persistence.cancelInvocationReservation(authority.request)
    }

    public func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation
    ) async -> InvocationTryOutcome {
        guard let authority = preparedAuthorities[prepared.capabilityID],
              authority.request == prepared.request,
              authority.aggregate == prepared.aggregate
        else {
            return .rejected(nil, .eligibilityChanged)
        }
        preparedAuthorities.removeValue(forKey: prepared.capabilityID)
        let request = prepared.request
        guard inFlightRequests.insert(request).inserted else {
            await persistence.cancelInvocationReservation(request)
            return .rejected(nil, .activeInvocation)
        }
        defer { inFlightRequests.remove(request) }

        return await invoke(request, firstAuthority: authority)
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

        let firstAuthority: InvocationPendingAuthority
        switch await persistence.acquirePendingInvocation(request) {
        case let .acquired(authority):
            firstAuthority = authority
        case let .ineligible(current):
            return .rejected(current, .eligibilityChanged)
        case .activeExists:
            return .rejected(nil, .activeInvocation)
        case .unavailable:
            return .rejected(nil, .persistenceUnavailable)
        }

        return await invoke(request, firstAuthority: firstAuthority)
    }

    private func invoke(
        _ request: PendingCoachInvocationRequest,
        firstAuthority: InvocationPendingAuthority
    ) async -> InvocationTryOutcome {
        let draft = firstAuthority.aggregate.chat.draft
        guard draft.text.utf8.count <= CoachContextInputLimits.maximumUserMessageUTF8Bytes else {
            return await reject(
                firstAuthority,
                reason: .messageMustBeShortened(
                    maximumUTF8Bytes: CoachContextInputLimits.maximumUserMessageUTF8Bytes
                )
            )
        }
        guard draft.text.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) else {
            return await reject(firstAuthority, reason: .eligibilityChanged)
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
            return await reject(firstAuthority, reason: .eligibilityChanged)
        }

        let prepared: PreparedCoachLaunchContext
        switch await coachContext.preparePendingUserTurn(contextRequest) {
        case let .prepared(value):
            prepared = value
        case let .cannotFit(failure):
            switch await persistence.markContextCapacityFailure(firstAuthority) {
            case let .committed(aggregate):
                return .contextCapacityFailure(aggregate, failure.quote)
            case let .stale(current):
                return .rejected(current, .eligibilityChanged)
            case .failed:
                return await interruptionAfterTerminalFailure(
                    request: firstAuthority.request,
                    fallback: firstAuthority.aggregate
                )
            }
        case let .messageTooLong(maximumUTF8Bytes):
            return await reject(
                firstAuthority,
                reason: .messageMustBeShortened(maximumUTF8Bytes: maximumUTF8Bytes)
            )
        case let .unavailable(reason):
            return await reject(firstAuthority, reason: .contextUnavailable(reason))
        }

        let finalAuthority: InvocationPendingAuthority
        switch await persistence.revalidatePendingInvocation(firstAuthority) {
        case let .eligible(authority) where authority == firstAuthority:
            finalAuthority = authority
        case let .eligible(authority):
            return await reject(authority, reason: .eligibilityChanged)
        case let .ineligible(current):
            return .rejected(current, .eligibilityChanged)
        case .unavailable:
            return await reject(firstAuthority, reason: .persistenceUnavailable)
        }

        let identityInstant = await clock.now()
        var selectedIdentity: InvocationLaunchIdentity?
        var lastCollision: InvocationLaunchIdentityCollision?
        for _ in 0 ..< Self.maximumLaunchIdentityCandidates {
            let candidate = await identities.generate(at: identityInstant)
            switch await persistence.checkLaunchIdentity(
                candidate,
                for: finalAuthority
            ) {
            case .available:
                selectedIdentity = candidate
            case let .collision(collision):
                lastCollision = collision
                continue
            case let .stale(current):
                if let current,
                   let currentAuthority = try? InvocationPendingAuthority(
                       request: request,
                       aggregate: current
                   )
                {
                    return await reject(currentAuthority, reason: .eligibilityChanged)
                }
                await persistence.cancelInvocationReservation(finalAuthority.request)
                return .rejected(current, .eligibilityChanged)
            case .unavailable:
                return await reject(finalAuthority, reason: .persistenceUnavailable)
            }
            break
        }
        guard let identity = selectedIdentity else {
            return await reject(
                finalAuthority,
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
                finalAuthority,
                reason: .persistenceUnavailable
            )
        case .cooldown:
            return await reject(finalAuthority, reason: .admissionCooldown)
        case .clockRollback:
            return await reject(finalAuthority, reason: .clockRollback)
        case .ledgerFull:
            return await reject(finalAuthority, reason: .admissionLedgerFull)
        case .unavailable:
            return await reject(finalAuthority, reason: .admissionUnavailable)
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
                finalAuthority,
                reason: .persistenceUnavailable
            )
        }

        let invocation: CoachInvocation
        switch await persistence.installInvocation(install) {
        case let .installed(value):
            invocation = value
        case .activeExists:
            return await interruptPending(
                finalAuthority,
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
                    currentAuthority,
                    reason: .persistenceUnavailable
                )
            }
            await persistence.cancelInvocationReservation(finalAuthority.request)
            return .rejected(current, .eligibilityChanged)
        case .failed:
            return await interruptPending(
                finalAuthority,
                reason: .persistenceUnavailable
            )
        }

        guard await coachContext.isPreparedContextCurrent(prepared) else {
            switch await persistence.abortInstalledNewSend(invocation) {
            case let .committed(aggregate):
                return .rejected(aggregate, .contextChanged)
            case let .stale(current):
                return .rejected(current, .contextChanged)
            case .failed:
                return await interruptionAfterTerminalFailure(
                    request: finalAuthority.request,
                    fallback: finalAuthority.aggregate
                )
            }
        }

        let coachMarkdown: String
        do {
            coachMarkdown = try await provider.run(
                SyntheticCoachProviderRequest(
                    invocation: invocation,
                    exchange: prepared.exchange
                )
            )
        } catch {
            return await interruptAndAbort(
                invocation,
                fallback: finalAuthority.aggregate,
                reason: .providerFailed
            )
        }

        let completedAt = await clock.now()
        let publication: PublishCoachInvocationMutation
        do {
            publication = try PublishCoachInvocationMutation(
                base: finalAuthority.aggregate,
                invocation: invocation,
                identity: identity,
                coachMarkdown: coachMarkdown,
                completedAt: completedAt
            )
        } catch {
            return await interruptAndAbort(
                invocation,
                fallback: finalAuthority.aggregate,
                reason: .invalidProviderResponse
            )
        }

        switch await persistence.publish(publication) {
        case let .committed(aggregate):
            return .published(aggregate, prepared.quote)
        case let .stale(current):
            return await interruptAndAbort(
                invocation,
                fallback: current ?? finalAuthority.aggregate,
                reason: .publicationConflict,
                publication: PublicationRecoveryIntent(
                    mutation: publication,
                    quote: prepared.quote
                )
            )
        case .failed:
            return await interruptAndAbort(
                invocation,
                fallback: finalAuthority.aggregate,
                reason: .persistenceUnavailable,
                publication: PublicationRecoveryIntent(
                    mutation: publication,
                    quote: prepared.quote
                )
            )
        }
    }

    public func admissionAvailability(
        in library: LibraryScope
    ) async -> InvocationAdmissionAvailability {
        let instant = await clock.now()
        return await admission.availability(library: library, at: instant)
    }

    private func interruptAndAbort(
        _ invocation: CoachInvocation,
        fallback: ChatAggregate,
        reason: InvocationInterruptionReason,
        publication: PublicationRecoveryIntent? = nil
    ) async -> InvocationTryOutcome {
        var publicationRecovery: PublicationRecoveryResolution?
        if let publication {
            let resolution = await resolvePublicationRecovery(publication)
            if case let .published(outcome) = resolution { return outcome }
            publicationRecovery = resolution
        }
        return switch await persistence.abortInstalledNewSend(invocation) {
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
        case .failed:
            await interruptionAfterTerminalFailure(
                request: pendingRequest(for: invocation),
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
        _ publication: PublicationRecoveryIntent
    ) async -> PublicationRecoveryResolution {
        switch await persistence.recoverPublishedInvocation(publication.mutation) {
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
        _ authority: InvocationPendingAuthority,
        reason: InvocationInterruptionReason
    ) async -> InvocationTryOutcome {
        switch await persistence.markInterruptedNewSend(authority) {
        case let .committed(aggregate):
            .interrupted(aggregate, reason)
        case let .stale(current):
            .interrupted(current ?? authority.aggregate, reason)
        case .failed:
            await interruptionAfterTerminalFailure(
                request: authority.request,
                fallback: authority.aggregate
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
        _ authority: InvocationPendingAuthority,
        reason: InvocationRejectionReason
    ) async -> InvocationTryOutcome {
        if authority.pendingUserTurn.failure != nil {
            await persistence.cancelInvocationReservation(authority.request)
            return .rejected(authority.aggregate, reason)
        }
        return switch await persistence.rejectNewSend(authority) {
        case let .committed(aggregate):
            .rejected(aggregate, reason)
        case let .stale(current):
            .rejected(current, .eligibilityChanged)
        case .failed:
            await interruptionAfterTerminalFailure(
                request: authority.request,
                fallback: authority.aggregate
            )
        }
    }
}
