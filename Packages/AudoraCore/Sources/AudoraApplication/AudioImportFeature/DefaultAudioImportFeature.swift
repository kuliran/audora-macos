import AudoraDomain

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public actor DefaultAudioImportFeature: AudioImportFeature {
    private static let maximumSessionIDReservationAttempts = 3

    private let port: any AudioImportPort
    private let clock: any LibraryClock
    private let sessionIDGenerator: any SessionIDGenerator
    private let policy: AudioImportPolicy
    private var state = AudioImportFeatureState(status: .idle)
    private var operationTask: Task<Void, Never>?
    private var operationGeneration: UInt64 = 0
    private var continuations: [Int: AsyncStream<AudioImportFeatureState>.Continuation] = [:]
    private var nextSubscriberID = 0

    public init(
        port: any AudioImportPort,
        clock: any LibraryClock,
        sessionIDGenerator: any SessionIDGenerator,
        policy: AudioImportPolicy = .versionOne
    ) {
        self.port = port
        self.clock = clock
        self.sessionIDGenerator = sessionIDGenerator
        self.policy = policy
    }

    public var currentState: AudioImportFeatureState { state }

    public nonisolated var states: AsyncStream<AudioImportFeatureState> {
        AsyncStream { continuation in
            Task { await self.addSubscriber(continuation) }
        }
    }

    public func send(_ command: AudioImportCommand) async {
        switch command {
        case .chooseAudio:
            guard operationTask == nil else { return }
            operationGeneration &+= 1
            let generation = operationGeneration
            transition(to: .selecting)
            operationTask = Task { [weak self] in
                await self?.runImport(generation: generation)
            }

        case .cancelImport:
            operationTask?.cancel()

        case .clearResult:
            guard operationTask == nil else { return }
            transition(to: .idle)
        }
    }

    private func runImport(generation: UInt64) async {
        var stagedID: AudioStagingID?
        var selectedToken: AudioSelectionToken?
        var installStarted = false
        do {
            let selection = await port.choose()
            switch selection {
            case .cancelled:
                finish(generation: generation, status: .failed(.cancelled))
                return
            case let .failed(failure):
                finish(generation: generation, status: .failed(failure))
                return
            case let .selected(token, scope):
                selectedToken = token
                guard !Task.isCancelled else {
                    await port.revokeSelection(token)
                    selectedToken = nil
                    finish(generation: generation, status: .failed(.cancelled))
                    return
                }

                let instant = await clock.now()
                var reservedSessionID: SessionID?
                for _ in 0..<Self.maximumSessionIDReservationAttempts {
                    try Task.checkCancellation()
                    let candidateID = await sessionIDGenerator.generateSessionID(at: instant)
                    switch try await port.reserveSessionID(
                        candidateID,
                        for: token,
                        in: scope
                    ) {
                    case .reserved:
                        reservedSessionID = candidateID
                    case .collision:
                        continue
                    }
                    break
                }
                guard let sessionID = reservedSessionID else {
                    throw AudioImportFailure.destinationCollision
                }
                let seed = ImportedSessionSeed(
                    scope: scope,
                    sessionID: sessionID,
                    createdAt: instant
                )
                // `prepare` consumes the selection capability whether it returns
                // a staged candidate or fails.
                selectedToken = nil
                let candidate = try await port.prepare(
                    token,
                    seed: seed,
                    policy: policy
                ) { [weak self] phase in
                    await self?.acceptProgress(phase, generation: generation)
                }
                stagedID = candidate.stagingID
                guard !Task.isCancelled else {
                    await port.discard(candidate.stagingID)
                    finish(generation: generation, status: .failed(.cancelled))
                    return
                }

                let validated = try AudioImportCandidateValidator.validate(
                    candidate,
                    expectedSeed: seed,
                    policy: policy
                )
                guard !Task.isCancelled else {
                    await port.discard(candidate.stagingID)
                    finish(generation: generation, status: .failed(.cancelled))
                    return
                }

                transitionIfCurrent(to: .installing, generation: generation)
                installStarted = true
                let reopened = try await port.install(validated)

                // Directory installation is the authority boundary. A cancel that
                // races with a successful reopened result cannot erase the Session.
                finish(generation: generation, status: .succeeded(reopened))
            }
        } catch {
            let failure = (error as? AudioImportFailure) ?? .unavailable
            if let selectedToken {
                await port.revokeSelection(selectedToken)
            }
            if let stagedID, failure != .installedNeedsRefresh {
                await port.discard(stagedID)
            }
            let terminal: AudioImportFailure
            if installStarted, failure == .installedNeedsRefresh {
                terminal = .installedNeedsRefresh
            } else if Task.isCancelled {
                terminal = .cancelled
            } else {
                terminal = failure
            }
            finish(generation: generation, status: .failed(terminal))
        }
    }

    private func acceptProgress(
        _ phase: AudioImportPreparationPhase,
        generation: UInt64
    ) {
        let status: AudioImportFeatureState.Status
        switch phase {
        case .copying: status = .copying
        case .inspecting: status = .inspecting
        case .normalizing: status = .normalizing
        }
        transitionIfCurrent(to: status, generation: generation)
    }

    private func transitionIfCurrent(
        to status: AudioImportFeatureState.Status,
        generation: UInt64
    ) {
        guard generation == operationGeneration, operationTask != nil else { return }
        transition(to: status)
    }

    private func finish(
        generation: UInt64,
        status: AudioImportFeatureState.Status
    ) {
        guard generation == operationGeneration, operationTask != nil else { return }
        operationTask = nil
        transition(to: status)
    }

    private func transition(to status: AudioImportFeatureState.Status) {
        state = AudioImportFeatureState(status: status)
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }

    private func addSubscriber(
        _ continuation: AsyncStream<AudioImportFeatureState>.Continuation
    ) {
        let identifier = nextSubscriberID
        nextSubscriberID += 1
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSubscriber(identifier) }
        }
        continuations[identifier] = continuation
        continuation.yield(state)
    }

    private func removeSubscriber(_ identifier: Int) {
        continuations.removeValue(forKey: identifier)
    }
}
