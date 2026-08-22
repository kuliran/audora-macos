# Backlog

These are possible directions, not version-one commitments. Promoting an item into
scope requires updating the central [`../README.md`](../README.md), its affected
concept documents, and acceptance criteria in the same commit.

## Input and transcription

### System audio

Capture a separately aligned system/application source with its own mute and
availability intervals. Extend the existing source collection rather than changing
the worker envelope. When both sources contain evidence, transcribe sequentially
through one loaded model and merge source-tagged words on the common timeline.

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

A per-job bundled XPC execution helper selected by the phase-zero sandbox gate is
not this backlog item. “Persistent worker” here means retaining a loaded model or
service across jobs and introducing shared lifecycle/state.

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
staging directory, validating it, and atomically publishing the snapshot. Version
one instead documents copying a closed library.

### Projects, folders, tags, and search

Add organizational entities and a rebuildable SQLite/FTS index when real library
size makes in-memory metadata scanning inadequate. Authoritative content remains
in portable manifests and sidecars.

### Longitudinal coaching

Generate user-authorized reports across selected time windows, tracking recurring
issues and metric trends. Inputs must be explicit, reports revisioned, and external
egress separately disclosed. Do not build a hidden cross-session profile.

### Encrypted or synchronized backup

Consider encrypted archives or user-selected cloud folders without moving
credentials into the portable library. Conflict handling and incomplete remote
writes require a separate design.

## Analysis and coaching

### Thought-boundary classification

Use audio and lexical cues to distinguish probable hesitation, rhetorical pause,
completed thought, and response latency. Labels remain probabilistic and preserve
the measured underlying intervals.

### Local coach

Implement the `CoachProvider` port through a verified local model runtime. It must
declare its telemetry/network boundary and pass the same structured-anchor tests as
Codex.

### Multi-speaker and diarization

Support multiple voices only with source-aware or purpose-built diarization/ASR.
Avoid persistent voice embeddings unless a separately reviewed feature requires
cross-session identity and the user explicitly opts in.

## Platforms and distribution

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

### Legacy migration

Build a copy-first importer for existing Audora meeting JSON and mixed WAV files.
Until then, users can recover legacy content through ordinary mono audio import;
legacy live transcripts may be retained as clearly labeled historical revisions.
