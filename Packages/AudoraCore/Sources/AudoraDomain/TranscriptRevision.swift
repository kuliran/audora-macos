public typealias SessionTimeRange = CanonicalTimeRange

public enum TranscriptAnchorIDError: Error, Equatable, Sendable {
    case invalidLineID
    case invalidWordID
    case invalidAudioEventID
}

public struct TranscriptLineID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard TranscriptAnchorIDValidator.isValid(rawValue, prefix: "l") else {
            throw TranscriptAnchorIDError.invalidLineID
        }
        self.rawValue = rawValue
    }
}

public struct TranscriptWordID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard TranscriptAnchorIDValidator.isValid(rawValue, prefix: "w") else {
            throw TranscriptAnchorIDError.invalidWordID
        }
        self.rawValue = rawValue
    }
}

public struct AudioEventID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard TranscriptAnchorIDValidator.isValid(rawValue, prefix: "a") else {
            throw TranscriptAnchorIDError.invalidAudioEventID
        }
        self.rawValue = rawValue
    }
}

public struct LineTextRange: Equatable, Sendable {
    public let startUTF8Byte: Int
    public let endUTF8Byte: Int

    public init(startUTF8Byte: Int, endUTF8Byte: Int) {
        self.startUTF8Byte = startUTF8Byte
        self.endUTF8Byte = endUTF8Byte
    }
}

public enum TranscriptWordKind: String, Equatable, Sendable {
    case lexical
    case filledPause
    case partialWord
}

public enum TranscriptRevisionLimits {
    public static let maximumLineUTF8Bytes = 131_072
    public static let maximumWordUTF8Bytes = 1_024
    public static let maximumAggregateTextUTF8Bytes = 16 * 1_024 * 1_024
    public static let maximumSerializedBytes = 256 * 1_024 * 1_024
    public static let maximumSessionRevisionCount = 256
    public static let maximumVoicedRangeCount = 100_000
}

/// Canonical Word text is lexical evidence, not a display-text fragment.
/// Apostrophes and hyphens may join lexical characters; only `partialWord`
/// permits one terminal ASCII cutoff hyphen.
public enum TranscriptWordTextValidator {
    public static func isValid(_ text: String, kind: TranscriptWordKind) -> Bool {
        guard !text.isEmpty,
              text.utf8.count <= TranscriptRevisionLimits.maximumWordUTF8Bytes
        else {
            return false
        }
        let characters = Array(text)
        let lexical = characters.map(isLexicalCharacter)
        guard lexical.contains(true) else { return false }
        for index in characters.indices where !lexical[index] {
            let character = characters[index]
            if character == "-", kind == .partialWord,
               index == characters.index(before: characters.endIndex),
               index > characters.startIndex,
               lexical[characters.index(before: index)]
            {
                continue
            }
            guard character == "'" || character == "’" || character == "-",
                  index > characters.startIndex,
                  index < characters.index(before: characters.endIndex),
                  lexical[characters.index(before: index)],
                  lexical[characters.index(after: index)]
            else {
                return false
            }
        }
        return true
    }

    private static func isLexicalCharacter(_ character: Character) -> Bool {
        var hasBase = false
        for scalar in character.unicodeScalars {
            if scalar.properties.isAlphabetic || (48...57).contains(scalar.value) {
                hasBase = true
                continue
            }
            switch scalar.properties.generalCategory {
            case .nonspacingMark where hasBase,
                 .spacingMark where hasBase,
                 .enclosingMark where hasBase:
                continue
            default:
                return false
            }
        }
        return hasBase
    }
}

public enum TranscriptRepetitionValidator {
    public static func isPathological(
        words: [String],
        maximumConsecutiveOccurrences: Int
    ) -> Bool {
        guard maximumConsecutiveOccurrences > 0 else { return true }
        let normalized = words.map(normalize)
        guard !normalized.contains(where: \.isEmpty) else { return false }
        guard maximumConsecutiveOccurrences < normalized.count else { return false }
        let requiredOccurrences = maximumConsecutiveOccurrences + 1
        let maximumPhraseWidth = min(32, normalized.count / requiredOccurrences)
        guard maximumPhraseWidth > 0 else { return false }
        for width in 1...maximumPhraseWidth {
            var consecutivePeriodMatches = 0
            let rejectionThreshold = width * maximumConsecutiveOccurrences
            for index in width..<normalized.count {
                if normalized[index] == normalized[index - width] {
                    consecutivePeriodMatches += 1
                    if consecutivePeriodMatches >= rejectionThreshold { return true }
                } else {
                    consecutivePeriodMatches = 0
                }
            }
        }
        return false
    }

    private static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { scalar in
            scalar.properties.isAlphabetic || (48...57).contains(scalar.value) ||
                scalar.value == 39 || scalar.value == 45
        })
    }
}

public struct TranscriptWord: Equatable, Sendable {
    public let wordID: TranscriptWordID
    public let ordinal: Int
    public let text: String
    public let displayRange: LineTextRange
    public let timeRange: SessionTimeRange?
    public let confidence: Double?
    public let wordKind: TranscriptWordKind

    public init(
        wordID: TranscriptWordID,
        ordinal: Int,
        text: String,
        displayRange: LineTextRange,
        timeRange: SessionTimeRange?,
        confidence: Double?,
        wordKind: TranscriptWordKind
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

public struct TranscriptLine: Equatable, Sendable {
    public let lineID: TranscriptLineID
    public let order: Int
    public let audioSourceID: AudioSourceID
    public let timeRange: SessionTimeRange
    public let text: String
    public let words: [TranscriptWord]

    public init(
        lineID: TranscriptLineID,
        order: Int,
        audioSourceID: AudioSourceID,
        timeRange: SessionTimeRange,
        text: String,
        words: [TranscriptWord]
    ) {
        self.lineID = lineID
        self.order = order
        self.audioSourceID = audioSourceID
        self.timeRange = timeRange
        self.text = text
        self.words = words
    }
}

public enum TranscriptAudioEventCategory: String, Equatable, Sendable {
    case nonSpeech
    case silentPause
    case untranscribedVoicedInterval
    case muted
    case captureGap
}

public struct TranscriptAudioEvent: Equatable, Sendable {
    public let audioEventID: AudioEventID
    public let category: TranscriptAudioEventCategory
    public let audioSourceID: AudioSourceID
    public let timeRange: SessionTimeRange

    public init(
        audioEventID: AudioEventID,
        category: TranscriptAudioEventCategory,
        audioSourceID: AudioSourceID,
        timeRange: SessionTimeRange
    ) {
        self.audioEventID = audioEventID
        self.category = category
        self.audioSourceID = audioSourceID
        self.timeRange = timeRange
    }
}

public enum TranscriptEngineProvenanceError: Error, Equatable, Sendable {
    case invalidProvider
    case invalidModel
    case invalidRevision
    case unsupportedLanguage
    case unsupportedMode
    case invalidDecodingOptionsHash
    case invalidUsePolicy
}

public enum EngineCoveredArtifact: String, Hashable, Sendable {
    case transcriptRevision
}

public struct EngineUsePolicy: Equatable, Sendable {
    public let policyID: String
    public let coveredArtifacts: Set<EngineCoveredArtifact>
    public let privateLocalUseAllowed: Bool
    public let privateExportAllowed: Bool
    public let externalProcessingAllowed: Bool
    public let publicDistributionAllowed: Bool
    public let commercialUseAllowed: Bool
    public let licenseReference: String
    public let licenseSHA256: String

    public init(
        policyID: String,
        coveredArtifacts: Set<EngineCoveredArtifact>,
        privateLocalUseAllowed: Bool,
        privateExportAllowed: Bool,
        externalProcessingAllowed: Bool,
        publicDistributionAllowed: Bool,
        commercialUseAllowed: Bool,
        licenseReference: String,
        licenseSHA256: String
    ) throws {
        guard TranscriptEngineProvenance.isBoundedIdentifier(policyID),
              coveredArtifacts.contains(.transcriptRevision),
              !licenseReference.isEmpty,
              licenseReference.utf8.count <= 512,
              AudioArtifactFingerprint.isSHA256(licenseSHA256)
        else {
            throw TranscriptEngineProvenanceError.invalidUsePolicy
        }
        self.policyID = policyID
        self.coveredArtifacts = coveredArtifacts
        self.privateLocalUseAllowed = privateLocalUseAllowed
        self.privateExportAllowed = privateExportAllowed
        self.externalProcessingAllowed = externalProcessingAllowed
        self.publicDistributionAllowed = publicDistributionAllowed
        self.commercialUseAllowed = commercialUseAllowed
        self.licenseReference = licenseReference
        self.licenseSHA256 = licenseSHA256
    }
}

public struct TranscriptEngineProvenance: Equatable, Sendable {
    public let provider: String
    public let model: String
    public let revision: String
    public let language: String
    public let mode: String
    public let decodingOptionsSHA256: String
    public let usePolicy: EngineUsePolicy

    public init(
        provider: String,
        model: String,
        revision: String,
        language: String,
        mode: String,
        decodingOptionsSHA256: String,
        usePolicy: EngineUsePolicy
    ) throws {
        guard provider == "crisperwhisper" else {
            throw TranscriptEngineProvenanceError.invalidProvider
        }
        guard model == "small" else { throw TranscriptEngineProvenanceError.invalidModel }
        guard Self.isBoundedIdentifier(revision) else {
            throw TranscriptEngineProvenanceError.invalidRevision
        }
        guard language == "en" else {
            throw TranscriptEngineProvenanceError.unsupportedLanguage
        }
        guard mode == "verbatim" else {
            throw TranscriptEngineProvenanceError.unsupportedMode
        }
        guard AudioArtifactFingerprint.isSHA256(decodingOptionsSHA256) else {
            throw TranscriptEngineProvenanceError.invalidDecodingOptionsHash
        }
        self.provider = provider
        self.model = model
        self.revision = revision
        self.language = language
        self.mode = mode
        self.decodingOptionsSHA256 = decodingOptionsSHA256
        self.usePolicy = usePolicy
    }

    static func isBoundedIdentifier(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}

public struct TranscriptSourceFingerprint: Equatable, Sendable {
    public let audioSourceID: AudioSourceID
    public let fingerprint: AudioFingerprint

    public init(audioSourceID: AudioSourceID, fingerprint: AudioFingerprint) {
        self.audioSourceID = audioSourceID
        self.fingerprint = fingerprint
    }
}

public struct SelectedTranscriptRevision: Equatable, Sendable {
    public let revisionID: TranscriptRevisionID
    public let revisionSHA256: String

    public init(revisionID: TranscriptRevisionID, revisionSHA256: String) throws {
        guard AudioArtifactFingerprint.isSHA256(revisionSHA256) else {
            throw TranscriptRevisionIntegrityError.invalidSelection
        }
        self.revisionID = revisionID
        self.revisionSHA256 = revisionSHA256
    }
}

public enum SessionTranscriptSelectionValidator {
    public static func validate(
        revisionIDs: [TranscriptRevisionID],
        selected: SelectedTranscriptRevision?
    ) throws {
        guard revisionIDs.count <= TranscriptRevisionLimits.maximumSessionRevisionCount,
              Set(revisionIDs).count == revisionIDs.count,
              revisionIDs.isEmpty == (selected == nil),
              selected.map({ revisionIDs.contains($0.revisionID) }) ?? true
        else {
            throw TranscriptRevisionIntegrityError.invalidSelection
        }
    }
}

public struct TranscriptRevision: Equatable, Sendable {
    public let revisionID: TranscriptRevisionID
    public let sessionID: SessionID
    public let jobID: TranscriptionJobID
    public let createdAt: UTCInstant
    public let durationMilliseconds: UInt64
    public let audioFingerprint: AudioFingerprint
    public let sourceFingerprints: [TranscriptSourceFingerprint]
    public let candidateArtifactFingerprint: AudioFingerprint
    public let engine: TranscriptEngineProvenance
    public let lines: [TranscriptLine]
    public let audioEvents: [TranscriptAudioEvent]

    public init(
        revisionID: TranscriptRevisionID,
        sessionID: SessionID,
        jobID: TranscriptionJobID,
        createdAt: UTCInstant,
        durationMilliseconds: UInt64,
        audioFingerprint: AudioFingerprint,
        sourceFingerprints: [TranscriptSourceFingerprint],
        candidateArtifactFingerprint: AudioFingerprint,
        engine: TranscriptEngineProvenance,
        lines: [TranscriptLine],
        audioEvents: [TranscriptAudioEvent]
    ) throws {
        try TranscriptRevisionIntegrity.validate(
            durationMilliseconds: durationMilliseconds,
            sourceFingerprints: sourceFingerprints,
            lines: lines,
            audioEvents: audioEvents
        )
        self.revisionID = revisionID
        self.sessionID = sessionID
        self.jobID = jobID
        self.createdAt = createdAt
        self.durationMilliseconds = durationMilliseconds
        self.audioFingerprint = audioFingerprint
        self.sourceFingerprints = sourceFingerprints
        self.candidateArtifactFingerprint = candidateArtifactFingerprint
        self.engine = engine
        self.lines = lines
        self.audioEvents = audioEvents
    }
}

private enum TranscriptAnchorIDValidator {
    static func isValid(_ value: String, prefix: Character) -> Bool {
        guard value.utf8.count == 7,
              value.first == prefix
        else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy { (48...57).contains($0) }
    }
}

public enum TranscriptRevisionIntegrityError: Error, Equatable, Sendable {
    case invalidDuration
    case invalidSources
    case invalidLineOrdering
    case invalidWordOrdering
    case invalidTiming
    case invalidTextMapping
    case punctuationIsNotAWord
    case invalidConfidence
    case invalidAudioEvent
    case invalidSelection
    case pathologicalSize
    case pathologicalRepetition
}

private enum TranscriptRevisionIntegrity {
    static func validate(
        durationMilliseconds: UInt64,
        sourceFingerprints: [TranscriptSourceFingerprint],
        lines: [TranscriptLine],
        audioEvents: [TranscriptAudioEvent]
    ) throws {
        guard durationMilliseconds > 0, durationMilliseconds <= 2_700_000 else {
            throw TranscriptRevisionIntegrityError.invalidDuration
        }
        let sourceIDs = Set(sourceFingerprints.map(\.audioSourceID))
        guard !sourceIDs.isEmpty,
              sourceFingerprints.count <= 32,
              sourceIDs.count == sourceFingerprints.count
        else {
            throw TranscriptRevisionIntegrityError.invalidSources
        }
        guard !lines.isEmpty, lines.count <= 100_000,
              audioEvents.count <= 100_000
        else {
            throw TranscriptRevisionIntegrityError.invalidLineOrdering
        }

        var previousLineEnd: UInt64 = 0
        var previousTimedWordEnd: UInt64 = 0
        var nextWordOrdinal = 0
        var aggregateTextBytes = 0
        var canonicalWordTexts: [String] = []
        for (lineIndex, line) in lines.enumerated() {
            guard line.order == lineIndex,
                  line.lineID.rawValue == stableID(prefix: "l", ordinal: lineIndex),
                  sourceIDs.contains(line.audioSourceID),
                  line.timeRange.endMilliseconds <= durationMilliseconds,
                  lineIndex == 0 || line.timeRange.startMilliseconds >= previousLineEnd
            else {
                throw TranscriptRevisionIntegrityError.invalidLineOrdering
            }
            previousLineEnd = line.timeRange.endMilliseconds
            let lineTextBytes = line.text.utf8.count
            guard lineTextBytes > 0,
                  lineTextBytes <= TranscriptRevisionLimits.maximumLineUTF8Bytes,
                  aggregateTextBytes <=
                    TranscriptRevisionLimits.maximumAggregateTextUTF8Bytes - lineTextBytes
            else {
                throw TranscriptRevisionIntegrityError.pathologicalSize
            }
            aggregateTextBytes += lineTextBytes
            guard !line.words.isEmpty else {
                throw TranscriptRevisionIntegrityError.invalidTextMapping
            }
            guard nextWordOrdinal <= 1_000_000 - line.words.count else {
                throw TranscriptRevisionIntegrityError.invalidWordOrdering
            }
            let lineBytes = Array(line.text.utf8)
            var previousDisplayEnd = 0
            for word in line.words {
                guard word.ordinal == nextWordOrdinal,
                      word.wordID.rawValue == stableID(
                        prefix: "w",
                        ordinal: nextWordOrdinal
                      )
                else {
                    throw TranscriptRevisionIntegrityError.invalidWordOrdering
                }
                nextWordOrdinal += 1
                let wordTextBytes = word.text.utf8.count
                guard wordTextBytes <= TranscriptRevisionLimits.maximumWordUTF8Bytes,
                      wordTextBytes <=
                    TranscriptRevisionLimits.maximumAggregateTextUTF8Bytes -
                    aggregateTextBytes
                else {
                    throw TranscriptRevisionIntegrityError.pathologicalSize
                }
                aggregateTextBytes += wordTextBytes
                canonicalWordTexts.append(word.text)
                guard TranscriptWordTextValidator.isValid(
                    word.text,
                    kind: word.wordKind
                ) else {
                    throw TranscriptRevisionIntegrityError.punctuationIsNotAWord
                }
                guard word.displayRange.startUTF8Byte >= previousDisplayEnd,
                      word.displayRange.startUTF8Byte >= 0,
                      word.displayRange.startUTF8Byte < word.displayRange.endUTF8Byte,
                      word.displayRange.endUTF8Byte <= lineBytes.count,
                      Array(
                        lineBytes[
                            word.displayRange.startUTF8Byte..<word.displayRange.endUTF8Byte
                        ]
                      ) == Array(word.text.utf8),
                      !hasLexicalContent(
                        String(
                            decoding: lineBytes[
                                previousDisplayEnd..<word.displayRange.startUTF8Byte
                            ],
                            as: UTF8.self
                        )
                      )
                else {
                    throw TranscriptRevisionIntegrityError.invalidTextMapping
                }
                previousDisplayEnd = word.displayRange.endUTF8Byte
                if let range = word.timeRange {
                    guard range.startMilliseconds >= line.timeRange.startMilliseconds,
                          range.endMilliseconds <= line.timeRange.endMilliseconds,
                          range.startMilliseconds >= previousTimedWordEnd
                    else {
                        throw TranscriptRevisionIntegrityError.invalidTiming
                    }
                    previousTimedWordEnd = range.endMilliseconds
                }
                if let confidence = word.confidence,
                   (!confidence.isFinite || !(0...1).contains(confidence))
                {
                    throw TranscriptRevisionIntegrityError.invalidConfidence
                }
            }
            guard !hasLexicalContent(
                String(
                    decoding: lineBytes[previousDisplayEnd..<lineBytes.count],
                    as: UTF8.self
                )
            ) else {
                throw TranscriptRevisionIntegrityError.invalidTextMapping
            }
        }
        guard !TranscriptRepetitionValidator.isPathological(
            words: canonicalWordTexts,
            maximumConsecutiveOccurrences: 8
        ) else {
            throw TranscriptRevisionIntegrityError.pathologicalRepetition
        }

        var previousEventEnd: UInt64 = 0
        for (index, event) in audioEvents.enumerated() {
            guard event.audioEventID.rawValue == stableID(prefix: "a", ordinal: index),
                  sourceIDs.contains(event.audioSourceID),
                  event.timeRange.endMilliseconds <= durationMilliseconds,
                  index == 0 || event.timeRange.startMilliseconds >= previousEventEnd
            else {
                throw TranscriptRevisionIntegrityError.invalidAudioEvent
            }
            previousEventEnd = event.timeRange.endMilliseconds
        }
    }

    private static func stableID(prefix: Character, ordinal: Int) -> String {
        let digits = String(ordinal)
        return String(prefix) + String(repeating: "0", count: max(0, 6 - digits.count)) + digits
    }

    private static func hasLexicalContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.properties.isAlphabetic || (48...57).contains(scalar.value)
        }
    }
}
