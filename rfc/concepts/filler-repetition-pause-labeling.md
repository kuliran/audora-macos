# Filler, repetition, and pause labeling

## Purpose

The annotator makes speech imperfections legible without asking a generative model
to rewrite or reinterpret the transcript. It returns spans over an immutable
revision and never edits text.

The pure classifier is a Domain service. Platform audio code supplies normalized
VAD/energy evidence through `AcousticEvidencePort`; Infrastructure does not own the
word-labeling policy.

```text
TranscriptAnnotation
  = textual(TextualEvent)
  | audio(AudioEvent)

TextualEvent
  textualEventId
  transcriptRevisionId
  category
  wordRange
  confidence
  ruleVersion

AudioEvent
  audioEventId
  transcriptRevisionId
  category
  audioSourceId
  timeRange: SessionTimeRange
```

`TranscriptAnnotation` is the in-app closed union; the Domain term remains
Annotation. A Textual Event owns one ordered word range. An Audio Event owns one
Audio Source and one Session Time Range. `audioSourceId` distinguishes a source
within an Audio Asset; the more ambiguous `audioId` is not used. There is no line
anchor. Textual Events remain local because the coach evaluates the submitted
transcript itself. The coaching projection includes only `silentPause`,
`untranscribedVoicedInterval`, `muted`, `captureGap`, and acoustic-only `nonSpeech`
Audio Events; each stays nested under one Session attachment, so the provider needs
only its `audioEventId`, category, and time range. The coach points to that ID and
never invents a time range.

## Deterministic pass

Version one applies ordered local rules:

1. **Explicit fillers — high confidence.** Crisper tokens such as `[UH]`, `[UM]`,
   and `[HMM]` are labeled `filledPause`.
2. **Non-speech events — high confidence.** Bracketed events such as `[laughter]`
   remain visible and receive their own category rather than being called fillers.
3. **Partial words — high confidence when structurally valid.** A lexical fragment
   ending in an ASR cutoff marker, such as `p-`, is labeled `partialWord` after
   excluding ordinary hyphenated compounds and standalone punctuation.
4. **Immediate repetitions — medium confidence.** An identical normalized word or
   short n-gram repeated within a bounded word/time window is labeled
   `repetitionCandidate`. Emphasis remains possible, so this rule does not hide the
   words by default as aggressively as an explicit filler.
5. **Pause events.** The audio/timing analyzer creates `silentPause`,
   `untranscribedVoicedInterval`, `muted`, and `captureGap` intervals. A word
   gap is not automatically equivalent to silence.

A restart, reformulation, or self-correction is a semantic interpretation that
these deterministic rules cannot establish reliably. Version one therefore has no
deterministic restart Annotation. The coach may describe an apparent repair in a
Chat and point to its submitted word range, but that provider interpretation does
not become a local deterministic Annotation.

Do not use a broad dictionary that labels every `so`, `well`, `right`, `actually`,
or `okay` as filler. Do not call global word frequency repetition; repetition is a
local repair/event pattern.

Version-one normalization is pinned with the rule version: Unicode NFKC, English
locale-independent lowercase, and removal of surrounding punctuation while
preserving apostrophes and a terminal ASCII cutoff hyphen. Explicit ASR event kinds
win over text inference. Repetition matching considers maximal adjacent normalized
1–3-word sequences, longest first, with no intervening lexical word and no more
than 1,200 ms between occurrences. These candidates are annotations, not
deletions; corpus fixtures may tune thresholds only by publishing a new rule
version.

Annotations may overlap semantically, but the renderer uses a deterministic visual
priority: explicit non-speech/filler, partial word, then repetition candidate.
Underlying words and every category remain queryable.

## Pause decomposition

For the interval between meaningful words or phrases, retain separate evidence:

```text
between-phrase interval
  = observed silent duration
  + explicit filler duration
  + untranscribed voiced duration
  + repetition duration
```

Components are computed as disjoint interval unions on the sample timeline.
Unavailable muted/capture-gap time is removed first; timed lexical/filler/partial
coverage is removed next; remaining VAD-active time is untranscribed voiced
evidence; remaining observed VAD-inactive time is silence. A repeated word remains
lexical evidence and contributes its duration to the descriptive repetition
component only once, never again to silence.

Muted and capture-failed time is unavailable, not silence. The UI can describe a
long between-phrase interval while showing its decomposition, preventing an omitted
`um` from being misclassified as observed silence.

Distinguishing hesitation from a deliberate rhetorical or between-thought pause is
not reliable from duration alone. Version one reports the measured event and may
label interpretation as uncertain. Thought-boundary classification is backlog.

## Display

- Explicit fillers and clear partial words use a secondary-evidence style whose
  contrast is tested in every supported theme; exact opacity is a UI token, not an
  algorithm constant.
- Candidate repetitions use a distinct gentler treatment or annotation
  underline.
- One global control changes the visibility or emphasis of every annotation
  category together. Version one has no category-specific or per-word visibility
  controls.
- Selection, copy, export, seeking, and coach anchors continue to use the original
  words.
- Annotation colors and opacity meet accessibility contrast requirements and are
  not the only category signal.

## Test fixtures

Golden fixtures pair timed Word/Audio Event input with expected annotations. They
cover explicit fillers, legitimate hyphenated words, deliberate emphasis,
multiword repetitions, muted intervals, and missing timings. Separate ingestion
fixtures prove that punctuation-only ASR tokens become line display syntax rather
than Domain Words. These fixtures are platform-neutral and define the algorithm
more strongly than an implementation-language description.
