# Audio import qualification results

## 2026-09-19 compatible-WAV storage decision

Command:

```sh
Qualification/AudioImport/run-compatible-wav-benchmark.sh
```

Environment: macOS 26.6.2 (25G83), arm64, Apple Swift 6.4. The deterministic
fixture is ten minutes of mono 16 kHz signed-16 PCM (19,200,000 PCM bytes). The
optional-chunk fixture adds a 1 MiB `JUNK` chunk. Results are medians of five
interleaved measured imports after one warmup. The timed transaction uses
production persistence for staging, source copy/fingerprinting, compatibility
inspection, canonicalization, manifests, staged validation, atomic installation,
and final reopen. Compilation, Library creation, and fixture generation are
outside the timed region. The retained-original comparator follows the same
production persistence boundaries and performs a conservative direct compatible
PCM copy instead of charging the old path for AVFoundation decode.

| Path | Median import ms | Final Session logical bytes | Final Session allocated bytes |
|---|---:|---:|---:|
| strict / two artifacts | 86.445 | 38,401,200 | 38,412,288 |
| strict / one artifact | 63.578 | 19,201,257 | 19,210,240 |
| optional chunks / two artifacts | 82.961 | 39,449,784 | 39,460,864 |
| optional chunks / one artifact | 64.014 | 19,201,257 | 19,210,240 |

The one-artifact choice cut strict-WAV final Session allocation by 50% and median
production persistence time by 26%. For the metadata-bearing fixture it cut
allocation by 51% and time by 23%. The comparator is deliberately conservative:
both alternatives inspect compatibility and copy PCM directly, so it does not
credit the chosen path for avoiding historical AVFoundation decode and
requantization. Timing is host and filesystem dependent and is not a release
threshold; the repeatable storage reduction with no measured import-time
regression is the decision evidence.

## 2026-08-30 implementation run

- TypeSpec 1.15 compilation and generated-schema comparison: passed using the
  repository's already-installed pinned toolchain.
- Swift 6 strict-concurrency compilation of Domain, Application, macOS
  Infrastructure, Presentation, app composition, and new test sources: passed.
- The amended persistence, scenario-runner, normalizer, and macOS infrastructure
  test sources passed direct Swift 6.3.3 strict type checking on macOS 26.6.2
  arm64. A direct short-normalizer executable produced the checked-in 8/44.1/48
  kHz frame-count, byte-count, and SHA-256 goldens. These local results do not
  qualify macOS 15 or Apple Swift 6.0; that CI lane must reproduce the hashes.
- A direct synthetic runtime smoke covering partition-invariant 8/44.1/48 kHz
  normalization plus staged install, exact original-byte retention, and reopen:
  passed. Descriptor-backed AVURLAsset inspection also passed.
- Full SwiftPM/Xcode test execution on this host: not run because package builds
  are blocked by the enclosing workspace sandbox. No sandbox bypass was used.
- AVAssetReader startup for synthetic WAV input reports a bounded AVFoundation
  failure in this host environment, so the edited-AAC canonical drain and real
  internal-discontinuity assertions are covered by the macOS CI suite rather
  than claimed as locally executed.
- The `macos-15` CI lane runs the complete `AudoraMac` package tests and Debug and
  Release app builds with Apple Swift 6.0. The Ubuntu lane remains restricted to
  portable Core and scenarios.

Only synthetic fixtures are in scope. A successful CI run is required before
release qualification is complete.
