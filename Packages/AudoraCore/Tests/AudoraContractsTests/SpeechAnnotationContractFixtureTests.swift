import AudoraContracts
import AudoraDomain
import Foundation
import XCTest

final class SpeechAnnotationContractFixtureTests: XCTestCase {
    func testVersionedGoldenRunsThroughProductionAnnotator() throws {
        let schema = try ContractResources.data(for: .speechAnnotationFixtureSchema)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: schema))
        let fixture = try JSONDecoder().decode(
            SpeechAnnotationGoldenFixture.self,
            from: ContractResources.data(for: .speechAnnotationGoldenExample)
        )
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(
            fixture.ruleVersion,
            DeterministicSpeechAnnotator.ruleVersion
        )
        XCTAssertEqual(
            fixture.words.map(\.wordKind),
            [
                "filledPause", "lexical", "partialWord", "lexical", "lexical",
                "lexical", "lexical", "lexical", "lexical", "lexical", "lexical",
            ]
        )
        XCTAssertEqual(fixture.words[1].text, "state-of-the-art")
        XCTAssertNil(fixture.words[10].timeRange)

        let revision = try makeSpeechAnnotationRevision(from: fixture)
        let result = try DeterministicSpeechAnnotator().annotate(
            revision: revision,
            evidence: try makeSpeechAnnotationEvidence(
                from: fixture,
                duration: revision.durationMilliseconds
            )
        )
        let ordinals = Dictionary(
            uniqueKeysWithValues: revision.lines.flatMap(\.words).map {
                ($0.wordID, $0.ordinal)
            }
        )
        let textual = try result.textualEvents.map { event in
            let first = try XCTUnwrap(ordinals[event.wordRange.firstWordID])
            let last = try XCTUnwrap(ordinals[event.wordRange.lastWordID])
            return "\(event.textualEventID.rawValue):\(event.category.rawValue):" +
                "\(first)-\(last)"
        }
        XCTAssertEqual(
            textual,
            fixture.expected.textual.map {
                "\($0.textualEventId):\($0.category):" +
                    "\($0.firstWordOrdinal)-\($0.lastWordOrdinal)"
            }
        )
        XCTAssertEqual(
            result.audioEvents.map {
                "\($0.audioEventID.rawValue):\($0.category.rawValue):" +
                    "\($0.timeRange.startMilliseconds)-" +
                    "\($0.timeRange.endMilliseconds)"
            },
            fixture.expected.audio.map {
                "\($0.audioEventId):\($0.category):\($0.startMs)-\($0.endMs)"
            }
        )
    }
}

private struct SpeechAnnotationGoldenFixture: Decodable {
    struct Word: Decodable {
        let text: String
        let wordKind: String
        let timeRange: TimeRange?
    }

    struct AudioEvent: Decodable {
        let audioEventId: String
        let category: String
        let startMs: UInt64
        let endMs: UInt64
    }

    struct TimeRange: Decodable {
        let startMs: UInt64
        let endMs: UInt64
    }

    struct Unavailable: Decodable {
        let startMs: UInt64
        let endMs: UInt64
        let reasons: [String]
    }

    struct Evidence: Decodable {
        let observed: [TimeRange]
        let voiced: [TimeRange]
        let unavailable: [Unavailable]
    }

    struct ExpectedTextual: Decodable {
        let textualEventId: String
        let category: String
        let firstWordOrdinal: Int
        let lastWordOrdinal: Int
    }

    struct ExpectedAudio: Decodable {
        let audioEventId: String
        let category: String
        let startMs: UInt64
        let endMs: UInt64
    }

    struct Expected: Decodable {
        let textual: [ExpectedTextual]
        let audio: [ExpectedAudio]
    }

    let schemaVersion: Int
    let ruleVersion: String
    let durationMs: UInt64
    let lineText: String
    let words: [Word]
    let audioEvents: [AudioEvent]
    let evidence: Evidence
    let expected: Expected
}

private func makeSpeechAnnotationRevision(
    from fixture: SpeechAnnotationGoldenFixture
) throws -> TranscriptRevision {
    var searchStart = fixture.lineText.startIndex
    let words = try fixture.words.enumerated().map { ordinal, input in
        guard let display = fixture.lineText.range(
            of: input.text,
            range: searchStart..<fixture.lineText.endIndex
        ) else { throw SpeechAnnotationFixtureError.wordMissing }
        searchStart = display.upperBound
        let timeRange = try input.timeRange.map {
            try speechAnnotationTimeRange(
                $0.startMs,
                $0.endMs,
                duration: fixture.durationMs
            )
        }
        return TranscriptWord(
            wordID: try TranscriptWordID(speechAnnotationStableID("w", ordinal)),
            ordinal: ordinal,
            text: input.text,
            displayRange: LineTextRange(
                startUTF8Byte: fixture.lineText[..<display.lowerBound].utf8.count,
                endUTF8Byte: fixture.lineText[..<display.upperBound].utf8.count
            ),
            timeRange: timeRange,
            confidence: 1,
            wordKind: try speechAnnotationWordKind(input.wordKind)
        )
    }
    let fingerprint = try AudioFingerprint(sha256: String(repeating: "a", count: 64))
    return try TranscriptRevision(
        revisionID: TranscriptRevisionID("trv-20260830T121000000Z-4FGH"),
        sessionID: SessionID("ses-20260830T120000000Z-2ABC"),
        jobID: TranscriptionJobID("job-20260830T120500000Z-3DEF"),
        createdAt: UTCInstant("2026-08-30T12:10:00.000Z"),
        durationMilliseconds: fixture.durationMs,
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
        engine: try speechAnnotationEngineProvenance(),
        lines: [
            TranscriptLine(
                lineID: TranscriptLineID("l000000"),
                order: 0,
                audioSourceID: .microphone,
                timeRange: try speechAnnotationTimeRange(
                    0,
                    fixture.durationMs,
                    duration: fixture.durationMs
                ),
                text: fixture.lineText,
                words: words
            ),
        ],
        audioEvents: try fixture.audioEvents.map {
            TranscriptAudioEvent(
                audioEventID: try AudioEventID($0.audioEventId),
                category: try speechAnnotationAudioCategory($0.category),
                audioSourceID: .microphone,
                timeRange: try speechAnnotationTimeRange(
                    $0.startMs,
                    $0.endMs,
                    duration: fixture.durationMs
                )
            )
        }
    )
}

private func makeSpeechAnnotationEvidence(
    from fixture: SpeechAnnotationGoldenFixture,
    duration: UInt64
) throws -> SpeechAnnotationEvidence {
    SpeechAnnotationEvidence(
        sources: [
            SpeechAcousticEvidence(
                audioSourceID: .microphone,
                observedRanges: try fixture.evidence.observed.map {
                    try speechAnnotationTimeRange(
                        $0.startMs,
                        $0.endMs,
                        duration: duration
                    )
                },
                voicedRanges: try fixture.evidence.voiced.map {
                    try speechAnnotationTimeRange(
                        $0.startMs,
                        $0.endMs,
                        duration: duration
                    )
                },
                unavailableIntervals: try fixture.evidence.unavailable.map {
                    SpeechUnavailableInterval(
                        timeRange: try speechAnnotationTimeRange(
                            $0.startMs,
                            $0.endMs,
                            duration: duration
                        ),
                        reasons: Set(try $0.reasons.map(speechAnnotationUnavailableReason))
                    )
                }
            ),
        ]
    )
}

private func speechAnnotationWordKind(_ value: String) throws -> TranscriptWordKind {
    switch value {
    case "lexical": .lexical
    case "filledPause": .filledPause
    case "partialWord": .partialWord
    default: throw SpeechAnnotationFixtureError.unknownValue
    }
}

private func speechAnnotationAudioCategory(
    _ value: String
) throws -> TranscriptAudioEventCategory {
    switch value {
    case "nonSpeech": .nonSpeech
    case "silentPause": .silentPause
    case "untranscribedVoicedInterval": .untranscribedVoicedInterval
    case "muted": .muted
    case "captureGap": .captureGap
    default: throw SpeechAnnotationFixtureError.unknownValue
    }
}

private func speechAnnotationUnavailableReason(
    _ value: String
) throws -> UnavailableReason {
    switch value {
    case "muted": .muted
    case "captureGap": .captureGap
    default: throw SpeechAnnotationFixtureError.unknownValue
    }
}

private func speechAnnotationTimeRange(
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

private func speechAnnotationStableID(
    _ prefix: Character,
    _ ordinal: Int
) -> String {
    let digits = String(ordinal)
    return String(prefix) + String(repeating: "0", count: 6 - digits.count) + digits
}

private func speechAnnotationEngineProvenance() throws -> TranscriptEngineProvenance {
    try TranscriptEngineProvenance(
        provider: "crisperwhisper",
        model: "small",
        revision: "annotation-contract-v1",
        language: "en",
        mode: "verbatim",
        decodingOptionsSHA256: String(repeating: "c", count: 64),
        qualification: TranscriptEngineQualification(
            qualificationProfileID: "annotation-contract-profile",
            engineLockSHA256: String(repeating: "d", count: 64),
            runtimeIdentity: "annotation-contract-runtime",
            runtimeLockSHA256: String(repeating: "e", count: 64),
            compatibilityPatchID: "annotation-contract-patch"
        ),
        usePolicy: EngineUsePolicy(
            policyID: "annotation-contract-policy",
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

private enum SpeechAnnotationFixtureError: Error {
    case unknownValue
    case wordMissing
}
