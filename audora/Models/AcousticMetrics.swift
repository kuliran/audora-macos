import Foundation

// MARK: - Local analysis input

/// A word whose timestamps use the same absolute session clock as its phrase.
struct AcousticTimedWord: Codable, Hashable, Sendable {
    let word: String
    let startTime: Double
    let endTime: Double
    let confidence: Double?

    init(word: String, startTime: Double, endTime: Double, confidence: Double? = nil) {
        self.word = word
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

struct AcousticPhraseWindow: Codable, Hashable, Sendable {
    let startTime: Double
    let endTime: Double
    let text: String?
    let words: [AcousticTimedWord]

    init(startTime: Double, endTime: Double, text: String? = nil, words: [AcousticTimedWord] = []) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.words = words
    }
}

// MARK: - Shared wire vocabulary

enum AcousticSourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case mic
    case system
}

enum AcousticSpeakerScope: String, Codable, Hashable, Sendable {
    case singleSpeaker = "single_speaker"
    case mixedChannel = "mixed_channel"
}

enum AcousticPitchDirection: String, Codable, Hashable, Sendable {
    case falling
    case level
    case rising
    case varied
    case unavailable
}

enum AcousticQualityFlag: String, Codable, CaseIterable, Hashable, Sendable {
    case emptyAudio = "empty_audio"
    case insufficientAudio = "insufficient_audio"
    case invalidWindow = "invalid_window"
    case windowClamped = "window_clamped"
    case audioDurationMismatch = "audio_duration_mismatch"
    case nonFiniteSamples = "non_finite_samples"
    case lowSignal = "low_signal"
    case lowVoicedCoverage = "low_voiced_coverage"
    case insufficientVoicedFrames = "insufficient_voiced_frames"
    case pitchUnavailable = "pitch_unavailable"
    case clippingDetected = "clipping_detected"
    case insufficientWordTiming = "insufficient_word_timing"
}

// MARK: - Detailed, local-only analysis

/// Full-resolution values intended for local persistence and UI. No waveform,
/// pitch contour, voice embedding, or other speaker representation is retained.
struct LocalAcousticWindowMetrics: Codable, Hashable, Sendable {
    let paceWpm: Double?
    let articulationRateWpm: Double?
    let rmsDbfs: Double?
    let medianPitchHz: Double?
    let pitchRangeSemitones: Double?
    let pitchDirection: AcousticPitchDirection
    let pitchSlopeSemitonesPerSecond: Double?
    let relativeVolumeDb: Double?
    let volumeVariabilityDb: Double?
    let clippingRatio: Double
    let isClipped: Bool
    let steadiness: Double?
    let voicedRatio: Double
    let wordCount: Int
    let activeSpeechDuration: Double?
    let analyzedDuration: Double
    let qualityFlags: [AcousticQualityFlag]
}

struct LocalAcousticPhraseMetrics: Codable, Hashable, Sendable {
    let startTime: Double
    let endTime: Double
    let text: String?
    let metrics: LocalAcousticWindowMetrics
}

struct LocalAcousticSourceMetrics: Codable, Hashable, Sendable {
    let source: AcousticSourceKind
    let speaker: String?
    let scope: AcousticSpeakerScope
    let overall: LocalAcousticWindowMetrics?
    let phrases: [LocalAcousticPhraseMetrics]
}

struct LocalAcousticMetrics: Codable, Hashable, Sendable {
    static let currentVersion = 1

    let version: Int
    let sources: [LocalAcousticSourceMetrics]

    init(version: Int = LocalAcousticMetrics.currentVersion, sources: [LocalAcousticSourceMetrics]) {
        self.version = version
        self.sources = sources
    }

    /// Rounded values suitable for the local loopback backend. Absolute median
    /// pitch is retained here for local UI and longitudinal on-device reports.
    func storageProjection() -> AcousticMetrics {
        AcousticMetrics(
            version: version,
            sources: sources.map { $0.storageProjection() }
        )
    }

    /// Coarser values suitable for an LLM prompt. Absolute median pitch is
    /// intentionally omitted; only pitch range and categorical direction remain.
    func aiSafeProjection() -> AcousticMetrics {
        AcousticMetrics(
            version: version,
            sources: sources.map { $0.aiSafeProjection() }
        )
    }
}

// MARK: - Backend wire contract

/// Exact versioned shape accepted by the local Convex backend.
struct AcousticMetrics: Codable, Hashable, Sendable {
    let version: Int
    let sources: [AcousticSourceMetrics]

    init(version: Int = 1, sources: [AcousticSourceMetrics]) {
        self.version = version
        self.sources = sources
    }
}

struct AcousticSourceMetrics: Codable, Hashable, Sendable {
    let source: AcousticSourceKind
    let speaker: String?
    let scope: AcousticSpeakerScope?
    let overall: AcousticOverallMetrics?
    let phrases: [AcousticPhraseMetrics]?
}

struct AcousticOverallMetrics: Codable, Hashable, Sendable {
    let paceWpm: Double?
    let articulationRateWpm: Double?
    let medianPitchHz: Double?
    let pitchRangeSemitones: Double?
    let pitchDirection: AcousticPitchDirection?
    let volumeVariabilityDb: Double?
    let steadiness: Double?
    let voicedRatio: Double?
    let qualityFlags: [String]?
}

struct AcousticPhraseMetrics: Codable, Hashable, Sendable {
    let startTime: Double
    let endTime: Double
    let text: String?
    let paceWpm: Double?
    let articulationRateWpm: Double?
    let medianPitchHz: Double?
    let pitchRangeSemitones: Double?
    let pitchDirection: AcousticPitchDirection?
    let relativeVolumeDb: Double?
    let volumeVariabilityDb: Double?
    let steadiness: Double?
    let voicedRatio: Double?
    let qualityFlags: [String]?
}

// MARK: - Privacy projections

extension LocalAcousticSourceMetrics {
    private static var maximumProjectedPhrases: Int { 200 }
    private static var maximumProjectedTextCharacters: Int { 240 }

    func storageProjection() -> AcousticSourceMetrics {
        wireProjection(isAISafe: false)
    }

    func aiSafeProjection() -> AcousticSourceMetrics {
        wireProjection(isAISafe: true)
    }

    private func wireProjection(isAISafe: Bool) -> AcousticSourceMetrics {
        AcousticSourceMetrics(
            source: source,
            speaker: speaker.map { String($0.prefix(80)) },
            // System capture may contain several remote participants or media;
            // never let a caller accidentally project it as attributable.
            scope: source == .system ? .mixedChannel : scope,
            overall: overall.map { metrics in
                AcousticOverallMetrics(
                    paceWpm: Self.project(metrics.paceWpm, step: 5, range: 0...1_000),
                    articulationRateWpm: Self.project(metrics.articulationRateWpm, step: 5, range: 0...1_000),
                    medianPitchHz: isAISafe ? nil : Self.project(metrics.medianPitchHz, step: 5, range: 0...2_000),
                    pitchRangeSemitones: Self.project(metrics.pitchRangeSemitones, step: 0.5, range: 0...72),
                    pitchDirection: metrics.pitchDirection,
                    volumeVariabilityDb: Self.project(metrics.volumeVariabilityDb, step: 0.5, range: 0...120),
                    steadiness: Self.project(metrics.steadiness, step: 0.05, range: 0...1),
                    voicedRatio: Self.project(metrics.voicedRatio, step: 0.05, range: 0...1),
                    qualityFlags: Self.projectedFlags(metrics.qualityFlags)
                )
            },
            phrases: Self.evenlySampled(
                phrases.sorted { $0.startTime < $1.startTime },
                maximumCount: Self.maximumProjectedPhrases
            )
                .map { phrase in
                    let projectedStart = Self.project(phrase.startTime, step: 0.1, range: 0...86_400) ?? 0
                    let projectedEnd = max(
                        projectedStart,
                        Self.project(phrase.endTime, step: 0.1, range: 0...86_400) ?? projectedStart
                    )
                    return AcousticPhraseMetrics(
                        startTime: projectedStart,
                        endTime: projectedEnd,
                        text: Self.truncatedText(phrase.text),
                        paceWpm: Self.project(phrase.metrics.paceWpm, step: 5, range: 0...1_000),
                        articulationRateWpm: Self.project(phrase.metrics.articulationRateWpm, step: 5, range: 0...1_000),
                        medianPitchHz: isAISafe ? nil : Self.project(phrase.metrics.medianPitchHz, step: 5, range: 0...2_000),
                        pitchRangeSemitones: Self.project(phrase.metrics.pitchRangeSemitones, step: 0.5, range: 0...72),
                        pitchDirection: phrase.metrics.pitchDirection,
                        relativeVolumeDb: Self.project(phrase.metrics.relativeVolumeDb, step: 1, range: -120...120),
                        volumeVariabilityDb: Self.project(phrase.metrics.volumeVariabilityDb, step: 0.5, range: 0...120),
                        steadiness: Self.project(phrase.metrics.steadiness, step: 0.05, range: 0...1),
                        voicedRatio: Self.project(phrase.metrics.voicedRatio, step: 0.05, range: 0...1),
                        qualityFlags: Self.projectedFlags(phrase.metrics.qualityFlags)
                    )
                }
        )
    }

    private static func projectedFlags(_ flags: [AcousticQualityFlag]) -> [String]? {
        let values = flags.map(\.rawValue).sorted()
        return values.isEmpty ? nil : values
    }

    /// Keeps coverage across the complete session while bounding Convex document
    /// size. The full local analysis remains untouched.
    private static func evenlySampled<T>(_ values: [T], maximumCount: Int) -> [T] {
        guard maximumCount > 0, values.count > maximumCount else { return values }
        guard maximumCount > 1 else { return Array(values.prefix(1)) }
        let scale = Double(values.count - 1) / Double(maximumCount - 1)
        return (0..<maximumCount).map { projectedIndex in
            values[Int((Double(projectedIndex) * scale).rounded())]
        }
    }

    private static func truncatedText(_ text: String?) -> String? {
        guard let text else { return nil }
        if text.count <= maximumProjectedTextCharacters { return text }
        return String(text.prefix(maximumProjectedTextCharacters))
    }

    private static func round(_ value: Double, to step: Double) -> Double {
        guard value.isFinite, step > 0 else { return value }
        return (value / step).rounded() * step
    }

    private static func project(
        _ value: Double?,
        step: Double,
        range: ClosedRange<Double>
    ) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(range.upperBound, max(range.lowerBound, round(value, to: step)))
    }
}
