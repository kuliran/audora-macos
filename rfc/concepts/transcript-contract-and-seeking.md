# Transcript contract and seeking

## Immutable revision

Every successful transcription creates a new revision. Changing engine, model,
language, mode, or decoding options never overwrites earlier evidence.

```text
TranscriptRevision
  revisionId
  sessionId
  audioId
  engine provenance
  durationMs
  lines[]
  diagnostics
```

Each semantic line contains ordered words:

```text
TranscriptLine
  lineId, order, sourceId, startMs, endMs, text, words[]

TranscriptWord
  wordId, ordinal, text, startMs?, endMs?, confidence?, asrKind?
```

All time values are integer milliseconds relative to the canonical audio timeline.
IDs are deterministic within the revision, such as `l000042` and `w001237`.

Timed words are canonical when available. Punctuation and special event tokens must
have an explicit mapping to display ranges even when they have no independent
acoustic span. `line.text` cannot hide words that exist in the evidence stream, and
the timed-word renderer cannot silently discard text that lacks timing.

## Lines

Stored lines are semantic units produced deterministically from ASR punctuation,
pause boundaries, and a maximum readable length. They are not the visual wrapping
of a particular window size.

Reflow, font scaling, and window resizing therefore do not alter anchors. If line
segmentation changes, it produces a derived presentation revision, not new ASR
words.

## Seeking

The transcript view uses an attributed text storage with character ranges mapped
to stable word IDs:

- clicking a timed word seeks to `startMs`;
- clicking untimed punctuation seeks to the nearest timed word in its line;
- clicking an untimed line falls back to `line.startMs`;
- playback time selects the active word by binary search, not a full scan per
  frame;
- seek validation clamps times to the canonical audio duration.

Word timestamps already exist for transcript integrity and pause analysis, so word
clicking adds no further model inference. It does add UI mapping tests.

## Copy and export

The canonical verbatim transcript is the default evidence export. Annotation
opacity never removes words from copy/export. A separately labeled readable view
may omit the visual emphasis of disfluencies but cannot mutate the stored revision.

Exports record revision and engine provenance when using structured JSON. Plain
text exports remain human-readable and do not include local paths. Export controls
also enforce the selected revision's `EngineUsePolicy`; the evaluation Crisper
profile may only expose uses permitted by its model/output license. Public or
commercial export is not assumed merely because Audora can serialize a transcript.
