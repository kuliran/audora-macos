import AudoraDomain

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public actor DefaultRecordingFeature: RecordingFeature {
    private let capture: any AudioCapturePort
    private let clock: any RecordingClock
    private let idGenerator: any RecordingIDGenerator
    private let activity: any LibraryActivityCoordinating
    private let sealedNotificationChannel = SessionSealedNotificationChannel()

    private var state: RecordingFeatureState = .unavailable(.noWritableLibrary)
    private var selectedScope: LibraryScope?
    private var recordingLease: LibraryActivityLease?
    private var activeGeneration: UInt64?
    private var intentGeneration: UInt64 = 0
    private var pendingStartGeneration: UInt64?
    private var leaseAcquisitionGenerations: Set<UInt64> = []
    private var leaseAcquisitionWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextGeneration: UInt64 = 1
    private var nextNoticeID: UInt64 = 1
    private var feedTask: Task<Void, Never>?
    private var pendingLibrarySelection: RecordingLibrarySelection?
    private var inFlightLeaseReleaseCount = 0
    private var isCaptureStartInFlight = false
    private var isShuttingDown = false
    private var isShutdown = false
    private var shutdownTask: Task<Void, Never>?
    private var shutdownCompletion: CheckedContinuation<Void, Never>?
    /// Receipts already offered for committed Sessions whose exact Recording
    /// staging cleanup is still pending. The set is scoped by Library and is
    /// replaced/pruned from the finite recovery catalog after cleanup.
    private var pendingCleanupNotifications: Set<SessionSealIdentity> = []
    private var isPublishingSealNotification = false
    private var stateContinuations: [UInt64: AsyncStream<RecordingFeatureState>.Continuation] = [:]
    private var nextSubscriberID: UInt64 = 1

    public init(
        capture: any AudioCapturePort,
        clock: any RecordingClock,
        idGenerator: any RecordingIDGenerator,
        activity: any LibraryActivityCoordinating
    ) {
        self.capture = capture
        self.clock = clock
        self.idGenerator = idGenerator
        self.activity = activity
    }

    deinit {
        sealedNotificationChannel.finish()
    }

    public var currentState: RecordingFeatureState { state }

    public nonisolated var states: AsyncStream<RecordingFeatureState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            Task { await self.addStateSubscriber(continuation) }
        }
    }

    public nonisolated var sealedSessions: SessionSealedNotifications {
        SessionSealedNotifications(channel: sealedNotificationChannel)
    }

    public func send(_ command: RecordingCommand) async {
        // One publication may be suspended behind the lossless notification
        // channel. Reject reentrant commands until that authoritative effect
        // has crossed the Application boundary, keeping producer storage
        // structurally bounded to one.
        guard !isShuttingDown,
              !isShutdown,
              !isPublishingSealNotification
        else { return }
        switch command {
        case let .selectLibrary(selection):
            await selectLibrary(selection)
        case .record:
            await startRecording()
        case let .setMuted(muted):
            await setMuted(muted)
        case .stop:
            await stopRecording()
        case .cancel:
            showDiscardConfirmation()
        case .keepRecording:
            dismissDiscardConfirmation()
        case .discardRecording:
            await discardRecording()
        case let .sealRecovered(recordingID):
            await resolveRecovery(.seal, recordingID: recordingID)
        case let .discardRecovered(recordingID):
            await resolveRecovery(.discard, recordingID: recordingID)
        }
        await finishShutdownIfPossible()
    }

    public func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performShutdown()
        }
        shutdownTask = task
        await task.value
    }

    private func performShutdown() async {
        isShuttingDown = true
        pendingLibrarySelection = nil
        pendingStartGeneration = nil
        intentGeneration = reserveGeneration()
        // A lifecycle boundary has no downstream notification owner. Finishing
        // the channel also releases any capacity-one producer backpressure;
        // durable Library state remains authoritative across replacement.
        sealedNotificationChannel.finish()

        if case .active = state {
            await stopRecording()
        }
        await finishShutdownIfPossible()
        if !isShutdown { await waitForShutdownCompletion() }
    }

    private func selectLibrary(_ selection: RecordingLibrarySelection) async {
        guard !hasUnresolvedRecording else {
            // A terminal release clears local ownership before crossing the
            // coordinator actor. Keep only the newest Library projection that
            // arrives in that bounded suspension window.
            if recordingLease == nil {
                pendingLibrarySelection = selection
            }
            return
        }
        pendingLibrarySelection = nil
        let generation = reserveGeneration()
        intentGeneration = generation
        pendingStartGeneration = nil
        switch selection {
        case .none, .readOnly:
            selectedScope = nil
        case let .writable(scope):
            selectedScope = scope
            transition(to: .selectingLibrary(scope))
        }
        await releaseRecordingLease()
        guard intentGeneration == generation else { return }
        feedTask?.cancel()
        feedTask = nil
        activeGeneration = nil

        switch selection {
        case .none:
            selectedScope = nil
            transition(to: .unavailable(.noWritableLibrary))
        case .readOnly:
            transition(to: .unavailable(.libraryBecameReadOnly))
        case let .writable(scope):
            let acquired = await acquireLease(in: scope, generation: generation)
            guard intentGeneration == generation,
                  selectedScope == scope
            else {
                if let acquired { await releaseExternalLease(acquired) }
                return
            }
            guard let lease = acquired else {
                transition(to: .failed(.anotherLibraryActivity))
                return
            }
            recordingLease = lease
            let catalog = await capture.inspectRecovery(in: scope)
            guard intentGeneration == generation,
                  selectedScope == scope,
                  recordingLease == lease
            else {
                if recordingLease == lease {
                    recordingLease = nil
                    await releaseExternalLease(lease)
                }
                return
            }
            let reconciledReceipt = await publishReconciledSeals(in: catalog)
            guard intentGeneration == generation,
                  selectedScope == scope,
                  recordingLease == lease
            else {
                if recordingLease == lease {
                    recordingLease = nil
                    await releaseExternalLease(lease)
                }
                return
            }
            if catalog.isClear {
                await releaseRecordingLease()
                guard intentGeneration == generation,
                      selectedScope == scope
                else { return }
                if let receipt = reconciledReceipt {
                    transition(
                        to: .completed(
                            SealedSessionSnapshot(receipt: receipt),
                            notice: nil
                        )
                    )
                } else {
                    transition(to: .idle)
                }
                await replayPendingLibrarySelection()
            } else {
                transition(to: .recoveryRequired(catalog))
            }
        }
    }

    private func startRecording() async {
        switch state {
        case .idle, .completed, .failed:
            break
        default:
            return
        }
        guard let scope = selectedScope else {
            transition(to: .unavailable(.noWritableLibrary))
            return
        }
        guard pendingStartGeneration == nil else { return }
        let generation = reserveGeneration()
        intentGeneration = generation
        pendingStartGeneration = generation

        let acquired = await acquireLease(in: scope, generation: generation)
        guard isCurrentPendingStart(generation, scope: scope) else {
            if let acquired { await releaseExternalLease(acquired) }
            return
        }
        guard let lease = acquired else {
            pendingStartGeneration = nil
            transition(to: .failed(.anotherLibraryActivity))
            return
        }
        recordingLease = lease

        let instant = await clock.now()
        guard isCurrentPendingStart(generation, scope: scope) else {
            await abandonStartLease(lease, generation: generation)
            return
        }
        let recordingID = await idGenerator.generateRecordingID(at: instant)
        guard isCurrentPendingStart(generation, scope: scope) else {
            await abandonStartLease(lease, generation: generation)
            return
        }
        for attempt in 0..<32 {
            let sessionID = await idGenerator.generateSessionID(at: instant)
            guard isCurrentPendingStart(generation, scope: scope) else {
                await abandonStartLease(lease, generation: generation)
                return
            }
            let request = MicrophoneRecordingRequest(
                libraryScope: scope,
                recordingID: recordingID,
                sessionID: sessionID,
                startedAt: instant
            )
            transition(to: .starting(RecordingSeed(request: request)))

            isCaptureStartInFlight = true
            let outcome = await capture.begin(request)
            guard isCurrentPendingStart(generation, scope: scope) else {
                if case .started = outcome {
                    _ = await capture.apply(.discardConfirmed, to: recordingID)
                }
                await abandonStartLease(lease, generation: generation)
                isCaptureStartInFlight = false
                return
            }
            if case .rejected(.sessionDestinationCollision) = outcome,
               attempt < 31
            {
                isCaptureStartInFlight = false
                continue
            }

            pendingStartGeneration = nil
            activeGeneration = generation
            switch outcome {
            case let .started(feed):
                isCaptureStartInFlight = false
                guard feed.recordingID == recordingID else {
                    await failAndRelease(.staleCommand)
                    return
                }
                let snapshot = RecordingSnapshot(
                    recordingID: recordingID,
                    sessionID: sessionID,
                    elapsedFrames: 0,
                    level: .unavailable(.stale),
                    mute: .live,
                    noticeID: consumeNoticeID()
                )
                transition(to: .active(snapshot, confirmation: .none))
                feedTask = Task { [weak self] in
                    for await observation in feed.observations {
                        guard !Task.isCancelled else { return }
                        await self?.consume(
                            observation,
                            generation: generation,
                            request: request
                        )
                    }
                }
                return

            case let .rejected(failure):
                let catalog = await capture.inspectRecovery(in: scope)
                guard activeGeneration == generation,
                      intentGeneration == generation,
                      selectedScope == scope
                else {
                    await abandonStartLease(lease, generation: generation)
                    isCaptureStartInFlight = false
                    return
                }
                _ = await publishReconciledSeals(in: catalog)
                if catalog.isClear {
                    await failAndRelease(failure, expectedGeneration: generation)
                } else {
                    activeGeneration = nil
                    transition(to: .recoveryRequired(catalog))
                }
                isCaptureStartInFlight = false
                return
            }
        }
    }

    private func setMuted(_ muted: Bool) async {
        guard case let .active(snapshot, confirmation) = state,
              confirmation == .none
        else { return }
        let expected: RecordingMuteState = muted ? .live : .muted
        guard snapshot.mute == expected else { return }
        transition(
            to: .active(
                snapshot.updating(mute: .changing(toMuted: muted)),
                confirmation: .none
            )
        )
        let outcome = await capture.apply(.setMuted(muted), to: snapshot.recordingID)
        if case .rejected = outcome,
           case let .active(current, confirmation) = state,
           current.recordingID == snapshot.recordingID
        {
            let restored = current.updating(mute: expected)
            transition(to: .active(restored, confirmation: confirmation))
            // A rejected control acknowledgement does not revoke the active
            // capture authority or hide its Cancel/Stop controls. The adapter
            // publishes a terminal recovery observation for material failures.
        }
    }

    private func stopRecording() async {
        guard case let .active(snapshot, _) = state else { return }
        transition(to: .finishing(snapshot, reason: .userStop))
        let generation = activeGeneration
        let outcome = await capture.apply(.stop, to: snapshot.recordingID)
        if case let .rejected(failure) = outcome,
           activeGeneration == generation,
           case let .finishing(current, reason) = state,
           current.recordingID == snapshot.recordingID,
           reason == .userStop
        {
            await failAndRelease(failure, expectedGeneration: generation)
        }
    }

    private func showDiscardConfirmation() {
        guard case let .active(snapshot, .none) = state else { return }
        transition(to: .active(snapshot, confirmation: .discardRecording))
    }

    private func dismissDiscardConfirmation() {
        guard case let .active(snapshot, .discardRecording) = state else { return }
        transition(to: .active(snapshot, confirmation: .none))
    }

    private func discardRecording() async {
        guard case let .active(snapshot, .discardRecording) = state else { return }
        transition(to: .finishing(snapshot, reason: .interruption))
        let generation = activeGeneration
        let outcome = await capture.apply(.discardConfirmed, to: snapshot.recordingID)
        if case .rejected = outcome,
           activeGeneration == generation,
           case let .finishing(current, reason) = state,
           current.recordingID == snapshot.recordingID,
           reason == .interruption
        {
            // The adapter did not acknowledge deletion; keep the still-live
            // authority and explicit confirmation visible.
            transition(to: .active(snapshot, confirmation: .discardRecording))
        }
    }

    private func resolveRecovery(
        _ action: RecordingRecoveryAction,
        recordingID: RecordingID
    ) async {
        guard case let .recoveryRequired(catalog) = state,
              let item = catalog.items.first(where: { $0.recordingID == recordingID }),
              let scope = selectedScope
        else { return }
        if action == .seal,
           item.availability != .sealOrDiscard,
           item.availability != .committedCleanup
        {
            return
        }
        if item.availability == .readOnlyNewerSchema ||
            item.availability == .readOnlyUnsupported
        {
            return
        }
        if action == .discard, item.availability == .committedCleanup { return }
        transition(
            to: .resolvingRecovery(
                catalog,
                recordingID: recordingID,
                action: action
            )
        )

        let outcome = await capture.resolveRecovery(
            action,
            recordingID: recordingID,
            in: scope
        )
        guard case let .resolvingRecovery(
            currentCatalog,
            currentRecordingID,
            currentAction
        ) = state,
            currentCatalog == catalog,
            currentRecordingID == recordingID,
            currentAction == action,
            selectedScope == scope
        else {
            return
        }
        switch outcome {
        case let .sealCandidate(candidate):
                guard let sessionID = item.sessionID,
                      let startedAt = item.startedAt
                else {
                    transition(to: .recoveryRequired(catalog))
                    return
                }
                let request = MicrophoneRecordingRequest(
                    libraryScope: scope,
                    recordingID: item.recordingID,
                    sessionID: sessionID,
                    startedAt: startedAt
            )
            await promoteAndPublishRecoveryCandidate(
                candidate,
                expected: request,
                catalog: catalog,
                scope: scope
            )
        case .discarded:
            let refreshed = await capture.inspectRecovery(in: scope)
            let reconciledReceipt = await publishReconciledSeals(in: refreshed)
            if refreshed.isClear {
                await releaseRecordingLease()
                if let receipt = reconciledReceipt {
                    transition(
                        to: .completed(
                            SealedSessionSnapshot(receipt: receipt),
                            notice: nil
                        )
                    )
                } else {
                    transition(to: .idle)
                }
                await replayPendingLibrarySelection()
            } else {
                transition(to: .recoveryRequired(refreshed))
            }
        case .failed:
            // Keep the recovery catalog and its exact identity-scoped actions
            // visible. A failed recovery must never unlock Library selection or
            // permit a second Recording over unresolved staging.
            transition(to: .recoveryRequired(catalog))
        }
    }

    private func consume(
        _ observation: CaptureObservation,
        generation: UInt64,
        request: MicrophoneRecordingRequest
    ) async {
        guard activeGeneration == generation else { return }
        if let embeddedRecordingID = observation.embeddedRecordingID,
           embeddedRecordingID != request.recordingID
        {
            return
        }

        switch observation {
        case let .progress(frameCount, level):
            updateProgress(frameCount: frameCount, level: level)

        case let .muteChanged(isMuted, effectiveFrame):
            guard case let .active(snapshot, confirmation) = state,
                  effectiveFrame >= snapshot.elapsedFrames
            else { return }
            transition(
                to: .active(
                    snapshot.updating(
                        elapsedFrames: effectiveFrame,
                        level: isMuted ? .unavailable(.muted) : .unavailable(.stale),
                        mute: isMuted ? .muted : .live
                    ),
                    confirmation: confirmation
                )
            )

        case let .finishing(reason, frameCount):
            guard let snapshot = currentSnapshot,
                  frameCount >= snapshot.elapsedFrames
            else { return }
            transition(
                to: .finishing(
                    snapshot.updating(
                        elapsedFrames: frameCount,
                        noticeID: reason == .durationLimit ? consumeNoticeID() : nil
                    ),
                    reason: reason
                )
            )

        case let .sealing(reason, frameCount):
            guard let snapshot = currentSnapshot,
                  frameCount >= snapshot.elapsedFrames
            else { return }
            transition(
                to: .sealing(
                    snapshot.updating(elapsedFrames: frameCount),
                    reason: reason
                )
            )

        case let .sealCandidate(candidate):
            guard let snapshot = currentSnapshot,
                  let scope = selectedScope,
                  request.libraryScope == scope,
                  candidate.frameCount >= snapshot.elapsedFrames
            else { return }
            let publication: ValidatedRecordingPublication
            do {
                publication = try RecordingSealCandidateValidator.validate(
                    candidate,
                    expected: request
                )
            } catch {
                let outcome = await capture.completeSeal(
                    .preserveForRecovery(request)
                )
                guard activeGeneration == generation else { return }
                activeGeneration = nil
                feedTask = nil
                await applyPublicationFailure(
                    outcome,
                    fallback: RecordingRecoveryItem(
                        recordingID: request.recordingID,
                        sessionID: request.sessionID,
                        startedAt: request.startedAt,
                        durableFrameCount: candidate.frameCount,
                        availability: .sealOrDiscard
                    )
                )
                await finishShutdownIfPossible()
                return
            }
            let outcome = await capture.completeSeal(.publish(publication))
            guard activeGeneration == generation else { return }
            activeGeneration = nil
            feedTask = nil
            switch outcome {
            case let .installed(receipt):
                guard receipt == publication.receipt else {
                    await applyPublicationFailure(
                        .failed(.sealValidationFailedRecoverable),
                        fallback: recoveryItem(for: request, frames: candidate.frameCount)
                    )
                    await finishShutdownIfPossible()
                    return
                }
                transition(
                    to: .sealing(
                        snapshot.updating(elapsedFrames: candidate.frameCount),
                        reason: publication.terminalReason
                    )
                )
                let directIdentity = await publishSealed(receipt, in: scope)
                let refreshed = await capture.inspectRecovery(in: scope)
                _ = await publishReconciledSeals(
                    in: refreshed,
                    excluding: Set(directIdentity.map { [$0] } ?? [])
                )
                if refreshed.isClear {
                    await releaseRecordingLease()
                    transition(
                        to: .completed(
                            SealedSessionSnapshot(receipt: receipt),
                            notice: publication.terminalReason == .durationLimit
                                ? .durationLimit
                                : nil
                        )
                    )
                    await replayPendingLibrarySelection()
                } else {
                    transition(to: .recoveryRequired(refreshed))
                }
            case .recoveryRequired, .failed:
                await applyPublicationFailure(
                    outcome,
                    fallback: recoveryItem(for: request, frames: candidate.frameCount)
                )
            }

        case .discarded:
            activeGeneration = nil
            feedTask = nil
            await releaseRecordingLease()
            transition(to: .idle)
            await replayPendingLibrarySelection()

        case let .recoveryRequired(item):
            activeGeneration = nil
            feedTask = nil
            transition(to: .recoveryRequired(RecordingRecoveryCatalog(items: [item])))
        }
        await finishShutdownIfPossible()
    }

    private func updateProgress(frameCount: UInt64, level: CaptureLevel) {
        guard let snapshot = currentSnapshot,
              frameCount >= snapshot.elapsedFrames,
              frameCount <= CanonicalRecordingLimits.maximumFrames
        else { return }
        let phase = CanonicalRecordingLimits.phase(at: frameCount)
        let updated = snapshot.updating(
            elapsedFrames: frameCount,
            level: level,
            noticeID: shouldAdvanceNotice(from: snapshot.limitPhase, to: phase)
                ? consumeNoticeID()
                : nil
        )
        switch state {
        case let .active(_, confirmation):
            transition(to: .active(updated, confirmation: confirmation))
        case let .finishing(_, reason):
            transition(to: .finishing(updated, reason: reason))
        case let .sealing(_, reason):
            transition(to: .sealing(updated, reason: reason))
        default:
            break
        }
    }

    private func promoteAndPublishRecoveryCandidate(
        _ candidate: StagedRecordingSealCandidate,
        expected request: MicrophoneRecordingRequest,
        catalog: RecordingRecoveryCatalog,
        scope: LibraryScope
    ) async {
        let publication: ValidatedRecordingPublication
        do {
            publication = try RecordingSealCandidateValidator.validate(
                candidate,
                expected: request
            )
        } catch {
            _ = await capture.completeSeal(
                .preserveForRecovery(request)
            )
            transition(to: .recoveryRequired(catalog))
            return
        }
        let publicationOutcome = await capture.completeSeal(.publish(publication))
        switch publicationOutcome {
        case let .installed(receipt) where receipt == publication.receipt:
            let directIdentity = await publishSealed(receipt, in: scope)
            let refreshed = await capture.inspectRecovery(in: scope)
            _ = await publishReconciledSeals(
                in: refreshed,
                excluding: Set(directIdentity.map { [$0] } ?? [])
            )
            if refreshed.isClear {
                await releaseRecordingLease()
                transition(
                    to: .completed(
                        SealedSessionSnapshot(receipt: receipt),
                        notice: publication.terminalReason == .durationLimit
                            ? .durationLimit
                            : nil
                    )
                )
                await replayPendingLibrarySelection()
            } else {
                transition(to: .recoveryRequired(refreshed))
            }
        case .installed, .recoveryRequired, .failed:
            transition(to: .recoveryRequired(catalog))
        }
    }

    private func applyPublicationFailure(
        _ outcome: RecordingPublicationOutcome,
        fallback: RecordingRecoveryItem
    ) async {
        switch outcome {
        case let .recoveryRequired(item):
            transition(to: .recoveryRequired(RecordingRecoveryCatalog(items: [item])))
        case .installed:
            // A mismatched installed receipt is semantically untrusted. Keep
            // recovery visible rather than acknowledging the wrong Session.
            transition(to: .recoveryRequired(RecordingRecoveryCatalog(items: [fallback])))
        case .failed:
            transition(to: .recoveryRequired(RecordingRecoveryCatalog(items: [fallback])))
        }
    }

    private func recoveryItem(
        for request: MicrophoneRecordingRequest,
        frames: UInt64
    ) -> RecordingRecoveryItem {
        RecordingRecoveryItem(
            recordingID: request.recordingID,
            sessionID: request.sessionID,
            startedAt: request.startedAt,
            durableFrameCount: frames,
            availability: frames > 0 ? .sealOrDiscard : .discardOnly
        )
    }

    private func shouldAdvanceNotice(
        from old: RecordingLimitPhase,
        to new: RecordingLimitPhase
    ) -> Bool {
        switch (old, new) {
        case (.ordinary, .fiveMinuteWarning),
             (.ordinary, .oneMinuteCountdown),
             (.fiveMinuteWarning, .oneMinuteCountdown),
             (_, .automaticStop):
            return true
        case let (.oneMinuteCountdown(oldSeconds), .oneMinuteCountdown(newSeconds)):
            let milestones: Set<UInt8> = [30, 10, 5, 4, 3, 2, 1]
            return newSeconds < oldSeconds && milestones.contains(newSeconds)
        default:
            return false
        }
    }

    private var currentSnapshot: RecordingSnapshot? {
        switch state {
        case let .active(snapshot, _),
             let .finishing(snapshot, _),
             let .sealing(snapshot, _):
            snapshot
        default:
            nil
        }
    }

    private var hasUnresolvedRecording: Bool {
        switch state {
        case .starting, .active, .finishing, .sealing, .recoveryRequired,
             .resolvingRecovery:
            true
        case .selectingLibrary, .unavailable, .idle, .completed, .failed:
            false
        }
    }

    private func failAndRelease(
        _ failure: RecordingFailure,
        expectedGeneration: UInt64? = nil
    ) async {
        if let expectedGeneration, activeGeneration != expectedGeneration { return }
        activeGeneration = nil
        feedTask?.cancel()
        feedTask = nil
        await releaseRecordingLease()
        transition(to: .failed(failure))
        await replayPendingLibrarySelection()
    }

    private func releaseRecordingLease() async {
        guard let lease = recordingLease else { return }
        recordingLease = nil
        await releaseExternalLease(lease)
    }

    private func releaseExternalLease(_ lease: LibraryActivityLease) async {
        inFlightLeaseReleaseCount += 1
        await activity.release(lease)
        inFlightLeaseReleaseCount -= 1
    }

    private func finishShutdownIfPossible() async {
        guard isShuttingDown,
              !isShutdown,
              !isPublishingSealNotification,
              leaseAcquisitionGenerations.isEmpty,
              inFlightLeaseReleaseCount == 0,
              !isCaptureStartInFlight
        else { return }

        // Live terminal work owns the Library authority until its adapter has
        // made either the immutable Session or its recovery staging durable.
        switch state {
        case .active, .finishing, .sealing, .resolvingRecovery:
            return
        case .selectingLibrary, .starting, .recoveryRequired,
             .unavailable, .idle, .completed, .failed:
            break
        }

        await releaseRecordingLease()
        guard inFlightLeaseReleaseCount == 0,
              recordingLease == nil
        else { return }

        activeGeneration = nil
        pendingStartGeneration = nil
        selectedScope = nil
        pendingLibrarySelection = nil
        feedTask?.cancel()
        feedTask = nil
        transition(to: .unavailable(.noWritableLibrary))
        for continuation in stateContinuations.values { continuation.finish() }
        stateContinuations.removeAll(keepingCapacity: false)
        isShutdown = true
        let completion = shutdownCompletion
        shutdownCompletion = nil
        completion?.resume()
    }

    private func waitForShutdownCompletion() async {
        if isShutdown { return }
        await withCheckedContinuation { continuation in
            precondition(shutdownCompletion == nil)
            shutdownCompletion = continuation
        }
    }

    private func replayPendingLibrarySelection() async {
        guard let selection = pendingLibrarySelection else { return }
        pendingLibrarySelection = nil
        await selectLibrary(selection)
    }

    private func reserveGeneration() -> UInt64 {
        defer { nextGeneration &+= 1 }
        return nextGeneration
    }

    private func isCurrentPendingStart(
        _ generation: UInt64,
        scope: LibraryScope
    ) -> Bool {
        pendingStartGeneration == generation &&
            intentGeneration == generation &&
            selectedScope == scope
    }

    private func abandonStartLease(
        _ lease: LibraryActivityLease,
        generation: UInt64
    ) async {
        if pendingStartGeneration == generation { pendingStartGeneration = nil }
        guard recordingLease == lease else { return }
        recordingLease = nil
        await releaseExternalLease(lease)
    }

    private func acquireLease(
        in scope: LibraryScope,
        generation: UInt64
    ) async -> LibraryActivityLease? {
        let waitsForOwnedAcquisition = !leaseAcquisitionGenerations.isEmpty
        leaseAcquisitionGenerations.insert(generation)
        let first = await activity.acquireRecording(in: scope)
        leaseAcquisitionGenerations.remove(generation)

        guard intentGeneration == generation, selectedScope == scope else {
            if let first { await releaseExternalLease(first) }
            // Waiters may retry only after stale authority is actually reaped,
            // not merely after its acquire call returned.
            resumeLeaseAcquisitionWaiters()
            return nil
        }
        if let first {
            resumeLeaseAcquisitionWaiters()
            return first
        }
        resumeLeaseAcquisitionWaiters()
        guard waitsForOwnedAcquisition || !leaseAcquisitionGenerations.isEmpty else {
            return nil
        }
        while !leaseAcquisitionGenerations.isEmpty {
            await withCheckedContinuation { leaseAcquisitionWaiters.append($0) }
            guard intentGeneration == generation,
                  selectedScope == scope
            else { return nil }
        }
        let retried = await activity.acquireRecording(in: scope)
        guard intentGeneration == generation, selectedScope == scope else {
            if let retried { await releaseExternalLease(retried) }
            return nil
        }
        return retried
    }

    private func resumeLeaseAcquisitionWaiters() {
        let waiters = leaseAcquisitionWaiters
        leaseAcquisitionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    private func consumeNoticeID() -> UInt64 {
        defer { nextNoticeID &+= 1 }
        return nextNoticeID
    }

    private func transition(to newState: RecordingFeatureState) {
        state = newState
        for continuation in stateContinuations.values {
            continuation.yield(newState)
        }
    }

    private func publishSealed(
        _ receipt: SessionSealedReceipt,
        in scope: LibraryScope
    ) async -> SessionSealIdentity? {
        let identity = SessionSealIdentity(
            libraryID: receipt.libraryID,
            sessionID: receipt.sessionID
        )
        guard receipt.libraryID == scope.libraryID,
              !pendingCleanupNotifications.contains(identity),
              !isPublishingSealNotification
        else { return nil }
        isPublishingSealNotification = true
        defer { isPublishingSealNotification = false }
        await deliverSealed(receipt, in: scope)
        return identity
    }

    private func publishReconciledSeals(
        in catalog: RecordingRecoveryCatalog,
        excluding operationExclusions: Set<SessionSealIdentity> = []
    ) async -> SessionSealedReceipt? {
        guard let scope = selectedScope,
              !isPublishingSealNotification
        else { return nil }
        // Fence the whole catalog, not just each individual send. Otherwise an
        // actor-reentrant Library command could start a second catalog between
        // two receipts and either grow producer waiters or make one batch skip
        // a receipt while the other is backpressured.
        isPublishingSealNotification = true
        defer { isPublishingSealNotification = false }
        let currentPending = Set(catalog.items.compactMap { item -> SessionSealIdentity? in
            guard item.availability == .committedCleanup,
                  let sessionID = item.sessionID
            else { return nil }
            return SessionSealIdentity(libraryID: scope.libraryID, sessionID: sessionID)
        })
        let previousPending = pendingCleanupNotifications
        if case .blocked = catalog.inspectionStatus,
           previousPending.union(currentPending).count >
               RecordingRecoveryCatalog.maximumEntryCount
        {
            // Preserve the already-notified authority and defer all new
            // effects until a complete bounded scan can replace it.
            return nil
        }
        var notifiedThisOperation = operationExclusions
        var operationIdentities: Set<SessionSealIdentity> = []
        var authoritativeReceipt: SessionSealedReceipt?
        for receipt in catalog.reconciledSeals {
            let identity = SessionSealIdentity(
                libraryID: receipt.libraryID,
                sessionID: receipt.sessionID
            )
            guard receipt.libraryID == scope.libraryID else { continue }
            authoritativeReceipt = receipt
            guard !operationExclusions.contains(identity),
                  !previousPending.contains(identity),
                  operationIdentities.insert(identity).inserted
            else { continue }
            await deliverSealed(receipt, in: scope)
            notifiedThisOperation.insert(identity)
        }

        var nextPending: Set<SessionSealIdentity>
        switch catalog.inspectionStatus {
        case .complete:
            nextPending = previousPending.intersection(currentPending)
        case .blocked:
            // An incomplete scan cannot prove that an earlier cleanup
            // obligation disappeared.
            nextPending = previousPending
        }
        // A cleanup item may suppress a later retry only after its receipt was
        // actually offered by this feature instance. A malformed adapter that
        // reports cleanup without the matching receipt must not strand the
        // committed Session forever.
        nextPending.formUnion(currentPending.intersection(notifiedThisOperation))
        // A blocked/inconsistent fake or future adapter must not grow the
        // in-memory dedupe authority beyond the same finite staging budget.
        guard nextPending.count <= RecordingRecoveryCatalog.maximumEntryCount else {
            return authoritativeReceipt
        }
        pendingCleanupNotifications = nextPending
        return authoritativeReceipt
    }

    private func deliverSealed(
        _ receipt: SessionSealedReceipt,
        in scope: LibraryScope
    ) async {
        guard receipt.libraryID == scope.libraryID else { return }
        await sealedNotificationChannel.send(receipt)
    }

    private func addStateSubscriber(
        _ continuation: AsyncStream<RecordingFeatureState>.Continuation
    ) {
        let id = nextSubscriberID
        nextSubscriberID &+= 1
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeStateSubscriber(id) }
        }
        stateContinuations[id] = continuation
        continuation.yield(state)
    }

    private func removeStateSubscriber(_ id: UInt64) {
        stateContinuations.removeValue(forKey: id)
    }

}

private struct SessionSealIdentity: Hashable {
    let libraryID: LibraryID
    let sessionID: SessionID
}

private extension CaptureObservation {
    var embeddedRecordingID: RecordingID? {
        switch self {
        case let .sealCandidate(candidate): try? RecordingID(candidate.recordingID)
        case let .discarded(recordingID): recordingID
        case let .recoveryRequired(item): item.recordingID
        case .progress, .muteChanged, .finishing, .sealing:
            nil
        }
    }
}
