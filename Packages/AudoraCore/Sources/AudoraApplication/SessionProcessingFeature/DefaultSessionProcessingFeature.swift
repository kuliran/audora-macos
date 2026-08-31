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
    private var cancellationFinalizationInFlight = false
    private var pendingSelectionCommand: PendingSelectionCommand?
    private var cancelledRunJobID: TranscriptionJobID?
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
        if command == .cancel {
            await cancel()
            return
        }
        if cancellationFinalizationInFlight {
            retainLatestSelectionCommand(command)
            return
        }
        guard !commandInFlight else {
            retainLatestSelectionCommand(command)
            return
        }
        commandInFlight = true
        var next: SessionProcessingCommand? = command
        while let current = next {
            await perform(current)
            guard !cancellationFinalizationInFlight else { break }
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
        case .cancel:
            await cancel()
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
        cancelledRunJobID = nil
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
            case let .loaded(latest):
                await reconcile(latest, source: source)
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
            case .none:
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
        guard advertisedRecoveryActions.contains(.retry),
              let lastSelection
        else { return }
        await select(lastSelection)
        guard selectedSource != nil, acceptsRefreshedRetryLaunch else { return }
        await launch()
    }

    private func prepare(_ action: SessionProcessingRecoveryAction) async {
        guard action == .prepare || action == .reinstall,
              let source = selectedSource,
              advertisedRecoveryActions.contains(action)
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
        guard acceptsStartCommand else { return }
        await launch()
    }

    /// Internal execution primitive. Callers must first establish either
    /// public Start authority or refreshed Retry authority.
    private func launch() async {
        guard let source = selectedSource else { return }

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
                state: .queued,
                expectedSelectedRevisionID: source.expectedSelectedRevisionID,
                cancellationAuthorityID:
                    await identifiers.generateCancellationAuthorityID(at: createdAt)
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
        guard let cancellationAuthorityID = job.cancellationAuthorityID else {
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
                    modelCapability: modelCapability,
                    cancellationAuthorityID: cancellationAuthorityID
                ),
                events: { [weak self] event in
                    await self?.accept(event, for: jobID)
                }
            )
        } catch {
            if cancelledRunJobID == jobID { return }
            await fail(job: job, expected: .running, reason: .engineFailed)
            return
        }
        guard cancelledRunJobID != jobID else { return }
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
        await publish(
            verified,
            source: source,
            profile: profile,
            evidence: evidence,
            job: job
        )
    }

    private func reconcile(
        _ job: SessionProcessingJob,
        source: SessionTranscriptionSource
    ) async {
        switch job.state {
        case .queued:
            // Running is persisted before any engine launch. A durable queued
            // Job therefore proves that no worker acquired execution authority,
            // but the interrupted create→running window still needs an explicit
            // retry path after relaunch.
            await interrupt(job, source: source)
        case .preparing, .running:
            guard job.cancellationAuthorityID != nil else {
                transition(to: .recoveryRequired(job))
                return
            }
            switch await engine.workerPresence(for: job.executionReference) {
            case .absent:
                await finishAbandoned(job, source: source)
            case .present:
                let outcome = await engine.cancel(job.executionReference)
                guard outcome == .reaped || outcome == .alreadyAbsent else {
                    transition(to: .recoveryRequired(job))
                    return
                }
                await finishAbandoned(job, source: source)
            case .unknown:
                transition(to: .recoveryRequired(job))
            }
        case .validating:
            await resumeValidation(job, source: source)
        case .completed:
            guard await completedRevisionMatches(job, source: source) else {
                transition(
                    to: .failed(
                        SessionProcessingFailedSnapshot(
                            job: job,
                            reason: .canonicalRevisionIntegrityFailed,
                            actions: []
                        )
                    )
                )
                return
            }
            transition(
                to: .completed(
                    SessionProcessingCompletedSnapshot(
                        sessionID: job.sessionID,
                        jobID: job.jobID,
                        selectedRevisionID:
                            source.expectedSelectedRevisionID ?? job.revisionID
                    )
                )
            )
        case .failed:
            transition(
                to: .failed(
                    SessionProcessingFailedSnapshot(
                        job: job,
                        reason: job.failure ?? .jobPersistenceFailed,
                        actions: [.retry]
                    )
                )
            )
        case .cancelled:
            transition(
                to: .cancelled(
                    SessionProcessingRecoverableSnapshot(
                        source: source,
                        job: job,
                        actions: [.retry]
                    )
                )
            )
        case .interrupted:
            transition(
                to: .interrupted(
                    SessionProcessingRecoverableSnapshot(
                        source: source,
                        job: job,
                        actions: [.retry]
                    )
                )
            )
        }
    }

    private func resumeValidation(
        _ job: SessionProcessingJob,
        source: SessionTranscriptionSource
    ) async {
        if source.expectedSelectedRevisionID == job.revisionID {
            guard await selectedRevisionMatches(job, source: source) else {
                transition(
                    to: .failed(
                        SessionProcessingFailedSnapshot(
                            job: job,
                            reason: .canonicalRevisionIntegrityFailed,
                            actions: []
                        )
                    )
                )
                return
            }
            await completeInstalledValidation(job, source: source)
            return
        }
        guard job.hasCapturedSelectionBaseline else {
            await interrupt(job, source: source)
            return
        }
        guard let expectedHash = job.candidateArtifactSHA256 else {
            await interrupt(job, source: source)
            return
        }
        let verified: VerifiedTranscriptionCandidate
        switch await engine.recoverCandidate(for: job) {
        case let .available(candidate):
            guard candidate.artifactFingerprint.sha256 == expectedHash,
                  candidate.candidate.candidateArtifactSHA256 == expectedHash
            else {
                await interrupt(job, source: source)
                return
            }
            verified = candidate
        case .unavailable, .integrityMismatch:
            await interrupt(job, source: source)
            return
        }
        guard case let .qualified(profile) = await runtime.resolve(),
              profile.profileID == job.profileID,
              case let .qualified(evidence) = await acoustics.resolve(
                  for: source,
                  profile: profile
              ),
              evidence.isValid(for: source, profile: profile)
        else {
            await interrupt(job, source: source)
            return
        }
        selectedProfile = profile
        transition(
            to: .validating(
                SessionProcessingActiveSnapshot(source: source, job: job)
            )
        )
        await publish(
            verified,
            source: source,
            profile: profile,
            evidence: evidence,
            job: job
        )
    }

    private func publish(
        _ verified: VerifiedTranscriptionCandidate,
        source: SessionTranscriptionSource,
        profile: QualifiedTranscriptionProfile,
        evidence: SessionVoicedRangeEvidence,
        job: SessionProcessingJob
    ) async {
        guard job.hasCapturedSelectionBaseline else {
            await interrupt(job, source: source)
            return
        }
        let context = TranscriptPublicationContext(
            jobID: job.jobID,
            sessionID: source.selection.sessionID,
            revisionID: job.revisionID,
            createdAt: job.createdAt,
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
            expectedSelectedRevisionID: job.expectedSelectedRevisionID
        ) {
        case let .published(reopened):
            let completed = job.transitioning(to: .completed)
            guard case .written = await jobs.transition(completed, from: .validating)
            else {
                transition(
                    to: .failed(
                        SessionProcessingFailedSnapshot(
                            job: completed,
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
                        jobID: job.jobID,
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
            case .staleSelection:
                reason = .staleSelection
            default:
                reason = .publicationFailed
            }
            await fail(job: job, expected: .validating, reason: reason)
        }
    }

    private func selectedRevisionMatches(
        _ job: SessionProcessingJob,
        source: SessionTranscriptionSource
    ) async -> Bool {
        guard source.expectedSelectedRevisionID == job.revisionID,
              case let .available(reopened) = await publisher.reopenSelected(
                  sessionID: job.sessionID
              ),
              reopened.selectedRevisionID == job.revisionID,
              reopened.revisionIDs.contains(job.revisionID),
              reopened.selectedRevision.revisionID == job.revisionID,
              reopened.selectedRevision.sessionID == job.sessionID,
              reopened.selectedRevision.jobID == job.jobID,
              reopened.selectedRevision.audioFingerprint == source.audioFingerprint,
              reopened.selectedRevision.sourceFingerprints == source.sourceFingerprints,
              reopened.selectedRevision.candidateArtifactFingerprint.sha256 ==
                job.candidateArtifactSHA256
        else { return false }
        return true
    }

    private func completedRevisionMatches(
        _ job: SessionProcessingJob,
        source: SessionTranscriptionSource
    ) async -> Bool {
        guard case let .available(revision) = await publisher.reopenRevision(
            sessionID: job.sessionID,
            revisionID: job.revisionID
        ),
              revision.revisionID == job.revisionID,
              revision.sessionID == job.sessionID,
              revision.jobID == job.jobID,
              revision.audioFingerprint == source.audioFingerprint,
              revision.sourceFingerprints == source.sourceFingerprints,
              revision.candidateArtifactFingerprint.sha256 ==
                job.candidateArtifactSHA256
        else { return false }
        return true
    }

    private func completeInstalledValidation(
        _ job: SessionProcessingJob,
        source: SessionTranscriptionSource
    ) async {
        let completed = job.transitioning(to: .completed)
        guard case .written = await jobs.transition(completed, from: .validating) else {
            transition(
                to: .failed(
                    SessionProcessingFailedSnapshot(
                        job: completed,
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
                    jobID: job.jobID,
                    selectedRevisionID: job.revisionID
                )
            )
        )
    }

    private func interrupt(
        _ job: SessionProcessingJob,
        source: SessionTranscriptionSource
    ) async {
        let interrupted = job.transitioning(to: .interrupted)
        guard case .written = await jobs.transition(interrupted, from: job.state)
        else {
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
            to: .interrupted(
                SessionProcessingRecoverableSnapshot(
                    source: source,
                    job: interrupted,
                    actions: [.retry]
                )
            )
        )
    }

    private func finishAbandoned(
        _ job: SessionProcessingJob,
        source: SessionTranscriptionSource
    ) async {
        guard job.cancellationRequestedAt != nil else {
            await interrupt(job, source: source)
            return
        }
        let cancelled = job.transitioning(to: .cancelled)
        guard case .written = await jobs.transition(cancelled, from: job.state) else {
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
            to: .cancelled(
                SessionProcessingRecoverableSnapshot(
                    source: source,
                    job: cancelled,
                    actions: [.retry]
                )
            )
        )
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
                        job: job,
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

    private func cancel() async {
        guard case let .running(active) = state,
              active.job.cancellationRequestedAt == nil,
              active.job.cancellationAuthorityID != nil,
              !cancellationFinalizationInFlight
        else { return }

        let jobID = active.job.jobID
        cancellationFinalizationInFlight = true
        cancelledRunJobID = jobID
        guard let requested = active.job.requestingCancellation(at: await clock.now())
        else {
            await finishCancellationFinalization()
            return
        }
        guard case .written = await jobs.transition(requested, from: active.job.state)
        else {
            _ = await engine.cancel(active.job.executionReference)
            transition(
                to: .failed(
                    SessionProcessingFailedSnapshot(
                        job: active.job,
                        reason: .jobPersistenceFailed,
                        actions: [.retry]
                    )
                )
            )
            await finishCancellationFinalization()
            return
        }
        let cancelling = SessionProcessingActiveSnapshot(
            source: active.source,
            job: requested,
            phase: active.phase,
            progress: active.progress
        )
        transition(to: .cancelling(cancelling))

        let outcome = await engine.cancel(requested.executionReference)
        guard outcome == .reaped || outcome == .alreadyAbsent else {
            transition(to: .recoveryRequired(requested))
            cancellationFinalizationInFlight = false
            return
        }
        let cancelled = requested.transitioning(to: .cancelled)
        guard case .written = await jobs.transition(cancelled, from: requested.state)
        else {
            transition(
                to: .failed(
                    SessionProcessingFailedSnapshot(
                        job: requested,
                        reason: .jobPersistenceFailed,
                        actions: [.retry]
                    )
                )
            )
            await finishCancellationFinalization()
            return
        }
        transition(
            to: .cancelled(
                SessionProcessingRecoverableSnapshot(
                    source: active.source,
                    job: cancelled,
                    actions: [.retry]
                )
            )
        )
        await finishCancellationFinalization()
    }

    private func retainLatestSelectionCommand(_ command: SessionProcessingCommand) {
        switch command {
        case let .selectSession(selection):
            pendingSelectionCommand = .select(selection)
        case .clearSelection:
            pendingSelectionCommand = .clear
        case .start, .cancel, .retry, .prepare, .reinstall:
            break
        }
    }

    private func finishCancellationFinalization() async {
        cancellationFinalizationInFlight = false
        guard !commandInFlight, pendingSelectionCommand != nil else { return }
        commandInFlight = true
        while let current = pendingSelectionCommand?.command {
            pendingSelectionCommand = nil
            await perform(current)
            guard !cancellationFinalizationInFlight else { break }
        }
        commandInFlight = false
    }

    private func accept(
        _ event: TranscriptionEvent,
        for jobID: TranscriptionJobID
    ) {
        guard case let .running(active) = state,
              active.job.jobID == jobID,
              cancelledRunJobID != jobID,
              !active.job.state.isTerminal
        else { return }

        switch event {
        case let .phase(phase):
            switch phase {
            case .loadingModel:
                guard active.phase != .transcribing, active.progress == nil else {
                    return
                }
                transition(
                    to: .running(
                        SessionProcessingActiveSnapshot(
                            source: active.source,
                            job: active.job,
                            phase: .loadingModel,
                            progress: nil
                        )
                    )
                )
            case .transcribing:
                transition(
                    to: .running(
                        SessionProcessingActiveSnapshot(
                            source: active.source,
                            job: active.job,
                            phase: .transcribing,
                            progress: active.progress
                        )
                    )
                )
            }
        case let .progress(completed, total, etaSeconds):
            guard total > 0, completed <= total else { return }
            if let previous = active.progress {
                guard previous.totalWindows == total,
                      completed >= previous.completedWindows
                else { return }
            }
            transition(
                to: .running(
                    SessionProcessingActiveSnapshot(
                        source: active.source,
                        job: active.job,
                        phase: .transcribing,
                        progress: SessionProcessingProgress(
                            completedWindows: completed,
                            totalWindows: total,
                            approximateETASeconds: etaSeconds
                        )
                    )
                )
            )
        }
    }

    private var advertisedRecoveryActions: [SessionProcessingRecoveryAction] {
        switch state {
        case let .unavailable(snapshot): snapshot.actions
        case let .queued(snapshot), let .cancelled(snapshot), let .interrupted(snapshot):
            snapshot.actions
        case let .failed(snapshot): snapshot.actions
        case .ready, .preparing, .running, .cancelling, .validating, .completed,
             .recoveryRequired:
            []
        }
    }

    private var acceptsStartCommand: Bool {
        switch state {
        case .ready, .completed: true
        case .unavailable, .preparing, .queued, .running, .cancelling,
             .validating, .failed, .cancelled, .interrupted, .recoveryRequired:
            false
        }
    }

    private var acceptsRefreshedRetryLaunch: Bool {
        switch state {
        case .ready:
            true
        case let .cancelled(snapshot):
            snapshot.job.state == .cancelled && snapshot.actions.contains(.retry)
        case let .interrupted(snapshot):
            snapshot.job.state == .interrupted && snapshot.actions.contains(.retry)
        case let .failed(snapshot):
            snapshot.job?.state == .failed && snapshot.actions.contains(.retry)
        case .unavailable, .preparing, .queued, .running, .cancelling,
             .validating, .completed, .recoveryRequired:
            false
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
