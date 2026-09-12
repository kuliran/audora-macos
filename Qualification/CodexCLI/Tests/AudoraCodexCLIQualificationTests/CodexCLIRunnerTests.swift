import Foundation
import XCTest

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@testable import AudoraCodexCLIQualification

final class CodexCLIRunnerTests: XCTestCase {
    func testCollectsValidStructuredResponseWithinBounds() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "Practice one calm opening sentence."]],
        ])
        let plan = try eventPlan(lines: [
            try jsonString(["type": "thread.started", "thread_id": "synthetic-thread"]),
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": response],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["input_tokens": 100, "output_tokens": 42],
            ]),
        ])

        let outcome = CodexCLIRunner().run(plan: plan)

        guard case let .success(result) = outcome else {
            return XCTFail("expected a successful bounded response")
        }
        XCTAssertEqual(result.responseByteCount, response.utf8.count)
        XCTAssertEqual(result.outputTokenCount, 42)
        XCTAssertTrue(result.processWasReaped)
    }

    func testAcceptsCodex0143CompleteUsageShape() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "Practice once."]],
        ])
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": response],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": [
                    "input_tokens": 100,
                    "cached_input_tokens": 20,
                    "output_tokens": 42,
                    "reasoning_output_tokens": 7,
                ],
            ]),
        ])

        guard case let .success(result) = CodexCLIRunner().run(plan: plan) else {
            return XCTFail("expected the Codex 0.143 usage shape to be accepted")
        }
        XCTAssertEqual(result.outputTokenCount, 42)
    }

    func testRejectsMalformedResponseWithoutReturningIt() throws {
        let marker = "synthetic-private-provider-output"
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": marker],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["output_tokens": 2],
            ]),
        ])

        let outcome = CodexCLIRunner().run(plan: plan)

        XCTAssertEqual(failure(outcome)?.reason, .malformedOutput)
        XCTAssertFalse(String(describing: outcome).contains(marker))
    }

    func testRejectsMarkdownAboveSchemaCodePointLimit() throws {
        let markdown = "a" + String(repeating: "\u{0301}", count: 160)
        XCTAssertEqual(markdown.count, 1)
        XCTAssertEqual(markdown.unicodeScalars.count, 161)
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": markdown]],
        ])
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": response],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["output_tokens": 2],
            ]),
        ])

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .malformedOutput
        )
    }

    func testRejectsInvalidUTF8InEventStream() throws {
        let invalidMarker = "INVALID_UTF8"
        let response = try jsonString([
            "messageBlocks": [[
                "kind": "markdown",
                "markdown": "Invalid \(invalidMarker)",
            ]],
        ])
        let responseEvent = try jsonString([
            "type": "item.completed",
            "item": ["type": "agent_message", "text": response],
        ])
        let usageEvent = try jsonString([
            "type": "turn.completed",
            "usage": ["output_tokens": 2],
        ])
        var stream = Data(responseEvent.utf8)
        let markerRange = try XCTUnwrap(stream.range(of: Data(invalidMarker.utf8)))
        stream.replaceSubrange(markerRange, with: [0xff])
        stream.append(Data("\n\(usageEvent)\n".utf8))

        let fixtureURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-invalid-utf8-\(UUID().uuidString).jsonl"
        )
        try stream.write(to: fixtureURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let plan = try processPlan(
            executable: "/bin/cat",
            arguments: [fixtureURL.path]
        )

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .malformedOutput
        )
    }

    func testRejectsMoreThanOneCompletedAgentResponse() throws {
        let firstResponse = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "First response."]],
        ])
        let secondResponse = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "Second response."]],
        ])
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": firstResponse],
            ]),
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": secondResponse],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["output_tokens": 4],
            ]),
        ])

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .malformedOutput
        )
    }

    func testRejectsAgentResponseThatWasNotCompleted() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "Incomplete response."]],
        ])
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "item.started",
                "item": ["type": "agent_message", "text": response],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["output_tokens": 2],
            ]),
        ])

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .malformedOutput
        )
    }

    func testRejectsUnknownItemShapeEvenWhenAValidResponseFollows() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "Valid response."]],
        ])
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "item.completed",
                "item": ["text": "unknown item without a type"],
            ]),
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": response],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["output_tokens": 2],
            ]),
        ])

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .malformedOutput
        )
    }

    func testRejectsItemAttachedToUnknownEventType() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "Valid response."]],
        ])
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "future.item",
                "item": ["type": "reasoning", "text": "synthetic summary"],
            ]),
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": response],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["output_tokens": 2],
            ]),
        ])

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .malformedOutput
        )
    }

    func testRejectsUnknownTopLevelEventEvenWhenAValidResponseFollows() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "Valid response."]],
        ])
        let plan = try eventPlan(lines: [
            try jsonString(["type": "future.event", "opaque": true]),
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": response],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["output_tokens": 2],
            ]),
        ])

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .malformedOutput
        )
    }

    func testRejectsDuplicateJSONKeysAtEveryAcceptedObjectDepth() throws {
        let validResponse = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "Valid response."]],
        ])
        let validResponseEvent = try jsonString([
            "type": "item.completed",
            "item": ["type": "agent_message", "text": validResponse],
        ])
        let duplicateResponseRoot =
            #"{"messageBlocks":[{"kind":"markdown","markdown":"Valid response."}],"messageBlocks":[{"kind":"tool","markdown":"hidden"}]}"#
        let duplicateEscapedResponseRoot =
            #"{"messageBlocks":[{"kind":"markdown","markdown":"Valid response."}],"message\u0042locks":[{"kind":"tool","markdown":"hidden"}]}"#
        let duplicateNestedKey =
            #"{"messageBlocks":[{"kind":"markdown","kind":"tool","markdown":"Valid response."}]}"#
        let duplicateType = String(validResponseEvent.dropLast())
            + #", "type":"future.event"}"#
        let duplicateItem = validResponseEvent.replacingOccurrences(
            of: #", "type":"item.completed"}"#.replacingOccurrences(of: " ", with: ""),
            with: #", "item":{"type":"command_execution"},"type":"item.completed"}"#
                .replacingOccurrences(of: " ", with: "")
        )
        let malformedResponseEvents = [
            duplicateType,
            duplicateItem,
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": duplicateResponseRoot],
            ]),
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": duplicateEscapedResponseRoot],
            ]),
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": duplicateNestedKey],
            ]),
        ]
        let completion = try jsonString([
            "type": "turn.completed",
            "usage": ["output_tokens": 2],
        ])

        for responseEvent in malformedResponseEvents {
            XCTAssertEqual(
                failure(
                    CodexCLIRunner().run(
                        plan: try eventPlan(lines: [String(responseEvent), completion])
                    )
                )?.reason,
                .malformedOutput
            )
        }
    }

    func testRejectsUnexpectedFieldsOnKnownEventShapes() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "Valid response."]],
        ])
        let responseEvent = try jsonString([
            "type": "item.completed",
            "item": ["type": "agent_message", "text": response],
        ])
        let completionEvent = try jsonString([
            "type": "turn.completed",
            "usage": ["output_tokens": 2],
        ])
        let malformedEvents: [[String: Any]] = [
            ["type": "thread.started", "thread_id": "fixture", "opaque": true],
            ["type": "turn.started", "opaque": true],
            [
                "type": "item.completed",
                "item": ["type": "reasoning", "text": "summary"],
                "opaque": true,
            ],
            [
                "type": "turn.completed",
                "usage": ["output_tokens": 2],
                "opaque": true,
            ],
            [
                "type": "turn.completed",
                "usage": ["output_tokens": 2, "opaque": 0],
            ],
            [
                "type": "error",
                "code": "authentication_error",
                "message": "synthetic detail",
                "opaque": true,
            ],
            [
                "type": "turn.failed",
                "error": [
                    "code": "rate_limit_exceeded",
                    "message": "synthetic detail",
                    "opaque": true,
                ],
            ],
        ]

        for malformedEvent in malformedEvents {
            let malformedLine = try jsonString(malformedEvent)
            let lines: [String]
            if malformedEvent["type"] as? String == "turn.completed" {
                lines = [responseEvent, malformedLine]
            } else {
                lines = [malformedLine, responseEvent, completionEvent]
            }
            XCTAssertEqual(
                failure(CodexCLIRunner().run(plan: try eventPlan(lines: lines)))?.reason,
                .malformedOutput,
                "known event shape accepted unknown fields: \(malformedEvent["type"] ?? "missing")"
            )
        }
    }

    func testRejectsMalformedAgentItemEvenWhenAValidResponseFollows() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "Valid response."]],
        ])
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": 42],
            ]),
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": response],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["output_tokens": 2],
            ]),
        ])

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .malformedOutput
        )
    }

    func testRejectsSafeNamedItemWithUnknownFields() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "Valid response."]],
        ])
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "item.completed",
                "item": [
                    "type": "reasoning",
                    "text": "bounded summary",
                    "path": "/synthetic/private-path",
                ],
            ]),
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": response],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["output_tokens": 2],
            ]),
        ])

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .malformedOutput
        )
    }

    func testRejectsMalformedReasoningItemEvenWhenAValidResponseFollows() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "Valid response."]],
        ])
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "item.completed",
                "item": ["type": "reasoning", "text": 42],
            ]),
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": response],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["output_tokens": 2],
            ]),
        ])

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .malformedOutput
        )
    }

    func testRejectsAgentResponseItemWithUnknownFields() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "Valid response."]],
        ])
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "item.completed",
                "item": [
                    "type": "agent_message",
                    "text": response,
                    "path": "/synthetic/private-path",
                ],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["output_tokens": 2],
            ]),
        ])

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .malformedOutput
        )
    }

    func testRejectsAnyToolEvent() throws {
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "item.completed",
                "item": ["type": "command_execution", "command": "pwd"],
            ]),
        ])

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .forbiddenCapabilityUsed
        )
    }

    func testEnforcesResponseAndReportedTokenBounds() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "A bounded response."]],
        ])
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": response],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["output_tokens": 42],
            ]),
        ])

        let byteLimited = CodexCLIRunner().run(
            plan: plan,
            limits: QualificationLimits(responseByteCeiling: 8)
        )
        XCTAssertEqual(failure(byteLimited)?.reason, .responseByteLimit)

        let tokenLimited = CodexCLIRunner().run(
            plan: plan,
            limits: QualificationLimits(outputTokenCeiling: 8)
        )
        XCTAssertEqual(failure(tokenLimited)?.reason, .outputTokenLimit)
    }

    func testRejectsNegativeReportedOutputUsage() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "A bounded response."]],
        ])
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": response],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["output_tokens": -1],
            ]),
        ])

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .malformedOutput
        )
    }

    func testRejectsOutOfRangeReportedOutputUsage() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "A bounded response."]],
        ])
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": response],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["output_tokens": 1e100],
            ]),
        ])

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .malformedOutput
        )
    }

    func testRejectsBooleanAndFractionalTokenCounts() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "A bounded response."]],
        ])
        let responseEvent = try jsonString([
            "type": "item.completed",
            "item": ["type": "agent_message", "text": response],
        ])
        let invalidUsage: [[String: Any]] = [
            ["output_tokens": true],
            ["input_tokens": 1.5, "output_tokens": 2],
            ["output_tokens": 2, "reasoning_output_tokens": true],
            ["output_tokens": 2, "reasoning_output_tokens": -1],
            ["output_tokens": 2, "reasoning_output_tokens": 1.5],
        ]

        for usage in invalidUsage {
            let completion = try jsonString([
                "type": "turn.completed",
                "usage": usage,
            ])
            XCTAssertEqual(
                failure(
                    CodexCLIRunner().run(
                        plan: try eventPlan(lines: [responseEvent, completion])
                    )
                )?.reason,
                .malformedOutput
            )
        }
    }

    func testRejectsFractionalTokenCountBeyondDoubleIntegerPrecision() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "A bounded response."]],
        ])
        let responseEvent = try jsonString([
            "type": "item.completed",
            "item": ["type": "agent_message", "text": response],
        ])
        let fractionalUsage =
            #"{"type":"turn.completed","usage":{"output_tokens":9007199254740992.5}}"#
        let plan = try eventPlan(lines: [responseEvent, fractionalUsage])

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .malformedOutput
        )
    }

    func testRejectsFractionalTokenCountBeyondDecimalPrecision() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "A bounded response."]],
        ])
        let responseEvent = try jsonString([
            "type": "item.completed",
            "item": ["type": "agent_message", "text": response],
        ])
        let fractionalUsage =
            #"{"type":"turn.completed","usage":{"output_tokens":2.00000000000000000000000000000000000000001}}"#
        let plan = try eventPlan(lines: [responseEvent, fractionalUsage])

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .malformedOutput
        )
    }

    func testRejectsMoreThanOneCompletedUsageRecord() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "A bounded response."]],
        ])
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": response],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["output_tokens": 5_000],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["output_tokens": 1],
            ]),
        ])

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .malformedOutput
        )
    }

    func testAcknowledgedCancellationAndTimeoutTerminateAndReapProcess() throws {
        let acknowledgement = try jsonString([
            "type": "item.started",
            "item": ["type": "reasoning", "text": "synthetic provider work"],
        ])
        let cancellationPlan = try processPlan(
            executable: "/usr/bin/perl",
            arguments: [
                "-e",
                #"$| = 1; print $ARGV[0], "\n"; sleep 10;"#,
                acknowledgement,
            ]
        )

        let cancelled = CodexCLIRunner().run(
            plan: cancellationPlan,
            limits: QualificationLimits(timeoutSeconds: 2, terminationGraceSeconds: 0.1),
            control: CodexRunControl(cancelAfterSeconds: 0.02)
        )
        XCTAssertEqual(failure(cancelled)?.reason, .cancelled)
        XCTAssertEqual(failure(cancelled)?.processWasReaped, true)

        let timeoutPlan = try processPlan(executable: "/bin/sleep", arguments: ["10"])
        let timedOut = CodexCLIRunner().run(
            plan: timeoutPlan,
            limits: QualificationLimits(timeoutSeconds: 0.02, terminationGraceSeconds: 0.1)
        )
        XCTAssertEqual(failure(timedOut)?.reason, .timedOut)
        XCTAssertEqual(failure(timedOut)?.processWasReaped, true)
    }

    func testIdleProcessCannotProvideCancellationEvidence() throws {
        let plan = try processPlan(executable: "/bin/sleep", arguments: ["10"])

        let outcome = CodexCLIRunner().run(
            plan: plan,
            limits: QualificationLimits(
                timeoutSeconds: 2,
                terminationGraceSeconds: 0.1
            ),
            control: CodexRunControl(cancelAfterSeconds: 0.02)
        )

        XCTAssertEqual(failure(outcome)?.reason, .processFailure)
        XCTAssertEqual(failure(outcome)?.processWasReaped, true)
    }

    func testStopReasonCannotHideCompleteForbiddenCapabilityEvents() throws {
        let cases: [(itemType: String, cancelAfter: TimeInterval?)] = [
            ("command_execution", 0.05),
            ("file_change", nil),
            ("web_search", 0.05),
        ]

        for testCase in cases {
            let forbiddenEvent = try jsonString([
                "type": "item.completed",
                "item": ["type": testCase.itemType],
            ])
            let plan = try processPlan(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "printf '%s\\n' \"$1\"; sleep 10",
                    "fixture",
                    forbiddenEvent,
                ]
            )

            let outcome = CodexCLIRunner().run(
                plan: plan,
                limits: QualificationLimits(
                    timeoutSeconds: 0.1,
                    terminationGraceSeconds: 0.05
                ),
                control: CodexRunControl(cancelAfterSeconds: testCase.cancelAfter)
            )

            XCTAssertEqual(
                failure(outcome)?.reason,
                .forbiddenCapabilityUsed,
                "a stop hid the completed \(testCase.itemType) event"
            )
        }
    }

    func testStopPathRejectsForbiddenItemsDespiteEventSchemaDrift() throws {
        let cases: [(eventType: String, cancelAfter: TimeInterval?)] = [
            ("item.completed", 0.05),
            ("future.item", nil),
        ]

        for testCase in cases {
            let forbiddenEvent = try jsonString([
                "type": testCase.eventType,
                "item": ["type": "command_execution"],
                "future_field": "schema drift",
            ])
            let plan = try processPlan(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "printf '%s\\n' \"$1\"; sleep 10",
                    "fixture",
                    forbiddenEvent,
                ]
            )

            let outcome = CodexCLIRunner().run(
                plan: plan,
                limits: QualificationLimits(
                    timeoutSeconds: 0.1,
                    terminationGraceSeconds: 0.05
                ),
                control: CodexRunControl(cancelAfterSeconds: testCase.cancelAfter)
            )

            XCTAssertEqual(
                failure(outcome)?.reason,
                .forbiddenCapabilityUsed,
                "schema drift hid a forbidden item on \(testCase.eventType)"
            )
        }
    }

    func testStopPathRejectsCompleteMalformedOrDuplicateKeyLines() throws {
        let cases: [(line: String, cancelAfter: TimeInterval?)] = [
            (
                #"{"type":"item.completed","type":"turn.started","item":{"type":"command_execution"}}"#,
                0.05
            ),
            ("not-json", nil),
        ]

        for testCase in cases {
            let plan = try processPlan(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "printf '%s\\n' \"$1\"; sleep 10",
                    "fixture",
                    testCase.line,
                ]
            )

            let outcome = CodexCLIRunner().run(
                plan: plan,
                limits: QualificationLimits(
                    timeoutSeconds: 0.1,
                    terminationGraceSeconds: 0.05
                ),
                control: CodexRunControl(cancelAfterSeconds: testCase.cancelAfter)
            )

            XCTAssertEqual(
                failure(outcome)?.reason,
                .malformedOutput,
                "a stop hid malformed complete JSONL: \(testCase.line)"
            )
        }
    }

    func testStopPathRejectsNonemptyTrailingPartialJSON() throws {
        let cases: [TimeInterval?] = [0.05, nil]
        let partialEvents = [
            #"{"type":"item.completed","item":{"type":"command_execution""#,
            #"{"type":"turn.started""#,
        ]

        for partialEvent in partialEvents {
            for cancelAfter in cases {
                let plan = try processPlan(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        "printf '%s' \"$1\"; sleep 10",
                        "fixture",
                        partialEvent,
                    ]
                )

                let outcome = CodexCLIRunner().run(
                    plan: plan,
                    limits: QualificationLimits(
                        timeoutSeconds: 0.1,
                        terminationGraceSeconds: 0.05
                    ),
                    control: CodexRunControl(cancelAfterSeconds: cancelAfter)
                )

                XCTAssertEqual(failure(outcome)?.reason, .malformedOutput)
            }
        }
    }

    func testTimeoutStartsWhileProcessIsNotReadingStandardInput() throws {
        let plan = try processPlan(
            executable: "/usr/bin/perl",
            arguments: [
                "-e",
                "select undef, undef, undef, 0.4; while (<STDIN>) {} sleep 10;",
            ],
            standardInput: Data(repeating: 0x41, count: 512 * 1_024)
        )
        let startedAt = Date()

        let outcome = CodexCLIRunner().run(
            plan: plan,
            limits: QualificationLimits(
                timeoutSeconds: 0.05,
                terminationGraceSeconds: 0.05
            )
        )

        XCTAssertEqual(failure(outcome)?.reason, .timedOut)
        XCTAssertEqual(failure(outcome)?.processWasReaped, true)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.3)
    }

    func testClosedStandardInputPipeBecomesSanitizedProcessFailure() throws {
        let plan = try processPlan(
            executable: "/usr/bin/false",
            arguments: [],
            standardInput: Data(repeating: 0x41, count: 512 * 1_024)
        )

        let outcome = CodexCLIRunner().run(plan: plan)

        XCTAssertEqual(failure(outcome)?.reason, .processFailure)
        XCTAssertEqual(failure(outcome)?.processWasReaped, true)
    }

    func testIncompleteStandardInputCannotAcceptOtherwiseValidOutput() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "A bounded response."]],
        ])
        let responseEvent = try jsonString([
            "type": "item.completed",
            "item": ["type": "agent_message", "text": response],
        ])
        let usageEvent = try jsonString([
            "type": "turn.completed",
            "usage": ["output_tokens": 2],
        ])
        let plan = try processPlan(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "exec 0<&-; printf '%s\\n' \"$1\" \"$2\"",
                "fixture",
                responseEvent,
                usageEvent,
            ],
            standardInput: Data(repeating: 0x41, count: 512 * 1_024)
        )

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .processFailure
        )
    }

    func testForkedDescendantPreventsWholeTreeReclamationProof() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-process-group-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let descendantPIDURL = fixtureDirectory.appendingPathComponent("descendant.pid")
        var descendantPID: pid_t?
        defer {
            if let descendantPID, kill(descendantPID, 0) == 0 {
                _ = kill(descendantPID, SIGKILL)
            }
        }

        let plan = try processPlan(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "/bin/sh -c 'trap \"\" TERM HUP; while :; do sleep 1; done' </dev/null >/dev/null 2>&1 & child=$!; printf '%s' \"$child\" > \"$1\"; wait",
                "fixture",
                descendantPIDURL.path,
            ]
        )
        let startedAt = Date()

        let outcome = CodexCLIRunner().run(
            plan: plan,
            limits: QualificationLimits(
                timeoutSeconds: 2,
                terminationGraceSeconds: 0.1
            ),
            control: CodexRunControl(cancelAfterSeconds: 0.1)
        )

        descendantPID = try XCTUnwrap(
            pid_t(String(decoding: Data(contentsOf: descendantPIDURL), as: UTF8.self))
        )
        XCTAssertEqual(failure(outcome)?.reason, .processFailure)
        XCTAssertEqual(failure(outcome)?.processWasReaped, false)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        XCTAssertEqual(kill(try XCTUnwrap(descendantPID), 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testDetachedDescendantHoldingPipesCannotMakeValidPrefixPass() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-detached-pipe-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let detachedPIDURL = fixtureDirectory.appendingPathComponent("detached.pid")
        var detachedPID: pid_t?
        defer {
            if let detachedPID, kill(detachedPID, 0) == 0 {
                _ = kill(-detachedPID, SIGKILL)
                _ = kill(detachedPID, SIGKILL)
                let deadline = Date().addingTimeInterval(0.5)
                while kill(detachedPID, 0) == 0, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        }

        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "A bounded response."]],
        ])
        let responseEvent = try jsonString([
            "type": "item.completed",
            "item": ["type": "agent_message", "text": response],
        ])
        let usageEvent = try jsonString([
            "type": "turn.completed",
            "usage": ["output_tokens": 2],
        ])
        let forbiddenEvent = try jsonString([
            "type": "item.completed",
            "item": ["type": "command_execution"],
        ])
        let fixtureProgram = #"""
        my ($pid_path, $response, $usage, $forbidden) = @ARGV;
        my $child = fork();
        die "fork failed" unless defined $child;
        if ($child == 0) {
            POSIX::setsid();
            $SIG{TERM} = 'IGNORE';
            $SIG{HUP} = 'IGNORE';
            open my $pid_file, '>', $pid_path or exit 2;
            print $pid_file "$$\n";
            close $pid_file;
            select undef, undef, undef, 0.15;
            syswrite STDOUT, "$forbidden\n";
            sleep 2;
            exit 0;
        }
        for (1 .. 100) {
            last if -s $pid_path;
            select undef, undef, undef, 0.01;
        }
        print "$response\n$usage\n";
        """#
        let plan = try processPlan(
            executable: "/usr/bin/perl",
            arguments: [
                "-MPOSIX",
                "-e",
                fixtureProgram,
                detachedPIDURL.path,
                responseEvent,
                usageEvent,
                forbiddenEvent,
            ]
        )
        let startedAt = Date()

        let outcome = CodexCLIRunner().run(plan: plan)

        detachedPID = try XCTUnwrap(
            pid_t(
                String(decoding: Data(contentsOf: detachedPIDURL), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        XCTAssertEqual(failure(outcome)?.reason, .processFailure)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.8)
    }

    func testDetachedContinuousWriterFailsWhenReaderShutdownIsForced() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-detached-writer-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let detachedPIDURL = fixtureDirectory.appendingPathComponent("detached.pid")
        let readerClosedURL = fixtureDirectory.appendingPathComponent("reader-closed")
        var detachedPID: pid_t?
        defer {
            if let detachedPID, kill(detachedPID, 0) == 0 {
                _ = kill(-detachedPID, SIGKILL)
                _ = kill(detachedPID, SIGKILL)
                let deadline = Date().addingTimeInterval(0.5)
                while kill(detachedPID, 0) == 0, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        }

        let fixtureProgram = #"""
        my ($pid_path, $closed_path) = @ARGV;
        my $child = fork();
        die "fork failed" unless defined $child;
        if ($child == 0) {
            POSIX::setsid();
            $SIG{TERM} = 'IGNORE';
            $SIG{HUP} = 'IGNORE';
            $SIG{PIPE} = 'IGNORE';
            open my $pid_file, '>', $pid_path or exit 2;
            print $pid_file "$$\n";
            close $pid_file;
            my $chunk = 'x' x (4 * 1024 * 1024);
            for (1 .. 2) {
                my $writer = fork();
                exit 4 unless defined $writer;
                if ($writer == 0) {
                    while (defined syswrite STDOUT, $chunk) {}
                    exit 0;
                }
            }
            while (wait() != -1) {}
            open my $closed_file, '>', $closed_path or exit 3;
            print $closed_file "closed\n";
            close $closed_file;
            exit 0;
        }
        for (1 .. 100) {
            last if -s $pid_path;
            select undef, undef, undef, 0.01;
        }
        sleep 10;
        """#
        let plan = try processPlan(
            executable: "/usr/bin/perl",
            arguments: [
                "-MPOSIX",
                "-e",
                fixtureProgram,
                detachedPIDURL.path,
                readerClosedURL.path,
            ]
        )
        let startedAt = Date()

        let outcome = CodexCLIRunner().run(
            plan: plan,
            limits: QualificationLimits(terminationGraceSeconds: 0.05)
        )

        detachedPID = try XCTUnwrap(
            pid_t(
                String(decoding: Data(contentsOf: detachedPIDURL), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        let markerDeadline = Date().addingTimeInterval(0.3)
        while !FileManager.default.fileExists(atPath: readerClosedURL.path),
              Date() < markerDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(failure(outcome)?.reason, .processFailure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: readerClosedURL.path))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.4)
    }

    func testLaunchFailureIsSanitizedAndReaped() throws {
        let plan = try processPlan(
            executable: "/synthetic/does-not-exist",
            arguments: []
        )

        let result = failure(CodexCLIRunner().run(plan: plan))

        XCTAssertEqual(result?.reason, .processFailure)
        XCTAssertEqual(result?.processWasReaped, true)
        XCTAssertFalse(String(describing: result).contains("does-not-exist"))
    }

    func testClassifiesRequiredFailureReasonsFromSyntheticSignals() {
        let cases: [(String, SanitizedFailureReason)] = [
            ("Authentication failed", .authentication),
            ("insufficient_quota", .quota),
            ("rate limit status 429", .transient),
            ("model_not_found", .unavailableModel),
            ("invalid JSON structured output", .malformedOutput),
            ("child exited unexpectedly", .processFailure),
        ]

        for (signal, expected) in cases {
            XCTAssertEqual(
                SanitizedErrorClassifier.classify(
                    standardErrorSignal: Data(signal.utf8)
                ),
                expected
            )
        }
    }

    func testStableStructuredFailureCodeWinsOverProviderProse() throws {
        let event = try jsonString([
            "type": "turn.failed",
            "error": [
                "code": "rate_limit_exceeded",
                "message": "model_not_found synthetic private detail",
            ],
        ])

        XCTAssertEqual(
            SanitizedErrorClassifier.classify(
                standardErrorSignal: Data(),
                structuredEventSignal: Data(event.utf8)
            ),
            .transient
        )
    }

    func testMapsCodexCLI0143MessageOnlyFailureEventsToClosedReasons() throws {
        let privateMarker = "synthetic-private-structured-failure"
        let cases: [([String: Any], SanitizedFailureReason)] = [
            (
                ["type": "error", "message": "Authentication failed \(privateMarker)"],
                .authentication
            ),
            (
                [
                    "type": "turn.failed",
                    "error": ["message": "insufficient quota \(privateMarker)"],
                ],
                .quota
            ),
            (
                [
                    "type": "item.completed",
                    "item": [
                        "id": "synthetic-error-item",
                        "type": "error",
                        "message": "rate limit status 429 \(privateMarker)",
                    ],
                ],
                .transient
            ),
            (
                ["type": "error", "message": "model is not available \(privateMarker)"],
                .unavailableModel
            ),
            (
                [
                    "type": "turn.failed",
                    "error": ["message": "invalid JSON structured output \(privateMarker)"],
                ],
                .malformedOutput
            ),
        ]

        for (event, expectedReason) in cases {
            let outcome = CodexCLIRunner().run(
                plan: try eventPlan(lines: [try jsonString(event)])
            )

            XCTAssertEqual(failure(outcome)?.reason, expectedReason)
            XCTAssertFalse(String(describing: outcome).contains(privateMarker))
        }
    }

    func testMapsAdditionalCodexCLI0143DisplaySignalsToClosedReasons() throws {
        let cases: [(String, SanitizedFailureReason)] = [
            ("stream disconnected before completion", .transient),
            ("Connection failed: synthetic endpoint detail", .transient),
            (
                "Codex is experiencing high demand, which can lead to temporary errors.",
                .transient
            ),
            ("Your workspace is out of credits", .quota),
            ("Your workspace has reached its spend cap", .quota),
            ("UsageNotIncluded", .quota),
            ("To use Codex with your ChatGPT plan, upgrade to Plus", .quota),
            ("Error while reading the server response", .transient),
            ("exceeded retry limit, last status: 503", .transient),
            ("Selected model is at capacity", .transient),
            (
                "Your access token could not be refreshed because the refresh token has expired, been reused, or been revoked. Please log out and sign in again.",
                .authentication
            ),
        ]

        for (message, expectedReason) in cases {
            let event = try jsonString(["type": "error", "message": message])
            XCTAssertEqual(
                SanitizedErrorClassifier.classify(
                    standardErrorSignal: Data(),
                    structuredEventSignal: Data(event.utf8)
                ),
                expectedReason,
                "unexpected mapping for a pinned 0.143 display signal"
            )
        }
    }

    func testRetryLimitStatusMaps429AndEvery5xxToTransient() {
        for status in [429] + Array(500 ... 599) {
            XCTAssertEqual(
                SanitizedErrorClassifier.classify(
                    standardErrorSignal: Data(
                        "exceeded retry limit, last status: \(status)".utf8
                    )
                ),
                .transient,
                "unexpected retry-limit mapping for HTTP \(status)"
            )
        }

        for status in [428, 430, 499, 600] {
            XCTAssertEqual(
                SanitizedErrorClassifier.classify(
                    standardErrorSignal: Data(
                        "exceeded retry limit, last status: \(status)".utf8
                    )
                ),
                .processFailure,
                "non-transient retry-limit status \(status) was accepted"
            )
        }
    }

    func testRejectsMalformedAndBoundsOversizedStructuredFailureMessages() throws {
        let malformed = try eventPlan(lines: [
            try jsonString(["type": "error", "message": true]),
        ])
        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: malformed))?.reason,
            .malformedOutput
        )

        let oversized = try eventPlan(lines: [
            try jsonString([
                "type": "error",
                "message": String(repeating: "x", count: 1_024),
            ]),
        ])
        XCTAssertEqual(
            failure(
                CodexCLIRunner().run(
                    plan: oversized,
                    limits: QualificationLimits(eventStreamByteCeiling: 128)
                )
            )?.reason,
            .responseByteLimit
        )
    }

    func testMapsAllowlistedStructuredFailureCodesToClosedReasons() throws {
        let cases: [(String, SanitizedFailureReason)] = [
            ("authentication_error", .authentication),
            ("insufficient_quota", .quota),
            ("rate_limit_exceeded", .transient),
            ("model_not_found", .unavailableModel),
            ("invalid_output_schema", .malformedOutput),
            ("unknown_future_code", .processFailure),
        ]

        for (code, expected) in cases {
            let event = try jsonString([
                "type": "turn.failed",
                "error": ["code": code, "message": "synthetic private detail"],
            ])
            XCTAssertEqual(
                SanitizedErrorClassifier.classify(
                    standardErrorSignal: Data(),
                    structuredEventSignal: Data(event.utf8)
                ),
                expected,
                "unexpected mapping for \(code)"
            )
        }
    }

    func testMapsTopLevelStructuredErrorCode() throws {
        let event = try jsonString([
            "type": "error",
            "code": "authentication_error",
            "message": "synthetic private detail",
        ])

        XCTAssertEqual(
            SanitizedErrorClassifier.classify(
                standardErrorSignal: Data(),
                structuredEventSignal: Data(event.utf8)
            ),
            .authentication
        )
    }

    func testStructuredFailureEventCannotPassAlongsideValidResponse() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "Valid response."]],
        ])
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "turn.failed",
                "error": [
                    "code": "insufficient_quota",
                    "message": "synthetic private detail",
                ],
            ]),
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": response],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["output_tokens": 2],
            ]),
        ])

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .quota
        )
    }

    func testStructuredErrorItemCannotPassAlongsideValidResponse() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "Valid response."]],
        ])
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "item.completed",
                "item": [
                    "type": "error",
                    "code": "authentication_error",
                    "message": "synthetic private detail",
                ],
            ]),
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": response],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["output_tokens": 2],
            ]),
        ])

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .authentication
        )
    }

    func testProcessFailureMapsStderrWithoutExposingIt() throws {
        let marker = "Authentication failed: synthetic-provider-detail"
        let plan = try processPlan(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s' \"$1\" >&2; exit 1", "fixture", marker]
        )

        let outcome = CodexCLIRunner().run(plan: plan)

        XCTAssertEqual(failure(outcome)?.reason, .authentication)
        XCTAssertFalse(String(describing: outcome).contains(marker))
    }

    private func eventPlan(lines: [String]) throws -> CodexInvocationPlan {
        try processPlan(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "while IFS= read -r _; do :; done; for value do printf '%s\\n' \"$value\"; done",
                "fixture",
            ] + lines,
            standardInput: Data("synthetic\n".utf8)
        )
    }

    private func processPlan(
        executable: String,
        arguments: [String],
        standardInput: Data = Data()
    ) throws -> CodexInvocationPlan {
        let directory = FileManager.default.temporaryDirectory
        return CodexInvocationPlan(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin", "TERM": "dumb"],
            workingDirectoryURL: directory,
            standardInput: standardInput
        )
    }

    private func jsonString(_ object: Any) throws -> String {
        String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    private func failure(_ outcome: CodexRunOutcome) -> SanitizedFailure? {
        guard case let .failure(failure) = outcome else { return nil }
        return failure
    }
}
