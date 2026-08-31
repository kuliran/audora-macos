import AVFoundation
import AudioToolbox
import AudoraApplication
import AudoraDomain
import CoreMedia
import Darwin
import Foundation

struct InspectedAudio: Equatable, Sendable {
    let codec: DecodedAudioCodec
    let sampleRateHz: UInt32
    let channelCount: UInt32
    let metadataDurationSeconds: Double
}

struct DecodedPCMChunk: Sendable {
    let interleavedSamples: [Float]
    let frameCount: Int
    let channelCount: Int
    let sampleRateHz: UInt32
}

final class OwnedAudioFile: @unchecked Sendable {
    let byteCount: Int64
    private let descriptor: Int32

    init(takingOwnershipOf descriptor: Int32, byteCount: Int64) {
        self.descriptor = descriptor
        self.byteCount = byteCount
    }

    func duplicateDescriptor() throws -> Int32 {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { throw AudioImportFailure.unavailable }
        return duplicate
    }

    func readPrefix(maximumCount: Int) throws -> [UInt8] {
        guard maximumCount > 0 else { return [] }
        let count = min(Int64(maximumCount), byteCount)
        guard count > 0, count <= Int64(Int.max) else { return [] }
        var bytes = [UInt8](repeating: 0, count: Int(count))
        let readCount = bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            while true {
                let result = Darwin.pread(descriptor, base, buffer.count, 0)
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        guard readCount >= 0 else { throw AudioImportFailure.unavailable }
        bytes.removeSubrange(readCount..<bytes.count)
        return bytes
    }

    deinit { Darwin.close(descriptor) }
}

struct InspectedAudioSource: @unchecked Sendable {
    let description: InspectedAudio
    fileprivate let asset: AVURLAsset?
    fileprivate let resourceLoader: DescriptorAssetResourceLoader?

    init(description: InspectedAudio) {
        self.description = description
        asset = nil
        resourceLoader = nil
    }

    fileprivate init(
        description: InspectedAudio,
        asset: AVURLAsset,
        resourceLoader: DescriptorAssetResourceLoader
    ) {
        self.description = description
        self.asset = asset
        self.resourceLoader = resourceLoader
    }
}

protocol AudioPCMDecoding: Sendable {
    func inspect(
        _ source: OwnedAudioFile,
        container: ImportedAudioContainer
    ) async throws -> InspectedAudioSource
    func decode(
        _ source: InspectedAudioSource,
        consume: (DecodedPCMChunk) throws -> Void
    ) async throws
}

enum DecodedAudioTimelineError: Error, Equatable {
    case invalid
}

struct DecodedAudioTimelineValidator {
    let sampleRateHz: UInt32
    private var origin: CMTime?
    private(set) var presentedFrameCount: Int64 = 0

    init(sampleRateHz: UInt32) throws {
        guard sampleRateHz > 0, sampleRateHz <= UInt32(Int32.max) else {
            throw DecodedAudioTimelineError.invalid
        }
        self.sampleRateHz = sampleRateHz
    }

    mutating func accept(
        presentationTimeStamp: CMTime,
        frameCount: Int,
        trimAtStart: Int,
        trimAtEnd: Int
    ) throws -> Range<Int>? {
        guard frameCount > 0,
              trimAtStart >= 0,
              trimAtEnd >= 0,
              trimAtStart <= frameCount,
              trimAtEnd <= frameCount - trimAtStart
        else {
            throw DecodedAudioTimelineError.invalid
        }
        let range = trimAtStart..<(frameCount - trimAtEnd)
        guard !range.isEmpty else { return nil }
        guard presentationTimeStamp.isValid,
              presentationTimeStamp.isNumeric,
              let trimFrames = Int64(exactly: trimAtStart),
              let acceptedFrames = Int64(exactly: range.count),
              presentedFrameCount <= Int64.max - acceptedFrames
        else {
            throw DecodedAudioTimelineError.invalid
        }

        let presentedTimeStamp = CMTimeAdd(
            presentationTimeStamp,
            CMTime(value: trimFrames, timescale: Int32(sampleRateHz))
        )
        guard presentedTimeStamp.isValid, presentedTimeStamp.isNumeric else {
            throw DecodedAudioTimelineError.invalid
        }
        if origin == nil { origin = presentedTimeStamp }
        guard let origin else { throw DecodedAudioTimelineError.invalid }
        let relativeTimeStamp = CMTimeSubtract(presentedTimeStamp, origin)
        let expectedTimeStamp = CMTime(
            value: presentedFrameCount,
            timescale: Int32(sampleRateHz)
        )
        guard relativeTimeStamp.isValid,
              relativeTimeStamp.isNumeric,
              CMTimeCompare(relativeTimeStamp, expectedTimeStamp) == 0
        else {
            throw DecodedAudioTimelineError.invalid
        }
        presentedFrameCount += acceptedFrames
        return range
    }
}

struct AVAssetPCMDecoder: AudioPCMDecoding {
    func inspect(
        _ source: OwnedAudioFile,
        container: ImportedAudioContainer
    ) async throws -> InspectedAudioSource {
        do {
            if let detected = detectedContainer(in: try source.readPrefix(maximumCount: 12)),
               detected != container
            {
                throw AudioImportFailure.unsupportedMedia
            }
            let (asset, resourceLoader) = try makeAsset(source, container: container)
            async let loadedDuration = asset.load(.duration)
            async let loadedProtected = asset.load(.hasProtectedContent)
            async let loadedAudioTracks = asset.loadTracks(withMediaType: .audio)
            async let loadedVideoTracks = asset.loadTracks(withMediaType: .video)
            let (duration, hasProtectedContent, audioTracks, videoTracks) = try await (
                loadedDuration,
                loadedProtected,
                loadedAudioTracks,
                loadedVideoTracks
            )
            guard !hasProtectedContent,
                  audioTracks.count == 1,
                  videoTracks.isEmpty,
                  duration.isNumeric,
                  duration.isValid,
                  duration.seconds.isFinite,
                  duration.seconds > 0
            else {
                throw AudioImportFailure.unsupportedMedia
            }

            let descriptions = try await audioTracks[0].load(.formatDescriptions)
            guard !descriptions.isEmpty else {
                throw AudioImportFailure.unsupportedMedia
            }
            var expectedRate: UInt32?
            var expectedChannels: UInt32?
            var expectedCodec: DecodedAudioCodec?
            for formatDescription in descriptions {
                guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(
                    formatDescription
                )?.pointee,
                    basic.mSampleRate.isFinite,
                    basic.mSampleRate.rounded() == basic.mSampleRate,
                    basic.mSampleRate >= 8_000,
                    basic.mSampleRate <= 192_000,
                    basic.mChannelsPerFrame == 1 || basic.mChannelsPerFrame == 2,
                    Self.hasSupportedChannelLayout(
                        formatDescription,
                        channelCount: basic.mChannelsPerFrame
                    ),
                    let codec = codec(for: basic.mFormatID, container: container)
                else {
                    throw AudioImportFailure.unsupportedMedia
                }
                let rate = UInt32(basic.mSampleRate)
                if let expectedRate,
                   expectedRate != rate || expectedChannels != basic.mChannelsPerFrame ||
                    expectedCodec != codec
                {
                    throw AudioImportFailure.unsupportedMedia
                }
                expectedRate = rate
                expectedChannels = basic.mChannelsPerFrame
                expectedCodec = codec
            }
            guard let expectedRate, let expectedChannels, let expectedCodec else {
                throw AudioImportFailure.unsupportedMedia
            }
            return InspectedAudioSource(
                description: InspectedAudio(
                    codec: expectedCodec,
                    sampleRateHz: expectedRate,
                    channelCount: expectedChannels,
                    metadataDurationSeconds: duration.seconds
                ),
                asset: asset,
                resourceLoader: resourceLoader
            )
        } catch let failure as AudioImportFailure {
            throw failure
        } catch {
            throw AudioImportFailure.malformedMedia
        }
    }

    func decode(
        _ source: InspectedAudioSource,
        consume: (DecodedPCMChunk) throws -> Void
    ) async throws {
        do {
            guard let asset = source.asset,
                  source.resourceLoader != nil
            else {
                throw AudioImportFailure.decodeFailed
            }
            let expected = source.description
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard tracks.count == 1 else { throw AudioImportFailure.unsupportedMedia }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: tracks[0],
                outputSettings: [
                    AVFormatIDKey: NSNumber(value: kAudioFormatLinearPCM),
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw AudioImportFailure.decodeFailed }
            reader.add(output)
            guard reader.startReading() else { throw AudioImportFailure.decodeFailed }

            var timeline = try DecodedAudioTimelineValidator(
                sampleRateHz: expected.sampleRateHz
            )
            while let sampleBuffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard CMSampleBufferIsValid(sampleBuffer),
                      CMSampleBufferDataIsReady(sampleBuffer),
                      let block = CMSampleBufferGetDataBuffer(sampleBuffer)
                else {
                    reader.cancelReading()
                    throw AudioImportFailure.decodeFailed
                }
                let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
                let trimAtStart = try trimFrameCount(
                    sampleBuffer,
                    key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                    sampleRateHz: expected.sampleRateHz
                )
                let trimAtEnd = try trimFrameCount(
                    sampleBuffer,
                    key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
                    sampleRateHz: expected.sampleRateHz
                )
                let valueCount = frameCount * Int(expected.channelCount)
                let requiredBytes = valueCount * MemoryLayout<Float>.size
                guard frameCount > 0,
                      let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                      let basic = CMAudioFormatDescriptionGetStreamBasicDescription(
                          description
                      )?.pointee,
                      isExpectedDecodedFormat(basic, expected: expected),
                      CMBlockBufferGetDataLength(block) == requiredBytes
                else {
                    reader.cancelReading()
                    throw AudioImportFailure.decodeFailed
                }
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let presentedFrames: Range<Int>
                do {
                    guard let accepted = try timeline.accept(
                        presentationTimeStamp: timestamp,
                        frameCount: frameCount,
                        trimAtStart: trimAtStart,
                        trimAtEnd: trimAtEnd
                    ) else {
                        continue
                    }
                    presentedFrames = accepted
                } catch {
                    reader.cancelReading()
                    throw error
                }

                var samples = [Float](repeating: 0, count: valueCount)
                let copyStatus = samples.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(
                        block,
                        atOffset: 0,
                        dataLength: requiredBytes,
                        destination: bytes.baseAddress!
                    )
                }
                guard copyStatus == noErr else {
                    reader.cancelReading()
                    throw AudioImportFailure.decodeFailed
                }
                let channelCount = Int(expected.channelCount)
                let firstValue = presentedFrames.lowerBound * channelCount
                let presentedValueCount = presentedFrames.count * channelCount
                let presentedSamples = Array(
                    samples[firstValue..<(firstValue + presentedValueCount)]
                )
                try consume(
                    DecodedPCMChunk(
                        interleavedSamples: presentedSamples,
                        frameCount: presentedFrames.count,
                        channelCount: channelCount,
                        sampleRateHz: expected.sampleRateHz
                    )
                )
            }
            try Task.checkCancellation()
            guard reader.status == .completed, timeline.presentedFrameCount > 0 else {
                throw AudioImportFailure.decodeFailed
            }
        } catch is CancellationError {
            throw AudioImportFailure.cancelled
        } catch let failure as AudioImportFailure {
            throw failure
        } catch {
            throw AudioImportFailure.decodeFailed
        }
    }

    private func trimFrameCount(
        _ sampleBuffer: CMSampleBuffer,
        key: CFString,
        sampleRateHz: UInt32
    ) throws -> Int {
        guard let value = CMGetAttachment(
            sampleBuffer,
            key: key,
            attachmentModeOut: nil
        ) else {
            return 0
        }
        guard CFGetTypeID(value) == CFDictionaryGetTypeID() else {
            throw AudioImportFailure.decodeFailed
        }
        let dictionary = unsafeDowncast(value, to: CFDictionary.self)
        let time = CMTimeMakeFromDictionary(dictionary)
        guard time.isValid, time.isNumeric, time >= .zero else {
            throw AudioImportFailure.decodeFailed
        }
        let scaled = CMTimeConvertScale(
            time,
            timescale: Int32(sampleRateHz),
            method: .default
        )
        guard CMTimeCompare(time, scaled) == 0,
              scaled.value >= 0,
              scaled.value <= Int64(Int.max)
        else {
            throw AudioImportFailure.decodeFailed
        }
        return Int(scaled.value)
    }

    private func isExpectedDecodedFormat(
        _ format: AudioStreamBasicDescription,
        expected: InspectedAudio
    ) -> Bool {
        let flags = format.mFormatFlags
        return format.mFormatID == kAudioFormatLinearPCM &&
            flags & kAudioFormatFlagIsFloat != 0 &&
            flags & kAudioFormatFlagIsPacked != 0 &&
            flags & kAudioFormatFlagIsBigEndian == 0 &&
            flags & kAudioFormatFlagIsNonInterleaved == 0 &&
            format.mBitsPerChannel == 32 &&
            format.mBytesPerFrame == expected.channelCount * 4 &&
            format.mFramesPerPacket == 1 &&
            format.mChannelsPerFrame == expected.channelCount &&
            format.mSampleRate == Double(expected.sampleRateHz)
    }

    private func makeAsset(
        _ source: OwnedAudioFile,
        container: ImportedAudioContainer
    ) throws -> (AVURLAsset, DescriptorAssetResourceLoader) {
        guard let url = URL(
            string: "audora-owned-audio://local/source.\(container.rawValue)"
        ) else {
            throw AudioImportFailure.unavailable
        }
        let resourceLoader = try DescriptorAssetResourceLoader(
            source: source,
            resourceURL: url,
            container: container
        )
        let asset = AVURLAsset(
            url: url,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true,
                AVURLAssetReferenceRestrictionsKey: NSNumber(
                    value: AVAssetReferenceRestrictions.forbidAll.rawValue
                ),
            ]
        )
        asset.resourceLoader.setDelegate(resourceLoader, queue: resourceLoader.queue)
        return (asset, resourceLoader)
    }

    private func codec(
        for formatID: AudioFormatID,
        container: ImportedAudioContainer
    ) -> DecodedAudioCodec? {
        switch (container, formatID) {
        case (.wav, kAudioFormatLinearPCM): .linearPCM
        case (.m4a, kAudioFormatMPEG4AAC): .aacLC
        case (.m4a, kAudioFormatAppleLossless): .alac
        default: nil
        }
    }

    private func detectedContainer(in prefix: [UInt8]) -> ImportedAudioContainer? {
        if prefix.count >= 12,
           prefix[0..<4].elementsEqual("RIFF".utf8),
           prefix[8..<12].elementsEqual("WAVE".utf8)
        {
            return .wav
        }
        if prefix.count >= 8,
           prefix[4..<8].elementsEqual("ftyp".utf8)
        {
            let boxSize = prefix[0..<4].reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            if boxSize == 0 || boxSize >= 8 {
                return .m4a
            }
        }
        return nil
    }

    static func hasSupportedChannelLayout(
        _ description: CMAudioFormatDescription,
        channelCount: UInt32
    ) -> Bool {
        var byteCount = 0
        guard let layout = CMAudioFormatDescriptionGetChannelLayout(
            description,
            sizeOut: &byteCount
        ) else {
            // A missing layout on an ordinary one/two-channel file carries the
            // conventional mono/stereo ordering implied by its channel count.
            return true
        }
        let value = layout.pointee
        switch value.mChannelLayoutTag {
        case kAudioChannelLayoutTag_Mono:
            return channelCount == 1
        case kAudioChannelLayoutTag_Stereo, kAudioChannelLayoutTag_StereoHeadphones:
            return channelCount == 2
        case kAudioChannelLayoutTag_UseChannelBitmap:
            if channelCount == 1 {
                return value.mChannelBitmap.rawValue == 1 << 2
            }
            return channelCount == 2 &&
                value.mChannelBitmap.rawValue == (1 << 0) | (1 << 1)
        case kAudioChannelLayoutTag_UseChannelDescriptions:
            guard value.mNumberChannelDescriptions == channelCount,
                  let descriptionsOffset = MemoryLayout<AudioChannelLayout>.offset(
                      of: \AudioChannelLayout.mChannelDescriptions
                  ),
                  byteCount >= descriptionsOffset +
                    Int(channelCount) * MemoryLayout<AudioChannelDescription>.stride
            else {
                return false
            }
            let channels = UnsafeRawPointer(layout)
                .advanced(by: descriptionsOffset)
                .assumingMemoryBound(to: AudioChannelDescription.self)
            if channelCount == 1 {
                return channels[0].mChannelLabel == kAudioChannelLabel_Center ||
                    channels[0].mChannelLabel == kAudioChannelLabel_Mono
            }
            return channels[0].mChannelLabel == kAudioChannelLabel_Left &&
                channels[1].mChannelLabel == kAudioChannelLabel_Right
        default:
            return false
        }
    }
}

enum DescriptorAssetByteRangeError: Error, Equatable {
    case invalidRequest
}

enum DescriptorAssetByteRangePlanner {
    static func responseRange(
        requestedOffset: Int64,
        currentOffset: Int64,
        requestedLength: Int,
        requestsAllDataToEndOfResource: Bool,
        byteCount: Int64
    ) throws -> Range<Int64> {
        guard requestedOffset >= 0,
              currentOffset >= 0,
              byteCount >= 0
        else {
            throw DescriptorAssetByteRangeError.invalidRequest
        }
        let start = max(requestedOffset, currentOffset)
        guard start <= byteCount else {
            throw DescriptorAssetByteRangeError.invalidRequest
        }
        if requestsAllDataToEndOfResource {
            return start..<byteCount
        }
        guard requestedLength >= 0,
              let length = Int64(exactly: requestedLength),
              requestedOffset <= Int64.max - length
        else {
            throw DescriptorAssetByteRangeError.invalidRequest
        }
        let requestedEnd = requestedOffset + length
        let end = min(byteCount, requestedEnd)
        guard start <= end else {
            throw DescriptorAssetByteRangeError.invalidRequest
        }
        return start..<end
    }
}

private enum DescriptorAssetResourceError: Error {
    case readFailed
}

private final class DescriptorAssetResourceLoader: NSObject,
    AVAssetResourceLoaderDelegate,
    @unchecked Sendable
{
    let queue = DispatchQueue(label: "app.audora.audio-import.resource-loader")

    private let descriptor: Int32
    private let byteCount: Int64
    private let resourceURL: URL
    private let contentType: String

    init(
        source: OwnedAudioFile,
        resourceURL: URL,
        container: ImportedAudioContainer
    ) throws {
        descriptor = try source.duplicateDescriptor()
        byteCount = source.byteCount
        self.resourceURL = resourceURL
        contentType = switch container {
        case .wav: "com.microsoft.waveform-audio"
        case .m4a: "public.mpeg-4-audio"
        }
        super.init()
    }

    deinit { Darwin.close(descriptor) }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard loadingRequest.request.url == resourceURL else { return false }
        do {
            if let information = loadingRequest.contentInformationRequest {
                information.contentType = contentType
                information.contentLength = byteCount
                information.isByteRangeAccessSupported = true
            }
            if let request = loadingRequest.dataRequest {
                try respond(to: request)
            }
            loadingRequest.finishLoading()
        } catch {
            loadingRequest.finishLoading(with: error)
        }
        return true
    }

    private func respond(to request: AVAssetResourceLoadingDataRequest) throws {
        let range = try DescriptorAssetByteRangePlanner.responseRange(
            requestedOffset: request.requestedOffset,
            currentOffset: request.currentOffset,
            requestedLength: request.requestedLength,
            requestsAllDataToEndOfResource: request.requestsAllDataToEndOfResource,
            byteCount: byteCount
        )

        var offset = range.lowerBound
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < range.upperBound {
            let amount = min(Int64(buffer.count), range.upperBound - offset)
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                while true {
                    let result = Darwin.pread(
                        descriptor,
                        base,
                        Int(amount),
                        off_t(offset)
                    )
                    if result < 0, errno == EINTR { continue }
                    return result
                }
            }
            guard count > 0 else { throw DescriptorAssetResourceError.readFailed }
            request.respond(with: Data(buffer[0..<count]))
            offset += Int64(count)
        }
    }
}
