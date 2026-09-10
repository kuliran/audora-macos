@_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain

@_spi(InvocationInfrastructure)
public actor PortableInvocationStore: InvocationPersistencePort {
    private enum ProfileReconsiderationReservationDisposition: Equatable {
        case provisional
        case retained
    }

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
            processingAggregate: ChatAggregate,
            lease: PortableInvocationLivenessLease
        )
        case profileReconsiderationPending(
            authority: InvocationProfileReconsiderationAuthority,
            disposition: ProfileReconsiderationReservationDisposition,
            lease: PortableInvocationLivenessLease
        )
        case profileReconsiderationInstalling(
            authority: InvocationProfileReconsiderationAuthority,
            disposition: ProfileReconsiderationReservationDisposition,
            invocation: CoachInvocation,
            lease: PortableInvocationLivenessLease
        )
        case profileReconsiderationActive(
            invocation: CoachInvocation,
            processingAggregate: ChatAggregate,
            reconsideration: ProfileReconsideration,
            basis: ProfileReconsiderationBasis,
            lease: PortableInvocationLivenessLease
        )

        var lease: PortableInvocationLivenessLease {
            switch self {
            case let .pending(_, lease),
                 let .installing(_, _, lease),
                 let .active(_, _, lease),
                 let .profileReconsiderationPending(_, _, lease),
                 let .profileReconsiderationInstalling(_, _, _, lease),
                 let .profileReconsiderationActive(_, _, _, _, lease):
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

    public func openNewProfileReconsiderationInvocation(
        _ request: NewProfileReconsiderationInvocationRequest
    ) async -> InvocationProfileReconsiderationSessionPreparationOutcome {
        let libraryID = request.library.libraryID
        guard invocationLeases[libraryID] == nil else {
            return .blockedByActiveInvocation
        }
        switch await transactions.prepareNewProfileReconsiderationInvocation(
            request
        ) {
        case let .prepared(authority, lease):
            guard invocationLeases[libraryID] == nil else {
                lease.release()
                return .blockedByActiveInvocation
            }
            invocationLeases[libraryID] = .profileReconsiderationPending(
                authority: authority,
                disposition: .provisional,
                lease: lease
            )
            return .opened(
                PortableProfileReconsiderationInvocationSession(
                    store: self,
                    authority: authority
                )
            )
        case let .rejected(outcome):
            return outcome
        }
    }

    public func openRetryProfileReconsiderationInvocation(
        _ request: RetryProfileReconsiderationInvocationRequest
    ) async -> InvocationProfileReconsiderationSessionAcquisitionOutcome {
        await openExistingProfileReconsiderationInvocation(
            libraryID: request.library.libraryID
        ) {
            await transactions.acquireRetryProfileReconsiderationInvocation(
                request
            )
        }
    }

    public func openOperationalProfileReconsiderationInvocation(
        _ request: ProfileReconsiderationInvocationRequest
    ) async -> InvocationProfileReconsiderationSessionAcquisitionOutcome {
        await openExistingProfileReconsiderationInvocation(
            libraryID: request.library.libraryID
        ) {
            await transactions
                .acquireOperationalProfileReconsiderationInvocation(request)
        }
    }

    private func openExistingProfileReconsiderationInvocation(
        libraryID: LibraryID,
        acquire: () async ->
            PortableProfileReconsiderationAcquisitionTransactionResult
    ) async -> InvocationProfileReconsiderationSessionAcquisitionOutcome {
        guard invocationLeases[libraryID] == nil else {
            return .blockedByActiveInvocation
        }
        switch await acquire() {
        case let .acquired(authority, lease):
            guard invocationLeases[libraryID] == nil else {
                lease.release()
                return .blockedByActiveInvocation
            }
            invocationLeases[libraryID] = .profileReconsiderationPending(
                authority: authority,
                disposition: .retained,
                lease: lease
            )
            return .opened(
                PortableProfileReconsiderationInvocationSession(
                    store: self,
                    authority: authority
                )
            )
        case let .rejected(outcome):
            return outcome
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
           invocation.hasSameDurableProjection(as: mutation.invocation) {
            invocationLeases[libraryID] = .active(
                invocation: mutation.invocation,
                processingAggregate: mutation.processingAggregate,
                lease: lease
            )
            return .installed(mutation.invocation)
        }
        invocationLeases[libraryID] = .pending(
            request: request,
            lease: lease
        )
        if case .installed = outcome { return .failed }
        return outcome
    }

    func installNextAttempt(
        _ mutation: InstallNextCoachProviderAttemptMutation
    ) async -> InvocationNextAttemptInstallOutcome {
        let base = mutation.base
        let libraryID = base.libraryID
        guard let lease = activeLease(for: base) else { return .failed }
        let outcome = await transactions.installNextAttempt(
            mutation,
            holding: lease
        )
        guard let state = invocationLeases[libraryID],
              case let .active(expected, processingAggregate, installedLease) = state,
              expected == base,
              installedLease === lease
        else { return .failed }
        switch outcome {
        case let .installed(replacement)
            where replacement.hasSameDurableProjection(as: mutation.replacement):
            invocationLeases[libraryID] = .active(
                invocation: mutation.replacement,
                processingAggregate: processingAggregate,
                lease: lease
            )
            return .installed(PortableActiveInvocationSession(
                store: self,
                invocation: mutation.replacement,
                processingAggregate: processingAggregate
            ))
        case .installed:
            return .failed
        case let .collision(collision):
            return .collision(collision)
        case let .stale(current):
            return .stale(current)
        case .failed:
            return .failed
        }
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

    func revalidateProfileReconsiderationInvocation(
        _ authority: InvocationProfileReconsiderationAuthority
    ) async -> InvocationProfileReconsiderationResolutionOutcome {
        let request = authority.request
        guard let reservation = profileReconsiderationPendingLease(
            for: request
        ), reservation.authority == authority else { return .unavailable }
        let outcome = await transactions
            .revalidateProfileReconsiderationInvocation(
                authority,
                holding: reservation.lease
            )
        guard let current = profileReconsiderationPendingLease(for: request),
              current.authority == authority,
              current.disposition == reservation.disposition,
              current.lease === reservation.lease
        else { return .unavailable }
        switch outcome {
        case let .eligible(updated):
            invocationLeases[request.library.libraryID] =
                .profileReconsiderationPending(
                    authority: updated,
                    disposition: reservation.disposition,
                    lease: reservation.lease
                )
        case .ineligible:
            releaseProfileReconsiderationPendingLease(for: request)
        case .unavailable:
            break
        }
        return outcome
    }

    func checkProfileReconsiderationLaunchIdentity(
        _ identity: InvocationProfileReconsiderationLaunchIdentity,
        for authority: InvocationProfileReconsiderationAuthority
    ) async -> InvocationLaunchIdentityAvailabilityOutcome {
        guard let reservation = profileReconsiderationPendingLease(
            for: authority.request
        ), reservation.authority == authority else { return .unavailable }
        return await transactions.checkProfileReconsiderationLaunchIdentity(
            identity,
            for: authority,
            holding: reservation.lease
        )
    }

    func installProfileReconsiderationInvocation(
        _ mutation: InstallProfileReconsiderationInvocationMutation
    ) async -> InvocationInstallOutcome {
        let request = mutation.authority.request
        let libraryID = request.library.libraryID
        guard let reservation = profileReconsiderationPendingLease(
            for: request
        ), reservation.authority == mutation.authority else { return .failed }
        invocationLeases[libraryID] = .profileReconsiderationInstalling(
            authority: mutation.authority,
            disposition: reservation.disposition,
            invocation: mutation.invocation,
            lease: reservation.lease
        )
        let outcome = await transactions.installProfileReconsiderationInvocation(
            mutation,
            holding: reservation.lease
        )
        guard let state = invocationLeases[libraryID],
              case let .profileReconsiderationInstalling(
                  authority,
                  disposition,
                  expected,
                  installedLease
              ) = state,
              authority == mutation.authority,
              disposition == reservation.disposition,
              expected == mutation.invocation,
              installedLease === reservation.lease
        else {
            reservation.lease.release()
            return .failed
        }
        if case let .installed(invocation) = outcome,
           invocation.hasSameDurableProjection(as: mutation.invocation) {
            invocationLeases[libraryID] = .profileReconsiderationActive(
                invocation: mutation.invocation,
                processingAggregate: mutation.processingAggregate,
                reconsideration: mutation.processingReconsideration,
                basis: mutation.authority.basis,
                lease: reservation.lease
            )
            return .installed(mutation.invocation)
        }
        invocationLeases[libraryID] = .profileReconsiderationPending(
            authority: mutation.authority,
            disposition: reservation.disposition,
            lease: reservation.lease
        )
        if case .installed = outcome { return .failed }
        return outcome
    }

    func installNextProfileReconsiderationAttempt(
        _ mutation: InstallNextProfileReconsiderationAttemptMutation
    ) async -> InvocationProfileReconsiderationNextAttemptInstallOutcome {
        let libraryID = mutation.base.libraryID
        guard let active = profileReconsiderationActiveLease(
            for: mutation.base
        ) else { return .failed }
        let outcome = await transactions.installNextProfileReconsiderationAttempt(
            mutation,
            holding: active.lease
        )
        guard let current = profileReconsiderationActiveLease(
            for: mutation.base
        ), current.lease === active.lease else { return .failed }
        switch outcome {
        case let .installed(replacement)
            where replacement.hasSameDurableProjection(as: mutation.replacement):
            invocationLeases[libraryID] = .profileReconsiderationActive(
                invocation: mutation.replacement,
                processingAggregate: active.processingAggregate,
                reconsideration: active.reconsideration,
                basis: active.basis,
                lease: active.lease
            )
            return .installed(
                PortableProfileReconsiderationActiveInvocationSession(
                    store: self,
                    invocation: mutation.replacement,
                    processingAggregate: active.processingAggregate,
                    reconsideration: active.reconsideration,
                    basis: active.basis
                )
            )
        case .installed:
            return .failed
        case let .collision(collision):
            return .collision(collision)
        case let .stale(current):
            return .stale(current)
        case .failed:
            return .failed
        }
    }

    func terminateProfileReconsiderationReservation(
        _ authority: InvocationProfileReconsiderationAuthority,
        termination: InvocationProfileReconsiderationTermination
    ) async -> InvocationProfileReconsiderationTerminalPersistenceOutcome {
        let request = authority.request
        guard let reservation = profileReconsiderationPendingLease(
            for: request
        ), reservation.authority == authority else {
            return .recovered(.unavailable)
        }
        let outcome: InvocationPendingMutationOutcome
        switch termination {
        case .rejected where reservation.disposition == .retained:
            outcome = .committed(authority.aggregate)
        case .rejected:
            outcome = await transactions.discardProvisionalProfileReconsideration(
                authority,
                holding: reservation.lease
            )
        case let .failed(failure):
            outcome = await transactions.markProfileReconsiderationFailure(
                authority,
                failure: failure,
                holding: reservation.lease
            )
        }
        releaseProfileReconsiderationPendingLease(for: request)
        return await profileReconsiderationTerminalOutcome(
            outcome,
            request: request
        )
    }

    func abandonProfileReconsiderationReservation(
        _ request: ProfileReconsiderationInvocationRequest
    ) async {
        guard let reservation = profileReconsiderationPendingLease(
            for: request
        ) else { return }
        if reservation.disposition == .provisional {
            _ = await transactions.discardProvisionalProfileReconsideration(
                reservation.authority,
                holding: reservation.lease
            )
        }
        releaseProfileReconsiderationPendingLease(for: request)
    }

    func abortInstalledProfileReconsideration(
        _ invocation: CoachInvocation,
        failure: PendingUserTurnFailure
    ) async -> InvocationProfileReconsiderationTerminalPersistenceOutcome {
        guard let active = profileReconsiderationActiveLease(for: invocation)
        else { return .recovered(.unavailable) }
        let request = profileReconsiderationRequest(for: invocation)
        guard let request else { return .recovered(.unavailable) }
        let outcome = await transactions.abortInstalledProfileReconsideration(
            invocation,
            failure: failure,
            holding: active.lease
        )
        releaseProfileReconsiderationActiveLease(for: invocation)
        return await profileReconsiderationTerminalOutcome(
            outcome,
            request: request
        )
    }

    public func recoverProfileReconsiderationAfterTerminalFailure(
        _ request: ProfileReconsiderationInvocationRequest
    ) async -> InvocationProfileReconsiderationResolutionOutcome {
        await transactions.recoverProfileReconsiderationAfterTerminalFailure(
            request
        )
    }

    func publishProfileReconsideration(
        _ mutation: PublishProfileReconsiderationInvocationMutation
    ) async -> InvocationPublicationOutcome {
        guard let active = profileReconsiderationActiveLease(
            for: mutation.invocation
        ), active.reconsideration == mutation.reconsideration,
            active.basis == mutation.basis
        else { return .failed }
        let outcome = await transactions.publishProfileReconsideration(
            mutation,
            holding: active.lease
        )
        if case .committed = outcome {
            releaseProfileReconsiderationActiveLease(for: mutation.invocation)
        }
        return outcome
    }

    public func recoverPublishedProfileReconsideration(
        _ mutation: PublishProfileReconsiderationInvocationMutation
    ) async -> InvocationPublicationRecoveryOutcome {
        let active = profileReconsiderationActiveLease(
            for: mutation.invocation
        )
        let outcome = await transactions.recoverPublishedProfileReconsideration(
            mutation,
            holding: active?.lease
        )
        if active != nil, case .published = outcome {
            releaseProfileReconsiderationActiveLease(for: mutation.invocation)
        }
        return outcome
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
        _ invocation: CoachInvocation,
        failure: PendingUserTurnFailure = .coachResponseInterrupted
    ) async -> InvocationPendingMutationOutcome {
        guard let lease = activeLease(for: invocation) else { return .failed }
        defer { releaseActiveLease(for: invocation) }
        return await transactions.abortInstalledNewSend(
            invocation,
            failure: failure,
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

    private func profileReconsiderationPendingLease(
        for request: ProfileReconsiderationInvocationRequest
    ) -> (
        authority: InvocationProfileReconsiderationAuthority,
        disposition: ProfileReconsiderationReservationDisposition,
        lease: PortableInvocationLivenessLease
    )? {
        guard let state = invocationLeases[request.library.libraryID],
              case let .profileReconsiderationPending(
                  authority,
                  disposition,
                  lease
              ) = state,
              authority.request == request
        else { return nil }
        return (authority, disposition, lease)
    }

    private func profileReconsiderationActiveLease(
        for invocation: CoachInvocation
    ) -> (
        processingAggregate: ChatAggregate,
        reconsideration: ProfileReconsideration,
        basis: ProfileReconsiderationBasis,
        lease: PortableInvocationLivenessLease
    )? {
        guard let state = invocationLeases[invocation.libraryID],
              case let .profileReconsiderationActive(
                  candidate,
                  processingAggregate,
                  reconsideration,
                  basis,
                  lease
              ) = state,
              candidate == invocation
        else { return nil }
        return (processingAggregate, reconsideration, basis, lease)
    }

    private func activeLease(
        for invocation: CoachInvocation
    ) -> PortableInvocationLivenessLease? {
        guard let state = invocationLeases[invocation.libraryID],
              case let .active(candidate, _, lease) = state,
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
        case let .active(invocation, _, _):
            return invocation.chatID == request.chatID &&
                invocation.pendingUserTurnID == request.pendingUserTurnID
        case .profileReconsiderationPending,
             .profileReconsiderationInstalling,
             .profileReconsiderationActive:
            return false
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
            guard case let .active(candidate, _, _) = state else { return false }
            return candidate == invocation
        }
    }

    private func releaseProfileReconsiderationPendingLease(
        for request: ProfileReconsiderationInvocationRequest
    ) {
        releaseLease(for: request.library.libraryID) { state in
            guard case let .profileReconsiderationPending(authority, _, _) =
                state
            else { return false }
            return authority.request == request
        }
    }

    private func releaseProfileReconsiderationActiveLease(
        for invocation: CoachInvocation
    ) {
        releaseLease(for: invocation.libraryID) { state in
            guard case let .profileReconsiderationActive(candidate, _, _, _, _) =
                state
            else { return false }
            return candidate == invocation
        }
    }

    private func profileReconsiderationRequest(
        for invocation: CoachInvocation
    ) -> ProfileReconsiderationInvocationRequest? {
        guard case let .reconsiderProfileChange(source, result) =
            invocation.intent
        else { return nil }
        return ProfileReconsiderationInvocationRequest(
            library: LibraryScope(libraryID: invocation.libraryID),
            chatID: invocation.chatID,
            sourceEffectIdentity: source,
            resultResponsePositionID: result
        )
    }

    private func profileReconsiderationTerminalOutcome(
        _ outcome: InvocationPendingMutationOutcome,
        request: ProfileReconsiderationInvocationRequest
    ) async -> InvocationProfileReconsiderationTerminalPersistenceOutcome {
        switch outcome {
        case let .committed(aggregate):
            return .committed(aggregate)
        case let .stale(current):
            return .stale(current)
        case .failed:
            return .recovered(
                await recoverProfileReconsiderationAfterTerminalFailure(request)
            )
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
                    invocation: invocation,
                    processingAggregate: mutation.processingAggregate
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
    nonisolated let processingAggregate: ChatAggregate
    private let store: PortableInvocationStore
    private var state: State = .active

    init(
        store: PortableInvocationStore,
        invocation: CoachInvocation,
        processingAggregate: ChatAggregate
    ) {
        self.store = store
        self.invocation = invocation
        self.processingAggregate = processingAggregate
    }

    deinit {
        let store = store
        let invocation = invocation
        Task { _ = await store.abortInstalledNewSend(invocation) }
    }

    func installNextAttempt(
        _ mutation: InstallNextCoachProviderAttemptMutation
    ) async -> InvocationNextAttemptInstallOutcome {
        guard case .active = state,
              mutation.base == invocation
        else { return .failed }
        state = .transitioning
        let outcome = await store.installNextAttempt(mutation)
        switch outcome {
        case .installed:
            state = .finished
        case .collision, .stale, .failed:
            state = .active
        }
        return outcome
    }

    func abort(
        failure: PendingUserTurnFailure
    ) async -> InvocationTerminalPersistenceOutcome {
        guard case .active = state else { return .recovered(.unavailable) }
        state = .finished
        switch await store.abortInstalledNewSend(invocation, failure: failure) {
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

private actor PortableProfileReconsiderationInvocationSession:
    InvocationProfileReconsiderationPersistenceSession
{
    private enum State {
        case pending(InvocationProfileReconsiderationAuthority)
        case transitioning
        case finished
    }

    nonisolated let authority: InvocationProfileReconsiderationAuthority
    private let store: PortableInvocationStore
    private var state: State

    init(
        store: PortableInvocationStore,
        authority: InvocationProfileReconsiderationAuthority
    ) {
        self.store = store
        self.authority = authority
        state = .pending(authority)
    }

    deinit {
        let store = store
        let request = authority.request
        Task { await store.abandonProfileReconsiderationReservation(request) }
    }

    func revalidate()
        async -> InvocationProfileReconsiderationResolutionOutcome
    {
        guard case let .pending(current) = state else { return .unavailable }
        state = .transitioning
        let outcome = await store.revalidateProfileReconsiderationInvocation(
            current
        )
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
        _ identity: InvocationProfileReconsiderationLaunchIdentity
    ) async -> InvocationLaunchIdentityAvailabilityOutcome {
        guard case let .pending(current) = state else { return .unavailable }
        state = .transitioning
        let outcome = await store.checkProfileReconsiderationLaunchIdentity(
            identity,
            for: current
        )
        state = .pending(current)
        return outcome
    }

    func install(
        _ mutation: InstallProfileReconsiderationInvocationMutation
    ) async -> InvocationProfileReconsiderationSessionInstallOutcome {
        guard case let .pending(current) = state,
              mutation.authority == current
        else { return .failed }
        state = .transitioning
        switch await store.installProfileReconsiderationInvocation(mutation) {
        case let .installed(invocation)
            where invocation.hasSameDurableProjection(as: mutation.invocation):
            state = .finished
            return .installed(
                PortableProfileReconsiderationActiveInvocationSession(
                    store: store,
                    invocation: mutation.invocation,
                    processingAggregate: mutation.processingAggregate,
                    reconsideration: mutation.processingReconsideration,
                    basis: mutation.authority.basis
                )
            )
        case .installed:
            state = .pending(current)
            return .failed
        case .activeExists:
            state = .pending(current)
            return .blockedByActiveInvocation
        case let .stale(aggregate):
            state = .pending(current)
            return .stale(aggregate)
        case .failed:
            state = .pending(current)
            return .failed
        }
    }

    func terminate(
        _ termination: InvocationProfileReconsiderationTermination
    ) async -> InvocationProfileReconsiderationTerminalPersistenceOutcome {
        guard case let .pending(current) = state else {
            return .recovered(.unavailable)
        }
        state = .finished
        return await store.terminateProfileReconsiderationReservation(
            current,
            termination: termination
        )
    }

    func abandon() async {
        guard case .pending = state else { return }
        state = .finished
        await store.abandonProfileReconsiderationReservation(authority.request)
    }
}

private actor PortableProfileReconsiderationActiveInvocationSession:
    InvocationProfileReconsiderationActivePersistenceSession
{
    private enum State {
        case active
        case transitioning
        case finished
    }

    nonisolated let invocation: CoachInvocation
    nonisolated let processingAggregate: ChatAggregate
    nonisolated let reconsideration: ProfileReconsideration
    nonisolated let basis: ProfileReconsiderationBasis
    private let store: PortableInvocationStore
    private var state: State = .active

    init(
        store: PortableInvocationStore,
        invocation: CoachInvocation,
        processingAggregate: ChatAggregate,
        reconsideration: ProfileReconsideration,
        basis: ProfileReconsiderationBasis
    ) {
        self.store = store
        self.invocation = invocation
        self.processingAggregate = processingAggregate
        self.reconsideration = reconsideration
        self.basis = basis
    }

    deinit {
        let store = store
        let invocation = invocation
        Task {
            _ = await store.abortInstalledProfileReconsideration(
                invocation,
                failure: .coachResponseInterrupted
            )
        }
    }

    func installNextAttempt(
        _ mutation: InstallNextProfileReconsiderationAttemptMutation
    ) async -> InvocationProfileReconsiderationNextAttemptInstallOutcome {
        guard case .active = state,
              mutation.base == invocation
        else { return .failed }
        state = .transitioning
        let outcome = await store.installNextProfileReconsiderationAttempt(
            mutation
        )
        switch outcome {
        case .installed:
            state = .finished
        case .collision, .stale, .failed:
            state = .active
        }
        return outcome
    }

    func abort(
        failure: PendingUserTurnFailure
    ) async -> InvocationProfileReconsiderationTerminalPersistenceOutcome {
        guard case .active = state else { return .recovered(.unavailable) }
        state = .finished
        return await store.abortInstalledProfileReconsideration(
            invocation,
            failure: failure
        )
    }

    func publish(
        _ mutation: PublishProfileReconsiderationInvocationMutation
    ) async -> InvocationPublicationOutcome {
        guard case .active = state,
              mutation.invocation == invocation,
              mutation.reconsideration == reconsideration,
              mutation.basis == basis
        else { return .failed }
        state = .transitioning
        let outcome = await store.publishProfileReconsideration(mutation)
        switch outcome {
        case .committed:
            state = .finished
        case .stale, .failed:
            state = .active
        }
        return outcome
    }

    func recoverPublished(
        _ mutation: PublishProfileReconsiderationInvocationMutation
    ) async -> InvocationPublicationRecoveryOutcome {
        guard case .active = state,
              mutation.invocation == invocation,
              mutation.reconsideration == reconsideration,
              mutation.basis == basis
        else { return .unavailable }
        state = .transitioning
        let outcome = await store.recoverPublishedProfileReconsideration(
            mutation
        )
        switch outcome {
        case .published:
            state = .finished
        case .notPublished, .unavailable:
            state = .active
        }
        return outcome
    }
}
