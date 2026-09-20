# CrisperWhisper Small qualification

This directory is the versioned release-qualification corpus and benchmark for the
selected transcription target. Its engine lock also pins the profile that a
separate shipping-path execution-admission smoke must use. It does not select a
fallback engine, and a failed or blocked run does not change
`engine-lock.v1.json`.

## Qualification stages

- **Execution admission** proves the exact runtime/model lock, a non-null
  compatibility patch, worker confinement, real cached-offline inference,
  cancellation/reaping, and the candidate-validation boundary. Passing this stage
  permits the real adapter to run; a fixture provider or bypass flag cannot stand
  in for it. The production worker and smoke artifact still need to be added; this
  release benchmark is not weakened into an execution-only mode.
- **Release qualification** adds the hand-reviewed corpus, the full 45-minute run,
  and all quality, timing, memory, thermal, and performance thresholds below. It
  may be completed after the rest of the app is ready, but must pass before the
  release is called qualified.

The product owner's prior testing on personal recordings selects Crisper as the
implementation target. It is not reproducible benchmark evidence, so the corpus
manifest and recorded report remain blocked until the deferred review is done.

## Pinned profile

- CrisperWhisper 2.0.0 (`v2.0.0`, commit `b109acff29f7cbd3793853b3ff5fd1158f38d081`)
- `nyralabs/CrisperWhisper2.0_small` revision
  `bcaecf0a584a1f600d8897fe6032b9e2e56429a7`; every local model file is
  SHA-256 verified before inference
- Python 3.12.14 and the hashed Apple Silicon dependency set in
  `requirements-macos-arm64.lock`
- Transformers backend, Apple MPS, float16, English verbatim output, word
  timestamps, and explicit upstream 2.0.0 long-form/decoding values

The runner takes only a local model snapshot. It sets Hugging Face and
Transformers offline modes, replaces HOME/cache directories with empty
job-scoped directories, strips the ambient environment to an allowlist, and on
macOS uses `sandbox-exec` to deny network access. The network proof targets only
an unused loopback port and transmits no data. Model preparation is deliberately
separate and is not performed by this benchmark.

## Corpus and thresholds

`corpus-manifest.v1.json` defines short, one-minute, twelve-minute, and
forty-five-minute fixtures. The two long fixtures exercise continuation-window
boundaries, and the maximum fixture includes final speech in an underfilled
window. Hand labels preserve quiet speech, fillers, immediate repetitions,
cutoffs, laughter, long pauses, beginning anchors, and tail anchors.

The manifest also pins the canonical SHA-256 and ID of
`public-source-plan.v1.json`. Each fixture repeats the plan's source ID, exact
start and duration, and candidate WAV hash as bounded provenance. Qualification
rejects any plan/manifest mismatch before inference and cannot run while any
candidate WAV hash remains unset.

The numeric gates were recorded before any local inference result was available:

- word error rate at most 20%, reference-word coverage at least 80%, and
  labeled verbatim-event recall at least 85%;
- all beginning/tail anchors retained in their respective first/last 12-word
  boundary, candidate word count within 80–120% of the reference, and no more
  than one excess repeated phrase run of any feasible length;
- at least 98% timed words, no zero-duration words, monotonic in-bounds timing,
  at least 80% hand-aligned words within 750 ms at both boundaries, no aligned
  word outside that tolerance, and no more than 1.5 seconds of tail lag;
- 100% timing recall for every hand-labeled long pause, hand-labeled 26-second
  continuation seam, and hand-labeled final underfilled 30-second window, with
  the kind-specific tolerances in `fixtures/README.md`;
- cold RTF at most 1.0, warm RTF at most 0.75, peak resident memory at most
  6 GiB, MPS driver allocation at most 4 GiB, no thermal state above `serious`,
  and recovery to `fair` within five minutes;
- a pinned compatibility-patch callback emitted from inside active model
  inference, followed by three seconds of continued inference and termination
  and reaping within five seconds without forced kill; and
- successful cached inference with network denial proved.

The values are conservative feasibility gates for a 45-minute personal workflow,
not claims of perfect transcription quality.

Reference duration must exactly equal the duration derived from the WAV frame
count and sample rate; that canonical audio duration drives timeout, word-timing,
and RTF calculations. Missing RSS or MPS allocation telemetry is a failed gate,
not a zero measurement or evidence of low memory use.

The current upstream profile has no pinned callback from inside its model call,
so execution admission and cancellation qualification are intentionally blocked
with `ACTIVE_INFERENCE_PROOF_UNAVAILABLE`. A pre-call worker acknowledgement or
an apparently live process is not accepted as evidence that inference is active.

## Public candidate audio

`public-source-plan.v1.json` pins two first-party public sources and four exact
candidate intervals:

| Fixture | Source | Interval | Duration |
| --- | --- | --- | --- |
| `short` | AMI `ES2002a` headset mix | `00:50.000–01:00.350` | 10.350 s |
| `one-minute` | AMI `ES2002a` headset mix | `01:00.350–02:00.980` | 60.630 s |
| `twelve-minute` | NASA *Astronaut Health* podcast | `27:28–39:26` | 718 s |
| `forty-five-minute` | NASA *Astronaut Health* podcast | `04:03–48:58` | 2,695 s |

The AMI excerpts retain fillers, repetition, laughter, multi-second pauses, and
a transcribed cutoff. The NASA spans start and end on complete turns; under the
pinned 30-second chunk/26-second stride schedule, the 45-minute case starts its
final continuation at 2,678 seconds and leaves a 17-second partial window. Quiet speech,
partial words, pause boundaries, and the complete word reference still require
an acoustic human review. Source hashes, transcript seeds, attribution, and
license/usage links are recorded in the plan and `AUDIO_SOURCE_RESEARCH.md`.

Prepare the native AMI candidates with Python 3.12; no converter is required:

```sh
python3.12 prepare_public_fixtures.py \
  --download \
  --fixtures short one-minute
```

The preparation command downloads only the plan's fixed HTTPS URLs into ignored
local storage, verifies byte count and SHA-256 before use, clips on exact sample
boundaries, emits derived audio hashes, and reports
`qualificationReady: false`. It refuses to overwrite an existing candidate
unless `--replace` is explicit. It never writes a reference, changes the corpus
manifest, or makes gate evidence. An optional `--report` path must be a new file
outside the source and fixture trees; reports never replace plans, media, labels,
or an earlier report.

The NASA recipe is pinned to the arm64 `ffmpeg` 8.0 executable whose SHA-256 is
`c997afe238f01223e11f47f945e1599e506217bc7ed7f02b0205f21f56fb73c3` and
whose first version line is recorded verbatim in `public-source-plan.v1.json`.
On the validation host that executable was supplied by Buzz.app at
`/Applications/Buzz.app/Contents/Frameworks/ffmpeg`; another copy is accepted
only if both pinned identity checks match. Reproduce the podcast candidates
from a clean ignored fixture directory with:

```sh
python3.12 prepare_public_fixtures.py \
  --download \
  --fixtures twelve-minute forty-five-minute \
  --ffmpeg /absolute/path/to/the-pinned/ffmpeg
```

The pinned outputs are a 718-second WAV with SHA-256
`e357cbf3a8568a39b897846ba8a988beb86630c7bba22deb2675e652abfa37eb` and a
2,695-second WAV with SHA-256
`8bef07a1cadea11f9a2505592e5ac20c46577c4868499b2d7aeb8fcfe60a08c5`.
The recipe was rerun with `--replace` and reproduced both hashes exactly. The
downloaded MP3 and derived WAVs remain git-ignored and are not vendored. These
are candidate audio files only: neither interval has a hand-reviewed word/timing
reference, so neither fixture is marked ready or counts as qualification evidence.

## Running

The local corpus layout and hand-label schema are documented in
`fixtures/README.md`. After every candidate interval has been listened to and
hand-corrected, pin every derived audio/reference hash and mark each manifest
entry `ready`. This human-labeling work and the complete 45-minute run may be
deferred until the application is otherwise ready; neither can be reported as
passed, and the application cannot be declared release-qualified, before then.

Create an isolated environment from the checked-in lock, then run:

```sh
uv venv --python 3.12.14 .qualification-venv
uv pip sync --python .qualification-venv/bin/python requirements-macos-arm64.lock
.qualification-venv/bin/python benchmark.py \
  --model-dir /absolute/path/to/the/pinned/local/model-snapshot \
  --fixtures-dir fixtures \
  --output results/local-qualified-run.json
```

The report contains measurements, pass/fail gates, package/platform identity,
input-manifest hashes, the public-source-plan ID/hash, and each fixture's bounded
source ID/interval/derived-hash provenance. It never stores candidate transcript
text, reference text, audio paths, raw worker stderr, or model/cache paths. A
non-passing run returns status 2 and remains a failed gate. Production execution
uses validated lock, manifest, and public-source-plan snapshots and copies only
fixture audio into a mode-0700 system temporary workspace, rechecking its pinned
hash before the worker can read it. Reference bytes are hash-checked once,
parsed, and kept in memory; reference text is never copied into the
crash-recovery workspace.

Run the dependency-free deterministic harness tests with:

```sh
PYTHON_BIN=python3.12 sh run-tests.sh
```

## Recorded outcome

`results/2026-09-12-local-preflight.json` is the current, explicitly
`preflight-only` Apple Silicon release-qualification report; no inference was
attempted. Its engine, corpus, and public-source-plan hashes match the current
configuration. All four corpus cases, cancellation, and cached-offline inference
are **blocked**, not passed: the AMI audio candidates are absent on the recorded
host, no reviewed reference hashes are pinned, no prepared local model snapshot
was supplied, and the locked Python runtime and packages are not installed. Both
NASA audio files were present with the pinned format, duration, and SHA-256 when
preflight was recorded, but their manifest entries remain explicitly not ready
pending the deferred acoustic review and hand-aligned references. The engine
selection and decoding configuration were not changed. Execution admission also
remains blocked because the real runtime/model are unavailable and the
compatibility-patch callback required to prove cancellation during active model
inference is absent (`audoraCompatibilityPatchId` is null). These blockers must be
resolved by the real adapter and artifacts, not by a fake provider or temporary
substitution.
