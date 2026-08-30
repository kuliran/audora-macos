import "./portable-library.tsp";
import "@typespec/json-schema";

using TypeSpec.JsonSchema;

namespace Audora.Contracts {
  @jsonSchema
  @id("AudioManifest.json")
  model AudioManifest {
    schemaVersion: 1;
    acquisitionKind: "imported";
    original: OriginalAudioArtifact;
    canonical: CanonicalAudioArtifact;

    @minItems(1)
    @maxItems(1)
    sources: ImportedAudioSource[];

    normalization: AudioNormalization;
  }

  @jsonSchema
  @id("SessionManifest.json")
  model SessionManifest {
    schemaVersion: 1;
    sessionId: SessionId;
    createdAt: UTCInstant;
    durationMs: CanonicalDurationMilliseconds;
    audioManifestSha256: Sha256Hex;

    @maxItems(0)
    transcriptRevisionIds: string[];
  }

  @jsonSchema
  @id("AudioNormalizationVectors.json")
  model AudioNormalizationVectors {
    schemaVersion: 1;
    stereoRule: "arithmeticMean";
    quantizerVersion: "s16-round-away-saturate-v1";
    downmixVectors: AudioDownmixVector[];
    quantizationVectors: AudioQuantizationVector[];
    frameDurationVectors: AudioFrameDurationVector[];
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

  model AudioDownmixVector {
    left: float64;
    right: float64;
    output: float64;
  }

  model AudioQuantizationVector {
    input: float64;
    output: int16;
  }

  model AudioFrameDurationVector {
    frameCount: CanonicalFrameCount;
    durationMs: CanonicalDurationMilliseconds;
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

  @pattern("^ses-[0-9]{8}T[0-9]{9}Z-[0-9A-HJKMNP-TV-Z]{4}$")
  scalar SessionId extends string;

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
}
