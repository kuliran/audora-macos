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
const recordingExamplesDirectory = path.join(
  resourcesDirectory,
  "Examples/Recording/v1",
);
const recordingScenariosDirectory = path.join(
  resourcesDirectory,
  "Scenarios/Recording",
);

const ajv = new Ajv2020({ allErrors: true, strict: true });

async function loadJSON(file) {
  return JSON.parse(await readFile(file, "utf8"));
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

const audioManifest = await validator("AudioManifest.json");
const sessionManifest = await validator("SessionManifest.json");
await registerSchema("RecordingStagingIdentityManifest.json");
const stagingManifest = await validator("RecordingStagingManifest.json");
const recordingScenario = await validator("RecordingFeatureScenario.json");

for (const name of ["audio.json", "audio-45-minutes.json"]) {
  assertValidation(
    audioManifest,
    await loadJSON(path.join(recordingExamplesDirectory, name)),
    true,
    name,
  );
}
assertValidation(
  sessionManifest,
  await loadJSON(path.join(recordingExamplesDirectory, "session.json")),
  true,
  "session.json",
);
for (const name of [
  "recording-capturing.json",
  "recording-recoverable.json",
  "recording-discard-only.json",
  "recording-committed.json",
]) {
  assertValidation(
    stagingManifest,
    await loadJSON(path.join(recordingExamplesDirectory, name)),
    true,
    name,
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
    `scenario/${name}`,
  );
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
  "scenario/invalid-state-combination",
);
const invalidDependencyCombination = structuredClone(closedUnionProbe);
invalidDependencyCombination.dependencyTrace[0].port = "domain";
assertValidation(
  recordingScenario,
  invalidDependencyCombination,
  false,
  "scenario/invalid-dependency-combination",
);

const rejectedDirectory = path.join(recordingExamplesDirectory, "rejected");
const schemaRejectedAudioFixtures = [
  "audio-duration-overflow.json",
  "audio-empty-reasons.json",
  "audio-multiple-sources.json",
  "audio-unknown-key.json",
  "audio-wrong-channel-count.json",
  "audio-wrong-format.json",
  "audio-wrong-sample-rate.json",
  "audio-zero-sources.json",
];
const schemaRejectedSessionFixtures = [
  "session-invalid-id.json",
  "session-path-like-id.json",
];
// JSON Schema can bound each interval and fingerprint lexically, but ordering,
// overlap, duration-relative bounds, and staged-WAV fingerprint equality need
// trusted runtime context. Their fixtures must remain structurally valid here;
// Swift contract tests route them through the production Application and
// Infrastructure validators.
const runtimeRejectedAudioFixtures = [
  "audio-interval-out-of-bounds.json",
  "audio-interval-overlap.json",
  "audio-interval-unordered.json",
  "audio-mismatched-fingerprint.json",
];
await assertInventory(
  rejectedDirectory,
  [
    ...schemaRejectedAudioFixtures,
    ...schemaRejectedSessionFixtures,
    ...runtimeRejectedAudioFixtures,
  ],
  "rejected recording fixture",
);
for (const name of schemaRejectedAudioFixtures) {
  assertValidation(
    audioManifest,
    await loadJSON(path.join(rejectedDirectory, name)),
    false,
    `rejected/${name}`,
  );
}
for (const name of schemaRejectedSessionFixtures) {
  assertValidation(
    sessionManifest,
    await loadJSON(path.join(rejectedDirectory, name)),
    false,
    `rejected/${name}`,
  );
}
for (const name of runtimeRejectedAudioFixtures) {
  assertValidation(
    audioManifest,
    await loadJSON(path.join(rejectedDirectory, name)),
    true,
    `runtime-rejected/${name}`,
  );
}
