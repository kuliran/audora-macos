# Audio import qualification results

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
