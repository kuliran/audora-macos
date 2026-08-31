import AudoraDomain
import Foundation

enum CanonicalPCMAssemblerError: Error, Equatable {
    case unsupportedInputFormat
    case inputClockOverflow
}

struct CanonicalPCMSpan: Equatable {
    let frameCount: UInt64
    let pcmLittleEndian: Data?
    let reasons: Set<UnavailableReason>
    let level: Double?
}

extension CanonicalPCMSpan {
    func prefix(maximumFrames: UInt64) throws -> CanonicalPCMSpan {
        let frames = min(frameCount, maximumFrames)
        guard frames > 0 else { throw CanonicalPCMAssemblerError.inputClockOverflow }
        let payload: Data?
        if let original = pcmLittleEndian {
            let (count, overflow) = frames.multipliedReportingOverflow(by: 2)
            guard !overflow, count <= UInt64(Int.max) else {
                throw CanonicalPCMAssemblerError.inputClockOverflow
            }
            payload = Data(original.prefix(Int(count)))
        } else {
            payload = nil
        }
        return CanonicalPCMSpan(
            frameCount: frames,
            pcmLittleEndian: payload,
            reasons: reasons,
            level: level
        )
    }
}

struct CanonicalPCMAssembler {
    private(set) var frameCount: UInt64 = 0
    private var inputSampleRate: UInt32?
    private var inputChannelCount: Int?
    private var greatestInputEnd: UInt64 = 0
    private var resampler: StreamingCanonicalSampleRateConverter?
    private var pending: [PendingSpan] = []
    private var finished = false

    mutating func consume(
        _ chunk: MicrophoneInputChunk,
        muted: Bool
    ) throws -> [CanonicalPCMSpan] {
        guard chunk.sampleRateHz <= 384_000,
              (1...2).contains(chunk.channels.count)
        else {
            throw CanonicalPCMAssemblerError.unsupportedInputFormat
        }
        if let inputSampleRate,
           inputSampleRate != chunk.sampleRateHz ||
               inputChannelCount != chunk.channels.count
        {
            throw CanonicalPCMAssemblerError.unsupportedInputFormat
        }
        let (inputEnd, overflow) = chunk.startSampleFrame.addingReportingOverflow(chunk.frameCount)
        guard !overflow else { throw CanonicalPCMAssemblerError.inputClockOverflow }
        if inputEnd <= greatestInputEnd {
            return []
        }
        try configure(sampleRateHz: chunk.sampleRateHz, channelCount: chunk.channels.count)
        let effectiveStart = max(chunk.startSampleFrame, greatestInputEnd)
        var spans: [CanonicalPCMSpan] = []
        if effectiveStart > greatestInputEnd {
            var reasons: Set<UnavailableReason> = [.captureGap]
            if muted { reasons.insert(.muted) }
            spans.append(try unavailableSpan(
                sourceStart: greatestInputEnd, sourceEnd: effectiveStart, reasons: reasons
            ))
            greatestInputEnd = effectiveStart
        }
        let offset = Int(effectiveStart - chunk.startSampleFrame)
        let source: [Double]
        if muted {
            source = Array(repeating: 0, count: Int(inputEnd - effectiveStart))
        } else if chunk.channels.count == 1 {
            source = chunk.channels[0][offset...].map(Double.init)
        } else {
            source = zip(chunk.channels[0][offset...], chunk.channels[1][offset...]).map {
                (Double($0.0) + Double($0.1)) / 2
            }
        }
        spans += try append(
            sourceFrames: source,
            sourceStart: effectiveStart,
            sourceEnd: inputEnd,
            reasons: muted ? [.muted] : []
        )
        return spans
    }

    mutating func consumeGap(
        sampleRateHz: UInt32,
        startSampleFrame: UInt64,
        frameCount inputFrameCount: UInt64,
        channelCount: UInt8,
        muted: Bool
    ) throws -> [CanonicalPCMSpan] {
        guard sampleRateHz > 0,
              sampleRateHz <= 384_000,
              (1...2).contains(Int(channelCount)),
              inputFrameCount > 0
        else {
            throw CanonicalPCMAssemblerError.unsupportedInputFormat
        }
        if let inputSampleRate,
           inputSampleRate != sampleRateHz || inputChannelCount != Int(channelCount)
        {
            throw CanonicalPCMAssemblerError.unsupportedInputFormat
        }
        let (inputEnd, overflow) = startSampleFrame.addingReportingOverflow(inputFrameCount)
        guard !overflow else { throw CanonicalPCMAssemblerError.inputClockOverflow }
        if inputEnd <= greatestInputEnd { return [] }
        try configure(sampleRateHz: sampleRateHz, channelCount: Int(channelCount))
        let effectiveStart = max(startSampleFrame, greatestInputEnd)
        var spans: [CanonicalPCMSpan] = []
        if effectiveStart > greatestInputEnd {
            var reasons: Set<UnavailableReason> = [.captureGap]
            if muted { reasons.insert(.muted) }
            spans.append(try unavailableSpan(
                sourceStart: greatestInputEnd, sourceEnd: effectiveStart, reasons: reasons
            ))
            greatestInputEnd = effectiveStart
        }
        var reasons: Set<UnavailableReason> = [.captureGap]
        if muted { reasons.insert(.muted) }
        spans.append(try unavailableSpan(
            sourceStart: effectiveStart, sourceEnd: inputEnd, reasons: reasons
        ))
        greatestInputEnd = inputEnd
        return spans
    }

    mutating func finish() throws -> [CanonicalPCMSpan] {
        guard !finished, let resampler else { return [] }
        finished = true
        return try drain(resampler.finish())
    }

    private mutating func configure(sampleRateHz: UInt32, channelCount: Int) throws {
        if let inputSampleRate,
           inputSampleRate != sampleRateHz || inputChannelCount != channelCount {
            throw CanonicalPCMAssemblerError.unsupportedInputFormat
        }
        if inputSampleRate == nil {
            resampler = try StreamingCanonicalSampleRateConverter(sourceSampleRateHz: sampleRateHz)
        }
        inputSampleRate = sampleRateHz
        inputChannelCount = channelCount
    }

    private mutating func append(
        sourceFrames: [Double],
        sourceStart: UInt64,
        sourceEnd: UInt64,
        reasons: Set<UnavailableReason>
    ) throws -> [CanonicalPCMSpan] {
        guard let inputSampleRate, let resampler else {
            throw CanonicalPCMAssemblerError.unsupportedInputFormat
        }
        let start = try canonicalCeiling(inputFrame: sourceStart, inputRate: inputSampleRate)
        let end = try canonicalCeiling(inputFrame: sourceEnd, inputRate: inputSampleRate)
        if end > start { pending.append(PendingSpan(frameCount: end - start, reasons: reasons)) }
        greatestInputEnd = sourceEnd
        return try drain(resampler.consume(sourceFrames))
    }

    private mutating func unavailableSpan(
        sourceStart: UInt64,
        sourceEnd: UInt64,
        reasons: Set<UnavailableReason>
    ) throws -> CanonicalPCMSpan {
        guard let inputSampleRate else { throw CanonicalPCMAssemblerError.unsupportedInputFormat }
        let start = try canonicalCeiling(inputFrame: sourceStart, inputRate: inputSampleRate)
        let end = try canonicalCeiling(inputFrame: sourceEnd, inputRate: inputSampleRate)
        guard end > start else { throw CanonicalPCMAssemblerError.inputClockOverflow }
        let span = CanonicalPCMSpan(
            frameCount: end - start, pcmLittleEndian: nil, reasons: reasons, level: nil
        )
        frameCount += span.frameCount
        return span
    }

    private mutating func drain(_ samples: [Double]) throws -> [CanonicalPCMSpan] {
        var cursor = 0
        var spans: [CanonicalPCMSpan] = []
        while cursor < samples.count {
            guard !pending.isEmpty else { throw CanonicalPCMAssemblerError.inputClockOverflow }
            let count = min(Int(pending[0].frameCount), samples.count - cursor)
            let section = Array(samples[cursor..<(cursor + count)])
            let entry = pending[0]
            if entry.reasons.isEmpty {
                var pcm = Data()
                pcm.reserveCapacity(count * MemoryLayout<Int16>.size)
                var energy = 0.0
                for sample in section {
                    let bounded = max(-1, min(1, sample))
                    energy += bounded * bounded
                    var integer = try CanonicalWAVWriter.quantize(sample).littleEndian
                    withUnsafeBytes(of: &integer) { pcm.append(contentsOf: $0) }
                }
                spans.append(CanonicalPCMSpan(
                    frameCount: UInt64(count), pcmLittleEndian: pcm, reasons: [],
                    level: (energy / Double(count)).squareRoot()
                ))
            } else {
                spans.append(CanonicalPCMSpan(
                    frameCount: UInt64(count), pcmLittleEndian: nil, reasons: entry.reasons, level: nil
                ))
            }
            pending[0].frameCount -= UInt64(count)
            if pending[0].frameCount == 0 { pending.removeFirst() }
            cursor += count
            frameCount += UInt64(count)
        }
        return spans
    }

    /// Materializes elapsed monotonic time for a source that remains open but
    /// produces no callbacks. The existing input format is retained when one
    /// is known; otherwise canonical mono timing is the conservative baseline.
    mutating func consumeTimedGap(
        throughCanonicalFrame target: UInt64,
        muted: Bool = false
    ) throws -> [CanonicalPCMSpan] {
        guard target > frameCount else { return [] }
        let rate = inputSampleRate ?? UInt32(CanonicalRecordingLimits.sampleRate)
        let channels = UInt8(inputChannelCount ?? 1)
        let (scaled, overflow) = target.multipliedReportingOverflow(by: UInt64(rate))
        guard !overflow else { throw CanonicalPCMAssemblerError.inputClockOverflow }
        let (rounded, roundingOverflow) = scaled.addingReportingOverflow(
            CanonicalRecordingLimits.sampleRate - 1
        )
        guard !roundingOverflow else {
            throw CanonicalPCMAssemblerError.inputClockOverflow
        }
        let inputEnd = rounded / CanonicalRecordingLimits.sampleRate
        guard inputEnd > greatestInputEnd else { return [] }
        return try consumeGap(
            sampleRateHz: rate,
            startSampleFrame: greatestInputEnd,
            frameCount: inputEnd - greatestInputEnd,
            channelCount: channels,
            muted: muted
        )
    }

    private func canonicalCeiling(
        inputFrame: UInt64,
        inputRate: UInt32
    ) throws -> UInt64 {
        let (scaled, overflow) = inputFrame.multipliedReportingOverflow(
            by: CanonicalRecordingLimits.sampleRate
        )
        guard !overflow else { throw CanonicalPCMAssemblerError.inputClockOverflow }
        let denominator = UInt64(inputRate)
        let (rounded, additionOverflow) = scaled.addingReportingOverflow(denominator - 1)
        guard !additionOverflow else {
            throw CanonicalPCMAssemblerError.inputClockOverflow
        }
        return rounded / denominator
    }

}

private struct PendingSpan {
    var frameCount: UInt64
    let reasons: Set<UnavailableReason>
}
