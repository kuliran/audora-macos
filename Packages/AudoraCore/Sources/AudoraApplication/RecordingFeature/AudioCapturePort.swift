import AudoraDomain

public struct MicrophoneRecordingRequest: Equatable, Sendable {
    public let libraryScope: LibraryScope
    public let recordingID: RecordingID
    public let sessionID: SessionID
    public let startedAt: UTCInstant
    public let canonicalFormat: CanonicalAudioFormat
    public let maximumFrames: UInt64

    public init(
        libraryScope: LibraryScope,
        recordingID: RecordingID,
        sessionID: SessionID,
        startedAt: UTCInstant,
        canonicalFormat: CanonicalAudioFormat = .versionOne,
        maximumFrames: UInt64 = CanonicalRecordingLimits.maximumFrames
    ) {
        self.libraryScope = libraryScope
        self.recordingID = recordingID
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.canonicalFormat = canonicalFormat
        self.maximumFrames = maximumFrames
    }
}

public struct ActiveCaptureFeed: Sendable {
    public let recordingID: RecordingID
    public let observations: AsyncStream<CaptureObservation>

    public init(
        recordingID: RecordingID,
        observations: AsyncStream<CaptureObservation>
    ) {
        self.recordingID = recordingID
        self.observations = observations
    }
}

public enum CaptureStartOutcome: Sendable {
    case started(ActiveCaptureFeed)
    case rejected(RecordingFailure)
}

public enum ActiveCaptureCommand: Equatable, Sendable {
    case setMuted(Bool)
    case stop
    case discardConfirmed
}

public enum CaptureCommandOutcome: Equatable, Sendable {
    case accepted
    case rejected(RecordingFailure)
}

public enum CaptureTerminalReason: String, Equatable, Sendable {
    case userStop
    case durationLimit
    case interruption
}

public enum CaptureLevelUnavailableReason: String, Equatable, Sendable {
    case muted
    case captureGap
    case stale
}

public enum CaptureLevel: Equatable, Sendable {
    case measured(Double)
    case unavailable(CaptureLevelUnavailableReason)
}

public struct SessionSealedReceipt: Equatable, Sendable {
    public let libraryID: LibraryID
    public let recordingID: RecordingID
    public let sessionID: SessionID
    public let frameCount: UInt64
    public let fingerprint: AudioFingerprint

    public init(
        libraryID: LibraryID,
        recordingID: RecordingID,
        sessionID: SessionID,
        frameCount: UInt64,
        fingerprint: AudioFingerprint
    ) {
        self.libraryID = libraryID
        self.recordingID = recordingID
        self.sessionID = sessionID
        self.frameCount = frameCount
        self.fingerprint = fingerprint
    }
}

/// Semantically untrusted metadata for one fully staged canonical recording.
/// Infrastructure may report these bounded values, but only Application may
/// promote them into a `SealedAudioAsset` and `SealedSession`.
public struct StagedUnavailableInterval: Equatable, Sendable {
    public let startFrame: UInt64
    public let endFrame: UInt64
    public let reasons: [String]

    public init(startFrame: UInt64, endFrame: UInt64, reasons: [String]) {
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.reasons = reasons
    }
}

public struct StagedRecordingSealCandidate: Equatable, Sendable {
    public static let maximumUnavailableIntervalCount = 8_192

    public let recordingID: String
    public let sessionID: String
    public let libraryID: String
    public let startedAt: String
    public let terminalReason: String
    public let sourceKind: String
    public let canonicalAudioPath: String
    public let sampleRateHz: UInt32
    public let channelCount: UInt8
    public let encoding: String
    public let frameCount: UInt64
    public let canonicalSHA256: String
    public let unavailableIntervals: [StagedUnavailableInterval]

    public init(
        recordingID: String,
        sessionID: String,
        libraryID: String,
        startedAt: String,
        terminalReason: String,
        sourceKind: String,
        canonicalAudioPath: String,
        sampleRateHz: UInt32,
        channelCount: UInt8,
        encoding: String,
        frameCount: UInt64,
        canonicalSHA256: String,
        unavailableIntervals: [StagedUnavailableInterval]
    ) {
        self.recordingID = recordingID
        self.sessionID = sessionID
        self.libraryID = libraryID
        self.startedAt = startedAt
        self.terminalReason = terminalReason
        self.sourceKind = sourceKind
        self.canonicalAudioPath = canonicalAudioPath
        self.sampleRateHz = sampleRateHz
        self.channelCount = channelCount
        self.encoding = encoding
        self.frameCount = frameCount
        self.canonicalSHA256 = canonicalSHA256
        self.unavailableIntervals = unavailableIntervals
    }
}

public struct ValidatedRecordingPublication: Equatable, Sendable {
    public let candidate: StagedRecordingSealCandidate
    public let libraryID: LibraryID
    public let recordingID: RecordingID
    public let session: SealedSession
    public let terminalReason: CaptureTerminalReason

    init(
        candidate: StagedRecordingSealCandidate,
        libraryID: LibraryID,
        recordingID: RecordingID,
        session: SealedSession,
        terminalReason: CaptureTerminalReason
    ) {
        self.candidate = candidate
        self.libraryID = libraryID
        self.recordingID = recordingID
        self.session = session
        self.terminalReason = terminalReason
    }

    public var receipt: SessionSealedReceipt {
        SessionSealedReceipt(
            libraryID: libraryID,
            recordingID: recordingID,
            sessionID: session.sessionID,
            frameCount: session.audio.frameCount,
            fingerprint: session.audio.fingerprint
        )
    }
}

public enum RecordingPublicationCommand: Equatable, Sendable {
    case publish(ValidatedRecordingPublication)
    case preserveForRecovery(MicrophoneRecordingRequest)
}

public enum RecordingPublicationOutcome: Equatable, Sendable {
    case installed(SessionSealedReceipt)
    case recoveryRequired(RecordingRecoveryItem)
    case failed(RecordingFailure)
}

public enum CaptureObservation: Equatable, Sendable {
    case progress(frameCount: UInt64, level: CaptureLevel)
    case muteChanged(isMuted: Bool, effectiveFrame: UInt64)
    case finishing(reason: CaptureTerminalReason, frameCount: UInt64)
    case sealing(reason: CaptureTerminalReason, frameCount: UInt64)
    case sealCandidate(StagedRecordingSealCandidate)
    case discarded(recordingID: RecordingID)
    case recoveryRequired(RecordingRecoveryItem)
}

public enum RecordingRecoveryAvailability: String, Equatable, Sendable {
    case sealOrDiscard
    case discardOnly
    /// The immutable Session is already authoritative. Only exact staging
    /// cleanup remains; recording Discard must never delete the committed work.
    case committedCleanup
    /// A newer staging root is preserved byte-for-byte for a newer Audora.
    /// Neither Seal nor Discard has authority over it.
    case readOnlyNewerSchema
    /// A recognized Recording root cannot be safely interpreted or removed by
    /// this build. It remains visible and blocks new capture.
    case readOnlyUnsupported
}

public enum RecordingRecoveryInspectionFailure: String, Equatable, Sendable {
    case libraryAuthorityUnavailable
    case stagingListingUnavailable
}

public enum RecordingRecoveryInspectionStatus: Equatable, Sendable {
    case complete
    case blocked(RecordingRecoveryInspectionFailure)
}

public struct RecordingRecoveryItem: Equatable, Sendable {
    public let recordingID: RecordingID
    public let sessionID: SessionID?
    public let startedAt: UTCInstant?
    public let durableFrameCount: UInt64
    public let availability: RecordingRecoveryAvailability

    public init(
        recordingID: RecordingID,
        sessionID: SessionID? = nil,
        startedAt: UTCInstant? = nil,
        durableFrameCount: UInt64,
        availability: RecordingRecoveryAvailability
    ) {
        self.recordingID = recordingID
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.durableFrameCount = durableFrameCount
        self.availability = availability
    }
}

public struct RecordingRecoveryCatalog: Equatable, Sendable {
    /// `staging/recordings` is a finite, Audora-owned inventory. Each staging
    /// entry can contribute one recovery item and one authoritative receipt,
    /// so these public arrays are bounded independently rather than by their
    /// combined count.
    public static let maximumEntryCount = 128

    public let items: [RecordingRecoveryItem]
    public let reconciledSeals: [SessionSealedReceipt]
    public let inspectionStatus: RecordingRecoveryInspectionStatus

    public init(
        items: [RecordingRecoveryItem],
        reconciledSeals: [SessionSealedReceipt] = [],
        inspectionStatus: RecordingRecoveryInspectionStatus = .complete
    ) {
        guard items.count <= Self.maximumEntryCount,
              reconciledSeals.count <= Self.maximumEntryCount
        else {
            self.items = []
            self.reconciledSeals = []
            self.inspectionStatus = .blocked(.stagingListingUnavailable)
            return
        }
        self.items = items
        self.reconciledSeals = reconciledSeals
        self.inspectionStatus = inspectionStatus
    }

    public var isClear: Bool { items.isEmpty && inspectionStatus == .complete }
}

public enum RecordingRecoveryAction: Equatable, Sendable {
    case seal
    case discard
}

public enum RecordingRecoveryOutcome: Equatable, Sendable {
    case sealCandidate(StagedRecordingSealCandidate)
    case discarded(recordingID: RecordingID)
    case failed(RecordingFailure)
}

public protocol AudioCapturePort: Sendable {
    func begin(_ request: MicrophoneRecordingRequest) async -> CaptureStartOutcome

    func apply(
        _ command: ActiveCaptureCommand,
        to recordingID: RecordingID
    ) async -> CaptureCommandOutcome

    func completeSeal(
        _ command: RecordingPublicationCommand
    ) async -> RecordingPublicationOutcome

    func inspectRecovery(in library: LibraryScope) async -> RecordingRecoveryCatalog

    func resolveRecovery(
        _ action: RecordingRecoveryAction,
        recordingID: RecordingID,
        in library: LibraryScope
    ) async -> RecordingRecoveryOutcome
}

public protocol RecordingClock: Sendable {
    func now() async -> UTCInstant
}

public protocol RecordingIDGenerator: Sendable {
    func generateRecordingID(at instant: UTCInstant) async -> RecordingID
    func generateSessionID(at instant: UTCInstant) async -> SessionID
}
