import "./transcript-revision.tsp";
import "@typespec/json-schema";

using TypeSpec.JsonSchema;

namespace Audora.Contracts {
  /** Minimal durable state for one Session transcription job. */
  @jsonSchema
  @id("TranscriptionJobManifest.json")
  union TranscriptionJobManifest {
    legacyV1: LegacyTranscriptionJobManifest,
    controlledV2: ControlledTranscriptionJobManifest,
  }

  model LegacyTranscriptionJobManifest extends TranscriptionJobManifestBody {
    schemaVersion: 1;
  }

  model ControlledTranscriptionJobManifest
    extends TranscriptionJobManifestBody {
    schemaVersion: 2;
    expectedSelectedRevisionId: TranscriptRevisionId | null;
    cancellationAuthorityId: TranscriptionCancellationAuthorityId;
    cancellationRequestedAt?: UTCInstant;
  }

  model TranscriptionJobManifestBody {
    jobId: TranscriptionJobId;
    sessionId: SessionId;
    revisionId: TranscriptRevisionId;
    profileId: TranscriptionProfileId;
    createdAt: UTCInstant;
    state: TranscriptionJobState;
    candidateArtifactSha256?: Sha256Hex;
    failure?: SessionProcessingFailure;
  }

  /** Complete bounded worker artifact, still semantically untrusted. */
  @jsonSchema
  @id("TranscriptionCandidateArtifact.json")
  model TranscriptionCandidateArtifact {
    schemaVersion: 1;
    jobId: TranscriptionJobId;
    sessionId: SessionId;
    revisionId: TranscriptRevisionId;
    durationMs: CanonicalDurationMilliseconds;
    audioFingerprintSha256: Sha256Hex;

    @minItems(1)
    @maxItems(32)
    sourceFingerprints: CandidateSourceFingerprint[];

    engine: CandidateEngineProvenance;

    @minItems(1)
    @maxItems(100000)
    lines: CandidateTranscriptLine[];

    @maxItems(100000)
    audioEvents: CandidateTranscriptAudioEvent[];
  }

  /** One offline invocation written to the worker's anonymous stdin. */
  @jsonSchema
  @id("TranscriptionWorkerRequest.json")
  model TranscriptionWorkerRequest {
    v: 1;
    type: "transcribe";
    jobId: TranscriptionJobId;
    sessionId: SessionId;
    revisionId: TranscriptRevisionId;
    durationMs: CanonicalDurationMilliseconds;
    qualificationProfileId: TranscriptionProfileId;
    engine: TranscriptionWorkerEngine;
    qualification: TranscriptionWorkerQualification;

    @minItems(1)
    @maxItems(1)
    sources: TranscriptionWorkerSource[];

    options: TranscriptionWorkerOptions;
    networkAccess: "disabled";
  }

  /** Closed set of bounded JSONL messages emitted on worker stdout. */
  @jsonSchema
  @id("TranscriptionWorkerMessage.json")
  union TranscriptionWorkerMessage {
    hello: TranscriptionWorkerHello,
    phase: TranscriptionWorkerPhase,
    progress: TranscriptionWorkerProgress,
    candidateReady: TranscriptionWorkerCandidateReady,
    failed: TranscriptionWorkerFailed,
  }

  /** Portable processing behavior and trust-boundary effects. */
  @jsonSchema
  @id("SessionProcessingFeatureScenario.json")
  model SessionProcessingFeatureScenario {
    schemaVersion: 1;
    scenarioId: SessionProcessingScenarioId;
    initialState: SessionProcessingScenarioState;

    @minItems(1)
    commands: SessionProcessingScenarioCommand[];

    dependencyTrace: SessionProcessingScenarioDependencyEvent[];
    expectedState: SessionProcessingScenarioState;

    @minItems(1)
    expectedEffects: SessionProcessingScenarioEffect[];
  }

  enum TranscriptionJobState {
    queued,
    preparing,
    running,
    validating,
    completed,
    failed,
    cancelled,
    interrupted,
  }

  enum SessionProcessingFailure {
    sourceUnavailable,
    jobPersistenceFailed,
    engineUnavailable,
    engineFailed,
    candidateRejected,
    publicationFailed,
    installedNeedsRefresh,
    canonicalRevisionIntegrityFailed,
    staleSelection,
  }

  @minLength(1)
  @maxLength(128)
  @pattern("^[0-9A-Za-z._-]+$")
  scalar TranscriptionProfileId extends string;

  @minLength(1)
  @maxLength(128)
  @pattern("^[0-9A-Za-z_-]+$")
  scalar TranscriptionCancellationAuthorityId extends string;

  model CandidateSourceFingerprint {
    audioSourceId: TranscriptAudioSourceId;
    sha256: Sha256Hex;
  }

  model CandidateEngineProvenance {
    provider: "crisperwhisper";
    `model`: "small";

    @minLength(1)
    @maxLength(128)
    @pattern("^[0-9A-Za-z._-]+$")
    revision: string;

    language: "en";
    mode: "verbatim";
    decodingOptionsSha256: Sha256Hex;
    qualification: TranscriptEngineQualification;
  }

  model CandidateTranscriptLine {
    lineId: TranscriptLineId;
    order: NonnegativeWholeNumber;
    audioSourceId: TranscriptAudioSourceId;
    startMs: CandidateTimeMilliseconds;
    endMs: CandidateTimeMilliseconds;

    @minLength(1)
    @maxLength(131072)
    text: string;

    @minItems(1)
    @maxItems(1000000)
    words: CandidateTranscriptWord[];
  }

  model CandidateTranscriptAudioEvent {
    audioEventId: TranscriptAudioEventId;
    category: AudioEventCategory;
    audioSourceId: TranscriptAudioSourceId;
    startMs: CandidateTimeMilliseconds;
    endMs: CandidateTimeMilliseconds;
  }

  model CandidateTranscriptWord {
    wordId: TranscriptWordId;
    ordinal: NonnegativeWholeNumber;

    @minLength(1)
    @maxLength(1024)
    text: string;

    @minValue(0)
    startUtf8Byte: integer;

    @minValue(0)
    endUtf8Byte: integer;

    startMs: CandidateTimeMilliseconds | null;
    endMs: CandidateTimeMilliseconds | null;

    @minValue(0)
    @maxValue(1)
    confidence: float64 | null;

    wordKind: TranscriptWordKind;
  }

  @minValue(0)
  @maxValue(2700000)
  scalar CandidateTimeMilliseconds extends integer;

  model TranscriptionWorkerEngine {
    provider: "crisperwhisper";
    `model`: "small";

    @minLength(1)
    @maxLength(128)
    @pattern("^[0-9A-Za-z._-]+$")
    revision: string;
  }

  model TranscriptionWorkerQualification {
    schemaVersion: 1;
    engineLockSha256: Sha256Hex;

    @minLength(1)
    @maxLength(128)
    @pattern("^[0-9A-Za-z._-]+$")
    runtimeIdentity: string;

    runtimeLockSha256: Sha256Hex;

    @minLength(1)
    @maxLength(128)
    @pattern("^[0-9A-Za-z._-]+$")
    compatibilityPatchId: string;
  }

  model TranscriptionWorkerSource {
    audioSourceId: TranscriptAudioSourceId;
    role: "microphone";
    path: "input/audio.wav";
    timelineOffsetMs: 0;
  }

  model TranscriptionWorkerOptions {
    language: "en";
    mode: "verbatim";
    wordTimestamps: true;
  }

  model TranscriptionWorkerMessageBase {
    v: 1;
    jobId: TranscriptionJobId;
  }

  /** Startup identity emitted before any Job or private input is granted. */
  model TranscriptionWorkerHello {
    v: 1;
    type: "hello";
    qualificationProfileId: TranscriptionProfileId;
    engineLockSha256: Sha256Hex;

    @minLength(1)
    @maxLength(128)
    @pattern("^[0-9A-Za-z._-]+$")
    runtimeIdentity: string;

    runtimeLockSha256: Sha256Hex;

    @minLength(1)
    @maxLength(128)
    @pattern("^[0-9A-Za-z._-]+$")
    modelRevision: string;

    @minLength(1)
    @maxLength(128)
    @pattern("^[0-9A-Za-z._-]+$")
    compatibilityPatchId: string;
  }

  model TranscriptionWorkerPhase extends TranscriptionWorkerMessageBase {
    type: "phase";
    phase: "loading_model" | "transcribing";
  }

  model TranscriptionWorkerProgress extends TranscriptionWorkerMessageBase {
    type: "progress";

    @minValue(0)
    completed: integer;

    @minValue(1)
    total: integer;

    unit: "window";

    @minValue(0)
    etaSeconds?: integer;
  }

  model TranscriptionWorkerCandidateReady
    extends TranscriptionWorkerMessageBase {
    type: "candidate_ready";
    result: "result.json";
    sha256: Sha256Hex;
  }

  model TranscriptionWorkerFailed extends TranscriptionWorkerMessageBase {
    type: "failed";
    error: TranscriptionWorkerError;
  }

  model TranscriptionWorkerError {
    @minLength(1)
    @maxLength(64)
    code: string;

    retryable: boolean;
  }

  @pattern("^session-processing\\.[a-z0-9]+(?:-[a-z0-9]+)*$")
  scalar SessionProcessingScenarioId extends string;

  union SessionProcessingScenarioState {
    unavailable: SessionProcessingScenarioUnavailableState,
    ready: SessionProcessingScenarioReadyState,
    queued: SessionProcessingScenarioQueuedState,
    running: SessionProcessingScenarioRunningState,
    cancelling: SessionProcessingScenarioCancellingState,
    validating: SessionProcessingScenarioValidatingState,
    completed: SessionProcessingScenarioCompletedState,
    failed: SessionProcessingScenarioFailedState,
    cancelled: SessionProcessingScenarioCancelledState,
    interrupted: SessionProcessingScenarioInterruptedState,
    recoveryRequired: SessionProcessingScenarioRecoveryRequiredState,
  }

  model SessionProcessingScenarioUnavailableState {
    status: "unavailable";
    reason:
      | "noSession"
      | "qualificationBlocked"
      | "runtimeMissing"
      | "runtimeLockMismatch"
      | "modelMissing"
      | "modelCorrupt"
      | "modelLockMismatch"
      | "acousticEvidenceUnavailable";
    actions: SessionProcessingRecoveryAction[];
  }

  model SessionProcessingScenarioReadyState {
    status: "ready";
  }

  model SessionProcessingScenarioQueuedState {
    status: "queued";
    jobId: TranscriptionJobId;
    actions: SessionProcessingRecoveryAction[];
  }

  model SessionProcessingScenarioRunningState {
    status: "running";
    jobId: TranscriptionJobId;
    phase: "preparing" | "loadingModel" | "transcribing";
    progress?: SessionProcessingScenarioProgress;
    actions: SessionProcessingControlAction[];
  }

  model SessionProcessingScenarioCancellingState {
    status: "cancelling";
    jobId: TranscriptionJobId;
    actions: SessionProcessingControlAction[];
  }

  model SessionProcessingScenarioValidatingState {
    status: "validating";
    jobId: TranscriptionJobId;
  }

  model SessionProcessingScenarioCompletedState {
    status: "completed";

    /** Exact immutable Revision owned by the completed Job. */
    revisionId: TranscriptRevisionId;

    /** Current Session selection, which may be absent or point at another Revision. */
    selectedRevisionId: TranscriptRevisionId | null;
  }

  model SessionProcessingScenarioFailedState {
    status: "failed";
    reason: SessionProcessingFailure;
    actions: SessionProcessingRecoveryAction[];
  }

  model SessionProcessingScenarioCancelledState {
    status: "cancelled";
    jobId: TranscriptionJobId;
    actions: SessionProcessingRecoveryAction[];
  }

  model SessionProcessingScenarioInterruptedState {
    status: "interrupted";
    jobId: TranscriptionJobId;
    actions: SessionProcessingRecoveryAction[];
  }

  model SessionProcessingScenarioRecoveryRequiredState {
    status: "recoveryRequired";
    jobId: TranscriptionJobId;
    actions: SessionProcessingRecoveryAction[];
  }

  model SessionProcessingScenarioProgress {
    @minValue(0)
    completedWindows: integer;

    @minValue(1)
    totalWindows: integer;

    @minValue(0)
    approximateEtaSeconds?: integer;
  }

  enum SessionProcessingRecoveryAction {
    prepare,
    reinstall,
    retry,
  }

  enum SessionProcessingControlAction {
    cancel,
  }

  model SessionProcessingScenarioCommand {
    kind:
      | "activateLibrary"
      | "selectSession"
      | "clearSelection"
      | "start"
      | "cancel"
      | "prepare"
      | "reinstall"
      | "retry";
  }

  model SessionProcessingScenarioDependencyEvent {
    port:
      | "source"
      | "jobs"
      | "runtime"
      | "model"
      | "acousticEvidence"
      | "clock"
      | "identifiers"
      | "engine"
      | "publisher";
    effect:
      | "load"
      | "inventory"
      | "latest"
      | "resolve"
      | "prepare"
      | "verify"
      | "now"
      | "generateJobId"
      | "generateRevisionId"
      | "generateCancellationAuthorityId"
      | "create"
      | "transitionRunning"
      | "persistCancellationRequest"
      | "cancelAndReap"
      | "workerPresence"
      | "recoverCandidate"
      | "transcribe"
      | "transitionValidating"
      | "publish"
      | "reopenRevision"
      | "transitionCompleted"
      | "transitionFailed"
      | "transitionCancelled"
      | "transitionInterrupted";

    @minLength(1)
    @maxLength(128)
    outcome: string;
  }

  model SessionProcessingScenarioEffect {
    kind:
      | "networkDisabled"
      | "exactProfileOnly"
      | "oneUntrustedCandidate"
      | "publishedThroughValidator"
      | "selectedAtomically"
      | "noJobCreated"
      | "noEngineLaunch"
      | "noPublication"
      | "noFallback"
      | "cancellationAuthorityPersisted"
      | "workerReaped"
      | "lateCandidateRejected"
      | "sessionRetained"
      | "processAbsenceConfirmed"
      | "queuedInterrupted"
      | "stagedCandidateRevalidated"
      | "publicationIdempotent"
      | "canonicalRevisionReopened"
      | "allDurableJobsReconciled"
      | "startSelectionBaselinePreserved"
      | "staleSelectionRejected"
      | "progressMonotonic"
      | "etaApproximate";
  }
}
