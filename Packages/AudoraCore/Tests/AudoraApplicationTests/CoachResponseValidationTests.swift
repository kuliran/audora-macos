@testable @_spi(CoachContextQualification) import AudoraApplication
import AudoraContracts
import AudoraDomain
import Foundation
import XCTest

final class CoachResponseValidationTests: XCTestCase {
    func testBundledCoachResponseCorpusMatchesRuntimeValidation() throws {
        for resource in [
            ContractResource.coachResponseAnswerExample,
            .coachResponseFullBatchExample,
        ] {
            let validated = try CoachResponseValidator().validate(
                CoachProviderCompleteResponse(
                    body: try ContractResources.data(for: resource)
                ),
                in: contractFixtureContext()
            )
            XCTAssertFalse(validated.messageBlocks.isEmpty, resource.bundlePath)
        }
        let reconsider = try CoachResponseValidator().validate(
            CoachProviderCompleteResponse(
                body: try ContractResources.data(
                    for: .coachResponseReconsiderNoMessageExample
                )
            ),
            in: contractFixtureContext(trigger: .reconsiderProfileChange)
        )
        XCTAssertTrue(reconsider.messageBlocks.isEmpty)

        for resource in [
            ContractResource.rejectedCoachResponseEmptyMessageBlocks,
            .rejectedCoachResponseMissingMarkdown,
            .rejectedCoachResponseNullMemory,
            .rejectedCoachResponseUnknownKey,
            .rejectedCoachResponseWrongKind,
        ] {
            XCTAssertThrowsError(
                try CoachResponseValidator().validate(
                    CoachProviderCompleteResponse(
                        body: try ContractResources.data(for: resource)
                    ),
                    in: contractFixtureContext()
                ),
                resource.bundlePath
            ) {
                XCTAssertEqual(
                    $0 as? CoachResponseValidationError,
                    .schemaMismatch,
                    resource.bundlePath
                )
            }
        }
    }

    func testValidCompleteBatchPreservesBlockAndEffectOrder() throws {
        let response = response(
            """
            {
              "messageBlocks": [
                {"kind":"markdown","markdown":"Start with **one** clear point."},
                {
                  "kind":"evidenceObservation",
                  "markdown":"Your transition lands too quickly.",
                  "evidence":[
                    {
                      "sessionAttachmentId":"attachment-1",
                      "target":{"kind":"wordRange","startWordId":"w1","endWordId":"w3"}
                    },
                    {
                      "sessionAttachmentId":"attachment-2",
                      "target":{"kind":"audioEvent","audioEventId":"a2"}
                    }
                  ]
                }
              ],
              "newMemory":{
                "generalNotes":"Practice deliberate transitions.",
                "sessionSummaries":[
                  {"sessionAttachmentId":"attachment-1","notes":"Fast transition."}
                ]
              },
              "proposeProfileEdits":[
                {
                  "edit":{
                    "kind":"add",
                    "statementKind":"growthDirection",
                    "wording":"Pause between major points."
                  },
                  "evidence":[
                    {
                      "sessionAttachmentId":"attachment-1",
                      "target":{"kind":"audioEvent","audioEventId":"a1"}
                    }
                  ]
                },
                {
                  "edit":{
                    "kind":"replace",
                    "targetStatementId":"profile-1",
                    "wording":"Open with the conclusion."
                  }
                }
              ],
              "appendProfileEvidence":[
                {
                  "targetStatementId":"profile-2",
                  "evidence":[
                    {
                      "sessionAttachmentId":"attachment-2",
                      "target":{"kind":"wordRange","startWordId":"x1","endWordId":"x2"}
                    }
                  ]
                }
              ]
            }
            """
        )

        let validated = try CoachResponseValidator().validate(
            response,
            in: context()
        )

        XCTAssertEqual(validated.messageBlocks.count, 2)
        XCTAssertEqual(
            validated.publicationMarkdown,
            "Start with **one** clear point.\n\nYour transition lands too quickly."
        )
        XCTAssertEqual(validated.newMemory?.sessionSummaries.count, 1)
        XCTAssertEqual(validated.proposedProfileEdits.count, 2)
        XCTAssertEqual(validated.appendedProfileEvidence.count, 1)
        XCTAssertFalse(validated.isSupportedByCurrentPublicationSlice)
    }

    func testOrdinaryAnswerRequiresBlocksButReconsiderMayBeEmpty() throws {
        XCTAssertThrowsError(
            try CoachResponseValidator().validate(response("{}"), in: context())
        ) {
            XCTAssertEqual(
                $0 as? CoachResponseValidationError,
                .messageBlocksRequired
            )
        }

        let reconsider = try CoachResponseValidator().validate(
            response("{}"),
            in: context(trigger: .reconsiderProfileChange)
        )
        XCTAssertTrue(reconsider.messageBlocks.isEmpty)
        XCTAssertNil(reconsider.publicationMarkdown)

        assertRejected(
            #"{"messageBlocks":[]}"#,
            as: .schemaMismatch
        )
    }

    func testRejectsMalformedUTF8DuplicateKeysAndClosedSchemaViolations() throws {
        XCTAssertThrowsError(
            try CoachResponseValidator().validate(
                CoachProviderCompleteResponse(body: Data([0xFF])),
                in: context()
            )
        ) {
            XCTAssertEqual($0 as? CoachResponseValidationError, .invalidUTF8)
        }

        let cases: [(String, CoachResponseValidationError)] = [
            ("{", .invalidJSON),
            (
                #"{"messageBlocks":[{"kind":"markdown","markdown":"ok"}],"\u006dessageBlocks":[{"kind":"markdown","markdown":"again"}]}"#,
                .duplicateJSONKey
            ),
            (
                #"{"messageBlocks":[{"kind":"markdown","markdown":"ok","extra":1}]}"#,
                .schemaMismatch
            ),
            (#"{"messageBlocks":null}"#, .schemaMismatch),
            (#"{"messageBlocks":"wrong"}"#, .schemaMismatch),
            (
                #"{"messageBlocks":[{"kind":"unknown","markdown":"ok"}]}"#,
                .schemaMismatch
            ),
            (
                #"{"messageBlocks":[{"kind":"markdown","markdown":""}]}"#,
                .schemaMismatch
            ),
            (#"{"proposeProfileEdits":[]}"#, .schemaMismatch),
            (#"{"appendProfileEvidence":[]}"#, .schemaMismatch),
        ]
        for (body, expected) in cases {
            assertRejected(body, as: expected)
        }

        let nested = #"{"unknown":"# +
            String(repeating: "[", count: 130) +
            "0" +
            String(repeating: "]", count: 130) +
            "}"
        assertRejected(nested, as: .invalidJSON)
    }

    func testCollectorAndFramedResponseTokenLimitsAreInclusive() throws {
        let complete = CoachProviderCompleteResponse.singleMarkdown("Exactly bounded.")
        let byteExact = context(
            responseTokens: 1_000_000,
            collectorBytes: complete.body.count
        )
        XCTAssertNoThrow(
            try CoachResponseValidator().validate(complete, in: byteExact)
        )
        XCTAssertThrowsError(
            try CoachResponseValidator().validate(
                complete,
                in: context(
                    responseTokens: 1_000_000,
                    collectorBytes: complete.body.count - 1
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? CoachResponseValidationError,
                .responseByteLimitExceeded
            )
        }

        let framing = CoachProviderFraming(
            minimumResponsePrefix: Data("P".utf8),
            minimumResponseSuffix: Data("S".utf8),
            minimumResponseHiddenTokens: 3
        )
        let exactTokens = complete.body.count + 5
        XCTAssertNoThrow(
            try CoachResponseValidator().validate(
                complete,
                in: context(responseTokens: exactTokens, framing: framing)
            )
        )
        XCTAssertThrowsError(
            try CoachResponseValidator().validate(
                complete,
                in: context(responseTokens: exactTokens - 1, framing: framing)
            )
        ) {
            XCTAssertEqual(
                $0 as? CoachResponseValidationError,
                .responseTokenLimitExceeded
            )
        }
    }

    func testMarkdownAllowsFormattingAndOrdinaryColonProse() throws {
        let markdown = """
        Metadata: keep the **main point**.

        - Pause.
        - Continue.

        \\<shown literally>
        \\<1@example.com>
        A comparison such as x <y remains ordinary prose.
        In 2026 [label]: remained ordinary inline prose.
        """
        let validated = try CoachResponseValidator().validate(
            .singleMarkdown(markdown),
            in: context()
        )
        XCTAssertEqual(validated.publicationMarkdown, markdown)
    }

    func testMarkdownRejectsActiveContentControlsAndBidiOverrides() {
        let rejected = [
            "[label](https://example.invalid)",
            "![alt](image.png)",
            "[label][destination]",
            "[destination]: https://example.invalid",
            "<https://example.invalid>",
            "<1@example.com>",
            "<em>raw HTML</em>",
            "<!--",
            "<script",
            "Visit custom://destination",
            "Visit +https://example.invalid",
            "Visit 1https://example.invalid",
            "control \u{0001}",
            "direction \u{202E}override",
            "direction \u{200F}mark",
            "direction \u{206A}format",
            #"\\<em>two slashes expose raw HTML</em>"#,
            "Use [guide]\r[guide]: /relative-target",
            "[guide]\n\n> [guide]: /relative-target",
            "[guide]\n\n- [guide]: /relative-target",
            "[Foo bar]\n\n[Foo\n  bar]: /relative-target",
            #"""
            [foo\]bar]

            [foo\]bar]: /relative-target
            """#,
        ]
        for markdown in rejected {
            XCTAssertThrowsError(
                try CoachResponseValidator().validate(
                    .singleMarkdown(markdown),
                    in: context()
                ),
                "expected rejection for \(String(reflecting: markdown))"
            ) {
                XCTAssertEqual(
                    $0 as? CoachResponseValidationError,
                    .unsafeMarkdown
                )
            }
        }
    }

    func testMemoryUsesCanonicalTokenBoundaryAndDomainInvariants() throws {
        let body = """
        {
          "messageBlocks":[{"kind":"markdown","markdown":"Valid answer."}],
          "newMemory":{
            "generalNotes":"Remember this.",
            "sessionSummaries":[
              {"sessionAttachmentId":"attachment-1","notes":"First note."}
            ]
          }
        }
        """
        let canonicalMemory = CanonicalJSON.serialize(
            .object([
                "generalNotes": .string("Remember this."),
                "sessionSummaries": .array([
                    .object([
                        "notes": .string("First note."),
                        "sessionAttachmentId": .string("attachment-1"),
                    ]),
                ]),
            ])
        )
        XCTAssertNoThrow(
            try CoachResponseValidator().validate(
                response(body),
                in: context(memoryTokens: canonicalMemory.count)
            )
        )
        XCTAssertThrowsError(
            try CoachResponseValidator().validate(
                response(body),
                in: context(memoryTokens: canonicalMemory.count - 1)
            )
        ) {
            XCTAssertEqual(
                $0 as? CoachResponseValidationError,
                .memoryTokenLimitExceeded
            )
        }

        let invalidMemories = [
            """
            {"messageBlocks":[{"kind":"markdown","markdown":"Valid."}],
             "newMemory":{"generalNotes":"","sessionSummaries":[
               {"sessionAttachmentId":"attachment-1","notes":"one"},
               {"sessionAttachmentId":"attachment-1","notes":"two"}]}}
            """,
            """
            {"messageBlocks":[{"kind":"markdown","markdown":"Valid."}],
             "newMemory":{"generalNotes":"","sessionSummaries":[
               {"sessionAttachmentId":"missing","notes":"one"}]}}
            """,
            #"{"messageBlocks":[{"kind":"markdown","markdown":"Valid."}],"newMemory":{"generalNotes":"\u0000","sessionSummaries":[]}}"#,
        ]
        for invalid in invalidMemories {
            assertRejected(invalid, as: .invalidMemory)
        }

        let oversized = String(
            repeating: "x",
            count: CoachMemory.maximumTextUTF8Bytes + 1
        )
        let oversizedResponse = CoachProviderCompleteResponse(
            body: CanonicalJSON.serialize(
                .object([
                    "messageBlocks": .array([
                        .object([
                            "kind": .string("markdown"),
                            "markdown": .string("Valid."),
                        ]),
                    ]),
                    "newMemory": .object([
                        "generalNotes": .string(oversized),
                        "sessionSummaries": .array([]),
                    ]),
                ])
            )
        )
        XCTAssertThrowsError(
            try CoachResponseValidator().validate(
                oversizedResponse,
                in: context()
            )
        ) {
            XCTAssertEqual($0 as? CoachResponseValidationError, .invalidMemory)
        }
    }

    func testEvidencePointersResolveOnlyWithinTheirFrozenTranscript() {
        let invalidTargets = [
            #"{"sessionAttachmentId":"missing","target":{"kind":"wordRange","startWordId":"w1","endWordId":"w2"}}"#,
            #"{"sessionAttachmentId":"attachment-1","target":{"kind":"wordRange","startWordId":"missing","endWordId":"w2"}}"#,
            #"{"sessionAttachmentId":"attachment-1","target":{"kind":"wordRange","startWordId":"w3","endWordId":"w1"}}"#,
            #"{"sessionAttachmentId":"attachment-1","target":{"kind":"wordRange","startWordId":"w1","endWordId":"x2"}}"#,
            #"{"sessionAttachmentId":"attachment-1","target":{"kind":"audioEvent","audioEventId":"missing"}}"#,
        ]
        for target in invalidTargets {
            assertRejected(
                """
                {"messageBlocks":[{
                  "kind":"evidenceObservation",
                  "markdown":"Grounded wording.",
                  "evidence":[\(target)]
                }]}
                """,
                as: .invalidEvidencePointer
            )
        }
    }

    func testProfileTargetsAndConflictingEffectsAreRejected() {
        let invalidBatches = [
            """
            "proposeProfileEdits":[
              {"edit":{"kind":"replace","targetStatementId":"missing","wording":"new"}}
            ]
            """,
            """
            "proposeProfileEdits":[
              {"edit":{"kind":"retire","targetStatementId":"missing"}}
            ]
            """,
            """
            "appendProfileEvidence":[{
              "targetStatementId":"missing",
              "evidence":[{"sessionAttachmentId":"attachment-1",
                "target":{"kind":"audioEvent","audioEventId":"a1"}}]
            }]
            """,
            """
            "proposeProfileEdits":[
              {"edit":{"kind":"replace","targetStatementId":"profile-1","wording":"one"}},
              {"edit":{"kind":"replace","targetStatementId":"profile-1","wording":"two"}}
            ]
            """,
            """
            "proposeProfileEdits":[
              {"edit":{"kind":"replace","targetStatementId":"profile-1","wording":"one"}},
              {"edit":{"kind":"retire","targetStatementId":"profile-1"}}
            ]
            """,
            """
            "proposeProfileEdits":[
              {"edit":{"kind":"retire","targetStatementId":"profile-1"}}
            ],
            "appendProfileEvidence":[{
              "targetStatementId":"profile-1",
              "evidence":[{"sessionAttachmentId":"attachment-1",
                "target":{"kind":"audioEvent","audioEventId":"a1"}}]
            }]
            """,
        ]
        for (index, effects) in invalidBatches.enumerated() {
            let expected: CoachResponseValidationError = index < 3
                ? .danglingProfileTarget
                : .conflictingProfileEffects
            assertRejected(
                """
                {
                  "messageBlocks":[{"kind":"markdown","markdown":"Valid."}],
                  \(effects)
                }
                """,
                as: expected
            )
        }
    }

    func testExactDuplicateProfileEditIsNotAConflict() throws {
        let body = """
        {
          "messageBlocks":[{"kind":"markdown","markdown":"Valid."}],
          "proposeProfileEdits":[
            {"edit":{"kind":"replace","targetStatementId":"profile-1","wording":"same"}},
            {"edit":{"kind":"replace","targetStatementId":"profile-1","wording":"same"}}
          ],
          "appendProfileEvidence":[{
            "targetStatementId":"profile-2",
            "evidence":[{"sessionAttachmentId":"attachment-1",
              "target":{"kind":"audioEvent","audioEventId":"a1"}}]
          }]
        }
        """
        let validated = try CoachResponseValidator().validate(
            response(body),
            in: context()
        )
        XCTAssertEqual(validated.proposedProfileEdits.count, 2)
        XCTAssertEqual(validated.appendedProfileEvidence.count, 1)
    }

    func testUnavailableAudioMayBeObservedButCannotSupportProfileEffects() throws {
        let pointer = """
        {"sessionAttachmentId":"attachment-1",
         "target":{"kind":"audioEvent","audioEventId":"gap-1"}}
        """
        XCTAssertNoThrow(
            try CoachResponseValidator().validate(
                response(
                    """
                    {"messageBlocks":[{
                      "kind":"evidenceObservation",
                      "markdown":"The capture gap is visible.",
                      "evidence":[\(pointer)]
                    }]}
                    """
                ),
                in: context()
            )
        )
        assertRejected(
            """
            {
              "messageBlocks":[{"kind":"markdown","markdown":"Valid."}],
              "proposeProfileEdits":[{
                "edit":{
                  "kind":"add",
                  "statementKind":"speakingObservation",
                  "wording":"Unsupported observation."
                },
                "evidence":[\(pointer)]
              }]
            }
            """,
            as: .invalidEvidencePointer
        )
    }

    func testMultiplePlainBlocksRemainValidatedButAreNotFlattenedForPublication() throws {
        let validated = try CoachResponseValidator().validate(
            response(
                """
                {"messageBlocks":[
                  {"kind":"markdown","markdown":"First."},
                  {"kind":"markdown","markdown":"Second."}
                ]}
                """
            ),
            in: context()
        )
        XCTAssertEqual(validated.messageBlocks.count, 2)
        XCTAssertFalse(validated.isSupportedByCurrentPublicationSlice)
    }

    private func assertRejected(
        _ body: String,
        as expected: CoachResponseValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try CoachResponseValidator().validate(response(body), in: context()),
            file: file,
            line: line
        ) {
            XCTAssertEqual(
                $0 as? CoachResponseValidationError,
                expected,
                "unexpected classification for \(body)",
                file: file,
                line: line
            )
        }
    }

    private func response(_ body: String) -> CoachProviderCompleteResponse {
        CoachProviderCompleteResponse(body: Data(body.utf8))
    }

    private func context(
        trigger: CoachResponseTriggerPosition = .userMessage,
        responseTokens: Int = 1_000_000,
        collectorBytes: Int = 1_000_000,
        memoryTokens: Int = 1_000_000,
        framing: CoachProviderFraming = CoachProviderFraming()
    ) -> CoachResponseValidationContext {
        let first = try! ChatSessionAttachmentID("attachment-1")
        let second = try! ChatSessionAttachmentID("attachment-2")
        return try! CoachResponseValidationContext(
            triggerPosition: trigger,
            transcripts: [
                first: try! CoachResponseTranscriptEvidenceIndex(
                    wordIDs: ["w1", "w2", "w3"],
                    audioEventIDs: ["a1", "gap-1"],
                    audioEventIDsIneligibleForProfileSupport: ["gap-1"]
                ),
                second: try! CoachResponseTranscriptEvidenceIndex(
                    wordIDs: ["x1", "x2"],
                    audioEventIDs: ["a2"]
                ),
            ],
            activeProfileStatementIDs: ["profile-1", "profile-2"],
            authority: CoachResponseValidationAuthority(
                responseReservedTokens: responseTokens,
                responseCollectorByteCeiling: collectorBytes,
                coachMemoryMaxTokens: memoryTokens,
                framing: framing,
                tokenEstimator: .utf8ByteUpperBound()
            )
        )
    }

    private func contractFixtureContext(
        trigger: CoachResponseTriggerPosition = .userMessage
    ) -> CoachResponseValidationContext {
        let planning = try! ChatSessionAttachmentID("planning-reflection")
        let demo = try! ChatSessionAttachmentID("demo-practice")
        return try! CoachResponseValidationContext(
            triggerPosition: trigger,
            transcripts: [
                planning: try! CoachResponseTranscriptEvidenceIndex(
                    wordIDs: (1 ... 18).map { "word-\($0)" },
                    audioEventIDs: ["event-3"]
                ),
                demo: try! CoachResponseTranscriptEvidenceIndex(
                    wordIDs: (31 ... 34).map { "word-\($0)" },
                    audioEventIDs: []
                ),
            ],
            activeProfileStatementIDs: ["statement-7"],
            authority: CoachResponseValidationAuthority(
                responseReservedTokens: 1_000_000,
                responseCollectorByteCeiling: 1_000_000,
                coachMemoryMaxTokens: 1_000_000,
                framing: CoachProviderFraming(),
                tokenEstimator: .utf8ByteUpperBound()
            )
        )
    }
}
