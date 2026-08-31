import AudoraDomain

public enum ReviewSessionReadResult: Equatable, Sendable {
    case available(ReviewSessionSnapshot)
    case unavailable
    case integrityMismatch
}

public enum ReviewRevisionSelectionResult: Equatable, Sendable {
    case selected(ReviewSessionSnapshot)
    case stale
    case unavailable
    case integrityMismatch
    case failed
}

public protocol ReviewSessionPort: Sendable {
    func load(_ selection: ReviewSelection) async -> ReviewSessionReadResult

    /// Compare-and-swap of the selected Revision pointer only. Implementations
    /// must never rewrite or delete an inventoried Revision.
    func selectRevision(
        _ revisionID: TranscriptRevisionID,
        for selection: ReviewSelection,
        expectedSelectedRevisionID: TranscriptRevisionID
    ) async -> ReviewRevisionSelectionResult
}

/// Narrow transport-free playback boundary. The port can resolve only the
/// opaque canonical-audio capability supplied by ReviewSessionPort.
public protocol ReviewPlaybackPort: Sendable {
    var states: AsyncStream<ReviewPlaybackSnapshot> { get }
    func load(_ source: ReviewAudioSource) async -> ReviewPlaybackSnapshot?
    func play() async -> ReviewPlaybackSnapshot?
    func pause() async -> ReviewPlaybackSnapshot?
    func seek(toMilliseconds milliseconds: UInt64) async -> ReviewPlaybackSnapshot?
    func clear(_ audioCapabilityID: ReviewAudioCapabilityID?) async
}

public enum ReviewRetranscriptionResult: Equatable, Sendable {
    case completed
    case unavailable
    case failed
}

/// Command seam into the existing Session-processing feature. Review does not
/// own worker lifecycle, progress, cancellation, or recovery.
public protocol ReviewRetranscriptionPort: Sendable {
    func retranscribe(_ selection: ReviewSelection) async -> ReviewRetranscriptionResult
}

/// Global portable preference seam. The selected Review remains authoritative
/// when this preference cannot be read or written.
public protocol ReviewAnnotationVisibilityPort: Sendable {
    func annotationsVisible(in scope: LibraryScope) async -> Bool?
    func setAnnotationsVisible(
        _ visible: Bool,
        in scope: LibraryScope
    ) async -> Bool
}
