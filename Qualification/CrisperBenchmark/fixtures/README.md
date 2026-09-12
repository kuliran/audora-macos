# Local qualification assets

Place the four audio files and their hand-labeled reference JSON files at the
paths declared by `../corpus-manifest.v1.json`. These derived assets are
intentionally not committed. `../public-source-plan.v1.json` records the pinned
public inputs, exact candidate intervals, attribution, and usage terms; the
preparation utility writes only local audio candidates and never promotes them
to ready fixtures. The two NASA podcast candidates now have pinned converter and
derived-audio hashes, but they remain unready until their audio is reviewed and
their word/timing references are hand-aligned and hashed.

Before a qualification run, verify each candidate WAV against the derived hash
in both the public-source plan and manifest, fill only genuinely derived hashes
that are still null, pin each reviewed reference hash, and set `assetStatus` to
`ready`. If a source interval or derived hash changes, update the fixture's
`sourceProvenance` and the manifest's public-source-plan ID/hash binding together.
A reference file has this shape:

```json
{
  "schemaVersion": 1,
  "fixtureId": "short",
  "durationMs": 18420,
  "lastSpeechEndMs": 17910,
  "words": ["we", "[um]", "we", "we", "need", "to", "start"],
  "wordTimings": [
    {"startMs": 0, "endMs": 310},
    {"startMs": 480, "endMs": 690},
    {"startMs": 820, "endMs": 1040},
    {"startMs": 1080, "endMs": 1290},
    {"startMs": 1510, "endMs": 1830},
    {"startMs": 1870, "endMs": 2020},
    {"startMs": 17420, "endMs": 17910}
  ],
  "phenomena": [
    "beginning-speech",
    "filled-pause",
    "immediate-repetition",
    "long-pause",
    "tail-speech"
  ],
  "beginningAnchors": [["we", "[um]", "we"]],
  "tailAnchors": [["need", "to", "start"]],
  "verbatimEvents": [
    {"kind": "filled-pause", "startWordIndex": 1, "endWordIndex": 1},
    {"kind": "immediate-repetition", "startWordIndex": 2, "endWordIndex": 3},
    {"kind": "long-pause", "beforeWordIndex": 5, "afterWordIndex": 6}
  ]
}
```

The hand label must describe the recording that was actually captured; it is not
an edited reading script. Keep cutoffs as trailing-hyphen tokens and keep explicit
Crisper event tags such as `[um]` and `[laughter]` as individual words. Beginning
anchors must occur within the first 12 words and tail anchors within the last 12
words (or the non-overlapping half of a shorter transcript). The same positional
rule is applied to the candidate transcript; finding an anchor only in the middle
does not satisfy either boundary gate.

`words` must be a nonempty array of strings, with each item normalizing to
exactly one transcript token. `wordTimings` is a one-to-one hand alignment using
integer, monotonic, in-audio `startMs`/`endMs` pairs. Its final `endMs` must equal
`lastSpeechEndMs`; generated or evenly distributed placeholder times are not
valid hand labels.

`phenomena` must be a unique list drawn from `beginning-speech`, `tail-speech`,
`quiet-speech`, `filled-pause`, `immediate-repetition`, `partial-word`,
`laughter`, `long-pause`, `longform-boundary`, and
`final-underfilled-window`. Beginning and tail speech map to their respective
anchor lists. Every other declared or manifest-required phenomenon must have a
same-kind entry in `verbatimEvents`. Word events use inclusive
`startWordIndex`/`endWordIndex` fields. A `long-pause` instead identifies the
adjacent `beforeWordIndex`/`afterWordIndex`; the aligned gap must be at least two
seconds. A `longform-boundary` adds `boundaryMs`, which must be a pinned 26-second
continuation seam bracketed by those adjacent words. A
`final-underfilled-window` identifies its inclusive word range and exact
`windowStartMs`, the start of the final partial 30-second window; its end index
must identify the final reference word. Unknown event kinds, extra event fields,
descriptive labels without positional evidence, and misplaced anchors make the
fixture not ready.

Final-window starts follow the pinned overlapping decoder schedule, not wall-clock
30-second multiples. For audio duration `D` greater than chunk size `C`, with
stride `S`, label `windowStartMs = ceil((D - C) / S) * S`. Thus a 65-second
fixture starts its last window at 52 seconds, while the 2,695-second fixture
starts at 2,678 seconds and has 17 seconds remaining. A duration whose final
window is exactly 30 seconds is not underfilled.

Only hand-labeled continuation seams are claimed and measured. Add a
`longform-boundary` event for every decoder seam that a fixture is intended to
qualify; the benchmark does not infer that unlabeled 26-second multiples were
manually verified.

Candidate word boundaries must be within 750 ms of the hand alignment for at
least 80% of reference words, with no aligned word outside that tolerance. Every
labeled long pause, continuation seam, and final partial-window tail must pass
its dedicated timing check; these critical events cannot be hidden by aggregate
event recall. Long-pause duration may differ by at most one second, its two
boundaries by at most 750 ms, continuation seams by at most 750 ms, and the final
partial-window start/tail by at most 1.5 seconds.

Published AMI/NASA transcripts are seed material only: listen to each derived
clip, correct every word and boundary, verify the acoustic-only conditions, and
then pin the reviewed audio/reference hashes before setting `assetStatus` to
`ready`.
