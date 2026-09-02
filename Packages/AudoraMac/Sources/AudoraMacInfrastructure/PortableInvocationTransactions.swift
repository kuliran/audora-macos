@_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
import Foundation

enum PortablePendingPreparationTransactionResult: Sendable {
    case prepared(
        authority: InvocationPendingAuthority,
        lease: PortableInvocationLivenessLease
    )
    case rejected(InvocationPendingPreparationOutcome)
}

enum PortablePendingAcquisitionTransactionResult: Sendable {
    case acquired(
        authority: InvocationPendingAuthority,
        lease: PortableInvocationLivenessLease
    )
    case rejected(InvocationPendingAcquisitionOutcome)
}

enum PortableNextAttemptInstallResult: Equatable, Sendable {
    case installed(CoachInvocation)
    case collision(InvocationLaunchIdentityCollision)
    case stale(ChatAggregate?)
    case failed
}

/// The Invocation persistence module's workflow seam. It owns Library-scoped
/// transaction routing, commit-uncertainty reconciliation, and the mapping from
/// confined filesystem outcomes into Invocation port outcomes. The actor above
/// this seam owns only live lease-state transitions; the shared Chat persistence
/// authority below it retains descriptors, locks, and atomic file operations.
struct PortableInvocationTransactions: Sendable {
    private let persistence: PortableChatPersistence
    private let workspace: PortableLibraryWorkspace
    private let chats: PortableChatStore

    init(
        persistence: PortableChatPersistence,
        workspace: PortableLibraryWorkspace
    ) {
        self.persistence = persistence
        self.workspace = workspace
        chats = PortableChatStore(persistence: persistence, workspace: workspace)
    }

    func prepareNewPendingInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> PortablePendingPreparationTransactionResult {
        let library = request.library
        let result: ActiveLibraryOperationResult<
            PortablePendingPreparationTransactionResult
        > = await workspace.performActiveReadWriteOperation(in: library) { root in
            do {
                switch try persistence.prepareNewPendingInvocation(
                    request,
                    at: root,
                    in: library
                ) {
                case let .prepared(aggregate, lease):
                    let pendingRequest = PendingCoachInvocationRequest(
                        library: library,
                        chatID: request.chatID,
                        pendingUserTurnID: request.pendingUserTurn.id
                    )
                    do {
                        return .prepared(
                            authority: try InvocationPendingAuthority(
                                request: pendingRequest,
                                aggregate: aggregate
                            ),
                            lease: lease
                        )
                    } catch {
                        lease.release()
                        return .rejected(.unavailable)
                    }
                case let .stale(current):
                    return .rejected(.stale(current))
                case let .frozen(frozen):
                    return .rejected(.frozen(frozen))
                case .activeExists:
                    return .rejected(.activeExists)
                }
            } catch PortableChatPersistenceError.readOnlyLibrary {
                return .rejected(.readOnlyLibrary)
            } catch {
                return .rejected(.unavailable)
            }
        }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly: .rejected(.readOnlyLibrary)
        case .unavailable: .rejected(.unavailable)
        }
    }

    func acquirePendingInvocation(
        _ request: PendingCoachInvocationRequest
    ) async -> PortablePendingAcquisitionTransactionResult {
        let library = request.library
        let result: ActiveLibraryOperationResult<
            PortablePendingAcquisitionTransactionResult
        > = await workspace.performActiveReadWriteOperation(in: library) { root in
            do {
                guard let lease = try persistence.acquireInvocationLivenessLease(
                    at: root,
                    in: library,
                    for: request
                ) else {
                    return .rejected(.activeExists)
                }
                do {
                    try persistence.reconcileInterruptedInvocations(
                        at: root,
                        in: library,
                        holding: lease
                    )
                    guard try !persistence.hasActiveInvocation(
                        at: root,
                        in: library,
                        holding: lease
                    ) else {
                        lease.release()
                        return .rejected(.activeExists)
                    }
                    switch try persistence.load(
                        request.chatID,
                        at: root,
                        in: library
                    ) {
                    case let .readWrite(aggregate):
                        do {
                            return .acquired(
                                authority: try InvocationPendingAuthority(
                                    request: request,
                                    aggregate: aggregate
                                ),
                                lease: lease
                            )
                        } catch {
                            lease.release()
                            return .rejected(.ineligible(aggregate))
                        }
                    case .frozen:
                        lease.release()
                        return .rejected(.ineligible(nil))
                    }
                } catch {
                    lease.release()
                    return .rejected(.unavailable)
                }
            } catch {
                return .rejected(.unavailable)
            }
        }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly, .unavailable: .rejected(.unavailable)
        }
    }

    func revalidatePendingInvocation(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingResolutionOutcome {
        let request = authority.request
        let result: ActiveLibraryOperationResult<InvocationPendingResolutionOutcome> =
            await workspace.performActiveReadWriteOperation(in: request.library) { root in
                do {
                    switch try persistence.load(
                        request.chatID,
                        at: root,
                        in: request.library
                    ) {
                    case let .readWrite(aggregate):
                        do {
                            return .eligible(
                                try InvocationPendingAuthority(
                                    request: request,
                                    aggregate: aggregate
                                )
                            )
                        } catch {
                            return .ineligible(aggregate)
                        }
                    case .frozen:
                        return .ineligible(nil)
                    }
                } catch PortableChatPersistenceError.chatMissing {
                    return .ineligible(nil)
                } catch {
                    return .unavailable
                }
            }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly: .ineligible(nil)
        case .unavailable: .unavailable
        }
    }

    func installInvocation(
        _ mutation: InstallCoachInvocationMutation,
        holding lease: PortableInvocationLivenessLease
    ) async -> InvocationInstallOutcome {
        let result: ActiveLibraryOperationResult<InvocationInstallOutcome> =
            await workspace.performActiveReadWriteOperation(
                in: mutation.authority.request.library
            ) { root in
                do {
                    return try persistence.installInvocation(
                        mutation,
                        at: root,
                        holding: lease
                    )
                } catch {
                    if let installed = try? persistence.reconcileInstalledInvocation(
                        mutation,
                        at: root,
                        holding: lease
                    ) {
                        return .installed(installed)
                    }
                    return .failed
                }
            }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly, .unavailable: .failed
        }
    }

    func installNextAttempt(
        _ mutation: InstallNextCoachProviderAttemptMutation,
        holding lease: PortableInvocationLivenessLease
    ) async -> PortableNextAttemptInstallResult {
        let scope = LibraryScope(libraryID: mutation.base.libraryID)
        let result: ActiveLibraryOperationResult<PortableNextAttemptInstallResult> =
            await workspace.performActiveReadWriteOperation(in: scope) { root in
                do {
                    return try persistence.installNextAttempt(
                        mutation,
                        at: root,
                        in: scope,
                        holding: lease
                    )
                } catch {
                    if let installed = try? persistence.reconcileInstalledNextAttempt(
                        mutation,
                        at: root,
                        in: scope,
                        holding: lease
                    ) {
                        return .installed(installed)
                    }
                    return .failed
                }
            }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly, .unavailable: .failed
        }
    }

    func checkLaunchIdentity(
        _ identity: InvocationLaunchIdentity,
        for authority: InvocationPendingAuthority,
        holding lease: PortableInvocationLivenessLease
    ) async -> InvocationLaunchIdentityAvailabilityOutcome {
        let result: ActiveLibraryOperationResult<
            InvocationLaunchIdentityAvailabilityOutcome
        > = await workspace.performActiveReadWriteOperation(
            in: authority.request.library
        ) { root in
            do {
                return try persistence.checkLaunchIdentity(
                    identity,
                    for: authority,
                    at: root,
                    holding: lease
                )
            } catch {
                return .unavailable
            }
        }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly, .unavailable: .unavailable
        }
    }

    func recoverPendingAfterTerminalFailure(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingResolutionOutcome {
        let result: ActiveLibraryOperationResult<InvocationPendingResolutionOutcome> =
            await workspace.performActiveReadWriteOperation(in: request.library) { root in
                do {
                    try persistence.reconcileInterruptedInvocationsIfUnowned(
                        at: root,
                        in: request.library
                    )
                    switch try persistence.load(
                        request.chatID,
                        at: root,
                        in: request.library
                    ) {
                    case let .readWrite(aggregate):
                        do {
                            return .eligible(
                                try InvocationPendingAuthority(
                                    request: request,
                                    aggregate: aggregate
                                )
                            )
                        } catch {
                            return .ineligible(aggregate)
                        }
                    case .frozen:
                        return .ineligible(nil)
                    }
                } catch PortableChatPersistenceError.chatMissing {
                    return .ineligible(nil)
                } catch {
                    return .unavailable
                }
            }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly, .unavailable: .unavailable
        }
    }

    func markPendingFailure(
        _ authority: InvocationPendingAuthority,
        failure: PendingUserTurnFailure,
        holding lease: PortableInvocationLivenessLease?
    ) async -> InvocationPendingMutationOutcome {
        let mutation: ReplacePendingUserTurnMutation
        do {
            mutation = try ReplacePendingUserTurnMutation(
                library: authority.request.library,
                chatID: authority.request.chatID,
                base: authority.pendingUserTurn,
                replacement: authority.pendingUserTurn.replacingFailure(failure)
            )
        } catch {
            return .failed
        }
        if let lease {
            return await performPendingMutation(
                in: authority.request.library,
                operation: { root in
                    try persistence.replacePendingUserTurn(
                        mutation,
                        at: root,
                        holding: lease
                    )
                },
                reconcile: { root in
                    try persistence.reconcileCommittedPendingReplacement(
                        mutation,
                        at: root,
                        holding: lease
                    )
                }
            )
        }
        return invocationMutationOutcome(await chats.replacePendingUserTurn(mutation))
    }

    func rejectNewSend(
        _ authority: InvocationPendingAuthority,
        holding lease: PortableInvocationLivenessLease?
    ) async -> InvocationPendingMutationOutcome {
        let mutation = DiscardPendingUserTurnMutation(
            library: authority.request.library,
            chatID: authority.request.chatID,
            pendingUserTurn: authority.pendingUserTurn
        )
        if let lease {
            return await performPendingMutation(
                in: authority.request.library,
                operation: { root in
                    try persistence.discardPendingUserTurn(
                        mutation,
                        at: root,
                        holding: lease
                    )
                },
                reconcile: { root in
                    try persistence.reconcileCommittedPendingDiscard(
                        mutation,
                        at: root,
                        holding: lease
                    )
                }
            )
        }
        return invocationMutationOutcome(await chats.discardPendingUserTurn(mutation))
    }

    func abortInstalledNewSend(
        _ invocation: CoachInvocation,
        failure: PendingUserTurnFailure = .coachResponseInterrupted,
        holding lease: PortableInvocationLivenessLease
    ) async -> InvocationPendingMutationOutcome {
        let scope = LibraryScope(libraryID: invocation.libraryID)
        let result: ActiveLibraryOperationResult<InvocationPendingMutationOutcome> =
            await workspace.performActiveReadWriteOperation(in: scope) { root in
                do {
                    switch try persistence.abortInstalledNewSend(
                        invocation,
                        failure: failure,
                        at: root,
                        in: scope,
                        holding: lease
                    ) {
                    case let .committed(aggregate): return .committed(aggregate)
                    case let .stale(aggregate): return .stale(aggregate)
                    case .frozen: return .failed
                    }
                } catch {
                    return .failed
                }
            }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly, .unavailable: .failed
        }
    }

    func publish(
        _ mutation: PublishCoachInvocationMutation,
        holding lease: PortableInvocationLivenessLease
    ) async -> InvocationPublicationOutcome {
        let scope = LibraryScope(libraryID: mutation.invocation.libraryID)
        let result: ActiveLibraryOperationResult<InvocationPublicationOutcome> =
            await workspace.performActiveReadWriteOperation(in: scope) { root in
                do {
                    switch try persistence.publishInvocation(
                        mutation,
                        at: root,
                        in: scope,
                        holding: lease
                    ) {
                    case let .committed(aggregate): return .committed(aggregate)
                    case let .stale(aggregate): return .stale(aggregate)
                    case .frozen: return .failed
                    }
                } catch {
                    if let committed = try? persistence
                        .reconcileCommittedInvocationPublication(
                            mutation,
                            at: root,
                            in: scope,
                            holding: lease
                        )
                    {
                        return .committed(committed)
                    }
                    return .failed
                }
            }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly, .unavailable: .failed
        }
    }

    func recoverPublishedInvocation(
        _ mutation: PublishCoachInvocationMutation,
        holding lease: PortableInvocationLivenessLease?
    ) async -> InvocationPublicationRecoveryOutcome {
        let scope = LibraryScope(libraryID: mutation.invocation.libraryID)
        let result: ActiveLibraryOperationResult<InvocationPublicationRecoveryOutcome> =
            await workspace.performActiveReadWriteOperation(in: scope) { root in
                do {
                    if let lease {
                        if let published = try persistence
                            .reconcileCommittedInvocationPublication(
                                mutation,
                                at: root,
                                in: scope,
                                holding: lease
                            )
                        {
                            return .published(published)
                        }
                        return .notPublished
                    }
                    return switch try persistence
                        .reconcileCommittedInvocationPublicationIfUnowned(
                            mutation,
                            at: root,
                            in: scope
                        ) {
                    case let .published(aggregate): .published(aggregate)
                    case .notPublished: .notPublished
                    case .owned: .unavailable
                    }
                } catch {
                    return .unavailable
                }
            }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly, .unavailable: .unavailable
        }
    }

    private func invocationMutationOutcome(
        _ outcome: ChatMutationOutcome
    ) -> InvocationPendingMutationOutcome {
        switch outcome {
        case let .committed(aggregate): .committed(aggregate)
        case let .stale(aggregate): .stale(aggregate)
        case .collision, .creationAuthorityChanged, .attachmentUnavailable,
             .profileStatementGenerationChanged, .frozen, .readOnlyLibrary,
             .failed: .failed
        }
    }

    private func performPendingMutation(
        in library: LibraryScope,
        operation: @Sendable (URL) throws -> PortableChatMutationResult,
        reconcile: @Sendable (URL) throws -> ChatAggregate?
    ) async -> InvocationPendingMutationOutcome {
        let result: ActiveLibraryOperationResult<InvocationPendingMutationOutcome> =
            await workspace.performActiveReadWriteOperation(in: library) { root in
                do {
                    switch try operation(root) {
                    case let .committed(aggregate): return .committed(aggregate)
                    case let .stale(aggregate): return .stale(aggregate)
                    case .frozen: return .failed
                    }
                } catch {
                    if let committed = try? reconcile(root) {
                        return .committed(committed)
                    }
                    return .failed
                }
            }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly, .unavailable: .failed
        }
    }
}
