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

/// Immutable physical format declared by the input source before it starts
/// emitting callbacks.  This lets capture establish a real source-clock
/// timeline even when the first source event is a mute command or a gap.
public struct MicrophoneInputFormat: Equatable, Sendable {
    public let sampleRateHz: UInt32
    public let channelCount: UInt8

    public init(sampleRateHz: UInt32, channelCount: UInt8) throws {
        // Live capture must map every monotonic canonical target exactly back
        // to the source clock.  Rates below the canonical 16 kHz clock cannot
        // provide that guarantee; imports use their separate decoder seam.
        guard (16_000...384_000).contains(sampleRateHz) else {
            throw MicrophoneInputChunkError.invalidSampleRate
        }
        guard (1...2).contains(channelCount) else {
            throw MicrophoneInputChunkError.invalidChannelCount
        }
        self.sampleRateHz = sampleRateHz
        self.channelCount = channelCount
    }
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
    /// A muted callback keeps only source-clock evidence.  Raw microphone
    /// samples are intentionally absent, so a delayed consumer can never make
    /// muted content persistable after a later unmute.
    case mutedInterval(
        sampleRateHz: UInt32,
        startSampleFrame: UInt64,
        frameCount: UInt64,
        channelCount: UInt8,
        muteEpoch: MicrophoneMuteEpoch
    )
    /// Ordered source-clock acknowledgement. Its frame is evidence about the
    /// timeline; buffered chunks remain classified by their own epoch.
    case muteChanged(epoch: MicrophoneMuteEpoch, effectiveInputFrame: UInt64)
    case interrupted
    case clockBecameInvalid
}

/// A single-consumer event sequence.  Production feeds use a bounded,
/// event-driven broker; tests may bridge a synthetic `AsyncStream`.
public struct MicrophoneInputEventSequence: AsyncSequence, Sendable {
    public typealias Element = MicrophoneInputEvent

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let nextValue: @Sendable () async -> MicrophoneInputEvent?

        fileprivate init(nextValue: @escaping @Sendable () async -> MicrophoneInputEvent?) {
            self.nextValue = nextValue
        }

        public mutating func next() async -> MicrophoneInputEvent? {
            await nextValue()
        }
    }

    private let makeNextValue: @Sendable () -> @Sendable () async -> MicrophoneInputEvent?

    public init(events: AsyncStream<MicrophoneInputEvent>) {
        let bridge = MicrophoneInputStreamBridge(events)
        makeNextValue = { { await bridge.next() } }
    }

    init(nextValue: @escaping @Sendable () async -> MicrophoneInputEvent?) {
        makeNextValue = { nextValue }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(nextValue: makeNextValue())
    }
}

private actor MicrophoneInputStreamBridge {
    private let stream: AsyncStream<MicrophoneInputEvent>

    init(_ stream: AsyncStream<MicrophoneInputEvent>) {
        self.stream = stream
    }

    func next() async -> MicrophoneInputEvent? {
        for await event in stream { return event }
        return nil
    }
}

public struct MicrophoneInputFeed: Sendable {
    public let format: MicrophoneInputFormat
    /// The sole zero point for source callback projection, displayed elapsed
    /// time, mute/Stop boundaries, warnings, and the 45-minute ceiling.
    public let captureStartedAtMonotonicNanoseconds: UInt64
    public let events: MicrophoneInputEventSequence

    public init(
        format: MicrophoneInputFormat,
        captureStartedAtMonotonicNanoseconds: UInt64,
        events: AsyncStream<MicrophoneInputEvent>
    ) {
        self.format = format
        self.captureStartedAtMonotonicNanoseconds = captureStartedAtMonotonicNanoseconds
        self.events = MicrophoneInputEventSequence(events: events)
    }

    init(
        format: MicrophoneInputFormat,
        captureStartedAtMonotonicNanoseconds: UInt64,
        events: MicrophoneInputEventSequence
    ) {
        self.format = format
        self.captureStartedAtMonotonicNanoseconds = captureStartedAtMonotonicNanoseconds
        self.events = events
    }
}

public enum MicrophoneInputStartOutcome: Sendable {
    case started(MicrophoneInputFeed)
    case permissionDenied
    case unavailable
}

public protocol MicrophoneInputSource: Sendable {
    /// Authorizes and prepares first, then samples `monotonicClock.captureStart()`
    /// immediately before physical or synthetic capture begins. A successful
    /// feed returns that same instant as its timeline authority.
    func start(
        monotonicClock: any CaptureMonotonicClock
    ) async -> MicrophoneInputStartOutcome
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

    public func start(
        monotonicClock: any CaptureMonotonicClock
    ) async -> MicrophoneInputStartOutcome {
        .unavailable
    }
    public func setMuted(_ muted: Bool) async -> Bool { false }
    public func stop() async {}
}

public struct UnavailableMicrophoneInputSourceFactory: MicrophoneInputSourceFactory {
    public init() {}

    public func makeSource() async -> any MicrophoneInputSource {
        UnavailableMicrophoneInputSource()
    }
}
