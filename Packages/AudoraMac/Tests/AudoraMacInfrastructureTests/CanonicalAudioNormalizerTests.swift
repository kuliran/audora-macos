import AudoraApplication
import AudoraDomain
@testable import AudoraMacInfrastructure
import CryptoKit
import Darwin
import Foundation
import XCTest

final class CanonicalAudioNormalizerTests: XCTestCase {
    func testStereoDownmixUsesArithmeticMeanInDouble() throws {
        XCTAssertEqual(
            try StreamingCanonicalAudioNormalizer.downmix(
                [1, -1, 0.75, 0.25, -0.5, -0.25],
                frameCount: 3,
                channelCount: 2
            ),
            [0, 0.5, -0.375]
        )
        XCTAssertEqual(
            try StreamingCanonicalAudioNormalizer.downmix(
                [0.25, -0.5],
                frameCount: 2,
                channelCount: 1
            ),
            [0.25, -0.5]
        )
    }

    func testStereoMeanBelowHalfLSBDoesNotRoundUpBeforeQuantization() throws {
        let oneLSB = Float(1.0 / 32_768.0)
        let result = try normalize(
            sampleRate: 16_000,
            channelCount: 2,
            chunks: [[0, oneLSB.nextDown]],
            maximumFrames: 1
        )

        XCTAssertEqual(result.summary.frameCount, 1)
        XCTAssertEqual(Array(result.bytes.dropFirst(44)), [0x00, 0x00])
    }

    func testDownmixRejectsUnsupportedChannelsAndNonfiniteSamples() {
        XCTAssertThrowsError(
            try StreamingCanonicalAudioNormalizer.downmix(
                [0, 0, 0],
                frameCount: 1,
                channelCount: 3
            )
        ) { error in
            XCTAssertEqual(error as? AudioImportFailure, .unsupportedMedia)
        }
        for nonfinite in [Float.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(
                try StreamingCanonicalAudioNormalizer.downmix(
                    [nonfinite],
                    frameCount: 1,
                    channelCount: 1
                )
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .nonfiniteSamples)
            }
        }
    }

    func testQuantizationUsesLockedRoundAwayAndSaturationVectors() throws {
        let vectors: [(Double, Int16)] = [
            (-2, .min),
            (-1, .min),
            (-0.5, -16_384),
            (-1.0 / 65_536.0, -1),
            (0, 0),
            (1.0 / 65_536.0, 1),
            (0.5, 16_384),
            (0.999_99, 32_767),
            (1, .max),
            (2, .max),
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(try CanonicalWAVWriter.quantize(input), expected)
        }
    }

    func testSixteenKilohertzBypassWritesCanonicalHeaderAndExactSamples() throws {
        let result = try normalize(
            sampleRate: 16_000,
            chunks: [[-1, -0.5, 0, 0.5, 1]],
            maximumFrames: 5
        )

        XCTAssertEqual(result.summary.frameCount, 5)
        XCTAssertEqual(result.summary.durationMilliseconds, 1)
        XCTAssertEqual(result.summary.byteCount, 54)
        XCTAssertEqual(Array(result.bytes.prefix(44)), Array(CanonicalWAVWriter.header(dataByteCount: 10)))
        XCTAssertEqual(
            Array(result.bytes.dropFirst(44)),
            [0x00, 0x80, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x40, 0xFF, 0x7F]
        )
        XCTAssertEqual(
            SHA256.hash(data: result.bytes).map { String(format: "%02x", $0) }.joined(),
            "87615e424bb548113f3b8afdc7ff93f6b2de088b925e23216fcb65f6a91f73d2"
        )
    }

    func testFrameLimitAcceptsBoundaryAndRejectsNextFrame() throws {
        try withTemporaryFile { url, descriptor in
            let description = InspectedAudio(
                codec: .linearPCM,
                sampleRateHz: 16_000,
                channelCount: 1,
                metadataDurationSeconds: 0.001
            )
            let normalizer = try StreamingCanonicalAudioNormalizer(
                description: description,
                destinationDescriptor: descriptor,
                maximumFrameCount: 2
            )
            try normalizer.consume(
                DecodedPCMChunk(
                    interleavedSamples: [0, 0],
                    frameCount: 2,
                    channelCount: 1,
                    sampleRateHz: 16_000
                )
            )
            XCTAssertThrowsError(
                try normalizer.consume(
                    DecodedPCMChunk(
                        interleavedSamples: [0],
                        frameCount: 1,
                        channelCount: 1,
                        sampleRateHz: 16_000
                    )
                )
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .durationExceeded)
            }
            _ = try normalizer.finish()
            XCTAssertEqual(try Data(contentsOf: url).count, 48)
        }
    }

    func testV1FortyFiveMinuteFrameBoundaryStreamsWithoutHoldingWholeAudio() throws {
        try withTemporaryFile { url, descriptor in
            let writer = try CanonicalWAVWriter(
                descriptor: descriptor,
                maximumFrameCount: CanonicalAudioFormat.maximumFrameCount
            )
            let chunk = [Double](repeating: 0, count: 65_536)
            var remaining = CanonicalAudioFormat.maximumFrameCount
            while remaining >= UInt64(chunk.count) {
                try writer.append(chunk)
                remaining -= UInt64(chunk.count)
            }
            if remaining > 0 {
                try writer.append(Array(chunk.prefix(Int(remaining))))
            }
            XCTAssertThrowsError(try writer.append([0])) { error in
                XCTAssertEqual(error as? AudioImportFailure, .durationExceeded)
            }

            let summary = try writer.finish()
            XCTAssertEqual(summary.frameCount, 43_200_000)
            XCTAssertEqual(summary.durationMilliseconds, 2_700_000)
            XCTAssertEqual(summary.byteCount, 86_400_044)
            let fileSize = try FileManager.default.attributesOfItem(
                atPath: url.path
            )[.size] as? NSNumber
            XCTAssertEqual(
                fileSize?.uint64Value,
                86_400_044
            )
        }
    }

    func testResamplingIsRepeatableAndIndependentOfDecoderChunkPartition() throws {
        let goldenSHA256: [UInt32: String] = [
            8_000: "e0a01269c8383d3e126b59a90395b2152cb72c61e9d3e804a6bae88d6406f38a",
            44_100: "eec7055f44d1ff2e4e3d575fb8b046fb3b76174746b09d191f3be117e187ed5d",
            48_000: "b0fb6b2abba998d79b09f14401a799059356d8f30798ba6af54f59c544fc9fd0",
        ]
        for rate in [UInt32(8_000), 44_100, 48_000] {
            let samples = (0..<Int(rate / 100)).map { index in
                Float(sin(Double(index) * 0.071) * 0.4)
            }
            let oneChunk = try normalize(
                sampleRate: rate,
                chunks: [samples],
                maximumFrames: 1_000
            )
            let split = samples.count / 3
            let partitioned = try normalize(
                sampleRate: rate,
                chunks: [
                    Array(samples[..<split]),
                    Array(samples[split..<(split * 2)]),
                    Array(samples[(split * 2)...]),
                ],
                maximumFrames: 1_000
            )
            let repeated = try normalize(
                sampleRate: rate,
                chunks: [samples],
                maximumFrames: 1_000
            )

            XCTAssertEqual(oneChunk.summary.frameCount, 160, "rate \(rate)")
            XCTAssertEqual(oneChunk.summary.durationMilliseconds, 10, "rate \(rate)")
            XCTAssertEqual(oneChunk.bytes, partitioned.bytes, "rate \(rate)")
            XCTAssertEqual(oneChunk.bytes, repeated.bytes, "rate \(rate)")
            XCTAssertEqual(
                SHA256.hash(data: oneChunk.bytes)
                    .map { String(format: "%02x", $0) }
                    .joined(),
                goldenSHA256[rate],
                "rate \(rate)"
            )
        }
    }

    private func normalize(
        sampleRate: UInt32,
        channelCount: UInt32 = 1,
        chunks: [[Float]],
        maximumFrames: UInt64
    ) throws -> (summary: CanonicalNormalizationResult, bytes: Data) {
        try withTemporaryFile { url, descriptor in
            let normalizer = try StreamingCanonicalAudioNormalizer(
                description: InspectedAudio(
                    codec: .linearPCM,
                    sampleRateHz: sampleRate,
                    channelCount: channelCount,
                    metadataDurationSeconds: Double(chunks.reduce(0) { $0 + $1.count }) /
                        Double(channelCount) /
                        Double(sampleRate)
                ),
                destinationDescriptor: descriptor,
                maximumFrameCount: maximumFrames
            )
            for samples in chunks where !samples.isEmpty {
                try normalizer.consume(
                    DecodedPCMChunk(
                        interleavedSamples: samples,
                        frameCount: samples.count / Int(channelCount),
                        channelCount: Int(channelCount),
                        sampleRateHz: sampleRate
                    )
                )
            }
            let summary = try normalizer.finish()
            return (summary, try Data(contentsOf: url))
        }
    }

    private func withTemporaryFile<Result>(
        _ body: (URL, Int32) throws -> Result
    ) throws -> Result {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-normalizer-test-\(UUID().uuidString).wav"
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
        return try body(url, descriptor)
    }
}
