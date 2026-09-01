import AudoraDomain

private actor CancellationOwnedNewChatOperation<Outcome: Sendable> {
    private enum State {
        case pending
        case completed(Outcome)
        case cancelled
        case claimed
    }

    private var state: State = .pending
    private var child: Task<Void, Never>?
    private var lease: CoachContextAuthorityLease?
    private var waiters: [CheckedContinuation<Outcome?, Never>] = []

    func start(
        _ operation: @escaping @Sendable (
            CancellationOwnedNewChatOperation<Outcome>
        ) async -> Outcome?
    ) {
        guard child == nil, case .pending = state else { return }
        child = Task { [weak self] in
            guard let self else { return }
            let outcome = await operation(self)
            await self.finish(outcome)
        }
    }

    func value() async -> Outcome? {
        switch state {
        case .pending:
            return await withCheckedContinuation { waiters.append($0) }
        case let .completed(outcome):
            return outcome
        case .cancelled, .claimed:
            return nil
        }
    }

    func isActive() -> Bool {
        if case .pending = state { return true }
        return false
    }

    func retain(_ acquiredLease: CoachContextAuthorityLease) -> Bool {
        guard case .pending = state, lease == nil else {
            acquiredLease.releaseDetached()
            return false
        }
        lease = acquiredLease
        return true
    }

    func claimLease() -> CoachContextAuthorityLease? {
        guard case .completed = state else { return nil }
        state = .claimed
        let claimed = lease
        lease = nil
        child = nil
        return claimed
    }

    func cancel() {
        switch state {
        case .pending, .completed:
            state = .cancelled
        case .cancelled, .claimed:
            return
        }
        child?.cancel()
        child = nil
        let ownedLease = lease
        lease = nil
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume(returning: nil) }
        ownedLease?.releaseDetached()
    }

    private func finish(_ outcome: Outcome?) async {
        guard case .pending = state else { return }
        guard let outcome else {
            state = .cancelled
            child = nil
            let ownedLease = lease
            lease = nil
            let pendingWaiters = waiters
            waiters.removeAll()
            pendingWaiters.forEach { $0.resume(returning: nil) }
            ownedLease?.releaseDetached()
            return
        }
        state = .completed(outcome)
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume(returning: outcome) }
    }
}

private struct ActiveNewChatWork: Sendable {
    let id: UInt64
    let cancel: @Sendable () async -> Void
}

private struct CompletedNewChatWork<Outcome: Sendable>: Sendable {
    let outcome: Outcome
    let lease: CoachContextAuthorityLease?
}

private enum NewChatPreparationOutcome: Sendable {
    case prepared(NewChatSeed)
    case configurationChanged
    case qualifiedConfigurationUnavailable
    case attachmentUnavailable
    case leaseUnavailable
    case profileUnavailable
    case invalidSeed
}

struct NewChatCreationRequest: Sendable {
    let library: LibraryScope
    let attachments: ChatAttachments
    let quoteAuthority: ChatCreationQuoteAuthority
}

enum NewChatCreationOutcome: Sendable {
    case committed(ChatAggregate)
    case requote
    case qualifiedConfigurationUnavailable
    case attachmentUnavailable
    case collisionLimitReached
    case frozen(FrozenChatSnapshot)
    case readOnlyLibrary
    case failed
    case cancelled
}

/// Deep Application module for the complete new-Chat state machine. Its small
/// interface hides catalog/quote cancellation, exact evidence re-resolution,
/// context leasing, Profile fencing, identity collision retries, and authorized
/// persistence. Presentation-facing state remains owned by `DefaultChatFeature`.
actor NewChatCreationModule {
    private static let maximumCollisionAttempts = 3

    private let store: any ChatStorePort
    private let profileReader: any ProfileStatementGenerationReading
    private let clock: any ChatClock
    private let chatIDGenerator: any ChatIDGenerator
    private let draftIDGenerator: any ChatDraftIDGenerator
    private let memoryIDGenerator: any CoachMemoryIDGenerator
    private let coachContext: any ChatCoachContextCoordinating

    private var activeWork: ActiveNewChatWork?
    private var nextWorkID: UInt64 = 0

    init(
        store: any ChatStorePort,
        profileReader: any ProfileStatementGenerationReading,
        clock: any ChatClock,
        chatIDGenerator: any ChatIDGenerator,
        draftIDGenerator: any ChatDraftIDGenerator,
        memoryIDGenerator: any CoachMemoryIDGenerator,
        coachContext: any ChatCoachContextCoordinating
    ) {
        self.store = store
        self.profileReader = profileReader
        self.clock = clock
        self.chatIDGenerator = chatIDGenerator
        self.draftIDGenerator = draftIDGenerator
        self.memoryIDGenerator = memoryIDGenerator
        self.coachContext = coachContext
    }

    func loadCandidates(
        in library: LibraryScope
    ) async -> ChatAttachmentCatalogOutcome? {
        await performTransientWork { [coachContext] in
            await coachContext.loadAttachmentCandidates(in: library)
        }
    }

    func quote(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> ConfigurationBoundChatCreationQuoteOutcome? {
        await performTransientWork { [coachContext] in
            await coachContext.quoteNewChatBoundToConfiguration(request)
        }
    }

    func create(
        _ request: NewChatCreationRequest,
        durablePhaseWillBegin: @escaping @Sendable () async -> Bool
    ) async -> NewChatCreationOutcome {
        let coachContext = coachContext
        let profileReader = profileReader
        let clock = clock
        let chatIDGenerator = chatIDGenerator
        let draftIDGenerator = draftIDGenerator
        let memoryIDGenerator = memoryIDGenerator
        let completed: CompletedNewChatWork<NewChatPreparationOutcome>? =
            await performWork { controller in
                guard await controller.isActive() else { return nil }
                let resolution = await coachContext.resolveAttachments(
                    request.attachments,
                    in: request.library
                )
                guard await controller.isActive() else { return nil }
                switch resolution {
                case .configurationChanged:
                    return .configurationChanged
                case .qualifiedConfigurationUnavailable:
                    return .qualifiedConfigurationUnavailable
                case let .resolved(resolved, configuration):
                    guard configuration == request.quoteAuthority.configuration else {
                        return .configurationChanged
                    }
                    guard resolved.count == request.attachments.values.count,
                          zip(resolved, request.attachments.values).allSatisfy({
                              item, expected in
                              item.attachment == expected && {
                                  if case .available = item.resolution { return true }
                                  return false
                              }()
                          })
                    else {
                        return .attachmentUnavailable
                    }
                case .readOnlyLibrary, .failed:
                    return .attachmentUnavailable
                }

                let leaseOutcome = await coachContext.acquireNewChatCreationLease(
                    request.quoteAuthority
                )
                guard await controller.isActive() else {
                    if case let .acquired(lateLease) = leaseOutcome {
                        lateLease.releaseDetached()
                    }
                    return nil
                }
                guard case let .acquired(lease) = leaseOutcome else {
                    return .leaseUnavailable
                }
                guard await controller.retain(lease) else { return nil }

                guard let profileStatementGeneration =
                    await profileReader.statementGeneration(in: request.library)
                else {
                    return .profileUnavailable
                }
                guard await controller.isActive() else { return nil }
                let instant = await clock.now()
                guard await controller.isActive() else { return nil }
                let chatID = await chatIDGenerator.generateChatID(at: instant)
                guard await controller.isActive() else { return nil }
                let draftID = await draftIDGenerator.generateChatDraftID(at: instant)
                guard await controller.isActive() else { return nil }
                let memoryID = await memoryIDGenerator.generateCoachMemoryID(at: instant)
                guard await controller.isActive() else { return nil }
                do {
                    return .prepared(
                        try NewChatSeed(
                            library: request.library,
                            chatID: chatID,
                            draftID: draftID,
                            memoryID: memoryID,
                            instant: instant,
                            profileStatementGeneration: profileStatementGeneration,
                            attachments: request.attachments
                        )
                    )
                } catch {
                    return .invalidSeed
                }
            }
        guard let completed else { return .cancelled }
        guard case let .prepared(initialSeed) = completed.outcome,
              let lease = completed.lease
        else {
            completed.lease?.releaseDetached()
            switch completed.outcome {
            case .configurationChanged, .leaseUnavailable:
                return .requote
            case .qualifiedConfigurationUnavailable:
                return .qualifiedConfigurationUnavailable
            case .attachmentUnavailable:
                return .attachmentUnavailable
            case .profileUnavailable, .invalidSeed:
                return .failed
            case .prepared:
                return .requote
            }
        }
        guard await durablePhaseWillBegin() else {
            lease.releaseDetached()
            return .cancelled
        }

        let instant = initialSeed.aggregate.chat.createdAt
        let profileGeneration =
            initialSeed.aggregate.chat.profileStatementGenerationAtCreation
        var seed = initialSeed
        var collisionAttempts = 0
        let outcome: ChatMutationOutcome
        while true {
            let retainsEvidenceAuthorityOnCollision =
                collisionAttempts + 1 < Self.maximumCollisionAttempts
            let attempt = await store.create(
                NewChatCommit(
                    seed: seed,
                    evidenceAuthority: request.quoteAuthority.evidence,
                    retainsEvidenceAuthorityOnCollision:
                        retainsEvidenceAuthorityOnCollision
                )
            )
            switch attempt {
            case .collision:
                collisionAttempts += 1
                guard collisionAttempts < Self.maximumCollisionAttempts else {
                    outcome = .collision
                    break
                }
                let chatID = await chatIDGenerator.generateChatID(at: instant)
                let draftID = await draftIDGenerator.generateChatDraftID(at: instant)
                let memoryID = await memoryIDGenerator.generateCoachMemoryID(at: instant)
                do {
                    seed = try NewChatSeed(
                        library: request.library,
                        chatID: chatID,
                        draftID: draftID,
                        memoryID: memoryID,
                        instant: instant,
                        profileStatementGeneration: profileGeneration,
                        attachments: request.attachments
                    )
                } catch {
                    outcome = .failed
                    break
                }
                continue
            default:
                outcome = attempt
            }
            break
        }
        lease.releaseDetached()
        switch outcome {
        case let .committed(aggregate): return .committed(aggregate)
        case .collision: return .collisionLimitReached
        case .creationAuthorityChanged, .profileStatementGenerationChanged:
            return .requote
        case .attachmentUnavailable: return .attachmentUnavailable
        case let .frozen(frozen): return .frozen(frozen)
        case .readOnlyLibrary: return .readOnlyLibrary
        case .stale, .failed: return .failed
        }
    }

    func cancelTransientWork() async {
        let work = activeWork
        activeWork = nil
        await work?.cancel()
    }

    private func performTransientWork<Outcome: Sendable>(
        _ operation: @escaping @Sendable () async -> Outcome
    ) async -> Outcome? {
        let completed: CompletedNewChatWork<Outcome>? = await performWork {
            controller in
            guard await controller.isActive() else { return nil }
            let outcome = await operation()
            guard await controller.isActive() else { return nil }
            return outcome
        }
        completed?.lease?.releaseDetached()
        return completed?.outcome
    }

    private func performWork<Outcome: Sendable>(
        _ operation: @escaping @Sendable (
            CancellationOwnedNewChatOperation<Outcome>
        ) async -> Outcome?
    ) async -> CompletedNewChatWork<Outcome>? {
        guard nextWorkID < .max else {
            await cancelTransientWork()
            return nil
        }
        nextWorkID += 1
        let workID = nextWorkID
        let controller = CancellationOwnedNewChatOperation<Outcome>()
        let superseded = activeWork
        activeWork = ActiveNewChatWork(
            id: workID,
            cancel: { await controller.cancel() }
        )
        await superseded?.cancel()
        guard activeWork?.id == workID else {
            await controller.cancel()
            return nil
        }
        await controller.start(operation)
        guard activeWork?.id == workID else {
            await controller.cancel()
            return nil
        }
        guard let outcome = await controller.value() else { return nil }
        guard activeWork?.id == workID else { return nil }
        let lease = await controller.claimLease()
        guard activeWork?.id == workID else {
            lease?.releaseDetached()
            return nil
        }
        activeWork = nil
        return CompletedNewChatWork(outcome: outcome, lease: lease)
    }
}
