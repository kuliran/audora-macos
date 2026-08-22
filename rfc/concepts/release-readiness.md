# Release readiness

Version one is ready only when the phase-zero decisions are recorded and the
following evidence passes in the selected Release execution profile.

## Local workflow

- After dependencies and the model are installed, recording, local transcription,
  review, storage, and annotation work with the web app, Convex, and network
  stopped.
- Coaching reports an explicit offline state when OpenAI is unavailable.
- Recording/import seals audio before transcription begins.
- Imported M4A playback and transcript timestamps share one canonical timeline.
- Imported media retains its original file and a canonical normalized artifact.

## Transcription and review

- The labeled one-minute and thirty-minute acceptance fixtures retain their
  beginning/tail phrases and required disfluency events within the versioned
  qualification thresholds.
- Progress does not regress; ETA is labeled approximate; Cancel and worker failure
  retain retryable audio.
- Only a complete, validated revision becomes the selected transcript.
- Word and line clicks seek correctly; dimmed evidence remains copyable and can be
  shown at full opacity.

## Storage and recovery

- The library survives ordinary closed-app copying to another Mac.
- Missing, corrupt, unsupported, and in-trash references produce the documented
  degraded states without cascade deletion.
- Every durable job state passes crash/restart reconciliation fixtures.

## Trust boundaries

- No Codex process starts until the user invokes coaching, the transcript engine's
  policy permits external processing, and the user approves a disclosure generated
  from the exact payload envelope.
- Adversarial worker tests prove unrelated filesystem paths and network endpoints
  are unavailable to cached transcription in the selected execution profile.
- The authenticated Codex adapter passes its isolated launch, structured-output,
  cancellation, and no-local-rollout tests.
- Domain and Application tests run without SwiftUI, AVFoundation, Crisper, Codex,
  network access, or a real user library.

Numeric quality, coverage, runtime, memory, and thermal thresholds are published as
versioned qualification fixtures during phase zero. This document links those
artifacts once they exist rather than inventing thresholds from a single benchmark.
