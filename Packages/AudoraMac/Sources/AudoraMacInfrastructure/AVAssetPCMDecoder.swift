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

struct AVAssetPCMDecoder: AudioPCMDecoding {
    func inspect(
        _ source: OwnedAudioFile,
        container: ImportedAudioContainer
    ) async throws -> InspectedAudioSource {
        do {
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

            var timelineOrigin: CMTime?
            var nextPresentedFrame: Int64 = 0
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
                guard trimAtStart <= frameCount,
                      trimAtEnd <= frameCount - trimAtStart
                else {
                    reader.cancelReading()
                    throw AudioImportFailure.decodeFailed
                }
                let presentedFrameCount = frameCount - trimAtStart - trimAtEnd
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
                if presentedFrameCount == 0 { continue }

                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                guard timestamp.isValid, timestamp.isNumeric else {
                    reader.cancelReading()
                    throw AudioImportFailure.decodeFailed
                }
                let presentedTimestamp = CMTimeAdd(
                    timestamp,
                    CMTime(
                        value: Int64(trimAtStart),
                        timescale: Int32(expected.sampleRateHz)
                    )
                )
                if timelineOrigin == nil { timelineOrigin = presentedTimestamp }
                guard let timelineOrigin else {
                    reader.cancelReading()
                    throw AudioImportFailure.decodeFailed
                }
                let relativeTimestamp = CMTimeSubtract(presentedTimestamp, timelineOrigin)
                let frameTimestamp = CMTime(
                    value: nextPresentedFrame,
                    timescale: Int32(expected.sampleRateHz)
                )
                guard CMTimeCompare(relativeTimestamp, frameTimestamp) == 0 else {
                    reader.cancelReading()
                    throw AudioImportFailure.decodeFailed
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
                let firstValue = trimAtStart * channelCount
                let presentedValueCount = presentedFrameCount * channelCount
                let presentedSamples = Array(
                    samples[firstValue..<(firstValue + presentedValueCount)]
                )
                try consume(
                    DecodedPCMChunk(
                        interleavedSamples: presentedSamples,
                        frameCount: presentedFrameCount,
                        channelCount: channelCount,
                        sampleRateHz: expected.sampleRateHz
                    )
                )
                nextPresentedFrame += Int64(presentedFrameCount)
            }
            try Task.checkCancellation()
            guard reader.status == .completed, nextPresentedFrame > 0 else {
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

private enum DescriptorAssetResourceError: Error {
    case invalidRequest
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
        let start = max(request.requestedOffset, request.currentOffset)
        guard start >= 0, start <= byteCount else {
            throw DescriptorAssetResourceError.invalidRequest
        }
        let end: Int64
        if request.requestsAllDataToEndOfResource {
            end = byteCount
        } else {
            let requestedLength = Int64(request.requestedLength)
            guard requestedLength >= 0,
                  start <= Int64.max - requestedLength
            else {
                throw DescriptorAssetResourceError.invalidRequest
            }
            end = min(byteCount, start + requestedLength)
        }

        var offset = start
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < end {
            let amount = min(Int64(buffer.count), end - offset)
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
