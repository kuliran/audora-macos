import Foundation

public enum TextualEventIDError: Error, Equatable, Sendable {
    case invalidTextualEventID
}

public struct TextualEventID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard rawValue.utf8.count == 7,
              rawValue.first == "t",
              rawValue.utf8.dropFirst().allSatisfy({ (48...57).contains($0) })
        else { throw TextualEventIDError.invalidTextualEventID }
        self.rawValue = rawValue
    }
}

public enum TextualEventCategory: String, Equatable, Sendable {
    case filledPause
    case partialWord
    case repetitionCandidate
}

public enum AnnotationConfidence: String, Equatable, Sendable {
    case high
    case medium
}

public struct TranscriptWordRange: Equatable, Sendable {
    public let firstWordID: TranscriptWordID
    public let lastWordID: TranscriptWordID

    public init(
        firstWordID: TranscriptWordID,
        lastWordID: TranscriptWordID
    ) {
        self.firstWordID = firstWordID
        self.lastWordID = lastWordID
    }
}

public struct TextualEvent: Equatable, Sendable {
    public let textualEventID: TextualEventID
    public let transcriptRevisionID: TranscriptRevisionID
    public let category: TextualEventCategory
    public let wordRange: TranscriptWordRange
    public let confidence: AnnotationConfidence
    public let ruleVersion: String

    public init(
        textualEventID: TextualEventID,
        transcriptRevisionID: TranscriptRevisionID,
        category: TextualEventCategory,
        wordRange: TranscriptWordRange,
        confidence: AnnotationConfidence,
        ruleVersion: String
    ) {
        self.textualEventID = textualEventID
        self.transcriptRevisionID = transcriptRevisionID
        self.category = category
        self.wordRange = wordRange
        self.confidence = confidence
        self.ruleVersion = ruleVersion
    }
}

public enum TranscriptAnnotation: Equatable, Sendable {
    case textual(TextualEvent)
    case audio(TranscriptAudioEvent)
}

public struct TranscriptAnnotationSet: Equatable, Sendable {
    public let transcriptRevisionID: TranscriptRevisionID
    public let ruleVersion: String
    public let annotations: [TranscriptAnnotation]

    public init(
        transcriptRevisionID: TranscriptRevisionID,
        ruleVersion: String,
        annotations: [TranscriptAnnotation]
    ) {
        self.transcriptRevisionID = transcriptRevisionID
        self.ruleVersion = ruleVersion
        self.annotations = annotations
    }

    public var textualEvents: [TextualEvent] {
        annotations.compactMap {
            guard case let .textual(event) = $0 else { return nil }
            return event
        }
    }

    public var audioEvents: [TranscriptAudioEvent] {
        annotations.compactMap {
            guard case let .audio(event) = $0 else { return nil }
            return event
        }
    }
}

public struct SpeechUnavailableInterval: Equatable, Sendable {
    public let timeRange: SessionTimeRange
    public let reasons: Set<UnavailableReason>

    public init(
        timeRange: SessionTimeRange,
        reasons: Set<UnavailableReason>
    ) {
        self.timeRange = timeRange
        self.reasons = reasons
    }
}

public struct SpeechAcousticEvidence: Equatable, Sendable {
    public let audioSourceID: AudioSourceID
    public let observedRanges: [SessionTimeRange]
    public let voicedRanges: [SessionTimeRange]
    public let unavailableIntervals: [SpeechUnavailableInterval]

    public init(
        audioSourceID: AudioSourceID,
        observedRanges: [SessionTimeRange],
        voicedRanges: [SessionTimeRange],
        unavailableIntervals: [SpeechUnavailableInterval]
    ) {
        self.audioSourceID = audioSourceID
        self.observedRanges = observedRanges
        self.voicedRanges = voicedRanges
        self.unavailableIntervals = unavailableIntervals
    }
}

public struct SpeechAnnotationEvidence: Equatable, Sendable {
    public static let none = SpeechAnnotationEvidence(sources: [])

    public let sources: [SpeechAcousticEvidence]

    public init(sources: [SpeechAcousticEvidence]) {
        self.sources = sources
    }
}

public enum SpeechAnnotationError: Error, Equatable, Sendable {
    case invalidEvidence
    case outputLimitExceeded
}

/// Pure, versioned local rules over immutable transcript and normalized audio
/// evidence. The module has no model, provider, persistence, or transport seam.
public struct DeterministicSpeechAnnotator: Sendable {
    public static let ruleVersion = "audora-speech-annotations-v1"
    public static let maximumAnnotationCount = 100_000
    private static let maximumRepetitionPhraseWords = 3
    private static let maximumRepetitionGapMilliseconds: UInt64 = 1_200

    public init() {}

    public func annotate(
        revision: TranscriptRevision,
        evidence: SpeechAnnotationEvidence
    ) throws -> TranscriptAnnotationSet {
        let words = revision.lines.flatMap(\.words)
        var drafts: [TextualDraft] = words.compactMap { word in
            switch word.wordKind {
            case .filledPause:
                TextualDraft(
                    category: .filledPause,
                    firstOrdinal: word.ordinal,
                    lastOrdinal: word.ordinal,
                    confidence: .high
                )
            case .partialWord:
                TextualDraft(
                    category: .partialWord,
                    firstOrdinal: word.ordinal,
                    lastOrdinal: word.ordinal,
                    confidence: .high
                )
            case .lexical:
                nil
            }
        }
        drafts.append(contentsOf: repetitionDrafts(in: words))
        drafts.sort {
            if $0.firstOrdinal != $1.firstOrdinal {
                return $0.firstOrdinal < $1.firstOrdinal
            }
            if $0.lastOrdinal != $1.lastOrdinal {
                return $0.lastOrdinal < $1.lastOrdinal
            }
            return categoryPriority($0.category) < categoryPriority($1.category)
        }
        guard drafts.count <= Self.maximumAnnotationCount else {
            throw SpeechAnnotationError.outputLimitExceeded
        }
        let textualAnnotations = try drafts.enumerated().map { index, draft in
            TranscriptAnnotation.textual(
                TextualEvent(
                    textualEventID: try TextualEventID(stableID("t", index)),
                    transcriptRevisionID: revision.revisionID,
                    category: draft.category,
                    wordRange: TranscriptWordRange(
                        firstWordID: words[draft.firstOrdinal].wordID,
                        lastWordID: words[draft.lastOrdinal].wordID
                    ),
                    confidence: draft.confidence,
                    ruleVersion: Self.ruleVersion
                )
            )
        }
        let audioEvents = try classifyAudio(
            revision: revision,
            evidence: evidence
        )
        guard textualAnnotations.count <=
            Self.maximumAnnotationCount - audioEvents.count
        else { throw SpeechAnnotationError.outputLimitExceeded }
        return TranscriptAnnotationSet(
            transcriptRevisionID: revision.revisionID,
            ruleVersion: Self.ruleVersion,
            annotations: textualAnnotations + audioEvents.map(TranscriptAnnotation.audio)
        )
    }

    private struct TextualDraft {
        let category: TextualEventCategory
        let firstOrdinal: Int
        let lastOrdinal: Int
        let confidence: AnnotationConfidence
    }

    private struct LexicalWord {
        let word: TranscriptWord
        let normalized: String
    }

    private struct Interval: Equatable {
        let start: UInt64
        let end: UInt64

        init(start: UInt64, end: UInt64) {
            self.start = start
            self.end = end
        }

        init(_ range: SessionTimeRange) {
            start = range.startMilliseconds
            end = range.endMilliseconds
        }
    }

    private struct AudioDraft {
        let category: TranscriptAudioEventCategory
        let audioSourceID: AudioSourceID
        let interval: Interval
    }

    private func classifyAudio(
        revision: TranscriptRevision,
        evidence: SpeechAnnotationEvidence
    ) throws -> [TranscriptAudioEvent] {
        guard evidence.sources.count <= 32,
              Set(evidence.sources.map(\.audioSourceID)).count ==
                evidence.sources.count
        else { throw SpeechAnnotationError.invalidEvidence }
        let allowedSources = Set(revision.sourceFingerprints.map(\.audioSourceID))
        let evidenceSourceIDs = Set(evidence.sources.map(\.audioSourceID))
        var totalInputRanges = 0
        var retainedExisting = revision.audioEvents.filter {
            !evidenceSourceIDs.contains($0.audioSourceID)
        }
        var derived: [AudioDraft] = []
        for source in evidence.sources {
            guard allowedSources.contains(source.audioSourceID) else {
                throw SpeechAnnotationError.invalidEvidence
            }
            let (observedCount, observedOverflow) = totalInputRanges
                .addingReportingOverflow(source.observedRanges.count)
            let (voicedCount, voicedOverflow) = observedCount
                .addingReportingOverflow(source.voicedRanges.count)
            let (unavailableCount, unavailableOverflow) = voicedCount
                .addingReportingOverflow(source.unavailableIntervals.count)
            guard !observedOverflow, !voicedOverflow, !unavailableOverflow,
                  unavailableCount <= TranscriptRevisionLimits.maximumVoicedRangeCount,
                  source.unavailableIntervals.allSatisfy({ !$0.reasons.isEmpty }),
                  source.observedRanges.allSatisfy({
                      $0.endMilliseconds <= revision.durationMilliseconds
                  }),
                  source.voicedRanges.allSatisfy({
                      $0.endMilliseconds <= revision.durationMilliseconds
                  }),
                  source.unavailableIntervals.allSatisfy({
                      $0.timeRange.endMilliseconds <= revision.durationMilliseconds
                  })
            else { throw SpeechAnnotationError.invalidEvidence }
            totalInputRanges = unavailableCount

            let existing = revision.audioEvents.filter {
                $0.audioSourceID == source.audioSourceID
            }
            let wordCoverage = normalize(
                revision.lines
                    .filter { $0.audioSourceID == source.audioSourceID }
                    .flatMap(\.words)
                    .compactMap { $0.timeRange.map(Interval.init) }
            )
            let unavailable = normalize(
                source.unavailableIntervals.map { Interval($0.timeRange) } +
                    existing.compactMap {
                        switch $0.category {
                        case .muted, .captureGap: Interval($0.timeRange)
                        case .nonSpeech, .silentPause,
                             .untranscribedVoicedInterval: nil
                        }
                    }
            )
            var existingObservedCoverage: [Interval] = []
            for event in existing {
                let interval = Interval(event.timeRange)
                switch event.category {
                case .nonSpeech, .silentPause, .untranscribedVoicedInterval:
                    let availableFragments = subtract([interval], unavailable)
                    if availableFragments == [interval] {
                        retainedExisting.append(event)
                    } else {
                        derived.append(contentsOf: availableFragments.map {
                            AudioDraft(
                                category: event.category,
                                audioSourceID: event.audioSourceID,
                                interval: $0
                            )
                        })
                    }
                    existingObservedCoverage.append(contentsOf: availableFragments)
                case .muted, .captureGap:
                    retainedExisting.append(event)
                }
            }
            let observed = subtract(
                normalize(source.observedRanges.map(Interval.init)),
                unavailable
            )
            let residual = subtract(
                subtract(observed, wordCoverage),
                normalize(existingObservedCoverage)
            )
            let voiced = intersect(
                residual,
                normalize(source.voicedRanges.map(Interval.init))
            )
            let silent = subtract(residual, voiced)
            derived.append(contentsOf: silent.map {
                AudioDraft(
                    category: .silentPause,
                    audioSourceID: source.audioSourceID,
                    interval: $0
                )
            })
            derived.append(contentsOf: voiced.map {
                AudioDraft(
                    category: .untranscribedVoicedInterval,
                    audioSourceID: source.audioSourceID,
                    interval: $0
                )
            })
            for reason in UnavailableReason.allCases {
                let ranges = normalize(
                    source.unavailableIntervals.compactMap {
                        $0.reasons.contains(reason) ? Interval($0.timeRange) : nil
                    }
                )
                let category: TranscriptAudioEventCategory = switch reason {
                case .muted: .muted
                case .captureGap: .captureGap
                }
                let sameCategoryCoverage = normalize(
                    existing.compactMap {
                        $0.category == category ? Interval($0.timeRange) : nil
                    }
                )
                derived.append(contentsOf: subtract(ranges, sameCategoryCoverage).map {
                    AudioDraft(
                        category: category,
                        audioSourceID: source.audioSourceID,
                        interval: $0
                    )
                })
            }
        }

        derived.sort(by: audioDraftPrecedes)
        guard retainedExisting.count <= Self.maximumAnnotationCount,
              derived.count <= Self.maximumAnnotationCount - retainedExisting.count
        else { throw SpeechAnnotationError.outputLimitExceeded }
        let generated = try derived.enumerated().map { index, draft in
            TranscriptAudioEvent(
                audioEventID: try AudioEventID(
                    stableID("a", revision.audioEvents.count + index)
                ),
                category: draft.category,
                audioSourceID: draft.audioSourceID,
                timeRange: try SessionTimeRange(
                    startMilliseconds: draft.interval.start,
                    endMilliseconds: draft.interval.end,
                    sessionDurationMilliseconds: revision.durationMilliseconds
                )
            )
        }
        return (retainedExisting + generated).sorted(by: audioEventPrecedes)
    }

    private func normalize(_ intervals: [Interval]) -> [Interval] {
        let sorted = intervals.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        var result: [Interval] = []
        for interval in sorted {
            guard let last = result.last, interval.start <= last.end else {
                result.append(interval)
                continue
            }
            result[result.count - 1] = Interval(
                start: last.start,
                end: max(last.end, interval.end)
            )
        }
        return result
    }

    private func subtract(_ intervals: [Interval], _ cuts: [Interval]) -> [Interval] {
        guard !intervals.isEmpty, !cuts.isEmpty else { return intervals }
        var result: [Interval] = []
        var cutIndex = 0
        for interval in intervals {
            var cursor = interval.start
            while cutIndex < cuts.count, cuts[cutIndex].end <= cursor {
                cutIndex += 1
            }
            var index = cutIndex
            while index < cuts.count, cuts[index].start < interval.end {
                let cut = cuts[index]
                if cursor < cut.start {
                    result.append(
                        Interval(start: cursor, end: min(cut.start, interval.end))
                    )
                }
                cursor = max(cursor, cut.end)
                if cursor >= interval.end { break }
                index += 1
            }
            if cursor < interval.end {
                result.append(Interval(start: cursor, end: interval.end))
            }
        }
        return result
    }

    private func intersect(_ left: [Interval], _ right: [Interval]) -> [Interval] {
        var result: [Interval] = []
        var leftIndex = 0
        var rightIndex = 0
        while leftIndex < left.count, rightIndex < right.count {
            let start = max(left[leftIndex].start, right[rightIndex].start)
            let end = min(left[leftIndex].end, right[rightIndex].end)
            if start < end { result.append(Interval(start: start, end: end)) }
            if left[leftIndex].end < right[rightIndex].end {
                leftIndex += 1
            } else {
                rightIndex += 1
            }
        }
        return result
    }

    private func audioDraftPrecedes(_ lhs: AudioDraft, _ rhs: AudioDraft) -> Bool {
        if lhs.interval.start != rhs.interval.start {
            return lhs.interval.start < rhs.interval.start
        }
        if lhs.interval.end != rhs.interval.end {
            return lhs.interval.end < rhs.interval.end
        }
        if lhs.category != rhs.category {
            return audioCategoryPriority(lhs.category) <
                audioCategoryPriority(rhs.category)
        }
        return lhs.audioSourceID.rawValue < rhs.audioSourceID.rawValue
    }

    private func audioEventPrecedes(
        _ lhs: TranscriptAudioEvent,
        _ rhs: TranscriptAudioEvent
    ) -> Bool {
        if lhs.timeRange.startMilliseconds != rhs.timeRange.startMilliseconds {
            return lhs.timeRange.startMilliseconds < rhs.timeRange.startMilliseconds
        }
        if lhs.timeRange.endMilliseconds != rhs.timeRange.endMilliseconds {
            return lhs.timeRange.endMilliseconds < rhs.timeRange.endMilliseconds
        }
        if lhs.category != rhs.category {
            return audioCategoryPriority(lhs.category) <
                audioCategoryPriority(rhs.category)
        }
        if lhs.audioSourceID != rhs.audioSourceID {
            return lhs.audioSourceID.rawValue < rhs.audioSourceID.rawValue
        }
        return lhs.audioEventID.rawValue < rhs.audioEventID.rawValue
    }

    private func audioCategoryPriority(_ category: TranscriptAudioEventCategory) -> Int {
        switch category {
        case .nonSpeech: 0
        case .muted: 1
        case .captureGap: 2
        case .untranscribedVoicedInterval: 3
        case .silentPause: 4
        }
    }

    private func repetitionDrafts(in words: [TranscriptWord]) -> [TextualDraft] {
        let lexical = words.compactMap { word -> LexicalWord? in
            guard word.wordKind == .lexical else { return nil }
            let normalized = Self.normalizeRepetitionToken(word.text)
            guard !normalized.isEmpty else { return nil }
            return LexicalWord(word: word, normalized: normalized)
        }
        guard lexical.count >= 2 else { return [] }

        var result: [TextualDraft] = []
        var start = 0
        while start < lexical.count - 1 {
            var matchedWidth: Int?
            var matchedOccurrences = 0
            let widest = min(
                Self.maximumRepetitionPhraseWords,
                (lexical.count - start) / 2
            )
            if widest > 0 {
                for width in stride(from: widest, through: 1, by: -1) {
                    guard phrasesMatch(lexical, first: start, second: start + width, width: width),
                          gapIsBounded(
                              lexical,
                              previousStart: start,
                              nextStart: start + width,
                              width: width
                          )
                    else { continue }
                    var occurrences = 2
                    while start + (occurrences + 1) * width <= lexical.count,
                          phrasesMatch(
                              lexical,
                              first: start,
                              second: start + occurrences * width,
                              width: width
                          ),
                          gapIsBounded(
                              lexical,
                              previousStart: start + (occurrences - 1) * width,
                              nextStart: start + occurrences * width,
                              width: width
                          )
                    {
                        occurrences += 1
                    }
                    matchedWidth = width
                    matchedOccurrences = occurrences
                    break
                }
            }
            guard let width = matchedWidth else {
                start += 1
                continue
            }
            let last = start + width * matchedOccurrences - 1
            result.append(
                TextualDraft(
                    category: .repetitionCandidate,
                    firstOrdinal: lexical[start].word.ordinal,
                    lastOrdinal: lexical[last].word.ordinal,
                    confidence: .medium
                )
            )
            start = last + 1
        }
        return result
    }

    private func phrasesMatch(
        _ words: [LexicalWord],
        first: Int,
        second: Int,
        width: Int
    ) -> Bool {
        for offset in 0..<width where
            words[first + offset].normalized != words[second + offset].normalized
        {
            return false
        }
        return true
    }

    private func gapIsBounded(
        _ words: [LexicalWord],
        previousStart: Int,
        nextStart: Int,
        width: Int
    ) -> Bool {
        guard let previous = words[previousStart + width - 1].word.timeRange,
              let next = words[nextStart].word.timeRange,
              next.startMilliseconds >= previous.endMilliseconds
        else { return false }
        return next.startMilliseconds - previous.endMilliseconds <=
            Self.maximumRepetitionGapMilliseconds
    }

    /// Version-one, locale-independent repetition normalization.
    ///
    /// Canonical Words have already passed `TranscriptWordTextValidator`, but
    /// keeping this rule explicit and versioned prevents future ingestion seams
    /// from collapsing internal punctuation such as `U.S.` into `us`. Only
    /// punctuation outside the first/last lexical character is trimmed. One
    /// ASCII hyphen immediately after the last lexical character is retained as
    /// an ASR cutoff marker.
    public static func normalizeRepetitionToken(_ text: String) -> String {
        let compatible = (text as NSString)
            .precomposedStringWithCompatibilityMapping
            .lowercased()
        let characters = Array(compatible)
        guard let first = characters.firstIndex(where: containsLexicalBase),
              let lastLexical = characters.lastIndex(where: containsLexicalBase)
        else { return "" }
        var last = lastLexical
        let afterLexical = characters.index(after: lastLexical)
        if afterLexical < characters.endIndex, characters[afterLexical] == "-" {
            last = afterLexical
        }
        return String(characters[first...last])
    }

    private static func containsLexicalBase(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            $0.properties.isAlphabetic || (48...57).contains($0.value)
        }
    }

    private func categoryPriority(_ category: TextualEventCategory) -> Int {
        switch category {
        case .filledPause: 0
        case .partialWord: 1
        case .repetitionCandidate: 2
        }
    }

    private func stableID(_ prefix: Character, _ ordinal: Int) -> String {
        let digits = String(ordinal)
        return String(prefix) + String(repeating: "0", count: 6 - digits.count) + digits
    }
}
