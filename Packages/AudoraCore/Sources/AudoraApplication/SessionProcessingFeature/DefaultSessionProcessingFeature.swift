import AudoraDomain

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public actor DefaultSessionProcessingFeature: SessionProcessingFeature {
    private static let maximumIdentityAttempts = 16
    private static let maximumReconciledJobCount = 10_000

    private struct CompletedRecoveryKey: Hashable {
        let libraryID: String
        let sessionID: String

        init(_ selection: SessionProcessingSelection) {
            libraryID = selection.scope.libraryID.rawValue
            sessionID = selection.sessionID.rawValue
        }
    }

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
    private var pendingLibraryActivationScope: LibraryScope?
    private var cancelledRunJobID: TranscriptionJobID?
    private var invalidCompletedJobs: [CompletedRecoveryKey: SessionProcessingJob]
        = [:]
    private var suppressStateTransitions = false
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
            next = takePendingContextCommand()
        }
        commandInFlight = false
    }

    private func perform(_ command: SessionProcessingCommand) async {
        switch command {
        case let .activateLibrary(scope):
            await reconcileActiveLibrary(scope)
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

    /// Bounded launch-time reconciliation is intentionally independent of UI
    /// Session selection. Infrastructure binds the inventory capability to one
    /// retained Library generation; every subsequent source/job/publication
    /// boundary fails closed if that authority is no longer current.
    private func reconcileActiveLibrary(_ scope: LibraryScope) async {
        let inventory: SessionProcessingJobInventory
        switch await jobs.inventory(for: scope) {
        case let .available(available):
            inventory = available
        case .unavailable, .integrityMismatch:
            return
        }
        let reconciliationID = inventory.reconciliationID
        guard inventory.scope == scope,
              inventory.jobs.count <= Self.maximumReconciledJobCount,
              Set(inventory.jobs.map(\.jobID)).count == inventory.jobs.count
        else {
            await jobs.finishReconciliation(reconciliationID)
            return
        }
        // One writable Library is active at a time. Its bounded inventory is
        // the authority for launch-time completed-Job recovery errors.
        invalidCompletedJobs.removeAll(keepingCapacity: true)

        let preservedProfile = selectedProfile
        suppressStateTransitions = true
        for job in inventory.jobs.sorted(by: {
            ($0.createdAt.rawValue, $0.jobID.rawValue) <
                ($1.createdAt.rawValue, $1.jobID.rawValue)
        }) {
            switch job.state {
            case .queued, .preparing, .running:
                await reconcileBackgroundControl(job)
                continue
            case .failed, .cancelled, .interrupted:
                // These terminal outcomes remain terminal and require no
                // canonical-audio or Revision work during activation.
                continue
            case .validating, .completed:
                break
            }
            let selection = SessionProcessingSelection(
                scope: scope,
                sessionID: job.sessionID
            )
            let sourceResult = await sourcePort.load(
                selection,
                reconciliationID: reconciliationID
            )
            guard case let .available(source) = sourceResult,
                  source.selection == selection,
                  source.isValid
            else {
                // Validating work may safely become retryable interruption.
                // Completed authority is immutable: missing/corrupt sealed
                // source leaves it fail-closed so selecting that Session opens
                // the canonical recovery error instead of retranscribing.
                if job.state == .validating {
                    await persistBackgroundTerminal(job, as: .interrupted)
                } else {
                    invalidCompletedJobs[CompletedRecoveryKey(selection)] = job
                }
                continue
            }
            if job.state == .completed {
                guard await completedRevisionMatches(job, source: source) else {
                    invalidCompletedJobs[CompletedRecoveryKey(selection)] = job
                    continue
                }
                continue
            }
            await reconcile(job, source: source)
        }
        suppressStateTransitions = false
        selectedProfile = preservedProfile
        await jobs.finishReconciliation(reconciliationID)
    }

    private func reconcileBackgroundControl(_ job: SessionProcessingJob) async {
        switch job.state {
        case .queued:
            await persistBackgroundTerminal(job, as: .interrupted)
        case .preparing, .running:
            guard job.cancellationAuthorityID != nil else { return }
            switch await engine.workerPresence(for: job.executionReference) {
            case .absent:
                await persistBackgroundAbandonment(job)
            case .present:
                let outcome = await engine.cancel(job.executionReference)
                guard outcome == .reaped || outcome == .alreadyAbsent else { return }
                await persistBackgroundAbandonment(job)
            case .unknown:
                // Preserve the nonterminal Job as recovery-required. Absence
                // has not been proved, so no durable terminal claim is safe.
                return
            }
        case .validating, .completed, .failed, .cancelled, .interrupted:
            return
        }
    }

    private func persistBackgroundAbandonment(_ job: SessionProcessingJob) async {
        await persistBackgroundTerminal(
            job,
            as: job.cancellationRequestedAt == nil ? .interrupted : .cancelled
        )
    }

    private func persistBackgroundTerminal(
        _ job: SessionProcessingJob,
        as state: SessionProcessingJobState
    ) async {
        let terminal = job.transitioning(to: state)
        _ = await jobs.transition(terminal, from: job.state)
    }

    private func select(_ selection: SessionProcessingSelection) async {
        lastSelection = selection
        selectedSource = nil
        selectedProfile = nil
        if let invalid = invalidCompletedJobs[CompletedRecoveryKey(selection)] {
            transition(
                to: .failed(
                    SessionProcessingFailedSnapshot(
                        job: invalid,
                        reason: .canonicalRevisionIntegrityFailed,
                        actions: []
                    )
                )
            )
            return
        }
        switch await sourcePort.load(selection) {
        case let .available(source):
            guard source.selection == selection, source.isValid else {
                guard await interruptValidatingJobWithoutSource(for: selection) else {
                    return
                }
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
            guard await interruptValidatingJobWithoutSource(for: selection) else {
                return
            }
            transition(to: .unavailable(unavailable(selection, .sourceUnavailable)))
        case .integrityMismatch:
            guard await interruptValidatingJobWithoutSource(for: selection) else {
                return
            }
            transition(
                to: .unavailable(unavailable(selection, .sourceIntegrityMismatch))
            )
        }
    }

    private func interruptValidatingJobWithoutSource(
        for selection: SessionProcessingSelection
    ) async -> Bool {
        switch await jobs.latest(for: selection) {
        case let .loaded(job) where job.state == .validating:
            let interrupted = job.transitioning(to: .interrupted)
            guard case .written = await jobs.transition(
                interrupted,
                from: .validating
            ) else {
                transition(
                    to: .failed(
                        SessionProcessingFailedSnapshot(
                            job: job,
                            reason: .jobPersistenceFailed,
                            actions: [.retry]
                        )
                    )
                )
                return false
            }
            return true
        case .loaded, .none:
            return true
        case .unavailable, .integrityMismatch:
            transition(
                to: .failed(
                    SessionProcessingFailedSnapshot(
                        job: nil,
                        reason: .jobPersistenceFailed,
                        actions: [.retry]
                    )
                )
            )
            return false
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
        let candidateWrite = await jobs.transition(job, from: running)
        // Cancel may enter while the durable running→validating CAS is
        // suspended. Whichever CAS commits owns the outcome: the original
        // transcribe path must not publish or overwrite cancellation after
        // returning across this suspension boundary.
        guard cancelledRunJobID != jobID else { return }
        guard case .written = candidateWrite else {
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
                        revisionID: job.revisionID,
                        selectedRevisionID: source.expectedSelectedRevisionID
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
        // Publication is manifest-last: the exact immutable Revision may be
        // installed even when the publisher returned installedNeedsRefresh or
        // the validating->completed Job CAS failed. Prove this Job's Revision
        // first, independently of a later review selection, and never republish
        // it against the stale start-time selection baseline.
        if await completedRevisionMatches(job, source: source) {
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
                // The canonical selection has already committed. Preserve the
                // durable validating Job as the sole recovery authority so a
                // later exact reopen completes this Job instead of rerunning it.
                transition(to: .recoveryRequired(job))
                return
            }
            transition(
                to: .completed(
                    SessionProcessingCompletedSnapshot(
                        sessionID: source.selection.sessionID,
                        jobID: job.jobID,
                        revisionID: job.revisionID,
                        selectedRevisionID: reopened.selectedRevisionID
                    )
                )
            )
        case let .rejected(failure):
            if failure == .installedNeedsRefresh {
                // Repository contract: selection already switched, but its
                // mandatory reopen could not complete. Never rewrite this
                // validating Job to retryable failed; relaunch must prove and
                // reopen the exact installed Revision by Job identity.
                transition(to: .recoveryRequired(job))
                return
            }
            let reason: SessionProcessingFailureReason
            switch failure {
            case .invalidCandidate:
                reason = .candidateRejected
            case .installedNeedsRefresh:
                preconditionFailure("handled above")
            case .staleSelection:
                reason = .staleSelection
            default:
                reason = .publicationFailed
            }
            await fail(job: job, expected: .validating, reason: reason)
        }
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
              revision.createdAt == job.createdAt,
              let qualification = revision.engine.qualification,
              qualification.qualificationProfileID == job.profileID,
              revision.durationMilliseconds == source.durationMilliseconds,
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
            transition(to: .recoveryRequired(job))
            return
        }
        transition(
            to: .completed(
                SessionProcessingCompletedSnapshot(
                    sessionID: source.selection.sessionID,
                    jobID: job.jobID,
                    revisionID: job.revisionID,
                    selectedRevisionID: source.expectedSelectedRevisionID
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
        let failureWrite = await jobs.transition(failed, from: expected)
        // Cancel can enter while any terminal CAS is suspended. Once it has
        // raised this run's fence, its exact-Job refresh owns presentation of
        // the first durable winner; a late acknowledgement (including an
        // ambiguous failed/stale result) must not invent jobPersistenceFailed.
        guard cancelledRunJobID != job.jobID else { return }
        guard case .written = failureWrite else {
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
        let requestWrite = await jobs.transition(requested, from: active.job.state)
        switch requestWrite {
        case .written:
            break
        case .stale:
            // A candidate may have committed running→validating while this
            // cancellation CAS was suspended. Refresh that exact Job and let
            // its already-accepted validation/publication outcome finish;
            // never send cancellation authority to a worker after losing CAS.
            guard await resumeDurableWinnerAfterCancellationCASLoss(active)
            else {
                await retainRecoveryForUnconfirmedCancellation(active.job)
                return
            }
            await finishCancellationFinalization()
            return
        case .collision, .failed:
            let outcome = await engine.cancel(active.job.executionReference)
            guard outcome == .reaped || outcome == .alreadyAbsent else {
                await retainRecoveryForUnconfirmedCancellation(active.job)
                return
            }
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
            await retainRecoveryForUnconfirmedCancellation(requested)
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

    private func resumeDurableWinnerAfterCancellationCASLoss(
        _ active: SessionProcessingActiveSnapshot
    ) async -> Bool {
        guard case let .loaded(current) = await jobs.load(
            jobID: active.job.jobID,
            for: active.source.selection
        ),
              current.jobID == active.job.jobID,
              current.sessionID == active.job.sessionID,
              current.revisionID == active.job.revisionID,
              current.profileID == active.job.profileID,
              current.createdAt == active.job.createdAt,
              current.expectedSelectedRevisionID ==
                active.job.expectedSelectedRevisionID,
              current.hasCapturedSelectionBaseline ==
                active.job.hasCapturedSelectionBaseline,
              current.cancellationAuthorityID ==
                active.job.cancellationAuthorityID,
              current.state == .validating || current.state == .completed ||
                current.state == .failed
        else { return false }
        await reconcile(current, source: active.source)
        return true
    }

    private func retainRecoveryForUnconfirmedCancellation(
        _ job: SessionProcessingJob
    ) async {
        transition(to: .recoveryRequired(job))
        // The old worker may still be alive, so ordinary Session commands stay
        // fenced behind its in-flight run. Library activation is a lifecycle
        // obligation for a newly active authority and must still reconcile its
        // durable Jobs without inheriting this run's UI state.
        while let scope = pendingLibraryActivationScope {
            pendingLibraryActivationScope = nil
            await reconcileActiveLibrary(scope)
        }
        await finishCancellationFinalization()
    }

    private func retainLatestSelectionCommand(_ command: SessionProcessingCommand) {
        switch command {
        case let .activateLibrary(scope):
            pendingLibraryActivationScope = scope
        case let .selectSession(selection):
            pendingSelectionCommand = .select(selection)
        case .clearSelection:
            pendingSelectionCommand = .clear
        case .start, .cancel, .retry, .prepare, .reinstall:
            break
        }
    }

    private func takePendingContextCommand() -> SessionProcessingCommand? {
        if let scope = pendingLibraryActivationScope {
            pendingLibraryActivationScope = nil
            return .activateLibrary(scope)
        }
        defer { pendingSelectionCommand = nil }
        return pendingSelectionCommand?.command
    }

    private func finishCancellationFinalization() async {
        cancellationFinalizationInFlight = false
        guard !commandInFlight,
              pendingSelectionCommand != nil || pendingLibraryActivationScope != nil
        else { return }
        commandInFlight = true
        while let current = takePendingContextCommand() {
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
        guard !suppressStateTransitions else { return }
        state = next
        for continuation in stateContinuations.values { continuation.yield(next) }
    }
}
