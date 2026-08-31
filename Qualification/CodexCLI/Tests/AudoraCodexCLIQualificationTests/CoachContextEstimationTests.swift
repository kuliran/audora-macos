import Foundation
import XCTest

import AudoraApplication
@testable import AudoraCodexCLIQualification

final class CoachContextEstimationTests: XCTestCase {
    func testCanonicalSerializationOrdersKeysAndEscapesWithoutNormalizingText() {
        let value = CanonicalJSONValue.object([
            "z": .string("line\nquote\"slash\\/\u{0001} café 😀"),
            "a": .array([.integer(-2), .boolean(true), .null]),
        ])

        XCTAssertEqual(
            String(decoding: CanonicalJSON.serialize(value), as: UTF8.self),
            #"{"a":[-2,true,null],"z":"line\nquote\"slash\\/\u0001 café 😀"}"#
        )
    }

    func testCanonicalRequestIncludesEveryContextCategoryExactlyOnce() throws {
        let context = fixtureContext(attachments: [inlineAttachment()])
        let result = try planner.estimate(
            context,
            descriptor: descriptor(contextWindow: 100_000),
            policy: policy()
        )

        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: result.exchange.request) as? [String: Any]
        )
        let conversation = try XCTUnwrap(decoded["conversation"] as? [String: Any])
        let statements = try XCTUnwrap(
            (decoded["profile"] as? [String: Any])?["statements"] as? [[String: Any]]
        )
        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(statements[0]["statementId"] as? String, "p-1")
        XCTAssertEqual(statements[0]["statementKind"] as? String, "goal")
        XCTAssertEqual(statements[0]["supportingSessionCount"] as? Int, 0)
        XCTAssertEqual(statements[0]["wording"] as? String, "Speak clearly.")
        XCTAssertEqual((conversation["memory"] as? [String: Any])?["generalNotes"] as? String, "Remember this.")
        XCTAssertEqual((conversation["history"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((conversation["trigger"] as? [String: Any])?["text"] as? String, "Current draft")
        XCTAssertEqual((decoded["sessionAttachments"] as? [[String: Any]])?.count, 1)

        for component in [
            CoachContextCostCategory.profile,
            .memory,
            .history,
            .draft,
            .framing,
            .attachments,
            .responseReserve,
            .safetyMargin,
        ] {
            XCTAssertGreaterThan(
                try XCTUnwrap(result.componentCosts[component]).estimatedTokenCount,
                0,
                "missing cost for \(component)"
            )
        }
        XCTAssertEqual(result.componentCosts[.transcriptExchange]?.estimatedTokenCount, 0)
        XCTAssertEqual(result.responseCollectorByteCeiling, 8_192)
    }

    func testExactFitAndOneTokenOverflowUseWholeSerializedEnvelope() throws {
        let context = fixtureContext(attachments: [inlineAttachment()])
        let roomy = try planner.estimate(
            context,
            descriptor: descriptor(contextWindow: 100_000),
            policy: policy()
        )
        let reserve = 200
        let margin = 17
        let exactWindow = roomy.completeInputTokens + reserve + margin

        let exact = try planner.estimate(
            context,
            descriptor: descriptor(
                contextWindow: exactWindow,
                responseReserve: reserve,
                safetyMargin: margin
            ),
            policy: policy()
        )
        let overflow = try planner.estimate(
            context,
            descriptor: descriptor(
                contextWindow: exactWindow - 1,
                responseReserve: reserve,
                safetyMargin: margin
            ),
            policy: policy()
        )

        XCTAssertTrue(exact.fits)
        XCTAssertEqual(exact.completeInputTokens, exact.inputCeilingTokens)
        XCTAssertEqual(exact.totalContextTokens, exactWindow)
        XCTAssertFalse(overflow.fits)
        XCTAssertEqual(overflow.completeInputTokens, overflow.inputCeilingTokens + 1)
    }

    func testEscapingIsMeasuredAfterCanonicalSerialization() throws {
        let plain = fixtureContext(triggerText: "abcdefghij")
        let escaped = fixtureContext(triggerText: "\n\n\n\n\n\n\n\n\n\n")

        let plainEstimate = try planner.estimate(
            plain,
            descriptor: descriptor(contextWindow: 100_000),
            policy: policy()
        )
        let escapedEstimate = try planner.estimate(
            escaped,
            descriptor: descriptor(contextWindow: 100_000),
            policy: policy()
        )

        XCTAssertEqual(
            escapedEstimate.completeInputTokens - plainEstimate.completeInputTokens,
            10,
            "ten newlines each gain one JSON escape byte"
        )
        XCTAssertTrue(
            String(decoding: escapedEstimate.exchange.request, as: UTF8.self)
                .contains(#"\n\n\n\n\n\n\n\n\n\n"#)
        )
    }

    func testMultipleLargeSessionsReserveOneCompleteAtomicOnDemandExchange() throws {
        let first = try onDemandAttachment(index: 1, transcriptText: String(repeating: "alpha ", count: 200))
        let second = try onDemandAttachment(index: 2, transcriptText: String(repeating: "beta ", count: 300))
        let one = try planner.estimate(
            fixtureContext(attachments: [first]),
            descriptor: descriptor(contextWindow: 100_000),
            policy: policy()
        )
        let both = try planner.estimate(
            fixtureContext(attachments: [first, second]),
            descriptor: descriptor(contextWindow: 100_000),
            policy: policy()
        )

        XCTAssertGreaterThan(both.completeInputTokens, one.completeInputTokens)
        XCTAssertGreaterThan(
            try XCTUnwrap(both.componentCosts[.transcriptExchange]).estimatedTokenCount,
            try XCTUnwrap(one.componentCosts[.transcriptExchange]).estimatedTokenCount
        )

        let readRequest = try XCTUnwrap(both.exchange.transcriptReadRequest)
        let requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: readRequest) as? [String: Any]
        )
        XCTAssertEqual((requestObject["sessionTranscriptHandles"] as? [String])?.count, 2)

        let readResponse = try XCTUnwrap(both.exchange.transcriptReadResponse)
        let responseObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: readResponse) as? [String: Any]
        )
        XCTAssertEqual((responseObject["transcripts"] as? [[String: Any]])?.count, 2)
    }

    func testExactEstimatorPreservesProviderMessageBoundaries() throws {
        let oneTokenPerMessage = try CoachTokenEstimator(
            identifier: "one-token-per-message-fixture-v1",
            mode: .exact,
            maximumUTF8BytesPerToken: 100_000,
            implementation: { $0.isEmpty ? 0 : 1 }
        )
        let result = try planner.estimate(
            fixtureContext(attachments: [
                try onDemandAttachment(index: 1, transcriptText: "large transcript"),
            ]),
            descriptor: descriptor(contextWindow: 1_000),
            policy: policy(tokenEstimator: oneTokenPerMessage)
        )

        // Initial request, tool call, and tool result are independently framed
        // messages. Their eight configured hidden tokens are counted separately.
        XCTAssertEqual(result.exchange.modelInputFrames.count, 3)
        XCTAssertEqual(result.completeInputTokens, 11)
    }

    func testDuplicateOnDemandHandleIsRejectedBeforeEstimation() throws {
        let attachment = try onDemandAttachment(index: 1, transcriptText: "one")
        XCTAssertThrowsError(
            try planner.estimate(
                fixtureContext(attachments: [attachment, attachment]),
                descriptor: descriptor(contextWindow: 100_000),
                policy: policy()
            )
        ) { error in
            XCTAssertEqual(
                error as? CoachContextEstimationError,
                .duplicateSessionTranscriptHandle
            )
        }
    }

    func testConservativeUTF8EstimatorNeverUndercountsExactFixtureEstimator() throws {
        let exact = try CoachTokenEstimator(
            identifier: "four-byte-fixture-tokenizer-v1",
            mode: .exact,
            maximumUTF8BytesPerToken: 4,
            implementation: { ($0.count + 3) / 4 }
        )
        let conservative = CoachTokenEstimator.utf8ByteUpperBound()
        let payloads = [
            Data(),
            Data("ascii".utf8),
            CanonicalJSON.serialize(.string("quotes \" slashes \\ newlines\n")),
            CanonicalJSON.serialize(.string(String(repeating: "😀", count: 100))),
        ]

        for payload in payloads {
            XCTAssertGreaterThanOrEqual(
                try conservative.tokenCount(forUTF8: payload),
                try exact.tokenCount(forUTF8: payload)
            )
        }
        XCTAssertEqual(conservative.mode, .conservativeUpperBound)
    }

    func testMaximumMemoryQualifiesAgainstRequestResponseAndCollectorEnvelopes() throws {
        let memory = maximumMemoryFixture()
        let memoryTokens = try byteEstimator.tokenCount(
            forUTF8: CanonicalJSON.serialize(memory)
        )
        let qualified = try qualifier.qualify(
            descriptor: descriptor(
                contextWindow: 20_000,
                responseReserve: 8_000,
                safetyMargin: 100,
                memoryMax: memoryTokens
            ),
            policy: policy(responseCollectorBytes: 8_000),
            maximumMemory: memory
        )

        XCTAssertEqual(qualified.maximumMemoryTokens, memoryTokens)
        XCTAssertLessThanOrEqual(
            qualified.minimumRequestWithMaximumMemoryTokens,
            qualified.inputCeilingTokens
        )
        XCTAssertLessThanOrEqual(
            qualified.minimumResponseWithMaximumMemoryTokens,
            qualified.descriptor.contextBudget.responseReservedTokens
        )
        XCTAssertLessThanOrEqual(
            qualified.minimumResponseWithMaximumMemoryBytes,
            qualified.responseCollectorByteCeiling
        )
        XCTAssertEqual(qualified.estimatorIdentifier, "ascii-byte-exact-v1")
    }

    func testDescriptorRejectsReserveAndMarginAtOrBeyondWindow() throws {
        let memory = emptyMemory()
        let memoryTokens = try byteEstimator.tokenCount(forUTF8: CanonicalJSON.serialize(memory))

        for window in [250, 249] {
            XCTAssertThrowsError(
                try qualifier.qualify(
                    descriptor: descriptor(
                        contextWindow: window,
                        responseReserve: 200,
                        safetyMargin: 50,
                        memoryMax: memoryTokens
                    ),
                    policy: policy(),
                    maximumMemory: memory
                )
            ) { error in
                XCTAssertEqual(
                    error as? CoachProviderDescriptorValidationError,
                    .reserveAndSafetyMarginReachContextWindow
                )
            }
        }
    }

    func testDescriptorRejectsMaximumMemoryThatMissesEachEnvelope() throws {
        let memory = maximumMemoryFixture()
        let memoryTokens = try byteEstimator.tokenCount(forUTF8: CanonicalJSON.serialize(memory))
        let accepted = try qualifier.qualify(
            descriptor: descriptor(
                contextWindow: 20_000,
                responseReserve: 8_000,
                safetyMargin: 100,
                memoryMax: memoryTokens
            ),
            policy: policy(responseCollectorBytes: 8_000),
            maximumMemory: memory
        )

        XCTAssertThrowsError(
            try qualifier.qualify(
                descriptor: descriptor(
                    contextWindow: accepted.minimumRequestWithMaximumMemoryTokens + 8_000 + 100 - 1,
                    responseReserve: 8_000,
                    safetyMargin: 100,
                    memoryMax: memoryTokens
                ),
                policy: policy(responseCollectorBytes: 8_000),
                maximumMemory: memory
            )
        ) { error in
            guard case .maximumMemoryDoesNotFitMinimumRequest = error as? CoachProviderDescriptorValidationError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(
            try qualifier.qualify(
                descriptor: descriptor(
                    contextWindow: 20_000,
                    responseReserve: accepted.minimumResponseWithMaximumMemoryTokens - 1,
                    safetyMargin: 100,
                    memoryMax: memoryTokens
                ),
                policy: policy(responseCollectorBytes: 8_000),
                maximumMemory: memory
            )
        ) { error in
            guard case .maximumMemoryDoesNotFitMinimumResponseTokens = error as? CoachProviderDescriptorValidationError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(
            try qualifier.qualify(
                descriptor: descriptor(
                    contextWindow: 20_000,
                    responseReserve: 8_000,
                    safetyMargin: 100,
                    memoryMax: memoryTokens
                ),
                policy: policy(
                    responseCollectorBytes: accepted.minimumResponseWithMaximumMemoryBytes - 1
                ),
                maximumMemory: memory
            )
        ) { error in
            guard case .maximumMemoryDoesNotFitResponseCollectorBytes = error as? CoachProviderDescriptorValidationError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testDescriptorRejectsMemoryFixtureBelowDeclaredMaximum() throws {
        let memory = maximumMemoryFixture()
        let measured = try byteEstimator.tokenCount(forUTF8: CanonicalJSON.serialize(memory))

        XCTAssertThrowsError(
            try qualifier.qualify(
                descriptor: descriptor(
                    contextWindow: 20_000,
                    responseReserve: 8_000,
                    safetyMargin: 100,
                    memoryMax: measured + 1
                ),
                policy: policy(responseCollectorBytes: 8_000),
                maximumMemory: memory
            )
        ) { error in
            XCTAssertEqual(
                error as? CoachProviderDescriptorValidationError,
                .maximumMemoryFixtureTokenMismatch(declared: measured + 1, measured: measured)
            )
        }
    }

    func testCollectorQualificationUsesTokenizerWorstCaseByteBound() throws {
        var note = "x"
        var memory = memory(generalNotes: note)
        while CanonicalJSON.serialize(memory).count.isMultiple(of: 4) {
            note.append("x")
            memory = self.memory(generalNotes: note)
        }
        let fourByteEstimator = try CoachTokenEstimator(
            identifier: "four-byte-collector-fixture-v1",
            mode: .exact,
            maximumUTF8BytesPerToken: 4,
            implementation: { ($0.count + 3) / 4 }
        )
        let memoryTokens = try fourByteEstimator.tokenCount(
            forUTF8: CanonicalJSON.serialize(memory)
        )
        let generousPolicy = policy(
            responseCollectorBytes: 8_000,
            tokenEstimator: fourByteEstimator
        )
        let qualified = try qualifier.qualify(
            descriptor: descriptor(
                contextWindow: 20_000,
                responseReserve: 8_000,
                safetyMargin: 100,
                memoryMax: memoryTokens
            ),
            policy: generousPolicy,
            maximumMemory: memory
        )
        let actualFixtureBytes = CanonicalJSON.serialize(
            .object(["newMemory": memory])
        ).count

        XCTAssertGreaterThan(
            qualified.minimumResponseWithMaximumMemoryBytes,
            actualFixtureBytes
        )
        XCTAssertThrowsError(
            try qualifier.qualify(
                descriptor: qualified.descriptor,
                policy: policy(
                    responseCollectorBytes: qualified.minimumResponseWithMaximumMemoryBytes - 1,
                    tokenEstimator: fourByteEstimator
                ),
                maximumMemory: memory
            )
        ) { error in
            guard case .maximumMemoryDoesNotFitResponseCollectorBytes = error as? CoachProviderDescriptorValidationError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    private let planner = CoachContextPlanner()
    private let qualifier = CoachProviderDescriptorQualifier()

    private var byteEstimator: CoachTokenEstimator {
        try! CoachTokenEstimator(
            identifier: "ascii-byte-exact-v1",
            mode: .exact,
            maximumUTF8BytesPerToken: 1,
            implementation: { $0.count }
        )
    }

    private func descriptor(
        contextWindow: Int,
        responseReserve: Int = 200,
        safetyMargin: Int = 17,
        memoryMax: Int = 1
    ) -> CoachProviderDescriptor {
        CoachProviderDescriptor(
            displayName: "Synthetic exact estimator",
            contextBudget: CoachContextBudget(
                contextWindowTokens: contextWindow,
                responseReservedTokens: responseReserve,
                safetyMarginTokens: safetyMargin
            ),
            coachMemoryMaxTokens: memoryMax
        )
    }

    private func policy(
        responseCollectorBytes: Int = 8_192,
        tokenEstimator: CoachTokenEstimator? = nil
    ) -> CoachProviderEstimationPolicy {
        CoachProviderEstimationPolicy(
            providerIdentifier: "synthetic-provider-v1",
            responseCollectorByteCeiling: responseCollectorBytes,
            framing: CoachProviderFraming(
                initialRequestPrefix: Data("<request>".utf8),
                initialRequestSuffix: Data("</request>".utf8),
                transcriptReadRequestPrefix: Data("<tool-call>".utf8),
                transcriptReadRequestSuffix: Data("</tool-call>".utf8),
                transcriptReadResponsePrefix: Data("<tool-result>".utf8),
                transcriptReadResponseSuffix: Data("</tool-result>".utf8),
                minimumResponsePrefix: Data("<response>".utf8),
                minimumResponseSuffix: Data("</response>".utf8),
                initialRequestHiddenTokens: 3,
                transcriptReadExchangeHiddenTokens: 5,
                minimumResponseHiddenTokens: 2
            ),
            tokenEstimator: tokenEstimator ?? byteEstimator
        )
    }

    private func fixtureContext(
        triggerText: String = "Current draft",
        attachments: [PreparedCoachAttachment] = []
    ) -> PreparedCoachContext {
        PreparedCoachContext(
            profile: .object([
                "statements": .array([
                    .object([
                        "statementId": .string("p-1"),
                        "statementKind": .string("goal"),
                        "supportingSessionCount": .integer(0),
                        "wording": .string("Speak clearly."),
                    ]),
                ]),
            ]),
            memory: .object([
                "generalNotes": .string("Remember this."),
                "sessionSummaries": .array([]),
            ]),
            history: [
                .object(["role": .string("user"), "text": .string("Earlier question")]),
                .object([
                    "role": .string("coach"),
                    "text": .string("First block\n\nSecond block"),
                ]),
            ],
            trigger: .object([
                "kind": .string("userMessage"),
                "text": .string(triggerText),
            ]),
            attachments: attachments
        )
    }

    private func inlineAttachment() -> PreparedCoachAttachment {
        .inline(requestValue: .object([
            "displayLabel": .string("Inline Session"),
            "kind": .string("inline"),
            "sessionAttachmentId": .string("attachment-inline"),
            "transcript": transcript(text: "Hello, world."),
        ]))
    }

    private func onDemandAttachment(
        index: Int,
        transcriptText: String
    ) throws -> PreparedCoachAttachment {
        let handle = String(format: "00000000-0000-0000-0000-%012d", index)
        let attachmentID = "attachment-\(index)"
        return .onDemand(
            requestValue: .object([
                "displayLabel": .string("Large Session \(index)"),
                "kind": .string("onDemand"),
                "sessionAttachmentId": .string(attachmentID),
                "sessionTranscriptHandle": .string(handle),
            ]),
            sessionTranscriptHandle: try PreparedCoachTranscriptHandle(handle),
            transcriptDisclosure: .object([
                "sessionAttachmentId": .string(attachmentID),
                "transcript": transcript(text: transcriptText),
            ])
        )
    }

    private func transcript(text: String) -> CanonicalJSONValue {
        .object([
            "audioEvents": .array([]),
            "lines": .array([
                .object([
                    "text": .string(text),
                    "timeRange": .object([
                        "endMs": .integer(1_000),
                        "startMs": .integer(0),
                    ]),
                    "words": .array([
                        .object([
                            "text": .string(text),
                            "wordId": .string("word-1"),
                        ]),
                    ]),
                ]),
            ]),
        ])
    }

    private func emptyMemory() -> CanonicalJSONValue {
        memory(generalNotes: "")
    }

    private func memory(generalNotes: String) -> CanonicalJSONValue {
        .object([
            "generalNotes": .string(generalNotes),
            "sessionSummaries": .array([]),
        ])
    }

    private func maximumMemoryFixture() -> CanonicalJSONValue {
        .object([
            "generalNotes": .string(String(repeating: "memory\\\"\n", count: 256)),
            "sessionSummaries": .array([
                .object([
                    "notes": .string(String(repeating: "summary ", count: 128)),
                    "sessionAttachmentId": .string("attachment-1"),
                ]),
                .object([
                    "notes": .string(String(repeating: "other ", count: 128)),
                    "sessionAttachmentId": .string("attachment-2"),
                ]),
            ]),
        ])
    }
}

final class CompleteToolResponseBudgetTests: XCTestCase {
    func testAdmitsExactFitAndRejectsOneTokenOverflowUsingCompleteFramedResponse() throws {
        let estimator = try CoachTokenEstimator(
            identifier: "ascii-byte-exact-v1",
            mode: .exact,
            maximumUTF8BytesPerToken: 1,
            implementation: { $0.count }
        )
        let response = Data(#"{"kind":"contextCannotFit"}"#.utf8)
        let exactTokens = Data("tool-result:".utf8).count + response.count + 2

        let exact = try CompleteToolResponseBudget(
            remainingInputTokens: exactTokens,
            responsePrefix: Data("tool-result:".utf8),
            responseSuffix: Data(),
            hiddenTokens: 2,
            tokenEstimator: estimator
        )
        let overflow = try CompleteToolResponseBudget(
            remainingInputTokens: exactTokens - 1,
            responsePrefix: Data("tool-result:".utf8),
            responseSuffix: Data(),
            hiddenTokens: 2,
            tokenEstimator: estimator
        )

        XCTAssertTrue(try exact.admits(canonicalResponse: response))
        XCTAssertFalse(try overflow.admits(canonicalResponse: response))
    }
}
