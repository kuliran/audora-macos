import Foundation

public enum MicrophoneInputChunkError: Error, Equatable, Sendable {
    case invalidSampleRate
    case invalidChannelCount
    case inconsistentChannelLengths
    case empty
    case nonFiniteSample
}

public struct MicrophoneInputChunk: Equatable, Sendable {
    public let sampleRateHz: UInt32
    public let startSampleFrame: UInt64
    public let channels: [[Float]]

    public init(
        sampleRateHz: UInt32,
        startSampleFrame: UInt64,
        channels: [[Float]]
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
        channelCount: UInt8
    )
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
    public func stop() async {}
}

public struct UnavailableMicrophoneInputSourceFactory: MicrophoneInputSourceFactory {
    public init() {}

    public func makeSource() async -> any MicrophoneInputSource {
        UnavailableMicrophoneInputSource()
    }
}
