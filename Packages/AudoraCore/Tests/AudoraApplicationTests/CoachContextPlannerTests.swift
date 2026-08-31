@testable import AudoraApplication
import Foundation
import XCTest

final class CoachContextPlannerTests: XCTestCase {
    func testCanonicalRequestSerializationIsAvailableAtTheApplicationSeam() {
        let value = CanonicalJSONValue.object([
            "z": .string("quotes \" and newlines\n"),
            "a": .integer(2),
        ])

        XCTAssertEqual(
            String(decoding: CanonicalJSON.serialize(value), as: UTF8.self),
            #"{"a":2,"z":"quotes \" and newlines\n"}"#
        )
    }

    func testTypedQuotePreservesHistoryAndDraftAndExplainsEveryCategory() throws {
        let capacity = CoachContextCapacity()
        let input = try CoachContextQuoteInput(
            profile: .object(["statements": .array([])]),
            memory: .object([
                "generalNotes": .string("Memory"),
                "sessionSummaries": .array([]),
            ]),
            history: [
                .user(text: "  exact user text\n"),
                .coach(markdownBlocks: ["First block", "Second block"]),
            ],
            currentDraft: "Current Draft",
            attachments: [
                .inline(requestValue: .object([
                    "displayLabel": .string("Small Session"),
                    "kind": .string("inline"),
                    "sessionAttachmentId": .string("attachment-small"),
                    "transcript": .object([
                        "audioEvents": .array([]),
                        "lines": .array([]),
                    ]),
                ])),
                .onDemand(
                    requestValue: .object([
                        "displayLabel": .string("Large Session"),
                        "kind": .string("onDemand"),
                        "sessionAttachmentId": .string("attachment-large"),
                        "sessionTranscriptHandle": .string(
                            "00000000-0000-0000-0000-000000000001"
                        ),
                    ]),
                    sessionTranscriptHandle: try PreparedCoachTranscriptHandle(
                        "00000000-0000-0000-0000-000000000001"
                    ),
                    transcriptDisclosure: .object([
                        "sessionAttachmentId": .string("attachment-large"),
                        "transcript": .object([
                            "audioEvents": .array([]),
                            "lines": .array([]),
                        ]),
                    ])
                ),
            ]
        )
        let configuration = try fixtureConfiguration(contextWindow: 10_000)

        let quote = try capacity.quoteChat(input, configuration: configuration)
        let prepared = try capacity.prepareForLaunch(input, configuration: configuration)

        XCTAssertEqual(quote, prepared.quote)
        XCTAssertEqual(
            Set(quote.categoryCosts.keys),
            Set(CoachContextCostCategory.allCases)
        )
        let request = String(decoding: prepared.exchange.request, as: UTF8.self)
        XCTAssertTrue(request.contains(#"{"role":"user","text":"  exact user text\n"}"#))
        XCTAssertTrue(request.contains(#"{"role":"coach","text":"First block\n\nSecond block"}"#))
        XCTAssertTrue(request.contains(#""trigger":{"kind":"userMessage","text":"Current Draft"}"#))
        XCTAssertEqual(request.components(separatedBy: "Current Draft").count - 1, 1)
        let transcriptReadRequest = try XCTUnwrap(
            prepared.exchange.transcriptReadRequest
        )
        XCTAssertTrue(
            String(decoding: transcriptReadRequest, as: UTF8.self).contains(
                "00000000-0000-0000-0000-000000000001"
            )
        )
        XCTAssertNotNil(prepared.exchange.transcriptReadResponse)
    }

    func testTranscriptHandleIsBoundedAndAuthoritativeAcrossBothPayloads() throws {
        XCTAssertThrowsError(
            try PreparedCoachTranscriptHandle(String(repeating: "a", count: 1_000_000))
        ) { error in
            XCTAssertEqual(
                error as? PreparedCoachTranscriptHandleError,
                .notCanonicalUUID
            )
        }

        let authority = try PreparedCoachTranscriptHandle(
            "00000000-0000-0000-0000-000000000001"
        )
        let attachment = PreparedCoachAttachment.onDemand(
            requestValue: .object([
                "kind": .string("onDemand"),
                "sessionTranscriptHandle": .string(
                    "00000000-0000-0000-0000-000000000002"
                ),
            ]),
            sessionTranscriptHandle: authority,
            transcriptDisclosure: .object([
                "sessionAttachmentId": .string("attachment-large"),
            ])
        )

        XCTAssertThrowsError(
            try CoachContextQuoteInput(
                profile: .object(["statements": .array([])]),
                memory: .object([
                    "generalNotes": .string(""),
                    "sessionSummaries": .array([]),
                ]),
                history: [],
                currentDraft: "Current Draft",
                attachments: [attachment]
            )
        ) { error in
            XCTAssertEqual(
                error as? CoachContextQuoteInputError,
                .attachmentTranscriptHandleMismatch
            )
        }

        XCTAssertThrowsError(
            try CoachContextPlanner().estimate(
                PreparedCoachContext(
                    profile: .object(["statements": .array([])]),
                    memory: .object([
                        "generalNotes": .string(""),
                        "sessionSummaries": .array([]),
                    ]),
                    history: [],
                    trigger: .object([
                        "kind": .string("userMessage"),
                        "text": .string("Current Draft"),
                    ]),
                    attachments: [attachment]
                ),
                descriptor: try fixtureConfiguration(
                    contextWindow: 10_000
                ).descriptor,
                policy: try fixtureConfiguration(
                    contextWindow: 10_000
                ).policy
            )
        ) { error in
            XCTAssertEqual(
                error as? CoachContextEstimationError,
                .sessionTranscriptHandleMismatch
            )
        }
    }

    func testAdvisoryCategoryCostsAreNotSummedForAuthoritativeFit() throws {
        let oneTokenPerFrame = try CoachTokenEstimator(
            identifier: "one-token-per-frame-v1",
            mode: .exact,
            maximumUTF8BytesPerToken: 1,
            implementation: { $0.isEmpty ? 0 : 1 }
        )
        let configuration = try fixtureConfiguration(
            contextWindow: 12,
            responseReserve: 4,
            safetyMargin: 2,
            estimator: oneTokenPerFrame
        )
        let input = try CoachContextQuoteInput(
            profile: .object(["statements": .array([])]),
            memory: .object([
                "generalNotes": .string(""),
                "sessionSummaries": .array([]),
            ]),
            history: [.user(text: "Earlier")],
            currentDraft: "Now"
        )

        let quote = try CoachContextCapacity().quoteChat(
            input,
            configuration: configuration
        )

        XCTAssertEqual(quote.completeInputTokens, 1)
        XCTAssertTrue(quote.fits)
        XCTAssertGreaterThan(
            quote.categoryCosts.values.reduce(0) { $0 + $1.estimatedTokenCount },
            quote.completeInputTokens
        )
    }

    func testOversizedMessageRemainsQuotableButLaunchPreparationRequestsShortening() throws {
        let text = String(
            repeating: "x",
            count: CoachContextInputLimits.maximumUserMessageUTF8Bytes + 1
        )
        let input = try CoachContextQuoteInput(
            profile: .object(["statements": .array([])]),
            memory: .object([
                "generalNotes": .string(""),
                "sessionSummaries": .array([]),
            ]),
            history: [],
            currentDraft: text
        )
        let capacity = CoachContextCapacity()
        let configuration = try fixtureConfiguration(contextWindow: 100_000)

        let quote = try capacity.quoteChat(input, configuration: configuration)
        XCTAssertEqual(
            quote.messageLength,
            .mustShorten(
                maximumUTF8Bytes: CoachContextInputLimits.maximumUserMessageUTF8Bytes
            )
        )
        XCTAssertThrowsError(
            try capacity.prepareForLaunch(input, configuration: configuration)
        ) { error in
            XCTAssertEqual(
                error as? CoachContextPreparationError,
                .messageTooLong(quote)
            )
        }
    }

    func testOneTokenOverflowProducesTypedRecoveryWithoutPreparedLaunch() throws {
        let capacity = CoachContextCapacity()
        let input = try CoachContextQuoteInput(
            profile: .object(["statements": .array([])]),
            memory: .object([
                "generalNotes": .string(""),
                "sessionSummaries": .array([]),
            ]),
            history: [],
            currentDraft: "Current Draft"
        )
        let wide = try fixtureConfiguration(contextWindow: 100_000)
        let measured = try capacity.quoteChat(input, configuration: wide)
        let exactWindow = measured.completeInputTokens
            + wide.descriptor.contextBudget.responseReservedTokens
            + wide.descriptor.contextBudget.safetyMarginTokens
        let overflow = try fixtureConfiguration(contextWindow: exactWindow - 1)

        XCTAssertThrowsError(
            try capacity.prepareForLaunch(input, configuration: overflow)
        ) { error in
            guard case let .cannotFit(failure) = error as? CoachContextPreparationError else {
                return XCTFail("expected a typed capacity failure")
            }
            XCTAssertEqual(failure.quote.completeInputTokens, measured.completeInputTokens)
            XCTAssertEqual(failure.recoveryActions, [.retry, .discard, .createNewChat])
            XCTAssertFalse(failure.quote.fits)
        }
    }

    func testAggregateInputBudgetRejectsOverflowWithoutAllocatingPayloadBytes() {
        XCTAssertTrue(
            CoachContextAggregateBudget.accepts(byteCounts: [1, 2, 3])
        )
        XCTAssertFalse(
            CoachContextAggregateBudget.accepts(byteCounts: [
                CoachContextInputLimits.maximumAggregateCanonicalUTF8Bytes,
                1,
            ])
        )
        XCTAssertFalse(
            CoachContextAggregateBudget.accepts(byteCounts: [Int.max, 1])
        )
    }

    func testCanonicalMeasurementStopsAtByteAndNestingBoundsWithoutSerializing() throws {
        XCTAssertEqual(
            try CanonicalJSON.byteCount(
                of: .object(["line": .string("one\ntwo")]),
                maximumByteCount: 64
            ),
            CanonicalJSON.serialize(.object(["line": .string("one\ntwo")])).count
        )
        XCTAssertThrowsError(
            try CanonicalJSON.byteCount(
                of: .string("escaped\ntext"),
                maximumByteCount: 4
            )
        ) { error in
            XCTAssertEqual(
                error as? CanonicalJSONMeasurementError,
                .byteLimitExceeded
            )
        }

        var nested: CanonicalJSONValue = .null
        for _ in 0 ... CanonicalJSON.maximumMeasuredNestingDepth {
            nested = .array([nested])
        }
        XCTAssertThrowsError(
            try CanonicalJSON.byteCount(of: nested, maximumByteCount: 4_096)
        ) { error in
            XCTAssertEqual(
                error as? CanonicalJSONMeasurementError,
                .nestingLimitExceeded
            )
        }
    }

    private func fixtureConfiguration(
        contextWindow: Int,
        responseReserve: Int = 32,
        safetyMargin: Int = 8,
        estimator: CoachTokenEstimator = .utf8ByteUpperBound()
    ) throws -> CoachContextConfiguration {
        try CoachContextConfiguration(
            descriptor: CoachProviderDescriptor(
                displayName: "Synthetic fixture",
                contextBudget: CoachContextBudget(
                    contextWindowTokens: contextWindow,
                    responseReservedTokens: responseReserve,
                    safetyMarginTokens: safetyMargin
                ),
                coachMemoryMaxTokens: 1
            ),
            policy: CoachProviderEstimationPolicy(
                providerIdentifier: "synthetic-fixture-v1",
                responseCollectorByteCeiling: 8_192,
                framing: CoachProviderFraming(
                    initialRequestPrefix: Data("<request>".utf8),
                    initialRequestSuffix: Data("</request>".utf8),
                    transcriptReadRequestPrefix: Data("<tool-call>".utf8),
                    transcriptReadRequestSuffix: Data("</tool-call>".utf8),
                    transcriptReadResponsePrefix: Data("<tool-result>".utf8),
                    transcriptReadResponseSuffix: Data("</tool-result>".utf8),
                    initialRequestHiddenTokens: 0,
                    transcriptReadExchangeHiddenTokens: 0
                ),
                tokenEstimator: estimator
            )
        )
    }
}
