# Audio processing

## Version-one input contract

A Session owns exactly one Audio Asset with one transcribable canonical mono
source:

- `microphone`: captured by the native app; or
- `imported`: a mono or stereo M4A/WAV chosen by the user, copied into the
  library, and deterministically downmixed when necessary.

Domain and worker values represent the Session-owned Audio Asset as a collection
of source-tagged Audio Sources, but the version-one use case rejects zero or
multiple eligible Sources. `system` is a reserved source value for a possible
later dual-track recording that aligns the Speaker's microphone with a separately
retained system or application-audio source; it is not captured or transcribed in
version one.

## Canonical timeline

Playback, transcription, words, pauses, and annotations use the same
zero-based canonical timeline. The canonical analysis artifact is 16 kHz, mono,
signed 16-bit little-endian linear PCM WAV. Version one identifies its pipeline
as `audora-avfoundation` version 1: stereo is mixed as `(left + right) / 2` in
`Double`, sample-rate conversion uses one long-lived `AVAudioConverter` with the
normal/max-quality/normal-prime settings, and quantization multiplies by 32,768,
rounds ties away from zero, then saturates to the signed-16 range.

An eligible WAV already has that decoded representation and instead records the
identity pipeline `audora-compatible-pcm-wav` version 1. Eligibility requires a
little-endian `RIFF`/`WAVE` whose declared RIFF length covers the whole file,
exactly one 16-byte PCM format chunk with encoding tag 1, mono 16 kHz, 16 bits per
sample, block alignment 2 and byte rate 32,000, followed by exactly one nonempty,
even-sized direct `data` chunk. Chunk lengths and RIFF padding must be complete.
Every `LIST` chunk has a four-byte list type; short `LIST` payloads and extended
`fmt ` payloads bypass this deliberately narrow path.
`wavl`, `slnt`, `plst`, `smpl`, multiple data chunks, extensible/non-PCM
formats, RF64/RIFX, unsupported channels/rates/depths, and malformed layouts are
ineligible. Other
optional chunks are metadata: Audora records the selected container fingerprint
but does not copy those chunks into the canonical artifact.
Eligibility examines at most 4,096 top-level chunks with cancellation checked
between chunks. A larger inventory is not rejected as media; it bypasses this
bounded fast path and uses the ordinary decoder with byte-exact retention.

At a declared unavailable microphone discontinuity, version one may reset that
same converter instance without changing its format, settings, or pipeline
version. Before reset it completes the current 4,096-frame input batch and one
batch-rounded converter-prime window; version one qualifies both prime counts at
no more than 4,096 frames, so this bridge is at most 8,191 source frames. It then
materializes only unavailable canonical frames through
`floor(inputEnd * 16000 / inputRate)`, retaining the zero-or-one-frame difference
to the ceiling projection as ordered unavailable ownership. After reset it
pre-rolls `inputEnd mod (inputRate / gcd(inputRate, 16000))` zero source frames,
discards the floor-projected pre-roll output, and routes any surplus output
through that retained ownership before exposing later observed audio. This
bounded bridge plus absolute-phase pre-roll must be byte-equivalent after the
unavailable interval to uninterrupted conversion with zeros, while work remains
independent of the unavailable interval's duration.

The decoded canonical frame count is authoritative. Version one accepts at most
43,200,000 frames, including that exact boundary, and calculates duration as
`ceil(frameCount * 1000 / 16000)` with integer arithmetic. It does not use a
container's rounded duration to decide the final boundary.

For imports:

1. Copy the original byte-for-byte into the Session's partial audio directory.
   The external source is opened read-only and never renamed, hard-linked, or
   mutated; descriptor streaming works identically when source and Library are
   on different filesystems.
2. Open that retained copy through the Library's anchored, no-follow descriptor
   capability and inspect and decode from that same file identity; pathname
   replacement cannot redirect the decoder after validation.
3. Inspect its duration, channel count, sample format, channel layout, and
   decodeability.
4. Reject inputs longer than 45 minutes, unsupported channel layouts, and files
   with more than two channels explicitly.
5. For an eligible compatible PCM WAV, copy its direct PCM payload behind the
   strict 44-byte canonical header, or rename the already strict staged copy,
   then remove only the staged original. This stores one artifact. For all other
   input, decode and deterministically downmix once to canonical mono while
   retaining the byte-exact original.
6. Apply container edits and codec priming/trailing trims, normalize the first
   presented sample to canonical frame zero, and reject discontinuous presented
   sample buffers instead of silently compressing or extending the timeline.
7. Validate duration and readable frames.
8. Revalidate the authoritative Library root and atomically commit the Session
   with its owned Audio Asset.

The compatible path is chosen only after the full source has been copied,
fingerprinted, flushed, and parsed from its anchored staged descriptor. Until
`session.json` is installed, both a partially written canonical file and any
not-yet-removed staged original remain disposable recovery state. The persisted
schema-v2 manifest points both artifact roles at the real `audio/audio.wav`
fingerprint and stores the discarded selected-container fingerprint separately as
provenance. Schema-v1 two-artifact Sessions remain valid and are never migrated.

The storage measurement for an eligible source of `S` bytes and `F` PCM frames is
one `44 + 2F` byte artifact instead of `S + 44 + 2F`; the final saving is exactly
`S` bytes, excluding the small manifest delta. A strict canonical source takes
one staged copy plus a same-directory rename and no decode or PCM rewrite. An
eligible source with optional chunks takes one staged copy, one bounded RIFF scan,
and one PCM payload copy, while skipping AVFoundation decode, float conversion,
resampling, and requantization. The ordinary descriptor-copy acquisition is also
the portable fallback; no APFS clone or mutable hard link is part of correctness.
Capacity admission reserves the two bounded manifests for strict canonical input;
it reserves one additional canonical WAV only when PCM must be copied out of an
eligible container with optional chunks.

The reproducible ten-minute synthetic comparison in
[`Qualification/AudioImport/RESULTS.md`](../../Qualification/AudioImport/RESULTS.md)
measured both final storage and fsync-inclusive import time before selecting this
contract. The one-artifact path reduced allocated bytes by 50% for strict input
and 51% for input with a 1 MiB metadata chunk. Median strict import time fell from
86.445 ms to 63.578 ms; the conservative optional-chunk comparison fell from
82.961 ms to 64.014 ms. The timed production persistence transaction includes
staging, fingerprints, parsing, manifests, validation, install, and final reopen;
the retained-original comparator copies compatible PCM directly rather than
charging historical decoder work. These timings are diagnostic, not release
thresholds; the portable storage reduction without a measured time regression
supports the single-artifact choice.

Transcription and playback both use the canonical timeline. This avoids M4A codec
priming/edit-list offsets causing the transcript to appear ahead of playback.

For microphone recording:

1. Allocate and freeze the Session ID and wall-clock start metadata while keeping
   the acquisition non-authoritative until it seals. After microphone authorization
   and input preparation, the source samples one monotonic capture origin
   immediately before starting. Source callback/gap projection, displayed elapsed
   time, mute and Stop boundaries, warning deadlines, and the 45-minute ceiling
   all share that zero point; authorization and preparation wait do not count.
2. Write capture frames away from the real-time callback as lossless partial data.
3. Preserve callback/sample discontinuities by inserting timeline silence and
   recording a capture-gap diagnostic.
4. When muted by the user, stop accepting microphone content, preserve the elapsed
   timeline with zeros, and record a `muted` interval. Muted time is unavailable
   data, not an observed silent pause.
5. Stop callbacks, flush writers, close files, normalize, validate, and commit the
   Session with its owned Audio Asset before creating a transcription job.

Cancel during recording removes only the incomplete Session staging area after
explicit confirmation. Cancel during transcription keeps the committed Session
and its Sealed Audio.

An unexpected app, device, or capture interruption preserves recoverable recording
staging. On the next launch, Audora validates the captured frames and offers only
**Seal Recovered Recording** or **Discard**. Sealing publishes exactly one Session
and immutable canonical timeline from the recoverable evidence; it never reopens
capture or appends new frames. If the partial evidence cannot be validated and
sealed, only Discard is available.

The recording view keeps its elapsed timer visible, adds a persistent five-minute
warning at 40:00, changes to a one-minute countdown at 44:00, and automatically
stops and seals at 45:00. The transition to processing shows a persistent notice
that the duration limit caused the stop; a transient toast is not the sole
notification.

Once capture or import seals a Session's Audio Asset, Audora never resumes,
appends to, or replaces its canonical timeline. Another take creates another
Session.

## Audio evidence extraction

Evidence extraction operates on canonical mono samples outside the real-time
capture callback. It computes only the VAD/energy intervals, voiced coverage, and
quality evidence needed for transcript validation and deterministic annotations.
Version one exposes no automatic delivery scores or aggregate primitive metrics.

- No voice embedding or cross-session speaker template is created.
- Muted and capture-failed intervals are excluded rather than classified as
  silence.
- Pauses used for coaching come from the audio timeline and timed evidence, not
  punctuation alone.

Derived evidence can be recomputed. The canonical audio and immutable transcript
remain authoritative.
