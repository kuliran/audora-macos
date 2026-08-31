import "./session-audio.tsp";
import "@typespec/json-schema";

using TypeSpec.JsonSchema;

namespace Audora.Contracts {
  /** Complete immutable canonical transcription selected only after validation. */
  @jsonSchema
  @id("TranscriptRevision.json")
  union TranscriptRevision {
    legacyV1: LegacyTranscriptRevision,
    qualifiedV2: QualifiedTranscriptRevision,
  }

  model LegacyTranscriptRevision extends TranscriptRevisionBody {
    schemaVersion: 1;
    engine: LegacyTranscriptEngineProvenance;
  }

  model QualifiedTranscriptRevision extends TranscriptRevisionBody {
    schemaVersion: 2;
    engine: QualifiedTranscriptEngineProvenance;
  }

  model TranscriptRevisionBody {
    revisionId: TranscriptRevisionId;
    sessionId: SessionId;
    jobId: TranscriptionJobId;
    createdAt: UTCInstant;
    durationMs: CanonicalDurationMilliseconds;
    audioFingerprintSha256: Sha256Hex;

    @minItems(1)
    @maxItems(32)
    sourceFingerprints: TranscriptSourceFingerprint[];

    candidateArtifactSha256: Sha256Hex;

    @minItems(1)
    @maxItems(100000)
    lines: PersistedTranscriptLine[];

    @maxItems(100000)
    audioEvents: PersistedTranscriptAudioEvent[];
  }

  model TranscriptSourceFingerprint {
    audioSourceId: TranscriptAudioSourceId;
    sha256: Sha256Hex;
  }

  model LegacyTranscriptEngineProvenance {
    ...TranscriptEngineProvenanceBody;
  }

  model QualifiedTranscriptEngineProvenance {
    ...TranscriptEngineProvenanceBody;
    qualification: TranscriptEngineQualification;
  }

  model TranscriptEngineProvenanceBody {
    provider: "crisperwhisper";
    `model`: "small";

    @minLength(1)
    @maxLength(128)
    @pattern("^[0-9A-Za-z._-]+$")
    revision: string;

    language: "en";
    mode: "verbatim";
    decodingOptionsSha256: Sha256Hex;
    usePolicy: TranscriptEngineUsePolicy;
  }

  /** Exact qualified runtime identity retained with immutable derivation evidence. */
  model TranscriptEngineQualification {
    schemaVersion: 1;

    @minLength(1)
    @maxLength(128)
    @pattern("^[0-9A-Za-z._-]+$")
    qualificationProfileId: string;

    engineLockSha256: Sha256Hex;

    @minLength(1)
    @maxLength(128)
    @pattern("^[0-9A-Za-z._-]+$")
    runtimeIdentity: string;

    runtimeLockSha256: Sha256Hex;

    @minLength(1)
    @maxLength(128)
    @pattern("^[0-9A-Za-z._-]+$")
    compatibilityPatchId: string;
  }

  model PersistedTranscriptLine {
    lineId: TranscriptLineId;
    order: NonnegativeWholeNumber;
    audioSourceId: TranscriptAudioSourceId;
    timeRange: SessionTimeRange;

    @minLength(1)
    @maxLength(131072)
    text: string;

    @minItems(1)
    @maxItems(1000000)
    words: PersistedTranscriptWord[];
  }

  model PersistedTranscriptAudioEvent {
    audioEventId: TranscriptAudioEventId;
    category: AudioEventCategory;
    audioSourceId: TranscriptAudioSourceId;
    timeRange: SessionTimeRange;
  }

  model TranscriptEngineUsePolicy {
    @minLength(1)
    @maxLength(128)
    @pattern("^[0-9A-Za-z._-]+$")
    policyId: string;

    @minItems(1)
    @maxItems(1)
    coveredArtifacts: TranscriptCoveredArtifact[];

    privateLocalUseAllowed: boolean;
    privateExportAllowed: boolean;
    externalProcessingAllowed: boolean;
    publicDistributionAllowed: boolean;
    commercialUseAllowed: boolean;

    @minLength(1)
    @maxLength(512)
    licenseReference: string;

    licenseSha256: Sha256Hex;
  }

  model PersistedTranscriptWord {
    wordId: TranscriptWordId;
    ordinal: NonnegativeWholeNumber;

    @minLength(1)
    @maxLength(1024)
    text: string;

    displayRange: LineTextRange;
    timeRange?: SessionTimeRange;

    @minValue(0)
    @maxValue(1)
    confidence?: float64;

    wordKind: TranscriptWordKind;
  }

  model LineTextRange {
    @minValue(0)
    startUtf8Byte: integer;

    @minValue(0)
    endUtf8Byte: integer;
  }

  enum TranscriptCoveredArtifact {
    transcriptRevision,
  }

  enum TranscriptWordKind {
    lexical,
    filledPause,
    partialWord,
  }

  @pattern("^src-[0-9]{4}$")
  scalar TranscriptAudioSourceId extends string;

  @pattern("^l[0-9]{6}$")
  scalar TranscriptLineId extends string;

  @pattern("^w[0-9]{6}$")
  scalar TranscriptWordId extends string;

  @pattern("^a[0-9]{6}$")
  scalar TranscriptAudioEventId extends string;
}
