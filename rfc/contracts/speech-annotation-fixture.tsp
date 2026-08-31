import "@typespec/json-schema";

using TypeSpec.JsonSchema;

namespace Audora.Contracts {
  /**
   * Versioned, platform-neutral golden input and expected output for the pure
   * deterministic local speech annotator. This fixture is never provider data.
   */
  @jsonSchema
  @id("SpeechAnnotationFixture.json")
  model SpeechAnnotationFixture {
    schemaVersion: 1;
    ruleVersion: "audora-speech-annotations-v1";
    durationMs: CanonicalDurationMilliseconds;

    @minLength(1)
    @maxLength(131072)
    lineText: string;

    @minItems(1)
    @maxItems(1000000)
    words: SpeechAnnotationFixtureWord[];

    @maxItems(100000)
    audioEvents: SpeechAnnotationFixtureAudioEvent[];

    evidence: SpeechAnnotationFixtureEvidence;
    expected: SpeechAnnotationFixtureExpected;
  }

  model SpeechAnnotationFixtureWord {
    @minLength(1)
    @maxLength(1024)
    text: string;

    wordKind: TranscriptWordKind;
    timeRange?: SpeechAnnotationFixtureRange;
  }

  model SpeechAnnotationFixtureAudioEvent {
    audioEventId: TranscriptAudioEventId;
    category: AudioEventCategory;
    startMs: SpeechAnnotationFixtureOffset;
    endMs: SpeechAnnotationFixtureOffset;
  }

  model SpeechAnnotationFixtureEvidence {
    @maxItems(100000)
    observed: SpeechAnnotationFixtureRange[];

    @maxItems(100000)
    voiced: SpeechAnnotationFixtureRange[];

    @maxItems(100000)
    unavailable: SpeechAnnotationFixtureUnavailable[];
  }

  model SpeechAnnotationFixtureRange {
    startMs: SpeechAnnotationFixtureOffset;
    endMs: SpeechAnnotationFixtureOffset;
  }

  model SpeechAnnotationFixtureUnavailable {
    startMs: SpeechAnnotationFixtureOffset;
    endMs: SpeechAnnotationFixtureOffset;

    @minItems(1)
    @maxItems(2)
    reasons: UnavailableReason[];
  }

  model SpeechAnnotationFixtureExpected {
    @maxItems(100000)
    textual: SpeechAnnotationFixtureExpectedTextual[];

    @maxItems(100000)
    audio: SpeechAnnotationFixtureExpectedAudio[];
  }

  model SpeechAnnotationFixtureExpectedTextual {
    textualEventId: SpeechTextualEventId;
    category: SpeechTextualEventCategory;
    firstWordOrdinal: NonnegativeWholeNumber;
    lastWordOrdinal: NonnegativeWholeNumber;
  }

  model SpeechAnnotationFixtureExpectedAudio {
    audioEventId: TranscriptAudioEventId;
    category: AudioEventCategory;
    startMs: SpeechAnnotationFixtureOffset;
    endMs: SpeechAnnotationFixtureOffset;
  }

  enum SpeechTextualEventCategory {
    filledPause,
    partialWord,
    repetitionCandidate,
  }

  @pattern("^t[0-9]{6}$")
  scalar SpeechTextualEventId extends string;

  @minValue(0)
  @maxValue(2700000)
  scalar SpeechAnnotationFixtureOffset extends integer;
}
