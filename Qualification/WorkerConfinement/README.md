# Offline transcription-worker confinement qualification

This ticket-scoped harness attacks the production restriction boundary Audora
will place around its transient transcription worker. It is independent of the
legacy app and never discovers or reads the user's home, configuration, caches,
credentials, or model directories.

The public seams are:

- `confinement.py`, which launches one fixed executable and returns only bounded
  `ScenarioResult` values; and
- the version-one JSON Lines worker handshake/request/result exchange exercised
  by `fixture_worker.c`.

The launcher builds the child environment from a fixed allowlist, maps `HOME` and
configuration/cache variables to empty job-owned directories, starts in the job
directory, and applies a deny-by-default macOS Seatbelt profile. The profile
allows system loader support, read-only runtime/model roots, and read/write job
staging; it has no network allowance and denies process creation. CPU time, open
files, regular-file output, stdout, stderr, handshake time, job time, and
termination grace are bounded. Every terminal path waits for the owned process
group to disappear.

## What the automated proof covers

The harness builds an optimized, ad-hoc-signed Hardened Runtime C fixture so the
restriction mechanism remains testable without the unavailable Crisper runtime,
model, or private audio corpus. The fixture has no transcription capability and
contains only synthetic literals.

The scenarios prove:

- exact environment construction, empty home/config, scoped current directory,
  and a version/runtime/model/patch startup handshake before work is accepted;
- synthetic cached work reads its model/input, performs a denied loopback
  connection attempt without transmitting data, and atomically installs its
  result only under job staging;
- unrelated read, unrelated write, `..` traversal, symlink escape, runtime write,
  model write, network, and child-process attacks are unavailable;
- open-file, stdout, and stderr excess plus malformed requests, malformed worker
  output, wrong/missing handshakes return normalized bounded codes; and
- cancellation, crash, and timeout terminate and reap the complete owned process
  group.

The JSON report contains codes, sizes, versions, and pass/block state only. It
contains no paths, environment values, fixture content, raw stderr, or candidate
text.

## Run

Run from a normal macOS terminal on the supported host:

```sh
./run-tests.sh
./qualify.py --output results/local.json
```

Nested `sandbox-exec` can be rejected by an outer CI or development sandbox. That
is an execution-environment block, not a passing result; rerun from an environment
that permits applying the child profile.

`sandbox-exec` and its Seatbelt profile language are Apple system-private
interfaces. The checked-in result proves the mechanism only on its recorded host;
the clean minimum macOS 15 Release baseline must still be exercised.

## Production qualification is still blocked

The synthetic restriction proof does not promote CrisperWhisper Small or claim a
real cached inference passed. The current engine lock has no compatibility patch
ID, and this repository has neither the locked Python environment nor the pinned
model snapshot. A production run must use the exact locked runtime/model, report
the real startup handshake, exercise MPS and the fixed audio corpus, and repeat the
same attacks under the supported signed Release composition. Those limits are
machine-readable in `results/2026-08-30-local.json` and summarized in
`RESULTS.md`.
