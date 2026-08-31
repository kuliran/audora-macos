public enum CanonicalAudioFormatError: Error, Equatable, Sendable {
    case unsupportedSampleRate
    case unsupportedChannelCount
    case unsupportedEncoding
    case invalidFrameCount
}

public enum CanonicalPCMEncoding: String, Equatable, Sendable {
    case pcmS16LE
}

/// The single canonical representation shared by imported and captured Session audio.
public struct CanonicalAudioFormat: Equatable, Sendable {
    public static let sampleRateHz: UInt32 = 16_000
    public static let channelCount: UInt32 = 1
    public static let bitsPerSample: UInt32 = 16
    public static let maximumFrameCount: UInt64 = 43_200_000

    public static let versionOne = try! CanonicalAudioFormat(
        sampleRateHz: sampleRateHz,
        channelCount: channelCount,
        encoding: .pcmS16LE
    )
    public static let v1 = versionOne

    public let container = "wav"
    public let sampleRateHz: UInt32
    public let channelCount: UInt32
    public let bitsPerSample = Self.bitsPerSample
    public let encoding: CanonicalPCMEncoding

    public init(
        sampleRateHz: UInt32,
        channelCount: UInt32,
        encoding: CanonicalPCMEncoding
    ) throws {
        guard sampleRateHz == Self.sampleRateHz else {
            throw CanonicalAudioFormatError.unsupportedSampleRate
        }
        guard channelCount == Self.channelCount else {
            throw CanonicalAudioFormatError.unsupportedChannelCount
        }
        guard encoding == .pcmS16LE else {
            throw CanonicalAudioFormatError.unsupportedEncoding
        }
        self.sampleRateHz = sampleRateHz
        self.channelCount = channelCount
        self.encoding = encoding
    }

    public static func durationMilliseconds(forFrameCount frameCount: UInt64) throws -> UInt64 {
        guard frameCount > 0, frameCount <= maximumFrameCount else {
            throw CanonicalAudioFormatError.invalidFrameCount
        }
        return (frameCount * 1_000 + UInt64(sampleRateHz) - 1) / UInt64(sampleRateHz)
    }
}
