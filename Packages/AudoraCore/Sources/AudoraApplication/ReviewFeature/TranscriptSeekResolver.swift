import AudoraDomain

/// Pure, immutable index for transcript hit-testing and playback highlighting.
/// Canonical UTF-8 ranges remain the authority; no display-text reconstruction
/// or model inference occurs while resolving a seek.
public struct TranscriptSeekResolver: Sendable {
    private struct DisplayTimedWord: Sendable {
        let startUTF8Byte: Int
        let endUTF8Byte: Int
        let startMilliseconds: UInt64
    }

    private struct TimedWord: Sendable {
        let wordID: TranscriptWordID
        let startMilliseconds: UInt64
        let endMilliseconds: UInt64
    }

    private struct EvidenceWord: Sendable {
        let wordID: TranscriptWordID
        let seekMilliseconds: UInt64
    }

    private struct IndexedLine: Sendable {
        let textUTF8ByteCount: Int
        let startMilliseconds: UInt64
        let words: [TranscriptWord]
        let timedWords: [DisplayTimedWord]
    }

    private let linesByID: [TranscriptLineID: IndexedLine]
    private let timedWords: [TimedWord]
    private let evidenceWords: [EvidenceWord]
    private let evidenceWordPositions: [TranscriptWordID: Int]
    private let audioEventsByID: [AudioEventID: TranscriptAudioEvent]
    private let sessionID: SessionID?
    private let transcriptRevisionID: TranscriptRevisionID?
    private let canonicalAudioDurationMilliseconds: UInt64

    public init(
        revision: TranscriptRevision,
        canonicalAudioDurationMilliseconds: UInt64
    ) {
        self.init(
            sessionID: revision.sessionID,
            transcriptRevisionID: revision.revisionID,
            lines: revision.lines,
            audioEvents: revision.audioEvents,
            canonicalAudioDurationMilliseconds: canonicalAudioDurationMilliseconds
        )
    }

    public init(revision: TranscriptRevision) {
        self.init(
            revision: revision,
            canonicalAudioDurationMilliseconds: revision.durationMilliseconds
        )
    }

    init(
        lines: [TranscriptLine],
        canonicalAudioDurationMilliseconds: UInt64
    ) {
        self.init(
            sessionID: nil,
            transcriptRevisionID: nil,
            lines: lines,
            audioEvents: [],
            canonicalAudioDurationMilliseconds: canonicalAudioDurationMilliseconds
        )
    }

    init(
        sessionID: SessionID?,
        transcriptRevisionID: TranscriptRevisionID?,
        lines: [TranscriptLine],
        audioEvents: [TranscriptAudioEvent],
        canonicalAudioDurationMilliseconds: UInt64
    ) {
        var indexedLines: [TranscriptLineID: IndexedLine] = [:]
        indexedLines.reserveCapacity(lines.count)
        var playbackWords: [TimedWord] = []
        playbackWords.reserveCapacity(lines.reduce(into: 0) { count, line in
            count += line.words.count
        })
        var resolvedEvidenceWords: [EvidenceWord] = []
        resolvedEvidenceWords.reserveCapacity(lines.reduce(into: 0) { count, line in
            count += line.words.count
        })

        for line in lines {
            let displayTimedWords = line.words.compactMap { word -> DisplayTimedWord? in
                guard let timeRange = word.timeRange else { return nil }
                playbackWords.append(
                    TimedWord(
                        wordID: word.wordID,
                        startMilliseconds: timeRange.startMilliseconds,
                        endMilliseconds: timeRange.endMilliseconds
                    )
                )
                return DisplayTimedWord(
                    startUTF8Byte: word.displayRange.startUTF8Byte,
                    endUTF8Byte: word.displayRange.endUTF8Byte,
                    startMilliseconds: timeRange.startMilliseconds
                )
            }
            indexedLines[line.lineID] = IndexedLine(
                textUTF8ByteCount: line.text.utf8.count,
                startMilliseconds: line.timeRange.startMilliseconds,
                words: line.words,
                timedWords: displayTimedWords
            )
            resolvedEvidenceWords.append(contentsOf: line.words.map { word in
                EvidenceWord(
                    wordID: word.wordID,
                    seekMilliseconds: word.timeRange?.startMilliseconds ??
                        line.timeRange.startMilliseconds
                )
            })
        }

        linesByID = indexedLines
        timedWords = playbackWords
        evidenceWords = resolvedEvidenceWords
        evidenceWordPositions = Dictionary(
            uniqueKeysWithValues: resolvedEvidenceWords.enumerated().map {
                ($0.element.wordID, $0.offset)
            }
        )
        audioEventsByID = Dictionary(uniqueKeysWithValues: audioEvents.map {
            ($0.audioEventID, $0)
        })
        self.sessionID = sessionID
        self.transcriptRevisionID = transcriptRevisionID
        self.canonicalAudioDurationMilliseconds = canonicalAudioDurationMilliseconds
    }

    /// Re-resolves a durable reference against the exact loaded revision. The
    /// saved display snapshot is never used as seek or highlight authority.
    public func resolveEvidence(
        _ reference: EvidenceReference
    ) -> ResolvedReviewEvidence? {
        guard reference.sessionID == sessionID,
              reference.transcriptRevisionID == transcriptRevisionID
        else { return nil }
        switch reference.target {
        case let .wordRange(startWordID, endWordID):
            guard let start = evidenceWordPositions[startWordID],
                  let end = evidenceWordPositions[endWordID],
                  start <= end
            else { return nil }
            let words = Array(evidenceWords[start ... end])
            return ResolvedReviewEvidence(
                highlight: .wordRange(words.map(\.wordID)),
                seekMilliseconds: clamped(words[0].seekMilliseconds)
            )
        case let .audioEvent(audioEventID):
            guard let event = audioEventsByID[audioEventID] else { return nil }
            return ResolvedReviewEvidence(
                highlight: .audioEvent(audioEventID),
                seekMilliseconds: clamped(event.timeRange.startMilliseconds)
            )
        }
    }

    /// Resolves a click in canonical line UTF-8 coordinates. A direct untimed
    /// Word intentionally uses the line start; punctuation instead uses the
    /// preceding/following timed-Word fallback chain.
    public func seekTime(
        lineID: TranscriptLineID,
        utf8ByteOffset: Int
    ) -> UInt64? {
        guard let line = linesByID[lineID],
              utf8ByteOffset >= 0,
              utf8ByteOffset < line.textUTF8ByteCount
        else { return nil }

        if let word = containingWord(in: line.words, offset: utf8ByteOffset) {
            return clamped(
                word.timeRange?.startMilliseconds ?? line.startMilliseconds
            )
        }

        if let previous = precedingTimedWord(
            in: line.timedWords,
            offset: utf8ByteOffset
        ) {
            return clamped(previous.startMilliseconds)
        }
        if let following = followingTimedWord(
            in: line.timedWords,
            offset: utf8ByteOffset
        ) {
            return clamped(following.startMilliseconds)
        }
        return clamped(line.startMilliseconds)
    }

    /// Uses a binary search over the globally ordered timed Words. Ranges are
    /// half-open, so silence and untimed gaps have no active Word.
    public func activeWord(atMilliseconds position: UInt64) -> TranscriptWordID? {
        var lower = 0
        var upper = timedWords.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if timedWords[middle].startMilliseconds <= position {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return nil }
        let candidate = timedWords[lower - 1]
        return position < candidate.endMilliseconds ? candidate.wordID : nil
    }

    private func containingWord(
        in words: [TranscriptWord],
        offset: Int
    ) -> TranscriptWord? {
        var lower = 0
        var upper = words.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if words[middle].displayRange.startUTF8Byte <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return nil }
        let candidate = words[lower - 1]
        return offset < candidate.displayRange.endUTF8Byte ? candidate : nil
    }

    private func precedingTimedWord(
        in words: [DisplayTimedWord],
        offset: Int
    ) -> DisplayTimedWord? {
        var lower = 0
        var upper = words.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if words[middle].endUTF8Byte <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower > 0 ? words[lower - 1] : nil
    }

    private func followingTimedWord(
        in words: [DisplayTimedWord],
        offset: Int
    ) -> DisplayTimedWord? {
        var lower = 0
        var upper = words.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if words[middle].startUTF8Byte <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower < words.count ? words[lower] : nil
    }

    private func clamped(_ milliseconds: UInt64) -> UInt64 {
        min(milliseconds, canonicalAudioDurationMilliseconds)
    }
}
