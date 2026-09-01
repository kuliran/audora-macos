@_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain

@_spi(InvocationInfrastructure)
public actor PortableInvocationStore: InvocationPersistencePort {
    private enum InvocationLeaseState {
        case pending(
            request: PendingCoachInvocationRequest,
            lease: PortableInvocationLivenessLease
        )
        case installing(
            request: PendingCoachInvocationRequest,
            invocation: CoachInvocation,
            lease: PortableInvocationLivenessLease
        )
        case active(
            invocation: CoachInvocation,
            lease: PortableInvocationLivenessLease
        )

        var lease: PortableInvocationLivenessLease {
            switch self {
            case let .pending(_, lease),
                 let .installing(_, _, lease),
                 let .active(_, lease):
                lease
            }
        }
    }

    private let transactions: PortableInvocationTransactions
    private var invocationLeases: [LibraryID: InvocationLeaseState] = [:]

    public init(
        persistence: PortableChatPersistence = PortableChatPersistence(),
        workspace: PortableLibraryWorkspace
    ) {
        transactions = PortableInvocationTransactions(
            persistence: persistence,
            workspace: workspace
        )
    }

    public func openNewPendingInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> InvocationPendingSessionPreparationOutcome {
        switch await prepareNewPendingInvocation(request) {
        case let .prepared(authority):
            return .opened(
                PortablePendingInvocationSession(
                    store: self,
                    authority: authority
                )
            )
        case let .stale(current):
            return .stale(current)
        case let .frozen(frozen):
            return .frozen(frozen)
        case .readOnlyLibrary:
            return .readOnlyLibrary
        case .activeExists:
            return .blockedByActiveInvocation
        case .unavailable:
            return .unavailable
        }
    }

    public func openPendingInvocation(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingSessionAcquisitionOutcome {
        switch await acquirePendingInvocation(request) {
        case let .acquired(authority):
            return .opened(
                PortablePendingInvocationSession(
                    store: self,
                    authority: authority
                )
            )
        case let .ineligible(current):
            return .ineligible(current)
        case .activeExists:
            return .blockedByActiveInvocation
        case .unavailable:
            return .unavailable
        }
    }

    func prepareNewPendingInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> InvocationPendingPreparationOutcome {
        let libraryID = request.library.libraryID
        guard invocationLeases[libraryID] == nil else { return .activeExists }
        switch await transactions.prepareNewPendingInvocation(request) {
        case let .rejected(outcome):
            return outcome
        case let .prepared(authority, lease):
            guard invocationLeases[libraryID] == nil else {
                lease.release()
                return .activeExists
            }
            invocationLeases[libraryID] = .pending(
                request: authority.request,
                lease: lease
            )
            return .prepared(authority)
        }
    }

    func acquirePendingInvocation(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingAcquisitionOutcome {
        let libraryID = request.library.libraryID
        guard invocationLeases[libraryID] == nil else { return .activeExists }
        switch await transactions.acquirePendingInvocation(request) {
        case let .rejected(outcome):
            return outcome
        case let .acquired(authority, lease):
            guard invocationLeases[libraryID] == nil else {
                lease.release()
                return .activeExists
            }
            invocationLeases[libraryID] = .pending(
                request: request,
                lease: lease
            )
            return .acquired(authority)
        }
    }

    func revalidatePendingInvocation(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingResolutionOutcome {
        let request = authority.request
        guard pendingLease(for: request) != nil else { return .unavailable }
        let outcome = await transactions.revalidatePendingInvocation(authority)
        if case .ineligible = outcome {
            releasePendingLease(for: request)
        }
        return outcome
    }

    func installInvocation(
        _ mutation: InstallCoachInvocationMutation
    ) async -> InvocationInstallOutcome {
        let request = mutation.authority.request
        let libraryID = request.library.libraryID
        guard let lease = pendingLease(for: request) else { return .failed }
        invocationLeases[libraryID] = .installing(
            request: request,
            invocation: mutation.invocation,
            lease: lease
        )

        let outcome = await transactions.installInvocation(
            mutation,
            holding: lease
        )
        guard let state = invocationLeases[libraryID],
              case let .installing(installedRequest, expected, installedLease) = state,
              installedRequest == request,
              expected == mutation.invocation,
              installedLease === lease
        else {
            lease.release()
            return .failed
        }
        if case let .installed(invocation) = outcome,
           invocation == mutation.invocation {
            invocationLeases[libraryID] = .active(
                invocation: invocation,
                lease: lease
            )
            return outcome
        }
        invocationLeases[libraryID] = .pending(
            request: request,
            lease: lease
        )
        if case .installed = outcome { return .failed }
        return outcome
    }

    func checkLaunchIdentity(
        _ identity: InvocationLaunchIdentity,
        for authority: InvocationPendingAuthority
    ) async -> InvocationLaunchIdentityAvailabilityOutcome {
        guard let lease = pendingLease(for: authority.request) else {
            return .unavailable
        }
        return await transactions.checkLaunchIdentity(
            identity,
            for: authority,
            holding: lease
        )
    }

    func cancelInvocationReservation(
        _ request: PendingCoachInvocationRequest
    ) async {
        releasePendingLease(for: request)
    }

    func markContextCapacityFailure(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome {
        await markPendingFailure(authority, failure: .coachContextCannotFit)
    }

    func markInterruptedNewSend(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome {
        await markPendingFailure(authority, failure: .coachResponseInterrupted)
    }

    public func recoverPendingAfterTerminalFailure(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingResolutionOutcome {
        await transactions.recoverPendingAfterTerminalFailure(request)
    }

    private func markPendingFailure(
        _ authority: InvocationPendingAuthority,
        failure: PendingUserTurnFailure
    ) async -> InvocationPendingMutationOutcome {
        let lease = pendingLease(for: authority.request)
        if lease == nil, leaseStateOwns(authority.request) { return .failed }
        defer { releasePendingLease(for: authority.request) }
        return await transactions.markPendingFailure(
            authority,
            failure: failure,
            holding: lease
        )
    }

    func rejectNewSend(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome {
        let lease = pendingLease(for: authority.request)
        if lease == nil, leaseStateOwns(authority.request) { return .failed }
        defer { releasePendingLease(for: authority.request) }
        return await transactions.rejectNewSend(authority, holding: lease)
    }

    func abortInstalledNewSend(
        _ invocation: CoachInvocation
    ) async -> InvocationPendingMutationOutcome {
        guard let lease = activeLease(for: invocation) else { return .failed }
        defer { releaseActiveLease(for: invocation) }
        return await transactions.abortInstalledNewSend(
            invocation,
            holding: lease
        )
    }

    func publish(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationOutcome {
        guard let lease = activeLease(for: mutation.invocation) else {
            return .failed
        }
        let outcome = await transactions.publish(mutation, holding: lease)
        if case .committed = outcome {
            releaseActiveLease(for: mutation.invocation)
        }
        return outcome
    }

    public func recoverPublishedInvocation(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationRecoveryOutcome {
        let lease = activeLease(for: mutation.invocation)
        let outcome = await transactions.recoverPublishedInvocation(
            mutation,
            holding: lease
        )
        if lease != nil, case .published = outcome {
            releaseActiveLease(for: mutation.invocation)
        }
        return outcome
    }

    private func pendingLease(
        for request: PendingCoachInvocationRequest
    ) -> PortableInvocationLivenessLease? {
        guard let state = invocationLeases[request.library.libraryID],
              case let .pending(candidate, lease) = state,
              candidate == request
        else { return nil }
        return lease
    }

    private func activeLease(
        for invocation: CoachInvocation
    ) -> PortableInvocationLivenessLease? {
        guard let state = invocationLeases[invocation.libraryID],
              case let .active(candidate, lease) = state,
              candidate == invocation
        else { return nil }
        return lease
    }

    private func leaseStateOwns(
        _ request: PendingCoachInvocationRequest
    ) -> Bool {
        guard let state = invocationLeases[request.library.libraryID] else {
            return false
        }
        switch state {
        case let .pending(candidate, _), let .installing(candidate, _, _):
            return candidate == request
        case let .active(invocation, _):
            return invocation.chatID == request.chatID &&
                invocation.pendingUserTurnID == request.pendingUserTurnID
        }
    }

    private func releasePendingLease(
        for request: PendingCoachInvocationRequest
    ) {
        releaseLease(for: request.library.libraryID) { state in
            guard case let .pending(candidate, _) = state else { return false }
            return candidate == request
        }
    }

    private func releaseActiveLease(for invocation: CoachInvocation) {
        releaseLease(for: invocation.libraryID) { state in
            guard case let .active(candidate, _) = state else { return false }
            return candidate == invocation
        }
    }

    private func releaseLease(
        for libraryID: LibraryID,
        matching expected: (InvocationLeaseState) -> Bool
    ) {
        guard let state = invocationLeases[libraryID], expected(state) else {
            return
        }
        invocationLeases.removeValue(forKey: libraryID)
        state.lease.release()
    }
}

private actor PortablePendingInvocationSession: InvocationPendingPersistenceSession {
    private enum State {
        case pending(InvocationPendingAuthority)
        case transitioning
        case finished
    }

    nonisolated let authority: InvocationPendingAuthority
    private let store: PortableInvocationStore
    private var state: State

    init(
        store: PortableInvocationStore,
        authority: InvocationPendingAuthority
    ) {
        self.store = store
        self.authority = authority
        state = .pending(authority)
    }

    deinit {
        let store = store
        let request = authority.request
        Task { await store.cancelInvocationReservation(request) }
    }

    func revalidate() async -> InvocationPendingResolutionOutcome {
        guard case let .pending(current) = state else { return .unavailable }
        state = .transitioning
        let outcome = await store.revalidatePendingInvocation(current)
        switch outcome {
        case let .eligible(updated):
            state = .pending(updated)
        case .ineligible:
            state = .finished
        case .unavailable:
            state = .pending(current)
        }
        return outcome
    }

    func checkLaunchIdentity(
        _ identity: InvocationLaunchIdentity
    ) async -> InvocationLaunchIdentityAvailabilityOutcome {
        guard case let .pending(current) = state else { return .unavailable }
        state = .transitioning
        let outcome = await store.checkLaunchIdentity(identity, for: current)
        switch outcome {
        case let .stale(aggregate):
            if let aggregate,
               let updated = try? InvocationPendingAuthority(
                   request: current.request,
                   aggregate: aggregate
               )
            {
                state = .pending(updated)
            } else {
                state = .pending(current)
            }
        case .available, .collision, .unavailable:
            state = .pending(current)
        }
        return outcome
    }

    func install(
        _ mutation: InstallCoachInvocationMutation
    ) async -> InvocationSessionInstallOutcome {
        guard case let .pending(current) = state,
              mutation.authority == current
        else { return .failed }
        state = .transitioning
        switch await store.installInvocation(mutation) {
        case let .installed(invocation) where invocation == mutation.invocation:
            state = .finished
            return .installed(
                PortableActiveInvocationSession(
                    store: store,
                    invocation: invocation
                )
            )
        case .installed:
            state = .pending(current)
            return .failed
        case .activeExists:
            state = .pending(current)
            return .blockedByActiveInvocation
        case let .stale(aggregate):
            if let aggregate,
               let updated = try? InvocationPendingAuthority(
                   request: current.request,
                   aggregate: aggregate
               )
            {
                state = .pending(updated)
            } else {
                state = .pending(current)
            }
            return .stale(aggregate)
        case .failed:
            state = .pending(current)
            return .failed
        }
    }

    func terminate(
        _ termination: InvocationPendingTermination
    ) async -> InvocationTerminalPersistenceOutcome {
        guard case let .pending(current) = state else {
            return .recovered(.unavailable)
        }
        state = .finished
        let outcome: InvocationPendingMutationOutcome = switch termination {
        case .contextCapacityFailure:
            await store.markContextCapacityFailure(current)
        case .interrupted:
            await store.markInterruptedNewSend(current)
        case .rejected:
            await store.rejectNewSend(current)
        }
        return await terminalOutcome(outcome, request: current.request)
    }

    func abandon() async {
        guard case let .pending(current) = state else { return }
        state = .finished
        await store.cancelInvocationReservation(current.request)
    }

    private func terminalOutcome(
        _ outcome: InvocationPendingMutationOutcome,
        request: PendingCoachInvocationRequest
    ) async -> InvocationTerminalPersistenceOutcome {
        switch outcome {
        case let .committed(aggregate):
            return .committed(aggregate)
        case let .stale(current):
            return .stale(current)
        case .failed:
            return .recovered(
                await store.recoverPendingAfterTerminalFailure(request)
            )
        }
    }
}

private actor PortableActiveInvocationSession: InvocationActivePersistenceSession {
    private enum State {
        case active
        case transitioning
        case finished
    }

    nonisolated let invocation: CoachInvocation
    private let store: PortableInvocationStore
    private var state: State = .active

    init(store: PortableInvocationStore, invocation: CoachInvocation) {
        self.store = store
        self.invocation = invocation
    }

    deinit {
        let store = store
        let invocation = invocation
        Task { _ = await store.abortInstalledNewSend(invocation) }
    }

    func abort() async -> InvocationTerminalPersistenceOutcome {
        guard case .active = state else { return .recovered(.unavailable) }
        state = .finished
        switch await store.abortInstalledNewSend(invocation) {
        case let .committed(aggregate):
            return .committed(aggregate)
        case let .stale(current):
            return .stale(current)
        case .failed:
            return .recovered(
                await store.recoverPendingAfterTerminalFailure(
                    PendingCoachInvocationRequest(
                        library: LibraryScope(libraryID: invocation.libraryID),
                        chatID: invocation.chatID,
                        pendingUserTurnID: invocation.pendingUserTurnID
                    )
                )
            )
        }
    }

    func publish(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationOutcome {
        guard case .active = state,
              mutation.invocation == invocation
        else { return .failed }
        state = .transitioning
        let outcome = await store.publish(mutation)
        switch outcome {
        case .committed:
            state = .finished
        case .stale, .failed:
            state = .active
        }
        return outcome
    }

    func recoverPublished(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationRecoveryOutcome {
        guard case .active = state,
              mutation.invocation == invocation
        else { return .unavailable }
        state = .transitioning
        let outcome = await store.recoverPublishedInvocation(mutation)
        switch outcome {
        case .published:
            state = .finished
        case .notPublished, .unavailable:
            state = .active
        }
        return outcome
    }
}
