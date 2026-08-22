# Filler, restart, and pause labeling

## Purpose

The annotator makes speech imperfections legible without asking a generative model
to rewrite or reinterpret the transcript. It returns spans over an immutable
revision and never edits text.

The pure classifier is a Domain service. Platform audio code supplies normalized
VAD/energy evidence through `AcousticEvidencePort`; Infrastructure does not own the
word-labeling policy.

```text
Annotation
  annotationId
  revisionId
  category
  anchors[]
  confidence
  ruleVersion
```

Anchors refer to word IDs, line IDs, or timed acoustic events. Missing anchors make
only that annotation stale.

## Deterministic pass

Version one applies ordered local rules:

1. **Explicit fillers — high confidence.** Crisper tokens such as `[UH]`, `[UM]`,
   and `[HMM]` are labeled `filled_pause`.
2. **Non-speech events — high confidence.** Bracketed events such as `[laughter]`
   remain visible and receive their own category rather than being called fillers.
3. **Partial words — high confidence when structurally valid.** A lexical fragment
   ending in an ASR cutoff marker, such as `p-`, is labeled `partial_word` after
   excluding ordinary hyphenated compounds and standalone punctuation.
4. **Immediate repetitions — medium confidence.** An identical normalized word or
   short n-gram repeated within a bounded word/time window is labeled
   `repetition_candidate`. Emphasis remains possible, so this rule does not hide the
   words by default as aggressively as an explicit filler.
5. **Repair cues — medium/low confidence.** Nearby patterns such as a partial word
   followed by a replacement, or explicit cues such as `no` and `I mean`, create a
   `restart_candidate` only when timing/order constraints hold. Ordinary uses are
   not labeled from vocabulary alone.
6. **Pause events.** The audio/timing analyzer creates `silent_pause`,
   `untranscribed_voiced_interval`, `muted`, and `capture_gap` intervals. A word
   gap is not automatically equivalent to silence.

Do not use a broad dictionary that labels every `so`, `well`, `right`, `actually`,
or `okay` as filler. Do not call global word frequency repetition; repetition is a
local repair/event pattern.

Version-one normalization is pinned with the rule version: Unicode NFKC, English
locale-independent lowercase, and removal of surrounding punctuation while
preserving apostrophes and a terminal ASCII cutoff hyphen. Explicit ASR event kinds
win over text inference. Repetition matching considers maximal adjacent normalized
1–3-word sequences, longest first, with no intervening lexical word and no more
than 1,200 ms between occurrences. A partial-word restart candidate requires the
replacement to begin within three lexical words and 2,000 ms. These candidates are
annotations, not deletions; corpus fixtures may tune thresholds only by publishing
a new rule version.

Annotations may overlap semantically, but the renderer uses a deterministic visual
priority: explicit non-speech/filler, partial word, repetition candidate, then
restart candidate. Underlying words and every category remain queryable.

## Pause decomposition

For the interval between meaningful words or phrases, retain separate evidence:

```text
between-phrase interval
  = observed silent duration
  + explicit filler duration
  + untranscribed voiced duration
  + restart/repetition duration
```

Components are computed as disjoint interval unions on the sample timeline.
Unavailable muted/capture-gap time is removed first; timed lexical/filler/partial
coverage is removed next; remaining VAD-active time is untranscribed voiced
evidence; remaining observed VAD-inactive time is silence. A repeated or restart
word remains lexical evidence and contributes its duration to the descriptive
restart component only once, never again to silence.

Muted and capture-failed time is unavailable, not silence. The UI can describe a
long between-phrase interval while showing its decomposition, preventing an omitted
`um` from mechanically inflating silent-pause metrics.

Distinguishing hesitation from a deliberate rhetorical or between-thought pause is
not reliable from duration alone. Version one reports the measured event and may
label interpretation as uncertain. Thought-boundary classification is backlog.

## Display

- Explicit fillers and clear partial words use a secondary-evidence style whose
  contrast is tested in every supported theme; exact opacity is a UI token, not an
  algorithm constant.
- Candidate repetitions/restarts use a distinct gentler treatment or annotation
  underline.
- The user can disable dimming or show all evidence at full opacity.
- Selection, copy, export, seeking, and coach anchors continue to use the original
  words.
- Annotation colors and opacity meet accessibility contrast requirements and are
  not the only category signal.

## Test fixtures

Golden fixtures pair timed word/audio-event input with expected annotations. They
cover explicit fillers, legitimate hyphenated words, deliberate emphasis,
multiword repetitions, repairs, punctuation-only tokens, muted intervals, and
missing timings. These fixtures are platform-neutral and define the algorithm more
strongly than an implementation-language description.
