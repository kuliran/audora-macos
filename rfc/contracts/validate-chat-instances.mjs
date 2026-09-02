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
const examplesDirectory = path.join(
  resourcesDirectory,
  "Examples/Chat/v1",
);
const coachContextExamplesDirectory = path.join(
  resourcesDirectory,
  "Examples/CoachContext/v1",
);
const invocationExamplesDirectory = path.join(
  resourcesDirectory,
  "Examples/Invocation/v1",
);
const rejectedDirectory = path.join(examplesDirectory, "rejected");
const scenariosDirectory = path.join(resourcesDirectory, "Scenarios/Chat");

const positiveInventory = [
  "chat.json",
  "coach-invocation.json",
  "coach-message.json",
  "memory.json",
  "pending-user-turn-capacity-failure.json",
  "pending-user-turn-interrupted.json",
  "pending-user-turn-invalid-response.json",
  "pending-user-turn-legacy-v1.json",
  "pending-user-turn-provider-failure.json",
  "pending-user-turn.json",
  "rejected",
  "renamed-chat.json",
  "session-analysis-chat.json",
  "user-message.json",
];
const scenarioInventory = [
  "attachment-disappears-during-create.v1.json",
  "cancel-during-attachment-resolution.v1.json",
  "cancel-during-new-chat-quote.v1.json",
  "corrupt-chat-freezes.v1.json",
  "context-capacity-recovery.v1.json",
  "create-collision-limit.v1.json",
  "create-empty-development-chat.v1.json",
  "draft-send-discard.v1.json",
  "fake-provider-success.v1.json",
  "filter-is-pure.v1.json",
  "invalid-context-blocks-new-chat.v1.json",
  "library-switch-during-suspended-load.v1.json",
  "newer-chat-freezes.v1.json",
  "provider-unavailable-creates-locally.v1.json",
  "relaunch-reopens-exact-aggregate.v1.json",
  "rename-preserves-identity.v1.json",
  "stale-rename-cannot-overwrite.v1.json",
  "wrong-library-load-fails.v1.json",
];
const schemaInvalidChatFixtures = [
  "chat-explicit-null-origin.json",
  "chat-missing-attachments.json",
  "chat-newchat-with-origin.json",
  "chat-newer-schema.json",
  "chat-unknown-key.json",
];
const schemaValidRuntimeRejectedFixtures = ["memory-dangling-summary.json"];
const rejectedInventory = [
  ...schemaInvalidChatFixtures,
  ...schemaValidRuntimeRejectedFixtures,
].sort();

const ajv = new Ajv2020({ allErrors: true, strict: true });

async function loadJSON(file) {
  return JSON.parse(await readFile(file, "utf8"));
}

async function validator(schemaName) {
  const schema = await loadJSON(path.join(schemasDirectory, schemaName));
  return ajv.compile(schema);
}

async function assertExactInventory(directory, expected, label) {
  const actual = (await readdir(directory)).sort();
  const sortedExpected = [...expected].sort();
  if (actual.join("\n") !== sortedExpected.join("\n")) {
    throw new Error(`${label} inventory does not match validator expectations`);
  }
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

await assertExactInventory(examplesDirectory, positiveInventory, "positive Chat fixture");
await assertExactInventory(scenariosDirectory, scenarioInventory, "Chat scenario");
await assertExactInventory(rejectedDirectory, rejectedInventory, "rejected Chat fixture");

const chatManifest = await validator("ChatManifest.json");
const coachMemory = await validator("CoachMemoryEnvelope.json");
const pendingUserTurn = await validator("PendingUserTurn.json");
const chatMessage = await validator("ChatMessage.json");
const coachInvocation = await validator("CoachInvocation.json");
const invocationAdmissionLedger = await validator("InvocationAdmissionLedger.json");
const chatFeatureScenario = await validator("ChatFeatureScenario.json");
const coachContextQuote = await validator("CoachContextQuote.json");

await assertExactInventory(
  coachContextExamplesDirectory,
  ["quote.json"],
  "Coach context fixture",
);
assertValidation(
  coachContextQuote,
  await loadJSON(path.join(coachContextExamplesDirectory, "quote.json")),
  true,
  "coach-context/quote.json",
);
await assertExactInventory(
  invocationExamplesDirectory,
  ["admission-ledger.json"],
  "Invocation fixture",
);
assertValidation(
  invocationAdmissionLedger,
  await loadJSON(path.join(invocationExamplesDirectory, "admission-ledger.json")),
  true,
  "invocation/admission-ledger.json",
);

for (const name of ["chat.json", "renamed-chat.json", "session-analysis-chat.json"]) {
  assertValidation(
    chatManifest,
    await loadJSON(path.join(examplesDirectory, name)),
    true,
    name,
  );
}
assertValidation(
  coachMemory,
  await loadJSON(path.join(examplesDirectory, "memory.json")),
  true,
  "memory.json",
);
for (const name of ["user-message.json", "coach-message.json"]) {
  assertValidation(
    chatMessage,
    await loadJSON(path.join(examplesDirectory, name)),
    true,
    name,
  );
}
assertValidation(
  coachInvocation,
  await loadJSON(path.join(examplesDirectory, "coach-invocation.json")),
  true,
  "coach-invocation.json",
);
for (const name of [
  "pending-user-turn.json",
  "pending-user-turn-capacity-failure.json",
  "pending-user-turn-interrupted.json",
  "pending-user-turn-invalid-response.json",
  "pending-user-turn-legacy-v1.json",
  "pending-user-turn-provider-failure.json",
]) {
  assertValidation(
    pendingUserTurn,
    await loadJSON(path.join(examplesDirectory, name)),
    true,
    name,
  );
}
const legacyInterruptedPending = await loadJSON(
  path.join(examplesDirectory, "pending-user-turn-legacy-v1.json"),
);
legacyInterruptedPending.failure = "coachResponseInterrupted";
assertValidation(
  pendingUserTurn,
  legacyInterruptedPending,
  false,
  "synthetic legacy-v1 interrupted Pending",
);
const unknownNewerPending = await loadJSON(
  path.join(examplesDirectory, "pending-user-turn-interrupted.json"),
);
unknownNewerPending.schemaVersion = 4;
assertValidation(
  pendingUserTurn,
  unknownNewerPending,
  false,
  "synthetic unknown-newer Pending",
);
const legacyV2ProviderFailure = await loadJSON(
  path.join(examplesDirectory, "pending-user-turn-provider-failure.json"),
);
legacyV2ProviderFailure.schemaVersion = 2;
assertValidation(
  pendingUserTurn,
  legacyV2ProviderFailure,
  false,
  "synthetic legacy-v2 provider failure Pending",
);

for (const name of scenarioInventory) {
  assertValidation(
    chatFeatureScenario,
    await loadJSON(path.join(scenariosDirectory, name)),
    true,
    `scenario/${name}`,
  );
}

const attachmentBoundaryScenario = await loadJSON(
  path.join(scenariosDirectory, "invalid-context-blocks-new-chat.v1.json"),
);
const invalidAttachmentMetadata = [
  ["empty display label", (value) => {
    value.dependencyTrace[1].candidates[0].displayLabel = "";
  }],
  ["257-scalar display label", (value) => {
    value.dependencyTrace[1].candidates[0].displayLabel = "😀".repeat(257);
  }],
  ["control display label", (value) => {
    value.dependencyTrace[1].candidates[0].displayLabel = "label\u0000";
  }],
  ["257-scalar filter", (value) => {
    value.commands[1].query = "😀".repeat(257);
  }],
  ["control filter", (value) => {
    value.commands[1].query = "query\u009f";
  }],
];
for (const [label, mutate] of invalidAttachmentMetadata) {
  const value = structuredClone(attachmentBoundaryScenario);
  mutate(value);
  assertValidation(chatFeatureScenario, value, false, `scenario/${label}`);
}

for (const name of schemaInvalidChatFixtures) {
  assertValidation(
    chatManifest,
    await loadJSON(path.join(rejectedDirectory, name)),
    false,
    `rejected/${name}`,
  );
}

// The dangling summary is structurally valid. Domain loading rejects it because
// its attachment identifier is absent from the owning Chat aggregate.
for (const name of schemaValidRuntimeRejectedFixtures) {
  assertValidation(
    coachMemory,
    await loadJSON(path.join(rejectedDirectory, name)),
    true,
    `runtime-rejected/${name}`,
  );
}
