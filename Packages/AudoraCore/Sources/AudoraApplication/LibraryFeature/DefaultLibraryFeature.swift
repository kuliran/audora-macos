import AudoraDomain

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public actor DefaultLibraryFeature: LibraryFeature {
    private struct QueuedExternalOpen {
        let token: LibraryOpenRequestToken
        let completion: CheckedContinuation<Void, Never>
    }

    private let workspace: any LibraryWorkspacePort
    private let clock: any LibraryClock
    private let idGenerator: any LibraryIDGenerator
    private let activityCoordinator: (any LibraryActivityCoordinating)?
    private var state = LibraryFeatureReducer.initialState
    private var hasStarted = false
    private var queuedExternalOpen: QueuedExternalOpen?
    private var continuations: [Int: AsyncStream<LibraryFeatureState>.Continuation] = [:]
    private var nextSubscriberID = 0

    public init(
        workspace: any LibraryWorkspacePort,
        clock: any LibraryClock,
        idGenerator: any LibraryIDGenerator
    ) {
        self.workspace = workspace
        self.clock = clock
        self.idGenerator = idGenerator
        activityCoordinator = nil
    }

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

    var queuedExternalOpenCount: Int {
        queuedExternalOpen == nil ? 0 : 1
    }

    public nonisolated var states: AsyncStream<LibraryFeatureState> {
        AsyncStream { continuation in
            Task {
                await self.addSubscriber(continuation)
            }
        }
    }

    public func send(_ command: LibraryCommand) async {
        if command == .rejectMultipleExternalOpenRequests {
            state = LibraryFeatureState(
                selection: state.selection,
                activity: state.activity,
                notice: .multipleExternalOpenRequests
            )
            publish(state)
            return
        }

        guard state.activity == nil else {
            if case let .openExternal(token) = command {
                await queueExternalOpen(token)
            }
            return
        }

        switch command {
        case .start:
            guard !hasStarted, case .awaitingBootstrap = state.selection else { return }
            hasStarted = true
            await performOpen(activity: .restoring) {
                await workspace.restoreActiveLibrary()
            }

        case .create:
            guard !isAwaitingBootstrap else { return }
            await performOpen(activity: .creating) {
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
            guard !isAwaitingBootstrap else { return }
            await performOpen(activity: .opening) {
                await workspace.chooseLibrary()
            }

        case .reopenRecent:
            guard !isAwaitingBootstrap else { return }
            await performOpen(activity: .opening) {
                await workspace.reopenRecentLibrary()
            }

        case let .openExternal(token):
            await performOpen(activity: .opening) {
                await workspace.openExternalRequest(token)
            }

        case .reveal:
            guard hasSelectedLibrary else { return }
            await performAction(activity: .revealing, close: false) {
                await workspace.revealActiveLibrary()
            }

        case .close:
            guard hasSelectedLibrary else { return }
            await performAction(activity: .closing, close: true) {
                await workspace.closeActiveLibrary()
            }

        case .rejectMultipleExternalOpenRequests:
            break
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
    private func queueExternalOpen(_ token: LibraryOpenRequestToken) async {
        await withCheckedContinuation { continuation in
            let superseded = queuedExternalOpen
            queuedExternalOpen = QueuedExternalOpen(
                token: token,
                completion: continuation
            )
            superseded?.completion.resume()
        }
    }

    private func performOpen(
        activity: LibraryFeatureState.Activity,
        operation: () async -> LibraryOpenOutcome
    ) async {
        let previous = state.selection
        state = LibraryFeatureReducer.begin(activity, from: state)
        publish(state)
        let lease: LibraryActivityLease?
        if let activityCoordinator {
            guard let acquired = await activityCoordinator.acquireSelectionMutation() else {
                state = LibraryFeatureState(
                    selection: previous,
                    notice: .recordingInProgress
                )
                publish(state)
                await replayQueuedExternalOpens()
                return
            }
            lease = acquired
        } else {
            lease = nil
        }
        let outcome = await operation()
        if let lease, let activityCoordinator {
            await activityCoordinator.release(lease)
        }
        state = LibraryFeatureReducer.completeOpen(outcome, previous: previous)
        publish(state)
        await replayQueuedExternalOpens()
    }

    private func performAction(
        activity: LibraryFeatureState.Activity,
        close: Bool,
        operation: () async -> LibraryActionOutcome
    ) async {
        let previous = state.selection
        state = LibraryFeatureReducer.begin(activity, from: state)
        publish(state)
        let lease: LibraryActivityLease?
        if close, let activityCoordinator {
            guard let acquired = await activityCoordinator.acquireSelectionMutation() else {
                state = LibraryFeatureState(
                    selection: previous,
                    notice: .recordingInProgress
                )
                publish(state)
                await replayQueuedExternalOpens()
                return
            }
            lease = acquired
        } else {
            lease = nil
        }
        let outcome = await operation()
        if let lease, let activityCoordinator {
            await activityCoordinator.release(lease)
        }
        state = close
            ? LibraryFeatureReducer.completeClose(outcome, previous: previous)
            : LibraryFeatureReducer.completeReveal(outcome, previous: previous)
        publish(state)
        await replayQueuedExternalOpens()
    }

    private func replayQueuedExternalOpens() async {
        while let queued = queuedExternalOpen {
            queuedExternalOpen = nil
            let previous = state.selection
            state = LibraryFeatureReducer.begin(.opening, from: state)
            publish(state)
            let lease: LibraryActivityLease?
            if let activityCoordinator {
                guard let acquired = await activityCoordinator.acquireSelectionMutation() else {
                    state = LibraryFeatureState(
                        selection: previous,
                        notice: .recordingInProgress
                    )
                    publish(state)
                    queued.completion.resume()
                    continue
                }
                lease = acquired
            } else {
                lease = nil
            }
            let outcome = await workspace.openExternalRequest(queued.token)
            if let lease, let activityCoordinator {
                await activityCoordinator.release(lease)
            }
            state = LibraryFeatureReducer.completeOpen(outcome, previous: previous)
            publish(state)
            queued.completion.resume()
        }
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
