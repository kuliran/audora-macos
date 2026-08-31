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

    /// Canonical ownership waiting for output from the streaming converter.
    /// This is internal evidence for terminal-invariant tests and is always
    /// zero after a successful finish.
    var pendingFrameCount: UInt64 {
        pending.reduce(0) { $0 + $1.frameCount }
    }

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
        try configure(sampleRateHz: chunk.sampleRateHz, channelCount: chunk.channels.count)
        let boundedInputEnd = min(
            inputEnd,
            try maximumInputFrame(sampleRateHz: chunk.sampleRateHz)
        )
        if boundedInputEnd <= greatestInputEnd {
            return []
        }
        let effectiveStart = min(
            max(chunk.startSampleFrame, greatestInputEnd),
            boundedInputEnd
        )
        var spans: [CanonicalPCMSpan] = []
        if effectiveStart > greatestInputEnd {
            var reasons: Set<UnavailableReason> = [.captureGap]
            if muted { reasons.insert(.muted) }
            spans += try appendUnavailable(
                sourceStart: greatestInputEnd, sourceEnd: effectiveStart, reasons: reasons
            )
        }
        guard effectiveStart < boundedInputEnd else { return spans }
        let offset = Int(effectiveStart - chunk.startSampleFrame)
        if muted {
            spans += try appendUnavailable(
                sourceStart: effectiveStart, sourceEnd: boundedInputEnd, reasons: [.muted]
            )
            return spans
        }
        let acceptedFrameCount = Int(boundedInputEnd - effectiveStart)
        let acceptedRange = offset..<(offset + acceptedFrameCount)
        let source: [Double]
        if chunk.channels.count == 1 {
            source = chunk.channels[0][acceptedRange].map(Double.init)
        } else {
            source = zip(
                chunk.channels[0][acceptedRange],
                chunk.channels[1][acceptedRange]
            ).map {
                (Double($0.0) + Double($0.1)) / 2
            }
        }
        spans += try append(
            sourceFrames: source,
            sourceStart: effectiveStart,
            sourceEnd: boundedInputEnd,
            reasons: []
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
        var reasons: Set<UnavailableReason> = [.captureGap]
        if muted { reasons.insert(.muted) }
        return try consumeUnavailable(
            sampleRateHz: sampleRateHz,
            startSampleFrame: startSampleFrame,
            frameCount: inputFrameCount,
            channelCount: channelCount,
            reasons: reasons
        )
    }

    mutating func consumeMutedInterval(
        sampleRateHz: UInt32,
        startSampleFrame: UInt64,
        frameCount: UInt64,
        channelCount: UInt8
    ) throws -> [CanonicalPCMSpan] {
        try consumeUnavailable(
            sampleRateHz: sampleRateHz,
            startSampleFrame: startSampleFrame,
            frameCount: frameCount,
            channelCount: channelCount,
            reasons: [.muted]
        )
    }

    mutating func finish() throws -> [CanonicalPCMSpan] {
        guard !finished, let resampler else { return [] }
        try assertActiveTimelineInvariant()
        finished = true
        let spans = try drain(resampler.finish())
        guard !resampler.hasPendingPhasePreroll, let inputSampleRate else {
            throw CanonicalPCMAssemblerError.inputClockOverflow
        }

        // AVAudioConverter's normal-prime EOS behavior may resolve a
        // fractional final source frame to either adjacent integer. Decoded
        // output remains authoritative; the active source-clock invariant
        // owns the ceiling, so only the corresponding zero-or-one-frame
        // mathematical residual may remain and be dropped at EOS.
        let projectedCeiling = try canonicalCeiling(
            inputFrame: greatestInputEnd,
            inputRate: inputSampleRate
        )
        let projectedFloor = try canonicalFloor(
            inputFrame: greatestInputEnd,
            inputRate: inputSampleRate
        )
        let residual = pendingFrameCount
        guard residual <= 1,
              pending.count <= 1,
              frameCount >= projectedFloor,
              frameCount <= projectedCeiling,
              projectedCeiling - frameCount == residual
        else {
            throw CanonicalPCMAssemblerError.inputClockOverflow
        }
        pending.removeAll(keepingCapacity: false)
        guard pendingFrameCount == 0 else {
            throw CanonicalPCMAssemblerError.inputClockOverflow
        }
        return coalescingUnavailableSpans(spans)
    }

    /// Projects source-clock control acknowledgements onto the canonical
    /// timeline without materializing any audio or unavailable evidence.
    func canonicalFrame(forInputFrame inputFrame: UInt64) throws -> UInt64? {
        guard let inputSampleRate else { return nil }
        return try canonicalCeiling(inputFrame: inputFrame, inputRate: inputSampleRate)
    }

    mutating func configure(sampleRateHz: UInt32, channelCount: Int) throws {
        guard !finished,
              sampleRateHz >= CanonicalRecordingLimits.sampleRate,
              sampleRateHz <= 384_000,
              (1...2).contains(channelCount)
        else {
            throw CanonicalPCMAssemblerError.unsupportedInputFormat
        }
        if let inputSampleRate,
           inputSampleRate != sampleRateHz || inputChannelCount != channelCount {
            throw CanonicalPCMAssemblerError.unsupportedInputFormat
        }
        if inputSampleRate == nil {
            resampler = try StreamingCanonicalSampleRateConverter(sourceSampleRateHz: sampleRateHz)
        }
        inputSampleRate = sampleRateHz
        inputChannelCount = channelCount
        try assertActiveTimelineInvariant()
    }

    private mutating func consumeUnavailable(
        sampleRateHz: UInt32,
        startSampleFrame: UInt64,
        frameCount inputFrameCount: UInt64,
        channelCount: UInt8,
        reasons: Set<UnavailableReason>
    ) throws -> [CanonicalPCMSpan] {
        guard inputFrameCount > 0,
              !reasons.isEmpty,
              reasons.isSubset(of: [.captureGap, .muted])
        else {
            throw CanonicalPCMAssemblerError.unsupportedInputFormat
        }
        try configure(sampleRateHz: sampleRateHz, channelCount: Int(channelCount))
        let (inputEnd, overflow) = startSampleFrame.addingReportingOverflow(inputFrameCount)
        guard !overflow else { throw CanonicalPCMAssemblerError.inputClockOverflow }
        let boundedInputEnd = min(
            inputEnd,
            try maximumInputFrame(sampleRateHz: sampleRateHz)
        )
        guard boundedInputEnd > greatestInputEnd else { return [] }

        let effectiveStart = min(
            max(startSampleFrame, greatestInputEnd),
            boundedInputEnd
        )
        var spans: [CanonicalPCMSpan] = []
        if effectiveStart > greatestInputEnd {
            spans += try appendUnavailable(
                sourceStart: greatestInputEnd,
                sourceEnd: effectiveStart,
                reasons: reasons.union([.captureGap])
            )
        }
        if effectiveStart < boundedInputEnd {
            spans += try appendUnavailable(
                sourceStart: effectiveStart,
                sourceEnd: boundedInputEnd,
                reasons: reasons
            )
        }
        return coalescingUnavailableSpans(spans)
    }

    private mutating func append(
        sourceFrames: [Double],
        sourceStart: UInt64,
        sourceEnd: UInt64,
        reasons: Set<UnavailableReason>
    ) throws -> [CanonicalPCMSpan] {
        guard let inputSampleRate,
              let resampler,
              sourceStart == greatestInputEnd,
              UInt64(sourceFrames.count) == sourceEnd - sourceStart
        else {
            throw CanonicalPCMAssemblerError.unsupportedInputFormat
        }
        let start = try canonicalCeiling(inputFrame: sourceStart, inputRate: inputSampleRate)
        let end = try canonicalCeiling(inputFrame: sourceEnd, inputRate: inputSampleRate)
        if end > start { pending.append(PendingSpan(frameCount: end - start, reasons: reasons)) }
        greatestInputEnd = sourceEnd
        let spans = try drain(resampler.consume(sourceFrames))
        try assertActiveTimelineInvariant()
        return spans
    }

    private mutating func appendUnavailable(
        sourceStart: UInt64,
        sourceEnd: UInt64,
        reasons: Set<UnavailableReason>
    ) throws -> [CanonicalPCMSpan] {
        guard sourceEnd > sourceStart,
              let inputSampleRate,
              let resampler,
              sourceStart == greatestInputEnd
        else {
            throw CanonicalPCMAssemblerError.unsupportedInputFormat
        }
        try assertActiveTimelineInvariant()
        let sourceFrames = sourceEnd - sourceStart
        let bridgeInputFrames = resampler.unavailableDiscontinuityBridgeInputFrames
        if bridgeInputFrames > 0, sourceFrames <= bridgeInputFrames {
            return try appendSilence(
                sourceStart: sourceStart,
                sourceEnd: sourceEnd,
                reasons: reasons
            )
        }

        // Complete the current converter batch and one batch-rounded prime
        // window. This computed bridge must drain every protected observed
        // span before any unavailable ownership is materialized directly.
        let protectedPendingBeforeBridge = try pendingFrames { $0.reasons.isEmpty }
        var spans: [CanonicalPCMSpan] = []
        if bridgeInputFrames > 0 {
            let bridgeEnd = sourceStart + bridgeInputFrames
            spans += try appendSilence(
                sourceStart: sourceStart,
                sourceEnd: bridgeEnd,
                reasons: reasons
            )
        }
        let protectedPendingAfterBridge = try pendingFrames { $0.reasons.isEmpty }
        guard protectedPendingAfterBridge <= protectedPendingBeforeBridge,
              protectedPendingAfterBridge == 0,
              pending.allSatisfy({ !$0.reasons.isEmpty })
        else {
            throw CanonicalPCMAssemblerError.inputClockOverflow
        }
        let projectedFloor = try canonicalFloor(
            inputFrame: sourceEnd,
            inputRate: inputSampleRate
        )
        guard frameCount <= projectedFloor else {
            throw CanonicalPCMAssemblerError.inputClockOverflow
        }
        spans += try materializePendingUnavailable(throughFrame: projectedFloor)
        guard frameCount <= projectedFloor,
              pending.allSatisfy({ !$0.reasons.isEmpty })
        else {
            throw CanonicalPCMAssemblerError.inputClockOverflow
        }
        if frameCount < projectedFloor {
            guard pending.isEmpty else {
                throw CanonicalPCMAssemblerError.inputClockOverflow
            }
            spans.append(
                CanonicalPCMSpan(
                    frameCount: projectedFloor - frameCount,
                    pcmLittleEndian: nil,
                    reasons: reasons,
                    level: nil
                )
            )
            frameCount = projectedFloor
        }

        let projectedCeiling = try canonicalCeiling(
            inputFrame: sourceEnd,
            inputRate: inputSampleRate
        )
        let holdback = projectedCeiling - projectedFloor
        guard holdback <= 1 else {
            throw CanonicalPCMAssemblerError.inputClockOverflow
        }
        let retainedHoldback = try pendingFrames { _ in true }
        guard retainedHoldback <= holdback else {
            throw CanonicalPCMAssemblerError.inputClockOverflow
        }
        if retainedHoldback < holdback {
            pending.append(
                PendingSpan(frameCount: holdback - retainedHoldback, reasons: reasons)
            )
        }
        greatestInputEnd = sourceEnd
        try assertActiveTimelineInvariant()
        let phasePreroll = try resampler.resetAfterUnavailable(
            atAbsoluteSourceFrame: sourceEnd
        )
        spans += try drain(phasePreroll)
        try assertActiveTimelineInvariant()
        return coalescingUnavailableSpans(spans)
    }

    private mutating func materializePendingUnavailable(
        throughFrame target: UInt64
    ) throws -> [CanonicalPCMSpan] {
        var spans: [CanonicalPCMSpan] = []
        while frameCount < target, let entry = pending.first {
            guard !entry.reasons.isEmpty else {
                throw CanonicalPCMAssemblerError.inputClockOverflow
            }
            let count = min(entry.frameCount, target - frameCount)
            spans.append(
                CanonicalPCMSpan(
                    frameCount: count,
                    pcmLittleEndian: nil,
                    reasons: entry.reasons,
                    level: nil
                )
            )
            pending[0].frameCount -= count
            if pending[0].frameCount == 0 { pending.removeFirst() }
            let (nextFrameCount, overflow) = frameCount.addingReportingOverflow(count)
            guard !overflow else { throw CanonicalPCMAssemblerError.inputClockOverflow }
            frameCount = nextFrameCount
        }
        return spans
    }

    private mutating func appendSilence(
        sourceStart: UInt64,
        sourceEnd: UInt64,
        reasons: Set<UnavailableReason>
    ) throws -> [CanonicalPCMSpan] {
        guard let inputSampleRate,
              let resampler,
              sourceStart == greatestInputEnd
        else {
            throw CanonicalPCMAssemblerError.unsupportedInputFormat
        }
        let start = try canonicalCeiling(inputFrame: sourceStart, inputRate: inputSampleRate)
        let end = try canonicalCeiling(inputFrame: sourceEnd, inputRate: inputSampleRate)
        if end > start {
            pending.append(PendingSpan(frameCount: end - start, reasons: reasons))
        }
        greatestInputEnd = sourceEnd
        var spans: [CanonicalPCMSpan] = []
        try resampler.consumeSilence(frameCount: sourceEnd - sourceStart) { samples in
            for span in try drain(samples) {
                if let last = spans.last,
                   last.pcmLittleEndian == nil,
                   span.pcmLittleEndian == nil,
                   last.reasons == span.reasons
                {
                    spans[spans.count - 1] = CanonicalPCMSpan(
                        frameCount: last.frameCount + span.frameCount,
                        pcmLittleEndian: nil,
                        reasons: last.reasons,
                        level: nil
                    )
                } else {
                    spans.append(span)
                }
            }
        }
        try assertActiveTimelineInvariant()
        return spans
    }

    private func maximumInputFrame(sampleRateHz: UInt32) throws -> UInt64 {
        let (scaled, overflow) = CanonicalRecordingLimits.maximumFrames
            .multipliedReportingOverflow(by: UInt64(sampleRateHz))
        guard !overflow else { throw CanonicalPCMAssemblerError.inputClockOverflow }
        return scaled / CanonicalRecordingLimits.sampleRate
    }

    private func coalescingUnavailableSpans(
        _ spans: [CanonicalPCMSpan]
    ) -> [CanonicalPCMSpan] {
        var result: [CanonicalPCMSpan] = []
        for span in spans {
            if let last = result.last,
               last.pcmLittleEndian == nil,
               span.pcmLittleEndian == nil,
               last.reasons == span.reasons
            {
                result[result.count - 1] = CanonicalPCMSpan(
                    frameCount: last.frameCount + span.frameCount,
                    pcmLittleEndian: nil,
                    reasons: last.reasons,
                    level: nil
                )
            } else {
                result.append(span)
            }
        }
        return result
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
            let (nextFrameCount, overflow) = frameCount.addingReportingOverflow(UInt64(count))
            guard !overflow else { throw CanonicalPCMAssemblerError.inputClockOverflow }
            frameCount = nextFrameCount
        }
        return spans
    }

    /// Materializes elapsed monotonic time for a source that remains open but
    /// produces no callbacks. The immutable feed format must be configured at
    /// start; deadline projection never fabricates a 16 kHz mono input format.
    mutating func consumeTimedGap(
        throughCanonicalFrame target: UInt64,
        muted: Bool = false
    ) throws -> [CanonicalPCMSpan] {
        let boundedTarget = min(target, CanonicalRecordingLimits.maximumFrames)
        guard boundedTarget > frameCount else { return [] }
        guard let rate = inputSampleRate,
              let inputChannelCount,
              let channels = UInt8(exactly: inputChannelCount)
        else {
            throw CanonicalPCMAssemblerError.unsupportedInputFormat
        }
        guard rate >= CanonicalRecordingLimits.sampleRate else {
            throw CanonicalPCMAssemblerError.unsupportedInputFormat
        }
        let (scaled, overflow) = boundedTarget.multipliedReportingOverflow(by: UInt64(rate))
        guard !overflow else { throw CanonicalPCMAssemblerError.inputClockOverflow }
        let (rounded, roundingOverflow) = scaled.addingReportingOverflow(
            CanonicalRecordingLimits.sampleRate - 1
        )
        guard !roundingOverflow else {
            throw CanonicalPCMAssemblerError.inputClockOverflow
        }
        // Unavailable time materializes through the converter's floor
        // projection, so ceil(target * S / D) is the least source end whose
        // authoritative decoded frame count reaches an arbitrary target.
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

    private func canonicalFloor(
        inputFrame: UInt64,
        inputRate: UInt32
    ) throws -> UInt64 {
        let (scaled, overflow) = inputFrame.multipliedReportingOverflow(
            by: CanonicalRecordingLimits.sampleRate
        )
        guard !overflow else { throw CanonicalPCMAssemblerError.inputClockOverflow }
        return scaled / UInt64(inputRate)
    }

    private func pendingFrames(
        where predicate: (PendingSpan) -> Bool
    ) throws -> UInt64 {
        var total: UInt64 = 0
        for entry in pending where predicate(entry) {
            let (next, overflow) = total.addingReportingOverflow(entry.frameCount)
            guard !overflow else { throw CanonicalPCMAssemblerError.inputClockOverflow }
            total = next
        }
        return total
    }

    /// While capture is active, emitted frames plus pending source ownership
    /// must equal the ceiling projection of the greatest accepted input end.
    private func assertActiveTimelineInvariant() throws {
        guard let inputSampleRate else {
            guard frameCount == 0, greatestInputEnd == 0, pending.isEmpty else {
                throw CanonicalPCMAssemblerError.inputClockOverflow
            }
            return
        }
        let retained = try pendingFrames { _ in true }
        let (accounted, overflow) = frameCount.addingReportingOverflow(retained)
        let projectedEnd = try canonicalCeiling(
            inputFrame: greatestInputEnd,
            inputRate: inputSampleRate
        )
        guard !overflow,
              accounted == projectedEnd
        else {
            throw CanonicalPCMAssemblerError.inputClockOverflow
        }
    }

}

private struct PendingSpan {
    var frameCount: UInt64
    let reasons: Set<UnavailableReason>
}
