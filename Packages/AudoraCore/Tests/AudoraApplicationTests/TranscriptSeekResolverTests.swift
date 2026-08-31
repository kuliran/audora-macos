@testable import AudoraApplication
import AudoraDomain
import XCTest

final class TranscriptSeekResolverTests: XCTestCase {
    func testUTF8PunctuationUsesPreviousThenFollowingTimedWord() throws {
        let text = "— Привет, мир!"
        let hello = try word(
            id: "w000000",
            ordinal: 0,
            text: "Привет",
            in: text,
            time: (120, 300)
        )
        let world = try word(
            id: "w000001",
            ordinal: 1,
            text: "мир",
            in: text,
            time: (420, 600)
        )
        let line = try transcriptLine(
            text: text,
            words: [hello, world],
            time: (80, 900)
        )
        let resolver = TranscriptSeekResolver(
            lines: [line],
            canonicalAudioDurationMilliseconds: 1_000
        )

        XCTAssertEqual(
            resolver.seekTime(
                lineID: line.lineID,
                utf8ByteOffset: utf8Offset(of: "—", in: text)
            ),
            120
        )
        XCTAssertEqual(
            resolver.seekTime(
                lineID: line.lineID,
                utf8ByteOffset: utf8Offset(of: ",", in: text)
            ),
            120
        )
        XCTAssertEqual(
            resolver.seekTime(
                lineID: line.lineID,
                utf8ByteOffset: utf8Offset(of: "!", in: text)
            ),
            420
        )
        XCTAssertEqual(
            resolver.seekTime(
                lineID: line.lineID,
                utf8ByteOffset: world.displayRange.startUTF8Byte
            ),
            420
        )
    }

    func testUntimedWordsAndAllUntimedPunctuationUseLineStart() throws {
        let text = "Well… okay?"
        let first = try word(
            id: "w000000",
            ordinal: 0,
            text: "Well",
            in: text,
            time: nil
        )
        let second = try word(
            id: "w000001",
            ordinal: 1,
            text: "okay",
            in: text,
            time: nil
        )
        let line = try transcriptLine(
            text: text,
            words: [first, second],
            time: (250, 900)
        )
        let resolver = TranscriptSeekResolver(
            lines: [line],
            canonicalAudioDurationMilliseconds: 1_000
        )

        XCTAssertEqual(
            resolver.seekTime(
                lineID: line.lineID,
                utf8ByteOffset: first.displayRange.startUTF8Byte
            ),
            250
        )
        XCTAssertEqual(
            resolver.seekTime(
                lineID: line.lineID,
                utf8ByteOffset: utf8Offset(of: "…", in: text)
            ),
            250
        )
        XCTAssertNil(resolver.activeWord(atMilliseconds: 500))
    }

    func testEveryResolvedSeekIsClampedToCanonicalAudioDuration() throws {
        let text = "Late."
        let late = try word(
            id: "w000000",
            ordinal: 0,
            text: "Late",
            in: text,
            time: (700, 900)
        )
        let line = try transcriptLine(
            text: text,
            words: [late],
            time: (650, 950)
        )
        let resolver = TranscriptSeekResolver(
            lines: [line],
            canonicalAudioDurationMilliseconds: 500
        )

        XCTAssertEqual(
            resolver.seekTime(
                lineID: line.lineID,
                utf8ByteOffset: late.displayRange.startUTF8Byte
            ),
            500
        )
        XCTAssertEqual(
            resolver.seekTime(
                lineID: line.lineID,
                utf8ByteOffset: utf8Offset(of: ".", in: text)
            ),
            500
        )
    }

    func testActiveWordLookupUsesHalfOpenTimedWordRanges() throws {
        let text = "One two"
        let first = try word(
            id: "w000000",
            ordinal: 0,
            text: "One",
            in: text,
            time: (100, 200)
        )
        let second = try word(
            id: "w000001",
            ordinal: 1,
            text: "two",
            in: text,
            time: (300, 450)
        )
        let resolver = TranscriptSeekResolver(
            lines: [try transcriptLine(text: text, words: [first, second], time: (50, 500))],
            canonicalAudioDurationMilliseconds: 500
        )

        XCTAssertNil(resolver.activeWord(atMilliseconds: 99))
        XCTAssertEqual(resolver.activeWord(atMilliseconds: 100), first.wordID)
        XCTAssertEqual(resolver.activeWord(atMilliseconds: 199), first.wordID)
        XCTAssertNil(resolver.activeWord(atMilliseconds: 200))
        XCTAssertEqual(resolver.activeWord(atMilliseconds: 300), second.wordID)
        XCTAssertNil(resolver.activeWord(atMilliseconds: 450))
    }
}

private func transcriptLine(
    text: String,
    words: [TranscriptWord],
    time: (UInt64, UInt64)
) throws -> TranscriptLine {
    TranscriptLine(
        lineID: try TranscriptLineID("l000000"),
        order: 0,
        audioSourceID: .microphone,
        timeRange: try SessionTimeRange(
            startMilliseconds: time.0,
            endMilliseconds: time.1,
            sessionDurationMilliseconds: 1_000
        ),
        text: text,
        words: words
    )
}

private func word(
    id: String,
    ordinal: Int,
    text wordText: String,
    in lineText: String,
    time: (UInt64, UInt64)?
) throws -> TranscriptWord {
    let start = utf8Offset(of: wordText, in: lineText)
    return TranscriptWord(
        wordID: try TranscriptWordID(id),
        ordinal: ordinal,
        text: wordText,
        displayRange: LineTextRange(
            startUTF8Byte: start,
            endUTF8Byte: start + wordText.utf8.count
        ),
        timeRange: try time.map {
            try SessionTimeRange(
                startMilliseconds: $0.0,
                endMilliseconds: $0.1,
                sessionDurationMilliseconds: 1_000
            )
        },
        confidence: nil,
        wordKind: .lexical
    )
}

private func utf8Offset(of needle: String, in haystack: String) -> Int {
    let range = haystack.range(of: needle)!
    return haystack[..<range.lowerBound].utf8.count
}
