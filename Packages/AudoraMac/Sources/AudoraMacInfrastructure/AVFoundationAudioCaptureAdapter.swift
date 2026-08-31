import AudoraApplication
import AudoraDomain
import Foundation
import Synchronization

/// Single-consumer state channel for capture observations. Progress is a
/// replaceable projection, and a newer mute acknowledgement subsumes an older
/// queued acknowledgement because its effective frame never regresses.
/// Terminal observations are retained in order. This keeps the channel bounded
/// without allowing progress floods to evict control or terminal state.
final class BoundedCaptureObservationBroker: @unchecked Sendable {
    private final class CancellationToken: @unchecked Sendable {
        let cancelled = Atomic<Bool>(false)
    }

    private struct WaitingConsumer {
        let id: UUID
        let token: CancellationToken
        let continuation: CheckedContinuation<CaptureObservation?, Never>
    }

    // One latest progress, one latest mute acknowledgement, and the fixed
    // finishing/sealing/result terminal sequence fit within this bound.
    private static let pendingCapacity = 8

    private var pending: [CaptureObservation] = []
    private var finishRequested = false
    private var waitingConsumer: WaitingConsumer?
    private let lock = NSLock()
    private let afterWaiterInstalled: (@Sendable () -> Void)?
    private let beforeCancellationLock: (@Sendable () -> Void)?
    private let afterCancelledWaiterObservationBuffered: (@Sendable () -> Void)?

    init(
        afterWaiterInstalled: (@Sendable () -> Void)? = nil,
        beforeCancellationLock: (@Sendable () -> Void)? = nil,
        afterCancelledWaiterObservationBuffered: (@Sendable () -> Void)? = nil
    ) {
        self.afterWaiterInstalled = afterWaiterInstalled
        self.beforeCancellationLock = beforeCancellationLock
        self.afterCancelledWaiterObservationBuffered =
            afterCancelledWaiterObservationBuffered
    }

    func publish(_ observation: CaptureObservation) {
        lock.lock()
        guard !finishRequested else {
            lock.unlock()
            return
        }
        if let waitingConsumer,
           waitingConsumer.token.cancelled.load(ordering: .acquiring)
        {
            // Cancellation linearized before this publication. Preserve the
            // observation, but leave detachment and nil resumption to the
            // cancellation path. Resuming here can circularly wait on the
            // synchronous cancellation handler.
            appendBounded(observation)
            lock.unlock()
            afterCancelledWaiterObservationBuffered?()
            return
        }
        if let waitingConsumer {
            self.waitingConsumer = nil
            lock.unlock()
            waitingConsumer.continuation.resume(returning: observation)
            return
        }
        appendBounded(observation)
        lock.unlock()
    }

    private func appendBounded(_ observation: CaptureObservation) {
        switch observation {
        case .progress:
            pending.removeAll(where: Self.isProgress)
        case .muteChanged:
            pending.removeAll(where: Self.isMuteAcknowledgement)
        case .finishing, .sealing, .sealCandidate, .discarded, .recoveryRequired:
            break
        }
        precondition(
            pending.count < Self.pendingCapacity,
            "capture observation control bound exceeded"
        )
        pending.append(observation)
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

    func next() async -> CaptureObservation? {
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
                    let observation = pending.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: observation)
                    return
                }
                if finishRequested {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                precondition(
                    waitingConsumer == nil,
                    "capture observation feed has multiple consumers"
                )
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
        let continuation: CheckedContinuation<CaptureObservation?, Never>?
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

    private static func isProgress(_ observation: CaptureObservation) -> Bool {
        if case .progress = observation { return true }
        return false
    }

    private static func isMuteAcknowledgement(
        _ observation: CaptureObservation
    ) -> Bool {
        if case .muteChanged = observation { return true }
        return false
    }
}

/// Nonisolated lifetime authority for one active capture. Normal adapter
/// finalization disarms it. If the adapter itself is released, this owner
/// cancels both workers and converts the incomplete staging aggregate into an
/// identity-scoped recovery item after quiescing the source.
private final class CaptureSessionLifecycle: @unchecked Sendable {
    private let source: any MicrophoneInputSource
    private let handle: RecordingStagingHandle
    private let observations: BoundedCaptureObservationBroker
    private let persistence: RecordingPersistence
    private var feedTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var armed = true
    private let lock = NSLock()

    init(
        source: any MicrophoneInputSource,
        handle: RecordingStagingHandle,
        observations: BoundedCaptureObservationBroker,
        persistence: RecordingPersistence
    ) {
        self.source = source
        self.handle = handle
        self.observations = observations
        self.persistence = persistence
    }

    func install(
        feedTask: Task<Void, Never>,
        deadlineTask: Task<Void, Never>
    ) {
        lock.lock()
        precondition(armed && self.feedTask == nil && self.deadlineTask == nil)
        self.feedTask = feedTask
        self.deadlineTask = deadlineTask
        lock.unlock()
    }

    func disarm() {
        let deadlineTask: Task<Void, Never>?
        lock.lock()
        guard armed else {
            lock.unlock()
            return
        }
        armed = false
        feedTask = nil
        deadlineTask = self.deadlineTask
        self.deadlineTask = nil
        lock.unlock()
        deadlineTask?.cancel()
    }

    deinit {
        let feedTask: Task<Void, Never>?
        let deadlineTask: Task<Void, Never>?
        lock.lock()
        guard armed else {
            lock.unlock()
            return
        }
        armed = false
        feedTask = self.feedTask
        deadlineTask = self.deadlineTask
        self.feedTask = nil
        self.deadlineTask = nil
        let source = source
        let handle = handle
        let observations = observations
        let persistence = persistence
        lock.unlock()

        feedTask?.cancel()
        deadlineTask?.cancel()
        Task {
            await source.stop()
            let frames = handle.durableFrameCount
            let availability: RecordingRecoveryAvailability = frames > 0
                ? .sealOrDiscard
                : .discardOnly
            handle.closeCaptureStream()
            try? persistence.markRecoverable(handle, availability: availability)
            observations.publish(
                .finishing(reason: .interruption, frameCount: frames)
            )
            observations.publish(
                .recoveryRequired(
                    RecordingRecoveryItem(
                        recordingID: handle.request.recordingID,
                        sessionID: handle.request.sessionID,
                        startedAt: handle.request.startedAt,
                        durableFrameCount: frames,
                        availability: availability
                    )
                )
            )
            observations.finish()
        }
    }
}

/// macOS capture boundary. The shipping composition injects the AVFoundation
/// source, while tests exercise this adapter only with synthetic input sources.
/// Physical devices and permission prompts remain explicit release qualification.
public actor AVFoundationAudioCaptureAdapter: AudioCapturePort {
    private enum RecoveryDrain: Equatable {
        /// Persistence or assembler authority failed. Only bytes already
        /// acknowledged by the durable watermark may be exposed.
        case durableOnly
        /// The source ended without a clean capture command. Preserve its
        /// monotonic terminal boundary before flushing the valid assembler.
        case sourceBoundary(UInt64)
    }

    private enum TerminalIntent: Equatable {
        case seal(CaptureTerminalReason)
        case discard
        case recover(RecoveryDrain)

        var blocksInputPersistence: Bool {
            switch self {
            case .seal:
                false
            case .discard, .recover:
                true
            }
        }
    }

    private enum SpanDurationLimitPolicy {
        /// Live input that first reaches the ceiling reserves a duration seal
        /// and asks the source to quiesce.
        case liveInput
        /// Final flushing may promote a clean seal to duration-limit, but must
        /// never replace an already authoritative recovery decision.
        case terminalFlush
        /// Timeline materialization preserves its caller's terminal policy.
        case preserveTerminalIntent
    }

    private struct ActiveCapture {
        struct PendingMute: Equatable {
            let isMuted: Bool
            let monotonicBoundaryFrame: UInt64
        }

        let generation: UInt64
        let handle: RecordingStagingHandle
        let source: any MicrophoneInputSource
        let observations: BoundedCaptureObservationBroker
        let startedAtMonotonicNanoseconds: UInt64
        var assembler: CanonicalPCMAssembler
        var acknowledgedMuteEpoch: MicrophoneMuteEpoch
        var projectedElapsedFrame: UInt64
        var pendingMute: PendingMute?
        var pendingDurationDeadlineFrame: UInt64?
        var terminalIntent: TerminalIntent?
        var finalizing: Bool
    }

    private let roots: any RecordingLibraryRootProviding
    private let sources: any MicrophoneInputSourceFactory
    private let persistence: RecordingPersistence
    private let monotonicClock: any CaptureMonotonicClock
    private let deadlineWorkerDidFinish: @Sendable () -> Void
    private var active: ActiveCapture?
    private var feedTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var captureLifecycle: CaptureSessionLifecycle?
    private var nextGeneration: UInt64 = 1
    private var beginningGeneration: UInt64?

    public init(
        roots: any RecordingLibraryRootProviding,
        sources: any MicrophoneInputSourceFactory,
        monotonicClock: any CaptureMonotonicClock = SystemCaptureMonotonicClock(),
        persistenceFault: @escaping @Sendable (RecordingPersistenceFaultPoint) throws -> Void = { _ in }
    ) {
        self.roots = roots
        self.sources = sources
        self.monotonicClock = monotonicClock
        deadlineWorkerDidFinish = {}
        persistence = RecordingPersistence(fault: persistenceFault)
    }

    init(
        roots: any RecordingLibraryRootProviding,
        sources: any MicrophoneInputSourceFactory,
        monotonicClock: any CaptureMonotonicClock,
        deadlineWorkerDidFinish: @escaping @Sendable () -> Void,
        persistenceFault: @escaping @Sendable (RecordingPersistenceFaultPoint) throws -> Void = {
            _ in
        }
    ) {
        self.roots = roots
        self.sources = sources
        self.monotonicClock = monotonicClock
        self.deadlineWorkerDidFinish = deadlineWorkerDidFinish
        persistence = RecordingPersistence(fault: persistenceFault)
    }

    public func begin(_ request: MicrophoneRecordingRequest) async -> CaptureStartOutcome {
        guard active == nil, beginningGeneration == nil else {
            return .rejected(.anotherLibraryActivity)
        }
        let generation = nextGeneration
        nextGeneration &+= 1
        beginningGeneration = generation

        guard let root = await roots.recordingRoot(for: request.libraryScope) else {
            clearBeginningReservation(generation)
            return .rejected(.libraryBecameReadOnly)
        }
        guard isBeginning(generation) else {
            return .rejected(.anotherLibraryActivity)
        }
        let handle: RecordingStagingHandle
        do {
            handle = try persistence.prepare(request, under: root)
        } catch {
            clearBeginningReservation(generation)
            return .rejected(map(error))
        }
        let source = await sources.makeSource()
        guard isBeginning(generation) else {
            try? persistence.discard(handle)
            return .rejected(.anotherLibraryActivity)
        }
        let inputOutcome = await source.start(monotonicClock: monotonicClock)
        let inputFeed: MicrophoneInputFeed
        switch inputOutcome {
        case let .started(feed):
            inputFeed = feed
        case .permissionDenied:
            try? persistence.discard(handle)
            clearBeginningReservation(generation)
            return .rejected(.microphonePermissionDenied)
        case .unavailable:
            try? persistence.discard(handle)
            clearBeginningReservation(generation)
            return .rejected(.microphoneUnavailable)
        }
        guard isBeginning(generation) else {
            await source.stop()
            try? persistence.discard(handle)
            return .rejected(.anotherLibraryActivity)
        }

        var configuredAssembler = CanonicalPCMAssembler()
        do {
            try configuredAssembler.configure(
                sampleRateHz: inputFeed.format.sampleRateHz,
                channelCount: Int(inputFeed.format.channelCount)
            )
        } catch {
            await source.stop()
            try? persistence.discard(handle)
            clearBeginningReservation(generation)
            return .rejected(.microphoneUnavailable)
        }

        let captureObservedAt = await monotonicClock.now()
        guard isBeginning(generation) else {
            await source.stop()
            try? persistence.discard(handle)
            return .rejected(.anotherLibraryActivity)
        }
        let captureStartedAt = inputFeed.captureStartedAtMonotonicNanoseconds
        guard captureStartedAt <= captureObservedAt else {
            await source.stop()
            try? persistence.discard(handle)
            clearBeginningReservation(generation)
            return .rejected(.microphoneUnavailable)
        }
        let initialElapsedFrame = monotonicFrame(
            now: captureObservedAt,
            startedAt: captureStartedAt
        )
        let startedAtDurationLimit =
            initialElapsedFrame == CanonicalRecordingLimits.maximumFrames
        let observationBroker = BoundedCaptureObservationBroker()
        let stream = AsyncStream<CaptureObservation>(
            unfolding: { await observationBroker.next() }
        )
        active = ActiveCapture(
            generation: generation,
            handle: handle,
            source: source,
            observations: observationBroker,
            startedAtMonotonicNanoseconds: captureStartedAt,
            assembler: configuredAssembler,
            acknowledgedMuteEpoch: .initial,
            projectedElapsedFrame: initialElapsedFrame,
            pendingMute: nil,
            pendingDurationDeadlineFrame: startedAtDurationLimit
                ? CanonicalRecordingLimits.maximumFrames
                : nil,
            terminalIntent: startedAtDurationLimit ? .seal(.durationLimit) : nil,
            finalizing: false
        )
        clearBeginningReservation(generation)
        guard active?.generation == generation else {
            await source.stop()
            try? persistence.markRecoverable(handle, availability: .discardOnly)
            return .rejected(.stagingWriteFailedRecoverable)
        }
        active?.observations.publish(
            .progress(frameCount: initialElapsedFrame, level: .unavailable(.stale))
        )
        let lifecycle = CaptureSessionLifecycle(
            source: source,
            handle: handle,
            observations: observationBroker,
            persistence: persistence
        )
        captureLifecycle = lifecycle
        let deadlineClock = monotonicClock
        let workerDidFinish = deadlineWorkerDidFinish
        let deadlineWorker = Task { [weak self] in
            defer { workerDidFinish() }
            let countdownSeconds = (0...59).map { UInt64(44 * 60 + $0) }
            let deadlines = [UInt64(40 * 60)] + countdownSeconds + [UInt64(45 * 60)]
            for seconds in deadlines {
                let (deadline, overflow) = captureStartedAt.addingReportingOverflow(
                    seconds * 1_000_000_000
                )
                guard !overflow else { return }
                do {
                    try await deadlineClock.sleep(until: deadline)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.deadlineReached(
                    generation: generation,
                    targetFrame: seconds * CanonicalRecordingLimits.sampleRate
                )
            }
        }
        deadlineTask = deadlineWorker
        let feedWorker = Task { [weak self] in
            for await event in inputFeed.events {
                guard !Task.isCancelled else { break }
                await self?.consume(event, generation: generation)
            }
            await self?.inputEnded(generation: generation)
        }
        feedTask = feedWorker
        lifecycle.install(feedTask: feedWorker, deadlineTask: deadlineWorker)
        if startedAtDurationLimit {
            await source.stop()
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
              !current.finalizing
        else {
            return .rejected(.staleCommand)
        }
        switch command {
        case let .setMuted(muted):
            guard current.terminalIntent == nil else {
                return .rejected(.staleCommand)
            }
            if let pending = current.pendingMute {
                return pending.isMuted == muted
                    ? .accepted
                    : .rejected(.staleCommand)
            }
            guard current.acknowledgedMuteEpoch.isMuted != muted else {
                return .accepted
            }
            let now = await monotonicClock.now()
            guard var live = active,
                  live.generation == current.generation,
                  live.handle.request.recordingID == recordingID,
                  live.terminalIntent == nil,
                  !live.finalizing
            else {
                return .rejected(.staleCommand)
            }
            if let pending = live.pendingMute {
                return pending.isMuted == muted
                    ? .accepted
                    : .rejected(.staleCommand)
            }
            guard live.acknowledgedMuteEpoch.isMuted != muted else {
                return .accepted
            }
            let boundary = monotonicFrame(
                now: now,
                startedAt: live.startedAtMonotonicNanoseconds
            )
            let proposedMute = ActiveCapture.PendingMute(
                isMuted: muted,
                monotonicBoundaryFrame: boundary
            )
            live.pendingMute = proposedMute
            active = live
            let sourceAccepted = await live.source.setMuted(muted)
            guard let latest = active,
                  latest.generation == live.generation,
                  latest.handle.request.recordingID == recordingID,
                  latest.terminalIntent == nil,
                  !latest.finalizing
            else {
                return .rejected(.staleCommand)
            }
            guard sourceAccepted else {
                if latest.pendingMute == proposedMute {
                    active?.pendingMute = nil
                }
                return .rejected(.stagingWriteFailedRecoverable)
            }
            return .accepted

        case .stop:
            if case .seal = current.terminalIntent {
                return .accepted
            }
            guard current.terminalIntent == nil else {
                return .rejected(.staleCommand)
            }
            let now = await monotonicClock.now()
            guard var live = active,
                  live.generation == current.generation,
                  live.handle.request.recordingID == recordingID,
                  !live.finalizing
            else {
                return .rejected(.staleCommand)
            }
            if case .seal = live.terminalIntent {
                // A duration stop or an already accepted user stop won while
                // the clock read was suspended. Preserve that terminal reason.
                return .accepted
            }
            guard live.terminalIntent == nil else {
                return .rejected(.staleCommand)
            }
            let stopBoundary = monotonicFrame(
                now: now,
                startedAt: live.startedAtMonotonicNanoseconds
            )
            live.pendingDurationDeadlineFrame = stopBoundary
            live.terminalIntent = .seal(
                stopBoundary == CanonicalRecordingLimits.maximumFrames
                    ? .durationLimit
                    : .userStop
            )
            active = live
            // `stop` is a quiesce-and-drain operation. The source must detach
            // callbacks and finish its feed only after every accepted event has
            // entered the bounded stream. `inputEnded` owns sealing.
            await live.source.stop()
            return .accepted

        case .discardConfirmed:
            guard current.terminalIntent == nil else {
                return .rejected(.staleCommand)
            }
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
        guard !hasCaptureActivity else {
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
        guard !hasCaptureActivity else {
            return RecordingRecoveryCatalog(
                items: [],
                inspectionStatus: .blocked(.stagingListingUnavailable)
            )
        }
        return persistence.inspectRecovery(in: library, under: root)
    }

    public func resolveRecovery(
        _ action: RecordingRecoveryAction,
        recordingID: RecordingID,
        in library: LibraryScope
    ) async -> RecordingRecoveryOutcome {
        guard !hasCaptureActivity else {
            return .failed(.libraryBecameReadOnly)
        }
        guard let root = await roots.recordingRoot(for: library),
              !hasCaptureActivity
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
            if current.terminalIntent?.blocksInputPersistence == true {
                return
            }
            do {
                let spans = try current.assembler.consume(
                    chunk,
                    muted: chunk.muteEpoch.isMuted
                )
                active?.assembler = current.assembler
                let shouldStop = try persist(
                    spans,
                    into: &current,
                    durationLimitPolicy: .liveInput
                )
                active = current
                if shouldStop {
                    await current.source.stop()
                }
            } catch CanonicalPCMAssemblerError.unsupportedInputFormat {
                await requestRecovery(generation: generation)
            } catch {
                await requestRecovery(generation: generation)
            }

        case .interrupted:
            await requestSourceRecovery(generation: generation)
        case .clockBecameInvalid:
            await requestSourceRecovery(generation: generation)
        case let .captureGap(
            sampleRateHz,
            startSampleFrame,
            frameCount,
            channelCount,
            muteEpoch
        ):
            if current.terminalIntent?.blocksInputPersistence == true {
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
                let shouldStop = try persist(
                    spans,
                    into: &current,
                    durationLimitPolicy: .liveInput
                )
                active = current
                if shouldStop {
                    await current.source.stop()
                }
            } catch {
                await requestRecovery(generation: generation)
            }
        case let .mutedInterval(
            sampleRateHz,
            startSampleFrame,
            frameCount,
            channelCount,
            muteEpoch
        ):
            if current.terminalIntent?.blocksInputPersistence == true {
                return
            }
            guard muteEpoch.isMuted else {
                await requestRecovery(generation: generation)
                return
            }
            do {
                let spans = try current.assembler.consumeMutedInterval(
                    sampleRateHz: sampleRateHz,
                    startSampleFrame: startSampleFrame,
                    frameCount: frameCount,
                    channelCount: channelCount
                )
                active?.assembler = current.assembler
                let shouldStop = try persist(
                    spans,
                    into: &current,
                    durationLimitPolicy: .liveInput
                )
                active = current
                if shouldStop {
                    await current.source.stop()
                }
            } catch {
                await requestRecovery(generation: generation)
            }
        case let .muteChanged(epoch, effectiveInputFrame):
            if current.terminalIntent?.blocksInputPersistence == true {
                return
            }
            let sourceBoundary: UInt64
            do {
                sourceBoundary = try current.assembler.canonicalFrame(
                    forInputFrame: effectiveInputFrame
                ) ?? current.handle.durableFrameCount
            } catch {
                await requestRecovery(generation: generation)
                return
            }
            if let pending = current.pendingMute,
               pending.isMuted == epoch.isMuted
            {
                do {
                    try materializeDeadlineRemainder(
                        &current,
                        through: max(sourceBoundary, pending.monotonicBoundaryFrame)
                    )
                } catch {
                    await requestRecovery(generation: generation)
                    return
                }
                current.pendingMute = nil
            }
            current.acknowledgedMuteEpoch = epoch
            current.projectedElapsedFrame = min(
                CanonicalRecordingLimits.maximumFrames,
                max(
                    current.projectedElapsedFrame,
                    max(sourceBoundary, current.handle.durableFrameCount)
                )
            )
            active = current
            current.observations.publish(
                .muteChanged(
                    isMuted: epoch.isMuted,
                    effectiveFrame: current.projectedElapsedFrame
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
        guard targetFrame < CanonicalRecordingLimits.maximumFrames else {
            active?.pendingDurationDeadlineFrame = targetFrame
            active?.terminalIntent = .seal(.durationLimit)
            await current.source.stop()
            return
        }
        // Deadline observations advance the UI only. They must not turn a
        // temporarily backlogged callback queue into durable capture gaps.
        current.projectedElapsedFrame = min(
            CanonicalRecordingLimits.maximumFrames,
            max(current.projectedElapsedFrame, targetFrame)
        )
        active = current
        current.observations.publish(
            .progress(
                frameCount: current.projectedElapsedFrame,
                level: .unavailable(.stale)
            )
        )
    }

    private func inputEnded(generation: UInt64) async {
        guard var current = active,
              current.generation == generation,
              !current.finalizing
        else { return }

        if current.terminalIntent == nil {
            // EOF itself is the source-failure observation. Reserve recovery
            // before reading the clock so a reentrant command cannot replace
            // that already-observed failure with a clean seal.
            current.terminalIntent = .recover(
                .sourceBoundary(
                    max(
                        current.projectedElapsedFrame,
                        current.handle.durableFrameCount
                    )
                )
            )
            active = current
            let now = await monotonicClock.now()
            guard var refreshed = active,
                  refreshed.generation == generation,
                  !refreshed.finalizing
            else { return }
            if case let .recover(.sourceBoundary(reservedBoundary)) =
                refreshed.terminalIntent
            {
                refreshed.terminalIntent = .recover(
                    .sourceBoundary(
                        max(
                            reservedBoundary,
                            monotonicFrame(
                                now: now,
                                startedAt: refreshed.startedAtMonotonicNanoseconds
                            )
                        )
                    )
                )
                active = refreshed
            }
            current = refreshed
        }

        if case .seal = current.terminalIntent {
            do {
                if let deadline = current.pendingDurationDeadlineFrame {
                    try materializeTerminalRemainder(&current, through: deadline)
                }
                try flushAssembler(&current)
            } catch {
                current.terminalIntent = .recover(.durableOnly)
            }
        } else if case let .recover(.sourceBoundary(boundary)) = current.terminalIntent {
            do {
                try materializeTerminalRemainder(&current, through: boundary)
                try flushAssembler(&current)
            } catch {
                current.terminalIntent = .recover(.durableOnly)
            }
        }
        if current.terminalIntent == nil {
            current.terminalIntent = .recover(.durableOnly)
        }
        current.finalizing = true
        active = current
        feedTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        captureLifecycle?.disarm()
        captureLifecycle = nil

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
        _ = try persist(
            spans,
            into: &current,
            durationLimitPolicy: .terminalFlush
        )
    }

    /// The only path from canonical spans to durable capture. It owns ceiling
    /// truncation, elapsed projection, level classification, persistence, and
    /// progress publication while its policy preserves the caller's distinct
    /// live/terminal recovery semantics.
    @discardableResult
    private func persist(
        _ spans: [CanonicalPCMSpan],
        into current: inout ActiveCapture,
        durationLimitPolicy: SpanDurationLimitPolicy
    ) throws -> Bool {
        for span in spans {
            let remaining = CanonicalRecordingLimits.maximumFrames -
                current.handle.durableFrameCount
            guard remaining > 0 else {
                return applyDurationLimit(
                    to: &current,
                    policy: durationLimitPolicy
                )
            }
            let bounded = try span.prefix(maximumFrames: remaining)
            let frames = try persistence.append(bounded, to: current.handle)
            current.projectedElapsedFrame = min(
                CanonicalRecordingLimits.maximumFrames,
                max(current.projectedElapsedFrame, frames)
            )
            current.observations.publish(
                .progress(
                    frameCount: current.projectedElapsedFrame,
                    level: captureLevel(for: bounded)
                )
            )
            if frames == CanonicalRecordingLimits.maximumFrames {
                return applyDurationLimit(
                    to: &current,
                    policy: durationLimitPolicy
                )
            }
        }
        return false
    }

    private func captureLevel(for span: CanonicalPCMSpan) -> CaptureLevel {
        if span.reasons.contains(.muted) {
            return .unavailable(.muted)
        }
        if span.reasons.contains(.captureGap) {
            return .unavailable(.captureGap)
        }
        if let measured = span.level {
            return .measured(measured)
        }
        return .unavailable(.stale)
    }

    /// Returns true only when live input newly reserved the stop that its
    /// caller must deliver to the source.
    private func applyDurationLimit(
        to current: inout ActiveCapture,
        policy: SpanDurationLimitPolicy
    ) -> Bool {
        switch policy {
        case .liveInput:
            guard current.terminalIntent == nil else { return false }
            current.terminalIntent = .seal(.durationLimit)
            current.pendingDurationDeadlineFrame =
                CanonicalRecordingLimits.maximumFrames
            return true
        case .terminalFlush:
            if case .recover = current.terminalIntent {
                return false
            }
            current.terminalIntent = .seal(.durationLimit)
            current.pendingDurationDeadlineFrame =
                CanonicalRecordingLimits.maximumFrames
            return false
        case .preserveTerminalIntent:
            return false
        }
    }

    private func materializeDeadlineRemainder(
        _ current: inout ActiveCapture,
        through deadline: UInt64,
        muted: Bool? = nil
    ) throws {
        let spans = try current.assembler.consumeTimedGap(
            throughCanonicalFrame: deadline,
            muted: muted ?? current.acknowledgedMuteEpoch.isMuted
        )
        active?.assembler = current.assembler
        _ = try persist(
            spans,
            into: &current,
            durationLimitPolicy: .preserveTerminalIntent
        )
    }

    /// A source stop may intentionally fail closed before an asynchronous mute
    /// acknowledgement is published.  The accepted command boundary remains
    /// authoritative for privacy: preserve the previous state before it and
    /// the pending state after it, rather than reclassifying all elapsed time
    /// with the last acknowledgement.
    private func materializeTerminalRemainder(
        _ current: inout ActiveCapture,
        through deadline: UInt64
    ) throws {
        guard let pending = current.pendingMute,
              pending.monotonicBoundaryFrame < deadline
        else {
            try materializeDeadlineRemainder(&current, through: deadline)
            return
        }
        try materializeDeadlineRemainder(
            &current,
            through: pending.monotonicBoundaryFrame,
            muted: current.acknowledgedMuteEpoch.isMuted
        )
        try materializeDeadlineRemainder(
            &current,
            through: deadline,
            muted: pending.isMuted
        )
    }

    private func monotonicFrame(now: UInt64, startedAt: UInt64) -> UInt64 {
        guard now > startedAt else { return 0 }
        let elapsedNanoseconds = now - startedAt
        let (scaled, overflow) = elapsedNanoseconds.multipliedReportingOverflow(
            by: CanonicalRecordingLimits.sampleRate
        )
        guard !overflow else { return CanonicalRecordingLimits.maximumFrames }
        return min(
            CanonicalRecordingLimits.maximumFrames,
            scaled / 1_000_000_000
        )
    }

    private func sealAfterDrain(
        _ current: ActiveCapture,
        reason: CaptureTerminalReason
    ) async {
        let frames = current.handle.durableFrameCount
        current.observations.publish(.finishing(reason: reason, frameCount: frames))
        current.observations.publish(.sealing(reason: reason, frameCount: frames))
        do {
            let candidate = try persistence.stageSeal(current.handle, reason: reason)
            current.handle.closeCaptureStream()
            current.observations.publish(.sealCandidate(candidate))
            current.observations.finish()
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
            current.observations.publish(.recoveryRequired(item))
            current.observations.finish()
            active = nil
        }
    }

    private func discardAfterDrain(_ current: ActiveCapture) {
        do {
            current.handle.closeCaptureStream()
            try persistence.discard(current.handle)
            current.observations.publish(
                .discarded(recordingID: current.handle.request.recordingID)
            )
            current.observations.finish()
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
            current.observations.publish(.recoveryRequired(item))
            current.observations.finish()
            active = nil
        }
    }

    private func requestRecovery(generation: UInt64) async {
        guard let current = active,
              current.generation == generation,
              !current.finalizing
        else { return }
        switch current.terminalIntent {
        case .discard, .recover:
            return
        case .none, .seal:
            break
        }
        active?.terminalIntent = .recover(.durableOnly)
        await current.source.stop()
    }

    private func requestSourceRecovery(generation: UInt64) async {
        guard let observed = active,
              observed.generation == generation,
              !observed.finalizing
        else { return }
        if observed.terminalIntent == .discard {
            return
        }
        if observed.terminalIntent == .recover(.durableOnly) {
            return
        }

        let now = await monotonicClock.now()
        guard var current = active,
              current.generation == generation,
              !current.finalizing
        else { return }
        switch current.terminalIntent {
        case .discard, .recover(.durableOnly):
            return
        case let .recover(.sourceBoundary(existingBoundary)):
            current.terminalIntent = .recover(
                .sourceBoundary(
                    max(
                        existingBoundary,
                        monotonicFrame(
                            now: now,
                            startedAt: current.startedAtMonotonicNanoseconds
                        )
                    )
                )
            )
        case .none, .seal:
            current.terminalIntent = .recover(
                .sourceBoundary(
                    monotonicFrame(
                        now: now,
                        startedAt: current.startedAtMonotonicNanoseconds
                    )
                )
            )
        }
        active = current
        await current.source.stop()
    }

    private func exposeRecoveryAfterDrain(_ current: ActiveCapture) {
        let frames = current.handle.durableFrameCount
        current.handle.closeCaptureStream()
        let availability: RecordingRecoveryAvailability = frames > 0 ? .sealOrDiscard : .discardOnly
        try? persistence.markRecoverable(current.handle, availability: availability)
        current.observations.publish(
            .finishing(reason: .interruption, frameCount: frames)
        )
        current.observations.publish(
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
        current.observations.finish()
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

    private var hasCaptureActivity: Bool {
        active != nil || beginningGeneration != nil
    }

    private func isBeginning(_ generation: UInt64) -> Bool {
        beginningGeneration == generation && active == nil
    }

    private func clearBeginningReservation(_ generation: UInt64) {
        if beginningGeneration == generation {
            beginningGeneration = nil
        }
    }
}
