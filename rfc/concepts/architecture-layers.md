# Architecture layers

This document elaborates on the dependency boundaries summarized in the central
RFC. It defines responsibilities, not a required folder spelling.

## Domain

The Domain layer contains values and deterministic rules:

- Session aggregates, their owned Audio Assets, and muted intervals;
- transcript revisions;
- timed lines and words;
- Textual and Audio Event annotations;
- coach messages, Chats, Chat Creation Kind, immutable Chat Session Attachments,
  Coach Memory, Chat Drafts, Pending User Turns, anchors, Development Profiles,
  Profile Revisions, staged evidence appends, and Chat-owned Profile Change
  Proposals;
- IDs, time ranges, reference states, and schema versions;
- validation and deterministic labeling policies.

Domain code has no UI, process, filesystem, database, audio-framework, model, or
network imports. Time, random IDs, and external state enter as values.

## Application

The Application layer coordinates use cases and owns state transitions:

- create or open a Library;
- record, mute, stop, cancel, and import audio;
- start, monitor, cancel, retry, and recover processing jobs;
- publish validated Transcript Revisions and deterministic Annotations;
- play or seek through abstract playback controls;
- create a Chat with zero or more immutable Session/Transcript Revision pins and
  expose only Chat-scoped attachment IDs to Coach Providers;
- persist `newChat | sessionAnalysis`; lock the source attachment for Session
  Analysis, seed a singular or plural ordinary Draft, and submit it without a
  provider-specific trigger;
- retain the creation sheet and show a fleeting accessible toast when eligibility
  or admission fails before Chat installation; if only the final exact context-fit
  check fails, install the Chat with its seeded Draft locked by the ordinary
  UserRetryable capacity failure;
- persist and restore each Chat Draft; lock one exact version while its Pending
  User Turn is processing or user-retryable, consume it only on success, and unlock
  it unchanged on Discard;
- if a new Send loses the final eligibility, concurrency, or admission race, remove
  its provisional Pending User Turn and unlock the unchanged Draft; retain an
  existing failure or stale Proposal for Invocation Retry or Reconsider;
- quote the Profile, current Memory, successful history, Draft, fixed overhead, and
  immutable attachments while treating the final prepared Request calculation as
  authoritative;
- choose which attached transcripts are inline and which receive on-demand handles
  while keeping token estimates and read admission app-side;
- admit all coach work through one Invocation module, which checks intent
  eligibility, exact context, one active Invocation per Library, and the persisted
  one-top-level-Invocation-per-rolling-minute policy before launch;
- keep Send, Invocation Retry, and Reconsider unavailable while processing or while
  admission is closed; automatic Attempt retry remains the same `processing` state;
- enforce bounded 5/10/15-second automatic Provider Attempt retry, one shorter-
  response repair for truncation/overflow, and relaunch-to-interrupted recovery;
- enforce at most one unresolved Profile Change Proposal per Chat and delete it on
  terminal resolution;
- persist an accepted Proposal's temporary commit intent, then transactionally
  publish and reconcile the Profile Revision without invoking the provider;
- atomically publish the successful user/coach turn, optional complete `newMemory`,
  and exactly one classified Profile effect; only pure staged evidence proceeds to
  the separate recoverable idempotent set-union transaction;
- resolve successful evidence append silently; on local failure retain its exact
  Retry/Discard state while keeping the response and Memory published;
- assign new Profile Statement IDs and local Evidence References rather than
  trusting provider-owned identity;
- validate returned Evidence Pointers against canonical Transcript Revisions
  attached to the Chat without judging semantic support;
- retain only current structured Coach Memory, remove the superseded snapshot after
  atomic cleanup, and never roll Memory back when a Proposal is discarded;
- freeze a Chat whose authoritative persisted data cannot be migrated or validated;
- retain one failed Pending User Turn and locked Draft across provider, validation,
  transcript-read, interruption, and capacity failures; Retry reuses the same turn
  while Discard unlocks its unchanged Draft;
- create `CoachContextCannotFitUserRetryable` without an Invocation or network
  request when exact context cannot fit;
- create, rename, move to Trash, and restore Sessions and Chats; and
- resolve active, in-Trash, and externally missing references without cascading
  changes into accepted Profile semantics or Chat messages.

It defines ports such as:

```swift
protocol AudioCapturePort
protocol AudioImportPort
protocol AudioPlaybackPort
protocol LibraryRepository
protocol TranscriptionEngine
protocol AcousticEvidencePort
protocol CoachProvider
protocol ModelRepository
protocol ExecutionHostPort
protocol IDGenerator
protocol Clock
```

Application policies must not be duplicated in UI adapters. For example,
`CreateAnalysisChat` locks the source Session, validates additional attachments,
seeds the ordinary Draft, and submits it. Presentation projects state but does not
own retry timing, admission, provider-error classification, or Trash retention.

Coaching turn coordination is one deep Application module rather than Draft locks,
admission, Retry/Discard, and token math spread across views, repositories, and the
provider adapter. Its small conceptual interface is:

```swift
quoteNewChat(attachmentPins, creationKind) -> ChatCreationQuote | CoachContextPreparationError
quoteChat(chatID) -> ContextQuote | CoachContextPreparationError
Invocations.tryInvoke(intent) -> InvocationAdmission
discardInvocationFailure(failureID) -> DiscardResult
```

It hides Profile, Coach Memory, Chat, Session, and Transcript resolution;
selection of inline versus on-demand transcript delivery; deterministic request
projection and serialization; one hidden Attempt-scoped read capability; fresh
attachment handles; atomic subset reads; provider/model token estimation; Draft
locking; Pending User Turn persistence; Invocation admission; Attempt retry;
success promotion; Retry/Discard; and the race-safe final budget recheck. Stable
Domain IDs—not prepared DTOs or disabled-state booleans—cross its interface. Only
the true external `CoachProvider` is a public outbound port; tokenizer and repository
details remain substitutable implementation dependencies inside the module.
Each provider-facing attachment carries a Chat-scoped ID and either complete inline
transcript content or a temporary transcript handle. Application chooses the form
under the provider's qualified thresholds and reserves the conservative complete
exchange for all on-demand attachments, so an atomic scoped read of any subset fits
unless evidence becomes unavailable. MCP,
native function calling, and another IPC transport are Infrastructure adapter
details, so Presentation and Chat use cases never branch on provider name or
transport support.

One Library-scoped `ProfileCommitCoordinator` is the single mutation seam for
accepted Proposals, automatic Evidence Appends, recovery, Retry, and relaunch
reconciliation. It serializes writers and compare-and-swaps `head.json` generation,
Statement generation, revision ID, and hash; repositories expose no unconditional
head replacement.

Full Chat history remains authoritative storage. The context planner supplies the
current bounded Coach Memory plus every successful message; `newMemory` is an
optional complete replacement, and omission retains the current value. Memory is
working context and does not permit omission of history. A Pending User Turn supplies its locked
Draft separately as the current trigger and joins history only with a successful
coach response. A Chat is finite when its actual current Profile, Memory, complete
eligible history, trigger, response reserve, and attachment plan no longer fit.
History compaction and continuation beyond that limit are backlog work.

Provider configuration is invalid unless response reserve plus safety margin is
strictly below the context window. Qualification proves that the largest valid
structured Memory fits inside both the minimum Request's usable input and the
minimum Response's `responseReservedTokens` and collector byte ceiling. A
configuration that cannot satisfy these invariants is unavailable.

Presentation uses an inbound API rather than importing repositories or adapters:

```swift
protocol RecordingFeature {
    func send(_ command: RecordingCommand) async
    var states: AsyncStream<RecordingFeatureState> { get }
}

protocol ReviewFeature {
    func send(_ command: ReviewCommand) async
    var states: AsyncStream<ReviewFeatureState> { get }
}
```

The exact Swift spelling may change, but every feature exposes typed commands and
immutable state snapshots. Application emits effects only through its outbound
ports. Cross-platform scenario fixtures define an initial state, command,
dependency event/outcome trace, expected next state, and expected effects. Durable
job, admission, cancellation, and recovery behavior therefore does not live only in
SwiftUI presentation models.

### Library activation and processing authority

Application treats a successful writable Library open as a new authority event,
not merely as a `LibraryID` selection. `DefaultLibraryFeature` attaches a
strictly increasing, process-local generation to the resulting
`LibraryActivation`. Generations may contain gaps after cancelled or failed opens;
they are ordering tokens for the current process, never a persisted schema
generation or a value reconstructed across launch. Reopening or refreshing the
same Library ID still produces a newer activation.

`SessionProcessingFeature` observes each activation before it performs inventory
and immediately installs a Library-wide processing fence. The fence prevents
Start, Retry, model mutation, and processing-backed navigation until a bounded,
complete inventory for that exact activation has reconciled every durable Job and
left no unresolved worker authority or invalid completed publication. Partial,
corrupt, unavailable, or unknown-newer attempt coordination keeps the fence in
place. Equality includes both Library scope and activation generation: a newer
activation supersedes suspended reconciliation, and an older result cannot clear
the newer fence even when both activations name the same `LibraryID`.

Infrastructure supplies a separate process-local replacement fence. Each active
processing capability retains a Library access lease and captures
`(LibraryID, workspaceGeneration, root device, root inode)`. The workspace
generation advances whenever the active root is installed, replaced, or closed;
filesystem identity detects a root swapped beneath the same path. Inventory
creates one reconciliation capability bound to that exact retained scope, and
subsequent source loads and Job transitions must present its opaque reconciliation
ID. Selected-Session reads, Job mutations, canonical audio capabilities, and
Transcript publication all verify the scope before and after work, while the
synchronous filesystem mutation itself executes under the workspace actor's
current-scope check. Any close, switch, lease loss, or same-ID root replacement
therefore makes the old capability fail closed without mixing roots.

These two generations serve different layers and must not be collapsed:
`LibraryActivation.generation` orders Application reconciliation, while
`workspaceGeneration` plus root identity confines Infrastructure authority. Neither
is serialized into the portable Library.

External providers never return authoritative Domain entities. Infrastructure
first confines and reads transport artifacts, verifies their declared hashes and
size limits, and parses their DTO shape. Transcription returns
`TranscriptionCandidate`; coaching returns one complete `CoachResponse`. These are
not Domain values and remain semantically untrusted. Application and Domain then
perform identity, time/order, integrity, license-policy, and anchor checks before
Application asks the repository to publish a canonical value. Only Application may
publish or change authoritative manifests.

## Infrastructure

Infrastructure implements ports with replaceable adapters:

- AVFoundation microphone capture and playback;
- the portable filesystem repository and machine-local Library locator;
- audio normalization and media inspection;
- the Crisper Python/MPS worker process;
- model installation and cache validation;
- platform-dependent audio decoding, VAD, and acoustic evidence extraction;
- the ChatGPT-authenticated Codex CLI provider;
- the attempt-scoped Audora transcript MCP broker used by the Codex adapter for
  large attached transcripts;
- constrained process execution for transcription and coaching;
- derived search indexes when introduced.

Infrastructure converts external errors into bounded application error codes. It
does not expose provider stderr, filesystem paths, or framework-specific objects to
Domain or Presentation. `LibraryRepository` reports reference states but never
implements a Session Move-to-Trash or Restore cascade into Profile Revisions,
Evidence References, or proposals.

Pure filler, partial-word, repetition, and pause-composition rules are
Domain services, not Infrastructure adapters. They consume Domain transcript
values plus normalized acoustic evidence returned by `AcousticEvidencePort`.

## Presentation

Presentation contains SwiftUI/AppKit views and presentation models. It:

- renders immutable feature state;
- sends user intents to application use cases;
- formats progress, ETA, dates, annotations, and recoverable errors;
- while a Pending User Turn is processing or user-retryable, renders its exact
  locked Draft in the read-only composer with Send disabled; Discard unlocks that
  same populated Draft for editing rather than creating a history message;
- maps attributed transcript ranges to stable word IDs;
- reuses one searchable, keyboard-accessible Session multi-select shell for
  Chat-creation attachment selection and batch Move to Trash while sending the
  results to distinct Application use cases;
- renders persistent Trash contents and sends Restore intent to its Application
  use case; version one exposes no cleanup action;
- owns no storage, process, provider, or audio-engine lifecycle.

A view may optimistically change purely visual state, but durable state becomes
authoritative only after the relevant use case succeeds.

## Composition root

The executable target is the only place that knows all concrete types. It creates
the repository, capture, player, worker, acoustic-evidence, coach, execution-host,
and clock adapters and injects them into application services and presentation
models.

Tests use in-memory repositories, deterministic clocks/IDs, fake workers, and fake
coach providers. No Domain or Application test should need microphone permission,
a model download, Codex login, or a real library directory.

## Platform-neutral contracts

`AudoraContracts` is a resource/fixture package, not the owner of business values.
It contains JSON Schemas, JSONL protocol examples, test vectors, and scenario
fixtures. Boundary adapters may define generated or hand-written DTOs from those
schemas and map them into Domain candidates. Domain remains serialization-free and
does not import worker/storage DTO modules.

Portable library manifests, transcript candidates, worker messages, annotations,
coach envelopes, and feature scenarios use versioned language-neutral fixtures.
Fields use integer milliseconds and relative IDs, not framework dates, URLs, or
object IDs.

A later TypeScript/browser implementation reimplements the Domain/Application
behavior and platform ports and must pass the same fixture suites. Algorithms are
behaviorally portable when specified by fixtures, even if their first
implementation is Swift; there is no claim of zero-effort source reuse.

`AudoraDomain`, `AudoraApplication`, and `AudoraContracts` are SwiftPM-compatible
and build and test on macOS and Linux in version one. SwiftUI, AppKit,
AVFoundation, Library locators, MPS, and macOS worker/provider hosting remain
platform-specific adapters. Windows and WebAssembly source compatibility require
their own future continuous-integration proof.

Code sharing across platforms is optional:

- **First choice:** share schemas, invariants, and fixtures; implement thin native
  domain types per platform.
- **Later option:** extract stable, compute-heavy pure logic into Rust and expose it
  to Swift and WebAssembly.
- **Avoid in v1:** adopting a cross-platform runtime solely to share simple models
  before the product boundaries are stable.

Hardware and process capabilities still require platform adapters. A browser may
use Web Audio, the File System Access API, and a remote or local-companion engine;
it cannot assume macOS process execution or sandbox bookmarks.
