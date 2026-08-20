import Foundation

/// Dependency-free, deterministic acoustic analysis for already-converted
/// 16 kHz mono floating-point audio. Call from a worker task, never a Core Audio
/// realtime callback: pitch tracking is intentionally CPU-bound.
struct AcousticMetricsCalculator: Sendable {
    static let requiredSampleRate = 16_000

    struct Configuration: Hashable, Sendable {
        var frameDuration: Double = 0.040
        var frameHop: Double = 0.020
        var minimumPitchHz: Double = 55
        var maximumPitchHz: Double = 400
        var yinThreshold: Double = 0.15
        var minimumPitchConfidence: Double = 0.72
        var minimumVoicedLevelDbfs: Double = -50
        var minimumAnalysisDuration: Double = 0.25
        var minimumVoicedFrames: Int = 4
        var lowVoicedRatio: Double = 0.12
        var clippingAmplitude: Float = 0.99
        var clippingRatioThreshold: Double = 0.001
        var pitchDirectionChangeSemitones: Double = 1.0
        var variedPitchResidualSemitones: Double = 1.5

        static let `default` = Configuration()
    }

    enum AnalysisError: Error, Equatable, Sendable {
        case unsupportedSampleRate(expected: Int, actual: Int)
    }

    let configuration: Configuration

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Analyzes a complete source buffer and all phrase windows against its
    /// absolute session timeline. This produces the most accurate overall result.
    func analyze(
        samples: [Float],
        sampleRate: Int = AcousticMetricsCalculator.requiredSampleRate,
        source: AcousticSourceKind,
        scope: AcousticSpeakerScope,
        speaker: String? = nil,
        phrases: [AcousticPhraseWindow]
    ) throws -> LocalAcousticSourceMetrics {
        try validate(sampleRate: sampleRate)

        let duration = Double(samples.count) / Double(sampleRate)
        let orderedWindows = phrases.sorted { $0.startTime < $1.startTime }
        let allWords = orderedWindows.flatMap(\.words)
        let combinedText = orderedWindows.compactMap(\.text).joined(separator: " ")
        let overall = calculateWindow(
            samples: samples,
            startTime: 0,
            endTime: duration,
            text: combinedText,
            words: allWords,
            declaredDuration: duration
        )

        var analyzedPhrases = orderedWindows.map { window -> LocalAcousticPhraseMetrics in
            guard window.endTime > window.startTime, duration > 0 else {
                return invalidPhrase(window)
            }

            let clampedStart = max(0, min(duration, window.startTime))
            let clampedEnd = max(clampedStart, min(duration, window.endTime))
            let startIndex = max(0, min(samples.count, Int((clampedStart * Double(sampleRate)).rounded(.down))))
            let endIndex = max(startIndex, min(samples.count, Int((clampedEnd * Double(sampleRate)).rounded(.up))))
            let slice = Array(samples[startIndex..<endIndex])
            var phrase = analyzePhraseUnchecked(
                samples: slice,
                startTime: window.startTime,
                endTime: window.endTime,
                text: window.text,
                words: window.words
            )

            if clampedStart != window.startTime || clampedEnd != window.endTime {
                phrase = phrase.addingQualityFlag(.windowClamped)
            }
            return phrase
        }

        analyzedPhrases = applyingRelativeVolume(to: analyzedPhrases, referenceDbfs: overall.rmsDbfs)

        return LocalAcousticSourceMetrics(
            source: source,
            speaker: speaker,
            scope: scope,
            overall: overall,
            phrases: analyzedPhrases
        )
    }

    /// Analyzes one phrase-sized buffer. `samples` must contain the audio between
    /// `startTime` and `endTime`; timestamps themselves remain on the session clock.
    func analyzePhrase(
        samples: [Float],
        startTime: Double,
        endTime: Double,
        text: String? = nil,
        words: [AcousticTimedWord] = [],
        sampleRate: Int = AcousticMetricsCalculator.requiredSampleRate
    ) throws -> LocalAcousticPhraseMetrics {
        try validate(sampleRate: sampleRate)
        return analyzePhraseUnchecked(
            samples: samples,
            startTime: startTime,
            endTime: endTime,
            text: text,
            words: words
        )
    }

    /// Builds a source from independently analyzed phrases. Overall speech-rate
    /// values are exact; acoustic values are voiced-frame-weighted summaries.
    /// Prefer `analyze(samples:...)` when the complete source buffer is available.
    func aggregate(
        source: AcousticSourceKind,
        scope: AcousticSpeakerScope,
        speaker: String? = nil,
        phrases: [LocalAcousticPhraseMetrics]
    ) -> LocalAcousticSourceMetrics {
        let ordered = phrases.sorted { $0.startTime < $1.startTime }
        guard !ordered.isEmpty else {
            return LocalAcousticSourceMetrics(
                source: source,
                speaker: speaker,
                scope: scope,
                overall: nil,
                phrases: []
            )
        }

        let referenceDbfs = combinedDbfs(
            ordered.compactMap { phrase in
                phrase.metrics.rmsDbfs.map { ($0, max(phrase.metrics.analyzedDuration, 0.001)) }
            }
        )
        let relativePhrases = applyingRelativeVolume(to: ordered, referenceDbfs: referenceDbfs)
        let overall = aggregateMetrics(relativePhrases)

        return LocalAcousticSourceMetrics(
            source: source,
            speaker: speaker,
            scope: scope,
            overall: overall,
            phrases: relativePhrases
        )
    }

    /// Appends a newly analyzed take to metrics already stored for the same
    /// meeting. Phrase timestamps are expected to share the rendered recording
    /// timeline; aggregation then recomputes relative volume and overall values
    /// across the complete meeting instead of replacing the prior take.
    func merging(
        existing: LocalAcousticMetrics?,
        appending newer: LocalAcousticMetrics?
    ) -> LocalAcousticMetrics? {
        guard let newer else { return existing }
        guard let existing else { return newer }

        let existingBySource = Dictionary(
            existing.sources.map { ($0.source, $0) },
            uniquingKeysWith: { _, last in last }
        )
        let newerBySource = Dictionary(
            newer.sources.map { ($0.source, $0) },
            uniquingKeysWith: { _, last in last }
        )
        let orderedKinds = AcousticSourceKind.allCases.filter {
            existingBySource[$0] != nil || newerBySource[$0] != nil
        }

        let mergedSources = orderedKinds.compactMap { kind -> LocalAcousticSourceMetrics? in
            switch (existingBySource[kind], newerBySource[kind]) {
            case let (old?, new?):
                let phrases = (old.phrases + new.phrases).sorted {
                    if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
                    return $0.startTime < $1.startTime
                }
                guard !phrases.isEmpty else { return new }
                return aggregate(
                    source: kind,
                    scope: kind == .system ? .mixedChannel : new.scope,
                    speaker: new.speaker ?? old.speaker,
                    phrases: phrases
                )
            case let (old?, nil):
                return old
            case let (nil, new?):
                return new
            case (nil, nil):
                return nil
            }
        }

        return LocalAcousticMetrics(
            version: max(existing.version, newer.version),
            sources: mergedSources
        )
    }

    // MARK: Speech-rate helpers

    static func deliveryWpm(wordCount: Int, elapsedSeconds: Double) -> Double? {
        guard wordCount > 0, elapsedSeconds > 0, elapsedSeconds.isFinite else { return nil }
        return Double(wordCount) * 60 / elapsedSeconds
    }

    static func articulationRateWpm(wordCount: Int, activeSpeechSeconds: Double) -> Double? {
        guard wordCount > 0, activeSpeechSeconds > 0, activeSpeechSeconds.isFinite else { return nil }
        return Double(wordCount) * 60 / activeSpeechSeconds
    }

    static func rmsDbfs(samples: [Float]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sumSquares = samples.reduce(0.0) { partial, sample in
            guard sample.isFinite else { return partial }
            return partial + Double(sample * sample)
        }
        return dbfs(sqrt(sumSquares / Double(samples.count)))
    }

    /// Cadence regularity in 0...1, defined as one minus the median absolute
    /// deviation of consecutive word-onset intervals divided by their median.
    /// This describes regularity, not quality; at least four timed words are needed.
    static func deliverySteadiness(words: [AcousticTimedWord]) -> Double? {
        let starts = words
            .filter { $0.startTime.isFinite && $0.endTime > $0.startTime && isLexicalWord($0.word) }
            .map(\.startTime)
            .sorted()
        guard starts.count >= 4 else { return nil }

        let intervals = zip(starts.dropFirst(), starts).map(-).filter { $0 >= 0.06 && $0 <= 3.0 }
        guard intervals.count >= 3, let intervalMedian = percentile(intervals, 0.5), intervalMedian > 0 else {
            return nil
        }
        let deviations = intervals.map { abs($0 - intervalMedian) }
        guard let mad = percentile(deviations, 0.5) else { return nil }
        return max(0, min(1, 1 - (mad / intervalMedian)))
    }

    // MARK: Window analysis

    private func analyzePhraseUnchecked(
        samples: [Float],
        startTime: Double,
        endTime: Double,
        text: String?,
        words: [AcousticTimedWord]
    ) -> LocalAcousticPhraseMetrics {
        guard startTime.isFinite, endTime.isFinite, endTime > startTime else {
            return invalidPhrase(AcousticPhraseWindow(startTime: startTime, endTime: endTime, text: text, words: words))
        }

        let metrics = calculateWindow(
            samples: samples,
            startTime: startTime,
            endTime: endTime,
            text: text ?? "",
            words: words,
            declaredDuration: endTime - startTime
        )
        return LocalAcousticPhraseMetrics(startTime: startTime, endTime: endTime, text: text, metrics: metrics)
    }

    private func calculateWindow(
        samples: [Float],
        startTime: Double,
        endTime: Double,
        text: String,
        words: [AcousticTimedWord],
        declaredDuration: Double
    ) -> LocalAcousticWindowMetrics {
        let cleanSamples = samples.map { $0.isFinite ? max(-1, min(1, $0)) : 0 }
        let nonFiniteCount = samples.reduce(into: 0) { count, sample in
            if !sample.isFinite { count += 1 }
        }
        let analyzedDuration = Double(cleanSamples.count) / Double(Self.requiredSampleRate)
        let wordCount = words.isEmpty ? Self.wordCount(in: text) : words.filter { Self.isLexicalWord($0.word) }.count
        let activeDuration = Self.activeSpeechDuration(words: words, lowerBound: startTime, upperBound: endTime)
        let elapsed = declaredDuration > 0 ? declaredDuration : analyzedDuration

        let sumSquares = cleanSamples.reduce(0.0) { $0 + Double($1 * $1) }
        let rms = cleanSamples.isEmpty ? nil : sqrt(sumSquares / Double(cleanSamples.count))
        let rmsDbfs = rms.flatMap(Self.dbfs)
        let clippedCount = cleanSamples.reduce(into: 0) { count, sample in
            if abs(sample) >= configuration.clippingAmplitude { count += 1 }
        }
        let clippingRatio = cleanSamples.isEmpty ? 0 : Double(clippedCount) / Double(cleanSamples.count)
        let isClipped = clippingRatio >= configuration.clippingRatioThreshold

        let frames = frameFeatures(cleanSamples)
        let pitchedFrames = frames.filter { $0.pitchHz != nil }
        let pitchValues = pitchedFrames.compactMap(\.pitchHz)
        let voicedRatio = frames.isEmpty ? 0 : Double(pitchedFrames.count) / Double(frames.count)
        let medianPitch = Self.percentile(pitchValues, 0.5)
        let pitchLow = Self.percentile(pitchValues, 0.1)
        let pitchHigh = Self.percentile(pitchValues, 0.9)
        let pitchRange = Self.semitoneDistance(low: pitchLow, high: pitchHigh)
        let direction = pitchDirection(frames: pitchedFrames, medianPitchHz: medianPitch)
        let activeLevels = frames.filter(\.isEnergyActive).map(\.rmsDbfs)
        let volumeVariability = Self.standardDeviation(activeLevels)

        var flags: [AcousticQualityFlag] = []
        if cleanSamples.isEmpty { flags.append(.emptyAudio) }
        if analyzedDuration < configuration.minimumAnalysisDuration { flags.append(.insufficientAudio) }
        if abs(analyzedDuration - declaredDuration) > max(0.12, declaredDuration * 0.1) {
            flags.append(.audioDurationMismatch)
        }
        if nonFiniteCount > 0 { flags.append(.nonFiniteSamples) }
        if rmsDbfs == nil || (rmsDbfs ?? -.infinity) < configuration.minimumVoicedLevelDbfs {
            flags.append(.lowSignal)
        }
        if voicedRatio < configuration.lowVoicedRatio { flags.append(.lowVoicedCoverage) }
        if pitchedFrames.count < configuration.minimumVoicedFrames { flags.append(.insufficientVoicedFrames) }
        if medianPitch == nil { flags.append(.pitchUnavailable) }
        if isClipped { flags.append(.clippingDetected) }
        if !words.isEmpty && Self.deliverySteadiness(words: words) == nil {
            flags.append(.insufficientWordTiming)
        }

        return LocalAcousticWindowMetrics(
            paceWpm: Self.deliveryWpm(wordCount: wordCount, elapsedSeconds: elapsed),
            articulationRateWpm: activeDuration.flatMap { Self.articulationRateWpm(wordCount: wordCount, activeSpeechSeconds: $0) },
            rmsDbfs: rmsDbfs,
            medianPitchHz: medianPitch,
            pitchRangeSemitones: pitchRange,
            pitchDirection: direction.direction,
            pitchSlopeSemitonesPerSecond: direction.slope,
            relativeVolumeDb: nil,
            volumeVariabilityDb: volumeVariability,
            clippingRatio: clippingRatio,
            isClipped: isClipped,
            steadiness: Self.deliverySteadiness(words: words),
            voicedRatio: voicedRatio,
            wordCount: wordCount,
            activeSpeechDuration: activeDuration,
            analyzedDuration: analyzedDuration,
            qualityFlags: Array(Set(flags)).sorted { $0.rawValue < $1.rawValue }
        )
    }

    // MARK: Frame-level acoustic features

    private struct FrameFeature: Sendable {
        let time: Double
        let rmsDbfs: Double
        let isEnergyActive: Bool
        let pitchHz: Double?
    }

    private func frameFeatures(_ samples: [Float]) -> [FrameFeature] {
        let frameLength = max(1, Int(configuration.frameDuration * Double(Self.requiredSampleRate)))
        let hopLength = max(1, Int(configuration.frameHop * Double(Self.requiredSampleRate)))
        guard samples.count >= frameLength else { return [] }

        var features: [FrameFeature] = []
        features.reserveCapacity(1 + (samples.count - frameLength) / hopLength)
        var start = 0
        while start + frameLength <= samples.count {
            let frame = Array(samples[start..<(start + frameLength)])
            let meanSquare = frame.reduce(0.0) { $0 + Double($1 * $1) } / Double(frame.count)
            let level = Self.dbfs(sqrt(meanSquare)) ?? -120
            let active = level >= configuration.minimumVoicedLevelDbfs
            let pitch = active ? estimatePitch(frame) : nil
            features.append(
                FrameFeature(
                    time: (Double(start) + Double(frameLength) / 2) / Double(Self.requiredSampleRate),
                    rmsDbfs: level,
                    isEnergyActive: active,
                    pitchHz: pitch
                )
            )
            start += hopLength
        }
        return features
    }

    /// YIN on a 4 kHz anti-aliased-by-averaging signal. The target range ends at
    /// 400 Hz, so this preserves the fundamental while reducing offline CPU cost.
    private func estimatePitch(_ frame: [Float]) -> Double? {
        let downsampleFactor = 4
        let downsampledCount = frame.count / downsampleFactor
        guard downsampledCount >= 32 else { return nil }

        var signal = [Double](repeating: 0, count: downsampledCount)
        for index in 0..<downsampledCount {
            let base = index * downsampleFactor
            signal[index] = (0..<downsampleFactor).reduce(0.0) { partial, offset in
                partial + Double(frame[base + offset])
            } / Double(downsampleFactor)
        }
        let mean = signal.reduce(0, +) / Double(signal.count)
        for index in signal.indices { signal[index] -= mean }

        let downsampledRate = Double(Self.requiredSampleRate / downsampleFactor)
        let minimumLag = max(2, Int(downsampledRate / configuration.maximumPitchHz))
        let maximumLag = min(signal.count - 2, Int(downsampledRate / configuration.minimumPitchHz))
        guard maximumLag > minimumLag else { return nil }

        var difference = [Double](repeating: 0, count: maximumLag + 1)
        for lag in 1...maximumLag {
            var sum = 0.0
            let upper = signal.count - lag
            for index in 0..<upper {
                let delta = signal[index] - signal[index + lag]
                sum += delta * delta
            }
            difference[lag] = sum
        }

        var cumulative = 0.0
        var normalized = [Double](repeating: 1, count: maximumLag + 1)
        for lag in 1...maximumLag {
            cumulative += difference[lag]
            normalized[lag] = cumulative > 0 ? difference[lag] * Double(lag) / cumulative : 1
        }

        var candidate: Int?
        var lag = minimumLag
        while lag <= maximumLag {
            if normalized[lag] < configuration.yinThreshold {
                while lag + 1 <= maximumLag, normalized[lag + 1] < normalized[lag] { lag += 1 }
                candidate = lag
                break
            }
            lag += 1
        }
        if candidate == nil {
            candidate = (minimumLag...maximumLag).min { normalized[$0] < normalized[$1] }
        }
        guard let bestLag = candidate else { return nil }
        let confidence = 1 - normalized[bestLag]
        guard confidence >= configuration.minimumPitchConfidence else { return nil }

        var refinedLag = Double(bestLag)
        if bestLag > minimumLag, bestLag < maximumLag {
            let left = normalized[bestLag - 1]
            let center = normalized[bestLag]
            let right = normalized[bestLag + 1]
            let denominator = left - 2 * center + right
            if abs(denominator) > 1e-12 {
                refinedLag += 0.5 * (left - right) / denominator
            }
        }
        guard refinedLag > 0 else { return nil }
        let frequency = downsampledRate / refinedLag
        return (configuration.minimumPitchHz...configuration.maximumPitchHz).contains(frequency) ? frequency : nil
    }

    private func pitchDirection(
        frames: [FrameFeature],
        medianPitchHz: Double?
    ) -> (direction: AcousticPitchDirection, slope: Double?) {
        guard frames.count >= configuration.minimumVoicedFrames,
              let medianPitchHz,
              medianPitchHz > 0 else {
            return (.unavailable, nil)
        }

        let points = frames.compactMap { frame -> (Double, Double)? in
            guard let pitch = frame.pitchHz, pitch > 0 else { return nil }
            return (frame.time, 12 * log2(pitch / medianPitchHz))
        }
        guard let first = points.first, let last = points.last, last.0 > first.0 else {
            return (.unavailable, nil)
        }

        let meanTime = points.map(\.0).reduce(0, +) / Double(points.count)
        let meanPitch = points.map(\.1).reduce(0, +) / Double(points.count)
        let numerator = points.reduce(0.0) { $0 + ($1.0 - meanTime) * ($1.1 - meanPitch) }
        let denominator = points.reduce(0.0) { $0 + pow($1.0 - meanTime, 2) }
        guard denominator > 0 else { return (.unavailable, nil) }
        let slope = numerator / denominator
        let residuals = points.map { abs($0.1 - (meanPitch + slope * ($0.0 - meanTime))) }
        let residual = Self.percentile(residuals, 0.5) ?? 0
        if residual >= configuration.variedPitchResidualSemitones {
            return (.varied, slope)
        }

        let modeledChange = slope * (last.0 - first.0)
        if modeledChange >= configuration.pitchDirectionChangeSemitones { return (.rising, slope) }
        if modeledChange <= -configuration.pitchDirectionChangeSemitones { return (.falling, slope) }
        return (.level, slope)
    }

    // MARK: Aggregation

    private func aggregateMetrics(_ phrases: [LocalAcousticPhraseMetrics]) -> LocalAcousticWindowMetrics {
        let metrics = phrases.map(\.metrics)
        let start = phrases.map(\.startTime).min() ?? 0
        let end = phrases.map(\.endTime).max() ?? start
        let wordCount = metrics.reduce(0) { $0 + $1.wordCount }
        let activeDuration = metrics.compactMap(\.activeSpeechDuration).reduce(0, +)
        let duration = metrics.reduce(0) { $0 + $1.analyzedDuration }
        let weights = metrics.map { max(Double($0.wordCount), 1) }

        let pitch = weightedMedian(
            zip(metrics, weights).compactMap { metric, weight in
                metric.medianPitchHz.map { ($0, weight) }
            }
        )
        let pitchRange = weightedMetric(metrics, weights: weights, keyPath: \.pitchRangeSemitones)
        let variability = weightedMetric(metrics, weights: weights, keyPath: \.volumeVariabilityDb)
        let steadiness = weightedMetric(metrics, weights: weights, keyPath: \.steadiness)
        let voiced = duration > 0
            ? metrics.reduce(0) { $0 + $1.voicedRatio * $1.analyzedDuration } / duration
            : 0
        let clippingRatio = duration > 0
            ? metrics.reduce(0) { $0 + $1.clippingRatio * $1.analyzedDuration } / duration
            : 0
        let flags = Array(Set(metrics.flatMap(\.qualityFlags))).sorted { $0.rawValue < $1.rawValue }
        let directions = Set(metrics.map(\.pitchDirection).filter { $0 != .unavailable })
        let direction: AcousticPitchDirection = directions.count == 1 ? (directions.first ?? .unavailable) : (directions.isEmpty ? .unavailable : .varied)

        return LocalAcousticWindowMetrics(
            paceWpm: Self.deliveryWpm(wordCount: wordCount, elapsedSeconds: max(0, end - start)),
            articulationRateWpm: Self.articulationRateWpm(wordCount: wordCount, activeSpeechSeconds: activeDuration),
            rmsDbfs: combinedDbfs(
                zip(metrics, metrics.map { max($0.analyzedDuration, 0.001) }).compactMap { metric, weight in
                    metric.rmsDbfs.map { ($0, weight) }
                }
            ),
            medianPitchHz: pitch,
            pitchRangeSemitones: pitchRange,
            pitchDirection: direction,
            pitchSlopeSemitonesPerSecond: weightedMetric(metrics, weights: weights, keyPath: \.pitchSlopeSemitonesPerSecond),
            relativeVolumeDb: nil,
            volumeVariabilityDb: variability,
            clippingRatio: clippingRatio,
            isClipped: clippingRatio >= configuration.clippingRatioThreshold,
            steadiness: steadiness,
            voicedRatio: voiced,
            wordCount: wordCount,
            activeSpeechDuration: activeDuration > 0 ? activeDuration : nil,
            analyzedDuration: duration,
            qualityFlags: flags
        )
    }

    private func applyingRelativeVolume(
        to phrases: [LocalAcousticPhraseMetrics],
        referenceDbfs: Double?
    ) -> [LocalAcousticPhraseMetrics] {
        phrases.map { phrase in
            let relative: Double?
            if let phraseDbfs = phrase.metrics.rmsDbfs, let referenceDbfs {
                relative = phraseDbfs - referenceDbfs
            } else {
                relative = nil
            }
            return phrase.replacing(metrics: phrase.metrics.replacing(relativeVolumeDb: relative))
        }
    }

    private func weightedMetric(
        _ metrics: [LocalAcousticWindowMetrics],
        weights: [Double],
        keyPath: KeyPath<LocalAcousticWindowMetrics, Double?>
    ) -> Double? {
        weightedMean(zip(metrics, weights).compactMap { metric, weight in
            metric[keyPath: keyPath].map { ($0, weight) }
        })
    }

    private func weightedMean(_ values: [(Double, Double)]) -> Double? {
        let valid = values.filter { $0.0.isFinite && $0.1.isFinite && $0.1 > 0 }
        let totalWeight = valid.reduce(0) { $0 + $1.1 }
        guard totalWeight > 0 else { return nil }
        return valid.reduce(0) { $0 + $1.0 * $1.1 } / totalWeight
    }

    private func weightedMedian(_ values: [(Double, Double)]) -> Double? {
        let valid = values
            .filter { $0.0.isFinite && $0.1.isFinite && $0.1 > 0 }
            .sorted { $0.0 < $1.0 }
        let totalWeight = valid.reduce(0) { $0 + $1.1 }
        guard totalWeight > 0 else { return nil }
        let midpoint = totalWeight / 2
        var accumulated = 0.0
        for value in valid {
            accumulated += value.1
            if accumulated >= midpoint { return value.0 }
        }
        return valid.last?.0
    }

    /// Combines dBFS RMS levels through linear mean-square power, not by taking
    /// an arithmetic mean of logarithmic dB values.
    private func combinedDbfs(_ values: [(Double, Double)]) -> Double? {
        let valid = values.filter { $0.0.isFinite && $0.1.isFinite && $0.1 > 0 }
        let totalWeight = valid.reduce(0) { $0 + $1.1 }
        guard totalWeight > 0 else { return nil }
        let meanPower = valid.reduce(0) { partial, value in
            partial + pow(10, value.0 / 10) * value.1
        } / totalWeight
        return meanPower > 0 ? 10 * log10(meanPower) : nil
    }

    private func invalidPhrase(_ window: AcousticPhraseWindow) -> LocalAcousticPhraseMetrics {
        LocalAcousticPhraseMetrics(
            startTime: window.startTime,
            endTime: window.endTime,
            text: window.text,
            metrics: LocalAcousticWindowMetrics(
                paceWpm: nil,
                articulationRateWpm: nil,
                rmsDbfs: nil,
                medianPitchHz: nil,
                pitchRangeSemitones: nil,
                pitchDirection: .unavailable,
                pitchSlopeSemitonesPerSecond: nil,
                relativeVolumeDb: nil,
                volumeVariabilityDb: nil,
                clippingRatio: 0,
                isClipped: false,
                steadiness: nil,
                voicedRatio: 0,
                wordCount: 0,
                activeSpeechDuration: nil,
                analyzedDuration: 0,
                qualityFlags: [.invalidWindow]
            )
        )
    }

    private func validate(sampleRate: Int) throws {
        guard sampleRate == Self.requiredSampleRate else {
            throw AnalysisError.unsupportedSampleRate(expected: Self.requiredSampleRate, actual: sampleRate)
        }
    }

    // MARK: Numeric helpers

    private static func dbfs(_ amplitude: Double) -> Double? {
        guard amplitude.isFinite, amplitude > 0 else { return nil }
        return 20 * log10(amplitude)
    }

    private static func semitoneDistance(low: Double?, high: Double?) -> Double? {
        guard let low, let high, low > 0, high >= low else { return nil }
        return 12 * log2(high / low)
    }

    private static func percentile(_ values: [Double], _ quantile: Double) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let position = max(0, min(1, quantile)) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    private static func standardDeviation(_ values: [Double]) -> Double? {
        let valid = values.filter(\.isFinite)
        guard valid.count >= 2 else { return nil }
        let mean = valid.reduce(0, +) / Double(valid.count)
        let variance = valid.reduce(0) { $0 + pow($1 - mean, 2) } / Double(valid.count)
        return sqrt(variance)
    }

    private static func activeSpeechDuration(
        words: [AcousticTimedWord],
        lowerBound: Double,
        upperBound: Double
    ) -> Double? {
        var intervals = words.compactMap { word -> (Double, Double)? in
            guard isLexicalWord(word.word), word.startTime.isFinite, word.endTime.isFinite else { return nil }
            let start = max(lowerBound, word.startTime)
            let end = min(upperBound, word.endTime)
            return end > start ? (start, end) : nil
        }.sorted { $0.0 < $1.0 }
        guard !intervals.isEmpty else { return nil }

        var total = 0.0
        var current = intervals.removeFirst()
        for interval in intervals {
            if interval.0 <= current.1 {
                current.1 = max(current.1, interval.1)
            } else {
                total += current.1 - current.0
                current = interval
            }
        }
        total += current.1 - current.0
        return total > 0 ? total : nil
    }

    private static func wordCount(in text: String) -> Int {
        text.split { character in
            !character.isLetter && !character.isNumber && character != "'" && character != "’"
        }.count
    }

    private static func isLexicalWord(_ word: String) -> Bool {
        word.contains { $0.isLetter || $0.isNumber }
    }
}

private extension LocalAcousticWindowMetrics {
    func replacing(relativeVolumeDb: Double?) -> LocalAcousticWindowMetrics {
        LocalAcousticWindowMetrics(
            paceWpm: paceWpm,
            articulationRateWpm: articulationRateWpm,
            rmsDbfs: rmsDbfs,
            medianPitchHz: medianPitchHz,
            pitchRangeSemitones: pitchRangeSemitones,
            pitchDirection: pitchDirection,
            pitchSlopeSemitonesPerSecond: pitchSlopeSemitonesPerSecond,
            relativeVolumeDb: relativeVolumeDb,
            volumeVariabilityDb: volumeVariabilityDb,
            clippingRatio: clippingRatio,
            isClipped: isClipped,
            steadiness: steadiness,
            voicedRatio: voicedRatio,
            wordCount: wordCount,
            activeSpeechDuration: activeSpeechDuration,
            analyzedDuration: analyzedDuration,
            qualityFlags: qualityFlags
        )
    }
}

private extension LocalAcousticPhraseMetrics {
    func replacing(metrics: LocalAcousticWindowMetrics) -> LocalAcousticPhraseMetrics {
        LocalAcousticPhraseMetrics(startTime: startTime, endTime: endTime, text: text, metrics: metrics)
    }

    func addingQualityFlag(_ flag: AcousticQualityFlag) -> LocalAcousticPhraseMetrics {
        var flags = metrics.qualityFlags
        if !flags.contains(flag) { flags.append(flag) }
        let replacement = LocalAcousticWindowMetrics(
            paceWpm: metrics.paceWpm,
            articulationRateWpm: metrics.articulationRateWpm,
            rmsDbfs: metrics.rmsDbfs,
            medianPitchHz: metrics.medianPitchHz,
            pitchRangeSemitones: metrics.pitchRangeSemitones,
            pitchDirection: metrics.pitchDirection,
            pitchSlopeSemitonesPerSecond: metrics.pitchSlopeSemitonesPerSecond,
            relativeVolumeDb: metrics.relativeVolumeDb,
            volumeVariabilityDb: metrics.volumeVariabilityDb,
            clippingRatio: metrics.clippingRatio,
            isClipped: metrics.isClipped,
            steadiness: metrics.steadiness,
            voicedRatio: metrics.voicedRatio,
            wordCount: metrics.wordCount,
            activeSpeechDuration: metrics.activeSpeechDuration,
            analyzedDuration: metrics.analyzedDuration,
            qualityFlags: flags.sorted { $0.rawValue < $1.rawValue }
        )
        return replacing(metrics: replacement)
    }
}
