@testable @_spi(CoachContextQualification) @_spi(ChatCreationAuthorityTesting) import AudoraApplication
import AudoraDomain
import Foundation
import XCTest

private let coachContextFixtureRevisionSHA256 = String(repeating: "1", count: 64)

final class CoachContextPlannerTests: XCTestCase {
    func testAttemptTranscriptBudgetCountsNonzeroHiddenExchangeExactlyOnce()
        throws
    {
        let estimator = try CoachTokenEstimator(
            identifier: "ascii-byte-exact-v1",
            mode: .exact,
            maximumUTF8BytesPerToken: 1,
            implementation: { $0.count }
        )
        let framing = CoachProviderFraming(
            initialRequestHiddenTokens: 2,
            transcriptReadExchangeHiddenTokens: 5
        )
        let exactAuthority = AttemptTranscriptResponseBudgetAuthority(
            inputCeilingTokens: 11,
            pinnedInstructionFrame: Data("P".utf8),
            framing: framing,
            tokenEstimator: estimator
        )
        let overflowAuthority = AttemptTranscriptResponseBudgetAuthority(
            inputCeilingTokens: 10,
            pinnedInstructionFrame: Data("P".utf8),
            framing: framing,
            tokenEstimator: estimator
        )
        let response = Data("R".utf8)

        let exact = try XCTUnwrap(
            exactAuthority.budget(
                reboundInitialRequest: Data("I".utf8),
                transcriptReadRequest: Data("Q".utf8)
            )
        )
        let overflow = try XCTUnwrap(
            overflowAuthority.budget(
                reboundInitialRequest: Data("I".utf8),
                transcriptReadRequest: Data("Q".utf8)
            )
        )

        XCTAssertTrue(try exact.admits(canonicalResponse: response))
        XCTAssertFalse(try overflow.admits(canonicalResponse: response))
    }

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

    func testPinnedInstructionContractIsExactAndTranscriptScoped() {
        XCTAssertEqual(
            CoachProviderPinnedInstruction.standard(outputTokenCeiling: 32),
            "Return one complete structured response that fits within the " +
                "32-token output allowance. Ground claims about attached " +
                "Sessions only in complete transcripts supplied inline or " +
                "returned by read_session_transcripts. When the request needs " +
                "evidence from on-demand Session attachments, request every " +
                "needed handle together in one read_session_transcripts call. " +
                "Do not split, reorder, shrink, or retry that logical read. If " +
                "a transcript read does not return complete transcripts, do " +
                "not answer around missing evidence. If you detect that you " +
                "conflated two Sessions, ask the user to send the message again " +
                "instead of presenting the answer as grounded."
        )
    }

    func testTypedQuotePreservesHistoryAndDraftAndExplainsEveryCategory() throws {
        let capacity = CoachContextCapacity()
        let input = try CoachContextQuoteInput(
            profile: .object(["statements": .array([])]),
            memory: .object([
                "generalNotes": .string("Memory"),
                "sessionSummaries": .array([
                    .object([
                        "notes": .string("Small Session summary"),
                        "sessionAttachmentId": .string("attachment-small"),
                    ]),
                ]),
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
                    ]),
                    sourceAttachment: ChatSessionAttachment(
                        attachmentID: try ChatSessionAttachmentID("attachment-large"),
                        sessionID: try SessionID("ses-20260830T120000000Z-3DEF"),
                        transcriptRevisionID: try TranscriptRevisionID(
                            "trv-20260830T121000000Z-4FGH"
                        )
                    ),
                    revisionSHA256: coachContextFixtureRevisionSHA256
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
        XCTAssertTrue(
            request.contains(
                #""memory":{"generalNotes":"Memory","sessionSummaries":[{"notes":"Small Session summary","sessionAttachmentId":"attachment-small"}]}"#
            )
        )
        XCTAssertEqual(request.components(separatedBy: "Small Session summary").count - 1, 1)
        let transcriptReadRequest = try XCTUnwrap(
            prepared.exchange.transcriptReadRequest
        )
        XCTAssertTrue(
            String(decoding: transcriptReadRequest, as: UTF8.self).contains(
                "00000000-0000-0000-0000-000000000001"
            )
        )
        XCTAssertNotNil(prepared.exchange.transcriptReadResponse)

        let expectedInstruction = CoachProviderPinnedInstruction.standard(
            outputTokenCeiling: configuration.descriptor.contextBudget
                .responseReservedTokens
        )
        XCTAssertEqual(prepared.exchange.pinnedInstruction, expectedInstruction)
        XCTAssertEqual(
            prepared.exchange.modelInputFrames.first,
            Data(expectedInstruction.utf8)
        )
        XCTAssertEqual(
            quote.completeInputTokens,
            prepared.exchange.modelInputFrames.reduce(0) { $0 + $1.count }
        )
        let budgetAuthority = try XCTUnwrap(
            prepared.exchange.transcriptResponseBudgetAuthority
        )
        let responseBudget = try XCTUnwrap(
            budgetAuthority.budget(
                reboundInitialRequest: prepared.exchange.request,
                transcriptReadRequest: transcriptReadRequest
            )
        )
        XCTAssertEqual(
            responseBudget.remainingInputTokens,
            quote.inputCeilingTokens - prepared.exchange.modelInputFrames
                .dropLast().reduce(0) { $0 + $1.count }
        )
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
            ]),
            sourceAttachment: ChatSessionAttachment(
                attachmentID: try ChatSessionAttachmentID("attachment-large"),
                sessionID: try SessionID("ses-20260830T120000000Z-3DEF"),
                transcriptRevisionID: try TranscriptRevisionID(
                    "trv-20260830T121000000Z-4FGH"
                )
            ),
            revisionSHA256: coachContextFixtureRevisionSHA256
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

        XCTAssertEqual(quote.completeInputTokens, 2)
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
            revision: revision,
            revisionSHA256: coachContextFixtureRevisionSHA256
        )
        let projection = try policy.project(evidence: evidence)
        let candidate = try projection.makeCandidate()
        let attachment = ChatSessionAttachment(
            attachmentID: try ChatSessionAttachmentID("attachment-1"),
            sessionID: evidence.sessionID,
            transcriptRevisionID: evidence.transcriptRevisionID
        )
        let prepared = try projection.prepareAttachment(
            attachment: attachment,
            transcriptHandle: try PreparedCoachTranscriptHandle(
                "00000000-0000-0000-0000-000000000001"
            )
        )
        let canonicalTranscript = CanonicalJSON.serialize(
            projection.canonicalTranscript
        )

        XCTAssertEqual(observation.values, [canonicalTranscript])
        XCTAssertEqual(
            projection.canonicalTranscriptUTF8ByteCount,
            canonicalTranscript.count
        )
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

    func testAttachmentProjectionRejectsAProviderIDForDifferentImmutableEvidence()
        throws
    {
        let evidence = ChatAttachmentEvidence(
            displayLabel: "Pinned evidence",
            revision: try manyShortWordRevision(wordCount: 1),
            revisionSHA256: coachContextFixtureRevisionSHA256
        )
        let projection = try CoachAttachmentProjectionPolicy(
            maximumInlineTranscriptTokens: 8_192,
            tokenEstimator: .utf8ByteUpperBound()
        ).project(evidence: evidence)
        let mismatchedAttachments = [
            ChatSessionAttachment(
                attachmentID: try ChatSessionAttachmentID("attachment-session"),
                sessionID: try SessionID("ses-20260830T112000000Z-7STV"),
                transcriptRevisionID: evidence.transcriptRevisionID
            ),
            ChatSessionAttachment(
                attachmentID: try ChatSessionAttachmentID("attachment-revision"),
                sessionID: evidence.sessionID,
                transcriptRevisionID: try TranscriptRevisionID(
                    "trv-20260830T113000000Z-8WXY"
                )
            ),
        ]

        for mismatchedAttachment in mismatchedAttachments {
            XCTAssertThrowsError(
                try projection.prepareAttachment(
                    attachment: mismatchedAttachment,
                    transcriptHandle: try PreparedCoachTranscriptHandle(
                        "00000000-0000-0000-0000-000000000001"
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? ChatAttachmentResolutionError,
                    .identityMismatch
                )
            }
        }
    }

    func testProviderAttachmentLabelCannotExposeLocalEvidenceIDs() throws {
        let revision = try manyShortWordRevision(wordCount: 1)
        let localDisplayLabel =
            "Practice \(revision.sessionID.rawValue) · revision "
            + revision.revisionID.rawValue
        let evidence = ChatAttachmentEvidence(
            displayLabel: localDisplayLabel,
            revision: revision,
            revisionSHA256: coachContextFixtureRevisionSHA256
        )
        let policy = try CoachAttachmentProjectionPolicy(
            maximumInlineTranscriptTokens: 8_192,
            tokenEstimator: .utf8ByteUpperBound()
        )
        let projection = try policy.project(evidence: evidence)
        let candidate = try projection.makeCandidate()
        let prepared = try projection.prepareAttachment(
            attachment: ChatSessionAttachment(
                attachmentID: try ChatSessionAttachmentID("attachment-privacy"),
                sessionID: revision.sessionID,
                transcriptRevisionID: revision.revisionID
            ),
            transcriptHandle: try PreparedCoachTranscriptHandle(
                "00000000-0000-0000-0000-000000000001"
            )
        )
        let configuration = try fixtureConfiguration(contextWindow: 100_000)
        let request = try CoachContextPlanner().estimate(
            PreparedCoachContext(
                profile: .object(["statements": .array([])]),
                memory: .object([
                    "generalNotes": .string(""),
                    "sessionSummaries": .array([]),
                ]),
                history: [],
                trigger: .object([
                    "kind": .string("userMessage"),
                    "text": .string("Review this practice"),
                ]),
                attachments: [prepared]
            ),
            descriptor: configuration.descriptor,
            policy: configuration.policy
        ).exchange.request
        let providerJSON = String(decoding: request, as: UTF8.self)

        XCTAssertEqual(candidate.displayLabel, localDisplayLabel)
        XCTAssertTrue(
            providerJSON.contains(#""displayLabel":"Practice · revision""#)
        )
        XCTAssertFalse(providerJSON.contains(revision.sessionID.rawValue))
        XCTAssertFalse(providerJSON.contains(revision.revisionID.rawValue))
    }

    func testInlineAndOnDemandProjectionExposeOnlyAllowlistedTranscriptFields()
        throws
    {
        let revision = try manyShortWordRevision(wordCount: 1)
        let evidence = ChatAttachmentEvidence(
            displayLabel: "Privacy fixture",
            revision: revision,
            revisionSHA256: coachContextFixtureRevisionSHA256
        )
        let attachment = ChatSessionAttachment(
            attachmentID: try ChatSessionAttachmentID("attachment-privacy"),
            sessionID: revision.sessionID,
            transcriptRevisionID: revision.revisionID
        )
        let handle = try PreparedCoachTranscriptHandle(
            "00000000-0000-0000-0000-000000000001"
        )
        let expectedTranscript = CanonicalJSONValue.object([
            "audioEvents": .array([]),
            "lines": .array([
                .object([
                    "text": .string("w0"),
                    "timeRange": .object([
                        "endMs": .integer(1_000),
                        "startMs": .integer(0),
                    ]),
                    "words": .array([
                        .object([
                            "text": .string("w0"),
                            "wordId": .string("w000000"),
                        ]),
                    ]),
                ]),
            ]),
        ])
        let inlineProjection = try CoachAttachmentProjectionPolicy(
            maximumInlineTranscriptTokens: 10_000,
            tokenEstimator: .utf8ByteUpperBound()
        ).project(evidence: evidence)
        let onDemandProjection = try CoachAttachmentProjectionPolicy(
            maximumInlineTranscriptTokens: 1,
            tokenEstimator: .utf8ByteUpperBound()
        ).project(evidence: evidence)

        XCTAssertEqual(inlineProjection.canonicalTranscript, expectedTranscript)
        XCTAssertEqual(onDemandProjection.canonicalTranscript, expectedTranscript)
        XCTAssertEqual(
            try inlineProjection.prepareAttachment(
                attachment: attachment,
                transcriptHandle: handle
            ),
            .inline(
                requestValue: .object([
                    "displayLabel": .string("Privacy fixture"),
                    "kind": .string("inline"),
                    "sessionAttachmentId": .string("attachment-privacy"),
                    "transcript": expectedTranscript,
                ])
            )
        )
        XCTAssertEqual(
            try onDemandProjection.prepareAttachment(
                attachment: attachment,
                transcriptHandle: handle
            ),
            .onDemand(
                requestValue: .object([
                    "displayLabel": .string("Privacy fixture"),
                    "kind": .string("onDemand"),
                    "sessionAttachmentId": .string("attachment-privacy"),
                    "sessionTranscriptHandle": .string(handle.rawValue),
                ]),
                sessionTranscriptHandle: handle,
                transcriptDisclosure: .object([
                    "sessionAttachmentId": .string("attachment-privacy"),
                    "transcript": expectedTranscript,
                ]),
                sourceAttachment: attachment,
                revisionSHA256: coachContextFixtureRevisionSHA256
            )
        )

        let providerJSON = String(
            decoding: CanonicalJSON.serialize(expectedTranscript),
            as: UTF8.self
        )
        for forbiddenValue in [
            revision.sessionID.rawValue,
            revision.revisionID.rawValue,
            revision.jobID.rawValue,
            "confidence",
            "ordinal",
            "order",
            "audioSource",
            "engine",
            "fingerprint",
            "license",
            "textualEvent",
            "rawAudio",
            "path",
        ] {
            XCTAssertFalse(providerJSON.contains(forbiddenValue), forbiddenValue)
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
                    revision: revision,
                    revisionSHA256: coachContextFixtureRevisionSHA256
                )
            ).delivery,
            .inline
        )
        XCTAssertEqual(
            try overLimit.project(
                evidence: ChatAttachmentEvidence(
                    displayLabel: "One over",
                    revision: revision,
                    revisionSHA256: coachContextFixtureRevisionSHA256
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

    func testAttachmentProjectionPreflightsCanonicalLimitBeforeSerializationOrEstimation()
        throws
    {
        let encodingObservation = AttachmentEncodingObservation()
        let estimatorObservation = AttachmentEstimatorObservation()
        let encoder = BoundedCanonicalTranscriptEncoder(
            measure: { _, maximumByteCount in
                encodingObservation.recordMeasurement(maximumByteCount)
                return maximumByteCount + 1
            },
            serialize: { _ in
                encodingObservation.recordSerialization()
                return Data("must-not-serialize".utf8)
            }
        )
        let estimator = try CoachTokenEstimator(
            identifier: "preflight-fixture-v1",
            mode: .exact,
            maximumUTF8BytesPerToken: 1,
            implementation: { bytes in
                estimatorObservation.record(bytes)
                return bytes.count
            }
        )
        let policy = try CoachAttachmentProjectionPolicy(
            maximumInlineTranscriptTokens: 8,
            tokenEstimator: estimator,
            canonicalTranscriptEncoder: encoder
        )
        let evidence = ChatAttachmentEvidence(
            displayLabel: "Over canonical limit",
            revision: try manyShortWordRevision(wordCount: 1),
            revisionSHA256: coachContextFixtureRevisionSHA256
        )

        XCTAssertThrowsError(try policy.project(evidence: evidence)) { error in
            XCTAssertEqual(
                error as? CoachAttachmentProjectionError,
                .canonicalTranscriptTooLarge
            )
        }
        XCTAssertEqual(
            encodingObservation.measuredMaximums,
            [CoachContextInputLimits.maximumCanonicalValueUTF8Bytes]
        )
        XCTAssertEqual(encodingObservation.serializationCount, 0)
        XCTAssertEqual(estimatorObservation.values, [])
    }

    func testAttachmentCatalogIsolatesUnprojectableEvidenceButExactPinsFail()
        async throws
    {
        let oversized = ChatAttachmentEvidence(
            displayLabel: "Oversized Session",
            revision: try manyShortWordRevision(
                wordCount: 2,
                sessionID: "ses-20260830T120000000Z-3DEF",
                revisionID: "trv-20260830T121000000Z-4FGH"
            ),
            revisionSHA256: coachContextFixtureRevisionSHA256
        )
        let healthy = ChatAttachmentEvidence(
            displayLabel: "Healthy Session",
            revision: try manyShortWordRevision(
                wordCount: 1,
                sessionID: "ses-20260830T112000000Z-7STV",
                revisionID: "trv-20260830T113000000Z-8WXY"
            ),
            revisionSHA256: coachContextFixtureRevisionSHA256
        )
        let oversizedAttachment = ChatSessionAttachment(
            attachmentID: try ChatSessionAttachmentID("attachment-oversized"),
            sessionID: oversized.sessionID,
            transcriptRevisionID: oversized.transcriptRevisionID
        )
        let estimator = try CoachTokenEstimator(
            identifier: "selective-oversized-fixture-v1",
            mode: .exact,
            maximumUTF8BytesPerToken: 1,
            implementation: { bytes in
                bytes.range(of: Data(#""text":"w1""#.utf8)) == nil
                    ? 17
                    : ChatAttachmentCandidate.maximumApproximateTranscriptTokens + 1
            }
        )
        let policy = try CoachAttachmentProjectionPolicy(
            maximumInlineTranscriptTokens: 8,
            tokenEstimator: estimator
        )
        let configurationAuthority =
            FixedAttachmentProjectionConfigurationAuthority(policy: policy)
        let mixedSource = ProjectedChatSessionAttachmentSource(
            evidenceSource: AttachmentEvidenceSourceFixture(
                catalog: [oversized, healthy],
                resolutions: [
                    try ResolvedChatAttachmentEvidence(
                        attachment: oversizedAttachment,
                        resolution: .available(oversized)
                    ),
                ]
            ),
            configurationAuthority: configurationAuthority
        )
        let oversizedOnlySource = ProjectedChatSessionAttachmentSource(
            evidenceSource: AttachmentEvidenceSourceFixture(
                catalog: [oversized],
                resolutions: []
            ),
            configurationAuthority: configurationAuthority
        )
        let library = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120000000Z-7NPQ")
        )

        guard case let .loaded(candidates, _) = await mixedSource.loadCandidates(
            in: library
        ) else {
            return XCTFail("one unprojectable Session must not fail the catalog")
        }
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].sessionID, healthy.sessionID)
        XCTAssertEqual(candidates[0].transcriptRevisionID, healthy.transcriptRevisionID)
        XCTAssertEqual(candidates[0].approximateTranscriptTokens, 17)
        let emptyCatalog = await oversizedOnlySource.loadCandidates(in: library)
        XCTAssertEqual(
            emptyCatalog,
            .loaded([], configuration: configurationAuthority.stamp),
            "an empty projected catalog must preserve the zero-selection path"
        )
        let pinnedResolution = await mixedSource.resolve(
            try ChatAttachments(validating: [oversizedAttachment]),
            in: library
        )
        XCTAssertEqual(
            pinnedResolution,
            .failed,
            "an exact pinned attachment must never be silently dropped"
        )
    }

    func testAttachmentCatalogFailsWhenQualifiedEstimatorMalfunctions() async throws {
        let evidence = ChatAttachmentEvidence(
            displayLabel: "Healthy Session",
            revision: try manyShortWordRevision(wordCount: 1),
            revisionSHA256: coachContextFixtureRevisionSHA256
        )
        let estimator = try CoachTokenEstimator(
            identifier: "malfunctioning-fixture-v1",
            mode: .exact,
            maximumUTF8BytesPerToken: 1,
            implementation: { _ in -1 }
        )
        let source = ProjectedChatSessionAttachmentSource(
            evidenceSource: AttachmentEvidenceSourceFixture(
                catalog: [evidence],
                resolutions: []
            ),
            configurationAuthority:
                FixedAttachmentProjectionConfigurationAuthority(
                    policy: try CoachAttachmentProjectionPolicy(
                        maximumInlineTranscriptTokens: 8,
                        tokenEstimator: estimator
                    )
                )
        )
        let library = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120000000Z-7NPQ")
        )

        let outcome = await source.loadCandidates(in: library)

        XCTAssertEqual(outcome, .failed)
    }

    func testAttachmentEvidenceIsProjectedDuringSourceTraversal() async throws {
        let first = ChatAttachmentEvidence(
            displayLabel: "First Session",
            revision: try manyShortWordRevision(
                wordCount: 1,
                sessionID: "ses-20260830T120000000Z-3DEF",
                revisionID: "trv-20260830T121000000Z-4FGH"
            ),
            revisionSHA256: coachContextFixtureRevisionSHA256
        )
        let second = ChatAttachmentEvidence(
            displayLabel: "Second Session",
            revision: try manyShortWordRevision(
                wordCount: 1,
                sessionID: "ses-20260830T122000000Z-5GHJ",
                revisionID: "trv-20260830T123000000Z-6JKM"
            ),
            revisionSHA256: coachContextFixtureRevisionSHA256
        )
        let traversal = AttachmentTraversalObservation()
        let estimator = try CoachTokenEstimator(
            identifier: "streaming-projection-fixture-v1",
            mode: .exact,
            maximumUTF8BytesPerToken: 1,
            implementation: { bytes in
                traversal.record("project:\(bytes.count)")
                return bytes.count
            }
        )
        let source = ProjectedChatSessionAttachmentSource(
            evidenceSource: AttachmentEvidenceSourceFixture(
                catalog: [first, second],
                resolutions: [],
                traversal: traversal
            ),
            configurationAuthority:
                FixedAttachmentProjectionConfigurationAuthority(
                    policy: try CoachAttachmentProjectionPolicy(
                        maximumInlineTranscriptTokens: Int.max,
                        tokenEstimator: estimator
                    )
                )
        )
        let library = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120000000Z-7NPQ")
        )

        guard case let .loaded(candidates, _) = await source.loadCandidates(
            in: library
        ) else {
            return XCTFail("expected streamed evidence to project")
        }

        XCTAssertEqual(candidates.count, 2)
        let events = traversal.events
        XCTAssertEqual(events.count, 6)
        XCTAssertEqual(events[0], "load:0")
        XCTAssertTrue(events[1].hasPrefix("project:"))
        XCTAssertEqual(events[2], "release:0")
        XCTAssertEqual(events[3], "load:1")
        XCTAssertTrue(events[4].hasPrefix("project:"))
        XCTAssertEqual(events[5], "release:1")
    }

    func testCapacityProjectionStopsTraversalWhenRunningTranscriptBudgetIsExhausted()
        async throws
    {
        let evidence = try (0 ..< 3).map { index in
            ChatAttachmentEvidence(
                displayLabel: "Session \(index)",
                revision: try manyShortWordRevision(
                    wordCount: 1,
                    sessionID: "ses-20260830T12\(index)000000Z-3DE\(index)",
                    revisionID: "trv-20260830T12\(index)100000Z-4FG\(index)"
                ),
                revisionSHA256: coachContextFixtureRevisionSHA256
            )
        }
        let attachments = try ChatAttachments(
            validating: try evidence.enumerated().map { index, item in
                ChatSessionAttachment(
                    attachmentID: try ChatSessionAttachmentID(
                        "attachment-\(index + 1)"
                    ),
                    sessionID: item.sessionID,
                    transcriptRevisionID: item.transcriptRevisionID
                )
            }
        )
        let traversal = AttachmentTraversalObservation()
        let estimator = try CoachTokenEstimator(
            identifier: "aggregate-budget-fixture-v1",
            mode: .exact,
            maximumUTF8BytesPerToken: 1,
            implementation: { bytes in
                traversal.record("project:\(bytes.count)")
                return bytes.count
            }
        )
        let policy = try CoachAttachmentProjectionPolicy(
            maximumInlineTranscriptTokens: Int.max,
            tokenEstimator: estimator
        )
        let exactTranscriptByteCount = try policy.project(
            evidence: evidence[0]
        ).canonicalTranscriptUTF8ByteCount
        let resolved = try zip(attachments.values, evidence).map { attachment, item in
            try ResolvedChatAttachmentEvidence(
                attachment: attachment,
                resolution: .available(item)
            )
        }
        let source = ProjectedChatSessionAttachmentSource(
            evidenceSource: AttachmentEvidenceSourceFixture(
                catalog: [],
                resolutions: resolved,
                traversal: traversal
            ),
            configurationAuthority:
                FixedAttachmentProjectionConfigurationAuthority(policy: policy),
            maximumAggregateCanonicalTranscriptBytes:
                exactTranscriptByteCount * 2 - 1
        )
        traversal.reset()
        let library = LibraryScope(
            libraryID: try LibraryID("lib-20260830T120000000Z-7NPQ")
        )

        let outcome = await source.prepareCapacityAttachments(
            attachments,
            in: library
        )

        guard case .invalidContext = outcome else {
            return XCTFail("aggregate transcript overflow must be invalid context")
        }
        let events = traversal.events
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events[0], "load:0")
        XCTAssertTrue(events[1].hasPrefix("project:"))
        XCTAssertEqual(events[2], "release:0")
        XCTAssertEqual(events[3], "load:1")
        XCTAssertTrue(events[4].hasPrefix("project:"))
        XCTAssertFalse(events.contains("load:2"))
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

    private func manyShortWordRevision(
        wordCount: Int,
        sessionID: String = "ses-20260830T120000000Z-3DEF",
        revisionID: String = "trv-20260830T121000000Z-4FGH"
    ) throws -> TranscriptRevision {
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
            revisionID: try TranscriptRevisionID(revisionID),
            sessionID: try SessionID(sessionID),
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

private final class AttachmentEncodingObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var maximums: [Int] = []
    private var serializations = 0

    var measuredMaximums: [Int] {
        lock.withLock { maximums }
    }

    var serializationCount: Int {
        lock.withLock { serializations }
    }

    func recordMeasurement(_ maximum: Int) {
        lock.withLock { maximums.append(maximum) }
    }

    func recordSerialization() {
        lock.withLock { serializations += 1 }
    }
}

private final class AttachmentTraversalObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var events: [String] {
        lock.withLock { recorded }
    }

    func record(_ event: String) {
        lock.withLock { recorded.append(event) }
    }

    func reset() {
        lock.withLock { recorded.removeAll() }
    }
}

private struct FixedAttachmentProjectionConfigurationAuthority:
    CoachAttachmentProjectionConfigurationAuthority
{
    let policy: CoachAttachmentProjectionPolicy
    let stamp = CoachContextConfigurationStamp(
        authorityID: UUID(uuidString: "00000000-0000-0000-0000-000000000325")!,
        generation: 1
    )

    func currentAttachmentProjectionConfiguration()
        async -> CoachAttachmentProjectionConfigurationOutcome
    {
        .configured(
            CoachAttachmentProjectionConfiguration(
                configuration: try! CoachContextConfiguration(
                    descriptor: CoachProviderDescriptor(
                        displayName: "Fixed attachment projection fixture",
                        contextBudget: CoachContextBudget(
                            contextWindowTokens: 100_000,
                            responseReservedTokens: 32,
                            safetyMarginTokens: 8
                        ),
                        coachMemoryMaxTokens: 1
                    ),
                    policy: CoachProviderEstimationPolicy(
                        providerIdentifier: "fixed-attachment-projection-v1",
                        responseCollectorByteCeiling: 8_192,
                        framing: CoachProviderFraming(),
                        attachmentProjectionPolicy: policy
                    )
                ),
                stamp: stamp
            )
        )
    }

    func isCurrent(_ candidate: CoachContextConfigurationStamp) async -> Bool {
        candidate == stamp
    }
}

private struct AttachmentEvidenceSourceFixture: ChatSessionAttachmentEvidenceSource {
    let catalog: [ChatAttachmentEvidence]
    let resolutions: [ResolvedChatAttachmentEvidence]
    var traversal: AttachmentTraversalObservation?

    init(
        catalog: [ChatAttachmentEvidence],
        resolutions: [ResolvedChatAttachmentEvidence],
        traversal: AttachmentTraversalObservation? = nil
    ) {
        self.catalog = catalog
        self.resolutions = resolutions
        self.traversal = traversal
    }

    func forEachEvidence(
        in library: LibraryScope,
        _ visit: @escaping @Sendable (ChatAttachmentEvidence) throws -> Void
    ) async -> ChatAttachmentEvidenceTraversalOutcome {
        do {
            for (index, evidence) in catalog.enumerated() {
                try Task.checkCancellation()
                traversal?.record("load:\(index)")
                try visit(evidence)
                traversal?.record("release:\(index)")
            }
            return .completed
        } catch {
            return .failed
        }
    }

    func forEachResolvedEvidence(
        _ attachments: ChatAttachments,
        in library: LibraryScope,
        _ visit: @escaping @Sendable (ResolvedChatAttachmentEvidence) throws -> Void
    ) async -> ChatAttachmentEvidenceTraversalOutcome {
        do {
            for (index, resolution) in resolutions.enumerated() {
                try Task.checkCancellation()
                traversal?.record("load:\(index)")
                try visit(resolution)
                traversal?.record("release:\(index)")
            }
            return .completedWithAuthority(
                ChatCreationEvidenceAuthority(
                    testingValue: UUID(
                        uuidString: "00000000-0000-0000-0000-000000000525"
                    )!
                )
            )
        } catch {
            return .failed
        }
    }
}
