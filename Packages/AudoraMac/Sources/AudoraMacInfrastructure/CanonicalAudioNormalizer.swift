@preconcurrency import AVFAudio
import AudioToolbox
import AudoraApplication
import AudoraDomain
import Darwin
import Foundation

struct CanonicalNormalizationResult: Equatable, Sendable {
    let frameCount: UInt64
    let durationMilliseconds: UInt64
    let byteCount: UInt64
}

final class StreamingCanonicalAudioNormalizer {
    private let description: InspectedAudio
    private let writer: CanonicalWAVWriter
    private let resampler: StreamingCanonicalSampleRateConverter
    private var finished = false

    init(
        description: InspectedAudio,
        destinationDescriptor: Int32,
        maximumFrameCount: UInt64
    ) throws {
        self.description = description
        writer = try CanonicalWAVWriter(
            descriptor: destinationDescriptor,
            maximumFrameCount: maximumFrameCount
        )
        resampler = try StreamingCanonicalSampleRateConverter(
            sourceSampleRateHz: description.sampleRateHz
        )
    }

    func consume(_ chunk: DecodedPCMChunk) throws {
        guard !finished,
              chunk.frameCount > 0,
              chunk.sampleRateHz == description.sampleRateHz,
              chunk.channelCount == Int(description.channelCount),
              chunk.interleavedSamples.count == chunk.frameCount * chunk.channelCount
        else {
            throw AudioImportFailure.decodeFailed
        }
        let mono = try Self.downmix(
            chunk.interleavedSamples,
            frameCount: chunk.frameCount,
            channelCount: chunk.channelCount
        )
        try writer.append(resampler.consume(mono))
    }

    func finish() throws -> CanonicalNormalizationResult {
        guard !finished else { throw AudioImportFailure.writeFailed }
        finished = true
        try writer.append(resampler.finish())
        return try writer.finish()
    }

    static func downmix(
        _ samples: [Float],
        frameCount: Int,
        channelCount: Int
    ) throws -> [Double] {
        guard channelCount == 1 || channelCount == 2,
              samples.count == frameCount * channelCount
        else {
            throw AudioImportFailure.unsupportedMedia
        }
        var mono = [Double]()
        mono.reserveCapacity(frameCount)
        if channelCount == 1 {
            for sample in samples {
                guard sample.isFinite else { throw AudioImportFailure.nonfiniteSamples }
                mono.append(Double(sample))
            }
        } else {
            for frame in 0..<frameCount {
                let left = samples[frame * 2]
                let right = samples[frame * 2 + 1]
                guard left.isFinite, right.isFinite else {
                    throw AudioImportFailure.nonfiniteSamples
                }
                let mixed = 0.5 * (Double(left) + Double(right))
                guard mixed.isFinite else { throw AudioImportFailure.nonfiniteSamples }
                mono.append(mixed)
            }
        }
        return mono
    }

}

/// One acquisition-independent streaming resampler. Import and microphone
/// capture share this exact converter configuration and batching policy.
final class StreamingCanonicalSampleRateConverter {
    static let inputFrameCount = 4_096
    static let maximumQualifiedPrimeFrames: AVAudioFrameCount = 4_096
    static let maximumUnavailableBridgeInputFrames = UInt64(inputFrameCount * 2 - 1)
    /// Covers the largest qualified live-source phase period. Both callers of
    /// the silence primitive (the discontinuity bridge and phase preroll) must
    /// stay within this fixed work bound.
    static let maximumSyntheticSilenceInputFrames: UInt64 = 384_000

    private let sourceSampleRateHz: UInt32
    private let converter: AVAudioConverter?
    private let sourceFormat: AVAudioFormat?
    private let destinationFormat: AVAudioFormat?
    private let qualifiedPrimeBridgeFrames: UInt64
    private var pending: [Double] = []
    private var pendingOffset = 0
    private var outputFramesToDiscard: UInt64 = 0
    private var finished = false

    /// The maximum source-time bridge needed before an unavailable
    /// discontinuity can be compacted. First complete the converter's current
    /// 4,096-frame input batch, then advance through a whole, batch-rounded
    /// prime window. The bound is derived from this converter instance rather
    /// than assuming a particular AVFoundation latency.
    var unavailableDiscontinuityBridgeInputFrames: UInt64 {
        guard converter != nil else { return 0 }
        let batch = UInt64(Self.inputFrameCount)
        let retainedInputFrames = UInt64(pending.count - pendingOffset)
        let retainedRemainder = retainedInputFrames % batch
        let alignment = retainedRemainder == 0 ? 0 : batch - retainedRemainder
        return alignment + qualifiedPrimeBridgeFrames
    }

    var hasPendingPhasePreroll: Bool {
        outputFramesToDiscard != 0
    }

    init(sourceSampleRateHz: UInt32) throws {
        guard sourceSampleRateHz > 0 else { throw AudioImportFailure.unsupportedMedia }
        self.sourceSampleRateHz = sourceSampleRateHz
        guard sourceSampleRateHz != CanonicalAudioFormat.sampleRateHz else {
            converter = nil
            sourceFormat = nil
            destinationFormat = nil
            qualifiedPrimeBridgeFrames = 0
            return
        }
        guard let source = AVAudioFormat(
            commonFormat: .pcmFormatFloat64,
            sampleRate: Double(sourceSampleRateHz),
            channels: 1,
            interleaved: false
        ), let destination = AVAudioFormat(
            commonFormat: .pcmFormatFloat64,
            sampleRate: Double(CanonicalAudioFormat.sampleRateHz),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: source, to: destination) else {
            throw AudioImportFailure.unsupportedMedia
        }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        converter.sampleRateConverterQuality = Int(kAudioConverterQuality_Max)
        converter.primeMethod = .normal
        converter.dither = false
        guard converter.primeInfo.leadingFrames <= Self.maximumQualifiedPrimeFrames,
              converter.primeInfo.trailingFrames <= Self.maximumQualifiedPrimeFrames
        else {
            throw AudioImportFailure.unsupportedMedia
        }
        let batch = UInt64(Self.inputFrameCount)
        let qualifiedPrime = max(
            batch,
            UInt64(converter.primeInfo.leadingFrames),
            UInt64(converter.primeInfo.trailingFrames)
        )
        qualifiedPrimeBridgeFrames = ((qualifiedPrime + batch - 1) / batch) * batch
        self.converter = converter
        sourceFormat = source
        destinationFormat = destination
    }

    func consume(_ samples: [Double]) throws -> [Double] {
        guard !finished, !samples.isEmpty else { throw AudioImportFailure.decodeFailed }
        guard samples.allSatisfy(\.isFinite) else { throw AudioImportFailure.nonfiniteSamples }
        guard let converter, let sourceFormat, let destinationFormat else { return samples }

        pending.append(contentsOf: samples)
        var output: [Double] = []
        while pending.count - pendingOffset >= Self.inputFrameCount {
            let end = pendingOffset + Self.inputFrameCount
            output.append(contentsOf: try convert(
                Array(pending[pendingOffset..<end]),
                with: converter,
                sourceFormat: sourceFormat,
                destinationFormat: destinationFormat
            ))
            pendingOffset = end
        }
        if pendingOffset >= Self.inputFrameCount * 2 {
            pending.removeFirst(pendingOffset)
            pendingOffset = 0
        }
        return discardPhasePreroll(from: output)
    }

    /// Advances the same converter through unavailable source time without
    /// allocating one array proportional to a stalled capture interval.
    func consumeSilence(
        frameCount: UInt64,
        onOutput: ([Double]) throws -> Void
    ) throws {
        guard !finished,
              frameCount > 0,
              frameCount <= Self.maximumSyntheticSilenceInputFrames
        else { throw AudioImportFailure.decodeFailed }
        let boundedSilence = [Double](repeating: 0, count: Self.inputFrameCount)
        var remaining = frameCount
        while remaining > 0 {
            let count = min(remaining, UInt64(Self.inputFrameCount))
            let input = count == UInt64(boundedSilence.count)
                ? boundedSilence
                : Array(boundedSilence.prefix(Int(count)))
            try onOutput(consume(input))
            remaining -= count
        }
    }

    func finish() throws -> [Double] {
        guard !finished else { throw AudioImportFailure.writeFailed }
        finished = true
        guard let converter, let sourceFormat, let destinationFormat else { return [] }

        var output: [Double] = []
        if pendingOffset < pending.count {
            output.append(contentsOf: try convert(
                Array(pending[pendingOffset...]),
                with: converter,
                sourceFormat: sourceFormat,
                destinationFormat: destinationFormat
            ))
        }
        pending.removeAll(keepingCapacity: false)
        pendingOffset = 0
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: destinationFormat,
            frameCapacity: 4_096
        ) else { throw AudioImportFailure.decodeFailed }
        for _ in 0..<64 {
            buffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: buffer, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            output.append(contentsOf: try Self.samples(in: buffer))
            switch status {
            case .haveData:
                guard buffer.frameLength > 0 else { throw AudioImportFailure.decodeFailed }
            case .endOfStream:
                let exposed = discardPhasePreroll(from: output)
                guard outputFramesToDiscard == 0 else {
                    throw AudioImportFailure.decodeFailed
                }
                return exposed
            case .inputRanDry:
                continue
            case .error:
                throw AudioImportFailure.decodeFailed
            @unknown default:
                throw AudioImportFailure.decodeFailed
            }
        }
        throw AudioImportFailure.decodeFailed
    }

    /// Starts a new observed segment after a declared unavailable interval.
    /// AVAudioConverter keeps the identical instance and configuration, while
    /// reset plus a rational source-phase preroll makes post-gap samples align
    /// with the absolute canonical timeline. The preroll is always smaller
    /// than one source/canonical phase period and is never exposed as audio.
    func resetAfterUnavailable(atAbsoluteSourceFrame sourceFrame: UInt64) throws -> [Double] {
        guard !finished, outputFramesToDiscard == 0 else {
            throw AudioImportFailure.decodeFailed
        }
        pending.removeAll(keepingCapacity: true)
        pendingOffset = 0
        converter?.reset()

        let divisor = Self.greatestCommonDivisor(
            UInt64(sourceSampleRateHz),
            CanonicalRecordingLimits.sampleRate
        )
        let period = UInt64(sourceSampleRateHz) / divisor
        let phase = sourceFrame % period
        guard phase > 0 else {
            guard pending.isEmpty, pendingOffset == 0 else {
                throw AudioImportFailure.decodeFailed
            }
            return []
        }
        let expectedDiscard = try Self.canonicalFloor(
            inputFrame: phase,
            inputRate: sourceSampleRateHz
        )
        outputFramesToDiscard = expectedDiscard
        var exposed: [Double] = []
        try consumeSilence(frameCount: phase) { output in
            exposed.append(contentsOf: output)
        }
        guard pending.count - pendingOffset < Self.inputFrameCount,
              outputFramesToDiscard <= expectedDiscard
        else {
            throw AudioImportFailure.decodeFailed
        }
        return exposed
    }

    private func convert(
        _ mono: [Double],
        with converter: AVAudioConverter,
        sourceFormat: AVAudioFormat,
        destinationFormat: AVAudioFormat
    ) throws -> [Double] {
        guard mono.count <= Int(UInt32.max),
              let input = AVAudioPCMBuffer(
                  pcmFormat: sourceFormat,
                  frameCapacity: AVAudioFrameCount(mono.count)
              ), let channel = Self.float64Channel(in: input)
        else { throw AudioImportFailure.decodeFailed }
        input.frameLength = AVAudioFrameCount(mono.count)
        for (index, value) in mono.enumerated() { channel[index] = value }
        let capacity = Int(ceil(
            Double(mono.count) * Double(CanonicalAudioFormat.sampleRateHz) /
                Double(sourceSampleRateHz)
        )) + 512
        guard capacity > 0, capacity <= Int(UInt32.max),
              let output = AVAudioPCMBuffer(
                  pcmFormat: destinationFormat,
                  frameCapacity: AVAudioFrameCount(capacity)
              )
        else { throw AudioImportFailure.decodeFailed }
        let inputBox = ConverterInputBox(input)
        var samples: [Double] = []
        for _ in 0..<32 {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                inputBox.supply(inputStatus)
            }
            samples.append(contentsOf: try Self.samples(in: output))
            switch status {
            case .haveData:
                guard output.frameLength > 0 else { throw AudioImportFailure.decodeFailed }
            case .inputRanDry:
                return samples
            case .endOfStream, .error:
                throw AudioImportFailure.decodeFailed
            @unknown default:
                throw AudioImportFailure.decodeFailed
            }
        }
        throw AudioImportFailure.decodeFailed
    }

    private static func samples(in buffer: AVAudioPCMBuffer) throws -> [Double] {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return [] }
        guard let channel = float64Channel(in: buffer) else {
            throw AudioImportFailure.decodeFailed
        }
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }

    private func discardPhasePreroll(from samples: [Double]) -> [Double] {
        guard outputFramesToDiscard > 0, !samples.isEmpty else { return samples }
        let discarded = min(outputFramesToDiscard, UInt64(samples.count))
        outputFramesToDiscard -= discarded
        return Array(samples.dropFirst(Int(discarded)))
    }

    private static func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var a = lhs
        var b = rhs
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return a
    }

    private static func canonicalFloor(
        inputFrame: UInt64,
        inputRate: UInt32
    ) throws -> UInt64 {
        let (scaled, overflow) = inputFrame.multipliedReportingOverflow(
            by: CanonicalRecordingLimits.sampleRate
        )
        guard !overflow else { throw AudioImportFailure.decodeFailed }
        return scaled / UInt64(inputRate)
    }

    private static func float64Channel(in buffer: AVAudioPCMBuffer) -> UnsafeMutablePointer<Double>? {
        guard buffer.format.commonFormat == .pcmFormatFloat64,
              !buffer.format.isInterleaved,
              buffer.format.channelCount == 1
        else {
            return nil
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            buffer.mutableAudioBufferList
        )
        guard buffers.count == 1, let data = buffers[0].mData else { return nil }
        return data.assumingMemoryBound(to: Double.self)
    }
}

private final class ConverterInputBox: @unchecked Sendable {
    private let input: AVAudioPCMBuffer
    private let lock = NSLock()
    private var supplied = false

    init(_ input: AVAudioPCMBuffer) {
        self.input = input
    }

    func supply(
        _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if supplied {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return input
    }
}

final class CanonicalWAVWriter {
    private var descriptor: Int32
    private let maximumFrameCount: UInt64
    private var frameCount: UInt64 = 0
    private var closed = false

    init(descriptor: Int32, maximumFrameCount: UInt64) throws {
        guard descriptor >= 0 else { throw AudioImportFailure.writeFailed }
        self.descriptor = descriptor
        self.maximumFrameCount = maximumFrameCount
        try Self.writeAll(Data(repeating: 0, count: 44), to: descriptor)
    }

    deinit {
        if !closed { Darwin.close(descriptor) }
    }

    func append(_ samples: [Double]) throws {
        guard !closed,
              UInt64(samples.count) <= maximumFrameCount - min(frameCount, maximumFrameCount)
        else {
            throw AudioImportFailure.durationExceeded
        }
        var bytes = Data(count: samples.count * 2)
        try bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                if samples.isEmpty { return }
                throw AudioImportFailure.writeFailed
            }
            for (index, sample) in samples.enumerated() {
                let value = try Self.quantize(sample)
                let bitPattern = UInt16(bitPattern: value)
                base[index * 2] = UInt8(truncatingIfNeeded: bitPattern)
                base[index * 2 + 1] = UInt8(truncatingIfNeeded: bitPattern >> 8)
            }
        }
        try Self.writeAll(bytes, to: descriptor)
        frameCount += UInt64(samples.count)
    }

    func finish() throws -> CanonicalNormalizationResult {
        guard !closed, frameCount > 0 else { throw AudioImportFailure.decodeFailed }
        let duration = try CanonicalAudioFormat.durationMilliseconds(forFrameCount: frameCount)
        let dataByteCount = frameCount * 2
        guard dataByteCount <= UInt64(UInt32.max) - 36 else {
            throw AudioImportFailure.durationExceeded
        }
        let header = Self.header(dataByteCount: UInt32(dataByteCount))
        try Self.pwriteAll(header, to: descriptor, offset: 0)
        try Self.flush(descriptor)
        guard Darwin.close(descriptor) == 0 else {
            closed = true
            throw AudioImportFailure.writeFailed
        }
        closed = true
        return CanonicalNormalizationResult(
            frameCount: frameCount,
            durationMilliseconds: duration,
            byteCount: 44 + dataByteCount
        )
    }

    static func quantize(_ sample: Double) throws -> Int16 {
        guard sample.isFinite else { throw AudioImportFailure.nonfiniteSamples }
        let value = sample
        if value <= -1 { return Int16.min }
        if value >= 1 { return Int16.max }
        let rounded = (value * 32_768).rounded(.toNearestOrAwayFromZero)
        return Int16(max(Double(Int16.min), min(Double(Int16.max), rounded)))
    }

    static func header(dataByteCount: UInt32) -> Data {
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        appendLittleEndian(36 + dataByteCount, to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt32(16_000), to: &data)
        appendLittleEndian(UInt32(32_000), to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendLittleEndian(dataByteCount, to: &data)
        return data
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        let succeeded = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if result == 0 { return false }
                offset += result
            }
            return true
        }
        guard succeeded else { throw AudioImportFailure.writeFailed }
    }

    private static func pwriteAll(
        _ data: Data,
        to descriptor: Int32,
        offset initialOffset: off_t
    ) throws {
        let succeeded = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.pwrite(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset,
                    initialOffset + off_t(offset)
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if result == 0 { return false }
                offset += result
            }
            return true
        }
        guard succeeded else { throw AudioImportFailure.writeFailed }
    }

    private static func flush(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw AudioImportFailure.writeFailed
        }
    }
}
