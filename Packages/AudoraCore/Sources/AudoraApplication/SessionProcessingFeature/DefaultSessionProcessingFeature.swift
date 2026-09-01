import AudoraDomain

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public actor DefaultSessionProcessingFeature: SessionProcessingFeature {
    private static let maximumIdentityAttempts = 16
    /// Bounds exact-winner rediscovery independently of inventory size. The
    /// monotonic Job graph normally settles sooner; exhaustion fails closed.
    private static let maximumExactWinnerReconciliationPassCount = 8
    private static let maximumReconciledJobCount = 10_000

    private struct CompletedRecoveryKey: Hashable {
        let libraryID: String
        let sessionID: String

        init(_ selection: SessionProcessingSelection) {
            libraryID = selection.scope.libraryID.rawValue
            sessionID = selection.sessionID.rawValue
        }
    }

    private enum ActivationRecovery {
        /// A stale compare-and-swap proved that another writer committed first;
        /// this is the exact immutable-identity load of that durable winner.
        case exactWinner(SessionProcessingJob)
        /// Persistence did not establish a new durable truth. The inventoried
        /// Job remains fenced until a later Library activation can reconcile it.
        case unconfirmed(SessionProcessingJob)
    }

    private struct ActivationRecoveryLedger {
        var exactWinner: SessionProcessingJob?
        private var unconfirmedJobs: [TranscriptionJobID: SessionProcessingJob]
            = [:]

        var recoveryRequiredJob: SessionProcessingJob? {
            unconfirmedJobs.values.min {
                ($0.createdAt.rawValue, $0.jobID.rawValue) <
                    ($1.createdAt.rawValue, $1.jobID.rawValue)
            }
        }

        var isEmpty: Bool { exactWinner == nil && unconfirmedJobs.isEmpty }
        var hasUnconfirmedJobs: Bool { !unconfirmedJobs.isEmpty }

        mutating func retain(_ recovery: ActivationRecovery) {
            switch recovery {
            case let .exactWinner(job):
                exactWinner = job
            case let .unconfirmed(job):
                unconfirmedJobs[job.jobID] = job
            }
        }

        mutating func supersedeExactWinner() {
            exactWinner = nil
        }

        mutating func resolveUnconfirmedJob(_ jobID: TranscriptionJobID) {
            unconfirmedJobs.removeValue(forKey: jobID)
        }
    }

    private enum DurableMutationOutcome {
        case settled
        case stale
        case unconfirmed

        init(_ write: SessionProcessingJobWriteResult) {
            switch write {
            case .written:
                self = .settled
            case .stale:
                self = .stale
            case .collision, .failed:
                self = .unconfirmed
            }
        }
    }

    /// The durable recovery policy is shared; only authority acquisition and
    /// observable projection differ between launch activation and a selected
    /// Session refresh.
    private enum DurableRecoveryContext {
        case libraryActivation(
            scope: LibraryScope,
            reconciliationID: SessionProcessingReconciliationID
        )
        case selectedSession(SessionTranscriptionSource)

        var isLibraryActivation: Bool {
            if case .libraryActivation = self { return true }
            return false
        }
    }

    private enum DurableRecoveryContinuation {
        case stop
        case next(SessionProcessingJob, exactWinner: Bool)
    }

    private enum StagedCandidateProof {
        case verified(VerifiedTranscriptionCandidate)
        case invalid
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

    private struct ClassifiedActivationInventory {
        let jobs: [SessionProcessingJob]
        let isComplete: Bool
    }

    private struct LibraryRecoveryBlock {
        let activation: LibraryActivation
        let reason: SessionProcessingUnavailableReason

        var snapshot: SessionProcessingUnavailableSnapshot {
            SessionProcessingUnavailableSnapshot(
                selection: nil,
                reason: reason,
                actions: []
            )
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
    private var pendingLibraryActivation: LibraryActivation?
    private var libraryNavigationReserved = false
    private var libraryNavigationActivation: LibraryActivation?
    private var cancelledRunJobID: TranscriptionJobID?
    private var invalidCompletedJobs: [CompletedRecoveryKey: SessionProcessingJob]
        = [:]
    private var activationRecovery: [CompletedRecoveryKey: ActivationRecoveryLedger]
        = [:]
    /// Every Library activation event installs a fail-closed launch fence. Only
    /// a complete pass over the exact retained root generation may clear it.
    private var libraryReconciliationFence: LibraryActivation?
    private var successfullyReconciledLibraryActivation: LibraryActivation?
    private var latestLibraryActivation: LibraryActivation?
    private var libraryRecoveryBlock: LibraryRecoveryBlock?
    private var legacyActivationGeneration: UInt64 = 0
    private var hasObservedLibraryActivation = false
    private var activeReconciliationActivation: LibraryActivation?
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

    public func send(_ requestedCommand: SessionProcessingCommand) async {
        guard let command = normalizedCommand(requestedCommand) else { return }
        if case let .activateLibraryAuthority(activation) = command,
           !observeLibraryActivation(activation)
        {
            return
        }
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

    public func activateLibrary(_ activation: LibraryActivation) async {
        await send(.activateLibraryAuthority(activation))
    }

    public func reserveLibraryNavigation() async -> Bool {
        guard !libraryNavigationReserved,
              libraryReconciliationFence == nil,
              !state.ownsLibraryMutationAuthority,
              !commandInFlight,
              !cancellationFinalizationInFlight
        else { return false }
        libraryNavigationReserved = true
        libraryNavigationActivation = nil
        return true
    }

    public func finishLibraryNavigation(didMutateLibrary: Bool) async {
        guard libraryNavigationReserved else { return }
        // An accepted activation already cleared the prior context before its
        // inventory pass and may have installed a recovered route. Preserve
        // that result; only a mutation with no writable activation (for
        // example Close or read-only Open) needs a final clear here.
        if didMutateLibrary, libraryNavigationActivation == nil {
            clearSelection()
        }
        libraryNavigationActivation = nil
        libraryNavigationReserved = false
    }

    private func perform(_ command: SessionProcessingCommand) async {
        switch command {
        case let .activateLibrary(scope):
            guard let activation = reserveLegacyActivation(for: scope),
                  observeLibraryActivation(activation)
            else { return }
            await reconcileActiveLibrary(activation)
        case let .activateLibraryAuthority(activation):
            await reconcileActiveLibrary(activation)
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

    private func normalizedCommand(
        _ command: SessionProcessingCommand
    ) -> SessionProcessingCommand? {
        guard case let .activateLibrary(scope) = command else { return command }
        guard let activation = reserveLegacyActivation(for: scope) else {
            hasObservedLibraryActivation = true
            if let latestLibraryActivation {
                libraryReconciliationFence = latestLibraryActivation
            }
            return nil
        }
        return .activateLibraryAuthority(activation)
    }

    private func reserveLegacyActivation(
        for scope: LibraryScope
    ) -> LibraryActivation? {
        let latestGeneration = latestLibraryActivation?.generation ?? 0
        let floor = max(legacyActivationGeneration, latestGeneration)
        guard floor < .max else { return nil }
        let generation = floor + 1
        legacyActivationGeneration = generation
        return LibraryActivation(scope: scope, generation: generation)
    }

    private func observeLibraryActivation(_ activation: LibraryActivation) -> Bool {
        hasObservedLibraryActivation = true
        guard activation.generation > 0 else {
            latestLibraryActivation = activation
            libraryReconciliationFence = activation
            successfullyReconciledLibraryActivation = nil
            return false
        }
        if let latest = latestLibraryActivation {
            if activation.generation < latest.generation {
                return false
            }
            if activation.generation == latest.generation {
                guard activation == latest else {
                    latestLibraryActivation = activation
                    libraryReconciliationFence = activation
                    successfullyReconciledLibraryActivation = nil
                    return false
                }
                return false
            }
        }
        latestLibraryActivation = activation
        libraryReconciliationFence = activation
        return true
    }

    private func clearSelection() {
        lastSelection = nil
        selectedSource = nil
        selectedProfile = nil
        cancelledRunJobID = nil
        guard !projectCurrentLibraryRecoveryBlock() else { return }
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
    private func reconcileActiveLibrary(_ activation: LibraryActivation) async {
        let scope = activation.scope
        if libraryNavigationReserved {
            clearSelection()
            libraryNavigationActivation = activation
        }
        let inventory: SessionProcessingJobInventory
        switch await jobs.inventory(for: scope) {
        case let .available(available):
            inventory = available
        case let .unsupportedSchema(version):
            guard latestLibraryActivation == activation,
                  libraryReconciliationFence == activation
            else { return }
            installLibraryRecoveryBlock(
                .jobIndexSchemaNewer(version: version),
                activation: activation
            )
            return
        case .unavailable:
            guard latestLibraryActivation == activation,
                  libraryReconciliationFence == activation
            else { return }
            installLibraryRecoveryBlock(
                .jobIndexUnavailable,
                activation: activation
            )
            return
        case .integrityMismatch:
            guard latestLibraryActivation == activation,
                  libraryReconciliationFence == activation
            else { return }
            installLibraryRecoveryBlock(
                .jobIndexIntegrityMismatch,
                activation: activation
            )
            return
        }
        let reconciliationID = inventory.reconciliationID
        guard latestLibraryActivation == activation,
              libraryReconciliationFence == activation,
              inventory.scope == scope
        else {
            await jobs.finishReconciliation(reconciliationID)
            return
        }
        let classified = classifyActivationInventory(
            inventory.jobs,
            repositoryReportedComplete: inventory.isComplete
        )
        // One writable Library is active at a time. Its bounded inventory is
        // the authority for launch-time completed-Job recovery errors.
        if classified.isComplete {
            invalidCompletedJobs.removeAll(keepingCapacity: false)
            activationRecovery.removeAll(keepingCapacity: false)
        }

        let preservedProfile = selectedProfile
        activeReconciliationActivation = activation
        suppressStateTransitions = true
        var superseded = false
        for job in classified.jobs {
            guard latestLibraryActivation == activation else {
                superseded = true
                break
            }
            // A newer inventoried Job supersedes only the prior exact-winner
            // presentation. Every unresolved nonterminal Job remains fenced by
            // exact Job identity until a later activation proves it settled.
            supersedeExactActivationWinner(
                for: SessionProcessingSelection(scope: scope, sessionID: job.sessionID)
            )
            await reconcileActivationJob(
                job,
                scope: scope,
                reconciliationID: reconciliationID
            )
            if latestLibraryActivation != activation {
                superseded = true
                break
            }
        }
        suppressStateTransitions = false
        activeReconciliationActivation = nil
        selectedProfile = preservedProfile
        await jobs.finishReconciliation(reconciliationID)
        guard !superseded,
              latestLibraryActivation == activation,
              libraryReconciliationFence == activation
        else { return }
        guard classified.isComplete else {
            installLibraryRecoveryBlock(
                .jobIndexIncomplete,
                activation: activation
            )
            return
        }
        let releasedLibraryRecoveryBlock = libraryRecoveryBlock != nil
        libraryRecoveryBlock = nil

        let libraryID = scope.libraryID.rawValue
        let hasInvalidCompletedAuthority = invalidCompletedJobs.keys.contains {
            $0.libraryID == libraryID
        }
        let hasUnconfirmedAuthority = activationRecovery.contains { key, ledger in
            key.libraryID == libraryID && ledger.hasUnconfirmedJobs
        }
        if classified.isComplete,
           !hasInvalidCompletedAuthority, !hasUnconfirmedAuthority,
           libraryReconciliationFence == activation
        {
            libraryReconciliationFence = nil
            successfullyReconciledLibraryActivation = activation
        }

        // Activation may have discovered durable recovery outside the prior
        // on-screen Session. Expose one deterministic recovered route before
        // refreshing that stale selection; every sibling has still been
        // reconciled by the complete bounded pass above.
        // An unconfirmed cancellation owns the current observable recovery
        // fence while its worker may still be alive. Its queued activation has
        // completed the full inventory pass above, but must not replace that
        // stronger live authority with a sibling's terminal Retry route.
        guard pendingSelectionCommand == nil,
              !cancellationFinalizationInFlight
        else { return }
        if let recovered = deterministicRecoveredSelection(for: scope) {
            await projectDeterministicActivationRecovery(recovered)
            return
        }
        if let selected = lastSelection {
            if selected.scope == scope { await select(selected) }
            return
        }
        if releasedLibraryRecoveryBlock {
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
    }

    /// Preserve the repository's causal order while bounding hostile or corrupt
    /// inventories. Exact duplicate records are reconciled once; conflicting
    /// records for one Job identity are excluded while independently valid
    /// siblings still have their worker authority reaped.
    private func classifyActivationInventory(
        _ inventoried: [SessionProcessingJob],
        repositoryReportedComplete: Bool
    ) -> ClassifiedActivationInventory {
        var firstByID: [TranscriptionJobID: SessionProcessingJob] = [:]
        var orderedIDs: [TranscriptionJobID] = []
        var conflictingIDs: Set<TranscriptionJobID> = []
        var sawDuplicate = false

        for job in inventoried.prefix(Self.maximumReconciledJobCount) {
            if let existing = firstByID[job.jobID] {
                sawDuplicate = true
                if existing != job { conflictingIDs.insert(job.jobID) }
            } else {
                firstByID[job.jobID] = job
                orderedIDs.append(job.jobID)
            }
        }
        let classified: [SessionProcessingJob] = orderedIDs.compactMap { jobID in
            guard !conflictingIDs.contains(jobID) else { return nil }
            return firstByID[jobID]
        }
        return ClassifiedActivationInventory(
            jobs: classified,
            isComplete: repositoryReportedComplete &&
                inventoried.count <= Self.maximumReconciledJobCount &&
                !sawDuplicate
        )
    }

    private func reconcileActivationJob(
        _ inventoried: SessionProcessingJob,
        scope: LibraryScope,
        reconciliationID: SessionProcessingReconciliationID
    ) async {
        await recoverDurableJob(
            inventoried,
            context: .libraryActivation(
                scope: scope,
                reconciliationID: reconciliationID
            )
        )
    }

    private func recoverDurableJob(
        _ initial: SessionProcessingJob,
        context: DurableRecoveryContext,
        initialCandidateProof: StagedCandidateProof? = nil
    ) async {
        let selection: SessionProcessingSelection
        switch context {
        case let .libraryActivation(scope, _):
            selection = SessionProcessingSelection(
                scope: scope,
                sessionID: initial.sessionID
            )
        case let .selectedSession(source):
            selection = source.selection
        }
        var job = initial
        var isExactWinner = false
        var observedJobs: [SessionProcessingJob] = []

        for _ in 0..<Self.maximumExactWinnerReconciliationPassCount {
            guard !observedJobs.contains(job) else {
                projectRecoveryRequired(job, context: context)
                return
            }
            observedJobs.append(job)

            switch job.state {
            case .queued:
                let outcome = await persistInterruptedRecovery(
                    job,
                    selection: selection,
                    context: context
                )
                switch await recoveryContinuation(
                    after: outcome,
                    job: job,
                    selection: selection,
                    context: context
                ) {
                case .stop:
                    return
                case let .next(winner, exactWinner):
                    job = winner
                    isExactWinner = isExactWinner || exactWinner
                }
            case .preparing, .running:
                guard job.cancellationAuthorityID != nil else {
                    projectRecoveryRequired(job, context: context)
                    return
                }
                switch await engine.workerPresence(for: job.executionReference) {
                case .absent:
                    break
                case .present:
                    let outcome = await engine.cancel(job.executionReference)
                    guard outcome == .reaped || outcome == .alreadyAbsent else {
                        projectRecoveryRequired(job, context: context)
                        return
                    }
                case .unknown:
                    projectRecoveryRequired(job, context: context)
                    return
                }
                let outcome = await persistAbandonedRecovery(
                    job,
                    selection: selection,
                    context: context
                )
                switch await recoveryContinuation(
                    after: outcome,
                    job: job,
                    selection: selection,
                    context: context
                ) {
                case .stop:
                    return
                case let .next(winner, exactWinner):
                    job = winner
                    isExactWinner = isExactWinner || exactWinner
                }
            case .failed, .cancelled, .interrupted:
                projectRecoveredTerminal(
                    job,
                    context: context,
                    isExactWinner: isExactWinner
                )
                return
            case .completed:
                guard let source = await recoverySource(
                    for: selection,
                    context: context
                ) else {
                    // Completed authority is immutable: missing/corrupt sealed
                    // source leaves it fail-closed instead of retranscribing.
                    projectInvalidCompleted(job, context: context)
                    return
                }
                guard await completedRevisionMatches(job, source: source) else {
                    projectInvalidCompleted(job, context: context)
                    return
                }
                projectRecoveredCompleted(
                    job,
                    source: source,
                    context: context,
                    isExactWinner: isExactWinner
                )
                return
            case .validating:
                let proof: StagedCandidateProof
                if job == initial, let initialCandidateProof {
                    proof = initialCandidateProof
                } else {
                    proof = await proveStagedCandidate(for: job)
                }
                guard case let .verified(verified) = proof else {
                    if let source = await recoverySource(
                        for: selection,
                        context: context
                    ), await completedRevisionMatches(job, source: source)
                    {
                        let outcome = await completeInstalledValidation(
                            job,
                            source: source
                        )
                        switch await recoveryContinuation(
                            after: outcome,
                            job: job,
                            selection: selection,
                            context: context
                        ) {
                        case .stop:
                            return
                        case let .next(winner, exactWinner):
                            job = winner
                            isExactWinner = isExactWinner || exactWinner
                        }
                        continue
                    }
                    let outcome = await persistInterruptedRecovery(
                        job,
                        selection: selection,
                        context: context
                    )
                    switch await recoveryContinuation(
                        after: outcome,
                        job: job,
                        selection: selection,
                        context: context
                    ) {
                    case .stop:
                        return
                    case let .next(winner, exactWinner):
                        job = winner
                        isExactWinner = isExactWinner || exactWinner
                    }
                    continue
                }
                guard let source = await recoverySource(
                    for: selection,
                    context: context
                ) else {
                    projectDeferredValidation(job, context: context)
                    return
                }
                guard let outcome = await resumeValidation(
                    job,
                    source: source,
                    verified: verified
                ) else {
                    projectDeferredValidation(job, context: context)
                    return
                }
                switch await recoveryContinuation(
                    after: outcome,
                    job: job,
                    selection: selection,
                    context: context
                ) {
                case .stop:
                    return
                case let .next(winner, exactWinner):
                    job = winner
                    isExactWinner = isExactWinner || exactWinner
                }
            }
        }

        projectRecoveryRequired(job, context: context)
    }

    private func recoverySource(
        for selection: SessionProcessingSelection,
        context: DurableRecoveryContext
    ) async -> SessionTranscriptionSource? {
        switch context {
        case let .libraryActivation(_, reconciliationID):
            guard case let .available(source) = await sourcePort.load(
                selection,
                reconciliationID: reconciliationID
            ), source.selection == selection, source.isValid
            else { return nil }
            return source
        case let .selectedSession(source):
            guard source.selection == selection, source.isValid else { return nil }
            return source
        }
    }

    private func persistInterruptedRecovery(
        _ job: SessionProcessingJob,
        selection: SessionProcessingSelection,
        context: DurableRecoveryContext
    ) async -> DurableMutationOutcome {
        switch context {
        case .libraryActivation:
            await persistBackgroundTerminal(
                job,
                as: .interrupted,
                selection: selection
            )
        case let .selectedSession(source):
            await interrupt(job, source: source)
        }
    }

    private func persistAbandonedRecovery(
        _ job: SessionProcessingJob,
        selection: SessionProcessingSelection,
        context: DurableRecoveryContext
    ) async -> DurableMutationOutcome {
        switch context {
        case .libraryActivation:
            await persistBackgroundAbandonment(job, selection: selection)
        case let .selectedSession(source):
            await finishAbandoned(job, source: source)
        }
    }

    private func recoveryContinuation(
        after outcome: DurableMutationOutcome,
        job: SessionProcessingJob,
        selection: SessionProcessingSelection,
        context: DurableRecoveryContext
    ) async -> DurableRecoveryContinuation {
        switch outcome {
        case .settled:
            return .stop
        case .stale:
            guard let winner = await loadExactWinner(
                afterStaleWriteFor: job,
                selection: selection
            ) else {
                if !context.isLibraryActivation {
                    transition(to: .recoveryRequired(job))
                }
                return .stop
            }
            return .next(winner, exactWinner: true)
        case .unconfirmed:
            if context.isLibraryActivation {
                retainActivationRecovery(.unconfirmed(job), for: job)
                return .stop
            }
            if case .recoveryRequired = state { return .stop }
            if let winner = await loadExactJob(
                jobID: job.jobID,
                selection: selection,
                matching: job
            ), winner.state != job.state {
                return .next(winner, exactWinner: false)
            }
            presentPersistenceFailure(for: job)
            return .stop
        }
    }

    private func projectRecoveryRequired(
        _ job: SessionProcessingJob,
        context: DurableRecoveryContext
    ) {
        if context.isLibraryActivation {
            retainActivationRecovery(.unconfirmed(job), for: job)
        } else {
            transition(to: .recoveryRequired(job))
        }
    }

    /// A hash-valid staged candidate remains the authority for this validating
    /// Job even when the mutable machine qualification context cannot currently
    /// be re-established. Keep the Job unchanged and retry publication only
    /// after trusted app-owned runtime and acoustic evidence become available.
    private func projectDeferredValidation(
        _ job: SessionProcessingJob,
        context: DurableRecoveryContext
    ) {
        if context.isLibraryActivation {
            retainActivationRecovery(.exactWinner(job), for: job)
        } else {
            transition(to: .recoveryRequired(job))
        }
    }

    private func projectInvalidCompleted(
        _ job: SessionProcessingJob,
        context: DurableRecoveryContext
    ) {
        switch context {
        case let .libraryActivation(scope, _):
            invalidCompletedJobs[
                CompletedRecoveryKey(
                    SessionProcessingSelection(scope: scope, sessionID: job.sessionID)
                )
            ] = job
        case .selectedSession:
            transition(
                to: .failed(
                    SessionProcessingFailedSnapshot(
                        job: job,
                        reason: .canonicalRevisionIntegrityFailed,
                        actions: []
                    )
                )
            )
        }
    }

    private func projectRecoveredCompleted(
        _ job: SessionProcessingJob,
        source: SessionTranscriptionSource,
        context: DurableRecoveryContext,
        isExactWinner: Bool
    ) {
        if context.isLibraryActivation {
            if isExactWinner {
                retainActivationRecovery(.exactWinner(job), for: job)
            }
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
    }

    private func projectRecoveredTerminal(
        _ job: SessionProcessingJob,
        context: DurableRecoveryContext,
        isExactWinner _: Bool
    ) {
        switch context {
        case .libraryActivation:
            // Inventory is in causal order and each newer Job clears only the
            // prior exact presentation for its own Session. Retaining every
            // durable terminal here therefore leaves that Session's exact
            // current winner available after the full pass.
            retainActivationRecovery(.exactWinner(job), for: job)
        case let .selectedSession(source):
            switch job.state {
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
            case .queued, .preparing, .running, .validating, .completed:
                preconditionFailure("nonterminal Job reached terminal projection")
            }
        }
    }

    private func persistBackgroundAbandonment(
        _ job: SessionProcessingJob,
        selection: SessionProcessingSelection
    ) async -> DurableMutationOutcome {
        await persistBackgroundTerminal(
            job,
            as: job.cancellationRequestedAt == nil ? .interrupted : .cancelled,
            selection: selection
        )
    }

    private func persistBackgroundTerminal(
        _ job: SessionProcessingJob,
        as state: SessionProcessingJobState,
        selection: SessionProcessingSelection
    ) async -> DurableMutationOutcome {
        let terminal = job.transitioning(to: state)
        switch await jobs.transition(terminal, from: job.state) {
        case .written:
            retainActivationRecovery(.exactWinner(terminal), for: terminal)
            return .settled
        case .stale:
            return .stale
        case .collision, .failed:
            retainActivationRecovery(.unconfirmed(job), for: job)
            return .unconfirmed
        }
    }

    private func loadExactWinner(
        afterStaleWriteFor job: SessionProcessingJob,
        selection: SessionProcessingSelection
    ) async -> SessionProcessingJob? {
        guard let winner = await loadExactJob(
            jobID: job.jobID,
            selection: selection,
            matching: job
        ) else {
            retainActivationRecovery(.unconfirmed(job), for: job)
            return nil
        }
        resolveUnconfirmedActivationRecovery(for: job)
        return winner
    }

    private func loadExactJob(
        jobID: TranscriptionJobID,
        selection: SessionProcessingSelection,
        matching reference: SessionProcessingJob
    ) async -> SessionProcessingJob? {
        guard case let .loaded(job) = await jobs.load(
            jobID: jobID,
            for: selection
        ), job.reconciliationIdentity == reference.reconciliationIdentity
        else { return nil }
        return job
    }

    private func presentPersistenceFailure(for job: SessionProcessingJob?) {
        transition(
            to: .failed(
                SessionProcessingFailedSnapshot(
                    job: job,
                    reason: .jobPersistenceFailed,
                    actions: [.retry]
                )
            )
        )
    }

    private func presentUnsupportedJobIndex(
        version: UInt32,
        selection: SessionProcessingSelection?
    ) {
        transition(
            to: .unavailable(
                SessionProcessingUnavailableSnapshot(
                    selection: selection,
                    reason: .jobIndexSchemaNewer(version: version),
                    actions: []
                )
            )
        )
    }

    private func installLibraryRecoveryBlock(
        _ reason: SessionProcessingUnavailableReason,
        activation: LibraryActivation
    ) {
        guard latestLibraryActivation == activation,
              libraryReconciliationFence == activation
        else { return }
        let block = LibraryRecoveryBlock(
            activation: activation,
            reason: reason
        )
        libraryRecoveryBlock = block
        selectedSource = nil
        selectedProfile = nil
        transition(to: .unavailable(block.snapshot))
    }

    private func projectCurrentLibraryRecoveryBlock() -> Bool {
        guard let block = currentLibraryRecoveryBlock() else { return false }
        transition(to: .unavailable(block.snapshot))
        return true
    }

    private func currentLibraryRecoveryBlock() -> LibraryRecoveryBlock? {
        guard let block = libraryRecoveryBlock,
              latestLibraryActivation == block.activation,
              libraryReconciliationFence == block.activation
        else { return nil }
        return block
    }

    private func select(_ selection: SessionProcessingSelection) async {
        selectedSource = nil
        selectedProfile = nil
        if let block = currentLibraryRecoveryBlock() {
            if selection.scope == block.activation.scope {
                lastSelection = selection
            }
            transition(to: .unavailable(block.snapshot))
            return
        }
        lastSelection = selection
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
        let recoveryKey = CompletedRecoveryKey(selection)
        if let job = activationRecovery[recoveryKey]?.recoveryRequiredJob {
            transition(to: .recoveryRequired(job))
            return
        }
        let jobResult: SessionProcessingJobLoadResult
        if let winner = takeExactActivationWinner(for: recoveryKey) {
            jobResult = .loaded(winner)
        } else {
            jobResult = await jobs.latest(for: selection)
        }
        switch jobResult {
        case let .loaded(job) where job.state == .validating:
            let proof = await proveStagedCandidate(for: job)
            await selectValidatingJob(
                job,
                proof: proof,
                selection: selection
            )
        case let .loaded(job):
            await selectSource(for: selection, job: job)
        case .none:
            await selectSource(for: selection, job: nil)
        case let .unsupportedSchema(version):
            await retainReadableSourceIfAvailable(for: selection)
            presentUnsupportedJobIndex(version: version, selection: selection)
        case .integrityMismatch, .unavailable:
            await retainReadableSourceIfAvailable(for: selection)
            presentPersistenceFailure(for: nil)
        }
    }

    private func selectSource(
        for selection: SessionProcessingSelection,
        job: SessionProcessingJob?
    ) async {
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
            if let job {
                await recoverDurableJob(job, context: .selectedSession(source))
            } else {
                transition(to: .ready(SessionProcessingReadySnapshot(source: source)))
            }
        case .unavailable:
            transition(to: .unavailable(unavailable(selection, .sourceUnavailable)))
        case .integrityMismatch:
            transition(
                to: .unavailable(unavailable(selection, .sourceIntegrityMismatch))
            )
        }
    }

    private func selectValidatingJob(
        _ job: SessionProcessingJob,
        proof: StagedCandidateProof,
        selection: SessionProcessingSelection
    ) async {
        let sourceResult = await sourcePort.load(selection)
        if case let .available(source) = sourceResult,
           source.selection == selection, source.isValid
        {
            selectedSource = source
            await recoverDurableJob(
                job,
                context: .selectedSession(source),
                initialCandidateProof: proof
            )
            return
        }
        guard await preserveOrInterruptValidatingJobWithoutSource(
            job,
            proof: proof,
            selection: selection
        ) else { return }
        let reason: SessionProcessingUnavailableReason = switch sourceResult {
        case .unavailable:
            .sourceUnavailable
        case .available, .integrityMismatch:
            .sourceIntegrityMismatch
        }
        transition(to: .unavailable(unavailable(selection, reason)))
    }

    private func preserveOrInterruptValidatingJobWithoutSource(
        _ initial: SessionProcessingJob,
        proof initialProof: StagedCandidateProof,
        selection: SessionProcessingSelection
    ) async -> Bool {
        var job = initial
        var proof: StagedCandidateProof? = initialProof
        var observedJobs: [SessionProcessingJob] = []
        for _ in 0..<Self.maximumExactWinnerReconciliationPassCount {
            guard !observedJobs.contains(job) else {
                transition(to: .recoveryRequired(job))
                return false
            }
            observedJobs.append(job)
            guard job.state == .validating else { return true }

            let currentProof: StagedCandidateProof
            if let proof {
                currentProof = proof
            } else {
                currentProof = await proveStagedCandidate(for: job)
            }
            proof = nil
            switch currentProof {
            case .verified:
                transition(to: .recoveryRequired(job))
                return false
            case .invalid:
                break
            }

            let interrupted = job.transitioning(to: .interrupted)
            switch DurableMutationOutcome(
                await jobs.transition(interrupted, from: .validating)
            ) {
            case .settled:
                return true
            case .stale:
                guard let winner = await loadExactWinner(
                    afterStaleWriteFor: job,
                    selection: selection
                ) else {
                    transition(to: .recoveryRequired(job))
                    return false
                }
                job = winner
            case .unconfirmed:
                presentPersistenceFailure(for: job)
                return false
            }
        }
        transition(to: .recoveryRequired(job))
        return false
    }

    private func retainReadableSourceIfAvailable(
        for selection: SessionProcessingSelection
    ) async {
        guard case let .available(source) = await sourcePort.load(selection),
              source.selection == selection, source.isValid
        else { return }
        selectedSource = source
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
        guard !libraryNavigationReserved,
              action == .prepare || action == .reinstall,
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
            case let .written(written):
                guard written.reconciliationIdentity == candidate.reconciliationIdentity,
                      written.state == .queued
                else { break }
                acceptedJob = written
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
        let runningWrite = await jobs.transition(job, from: queued)
        guard case .written = runningWrite else {
            await followLaunchMutationOutcome(
                DurableMutationOutcome(runningWrite),
                job: job,
                expected: queued,
                source: source
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
        } catch let failure as TranscriptionEngineFailure {
            if cancelledRunJobID == jobID { return }
            if failure == .workerAbsenceUnconfirmed {
                transition(to: .recoveryRequired(job))
                return
            }
            let outcome = await fail(
                job: job,
                expected: .running,
                reason: .engineFailed
            )
            await followLaunchMutationOutcome(
                outcome,
                job: job,
                expected: .running,
                source: source
            )
            return
        } catch {
            if cancelledRunJobID == jobID { return }
            let outcome = await fail(
                job: job,
                expected: .running,
                reason: .engineFailed
            )
            await followLaunchMutationOutcome(
                outcome,
                job: job,
                expected: .running,
                source: source
            )
            return
        }
        guard cancelledRunJobID != jobID else { return }
        guard verified.candidate.candidateArtifactSHA256 ==
            verified.artifactFingerprint.sha256
        else {
            let outcome = await fail(
                job: job,
                expected: .running,
                reason: .candidateRejected
            )
            await followLaunchMutationOutcome(
                outcome,
                job: job,
                expected: .running,
                source: source
            )
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
            await followLaunchMutationOutcome(
                DurableMutationOutcome(candidateWrite),
                job: job,
                expected: running,
                source: source
            )
            return
        }
        transition(
            to: .validating(SessionProcessingActiveSnapshot(source: source, job: job))
        )
        let publicationOutcome = await publish(
            verified,
            source: source,
            profile: profile,
            evidence: evidence,
            job: job
        )
        await followLaunchMutationOutcome(
            publicationOutcome,
            job: job,
            expected: .validating,
            source: source
        )
    }

    private func followLaunchMutationOutcome(
        _ outcome: DurableMutationOutcome,
        job: SessionProcessingJob,
        expected: SessionProcessingJobState,
        source: SessionTranscriptionSource
    ) async {
        // Cancellation raises an exact-Job presentation fence before its CAS.
        // A late launch-path acknowledgement must not race or overwrite the
        // cancellation finalizer that already owns durable reconciliation.
        guard cancelledRunJobID != job.jobID else { return }
        switch outcome {
        case .settled:
            return
        case .stale:
            guard let winner = await loadExactWinner(
                afterStaleWriteFor: job,
                selection: source.selection
            ) else {
                transition(to: .recoveryRequired(job))
                return
            }
            await reconcile(winner, source: source)
        case .unconfirmed:
            // A failed acknowledgement does not prove whether the transition
            // committed. Follow an exact durable advance, but never retry the
            // mutation in-place when the old expected state is still current.
            if case .recoveryRequired = state { return }
            if let winner = await loadExactJob(
                jobID: job.jobID,
                selection: source.selection,
                matching: job
            ), winner.state != expected {
                await reconcile(winner, source: source)
            } else {
                presentPersistenceFailure(for: job)
            }
        }
    }

    private func reconcile(
        _ initial: SessionProcessingJob,
        source: SessionTranscriptionSource
    ) async {
        await recoverDurableJob(initial, context: .selectedSession(source))
    }

    @discardableResult
    private func resumeValidation(
        _ job: SessionProcessingJob,
        source: SessionTranscriptionSource,
        verified: VerifiedTranscriptionCandidate
    ) async -> DurableMutationOutcome? {
        // Publication is manifest-last: the exact immutable Revision may be
        // installed even when the publisher returned installedNeedsRefresh or
        // the validating->completed Job CAS failed. Prove this Job's Revision
        // first, independently of a later review selection, and never republish
        // it against the stale start-time selection baseline.
        if await completedRevisionMatches(job, source: source) {
            return await completeInstalledValidation(job, source: source)
        }
        guard case let .qualified(profile) = await runtime.resolve(),
              profile.profileID == job.profileID,
              case let .qualified(evidence) = await acoustics.resolve(
                  for: source,
                  profile: profile
              ),
              evidence.isValid(for: source, profile: profile)
        else {
            return nil
        }
        selectedProfile = profile
        transition(
            to: .validating(
                SessionProcessingActiveSnapshot(source: source, job: job)
            )
        )
        return await publish(
            verified,
            source: source,
            profile: profile,
            evidence: evidence,
            job: job
        )
    }

    private func proveStagedCandidate(
        for job: SessionProcessingJob
    ) async -> StagedCandidateProof {
        guard job.hasCapturedSelectionBaseline,
              let expectedHash = job.candidateArtifactSHA256
        else { return .invalid }
        switch await engine.recoverCandidate(for: job) {
        case let .available(candidate):
            guard candidate.artifactFingerprint.sha256 == expectedHash,
                  candidate.candidate.candidateArtifactSHA256 == expectedHash
            else { return .invalid }
            return .verified(candidate)
        case .unavailable, .integrityMismatch:
            return .invalid
        }
    }

    @discardableResult
    private func publish(
        _ verified: VerifiedTranscriptionCandidate,
        source: SessionTranscriptionSource,
        profile: QualifiedTranscriptionProfile,
        evidence: SessionVoicedRangeEvidence,
        job: SessionProcessingJob
    ) async -> DurableMutationOutcome {
        guard job.hasCapturedSelectionBaseline else {
            return await interrupt(job, source: source)
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
            let completionWrite = await jobs.transition(
                completed,
                from: .validating
            )
            guard case .written = completionWrite else {
                // The canonical selection has already committed. Launch
                // reconciliation propagates stale so it can follow the exact
                // winner; other callers preserve this validating recovery fence.
                return DurableMutationOutcome(completionWrite)
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
            return .settled
        case let .rejected(failure):
            if failure == .installedNeedsRefresh {
                // Repository contract: selection already switched, but its
                // mandatory reopen could not complete. Never rewrite this
                // validating Job to retryable failed; relaunch must prove and
                // reopen the exact installed Revision by Job identity.
                transition(to: .recoveryRequired(job))
                return .unconfirmed
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
            return await fail(job: job, expected: .validating, reason: reason)
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
              completedProvenanceMatches(job: job, revision: revision),
              revision.durationMilliseconds == source.durationMilliseconds,
              revision.audioFingerprint == source.audioFingerprint,
              revision.sourceFingerprints == source.sourceFingerprints,
              revision.candidateArtifactFingerprint.sha256 ==
                job.candidateArtifactSHA256
        else { return false }
        return true
    }

    private func completedProvenanceMatches(
        job: SessionProcessingJob,
        revision: TranscriptRevision
    ) -> Bool {
        if let qualification = revision.engine.qualification {
            return job.hasCapturedSelectionBaseline &&
                job.cancellationAuthorityID != nil &&
                qualification.qualificationProfileID == job.profileID
        }
        // Qualification is deliberately absent only on a byte-preserved
        // schema-v1 Revision. Pair it exclusively with a schema-v1 Job; this
        // read compatibility does not create runtime execution authority.
        return !job.hasCapturedSelectionBaseline &&
            job.cancellationAuthorityID == nil
    }

    @discardableResult
    private func completeInstalledValidation(
        _ job: SessionProcessingJob,
        source: SessionTranscriptionSource
    ) async -> DurableMutationOutcome {
        let completed = job.transitioning(to: .completed)
        let completionWrite = await jobs.transition(completed, from: .validating)
        guard case .written = completionWrite else {
            return DurableMutationOutcome(completionWrite)
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
        return .settled
    }

    @discardableResult
    private func interrupt(
        _ job: SessionProcessingJob,
        source: SessionTranscriptionSource
    ) async -> DurableMutationOutcome {
        let interrupted = job.transitioning(to: .interrupted)
        let interruptionWrite = await jobs.transition(interrupted, from: job.state)
        guard case .written = interruptionWrite else {
            return DurableMutationOutcome(interruptionWrite)
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
        return .settled
    }

    private func finishAbandoned(
        _ job: SessionProcessingJob,
        source: SessionTranscriptionSource
    ) async -> DurableMutationOutcome {
        guard job.cancellationRequestedAt != nil else {
            return await interrupt(job, source: source)
        }
        let cancelled = job.transitioning(to: .cancelled)
        let write = await jobs.transition(cancelled, from: job.state)
        guard case .written = write else {
            return DurableMutationOutcome(write)
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
        return .settled
    }

    @discardableResult
    private func fail(
        job: SessionProcessingJob,
        expected: SessionProcessingJobState,
        reason: SessionProcessingFailureReason
    ) async -> DurableMutationOutcome {
        let failed = job.transitioning(to: .failed, failure: reason)
        let failureWrite = await jobs.transition(failed, from: expected)
        // Cancel can enter while a running-terminal CAS is suspended. Once it
        // raises this run's fence, its exact-Job refresh owns presentation of
        // that first durable winner; a late acknowledgement must not invent
        // jobPersistenceFailed. A validating publication failure is downstream
        // of the candidate winner and must still become visible.
        guard expected != .running || cancelledRunJobID != job.jobID else {
            return DurableMutationOutcome(failureWrite)
        }
        guard case .written = failureWrite else {
            return DurableMutationOutcome(failureWrite)
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
        return .settled
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
        let completionWrite = await jobs.transition(cancelled, from: requested.state)
        guard case .written = completionWrite else {
            switch DurableMutationOutcome(completionWrite) {
            case .settled:
                preconditionFailure("handled by guard")
            case .stale:
                guard let winner = await loadExactWinner(
                    afterStaleWriteFor: requested,
                    selection: active.source.selection
                ) else {
                    transition(to: .recoveryRequired(requested))
                    await finishCancellationFinalization()
                    return
                }
                await reconcile(winner, source: active.source)
            case .unconfirmed:
                if let winner = await loadExactJob(
                    jobID: requested.jobID,
                    selection: active.source.selection,
                    matching: requested
                ), winner.state != requested.state {
                    await reconcile(winner, source: active.source)
                } else {
                    presentPersistenceFailure(for: requested)
                }
            }
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
        guard let current = await loadExactWinner(
            afterStaleWriteFor: active.job,
            selection: active.source.selection
        ),
              current != active.job
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
        while let activation = pendingLibraryActivation {
            pendingLibraryActivation = nil
            await reconcileActiveLibrary(activation)
        }
        await finishCancellationFinalization()
    }

    private func retainLatestSelectionCommand(_ command: SessionProcessingCommand) {
        switch command {
        case .activateLibrary:
            break
        case let .activateLibraryAuthority(activation):
            pendingLibraryActivation = activation
        case let .selectSession(selection):
            pendingSelectionCommand = .select(selection)
        case .clearSelection:
            pendingSelectionCommand = .clear
        case .start, .cancel, .retry, .prepare, .reinstall:
            break
        }
    }

    private func takePendingContextCommand() -> SessionProcessingCommand? {
        if let activation = pendingLibraryActivation {
            pendingLibraryActivation = nil
            return .activateLibraryAuthority(activation)
        }
        defer { pendingSelectionCommand = nil }
        return pendingSelectionCommand?.command
    }

    private func finishCancellationFinalization() async {
        cancellationFinalizationInFlight = false
        guard !commandInFlight,
              pendingSelectionCommand != nil || pendingLibraryActivation != nil
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
        guard !libraryNavigationReserved,
              !selectedSessionHasPendingActivationAuthority,
              selectedLibraryHasCompletedReconciliation
        else { return false }
        return switch state {
        case .ready, .completed: true
        case .unavailable, .preparing, .queued, .running, .cancelling,
             .validating, .failed, .cancelled, .interrupted, .recoveryRequired:
            false
        }
    }

    private var selectedSessionHasPendingActivationAuthority: Bool {
        guard let lastSelection else { return false }
        let key = CompletedRecoveryKey(lastSelection)
        return invalidCompletedJobs[key] != nil ||
            activationRecovery[key]?.isEmpty == false
    }

    private var acceptsRefreshedRetryLaunch: Bool {
        guard !libraryNavigationReserved,
              selectedLibraryHasCompletedReconciliation
        else { return false }
        return switch state {
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

    private var selectedLibraryHasCompletedReconciliation: Bool {
        guard hasObservedLibraryActivation else { return true }
        guard libraryReconciliationFence == nil,
              let activation = latestLibraryActivation,
              let lastSelection,
              activation.scope == lastSelection.scope
        else {
            return false
        }
        return successfullyReconciledLibraryActivation == activation
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
        case .noSession, .jobIndexSchemaNewer, .jobIndexUnavailable,
             .jobIndexIntegrityMismatch, .jobIndexIncomplete:
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
        guard !suppressStateTransitions else {
            retainSuppressedActivationRecovery(next)
            return
        }
        state = next
        for continuation in stateContinuations.values { continuation.yield(next) }
    }

    private func retainActivationRecovery(
        _ recovery: ActivationRecovery,
        for job: SessionProcessingJob
    ) {
        guard let scope = activeReconciliationActivation?.scope else { return }
        let key = CompletedRecoveryKey(
            SessionProcessingSelection(scope: scope, sessionID: job.sessionID)
        )
        var ledger = activationRecovery[key] ?? ActivationRecoveryLedger()
        ledger.retain(recovery)
        activationRecovery[key] = ledger
    }

    private func supersedeExactActivationWinner(
        for selection: SessionProcessingSelection
    ) {
        let key = CompletedRecoveryKey(selection)
        guard var ledger = activationRecovery[key] else { return }
        ledger.supersedeExactWinner()
        if ledger.isEmpty {
            activationRecovery.removeValue(forKey: key)
        } else {
            activationRecovery[key] = ledger
        }
    }

    private func resolveUnconfirmedActivationRecovery(
        for job: SessionProcessingJob
    ) {
        guard let scope = activeReconciliationActivation?.scope else { return }
        let key = CompletedRecoveryKey(
            SessionProcessingSelection(scope: scope, sessionID: job.sessionID)
        )
        guard var ledger = activationRecovery[key] else { return }
        ledger.resolveUnconfirmedJob(job.jobID)
        if ledger.isEmpty {
            activationRecovery.removeValue(forKey: key)
        } else {
            activationRecovery[key] = ledger
        }
    }

    private func takeExactActivationWinner(
        for key: CompletedRecoveryKey
    ) -> SessionProcessingJob? {
        guard var ledger = activationRecovery[key],
              let winner = ledger.exactWinner
        else { return nil }
        ledger.supersedeExactWinner()
        if ledger.isEmpty {
            activationRecovery.removeValue(forKey: key)
        } else {
            activationRecovery[key] = ledger
        }
        return winner
    }

    /// Complete activation inventories are capped at
    /// `maximumReconciledJobCount`; sorting the retained one-per-Session
    /// winners is therefore deterministic and bounded independently of the
    /// repository's cross-Session inventory order.
    private func deterministicRecoveredSelection(
        for scope: LibraryScope
    ) -> SessionProcessingSelection? {
        let libraryID = scope.libraryID.rawValue
        let invalidCompletedSelections: [SessionProcessingSelection] =
            invalidCompletedJobs.compactMap { key, job in
            guard key.libraryID == libraryID else { return nil }
            return SessionProcessingSelection(
                scope: scope,
                sessionID: job.sessionID
            )
        }
        let retainedRecoverySelections: [SessionProcessingSelection] =
            activationRecovery.compactMap { key, ledger in
            guard key.libraryID == libraryID else {
                return nil
            }
            if let job = ledger.recoveryRequiredJob {
                return SessionProcessingSelection(
                    scope: scope,
                    sessionID: job.sessionID
                )
            }
            guard let job = ledger.exactWinner else { return nil }
            switch job.state {
            case .validating, .failed, .cancelled, .interrupted:
                return SessionProcessingSelection(
                    scope: scope,
                    sessionID: job.sessionID
                )
            case .queued, .preparing, .running, .completed:
                return nil
            }
        }
        return (invalidCompletedSelections + retainedRecoverySelections).min {
            $0.sessionID.rawValue < $1.sessionID.rawValue
        }
    }

    private func projectDeterministicActivationRecovery(
        _ selection: SessionProcessingSelection
    ) async {
        let key = CompletedRecoveryKey(selection)
        if let deferred = activationRecovery[key]?.exactWinner,
           deferred.state == .validating
        {
            lastSelection = selection
            selectedSource = nil
            selectedProfile = nil
            transition(to: .recoveryRequired(deferred))
            return
        }
        await select(selection)
    }

    private func retainSuppressedActivationRecovery(
        _ next: SessionProcessingFeatureState
    ) {
        switch next {
        case let .recoveryRequired(job):
            retainActivationRecovery(.unconfirmed(job), for: job)
        case let .failed(snapshot):
            guard let job = snapshot.job else { return }
            retainActivationRecovery(
                snapshot.reason == .jobPersistenceFailed
                    ? .unconfirmed(job)
                    : .exactWinner(job),
                for: job
            )
        case let .cancelled(snapshot), let .interrupted(snapshot):
            retainActivationRecovery(.exactWinner(snapshot.job), for: snapshot.job)
        case .unavailable, .ready, .preparing, .queued, .running, .cancelling,
             .validating, .completed:
            return
        }
    }
}
