# Transcription worker contract

## Engine port

The application depends on a file/job-oriented port rather than a specific Python
package:

```swift
protocol TranscriptionEngine {
    func capabilities() async throws -> EngineCapabilities
    func prepare(model: ModelID) async throws
    func transcribe(
        request: TranscriptionRequest,
        events: @escaping (TranscriptionEvent) -> Void
    ) async throws -> TranscriptionCandidate
    func cancel(jobID: JobID) async
}
```

The provisional initial adapter is CrisperWhisper Small in English verbatim mode
using pinned Python, PyTorch, Transformers, model revision, and decoding options.
It executes locally through Apple MPS but is not a native Swift/Core ML model.
Version-one validation rejects unsupported languages rather than silently using
automatic detection or another model.

`TranscriptionCandidate` is a semantically untrusted Application DTO plus
provenance, diagnostics, and claimed timing coverage. Infrastructure has already
confined/read the staged artifact, enforced size limits, verified its hash, and
parsed its schema shape. It cannot be displayed as canonical or written into a
session manifest. Domain/Application validation is the only path that promotes it
to `TranscriptRevision`.

Model weights and generated outputs carry separate licensing constraints. The
engine descriptor exposes a reviewed `EngineUsePolicy` including
covered artifacts, private-local evaluation/export, external processing, public
distribution, commercial-use booleans, and a pinned license reference/hash.
CrisperWhisper is private local evaluation-only under Audora's conservative
policy: routine operational use, public sharing, and external processing remain
disabled until the exact license obligations are cleared or a compatible
replacement is secured. The license does not name Codex or ban all AI inference;
see
[`execution-and-distribution.md`](execution-and-distribution.md).

## Process boundary

The initial personal-build adapter owns a child process for the active
transcription job and communicates over anonymous stdin/stdout pipes using
versioned JSON Lines. There is no listener, port, named FIFO, Unix-domain socket,
token, or shell command. The Application-facing port and message DTOs are
transport-neutral so a future App Sandbox/XPC profile can preserve the same
request/event semantics and candidate-validation boundary.

- The executable URL and arguments are fixed by the adapter.
- Recording paths and transcript text do not appear in arguments or logs.
- Stdout contains protocol messages only.
- Stderr is bounded and mapped to redacted error codes.
- Inputs are paths relative to an app-created job directory; the worker rejects
  absolute paths, traversal, symlinks, and unexpected files.
- The process is terminated and reaped after completion/cancellation so MPS memory
  is reclaimed.

An `ExecutionHostPort` applies a pinned launch profile rather than relying on pipe
privacy alone:

- an allowlisted environment with proxy, cloud, token, plugin, Python-user-site,
  and ambient configuration variables removed;
- a dedicated empty home/config directory and job-scoped working directory;
- read-only access to the exact runtime/model revision and read-write access only
  to the job staging directory;
- no network for cached inference, and a distinct explicit preparation/download
  flow that fails if the model is missing;
- bounded CPU time, output size, stderr, open files, and termination grace;
- a startup `hello` that identifies protocol/runtime/model/patch versions before
  any Job metadata, model capability, or audio capability is accepted. The
  post-hello `transcribe` request begins Job correlation.

The chosen worker-confinement mechanism must prove these properties in an
adversarial integration test; the JSONL transport by itself does not enforce them.

## Requests and events

The contract is collection-shaped for future sources but validates one mono input
in version one:

```json
{
  "v": 1,
  "type": "transcribe",
  "jobId": "job-...",
  "engine": {
    "provider": "crisperwhisper",
    "model": "small",
    "revision": "pinned-revision"
  },
  "sources": [
    {
      "audioSourceId": "src-0001",
      "role": "microphone",
      "path": "input/audio.wav",
      "timelineOffsetMs": 0
    }
  ],
  "options": {
    "language": "en",
    "mode": "verbatim",
    "wordTimestamps": true
  }
}
```

Events are bounded and typed:

```json
{"v":1,"type":"phase","jobId":"job-...","phase":"loading_model"}
{"v":1,"type":"progress","jobId":"job-...","completed":9,"total":28,"unit":"window","etaSeconds":31}
{"v":1,"type":"candidate_ready","jobId":"job-...","result":"result.json","sha256":"..."}
{"v":1,"type":"failed","jobId":"job-...","error":{"code":"MODEL_MISSING","retryable":true}}
```

Large results are written to a partial file, validated by the worker, atomically
renamed, and referenced by relative path and hash. Partial transcript text is not a
canonical UI event.

`candidate_ready`, `failed`, and worker exit are adapter-private terminal protocol
signals. The Application port has exactly one terminal outcome: `transcribe`
returns one candidate, throws a bounded failure/cancellation, or is cancelled. Its
event callback carries only ordered nonterminal phase/progress events. The adapter
forwards none after its terminal outcome. Cancellation is idempotent; the first
accepted terminal outcome wins, and a late candidate after cancellation is
discarded. Scenario fixtures cover every race.

## Progress and ETA

Crisper already iterates known long-form windows, but the evaluated upstream build
does not expose a supported progress callback. The pinned adapter therefore carries
a small reviewed compatibility patch around that loop; it does not split the
recording into different independent ASR calls merely to manufacture progress.
The same patch must resolve or disable the upstream Transformers/CT2 lazy-import
failure explicitly—an inert module shim is not a production dependency strategy.

- Model loading and first-window compilation may be indeterminate.
- Window progress is monotonic.
- ETA begins only after enough measured work exists, then uses a robust rolling
  duration/window estimate and locally stored model/device history.
- ETA is labeled approximate and may increase.
- Cancellation requests cooperative stop first, then terminates and reaps the
  process after a bounded grace period.

## Durable jobs

States are `queued`, `preparing`, `running`, `validating`, `completed`, `failed`,
`cancelled`, and `interrupted`. The job is persisted before the process starts.

Only a returned candidate moves Application state from `running` to `validating`.
Only successful canonical publication moves `validating` to `completed`; the raw
worker's `candidate_ready` message never does. A thrown failure/cancellation maps to
one terminal Application state exactly once.

On app launch, Audora reconciles every durable job with owned-process state,
staging, and canonical manifests. No partial result becomes the selected
transcript.

Every state has deterministic restart reconciliation:

- `queued` remains queued;
- `preparing` and `running` become interrupted and retryable after owned processes
  are proven absent;
- `validating` resumes idempotent validation/publication when its staged candidate
  is confined, complete, and hash-valid, otherwise becomes interrupted;
- terminal `failed` and `cancelled` remain terminal;
- `completed` is accepted only when its canonical revision and manifest reference
  both validate; inconsistency opens a recovery error rather than rerunning.

Publication uses the job/revision ID as an idempotency key, covering a crash after
the revision file is installed but before job state is updated.

## Result validation

Before returning a candidate, Infrastructure validates path confinement, symlink/
file type, bounded artifact size, declared hash, JSON schema shape, and safe DTO
decoding. Before publication, Domain/Application validates:

- schema/model/job/source identity;
- finite, nonnegative, monotonic, in-bounds word times;
- stable line/word ordering and unique IDs;
- a defined mapping between display text and timed/explicitly untimed tokens;
- ending coverage relative to detected speech and audio duration;
- no pathological repeated n-gram loop;
- reasonable word-count collapse and zero-duration clusters;
- provenance and the identity of the already verified staging artifact.

Validation failure preserves the raw result for local diagnostics without selecting
it or invoking coaching.

Minimum voiced-coverage extraction needed for this gate is part of audio sealing
and transcription validation, not a user-facing metric. Acceptance is
fixture-specific: Audora must retain the labeled beginning, tail, fillers, and
repairs in its representative corpus. No ASR engine is claimed to guarantee that
every spoken word is correct.
