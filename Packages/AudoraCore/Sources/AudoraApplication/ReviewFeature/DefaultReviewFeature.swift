import AudoraDomain

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public actor DefaultReviewFeature: ReviewFeature {
    private enum PendingSelectionCommand {
        case select(ReviewSelection)
        case evidence(LibraryScope, EvidenceReference)
        case clear

        var command: ReviewCommand {
            switch self {
            case let .select(selection): .selectSession(selection)
            case let .evidence(scope, reference):
                .openEvidence(scope: scope, reference: reference)
            case .clear: .clearSelection
            }
        }
    }

    private struct PendingAnnotationVisibilityCommand {
        let selection: ReviewSelection
        let visible: Bool
    }

    private struct PendingLibraryActivationCommand {
        let activation: LibraryActivation?
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
    private var latestLibraryActivation: LibraryActivation?
    private var pendingLibraryActivationCommand: PendingLibraryActivationCommand?
    private var pendingSelectionCommand: PendingSelectionCommand?
    private var refreshPending = false
    private var pendingAnnotationVisibility: PendingAnnotationVisibilityCommand?
    private var libraryNavigationReserved = false
    private var libraryNavigationCapturedSelection: ReviewSelection?
    private var libraryCatalogSessionLease: LibraryCatalogSessionMutationLease?
    private var libraryCatalogCapturedSelection: ReviewSelection?
    private var nextLibraryCatalogSessionLeaseToken: UInt64 = 1
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
        guard !libraryNavigationReserved,
              libraryCatalogSessionLease == nil
        else { return }
        guard !commandInFlight else {
            retainPending(command)
            return
        }
        commandInFlight = true
        ensurePlaybackObservation()
        var next: ReviewCommand? = command
        while let current = next {
            await perform(current)
            if let activation = pendingLibraryActivationCommand {
                pendingLibraryActivationCommand = nil
                next = .activateLibraryAuthority(activation.activation)
            } else if let selection = pendingSelectionCommand {
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

    public func reserveLibraryNavigation() async -> Bool {
        guard !libraryNavigationReserved,
              libraryCatalogSessionLease == nil,
              !commandInFlight
        else { return false }

        // Install the fence before awaiting playback revocation so reentrant
        // Review ingress cannot reacquire the old Library's authority.
        libraryNavigationReserved = true
        libraryNavigationCapturedSelection = currentSelection
        await clearSelection()
        return true
    }

    public func finishLibraryNavigation(_ result: LibraryCommandResult) async {
        guard libraryNavigationReserved else { return }
        let capturedSelection = libraryNavigationCapturedSelection

        switch result {
        case .noSelectionMutation:
            if let capturedSelection {
                await selectSession(capturedSelection)
            }
        case let .activated(activation):
            latestLibraryActivation = activation
        case .deactivated:
            latestLibraryActivation = nil
        }

        libraryNavigationCapturedSelection = nil
        libraryNavigationReserved = false
    }

    public func reserveLibraryCatalogSessionMutation(
        _ mutation: LibraryCatalogSessionMutation
    ) async -> LibraryCatalogSessionMutationLease? {
        guard !libraryNavigationReserved,
              libraryCatalogSessionLease == nil,
              nextLibraryCatalogSessionLeaseToken > 0,
              !commandInFlight,
              latestLibraryActivation == mutation.activation
        else { return nil }

        let lease = LibraryCatalogSessionMutationLease(
            token: nextLibraryCatalogSessionLeaseToken,
            mutation: mutation
        )
        nextLibraryCatalogSessionLeaseToken =
            nextLibraryCatalogSessionLeaseToken == .max
            ? 0
            : nextLibraryCatalogSessionLeaseToken + 1
        let selected = currentSelection
        let capturedSelection: ReviewSelection?
        if let selected,
           selected.scope == mutation.activation.scope,
           mutation.sessionIDs.contains(selected.sessionID)
        {
            capturedSelection = selected
        } else {
            capturedSelection = nil
        }

        // Fence all Review ingress, but revoke playback only when this exact
        // Session is part of the mutation. Unrelated playback remains valid.
        libraryCatalogSessionLease = lease
        libraryCatalogCapturedSelection = capturedSelection
        if capturedSelection != nil {
            await clearSelection()
        }
        return lease
    }

    public func finishLibraryCatalogSessionMutation(
        _ lease: LibraryCatalogSessionMutationLease,
        completion: LibraryCatalogSessionMutationCompletion
    ) async -> LibraryCatalogSessionMutationFinishResult {
        guard libraryCatalogSessionLease == lease else { return .notOwned }
        let capturedSelection = libraryCatalogCapturedSelection
        let shouldReload: Bool
        switch completion {
        case .aborted:
            shouldReload = capturedSelection != nil
        case let .completed(.available(catalog)):
            shouldReload = capturedSelection.map { selection in
                catalog.active.contains {
                    $0.aggregate == .session(selection.sessionID)
                }
            } == true
        case .completed(.readOnly), .completed(.unavailable),
             .completed(.integrityMismatch):
            shouldReload = false
        }

        if shouldReload, let capturedSelection {
            await selectSession(capturedSelection)
        }
        libraryCatalogCapturedSelection = nil
        libraryCatalogSessionLease = nil
        return .consumed
    }

    private func retainPending(_ command: ReviewCommand) {
        switch command {
        case let .activateLibraryAuthority(activation):
            pendingLibraryActivationCommand = PendingLibraryActivationCommand(
                activation: activation
            )
            pendingSelectionCommand = nil
            refreshPending = false
        case let .selectSession(selection):
            pendingSelectionCommand = .select(selection)
            refreshPending = false
        case let .openEvidence(scope, reference):
            pendingSelectionCommand = .evidence(scope, reference)
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
        case let .activateLibraryAuthority(activation):
            guard latestLibraryActivation != activation else { return }
            latestLibraryActivation = activation
            await clearSelection()
        case let .selectSession(selection):
            await selectSession(selection)
        case let .openEvidence(scope, reference):
            await openEvidence(reference, in: scope)
        case .clearSelection:
            await clearSelection()
        case .refresh:
            await refresh()
        case let .seek(lineID, utf8ByteOffset):
            await seek(lineID: lineID, utf8ByteOffset: utf8ByteOffset)
        case .play:
            guard let capabilityID = readySnapshot?.playback?.audioCapabilityID
            else { return }
            await applyPlayback(
                await playback.play(),
                expectedCapabilityID: capabilityID
            )
        case .pause:
            guard let capabilityID = readySnapshot?.playback?.audioCapabilityID
            else { return }
            await applyPlayback(
                await playback.pause(),
                expectedCapabilityID: capabilityID
            )
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
        let previousCapability = readySnapshot?.playback?.audioCapabilityID
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

    private func openEvidence(
        _ reference: EvidenceReference,
        in scope: LibraryScope
    ) async {
        let selection = ReviewSelection(scope: scope, sessionID: reference.sessionID)
        let annotationsVisible = await annotationVisibility.annotationsVisible(
            in: scope
        ) ?? readySnapshot?.annotations.isVisible ?? true
        let previousCapability = readySnapshot?.playback?.audioCapabilityID
        let previousPlayback = readySnapshot?.selection == selection &&
            readySnapshot?.playbackAvailable == true
            ? readySnapshot?.playback
            : nil
        resolver = nil
        transition(to: .loading(selection))

        switch await exactSnapshot(for: reference, selection: selection) {
        case let .available(snapshot):
            await install(
                snapshot,
                preserving: previousPlayback,
                annotationsVisible: annotationsVisible,
                notice: nil,
                evidenceReference: reference
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

    private func exactSnapshot(
        for reference: EvidenceReference,
        selection: ReviewSelection
    ) async -> ReviewSessionReadResult {
        let loaded: ReviewSessionSnapshot
        switch await sessions.load(selection) {
        case let .available(snapshot): loaded = snapshot
        case .unavailable: return .unavailable
        case .integrityMismatch: return .integrityMismatch
        }
        guard loaded.revisionIDs.contains(reference.transcriptRevisionID) else {
            return .integrityMismatch
        }
        if loaded.selectedRevisionID == reference.transcriptRevisionID {
            return .available(loaded)
        }
        let first = await sessions.selectRevision(
            reference.transcriptRevisionID,
            for: selection,
            expectedSelectedRevisionID: loaded.selectedRevisionID
        )
        switch first {
        case let .selected(snapshot):
            return snapshot.selectedRevisionID == reference.transcriptRevisionID
                ? .available(snapshot)
                : .integrityMismatch
        case .stale:
            break
        case .unavailable, .failed:
            return .unavailable
        case .integrityMismatch:
            return .integrityMismatch
        }

        let refreshed: ReviewSessionSnapshot
        switch await sessions.load(selection) {
        case let .available(snapshot): refreshed = snapshot
        case .unavailable: return .unavailable
        case .integrityMismatch: return .integrityMismatch
        }
        guard refreshed.revisionIDs.contains(reference.transcriptRevisionID) else {
            return .integrityMismatch
        }
        if refreshed.selectedRevisionID == reference.transcriptRevisionID {
            return .available(refreshed)
        }
        switch await sessions.selectRevision(
            reference.transcriptRevisionID,
            for: selection,
            expectedSelectedRevisionID: refreshed.selectedRevisionID
        ) {
        case let .selected(snapshot):
            return snapshot.selectedRevisionID == reference.transcriptRevisionID
                ? .available(snapshot)
                : .integrityMismatch
        case .integrityMismatch:
            return .integrityMismatch
        case .stale, .unavailable, .failed:
            return .unavailable
        }
    }

    private func clearSelection() async {
        let capability = readySnapshot?.playback?.audioCapabilityID
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
            previousPlayback = ready.playbackAvailable ? ready.playback : nil
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
                preserving: availableReadyPlayback ?? previousPlayback,
                annotationsVisible: annotationsVisible,
                notice: nil
            )
        case .unavailable:
            await invalidateReview(
                selection: selection,
                reason: .noTranscript,
                clearing: readySnapshot?.playback?.audioCapabilityID ??
                    previousPlayback?.audioCapabilityID
            )
        case .integrityMismatch:
            await invalidateReview(
                selection: selection,
                reason: .integrityMismatch,
                clearing: readySnapshot?.playback?.audioCapabilityID ??
                    previousPlayback?.audioCapabilityID
            )
        }
    }

    private func seek(lineID: TranscriptLineID, utf8ByteOffset: Int) async {
        guard let capabilityID = readySnapshot?.playback?.audioCapabilityID,
              resolver != nil,
              let milliseconds = resolver?.seekTime(
                  lineID: lineID,
                  utf8ByteOffset: utf8ByteOffset
              )
        else { return }
        await applyPlayback(
            await playback.seek(toMilliseconds: milliseconds),
            expectedCapabilityID: capabilityID
        )
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
              current.playback?.audioCapabilityID ==
                ready.playback?.audioCapabilityID,
              current.playback?.durationMilliseconds ==
                ready.playback?.durationMilliseconds
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
                preserving: availableReadyPlayback ??
                    (ready.playbackAvailable ? ready.playback : nil),
                annotationsVisible: readySnapshot?.annotations.isVisible ??
                    ready.annotations.isVisible,
                notice: nil
            )
        case .stale:
            switch await sessions.load(ready.selection) {
            case let .available(snapshot):
                await install(
                    snapshot,
                    preserving: availableReadyPlayback ??
                        (ready.playbackAvailable ? ready.playback : nil),
                    annotationsVisible: readySnapshot?.annotations.isVisible ??
                        ready.annotations.isVisible,
                    notice: .selectionChanged
                )
            case .unavailable:
                await invalidateReview(
                    selection: ready.selection,
                    reason: .noTranscript,
                    clearing: readySnapshot?.playback?.audioCapabilityID ??
                        ready.playback?.audioCapabilityID
                )
            case .integrityMismatch:
                await invalidateReview(
                    selection: ready.selection,
                    reason: .integrityMismatch,
                    clearing: readySnapshot?.playback?.audioCapabilityID ??
                        ready.playback?.audioCapabilityID
                )
            }
        case .unavailable:
            await invalidateReview(
                selection: ready.selection,
                reason: .noTranscript,
                clearing: readySnapshot?.playback?.audioCapabilityID ??
                    ready.playback?.audioCapabilityID
            )
        case .integrityMismatch:
            await invalidateReview(
                selection: ready.selection,
                reason: .integrityMismatch,
                clearing: readySnapshot?.playback?.audioCapabilityID ??
                    ready.playback?.audioCapabilityID
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
        guard let ready = readySnapshot,
              ready.retranscriptionAvailable
        else { return }
        transition(to: .ready(replacing(ready, activity: .retranscribing)))
        switch await retranscriber.retranscribe(ready.selection) {
        case .completed:
            switch await sessions.load(ready.selection) {
            case let .available(snapshot):
                await install(
                    snapshot,
                    preserving: availableReadyPlayback ??
                        (ready.playbackAvailable ? ready.playback : nil),
                    annotationsVisible: readySnapshot?.annotations.isVisible ??
                        ready.annotations.isVisible,
                    notice: .retranscribed
                )
            case .unavailable:
                await invalidateReview(
                    selection: ready.selection,
                    reason: .noTranscript,
                    clearing: readySnapshot?.playback?.audioCapabilityID ??
                        ready.playback?.audioCapabilityID
                )
            case .integrityMismatch:
                await invalidateReview(
                    selection: ready.selection,
                    reason: .integrityMismatch,
                    clearing: readySnapshot?.playback?.audioCapabilityID ??
                        ready.playback?.audioCapabilityID
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
        notice: ReviewNotice?,
        evidenceReference: EvidenceReference? = nil
    ) async {
        let nextResolver = TranscriptSeekResolver(
            revision: snapshot.selectedRevision,
            canonicalAudioDurationMilliseconds:
                snapshot.selectedRevision.durationMilliseconds
        )
        let resolvedEvidence = evidenceReference.flatMap {
            nextResolver.resolveEvidence($0)
        }
        if evidenceReference != nil, resolvedEvidence == nil {
            await invalidateReview(
                selection: snapshot.selection,
                reason: .integrityMismatch,
                clearing: previousPlayback?.audioCapabilityID
            )
            return
        }
        let loadedPlayback: ReviewPlaybackSnapshot?
        if let audioSource = snapshot.audioSource {
            if let previousPlayback,
               previousPlayback.audioCapabilityID == audioSource.audioCapabilityID,
               previousPlayback.durationMilliseconds ==
                audioSource.durationMilliseconds
            {
                loadedPlayback = previousPlayback
            } else {
                loadedPlayback = await playback.load(audioSource)
            }
        } else {
            await playback.clear(
                previousPlayback?.audioCapabilityID ??
                    readySnapshot?.playback?.audioCapabilityID
            )
            loadedPlayback = nil
        }
        let verifiedPlayback: ReviewPlaybackSnapshot?
        if let audioSource = snapshot.audioSource,
           let loadedPlayback,
           loadedPlayback.audioCapabilityID == audioSource.audioCapabilityID,
           loadedPlayback.durationMilliseconds == audioSource.durationMilliseconds
        {
            verifiedPlayback = loadedPlayback
        } else {
            if snapshot.audioSource != nil { await playback.clear(nil) }
            verifiedPlayback = nil
        }
        let annotations = ReviewAnnotations(
            isVisible: annotationsVisible,
            projection: annotationProjection(for: snapshot)
        )
        let latestPlayback: ReviewPlaybackSnapshot?
        if let audioSource = snapshot.audioSource,
           let current = readySnapshot?.playback,
           current.audioCapabilityID == audioSource.audioCapabilityID,
           current.durationMilliseconds == audioSource.durationMilliseconds
        {
            latestPlayback = current
        } else {
            latestPlayback = verifiedPlayback
        }
        let navigatedPlayback: ReviewPlaybackSnapshot?
        if let audioSource = snapshot.audioSource,
           latestPlayback != nil,
           let resolvedEvidence,
           let sought = await playback.seek(
               toMilliseconds: resolvedEvidence.seekMilliseconds
           ),
           sought.audioCapabilityID == audioSource.audioCapabilityID,
           sought.durationMilliseconds == audioSource.durationMilliseconds
        {
            navigatedPlayback = sought
        } else {
            navigatedPlayback = latestPlayback
        }
        resolver = nextResolver
        transition(
            to: .ready(
                ReviewReadySnapshot(
                    selection: snapshot.selection,
                    revisionIDs: snapshot.revisionIDs,
                    selectedRevision: snapshot.selectedRevision,
                    playback: navigatedPlayback,
                    retranscriptionAvailable: snapshot.audioSource != nil,
                    activeWordID: navigatedPlayback.flatMap {
                        nextResolver.activeWord(
                            atMilliseconds: $0.positionMilliseconds
                        )
                    },
                    evidenceHighlight: resolvedEvidence?.highlight,
                    annotations: annotations,
                    notice: navigatedPlayback == nil
                        ? .playbackUnavailable
                        : notice
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

    private func applyPlayback(
        _ playbackSnapshot: ReviewPlaybackSnapshot?,
        expectedCapabilityID: ReviewAudioCapabilityID
    ) async {
        guard let ready = readySnapshot,
              let readyPlayback = ready.playback,
              readyPlayback.audioCapabilityID == expectedCapabilityID
        else { return }
        guard let playbackSnapshot,
              playbackSnapshot.audioCapabilityID == expectedCapabilityID,
              playbackSnapshot.durationMilliseconds ==
                readyPlayback.durationMilliseconds
        else {
            transition(
                to: .ready(
                    ReviewReadySnapshot(
                        selection: ready.selection,
                        revisionIDs: ready.revisionIDs,
                        selectedRevision: ready.selectedRevision,
                        playback: nil,
                        retranscriptionAvailable: ready.retranscriptionAvailable,
                        activeWordID: nil,
                        evidenceHighlight: ready.evidenceHighlight,
                        annotations: ready.annotations,
                        activity: ready.activity,
                        notice: .playbackUnavailable
                    )
                )
            )
            await playback.clear(expectedCapabilityID)
            return
        }
        receivePlayback(playbackSnapshot)
    }

    private func receivePlayback(_ playbackSnapshot: ReviewPlaybackSnapshot?) {
        guard let playbackSnapshot,
              let ready = readySnapshot,
              let readyPlayback = ready.playback,
              let resolver,
              playbackSnapshot.audioCapabilityID == readyPlayback.audioCapabilityID,
              playbackSnapshot.durationMilliseconds ==
                readyPlayback.durationMilliseconds
        else { return }
        transition(
            to: .ready(
                ReviewReadySnapshot(
                    selection: ready.selection,
                    revisionIDs: ready.revisionIDs,
                    selectedRevision: ready.selectedRevision,
                    playback: playbackSnapshot,
                    retranscriptionAvailable: ready.retranscriptionAvailable,
                    activeWordID: resolver.activeWord(
                        atMilliseconds: playbackSnapshot.positionMilliseconds
                    ),
                    evidenceHighlight: ready.evidenceHighlight,
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

    private var currentSelection: ReviewSelection? {
        switch state {
        case let .ready(snapshot): snapshot.selection
        case let .loading(selection): selection
        case let .unavailable(selection, _): selection
        }
    }

    private var availableReadyPlayback: ReviewPlaybackSnapshot? {
        readySnapshot?.playback
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
            retranscriptionAvailable: ready.retranscriptionAvailable,
            activeWordID: ready.activeWordID,
            evidenceHighlight: ready.evidenceHighlight,
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
