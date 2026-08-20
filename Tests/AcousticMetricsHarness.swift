import Foundation

@main
private enum AcousticMetricsHarness {
    private static let sampleRate = AcousticMetricsCalculator.requiredSampleRate

    static func main() throws {
        try testSilenceQualityFlags()
        try testSteadySinePitchAndRates()
        try testRelativeVolumeAndProjectionPrivacy()
        try testMultipleTakeMerge()
        testAudioTimelineGapReconciliation()
        try testClippingDetection()
        print("AcousticMetricsHarness: all deterministic checks passed")
    }

    private static func testSilenceQualityFlags() throws {
        let calculator = AcousticMetricsCalculator()
        let result = try calculator.analyzePhrase(
            samples: [Float](repeating: 0, count: sampleRate),
            startTime: 0,
            endTime: 1,
            text: "",
            words: []
        )

        expect(result.metrics.rmsDbfs == nil, "digital silence must not produce a finite dBFS value")
        expect(result.metrics.medianPitchHz == nil, "silence must not produce pitch")
        expect(result.metrics.voicedRatio == 0, "silence must have zero voiced coverage")
        expect(result.metrics.qualityFlags.contains(.lowSignal), "silence must be marked low-signal")
        expect(result.metrics.qualityFlags.contains(.pitchUnavailable), "silence must mark pitch unavailable")
    }

    private static func testSteadySinePitchAndRates() throws {
        let calculator = AcousticMetricsCalculator()
        let samples = sine(frequency: 200, amplitude: 0.2, seconds: 2)
        let words = [
            AcousticTimedWord(word: "one", startTime: 0.1, endTime: 0.3),
            AcousticTimedWord(word: "two", startTime: 0.6, endTime: 0.8),
            AcousticTimedWord(word: "three", startTime: 1.1, endTime: 1.3),
            AcousticTimedWord(word: "four", startTime: 1.6, endTime: 1.8),
        ]
        let result = try calculator.analyzePhrase(
            samples: samples,
            startTime: 0,
            endTime: 2,
            text: "one two three four",
            words: words
        )

        expectClose(result.metrics.medianPitchHz, 200, tolerance: 2, "YIN median pitch")
        expect((result.metrics.pitchRangeSemitones ?? 99) < 0.25, "steady sine must have a narrow pitch range")
        expect(result.metrics.pitchDirection == .level, "steady sine must have level pitch")
        expectClose(result.metrics.rmsDbfs, -16.99, tolerance: 0.2, "sine RMS dBFS")
        expectClose(result.metrics.paceWpm, 120, tolerance: 0.01, "delivery pace")
        expectClose(result.metrics.articulationRateWpm, 300, tolerance: 0.01, "articulation rate")
        expectClose(result.metrics.steadiness, 1, tolerance: 0.001, "regular word-onset steadiness")
        expect(result.metrics.voicedRatio > 0.95, "steady sine must be consistently voiced")
    }

    private static func testRelativeVolumeAndProjectionPrivacy() throws {
        let calculator = AcousticMetricsCalculator()
        let quiet = sine(frequency: 180, amplitude: 0.1, seconds: 1)
        let loud = sine(frequency: 180, amplitude: 0.2, seconds: 1)
        let samples = quiet + loud
        let windows = [
            AcousticPhraseWindow(
                startTime: 0,
                endTime: 1,
                text: "quiet phrase",
                words: [
                    AcousticTimedWord(word: "quiet", startTime: 0.1, endTime: 0.35),
                    AcousticTimedWord(word: "phrase", startTime: 0.5, endTime: 0.8),
                ]
            ),
            AcousticPhraseWindow(
                startTime: 1,
                endTime: 2,
                text: "loud phrase",
                words: [
                    AcousticTimedWord(word: "loud", startTime: 1.1, endTime: 1.35),
                    AcousticTimedWord(word: "phrase", startTime: 1.5, endTime: 1.8),
                ]
            ),
        ]
        let source = try calculator.analyze(
            samples: samples,
            source: .mic,
            scope: .singleSpeaker,
            phrases: windows
        )

        let quietRelative = source.phrases[0].metrics.relativeVolumeDb
        let loudRelative = source.phrases[1].metrics.relativeVolumeDb
        expectClose(zipValues(loudRelative, quietRelative).map(-), 6.02, tolerance: 0.15, "relative phrase loudness delta")

        let local = LocalAcousticMetrics(sources: [source])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let storageJSON = String(decoding: try encoder.encode(local.storageProjection()), as: UTF8.self)
        let safeJSON = String(decoding: try encoder.encode(local.aiSafeProjection()), as: UTF8.self)
        expect(storageJSON.contains("medianPitchHz"), "storage projection must retain bucketed absolute pitch")
        expect(!safeJSON.contains("medianPitchHz"), "AI-safe projection must omit absolute pitch")
        expect(safeJSON.contains("pitchRangeSemitones"), "AI-safe projection should retain pitch variation")

        let longText = String(repeating: "x", count: 300)
        let manyPhrases = (0..<250).map { index in
            LocalAcousticPhraseMetrics(
                startTime: Double(index),
                endTime: Double(index) + 0.5,
                text: longText,
                metrics: source.phrases[0].metrics
            )
        }
        let boundedSource = LocalAcousticSourceMetrics(
            source: .mic,
            speaker: nil,
            scope: .singleSpeaker,
            overall: source.overall,
            phrases: manyPhrases
        )
        let boundedProjection = LocalAcousticMetrics(sources: [boundedSource]).storageProjection()
        let projectedPhrases = boundedProjection.sources[0].phrases ?? []
        expect(projectedPhrases.count == 200, "wire projection must cap phrases at 200")
        expect(projectedPhrases.first?.startTime == 0, "even sampling must retain the first phrase")
        expect(projectedPhrases.last?.startTime == 249, "even sampling must retain the last phrase")
        expect(projectedPhrases.allSatisfy { ($0.text?.count ?? 0) <= 240 }, "wire phrase text must be capped at 240 characters")
    }

    private static func testClippingDetection() throws {
        let calculator = AcousticMetricsCalculator()
        var samples = sine(frequency: 220, amplitude: 0.2, seconds: 1)
        for index in 0..<200 { samples[index] = index.isMultiple(of: 2) ? 1 : -1 }
        let result = try calculator.analyzePhrase(samples: samples, startTime: 0, endTime: 1)
        expect(result.metrics.isClipped, "clipped samples must cross the configured ratio threshold")
        expect(result.metrics.clippingRatio > 0.01, "clipping ratio must be retained locally")
        expect(result.metrics.qualityFlags.contains(.clippingDetected), "clipping must be surfaced as a quality flag")
    }

    private static func testMultipleTakeMerge() throws {
        let calculator = AcousticMetricsCalculator()
        let firstPhrase = try calculator.analyzePhrase(
            samples: sine(frequency: 180, amplitude: 0.1, seconds: 1),
            startTime: 0,
            endTime: 1,
            text: "first take",
            words: [
                AcousticTimedWord(word: "first", startTime: 0.1, endTime: 0.35),
                AcousticTimedWord(word: "take", startTime: 0.55, endTime: 0.85),
            ]
        )
        let secondPhrase = try calculator.analyzePhrase(
            samples: sine(frequency: 180, amplitude: 0.2, seconds: 1),
            startTime: 2,
            endTime: 3,
            text: "second take",
            words: [
                AcousticTimedWord(word: "second", startTime: 2.1, endTime: 2.35),
                AcousticTimedWord(word: "take", startTime: 2.55, endTime: 2.85),
            ]
        )
        let first = LocalAcousticMetrics(sources: [
            calculator.aggregate(
                source: .mic,
                scope: .singleSpeaker,
                speaker: "Me",
                phrases: [firstPhrase]
            ),
        ])
        let second = LocalAcousticMetrics(sources: [
            calculator.aggregate(
                source: .mic,
                scope: .singleSpeaker,
                speaker: "Me",
                phrases: [secondPhrase]
            ),
        ])

        guard let merged = calculator.merging(existing: first, appending: second),
              let source = merged.sources.first else {
            fatalError("multiple-take metrics should merge")
        }
        expect(source.phrases.map(\.startTime) == [0, 2], "merged phrases must retain timeline order")
        expectClose(source.overall?.paceWpm, 80, tolerance: 0.01, "merged overall pace")
        expectClose(
            zipValues(
                source.phrases[1].metrics.relativeVolumeDb,
                source.phrases[0].metrics.relativeVolumeDb
            ).map(-),
            6.02,
            tolerance: 0.15,
            "merged relative phrase loudness delta"
        )
    }

    private static func testAudioTimelineGapReconciliation() {
        expect(
            AudioTimelineGapReconciler.missingFrames(
                reportedStartTime: 10.199,
                expectedStartTime: 10,
                sampleRate: 16_000
            ) == 0,
            "callback jitter below 200 ms must not create silence"
        )
        expect(
            AudioTimelineGapReconciler.missingFrames(
                reportedStartTime: 10.25,
                expectedStartTime: 10,
                sampleRate: 16_000
            ) == 4_000,
            "a 250 ms discontinuity must create 4,000 frames at 16 kHz"
        )
        expect(
            AudioTimelineGapReconciler.missingFrames(
                reportedStartTime: 9.5,
                expectedStartTime: 10,
                sampleRate: 16_000
            ) == 0,
            "backward/stale callback times must not add silence"
        )
    }

    private static func sine(frequency: Double, amplitude: Float, seconds: Double) -> [Float] {
        let count = Int(Double(sampleRate) * seconds)
        return (0..<count).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / Double(sampleRate)))
        }
    }

    private static func zipValues(_ first: Double?, _ second: Double?) -> (Double, Double)? {
        guard let first, let second else { return nil }
        return (first, second)
    }

    private static func expectClose(
        _ actual: Double?,
        _ expected: Double,
        tolerance: Double,
        _ label: String
    ) {
        guard let actual, abs(actual - expected) <= tolerance else {
            fatalError("\(label): expected \(expected) +/- \(tolerance), got \(String(describing: actual))")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}
