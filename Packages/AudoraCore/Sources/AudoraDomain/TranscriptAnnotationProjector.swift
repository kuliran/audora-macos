public struct TextualEventOverlay: Equatable, Sendable {
    public let textualEventID: TextualEventID
    public let category: TextualEventCategory
    public let lineID: TranscriptLineID
    public let wordID: TranscriptWordID
    public let displayRange: LineTextRange

    public init(
        textualEventID: TextualEventID,
        category: TextualEventCategory,
        lineID: TranscriptLineID,
        wordID: TranscriptWordID,
        displayRange: LineTextRange
    ) {
        self.textualEventID = textualEventID
        self.category = category
        self.lineID = lineID
        self.wordID = wordID
        self.displayRange = displayRange
    }
}

public struct TranscriptAnnotationProjection: Equatable, Sendable {
    public let transcriptRevisionID: TranscriptRevisionID
    public let textualOverlays: [TextualEventOverlay]
    public let audioEvents: [TranscriptAudioEvent]

    public init(
        transcriptRevisionID: TranscriptRevisionID,
        textualOverlays: [TextualEventOverlay],
        audioEvents: [TranscriptAudioEvent]
    ) {
        self.transcriptRevisionID = transcriptRevisionID
        self.textualOverlays = textualOverlays
        self.audioEvents = audioEvents
    }
}

public enum TranscriptAnnotationProjectionError: Error, Equatable, Sendable {
    case revisionMismatch
    case invalidWordRange
    case outputLimitExceeded
}

/// Maps local Annotation anchors onto canonical Word display ranges. It returns
/// styling metadata only: canonical transcript text and seek targets never pass
/// through this module and therefore cannot be rewritten by an overlay.
public enum TranscriptAnnotationProjector {
    public static func project(
        _ annotations: TranscriptAnnotationSet,
        over revision: TranscriptRevision
    ) throws -> TranscriptAnnotationProjection {
        guard annotations.transcriptRevisionID == revision.revisionID else {
            throw TranscriptAnnotationProjectionError.revisionMismatch
        }
        struct LocatedWord {
            let lineID: TranscriptLineID
            let word: TranscriptWord
        }
        let words = revision.lines.flatMap { line in
            line.words.map {
                LocatedWord(lineID: line.lineID, word: $0)
            }
        }
        let indices = Dictionary(
            uniqueKeysWithValues: words.enumerated().map { ($0.element.word.wordID, $0.offset) }
        )
        let textualEvents = annotations.textualEvents
        let audioEvents = annotations.audioEvents
        guard textualEvents.count <= DeterministicSpeechAnnotator.maximumAnnotationCount,
              audioEvents.count <= DeterministicSpeechAnnotator.maximumAnnotationCount -
                textualEvents.count
        else { throw TranscriptAnnotationProjectionError.outputLimitExceeded }
        var selectedByWord: [TranscriptWordID: TextualEventOverlay] = [:]
        var projectedRangeWords = 0
        for event in textualEvents {
            guard event.transcriptRevisionID == revision.revisionID,
                  let first = indices[event.wordRange.firstWordID],
                  let last = indices[event.wordRange.lastWordID],
                  first <= last
            else { throw TranscriptAnnotationProjectionError.invalidWordRange }
            guard last - first < DeterministicSpeechAnnotator.maximumAnnotationCount
            else { throw TranscriptAnnotationProjectionError.outputLimitExceeded }
            for word in words[first...last] {
                projectedRangeWords += 1
                guard projectedRangeWords <=
                    DeterministicSpeechAnnotator.maximumAnnotationCount
                else { throw TranscriptAnnotationProjectionError.outputLimitExceeded }
                let candidate = TextualEventOverlay(
                    textualEventID: event.textualEventID,
                    category: event.category,
                    lineID: word.lineID,
                    wordID: word.word.wordID,
                    displayRange: word.word.displayRange
                )
                if let current = selectedByWord[word.word.wordID],
                   precedes(current, candidate)
                {
                    continue
                }
                selectedByWord[word.word.wordID] = candidate
                guard selectedByWord.count <=
                    DeterministicSpeechAnnotator.maximumAnnotationCount
                else { throw TranscriptAnnotationProjectionError.outputLimitExceeded }
            }
        }
        let textual = words.compactMap { selectedByWord[$0.word.wordID] }
        guard textual.count <= DeterministicSpeechAnnotator.maximumAnnotationCount,
              audioEvents.count <=
                DeterministicSpeechAnnotator.maximumAnnotationCount - textual.count
        else { throw TranscriptAnnotationProjectionError.outputLimitExceeded }
        return TranscriptAnnotationProjection(
            transcriptRevisionID: revision.revisionID,
            textualOverlays: textual,
            audioEvents: audioEvents
        )
    }

    private static func precedes(
        _ lhs: TextualEventOverlay,
        _ rhs: TextualEventOverlay
    ) -> Bool {
        let leftPriority = priority(lhs.category)
        let rightPriority = priority(rhs.category)
        if leftPriority != rightPriority { return leftPriority < rightPriority }
        return lhs.textualEventID.rawValue <= rhs.textualEventID.rawValue
    }

    private static func priority(_ category: TextualEventCategory) -> Int {
        switch category {
        case .filledPause: 0
        case .partialWord: 1
        case .repetitionCandidate: 2
        }
    }
}
