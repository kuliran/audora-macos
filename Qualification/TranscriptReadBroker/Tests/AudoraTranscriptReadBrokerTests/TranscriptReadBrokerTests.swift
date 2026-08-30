import AudoraCodexCLIQualification
@testable import AudoraTranscriptReadBroker
import Darwin
import Foundation
import XCTest

final class TranscriptReadBrokerTests: XCTestCase {
    func testEachGrantIssuesFreshCanonicalHandlesAndCapability() async throws {
        let first = try makeGrant()
        let second = try makeGrant()

        XCTAssertNotEqual(first.capability, second.capability)
        XCTAssertEqual(first.providerAttachments.count, 2)
        XCTAssertEqual(second.providerAttachments.count, 2)
        XCTAssertTrue(first.providerAttachments.allSatisfy { isCanonicalHandle($0.sessionTranscriptHandle) })
        XCTAssertTrue(second.providerAttachments.allSatisfy { isCanonicalHandle($0.sessionTranscriptHandle) })
        XCTAssertTrue(
            Set(first.providerAttachments.map(\.sessionTranscriptHandle))
                .isDisjoint(with: Set(second.providerAttachments.map(\.sessionTranscriptHandle)))
        )

        let foreignRequest = requestBody(handles: [
            second.providerAttachments[0].sessionTranscriptHandle,
        ])
        let result = await second.broker.read(
            capability: first.capability,
            requestBody: foreignRequest
        )
        XCTAssertEqual(result, .rejected(.closed))
    }

    func testOneUniqueSubsetReturnsOnlyCompleteRequestedTranscriptsInRequestOrder() async throws {
        let grant = try makeGrant()
        let requested = [
            grant.providerAttachments[1].sessionTranscriptHandle,
            grant.providerAttachments[0].sessionTranscriptHandle,
        ]

        let result = await grant.broker.read(
            capability: grant.capability,
            requestBody: requestBody(handles: requested)
        )
        guard case let .delivered(delivery) = result else {
            return XCTFail("expected a complete delivery")
        }
        XCTAssertEqual(delivery.kind, .complete)
        XCTAssertFalse(delivery.isReplay)
        XCTAssertFalse(delivery.terminatesAttempt)

        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: delivery.responseBody) as? [String: Any]
        )
        XCTAssertEqual(response["kind"] as? String, "complete")
        let transcripts = try XCTUnwrap(response["transcripts"] as? [[String: Any]])
        XCTAssertEqual(
            transcripts.compactMap { $0["sessionAttachmentId"] as? String },
            ["attachment-b", "attachment-a"]
        )
        XCTAssertEqual(transcripts.count, 2)

        let providerText = String(decoding: delivery.responseBody, as: UTF8.self)
        XCTAssertFalse(providerText.contains("local-session"))
        XCTAssertFalse(providerText.contains("revision-"))
        XCTAssertFalse(providerText.contains("Synthetic A"))
        XCTAssertFalse(providerText.contains("Synthetic B"))
        XCTAssertFalse(providerText.contains("durationMs"))
    }

    func testInvalidRequestShapesFailClosedBeforeStorageAndRevokeTheGrant() async throws {
        let cases: [(String, (AttemptTranscriptGrant) -> Data)] = [
            ("empty", { _ in Data(#"{"sessionTranscriptHandles":[]}"#.utf8) }),
            ("duplicate", { grant in
                let handle = grant.providerAttachments[0].sessionTranscriptHandle
                return self.requestBody(handles: [handle, handle])
            }),
            ("uppercase", { grant in
                self.requestBody(handles: [
                    grant.providerAttachments[0].sessionTranscriptHandle.uppercased(),
                ])
            }),
            ("unknown field", { grant in
                let handle = grant.providerAttachments[0].sessionTranscriptHandle
                return Data(
                    #"{"path":"/private/canary","sessionTranscriptHandles":["\#(handle)"]}"#.utf8
                )
            }),
            ("null", { _ in Data(#"{"sessionTranscriptHandles":null}"#.utf8) }),
            ("wrong type", { _ in Data(#"{"sessionTranscriptHandles":"not-an-array"}"#.utf8) }),
            ("duplicate object key", { grant in
                let handle = grant.providerAttachments[0].sessionTranscriptHandle
                return Data(
                    #"{"sessionTranscriptHandles":["\#(handle)"],"sessionTranscriptHandles":["\#(handle)"]}"#.utf8
                )
            }),
            ("batch", { _ in Data(#"[{"sessionTranscriptHandles":[]}]"#.utf8) }),
        ]

        for (name, body) in cases {
            let readCount = LockedCounter()
            let grant = try makeGrant(readCount: readCount)
            let result = await grant.broker.read(
                capability: grant.capability,
                requestBody: body(grant)
            )
            XCTAssertEqual(result, .rejected(.closed), name)
            XCTAssertEqual(readCount.value, 0, name)
            let status = await grant.broker.status()
            XCTAssertEqual(status, .revoked, name)
        }
    }

    func testOversizedOverCountUnknownAndMixedScopeRequestsReadNothing() async throws {
        let oversizedCount = LockedCounter()
        let oversized = try makeGrant(
            readCount: oversizedCount,
            limits: TranscriptReadBrokerLimits(
                maximumRequestBytes: 32,
                maximumRequestedHandles: 2,
                maximumDeliveries: 2
            )
        )
        let oversizedResult = await oversized.broker.read(
            capability: oversized.capability,
            requestBody: requestBody(handles: [
                oversized.providerAttachments[0].sessionTranscriptHandle,
            ])
        )
        XCTAssertEqual(oversizedResult, .rejected(.closed))
        XCTAssertEqual(oversizedCount.value, 0)

        let overCount = LockedCounter()
        let counted = try makeGrant(
            readCount: overCount,
            limits: TranscriptReadBrokerLimits(
                maximumRequestBytes: 16 * 1_024,
                maximumRequestedHandles: 2,
                maximumDeliveries: 2
            )
        )
        let thirdHandle = "00000000-0000-4000-8000-000000000003"
        let countedResult = await counted.broker.read(
            capability: counted.capability,
            requestBody: requestBody(handles: [
                counted.providerAttachments[0].sessionTranscriptHandle,
                counted.providerAttachments[1].sessionTranscriptHandle,
                thirdHandle,
            ])
        )
        XCTAssertEqual(countedResult, .rejected(.closed))
        XCTAssertEqual(overCount.value, 0)

        for handles in [
            ["00000000-0000-4000-8000-000000000004"],
            [
                "valid-placeholder",
                "00000000-0000-4000-8000-000000000005",
            ],
        ] {
            let count = LockedCounter()
            let grant = try makeGrant(readCount: count)
            let actualHandles = handles.map {
                $0 == "valid-placeholder"
                    ? grant.providerAttachments[0].sessionTranscriptHandle
                    : $0
            }
            let result = await grant.broker.read(
                capability: grant.capability,
                requestBody: requestBody(handles: actualHandles)
            )
            XCTAssertEqual(result, .rejected(.closed))
            XCTAssertEqual(count.value, 0)
        }
    }

    func testUnavailableMemberReturnsNoPartialTranscriptAndRevokes() async throws {
        let count = LockedCounter()
        let grant = try makeGrant(
            secondResult: .unavailable,
            readCount: count
        )
        let handles = grant.providerAttachments.map(\.sessionTranscriptHandle)

        let result = await grant.broker.read(
            capability: grant.capability,
            requestBody: requestBody(handles: handles)
        )
        guard case let .delivered(delivery) = result else {
            return XCTFail("expected a terminal provider response")
        }
        XCTAssertEqual(delivery.kind, .sessionUnavailable)
        XCTAssertTrue(delivery.terminatesAttempt)
        XCTAssertEqual(count.value, 2)
        let status = await grant.broker.status()
        XCTAssertEqual(status, .revoked)

        let text = String(decoding: delivery.responseBody, as: UTF8.self)
        XCTAssertEqual(
            text,
            #"{"kind":"sessionUnavailable","unavailableSessionTranscriptHandles":["\#(handles[1])"]}"#
        )
        XCTAssertFalse(text.contains("Synthetic alpha"))
        XCTAssertFalse(text.contains("attachment-a"))
    }

    func testCorruptTranscriptAndStorageErrorAreSanitizedAsUnavailable() async throws {
        let corrupt = SessionTranscriptProjection(
            durationMs: 1_000,
            lines: [
                TranscriptLine(
                    timeRange: TranscriptTimeRange(startMs: 100, endMs: 10),
                    text: "private transcript canary",
                    words: []
                ),
            ],
            audioEvents: []
        )
        let corruptGrant = try makeGrant(firstResult: .available(corrupt))
        let corruptHandle = corruptGrant.providerAttachments[0].sessionTranscriptHandle
        let corruptResult = await corruptGrant.broker.read(
            capability: corruptGrant.capability,
            requestBody: requestBody(handles: [corruptHandle])
        )
        guard case let .delivered(corruptDelivery) = corruptResult else {
            return XCTFail("expected corrupt storage to become unavailable")
        }
        XCTAssertEqual(corruptDelivery.kind, .sessionUnavailable)
        XCTAssertFalse(
            String(decoding: corruptDelivery.responseBody, as: UTF8.self)
                .contains("private transcript canary")
        )

        let throwingReader = FrozenTranscriptReader { _ in
            throw SyntheticStorageError.message(
                "private transcript /Library/canary token=do-not-disclose"
            )
        }
        let throwingGrant = try makeGrant(reader: throwingReader)
        let throwingHandle = throwingGrant.providerAttachments[0].sessionTranscriptHandle
        let throwingResult = await throwingGrant.broker.read(
            capability: throwingGrant.capability,
            requestBody: requestBody(handles: [throwingHandle])
        )
        guard case let .delivered(throwingDelivery) = throwingResult else {
            return XCTFail("expected storage failure to become unavailable")
        }
        let throwingText = String(decoding: throwingDelivery.responseBody, as: UTF8.self)
        XCTAssertEqual(throwingDelivery.kind, .sessionUnavailable)
        XCTAssertFalse(throwingText.contains("private transcript"))
        XCTAssertFalse(throwingText.contains("Library"))
        XCTAssertFalse(throwingText.contains("token"))
    }

    func testStrictHalfOpenAndContainmentViolationsDiscloseNoTranscript() async throws {
        let validLine = TranscriptTimeRange(startMs: 100, endMs: 900)
        let validWord = TranscriptTimeRange(startMs: 200, endMs: 300)
        let validEvent = TranscriptTimeRange(startMs: 400, endMs: 500)
        let makeProjection: (
            Int,
            TranscriptTimeRange,
            TranscriptTimeRange?,
            TranscriptTimeRange
        ) -> SessionTranscriptProjection = { duration, lineRange, wordRange, eventRange in
            SessionTranscriptProjection(
                durationMs: duration,
                lines: [
                    TranscriptLine(
                        timeRange: lineRange,
                        text: "private range transcript canary",
                        words: [
                            TranscriptWord(
                                wordID: "range-word",
                                text: "private",
                                timeRange: wordRange
                            ),
                        ]
                    ),
                ],
                audioEvents: [
                    TranscriptAudioEvent(
                        audioEventID: "range-event",
                        category: .nonSpeech,
                        timeRange: eventRange
                    ),
                ]
            )
        }
        let cases: [(String, SessionTranscriptProjection)] = [
            (
                "zero session duration",
                makeProjection(0, TranscriptTimeRange(startMs: 0, endMs: 1), nil, validEvent)
            ),
            (
                "session duration beyond canonical int32",
                makeProjection(
                    Int(Int32.max) + 1,
                    validLine,
                    validWord,
                    validEvent
                )
            ),
            (
                "zero-length line",
                makeProjection(
                    1_000,
                    TranscriptTimeRange(startMs: 100, endMs: 100),
                    nil,
                    validEvent
                )
            ),
            (
                "reversed line",
                makeProjection(
                    1_000,
                    TranscriptTimeRange(startMs: 200, endMs: 100),
                    nil,
                    validEvent
                )
            ),
            (
                "negative line start",
                makeProjection(
                    1_000,
                    TranscriptTimeRange(startMs: -1, endMs: 100),
                    nil,
                    validEvent
                )
            ),
            (
                "line beyond duration",
                makeProjection(
                    1_000,
                    TranscriptTimeRange(startMs: 100, endMs: 1_001),
                    nil,
                    validEvent
                )
            ),
            (
                "zero-length word",
                makeProjection(
                    1_000,
                    validLine,
                    TranscriptTimeRange(startMs: 200, endMs: 200),
                    validEvent
                )
            ),
            (
                "reversed word",
                makeProjection(
                    1_000,
                    validLine,
                    TranscriptTimeRange(startMs: 300, endMs: 200),
                    validEvent
                )
            ),
            (
                "word starts before parent line",
                makeProjection(
                    1_000,
                    validLine,
                    TranscriptTimeRange(startMs: 99, endMs: 200),
                    validEvent
                )
            ),
            (
                "negative word start",
                makeProjection(
                    1_000,
                    validLine,
                    TranscriptTimeRange(startMs: -1, endMs: 200),
                    validEvent
                )
            ),
            (
                "word ends after parent line",
                makeProjection(
                    1_000,
                    validLine,
                    TranscriptTimeRange(startMs: 800, endMs: 901),
                    validEvent
                )
            ),
            (
                "zero-length audio event",
                makeProjection(
                    1_000,
                    validLine,
                    validWord,
                    TranscriptTimeRange(startMs: 400, endMs: 400)
                )
            ),
            (
                "reversed audio event",
                makeProjection(
                    1_000,
                    validLine,
                    validWord,
                    TranscriptTimeRange(startMs: 500, endMs: 400)
                )
            ),
            (
                "negative audio event start",
                makeProjection(
                    1_000,
                    validLine,
                    validWord,
                    TranscriptTimeRange(startMs: -1, endMs: 400)
                )
            ),
            (
                "audio event beyond duration",
                makeProjection(
                    1_000,
                    validLine,
                    validWord,
                    TranscriptTimeRange(startMs: 900, endMs: 1_001)
                )
            ),
        ]

        for (name, projection) in cases {
            let grant = try makeGrant(firstResult: .available(projection))
            let handles = grant.providerAttachments.map(\.sessionTranscriptHandle)
            let result = await grant.broker.read(
                capability: grant.capability,
                requestBody: requestBody(handles: handles)
            )
            guard case let .delivered(delivery) = result else {
                XCTFail("expected unavailable: \(name)")
                continue
            }
            XCTAssertEqual(delivery.kind, .sessionUnavailable, name)
            XCTAssertTrue(delivery.terminatesAttempt, name)
            XCTAssertEqual(
                String(decoding: delivery.responseBody, as: UTF8.self),
                #"{"kind":"sessionUnavailable","unavailableSessionTranscriptHandles":["\#(handles[0])"]}"#,
                name
            )
            let providerText = String(decoding: delivery.responseBody, as: UTF8.self)
            XCTAssertFalse(providerText.contains("private range transcript canary"), name)
            XCTAssertFalse(providerText.contains("Synthetic beta"), name)
            XCTAssertFalse(providerText.contains("attachment-b"), name)
            let status = await grant.broker.status()
            XCTAssertEqual(status, .revoked, name)
        }
    }

    func testUntimedWordRemainsValidAndOmitsOnlyItsOptionalRange() async throws {
        let projection = SessionTranscriptProjection(
            durationMs: 500,
            lines: [
                TranscriptLine(
                    timeRange: TranscriptTimeRange(startMs: 0, endMs: 500),
                    text: "Untimed word.",
                    words: [
                        TranscriptWord(wordID: "untimed-word", text: "Untimed", timeRange: nil),
                    ]
                ),
            ],
            audioEvents: []
        )
        let grant = try makeGrant(firstResult: .available(projection))
        let handle = grant.providerAttachments[0].sessionTranscriptHandle
        let result = await grant.broker.read(
            capability: grant.capability,
            requestBody: requestBody(handles: [handle])
        )
        guard case let .delivered(delivery) = result else {
            return XCTFail("expected complete untimed-word projection")
        }
        XCTAssertEqual(delivery.kind, .complete)
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: delivery.responseBody) as? [String: Any]
        )
        let transcripts = try XCTUnwrap(envelope["transcripts"] as? [[String: Any]])
        let transcript = try XCTUnwrap(transcripts.first?["transcript"] as? [String: Any])
        let lines = try XCTUnwrap(transcript["lines"] as? [[String: Any]])
        let words = try XCTUnwrap(lines.first?["words"] as? [[String: Any]])
        XCTAssertNil(words.first?["timeRange"])
        XCTAssertNil(transcript["durationMs"])
    }

    func testExactCompleteResponseBudgetFailureReturnsNoTranscriptAndRevokes() async throws {
        let grant = try makeGrant(remainingInputTokens: 0)
        let handle = grant.providerAttachments[0].sessionTranscriptHandle

        let result = await grant.broker.read(
            capability: grant.capability,
            requestBody: requestBody(handles: [handle])
        )
        guard case let .delivered(delivery) = result else {
            return XCTFail("expected contextCannotFit")
        }
        XCTAssertEqual(delivery.kind, .contextCannotFit)
        XCTAssertEqual(
            String(decoding: delivery.responseBody, as: UTF8.self),
            #"{"kind":"contextCannotFit"}"#
        )
        XCTAssertTrue(delivery.terminatesAttempt)
        let status = await grant.broker.status()
        XCTAssertEqual(status, .revoked)
    }

    func testOnlyExactOrderedRedeliveryReplaysCachedBytesWithinBound() async throws {
        let count = LockedCounter()
        let grant = try makeGrant(readCount: count)
        let handles = grant.providerAttachments.map(\.sessionTranscriptHandle)
        let firstBody = requestBody(handles: handles)
        let whitespaceBody = Data(
            "{ \"sessionTranscriptHandles\" : [\"\(handles[0])\", \"\(handles[1])\"] }".utf8
        )

        let first = await grant.broker.read(
            capability: grant.capability,
            requestBody: firstBody
        )
        let replay = await grant.broker.read(
            capability: grant.capability,
            requestBody: whitespaceBody
        )
        guard case let .delivered(firstDelivery) = first,
              case let .delivered(replayDelivery) = replay
        else {
            return XCTFail("expected initial and replay deliveries")
        }
        XCTAssertFalse(firstDelivery.isReplay)
        XCTAssertTrue(replayDelivery.isReplay)
        XCTAssertTrue(replayDelivery.terminatesAttempt)
        XCTAssertEqual(replayDelivery.responseBody, firstDelivery.responseBody)
        XCTAssertEqual(count.value, 2)
        let exhaustedStatus = await grant.broker.status()
        XCTAssertEqual(exhaustedStatus, .revoked)

        let third = await grant.broker.read(
            capability: grant.capability,
            requestBody: firstBody
        )
        XCTAssertEqual(third, .rejected(.closed))
        XCTAssertEqual(count.value, 2)
        let status = await grant.broker.status()
        XCTAssertEqual(status, .revoked)
    }

    func testChangedSplitOrReorderedSecondSemanticReadFailsClosed() async throws {
        enum Change {
            case differentSubset
            case reordered
        }
        for change in [Change.differentSubset, .reordered] {
            let count = LockedCounter()
            let grant = try makeGrant(readCount: count)
            let handles = grant.providerAttachments.map(\.sessionTranscriptHandle)
            _ = await grant.broker.read(
                capability: grant.capability,
                requestBody: requestBody(handles: handles)
            )
            let changedHandles: [String]
            switch change {
            case .differentSubset:
                changedHandles = [handles[0]]
            case .reordered:
                changedHandles = Array(handles.reversed())
            }

            let changedResult = await grant.broker.read(
                capability: grant.capability,
                requestBody: requestBody(handles: changedHandles)
            )
            XCTAssertEqual(changedResult, .rejected(.closed))
            XCTAssertEqual(count.value, 2)
            let status = await grant.broker.status()
            XCTAssertEqual(status, .revoked)
        }
    }

    func testEveryAttemptTerminalReasonRevokesCapabilityHandlesAndCache() async throws {
        for reason in TranscriptReadRevocationReason.allCases {
            let grant = try makeGrant()
            let handle = grant.providerAttachments[0].sessionTranscriptHandle
            _ = await grant.broker.read(
                capability: grant.capability,
                requestBody: requestBody(handles: [handle])
            )

            await grant.broker.revoke(reason: reason)

            let status = await grant.broker.status()
            XCTAssertEqual(status, .revoked, reason.rawValue)
            let lateRead = await grant.broker.read(
                capability: grant.capability,
                requestBody: requestBody(handles: [handle])
            )
            XCTAssertEqual(lateRead, .rejected(.closed), reason.rawValue)
        }
    }

    func testConcurrentExactCallsPerformOneStorageReadAndOneReplay() async throws {
        let count = LockedCounter()
        let grant = try makeGrant(readCount: count)
        let body = requestBody(handles: grant.providerAttachments.map(\.sessionTranscriptHandle))

        async let first = grant.broker.read(capability: grant.capability, requestBody: body)
        async let second = grant.broker.read(capability: grant.capability, requestBody: body)
        let results = await [first, second]

        let deliveries = results.compactMap { result -> TranscriptReadDelivery? in
            guard case let .delivered(delivery) = result else { return nil }
            return delivery
        }
        XCTAssertEqual(deliveries.count, 2)
        XCTAssertEqual(deliveries.filter(\.isReplay).count, 1)
        XCTAssertEqual(Set(deliveries.map(\.responseBody)).count, 1)
        XCTAssertEqual(count.value, 2)
    }

    func testReadRacingCancellationNeverReturnsPartialBytes() async throws {
        for _ in 0 ..< 25 {
            let grant = try makeGrant()
            let body = requestBody(handles: grant.providerAttachments.map(\.sessionTranscriptHandle))

            async let result = grant.broker.read(
                capability: grant.capability,
                requestBody: body
            )
            async let cancellation: Void = grant.broker.revoke(reason: .cancelled)
            let (readResult, _) = await (result, cancellation)

            switch readResult {
            case let .delivered(delivery):
                XCTAssertEqual(delivery.kind, .complete)
                XCTAssertTrue(
                    String(decoding: delivery.responseBody, as: UTF8.self)
                        .hasPrefix(#"{"kind":"complete","transcripts":["#)
                )
            case .rejected:
                break
            }
            let status = await grant.broker.status()
            XCTAssertEqual(status, .revoked)
        }
    }

    func testForbiddenDataOperationsAndIdentitiesCannotReachStorage() async throws {
        let forbiddenFields = [
            "path", "libraryId", "sessionId", "transcriptRevisionId", "search",
            "query", "write", "delete", "audio", "profile", "memory", "chat",
            "operation",
        ]
        for field in forbiddenFields {
            let count = LockedCounter()
            let grant = try makeGrant(readCount: count)
            let body = try JSONSerialization.data(withJSONObject: [
                "sessionTranscriptHandles": [grant.providerAttachments[0].sessionTranscriptHandle],
                field: "/Library/private-canary",
            ])
            let result = await grant.broker.read(
                capability: grant.capability,
                requestBody: body
            )
            XCTAssertEqual(result, .rejected(.closed), field)
            XCTAssertEqual(count.value, 0, field)
        }
    }

    func testMCPDiscoveryExposesOnlyTheContractTranscriptReadTool() async throws {
        let grant = try makeGrant()
        let authorization = try authorizationHeader(for: grant)
        let boundary = grant.makeMCPBoundary(expectedAuthority: "127.0.0.1:43123")
        let initialize = await boundary.handle(
            mcpRequest(
                authorization: authorization,
                body: initializeBody(id: "initialize-1")
            )
        )
        XCTAssertEqual(initialize.statusCode, 200)

        let discovery = await boundary.handle(
            mcpRequest(
                authorization: authorization,
                body: rpcBody(id: "list-1", method: "tools/list", params: [:])
            )
        )
        XCTAssertEqual(discovery.statusCode, 200)
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: discovery.body) as? [String: Any]
        )
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["name"] as? String, "read_session_transcripts")

        let advertisedSchema = try XCTUnwrap(tools[0]["inputSchema"])
        let advertisedData = try JSONSerialization.data(
            withJSONObject: advertisedSchema,
            options: [.sortedKeys]
        )
        let committedData = try Data(contentsOf: requestContractURL())
        let committedObject = try JSONSerialization.jsonObject(with: committedData)
        let normalizedCommitted = try JSONSerialization.data(
            withJSONObject: committedObject,
            options: [.sortedKeys]
        )
        XCTAssertEqual(advertisedData, normalizedCommitted)
        XCTAssertFalse(String(decoding: advertisedData, as: UTF8.self).contains("uniqueItems"))

        let providerSurface = String(decoding: discovery.body, as: UTF8.self)
        for forbidden in [
            "Library", "sessionId", "revisionId", "path", "search", "write",
            "delete", "audio", "Profile", "Memory", "Chat",
        ] {
            XCTAssertFalse(providerSurface.contains(forbidden), forbidden)
        }
        let rawCapability = String(authorization.dropFirst("Bearer ".count))
        XCTAssertFalse(providerSurface.contains(rawCapability))
    }

    func testMCPInitializedNotificationIsAcceptedOnceWithoutConsumingDelivery() async throws {
        let grant = try makeGrant()
        let authorization = try authorizationHeader(for: grant)
        let boundary = grant.makeMCPBoundary(expectedAuthority: "127.0.0.1:43123")
        let initialize = await boundary.handle(
            mcpRequest(
                contentType: "application/json; charset=utf-8",
                authorization: authorization,
                body: initializeBody(id: "initialize-1")
            )
        )
        XCTAssertEqual(initialize.statusCode, 200)

        let notification = await boundary.handle(
            mcpRequest(
                authorization: authorization,
                body: initializedNotificationBody()
            )
        )
        XCTAssertEqual(notification.statusCode, 202)
        XCTAssertNil(notification.contentType)
        XCTAssertTrue(notification.body.isEmpty)

        let discovery = await boundary.handle(
            mcpRequest(
                authorization: authorization,
                body: rpcBody(id: "list-1", method: "tools/list", params: [:])
            )
        )
        XCTAssertEqual(discovery.statusCode, 200)

        let repeated = await boundary.handle(
            mcpRequest(
                authorization: authorization,
                body: initializedNotificationBody()
            )
        )
        XCTAssertEqual(repeated.statusCode, 400)
        let stopped = await boundary.isStopped()
        XCTAssertTrue(stopped)
        let status = await grant.broker.status()
        XCTAssertEqual(status, .revoked)
    }

    func testMCPToolCallRoundTripsCommittedResponseAndIgnoresRPCIDForRedelivery() async throws {
        let count = LockedCounter()
        let grant = try makeGrant(readCount: count)
        let authorization = try authorizationHeader(for: grant)
        let boundary = grant.makeMCPBoundary(expectedAuthority: "127.0.0.1:43123")
        _ = await boundary.handle(
            mcpRequest(
                authorization: authorization,
                body: initializeBody(id: "initialize-1")
            )
        )
        let arguments: [String: Any] = [
            "sessionTranscriptHandles": [grant.providerAttachments[0].sessionTranscriptHandle],
        ]

        let first = await boundary.handle(
            mcpRequest(
                authorization: authorization,
                body: toolCallBody(id: "rpc-a", arguments: arguments)
            )
        )
        let replay = await boundary.handle(
            mcpRequest(
                authorization: authorization,
                body: toolCallBody(id: "rpc-b", arguments: arguments)
            )
        )
        XCTAssertEqual(first.statusCode, 200)
        XCTAssertEqual(replay.statusCode, 200)
        let firstText = try toolResponseText(first.body)
        let replayText = try toolResponseText(replay.body)
        XCTAssertEqual(firstText, replayText)
        XCTAssertEqual(count.value, 1)

        let responseObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(firstText.utf8)) as? [String: Any]
        )
        XCTAssertEqual(responseObject["kind"] as? String, "complete")
        XCTAssertEqual(Set(responseObject.keys), ["kind", "transcripts"])
        let schema = try JSONSerialization.jsonObject(
            with: Data(contentsOf: responseContractURL())
        ) as? [String: Any]
        let definitions = try XCTUnwrap(schema?["$defs"] as? [String: Any])
        let completeDefinition = try XCTUnwrap(
            definitions["ReadSessionTranscriptsResponseComplete"] as? [String: Any]
        )
        XCTAssertEqual(
            Set(completeDefinition["required"] as? [String] ?? []),
            Set(responseObject.keys)
        )

        let providerSurface = String(decoding: first.body + replay.body, as: UTF8.self)
        XCTAssertFalse(providerSurface.contains("local-session"))
        XCTAssertFalse(providerSurface.contains("revision-"))
        XCTAssertFalse(
            providerSurface.contains(String(authorization.dropFirst("Bearer ".count)))
        )
    }

    func testMCPRejectsUnrelatedMethodsToolsAndFieldsBeforeStorage() async throws {
        enum Attack {
            case method(String)
            case tool(String, [String: Any])
        }
        let attacks: [Attack] = [
            .method("resources/list"),
            .method("resources/read"),
            .method("prompts/list"),
            .method("prompts/get"),
            .method("resources/subscribe"),
            .method("completion/complete"),
            .tool("read_file", [:]),
            .tool("read_session_transcripts", [
                "sessionTranscriptHandles": ["00000000-0000-4000-8000-000000000001"],
                "path": "/Library/private-canary",
            ]),
        ]

        for attack in attacks {
            let count = LockedCounter()
            let grant = try makeGrant(readCount: count)
            let authorization = try authorizationHeader(for: grant)
            let boundary = grant.makeMCPBoundary(expectedAuthority: "127.0.0.1:43123")
            _ = await boundary.handle(
                mcpRequest(
                    authorization: authorization,
                    body: initializeBody(id: "initialize-1")
                )
            )
            let body: Data
            switch attack {
            case let .method(method):
                body = rpcBody(id: "attack", method: method, params: [:])
            case let .tool(name, arguments):
                body = toolCallBody(id: "attack", name: name, arguments: arguments)
            }

            let response = await boundary.handle(
                mcpRequest(authorization: authorization, body: body)
            )
            XCTAssertEqual(response.statusCode, 400)
            XCTAssertEqual(
                String(decoding: response.body, as: UTF8.self),
                #"{"error":{"code":-32600,"message":"requestRejected"},"id":null,"jsonrpc":"2.0"}"#
            )
            XCTAssertEqual(count.value, 0)
            let stopped = await boundary.isStopped()
            XCTAssertTrue(stopped)
            let brokerStatus = await grant.broker.status()
            XCTAssertEqual(brokerStatus, .revoked)
        }
    }

    func testMCPRejectsMalformedHTTPAndAuthorizationWithoutLeakingCanaries() async throws {
        enum Mutation {
            case method, path, authority, contentType, origin, missingAuthorization
            case wrongAuthorization, truncatedAuthorization, malformedJSON, batch, oversized
        }
        let mutations: [Mutation] = [
            .method, .path, .authority, .contentType, .origin, .missingAuthorization,
            .wrongAuthorization, .truncatedAuthorization, .malformedJSON, .batch, .oversized,
        ]

        for mutation in mutations {
            let count = LockedCounter()
            let grant = try makeGrant(readCount: count)
            let goodAuthorization = try authorizationHeader(for: grant)
            let boundary = grant.makeMCPBoundary(
                expectedAuthority: "127.0.0.1:43123",
                maximumBodyBytes: mutation == .oversized ? 8 : 32 * 1_024
            )
            let otherGrant = try makeGrant()
            let wrongAuthorization = try authorizationHeader(for: otherGrant)
            let goodBody = initializeBody(id: "initialize-1")
            let request: TranscriptReadHTTPRequest
            switch mutation {
            case .method:
                request = mcpRequest(
                    method: "GET",
                    authorization: goodAuthorization,
                    body: goodBody
                )
            case .path:
                request = mcpRequest(
                    path: "/mcp/../Library/private-canary",
                    authorization: goodAuthorization,
                    body: goodBody
                )
            case .authority:
                request = mcpRequest(
                    authority: "0.0.0.0:43123",
                    authorization: goodAuthorization,
                    body: goodBody
                )
            case .contentType:
                request = mcpRequest(
                    contentType: "text/plain",
                    authorization: goodAuthorization,
                    body: goodBody
                )
            case .origin:
                request = mcpRequest(
                    authorization: goodAuthorization,
                    origin: "https://private-canary.invalid",
                    body: goodBody
                )
            case .missingAuthorization:
                request = mcpRequest(authorization: nil, body: goodBody)
            case .wrongAuthorization:
                request = mcpRequest(authorization: wrongAuthorization, body: goodBody)
            case .truncatedAuthorization:
                request = mcpRequest(
                    authorization: String(goodAuthorization.dropLast()),
                    body: goodBody
                )
            case .malformedJSON:
                request = mcpRequest(
                    authorization: goodAuthorization,
                    body: Data(#"{"jsonrpc":"2.0","method":"initialize""#.utf8)
                )
            case .batch:
                request = mcpRequest(
                    authorization: goodAuthorization,
                    body: Data("[\(String(decoding: goodBody, as: UTF8.self))]".utf8)
                )
            case .oversized:
                request = mcpRequest(authorization: goodAuthorization, body: goodBody)
            }

            let response = await boundary.handle(request)
            XCTAssertEqual(response.statusCode, 400)
            let responseText = String(decoding: response.body, as: UTF8.self)
            XCTAssertFalse(responseText.contains("private-canary"))
            XCTAssertFalse(
                responseText.contains(String(goodAuthorization.dropFirst("Bearer ".count)))
            )
            XCTAssertEqual(count.value, 0)
            let stopped = await boundary.isStopped()
            XCTAssertTrue(stopped)
        }
    }

    func testMCPRepeatedInitializeAndThirdToolDeliveryStopTheEndpoint() async throws {
        let repeatedGrant = try makeGrant()
        let repeatedAuthorization = try authorizationHeader(for: repeatedGrant)
        let repeatedBoundary = repeatedGrant.makeMCPBoundary(
            expectedAuthority: "127.0.0.1:43123"
        )
        let initialize = mcpRequest(
            authorization: repeatedAuthorization,
            body: initializeBody(id: "initialize-1")
        )
        let firstInitialize = await repeatedBoundary.handle(initialize)
        let repeatedInitialize = await repeatedBoundary.handle(initialize)
        XCTAssertEqual(firstInitialize.statusCode, 200)
        XCTAssertEqual(repeatedInitialize.statusCode, 400)
        let repeatedStopped = await repeatedBoundary.isStopped()
        XCTAssertTrue(repeatedStopped)

        let deliveryGrant = try makeGrant()
        let deliveryAuthorization = try authorizationHeader(for: deliveryGrant)
        let deliveryBoundary = deliveryGrant.makeMCPBoundary(
            expectedAuthority: "127.0.0.1:43123"
        )
        _ = await deliveryBoundary.handle(
            mcpRequest(
                authorization: deliveryAuthorization,
                body: initializeBody(id: "initialize-2")
            )
        )
        let call = toolCallBody(
            id: "call",
            arguments: [
                "sessionTranscriptHandles": [
                    deliveryGrant.providerAttachments[0].sessionTranscriptHandle,
                ],
            ]
        )
        let firstDelivery = await deliveryBoundary.handle(
            mcpRequest(authorization: deliveryAuthorization, body: call)
        )
        let secondDelivery = await deliveryBoundary.handle(
            mcpRequest(authorization: deliveryAuthorization, body: call)
        )
        let thirdDelivery = await deliveryBoundary.handle(
            mcpRequest(authorization: deliveryAuthorization, body: call)
        )
        XCTAssertEqual(firstDelivery.statusCode, 200)
        XCTAssertEqual(secondDelivery.statusCode, 200)
        XCTAssertEqual(thirdDelivery.statusCode, 400)
        let deliveryStopped = await deliveryBoundary.isStopped()
        XCTAssertTrue(deliveryStopped)
    }

    func testLoopbackHTTPServerUsesEphemeralIPv4AndStopsWithTheAttempt() async throws {
        let count = LockedCounter()
        let grant = try makeGrant(readCount: count)
        let server = try await LoopbackTranscriptReadHTTPServer.start(
            grant: grant,
            requestTimeout: .seconds(1)
        )
        XCTAssertEqual(server.host, "127.0.0.1")
        XCTAssertNotEqual(server.port, 0)
        XCTAssertEqual(server.endpointURL.host, "127.0.0.1")
        XCTAssertEqual(server.endpointURL.path, "/mcp")

        let authorization = try authorizationHeader(for: grant)
        let session = ephemeralURLSession()
        let initialize = try await sendHTTP(
            body: initializeBody(id: "initialize-live"),
            authorization: authorization,
            to: server.endpointURL,
            session: session
        )
        XCTAssertEqual(initialize.response.statusCode, 200)
        let initializeClosedReason = await server.diagnosticClosedReason()
        XCTAssertNil(initializeClosedReason, String(describing: initializeClosedReason))
        let initializeHTTPClosedReason = server.diagnosticHTTPClosedReason()
        XCTAssertNil(initializeHTTPClosedReason, String(describing: initializeHTTPClosedReason))
        XCTAssertNil(initialize.response.value(forHTTPHeaderField: "Location"))
        XCTAssertNil(initialize.response.value(forHTTPHeaderField: "Access-Control-Allow-Origin"))

        let call = try await sendHTTP(
            body: toolCallBody(
                id: "call-live",
                arguments: [
                    "sessionTranscriptHandles": [
                        grant.providerAttachments[0].sessionTranscriptHandle,
                    ],
                ]
            ),
            authorization: authorization,
            to: server.endpointURL,
            session: session
        )
        XCTAssertEqual(call.response.statusCode, 200)
        XCTAssertEqual(count.value, 1)
        XCTAssertFalse(
            String(decoding: call.data, as: UTF8.self)
                .contains(String(authorization.dropFirst("Bearer ".count)))
        )

        await server.stop(reason: .attemptCompleted)
        XCTAssertTrue(server.isStopped())
        let status = await grant.broker.status()
        XCTAssertEqual(status, .revoked)

        do {
            _ = try await sendHTTP(
                body: initializeBody(id: "late"),
                authorization: authorization,
                to: server.endpointURL,
                session: session
            )
            XCTFail("revocation must close the loopback port")
        } catch {
            // A connection refusal is the expected observable boundary.
        }
        session.invalidateAndCancel()
    }

    func testLoopbackProtocolFailureReturnsSanitizedErrorThenClosesPort() async throws {
        let count = LockedCounter()
        let grant = try makeGrant(readCount: count)
        let server = try await LoopbackTranscriptReadHTTPServer.start(
            grant: grant,
            requestTimeout: .seconds(1)
        )
        let session = ephemeralURLSession()

        let response = try await sendHTTP(
            body: initializeBody(id: "initialize-live"),
            authorization: nil,
            to: server.endpointURL,
            session: session
        )
        XCTAssertEqual(response.response.statusCode, 400)
        XCTAssertEqual(
            String(decoding: response.data, as: UTF8.self),
            #"{"error":{"code":-32600,"message":"requestRejected"},"id":null,"jsonrpc":"2.0"}"#
        )
        XCTAssertEqual(count.value, 0)

        for _ in 0 ..< 100 where !server.isStopped() {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(server.isStopped())
        let status = await grant.broker.status()
        XCTAssertEqual(status, .revoked)
        session.invalidateAndCancel()
    }

    func testLoopbackPartialBodyTimesOutWithoutStorageOrCapabilityLeakage() async throws {
        let count = LockedCounter()
        let grant = try makeGrant(readCount: count)
        let server = try await LoopbackTranscriptReadHTTPServer.start(
            grant: grant,
            requestTimeout: .milliseconds(100)
        )
        let authorization = try authorizationHeader(for: grant)
        let partialRequest = Data(
            (
                "POST /mcp HTTP/1.1\r\n"
                    + "Host: 127.0.0.1:\(server.port)\r\n"
                    + "Content-Type: application/json\r\n"
                    + "Authorization: \(authorization)\r\n"
                    + "Content-Length: 100\r\n\r\n"
                    + "{"
            ).utf8
        )

        let response = try rawHTTPExchange(
            port: server.port,
            request: partialRequest,
            receiveTimeout: .seconds(1)
        )
        let responseText = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(responseText.hasPrefix("HTTP/1.1 400 Bad Request"))
        XCTAssertTrue(responseText.contains("requestRejected"))
        XCTAssertFalse(
            responseText.contains(String(authorization.dropFirst("Bearer ".count)))
        )
        XCTAssertEqual(count.value, 0)
        XCTAssertEqual(server.diagnosticHTTPClosedReason(), .bodyTimedOut)
        XCTAssertTrue(server.isStopped())
        let status = await grant.broker.status()
        XCTAssertEqual(status, .revoked)
    }

    func testLoopbackStopRacingAcceptNeverUsesRecycledListenerDescriptor() async throws {
        let gate = DescriptorRaceGate()
        let monitor = DescriptorUseMonitor()
        let grant = try makeGrant()
        let server = try LoopbackTranscriptReadHTTPServer.startForTesting(
            grant: grant,
            requestTimeout: .seconds(1),
            testHooks: LoopbackTranscriptReadServerTestHooks(
                acceptedBeforeRegistration: { descriptor in
                    gate.block(descriptor: descriptor)
                },
                transportDidMarkStopped: {
                    gate.signalStopMarked()
                },
                acceptLoopFinished: {
                    gate.signalAcceptLoopFinished()
                },
                descriptorWillBeUsed: { descriptor in
                    monitor.observeUse(of: descriptor)
                }
            )
        )
        let listenerDescriptor = server.listenerDescriptorForTesting()
        let clientDescriptor = try openLoopbackConnection(port: server.port)
        defer { Darwin.close(clientDescriptor) }
        defer { gate.unblock() }
        guard gate.waitUntilBlocked() else {
            await server.stop(reason: .protocolFailure)
            return XCTFail("accept hook was not reached")
        }

        let stopTask = Task {
            await server.stop(reason: .cancelled)
        }
        guard gate.waitUntilStopMarked() else {
            gate.unblock()
            await stopTask.value
            return XCTFail("transport stop did not linearize")
        }
        gate.unblock()
        await stopTask.value

        let sentinel = try makeDescriptorReuseSentinel(target: listenerDescriptor)
        defer {
            Darwin.close(sentinel.descriptor)
            Darwin.close(sentinel.peer)
        }
        monitor.arm(descriptor: sentinel.descriptor)
        let marker = Data("listener-fd-reuse-canary".utf8)
        try sendAll(marker, to: sentinel.peer)
        XCTAssertTrue(gate.waitUntilAcceptLoopFinished())
        XCTAssertEqual(try receiveExactly(marker.count, from: sentinel.descriptor), marker)
        XCTAssertEqual(monitor.violations, 0)
        XCTAssertTrue(server.isStopped())
    }

    func testLoopbackStopBeforeReceiveNeverUsesRecycledConnectionDescriptor() async throws {
        let gate = DescriptorRaceGate()
        let monitor = DescriptorUseMonitor()
        let grant = try makeGrant()
        let server = try LoopbackTranscriptReadHTTPServer.startForTesting(
            grant: grant,
            requestTimeout: .seconds(1),
            testHooks: LoopbackTranscriptReadServerTestHooks(
                acceptedBeforeReceive: { descriptor in
                    gate.block(descriptor: descriptor)
                },
                connectionWorkerFinished: { _ in
                    gate.signalConnectionWorkerFinished()
                },
                descriptorWillBeUsed: { descriptor in
                    monitor.observeUse(of: descriptor)
                }
            )
        )
        let clientDescriptor = try openLoopbackConnection(port: server.port)
        defer { Darwin.close(clientDescriptor) }
        defer { gate.unblock() }
        guard gate.waitUntilBlocked(), let acceptedDescriptor = gate.descriptor else {
            await server.stop(reason: .protocolFailure)
            return XCTFail("receive hook was not reached")
        }

        await server.stop(reason: .cancelled)
        let sentinel = try makeDescriptorReuseSentinel(target: acceptedDescriptor)
        defer {
            Darwin.close(sentinel.descriptor)
            Darwin.close(sentinel.peer)
        }
        monitor.arm(descriptor: sentinel.descriptor)
        let marker = Data("connection-fd-reuse-canary".utf8)
        try sendAll(marker, to: sentinel.peer)
        gate.unblock()

        XCTAssertTrue(gate.waitUntilConnectionWorkerFinished())
        XCTAssertEqual(try receiveExactly(marker.count, from: sentinel.descriptor), marker)
        XCTAssertEqual(monitor.violations, 0)
        XCTAssertTrue(server.isStopped())
    }

    func testLoopbackRejectsOverflowingAndUnboundedConfiguration() async throws {
        let grant = try makeGrant()
        let cases: [(body: Int, header: Int, timeout: Duration, connections: Int)] = [
            (Int.max, 16 * 1_024, .seconds(1), 8),
            (32 * 1_024, Int.max, .seconds(1), 8),
            (1 * 1_024 * 1_024 + 1, 16 * 1_024, .seconds(1), 8),
            (32 * 1_024, 64 * 1_024 + 1, .seconds(1), 8),
            (32 * 1_024, 16 * 1_024, .seconds(31), 8),
            (32 * 1_024, 16 * 1_024, .seconds(1), Int(Int32.max) + 1),
        ]

        for configuration in cases {
            do {
                let server = try await LoopbackTranscriptReadHTTPServer.start(
                    grant: grant,
                    maximumBodyBytes: configuration.body,
                    maximumHeaderBytes: configuration.header,
                    requestTimeout: configuration.timeout,
                    maximumConnections: configuration.connections
                )
                await server.stop(reason: .protocolFailure)
                XCTFail("expected invalid configuration: \(configuration)")
            } catch let error as LoopbackTranscriptReadServerError {
                XCTAssertEqual(error, .invalidConfiguration)
            }
        }
    }

    func testLoopbackRejectsOverflowingContentLengthWithoutStorageOrLeakage() async throws {
        for length in [String(Int.max) + "0", "+1", "-1"] {
            let count = LockedCounter()
            let grant = try makeGrant(readCount: count)
            let server = try await LoopbackTranscriptReadHTTPServer.start(
                grant: grant,
                maximumBodyBytes: 1_024,
                requestTimeout: .seconds(1)
            )
            let request = Data(
                (
                    "POST /mcp HTTP/1.1\r\n"
                        + "Host: 127.0.0.1:\(server.port)\r\n"
                        + "Content-Type: application/json\r\n"
                        + "Content-Length: \(length)\r\n\r\n"
                ).utf8
            )
            let response = try rawHTTPExchange(
                port: server.port,
                request: request,
                receiveTimeout: .seconds(1)
            )
            let responseText = String(decoding: response, as: UTF8.self)
            XCTAssertTrue(responseText.hasPrefix("HTTP/1.1 400 Bad Request"))
            XCTAssertTrue(responseText.contains("requestRejected"))
            XCTAssertFalse(responseText.contains(length))
            XCTAssertEqual(count.value, 0)
            XCTAssertEqual(server.diagnosticHTTPClosedReason(), .invalidContentLength)
            XCTAssertTrue(server.isStopped())
        }
    }

    func testSyntheticQualificationReportKeepsRealCodexGateBlockedAndMetadataOnly() async throws {
        let report = try await TranscriptReadQualificationRunner().run()
        XCTAssertEqual(report.qualification, "syntheticOnly")
        XCTAssertEqual(report.realCodexExercise, "notRun")
        XCTAssertFalse(report.productionQualified)
        XCTAssertTrue(report.allOrNothingVerified)
        XCTAssertTrue(report.boundedRedeliveryVerified)
        XCTAssertTrue(report.loopbackIPv4Only)
        XCTAssertTrue(report.endpointStopped)
        XCTAssertFalse(report.capabilityLeakDetected)
        XCTAssertFalse(report.localIdentityLeakDetected)
        XCTAssertFalse(report.blockers.isEmpty)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(report), as: UTF8.self)
        for forbidden in [
            "Synthetic qualification transcript", "qualification-local-session-canary",
            "qualification-local-revision-canary", "sessionTranscriptHandle", "/Library/",
        ] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    private func makeGrant(
        firstResult: FrozenTranscriptReadResult? = nil,
        secondResult: FrozenTranscriptReadResult = .available(
            SessionTranscriptProjection(
                durationMs: 1_000,
                lines: [
                    TranscriptLine(
                        timeRange: TranscriptTimeRange(startMs: 0, endMs: 500),
                        text: "Synthetic beta.",
                        words: [
                            TranscriptWord(
                                wordID: "word-1",
                                text: "Synthetic beta.",
                                timeRange: TranscriptTimeRange(startMs: 0, endMs: 500)
                            ),
                        ]
                    ),
                ],
                audioEvents: []
            )
        ),
        readCount: LockedCounter? = nil,
        reader suppliedReader: FrozenTranscriptReader? = nil,
        remainingInputTokens: Int = 100_000,
        limits: TranscriptReadBrokerLimits = TranscriptReadBrokerLimits()
    ) throws -> AttemptTranscriptGrant {
        let transcripts: [FrozenTranscriptRevision: FrozenTranscriptReadResult] = [
            FrozenTranscriptRevision(sessionID: "local-session-a", revisionID: "revision-a"):
                firstResult ?? .available(fixtureTranscript(text: "Synthetic alpha.")),
            FrozenTranscriptRevision(sessionID: "local-session-b", revisionID: "revision-b"):
                secondResult,
        ]
        let reader = suppliedReader ?? FrozenTranscriptReader { revision in
            readCount?.increment()
            return transcripts[revision] ?? .unavailable
        }
        let budget = try CompleteToolResponseBudget(
            remainingInputTokens: remainingInputTokens,
            responsePrefix: Data(),
            responseSuffix: Data(),
            hiddenTokens: 0,
            tokenEstimator: .utf8ByteUpperBound()
        )
        return try AttemptTranscriptGrantIssuer().issue(
            attachments: [
                FrozenTranscriptAttachment(
                    sessionAttachmentID: "attachment-a",
                    displayLabel: "Synthetic A",
                    revision: FrozenTranscriptRevision(
                        sessionID: "local-session-a",
                        revisionID: "revision-a"
                    )
                ),
                FrozenTranscriptAttachment(
                    sessionAttachmentID: "attachment-b",
                    displayLabel: "Synthetic B",
                    revision: FrozenTranscriptRevision(
                        sessionID: "local-session-b",
                        revisionID: "revision-b"
                    )
                ),
            ],
            reader: reader,
            completeResponseBudget: budget,
            limits: limits
        )
    }

    private func fixtureTranscript(text: String) -> SessionTranscriptProjection {
        SessionTranscriptProjection(
            durationMs: 1_000,
            lines: [
                TranscriptLine(
                    timeRange: TranscriptTimeRange(startMs: 0, endMs: 500),
                    text: text,
                    words: [
                        TranscriptWord(
                            wordID: "word-1",
                            text: text,
                            timeRange: TranscriptTimeRange(startMs: 0, endMs: 500)
                        ),
                    ]
                ),
            ],
            audioEvents: []
        )
    }

    private func requestBody(handles: [String]) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "sessionTranscriptHandles": handles,
        ], options: [.sortedKeys])
    }

    private func authorizationHeader(for grant: AttemptTranscriptGrant) throws -> String {
        let variable = "AUDORA_TRANSCRIPT_READ_CAPABILITY"
        let environment = try grant.capability.installing(in: [:], variableName: variable)
        return "Bearer \(environment[variable]!)"
    }

    private func mcpRequest(
        method: String = "POST",
        path: String = "/mcp",
        authority: String = "127.0.0.1:43123",
        contentType: String = "application/json",
        authorization: String?,
        origin: String? = nil,
        body: Data
    ) -> TranscriptReadHTTPRequest {
        TranscriptReadHTTPRequest(
            method: method,
            path: path,
            authority: authority,
            contentType: contentType,
            authorization: authorization,
            origin: origin,
            body: body
        )
    }

    private func initializeBody(id: String) -> Data {
        rpcBody(
            id: id,
            method: "initialize",
            params: [
                "capabilities": [:],
                "clientInfo": ["name": "synthetic-client", "version": "1"],
                "protocolVersion": "2025-03-26",
            ]
        )
    }

    private func toolCallBody(
        id: String,
        name: String = "read_session_transcripts",
        arguments: [String: Any]
    ) -> Data {
        rpcBody(
            id: id,
            method: "tools/call",
            params: ["arguments": arguments, "name": name]
        )
    }

    private func initializedNotificationBody() -> Data {
        try! JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": [:],
            ],
            options: [.sortedKeys]
        )
    }

    private func rpcBody(id: String, method: String, params: [String: Any]) -> Data {
        try! JSONSerialization.data(
            withJSONObject: [
                "id": id,
                "jsonrpc": "2.0",
                "method": method,
                "params": params,
            ],
            options: [.sortedKeys]
        )
    }

    private func toolResponseText(_ body: Data) throws -> String {
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        return try XCTUnwrap(content[0]["text"] as? String)
    }

    private func requestContractURL() -> URL {
        packageRootURL()
            .appendingPathComponent(
                "../../Packages/AudoraCore/Sources/AudoraContracts/Resources/Schemas/ReadSessionTranscriptsRequest.json"
            )
            .standardizedFileURL
    }

    private func responseContractURL() -> URL {
        packageRootURL()
            .appendingPathComponent(
                "../../Packages/AudoraCore/Sources/AudoraContracts/Resources/Schemas/ReadSessionTranscriptsResponse.json"
            )
            .standardizedFileURL
    }

    private func ephemeralURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 2
        return URLSession(configuration: configuration)
    }

    private func sendHTTP(
        body: Data,
        authorization: String?,
        to url: URL,
        session: URLSession
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    private func openLoopbackConnection(port: UInt16) throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RawSocketError.failed }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard connected == 0 else {
            Darwin.close(descriptor)
            throw RawSocketError.failed
        }
        return descriptor
    }

    private func makeDescriptorReuseSentinel(
        target: Int32
    ) throws -> (descriptor: Int32, peer: Int32) {
        errno = 0
        guard fcntl(target, F_GETFD) == -1, errno == EBADF else {
            throw RawSocketError.failed
        }

        var heldDescriptors: [Int32] = []
        var sentinel: (descriptor: Int32, peer: Int32)?
        for _ in 0 ..< 128 {
            var pair = [Int32](repeating: -1, count: 2)
            let created = pair.withUnsafeMutableBufferPointer { buffer in
                Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress!)
            }
            guard created == 0 else { break }
            if pair[0] == target {
                sentinel = (pair[0], pair[1])
                break
            }
            if pair[1] == target {
                sentinel = (pair[1], pair[0])
                break
            }
            heldDescriptors.append(contentsOf: pair)
            if pair[0] > target, pair[1] > target {
                break
            }
        }
        for descriptor in heldDescriptors {
            Darwin.close(descriptor)
        }
        guard let sentinel else { throw RawSocketError.failed }

        var noSigPipe: Int32 = 1
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        for socket in [sentinel.descriptor, sentinel.peer] {
            guard setsockopt(
                socket,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0,
            setsockopt(
                socket,
                SOL_SOCKET,
                SO_RCVTIMEO,
                &timeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0
            else {
                Darwin.close(sentinel.descriptor)
                Darwin.close(sentinel.peer)
                throw RawSocketError.failed
            }
        }
        return sentinel
    }

    private func sendAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { pointer in
            var sent = 0
            while sent < pointer.count {
                let count = Darwin.send(
                    descriptor,
                    pointer.baseAddress?.advanced(by: sent),
                    pointer.count - sent,
                    0
                )
                guard count > 0 else { throw RawSocketError.failed }
                sent += count
            }
        }
    }

    private func receiveExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var result = Data()
        while result.count < count {
            var bytes = [UInt8](repeating: 0, count: count - result.count)
            let received = bytes.withUnsafeMutableBytes { pointer in
                Darwin.recv(descriptor, pointer.baseAddress, pointer.count, 0)
            }
            guard received > 0 else { throw RawSocketError.failed }
            result.append(contentsOf: bytes.prefix(received))
        }
        return result
    }

    private func rawHTTPExchange(
        port: UInt16,
        request: Data,
        receiveTimeout: Duration
    ) throws -> Data {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RawSocketError.failed }
        defer { Darwin.close(descriptor) }

        var timeout = timeval(
            tv_sec: Int(receiveTimeout.components.seconds),
            tv_usec: Int32(receiveTimeout.components.attoseconds / 1_000_000_000_000)
        )
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw RawSocketError.failed
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard connected == 0 else { throw RawSocketError.failed }

        try request.withUnsafeBytes { pointer in
            var sent = 0
            while sent < pointer.count {
                let count = Darwin.send(
                    descriptor,
                    pointer.baseAddress?.advanced(by: sent),
                    pointer.count - sent,
                    0
                )
                guard count > 0 else { throw RawSocketError.failed }
                sent += count
            }
        }

        var response = Data()
        while true {
            var bytes = [UInt8](repeating: 0, count: 4 * 1_024)
            let count = bytes.withUnsafeMutableBytes { pointer in
                Darwin.recv(descriptor, pointer.baseAddress, pointer.count, 0)
            }
            if count > 0 {
                response.append(contentsOf: bytes.prefix(count))
            } else {
                break
            }
        }
        guard !response.isEmpty else { throw RawSocketError.failed }
        return response
    }

    private func packageRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func isCanonicalHandle(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ) != nil
    }
}

private enum SyntheticStorageError: Error {
    case message(String)
}

private enum RawSocketError: Error {
    case failed
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class DescriptorRaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDescriptor: Int32?
    private let blocked = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let stopMarked = DispatchSemaphore(value: 0)
    private let acceptLoopFinished = DispatchSemaphore(value: 0)
    private let connectionWorkerFinished = DispatchSemaphore(value: 0)

    var descriptor: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return storedDescriptor
    }

    func block(descriptor: Int32) {
        lock.lock()
        storedDescriptor = descriptor
        lock.unlock()
        blocked.signal()
        release.wait()
    }

    func unblock() {
        release.signal()
    }

    func signalStopMarked() {
        stopMarked.signal()
    }

    func signalAcceptLoopFinished() {
        acceptLoopFinished.signal()
    }

    func signalConnectionWorkerFinished() {
        connectionWorkerFinished.signal()
    }

    func waitUntilBlocked() -> Bool {
        blocked.wait(timeout: .now() + 2) == .success
    }

    func waitUntilStopMarked() -> Bool {
        stopMarked.wait(timeout: .now() + 2) == .success
    }

    func waitUntilAcceptLoopFinished() -> Bool {
        acceptLoopFinished.wait(timeout: .now() + 2) == .success
    }

    func waitUntilConnectionWorkerFinished() -> Bool {
        connectionWorkerFinished.wait(timeout: .now() + 2) == .success
    }
}

private final class DescriptorUseMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var armedDescriptors: Set<Int32> = []
    private var violationCount = 0

    var violations: Int {
        lock.lock()
        defer { lock.unlock() }
        return violationCount
    }

    func arm(descriptor: Int32) {
        lock.lock()
        armedDescriptors.insert(descriptor)
        lock.unlock()
    }

    func observeUse(of descriptor: Int32) {
        lock.lock()
        if armedDescriptors.contains(descriptor) {
            violationCount += 1
        }
        lock.unlock()
    }
}
