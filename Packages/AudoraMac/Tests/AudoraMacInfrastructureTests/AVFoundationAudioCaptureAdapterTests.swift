import AudoraApplication
import AudoraDomain
@testable import AudoraMacInfrastructure
@preconcurrency import AVFoundation
import Foundation
import Synchronization
import XCTest

private final class AVFoundationInputRelayReference: @unchecked Sendable {
    var value: AVFoundationInputRelay?
}

final class AVFoundationAudioCaptureAdapterTests: XCTestCase {
    func testAVFoundationRelayProjectsSyntheticBuffersWithoutOpeningHardware() async throws {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let relay = AVFoundationInputRelay(continuation: stream.continuation)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
        )
        buffer.frameLength = 4
        for channel in 0..<2 {
            for frame in 0..<4 {
                buffer.floatChannelData![channel][frame] = Float(channel + frame) / 10
            }
        }
        var events = stream.stream.makeAsyncIterator()
        relay.accept(
            buffer: buffer,
            time: AVAudioTime(sampleTime: 1_000, atRate: 48_000)
        )
        guard case let .chunk(chunk) = await events.next() else {
            return XCTFail("relay did not project the synthetic buffer")
        }
        XCTAssertEqual(chunk.sampleRateHz, 48_000)
        XCTAssertEqual(chunk.startSampleFrame, 0)
        XCTAssertEqual(chunk.channels.count, 2)
        XCTAssertEqual(chunk.channels[0], [0, 0.1, 0.2, 0.3])
        XCTAssertEqual(chunk.channels[1], [0.1, 0.2, 0.3, 0.4])

        relay.accept(
            buffer: buffer,
            time: AVAudioTime(sampleTime: 1_006, atRate: 48_000)
        )
        guard case let .chunk(later) = await events.next() else {
            return XCTFail("relay did not project the later buffer")
        }
        XCTAssertEqual(later.startSampleFrame, 6)
        relay.finish()
        let terminal = await events.next()
        XCTAssertNil(terminal)
    }

    func testMuteAcknowledgementWaitsForCallbackThatSampledPriorEpoch() async throws {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let callbackSampledEpoch = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let relay = AVFoundationInputRelay(
            continuation: stream.continuation,
            callbackEpochSampled: {
                callbackSampledEpoch.signal()
                releaseCallback.wait()
            }
        )
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = 0.25
        DispatchQueue.global().async {
            relay.accept(buffer: buffer, time: AVAudioTime(sampleTime: 0, atRate: 16_000))
        }
        XCTAssertEqual(callbackSampledEpoch.wait(timeout: .now() + 1), .success)

        // Command acknowledgement is asynchronous: accepting the control must
        // not spin or block the source actor behind a stalled callback.
        XCTAssertTrue(relay.setMuted(true))

        releaseCallback.signal()
        var events = stream.stream.makeAsyncIterator()
        guard case let .chunk(chunk) = await events.next() else {
            return XCTFail("prior-epoch callback was not published before mute acknowledgement")
        }
        XCTAssertEqual(chunk.muteEpoch, .initial)
        let acknowledgement = await events.next()
        XCTAssertEqual(
            acknowledgement,
            .muteChanged(
                epoch: MicrophoneMuteEpoch(sequence: 1, isMuted: true),
                effectiveInputFrame: 1
            )
        )
        relay.finish()
    }

    func testMuteFencePublishesRegisteredNewEpochEvidenceBeforePostGateBlock() async throws {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let preFenceCallbackRegistered = DispatchSemaphore(value: 0)
        let releasePreFenceCallback = DispatchSemaphore(value: 0)
        let fenceClosed = DispatchSemaphore(value: 0)
        let shouldHoldCallback = Atomic<Bool>(true)
        let drainQueue = DispatchQueue(label: "relay-counted-mute-fence")
        let releaseInitialDrain = DispatchSemaphore(value: 0)
        drainQueue.async { releaseInitialDrain.wait() }
        let relay = AVFoundationInputRelay(
            continuation: stream.continuation,
            drainQueue: drainQueue,
            callbackEpochSampled: {
                if shouldHoldCallback.exchange(false, ordering: .acquiringAndReleasing) {
                    preFenceCallbackRegistered.signal()
                    releasePreFenceCallback.wait()
                }
            },
            afterMuteFenceClosed: { fenceClosed.signal() }
        )
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = 0.25

        XCTAssertTrue(relay.setMuted(true))
        DispatchQueue.global().async {
            relay.accept(buffer: buffer, time: AVAudioTime(sampleTime: 100, atRate: 16_000))
        }
        XCTAssertEqual(preFenceCallbackRegistered.wait(timeout: .now() + 1), .success)
        releaseInitialDrain.signal()
        XCTAssertEqual(fenceClosed.wait(timeout: .now() + 1), .success)

        // D enters after the gate closes while C is still held. It may enter
        // the bounded ring, but cannot overtake C's pre-ack timing evidence.
        relay.accept(buffer: buffer, time: AVAudioTime(sampleTime: 101, atRate: 16_000))
        releasePreFenceCallback.signal()

        var events = stream.stream.makeAsyncIterator()
        let acknowledgement = await events.next()
        let preFenceEvidence = await events.next()
        let postGateBlock = await events.next()
        XCTAssertEqual(
            acknowledgement,
            .muteChanged(
                epoch: MicrophoneMuteEpoch(sequence: 1, isMuted: true),
                effectiveInputFrame: 0
            )
        )
        XCTAssertEqual(
            preFenceEvidence,
            .mutedInterval(
                sampleRateHz: 16_000,
                startSampleFrame: 0,
                frameCount: 1,
                channelCount: 1,
                muteEpoch: MicrophoneMuteEpoch(sequence: 1, isMuted: true)
            )
        )
        XCTAssertEqual(
            postGateBlock,
            .mutedInterval(
                sampleRateHz: 16_000,
                startSampleFrame: 1,
                frameCount: 1,
                channelCount: 1,
                muteEpoch: MicrophoneMuteEpoch(sequence: 1, isMuted: true)
            )
        )
        relay.finish()
    }

    func testMuteAcknowledgementCommitsNextCommandBeforeBecomingVisible() async {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let relayReference = AVFoundationInputRelayReference()
        let shouldToggle = Atomic<Bool>(true)
        let oppositeAccepted = Atomic<Bool>(false)
        let relay = AVFoundationInputRelay(
            continuation: stream.continuation,
            beforeMuteAcknowledgementVisible: {
                guard shouldToggle.exchange(
                    false,
                    ordering: .acquiringAndReleasing
                ) else { return }
                oppositeAccepted.store(
                    relayReference.value?.setMuted(false) ?? false,
                    ordering: .releasing
                )
            }
        )
        relayReference.value = relay
        XCTAssertTrue(relay.setMuted(true))

        var events = stream.stream.makeAsyncIterator()
        let mute = await events.next()
        let unmute = await events.next()
        XCTAssertTrue(oppositeAccepted.load(ordering: .acquiring))
        XCTAssertEqual(
            mute,
            .muteChanged(
                epoch: MicrophoneMuteEpoch(sequence: 1, isMuted: true),
                effectiveInputFrame: 0
            )
        )
        XCTAssertEqual(
            unmute,
            .muteChanged(
                epoch: MicrophoneMuteEpoch(sequence: 2, isMuted: false),
                effectiveInputFrame: 0
            )
        )
        relay.finish()
    }

    func testMuteAcceptedDuringProjectionPrecedesConcurrentInterruption() async throws {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let projected = DispatchSemaphore(value: 0)
        let releaseProjection = DispatchSemaphore(value: 0)
        let shouldPause = Atomic<Bool>(true)
        let relay = AVFoundationInputRelay(
            continuation: stream.continuation,
            afterBlockProjected: {
                guard shouldPause.exchange(
                    false,
                    ordering: .acquiringAndReleasing
                ) else { return }
                projected.signal()
                releaseProjection.wait()
            }
        )
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = 0.5
        relay.accept(buffer: buffer, time: AVAudioTime(sampleTime: 0, atRate: 16_000))
        XCTAssertEqual(projected.wait(timeout: .now() + 1), .success)

        XCTAssertTrue(relay.setMuted(true))
        relay.interrupt()
        releaseProjection.signal()

        var events = stream.stream.makeAsyncIterator()
        guard case .chunk = await events.next() else {
            return XCTFail("projected chunk was not retained")
        }
        let acknowledgement = await events.next()
        let interruption = await events.next()
        XCTAssertEqual(
            acknowledgement,
            .muteChanged(
                epoch: MicrophoneMuteEpoch(sequence: 1, isMuted: true),
                effectiveInputFrame: 1
            )
        )
        XCTAssertEqual(interruption, .interrupted)
        let end = await events.next()
        XCTAssertNil(end)
    }

    func testExceptionalCallbackDoesNotWaitForRelayControlLock() throws {
        let controlLockHeld = DispatchSemaphore(value: 0)
        let releaseControlLock = DispatchSemaphore(value: 0)
        let callbackReturned = DispatchSemaphore(value: 0)
        let commandReturned = DispatchSemaphore(value: 0)
        let commandAccepted = Atomic<Bool>(true)
        let relay = AVFoundationInputRelay(
            whileControlLockHeld: {
                controlLockHeld.signal()
                releaseControlLock.wait()
            }
        )
        DispatchQueue.global().async {
            commandAccepted.store(relay.setMuted(true), ordering: .releasing)
            commandReturned.signal()
        }
        XCTAssertEqual(controlLockHeld.wait(timeout: .now() + 1), .success)

        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        DispatchQueue.global().async {
            relay.accept(
                buffer: buffer,
                time: AVAudioTime(sampleTime: 0, atRate: 44_100)
            )
            callbackReturned.signal()
        }
        XCTAssertEqual(
            callbackReturned.wait(timeout: .now() + 1),
            .success,
            "audio callback attempted to acquire the relay control lock"
        )
        releaseControlLock.signal()
        XCTAssertEqual(commandReturned.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(commandAccepted.load(ordering: .acquiring))
        relay.finish()
    }

    func testRelayReleasesInitializationLifetimeAfterNormalFinish() {
        let lifetimeReleased = DispatchSemaphore(value: 0)
        var relay: AVFoundationInputRelay? = AVFoundationInputRelay(
            afterTerminalLifetimeReleased: { lifetimeReleased.signal() }
        )
        weak let weakRelay = relay
        relay?.finish()
        XCTAssertEqual(lifetimeReleased.wait(timeout: .now() + 1), .success)
        relay = nil
        XCTAssertNil(weakRelay)
    }

    func testRelayReleasesInitializationLifetimeAfterCallbackTerminals() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        let terminalTimes = [
            // Format/time mismatch publishes the interruption terminal.
            AVAudioTime(sampleTime: 0, atRate: 44_100),
            // Invalid source time publishes the invalid-clock terminal.
            AVAudioTime(sampleTime: -1, atRate: 48_000),
        ]

        for time in terminalTimes {
            let lifetimeReleased = DispatchSemaphore(value: 0)
            let drainQueue = DispatchQueue(label: "relay-lifetime-callback-terminal")
            var relay: AVFoundationInputRelay? = AVFoundationInputRelay(
                drainQueue: drainQueue,
                afterTerminalLifetimeReleased: { lifetimeReleased.signal() }
            )
            weak let weakRelay = relay
            relay?.accept(buffer: buffer, time: time)
            XCTAssertEqual(lifetimeReleased.wait(timeout: .now() + 1), .success)
            // Ensure the drain handler has returned after releasing its retain.
            drainQueue.sync {}
            relay = nil
            XCTAssertNil(weakRelay)
        }
    }

    func testSequentialAdmissionOrderForbidsOldEpochAfterZeroCountObservation() {
        // SC program order is callback increment -> callback recheck and epoch
        // store -> drain count load. The forbidden reads additionally require
        // recheck < store and count load < increment, which would form a cycle.
        var validProgramOrders = 0
        var forbiddenOrders = 0
        for increment in 0..<4 {
            for recheck in 0..<4 where recheck != increment {
                for epochStore in 0..<4
                where epochStore != increment && epochStore != recheck {
                    for countLoad in 0..<4
                    where Set([increment, recheck, epochStore, countLoad]).count == 4 {
                        guard increment < recheck, epochStore < countLoad else { continue }
                        validProgramOrders += 1
                        if recheck < epochStore, countLoad < increment {
                            forbiddenOrders += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(validProgramOrders, 0)
        XCTAssertEqual(forbiddenOrders, 0)
    }

    func testInterruptDrainsCallbackAlreadyPastEpochSamplingBeforeTerminal() async throws {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let sampled = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let relay = AVFoundationInputRelay(
            continuation: stream.continuation,
            callbackEpochSampled: {
                sampled.signal()
                release.wait()
            }
        )
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = 0.5
        DispatchQueue.global().async {
            relay.accept(buffer: buffer, time: AVAudioTime(sampleTime: 0, atRate: 16_000))
        }
        XCTAssertEqual(sampled.wait(timeout: .now() + 1), .success)
        relay.interrupt()
        release.signal()

        var events = stream.stream.makeAsyncIterator()
        guard case let .chunk(chunk) = await events.next() else {
            return XCTFail("accepted callback disappeared behind terminal barrier")
        }
        XCTAssertEqual(chunk.channels, [[0.5]])
        let interruption = await events.next()
        let end = await events.next()
        XCTAssertEqual(interruption, .interrupted)
        XCTAssertNil(end)
    }

    func testFinishDrainsCallbackAlreadyPastEpochSamplingBeforeEOF() async throws {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let sampled = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let relay = AVFoundationInputRelay(
            continuation: stream.continuation,
            callbackEpochSampled: {
                sampled.signal()
                release.wait()
            }
        )
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = 0.5
        DispatchQueue.global().async {
            relay.accept(buffer: buffer, time: AVAudioTime(sampleTime: 0, atRate: 16_000))
        }
        XCTAssertEqual(sampled.wait(timeout: .now() + 1), .success)
        relay.finish()
        release.signal()

        var events = stream.stream.makeAsyncIterator()
        guard case .chunk = await events.next() else {
            return XCTFail("finish discarded a callback that had already sampled its epoch")
        }
        let end = await events.next()
        XCTAssertNil(end)
    }

    func testInvalidCallbackAfterFinishUpgradesTerminalInsteadOfCleanEOF() async throws {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let sampled = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let relay = AVFoundationInputRelay(
            continuation: stream.continuation,
            callbackEpochSampled: {
                sampled.signal()
                release.wait()
            }
        )
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = 0.5
        DispatchQueue.global().async {
            relay.accept(buffer: buffer, time: AVAudioTime(sampleTime: -1, atRate: 48_000))
        }
        XCTAssertEqual(sampled.wait(timeout: .now() + 1), .success)
        relay.finish()
        release.signal()

        var events = stream.stream.makeAsyncIterator()
        let terminal = await events.next()
        let end = await events.next()
        XCTAssertEqual(terminal, .clockBecameInvalid)
        XCTAssertNil(end)
    }

    func testInterruptRacingFinishFinalizationWinsBeforeTerminalPublication() async throws {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let reachedFinalization = DispatchSemaphore(value: 0)
        let releaseFinalization = DispatchSemaphore(value: 0)
        let relay = AVFoundationInputRelay(
            continuation: stream.continuation,
            beforeTerminalFinalization: {
                reachedFinalization.signal()
                releaseFinalization.wait()
            }
        )
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            relay.finish()
            finished.signal()
        }
        XCTAssertEqual(reachedFinalization.wait(timeout: .now() + 1), .success)
        relay.interrupt()
        releaseFinalization.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)

        var events = stream.stream.makeAsyncIterator()
        let terminal = await events.next()
        let end = await events.next()
        XCTAssertEqual(terminal, .interrupted)
        XCTAssertNil(end)
    }

    func testProjectionFailureRetainsTerminalUntilAnotherSampledCallbackDrains() async throws {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let drainQueue = DispatchQueue(label: "relay-projection-terminal")
        let holdDrain = DispatchSemaphore(value: 0)
        drainQueue.async { holdDrain.wait() }
        let secondSampled = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        let callbackCount = Atomic<Int>(0)
        let relay = AVFoundationInputRelay(
            continuation: stream.continuation,
            drainQueue: drainQueue,
            callbackEpochSampled: {
                callbackCount.wrappingAdd(1, ordering: .acquiringAndReleasing)
                let isSecond = callbackCount.load(ordering: .acquiring) == 2
                if isSecond {
                    secondSampled.signal()
                    releaseSecond.wait()
                }
            }
        )
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let invalid = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        invalid.frameLength = 1
        invalid.floatChannelData![0][0] = .nan
        let valid = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        valid.frameLength = 1
        valid.floatChannelData![0][0] = 0.25
        relay.accept(buffer: invalid, time: AVAudioTime(sampleTime: 0, atRate: 16_000))
        DispatchQueue.global().async {
            relay.accept(buffer: valid, time: AVAudioTime(sampleTime: 1, atRate: 16_000))
        }
        XCTAssertEqual(secondSampled.wait(timeout: .now() + 1), .success)
        holdDrain.signal()
        relay.finish()
        releaseSecond.signal()

        var events = stream.stream.makeAsyncIterator()
        var sawInvalidTerminal = false
        while let event = await events.next() {
            if event == .clockBecameInvalid { sawInvalidTerminal = true }
        }
        XCTAssertTrue(sawInvalidTerminal)
    }

    func testTerminalAcknowledgesPendingMuteThenPreservesItsDropEvidence() async throws {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let drainQueue = DispatchQueue(label: "relay-terminal-pending-mute")
        let relay = AVFoundationInputRelay(continuation: stream.continuation, drainQueue: drainQueue)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = 0.5
        relay.accept(buffer: buffer, time: AVAudioTime(sampleTime: 0, atRate: 16_000))
        var events = stream.stream.makeAsyncIterator()
        guard case .chunk = await events.next() else {
            return XCTFail("baseline callback did not establish source clock")
        }

        let holdDrain = DispatchSemaphore(value: 0)
        drainQueue.async { holdDrain.wait() }
        XCTAssertTrue(relay.setMuted(true))
        relay.accept(buffer: buffer, time: AVAudioTime(sampleTime: 1, atRate: 16_000))
        relay.interrupt()
        holdDrain.signal()

        let acknowledgement = await events.next()
        let pendingEvidence = await events.next()
        let terminal = await events.next()
        let end = await events.next()
        XCTAssertEqual(
            acknowledgement,
            .muteChanged(
                epoch: MicrophoneMuteEpoch(sequence: 1, isMuted: true),
                effectiveInputFrame: 1
            )
        )
        XCTAssertEqual(
            pendingEvidence,
            .mutedInterval(
                sampleRateHz: 16_000,
                startSampleFrame: 1,
                frameCount: 1,
                channelCount: 1,
                muteEpoch: MicrophoneMuteEpoch(sequence: 1, isMuted: true)
            )
        )
        XCTAssertEqual(terminal, .interrupted)
        XCTAssertNil(end)
    }

    func testMuteBeforeFirstCallbackPreservesPendingMutedTimingThroughStop() async throws {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let drainQueue = DispatchQueue(label: "relay-first-pending-mute")
        let holdDrain = DispatchSemaphore(value: 0)
        drainQueue.async { holdDrain.wait() }
        let relay = AVFoundationInputRelay(continuation: stream.continuation, drainQueue: drainQueue)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = 0.5
        XCTAssertTrue(relay.setMuted(true))
        for sampleFrame in 0...2 {
            relay.accept(buffer: buffer, time: AVAudioTime(sampleTime: Int64(sampleFrame), atRate: 16_000))
        }
        holdDrain.signal()
        relay.finish()

        var events = stream.stream.makeAsyncIterator()
        let acknowledgement = await events.next()
        let mutedTiming = await events.next()
        let end = await events.next()
        XCTAssertEqual(
            acknowledgement,
            .muteChanged(
                epoch: MicrophoneMuteEpoch(sequence: 1, isMuted: true),
                effectiveInputFrame: 0
            )
        )
        XCTAssertEqual(
            mutedTiming,
            .mutedInterval(
                sampleRateHz: 16_000,
                startSampleFrame: 0,
                frameCount: 3,
                channelCount: 1,
                muteEpoch: MicrophoneMuteEpoch(sequence: 1, isMuted: true)
            )
        )
        XCTAssertNil(end)
    }

    func testInvalidFirstPendingDropHostFailsClosedWithoutAnotherCallback() async throws {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let relay = AVFoundationInputRelay(
            continuation: stream.continuation,
            expectedSampleRateHz: 16_000,
            expectedChannelCount: 1
        )
        relay.beginTimeline(atHostTime: 100)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        XCTAssertTrue(relay.setMuted(true))
        relay.accept(
            buffer: buffer,
            time: AVAudioTime(hostTime: 99, sampleTime: 0, atRate: 16_000)
        )

        var events = stream.stream.makeAsyncIterator()
        let acknowledgement = await events.next()
        let invalid = await events.next()
        let end = await events.next()
        XCTAssertEqual(
            acknowledgement,
            .muteChanged(
                epoch: MicrophoneMuteEpoch(sequence: 1, isMuted: true),
                effectiveInputFrame: 0
            )
        )
        XCTAssertEqual(invalid, .clockBecameInvalid)
        XCTAssertNil(end)
    }

    func testRelayRejectsInterleavedOrNonFloatOrMismatchedTimeFormatsBeforeProjection() async throws {
        let malformed: [(AVAudioFormat, AVAudioTime)] = [
            (
                try XCTUnwrap(
                    AVAudioFormat(
                        commonFormat: .pcmFormatFloat32,
                        sampleRate: 48_000,
                        channels: 2,
                        interleaved: true
                    )
                ),
                AVAudioTime(sampleTime: 0, atRate: 48_000)
            ),
            (
                try XCTUnwrap(
                    AVAudioFormat(
                        commonFormat: .pcmFormatInt16,
                        sampleRate: 48_000,
                        channels: 1,
                        interleaved: false
                    )
                ),
                AVAudioTime(sampleTime: 0, atRate: 48_000)
            ),
            (
                try XCTUnwrap(
                    AVAudioFormat(
                        commonFormat: .pcmFormatFloat32,
                        sampleRate: 48_000,
                        channels: 1,
                        interleaved: false
                    )
                ),
                AVAudioTime(sampleTime: 0, atRate: 44_100)
            )
        ]
        for (format, time) in malformed {
            let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
            let relay = AVFoundationInputRelay(continuation: stream.continuation)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
            buffer.frameLength = 1
            relay.accept(buffer: buffer, time: time)
            var events = stream.stream.makeAsyncIterator()
            let interruption = await events.next()
            let end = await events.next()
            XCTAssertEqual(interruption, .interrupted)
            XCTAssertNil(end)
        }
    }

    func testMuteFenceAcknowledgesOldOverflowBeforeConcurrentNewEpochEvidence() async throws {
        let drainQueue = DispatchQueue(label: "relay-transition-overflow")
        let holdDrain = DispatchSemaphore(value: 0)
        drainQueue.async { holdDrain.wait() }
        let reachedFence = DispatchSemaphore(value: 0)
        let releaseFence = DispatchSemaphore(value: 0)
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let relay = AVFoundationInputRelay(
            continuation: stream.continuation,
            queueCapacity: 2,
            drainQueue: drainQueue,
            beforeMuteAcknowledgement: {
                reachedFence.signal()
                releaseFence.wait()
            }
        )
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        for frame: Int64 in 0...2 {
            relay.accept(buffer: buffer, time: AVAudioTime(sampleTime: frame, atRate: 16_000))
        }

        XCTAssertTrue(relay.setMuted(true))
        holdDrain.signal()
        XCTAssertEqual(reachedFence.wait(timeout: .now() + 1), .success)
        relay.accept(buffer: buffer, time: AVAudioTime(sampleTime: 3, atRate: 16_000))
        releaseFence.signal()

        var events = stream.stream.makeAsyncIterator()
        guard case let .chunk(first) = await events.next(),
              case let .chunk(second) = await events.next()
        else { return XCTFail("old published callbacks missing") }
        XCTAssertEqual(first.muteEpoch, .initial)
        XCTAssertEqual(second.muteEpoch, .initial)
        let oldGap = await events.next()
        XCTAssertEqual(
            oldGap,
            .captureGap(
                sampleRateHz: 16_000,
                startSampleFrame: 2,
                frameCount: 1,
                channelCount: 1,
                muteEpoch: .initial
            )
        )
        let acknowledgement = await events.next()
        XCTAssertEqual(
            acknowledgement,
            .muteChanged(
                epoch: MicrophoneMuteEpoch(sequence: 1, isMuted: true),
                effectiveInputFrame: 3
            )
        )
        let newGap = await events.next()
        XCTAssertEqual(
            newGap,
            .mutedInterval(
                sampleRateHz: 16_000,
                startSampleFrame: 3,
                frameCount: 1,
                channelCount: 1,
                muteEpoch: MicrophoneMuteEpoch(sequence: 1, isMuted: true)
            )
        )
        relay.finish()
    }

    func testRapidMuteTogglesAcknowledgeStrictEpochOrder() async throws {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let relay = AVFoundationInputRelay(continuation: stream.continuation)
        XCTAssertTrue(relay.setMuted(true))
        var events = stream.stream.makeAsyncIterator()
        let first = await events.next()
        XCTAssertEqual(
            first,
            .muteChanged(
                epoch: MicrophoneMuteEpoch(sequence: 1, isMuted: true),
                effectiveInputFrame: 0
            )
        )
        XCTAssertTrue(relay.setMuted(false))
        let second = await events.next()
        XCTAssertEqual(
            second,
            .muteChanged(
                epoch: MicrophoneMuteEpoch(sequence: 2, isMuted: false),
                effectiveInputFrame: 0
            )
        )
        relay.finish()
    }

    func testMutedCallbacksEmitOnlyTimingEvidence() async throws {
        let relay = AVFoundationInputRelay()
        var events = relay.eventFeed.makeAsyncIterator()
        XCTAssertTrue(relay.setMuted(true))
        let acknowledgement = await events.next()
        XCTAssertEqual(
            acknowledgement,
            .muteChanged(
                epoch: MicrophoneMuteEpoch(sequence: 1, isMuted: true),
                effectiveInputFrame: 0
            )
        )

        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        buffer.floatChannelData![0][0] = 0.9
        buffer.floatChannelData![0][1] = -0.8
        buffer.floatChannelData![1][0] = -0.7
        buffer.floatChannelData![1][1] = 0.6
        relay.accept(buffer: buffer, time: AVAudioTime(sampleTime: 100, atRate: 48_000))

        guard case let .mutedInterval(rate, start, count, channels, epoch) = await events.next() else {
            return XCTFail("muted callback exposed a raw chunk")
        }
        XCTAssertEqual(rate, 48_000)
        XCTAssertEqual(start, 0)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(channels, 2)
        XCTAssertEqual(epoch, MicrophoneMuteEpoch(sequence: 1, isMuted: true))

        XCTAssertTrue(relay.setMuted(false))
        let unmuteAcknowledgement = await events.next()
        XCTAssertEqual(
            unmuteAcknowledgement,
            .muteChanged(
                epoch: MicrophoneMuteEpoch(sequence: 2, isMuted: false),
                effectiveInputFrame: 2
            )
        )
        relay.accept(buffer: buffer, time: AVAudioTime(sampleTime: 102, atRate: 48_000))
        guard case let .chunk(unmuted) = await events.next() else {
            return XCTFail("unmute did not restore raw callback projection")
        }
        XCTAssertEqual(unmuted.startSampleFrame, 2)
        XCTAssertEqual(unmuted.channels[0], [0.9, -0.8])
        relay.finish()
    }

    func testDeclaredStereoFormatSupportsMuteBeforeFirstCallbackThenRealInput() async throws {
        try await withAdapterLibrary { root, request in
            let source = FakeMicrophoneInputSource(
                format: try MicrophoneInputFormat(sampleRateHz: 44_100, channelCount: 2)
            )
            let clock = FakeCaptureMonotonicClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: FixedRecordingRoot(root: root),
                sources: FixedInputFactory(source: source),
                monotonicClock: clock
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            var observations = feed.observations.makeAsyncIterator()
            _ = await observations.next()
            await clock.advance(toElapsedSeconds: 1)
            let mute = await adapter.apply(.setMuted(true), to: request.recordingID)
            XCTAssertEqual(mute, .accepted)

            guard case let .progress(frameCount, level) = await observations.next() else {
                return XCTFail("mute fence did not materialize the declared-format timeline")
            }
            XCTAssertEqual(frameCount, 16_000)
            XCTAssertEqual(level, .unavailable(.captureGap))
            let acknowledgement = await observations.next()
            XCTAssertEqual(acknowledgement, .muteChanged(isMuted: true, effectiveFrame: 16_000))

            let frames = Array(repeating: Float(0.25), count: 441)
            await source.emit(
                .chunk(
                    try MicrophoneInputChunk(
                        sampleRateHz: 44_100,
                        startSampleFrame: 44_100,
                        channels: [frames, frames]
                    )
                )
            )
            let stop = await adapter.apply(.stop, to: request.recordingID)
            XCTAssertEqual(stop, .accepted)

            var sealed = false
            while let observation = await observations.next() {
                switch observation {
                case .sealCandidate:
                    sealed = true
                case .recoveryRequired:
                    return XCTFail("declared 44.1 kHz stereo format caused recovery")
                default:
                    break
                }
            }
            XCTAssertTrue(sealed)
        }
    }

    func testPausedConsumerOverSixteenMutedCallbacksKeepsMuteBarrierAndTiming() async throws {
        let drainQueue = DispatchQueue(label: "relay-broker-saturation")
        let acknowledgementPublished = DispatchSemaphore(value: 0)
        let relay = AVFoundationInputRelay(
            queueCapacity: 16,
            drainQueue: drainQueue,
            beforeMuteAcknowledgement: { acknowledgementPublished.signal() }
        )
        var events = relay.eventFeed.makeAsyncIterator()
        XCTAssertTrue(relay.setMuted(true))
        XCTAssertEqual(acknowledgementPublished.wait(timeout: .now() + 1), .success)
        // FIFO drain completion proves the acknowledgement is buffered, while
        // the consumer remains deliberately untouched.
        drainQueue.sync {}
        let holdDrain = DispatchSemaphore(value: 0)
        drainQueue.async { holdDrain.wait() }

        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = 0.75
        for frame: Int64 in 0..<17 {
            relay.accept(buffer: buffer, time: AVAudioTime(sampleTime: frame, atRate: 16_000))
        }
        holdDrain.signal()
        relay.finish()

        var mutedFrameCount: UInt64 = 0
        var latestMutedEnd: UInt64 = 0
        var sawAcknowledgement = false
        var eventIndex = 0
        while let event = await events.next() {
            switch event {
            case let .muteChanged(epoch, _):
                XCTAssertEqual(eventIndex, 0, "mute barrier was evicted or reordered")
                XCTAssertEqual(epoch, MicrophoneMuteEpoch(sequence: 1, isMuted: true))
                sawAcknowledgement = true
            case let .mutedInterval(_, start, count, _, epoch):
                XCTAssertEqual(epoch, MicrophoneMuteEpoch(sequence: 1, isMuted: true))
                mutedFrameCount += count
                latestMutedEnd = max(latestMutedEnd, start + count)
            case .chunk, .captureGap:
                XCTFail("muted saturation must not retain raw samples or false gap evidence")
            case .interrupted, .clockBecameInvalid:
                XCTFail("bounded broker silently saturated")
            }
            eventIndex += 1
        }
        XCTAssertTrue(sawAcknowledgement)
        XCTAssertEqual(mutedFrameCount, 17)
        XCTAssertEqual(latestMutedEnd, 17)
    }

    func testBrokerControlSaturationFailsClosedAfterAlreadyOrderedBarrier() async {
        let broker = LossAwareMicrophoneEventBroker(pendingCapacity: 1)
        var events = MicrophoneInputEventSequence { await broker.next() }.makeAsyncIterator()
        let mute = MicrophoneInputEvent.muteChanged(
            epoch: MicrophoneMuteEpoch(sequence: 1, isMuted: true),
            effectiveInputFrame: 0
        )
        broker.publish(mute)
        // There is no data pair to compact: preserve the first barrier, freeze
        // publication at this exact point, and surface an explicit failure.
        broker.publish(
            .muteChanged(
                epoch: MicrophoneMuteEpoch(sequence: 2, isMuted: false),
                effectiveInputFrame: 0
            )
        )
        broker.publish(.interrupted)

        let first = await events.next()
        let failure = await events.next()
        let end = await events.next()
        XCTAssertEqual(first, mute)
        XCTAssertEqual(failure, .clockBecameInvalid)
        XCTAssertNil(end)
    }

    func testBrokerCancellationReleasesWaitingConsumerForReplacementIterator() async {
        let broker = LossAwareMicrophoneEventBroker()
        let waiter = Task { await broker.next() }
        await Task.yield()
        waiter.cancel()
        let cancelledValue = await waiter.value
        XCTAssertNil(cancelledValue)

        let replacement = Task { await broker.next() }
        await Task.yield()
        let event = MicrophoneInputEvent.muteChanged(
            epoch: MicrophoneMuteEpoch(sequence: 1, isMuted: true),
            effectiveInputFrame: 0
        )
        broker.publish(event)
        let replacementValue = await replacement.value
        XCTAssertEqual(replacementValue, event)
    }

    func testBrokerPublishPreservesEventWhenCancellationAlreadyLinearized() {
        let waiterInstalled = DispatchSemaphore(value: 0)
        let cancellationFlagStored = DispatchSemaphore(value: 0)
        let releaseCancellationLock = DispatchSemaphore(value: 0)
        let cancellationReturned = DispatchSemaphore(value: 0)
        let eventBufferedForReplacement = DispatchSemaphore(value: 0)
        let bufferedEventDequeued = DispatchSemaphore(value: 0)
        let cancelledWaiterCompleted = DispatchSemaphore(value: 0)
        let replacementCompleted = DispatchSemaphore(value: 0)
        let shouldGateCancellation = Atomic<Bool>(true)
        let cancelledWaiterResult = Atomic<Int>(0)
        let replacementResult = Atomic<Int>(0)
        let broker = LossAwareMicrophoneEventBroker(
            afterWaiterInstalled: { waiterInstalled.signal() },
            beforeCancellationLock: {
                if shouldGateCancellation.exchange(
                    false,
                    ordering: .acquiringAndReleasing
                ) {
                    cancellationFlagStored.signal()
                    releaseCancellationLock.wait()
                }
            },
            afterCancelledWaiterEventBuffered: {
                eventBufferedForReplacement.signal()
            },
            afterBufferedEventDequeued: { bufferedEventDequeued.signal() }
        )
        let waiter = Task {
            let value = await broker.next()
            cancelledWaiterResult.store(value == nil ? 1 : 2, ordering: .releasing)
            cancelledWaiterCompleted.signal()
        }
        XCTAssertEqual(waiterInstalled.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            waiter.cancel()
            cancellationReturned.signal()
        }
        XCTAssertEqual(cancellationFlagStored.wait(timeout: .now() + 1), .success)

        let event = MicrophoneInputEvent.muteChanged(
            epoch: MicrophoneMuteEpoch(sequence: 1, isMuted: true),
            effectiveInputFrame: 0
        )
        broker.publish(event)
        XCTAssertEqual(eventBufferedForReplacement.wait(timeout: .now() + 1), .success)
        releaseCancellationLock.signal()
        XCTAssertEqual(cancellationReturned.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(cancelledWaiterCompleted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(cancelledWaiterResult.load(ordering: .acquiring), 1)

        let replacement = Task {
            let value = await broker.next()
            replacementResult.store(value == event ? 1 : 2, ordering: .releasing)
            replacementCompleted.signal()
        }
        XCTAssertEqual(bufferedEventDequeued.wait(timeout: .now() + 1), .success)
        let replacementStatus = replacementCompleted.wait(timeout: .now() + 1)
        XCTAssertEqual(replacementStatus, .success)
        XCTAssertEqual(replacementResult.load(ordering: .acquiring), 1)
        if replacementStatus != .success { replacement.cancel() }
        broker.finish()
    }

    func testAVFoundationRelayRejectsOversizeCallbackBeforeProjection() async throws {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let relay = AVFoundationInputRelay(continuation: stream.continuation)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let frameCount = AVFoundationInputRelay.maximumAcceptedFramesPerCallback + 1
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            )
        )
        buffer.frameLength = AVAudioFrameCount(frameCount)
        var events = stream.stream.makeAsyncIterator()
        relay.accept(
            buffer: buffer,
            time: AVAudioTime(sampleTime: 0, atRate: 48_000)
        )
        let interrupted = await events.next()
        XCTAssertEqual(interrupted, .interrupted)
        let terminal = await events.next()
        XCTAssertNil(terminal)
    }

    func testAVFoundationRelayPreservesLeadingGapFromCaptureStartHostTime() async throws {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let relay = AVFoundationInputRelay(
            continuation: stream.continuation,
            expectedSampleRateHz: 48_000,
            expectedChannelCount: 1
        )
        let origin: UInt64 = 10_000_000
        relay.beginTimeline(atHostTime: origin)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        var events = stream.stream.makeAsyncIterator()
        let delay = AVAudioTime.hostTime(forSeconds: 0.25)
        relay.accept(
            buffer: buffer,
            time: AVAudioTime(
                hostTime: origin + delay,
                sampleTime: 1_000,
                atRate: 48_000
            )
        )
        guard case let .chunk(chunk) = await events.next() else {
            return XCTFail("missing first delayed callback")
        }
        XCTAssertEqual(chunk.startSampleFrame, 12_000)
        relay.finish()
    }

    func testLiveRelayRequiresHostTimeline() async throws {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let relay = AVFoundationInputRelay(
            continuation: stream.continuation,
            expectedSampleRateHz: 48_000,
            expectedChannelCount: 1
        )
        relay.beginTimeline(atHostTime: 1)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        var events = stream.stream.makeAsyncIterator()
        relay.accept(
            buffer: buffer,
            time: AVAudioTime(sampleTime: 0, atRate: 48_000)
        )
        let invalid = await events.next()
        XCTAssertEqual(invalid, .clockBecameInvalid)
        let terminal = await events.next()
        XCTAssertNil(terminal)

    }

    func testLiveRelayRejectsFirstHostTimeBeforeCaptureStart() async throws {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let relay = AVFoundationInputRelay(
            continuation: stream.continuation,
            expectedSampleRateHz: 48_000,
            expectedChannelCount: 1
        )
        relay.beginTimeline(atHostTime: 100)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        var events = stream.stream.makeAsyncIterator()
        relay.accept(
            buffer: buffer,
            time: AVAudioTime(hostTime: 99, sampleTime: 0, atRate: 48_000)
        )
        let invalid = await events.next()
        XCTAssertEqual(invalid, .clockBecameInvalid)
        let terminal = await events.next()
        XCTAssertNil(terminal)
    }

    func testLargestConstructibleHostTimeConvertsWithoutUInt64Trap() async throws {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let relay = AVFoundationInputRelay(
            continuation: stream.continuation,
            expectedSampleRateHz: 384_000,
            expectedChannelCount: 1
        )
        relay.beginTimeline(atHostTime: 1)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 384_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        var events = stream.stream.makeAsyncIterator()
        relay.accept(
            buffer: buffer,
            time: AVAudioTime(
                hostTime: UInt64.max,
                sampleTime: 0,
                atRate: 384_000
            )
        )
        guard case let .chunk(chunk) = await events.next() else {
            return XCTFail("largest AVAudioTime host value did not convert safely")
        }
        XCTAssertGreaterThan(chunk.startSampleFrame, 0)
        relay.finish()
    }

    func testFinishIsIdempotentAfterConfigurationInterruptAlreadyCancelledDrain() async {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let relay = AVFoundationInputRelay(continuation: stream.continuation)
        var events = stream.stream.makeAsyncIterator()

        // Exact production order: configuration change interrupts the relay;
        // adapter quiescence then calls source.stop(), which calls finish().
        relay.interrupt()
        let interrupted = await events.next()
        XCTAssertEqual(interrupted, .interrupted)
        let terminal = await events.next()
        XCTAssertNil(terminal)
        relay.finish()
        relay.finish()
    }

    func testRelayBoundsCallbackQueueAndFlushesOverflowAsCaptureGap() async throws {
        let drainQueue = DispatchQueue(label: "relay-overflow-test")
        let blocker = DispatchSemaphore(value: 0)
        drainQueue.async { blocker.wait() }
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let relay = AVFoundationInputRelay(
            continuation: stream.continuation,
            queueCapacity: 2,
            drainQueue: drainQueue
        )
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        for start: Int64 in [0, 4, 8] {
            relay.accept(
                buffer: buffer,
                time: AVAudioTime(sampleTime: start, atRate: 48_000)
            )
        }
        blocker.signal()
        relay.finish()

        var events = stream.stream.makeAsyncIterator()
        guard case let .chunk(first) = await events.next(),
              case let .chunk(second) = await events.next()
        else { return XCTFail("accepted callbacks were not drained") }
        XCTAssertEqual(first.startSampleFrame, 0)
        XCTAssertEqual(second.startSampleFrame, 4)
        let gap = await events.next()
        XCTAssertEqual(
            gap,
            .captureGap(
                sampleRateHz: 48_000,
                startSampleFrame: 8,
                frameCount: 4,
                channelCount: 1
            )
        )
        let terminal = await events.next()
        XCTAssertNil(terminal)
    }

    func testRelayTreatsOverflowAlreadyCoveredByLaterProjectedChunkAsObsolete() async throws {
        let drainQueue = DispatchQueue(label: "relay-obsolete-overflow")
        let holdDrain = DispatchSemaphore(value: 0)
        drainQueue.async { holdDrain.wait() }
        let firstBlockProjected = DispatchSemaphore(value: 0)
        let resumeDrain = DispatchSemaphore(value: 0)
        let pauseOnce = Atomic<Bool>(true)
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let relay = AVFoundationInputRelay(
            continuation: stream.continuation,
            queueCapacity: 2,
            drainQueue: drainQueue,
            afterBlockProjected: {
                if pauseOnce.compareExchange(
                    expected: true,
                    desired: false,
                    ordering: .acquiringAndReleasing
                ).exchanged {
                    firstBlockProjected.signal()
                    resumeDrain.wait()
                }
            }
        )
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4

        // A/B fill the ring, C becomes compacted overflow evidence. Once A
        // is projected it frees a slot; D enters and is projected before C's
        // evidence is claimed. D's absolute position makes C's gap explicit.
        for start: Int64 in [0, 4, 8] {
            relay.accept(buffer: buffer, time: AVAudioTime(sampleTime: start, atRate: 48_000))
        }
        holdDrain.signal()
        XCTAssertEqual(firstBlockProjected.wait(timeout: .now() + 1), .success)
        relay.accept(buffer: buffer, time: AVAudioTime(sampleTime: 12, atRate: 48_000))
        resumeDrain.signal()
        relay.finish()

        var events = stream.stream.makeAsyncIterator()
        guard case let .chunk(first) = await events.next(),
              case let .chunk(second) = await events.next(),
              case let .chunk(later) = await events.next()
        else { return XCTFail("projected callbacks missing") }
        XCTAssertEqual(first.startSampleFrame, 0)
        XCTAssertEqual(second.startSampleFrame, 4)
        XCTAssertEqual(later.startSampleFrame, 12)
        let terminal = await events.next()
        XCTAssertNil(terminal)
    }

    func testRelayRejectsSampleFrameArithmeticOverflowBeforeCopying() async throws {
        let stream = AsyncStream<MicrophoneInputEvent>.makeStream()
        let relay = AVFoundationInputRelay(continuation: stream.continuation)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        var events = stream.stream.makeAsyncIterator()
        relay.accept(
            buffer: buffer,
            time: AVAudioTime(sampleTime: Int64.max - 1, atRate: 48_000)
        )
        let invalid = await events.next()
        XCTAssertEqual(invalid, .clockBecameInvalid)
        let terminal = await events.next()
        XCTAssertNil(terminal)
    }

    func testSyntheticCaptureMuteGapStopSealAndLateCallbackFencing() async throws {
        try await withAdapterLibrary { root, request in
            let source = FakeMicrophoneInputSource()
            let clock = FakeCaptureMonotonicClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: FixedRecordingRoot(root: root),
                sources: FixedInputFactory(source: source),
                monotonicClock: clock
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            var observations = feed.observations.makeAsyncIterator()
            let initial = await observations.next()
            XCTAssertEqual(
                initial,
                .progress(frameCount: 0, level: .unavailable(.stale))
            )

            await source.emit(
                .chunk(
                    try MicrophoneInputChunk(
                        sampleRateHz: 16_000,
                        startSampleFrame: 0,
                        channels: [[0.25, 0.5]]
                    )
                )
            )
            guard case let .progress(frames, level) = await observations.next() else {
                return XCTFail("missing observed progress")
            }
            XCTAssertEqual(frames, 2)
            guard case let .measured(value) = level else {
                return XCTFail("expected measured level")
            }
            XCTAssertGreaterThan(value, 0)

            let muteOutcome = await adapter.apply(.setMuted(true), to: request.recordingID)
            XCTAssertEqual(muteOutcome, .accepted)
            let muteAcknowledgement = await observations.next()
            XCTAssertEqual(
                muteAcknowledgement,
                .muteChanged(isMuted: true, effectiveFrame: 2)
            )
            await source.emit(
                .chunk(
                    try MicrophoneInputChunk(
                        sampleRateHz: 16_000,
                        startSampleFrame: 4,
                        channels: [[0.75, 0.5]]
                    )
                )
            )
            let gapProgress = await observations.next()
            XCTAssertEqual(
                gapProgress,
                .progress(frameCount: 4, level: .unavailable(.muted))
            )
            let mutedProgress = await observations.next()
            XCTAssertEqual(
                mutedProgress,
                .progress(frameCount: 6, level: .unavailable(.muted))
            )

            let stopOutcome = await adapter.apply(.stop, to: request.recordingID)
            XCTAssertEqual(stopOutcome, .accepted)
            let finishing = await observations.next()
            XCTAssertEqual(
                finishing,
                .finishing(reason: .userStop, frameCount: 6)
            )
            let sealing = await observations.next()
            XCTAssertEqual(
                sealing,
                .sealing(reason: .userStop, frameCount: 6)
            )
            guard case let .sealCandidate(candidate) = await observations.next() else {
                return XCTFail("missing staged seal candidate")
            }
            XCTAssertEqual(candidate.terminalReason, CaptureTerminalReason.userStop.rawValue)
            XCTAssertEqual(candidate.frameCount, 6)
            XCTAssertEqual(try sessionNames(in: root), [])
            let terminal = await observations.next()
            XCTAssertNil(terminal)

            let publication = try RecordingSealCandidateValidator.validate(
                candidate,
                expected: request
            )
            guard case let .installed(receipt) = await adapter.completeSeal(
                .publish(publication)
            ) else {
                return XCTFail("authoritative publication failed")
            }
            XCTAssertEqual(receipt, publication.receipt)

            await source.emit(
                .chunk(
                    try MicrophoneInputChunk(
                        sampleRateHz: 16_000,
                        startSampleFrame: 6,
                        channels: [[1, 1]]
                    )
                )
            )
            let audioURL = root.appendingPathComponent(
                "sessions/\(request.sessionID.rawValue)/audio/audio.json"
            )
            let audio = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: audioURL)) as? [String: Any]
            )
            XCTAssertEqual(audio["frameCount"] as? Int, 6)
            let intervals = try XCTUnwrap(
                audio["unavailableIntervals"] as? [[String: Any]]
            )
            XCTAssertEqual(intervals.count, 2)
            XCTAssertEqual(Set(intervals[0]["reasons"] as? [String] ?? []), ["captureGap", "muted"])
            XCTAssertEqual(Set(intervals[1]["reasons"] as? [String] ?? []), ["muted"])
            let stopCount = await source.stopCount
            XCTAssertEqual(stopCount, 1)
        }
    }

    func testBufferedChunkCapturedWhileMutedCannotBecomePersistableAfterUnmute() async throws {
        try await withAdapterLibrary { root, request in
            let source = FakeMicrophoneInputSource(deliveryPaused: true)
            let clock = FakeCaptureMonotonicClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: FixedRecordingRoot(root: root),
                sources: FixedInputFactory(source: source),
                monotonicClock: clock
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            var observations = feed.observations.makeAsyncIterator()
            _ = await observations.next()

            let mute = await adapter.apply(.setMuted(true), to: request.recordingID)
            XCTAssertEqual(mute, .accepted)
            await source.emit(
                .chunk(
                    try MicrophoneInputChunk(
                        sampleRateHz: 16_000,
                        startSampleFrame: 0,
                        channels: [[0.75, -0.75]]
                    )
                )
            )
            await source.releaseBufferedEvents()
            let muteAcknowledgement = await observations.next()
            XCTAssertEqual(
                muteAcknowledgement,
                .muteChanged(isMuted: true, effectiveFrame: 0)
            )
            let unmute = await adapter.apply(.setMuted(false), to: request.recordingID)
            XCTAssertEqual(unmute, .accepted)
            let stop = await adapter.apply(.stop, to: request.recordingID)
            XCTAssertEqual(stop, .accepted)

            var candidate: StagedRecordingSealCandidate?
            while let observation = await observations.next() {
                if case let .sealCandidate(value) = observation { candidate = value }
            }
            let sealed = try XCTUnwrap(candidate)
            XCTAssertEqual(sealed.frameCount, 2)
            XCTAssertEqual(
                sealed.unavailableIntervals,
                [
                    StagedUnavailableInterval(
                        startFrame: 0,
                        endFrame: 2,
                        reasons: [UnavailableReason.muted.rawValue]
                    ),
                ]
            )
        }
    }

    func testMonotonicDeadlinesAdvanceStalledOpenFeedAndSealAtFortyFiveMinutes() async throws {
        try await withAdapterLibrary { root, request in
            let source = FakeMicrophoneInputSource()
            let clock = FakeCaptureMonotonicClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: FixedRecordingRoot(root: root),
                sources: FixedInputFactory(source: source),
                monotonicClock: clock
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            var observations = feed.observations.makeAsyncIterator()
            let initial = await observations.next()
            XCTAssertEqual(initial, .progress(frameCount: 0, level: .unavailable(.stale)))

            await clock.advance(toElapsedSeconds: 40 * 60)
            let warning = await observations.next()
            XCTAssertEqual(
                warning,
                .progress(
                    frameCount: CanonicalRecordingLimits.fiveMinuteWarningFrame,
                    level: .unavailable(.stale)
                )
            )
            await clock.advance(toElapsedSeconds: 44 * 60)
            let countdown = await observations.next()
            XCTAssertEqual(
                countdown,
                .progress(
                    frameCount: CanonicalRecordingLimits.oneMinuteCountdownFrame,
                    level: .unavailable(.stale)
                )
            )
            for elapsed in (44 * 60 + 1)...(44 * 60 + 59) {
                await clock.advance(toElapsedSeconds: UInt64(elapsed))
                _ = await observations.next()
            }
            await clock.advance(toElapsedSeconds: 45 * 60)
            let automaticStop = await observations.next()
            XCTAssertEqual(
                automaticStop,
                .progress(
                    frameCount: CanonicalRecordingLimits.maximumFrames,
                    level: .unavailable(.captureGap)
                )
            )
            let finishing = await observations.next()
            XCTAssertEqual(
                finishing,
                .finishing(
                    reason: .durationLimit,
                    frameCount: CanonicalRecordingLimits.maximumFrames
                )
            )
            let stopCount = await source.stopCount
            XCTAssertEqual(stopCount, 1)
            let sealing = await observations.next()
            XCTAssertEqual(
                sealing,
                .sealing(
                    reason: .durationLimit,
                    frameCount: CanonicalRecordingLimits.maximumFrames
                )
            )
            guard case let .sealCandidate(candidate) = await observations.next() else {
                return XCTFail("missing duration-limit seal candidate")
            }
            XCTAssertEqual(candidate.frameCount, CanonicalRecordingLimits.maximumFrames)
            XCTAssertEqual(
                candidate.unavailableIntervals,
                [
                    StagedUnavailableInterval(
                        startFrame: 0,
                        endFrame: CanonicalRecordingLimits.maximumFrames,
                        reasons: [UnavailableReason.captureGap.rawValue]
                    ),
                ]
            )
        }
    }

    func testDeadlineProjectionDoesNotAdvancePastAcceptedButBackloggedInput() async throws {
        try await withAdapterLibrary { root, request in
            let source = FakeMicrophoneInputSource(
                deliveryPaused: true,
                drainsBufferedEventsWhenStopped: true
            )
            let clock = FakeCaptureMonotonicClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: FixedRecordingRoot(root: root),
                sources: FixedInputFactory(source: source),
                monotonicClock: clock
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            var observations = feed.observations.makeAsyncIterator()
            _ = await observations.next()
            await source.emit(
                .chunk(
                    try MicrophoneInputChunk(
                        sampleRateHz: 16_000,
                        startSampleFrame: 0,
                        channels: [[0.25, -0.25]]
                    )
                )
            )

            await clock.advance(toElapsedSeconds: 40 * 60)
            let warning = await observations.next()
            XCTAssertEqual(
                warning,
                .progress(
                    frameCount: CanonicalRecordingLimits.fiveMinuteWarningFrame,
                    level: .unavailable(.stale)
                )
            )

            await clock.advance(toElapsedSeconds: 45 * 60)
            var candidate: StagedRecordingSealCandidate?
            while let observation = await observations.next() {
                if case let .sealCandidate(value) = observation { candidate = value }
            }
            let sealed = try XCTUnwrap(candidate)
            XCTAssertEqual(sealed.frameCount, CanonicalRecordingLimits.maximumFrames)
            XCTAssertEqual(
                sealed.unavailableIntervals,
                [
                    StagedUnavailableInterval(
                        startFrame: 2,
                        endFrame: CanonicalRecordingLimits.maximumFrames,
                        reasons: [UnavailableReason.captureGap.rawValue]
                    ),
                ]
            )
        }
    }

    func testUserStopAfterCallbackFreeStallMaterializesOnlyElapsedGap() async throws {
        try await withAdapterLibrary { root, request in
            let source = FakeMicrophoneInputSource()
            let clock = FakeCaptureMonotonicClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: FixedRecordingRoot(root: root),
                sources: FixedInputFactory(source: source),
                monotonicClock: clock
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            var observations = feed.observations.makeAsyncIterator()
            _ = await observations.next()
            await clock.advance(toElapsedSeconds: 7)
            let stop = await adapter.apply(.stop, to: request.recordingID)
            XCTAssertEqual(stop, .accepted)
            var candidate: StagedRecordingSealCandidate?
            while let observation = await observations.next() {
                if case let .sealCandidate(value) = observation { candidate = value }
            }
            let sealed = try XCTUnwrap(candidate)
            XCTAssertEqual(sealed.frameCount, 7 * 16_000)
            XCTAssertEqual(
                sealed.unavailableIntervals,
                [
                    StagedUnavailableInterval(
                        startFrame: 0,
                        endFrame: 7 * 16_000,
                        reasons: [UnavailableReason.captureGap.rawValue]
                    ),
                ]
            )
        }
    }

    func testStopWithUnacknowledgedMutePreservesPendingMuteInterval() async throws {
        try await withAdapterLibrary { root, request in
            let source = FakeMicrophoneInputSource(acknowledgesMuteImmediately: false)
            let clock = FakeCaptureMonotonicClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: FixedRecordingRoot(root: root),
                sources: FixedInputFactory(source: source),
                monotonicClock: clock
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            var observations = feed.observations.makeAsyncIterator()
            _ = await observations.next()
            await clock.advance(toElapsedSeconds: 1)
            let mute = await adapter.apply(.setMuted(true), to: request.recordingID)
            XCTAssertEqual(mute, .accepted)
            await clock.advance(toElapsedSeconds: 2)
            let stop = await adapter.apply(.stop, to: request.recordingID)
            XCTAssertEqual(stop, .accepted)

            var progressFrames: [UInt64] = []
            var progressLevels: [CaptureLevel] = []
            while let observation = await observations.next() {
                if case let .progress(frameCount, level) = observation {
                    progressFrames.append(frameCount)
                    progressLevels.append(level)
                }
                if case .recoveryRequired = observation {
                    return XCTFail("pending mute stop unexpectedly recovered")
                }
            }
            XCTAssertEqual(progressFrames, [16_000, 32_000])
            XCTAssertEqual(progressLevels.count, 2)
            XCTAssertEqual(progressLevels[0], .unavailable(.captureGap))
            XCTAssertEqual(progressLevels[1], .unavailable(.muted))
        }
    }

    func testStalledCountdownBeginsAtFiftyNineSecondsRemaining() async throws {
        try await withAdapterLibrary { root, request in
            let source = FakeMicrophoneInputSource()
            let clock = FakeCaptureMonotonicClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: FixedRecordingRoot(root: root),
                sources: FixedInputFactory(source: source),
                monotonicClock: clock
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            var observations = feed.observations.makeAsyncIterator()
            _ = await observations.next()

            await clock.advance(toElapsedSeconds: 40 * 60)
            let warning = await observations.next()
            XCTAssertEqual(
                warning,
                .progress(
                    frameCount: CanonicalRecordingLimits.fiveMinuteWarningFrame,
                    level: .unavailable(.stale)
                )
            )
            await clock.advance(toElapsedSeconds: 44 * 60)
            let sixtySecondTick = await observations.next()
            XCTAssertEqual(
                sixtySecondTick,
                .progress(
                    frameCount: CanonicalRecordingLimits.oneMinuteCountdownFrame,
                    level: .unavailable(.stale)
                )
            )
            var selectedTicks: [UInt64] = []
            for elapsed in (44 * 60 + 1)...(44 * 60 + 59) {
                await clock.advance(toElapsedSeconds: UInt64(elapsed))
                guard case let .progress(frameCount, level) = await observations.next() else {
                    return XCTFail("missing countdown tick for \(elapsed)")
                }
                XCTAssertEqual(level, .unavailable(.stale))
                let remaining = 45 * 60 - elapsed
                if [59, 30, 10, 1].contains(remaining) {
                    selectedTicks.append(frameCount)
                }
            }
            XCTAssertEqual(
                selectedTicks,
                [59, 30, 10, 1].map {
                    CanonicalRecordingLimits.maximumFrames - UInt64($0 * 16_000)
                }
            )
            _ = await adapter.apply(.discardConfirmed, to: request.recordingID)
        }
    }

    func testMuteAcknowledgementProjectsItsEffectiveInputFrameWithoutPersistingTime() async throws {
        try await withAdapterLibrary { root, request in
            let source = FakeMicrophoneInputSource(
                format: try MicrophoneInputFormat(sampleRateHz: 48_000, channelCount: 1)
            )
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: FixedRecordingRoot(root: root),
                sources: FixedInputFactory(source: source)
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            var observations = feed.observations.makeAsyncIterator()
            _ = await observations.next()
            await source.emit(
                .chunk(
                    try MicrophoneInputChunk(
                        sampleRateHz: 48_000,
                        startSampleFrame: 0,
                        channels: [[0.25]]
                    )
                )
            )
            await source.emit(
                .muteChanged(
                    epoch: MicrophoneMuteEpoch(sequence: 1, isMuted: true),
                    effectiveInputFrame: 48_000
                )
            )
            let acknowledgement = await observations.next()
            XCTAssertEqual(
                acknowledgement,
                .muteChanged(isMuted: true, effectiveFrame: 16_000)
            )
            _ = await adapter.apply(.discardConfirmed, to: request.recordingID)
        }
    }

    func testMuteAfterStalledWarningUsesNonRegressingProjectedFrame() async throws {
        try await withAdapterLibrary { root, request in
            let source = FakeMicrophoneInputSource()
            let clock = FakeCaptureMonotonicClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: FixedRecordingRoot(root: root),
                sources: FixedInputFactory(source: source),
                monotonicClock: clock
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            var observations = feed.observations.makeAsyncIterator()
            _ = await observations.next()
            await clock.advance(toElapsedSeconds: 40 * 60)
            _ = await observations.next()

            let mute = await adapter.apply(.setMuted(true), to: request.recordingID)
            XCTAssertEqual(mute, .accepted)
            let fencedGap = await observations.next()
            XCTAssertEqual(
                fencedGap,
                .progress(
                    frameCount: CanonicalRecordingLimits.fiveMinuteWarningFrame,
                    level: .unavailable(.captureGap)
                )
            )
            let acknowledgement = await observations.next()
            XCTAssertEqual(
                acknowledgement,
                .muteChanged(
                    isMuted: true,
                    effectiveFrame: CanonicalRecordingLimits.fiveMinuteWarningFrame
                )
            )
            _ = await adapter.apply(.discardConfirmed, to: request.recordingID)
        }
    }

    func testStalledMuteThenUnmuteRecordsOnlyTheMutedMonotonicInterval() async throws {
        try await withAdapterLibrary { root, request in
            let source = FakeMicrophoneInputSource()
            let clock = FakeCaptureMonotonicClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: FixedRecordingRoot(root: root),
                sources: FixedInputFactory(source: source),
                monotonicClock: clock
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            var observations = feed.observations.makeAsyncIterator()
            _ = await observations.next()
            await clock.advance(toElapsedSeconds: 40 * 60)
            _ = await observations.next()

            let mute = await adapter.apply(.setMuted(true), to: request.recordingID)
            XCTAssertEqual(mute, .accepted)
            _ = await observations.next()
            _ = await observations.next()
            await clock.advance(toElapsedSeconds: 42 * 60)
            let unmute = await adapter.apply(.setMuted(false), to: request.recordingID)
            XCTAssertEqual(unmute, .accepted)
            _ = await observations.next()
            _ = await observations.next()

            await clock.advance(toElapsedSeconds: 45 * 60)
            var candidate: StagedRecordingSealCandidate?
            while let observation = await observations.next() {
                if case let .sealCandidate(value) = observation { candidate = value }
            }
            let sealed = try XCTUnwrap(candidate)
            XCTAssertEqual(
                sealed.unavailableIntervals,
                [
                    StagedUnavailableInterval(
                        startFrame: 0,
                        endFrame: CanonicalRecordingLimits.fiveMinuteWarningFrame,
                        reasons: [UnavailableReason.captureGap.rawValue]
                    ),
                    StagedUnavailableInterval(
                        startFrame: CanonicalRecordingLimits.fiveMinuteWarningFrame,
                        endFrame: 42 * 60 * 16_000,
                        reasons: [
                            UnavailableReason.captureGap.rawValue,
                            UnavailableReason.muted.rawValue,
                        ]
                    ),
                    StagedUnavailableInterval(
                        startFrame: 42 * 60 * 16_000,
                        endFrame: CanonicalRecordingLimits.maximumFrames,
                        reasons: [UnavailableReason.captureGap.rawValue]
                    ),
                ]
            )
        }
    }

    func testUserStopDrainsBufferedFinalFramesBeforeFreezingSealWatermark() async throws {
        try await withAdapterLibrary { root, request in
            let source = FakeMicrophoneInputSource()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: FixedRecordingRoot(root: root),
                sources: FixedInputFactory(source: source)
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            var observations = feed.observations.makeAsyncIterator()
            _ = await observations.next()
            await source.emit(
                .chunk(
                    try MicrophoneInputChunk(
                        sampleRateHz: 16_000,
                        startSampleFrame: 0,
                        channels: [[0.1, 0.2]]
                    )
                )
            )
            await source.emit(
                .chunk(
                    try MicrophoneInputChunk(
                        sampleRateHz: 16_000,
                        startSampleFrame: 2,
                        channels: [[0.3, 0.4]]
                    )
                )
            )
            let stop = await adapter.apply(.stop, to: request.recordingID)
            XCTAssertEqual(stop, .accepted)
            var candidate: StagedRecordingSealCandidate?
            while let event = await observations.next() {
                if case let .sealCandidate(value) = event { candidate = value }
            }
            let staged = try XCTUnwrap(candidate)
            XCTAssertEqual(staged.frameCount, 4)
            let publication = try RecordingSealCandidateValidator.validate(
                staged,
                expected: request
            )
            let outcome = await adapter.completeSeal(.publish(publication))
            XCTAssertEqual(outcome, .installed(publication.receipt))
        }
    }

    func testAdapterCapsCrossingChunkAtExactlyFortyFiveMinutes() async throws {
        try await withAdapterLibrary { root, request in
            let source = FakeMicrophoneInputSource()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: FixedRecordingRoot(root: root),
                sources: FixedInputFactory(source: source),
                persistenceFault: { point in
                    if point == .beforeSealScan {
                        throw RecordingPersistenceError.injectedFault(point)
                    }
                }
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            var observations = feed.observations.makeAsyncIterator()
            _ = await observations.next()
            await source.emit(
                .chunk(
                    try MicrophoneInputChunk(
                        sampleRateHz: 16_000,
                        startSampleFrame: CanonicalRecordingLimits.maximumFrames - 1,
                        channels: [[0.25, 0.5]]
                    )
                )
            )

            var maximumObserved: UInt64 = 0
            var recovery: RecordingRecoveryItem?
            while let event = await observations.next() {
                switch event {
                case let .progress(frameCount, _),
                     let .finishing(_, frameCount),
                     let .sealing(_, frameCount):
                    maximumObserved = max(maximumObserved, frameCount)
                case let .recoveryRequired(item):
                    recovery = item
                case .sealCandidate, .muteChanged, .discarded:
                    break
                }
            }
            XCTAssertEqual(maximumObserved, CanonicalRecordingLimits.maximumFrames)
            XCTAssertEqual(recovery?.durableFrameCount, CanonicalRecordingLimits.maximumFrames)
            let stopCount = await source.stopCount
            XCTAssertEqual(stopCount, 1)
        }
    }

    func testUnavailableInputDoesNotCreateRecordingStagingOrSession() async throws {
        try await withAdapterLibrary { root, request in
            let source = FakeMicrophoneInputSource(startOutcome: .unavailable)
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: FixedRecordingRoot(root: root),
                sources: FixedInputFactory(source: source)
            )
            guard case let .rejected(failure) = await adapter.begin(request) else {
                return XCTFail("unavailable input unexpectedly started")
            }
            XCTAssertEqual(failure, .microphoneUnavailable)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: root.appendingPathComponent("staging/recordings").path
                ),
                []
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: root.appendingPathComponent("sessions").path
                ),
                []
            )
        }
    }

    func testPermissionDenialIsBoundedAndCreatesNoPortableAuthority() async throws {
        try await withAdapterLibrary { root, request in
            let source = FakeMicrophoneInputSource(startOutcome: .permissionDenied)
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: FixedRecordingRoot(root: root),
                sources: FixedInputFactory(source: source)
            )
            guard case let .rejected(failure) = await adapter.begin(request) else {
                return XCTFail("permission-denied input unexpectedly started")
            }
            XCTAssertEqual(failure, .microphonePermissionDenied)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: root.appendingPathComponent("staging/recordings").path
                ),
                []
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: root.appendingPathComponent("sessions").path
                ),
                []
            )
        }
    }

    func testInterruptionExposesSealOrDiscardWithoutResume() async throws {
        try await withAdapterLibrary { root, request in
            let source = FakeMicrophoneInputSource()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: FixedRecordingRoot(root: root),
                sources: FixedInputFactory(source: source)
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            var observations = feed.observations.makeAsyncIterator()
            _ = await observations.next()
            await source.emit(
                .chunk(
                    try MicrophoneInputChunk(
                        sampleRateHz: 16_000,
                        startSampleFrame: 0,
                        channels: [[0.1, 0.2]]
                    )
                )
            )
            _ = await observations.next()
            await source.emit(.interrupted)
            var latestProgressFrameCount: UInt64 = 2
            var finishingFrameCount: UInt64?
            var recoveryItem: RecordingRecoveryItem?
            while let observation = await observations.next() {
                switch observation {
                case let .progress(frameCount, _):
                    latestProgressFrameCount = max(latestProgressFrameCount, frameCount)
                case let .finishing(reason, frameCount):
                    XCTAssertEqual(reason, .interruption)
                    finishingFrameCount = frameCount
                case let .recoveryRequired(item):
                    recoveryItem = item
                case .sealing, .sealCandidate, .muteChanged, .discarded:
                    XCTFail("interruption emitted an unexpected terminal observation")
                }
            }
            let interruptedFrames = try XCTUnwrap(finishingFrameCount)
            let item = try XCTUnwrap(recoveryItem)
            XCTAssertGreaterThanOrEqual(interruptedFrames, 2)
            XCTAssertGreaterThanOrEqual(interruptedFrames, latestProgressFrameCount)
            XCTAssertEqual(item.durableFrameCount, interruptedFrames)
            XCTAssertEqual(item.availability, .sealOrDiscard)
            XCTAssertEqual(item.recordingID, request.recordingID)

            let catalog = await adapter.inspectRecovery(in: request.libraryScope)
            XCTAssertEqual(catalog.items, [item])
            guard case let .sealCandidate(candidate) = await adapter.resolveRecovery(
                .seal,
                recordingID: request.recordingID,
                in: request.libraryScope
            ) else {
                return XCTFail("recovery seal failed")
            }
            XCTAssertEqual(try sessionNames(in: root), [])
            let publication = try RecordingSealCandidateValidator.validate(
                candidate,
                expected: request
            )
            let outcome = await adapter.completeSeal(.publish(publication))
            XCTAssertEqual(outcome, .installed(publication.receipt))
            XCTAssertEqual(publication.receipt.sessionID, request.sessionID)
        }
    }

    func testDurableWatermarkFaultPreservesAcceptedFramesForRecovery() async throws {
        try await withAdapterLibrary { root, request in
            let source = FakeMicrophoneInputSource()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: FixedRecordingRoot(root: root),
                sources: FixedInputFactory(source: source),
                persistenceFault: { point in
                    if point == .afterWatermarkFlush {
                        throw RecordingPersistenceError.injectedFault(point)
                    }
                }
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            var observations = feed.observations.makeAsyncIterator()
            _ = await observations.next()
            await source.emit(
                .chunk(
                    try MicrophoneInputChunk(
                        sampleRateHz: 16_000,
                        startSampleFrame: 0,
                        channels: [[0.1, 0.2, 0.3, 0.4]]
                    )
                )
            )
            let finishing = await observations.next()
            XCTAssertEqual(
                finishing,
                .finishing(reason: .interruption, frameCount: 4)
            )
            guard case let .recoveryRequired(item) = await observations.next() else {
                return XCTFail("durable frames were not exposed for recovery")
            }
            XCTAssertEqual(item.durableFrameCount, 4)
            XCTAssertEqual(item.availability, .sealOrDiscard)
        }
    }
}

private actor FakeMicrophoneInputSource: MicrophoneInputSource {
    nonisolated let events: AsyncStream<MicrophoneInputEvent>
    nonisolated let format: MicrophoneInputFormat
    private let continuation: AsyncStream<MicrophoneInputEvent>.Continuation
    private let configuredOutcome: ConfiguredOutcome
    private var deliveryPaused: Bool
    private let drainsBufferedEventsWhenStopped: Bool
    private let acknowledgesMuteImmediately: Bool
    private var bufferedEvents: [MicrophoneInputEvent] = []
    private var muteEpoch = MicrophoneMuteEpoch.initial
    private var effectiveInputFrame: UInt64 = 0
    private(set) var stopCount = 0

    enum ConfiguredOutcome {
        case started
        case permissionDenied
        case unavailable
    }

    init(
        startOutcome: ConfiguredOutcome = .started,
        deliveryPaused: Bool = false,
        drainsBufferedEventsWhenStopped: Bool = false,
        acknowledgesMuteImmediately: Bool = true,
        format: MicrophoneInputFormat = try! MicrophoneInputFormat(
            sampleRateHz: 16_000,
            channelCount: 1
        )
    ) {
        var stored: AsyncStream<MicrophoneInputEvent>.Continuation!
        events = AsyncStream { stored = $0 }
        continuation = stored
        configuredOutcome = startOutcome
        self.format = format
        self.deliveryPaused = deliveryPaused
        self.drainsBufferedEventsWhenStopped = drainsBufferedEventsWhenStopped
        self.acknowledgesMuteImmediately = acknowledgesMuteImmediately
    }

    func start(
        monotonicClock: any CaptureMonotonicClock
    ) async -> MicrophoneInputStartOutcome {
        switch configuredOutcome {
        case .started:
            let captureStart = await monotonicClock.captureStart()
            return .started(
                MicrophoneInputFeed(
                    format: format,
                    captureStartedAtMonotonicNanoseconds: captureStart.uptimeNanoseconds,
                    events: events
                )
            )
        case .permissionDenied:
            return .permissionDenied
        case .unavailable:
            return .unavailable
        }
    }

    func stop() {
        stopCount += 1
        if drainsBufferedEventsWhenStopped {
            releaseBufferedEvents()
        }
        continuation.finish()
    }

    func setMuted(_ muted: Bool) -> Bool {
        guard muteEpoch.isMuted != muted else { return true }
        muteEpoch = MicrophoneMuteEpoch(sequence: muteEpoch.sequence + 1, isMuted: muted)
        if acknowledgesMuteImmediately {
            emit(.muteChanged(epoch: muteEpoch, effectiveInputFrame: effectiveInputFrame))
        }
        return true
    }

    func emit(_ event: MicrophoneInputEvent) {
        let tagged = tag(event)
        updateEffectiveInputFrame(for: tagged)
        if deliveryPaused {
            bufferedEvents.append(tagged)
        } else {
            continuation.yield(tagged)
        }
    }

    func releaseBufferedEvents() {
        deliveryPaused = false
        for event in bufferedEvents { continuation.yield(event) }
        bufferedEvents.removeAll(keepingCapacity: false)
    }

    private func tag(_ event: MicrophoneInputEvent) -> MicrophoneInputEvent {
        switch event {
        case let .chunk(chunk):
            guard chunk.muteEpoch == .initial,
                  let tagged = try? MicrophoneInputChunk(
                      sampleRateHz: chunk.sampleRateHz,
                      startSampleFrame: chunk.startSampleFrame,
                      channels: chunk.channels,
                      muteEpoch: muteEpoch
                  )
            else { return event }
            return .chunk(tagged)
        case let .captureGap(rate, start, count, channels, epoch):
            return .captureGap(
                sampleRateHz: rate,
                startSampleFrame: start,
                frameCount: count,
                channelCount: channels,
                muteEpoch: epoch == .initial ? muteEpoch : epoch
            )
        case let .mutedInterval(rate, start, count, channels, epoch):
            return .mutedInterval(
                sampleRateHz: rate,
                startSampleFrame: start,
                frameCount: count,
                channelCount: channels,
                muteEpoch: epoch == .initial ? muteEpoch : epoch
            )
        case .muteChanged, .interrupted, .clockBecameInvalid:
            return event
        }
    }

    private func updateEffectiveInputFrame(for event: MicrophoneInputEvent) {
        switch event {
        case let .chunk(chunk):
            effectiveInputFrame = max(effectiveInputFrame, chunk.startSampleFrame + chunk.frameCount)
        case let .captureGap(_, start, count, _, _):
            effectiveInputFrame = max(effectiveInputFrame, start + count)
        case let .mutedInterval(_, start, count, _, _):
            effectiveInputFrame = max(effectiveInputFrame, start + count)
        case .muteChanged, .interrupted, .clockBecameInvalid:
            break
        }
    }
}

private actor FakeCaptureMonotonicClock: CaptureMonotonicClock {
    private struct Sleeper {
        let id: UUID
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var nowNanoseconds: UInt64 = 0
    private var sleepers: [Sleeper] = []

    func now() -> UInt64 { nowNanoseconds }

    func sleep(until deadline: UInt64) async throws {
        guard deadline > nowNanoseconds else { return }
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers.append(
                        Sleeper(
                            id: id,
                            deadline: deadline,
                            continuation: continuation
                        )
                    )
                }
            }
        }, onCancel: {
            Task { await self.cancelSleeper(id) }
        })
    }

    func advance(toElapsedSeconds seconds: UInt64) {
        nowNanoseconds = seconds * 1_000_000_000
        let ready = sleepers.filter { $0.deadline <= nowNanoseconds }
        sleepers.removeAll { $0.deadline <= nowNanoseconds }
        ready.forEach { $0.continuation.resume(returning: ()) }
    }

    private func cancelSleeper(_ id: UUID) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        let sleeper = sleepers.remove(at: index)
        sleeper.continuation.resume(throwing: CancellationError())
    }
}

private struct FixedInputFactory: MicrophoneInputSourceFactory {
    let source: FakeMicrophoneInputSource
    func makeSource() async -> any MicrophoneInputSource { source }
}

private struct FixedRecordingRoot: RecordingLibraryRootProviding {
    let root: URL
    func recordingRoot(for scope: LibraryScope) async -> URL? { root }
}

private func withAdapterLibrary(
    _ body: (URL, MicrophoneRecordingRequest) async throws -> Void
) async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
        "audora-capture-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("Synthetic.audoralibrary", isDirectory: true)
    let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
    let libraryID = try LibraryID("lib-20260830T120000000Z-1ABC")
    _ = try PortableLibraryPersistence().create(
        at: root,
        seed: NewLibrarySeed(
            libraryID: libraryID,
            createdAt: instant,
            preferences: .defaults,
            profileHead: ProfileHead(
                generation: 0,
                statementGeneration: 0,
                selection: .null,
                updatedAt: instant
            )
        )
    )
    try await body(
        root,
        MicrophoneRecordingRequest(
            libraryScope: LibraryScope(libraryID: libraryID),
            recordingID: try RecordingID("rec-20260830T120000000Z-2ABC"),
            sessionID: try SessionID("ses-20260830T120000000Z-3DEF"),
            startedAt: instant
        )
    )
}

private func sessionNames(in root: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("sessions").path
    ).sorted()
}
