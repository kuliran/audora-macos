import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const Ajv2020 = require("ajv/dist/2020").default;

const contractsDirectory = path.dirname(fileURLToPath(import.meta.url));
const projectDirectory = path.resolve(contractsDirectory, "../..");
const resourcesDirectory = path.join(
  projectDirectory,
  "Packages/AudoraCore/Sources/AudoraContracts/Resources",
);
const schemasDirectory = path.join(resourcesDirectory, "Schemas");
const audioImportExamplesDirectory = path.join(
  resourcesDirectory,
  "Examples/AudioImport/v1",
);
const audioImportScenariosDirectory = path.join(
  resourcesDirectory,
  "Scenarios/AudioImport",
);
const recordingExamplesDirectory = path.join(
  resourcesDirectory,
  "Examples/Recording/v1",
);
const recordingScenariosDirectory = path.join(
  resourcesDirectory,
  "Scenarios/Recording",
);
const transcriptRevisionExamplesDirectory = path.join(
  resourcesDirectory,
  "Examples/TranscriptRevision/v1",
);
const qualifiedTranscriptRevisionExamplesDirectory = path.join(
  resourcesDirectory,
  "Examples/TranscriptRevision/v2",
);
const sessionProcessingScenariosDirectory = path.join(
  resourcesDirectory,
  "Scenarios/SessionProcessing",
);

const ajv = new Ajv2020({ allErrors: true, strict: true });

async function loadJSON(file) {
  return JSON.parse(await readFile(file, "utf8"));
}

async function loadFixture(file) {
  const bytes = await readFile(file);
  return { bytes, value: JSON.parse(bytes.toString("utf8")) };
}

async function validator(schemaName) {
  const schema = await loadJSON(path.join(schemasDirectory, schemaName));
  return ajv.compile(schema);
}

async function registerSchema(schemaName) {
  ajv.addSchema(await loadJSON(path.join(schemasDirectory, schemaName)));
}

function assertValidation(validate, instance, expected, label) {
  const valid = validate(instance);
  if (valid !== expected) {
    const keywords = (validate.errors ?? [])
      .slice(0, 4)
      .map((error) => error.keyword)
      .join(",");
    throw new Error(`${label}: expected valid=${expected}; keywords=${keywords}`);
  }
}

async function assertInventory(directory, expected, label) {
  const actual = (await readdir(directory))
    .filter((name) => name.endsWith(".json"))
    .sort();
  const sortedExpected = [...expected].sort();
  if (actual.join("\n") !== sortedExpected.join("\n")) {
    throw new Error(`${label} inventory does not match validator expectations`);
  }
}

function sha256Hex(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function manifestPairIsValid(audioFixture, session) {
  if (!audioManifest(audioFixture.value) || !sessionManifest(session)) {
    return false;
  }

  if (
    audioFixture.value.acquisitionKind === "imported" &&
    session.audioManifestSha256 !== undefined
  ) {
    return session.audioManifestSha256 === sha256Hex(audioFixture.bytes);
  }

  return (
    audioFixture.value.sourceKind === "microphone" &&
    session.audioManifestPath === "audio/audio.json"
  );
}

function intervalsAreCanonical(audio) {
  let priorEnd = 0;
  return audio.unavailableIntervals.every((interval) => {
    const valid =
      interval.startFrame < interval.endFrame &&
      interval.endFrame <= audio.frameCount &&
      interval.startFrame >= priorEnd;
    priorEnd = interval.endFrame;
    return valid;
  });
}

const audioManifest = await validator("AudioManifest.json");
const sessionManifest = await validator("SessionManifest.json");
const normalizationVectors = await validator("AudioNormalizationVectors.json");
const audioImportScenario = await validator("AudioImportFeatureScenario.json");
await registerSchema("RecordingStagingIdentityManifest.json");
const recordingStagingManifest = await validator("RecordingStagingManifest.json");
const recordingScenario = await validator("RecordingFeatureScenario.json");
const transcriptRevision = await validator("TranscriptRevision.json");
const sessionProcessingScenario = await validator(
  "SessionProcessingFeatureScenario.json",
);

const importedAudio = await loadFixture(
  path.join(audioImportExamplesDirectory, "audio.json"),
);
const importedSession = await loadJSON(
  path.join(audioImportExamplesDirectory, "session.json"),
);
const recordedAudio = await loadFixture(
  path.join(recordingExamplesDirectory, "audio.json"),
);
const recordedSession = await loadJSON(
  path.join(recordingExamplesDirectory, "session.json"),
);

assertValidation(audioManifest, importedAudio.value, true, "audio-import/audio.json");
assertValidation(
  sessionManifest,
  importedSession,
  true,
  "audio-import/session.json",
);
assertValidation(
  normalizationVectors,
  await loadJSON(
    path.join(audioImportExamplesDirectory, "normalization-vectors.json"),
  ),
  true,
  "audio-import/normalization-vectors.json",
);

const expectedAudioImportScenarios = [
  "corrupt-candidate-discarded.v1.json",
  "install-failure-discards-staging.v1.json",
  "normalization-failure-publishes-nothing.v1.json",
  "postcommit-reopen-failure-keeps-session.v1.json",
  "selection-cancelled.v1.json",
  "session-id-collision-regenerates.v1.json",
  "success-retains-and-reopens.v1.json",
];
await assertInventory(
  audioImportScenariosDirectory,
  expectedAudioImportScenarios,
  "audio-import scenario",
);
for (const name of expectedAudioImportScenarios) {
  assertValidation(
    audioImportScenario,
    await loadJSON(path.join(audioImportScenariosDirectory, name)),
    true,
    `audio-import/scenario/${name}`,
  );
}

for (const name of ["audio.json", "audio-45-minutes.json"]) {
  assertValidation(
    audioManifest,
    await loadJSON(path.join(recordingExamplesDirectory, name)),
    true,
    `recording/${name}`,
  );
}
assertValidation(
  sessionManifest,
  recordedSession,
  true,
  "recording/session.json",
);
for (const name of [
  "recording-capturing.json",
  "recording-recoverable.json",
  "recording-discard-only.json",
  "recording-committed.json",
]) {
  assertValidation(
    recordingStagingManifest,
    await loadJSON(path.join(recordingExamplesDirectory, name)),
    true,
    `recording/${name}`,
  );
}

const expectedRecordingScenarios = [
  "another-take-new-session.v1.json",
  "cancel-keeps-recording.v1.json",
  "confirmed-cancel-discards.v1.json",
  "discard-failure-honest.v1.json",
  "duration-limit-seals.v1.json",
  "five-minute-warning.v1.json",
  "honest-live-state.v1.json",
  "interruption-recovery.v1.json",
  "late-events-fenced.v1.json",
  "library-switch-serialized.v1.json",
  "live-mute-acknowledgement.v1.json",
  "mute-gap-unavailable.v1.json",
  "one-minute-countdown.v1.json",
  "recovered-seal-idempotent.v1.json",
  "recovery-discard-only.v1.json",
  "start-failure-no-publication.v1.json",
  "stop-limit-race.v1.json",
  "user-stop-seals.v1.json",
];
await assertInventory(
  recordingScenariosDirectory,
  expectedRecordingScenarios,
  "recording scenario",
);
for (const name of expectedRecordingScenarios) {
  assertValidation(
    recordingScenario,
    await loadJSON(path.join(recordingScenariosDirectory, name)),
    true,
    `recording/scenario/${name}`,
  );
}

const legacyTranscriptRevision = await loadJSON(
  path.join(transcriptRevisionExamplesDirectory, "revision.json"),
);
assertValidation(
  transcriptRevision,
  legacyTranscriptRevision,
  true,
  "transcript-revision/v1/revision.json",
);
const qualifiedTranscriptRevision = await loadJSON(
  path.join(qualifiedTranscriptRevisionExamplesDirectory, "revision.json"),
);
assertValidation(
  transcriptRevision,
  qualifiedTranscriptRevision,
  true,
  "transcript-revision/v2/revision.json",
);
const transcriptRevisionRejectedDirectory = path.join(
  transcriptRevisionExamplesDirectory,
  "rejected",
);
const runtimeRejectedTranscriptRevisionFixtures = [
  "punctuation-as-word.json",
  "utf8-range-split.json",
];
await assertInventory(
  transcriptRevisionRejectedDirectory,
  runtimeRejectedTranscriptRevisionFixtures,
  "runtime-rejected transcript-revision fixture",
);
for (const name of runtimeRejectedTranscriptRevisionFixtures) {
  assertValidation(
    transcriptRevision,
    await loadJSON(path.join(transcriptRevisionRejectedDirectory, name)),
    true,
    `transcript-revision/runtime-rejected/${name}`,
  );
}

const expectedSessionProcessingScenarios = [
  "cancel-reaps-retains-session.v1.json",
  "candidate-rejected-no-publication.v1.json",
  "model-prepare-retry.v1.json",
  "progress-monotonic-eta-approximate.v1.json",
  "qualification-blocked-no-fallback.v1.json",
  "qualified-offline-success.v1.json",
  "relaunch-queued-interrupted.v1.json",
  "relaunch-running-absent-interrupted.v1.json",
  "relaunch-validating-stale-selection.v1.json",
  "relaunch-validating-resumes-idempotently.v1.json",
];
await assertInventory(
  sessionProcessingScenariosDirectory,
  expectedSessionProcessingScenarios,
  "session-processing scenario",
);
for (const name of expectedSessionProcessingScenarios) {
  assertValidation(
    sessionProcessingScenario,
    await loadJSON(path.join(sessionProcessingScenariosDirectory, name)),
    true,
    `session-processing/scenario/${name}`,
  );
}
const fallbackProbe = await loadJSON(
  path.join(
    sessionProcessingScenariosDirectory,
    "qualification-blocked-no-fallback.v1.json",
  ),
);
const invalidFallback = structuredClone(fallbackProbe);
invalidFallback.expectedEffects.push({ kind: "fallbackEngine" });
assertValidation(
  sessionProcessingScenario,
  invalidFallback,
  false,
  "session-processing/scenario/invalid-fallback-effect",
);
const punctuationWordRevision = await loadJSON(
  path.join(transcriptRevisionRejectedDirectory, "punctuation-as-word.json"),
);
if (punctuationWordRevision.lines[0].words[0].text !== ".") {
  throw new Error("punctuation runtime fixture no longer isolates punctuation as a Word");
}
const splitRangeRevision = await loadJSON(
  path.join(transcriptRevisionRejectedDirectory, "utf8-range-split.json"),
);
const splitLine = splitRangeRevision.lines[0];
const splitWord = splitLine.words[0];
const splitBytes = Buffer.from(splitLine.text, "utf8").subarray(
  splitWord.displayRange.startUtf8Byte,
  splitWord.displayRange.endUtf8Byte,
);
if (splitBytes.toString("utf8") === splitWord.text) {
  throw new Error("UTF-8 range runtime fixture unexpectedly maps to its Word text");
}

const closedUnionProbe = await loadJSON(
  path.join(recordingScenariosDirectory, "honest-live-state.v1.json"),
);
const invalidSnapshotCombination = structuredClone(closedUnionProbe);
invalidSnapshotCombination.initialState = { kind: "idle", elapsedFrames: 1 };
assertValidation(
  recordingScenario,
  invalidSnapshotCombination,
  false,
  "recording/scenario/invalid-state-combination",
);
const invalidDependencyCombination = structuredClone(closedUnionProbe);
invalidDependencyCombination.dependencyTrace[0].port = "domain";
assertValidation(
  recordingScenario,
  invalidDependencyCombination,
  false,
  "recording/scenario/invalid-dependency-combination",
);

const audioImportRejectedDirectory = path.join(
  audioImportExamplesDirectory,
  "rejected",
);
const schemaRejectedImportedAudioFixtures = [
  "audio-container-codec-mismatch.json",
  "audio-newer-schema.json",
  "audio-unknown-machine-path.json",
];
const runtimeRejectedImportedSessionFixtures = [
  "session-cross-root-hash.json",
];
await assertInventory(
  audioImportRejectedDirectory,
  [
    ...schemaRejectedImportedAudioFixtures,
    ...runtimeRejectedImportedSessionFixtures,
  ],
  "rejected audio-import fixture",
);
for (const name of schemaRejectedImportedAudioFixtures) {
  assertValidation(
    audioManifest,
    await loadJSON(path.join(audioImportRejectedDirectory, name)),
    false,
    `audio-import/rejected/${name}`,
  );
}
const wrongHashSession = await loadJSON(
  path.join(audioImportRejectedDirectory, "session-cross-root-hash.json"),
);
assertValidation(
  sessionManifest,
  wrongHashSession,
  true,
  "audio-import/runtime-rejected/session-cross-root-hash.json",
);

const recordingRejectedDirectory = path.join(
  recordingExamplesDirectory,
  "rejected",
);
const schemaRejectedRecordingAudioFixtures = [
  "audio-duration-overflow.json",
  "audio-empty-reasons.json",
  "audio-multiple-sources.json",
  "audio-unknown-key.json",
  "audio-wrong-channel-count.json",
  "audio-wrong-format.json",
  "audio-wrong-sample-rate.json",
  "audio-zero-sources.json",
];
const schemaRejectedRecordingSessionFixtures = [
  "session-invalid-id.json",
  "session-path-like-id.json",
];
// JSON Schema can bound each interval and fingerprint lexically, but ordering,
// overlap, duration-relative bounds, and staged-WAV fingerprint equality need
// trusted runtime context. These fixtures therefore remain structurally valid.
const runtimeRejectedRecordingAudioFixtures = [
  "audio-interval-out-of-bounds.json",
  "audio-interval-overlap.json",
  "audio-interval-unordered.json",
  "audio-mismatched-fingerprint.json",
];
await assertInventory(
  recordingRejectedDirectory,
  [
    ...schemaRejectedRecordingAudioFixtures,
    ...schemaRejectedRecordingSessionFixtures,
    ...runtimeRejectedRecordingAudioFixtures,
  ],
  "rejected recording fixture",
);
for (const name of schemaRejectedRecordingAudioFixtures) {
  assertValidation(
    audioManifest,
    await loadJSON(path.join(recordingRejectedDirectory, name)),
    false,
    `recording/rejected/${name}`,
  );
}
for (const name of schemaRejectedRecordingSessionFixtures) {
  assertValidation(
    sessionManifest,
    await loadJSON(path.join(recordingRejectedDirectory, name)),
    false,
    `recording/rejected/${name}`,
  );
}
for (const name of runtimeRejectedRecordingAudioFixtures) {
  assertValidation(
    audioManifest,
    await loadJSON(path.join(recordingRejectedDirectory, name)),
    true,
    `recording/runtime-rejected/${name}`,
  );
}
for (const name of [
  "audio-interval-out-of-bounds.json",
  "audio-interval-overlap.json",
  "audio-interval-unordered.json",
]) {
  const fixture = await loadJSON(path.join(recordingRejectedDirectory, name));
  if (intervalsAreCanonical(fixture)) {
    throw new Error(`recording/runtime-rejected/${name}: unexpectedly canonical`);
  }
}

const hybridAudio = {
  ...importedAudio.value,
  ...recordedAudio.value,
};
const hybridSession = {
  ...importedSession,
  ...recordedSession,
};
assertValidation(
  audioManifest,
  hybridAudio,
  false,
  "audio-manifest/hybrid-imported-microphone",
);
assertValidation(
  sessionManifest,
  hybridSession,
  false,
  "session-manifest/hybrid-imported-recorded",
);

const pairChecks = [
  [importedAudio, importedSession, true, "pair/imported"],
  [recordedAudio, recordedSession, true, "pair/recorded"],
  [importedAudio, wrongHashSession, false, "pair/imported-wrong-hash"],
  [importedAudio, recordedSession, false, "pair/imported-audio-recorded-session"],
  [recordedAudio, importedSession, false, "pair/microphone-audio-imported-session"],
  [
    { bytes: importedAudio.bytes, value: hybridAudio },
    importedSession,
    false,
    "pair/hybrid-audio",
  ],
];
for (const [audio, session, expected, label] of pairChecks) {
  const actual = manifestPairIsValid(audio, session);
  if (actual !== expected) {
    throw new Error(`${label}: expected valid=${expected}`);
  }
}
