# Release readiness

The private personal-use release is ready only when the feasibility decisions are
recorded and every applicable fixture below passes in the selected signed Release
execution profile.

## Local workflow

- After dependencies and the transcription model are installed, recording, local
  transcription, review, storage, and annotation work with the web app, Convex,
  and network stopped.
- Coaching reports an explicit offline state when its configured provider is
  unavailable.
- The signed Hardened Runtime, non-App-Sandbox Release profile passes without an
  unsigned development shortcut.
- Recording/import seals audio before transcription begins.
- Recording shows persistent five-minute and one-minute warnings, stops and seals
  at 45:00, and explains the automatic stop after the transition.
- Imported M4A playback and transcript timestamps share one canonical timeline.
  Import retains the original file and canonical normalized artifact.
- Mono and stereo fixtures produce the documented deterministic mono timeline;
  files over 45 minutes fail before Session publication.
- One main Library window exists. A second open request focuses it rather than
  creating another writer.

## Transcription and review

- Labeled one-minute and 45-minute fixtures retain their beginning/tail phrases
  and required disfluency events within versioned qualification thresholds.
- Progress never regresses; ETA is labeled approximate; Cancel and worker failure
  retain retryable audio.
- Only a complete validated Transcript Revision becomes selected.
- Force-quit, capture-device failure, and crash fixtures retain recoverable
  Recording staging and offer exactly **Seal Recovered Recording** or **Discard**.
  Seal is idempotent, Discard removes only that staging, and Resume is absent.
- Word and line clicks seek correctly. Punctuation is not a Word entity and seeks
  through the closest previous timed Word, then the closest following timed Word,
  then the line start.
- One global control changes every annotation overlay together. Hidden or dimmed
  transcript evidence remains copyable.
- Provider projection retains coherent line text and Words, omits Textual Events,
  and includes only Audio Events that Words cannot express. Lines and Audio Events
  remain nested under their Session attachment.

## Persisted schemas and migration

- Every independently persisted root named in
  [`portable-library.md`](portable-library.md) has `schemaVersion`; its nested
  values inherit that version. Raw media and detached hashes do not pretend to be
  versioned JSON roots.
- Generated provider descriptors, requests, responses, and transcript-read DTOs
  carry no persistence version.
- Each supported old root migrates atomically and idempotently. Unknown newer roots
  open read-only.
- Relaunch interrupts an in-flight turn. Retry rebuilds the current provider DTO
  from the immutable app records, so no old provider envelope is migrated.
- If historical Chat data cannot be migrated without changing meaning, the Chat is
  permanently frozen with an instruction to create a new one. Healthy independent
  Chats and Sessions remain available.
- Contract checks compile the authoritative TypeSpec and fail when a checked-in
  JSON Schema drifts.

## Library storage and recovery

- A closed-app Library copy opens on another Mac without an index or machine-local
  cache.
- JSON partial-write fixtures after every write/flush/install step expose one
  coherent old root or one coherent new root.
- Missing, corrupt, unsupported, and in-Trash references produce the documented
  non-destructive degraded states.
- Moving a Session to Trash moves owned audio, transcripts, and annotations as one
  aggregate while retaining every Chat and Profile reference. Restore returns the
  same aggregate under the same ID and fails rather than overwriting a collision.
- Trash survives relaunch and closed-app copying. No UI or maintenance job removes
  Trash content.
- Every durable recording/transcription job passes restart reconciliation.
- Resolved Failure Descriptors, Invocations, Provider Attempts, Proposals, and
  Profile-write intents are deleted. At most their non-content diagnostic metadata
  remains until log rotation.
- A validated complete provider response is not a recoverable staging artifact. A
  crash before atomic Chat publication produces interruption and preserves the
  locked Draft; relaunch never resumes response validation or publication.
- Unreferenced `.partial` files, candidate publications, and superseded Memory
  snapshots are removed without selecting them by recency.
- The metadata-only diagnostic log rotates before exceeding 100 MiB and never
  contains user messages, Memory text, transcripts, evidence excerpts, provider
  output, raw CLI stderr, credentials, capabilities, idempotency values, or Library
  paths.

## Development Profile

- The committed example matches
  [`head.json`](../examples/profile-revision/head.json), the selected
  [`revision.json`](../examples/profile-revision/revisions/prf-20260823T120000000Z-2ABC/revision.json),
  and its detached
  [`revision.sha256`](../examples/profile-revision/revisions/prf-20260823T120000000Z-2ABC/revision.sha256).
  `head.json` binds the current revision ID and expected digest as one nullable
  pair. No `profile.md` exists or is generated.
- Profile publication crash fixtures expose the complete old revision or complete
  new revision. `head.json` switches last by compare-and-swap over expected
  generation, revision ID, and digest.
- Every Revision contains structured active Statements and Evidence References,
  `generation`, and `statementGeneration`. It contains no `origin`,
  `changeSource`, `acceptedChanges`, Proposal, Chat, Invocation, or Attempt
  provenance.
- Each local Statement's `supportingSessionCount` equals the distinct Session IDs
  in its complete accepted evidence. Provider projection may filter evidence to
  exact attached `(sessionId, transcriptRevisionId)` pairs without lowering that
  historical count; another revision of the same Session is not a match.
- Physical `generation` advances on every new revision. Evidence-only publication
  retains `statementGeneration`; add/replace/retire advances it.
- Profile health rejects unsupported schema, hash mismatch, structural failure, or
  internally invalid evidence shape. A missing or in-Trash referenced Session does
  not make an otherwise valid Profile revision unhealthy.
- Current-Profile corruption blocks new Invocations and Profile writes and shows
  the persistent Library banner. **Revert to Latest Healthy Profile** selects the
  highest-generation healthy revision from a generation claimed by exactly one
  bundle, copies it into a fresh revision, sets both counters above all known/head
  watermarks, uses the selected revision as parent, and atomically switches the
  head ID/digest pair. Every revision in a generation collision is skipped, and all
  broken and colliding bundles remain.
- Collision fixtures prove that recovery selects the highest uniquely generated
  healthy revision below a collision rather than using timestamps or revision-ID
  ordering to choose within the collision.
- When no recovery-eligible healthy revision exists, recovery writes a null head
  after advancing both watermarks above every known value. Coach receives
  `ProfileContext { statements: [] }`; the next Profile write is parentless and
  continues above those watermarks.
- Recovery is a semantic-generation event: pending Proposals become stale and each
  affected Chat can derive its Profile-update divider.
- Every superseded Profile and Transcript Revision remains byte-for-byte readable;
  retirement and retranscription never mutate history.

## Chat creation and Drafts

- New Chat uses the shared searchable multi-select Session sheet, permits zero or
  more Sessions, and sends nothing until the user submits a Draft.
- Analyze Session opens the same sheet with its source Session selected and allows
  additional Sessions. The reusable multi-selection behavior also supports bulk
  **Move to Trash** without a second selection model.
- Chat creation freezes every `(sessionId, transcriptRevisionId)` pair under a
  stable Chat-scoped `sessionAttachmentId`. Later attach, detach, or revision swap
  controls do not exist.
- `creationKind: sessionAnalysis` requires its source `originAttachmentId`;
  `newChat` forbids it. Neither value is sent to the provider.
- Create & Analyze seeds an ordinary Draft with exactly:
  - one Session: **Analyze this Session and give me practical speaking feedback.**
  - multiple Sessions: **Analyze these Sessions and give me practical speaking
    feedback.**
- The seeded Draft is visible in the ordinary composer and follows the same
  Send/Retry/Discard path. No `analysisDraftSeed`, template provenance, or Analyze
  provider trigger is persisted.
- A final admission/concurrency race before Chat installation keeps the creation
  sheet open, creates no Chat, and produces an accessible fleeting notice. A final
  context-fit failure installs the coherent Chat with the seeded Draft locked under
  `CoachContextCannotFitUserRetryable` and creates no Invocation.
- Starting analysis with existing linked Chats shows their derived total and at
  most three recently updated accessible links before confirmation. Sessions store
  no reverse Chat pointer.
- Draft edits persist at least every two seconds while dirty and synchronously
  before Send, navigation, and orderly termination. Monotonic Draft versions keep
  delayed autosave from replacing a newer flush.
- Send atomically creates one Pending User Turn that locks the exact Draft version
  and response position. Processing and every turn-level UserRetryable failure
  leave that text visible in a disabled composer.
- No user message enters history until one atomic success publishes the user and
  coach messages. **Retry** reuses the locked intent without duplicating it.
  **Discard** removes the error and Pending User Turn and unlocks the same populated
  Draft for editing.
- Errors and Proposals never appear as Chat-history records. Capacity Discard does
  not make the Chat read-only.

## Context planning and Session access

- The creation sheet shows each Session's duration and conservative token cost,
  the Profile cost before any selection, and live `used/max` context. The total
  reflects current Profile, Memory, eligible history, Draft, fixed overhead, inline
  transcripts, all possible on-demand transcript reads, and the response reserve.
- The UI estimate is informative. Exact serialized context is remeasured before
  Invocation admission, so a later Profile change can make a previously quoted
  turn fail locally.
- Context fit uses token amount rather than message count. Qualification covers
  adversarial Unicode, JSON escaping, every current schema, tool framing, and
  adapter wrapper, and proves the estimator never undercounts a supported fixture.
- Provider configuration rejects reserve plus safety margin greater than or equal
  to the context window. A maximum valid serialized Coach Memory fits inside both
  the minimum Request's usable input and the minimum Response's token reserve and
  collector byte ceiling.
- A locally over-limit turn creates no Invocation, Attempt, admission debit, or
  provider request. It locks the Draft under the UserRetryable **Chat size
  exceeded. Please create a new one.** error. Retry repeats exact planning; Discard
  unlocks the Draft.
- Every provider request includes the complete current structured Profile, current
  structured Memory, eligible successful Chat history, current trigger, and the
  immutable attachment descriptions. It does not duplicate Profile history.
- History projection preserves user text exactly and joins each coach message's
  persisted block Markdown in order with exactly two newline characters. It omits
  local evidence controls and pointers, never an eligible successful turn.
- Small attached transcripts are included inline. Each large attachment receives a
  fresh Attempt-local handle; one atomic read can request any nonempty subset. One
  Attempt token authorizes the complete attached set, while the app resolves only
  handles from the requested subset.
- Token estimates and remaining budgets stay app-side. The transcript-read Request
  contains neither token estimate nor available-read budget.
- The transcript read is all-or-nothing for its requested subset. Application owns
  transport retries, fit checks, and fallback. It never relies on the coach to
  retry the tool.
- `sessionUnavailable` or defensive `contextCannotFit` aborts the Coach response
  and becomes a turn-level UserRetryable error. It names at most three unavailable
  Sessions as accessible links and asks the user to retry or discard. The model
  does not generate an incomplete excuse.
- The Coach instruction requires transcript grounding. If current Memory and input
  contain no sufficient knowledge, it reads every attached Session needed for the
  request and stores useful per-Session summaries in optional `newMemory`. If it
  detects that it conflated two Sessions, it asks the user to send the message
  again rather than presenting the confused answer as grounded.
- On the first response in a Session Analysis Chat, the Coach attempts any useful
  evidence-backed Profile effects in the same batch. Validation and deduplication
  may correctly leave no effective Proposal or Evidence Append.

## Coach Memory

- Empty Chat Memory has the canonical structured shape with empty `generalNotes`
  and `sessionSummaries`.
- Each request carries the current Memory. A successful response may omit
  `newMemory` to retain it. Canonically equal `newMemory` is treated as omission.
- Every returned Memory snapshot is structurally valid, bounded below the
  provider's maximum context, and refers only to immutable attachment IDs owned by
  its Chat.
- Response publication switches the Chat to the new Memory atomically with its
  messages. The prior snapshot remains only until the switch is recoverable, then
  is deleted. Relaunch cleans any unreferenced snapshot.
- Historical Memory is never retained. No Reset Coach Memory command or event
  exists.
- Discarding a Profile Proposal that arrived beside `newMemory` retains the current
  Memory. The structured current Profile outranks conflicting Memory.
- Any corrupted authoritative Chat record, including current Memory, permanently
  freezes that Chat and tells the user to create another. Corrupt content is never
  sent to a provider.
- History and Memory compaction remain backlog. Until implemented, exact context
  excess uses the ordinary Chat-size failure rather than silently dropping history.

## Invocation and Provider Attempts

- `Invocation` is the one domain model for Coach work. The current intent union
  admits answering a Pending User Turn and Reconsidering a stale Profile Proposal;
  Memory compaction remains an inactive backlog intent.
- Presentation invokes only `Invocations.tryInvoke` with stable app IDs. The module
  checks action eligibility, Chat state, exact context, one active Invocation per
  Library, and rolling admission before admitting the intent.
- Send and Reconsider are disabled while the Coach is processing. Reconsider is
  admitted only from an idle Chat. Send, Invocation Retry, and Reconsider are
  disabled while the app-owned admission gate is closed, with an accessible
  explanation and forbidden pointer cursor rather than a waiting state. Local
  Profile-publication Retry remains available.
- The machine-local Library-keyed ledger admits at most one top-level Invocation
  per rolling 60 seconds. A rejected preflight writes no Invocation and consumes no
  unit. If a new Send loses that final race, its provisional Pending User Turn is
  removed, its unchanged Draft unlocks, and an accessible fleeting notice appears;
  Invocation Retry and Reconsider retain their existing failure or Proposal.
  Context rejection instead keeps the Pending User Turn under the capacity failure.
  After successful admission, the ledger debit and Invocation are durable before
  provider launch. A failure after debit but before Invocation installation launches
  nothing, may consume the unit, and leaves the underlying intent interrupted and
  user-retryable.
- Every Provider Attempt has a fresh ID, provider idempotency value, transcript
  handles, one-time transcript access, and publication authority. User Retry creates
  a new Invocation and fresh first Attempt values.
- Transient rate-limit, network, timeout, and server failures are
  `CoachProviderErrorAutoRetryable`. Automatic retry remains one visible
  `processing` state and uses 5, 10, then 15 seconds, bounded to the initial Attempt
  plus three retries.
- Provider authentication, permission, unavailable-model, billing, quota,
  refusal, and exhausted transient failures become
  `CoachProviderErrorUserRetryable` with **Retry** and **Discard**. Retry remains
  enabled when admission permits; the app does not guess whether configuration
  changed.
- A provider-reported truncation or response-collector overflow gets at most one
  automatic repair Attempt within the same total bound. Its pinned instruction
  explicitly tells the coach to return a shorter valid complete response; partial
  prior output is not replayed. A repeat becomes UserRetryable.
- Every Attempt configures the provider output-token ceiling at or below
  `responseReservedTokens`, and the pinned instruction tells the Coach that its
  complete structured response must fit. Collector-byte and schema checks still
  reject overflow or truncation atomically.
- Every UserRetryable outcome logs its normalized reason. Safe displayed provider
  text comes from a structured provider error field or an adapter-owned sanitized
  mapping; raw CLI stderr is never displayed or logged.
- Stop terminates and reaps the active Attempt before a successor can start. A late
  result cannot publish unless the response position still names its Invocation and
  Attempt. Stop publishes nothing and leaves the locked Draft or stale Reconsider
  Proposal under the ordinary interrupted UserRetryable **Retry**/**Discard** state.
  Discard unlocks an answer Draft or restores the stale Proposal actions; it does
  not silently discard the Proposal itself.
- Relaunch converts every active Invocation into interruption, preserves its locked
  Draft or Reconsider intent, and resumes no timers or provider requests. No staged
  complete response is validated or published after relaunch.
- Resolved Invocations and Attempts are deleted.

## Coach response publication

- Normal turns require at least one message block. Reconsider may return no message
  when nothing needs explanation. `newMemory`, Profile edit proposals, and evidence
  appends remain optional independently subject to semantic validation.
- The complete structured response is untrusted and validated as one batch. Any
  schema error, oversized output, invalid edit, invalid evidence shape, or dangling
  target rejects the whole response; no partial answer or Profile effect publishes.
- A returned Evidence Pointer is accepted only when its `sessionAttachmentId`
  belongs to the Chat, the pinned Transcript Revision is canonical, and every Word or
  Audio Event target exists and forms a valid ordered range. Current-Attempt
  disclosure is not required because the coach may have retained the evidence in
  Memory. Application does not judge semantic relevance.
- One successful Chat compare-and-swap publishes the locked user Draft, complete
  coach message, optional Memory replacement, and at most one Profile-effect
  classification. A crash or stale response position publishes none of them.
- A response with surviving semantic edits produces exactly one reviewed Proposal;
  any surviving evidence appends join it. A wholly evidence-only response enters
  the silent local union path. The two paths cannot coexist.
- Profile-edit Proposals expose **Accept** and **Discard**, not Discuss. Their label
  explains that editing means discarding, talking with the Coach, and later asking
  it to remember the settled change.
- An unresolved Proposal or Profile-publication failure disables the composer so
  another Profile effect cannot queue behind it. Resolution restores ordinary
  Chat input.
- Every Reconsider is a full Invocation and response. The trigger includes complete
  previous edit proposals, inactive targets, and pending evidence for inactive
  targets. Any resulting Profile effect requires another explicit review,
  including an evidence-only result.
- If Reconsider withdraws every effect and no retained active append remains, the
  old Proposal is deleted, optional `newMemory` and any response message publish
  normally, and a 10-second accessible **Suggestion is no longer relevant** toast
  appears without entering history.
- Pure evidence union keeps the first provider-order occurrence of each
  `(statementId, sessionId)` key. Success is silent. Failure retains the exact
  app-generated wording and effect as one UserRetryable publication failure. Retry
  reruns only the local write; Discard deletes it without rolling back messages or
  Memory.
- Accept persists one immutable commit intent before Profile publication. Crash
  fixtures cover pre-write, revision install, head switch, and Chat cleanup. Retry
  reuses the intended revision; Discard is allowed only after reconciliation proves
  it never committed.
- Evidence-only revisions neither stale pending Proposals nor create a divider.
  Semantic or recovery `statementGeneration` changes stale them. Reconsider is
  available once the Chat is idle.
- Each affected Chat derives **Profile was updated** from its last observed
  `statementGeneration`. A pending action delays it until success, interruption,
  Discard, or replacement by Retry; a retried action that uses the new Profile is
  ordered after the divider. A newer tail update coalesces the prior divider when
  no message intervenes; the UI can still render distinct adjacent dividers
  correctly.
- Divider fixtures use the Chat's creation generation, each published turn's used
  generation, the pending Invocation generation, and the current head. They persist
  no divider record and perform no wall-clock ordering.
- Accepted, discarded, withdrawn, and superseded Proposals are deleted after their
  outcome is durable. Accepted-Proposal history and hover details remain backlog.

## Evidence presentation and trust boundary

- Coach responses support ordered Markdown and Evidence-backed Observation blocks.
  An Observation is a persistent inline inset block, not a hover-only overlay.
- Each evidence control displays a subtle highlight and underline on hover.
  Keyboard focus provides equivalent feedback plus a visible focus indicator.
- An available control opens the exact attached Session/Transcript Revision,
  highlights the canonical anchor, and seeks when possible. Missing or in-Trash
  evidence remains focusable with a visible unavailable state and accessible
  explanation.
- Opening Coach evidence never creates a transcript comment or annotation. Textual
  annotations remain local; the Coach independently evaluates transcript content.
- Provider-facing tasks receive no Library path or general filesystem tools from
  Audora. They inherit no user MCP servers and see only the allowlisted transcript
  read when the selected adapter supports it.
- Bearer capabilities, idempotency values, and credentials are absent from model
  content, portable files, Chat history, diagnostics, and provider responses.
  Opaque transcript handles appear only in the current Coach Request and its
  transcript-tool exchange; they are never persisted or logged.
- An already accepted Profile Statement remains available even if its supporting
  Session is not attached or later becomes unavailable. Inspecting or adding new
  support requires an eligible attached Session.
- Profile edits describing personality, identity, motives, character, or
  psychological traits are rejected; Profile content describes evidence-linked
  speaking behavior, goals, and user-authored self-assessment.
- At least one qualified transcription/use profile permits the selected evidence
  to become downstream Coach context. Acceptance cannot launder evidence from an
  engine whose terms prohibit that use.

## Portable architecture and qualification

- Domain and Application tests run without SwiftUI, AVFoundation, the
  transcription runtime, Codex, network access, or a real user Library.
- Domain, Application, and Contracts compile and pass their portable suites on
  macOS and Linux.
- The authenticated Coach adapter passes isolated launch, structured output,
  transcript-tool, cancellation, timeout/reaping, and no-local-rollout tests.
- Adversarial worker tests prove unrelated filesystem paths and network endpoints
  are unavailable to cached transcription in the selected execution profile.
- Signing, dependency/model preparation, offline operation, and the complete
  45-minute workflow pass from a clean supported Mac.

Numeric quality, coverage, runtime, memory, thermal, token-estimator, and output-
collector thresholds are published as versioned qualification fixtures during the
feasibility phase. The first Codex process, output, and failure fixtures plus their
current failed qualification decision are published in
[`Qualification/CodexCLI`](../../Qualification/CodexCLI/README.md). Its 4,096-byte
response collector and 4,096-reported-output-token ceilings are spike bounds, not a
qualified provider descriptor: Codex CLI 0.143.0 cannot configure the required
provider-side token cap or reduce its model-visible tool surface to Audora's sole
optional transcript read.
