# Portable library

## Source-of-truth layout

Audora operates on one active user-selected Library directory at a time. Each
Library is an isolated project with no cross-Library IDs, references, searches, or
coaching context:

```text
Audora Library.audoralibrary/
├── library.json
├── preferences.json
├── profile/
│   ├── head.json
│   └── revisions/
│       └── prf-20260823T120000000Z-2ABC/
│           ├── revision.json
│           └── revision.sha256
├── sessions/
│   └── ses-20260822T153045123Z-P4R7/
│       ├── session.json
│       ├── audio/
│       │   ├── audio.json
│       │   ├── original.<ext>  # imported media only
│       │   └── audio.wav       # canonical mono timeline
│       ├── transcripts/
│       └── annotations/
├── chats/
│   └── cht-20260822T160201044Z-9NQF/
│       ├── chat.json
│       ├── pending-user-turn.json    # present only while unresolved
│       ├── messages/
│       │   └── <message-id>.json
│       ├── memory/
│       │   └── <memory-id>.json      # current structured Memory only
│       ├── proposal.json             # present only while unresolved
│       └── profile-write.json        # present only while unresolved
├── invocations/
│   └── <invocation-id>/              # the one active Library Invocation
│       ├── invocation.json
│       └── attempt.json              # the current Provider Attempt
├── jobs/
│   ├── .attempts.json                # per-Session sequence/current pointer
│   └── job-20260822T160300000Z-1ABC/
│       ├── job.json
│       └── candidate/
├── staging/
│   ├── recordings/
│   ├── jobs/
│   └── publications/
└── trash/
    ├── sessions/
    └── chats/
```

The tree shows ownership, not a requirement to retain resolved operational
records. A Chat has at most one unresolved Proposal or Profile-publication failure.
Resolved failures, Invocations, Provider Attempts, Proposals, and Profile-write
intents are deleted. A transient second Memory file may exist between installation
and cleanup; `chat.json` selects the only current Memory, and relaunch deletes any
unreferenced snapshot.

Manifests and entity files are authoritative. A future SQLite/FTS index is a
rebuildable cache and cannot be required to restore a Library.

`jobs/.attempts.json` is authoritative coordination state rather than a derived
search index. Under the `jobs/` repository lock, each newly admitted Job reserves
the next monotonic sequence for its Session, installs the Job directory, then
commits that sequence and the exact current-Job pointer. A pending reservation is
repaired on relaunch according to whether its exact Job directory was installed.
Schema-v1/v2 Libraries migrate their pre-sequence Jobs as a bounded legacy set;
the first new attempt receives sequence 1 and supersedes that set regardless of
its ID or wall clock. IDs and `createdAt` remain unchanged and are never used to
infer causality for new attempts.

Trash is persistent Library storage, not a retention queue. Audora supports
**Move to Trash** and **Restore** for Sessions and Chats. It provides no cleanup or
expiry mechanism; those remain backlog.

`library.json` records the format name, schema version, Library ID, creation time,
and last successful migration. `session.json` is the Session aggregate manifest
and commit marker. `audio/audio.json` is owned child metadata rather than an
independent entity.

An imported Session is assembled under one unpredictable
`staging/publications/<transaction>/<session-id>/` directory. Audora copies the
original bytes, creates and flushes canonical audio, writes `audio.json`, writes
`session.json` last, and validates the complete candidate before publication. It
then installs the whole Session directory into `sessions/` with same-volume
no-replace rename semantics and flushes that parent. A preexisting destination is
a collision and is never overwritten or merged. Failures before rename publish
no Session; a failure reopening after rename reports that the installed Session
needs refresh and never deletes the committed directory.

## Persisted schema versions

Only independently persisted root records and envelopes carry `schemaVersion`.
Nested values inherit their root's version. The current versioned roots are:

- Library and preferences manifests;
- Session and audio manifests;
- Transcript Revisions and persisted annotation aggregates;
- Profile head and Profile Revisions;
- Chat manifest, messages, current Memory, Pending User Turn and unresolved
  failure, Proposal, and Profile-write intent;
- active Invocation and Provider Attempt records;
- recording/transcription jobs and staging manifests;
- the machine-local Library-keyed admission ledger; and
- the diagnostic-log envelope.

Raw media, `revision.sha256`, and other content-addressed payloads do not gain a
schema field. Provider descriptors, requests, responses, transcript-tool DTOs, and
other generated provider contracts are transport values rather than persisted
roots and carry no `schemaVersion`.

Migrations transform persisted roots. A relaunched in-flight turn is interrupted
regardless, so Retry reconstructs the current provider request from its immutable
app-owned input instead of migrating an old provider envelope. If a historical
Chat root cannot be migrated without changing its meaning, Audora freezes that
Chat and instructs the user to create a new one; it does not invent replacement
history.

## Development Profile

Each Library owns one Development Profile. `profile/head.json` selects either one
immutable Profile Revision or the null Profile. The null Profile means the Library
currently has no Development Profile; provider projection is
`ProfileContext { statements: [] }`, and the next Profile write creates a
parentless revision. A newly created Library may begin in this state.

`head.json` is deliberately small:

```text
ProfileHead
  schemaVersion
  generation                 # last allocated physical generation
  statementGeneration        # last allocated semantic generation
  currentRevisionId?         # absent in the null Profile state
  currentRevisionSha256?     # absent with the current revision ID
  updatedAt
```

`currentRevisionId` and `currentRevisionSha256` are both present or both absent.

Every revision folder is a self-contained immutable bundle. `revision.json` is the
authoritative structured snapshot. `revision.sha256` contains the SHA-256 digest
of the exact `revision.json` bytes, and a non-null head binds its selected revision
ID to that same expected digest. No Markdown projection exists.

```text
ProfileRevision
  schemaVersion
  revisionId
  parentRevisionId?
  generation
  statementGeneration
  createdAt
  statements[]
    statementId
    statementKind
    wording
    supportingSessionCount
    evidence[]
      EvidenceReference
```

The Profile stores accepted current content, not the transaction that produced it.
A revision contains no `origin`, `changeSource`, `acceptedChanges`, Proposal,
Chat, Invocation, or Provider Attempt provenance. Adjacent Statement arrays are
sufficient to derive a semantic diff when one is needed.

`generation` advances for every installed revision. `statementGeneration`
normally advances only when a Statement is added, replaced, or retired;
evidence-only union retains it. Profile recovery is the explicit exception: it
advances both counters so every pending Proposal and Chat observes the restored
semantic authority. Chat Proposal staleness and Profile-update dividers react to
`statementGeneration`, not ordinary physical revision churn.

`supportingSessionCount` reports all accepted supporting Sessions. A provider
projection keeps that count but includes only Evidence References that can be
mapped to an attachment with the exact same `(sessionId, transcriptRevisionId)`.
A different revision of the same Session never inherits its Word or Audio Event
IDs. Missing or trashed evidence is retained in the local revision and still
contributes to the historical count. A local revision is valid only when the count
equals its distinct evidence Session IDs.

Provider-returned Profile edits are untrusted. Application allocates new Statement
IDs, resolves every Evidence Pointer against the Chat's immutable attachments and
canonical Transcript Revisions, and validates the complete response before any
effect becomes visible. Structural validation proves that the Session is attached
and each referenced Word or Audio Event exists. It does not decide whether the
evidence semantically supports the coach's claim.

Semantic edits, or semantic edits mixed with evidence appends, form the owning
Chat's one reviewed Profile Change Proposal. Pure evidence appends for active
Statements bypass Proposal review and use an idempotent `(statementId, sessionId)`
set union. Application keeps the first provider-order occurrence for each key.
Successful evidence-only publication is silent, advances only `generation`, and
creates no Chat divider. A failed local union retains the exact intended effect as
an unresolved UserRetryable Profile-publication failure with **Retry** and
**Discard**; it does not call the provider again.

An unresolved Proposal or Profile-publication failure disables the Chat composer
until its available action resolves it. This prevents a second Profile effect from
queueing behind the one unresolved transaction.

Accepting a reviewed Proposal first persists one immutable Profile-write intent,
including its expected semantic base and intended revision ID. The Library-scoped
Profile commit coordinator serializes every Profile writer and compare-and-swaps
the expected head generation, revision ID, and digest. Relaunch reconciles the
intent before admitting another writer.
Once the revision and Chat state agree, the intent and resolved Proposal are
deleted. Discarded and withdrawn Proposals are also deleted. Saving accepted
Proposal details for later hover inspection remains backlog.

### Integrity and recovery

Audora verifies the selected revision when opening a Library, before building a
Coach request, and before committing a Profile change. A healthy revision has a
supported root schema, a matching detached hash, a structurally valid snapshot,
and internally valid evidence shapes. An unavailable, missing, or trashed Session
referenced by otherwise valid evidence does not make the revision unhealthy.

An unhealthy current Profile blocks new Invocations and Profile writes and shows
a persistent Library-level banner. **Revert to Latest Healthy Profile** scans the
immutable revision bundles. Any physical generation claimed by more than one
bundle is ambiguous; every revision in that collision is recovery-ineligible even
when its own schema, structure, and detached hash are valid. Recovery chooses the
healthy revision with the highest remaining unique physical generation. It
publishes a fresh revision containing that snapshot, assigns `generation` and
`statementGeneration` above every known revision and head watermark—including
colliding generations—uses the selected revision as parent, and atomically switches
the ID/digest pair in `head.json`. Broken and colliding revision bundles remain on
disk.
**Reveal Library** opens the Library in the local file explorer for backup or
manual inspection.

If no recovery-eligible healthy revision exists, the recovery action writes a
valid null `head.json` after advancing both allocation watermarks above every known
value. Coach requests then use an empty Profile until a new parentless revision is
created above those watermarks. Recovery never edits, deletes, or silently repoints
to a historical revision.

See the complete [`head.json`](../examples/profile-revision/head.json),
[`revision.json`](../examples/profile-revision/revisions/prf-20260823T120000000Z-2ABC/revision.json),
and [`revision.sha256`](../examples/profile-revision/revisions/prf-20260823T120000000Z-2ABC/revision.sha256)
examples.

Every immutable Profile and Transcript Revision superseded by another revision is
retained. Statement retirement affects only the new current Profile Revision.
Age-based revision cleanup remains backlog.

## IDs and references

Entity IDs are typed and immutable:

```text
ses-20260822T153045123Z-P4R7
cht-20260822T160201044Z-9NQF
prp-20260822T160100000Z-2ABC
prf-20260823T120000000Z-2ABC
stm-20260823T114500000Z-K6RT
```

- The timestamp is fixed-width UTC with milliseconds.
- The suffix is four Crockford Base32 characters.
- The creator checks the target entity folder and regenerates on collision.
- Authoritative dates are separate fields. Code never derives relationships or
  business state by parsing an ID.

References are explicit IDs rather than paths or timestamp inference:

```text
Chat -> immutable Session/Transcript Revision attachments, Draft, current Memory, message tail
Pending User Turn -> exact locked Draft version and stable response position
Invocation -> immutable intent and prepared app-owned context
Provider Attempt -> its Invocation, fresh transcript-read authority, and response position
Textual Event -> stable Word range in one Transcript Revision
Audio Event -> stable Session Time Range
Evidence-backed Observation -> one or more nested Evidence References
Profile Statement -> zero or more nested Evidence References
```

The Session manifest owns its Audio Asset by containment; there is no independent
cross-Session audio identity. Transcript Revisions record the owned-audio and
source fingerprints from which they were derived. Reverse relationships are
derived at load or by a rebuildable index, preventing two manifests from becoming
competing authorities.

Resolution returns an explicit state:

```swift
enum ReferenceResolution<Value> {
    case found(Value)
    case missing(id: EntityID)
    case inTrash(id: EntityID)
    case corrupt(id: EntityID, reason: String)
    case unsupportedSchema(id: EntityID, version: Int)
}
```

Fallback behavior is non-destructive:

| Reference problem | Behavior |
| --- | --- |
| Owned Session audio missing or corrupt while transcript evidence is intact | Keep the Session, transcript, annotations, linked Chats, and Profile evidence; disable playback/retranscription and allow exact-artifact restoration after fingerprint verification |
| Transcript Revision missing, corrupt, or unsupported | Preserve the Session, Chat, and accepted Profile Statements; render references into that revision unavailable |
| Evidence anchor missing from an otherwise readable Transcript Revision | Preserve its owning Statement or Observation and display snapshot; mark only that reference unavailable |
| Chat attachment missing or in Trash | Preserve its immutable pin and Chat messages; display it as unavailable and never substitute another revision |
| Current Chat Memory or another authoritative Chat record corrupt | Freeze that Chat permanently and instruct the user to create a new Chat; never send the bytes or offer Memory reset |
| Selected Transcript Revision missing | Choose the newest valid completed revision for Session review, or offer transcription; never change an existing Chat attachment |
| Annotation Word IDs missing | Hide only the stale overlay; retain the canonical transcript |
| Required local transcription model unavailable | Preserve the preference and Session evidence; offer Prepare, Reinstall, or Retry without silently changing engines |
| Last selected entity missing | Open the Library home |

An unresolved ID is never erased automatically. Restoring a copied entity can heal
the relationship without editing the referring record. `inTrash` is created only
by **Move to Trash** and returns to `found` only through **Restore**. `missing`
means expected content is externally absent.

## Chat state

`chat.json` stores `creationKind: newChat | sessionAnalysis`, immutable
`ChatSessionAttachment { attachmentId, sessionId, transcriptRevisionId }` values,
optional `originAttachmentId`, the editable Draft, the committed message tail, and
the current Memory pointer. It also records the Profile `statementGeneration` at
creation. Every published Coach turn records the `statementGeneration` used by its
Invocation. `attachmentId` is unique only within its Chat and is the sole Session
identity in provider DTOs. The app-side
Session/revision compound key never enters provider JSON.

New Chat permits zero or more selected Sessions and sends nothing until the user
submits a Draft. Analyze Session reuses the same searchable multi-select creation
sheet, keeps the source Session selected, and permits additional Sessions. It
stores `creationKind: sessionAnalysis` and the source `originAttachmentId`, then
seeds and sends an ordinary Draft:

- one Session: **Analyze this Session and give me practical speaking feedback.**
- multiple Sessions: **Analyze these Sessions and give me practical speaking
  feedback.**

The Draft itself is the durable input; there is no `analysisDraftSeed`, template
provenance, or Analyze-specific provider trigger. If admission becomes unavailable
before the staged Chat is installed, creation keeps the sheet open, creates no
Chat, and shows an accessible fleeting notice. If exact context preparation finds
that the created Chat cannot fit, the Chat is installed with the seeded Draft
locked under `CoachContextCannotFitUserRetryable` and no Invocation.

Attachments never change after Chat creation. A new Chat is the only way to use a
different set. Starting analysis may first show the derived count and up to three
recent clickable Chats that already attach the source Session; the Session stores
no reverse Chat pointer.

The Draft is persisted in the Chat immediately before Send and at least every two
seconds while dirty. Send locks its exact version in one Pending User Turn. The
Draft remains visible in the disabled composer while processing or while a
turn-level UserRetryable failure is unresolved. The user message enters history
only when one atomic publication installs both user and coach messages. **Retry**
creates a new Invocation for the same locked intent. **Discard** deletes the
failure and Pending User Turn, unlocks the unchanged populated Draft, and changes
no successful history.

Errors, processing state, and Proposals are operational UI state, never Chat
messages. A currently unresolved Failure Descriptor is persisted only as long as
Retry/Discard needs it. Resolution deletes it.

### Coach Memory

Coach Memory is one bounded structured replacement owned by its Chat:

```text
CoachMemory
  generalNotes
  sessionSummaries[]
    sessionAttachmentId
    notes
```

Every request includes the current Memory. `CoachResponse.newMemory` is optional:
omission retains the current value, and canonical equality is treated as omission.
When present, Application validates the complete value and publishes it atomically
with the response. After the Chat pointer switch is recoverable, the superseded
snapshot is deleted. Historical Memory snapshots are not retained, and there is no
Reset Coach Memory action. Discarding a Profile Proposal produced beside a Memory
update does not roll Memory back; the current structured Profile remains the
authority when Memory conflicts with it.

The complete successful Chat history remains stored and participates in context
planning. History/Memory compaction is backlog. Until it exists, an over-limit
turn becomes `CoachContextCannotFitUserRetryable` with the instruction to create a
new Chat. Discard hides the error and unlocks the same Draft; it does not make the
Chat read-only.

A user-approved semantic Profile update creates a thin app-owned **Profile was
updated** divider in each affected Chat. Evidence-only revisions do not create a
divider or stale a Proposal. If a Profile update occurs while a user turn is
pending, Presentation waits until that action succeeds, is interrupted, is
discarded, or is replaced by Retry. A Retry that will use the new Profile gets the
divider before its eventual user turn. Presentation derives divider positions from
the Chat's creation generation, each published turn's used generation, the pending
Invocation generation, and the current head. It never persists a divider as an
audit event or compares wall clocks. A later update may replace a tail divider
before another message appears, while distinct adjacent events remain renderable
without requiring a message between them.

## Invocation and admission

An Invocation is the only way to invoke the Coach. It owns one immutable intent:
answer the Pending User Turn, Reconsider a stale Profile Proposal, or eventually
compact Coach Memory. Compaction remains backlog.

Application exposes one `Invocations.tryInvoke` gateway. Before creating an
Invocation, it verifies that the action is enabled, the Chat is idle where required,
no other Library Invocation is active, the current context fits, and the Library-keyed
rolling admission gate has capacity. The gate admits at most one top-level
Invocation per 60 seconds and is stored in machine-local app data. Send, Invocation
Retry, and Reconsider are disabled while it is closed; local Profile-publication
Retry remains available. No waiting state or deferred launch is persisted. If a
new Send loses a final eligibility, concurrency, or admission race,
Application deletes its provisional Pending User Turn, unlocks the unchanged Draft,
and shows a fleeting accessible notice. Existing Retry and Reconsider intents keep
their failure or Proposal state.

Admission is claimed and the Invocation becomes durable before the provider
starts. A rare failure after the durable admission debit may waste that one unit;
it must never launch an unrecorded request and leaves the underlying intent
interrupted and user-retryable. Every Provider Attempt gets a fresh Attempt ID,
provider idempotency value, transcript handles, and one-time read authority.
Automatic retry stays under the Chat's single `processing` state and
uses delays of 5, 10, then 15 seconds. A user-triggered Retry creates a new
Invocation and therefore fresh Attempt and transcript-read values.

Relaunch converts every active Invocation to an interrupted UserRetryable failure.
Automatic retry timers do not resume, and a complete provider response that was not
atomically published is discarded rather than resumed from durable staging.
Resolved Invocations and Attempts are deleted. Late results cannot publish because
the response position no longer names their Invocation/Attempt authority.

## Atomicity and recovery

- Write JSON to a sibling `.partial`, flush it, then atomically replace the final
  file.
- Record and normalize audio inside Session staging. Publish owned audio metadata
  only after validation, and publish `session.json` last as aggregate commit
  marker.
- Publish a Transcript Revision only after schema and integrity validation.
- Build Chat creation, its ordinary Draft, and any Pending User Turn in staging;
  atomically install either a coherent Chat or nothing, except for the documented
  context-fit branch that installs a coherent Chat with its local failure.
- Before provider work, durably lock one Pending User Turn and its stable response
  position, then admit and persist its Invocation. No Attempt starts earlier.
- Hold a complete provider response in process memory while validating it. Stage
  its app-owned messages, optional Memory replacement, and optional Profile effect,
  then switch the Chat manifest by compare-and-swap. A crash before the switch
  publishes none of them and becomes interruption after relaunch.
- Install a Profile Revision folder only after `revision.json` and its detached
  hash are flushed. Replace `head.json` last under the Profile coordinator; that
  pointer replacement is the commit point.
- Reserve a Session processing attempt in `jobs/.attempts.json` before installing
  its Job directory, then atomically commit the matching sequence/current pointer.
  Relaunch either completes an installed pending reservation or drops an absent
  one; it never reorders attempts by `createdAt`.
- Move or restore a Session or Chat as one aggregate without rewriting references.
  Restore fails rather than overwriting an existing active target.
- Unknown newer root schemas open read-only. A corrupt individual entity does not
  prevent healthy independent entities from loading.

Durable transcription candidates remain untrusted until Application validation
promotes them. Raw provider responses are not durable candidates. A validated but
unresolved Proposal or Profile-write failure is app-owned operational state, not a
provider response archive.

## Diagnostics

Audora keeps a rotating metadata-only diagnostic log capped at 100 MiB. Every
automatic or user-visible retry records its normalized reason, Invocation and
Attempt identifiers, provider/error classification, timing, retry number, context
sizes, and Memory size. It never records message text, Memory contents,
transcripts, evidence excerpts, raw provider output, raw CLI stderr, capabilities,
idempotency values, credentials, or Library paths. Resolved error records disappear
from product state even though their non-content diagnostic metadata may remain
until log rotation.

## Portability

Audora supports creating a Library, choosing an existing copied Library, and
revealing it for backup. Direct copying is consistent only while the app is closed.
Live snapshot export and Library merging remain backlog.

Every operation is scoped to the active Library. Development Profile Statements,
Chats, Evidence References, and coaching context cannot resolve an entity from a
different Library even if two directories contain similarly named artifacts.

Chat messages are authoritative Chat-owned content. Moving, restoring, or losing a
Session changes only structured-reference resolution; it never rewrites Chat prose
or accepted Profile Statements.

Audio import copies the exact source into the Session and retains it for that
Session's lifetime. Audora also creates canonical mono WAV and never depends on an
external absolute URL. Every stored artifact path is relative and rejects `..`,
absolute paths, and symlinks.

Machine-local state outside the Library includes:

- the locator or bookmark used to find the Library;
- microphone and other macOS grants;
- Codex authentication and credentials;
- transcription runtime, model installation, and caches;
- hardware selection and performance history;
- the Library-keyed rolling Invocation-admission ledger;
- the metadata-only rotating diagnostic log; and
- window geometry and launch-at-login registration.

Portable preferences preserve language, global annotation visibility, and
playback rate. If a pinned dependency is unavailable on a copied Mac, the app
reports it without rewriting Library data or substituting another engine.

The Library is a transparent portable format and is not encrypted by Audora.
At-rest confidentiality relies on macOS account permissions and disk encryption
such as FileVault. App-managed encrypted Libraries remain a future design.
