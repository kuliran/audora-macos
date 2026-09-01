# Coaching and chat

## Provider seam

Coaching is independent of transcription and annotation. Application depends on
one provider interface:

```swift
protocol CoachProvider {
    func descriptor() -> CoachProviderDescriptor
    func health() async -> ProviderHealth
    func run(
        request: CoachRequest,
        execution: ProviderAttemptMetadata,
        transcriptAccess: CoachTranscriptAccess
    ) async throws -> CoachResponse
    func cancel(attemptID: ProviderAttemptID) async
}
```

The private build supplies one adapter: the ChatGPT-authenticated Codex CLI. A
future provider must qualify against the same request, response, evidence, budget,
and failure invariants before it becomes selectable. Presentation never invokes a
provider or branches on its identity.

[`contracts.tsp`](../contracts/contracts.tsp) is the TypeSpec compilation entry
point. The provider aggregate remains in `coach-provider.tsp`; app-only provider
configuration lives in `coach-provider-configuration.tsp`; coach-visible exchanges
live in `coach-provider-protocol.tsp`. Provider DTOs are transport values and carry
no persisted-data `schemaVersion`.

The adapter runs Codex non-interactively with structured output, an empty scoped
working directory, an allowlisted environment, and no Library path. Browser,
shell, project context, inherited MCP servers, plugins, and user-authored Codex
rules are unavailable to the model. The only optional tool is Audora's read-only
transcript endpoint described below.

## Invocation

An **Invocation** is the only admitted unit of Coach work. The Application-facing
`Invocations.tryInvoke(...)` interface owns eligibility, context preparation,
Library-wide concurrency, admission accounting, durable launch authority, provider
Attempts, cancellation, and terminal failure creation. Chat, Proposal, and future
maintenance use cases submit stable entity IDs and an `InvocationIntent`; they do
not duplicate these checks or construct provider DTOs.

```text
InvocationIntent
  answerPendingUserTurn
  reconsiderProfileChange
  compactCoachMemory       # backlog; not constructible in the current release
```

`answerPendingUserTurn` points to one locked Draft and response position.
`reconsiderProfileChange` points to the Chat's one stale Proposal. Memory
compaction is designed as another intent so its future provider call uses the same
admission and execution rules; it is not implemented now.

`tryInvoke` performs these operations in order:

1. Resolve the intent and repeat its current eligibility checks.
2. Ensure no Invocation is active anywhere in the Library.
3. Build and measure the exact current provider context.
4. Check the persisted rolling admission window.
5. Record the admission unit and persist the Invocation before provider launch.
6. Admit the intent and launch its first Provider Attempt.

A rejected eligibility, context, concurrency, or admission check launches nothing.
For a new Send, an eligibility, concurrency, or admission rejection atomically
removes the provisional Pending User Turn, unlocks the unchanged Draft, and shows
an accessible fleeting notice. Invocation Retry retains its existing failure;
Reconsider retains its stale Proposal. Context rejection is the documented
exception: it keeps the Pending User Turn under
`CoachContextCannotFitUserRetryable`. A rare failure after the admission ledger is
committed but before the Invocation is installed may waste one admission unit and
leaves the underlying intent interrupted and user-retryable; it must never launch
unrecorded provider work.

Only one Invocation may process at a time across the active Library. At most one
new Invocation is admitted in a rolling 60-second window. The ledger is stored in
machine-local application state keyed by Library ID, survives relaunch, and is not
portable Library content. Every top-level Invocation consumes one unit, including
Retry, Reconsider, and future Memory compaction. Automatic Provider Attempts inside
an already-admitted Invocation do not.

Admission cooldown is not another Chat state and does not queue work. Send,
Invocation Retry, and Reconsider are disabled until admission reopens. Local
Profile-publication Retry remains available. Pointer hover uses the
forbidden cursor; keyboard and assistive presentation provide the same unavailable
reason without requiring hover. A stale action that loses an admission race creates
no Invocation and retains its underlying Draft or Proposal.

Resolved Invocation and Provider Attempt operational records are deleted. Durable
product state keeps only the resulting messages, current Memory, unresolved
Proposal or Failure Descriptor, and bounded metadata logs.

## Provider Attempts and Retry

A **Provider Attempt** is one external provider launch inside an Invocation. Each
Attempt gets a fresh Attempt ID, provider idempotency token, process, transcript
access capability, and on-demand transcript handles. None is reused by another
Attempt.

One Invocation may make at most four Attempts. Transient provider failures use
5-, 10-, and 15-second delays before the remaining Attempts. Automatic retry keeps
the immutable intent and semantic context frozen, but it creates fresh
Attempt-scoped transport values. Presentation continues to show one slow
**processing** spinner.

A trusted length stop or local response-collector overflow may receive one
immediate repair Attempt when a slot remains. The repair gets this app-authored
instruction:

> The previous Attempt exceeded the response limit. Return a materially shorter
> complete response. Preserve the direct answer, remove repetition and optional
> detail, and never return partial JSON.

The failed bytes are not replayed. A repeated overflow, an overflow with no slot,
or a complete response that fails schema or semantic validation becomes
user-retryable. Complete invalid responses are not recursively sent back to the
model for repair.

User **Retry** creates a new Invocation for the same intent. For a pending user
turn it keeps the Draft ID, Draft version, and response position, but reconstructs
the request from the current Profile, Memory, successful history, and immutable
attachments. Reconsider Retry likewise reloads current authoritative state. This
is different from automatic retry, which stays inside one Invocation.

Stop cancels and reaps the current Attempt after a bounded grace period. A late
result cannot publish after Stop, Retry, Discard, or another Invocation takes over
the response position. Nothing from the stopped Invocation publishes. Its locked
Draft or stale Reconsider Proposal remains in an interrupted UserRetryable state
with the ordinary **Retry** and **Discard** actions. Discard unlocks an answer
Draft; for Reconsider it removes only the failure and restores the stale Proposal's
**Reconsider** and **Discard** actions.

## Chats and Session attachments

A Chat is local and independent of provider-owned conversation history. Its Session
attachments are fixed at creation and name exact `(sessionId, transcriptRevisionId)`
pairs. Provider projection replaces the app-private compound key with one stable,
Chat-scoped `sessionAttachmentId`.

There are two creation paths:

- **New Chat** from the Chat list opens a searchable multi-select sheet and permits
  zero or more Sessions.
- **Analyze with Coach** from a Session opens the same sheet with that Session
  selected and locked. The Speaker may add more Sessions but cannot remove the
  origin while that sheet is open.

The reusable picker supports selecting multiple Sessions in one operation. The
same selection shell is reused by batch **Move to Trash**, although that is a
separate Application command and never changes a Chat's attachments. An existing
Chat cannot add or remove Sessions; a different selection creates another Chat.

Before creating another Chat from a Session, Audora looks up active Chats that
already attach it. A reusable confirmation dialog shows the total and at most three
clickable Chat names with last-updated times, newest first. Selecting one navigates
there. **Create new** proceeds without replacing anything.

Analyze creates an ordinary Chat and seeds an ordinary Draft:

```text
one Session:       Analyze this Session and give me practical speaking feedback.
multiple Sessions: Analyze these Sessions and give me practical speaking feedback.
```

The grounding and transcript-fetch rules belong to the coach instruction, not the
user-facing Draft. The seeded Draft follows the exact Send, Retry, Discard, and
publication path used by a typed user message. While processing or failed it is
visible read-only in the composer, not Chat history. On success it becomes the
ordinary user message published with the coach message.

Chat storage retains minimal app-only creation provenance:

```text
ChatCreation
  creationKind: newChat | sessionAnalysis
  originAttachmentId?  # required for sessionAnalysis
```

For Session Analysis, `originAttachmentId` names the locked attachment from which
Analyze opened. Neither field enters provider context. Storage has no Analyze-only
trigger, template ID, rendered-text hash, or separate recovery path.

The prospective Analyze Chat is prepared before installation. If concurrency or
admission closes at the final check, Audora retains the creation sheet, installs no
Chat, and shows an accessible fleeting notification. If exact context preparation
instead determines that the requested Chat cannot fit, Audora installs the Chat
with its seeded Draft locked by `CoachContextCannotFitUserRetryable`; no Invocation
is created. This preserves the ordinary Retry/Discard flow without inventing a
separate Analysis state.

A Chat created from the Chat list starts with an empty Draft and does not invoke the
coach. A Chat may have no Session attachments; its current Development Profile and
conversation are still valid coaching context.

## Draft and Pending User Turn

Each Chat owns one autosaved Draft:

```text
ChatDraft
  draftId
  version
  text
  updatedAt
```

The composer updates the in-memory Draft on every edit. Audora persists a dirty
Draft at least every two seconds while running and flushes it before Send,
navigation, and orderly termination. Relaunch restores it. Per-Chat serialization
prevents an older autosave from overwriting a newer version.

Send synchronously flushes and locks the exact Draft version in one Pending User
Turn before the final Invocation preflight. The Draft remains the sole copy of the
unanswered text:

```text
PendingUserTurn
  pendingUserTurnId
  draftId
  draftVersion
  responsePositionId
  state: processing(invocationId) | userRetryable(failure)
```

While processing or user-retryable, the composer displays that exact text with its
input and Send disabled. It is not a history message. Retry reuses it. Discard
removes the Failure Descriptor and Pending User Turn, then unlocks the same
populated Draft for editing. It never loses or silently submits the Speaker's text.
If the first Invocation preflight instead loses an eligibility, concurrency, or
admission race, the provisional Pending User Turn is removed and the Draft is
immediately unlocked; the fleeting notice is not a Failure Descriptor.

Only a valid complete Coach Response publishes a turn. One atomic Chat commit
appends the user and coach messages, applies optional `newMemory`, installs at most
one unresolved Proposal or evidence-publication operation, and removes the Pending
User Turn and consumed Draft. A one-sided user message or coach message is
forbidden.

Provider output and streaming events are transient until that commit. Audora does
not durably stage a complete response for crash resumption. On relaunch every
unfinished Invocation becomes **interrupted**, its exact Draft stays locked, and
Retry starts a new Invocation. If publication committed before the crash, both
messages are present; otherwise neither is.

Invocation and Profile-publication failures are operational UI state, never
Chat-history messages. Resolving Retry/Discard removes their failure records.
Accepted, discarded, or withdrawn Proposals are likewise not retained as Chat
audit events.

## Context preparation and capacity

Every Attempt receives the current structured Profile, current Coach Memory, the
complete successful Chat-history prose projection, the current trigger, and every
immutable Session attachment projection. The pending Draft appears once as the current trigger and
never inside history. Profile and Memory also appear once; no provider-side memory
is assumed.

User turns project their stored text exactly. Coach turns concatenate persisted
block Markdown in order with exactly two newline characters between blocks.
Evidence controls and pointers remain in the local structured message rather than
being synthesized into history text. The deterministic projection preserves every
successful turn and makes token calculation reproducible.

The qualified adapter supplies:

```text
CoachContextBudget
  contextWindowTokens
  responseReservedTokens
  safetyMarginTokens
```

The response reserve protects the current structured response. The safety margin
covers hidden framing and estimator uncertainty. A conservative estimator measures
the exact serialized request, JSON escaping, known provider framing, inline
transcripts, and the maximum complete on-demand transcript exchange. Model-facing
contracts contain no estimator ID, token estimate, or read budget.

Every Attempt configures the provider's output-token ceiling no higher than
`responseReservedTokens`, and the pinned coach instruction states that the complete
structured response must fit that allowance. The response collector's independent
byte ceiling and whole-response validation remain fail-closed defenses.

```text
inputCeiling = contextWindowTokens
             - responseReservedTokens
             - safetyMarginTokens
```

Application rejects a descriptor unless reserve plus margin is strictly below the
context window. Provider qualification also proves that a maximum valid,
canonically serialized Coach Memory fits inside both the minimum Request under
`inputCeiling` and the minimum Response under `responseReservedTokens` and the
collector byte ceiling. `coachMemoryMaxTokens` therefore cannot consume either
envelope's required framing.

Before Chat creation, each Session row shows duration, approximate token cost, and
expected inline/on-demand delivery. The picker shows approximate `X / max` usage,
including the current Profile. In Chat, a compact `~X / max` quote updates as the
Draft, Profile, Memory, history, or provider configuration changes. It explains the
major categories but never exposes a raw payload editor.

The picker catalog, exact attachment re-resolution, and creation quote use one
provider-configuration authority. Their in-memory stamps include both authority
identity and generation; equal generation numbers from different authorities are
not interchangeable. If the configuration changes, Application reprojects the
catalog, preserves every still-available immutable Session/Revision selection, and
requires a fresh confirmation. A known qualified projection may remain usable
while its provider is temporarily unavailable, but absence of a usable
configuration cannot be reported as the provider-unavailable creation exception.

The creation quote uses an explicit app-only creation-context frame. A new Chat has
no provider trigger yet, so Application neither fabricates user prose nor treats an
empty placeholder as successful history. Only a later nonempty ordinary Draft is a
launch-eligible `userMessage` trigger.

The visible estimate is advisory. `tryInvoke` repeats the exact race-safe
calculation. It never trims a message, Profile, Memory, Session, or history. If the
context does not fit, no provider work launches and the Pending User Turn shows:

```text
Chat size exceeded. Please create a new one.
[Retry] [Discard] [Create New Chat]
```

**Create New Chat** opens the ordinary creation sheet with the current Chat's
Sessions selected but removable. Retry recalculates the same locked Draft. In the
current release it usually reproduces the same result unless Profile or provider
configuration changed. Discard unlocks the same Draft. The Chat remains writable;
a shorter replacement message may fit. Automatic history compaction and infinite
continuation are backlog work.

The app-authored user-message maximum is checked before Invocation. A message over
that independent limit remains editable and shows **Message is too long. Shorten it
to send.**

Version one sets that Send limit to **16,384 UTF-8 bytes** while the recoverable
Draft remains persistable up to 32,768 UTF-8 bytes. The quote always reports the
message limit. Portable context snapshots are bounded to 4,096 history turns,
128 attachments, 64 MiB per canonical value, and 64 MiB in aggregate; checked
addition rejects overflow or excess before the planner can allocate an unbounded
request. The complete framed-message estimate—not the sum of category estimates—
is authoritative. Exact fit is accepted and one token over is rejected.
An on-demand transcript handle is one typed 36-byte lowercase canonical UUID. The
same authority must appear in its attachment descriptor and reserved read request;
the complete read-request and response wrappers count toward the aggregate bound.

Every resolved snapshot is bound to its Library, Chat, Draft ID and version, and,
for Send, Pending User Turn and response-position IDs. Separate monotonic
authorities cover the Profile/Memory/history/attachment projection and the complete
provider configuration. Application measures exact canonical bytes, then
revalidates both authorities before returning a quote, local capacity failure, or
prepared exchange. Identical prose cannot make a stale identity or generation
current.

## Transcript delivery

Each Session attachment is projected as either:

```text
SessionAttachmentInline
  sessionAttachmentId, displayLabel, transcript

SessionAttachmentOnDemand
  sessionAttachmentId, displayLabel, sessionTranscriptHandle
```

The inline threshold and reserve policy are adapter-internal qualified delivery
policy, not fields in the provider descriptor or request. Small immutable
transcripts are sent with every Attempt. Larger ones are available through one
Attempt-scoped read capability. The current contract exposes only complete selected
transcripts; it has no excerpt, line-range, or mutable attachment selection.

For Codex, the adapter may expose the read through a loopback endpoint bound to
`127.0.0.1` on an ephemeral port, or through stdio if qualification chooses it. A
fresh hidden one-time capability authenticates the Attempt's frozen attachment set
and is supplied outside model content. Prompt-visible transcript handles are opaque
routes, not bearer credentials. The endpoint stops when the Attempt ends.

The coach may make one logical batch request for any nonempty subset of on-demand
attachments. Audora validates the handles, performs bounded local transport/storage
retry, rechecks the complete response budget, and returns all requested transcripts
or no transcript bytes. Transport redelivery of the same logical call may replay
its cached response; a second semantic call is rejected.

The pinned coach instruction says:

- if the answer depends on Session content and Memory contains no adequate analysis,
  read every relevant on-demand Session;
- if it has no transcript knowledge yet for a broad analysis request, read all
  on-demand attachments and preserve useful conclusions in `newMemory`;
- for the first response in a Session Analysis Chat, attempt any useful
  evidence-backed Profile effects in the same response;
- never guess which Session a remembered conclusion belongs to; if uncertain, ask
  the Speaker to send the message again; and
- do not retry, split, reorder, or shrink a failed tool request.

The Analysis instruction does not require a visible Proposal. The coach may find
nothing worth remembering, and valid normalization or evidence deduplication may
remove every returned effect.

A non-complete read does not permit an incomplete coach answer. Audora terminates
the Attempt and creates a user-retryable application failure. For unavailable
Sessions, the error says that some Sessions could not be read and lists at most
three clickable Session names. Additional failures are summarized by count. Retry
creates a fresh Invocation and fresh access capability; Discard unlocks the Draft
or restores the stale Proposal action.

`contextCannotFit` is also terminal. Because admission reserves the complete
on-demand exchange, it indicates a changed-state race or provider-qualification
defect and is logged before becoming the appropriate context user-retryable error.
The model is never asked to invent an excuse or answer around missing required
evidence.

The transcript projection contains deterministic line text, canonical Words, and
app-created Audio Events. A Word may omit audio timing when ASR has no reliable
span; its enclosing line range remains a seeking fallback. Word IDs and Audio Event
IDs exist so a Coach Response can point back to canonical evidence. Textual Events
such as filler or repetition candidates remain local: the coach evaluates transcript
words rather than trusting an algorithmic interpretation.

Audio Event categories describe facts unavailable from Words:

| Category | Meaning |
| --- | --- |
| `nonSpeech` | A non-lexical sound such as a laugh or cough. |
| `silentPause` | Available audio with an observed speech-inactive interval; it does not infer intent. |
| `untranscribedVoicedInterval` | Detected voice without transcript coverage, preventing it from being mistaken for silence. |
| `muted` | Deliberately unavailable microphone evidence; never positive Profile support. |
| `captureGap` | Technically unavailable audio; never positive Profile support. |

## Coach Memory

Coach Memory is provider-authored, Chat-scoped working context. It preserves useful
conclusions without making the provider reread every transcript for every follow-up:

```text
CoachMemory
  generalNotes: string
  sessionSummaries[]
    sessionAttachmentId
    notes
```

Memory is neither speech evidence nor Development Profile authority. A Session
summary is scoped by the Chat attachment ID, so conclusions cannot silently migrate
between Sessions. `generalNotes` holds cross-session and conversational context.

Every request includes the current Memory. `CoachResponse.newMemory` is optional:
omission retains the current value; presence atomically replaces it with the
response. Canonically identical replacement is treated as omission. Audora stores
only the current Memory and removes the superseded value after its atomic switch is
recoverable. Proposal acceptance or Discard never rolls Memory back.

The provider configuration sets a hard Memory token allowance below the model's
context limit. An oversized `newMemory` invalidates the complete Coach Response and
the reason is logged so the allowance can be tuned. Audora does not semantically
rewrite Memory and exposes no **Reset Coach Memory** action.

The current release always includes the complete successful Chat-history prose
projection in addition to Memory. A Memory replacement does not hide or compact
prior messages. When
Memory or cumulative context cannot fit, the ordinary capacity failure applies.
Memory compaction is backlog work.

If persisted Chat data, including Memory, fails structural or integrity validation,
Audora freezes that Chat and instructs the Speaker to create a new one. It does not
silently replace damaged state with empty Memory.

## Structured Coach Response

The coach returns one complete semantically untrusted batch:

```text
CoachResponse
  messageBlocks?: CoachResponseBlock[]
  newMemory?: CoachMemory
  proposeProfileEdits?: CoachProfileEditProposal[]
  appendProfileEvidence?: CoachProfileEvidenceAppend[]
```

An answer to a pending user turn must contain at least one message block.
Reconsider may omit message blocks when nothing needs explanation. Arrays, when
present, are nonempty. The generated JSON Schema bounds shape; the output-token and
collector limits bound total size. Blocks are a batch layout, not a streaming
protocol.

Application validates the entire response before publishing any part. Invalid
schema, unsafe Markdown, unknown targets, invalid evidence pointers, inconsistent
Profile edits, or oversized Memory reject the complete response. Valid exact
duplicates and no-ops may normalize away. The app never accepts a valid message
while discarding an invalid Profile effect from the same response.

`CoachResponseBlockMarkdown` is ordinary text, advice, exercises, synthesis, or
transitions that do not need app-resolvable evidence controls. An Evidence
Observation contains interpretation plus one or more pointers:

```text
Here is the main pattern I noticed:

│ You rush the transition after stating a conclusion, so the next point
│ arrives before the listener can absorb the first one.
│ Evidence  [Planning reflection · 03:14]  [Demo practice · 06:42]

Try a deliberate one-beat pause before each new point.
```

The inset is always rendered inline in the Chat; it does not appear only on hover.
Each evidence control is visibly interactive at rest. Hover adds a subtle
background highlight and underlines the label. Keyboard focus adds the platform
focus ring. Click, Enter, or Space opens the exact Session, highlights the evidence,
and seeks available audio. An unavailable target keeps its saved label and becomes
a focusable unavailable control whose activation explains the reason.

## Evidence pointers and references

The provider returns compact pointers:

```text
CoachEvidencePointer
  sessionAttachmentId
  target
    wordRange { startWordId, endWordId }
    audioEvent { audioEventId }
```

The app validates every pointer against canonical local data:

- `sessionAttachmentId` maps to a Session attached to the Chat;
- that attachment names the immutable Transcript Revision used by the Chat;
- both Word IDs or the Audio Event ID exist in that canonical transcript; and
- a Word range is ordered and belongs to that transcript.

The coach may return a pointer from the structured transcript context or preserve
canonical IDs in Memory for later use. Reused, new, and changed pointers follow the
same checks regardless of how the coach learned them. The app does not decide
whether a structurally valid pointer semantically proves the coach's wording; the
Speaker reviews semantic Profile changes.

Application derives text, time, Session identity, and display labels from the
canonical revision. Model-returned quotes or timestamps are never authoritative.
The resulting Evidence Reference is nested in the coach message or Profile
Statement; it has no independent lifecycle. Missing, in-Trash, corrupt, or
unsupported source data changes navigation and presentation only. It does not
silently change an accepted Profile Statement.

## Development Profile context

Each Invocation includes the complete current structured Development Profile,
projected from the revision selected by `head.json`. No Markdown Profile projection
exists, and the coach never generates a whole replacement document.

```text
ProfileStatement
  statementId
  statementKind
  wording
  supportingSessionCount
  evidence?: CoachEvidencePointer[]
```

`statementId` lets the coach target an exact current Statement. The app assigns IDs
for additions and replacements; the coach never invents them. The support count
describes all accepted historical supporting Sessions. The provider-facing
`evidence` array contains only eligible References whose exact
`(sessionId, transcriptRevisionId)` pair is attached to this Chat. Evidence from a
different Transcript Revision of the same Session is not remapped; omission does
not reduce the historical count.

Statement kinds are `goal`, `coachingPreference`, `selfAssessment`,
`speakingObservation`, and `growthDirection`. Goals, preferences, and
Self-Assessments may originate in natural-language conversation without transcript
evidence. Session observations and growth directions require evidence. A recurring
pattern needs evidence from at least two distinct Sessions when first accepted;
multiple anchors from one Session still count once. This is an admission rule, not
a condition continuously re-evaluated after source data becomes unavailable.

The Profile revision is authoritative. Conflicting Memory is only working context
and must not override it. If the current Profile cannot be verified, Library-level
coaching is blocked by the Profile recovery banner. Recovery creates a new revision
from the highest-generation hash-verified healthy revision whose generation is
unique across all bundles. Every revision in a generation collision is skipped.
Recovery uses the selected revision as parent, assigns fresh monotonic generations
above every known value, and switches `head.json`; broken and colliding bundles
remain. If no revision is eligible, `head.json` selects the null-Profile state and
the coach receives `ProfileContext { statements: [] }`.

## Profile effects

The coach may return semantic edits and Evidence Appends:

```text
CoachProfileEditProposal
  edit: add | replace | retire
  evidence?: CoachEvidencePointer[]

CoachProfileEvidenceAppend
  targetStatementId
  evidence: CoachEvidencePointer[]
```

Add creates a new immutable Statement after approval. Replace atomically retires
one exact target and creates its successor; this remains one operation because a
split retire/add could partially apply or lose the intended relationship. Retire
removes an exact target from current coaching context. Replace and Retire use a
current Statement ID; Add and Replace receive a new app-assigned ID only after
validation.

The provider returns all Profile effects in the same response as its message and
optional Memory. Application validates that batch atomically, then classifies the
valid effective effects:

- If at least one semantic edit survives, all surviving semantic edits and Evidence
  Appends form one reviewed Proposal.
- If only Evidence Appends survive, they are eligible for silent local publication.
- If no Profile effect survives, no Proposal or Profile write is created.

A Chat owns at most one unresolved Proposal or Profile-publication failure. While
one exists, the composer is disabled. Resolved Proposals are deleted rather than
kept as Chat audit history; adjacent Profile revisions can derive the accepted
Statement diff later.

### Reviewed Proposal

A normal Proposal card shows the full effective changes, Evidence controls, and:

```text
[Accept] [Discard]

Want to change this suggestion? Discard it, continue chatting with the coach,
then ask the coach to remember the result.
```

There is no **Discuss** action. Accept runs one Profile transaction. Discard deletes
the Proposal without changing Profile or Memory. If Accept and Discard race, the
first compare-and-swap wins and no automatic action competes with them.

A local publication failure keeps the exact Proposal and offers **Retry** and
**Discard**. Retry repeats only the local transaction. If the Profile changed in a
way that invalidates its semantic base, Retry changes the card to **Reconsider**
rather than applying stale semantics.

### Evidence-only publication

Evidence Append uniqueness is `(statementId, sessionId)`. Provider order determines
the first occurrence kept for each pair. Existing support and later duplicates are
silent no-ops. A wholly evidence-only update to an active Statement is applied
without an approval card, Chat message, toast, or Profile-update divider.

If its local write fails, the Chat shows one user-retryable Profile publication
failure with app-generated wording for the exact update, such as:

```text
Add evidence from “Planning reflection” to “Pause briefly between points.”
[Retry] [Discard]
```

Retry reruns the idempotent local union. Discard removes the operation without
rolling back the already-published coach message or Memory. The failure is not Chat
history.

Concurrent evidence-only Profile revisions do not stale reviewed Proposals and do
not require Reconsider. The commit silently deduplicates current evidence. If the
target Statement was retired or replaced before an Evidence Append commits, the
operation becomes a stale Proposal with **Reconsider** instead of failing or
silently choosing another Statement.

## Staleness and Reconsider

Every Profile revision increments `generation`. Only add, replace, and retire
increment `statementGeneration`; evidence-only revisions preserve it. A Proposal
uses `statementGeneration` for semantic staleness, so evidence-only transactions do
not harass other Chats with needless reconsideration.

When a semantic Profile update makes a Proposal stale, its card replaces Accept
with **Reconsider** and keeps **Discard**. Reconsider is enabled only while the Chat
is otherwise idle and admission is open. The user cannot send a message while the
coach is processing, and cannot invoke Reconsider during another Invocation.

The trigger gives the coach the latest Profile and the earlier proposal's complete
semantic and evidence basis:

```text
ConversationTriggerReconsiderProfileChange
  previousEdits?: CoachProfileEditProposal[]
  inactiveEditTargets?: ProfileStatement[]
  inactiveTargetsEvidence?: CoachProfileEvidenceAppend[]
```

`previousEdits` contains the full earlier edit wrappers, including their evidence.
`inactiveEditTargets` contains the complete old Statements, including IDs, for
targets no longer active. `inactiveTargetsEvidence` contains only standalone
Evidence Appends whose target disappeared; it is normally absent. The app derives
these fields and never asks the coach to reconstruct them from display prose.
Semantic validation requires at least one of the three collections, rejects
duplicate inactive target IDs, and requires every inactive referenced ID to resolve
exactly once in `inactiveEditTargets`.

Evidence Appends in a stale mixed Proposal whose targets remain active stay pending
inside that one reviewed transaction. They are not silently absorbed while
Reconsider is running. The Chat can therefore never expose two pending Proposals
for one response.

Reconsider is a full Invocation. It may publish a coach message, optional
`newMemory`, and one replacement Proposal. Every resulting Profile effect,
including an evidence-only result, still requires user review. The coach may reuse
evidence pointers supplied in the Reconsider trigger; all returned pointers undergo
the ordinary canonical checks.

If Reconsider concludes that the current Profile already covers the suggestion,
returns no Profile effect, and no active-target Evidence Append remains pending,
the old Proposal disappears. Any returned message and `newMemory` publish normally,
no empty coach message is invented, and the composer becomes available. Audora
shows an accessible ten-second toast, **Suggestion is no longer relevant.** The
toast is neither persisted nor added to history. A retained active-target append or
new returned effect instead forms the one replacement Proposal and suppresses the
toast.

## Profile transactions and timeline dividers

One Library-scoped Profile commit coordinator serializes all writers and
compare-and-swaps the expected `head.json` state. Semantic acceptance writes
nothing when its `statementGeneration` is stale. Evidence-only set union may rebase
while its target remains active. Every successful transaction writes a new
immutable `revision.json`, its detached `revision.sha256`, and then atomically
switches `head.json`.

Profile publication and Chat publication are separate aggregates. A Proposal
acceptance records enough temporary intent to reconcile a crash around the Profile
head switch; this is Profile transaction recovery, not recovery of external output.
Reconciliation recognizes an already-committed intended revision and never writes
it twice. The temporary intent is removed after the Chat reflects success.

Statement updates create a neutral **Profile was updated** divider in every
affected Chat. Evidence-only revisions do not. The divider uses monotonic
`statementGeneration`, never wall-clock comparison. A Chat records the generation
observed at creation; each published coach turn records the Profile revision and
generation it used; a pending Invocation records its prepared generation.
Presentation compares those values with current `head.json`. It stores no divider
record or update timestamp.

The derived divider follows these rules:

- if no message follows the previous divider, a newer generation rewrites that
  tail divider to the actual latest generation;
- if a user turn or Reconsider was already pending when the Profile changed, the
  divider is placed after that action succeeds, is interrupted, is discarded, or
  is replaced by Retry, and before the retried action that uses the new Profile;
- independent ordered dividers may be adjacent, and Presentation renders each with
  compact spacing and its own accessible label.

An explicitly approved Proposal that contains Evidence Appends creates a divider
only because it also contains a semantic edit. Pure evidence publication, including
explicit Retry of a failed evidence-only write, remains silent.

## Failure model

Provider errors normalize into two types:

```text
CoachProviderErrorAutoRetryable
  rate limit, timeout, connection loss, provider 5xx

CoachProviderErrorUserRetryable
  authentication, permission, unavailable model, billing or quota,
  provider-rejected request, exhausted automatic retry, unexpected failure
```

Automatic errors follow the bounded Attempt policy while the Chat remains
**processing**. User-retryable errors persist across relaunch until Retry or
Discard. Audora does not disable Retry based on whether settings appear to have
changed.

Raw CLI stderr, arbitrary provider prose, and private request content are never
shown or logged. A bounded provider-supplied message may be displayed only when the
adapter extracts it from an allowlisted structured field, validates its encoding,
removes control characters, and applies a strict length cap. Otherwise
Infrastructure maps the trusted signal to a closed reason and Presentation uses
short app-authored text. Unknown conditions use **The coach provider could not
complete the request.** Every retry requirement records a metadata-only reason for
diagnosis, including model schema mistakes, Memory excess, read failures,
interruption, and admission rejection.

The metadata log contains IDs, timestamps, reason codes, Attempt counts, durations,
token estimates, and sizes—not Draft text, messages, transcripts, Memory, Profile
wording, provider output, paths, or credentials. Rotation caps it at 100 MiB.

Common Invocation-failure cards are:

```text
Coach provider error
The coach could not complete the request.
[Retry] [Discard]

Coach response couldn't be used
The coach returned an incomplete or invalid response.
[Retry] [Discard]

Some Sessions couldn't be read
[Session A] [Session B] [Session C] and 2 more
[Retry] [Discard]

Coach response was interrupted
[Retry] [Discard]
```

The Failure Descriptor lives beside its underlying intent, never in Chat history.
For an answer intent, Retry keeps the Pending User Turn and exact Draft locked;
Discard removes that pending turn and unlocks the populated Draft. For Reconsider,
the stale Proposal and its window remain; Retry invokes Reconsider again, while
Discard of the failure returns to the ordinary Reconsider/Discard Proposal actions.
Profile publication failures use the separate Proposal lifecycle because the user
and coach messages already committed.

If any persisted Chat data cannot be migrated or verified, that Chat is frozen and
instructs the Speaker to create a new one. Provider contract changes are rebuilt
from the same immutable Draft/history data at Retry time; coach-visible DTOs are not
persisted as authoritative Chat state.

## Presentation state

Chat rows project two independent indicators:

```text
ChatActivityIndicator
  idle | processing | interrupted | newMessage

ProfileUpdateIndicator
  none | pendingApproval | publicationFailure
```

`processing` covers provider execution, automatic backoff, response validation,
and atomic Invocation-result publication. It uses one slow spinner. `interrupted`
covers a visible Invocation UserRetryable failure. `newMessage` marks an unread
completed response. Proposal approval and Profile publication failure are projected
separately so they cannot be confused with coach execution.

When processing, the composer and Reconsider are disabled. When a turn-level
UserRetryable error is visible, the exact Draft remains read-only in the composer;
Retry is subject to admission. Discard remains available unless another action has
already won the compare-and-swap. A Reconsider failure remains on the stale
Proposal; discarding that failure restores its **Reconsider** and **Discard**
actions. Pending,
stale, committing, and commit-failed Profile states keep the composer disabled
until their available actions resolve them.

Errors, Proposal withdrawals, derived Profile dividers, and future Memory dividers
are app-owned presentation events, not coach messages. Multiple dividers in a row
are valid and must remain legible and accessible.

## Limits and execution

- One Invocation processes across the active Library.
- One top-level Invocation is admitted per rolling 60 seconds. Automatic Attempts
  use 5/10/15-second backoff and consume no additional admission unit.
- The current release exposes one main Library window. Another open request focuses
  it; sheets and dialogs are not Library windows.
- Inputs, outputs, transcript reads, duration, and process lifetime are bounded.
- Model and reasoning effort come from an application allowlist; UI input never
  becomes arbitrary CLI flags.
- Cancellation targets the current Attempt and terminates and reaps its process.
- Transcript, Profile, Memory, history, and tool output are untrusted model input;
  pinned instructions remain authoritative.

A future local coach requires an explicit qualified provider adapter. Different
transcript delivery may extend the provider contract then; the current code carries
no unused local-provider branch.

`--ephemeral` prevents Codex from persisting a local rollout file. It is not a claim
about OpenAI-side retention or training. Remote handling follows the signed-in
account's applicable terms and data controls.
