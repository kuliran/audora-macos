import AudoraDomain

public struct CandidateSessionTimeRange: Equatable, Sendable {
    public let startMilliseconds: UInt64
    public let endMilliseconds: UInt64

    public init(startMilliseconds: UInt64, endMilliseconds: UInt64) {
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
    }
}

public struct CandidateLineTextRange: Equatable, Sendable {
    public let startUTF8Byte: Int
    public let endUTF8Byte: Int

    public init(startUTF8Byte: Int, endUTF8Byte: Int) {
        self.startUTF8Byte = startUTF8Byte
        self.endUTF8Byte = endUTF8Byte
    }
}

public enum CandidateTranscriptWordKind: String, Equatable, Sendable {
    case lexical
    case filledPause
    case partialWord
}

public struct CandidateTranscriptWord: Equatable, Sendable {
    public let wordID: String
    public let ordinal: Int
    public let text: String
    public let displayRange: CandidateLineTextRange
    public let timeRange: CandidateSessionTimeRange?
    public let confidence: Double?
    public let wordKind: CandidateTranscriptWordKind

    public init(
        wordID: String,
        ordinal: Int,
        text: String,
        displayRange: CandidateLineTextRange,
        timeRange: CandidateSessionTimeRange?,
        confidence: Double?,
        wordKind: CandidateTranscriptWordKind
    ) {
        self.wordID = wordID
        self.ordinal = ordinal
        self.text = text
        self.displayRange = displayRange
        self.timeRange = timeRange
        self.confidence = confidence
        self.wordKind = wordKind
    }
}

public struct CandidateTranscriptLine: Equatable, Sendable {
    public let lineID: String
    public let order: Int
    public let audioSourceID: String
    public let timeRange: CandidateSessionTimeRange
    public let text: String
    public let words: [CandidateTranscriptWord]

    public init(
        lineID: String,
        order: Int,
        audioSourceID: String,
        timeRange: CandidateSessionTimeRange,
        text: String,
        words: [CandidateTranscriptWord]
    ) {
        self.lineID = lineID
        self.order = order
        self.audioSourceID = audioSourceID
        self.timeRange = timeRange
        self.text = text
        self.words = words
    }
}

public struct CandidateTranscriptAudioEvent: Equatable, Sendable {
    public let audioEventID: String
    public let category: TranscriptAudioEventCategory
    public let audioSourceID: String
    public let timeRange: CandidateSessionTimeRange

    public init(
        audioEventID: String,
        category: TranscriptAudioEventCategory,
        audioSourceID: String,
        timeRange: CandidateSessionTimeRange
    ) {
        self.audioEventID = audioEventID
        self.category = category
        self.audioSourceID = audioSourceID
        self.timeRange = timeRange
    }
}

public struct CandidateTranscriptSourceFingerprint: Equatable, Sendable {
    public let audioSourceID: String
    public let sha256: String

    public init(audioSourceID: String, sha256: String) {
        self.audioSourceID = audioSourceID
        self.sha256 = sha256
    }
}

public struct CandidateTranscriptEngineProvenance: Equatable, Sendable {
    public let provider: String
    public let model: String
    public let revision: String
    public let language: String
    public let mode: String
    public let decodingOptionsSHA256: String
    public let qualification: CandidateTranscriptEngineQualification

    public init(
        provider: String,
        model: String,
        revision: String,
        language: String,
        mode: String,
        decodingOptionsSHA256: String,
        qualification: CandidateTranscriptEngineQualification
    ) {
        self.provider = provider
        self.model = model
        self.revision = revision
        self.language = language
        self.mode = mode
        self.decodingOptionsSHA256 = decodingOptionsSHA256
        self.qualification = qualification
    }
}

/// Semantically untrusted echo of the worker startup identity. Application
/// compares every field against the trusted qualified profile before promotion.
public struct CandidateTranscriptEngineQualification: Equatable, Sendable {
    public let schemaVersion: UInt32
    public let qualificationProfileID: String
    public let engineLockSHA256: String
    public let runtimeIdentity: String
    public let runtimeLockSHA256: String
    public let compatibilityPatchID: String

    public init(
        schemaVersion: UInt32,
        qualificationProfileID: String,
        engineLockSHA256: String,
        runtimeIdentity: String,
        runtimeLockSHA256: String,
        compatibilityPatchID: String
    ) {
        self.schemaVersion = schemaVersion
        self.qualificationProfileID = qualificationProfileID
        self.engineLockSHA256 = engineLockSHA256
        self.runtimeIdentity = runtimeIdentity
        self.runtimeLockSHA256 = runtimeLockSHA256
        self.compatibilityPatchID = compatibilityPatchID
    }
}

public struct TranscriptionCandidate: Equatable, Sendable {
    public let schemaVersion: UInt32
    public let jobID: String
    public let sessionID: String
    public let revisionID: String
    public let durationMilliseconds: UInt64
    public let audioFingerprintSHA256: String
    public let sourceFingerprints: [CandidateTranscriptSourceFingerprint]
    public let candidateArtifactSHA256: String
    public let engine: CandidateTranscriptEngineProvenance
    public let lines: [CandidateTranscriptLine]
    public let audioEvents: [CandidateTranscriptAudioEvent]

    public init(
        schemaVersion: UInt32,
        jobID: String,
        sessionID: String,
        revisionID: String,
        durationMilliseconds: UInt64,
        audioFingerprintSHA256: String,
        sourceFingerprints: [CandidateTranscriptSourceFingerprint],
        candidateArtifactSHA256: String,
        engine: CandidateTranscriptEngineProvenance,
        lines: [CandidateTranscriptLine],
        audioEvents: [CandidateTranscriptAudioEvent]
    ) {
        self.schemaVersion = schemaVersion
        self.jobID = jobID
        self.sessionID = sessionID
        self.revisionID = revisionID
        self.durationMilliseconds = durationMilliseconds
        self.audioFingerprintSHA256 = audioFingerprintSHA256
        self.sourceFingerprints = sourceFingerprints
        self.candidateArtifactSHA256 = candidateArtifactSHA256
        self.engine = engine
        self.lines = lines
        self.audioEvents = audioEvents
    }
}

public struct TranscriptPublicationContext: Equatable, Sendable {
    public let jobID: TranscriptionJobID
    public let sessionID: SessionID
    public let revisionID: TranscriptRevisionID
    public let createdAt: UTCInstant
    public let durationMilliseconds: UInt64
    public let audioFingerprint: AudioFingerprint
    public let sourceFingerprints: [TranscriptSourceFingerprint]
    public let verifiedCandidateArtifactFingerprint: AudioFingerprint
    public let engine: TranscriptEngineProvenance
    public let voicedRanges: [SessionTimeRange]

    public init(
        jobID: TranscriptionJobID,
        sessionID: SessionID,
        revisionID: TranscriptRevisionID,
        createdAt: UTCInstant,
        durationMilliseconds: UInt64,
        audioFingerprint: AudioFingerprint,
        sourceFingerprints: [TranscriptSourceFingerprint],
        verifiedCandidateArtifactFingerprint: AudioFingerprint,
        engine: TranscriptEngineProvenance,
        voicedRanges: [SessionTimeRange]
    ) {
        self.jobID = jobID
        self.sessionID = sessionID
        self.revisionID = revisionID
        self.createdAt = createdAt
        self.durationMilliseconds = durationMilliseconds
        self.audioFingerprint = audioFingerprint
        self.sourceFingerprints = sourceFingerprints
        self.verifiedCandidateArtifactFingerprint = verifiedCandidateArtifactFingerprint
        self.engine = engine
        self.voicedRanges = voicedRanges
    }
}
