import AudioToolbox
import AVFoundation
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

    public func start(
        monotonicClock: any CaptureMonotonicClock
    ) async -> MicrophoneInputStartOutcome {
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

        guard let inputFormat = try? MicrophoneInputFormat(
            sampleRateHz: UInt32(format.sampleRate),
            channelCount: UInt8(format.channelCount)
        ) else {
            return .unavailable
        }
        let relay = AVFoundationInputRelay(
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
            let captureStart = await monotonicClock.captureStart()
            guard let audioHostTime = captureStart.audioHostTime else {
                NotificationCenter.default.removeObserver(observer)
                input.removeTap(onBus: 0)
                relay.finish()
                return .unavailable
            }
            relay.beginTimeline(atHostTime: audioHostTime)
            try engine.start()

            self.engine = engine
            self.relay = relay
            configurationObserver = observer
            return .started(
                MicrophoneInputFeed(
                    format: inputFormat,
                    captureStartedAtMonotonicNanoseconds: captureStart.uptimeNanoseconds,
                    events: relay.eventFeed
                )
            )
        } catch {
            NotificationCenter.default.removeObserver(observer)
            input.removeTap(onBus: 0)
            relay.finish()
            return .unavailable
        }
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
    let carriesSamples: Bool
    let channelCount: Int
    let frameCount: Int
}

/// Two parity lanes retain bounded timing evidence without allocating on an
/// input callback. A short sequence lock makes a concurrent drain either claim
/// one complete snapshot or leave it for the next pass.
final class BoundedMicrophoneDropEvidence: @unchecked Sendable {
    typealias Snapshot = (
        sampleRateHz: UInt32,
        startSampleFrame: Int64,
        endSampleFrame: Int64,
        hostTime: UInt64,
        channelCount: Int
    )

    private final class Lane {
        let count = Atomic<Int>(0)
        let end = Atomic<Int64>(0)
        let start = Atomic<Int64>(0)
        let hostTime = Atomic<UInt64>(0)
        let rate = Atomic<UInt32>(0)
        let channels = Atomic<Int>(0)
        let sequence = Atomic<UInt64>(0)
    }

    private let even = Lane()
    private let odd = Lane()

    func record(
        sampleRateHz: UInt32,
        startSampleFrame: Int64,
        endSampleFrame: Int64,
        hostTime: UInt64,
        channelCount: Int,
        epoch: MicrophoneMuteEpoch
    ) -> Bool {
        let lane = epoch.sequence.isMultiple(of: 2) ? even : odd
        let sequence = lane.sequence.load(ordering: .acquiring)
        guard sequence.isMultiple(of: 2),
              lane.sequence.compareExchange(
                expected: sequence,
                desired: sequence &+ 1,
                ordering: .acquiringAndReleasing
              ).exchanged
        else { return false }
        let count = lane.count.load(ordering: .relaxed)
        guard count < .max else {
            lane.sequence.store(sequence &+ 2, ordering: .releasing)
            return false
        }
        if count == 0 {
            lane.start.store(startSampleFrame, ordering: .relaxed)
            lane.hostTime.store(hostTime, ordering: .relaxed)
            lane.rate.store(sampleRateHz, ordering: .relaxed)
            lane.channels.store(channelCount, ordering: .relaxed)
        } else {
            let previousEnd = lane.end.load(ordering: .relaxed)
            guard sampleRateHz == lane.rate.load(ordering: .relaxed),
                  channelCount == lane.channels.load(ordering: .relaxed),
                  startSampleFrame >= previousEnd,
                  endSampleFrame > previousEnd
            else {
                lane.sequence.store(sequence &+ 2, ordering: .releasing)
                return false
            }
        }
        lane.end.store(endSampleFrame, ordering: .relaxed)
        lane.count.store(count + 1, ordering: .releasing)
        lane.sequence.store(sequence &+ 2, ordering: .releasing)
        return true
    }

    func take(for epoch: MicrophoneMuteEpoch) -> Snapshot? {
        let lane = epoch.sequence.isMultiple(of: 2) ? even : odd
        let sequence = lane.sequence.load(ordering: .acquiring)
        guard sequence.isMultiple(of: 2),
              lane.sequence.compareExchange(
                expected: sequence,
                desired: sequence &+ 1,
                ordering: .acquiringAndReleasing
              ).exchanged
        else { return nil }
        let count = lane.count.exchange(0, ordering: .acquiringAndReleasing)
        let snapshot: Snapshot = (
            lane.rate.load(ordering: .acquiring),
            lane.start.load(ordering: .acquiring),
            lane.end.load(ordering: .acquiring),
            lane.hostTime.load(ordering: .acquiring),
            lane.channels.load(ordering: .acquiring)
        )
        lane.sequence.store(sequence &+ 2, ordering: .releasing)
        guard count > 0 else { return nil }
        return snapshot
    }
}

/// Preallocated single-producer/single-consumer queue used by the audio tap.
/// The producer copies into fixed storage and advances one release atomic. It
/// never allocates, waits on a lock, or schedules a closure.
final class BoundedMicrophoneInputQueue: @unchecked Sendable {
    enum EnqueueResult: Equatable { case enqueued, full, evidenceContended, invalidClock }

    private final class Slot {
        let samples: UnsafeMutablePointer<Float>
        var sampleRateHz: UInt32 = 0
        var absoluteSampleFrame: Int64 = 0
        var hostTime: UInt64 = 0
        var channelCount = 0
        var frameCount = 0
        var muteEpoch = MicrophoneMuteEpoch.initial
        var carriesSamples = false

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
    private let dropEvidence = BoundedMicrophoneDropEvidence()

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
        let write = producer.load(ordering: .relaxed)
        let read = consumer.load(ordering: .acquiring)
        guard write - read < capacity else {
            guard recordDrop(
                sampleRateHz: sampleRateHz,
                startSampleFrame: absoluteSampleFrame,
                endSampleFrame: end,
                hostTime: hostTime,
                channelCount: channelCount,
                epoch: muteEpoch
            ) else { return .evidenceContended }
            return .full
        }

        let slot = slots[write % capacity]
        slot.sampleRateHz = sampleRateHz
        slot.absoluteSampleFrame = absoluteSampleFrame
        slot.hostTime = hostTime
        slot.channelCount = channelCount
        slot.frameCount = frameCount
        slot.muteEpoch = muteEpoch
        slot.carriesSamples = true
        for channel in 0..<channelCount {
            slot.samples
                .advanced(by: channel * maximumFrames)
                .update(from: channelData[channel], count: frameCount)
        }
        producer.store(write + 1, ordering: .releasing)
        return .enqueued
    }

    /// The microphone callback remains bounded while muted, but deliberately
    /// never reads or copies its raw sample pointers.  The consumer receives
    /// only timing and mute-epoch evidence.
    func enqueueMutedTiming(
        sampleRateHz: UInt32,
        absoluteSampleFrame: Int64,
        hostTime: UInt64,
        channelCount: Int,
        frameCount: Int,
        muteEpoch: MicrophoneMuteEpoch
    ) -> EnqueueResult {
        guard absoluteSampleFrame >= 0,
              frameCount > 0,
              Int64(frameCount) <= Int64.max - absoluteSampleFrame
        else {
            return .invalidClock
        }
        let end = absoluteSampleFrame + Int64(frameCount)
        let write = producer.load(ordering: .relaxed)
        let read = consumer.load(ordering: .acquiring)
        guard write - read < capacity else {
            guard recordDrop(
                sampleRateHz: sampleRateHz,
                startSampleFrame: absoluteSampleFrame,
                endSampleFrame: end,
                hostTime: hostTime,
                channelCount: channelCount,
                epoch: muteEpoch
            ) else { return .evidenceContended }
            return .full
        }
        let slot = slots[write % capacity]
        slot.sampleRateHz = sampleRateHz
        slot.absoluteSampleFrame = absoluteSampleFrame
        slot.hostTime = hostTime
        slot.channelCount = channelCount
        slot.frameCount = frameCount
        slot.muteEpoch = muteEpoch
        slot.carriesSamples = false
        producer.store(write + 1, ordering: .releasing)
        return .enqueued
    }

    func dequeue(through watermark: Int = .max) -> BufferedMicrophoneInputBlock? {
        let read = consumer.load(ordering: .relaxed)
        let write = producer.load(ordering: .acquiring)
        guard read < write, read < watermark else { return nil }
        let slot = slots[read % capacity]
        var channels: [[Float]] = []
        if slot.carriesSamples {
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
        }
        let block = BufferedMicrophoneInputBlock(
            sampleRateHz: slot.sampleRateHz,
            absoluteSampleFrame: slot.absoluteSampleFrame,
            hostTime: slot.hostTime,
            channels: channels,
            muteEpoch: slot.muteEpoch,
            carriesSamples: slot.carriesSamples,
            channelCount: slot.channelCount,
            frameCount: slot.frameCount
        )
        consumer.store(read + 1, ordering: .releasing)
        return block
    }

    var publicationWatermark: Int { producer.load(ordering: .acquiring) }

    func recordDrop(
        sampleRateHz: UInt32,
        startSampleFrame: Int64,
        endSampleFrame: Int64,
        hostTime: UInt64,
        channelCount: Int,
        epoch: MicrophoneMuteEpoch
    ) -> Bool {
        dropEvidence.record(
            sampleRateHz: sampleRateHz,
            startSampleFrame: startSampleFrame,
            endSampleFrame: endSampleFrame,
            hostTime: hostTime,
            channelCount: channelCount,
            epoch: epoch
        )
    }

    func takeDropEvidence(for epoch: MicrophoneMuteEpoch) -> (
        sampleRateHz: UInt32,
        startSampleFrame: Int64,
        endSampleFrame: Int64,
        hostTime: UInt64,
        channelCount: Int
    )? {
        dropEvidence.take(for: epoch)
    }
}

/// Event-driven, single-consumer broker between the bounded raw-input ring and
/// capture.  Unlike `AsyncStream(bufferingNewest:)`, it has no second hidden
/// eviction policy: source data is compacted into explicit timing evidence,
/// while mute and terminal barriers retain source order.
final class LossAwareMicrophoneEventBroker: @unchecked Sendable {
    private final class CancellationToken: @unchecked Sendable {
        let cancelled = Atomic<Bool>(false)
    }

    private struct WaitingConsumer {
        let id: UUID
        let token: CancellationToken
        let continuation: CheckedContinuation<MicrophoneInputEvent?, Never>
    }

    private let pendingCapacity: Int
    private var pending: [MicrophoneInputEvent] = []
    private var finishRequested = false
    private var saturationFailure = false
    private var waitingConsumer: WaitingConsumer?
    private let lock = NSLock()
    private let afterWaiterInstalled: (@Sendable () -> Void)?
    private let beforeCancellationLock: (@Sendable () -> Void)?
    private let afterCancelledWaiterEventBuffered: (@Sendable () -> Void)?
    private let afterBufferedEventDequeued: (@Sendable () -> Void)?

    init(
        pendingCapacity: Int = 16,
        afterWaiterInstalled: (@Sendable () -> Void)? = nil,
        beforeCancellationLock: (@Sendable () -> Void)? = nil,
        afterCancelledWaiterEventBuffered: (@Sendable () -> Void)? = nil,
        afterBufferedEventDequeued: (@Sendable () -> Void)? = nil
    ) {
        self.pendingCapacity = pendingCapacity
        self.afterWaiterInstalled = afterWaiterInstalled
        self.beforeCancellationLock = beforeCancellationLock
        self.afterCancelledWaiterEventBuffered = afterCancelledWaiterEventBuffered
        self.afterBufferedEventDequeued = afterBufferedEventDequeued
    }

    func publish(_ event: MicrophoneInputEvent) {
        lock.lock()
        guard !finishRequested else {
            lock.unlock()
            return
        }
        if let waitingConsumer,
           waitingConsumer.token.cancelled.load(ordering: .acquiring)
        {
            // Cancellation linearized before this publication. Preserve the
            // event, but leave detachment and nil resumption to cancelWaiter.
            // Resuming here can circularly wait on Task.cancel(), which is
            // synchronously running that task's cancellation handler.
            appendLossAware(event)
            lock.unlock()
            afterCancelledWaiterEventBuffered?()
            return
        }
        if let waitingConsumer {
            self.waitingConsumer = nil
            lock.unlock()
            waitingConsumer.continuation.resume(returning: event)
            return
        }
        appendLossAware(event)
        lock.unlock()
    }

    /// Publishes a control barrier and its optional data prefix as one broker
    /// transaction. `beforeVisible` runs while the broker lock still excludes
    /// consumers, so relay authority can advance before the barrier is either
    /// resumed directly or made available in `pending`.
    func publishBarrier(
        _ barrier: MicrophoneInputEvent,
        followedBy prefix: MicrophoneInputEvent?,
        beforeVisible: () -> Void
    ) {
        let directConsumer: CheckedContinuation<MicrophoneInputEvent?, Never>?
        var bufferedBehindCancelledConsumer = false
        lock.lock()
        guard !finishRequested else {
            beforeVisible()
            lock.unlock()
            return
        }
        if let waitingConsumer,
           waitingConsumer.token.cancelled.load(ordering: .acquiring)
        {
            appendLossAware(barrier)
            if let prefix, !finishRequested { appendLossAware(prefix) }
            beforeVisible()
            bufferedBehindCancelledConsumer = true
            directConsumer = nil
        } else if let waitingConsumer {
            self.waitingConsumer = nil
            if let prefix { appendLossAware(prefix) }
            beforeVisible()
            directConsumer = waitingConsumer.continuation
        } else {
            appendLossAware(barrier)
            if let prefix, !finishRequested { appendLossAware(prefix) }
            beforeVisible()
            directConsumer = nil
        }
        lock.unlock()
        if bufferedBehindCancelledConsumer {
            afterCancelledWaiterEventBuffered?()
        }
        directConsumer?.resume(returning: barrier)
    }

    func finish() {
        let waitingConsumer: WaitingConsumer?
        lock.lock()
        finishRequested = true
        waitingConsumer = pending.isEmpty ? self.waitingConsumer : nil
        if waitingConsumer != nil {
            self.waitingConsumer = nil
        }
        lock.unlock()
        waitingConsumer?.continuation.resume(returning: nil)
    }

    private func appendLossAware(_ event: MicrophoneInputEvent) {
        while pending.count >= pendingCapacity, compactOneAdjacentDataPair() {}
        guard pending.count < pendingCapacity else {
            // There is no polling or silent eviction on saturation.  A
            // subsequent consumer observes this terminal evidence after the
            // already ordered buffer; capture fails closed rather than
            // misclassifying an omitted control barrier.
            saturationFailure = true
            finishRequested = true
            return
        }
        pending.append(event)
    }

    func next() async -> MicrophoneInputEvent? {
        let id = UUID()
        let token = CancellationToken()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                lock.lock()
                if token.cancelled.load(ordering: .acquiring) {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                if !pending.isEmpty {
                    let event = pending.removeFirst()
                    lock.unlock()
                    afterBufferedEventDequeued?()
                    continuation.resume(returning: event)
                    return
                }
                if saturationFailure {
                    saturationFailure = false
                    lock.unlock()
                    continuation.resume(returning: .clockBecameInvalid)
                    return
                }
                if finishRequested {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                precondition(waitingConsumer == nil, "microphone input feed has multiple consumers")
                waitingConsumer = WaitingConsumer(
                    id: id,
                    token: token,
                    continuation: continuation
                )
                lock.unlock()
                afterWaiterInstalled?()
            }
        }, onCancel: { [weak self] in
            self?.cancelWaiter(id, token: token)
        })
    }

    private func cancelWaiter(_ id: UUID, token: CancellationToken) {
        let continuation: CheckedContinuation<MicrophoneInputEvent?, Never>?
        token.cancelled.store(true, ordering: .releasing)
        beforeCancellationLock?()
        lock.lock()
        if waitingConsumer?.id == id,
           waitingConsumer?.token === token
        {
            continuation = waitingConsumer?.continuation
            waitingConsumer = nil
        } else {
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: nil)
    }

    /// Collapsing a pair represents every covered input frame as an explicit
    /// source loss, retaining the pair's position relative to controls.
    private func compactOneAdjacentDataPair() -> Bool {
        guard pending.count > 1 else { return false }
        for index in 0..<(pending.count - 1) {
            guard let first = lossRange(for: pending[index]),
                  let second = lossRange(for: pending[index + 1]),
                  first.sampleRateHz == second.sampleRateHz,
                  first.channelCount == second.channelCount,
                  first.epoch == second.epoch,
                  first.endSampleFrame <= second.startSampleFrame
            else { continue }
            pending[index] = compactedEvent(
                first: pending[index],
                second: pending[index + 1],
                range: (
                    first.sampleRateHz,
                    first.startSampleFrame,
                    second.endSampleFrame,
                    first.channelCount,
                    first.epoch
                )
            )
            pending.remove(at: index + 1)
            return true
        }
        return false
    }

    private func compactedEvent(
        first: MicrophoneInputEvent,
        second: MicrophoneInputEvent,
        range: (
            sampleRateHz: UInt32,
            startSampleFrame: UInt64,
            endSampleFrame: UInt64,
            channelCount: UInt8,
            epoch: MicrophoneMuteEpoch
        )
    ) -> MicrophoneInputEvent {
        let count = range.endSampleFrame - range.startSampleFrame
        if case .mutedInterval = first, case .mutedInterval = second {
            return .mutedInterval(
                sampleRateHz: range.sampleRateHz,
                startSampleFrame: range.startSampleFrame,
                frameCount: count,
                channelCount: range.channelCount,
                muteEpoch: range.epoch
            )
        }
        return .captureGap(
            sampleRateHz: range.sampleRateHz,
            startSampleFrame: range.startSampleFrame,
            frameCount: count,
            channelCount: range.channelCount,
            muteEpoch: range.epoch
        )
    }

    private func lossRange(for event: MicrophoneInputEvent) -> (
        sampleRateHz: UInt32,
        startSampleFrame: UInt64,
        endSampleFrame: UInt64,
        channelCount: UInt8,
        epoch: MicrophoneMuteEpoch
    )? {
        switch event {
        case let .chunk(chunk):
            return (
                chunk.sampleRateHz,
                chunk.startSampleFrame,
                chunk.startSampleFrame + chunk.frameCount,
                UInt8(chunk.channels.count),
                chunk.muteEpoch
            )
        case let .captureGap(rate, start, count, channels, epoch),
             let .mutedInterval(rate, start, count, channels, epoch):
            return (rate, start, start + count, channels, epoch)
        case .muteChanged, .interrupted, .clockBecameInvalid:
            return nil
        }
    }

}

final class AVFoundationInputRelay: @unchecked Sendable {
    /// AVAudioEngine is configured for 1,024 frames. Eight callbacks' worth is
    /// the largest single delivery accepted before any channel-array allocation.
    static let maximumAcceptedFramesPerCallback = 8_192
    private static let inactiveMuteFenceRegistration = Int.min

    private enum CallbackMuteFencePosition: Equatable {
        case outsideFence
        case registeredBeforeClosure
        case afterClosure
        case invalid
    }

    private struct SampledCallbackAuthority {
        let muteEpoch: MicrophoneMuteEpoch
        let fencePosition: CallbackMuteFencePosition
    }

    private let broker: LossAwareMicrophoneEventBroker
    private var testForwardingTask: Task<Void, Never>?
    private let expectedSampleRateHz: UInt32?
    private let expectedChannelCount: Int?
    private let ring: BoundedMicrophoneInputQueue
    private let preAcknowledgementEvidence = BoundedMicrophoneDropEvidence()
    private let drainQueue: DispatchQueue
    private var drainSource: DispatchSourceUserDataAdd!
    private let terminal = Atomic<Int>(0)
    private let timelineOriginHostTime = Atomic<UInt64>(0)
    private let encodedMuteEpoch = Atomic<UInt64>(0)
    private let publishedMuteEpoch = Atomic<UInt64>(0)
    private let evenEpochCallbacks = Atomic<Int>(0)
    private let oddEpochCallbacks = Atomic<Int>(0)
    private let callbackEpochSampled: (@Sendable () -> Void)?
    private let afterBlockProjected: (@Sendable () -> Void)?
    private let afterMuteFenceClosed: (@Sendable () -> Void)?
    private let beforeMuteAcknowledgement: (@Sendable () -> Void)?
    private let beforeMuteAcknowledgementVisible: (@Sendable () -> Void)?
    private let beforeTerminalFinalization: (@Sendable () -> Void)?
    private let whileControlLockHeld: (@Sendable () -> Void)?
    private let afterTerminalLifetimeReleased: (@Sendable () -> Void)?
    private let controlLock = NSLock()
    /// The target epoch of the single asynchronous mute fence, or zero.
    private let pendingMuteFence = Atomic<UInt64>(0)
    /// Nonnegative values are an open fence's registered new-epoch callback
    /// count. Negative values encode a closed fence with `-value - 1`
    /// callbacks still completing. `Int.min` means no fence is installed.
    private let muteFenceRegistration = Atomic<Int>(Int.min)
    /// Keeps the relay and its broker alive after a source releases its last
    /// reference while an already-retained callback crosses a terminal fence.
    private var terminalLifetime: AVFoundationInputRelay?
    private var baselineSampleFrame: Int64?
    private var baselineRelativeFrame: UInt64 = 0
    private var deliveredInputEnd: UInt64 = 0
    private var finished = false

    init(
        continuation: AsyncStream<MicrophoneInputEvent>.Continuation,
        expectedSampleRateHz: UInt32? = nil,
        expectedChannelCount: Int? = nil,
        queueCapacity: Int = 16,
        drainQueue: DispatchQueue? = nil,
        callbackEpochSampled: (@Sendable () -> Void)? = nil,
        afterBlockProjected: (@Sendable () -> Void)? = nil,
        afterMuteFenceClosed: (@Sendable () -> Void)? = nil,
        beforeMuteAcknowledgement: (@Sendable () -> Void)? = nil,
        beforeMuteAcknowledgementVisible: (@Sendable () -> Void)? = nil,
        beforeTerminalFinalization: (@Sendable () -> Void)? = nil,
        whileControlLockHeld: (@Sendable () -> Void)? = nil,
        afterTerminalLifetimeReleased: (@Sendable () -> Void)? = nil
    ) {
        self.expectedSampleRateHz = expectedSampleRateHz
        self.expectedChannelCount = expectedChannelCount
        self.drainQueue = drainQueue ?? DispatchQueue(
            label: "com.audora.microphone-input-relay.drain",
            qos: .userInitiated
        )
        self.callbackEpochSampled = callbackEpochSampled
        self.afterBlockProjected = afterBlockProjected
        self.afterMuteFenceClosed = afterMuteFenceClosed
        self.beforeMuteAcknowledgement = beforeMuteAcknowledgement
        self.beforeMuteAcknowledgementVisible = beforeMuteAcknowledgementVisible
        self.beforeTerminalFinalization = beforeTerminalFinalization
        self.whileControlLockHeld = whileControlLockHeld
        self.afterTerminalLifetimeReleased = afterTerminalLifetimeReleased
        broker = LossAwareMicrophoneEventBroker()
        ring = BoundedMicrophoneInputQueue(
            capacity: queueCapacity,
            maximumFrames: Self.maximumAcceptedFramesPerCallback
        )
        let source = DispatchSource.makeUserDataAddSource(queue: self.drainQueue)
        drainSource = source
        source.setEventHandler { [weak self] in self?.drainAcceptedBlocks() }
        source.resume()
        testForwardingTask = Task { [broker] in
            while let event = await broker.next() {
                continuation.yield(event)
            }
            continuation.finish()
        }
        terminalLifetime = self
    }

    init(
        expectedSampleRateHz: UInt32? = nil,
        expectedChannelCount: Int? = nil,
        queueCapacity: Int = 16,
        drainQueue: DispatchQueue? = nil,
        callbackEpochSampled: (@Sendable () -> Void)? = nil,
        afterBlockProjected: (@Sendable () -> Void)? = nil,
        afterMuteFenceClosed: (@Sendable () -> Void)? = nil,
        beforeMuteAcknowledgement: (@Sendable () -> Void)? = nil,
        beforeMuteAcknowledgementVisible: (@Sendable () -> Void)? = nil,
        beforeTerminalFinalization: (@Sendable () -> Void)? = nil,
        whileControlLockHeld: (@Sendable () -> Void)? = nil,
        afterTerminalLifetimeReleased: (@Sendable () -> Void)? = nil
    ) {
        self.expectedSampleRateHz = expectedSampleRateHz
        self.expectedChannelCount = expectedChannelCount
        self.drainQueue = drainQueue ?? DispatchQueue(
            label: "com.audora.microphone-input-relay.drain",
            qos: .userInitiated
        )
        self.callbackEpochSampled = callbackEpochSampled
        self.afterBlockProjected = afterBlockProjected
        self.afterMuteFenceClosed = afterMuteFenceClosed
        self.beforeMuteAcknowledgement = beforeMuteAcknowledgement
        self.beforeMuteAcknowledgementVisible = beforeMuteAcknowledgementVisible
        self.beforeTerminalFinalization = beforeTerminalFinalization
        self.whileControlLockHeld = whileControlLockHeld
        self.afterTerminalLifetimeReleased = afterTerminalLifetimeReleased
        broker = LossAwareMicrophoneEventBroker()
        ring = BoundedMicrophoneInputQueue(
            capacity: queueCapacity,
            maximumFrames: Self.maximumAcceptedFramesPerCallback
        )
        let source = DispatchSource.makeUserDataAddSource(queue: self.drainQueue)
        drainSource = source
        source.setEventHandler { [weak self] in self?.drainAcceptedBlocks() }
        source.resume()
        terminalLifetime = self
    }

    var eventFeed: MicrophoneInputEventSequence {
        MicrophoneInputEventSequence { [broker] in await broker.next() }
    }

    func beginTimeline(atHostTime hostTime: UInt64) {
        _ = timelineOriginHostTime.compareExchange(
            expected: 0,
            desired: hostTime,
            ordering: .releasing
        )
    }

    func setMuted(_ muted: Bool) -> Bool {
        controlLock.lock()
        defer { controlLock.unlock() }
        whileControlLockHeld?()
        guard terminal.load(ordering: .sequentiallyConsistent) == 0 else { return false }
        guard pendingMuteFence.load(ordering: .acquiring) == 0 else { return false }
        let current = Self.decode(
            encodedMuteEpoch.load(ordering: .sequentiallyConsistent)
        )
        guard current.isMuted != muted else { return true }
        guard current.sequence < UInt64.max >> 1 else { return false }
        let epoch = MicrophoneMuteEpoch(
            sequence: current.sequence + 1,
            isMuted: muted
        )
        // The command is accepted as soon as the new callback epoch and its
        // pending source-order fence are visible. Install the open registration
        // gate first so no callback can observe the new epoch without being
        // classified on one side of the acknowledgement boundary.
        guard muteFenceRegistration.load(ordering: .acquiring) ==
            Self.inactiveMuteFenceRegistration
        else { return false }
        let encoded = Self.encode(epoch)
        muteFenceRegistration.store(0, ordering: .releasing)
        pendingMuteFence.store(encoded, ordering: .releasing)
        encodedMuteEpoch.store(encoded, ordering: .sequentiallyConsistent)
        drainSource.add(data: 1)
        return true
    }

    func accept(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard terminal.load(ordering: .sequentiallyConsistent) == 0 else { return }
        guard let authority = sampleMuteEpochForCallback() else { return }
        let muteEpoch = authority.muteEpoch
        defer {
            if authority.fencePosition == .registeredBeforeClosure {
                releaseMuteFenceRegistration()
            }
            releaseCallbackEpoch(muteEpoch)
            // The first drain may have observed this callback in flight. Its
            // release is therefore the asynchronous signal for both mute and
            // terminal fences; no accepted callback can appear after EOF.
            if pendingMuteFence.load(ordering: .acquiring) != 0 ||
                terminal.load(ordering: .sequentiallyConsistent) != 0
            {
                drainSource.add(data: 1)
            }
        }
        callbackEpochSampled?()
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
              buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              buffer.format.sampleRate.isFinite,
              buffer.format.sampleRate.rounded() == buffer.format.sampleRate,
              (1...384_000).contains(buffer.format.sampleRate),
              time.sampleRate.isFinite,
              time.sampleRate == buffer.format.sampleRate,
              expectedSampleRateHz.map({ $0 == UInt32(buffer.format.sampleRate) }) ?? true,
              expectedSampleRateHz.map({ $0 == UInt32(time.sampleRate) }) ?? true,
              expectedChannelCount.map({ $0 == channelCount }) ?? true
        else {
            interrupt()
            return
        }
        if authority.fencePosition == .invalid {
            invalidateClock()
            return
        }
        if authority.fencePosition == .registeredBeforeClosure {
            guard preAcknowledgementEvidence.record(
                sampleRateHz: UInt32(buffer.format.sampleRate),
                startSampleFrame: Int64(time.sampleTime),
                endSampleFrame: Int64(time.sampleTime) + Int64(frameCount),
                hostTime: time.isHostTimeValid ? time.hostTime : 0,
                channelCount: channelCount,
                epoch: muteEpoch
            ) else {
                invalidateClock()
                return
            }
            drainSource.add(data: 1)
            return
        }
        if authority.fencePosition == .outsideFence,
           Self.decode(publishedMuteEpoch.load(ordering: .acquiring)) != muteEpoch
        {
            invalidateClock()
            return
        }
        let enqueue: BoundedMicrophoneInputQueue.EnqueueResult
        if muteEpoch.isMuted {
            enqueue = ring.enqueueMutedTiming(
                sampleRateHz: UInt32(buffer.format.sampleRate),
                absoluteSampleFrame: Int64(time.sampleTime),
                hostTime: time.isHostTimeValid ? time.hostTime : 0,
                channelCount: channelCount,
                frameCount: frameCount,
                muteEpoch: muteEpoch
            )
        } else {
            guard let channelData = buffer.floatChannelData else {
                interrupt()
                return
            }
            enqueue = ring.enqueue(
                sampleRateHz: UInt32(buffer.format.sampleRate),
                absoluteSampleFrame: Int64(time.sampleTime),
                hostTime: time.isHostTimeValid ? time.hostTime : 0,
                channelCount: channelCount,
                frameCount: frameCount,
                muteEpoch: muteEpoch,
                channelData: UnsafePointer(channelData)
            )
        }
        if enqueue == .invalidClock || enqueue == .evidenceContended {
            invalidateClock()
            return
        }
        // DispatchSource coalesces signals and has one preinstalled handler;
        // callback traffic cannot create an unbounded closure queue.
        drainSource.add(data: 1)
    }

    func interrupt() {
        if transitionTerminal(to: 2) {
            drainSource.add(data: 1)
        }
    }

    func finish() {
        _ = transitionTerminal(to: 1)
        drainQueue.sync {
            drainAcceptedBlocks()
        }
    }

    private func invalidateClock() {
        if transitionTerminal(to: 3) {
            drainSource.add(data: 1)
        }
    }

    private func drainAcceptedBlocks(through watermark: Int = .max) {
        guard !finished else { return }
        var currentWatermark = watermark
        while true {
            if pendingMuteFence.load(ordering: .acquiring) != 0 {
                guard advancePendingMuteFence() else { return }
                // `beforeVisible` may accept the opposite command after the
                // completed fence commits but before its ack is resumed.
                if pendingMuteFence.load(ordering: .acquiring) != 0 { continue }
            }
            while let block = ring.dequeue(through: currentWatermark) {
                if !project(block) {
                    _ = transitionTerminal(to: 3)
                }
            }
            currentWatermark = .max
            let published = Self.decode(publishedMuteEpoch.load(ordering: .acquiring))
            _ = emitOverflowGapIfNeeded(for: published)

            // A command can be accepted while `project` is paused in a test
            // hook (or under scheduler preemption). Restart at the fence before
            // examining terminal state, so terminal publication cannot skip it.
            if pendingMuteFence.load(ordering: .acquiring) != 0 { continue }
            guard currentTerminalSeverity != 0 else { return }

            // `accept` retains its epoch before validation or buffer access.
            // Leave the broker live until all retained callbacks publish their
            // ring index/evidence, then take a final acquire-ordered pass.
            guard callbacksInFlightTotal == 0 else { return }
            while let block = ring.dequeue() {
                if !project(block) {
                    _ = transitionTerminal(to: 3)
                }
            }
            _ = emitOverflowGapIfNeeded(
                for: Self.decode(publishedMuteEpoch.load(ordering: .acquiring))
            )
            if pendingMuteFence.load(ordering: .acquiring) != 0 { continue }
            guard callbacksInFlightTotal == 0 else { return }

            beforeTerminalFinalization?()
            if pendingMuteFence.load(ordering: .acquiring) != 0 { continue }
            guard let finalizedKind = finalizeTerminalSnapshot() else {
                if pendingMuteFence.load(ordering: .acquiring) != 0 { continue }
                return
            }
            switch finalizedKind {
            case 2:
                broker.publish(.interrupted)
            case 3:
                broker.publish(.clockBecameInvalid)
            default:
                break
            }
            finished = true
            broker.finish()
            drainSource.cancel()
            releaseTerminalLifetime()
            return
        }
    }

    private var currentTerminalSeverity: Int {
        let state = terminal.load(ordering: .sequentiallyConsistent)
        return state >= 0 ? state : -state - 1
    }

    /// Advances one installed mute fence without ever waiting on the audio
    /// callback. While open, new-epoch callbacks register as timing evidence.
    /// Once old callbacks are stably absent, the drain consumes their exact
    /// publication watermark and atomically closes registration. Post-closure
    /// callbacks may enqueue, but this method returns before touching their
    /// ring slots until every registered callback has completed and the
    /// acknowledgement plus its prefix evidence have been published.
    private func advancePendingMuteFence() -> Bool {
        let encodedPending = pendingMuteFence.load(ordering: .acquiring)
        guard encodedPending != 0 else { return true }
        let pending = Self.decode(encodedPending)
        guard pending.sequence > 0 else {
            invalidateClock()
            return false
        }
        let old = MicrophoneMuteEpoch(
            sequence: pending.sequence - 1,
            isMuted: !pending.isMuted
        )
        var registration = muteFenceRegistration.load(ordering: .acquiring)
        guard registration != Self.inactiveMuteFenceRegistration else {
            invalidateClock()
            return false
        }

        if registration >= 0 {
            // `setMuted` installs the pending descriptor before changing the
            // sampled epoch. A release signal can briefly expose that setup;
            // wait for the final store before treating the old count as stable.
            guard encodedMuteEpoch.load(ordering: .sequentiallyConsistent) == encodedPending,
                  callbacksInFlight(for: old.sequence) == 0
            else { return false }

            // Every accepted old callback published its ring index before its
            // release decrement. New callbacks are still registered as
            // out-of-ring evidence, so this watermark contains exactly the old
            // prefix and remains stable until registration closes.
            let oldWatermark = ring.publicationWatermark
            while let block = ring.dequeue(through: oldWatermark) {
                if !project(block) {
                    _ = transitionTerminal(to: 3)
                }
            }
            _ = emitOverflowGapIfNeeded(for: old)

            guard closeMuteFenceRegistration() else {
                invalidateClock()
                return false
            }
            afterMuteFenceClosed?()
            registration = muteFenceRegistration.load(ordering: .acquiring)
        }

        // Closed state -1 means every callback that registered on the open
        // side has recorded its timing evidence. Continual post-gate traffic
        // does not affect this count and therefore cannot starve the ack.
        guard registration == -1 else { return false }
        beforeMuteAcknowledgement?()
        let effectiveInputFrame = deliveredInputEnd
        let prefix = materializeDropEvidence(
            preAcknowledgementEvidence.take(for: pending),
            for: pending
        )
        broker.publishBarrier(
            .muteChanged(
                epoch: pending,
                effectiveInputFrame: effectiveInputFrame
            ),
            followedBy: prefix
        ) { [self] in
            // Commit authority while the broker still excludes consumers. An
            // observer can therefore issue the opposite command immediately
            // after seeing the ack without racing this fence's cleanup, while
            // the ack and prefix remain an indivisible ordered broker batch.
            controlLock.lock()
            publishedMuteEpoch.store(encodedPending, ordering: .releasing)
            muteFenceRegistration.store(
                Self.inactiveMuteFenceRegistration,
                ordering: .releasing
            )
            pendingMuteFence.store(0, ordering: .releasing)
            controlLock.unlock()
            beforeMuteAcknowledgementVisible?()
        }
        return true
    }

    private func project(_ block: BufferedMicrophoneInputBlock) -> Bool {
        if baselineSampleFrame == nil {
            baselineSampleFrame = block.absoluteSampleFrame
            let origin = timelineOriginHostTime.load(ordering: .acquiring)
            if origin > 0 {
                guard let relativeFrame = inputFramesSinceTimelineOrigin(
                    hostTime: block.hostTime,
                    sampleRateHz: block.sampleRateHz
                ) else { return false }
                baselineRelativeFrame = relativeFrame
            }
        }
        guard let baselineSampleFrame,
              block.absoluteSampleFrame >= baselineSampleFrame
        else { return false }
        let delta = UInt64(block.absoluteSampleFrame - baselineSampleFrame)
        let (relative, overflow) = baselineRelativeFrame.addingReportingOverflow(delta)
        guard !overflow,
              UInt64(block.frameCount) <= UInt64.max - relative
        else { return false }
        let frameCount = UInt64(block.frameCount)
        deliveredInputEnd = max(deliveredInputEnd, relative + frameCount)
        if block.carriesSamples {
            guard let chunk = try? MicrophoneInputChunk(
                sampleRateHz: block.sampleRateHz,
                startSampleFrame: relative,
                channels: block.channels,
                muteEpoch: block.muteEpoch
            ) else { return false }
            broker.publish(.chunk(chunk))
        } else {
            broker.publish(
                .mutedInterval(
                    sampleRateHz: block.sampleRateHz,
                    startSampleFrame: relative,
                    frameCount: frameCount,
                    channelCount: UInt8(block.channelCount),
                    muteEpoch: block.muteEpoch
                )
            )
        }
        afterBlockProjected?()
        return true
    }

    @discardableResult
    private func emitOverflowGapIfNeeded(for epoch: MicrophoneMuteEpoch) -> Bool {
        guard let event = materializeDropEvidence(
            ring.takeDropEvidence(for: epoch),
            for: epoch
        ) else { return true }
        broker.publish(event)
        return true
    }

    private func materializeDropEvidence(
        _ latest: BoundedMicrophoneDropEvidence.Snapshot?,
        for epoch: MicrophoneMuteEpoch
    ) -> MicrophoneInputEvent? {
        guard let latest else { return nil }
        if baselineSampleFrame == nil {
            baselineSampleFrame = latest.startSampleFrame
            let origin = timelineOriginHostTime.load(ordering: .acquiring)
            if origin > 0 {
                guard let relativeFrame = inputFramesSinceTimelineOrigin(
                    hostTime: latest.hostTime,
                    sampleRateHz: latest.sampleRateHz
                ) else {
                    invalidateClock()
                    return nil
                }
                baselineRelativeFrame = relativeFrame
            }
        }
        guard let baselineSampleFrame,
              latest.endSampleFrame >= baselineSampleFrame
        else {
            invalidateClock()
            return nil
        }
        let delta = UInt64(latest.endSampleFrame - baselineSampleFrame)
        let (latestRelativeEnd, overflow) = baselineRelativeFrame.addingReportingOverflow(delta)
        guard !overflow else {
            invalidateClock()
            return nil
        }
        // A concurrent callback may have filled a slot released by this
        // drain and been projected past this compacted evidence. Its absolute
        // start already proves the missing range to the assembler, so this
        // older evidence is safely redundant rather than a clock fault.
        guard latestRelativeEnd > deliveredInputEnd else { return nil }
        let rangeStart = deliveredInputEnd
        let frameCount = latestRelativeEnd - rangeStart
        let event: MicrophoneInputEvent
        if epoch.isMuted {
            event = .mutedInterval(
                sampleRateHz: latest.sampleRateHz,
                startSampleFrame: rangeStart,
                frameCount: frameCount,
                channelCount: UInt8(latest.channelCount),
                muteEpoch: epoch
            )
        } else {
            event = .captureGap(
                sampleRateHz: latest.sampleRateHz,
                startSampleFrame: rangeStart,
                frameCount: frameCount,
                channelCount: UInt8(latest.channelCount),
                muteEpoch: epoch
            )
        }
        deliveredInputEnd = latestRelativeEnd
        return event
    }

    private func inputFramesSinceTimelineOrigin(
        hostTime: UInt64,
        sampleRateHz: UInt32
    ) -> UInt64? {
        let originHostTime = timelineOriginHostTime.load(ordering: .acquiring)
        guard originHostTime > 0,
              hostTime >= originHostTime
        else { return nil }
        let originNanoseconds = AudioConvertHostTimeToNanos(originHostTime)
        let callbackNanoseconds = AudioConvertHostTimeToNanos(hostTime)
        guard callbackNanoseconds >= originNanoseconds else { return nil }
        let elapsedNanoseconds = callbackNanoseconds - originNanoseconds
        let wholeSeconds = elapsedNanoseconds / 1_000_000_000
        let fractionalNanoseconds = elapsedNanoseconds % 1_000_000_000
        let rate = UInt64(sampleRateHz)
        let (wholeFrames, wholeOverflow) = wholeSeconds.multipliedReportingOverflow(by: rate)
        let (fractionalProduct, fractionalOverflow) =
            fractionalNanoseconds.multipliedReportingOverflow(by: rate)
        guard !wholeOverflow, !fractionalOverflow else { return nil }
        let fractionalFrames = fractionalProduct / 1_000_000_000
        let (frames, totalOverflow) = wholeFrames.addingReportingOverflow(fractionalFrames)
        guard !totalOverflow else { return nil }
        return frames
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

    private func sampleMuteEpochForCallback() -> SampledCallbackAuthority? {
        while terminal.load(ordering: .sequentiallyConsistent) == 0 {
            let encoded = encodedMuteEpoch.load(ordering: .sequentiallyConsistent)
            let epoch = Self.decode(encoded)
            retainCallbackEpoch(epoch)
            if terminal.load(ordering: .sequentiallyConsistent) == 0,
               encodedMuteEpoch.load(ordering: .sequentiallyConsistent) == encoded
            {
                return SampledCallbackAuthority(
                    muteEpoch: epoch,
                    fencePosition: registerCallbackWithMuteFence(for: encoded)
                )
            }
            releaseCallbackEpoch(epoch)
        }
        return nil
    }

    /// Linearizes a new-epoch callback against closure of its acknowledgement
    /// gate. A successful increment belongs to the pre-ack prefix even if the
    /// drain closes the gate immediately afterwards; the closed encoding keeps
    /// that registration counted until the callback releases it.
    private func registerCallbackWithMuteFence(
        for encodedEpoch: UInt64
    ) -> CallbackMuteFencePosition {
        while true {
            // A previous fence can complete and the next one can install while
            // a callback is paused here. Match the generation on every retry
            // so an old callback can never increment the next fence's count.
            guard pendingMuteFence.load(ordering: .acquiring) == encodedEpoch else {
                return .outsideFence
            }
            let registration = muteFenceRegistration.load(ordering: .acquiring)
            if registration == Self.inactiveMuteFenceRegistration {
                return .outsideFence
            }
            if registration < 0 {
                return .afterClosure
            }
            // Int.min is the inactive sentinel, so the open representation
            // reserves Int.max and never closes into that sentinel.
            guard registration < Int.max - 1 else { return .invalid }
            if muteFenceRegistration.compareExchange(
                expected: registration,
                desired: registration + 1,
                ordering: .acquiringAndReleasing
            ).exchanged {
                if pendingMuteFence.load(ordering: .acquiring) == encodedEpoch {
                    return .registeredBeforeClosure
                }
                // The CAS landed in a later generation. Its count prevents
                // that fence from completing until this rollback is visible.
                releaseMuteFenceRegistration()
                return .outsideFence
            }
        }
    }

    private func releaseMuteFenceRegistration() {
        while true {
            let registration = muteFenceRegistration.load(ordering: .acquiring)
            let desired: Int
            if registration > 0 {
                desired = registration - 1
            } else if registration < -1,
                      registration != Self.inactiveMuteFenceRegistration
            {
                desired = registration + 1
            } else {
                return
            }
            if muteFenceRegistration.compareExchange(
                expected: registration,
                desired: desired,
                ordering: .acquiringAndReleasing
            ).exchanged {
                return
            }
        }
    }

    private func closeMuteFenceRegistration() -> Bool {
        while true {
            let registration = muteFenceRegistration.load(ordering: .acquiring)
            guard registration != Self.inactiveMuteFenceRegistration else {
                return false
            }
            if registration < 0 { return true }
            // Keep Int.min reserved for the inactive state.
            guard registration < Int.max else { return false }
            if muteFenceRegistration.compareExchange(
                expected: registration,
                desired: -(registration + 1),
                ordering: .acquiringAndReleasing
            ).exchanged {
                return true
            }
        }
    }

    private func retainCallbackEpoch(_ epoch: MicrophoneMuteEpoch) {
        if epoch.sequence.isMultiple(of: 2) {
            evenEpochCallbacks.wrappingAdd(1, ordering: .sequentiallyConsistent)
        } else {
            oddEpochCallbacks.wrappingAdd(1, ordering: .sequentiallyConsistent)
        }
    }

    private func releaseCallbackEpoch(_ epoch: MicrophoneMuteEpoch) {
        if epoch.sequence.isMultiple(of: 2) {
            evenEpochCallbacks.wrappingAdd(-1, ordering: .sequentiallyConsistent)
        } else {
            oddEpochCallbacks.wrappingAdd(-1, ordering: .sequentiallyConsistent)
        }
    }

    private func callbacksInFlight(for sequence: UInt64) -> Int {
        if sequence.isMultiple(of: 2) {
            evenEpochCallbacks.load(ordering: .sequentiallyConsistent)
        } else {
            oddEpochCallbacks.load(ordering: .sequentiallyConsistent)
        }
    }

    private var callbacksInFlightTotal: Int {
        evenEpochCallbacks.load(ordering: .sequentiallyConsistent) +
            oddEpochCallbacks.load(ordering: .sequentiallyConsistent)
    }

    /// Terminal severity is monotonic and callback-safe. Nonnegative states
    /// remain upgradeable; `-(severity + 1)` is the atomically finalized form.
    /// This single word prevents an RT publication from racing behind a final
    /// snapshot without acquiring `controlLock`.
    private func transitionTerminal(to requested: Int) -> Bool {
        while true {
            let state = terminal.load(ordering: .sequentiallyConsistent)
            guard state >= 0, requested > state else { return false }
            if terminal.compareExchange(
                expected: state,
                desired: requested,
                ordering: .sequentiallyConsistent
            ).exchanged {
                return true
            }
        }
    }

    /// Atomically closes terminal severity upgrades before publishing the final
    /// feed barrier.  Calls racing after this point are deliberately rejected:
    /// their source has already reached a coherent EOF watermark.
    private func finalizeTerminalSnapshot() -> Int? {
        controlLock.lock()
        defer { controlLock.unlock() }
        guard pendingMuteFence.load(ordering: .acquiring) == 0 else {
            drainSource.add(data: 1)
            return nil
        }
        while true {
            let state = terminal.load(ordering: .sequentiallyConsistent)
            guard state > 0 else { return nil }
            if terminal.compareExchange(
                expected: state,
                desired: -(state + 1),
                ordering: .sequentiallyConsistent
            ).exchanged {
                return state
            }
        }
    }

    private func releaseTerminalLifetime() {
        controlLock.lock()
        terminalLifetime = nil
        controlLock.unlock()
        afterTerminalLifetimeReleased?()
    }
}
