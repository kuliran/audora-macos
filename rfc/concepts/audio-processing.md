# Audio processing

## Version-one input contract

A session contains exactly one transcribable mono source:

- `microphone`: captured by the native app; or
- `imported`: a mono M4A or WAV chosen by the user and copied into the library.

Domain and worker values use a collection of source-tagged audio assets, but the
version-one use case rejects zero or multiple eligible assets. `system` is a
reserved source value and is not captured or transcribed in version one.

## Canonical timeline

Playback, transcription, words, pauses, annotations, and metrics use the same
zero-based canonical timeline. The canonical analysis artifact is 16 kHz, mono,
linear PCM WAV unless benchmark evidence justifies changing the format.

For imports:

1. Copy the original byte-for-byte into a partial audio entity directory; version
   one retains it for the life of the audio entity.
2. Inspect its duration, channel count, sample format, and decodeability.
3. Reject unsupported or multichannel input explicitly in version one.
4. Decode and normalize it once to the canonical WAV.
5. Validate duration and readable frames.
6. Atomically commit the audio entity.

Transcription and playback both use the canonical timeline. This avoids M4A codec
priming/edit-list offsets causing the transcript to appear ahead of playback.

For microphone recording:

1. Freeze the recording ID and start time before the first accepted frame.
2. Write capture frames away from the real-time callback as lossless partial data.
3. Preserve callback/sample discontinuities by inserting timeline silence and
   recording a capture-gap diagnostic.
4. When muted by the user, stop accepting microphone content, preserve the elapsed
   timeline with zeros, and record a `muted` interval. Muted time is unavailable
   data, not an observed silent pause.
5. Stop callbacks, flush writers, close files, normalize, validate, and commit the
   audio entity before creating a transcription job.

Cancel during recording removes only the uncommitted partial entity after explicit
confirmation. Cancel during transcription keeps committed audio.

## Audio analysis

Timing and delivery analysis operates on the canonical mono samples outside the
real-time capture callback. It may compute VAD/energy intervals, pace,
articulation, pitch range/direction, relative volume, variability, steadiness,
voiced coverage, and quality flags.

- No voice embedding or cross-session speaker template is created.
- Raw pitch contours and unnecessarily precise acoustic features are not sent to a
  coach.
- Muted and capture-failed intervals are excluded rather than classified as
  silence.
- Pauses used for coaching come from the audio timeline and timed evidence, not
  punctuation alone.

Derived analysis can be recomputed. The canonical audio and immutable transcript
remain the evidence.
