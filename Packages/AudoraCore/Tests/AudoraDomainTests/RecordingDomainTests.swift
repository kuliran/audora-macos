import AudoraDomain
import XCTest

final class RecordingDomainTests: XCTestCase {
    func testCanonicalFormatIsLockedToVersionOne() throws {
        XCTAssertEqual(CanonicalAudioFormat.versionOne.sampleRateHz, 16_000)
        XCTAssertEqual(CanonicalAudioFormat.versionOne.channelCount, 1)
        XCTAssertEqual(
            CanonicalAudioFormat.versionOne.encoding,
            .pcmS16LE
        )
        XCTAssertThrowsError(
            try CanonicalAudioFormat(
                sampleRateHz: 48_000,
                channelCount: 1,
                encoding: .pcmS16LE
            )
        )
        XCTAssertThrowsError(
            try CanonicalAudioFormat(
                sampleRateHz: 16_000,
                channelCount: 2,
                encoding: .pcmS16LE
            )
        )
    }

    func testRecordingLimitBoundariesAreFrameExact() {
        XCTAssertEqual(
            CanonicalRecordingLimits.phase(at: 38_399_999),
            .ordinary
        )
        XCTAssertEqual(
            CanonicalRecordingLimits.phase(at: 38_400_000),
            .fiveMinuteWarning
        )
        XCTAssertEqual(
            CanonicalRecordingLimits.phase(at: 42_239_999),
            .fiveMinuteWarning
        )
        XCTAssertEqual(
            CanonicalRecordingLimits.phase(at: 42_240_000),
            .oneMinuteCountdown(secondsRemaining: 60)
        )
        XCTAssertEqual(
            CanonicalRecordingLimits.phase(at: 43_184_001),
            .oneMinuteCountdown(secondsRemaining: 1)
        )
        XCTAssertEqual(
            CanonicalRecordingLimits.phase(at: 43_200_000),
            .automaticStop
        )
    }

    func testUnavailableIntervalsUseHalfOpenUnionAndReasonSets() throws {
        let intervals = [
            try interval(1_600, 3_200, [.muted]),
            try interval(3_000, 4_800, [.captureGap]),
            try interval(4_800, 6_400, [.captureGap]),
        ]
        XCTAssertEqual(
            try UnavailableIntervalNormalizer.normalize(
                intervals,
                durationFrames: 8_000
            ),
            [
                try interval(1_600, 3_000, [.muted]),
                try interval(3_000, 3_200, [.captureGap, .muted]),
                try interval(3_200, 6_400, [.captureGap]),
            ]
        )
    }

    func testNormalizationIsOrderIndependentAndIdempotentForSyntheticCases() throws {
        var generator = LCG(state: 0xA0D0_12)
        for _ in 0..<250 {
            let duration: UInt64 = 1_000
            var intervals: [UnavailableInterval] = []
            for _ in 0..<20 {
                let start = generator.next() % 999
                let width = 1 + generator.next() % (duration - start)
                let reasons: Set<UnavailableReason> = generator.next().isMultiple(of: 2)
                    ? [.muted]
                    : [.captureGap]
                intervals.append(try interval(start, start + width, reasons))
            }
            let normalized = try UnavailableIntervalNormalizer.normalize(
                intervals,
                durationFrames: duration
            )
            XCTAssertEqual(
                try UnavailableIntervalNormalizer.normalize(
                    normalized,
                    durationFrames: duration
                ),
                normalized
            )
            XCTAssertEqual(
                try UnavailableIntervalNormalizer.normalize(
                    intervals.reversed(),
                    durationFrames: duration
                ),
                normalized
            )
            for pair in zip(normalized, normalized.dropFirst()) {
                XCTAssertLessThanOrEqual(pair.0.range.endFrame, pair.1.range.startFrame)
                if pair.0.range.endFrame == pair.1.range.startFrame {
                    XCTAssertNotEqual(pair.0.reasons, pair.1.reasons)
                }
            }
        }
    }

    func testSealedAudioRejectsNonCanonicalReferencesAndUnnormalizedIntervals() throws {
        let fingerprint = try AudioFingerprint(
            sha256: String(repeating: "a", count: 64)
        )
        XCTAssertThrowsError(
            try SealedAudioAsset(
                source: .microphone,
                format: .versionOne,
                frameCount: 16_000,
                canonicalAudioPath: LibraryRelativePath("audio/other.wav"),
                fingerprint: fingerprint,
                unavailableIntervals: []
            )
        )
        XCTAssertThrowsError(
            try SealedAudioAsset(
                source: .microphone,
                format: .versionOne,
                frameCount: 16_000,
                canonicalAudioPath: LibraryRelativePath("audio/audio.wav"),
                fingerprint: fingerprint,
                unavailableIntervals: [
                    try interval(0, 8_000, [.muted]),
                    try interval(4_000, 12_000, [.captureGap]),
                ]
            )
        )
    }

    private func interval(
        _ start: UInt64,
        _ end: UInt64,
        _ reasons: Set<UnavailableReason>
    ) throws -> UnavailableInterval {
        try UnavailableInterval(
            range: CanonicalFrameRange(startFrame: start, endFrame: end),
            reasons: reasons
        )
    }
}

private struct LCG {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
