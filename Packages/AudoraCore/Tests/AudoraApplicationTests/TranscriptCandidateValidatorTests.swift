@testable import AudoraApplication
import AudoraDomain
import Foundation
import XCTest

final class TranscriptCandidateValidatorTests: XCTestCase {
    func testValidCandidatePromotesCompleteImmutableRevisionAndLeavesPunctuationInDisplayText() throws {
        let fixture = try TranscriptCandidateFixture()

        let revision = try TranscriptCandidateValidator().validate(
            fixture.candidate,
            against: fixture.context
        )

        XCTAssertEqual(revision.revisionID, fixture.context.revisionID)
        XCTAssertEqual(revision.sessionID, fixture.context.sessionID)
        XCTAssertEqual(revision.lines.map(\.lineID.rawValue), ["l000000", "l000001"])
        XCTAssertEqual(
            revision.lines.flatMap(\.words).map(\.wordID.rawValue),
            ["w000000", "w000001", "w000002", "w000003"]
        )
        XCTAssertEqual(revision.lines[0].text, "Hello, wörld.")
        XCTAssertEqual(revision.lines[0].words.map(\.text), ["Hello", "wörld"])
        XCTAssertFalse(revision.lines.flatMap(\.words).contains { $0.text == "," || $0.text == "." })
        XCTAssertEqual(revision.audioEvents.map(\.audioEventID.rawValue), ["a000000"])
    }

    func testUTF8DisplayRangeMustSelectExactWordBytes() throws {
        let fixture = try TranscriptCandidateFixture()
        let malformed = fixture.candidate.replacingWord(
            lineIndex: 0,
            wordIndex: 1,
            displayRange: CandidateLineTextRange(startUTF8Byte: 7, endUTF8Byte: 9)
        )

        XCTAssertThrowsError(
            try TranscriptCandidateValidator().validate(malformed, against: fixture.context)
        ) { error in
            XCTAssertEqual(error as? TranscriptCandidateValidationError, .invalidTextMapping)
        }
    }

    func testPunctuationOnlyCandidateTokenIsNeverPromotedAsWord() throws {
        let fixture = try TranscriptCandidateFixture()
        let malformed = fixture.candidate.replacingWord(
            lineIndex: 0,
            wordIndex: 0,
            text: ",",
            displayRange: CandidateLineTextRange(startUTF8Byte: 5, endUTF8Byte: 6)
        )

        XCTAssertThrowsError(
            try TranscriptCandidateValidator().validate(malformed, against: fixture.context)
        ) { error in
            XCTAssertEqual(error as? TranscriptCandidateValidationError, .punctuationIsNotAWord)
        }
    }

    func testWordTextRejectsDisplayPunctuationAndWhitespaceButKeepsLexicalMarks() throws {
        let fixture = try TranscriptCandidateFixture()
        for invalid in ["Hello,", "(Hello)", "Hello world", "Hello "] {
            assertRejected(
                fixture.candidate.replacingWord(
                    lineIndex: 0,
                    wordIndex: 0,
                    text: invalid
                ),
                against: fixture.context,
                as: .punctuationIsNotAWord
            )
        }

        let lexicalMarks = fixture.candidate.replacingLines([
            CandidateTranscriptLine(
                lineID: "l000000",
                order: 0,
                audioSourceID: "src-0001",
                timeRange: CandidateSessionTimeRange(
                    startMilliseconds: 0,
                    endMilliseconds: 1_000
                ),
                text: "can't, mother-in-law p-.",
                words: [
                    CandidateTranscriptWord(
                        wordID: "w000000",
                        ordinal: 0,
                        text: "can't",
                        displayRange: CandidateLineTextRange(
                            startUTF8Byte: 0,
                            endUTF8Byte: 5
                        ),
                        timeRange: CandidateSessionTimeRange(
                            startMilliseconds: 100,
                            endMilliseconds: 300
                        ),
                        confidence: 0.9,
                        wordKind: .lexical
                    ),
                    CandidateTranscriptWord(
                        wordID: "w000001",
                        ordinal: 1,
                        text: "mother-in-law",
                        displayRange: CandidateLineTextRange(
                            startUTF8Byte: 7,
                            endUTF8Byte: 20
                        ),
                        timeRange: CandidateSessionTimeRange(
                            startMilliseconds: 400,
                            endMilliseconds: 700
                        ),
                        confidence: 0.9,
                        wordKind: .lexical
                    ),
                    CandidateTranscriptWord(
                        wordID: "w000002",
                        ordinal: 2,
                        text: "p-",
                        displayRange: CandidateLineTextRange(
                            startUTF8Byte: 21,
                            endUTF8Byte: 23
                        ),
                        timeRange: CandidateSessionTimeRange(
                            startMilliseconds: 800,
                            endMilliseconds: 900
                        ),
                        confidence: 0.9,
                        wordKind: .partialWord
                    ),
                ]
            ),
        ]).replacingAudioEvents([])
        let context = fixture.context.replacingVoicedRanges([
            try SessionTimeRange(
                startMilliseconds: 100,
                endMilliseconds: 900,
                sessionDurationMilliseconds: 12_000
            ),
        ])

        let revision = try TranscriptCandidateValidator().validate(
            lexicalMarks,
            against: context
        )
        XCTAssertEqual(revision.lines[0].words.map(\.text), ["can't", "mother-in-law", "p-"])
    }

    func testImmediateRepetitionIsPreservedButPathologicalLoopIsRejected() throws {
        let fixture = try TranscriptCandidateFixture()

        XCTAssertNoThrow(
            try TranscriptCandidateValidator().validate(fixture.candidate, against: fixture.context)
        )

        let loop = fixture.candidate.replacingLines([
            CandidateTranscriptLine(
                lineID: "l000000",
                order: 0,
                audioSourceID: "src-0001",
                timeRange: CandidateSessionTimeRange(startMilliseconds: 100, endMilliseconds: 6_600),
                text: "go go go go go go go go go",
                words: (0..<9).map { index in
                    let start = index * 3
                    return CandidateTranscriptWord(
                        wordID: String(format: "w%06d", index),
                        ordinal: index,
                        text: "go",
                        displayRange: CandidateLineTextRange(
                            startUTF8Byte: start,
                            endUTF8Byte: start + 2
                        ),
                        timeRange: CandidateSessionTimeRange(
                            startMilliseconds: 100 + UInt64(index * 500),
                            endMilliseconds: 400 + UInt64(index * 500)
                        ),
                        confidence: 0.9,
                        wordKind: .lexical
                    )
                }
            ),
        ])

        XCTAssertThrowsError(
            try TranscriptCandidateValidator().validate(loop, against: fixture.context)
        ) { error in
            XCTAssertEqual(error as? TranscriptCandidateValidationError, .pathologicalRepetition)
        }
    }

    func testPathologicalRepeatedSentenceIsRejectedBeyondThreeWordNGrams() throws {
        let fixture = try TranscriptCandidateFixture()
        let tokens = Array(repeating: ["one", "two", "three", "four"], count: 9)
            .flatMap { $0 }
        var cursor = 0
        let words = tokens.enumerated().map { index, token in
            let start = cursor
            cursor += token.utf8.count + 1
            return CandidateTranscriptWord(
                wordID: String(format: "w%06d", index),
                ordinal: index,
                text: token,
                displayRange: CandidateLineTextRange(
                    startUTF8Byte: start,
                    endUTF8Byte: start + token.utf8.count
                ),
                timeRange: CandidateSessionTimeRange(
                    startMilliseconds: 100 + UInt64(index * 100),
                    endMilliseconds: 150 + UInt64(index * 100)
                ),
                confidence: 0.9,
                wordKind: .lexical
            )
        }
        let loop = fixture.candidate.replacingLines([
            CandidateTranscriptLine(
                lineID: "l000000",
                order: 0,
                audioSourceID: "src-0001",
                timeRange: CandidateSessionTimeRange(
                    startMilliseconds: 0,
                    endMilliseconds: 4_000
                ),
                text: tokens.joined(separator: " "),
                words: words
            ),
        ])

        assertRejected(loop, against: fixture.context, as: .pathologicalRepetition)
    }

    func testPathologicalRepeatedPhraseHasNoMaximumDetectableWidth() throws {
        let fixture = try TranscriptCandidateFixture()
        let phrase = (0..<33).map { String(format: "word%03d", $0) }
        let tokens = Array(repeating: phrase, count: 9).flatMap { $0 }
        var cursor = 0
        let words = tokens.enumerated().map { index, token in
            let start = cursor
            cursor += token.utf8.count + 1
            return CandidateTranscriptWord(
                wordID: String(format: "w%06d", index),
                ordinal: index,
                text: token,
                displayRange: CandidateLineTextRange(
                    startUTF8Byte: start,
                    endUTF8Byte: start + token.utf8.count
                ),
                timeRange: CandidateSessionTimeRange(
                    startMilliseconds: 100 + UInt64(index * 30),
                    endMilliseconds: 120 + UInt64(index * 30)
                ),
                confidence: 0.9,
                wordKind: .lexical
            )
        }
        let loop = fixture.candidate.replacingLines([
            CandidateTranscriptLine(
                lineID: "l000000",
                order: 0,
                audioSourceID: "src-0001",
                timeRange: CandidateSessionTimeRange(
                    startMilliseconds: 0,
                    endMilliseconds: 10_000
                ),
                text: tokens.joined(separator: " "),
                words: words
            ),
        ])

        assertRejected(loop, against: fixture.context, as: .pathologicalRepetition)
    }

    func testLargeNonrepeatingTranscriptDoesNotTripRepetitionGuard() {
        let words = (0..<25_000).map { "unique\($0)" }

        XCTAssertFalse(
            TranscriptRepetitionValidator.isPathological(
                words: words,
                maximumConsecutiveOccurrences: 8
            )
        )
    }

    func testSourceFingerprintsMustBeAUniqueExactIdentityAndHashSet() throws {
        let fixture = try TranscriptCandidateFixture()
        let secondSource = try AudioSourceID("src-0002")
        let secondFingerprint = try AudioFingerprint(
            sha256: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        )
        let context = TranscriptPublicationContext(
            jobID: fixture.context.jobID,
            sessionID: fixture.context.sessionID,
            revisionID: fixture.context.revisionID,
            createdAt: fixture.context.createdAt,
            durationMilliseconds: fixture.context.durationMilliseconds,
            audioFingerprint: fixture.context.audioFingerprint,
            sourceFingerprints: fixture.context.sourceFingerprints + [
                TranscriptSourceFingerprint(
                    audioSourceID: secondSource,
                    fingerprint: secondFingerprint
                ),
            ],
            verifiedCandidateArtifactFingerprint:
                fixture.context.verifiedCandidateArtifactFingerprint,
            engine: fixture.context.engine,
            voicedRanges: fixture.context.voicedRanges
        )
        let first = fixture.candidate.sourceFingerprints[0]
        let duplicated = fixture.candidate.replacingSourceFingerprints([first, first])

        XCTAssertThrowsError(
            try TranscriptCandidateValidator().validate(duplicated, against: context)
        ) { error in
            XCTAssertEqual(error as? TranscriptCandidateValidationError, .integrityMismatch)
        }

        let duplicateTrustedContext = TranscriptPublicationContext(
            jobID: fixture.context.jobID,
            sessionID: fixture.context.sessionID,
            revisionID: fixture.context.revisionID,
            createdAt: fixture.context.createdAt,
            durationMilliseconds: fixture.context.durationMilliseconds,
            audioFingerprint: fixture.context.audioFingerprint,
            sourceFingerprints: [
                fixture.context.sourceFingerprints[0],
                fixture.context.sourceFingerprints[0],
            ],
            verifiedCandidateArtifactFingerprint:
                fixture.context.verifiedCandidateArtifactFingerprint,
            engine: fixture.context.engine,
            voicedRanges: fixture.context.voicedRanges
        )
        XCTAssertThrowsError(
            try TranscriptCandidateValidator().validate(duplicated, against: duplicateTrustedContext)
        ) { error in
            XCTAssertEqual(error as? TranscriptCandidateValidationError, .integrityMismatch)
        }
    }

    func testIdentityIntegrityAndEngineClaimsMustMatchTrustedContextExactly() throws {
        let fixture = try TranscriptCandidateFixture()
        let identityCases = [
            fixture.candidate.replacingIdentity(jobID: "job-wrong"),
            fixture.candidate.replacingIdentity(sessionID: "ses-wrong"),
            fixture.candidate.replacingIdentity(revisionID: "trv-wrong"),
        ]
        for candidate in identityCases {
            assertRejected(candidate, against: fixture.context, as: .identityMismatch)
        }

        assertRejected(
            fixture.candidate.replacingIntegrity(audioSHA256: String(repeating: "d", count: 64)),
            against: fixture.context,
            as: .integrityMismatch
        )
        assertRejected(
            fixture.candidate.replacingIntegrity(
                candidateArtifactSHA256: String(repeating: "d", count: 64)
            ),
            against: fixture.context,
            as: .integrityMismatch
        )
        assertRejected(
            fixture.candidate.replacingEngine(provider: "unexpected-provider"),
            against: fixture.context,
            as: .engineMismatch
        )
    }

    func testLineWordTimingConfidenceAndAudioEventOrderingAreValidated() throws {
        let fixture = try TranscriptCandidateFixture()
        var reorderedLines = fixture.candidate.lines
        let second = reorderedLines[1]
        reorderedLines[1] = CandidateTranscriptLine(
            lineID: second.lineID,
            order: 0,
            audioSourceID: second.audioSourceID,
            timeRange: second.timeRange,
            text: second.text,
            words: second.words
        )
        assertRejected(
            fixture.candidate.replacingLines(reorderedLines),
            against: fixture.context,
            as: .invalidLineOrdering
        )
        assertRejected(
            fixture.candidate.replacingWordIdentity(
                lineIndex: 0,
                wordIndex: 0,
                wordID: "w000001",
                ordinal: 1
            ),
            against: fixture.context,
            as: .invalidWordOrdering
        )
        assertRejected(
            fixture.candidate.replacingWordTimeRange(
                lineIndex: 0,
                wordIndex: 0,
                CandidateSessionTimeRange(startMilliseconds: 100, endMilliseconds: 1_600)
            ),
            against: fixture.context,
            as: .invalidTiming
        )
        assertRejected(
            fixture.candidate.replacingWordConfidence(
                lineIndex: 0,
                wordIndex: 0,
                .infinity
            ),
            against: fixture.context,
            as: .invalidConfidence
        )
        let event = fixture.candidate.audioEvents[0]
        assertRejected(
            fixture.candidate.replacingAudioEvents([
                CandidateTranscriptAudioEvent(
                    audioEventID: "a000001",
                    category: event.category,
                    audioSourceID: event.audioSourceID,
                    timeRange: event.timeRange
                ),
            ]),
            against: fixture.context,
            as: .invalidAudioEvent
        )
    }

    func testDisplayTextCannotHideLexicalContentBetweenCanonicalWords() throws {
        let fixture = try TranscriptCandidateFixture()
        let first = fixture.candidate.lines[0]
        let words = [
            first.words[0],
            CandidateTranscriptWord(
                wordID: first.words[1].wordID,
                ordinal: first.words[1].ordinal,
                text: first.words[1].text,
                displayRange: CandidateLineTextRange(startUTF8Byte: 14, endUTF8Byte: 20),
                timeRange: first.words[1].timeRange,
                confidence: first.words[1].confidence,
                wordKind: first.words[1].wordKind
            ),
        ]
        var lines = fixture.candidate.lines
        lines[0] = CandidateTranscriptLine(
            lineID: first.lineID,
            order: first.order,
            audioSourceID: first.audioSourceID,
            timeRange: first.timeRange,
            text: "Hello, hidden wörld.",
            words: words
        )

        assertRejected(
            fixture.candidate.replacingLines(lines),
            against: fixture.context,
            as: .invalidTextMapping
        )
    }

    func testEveryVoicedIntervalRejectsAnUncoveredInteriorGap() throws {
        let fixture = try TranscriptCandidateFixture()
        let context = fixture.context.replacingVoicedRanges([
            try SessionTimeRange(
                startMilliseconds: 100,
                endMilliseconds: 6_500,
                sessionDurationMilliseconds: 12_000
            ),
        ])

        assertRejected(
            fixture.candidate,
            against: context,
            as: .insufficientCoverage
        )

        let shortUncoveredContext = fixture.context.replacingVoicedRanges([
            try SessionTimeRange(
                startMilliseconds: 1_600,
                endMilliseconds: 1_800,
                sessionDurationMilliseconds: 12_000
            ),
        ])
        assertRejected(
            fixture.candidate,
            against: shortUncoveredContext,
            as: .insufficientCoverage
        )
    }

    func testExplicitlyUntimedWordsRemainValidWhenVoicedCoverageIsExplicit() throws {
        let fixture = try TranscriptCandidateFixture()
        let untimed = fixture.candidate.replacingAllWordTimeRanges(nil)
            .replacingAudioEvents([
                CandidateTranscriptAudioEvent(
                    audioEventID: "a000000",
                    category: .untranscribedVoicedInterval,
                    audioSourceID: "src-0001",
                    timeRange: CandidateSessionTimeRange(
                        startMilliseconds: 100,
                        endMilliseconds: 6_500
                    )
                ),
            ])

        let revision = try TranscriptCandidateValidator().validate(
            untimed,
            against: fixture.context
        )
        XCTAssertTrue(revision.lines.flatMap(\.words).allSatisfy { $0.timeRange == nil })
    }

    func testImplausibleWordCountCollapseIsRejectedAgainstVoicedDuration() throws {
        let fixture = try TranscriptCandidateFixture()
        let policy = TranscriptValidationPolicy(
            maximumLines: 100_000,
            maximumWords: 1_000_000,
            maximumAudioEvents: 100_000,
            maximumAggregateTextUTF8Bytes:
                TranscriptRevisionLimits.maximumAggregateTextUTF8Bytes,
            maximumCoverageEdgeGapMilliseconds: 2_000,
            maximumVoicedMillisecondsPerWord: 500,
            maximumConsecutiveNGramOccurrences: 8
        )

        XCTAssertThrowsError(
            try TranscriptCandidateValidator(policy: policy).validate(
                fixture.candidate,
                against: fixture.context
            )
        ) { error in
            XCTAssertEqual(error as? TranscriptCandidateValidationError, .wordCountCollapse)
        }
    }

    func testPerFieldAndAggregateTranscriptTextBudgetsRejectPathologicalInput() throws {
        let fixture = try TranscriptCandidateFixture()
        var oversizedLine = fixture.candidate.lines
        let first = oversizedLine[0]
        oversizedLine[0] = CandidateTranscriptLine(
            lineID: first.lineID,
            order: first.order,
            audioSourceID: first.audioSourceID,
            timeRange: first.timeRange,
            text: String(
                repeating: "a",
                count: TranscriptRevisionLimits.maximumLineUTF8Bytes + 1
            ),
            words: first.words
        )
        assertRejected(
            fixture.candidate.replacingLines(oversizedLine),
            against: fixture.context,
            as: .pathologicalSize
        )
        assertRejected(
            fixture.candidate.replacingWord(
                lineIndex: 0,
                wordIndex: 0,
                text: String(
                    repeating: "a",
                    count: TranscriptRevisionLimits.maximumWordUTF8Bytes + 1
                )
            ),
            against: fixture.context,
            as: .pathologicalSize
        )

        let aggregatePolicy = TranscriptValidationPolicy(
            maximumLines: 100_000,
            maximumWords: 1_000_000,
            maximumAudioEvents: 100_000,
            maximumAggregateTextUTF8Bytes: 16,
            maximumCoverageEdgeGapMilliseconds: 2_000,
            maximumVoicedMillisecondsPerWord: 15_000,
            maximumConsecutiveNGramOccurrences: 8
        )
        XCTAssertThrowsError(
            try TranscriptCandidateValidator(policy: aggregatePolicy).validate(
                fixture.candidate,
                against: fixture.context
            )
        ) { error in
            XCTAssertEqual(error as? TranscriptCandidateValidationError, .pathologicalSize)
        }

        let wordCountPolicy = TranscriptValidationPolicy(
            maximumLines: 100_000,
            maximumWords: 3,
            maximumAudioEvents: 100_000,
            maximumAggregateTextUTF8Bytes:
                TranscriptRevisionLimits.maximumAggregateTextUTF8Bytes,
            maximumCoverageEdgeGapMilliseconds: 2_000,
            maximumVoicedMillisecondsPerWord: 15_000,
            maximumConsecutiveNGramOccurrences: 8
        )
        XCTAssertThrowsError(
            try TranscriptCandidateValidator(policy: wordCountPolicy).validate(
                fixture.candidate,
                against: fixture.context
            )
        ) { error in
            XCTAssertEqual(error as? TranscriptCandidateValidationError, .pathologicalSize)
        }
    }

    func testInvalidInjectedValidationPolicyFailsWithoutArithmeticTrap() throws {
        let fixture = try TranscriptCandidateFixture()
        let invalidZeroes = TranscriptValidationPolicy(
            maximumLines: 0,
            maximumWords: 0,
            maximumAudioEvents: -1,
            maximumAggregateTextUTF8Bytes: 0,
            maximumCoverageEdgeGapMilliseconds: 0,
            maximumVoicedMillisecondsPerWord: 0,
            maximumConsecutiveNGramOccurrences: 0
        )

        let invalidOverflowingBounds = TranscriptValidationPolicy(
            maximumLines: 1,
            maximumWords: 1,
            maximumAudioEvents: 0,
            maximumAggregateTextUTF8Bytes: 1,
            maximumCoverageEdgeGapMilliseconds: .max,
            maximumVoicedMillisecondsPerWord: .max,
            maximumConsecutiveNGramOccurrences: 1
        )

        for invalid in [invalidZeroes, invalidOverflowingBounds] {
            XCTAssertThrowsError(
                try TranscriptCandidateValidator(policy: invalid).validate(
                    fixture.candidate,
                    against: fixture.context
                )
            ) { error in
                XCTAssertEqual(error as? TranscriptCandidateValidationError, .invalidPolicy)
            }
        }
    }

    private func assertRejected(
        _ candidate: TranscriptionCandidate,
        against context: TranscriptPublicationContext,
        as expected: TranscriptCandidateValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try TranscriptCandidateValidator().validate(candidate, against: context),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? TranscriptCandidateValidationError,
                expected,
                file: file,
                line: line
            )
        }
    }
}

struct TranscriptCandidateFixture {
    let context: TranscriptPublicationContext
    let candidate: TranscriptionCandidate

    init() throws {
        let sessionID = try SessionID("ses-20260830T120000000Z-3DEF")
        let revisionID = try TranscriptRevisionID("trv-20260830T121000000Z-4FGH")
        let jobID = try TranscriptionJobID("job-20260830T120500000Z-5GHJ")
        let audioFingerprint = try AudioFingerprint(
            sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
        let artifactFingerprint = try AudioFingerprint(
            sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        )
        let usePolicy = try EngineUsePolicy(
            policyID: "crisper-evaluation-v1",
            coveredArtifacts: [.transcriptRevision],
            privateLocalUseAllowed: true,
            privateExportAllowed: true,
            externalProcessingAllowed: false,
            publicDistributionAllowed: false,
            commercialUseAllowed: false,
            licenseReference: "pinned-license-reference",
            licenseSHA256: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        )
        let qualification = try TranscriptEngineQualification(
            qualificationProfileID: "synthetic-qualified-v1",
            engineLockSHA256: String(repeating: "f", count: 64),
            runtimeIdentity: "synthetic-runtime-v1",
            runtimeLockSHA256: String(repeating: "d", count: 64),
            compatibilityPatchID: "synthetic-progress-patch-v1"
        )
        let engine = try TranscriptEngineProvenance(
            provider: "crisperwhisper",
            model: "small",
            revision: "pinned-revision",
            language: "en",
            mode: "verbatim",
            decodingOptionsSHA256: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            qualification: qualification,
            usePolicy: usePolicy
        )
        context = TranscriptPublicationContext(
            jobID: jobID,
            sessionID: sessionID,
            revisionID: revisionID,
            createdAt: try UTCInstant("2026-08-30T12:10:00.000Z"),
            durationMilliseconds: 12_000,
            audioFingerprint: audioFingerprint,
            sourceFingerprints: [
                TranscriptSourceFingerprint(
                    audioSourceID: .microphone,
                    fingerprint: audioFingerprint
                ),
            ],
            verifiedCandidateArtifactFingerprint: artifactFingerprint,
            engine: engine,
            voicedRanges: [
                try SessionTimeRange(
                    startMilliseconds: 100,
                    endMilliseconds: 1_400,
                    sessionDurationMilliseconds: 12_000
                ),
                try SessionTimeRange(
                    startMilliseconds: 5_000,
                    endMilliseconds: 6_500,
                    sessionDurationMilliseconds: 12_000
                ),
            ]
        )
        candidate = TranscriptionCandidate(
            schemaVersion: 1,
            jobID: jobID.rawValue,
            sessionID: sessionID.rawValue,
            revisionID: revisionID.rawValue,
            durationMilliseconds: 12_000,
            audioFingerprintSHA256: audioFingerprint.sha256,
            sourceFingerprints: [
                CandidateTranscriptSourceFingerprint(
                    audioSourceID: "src-0001",
                    sha256: audioFingerprint.sha256
                ),
            ],
            candidateArtifactSHA256: artifactFingerprint.sha256,
            engine: CandidateTranscriptEngineProvenance(
                provider: engine.provider,
                model: engine.model,
                revision: engine.revision,
                language: engine.language,
                mode: engine.mode,
                decodingOptionsSHA256: engine.decodingOptionsSHA256,
                qualification: CandidateTranscriptEngineQualification(
                    schemaVersion: TranscriptEngineQualification.schemaVersion,
                    qualificationProfileID: qualification.qualificationProfileID,
                    engineLockSHA256: qualification.engineLockSHA256,
                    runtimeIdentity: qualification.runtimeIdentity,
                    runtimeLockSHA256: qualification.runtimeLockSHA256,
                    compatibilityPatchID: qualification.compatibilityPatchID
                )
            ),
            lines: [
                CandidateTranscriptLine(
                    lineID: "l000000",
                    order: 0,
                    audioSourceID: "src-0001",
                    timeRange: CandidateSessionTimeRange(
                        startMilliseconds: 0,
                        endMilliseconds: 1_500
                    ),
                    text: "Hello, wörld.",
                    words: [
                        CandidateTranscriptWord(
                            wordID: "w000000",
                            ordinal: 0,
                            text: "Hello",
                            displayRange: CandidateLineTextRange(
                                startUTF8Byte: 0,
                                endUTF8Byte: 5
                            ),
                            timeRange: CandidateSessionTimeRange(
                                startMilliseconds: 100,
                                endMilliseconds: 500
                            ),
                            confidence: 0.98,
                            wordKind: .lexical
                        ),
                        CandidateTranscriptWord(
                            wordID: "w000001",
                            ordinal: 1,
                            text: "wörld",
                            displayRange: CandidateLineTextRange(
                                startUTF8Byte: 7,
                                endUTF8Byte: 13
                            ),
                            timeRange: CandidateSessionTimeRange(
                                startMilliseconds: 600,
                                endMilliseconds: 1_200
                            ),
                            confidence: 0.97,
                            wordKind: .lexical
                        ),
                    ]
                ),
                CandidateTranscriptLine(
                    lineID: "l000001",
                    order: 1,
                    audioSourceID: "src-0001",
                    timeRange: CandidateSessionTimeRange(
                        startMilliseconds: 4_900,
                        endMilliseconds: 6_600
                    ),
                    text: "Go go.",
                    words: [
                        CandidateTranscriptWord(
                            wordID: "w000002",
                            ordinal: 2,
                            text: "Go",
                            displayRange: CandidateLineTextRange(
                                startUTF8Byte: 0,
                                endUTF8Byte: 2
                            ),
                            timeRange: CandidateSessionTimeRange(
                                startMilliseconds: 5_000,
                                endMilliseconds: 5_300
                            ),
                            confidence: 0.96,
                            wordKind: .lexical
                        ),
                        CandidateTranscriptWord(
                            wordID: "w000003",
                            ordinal: 3,
                            text: "go",
                            displayRange: CandidateLineTextRange(
                                startUTF8Byte: 3,
                                endUTF8Byte: 5
                            ),
                            timeRange: CandidateSessionTimeRange(
                                startMilliseconds: 5_400,
                                endMilliseconds: 5_700
                            ),
                            confidence: 0.95,
                            wordKind: .lexical
                        ),
                    ]
                ),
            ],
            audioEvents: [
                CandidateTranscriptAudioEvent(
                    audioEventID: "a000000",
                    category: .silentPause,
                    audioSourceID: "src-0001",
                    timeRange: CandidateSessionTimeRange(
                        startMilliseconds: 1_500,
                        endMilliseconds: 4_900
                    )
                ),
            ]
        )
    }
}

extension TranscriptionCandidate {
    func replacingIdentity(
        jobID: String? = nil,
        sessionID: String? = nil,
        revisionID: String? = nil
    ) -> Self {
        Self(
            schemaVersion: schemaVersion,
            jobID: jobID ?? self.jobID,
            sessionID: sessionID ?? self.sessionID,
            revisionID: revisionID ?? self.revisionID,
            durationMilliseconds: durationMilliseconds,
            audioFingerprintSHA256: audioFingerprintSHA256,
            sourceFingerprints: sourceFingerprints,
            candidateArtifactSHA256: candidateArtifactSHA256,
            engine: engine,
            lines: lines,
            audioEvents: audioEvents
        )
    }

    func replacingIntegrity(
        audioSHA256: String? = nil,
        candidateArtifactSHA256: String? = nil
    ) -> Self {
        Self(
            schemaVersion: schemaVersion,
            jobID: jobID,
            sessionID: sessionID,
            revisionID: revisionID,
            durationMilliseconds: durationMilliseconds,
            audioFingerprintSHA256: audioSHA256 ?? audioFingerprintSHA256,
            sourceFingerprints: sourceFingerprints,
            candidateArtifactSHA256: candidateArtifactSHA256 ?? self.candidateArtifactSHA256,
            engine: engine,
            lines: lines,
            audioEvents: audioEvents
        )
    }

    func replacingEngine(provider: String) -> Self {
        Self(
            schemaVersion: schemaVersion,
            jobID: jobID,
            sessionID: sessionID,
            revisionID: revisionID,
            durationMilliseconds: durationMilliseconds,
            audioFingerprintSHA256: audioFingerprintSHA256,
            sourceFingerprints: sourceFingerprints,
            candidateArtifactSHA256: candidateArtifactSHA256,
            engine: CandidateTranscriptEngineProvenance(
                provider: provider,
                model: engine.model,
                revision: engine.revision,
                language: engine.language,
                mode: engine.mode,
                decodingOptionsSHA256: engine.decodingOptionsSHA256,
                qualification: engine.qualification
            ),
            lines: lines,
            audioEvents: audioEvents
        )
    }

    func replacingAudioEvents(_ audioEvents: [CandidateTranscriptAudioEvent]) -> Self {
        Self(
            schemaVersion: schemaVersion,
            jobID: jobID,
            sessionID: sessionID,
            revisionID: revisionID,
            durationMilliseconds: durationMilliseconds,
            audioFingerprintSHA256: audioFingerprintSHA256,
            sourceFingerprints: sourceFingerprints,
            candidateArtifactSHA256: candidateArtifactSHA256,
            engine: engine,
            lines: lines,
            audioEvents: audioEvents
        )
    }

    func replacingLines(_ lines: [CandidateTranscriptLine]) -> Self {
        Self(
            schemaVersion: schemaVersion,
            jobID: jobID,
            sessionID: sessionID,
            revisionID: revisionID,
            durationMilliseconds: durationMilliseconds,
            audioFingerprintSHA256: audioFingerprintSHA256,
            sourceFingerprints: sourceFingerprints,
            candidateArtifactSHA256: candidateArtifactSHA256,
            engine: engine,
            lines: lines,
            audioEvents: audioEvents
        )
    }

    func replacingSourceFingerprints(
        _ sourceFingerprints: [CandidateTranscriptSourceFingerprint]
    ) -> Self {
        Self(
            schemaVersion: schemaVersion,
            jobID: jobID,
            sessionID: sessionID,
            revisionID: revisionID,
            durationMilliseconds: durationMilliseconds,
            audioFingerprintSHA256: audioFingerprintSHA256,
            sourceFingerprints: sourceFingerprints,
            candidateArtifactSHA256: candidateArtifactSHA256,
            engine: engine,
            lines: lines,
            audioEvents: audioEvents
        )
    }

    func replacingWord(
        lineIndex: Int,
        wordIndex: Int,
        text: String? = nil,
        displayRange: CandidateLineTextRange? = nil
    ) -> Self {
        var changedLines = lines
        var changedWords = changedLines[lineIndex].words
        let old = changedWords[wordIndex]
        changedWords[wordIndex] = CandidateTranscriptWord(
            wordID: old.wordID,
            ordinal: old.ordinal,
            text: text ?? old.text,
            displayRange: displayRange ?? old.displayRange,
            timeRange: old.timeRange,
            confidence: old.confidence,
            wordKind: old.wordKind
        )
        let line = changedLines[lineIndex]
        changedLines[lineIndex] = CandidateTranscriptLine(
            lineID: line.lineID,
            order: line.order,
            audioSourceID: line.audioSourceID,
            timeRange: line.timeRange,
            text: line.text,
            words: changedWords
        )
        return replacingLines(changedLines)
    }

    func replacingWordIdentity(
        lineIndex: Int,
        wordIndex: Int,
        wordID: String,
        ordinal: Int
    ) -> Self {
        replacingWordValue(lineIndex: lineIndex, wordIndex: wordIndex) { old in
            CandidateTranscriptWord(
                wordID: wordID,
                ordinal: ordinal,
                text: old.text,
                displayRange: old.displayRange,
                timeRange: old.timeRange,
                confidence: old.confidence,
                wordKind: old.wordKind
            )
        }
    }

    func replacingWordTimeRange(
        lineIndex: Int,
        wordIndex: Int,
        _ timeRange: CandidateSessionTimeRange?
    ) -> Self {
        replacingWordValue(lineIndex: lineIndex, wordIndex: wordIndex) { old in
            CandidateTranscriptWord(
                wordID: old.wordID,
                ordinal: old.ordinal,
                text: old.text,
                displayRange: old.displayRange,
                timeRange: timeRange,
                confidence: old.confidence,
                wordKind: old.wordKind
            )
        }
    }

    func replacingWordConfidence(
        lineIndex: Int,
        wordIndex: Int,
        _ confidence: Double?
    ) -> Self {
        replacingWordValue(lineIndex: lineIndex, wordIndex: wordIndex) { old in
            CandidateTranscriptWord(
                wordID: old.wordID,
                ordinal: old.ordinal,
                text: old.text,
                displayRange: old.displayRange,
                timeRange: old.timeRange,
                confidence: confidence,
                wordKind: old.wordKind
            )
        }
    }

    func replacingAllWordTimeRanges(_ timeRange: CandidateSessionTimeRange?) -> Self {
        replacingLines(lines.map { line in
            CandidateTranscriptLine(
                lineID: line.lineID,
                order: line.order,
                audioSourceID: line.audioSourceID,
                timeRange: line.timeRange,
                text: line.text,
                words: line.words.map { word in
                    CandidateTranscriptWord(
                        wordID: word.wordID,
                        ordinal: word.ordinal,
                        text: word.text,
                        displayRange: word.displayRange,
                        timeRange: timeRange,
                        confidence: word.confidence,
                        wordKind: word.wordKind
                    )
                }
            )
        })
    }

    private func replacingWordValue(
        lineIndex: Int,
        wordIndex: Int,
        _ transform: (CandidateTranscriptWord) -> CandidateTranscriptWord
    ) -> Self {
        var changedLines = lines
        var words = changedLines[lineIndex].words
        words[wordIndex] = transform(words[wordIndex])
        let line = changedLines[lineIndex]
        changedLines[lineIndex] = CandidateTranscriptLine(
            lineID: line.lineID,
            order: line.order,
            audioSourceID: line.audioSourceID,
            timeRange: line.timeRange,
            text: line.text,
            words: words
        )
        return replacingLines(changedLines)
    }
}

private extension TranscriptPublicationContext {
    func replacingVoicedRanges(_ voicedRanges: [SessionTimeRange]) -> Self {
        Self(
            jobID: jobID,
            sessionID: sessionID,
            revisionID: revisionID,
            createdAt: createdAt,
            durationMilliseconds: durationMilliseconds,
            audioFingerprint: audioFingerprint,
            sourceFingerprints: sourceFingerprints,
            verifiedCandidateArtifactFingerprint: verifiedCandidateArtifactFingerprint,
            engine: engine,
            voicedRanges: voicedRanges
        )
    }
}
