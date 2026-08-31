import AVFoundation
import Darwin
import Foundation
import Synchronization

public struct AVFoundationMicrophoneInputSourceFactory: MicrophoneInputSourceFactory {
    public init() {}

    public func makeSource() async -> any MicrophoneInputSource {
        AVFoundationMicrophoneInputSource()
    }
}

/// Owns one AVAudioEngine input tap. It emits only bounded sample/timeline
/// values; permission state, device identity, URLs, and raw AVFoundation errors
/// never cross this Infrastructure boundary.
public actor AVFoundationMicrophoneInputSource: MicrophoneInputSource {
    private var engine: AVAudioEngine?
    private var relay: AVFoundationInputRelay?
    private var configurationObserver: NSObjectProtocol?
    private var hasStarted = false

    public init() {}

    public func start() async -> MicrophoneInputStartOutcome {
        guard !hasStarted else { return .unavailable }
        hasStarted = true

        switch await microphoneAuthorization() {
        case .authorized:
            break
        case .denied:
            return .permissionDenied
        case .unavailable:
            return .unavailable
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite,
              format.sampleRate.rounded() == format.sampleRate,
              (1...384_000).contains(format.sampleRate),
              (1...2).contains(Int(format.channelCount)),
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved
        else {
            return .unavailable
        }

        // A delayed consumer cannot turn the audio callback into an unbounded
        // memory queue. If old chunks are evicted, their absolute sample-frame
        // positions make the loss reappear downstream as a capture gap.
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        let relay = AVFoundationInputRelay(
            continuation: stream.continuation,
            expectedSampleRateHz: UInt32(format.sampleRate),
            expectedChannelCount: Int(format.channelCount)
        )
        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format
        ) { buffer, time in
            relay.accept(buffer: buffer, time: time)
        }
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            relay.interrupt()
        }

        do {
            engine.prepare()
            relay.beginTimeline(atHostTime: mach_absolute_time())
            try engine.start()
        } catch {
            NotificationCenter.default.removeObserver(observer)
            input.removeTap(onBus: 0)
            relay.finish()
            return .unavailable
        }

        self.engine = engine
        self.relay = relay
        configurationObserver = observer
        return .started(MicrophoneInputFeed(events: stream.stream))
    }

    public func stop() async {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        // The tap is detached and the engine quiesced before the relay drains.
        // Therefore finishing the stream is an exact accepted-event watermark.
        relay?.finish()
        engine = nil
        relay = nil
    }

    public func setMuted(_ muted: Bool) async -> Bool {
        relay?.setMuted(muted) ?? false
    }

    private func microphoneAuthorization() async -> MicrophoneAuthorizationOutcome {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            return granted ? .authorized : .denied
        @unknown default:
            return .unavailable
        }
    }
}

private enum MicrophoneAuthorizationOutcome {
    case authorized
    case denied
    case unavailable
}

struct BufferedMicrophoneInputBlock: Equatable {
    let sampleRateHz: UInt32
    let absoluteSampleFrame: Int64
    let hostTime: UInt64
    let channels: [[Float]]
    let muteEpoch: MicrophoneMuteEpoch

    var frameCount: Int { channels.first?.count ?? 0 }
}

/// Preallocated single-producer/single-consumer queue used by the audio tap.
/// The producer copies into fixed storage and advances one release atomic. It
/// never allocates, waits on a lock, or schedules a closure.
final class BoundedMicrophoneInputQueue: @unchecked Sendable {
    enum EnqueueResult: Equatable { case enqueued, full, invalidClock }

    private final class Slot {
        let samples: UnsafeMutablePointer<Float>
        var sampleRateHz: UInt32 = 0
        var absoluteSampleFrame: Int64 = 0
        var hostTime: UInt64 = 0
        var channelCount = 0
        var frameCount = 0
        var muteEpoch = MicrophoneMuteEpoch.initial

        init(sampleCapacity: Int) {
            samples = .allocate(capacity: sampleCapacity)
        }

        deinit { samples.deallocate() }
    }

    let capacity: Int
    let maximumFrames: Int
    private let slots: [Slot]
    private let producer = Atomic<Int>(0)
    private let consumer = Atomic<Int>(0)
    private let latestEndSampleFrame = Atomic<Int64>(0)
    private let latestSampleRate = Atomic<UInt32>(0)
    private let latestChannelCount = Atomic<Int>(0)
    private let latestMuteEpoch = Atomic<UInt64>(0)
    private let callbacksSeen = Atomic<Int>(0)
    private let drops = Atomic<Int>(0)

    init(capacity: Int = 16, maximumFrames: Int) {
        precondition(capacity >= 2)
        precondition(maximumFrames > 0)
        self.capacity = capacity
        self.maximumFrames = maximumFrames
        slots = (0..<capacity).map { _ in
            Slot(sampleCapacity: maximumFrames * 2)
        }
    }

    func enqueue(
        sampleRateHz: UInt32,
        absoluteSampleFrame: Int64,
        hostTime: UInt64,
        channelCount: Int,
        frameCount: Int,
        muteEpoch: MicrophoneMuteEpoch,
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>
    ) -> EnqueueResult {
        guard absoluteSampleFrame >= 0,
              frameCount > 0,
              Int64(frameCount) <= Int64.max - absoluteSampleFrame
        else {
            return .invalidClock
        }
        let end = absoluteSampleFrame + Int64(frameCount)
        latestEndSampleFrame.store(end, ordering: .relaxed)
        latestSampleRate.store(sampleRateHz, ordering: .relaxed)
        latestChannelCount.store(channelCount, ordering: .relaxed)
        latestMuteEpoch.store(
            AVFoundationInputRelay.encode(muteEpoch),
            ordering: .relaxed
        )
        callbacksSeen.wrappingAdd(1, ordering: .relaxed)

        let write = producer.load(ordering: .relaxed)
        let read = consumer.load(ordering: .acquiring)
        guard write - read < capacity else {
            drops.wrappingAdd(1, ordering: .relaxed)
            return .full
        }

        let slot = slots[write % capacity]
        slot.sampleRateHz = sampleRateHz
        slot.absoluteSampleFrame = absoluteSampleFrame
        slot.hostTime = hostTime
        slot.channelCount = channelCount
        slot.frameCount = frameCount
        slot.muteEpoch = muteEpoch
        for channel in 0..<channelCount {
            slot.samples
                .advanced(by: channel * maximumFrames)
                .update(from: channelData[channel], count: frameCount)
        }
        producer.store(write + 1, ordering: .releasing)
        return .enqueued
    }

    func dequeue() -> BufferedMicrophoneInputBlock? {
        let read = consumer.load(ordering: .relaxed)
        let write = producer.load(ordering: .acquiring)
        guard read < write else { return nil }
        let slot = slots[read % capacity]
        var channels: [[Float]] = []
        channels.reserveCapacity(slot.channelCount)
        for channel in 0..<slot.channelCount {
            channels.append(
                Array(
                    UnsafeBufferPointer(
                        start: slot.samples.advanced(by: channel * maximumFrames),
                        count: slot.frameCount
                    )
                )
            )
        }
        let block = BufferedMicrophoneInputBlock(
            sampleRateHz: slot.sampleRateHz,
            absoluteSampleFrame: slot.absoluteSampleFrame,
            hostTime: slot.hostTime,
            channels: channels,
            muteEpoch: slot.muteEpoch
        )
        consumer.store(read + 1, ordering: .releasing)
        return block
    }

    var droppedCallbackCount: Int { drops.load(ordering: .acquiring) }

    var latestCallbackEnd: (
        sampleRateHz: UInt32,
        endSampleFrame: Int64,
        channelCount: Int,
        muteEpoch: MicrophoneMuteEpoch
    )? {
        guard callbacksSeen.load(ordering: .acquiring) > 0 else { return nil }
        return (
            latestSampleRate.load(ordering: .acquiring),
            latestEndSampleFrame.load(ordering: .acquiring),
            latestChannelCount.load(ordering: .acquiring),
            AVFoundationInputRelay.decode(
                latestMuteEpoch.load(ordering: .acquiring)
            )
        )
    }
}

final class AVFoundationInputRelay: @unchecked Sendable {
    /// AVAudioEngine is configured for 1,024 frames. Eight callbacks' worth is
    /// the largest single delivery accepted before any channel-array allocation.
    static let maximumAcceptedFramesPerCallback = 8_192

    private let continuation: AsyncStream<MicrophoneInputEvent>.Continuation
    private let expectedSampleRateHz: UInt32?
    private let expectedChannelCount: Int?
    private let ring: BoundedMicrophoneInputQueue
    private let drainQueue: DispatchQueue
    private var drainSource: DispatchSourceUserDataAdd!
    private let terminal = Atomic<Int>(0)
    private let timelineOriginHostTime = Atomic<UInt64>(0)
    private let encodedMuteEpoch = Atomic<UInt64>(0)
    private var baselineSampleFrame: Int64?
    private var baselineRelativeFrame: UInt64 = 0
    private var deliveredInputEnd: UInt64 = 0
    private var finished = false

    init(
        continuation: AsyncStream<MicrophoneInputEvent>.Continuation,
        expectedSampleRateHz: UInt32? = nil,
        expectedChannelCount: Int? = nil,
        queueCapacity: Int = 16,
        drainQueue: DispatchQueue? = nil
    ) {
        self.continuation = continuation
        self.expectedSampleRateHz = expectedSampleRateHz
        self.expectedChannelCount = expectedChannelCount
        self.drainQueue = drainQueue ?? DispatchQueue(
            label: "com.audora.microphone-input-relay.drain",
            qos: .userInitiated
        )
        ring = BoundedMicrophoneInputQueue(
            capacity: queueCapacity,
            maximumFrames: Self.maximumAcceptedFramesPerCallback
        )
        let source = DispatchSource.makeUserDataAddSource(queue: drainQueue)
        drainSource = source
        source.setEventHandler { [weak self] in self?.drainAcceptedBlocks() }
        source.resume()
    }

    func beginTimeline(atHostTime hostTime: UInt64) {
        _ = timelineOriginHostTime.compareExchange(
            expected: 0,
            desired: hostTime,
            ordering: .releasing
        )
    }

    func setMuted(_ muted: Bool) -> Bool {
        guard terminal.load(ordering: .acquiring) == 0 else { return false }
        let current = Self.decode(encodedMuteEpoch.load(ordering: .acquiring))
        guard current.isMuted != muted else { return true }
        guard current.sequence < UInt64.max >> 1 else { return false }
        let epoch = MicrophoneMuteEpoch(
            sequence: current.sequence + 1,
            isMuted: muted
        )
        encodedMuteEpoch.store(Self.encode(epoch), ordering: .releasing)
        drainQueue.sync {
            drainAcceptedBlocks()
            emitTrailingOverflowGapIfNeeded()
            continuation.yield(
                .muteChanged(
                    epoch: epoch,
                    effectiveInputFrame: deliveredInputEnd
                )
            )
        }
        return true
    }

    func accept(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard terminal.load(ordering: .acquiring) == 0 else { return }
        let muteEpoch = Self.decode(encodedMuteEpoch.load(ordering: .acquiring))
        guard time.isSampleTimeValid,
              Int64(time.sampleTime) >= 0,
              Int64(frameCount) <= Int64.max - Int64(time.sampleTime),
              (expectedSampleRateHz == nil || expectedChannelCount == nil ||
                  (time.isHostTimeValid &&
                      timelineOriginHostTime.load(ordering: .acquiring) > 0))
        else {
            invalidateClock()
            return
        }
        guard frameCount > 0,
              frameCount <= Self.maximumAcceptedFramesPerCallback,
              (1...2).contains(channelCount),
              let channelData = buffer.floatChannelData,
              buffer.format.sampleRate.isFinite,
              buffer.format.sampleRate.rounded() == buffer.format.sampleRate,
              (1...384_000).contains(buffer.format.sampleRate),
              expectedSampleRateHz.map({ $0 == UInt32(buffer.format.sampleRate) }) ?? true,
              expectedChannelCount.map({ $0 == channelCount }) ?? true
        else {
            interrupt()
            return
        }
        let enqueue = ring.enqueue(
            sampleRateHz: UInt32(buffer.format.sampleRate),
            absoluteSampleFrame: Int64(time.sampleTime),
            hostTime: time.isHostTimeValid ? time.hostTime : 0,
            channelCount: channelCount,
            frameCount: frameCount,
            muteEpoch: muteEpoch,
            channelData: UnsafePointer(channelData)
        )
        if enqueue == .invalidClock {
            invalidateClock()
            return
        }
        // DispatchSource coalesces signals and has one preinstalled handler;
        // callback traffic cannot create an unbounded closure queue.
        drainSource.add(data: 1)
    }

    func interrupt() {
        let result = terminal.compareExchange(
            expected: 0,
            desired: 2,
            ordering: .acquiringAndReleasing
        )
        if result.exchanged {
            drainSource.add(data: 1)
        }
    }

    func finish() {
        _ = terminal.compareExchange(
            expected: 0,
            desired: 1,
            ordering: .acquiringAndReleasing
        )
        drainQueue.sync {
            drainAcceptedBlocks()
        }
    }

    private func invalidateClock() {
        let result = terminal.compareExchange(
            expected: 0,
            desired: 3,
            ordering: .acquiringAndReleasing
        )
        if result.exchanged {
            drainSource.add(data: 1)
        }
    }

    private func drainAcceptedBlocks() {
        guard !finished else { return }
        while let block = ring.dequeue() {
            guard project(block) else {
                terminal.store(3, ordering: .releasing)
                break
            }
        }
        let terminalKind = terminal.load(ordering: .acquiring)
        guard terminalKind != 0 else { return }

        emitTrailingOverflowGapIfNeeded()
        switch terminalKind {
        case 2:
            continuation.yield(.interrupted)
        case 3:
            continuation.yield(.clockBecameInvalid)
        default:
            break
        }
        finished = true
        continuation.finish()
        drainSource.cancel()
    }

    private func project(_ block: BufferedMicrophoneInputBlock) -> Bool {
        if baselineSampleFrame == nil {
            baselineSampleFrame = block.absoluteSampleFrame
            let origin = timelineOriginHostTime.load(ordering: .acquiring)
            if origin > 0 {
                guard block.hostTime >= origin else { return false }
                let seconds = AVAudioTime.seconds(forHostTime: block.hostTime - origin)
                let frames = seconds * Double(block.sampleRateHz)
                guard frames.isFinite,
                      frames >= 0,
                      // Double(UInt64.max) rounds up to exactly 2^64, which
                      // is not representable by UInt64 and would trap.
                      frames < Double(UInt64.max)
                else { return false }
                baselineRelativeFrame = UInt64(frames.rounded(.down))
            }
        }
        guard let baselineSampleFrame,
              block.absoluteSampleFrame >= baselineSampleFrame
        else { return false }
        let delta = UInt64(block.absoluteSampleFrame - baselineSampleFrame)
        let (relative, overflow) = baselineRelativeFrame.addingReportingOverflow(delta)
        guard !overflow,
              let chunk = try? MicrophoneInputChunk(
                  sampleRateHz: block.sampleRateHz,
                  startSampleFrame: relative,
                  channels: block.channels,
                  muteEpoch: block.muteEpoch
              ),
              chunk.frameCount <= UInt64.max - relative
        else { return false }
        deliveredInputEnd = max(deliveredInputEnd, relative + chunk.frameCount)
        continuation.yield(.chunk(chunk))
        return true
    }

    private func emitTrailingOverflowGapIfNeeded() {
        guard ring.droppedCallbackCount > 0,
              let latest = ring.latestCallbackEnd,
              let baselineSampleFrame,
              latest.endSampleFrame >= baselineSampleFrame
        else { return }
        let delta = UInt64(latest.endSampleFrame - baselineSampleFrame)
        let (latestRelativeEnd, overflow) = baselineRelativeFrame.addingReportingOverflow(delta)
        guard !overflow, latestRelativeEnd > deliveredInputEnd else { return }
        continuation.yield(
            .captureGap(
                sampleRateHz: latest.sampleRateHz,
                startSampleFrame: deliveredInputEnd,
                frameCount: latestRelativeEnd - deliveredInputEnd,
                channelCount: UInt8(latest.channelCount),
                muteEpoch: latest.muteEpoch
            )
        )
        deliveredInputEnd = latestRelativeEnd
    }

    static func encode(_ epoch: MicrophoneMuteEpoch) -> UInt64 {
        (epoch.sequence << 1) | (epoch.isMuted ? 1 : 0)
    }

    static func decode(_ encoded: UInt64) -> MicrophoneMuteEpoch {
        MicrophoneMuteEpoch(
            sequence: encoded >> 1,
            isMuted: encoded & 1 == 1
        )
    }
}
