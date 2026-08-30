# Backlog

These are possible directions, not current-scope commitments. Promoting an item into
scope requires updating the central [`../README.md`](../README.md), its affected
concept documents, and acceptance criteria in the same commit.

## Input and transcription

### Dual-track microphone and system audio

Capture the Speaker's microphone and a separately retained, aligned system or
application-audio source with its own mute and availability intervals. Extend the
existing source collection rather than changing the worker envelope. When both
sources contain evidence, transcribe sequentially through one loaded model and
merge source-tagged words on the common timeline.

The microphone Speaker remains the sole coaching subject. System/application audio
is separately disclosed conversational context; Audora does not score the other
speaker, infer identity, or add observations about them to the Development Profile.

Prerequisites include ProcessTap reliability, source-specific storage, alignment
fixtures, overlap display, progress weighted by eligible source duration, and clear
privacy controls. Silence skipping must never discard quiet speech.

### Alternative transcription engines

Add providers only after the Crisper contract and corpus fixtures are stable.
Candidates may include native Core ML/MLX engines, newer verbatim models, or a fast
content-ASR plus specialized filler detector. Switching engines creates a new
transcript revision.

### Native or persistent worker

Evaluate Core ML/MLX conversion, a Rust core, XPC, or a persistent worker only when
measured model-load latency, packaging, multiple clients, or OS-level network
isolation justifies the added lifecycle and signing complexity. Unix-domain sockets
are not needed for the single-client child-process design.

A future App Sandbox/XPC packaging profile is a separate backlog item below.
“Persistent worker” here means retaining a loaded model or service across jobs and
introducing shared lifecycle/state.

### Live transcription

Optional provisional text may be reconsidered after the finished-audio pipeline is
reliable. It must never replace or constrain the canonical post-recording revision.

## Library and organization

### Merge libraries

Merge two complete libraries through staging. Identical ID and content hashes can
deduplicate; conflicting IDs require fresh suffixes and an import-wide reference
rewrite. No partial implementation should overwrite entities in place.

### Live backup snapshot

Create a consistent copy while the app is open by pausing commits, copying to a
staging directory, validating it, and atomically publishing the snapshot. The
current scope documents copying a closed library.

### Revision retention and cleanup

Add a future per-Library retention policy for superseded immutable Profile and
Transcript Revisions after an age threshold, provisionally 14 days from
supersession. The current scope retains all published revisions. Age makes a revision
eligible; it is never sufficient by itself. Cleanup must protect the current
Profile Revision, every Chat-attached Transcript Revision, explicit pins, pending
proposals and jobs, and revisions still referenced by retained Chats, coach
messages, annotations, Evidence References, or exports. It removes whole
revisions rather than editing immutable content, fails closed on unknown/corrupt
state, and previews impact. Before promotion from backlog, decide whether eligible
revisions ever leave recoverable retention, the default versus **Never**, bounded
tombstone/hash retention, and separate policies for tiny Profile history versus
larger Transcript history.

### Trash cleanup

Design cleanup for Sessions and Chats that the Speaker has moved to persistent
Library Trash. The current scope provides only Move to Trash and Restore and retains every
trashed item indefinitely. Before promotion, decide whether cleanup is manual,
automatic after a retention period, or both; choose defaults and per-Library
controls; define interrupted-cleanup recovery; and show an impact preview covering
owned artifacts, Chat-owned proposals, external references, and the unavailable
states cleanup would create. No cleanup policy or retention duration is implied by
the current scope.

### Projects, folders, tags, and search

Add organizational entities and a rebuildable SQLite/FTS index when real library
size makes in-memory metadata scanning inadequate. Authoritative content remains
in portable manifests and sidecars.

### Automatic longitudinal synthesis

Synthesize recurring evidence patterns across selected comparable time windows and
propose profile changes automatically. Inputs must be explicit, synthesis outputs
immutable and revisioned, and external egress separately disclosed. The current scope has a visible, revisioned
Development Profile but does not silently infer or mutate longitudinal trends.
Recurring synthesis remains limited to evidence-linked speaking behavior and may
not infer personality, character, motives, identity, or psychological traits.

### Encrypted or synchronized backup

Consider encrypted archives or user-selected cloud folders without moving
credentials into the portable library. Conflict handling and incomplete remote
writes require a separate design.

## Analysis and coaching

### Infinite Chats through Coach Memory compaction

Allow a long Chat to replace its current structured Coach Memory and summarize an
eligible successful-history prefix into a materially smaller Memory value. Full Chat
history remains authoritative and locally readable; compaction only advances the
provider-context boundary.

The trigger is deterministic and app-owned. It may fire when current Memory crosses
a soft threshold or when Memory, eligible history, current Draft, Profile, Session
context, and response reserve approach a compaction threshold. The threshold must
leave enough headroom to run compaction itself. A Chat already beyond that point
uses the ordinary context-cannot-fit failure rather than launching an impossible
Invocation.

Once promoted, Retry from `CoachContextCannotFitUserRetryable` first tries
`compactCoachMemory` for the same underlying user-turn or Reconsider intent. It
does not keep launching the unchanged answer request.

Compaction is `InvocationIntent.compactCoachMemory`, a separate Invocation run
before the normal answer or Reconsider rather than an Attempt inside either one.
For an answer, the Pending User Turn, locked Draft, and response position exist
first. For Reconsider, the stale Proposal remains the underlying intent and its card
stays visible. Compaction receives current Memory and one contiguous Chat-history
prefix, then returns only a complete replacement `CoachMemory` within its hard
allowance. It cannot publish a coach message, change the Development Profile,
create Evidence References, or read Session transcripts.

The locked Draft may be supplied only as a relevance hint. Compaction may use it to
choose which facts already present in Memory or eligible history deserve scarce
space, but it must not treat the unanswered Draft as an established fact, decision,
or remembered user preference. The normal answer still receives that Draft once as
its separate trigger.

Compaction consumes one ordinary Library-wide admission unit and returns no answer
for the response position. It succeeds only when the replacement Memory plus exact
history after its proposed boundary, original trigger, and all fixed/reserved
context fit the captured normal-turn budget. Success atomically switches the current Memory,
advances that boundary, appends an app-owned **Coach Memory compacted** divider
excluded from provider history, and automatically retries the same answer or
Reconsider intent. That work is a new Invocation and therefore needs another admission unit.
If admission is still closed, Audora invokes no provider and shows the ordinary
user-retryable limit message asking the Speaker to try again shortly. It does not
introduce a waiting state. A context race still ends in the ordinary capacity
failure. Multiple compaction dividers may occur consecutively with no message between;
Presentation must keep every event in order, render the run with compact spacing,
and expose every individual label to assistive technology rather than merging or
dropping events.

If compaction fails or is interrupted, Memory and its boundary do not change and
the underlying answer or Reconsider exposes ordinary **Retry** / **Discard**
actions. An answer keeps its Draft locked; Reconsider keeps its stale Proposal and
window unchanged. Retry reruns compaction through a new Invocation for the same
intent. Discard of an answer removes the Pending User Turn and unlocks that
unchanged Draft; it creates no history message or exclusion event. If the following
answer or Reconsider fails, the compacted Memory remains current and that intent
uses ordinary Invocation Retry/Discard behavior. Consecutive successful
compactions may therefore leave adjacent dividers even if the pending turn is later
discarded. The Speaker may then replace the unlocked Draft with an unrelated
message. Audora does not roll back the compacted Memory or its divider: Memory is a
mutable derived projection, so being temporarily optimized for the discarded
trigger is valid and a later successful response may replace it again.

There is no automatic cycle cap that promises compaction will eventually reach the
answer. The Speaker can Stop the active Invocation or close the app; relaunch turns
the interrupted intent into its ordinary user-retryable state.

Promotion requires a dedicated request/response contract, a Memory-publication
source that is not tied to a coach message, crash reconciliation, a smaller output
target than the normal Memory ceiling, and admission accounting for the extra
Invocation. Promotion fixtures must also cover successful
compaction followed by answer interruption, Discard, and an unrelated Draft edit,
proving that neither Memory nor the divider rolls back. Until then, there is no automatic continuation:
an unchanged capacity Retry repeats; Discard returns the same text for editing, and
the normal path for a history-bound Chat is to start a new Chat.

### Higher coaching admission throughput

After provider-error, retry, relaunch, and conflict fixtures are reliable, qualify
a higher Library-wide launch limit. Development starts with one top-level
Invocation per rolling 60 seconds; the persisted
timestamp-ledger shape must support raising the count without a migration. Bounded
internal Provider Attempts are governed separately by the adapter retry policy.

### Development Profile Inspector

Add a read-only UI for inspecting current structured Statements, historical
revisions, Evidence References, and adjacent-revision diffs. Natural-language Chat
remains sufficient for changing the Profile in the current scope; the Inspector is
not a raw JSON editor and does not bypass Proposal approval.

### Accepted Proposal summaries

Persist a compact accepted-Proposal summary only if later usability testing shows
that Profile dividers lack enough context. The prospective UI is a small timeline
pill whose hover or keyboard focus shows the accepted edits; it has no click action.
Current Chat history stores neither accepted Proposals nor turn errors.

### Thought-boundary classification

Use audio and lexical cues to distinguish probable hesitation, rhetorical pause,
completed thought, and response latency. Labels remain probabilistic and preserve
the measured underlying intervals.

### Local coach

Implement the `CoachProvider` port through a verified local model runtime. It must
declare its telemetry/network boundary, context limits, and transcript-delivery
capabilities. A provider without safe scoped reads requires an explicit future
contract extension; the current provider union intentionally carries no unused
local-model branch. Any implementation must pass the same structured evidence,
canonical-pointer validation, budget, retry, and atomic-response fixtures as Codex.

### Multi-speaker and diarization

Support multiple voices only with source-aware or purpose-built diarization/ASR.
Avoid persistent voice embeddings unless a separately reviewed feature requires
cross-session identity and the user explicitly opts in.

## Platforms and distribution

### App Sandbox and XPC privilege separation

Add an App Sandbox distribution profile only after a Release spike proves
read/write security-scoped access to a portable Library, bookmark recovery, and a
bundled/signed helper or XPC design for both transcription and coaching. The design
must separate an offline ASR worker with job-only evidence access from a networked
coach that receives bounded envelope bytes but no Library capability.

Do not assume a sandboxed host can invoke the user's arbitrary installed Python or
Codex executables or reuse external authentication state. Adopting this profile may
require bundled runtimes, a dedicated coaching helper and sign-in flow, new
entitlements, migration of machine-local bootstrap state, and a separate
Release-mode adversarial test suite. The current release deliberately uses task-level Codex
confinement in a non-App-Sandbox personal build instead.

### Browser or other UI adapters

Two routes are compatible with the contracts and fixtures:

- a browser Presentation client talks to a local companion that exposes Audora's
  inbound Application commands/state; or
- a browser-only port reimplements Domain/Application behavior plus browser audio,
  file, storage, and engine adapters and passes the shared scenarios.

A pure browser cannot be described as only another Presentation layer. Do not
bring a browser runtime back into the native version merely to share views.

### Packaging and commercial distribution

Bundle/sign/notarize the Python runtime and model installer, or replace them with a
native engine. Public or commercial distribution requires resolving inherited
source licenses and Crisper model/output licensing before release.
