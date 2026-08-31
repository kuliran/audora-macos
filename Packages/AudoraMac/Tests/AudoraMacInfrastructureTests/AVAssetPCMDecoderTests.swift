@preconcurrency import AVFoundation
import AudioToolbox
import AudoraApplication
import AudoraDomain
@testable import AudoraMacInfrastructure
import CoreMedia
import Darwin
import Foundation
import XCTest

final class AVAssetPCMDecoderTests: XCTestCase {
    func testDescriptorRangePlannerResumesWithinTheOriginalRequestedRange() throws {
        XCTAssertEqual(
            try DescriptorAssetByteRangePlanner.responseRange(
                requestedOffset: 100,
                currentOffset: 120,
                requestedLength: 50,
                requestsAllDataToEndOfResource: false,
                byteCount: 1_000
            ),
            120..<150
        )
        XCTAssertEqual(
            try DescriptorAssetByteRangePlanner.responseRange(
                requestedOffset: 100,
                currentOffset: 120,
                requestedLength: -1,
                requestsAllDataToEndOfResource: true,
                byteCount: 200
            ),
            120..<200
        )
    }

    func testDescriptorRangePlannerBoundsEOFAndRejectsInvalidOffsets() throws {
        XCTAssertEqual(
            try DescriptorAssetByteRangePlanner.responseRange(
                requestedOffset: 90,
                currentOffset: 90,
                requestedLength: 50,
                requestsAllDataToEndOfResource: false,
                byteCount: 100
            ),
            90..<100
        )
        XCTAssertEqual(
            try DescriptorAssetByteRangePlanner.responseRange(
                requestedOffset: 90,
                currentOffset: 100,
                requestedLength: 10,
                requestsAllDataToEndOfResource: false,
                byteCount: 100
            ),
            100..<100
        )
        XCTAssertThrowsError(
            try DescriptorAssetByteRangePlanner.responseRange(
                requestedOffset: Int64.max - 1,
                currentOffset: Int64.max - 1,
                requestedLength: 4,
                requestsAllDataToEndOfResource: false,
                byteCount: Int64.max
            )
        ) { error in
            XCTAssertEqual(error as? DescriptorAssetByteRangeError, .invalidRequest)
        }
        XCTAssertThrowsError(
            try DescriptorAssetByteRangePlanner.responseRange(
                requestedOffset: 100,
                currentOffset: 151,
                requestedLength: 50,
                requestsAllDataToEndOfResource: false,
                byteCount: 1_000
            )
        ) { error in
            XCTAssertEqual(error as? DescriptorAssetByteRangeError, .invalidRequest)
        }
        XCTAssertThrowsError(
            try DescriptorAssetByteRangePlanner.responseRange(
                requestedOffset: 0,
                currentOffset: -1,
                requestedLength: 1,
                requestsAllDataToEndOfResource: false,
                byteCount: 1
            )
        ) { error in
            XCTAssertEqual(error as? DescriptorAssetByteRangeError, .invalidRequest)
        }
    }

    func testOnlyOrdinaryMonoAndStereoLayoutsAreAccepted() throws {
        XCTAssertTrue(
            AVAssetPCMDecoder.hasSupportedChannelLayout(
                try audioDescription(layoutTag: kAudioChannelLayoutTag_Mono, channelCount: 1),
                channelCount: 1
            )
        )
        XCTAssertTrue(
            AVAssetPCMDecoder.hasSupportedChannelLayout(
                try audioDescription(layoutTag: kAudioChannelLayoutTag_Stereo, channelCount: 2),
                channelCount: 2
            )
        )
        XCTAssertFalse(
            AVAssetPCMDecoder.hasSupportedChannelLayout(
                try audioDescription(
                    layoutTag: kAudioChannelLayoutTag_MatrixStereo,
                    channelCount: 2
                ),
                channelCount: 2
            )
        )
    }

    func testSyntheticMonoAndStereoWAVVariantsInspectAndDecode() async throws {
        for rate in [UInt32(8_000), 16_000, 44_100, 48_000] {
            for channels in [UInt32(1), 2] {
                try await withTemporaryAudioURL(extension: "wav") { url in
                    let sourceFrames = Int(rate / 20)
                    try writeSyntheticAudio(
                        to: url,
                        formatID: kAudioFormatLinearPCM,
                        sampleRate: rate,
                        channelCount: channels,
                        frameCount: sourceFrames
                    )

                    let decoder = AVAssetPCMDecoder()
                    let inspectedSource = try await decoder.inspect(
                        try openOwnedAudio(url),
                        container: .wav
                    )
                    let inspected = inspectedSource.description
                    XCTAssertEqual(inspected.codec, .linearPCM)
                    XCTAssertEqual(inspected.sampleRateHz, rate)
                    XCTAssertEqual(inspected.channelCount, channels)
                    let decoded = try await decodeAll(decoder, source: inspectedSource)
                    XCTAssertEqual(decoded.frameCount, sourceFrames)
                    XCTAssertEqual(decoded.samples.count, sourceFrames * Int(channels))
                    XCTAssertTrue(decoded.samples.allSatisfy(\.isFinite))
                }
            }
        }
    }

    func testSyntheticAACAndALACM4AVariantsInspectAndDecode() async throws {
        let variants: [(AudioFormatID, DecodedAudioCodec)] = [
            (kAudioFormatMPEG4AAC, .aacLC),
            (kAudioFormatAppleLossless, .alac),
        ]
        for (formatID, expectedCodec) in variants {
            for channels in [UInt32(1), 2] {
                try await withTemporaryAudioURL(extension: "m4a") { url in
                    try writeSyntheticAudio(
                        to: url,
                        formatID: formatID,
                        sampleRate: 44_100,
                        channelCount: channels,
                        frameCount: 4_410
                    )

                    let decoder = AVAssetPCMDecoder()
                    let inspectedSource = try await decoder.inspect(
                        try openOwnedAudio(url),
                        container: .m4a
                    )
                    let inspected = inspectedSource.description
                    XCTAssertEqual(inspected.codec, expectedCodec)
                    XCTAssertEqual(inspected.sampleRateHz, 44_100)
                    XCTAssertEqual(inspected.channelCount, channels)
                    let decoded = try await decodeAll(decoder, source: inspectedSource)
                    XCTAssertEqual(decoded.frameCount, 4_410)
                    XCTAssertEqual(decoded.samples.count, decoded.frameCount * Int(channels))
                    XCTAssertTrue(decoded.samples.allSatisfy(\.isFinite))
                }
            }
        }
    }

    func testAACPrimingDrainsOnsetAndTailIntoCanonicalWAV() async throws {
        try await withTemporaryAudioURL(extension: "m4a") { encodedURL in
            try await withTemporaryAudioURL(extension: "wav") { canonicalURL in
                let frameCount = 4_410
                try writeSyntheticAudio(
                    to: encodedURL,
                    formatID: kAudioFormatMPEG4AAC,
                    sampleRate: 44_100,
                    channelCount: 1,
                    frameCount: frameCount
                ) { _, frame in
                    if frame < 512 || frame >= frameCount - 512 {
                        return Float(
                            sin(2 * Double.pi * 1_000 * Double(frame) / 44_100) * 0.8
                        )
                    }
                    return 0
                }

                let decoder = AVAssetPCMDecoder()
                let inspectedSource = try await decoder.inspect(
                    try openOwnedAudio(encodedURL),
                    container: .m4a
                )
                let descriptor = Darwin.open(
                    canonicalURL.path,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                    0o600
                )
                guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
                let normalizer = try StreamingCanonicalAudioNormalizer(
                    description: inspectedSource.description,
                    destinationDescriptor: descriptor,
                    maximumFrameCount: 1_600
                )
                var decodedFrames = 0
                try await decoder.decode(inspectedSource) { chunk in
                    decodedFrames += chunk.frameCount
                    try normalizer.consume(chunk)
                }
                let normalized = try normalizer.finish()
                let canonical = try Data(contentsOf: canonicalURL)
                let canonicalSamples = canonicalInt16Samples(canonical)

                XCTAssertEqual(decodedFrames, frameCount)
                XCTAssertEqual(normalized.frameCount, 1_600)
                XCTAssertEqual(normalized.byteCount, UInt64(canonical.count))
                XCTAssertEqual(canonicalSamples.count, 1_600)
                XCTAssertGreaterThan(
                    canonicalSamples.prefix(256).map(magnitude).max() ?? 0,
                    1_000
                )
                XCTAssertGreaterThan(
                    canonicalSamples.suffix(256).map(magnitude).max() ?? 0,
                    1_000
                )
            }
        }
    }

    func testDecodedTimelineAcceptsExactlyContiguousPresentedFrames() throws {
        var timeline = try DecodedAudioTimelineValidator(sampleRateHz: 44_100)
        XCTAssertEqual(
            try timeline.accept(
                presentationTimeStamp: CMTime(value: 0, timescale: 44_100),
                frameCount: 100,
                trimAtStart: 10,
                trimAtEnd: 20
            ),
            10..<80
        )
        XCTAssertEqual(
            try timeline.accept(
                presentationTimeStamp: CMTime(value: 80, timescale: 44_100),
                frameCount: 50,
                trimAtStart: 0,
                trimAtEnd: 0
            ),
            0..<50
        )
        XCTAssertEqual(timeline.presentedFrameCount, 120)
    }

    func testDecodedTimelineRejectsInternalPositiveGap() throws {
        var timeline = try DecodedAudioTimelineValidator(sampleRateHz: 44_100)
        _ = try timeline.accept(
            presentationTimeStamp: .zero,
            frameCount: 100,
            trimAtStart: 0,
            trimAtEnd: 0
        )
        XCTAssertThrowsError(
            try timeline.accept(
                presentationTimeStamp: CMTime(value: 101, timescale: 44_100),
                frameCount: 100,
                trimAtStart: 0,
                trimAtEnd: 0
            )
        ) { error in
            XCTAssertEqual(error as? DecodedAudioTimelineError, .invalid)
        }
    }

    func testDecodedTimelineRejectsPresentationOverlap() throws {
        var timeline = try DecodedAudioTimelineValidator(sampleRateHz: 44_100)
        _ = try timeline.accept(
            presentationTimeStamp: .zero,
            frameCount: 100,
            trimAtStart: 0,
            trimAtEnd: 0
        )
        XCTAssertThrowsError(
            try timeline.accept(
                presentationTimeStamp: CMTime(value: 99, timescale: 44_100),
                frameCount: 100,
                trimAtStart: 0,
                trimAtEnd: 0
            )
        ) { error in
            XCTAssertEqual(error as? DecodedAudioTimelineError, .invalid)
        }
    }

    func testMalformedAndContainerMismatchedInputsAreRejected() async throws {
        try await withTemporaryAudioURL(extension: "wav") { url in
            try Data("RIFFsyntheticWAVE".utf8).write(to: url)
            await XCTAssertThrowsErrorAsync(
                try await AVAssetPCMDecoder().inspect(
                    try openOwnedAudio(url),
                    container: .wav
                )
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .malformedMedia)
            }
        }

        try await withTemporaryAudioURL(extension: "m4a") { url in
            let wav = url.deletingPathExtension().appendingPathExtension("wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            try writeSyntheticAudio(
                to: wav,
                formatID: kAudioFormatLinearPCM,
                sampleRate: 16_000,
                channelCount: 1,
                frameCount: 160
            )
            try FileManager.default.moveItem(at: wav, to: url)
            await XCTAssertThrowsErrorAsync(
                try await AVAssetPCMDecoder().inspect(
                    try openOwnedAudio(url),
                    container: .m4a
                )
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .unsupportedMedia)
            }
        }
    }

    func testMoreThanTwoChannelsIsRejectedBeforeDecode() async throws {
        try await withTemporaryAudioURL(extension: "wav") { url in
            try writeSyntheticAudio(
                to: url,
                formatID: kAudioFormatLinearPCM,
                sampleRate: 16_000,
                channelCount: 3,
                frameCount: 160
            )
            await XCTAssertThrowsErrorAsync(
                try await AVAssetPCMDecoder().inspect(
                    try openOwnedAudio(url),
                    container: .wav
                )
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .unsupportedMedia)
            }
        }
    }

    private func decodeAll(
        _ decoder: AVAssetPCMDecoder,
        source: InspectedAudioSource
    ) async throws -> (samples: [Float], frameCount: Int) {
        var samples: [Float] = []
        var frameCount = 0
        try await decoder.decode(source) { chunk in
            samples.append(contentsOf: chunk.interleavedSamples)
            frameCount += chunk.frameCount
        }
        return (samples, frameCount)
    }

    private func writeSyntheticAudio(
        to url: URL,
        formatID: AudioFormatID,
        sampleRate: UInt32,
        channelCount: UInt32,
        frameCount: Int,
        sample: ((Int, Int) -> Float)? = nil
    ) throws {
        if formatID == kAudioFormatLinearPCM, channelCount > 2 {
            try writePCM16WAV(
                to: url,
                sampleRate: sampleRate,
                channelCount: channelCount,
                frameCount: frameCount
            )
            return
        }
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ),
            let channelData = buffer.floatChannelData
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<Int(channelCount) {
            for frame in 0..<frameCount {
                channelData[channel][frame] = sample?(channel, frame) ?? Float(
                    sin(Double(frame) * 0.031 + Double(channel) * 0.3) * 0.4
                )
            }
        }

        var settings: [String: Any] = [
            AVFormatIDKey: NSNumber(value: formatID),
            AVSampleRateKey: NSNumber(value: sampleRate),
            AVNumberOfChannelsKey: NSNumber(value: channelCount),
        ]
        switch formatID {
        case kAudioFormatLinearPCM:
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        case kAudioFormatMPEG4AAC:
            settings[AVEncoderBitRateKey] = 64_000 * Int(channelCount)
        case kAudioFormatAppleLossless:
            settings[AVEncoderBitDepthHintKey] = 16
        default:
            throw CocoaError(.fileWriteUnsupportedScheme)
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private func writePCM16WAV(
        to url: URL,
        sampleRate: UInt32,
        channelCount: UInt32,
        frameCount: Int
    ) throws {
        guard channelCount > 0,
              channelCount <= UInt32(UInt16.max / 2),
              frameCount > 0,
              let dataByteCount = UInt32(
                  exactly: UInt64(frameCount) * UInt64(channelCount) * 2
              ),
              dataByteCount <= UInt32.max - 36,
              sampleRate <= UInt32.max / (channelCount * 2)
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        var data = Data()
        func appendLittleEndian(_ value: UInt16) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func appendLittleEndian(_ value: UInt32) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value >> 16))
            data.append(UInt8(truncatingIfNeeded: value >> 24))
        }

        data.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(36 + dataByteCount)
        data.append(contentsOf: "WAVEfmt ".utf8)
        appendLittleEndian(UInt32(16))
        appendLittleEndian(UInt16(1))
        appendLittleEndian(UInt16(channelCount))
        appendLittleEndian(sampleRate)
        appendLittleEndian(sampleRate * channelCount * 2)
        appendLittleEndian(UInt16(channelCount * 2))
        appendLittleEndian(UInt16(16))
        data.append(contentsOf: "data".utf8)
        appendLittleEndian(dataByteCount)
        data.append(Data(repeating: 0, count: Int(dataByteCount)))
        try data.write(to: url, options: .withoutOverwriting)
    }

    private func canonicalInt16Samples(_ data: Data) -> [Int16] {
        guard data.count >= 44, (data.count - 44).isMultiple(of: 2) else { return [] }
        return stride(from: 44, to: data.count, by: 2).map { offset in
            Int16(
                bitPattern: UInt16(data[offset]) |
                    UInt16(data[offset + 1]) << 8
            )
        }
    }

    private func magnitude(_ sample: Int16) -> UInt16 {
        sample.magnitude
    }

    private func withTemporaryAudioURL(
        extension pathExtension: String,
        _ body: (URL) async throws -> Void
    ) async throws {
        var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(FileManager.default.temporaryDirectory.path, &resolvedPath) != nil else {
            throw CocoaError(.fileReadUnknown)
        }
        let resolvedBytes = resolvedPath.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let url = URL(
            fileURLWithPath: String(decoding: resolvedBytes, as: UTF8.self),
            isDirectory: true
        )
            .appendingPathComponent(
                "audora-decoder-test-\(UUID().uuidString).\(pathExtension)"
            )
        defer { _ = Darwin.unlink(url.path) }
        try await body(url)
    }

    private func openOwnedAudio(_ url: URL) throws -> OwnedAudioFile {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size > 0
        else {
            Darwin.close(descriptor)
            throw CocoaError(.fileReadCorruptFile)
        }
        return OwnedAudioFile(
            takingOwnershipOf: descriptor,
            byteCount: Int64(metadata.st_size)
        )
    }

    private func audioDescription(
        layoutTag: AudioChannelLayoutTag,
        channelCount: UInt32
    ) throws -> CMAudioFormatDescription {
        var basic = AudioStreamBasicDescription(
            mSampleRate: 44_100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channelCount * 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: channelCount * 4,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = layoutTag
        var description: CMAudioFormatDescription?
        let status = withUnsafePointer(to: &basic) { basicPointer in
            withUnsafePointer(to: &layout) { layoutPointer in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: basicPointer,
                    layoutSize: MemoryLayout<AudioChannelLayout>.size,
                    layout: layoutPointer,
                    magicCookieSize: 0,
                    magicCookie: nil,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else {
            throw CocoaError(.coderInvalidValue)
        }
        return description
    }
}

private func XCTAssertThrowsErrorAsync<Result>(
    _ expression: @autoclosure () async throws -> Result,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
