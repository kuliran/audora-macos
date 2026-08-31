import "./portable-library.tsp";
import "@typespec/json-schema";

using TypeSpec.JsonSchema;

namespace Audora.Contracts {
  /** Closed union of every persisted Session audio-manifest variant. */
  @jsonSchema
  @id("AudioManifest.json")
  union AudioManifest {
    imported: ImportedAudioManifest,
    microphone: MicrophoneAudioManifest,
  }

  /** Closed union of every persisted Session aggregate-manifest variant. */
  @jsonSchema
  @id("SessionManifest.json")
  union SessionManifest {
    imported: ImportedSessionManifest,
    recorded: RecordedSessionManifest,
  }

  /** Audio imported from a user-selected portable source file. */
  model ImportedAudioManifest {
    schemaVersion: 1;
    acquisitionKind: "imported";
    original: OriginalAudioArtifact;
    canonical: CanonicalAudioArtifact;

    @minItems(1)
    @maxItems(1)
    sources: ImportedAudioSource[];

    normalization: AudioNormalization;
  }

  /** Session-owned canonical microphone Audio Asset metadata. */
  model MicrophoneAudioManifest {
    schemaVersion: 1;
    sourceKind: "microphone";
    canonicalAudioPath: "audio/audio.wav";
    canonicalFormat: CanonicalAudioFormat;
    frameCount: PositiveRecordingFrameCount;
    canonicalSha256: Sha256Hex;

    @maxItems(8192)
    unavailableIntervals: UnavailableInterval[];
  }

  /** Aggregate commit marker for an imported Session. */
  model ImportedSessionManifest {
    schemaVersion: 1;
    sessionId: SessionId;
    createdAt: UTCInstant;
    durationMs: CanonicalDurationMilliseconds;
    audioManifestSha256: Sha256Hex;

    @maxItems(0)
    transcriptRevisionIds: string[];
  }

  /** Aggregate commit marker for a microphone-recorded Session. */
  model RecordedSessionManifest {
    schemaVersion: 1;
    sessionId: SessionId;
    createdAt: UTCInstant;
    audioManifestPath: "audio/audio.json";
  }

  union OriginalAudioArtifact {
    wav: WAVOriginalAudioArtifact,
    aac: AACOriginalAudioArtifact,
    alac: ALACOriginalAudioArtifact,
  }

  model CanonicalAudioArtifact {
    relativePath: "audio/audio.wav";
    byteCount: PositiveByteCount;
    sha256: Sha256Hex;
    frameCount: CanonicalFrameCount;
    durationMs: CanonicalDurationMilliseconds;
    container: "wav";
    encoding: "pcmS16LE";
    sampleRateHz: 16000;
    channelCount: 1;
    bitsPerSample: 16;
  }

  model ImportedAudioSource {
    audioSourceId: AudioSourceId;
    role: "microphone";
    timelineOffsetMs: 0;
  }

  model AudioNormalization {
    algorithmId: "audora-avfoundation";
    algorithmVersion: 1;
    stereoRule: "arithmeticMean";
    resamplerVersion: "av-audio-converter-normal-max-normal-prime-v1";
    quantizerVersion: "s16-round-away-saturate-v1";
  }

  model CanonicalAudioFormat {
    sampleRateHz: 16000;
    channelCount: 1;
    encoding: "pcmS16LE";
  }

  model UnavailableInterval {
    startFrame: RecordingFrameOffset;
    endFrame: PositiveRecordingFrameCount;

    @minItems(1)
    @maxItems(2)
    reasons: UnavailableReason[];
  }

  model WAVOriginalAudioArtifact extends OriginalAudioArtifactBase {
    relativePath: "audio/original.wav";
    container: "wav";
    decodedCodec: "linearPCM";
  }

  model AACOriginalAudioArtifact extends OriginalAudioArtifactBase {
    relativePath: "audio/original.m4a";
    container: "m4a";
    decodedCodec: "aacLC";
  }

  model ALACOriginalAudioArtifact extends OriginalAudioArtifactBase {
    relativePath: "audio/original.m4a";
    container: "m4a";
    decodedCodec: "alac";
  }

  model OriginalAudioArtifactBase {
    byteCount: PositiveByteCount;
    sha256: Sha256Hex;

    @minValue(8000)
    @maxValue(192000)
    sourceSampleRateHz: integer;

    @minValue(1)
    @maxValue(2)
    sourceChannelCount: integer;
  }

  @pattern("^src-0001$")
  scalar AudioSourceId extends string;

  @minValue(1)
  scalar PositiveByteCount extends integer;

  @minValue(1)
  @maxValue(43200000)
  scalar CanonicalFrameCount extends integer;

  @minValue(1)
  @maxValue(2700000)
  scalar CanonicalDurationMilliseconds extends integer;

  @minValue(1)
  @maxValue(43200000)
  scalar PositiveRecordingFrameCount extends integer;

  @minValue(0)
  @maxValue(43200000)
  scalar RecordingFrameOffset extends integer;

  enum UnavailableReason {
    muted,
    captureGap,
  }
}
