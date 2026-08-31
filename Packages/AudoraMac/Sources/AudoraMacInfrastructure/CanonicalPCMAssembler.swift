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
        inputSampleRate = chunk.sampleRateHz
        inputChannelCount = chunk.channels.count

        let (inputEnd, overflow) = chunk.startSampleFrame.addingReportingOverflow(chunk.frameCount)
        guard !overflow else { throw CanonicalPCMAssemblerError.inputClockOverflow }
        if inputEnd <= greatestInputEnd {
            return []
        }

        let earliestCanonical = try canonicalCeiling(
            inputFrame: max(chunk.startSampleFrame, greatestInputEnd),
            inputRate: chunk.sampleRateHz
        )
        let canonicalEnd = try canonicalCeiling(
            inputFrame: inputEnd,
            inputRate: chunk.sampleRateHz
        )
        greatestInputEnd = inputEnd

        var spans: [CanonicalPCMSpan] = []
        if earliestCanonical > frameCount {
            let gapCount = earliestCanonical - frameCount
            var reasons: Set<UnavailableReason> = [.captureGap]
            if muted { reasons.insert(.muted) }
            spans.append(
                CanonicalPCMSpan(
                    frameCount: gapCount,
                    pcmLittleEndian: nil,
                    reasons: reasons,
                    level: nil
                )
            )
            frameCount = earliestCanonical
        }

        let outputStart = max(frameCount, earliestCanonical)
        guard outputStart < canonicalEnd else { return spans }
        let outputCount = canonicalEnd - outputStart
        guard outputCount <= UInt64(Int.max) else {
            throw CanonicalPCMAssemblerError.inputClockOverflow
        }

        if muted {
            spans.append(
                CanonicalPCMSpan(
                    frameCount: outputCount,
                    pcmLittleEndian: nil,
                    reasons: [.muted],
                    level: nil
                )
            )
        } else {
            var pcm = Data()
            pcm.reserveCapacity(Int(outputCount) * MemoryLayout<Int16>.size)
            var energy = 0.0
            for canonicalFrame in outputStart..<canonicalEnd {
                let sourceFrame = try sourceFloor(
                    canonicalFrame: canonicalFrame,
                    inputRate: chunk.sampleRateHz
                )
                guard sourceFrame >= chunk.startSampleFrame,
                      sourceFrame < inputEnd
                else {
                    throw CanonicalPCMAssemblerError.inputClockOverflow
                }
                let index = Int(sourceFrame - chunk.startSampleFrame)
                let sample: Float
                if chunk.channels.count == 1 {
                    sample = chunk.channels[0][index]
                } else {
                    sample = (chunk.channels[0][index] + chunk.channels[1][index]) / 2
                }
                let bounded = max(-1, min(1, sample))
                energy += Double(bounded * bounded)
                var integer: Int16
                if bounded <= -1 {
                    integer = .min
                } else if bounded >= 1 {
                    integer = .max
                } else {
                    integer = Int16((bounded * Float(Int16.max)).rounded())
                }
                integer = integer.littleEndian
                withUnsafeBytes(of: integer) { pcm.append(contentsOf: $0) }
            }
            let rms = min(1, max(0, (energy / Double(outputCount)).squareRoot()))
            spans.append(
                CanonicalPCMSpan(
                    frameCount: outputCount,
                    pcmLittleEndian: pcm,
                    reasons: [],
                    level: rms
                )
            )
        }
        frameCount = canonicalEnd
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
        inputSampleRate = sampleRateHz
        inputChannelCount = Int(channelCount)

        let (inputEnd, overflow) = startSampleFrame.addingReportingOverflow(inputFrameCount)
        guard !overflow else { throw CanonicalPCMAssemblerError.inputClockOverflow }
        if inputEnd <= greatestInputEnd { return [] }

        let effectiveStart = max(startSampleFrame, greatestInputEnd)
        let canonicalStart = try canonicalCeiling(
            inputFrame: effectiveStart,
            inputRate: sampleRateHz
        )
        let canonicalEnd = try canonicalCeiling(
            inputFrame: inputEnd,
            inputRate: sampleRateHz
        )
        greatestInputEnd = inputEnd

        var spans: [CanonicalPCMSpan] = []
        if canonicalStart > frameCount {
            var reasons: Set<UnavailableReason> = [.captureGap]
            if muted { reasons.insert(.muted) }
            spans.append(
                CanonicalPCMSpan(
                    frameCount: canonicalStart - frameCount,
                    pcmLittleEndian: nil,
                    reasons: reasons,
                    level: nil
                )
            )
            frameCount = canonicalStart
        }
        if canonicalEnd > frameCount {
            var reasons: Set<UnavailableReason> = [.captureGap]
            if muted { reasons.insert(.muted) }
            spans.append(
                CanonicalPCMSpan(
                    frameCount: canonicalEnd - frameCount,
                    pcmLittleEndian: nil,
                    reasons: reasons,
                    level: nil
                )
            )
            frameCount = canonicalEnd
        }
        return spans
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

    private func sourceFloor(
        canonicalFrame: UInt64,
        inputRate: UInt32
    ) throws -> UInt64 {
        let (scaled, overflow) = canonicalFrame.multipliedReportingOverflow(
            by: UInt64(inputRate)
        )
        guard !overflow else { throw CanonicalPCMAssemblerError.inputClockOverflow }
        return scaled / CanonicalRecordingLimits.sampleRate
    }
}
