@testable @_spi(CoachContextQualification) @_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
import Foundation
import XCTest

final class AttemptTranscriptAccessTests: XCTestCase {
    func testRebindChangesOnlyOnDemandDescriptorHandleField() throws {
        let fixture = try makeExchange(includeInlineHandleCanary: true)
        let fresh = try handle(101)

        let grant = try AttemptTranscriptAccessGrantIssuer().issue(
            exchange: fixture.exchange,
            freshHandles: [fresh]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: grant.exchange.request) as? [String: Any]
        )
        let attachments = try XCTUnwrap(object["sessionAttachments"] as? [[String: Any]])
        XCTAssertEqual(
            attachments[0]["transcript"] as? String,
            fixture.preparedHandles[0].rawValue,
            "an equal string outside the descriptor field must remain byte-for-byte content"
        )
        XCTAssertEqual(attachments[1]["sessionTranscriptHandle"] as? String, fresh.rawValue)
        XCTAssertFalse(
            String(decoding: grant.exchange.request, as: UTF8.self)
                .contains(#""sessionTranscriptHandle":"\#(fixture.preparedHandles[0].rawValue)""#)
        )
    }

    func testEachGrantHasFreshRedactedCapabilityAndRequiresFreshHandleBijection() throws {
        let fixture = try makeExchange()
        let first = try AttemptTranscriptAccessGrantIssuer().issue(
            exchange: fixture.exchange,
            freshHandles: [try handle(101)]
        )
        let second = try AttemptTranscriptAccessGrantIssuer().issue(
            exchange: fixture.exchange,
            freshHandles: [try handle(102)]
        )

        XCTAssertNotEqual(first.capability, second.capability)
        XCTAssertEqual(first.capability.description, "<redacted attempt transcript capability>")
        XCTAssertFalse(String(reflecting: first.capability).contains("Data"))
        XCTAssertNotEqual(first.exchange.request, second.exchange.request)

        XCTAssertThrowsError(
            try AttemptTranscriptAccessGrantIssuer().issue(
                exchange: fixture.exchange,
                freshHandles: fixture.preparedHandles
            )
        ) { error in
            XCTAssertEqual(
                error as? AttemptTranscriptAccessGrantIssueError,
                .freshHandleWasNotRebound
            )
        }
    }

    func testCapabilityFromAnotherAttemptClosesOnlyTheTargetBroker() async throws {
        let fixture = try makeExchange()
        let firstHandle = try handle(101)
        let secondHandle = try handle(102)
        let first = try AttemptTranscriptAccessGrantIssuer().issue(
            exchange: fixture.exchange,
            freshHandles: [firstHandle]
        )
        let second = try AttemptTranscriptAccessGrantIssuer().issue(
            exchange: fixture.exchange,
            freshHandles: [secondHandle]
        )

        let rejected = await first.broker.read(
            capability: second.capability,
            handles: [firstHandle]
        )

        XCTAssertEqual(rejected, .rejected(.closed))
        let firstStatus = await first.broker.status()
        XCTAssertEqual(firstStatus, .terminal(.rejected))
        guard case let .delivered(delivery) = await second.broker.read(
            capability: second.capability,
            handles: [secondHandle]
        ) else { return XCTFail("the unrelated Attempt must remain readable") }
        XCTAssertEqual(delivery.kind, .complete)
    }

    func testMalformedUnknownAndOversizedRequestsCloseWithoutDisclosure() async throws {
        let fixture = try makeExchange(attachmentCount: 2)
        let fresh = [try handle(101), try handle(102)]

        let malformedRequests: [(
            limits: AttemptTranscriptAccessLimits,
            handles: [PreparedCoachTranscriptHandle]
        )] = [
            (AttemptTranscriptAccessLimits(), [fresh[0], fresh[0]]),
            (AttemptTranscriptAccessLimits(), [try handle(999)]),
            (
                AttemptTranscriptAccessLimits(
                    maximumRequestBytes: 1,
                    maximumRequestedHandles: 2
                ),
                fresh
            ),
        ]
        for malformed in malformedRequests {
            let grant = try AttemptTranscriptAccessGrantIssuer().issue(
                exchange: fixture.exchange,
                freshHandles: fresh,
                limits: malformed.limits
            )

            let result = await grant.broker.read(
                capability: grant.capability,
                handles: malformed.handles
            )

            XCTAssertEqual(result, .rejected(.closed))
            let status = await grant.broker.status()
            XCTAssertEqual(status, .terminal(.rejected))
        }
    }

    func testCanonicalRequestByteLimitIsInclusive() async throws {
        let fixture = try makeExchange()
        let fresh = [try handle(101)]
        let requestByteCount = CanonicalJSON.serialize(
            .object([
                "sessionTranscriptHandles": .array(
                    fresh.map { .string($0.rawValue) }
                ),
            ])
        ).count
        let tooSmall = try AttemptTranscriptAccessGrantIssuer().issue(
            exchange: fixture.exchange,
            freshHandles: fresh,
            limits: AttemptTranscriptAccessLimits(
                maximumRequestBytes: requestByteCount - 1,
                maximumRequestedHandles: 1
            )
        )
        let exact = try AttemptTranscriptAccessGrantIssuer().issue(
            exchange: fixture.exchange,
            freshHandles: fresh,
            limits: AttemptTranscriptAccessLimits(
                maximumRequestBytes: requestByteCount,
                maximumRequestedHandles: 1
            )
        )

        let rejected = await tooSmall.broker.read(
            capability: tooSmall.capability,
            handles: fresh
        )
        let delivered = await exact.broker.read(
            capability: exact.capability,
            handles: fresh
        )

        XCTAssertEqual(rejected, .rejected(.closed))
        guard case .delivered = delivered else {
            return XCTFail("the exact canonical byte limit must be admitted")
        }
    }

    func testReorderedOrNarrowedSecondReadClosesTheAttempt() async throws {
        let fixture = try makeExchange(attachmentCount: 2)
        let fresh = [try handle(101), try handle(102)]
        let changedRequests = [
            [fresh[1], fresh[0]],
            [fresh[1]],
        ]

        for changedRequest in changedRequests {
            let grant = try AttemptTranscriptAccessGrantIssuer().issue(
                exchange: fixture.exchange,
                freshHandles: fresh
            )
            guard case .delivered = await grant.broker.read(
                capability: grant.capability,
                handles: fresh
            ) else { return XCTFail("the first complete batch must be delivered") }

            let changed = await grant.broker.read(
                capability: grant.capability,
                handles: changedRequest
            )

            XCTAssertEqual(changed, .rejected(.closed))
            let status = await grant.broker.status()
            XCTAssertEqual(status, .terminal(.rejected))
        }
    }

    func testSplitReadsCannotAssembleOneLogicalBatch() async throws {
        let fixture = try makeExchange(attachmentCount: 2)
        let fresh = [try handle(101), try handle(102)]
        let grant = try AttemptTranscriptAccessGrantIssuer().issue(
            exchange: fixture.exchange,
            freshHandles: fresh
        )

        guard case let .delivered(first) = await grant.broker.read(
            capability: grant.capability,
            handles: [fresh[0]]
        ) else { return XCTFail("the first requested set must be complete") }
        let second = await grant.broker.read(
            capability: grant.capability,
            handles: [fresh[1]]
        )

        let firstBody = String(decoding: first.responseBody, as: UTF8.self)
        XCTAssertTrue(firstBody.contains("private transcript 1"))
        XCTAssertFalse(firstBody.contains("private transcript 2"))
        XCTAssertEqual(second, .rejected(.closed))
        let status = await grant.broker.status()
        XCTAssertEqual(status, .terminal(.rejected))
    }

    func testUniqueSubsetIsCompleteInRequestOrderAndOnlyExactReplaySucceeds() async throws {
        let fixture = try makeExchange(attachmentCount: 2)
        let fresh = [try handle(101), try handle(102)]
        let grant = try AttemptTranscriptAccessGrantIssuer().issue(
            exchange: fixture.exchange,
            freshHandles: fresh
        )
        let requested = [fresh[1], fresh[0]]

        let first = await grant.broker.read(
            capability: grant.capability,
            handles: requested
        )
        guard case let .delivered(firstDelivery) = first else {
            return XCTFail("expected complete read")
        }
        XCTAssertEqual(firstDelivery.kind, .complete)
        XCTAssertFalse(firstDelivery.isReplay)
        XCTAssertFalse(firstDelivery.terminatesAttempt)
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: firstDelivery.responseBody) as? [String: Any]
        )
        let transcripts = try XCTUnwrap(response["transcripts"] as? [[String: Any]])
        XCTAssertEqual(
            transcripts.compactMap { $0["sessionAttachmentId"] as? String },
            ["attachment-2", "attachment-1"]
        )

        let replay = await grant.broker.read(
            capability: grant.capability,
            handles: requested
        )
        guard case let .delivered(replayDelivery) = replay else {
            return XCTFail("expected one replay")
        }
        XCTAssertTrue(replayDelivery.isReplay)
        XCTAssertTrue(replayDelivery.terminatesAttempt)
        XCTAssertEqual(replayDelivery.responseBody, firstDelivery.responseBody)

        let third = await grant.broker.read(
            capability: grant.capability,
            handles: requested
        )
        XCTAssertEqual(third, .rejected(.closed))
        let terminal = await grant.broker.status()
        XCTAssertEqual(terminal, .terminal(.completed))
    }

    func testUnavailableBatchDisclosesNoTranscriptAndRetainsOnlyStableTerminalIDs() async throws {
        let fixture = try makeExchange(attachmentCount: 2)
        let fresh = [try handle(101), try handle(102)]
        let unavailableID = try ChatSessionAttachmentID("attachment-2")
        let grant = try AttemptTranscriptAccessGrantIssuer().issue(
            exchange: fixture.exchange,
            freshHandles: fresh,
            availabilityChecker: AttemptTranscriptAvailabilityChecker { source in
                source.sessionAttachmentID == unavailableID ? .unavailable : .available
            }
        )

        let result = await grant.broker.read(
            capability: grant.capability,
            handles: fresh
        )
        guard case let .delivered(delivery) = result else {
            return XCTFail("expected terminal unavailable response")
        }
        XCTAssertEqual(delivery.kind, .sessionUnavailable)
        XCTAssertTrue(delivery.terminatesAttempt)
        let body = String(decoding: delivery.responseBody, as: UTF8.self)
        XCTAssertEqual(
            body,
            #"{"kind":"sessionUnavailable","unavailableSessionTranscriptHandles":["\#(fresh[1].rawValue)"]}"#
        )
        XCTAssertFalse(body.contains("private transcript"))
        XCTAssertFalse(body.contains("attachment-"))
        let status = await grant.broker.status()
        XCTAssertEqual(
            status,
            .terminal(
                .sessionUnavailable([
                    AttemptTranscriptFailureSession(
                        sessionAttachmentID: unavailableID,
                        displayLabel: "Session 2"
                    ),
                ])
            )
        )
        let late = await grant.broker.read(
            capability: grant.capability,
            handles: [fresh[0]]
        )
        XCTAssertEqual(late, .rejected(.closed))
    }

    func testAvailabilityIsCheckedOnceForTheCompleteOrderedBatch() async throws {
        let fixture = try makeExchange(attachmentCount: 2)
        let fresh = [try handle(101), try handle(102)]
        let probe = BatchTranscriptAvailabilityProbe()
        let grant = try AttemptTranscriptAccessGrantIssuer().issue(
            exchange: fixture.exchange,
            freshHandles: fresh,
            availabilityChecker: AttemptTranscriptAvailabilityChecker(
                batchImplementation: { sources in
                    await probe.check(sources)
                    return [.available, .unavailable]
                }
            )
        )

        let result = await grant.broker.read(
            capability: grant.capability,
            handles: fresh
        )

        guard case let .delivered(delivery) = result else {
            return XCTFail("expected one atomic unavailable result")
        }
        XCTAssertEqual(delivery.kind, .sessionUnavailable)
        XCTAssertFalse(
            String(decoding: delivery.responseBody, as: UTF8.self)
                .contains("private transcript")
        )
        let batches = await probe.batches
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(
            batches.first?.map(\.sessionAttachmentID),
            try [
                ChatSessionAttachmentID("attachment-1"),
                ChatSessionAttachmentID("attachment-2"),
            ]
        )
    }

    func testMalformedBatchAvailabilityResultClosesWithoutDisclosure() async throws {
        let fixture = try makeExchange(attachmentCount: 2)
        let fresh = [try handle(101), try handle(102)]
        let grant = try AttemptTranscriptAccessGrantIssuer().issue(
            exchange: fixture.exchange,
            freshHandles: fresh,
            availabilityChecker: AttemptTranscriptAvailabilityChecker(
                batchImplementation: { _ in [.available] }
            )
        )

        let result = await grant.broker.read(
            capability: grant.capability,
            handles: fresh
        )

        XCTAssertEqual(result, .rejected(.closed))
        let terminal = await grant.broker.status()
        XCTAssertEqual(terminal, .terminal(.rejected))
    }

    func testBudgetFailureAndExplicitRevocationTerminateWithoutTranscript() async throws {
        let fixture = try makeExchange(inputCeilingTokens: 0)
        let fresh = [try handle(101)]
        let budgetGrant = try AttemptTranscriptAccessGrantIssuer().issue(
            exchange: fixture.exchange,
            freshHandles: fresh
        )

        let result = await budgetGrant.broker.read(
            capability: budgetGrant.capability,
            handles: fresh
        )
        guard case let .delivered(delivery) = result else {
            return XCTFail("expected contextCannotFit")
        }
        XCTAssertEqual(delivery.kind, .contextCannotFit)
        XCTAssertEqual(
            String(decoding: delivery.responseBody, as: UTF8.self),
            #"{"kind":"contextCannotFit"}"#
        )
        let budgetStatus = await budgetGrant.broker.status()
        XCTAssertEqual(budgetStatus, .terminal(.contextCannotFit))

        let revokedGrant = try AttemptTranscriptAccessGrantIssuer().issue(
            exchange: fixture.exchange,
            freshHandles: [try handle(102)]
        )
        await revokedGrant.broker.revoke(reason: .cancelled)
        let revokedStatus = await revokedGrant.broker.status()
        XCTAssertEqual(revokedStatus, .terminal(.revoked(.cancelled)))
        let late = await revokedGrant.broker.read(
            capability: revokedGrant.capability,
            handles: [try handle(102)]
        )
        XCTAssertEqual(late, .rejected(.closed))
    }

    func testConcurrentExactReadSharesOneAvailabilityCheckAndAllowsOneReplay()
        async throws
    {
        let fixture = try makeExchange()
        let fresh = [try handle(101)]
        let availability = SuspendingTranscriptAvailability()
        let grant = try AttemptTranscriptAccessGrantIssuer().issue(
            exchange: fixture.exchange,
            freshHandles: fresh,
            availabilityChecker: AttemptTranscriptAvailabilityChecker { source in
                await availability.check(source.sessionAttachmentID)
            }
        )
        let first = Task {
            await grant.broker.read(
                capability: grant.capability,
                handles: fresh
            )
        }
        await availability.waitUntilStarted()
        let second = Task {
            await grant.broker.read(
                capability: grant.capability,
                handles: fresh
            )
        }
        await Task.yield()
        await availability.release(with: .available)

        let results = [await first.value, await second.value]
        let deliveries = results.compactMap { result -> AttemptTranscriptAccessDelivery? in
            guard case let .delivered(delivery) = result else { return nil }
            return delivery
        }
        XCTAssertEqual(deliveries.count, 2)
        XCTAssertEqual(deliveries.filter(\.isReplay).count, 1)
        let checkCount = await availability.checkCount
        let terminal = await grant.broker.status()
        XCTAssertEqual(checkCount, 1)
        XCTAssertEqual(terminal, .terminal(.completed))
    }

    func testAtomicFinalizeWinsAgainstSuspendedAvailabilityWithoutDisclosure()
        async throws
    {
        let fixture = try makeExchange()
        let fresh = [try handle(101)]
        let availability = SuspendingTranscriptAvailability()
        let grant = try AttemptTranscriptAccessGrantIssuer().issue(
            exchange: fixture.exchange,
            freshHandles: fresh,
            availabilityChecker: AttemptTranscriptAvailabilityChecker { source in
                await availability.check(source.sessionAttachmentID)
            }
        )
        let read = Task {
            await grant.broker.read(
                capability: grant.capability,
                handles: fresh
            )
        }
        await availability.waitUntilStarted()

        let prior = await grant.broker.finalize(reason: .cancelled)
        await availability.release(with: .available)

        let result = await read.value
        let terminal = await grant.broker.status()
        XCTAssertEqual(prior, .checking)
        XCTAssertEqual(result, .rejected(.closed))
        XCTAssertEqual(terminal, .terminal(.revoked(.cancelled)))
    }

    func testClosingProviderGateDuringSuspendedReadReturnsNoTranscriptBytes()
        async throws
    {
        let fixture = try makeExchange()
        let fresh = [try handle(101)]
        let availability = SuspendingTranscriptAvailability()
        let grant = try AttemptTranscriptAccessGrantIssuer().issue(
            exchange: fixture.exchange,
            freshHandles: fresh,
            availabilityChecker: AttemptTranscriptAvailabilityChecker { source in
                await availability.check(source.sessionAttachmentID)
            }
        )
        let access = ProviderAttemptTranscriptAccess(grant: grant)
        let read = Task {
            await access.read(
                transportRequestID: AttemptTranscriptTransportRequestID("read-1")!,
                handles: fresh
            )
        }
        await availability.waitUntilStarted()

        access.closeReads()
        await availability.release(with: .available)

        let result = await read.value
        XCTAssertEqual(result, .rejected(.closed))
    }

    func testFinalizeReturnsReplayableThenClosesAtomically() async throws {
        let fixture = try makeExchange()
        let fresh = [try handle(101)]
        let grant = try AttemptTranscriptAccessGrantIssuer().issue(
            exchange: fixture.exchange,
            freshHandles: fresh
        )
        guard case .delivered = await grant.broker.read(
            capability: grant.capability,
            handles: fresh
        ) else { return XCTFail("the first read must complete") }

        let prior = await grant.broker.finalize(reason: .attemptCompleted)
        let late = await grant.broker.read(
            capability: grant.capability,
            handles: fresh
        )
        let terminal = await grant.broker.status()

        XCTAssertEqual(prior, .replayable)
        XCTAssertEqual(late, .rejected(.closed))
        XCTAssertEqual(terminal, .terminal(.revoked(.attemptCompleted)))
    }

    func testFinalizePreservesExistingTranscriptFailure() async throws {
        let fixture = try makeExchange()
        let fresh = [try handle(101)]
        let grant = try AttemptTranscriptAccessGrantIssuer().issue(
            exchange: fixture.exchange,
            freshHandles: fresh,
            availabilityChecker: AttemptTranscriptAvailabilityChecker { _ in
                .unavailable
            }
        )
        guard case .delivered = await grant.broker.read(
            capability: grant.capability,
            handles: fresh
        ) else { return XCTFail("the unavailable result must be delivered atomically") }
        let expected = await grant.broker.status()

        let prior = await grant.broker.finalize(reason: .attemptCompleted)
        let terminal = await grant.broker.status()

        XCTAssertEqual(prior, expected)
        XCTAssertEqual(terminal, expected)
    }
}

private actor SuspendingTranscriptAvailability {
    private var continuation:
        CheckedContinuation<AttemptTranscriptAvailability, Never>?
    private(set) var checkCount = 0

    func check(
        _ attachmentID: ChatSessionAttachmentID
    ) async -> AttemptTranscriptAvailability {
        checkCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }

    func release(with availability: AttemptTranscriptAvailability) {
        continuation?.resume(returning: availability)
        continuation = nil
    }
}

private actor BatchTranscriptAvailabilityProbe {
    private(set) var batches: [[AttemptTranscriptSourceIdentity]] = []

    func check(_ sources: [AttemptTranscriptSourceIdentity]) {
        batches.append(sources)
    }
}

private extension AttemptTranscriptAccessTests {
    struct ExchangeFixture {
        let exchange: CanonicalCoachExchange
        let preparedHandles: [PreparedCoachTranscriptHandle]
    }

    func makeExchange(
        attachmentCount: Int = 1,
        includeInlineHandleCanary: Bool = false,
        inputCeilingTokens: Int = 1_000_000
    ) throws -> ExchangeFixture {
        let preparedHandles = try (1 ... attachmentCount).map(handle)
        var attachments: [CanonicalJSONValue] = []
        if includeInlineHandleCanary {
            attachments.append(
                .object([
                    "displayLabel": .string("Inline"),
                    "kind": .string("inline"),
                    "sessionAttachmentId": .string("inline-attachment"),
                    "transcript": .string(preparedHandles[0].rawValue),
                ])
            )
        }

        var routes: [CanonicalCoachTranscriptRoute] = []
        var disclosures: [CanonicalJSONValue] = []
        for index in 0 ..< attachmentCount {
            let attachmentID = "attachment-\(index + 1)"
            let disclosure = CanonicalJSONValue.object([
                "sessionAttachmentId": .string(attachmentID),
                "transcript": .object([
                    "audioEvents": .array([]),
                    "lines": .array([
                        .object([
                            "text": .string("private transcript \(index + 1)"),
                            "timeRange": .object([
                                "endMs": .integer(100),
                                "startMs": .integer(0),
                            ]),
                            "words": .array([
                                .object([
                                    "text": .string("private"),
                                    "wordId": .string("w00000\(index)"),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ])
            let requestIndex = attachments.count
            attachments.append(
                .object([
                    "displayLabel": .string("Session \(index + 1)"),
                    "kind": .string("onDemand"),
                    "sessionAttachmentId": .string(attachmentID),
                    "sessionTranscriptHandle": .string(preparedHandles[index].rawValue),
                ])
            )
            disclosures.append(disclosure)
            let sourceAttachment = ChatSessionAttachment(
                attachmentID: try ChatSessionAttachmentID(attachmentID),
                sessionID: try SessionID(
                    "ses-20260830T12000000\(index)Z-3DEF"
                ),
                transcriptRevisionID: try TranscriptRevisionID(
                    "trv-20260830T12100000\(index)Z-4FGH"
                )
            )
            routes.append(
                CanonicalCoachTranscriptRoute(
                    requestAttachmentIndex: requestIndex,
                    preparedHandle: preparedHandles[index],
                    disclosure: disclosure,
                    sourceAttachment: sourceAttachment,
                    revisionSHA256: String(repeating: "1", count: 64)
                )
            )
        }

        let request = CanonicalJSONValue.object([
            "conversation": .object([
                "history": .array([]),
                "memory": .object([:]),
                "trigger": .object([:]),
            ]),
            "profile": .object([:]),
            "sessionAttachments": .array(attachments),
        ])
        let readRequest = CanonicalJSONValue.object([
            "sessionTranscriptHandles": .array(
                preparedHandles.map { .string($0.rawValue) }
            ),
        ])
        let readResponse = CanonicalJSONValue.object([
            "kind": .string("complete"),
            "transcripts": .array(disclosures),
        ])
        return ExchangeFixture(
            exchange: CanonicalCoachExchange(
                pinnedInstruction: "",
                request: CanonicalJSON.serialize(request),
                transcriptReadRequest: CanonicalJSON.serialize(readRequest),
                transcriptReadResponse: CanonicalJSON.serialize(readResponse),
                modelInputFrames: [],
                completeModelInput: Data(),
                preparedTranscriptHandles: preparedHandles,
                structuralRequest: request,
                preparedTranscriptRoutes: routes,
                transcriptResponseBudgetAuthority:
                    AttemptTranscriptResponseBudgetAuthority(
                        inputCeilingTokens: inputCeilingTokens,
                        pinnedInstructionFrame: Data(),
                        framing: CoachProviderFraming(),
                        tokenEstimator: .utf8ByteUpperBound()
                    )
            ),
            preparedHandles: preparedHandles
        )
    }

    func handle(_ ordinal: Int) throws -> PreparedCoachTranscriptHandle {
        try PreparedCoachTranscriptHandle(
            String(format: "00000000-0000-0000-0000-%012d", ordinal)
        )
    }

}
