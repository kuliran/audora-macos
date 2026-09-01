import AudoraDomain

public enum SessionTranscriptionSourceResult: Equatable, Sendable {
    case available(SessionTranscriptionSource)
    case unavailable
    case integrityMismatch
}

public protocol SessionTranscriptionSourcePort: Sendable {
    func load(_ selection: SessionProcessingSelection) async
        -> SessionTranscriptionSourceResult

    /// Resolves through the exact retained Library authority that produced a
    /// durable-Job inventory. Reacquiring an ambient same-ID Library is not
    /// permitted when that authority has expired.
    func load(
        _ selection: SessionProcessingSelection,
        reconciliationID: SessionProcessingReconciliationID
    ) async -> SessionTranscriptionSourceResult
}

public extension SessionTranscriptionSourcePort {
    func load(
        _ selection: SessionProcessingSelection,
        reconciliationID: SessionProcessingReconciliationID
    ) async -> SessionTranscriptionSourceResult { .unavailable }
}

public enum SessionAcousticEvidenceResolution: Equatable, Sendable {
    case qualified(SessionVoicedRangeEvidence)
    case unavailable
}

public protocol SessionAcousticEvidencePort: Sendable {
    func resolve(
        for source: SessionTranscriptionSource,
        profile: QualifiedTranscriptionProfile
    ) async -> SessionAcousticEvidenceResolution
}

public enum TranscriptionRuntimeResolution: Equatable, Sendable {
    case qualified(QualifiedTranscriptionProfile)
    case unavailable(SessionProcessingUnavailableReason)
}

public protocol TranscriptionRuntimePort: Sendable {
    /// Returns a qualified profile only after exact runtime/model-lock and
    /// qualification evidence verification. It never substitutes an engine.
    func resolve() async -> TranscriptionRuntimeResolution

    func prepare(_ action: SessionProcessingRecoveryAction) async
        -> TranscriptionRuntimeResolution

    /// Returns a process-local capability only for the exact profile retained
    /// by the successful qualification result.
    func executionCapability(
        for profile: QualifiedTranscriptionProfile
    ) async -> VerifiedTranscriptionRuntime?
}

public enum TranscriptionModelResolution: Equatable, Sendable {
    case ready
    case missing
    case corrupt
    case lockMismatch
}

public protocol TranscriptionModelPort: Sendable {
    func verify(_ profile: QualifiedTranscriptionProfile) async
        -> TranscriptionModelResolution

    func prepare(
        _ action: SessionProcessingRecoveryAction,
        profile: QualifiedTranscriptionProfile
    ) async -> TranscriptionModelResolution

    /// Returns the descriptor-retained model snapshot created by the most
    /// recent successful verification. No path crosses this boundary.
    func executionCapability(
        for profile: QualifiedTranscriptionProfile
    ) async -> VerifiedTranscriptionModel?
}

public enum SessionProcessingJobWriteResult: Equatable, Sendable {
    case written(SessionProcessingJob)
    case collision
    case stale
    case failed
}

public enum SessionProcessingJobLoadResult: Equatable, Sendable {
    case none
    case loaded(SessionProcessingJob)
    /// The authoritative attempt index was written by a newer Audora. Durable
    /// Jobs remain untouched and processing stays frozen until a compatible app
    /// opens the Library.
    case unsupportedSchema(version: UInt32)
    case unavailable
    case integrityMismatch
}

public enum SessionProcessingJobInventoryResult: Equatable, Sendable {
    case available(SessionProcessingJobInventory)
    /// Distinct from corruption: callers must not reconcile independently
    /// readable Jobs when their newer causal index cannot be interpreted.
    case unsupportedSchema(version: UInt32)
    case unavailable
    case integrityMismatch
}

public protocol SessionProcessingJobPort: Sendable {
    func inventory(
        for scope: LibraryScope
    ) async -> SessionProcessingJobInventoryResult

    func finishReconciliation(
        _ reconciliationID: SessionProcessingReconciliationID
    ) async

    func latest(for selection: SessionProcessingSelection) async
        -> SessionProcessingJobLoadResult

    /// Loads one durable Job by immutable identity. This must never substitute
    /// a newer Job for the same Session after a compare-and-swap race.
    func load(
        jobID: TranscriptionJobID,
        for selection: SessionProcessingSelection
    ) async -> SessionProcessingJobLoadResult

    func create(_ job: SessionProcessingJob) async -> SessionProcessingJobWriteResult

    /// Durable compare-and-swap. Infrastructure must reject a different current
    /// state rather than replacing it unconditionally.
    func transition(
        _ job: SessionProcessingJob,
        from expected: SessionProcessingJobState
    ) async -> SessionProcessingJobWriteResult
}

public extension SessionProcessingJobPort {
    func inventory(
        for scope: LibraryScope
    ) async -> SessionProcessingJobInventoryResult { .unavailable }

    func finishReconciliation(
        _ reconciliationID: SessionProcessingReconciliationID
    ) async {}
}

public protocol TranscriptionEngine: Sendable {
    /// Returns exactly one complete, bounded, hash-verified but semantically
    /// untrusted Candidate, or throws one bounded failure.
    func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> VerifiedTranscriptionCandidate

    /// Idempotently requests cooperative stop, then bounded termination and
    /// reap. Success is returned only after process absence is proven.
    func cancel(
        _ execution: TranscriptionExecutionReference
    ) async -> TranscriptionCancellationOutcome

    func workerPresence(
        for execution: TranscriptionExecutionReference
    ) async -> TranscriptionWorkerPresence

    /// Reopens only a complete, confined, hash-valid Candidate staged by the
    /// exact durable Job. It never publishes or selects a Revision.
    func recoverCandidate(
        for job: SessionProcessingJob
    ) async -> StagedTranscriptionCandidateResolution
}

public extension TranscriptionEngine {
    func cancel(
        _ execution: TranscriptionExecutionReference
    ) async -> TranscriptionCancellationOutcome { .unableToConfirm }

    func workerPresence(
        for execution: TranscriptionExecutionReference
    ) async -> TranscriptionWorkerPresence { .unknown }

    func recoverCandidate(
        for job: SessionProcessingJob
    ) async -> StagedTranscriptionCandidateResolution { .unavailable }
}

public protocol SessionProcessingClock: Sendable {
    func now() async -> UTCInstant
}

public protocol SessionProcessingIDGenerator: Sendable {
    func generateJobID(at instant: UTCInstant) async -> TranscriptionJobID
    func generateRevisionID(at instant: UTCInstant) async -> TranscriptRevisionID
    func generateCancellationAuthorityID(
        at instant: UTCInstant
    ) async -> TranscriptionCancellationAuthorityID
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol SessionProcessingFeature: Sendable {
    var currentState: SessionProcessingFeatureState { get async }
    var states: AsyncStream<SessionProcessingFeatureState> { get }
    func send(_ command: SessionProcessingCommand) async

    /// Reconciles one exact process-local Library activation. A newer
    /// generation supersedes every older same-ID reconciliation completion.
    func activateLibrary(_ activation: LibraryActivation) async

    /// Atomically excludes Start/Retry/Prepare while Application coordinates a
    /// Library-selection mutation. Returns false when processing already owns
    /// active or recovery authority.
    func reserveLibraryNavigation() async -> Bool

    /// Releases the reservation. A successful Library mutation also clears the
    /// old Session selection before launch admission reopens.
    func finishLibraryNavigation(didMutateLibrary: Bool) async
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public extension SessionProcessingFeature {
    func activateLibrary(_ activation: LibraryActivation) async {
        await send(.activateLibraryAuthority(activation))
    }
}
