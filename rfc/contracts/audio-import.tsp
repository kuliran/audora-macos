import "./session-audio.tsp";
import "@typespec/json-schema";

using TypeSpec.JsonSchema;

namespace Audora.Contracts {
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
}
