import AudoraDomain

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public actor DefaultReviewFeature: ReviewFeature {
    private enum PendingSelectionCommand {
        case select(ReviewSelection)
        case clear

        var command: ReviewCommand {
            switch self {
            case let .select(selection): .selectSession(selection)
            case .clear: .clearSelection
            }
        }
    }

    private struct PendingAnnotationVisibilityCommand {
        let selection: ReviewSelection
        let visible: Bool
    }

    private let sessions: any ReviewSessionPort
    private let playback: any ReviewPlaybackPort
    private let retranscriber: any ReviewRetranscriptionPort
    private let annotationVisibility: any ReviewAnnotationVisibilityPort
    private let annotator = DeterministicSpeechAnnotator()

    private var state: ReviewFeatureState = .unavailable(
        selection: nil,
        reason: .noSession
    )
    private var resolver: TranscriptSeekResolver?
    private var commandInFlight = false
    private var pendingSelectionCommand: PendingSelectionCommand?
    private var refreshPending = false
    private var pendingAnnotationVisibility: PendingAnnotationVisibilityCommand?
    private var playbackObserver: Task<Void, Never>?
    private var stateContinuations: [UInt64: AsyncStream<ReviewFeatureState>.Continuation]
        = [:]
    private var nextSubscriberID: UInt64 = 1

    public init(
        sessions: any ReviewSessionPort,
        playback: any ReviewPlaybackPort,
        retranscriber: any ReviewRetranscriptionPort,
        annotationVisibility: any ReviewAnnotationVisibilityPort
    ) {
        self.sessions = sessions
        self.playback = playback
        self.retranscriber = retranscriber
        self.annotationVisibility = annotationVisibility
    }

    deinit { playbackObserver?.cancel() }

    public var currentState: ReviewFeatureState { state }

    public nonisolated var states: AsyncStream<ReviewFeatureState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            Task { await self.addSubscriber(continuation) }
        }
    }

    public func send(_ command: ReviewCommand) async {
        guard !commandInFlight else {
            retainPending(command)
            return
        }
        commandInFlight = true
        ensurePlaybackObservation()
        var next: ReviewCommand? = command
        while let current = next {
            await perform(current)
            if let selection = pendingSelectionCommand {
                pendingSelectionCommand = nil
                refreshPending = false
                next = selection.command
            } else if refreshPending {
                refreshPending = false
                next = .refresh
            } else if let pendingVisibility = pendingAnnotationVisibility {
                pendingAnnotationVisibility = nil
                next = readySnapshot?.selection == pendingVisibility.selection
                    ? .setAnnotationsVisible(pendingVisibility.visible)
                    : nil
            } else {
                next = nil
            }
        }
        commandInFlight = false
    }

    private func retainPending(_ command: ReviewCommand) {
        switch command {
        case let .selectSession(selection):
            pendingSelectionCommand = .select(selection)
            refreshPending = false
        case .clearSelection:
            pendingSelectionCommand = .clear
            refreshPending = false
        case .refresh:
            if pendingSelectionCommand == nil { refreshPending = true }
        case let .setAnnotationsVisible(visible):
            guard let selection = readySnapshot?.selection else { return }
            pendingAnnotationVisibility = PendingAnnotationVisibilityCommand(
                selection: selection,
                visible: visible
            )
        case .seek, .play, .pause, .selectRevision, .retranscribe:
            break
        }
    }

    private func perform(_ command: ReviewCommand) async {
        switch command {
        case let .selectSession(selection):
            await selectSession(selection)
        case .clearSelection:
            await clearSelection()
        case .refresh:
            await refresh()
        case let .seek(lineID, utf8ByteOffset):
            await seek(lineID: lineID, utf8ByteOffset: utf8ByteOffset)
        case .play:
            await applyPlayback(await playback.play())
        case .pause:
            await applyPlayback(await playback.pause())
        case let .setAnnotationsVisible(visible):
            await setAnnotationsVisible(visible)
        case let .selectRevision(revisionID, expectedSelectedRevisionID):
            await selectRevision(
                revisionID,
                expectedSelectedRevisionID: expectedSelectedRevisionID
            )
        case .retranscribe:
            await retranscribe()
        }
    }

    private func selectSession(_ selection: ReviewSelection) async {
        let annotationsVisible = await annotationVisibility.annotationsVisible(
            in: selection.scope
        ) ?? readySnapshot?.annotations.isVisible ?? true
        let previousCapability = readySnapshot?.playback.audioCapabilityID
        resolver = nil
        transition(to: .loading(selection))
        switch await sessions.load(selection) {
        case let .available(snapshot):
            await install(
                snapshot,
                preserving: nil,
                annotationsVisible: annotationsVisible,
                notice: nil
            )
        case .unavailable:
            await invalidateReview(
                selection: selection,
                reason: .noTranscript,
                clearing: previousCapability
            )
        case .integrityMismatch:
            await invalidateReview(
                selection: selection,
                reason: .integrityMismatch,
                clearing: previousCapability
            )
        }
    }

    private func clearSelection() async {
        let capability = readySnapshot?.playback.audioCapabilityID
        await invalidateReview(
            selection: nil,
            reason: .noSession,
            clearing: capability
        )
    }

    private func refresh() async {
        let selection: ReviewSelection
        let previousPlayback: ReviewPlaybackSnapshot?
        switch state {
        case let .ready(ready):
            selection = ready.selection
            previousPlayback = ready.playback
        case let .unavailable(.some(selected), _):
            selection = selected
            previousPlayback = nil
        case .loading, .unavailable(selection: nil, reason: _):
            return
        }
        let annotationsVisible = await annotationVisibility.annotationsVisible(
            in: selection.scope
        ) ?? readySnapshot?.annotations.isVisible ?? true
        switch await sessions.load(selection) {
        case let .available(snapshot):
            await install(
                snapshot,
                preserving: readySnapshot?.playback ?? previousPlayback,
                annotationsVisible: annotationsVisible,
                notice: nil
            )
        case .unavailable:
            await invalidateReview(
                selection: selection,
                reason: .noTranscript,
                clearing: readySnapshot?.playback.audioCapabilityID ??
                    previousPlayback?.audioCapabilityID
            )
        case .integrityMismatch:
            await invalidateReview(
                selection: selection,
                reason: .integrityMismatch,
                clearing: readySnapshot?.playback.audioCapabilityID ??
                    previousPlayback?.audioCapabilityID
            )
        }
    }

    private func seek(lineID: TranscriptLineID, utf8ByteOffset: Int) async {
        guard resolver != nil,
              let milliseconds = resolver?.seekTime(
                  lineID: lineID,
                  utf8ByteOffset: utf8ByteOffset
              )
        else { return }
        await applyPlayback(await playback.seek(toMilliseconds: milliseconds))
    }

    private func setAnnotationsVisible(_ visible: Bool) async {
        guard let ready = readySnapshot,
              ready.annotations.isVisible != visible
        else { return }
        transition(
            to: .ready(
                replacing(ready, activity: .settingAnnotationVisibility)
            )
        )
        let writeResult = await annotationVisibility.setAnnotationsVisible(
            visible,
            in: ready.selection.scope
        )
        let currentVisibility: Bool? = switch writeResult {
        case let .committed(visible),
             let .notCommitted(visible),
             let .commitAmbiguous(visible):
            visible
        case .unavailable:
            nil
        }
        guard let current = readySnapshot,
              current.selection == ready.selection,
              current.selectedRevisionID == ready.selectedRevisionID,
              current.playback.audioCapabilityID ==
                ready.playback.audioCapabilityID,
              current.playback.durationMilliseconds ==
                ready.playback.durationMilliseconds
        else { return }
        transition(
            to: .ready(
                replacing(
                    current,
                    annotations: currentVisibility.map {
                        current.annotations.settingVisibility($0)
                    } ?? current.annotations,
                    activity: nil
                )
            )
        )
    }

    private func selectRevision(
        _ revisionID: TranscriptRevisionID,
        expectedSelectedRevisionID: TranscriptRevisionID
    ) async {
        guard let ready = readySnapshot,
              ready.selectedRevisionID == expectedSelectedRevisionID,
              ready.revisionIDs.contains(revisionID)
        else { return }
        guard revisionID != ready.selectedRevisionID else { return }
        transition(to: .ready(replacing(ready, activity: .selectingRevision)))
        let result = await sessions.selectRevision(
            revisionID,
            for: ready.selection,
            expectedSelectedRevisionID: expectedSelectedRevisionID
        )
        switch result {
        case let .selected(snapshot):
            await install(
                snapshot,
                preserving: readySnapshot?.playback ?? ready.playback,
                annotationsVisible: readySnapshot?.annotations.isVisible ??
                    ready.annotations.isVisible,
                notice: nil
            )
        case .stale:
            switch await sessions.load(ready.selection) {
            case let .available(snapshot):
                await install(
                    snapshot,
                    preserving: readySnapshot?.playback ?? ready.playback,
                    annotationsVisible: readySnapshot?.annotations.isVisible ??
                        ready.annotations.isVisible,
                    notice: .selectionChanged
                )
            case .unavailable:
                await invalidateReview(
                    selection: ready.selection,
                    reason: .noTranscript,
                    clearing: readySnapshot?.playback.audioCapabilityID ??
                        ready.playback.audioCapabilityID
                )
            case .integrityMismatch:
                await invalidateReview(
                    selection: ready.selection,
                    reason: .integrityMismatch,
                    clearing: readySnapshot?.playback.audioCapabilityID ??
                        ready.playback.audioCapabilityID
                )
            }
        case .unavailable:
            await invalidateReview(
                selection: ready.selection,
                reason: .noTranscript,
                clearing: readySnapshot?.playback.audioCapabilityID ??
                    ready.playback.audioCapabilityID
            )
        case .integrityMismatch:
            await invalidateReview(
                selection: ready.selection,
                reason: .integrityMismatch,
                clearing: readySnapshot?.playback.audioCapabilityID ??
                    ready.playback.audioCapabilityID
            )
        case .failed:
            transition(
                to: .ready(
                    replacing(
                        readySnapshot ?? ready,
                        notice: .selectionFailed
                    )
                )
            )
        }
    }

    private func retranscribe() async {
        guard let ready = readySnapshot else { return }
        transition(to: .ready(replacing(ready, activity: .retranscribing)))
        switch await retranscriber.retranscribe(ready.selection) {
        case .completed:
            switch await sessions.load(ready.selection) {
            case let .available(snapshot):
                await install(
                    snapshot,
                    preserving: readySnapshot?.playback ?? ready.playback,
                    annotationsVisible: readySnapshot?.annotations.isVisible ??
                        ready.annotations.isVisible,
                    notice: .retranscribed
                )
            case .unavailable:
                await invalidateReview(
                    selection: ready.selection,
                    reason: .noTranscript,
                    clearing: readySnapshot?.playback.audioCapabilityID ??
                        ready.playback.audioCapabilityID
                )
            case .integrityMismatch:
                await invalidateReview(
                    selection: ready.selection,
                    reason: .integrityMismatch,
                    clearing: readySnapshot?.playback.audioCapabilityID ??
                        ready.playback.audioCapabilityID
                )
            }
        case .unavailable, .failed:
            transition(
                to: .ready(
                    replacing(
                        readySnapshot ?? ready,
                        notice: .retranscriptionFailed
                    )
                )
            )
        }
    }

    private func install(
        _ snapshot: ReviewSessionSnapshot,
        preserving previousPlayback: ReviewPlaybackSnapshot?,
        annotationsVisible: Bool,
        notice: ReviewNotice?
    ) async {
        let playbackSnapshot: ReviewPlaybackSnapshot?
        if let previousPlayback,
           previousPlayback.audioCapabilityID == snapshot.audioCapabilityID,
           previousPlayback.durationMilliseconds ==
            snapshot.canonicalAudioDurationMilliseconds
        {
            playbackSnapshot = previousPlayback
        } else {
            playbackSnapshot = await playback.load(snapshot.audioSource)
        }
        guard let playbackSnapshot,
              playbackSnapshot.audioCapabilityID == snapshot.audioCapabilityID,
              playbackSnapshot.durationMilliseconds ==
                snapshot.canonicalAudioDurationMilliseconds
        else {
            await invalidateReview(
                selection: snapshot.selection,
                reason: .playbackUnavailable,
                clearing: nil
            )
            return
        }
        let nextResolver = TranscriptSeekResolver(
            revision: snapshot.selectedRevision,
            canonicalAudioDurationMilliseconds:
                snapshot.canonicalAudioDurationMilliseconds
        )
        let annotations = ReviewAnnotations(
            isVisible: annotationsVisible,
            projection: annotationProjection(for: snapshot)
        )
        let latestPlayback: ReviewPlaybackSnapshot
        if let current = readySnapshot?.playback,
           current.audioCapabilityID == snapshot.audioCapabilityID,
           current.durationMilliseconds ==
            snapshot.canonicalAudioDurationMilliseconds
        {
            latestPlayback = current
        } else {
            latestPlayback = playbackSnapshot
        }
        resolver = nextResolver
        transition(
            to: .ready(
                ReviewReadySnapshot(
                    selection: snapshot.selection,
                    revisionIDs: snapshot.revisionIDs,
                    selectedRevision: snapshot.selectedRevision,
                    playback: latestPlayback,
                    activeWordID: nextResolver.activeWord(
                        atMilliseconds: latestPlayback.positionMilliseconds
                    ),
                    annotations: annotations,
                    notice: notice
                )
            )
        )
    }

    /// A Review loses all interaction authority as one operation: stale seek
    /// indexes and buffered canonical audio are both revoked before returning.
    private func invalidateReview(
        selection: ReviewSelection?,
        reason: ReviewUnavailableReason,
        clearing audioCapabilityID: ReviewAudioCapabilityID?
    ) async {
        resolver = nil
        transition(to: .unavailable(selection: selection, reason: reason))
        await playback.clear(audioCapabilityID)
    }

    private func applyPlayback(_ playbackSnapshot: ReviewPlaybackSnapshot?) async {
        receivePlayback(playbackSnapshot)
    }

    private func receivePlayback(_ playbackSnapshot: ReviewPlaybackSnapshot?) {
        guard let playbackSnapshot,
              let ready = readySnapshot,
              let resolver,
              playbackSnapshot.audioCapabilityID == ready.playback.audioCapabilityID,
              playbackSnapshot.durationMilliseconds == ready.playback.durationMilliseconds
        else { return }
        transition(
            to: .ready(
                ReviewReadySnapshot(
                    selection: ready.selection,
                    revisionIDs: ready.revisionIDs,
                    selectedRevision: ready.selectedRevision,
                    playback: playbackSnapshot,
                    activeWordID: resolver.activeWord(
                        atMilliseconds: playbackSnapshot.positionMilliseconds
                    ),
                    annotations: ready.annotations,
                    activity: ready.activity,
                    notice: ready.notice
                )
            )
        )
    }

    private func ensurePlaybackObservation() {
        guard playbackObserver == nil else { return }
        let stream = playback.states
        playbackObserver = Task { [weak self] in
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                await self?.receivePlayback(snapshot)
            }
        }
    }

    private var readySnapshot: ReviewReadySnapshot? {
        guard case let .ready(snapshot) = state else { return nil }
        return snapshot
    }

    private func replacing(
        _ ready: ReviewReadySnapshot,
        annotations: ReviewAnnotations? = nil,
        activity: ReviewActivity? = nil,
        notice: ReviewNotice? = nil
    ) -> ReviewReadySnapshot {
        ReviewReadySnapshot(
            selection: ready.selection,
            revisionIDs: ready.revisionIDs,
            selectedRevision: ready.selectedRevision,
            playback: ready.playback,
            activeWordID: ready.activeWordID,
            annotations: annotations ?? ready.annotations,
            activity: activity,
            notice: notice
        )
    }

    private func annotationProjection(
        for snapshot: ReviewSessionSnapshot
    ) -> TranscriptAnnotationProjection {
        do {
            let annotations = try annotator.annotate(
                revision: snapshot.selectedRevision,
                evidence: snapshot.annotationEvidence
            )
            return try TranscriptAnnotationProjector.project(
                annotations,
                over: snapshot.selectedRevision
            )
        } catch {
            return TranscriptAnnotationProjection(
                transcriptRevisionID: snapshot.selectedRevisionID,
                textualOverlays: [],
                audioEvents: []
            )
        }
    }

    private func transition(to next: ReviewFeatureState) {
        state = next
        for continuation in stateContinuations.values {
            continuation.yield(next)
        }
    }

    private func addSubscriber(
        _ continuation: AsyncStream<ReviewFeatureState>.Continuation
    ) {
        let id = nextSubscriberID
        nextSubscriberID &+= 1
        stateContinuations[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
    }

    private func removeSubscriber(_ id: UInt64) {
        stateContinuations[id] = nil
    }
}
