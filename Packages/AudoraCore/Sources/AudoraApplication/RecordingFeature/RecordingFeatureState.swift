import AudoraDomain

public enum RecordingFailure: String, Error, Equatable, Sendable {
    case noWritableLibrary
    case anotherLibraryActivity
    case microphonePermissionDenied
    case microphoneUnavailable
    case unsupportedInputFormat
    case captureInterruptedRecoverable
    case captureClockInvalidRecoverable
    case stagingWriteFailedRecoverable
    case sealValidationFailedRecoverable
    case sessionDestinationCollision
    case stagingDiscardFailed
    case libraryBecameReadOnly
    case staleCommand
}

public enum RecordingLibrarySelection: Equatable, Sendable {
    case none
    case readOnly
    case writable(LibraryScope)
}

public enum RecordingConfirmation: Equatable, Sendable {
    case none
    case discardRecording
}

public enum RecordingMuteState: Equatable, Sendable {
    case live
    case changing(toMuted: Bool)
    case muted
}

public struct RecordingSnapshot: Equatable, Sendable {
    public let recordingID: RecordingID
    public let sessionID: SessionID
    public let elapsedFrames: UInt64
    public let level: CaptureLevel
    public let mute: RecordingMuteState
    public let limitPhase: RecordingLimitPhase
    public let noticeID: UInt64

    public init(
        recordingID: RecordingID,
        sessionID: SessionID,
        elapsedFrames: UInt64,
        level: CaptureLevel,
        mute: RecordingMuteState,
        noticeID: UInt64
    ) {
        self.recordingID = recordingID
        self.sessionID = sessionID
        self.elapsedFrames = min(elapsedFrames, CanonicalRecordingLimits.maximumFrames)
        self.level = level
        self.mute = mute
        self.limitPhase = CanonicalRecordingLimits.phase(at: self.elapsedFrames)
        self.noticeID = noticeID
    }

    public func updating(
        elapsedFrames: UInt64? = nil,
        level: CaptureLevel? = nil,
        mute: RecordingMuteState? = nil,
        noticeID: UInt64? = nil
    ) -> RecordingSnapshot {
        RecordingSnapshot(
            recordingID: recordingID,
            sessionID: sessionID,
            elapsedFrames: elapsedFrames ?? self.elapsedFrames,
            level: level ?? self.level,
            mute: mute ?? self.mute,
            noticeID: noticeID ?? self.noticeID
        )
    }
}

public struct RecordingSeed: Equatable, Sendable {
    public let request: MicrophoneRecordingRequest

    public init(request: MicrophoneRecordingRequest) {
        self.request = request
    }
}

public struct SealedSessionSnapshot: Equatable, Sendable {
    public let receipt: SessionSealedReceipt

    public init(receipt: SessionSealedReceipt) {
        self.receipt = receipt
    }
}

public enum RecordingCompletionNotice: String, Equatable, Sendable {
    case durationLimit
}

public enum RecordingFeatureState: Equatable, Sendable {
    case unavailable(RecordingFailure)
    case selectingLibrary(LibraryScope)
    case idle
    case starting(RecordingSeed)
    case active(RecordingSnapshot, confirmation: RecordingConfirmation)
    case finishing(RecordingSnapshot, reason: CaptureTerminalReason)
    case sealing(RecordingSnapshot, reason: CaptureTerminalReason)
    case recoveryRequired(RecordingRecoveryCatalog)
    case resolvingRecovery(
        RecordingRecoveryCatalog,
        recordingID: RecordingID,
        action: RecordingRecoveryAction
    )
    case completed(SealedSessionSnapshot, notice: RecordingCompletionNotice?)
    case failed(RecordingFailure)
}

public enum RecordingCommand: Equatable, Sendable {
    case selectLibrary(RecordingLibrarySelection)
    case record
    case setMuted(Bool)
    case stop
    case cancel
    case keepRecording
    case discardRecording
    case sealRecovered(RecordingID)
    case discardRecovered(RecordingID)
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol RecordingFeature: Sendable {
    var currentState: RecordingFeatureState { get async }
    var states: AsyncStream<RecordingFeatureState> { get }
    /// Bounded FIFO notifications that Sessions became durable. A slow
    /// subscriber backpressures publication instead of losing a receipt.
    /// Notifications are not replayed; persisted Library state is authoritative.
    var sealedSessions: SessionSealedNotifications { get }

    func send(_ command: RecordingCommand) async
}
