# Audio import qualification

This qualification is synthetic-only. It never reads a user's media, browser,
credentials, Library, or machine-local locator.

The automated macOS package suite generates short mono and stereo WAV, AAC-LC
M4A, and ALAC M4A fixtures at 8, 16, 44.1, and 48 kHz as applicable. It checks
descriptor-bound inspection and complete decode, AAC edit/priming timeline
handling through canonical WAV output, internal presentation-gap rejection,
strict channel layouts, arithmetic downmix, fixed resampling settings, signed-16
quantization, canonical WAV bytes, original-byte retention, strict candidate
reopen, no-replace Session installation, descriptor-bound capacity checks,
root-authority revalidation, and pre/post-commit faults.
Compatible mono 16 kHz signed-16 PCM WAV coverage additionally checks the
single-artifact schema-v2 path for both strict canonical input and input with
optional chunks, source/canonical fingerprint separation, unchanged external
source bytes, descriptor-copy portability, deterministic PCM/timeline identity,
legacy schema-v1 two-artifact reopen, and abandoned-staging cleanup.
Portable tests independently check typed identities, exact frame/duration math,
the inclusive 43,200,000-frame boundary, contract resources, and Application
scenarios. The contract check executes every audio-import golden and scenario
against its generated schema.

Run from the repository root on macOS 15 with Swift 6.0:

```sh
Qualification/AudioImport/run-tests.sh
```

The script writes build caches only below a fresh temporary directory. The
checked-in manifest describes generated fixture classes rather than recording
local filenames or media hashes.

To reproduce the compatible-WAV storage and import-time comparison separately:

```sh
Qualification/AudioImport/run-compatible-wav-benchmark.sh
```

The benchmark generates deterministic ten-minute PCM fixtures, performs one
warmup and five interleaved measured iterations, and reports median time plus
logical and allocated final Session bytes. Its timed region runs the production
persistence transaction: staging, source copy and fingerprint, compatibility
inspection, canonicalization, manifest publication, staged validation, atomic
install, and final reopen. Library creation, compilation, and fixture generation
are excluded. The two-artifact comparator uses those same production persistence
boundaries but retains the original and copies compatible PCM directly rather
than invoking the slower historical decoder, so the comparison does not
manufacture a decode-speed advantage.
