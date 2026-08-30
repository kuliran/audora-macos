import "./portable-library.tsp";
import "@typespec/json-schema";

using TypeSpec.JsonSchema;

namespace Audora.Contracts {
  /** Session-owned canonical microphone Audio Asset metadata. */
  @jsonSchema
  @id("AudioManifest.json")
  model AudioManifest {
    schemaVersion: 1;
    sourceKind: "microphone";
    canonicalAudioPath: "audio/audio.wav";
    canonicalFormat: CanonicalAudioFormat;
    frameCount: PositiveRecordingFrameCount;
    canonicalSha256: Sha256Hex;

    @maxItems(8192)
    unavailableIntervals: UnavailableInterval[];
  }

  /** Session aggregate commit marker. */
  @jsonSchema
  @id("SessionManifest.json")
  model SessionManifest {
    schemaVersion: 1;
    sessionId: SessionId;
    createdAt: UTCInstant;
    audioManifestPath: "audio/audio.json";
  }

  /** Immutable identity root for exact recovery/discard authorization. */
  @jsonSchema
  @id("RecordingStagingIdentityManifest.json")
  model RecordingStagingIdentityManifest {
    schemaVersion: 1;
    recordingId: RecordingId;
    sessionId: SessionId;
    libraryId: LibraryId;
    startedAt: UTCInstant;
    canonicalFormat: CanonicalAudioFormat;
    maximumFrames: 43200000;
    recordStreamFormat: "audora-record-stream-v1";
  }

  /** Non-authoritative microphone Recording staging root. */
  @jsonSchema
  @id("RecordingStagingManifest.json")
  union RecordingStagingManifest {
    capturing: CapturingRecordingStaging,
    recoverable: RecoverableRecordingStaging,
    sealing: SealingRecordingStaging,
    publishing: PublishingRecordingStaging,
    committed: CommittedRecordingStaging,
  }

  /** Portable Recording feature behavior shared by implementations. */
  @jsonSchema
  @id("RecordingFeatureScenario.json")
  model RecordingFeatureScenario {
    schemaVersion: 1;
    scenarioId: RecordingScenarioId;
    initialState: RecordingScenarioSnapshot;

    @minItems(1)
    commands: RecordingScenarioCommand[];

    dependencyTrace: RecordingScenarioDependencyEvent[];
    expectedState: RecordingScenarioSnapshot;

    @minItems(1)
    expectedEffects: RecordingScenarioEffect[];
  }

  model CanonicalAudioFormat {
    sampleRateHz: 16000;
    channelCount: 1;
    encoding: "pcmS16LE";
  }

  @minValue(1)
  @maxValue(43200000)
  scalar PositiveRecordingFrameCount extends integer;

  model UnavailableInterval {
    startFrame: RecordingFrameOffset;
    endFrame: PositiveRecordingFrameCount;

    @minItems(1)
    @maxItems(2)
    reasons: UnavailableReason[];
  }

  @pattern("^ses-[0-9]{8}T[0-9]{9}Z-[0-9A-HJKMNP-TV-Z]{4}$")
  scalar SessionId extends string;

  @pattern("^rec-[0-9]{8}T[0-9]{9}Z-[0-9A-HJKMNP-TV-Z]{4}$")
  scalar RecordingId extends string;

  model CapturingRecordingStaging extends RecordingStagingBase {
    phase: "capturing";
  }

  model RecoverableRecordingStaging extends RecordingStagingBase {
    phase: "recoverable";
    availability: "sealOrDiscard" | "discardOnly";
  }

  model SealingRecordingStaging extends RecordingStagingBase {
    phase: "sealing";
    terminalReason: "userStop" | "durationLimit" | "interruption";
  }

  model PublishingRecordingStaging extends RecordingStagingBase {
    phase: "publishing";
    terminalReason: "userStop" | "durationLimit" | "interruption";
    canonicalSha256: Sha256Hex;
  }

  model CommittedRecordingStaging extends RecordingStagingBase {
    phase: "committed";
    terminalReason: "userStop" | "durationLimit" | "interruption";
    canonicalSha256: Sha256Hex;
  }

  @pattern("^recording\\.[a-z0-9]+(?:-[a-z0-9]+)*$")
  scalar RecordingScenarioId extends string;

  union RecordingScenarioSnapshot {
    unavailable: RecordingScenarioUnavailableSnapshot,
    selectingLibrary: RecordingScenarioSelectingLibrarySnapshot,
    idle: RecordingScenarioIdleSnapshot,
    starting: RecordingScenarioStartingSnapshot,
    activeOrdinary: RecordingScenarioActiveOrdinarySnapshot,
    activeWarning: RecordingScenarioActiveWarningSnapshot,
    activeCountdown: RecordingScenarioActiveCountdownSnapshot,
    activeLimit: RecordingScenarioActiveLimitSnapshot,
    finishing: RecordingScenarioFinishingSnapshot,
    sealing: RecordingScenarioSealingSnapshot,
    recoveryRequired: RecordingScenarioRecoveryRequiredSnapshot,
    resolvingRecovery: RecordingScenarioResolvingRecoverySnapshot,
    completed: RecordingScenarioCompletedSnapshot,
    failed: RecordingScenarioFailedSnapshot,
  }

  model RecordingScenarioCommand {
    kind:
      | "selectLibrary"
      | "record"
      | "mute"
      | "unmute"
      | "stop"
      | "cancel"
      | "keepRecording"
      | "discardRecording"
      | "sealRecovered"
      | "discardRecovered";
  }

  union RecordingScenarioDependencyEvent {
    inspectEmpty: RecordingInspectEmptyDependency,
    inspectItem: RecordingInspectItemDependency,
    beginStarted: RecordingBeginStartedDependency,
    beginDenied: RecordingBeginDeniedDependency,
    measuredProgress: RecordingMeasuredProgressDependency,
    unavailableProgress: RecordingUnavailableProgressDependency,
    setMuted: RecordingSetMutedDependency,
    muteChanged: RecordingMuteChangedDependency,
    normalizedIntervals: RecordingNormalizedIntervalsDependency,
    finishing: RecordingFinishingDependency,
    sealing: RecordingSealingDependency,
    sealed: RecordingSealedDependency,
    stop: RecordingStopDependency,
    discardConfirmed: RecordingDiscardConfirmedDependency,
    discarded: RecordingDiscardedDependency,
    recoveryRequired: RecordingRecoveryRequiredDependency,
    resolveSeal: RecordingResolveSealDependency,
  }

  model RecordingScenarioEffect {
    kind:
      | "captureStarted"
      | "liveLevelMeasured"
      | "muteCommandsAcknowledged"
      | "mutedLevelUnavailable"
      | "normalizedUnavailablePartition"
      | "gapLevelUnavailable"
      | "warningPersistsAfterBoundary"
      | "countdownUsesCeilingAtExactFrames"
      | "sessionSealedExactlyOnce"
      | "persistentDurationLimitExplanation"
      | "neverExceedsMaximumFrames"
      | "noPublicationBeforeCommittedReceipt"
      | "bothTerminalOrderingsDeterministic"
      | "twoTakesProduceTwoSeals"
      | "noDiscardCommand"
      | "timelineContinuesBehindConfirmation"
      | "discardedWithoutSeal"
      | "discardCommandSentOnce"
      | "discardFailureDoesNotClaimIdle"
      | "permissionFailurePublishesNothing"
      | "recoveryOffersSealAndDiscard"
      | "resumeAbsent"
      | "sameRecoveredSessionPublishedOnce"
      | "offerDiscardOnly"
      | "newRecordingAndSessionIdentity"
      | "firstSessionSealedOnce"
      | "lateEventsCannotMutateCompletion"
      | "librarySwitchBlockedWhileActive";
  }

  @minValue(0)
  @maxValue(43200000)
  scalar RecordingFrameOffset extends integer;

  enum UnavailableReason {
    muted,
    captureGap,
  }

  model RecordingStagingBase extends RecordingStagingIdentityManifest {
    durableFrameCount: RecordingFrameOffset;
  }

  model RecordingScenarioUnavailableSnapshot {
    kind: "unavailable";
  }

  model RecordingScenarioSelectingLibrarySnapshot {
    kind: "selectingLibrary";
  }

  model RecordingScenarioIdleSnapshot {
    kind: "idle";
  }

  model RecordingScenarioStartingSnapshot {
    kind: "starting";
  }

  model RecordingScenarioActiveBase {
    kind: "active";
    elapsedFrames: RecordingFrameOffset;
    mute: "live" | "muting" | "muted" | "unmuting";
    confirmation: "none" | "discardRecording";
  }

  model RecordingScenarioActiveOrdinarySnapshot
    extends RecordingScenarioActiveBase {
    limitPhase: "ordinary";
  }

  model RecordingScenarioActiveWarningSnapshot
    extends RecordingScenarioActiveBase {
    limitPhase: "fiveMinuteWarning";
  }

  model RecordingScenarioActiveCountdownSnapshot
    extends RecordingScenarioActiveBase {
    limitPhase: "oneMinuteCountdown";

    @minValue(1)
    @maxValue(60)
    secondsRemaining: integer;
  }

  model RecordingScenarioActiveLimitSnapshot
    extends RecordingScenarioActiveBase {
    limitPhase: "automaticStop";
  }

  model RecordingScenarioTerminalSnapshotBase {
    elapsedFrames: RecordingFrameOffset;
    mute: "live" | "muting" | "muted" | "unmuting";
    limitPhase: "ordinary" | "fiveMinuteWarning" | "automaticStop";
    terminalReason: "userStop" | "durationLimit" | "interruption";
  }

  model RecordingScenarioFinishingSnapshot
    extends RecordingScenarioTerminalSnapshotBase {
    kind: "finishing";
  }

  model RecordingScenarioSealingSnapshot
    extends RecordingScenarioTerminalSnapshotBase {
    kind: "sealing";
  }

  model RecordingScenarioRecoveryRequiredSnapshot {
    kind: "recoveryRequired";
  }

  model RecordingScenarioResolvingRecoverySnapshot {
    kind: "resolvingRecovery";
  }

  model RecordingScenarioCompletedSnapshot {
    kind: "completed";
    notice?: "durationLimit";
  }

  model RecordingScenarioFailedSnapshot {
    kind: "failed";
  }

  model RecordingScenarioDependencyBase {
    @minValue(0)
    afterCommand: integer;
  }

  model RecordingInspectEmptyDependency
    extends RecordingScenarioDependencyBase {
    port: "audioCapture";
    effect: "inspectRecovery";
    outcome: "none";
  }

  model RecordingInspectItemDependency extends RecordingScenarioDependencyBase {
    port: "audioCapture";
    effect: "inspectRecovery";
    outcome: "sealOrDiscard" | "committedCleanup" | "discardOnly";
    frameCount: RecordingFrameOffset;
  }

  model RecordingBeginStartedDependency
    extends RecordingScenarioDependencyBase {
    port: "audioCapture";
    effect: "begin";
    outcome: "started";
    frameCount?: RecordingFrameOffset;
  }

  model RecordingBeginDeniedDependency extends RecordingScenarioDependencyBase {
    port: "audioCapture";
    effect: "begin";
    outcome: "microphonePermissionDenied";
  }

  model RecordingMeasuredProgressDependency
    extends RecordingScenarioDependencyBase {
    port: "audioCapture";
    effect: "progress";
    outcome: "measured";
    frameCount: RecordingFrameOffset;

    @minValue(0)
    @maxValue(1)
    level: float64;
  }

  model RecordingUnavailableProgressDependency
    extends RecordingScenarioDependencyBase {
    port: "audioCapture";
    effect: "progress";
    outcome: "muted" | "captureGap";
    frameCount: RecordingFrameOffset;
  }

  model RecordingSetMutedDependency extends RecordingScenarioDependencyBase {
    port: "audioCapture";
    effect: "setMuted";
    outcome: "accepted";
  }

  model RecordingMuteChangedDependency extends RecordingScenarioDependencyBase {
    port: "audioCapture";
    effect: "muteChanged";
    outcome: "muted" | "live";
    frameCount: RecordingFrameOffset;
  }

  model RecordingNormalizedIntervalsDependency
    extends RecordingScenarioDependencyBase {
    port: "domain";
    effect: "normalizeUnavailableIntervals";
    outcome: "mutedGapOverlap";
    frameCount: RecordingFrameOffset;
  }

  model RecordingFinishingDependency extends RecordingScenarioDependencyBase {
    port: "audioCapture";
    effect: "finishing";
    outcome: "durationLimit" | "userStop";
    frameCount: RecordingFrameOffset;
  }

  model RecordingSealingDependency extends RecordingScenarioDependencyBase {
    port: "audioCapture";
    effect: "sealing";
    outcome: "durationLimit" | "userStop";
    frameCount: RecordingFrameOffset;
  }

  model RecordingSealedDependency extends RecordingScenarioDependencyBase {
    port: "audioCapture";
    effect: "sealed";
    outcome: "durationLimit" | "userStop";
    frameCount: RecordingFrameOffset;
  }

  model RecordingStopDependency extends RecordingScenarioDependencyBase {
    port: "audioCapture";
    effect: "stop";
    outcome: "accepted";
  }

  model RecordingDiscardConfirmedDependency
    extends RecordingScenarioDependencyBase {
    port: "audioCapture";
    effect: "discardConfirmed";
    outcome: "accepted" | "stagingDiscardFailed";
  }

  model RecordingDiscardedDependency extends RecordingScenarioDependencyBase {
    port: "audioCapture";
    effect: "discarded";
    outcome: "discarded";
  }

  model RecordingRecoveryRequiredDependency
    extends RecordingScenarioDependencyBase {
    port: "audioCapture";
    effect: "recoveryRequired";
    outcome: "sealOrDiscard";
    frameCount: RecordingFrameOffset;
  }

  model RecordingResolveSealDependency extends RecordingScenarioDependencyBase {
    port: "audioCapture";
    effect: "resolveSeal";
    outcome: "sealed";
    frameCount: RecordingFrameOffset;
  }
}
