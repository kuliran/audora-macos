# Audora local speech coach

This directory is the canonical product and architecture specification for the transformed Audora macOS application.
The existing Audora application serves as the basis, with useful native capture and playback code.

## Documentation rule

Read this file before making product or architecture changes. Every conceptual
change or addition must be reflected here in the same commit as the detailed RFC
or implementation. Put details that would obscure this overview under
[`concepts/`](concepts/), and keep speculative work under
[`backlog/`](backlog/README.md).

Git commits are the history. These RFC files describe only the current direction;
they do not maintain a changelog or retain superseded decisions.

## Product

Audora is a private, local-first macOS speaking-reflection application. A user
records one microphone track or imports one audio file, waits for local batch
transcription, reviews a verbatim timestamped transcript, and optionally asks an
AI coach for feedback. The product is intended to preserve speech evidence such
as fillers, false starts, immediate repetitions, and pauses rather than silently
turning it into polished prose.

The essential loop is:

1. Record mono microphone audio or import a mono audio file.
2. Seal and save the audio before inference starts.
3. Transcribe locally with the qualified engine; the current personal-evaluation
   candidate is CrisperWhisper Small.
4. Validate and atomically publish the completed transcript.
5. Add local, non-destructive speech annotations and metrics.
6. Review the transcript alongside synchronized audio.
7. Optionally send an explicitly selected transcript context to Codex for
   coaching.

No transcript is displayed as final while recording or while a transcription job
is incomplete.

## Product principles

- **Evidence before polish.** The canonical transcript is immutable evidence.
  Readability styling and coaching are overlays, never silent rewrites.
- **Local by default.** Authoritative audio, transcription, annotation, metrics,
  preferences, sessions, and chats are stored on the Mac. Only explicitly approved
  excerpts may be transmitted when provider and engine-use policies both allow it.
- **Explicit egress.** Codex runs only after a user action that previews the exact
  classes of data in the request envelope. Audio is never sent to the coach, and
  engine output-use policy can prohibit external processing entirely.
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
| Language | English transcription and English-specific annotation rules |
| UI | Native SwiftUI/AppKit application; no browser shell or embedded web UI |
| Capture | One mono microphone recording with Record, Stop, and microphone mute |
| Import | One mono M4A or WAV copied into the library and normalized locally |
| Transcription | Post-recording, local verbatim engine; CrisperWhisper Small/MPS is the provisional evaluation candidate |
| Worker | App-supervised local process behind a transport-neutral port; first profile uses versioned JSON Lines over anonymous pipes |
| Processing | Durable states, visible phases, monotonic progress, approximate ETA, Cancel, Retry |
| Transcript | Immutable revisions, stable line/word IDs, integer-millisecond timings |
| Review | Audio player, word-level seek with line fallback, active-word highlighting |
| Annotation | Local deterministic filler, partial-word, nearby repetition, restart, and pause overlays |
| Metrics | Local timing and delivery measurements; no voice embeddings |
| Coach | User-triggered Codex provider with structured, validated anchors, only when the selected transcript's output-use policy permits external processing |
| Chat | App-owned local chat history linked to zero or more sessions |
| Storage | One portable library containing preferences, audio, sessions, and chats |
| Recovery | Explicit missing/corrupt/in-trash states; no silent cascade deletion |

Version one accepts exactly one transcribable mono source per session. Storage and
worker contracts represent inputs as source-tagged collections so later sources
can be added without changing the contract, but version-one validation rejects
multiple tracks. System audio is backlog, not partially implemented scope.

Opening a complete copied library on another Mac is in scope. Merging two
libraries is not. A direct backup copy is consistent only while Audora is closed;
live snapshots are backlog.

## User interface

The native application has a reduced set of states:

- **Library:** session/chat title and metadata filtering, Record, and Import Audio;
  transcript full-text search remains backlog.
- **Recording:** elapsed time, microphone level, mute state, Stop, and Cancel.
- **Processing:** saved-audio player, current phase, progress, approximate ETA,
  Cancel, and no partial canonical transcript.
- **Ready:** player, transcript, local annotations/metrics, and coaching actions.
- **Interrupted or failed:** retained audio, concise error, Retry, and model
  preparation/reinstallation for the sole version-one engine.
- **Unavailable:** explicit missing audio, transcript, model, or linked-session
  state with recovery actions.

Transcript words are rendered through a TextKit-backed attributed text view rather
than thousands of SwiftUI buttons. Clicking a timed word seeks to its start;
untimed text falls back to its semantic line. Dimming annotations never removes
content from copy or export, and the user can restore full opacity.

## Layered architecture

The native UI is one adapter, not the owner of business rules:

```text
Presentation
  SwiftUI/AppKit views + presentation models
                         |
Application
  use cases, job state machines, consent and recovery policy, ports
                         |
Domain
  sessions, audio assets, transcript revisions, annotations, chats, rules
                         ^
Infrastructure adapters |
  AVFoundation | portable files | Crisper process | Codex CLI | model installer
```

Dependency direction points inward. Domain and Application do not import SwiftUI,
AppKit, AVFoundation, Convex, Crisper, Codex, or concrete filesystem code.
Presentation sends intents to application use cases and renders application state;
it never launches a process or edits storage directly. A composition root in the
macOS target selects and wires concrete adapters.

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

`AudoraContracts` contains language-neutral JSON schemas, protocol examples, and
golden fixtures as resources; it is not a serialization dependency of Domain.
Adapters map transport/storage DTOs into bounded, shape/size/confinement/hash-
checked Application candidates at their boundaries. Those candidates remain
semantically untrusted until Domain/Application validation promotes them. Pure
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
adapters or a local companion.

See [`concepts/architecture-layers.md`](concepts/architecture-layers.md) and the
layer diagram in [`media/layers.mmd`](media/layers.mmd).

## Runtime flow

```text
SwiftUI intent
  -> RecordAudio or ImportAudio use case
  -> AudioCapture/AudioImporter port
  -> portable Audio entity is committed
  -> TranscribeSession use case creates a durable job
  -> transcription adapter starts the constrained private worker
  -> progress events update application state
  -> adapter returns an untrusted staged candidate
  -> Application validates and promotes it to a transcript revision
  -> deterministic Domain annotation and local metrics run
  -> ready state becomes visible
  -> optional AnalyzeWithCoach use case checks consent and invokes Codex
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
  audio/<audio-id>/...
  sessions/<session-id>/...
  chats/<chat-id>/...
  jobs/<job-id>/...
  staging/<job-id>/...
  trash/...
```

Audio, session, and chat IDs use a typed UTC timestamp plus four random Crockford
Base32 characters, for example `ses-20260822T153045123Z-P4R7`. Relationships use
explicit IDs and relative paths; timestamps are not relationships.

For imported media, version one retains the original file as evidence and also
creates a canonical mono WAV for playback, analysis, and timestamps. This uses
more disk space but avoids making a destructive format conversion part of import.

Credentials, Codex login state, model weights, the Python runtime, caches, macOS
permission grants, and the machine-specific security-scoped bookmark locating the
library remain outside it. A copied library heals previously missing references
when matching entities reappear.

See [`concepts/portable-library.md`](concepts/portable-library.md).

## Privacy and trust boundaries

- Microphone audio is captured and stored locally.
- The transcription worker receives only capability-scoped job/model paths through
  its private process protocol. Its launch profile scrubs ambient credentials and
  configuration and must enforce no network during cached inference.
- Local annotation and metrics never invoke Codex.
- Codex receives a bounded `CoachPayloadEnvelope`: the current user request,
  explicitly selected prior chat messages, selected transcript slices and anchor
  IDs, optional rounded metrics, and fixed versioned provider instructions. The
  consent display is derived from that exact envelope rather than a parallel
  description.
- Raw audio, absolute local paths, credentials, voice embeddings, and unrelated
  sessions are excluded from coaching requests.
- Transcript content is untrusted input. Provider adapters use bounded structured
  output and do not expose shell, browser, plugin, or filesystem tools to it.
- App logs contain IDs, phases, durations, and redacted error codes, not transcript
  excerpts, audio paths, prompts, or provider diagnostics that may contain data.

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
- [`filler-restart-pause-labeling.md`](concepts/filler-restart-pause-labeling.md):
  local annotation rules and evidence-preserving display behavior.
- [`coaching-and-chat.md`](concepts/coaching-and-chat.md): coach port, Codex data
  boundary, structured anchors, rate limits, and local chat persistence.
- [`execution-and-distribution.md`](concepts/execution-and-distribution.md): worker
  isolation, App Sandbox choices, engine qualification, and license gates.
- [`implementation-plan.md`](concepts/implementation-plan.md): ordered delivery
  phases and repository strategy.
- [`release-readiness.md`](concepts/release-readiness.md): acceptance and release
  evidence required before version one is considered ready.
- [`system-context.mmd`](media/system-context.mmd) and
  [`layers.mmd`](media/layers.mmd): editable architecture diagrams.
