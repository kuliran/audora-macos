import AudoraApplication
import AudoraDomain
import XCTest

final class RecordingFeatureTests: XCTestCase {
    func testApplicationPromotesStagedSealCandidateBeforePublication() async throws {
        let capture = FakeAudioCapturePort()
        let feature = makeFeature(capture: capture)
        let scope = LibraryScope(libraryID: try libraryID())
        await feature.send(.selectLibrary(.writable(scope)))
        await feature.send(.record)
        let latestRequest = await capture.latestRequest
        let request = try XCTUnwrap(latestRequest)
        try await eventually {
            if case .active = await feature.currentState { return true }
            return false
        }

        let candidate = stagedCandidate(request: request, frameCount: 16_000)
        await capture.emit(.sealCandidate(candidate))

        try await eventually {
            if case .completed = await feature.currentState { return true }
            return false
        }
        let capturedPublications = await capture.publications
        let publication = try XCTUnwrap(capturedPublications.last)
        XCTAssertEqual(publication.candidate, candidate)
        XCTAssertEqual(publication.session.sessionID, request.sessionID)
        XCTAssertEqual(publication.session.audio.frameCount, 16_000)
        XCTAssertEqual(publication.session.audio.canonicalAudioPath.description, "audio/audio.wav")
    }

    func testMalformedStagedSealCandidateIsNeverPublishedAndRemainsRecoverable() async throws {
        let capture = FakeAudioCapturePort()
        let feature = makeFeature(capture: capture)
        await feature.send(.selectLibrary(.writable(LibraryScope(libraryID: try libraryID()))))
        await feature.send(.record)
        let latestRequest = await capture.latestRequest
        let request = try XCTUnwrap(latestRequest)
        try await eventually {
            if case .active = await feature.currentState { return true }
            return false
        }

        let valid = stagedCandidate(request: request, frameCount: 16_000)
        let malformed = StagedRecordingSealCandidate(
            recordingID: valid.recordingID,
            sessionID: valid.sessionID,
            libraryID: valid.libraryID,
            startedAt: valid.startedAt,
            terminalReason: valid.terminalReason,
            sourceKind: valid.sourceKind,
            canonicalAudioPath: "../audio.wav",
            sampleRateHz: valid.sampleRateHz,
            channelCount: valid.channelCount,
            encoding: valid.encoding,
            frameCount: valid.frameCount,
            canonicalSHA256: valid.canonicalSHA256,
            unavailableIntervals: valid.unavailableIntervals
        )
        await capture.emit(.sealCandidate(malformed))

        try await eventually {
            if case .recoveryRequired = await feature.currentState { return true }
            return false
        }
        let publications = await capture.publications
        let preserved = await capture.preservedRecordingIDs
        XCTAssertEqual(publications, [])
        XCTAssertEqual(preserved, [request.recordingID])
    }

    func testStateStreamKeepsOnlyNewestSnapshotForSlowSubscriber() async throws {
        let capture = FakeAudioCapturePort()
        let feature = makeFeature(capture: capture)
        var iterator = feature.states.makeAsyncIterator()
        _ = await iterator.next()
        await feature.send(.selectLibrary(.writable(LibraryScope(libraryID: try libraryID()))))
        await feature.send(.record)
        try await eventually {
            if case .active = await feature.currentState { return true }
            return false
        }
        for frame in 1...100 {
            await capture.emit(.progress(frameCount: UInt64(frame), level: .measured(0.25)))
        }
        try await eventually {
            (try? await recordingSnapshot(of: feature).elapsedFrames) == 100
        }

        guard case let .active(snapshot, _) = await iterator.next() else {
            return XCTFail("slow subscriber did not receive the newest state")
        }
        XCTAssertEqual(snapshot.elapsedFrames, 100)
    }

    func testTwoTakesReachAStalledSealedSessionSubscriberInFIFOOrder() async throws {
        let capture = FakeAudioCapturePort()
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(
                recordings: try (0..<2).map(indexedRecordingID),
                sessions: try (0..<2).map(indexedSessionID)
            ),
            activity: LibraryActivityCoordinator()
        )
        var notifications = feature.sealedSessions.makeAsyncIterator()
        await feature.send(
            .selectLibrary(.writable(LibraryScope(libraryID: try libraryID())))
        )

        var expected: [SessionSealedReceipt] = []
        for publicationIndex in 0..<2 {
            await feature.send(.record)
            let capturedRequest = await capture.latestRequest
            let request = try XCTUnwrap(capturedRequest)
            await capture.emit(
                .sealCandidate(stagedCandidate(request: request, frameCount: 16_000))
            )
            expected.append(try sealedReceipt(request: request, frameCount: 16_000))
            if publicationIndex == 0 {
                try await eventually {
                    guard case let .completed(snapshot, _) = await feature.currentState else {
                        return false
                    }
                    return snapshot.receipt.sessionID == request.sessionID
                }
            } else {
                try await eventually { await capture.publications.count == 2 }
            }
        }

        for _ in 0..<100 { await Task.yield() }
        let first = await notifications.next()
        guard first == expected[0] else {
            return XCTFail("stalled subscriber lost or reordered the first sealed Session")
        }
        let expectedSecond = expected[1]
        try await eventually {
            guard case let .completed(snapshot, _) = await feature.currentState else {
                return false
            }
            return snapshot.receipt.sessionID == expectedSecond.sessionID
        }
        let second = await notifications.next()
        XCTAssertEqual(second, expectedSecond)
    }

    func testSealedNotificationCapacityBackpressuresInsteadOfDropping() async throws {
        let capture = FakeAudioCapturePort()
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(
                recordings: try (0..<2).map(indexedRecordingID),
                sessions: try (0..<2).map(indexedSessionID)
            ),
            activity: LibraryActivityCoordinator()
        )
        var notifications = feature.sealedSessions.makeAsyncIterator()
        await feature.send(.selectLibrary(.writable(LibraryScope(libraryID: try libraryID()))))

        await feature.send(.record)
        let capturedFirstRequest = await capture.latestRequest
        let firstRequest = try XCTUnwrap(capturedFirstRequest)
        await capture.emit(.sealCandidate(stagedCandidate(request: firstRequest, frameCount: 16_000)))
        try await eventually {
            guard case let .completed(snapshot, _) = await feature.currentState else {
                return false
            }
            return snapshot.receipt.sessionID == firstRequest.sessionID
        }

        await feature.send(.record)
        let capturedSecondRequest = await capture.latestRequest
        let secondRequest = try XCTUnwrap(capturedSecondRequest)
        await capture.emit(.sealCandidate(stagedCandidate(request: secondRequest, frameCount: 16_000)))
        try await eventually { await capture.publications.count == 2 }
        for _ in 0..<100 { await Task.yield() }
        let blockedState = await feature.currentState
        guard case let .sealing(blockedSnapshot, reason) = blockedState else {
            return XCTFail("second publication did not remain at the delivery boundary")
        }
        XCTAssertEqual(blockedSnapshot.sessionID, secondRequest.sessionID)
        XCTAssertEqual(reason, .userStop)

        let firstNotification = await notifications.next()
        XCTAssertEqual(firstNotification?.sessionID, firstRequest.sessionID)
        try await eventually {
            guard case let .completed(snapshot, _) = await feature.currentState else {
                return false
            }
            return snapshot.receipt.sessionID == secondRequest.sessionID
        }
        let secondNotification = await notifications.next()
        XCTAssertEqual(secondNotification?.sessionID, secondRequest.sessionID)
    }

    func testTwoTakesCompleteWhenThereIsNoSealedNotificationSubscriber() async throws {
        let capture = FakeAudioCapturePort()
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(
                recordings: try (0..<2).map(indexedRecordingID),
                sessions: try (0..<2).map(indexedSessionID)
            ),
            activity: LibraryActivityCoordinator()
        )
        await feature.send(.selectLibrary(.writable(LibraryScope(libraryID: try libraryID()))))

        for index in 0..<2 {
            await feature.send(.record)
            let capturedRequest = await capture.latestRequest
            let request = try XCTUnwrap(capturedRequest)
            await capture.emit(.sealCandidate(stagedCandidate(request: request, frameCount: 16_000)))
            try await eventually {
                guard case let .completed(snapshot, _) = await feature.currentState else {
                    return false
                }
                return snapshot.receipt.sessionID == request.sessionID
            }
            let publicationCount = await capture.publications.count
            XCTAssertEqual(publicationCount, index + 1)
        }
    }

    func testCancellingStalledSubscriberReleasesBackpressuredPublication() async throws {
        let capture = FakeAudioCapturePort()
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(
                recordings: try (0..<3).map(indexedRecordingID),
                sessions: try (0..<3).map(indexedSessionID)
            ),
            activity: LibraryActivityCoordinator()
        )
        let received = ReceiptCollector()
        let consumer = Task {
            var iterator = feature.sealedSessions.makeAsyncIterator()
            if let receipt = await iterator.next() {
                await received.append(receipt)
            }
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            withExtendedLifetime(iterator) {}
        }
        for _ in 0..<20 { await Task.yield() }
        await feature.send(.selectLibrary(.writable(LibraryScope(libraryID: try libraryID()))))

        var requests: [MicrophoneRecordingRequest] = []
        for index in 0..<3 {
            await feature.send(.record)
            let capturedRequest = await capture.latestRequest
            let request = try XCTUnwrap(capturedRequest)
            requests.append(request)
            await capture.emit(.sealCandidate(stagedCandidate(request: request, frameCount: 16_000)))
            if index == 0 {
                try await eventually { await received.values.count == 1 }
            }
            if index < 2 {
                try await eventually {
                    guard case let .completed(snapshot, _) = await feature.currentState else {
                        return false
                    }
                    return snapshot.receipt.sessionID == request.sessionID
                }
            } else {
                try await eventually { await capture.publications.count == 3 }
            }
        }
        for _ in 0..<100 { await Task.yield() }
        let blockedState = await feature.currentState
        guard case let .sealing(blockedSnapshot, reason) = blockedState else {
            let publicationCount = await capture.publications.count
            return XCTFail(
                "third publication did not remain at the delivery boundary; " +
                    "publications=\(publicationCount), state=\(blockedState)"
            )
        }
        XCTAssertEqual(blockedSnapshot.sessionID, requests[2].sessionID)
        XCTAssertEqual(reason, .userStop)

        consumer.cancel()
        await consumer.value
        let finalSessionID = requests[2].sessionID
        try await eventually {
            guard case let .completed(snapshot, _) = await feature.currentState else {
                return false
            }
            return snapshot.receipt.sessionID == finalSessionID
        }
    }

    func testFeatureDeinitFinishesWaitingSealedNotificationIterator() async {
        var feature: DefaultRecordingFeature? = DefaultRecordingFeature(
            capture: FakeAudioCapturePort(),
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(recordings: [], sessions: []),
            activity: LibraryActivityCoordinator()
        )
        let notifications = feature!.sealedSessions
        let waiting = Task { () -> SessionSealedReceipt? in
            var iterator = notifications.makeAsyncIterator()
            return await iterator.next()
        }
        for _ in 0..<20 { await Task.yield() }
        feature = nil
        let finishedValue = await waiting.value
        XCTAssertNil(finishedValue)
    }

    func testOnlyOneConcurrentSealedNotificationIteratorOwnsBackpressure() async throws {
        let capture = FakeAudioCapturePort()
        let feature = makeFeature(capture: capture)
        let notifications = feature.sealedSessions
        var owner = notifications.makeAsyncIterator()
        var additional = notifications.makeAsyncIterator()
        let additionalValue = await additional.next()
        XCTAssertNil(additionalValue)

        await feature.send(.selectLibrary(.writable(LibraryScope(libraryID: try libraryID()))))
        await feature.send(.record)
        let capturedRequest = await capture.latestRequest
        let request = try XCTUnwrap(capturedRequest)
        await capture.emit(.sealCandidate(stagedCandidate(request: request, frameCount: 16_000)))
        let ownerValue = await owner.next()
        XCTAssertEqual(ownerValue, try sealedReceipt(request: request, frameCount: 16_000))
    }

    func testBlockedRecoveryInspectionNeverLooksIdleOrStartsCapture() async throws {
        let capture = FakeAudioCapturePort(
            recovery: RecordingRecoveryCatalog(
                items: [],
                inspectionStatus: .blocked(.stagingListingUnavailable)
            )
        )
        let feature = makeFeature(capture: capture)

        await feature.send(.selectLibrary(.writable(LibraryScope(libraryID: try libraryID()))))

        guard case let .recoveryRequired(catalog) = await feature.currentState else {
            return XCTFail("inspection failure was presented as a clear Library")
        }
        XCTAssertEqual(catalog.inspectionStatus, .blocked(.stagingListingUnavailable))
        await feature.send(.record)
        let startedFeedCount = await capture.startedFeedCount
        XCTAssertEqual(startedFeedCount, 0)
    }

    func testRecoveryCatalogBoundsEachPublicInventory() throws {
        let item = RecordingRecoveryItem(
            recordingID: try recordingID(),
            durableFrameCount: 0,
            availability: .discardOnly
        )
        let request = MicrophoneRecordingRequest(
            libraryScope: LibraryScope(libraryID: try libraryID()),
            recordingID: try recordingID(),
            sessionID: try sessionID(),
            startedAt: try instant()
        )
        let receipt = try sealedReceipt(request: request, frameCount: 16_000)

        for catalog in [
            RecordingRecoveryCatalog(items: Array(repeating: item, count: 129)),
            RecordingRecoveryCatalog(
                items: [],
                reconciledSeals: Array(repeating: receipt, count: 129)
            ),
        ] {
            XCTAssertEqual(catalog.items, [])
            XCTAssertEqual(catalog.reconciledSeals, [])
            XCTAssertEqual(
                catalog.inspectionStatus,
                .blocked(.stagingListingUnavailable)
            )
            XCTAssertFalse(catalog.isClear)
        }

        let boundary = RecordingRecoveryCatalog(
            items: Array(repeating: item, count: 128),
            reconciledSeals: Array(repeating: receipt, count: 128)
        )
        XCTAssertEqual(boundary.items.count, 128)
        XCTAssertEqual(boundary.reconciledSeals.count, 128)
        XCTAssertEqual(boundary.inspectionStatus, .complete)
    }

    func testOversizedRecoveryPortFailsClosedAndNeverStartsOrNotifies() async throws {
        let item = RecordingRecoveryItem(
            recordingID: try recordingID(),
            durableFrameCount: 0,
            availability: .discardOnly
        )
        let capture = FakeAudioCapturePort(
            recovery: RecordingRecoveryCatalog(
                items: Array(repeating: item, count: 129)
            )
        )
        let feature = makeFeature(capture: capture)
        let collector = ReceiptCollector()
        let collection = Task {
            for await receipt in feature.sealedSessions {
                await collector.append(receipt)
            }
        }
        for _ in 0..<20 { await Task.yield() }

        await feature.send(.selectLibrary(.writable(LibraryScope(libraryID: try libraryID()))))
        guard case let .recoveryRequired(catalog) = await feature.currentState else {
            return XCTFail("oversized recovery inventory appeared writable")
        }
        XCTAssertEqual(catalog.items, [])
        XCTAssertEqual(catalog.reconciledSeals, [])
        XCTAssertEqual(catalog.inspectionStatus, .blocked(.stagingListingUnavailable))
        await feature.send(.record)
        let startedFeedCount = await capture.startedFeedCount
        XCTAssertEqual(startedFeedCount, 0)
        for _ in 0..<20 { await Task.yield() }
        let receipts = await collector.values
        XCTAssertEqual(receipts, [])
        collection.cancel()
        await collection.value
    }

    func testUnsupportedRecoveryItemRejectsEveryMutationCommand() async throws {
        let item = RecordingRecoveryItem(
            recordingID: try recordingID(),
            durableFrameCount: 0,
            availability: .readOnlyUnsupported
        )
        let capture = FakeAudioCapturePort(
            recovery: RecordingRecoveryCatalog(items: [item])
        )
        let feature = makeFeature(capture: capture)
        await feature.send(.selectLibrary(.writable(LibraryScope(libraryID: try libraryID()))))

        await feature.send(.sealRecovered(item.recordingID))
        await feature.send(.discardRecovered(item.recordingID))

        let resolutionCount = await capture.recoveryResolutionCount
        XCTAssertEqual(resolutionCount, 0)
        guard case .recoveryRequired = await feature.currentState else {
            return XCTFail("unsupported Recording authority became mutable")
        }
    }

    func testLiveLifecycleTracksWarningsMuteConfirmationAndExactlyOneSeal() async throws {
        let capture = FakeAudioCapturePort()
        let feature = makeFeature(capture: capture)
        let scope = LibraryScope(libraryID: try libraryID())
        await feature.send(.selectLibrary(.writable(scope)))
        let idleState = await feature.currentState
        XCTAssertEqual(idleState, .idle)

        let receipts = ReceiptCollector()
        let receiptTask = Task {
            for await receipt in feature.sealedSessions {
                await receipts.append(receipt)
            }
        }
        await feature.send(.record)
        let latestRequest = await capture.latestRequest
        let request = try XCTUnwrap(latestRequest)
        try await eventually {
            if case .active = await feature.currentState { return true }
            return false
        }

        await capture.emit(.progress(frameCount: 38_399_999, level: .measured(0.25)))
        try await eventually { await recordingPhase(of: feature) == .ordinary }
        let oldNotice = try await recordingSnapshot(of: feature).noticeID
        await capture.emit(.progress(frameCount: 38_400_000, level: .measured(0.5)))
        try await eventually { await recordingPhase(of: feature) == .fiveMinuteWarning }
        let warningNotice = try await recordingSnapshot(of: feature).noticeID
        XCTAssertGreaterThan(warningNotice, oldNotice)

        await feature.send(.setMuted(true))
        let changingMute = try await recordingSnapshot(of: feature).mute
        XCTAssertEqual(changingMute, .changing(toMuted: true))
        await capture.emit(.muteChanged(isMuted: true, effectiveFrame: 38_416_000))
        try await eventually { try await recordingSnapshot(of: feature).mute == .muted }

        await feature.send(.cancel)
        await capture.emit(.progress(frameCount: 38_432_000, level: .unavailable(.muted)))
        try await eventually {
            guard case let .active(snapshot, confirmation) = await feature.currentState else {
                return false
            }
            return confirmation == .discardRecording && snapshot.elapsedFrames == 38_432_000
        }
        let commandsBeforeKeep = await capture.commands
        XCTAssertFalse(commandsBeforeKeep.contains(.discardConfirmed))
        await feature.send(.keepRecording)

        await feature.send(.stop)
        let receipt = try sealedReceipt(request: request, frameCount: 38_432_000)
        let candidate = stagedCandidate(request: request, frameCount: 38_432_000)
        await capture.emit(.sealCandidate(candidate))
        await capture.emit(.sealCandidate(candidate))
        try await eventually {
            if case .completed = await feature.currentState { return true }
            return false
        }
        for _ in 0..<20 { await Task.yield() }
        let publishedReceipts = await receipts.values
        XCTAssertEqual(publishedReceipts, [receipt])
        receiptTask.cancel()
    }

    func testDurationLimitNoticePersistsAfterCompletion() async throws {
        let capture = FakeAudioCapturePort()
        let feature = makeFeature(capture: capture)
        await feature.send(.selectLibrary(.writable(LibraryScope(libraryID: try libraryID()))))
        await feature.send(.record)
        let latestRequest = await capture.latestRequest
        let request = try XCTUnwrap(latestRequest)
        try await eventually {
            if case .active = await feature.currentState { return true }
            return false
        }
        await capture.emit(
            .progress(
                frameCount: CanonicalRecordingLimits.oneMinuteCountdownFrame,
                level: .measured(0.1)
            )
        )
        try await eventually {
            await recordingPhase(of: feature) == .oneMinuteCountdown(secondsRemaining: 60)
        }
        await capture.emit(
            .finishing(
                reason: .durationLimit,
                frameCount: CanonicalRecordingLimits.maximumFrames
            )
        )
        await capture.emit(
            .sealCandidate(
                stagedCandidate(
                    request: request,
                    frameCount: CanonicalRecordingLimits.maximumFrames,
                    terminalReason: .durationLimit
                )
            )
        )
        try await eventually {
            guard case let .completed(_, notice) = await feature.currentState else {
                return false
            }
            return notice == .durationLimit
        }
    }

    func testRecoveryKeepsSharedActivityLeaseUntilResolved() async throws {
        let item = RecordingRecoveryItem(
            recordingID: try recordingID(),
            sessionID: try sessionID(),
            startedAt: try instant(),
            durableFrameCount: 16_000,
            availability: .sealOrDiscard
        )
        let capture = FakeAudioCapturePort(recovery: RecordingRecoveryCatalog(items: [item]))
        let activity = LibraryActivityCoordinator()
        let feature = makeFeature(capture: capture, activity: activity)
        let scope = LibraryScope(libraryID: try libraryID())
        await feature.send(.selectLibrary(.writable(scope)))
        let activeKind = await activity.activeKind
        let selectionLease = await activity.acquireSelectionMutation()
        XCTAssertEqual(activeKind, .recording)
        XCTAssertNil(selectionLease)

        let recoveryRequest = MicrophoneRecordingRequest(
            libraryScope: scope,
            recordingID: item.recordingID,
            sessionID: try XCTUnwrap(item.sessionID),
            startedAt: try XCTUnwrap(item.startedAt)
        )
        await capture.setRecoveryOutcome(
            .sealCandidate(stagedCandidate(request: recoveryRequest, frameCount: 16_000))
        )
        await feature.send(.sealRecovered(item.recordingID))
        let resolvedKind = await activity.activeKind
        XCTAssertNil(resolvedKind)
        guard case .completed = await feature.currentState else {
            return XCTFail("expected completed recovery")
        }
    }

    func testAnotherTakeAllocatesDistinctRecordingAndSessionIdentities() async throws {
        let capture = FakeAudioCapturePort()
        let ids = QueueRecordingIDs(
            recordings: [try recordingID(), try RecordingID("rec-20260830T120001000Z-4GHJ")],
            sessions: [try sessionID(), try SessionID("ses-20260830T120001000Z-5JKM")]
        )
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: FixedRecordingClock(),
            idGenerator: ids,
            activity: LibraryActivityCoordinator()
        )
        await feature.send(.selectLibrary(.writable(LibraryScope(libraryID: try libraryID()))))
        await feature.send(.record)
        let firstRequest = await capture.latestRequest
        let first = try XCTUnwrap(firstRequest)
        try await eventually {
            if case .active = await feature.currentState { return true }
            return false
        }
        await capture.emit(.sealCandidate(stagedCandidate(request: first, frameCount: 16_000)))
        try await eventually {
            if case .completed = await feature.currentState { return true }
            return false
        }
        await feature.send(.record)
        try await eventually { await capture.requests.count == 2 }
        let secondRequest = await capture.latestRequest
        let second = try XCTUnwrap(secondRequest)
        XCTAssertNotEqual(first.recordingID, second.recordingID)
        XCTAssertNotEqual(first.sessionID, second.sessionID)
    }

    func testLosingStopCannotOverwriteDurationLimitSeal() async throws {
        let capture = SuspendingCommandCapturePort()
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(
                recordings: [try recordingID()],
                sessions: [try sessionID()]
            ),
            activity: LibraryActivityCoordinator()
        )
        await feature.send(.selectLibrary(.writable(LibraryScope(libraryID: try libraryID()))))
        await feature.send(.record)
        try await eventually { await capture.hasFeed }
        let capturedRequest = await capture.latestRequest
        let request = try XCTUnwrap(capturedRequest)

        let stop = Task { await feature.send(.stop) }
        try await eventually { await capture.pendingCommand == .stop }
        await capture.emit(
            .finishing(
                reason: .durationLimit,
                frameCount: CanonicalRecordingLimits.maximumFrames
            )
        )
        await capture.emit(
            .sealCandidate(
                stagedCandidate(
                    request: request,
                    frameCount: CanonicalRecordingLimits.maximumFrames,
                    terminalReason: .durationLimit
                )
            )
        )
        try await eventually {
            if case .completed = await feature.currentState { return true }
            return false
        }
        await capture.resumeCommand(with: .rejected(.staleCommand))
        await stop.value
        guard case let .completed(_, notice) = await feature.currentState else {
            return XCTFail("losing Stop overwrote the terminal success")
        }
        XCTAssertEqual(notice, .durationLimit)
    }

    func testLosingDiscardCannotOverwriteASealThatAlreadyWon() async throws {
        let capture = SuspendingCommandCapturePort()
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(
                recordings: [try recordingID()],
                sessions: [try sessionID()]
            ),
            activity: LibraryActivityCoordinator()
        )
        await feature.send(.selectLibrary(.writable(LibraryScope(libraryID: try libraryID()))))
        await feature.send(.record)
        try await eventually { await capture.hasFeed }
        let capturedRequest = await capture.latestRequest
        let request = try XCTUnwrap(capturedRequest)
        await feature.send(.cancel)
        let discard = Task { await feature.send(.discardRecording) }
        try await eventually { await capture.pendingCommand == .discardConfirmed }
        await capture.emit(.sealCandidate(stagedCandidate(request: request, frameCount: 16_000)))
        try await eventually {
            if case .completed = await feature.currentState { return true }
            return false
        }
        await capture.resumeCommand(with: .rejected(.staleCommand))
        await discard.value
        guard case .completed = await feature.currentState else {
            return XCTFail("losing Discard restored stale active state")
        }
    }

    func testRecoveryResolutionIsObservableAndFencesConcurrentActions() async throws {
        let item = RecordingRecoveryItem(
            recordingID: try recordingID(),
            sessionID: try sessionID(),
            startedAt: try instant(),
            durableFrameCount: 16_000,
            availability: .sealOrDiscard
        )
        let capture = SuspendingRecoveryCapturePort(item: item)
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(recordings: [], sessions: []),
            activity: LibraryActivityCoordinator()
        )
        await feature.send(.selectLibrary(.writable(LibraryScope(libraryID: try libraryID()))))
        let seal = Task { await feature.send(.sealRecovered(item.recordingID)) }
        try await eventually {
            if case .resolvingRecovery = await feature.currentState { return true }
            return false
        }
        await feature.send(.discardRecovered(item.recordingID))
        let resolveCallCount = await capture.resolveCallCount
        XCTAssertEqual(resolveCallCount, 1)
        await capture.resume(with: .failed(.sealValidationFailedRecoverable))
        await seal.value
        guard case .recoveryRequired = await feature.currentState else {
            return XCTFail("failed resolution did not restore the exact catalog")
        }
    }

    func testSealedEventDeduplicationIsScopedByLibraryIdentity() async throws {
        let capture = FakeAudioCapturePort()
        let secondRecording = try RecordingID("rec-20260830T120001000Z-4GHJ")
        let sharedSession = try sessionID()
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(
                recordings: [try recordingID(), secondRecording],
                sessions: [sharedSession, sharedSession]
            ),
            activity: LibraryActivityCoordinator()
        )
        let collector = ReceiptCollector()
        let collection = Task {
            for await receipt in feature.sealedSessions { await collector.append(receipt) }
        }
        let firstScope = LibraryScope(libraryID: try libraryID())
        let secondScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120001000Z-4DEF")
        )
        for scope in [firstScope, secondScope] {
            await feature.send(.selectLibrary(.writable(scope)))
            await feature.send(.record)
            let capturedRequest = await capture.latestRequest
            let request = try XCTUnwrap(capturedRequest)
            try await eventually {
                if case .active = await feature.currentState { return true }
                return false
            }
            await capture.emit(
                .sealCandidate(stagedCandidate(request: request, frameCount: 16_000))
            )
            try await eventually {
                if case .completed = await feature.currentState { return true }
                return false
            }
        }
        try await eventually { await collector.values.count == 2 }
        let publishedSessions = await collector.values.map(\.sessionID)
        XCTAssertEqual(publishedSessions, [sharedSession, sharedSession])
        let publishedLibraries = await collector.values.map(\.libraryID)
        XCTAssertEqual(publishedLibraries, [firstScope.libraryID, secondScope.libraryID])
        collection.cancel()
    }

    func testCommittedCleanupRecoveryAndReselectionPublishOneReceipt() async throws {
        let scope = LibraryScope(libraryID: try libraryID())
        let request = MicrophoneRecordingRequest(
            libraryScope: scope,
            recordingID: try recordingID(),
            sessionID: try sessionID(),
            startedAt: try instant()
        )
        let expected = try sealedReceipt(request: request, frameCount: 16_000)
        let capture = CommittedCleanupCapturePort(
            request: request,
            receipt: expected
        )
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(recordings: [], sessions: []),
            activity: LibraryActivityCoordinator()
        )
        let collector = ReceiptCollector()
        let collection = Task {
            for await receipt in feature.sealedSessions {
                await collector.append(receipt)
            }
        }
        for _ in 0..<20 { await Task.yield() }

        await feature.send(.selectLibrary(.writable(scope)))
        try await eventually { await collector.values == [expected] }
        guard case .recoveryRequired = await feature.currentState else {
            return XCTFail("committed cleanup was not retained for explicit resolution")
        }

        await feature.send(.sealRecovered(request.recordingID))
        try await eventually {
            guard case let .completed(snapshot, _) = await feature.currentState else {
                return false
            }
            return snapshot.receipt == expected
        }
        await feature.send(.selectLibrary(.writable(scope)))
        await feature.send(.selectLibrary(.writable(scope)))
        for _ in 0..<100 { await Task.yield() }
        let finallyPublished = await collector.values
        XCTAssertEqual(finallyPublished, [expected])
        collection.cancel()
        await collection.value
    }

    func testCancelledSelectionCannotDropCommittedCleanupReceipt() async throws {
        let scope = LibraryScope(libraryID: try libraryID())
        let request = MicrophoneRecordingRequest(
            libraryScope: scope,
            recordingID: try recordingID(),
            sessionID: try sessionID(),
            startedAt: try instant()
        )
        let expected = try sealedReceipt(request: request, frameCount: 16_000)
        let cleanupItem = RecordingRecoveryItem(
            recordingID: request.recordingID,
            sessionID: request.sessionID,
            startedAt: request.startedAt,
            durableFrameCount: expected.frameCount,
            availability: .committedCleanup
        )
        let capture = SuspendingInspectionCapturePort(suspending: scope)
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(recordings: [], sessions: []),
            activity: LibraryActivityCoordinator()
        )
        let collector = ReceiptCollector()
        let collection = Task {
            for await receipt in feature.sealedSessions {
                await collector.append(receipt)
            }
        }
        for _ in 0..<20 { await Task.yield() }

        let selection = Task { await feature.send(.selectLibrary(.writable(scope))) }
        try await eventually { await capture.isInspectionWaiting }
        selection.cancel()
        await capture.resumeInspection(
            with: RecordingRecoveryCatalog(
                items: [cleanupItem],
                reconciledSeals: [expected]
            )
        )
        await selection.value

        try await eventually { await collector.values == [expected] }
        guard case let .recoveryRequired(catalog) = await feature.currentState else {
            return XCTFail("cancelled selection hid committed cleanup authority")
        }
        XCTAssertEqual(catalog.items, [cleanupItem])
        collection.cancel()
        await collection.value
    }

    func testLiveInstalledSessionNotifiesOnceWhileCleanupRemainsRecoverable() async throws {
        let scope = LibraryScope(libraryID: try libraryID())
        let request = MicrophoneRecordingRequest(
            libraryScope: scope,
            recordingID: try recordingID(),
            sessionID: try sessionID(),
            startedAt: try instant()
        )
        let expected = try sealedReceipt(request: request, frameCount: 16_000)
        let cleanupItem = RecordingRecoveryItem(
            recordingID: request.recordingID,
            sessionID: request.sessionID,
            startedAt: request.startedAt,
            durableFrameCount: expected.frameCount,
            availability: .committedCleanup
        )
        let capture = FakeAudioCapturePort(
            recoveryAfterFirstPublication: RecordingRecoveryCatalog(
                items: [cleanupItem],
                reconciledSeals: [expected]
            )
        )
        let feature = makeFeature(capture: capture)
        let collector = ReceiptCollector()
        let collection = Task {
            for await receipt in feature.sealedSessions {
                await collector.append(receipt)
            }
        }
        for _ in 0..<20 { await Task.yield() }

        await feature.send(.selectLibrary(.writable(scope)))
        await feature.send(.record)
        await capture.emit(.sealCandidate(stagedCandidate(request: request, frameCount: 16_000)))
        try await eventually { await collector.values == [expected] }
        guard case let .recoveryRequired(catalog) = await feature.currentState else {
            return XCTFail("committed Session cleanup was reported complete")
        }
        XCTAssertEqual(catalog.items, [cleanupItem])

        await capture.setRecoveryOutcome(
            .sealCandidate(stagedCandidate(request: request, frameCount: 16_000))
        )
        await feature.send(.sealRecovered(request.recordingID))
        try await eventually {
            guard case let .completed(snapshot, _) = await feature.currentState else {
                return false
            }
            return snapshot.receipt == expected
        }
        await feature.send(.selectLibrary(.writable(scope)))
        for _ in 0..<100 { await Task.yield() }
        let receipts = await collector.values
        XCTAssertEqual(receipts, [expected])
        collection.cancel()
        await collection.value
    }

    func testConcurrentRecordCommandsAcquireAndBeginExactlyOnce() async throws {
        let capture = FakeAudioCapturePort()
        let clock = SuspendingRecordingClock()
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: clock,
            idGenerator: QueueRecordingIDs(
                recordings: [try recordingID()],
                sessions: [try sessionID()]
            ),
            activity: LibraryActivityCoordinator()
        )
        await feature.send(.selectLibrary(.writable(LibraryScope(libraryID: try libraryID()))))

        let first = Task { await feature.send(.record) }
        try await eventually { await clock.isWaiting }
        let losing = Task { await feature.send(.record) }
        await losing.value
        let requestsBeforeResume = await capture.requests
        XCTAssertEqual(requestsBeforeResume.count, 0)

        await clock.resume()
        await first.value
        let completedRequests = await capture.requests
        XCTAssertEqual(completedRequests.count, 1)
    }

    func testSessionIdentityCollisionRegeneratesBeforeCaptureStarts() async throws {
        let firstSession = try sessionID()
        let secondSession = try SessionID("ses-20260830T120001000Z-5JKM")
        let capture = FakeAudioCapturePort(collisionsBeforeStart: 1)
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(
                recordings: [try recordingID()],
                sessions: [firstSession, secondSession]
            ),
            activity: LibraryActivityCoordinator()
        )
        await feature.send(.selectLibrary(.writable(LibraryScope(libraryID: try libraryID()))))
        await feature.send(.record)

        try await eventually {
            if case .active = await feature.currentState { return true }
            return false
        }
        let requests = await capture.requests
        let feedCount = await capture.startedFeedCount
        XCTAssertEqual(requests.map(\.sessionID), [firstSession, secondSession])
        XCTAssertEqual(feedCount, 1)
    }

    func testNewLibrarySelectionSupersedesPreBeginRecordAndReleasesItsLease() async throws {
        let capture = FakeAudioCapturePort()
        let clock = SuspendingRecordingClock()
        let secondScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120001000Z-4DEF")
        )
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: clock,
            idGenerator: QueueRecordingIDs(
                recordings: [try recordingID()],
                sessions: [try sessionID()]
            ),
            activity: LibraryActivityCoordinator()
        )
        await feature.send(.selectLibrary(.writable(LibraryScope(libraryID: try libraryID()))))

        let staleRecord = Task { await feature.send(.record) }
        try await eventually { await clock.isWaiting }
        await feature.send(.selectLibrary(.writable(secondScope)))
        await clock.resume()
        await staleRecord.value
        let staleRequests = await capture.requests
        XCTAssertEqual(staleRequests.count, 0)
        let selectedState = await feature.currentState
        XCTAssertEqual(selectedState, .idle)

        await feature.send(.record)
        let latestRequest = await capture.latestRequest
        let request = try XCTUnwrap(latestRequest)
        XCTAssertEqual(request.libraryScope, secondScope)
    }

    func testStaleLibraryInspectionCannotOverwriteNewerSelection() async throws {
        let firstScope = LibraryScope(libraryID: try libraryID())
        let secondScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120001000Z-4DEF")
        )
        let capture = SuspendingInspectionCapturePort(suspending: firstScope)
        let activity = CountingLibraryActivityCoordinator()
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(
                recordings: [try recordingID()],
                sessions: [try sessionID()]
            ),
            activity: activity
        )

        let staleSelection = Task { await feature.send(.selectLibrary(.writable(firstScope))) }
        try await eventually { await capture.isInspectionWaiting }
        await feature.send(.selectLibrary(.writable(secondScope)))
        let currentSelectionState = await feature.currentState
        XCTAssertEqual(currentSelectionState, .idle)
        await capture.resumeInspection(
            with: RecordingRecoveryCatalog(
                items: [
                    RecordingRecoveryItem(
                        recordingID: try recordingID(),
                        sessionID: try sessionID(),
                        startedAt: try instant(),
                        durableFrameCount: 16_000,
                        availability: .sealOrDiscard
                    ),
                ]
            )
        )
        await staleSelection.value
        let stableSelectionState = await feature.currentState
        XCTAssertEqual(stableSelectionState, .idle)

        await feature.send(.record)
        let latestRequest = await capture.latestRequest
        let request = try XCTUnwrap(latestRequest)
        XCTAssertEqual(request.libraryScope, secondScope)
        await capture.emit(.sealCandidate(stagedCandidate(request: request, frameCount: 16_000)))
        try await eventually {
            if case .completed = await feature.currentState { return true }
            return false
        }
        let leaseAudit = await activity.audit
        XCTAssertEqual(leaseAudit.acquired.sorted(), leaseAudit.released.sorted())
        XCTAssertEqual(Set(leaseAudit.released).count, leaseAudit.released.count)
    }

    func testRecordDuringSuspendedLibraryInspectionIsIgnoredWithoutFalseFailure() async throws {
        let scope = LibraryScope(libraryID: try libraryID())
        let capture = SuspendingInspectionCapturePort(suspending: scope)
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(
                recordings: [try recordingID()],
                sessions: [try sessionID()]
            ),
            activity: LibraryActivityCoordinator()
        )
        let selection = Task { await feature.send(.selectLibrary(.writable(scope))) }
        try await eventually { await capture.isInspectionWaiting }
        let selecting = await feature.currentState
        XCTAssertEqual(selecting, .selectingLibrary(scope))

        await feature.send(.record)
        let requestWhileSelecting = await capture.latestRequest
        XCTAssertNil(requestWhileSelecting)
        let stillSelecting = await feature.currentState
        XCTAssertEqual(stillSelecting, .selectingLibrary(scope))

        await capture.resumeInspection(with: RecordingRecoveryCatalog(items: []))
        await selection.value
        await feature.send(.record)
        let requestAfterSelection = await capture.latestRequest
        XCTAssertNotNil(requestAfterSelection)
    }

    func testStaleStartCannotCancelOrDoubleReleaseNewerStartAuthority() async throws {
        let firstScope = LibraryScope(libraryID: try libraryID())
        let secondScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120001000Z-4DEF")
        )
        let capture = FakeAudioCapturePort()
        let clock = FirstCallSuspendingRecordingClock()
        let ids = SuspendingRecordingIDs(
            recordingID: try recordingID(),
            sessionID: try sessionID()
        )
        let activity = CountingLibraryActivityCoordinator()
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: clock,
            idGenerator: ids,
            activity: activity
        )
        await feature.send(.selectLibrary(.writable(firstScope)))

        let staleStart = Task { await feature.send(.record) }
        try await eventually { await clock.firstCallIsWaiting }
        await feature.send(.selectLibrary(.writable(secondScope)))
        let currentStart = Task { await feature.send(.record) }
        try await eventually { await ids.recordingIDCallIsWaiting }

        await clock.resumeFirstCall()
        await staleStart.value
        await ids.resumeRecordingID()
        await currentStart.value
        let latestRequest = await capture.latestRequest
        let latest = try XCTUnwrap(latestRequest)
        XCTAssertEqual(latest.libraryScope, secondScope)

        await capture.emit(.sealCandidate(stagedCandidate(request: latest, frameCount: 16_000)))
        try await eventually {
            if case .completed = await feature.currentState { return true }
            return false
        }
        let leaseAudit = await activity.audit
        XCTAssertEqual(leaseAudit.acquired.sorted(), leaseAudit.released.sorted())
        XCTAssertEqual(Set(leaseAudit.released).count, leaseAudit.released.count)
    }

    func testSelectionDuringSuspendingTerminalReleaseTargetsTheNewLibrary() async throws {
        let firstScope = LibraryScope(libraryID: try libraryID())
        let secondScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120001000Z-4DEF")
        )
        let latestScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120002000Z-5ABC")
        )
        let capture = FakeAudioCapturePort()
        let activity = SuspendingReleaseLibraryActivityCoordinator()
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(
                recordings: try (0..<2).map(indexedRecordingID),
                sessions: try (0..<2).map(indexedSessionID)
            ),
            activity: activity
        )
        await feature.send(.selectLibrary(.writable(firstScope)))
        await activity.suspendNextRelease()

        await feature.send(.record)
        let capturedFirstRequest = await capture.latestRequest
        let firstRequest = try XCTUnwrap(capturedFirstRequest)
        await capture.emit(
            .sealCandidate(stagedCandidate(request: firstRequest, frameCount: 16_000))
        )
        try await eventually { await activity.isReleaseSuspended }

        await feature.send(.selectLibrary(.writable(secondScope)))
        await feature.send(.selectLibrary(.writable(latestScope)))
        await activity.resumeRelease()
        try await eventually {
            if case .idle = await feature.currentState { return true }
            return false
        }

        await feature.send(.record)
        let capturedSecondRequest = await capture.latestRequest
        let secondRequest = try XCTUnwrap(capturedSecondRequest)
        XCTAssertEqual(secondRequest.libraryScope, latestScope)
        let acquiredScopes = await activity.recordingScopes
        XCTAssertFalse(acquiredScopes.contains(secondScope))
    }

    func testShutdownReleasesHeldRecoveryLeaseBeforeFeatureReplacement() async throws {
        let scope = LibraryScope(libraryID: try libraryID())
        let recovery = RecordingRecoveryItem(
            recordingID: try recordingID(),
            sessionID: try sessionID(),
            startedAt: try instant(),
            durableFrameCount: 16_000,
            availability: .sealOrDiscard
        )
        let activity = LibraryActivityCoordinator()
        var feature: DefaultRecordingFeature? = DefaultRecordingFeature(
            capture: FakeAudioCapturePort(
                recovery: RecordingRecoveryCatalog(items: [recovery])
            ),
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(recordings: [], sessions: []),
            activity: activity
        )
        await feature?.send(.selectLibrary(.writable(scope)))
        let heldKind = await activity.activeKind
        XCTAssertEqual(heldKind, .recording)

        await feature?.shutdown()
        feature = nil
        let releasedKind = await activity.activeKind
        XCTAssertNil(releasedKind)

        let replacement = DefaultRecordingFeature(
            capture: FakeAudioCapturePort(),
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(
                recordings: [try recordingID()],
                sessions: [try sessionID()]
            ),
            activity: activity
        )
        await replacement.send(.selectLibrary(.writable(scope)))
        guard case .idle = await replacement.currentState else {
            return XCTFail("replacement feature could not acquire the released Library authority")
        }
    }

    func testStateSubscriptionsRacingAndFollowingShutdownFinishWithTerminalSnapshot() async throws {
        let feature = makeFeature(capture: FakeAudioCapturePort())
        let racingStream = feature.states

        await feature.shutdown()

        let lateStream = feature.states
        let racingProbe = RecordingStateStreamProbe()
        let lateProbe = RecordingStateStreamProbe()
        let racingConsumer = Task { await racingProbe.collect(racingStream) }
        let lateConsumer = Task { await lateProbe.collect(lateStream) }
        defer {
            racingConsumer.cancel()
            lateConsumer.cancel()
        }

        try await eventually {
            let racingFinished = await racingProbe.isFinished
            let lateFinished = await lateProbe.isFinished
            return racingFinished && lateFinished
        }
        let expected = RecordingFeatureState.unavailable(.noWritableLibrary)
        let racingSnapshot = await racingProbe.snapshot
        let lateSnapshot = await lateProbe.snapshot
        XCTAssertTrue(racingSnapshot.finished)
        XCTAssertEqual(racingSnapshot.values.last, expected)
        XCTAssertTrue(lateSnapshot.finished)
        XCTAssertEqual(lateSnapshot.values, [expected])
    }

    func testShutdownKeepsLeaseUntilActiveCaptureBecomesRecoverable() async throws {
        let scope = LibraryScope(libraryID: try libraryID())
        let capture = FakeAudioCapturePort()
        let activity = LibraryActivityCoordinator()
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(
                recordings: [try recordingID()],
                sessions: [try sessionID()]
            ),
            activity: activity
        )
        await feature.send(.selectLibrary(.writable(scope)))
        await feature.send(.record)
        let capturedRequest = await capture.latestRequest
        let request = try XCTUnwrap(capturedRequest)

        let shutdown = Task { await feature.shutdown() }
        let concurrentShutdown = Task { await feature.shutdown() }
        try await eventually { await capture.commands == [.stop] }
        let heldKind = await activity.activeKind
        XCTAssertEqual(heldKind, .recording)

        await capture.emit(
            .recoveryRequired(
                RecordingRecoveryItem(
                    recordingID: request.recordingID,
                    sessionID: request.sessionID,
                    startedAt: request.startedAt,
                    durableFrameCount: 16_000,
                    availability: .sealOrDiscard
                )
            )
        )
        await shutdown.value
        await concurrentShutdown.value
        let commands = await capture.commands
        XCTAssertEqual(commands, [.stop])
        let releasedKind = await activity.activeKind
        XCTAssertNil(releasedKind)
    }

    func testShutdownWaitsForInFlightAcquisitionAndNeverBeginsCapture() async throws {
        let scope = LibraryScope(libraryID: try libraryID())
        let capture = FakeAudioCapturePort()
        let activity = SuspendingAcquireLibraryActivityCoordinator()
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(
                recordings: [try recordingID()],
                sessions: [try sessionID()]
            ),
            activity: activity
        )
        await feature.send(.selectLibrary(.writable(scope)))
        await activity.suspendNextRecordingAcquire()
        let record = Task { await feature.send(.record) }
        try await eventually { await activity.isRecordingAcquireSuspended }

        let notifications = feature.sealedSessions
        let notificationFinished = Task { () -> SessionSealedReceipt? in
            var iterator = notifications.makeAsyncIterator()
            return await iterator.next()
        }
        let shutdown = Task { await feature.shutdown() }
        let notificationValue = await notificationFinished.value
        XCTAssertNil(notificationValue)
        let heldKind = await activity.activeKind
        XCTAssertEqual(heldKind, .recording)
        let requestsBeforeResume = await capture.requests
        XCTAssertEqual(requestsBeforeResume.count, 0)

        await activity.resumeRecordingAcquire()
        await record.value
        await shutdown.value
        let releasedKind = await activity.activeKind
        XCTAssertNil(releasedKind)
        let requestsAfterShutdown = await capture.requests
        XCTAssertEqual(requestsAfterShutdown.count, 0)
    }

    func testShutdownDoesNotReleaseStartingCaptureBeforeDiscardAcknowledgement() async throws {
        let scope = LibraryScope(libraryID: try libraryID())
        let capture = SuspendingBeginCapturePort()
        let activity = LibraryActivityCoordinator()
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(
                recordings: [try recordingID()],
                sessions: [try sessionID()]
            ),
            activity: activity
        )
        await feature.send(.selectLibrary(.writable(scope)))
        let record = Task { await feature.send(.record) }
        try await eventually { await capture.isBeginSuspended }

        let notifications = feature.sealedSessions
        let notificationFinished = Task { () -> SessionSealedReceipt? in
            var iterator = notifications.makeAsyncIterator()
            return await iterator.next()
        }
        let shutdown = Task { await feature.shutdown() }
        let notificationValue = await notificationFinished.value
        XCTAssertNil(notificationValue)
        let heldKind = await activity.activeKind
        XCTAssertEqual(heldKind, .recording)

        await capture.resumeStarted()
        try await eventually { await capture.isDiscardSuspended }
        let heldDuringDiscard = await activity.activeKind
        XCTAssertEqual(heldDuringDiscard, .recording)
        await capture.resumeDiscard()
        await record.value
        await shutdown.value
        let commands = await capture.commands
        XCTAssertEqual(commands, [.discardConfirmed])
        let releasedKind = await activity.activeKind
        XCTAssertNil(releasedKind)
    }

    func testShutdownReleasesCapacityOneNotificationBackpressure() async throws {
        let scope = LibraryScope(libraryID: try libraryID())
        let capture = FakeAudioCapturePort()
        let activity = LibraryActivityCoordinator()
        let feature = DefaultRecordingFeature(
            capture: capture,
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(
                recordings: try (0..<2).map(indexedRecordingID),
                sessions: try (0..<2).map(indexedSessionID)
            ),
            activity: activity
        )
        var notifications = feature.sealedSessions.makeAsyncIterator()
        await feature.send(.selectLibrary(.writable(scope)))

        for index in 0..<2 {
            await feature.send(.record)
            let capturedRequest = await capture.latestRequest
            let request = try XCTUnwrap(capturedRequest)
            await capture.emit(
                .sealCandidate(stagedCandidate(request: request, frameCount: 16_000))
            )
            if index == 0 {
                try await eventually {
                    if case .completed = await feature.currentState { return true }
                    return false
                }
            } else {
                try await eventually {
                    if case .sealing = await feature.currentState { return true }
                    return false
                }
            }
        }

        await feature.shutdown()
        let releasedKind = await activity.activeKind
        XCTAssertNil(releasedKind)
        let notification = await notifications.next()
        XCTAssertNil(notification)
    }

    private func makeFeature(
        capture: FakeAudioCapturePort,
        activity: LibraryActivityCoordinator = LibraryActivityCoordinator()
    ) -> DefaultRecordingFeature {
        DefaultRecordingFeature(
            capture: capture,
            clock: FixedRecordingClock(),
            idGenerator: QueueRecordingIDs(
                recordings: [try! recordingID()],
                sessions: [try! sessionID()]
            ),
            activity: activity
        )
    }

}

private enum TestError: Error { case wrongState }

private actor FakeAudioCapturePort: AudioCapturePort {
    private(set) var requests: [MicrophoneRecordingRequest] = []
    private(set) var commands: [ActiveCaptureCommand] = []
    private var continuation: AsyncStream<CaptureObservation>.Continuation?
    private var recovery: RecordingRecoveryCatalog
    private var recoveryAfterFirstPublication: RecordingRecoveryCatalog?
    private var recoveryOutcome: RecordingRecoveryOutcome = .failed(.sealValidationFailedRecoverable)
    private(set) var publications: [ValidatedRecordingPublication] = []
    private(set) var preservedRecordingIDs: [RecordingID] = []
    private(set) var recoveryResolutionCount = 0
    private var collisionsBeforeStart: Int
    private(set) var startedFeedCount = 0

    init(
        recovery: RecordingRecoveryCatalog = RecordingRecoveryCatalog(items: []),
        recoveryAfterFirstPublication: RecordingRecoveryCatalog? = nil,
        collisionsBeforeStart: Int = 0
    ) {
        self.recovery = recovery
        self.recoveryAfterFirstPublication = recoveryAfterFirstPublication
        self.collisionsBeforeStart = collisionsBeforeStart
    }

    var latestRequest: MicrophoneRecordingRequest? { requests.last }

    func begin(_ request: MicrophoneRecordingRequest) -> CaptureStartOutcome {
        requests.append(request)
        if collisionsBeforeStart > 0 {
            collisionsBeforeStart -= 1
            return .rejected(.sessionDestinationCollision)
        }
        startedFeedCount += 1
        let stream = AsyncStream<CaptureObservation> { continuation = $0 }
        return .started(ActiveCaptureFeed(recordingID: request.recordingID, observations: stream))
    }

    func apply(
        _ command: ActiveCaptureCommand,
        to recordingID: RecordingID
    ) -> CaptureCommandOutcome {
        commands.append(command)
        return .accepted
    }

    func completeSeal(
        _ command: RecordingPublicationCommand
    ) -> RecordingPublicationOutcome {
        switch command {
        case let .publish(publication):
            publications.append(publication)
            if let recoveryAfterFirstPublication {
                recovery = recoveryAfterFirstPublication
                self.recoveryAfterFirstPublication = nil
            }
            return .installed(publication.receipt)
        case let .preserveForRecovery(request):
            preservedRecordingIDs.append(request.recordingID)
            let item = RecordingRecoveryItem(
                recordingID: request.recordingID,
                sessionID: request.sessionID,
                startedAt: request.startedAt,
                durableFrameCount: 16_000,
                availability: .sealOrDiscard
            )
            recovery = RecordingRecoveryCatalog(items: [item])
            return .recoveryRequired(item)
        }
    }

    func inspectRecovery(in library: LibraryScope) -> RecordingRecoveryCatalog { recovery }

    func resolveRecovery(
        _ action: RecordingRecoveryAction,
        recordingID: RecordingID,
        in library: LibraryScope
    ) -> RecordingRecoveryOutcome {
        recoveryResolutionCount += 1
        switch recoveryOutcome {
        case .sealCandidate, .discarded:
            recovery = RecordingRecoveryCatalog(items: [])
        case .failed:
            break
        }
        return recoveryOutcome
    }

    func emit(_ observation: CaptureObservation) {
        continuation?.yield(observation)
    }

    func setRecoveryOutcome(_ value: RecordingRecoveryOutcome) {
        recoveryOutcome = value
    }
}

private actor CommittedCleanupCapturePort: AudioCapturePort {
    private let request: MicrophoneRecordingRequest
    private let receipt: SessionSealedReceipt
    private var inspectionCount = 0

    init(request: MicrophoneRecordingRequest, receipt: SessionSealedReceipt) {
        self.request = request
        self.receipt = receipt
    }

    func begin(_ request: MicrophoneRecordingRequest) -> CaptureStartOutcome {
        .rejected(.anotherLibraryActivity)
    }

    func apply(
        _ command: ActiveCaptureCommand,
        to recordingID: RecordingID
    ) -> CaptureCommandOutcome {
        .rejected(.staleCommand)
    }

    func completeSeal(
        _ command: RecordingPublicationCommand
    ) -> RecordingPublicationOutcome {
        guard case let .publish(publication) = command,
              publication.receipt == receipt
        else { return .failed(.sealValidationFailedRecoverable) }
        return .installed(receipt)
    }

    func inspectRecovery(in library: LibraryScope) -> RecordingRecoveryCatalog {
        inspectionCount += 1
        guard inspectionCount == 1 else {
            return RecordingRecoveryCatalog(items: [])
        }
        return RecordingRecoveryCatalog(
            items: [
                RecordingRecoveryItem(
                    recordingID: request.recordingID,
                    sessionID: request.sessionID,
                    startedAt: request.startedAt,
                    durableFrameCount: receipt.frameCount,
                    availability: .committedCleanup
                ),
            ],
            reconciledSeals: [receipt]
        )
    }

    func resolveRecovery(
        _ action: RecordingRecoveryAction,
        recordingID: RecordingID,
        in library: LibraryScope
    ) -> RecordingRecoveryOutcome {
        guard action == .seal,
              recordingID == request.recordingID,
              library == request.libraryScope
        else { return .failed(.staleCommand) }
        return .sealCandidate(
            stagedCandidate(request: request, frameCount: receipt.frameCount)
        )
    }
}

private actor SuspendingCommandCapturePort: AudioCapturePort {
    private var continuation: AsyncStream<CaptureObservation>.Continuation?
    private var commandContinuation: CheckedContinuation<CaptureCommandOutcome, Never>?
    private(set) var latestRequest: MicrophoneRecordingRequest?
    private(set) var pendingCommand: ActiveCaptureCommand?

    var hasFeed: Bool { continuation != nil }

    func begin(_ request: MicrophoneRecordingRequest) -> CaptureStartOutcome {
        latestRequest = request
        let stream = AsyncStream<CaptureObservation> { continuation = $0 }
        return .started(ActiveCaptureFeed(recordingID: request.recordingID, observations: stream))
    }

    func apply(
        _ command: ActiveCaptureCommand,
        to recordingID: RecordingID
    ) async -> CaptureCommandOutcome {
        pendingCommand = command
        return await withCheckedContinuation { commandContinuation = $0 }
    }

    func completeSeal(
        _ command: RecordingPublicationCommand
    ) -> RecordingPublicationOutcome {
        guard case let .publish(publication) = command else {
            return .failed(.sealValidationFailedRecoverable)
        }
        return .installed(publication.receipt)
    }

    func inspectRecovery(in library: LibraryScope) -> RecordingRecoveryCatalog {
        RecordingRecoveryCatalog(items: [])
    }

    func resolveRecovery(
        _ action: RecordingRecoveryAction,
        recordingID: RecordingID,
        in library: LibraryScope
    ) -> RecordingRecoveryOutcome {
        .failed(.staleCommand)
    }

    func emit(_ observation: CaptureObservation) { continuation?.yield(observation) }

    func resumeCommand(with outcome: CaptureCommandOutcome) {
        let continuation = commandContinuation
        commandContinuation = nil
        pendingCommand = nil
        continuation?.resume(returning: outcome)
    }
}

private actor SuspendingRecoveryCapturePort: AudioCapturePort {
    private let item: RecordingRecoveryItem
    private var continuation: CheckedContinuation<RecordingRecoveryOutcome, Never>?
    private(set) var resolveCallCount = 0

    init(item: RecordingRecoveryItem) { self.item = item }

    func begin(_ request: MicrophoneRecordingRequest) -> CaptureStartOutcome {
        .rejected(.anotherLibraryActivity)
    }

    func apply(
        _ command: ActiveCaptureCommand,
        to recordingID: RecordingID
    ) -> CaptureCommandOutcome {
        .rejected(.staleCommand)
    }

    func completeSeal(
        _ command: RecordingPublicationCommand
    ) -> RecordingPublicationOutcome {
        guard case let .publish(publication) = command else {
            return .failed(.sealValidationFailedRecoverable)
        }
        return .installed(publication.receipt)
    }

    func inspectRecovery(in library: LibraryScope) -> RecordingRecoveryCatalog {
        RecordingRecoveryCatalog(items: [item])
    }

    func resolveRecovery(
        _ action: RecordingRecoveryAction,
        recordingID: RecordingID,
        in library: LibraryScope
    ) async -> RecordingRecoveryOutcome {
        resolveCallCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume(with outcome: RecordingRecoveryOutcome) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: outcome)
    }
}

private actor SuspendingInspectionCapturePort: AudioCapturePort {
    private let suspendedScope: LibraryScope
    private var inspectionContinuation: CheckedContinuation<RecordingRecoveryCatalog, Never>?
    private var feedContinuation: AsyncStream<CaptureObservation>.Continuation?
    private(set) var latestRequest: MicrophoneRecordingRequest?

    init(suspending scope: LibraryScope) { suspendedScope = scope }

    var isInspectionWaiting: Bool { inspectionContinuation != nil }

    func begin(_ request: MicrophoneRecordingRequest) -> CaptureStartOutcome {
        latestRequest = request
        let stream = AsyncStream<CaptureObservation> { feedContinuation = $0 }
        return .started(ActiveCaptureFeed(recordingID: request.recordingID, observations: stream))
    }

    func apply(
        _ command: ActiveCaptureCommand,
        to recordingID: RecordingID
    ) -> CaptureCommandOutcome {
        .accepted
    }

    func completeSeal(
        _ command: RecordingPublicationCommand
    ) -> RecordingPublicationOutcome {
        guard case let .publish(publication) = command else {
            return .failed(.sealValidationFailedRecoverable)
        }
        return .installed(publication.receipt)
    }

    func inspectRecovery(in library: LibraryScope) async -> RecordingRecoveryCatalog {
        guard library == suspendedScope else { return RecordingRecoveryCatalog(items: []) }
        return await withCheckedContinuation { inspectionContinuation = $0 }
    }

    func resolveRecovery(
        _ action: RecordingRecoveryAction,
        recordingID: RecordingID,
        in library: LibraryScope
    ) -> RecordingRecoveryOutcome {
        .failed(.staleCommand)
    }

    func resumeInspection(with catalog: RecordingRecoveryCatalog) {
        let pending = inspectionContinuation
        inspectionContinuation = nil
        pending?.resume(returning: catalog)
    }

    func emit(_ observation: CaptureObservation) {
        feedContinuation?.yield(observation)
    }
}

private actor SuspendingBeginCapturePort: AudioCapturePort {
    private var beginContinuation: CheckedContinuation<CaptureStartOutcome, Never>?
    private var commandContinuation: CheckedContinuation<CaptureCommandOutcome, Never>?
    private var request: MicrophoneRecordingRequest?
    private(set) var commands: [ActiveCaptureCommand] = []

    var isBeginSuspended: Bool { beginContinuation != nil }
    var isDiscardSuspended: Bool { commandContinuation != nil }

    func begin(_ request: MicrophoneRecordingRequest) async -> CaptureStartOutcome {
        self.request = request
        return await withCheckedContinuation { beginContinuation = $0 }
    }

    func apply(
        _ command: ActiveCaptureCommand,
        to recordingID: RecordingID
    ) async -> CaptureCommandOutcome {
        commands.append(command)
        return await withCheckedContinuation { commandContinuation = $0 }
    }

    func completeSeal(
        _ command: RecordingPublicationCommand
    ) -> RecordingPublicationOutcome {
        .failed(.sealValidationFailedRecoverable)
    }

    func inspectRecovery(in library: LibraryScope) -> RecordingRecoveryCatalog {
        RecordingRecoveryCatalog(items: [])
    }

    func resolveRecovery(
        _ action: RecordingRecoveryAction,
        recordingID: RecordingID,
        in library: LibraryScope
    ) -> RecordingRecoveryOutcome {
        .failed(.staleCommand)
    }

    func resumeStarted() {
        guard let request else { return }
        let stream = AsyncStream<CaptureObservation> { _ in }
        let continuation = beginContinuation
        beginContinuation = nil
        continuation?.resume(
            returning: .started(
                ActiveCaptureFeed(
                    recordingID: request.recordingID,
                    observations: stream
                )
            )
        )
    }

    func resumeDiscard() {
        let continuation = commandContinuation
        commandContinuation = nil
        continuation?.resume(returning: .accepted)
    }
}

private struct FixedRecordingClock: RecordingClock {
    func now() async -> UTCInstant { try! instant() }
}

private actor SuspendingRecordingClock: RecordingClock {
    private var continuation: CheckedContinuation<UTCInstant, Never>?
    private var resumed = false

    var isWaiting: Bool { continuation != nil }

    func now() async -> UTCInstant {
        if resumed { return try! instant() }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        resumed = true
        let pending = continuation
        continuation = nil
        pending?.resume(returning: try! instant())
    }
}

private actor FirstCallSuspendingRecordingClock: RecordingClock {
    private var callCount = 0
    private var firstContinuation: CheckedContinuation<UTCInstant, Never>?

    var firstCallIsWaiting: Bool { firstContinuation != nil }

    func now() async -> UTCInstant {
        callCount += 1
        if callCount > 1 { return try! instant() }
        return await withCheckedContinuation { firstContinuation = $0 }
    }

    func resumeFirstCall() {
        let pending = firstContinuation
        firstContinuation = nil
        pending?.resume(returning: try! instant())
    }
}

private actor SuspendingRecordingIDs: RecordingIDGenerator {
    private let value: RecordingID
    private let session: SessionID
    private var recordingContinuation: CheckedContinuation<RecordingID, Never>?

    init(recordingID: RecordingID, sessionID: SessionID) {
        value = recordingID
        session = sessionID
    }

    var recordingIDCallIsWaiting: Bool { recordingContinuation != nil }

    func generateRecordingID(at instant: UTCInstant) async -> RecordingID {
        await withCheckedContinuation { recordingContinuation = $0 }
    }

    func generateSessionID(at instant: UTCInstant) -> SessionID { session }

    func resumeRecordingID() {
        let pending = recordingContinuation
        recordingContinuation = nil
        pending?.resume(returning: value)
    }
}

private actor CountingLibraryActivityCoordinator: LibraryActivityCoordinating {
    private let base = LibraryActivityCoordinator()
    private var acquiredTokens: [UInt64] = []
    private var releasedTokens: [UInt64] = []

    func acquireAudioImport() async -> LibraryActivityLease? {
        let lease = await base.acquireAudioImport()
        if let lease { acquiredTokens.append(lease.token) }
        return lease
    }

    func acquireRecording(in scope: LibraryScope) async -> LibraryActivityLease? {
        let lease = await base.acquireRecording(in: scope)
        if let lease { acquiredTokens.append(lease.token) }
        return lease
    }

    func acquireSelectionMutation() async -> LibraryActivityLease? {
        let lease = await base.acquireSelectionMutation()
        if let lease { acquiredTokens.append(lease.token) }
        return lease
    }

    func release(_ lease: LibraryActivityLease) async {
        releasedTokens.append(lease.token)
        await base.release(lease)
    }

    var audit: (acquired: [UInt64], released: [UInt64]) {
        (acquiredTokens, releasedTokens)
    }
}

private actor SuspendingReleaseLibraryActivityCoordinator: LibraryActivityCoordinating {
    private let base = LibraryActivityCoordinator()
    private var shouldSuspendNextRelease = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var recordingScopes: [LibraryScope] = []

    var isReleaseSuspended: Bool { releaseContinuation != nil }

    func acquireAudioImport() async -> LibraryActivityLease? {
        await base.acquireAudioImport()
    }

    func acquireRecording(in scope: LibraryScope) async -> LibraryActivityLease? {
        recordingScopes.append(scope)
        return await base.acquireRecording(in: scope)
    }

    func acquireSelectionMutation() async -> LibraryActivityLease? {
        await base.acquireSelectionMutation()
    }

    func release(_ lease: LibraryActivityLease) async {
        await base.release(lease)
        guard shouldSuspendNextRelease else { return }
        shouldSuspendNextRelease = false
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func suspendNextRelease() {
        shouldSuspendNextRelease = true
    }

    func resumeRelease() {
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }
}

private actor SuspendingAcquireLibraryActivityCoordinator: LibraryActivityCoordinating {
    private let base = LibraryActivityCoordinator()
    private var shouldSuspendNextRecordingAcquire = false
    private var recordingAcquireContinuation: CheckedContinuation<Void, Never>?

    var isRecordingAcquireSuspended: Bool { recordingAcquireContinuation != nil }
    var activeKind: LibraryActivityKind? { get async { await base.activeKind } }

    func acquireAudioImport() async -> LibraryActivityLease? {
        await base.acquireAudioImport()
    }

    func acquireRecording(in scope: LibraryScope) async -> LibraryActivityLease? {
        let lease = await base.acquireRecording(in: scope)
        guard shouldSuspendNextRecordingAcquire else { return lease }
        shouldSuspendNextRecordingAcquire = false
        await withCheckedContinuation { recordingAcquireContinuation = $0 }
        return lease
    }

    func acquireSelectionMutation() async -> LibraryActivityLease? {
        await base.acquireSelectionMutation()
    }

    func release(_ lease: LibraryActivityLease) async {
        await base.release(lease)
    }

    func suspendNextRecordingAcquire() {
        shouldSuspendNextRecordingAcquire = true
    }

    func resumeRecordingAcquire() {
        let continuation = recordingAcquireContinuation
        recordingAcquireContinuation = nil
        continuation?.resume()
    }
}

private actor QueueRecordingIDs: RecordingIDGenerator {
    private var recordings: [RecordingID]
    private var sessions: [SessionID]

    init(recordings: [RecordingID], sessions: [SessionID]) {
        self.recordings = recordings
        self.sessions = sessions
    }

    func generateRecordingID(at instant: UTCInstant) -> RecordingID {
        recordings.removeFirst()
    }

    func generateSessionID(at instant: UTCInstant) -> SessionID {
        sessions.removeFirst()
    }
}

private actor ReceiptCollector {
    private(set) var values: [SessionSealedReceipt] = []
    func append(_ receipt: SessionSealedReceipt) { values.append(receipt) }
}

private actor RecordingStateStreamProbe {
    private var values: [RecordingFeatureState] = []
    private(set) var isFinished = false

    func collect(_ stream: AsyncStream<RecordingFeatureState>) async {
        for await value in stream {
            values.append(value)
        }
        isFinished = true
    }

    var snapshot: (values: [RecordingFeatureState], finished: Bool) {
        (values, isFinished)
    }
}

private func eventually(
    _ condition: @escaping @Sendable () async throws -> Bool
) async throws {
    for _ in 0..<1_000 {
        if try await condition() { return }
        await Task.yield()
    }
    XCTFail("condition did not become true")
}

private func recordingSnapshot(
    of feature: DefaultRecordingFeature
) async throws -> RecordingSnapshot {
    guard case let .active(snapshot, _) = await feature.currentState else {
        throw TestError.wrongState
    }
    return snapshot
}

private func recordingPhase(
    of feature: DefaultRecordingFeature
) async -> RecordingLimitPhase? {
    try? await recordingSnapshot(of: feature).limitPhase
}

private func instant() throws -> UTCInstant {
    try UTCInstant("2026-08-30T12:00:00.000Z")
}

private func libraryID() throws -> LibraryID {
    try LibraryID("lib-20260830T120000000Z-1ABC")
}

private func recordingID() throws -> RecordingID {
    try RecordingID("rec-20260830T120000000Z-2ABC")
}

private func sessionID() throws -> SessionID {
    try SessionID("ses-20260830T120000000Z-3DEF")
}

private func indexedRecordingID(_ index: Int) throws -> RecordingID {
    try RecordingID("rec-20260830T120000000Z-\(base32Suffix(index))")
}

private func indexedSessionID(_ index: Int) throws -> SessionID {
    try SessionID("ses-20260830T120000000Z-\(base32Suffix(index))")
}

private func base32Suffix(_ index: Int) -> String {
    let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    precondition(index >= 0 && index < 32 * 32 * 32 * 32)
    var value = index
    var digits = Array(repeating: Character("0"), count: 4)
    for position in digits.indices.reversed() {
        digits[position] = alphabet[value % alphabet.count]
        value /= alphabet.count
    }
    return String(digits)
}

private func sealedReceipt(
    request: MicrophoneRecordingRequest,
    frameCount: UInt64
) throws -> SessionSealedReceipt {
    try SessionSealedReceipt(
        libraryID: request.libraryScope.libraryID,
        recordingID: request.recordingID,
        sessionID: request.sessionID,
        frameCount: frameCount,
        fingerprint: AudioFingerprint(sha256: String(repeating: "a", count: 64))
    )
}

private func stagedCandidate(
    request: MicrophoneRecordingRequest,
    frameCount: UInt64,
    terminalReason: CaptureTerminalReason = .userStop,
    unavailableIntervals: [StagedUnavailableInterval] = []
) -> StagedRecordingSealCandidate {
    StagedRecordingSealCandidate(
        recordingID: request.recordingID.rawValue,
        sessionID: request.sessionID.rawValue,
        libraryID: request.libraryScope.libraryID.rawValue,
        startedAt: request.startedAt.rawValue,
        terminalReason: terminalReason.rawValue,
        sourceKind: "microphone",
        canonicalAudioPath: "audio/audio.wav",
        sampleRateHz: 16_000,
        channelCount: 1,
        encoding: "pcmS16LE",
        frameCount: frameCount,
        canonicalSHA256: String(repeating: "a", count: 64),
        unavailableIntervals: unavailableIntervals
    )
}
