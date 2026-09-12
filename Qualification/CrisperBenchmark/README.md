# CrisperWhisper Small qualification

This directory is the versioned gate-zero corpus and benchmark for the one
selected transcription candidate. It does not select a fallback engine and a
failed or blocked run does not change `engine-lock.v1.json`.

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
so cancellation qualification is intentionally blocked with
`ACTIVE_INFERENCE_PROOF_UNAVAILABLE`. A pre-call worker acknowledgement or an
apparently live process is not accepted as evidence that inference is active.

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

Podcast preparation is deliberately blocked with
`PODCAST_REPRODUCIBILITY_NOT_PINNED`. Before either NASA fixture can be
prepared, `public-source-plan.v1.json` must pin the exact `ffmpeg` executable
SHA-256, its first `-version` line, and the expected derived WAV SHA-256 for
both podcast intervals. The preparer verifies those identities before use.
`ffmpeg` was not available on the validation host, so the NASA clips were not
converted and their derived hashes remain explicitly unset. The utility never
installs a converter, and no podcast output should be treated as reproducible
until those fields have been independently reviewed and pinned.

## Running

The local corpus layout and hand-label schema are documented in
`fixtures/README.md`. After every candidate interval has been listened to and
hand-corrected, pin every derived audio/reference hash and mark each manifest
entry `ready`.

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
`preflight-only` Apple Silicon report; no inference was attempted. Its engine,
corpus, and public-source-plan hashes match the current configuration. All four corpus cases,
cancellation, and cached-offline inference are **blocked**, not passed: the
repository contains no local audio/reference assets, no reviewed reference hashes
are pinned, no prepared local model snapshot was supplied, and the locked Python
runtime and packages are not installed. Public source selection is no longer a
blocker, but the NASA converter and derived hashes remain unpinned, local
candidate audio is absent, and human-reviewed references are not
qualification-ready. The engine selection and decoding configuration were not
changed. The compatibility-patch callback needed to prove cancellation during
active model inference is also absent
(`audoraCompatibilityPatchId` is null), so cancellation remains blocked even
after the corpus, model, and runtime prerequisites are supplied.
