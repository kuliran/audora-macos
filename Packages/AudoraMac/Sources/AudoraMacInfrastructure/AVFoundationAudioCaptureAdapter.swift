import AudoraApplication
import AudoraDomain
import Foundation

/// macOS capture boundary. The shipping composition injects the AVFoundation
/// source, while tests exercise this adapter only with synthetic input sources.
/// Physical devices and permission prompts remain explicit release qualification.
public actor AVFoundationAudioCaptureAdapter: AudioCapturePort {
    private enum TerminalIntent: Equatable {
        case seal(CaptureTerminalReason)
        case discard
        case recover
    }

    private struct ActiveCapture {
        let generation: UInt64
        let handle: RecordingStagingHandle
        let source: any MicrophoneInputSource
        let continuation: AsyncStream<CaptureObservation>.Continuation
        var assembler: CanonicalPCMAssembler
        var acknowledgedMuteEpoch: MicrophoneMuteEpoch
        var terminalIntent: TerminalIntent?
        var finalizing: Bool
    }

    private let roots: any RecordingLibraryRootProviding
    private let sources: any MicrophoneInputSourceFactory
    private let persistence: RecordingPersistence
    private let monotonicClock: any CaptureMonotonicClock
    private var active: ActiveCapture?
    private var feedTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var nextGeneration: UInt64 = 1

    public init(
        roots: any RecordingLibraryRootProviding,
        sources: any MicrophoneInputSourceFactory,
        monotonicClock: any CaptureMonotonicClock = SystemCaptureMonotonicClock(),
        persistenceFault: @escaping @Sendable (RecordingPersistenceFaultPoint) throws -> Void = { _ in }
    ) {
        self.roots = roots
        self.sources = sources
        self.monotonicClock = monotonicClock
        persistence = RecordingPersistence(fault: persistenceFault)
    }

    public func begin(_ request: MicrophoneRecordingRequest) async -> CaptureStartOutcome {
        guard active == nil else { return .rejected(.anotherLibraryActivity) }
        guard let root = await roots.recordingRoot(for: request.libraryScope) else {
            return .rejected(.libraryBecameReadOnly)
        }
        let handle: RecordingStagingHandle
        do {
            handle = try persistence.prepare(request, under: root)
        } catch {
            return .rejected(map(error))
        }
        let source = await sources.makeSource()
        let inputOutcome = await source.start()
        let inputFeed: MicrophoneInputFeed
        switch inputOutcome {
        case let .started(feed):
            inputFeed = feed
        case .permissionDenied:
            try? persistence.discard(handle)
            return .rejected(.microphonePermissionDenied)
        case .unavailable:
            try? persistence.discard(handle)
            return .rejected(.microphoneUnavailable)
        }

        let generation = nextGeneration
        nextGeneration &+= 1
        // State observations are projections, not the durable audio stream.
        // Keep the newest bounded window; terminal observations are emitted
        // after capture has stopped, so they displace stale progress if needed.
        let stream = AsyncStream<CaptureObservation>(
            bufferingPolicy: .bufferingNewest(64)
        ) { continuation in
            active = ActiveCapture(
                generation: generation,
                handle: handle,
                source: source,
                continuation: continuation,
                assembler: CanonicalPCMAssembler(),
                acknowledgedMuteEpoch: .initial,
                terminalIntent: nil,
                finalizing: false
            )
        }
        guard active?.generation == generation else {
            await source.stop()
            try? persistence.markRecoverable(handle, availability: .discardOnly)
            return .rejected(.stagingWriteFailedRecoverable)
        }
        active?.continuation.yield(
            .progress(frameCount: 0, level: .unavailable(.stale))
        )
        let captureStartedAt = await monotonicClock.now()
        deadlineTask = Task { [weak self] in
            for seconds in [UInt64(40 * 60), UInt64(44 * 60), UInt64(45 * 60)] {
                let (deadline, overflow) = captureStartedAt.addingReportingOverflow(
                    seconds * 1_000_000_000
                )
                guard !overflow else { return }
                await self?.monotonicClock.sleep(until: deadline)
                guard !Task.isCancelled else { return }
                await self?.deadlineReached(
                    generation: generation,
                    targetFrame: seconds * CanonicalRecordingLimits.sampleRate
                )
            }
        }
        feedTask = Task { [weak self] in
            for await event in inputFeed.events {
                guard !Task.isCancelled else { break }
                await self?.consume(event, generation: generation)
            }
            await self?.inputEnded(generation: generation)
        }
        return .started(
            ActiveCaptureFeed(recordingID: request.recordingID, observations: stream)
        )
    }

    public func apply(
        _ command: ActiveCaptureCommand,
        to recordingID: RecordingID
    ) async -> CaptureCommandOutcome {
        guard let current = active,
              current.handle.request.recordingID == recordingID,
              current.terminalIntent == nil,
              !current.finalizing
        else {
            return .rejected(.staleCommand)
        }
        switch command {
        case let .setMuted(muted):
            return await current.source.setMuted(muted)
                ? .accepted
                : .rejected(.stagingWriteFailedRecoverable)

        case .stop:
            active?.terminalIntent = .seal(.userStop)
            // `stop` is a quiesce-and-drain operation. The source must detach
            // callbacks and finish its feed only after every accepted event has
            // entered the bounded stream. `inputEnded` owns sealing.
            await current.source.stop()
            return .accepted

        case .discardConfirmed:
            active?.terminalIntent = .discard
            await current.source.stop()
            return .accepted
        }
    }

    public func completeSeal(
        _ command: RecordingPublicationCommand
    ) async -> RecordingPublicationOutcome {
        let request: MicrophoneRecordingRequest
        switch command {
        case let .publish(publication):
            guard let recordingID = try? RecordingID(publication.candidate.recordingID),
                  let libraryID = try? LibraryID(publication.candidate.libraryID),
                  let startedAt = try? UTCInstant(publication.candidate.startedAt)
            else {
                return .failed(.sealValidationFailedRecoverable)
            }
            request = MicrophoneRecordingRequest(
                libraryScope: LibraryScope(libraryID: libraryID),
                recordingID: recordingID,
                sessionID: publication.session.sessionID,
                startedAt: startedAt
            )
            guard let root = await roots.recordingRoot(for: request.libraryScope) else {
                return .failed(.libraryBecameReadOnly)
            }
            do {
                let handle = try persistence.openRecovery(
                    recordingID: request.recordingID,
                    in: request.libraryScope,
                    under: root
                )
                let receipt = try persistence.install(publication, using: handle)
                handle.closeCaptureStream()
                return .installed(receipt)
            } catch {
                return recoveryOutcome(for: request, root: root, error: error)
            }

        case let .preserveForRecovery(preservedRequest):
            request = preservedRequest
            guard let root = await roots.recordingRoot(for: request.libraryScope) else {
                return .failed(.libraryBecameReadOnly)
            }
            do {
                let handle = try persistence.openRecovery(
                    recordingID: request.recordingID,
                    in: request.libraryScope,
                    under: root
                )
                try persistence.markRecoverable(handle, availability: .sealOrDiscard)
                return .recoveryRequired(
                    RecordingRecoveryItem(
                        recordingID: request.recordingID,
                        sessionID: request.sessionID,
                        startedAt: request.startedAt,
                        durableFrameCount: handle.durableFrameCount,
                        availability: handle.durableFrameCount > 0
                            ? .sealOrDiscard
                            : .discardOnly
                    )
                )
            } catch {
                return recoveryOutcome(for: request, root: root, error: error)
            }
        }
    }

    public func inspectRecovery(in library: LibraryScope) async -> RecordingRecoveryCatalog {
        guard active == nil else {
            return RecordingRecoveryCatalog(
                items: [],
                inspectionStatus: .blocked(.stagingListingUnavailable)
            )
        }
        guard let root = await roots.recordingRoot(for: library) else {
            return RecordingRecoveryCatalog(
                items: [],
                inspectionStatus: .blocked(.libraryAuthorityUnavailable)
            )
        }
        return persistence.inspectRecovery(in: library, under: root)
    }

    public func resolveRecovery(
        _ action: RecordingRecoveryAction,
        recordingID: RecordingID,
        in library: LibraryScope
    ) async -> RecordingRecoveryOutcome {
        guard active == nil,
              let root = await roots.recordingRoot(for: library)
        else {
            return .failed(.libraryBecameReadOnly)
        }
        do {
            switch action {
            case .seal:
                let handle = try persistence.openRecovery(
                    recordingID: recordingID,
                    in: library,
                    under: root
                )
                let candidate = try persistence.stageSeal(handle, reason: .interruption)
                return .sealCandidate(candidate)
            case .discard:
                try persistence.discardRecovery(
                    recordingID: recordingID,
                    in: library,
                    under: root
                )
                return .discarded(recordingID: recordingID)
            }
        } catch {
            return .failed(map(error))
        }
    }

    private func consume(_ event: MicrophoneInputEvent, generation: UInt64) async {
        guard var current = active,
              current.generation == generation,
              !current.finalizing
        else { return }
        switch event {
        case let .chunk(chunk):
            if current.terminalIntent == .discard || current.terminalIntent == .recover {
                return
            }
            do {
                let spans = try current.assembler.consume(
                    chunk,
                    muted: chunk.muteEpoch.isMuted
                )
                active?.assembler = current.assembler
                for span in spans {
                    guard let live = active,
                          live.generation == generation,
                          !live.finalizing
                    else { return }
                    let remaining = CanonicalRecordingLimits.maximumFrames -
                        live.handle.durableFrameCount
                    guard remaining > 0 else {
                        if live.terminalIntent == nil {
                            active?.terminalIntent = .seal(.durationLimit)
                            await live.source.stop()
                        }
                        return
                    }
                    let bounded = try span.prefix(maximumFrames: remaining)
                    let frameCount = try persistence.append(bounded, to: live.handle)
                    let level: CaptureLevel
                    if bounded.reasons.contains(.muted) {
                        level = .unavailable(.muted)
                    } else if bounded.reasons.contains(.captureGap) {
                        level = .unavailable(.captureGap)
                    } else if let measured = bounded.level {
                        level = .measured(measured)
                    } else {
                        level = .unavailable(.stale)
                    }
                    live.continuation.yield(.progress(frameCount: frameCount, level: level))
                    if frameCount == CanonicalRecordingLimits.maximumFrames,
                       live.terminalIntent == nil
                    {
                        active?.terminalIntent = .seal(.durationLimit)
                        await live.source.stop()
                        return
                    }
                }
            } catch CanonicalPCMAssemblerError.unsupportedInputFormat {
                await requestRecovery(generation: generation)
            } catch {
                await requestRecovery(generation: generation)
            }

        case .interrupted:
            await requestRecovery(generation: generation)
        case .clockBecameInvalid:
            await requestRecovery(generation: generation)
        case let .captureGap(
            sampleRateHz,
            startSampleFrame,
            frameCount,
            channelCount,
            muteEpoch
        ):
            if current.terminalIntent == .discard || current.terminalIntent == .recover {
                return
            }
            do {
                let spans = try current.assembler.consumeGap(
                    sampleRateHz: sampleRateHz,
                    startSampleFrame: startSampleFrame,
                    frameCount: frameCount,
                    channelCount: channelCount,
                    muted: muteEpoch.isMuted
                )
                active?.assembler = current.assembler
                for span in spans {
                    guard let live = active,
                          live.generation == generation,
                          !live.finalizing
                    else { return }
                    let remaining = CanonicalRecordingLimits.maximumFrames -
                        live.handle.durableFrameCount
                    guard remaining > 0 else { return }
                    let bounded = try span.prefix(maximumFrames: remaining)
                    let frames = try persistence.append(bounded, to: live.handle)
                    live.continuation.yield(
                        .progress(
                            frameCount: frames,
                            level: .unavailable(
                                bounded.reasons.contains(.muted) ? .muted : .captureGap
                            )
                        )
                    )
                    if frames == CanonicalRecordingLimits.maximumFrames,
                       live.terminalIntent == nil
                    {
                        active?.terminalIntent = .seal(.durationLimit)
                        await live.source.stop()
                        return
                    }
                }
            } catch {
                await requestRecovery(generation: generation)
            }
        case let .muteChanged(epoch, _):
            current.acknowledgedMuteEpoch = epoch
            active = current
            current.continuation.yield(
                .muteChanged(
                    isMuted: epoch.isMuted,
                    effectiveFrame: current.handle.durableFrameCount
                )
            )
        }
    }

    private func deadlineReached(generation: UInt64, targetFrame: UInt64) async {
        guard var current = active,
              current.generation == generation,
              current.terminalIntent == nil,
              !current.finalizing
        else { return }
        do {
            let spans = try current.assembler.consumeTimedGap(
                throughCanonicalFrame: targetFrame,
                muted: current.acknowledgedMuteEpoch.isMuted
            )
            active?.assembler = current.assembler
            for span in spans {
                guard let live = active,
                      live.generation == generation,
                      !live.finalizing
                else { return }
                let bounded = try span.prefix(
                    maximumFrames: CanonicalRecordingLimits.maximumFrames -
                        live.handle.durableFrameCount
                )
                let frames = try persistence.append(bounded, to: live.handle)
                live.continuation.yield(
                    .progress(
                        frameCount: frames,
                        level: .unavailable(
                            bounded.reasons.contains(.muted) ? .muted : .captureGap
                        )
                    )
                )
            }
            if targetFrame >= CanonicalRecordingLimits.maximumFrames,
               let live = active,
               live.generation == generation,
               live.terminalIntent == nil
            {
                active?.terminalIntent = .seal(.durationLimit)
                await live.source.stop()
            }
        } catch {
            await requestRecovery(generation: generation)
        }
    }

    private func inputEnded(generation: UInt64) async {
        guard var current = active,
              current.generation == generation,
              !current.finalizing
        else { return }
        if case .seal = current.terminalIntent {
            do {
                try flushAssembler(&current)
            } catch {
                current.terminalIntent = .recover
            }
        }
        if current.terminalIntent == nil {
            current.terminalIntent = .recover
        }
        current.finalizing = true
        active = current
        feedTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil

        switch current.terminalIntent! {
        case let .seal(reason):
            await sealAfterDrain(current, reason: reason)
        case .discard:
            discardAfterDrain(current)
        case .recover:
            exposeRecoveryAfterDrain(current)
        }
    }

    private func flushAssembler(_ current: inout ActiveCapture) throws {
        let spans = try current.assembler.finish()
        active?.assembler = current.assembler
        for span in spans {
            let remaining = CanonicalRecordingLimits.maximumFrames -
                current.handle.durableFrameCount
            guard remaining > 0 else {
                current.terminalIntent = .seal(.durationLimit)
                return
            }
            let bounded = try span.prefix(maximumFrames: remaining)
            let frames = try persistence.append(bounded, to: current.handle)
            let level: CaptureLevel
            if bounded.reasons.contains(.muted) {
                level = .unavailable(.muted)
            } else if bounded.reasons.contains(.captureGap) {
                level = .unavailable(.captureGap)
            } else if let measured = bounded.level {
                level = .measured(measured)
            } else {
                level = .unavailable(.stale)
            }
            current.continuation.yield(.progress(frameCount: frames, level: level))
            if frames == CanonicalRecordingLimits.maximumFrames {
                current.terminalIntent = .seal(.durationLimit)
                return
            }
        }
    }

    private func sealAfterDrain(
        _ current: ActiveCapture,
        reason: CaptureTerminalReason
    ) async {
        let frames = current.handle.durableFrameCount
        current.continuation.yield(.finishing(reason: reason, frameCount: frames))
        current.continuation.yield(.sealing(reason: reason, frameCount: frames))
        do {
            let candidate = try persistence.stageSeal(current.handle, reason: reason)
            current.handle.closeCaptureStream()
            current.continuation.yield(.sealCandidate(candidate))
            current.continuation.finish()
            active = nil
        } catch {
            let availability = persistence.recoveryAvailability(for: current.handle)
            try? persistence.markRecoverable(
                current.handle,
                availability: availability
            )
            let item = RecordingRecoveryItem(
                recordingID: current.handle.request.recordingID,
                sessionID: current.handle.request.sessionID,
                startedAt: current.handle.request.startedAt,
                durableFrameCount: frames,
                availability: availability
            )
            current.continuation.yield(.recoveryRequired(item))
            current.continuation.finish()
            active = nil
        }
    }

    private func discardAfterDrain(_ current: ActiveCapture) {
        do {
            current.handle.closeCaptureStream()
            try persistence.discard(current.handle)
            current.continuation.yield(.discarded(recordingID: current.handle.request.recordingID))
            current.continuation.finish()
            active = nil
        } catch {
            try? persistence.markRecoverable(current.handle, availability: .discardOnly)
            let item = RecordingRecoveryItem(
                recordingID: current.handle.request.recordingID,
                sessionID: current.handle.request.sessionID,
                startedAt: current.handle.request.startedAt,
                durableFrameCount: current.handle.durableFrameCount,
                availability: .discardOnly
            )
            current.continuation.yield(.recoveryRequired(item))
            current.continuation.finish()
            active = nil
        }
    }

    private func requestRecovery(generation: UInt64) async {
        guard let current = active,
              current.generation == generation,
              current.terminalIntent == nil,
              !current.finalizing
        else { return }
        active?.terminalIntent = .recover
        await current.source.stop()
    }

    private func exposeRecoveryAfterDrain(_ current: ActiveCapture) {
        let frames = current.handle.durableFrameCount
        current.handle.closeCaptureStream()
        let availability: RecordingRecoveryAvailability = frames > 0 ? .sealOrDiscard : .discardOnly
        try? persistence.markRecoverable(current.handle, availability: availability)
        current.continuation.yield(
            .finishing(reason: .interruption, frameCount: frames)
        )
        current.continuation.yield(
            .recoveryRequired(
                RecordingRecoveryItem(
                    recordingID: current.handle.request.recordingID,
                    sessionID: current.handle.request.sessionID,
                    startedAt: current.handle.request.startedAt,
                    durableFrameCount: frames,
                    availability: availability
                )
            )
        )
        current.continuation.finish()
        active = nil
    }

    private func map(_ error: Error) -> RecordingFailure {
        switch error as? RecordingPersistenceError {
        case .invalidLibraryAuthority:
            .libraryBecameReadOnly
        case .stagingCollision, .destinationCollision:
            .sessionDestinationCollision
        case .invalidStaging, .recordStreamTooLarge, .emptyRecording, .durationExceeded:
            .sealValidationFailedRecoverable
        case .unsafeEntry, .ioFailure, .injectedFault:
            .stagingWriteFailedRecoverable
        case nil:
            .stagingWriteFailedRecoverable
        }
    }

    private func recoveryOutcome(
        for request: MicrophoneRecordingRequest,
        root: URL,
        error: Error
    ) -> RecordingPublicationOutcome {
        let catalog = persistence.inspectRecovery(in: request.libraryScope, under: root)
        if let receipt = catalog.reconciledSeals.first(where: {
            $0.libraryID == request.libraryScope.libraryID &&
                $0.recordingID == request.recordingID &&
                $0.sessionID == request.sessionID
        }) {
            return .installed(receipt)
        }
        if let item = catalog.items.first(where: { $0.recordingID == request.recordingID }) {
            return .recoveryRequired(item)
        }
        return .failed(map(error))
    }
}
