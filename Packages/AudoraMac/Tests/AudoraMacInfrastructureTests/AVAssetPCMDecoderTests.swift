import AVFoundation
import AudioToolbox
import AudoraApplication
import AudoraDomain
@testable import AudoraMacInfrastructure
import CoreMedia
import Darwin
import Foundation
import XCTest

final class AVAssetPCMDecoderTests: XCTestCase {
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

    func testEditedAACPrimingDrainsOnsetAndTailIntoCanonicalWAV() async throws {
        try await withTemporaryAudioURL(extension: "m4a") { encodedURL in
            try await withTemporaryAudioURL(extension: "m4a") { editedURL in
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
                    try await writeEditedM4A(from: encodedURL, to: editedURL)

                    let decoder = AVAssetPCMDecoder()
                    let inspectedSource = try await decoder.inspect(
                        try openOwnedAudio(editedURL),
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
                    let samples = canonicalInt16Samples(canonical)

                    XCTAssertGreaterThan(inspectedSource.description.metadataDurationSeconds, 1)
                    XCTAssertEqual(decodedFrames, frameCount)
                    XCTAssertEqual(normalized.frameCount, 1_600)
                    XCTAssertEqual(normalized.byteCount, UInt64(canonical.count))
                    XCTAssertEqual(samples.count, 1_600)
                    XCTAssertGreaterThan(samples.prefix(256).map(magnitude).max() ?? 0, 1_000)
                    XCTAssertGreaterThan(samples.suffix(256).map(magnitude).max() ?? 0, 1_000)
                }
            }
        }
    }

    func testInternalPresentationTimestampDiscontinuityIsRejected() async throws {
        try await withTemporaryAudioURL(extension: "m4a") { encodedURL in
            try await withTemporaryAudioURL(extension: "m4a") { discontinuousURL in
                try writeSyntheticAudio(
                    to: encodedURL,
                    formatID: kAudioFormatMPEG4AAC,
                    sampleRate: 44_100,
                    channelCount: 1,
                    frameCount: 4_410
                )
                try await writeDiscontinuousM4A(
                    from: encodedURL,
                    to: discontinuousURL
                )
                let hasInternalGap = try await hasInternalPresentationGap(
                    at: discontinuousURL
                )
                XCTAssertTrue(hasInternalGap)

                let decoder = AVAssetPCMDecoder()
                let inspected = try await decoder.inspect(
                    try openOwnedAudio(discontinuousURL),
                    container: .m4a
                )
                await XCTAssertThrowsErrorAsync(
                    try await decoder.decode(inspected) { _ in }
                ) { error in
                    XCTAssertEqual(error as? AudioImportFailure, .decodeFailed)
                }
            }
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
            )
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

    private func writeEditedM4A(from sourceURL: URL, to destinationURL: URL) async throws {
        let source = AVURLAsset(url: sourceURL)
        let tracks = try await source.loadTracks(withMediaType: .audio)
        let duration = try await source.load(.duration)
        let composition = AVMutableComposition()
        guard tracks.count == 1,
              let track = composition.addMutableTrack(
                  withMediaType: .audio,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try track.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: tracks[0],
            at: CMTime(value: 44_100, timescale: 44_100)
        )
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw CocoaError(.fileWriteUnsupportedScheme)
        }
        try await exporter.export(to: destinationURL, as: .m4a)
    }

    private func writeDiscontinuousM4A(
        from sourceURL: URL,
        to destinationURL: URL
    ) async throws {
        let source = AVURLAsset(url: sourceURL)
        let tracks = try await source.loadTracks(withMediaType: .audio)
        let composition = AVMutableComposition()
        guard tracks.count == 1,
              let track = composition.addMutableTrack(
                  withMediaType: .audio,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let half = CMTime(value: 2_205, timescale: 44_100)
        try track.insertTimeRange(
            CMTimeRange(start: .zero, duration: half),
            of: tracks[0],
            at: .zero
        )
        try track.insertTimeRange(
            CMTimeRange(start: half, duration: half),
            of: tracks[0],
            at: CMTime(value: 4_410, timescale: 44_100)
        )
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw CocoaError(.fileWriteUnsupportedScheme)
        }
        try await exporter.export(to: destinationURL, as: .m4a)
    }

    private func hasInternalPresentationGap(at url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count == 1 else { throw CocoaError(.fileReadCorruptFile) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: nil)
        guard reader.canAdd(output) else { throw CocoaError(.fileReadCorruptFile) }
        reader.add(output)
        guard reader.startReading() else { throw CocoaError(.fileReadCorruptFile) }

        var previousEnd: CMTime?
        var sampleBufferCount = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard timestamp.isValid,
                  timestamp.isNumeric,
                  let format = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  basic.mSampleRate.isFinite,
                  basic.mSampleRate.rounded() == basic.mSampleRate,
                  basic.mSampleRate > 0
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if let previousEnd {
                let gap = CMTimeSubtract(timestamp, previousEnd).seconds
                if gap.isFinite, gap > 0.01 {
                    reader.cancelReading()
                    return true
                }
            }
            previousEnd = CMTimeAdd(
                timestamp,
                CMTime(
                    value: Int64(CMSampleBufferGetNumSamples(sampleBuffer)),
                    timescale: Int32(basic.mSampleRate)
                )
            )
            sampleBufferCount += 1
        }
        guard reader.status == .completed, sampleBufferCount > 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return false
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-decoder-test-\(UUID().uuidString).\(pathExtension)"
        )
        defer { try? FileManager.default.removeItem(at: url) }
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
