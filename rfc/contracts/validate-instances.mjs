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
const audioExamplesDirectory = path.join(
  resourcesDirectory,
  "Examples/AudioImport/v1",
);
const audioScenariosDirectory = path.join(
  resourcesDirectory,
  "Scenarios/AudioImport",
);

const ajv = new Ajv2020({ allErrors: true, strict: true });

async function loadJSON(file) {
  return JSON.parse(await readFile(file, "utf8"));
}

async function validator(schemaName) {
  const schema = await loadJSON(path.join(schemasDirectory, schemaName));
  return ajv.compile(schema);
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

const audioManifest = await validator("AudioManifest.json");
const sessionManifest = await validator("SessionManifest.json");
const normalizationVectors = await validator("AudioNormalizationVectors.json");
const audioScenario = await validator("AudioImportFeatureScenario.json");

assertValidation(
  audioManifest,
  await loadJSON(path.join(audioExamplesDirectory, "audio.json")),
  true,
  "audio.json",
);
assertValidation(
  sessionManifest,
  await loadJSON(path.join(audioExamplesDirectory, "session.json")),
  true,
  "session.json",
);
assertValidation(
  normalizationVectors,
  await loadJSON(path.join(audioExamplesDirectory, "normalization-vectors.json")),
  true,
  "normalization-vectors.json",
);

for (const name of (await readdir(audioScenariosDirectory)).sort()) {
  if (!name.endsWith(".json")) continue;
  assertValidation(
    audioScenario,
    await loadJSON(path.join(audioScenariosDirectory, name)),
    true,
    `scenario/${name}`,
  );
}

const rejectedDirectory = path.join(audioExamplesDirectory, "rejected");
const schemaInvalidAudioFixtures = [
  "audio-container-codec-mismatch.json",
  "audio-newer-schema.json",
  "audio-unknown-machine-path.json",
];
const schemaValidRuntimeRejectedFixtures = ["session-cross-root-hash.json"];
const actualRejectedFixtures = (await readdir(rejectedDirectory))
  .filter((name) => name.endsWith(".json"))
  .sort();
const expectedRejectedFixtures = [
  ...schemaInvalidAudioFixtures,
  ...schemaValidRuntimeRejectedFixtures,
].sort();
if (actualRejectedFixtures.join("\n") !== expectedRejectedFixtures.join("\n")) {
  throw new Error("rejected fixture inventory does not match validator expectations");
}

for (const name of schemaInvalidAudioFixtures) {
  assertValidation(
    audioManifest,
    await loadJSON(path.join(rejectedDirectory, name)),
    false,
    `rejected/${name}`,
  );
}

// This fixture is structurally valid. Runtime installation must reject its
// deliberately wrong cross-root hash after descriptor-bound reads.
assertValidation(
  sessionManifest,
  await loadJSON(
    path.join(rejectedDirectory, schemaValidRuntimeRejectedFixtures[0]),
  ),
  true,
  "rejected/session-cross-root-hash.json",
);
