import AudoraDomain

public struct AudioSelectionToken: Hashable, Sendable {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard OpaqueAudioTokenValidator.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

public struct AudioStagingID: Hashable, Sendable {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard OpaqueAudioTokenValidator.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

public struct AudioImportScopeIdentity: Equatable, Sendable {
    public let libraryID: LibraryID
    public let workspaceGeneration: UInt64

    public init(libraryID: LibraryID, workspaceGeneration: UInt64) {
        self.libraryID = libraryID
        self.workspaceGeneration = workspaceGeneration
    }
}

public enum AudioSelectionOutcome: Equatable, Sendable {
    case selected(AudioSelectionToken, scope: AudioImportScopeIdentity)
    case cancelled
    case failed(AudioImportFailure)
}

public enum AudioImportSessionIDReservationOutcome: Equatable, Sendable {
    case reserved
    case collision
}

public struct AudioImportPolicy: Equatable, Sendable {
    public static let versionOne = AudioImportPolicy(
        maximumCanonicalFrames: CanonicalAudioFormat.maximumFrameCount,
        maximumSourceBytes: 2_147_483_648
    )

    public let maximumCanonicalFrames: UInt64
    public let maximumSourceBytes: UInt64

    public init(maximumCanonicalFrames: UInt64, maximumSourceBytes: UInt64) {
        self.maximumCanonicalFrames = maximumCanonicalFrames
        self.maximumSourceBytes = maximumSourceBytes
    }
}

public struct ImportedSessionSeed: Equatable, Sendable {
    public let scope: AudioImportScopeIdentity
    public let sessionID: SessionID
    public let createdAt: UTCInstant

    public init(
        scope: AudioImportScopeIdentity,
        sessionID: SessionID,
        createdAt: UTCInstant
    ) {
        self.scope = scope
        self.sessionID = sessionID
        self.createdAt = createdAt
    }
}

public struct StagedAudioCandidate: Equatable, Sendable {
    public let stagingID: AudioStagingID
    public let scope: AudioImportScopeIdentity
    public let sessionID: String
    public let createdAt: String
    public let audioManifestSHA256: String
    public let originalRelativePath: String
    public let originalContainer: String
    public let originalByteCount: UInt64
    public let originalSHA256: String
    public let decodedCodec: String
    public let sourceSampleRateHz: UInt32
    public let sourceChannelCount: UInt32
    public let canonicalRelativePath: String
    public let canonicalByteCount: UInt64
    public let canonicalSHA256: String
    public let canonicalFrameCount: UInt64
    public let canonicalDurationMilliseconds: UInt64
    public let canonicalContainer: String
    public let canonicalEncoding: String
    public let canonicalSampleRateHz: UInt32
    public let canonicalChannelCount: UInt32
    public let canonicalBitsPerSample: UInt32
    public let audioSourceID: String
    public let audioSourceRole: String
    public let timelineOffsetMilliseconds: UInt64
    public let normalizationAlgorithmID: String
    public let normalizationAlgorithmVersion: UInt32
    public let stereoRule: String
    public let resamplerVersion: String
    public let quantizerVersion: String

    public init(
        stagingID: AudioStagingID,
        scope: AudioImportScopeIdentity,
        sessionID: String,
        createdAt: String,
        audioManifestSHA256: String,
        originalRelativePath: String,
        originalContainer: String,
        originalByteCount: UInt64,
        originalSHA256: String,
        decodedCodec: String,
        sourceSampleRateHz: UInt32,
        sourceChannelCount: UInt32,
        canonicalRelativePath: String,
        canonicalByteCount: UInt64,
        canonicalSHA256: String,
        canonicalFrameCount: UInt64,
        canonicalDurationMilliseconds: UInt64,
        canonicalContainer: String,
        canonicalEncoding: String,
        canonicalSampleRateHz: UInt32,
        canonicalChannelCount: UInt32,
        canonicalBitsPerSample: UInt32,
        audioSourceID: String,
        audioSourceRole: String,
        timelineOffsetMilliseconds: UInt64,
        normalizationAlgorithmID: String,
        normalizationAlgorithmVersion: UInt32,
        stereoRule: String,
        resamplerVersion: String,
        quantizerVersion: String
    ) {
        self.stagingID = stagingID
        self.scope = scope
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.audioManifestSHA256 = audioManifestSHA256
        self.originalRelativePath = originalRelativePath
        self.originalContainer = originalContainer
        self.originalByteCount = originalByteCount
        self.originalSHA256 = originalSHA256
        self.decodedCodec = decodedCodec
        self.sourceSampleRateHz = sourceSampleRateHz
        self.sourceChannelCount = sourceChannelCount
        self.canonicalRelativePath = canonicalRelativePath
        self.canonicalByteCount = canonicalByteCount
        self.canonicalSHA256 = canonicalSHA256
        self.canonicalFrameCount = canonicalFrameCount
        self.canonicalDurationMilliseconds = canonicalDurationMilliseconds
        self.canonicalContainer = canonicalContainer
        self.canonicalEncoding = canonicalEncoding
        self.canonicalSampleRateHz = canonicalSampleRateHz
        self.canonicalChannelCount = canonicalChannelCount
        self.canonicalBitsPerSample = canonicalBitsPerSample
        self.audioSourceID = audioSourceID
        self.audioSourceRole = audioSourceRole
        self.timelineOffsetMilliseconds = timelineOffsetMilliseconds
        self.normalizationAlgorithmID = normalizationAlgorithmID
        self.normalizationAlgorithmVersion = normalizationAlgorithmVersion
        self.stereoRule = stereoRule
        self.resamplerVersion = resamplerVersion
        self.quantizerVersion = quantizerVersion
    }
}

public struct ValidatedImportedSession: Equatable, Sendable {
    public let stagedCandidate: StagedAudioCandidate
    public let session: ImportedSession

    public init(stagedCandidate: StagedAudioCandidate, session: ImportedSession) {
        self.stagedCandidate = stagedCandidate
        self.session = session
    }
}

public struct ReopenedImportedSessionSnapshot: Equatable, Sendable {
    public let session: ImportedSession

    public init(session: ImportedSession) {
        self.session = session
    }
}

public enum AudioImportPreparationPhase: String, Equatable, Sendable {
    case copying
    case inspecting
    case normalizing
}

public enum AudioImportFailure: String, Error, Equatable, Sendable {
    case unavailable
    case unsupportedMedia
    case sourceChanged
    case sourceTooLarge
    case malformedMedia
    case durationExceeded
    case decodeFailed
    case nonfiniteSamples
    case insufficientSpace
    case writeFailed
    case candidateCorrupt
    case libraryChanged
    case destinationCollision
    case cancelled
    case installedNeedsRefresh
}

public protocol AudioImportPort: Sendable {
    func choose() async -> AudioSelectionOutcome
    func revokeSelection(_ token: AudioSelectionToken) async
    func reserveSessionID(
        _ sessionID: SessionID,
        for token: AudioSelectionToken,
        in scope: AudioImportScopeIdentity
    ) async throws -> AudioImportSessionIDReservationOutcome
    func prepare(
        _ token: AudioSelectionToken,
        seed: ImportedSessionSeed,
        policy: AudioImportPolicy,
        progress: @escaping @Sendable (AudioImportPreparationPhase) async -> Void
    ) async throws -> StagedAudioCandidate
    func install(
        _ candidate: ValidatedImportedSession
    ) async throws -> ReopenedImportedSessionSnapshot
    func discard(_ stagingID: AudioStagingID) async
}

public protocol SessionIDGenerator: Sendable {
    func generateSessionID(at instant: UTCInstant) async -> SessionID
}

private enum OpaqueAudioTokenValidator {
    static func isValid(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}
