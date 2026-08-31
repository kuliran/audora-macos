@testable import AudoraApplication
import AudoraDomain
import XCTest

final class ReviewFeatureTests: XCTestCase {
    func testAnnotationVisibilityChangesOnlyOverlayPresentation() async throws {
        let revision = try reviewRevision(
            id: "trv-20260830T121000000Z-4FGH",
            text: "Hello, world!",
            firstWordKind: .filledPause
        )
        let selection = ReviewSelection(
            scope: LibraryScope(libraryID: revisionFixtureLibraryID),
            sessionID: revision.sessionID
        )
        let stored = try ReviewSessionSnapshot(
            selection: selection,
            revisionIDs: [revision.revisionID],
            selectedRevision: revision,
            audioCapabilityID: ReviewAudioCapabilityID("review-annotations"),
            canonicalAudioDurationMilliseconds: revision.durationMilliseconds
        )
        let playback = ReviewPlaybackStub()
        let visibility = ReviewAnnotationVisibilityStub(visible: true)
        let feature = DefaultReviewFeature(
            sessions: ReviewSessionStoreStub(snapshot: stored),
            playback: playback,
            retranscriber: ReviewRetranscriberStub(),
            annotationVisibility: visibility
        )

        await feature.send(.selectSession(selection))
        await feature.send(
            .seek(
                lineID: revision.lines[0].lineID,
                utf8ByteOffset: revision.lines[0].words[0].displayRange.endUTF8Byte
            )
        )
        guard case let .ready(visible) = await feature.currentState else {
            return XCTFail("expected annotated Ready review")
        }
        XCTAssertTrue(visible.annotations.isVisible)
        XCTAssertEqual(visible.annotations.projection.textualOverlays.count, 1)
        let selectedReview = visible.selection
        let copiedText = visible.selectedRevision.lines.map(\.text)
            .joined(separator: "\n\n")
        let selectedRevision = visible.selectedRevision
        let projection = visible.annotations.projection

        await feature.send(.setAnnotationsVisible(false))
        await feature.send(
            .seek(
                lineID: revision.lines[0].lineID,
                utf8ByteOffset: revision.lines[0].words[0].displayRange.endUTF8Byte
            )
        )

        guard case let .ready(hidden) = await feature.currentState else {
            return XCTFail("visibility must not make Review unavailable")
        }
        XCTAssertFalse(hidden.annotations.isVisible)
        XCTAssertEqual(hidden.selection, selectedReview)
        XCTAssertEqual(hidden.selectedRevision, selectedRevision)
        XCTAssertEqual(
            hidden.selectedRevision.lines.map(\.text).joined(separator: "\n\n"),
            copiedText
        )
        XCTAssertEqual(hidden.annotations.projection, projection)
        let seekTimes = await playback.seekTimes
        let writes = await visibility.writes
        XCTAssertEqual(seekTimes, [100, 100])
        XCTAssertEqual(writes, [false])
    }

    func testVisibilityWriteCannotRewindLatestPlaybackState() async throws {
        let revision = try reviewRevision(
            id: "trv-20260830T121000000Z-4FGH",
            text: "Hello, world!"
        )
        let selection = ReviewSelection(
            scope: LibraryScope(libraryID: revisionFixtureLibraryID),
            sessionID: revision.sessionID
        )
        let capability = try ReviewAudioCapabilityID("review-annotation-race")
        let stored = try ReviewSessionSnapshot(
            selection: selection,
            revisionIDs: [revision.revisionID],
            selectedRevision: revision,
            audioCapabilityID: capability,
            canonicalAudioDurationMilliseconds: revision.durationMilliseconds
        )
        let playback = AuthorityLossPlaybackStub(failLoadAfter: nil)
        let visibility = SuspendedReviewAnnotationVisibilityStub()
        let feature = DefaultReviewFeature(
            sessions: ReviewSessionStoreStub(snapshot: stored),
            playback: playback,
            retranscriber: ReviewRetranscriberStub(),
            annotationVisibility: visibility
        )
        await feature.send(.selectSession(selection))

        let toggle = Task { await feature.send(.setAnnotationsVisible(false)) }
        await visibility.waitUntilWriteStarts()
        await playback.emit(
            ReviewPlaybackSnapshot(
                audioCapabilityID: capability,
                positionMilliseconds: 500,
                durationMilliseconds: revision.durationMilliseconds,
                status: .playing
            )
        )
        for _ in 0..<8 { await Task.yield() }
        await visibility.resumeWrite()
        await toggle.value

        guard case let .ready(ready) = await feature.currentState else {
            return XCTFail("visibility write must preserve Ready review")
        }
        XCTAssertEqual(ready.playback.positionMilliseconds, 500)
        XCTAssertEqual(ready.playback.status, .playing)
        XCTAssertEqual(ready.activeWordID, revision.lines[0].words[1].wordID)
        XCTAssertFalse(ready.annotations.isVisible)
    }

    func testQueuedVisibilityIntentCannotCrossAReviewSelectionBoundary() async throws {
        let firstRevision = try reviewRevision(
            id: "trv-20260830T121000000Z-4FGH",
            sessionID: "ses-20260830T120000000Z-2ABC",
            text: "Hello, world!"
        )
        let secondRevision = try reviewRevision(
            id: "trv-20260830T121100000Z-5GHJ",
            sessionID: "ses-20260830T120100000Z-3DEF",
            text: "Hello, world!"
        )
        let scope = LibraryScope(libraryID: revisionFixtureLibraryID)
        let firstSelection = ReviewSelection(
            scope: scope,
            sessionID: firstRevision.sessionID
        )
        let secondSelection = ReviewSelection(
            scope: scope,
            sessionID: secondRevision.sessionID
        )
        let firstSnapshot = try ReviewSessionSnapshot(
            selection: firstSelection,
            revisionIDs: [firstRevision.revisionID],
            selectedRevision: firstRevision,
            audioCapabilityID: ReviewAudioCapabilityID("review-visibility-first"),
            canonicalAudioDurationMilliseconds: firstRevision.durationMilliseconds
        )
        let secondSnapshot = try ReviewSessionSnapshot(
            selection: secondSelection,
            revisionIDs: [secondRevision.revisionID],
            selectedRevision: secondRevision,
            audioCapabilityID: ReviewAudioCapabilityID("review-visibility-second"),
            canonicalAudioDurationMilliseconds: secondRevision.durationMilliseconds
        )
        let sessions = ScriptedAuthorityLossReviewSessions(
            reads: [.available(firstSnapshot), .available(secondSnapshot)],
            selectionResult: .failed
        )
        let visibility = SuspendedReviewAnnotationReadStub()
        let feature = DefaultReviewFeature(
            sessions: sessions,
            playback: ReviewPlaybackStub(),
            retranscriber: ReviewRetranscriberStub(),
            annotationVisibility: visibility
        )
        await feature.send(.selectSession(firstSelection))

        let selection = Task { await feature.send(.selectSession(secondSelection)) }
        await visibility.waitUntilRefreshReadStarts()
        await feature.send(.setAnnotationsVisible(false))
        await visibility.resumeRefreshRead()
        await selection.value

        guard case let .ready(ready) = await feature.currentState else {
            return XCTFail("expected the replacement Review to be ready")
        }
        XCTAssertEqual(ready.selection, secondSelection)
        XCTAssertTrue(ready.annotations.isVisible)
        let writeCount = await visibility.writeCount()
        XCTAssertEqual(writeCount, 0)
    }

    func testAnnotationRefreshCannotRewindLatestPlaybackState() async throws {
        let revision = try reviewRevision(
            id: "trv-20260830T121000000Z-4FGH",
            text: "Hello, world!"
        )
        let selection = ReviewSelection(
            scope: LibraryScope(libraryID: revisionFixtureLibraryID),
            sessionID: revision.sessionID
        )
        let capability = try ReviewAudioCapabilityID("review-annotation-refresh")
        let stored = try ReviewSessionSnapshot(
            selection: selection,
            revisionIDs: [revision.revisionID],
            selectedRevision: revision,
            audioCapabilityID: capability,
            canonicalAudioDurationMilliseconds: revision.durationMilliseconds
        )
        let playback = AuthorityLossPlaybackStub(failLoadAfter: nil)
        let visibility = SuspendedReviewAnnotationReadStub()
        let feature = DefaultReviewFeature(
            sessions: ReviewSessionStoreStub(snapshot: stored),
            playback: playback,
            retranscriber: ReviewRetranscriberStub(),
            annotationVisibility: visibility
        )
        await feature.send(.selectSession(selection))
        await playback.emit(
            ReviewPlaybackSnapshot(
                audioCapabilityID: capability,
                positionMilliseconds: 500,
                durationMilliseconds: revision.durationMilliseconds,
                status: .playing
            )
        )
        for _ in 0..<8 { await Task.yield() }

        let refresh = Task { await feature.send(.refresh) }
        await visibility.waitUntilRefreshReadStarts()
        await playback.emit(
            ReviewPlaybackSnapshot(
                audioCapabilityID: capability,
                positionMilliseconds: 800,
                durationMilliseconds: revision.durationMilliseconds,
                status: .playing
            )
        )
        for _ in 0..<8 { await Task.yield() }
        await visibility.resumeRefreshRead()
        await refresh.value

        guard case let .ready(ready) = await feature.currentState else {
            return XCTFail("refresh must preserve Ready review")
        }
        XCTAssertEqual(ready.playback.positionMilliseconds, 800)
        XCTAssertEqual(ready.playback.status, .playing)
    }

    func testReadyReviewSeeksCanonicalAudioAndHighlightsTheResolvedWord() async throws {
        let revision = try reviewRevision(
            id: "trv-20260830T121000000Z-4FGH",
            text: "Hello, world!"
        )
        let selection = ReviewSelection(
            scope: LibraryScope(libraryID: revisionFixtureLibraryID),
            sessionID: revision.sessionID
        )
        let capabilityID = try ReviewAudioCapabilityID("review-audio-one")
        let stored = try ReviewSessionSnapshot(
            selection: selection,
            revisionIDs: [revision.revisionID],
            selectedRevision: revision,
            audioCapabilityID: capabilityID,
            canonicalAudioDurationMilliseconds: revision.durationMilliseconds
        )
        let sessions = ReviewSessionStoreStub(snapshot: stored)
        let playback = ReviewPlaybackStub()
        let feature = DefaultReviewFeature(
            sessions: sessions,
            playback: playback,
            retranscriber: ReviewRetranscriberStub(),
            annotationVisibility: ReviewAnnotationVisibilityStub(visible: true)
        )

        await feature.send(.selectSession(selection))
        await feature.send(
            .seek(
                lineID: revision.lines[0].lineID,
                utf8ByteOffset: "Hello".utf8.count
            )
        )

        let state = await feature.currentState
        guard case let .ready(ready) = state else {
            return XCTFail("expected synchronized Ready-state review")
        }
        XCTAssertEqual(ready.selectedRevision, revision)
        XCTAssertEqual(ready.revisionIDs, [revision.revisionID])
        XCTAssertEqual(ready.playback.positionMilliseconds, 100)
        XCTAssertEqual(ready.activeWordID, revision.lines[0].words[0].wordID)
        let seeks = await playback.seekTimes
        XCTAssertEqual(seeks, [100])
    }

    func testConcurrentRevisionSelectionUsesOneCASWinnerAndConvergesOnInventory() async throws {
        let first = try reviewRevision(
            id: "trv-20260830T121000000Z-4FGH",
            text: "Hello, world!"
        )
        let second = try reviewRevision(
            id: "trv-20260830T121100000Z-5GHJ",
            text: "Hello, world!"
        )
        let third = try reviewRevision(
            id: "trv-20260830T121200000Z-6PQR",
            text: "Hello, world!"
        )
        let selection = ReviewSelection(
            scope: LibraryScope(libraryID: revisionFixtureLibraryID),
            sessionID: first.sessionID
        )
        let capabilityID = try ReviewAudioCapabilityID("review-audio-cas")
        let inventory = [first.revisionID, second.revisionID, third.revisionID]
        let snapshots = try [first, second, third].map {
            try ReviewSessionSnapshot(
                selection: selection,
                revisionIDs: inventory,
                selectedRevision: $0,
                audioCapabilityID: capabilityID,
                canonicalAudioDurationMilliseconds: $0.durationMilliseconds
            )
        }
        let sessions = ReviewSessionStoreStub(
            snapshots: snapshots,
            selectedRevisionID: first.revisionID
        )
        let left = DefaultReviewFeature(
            sessions: sessions,
            playback: ReviewPlaybackStub(),
            retranscriber: ReviewRetranscriberStub(),
            annotationVisibility: ReviewAnnotationVisibilityStub(visible: true)
        )
        let right = DefaultReviewFeature(
            sessions: sessions,
            playback: ReviewPlaybackStub(),
            retranscriber: ReviewRetranscriberStub(),
            annotationVisibility: ReviewAnnotationVisibilityStub(visible: true)
        )
        await left.send(.selectSession(selection))
        await right.send(.selectSession(selection))

        async let leftSelection: Void = left.send(
            .selectRevision(
                second.revisionID,
                expectedSelectedRevisionID: first.revisionID
            )
        )
        async let rightSelection: Void = right.send(
            .selectRevision(
                third.revisionID,
                expectedSelectedRevisionID: first.revisionID
            )
        )
        _ = await (leftSelection, rightSelection)

        let authoritative = await sessions.selectedSnapshot
        let leftState = await left.currentState
        let rightState = await right.currentState
        guard case let .ready(leftReady) = leftState,
              case let .ready(rightReady) = rightState
        else { return XCTFail("both reviewers must remain ready after a CAS race") }
        let successfulSelectionCount = await sessions.successfulSelectionCount
        XCTAssertEqual(successfulSelectionCount, 1)
        XCTAssertEqual(leftReady.selectedRevisionID, authoritative.selectedRevisionID)
        XCTAssertEqual(rightReady.selectedRevisionID, authoritative.selectedRevisionID)
        XCTAssertEqual(leftReady.revisionIDs, inventory)
        XCTAssertEqual(rightReady.revisionIDs, inventory)
    }

    func testRetranscribeCommandReloadsAnotherSelectedImmutableRevision() async throws {
        let original = try reviewRevision(
            id: "trv-20260830T121000000Z-4FGH",
            text: "Hello, world!"
        )
        let replacement = try reviewRevision(
            id: "trv-20260830T121100000Z-5GHJ",
            text: "Hello, world!"
        )
        let selection = ReviewSelection(
            scope: LibraryScope(libraryID: revisionFixtureLibraryID),
            sessionID: original.sessionID
        )
        let capabilityID = try ReviewAudioCapabilityID("review-audio-retranscribe")
        let initial = try ReviewSessionSnapshot(
            selection: selection,
            revisionIDs: [original.revisionID],
            selectedRevision: original,
            audioCapabilityID: capabilityID,
            canonicalAudioDurationMilliseconds: original.durationMilliseconds
        )
        let updated = try ReviewSessionSnapshot(
            selection: selection,
            revisionIDs: [original.revisionID, replacement.revisionID],
            selectedRevision: replacement,
            audioCapabilityID: capabilityID,
            canonicalAudioDurationMilliseconds: replacement.durationMilliseconds
        )
        let sessions = ReviewSessionStoreStub(snapshot: initial)
        let retranscriber = ReviewRetranscriberStub(result: .completed) {
            await sessions.installSnapshot(updated)
        }
        let feature = DefaultReviewFeature(
            sessions: sessions,
            playback: ReviewPlaybackStub(),
            retranscriber: retranscriber,
            annotationVisibility: ReviewAnnotationVisibilityStub(visible: true)
        )
        await feature.send(.selectSession(selection))

        await feature.send(.retranscribe)

        let state = await feature.currentState
        guard case let .ready(ready) = state else {
            return XCTFail("completed retranscription must return to Ready review")
        }
        XCTAssertEqual(
            ready.revisionIDs,
            [original.revisionID, replacement.revisionID]
        )
        XCTAssertEqual(ready.selectedRevision, replacement)
        XCTAssertEqual(ready.notice, .retranscribed)
        let retranscriptionSelections = await retranscriber.selections
        XCTAssertEqual(retranscriptionSelections, [selection])
    }

    func testProcessingRetranscriberSelectsSessionThenStartsExistingFeature() async throws {
        let selection = ReviewSelection(
            scope: LibraryScope(libraryID: revisionFixtureLibraryID),
            sessionID: try SessionID("ses-20260830T120000000Z-2ABC")
        )
        let processing = SessionProcessingFeatureStub(
            completedRevisionID: try TranscriptRevisionID(
                "trv-20260830T121100000Z-5GHJ"
            )
        )
        let retranscriber = SessionProcessingReviewRetranscriber(feature: processing)

        let result = await retranscriber.retranscribe(selection)

        XCTAssertEqual(result, .completed)
        let commands = await processing.commands
        XCTAssertEqual(
            commands,
            [
                .selectSession(
                    SessionProcessingSelection(
                        scope: selection.scope,
                        sessionID: selection.sessionID
                    )
                ),
                .start,
            ]
        )
    }

    func testRefreshRereadsASelectedSessionAfterItsFirstRevisionAppears() async throws {
        let revision = try reviewRevision(
            id: "trv-20260830T121000000Z-4FGH",
            text: "Hello, world!"
        )
        let selection = ReviewSelection(
            scope: LibraryScope(libraryID: revisionFixtureLibraryID),
            sessionID: revision.sessionID
        )
        let snapshot = try ReviewSessionSnapshot(
            selection: selection,
            revisionIDs: [revision.revisionID],
            selectedRevision: revision,
            audioCapabilityID: ReviewAudioCapabilityID("review-first-revision"),
            canonicalAudioDurationMilliseconds: revision.durationMilliseconds
        )
        let sessions = MutableReviewSessionStub(result: .unavailable)
        let feature = DefaultReviewFeature(
            sessions: sessions,
            playback: ReviewPlaybackStub(),
            retranscriber: ReviewRetranscriberStub(),
            annotationVisibility: ReviewAnnotationVisibilityStub(visible: true)
        )
        await feature.send(.selectSession(selection))
        await sessions.install(.available(snapshot))

        await feature.send(.refresh)

        guard case let .ready(ready) = await feature.currentState else {
            return XCTFail("refresh must discover the first selected Revision")
        }
        XCTAssertEqual(ready.selectedRevision, revision)
    }

    func testSuspendedLoadKeepsOnlyLatestPendingSessionSelection() async throws {
        let scope = LibraryScope(libraryID: revisionFixtureLibraryID)
        let first = ReviewSelection(
            scope: scope,
            sessionID: try SessionID("ses-20260830T120000000Z-2ABC")
        )
        let second = ReviewSelection(
            scope: scope,
            sessionID: try SessionID("ses-20260830T120100000Z-3DEF")
        )
        let third = ReviewSelection(
            scope: scope,
            sessionID: try SessionID("ses-20260830T120200000Z-4GHJ")
        )
        let sessions = SuspendedReviewSessionStub()
        let feature = DefaultReviewFeature(
            sessions: sessions,
            playback: ReviewPlaybackStub(),
            retranscriber: ReviewRetranscriberStub(),
            annotationVisibility: ReviewAnnotationVisibilityStub(visible: true)
        )
        let firstSend = Task { await feature.send(.selectSession(first)) }
        await sessions.waitUntilFirstLoadStarts()

        await feature.send(.selectSession(second))
        await feature.send(.selectSession(third))
        await sessions.resumeFirstLoad()
        await firstSend.value

        let loadedSelections = await sessions.loadedSelections()
        XCTAssertEqual(loadedSelections, [first, third])
        guard case let .unavailable(selection, _) = await feature.currentState else {
            return XCTFail("expected latest unavailable selection")
        }
        XCTAssertEqual(selection, third)
    }

    func testEveryReadyAuthorityLossClearsPlaybackAndRejectsStaleEvents() async throws {
        enum Trigger: String {
            case refresh
            case staleSelectionReload
            case directSelectionFailure
            case retranscriptionReload
            case playbackReplacementFailure
        }
        struct Scenario {
            let trigger: Trigger
            let readFailure: ReviewSessionReadResult?
            let expectedReason: ReviewUnavailableReason
        }

        let scenarios = [
            Scenario(
                trigger: .refresh,
                readFailure: .unavailable,
                expectedReason: .noTranscript
            ),
            Scenario(
                trigger: .refresh,
                readFailure: .integrityMismatch,
                expectedReason: .integrityMismatch
            ),
            Scenario(
                trigger: .staleSelectionReload,
                readFailure: .unavailable,
                expectedReason: .noTranscript
            ),
            Scenario(
                trigger: .staleSelectionReload,
                readFailure: .integrityMismatch,
                expectedReason: .integrityMismatch
            ),
            Scenario(
                trigger: .directSelectionFailure,
                readFailure: .unavailable,
                expectedReason: .noTranscript
            ),
            Scenario(
                trigger: .directSelectionFailure,
                readFailure: .integrityMismatch,
                expectedReason: .integrityMismatch
            ),
            Scenario(
                trigger: .retranscriptionReload,
                readFailure: .unavailable,
                expectedReason: .noTranscript
            ),
            Scenario(
                trigger: .retranscriptionReload,
                readFailure: .integrityMismatch,
                expectedReason: .integrityMismatch
            ),
            Scenario(
                trigger: .playbackReplacementFailure,
                readFailure: nil,
                expectedReason: .playbackUnavailable
            ),
        ]

        for scenario in scenarios {
            let first = try reviewRevision(
                id: "trv-20260830T121000000Z-4FGH",
                text: "Hello, world!"
            )
            let second = try reviewRevision(
                id: "trv-20260830T121100000Z-5GHJ",
                text: "Hello, world!"
            )
            let selection = ReviewSelection(
                scope: LibraryScope(libraryID: revisionFixtureLibraryID),
                sessionID: first.sessionID
            )
            let firstCapability = try ReviewAudioCapabilityID(
                "review-authority-loss"
            )
            let replacementCapability = try ReviewAudioCapabilityID(
                "review-replacement"
            )
            let inventory = [first.revisionID, second.revisionID]
            let initial = try ReviewSessionSnapshot(
                selection: selection,
                revisionIDs: inventory,
                selectedRevision: first,
                audioCapabilityID: firstCapability,
                canonicalAudioDurationMilliseconds: first.durationMilliseconds
            )
            let selectedSecond = try ReviewSessionSnapshot(
                selection: selection,
                revisionIDs: inventory,
                selectedRevision: second,
                audioCapabilityID: firstCapability,
                canonicalAudioDurationMilliseconds: second.durationMilliseconds
            )
            let replacementAudio = try ReviewSessionSnapshot(
                selection: selection,
                revisionIDs: inventory,
                selectedRevision: first,
                audioCapabilityID: replacementCapability,
                canonicalAudioDurationMilliseconds: first.durationMilliseconds
            )
            var reads: [ReviewSessionReadResult] = [.available(initial)]
            if scenario.trigger == .playbackReplacementFailure {
                reads.append(.available(replacementAudio))
            } else if scenario.trigger != .directSelectionFailure,
                      let readFailure = scenario.readFailure
            {
                reads.append(readFailure)
            }
            let selectionResult: ReviewRevisionSelectionResult
            switch scenario.trigger {
            case .staleSelectionReload:
                selectionResult = .stale
            case .directSelectionFailure:
                selectionResult = scenario.readFailure == .unavailable
                    ? .unavailable
                    : .integrityMismatch
            case .refresh, .retranscriptionReload,
                 .playbackReplacementFailure:
                selectionResult = .selected(selectedSecond)
            }
            let sessions = ScriptedAuthorityLossReviewSessions(
                reads: reads,
                selectionResult: selectionResult
            )
            let playback = AuthorityLossPlaybackStub(
                failLoadAfter: scenario.trigger == .playbackReplacementFailure ? 1 : nil
            )
            let feature = DefaultReviewFeature(
                sessions: sessions,
                playback: playback,
                retranscriber: ReviewRetranscriberStub(result: .completed),
                annotationVisibility: ReviewAnnotationVisibilityStub(visible: true)
            )
            await feature.send(.selectSession(selection))
            await feature.send(.play)
            guard case let .ready(playing) = await feature.currentState else {
                return XCTFail("\(scenario.trigger.rawValue): expected playing Review")
            }
            XCTAssertEqual(playing.playback.status, .playing)

            switch scenario.trigger {
            case .refresh, .playbackReplacementFailure:
                await feature.send(.refresh)
            case .staleSelectionReload, .directSelectionFailure:
                await feature.send(
                    .selectRevision(
                        second.revisionID,
                        expectedSelectedRevisionID: first.revisionID
                    )
                )
            case .retranscriptionReload:
                await feature.send(.retranscribe)
            }

            let cleared = await playback.clearedCapabilities()
            let expectedClearedCapability: ReviewAudioCapabilityID? =
                scenario.trigger == .playbackReplacementFailure
                    ? nil
                    : firstCapability
            XCTAssertEqual(
                cleared,
                [expectedClearedCapability],
                scenario.trigger.rawValue
            )
            let hasLoadedAudio = await playback.hasLoadedAudio()
            XCTAssertFalse(hasLoadedAudio)
            await playback.emit(
                ReviewPlaybackSnapshot(
                    audioCapabilityID: firstCapability,
                    positionMilliseconds: 800,
                    durationMilliseconds: first.durationMilliseconds,
                    status: .playing
                )
            )
            for _ in 0..<8 { await Task.yield() }
            guard case let .unavailable(finalSelection, reason) =
                await feature.currentState
            else {
                return XCTFail(
                    "\(scenario.trigger.rawValue): stale playback restored controls"
                )
            }
            XCTAssertEqual(finalSelection, selection, scenario.trigger.rawValue)
            XCTAssertEqual(reason, scenario.expectedReason, scenario.trigger.rawValue)
        }
    }

    func testNewSessionLoadFailureRevokesPreviouslyPlayingAdapterWholesale() async throws {
        let first = try reviewRevision(
            id: "trv-20260830T121000000Z-4FGH",
            text: "Hello, world!"
        )
        let replacement = try reviewRevision(
            id: "trv-20260830T122000000Z-8JKM",
            sessionID: "ses-20260830T121500000Z-7HJK",
            text: "Hello, world!"
        )
        let scope = LibraryScope(libraryID: revisionFixtureLibraryID)
        let firstSelection = ReviewSelection(
            scope: scope,
            sessionID: first.sessionID
        )
        let replacementSelection = ReviewSelection(
            scope: scope,
            sessionID: replacement.sessionID
        )
        let firstCapability = try ReviewAudioCapabilityID("review-old-session")
        let replacementCapability = try ReviewAudioCapabilityID(
            "review-new-session"
        )
        let firstSnapshot = try ReviewSessionSnapshot(
            selection: firstSelection,
            revisionIDs: [first.revisionID],
            selectedRevision: first,
            audioCapabilityID: firstCapability,
            canonicalAudioDurationMilliseconds: first.durationMilliseconds
        )
        let replacementSnapshot = try ReviewSessionSnapshot(
            selection: replacementSelection,
            revisionIDs: [replacement.revisionID],
            selectedRevision: replacement,
            audioCapabilityID: replacementCapability,
            canonicalAudioDurationMilliseconds: replacement.durationMilliseconds
        )
        let sessions = ScriptedAuthorityLossReviewSessions(
            reads: [.available(firstSnapshot), .available(replacementSnapshot)],
            selectionResult: .failed
        )
        let playback = AuthorityLossPlaybackStub(failLoadAfter: 1)
        let feature = DefaultReviewFeature(
            sessions: sessions,
            playback: playback,
            retranscriber: ReviewRetranscriberStub(),
            annotationVisibility: ReviewAnnotationVisibilityStub(visible: true)
        )
        await feature.send(.selectSession(firstSelection))
        await feature.send(.play)
        guard case let .ready(playing) = await feature.currentState else {
            return XCTFail("expected old session audio to be ready")
        }
        XCTAssertEqual(playing.playback.status, .playing)

        await feature.send(.selectSession(replacementSelection))

        let clears = await playback.clearedCapabilities()
        XCTAssertEqual(clears, [nil])
        let hasLoadedAudio = await playback.hasLoadedAudio()
        XCTAssertFalse(hasLoadedAudio)
        await playback.emit(
            ReviewPlaybackSnapshot(
                audioCapabilityID: firstCapability,
                positionMilliseconds: 800,
                durationMilliseconds: first.durationMilliseconds,
                status: .playing
            )
        )
        for _ in 0..<8 { await Task.yield() }
        guard case let .unavailable(selection, reason) = await feature.currentState
        else { return XCTFail("failed replacement must not restore Review controls") }
        XCTAssertEqual(selection, replacementSelection)
        XCTAssertEqual(reason, .playbackUnavailable)
    }
}

private actor ReviewSessionStoreStub: ReviewSessionPort {
    private var snapshot: ReviewSessionSnapshot
    private let snapshotsByRevisionID: [TranscriptRevisionID: ReviewSessionSnapshot]
    private(set) var successfulSelectionCount = 0

    init(snapshot: ReviewSessionSnapshot) {
        self.snapshot = snapshot
        snapshotsByRevisionID = [snapshot.selectedRevisionID: snapshot]
    }

    init(
        snapshots: [ReviewSessionSnapshot],
        selectedRevisionID: TranscriptRevisionID
    ) {
        let indexed = Dictionary(
            uniqueKeysWithValues: snapshots.map { ($0.selectedRevisionID, $0) }
        )
        self.snapshot = indexed[selectedRevisionID]!
        snapshotsByRevisionID = indexed
    }

    var selectedSnapshot: ReviewSessionSnapshot { snapshot }

    func installSnapshot(_ replacement: ReviewSessionSnapshot) {
        snapshot = replacement
    }

    func load(_ selection: ReviewSelection) async -> ReviewSessionReadResult {
        snapshot.selection == selection ? .available(snapshot) : .unavailable
    }

    func selectRevision(
        _ revisionID: TranscriptRevisionID,
        for selection: ReviewSelection,
        expectedSelectedRevisionID: TranscriptRevisionID
    ) async -> ReviewRevisionSelectionResult {
        guard snapshot.selection == selection else { return .unavailable }
        guard snapshot.selectedRevisionID == expectedSelectedRevisionID else {
            return .stale
        }
        guard let selected = snapshotsByRevisionID[revisionID] else {
            return .integrityMismatch
        }
        snapshot = selected
        successfulSelectionCount += 1
        return .selected(selected)
    }
}

private actor ReviewPlaybackStub: ReviewPlaybackPort {
    private(set) var seekTimes: [UInt64] = []
    private var loaded: ReviewAudioSource?

    nonisolated var states: AsyncStream<ReviewPlaybackSnapshot> {
        AsyncStream { $0.finish() }
    }

    func load(_ source: ReviewAudioSource) async -> ReviewPlaybackSnapshot? {
        loaded = source
        return ReviewPlaybackSnapshot(
            audioCapabilityID: source.audioCapabilityID,
            positionMilliseconds: 0,
            durationMilliseconds: source.durationMilliseconds,
            status: .paused
        )
    }

    func play() async -> ReviewPlaybackSnapshot? { current(status: .playing) }
    func pause() async -> ReviewPlaybackSnapshot? { current(status: .paused) }

    func seek(toMilliseconds milliseconds: UInt64) async -> ReviewPlaybackSnapshot? {
        seekTimes.append(milliseconds)
        return current(positionMilliseconds: milliseconds, status: .paused)
    }

    func clear(_ audioCapabilityID: ReviewAudioCapabilityID?) async {
        guard audioCapabilityID == nil || loaded?.audioCapabilityID == audioCapabilityID else {
            return
        }
        loaded = nil
    }

    private func current(
        positionMilliseconds: UInt64 = 0,
        status: ReviewPlaybackStatus
    ) -> ReviewPlaybackSnapshot? {
        guard let loaded else { return nil }
        return ReviewPlaybackSnapshot(
            audioCapabilityID: loaded.audioCapabilityID,
            positionMilliseconds: positionMilliseconds,
            durationMilliseconds: loaded.durationMilliseconds,
            status: status
        )
    }
}

private actor MutableReviewSessionStub: ReviewSessionPort {
    private var result: ReviewSessionReadResult

    init(result: ReviewSessionReadResult) { self.result = result }

    func install(_ result: ReviewSessionReadResult) { self.result = result }

    func load(_ selection: ReviewSelection) async -> ReviewSessionReadResult { result }

    func selectRevision(
        _ revisionID: TranscriptRevisionID,
        for selection: ReviewSelection,
        expectedSelectedRevisionID: TranscriptRevisionID
    ) async -> ReviewRevisionSelectionResult {
        .failed
    }
}

private actor SuspendedReviewSessionStub: ReviewSessionPort {
    private var selections: [ReviewSelection] = []
    private var firstLoadContinuation: CheckedContinuation<Void, Never>?

    func load(_ selection: ReviewSelection) async -> ReviewSessionReadResult {
        selections.append(selection)
        if selections.count == 1 {
            await withCheckedContinuation { continuation in
                firstLoadContinuation = continuation
            }
        }
        return .unavailable
    }

    func selectRevision(
        _ revisionID: TranscriptRevisionID,
        for selection: ReviewSelection,
        expectedSelectedRevisionID: TranscriptRevisionID
    ) async -> ReviewRevisionSelectionResult {
        .failed
    }

    func waitUntilFirstLoadStarts() async {
        while selections.isEmpty { await Task.yield() }
    }

    func resumeFirstLoad() {
        firstLoadContinuation?.resume()
        firstLoadContinuation = nil
    }

    func loadedSelections() -> [ReviewSelection] { selections }
}

private actor ScriptedAuthorityLossReviewSessions: ReviewSessionPort {
    private var reads: [ReviewSessionReadResult]
    private let selectionResult: ReviewRevisionSelectionResult

    init(
        reads: [ReviewSessionReadResult],
        selectionResult: ReviewRevisionSelectionResult
    ) {
        self.reads = reads
        self.selectionResult = selectionResult
    }

    func load(_ selection: ReviewSelection) async -> ReviewSessionReadResult {
        guard !reads.isEmpty else { return .unavailable }
        return reads.removeFirst()
    }

    func selectRevision(
        _ revisionID: TranscriptRevisionID,
        for selection: ReviewSelection,
        expectedSelectedRevisionID: TranscriptRevisionID
    ) async -> ReviewRevisionSelectionResult {
        selectionResult
    }
}

private actor AuthorityLossPlaybackStub: ReviewPlaybackPort {
    nonisolated let states: AsyncStream<ReviewPlaybackSnapshot>
    private let continuation: AsyncStream<ReviewPlaybackSnapshot>.Continuation
    private let failLoadAfter: Int?
    private var loadCount = 0
    private var loaded: ReviewAudioSource?
    private var clears: [ReviewAudioCapabilityID?] = []

    init(failLoadAfter: Int?) {
        self.failLoadAfter = failLoadAfter
        var captured: AsyncStream<ReviewPlaybackSnapshot>.Continuation?
        states = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            captured = $0
        }
        continuation = captured!
    }

    func load(_ source: ReviewAudioSource) async -> ReviewPlaybackSnapshot? {
        loadCount += 1
        if let failLoadAfter, loadCount > failLoadAfter { return nil }
        loaded = source
        return snapshot(source: source, status: .paused)
    }

    func play() async -> ReviewPlaybackSnapshot? {
        loaded.map { snapshot(source: $0, status: .playing) }
    }

    func pause() async -> ReviewPlaybackSnapshot? {
        loaded.map { snapshot(source: $0, status: .paused) }
    }

    func seek(toMilliseconds milliseconds: UInt64) async -> ReviewPlaybackSnapshot? {
        loaded.map {
            ReviewPlaybackSnapshot(
                audioCapabilityID: $0.audioCapabilityID,
                positionMilliseconds: milliseconds,
                durationMilliseconds: $0.durationMilliseconds,
                status: .paused
            )
        }
    }

    func clear(_ audioCapabilityID: ReviewAudioCapabilityID?) async {
        clears.append(audioCapabilityID)
        guard audioCapabilityID == nil || loaded?.audioCapabilityID == audioCapabilityID
        else { return }
        loaded = nil
    }

    func emit(_ snapshot: ReviewPlaybackSnapshot) {
        continuation.yield(snapshot)
    }

    func clearedCapabilities() -> [ReviewAudioCapabilityID?] { clears }

    func hasLoadedAudio() -> Bool { loaded != nil }

    private func snapshot(
        source: ReviewAudioSource,
        status: ReviewPlaybackStatus
    ) -> ReviewPlaybackSnapshot {
        ReviewPlaybackSnapshot(
            audioCapabilityID: source.audioCapabilityID,
            positionMilliseconds: 0,
            durationMilliseconds: source.durationMilliseconds,
            status: status
        )
    }
}

private actor ReviewRetranscriberStub: ReviewRetranscriptionPort {
    private let result: ReviewRetranscriptionResult
    private let operation: @Sendable () async -> Void
    private(set) var selections: [ReviewSelection] = []

    init(
        result: ReviewRetranscriptionResult = .failed,
        operation: @escaping @Sendable () async -> Void = {}
    ) {
        self.result = result
        self.operation = operation
    }

    func retranscribe(_ selection: ReviewSelection) async -> ReviewRetranscriptionResult {
        selections.append(selection)
        await operation()
        return result
    }
}

private actor ReviewAnnotationVisibilityStub: ReviewAnnotationVisibilityPort {
    private var visible: Bool
    private(set) var writes: [Bool] = []

    init(visible: Bool) { self.visible = visible }

    func annotationsVisible(in scope: LibraryScope) async -> Bool? { visible }

    func setAnnotationsVisible(
        _ visible: Bool,
        in scope: LibraryScope
    ) async -> Bool {
        self.visible = visible
        writes.append(visible)
        return true
    }
}

private actor SuspendedReviewAnnotationVisibilityStub:
    ReviewAnnotationVisibilityPort
{
    private var didStartWrite = false
    private var continuation: CheckedContinuation<Void, Never>?

    func annotationsVisible(in scope: LibraryScope) async -> Bool? { true }

    func setAnnotationsVisible(
        _ visible: Bool,
        in scope: LibraryScope
    ) async -> Bool {
        didStartWrite = true
        await withCheckedContinuation { continuation = $0 }
        return true
    }

    func waitUntilWriteStarts() async {
        while !didStartWrite { await Task.yield() }
    }

    func resumeWrite() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SuspendedReviewAnnotationReadStub: ReviewAnnotationVisibilityPort {
    private var readCount = 0
    private var writes = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func annotationsVisible(in scope: LibraryScope) async -> Bool? {
        readCount += 1
        if readCount == 2 {
            await withCheckedContinuation { continuation = $0 }
        }
        return true
    }

    func setAnnotationsVisible(
        _ visible: Bool,
        in scope: LibraryScope
    ) async -> Bool {
        writes += 1
        return true
    }

    func writeCount() -> Int { writes }

    func waitUntilRefreshReadStarts() async {
        while readCount < 2 { await Task.yield() }
    }

    func resumeRefreshRead() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SessionProcessingFeatureStub: SessionProcessingFeature {
    private let completedRevisionID: TranscriptRevisionID
    private var state: SessionProcessingFeatureState = .unavailable(
        SessionProcessingUnavailableSnapshot(
            selection: nil,
            reason: .noSession,
            actions: []
        )
    )
    private(set) var commands: [SessionProcessingCommand] = []

    init(completedRevisionID: TranscriptRevisionID) {
        self.completedRevisionID = completedRevisionID
    }

    var currentState: SessionProcessingFeatureState { state }

    nonisolated var states: AsyncStream<SessionProcessingFeatureState> {
        AsyncStream { $0.finish() }
    }

    func send(_ command: SessionProcessingCommand) async {
        commands.append(command)
        switch command {
        case let .selectSession(selection):
            state = .failed(
                SessionProcessingFailedSnapshot(
                    job: nil,
                    reason: .engineFailed,
                    actions: [.retry]
                )
            )
            precondition(selection.sessionID.rawValue.hasPrefix("ses-"))
        case .start:
            state = .completed(
                SessionProcessingCompletedSnapshot(
                    sessionID: try! SessionID("ses-20260830T120000000Z-2ABC"),
                    jobID: try! TranscriptionJobID(
                        "job-20260830T121000000Z-4FGH"
                    ),
                    selectedRevisionID: completedRevisionID
                )
            )
        case .clearSelection, .prepare, .reinstall, .retry:
            break
        }
    }
}

private let revisionFixtureLibraryID = try! LibraryID("lib-20260830T120000000Z-1ABC")

private func reviewRevision(
    id: String,
    sessionID: String = "ses-20260830T120000000Z-2ABC",
    text: String,
    firstWordKind: TranscriptWordKind = .lexical
) throws -> TranscriptRevision {
    let duration: UInt64 = 1_000
    let firstText = "Hello"
    let secondText = "world"
    let secondStart = text.utf8.count - "world!".utf8.count
    let firstTime = try SessionTimeRange(
        startMilliseconds: 100,
        endMilliseconds: 250,
        sessionDurationMilliseconds: duration
    )
    let secondTime = try SessionTimeRange(
        startMilliseconds: 400,
        endMilliseconds: 600,
        sessionDurationMilliseconds: duration
    )
    let lineTime = try SessionTimeRange(
        startMilliseconds: 80,
        endMilliseconds: 700,
        sessionDurationMilliseconds: duration
    )
    let fingerprint = try AudioFingerprint(sha256: String(repeating: "a", count: 64))
    let usePolicy = try EngineUsePolicy(
        policyID: "review-test-policy",
        coveredArtifacts: [.transcriptRevision],
        privateLocalUseAllowed: true,
        privateExportAllowed: true,
        externalProcessingAllowed: false,
        publicDistributionAllowed: false,
        commercialUseAllowed: false,
        licenseReference: "synthetic-license",
        licenseSHA256: String(repeating: "b", count: 64)
    )
    return try TranscriptRevision(
        revisionID: TranscriptRevisionID(id),
        sessionID: SessionID(sessionID),
        jobID: TranscriptionJobID("job-20260830T120500000Z-3DEF"),
        createdAt: UTCInstant("2026-08-30T12:10:00.000Z"),
        durationMilliseconds: duration,
        audioFingerprint: fingerprint,
        sourceFingerprints: [
            TranscriptSourceFingerprint(
                audioSourceID: .microphone,
                fingerprint: fingerprint
            ),
        ],
        candidateArtifactFingerprint: try AudioFingerprint(
            sha256: String(repeating: "c", count: 64)
        ),
        engine: try TranscriptEngineProvenance(
            provider: "crisperwhisper",
            model: "small",
            revision: "review-v1",
            language: "en",
            mode: "verbatim",
            decodingOptionsSHA256: String(repeating: "d", count: 64),
            qualification: try TranscriptEngineQualification(
                qualificationProfileID: "review-qualified-v1",
                engineLockSHA256: String(repeating: "e", count: 64),
                runtimeIdentity: "review-runtime-v1",
                runtimeLockSHA256: String(repeating: "f", count: 64),
                compatibilityPatchID: "review-patch-v1"
            ),
            usePolicy: usePolicy
        ),
        lines: [
            TranscriptLine(
                lineID: try TranscriptLineID("l000000"),
                order: 0,
                audioSourceID: .microphone,
                timeRange: lineTime,
                text: text,
                words: [
                    TranscriptWord(
                        wordID: try TranscriptWordID("w000000"),
                        ordinal: 0,
                        text: firstText,
                        displayRange: LineTextRange(
                            startUTF8Byte: 0,
                            endUTF8Byte: firstText.utf8.count
                        ),
                        timeRange: firstTime,
                        confidence: nil,
                        wordKind: firstWordKind
                    ),
                    TranscriptWord(
                        wordID: try TranscriptWordID("w000001"),
                        ordinal: 1,
                        text: secondText,
                        displayRange: LineTextRange(
                            startUTF8Byte: secondStart,
                            endUTF8Byte: secondStart + secondText.utf8.count
                        ),
                        timeRange: secondTime,
                        confidence: nil,
                        wordKind: .lexical
                    ),
                ]
            ),
        ],
        audioEvents: []
    )
}
