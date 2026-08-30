# Contracts

[`contracts.tsp`](contracts.tsp) is the sole compilation entry point. It imports
the provider aggregate in [`coach-provider.tsp`](coach-provider.tsp), the
portable Library document roots in
[`portable-library.tsp`](portable-library.tsp), the Library lifecycle
scenario in [`library-feature-scenario.tsp`](library-feature-scenario.tsp), and
the Recording storage and feature contracts in
[`recording.tsp`](recording.tsp).

The provider source is separated by audience:

- [`coach-provider-configuration.tsp`](coach-provider-configuration.tsp) contains
  Application-only static provider configuration.
- [`coach-provider-protocol.tsp`](coach-provider-protocol.tsp) contains JSON sent
  to or returned by the coach and the scoped transcript-read tool.
- [`coach-provider-shared.tsp`](coach-provider-shared.tsp) contains shared scalar
  definitions.

TypeSpec compilation emits committed JSON Schemas into the `AudoraContracts`
package resources. Application and scenario runners do not need Node or TypeSpec
at runtime.

- [`AudioManifest.json`](../../Packages/AudoraCore/Sources/AudoraContracts/Resources/Schemas/AudioManifest.json)
- [`CoachProviderDescriptor.json`](../../Packages/AudoraCore/Sources/AudoraContracts/Resources/Schemas/CoachProviderDescriptor.json)
- [`CoachRequest.json`](../../Packages/AudoraCore/Sources/AudoraContracts/Resources/Schemas/CoachRequest.json)
- [`CoachResponse.json`](../../Packages/AudoraCore/Sources/AudoraContracts/Resources/Schemas/CoachResponse.json)
- [`LibraryFeatureScenario.json`](../../Packages/AudoraCore/Sources/AudoraContracts/Resources/Schemas/LibraryFeatureScenario.json)
- [`LibraryManifest.json`](../../Packages/AudoraCore/Sources/AudoraContracts/Resources/Schemas/LibraryManifest.json)
- [`LibraryPreferences.json`](../../Packages/AudoraCore/Sources/AudoraContracts/Resources/Schemas/LibraryPreferences.json)
- [`ProfileHead.json`](../../Packages/AudoraCore/Sources/AudoraContracts/Resources/Schemas/ProfileHead.json)
- [`ReadSessionTranscriptsRequest.json`](../../Packages/AudoraCore/Sources/AudoraContracts/Resources/Schemas/ReadSessionTranscriptsRequest.json)
- [`ReadSessionTranscriptsResponse.json`](../../Packages/AudoraCore/Sources/AudoraContracts/Resources/Schemas/ReadSessionTranscriptsResponse.json)
- [`RecordingFeatureScenario.json`](../../Packages/AudoraCore/Sources/AudoraContracts/Resources/Schemas/RecordingFeatureScenario.json)
- [`RecordingStagingIdentityManifest.json`](../../Packages/AudoraCore/Sources/AudoraContracts/Resources/Schemas/RecordingStagingIdentityManifest.json)
- [`RecordingStagingManifest.json`](../../Packages/AudoraCore/Sources/AudoraContracts/Resources/Schemas/RecordingStagingManifest.json)
- [`SessionManifest.json`](../../Packages/AudoraCore/Sources/AudoraContracts/Resources/Schemas/SessionManifest.json)

| Root schema | Direction | Coach-visible instance? |
| --- | --- | --- |
| `AudioManifest` | Portable Library Session storage | No |
| `CoachProviderDescriptor` | Application configuration | No |
| `CoachRequest` | Application -> coach | Yes |
| `CoachResponse` | Coach -> Application | Yes |
| `LibraryFeatureScenario` | Portable cross-implementation behavior | No |
| `LibraryManifest` | Portable Library storage | No |
| `LibraryPreferences` | Portable Library storage | No |
| `ProfileHead` | Portable Library storage | No |
| `ReadSessionTranscriptsRequest` | Coach tool call -> Application | Yes |
| `ReadSessionTranscriptsResponse` | Application -> coach tool result | Yes |
| `RecordingFeatureScenario` | Portable cross-implementation behavior | No |
| `RecordingStagingIdentityManifest` | Recording staging storage | No |
| `RecordingStagingManifest` | Recording staging storage | No |
| `SessionManifest` | Portable Library Session storage | No |

Invocation and Attempt identities, provider idempotency, admission state, token
estimator identity, Profile integrity hashes, and persisted-record schema versions
remain outside these provider DTOs.

## Library feature scenarios

`LibraryFeatureScenario` is a versioned, language-neutral description of one
Application lifecycle. Commands, states, effects, dependency ports, and outcomes
use literal typed values rather than UI prose or framework-specific data. Checked-in
fixtures cover creation, failed and successful selection, reveal, close/reopen,
relaunch restoration, and newer-root read-only behavior. The
[`library-launch-no-selection.v1.json`](../../Packages/AudoraCore/Sources/AudoraContracts/Resources/Scenarios/library-launch-no-selection.v1.json)
fixture describes launch without a saved Library locator. Portable implementations
consume all scenarios through their package resources.

`CoachProviderDescriptor` is app-only configuration. JSON Schema validates each
field's shape. `displayName` is a bounded Presentation label for provider health
and errors; no behavior branches on its text. Application additionally rejects the
descriptor unless:

- `responseReservedTokens + safetyMarginTokens < contextWindowTokens`;
- a maximum valid canonically serialized `CoachMemory`, inside the minimum valid
  Request, fits the resulting input ceiling; and
- that same Memory, inside the minimum valid Response, fits both
  `responseReservedTokens` and the response collector's byte ceiling.

This guarantees that accepting a maximum-sized Memory cannot make the next minimal
turn or its own valid response structurally impossible.

## Source ordering

TypeSpec declarations are order-independent. New contract files and roots that a
change introduces or substantively modifies favor reading from the prominent
root outward. Untouched legacy declarations do not need to be reordered solely
to adopt this convention:

1. Declare each new or substantively modified exported `@jsonSchema` root before
   the supporting shapes introduced for it.
2. Traverse those roots in source order, preserving field and union order.
3. Declare supporting models, unions, enums, and scalars breadth-first in the
   order they are first referenced.
4. Put a spread `*Base` after the models that use it.
5. Start a new root-and-support queue at each direction heading.

Comments explain only non-obvious trust, units, or cross-field rules.

## Generation

From the macOS project directory:

```sh
pnpm install
pnpm contracts:generate
pnpm contracts:check
```

The compiler and JSON Schema emitter are pinned in `package.json`. The resolved
dependency graph is committed in `pnpm-lock.yaml`. `generated-json-files.txt`
enumerates the canonical package-resource schemas and makes the check fail when
generated roots change unexpectedly or their committed bytes drift.

## Request context

A Chat freezes its Session attachment set at creation. A request may contain no
Session attachments. Each attachment has a stable Chat-scoped
`sessionAttachmentId`; Library Session and revision identities stay local.

For each Provider Attempt, Application projects every attachment as either:

- `inline`, with its complete immutable transcript; or
- `onDemand`, with a fresh Attempt-scoped `SessionTranscriptHandle`.

The projection may change between Attempts without changing attachment identity.
Application chooses it from the exact serialized context and provider limits. The
coach receives no estimates or admission inputs.

`ProfileContext` is a structured projection of the current Profile. Each
`ProfileStatement` exposes its stable target ID, kind, wording, total distinct
supporting-Session count, and only the supporting evidence whose exact
`(sessionId, transcriptRevisionId)` pair is attached to this Chat. Matching a
Session at a different Transcript Revision never remaps Word or Audio Event IDs.

`ConversationContext` contains the complete eligible Chat-history prose projection,
current structured Coach Memory, and one trigger. A user `ChatTurn.text` is the
stored user text. A coach `ChatTurn.text` concatenates its persisted block Markdown
in order with exactly two newline characters between blocks. Evidence controls and
pointers remain in local message storage rather than being synthesized into that
text. This projection is deterministic and never omits an eligible successful turn.

Analyze is not a trigger: it creates a Chat, seeds
an ordinary user-message Draft, and submits that Draft through the same path.
Pending Drafts, errors, Proposals, processing state, and Profile-update dividers
never enter history.

Coach Memory is a complete Chat-scoped working snapshot with free general notes
and per-attachment summaries. `CoachResponse.newMemory` is optional. Omission keeps
the current snapshot; presence replaces it atomically with successful response
publication. Superseded snapshots are not retained.

## Transcript reads

The transcript-read tool accepts a unique nonempty subset of the handles in the
current request. Its response is atomic:

- `complete` returns every requested transcript;
- `sessionUnavailable` identifies unavailable handles and returns no transcript;
  or
- `contextCannotFit` returns no transcript.

Each complete disclosure includes `sessionAttachmentId` so multiple returned
transcripts never rely on array position. Application owns retries, limits, and
failure presentation.

`TranscriptAttachmentLine.text` and `words` intentionally overlap. Text preserves
coherent punctuation; Words provide stable evidence anchors. Punctuation is not a
Word. A Word may omit its time range when no reliable span exists. Lines and Audio
Events need no audio-source identity because each remains grouped inside one
Session attachment. Word IDs and Audio Event IDs remain because the coach can use
them as evidence targets.

## Responses, evidence, and Profile edits

`messageBlocks` form one ordered response batch, not a streaming protocol. A
Markdown block is ordinary coaching prose. An Evidence Observation is prose that
Presentation renders with evidence controls. The output limit and whole-response
validation bound the batch; there is no independent block-size limit.

Every `CoachEvidencePointer` is semantically untrusted. Application accepts one
only when:

- its `sessionAttachmentId` belongs to this Chat;
- its IDs exist in that attachment's canonical immutable transcript; and
- a Word range is ordered and belongs to that transcript.

The evidence need not have been disclosed during the current Attempt: the coach
may have retained relevant transcript conclusions in Coach Memory. Application
validates structural truth, not whether the evidence supports the coach's claim.

`proposeProfileEdits` contains reviewed semantic edits. Add selects a Statement
kind; Replace preserves the target Statement kind and therefore omits it; Retire
only identifies its target. The coach never allocates Statement IDs for additions
or replacements.

`appendProfileEvidence` contains evidence-only additions to active Statements. A
wholly evidence-only response may be committed silently. If any semantic edit
survives normalization, every surviving effect becomes one reviewed Proposal.
Application deduplicates evidence by `(statementId, Session)` using provider order.

A Reconsider trigger supplies the complete prior `CoachProfileEditProposal`
values, including their evidence. When targets became inactive, it also supplies
their `ProfileStatement` snapshots and any pending standalone evidence through
`inactiveEditTargets` and `inactiveTargetsEvidence`. Application requires at least
one of the three optional arrays, unique inactive target IDs, and exact resolution
of every referenced inactive ID. Any resulting effect still requires review.

The complete `CoachResponse` is one semantically untrusted batch. Application
rejects it atomically when schema, Memory, evidence, edit, conflict, or size
validation fails. For an ordinary user-message trigger, Application additionally
requires `messageBlocks`. Reconsider may validly return no message and no Profile
effect, which withdraws the old Proposal without publishing an empty Chat message.
