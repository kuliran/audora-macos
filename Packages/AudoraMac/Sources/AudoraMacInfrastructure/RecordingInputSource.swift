import Foundation

public enum MicrophoneInputChunkError: Error, Equatable, Sendable {
    case invalidSampleRate
    case invalidChannelCount
    case inconsistentChannelLengths
    case empty
    case nonFiniteSample
}

/// Source-clock capture policy sampled when an input callback is accepted.
/// The monotonically increasing sequence keeps buffered callbacks tied to the
/// mute authority that was effective when they entered the source stream.
public struct MicrophoneMuteEpoch: Equatable, Sendable {
    public static let initial = MicrophoneMuteEpoch(sequence: 0, isMuted: false)

    public let sequence: UInt64
    public let isMuted: Bool

    public init(sequence: UInt64, isMuted: Bool) {
        self.sequence = sequence
        self.isMuted = isMuted
    }
}

public struct MicrophoneInputChunk: Equatable, Sendable {
    public let sampleRateHz: UInt32
    public let startSampleFrame: UInt64
    public let channels: [[Float]]
    public let muteEpoch: MicrophoneMuteEpoch

    public init(
        sampleRateHz: UInt32,
        startSampleFrame: UInt64,
        channels: [[Float]],
        muteEpoch: MicrophoneMuteEpoch = .initial
    ) throws {
        guard sampleRateHz > 0 else { throw MicrophoneInputChunkError.invalidSampleRate }
        guard (1...2).contains(channels.count) else {
            throw MicrophoneInputChunkError.invalidChannelCount
        }
        guard let count = channels.first?.count, count > 0 else {
            throw MicrophoneInputChunkError.empty
        }
        guard channels.allSatisfy({ $0.count == count }) else {
            throw MicrophoneInputChunkError.inconsistentChannelLengths
        }
        guard channels.allSatisfy({ channel in
            channel.allSatisfy(\.isFinite)
        }) else {
            throw MicrophoneInputChunkError.nonFiniteSample
        }
        self.sampleRateHz = sampleRateHz
        self.startSampleFrame = startSampleFrame
        self.channels = channels
        self.muteEpoch = muteEpoch
    }

    public var frameCount: UInt64 { UInt64(channels[0].count) }
}

public enum MicrophoneInputEvent: Equatable, Sendable {
    case chunk(MicrophoneInputChunk)
    /// Exact input-clock evidence for callbacks dropped by the bounded relay.
    /// The canonical assembler turns this range into capture-gap frames.
    case captureGap(
        sampleRateHz: UInt32,
        startSampleFrame: UInt64,
        frameCount: UInt64,
        channelCount: UInt8,
        muteEpoch: MicrophoneMuteEpoch = .initial
    )
    /// Ordered source-clock acknowledgement. Its frame is evidence about the
    /// timeline; buffered chunks remain classified by their own epoch.
    case muteChanged(epoch: MicrophoneMuteEpoch, effectiveInputFrame: UInt64)
    case interrupted
    case clockBecameInvalid
}

public struct MicrophoneInputFeed: Sendable {
    public let events: AsyncStream<MicrophoneInputEvent>

    public init(events: AsyncStream<MicrophoneInputEvent>) {
        self.events = events
    }
}

public enum MicrophoneInputStartOutcome: Sendable {
    case started(MicrophoneInputFeed)
    case permissionDenied
    case unavailable
}

public protocol MicrophoneInputSource: Sendable {
    func start() async -> MicrophoneInputStartOutcome
    /// Changes the capture policy at the source seam. A successful command
    /// places a corresponding epoch acknowledgement on the input feed.
    func setMuted(_ muted: Bool) async -> Bool
    /// Quiesces callbacks and finishes the feed after all already accepted
    /// events have been drained into it.
    func stop() async
}

public protocol MicrophoneInputSourceFactory: Sendable {
    func makeSource() async -> any MicrophoneInputSource
}

/// A safe composition fallback used until a physical microphone profile is
/// explicitly qualified. It never queries permission or opens hardware.
public struct UnavailableMicrophoneInputSource: MicrophoneInputSource {
    public init() {}

    public func start() async -> MicrophoneInputStartOutcome { .unavailable }
    public func setMuted(_ muted: Bool) async -> Bool { false }
    public func stop() async {}
}

public struct UnavailableMicrophoneInputSourceFactory: MicrophoneInputSourceFactory {
    public init() {}

    public func makeSource() async -> any MicrophoneInputSource {
        UnavailableMicrophoneInputSource()
    }
}
