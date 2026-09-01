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
}

public protocol Invocations: Sendable {
    func tryInvoke(_ request: PendingCoachInvocationRequest) async -> InvocationTryOutcome
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
        guard pending.failure == nil else {
            throw InvocationPendingAuthorityError.failedPending
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
public enum InvocationActiveCheckOutcome: Equatable, Sendable {
    case none
    case exists
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

@_spi(InvocationInfrastructure)
public struct InstallCoachInvocationMutation: Equatable, Sendable {
    public let authority: InvocationPendingAuthority
    public let invocation: CoachInvocation

    public init(
        authority: InvocationPendingAuthority,
        identity: InvocationLaunchIdentity,
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
public protocol InvocationPersistencePort: Sendable {
    func resolvePending(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingResolutionOutcome

    /// Reserves the Library-wide Invocation authority for this exact request
    /// when returning `.none`. The reservation remains held until that request
    /// is installed or reaches a pending-terminal mutation.
    func reserveInvocation(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationActiveCheckOutcome

    func installInvocation(
        _ mutation: InstallCoachInvocationMutation
    ) async -> InvocationInstallOutcome

    /// Releases only this exact pending reservation when no current Pending
    /// authority remains available for a terminal mutation.
    func cancelInvocationReservation(
        _ request: PendingCoachInvocationRequest
    ) async

    func markContextCapacityFailure(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome

    func rejectNewSend(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome

    func abortInstalledNewSend(
        _ invocation: CoachInvocation
    ) async -> InvocationPendingMutationOutcome

    func publish(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationOutcome
}

@_spi(InvocationInfrastructure)
public enum InvocationAdmissionClaimOutcome: Equatable, Sendable {
    case admitted
    case cooldown(lastAdmittedAt: UTCInstant, reopensAt: UTCInstant)
    case clockRollback(lastAdmittedAt: UTCInstant)
    case ledgerFull
    case unavailable
}

@_spi(InvocationInfrastructure)
public protocol InvocationAdmissionPort: Sendable {
    func claim(
        library: LibraryScope,
        at instant: UTCInstant
    ) async -> InvocationAdmissionClaimOutcome
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
    private let persistence: any InvocationPersistencePort
    private let admission: any InvocationAdmissionPort
    private let provider: any SyntheticCoachProviderPort
    private let coachContext: any CoachContextCoordinating
    private let clock: any ChatClock
    private let identities: any InvocationIdentityGenerating
    private var inFlightRequests: Set<PendingCoachInvocationRequest> = []

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

    public func tryInvoke(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationTryOutcome {
        guard inFlightRequests.insert(request).inserted else {
            return .rejected(nil, .activeInvocation)
        }
        defer { inFlightRequests.remove(request) }

        let firstAuthority: InvocationPendingAuthority
        switch await persistence.resolvePending(request) {
        case let .eligible(authority):
            firstAuthority = authority
        case let .ineligible(current):
            return .rejected(current, .eligibilityChanged)
        case .unavailable:
            return .rejected(nil, .persistenceUnavailable)
        }

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

        switch await persistence.reserveInvocation(request) {
        case .none:
            break
        case .exists:
            return await reject(firstAuthority, reason: .activeInvocation)
        case .unavailable:
            return await reject(firstAuthority, reason: .persistenceUnavailable)
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
                return .interrupted(firstAuthority.aggregate, .persistenceUnavailable)
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
        switch await persistence.resolvePending(request) {
        case let .eligible(authority) where authority == firstAuthority:
            finalAuthority = authority
        case let .eligible(authority):
            return await reject(authority, reason: .eligibilityChanged)
        case let .ineligible(current):
            await persistence.cancelInvocationReservation(firstAuthority.request)
            return .rejected(current, .eligibilityChanged)
        case .unavailable:
            return await reject(firstAuthority, reason: .persistenceUnavailable)
        }

        let admittedAt = await clock.now()
        switch await admission.claim(library: request.library, at: admittedAt) {
        case .admitted:
            break
        case .cooldown:
            return await reject(finalAuthority, reason: .admissionCooldown)
        case .clockRollback:
            return await reject(finalAuthority, reason: .clockRollback)
        case .ledgerFull:
            return await reject(finalAuthority, reason: .admissionLedgerFull)
        case .unavailable:
            return await reject(finalAuthority, reason: .admissionUnavailable)
        }

        let identity = await identities.generate(at: admittedAt)
        let install: InstallCoachInvocationMutation
        do {
            install = try InstallCoachInvocationMutation(
                authority: finalAuthority,
                identity: identity,
                admittedAt: admittedAt
            )
        } catch {
            return await reject(finalAuthority, reason: .eligibilityChanged)
        }

        let invocation: CoachInvocation
        switch await persistence.installInvocation(install) {
        case let .installed(value):
            invocation = value
        case .activeExists:
            return await reject(finalAuthority, reason: .activeInvocation)
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
        case .failed:
            return await reject(finalAuthority, reason: .persistenceUnavailable)
        }

        guard await coachContext.isPreparedContextCurrent(prepared) else {
            switch await persistence.abortInstalledNewSend(invocation) {
            case let .committed(aggregate):
                return .rejected(aggregate, .contextChanged)
            case let .stale(current):
                return .rejected(current, .contextChanged)
            case .failed:
                return .interrupted(finalAuthority.aggregate, .persistenceUnavailable)
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
                reason: .publicationConflict
            )
        case .failed:
            return await interruptAndAbort(
                invocation,
                fallback: finalAuthority.aggregate,
                reason: .persistenceUnavailable
            )
        }
    }

    private func interruptAndAbort(
        _ invocation: CoachInvocation,
        fallback: ChatAggregate,
        reason: InvocationInterruptionReason
    ) async -> InvocationTryOutcome {
        switch await persistence.abortInstalledNewSend(invocation) {
        case let .committed(aggregate):
            .interrupted(aggregate, reason)
        case let .stale(current):
            .interrupted(current ?? fallback, reason)
        case .failed:
            .interrupted(fallback, .persistenceUnavailable)
        }
    }

    private func reject(
        _ authority: InvocationPendingAuthority,
        reason: InvocationRejectionReason
    ) async -> InvocationTryOutcome {
        switch await persistence.rejectNewSend(authority) {
        case let .committed(aggregate):
            .rejected(aggregate, reason)
        case let .stale(current):
            .rejected(current, .eligibilityChanged)
        case .failed:
            .interrupted(authority.aggregate, .persistenceUnavailable)
        }
    }
}
