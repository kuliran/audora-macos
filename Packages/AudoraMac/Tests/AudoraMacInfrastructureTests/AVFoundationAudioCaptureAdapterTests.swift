import AudoraApplication
import AudoraDomain
@testable import AudoraMacInfrastructure
import AVFoundation
import Foundation
import XCTest

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
            let adapter = AVFoundationAudioCaptureAdapter(
                roots: FixedRecordingRoot(root: root),
                sources: FixedInputFactory(source: source)
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
            let interrupted = await observations.next()
            XCTAssertEqual(
                interrupted,
                .finishing(reason: .interruption, frameCount: 2)
            )
            guard case let .recoveryRequired(item) = await observations.next() else {
                return XCTFail("missing recovery item")
            }
            XCTAssertEqual(item.availability, .sealOrDiscard)
            XCTAssertEqual(item.recordingID, request.recordingID)
            let terminal = await observations.next()
            XCTAssertNil(terminal)

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
    private let continuation: AsyncStream<MicrophoneInputEvent>.Continuation
    private let configuredOutcome: ConfiguredOutcome
    private(set) var stopCount = 0

    enum ConfiguredOutcome {
        case started
        case permissionDenied
        case unavailable
    }

    init(startOutcome: ConfiguredOutcome = .started) {
        var stored: AsyncStream<MicrophoneInputEvent>.Continuation!
        events = AsyncStream { stored = $0 }
        continuation = stored
        configuredOutcome = startOutcome
    }

    func start() -> MicrophoneInputStartOutcome {
        switch configuredOutcome {
        case .started: .started(MicrophoneInputFeed(events: events))
        case .permissionDenied: .permissionDenied
        case .unavailable: .unavailable
        }
    }

    func stop() {
        stopCount += 1
        continuation.finish()
    }

    func emit(_ event: MicrophoneInputEvent) { continuation.yield(event) }
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
