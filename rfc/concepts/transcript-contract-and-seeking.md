# Transcript contract and seeking

## Immutable revision

Every successful transcription creates a new revision. Changing engine, model,
language, mode, or decoding options never overwrites earlier evidence.
Selecting a newer revision never deletes the former selection. Version one keeps
every valid Transcript Revision readable; automatic age-based cleanup is backlog.

```text
TranscriptRevision
  revisionId
  sessionId
  audio fingerprint and source fingerprints
  engine provenance
  durationMs
  lines[]
  diagnostics
```

Each semantic line contains ordered words:

```text
TranscriptLine
  lineId, order, audioSourceId, timeRange, text, words[]

TranscriptWord
  wordId, ordinal, text, displayRange, timeRange?, confidence?, wordKind?

TranscriptWordKind
  lexical | filledPause | partialWord

SessionTimeRange
  startMs, endMs

LineTextRange
  startUtf8Byte, endUtf8Byte
```

All time values are integer milliseconds relative to the canonical audio timeline.
IDs are deterministic within the revision, such as `l000042` and `w001237`.
Every `SessionTimeRange` is half-open and satisfies
`0 <= startMs < endMs <= sessionDurationMs`.
Stored `order` and `ordinal` values make canonical ordering explicit and remain
useful for validation and local indexing. Every line is source-homogeneous: its
`audioSourceId` identifies one Audio Source, and every contained word inherits that
source rather than repeating it. The ID is provenance/grouping, not a speaker-role
label; a future dual-track coach projection must disclose safe source-role metadata
separately when the distinction matters. `audioSourceId` is deliberate: `audioId`
would ambiguously suggest the whole Audio Asset rather than one source within it.
Punctuation belongs to `line.text`, not
to `words[]`; it has neither a Word ID nor an independent audio span. Every Word's
half-open UTF-8 `displayRange` selects its exact text inside `line.text`; ranges are
ordered, non-overlapping, and leave punctuation and spacing between Words. This
portable mapping is canonical, while TextKit derives its native character ranges
from it. An engine-specific tag that cannot be mapped to `TranscriptWordKind`
safely remains in
engine diagnostics instead of crossing the coaching seam as an arbitrary
`asrKind` string. Non-speech evidence is represented as an Audio Event.

For coaching, Application projects every immutable Chat Session Attachment into
the concrete `CoachRequest` from
[`coach-provider.tsp`](../contracts/coach-provider.tsp). Chat storage keeps the
exact `(sessionId, transcriptRevisionId)` compound key. The provider instead sees a
stable Chat-scoped `sessionAttachmentId`, a label, and either the complete inline
projection or one fresh Provider-Attempt-local `SessionTranscriptHandle`. This is
an explicit app/provider boundary: reusing the storage schema would disclose
identity that the coach does not need. A different request shape will be introduced
only when another implemented provider actually needs one.

`ReadSessionTranscriptsRequest` accepts one or more handles. A
`ReadSessionTranscriptsResponse.complete` atomically carries every requested
complete line/word projection; `sessionUnavailable` and `contextCannotFit`
carry no transcript content. The complete projection retains only stable Word and
Audio Event IDs plus integer timings needed for evidence resolution; it omits local
Session IDs, Transcript Revision IDs, line IDs, line `order`, word `ordinal`, and Audio Source IDs. Array
order is canonical and every value remains nested under one attachment. A projected
line includes coherent text and one required `SessionTimeRange`; its projected words
retain stable Word IDs and may omit a time range when no reliable audio span exists.
The line range supplies seeking fallback.
The projection intentionally includes both `line.text` and `words[]`: the coach
reads coherent text while returned evidence uses stable Word IDs. `line.text`
includes punctuation that is absent from `words[]`; Application validates both
against the Transcript Revision's canonical UTF-8 Word-to-display ranges rather than
trying to reconstruct punctuation from Words alone.
This is provider transport, not another Transcript Revision or a new Library
entity, and raw audio, paths, confidence values, engine-specific token tags, and
unrelated Session metadata are excluded.

`ReadSessionTranscriptsResponse` is a closed union whose current branches are
`complete`, `sessionUnavailable`, and `contextCannotFit`. `complete` means
that no requested transcript content was intentionally omitted. Application owns
retry and fallback policy, and the coach never retries the tool. Either failure
branch stops the Provider Attempt and creates the ordinary UserRetryable turn
failure, with at most three affected Sessions rendered as accessible links. Audora
does not load the model merely to produce an incomplete explanation. A later
excerpt capability adds a new response branch and projection; no unused excerpt
schema exists now.

For a multi-Session Chat, Application reserves one conservative complete batch
exchange containing every on-demand attachment alongside complete eligible history.
Creation feasibility charges the configured maximum valid Profile and Memory
allowances; each turn instead admits its actual current Profile, Memory, and history
or enters Chat Capacity Failure before provider launch. Any requested subset in
an admitted Invocation therefore fits without coach-visible estimates;
`contextCannotFit` remains a fail-closed defense for qualification or state-integrity
drift rather than a normal subset-selection result.

Coach Memory may preserve conclusions and exact evidence identifiers for later
reasoning, but it is not itself transcript evidence. Application accepts a returned
pointer only when its `sessionAttachmentId` belongs to the Chat and its ordered Word
range or Audio Event exists in that attachment's canonical Transcript Revision.
This rule is identical for new and repeated pointers and does not require the
transcript to have been disclosed during the current Provider Attempt. Application
validates structure and identity, not whether the material semantically supports
the coach's claim.

`transcriptRevisionId` remains deliberately precise. Retranscription with another
engine, language, model, or settings creates another immutable Transcript Revision
even without transcript editing. If coaching later depends on another independently
revisioned evidence set, that set receives its own revision identity rather than
renaming the entire Session as a revision.

Submitted `AudioEvent` values cover only time-based acoustic or availability facts
absent from transcript words. Textual Events remain local. A coach may point to
submitted Word IDs or an Audio Event ID. It never returns arbitrary millisecond ranges:
Application resolves the pointer and derives the trusted anchor from canonical data.

Timed Words are canonical when available. Punctuation remains line-display syntax
mapped to a nearby Word for seeking; it does not become a Word merely to acquire an
anchor. `line.text` cannot hide Words that exist in the evidence stream, and the
timed-Word renderer cannot silently discard text that lacks timing.

## Lines

Stored lines are semantic units produced deterministically from ASR punctuation,
pause boundaries, and a maximum readable length. They are not the visual wrapping
of a particular window size.

Reflow, font scaling, and window resizing therefore do not alter anchors. If line
segmentation changes, it produces a derived presentation revision, not new ASR
words.

## Seeking

The transcript view uses an attributed text storage with character ranges mapped
from the canonical UTF-8 display ranges to stable Word IDs:

- clicking a timed word seeks to `timeRange.startMs`;
- clicking punctuation seeks to the nearest preceding timed Word in its line, then
  the nearest following timed Word or line start when none precedes it;
- clicking an untimed word falls back to `line.timeRange.startMs`;
- opening a word-range Evidence Reference seeks to its first timed word, or to the
  containing line start when the complete range is untimed;
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
