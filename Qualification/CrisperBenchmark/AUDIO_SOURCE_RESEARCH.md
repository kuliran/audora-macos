# Audio source research for the CrisperWhisper gate

Research checked 2026-09-12. The public AMI and NASA media were initially
downloaded to disposable `/private/tmp` paths solely to validate their format,
byte count, hashes, and candidate intervals. For reproducible long-fixture
preparation, the NASA MP3 was subsequently downloaded again to git-ignored local
fixture storage and converted into git-ignored WAV candidates. No source or
derived audio was committed. This document makes no claim that the earlier
disposable validation copies have since been deleted.

## Recommendation

Use two openly reusable, first-party sources:

| Fixture | Source | Planned source interval | Why |
| --- | --- | --- | --- |
| `short` | AMI meeting `ES2002a`, headset mix | `00:50.000–01:00.350` (10.350 seconds) | Native mono 16 kHz, 16-bit PCM WAV; the exact interval has a filled pause, immediate “our our” repetition, and complete tail speech. |
| `one-minute` | AMI meeting `ES2002a`, headset mix | `01:00.350–02:00.980` (60.630 seconds) | The exact interval has fillers, laughter, multi-second gaps, repetition, and the transcript's `trunc="true"` `des-` cutoff. One participant's misplaced headset also makes this meeting useful for checking genuinely quiet speech. |
| `twelve-minute` | NASA, *Houston We Have a Podcast*, Episode 22, “Astronaut Health” | `27:28–39:26` (718 seconds) | Conversational podcast speech on complete official-transcript turn boundaries. |
| `forty-five-minute` | The same NASA episode | `04:03–48:58` (2,695 seconds) | Complete turn boundaries, speech near both ends, and a 17-second final continuation window beginning at 2,678 seconds under the pinned 30-second chunk/26-second stride schedule. |

The intervals are extraction candidates, not final labels. Before marking any
fixture `ready`, listen at both boundaries, verify quiet speech, a real long
pause, and tail speech in the resulting WAV, then hand-correct the reference
against the extracted audio. The 12-minute interval being contained within the
45-minute interval is acceptable for performance qualification, but separate
spans would reduce corpus correlation if another suitably licensed long episode
is added later.

## Short and one-minute source: AMI Meeting Corpus

The [AMI Corpus overview](https://groups.inf.ed.ac.uk/ami/corpus/) describes roughly 100 hours of recorded meetings with close and far-field microphones and orthographic transcription. Its signals and transcripts are explicitly released under [CC BY 4.0](https://groups.inf.ed.ac.uk/ami/corpus/). The [official download page](https://groups.inf.ed.ac.uk/ami/download/) provides the manual annotations and audio chooser.

Use the official [`ES2002a.Mix-Headset.wav`](https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/HeadsetAudio/ES2002a.Mix-Headset.wav). The [official headset-mix index](https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/HeadsetAudio/) lists that file, and the [signal documentation](https://groups.inf.ed.ac.uk/ami/corpus/signals.shtml) says AMI audio was downsampled to 16 kHz WAV. A full download verified SHA-256 `9c76866990fcc8b84006dc32d273ad99df439090b748ebe72103bb78c3216ee7`; its header is PCM format 1, one channel, 16,000 Hz, and 16 bits per sample, so no lossy conversion is needed. The manual annotation archive SHA-256 is `b56e5babb2496b8795deeeda7e71178d7fbc9963f94276cf2a3f4b56ebbc9f9d`.

The [transcription documentation](https://groups.inf.ed.ac.uk/ami/corpus/transcription.shtml) says the word transcripts received two and sometimes three passes, are synchronized to the recordings, and preserve grammatical errors, reduced forms, cut-offs, restarts, laughter, and other vocal events. The [annotation coverage table](https://groups.inf.ed.ac.uk/ami/corpus/annotationpresent.shtml) confirms that `ES2002a` has both a manual transcript and disfluency annotations. The [known-data list](https://groups.inf.ed.ac.uk/ami/corpus/dataproblems.shtml) notes that participant 1 did not wear the headset correctly and recommends lapel audio for that participant; for this benchmark, first inspect whether the resulting quieter voice is intelligible enough to exercise the required `quiet-speech` condition. If it is not, use [`ES2002a.Mix-Lapel.wav`](https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/ES2002a/audio/ES2002a.Mix-Lapel.wav) instead.

Selection procedure for the two clips:

1. Load the manual word transcript and disfluency annotations from the official AMI download.
2. Find non-overlapping candidate windows containing the fixture's required phenomena.
3. Audition only those windows, including the leading and trailing silence, and choose boundaries on complete words.
4. Export without changing sample rate, channel count, or sample width; pin the source and derived-file SHA-256 values.
5. Preserve attribution with meeting ID, corpus URL, CC BY 4.0 link, and a notice that the recording was clipped.

Do not treat the published transcript as infallible: AMI documents a small set of known transcription errors. The fixture references still need a focused human pass.

## Long source: NASA podcast

Use NASA's direct MP3 for [Episode 22, “Astronaut Health”](https://www.nasa.gov/podcasts/houston-we-have-a-podcast/astronaut-health/):

- [Direct NASA-hosted MP3](https://www.nasa.gov/wp-content/uploads/2017/12/ep22_astronaut_health.mp3)
- [Official podcast RSS feed](https://www.nasa.gov/feeds/podcasts/houston-we-have-a-podcast)

The direct NASA MP3 download verified SHA-256 `444656d86447e832dc6f54cc17a2a152abdef6eafb8c7135d8b176def2abebde` and decodes to approximately 3,218 seconds, enough for the selected 48:58 endpoint. The episode page supplies an official, speaker-attributed transcript with utterance timestamps through the end of the conversation. It visibly retains conversational forms such as repeated words and fillers, cut-offs, `[inaudible]`, and multiple `[laughter]`/`[laughing]` events. This makes it a useful labeling seed, but it is not a word-timed benchmark reference; the extracted clips require word-level hand alignment and correction.

The extraction was reproduced with the arm64 `ffmpeg` 8.0 executable at
`/Applications/Buzz.app/Contents/Frameworks/ffmpeg`, pinned by executable
SHA-256 `c997afe238f01223e11f47f945e1599e506217bc7ed7f02b0205f21f56fb73c3`
and first version line in `public-source-plan.v1.json`. The checked-in argument
profile produced mono 16 kHz signed 16-bit PCM WAVs with these exact identities:

- `27:28–39:26`: 718,000 ms, 22,976,044 bytes, SHA-256 `e357cbf3a8568a39b897846ba8a988beb86630c7bba22deb2675e652abfa37eb`;
- `04:03–48:58`: 2,695,000 ms, 86,240,044 bytes, SHA-256 `8bef07a1cadea11f9a2505592e5ac20c46577c4868499b2d7aeb8fcfe60a08c5`.

Running the public preparer again with `--replace` reproduced both hashes. This
establishes converter/output reproducibility only; acoustic review, word-level
reference correction, and all model qualification gates remain outstanding.

NASA's [media usage guidelines](https://www.nasa.gov/nasa-brand-center/images-and-media/) state that NASA audio and other NASA content generally are not subject to copyright in the United States, permit educational or informational reuse, require source acknowledgement, prohibit implied endorsement, and warn that separately identified third-party material is not covered. The broader [NASA Brand Center guidance](https://www.nasa.gov/nasa-brand-center/) also warns that some audiovisual works contain licensed music or footage. Therefore:

- extract speech-only spans and omit intro/outro music and embedded archival clips;
- credit NASA and the episode, and do not use NASA marks or imply NASA approval;
- retain the original episode URL and transformation notice alongside derived WAVs;
- obtain project-owner/legal confirmation before distributing the derived NASA audio as part of a commercial product, especially outside the United States. Keeping a reproducible local-fetch recipe instead of vendoring the MP3 is the lowest-risk default.

## Gate status

These sources and reproduced hashes remove the candidate-audio identity blocker.
They do **not** make release qualification pass by themselves. Acoustic review,
hand-labeled references, and the full 45-minute quality/timing/performance run are
explicitly deferred until the application is otherwise ready, and each manifest
entry must remain not ready in the meantime. That deferral does not block building
the real Crisper adapter or its execution-admission work: the pinned runtime/model,
compatibility patch, confinement, real cached-offline inference, cancellation, and
candidate boundary still have to pass without a fake provider or bypass.
