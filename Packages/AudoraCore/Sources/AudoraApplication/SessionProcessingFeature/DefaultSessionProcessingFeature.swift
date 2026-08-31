import AudoraDomain

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public actor DefaultSessionProcessingFeature: SessionProcessingFeature {
    private static let maximumIdentityAttempts = 16

    private enum PendingSelectionCommand {
        case select(SessionProcessingSelection)
        case clear

        var command: SessionProcessingCommand {
            switch self {
            case let .select(selection): .selectSession(selection)
            case .clear: .clearSelection
            }
        }
    }

    private let sourcePort: any SessionTranscriptionSourcePort
    private let runtime: any TranscriptionRuntimePort
    private let model: any TranscriptionModelPort
    private let acoustics: any SessionAcousticEvidencePort
    private let jobs: any SessionProcessingJobPort
    private let engine: any TranscriptionEngine
    private let publisher: TranscriptRevisionPublisher
    private let clock: any SessionProcessingClock
    private let identifiers: any SessionProcessingIDGenerator

    private var state: SessionProcessingFeatureState = .unavailable(
        SessionProcessingUnavailableSnapshot(
            selection: nil,
            reason: .noSession,
            actions: []
        )
    )
    private var selectedSource: SessionTranscriptionSource?
    private var selectedProfile: QualifiedTranscriptionProfile?
    private var lastSelection: SessionProcessingSelection?
    private var commandInFlight = false
    private var pendingSelectionCommand: PendingSelectionCommand?
    private var stateContinuations: [UInt64: AsyncStream<SessionProcessingFeatureState>.Continuation]
        = [:]
    private var nextSubscriberID: UInt64 = 1

    public init(
        source: any SessionTranscriptionSourcePort,
        runtime: any TranscriptionRuntimePort,
        model: any TranscriptionModelPort,
        acoustics: any SessionAcousticEvidencePort,
        jobs: any SessionProcessingJobPort,
        engine: any TranscriptionEngine,
        publisher: TranscriptRevisionPublisher,
        clock: any SessionProcessingClock,
        identifiers: any SessionProcessingIDGenerator
    ) {
        sourcePort = source
        self.runtime = runtime
        self.model = model
        self.acoustics = acoustics
        self.jobs = jobs
        self.engine = engine
        self.publisher = publisher
        self.clock = clock
        self.identifiers = identifiers
    }

    public var currentState: SessionProcessingFeatureState { state }

    public nonisolated var states: AsyncStream<SessionProcessingFeatureState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            Task { await self.addSubscriber(continuation) }
        }
    }

    public func send(_ command: SessionProcessingCommand) async {
        guard !commandInFlight else {
            switch command {
            case let .selectSession(selection):
                pendingSelectionCommand = .select(selection)
            case .clearSelection:
                pendingSelectionCommand = .clear
            case .start, .retry, .prepare, .reinstall:
                break
            }
            return
        }
        commandInFlight = true
        var next: SessionProcessingCommand? = command
        while let current = next {
            await perform(current)
            next = pendingSelectionCommand?.command
            pendingSelectionCommand = nil
        }
        commandInFlight = false
    }

    private func perform(_ command: SessionProcessingCommand) async {
        switch command {
        case let .selectSession(selection):
            await select(selection)
        case .clearSelection:
            clearSelection()
        case .start:
            await start()
        case .retry:
            await retry()
        case .prepare:
            await prepare(.prepare)
        case .reinstall:
            await prepare(.reinstall)
        }
    }

    private func clearSelection() {
        lastSelection = nil
        selectedSource = nil
        selectedProfile = nil
        transition(
            to: .unavailable(
                SessionProcessingUnavailableSnapshot(
                    selection: nil,
                    reason: .noSession,
                    actions: []
                )
            )
        )
    }

    private func select(_ selection: SessionProcessingSelection) async {
        lastSelection = selection
        selectedSource = nil
        selectedProfile = nil
        switch await sourcePort.load(selection) {
        case let .available(source):
            guard source.selection == selection, source.isValid else {
                transition(
                    to: .unavailable(
                        unavailable(selection, .sourceIntegrityMismatch)
                    )
                )
                return
            }
            selectedSource = source
            switch await jobs.latest(for: selection) {
            case let .loaded(latest) where !latest.state.isTerminal:
                transition(to: .recoveryRequired(latest))
                return
            case let .loaded(latest) where latest.state == .failed:
                transition(
                    to: .failed(
                        SessionProcessingFailedSnapshot(
                            job: latest,
                            reason: latest.failure ?? .jobPersistenceFailed,
                            actions: [.retry]
                        )
                    )
                )
                return
            case .integrityMismatch, .unavailable:
                transition(
                    to: .failed(
                        SessionProcessingFailedSnapshot(
                            job: nil,
                            reason: .jobPersistenceFailed,
                            actions: [.retry]
                        )
                    )
                )
                return
            case .none, .loaded:
                break
            }
            transition(to: .ready(SessionProcessingReadySnapshot(source: source)))
        case .unavailable:
            transition(to: .unavailable(unavailable(selection, .sourceUnavailable)))
        case .integrityMismatch:
            transition(
                to: .unavailable(unavailable(selection, .sourceIntegrityMismatch))
            )
        }
    }

    /// Retry is truthful even when the previous source read failed: it rereads
    /// the same sealed Session before attempting a new processing run.
    private func retry() async {
        guard let lastSelection else { return }
        await select(lastSelection)
        guard selectedSource != nil else { return }
        await start()
    }

    private func prepare(_ action: SessionProcessingRecoveryAction) async {
        guard action == .prepare || action == .reinstall,
              let source = selectedSource,
              canRecover
        else { return }
        transition(
            to: .preparing(
                SessionProcessingReadySnapshot(
                    source: source,
                    profileID: selectedProfile?.profileID
                ),
                action
            )
        )

        let runtimeResolution = await runtime.prepare(action)
        guard case let .qualified(profile) = runtimeResolution else {
            selectedProfile = nil
            transition(to: runtimeUnavailable(runtimeResolution, selection: source.selection))
            return
        }
        let modelResolution = await model.prepare(action, profile: profile)
        guard modelResolution == .ready else {
            selectedProfile = profile
            transition(
                to: .unavailable(
                    unavailable(source.selection, modelReason(modelResolution))
                )
            )
            return
        }
        selectedProfile = profile
        transition(
            to: .ready(
                SessionProcessingReadySnapshot(
                    source: source,
                    profileID: profile.profileID
                )
            )
        )
    }

    private func start() async {
        guard let source = selectedSource else { return }
        switch state {
        case .ready, .failed, .unavailable:
            break
        case .preparing, .running, .validating, .completed, .recoveryRequired:
            return
        }

        let runtimeResolution = await runtime.resolve()
        guard case let .qualified(profile) = runtimeResolution else {
            selectedProfile = nil
            transition(to: runtimeUnavailable(runtimeResolution, selection: source.selection))
            return
        }
        guard let runtimeCapability = await runtime.executionCapability(for: profile),
              runtimeCapability.isValid(for: profile)
        else {
            transition(
                to: .unavailable(
                    unavailable(source.selection, .runtimeLockMismatch)
                )
            )
            return
        }
        selectedProfile = profile
        let modelResolution = await model.verify(profile)
        guard modelResolution == .ready else {
            transition(
                to: .unavailable(
                    unavailable(source.selection, modelReason(modelResolution))
                )
            )
            return
        }
        guard let modelCapability = await model.executionCapability(for: profile),
              modelCapability.isValid(for: profile)
        else {
            transition(
                to: .unavailable(
                    unavailable(source.selection, .modelLockMismatch)
                )
            )
            return
        }
        guard case let .qualified(evidence) = await acoustics.resolve(
            for: source,
            profile: profile
        ), evidence.isValid(for: source, profile: profile) else {
            transition(
                to: .unavailable(
                    unavailable(source.selection, .acousticEvidenceUnavailable)
                )
            )
            return
        }

        let createdAt = await clock.now()
        var acceptedJob: SessionProcessingJob?
        for _ in 0..<Self.maximumIdentityAttempts {
            let candidate = SessionProcessingJob(
                jobID: await identifiers.generateJobID(at: createdAt),
                sessionID: source.selection.sessionID,
                revisionID: await identifiers.generateRevisionID(at: createdAt),
                profileID: profile.profileID,
                createdAt: createdAt,
                state: .queued
            )
            switch await jobs.create(candidate) {
            case .written:
                acceptedJob = candidate
            case .collision:
                continue
            case .stale, .failed:
                break
            }
            break
        }
        guard var job = acceptedJob else {
            transition(
                to: .failed(
                    SessionProcessingFailedSnapshot(
                        job: nil,
                        reason: .jobPersistenceFailed,
                        actions: [.retry]
                    )
                )
            )
            return
        }
        let jobID = job.jobID
        let revisionID = job.revisionID

        let queued = job.state
        job = job.transitioning(to: .running)
        guard case .written = await jobs.transition(job, from: queued) else {
            transition(
                to: .failed(
                    SessionProcessingFailedSnapshot(
                        job: job,
                        reason: .jobPersistenceFailed,
                        actions: [.retry]
                    )
                )
            )
            return
        }
        transition(to: .running(SessionProcessingActiveSnapshot(source: source, job: job)))

        let verified: VerifiedTranscriptionCandidate
        do {
            verified = try await engine.transcribe(
                TranscriptionRequest(
                    source: source,
                    jobID: jobID,
                    revisionID: revisionID,
                    createdAt: createdAt,
                    profile: profile,
                    runtimeCapability: runtimeCapability,
                    modelCapability: modelCapability
                ),
                events: { _ in }
            )
        } catch {
            await fail(job: job, expected: .running, reason: .engineFailed)
            return
        }
        guard verified.candidate.candidateArtifactSHA256 ==
            verified.artifactFingerprint.sha256
        else {
            await fail(job: job, expected: .running, reason: .candidateRejected)
            return
        }

        let running = job.state
        job = job.transitioning(
            to: .validating,
            candidateArtifactSHA256: verified.artifactFingerprint.sha256
        )
        guard case .written = await jobs.transition(job, from: running) else {
            transition(
                to: .failed(
                    SessionProcessingFailedSnapshot(
                        job: job,
                        reason: .jobPersistenceFailed,
                        actions: [.retry]
                    )
                )
            )
            return
        }
        transition(
            to: .validating(SessionProcessingActiveSnapshot(source: source, job: job))
        )

        let context = TranscriptPublicationContext(
            jobID: jobID,
            sessionID: source.selection.sessionID,
            revisionID: revisionID,
            createdAt: createdAt,
            durationMilliseconds: source.durationMilliseconds,
            audioFingerprint: source.audioFingerprint,
            sourceFingerprints: source.sourceFingerprints,
            verifiedCandidateArtifactFingerprint: verified.artifactFingerprint,
            engine: profile.engine,
            voicedRanges: evidence.voicedRanges
        )
        switch await publisher.publish(
            verified.candidate,
            context: context,
            expectedSelectedRevisionID: source.expectedSelectedRevisionID
        ) {
        case let .published(reopened):
            let validating = job.state
            job = job.transitioning(to: .completed)
            guard case .written = await jobs.transition(job, from: validating) else {
                transition(
                    to: .failed(
                        SessionProcessingFailedSnapshot(
                            job: job,
                            reason: .installedNeedsRefresh,
                            actions: [.retry]
                        )
                    )
                )
                return
            }
            transition(
                to: .completed(
                    SessionProcessingCompletedSnapshot(
                        sessionID: source.selection.sessionID,
                        jobID: jobID,
                        selectedRevisionID: reopened.selectedRevisionID
                    )
                )
            )
        case let .rejected(failure):
            let reason: SessionProcessingFailureReason
            switch failure {
            case .invalidCandidate:
                reason = .candidateRejected
            case .installedNeedsRefresh:
                reason = .installedNeedsRefresh
            default:
                reason = .publicationFailed
            }
            await fail(job: job, expected: .validating, reason: reason)
        }
    }

    private func fail(
        job: SessionProcessingJob,
        expected: SessionProcessingJobState,
        reason: SessionProcessingFailureReason
    ) async {
        let failed = job.transitioning(to: .failed, failure: reason)
        guard case .written = await jobs.transition(failed, from: expected) else {
            transition(
                to: .failed(
                    SessionProcessingFailedSnapshot(
                        job: failed,
                        reason: .jobPersistenceFailed,
                        actions: [.retry]
                    )
                )
            )
            return
        }
        transition(
            to: .failed(
                SessionProcessingFailedSnapshot(
                    job: failed,
                    reason: reason,
                    actions: [.retry]
                )
            )
        )
    }

    private var canRecover: Bool {
        switch state {
        case .unavailable, .failed, .ready: true
        case .preparing, .running, .validating, .completed, .recoveryRequired: false
        }
    }

    private func runtimeUnavailable(
        _ resolution: TranscriptionRuntimeResolution,
        selection: SessionProcessingSelection
    ) -> SessionProcessingFeatureState {
        switch resolution {
        case .qualified:
            guard let selectedSource else {
                return .unavailable(unavailable(selection, .sourceUnavailable))
            }
            return .ready(SessionProcessingReadySnapshot(source: selectedSource))
        case let .unavailable(reason):
            return .unavailable(unavailable(selection, reason))
        }
    }

    private func unavailable(
        _ selection: SessionProcessingSelection,
        _ reason: SessionProcessingUnavailableReason
    ) -> SessionProcessingUnavailableSnapshot {
        let actions: [SessionProcessingRecoveryAction]
        switch reason {
        case .noSession:
            actions = []
        case .sourceUnavailable, .sourceIntegrityMismatch,
             .acousticEvidenceUnavailable:
            actions = [.retry]
        case .qualificationBlocked:
            actions = []
        case .runtimeMissing, .runtimeLockMismatch, .modelMissing, .modelCorrupt,
             .modelLockMismatch:
            actions = [.prepare, .reinstall, .retry]
        }
        return SessionProcessingUnavailableSnapshot(
            selection: selection,
            reason: reason,
            actions: actions
        )
    }

    private func modelReason(
        _ resolution: TranscriptionModelResolution
    ) -> SessionProcessingUnavailableReason {
        switch resolution {
        case .ready: .modelLockMismatch
        case .missing: .modelMissing
        case .corrupt: .modelCorrupt
        case .lockMismatch: .modelLockMismatch
        }
    }

    private func addSubscriber(
        _ continuation: AsyncStream<SessionProcessingFeatureState>.Continuation
    ) {
        let subscriberID = nextSubscriberID
        nextSubscriberID &+= 1
        stateContinuations[subscriberID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(subscriberID) }
        }
        continuation.yield(state)
    }

    private func removeSubscriber(_ subscriberID: UInt64) {
        stateContinuations.removeValue(forKey: subscriberID)
    }

    private func transition(to next: SessionProcessingFeatureState) {
        state = next
        for continuation in stateContinuations.values { continuation.yield(next) }
    }
}
