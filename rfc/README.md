# Audora local speech coach

This directory is the canonical product and architecture specification for the transformed Audora macOS application.
The legacy application is a non-authoritative code donor. Version one has no
behavior or data-compatibility obligation and uses a new composition root; only
deliberately selected native techniques are candidates for extraction.

## Documentation rule

Read this file before making product or architecture changes. Every conceptual
change or addition must be reflected here in the same commit as the detailed RFC
or implementation. Put details that would obscure this overview under
[`concepts/`](concepts/), and keep speculative work under
[`backlog/`](backlog/README.md).

Git commits are the history. These RFC files describe only the current direction;
they do not maintain a changelog or retain superseded decisions.

## Product

Audora is a private, local-first macOS application for solo speech reflection and
rehearsal. The Speaker records their own microphone audio or imports audio of
their own speech, waits for local batch transcription, reviews a verbatim
timestamped transcript, and asks an AI coach for feedback when useful. A working
coaching path is required for version one, although invoking it remains an
explicit choice for each session. The product preserves speech evidence such as
fillers, false starts, immediate repetitions, and pauses rather than silently
turning it into polished prose.

The essential loop is:

1. Record mono microphone audio or import a mono/stereo M4A or WAV file.
2. Seal and save the audio before inference starts.
3. Transcribe locally with the qualified engine; the current personal-evaluation
   candidate is CrisperWhisper Small.
4. Validate and atomically publish the completed transcript.
5. Add local, non-destructive speech annotations.
6. Review the transcript alongside synchronized audio.
7. Create a Chat with an immutable set of zero or more Session/Transcript Revision
   attachments. Analyze Session opens the same creation picker with its source
   Session locked, seeds a singular or plural ordinary Draft, and submits it;
   New Chat opens without sending.
8. On Send, Invocation Retry, or Reconsider, ask the Invocation module to admit one
   immutable intent. An admitted Invocation sends the structured Development Profile,
   current structured Coach Memory, successful Chat history, current trigger, and
   attached Session evidence to Codex. Small transcripts may be inline; large ones
   are available through one capability-scoped atomic batch read.
9. Atomically publish the successful answer turn or Reconsider result, optional
   replacement Memory, and one classified Profile effect: none, one reviewed
   Profile Change Proposal, or one staged evidence-only append. Pure evidence is
   applied locally and silently; semantic or mixed changes require Speaker approval.

No transcript is displayed as final while recording or while a transcription job
is incomplete.

Each Chat owns at most one unresolved Profile Change Proposal. It disables further
Chat input until Accept, Discard, or—when stale—Reconsider resolves it. Terminal
resolution deletes the operational Proposal record; accepted-proposal history is
backlog. A wholly evidence-only response is the narrow exception: Application
stages an idempotent union, applies it silently when possible, and exposes one
Retry/Discard publication failure when the local write fails.

## Product principles

- **Evidence before polish.** The canonical transcript is immutable evidence.
  Readability styling and coaching are overlays, never silent rewrites.
- **Local by default.** Authoritative Sessions—including their audio,
  transcription, and annotation—plus preferences, chats, and the Development
  Profile are stored on the Mac. Only evidence pinned to the Chat may be
  transmitted when provider and engine-use policies both allow it.
- **Explicit egress.** Codex runs only because the Speaker sends, retries, or
  reconsiders. The invoked Chat's Profile, Memory, history, trigger, and immutable
  attachments define the scope; audio is never sent, and Engine-use Policy may
  prohibit external processing.
- **Speech behavior, not character.** Audora describes evidence-linked speaking
  behavior and user-authored goals or preferences. It does not infer personality,
  character, motives, identity, or psychological traits from speech.
- **Recoverable work.** A failed worker, missing reference, or app restart must
  not destroy saved audio or the last valid transcript.
- **Honest progress.** Progress and ETA come from observable work. Unknown phases
  are shown as indeterminate instead of using a fake percentage.
- **Replaceable boundaries.** Transcription, storage, capture, annotation,
  playback, and coaching are ports with replaceable adapters.
- **Portable user data.** Authoritative user content lives under one copyable
  library directory and uses relative, ID-based references.
- **Focused interface.** The native UI serves recording, processing, review,
  navigation, and coaching. Legacy meeting, calendar, authentication, cloud, and
  web surfaces are not carried forward by default.

## Version-one scope

| Area | Committed behavior |
| --- | --- |
| Platform | Apple Silicon Mac; macOS 15 or later for the initial supported build |
| Distribution | Private, non-commercial personal build; no public or commercial distribution |
| App execution | Signed, Hardened Runtime, deliberately non-App-Sandbox personal build; App Sandbox packaging is backlog |
| Portability | Domain, Application, and Contracts compile and test on macOS and Linux; no non-macOS application ships |
| Language | English transcription and English-specific annotation rules |
| UI | Native SwiftUI/AppKit application; no browser shell or embedded web UI |
| Capture | One mono microphone recording with Record, Stop, and microphone mute |
| Import | One mono or stereo M4A/WAV retained in original form and deterministically normalized to canonical mono |
| Duration | At most 45 minutes per recording or imported file |
| Transcription | Post-recording, local verbatim engine; CrisperWhisper Small/MPS is the provisional evaluation candidate |
| Worker | App-supervised local process behind a transport-neutral port; first profile uses versioned JSON Lines over anonymous pipes |
| Processing | Durable states, visible phases, monotonic progress, approximate ETA, Cancel, Retry |
| Transcript | Immutable revisions retained in version one, stable line/word IDs, integer-millisecond timings |
| Review | Audio player, word-level seek with line fallback, active-word highlighting |
| Annotation | Local Textual Events and Audio Events; broader reformulation interpretation belongs to coaching |
| Coach | Required user-triggered capability behind a replaceable provider port; Codex is the only version-one provider, receives small attached transcripts inline and can retrieve large ones through a capability-scoped batch read, and runs only when Engine-use Policy permits external processing |
| Development Profile | One compact, revisioned structured statement set included in every coaching request; it records goals, preferences, accepted speaking observations, and growth directions without becoming a chronological log or character inference |
| Chat | Persisted but disposable, finite-capacity reflection over the Development Profile and zero or more immutable Chat Session Attachments; it owns current bounded structured Coach Memory, one recoverable Chat Draft, at most one Pending User Turn, successful message history, and at most one unresolved Profile Change Proposal or Profile-publication failure |
| Storage | One active portable Library, isolated from every other Library, containing its preferences, Development Profile, Sessions with owned audio, and chats |
| Recovery | Explicit missing/corrupt/in-trash states; moving a Session to Trash never cascades to Chats or changes accepted Development Profile statements; version one never empties Trash |

Coach Provider qualification must prove that the largest valid structured Coach
Memory fits inside both the minimum Request's usable input and the minimum valid
Response's `responseReservedTokens` and collector byte ceiling. Reserve plus safety
margin must remain strictly below the context window. Every Attempt also caps
provider output at or below that token reserve and tells the coach that its
complete structured response must fit.

The first isolated Codex CLI feasibility harness lives under
[`Qualification/CodexCLI`](../Qualification/CodexCLI/README.md). Codex CLI 0.143.0
is not a qualified Coach Provider: deterministic response, failure-mapping,
cancellation, timeout, and reaping tests pass, but the authenticated structured
response did not complete, the CLI exposes no documented provider-side output-token
ceiling, and its core model-visible tool surface cannot be reduced to only Audora's
future scoped transcript read. The application must not wire this candidate into
its composition root until the exact shipping CLI/model pair passes every gate.

The synthetic Attempt-scoped transcript-read qualification lives under
[`Qualification/TranscriptReadBroker`](../Qualification/TranscriptReadBroker/README.md).
Its actor, strict MCP boundary, and IPv4 loopback listener pass the deterministic
all-or-nothing, bounded-redelivery, revocation, contract, sanitization, and hostile
transport suite without opening a Library or reading provider credentials. This
does not change the Codex result above: the real CLI/model exercise remains not run
for this gate and production coaching remains blocked on the shipping-provider
evidence.

The executable Send slice crosses one Application-owned Invocation coordinator.
It revalidates the locked Pending User Turn and exact prepared context, claims the
machine-local Library rolling window, and durably installs one portable Invocation
before its deterministic synthetic Provider can run. Its only successful effect is
one atomic user/Coach message pair plus a fresh Draft; pre-commit interruption or
CAS conflict publishes neither message and retires the installed authority. Live
composition still fails closed because the shipping Provider descriptor is not
qualified. Real Provider execution, automatic retries, Stop, transcript tools,
and Profile or Memory effects remain outside this slice.
If the machine-local ledger rename succeeds but its parent-directory flush cannot
prove durability, Audora treats the debit as possibly committed and preserves the
exact Pending User Turn as interrupted and user-retryable; it never unlocks that
Draft as a pre-admission rejection.
Invocation liveness is acquired atomically with the first exact Pending
resolution, so concurrent catalog recovery cannot interrupt a live Send between
resolution and reservation. Pending User Turn schema v2 persists the interrupted
failure; strict v1 compatibility permits only no failure or the older context-fit
failure and upgrades when that Pending is next written.

Version one accepts exactly one transcribable mono source per Session. A possible
later extension adds dual-track capture: the Speaker's microphone plus a
separately retained, aligned system or application-audio source. Storage and
worker contracts already represent inputs as source-tagged collections so this
extension does not require replacing the contract, but version-one validation
rejects multiple tracks. System audio is backlog, not partially implemented
scope. Stopping seals the audio permanently; another take creates another Session
rather than appending to the first.

Opening a complete copied library on another Mac is in scope. Merging two
libraries is not. A direct backup copy is consistent only while Audora is closed;
live snapshots are backlog.

## User interface

The native application has a reduced set of states:

- **Library:** session/chat title and metadata filtering, Record, and Import Audio;
  transcript full-text search remains backlog.
- **Recording:** elapsed time, microphone level, mute state, Stop, Cancel, and
  persistent warnings as the 45-minute automatic-stop limit approaches.
- **Processing:** saved-audio player, current phase, progress, approximate ETA,
  Cancel, and no partial canonical transcript.
- **Ready:** player, transcript, local annotations, and coaching actions.
- **Session analysis:** Analyze opens Chat creation with that Session locked while
  allowing optional additional Sessions. If other active Chats already attach the
  source Session, a reusable confirmation shows the total and up to three clickable
  recent Chats before **Create new** proceeds. Successful creation seeds the Draft
  with this app-authored text and immediately submits it through the ordinary Send
  path. With one attachment it says **“Analyze this Session and give me practical
  speaking feedback.”** With several it says **“Analyze these Sessions and give me
  practical speaking feedback.”** The coach receives an ordinary user-message
  trigger. Until a response succeeds, the text remains visible in the disabled
  composer rather than becoming Chat history. New Chat never sends automatically.
  On that first Session Analysis response, the coach also attempts any useful
  evidence-backed Profile effects; validation and deduplication may leave none.
- **Interrupted recording:** validate the recoverable frames, then offer Seal
  Recovered Recording or Discard; never Resume or append.
- **Interrupted or failed processing:** retained sealed audio, concise error,
  Retry, and model preparation/reinstallation for the sole version-one engine.
- **Unavailable:** explicit missing audio, transcript, model, or linked-session
  state with recovery actions.
- **Chat:** provider/user messages plus derived Profile-update dividers. A
  Statement-changing Profile revision appears as a compact divider, never as an
  assistant message; evidence-only updates are visually silent. A tail divider is
  rewritten to the newest Statement generation when no message intervenes, while
  genuinely adjacent dividers remain supported and accessible. Provider,
  response-validation, transcript-read, interruption, and local-capacity
  failures occupy the Pending User Turn's terminal area with bounded **Retry** and
  **Discard** actions; they never accumulate as ordinary history items or appear as
  toast-only errors. A post-response Profile-publication failure remains a separate
  card on its already published coach Message. Chat rows project independent
  activity and Profile-update icons; one slow `processing` state covers provider
  work and automatic retry delays. The Chat Draft is persisted periodically and
  synchronously before Send. Send freezes its exact ID/version into one Pending
  User Turn but leaves the Draft text in the disabled composer. Retry reuses that
  exact trigger. Discard hides the failure and unlocks the same populated Draft for
  editing; it creates no message or abandonment event. Only successful response
  publication promotes the Draft into one immutable user message beside its coach
  response, then clears both the matching Draft and Pending User Turn. Coach Memory
  stays at the last successful response throughout an unanswered failure.
  A truncated or collector-oversized Coach Response may use one remaining authorized
  Attempt for immediate repair; it becomes user-retryable if no slot remains or the
  overflow repeats.
  An authoritatively over-capacity Send installs a durable
  `CoachContextCannotFitUserRetryable` on the Pending User Turn without admitting
  an Invocation or launching a Provider Attempt. The persistent card says
  **“Chat size exceeded. Please create a new one.”** Retry
  recalculates the same locked Draft and response position: if the request now fits
  it creates that position's first Invocation, otherwise it reproduces the local
  failure. Discard hides the card and unlocks the same populated Draft without
  provider work; a stale Retry after Discard fails against the removed Pending User
  Turn. Corrupt Chat data freezes that Chat permanently and directs the Speaker to
  create another. Catalog recovery and launch-identity checks isolate that failure
  per Chat, so a corrupt or newer-schema sibling does not hide healthy Chats or
  block their Send path.
- **Coach context:** a subtle `X / max` text beside Send shows the latest
  provider-specific context quote, where `max` is usable input capacity after the
  current-response reserve and safety margin, and expands to Profile, Coach Memory,
  the complete eligible prose-history projection, current Draft, fixed overhead,
  and the conservative complete-exchange reserve for every on-demand immutable
  attachment.
  The category disclosure also lists the response reserve and safety margin.
  Category token costs are explanatory and are not summed: only the complete
  framed model-message sequence decides fit because tokenizer boundaries differ.
  The creation picker shows Session duration and estimated transcript cost and
  rejects an attachment set whose complete evidence can never fit with **These
  Sessions cannot fit together in this coach's context. Remove a Session.**
  At Send, Application uses the actual current Profile, Memory, and complete
  eligible prose-history projection; it never omits successful turns merely
  because the request is large. Creation feasibility may conservatively reserve
  configured Profile and Memory maxima and may reject an inherently impossible
  attachment set before installing a Chat. These estimates are not coach-controlled
  fields. A rejected transcript batch releases no partial transcript.
  New Chat may use zero or more attachments; Analyze locks its source Session in
  the same picker. Attachments cannot change after creation, so another set requires
  a new Chat. While the Library-wide one-per-minute admission gate is closed,
  Send, Invocation Retry, and Reconsider are disabled and use the forbidden cursor;
  local Profile-publication Retry remains available. Audora creates no separate
  waiting state. If a new Send loses a final eligibility, concurrency, or admission
  race, its provisional Pending User Turn is removed, its unchanged Draft unlocks,
  and an accessible fleeting notice appears. The capacity failure above remains
  the explicit persistent exception.

Version one exposes exactly one main Library window. New-window commands are
unavailable, and another open request focuses the existing window. Sheets and
transient dialogs do not count as Library windows.

Transcript Words store portable UTF-8 ranges into each line's display text; the UI
converts them into a TextKit-backed attributed view rather than thousands of SwiftUI
buttons. Clicking a timed Word seeks to its start;
untimed text falls back to its semantic line. Punctuation is display text, not a
Word entity or evidence anchor; clicking it seeks to the closest preceding timed
Word, then the closest following timed Word or line start when none precedes it.
One global annotation-visibility control switches all annotation styling together;
there are no per-word visibility controls. Hiding or dimming annotations never
removes content from copy or export.

Coach messages combine flexible Markdown with optional, always-visible inset
Evidence-backed Observation blocks whose app-generated controls open the exact
supporting Transcript Revision, highlight its trusted anchor, and seek audio when
available. Hovering an available evidence control adds a subtle background highlight
and underlines its label; keyboard focus receives the same emphasis plus the native
focus ring. They do not create transcript comments or Session-owned feedback.
When a requested transcript batch is unavailable or cannot fit, Application stops
that Attempt and exposes the ordinary UserRetryable turn failure, listing at most
three affected Sessions as accessible links. It does not ask the coach to improvise
an incomplete answer.

Nested Evidence References resolve structured Session, Transcript Revision, and
trusted word or time anchors into links. If evidence is missing, in Trash,
corrupt, or unsupported, the reference remains visible but unavailable, with an
explanation accessible by click/focus rather than hover alone. A compact label
such as **Unavailable Session · 23 Aug 2026, 14:35** uses the reference's saved
display label rather than showing a raw ID; dimming or strikethrough is
supplemental. Restoring matching evidence heals the link. The accepted Profile
insight remains active throughout: Session removal or loss never edits or
re-evaluates the Profile. Evidence References are nested values, not independently
identified Citation entities.

## Layered architecture

The native UI is one adapter, not the owner of business rules:

```text
Presentation
  SwiftUI/AppKit views + presentation models
                         |
Application
  use cases, job state machines, admission and recovery policy, ports
                         |
Domain
  Session aggregates, owned audio evidence, transcript revisions, annotations,
  chats, rules
                         ^
Infrastructure adapters |
  AVFoundation | portable files | Crisper process | Codex CLI | model installer
```

Dependency direction points inward. Domain and Application do not import SwiftUI,
AppKit, AVFoundation, Convex, Crisper, Codex, or concrete filesystem code.
Presentation sends intents to application use cases and renders application state;
it never launches a process or edits storage directly. A composition root in the
macOS target selects and wires concrete adapters, including the wall-clock
admission-refresh scheduler.

The first implementation can use Swift packages or Xcode targets for these
boundaries:

```text
AudoraDomain
AudoraApplication
AudoraContracts
AudoraMacInfrastructure
AudoraMacPresentation
AudoraApp
```

`AudoraDomain`, `AudoraApplication`, and `AudoraContracts` are SwiftPM-compatible
and compile and test on macOS and Linux in version one. This continuously proves
that their interfaces do not acquire Apple-framework dependencies; Windows and
WebAssembly builds are not version-one commitments.

`AudoraContracts` contains language-neutral JSON schemas, protocol examples, and
golden fixtures as resources; it is not a serialization dependency of Domain.
Adapters map transport/storage DTOs into bounded, shape/size/confinement/hash-
checked Application inputs at their seams. Those values remain semantically
untrusted until Domain/Application validation promotes them. Pure
algorithms such as filler labeling live in Domain and are tested against the shared
fixtures.

Presentation talks to a small inbound Application API of feature commands and
immutable feature-state snapshots. Language-neutral scenarios specify `initial
state + command + dependency event trace -> next state + effects`. A future browser
client can therefore reimplement Domain/Application behavior and platform adapters
in TypeScript while proving parity against the same schemas and scenarios. A later
shared Rust core remains possible if duplicated pure logic becomes costly.

This separation makes another presentation layer substantially easier, not
automatic. The first Domain/Application implementation is Swift; a browser must
either reimplement that behavior against the scenarios or consume a future shared
core. It also cannot launch local Crisper or Codex processes, use arbitrary library
directories, or reproduce macOS audio permissions without browser-specific
adapters or a local companion. Version one promises architectural and behavioral
portability through modules, contracts, and scenarios; it does not promise
cross-platform source compilation or an effortless port.

See [`concepts/architecture-layers.md`](concepts/architecture-layers.md) and the
layer diagram in [`media/layers.mmd`](media/layers.mmd).

## Runtime flow

```text
SwiftUI intent
  -> RecordAudio or ImportAudio use case
  -> AudioCapture/AudioImporter port
  -> Session with owned sealed Audio Asset is committed
  -> TranscribeSession use case creates a durable job
  -> transcription adapter starts the constrained private worker
  -> progress events update application state
  -> adapter returns an untrusted staged candidate
  -> Application validates and promotes it to a transcript revision
  -> deterministic Domain annotation runs
  -> ready state becomes visible
  -> optional CreateAnalysisChat pins its source Session plus any creation-time additions
  -> Invocations.tryInvoke checks eligibility, context, and Library-wide admission
  -> an admitted Invocation launches bounded Provider Attempts against that attachment set
  -> the Chat atomically publishes the user/coach turn, optional new Memory,
     and one classified Profile effect: none, Proposal, or pure evidence staging
  -> Application validates at most one Proposal as unresolved within that Chat
  -> the Speaker may approve it; Audora locally commits a new Profile Revision
```

Ordinary use has one native application plus transient local workers. It does not
require Vite, Node, Convex, Clerk, JWT, a localhost web server, or an embedded
browser.

## Portable library

All authoritative portable user data lives under one directory:

```text
Audora Library.audoralibrary/
  library.json
  preferences.json
  profile/
    head.json                      # nullable current pointer and generations
    revisions/<profile-revision>/
      revision.json               # structured authority
      revision.sha256              # detached exact-byte digest
  sessions/<session-id>/
    session.json
    audio/...
    transcripts/...
    annotations/...
  chats/<chat-id>/...            # messages and unresolved operational state
  jobs/<job-id>/...
  staging/recordings/<recording-id>/...
  staging/jobs/<job-id>/...
  trash/...
```

`head.json` contains monotonic physical and Statement generations plus nullable
current revision ID/hash fields. Every revision bundle is independently checked by
its detached SHA-256. If the current revision is broken, a Library-level banner
offers one automatic recovery. It excludes every generation claimed by multiple
revision bundles, copies the highest-generation remaining healthy revision into a
fresh monotonic revision, or sets the head to the null-Profile state when none is
eligible. All broken and colliding revision bundles remain available for
inspection. A null Profile is projected to the coach as an empty Statement array.

Session, Recording, Chat, Profile Revision, Profile Statement, and Profile Change
Proposal IDs use a typed UTC timestamp plus four random Crockford Base32
characters, for example `ses-20260822T153045123Z-P4R7` and
`rec-20260822T153045123Z-P4R7`. A RecordingID identifies only one incomplete
capture aggregate under `staging/recordings/<recording-id>`. Its identity root
binds that RecordingID to the intended SessionID, LibraryID, capture start
instant, canonical format, and duration ceiling. Sealing installs the immutable
Session under its SessionID; cancellation and recovery cleanup remain scoped to
the RecordingID. A RecordingID never becomes an Audio Asset ID or a portable
relationship after sealing. A Session owns its Audio Asset by containment rather
than by an independent audio ID. Other relationships use explicit IDs and
relative paths; timestamps are not relationships.

For imported media, version one retains the original file as evidence and also
creates a canonical mono WAV for playback, analysis, and timestamps. This uses
more disk space but avoids making a destructive format conversion part of import.

Microphone capture declares its physical format before the first event and uses a
bounded, loss-aware relay: muted callbacks retain timing only, and any unavailable
source interval remains explicit on the canonical timeline. After microphone
authorization and preparation, the source declares one monotonic capture origin
immediately before starting. Callback projection, displayed elapsed time, mute
and Stop boundaries, warnings, and the 45-minute ceiling all use that origin;
permission wait is never recorded time. Capture and import share the same
qualified streaming converter. Long unavailable intervals advance it through a
bounded bridge and an absolute-phase reset, so later observed audio stays
deterministic while work remains independent of the interval's duration; the
45-minute ceiling is applied before that work begins. The exact version-one
normalization and discontinuity rules live in
[`concepts/audio-processing.md`](concepts/audio-processing.md).

Credentials, Codex login state, model weights, the Python runtime, caches, macOS
permission grants, and the machine-specific locator needed to reopen the Library
remain outside it. A copied library heals unresolved Chat and Development Profile
references when the referenced Session or Transcript Revision reappears.

Each Library is an isolated project. IDs, references, searches, chats, coaching
envelopes, and Development Profile evidence never cross Library roots. Version-one
files are not encrypted by Audora; at-rest protection relies on macOS account
permissions and disk encryption such as FileVault.

See [`concepts/portable-library.md`](concepts/portable-library.md).

## Privacy and trust boundaries

- Microphone audio is captured and stored locally.
- The transcription worker receives only capability-scoped job/model paths through
  its private process protocol. Its launch profile scrubs ambient credentials and
  configuration and must enforce no network during cached inference.
- Local annotation never invokes Codex.
- Codex receives a bounded Invocation: a structured `CoachRequest` containing the
  current trigger, complete current Development Profile, current bounded Coach
  Memory, successful Chat history, and every immutable Chat Session Attachment
  under a Chat-scoped ID. Small transcripts are inline; each large
  transcript has a fresh opaque `SessionTranscriptHandle`. Library Session and
  Transcript Revision IDs are not provider fields. One hidden bearer capability
  covers that Provider Attempt's attachment set. A single allowlisted,
  read-only Audora MCP tool accepts one nonempty handle array and atomically returns
  the requested subset of exact attached Transcript Revisions; it accepts no path,
  arbitrary Session ID, write, search, audio, or Library operation. The
  language-neutral provider seam is
  [`contracts/contracts.tsp`](contracts/contracts.tsp); compilation emits
  the committed machine-readable schemas. Every Provider Attempt receives fresh
  transcript handles, one hidden capability, and one provider idempotency key.
  Application—not the coach—owns read limits, automatic retry, and cancellation.
- Audora never supplies Codex with a Library path or model-facing filesystem
  capability. The transcript tool is backed by an attempt-scoped read capability
  held outside model content; Codex sees only opaque `SessionTranscriptHandle`s. The
  non-App-Sandbox authenticated CLI process retains the ordinary OS access needed
  for its executable, authentication state, and OpenAI network connection; version
  one claims task-level confinement, not OS-level process confinement.
- A Profile Change Proposal has no write authority. Application validates each
  returned pointer against the canonical Transcript Revision of a Session attached
  to the Chat and presents the resulting change as a human-readable card. The same
  structural rule applies whether the coach learned the pointer from a transcript
  read or current Memory; Application does not judge whether evidence semantically
  proves the claim.
  Existing Profile evidence is projected only when its exact
  `(sessionId, transcriptRevisionId)` pair is attached; another revision of the
  same Session is never substituted.
  Moving the Chat to Trash preserves an unresolved Proposal. Only explicit approval commits semantic
  additions, replacements, retirements, or mixed changes. A wholly evidence-only
  Coach Response for active Statements is first durably staged by the same Chat CAS
  that publishes its message and Memory. The Profile set union is a separate local
  transaction: success resolves the staged record silently, while failure retains
  it with **Retry** and **Discard** and never rolls back the published response.
- Raw audio, absolute local paths, credentials, voice embeddings, and unrelated
  sessions are excluded from coaching requests.
- Transcript content, prior Chat prose, and Coach Memory are untrusted data, never
  instructions. The
  Codex adapter disables inherited tools and exposes only Audora's scoped
  transcript-read MCP tool—never shell, browser, plugin, generic network, or
  filesystem tools.
- App logs contain IDs, phases, durations, and redacted error codes, not transcript
  excerpts, audio paths, prompts, Memory, or provider diagnostics that may contain
  data. Metadata logs rotate at a total 100 MiB cap.

## Concept index

- [`architecture-layers.md`](concepts/architecture-layers.md): dependency rules,
  ports, composition, and cross-platform seams.
- [`portable-library.md`](concepts/portable-library.md): directory format, IDs,
  references, atomic writes, backup, and degraded states.
- [`audio-processing.md`](concepts/audio-processing.md): mono capture/import,
  canonical timeline, normalization, mute, and sealing.
- [`transcription-worker-contract.md`](concepts/transcription-worker-contract.md):
  engine abstraction, worker protocol, progress, cancellation, and validation.
- [`transcript-contract-and-seeking.md`](concepts/transcript-contract-and-seeking.md):
  immutable revisions, stable anchors, lines, words, and playback seeking.
- [`filler-repetition-pause-labeling.md`](concepts/filler-repetition-pause-labeling.md):
  local annotation rules and evidence-preserving display behavior.
- [`coaching-and-chat.md`](concepts/coaching-and-chat.md): coach port, Codex data
  boundary, structured anchors, rate limits, and local chat persistence.
- [`execution-and-distribution.md`](concepts/execution-and-distribution.md): the
  selected personal-build execution profile, worker isolation, engine
  qualification, and license gates. The versioned Crisper profile, numeric
  thresholds, runner, and blocked preflight are under
  [`Qualification/CrisperBenchmark`](../Qualification/CrisperBenchmark/README.md);
  the adversarial production-restriction harness and its recorded synthetic proof
  are under
  [`Qualification/WorkerConfinement`](../Qualification/WorkerConfinement/README.md).
  Both artifacts keep real Crisper qualification blocked while the locked
  runtime/model and compatibility patch are absent; a blocked gate does not
  promote the provisional candidate.
- [`implementation-plan.md`](concepts/implementation-plan.md): ordered delivery
  phases and repository strategy.
- [`release-readiness.md`](concepts/release-readiness.md): acceptance and release
  evidence required before version one is considered ready.
- [`system-context.mmd`](media/system-context.mmd) and
  [`layers.mmd`](media/layers.mmd): editable architecture diagrams.
