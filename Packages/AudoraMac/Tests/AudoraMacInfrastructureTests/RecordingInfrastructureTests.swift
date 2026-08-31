import AudoraApplication
import AudoraDomain
@testable import AudoraMacInfrastructure
import CryptoKit
import Darwin
import Foundation
import XCTest

final class RecordingInfrastructureTests: XCTestCase {
    func testAssemblerProducesCanonicalMonoPCMAndHonestGapAndMuteSpans() throws {
        var assembler = CanonicalPCMAssembler()
        let first = try assembler.consume(
            MicrophoneInputChunk(
                sampleRateHz: 16_000,
                startSampleFrame: 0,
                channels: [[-1, -0.5, 0.5, 1]]
            ),
            muted: false
        )
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].frameCount, 4)
        XCTAssertEqual(first[0].reasons, [])
        XCTAssertEqual(first[0].pcmLittleEndian?.count, 8)
        XCTAssertNotNil(first[0].level)

        let later = try assembler.consume(
            MicrophoneInputChunk(
                sampleRateHz: 16_000,
                startSampleFrame: 6,
                channels: [[0.25, 0.5]]
            ),
            muted: true
        )
        XCTAssertEqual(
            later,
            [
                CanonicalPCMSpan(
                    frameCount: 2,
                    pcmLittleEndian: nil,
                    reasons: [.captureGap, .muted],
                    level: nil
                ),
                CanonicalPCMSpan(
                    frameCount: 2,
                    pcmLittleEndian: nil,
                    reasons: [.muted],
                    level: nil
                ),
            ]
        )
        XCTAssertEqual(assembler.frameCount, 8)
    }

    func testAssemblerIsBufferBoundaryInvariantForSyntheticInput() throws {
        let samples: [Float] = (0..<1_000).map { index in
            Float((index % 17) - 8) / 8
        }
        var whole = CanonicalPCMAssembler()
        let wholePCM = try XCTUnwrap(
            whole.consume(
                MicrophoneInputChunk(
                    sampleRateHz: 16_000,
                    startSampleFrame: 0,
                    channels: [samples]
                ),
                muted: false
            ).first?.pcmLittleEndian
        )

        var partitioned = CanonicalPCMAssembler()
        var partitionedPCM = Data()
        for start in stride(from: 0, to: samples.count, by: 37) {
            let end = min(samples.count, start + 37)
            let spans = try partitioned.consume(
                MicrophoneInputChunk(
                    sampleRateHz: 16_000,
                    startSampleFrame: UInt64(start),
                    channels: [Array(samples[start..<end])]
                ),
                muted: false
            )
            for span in spans { partitionedPCM.append(try XCTUnwrap(span.pcmLittleEndian)) }
        }
        XCTAssertEqual(partitionedPCM, wholePCM)
        XCTAssertEqual(partitioned.frameCount, whole.frameCount)
    }

    func testMicrophoneAndImportShareCanonicalNativeRateGoldenPCM() throws {
        let halfLSB = Float(1.0 / 65_536.0)
        let left: [Float] = [0, 0, -1, 1, 0.5, -0.5]
        let right: [Float] = [halfLSB * 2, -halfLSB * 2, -1, 1, -0.5, 0.5]
        let interleaved = zip(left, right).flatMap { [$0, $1] }
        let imported = try canonicalImportPCM(
            sampleRateHz: 16_000,
            channelCount: 2,
            interleavedChunks: [interleaved]
        )

        var microphone = CanonicalPCMAssembler()
        let microphonePCM = try microphone.consume(
            MicrophoneInputChunk(
                sampleRateHz: 16_000,
                startSampleFrame: 0,
                channels: [left, right]
            ),
            muted: false
        ).reduce(into: Data()) { bytes, span in
            bytes.append(try XCTUnwrap(span.pcmLittleEndian))
        }

        XCTAssertEqual(microphonePCM, imported)
        XCTAssertEqual(
            Array(imported),
            [0x01, 0x00, 0xFF, 0xFF, 0x00, 0x80, 0xFF, 0x7F, 0x00, 0x00, 0x00, 0x00]
        )
    }

    func testMicrophoneAndImportShareResampledGoldenAcrossChunkPartitions() throws {
        let sampleRate = UInt32(48_000)
        let samples = (0..<Int(sampleRate / 100)).map { index in
            Float(sin(Double(index) * 0.071) * 0.4)
        }
        let interleaved = samples.flatMap { [$0, $0] }
        let imported = try canonicalImportPCM(
            sampleRateHz: sampleRate,
            channelCount: 2,
            interleavedChunks: [interleaved]
        )
        let whole = try canonicalMicrophonePCM(
            sampleRateHz: sampleRate,
            channels: [samples, samples],
            partitions: [0..<samples.count]
        )
        let partitioned = try canonicalMicrophonePCM(
            sampleRateHz: sampleRate,
            channels: [samples, samples],
            partitions: [0..<37, 37..<173, 173..<311, 311..<samples.count]
        )

        XCTAssertEqual(whole, imported)
        XCTAssertEqual(partitioned, imported)
        var canonicalWAV = CanonicalWAVWriter.header(dataByteCount: UInt32(imported.count))
        canonicalWAV.append(imported)
        XCTAssertEqual(
            SHA256.hash(data: canonicalWAV).map { String(format: "%02x", $0) }.joined(),
            "b0fb6b2abba998d79b09f14401a799059356d8f30798ba6af54f59c544fc9fd0"
        )
    }

    func testObservedGapObservedSharesSourceOrderedResamplingWithImportAtNonNativeRates() throws {
        for sampleRate in [UInt32(48_000), 44_100] {
            let before = (0..<127).map { Float(sin(Double($0) * 0.071) * 0.4) }
            let after = (0..<193).map { Float(cos(Double($0) * 0.053) * 0.35) }
            let gapFrames = 271
            let imported = try canonicalImportPCM(
                sampleRateHz: sampleRate,
                channelCount: 2,
                interleavedChunks: [(before + Array(repeating: 0, count: gapFrames) + after)
                    .flatMap { [$0, $0] }]
            )
            let expected = silenceCanonicalFrames(
                in: imported,
                from: canonicalCeiling(127, at: sampleRate),
                through: canonicalCeiling(127 + UInt64(gapFrames), at: sampleRate)
            )
            let whole = try microphonePCMWithUnavailableZeros(
                sampleRateHz: sampleRate,
                before: before,
                unavailableFrames: gapFrames,
                after: after,
                muted: false,
                partitioned: false
            )
            let partitioned = try microphonePCMWithUnavailableZeros(
                sampleRateHz: sampleRate,
                before: before,
                unavailableFrames: gapFrames,
                after: after,
                muted: false,
                partitioned: true
            )

            XCTAssertEqual(whole.pcm, expected, "rate \(sampleRate)")
            XCTAssertEqual(partitioned.pcm, expected, "rate \(sampleRate)")
            XCTAssertEqual(
                whole.unavailable,
                [
                    UnavailableInterval(
                        start: canonicalCeiling(127, at: sampleRate),
                        end: canonicalCeiling(127 + UInt64(gapFrames), at: sampleRate),
                        reasons: [.captureGap]
                    ),
                ],
                "rate \(sampleRate)"
            )
        }
    }

    func testObservedMuteObservedSharesSourceOrderedResamplingWithImportAtNonNativeRates() throws {
        for sampleRate in [UInt32(48_000), 44_100] {
            let before = (0..<127).map { Float(sin(Double($0) * 0.071) * 0.4) }
            let withheld = (0..<271).map { Float(cos(Double($0) * 0.053) * 0.35) }
            let after = (0..<193).map { Float(sin(Double($0) * 0.029) * 0.3) }
            let imported = try canonicalImportPCM(
                sampleRateHz: sampleRate,
                channelCount: 2,
                interleavedChunks: [(before + Array(repeating: 0, count: withheld.count) + after)
                    .flatMap { [$0, $0] }]
            )
            let expected = silenceCanonicalFrames(
                in: imported,
                from: canonicalCeiling(127, at: sampleRate),
                through: canonicalCeiling(127 + UInt64(withheld.count), at: sampleRate)
            )
            let whole = try microphonePCMWithUnavailableZeros(
                sampleRateHz: sampleRate,
                before: before,
                unavailableFrames: withheld.count,
                after: after,
                muted: true,
                partitioned: false,
                withheld: withheld
            )
            let partitioned = try microphonePCMWithUnavailableZeros(
                sampleRateHz: sampleRate,
                before: before,
                unavailableFrames: withheld.count,
                after: after,
                muted: true,
                partitioned: true,
                withheld: withheld
            )

            XCTAssertEqual(whole.pcm, expected, "rate \(sampleRate)")
            XCTAssertEqual(partitioned.pcm, expected, "rate \(sampleRate)")
            XCTAssertEqual(
                whole.unavailable,
                [
                    UnavailableInterval(
                        start: canonicalCeiling(127, at: sampleRate),
                        end: canonicalCeiling(127 + UInt64(withheld.count), at: sampleRate),
                        reasons: [.muted]
                    ),
                ],
                "rate \(sampleRate)"
            )
        }
    }

    func testConsecutiveSubcanonicalGapsStillAdvanceResamplerAtFortyEightKilohertz() throws {
        let before: [Float] = [0.4]
        let after = (0..<96).map { Float(sin(Double($0) * 0.071) * 0.4) }
        let expected = try canonicalImportPCM(
            sampleRateHz: 48_000,
            channelCount: 2,
            interleavedChunks: [(before + [0, 0] + after).flatMap { [$0, $0] }]
        )

        var assembler = CanonicalPCMAssembler()
        var spans = try assembler.consume(
            MicrophoneInputChunk(sampleRateHz: 48_000, startSampleFrame: 0, channels: [before, before]),
            muted: false
        )
        spans += try assembler.consumeGap(
            sampleRateHz: 48_000, startSampleFrame: 1, frameCount: 1, channelCount: 2, muted: false
        )
        spans += try assembler.consumeGap(
            sampleRateHz: 48_000, startSampleFrame: 2, frameCount: 1, channelCount: 2, muted: false
        )
        spans += try assembler.consume(
            MicrophoneInputChunk(sampleRateHz: 48_000, startSampleFrame: 3, channels: [after, after]),
            muted: false
        )
        spans += try assembler.finish()

        let pcm = spans.reduce(into: Data()) { pcm, span in
            pcm.append(span.pcmLittleEndian ?? Data(repeating: 0, count: Int(span.frameCount * 2)))
        }
        XCTAssertEqual(pcm, expected)
        XCTAssertTrue(spans.allSatisfy(\.reasons.isEmpty))
    }

    func testStereoResamplingHasPartitionInvariantGoldenFingerprint() throws {
        let left: [Float] = (0..<96).map { Float(($0 % 11) - 5) / 5 }
        let right: [Float] = (0..<96).map { Float(($0 % 7) - 3) / 3 }
        var whole = CanonicalPCMAssembler()
        var wholeBytes = try whole.consume(
            MicrophoneInputChunk(
                sampleRateHz: 48_000,
                startSampleFrame: 0,
                channels: [left, right]
            ),
            muted: false
        ).reduce(into: Data()) { bytes, span in
            bytes.append(try XCTUnwrap(span.pcmLittleEndian))
        }
        for span in try whole.finish() {
            wholeBytes.append(try XCTUnwrap(span.pcmLittleEndian))
        }

        var partitioned = CanonicalPCMAssembler()
        var partitionedBytes = Data()
        for range in [0..<15, 15..<47, 47..<71, 71..<96] {
            let spans = try partitioned.consume(
                MicrophoneInputChunk(
                    sampleRateHz: 48_000,
                    startSampleFrame: UInt64(range.lowerBound),
                    channels: [Array(left[range]), Array(right[range])]
                ),
                muted: false
            )
            for span in spans {
                partitionedBytes.append(try XCTUnwrap(span.pcmLittleEndian))
            }
        }
        for span in try partitioned.finish() {
            partitionedBytes.append(try XCTUnwrap(span.pcmLittleEndian))
        }
        XCTAssertEqual(partitionedBytes, wholeBytes)
        let digest = Data(SHA256.hash(data: wholeBytes)).map {
            String(format: "%02x", $0)
        }.joined()
        XCTAssertEqual(
            digest,
            "c01ff6cd2f5aea8aabf1d33d41179c74d7d483b712d33cb4693fd5fae0f78898"
        )
    }

    func testStereoResamplingUsesAbsoluteFramesAndRejectsMidstreamFormatChange() throws {
        var assembler = CanonicalPCMAssembler()
        var spans = try assembler.consume(
            MicrophoneInputChunk(
                sampleRateHz: 48_000,
                startSampleFrame: 0,
                channels: [
                    [1, 0, 0, -1, 0, 0],
                    [1, 0, 0, -1, 0, 0],
                ]
            ),
            muted: false
        )
        spans += try assembler.finish()
        XCTAssertEqual(spans.first?.frameCount, 2)
        XCTAssertEqual(spans.first?.pcmLittleEndian?.count, 4)
        XCTAssertThrowsError(
            try assembler.consume(
                MicrophoneInputChunk(
                    sampleRateHz: 44_100,
                    startSampleFrame: 6,
                    channels: [[0, 0]]
                ),
                muted: false
            )
        ) { error in
            XCTAssertEqual(error as? CanonicalPCMAssemblerError, .unsupportedInputFormat)
        }
    }

    func testCrossingDurationCeilingKeepsOnlyExactCanonicalPrefix() throws {
        let original = CanonicalPCMSpan(
            frameCount: 100,
            pcmLittleEndian: Data((0..<200).map { UInt8($0 % 251) }),
            reasons: [],
            level: 0.3
        )
        let bounded = try original.prefix(maximumFrames: 40)
        XCTAssertEqual(bounded.frameCount, 40)
        XCTAssertEqual(bounded.pcmLittleEndian, Data(original.pcmLittleEndian!.prefix(80)))
        XCTAssertEqual(bounded.reasons, [])
    }

    func testExplicitCaptureGapAdvancesCanonicalTimelineWithoutObservedSilence() throws {
        var assembler = CanonicalPCMAssembler()
        var leading = try assembler.consumeGap(
            sampleRateHz: 48_000,
            startSampleFrame: 12_000,
            frameCount: 6_000,
            channelCount: 1,
            muted: false
        )
        leading += try assembler.finish()
        XCTAssertEqual(leading.reduce(0) { $0 + $1.frameCount }, 6_000)
        XCTAssertTrue(leading.allSatisfy {
            $0.pcmLittleEndian == nil && $0.reasons == [.captureGap] && $0.level == nil
        })
        XCTAssertEqual(assembler.frameCount, 6_000)
    }

    func testMaximumRateHugeGapIsComputationallyBoundedAndClampedAtFortyFiveMinutes() throws {
        let maximumInputFrames = UInt64(384_000) * 45 * 60
        let oversizedInputFrames = maximumInputFrames + UInt64(384_000) * 60
        var assembler = CanonicalPCMAssembler()
        let started = ContinuousClock.now

        var spans = try assembler.consumeGap(
            sampleRateHz: 384_000,
            startSampleFrame: 0,
            frameCount: oversizedInputFrames,
            channelCount: 2,
            muted: false
        )
        spans += try assembler.finish()

        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
        XCTAssertLessThanOrEqual(spans.count, 3)
        XCTAssertEqual(
            spans.reduce(0) { $0 + $1.frameCount },
            CanonicalRecordingLimits.maximumFrames
        )
        XCTAssertEqual(assembler.frameCount, CanonicalRecordingLimits.maximumFrames)
        XCTAssertTrue(spans.allSatisfy {
            $0.pcmLittleEndian == nil && $0.reasons == [.captureGap] && $0.level == nil
        })
    }

    func testQualifiedConverterBridgeIsAlwaysBelowTwoInputBatches() throws {
        for sampleRate in [UInt32(44_100), 48_000, 384_000, 44_099] {
            let converter = try StreamingCanonicalSampleRateConverter(
                sourceSampleRateHz: sampleRate
            )
            _ = try converter.consume([Double](repeating: 0.25, count: 127))

            XCTAssertGreaterThan(converter.unavailableDiscontinuityBridgeInputFrames, 0)
            XCTAssertLessThanOrEqual(
                converter.unavailableDiscontinuityBridgeInputFrames,
                StreamingCanonicalSampleRateConverter.maximumUnavailableBridgeInputFrames,
                "rate \(sampleRate)"
            )
        }
    }

    func testConverterRejectsSyntheticSilenceBeyondQualifiedWorkBound() throws {
        let converter = try StreamingCanonicalSampleRateConverter(
            sourceSampleRateHz: 44_100
        )

        XCTAssertThrowsError(
            try converter.consumeSilence(
                frameCount: StreamingCanonicalSampleRateConverter
                    .maximumSyntheticSilenceInputFrames + 1,
                onOutput: { _ in }
            )
        )
    }

    func testFractionalGapOnlyEOSUsesDecodedFloorWithoutPhantomFrame() throws {
        var assembler = CanonicalPCMAssembler()
        var spans = try assembler.consumeGap(
            sampleRateHz: 44_100,
            startSampleFrame: 0,
            frameCount: 50_000,
            channelCount: 2,
            muted: false
        )
        spans += try assembler.finish()

        XCTAssertEqual(
            spans.reduce(0) { $0 + $1.frameCount },
            canonicalFloor(50_000, at: 44_100)
        )
        XCTAssertEqual(assembler.frameCount, canonicalFloor(50_000, at: 44_100))
        XCTAssertEqual(assembler.pendingFrameCount, 0)
        XCTAssertTrue(spans.allSatisfy {
            $0.pcmLittleEndian == nil && $0.reasons == [.captureGap] && $0.level == nil
        })
    }

    func testObservedThenCompactedTrailingGapMatchesUninterruptedEOSAtFractionalPhase() throws {
        let sampleRate = UInt32(44_100)
        let before = (0..<127).map { Float(sin(Double($0) * 0.071) * 0.4) }
        let gapFrames = 50_000
        let imported = try canonicalImportPCM(
            sampleRateHz: sampleRate,
            channelCount: 2,
            interleavedChunks: [
                (before + Array(repeating: 0, count: gapFrames)).flatMap { [$0, $0] },
            ]
        )
        let expected = silenceCanonicalFrames(
            in: imported,
            from: canonicalCeiling(UInt64(before.count), at: sampleRate),
            through: UInt64(imported.count / 2)
        )

        var assembler = CanonicalPCMAssembler()
        var spans = try assembler.consume(
            MicrophoneInputChunk(
                sampleRateHz: sampleRate,
                startSampleFrame: 0,
                channels: [before, before]
            ),
            muted: false
        )
        spans += try assembler.consumeGap(
            sampleRateHz: sampleRate,
            startSampleFrame: UInt64(before.count),
            frameCount: UInt64(gapFrames),
            channelCount: 2,
            muted: false
        )
        spans += try assembler.finish()

        let actual = spans.reduce(into: Data()) { pcm, span in
            pcm.append(
                span.pcmLittleEndian ?? Data(repeating: 0, count: Int(span.frameCount * 2))
            )
        }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(assembler.frameCount, UInt64(imported.count / 2))
        XCTAssertEqual(assembler.pendingFrameCount, 0)
        XCTAssertEqual(
            spans.filter { $0.reasons == [.captureGap] }.reduce(0) { $0 + $1.frameCount },
            UInt64(imported.count / 2) - canonicalCeiling(UInt64(before.count), at: sampleRate)
        )
    }

    func testCompactedGapPreservesObservedPCMOnBothSidesAcrossRatesAndPhases() throws {
        let before = (0..<127).map { Float(sin(Double($0) * 0.071) * 0.4) }
        let after = (0..<193).map { Float(cos(Double($0) * 0.053) * 0.35) }
        let gapFrames = 50_004

        // 44,099 is coprime with 16,000; the other rates cover the common
        // 44.1/48 kHz paths and the maximum accepted live input rate.
        for sampleRate in [UInt32(44_100), 48_000, 384_000, 44_099] {
            let imported = try canonicalImportPCM(
                sampleRateHz: sampleRate,
                channelCount: 2,
                interleavedChunks: [
                    (before + Array(repeating: 0, count: gapFrames) + after)
                        .flatMap { [$0, $0] },
                ]
            )
            let unavailableStart = canonicalCeiling(UInt64(before.count), at: sampleRate)
            let unavailableEnd = canonicalCeiling(
                UInt64(before.count + gapFrames),
                at: sampleRate
            )
            let expected = silenceCanonicalFrames(
                in: imported,
                from: unavailableStart,
                through: unavailableEnd
            )

            let actual = try microphonePCMWithUnavailableZeros(
                sampleRateHz: sampleRate,
                before: before,
                unavailableFrames: gapFrames,
                after: after,
                muted: false,
                partitioned: true
            )

            XCTAssertEqual(actual.pcm, expected, "rate \(sampleRate)")
            XCTAssertEqual(
                actual.frameCount,
                UInt64(imported.count / 2),
                "rate \(sampleRate)"
            )
            XCTAssertEqual(actual.pendingFrameCount, 0, "rate \(sampleRate)")
            XCTAssertEqual(
                actual.unavailable,
                [
                    UnavailableInterval(
                        start: unavailableStart,
                        end: unavailableEnd,
                        reasons: [.captureGap]
                    ),
                ],
                "rate \(sampleRate)"
            )
        }
    }

    func testComputedCompactionBoundaryPreservesParityAtPendingAlignments() throws {
        let sampleRate = UInt32(44_100)
        let after = (0..<193).map { Float(cos(Double($0) * 0.053) * 0.35) }

        // Retained converter-input alignments 1, 4,095, and 0.
        for beforeCount in [1, 4_095, 4_096] {
            let before = (0..<beforeCount).map {
                Float(sin(Double($0) * 0.071) * 0.4)
            }
            let probe = try StreamingCanonicalSampleRateConverter(
                sourceSampleRateHz: sampleRate
            )
            _ = try probe.consume(before.map(Double.init))
            let bridge = Int(probe.unavailableDiscontinuityBridgeInputFrames)

            for gapFrames in [bridge, bridge + 1] {
                let imported = try canonicalImportPCM(
                    sampleRateHz: sampleRate,
                    channelCount: 2,
                    interleavedChunks: [
                        (before + Array(repeating: 0, count: gapFrames) + after)
                            .flatMap { [$0, $0] },
                    ]
                )
                let expected = silenceCanonicalFrames(
                    in: imported,
                    from: canonicalCeiling(UInt64(beforeCount), at: sampleRate),
                    through: canonicalCeiling(
                        UInt64(beforeCount + gapFrames),
                        at: sampleRate
                    )
                )
                let actual = try microphonePCMWithUnavailableZeros(
                    sampleRateHz: sampleRate,
                    before: before,
                    unavailableFrames: gapFrames,
                    after: after,
                    muted: false,
                    partitioned: false
                )

                XCTAssertEqual(
                    actual.pcm,
                    expected,
                    "before \(beforeCount), gap \(gapFrames)"
                )
                XCTAssertEqual(actual.pendingFrameCount, 0)
            }
        }
    }

    func testTwoCompactedGapsSeparatedByObservedAudioMatchUninterruptedConversion() throws {
        let sampleRate = UInt32(44_099)
        let before = (0..<127).map { Float(sin(Double($0) * 0.071) * 0.4) }
        let middle = (0..<211).map { Float(cos(Double($0) * 0.037) * 0.3) }
        let after = (0..<193).map { Float(sin(Double($0) * 0.029) * 0.35) }
        let firstGapFrames = 50_004
        let secondGapFrames = 50_007
        let uninterrupted = before
            + Array(repeating: Float.zero, count: firstGapFrames)
            + middle
            + Array(repeating: Float.zero, count: secondGapFrames)
            + after
        let imported = try canonicalImportPCM(
            sampleRateHz: sampleRate,
            channelCount: 2,
            interleavedChunks: [uninterrupted.flatMap { [$0, $0] }]
        )
        let firstGapStart = UInt64(before.count)
        let firstGapEnd = firstGapStart + UInt64(firstGapFrames)
        let secondGapStart = firstGapEnd + UInt64(middle.count)
        let secondGapEnd = secondGapStart + UInt64(secondGapFrames)
        var expected = silenceCanonicalFrames(
            in: imported,
            from: canonicalCeiling(firstGapStart, at: sampleRate),
            through: canonicalCeiling(firstGapEnd, at: sampleRate)
        )
        expected = silenceCanonicalFrames(
            in: expected,
            from: canonicalCeiling(secondGapStart, at: sampleRate),
            through: canonicalCeiling(secondGapEnd, at: sampleRate)
        )

        var assembler = CanonicalPCMAssembler()
        var spans = try assembler.consume(
            MicrophoneInputChunk(
                sampleRateHz: sampleRate,
                startSampleFrame: 0,
                channels: [before, before]
            ),
            muted: false
        )
        spans += try assembler.consumeGap(
            sampleRateHz: sampleRate,
            startSampleFrame: firstGapStart,
            frameCount: UInt64(firstGapFrames),
            channelCount: 2,
            muted: false
        )
        spans += try assembler.consume(
            MicrophoneInputChunk(
                sampleRateHz: sampleRate,
                startSampleFrame: firstGapEnd,
                channels: [middle, middle]
            ),
            muted: false
        )
        spans += try assembler.consumeGap(
            sampleRateHz: sampleRate,
            startSampleFrame: secondGapStart,
            frameCount: UInt64(secondGapFrames),
            channelCount: 2,
            muted: false
        )
        spans += try assembler.consume(
            MicrophoneInputChunk(
                sampleRateHz: sampleRate,
                startSampleFrame: secondGapEnd,
                channels: [after, after]
            ),
            muted: false
        )
        spans += try assembler.finish()

        let actual = spans.reduce(into: Data()) { pcm, span in
            pcm.append(
                span.pcmLittleEndian ?? Data(repeating: 0, count: Int(span.frameCount * 2))
            )
        }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(assembler.frameCount, UInt64(imported.count / 2))
        XCTAssertEqual(assembler.pendingFrameCount, 0)
    }

    func testTimingOnlyMutedIntervalHasOnlyMutedReasonAcrossCompactedGap() throws {
        var assembler = CanonicalPCMAssembler()
        try assembler.configure(sampleRateHz: 48_000, channelCount: 2)

        var spans = try assembler.consumeMutedInterval(
            sampleRateHz: 48_000,
            startSampleFrame: 0,
            frameCount: 50_004,
            channelCount: 2
        )
        spans += try assembler.finish()

        XCTAssertEqual(
            spans.reduce(0) { $0 + $1.frameCount },
            canonicalCeiling(50_004, at: 48_000)
        )
        XCTAssertTrue(spans.allSatisfy {
            $0.pcmLittleEndian == nil && $0.reasons == [.muted] && $0.level == nil
        })
    }

    func testTimedGapRequiresAndRetainsActualFeedFormatBeforeFirstCallback() throws {
        var assembler = CanonicalPCMAssembler()
        XCTAssertThrowsError(
            try assembler.consumeTimedGap(throughCanonicalFrame: 16_000, muted: true)
        ) { error in
            XCTAssertEqual(error as? CanonicalPCMAssemblerError, .unsupportedInputFormat)
        }

        try assembler.configure(sampleRateHz: 44_100, channelCount: 2)
        var spans = try assembler.consumeTimedGap(
            throughCanonicalFrame: 16_000,
            muted: true
        )
        let after = (0..<193).map { Float(sin(Double($0) * 0.029) * 0.3) }
        spans += try assembler.consume(
            MicrophoneInputChunk(
                sampleRateHz: 44_100,
                startSampleFrame: 44_100,
                channels: [after, after]
            ),
            muted: false
        )
        spans += try assembler.finish()

        XCTAssertEqual(
            spans.reduce(0) { $0 + $1.frameCount },
            canonicalFloor(44_100 + UInt64(after.count), at: 44_100)
        )
        XCTAssertEqual(assembler.pendingFrameCount, 0)
        XCTAssertTrue(spans.contains { $0.reasons.contains(.muted) })
        XCTAssertTrue(spans.contains { $0.reasons.isEmpty && $0.pcmLittleEndian != nil })
    }

    func testTimedGapHitsArbitraryCanonicalTargetsWithoutOvershoot() throws {
        for target in [UInt64(1), 37, 15_999] {
            var assembler = CanonicalPCMAssembler()
            try assembler.configure(sampleRateHz: 44_100, channelCount: 2)

            var spans = try assembler.consumeTimedGap(
                throughCanonicalFrame: target,
                muted: false
            )
            spans += try assembler.finish()

            XCTAssertEqual(spans.reduce(0) { $0 + $1.frameCount }, target)
            XCTAssertEqual(assembler.frameCount, target)
            XCTAssertEqual(assembler.pendingFrameCount, 0)
            XCTAssertTrue(spans.allSatisfy { $0.reasons == [.captureGap] })
        }
    }

    func testAssemblerExplicitlyRejectsSubcanonicalLiveInputRates() throws {
        var assembler = CanonicalPCMAssembler()
        XCTAssertThrowsError(
            try assembler.configure(sampleRateHz: 8_000, channelCount: 1)
        ) { error in
            XCTAssertEqual(error as? CanonicalPCMAssemblerError, .unsupportedInputFormat)
        }
    }

    func testRecordStreamCeilingCoversFortyFiveMinutesAtMaximumAcceptedLiveRate() {
        // Independent worked maximum: 1,012,500 callbacks, at most two
        // 49-byte records each, plus 43,200,000 canonical S16LE frames.
        XCTAssertGreaterThanOrEqual(
            RecordingPersistence.maximumRecordStreamBytes,
            185_625_008
        )
    }

    func testPersistenceSealsOneImmutableSessionWithNormalizedUnavailableIntervals() throws {
        try withRecordingLibrary { root, request in
            let persistence = RecordingPersistence()
            let handle = try persistence.prepare(request, under: root)
            try persistence.append(
                CanonicalPCMSpan(
                    frameCount: 4,
                    pcmLittleEndian: Data([1, 0, 2, 0, 3, 0, 4, 0]),
                    reasons: [],
                    level: 0.1
                ),
                to: handle
            )
            try persistence.append(
                CanonicalPCMSpan(
                    frameCount: 2,
                    pcmLittleEndian: nil,
                    reasons: [.muted],
                    level: nil
                ),
                to: handle
            )
            try persistence.append(
                CanonicalPCMSpan(
                    frameCount: 2,
                    pcmLittleEndian: nil,
                    reasons: [.captureGap, .muted],
                    level: nil
                ),
                to: handle
            )

            let receipt = try authoritativeSeal(persistence, handle, reason: .userStop)
            XCTAssertEqual(receipt.frameCount, 8)
            let sessionRoot = root.appendingPathComponent(
                "sessions/\(request.sessionID.rawValue)"
            )
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: sessionRoot.appendingPathComponent("session.json").path
            ))
            let wav = try Data(
                contentsOf: sessionRoot.appendingPathComponent("audio/audio.wav")
            )
            XCTAssertEqual(wav.count, 44 + 16)
            XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
            XCTAssertEqual(
                receipt.fingerprint.sha256,
                Data(SHA256.hash(data: wav)).map { String(format: "%02x", $0) }.joined()
            )

            let audioData = try Data(
                contentsOf: sessionRoot.appendingPathComponent("audio/audio.json")
            )
            let audio = try XCTUnwrap(
                JSONSerialization.jsonObject(with: audioData) as? [String: Any]
            )
            XCTAssertEqual(audio["frameCount"] as? Int, 8)
            let intervals = try XCTUnwrap(
                audio["unavailableIntervals"] as? [[String: Any]]
            )
            XCTAssertEqual(intervals.count, 2)
            XCTAssertEqual(intervals[0]["startFrame"] as? Int, 4)
            XCTAssertEqual(intervals[0]["endFrame"] as? Int, 6)
            XCTAssertEqual(intervals[1]["startFrame"] as? Int, 6)
            XCTAssertEqual(intervals[1]["endFrame"] as? Int, 8)

            let portableText = try XCTUnwrap(String(data: audioData, encoding: .utf8))
            for forbidden in ["absolutePath", "deviceId", "permission", root.path] {
                XCTAssertFalse(portableText.localizedCaseInsensitiveContains(forbidden))
            }
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "staging/recordings/\(request.recordingID.rawValue)"
                ).path
            ))
        }
    }

    func testRejectedFingerprintFixtureCannotInstallAgainstStagedWAV() throws {
        try withRecordingLibrary { root, request in
            let persistence = RecordingPersistence()
            let handle = try persistence.prepare(request, under: root)
            try persistence.append(observedSpan(frames: 4), to: handle)
            let candidate = try persistence.stageSeal(handle, reason: .userStop)
            let fixtureData = try Data(
                contentsOf: recordingRejectedFixture("audio-mismatched-fingerprint.json")
            )
            let fixture = try XCTUnwrap(
                JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
            )
            let mismatchedFingerprint = try XCTUnwrap(
                fixture["canonicalSha256"] as? String
            )
            XCTAssertNotEqual(mismatchedFingerprint, candidate.canonicalSHA256)
            let mismatched = StagedRecordingSealCandidate(
                recordingID: candidate.recordingID,
                sessionID: candidate.sessionID,
                libraryID: candidate.libraryID,
                startedAt: candidate.startedAt,
                terminalReason: candidate.terminalReason,
                sourceKind: candidate.sourceKind,
                canonicalAudioPath: candidate.canonicalAudioPath,
                sampleRateHz: candidate.sampleRateHz,
                channelCount: candidate.channelCount,
                encoding: candidate.encoding,
                frameCount: candidate.frameCount,
                canonicalSHA256: mismatchedFingerprint,
                unavailableIntervals: candidate.unavailableIntervals
            )
            // Lexically valid metadata becomes an authoritative aggregate only
            // after Application validation; Infrastructure still binds that
            // aggregate to the exact staged WAV before installation.
            let publication = try RecordingSealCandidateValidator.validate(
                mismatched,
                expected: request
            )

            XCTAssertThrowsError(try persistence.install(publication, using: handle)) {
                XCTAssertEqual($0 as? RecordingPersistenceError, .invalidStaging)
            }
            XCTAssertEqual(try sessionNames(root), [])
            XCTAssertEqual(try recordingStagingNames(root), [request.recordingID.rawValue])
        }
    }

    func testSessionDestinationCollisionNeverOverwritesOrMerges() throws {
        try withRecordingLibrary { root, request in
            let persistence = RecordingPersistence()
            let handle = try persistence.prepare(request, under: root)
            try persistence.append(observedSpan(frames: 4), to: handle)
            let destination = root.appendingPathComponent(
                "sessions/\(request.sessionID.rawValue)"
            )
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let sentinel = destination.appendingPathComponent("sentinel.txt")
            try Data("keep".utf8).write(to: sentinel)

            XCTAssertThrowsError(try authoritativeSeal(persistence, handle, reason: .userStop)) { error in
                XCTAssertEqual(error as? RecordingPersistenceError, .destinationCollision)
            }
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "staging/recordings/\(request.recordingID.rawValue)/recording.json"
                ).path
            ))
        }
    }

    func testDiscardRemovesOnlyExactIncompleteStagingAndPreservesSiblings() throws {
        try withRecordingLibrary { root, request in
            let persistence = RecordingPersistence()
            let handle = try persistence.prepare(request, under: root)
            try persistence.append(observedSpan(frames: 4), to: handle)
            let sibling = root.appendingPathComponent("staging/recordings/sibling-sentinel")
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
            let sentinel = sibling.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: sentinel)

            try persistence.discard(handle)
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "staging/recordings/\(request.recordingID.rawValue)"
                ).path
            ))
        }
    }

    func testRecoveryDiscardRemovesOnlyInvalidTargetAndNeverFollowsItsEvidenceSymlink() throws {
        try withRecordingLibrary { root, request in
            let persistence = RecordingPersistence()
            let target = try persistence.prepare(request, under: root)
            try persistence.append(observedSpan(frames: 4), to: target)
            target.closeCaptureStream()

            let siblingRequest = MicrophoneRecordingRequest(
                libraryScope: request.libraryScope,
                recordingID: try RecordingID("rec-20260830T120001000Z-4GHJ"),
                sessionID: try SessionID("ses-20260830T120001000Z-5JKM"),
                startedAt: try UTCInstant("2026-08-30T12:00:01.000Z")
            )
            let sibling = try persistence.prepare(siblingRequest, under: root)
            try persistence.append(observedSpan(frames: 8), to: sibling)

            let outside = root.deletingLastPathComponent().appendingPathComponent(
                "outside-evidence.bin"
            )
            let outsideBytes = Data("not recording evidence".utf8)
            try outsideBytes.write(to: outside)
            let targetStream = root.appendingPathComponent(
                "staging/recordings/\(request.recordingID.rawValue)/records.bin"
            )
            try FileManager.default.removeItem(at: targetStream)
            try FileManager.default.createSymbolicLink(
                at: targetStream,
                withDestinationURL: outside
            )

            let catalog = persistence.inspectRecovery(
                in: request.libraryScope,
                under: root
            )
            XCTAssertEqual(
                Dictionary(uniqueKeysWithValues: catalog.items.map {
                    ($0.recordingID, $0.availability)
                }),
                [
                    request.recordingID: .discardOnly,
                    siblingRequest.recordingID: .sealOrDiscard,
                ]
            )

            try persistence.discardRecovery(
                recordingID: request.recordingID,
                in: request.libraryScope,
                under: root
            )

            XCTAssertEqual(try Data(contentsOf: outside), outsideBytes)
            XCTAssertEqual(
                try recordingStagingNames(root),
                [siblingRequest.recordingID.rawValue]
            )
            let remaining = persistence.inspectRecovery(
                in: siblingRequest.libraryScope,
                under: root
            )
            XCTAssertEqual(remaining.items.count, 1)
            XCTAssertEqual(remaining.items[0].recordingID, siblingRequest.recordingID)
            XCTAssertEqual(remaining.items[0].availability, .sealOrDiscard)
        }
    }

    func testDiscardPreflightsUnexpectedChildAndLeavesRecoverableIdentityIntact() throws {
        try withRecordingLibrary { root, request in
            let persistence = RecordingPersistence()
            let handle = try persistence.prepare(request, under: root)
            try persistence.append(observedSpan(frames: 4), to: handle)
            let staging = root.appendingPathComponent(
                "staging/recordings/\(request.recordingID.rawValue)"
            )
            let unexpected = staging.appendingPathComponent("unexpected-sentinel")
            try Data("keep".utf8).write(to: unexpected)

            XCTAssertThrowsError(try persistence.discard(handle)) { error in
                XCTAssertEqual(error as? RecordingPersistenceError, .unsafeEntry)
            }
            XCTAssertEqual(try Data(contentsOf: unexpected), Data("keep".utf8))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: staging.appendingPathComponent("identity.json").path
            ))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: staging.appendingPathComponent("recording.json").path
            ))
        }
    }

    func testArbitraryTrailingEvidenceAfterDurableWatermarkIsDiscardOnly() throws {
        try withRecordingLibrary { root, request in
            let persistence = RecordingPersistence()
            let handle = try persistence.prepare(request, under: root)
            try persistence.append(observedSpan(frames: 4), to: handle)
            let stream = root.appendingPathComponent(
                "staging/recordings/\(request.recordingID.rawValue)/records.bin"
            )
            let file = try FileHandle(forWritingTo: stream)
            try file.seekToEnd()
            try file.write(contentsOf: Data([0xFF, 0x00, 0x01]))
            try file.close()

            let catalog = persistence.inspectRecovery(
                in: request.libraryScope,
                under: root
            )
            XCTAssertEqual(catalog.items.count, 1)
            XCTAssertEqual(catalog.items[0].availability, .discardOnly)
            XCTAssertEqual(catalog.items[0].durableFrameCount, 4)
        }
    }

    func testCompleteTrailingRecordAfterDurableWatermarkIsDiscardOnly() throws {
        try withRecordingLibrary { root, request in
            let persistence = RecordingPersistence { point in
                if point == .afterRecordFlush {
                    throw RecordingPersistenceError.injectedFault(point)
                }
            }
            let handle = try persistence.prepare(request, under: root)
            XCTAssertThrowsError(try persistence.append(observedSpan(frames: 4), to: handle))

            let catalog = RecordingPersistence().inspectRecovery(
                in: request.libraryScope,
                under: root
            )
            XCTAssertEqual(catalog.items.first?.availability, .discardOnly)
            XCTAssertEqual(catalog.items.first?.durableFrameCount, 0)
        }
    }

    func testStagingIsRecordingIDKeyedAndMismatchedIdentityRemainsVisibleReadOnly() throws {
        try withRecordingLibrary { root, request in
            _ = try RecordingPersistence().prepare(request, under: root)
            XCTAssertEqual(try recordingStagingNames(root), [request.recordingID.rawValue])
            let identityURL = root.appendingPathComponent(
                "staging/recordings/\(request.recordingID.rawValue)/identity.json"
            )
            var identity = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: identityURL)) as? [String: Any]
            )
            identity["recordingId"] = "rec-20260830T120000000Z-9XYZ"
            let mismatched = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])
            try mismatched.write(to: identityURL)

            let catalog = RecordingPersistence().inspectRecovery(
                in: request.libraryScope,
                under: root
            )
            XCTAssertFalse(catalog.isClear)
            XCTAssertEqual(catalog.items.first?.recordingID, request.recordingID)
            XCTAssertEqual(catalog.items.first?.availability, .readOnlyUnsupported)
            XCTAssertNil(catalog.items.first?.sessionID)
            XCTAssertThrowsError(
                try RecordingPersistence().discardRecovery(
                    recordingID: request.recordingID,
                    in: request.libraryScope,
                    under: root
                )
            )
            XCTAssertEqual(try Data(contentsOf: identityURL), mismatched)
        }
    }

    func testNewerRecordingIdentityIsBytePreservedAndNeverDiscardable() throws {
        try withRecordingLibrary { root, request in
            _ = try RecordingPersistence().prepare(request, under: root)
            let identityURL = root.appendingPathComponent(
                "staging/recordings/\(request.recordingID.rawValue)/identity.json"
            )
            var identity = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: identityURL)) as? [String: Any]
            )
            identity["schemaVersion"] = 2
            identity["futureField"] = ["opaque": true]
            let newer = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])
            try newer.write(to: identityURL)

            let catalog = RecordingPersistence().inspectRecovery(
                in: request.libraryScope,
                under: root
            )
            XCTAssertEqual(catalog.items.first?.availability, .readOnlyNewerSchema)
            XCTAssertThrowsError(
                try RecordingPersistence().discardRecovery(
                    recordingID: request.recordingID,
                    in: request.libraryScope,
                    under: root
                )
            )
            XCTAssertEqual(try Data(contentsOf: identityURL), newer)
        }
    }

    func testOverBudgetRecoveryDirectoryBlocksCaptureAndPreservesEveryEntry() throws {
        try withRecordingLibrary { root, request in
            let recordings = root.appendingPathComponent("staging/recordings")
            for index in 0...RecordingPersistence.maximumRecordingStagingEntryCount {
                try FileManager.default.createDirectory(
                    at: recordings.appendingPathComponent("unknown-\(index)"),
                    withIntermediateDirectories: false
                )
            }
            let before = try recordingStagingNames(root)

            let catalog = RecordingPersistence().inspectRecovery(
                in: request.libraryScope,
                under: root
            )

            XCTAssertEqual(catalog.inspectionStatus, .blocked(.stagingListingUnavailable))
            XCTAssertEqual(try recordingStagingNames(root), before)
        }
    }

    func testUnrecognizedRecordingStagingEntryBlocksCaptureAndIsPreserved() throws {
        try withRecordingLibrary { root, request in
            let unknown = root.appendingPathComponent("staging/recordings/unknown-root")
            try FileManager.default.createDirectory(
                at: unknown,
                withIntermediateDirectories: false
            )
            let sentinel = unknown.appendingPathComponent("keep.bin")
            try Data([0x01, 0x02]).write(to: sentinel)

            let catalog = RecordingPersistence().inspectRecovery(
                in: request.libraryScope,
                under: root
            )

            XCTAssertEqual(catalog.inspectionStatus, .blocked(.stagingListingUnavailable))
            XCTAssertEqual(try Data(contentsOf: sentinel), Data([0x01, 0x02]))
        }
    }

    func testOwnedCrashPartialsReconcileOnlyWhenCurrentAndStructurallyExact() throws {
        try withRecordingLibrary { root, request in
            let persistence = RecordingPersistence()
            _ = try persistence.prepare(request, under: root)
            let recordings = root.appendingPathComponent("staging/recordings")
            let installed = recordings.appendingPathComponent(request.recordingID.rawValue)
            let partialName = ".\(request.recordingID.rawValue).00000000-0000-0000-0000-000000000001.partial"
            let partial = recordings.appendingPathComponent(partialName)
            try FileManager.default.moveItem(at: installed, to: partial)

            XCTAssertTrue(
                RecordingPersistence().inspectRecovery(in: request.libraryScope, under: root).isClear
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))

            _ = try persistence.prepare(request, under: root)
            try FileManager.default.moveItem(at: installed, to: partial)
            let sentinel = partial.appendingPathComponent("unknown-sentinel")
            try Data("keep".utf8).write(to: sentinel)
            let blocked = RecordingPersistence().inspectRecovery(
                in: request.libraryScope,
                under: root
            )
            XCTAssertEqual(blocked.inspectionStatus, .blocked(.stagingListingUnavailable))
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        }
    }

    func testManifestScratchReconciliationPreservesNewerScratch() throws {
        try withRecordingLibrary { root, request in
            _ = try RecordingPersistence().prepare(request, under: root)
            let staging = root.appendingPathComponent(
                "staging/recordings/\(request.recordingID.rawValue)"
            )
            let manifest = try Data(contentsOf: staging.appendingPathComponent("recording.json"))
            let currentScratch = staging.appendingPathComponent(
                ".recording.00000000-0000-0000-0000-000000000001.partial"
            )
            try manifest.write(to: currentScratch)
            _ = RecordingPersistence().inspectRecovery(in: request.libraryScope, under: root)
            XCTAssertFalse(FileManager.default.fileExists(atPath: currentScratch.path))

            var newerObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: manifest) as? [String: Any]
            )
            newerObject["schemaVersion"] = 2
            let newer = try JSONSerialization.data(withJSONObject: newerObject, options: [.sortedKeys])
            let newerScratch = staging.appendingPathComponent(
                ".recording.00000000-0000-0000-0000-000000000002.partial"
            )
            try newer.write(to: newerScratch)
            let catalog = RecordingPersistence().inspectRecovery(
                in: request.libraryScope,
                under: root
            )
            XCTAssertEqual(catalog.items.first?.availability, .readOnlyUnsupported)
            XCTAssertEqual(try Data(contentsOf: newerScratch), newer)
        }
    }

    func testStreamingSealRejectsFiniteRecordAndIntervalBudgets() throws {
        try withRecordingLibrary { root, request in
            let persistence = RecordingPersistence(recordLimit: 2, unavailableIntervalLimit: 1)
            let handle = try persistence.prepare(request, under: root)
            try persistence.append(unavailableSpan(frames: 1, reasons: [.muted]), to: handle)
            try persistence.append(unavailableSpan(frames: 1, reasons: [.captureGap]), to: handle)
            XCTAssertThrowsError(try persistence.stageSeal(handle, reason: .userStop)) {
                XCTAssertEqual($0 as? RecordingPersistenceError, .recordStreamTooLarge)
            }
            XCTAssertEqual(try sessionNames(root), [])
        }
    }

    func testDiscardOnlyRecoveryDoesNotRequireMutableManifestToDecode() throws {
        try withRecordingLibrary { root, request in
            let persistence = RecordingPersistence()
            _ = try persistence.prepare(request, under: root)
            let staging = root.appendingPathComponent(
                "staging/recordings/\(request.recordingID.rawValue)"
            )
            try Data("not-json".utf8).write(
                to: staging.appendingPathComponent("recording.json")
            )

            let catalog = persistence.inspectRecovery(
                in: request.libraryScope,
                under: root
            )
            XCTAssertEqual(catalog.items.count, 1)
            XCTAssertEqual(catalog.items[0].availability, .discardOnly)

            try persistence.discardRecovery(
                recordingID: request.recordingID,
                in: request.libraryScope,
                under: root
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        }
    }

    func testPrepareAndAppendFaultsLeaveOnlyHonestRecoverableStates() throws {
        for point in [
            RecordingPersistenceFaultPoint.afterStagingDirectoryCreate,
            .afterIdentityFlush,
        ] {
            try withRecordingLibrary { root, request in
                let persistence = RecordingPersistence { reached in
                    if reached == point { throw RecordingPersistenceError.injectedFault(point) }
                }
                XCTAssertThrowsError(try persistence.prepare(request, under: root))
                XCTAssertEqual(try recordingStagingNames(root), [], point.rawValue)
                XCTAssertEqual(try sessionNames(root), [], point.rawValue)
            }
        }

        for point in [
            RecordingPersistenceFaultPoint.afterRecordFlush,
            .afterWatermarkFlush,
        ] {
            try withRecordingLibrary { root, request in
                let persistence = RecordingPersistence { reached in
                    if reached == point { throw RecordingPersistenceError.injectedFault(point) }
                }
                let handle = try persistence.prepare(request, under: root)
                XCTAssertThrowsError(try persistence.append(observedSpan(frames: 4), to: handle))
                let catalog = RecordingPersistence().inspectRecovery(
                    in: request.libraryScope,
                    under: root
                )
                XCTAssertEqual(catalog.items.count, 1, point.rawValue)
                XCTAssertEqual(
                    catalog.items[0].availability,
                    point == .afterRecordFlush ? .discardOnly : .sealOrDiscard,
                    point.rawValue
                )
                XCTAssertEqual(try sessionNames(root), [], point.rawValue)
            }
        }
    }

    func testSealFaultMatrixNeverLeaksSessionCandidateAndReconcilesInstalledCommit() throws {
        let preInstallPoints: [RecordingPersistenceFaultPoint] = [
            .beforeSealScan,
            .afterCanonicalAudioFlush,
            .afterAudioManifestFlush,
            .afterSessionManifestFlush,
            .beforeSessionInstall,
        ]
        for point in preInstallPoints {
            try withRecordingLibrary { root, request in
                let persistence = RecordingPersistence { reached in
                    if reached == point { throw RecordingPersistenceError.injectedFault(point) }
                }
                let handle = try persistence.prepare(request, under: root)
                try persistence.append(observedSpan(frames: 4), to: handle)
                XCTAssertThrowsError(try authoritativeSeal(persistence, handle, reason: .userStop))
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(
                        "sessions/\(request.sessionID.rawValue)"
                    ).path
                ), point.rawValue)
                XCTAssertEqual(
                    persistence.inspectRecovery(in: request.libraryScope, under: root)
                        .items.first?.availability,
                    .sealOrDiscard,
                    point.rawValue
                )
                XCTAssertEqual(try sessionNames(root), [], point.rawValue)
                let stagedCandidateExists = FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(
                        "staging/recordings/\(request.recordingID.rawValue)/seal-candidate"
                    ).path
                )
                XCTAssertEqual(
                    stagedCandidateExists,
                    [.afterAudioManifestFlush, .afterSessionManifestFlush, .beforeSessionInstall]
                        .contains(point),
                    point.rawValue
                )
            }
        }

        for point in [
            RecordingPersistenceFaultPoint.afterSessionInstall,
            .afterSessionsDirectoryFlush,
            .beforeInstalledSessionValidation,
        ] {
            try withRecordingLibrary { root, request in
                let persistence = RecordingPersistence { reached in
                    if reached == point { throw RecordingPersistenceError.injectedFault(point) }
                }
                let handle = try persistence.prepare(request, under: root)
                try persistence.append(observedSpan(frames: 4), to: handle)
                let receipt = try authoritativeSeal(persistence, handle, reason: .userStop)
                XCTAssertEqual(receipt.sessionID, request.sessionID, point.rawValue)
                XCTAssertEqual(try sessionNames(root), [request.sessionID.rawValue], point.rawValue)
                XCTAssertEqual(
                    RecordingPersistence().inspectRecovery(
                        in: request.libraryScope,
                        under: root
                    ).items,
                    [],
                    point.rawValue
                )
                XCTAssertEqual(try recordingStagingNames(root), [], point.rawValue)
            }
        }

        try withRecordingLibrary { root, request in
            let point = RecordingPersistenceFaultPoint.beforeStagingCleanup
            let persistence = RecordingPersistence { reached in
                if reached == point { throw RecordingPersistenceError.injectedFault(point) }
            }
            let handle = try persistence.prepare(request, under: root)
            try persistence.append(observedSpan(frames: 4), to: handle)
            let receipt: SessionSealedReceipt
            do {
                receipt = try authoritativeSeal(persistence, handle, reason: .userStop)
            } catch {
                XCTFail("initial committed publication failed: \(error)")
                return
            }
            XCTAssertEqual(receipt.sessionID, request.sessionID)
            XCTAssertEqual(try sessionNames(root), [request.sessionID.rawValue])
            XCTAssertEqual(
                try recordingStagingNames(root),
                [request.recordingID.rawValue]
            )

            let relaunched = RecordingPersistence().inspectRecovery(
                in: request.libraryScope,
                under: root
            )
            XCTAssertEqual(relaunched.items, [])
            XCTAssertEqual(relaunched.reconciledSeals, [receipt])
            XCTAssertEqual(try recordingStagingNames(root), [])
        }
    }

    func testDiscardOnlyIntentSurvivesRelaunchEvenWhenStreamIsValid() throws {
        try withRecordingLibrary { root, request in
            let persistence = RecordingPersistence()
            let handle = try persistence.prepare(request, under: root)
            try persistence.append(observedSpan(frames: 4), to: handle)
            try persistence.markRecoverable(handle, availability: .discardOnly)

            let catalog = RecordingPersistence().inspectRecovery(
                in: request.libraryScope,
                under: root
            )
            XCTAssertEqual(catalog.items.first?.availability, .discardOnly)
            let recovered = try persistence.openRecovery(
                recordingID: request.recordingID,
                in: request.libraryScope,
                under: root
            )
            XCTAssertThrowsError(
                try authoritativeSeal(persistence, recovered, reason: .interruption)
            )
        }
    }

    func testRecoveryRecordStreamIsOpenedReadOnly() throws {
        try withRecordingLibrary { root, request in
            let persistence = RecordingPersistence()
            let capture = try persistence.prepare(request, under: root)
            try persistence.append(observedSpan(frames: 4), to: capture)
            try persistence.markRecoverable(capture, availability: .sealOrDiscard)
            capture.closeCaptureStream()

            let recovery = try persistence.openRecovery(
                recordingID: request.recordingID,
                in: request.libraryScope,
                under: root
            )

            let flags = fcntl(recovery.streamDescriptor, F_GETFL)
            XCTAssertGreaterThanOrEqual(flags, 0)
            XCTAssertEqual(flags & O_ACCMODE, O_RDONLY)
        }
    }

    func testCommittedCleanupExposesReceiptBeforeExactCleanupCompletes() throws {
        try withRecordingLibrary { root, request in
            let staging = root.appendingPathComponent(
                "staging/recordings/\(request.recordingID.rawValue)"
            )
            let unexpected = staging.appendingPathComponent("unexpected-sentinel")
            let persistence = RecordingPersistence { point in
                if point == .beforeStagingCleanup {
                    try Data("keep".utf8).write(to: unexpected)
                    throw RecordingPersistenceError.injectedFault(point)
                }
            }
            let handle = try persistence.prepare(request, under: root)
            try persistence.append(observedSpan(frames: 4), to: handle)
            let candidate = try persistence.stageSeal(handle, reason: .userStop)
            let publication = try RecordingSealCandidateValidator.validate(
                candidate,
                expected: request
            )
            let receipt = publication.receipt
            XCTAssertEqual(
                try persistence.install(publication, using: handle),
                receipt
            )

            let unresolved = RecordingPersistence().inspectRecovery(
                in: request.libraryScope,
                under: root
            )
            XCTAssertEqual(unresolved.reconciledSeals, [receipt])
            XCTAssertEqual(unresolved.items.first?.availability, .committedCleanup)
            XCTAssertThrowsError(
                try RecordingPersistence().discardRecovery(
                    recordingID: request.recordingID,
                    in: request.libraryScope,
                    under: root
                )
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: staging.path).sorted(),
                ["identity.json", "recording.json", "records.bin", "unexpected-sentinel"]
            )

            try FileManager.default.removeItem(at: unexpected)
            let resolved = RecordingPersistence().inspectRecovery(
                in: request.libraryScope,
                under: root
            )
            XCTAssertEqual(resolved.reconciledSeals, [receipt])
            XCTAssertEqual(resolved.items, [])
            let repeated = RecordingPersistence().inspectRecovery(
                in: request.libraryScope,
                under: root
            )
            XCTAssertEqual(repeated.reconciledSeals, [])
            XCTAssertEqual(repeated.items, [])
            XCTAssertEqual(try recordingStagingNames(root), [])
            XCTAssertEqual(try sessionNames(root), [request.sessionID.rawValue])
        }
    }

    func testCanonicalLibraryAuthorityIsRevalidatedBeforeStagingAndInstall() throws {
        try withRecordingLibrary { root, request in
            let manifestURL = root.appendingPathComponent("library.json")
            let original = try Data(contentsOf: manifestURL)
            var newer = try XCTUnwrap(
                JSONSerialization.jsonObject(with: original) as? [String: Any]
            )
            newer["schemaVersion"] = 2
            let newerData = try JSONSerialization.data(withJSONObject: newer, options: [.sortedKeys])
            try newerData.write(to: manifestURL)
            XCTAssertThrowsError(try RecordingPersistence().prepare(request, under: root)) {
                XCTAssertEqual($0 as? RecordingPersistenceError, .invalidLibraryAuthority)
            }
            XCTAssertEqual(try recordingStagingNames(root), [])

            try original.write(to: manifestURL)
            let persistence = RecordingPersistence { point in
                if point == .beforeSessionInstall { try newerData.write(to: manifestURL) }
            }
            let handle = try persistence.prepare(request, under: root)
            try persistence.append(observedSpan(frames: 4), to: handle)
            XCTAssertThrowsError(
                try authoritativeSeal(persistence, handle, reason: .userStop)
            ) {
                XCTAssertEqual($0 as? RecordingPersistenceError, .invalidLibraryAuthority)
            }
            XCTAssertEqual(try sessionNames(root), [])
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "staging/recordings/\(request.recordingID.rawValue)/seal-candidate"
                ).path
            ))

            try original.write(to: manifestURL)
            let recovered = try RecordingPersistence().openRecovery(
                recordingID: request.recordingID,
                in: request.libraryScope,
                under: root
            )
            XCTAssertEqual(
                try authoritativeSeal(
                    RecordingPersistence(),
                    recovered,
                    reason: .interruption
                ).sessionID,
                request.sessionID
            )
        }
    }

    func testPostInstallAuthorityFailureRetainsPublicationForRelaunchReconciliation() throws {
        try withRecordingLibrary { root, request in
            let manifestURL = root.appendingPathComponent("library.json")
            let original = try Data(contentsOf: manifestURL)
            var corrupt = try XCTUnwrap(
                JSONSerialization.jsonObject(with: original) as? [String: Any]
            )
            corrupt["formatName"] = "not-audora"
            let corruptData = try JSONSerialization.data(withJSONObject: corrupt, options: [.sortedKeys])
            let persistence = RecordingPersistence { point in
                if point == .afterSessionInstall { try corruptData.write(to: manifestURL) }
            }
            let handle = try persistence.prepare(request, under: root)
            try persistence.append(observedSpan(frames: 4), to: handle)
            XCTAssertThrowsError(
                try authoritativeSeal(persistence, handle, reason: .userStop)
            ) {
                XCTAssertEqual($0 as? RecordingPersistenceError, .invalidLibraryAuthority)
            }
            XCTAssertEqual(
                persistence.recoveryAvailability(for: handle),
                .committedCleanup
            )
            XCTAssertEqual(try sessionNames(root), [request.sessionID.rawValue])
            XCTAssertEqual(try recordingStagingNames(root), [request.recordingID.rawValue])

            try original.write(to: manifestURL)
            let catalog = RecordingPersistence().inspectRecovery(
                in: request.libraryScope,
                under: root
            )
            XCTAssertEqual(catalog.items, [])
            XCTAssertEqual(catalog.reconciledSeals.count, 1)
            XCTAssertEqual(catalog.reconciledSeals[0].sessionID, request.sessionID)
            XCTAssertEqual(try recordingStagingNames(root), [])
        }
    }

    private func observedSpan(frames: UInt64) -> CanonicalPCMSpan {
        CanonicalPCMSpan(
            frameCount: frames,
            pcmLittleEndian: Data(repeating: 1, count: Int(frames * 2)),
            reasons: [],
            level: 0.2
        )
    }

    private func unavailableSpan(
        frames: UInt64,
        reasons: Set<UnavailableReason>
    ) -> CanonicalPCMSpan {
        CanonicalPCMSpan(
            frameCount: frames,
            pcmLittleEndian: nil,
            reasons: reasons,
            level: nil
        )
    }

    private func authoritativeSeal(
        _ persistence: RecordingPersistence,
        _ handle: RecordingStagingHandle,
        reason: CaptureTerminalReason
    ) throws -> SessionSealedReceipt {
        let candidate = try persistence.stageSeal(handle, reason: reason)
        let publication = try RecordingSealCandidateValidator.validate(
            candidate,
            expected: handle.request
        )
        return try persistence.install(publication, using: handle)
    }

    private func authoritativeSeal(
        _ persistence: RecordingPersistence,
        _ handle: RecordingRecoveryHandle,
        reason: CaptureTerminalReason
    ) throws -> SessionSealedReceipt {
        let candidate = try persistence.stageSeal(handle, reason: reason)
        let publication = try RecordingSealCandidateValidator.validate(
            candidate,
            expected: handle.request
        )
        return try persistence.install(publication, using: handle)
    }

    private func canonicalImportPCM(
        sampleRateHz: UInt32,
        channelCount: UInt32,
        interleavedChunks: [[Float]]
    ) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-cross-acquisition-\(UUID().uuidString).wav"
        )
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer {
            _ = Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: url)
        }
        let frameCount = interleavedChunks.reduce(0) {
            $0 + $1.count / Int(channelCount)
        }
        let normalizer = try StreamingCanonicalAudioNormalizer(
            description: InspectedAudio(
                codec: .linearPCM,
                sampleRateHz: sampleRateHz,
                channelCount: channelCount,
                metadataDurationSeconds: Double(frameCount) / Double(sampleRateHz)
            ),
            destinationDescriptor: descriptor,
            maximumFrameCount: UInt64(frameCount * 4)
        )
        for chunk in interleavedChunks {
            try normalizer.consume(
                DecodedPCMChunk(
                    interleavedSamples: chunk,
                    frameCount: chunk.count / Int(channelCount),
                    channelCount: Int(channelCount),
                    sampleRateHz: sampleRateHz
                )
            )
        }
        _ = try normalizer.finish()
        return Data(try Data(contentsOf: url).dropFirst(44))
    }

    private func canonicalMicrophonePCM(
        sampleRateHz: UInt32,
        channels: [[Float]],
        partitions: [Range<Int>]
    ) throws -> Data {
        var assembler = CanonicalPCMAssembler()
        var pcm = Data()
        for range in partitions {
            let spans = try assembler.consume(
                MicrophoneInputChunk(
                    sampleRateHz: sampleRateHz,
                    startSampleFrame: UInt64(range.lowerBound),
                    channels: channels.map { Array($0[range]) }
                ),
                muted: false
            )
            for span in spans { pcm.append(try XCTUnwrap(span.pcmLittleEndian)) }
        }
        for span in try assembler.finish() {
            pcm.append(try XCTUnwrap(span.pcmLittleEndian))
        }
        return pcm
    }

    private struct UnavailableInterval: Equatable {
        let start: UInt64
        let end: UInt64
        let reasons: Set<UnavailableReason>
    }

    private func microphonePCMWithUnavailableZeros(
        sampleRateHz: UInt32,
        before: [Float],
        unavailableFrames: Int,
        after: [Float],
        muted: Bool,
        partitioned: Bool,
        withheld: [Float]? = nil
    ) throws -> (
        pcm: Data,
        unavailable: [UnavailableInterval],
        frameCount: UInt64,
        pendingFrameCount: UInt64
    ) {
        var assembler = CanonicalPCMAssembler()
        var spans: [CanonicalPCMSpan] = []
        func consume(_ samples: [Float], at start: Int, muted: Bool) throws {
            spans += try assembler.consume(
                MicrophoneInputChunk(
                    sampleRateHz: sampleRateHz,
                    startSampleFrame: UInt64(start),
                    channels: [samples, samples]
                ),
                muted: muted
            )
        }
        if partitioned {
            try consume(Array(before[..<41]), at: 0, muted: false)
            try consume(Array(before[41...]), at: 41, muted: false)
        } else {
            try consume(before, at: 0, muted: false)
        }
        let unavailableStart = before.count
        if muted {
            try consume(
                withheld ?? Array(repeating: 0.25, count: unavailableFrames),
                at: unavailableStart,
                muted: true
            )
        } else {
            spans += try assembler.consumeGap(
                sampleRateHz: sampleRateHz,
                startSampleFrame: UInt64(unavailableStart),
                frameCount: UInt64(unavailableFrames),
                channelCount: 2,
                muted: false
            )
        }
        let afterStart = unavailableStart + unavailableFrames
        if partitioned {
            try consume(Array(after[..<73]), at: afterStart, muted: false)
            try consume(Array(after[73...]), at: afterStart + 73, muted: false)
        } else {
            try consume(after, at: afterStart, muted: false)
        }
        spans += try assembler.finish()

        var pcm = Data()
        var unavailable: [UnavailableInterval] = []
        var offset: UInt64 = 0
        for span in spans {
            if let observed = span.pcmLittleEndian {
                pcm.append(observed)
            } else {
                pcm.append(Data(repeating: 0, count: Int(span.frameCount * 2)))
                let interval = UnavailableInterval(
                    start: offset,
                    end: offset + span.frameCount,
                    reasons: span.reasons
                )
                if let last = unavailable.last,
                   last.end == interval.start,
                   last.reasons == interval.reasons
                {
                    unavailable[unavailable.count - 1] = UnavailableInterval(
                        start: last.start, end: interval.end, reasons: last.reasons
                    )
                } else {
                    unavailable.append(interval)
                }
            }
            offset += span.frameCount
        }
        return (pcm, unavailable, assembler.frameCount, assembler.pendingFrameCount)
    }

    private func canonicalCeiling(_ sourceFrame: UInt64, at sampleRateHz: UInt32) -> UInt64 {
        (sourceFrame * CanonicalRecordingLimits.sampleRate + UInt64(sampleRateHz) - 1) /
            UInt64(sampleRateHz)
    }

    private func canonicalFloor(_ sourceFrame: UInt64, at sampleRateHz: UInt32) -> UInt64 {
        sourceFrame * CanonicalRecordingLimits.sampleRate / UInt64(sampleRateHz)
    }

    private func silenceCanonicalFrames(in pcm: Data, from start: UInt64, through end: UInt64) -> Data {
        var result = pcm
        result.replaceSubrange(Int(start * 2)..<Int(end * 2), with: Data(repeating: 0, count: Int((end - start) * 2)))
        return result
    }
}

private func withRecordingLibrary(
    _ body: (URL, MicrophoneRecordingRequest) throws -> Void
) throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
        "audora-recording-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("Synthetic.audoralibrary", isDirectory: true)
    let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
    let libraryID = try LibraryID("lib-20260830T120000000Z-1ABC")
    _ = try PortableLibraryPersistence().create(
        at: root,
        seed: NewLibrarySeed(
            libraryID: libraryID,
            createdAt: instant,
            preferences: .defaults,
            profileHead: ProfileHead(
                generation: 0,
                statementGeneration: 0,
                selection: .null,
                updatedAt: instant
            )
        )
    )
    let request = MicrophoneRecordingRequest(
        libraryScope: LibraryScope(libraryID: libraryID),
        recordingID: try RecordingID("rec-20260830T120000000Z-2ABC"),
        sessionID: try SessionID("ses-20260830T120000000Z-3DEF"),
        startedAt: instant
    )
    try body(root, request)
}

private func recordingStagingNames(_ root: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("staging/recordings").path
    ).sorted()
}

private func sessionNames(_ root: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("sessions").path
    ).sorted()
}

private func recordingRejectedFixture(_ name: String) -> URL {
    var repositoryRoot = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repositoryRoot.deleteLastPathComponent() }
    return repositoryRoot.appendingPathComponent(
        "Packages/AudoraCore/Sources/AudoraContracts/Resources/Examples/Recording/v1/rejected/\(name)"
    )
}
