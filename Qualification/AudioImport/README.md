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
