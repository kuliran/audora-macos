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
linear PCM WAV unless benchmark evidence justifies changing the format.

For imports:

1. Copy the original byte-for-byte into the Session's partial audio directory;
   version one retains it for the life of the Session.
2. Inspect its duration, channel count, sample format, and decodeability.
3. Reject inputs longer than 45 minutes, unsupported channel layouts, and files
   with more than two channels explicitly.
4. Decode and deterministically downmix mono or stereo input once to the canonical
   mono WAV.
5. Validate duration and readable frames.
6. Atomically commit the Session with its owned Audio Asset.

Transcription and playback both use the canonical timeline. This avoids M4A codec
priming/edit-list offsets causing the transcript to appear ahead of playback.

For microphone recording:

1. Allocate and freeze the Session ID and start time before the first accepted
   frame, while keeping the acquisition non-authoritative until it seals.
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
