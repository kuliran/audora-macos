import "./audio-import.tsp";
import "@typespec/json-schema";

using TypeSpec.JsonSchema;

namespace Audora.Contracts {
  /** Portable audio-import behavior shared by feature implementations. */
  @jsonSchema
  @id("AudioImportFeatureScenario.json")
  model AudioImportFeatureScenario {
    schemaVersion: 1;
    scenarioId: string;
    initialState: AudioImportScenarioState;
    commands: AudioImportScenarioCommand[];
    dependencyTrace: AudioImportDependencyEvent[];
    expectedState: AudioImportScenarioState;
  }

  union AudioImportScenarioState {
    idle: AudioImportIdleState,
    selecting: AudioImportSelectingState,
    copying: AudioImportCopyingState,
    inspecting: AudioImportInspectingState,
    normalizing: AudioImportNormalizingState,
    installing: AudioImportInstallingState,
    succeeded: AudioImportSucceededState,
    failed: AudioImportFailedState,
  }

  union AudioImportScenarioCommand {
    chooseAudio: AudioImportChooseAudioCommand,
    cancelImport: AudioImportCancelCommand,
    clearResult: AudioImportClearResultCommand,
  }

  union AudioImportDependencyEvent {
    choose: AudioImportChooseEvent,
    revokeSelection: AudioImportRevokeSelectionEvent,
    reserveSessionId: AudioImportReserveSessionIdEvent,
    prepare: AudioImportPrepareEvent,
    install: AudioImportInstallEvent,
    discard: AudioImportDiscardEvent,
    now: AudioImportClockEvent,
    generateSessionId: AudioImportSessionIdEvent,
  }

  model AudioImportIdleState {
    status: "idle";
  }
  model AudioImportSelectingState {
    status: "selecting";
  }
  model AudioImportCopyingState {
    status: "copying";
  }
  model AudioImportInspectingState {
    status: "inspecting";
  }
  model AudioImportNormalizingState {
    status: "normalizing";
  }
  model AudioImportInstallingState {
    status: "installing";
  }

  model AudioImportSucceededState {
    status: "succeeded";
    sessionId: SessionId;
  }

  model AudioImportFailedState {
    status: "failed";
    failure: AudioImportFailureCode;
  }

  model AudioImportChooseAudioCommand {
    kind: "chooseAudio";
  }
  model AudioImportCancelCommand {
    kind: "cancelImport";
  }
  model AudioImportClearResultCommand {
    kind: "clearResult";
  }

  model AudioImportChooseEvent {
    port: "audioImport";
    effect: "choose";
    outcome: AudioImportChooseOutcome;
  }

  model AudioImportRevokeSelectionEvent {
    port: "audioImport";
    effect: "revokeSelection";
    outcome: "revoked";
  }

  model AudioImportReserveSessionIdEvent {
    port: "audioImport";
    effect: "reserveSessionId";
    outcome: AudioImportReserveSessionIdOutcome;
  }

  model AudioImportPrepareEvent {
    port: "audioImport";
    effect: "prepare";
    outcome: AudioImportPrepareOutcome;
  }

  model AudioImportInstallEvent {
    port: "audioImport";
    effect: "install";
    outcome: AudioImportInstallOutcome;
  }

  model AudioImportDiscardEvent {
    port: "audioImport";
    effect: "discard";
    outcome: "discarded";
  }

  model AudioImportClockEvent {
    port: "clock";
    effect: "now";
    outcome: UTCInstant;
  }

  model AudioImportSessionIdEvent {
    port: "sessionIdGenerator";
    effect: "generateSessionId";
    outcome: SessionId;
  }

  union AudioImportFailureCode {
    unavailable: "unavailable",
    unsupportedMedia: "unsupportedMedia",
    sourceChanged: "sourceChanged",
    sourceTooLarge: "sourceTooLarge",
    malformedMedia: "malformedMedia",
    durationExceeded: "durationExceeded",
    decodeFailed: "decodeFailed",
    nonfiniteSamples: "nonfiniteSamples",
    insufficientSpace: "insufficientSpace",
    writeFailed: "writeFailed",
    candidateCorrupt: "candidateCorrupt",
    libraryChanged: "libraryChanged",
    destinationCollision: "destinationCollision",
    cancelled: "cancelled",
    installedNeedsRefresh: "installedNeedsRefresh",
  }

  union AudioImportChooseOutcome {
    selected: "selected",
    result: AudioImportFailureCode,
  }

  union AudioImportPrepareOutcome {
    candidate: "candidate",
    corruptCandidate: "corruptCandidate",
    failure: AudioImportFailureCode,
  }

  union AudioImportReserveSessionIdOutcome {
    reserved: "reserved",
    collision: "collision",
    failure: AudioImportFailureCode,
  }

  union AudioImportInstallOutcome {
    reopened: "reopened",
    failure: AudioImportFailureCode,
  }
}
