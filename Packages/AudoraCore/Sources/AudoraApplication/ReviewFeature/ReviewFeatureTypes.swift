import AudoraDomain

public struct ReviewSelection: Equatable, Sendable {
    public let scope: LibraryScope
    public let sessionID: SessionID

    public init(scope: LibraryScope, sessionID: SessionID) {
        self.scope = scope
        self.sessionID = sessionID
    }
}

public enum ReviewSnapshotError: Error, Equatable, Sendable {
    case invalidAudioCapability
    case invalidDuration
    case invalidRevisionInventory
    case inconsistentSelectedRevision
}

/// Process-local authority for one verified canonical Session audio snapshot.
/// Review passes the identifier to playback without learning a filesystem path.
public struct ReviewAudioCapabilityID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard (1...128).contains(rawValue.utf8.count), rawValue.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else {
            throw ReviewSnapshotError.invalidAudioCapability
        }
        self.rawValue = rawValue
    }
}

/// One synchronized read of the Session manifest, selected immutable Revision,
/// inventory, and canonical-audio authority.
public struct ReviewSessionSnapshot: Equatable, Sendable {
    public let selection: ReviewSelection
    public let revisionIDs: [TranscriptRevisionID]
    public let selectedRevision: TranscriptRevision
    public let audioCapabilityID: ReviewAudioCapabilityID
    public let canonicalAudioDurationMilliseconds: UInt64
    public let annotationEvidence: SpeechAnnotationEvidence

    public init(
        selection: ReviewSelection,
        revisionIDs: [TranscriptRevisionID],
        selectedRevision: TranscriptRevision,
        audioCapabilityID: ReviewAudioCapabilityID,
        canonicalAudioDurationMilliseconds: UInt64,
        annotationEvidence: SpeechAnnotationEvidence = .none
    ) throws {
        guard canonicalAudioDurationMilliseconds > 0,
              canonicalAudioDurationMilliseconds <= 2_700_000
        else { throw ReviewSnapshotError.invalidDuration }
        guard !revisionIDs.isEmpty,
              revisionIDs.count <= TranscriptRevisionLimits.maximumSessionRevisionCount,
              Set(revisionIDs).count == revisionIDs.count
        else { throw ReviewSnapshotError.invalidRevisionInventory }
        guard selectedRevision.sessionID == selection.sessionID,
              selectedRevision.durationMilliseconds == canonicalAudioDurationMilliseconds,
              revisionIDs.contains(selectedRevision.revisionID)
        else { throw ReviewSnapshotError.inconsistentSelectedRevision }
        self.selection = selection
        self.revisionIDs = revisionIDs
        self.selectedRevision = selectedRevision
        self.audioCapabilityID = audioCapabilityID
        self.canonicalAudioDurationMilliseconds = canonicalAudioDurationMilliseconds
        self.annotationEvidence = annotationEvidence
    }

    public var selectedRevisionID: TranscriptRevisionID {
        selectedRevision.revisionID
    }

    public var audioSource: ReviewAudioSource {
        ReviewAudioSource(
            selection: selection,
            audioCapabilityID: audioCapabilityID,
            durationMilliseconds: canonicalAudioDurationMilliseconds
        )
    }
}

public struct ReviewAudioSource: Equatable, Sendable {
    public let selection: ReviewSelection
    public let audioCapabilityID: ReviewAudioCapabilityID
    public let durationMilliseconds: UInt64

    public init(
        selection: ReviewSelection,
        audioCapabilityID: ReviewAudioCapabilityID,
        durationMilliseconds: UInt64
    ) {
        self.selection = selection
        self.audioCapabilityID = audioCapabilityID
        self.durationMilliseconds = durationMilliseconds
    }
}

public enum ReviewPlaybackStatus: String, Equatable, Sendable {
    case paused
    case playing
    case ended
}

public struct ReviewPlaybackSnapshot: Equatable, Sendable {
    public let audioCapabilityID: ReviewAudioCapabilityID
    public let positionMilliseconds: UInt64
    public let durationMilliseconds: UInt64
    public let status: ReviewPlaybackStatus

    public init(
        audioCapabilityID: ReviewAudioCapabilityID,
        positionMilliseconds: UInt64,
        durationMilliseconds: UInt64,
        status: ReviewPlaybackStatus
    ) {
        self.audioCapabilityID = audioCapabilityID
        self.positionMilliseconds = min(positionMilliseconds, durationMilliseconds)
        self.durationMilliseconds = durationMilliseconds
        self.status = status
    }
}

public enum ReviewActivity: Equatable, Sendable {
    case settingAnnotationVisibility
    case selectingRevision
    case retranscribing
}

public enum ReviewNotice: Equatable, Sendable {
    case selectionChanged
    case selectionFailed
    case retranscribed
    case retranscriptionFailed
    case playbackUnavailable
}

/// Presentation metadata derived from immutable Revision evidence. Visibility
/// controls only whether the metadata is drawn; projection anchors remain
/// available so hiding annotations cannot rewrite transcript or seek state.
public struct ReviewAnnotations: Equatable, Sendable {
    public let isVisible: Bool
    public let projection: TranscriptAnnotationProjection

    public init(
        isVisible: Bool,
        projection: TranscriptAnnotationProjection
    ) {
        self.isVisible = isVisible
        self.projection = projection
    }

    public func settingVisibility(_ isVisible: Bool) -> ReviewAnnotations {
        ReviewAnnotations(isVisible: isVisible, projection: projection)
    }
}

public struct ReviewReadySnapshot: Equatable, Sendable {
    public let selection: ReviewSelection
    public let revisionIDs: [TranscriptRevisionID]
    public let selectedRevision: TranscriptRevision
    public let playback: ReviewPlaybackSnapshot
    public let activeWordID: TranscriptWordID?
    public let annotations: ReviewAnnotations
    public let activity: ReviewActivity?
    public let notice: ReviewNotice?

    public init(
        selection: ReviewSelection,
        revisionIDs: [TranscriptRevisionID],
        selectedRevision: TranscriptRevision,
        playback: ReviewPlaybackSnapshot,
        activeWordID: TranscriptWordID?,
        annotations: ReviewAnnotations,
        activity: ReviewActivity? = nil,
        notice: ReviewNotice? = nil
    ) {
        self.selection = selection
        self.revisionIDs = revisionIDs
        self.selectedRevision = selectedRevision
        self.playback = playback
        self.activeWordID = activeWordID
        self.annotations = annotations
        self.activity = activity
        self.notice = notice
    }

    public var selectedRevisionID: TranscriptRevisionID {
        selectedRevision.revisionID
    }
}

public enum ReviewUnavailableReason: Equatable, Sendable {
    case noSession
    case noTranscript
    case integrityMismatch
    case playbackUnavailable
}

public enum ReviewFeatureState: Equatable, Sendable {
    case unavailable(selection: ReviewSelection?, reason: ReviewUnavailableReason)
    case loading(ReviewSelection)
    case ready(ReviewReadySnapshot)
}

public enum ReviewCommand: Equatable, Sendable {
    case selectSession(ReviewSelection)
    case clearSelection
    case refresh
    case seek(lineID: TranscriptLineID, utf8ByteOffset: Int)
    case play
    case pause
    case setAnnotationsVisible(Bool)
    case selectRevision(
        TranscriptRevisionID,
        expectedSelectedRevisionID: TranscriptRevisionID
    )
    case retranscribe
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol ReviewFeature: Sendable {
    var currentState: ReviewFeatureState { get async }
    var states: AsyncStream<ReviewFeatureState> { get }
    func send(_ command: ReviewCommand) async
}
