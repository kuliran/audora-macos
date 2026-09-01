@testable @_spi(CoachContextQualification) import AudoraApplication
import AudoraDomain
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

    func testAttachmentProjectionMeasuresCompleteManyWordEvidenceWithQualifiedPolicy()
        throws
    {
        let revision = try manyShortWordRevision(wordCount: 128)
        let observation = AttachmentEstimatorObservation()
        let estimator = try CoachTokenEstimator(
            identifier: "many-short-word-fixture-v1",
            mode: .exact,
            maximumUTF8BytesPerToken: 4,
            implementation: { bytes in
                observation.record(bytes)
                return bytes.count
            }
        )
        let policy = try CoachAttachmentProjectionPolicy(
            maximumInlineTranscriptTokens: 1_000,
            tokenEstimator: estimator
        )

        let evidence = ChatAttachmentEvidence(
            displayLabel: "Many short words",
            revision: revision
        )
        let projection = try policy.project(evidence: evidence)
        let candidate = try projection.makeCandidate()
        let prepared = projection.prepareAttachment(
            sessionAttachmentID: try ChatSessionAttachmentID("attachment-1"),
            transcriptHandle: try PreparedCoachTranscriptHandle(
                "00000000-0000-0000-0000-000000000001"
            )
        )
        let canonicalTranscript = CanonicalJSON.serialize(
            projection.canonicalTranscript
        )

        XCTAssertEqual(observation.values, [canonicalTranscript])
        XCTAssertEqual(candidate.approximateTranscriptTokens, canonicalTranscript.count)
        XCTAssertGreaterThan(
            candidate.approximateTranscriptTokens,
            revision.lines[0].text.utf8.count / 4
        )
        XCTAssertEqual(candidate.delivery, .onDemand)
        guard case .onDemand = prepared else {
            return XCTFail("the authoritative form must use the same delivery decision")
        }
    }

    func testAttachmentProjectionUsesInjectedExactCeilingAndProviderEstimator() throws {
        let revision = try manyShortWordRevision(wordCount: 2)
        let estimator = try CoachTokenEstimator(
            identifier: "constant-73-token-fixture-v1",
            mode: .exact,
            maximumUTF8BytesPerToken: 4,
            implementation: { _ in 73 }
        )
        let atLimit = try CoachAttachmentProjectionPolicy(
            maximumInlineTranscriptTokens: 73,
            tokenEstimator: estimator
        )
        let overLimit = try CoachAttachmentProjectionPolicy(
            maximumInlineTranscriptTokens: 72,
            tokenEstimator: estimator
        )
        let providerPolicy = CoachProviderEstimationPolicy(
            providerIdentifier: "non-default-threshold-fixture-v1",
            responseCollectorByteCeiling: 8_192,
            framing: CoachProviderFraming(),
            attachmentProjectionPolicy: atLimit
        )

        XCTAssertEqual(
            try atLimit.project(
                evidence: ChatAttachmentEvidence(
                    displayLabel: "Exact limit",
                    revision: revision
                )
            ).delivery,
            .inline
        )
        XCTAssertEqual(
            try overLimit.project(
                evidence: ChatAttachmentEvidence(
                    displayLabel: "One over",
                    revision: revision
                )
            ).delivery,
            .onDemand
        )
        XCTAssertEqual(providerPolicy.tokenEstimator.identifier, estimator.identifier)
        XCTAssertEqual(
            providerPolicy.attachmentProjectionPolicy.maximumInlineTranscriptTokens,
            73
        )
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
                attachmentProjectionPolicy: try CoachAttachmentProjectionPolicy(
                    maximumInlineTranscriptTokens: 8_192,
                    tokenEstimator: estimator
                )
            )
        )
    }

    private func manyShortWordRevision(wordCount: Int) throws -> TranscriptRevision {
        let tokens = (0..<wordCount).map { "w\($0)" }
        let lineText = tokens.joined(separator: " ")
        var cursor = 0
        let words = try tokens.enumerated().map { index, token in
            defer { cursor += token.utf8.count + 1 }
            return TranscriptWord(
                wordID: try TranscriptWordID(
                    "w" + String(format: "%06d", index)
                ),
                ordinal: index,
                text: token,
                displayRange: LineTextRange(
                    startUTF8Byte: cursor,
                    endUTF8Byte: cursor + token.utf8.count
                ),
                timeRange: nil,
                confidence: 0.95,
                wordKind: .lexical
            )
        }
        let range = try SessionTimeRange(
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            sessionDurationMilliseconds: 1_000
        )
        let fingerprint = try AudioFingerprint(sha256: String(repeating: "a", count: 64))
        let usePolicy = try EngineUsePolicy(
            policyID: "projection-test-v1",
            coveredArtifacts: [.transcriptRevision],
            privateLocalUseAllowed: true,
            privateExportAllowed: true,
            externalProcessingAllowed: false,
            publicDistributionAllowed: false,
            commercialUseAllowed: false,
            licenseReference: "test-license",
            licenseSHA256: String(repeating: "b", count: 64)
        )
        return try TranscriptRevision(
            revisionID: try TranscriptRevisionID("trv-20260830T121000000Z-4FGH"),
            sessionID: try SessionID("ses-20260830T120000000Z-3DEF"),
            jobID: try TranscriptionJobID("job-20260830T120500000Z-5GHJ"),
            createdAt: try UTCInstant("2026-08-30T12:10:00.000Z"),
            durationMilliseconds: 1_000,
            audioFingerprint: fingerprint,
            sourceFingerprints: [
                TranscriptSourceFingerprint(
                    audioSourceID: .microphone,
                    fingerprint: fingerprint
                ),
            ],
            candidateArtifactFingerprint: try AudioFingerprint(
                sha256: String(repeating: "c", count: 64)
            ),
            engine: try TranscriptEngineProvenance(
                provider: "crisperwhisper",
                model: "small",
                revision: "projection-test-v1",
                language: "en",
                mode: "verbatim",
                decodingOptionsSHA256: String(repeating: "d", count: 64),
                qualification: try TranscriptEngineQualification(
                    qualificationProfileID: "projection-test-v1",
                    engineLockSHA256: String(repeating: "e", count: 64),
                    runtimeIdentity: "projection-runtime-v1",
                    runtimeLockSHA256: String(repeating: "f", count: 64),
                    compatibilityPatchID: "projection-patch-v1"
                ),
                usePolicy: usePolicy
            ),
            lines: [
                TranscriptLine(
                    lineID: try TranscriptLineID("l000000"),
                    order: 0,
                    audioSourceID: .microphone,
                    timeRange: range,
                    text: lineText,
                    words: words
                ),
            ],
            audioEvents: []
        )
    }
}

private final class AttachmentEstimatorObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Data] = []

    var values: [Data] {
        lock.withLock { recorded }
    }

    func record(_ value: Data) {
        lock.withLock { recorded.append(value) }
    }
}
