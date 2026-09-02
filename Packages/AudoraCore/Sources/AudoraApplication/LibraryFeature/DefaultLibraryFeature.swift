import AudoraDomain

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public actor DefaultLibraryFeature: LibraryFeature {
    private struct QueuedExternalOpen {
        let token: LibraryOpenRequestToken
        let completion: CheckedContinuation<LibraryCommandResult, Never>
    }

    private let workspace: any LibraryWorkspacePort
    private let clock: any LibraryClock
    private let idGenerator: any LibraryIDGenerator
    private let activityCoordinator: any LibraryActivityCoordinating
    private var state = LibraryFeatureReducer.initialState
    private var hasStarted = false
    private var activationGeneration: UInt64 = 0
    private var queuedExternalOpen: QueuedExternalOpen?
    private var continuations: [Int: AsyncStream<LibraryFeatureState>.Continuation] = [:]
    private var nextSubscriberID = 0

    public init(
        workspace: any LibraryWorkspacePort,
        clock: any LibraryClock,
        idGenerator: any LibraryIDGenerator,
        activityCoordinator: any LibraryActivityCoordinating
    ) {
        self.workspace = workspace
        self.clock = clock
        self.idGenerator = idGenerator
        self.activityCoordinator = activityCoordinator
    }

    public var currentState: LibraryFeatureState {
        state
    }

    var queuedExternalOpenToken: LibraryOpenRequestToken? {
        queuedExternalOpen?.token
    }

    public nonisolated var states: AsyncStream<LibraryFeatureState> {
        AsyncStream { continuation in
            Task {
                await self.addSubscriber(continuation)
            }
        }
    }

    @discardableResult
    public func send(_ command: LibraryCommand) async -> LibraryCommandResult {
        if command == .rejectMultipleExternalOpenRequests {
            state = LibraryFeatureState(
                selection: state.selection,
                activity: state.activity,
                notice: .multipleExternalOpenRequests
            )
            publish(state)
            return .noSelectionMutation
        }

        guard state.activity == nil else {
            if case let .openExternal(token) = command {
                return await queueExternalOpen(token)
            }
            return .noSelectionMutation
        }

        switch command {
        case .start:
            guard !hasStarted, case .awaitingBootstrap = state.selection else {
                return .noSelectionMutation
            }
            hasStarted = true
            return await performOpen(activity: .restoring) {
                await workspace.restoreActiveLibrary()
            }

        case .create:
            guard !isAwaitingBootstrap else { return .noSelectionMutation }
            return await performOpen(activity: .creating) {
                let instant = await clock.now()
                let libraryID = await idGenerator.generateLibraryID(at: instant)
                let seed = NewLibrarySeed(
                    libraryID: libraryID,
                    createdAt: instant,
                    preferences: .defaults,
                    profileHead: ProfileHead(
                        generation: 0,
                        statementGeneration: 0,
                        selection: .null,
                        updatedAt: instant
                    )
                )
                return await workspace.createLibrary(seed)
            }

        case .chooseExisting:
            guard !isAwaitingBootstrap else { return .noSelectionMutation }
            return await performOpen(activity: .opening) {
                await workspace.chooseLibrary()
            }

        case .reopenRecent:
            guard !isAwaitingBootstrap else { return .noSelectionMutation }
            return await performOpen(activity: .opening) {
                await workspace.reopenRecentLibrary()
            }

        case let .openExternal(token):
            return await performOpen(activity: .opening) {
                await workspace.openExternalRequest(token)
            }

        case .reveal:
            guard hasSelectedLibrary else { return .noSelectionMutation }
            return await performAction(activity: .revealing, close: false) {
                await workspace.revealActiveLibrary()
            }

        case .close:
            guard hasSelectedLibrary else { return .noSelectionMutation }
            return await performAction(activity: .closing, close: true) {
                await workspace.closeActiveLibrary()
            }

        case .rejectMultipleExternalOpenRequests:
            return .noSelectionMutation
        }
    }

    private var isAwaitingBootstrap: Bool {
        if case .awaitingBootstrap = state.selection { return true }
        return false
    }

    private var hasSelectedLibrary: Bool {
        switch state.selection {
        case .active, .readOnly:
            true
        case .awaitingBootstrap, .noLibrarySelected:
            false
        }
    }

    // The caller owns the opaque URL token until this suspension ends. Keeping
    // one continuation here lets Launch Services callbacks survive a suspended
    // restore without expanding the workspace's one-capability bound. A newer
    // callback supersedes the older one and releases its caller immediately.
    private func queueExternalOpen(
        _ token: LibraryOpenRequestToken
    ) async -> LibraryCommandResult {
        await withCheckedContinuation { continuation in
            let superseded = queuedExternalOpen
            queuedExternalOpen = QueuedExternalOpen(
                token: token,
                completion: continuation
            )
            superseded?.completion.resume(returning: .noSelectionMutation)
        }
    }

    private func performOpen(
        activity: LibraryFeatureState.Activity,
        operation: () async -> LibraryOpenOutcome
    ) async -> LibraryCommandResult {
        guard let reservedActivationGeneration = reserveActivationGeneration() else {
            return .noSelectionMutation
        }
        let previous = state.selection
        state = LibraryFeatureReducer.begin(activity, from: state)
        publish(state)
        guard let lease = await activityCoordinator.acquireSelectionMutation() else {
            state = LibraryFeatureState(
                selection: previous,
                notice: .libraryActivityInProgress
            )
            publish(state)
            return await replayQueuedExternalOpens() ?? .noSelectionMutation
        }
        let outcome = await operation()
        await activityCoordinator.release(lease)
        state = LibraryFeatureReducer.completeOpen(outcome, previous: previous)
        publish(state)
        let result = commandResult(
            for: outcome,
            reservedActivationGeneration: reservedActivationGeneration
        )
        return await replayQueuedExternalOpens() ?? result
    }

    private func performAction(
        activity: LibraryFeatureState.Activity,
        close: Bool,
        operation: () async -> LibraryActionOutcome
    ) async -> LibraryCommandResult {
        let previous = state.selection
        state = LibraryFeatureReducer.begin(activity, from: state)
        publish(state)
        let lease: LibraryActivityLease?
        if close {
            guard let acquired = await activityCoordinator.acquireSelectionMutation() else {
                state = LibraryFeatureState(
                    selection: previous,
                    notice: .libraryActivityInProgress
                )
                publish(state)
                return await replayQueuedExternalOpens() ?? .noSelectionMutation
            }
            lease = acquired
        } else {
            lease = nil
        }
        let outcome = await operation()
        if let lease {
            await activityCoordinator.release(lease)
        }
        state = close
            ? LibraryFeatureReducer.completeClose(outcome, previous: previous)
            : LibraryFeatureReducer.completeReveal(outcome, previous: previous)
        publish(state)
        let result: LibraryCommandResult
        if close, case .succeeded = outcome {
            result = .deactivated
        } else {
            result = .noSelectionMutation
        }
        return await replayQueuedExternalOpens() ?? result
    }

    private func replayQueuedExternalOpens() async -> LibraryCommandResult? {
        var latestMutation: LibraryCommandResult?
        while let queued = queuedExternalOpen {
            queuedExternalOpen = nil
            guard let reservedActivationGeneration = reserveActivationGeneration() else {
                queued.completion.resume(returning: .noSelectionMutation)
                continue
            }
            let previous = state.selection
            state = LibraryFeatureReducer.begin(.opening, from: state)
            publish(state)
            guard let lease = await activityCoordinator.acquireSelectionMutation() else {
                state = LibraryFeatureState(
                    selection: previous,
                    notice: .libraryActivityInProgress
                )
                publish(state)
                queued.completion.resume(returning: .noSelectionMutation)
                continue
            }
            let outcome = await workspace.openExternalRequest(queued.token)
            await activityCoordinator.release(lease)
            state = LibraryFeatureReducer.completeOpen(outcome, previous: previous)
            publish(state)
            let result = commandResult(
                for: outcome,
                reservedActivationGeneration: reservedActivationGeneration
            )
            if result.didMutateSelection { latestMutation = result }
            queued.completion.resume(returning: result)
        }
        return latestMutation
    }

    private func commandResult(
        for outcome: LibraryOpenOutcome,
        reservedActivationGeneration: UInt64
    ) -> LibraryCommandResult {
        switch outcome {
        case let .opened(snapshot, _):
            return .activated(
                LibraryActivation(
                    scope: LibraryScope(libraryID: snapshot.libraryID),
                    generation: reservedActivationGeneration
                )
            )
        case .noLibrarySelected, .readOnly:
            return .deactivated
        case .cancelled, .failed:
            return .noSelectionMutation
        }
    }

    private func reserveActivationGeneration() -> UInt64? {
        guard activationGeneration < .max else { return nil }
        activationGeneration += 1
        return activationGeneration
    }

    private func addSubscriber(
        _ continuation: AsyncStream<LibraryFeatureState>.Continuation
    ) {
        let subscriberID = nextSubscriberID
        nextSubscriberID += 1

        continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.removeSubscriber(subscriberID)
            }
        }
        continuations[subscriberID] = continuation
        continuation.yield(state)
    }

    private func removeSubscriber(_ subscriberID: Int) {
        continuations.removeValue(forKey: subscriberID)
    }

    private func publish(_ snapshot: LibraryFeatureState) {
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }
}
