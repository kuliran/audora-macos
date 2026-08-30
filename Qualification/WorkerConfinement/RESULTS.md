# Worker confinement result — 2026-08-30

## Host

- Apple Silicon (`arm64`)
- macOS 26.6.2 (build 25G83; Darwin 25.6.0)
- Xcode 26.6 (build 17F113)

## Reproducible commands

```sh
cd Qualification/WorkerConfinement
./run-tests.sh
./qualify.py --output results/2026-08-30-local.json
```

## Recorded outcome

The deterministic suite passed 8 tests with 0 failures. All 19 synthetic
restriction scenarios passed. The worker reported protocol 1,
`synthetic-runtime-v1`, `synthetic-model-revision-v1`, and
`synthetic-progress-patch-v1` before accepting the request.

The run proved an exact allowlisted environment, empty job-owned home/config,
job-scoped current directory, read-only runtime/model roots, job-only writes,
cached/offline synthetic completion, and denial of unrelated read/write,
traversal, symlink escape, network, and child creation. Open-file, stdout, stderr,
malformed request/output, and handshake bounds returned normalized codes. Cancel,
crash, timeout, and handshake timeout all left the worker and its process group
reaped.

The fixture executable was optimized and ad-hoc signed with Hardened Runtime. The
report retains no local paths, environment values, raw stderr, fixture content, or
candidate text.

## Production result: blocked

This result does **not** claim real CrisperWhisper inference or engine selection.
Production qualification remains blocked for the exact reasons recorded in the
JSON artifact:

- `AUDORA_COMPATIBILITY_PATCH_UNPINNED`
- `LOCKED_RUNTIME_NOT_PROVIDED`
- `PINNED_MODEL_NOT_PROVIDED`
- `REAL_CACHED_INFERENCE_NOT_RUN`
- `MINIMUM_MACOS_15_BASELINE_NOT_RUN`

The real compatibility patch must be pinned, the exact Python/package runtime and
model snapshot supplied without inspecting a user's credential stores, and cached
MPS inference plus this attack matrix rerun from the signed Release composition on
the minimum supported macOS 15 baseline. The Apple-private `sandbox-exec` mechanism
also remains subject to baseline availability testing.
