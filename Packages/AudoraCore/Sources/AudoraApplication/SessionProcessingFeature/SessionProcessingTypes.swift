import AudoraDomain

public enum SessionProcessingConfigurationError: Error, Equatable, Sendable {
    case invalidProfile
}

/// The exact runtime/model/use-policy tuple admitted to offline transcription.
/// A non-null compatibility patch is required, so a qualification lock whose
/// patch remains unresolved cannot be represented as qualified.
public struct QualifiedTranscriptionProfile: Equatable, Sendable {
    public let profileID: String
    public let protocolVersion: UInt32
    public let runtimeVersion: String
    public let packageLockSHA256: String
    public let modelRevision: String
    public let compatibilityPatchID: String
    public let engine: TranscriptEngineProvenance

    public let qualification: TranscriptEngineQualification

    public init(
        profileID: String,
        protocolVersion: UInt32,
        runtimeVersion: String,
        packageLockSHA256: String,
        modelRevision: String,
        compatibilityPatchID: String,
        engine: TranscriptEngineProvenance
    ) throws {
        guard let qualification = engine.qualification,
              Self.isBoundedIdentifier(profileID),
              protocolVersion == 1,
              Self.isBoundedIdentifier(runtimeVersion),
              AudioArtifactFingerprint.isSHA256(packageLockSHA256),
              Self.isBoundedIdentifier(modelRevision),
              Self.isBoundedIdentifier(compatibilityPatchID),
              engine.revision == modelRevision,
              qualification.qualificationProfileID == profileID,
              qualification.runtimeIdentity == runtimeVersion,
              qualification.runtimeLockSHA256 == packageLockSHA256,
              qualification.compatibilityPatchID == compatibilityPatchID
        else {
            throw SessionProcessingConfigurationError.invalidProfile
        }
        self.profileID = profileID
        self.protocolVersion = protocolVersion
        self.runtimeVersion = runtimeVersion
        self.packageLockSHA256 = packageLockSHA256
        self.modelRevision = modelRevision
        self.compatibilityPatchID = compatibilityPatchID
        self.engine = engine
        self.qualification = qualification
    }

    private static func isBoundedIdentifier(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}

public struct SessionProcessingSelection: Equatable, Sendable {
    public let scope: LibraryScope
    public let sessionID: SessionID

    public init(scope: LibraryScope, sessionID: SessionID) {
        self.scope = scope
        self.sessionID = sessionID
    }
}

/// Opaque authority for the exact qualified runtime retained by
/// Infrastructure. The identifier is process-local and is never persisted as
/// derivation provenance.
public struct TranscriptionRuntimeCapabilityID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard Self.isValid(rawValue) else {
            throw SessionProcessingConfigurationError.invalidProfile
        }
        self.rawValue = rawValue
    }

    private static func isValid(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

public struct VerifiedTranscriptionRuntime: Equatable, Sendable {
    public let capabilityID: TranscriptionRuntimeCapabilityID
    public let profileID: String
    public let runtimeIdentity: String

    public init(
        capabilityID: TranscriptionRuntimeCapabilityID,
        profileID: String,
        runtimeIdentity: String
    ) {
        self.capabilityID = capabilityID
        self.profileID = profileID
        self.runtimeIdentity = runtimeIdentity
    }

    public func isValid(for profile: QualifiedTranscriptionProfile) -> Bool {
        profileID == profile.profileID &&
            runtimeIdentity == profile.runtimeVersion
    }
}

/// Opaque authority for the already-hashed, descriptor-retained model file
/// set. Application can match it to the qualified profile but cannot obtain a
/// filesystem path.
public struct TranscriptionModelCapabilityID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard (1...128).contains(rawValue.utf8.count), rawValue.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else {
            throw SessionProcessingConfigurationError.invalidProfile
        }
        self.rawValue = rawValue
    }
}

public struct VerifiedTranscriptionModel: Equatable, Sendable {
    public let capabilityID: TranscriptionModelCapabilityID
    public let profileID: String
    public let modelRevision: String

    public init(
        capabilityID: TranscriptionModelCapabilityID,
        profileID: String,
        modelRevision: String
    ) {
        self.capabilityID = capabilityID
        self.profileID = profileID
        self.modelRevision = modelRevision
    }

    public func isValid(for profile: QualifiedTranscriptionProfile) -> Bool {
        profileID == profile.profileID &&
            modelRevision == profile.modelRevision
    }
}

/// Opaque authority for the exact canonical audio bytes verified by
/// Infrastructure. The value is deliberately not a path: Application only
/// carries it from source reconstruction to the offline-engine request.
public struct SessionTranscriptionAudioCapabilityID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard (1...128).contains(rawValue.utf8.count), rawValue.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else {
            throw SessionProcessingConfigurationError.invalidProfile
        }
        self.rawValue = rawValue
    }
}

/// Trusted sealed-audio facts reread by Infrastructure. No filesystem path or
/// worker artifact crosses the Application interface.
public struct SessionTranscriptionSource: Equatable, Sendable {
    public let selection: SessionProcessingSelection
    public let audioCapabilityID: SessionTranscriptionAudioCapabilityID
    public let durationMilliseconds: UInt64
    public let audioFingerprint: AudioFingerprint
    public let sourceFingerprints: [TranscriptSourceFingerprint]
    public let expectedSelectedRevisionID: TranscriptRevisionID?

    public init(
        selection: SessionProcessingSelection,
        audioCapabilityID: SessionTranscriptionAudioCapabilityID,
        durationMilliseconds: UInt64,
        audioFingerprint: AudioFingerprint,
        sourceFingerprints: [TranscriptSourceFingerprint],
        expectedSelectedRevisionID: TranscriptRevisionID?
    ) {
        self.selection = selection
        self.audioCapabilityID = audioCapabilityID
        self.durationMilliseconds = durationMilliseconds
        self.audioFingerprint = audioFingerprint
        self.sourceFingerprints = sourceFingerprints
        self.expectedSelectedRevisionID = expectedSelectedRevisionID
    }

    var isValid: Bool {
        guard durationMilliseconds > 0 && durationMilliseconds <= 2_700_000 &&
            !sourceFingerprints.isEmpty && sourceFingerprints.count <= 32 &&
            Set(sourceFingerprints.map(\.audioSourceID)).count == sourceFingerprints.count
        else { return false }
        return true
    }
}

/// Qualified, bounded acoustic evidence is a separate platform result—not a
/// persistence heuristic. Its provenance identifies the reviewed extractor
/// admitted for the exact engine profile.
public struct SessionVoicedRangeEvidence: Equatable, Sendable {
    public let qualificationProfileID: String
    public let extractorID: String
    public let audioFingerprint: AudioFingerprint
    public let voicedRanges: [SessionTimeRange]

    public init(
        qualificationProfileID: String,
        extractorID: String,
        audioFingerprint: AudioFingerprint,
        voicedRanges: [SessionTimeRange]
    ) {
        self.qualificationProfileID = qualificationProfileID
        self.extractorID = extractorID
        self.audioFingerprint = audioFingerprint
        self.voicedRanges = voicedRanges
    }

    func isValid(
        for source: SessionTranscriptionSource,
        profile: QualifiedTranscriptionProfile
    ) -> Bool {
        guard qualificationProfileID == profile.profileID,
              audioFingerprint == source.audioFingerprint,
              (1...128).contains(extractorID.utf8.count),
              extractorID.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) ||
                    (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
              }),
              !voicedRanges.isEmpty,
              voicedRanges.count <= TranscriptRevisionLimits.maximumVoicedRangeCount
        else { return false }
        var previousEnd: UInt64 = 0
        for range in voicedRanges {
            guard range.startMilliseconds >= previousEnd,
                  range.endMilliseconds <= source.durationMilliseconds
            else { return false }
            previousEnd = range.endMilliseconds
        }
        return true
    }
}

public enum SessionProcessingRecoveryAction: String, Equatable, Sendable {
    case prepare
    case reinstall
    case retry
}

public enum SessionProcessingUnavailableReason: Equatable, Sendable {
    case noSession
    case sourceUnavailable
    case sourceIntegrityMismatch
    case acousticEvidenceUnavailable
    case qualificationBlocked(profileID: String)
    case runtimeMissing
    case runtimeLockMismatch
    case modelMissing
    case modelCorrupt
    case modelLockMismatch
}

public struct SessionProcessingUnavailableSnapshot: Equatable, Sendable {
    public let selection: SessionProcessingSelection?
    public let reason: SessionProcessingUnavailableReason
    public let actions: [SessionProcessingRecoveryAction]

    public init(
        selection: SessionProcessingSelection?,
        reason: SessionProcessingUnavailableReason,
        actions: [SessionProcessingRecoveryAction]
    ) {
        self.selection = selection
        self.reason = reason
        self.actions = actions
    }
}

public enum SessionProcessingJobState: String, Equatable, Sendable {
    case queued
    case preparing
    case running
    case validating
    case completed
    case failed
    case cancelled
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted: true
        case .queued, .preparing, .running, .validating: false
        }
    }
}

/// Durable, non-secret authority identity for controlling exactly one owned
/// worker execution. It is persisted with the Job so relaunch reconciliation
/// never guesses from a PID or an ambient process list.
public struct TranscriptionCancellationAuthorityID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard (1...128).contains(rawValue.utf8.count), rawValue.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else {
            throw SessionProcessingConfigurationError.invalidProfile
        }
        self.rawValue = rawValue
    }
}

/// The complete identity needed by the engine to cancel or reconcile one
/// worker. A legacy v1 Job may lack the authority; that absence must produce
/// `unknown`, never a guessed process match.
public struct TranscriptionExecutionReference: Hashable, Sendable {
    public let jobID: TranscriptionJobID
    public let cancellationAuthorityID: TranscriptionCancellationAuthorityID?

    public init(
        jobID: TranscriptionJobID,
        cancellationAuthorityID: TranscriptionCancellationAuthorityID?
    ) {
        self.jobID = jobID
        self.cancellationAuthorityID = cancellationAuthorityID
    }
}

public enum TranscriptionCancellationOutcome: Equatable, Sendable {
    case reaped
    case alreadyAbsent
    case unableToConfirm
}

public enum TranscriptionWorkerPresence: Equatable, Sendable {
    case present
    case absent
    case unknown
}

public enum StagedTranscriptionCandidateResolution: Equatable, Sendable {
    case available(VerifiedTranscriptionCandidate)
    case unavailable
    case integrityMismatch
}

public enum SessionProcessingFailureReason: String, Error, Equatable, Sendable {
    case sourceUnavailable
    case jobPersistenceFailed
    case engineUnavailable
    case engineFailed
    case candidateRejected
    case publicationFailed
    case installedNeedsRefresh
    case canonicalRevisionIntegrityFailed
    case staleSelection
}

public struct SessionProcessingJob: Equatable, Sendable {
    public let jobID: TranscriptionJobID
    public let sessionID: SessionID
    public let revisionID: TranscriptRevisionID
    public let profileID: String
    public let createdAt: UTCInstant
    public let state: SessionProcessingJobState
    /// The Session selection observed when this v2 Job was admitted. `nil` is
    /// a captured empty selection; `hasCapturedSelectionBaseline == false` is
    /// reserved for legacy v1 Jobs whose baseline is unknowable.
    public let expectedSelectedRevisionID: TranscriptRevisionID?
    public let hasCapturedSelectionBaseline: Bool
    public let cancellationAuthorityID: TranscriptionCancellationAuthorityID?
    public let cancellationRequestedAt: UTCInstant?
    public let candidateArtifactSHA256: String?
    public let failure: SessionProcessingFailureReason?

    public init(
        jobID: TranscriptionJobID,
        sessionID: SessionID,
        revisionID: TranscriptRevisionID,
        profileID: String,
        createdAt: UTCInstant,
        state: SessionProcessingJobState,
        expectedSelectedRevisionID: TranscriptRevisionID? = nil,
        cancellationAuthorityID: TranscriptionCancellationAuthorityID,
        cancellationRequestedAt: UTCInstant? = nil,
        candidateArtifactSHA256: String? = nil,
        failure: SessionProcessingFailureReason? = nil
    ) {
        self.jobID = jobID
        self.sessionID = sessionID
        self.revisionID = revisionID
        self.profileID = profileID
        self.createdAt = createdAt
        self.state = state
        self.expectedSelectedRevisionID = expectedSelectedRevisionID
        hasCapturedSelectionBaseline = true
        self.cancellationAuthorityID = cancellationAuthorityID
        self.cancellationRequestedAt = cancellationRequestedAt
        self.candidateArtifactSHA256 = candidateArtifactSHA256
        self.failure = failure
    }

    func transitioning(
        to state: SessionProcessingJobState,
        candidateArtifactSHA256: String? = nil,
        failure: SessionProcessingFailureReason? = nil
    ) -> SessionProcessingJob {
        if let cancellationAuthorityID {
            return SessionProcessingJob(
                jobID: jobID,
                sessionID: sessionID,
                revisionID: revisionID,
                profileID: profileID,
                createdAt: createdAt,
                state: state,
                expectedSelectedRevisionID: expectedSelectedRevisionID,
                cancellationAuthorityID: cancellationAuthorityID,
                cancellationRequestedAt: cancellationRequestedAt,
                candidateArtifactSHA256:
                    candidateArtifactSHA256 ?? self.candidateArtifactSHA256,
                failure: failure
            )
        }
        return .legacyV1(
            jobID: jobID,
            sessionID: sessionID,
            revisionID: revisionID,
            profileID: profileID,
            createdAt: createdAt,
            state: state,
            candidateArtifactSHA256:
                candidateArtifactSHA256 ?? self.candidateArtifactSHA256,
            failure: failure
        )
    }

    func requestingCancellation(at instant: UTCInstant) -> SessionProcessingJob? {
        guard let cancellationAuthorityID else { return nil }
        return SessionProcessingJob(
            jobID: jobID,
            sessionID: sessionID,
            revisionID: revisionID,
            profileID: profileID,
            createdAt: createdAt,
            state: state,
            expectedSelectedRevisionID: expectedSelectedRevisionID,
            cancellationAuthorityID: cancellationAuthorityID,
            cancellationRequestedAt: instant,
            candidateArtifactSHA256: candidateArtifactSHA256,
            failure: failure
        )
    }

    public var executionReference: TranscriptionExecutionReference {
        TranscriptionExecutionReference(
            jobID: jobID,
            cancellationAuthorityID: cancellationAuthorityID
        )
    }

    /// Explicit reader-only construction for immutable schema-v1 Jobs. New
    /// processing work must always use the authority-requiring initializer.
    public static func legacyV1(
        jobID: TranscriptionJobID,
        sessionID: SessionID,
        revisionID: TranscriptRevisionID,
        profileID: String,
        createdAt: UTCInstant,
        state: SessionProcessingJobState,
        candidateArtifactSHA256: String? = nil,
        failure: SessionProcessingFailureReason? = nil
    ) -> SessionProcessingJob {
        SessionProcessingJob(
            legacyJobID: jobID,
            sessionID: sessionID,
            revisionID: revisionID,
            profileID: profileID,
            createdAt: createdAt,
            state: state,
            candidateArtifactSHA256: candidateArtifactSHA256,
            failure: failure
        )
    }

    private init(
        legacyJobID jobID: TranscriptionJobID,
        sessionID: SessionID,
        revisionID: TranscriptRevisionID,
        profileID: String,
        createdAt: UTCInstant,
        state: SessionProcessingJobState,
        candidateArtifactSHA256: String?,
        failure: SessionProcessingFailureReason?
    ) {
        self.jobID = jobID
        self.sessionID = sessionID
        self.revisionID = revisionID
        self.profileID = profileID
        self.createdAt = createdAt
        self.state = state
        expectedSelectedRevisionID = nil
        hasCapturedSelectionBaseline = false
        cancellationAuthorityID = nil
        cancellationRequestedAt = nil
        self.candidateArtifactSHA256 = candidateArtifactSHA256
        self.failure = failure
    }
}

/// Process-local capability for one bounded durable-Job inventory. The
/// Infrastructure owner binds it to an exact active-Library generation and
/// retained root authority; Application never receives a filesystem path.
public enum SessionProcessingReconciliationIDError: Error, Equatable, Sendable {
    case invalidIdentifier
}

public struct SessionProcessingReconciliationID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard (1...128).contains(rawValue.utf8.count), rawValue.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else { throw SessionProcessingReconciliationIDError.invalidIdentifier }
        self.rawValue = rawValue
    }
}

public struct SessionProcessingJobInventory: Equatable, Sendable {
    public let reconciliationID: SessionProcessingReconciliationID
    public let scope: LibraryScope
    public let jobs: [SessionProcessingJob]
    /// False means Infrastructure could classify these exact valid Jobs but
    /// also encountered malformed siblings. Callers must reconcile `jobs` while
    /// retaining the Library-wide activation fence.
    public let isComplete: Bool

    public init(
        reconciliationID: SessionProcessingReconciliationID,
        scope: LibraryScope,
        jobs: [SessionProcessingJob],
        isComplete: Bool = true
    ) {
        self.reconciliationID = reconciliationID
        self.scope = scope
        self.jobs = jobs
        self.isComplete = isComplete
    }
}

public struct SessionProcessingReadySnapshot: Equatable, Sendable {
    public let source: SessionTranscriptionSource
    public let profileID: String?

    public init(source: SessionTranscriptionSource, profileID: String? = nil) {
        self.source = source
        self.profileID = profileID
    }
}

/// Honest user-visible phase for one admitted offline worker run. Model loading
/// and transcription are intentionally distinct because only the latter can
/// expose measurable window progress.
public enum SessionProcessingActivePhase: String, Equatable, Sendable {
    case preparing
    case loadingModel
    case transcribing
}

/// One accepted worker-window observation. ETA remains explicitly approximate
/// and is not clamped: a slower later window may truthfully increase it.
public struct SessionProcessingProgress: Equatable, Sendable {
    public let completedWindows: UInt32
    public let totalWindows: UInt32
    public let approximateETASeconds: UInt32?

    public init(
        completedWindows: UInt32,
        totalWindows: UInt32,
        approximateETASeconds: UInt32?
    ) {
        self.completedWindows = completedWindows
        self.totalWindows = totalWindows
        self.approximateETASeconds = approximateETASeconds
    }
}

public struct SessionProcessingActiveSnapshot: Equatable, Sendable {
    public let source: SessionTranscriptionSource
    public let job: SessionProcessingJob
    public let phase: SessionProcessingActivePhase
    public let progress: SessionProcessingProgress?

    public init(
        source: SessionTranscriptionSource,
        job: SessionProcessingJob,
        phase: SessionProcessingActivePhase = .preparing,
        progress: SessionProcessingProgress? = nil
    ) {
        self.source = source
        self.job = job
        self.phase = phase
        self.progress = progress
    }
}

public struct SessionProcessingRecoverableSnapshot: Equatable, Sendable {
    public let source: SessionTranscriptionSource
    public let job: SessionProcessingJob
    public let actions: [SessionProcessingRecoveryAction]

    public init(
        source: SessionTranscriptionSource,
        job: SessionProcessingJob,
        actions: [SessionProcessingRecoveryAction]
    ) {
        self.source = source
        self.job = job
        self.actions = actions
    }
}

public struct SessionProcessingCompletedSnapshot: Equatable, Sendable {
    public let sessionID: SessionID
    public let jobID: TranscriptionJobID
    /// The immutable Revision produced by this completed Job.
    public let revisionID: TranscriptRevisionID
    /// The Session's current selection at the source snapshot boundary. It can
    /// differ from `revisionID` after review, or be nil when nothing is selected.
    public let selectedRevisionID: TranscriptRevisionID?

    public init(
        sessionID: SessionID,
        jobID: TranscriptionJobID,
        revisionID: TranscriptRevisionID,
        selectedRevisionID: TranscriptRevisionID?
    ) {
        self.sessionID = sessionID
        self.jobID = jobID
        self.revisionID = revisionID
        self.selectedRevisionID = selectedRevisionID
    }
}

public struct SessionProcessingFailedSnapshot: Equatable, Sendable {
    public let job: SessionProcessingJob?
    public let reason: SessionProcessingFailureReason
    public let actions: [SessionProcessingRecoveryAction]

    public init(
        job: SessionProcessingJob?,
        reason: SessionProcessingFailureReason,
        actions: [SessionProcessingRecoveryAction]
    ) {
        self.job = job
        self.reason = reason
        self.actions = actions
    }
}

public enum SessionProcessingFeatureState: Equatable, Sendable {
    case unavailable(SessionProcessingUnavailableSnapshot)
    case ready(SessionProcessingReadySnapshot)
    case preparing(SessionProcessingReadySnapshot, SessionProcessingRecoveryAction)
    case queued(SessionProcessingRecoverableSnapshot)
    case running(SessionProcessingActiveSnapshot)
    case cancelling(SessionProcessingActiveSnapshot)
    case validating(SessionProcessingActiveSnapshot)
    case completed(SessionProcessingCompletedSnapshot)
    case failed(SessionProcessingFailedSnapshot)
    case cancelled(SessionProcessingRecoverableSnapshot)
    case interrupted(SessionProcessingRecoverableSnapshot)
    /// Issue #16 owns deterministic reconciliation of these nonterminal jobs.
    /// Issue #15 only exposes the durable seam without inventing a transition.
    case recoveryRequired(SessionProcessingJob)
}

public enum SessionProcessingCommand: Equatable, Sendable {
    /// System lifecycle command. It reconciles durable Jobs without selecting
    /// any Session in the user-facing processing panel.
    case activateLibrary(LibraryScope)
    case selectSession(SessionProcessingSelection)
    case clearSelection
    case start
    case cancel
    case prepare
    case reinstall
    case retry
}

public struct TranscriptionRequest: Equatable, Sendable {
    public let profile: QualifiedTranscriptionProfile
    public let runtimeCapability: VerifiedTranscriptionRuntime
    public let modelCapability: VerifiedTranscriptionModel
    public let audioCapabilityID: SessionTranscriptionAudioCapabilityID
    public let selection: SessionProcessingSelection
    public let jobID: TranscriptionJobID
    public let execution: TranscriptionExecutionReference
    public let revisionID: TranscriptRevisionID
    public let createdAt: UTCInstant
    public let profileID: String
    public let protocolVersion: UInt32
    public let runtimeVersion: String
    public let modelRevision: String
    public let compatibilityPatchID: String
    public let durationMilliseconds: UInt64
    public let audioFingerprint: AudioFingerprint
    public let sourceIDs: [AudioSourceID]

    public init(
        source: SessionTranscriptionSource,
        jobID: TranscriptionJobID,
        revisionID: TranscriptRevisionID,
        createdAt: UTCInstant,
        profile: QualifiedTranscriptionProfile,
        runtimeCapability: VerifiedTranscriptionRuntime,
        modelCapability: VerifiedTranscriptionModel,
        cancellationAuthorityID: TranscriptionCancellationAuthorityID
    ) {
        self.profile = profile
        self.runtimeCapability = runtimeCapability
        self.modelCapability = modelCapability
        audioCapabilityID = source.audioCapabilityID
        selection = source.selection
        self.jobID = jobID
        execution = TranscriptionExecutionReference(
            jobID: jobID,
            cancellationAuthorityID: cancellationAuthorityID
        )
        self.revisionID = revisionID
        self.createdAt = createdAt
        profileID = profile.profileID
        protocolVersion = profile.protocolVersion
        runtimeVersion = profile.runtimeVersion
        modelRevision = profile.modelRevision
        compatibilityPatchID = profile.compatibilityPatchID
        durationMilliseconds = source.durationMilliseconds
        audioFingerprint = source.audioFingerprint
        sourceIDs = source.sourceFingerprints.map(\.audioSourceID)
    }
}

public enum TranscriptionPhase: String, Equatable, Sendable {
    case loadingModel = "loading_model"
    case transcribing
}

public enum TranscriptionEvent: Equatable, Sendable {
    case phase(TranscriptionPhase)
    case progress(completed: UInt32, total: UInt32, etaSeconds: UInt32?)
}

/// Infrastructure has verified only confinement, completeness, bounded byte
/// count, and the detached artifact hash. The Candidate remains semantically
/// untrusted until `TranscriptCandidateValidator` accepts it.
public struct VerifiedTranscriptionCandidate: Equatable, Sendable {
    public let candidate: TranscriptionCandidate
    public let artifactFingerprint: AudioFingerprint

    public init(
        candidate: TranscriptionCandidate,
        artifactFingerprint: AudioFingerprint
    ) {
        self.candidate = candidate
        self.artifactFingerprint = artifactFingerprint
    }
}

public enum TranscriptionEngineFailure: String, Error, Equatable, Sendable {
    case profileMismatch
    case handshakeMismatch
    case malformedProtocol
    case outputLimitExceeded
    case candidateUnavailable
    case candidateIntegrityMismatch
    case launchFailed
    /// A launch boundary may have spawned the exact worker, but bounded reap
    /// could not prove it absent. The durable Job must remain nonterminal.
    case workerAbsenceUnconfirmed
    case workerFailed
    case cancelled
}
