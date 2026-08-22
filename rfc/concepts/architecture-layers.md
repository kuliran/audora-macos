# Architecture layers

This document elaborates on the dependency boundaries summarized in the central
RFC. It defines responsibilities, not a required folder spelling.

## Domain

The Domain layer contains values and deterministic rules:

- audio assets and muted intervals;
- sessions and transcript revisions;
- timed lines and words;
- annotations and acoustic events;
- coaching reports, chats, and anchors;
- IDs, time ranges, reference states, and schema versions;
- validation and deterministic labeling policies.

Domain code has no UI, process, filesystem, database, audio-framework, model, or
network imports. Time, random IDs, and external state enter as values.

## Application

The Application layer coordinates use cases and owns state transitions:

- create or open a library;
- record, mute, stop, cancel, and import audio;
- start, monitor, cancel, retry, and recover processing jobs;
- publish a validated transcript revision;
- annotate and calculate metrics;
- play or seek through abstract playback controls;
- request coaching after validating consent and payload scope;
- create, rename, organize, and delete sessions and chats.

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

Application policies must not be duplicated in UI adapters. For example, the
`AnalyzeWithCoach` use case—not a button—enforces consent, context selection, and
payload limits.

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
job, consent, cancellation, and recovery behavior therefore does not live only in
SwiftUI presentation models.

External providers never return authoritative Domain entities. Infrastructure
first confines and reads transport artifacts, verifies their declared hashes and
size limits, parses their DTO shape, and returns an Application candidate.
Transcription returns `TranscriptionCandidate`; coaching returns annotation/report
drafts. These are not Domain values and remain semantically untrusted. Application
and Domain then perform identity, time/order, integrity, license-policy, and anchor
checks before Application asks the repository to publish a canonical value. Only
Application may publish or change authoritative manifests.

## Infrastructure

Infrastructure implements ports with replaceable adapters:

- AVFoundation microphone capture and playback;
- the portable filesystem repository and security-scoped bookmark locator;
- audio normalization and media inspection;
- the Crisper Python/MPS worker process;
- model installation and cache validation;
- platform-dependent audio decoding, VAD, and acoustic evidence extraction;
- the ChatGPT-authenticated Codex CLI provider;
- constrained process execution for transcription and coaching;
- derived search indexes when introduced.

Infrastructure converts external errors into bounded application error codes. It
does not expose provider stderr, filesystem paths, or framework-specific objects to
Domain or Presentation.

Pure filler, partial-word, repetition, restart, and pause-composition rules are
Domain services, not Infrastructure adapters. They consume Domain transcript
values plus normalized acoustic evidence returned by `AcousticEvidencePort`.

## Presentation

Presentation contains SwiftUI/AppKit views and presentation models. It:

- renders immutable feature state;
- sends user intents to application use cases;
- formats progress, ETA, dates, metrics, and recoverable errors;
- maps attributed transcript ranges to stable word IDs;
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
