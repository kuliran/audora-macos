import AudoraApplication
import AudoraDomain
@testable import AudoraMacInfrastructure
import Foundation
import Synchronization
import XCTest

final class AVFoundationAudioCaptureAdapterConcurrencyTests: XCTestCase {
    func testCancelledObservationWaiterCannotStealConcurrentPublication() {
        let waiterInstalled = DispatchSemaphore(value: 0)
        let cancellationFlagStored = DispatchSemaphore(value: 0)
        let releaseCancellationLock = DispatchSemaphore(value: 0)
        let cancellationReturned = DispatchSemaphore(value: 0)
        let observationBuffered = DispatchSemaphore(value: 0)
        let cancelledWaiterCompleted = DispatchSemaphore(value: 0)
        let replacementCompleted = DispatchSemaphore(value: 0)
        let shouldGateCancellation = Atomic<Bool>(true)
        let cancelledWaiterResult = Atomic<Int>(0)
        let replacementResult = Atomic<Int>(0)
        let broker = BoundedCaptureObservationBroker(
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
            afterCancelledWaiterObservationBuffered: {
                observationBuffered.signal()
            }
        )
        let waiting = Task {
            let value = await broker.next()
            cancelledWaiterResult.store(value == nil ? 1 : 2, ordering: .releasing)
            cancelledWaiterCompleted.signal()
        }
        XCTAssertEqual(waiterInstalled.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            waiting.cancel()
            cancellationReturned.signal()
        }
        XCTAssertEqual(cancellationFlagStored.wait(timeout: .now() + 1), .success)

        let publication = CaptureObservation.progress(
            frameCount: 7,
            level: .unavailable(.stale)
        )
        broker.publish(publication)
        XCTAssertEqual(observationBuffered.wait(timeout: .now() + 1), .success)
        releaseCancellationLock.signal()
        XCTAssertEqual(cancellationReturned.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(cancelledWaiterCompleted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(cancelledWaiterResult.load(ordering: .acquiring), 1)

        let replacement = Task {
            let value = await broker.next()
            replacementResult.store(value == publication ? 1 : 2, ordering: .releasing)
            replacementCompleted.signal()
        }
        let replacementStatus = replacementCompleted.wait(timeout: .now() + 1)
        XCTAssertEqual(replacementStatus, .success)
        XCTAssertEqual(replacementResult.load(ordering: .acquiring), 1)
        if replacementStatus != .success { replacement.cancel() }
        broker.finish()
    }

    func testConcurrentBeginReservesCaptureBeforeLibraryLookupSuspends() async throws {
        try await withAdapterRaceLibrary { root, firstRequest in
            let secondRequest = try makeAdapterRaceRequest(
                libraryScope: firstRequest.libraryScope,
                suffix: "4ABC"
            )
            let roots = AdapterRaceSuspendingFirstRoot(root: root)
            let firstSource = try AdapterRaceInputSource()
            let secondSource = try AdapterRaceInputSource()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: roots,
                sources: AdapterRaceQueuedInputFactory(sources: [firstSource, secondSource])
            )

            let first = Task { await adapter.begin(firstRequest) }
            await roots.waitUntilFirstLookupSuspends()

            let second = await adapter.begin(secondRequest)
            guard case let .rejected(failure) = second else {
                await roots.resumeFirstLookup()
                await firstSource.finishFeed()
                await secondSource.finishFeed()
                _ = await first.value
                return XCTFail("a concurrent begin bypassed the in-flight reservation")
            }
            XCTAssertEqual(failure, .anotherLibraryActivity)
            let lookupCount = await roots.lookupCount
            XCTAssertEqual(lookupCount, 1)

            await roots.resumeFirstLookup()
            guard case let .started(feed) = await first.value else {
                return XCTFail("the reserved begin did not start")
            }
            _ = await adapter.apply(.discardConfirmed, to: firstRequest.recordingID)
            await drainAdapterRaceFeed(feed)
        }
    }

    func testDelayedSourceStartSharesOneOriginWithGapDisplayMuteAndStop() async throws {
        try await withAdapterRaceLibrary { root, request in
            let source = try AdapterRaceInputSource(
                holdStartAfterOrigin: true,
                bufferEventsUntilReleased: true
            )
            let clock = AdapterRaceClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: AdapterRaceFixedRoot(root: root),
                sources: AdapterRaceQueuedInputFactory(sources: [source]),
                monotonicClock: clock
            )

            let pendingBegin = Task { await adapter.begin(request) }
            await source.waitUntilStartIsHeld()
            await clock.advance(toElapsedSeconds: 2)
            await source.emit(
                .captureGap(
                    sampleRateHz: 16_000,
                    startSampleFrame: 0,
                    frameCount: CanonicalRecordingLimits.sampleRate,
                    channelCount: 1
                )
            )
            await source.releaseHeldStart()
            guard case let .started(feed) = await pendingBegin.value else {
                return XCTFail("capture did not start after the synthetic source delay")
            }

            var observations = feed.observations.makeAsyncIterator()
            let initialProgress = await observations.next()
            XCTAssertEqual(
                initialProgress,
                .progress(
                    frameCount: 2 * CanonicalRecordingLimits.sampleRate,
                    level: .unavailable(.stale)
                )
            )

            await source.releaseBufferedEvents()
            let firstGapProgress = await observations.next()
            XCTAssertEqual(
                firstGapProgress,
                .progress(
                    frameCount: 2 * CanonicalRecordingLimits.sampleRate,
                    level: .unavailable(.captureGap)
                )
            )

            let muteOutcome = await adapter.apply(
                .setMuted(true),
                to: request.recordingID
            )
            XCTAssertEqual(muteOutcome, .accepted)
            let muteBoundaryProgress = await observations.next()
            XCTAssertEqual(
                muteBoundaryProgress,
                .progress(
                    frameCount: 2 * CanonicalRecordingLimits.sampleRate,
                    level: .unavailable(.captureGap)
                )
            )
            let muteAcknowledgement = await observations.next()
            XCTAssertEqual(
                muteAcknowledgement,
                .muteChanged(
                    isMuted: true,
                    effectiveFrame: 2 * CanonicalRecordingLimits.sampleRate
                )
            )

            await clock.advance(toElapsedSeconds: 3)
            let stopOutcome = await adapter.apply(.stop, to: request.recordingID)
            XCTAssertEqual(stopOutcome, .accepted)
            var tail: [CaptureObservation] = []
            while let observation = await observations.next() {
                tail.append(observation)
            }
            XCTAssertTrue(tail.contains { observation in
                observation == .progress(
                    frameCount: 3 * CanonicalRecordingLimits.sampleRate,
                    level: .unavailable(.muted)
                )
            })
            XCTAssertTrue(tail.contains { observation in
                guard case let .sealCandidate(candidate) = observation else { return false }
                return candidate.frameCount == 3 * CanonicalRecordingLimits.sampleRate &&
                    candidate.terminalReason == CaptureTerminalReason.userStop.rawValue
            })
        }
    }

    func testDurationCeilingIsScheduledFromSourceDeclaredOrigin() async throws {
        try await withAdapterRaceLibrary { root, request in
            let source = try AdapterRaceInputSource(holdStartAfterOrigin: true)
            let clock = AdapterRaceClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: AdapterRaceFixedRoot(root: root),
                sources: AdapterRaceQueuedInputFactory(sources: [source]),
                monotonicClock: clock
            )

            let pendingBegin = Task { await adapter.begin(request) }
            await source.waitUntilStartIsHeld()
            await clock.advance(toElapsedSeconds: 2)
            await source.releaseHeldStart()
            guard case let .started(feed) = await pendingBegin.value else {
                return XCTFail("capture did not start after the synthetic source delay")
            }
            await clock.waitUntilSleeperIsRegistered()
            let firstDeadline = await clock.earliestRegisteredDeadline()
            XCTAssertEqual(
                firstDeadline,
                UInt64(40 * 60) * 1_000_000_000
            )

            await clock.advance(toElapsedSeconds: 45 * 60)
            let stoppedAtDeclaredCeiling = await source.waitUntilStopped()
            XCTAssertTrue(stoppedAtDeclaredCeiling)
            if !stoppedAtDeclaredCeiling {
                // Allow a pre-fix worker anchored after `start` returned to
                // terminate, so this regression always cleans up its tasks.
                await clock.advance(toElapsedSeconds: 45 * 60 + 2)
                _ = await source.waitUntilStopped()
            }

            let observations = await drainAdapterRaceFeed(feed)
            XCTAssertTrue(observations.contains { observation in
                guard case let .sealCandidate(candidate) = observation else { return false }
                return candidate.frameCount == CanonicalRecordingLimits.maximumFrames &&
                    candidate.terminalReason == CaptureTerminalReason.durationLimit.rawValue
            })
        }
    }

    func testSourceReturningAtDurationCeilingStopsBeforeBeginReturns() async throws {
        try await withAdapterRaceLibrary { root, request in
            let source = try AdapterRaceInputSource(holdStartAfterOrigin: true)
            let clock = AdapterRaceClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: AdapterRaceFixedRoot(root: root),
                sources: AdapterRaceQueuedInputFactory(sources: [source]),
                monotonicClock: clock
            )

            let pendingBegin = Task { await adapter.begin(request) }
            await source.waitUntilStartIsHeld()
            await clock.advance(toElapsedSeconds: 45 * 60)
            await source.releaseHeldStart()
            guard case let .started(feed) = await pendingBegin.value else {
                return XCTFail("capture did not expose its duration-limit result")
            }
            let stopCount = await source.stopCount
            XCTAssertEqual(stopCount, 1)

            let observations = await drainAdapterRaceFeed(feed)
            XCTAssertTrue(observations.contains { observation in
                guard case let .sealCandidate(candidate) = observation else { return false }
                return candidate.frameCount == CanonicalRecordingLimits.maximumFrames &&
                    candidate.terminalReason == CaptureTerminalReason.durationLimit.rawValue
            })
        }
    }

    func testPreOriginAuthorizationDelayDoesNotEnterCaptureTimeline() async throws {
        try await withAdapterRaceLibrary { root, request in
            let source = try AdapterRaceInputSource(holdStartBeforeOrigin: true)
            let clock = AdapterRaceClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: AdapterRaceFixedRoot(root: root),
                sources: AdapterRaceQueuedInputFactory(sources: [source]),
                monotonicClock: clock
            )

            let pendingBegin = Task { await adapter.begin(request) }
            await source.waitUntilStartIsHeldBeforeOrigin()
            await clock.advance(toElapsedSeconds: 2)
            await source.releaseStartHeldBeforeOrigin()
            guard case let .started(feed) = await pendingBegin.value else {
                return XCTFail("capture did not start after authorization/prepare delay")
            }

            var observations = feed.observations.makeAsyncIterator()
            let initialProgress = await observations.next()
            XCTAssertEqual(
                initialProgress,
                .progress(frameCount: 0, level: .unavailable(.stale))
            )
            await clock.waitUntilSleeperIsRegistered()
            let firstDeadline = await clock.earliestRegisteredDeadline()
            XCTAssertEqual(
                firstDeadline,
                UInt64(2 + 40 * 60) * 1_000_000_000
            )

            await clock.advance(toElapsedSeconds: 3)
            let stopOutcome = await adapter.apply(.stop, to: request.recordingID)
            XCTAssertEqual(stopOutcome, .accepted)
            var tail: [CaptureObservation] = []
            while let observation = await observations.next() {
                tail.append(observation)
            }
            XCTAssertTrue(tail.contains { observation in
                guard case let .sealCandidate(candidate) = observation else { return false }
                return candidate.frameCount == CanonicalRecordingLimits.sampleRate &&
                    candidate.terminalReason == CaptureTerminalReason.userStop.rawValue
            })
        }
    }

    func testMuteCommandRevalidatesGenerationAfterClockSuspension() async throws {
        try await withAdapterRaceLibrary { root, firstRequest in
            let secondRequest = try makeAdapterRaceRequest(
                libraryScope: firstRequest.libraryScope,
                suffix: "4BCD"
            )
            let firstSource = try AdapterRaceInputSource()
            let secondSource = try AdapterRaceInputSource()
            let clock = AdapterRaceClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: AdapterRaceFixedRoot(root: root),
                sources: AdapterRaceQueuedInputFactory(sources: [firstSource, secondSource]),
                monotonicClock: clock
            )
            guard case let .started(firstFeed) = await adapter.begin(firstRequest) else {
                return XCTFail("first capture did not start")
            }
            await clock.suspendNextNow()
            let pendingMute = Task {
                await adapter.apply(.setMuted(true), to: firstRequest.recordingID)
            }
            await clock.waitUntilNowSuspends()

            _ = await adapter.apply(.discardConfirmed, to: firstRequest.recordingID)
            await drainAdapterRaceFeed(firstFeed)
            guard case let .started(secondFeed) = await adapter.begin(secondRequest) else {
                await clock.resumeNow()
                return XCTFail("replacement capture did not start")
            }

            await clock.resumeNow()
            let muteOutcome = await pendingMute.value
            let firstMuteCommands = await firstSource.muteCommands
            let secondMuteCommands = await secondSource.muteCommands
            XCTAssertEqual(muteOutcome, .rejected(.staleCommand))
            XCTAssertEqual(firstMuteCommands, [])
            XCTAssertEqual(secondMuteCommands, [])

            _ = await adapter.apply(.discardConfirmed, to: secondRequest.recordingID)
            await drainAdapterRaceFeed(secondFeed)
        }
    }

    func testDurationLimitWinsWhenUserStopClockReadResumesLate() async throws {
        try await withAdapterRaceLibrary { root, request in
            let source = try AdapterRaceInputSource(stopBehavior: .leaveOpen)
            let clock = AdapterRaceClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: AdapterRaceFixedRoot(root: root),
                sources: AdapterRaceQueuedInputFactory(sources: [source]),
                monotonicClock: clock
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            await clock.waitUntilSleeperIsRegistered()
            await clock.suspendNextNow()
            let pendingStop = Task {
                await adapter.apply(.stop, to: request.recordingID)
            }
            await clock.waitUntilNowSuspends()

            await clock.advance(toElapsedSeconds: 45 * 60)
            let sourceStopped = await source.waitUntilStopped()
            XCTAssertTrue(sourceStopped)
            await clock.resumeNow()
            let stopOutcome = await pendingStop.value
            XCTAssertEqual(stopOutcome, .accepted)
            await source.finishFeed()

            let observations = await drainAdapterRaceFeed(feed)
            let candidates = observations.compactMap { observation -> StagedRecordingSealCandidate? in
                guard case let .sealCandidate(candidate) = observation else { return nil }
                return candidate
            }
            XCTAssertEqual(candidates.count, 1)
            XCTAssertEqual(candidates.first?.terminalReason, CaptureTerminalReason.durationLimit.rawValue)
            XCTAssertEqual(candidates.first?.frameCount, CanonicalRecordingLimits.maximumFrames)
        }
    }

    func testStopIsIdempotentlyAcceptedAfterDurationSealReservation() async throws {
        try await withAdapterRaceLibrary { root, request in
            let source = try AdapterRaceInputSource(stopBehavior: .holdThenFinish)
            let clock = AdapterRaceClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: AdapterRaceFixedRoot(root: root),
                sources: AdapterRaceQueuedInputFactory(sources: [source]),
                monotonicClock: clock
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            await clock.waitUntilSleeperIsRegistered()
            await clock.advance(toElapsedSeconds: 45 * 60)
            let sourceStopped = await source.waitUntilStopped()
            XCTAssertTrue(sourceStopped)

            let firstStop = await adapter.apply(.stop, to: request.recordingID)
            let repeatedStop = await adapter.apply(.stop, to: request.recordingID)
            let mute = await adapter.apply(.setMuted(true), to: request.recordingID)
            let discard = await adapter.apply(.discardConfirmed, to: request.recordingID)
            XCTAssertEqual(firstStop, .accepted)
            XCTAssertEqual(repeatedStop, .accepted)
            XCTAssertEqual(mute, .rejected(.staleCommand))
            XCTAssertEqual(discard, .rejected(.staleCommand))

            await source.releaseHeldStop()
            let observations = await drainAdapterRaceFeed(feed)
            XCTAssertTrue(observations.contains { observation in
                guard case let .sealCandidate(candidate) = observation else { return false }
                return candidate.terminalReason == CaptureTerminalReason.durationLimit.rawValue
            })
            let stopCount = await source.stopCount
            XCTAssertEqual(stopCount, 1)
        }
    }

    func testUserStopAtDurationBoundaryCannotBeatHeldDeadlineDelivery() async throws {
        try await withAdapterRaceLibrary { root, request in
            let source = try AdapterRaceInputSource()
            let clock = AdapterRaceClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: AdapterRaceFixedRoot(root: root),
                sources: AdapterRaceQueuedInputFactory(sources: [source]),
                monotonicClock: clock
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            await clock.waitUntilSleeperIsRegistered()
            await clock.setNowWithoutWakingSleepers(toElapsedSeconds: 45 * 60)

            let stopOutcome = await adapter.apply(.stop, to: request.recordingID)
            XCTAssertEqual(stopOutcome, .accepted)
            let observations = await drainAdapterRaceFeed(feed)
            await clock.releaseAllSleepers()

            let candidates = observations.compactMap { observation -> StagedRecordingSealCandidate? in
                guard case let .sealCandidate(candidate) = observation else { return nil }
                return candidate
            }
            XCTAssertEqual(candidates.count, 1)
            XCTAssertEqual(
                candidates.first?.terminalReason,
                CaptureTerminalReason.durationLimit.rawValue
            )
            XCTAssertEqual(
                candidates.first?.frameCount,
                CanonicalRecordingLimits.maximumFrames
            )
        }
    }

    func testPausedObservationConsumerKeepsMuteAcknowledgementAcrossProgressFlood() async throws {
        try await withAdapterRaceLibrary { root, request in
            let source = try AdapterRaceInputSource()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: AdapterRaceFixedRoot(root: root),
                sources: AdapterRaceQueuedInputFactory(sources: [source])
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }

            let muteOutcome = await adapter.apply(.setMuted(true), to: request.recordingID)
            XCTAssertEqual(muteOutcome, .accepted)
            let mutedEpoch = MicrophoneMuteEpoch(sequence: 1, isMuted: true)
            for frame in 0..<80 {
                await source.emit(
                    .mutedInterval(
                        sampleRateHz: 16_000,
                        startSampleFrame: UInt64(frame),
                        frameCount: 1,
                        channelCount: 1,
                        muteEpoch: mutedEpoch
                    )
                )
            }
            let stopOutcome = await adapter.apply(.stop, to: request.recordingID)
            XCTAssertEqual(stopOutcome, .accepted)

            // Deliberately start consuming only after the source has drained.
            // Progress may coalesce, but the control acknowledgement is
            // authoritative for leaving the UI's `.changing` mute state.
            while await adapter.inspectRecovery(in: request.libraryScope).inspectionStatus ==
                .blocked(.stagingListingUnavailable)
            {
                await Task.yield()
            }
            let observations = await drainAdapterRaceFeed(feed)
            XCTAssertTrue(observations.contains { observation in
                observation == .muteChanged(isMuted: true, effectiveFrame: 0)
            })
            XCTAssertTrue(observations.contains { observation in
                guard case let .sealCandidate(candidate) = observation else { return false }
                return candidate.frameCount == 80
            })
        }
    }

    func testSourceFailureUpgradesPendingSealAndMaterializesRecoveryBoundary() async throws {
        try await withAdapterRaceLibrary { root, request in
            let source = try AdapterRaceInputSource(stopBehavior: .interruptThenFinish)
            let clock = AdapterRaceClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: AdapterRaceFixedRoot(root: root),
                sources: AdapterRaceQueuedInputFactory(sources: [source]),
                monotonicClock: clock
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            await clock.advance(toElapsedSeconds: 2)
            let stopOutcome = await adapter.apply(.stop, to: request.recordingID)
            XCTAssertEqual(stopOutcome, .accepted)

            let observations = await drainAdapterRaceFeed(feed)
            XCTAssertFalse(observations.contains { observation in
                if case .sealCandidate = observation { return true }
                return false
            })
            guard let recovery = observations.compactMap({ observation -> RecordingRecoveryItem? in
                guard case let .recoveryRequired(item) = observation else { return nil }
                return item
            }).first else {
                return XCTFail("source failure did not expose recovery")
            }
            XCTAssertEqual(recovery.durableFrameCount, 2 * CanonicalRecordingLimits.sampleRate)
            XCTAssertEqual(recovery.availability, .sealOrDiscard)

            guard case let .sealCandidate(candidate) = await adapter.resolveRecovery(
                .seal,
                recordingID: request.recordingID,
                in: request.libraryScope
            ) else {
                return XCTFail("recovery did not preserve a sealable candidate")
            }
            XCTAssertEqual(
                candidate.unavailableIntervals,
                [
                    StagedUnavailableInterval(
                        startFrame: 0,
                        endFrame: 2 * CanonicalRecordingLimits.sampleRate,
                        reasons: [UnavailableReason.captureGap.rawValue]
                    ),
                ]
            )
        }
    }

    func testUnexpectedEOFFlushesAssemblerTailAndMaterializesElapsedGap() async throws {
        try await withAdapterRaceLibrary { root, request in
            let source = try AdapterRaceInputSource(
                format: try MicrophoneInputFormat(sampleRateHz: 44_100, channelCount: 1)
            )
            let clock = AdapterRaceClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: AdapterRaceFixedRoot(root: root),
                sources: AdapterRaceQueuedInputFactory(sources: [source]),
                monotonicClock: clock
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            await source.emit(
                .chunk(
                    try MicrophoneInputChunk(
                        sampleRateHz: 44_100,
                        startSampleFrame: 0,
                        channels: [Array(repeating: 0.25, count: 441)]
                    )
                )
            )
            await clock.advance(toElapsedSeconds: 1)
            await source.finishFeed()

            let observations = await drainAdapterRaceFeed(feed)
            guard let recovery = observations.compactMap({ observation -> RecordingRecoveryItem? in
                guard case let .recoveryRequired(item) = observation else { return nil }
                return item
            }).first else {
                return XCTFail("unexpected EOF did not expose recovery")
            }
            XCTAssertEqual(recovery.durableFrameCount, CanonicalRecordingLimits.sampleRate)

            guard case let .sealCandidate(candidate) = await adapter.resolveRecovery(
                .seal,
                recordingID: request.recordingID,
                in: request.libraryScope
            ) else {
                return XCTFail("unexpected EOF recovery was not sealable")
            }
            XCTAssertEqual(candidate.frameCount, CanonicalRecordingLimits.sampleRate)
            XCTAssertEqual(candidate.unavailableIntervals.last?.endFrame, CanonicalRecordingLimits.sampleRate)
            XCTAssertGreaterThan(candidate.unavailableIntervals.last?.startFrame ?? 0, 0)
            XCTAssertEqual(
                candidate.unavailableIntervals.last?.reasons,
                [UnavailableReason.captureGap.rawValue]
            )
        }
    }

    func testUnexpectedEOFReservesRecoveryBeforeItsClockBoundaryResumes() async throws {
        try await withAdapterRaceLibrary { root, request in
            let source = try AdapterRaceInputSource()
            let clock = AdapterRaceClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: AdapterRaceFixedRoot(root: root),
                sources: AdapterRaceQueuedInputFactory(sources: [source]),
                monotonicClock: clock
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }

            await clock.suspendNextNow()
            await source.finishFeed()
            await clock.waitUntilNowSuspends()
            await clock.advance(toElapsedSeconds: 3)

            let stopOutcome = await adapter.apply(.stop, to: request.recordingID)
            XCTAssertEqual(stopOutcome, .rejected(.staleCommand))
            await clock.resumeNow()

            let observations = await drainAdapterRaceFeed(feed)
            XCTAssertFalse(observations.contains { observation in
                if case .sealCandidate = observation { return true }
                return false
            })
            let recovery = observations.compactMap { observation -> RecordingRecoveryItem? in
                guard case let .recoveryRequired(item) = observation else { return nil }
                return item
            }.first
            XCTAssertEqual(
                recovery?.durableFrameCount,
                3 * CanonicalRecordingLimits.sampleRate
            )
            XCTAssertEqual(recovery?.availability, .sealOrDiscard)
        }
    }

    func testUnexpectedEOFMaterializesAcknowledgedMutedElapsedTime() async throws {
        try await withAdapterRaceLibrary { root, request in
            let source = try AdapterRaceInputSource()
            let clock = AdapterRaceClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: AdapterRaceFixedRoot(root: root),
                sources: AdapterRaceQueuedInputFactory(sources: [source]),
                monotonicClock: clock
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            await clock.advance(toElapsedSeconds: 1)
            let muteOutcome = await adapter.apply(.setMuted(true), to: request.recordingID)
            XCTAssertEqual(muteOutcome, .accepted)
            await clock.advance(toElapsedSeconds: 2)
            await source.finishFeed()
            _ = await drainAdapterRaceFeed(feed)

            guard case let .sealCandidate(candidate) = await adapter.resolveRecovery(
                .seal,
                recordingID: request.recordingID,
                in: request.libraryScope
            ) else {
                return XCTFail("muted EOF recovery was not sealable")
            }
            XCTAssertEqual(
                candidate.unavailableIntervals,
                [
                    StagedUnavailableInterval(
                        startFrame: 0,
                        endFrame: CanonicalRecordingLimits.sampleRate,
                        reasons: [UnavailableReason.captureGap.rawValue]
                    ),
                    StagedUnavailableInterval(
                        startFrame: CanonicalRecordingLimits.sampleRate,
                        endFrame: 2 * CanonicalRecordingLimits.sampleRate,
                        reasons: [
                            UnavailableReason.captureGap.rawValue,
                            UnavailableReason.muted.rawValue,
                        ]
                    ),
                ]
            )
        }
    }

    func testPersistenceFailureRecoveryRemainsAtDurableWatermark() async throws {
        try await withAdapterRaceLibrary { root, request in
            let source = try AdapterRaceInputSource()
            let clock = AdapterRaceClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: AdapterRaceFixedRoot(root: root),
                sources: AdapterRaceQueuedInputFactory(sources: [source]),
                monotonicClock: clock,
                persistenceFault: { point in
                    if point == .afterWatermarkFlush {
                        throw RecordingPersistenceError.injectedFault(point)
                    }
                }
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            await clock.advance(toElapsedSeconds: 2)
            await source.emit(
                .chunk(
                    try MicrophoneInputChunk(
                        sampleRateHz: 16_000,
                        startSampleFrame: 0,
                        channels: [[0.1, 0.2, 0.3, 0.4]]
                    )
                )
            )

            let observations = await drainAdapterRaceFeed(feed)
            let recovery = observations.compactMap { observation -> RecordingRecoveryItem? in
                guard case let .recoveryRequired(item) = observation else { return nil }
                return item
            }.first
            XCTAssertEqual(recovery?.durableFrameCount, 4)
            XCTAssertEqual(recovery?.availability, .sealOrDiscard)
        }
    }

    func testPersistenceFailureWhileDrainingStopUpgradesSealToDurableOnlyRecovery() async throws {
        try await withAdapterRaceLibrary { root, request in
            let finalChunk = MicrophoneInputEvent.chunk(
                try MicrophoneInputChunk(
                    sampleRateHz: 16_000,
                    startSampleFrame: 0,
                    channels: [[0.1, 0.2, 0.3, 0.4]]
                )
            )
            let source = try AdapterRaceInputSource(
                stopBehavior: .eventThenFinish(finalChunk)
            )
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: AdapterRaceFixedRoot(root: root),
                sources: AdapterRaceQueuedInputFactory(sources: [source]),
                persistenceFault: { point in
                    if point == .afterWatermarkFlush {
                        throw RecordingPersistenceError.injectedFault(point)
                    }
                }
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            let stopOutcome = await adapter.apply(.stop, to: request.recordingID)
            XCTAssertEqual(stopOutcome, .accepted)

            let observations = await drainAdapterRaceFeed(feed)
            XCTAssertFalse(observations.contains { observation in
                if case .sealCandidate = observation { return true }
                return false
            })
            let recovery = observations.compactMap { observation -> RecordingRecoveryItem? in
                guard case let .recoveryRequired(item) = observation else { return nil }
                return item
            }.first
            XCTAssertEqual(recovery?.durableFrameCount, 4)
            XCTAssertEqual(recovery?.availability, .sealOrDiscard)
        }
    }

    func testAssemblerFailureRecoveryDoesNotInventElapsedFrames() async throws {
        try await withAdapterRaceLibrary { root, request in
            let source = try AdapterRaceInputSource()
            let clock = AdapterRaceClock()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: AdapterRaceFixedRoot(root: root),
                sources: AdapterRaceQueuedInputFactory(sources: [source]),
                monotonicClock: clock
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            await clock.advance(toElapsedSeconds: 2)
            await source.emit(
                .chunk(
                    try MicrophoneInputChunk(
                        sampleRateHz: 48_000,
                        startSampleFrame: 0,
                        channels: [[0.1, 0.2, 0.3, 0.4]]
                    )
                )
            )

            let observations = await drainAdapterRaceFeed(feed)
            let recovery = observations.compactMap { observation -> RecordingRecoveryItem? in
                guard case let .recoveryRequired(item) = observation else { return nil }
                return item
            }.first
            XCTAssertEqual(recovery?.durableFrameCount, 0)
            XCTAssertEqual(recovery?.availability, .discardOnly)
        }
    }

    func testRecoveryInspectionRechecksCaptureGuardAfterRootLookup() async throws {
        try await withAdapterRaceLibrary { root, request in
            let roots = AdapterRaceSuspendingFirstRoot(root: root)
            let source = try AdapterRaceInputSource()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: roots,
                sources: AdapterRaceQueuedInputFactory(sources: [source])
            )

            let inspection = Task { await adapter.inspectRecovery(in: request.libraryScope) }
            await roots.waitUntilFirstLookupSuspends()
            guard case let .started(feed) = await adapter.begin(request) else {
                await roots.resumeFirstLookup()
                return XCTFail("capture did not start during suspended inspection")
            }
            await roots.resumeFirstLookup()
            let catalog = await inspection.value
            XCTAssertEqual(
                catalog.inspectionStatus,
                .blocked(.stagingListingUnavailable)
            )

            _ = await adapter.apply(.discardConfirmed, to: request.recordingID)
            await drainAdapterRaceFeed(feed)
        }
    }

    func testRecoveryResolutionRechecksCaptureGuardAfterRootLookup() async throws {
        try await withAdapterRaceLibrary { root, request in
            let roots = AdapterRaceSuspendingFirstRoot(root: root)
            let source = try AdapterRaceInputSource()
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: roots,
                sources: AdapterRaceQueuedInputFactory(sources: [source])
            )

            let resolution = Task {
                await adapter.resolveRecovery(
                    .seal,
                    recordingID: request.recordingID,
                    in: request.libraryScope
                )
            }
            await roots.waitUntilFirstLookupSuspends()
            guard case let .started(feed) = await adapter.begin(request) else {
                await roots.resumeFirstLookup()
                return XCTFail("capture did not start during suspended resolution")
            }
            await roots.resumeFirstLookup()
            let resolutionOutcome = await resolution.value
            XCTAssertEqual(resolutionOutcome, .failed(.libraryBecameReadOnly))

            _ = await adapter.apply(.discardConfirmed, to: request.recordingID)
            await drainAdapterRaceFeed(feed)
        }
    }

    func testDroppingAdapterTearsDownActiveCaptureWithoutClockAdvancement() async throws {
        try await withAdapterRaceLibrary { root, request in
            let source = try AdapterRaceInputSource()
            let clock = AdapterRaceClock()
            var adapter: AVFoundationAudioCaptureAdapter? = AVFoundationAudioCaptureAdapter(
                roots: AdapterRaceFixedRoot(root: root),
                sources: AdapterRaceQueuedInputFactory(sources: [source]),
                monotonicClock: clock
            )
            weak let weakAdapter = adapter
            guard case let .started(feed) = await adapter?.begin(request) else {
                return XCTFail("capture did not start")
            }
            await clock.waitUntilSleeperIsRegistered()

            adapter = nil
            for _ in 0..<1_000 where weakAdapter != nil { await Task.yield() }
            XCTAssertNil(weakAdapter)
            let sourceStopped = await source.waitUntilStopped()
            XCTAssertTrue(sourceStopped)
            let stopCount = await source.stopCount
            XCTAssertEqual(stopCount, 1)

            guard stopCount == 1 else {
                await clock.releaseAllSleepers()
                await source.finishFeed()
                return
            }
            let observations = await drainAdapterRaceFeed(feed)
            XCTAssertTrue(observations.contains { observation in
                guard case let .recoveryRequired(item) = observation else { return false }
                return item.recordingID == request.recordingID &&
                    item.availability == .discardOnly
            })
            await clock.releaseAllSleepers()
        }
    }

    func testFinalizationCancelsDeadlineWorkerWithoutClockAdvancement() async throws {
        try await withAdapterRaceLibrary { root, request in
            let source = try AdapterRaceInputSource()
            let clock = AdapterRaceClock()
            let deadlineWorkerFinished = DispatchSemaphore(value: 0)
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: AdapterRaceFixedRoot(root: root),
                sources: AdapterRaceQueuedInputFactory(sources: [source]),
                monotonicClock: clock,
                deadlineWorkerDidFinish: { deadlineWorkerFinished.signal() }
            )
            guard case let .started(feed) = await adapter.begin(request) else {
                return XCTFail("capture did not start")
            }
            await clock.waitUntilSleeperIsRegistered()

            let stop = await adapter.apply(.stop, to: request.recordingID)
            XCTAssertEqual(stop, .accepted)
            _ = await drainAdapterRaceFeed(feed)
            let completion = await waitForAdapterRaceSemaphore(deadlineWorkerFinished)
            await clock.releaseAllSleepers()
            XCTAssertEqual(completion, .success)
        }
    }
}

private actor AdapterRaceInputSource: MicrophoneInputSource {
    enum StopBehavior {
        case finish
        case leaveOpen
        case holdThenFinish
        case interruptThenFinish
        case eventThenFinish(MicrophoneInputEvent)
    }

    nonisolated let events: AsyncStream<MicrophoneInputEvent>
    nonisolated let format: MicrophoneInputFormat
    private let continuation: AsyncStream<MicrophoneInputEvent>.Continuation
    private let stopBehavior: StopBehavior
    private let holdStartBeforeOrigin: Bool
    private let holdStartAfterOrigin: Bool
    private var buffersEventsUntilReleased: Bool
    private var muteEpoch = MicrophoneMuteEpoch.initial
    private var effectiveInputFrame: UInt64 = 0
    private var bufferedEvents: [MicrophoneInputEvent] = []
    private(set) var stopCount = 0
    private(set) var muteCommands: [Bool] = []
    private var startBeforeOriginIsHeld = false
    private var heldStartBeforeOriginContinuation: CheckedContinuation<Void, Never>?
    private var startBeforeOriginWaiters: [CheckedContinuation<Void, Never>] = []
    private var startIsHeld = false
    private var heldStartContinuation: CheckedContinuation<Void, Never>?
    private var startHoldWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldStopContinuation: CheckedContinuation<Void, Never>?
    private var stopWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init(
        stopBehavior: StopBehavior = .finish,
        holdStartBeforeOrigin: Bool = false,
        holdStartAfterOrigin: Bool = false,
        bufferEventsUntilReleased: Bool = false,
        format: MicrophoneInputFormat? = nil
    ) throws {
        var stored: AsyncStream<MicrophoneInputEvent>.Continuation!
        events = AsyncStream { stored = $0 }
        continuation = stored
        self.stopBehavior = stopBehavior
        self.holdStartBeforeOrigin = holdStartBeforeOrigin
        self.holdStartAfterOrigin = holdStartAfterOrigin
        buffersEventsUntilReleased = bufferEventsUntilReleased
        if let format {
            self.format = format
        } else {
            self.format = try MicrophoneInputFormat(sampleRateHz: 16_000, channelCount: 1)
        }
    }

    func start(
        monotonicClock: any CaptureMonotonicClock
    ) async -> MicrophoneInputStartOutcome {
        if holdStartBeforeOrigin {
            startBeforeOriginIsHeld = true
            let waiters = startBeforeOriginWaiters
            startBeforeOriginWaiters.removeAll(keepingCapacity: false)
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { heldStartBeforeOriginContinuation = $0 }
            startBeforeOriginIsHeld = false
        }
        let captureStart = await monotonicClock.captureStart()
        if holdStartAfterOrigin {
            startIsHeld = true
            let waiters = startHoldWaiters
            startHoldWaiters.removeAll(keepingCapacity: false)
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { heldStartContinuation = $0 }
            startIsHeld = false
        }
        return .started(
            MicrophoneInputFeed(
                format: format,
                captureStartedAtMonotonicNanoseconds: captureStart.uptimeNanoseconds,
                events: events
            )
        )
    }

    func setMuted(_ muted: Bool) -> Bool {
        muteCommands.append(muted)
        guard muteEpoch.isMuted != muted else { return true }
        muteEpoch = MicrophoneMuteEpoch(sequence: muteEpoch.sequence + 1, isMuted: muted)
        continuation.yield(
            .muteChanged(epoch: muteEpoch, effectiveInputFrame: effectiveInputFrame)
        )
        return true
    }

    func stop() async {
        stopCount += 1
        let stoppedWaiters = stopWaiters.values
        stopWaiters.removeAll(keepingCapacity: false)
        stoppedWaiters.forEach { $0.resume(returning: true) }
        switch stopBehavior {
        case .finish:
            continuation.finish()
        case .leaveOpen:
            break
        case .holdThenFinish:
            await withCheckedContinuation { heldStopContinuation = $0 }
            continuation.finish()
        case .interruptThenFinish:
            continuation.yield(.interrupted)
            continuation.finish()
        case let .eventThenFinish(event):
            continuation.yield(event)
            continuation.finish()
        }
    }

    func emit(_ event: MicrophoneInputEvent) {
        switch event {
        case let .chunk(chunk):
            effectiveInputFrame = max(
                effectiveInputFrame,
                chunk.startSampleFrame + chunk.frameCount
            )
        case let .captureGap(_, start, count, _, _),
             let .mutedInterval(_, start, count, _, _):
            effectiveInputFrame = max(effectiveInputFrame, start + count)
        case .muteChanged, .interrupted, .clockBecameInvalid:
            break
        }
        if buffersEventsUntilReleased {
            bufferedEvents.append(event)
        } else {
            continuation.yield(event)
        }
    }

    func finishFeed() {
        continuation.finish()
    }

    func releaseBufferedEvents() {
        buffersEventsUntilReleased = false
        bufferedEvents.forEach { continuation.yield($0) }
        bufferedEvents.removeAll(keepingCapacity: false)
    }

    func waitUntilStartIsHeld() async {
        guard !startIsHeld else { return }
        await withCheckedContinuation { startHoldWaiters.append($0) }
    }

    func waitUntilStartIsHeldBeforeOrigin() async {
        guard !startBeforeOriginIsHeld else { return }
        await withCheckedContinuation { startBeforeOriginWaiters.append($0) }
    }

    func releaseStartHeldBeforeOrigin() {
        heldStartBeforeOriginContinuation?.resume()
        heldStartBeforeOriginContinuation = nil
    }

    func releaseHeldStart() {
        heldStartContinuation?.resume()
        heldStartContinuation = nil
    }

    func waitUntilStopped(timeoutNanoseconds: UInt64 = 1_000_000_000) async -> Bool {
        guard stopCount == 0 else { return true }
        let id = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if stopCount > 0 {
                    continuation.resume(returning: true)
                    return
                }
                stopWaiters[id] = continuation
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    await self?.expireStopWaiter(id)
                }
            }
        }, onCancel: {
            Task { await self.expireStopWaiter(id) }
        })
    }

    private func expireStopWaiter(_ id: UUID) {
        stopWaiters.removeValue(forKey: id)?.resume(returning: false)
    }

    func releaseHeldStop() {
        heldStopContinuation?.resume()
        heldStopContinuation = nil
    }
}

private actor AdapterRaceQueuedInputFactory: MicrophoneInputSourceFactory {
    private var sources: [AdapterRaceInputSource]

    init(sources: [AdapterRaceInputSource]) {
        self.sources = sources
    }

    func makeSource() -> any MicrophoneInputSource {
        precondition(!sources.isEmpty, "synthetic source queue exhausted")
        return sources.removeFirst()
    }
}

private struct AdapterRaceFixedRoot: RecordingLibraryRootProviding {
    let root: URL

    func recordingRoot(for scope: LibraryScope) async -> URL? { root }
}

private actor AdapterRaceSuspendingFirstRoot: RecordingLibraryRootProviding {
    private let root: URL
    private var firstLookupContinuation: CheckedContinuation<Void, Never>?
    private var firstLookupWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstLookupIsSuspended = false
    private(set) var lookupCount = 0

    init(root: URL) {
        self.root = root
    }

    func recordingRoot(for scope: LibraryScope) async -> URL? {
        lookupCount += 1
        guard lookupCount == 1 else { return root }
        firstLookupIsSuspended = true
        let waiters = firstLookupWaiters
        firstLookupWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { firstLookupContinuation = $0 }
        firstLookupIsSuspended = false
        return root
    }

    func waitUntilFirstLookupSuspends() async {
        guard !firstLookupIsSuspended else { return }
        await withCheckedContinuation { firstLookupWaiters.append($0) }
    }

    func resumeFirstLookup() {
        firstLookupContinuation?.resume()
        firstLookupContinuation = nil
    }
}

private actor AdapterRaceClock: CaptureMonotonicClock {
    private struct Sleeper {
        let id: UUID
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var nowNanoseconds: UInt64 = 0
    private var shouldSuspendNextNow = false
    private var nowContinuation: CheckedContinuation<Void, Never>?
    private var nowWaiters: [CheckedContinuation<Void, Never>] = []
    private var nowIsSuspended = false
    private var sleepers: [Sleeper] = []
    private var sleeperWaiters: [CheckedContinuation<Void, Never>] = []

    func now() async -> UInt64 {
        if shouldSuspendNextNow {
            shouldSuspendNextNow = false
            nowIsSuspended = true
            let waiters = nowWaiters
            nowWaiters.removeAll(keepingCapacity: false)
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { nowContinuation = $0 }
            nowIsSuspended = false
        }
        return nowNanoseconds
    }

    func sleep(until deadlineNanoseconds: UInt64) async throws {
        guard deadlineNanoseconds > nowNanoseconds else { return }
        let id = UUID()
        let waiters = sleeperWaiters
        sleeperWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
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
                            deadline: deadlineNanoseconds,
                            continuation: continuation
                        )
                    )
                }
            }
        }, onCancel: {
            Task { await self.cancelSleeper(id) }
        })
    }

    func suspendNextNow() {
        shouldSuspendNextNow = true
    }

    func waitUntilNowSuspends() async {
        guard !nowIsSuspended else { return }
        await withCheckedContinuation { nowWaiters.append($0) }
    }

    func resumeNow() {
        nowContinuation?.resume()
        nowContinuation = nil
    }

    func waitUntilSleeperIsRegistered() async {
        guard sleepers.isEmpty else { return }
        await withCheckedContinuation { sleeperWaiters.append($0) }
    }

    func earliestRegisteredDeadline() -> UInt64? {
        sleepers.map(\.deadline).min()
    }

    func advance(toElapsedSeconds seconds: UInt64) {
        nowNanoseconds = seconds * 1_000_000_000
        let ready = sleepers.filter { $0.deadline <= nowNanoseconds }
        sleepers.removeAll { $0.deadline <= nowNanoseconds }
        ready.forEach { $0.continuation.resume(returning: ()) }
    }

    func setNowWithoutWakingSleepers(toElapsedSeconds seconds: UInt64) {
        nowNanoseconds = seconds * 1_000_000_000
    }

    func releaseAllSleepers() {
        let waiting = sleepers
        sleepers.removeAll(keepingCapacity: false)
        waiting.forEach { $0.continuation.resume(throwing: CancellationError()) }
    }

    private func cancelSleeper(_ id: UUID) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        let sleeper = sleepers.remove(at: index)
        sleeper.continuation.resume(throwing: CancellationError())
    }
}

private func withAdapterRaceLibrary(
    _ body: (URL, MicrophoneRecordingRequest) async throws -> Void
) async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
        "audora-adapter-race-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("Synthetic.audoralibrary", isDirectory: true)
    let instant = try UTCInstant("2026-08-31T12:00:00.000Z")
    let libraryID = try LibraryID("lib-20260831T120000000Z-1ABC")
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
            recordingID: try RecordingID("rec-20260831T120000000Z-2ABC"),
            sessionID: try SessionID("ses-20260831T120000000Z-3ABC"),
            startedAt: instant
        )
    )
}

private func makeAdapterRaceRequest(
    libraryScope: LibraryScope,
    suffix: String
) throws -> MicrophoneRecordingRequest {
    MicrophoneRecordingRequest(
        libraryScope: libraryScope,
        recordingID: try RecordingID("rec-20260831T120000000Z-\(suffix)"),
        sessionID: try SessionID("ses-20260831T120000000Z-\(suffix)"),
        startedAt: try UTCInstant("2026-08-31T12:00:00.000Z")
    )
}

@discardableResult
private func drainAdapterRaceFeed(_ feed: ActiveCaptureFeed) async -> [CaptureObservation] {
    var observations: [CaptureObservation] = []
    for await observation in feed.observations {
        observations.append(observation)
    }
    return observations
}

private func waitForAdapterRaceSemaphore(
    _ semaphore: DispatchSemaphore
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 1))
        }
    }
}
