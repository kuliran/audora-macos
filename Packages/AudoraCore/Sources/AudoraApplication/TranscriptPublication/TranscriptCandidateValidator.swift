import AudoraDomain

public enum TranscriptCandidateValidationError: Error, Equatable, Sendable {
    case unsupportedSchema
    case identityMismatch
    case integrityMismatch
    case engineMismatch
    case invalidDuration
    case invalidSource
    case invalidLineOrdering
    case invalidWordOrdering
    case invalidTiming
    case invalidTextMapping
    case punctuationIsNotAWord
    case invalidConfidence
    case invalidAudioEvent
    case insufficientCoverage
    case wordCountCollapse
    case pathologicalRepetition
    case pathologicalSize
    case invalidPolicy
}

public struct TranscriptValidationPolicy: Equatable, Sendable {
    public static let versionOne = TranscriptValidationPolicy(
        maximumLines: 100_000,
        maximumWords: 1_000_000,
        maximumAudioEvents: 100_000,
        maximumAggregateTextUTF8Bytes:
            TranscriptRevisionLimits.maximumAggregateTextUTF8Bytes,
        maximumCoverageEdgeGapMilliseconds: 2_000,
        maximumVoicedMillisecondsPerWord: 15_000,
        maximumConsecutiveNGramOccurrences: 8
    )

    public let maximumLines: Int
    public let maximumWords: Int
    public let maximumAudioEvents: Int
    public let maximumAggregateTextUTF8Bytes: Int
    public let maximumCoverageEdgeGapMilliseconds: UInt64
    public let maximumVoicedMillisecondsPerWord: UInt64
    public let maximumConsecutiveNGramOccurrences: Int

    public init(
        maximumLines: Int,
        maximumWords: Int,
        maximumAudioEvents: Int,
        maximumAggregateTextUTF8Bytes: Int,
        maximumCoverageEdgeGapMilliseconds: UInt64,
        maximumVoicedMillisecondsPerWord: UInt64,
        maximumConsecutiveNGramOccurrences: Int
    ) {
        self.maximumLines = maximumLines
        self.maximumWords = maximumWords
        self.maximumAudioEvents = maximumAudioEvents
        self.maximumAggregateTextUTF8Bytes = maximumAggregateTextUTF8Bytes
        self.maximumCoverageEdgeGapMilliseconds = maximumCoverageEdgeGapMilliseconds
        self.maximumVoicedMillisecondsPerWord = maximumVoicedMillisecondsPerWord
        self.maximumConsecutiveNGramOccurrences = maximumConsecutiveNGramOccurrences
    }

    var isValid: Bool {
        (1...100_000).contains(maximumLines) &&
            (1...1_000_000).contains(maximumWords) &&
            (0...100_000).contains(maximumAudioEvents) &&
            (1...TranscriptRevisionLimits.maximumAggregateTextUTF8Bytes)
                .contains(maximumAggregateTextUTF8Bytes) &&
            maximumCoverageEdgeGapMilliseconds <= 2_700_000 &&
            (1...2_700_000).contains(maximumVoicedMillisecondsPerWord) &&
            (1...1_024).contains(maximumConsecutiveNGramOccurrences)
    }
}

public struct TranscriptCandidateValidator: Sendable {
    private let policy: TranscriptValidationPolicy

    public init(policy: TranscriptValidationPolicy = .versionOne) {
        self.policy = policy
    }

    public func validate(
        _ candidate: TranscriptionCandidate,
        against context: TranscriptPublicationContext
    ) throws -> TranscriptRevision {
        guard policy.isValid else {
            throw TranscriptCandidateValidationError.invalidPolicy
        }
        guard candidate.schemaVersion == 1 else {
            throw TranscriptCandidateValidationError.unsupportedSchema
        }
        guard candidate.jobID == context.jobID.rawValue,
              candidate.sessionID == context.sessionID.rawValue,
              candidate.revisionID == context.revisionID.rawValue
        else {
            throw TranscriptCandidateValidationError.identityMismatch
        }
        guard candidate.durationMilliseconds == context.durationMilliseconds,
              candidate.durationMilliseconds > 0,
              candidate.durationMilliseconds <= 2_700_000
        else {
            throw TranscriptCandidateValidationError.invalidDuration
        }
        guard candidate.audioFingerprintSHA256 == context.audioFingerprint.sha256,
              candidate.candidateArtifactSHA256 ==
                context.verifiedCandidateArtifactFingerprint.sha256,
              (1...32).contains(context.sourceFingerprints.count),
              candidate.sourceFingerprints.count == context.sourceFingerprints.count
        else {
            throw TranscriptCandidateValidationError.integrityMismatch
        }
        var expectedSources: [String: String] = [:]
        for source in context.sourceFingerprints {
            guard expectedSources.updateValue(
                source.fingerprint.sha256,
                forKey: source.audioSourceID.rawValue
            ) == nil else {
                throw TranscriptCandidateValidationError.integrityMismatch
            }
        }
        guard !expectedSources.isEmpty else {
            throw TranscriptCandidateValidationError.integrityMismatch
        }
        var candidateSourceIDs = Set<String>()
        for source in candidate.sourceFingerprints {
            guard candidateSourceIDs.insert(source.audioSourceID).inserted,
                  expectedSources[source.audioSourceID] == source.sha256
            else {
                throw TranscriptCandidateValidationError.integrityMismatch
            }
        }
        guard candidateSourceIDs == Set(expectedSources.keys) else {
            throw TranscriptCandidateValidationError.integrityMismatch
        }
        guard let trustedQualification = context.engine.qualification,
              candidate.engine.provider == context.engine.provider,
              candidate.engine.model == context.engine.model,
              candidate.engine.revision == context.engine.revision,
              candidate.engine.language == context.engine.language,
              candidate.engine.mode == context.engine.mode,
              candidate.engine.decodingOptionsSHA256 == context.engine.decodingOptionsSHA256,
              candidate.engine.qualification.schemaVersion ==
                TranscriptEngineQualification.schemaVersion,
              candidate.engine.qualification.qualificationProfileID ==
                trustedQualification.qualificationProfileID,
              candidate.engine.qualification.engineLockSHA256 ==
                trustedQualification.engineLockSHA256,
              candidate.engine.qualification.runtimeIdentity ==
                trustedQualification.runtimeIdentity,
              candidate.engine.qualification.runtimeLockSHA256 ==
                trustedQualification.runtimeLockSHA256,
              candidate.engine.qualification.compatibilityPatchID ==
                trustedQualification.compatibilityPatchID
        else {
            throw TranscriptCandidateValidationError.engineMismatch
        }
        guard !candidate.lines.isEmpty,
              candidate.lines.count <= policy.maximumLines,
              candidate.audioEvents.count <= policy.maximumAudioEvents
        else {
            throw TranscriptCandidateValidationError.wordCountCollapse
        }

        var lines: [TranscriptLine] = []
        var allWords: [TranscriptWord] = []
        var previousLineEnd: UInt64 = 0
        var previousTimedWordEnd: UInt64 = 0
        var aggregateTextBytes = 0

        for (lineIndex, candidateLine) in candidate.lines.enumerated() {
            guard candidateLine.order == lineIndex,
                  candidateLine.lineID == stableAnchorID(prefix: "l", ordinal: lineIndex)
            else {
                throw TranscriptCandidateValidationError.invalidLineOrdering
            }
            guard let expectedSourceHash = expectedSources[candidateLine.audioSourceID],
                  !expectedSourceHash.isEmpty,
                  let audioSourceID = try? AudioSourceID(candidateLine.audioSourceID)
            else {
                throw TranscriptCandidateValidationError.invalidSource
            }
            let lineRange = try timeRange(
                candidateLine.timeRange,
                durationMilliseconds: context.durationMilliseconds
            )
            guard lineIndex == 0 || lineRange.startMilliseconds >= previousLineEnd else {
                throw TranscriptCandidateValidationError.invalidLineOrdering
            }
            previousLineEnd = lineRange.endMilliseconds
            let lineTextBytes = candidateLine.text.utf8.count
            guard lineTextBytes > 0,
                  lineTextBytes <= TranscriptRevisionLimits.maximumLineUTF8Bytes,
                  aggregateTextBytes <=
                    policy.maximumAggregateTextUTF8Bytes - lineTextBytes
            else {
                throw TranscriptCandidateValidationError.pathologicalSize
            }
            aggregateTextBytes += lineTextBytes
            guard !candidateLine.words.isEmpty else {
                throw TranscriptCandidateValidationError.invalidTextMapping
            }
            guard allWords.count <= policy.maximumWords - candidateLine.words.count else {
                throw TranscriptCandidateValidationError.pathologicalSize
            }

            var words: [TranscriptWord] = []
            var previousDisplayEnd = 0
            let lineBytes = Array(candidateLine.text.utf8)
            for candidateWord in candidateLine.words {
                let expectedOrdinal = allWords.count + words.count
                guard candidateWord.ordinal == expectedOrdinal,
                      candidateWord.wordID == stableAnchorID(
                        prefix: "w",
                        ordinal: expectedOrdinal
                      )
                else {
                    throw TranscriptCandidateValidationError.invalidWordOrdering
                }
                let wordTextBytes = candidateWord.text.utf8.count
                guard wordTextBytes <= TranscriptRevisionLimits.maximumWordUTF8Bytes,
                      wordTextBytes <=
                    policy.maximumAggregateTextUTF8Bytes - aggregateTextBytes
                else {
                    throw TranscriptCandidateValidationError.pathologicalSize
                }
                aggregateTextBytes += wordTextBytes
                let wordKind = TranscriptWordKind(rawValue: candidateWord.wordKind.rawValue)!
                guard TranscriptWordTextValidator.isValid(
                    candidateWord.text,
                    kind: wordKind
                ) else {
                    throw TranscriptCandidateValidationError.punctuationIsNotAWord
                }
                let display = candidateWord.displayRange
                guard display.startUTF8Byte >= previousDisplayEnd,
                      display.startUTF8Byte >= 0,
                      display.startUTF8Byte < display.endUTF8Byte,
                      display.endUTF8Byte <= lineBytes.count,
                      Array(lineBytes[display.startUTF8Byte..<display.endUTF8Byte]) ==
                        Array(candidateWord.text.utf8)
                else {
                    throw TranscriptCandidateValidationError.invalidTextMapping
                }
                if containsLexicalContent(
                    lineBytes[previousDisplayEnd..<display.startUTF8Byte]
                ) {
                    throw TranscriptCandidateValidationError.invalidTextMapping
                }
                previousDisplayEnd = display.endUTF8Byte

                let wordRange: SessionTimeRange?
                if let candidateRange = candidateWord.timeRange {
                    let validated = try timeRange(
                        candidateRange,
                        durationMilliseconds: context.durationMilliseconds
                    )
                    guard validated.startMilliseconds >= lineRange.startMilliseconds,
                          validated.endMilliseconds <= lineRange.endMilliseconds,
                          validated.startMilliseconds >= previousTimedWordEnd
                    else {
                        throw TranscriptCandidateValidationError.invalidTiming
                    }
                    previousTimedWordEnd = validated.endMilliseconds
                    wordRange = validated
                } else {
                    wordRange = nil
                }
                if let confidence = candidateWord.confidence,
                   (!confidence.isFinite || !(0...1).contains(confidence))
                {
                    throw TranscriptCandidateValidationError.invalidConfidence
                }
                guard let wordID = try? TranscriptWordID(candidateWord.wordID) else {
                    throw TranscriptCandidateValidationError.invalidWordOrdering
                }
                words.append(
                    TranscriptWord(
                        wordID: wordID,
                        ordinal: candidateWord.ordinal,
                        text: candidateWord.text,
                        displayRange: LineTextRange(
                            startUTF8Byte: display.startUTF8Byte,
                            endUTF8Byte: display.endUTF8Byte
                        ),
                        timeRange: wordRange,
                        confidence: candidateWord.confidence,
                        wordKind: wordKind
                    )
                )
            }
            if containsLexicalContent(lineBytes[previousDisplayEnd..<lineBytes.count]) {
                throw TranscriptCandidateValidationError.invalidTextMapping
            }
            guard allWords.count + words.count <= policy.maximumWords,
                  let lineID = try? TranscriptLineID(candidateLine.lineID)
            else {
                throw TranscriptCandidateValidationError.wordCountCollapse
            }
            allWords.append(contentsOf: words)
            lines.append(
                TranscriptLine(
                    lineID: lineID,
                    order: candidateLine.order,
                    audioSourceID: audioSourceID,
                    timeRange: lineRange,
                    text: candidateLine.text,
                    words: words
                )
            )
        }

        try rejectPathologicalRepetition(in: allWords)
        let audioEvents = try validateAudioEvents(
            candidate.audioEvents,
            expectedSources: expectedSources,
            durationMilliseconds: context.durationMilliseconds
        )
        try validateCoverage(
            words: allWords,
            audioEvents: audioEvents,
            voicedRanges: context.voicedRanges,
            durationMilliseconds: context.durationMilliseconds
        )

        do {
            return try TranscriptRevision(
            revisionID: context.revisionID,
            sessionID: context.sessionID,
            jobID: context.jobID,
            createdAt: context.createdAt,
            durationMilliseconds: context.durationMilliseconds,
            audioFingerprint: context.audioFingerprint,
            sourceFingerprints: context.sourceFingerprints,
            candidateArtifactFingerprint: context.verifiedCandidateArtifactFingerprint,
            engine: context.engine,
            lines: lines,
            audioEvents: audioEvents
            )
        } catch {
            throw TranscriptCandidateValidationError.integrityMismatch
        }
    }

    private func validateAudioEvents(
        _ candidates: [CandidateTranscriptAudioEvent],
        expectedSources: [String: String],
        durationMilliseconds: UInt64
    ) throws -> [TranscriptAudioEvent] {
        var result: [TranscriptAudioEvent] = []
        var previousEnd: UInt64 = 0
        for (index, candidate) in candidates.enumerated() {
            guard candidate.audioEventID == stableAnchorID(prefix: "a", ordinal: index),
                  expectedSources[candidate.audioSourceID] != nil,
                  let eventID = try? AudioEventID(candidate.audioEventID),
                  let sourceID = try? AudioSourceID(candidate.audioSourceID)
            else {
                throw TranscriptCandidateValidationError.invalidAudioEvent
            }
            let range = try timeRange(
                candidate.timeRange,
                durationMilliseconds: durationMilliseconds
            )
            guard index == 0 || range.startMilliseconds >= previousEnd else {
                throw TranscriptCandidateValidationError.invalidAudioEvent
            }
            previousEnd = range.endMilliseconds
            result.append(
                TranscriptAudioEvent(
                    audioEventID: eventID,
                    category: candidate.category,
                    audioSourceID: sourceID,
                    timeRange: range
                )
            )
        }
        return result
    }

    private func validateCoverage(
        words: [TranscriptWord],
        audioEvents: [TranscriptAudioEvent],
        voicedRanges: [SessionTimeRange],
        durationMilliseconds: UInt64
    ) throws {
        guard !voicedRanges.isEmpty,
              voicedRanges.count <= TranscriptRevisionLimits.maximumVoicedRangeCount
        else {
            throw TranscriptCandidateValidationError.insufficientCoverage
        }
        var previousVoicedEnd: UInt64 = 0
        var voicedDuration: UInt64 = 0
        for (index, range) in voicedRanges.enumerated() {
            guard range.endMilliseconds <= durationMilliseconds,
                  index == 0 || range.startMilliseconds >= previousVoicedEnd
            else {
                throw TranscriptCandidateValidationError.insufficientCoverage
            }
            voicedDuration += range.endMilliseconds - range.startMilliseconds
            previousVoicedEnd = range.endMilliseconds
        }
        let evidenceRanges = words.compactMap(\.timeRange) + audioEvents.compactMap {
            $0.category == .untranscribedVoicedInterval ? $0.timeRange : nil
        }
        let orderedEvidence = evidenceRanges.sorted {
            ($0.startMilliseconds, $0.endMilliseconds) <
                ($1.startMilliseconds, $1.endMilliseconds)
        }
        guard !orderedEvidence.isEmpty else {
            throw TranscriptCandidateValidationError.insufficientCoverage
        }
        var mergedEvidence: [(start: UInt64, end: UInt64)] = []
        mergedEvidence.reserveCapacity(orderedEvidence.count)
        for range in orderedEvidence {
            if let last = mergedEvidence.last,
               range.startMilliseconds <= last.end
            {
                mergedEvidence[mergedEvidence.count - 1].end = max(
                    last.end,
                    range.endMilliseconds
                )
            } else {
                mergedEvidence.append((
                    start: range.startMilliseconds,
                    end: range.endMilliseconds
                ))
            }
        }
        var firstRelevantEvidence = 0
        for voiced in voicedRanges {
            while firstRelevantEvidence < mergedEvidence.count,
                  mergedEvidence[firstRelevantEvidence].end <= voiced.startMilliseconds
            {
                firstRelevantEvidence += 1
            }
            var coveredThrough = voiced.startMilliseconds
            var evidenceIndex = firstRelevantEvidence
            var foundEvidence = false
            while evidenceIndex < mergedEvidence.count,
                  mergedEvidence[evidenceIndex].start < voiced.endMilliseconds
            {
                let evidence = mergedEvidence[evidenceIndex]
                foundEvidence = true
                if evidence.start > coveredThrough,
                   evidence.start - coveredThrough >
                    policy.maximumCoverageEdgeGapMilliseconds
                {
                    throw TranscriptCandidateValidationError.insufficientCoverage
                }
                coveredThrough = max(coveredThrough, evidence.end)
                if coveredThrough >= voiced.endMilliseconds { break }
                evidenceIndex += 1
            }
            guard foundEvidence else {
                throw TranscriptCandidateValidationError.insufficientCoverage
            }
            if voiced.endMilliseconds > coveredThrough,
               voiced.endMilliseconds - coveredThrough >
                policy.maximumCoverageEdgeGapMilliseconds
            {
                throw TranscriptCandidateValidationError.insufficientCoverage
            }
        }
        let minimumWords = Int(
            voicedDuration / policy.maximumVoicedMillisecondsPerWord +
                (voicedDuration % policy.maximumVoicedMillisecondsPerWord == 0 ? 0 : 1)
        )
        guard words.count >= minimumWords else {
            throw TranscriptCandidateValidationError.wordCountCollapse
        }
    }

    private func rejectPathologicalRepetition(in words: [TranscriptWord]) throws {
        if TranscriptRepetitionValidator.isPathological(
            words: words.map(\.text),
            maximumConsecutiveOccurrences: policy.maximumConsecutiveNGramOccurrences
        ) {
            throw TranscriptCandidateValidationError.pathologicalRepetition
        }
    }

    private func timeRange(
        _ candidate: CandidateSessionTimeRange,
        durationMilliseconds: UInt64
    ) throws -> SessionTimeRange {
        do {
            return try SessionTimeRange(
                startMilliseconds: candidate.startMilliseconds,
                endMilliseconds: candidate.endMilliseconds,
                sessionDurationMilliseconds: durationMilliseconds
            )
        } catch {
            throw TranscriptCandidateValidationError.invalidTiming
        }
    }

    private func stableAnchorID(prefix: Character, ordinal: Int) -> String {
        let digits = String(ordinal)
        return String(prefix) + String(repeating: "0", count: max(0, 6 - digits.count)) + digits
    }

    private func hasLexicalContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.properties.isAlphabetic || (48...57).contains(scalar.value)
        }
    }

    private func containsLexicalContent(_ bytes: ArraySlice<UInt8>) -> Bool {
        hasLexicalContent(String(decoding: bytes, as: UTF8.self))
    }

}
