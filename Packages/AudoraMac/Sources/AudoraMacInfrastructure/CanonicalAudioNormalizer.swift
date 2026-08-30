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
    static let converterInputFrameCount = 4_096

    private let description: InspectedAudio
    private let writer: CanonicalWAVWriter
    private let converter: AVAudioConverter?
    private let sourceFormat: AVAudioFormat?
    private let destinationFormat: AVAudioFormat?
    private var pendingMono: [Double] = []
    private var pendingMonoOffset = 0
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
        if description.sampleRateHz == CanonicalAudioFormat.sampleRateHz {
            converter = nil
            sourceFormat = nil
            destinationFormat = nil
        } else {
            guard let source = AVAudioFormat(
                commonFormat: .pcmFormatFloat64,
                sampleRate: Double(description.sampleRateHz),
                channels: 1,
                interleaved: false
            ),
                let destination = AVAudioFormat(
                commonFormat: .pcmFormatFloat64,
                    sampleRate: Double(CanonicalAudioFormat.sampleRateHz),
                    channels: 1,
                    interleaved: false
                ),
                let converter = AVAudioConverter(from: source, to: destination)
            else {
                throw AudioImportFailure.unsupportedMedia
            }
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
            converter.sampleRateConverterQuality = Int(kAudioConverterQuality_Max)
            converter.primeMethod = .normal
            converter.dither = false
            self.converter = converter
            sourceFormat = source
            destinationFormat = destination
        }
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
        guard let converter, let sourceFormat, let destinationFormat else {
            try writer.append(mono)
            return
        }

        pendingMono.append(contentsOf: mono)
        while pendingMono.count - pendingMonoOffset >= Self.converterInputFrameCount {
            let end = pendingMonoOffset + Self.converterInputFrameCount
            try convert(
                Array(pendingMono[pendingMonoOffset..<end]),
                with: converter,
                sourceFormat: sourceFormat,
                destinationFormat: destinationFormat
            )
            pendingMonoOffset = end
        }
        if pendingMonoOffset >= Self.converterInputFrameCount * 2 {
            pendingMono.removeFirst(pendingMonoOffset)
            pendingMonoOffset = 0
        }
    }

    private func convert(
        _ mono: [Double],
        with converter: AVAudioConverter,
        sourceFormat: AVAudioFormat,
        destinationFormat: AVAudioFormat
    ) throws {
        guard mono.count <= Int(UInt32.max),
              let input = AVAudioPCMBuffer(
                  pcmFormat: sourceFormat,
                  frameCapacity: AVAudioFrameCount(mono.count)
              ),
              let channel = Self.float64Channel(in: input)
        else {
            throw AudioImportFailure.decodeFailed
        }
        input.frameLength = AVAudioFrameCount(mono.count)
        for (index, value) in mono.enumerated() {
            channel[index] = value
        }
        let estimated = Int(
            ceil(
                Double(mono.count) *
                    Double(CanonicalAudioFormat.sampleRateHz) /
                    Double(description.sampleRateHz)
            )
        ) + 512
        guard estimated > 0,
              estimated <= Int(UInt32.max),
              let output = AVAudioPCMBuffer(
                  pcmFormat: destinationFormat,
                  frameCapacity: AVAudioFrameCount(estimated)
              )
        else {
            throw AudioImportFailure.decodeFailed
        }

        let inputBox = ConverterInputBox(input)
        var iteration = 0
        while iteration < 32 {
            iteration += 1
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) {
                _, inputStatus in
                inputBox.supply(inputStatus)
            }
            try appendOutput(output)
            switch status {
            case .haveData:
                guard output.frameLength > 0 else {
                    throw AudioImportFailure.decodeFailed
                }
            case .inputRanDry:
                return
            case .endOfStream:
                throw AudioImportFailure.decodeFailed
            case .error:
                throw AudioImportFailure.decodeFailed
            @unknown default:
                throw AudioImportFailure.decodeFailed
            }
        }
        throw AudioImportFailure.decodeFailed
    }

    func finish() throws -> CanonicalNormalizationResult {
        guard !finished else { throw AudioImportFailure.writeFailed }
        finished = true
        if let converter, let sourceFormat, let destinationFormat {
            if pendingMonoOffset < pendingMono.count {
                try convert(
                    Array(pendingMono[pendingMonoOffset...]),
                    with: converter,
                    sourceFormat: sourceFormat,
                    destinationFormat: destinationFormat
                )
            }
            pendingMono.removeAll(keepingCapacity: false)
            pendingMonoOffset = 0
            guard let output = AVAudioPCMBuffer(
                pcmFormat: destinationFormat,
                frameCapacity: 4_096
            ) else {
                throw AudioImportFailure.decodeFailed
            }
            var iteration = 0
            while iteration < 64 {
                iteration += 1
                output.frameLength = 0
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) {
                    _, inputStatus in
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                try appendOutput(output)
                switch status {
                case .haveData:
                    guard output.frameLength > 0 else {
                        throw AudioImportFailure.decodeFailed
                    }
                case .endOfStream:
                    return try writer.finish()
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

    private func appendOutput(_ output: AVAudioPCMBuffer) throws {
        let count = Int(output.frameLength)
        guard count > 0 else { return }
        guard let channel = Self.float64Channel(in: output) else {
            throw AudioImportFailure.decodeFailed
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: count))
        try writer.append(samples)
    }

    private static func float64Channel(
        in buffer: AVAudioPCMBuffer
    ) -> UnsafeMutablePointer<Double>? {
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
