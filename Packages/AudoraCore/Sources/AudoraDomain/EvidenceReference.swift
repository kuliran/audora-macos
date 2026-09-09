public enum EvidenceReferenceError: Error, Equatable, Sendable {
    case invalidAnchor
    case invalidDisplay
    case invalidTimeRange
}

/// A locally resolved, portable pointer into one exact immutable Transcript
/// revision. Provider attachment handles, quotes, labels, and timestamps never
/// cross this boundary.
public enum EvidenceReferenceTarget: Equatable, Sendable {
    case wordRange(startWordID: TranscriptWordID, endWordID: TranscriptWordID)
    case audioEvent(audioEventID: AudioEventID)
}

public struct EvidenceReferenceDisplay: Equatable, Sendable {
    public static let maximumSessionLabelUTF8Bytes = 1_024
    public static let maximumTrustedTextUTF8Bytes = 16_384
    public static let maximumSessionDurationMilliseconds: UInt64 = 2_700_000

    public let sessionLabel: String
    public let trustedText: String
    public let startMilliseconds: UInt64
    public let endMilliseconds: UInt64

    public init(
        sessionLabel: String,
        trustedText: String,
        startMilliseconds: UInt64,
        endMilliseconds: UInt64
    ) throws {
        guard Self.isValidText(
            sessionLabel,
            maximumUTF8Bytes: Self.maximumSessionLabelUTF8Bytes
        ), Self.isValidText(
            trustedText,
            maximumUTF8Bytes: Self.maximumTrustedTextUTF8Bytes
        ) else {
            throw EvidenceReferenceError.invalidDisplay
        }
        guard startMilliseconds < endMilliseconds,
              endMilliseconds <= Self.maximumSessionDurationMilliseconds
        else {
            throw EvidenceReferenceError.invalidTimeRange
        }
        self.sessionLabel = sessionLabel
        self.trustedText = trustedText
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
    }

    private static func isValidText(
        _ value: String,
        maximumUTF8Bytes: Int
    ) -> Bool {
        value.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) &&
            value.utf8.count <= maximumUTF8Bytes &&
            !value.unicodeScalars.contains(where: {
                $0.value == 0 ||
                    ($0.properties.generalCategory == .control &&
                        ![0x09, 0x0A, 0x0D].contains($0.value))
            })
    }
}

public struct EvidenceReference: Equatable, Sendable {
    public let sessionID: SessionID
    public let transcriptRevisionID: TranscriptRevisionID
    public let target: EvidenceReferenceTarget
    public let display: EvidenceReferenceDisplay

    public init(
        sessionID: SessionID,
        transcriptRevisionID: TranscriptRevisionID,
        target: EvidenceReferenceTarget,
        display: EvidenceReferenceDisplay
    ) throws {
        if case let .wordRange(startWordID, endWordID) = target,
           startWordID.rawValue > endWordID.rawValue
        {
            throw EvidenceReferenceError.invalidAnchor
        }
        self.sessionID = sessionID
        self.transcriptRevisionID = transcriptRevisionID
        self.target = target
        self.display = display
    }
}
