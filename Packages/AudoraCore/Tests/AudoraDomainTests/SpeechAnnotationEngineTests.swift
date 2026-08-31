import AudoraDomain
import XCTest

final class SpeechAnnotationEngineTests: XCTestCase {
    func testV1RepetitionNormalizationTrimsOnlySurroundingPunctuation() {
        XCTAssertEqual(
            DeterministicSpeechAnnotator.normalizeRepetitionToken("U.S."),
            "u.s"
        )
        XCTAssertEqual(
            DeterministicSpeechAnnotator.normalizeRepetitionToken("us"),
            "us"
        )
        XCTAssertEqual(
            DeterministicSpeechAnnotator.normalizeRepetitionToken("-go"),
            "go"
        )
        XCTAssertEqual(
            DeterministicSpeechAnnotator.normalizeRepetitionToken("go"),
            "go"
        )
        XCTAssertEqual(
            DeterministicSpeechAnnotator.normalizeRepetitionToken("“DON’T,”"),
            "don’t"
        )
        XCTAssertEqual(
            DeterministicSpeechAnnotator.normalizeRepetitionToken(
                "(state-of-the-art)!"
            ),
            "state-of-the-art"
        )
        XCTAssertEqual(
            DeterministicSpeechAnnotator.normalizeRepetitionToken("go-."),
            "go-"
        )
    }

    func testClassifiesOnlyExplicitTextualEvidenceAndExactBoundedRepetition() throws {
        let revision = try annotationRevision(
            text: "Um state-of-the-art p- we should we should well actually no",
            words: [
                ("Um", .filledPause, 100, 180),
                ("state-of-the-art", .lexical, 220, 420),
                ("p-", .partialWord, 460, 520),
                ("we", .lexical, 600, 680),
                ("should", .lexical, 690, 790),
                ("we", .lexical, 840, 920),
                ("should", .lexical, 930, 1_030),
                ("well", .lexical, 1_300, 1_400),
                ("actually", .lexical, 1_450, 1_600),
                ("no", .lexical, 1_650, 1_720),
            ]
        )

        let result = try DeterministicSpeechAnnotator().annotate(
            revision: revision,
            evidence: .none
        )

        XCTAssertEqual(
            result.textualEvents.map(\.category),
            [.filledPause, .partialWord, .repetitionCandidate]
        )
        XCTAssertEqual(
            result.textualEvents.map {
                $0.wordRange.firstWordID.rawValue + "..." +
                    $0.wordRange.lastWordID.rawValue
            },
            [
                "w000000...w000000",
                "w000002...w000002",
                "w000003...w000006",
            ]
        )
    }

    func testSubtractsUnavailableAndCanonicalCoverageBeforeAudioClassification() throws {
        let duration: UInt64 = 2_000
        let nonSpeech = TranscriptAudioEvent(
            audioEventID: try AudioEventID("a000000"),
            category: .nonSpeech,
            audioSourceID: .microphone,
            timeRange: try annotationTimeRange(1_000, 1_100, duration: duration)
        )
        let revision = try annotationRevision(
            text: "hello",
            words: [("hello", .lexical, 400, 600)],
            audioEvents: [nonSpeech],
            durationMilliseconds: duration
        )
        let evidence = SpeechAnnotationEvidence(
            sources: [
                SpeechAcousticEvidence(
                    audioSourceID: .microphone,
                    observedRanges: [
                        try annotationTimeRange(100, 1_900, duration: duration),
                    ],
                    voicedRanges: [
                        try annotationTimeRange(200, 500, duration: duration),
                        try annotationTimeRange(700, 900, duration: duration),
                    ],
                    unavailableIntervals: [
                        SpeechUnavailableInterval(
                            timeRange: try annotationTimeRange(
                                250,
                                350,
                                duration: duration
                            ),
                            reasons: [.muted]
                        ),
                        SpeechUnavailableInterval(
                            timeRange: try annotationTimeRange(
                                750,
                                800,
                                duration: duration
                            ),
                            reasons: [.captureGap]
                        ),
                    ]
                ),
            ]
        )

        let result = try DeterministicSpeechAnnotator().annotate(
            revision: revision,
            evidence: evidence
        )

        XCTAssertEqual(
            result.audioEvents.map {
                "\($0.category.rawValue):\($0.timeRange.startMilliseconds)-" +
                    "\($0.timeRange.endMilliseconds)"
            },
            [
                "silentPause:100-200",
                "untranscribedVoicedInterval:200-250",
                "muted:250-350",
                "untranscribedVoicedInterval:350-400",
                "silentPause:600-700",
                "untranscribedVoicedInterval:700-750",
                "captureGap:750-800",
                "untranscribedVoicedInterval:800-900",
                "silentPause:900-1000",
                "nonSpeech:1000-1100",
                "silentPause:1100-1900",
            ]
        )
        XCTAssertEqual(
            result.audioEvents.first(where: { $0.category == .nonSpeech })?
                .audioEventID,
            nonSpeech.audioEventID
        )
    }

    func testAuthoritativeUnavailableSplitsExistingObservedAudioEvents() throws {
        let duration: UInt64 = 1_000
        let revision = try annotationRevision(
            text: "hello",
            words: [("hello", .lexical, 1, 50)],
            audioEvents: [
                try annotationAudioEvent(
                    "a000000",
                    .silentPause,
                    100,
                    500,
                    duration: duration
                ),
                try annotationAudioEvent(
                    "a000001",
                    .untranscribedVoicedInterval,
                    600,
                    900,
                    duration: duration
                ),
            ],
            durationMilliseconds: duration
        )
        let evidence = SpeechAnnotationEvidence(
            sources: [
                SpeechAcousticEvidence(
                    audioSourceID: .microphone,
                    observedRanges: [],
                    voicedRanges: [],
                    unavailableIntervals: [
                        SpeechUnavailableInterval(
                            timeRange: try annotationTimeRange(
                                200,
                                250,
                                duration: duration
                            ),
                            reasons: [.muted]
                        ),
                        SpeechUnavailableInterval(
                            timeRange: try annotationTimeRange(
                                300,
                                350,
                                duration: duration
                            ),
                            reasons: [.captureGap]
                        ),
                        SpeechUnavailableInterval(
                            timeRange: try annotationTimeRange(
                                700,
                                750,
                                duration: duration
                            ),
                            reasons: [.muted]
                        ),
                    ]
                ),
            ]
        )

        let result = try DeterministicSpeechAnnotator().annotate(
            revision: revision,
            evidence: evidence
        )

        XCTAssertEqual(
            describedAudioEvents(result.audioEvents),
            [
                "a000002:silentPause:100-200",
                "a000003:muted:200-250",
                "a000004:silentPause:250-300",
                "a000005:captureGap:300-350",
                "a000006:silentPause:350-500",
                "a000007:untranscribedVoicedInterval:600-700",
                "a000008:muted:700-750",
                "a000009:untranscribedVoicedInterval:750-900",
            ]
        )
    }

    func testUnavailableDeduplicationIsCategorySpecific() throws {
        let duration: UInt64 = 1_000
        let revision = try annotationRevision(
            text: "hello",
            words: [("hello", .lexical, 1, 50)],
            audioEvents: [
                try annotationAudioEvent(
                    "a000000",
                    .muted,
                    200,
                    300,
                    duration: duration
                ),
                try annotationAudioEvent(
                    "a000001",
                    .nonSpeech,
                    400,
                    500,
                    duration: duration
                ),
            ],
            durationMilliseconds: duration
        )
        let evidence = SpeechAnnotationEvidence(
            sources: [
                SpeechAcousticEvidence(
                    audioSourceID: .microphone,
                    observedRanges: [],
                    voicedRanges: [],
                    unavailableIntervals: [
                        SpeechUnavailableInterval(
                            timeRange: try annotationTimeRange(
                                150,
                                350,
                                duration: duration
                            ),
                            reasons: [.muted, .captureGap]
                        ),
                        SpeechUnavailableInterval(
                            timeRange: try annotationTimeRange(
                                400,
                                500,
                                duration: duration
                            ),
                            reasons: [.captureGap]
                        ),
                    ]
                ),
            ]
        )

        let result = try DeterministicSpeechAnnotator().annotate(
            revision: revision,
            evidence: evidence
        )

        XCTAssertEqual(
            describedAudioEvents(result.audioEvents),
            [
                "a000002:muted:150-200",
                "a000003:captureGap:150-350",
                "a000000:muted:200-300",
                "a000004:muted:300-350",
                "a000001:nonSpeech:400-500",
                "a000005:captureGap:400-500",
            ]
        )
    }

    func testProjectorUsesCanonicalUTF8RangesAndStableLocalIdentities() throws {
        let revision = try annotationRevision(
            text: "Écho, Um",
            words: [
                ("Écho", .lexical, 100, 200),
                ("Um", .filledPause, 250, 320),
            ]
        )
        let annotations = try DeterministicSpeechAnnotator().annotate(
            revision: revision,
            evidence: .none
        )

        let first = try TranscriptAnnotationProjector.project(
            annotations,
            over: revision
        )
        let second = try TranscriptAnnotationProjector.project(
            annotations,
            over: revision
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.textualOverlays.count, 1)
        XCTAssertEqual(first.textualOverlays[0].textualEventID.rawValue, "t000000")
        XCTAssertEqual(first.textualOverlays[0].lineID.rawValue, "l000000")
        XCTAssertEqual(first.textualOverlays[0].wordID.rawValue, "w000001")
        XCTAssertEqual(
            first.textualOverlays[0].displayRange,
            LineTextRange(startUTF8Byte: 7, endUTF8Byte: 9)
        )
        XCTAssertEqual(revision.lines[0].text, "Écho, Um")
    }

    func testProjectorRejectsPathologicalOverlappingRangeWork() throws {
        let revision = try annotationRevision(
            text: "one two",
            words: [
                ("one", .lexical, 100, 200),
                ("two", .lexical, 250, 350),
            ]
        )
        let eventCount = DeterministicSpeechAnnotator.maximumAnnotationCount / 2 + 1
        let events = try (0..<eventCount).map { ordinal in
            TranscriptAnnotation.textual(
                TextualEvent(
                    textualEventID: try TextualEventID(
                        stableAnnotationID("t", ordinal)
                    ),
                    transcriptRevisionID: revision.revisionID,
                    category: .repetitionCandidate,
                    wordRange: TranscriptWordRange(
                        firstWordID: revision.lines[0].words[0].wordID,
                        lastWordID: revision.lines[0].words[1].wordID
                    ),
                    confidence: .medium,
                    ruleVersion: DeterministicSpeechAnnotator.ruleVersion
                )
            )
        }
        let annotations = TranscriptAnnotationSet(
            transcriptRevisionID: revision.revisionID,
            ruleVersion: DeterministicSpeechAnnotator.ruleVersion,
            annotations: events
        )

        XCTAssertThrowsError(
            try TranscriptAnnotationProjector.project(annotations, over: revision)
        ) { error in
            XCTAssertEqual(
                error as? TranscriptAnnotationProjectionError,
                .outputLimitExceeded
            )
        }
    }

    func testRepetitionRequiresExactAdjacentLexicalEvidenceAndReliableTiming() throws {
        let revision = try annotationRevision(
            text: "go Um go now go very very later later Ｗｅ we",
            words: [
                ("go", .lexical, 100, 180),
                ("Um", .filledPause, 200, 260),
                ("go", .lexical, 300, 380),
                ("now", .lexical, 420, 500),
                ("go", .lexical, 540, 620),
                ("very", .lexical, 700, 780),
                ("very", .lexical, 820, 900),
                ("later", .lexical, 1_000, 1_100),
                ("later", .lexical, 1_150, 1_250),
                ("Ｗｅ", .lexical, 1_400, 1_480),
                ("we", .lexical, 1_520, 1_600),
            ],
            untimedWordOrdinals: [8]
        )

        let result = try DeterministicSpeechAnnotator().annotate(
            revision: revision,
            evidence: .none
        )
        let repetitions = result.textualEvents.filter {
            $0.category == .repetitionCandidate
        }

        XCTAssertEqual(
            repetitions.map {
                $0.wordRange.firstWordID.rawValue + "..." +
                    $0.wordRange.lastWordID.rawValue
            },
            [
                "w000000...w000002", // An explicit filler is not lexical.
                "w000005...w000006", // Exact emphasis remains a candidate.
                "w000009...w000010", // NFKC-equivalent words match.
            ]
        )
        XCTAssertFalse(
            repetitions.contains {
                $0.wordRange.firstWordID.rawValue == "w000002" &&
                    $0.wordRange.lastWordID.rawValue == "w000004"
            },
            "an intervening different lexical Word prevents compaction"
        )
        XCTAssertFalse(
            repetitions.contains {
                $0.wordRange.firstWordID.rawValue == "w000007"
            },
            "missing timing cannot prove the bounded repetition window"
        )
    }

    func testRejectsAcousticEvidenceOutsideTheRevisionTimeline() throws {
        let revision = try annotationRevision(
            text: "hello",
            words: [("hello", .lexical, 100, 200)],
            durationMilliseconds: 1_000
        )
        let outside = try annotationTimeRange(900, 1_100, duration: 1_200)
        let evidence = SpeechAnnotationEvidence(
            sources: [
                SpeechAcousticEvidence(
                    audioSourceID: .microphone,
                    observedRanges: [outside],
                    voicedRanges: [],
                    unavailableIntervals: []
                ),
            ]
        )

        XCTAssertThrowsError(
            try DeterministicSpeechAnnotator().annotate(
                revision: revision,
                evidence: evidence
            )
        ) { error in
            XCTAssertEqual(error as? SpeechAnnotationError, .invalidEvidence)
        }
    }

    func testExistingAudioEvidenceKeepsItsIdentityWithoutDerivedDuplicate() throws {
        let duration: UInt64 = 1_000
        let existingPause = TranscriptAudioEvent(
            audioEventID: try AudioEventID("a000000"),
            category: .silentPause,
            audioSourceID: .microphone,
            timeRange: try annotationTimeRange(100, 200, duration: duration)
        )
        let existingMuted = TranscriptAudioEvent(
            audioEventID: try AudioEventID("a000001"),
            category: .muted,
            audioSourceID: .microphone,
            timeRange: try annotationTimeRange(250, 350, duration: duration)
        )
        let revision = try annotationRevision(
            text: "hello",
            words: [("hello", .lexical, 400, 600)],
            audioEvents: [existingPause, existingMuted],
            durationMilliseconds: duration
        )
        let evidence = SpeechAnnotationEvidence(
            sources: [
                SpeechAcousticEvidence(
                    audioSourceID: .microphone,
                    observedRanges: [],
                    voicedRanges: [],
                    unavailableIntervals: [
                        SpeechUnavailableInterval(
                            timeRange: try annotationTimeRange(
                                250,
                                350,
                                duration: duration
                            ),
                            reasons: [.muted]
                        ),
                    ]
                ),
            ]
        )

        let result = try DeterministicSpeechAnnotator().annotate(
            revision: revision,
            evidence: evidence
        )

        XCTAssertEqual(result.audioEvents, [existingPause, existingMuted])
    }
}

private func annotationRevision(
    text: String,
    words: [(String, TranscriptWordKind, UInt64, UInt64)],
    audioEvents: [TranscriptAudioEvent] = [],
    durationMilliseconds: UInt64 = 4_000,
    untimedWordOrdinals: Set<Int> = []
) throws -> TranscriptRevision {
    var searchStart = text.startIndex
    let transcriptWords = try words.enumerated().map { ordinal, specification in
        let (wordText, kind, start, end) = specification
        guard let range = text.range(
            of: wordText,
            range: searchStart..<text.endIndex
        ) else {
            throw AnnotationFixtureError.wordMissing
        }
        searchStart = range.upperBound
        return TranscriptWord(
            wordID: try TranscriptWordID(stableAnnotationID("w", ordinal)),
            ordinal: ordinal,
            text: wordText,
            displayRange: LineTextRange(
                startUTF8Byte: text[..<range.lowerBound].utf8.count,
                endUTF8Byte: text[..<range.upperBound].utf8.count
            ),
            timeRange: untimedWordOrdinals.contains(ordinal)
                ? nil
                : try SessionTimeRange(
                    startMilliseconds: start,
                    endMilliseconds: end,
                    sessionDurationMilliseconds: durationMilliseconds
                ),
            confidence: 1,
            wordKind: kind
        )
    }
    let fingerprint = try AudioFingerprint(sha256: String(repeating: "a", count: 64))
    return try TranscriptRevision(
        revisionID: TranscriptRevisionID("trv-20260830T121000000Z-4FGH"),
        sessionID: SessionID("ses-20260830T120000000Z-2ABC"),
        jobID: TranscriptionJobID("job-20260830T120500000Z-3DEF"),
        createdAt: UTCInstant("2026-08-30T12:10:00.000Z"),
        durationMilliseconds: durationMilliseconds,
        audioFingerprint: fingerprint,
        sourceFingerprints: [
            TranscriptSourceFingerprint(
                audioSourceID: .microphone,
                fingerprint: fingerprint
            ),
        ],
        candidateArtifactFingerprint: try AudioFingerprint(
            sha256: String(repeating: "b", count: 64)
        ),
        engine: try annotationEngineProvenance(),
        lines: [
            TranscriptLine(
                lineID: TranscriptLineID("l000000"),
                order: 0,
                audioSourceID: .microphone,
                timeRange: try SessionTimeRange(
                    startMilliseconds: 1,
                    endMilliseconds: durationMilliseconds,
                    sessionDurationMilliseconds: durationMilliseconds
                ),
                text: text,
                words: transcriptWords
            ),
        ],
        audioEvents: audioEvents
    )
}

private func annotationEngineProvenance() throws -> TranscriptEngineProvenance {
    try TranscriptEngineProvenance(
        provider: "crisperwhisper",
        model: "small",
        revision: "annotation-test-v1",
        language: "en",
        mode: "verbatim",
        decodingOptionsSHA256: String(repeating: "c", count: 64),
        qualification: TranscriptEngineQualification(
            qualificationProfileID: "annotation-test-profile",
            engineLockSHA256: String(repeating: "d", count: 64),
            runtimeIdentity: "annotation-test-runtime",
            runtimeLockSHA256: String(repeating: "e", count: 64),
            compatibilityPatchID: "annotation-test-patch"
        ),
        usePolicy: EngineUsePolicy(
            policyID: "annotation-test-policy",
            coveredArtifacts: [.transcriptRevision],
            privateLocalUseAllowed: true,
            privateExportAllowed: true,
            externalProcessingAllowed: false,
            publicDistributionAllowed: false,
            commercialUseAllowed: false,
            licenseReference: "synthetic-license",
            licenseSHA256: String(repeating: "f", count: 64)
        )
    )
}

private func stableAnnotationID(_ prefix: Character, _ ordinal: Int) -> String {
    let digits = String(ordinal)
    return String(prefix) + String(repeating: "0", count: 6 - digits.count) + digits
}

private func annotationTimeRange(
    _ start: UInt64,
    _ end: UInt64,
    duration: UInt64
) throws -> SessionTimeRange {
    try SessionTimeRange(
        startMilliseconds: start,
        endMilliseconds: end,
        sessionDurationMilliseconds: duration
    )
}

private func annotationAudioEvent(
    _ id: String,
    _ category: TranscriptAudioEventCategory,
    _ start: UInt64,
    _ end: UInt64,
    duration: UInt64
) throws -> TranscriptAudioEvent {
    TranscriptAudioEvent(
        audioEventID: try AudioEventID(id),
        category: category,
        audioSourceID: .microphone,
        timeRange: try annotationTimeRange(start, end, duration: duration)
    )
}

private func describedAudioEvents(
    _ events: [TranscriptAudioEvent]
) -> [String] {
    events.map {
        "\($0.audioEventID.rawValue):\($0.category.rawValue):" +
            "\($0.timeRange.startMilliseconds)-\($0.timeRange.endMilliseconds)"
    }
}

private enum AnnotationFixtureError: Error {
    case wordMissing
}
