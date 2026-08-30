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

The numeric gates were recorded before any local inference result was available:

- word error rate at most 20%, reference-word coverage at least 80%, and
  labeled verbatim-event recall at least 85%;
- all beginning/tail anchors retained, candidate word count within 80–120% of
  the reference, and no more than one excess repeated n-gram run;
- at least 98% timed words, no zero-duration words, monotonic in-bounds timing,
  and no more than 1.5 seconds of labeled tail lag;
- cold RTF at most 1.0, warm RTF at most 0.75, peak resident memory at most
  6 GiB, MPS driver allocation at most 4 GiB, no thermal state above `serious`,
  and recovery to `fair` within five minutes;
- termination and reaping within five seconds without forced kill; and
- successful cached inference with network denial proved.

The values are conservative feasibility gates for a 45-minute personal workflow,
not claims of perfect transcription quality.

## Running

The local corpus layout and hand-label schema are documented in
`fixtures/README.md`. Once the private/redistributable asset decision is made,
pin every audio/reference hash and mark each manifest entry `ready`.

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
and input-manifest hashes. It never stores candidate transcript text, reference
text, audio paths, raw worker stderr, or model/cache paths. A non-passing run
returns status 2 and remains a failed gate.

Run the dependency-free deterministic harness tests with:

```sh
PYTHON_BIN=python3.12 sh run-tests.sh
```

## Recorded outcome

`results/2026-08-30-local-preflight.json` records the available Apple Silicon
host result. All four corpus cases, cancellation, and cached-offline inference
are **blocked**, not passed: the repository has no pinned audio/reference assets,
no prepared local model snapshot was supplied, and the locked Python packages
are not installed. The engine selection and decoding configuration were not
changed. The compatibility patch required by the production worker contract is
also still absent (`audoraCompatibilityPatchId` is null), so this artifact can
qualify the direct pinned inference profile but does not by itself qualify the
future app worker integration.
