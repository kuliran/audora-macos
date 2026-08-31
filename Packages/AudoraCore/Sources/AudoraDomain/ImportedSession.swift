public enum ImportedSessionValidationError: Error, Equatable, Sendable {
    case invalidAudioSourceID
    case invalidHash
    case invalidByteCount
    case invalidFrameCount
    case invalidDuration
    case invalidOriginalPath
    case invalidCanonicalPath
    case invalidSourceFormat
    case invalidSource
    case invalidNormalization
    case audioManifestMismatch
}

public struct AudioSourceID: Hashable, Sendable, CustomStringConvertible {
    public static let microphone = try! AudioSourceID("src-0001")

    public let rawValue: String

    public init(_ rawValue: String) throws {
        let suffix = rawValue.dropFirst(4)
        guard rawValue.hasPrefix("src-"),
              suffix.count == 4,
              suffix.allSatisfy({ $0.asciiValue.map { (48...57).contains($0) } == true })
        else {
            throw ImportedSessionValidationError.invalidAudioSourceID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum ImportedAudioContainer: String, Equatable, Sendable {
    case m4a
    case wav
}

public enum DecodedAudioCodec: String, Equatable, Sendable {
    case aacLC
    case alac
    case linearPCM
}

public struct AudioArtifactFingerprint: Equatable, Sendable {
    public let byteCount: UInt64
    public let sha256: String

    public init(byteCount: UInt64, sha256: String) throws {
        guard byteCount > 0 else {
            throw ImportedSessionValidationError.invalidByteCount
        }
        guard Self.isSHA256(sha256) else {
            throw ImportedSessionValidationError.invalidHash
        }
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    public static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

public struct OriginalAudioArtifact: Equatable, Sendable {
    public let relativePath: LibraryRelativePath
    public let container: ImportedAudioContainer
    public let fingerprint: AudioArtifactFingerprint
    public let decodedCodec: DecodedAudioCodec
    public let sourceSampleRateHz: UInt32
    public let sourceChannelCount: UInt32

    public init(
        relativePath: LibraryRelativePath,
        container: ImportedAudioContainer,
        fingerprint: AudioArtifactFingerprint,
        decodedCodec: DecodedAudioCodec,
        sourceSampleRateHz: UInt32,
        sourceChannelCount: UInt32
    ) throws {
        guard relativePath.description == "audio/original.\(container.rawValue)" else {
            throw ImportedSessionValidationError.invalidOriginalPath
        }
        guard (8_000...192_000).contains(sourceSampleRateHz),
              sourceChannelCount == 1 || sourceChannelCount == 2
        else {
            throw ImportedSessionValidationError.invalidSourceFormat
        }
        switch (container, decodedCodec) {
        case (.wav, .linearPCM), (.m4a, .aacLC), (.m4a, .alac):
            break
        default:
            throw ImportedSessionValidationError.invalidSourceFormat
        }
        self.relativePath = relativePath
        self.container = container
        self.fingerprint = fingerprint
        self.decodedCodec = decodedCodec
        self.sourceSampleRateHz = sourceSampleRateHz
        self.sourceChannelCount = sourceChannelCount
    }
}

public struct CanonicalAudioArtifact: Equatable, Sendable {
    public let relativePath: LibraryRelativePath
    public let fingerprint: AudioArtifactFingerprint
    public let frameCount: UInt64
    public let durationMilliseconds: UInt64
    public let format: CanonicalAudioFormat

    public init(
        relativePath: LibraryRelativePath,
        fingerprint: AudioArtifactFingerprint,
        frameCount: UInt64,
        durationMilliseconds: UInt64,
        format: CanonicalAudioFormat = .v1
    ) throws {
        guard relativePath.description == "audio/audio.wav" else {
            throw ImportedSessionValidationError.invalidCanonicalPath
        }
        let expectedDuration = try CanonicalAudioFormat.durationMilliseconds(
            forFrameCount: frameCount
        )
        guard durationMilliseconds == expectedDuration,
              fingerprint.byteCount == 44 + frameCount * 2
        else {
            throw ImportedSessionValidationError.invalidDuration
        }
        self.relativePath = relativePath
        self.fingerprint = fingerprint
        self.frameCount = frameCount
        self.durationMilliseconds = durationMilliseconds
        self.format = format
    }
}

public enum AudioSourceRole: String, Equatable, Sendable {
    case microphone
}

public struct SessionAudioSource: Equatable, Sendable {
    public let audioSourceID: AudioSourceID
    public let role: AudioSourceRole
    public let timelineOffsetMilliseconds: UInt64

    public init(
        audioSourceID: AudioSourceID,
        role: AudioSourceRole,
        timelineOffsetMilliseconds: UInt64
    ) throws {
        guard audioSourceID == .microphone,
              role == .microphone,
              timelineOffsetMilliseconds == 0
        else {
            throw ImportedSessionValidationError.invalidSource
        }
        self.audioSourceID = audioSourceID
        self.role = role
        self.timelineOffsetMilliseconds = timelineOffsetMilliseconds
    }
}

public struct AudioNormalizationProvenance: Equatable, Sendable {
    public static let v1 = AudioNormalizationProvenance(
        algorithmID: "audora-avfoundation",
        algorithmVersion: 1,
        stereoRule: "arithmeticMean",
        resamplerVersion: "av-audio-converter-normal-max-normal-prime-v1",
        quantizerVersion: "s16-round-away-saturate-v1"
    )!

    public let algorithmID: String
    public let algorithmVersion: UInt32
    public let stereoRule: String
    public let resamplerVersion: String
    public let quantizerVersion: String

    public init?(
        algorithmID: String,
        algorithmVersion: UInt32,
        stereoRule: String,
        resamplerVersion: String,
        quantizerVersion: String
    ) {
        guard algorithmID == "audora-avfoundation",
              algorithmVersion == 1,
              stereoRule == "arithmeticMean",
              resamplerVersion == "av-audio-converter-normal-max-normal-prime-v1",
              quantizerVersion == "s16-round-away-saturate-v1"
        else {
            return nil
        }
        self.algorithmID = algorithmID
        self.algorithmVersion = algorithmVersion
        self.stereoRule = stereoRule
        self.resamplerVersion = resamplerVersion
        self.quantizerVersion = quantizerVersion
    }
}

public struct ImportedAudioAsset: Equatable, Sendable {
    public let original: OriginalAudioArtifact
    public let canonical: CanonicalAudioArtifact
    public let sources: [SessionAudioSource]
    public let normalization: AudioNormalizationProvenance

    public init(
        original: OriginalAudioArtifact,
        canonical: CanonicalAudioArtifact,
        sources: [SessionAudioSource],
        normalization: AudioNormalizationProvenance
    ) throws {
        guard sources.count == 1, sources.first?.audioSourceID == .microphone else {
            throw ImportedSessionValidationError.invalidSource
        }
        self.original = original
        self.canonical = canonical
        self.sources = sources
        self.normalization = normalization
    }
}

public struct ImportedSession: Equatable, Sendable {
    public let sessionID: SessionID
    public let createdAt: UTCInstant
    public let durationMilliseconds: UInt64
    public let audioManifestSHA256: String
    public let audio: ImportedAudioAsset
    public let transcriptRevisionIDs: [TranscriptRevisionID]
    public let selectedTranscriptRevision: SelectedTranscriptRevision?

    public init(
        sessionID: SessionID,
        createdAt: UTCInstant,
        durationMilliseconds: UInt64,
        audioManifestSHA256: String,
        audio: ImportedAudioAsset,
        transcriptRevisionIDs: [TranscriptRevisionID] = [],
        selectedTranscriptRevision: SelectedTranscriptRevision? = nil
    ) throws {
        guard durationMilliseconds == audio.canonical.durationMilliseconds else {
            throw ImportedSessionValidationError.invalidDuration
        }
        guard AudioArtifactFingerprint.isSHA256(audioManifestSHA256) else {
            throw ImportedSessionValidationError.audioManifestMismatch
        }
        try SessionTranscriptSelectionValidator.validate(
            revisionIDs: transcriptRevisionIDs,
            selected: selectedTranscriptRevision
        )
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.durationMilliseconds = durationMilliseconds
        self.audioManifestSHA256 = audioManifestSHA256
        self.audio = audio
        self.transcriptRevisionIDs = transcriptRevisionIDs
        self.selectedTranscriptRevision = selectedTranscriptRevision
    }
}

public struct CanonicalTimeRange: Equatable, Sendable {
    public let startMilliseconds: UInt64
    public let endMilliseconds: UInt64

    public init(
        startMilliseconds: UInt64,
        endMilliseconds: UInt64,
        sessionDurationMilliseconds: UInt64
    ) throws {
        guard startMilliseconds < endMilliseconds,
              endMilliseconds <= sessionDurationMilliseconds
        else {
            throw ImportedSessionValidationError.invalidDuration
        }
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
    }
}
