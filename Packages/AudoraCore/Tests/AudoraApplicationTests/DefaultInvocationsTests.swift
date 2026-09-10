@testable @_spi(CoachContextQualification) @_spi(InvocationInfrastructure) @_spi(InvocationTesting) import AudoraApplication
import AudoraDomain
import Foundation
import XCTest

final class DefaultInvocationsTests: XCTestCase {
    func testStopRevokesAndReapsSuspendedProviderBeforePersistingInterruption() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            includesOnDemandAttachment: true
        )
        let authorities = InvocationStopAuthorityRecorder()
        await fixture.provider.suspendNextLaunch()

        let invocationTask = Task {
            await fixture.invocations.tryInvoke(
                fixture.request,
                observingStopAuthority: { authority in
                    await authorities.record(authority)
                }
            )
        }
        await fixture.provider.waitUntilLaunchStarts()
        let authority = await authorities.waitForAuthority()
        let stopRequest = StopCoachInvocationRequest(
            library: fixture.scope,
            chatID: fixture.request.chatID,
            pendingUserTurnID: fixture.request.pendingUserTurnID
        )

        let stopOutcome = await fixture.invocations.stop(
            stopRequest,
            authority: authority
        )

        guard case let .interrupted(aggregate) = stopOutcome else {
            return XCTFail("Stop must durably interrupt after reaping, got \(stopOutcome)")
        }
        XCTAssertEqual(aggregate.pendingUserTurn?.failure, .coachResponseInterrupted)
        _ = await invocationTask.value
        let cancelledAttemptIDs = await fixture.provider.cancelledAttemptIDs
        let cancellationGraceMilliseconds = await fixture.provider
            .cancellationGraceMilliseconds
        let publicationCount = await fixture.persistence.publicationCount
        let activeInvocation = await fixture.persistence.activeInvocation
        XCTAssertEqual(cancelledAttemptIDs, [authority.attemptID])
        XCTAssertEqual(
            cancellationGraceMilliseconds,
            [DefaultInvocations.providerCancellationGraceMilliseconds]
        )
        XCTAssertEqual(publicationCount, 0)
        XCTAssertNil(activeInvocation)
        XCTAssertEqual(aggregate.chat.messageIDs, [])
        let stopDiagnostic = try XCTUnwrap(
            fixture.diagnostics.recordedEvents().first
        )
        XCTAssertEqual(fixture.diagnostics.recordedEvents().count, 1)
        XCTAssertEqual(stopDiagnostic.reason, .coachResponseStopped)
        XCTAssertEqual(stopDiagnostic.classification, .interruption)
        XCTAssertEqual(stopDiagnostic.disposition, .userRetryableFailure)
        XCTAssertEqual(stopDiagnostic.invocationID, authority.invocationID)
        XCTAssertEqual(stopDiagnostic.attemptID, authority.attemptID)
        let stoppedRequests = await fixture.provider.requests
        let providerRequest = try XCTUnwrap(stoppedRequests.first)
        let transcriptAccess = try XCTUnwrap(providerRequest.transcriptAccess)
        let lateRead = await transcriptAccess.read(
            transportRequestID: AttemptTranscriptTransportRequestID("late-read")!,
            handles: transcriptAccess.handles
        )
        XCTAssertEqual(lateRead, .rejected(.closed))
    }

    func testOrdinaryStopRetriesUnconfirmedReapAsInterruption() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            includesOnDemandAttachment: true,
            providerCancellationOutcomes: [.unableToConfirm, .reaped]
        )
        let authorities = InvocationStopAuthorityRecorder()
        await fixture.provider.suspendNextLaunch()
        let invocationTask = Task {
            await fixture.invocations.tryInvoke(
                fixture.request,
                observingStopAuthority: { authority in
                    await authorities.record(authority)
                }
            )
        }
        let authority = await authorities.waitForAuthority()
        let request = StopCoachInvocationRequest(
            library: fixture.scope,
            chatID: fixture.request.chatID,
            pendingUserTurnID: fixture.request.pendingUserTurnID
        )

        let firstOutcome = await fixture.invocations.stop(
            request,
            authority: authority
        )
        XCTAssertEqual(firstOutcome, .unableToReap)

        let secondOutcome = await fixture.invocations.stop(
            request,
            authority: authority
        )
        guard case let .interrupted(aggregate) = secondOutcome else {
            return XCTFail("the exact authority must retry process reaping")
        }
        XCTAssertEqual(
            aggregate.pendingUserTurn?.failure,
            .coachResponseInterrupted
        )
        _ = await invocationTask.value
        XCTAssertEqual(
            fixture.diagnostics.recordedEvents().last?.reason,
            .coachResponseStopped
        )
    }

    func testCompleteAttemptTranscriptReadPublishesThenRevokesAccess() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            includesOnDemandAttachment: true,
            providerTranscriptReadPlan: .all
        )

        guard case .published = await fixture.invocations.tryInvoke(fixture.request) else {
            return XCTFail("a complete atomic transcript read must permit publication")
        }

        let results = await fixture.provider.transcriptReadResults
        guard case let .delivered(delivery) = try XCTUnwrap(results.first) else {
            return XCTFail("the provider must receive one complete transcript delivery")
        }
        XCTAssertEqual(delivery.kind, .complete)
        XCTAssertFalse(delivery.isReplay)
        XCTAssertFalse(delivery.terminatesAttempt)
        let body = String(decoding: delivery.responseBody, as: UTF8.self)
        XCTAssertTrue(body.contains(#""sessionAttachmentId":"attachment-1""#))
        XCTAssertFalse(body.contains("ses-"))
        XCTAssertFalse(body.contains("trv-"))
        XCTAssertFalse(body.contains("library"))
        XCTAssertFalse(body.contains("path"))
        XCTAssertFalse(body.contains("confidence"))
        XCTAssertFalse(body.contains("textualEvents"))
        XCTAssertFalse(body.contains("rawAudio"))

        let providerRequests = await fixture.provider.requests
        let request = try XCTUnwrap(providerRequests.first)
        XCTAssertEqual(
            Set(Mirror(reflecting: request).children.compactMap(\.label)),
            Set([
                "attemptID",
                "attemptOrdinal",
                "attemptKind",
                "providerIdempotencyValue",
                "exchange",
                "transcriptAccess",
                "outputTokenCeiling",
                "pinnedInstruction",
                "control",
            ])
        )
        XCTAssertEqual(
            Set(Mirror(reflecting: request.exchange).children.compactMap(\.label)),
            Set(["request", "transcriptHandles"])
        )
        let lateRead = await request.transcriptAccess?.read(
            transportRequestID: AttemptTranscriptTransportRequestID("late-read")!,
            handles: request.exchange.transcriptHandles
        )
        XCTAssertEqual(lateRead, .rejected(.closed))
    }

    func testUnavailableAttemptTranscriptReadPersistsBoundedStableFailure() async throws {
        let unavailableID = try ChatSessionAttachmentID("attachment-1")
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            includesOnDemandAttachment: true,
            providerTranscriptReadPlan: .all,
            transcriptAvailability: AttemptTranscriptAvailabilitySource { query in
                query.sessionAttachmentID == unavailableID ? .unavailable : .available
            }
        )
        await fixture.provider.suspendNextLaunch()

        let invocationTask = Task {
            await fixture.invocations.tryInvoke(fixture.request)
        }
        await fixture.provider.waitUntilCancellationStarts()
        guard case let .interrupted(aggregate?, .providerFailed) =
            await invocationTask.value
        else {
            return XCTFail("an unavailable transcript must abort without publication")
        }
        guard case let .coachTranscriptReadFailed(summary)? =
            aggregate.pendingUserTurn?.failure
        else {
            return XCTFail("the durable Pending must retain safe recovery links")
        }
        XCTAssertEqual(
            summary.sessions,
            [
                try CoachTranscriptReadFailureSession(
                    sessionAttachmentID: unavailableID,
                    displayLabel: "Fixture Session"
                ),
            ]
        )
        XCTAssertEqual(summary.additionalSessionCount, 0)
        let publicationCount = await fixture.persistence.publicationCount
        let cancelledAttemptIDs = await fixture.provider.cancelledAttemptIDs
        let providerRequests = await fixture.provider.requests
        XCTAssertEqual(publicationCount, 0)
        XCTAssertEqual(
            cancelledAttemptIDs,
            [try XCTUnwrap(providerRequests.first?.attemptID)]
        )
        let event = try XCTUnwrap(fixture.diagnostics.recordedEvents().last)
        XCTAssertEqual(event.reason, .transcriptSessionUnavailable)
        XCTAssertEqual(event.classification, .transcriptReadFailure)
    }

    func testStopWinningDuringTranscriptTerminalReapPreservesRichFailure()
        async throws
    {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            includesOnDemandAttachment: true,
            providerTranscriptReadPlan: .all,
            transcriptAvailability: AttemptTranscriptAvailabilitySource { _ in
                .unavailable
            },
            providerCancellationOutcomes: [.reaped, .reaped]
        )
        let authorities = InvocationStopAuthorityRecorder()
        await fixture.provider.suspendNextLaunch()
        await fixture.provider.suspendNextCancellation()
        let invocationTask = Task {
            await fixture.invocations.tryInvoke(
                fixture.request,
                observingStopAuthority: { authority in
                    await authorities.record(authority)
                }
            )
        }
        let authority = await authorities.waitForAuthority()
        await fixture.provider.waitUntilCancellationStarts()

        let stopOutcome = await fixture.invocations.stop(
            StopCoachInvocationRequest(
                library: fixture.scope,
                chatID: fixture.request.chatID,
                pendingUserTurnID: fixture.request.pendingUserTurnID
            ),
            authority: authority
        )
        await fixture.provider.resumeCancellation()
        _ = await invocationTask.value

        guard case let .interrupted(aggregate) = stopOutcome,
              case let .coachTranscriptReadFailed(summary)? =
              aggregate.pendingUserTurn?.failure
        else {
            return XCTFail("Stop must persist the terminal transcript summary")
        }
        XCTAssertEqual(
            summary.sessions.map(\.sessionAttachmentID),
            [try ChatSessionAttachmentID("attachment-1")]
        )
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(publicationCount, 0)
    }

    func testStopCapturesTranscriptTerminalBeforeCoordinatorReport() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            includesOnDemandAttachment: true,
            providerTranscriptReadPlan: .terminalBeforeCoordinatorReport,
            transcriptAvailability: AttemptTranscriptAvailabilitySource { _ in
                .unavailable
            }
        )
        let authorities = InvocationStopAuthorityRecorder()
        await fixture.provider.suspendNextLaunch()
        let invocationTask = Task {
            await fixture.invocations.tryInvoke(
                fixture.request,
                observingStopAuthority: { authority in
                    await authorities.record(authority)
                }
            )
        }
        let authority = await authorities.waitForAuthority()
        await fixture.provider.waitUntilTranscriptReadCount(1)

        let stopOutcome = await fixture.invocations.stop(
            StopCoachInvocationRequest(
                library: fixture.scope,
                chatID: fixture.request.chatID,
                pendingUserTurnID: fixture.request.pendingUserTurnID
            ),
            authority: authority
        )
        _ = await invocationTask.value

        guard case let .interrupted(aggregate) = stopOutcome,
              case let .coachTranscriptReadFailed(summary)? =
              aggregate.pendingUserTurn?.failure
        else {
            return XCTFail("Stop must capture an already-terminal broker summary")
        }
        XCTAssertEqual(summary.additionalSessionCount, 0)
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(publicationCount, 0)
    }

    func testTranscriptFailureRetainsLivenessUntilExactReapCanBeConfirmed()
        async throws
    {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            includesOnDemandAttachment: true,
            providerTranscriptReadPlan: .all,
            transcriptAvailability: AttemptTranscriptAvailabilitySource { _ in
                .unavailable
            },
            providerCancellationOutcomes: [
                .unableToConfirm,
                .unableToConfirm,
                .reaped,
            ]
        )
        let authorities = InvocationStopAuthorityRecorder()
        await fixture.provider.suspendNextLaunch()
        let invocationTask = Task {
            await fixture.invocations.tryInvoke(
                fixture.request,
                observingStopAuthority: { authority in
                    await authorities.record(authority)
                }
            )
        }
        let authority = await authorities.waitForAuthority()
        await fixture.provider.waitUntilCancellationStarts()

        let invocationOutcome = await invocationTask.value
        let retainedInvocation = await fixture.persistence.activeInvocation
        let retainedAggregate = await fixture.persistence.aggregateSnapshot()
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(invocationOutcome, .providerReapPending(authority))
        XCTAssertNotNil(retainedInvocation)
        XCTAssertNil(retainedAggregate.pendingUserTurn?.failure)
        XCTAssertEqual(publicationCount, 0)

        let blockedSuccessor = await fixture.invocations.tryInvoke(
            fixture.request
        )
        XCTAssertEqual(
            blockedSuccessor,
            .rejected(nil, .activeInvocation)
        )
        let launchesWhileUnreaped = await fixture.provider.requests.count
        XCTAssertEqual(
            launchesWhileUnreaped,
            1,
            "no successor provider may start behind an unreaped authority"
        )

        let firstStopOutcome = await fixture.invocations.stop(
            StopCoachInvocationRequest(
                library: fixture.scope,
                chatID: fixture.request.chatID,
                pendingUserTurnID: fixture.request.pendingUserTurnID
            ),
            authority: authority
        )
        XCTAssertEqual(firstStopOutcome, .unableToReap)
        let stillActiveInvocation = await fixture.persistence.activeInvocation
        XCTAssertNotNil(stillActiveInvocation)

        let stopOutcome = await fixture.invocations.stop(
            StopCoachInvocationRequest(
                library: fixture.scope,
                chatID: fixture.request.chatID,
                pendingUserTurnID: fixture.request.pendingUserTurnID
            ),
            authority: authority
        )

        guard case let .interrupted(terminal) = stopOutcome else {
            return XCTFail("the retained authority must allow exact reap retry")
        }
        guard case let .coachTranscriptReadFailed(summary)? =
            terminal.pendingUserTurn?.failure
        else { return XCTFail("the retained terminal summary must survive reap retry") }
        XCTAssertEqual(
            summary.sessions.map(\.sessionAttachmentID),
            [try ChatSessionAttachmentID("attachment-1")]
        )
        XCTAssertEqual(summary.additionalSessionCount, 0)
        let activeInvocation = await fixture.persistence.activeInvocation
        let cancelledAttemptIDs = await fixture.provider.cancelledAttemptIDs
        XCTAssertNil(activeInvocation)
        XCTAssertEqual(
            cancelledAttemptIDs,
            [authority.attemptID, authority.attemptID, authority.attemptID]
        )
        let event = try XCTUnwrap(fixture.diagnostics.recordedEvents().last)
        XCTAssertEqual(event.reason, .transcriptSessionUnavailable)
        XCTAssertEqual(event.classification, .transcriptReadFailure)
    }

    func testTranscriptFailureRetryUsesFreshAuthorityAndStableAttachmentIdentity()
        async throws
    {
        let availability = SequencedTranscriptAvailability(
            results: [.unavailable, .available]
        )
        let identities = RetryInvocationIdentities()
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [
                .complete(markdown: "discarded first result"),
                .complete(markdown: "Retry succeeds."),
            ],
            includesOnDemandAttachment: true,
            providerTranscriptReadPlan: .all,
            transcriptAvailability: AttemptTranscriptAvailabilitySource { query in
                await availability.inspect(query)
            },
            identityGenerator: identities
        )
        let authorities = InvocationStopAuthorityRecorder()

        let first = await fixture.invocations.tryInvoke(
            fixture.request,
            observingStopAuthority: { authority in
                await authorities.record(authority)
            }
        )
        guard case let .interrupted(firstAggregate?, .providerFailed) = first,
              case let .coachTranscriptReadFailed(summary)? =
              firstAggregate.pendingUserTurn?.failure
        else { return XCTFail("the first read must retain a Retryable failure") }
        let firstRequests = await fixture.provider.requests
        let firstRequest = try XCTUnwrap(firstRequests.first)
        let firstAccess = try XCTUnwrap(firstRequest.transcriptAccess)

        guard case .published = await fixture.invocations.tryInvoke(
            fixture.request,
            observingStopAuthority: { authority in
                await authorities.record(authority)
            }
        ) else { return XCTFail("Retry must publish after storage recovers") }

        let requests = await fixture.provider.requests
        let attempts = await authorities.waitForDistinctAttempts(2)
        let readResults = await fixture.provider.transcriptReadResults
        let queries = await availability.queries
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(Set(attempts.map(\.invocationID)).count, 2)
        XCTAssertEqual(Set(attempts.map(\.attemptID)).count, 2)
        XCTAssertNotEqual(
            requests[0].transcriptAccess?.handles,
            requests[1].transcriptAccess?.handles
        )
        XCTAssertEqual(
            try requests.map(maskingTranscriptDescriptorHandles(in:)),
            Array(
                repeating: try maskingTranscriptDescriptorHandles(in: requests[0]),
                count: 2
            )
        )
        XCTAssertEqual(
            summary.sessions.map(\.sessionAttachmentID),
            [try ChatSessionAttachmentID("attachment-1")]
        )
        XCTAssertEqual(
            queries.map(\.sessionAttachmentID),
            Array(
                repeating: try ChatSessionAttachmentID("attachment-1"),
                count: 2
            )
        )
        guard case let .delivered(retryDelivery) = try XCTUnwrap(readResults.last) else {
            return XCTFail("Retry must receive one complete atomic response")
        }
        XCTAssertTrue(
            String(decoding: retryDelivery.responseBody, as: UTF8.self)
                .contains(#""sessionAttachmentId":"attachment-1""#)
        )
        let oldCapabilityResult = await firstAccess.read(
            transportRequestID: AttemptTranscriptTransportRequestID("late-read")!,
            handles: firstAccess.handles
        )
        XCTAssertEqual(oldCapabilityResult, .rejected(.closed))
    }

    func testFreshHandleBudgetFailureBecomesDurableContextCapacityFailure()
        async throws
    {
        let estimator = try CoachTokenEstimator(
            identifier: "fresh-handle-penalty-fixture-v1",
            mode: .exact,
            maximumUTF8BytesPerToken: 1,
            implementation: { data in
                data.count + (String(decoding: data, as: UTF8.self).contains(
                    "00000000-0000-0000-0001-"
                ) ? 1_000_000 : 0)
            }
        )
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            includesOnDemandAttachment: true,
            providerTranscriptReadPlan: .all,
            tokenEstimator: estimator
        )
        guard case let .contextCapacityFailure(aggregate, _) =
            await fixture.invocations.tryInvoke(fixture.request)
        else {
            return XCTFail("fresh transport bytes must be remeasured exactly")
        }
        XCTAssertEqual(aggregate.pendingUserTurn?.failure, .coachContextCannotFit)
        let publicationCount = await fixture.persistence.publicationCount
        let transcriptReadResults = await fixture.provider.transcriptReadResults
        let providerRequests = await fixture.provider.requests
        let cancelledAttemptIDs = await fixture.provider.cancelledAttemptIDs
        let admissionCount = await fixture.admission.claimCount
        XCTAssertEqual(publicationCount, 0)
        XCTAssertTrue(transcriptReadResults.isEmpty)
        XCTAssertTrue(providerRequests.isEmpty)
        XCTAssertTrue(cancelledAttemptIDs.isEmpty)
        XCTAssertEqual(admissionCount, 0)
        let event = try XCTUnwrap(fixture.diagnostics.recordedEvents().last)
        XCTAssertEqual(event.reason, .transcriptContextCannotFit)
        XCTAssertEqual(event.classification, .contextCapacity)
    }

    func testUnmeasuredShorterRepairInstructionCannotLaunchPastInputCeiling()
        async throws
    {
        let estimator = try CoachTokenEstimator(
            identifier: "repair-instruction-penalty-fixture-v1",
            mode: .exact,
            maximumUTF8BytesPerToken: 1,
            implementation: { data in
                data.count + (String(decoding: data, as: UTF8.self).contains(
                    "The previous Attempt exceeded the response limit."
                ) ? 1_000_000 : 0)
            }
        )
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [.responseOverflow],
            tokenEstimator: estimator
        )

        guard case let .contextCapacityFailure(aggregate, _) =
            await fixture.invocations.tryInvoke(fixture.request)
        else {
            return XCTFail("repair instructions must be remeasured before install")
        }

        XCTAssertEqual(aggregate.pendingUserTurn?.failure, .coachContextCannotFit)
        let providerRequests = await fixture.provider.requests
        let installedOrdinals = await fixture.persistence.installedAttemptOrdinals
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(providerRequests.count, 1)
        XCTAssertEqual(installedOrdinals, [1])
        XCTAssertEqual(publicationCount, 0)
    }

    func testInvalidAttemptTranscriptReadIsTerminalWithoutPublication() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            includesOnDemandAttachment: true,
            providerTranscriptReadPlan: .duplicateFirst
        )
        await fixture.provider.suspendNextLaunch()

        let invocationTask = Task {
            await fixture.invocations.tryInvoke(fixture.request)
        }
        await fixture.provider.waitUntilCancellationStarts()
        guard case let .interrupted(aggregate?, .invalidProviderResponse) =
            await invocationTask.value
        else {
            return XCTFail("a malformed transcript request must close the Attempt")
        }
        XCTAssertEqual(aggregate.pendingUserTurn?.failure, .coachResponseInvalid)
        let publicationCount = await fixture.persistence.publicationCount
        let transcriptReadResults = await fixture.provider.transcriptReadResults
        XCTAssertEqual(publicationCount, 0)
        XCTAssertEqual(
            try XCTUnwrap(transcriptReadResults.first),
            .rejected(.closed)
        )
        let event = try XCTUnwrap(fixture.diagnostics.recordedEvents().last)
        XCTAssertEqual(event.reason, .transcriptAccessProtocolFailure)
        XCTAssertEqual(event.classification, .invalidProviderResponse)
    }

    func testThirdExactTranscriptReadIsTerminalWithoutPublication() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            includesOnDemandAttachment: true,
            providerTranscriptReadPlan: .threeExactReads
        )

        guard case let .interrupted(aggregate?, .invalidProviderResponse) =
            await fixture.invocations.tryInvoke(fixture.request)
        else {
            return XCTFail("a third read after the one replay must close the Attempt")
        }

        XCTAssertEqual(aggregate.pendingUserTurn?.failure, .coachResponseInvalid)
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(publicationCount, 0)
        let results = await fixture.provider.transcriptReadResults
        XCTAssertEqual(results.count, 3)
        guard case let .delivered(first) = results[0],
              case let .delivered(replay) = results[1]
        else { return XCTFail("the first read and one exact replay must be delivered") }
        XCTAssertFalse(first.isReplay)
        XCTAssertTrue(replay.isReplay)
        XCTAssertEqual(results[2], .rejected(.closed))
        let event = try XCTUnwrap(fixture.diagnostics.recordedEvents().last)
        XCTAssertEqual(event.reason, .transcriptAccessProtocolFailure)
        XCTAssertEqual(event.classification, .invalidProviderResponse)
    }

    func testSecondSemanticTranscriptReadIsTerminalWithoutPublication()
        async throws
    {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            includesOnDemandAttachment: true,
            providerTranscriptReadPlan: .secondSemanticExactRead
        )

        guard case let .interrupted(aggregate?, .invalidProviderResponse) =
            await fixture.invocations.tryInvoke(fixture.request)
        else {
            return XCTFail("a new transport identity must be a second semantic call")
        }

        XCTAssertEqual(aggregate.pendingUserTurn?.failure, .coachResponseInvalid)
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(publicationCount, 0)
        let results = await fixture.provider.transcriptReadResults
        XCTAssertEqual(results.count, 2)
        guard case let .delivered(first) = results[0] else {
            return XCTFail("the first semantic read must be delivered")
        }
        XCTAssertFalse(first.isReplay)
        XCTAssertEqual(results[1], .rejected(.closed))
    }

    func testProviderCompletionWhileTranscriptAvailabilityIsCheckingIsTerminal()
        async throws
    {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            includesOnDemandAttachment: true,
            providerTranscriptReadPlan: .completeWhileReadChecksAvailability,
            transcriptAvailability: AttemptTranscriptAvailabilitySource { _ in
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return .available
            }
        )

        guard case let .interrupted(aggregate?, .invalidProviderResponse) =
            await fixture.invocations.tryInvoke(fixture.request)
        else {
            return XCTFail("a provider cannot complete around an unfinished read")
        }

        XCTAssertEqual(aggregate.pendingUserTurn?.failure, .coachResponseInvalid)
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(publicationCount, 0)
        let results = await fixture.provider.drainPendingTranscriptReadResults()
        XCTAssertEqual(results, [.rejected(.closed)])
        let cancelledAttemptCount = await fixture.provider.cancelledAttemptIDs.count
        XCTAssertEqual(cancelledAttemptCount, 1)
    }

    func testProviderCompletionBeforeFinalTranscriptAuthorizationIsTerminal()
        async throws
    {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            includesOnDemandAttachment: true,
            providerTranscriptReadPlan: .completeBeforeReadAuthorization
        )

        guard case let .interrupted(aggregate?, .invalidProviderResponse) =
            await fixture.invocations.tryInvoke(fixture.request)
        else {
            return XCTFail("completion cannot overtake the disclosure fence")
        }

        XCTAssertEqual(aggregate.pendingUserTurn?.failure, .coachResponseInvalid)
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(publicationCount, 0)
        await fixture.provider.releaseTranscriptReadAuthorization()
        let results = await fixture.provider.drainPendingTranscriptReadResults()
        XCTAssertEqual(results, [.rejected(.closed)])
        let cancelledAttemptCount = await fixture.provider.cancelledAttemptIDs.count
        XCTAssertEqual(cancelledAttemptCount, 1)
    }

    func testStoppingOneLibraryDoesNotReplaceAnotherLibrarysActiveControl()
        async throws
    {
        let first = try InvocationFixture(contextWindow: 100_000)
        let secondScope = LibraryScope(
            libraryID: try LibraryID("lib-20260830T121000000Z-2DEF")
        )
        let secondAggregate = try makePendingInvocationAggregate(
            instant: first.instant,
            chatID: "cht-20260830T121000000Z-A234",
            draftID: "drf-20260830T121000000Z-B345",
            memoryID: "mem-20260830T121000000Z-C456",
            pendingID: "ptu-20260830T121000000Z-D567",
            responsePositionID: "rsp-20260830T121000000Z-E678",
            draftText: "Keep the second Library invocation running."
        )
        let secondRequest = PendingCoachInvocationRequest(
            library: secondScope,
            chatID: secondAggregate.chat.id,
            pendingUserTurnID: try XCTUnwrap(secondAggregate.pendingUserTurn).id
        )
        let secondPersistence = MemoryInvocationPersistence(
            initial: secondAggregate
        )
        let persistence = LibraryRoutingInvocationPersistence(
            routes: [
                first.scope.libraryID: first.persistence,
                secondScope.libraryID: secondPersistence,
            ]
        )
        let provider = TwoLibrarySuspendingProvider()
        let identities = try TwoLibraryInvocationIdentities()
        let invocations = DefaultInvocations(
            persistence: persistence,
            admission: ScriptedInvocationAdmission(decision: .admitted),
            provider: provider,
            coachContext: DefaultCoachContextFeature(
                source: InvocationContextSource(
                    contextWindow: 100_000,
                    isCurrent: true
                )
            ),
            clock: FixedInvocationClock(instant: first.instant),
            identities: identities,
            memoryIDGenerator: FixedInvocationMemoryIDs(
                memoryID: first.replacementMemoryID
            ),
            retrySleeper: RecordingInvocationRetrySleeper(),
            retryDiagnostics: RecordingInvocationRetryDiagnostics(),
            retryTiming: ScriptedInvocationRetryTiming(milliseconds: [0])
        )
        let firstAuthorities = InvocationStopAuthorityRecorder()
        let secondAuthorities = InvocationStopAuthorityRecorder()

        let firstTask = Task {
            await invocations.tryInvoke(
                first.request,
                observingStopAuthority: { authority in
                    await firstAuthorities.record(authority)
                }
            )
        }
        await provider.waitUntilLaunchCount(1)
        let firstAuthority = await firstAuthorities.waitForAuthority()

        let secondTask = Task {
            await invocations.tryInvoke(
                secondRequest,
                observingStopAuthority: { authority in
                    await secondAuthorities.record(authority)
                }
            )
        }
        await provider.waitUntilLaunchCount(2)
        let secondAuthority = await secondAuthorities.waitForAuthority()
        XCTAssertNotEqual(firstAuthority, secondAuthority)
        XCTAssertEqual(firstAuthority.library, first.scope)
        XCTAssertEqual(secondAuthority.library, secondScope)

        let stopOutcome = await invocations.stop(
            StopCoachInvocationRequest(
                library: first.scope,
                chatID: first.request.chatID,
                pendingUserTurnID: first.request.pendingUserTurnID
            ),
            authority: firstAuthority
        )

        guard case let .interrupted(firstTerminal) = stopOutcome else {
            return XCTFail("the first Library must stop independently")
        }
        XCTAssertEqual(
            firstTerminal.pendingUserTurn?.failure,
            .coachResponseInterrupted
        )
        let firstOutcome = await firstTask.value
        let firstActiveAfterStop = await first.persistence.activeInvocation
        let secondActiveAfterStop = await secondPersistence.activeInvocation
        let cancelledAttemptIDs = await provider.cancelledAttemptIDs
        let firstRunRemainsSuspended = await provider.isRunSuspended(
            attemptID: firstAuthority.attemptID
        )
        XCTAssertEqual(firstOutcome, .stopped)
        XCTAssertNil(firstActiveAfterStop)
        XCTAssertNotNil(secondActiveAfterStop)
        XCTAssertEqual(cancelledAttemptIDs, [firstAuthority.attemptID])
        XCTAssertTrue(
            firstRunRemainsSuspended,
            "reaping can finish before a non-cooperative late result arrives"
        )

        await provider.resume(attemptID: firstAuthority.attemptID)
        await provider.waitUntilRunFinishes(attemptID: firstAuthority.attemptID)
        let firstPublicationAfterLateResult = await first.persistence.publicationCount
        let secondStillActiveAfterLateResult = await secondPersistence.activeInvocation
        XCTAssertEqual(firstPublicationAfterLateResult, 0)
        XCTAssertNotNil(secondStillActiveAfterLateResult)

        await provider.resume(attemptID: secondAuthority.attemptID)
        guard case .published = await secondTask.value else {
            return XCTFail("stopping the first Library must not stop the second")
        }
        let firstPublicationCount = await first.persistence.publicationCount
        let secondPublicationCount = await secondPersistence.publicationCount
        let secondActiveAfterPublication = await secondPersistence.activeInvocation
        XCTAssertEqual(firstPublicationCount, 0)
        XCTAssertEqual(secondPublicationCount, 1)
        XCTAssertNil(secondActiveAfterPublication)
    }

    func testLateProviderCompletionAfterStopCannotPublishWhileReapIsPending() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        let authorities = InvocationStopAuthorityRecorder()
        await fixture.provider.suspendNextLaunch()
        await fixture.provider.suspendNextCancellation()
        let invocationTask = Task {
            await fixture.invocations.tryInvoke(
                fixture.request,
                observingStopAuthority: { authority in
                    await authorities.record(authority)
                }
            )
        }
        await fixture.provider.waitUntilLaunchStarts()
        let authority = await authorities.waitForAuthority()
        let stopTask = Task {
            await fixture.invocations.stop(
                StopCoachInvocationRequest(
                    library: fixture.scope,
                    chatID: fixture.request.chatID,
                    pendingUserTurnID: fixture.request.pendingUserTurnID
                ),
                authority: authority
            )
        }

        await fixture.provider.waitUntilCancellationStarts()
        let lateInvocationOutcome = await invocationTask.value
        XCTAssertEqual(lateInvocationOutcome, .stopped)
        let publicationCountBeforeReap = await fixture.persistence.publicationCount
        let activeBeforeReap = await fixture.persistence.activeInvocation
        XCTAssertEqual(publicationCountBeforeReap, 0)
        XCTAssertNotNil(activeBeforeReap, "liveness must remain held until reap")

        await fixture.provider.resumeCancellation()
        guard case let .interrupted(aggregate) = await stopTask.value else {
            return XCTFail("reaped Stop must persist interruption")
        }
        XCTAssertEqual(aggregate.pendingUserTurn?.failure, .coachResponseInterrupted)
        let finalPublicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(finalPublicationCount, 0)
    }

    func testStopDuringBackoffCancelsTimerAndNeverInstallsAnotherAttempt() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [
                .autoRetryableFailure,
                .complete(markdown: "must not launch"),
            ]
        )
        let authorities = InvocationStopAuthorityRecorder()
        await fixture.sleeper.suspendNextSleep()
        let invocationTask = Task {
            await fixture.invocations.tryInvoke(
                fixture.request,
                observingStopAuthority: { authority in
                    await authorities.record(authority)
                }
            )
        }
        await fixture.sleeper.waitUntilSleepStarts()
        let authority = await authorities.waitForAuthority()

        let stopOutcome = await fixture.invocations.stop(
            StopCoachInvocationRequest(
                library: fixture.scope,
                chatID: fixture.request.chatID,
                pendingUserTurnID: fixture.request.pendingUserTurnID
            ),
            authority: authority
        )

        guard case .interrupted = stopOutcome else {
            return XCTFail("backoff Stop must interrupt, got \(stopOutcome)")
        }
        _ = await invocationTask.value
        let installedOrdinals = await fixture.persistence.installedAttemptOrdinals
        let launchCount = await fixture.provider.launchCount
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(installedOrdinals, [1])
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(publicationCount, 0)
    }

    func testBackoffStopRetriesUnconfirmedReapWithSameAuthority() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [
                .autoRetryableFailure,
                .complete(markdown: "must not launch"),
            ],
            providerCancellationOutcomes: [.unableToConfirm, .reaped]
        )
        let authorities = InvocationStopAuthorityRecorder()
        await fixture.sleeper.suspendNextSleep()
        let invocationTask = Task {
            await fixture.invocations.tryInvoke(
                fixture.request,
                observingStopAuthority: { authority in
                    await authorities.record(authority)
                }
            )
        }
        await fixture.sleeper.waitUntilSleepStarts()
        let authority = await authorities.waitForAuthority()
        let request = StopCoachInvocationRequest(
            library: fixture.scope,
            chatID: fixture.request.chatID,
            pendingUserTurnID: fixture.request.pendingUserTurnID
        )

        let firstStop = await fixture.invocations.stop(
            request,
            authority: authority
        )
        XCTAssertEqual(firstStop, .unableToReap)
        guard case let .interrupted(aggregate) = await fixture.invocations.stop(
            request,
            authority: authority
        ) else {
            return XCTFail("backoff reap must remain retryable")
        }
        XCTAssertEqual(aggregate.pendingUserTurn?.failure, .coachResponseInterrupted)
        let invocationOutcome = await invocationTask.value
        XCTAssertEqual(invocationOutcome, .stopped)
        let launchCount = await fixture.provider.launchCount
        XCTAssertEqual(launchCount, 1)
    }

    func testStopDuringNonCooperativeBackoffReturnsBeforeSleeperFinishes()
        async throws
    {
        let sleeper = NonCooperativeInvocationRetrySleeper()
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [
                .autoRetryableFailure,
                .complete(markdown: "must not launch"),
            ],
            invocationRetrySleeper: sleeper
        )
        let authorities = InvocationStopAuthorityRecorder()
        let invocationTask = Task {
            await fixture.invocations.tryInvoke(
                fixture.request,
                observingStopAuthority: { authority in
                    await authorities.record(authority)
                }
            )
        }
        await sleeper.waitUntilSleepStarts()
        let authority = await authorities.waitForAuthority()

        let stopOutcome = await fixture.invocations.stop(
            StopCoachInvocationRequest(
                library: fixture.scope,
                chatID: fixture.request.chatID,
                pendingUserTurnID: fixture.request.pendingUserTurnID
            ),
            authority: authority
        )
        let invocationOutcome = await invocationTask.value
        let sleeperRemainsSuspended = await sleeper.isSuspended

        guard case .interrupted = stopOutcome else {
            return XCTFail("Stop must persist interruption without waiting on sleep")
        }
        XCTAssertEqual(invocationOutcome, .stopped)
        XCTAssertTrue(sleeperRemainsSuspended)
        let installedOrdinals = await fixture.persistence.installedAttemptOrdinals
        let launchCount = await fixture.provider.launchCount
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(installedOrdinals, [1])
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(publicationCount, 0)

        await sleeper.resume()
        await sleeper.waitUntilSleepFinishes()
        let finalPublicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(finalPublicationCount, 0)
    }

    func testStopDuringAttemptInstallAbortsReplacementBeforeItCanLaunch()
        async throws
    {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [
                .autoRetryableFailure,
                .complete(markdown: "must never launch"),
            ]
        )
        let authorities = InvocationStopAuthorityRecorder()
        await fixture.persistence.suspendNextAttemptInstall()
        let invocationTask = Task {
            await fixture.invocations.tryInvoke(
                fixture.request,
                observingStopAuthority: { authority in
                    await authorities.record(authority)
                }
            )
        }
        await fixture.persistence.waitUntilNextAttemptInstallStarts()
        let authority = await authorities.waitForAuthority()
        let stopTask = Task {
            await fixture.invocations.stop(
                StopCoachInvocationRequest(
                    library: fixture.scope,
                    chatID: fixture.request.chatID,
                    pendingUserTurnID: fixture.request.pendingUserTurnID
                ),
                authority: authority
            )
        }
        await fixture.provider.waitUntilCancellationStarts()

        let launchesBeforeInstallCompletes = await fixture.provider.launchCount
        XCTAssertEqual(launchesBeforeInstallCompletes, 1)
        await fixture.persistence.resumeNextAttemptInstall()

        guard case let .interrupted(aggregate) = await stopTask.value else {
            return XCTFail("Stop must retire the installed replacement")
        }
        XCTAssertEqual(aggregate.pendingUserTurn?.failure, .coachResponseInterrupted)
        let invocationOutcome = await invocationTask.value
        XCTAssertEqual(invocationOutcome, .stopped)
        let activeInvocation = await fixture.persistence.activeInvocation
        let launchCount = await fixture.provider.launchCount
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertNil(activeInvocation)
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(publicationCount, 0)
    }

    func testAttemptTransitionStopRetriesUnconfirmedReapWithSameAuthority()
        async throws
    {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [
                .autoRetryableFailure,
                .complete(markdown: "must never launch"),
            ],
            providerCancellationOutcomes: [.unableToConfirm, .reaped]
        )
        let authorities = InvocationStopAuthorityRecorder()
        await fixture.persistence.suspendNextAttemptInstall()
        let invocationTask = Task {
            await fixture.invocations.tryInvoke(
                fixture.request,
                observingStopAuthority: { authority in
                    await authorities.record(authority)
                }
            )
        }
        await fixture.persistence.waitUntilNextAttemptInstallStarts()
        let authority = await authorities.waitForAuthority()
        let request = StopCoachInvocationRequest(
            library: fixture.scope,
            chatID: fixture.request.chatID,
            pendingUserTurnID: fixture.request.pendingUserTurnID
        )
        let firstStop = Task {
            await fixture.invocations.stop(request, authority: authority)
        }
        await fixture.provider.waitUntilCancellationStarts()
        await fixture.persistence.resumeNextAttemptInstall()

        let firstStopOutcome = await firstStop.value
        XCTAssertEqual(firstStopOutcome, .unableToReap)
        guard case let .interrupted(aggregate) = await fixture.invocations.stop(
            request,
            authority: authority
        ) else {
            return XCTFail("transition reap must remain retryable")
        }
        XCTAssertEqual(aggregate.pendingUserTurn?.failure, .coachResponseInterrupted)
        let invocationOutcome = await invocationTask.value
        XCTAssertEqual(invocationOutcome, .stopped)
        let activeInvocation = await fixture.persistence.activeInvocation
        let launchCount = await fixture.provider.launchCount
        XCTAssertNil(activeInvocation)
        XCTAssertEqual(launchCount, 1)
    }

    func testStopOwnsInterruptionWhenSuspendedAttemptInstallLaterFails()
        async throws
    {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [
                .autoRetryableFailure,
                .complete(markdown: "must never launch"),
            ]
        )
        let authorities = InvocationStopAuthorityRecorder()
        await fixture.persistence.scriptNextAttemptInstall(.failed)
        await fixture.persistence.suspendNextAttemptInstall()
        let invocationTask = Task {
            await fixture.invocations.tryInvoke(
                fixture.request,
                observingStopAuthority: { authority in
                    await authorities.record(authority)
                }
            )
        }
        await fixture.persistence.waitUntilNextAttemptInstallStarts()
        let authority = await authorities.waitForAuthority()
        let stopTask = Task {
            await fixture.invocations.stop(
                StopCoachInvocationRequest(
                    library: fixture.scope,
                    chatID: fixture.request.chatID,
                    pendingUserTurnID: fixture.request.pendingUserTurnID
                ),
                authority: authority
            )
        }
        await fixture.provider.waitUntilCancellationStarts()
        await fixture.persistence.resumeNextAttemptInstall()

        guard case let .interrupted(aggregate) = await stopTask.value else {
            return XCTFail("Stop must own the terminal failure after revocation")
        }
        XCTAssertEqual(aggregate.pendingUserTurn?.failure, .coachResponseInterrupted)
        let invocationOutcome = await invocationTask.value
        XCTAssertEqual(invocationOutcome, .stopped)
        let activeInvocation = await fixture.persistence.activeInvocation
        let launchCount = await fixture.provider.launchCount
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertNil(activeInvocation)
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(publicationCount, 0)
        XCTAssertEqual(
            fixture.diagnostics.recordedEvents().map(\.reason),
            [.providerAutoRetryable, .coachResponseStopped]
        )
    }

    func testStopRejectsWrongRequestAndForgedAuthorityWithoutCancelling() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        let authorities = InvocationStopAuthorityRecorder()
        await fixture.provider.suspendNextLaunch()
        let invocationTask = Task {
            await fixture.invocations.tryInvoke(
                fixture.request,
                observingStopAuthority: { authority in
                    await authorities.record(authority)
                }
            )
        }
        await fixture.provider.waitUntilLaunchStarts()
        let authority = await authorities.waitForAuthority()
        let exactRequest = StopCoachInvocationRequest(
            library: fixture.scope,
            chatID: fixture.request.chatID,
            pendingUserTurnID: fixture.request.pendingUserTurnID
        )
        let wrongRequest = StopCoachInvocationRequest(
            library: fixture.scope,
            chatID: try ChatID("cht-20260830T120000000Z-WXYZ"),
            pendingUserTurnID: fixture.request.pendingUserTurnID
        )
        let forgedAuthority = InvocationStopAuthority(
            testingRequest: exactRequest,
            invocationID: authority.invocationID,
            attemptID: authority.attemptID,
            capabilityID: UUID()
        )

        let wrongRequestOutcome = await fixture.invocations.stop(
            wrongRequest,
            authority: authority
        )
        let forgedAuthorityOutcome = await fixture.invocations.stop(
            exactRequest,
            authority: forgedAuthority
        )
        XCTAssertEqual(wrongRequestOutcome, .staleAuthority)
        XCTAssertEqual(forgedAuthorityOutcome, .staleAuthority)
        let cancelledBeforeExactStop = await fixture.provider.cancelledAttemptIDs
        XCTAssertEqual(cancelledBeforeExactStop, [])

        guard case .interrupted = await fixture.invocations.stop(
            exactRequest,
            authority: authority
        ) else { return XCTFail("the exact authority must remain usable") }
        _ = await invocationTask.value
    }

    func testReplacementAttemptRejectsThePreviousStopAuthority() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [
                .autoRetryableFailure,
                .complete(markdown: "late second Attempt"),
            ]
        )
        let authorities = InvocationStopAuthorityRecorder()
        await fixture.provider.suspendLaunch(ordinal: 2)
        let invocationTask = Task {
            await fixture.invocations.tryInvoke(
                fixture.request,
                observingStopAuthority: { authority in
                    await authorities.record(authority)
                }
            )
        }
        await fixture.provider.waitUntilLaunchCount(2)
        let observed = await authorities.waitForDistinctAttempts(2)
        let staleAuthority = try XCTUnwrap(observed.first)
        let currentAuthority = try XCTUnwrap(observed.last)
        XCTAssertNotEqual(staleAuthority.attemptID, currentAuthority.attemptID)
        let request = StopCoachInvocationRequest(
            library: fixture.scope,
            chatID: fixture.request.chatID,
            pendingUserTurnID: fixture.request.pendingUserTurnID
        )

        let staleOutcome = await fixture.invocations.stop(
            request,
            authority: staleAuthority
        )
        XCTAssertEqual(staleOutcome, .staleAuthority)
        let cancelledAfterStaleStop = await fixture.provider.cancelledAttemptIDs
        XCTAssertEqual(cancelledAfterStaleStop, [])

        guard case .interrupted = await fixture.invocations.stop(
            request,
            authority: currentAuthority
        ) else { return XCTFail("the replacement Attempt authority must stop") }
        _ = await invocationTask.value
        let cancelledAttemptIDs = await fixture.provider.cancelledAttemptIDs
        XCTAssertEqual(cancelledAttemptIDs, [currentAuthority.attemptID])
    }

    func testPreparedNewInvocationCapabilityIsExactOneShotAndCannotBeForged() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.persistence.resetForNewSend(fixture.unlocked)
        let newRequest = try NewPendingCoachInvocationRequest(
            library: fixture.scope,
            observedAggregate: fixture.unlocked,
            pendingUserTurn: fixture.pending
        )
        guard case let .prepared(prepared) = await fixture.invocations
            .prepareNewInvocation(newRequest)
        else { return XCTFail("new Send did not acquire its exact Pending authority") }
        let forged = try PreparedPendingCoachInvocation(preparing: newRequest)

        let forgedOutcome = await fixture.invocations.tryInvoke(forged)
        XCTAssertEqual(
            forgedOutcome,
            .rejected(nil, .eligibilityChanged)
        )

        guard case .published = await fixture.invocations.tryInvoke(prepared) else {
            return XCTFail("the exact prepared capability did not invoke")
        }
        let reusedOutcome = await fixture.invocations.tryInvoke(prepared)
        let claimCount = await fixture.admission.claimCount
        let launchCount = await fixture.provider.launchCount
        XCTAssertEqual(
            reusedOutcome,
            .rejected(nil, .eligibilityChanged)
        )
        XCTAssertEqual(claimCount, 1)
        XCTAssertEqual(launchCount, 1)
    }

    func testAbandonPreparedNewInvocationReleasesAuthorityAndInvalidatesCapability() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.persistence.resetForNewSend(fixture.unlocked)
        let newRequest = try NewPendingCoachInvocationRequest(
            library: fixture.scope,
            observedAggregate: fixture.unlocked,
            pendingUserTurn: fixture.pending
        )
        guard case let .prepared(prepared) = await fixture.invocations
            .prepareNewInvocation(newRequest)
        else { return XCTFail("new Send did not acquire its exact Pending authority") }

        await fixture.invocations.abandonPreparedInvocation(prepared)

        let abandonedOutcome = await fixture.invocations.tryInvoke(prepared)
        XCTAssertEqual(
            abandonedOutcome,
            .rejected(nil, .eligibilityChanged)
        )
        let reacquired = await fixture.persistence.acquirePendingInvocation(
            prepared.request
        )
        XCTAssertEqual(
            reacquired,
            .acquired(
                try InvocationPendingAuthority(
                    request: prepared.request,
                    aggregate: prepared.aggregate
                )
            )
        )
        await fixture.persistence.cancelInvocationReservation(prepared.request)
    }

    func testReadOnlyAdmissionAvailabilityProjectsReopeningWithoutClaiming() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        let reopensAt = try UTCInstant("2026-08-30T12:01:00.000Z")
        await fixture.admission.setAvailability(.cooldown(reopensAt: reopensAt))

        let availability = await fixture.invocations.admissionAvailability(
            in: fixture.scope
        )

        XCTAssertEqual(availability, .cooldown(reopensAt: reopensAt))
        let claimCount = await fixture.admission.claimCount
        let availabilityCount = await fixture.admission.availabilityCount
        XCTAssertEqual(claimCount, 0)
        XCTAssertEqual(availabilityCount, 1)
    }

    func testSuccessPublishesOneTurnAfterSingleAdmissionAndProviderLaunch() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .published(aggregate, quote) = outcome else {
            return XCTFail("expected one complete publication, got \(outcome)")
        }
        XCTAssertTrue(quote.fits)
        XCTAssertEqual(aggregate.chat.messageIDs, [fixture.userMessageID, fixture.coachMessageID])
        XCTAssertEqual(aggregate.chat.draft.draftID, fixture.freshDraftID)
        XCTAssertEqual(aggregate.chat.draft.text, "")
        XCTAssertNil(aggregate.pendingUserTurn)
        let launchCount = await fixture.provider.launchCount
        let claimCount = await fixture.admission.claimCount
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(claimCount, 1)
        let exactBytes = await fixture.provider.serializedRequests
        XCTAssertEqual(exactBytes.count, 1)
        XCTAssertFalse(exactBytes[0].isEmpty)
        let publication = await fixture.persistence.lastPublication
        XCTAssertEqual(
            publication?.invocation.preparedProfile,
            fixture.contextSource.profile
        )
        XCTAssertEqual(
            publication?.coachMessage.coachProfile,
            fixture.contextSource.profile
        )
    }

    func testTransientProviderFailuresUseExactBoundedScheduleWithFreshAttemptAuthority() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [
                .autoRetryableFailure,
                .autoRetryableFailure,
                .autoRetryableFailure,
                .complete(markdown: "Fourth Attempt succeeds."),
            ],
            includesOnDemandAttachment: true
        )

        guard case .published = await fixture.invocations.tryInvoke(fixture.request) else {
            return XCTFail("the fourth and final bounded Attempt must publish")
        }

        let requests = await fixture.provider.requests
        XCTAssertEqual(requests.map(\.attemptOrdinal), [1, 2, 3, 4])
        XCTAssertEqual(requests.map(\.attemptKind), [
            .standard, .standard, .standard, .standard,
        ])
        XCTAssertEqual(Set(requests.map(\.attemptID)).count, 4)
        XCTAssertEqual(Set(requests.map(\.providerIdempotencyValue)).count, 4)
        let installedAttempts = await fixture.persistence.installedAttempts
        XCTAssertEqual(Set(installedAttempts.compactMap(\.userMessageID)).count, 4)
        XCTAssertEqual(Set(installedAttempts.compactMap(\.coachMessageID)).count, 4)
        XCTAssertEqual(Set(installedAttempts.compactMap(\.freshDraftID)).count, 4)
        XCTAssertEqual(
            Set(requests.compactMap { $0.transcriptAccess?.handles.first }).count,
            4
        )
        XCTAssertEqual(
            Set(requests.map { Data($0.exchange.request) }).count,
            4,
            "automatic retry must bind a fresh handle into every request"
        )
        let normalizedRequests = try requests.map(
            maskingTranscriptDescriptorHandles(in:)
        )
        XCTAssertEqual(
            normalizedRequests,
            Array(repeating: normalizedRequests[0], count: 4),
            "only the Attempt-local transcript handle may change"
        )
        let delays = await fixture.sleeper.delaysMilliseconds
        let installedOrdinals = await fixture.persistence.installedAttemptOrdinals
        let durableBeforeLaunch = await fixture.provider.durableBeforeLaunch
        let claimCount = await fixture.admission.claimCount
        XCTAssertEqual(delays, [5_000, 10_000, 15_000])
        XCTAssertEqual(installedOrdinals, [1, 2, 3, 4])
        XCTAssertEqual(durableBeforeLaunch, [true, true, true, true])
        XCTAssertEqual(claimCount, 1)
    }

    func testEveryProviderAttemptCarriesTheReservedOutputCeilingAndPinnedInstruction()
        async throws
    {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [
                .autoRetryableFailure,
                .responseOverflow,
                .complete(markdown: "Short complete response."),
            ]
        )

        guard case .published = await fixture.invocations.tryInvoke(fixture.request)
        else { return XCTFail("the shorter repair must publish") }

        let requests = await fixture.provider.requests
        XCTAssertEqual(requests.map(\.attemptKind), [
            .standard, .standard, .shorterRepair,
        ])
        XCTAssertEqual(requests.map(\.outputTokenCeiling), [512, 512, 512])
        let baseInstruction = DefaultInvocations.pinnedInstruction(
            outputTokenCeiling: 512
        )
        XCTAssertEqual(
            requests.map(\.pinnedInstruction),
            [
                baseInstruction,
                baseInstruction,
                baseInstruction + " " + DefaultInvocations.shorterRepairInstruction,
            ]
        )
        XCTAssertEqual(
            requests.map { $0.exchange.request },
            Array(repeating: requests[0].exchange.request, count: 3),
            "Attempt controls must not alter the frozen semantic request bytes"
        )
    }

    func testAutomaticRetriesRecordMetadataOnlyDiagnostics() async throws {
        let timing = ScriptedInvocationRetryTiming(
            milliseconds: [0, 7, 100, 111, 200, 213, 300]
        )
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [
                .autoRetryableFailure,
                .autoRetryableFailure,
                .autoRetryableFailure,
                .complete(markdown: "Fourth Attempt succeeds."),
            ],
            includesOnDemandAttachment: true,
            retryTiming: timing
        )

        guard case let .published(_, quote) =
            await fixture.invocations.tryInvoke(fixture.request)
        else {
            return XCTFail("the fourth Attempt must publish")
        }

        let events = fixture.diagnostics.recordedEvents()
        XCTAssertEqual(events.map(\.reason), [
            .providerAutoRetryable,
            .providerAutoRetryable,
            .providerAutoRetryable,
        ])
        XCTAssertEqual(
            events.map(\.classification),
            Array(repeating: .providerAutoRetryable, count: 3)
        )
        XCTAssertEqual(
            events.map(\.disposition),
            Array(repeating: .automaticRetry, count: 3)
        )
        XCTAssertEqual(events.map(\.attemptOrdinal), [1, 2, 3])
        XCTAssertEqual(events.map(\.retryNumber), [1, 2, 3])
        XCTAssertEqual(
            events.map(\.invocationID),
            Array(repeating: try CoachInvocationID(
                "inv-20260830T120000000Z-5KMN"
            ), count: 3)
        )
        let requests = await fixture.provider.requests
        XCTAssertEqual(events.map(\.attemptID), requests.prefix(3).map(\.attemptID))
        XCTAssertEqual(
            events.map(\.occurredAt),
            Array(repeating: fixture.instant, count: 3)
        )
        XCTAssertEqual(events.map(\.durationMilliseconds), [7, 11, 13])
        XCTAssertEqual(timing.callCount, 7)
        let exchange = try XCTUnwrap(requests.first?.exchange)
        let exactContext = try XCTUnwrap(events.first?.context)
        XCTAssertEqual(exactContext.requestUTF8Bytes, exchange.request.count)
        XCTAssertGreaterThan(exactContext.completeModelInputUTF8Bytes, 0)
        XCTAssertGreaterThan(exactContext.transcriptReadRequestUTF8Bytes, 0)
        XCTAssertGreaterThan(exactContext.transcriptReadResponseUTF8Bytes, 0)
        XCTAssertEqual(exactContext.completeInputTokens, quote.completeInputTokens)
        XCTAssertEqual(exactContext.inputCeilingTokens, quote.inputCeilingTokens)
        XCTAssertEqual(
            exactContext.memoryUTF8Bytes,
            quote.categoryCosts[.memory]?.utf8ByteCount ?? 0
        )
        XCTAssertGreaterThan(exactContext.memoryUTF8Bytes, 0)
        XCTAssertEqual(
            events.map(\.context),
            Array(repeating: exactContext, count: 3)
        )
    }

    func testSameInvocationIdentityCollisionRegeneratesBeforeInstallingNextAttempt() async throws {
        for collision in SameInvocationCollisionIdentities.Collision.allCases {
            let identities = SameInvocationCollisionIdentities(
                collision: collision,
                collidingCandidateCount: 1
            )
            let fixture = try InvocationFixture(
                contextWindow: 100_000,
                providerOutcomes: [
                    .autoRetryableFailure,
                    .complete(markdown: "A fresh second Attempt succeeds."),
                ],
                includesOnDemandAttachment: true,
                identityGenerator: identities
            )

            guard case .published = await fixture.invocations.tryInvoke(fixture.request)
            else {
                return XCTFail("a fresh candidate must recover from \(collision)")
            }

            let generatedIdentityCount = await identities.generatedAttemptIdentityCount
            let installedOrdinals = await fixture.persistence.installedAttemptOrdinals
            let launchCount = await fixture.provider.launchCount
            XCTAssertEqual(generatedIdentityCount, 3, "\(collision)")
            XCTAssertEqual(installedOrdinals, [1, 2], "\(collision)")
            XCTAssertEqual(launchCount, 2, "\(collision)")
        }
    }

    func testSameInvocationIdentityCollisionExhaustionNeverLaunchesAnUnrecordedAttempt() async throws {
        let identities = SameInvocationCollisionIdentities(
            collision: .attemptID,
            collidingCandidateCount: DefaultInvocations.maximumLaunchIdentityCandidates
        )
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [
                .autoRetryableFailure,
                .complete(markdown: "Must not launch."),
            ],
            includesOnDemandAttachment: true,
            identityGenerator: identities
        )

        guard case let .interrupted(aggregate, .persistenceUnavailable) =
            await fixture.invocations.tryInvoke(fixture.request)
        else { return XCTFail("bounded collision exhaustion must interrupt") }

        let generatedIdentityCount = await identities.generatedAttemptIdentityCount
        let installedOrdinals = await fixture.persistence.installedAttemptOrdinals
        let launchCount = await fixture.provider.launchCount
        XCTAssertEqual(
            generatedIdentityCount,
            DefaultInvocations.maximumLaunchIdentityCandidates + 1
        )
        XCTAssertEqual(installedOrdinals, [1])
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(aggregate?.pendingUserTurn?.failure, .coachResponseInterrupted)
        let events = fixture.diagnostics.recordedEvents()
        XCTAssertEqual(events.map(\.reason), [
            .providerAutoRetryable,
            .nextAttemptIdentityCollisionExhausted,
        ])
        XCTAssertEqual(
            events.map(\.classification),
            [.providerAutoRetryable, .retryInfrastructureFailure]
        )
        XCTAssertEqual(
            events.map(\.disposition),
            [.automaticRetry, .userRetryableFailure]
        )
        XCTAssertEqual(events.map(\.attemptOrdinal), [1, 1])
        XCTAssertEqual(events.map(\.retryNumber), [1, 1])
    }

    func testNextAttemptInstallFailuresRecordTerminalInfrastructureDiagnostics() async throws {
        let cases: [(
            directive: MemoryInvocationPersistence.NextAttemptInstallDirective,
            reason: InvocationRetryDiagnosticReason
        )] = [
            (.failed, .nextAttemptInstallationFailed),
            (.staleWithCurrent, .nextAttemptBecameStale),
        ]

        for testCase in cases {
            let fixture = try InvocationFixture(
                contextWindow: 100_000,
                providerOutcomes: [.autoRetryableFailure]
            )
            await fixture.persistence.scriptNextAttemptInstall(testCase.directive)

            guard case .interrupted(_, .persistenceUnavailable) =
                await fixture.invocations.tryInvoke(fixture.request)
            else { return XCTFail("next Attempt install must fail closed") }

        let events = fixture.diagnostics.recordedEvents()
            XCTAssertEqual(
                events.map(\.reason),
                [.providerAutoRetryable, testCase.reason]
            )
            XCTAssertEqual(
                events.map(\.classification),
                [.providerAutoRetryable, .retryInfrastructureFailure]
            )
            XCTAssertEqual(
                events.map(\.disposition),
                [.automaticRetry, .userRetryableFailure]
            )
            XCTAssertEqual(events.map(\.attemptOrdinal), [1, 1])
            XCTAssertEqual(events.map(\.retryNumber), [1, 1])
        }
    }

    func testNextAttemptConstructionFailureRecordsTerminalInfrastructureDiagnostic() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [.autoRetryableFailure],
            includesOnDemandAttachment: true,
            identityGenerator: MalformedNextAttemptIdentities()
        )

        guard case .interrupted(_, .persistenceUnavailable) =
            await fixture.invocations.tryInvoke(fixture.request)
        else { return XCTFail("malformed next Attempt must fail closed") }

        let events = fixture.diagnostics.recordedEvents()
        XCTAssertEqual(events.map(\.reason), [
            .providerAutoRetryable,
            .nextAttemptConstructionFailed,
        ])
        XCTAssertEqual(
            events.map(\.classification),
            [.providerAutoRetryable, .retryInfrastructureFailure]
        )
        XCTAssertEqual(
            events.map(\.disposition),
            [.automaticRetry, .userRetryableFailure]
        )
        XCTAssertEqual(events.map(\.attemptOrdinal), [1, 1])
        XCTAssertEqual(events.map(\.retryNumber), [1, 1])
    }

    func testOverflowUsesOneImmediateShorterCompleteRepairWithoutChangingSemanticBytes() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [
                .responseOverflow,
                .complete(markdown: "A materially shorter complete answer."),
            ]
        )

        guard case let .published(aggregate, _) = await fixture.invocations.tryInvoke(
            fixture.request
        ) else { return XCTFail("the single shorter repair must publish") }

        let requests = await fixture.provider.requests
        XCTAssertEqual(requests.map(\.attemptOrdinal), [1, 2])
        XCTAssertEqual(requests.map(\.attemptKind), [.standard, .shorterRepair])
        XCTAssertEqual(requests[0].exchange.request, requests[1].exchange.request)
        XCTAssertEqual(requests[0].control, .standard)
        XCTAssertEqual(
            requests[1].control,
            .shorterRepair(
                instruction: "The previous Attempt exceeded the response limit. " +
                    "Return a materially shorter complete response. Preserve the " +
                    "direct answer, remove repetition and optional detail, and " +
                    "never return partial JSON."
            )
        )
        let delays = await fixture.sleeper.recordedDelays()
        XCTAssertEqual(delays, [])
        let attempts = await fixture.persistence.installedAttempts
        XCTAssertEqual(
            aggregate.chat.messageIDs,
            [
                try XCTUnwrap(attempts[1].userMessageID),
                try XCTUnwrap(attempts[1].coachMessageID),
            ]
        )
        XCTAssertEqual(aggregate.chat.draft.draftID, attempts[1].freshDraftID)
    }

    func testRepeatedOverflowIsInvalidUserRetryableWithoutPartialPublication() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [.responseOverflow, .responseOverflow]
        )

        guard case let .interrupted(aggregate, .invalidProviderResponse) =
            await fixture.invocations.tryInvoke(fixture.request)
        else { return XCTFail("a repeated overflow must be terminal") }

        XCTAssertEqual(aggregate?.pendingUserTurn?.failure, .coachResponseInvalid)
        XCTAssertEqual(aggregate?.chat.messageIDs, [])
        let kinds = await fixture.provider.recordedAttemptKinds()
        let delays = await fixture.sleeper.recordedDelays()
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(kinds, [.standard, .shorterRepair])
        XCTAssertEqual(delays, [])
        XCTAssertEqual(publicationCount, 0)
        let events = fixture.diagnostics.recordedEvents()
        XCTAssertEqual(events.map(\.reason), [
            .responseOverflowRepair,
            .responseOverflowRepeated,
        ])
        XCTAssertEqual(
            events.map(\.classification),
            [.invalidProviderResponse, .invalidProviderResponse]
        )
        XCTAssertEqual(
            events.map(\.disposition),
            [.automaticRetry, .userRetryableFailure]
        )
        XCTAssertEqual(events.map(\.attemptOrdinal), [1, 2])
        XCTAssertEqual(events.map(\.retryNumber), [1, 2])
    }

    func testTransientFailureAfterShorterRepairDoesNotResumeStandardRetry() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [.responseOverflow, .autoRetryableFailure]
        )

        guard case let .interrupted(aggregate, .providerFailed) =
            await fixture.invocations.tryInvoke(fixture.request)
        else { return XCTFail("repair failure must be user-retryable") }

        XCTAssertEqual(aggregate?.pendingUserTurn?.failure, .coachProviderError)
        XCTAssertEqual(aggregate?.chat.messageIDs, [])
        let kinds = await fixture.provider.recordedAttemptKinds()
        let delays = await fixture.sleeper.recordedDelays()
        XCTAssertEqual(kinds, [.standard, .shorterRepair])
        XCTAssertEqual(delays, [])
        let events = fixture.diagnostics.recordedEvents()
        XCTAssertEqual(events.map(\.reason), [
            .responseOverflowRepair,
            .shorterRepairProviderFailure,
        ])
        XCTAssertEqual(
            events.map(\.classification),
            [.invalidProviderResponse, .providerUserRetryable]
        )
        XCTAssertEqual(
            events.map(\.disposition),
            [.automaticRetry, .userRetryableFailure]
        )
    }

    func testAutomaticRetryExhaustionPersistsProviderUserRetryableWithoutPartialPublication() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: Array(repeating: .autoRetryableFailure, count: 4)
        )

        guard case let .interrupted(aggregate, .providerFailed) =
            await fixture.invocations.tryInvoke(fixture.request)
        else { return XCTFail("four failed Attempts must exhaust the Invocation") }

        XCTAssertEqual(aggregate?.pendingUserTurn?.failure, .coachProviderError)
        XCTAssertEqual(aggregate?.chat.messageIDs, [])
        let ordinals = await fixture.provider.recordedAttemptOrdinals()
        let delays = await fixture.sleeper.recordedDelays()
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(ordinals, [1, 2, 3, 4])
        XCTAssertEqual(delays, [5_000, 10_000, 15_000])
        XCTAssertEqual(publicationCount, 0)
        let events = fixture.diagnostics.recordedEvents()
        XCTAssertEqual(events.map(\.reason), [
            .providerAutoRetryable,
            .providerAutoRetryable,
            .providerAutoRetryable,
            .automaticRetriesExhausted,
        ])
        XCTAssertEqual(events.map(\.retryNumber), [1, 2, 3, 4])
        XCTAssertEqual(events.last?.classification, .providerUserRetryable)
        XCTAssertEqual(events.last?.disposition, .userRetryableFailure)
    }

    func testRetrySleepFailureRecordsTerminalInfrastructureDiagnostic() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [.autoRetryableFailure]
        )
        await fixture.sleeper.failNextSleep()

        guard case let .interrupted(aggregate, .retryInfrastructureFailed) =
            await fixture.invocations.tryInvoke(fixture.request)
        else { return XCTFail("a failed retry sleep must interrupt") }

        XCTAssertEqual(
            aggregate?.pendingUserTurn?.failure,
            .coachResponseInterrupted
        )
        let events = fixture.diagnostics.recordedEvents()
        XCTAssertEqual(events.map(\.reason), [
            .providerAutoRetryable,
            .retrySleepFailed,
        ])
        XCTAssertEqual(
            events.map(\.classification),
            [.providerAutoRetryable, .retryInfrastructureFailure]
        )
        XCTAssertEqual(
            events.map(\.disposition),
            [.automaticRetry, .userRetryableFailure]
        )
        XCTAssertEqual(events.map(\.attemptOrdinal), [1, 1])
        XCTAssertEqual(events.map(\.retryNumber), [1, 1])
    }

    func testDurableOnlyAttemptRecordsTerminalRetryInfrastructureDiagnostic() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            includesOnDemandAttachment: true
        )
        await fixture.persistence.scriptNextInstall(.durableOnly)

        guard case let .interrupted(aggregate, .retryInfrastructureFailed) =
            await fixture.invocations.tryInvoke(fixture.request)
        else { return XCTFail("durable-only Attempt must fail closed before launch") }

        XCTAssertEqual(
            aggregate?.pendingUserTurn?.failure,
            .coachResponseInterrupted
        )
        let events = fixture.diagnostics.recordedEvents()
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.reason, .missingAttemptTransportAuthority)
        XCTAssertEqual(event.classification, .retryInfrastructureFailure)
        XCTAssertEqual(event.disposition, .userRetryableFailure)
        XCTAssertEqual(
            event.invocationID,
            try CoachInvocationID("inv-20260830T120000000Z-5KMN")
        )
        XCTAssertEqual(
            event.attemptID,
            try CoachProviderAttemptID("atm-20260830T120000000Z-6NPQ")
        )
        XCTAssertEqual(event.attemptOrdinal, 1)
        XCTAssertEqual(event.retryNumber, 1)
        XCTAssertEqual(event.occurredAt, fixture.instant)
        XCTAssertLessThan(event.durationMilliseconds, 60_000)
        XCTAssertGreaterThan(event.context.requestUTF8Bytes, 0)
        XCTAssertGreaterThan(event.context.completeModelInputUTF8Bytes, 0)
        XCTAssertGreaterThan(event.context.transcriptReadRequestUTF8Bytes, 0)
        XCTAssertGreaterThan(event.context.transcriptReadResponseUTF8Bytes, 0)
        XCTAssertGreaterThan(event.context.completeInputTokens, 0)
        XCTAssertGreaterThan(event.context.inputCeilingTokens, 0)
        XCTAssertGreaterThan(event.context.memoryUTF8Bytes, 0)
        let launchCount = await fixture.provider.launchCount
        XCTAssertEqual(launchCount, 0)
    }

    func testOverflowOnFourthAutomaticAttemptCannotCreateFifthRepairAttempt() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [
                .autoRetryableFailure,
                .autoRetryableFailure,
                .autoRetryableFailure,
                .responseOverflow,
            ]
        )

        guard case let .interrupted(aggregate, .invalidProviderResponse) =
            await fixture.invocations.tryInvoke(fixture.request)
        else { return XCTFail("fourth Attempt overflow must be terminal") }

        XCTAssertEqual(aggregate?.pendingUserTurn?.failure, .coachResponseInvalid)
        XCTAssertEqual(aggregate?.chat.messageIDs, [])
        let requests = await fixture.provider.requests
        XCTAssertEqual(requests.map(\.attemptOrdinal), [1, 2, 3, 4])
        XCTAssertEqual(
            requests.map(\.attemptKind),
            [.standard, .standard, .standard, .standard]
        )
        let delays = await fixture.sleeper.recordedDelays()
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(delays, [5_000, 10_000, 15_000])
        XCTAssertEqual(publicationCount, 0)
        let events = fixture.diagnostics.recordedEvents()
        XCTAssertEqual(events.map(\.reason), [
            .providerAutoRetryable,
            .providerAutoRetryable,
            .providerAutoRetryable,
            .responseOverflowAttemptLimitReached,
        ])
        XCTAssertEqual(events.last?.classification, .invalidProviderResponse)
        XCTAssertEqual(events.last?.disposition, .userRetryableFailure)
    }

    func testInvalidCompleteResponseIsTerminalWithoutAutomaticRetryOrPublication() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [.complete(markdown: "")]
        )

        guard case let .interrupted(aggregate, .invalidProviderResponse) =
            await fixture.invocations.tryInvoke(fixture.request)
        else { return XCTFail("an invalid complete response must not be repaired") }

        XCTAssertEqual(aggregate?.pendingUserTurn?.failure, .coachResponseInvalid)
        XCTAssertEqual(aggregate?.chat.messageIDs, [])
        let ordinals = await fixture.provider.recordedAttemptOrdinals()
        let delays = await fixture.sleeper.recordedDelays()
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(ordinals, [1])
        XCTAssertEqual(delays, [])
        XCTAssertEqual(publicationCount, 0)
    }

    func testInvalidOptionalResponseComponentRejectsWholeBatchWithoutLeakingProviderProse()
        async throws
    {
        let sentinel = "PRIVATE-PROVIDER-PROSE-MUST-NOT-PUBLISH"
        let raw = """
        {
          "messageBlocks":[{"kind":"markdown","markdown":"\(sentinel)"}],
          "newMemory":{
            "generalNotes":"valid",
            "sessionSummaries":[
              {"sessionAttachmentId":"not-attached","notes":"invalid target"}
            ]
          }
        }
        """
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [
                .complete(CoachProviderCompleteResponse(body: Data(raw.utf8))),
            ]
        )

        guard case let .interrupted(aggregate, .invalidProviderResponse) =
            await fixture.invocations.tryInvoke(fixture.request)
        else { return XCTFail("one invalid component must reject the whole batch") }

        let interrupted = try XCTUnwrap(aggregate)
        XCTAssertEqual(interrupted.chat.messageIDs, [])
        XCTAssertEqual(interrupted.chat.draft, fixture.initial.chat.draft)
        XCTAssertEqual(interrupted.memory, fixture.initial.memory)
        XCTAssertEqual(interrupted.pendingUserTurn?.id, fixture.pending.id)
        XCTAssertEqual(
            interrupted.pendingUserTurn?.failure,
            .coachResponseInvalid
        )
        XCTAssertFalse(
            interrupted.chat.messageIDs.contains(where: {
                $0.rawValue.contains(sentinel)
            })
        )
        let ordinals = await fixture.provider.recordedAttemptOrdinals()
        let delays = await fixture.sleeper.recordedDelays()
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(ordinals, [1])
        XCTAssertEqual(delays, [])
        XCTAssertEqual(publicationCount, 0)
        let events = fixture.diagnostics.recordedEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.reason, .responseMemoryInvalid)
        XCTAssertEqual(events.first?.classification, .invalidProviderResponse)
        XCTAssertEqual(events.first?.disposition, .userRetryableFailure)
    }

    func testValidChangedMemoryPublishesWithTheCompleteTurn() async throws {
        let raw = """
        {
          "messageBlocks":[{"kind":"markdown","markdown":"Use one deliberate pause."}],
          "newMemory":{
            "generalNotes":"Practice a deliberate pause before transitions.",
            "sessionSummaries":[]
          }
        }
        """
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [
                .complete(CoachProviderCompleteResponse(body: Data(raw.utf8))),
            ]
        )

        guard case let .published(published, _) =
            await fixture.invocations.tryInvoke(fixture.request)
        else { return XCTFail("valid changed Memory must publish atomically") }

        XCTAssertEqual(
            published.chat.messageIDs,
            [fixture.userMessageID, fixture.coachMessageID]
        )
        XCTAssertEqual(
            published.memory.memoryID,
            fixture.replacementMemoryID
        )
        XCTAssertEqual(
            published.memory.generalNotes,
            "Practice a deliberate pause before transitions."
        )
        XCTAssertEqual(
            published.chat.currentMemoryID,
            fixture.replacementMemoryID
        )
        XCTAssertNil(published.pendingUserTurn)
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(publicationCount, 1)
    }

    func testOmittedOrCanonicallyEqualMemoryRetainsTheCurrentSnapshotIdentity()
        async throws
    {
        let responses = [
            #"{"messageBlocks":[{"kind":"markdown","markdown":"No replacement."}]}"#,
            #"{"messageBlocks":[{"kind":"markdown","markdown":"Same replacement."}],"newMemory":{"generalNotes":"","sessionSummaries":[]}}"#,
        ]

        for raw in responses {
            let fixture = try InvocationFixture(
                contextWindow: 100_000,
                providerOutcomes: [
                    .complete(CoachProviderCompleteResponse(body: Data(raw.utf8))),
                ]
            )

            guard case let .published(published, _) =
                await fixture.invocations.tryInvoke(fixture.request)
            else { return XCTFail("retained Memory response must publish") }

            XCTAssertEqual(published.memory, fixture.initial.memory)
            XCTAssertEqual(
                published.chat.currentMemoryID,
                fixture.initial.chat.currentMemoryID
            )
        }
    }

    func testPureEvidenceResponseAtomicallyPublishesTurnMemoryAndStagedOperation()
        async throws
    {
        let statementID = "stm-20260830T110000000Z-1ABC"
        let response = """
        {
          "messageBlocks":[{"kind":"markdown","markdown":"Keep this evidence with the Profile."}],
          "newMemory":{
            "generalNotes":"Practice deliberate transitions.",
            "sessionSummaries":[]
          },
          "appendProfileEvidence":[{
            "targetStatementId":"\(statementID)",
            "evidence":[{
              "sessionAttachmentId":"attachment-1",
              "target":{"kind":"audioEvent","audioEventId":"a000000"}
            }]
          }]
        }
        """
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            responseReservedTokens: 2_048,
            providerOutcomes: [
                .complete(CoachProviderCompleteResponse(body: Data(response.utf8))),
            ],
            includesOnDemandAttachment: true,
            activeProfileStatementIDs: [statementID]
        )

        guard case let .published(published, _) =
            await fixture.invocations.tryInvoke(fixture.request)
        else {
            return XCTFail("pure Profile evidence must stage with the published turn")
        }

        XCTAssertEqual(
            published.chat.messageIDs,
            [fixture.userMessageID, fixture.coachMessageID]
        )
        XCTAssertEqual(published.memory.memoryID, fixture.replacementMemoryID)
        XCTAssertEqual(
            published.memory.generalNotes,
            "Practice deliberate transitions."
        )
        XCTAssertNil(published.pendingUserTurn)
        XCTAssertNil(published.profileProposal)
        let publication = try XCTUnwrap(published.profileEvidencePublication)
        XCTAssertEqual(publication.chatID, published.chat.id)
        XCTAssertEqual(
            publication.responsePositionID,
            fixture.pending.responsePositionID
        )
        XCTAssertEqual(publication.createdAt, fixture.instant)
        XCTAssertEqual(publication.evidenceAppends.count, 1)
        XCTAssertEqual(
            publication.evidenceAppends[0].target.statementID,
            try ProfileStatementID(statementID)
        )
        XCTAssertEqual(
            publication.evidenceAppends[0].target.wording,
            "Speak with clarity."
        )
        XCTAssertEqual(publication.evidenceAppends[0].evidence.count, 1)
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(publicationCount, 1)
    }

    func testSemanticAndMixedProfileEffectsPublishAsOneChatOwnedProposal()
        async throws
    {
        let first = "stm-20260830T110000000Z-1ABC"
        let second = "stm-20260830T110100000Z-2DEF"
        let third = "stm-20260830T110200000Z-3GHJ"
        let response = """
        {
          "messageBlocks":[{"kind":"markdown","markdown":"Review this Profile suggestion."}],
          "proposeProfileEdits":[
            {
              "edit":{
                "kind":"add",
                "statementKind":"goal",
                "wording":"Pause before each new point."
              },
              "evidence":[{
                "sessionAttachmentId":"attachment-1",
                "target":{
                  "kind":"wordRange",
                  "startWordId":"w000000",
                  "endWordId":"w000000"
                }
              }]
            },
            {
              "edit":{
                "kind":"replace",
                "targetStatementId":"\(first)",
                "wording":"Explain one idea at a time."
              }
            },
            {
              "edit":{
                "kind":"retire",
                "targetStatementId":"\(second)"
              }
            }
          ],
          "appendProfileEvidence":[{
            "targetStatementId":"\(third)",
            "evidence":[{
              "sessionAttachmentId":"attachment-1",
              "target":{"kind":"audioEvent","audioEventId":"a000000"}
            }]
          }]
        }
        """
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            responseReservedTokens: 2_048,
            providerOutcomes: [
                .complete(
                    CoachProviderCompleteResponse(body: Data(response.utf8))
                ),
            ],
            includesOnDemandAttachment: true,
            activeProfileStatementIDs: [first, second, third]
        )

        guard case let .published(published, _) =
            await fixture.invocations.tryInvoke(fixture.request)
        else { return XCTFail("semantic Profile effects must publish for review") }

        let proposal = try XCTUnwrap(published.profileProposal)
        XCTAssertNil(published.profileEvidencePublication)
        XCTAssertEqual(proposal.chatID, published.chat.id)
        XCTAssertEqual(proposal.responsePositionID, fixture.pending.responsePositionID)
        XCTAssertEqual(proposal.baseProfile, fixture.contextSource.profile)
        XCTAssertEqual(proposal.changes.count, 3)
        XCTAssertEqual(proposal.evidenceAppends.count, 1)
        XCTAssertTrue(proposal.id.rawValue.hasPrefix("prp-"))
        let proposedIDs = proposal.changes.compactMap { change -> ProfileStatementID? in
            switch change {
            case let .add(statement): statement.statementID
            case let .replace(_, replacement): replacement.statementID
            case .retire: nil
            }
        }
        XCTAssertEqual(Set(proposedIDs).count, 2)
        XCTAssertTrue(proposedIDs.allSatisfy { $0.rawValue.hasPrefix("stm-") })
        XCTAssertEqual(
            proposal.changes.flatMap(\.evidence).first?.sessionID,
            fixture.initial.chat.attachments.values[0].sessionID
        )
        XCTAssertNil(published.pendingUserTurn)
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(publicationCount, 1)
    }

    func testDuplicateExactReplacementNormalizesBeforeStatementIdentityAllocation()
        async throws
    {
        let target = "stm-20260830T110000000Z-1ABC"
        let response = """
        {
          "messageBlocks":[{"kind":"markdown","markdown":"Review this refinement."}],
          "proposeProfileEdits":[
            {
              "edit":{
                "kind":"replace",
                "targetStatementId":"\(target)",
                "wording":"Explain one idea at a time."
              },
              "evidence":[{
                "sessionAttachmentId":"attachment-1",
                "target":{
                  "kind":"wordRange",
                  "startWordId":"w000000",
                  "endWordId":"w000000"
                }
              }]
            },
            {
              "edit":{
                "kind":"replace",
                "targetStatementId":"\(target)",
                "wording":"Explain one idea at a time."
              },
              "evidence":[{
                "sessionAttachmentId":"attachment-1",
                "target":{"kind":"audioEvent","audioEventId":"a000000"}
              }]
            }
          ]
        }
        """
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            responseReservedTokens: 2_048,
            providerOutcomes: [
                .complete(CoachProviderCompleteResponse(body: Data(response.utf8))),
            ],
            includesOnDemandAttachment: true,
            activeProfileStatementIDs: [target]
        )

        guard case let .published(published, _) =
            await fixture.invocations.tryInvoke(fixture.request),
              let proposal = published.profileProposal,
              proposal.changes.count == 1,
              case let .replace(_, replacement) = proposal.changes[0]
        else { return XCTFail("duplicate replacement must normalize") }

        XCTAssertEqual(replacement.evidence.count, 2)
        XCTAssertEqual(Set(replacement.evidence.map(\.sessionID)).count, 1)
    }

    func testDuplicateExactAdditionNormalizesBeforeStatementIdentityAllocation()
        async throws
    {
        let response = """
        {
          "messageBlocks":[{"kind":"markdown","markdown":"Review this goal."}],
          "proposeProfileEdits":[
            {
              "edit":{
                "kind":"add",
                "statementKind":"goal",
                "wording":"Pause before each new point."
              },
              "evidence":[{
                "sessionAttachmentId":"attachment-1",
                "target":{
                  "kind":"wordRange",
                  "startWordId":"w000000",
                  "endWordId":"w000000"
                }
              }]
            },
            {
              "edit":{
                "kind":"add",
                "statementKind":"goal",
                "wording":"Pause before each new point."
              },
              "evidence":[{
                "sessionAttachmentId":"attachment-1",
                "target":{"kind":"audioEvent","audioEventId":"a000000"}
              }]
            }
          ]
        }
        """
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            responseReservedTokens: 2_048,
            providerOutcomes: [
                .complete(CoachProviderCompleteResponse(body: Data(response.utf8))),
            ],
            includesOnDemandAttachment: true
        )

        guard case let .published(published, _) =
            await fixture.invocations.tryInvoke(fixture.request),
              let proposal = published.profileProposal,
              proposal.changes.count == 1,
              case let .add(statement) = proposal.changes[0]
        else { return XCTFail("duplicate addition must normalize") }

        XCTAssertEqual(statement.evidence.count, 2)
        XCTAssertEqual(Set(statement.evidence.map(\.sessionID)).count, 1)
    }

    func testEvidenceObservationPublishesResolvedStructuredCoachBlocks() async throws {
        let response = CoachProviderCompleteResponse(
            body: Data(
                """
                {
                  "messageBlocks":[
                    {"kind":"markdown","markdown":"Try one deliberate pause."},
                    {
                      "kind":"evidenceObservation",
                      "markdown":"This pause clearly separated your points.",
                      "evidence":[{
                        "sessionAttachmentId":"attachment-1",
                        "target":{"kind":"wordRange","startWordId":"w000000","endWordId":"w000000"}
                      }]
                    }
                  ]
                }
                """.utf8
            )
        )
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [.complete(response)],
            includesOnDemandAttachment: true
        )

        guard case let .published(aggregate, _) =
            await fixture.invocations.tryInvoke(fixture.request)
        else { return XCTFail("resolved evidence response must publish") }

        XCTAssertEqual(
            aggregate.chat.messageIDs,
            [fixture.userMessageID, fixture.coachMessageID]
        )
        let recordedPublication = await fixture.persistence.lastPublication
        let publication = try XCTUnwrap(recordedPublication)
        guard case let .coach(blocks) = publication.coachMessage.content,
              case let .evidenceObservation(_, evidence) = blocks[1]
        else { return XCTFail("expected structured evidence block") }
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(evidence[0].display.sessionLabel, "Fixture Session")
        XCTAssertEqual(evidence[0].display.trustedText, "Pause")
        XCTAssertEqual(evidence[0].display.startMilliseconds, 0)
        XCTAssertEqual(evidence[0].display.endMilliseconds, 900)
        XCTAssertEqual(
            evidence[0].sessionID,
            try SessionID("ses-20260830T115900000Z-1ABC")
        )
        XCTAssertEqual(
            evidence[0].transcriptRevisionID,
            try TranscriptRevisionID("trv-20260830T115900000Z-2DEF")
        )
    }

    func testContextCapacityFailureIsDurableAndConsumesNoAdmissionOrProviderLaunch() async throws {
        let fixture = try InvocationFixture(contextWindow: 8)

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .contextCapacityFailure(aggregate, quote) = outcome else {
            return XCTFail("expected the #21 durable recovery")
        }
        XCTAssertFalse(quote.fits)
        XCTAssertEqual(aggregate.pendingUserTurn?.id, fixture.pending.id)
        XCTAssertEqual(aggregate.pendingUserTurn?.failure, .coachContextCannotFit)
        XCTAssertEqual(aggregate.chat.draft, fixture.initial.chat.draft)
        let claimCount = await fixture.admission.claimCount
        let launchCount = await fixture.provider.launchCount
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(claimCount, 0)
        XCTAssertEqual(launchCount, 0)
        XCTAssertEqual(publicationCount, 0)
        let event = try XCTUnwrap(fixture.diagnostics.recordedEvents().first)
        XCTAssertEqual(fixture.diagnostics.recordedEvents().count, 1)
        XCTAssertEqual(event.reason.rawValue, "contextCapacityExceeded")
        XCTAssertEqual(event.classification.rawValue, "contextCapacity")
        XCTAssertEqual(event.disposition, .userRetryableFailure)
        XCTAssertNil(event.invocationID)
        XCTAssertNil(event.attemptID)
        XCTAssertNil(event.attemptOrdinal)
        XCTAssertNil(event.retryNumber)
        XCTAssertEqual(event.context.completeInputTokens, quote.completeInputTokens)
        XCTAssertEqual(event.context.inputCeilingTokens, quote.inputCeilingTokens)
        XCTAssertGreaterThan(event.context.memoryUTF8Bytes, 0)
    }

    func testCapacityFailureRetryUsesSameIntentAndPublishesThroughFreshInvocation() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            pendingFailure: .coachContextCannotFit
        )

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .published(aggregate, _) = outcome else {
            return XCTFail("the retryable Pending intent must re-enter the gateway")
        }
        XCTAssertEqual(
            aggregate.chat.messageIDs,
            [fixture.userMessageID, fixture.coachMessageID]
        )
        XCTAssertNil(aggregate.pendingUserTurn)
        let claimCount = await fixture.admission.claimCount
        let launchCount = await fixture.provider.launchCount
        XCTAssertEqual(claimCount, 1)
        XCTAssertEqual(launchCount, 1)
    }

    func testRetryAdmissionRejectionRetainsExactFailureAndLaunchesNothing() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            admissionDecision: .cooldown(
                lastAdmittedAt: UTCInstant("2026-08-30T11:59:30.001Z"),
                reopensAt: UTCInstant("2026-08-30T12:00:30.001Z")
            ),
            pendingFailure: .coachContextCannotFit
        )

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .rejected(aggregate, .admissionCooldown) = outcome else {
            return XCTFail("expected retry admission rejection")
        }
        XCTAssertEqual(aggregate, fixture.initial)
        XCTAssertEqual(
            aggregate?.pendingUserTurn?.failure,
            .coachContextCannotFit
        )
        let launchCount = await fixture.provider.launchCount
        XCTAssertEqual(launchCount, 0)
        let event = try XCTUnwrap(fixture.diagnostics.recordedEvents().first)
        XCTAssertEqual(fixture.diagnostics.recordedEvents().count, 1)
        XCTAssertEqual(event.reason.rawValue, "admissionCooldown")
        XCTAssertEqual(event.classification.rawValue, "admissionRejected")
        XCTAssertEqual(event.disposition, .userRetryableFailure)
        XCTAssertNil(event.invocationID)
        XCTAssertNil(event.attemptID)
        XCTAssertNil(event.attemptOrdinal)
        XCTAssertNil(event.retryNumber)
        XCTAssertGreaterThan(event.context.requestUTF8Bytes, 0)
        XCTAssertGreaterThan(event.context.completeModelInputUTF8Bytes, 0)
    }

    func testOrdinaryAdmissionRejectionsUnlockWithoutFalseRetryDiagnostics() async throws {
        let cases: [(InvocationAdmissionClaimOutcome, InvocationRejectionReason)] = [
            (
                .cooldown(
                    lastAdmittedAt: try UTCInstant("2026-08-30T11:59:30.001Z"),
                    reopensAt: try UTCInstant("2026-08-30T12:00:30.001Z")
                ),
                .admissionCooldown
            ),
            (
                .clockRollback(
                    lastAdmittedAt: try UTCInstant("2026-08-30T12:00:01.000Z")
                ),
                .clockRollback
            ),
            (.ledgerFull, .admissionLedgerFull),
            (.unavailable, .admissionUnavailable),
        ]

        for (decision, expectedRejection) in cases {
            let fixture = try InvocationFixture(
                contextWindow: 100_000,
                admissionDecision: decision
            )

            guard case let .rejected(aggregate, rejection) =
                await fixture.invocations.tryInvoke(fixture.request)
            else { return XCTFail("expected an ordinary admission rejection") }

            XCTAssertEqual(rejection, expectedRejection)
            XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
            XCTAssertNil(aggregate?.pendingUserTurn)
            let launchCount = await fixture.provider.launchCount
            let publicationCount = await fixture.persistence.publicationCount
            XCTAssertEqual(launchCount, 0)
            XCTAssertEqual(publicationCount, 0)
            XCTAssertEqual(
                fixture.diagnostics.recordedEvents(),
                [],
                "an unlocked Draft has no product Retry/Discard state to diagnose"
            )
        }
    }

    func testEveryRetainedRetryAdmissionRejectionRecordsItsClosedReason() async throws {
        let cases: [(
            InvocationAdmissionClaimOutcome,
            InvocationRejectionReason,
            String
        )] = [
            (
                .cooldown(
                    lastAdmittedAt: try UTCInstant("2026-08-30T11:59:30.001Z"),
                    reopensAt: try UTCInstant("2026-08-30T12:00:30.001Z")
                ),
                .admissionCooldown,
                "admissionCooldown"
            ),
            (
                .clockRollback(
                    lastAdmittedAt: try UTCInstant("2026-08-30T12:00:01.000Z")
                ),
                .clockRollback,
                "admissionClockRollback"
            ),
            (.ledgerFull, .admissionLedgerFull, "admissionLedgerFull"),
            (.unavailable, .admissionUnavailable, "admissionUnavailable"),
        ]

        for (decision, expectedRejection, expectedDiagnostic) in cases {
            let fixture = try InvocationFixture(
                contextWindow: 100_000,
                admissionDecision: decision,
                pendingFailure: .coachContextCannotFit
            )

            guard case let .rejected(_, rejection) =
                await fixture.invocations.tryInvoke(fixture.request)
            else { return XCTFail("expected retained admission rejection") }

            XCTAssertEqual(rejection, expectedRejection)
            let event = try XCTUnwrap(fixture.diagnostics.recordedEvents().first)
            XCTAssertEqual(fixture.diagnostics.recordedEvents().count, 1)
            XCTAssertEqual(event.reason.rawValue, expectedDiagnostic)
            XCTAssertEqual(event.classification, .admissionRejected)
            XCTAssertNil(event.invocationID)
            XCTAssertNil(event.attemptID)
        }
    }

    func testAdmissionCommitUncertaintyRetainsExactPendingAsInterrupted() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            admissionDecision: .commitUncertain
        )

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .interrupted(aggregate, .persistenceUnavailable) = outcome else {
            return XCTFail("a possibly committed debit must remain user-retryable")
        }
        XCTAssertEqual(aggregate?.pendingUserTurn?.id, fixture.pending.id)
        XCTAssertEqual(
            aggregate?.pendingUserTurn?.failure,
            .coachResponseInterrupted
        )
        XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
        let claimCount = await fixture.admission.claimCount
        let launchCount = await fixture.provider.launchCount
        XCTAssertEqual(claimCount, 1)
        XCTAssertEqual(launchCount, 0)
        let event = try XCTUnwrap(fixture.diagnostics.recordedEvents().first)
        XCTAssertEqual(fixture.diagnostics.recordedEvents().count, 1)
        XCTAssertEqual(event.reason, .admissionCommitUncertain)
        XCTAssertEqual(event.classification, .interruption)
        XCTAssertNil(event.invocationID)
        XCTAssertNil(event.attemptID)
    }

    func testFailedInterruptedPendingMutationRecoversAuthoritativeDurableRetrySnapshot() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            admissionDecision: .commitUncertain
        )
        await fixture.persistence.scriptNextInterruptedMutation(
            .committedButReportedFailed
        )

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .interrupted(aggregate, .persistenceUnavailable) = outcome else {
            return XCTFail("terminal uncertainty must reconcile the durable Pending")
        }
        XCTAssertEqual(aggregate?.pendingUserTurn?.id, fixture.pending.id)
        XCTAssertEqual(
            aggregate?.pendingUserTurn?.failure,
            .coachResponseInterrupted
        )
        let recoveredRequests = await fixture.persistence.recoveredRequests
        XCTAssertEqual(recoveredRequests, [fixture.request])
    }

    func testFailedAbortWithUnavailableRecoveryReturnsExactOperationalRetryIntent() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.provider.failNextLaunch()
        await fixture.persistence.scriptNextAbort(.failedWithoutCommit)
        await fixture.persistence.scriptNextPendingRecovery(.unavailable)

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .operationallyInterrupted(
            aggregate,
            retryRequest,
            .persistenceUnavailable
        ) = outcome else {
            return XCTFail("unproven terminal persistence needs an operational Retry")
        }
        XCTAssertEqual(aggregate, fixture.initial)
        XCTAssertNil(aggregate?.pendingUserTurn?.failure)
        XCTAssertEqual(retryRequest, fixture.request)
        let recoveredRequests = await fixture.persistence.recoveredRequests
        XCTAssertEqual(recoveredRequests, [fixture.request])
        let events = fixture.diagnostics.recordedEvents()
        XCTAssertEqual(events.map(\.reason), [.providerUserRetryable])
        XCTAssertEqual(events.map(\.disposition), [.userRetryableFailure])
    }

    func testOperationalRetryReconcilesUnchangedPendingBeforeAtomicReacquisition() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.provider.failNextLaunch()
        await fixture.persistence.scriptNextAbort(.failedWithoutCommit)
        await fixture.persistence.scriptNextPendingRecovery(.unavailable)
        guard case .operationallyInterrupted = await fixture.invocations.tryInvoke(
            fixture.request
        ) else { return XCTFail("first attempt must retain operational Retry") }

        await fixture.persistence.scriptNextPendingRecovery(.current)
        let retry = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .published(aggregate, _) = retry else {
            return XCTFail("Retry must reconcile before reacquiring the unchanged Pending")
        }
        XCTAssertNil(aggregate.pendingUserTurn)
        XCTAssertEqual(
            aggregate.chat.messageIDs,
            [fixture.userMessageID, fixture.coachMessageID]
        )
        let recoveredRequests = await fixture.persistence.recoveredRequests
        XCTAssertEqual(recoveredRequests, [fixture.request, fixture.request])
    }

    func testInstallFailureAfterDurableDebitNeverLaunchesAndRetainsRetryableIntent() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.persistence.scriptNextInstall(.failed)

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .interrupted(aggregate, .persistenceUnavailable) = outcome else {
            return XCTFail("expected a durable interrupted failure")
        }
        let claimCount = await fixture.admission.claimCount
        let launchCount = await fixture.provider.launchCount
        XCTAssertEqual(claimCount, 1)
        XCTAssertEqual(launchCount, 0)
        XCTAssertEqual(aggregate?.pendingUserTurn?.id, fixture.pending.id)
        XCTAssertEqual(
            aggregate?.pendingUserTurn?.failure,
            .coachResponseInterrupted
        )
        XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
    }

    func testInstallStaleOutcomeRetainsAStillMatchingPendingAsInterrupted() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.persistence.scriptNextInstall(.staleWithCurrent)

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .interrupted(aggregate, .persistenceUnavailable) = outcome else {
            return XCTFail("a stale install must retain the matching Pending authority")
        }
        XCTAssertEqual(aggregate?.pendingUserTurn?.id, fixture.pending.id)
        XCTAssertEqual(
            aggregate?.pendingUserTurn?.failure,
            .coachResponseInterrupted
        )
        XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
        let launchCount = await fixture.provider.launchCount
        XCTAssertEqual(launchCount, 0)
    }

    func testInstallActiveExistsAfterDebitRetainsPendingAsInterrupted() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.persistence.scriptNextInstall(.activeExists)

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .interrupted(aggregate, .persistenceUnavailable) = outcome else {
            return XCTFail("a post-debit install conflict must retain the Pending intent")
        }
        XCTAssertEqual(aggregate?.pendingUserTurn?.id, fixture.pending.id)
        XCTAssertEqual(
            aggregate?.pendingUserTurn?.failure,
            .coachResponseInterrupted
        )
        let claimCount = await fixture.admission.claimCount
        let launchCount = await fixture.provider.launchCount
        XCTAssertEqual(claimCount, 1)
        XCTAssertEqual(launchCount, 0)
    }

    func testInstallStaleWithoutSnapshotStillTerminatesReservation() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.persistence.scriptNextInstall(.staleWithoutSnapshot)

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        XCTAssertEqual(outcome, .rejected(nil, .eligibilityChanged))
        let nextReservation = await fixture.persistence.acquirePendingInvocation(
            fixture.request
        )
        XCTAssertEqual(
            nextReservation,
            .acquired(
                try InvocationPendingAuthority(
                    request: fixture.request,
                    aggregate: fixture.initial
                )
            )
        )
        await fixture.persistence.cancelInvocationReservation(fixture.request)
    }

    func testCASConflictAfterProviderLaunchPublishesNeitherMessageAndRetiresInvocation() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.persistence.scriptNextPublication(.staleWithCurrent)

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .interrupted(aggregate, .publicationConflict) = outcome else {
            return XCTFail("expected a typed publication conflict")
        }
        let launchCount = await fixture.provider.launchCount
        let activeInvocation = await fixture.persistence.activeInvocation
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(aggregate?.chat.messageIDs, [])
        XCTAssertEqual(aggregate?.pendingUserTurn?.id, fixture.pending.id)
        XCTAssertEqual(
            aggregate?.pendingUserTurn?.failure,
            .coachResponseInterrupted
        )
        XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
        XCTAssertNil(activeInvocation)
        let events = fixture.diagnostics.recordedEvents()
        XCTAssertEqual(events.map(\.reason), [.publicationConflict])
        XCTAssertEqual(events.map(\.classification), [.publicationConflict])
        XCTAssertEqual(events.map(\.disposition), [.userRetryableFailure])
    }

    func testOversizedLockedMessageUsesLocalLimitBeforeContextAdmissionOrProvider() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            draftText: String(
                repeating: "x",
                count: CoachContextInputLimits.maximumUserMessageUTF8Bytes + 1
            )
        )

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .rejected(aggregate, .messageMustBeShortened(maximum)) = outcome else {
            return XCTFail("expected concise local shortening guidance")
        }
        XCTAssertEqual(maximum, CoachContextInputLimits.maximumUserMessageUTF8Bytes)
        XCTAssertNil(aggregate?.pendingUserTurn)
        XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
        let resolutionCount = await fixture.contextSource.pendingResolutionCount
        let claimCount = await fixture.admission.claimCount
        let launchCount = await fixture.provider.launchCount
        XCTAssertEqual(resolutionCount, 0)
        XCTAssertEqual(claimCount, 0)
        XCTAssertEqual(launchCount, 0)
    }

    func testChangedExactContextAfterDurableInstallAbortsAndUnlocksBeforeProvider() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000, contextIsCurrent: false)

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .rejected(aggregate, .contextChanged) = outcome else {
            return XCTFail("stale exact context must abort before launch")
        }
        XCTAssertEqual(aggregate?.pendingUserTurn?.id, fixture.pending.id)
        XCTAssertEqual(
            aggregate?.pendingUserTurn?.failure,
            .coachResponseInterrupted
        )
        XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
        let claimCount = await fixture.admission.claimCount
        let launchCount = await fixture.provider.launchCount
        let active = await fixture.persistence.activeInvocation
        XCTAssertEqual(claimCount, 1)
        XCTAssertEqual(launchCount, 0)
        XCTAssertNil(active)
        let event = try XCTUnwrap(fixture.diagnostics.recordedEvents().first)
        XCTAssertEqual(fixture.diagnostics.recordedEvents().count, 1)
        XCTAssertEqual(event.reason.rawValue, "preparedContextStale")
        XCTAssertEqual(event.classification.rawValue, "interruption")
        XCTAssertEqual(event.disposition, .userRetryableFailure)
        XCTAssertNotNil(event.invocationID)
        XCTAssertNotNil(event.attemptID)
        XCTAssertEqual(event.attemptOrdinal, 1)
        XCTAssertEqual(event.retryNumber, 1)
    }

    func testChangedExactContextWithStaleAbortRetainsOperationalRetryAndDiagnosesIt() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000, contextIsCurrent: false)
        await fixture.persistence.scriptNextAbort(.staleWithCurrent)

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .operationallyInterrupted(
            aggregate,
            retryRequest,
            .persistenceUnavailable
        ) = outcome else {
            return XCTFail("an unclassified installed Pending must retain Retry authority")
        }
        XCTAssertEqual(retryRequest, fixture.request)
        XCTAssertEqual(aggregate?.pendingUserTurn?.id, fixture.pending.id)
        XCTAssertNil(aggregate?.pendingUserTurn?.failure)
        XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
        let launchCount = await fixture.provider.launchCount
        let activeInvocation = await fixture.persistence.activeInvocation
        XCTAssertEqual(launchCount, 0)
        XCTAssertNil(activeInvocation)
        let events = fixture.diagnostics.recordedEvents()
        XCTAssertEqual(events.map(\.reason), [.preparedContextStale])
        XCTAssertEqual(events.map(\.classification), [.interruption])
        XCTAssertEqual(events.map(\.disposition), [.userRetryableFailure])
        XCTAssertEqual(events.first?.attemptOrdinal, 1)
    }

    func testProviderCrashPublishesNeitherSideAndRetiresInvocation() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.provider.failNextLaunch()

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .interrupted(aggregate, .providerFailed) = outcome else {
            return XCTFail("provider crash must retire the interrupted Invocation")
        }
        XCTAssertEqual(aggregate?.chat.messageIDs, [])
        XCTAssertEqual(aggregate?.pendingUserTurn?.id, fixture.pending.id)
        XCTAssertEqual(
            aggregate?.pendingUserTurn?.failure,
            .coachProviderError
        )
        XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
        let active = await fixture.persistence.activeInvocation
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertNil(active)
        XCTAssertEqual(publicationCount, 0)
        let events = fixture.diagnostics.recordedEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.reason, .providerUserRetryable)
        XCTAssertEqual(events.first?.classification, .providerUserRetryable)
        XCTAssertEqual(events.first?.disposition, .userRetryableFailure)
        XCTAssertEqual(events.first?.attemptOrdinal, 1)
        XCTAssertEqual(events.first?.retryNumber, 1)
    }

    func testProviderFailureDoesNotDiagnoseAStaleTurnWithoutRetryAuthority() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            providerOutcomes: [.userRetryableFailure]
        )
        await fixture.persistence.scriptNextAbort(.staleWithoutPending)

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .interrupted(aggregate, .providerFailed) = outcome else {
            return XCTFail("a stale terminal mutation must surface its current state")
        }
        XCTAssertNil(aggregate?.pendingUserTurn)
        XCTAssertEqual(
            fixture.diagnostics.recordedEvents(),
            [],
            "a retired Pending without Retry/Discard authority must not be diagnosed"
        )
    }

    func testInvalidProviderResponsePublishesNeitherSideAndRetiresInvocation() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.provider.returnInvalidResponseNextLaunch()

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .interrupted(aggregate, .invalidProviderResponse) = outcome else {
            return XCTFail("invalid response must retire the interrupted Invocation")
        }
        XCTAssertEqual(aggregate?.chat.messageIDs, [])
        XCTAssertEqual(aggregate?.pendingUserTurn?.id, fixture.pending.id)
        XCTAssertEqual(
            aggregate?.pendingUserTurn?.failure,
            .coachResponseInvalid
        )
        XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
        let active = await fixture.persistence.activeInvocation
        XCTAssertNil(active)
        let events = fixture.diagnostics.recordedEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.reason, .responseSchemaInvalid)
        XCTAssertEqual(events.first?.classification, .invalidProviderResponse)
        XCTAssertEqual(events.first?.disposition, .userRetryableFailure)
        XCTAssertEqual(events.first?.attemptOrdinal, 1)
        XCTAssertEqual(events.first?.retryNumber, 1)
    }

    func testPublicationFailurePublishesNeitherSideAndRetiresInvocation() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.persistence.scriptNextPublication(.failedWithoutCommit)

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .interrupted(aggregate, .persistenceUnavailable) = outcome else {
            return XCTFail("publication failure must retire the interrupted Invocation")
        }
        XCTAssertEqual(aggregate?.chat.messageIDs, [])
        XCTAssertEqual(aggregate?.pendingUserTurn?.id, fixture.pending.id)
        XCTAssertEqual(
            aggregate?.pendingUserTurn?.failure,
            .coachResponseInterrupted
        )
        XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
        let active = await fixture.persistence.activeInvocation
        XCTAssertNil(active)
        let events = fixture.diagnostics.recordedEvents()
        XCTAssertEqual(
            events.map(\.reason),
            [.publicationPersistenceUnavailable]
        )
        XCTAssertEqual(events.map(\.classification), [.persistenceUnavailable])
        XCTAssertEqual(events.map(\.disposition), [.userRetryableFailure])
    }

    func testPublicationAbortStaleFailureFreePendingBecomesOperationalRetry()
        async throws
    {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.persistence.scriptNextPublication(.failedWithoutCommit)
        await fixture.persistence.scriptNextAbort(.staleWithCurrent)

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .operationallyInterrupted(
            fallback,
            request,
            .persistenceUnavailable
        ) = outcome else {
            return XCTFail(
                "an exact failure-free Pending must retain operational Retry authority"
            )
        }
        XCTAssertEqual(fallback, fixture.initial)
        XCTAssertEqual(request, fixture.request)
        XCTAssertNil(fallback?.pendingUserTurn?.failure)
        XCTAssertEqual(
            fixture.diagnostics.recordedEvents().map(\.reason),
            [.publicationPersistenceUnavailable]
        )
    }

    func testCommittedPublicationSurvivesFailedImmediateReconciliationWithExactQuote() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.persistence.scriptNextPublication(
            .committedButReportedFailed(.unchanged)
        )

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .published(aggregate, quote) = outcome else {
            return XCTFail("an exact already-published replacement must remain published")
        }
        let observedPublication = await fixture.persistence.lastPublication
        let publication = try XCTUnwrap(observedPublication)
        let activeInvocation = await fixture.persistence.activeInvocation
        XCTAssertEqual(aggregate, publication.replacement)
        XCTAssertEqual(aggregate.chat.messageIDs, [
            fixture.userMessageID,
            fixture.coachMessageID,
        ])
        XCTAssertNil(aggregate.pendingUserTurn)
        XCTAssertTrue(quote.fits)
        XCTAssertNil(activeInvocation)
        XCTAssertEqual(
            fixture.diagnostics.recordedEvents(),
            [],
            "a recovered publication must not create a false Retry event"
        )
    }

    func testCommittedPublicationSurvivesAbortFailureAndRecoveryReread() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.persistence.scriptNextPublication(
            .committedButReportedFailed(.unchanged)
        )
        await fixture.persistence.scriptNextPublicationRecovery(.unavailable)
        await fixture.persistence.scriptNextAbort(.failedWithoutCommit)

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .published(aggregate, quote) = outcome else {
            return XCTFail("recovery must recognize the complete intended replacement")
        }
        let observedPublication = await fixture.persistence.lastPublication
        let publication = try XCTUnwrap(observedPublication)
        XCTAssertEqual(aggregate, publication.replacement)
        XCTAssertTrue(quote.fits)
        let recoveryCount = await fixture.persistence.publicationRecoveryCount
        XCTAssertEqual(recoveryCount, 2)
    }

    func testTypedPublicationRecoveryAllowsLaterRenameAndFreshDraftEdit() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.persistence.scriptNextPublication(
            .committedButReportedFailed(.evolveChat)
        )

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .published(aggregate, quote) = outcome else {
            return XCTFail("typed persistence proof must preserve the published turn")
        }
        XCTAssertEqual(aggregate.chat.title, try ChatTitle("Later title"))
        XCTAssertEqual(aggregate.chat.draft.draftID, fixture.freshDraftID)
        XCTAssertEqual(aggregate.chat.draft.version, 1)
        XCTAssertEqual(aggregate.chat.draft.text, "A later fresh Draft edit.")
        XCTAssertEqual(aggregate.chat.messageIDs, [
            fixture.userMessageID,
            fixture.coachMessageID,
        ])
        XCTAssertNil(aggregate.pendingUserTurn)
        XCTAssertTrue(quote.fits)
        let recoveryCount = await fixture.persistence.publicationRecoveryCount
        XCTAssertEqual(recoveryCount, 1)
    }

    func testOperationalRetryUsesTypedProofForEvolvedPublishedChat() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.persistence.scriptNextPublication(
            .committedButReportedFailed(.evolveChat)
        )
        await fixture.persistence.scriptNextPublicationRecovery(.unavailable)
        await fixture.persistence.scriptNextPublicationRecovery(.unavailable)
        await fixture.persistence.scriptNextAbort(.failedWithoutCommit)
        await fixture.persistence.scriptNextPendingRecovery(.unavailable)

        guard case let .operationallyInterrupted(
            fallback,
            retryRequest,
            .persistenceUnavailable
        ) = await fixture.invocations.tryInvoke(fixture.request)
        else { return XCTFail("unproven publication must retain operational Retry") }
        XCTAssertEqual(fallback, fixture.initial)
        XCTAssertEqual(retryRequest, fixture.request)
        XCTAssertEqual(
            fixture.diagnostics.recordedEvents().map(\.reason),
            [.publicationPersistenceUnavailable],
            "a surfaced operational Retry/Discard outcome must be diagnosed"
        )

        await fixture.persistence.scriptNextPendingRecovery(.current)
        let retry = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .published(aggregate, quote) = retry else {
            return XCTFail("Retry must consume the typed exact-publication proof")
        }
        XCTAssertEqual(aggregate.chat.title, try ChatTitle("Later title"))
        XCTAssertEqual(aggregate.chat.draft.draftID, fixture.freshDraftID)
        XCTAssertEqual(aggregate.chat.draft.version, 1)
        XCTAssertEqual(aggregate.chat.messageIDs, [
            fixture.userMessageID,
            fixture.coachMessageID,
        ])
        XCTAssertTrue(quote.fits)
        let claimCount = await fixture.admission.claimCount
        let recoveryCount = await fixture.persistence.publicationRecoveryCount
        XCTAssertEqual(claimCount, 1)
        XCTAssertEqual(recoveryCount, 3)
        XCTAssertEqual(
            fixture.diagnostics.recordedEvents().map(\.reason),
            [.publicationPersistenceUnavailable],
            "later proof must not duplicate the already-visible Retry event"
        )
    }

    func testTypedPublicationRejectionOverridesShallowReplacementEquality() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.persistence.scriptNextPublication(
            .shallowImpostorButReportedFailed
        )

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .interrupted(aggregate, .persistenceUnavailable) = outcome else {
            return XCTFail("an ID-only impostor must never be reported as published")
        }
        XCTAssertEqual(aggregate?.chat.messageIDs, [
            fixture.userMessageID,
            fixture.coachMessageID,
        ])
        let recoveryCount = await fixture.persistence.publicationRecoveryCount
        XCTAssertEqual(recoveryCount, 1)
    }

    func testConcurrentDuplicateRequestUsesOneAdmissionOneLaunchAndOnePublication() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.provider.suspendNextLaunch()

        async let first = fixture.invocations.tryInvoke(fixture.request)
        await fixture.provider.waitUntilLaunchStarts()
        let duplicate = await fixture.invocations.tryInvoke(fixture.request)

        XCTAssertEqual(duplicate, .rejected(nil, .activeInvocation))
        let claimCountWhileSuspended = await fixture.admission.claimCount
        let launchCountWhileSuspended = await fixture.provider.launchCount
        XCTAssertEqual(claimCountWhileSuspended, 1)
        XCTAssertEqual(launchCountWhileSuspended, 1)

        await fixture.provider.resumeLaunch()
        guard case .published = await first else {
            return XCTFail("the original Invocation must publish exactly once")
        }
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(publicationCount, 1)
    }

    func testSecondResolutionIneligibilityTerminatesTheExactReservation() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.persistence.scriptNextRevalidation(.ineligible)

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        XCTAssertEqual(outcome, .rejected(fixture.initial, .eligibilityChanged))
        let nextReservation = await fixture.persistence.acquirePendingInvocation(
            fixture.request
        )
        XCTAssertEqual(
            nextReservation,
            .acquired(
                try InvocationPendingAuthority(
                    request: fixture.request,
                    aggregate: fixture.initial
                )
            )
        )
        await fixture.persistence.cancelInvocationReservation(fixture.request)
    }

    func testIdentityCollisionRegeneratesBeforeAdmissionOrProviderLaunch() async throws {
        let fixture = try InvocationFixture(contextWindow: 100_000)
        await fixture.persistence.scriptIdentityChecks([
            .collision(.userMessageID)
        ])

        guard case .published = await fixture.invocations.tryInvoke(fixture.request) else {
            return XCTFail("a fresh available candidate must continue through publication")
        }

        let identityCheckCount = await fixture.persistence.identityCheckCount
        let claimCount = await fixture.admission.claimCount
        let launchCount = await fixture.provider.launchCount
        XCTAssertEqual(identityCheckCount, 2)
        XCTAssertEqual(claimCount, 1)
        XCTAssertEqual(launchCount, 1)
    }

    func testAdmissionDebitUsesAFreshInstantAfterIdentityPreflight() async throws {
        let identityInstant = try UTCInstant("2026-08-30T12:00:00.000Z")
        let admittedAt = try UTCInstant("2026-08-30T12:00:12.000Z")
        let completedAt = try UTCInstant("2026-08-30T12:00:13.000Z")
        let clock = SequencedInvocationClock(
            instants: [identityInstant, admittedAt, completedAt]
        )
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            clock: clock
        )

        guard case .published = await fixture.invocations.tryInvoke(fixture.request) else {
            return XCTFail("expected publication")
        }

        let claimedAt = await fixture.admission.claimedAt
        let publication = await fixture.persistence.lastPublication
        XCTAssertEqual(claimedAt, [admittedAt])
        XCTAssertEqual(publication?.invocation.admittedAt, admittedAt)
    }

    func testMalformedInitialTranscriptHandleAuthorityFailsBeforeAdmission() async throws {
        for mode in MalformedInitialAttemptIdentities.Mode.allCases {
            let fixture = try InvocationFixture(
                contextWindow: 100_000,
                includesOnDemandAttachment: true,
                identityGenerator: MalformedInitialAttemptIdentities(mode: mode)
            )

            guard case .rejected(_, .persistenceUnavailable) =
                await fixture.invocations.tryInvoke(fixture.request)
            else { return XCTFail("\(mode) must fail closed before admission") }

            let identityCheckCount = await fixture.persistence.identityCheckCount
            let installedOrdinals = await fixture.persistence.installedAttemptOrdinals
            let claimCount = await fixture.admission.claimCount
            let launchCount = await fixture.provider.launchCount
            XCTAssertEqual(identityCheckCount, 0, "\(mode)")
            XCTAssertEqual(installedOrdinals, [], "\(mode)")
            XCTAssertEqual(claimCount, 0, "\(mode)")
            XCTAssertEqual(launchCount, 0, "\(mode)")
        }
    }

    func testEveryIdentityNamespaceCollisionExhaustsBeforeAdmissionAndProvider() async throws {
        for collision in InvocationLaunchIdentityCollision.allCases {
            let fixture = try InvocationFixture(contextWindow: 100_000)
            await fixture.persistence.scriptIdentityChecks(
                Array(
                    repeating: .collision(collision),
                    count: DefaultInvocations.maximumLaunchIdentityCandidates
                )
            )

            let outcome = await fixture.invocations.tryInvoke(fixture.request)

            guard case let .rejected(
                _,
                .identityCollisionExhausted(lastCollision)
            ) = outcome else {
                return XCTFail("expected typed exhaustion for \(collision), got \(outcome)")
            }
            XCTAssertEqual(lastCollision, collision)
            let identityCheckCount = await fixture.persistence.identityCheckCount
            let claimCount = await fixture.admission.claimCount
            let launchCount = await fixture.provider.launchCount
            XCTAssertEqual(
                identityCheckCount,
                DefaultInvocations.maximumLaunchIdentityCandidates
            )
            XCTAssertEqual(claimCount, 0)
            XCTAssertEqual(launchCount, 0)
        }
    }
}

private func makePendingInvocationAggregate(
    instant: UTCInstant,
    chatID: String,
    draftID: String,
    memoryID: String,
    pendingID: String,
    responsePositionID: String,
    draftText: String
) throws -> ChatAggregate {
    let empty = try ChatAggregate.emptyDevelopmentChat(
        chatID: ChatID(chatID),
        draftID: ChatDraftID(draftID),
        memoryID: CoachMemoryID(memoryID),
        instant: instant,
        profileStatementGeneration: 7
    )
    let draft = try empty.chat.draft.edited(text: draftText, at: instant)
    let unlocked = try ChatAggregate(
        chat: empty.chat.replacingDraft(with: draft),
        memory: empty.memory
    )
    let pending = PendingUserTurn(
        id: try PendingUserTurnID(pendingID),
        draftID: draft.draftID,
        draftVersion: draft.version,
        responsePositionID: try ChatResponsePositionID(responsePositionID)
    )
    return try ChatAggregate(
        chat: unlocked.chat,
        memory: unlocked.memory,
        pendingUserTurn: pending
    )
}

private struct LibraryRoutingInvocationPersistence:
    ProfileReconsiderationUnavailableInvocationPersistencePort
{
    let routes: [LibraryID: MemoryInvocationPersistence]

    func openNewPendingInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> InvocationPendingSessionPreparationOutcome {
        guard let persistence = routes[request.library.libraryID] else {
            return .unavailable
        }
        return await persistence.openNewPendingInvocation(request)
    }

    func openPendingInvocation(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingSessionAcquisitionOutcome {
        guard let persistence = routes[request.library.libraryID] else {
            return .unavailable
        }
        return await persistence.openPendingInvocation(request)
    }

    func recoverPendingAfterTerminalFailure(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingResolutionOutcome {
        guard let persistence = routes[request.library.libraryID] else {
            return .unavailable
        }
        return await persistence.recoverPendingAfterTerminalFailure(request)
    }

    func recoverPublishedInvocation(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationRecoveryOutcome {
        guard let persistence = routes[mutation.invocation.libraryID] else {
            return .unavailable
        }
        return await persistence.recoverPublishedInvocation(mutation)
    }
}

private actor TwoLibraryInvocationIdentities: InvocationIdentityGenerating {
    private var invocationIDs: [CoachInvocationID]
    private var attemptIdentities: [InvocationAttemptIdentity]

    init() throws {
        invocationIDs = [
            try CoachInvocationID("inv-20260830T120000000Z-5KMN"),
            try CoachInvocationID("inv-20260830T121000000Z-A234"),
        ]
        attemptIdentities = [
            InvocationAttemptIdentity(
                attemptID: try CoachProviderAttemptID(
                    "atm-20260830T120000000Z-6NPQ"
                ),
                idempotencyValue: try ProviderIdempotencyValue(
                    "synthetic-attempt-first"
                ),
                userMessageID: try ChatMessageID(
                    "msg-20260830T120000000Z-7RST"
                ),
                coachMessageID: try ChatMessageID(
                    "msg-20260830T120000000Z-8VWX"
                ),
                freshDraftID: try ChatDraftID(
                    "drf-20260830T120000000Z-9YZ0"
                )
            ),
            InvocationAttemptIdentity(
                attemptID: try CoachProviderAttemptID(
                    "atm-20260830T121000000Z-B345"
                ),
                idempotencyValue: try ProviderIdempotencyValue(
                    "synthetic-attempt-second"
                ),
                userMessageID: try ChatMessageID(
                    "msg-20260830T121000000Z-C456"
                ),
                coachMessageID: try ChatMessageID(
                    "msg-20260830T121000000Z-D567"
                ),
                freshDraftID: try ChatDraftID(
                    "drf-20260830T121000000Z-E678"
                )
            ),
        ]
    }

    func generateInvocationID(at instant: UTCInstant) async -> CoachInvocationID {
        precondition(!invocationIDs.isEmpty)
        return invocationIDs.removeFirst()
    }

    func generateAttemptIdentity(
        at instant: UTCInstant,
        ordinal: UInt8,
        kind: CoachProviderAttemptKind,
        transcriptHandleCount: Int
    ) async -> InvocationAttemptIdentity {
        precondition(ordinal == 1)
        precondition(kind == .standard)
        precondition(transcriptHandleCount == 0)
        precondition(!attemptIdentities.isEmpty)
        return attemptIdentities.removeFirst()
    }
}

private actor TwoLibrarySuspendingProvider: SyntheticCoachProviderPort {
    private var continuations: [
        CoachProviderAttemptID: CheckedContinuation<Void, Never>
    ] = [:]
    private var launchCount = 0
    private var finishedAttemptIDs: Set<CoachProviderAttemptID> = []
    private(set) var cancelledAttemptIDs: [CoachProviderAttemptID] = []

    func run(
        _ request: SyntheticCoachProviderRequest
    ) async -> CoachProviderAttemptOutcome {
        launchCount += 1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            continuations[request.attemptID] = continuation
        }
        finishedAttemptIDs.insert(request.attemptID)
        return .complete(markdown: "A complete response for its own Library.")
    }

    func cancelAndReap(
        attemptID: CoachProviderAttemptID,
        graceMilliseconds: Int64
    ) async -> CoachProviderAttemptCancellationOutcome {
        cancelledAttemptIDs.append(attemptID)
        return .reaped
    }

    func waitUntilLaunchCount(_ count: Int) async {
        while launchCount < count { await Task.yield() }
    }

    func isRunSuspended(attemptID: CoachProviderAttemptID) -> Bool {
        continuations[attemptID] != nil
    }

    func resume(attemptID: CoachProviderAttemptID) {
        continuations.removeValue(forKey: attemptID)?.resume()
    }

    func waitUntilRunFinishes(attemptID: CoachProviderAttemptID) async {
        while !finishedAttemptIDs.contains(attemptID) { await Task.yield() }
    }
}

private final class InvocationFixture: @unchecked Sendable {
    let scope = LibraryScope(
        libraryID: try! LibraryID("lib-20260830T115900000Z-1ABC")
    )
    let instant = try! UTCInstant("2026-08-30T12:00:00.000Z")
    let unlocked: ChatAggregate
    let initial: ChatAggregate
    let pending: PendingUserTurn
    let request: PendingCoachInvocationRequest
    let persistence: MemoryInvocationPersistence
    let admission: ScriptedInvocationAdmission
    let provider: RecordingSyntheticCoachProvider
    let sleeper: RecordingInvocationRetrySleeper
    let diagnostics: RecordingInvocationRetryDiagnostics
    let contextSource: InvocationContextSource
    let invocations: DefaultInvocations

    let userMessageID = try! ChatMessageID("msg-20260830T120000000Z-7RST")
    let coachMessageID = try! ChatMessageID("msg-20260830T120000000Z-8VWX")
    let freshDraftID = try! ChatDraftID("drf-20260830T120000000Z-9YZ0")
    let replacementMemoryID = try! CoachMemoryID(
        "mem-20260830T120001000Z-1BCD"
    )

    init(
        contextWindow: Int,
        responseReservedTokens: Int = 512,
        admissionDecision: InvocationAdmissionClaimOutcome = .admitted,
        draftText: String = "Keep this exact user Draft",
        contextIsCurrent: Bool = true,
        pendingFailure: PendingUserTurnFailure? = nil,
        clock: (any ChatClock)? = nil,
        providerOutcomes: [CoachProviderAttemptOutcome] = [
            .complete(markdown: "A concise **synthetic** answer."),
        ],
        includesOnDemandAttachment: Bool = false,
        providerTranscriptReadPlan: ProviderTranscriptReadPlan = .none,
        transcriptAvailability: AttemptTranscriptAvailabilitySource = .allAvailable,
        providerCancellationOutcomes: [CoachProviderAttemptCancellationOutcome] = [
            .reaped,
        ],
        tokenEstimator: CoachTokenEstimator = .utf8ByteUpperBound(),
        activeProfileStatementIDs: [String] = [],
        identityGenerator: (any InvocationIdentityGenerating)? = nil,
        invocationRetrySleeper: (any InvocationRetrySleeping)? = nil,
        retryTiming: (any InvocationRetryTiming)? = nil
    ) throws {
        let attachments: ChatAttachments = if includesOnDemandAttachment {
            try ChatAttachments(
                validating: [
                    ChatSessionAttachment(
                        attachmentID: try ChatSessionAttachmentID("attachment-1"),
                        sessionID: try SessionID(
                            "ses-20260830T115900000Z-1ABC"
                        ),
                        transcriptRevisionID: try TranscriptRevisionID(
                            "trv-20260830T115900000Z-2DEF"
                        )
                    ),
                ]
            )
        } else {
            .empty
        }
        let empty = try ChatAggregate.newChat(
            chatID: ChatID("cht-20260830T120000000Z-1ABC"),
            draftID: ChatDraftID("drf-20260830T120000000Z-2DEF"),
            memoryID: CoachMemoryID("mem-20260830T120000000Z-3GHJ"),
            instant: instant,
            profileStatementGeneration: 7,
            attachments: attachments
        )
        let draft = try empty.chat.draft.edited(text: draftText, at: instant)
        unlocked = try ChatAggregate(
            chat: empty.chat.replacingDraft(with: draft),
            memory: empty.memory
        )
        pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120000000Z-4JKM"),
            draftID: draft.draftID,
            draftVersion: draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120000000Z-5MNP"
            ),
            failure: pendingFailure
        )
        initial = try ChatAggregate(
            chat: unlocked.chat,
            memory: unlocked.memory,
            pendingUserTurn: pending
        )
        request = PendingCoachInvocationRequest(
            library: scope,
            chatID: initial.chat.id,
            pendingUserTurnID: pending.id
        )
        persistence = MemoryInvocationPersistence(initial: initial)
        admission = ScriptedInvocationAdmission(decision: admissionDecision)
        provider = RecordingSyntheticCoachProvider(
            outcomes: providerOutcomes,
            persistence: persistence,
            transcriptReadPlan: providerTranscriptReadPlan,
            cancellationOutcomes: providerCancellationOutcomes
        )
        sleeper = RecordingInvocationRetrySleeper()
        diagnostics = RecordingInvocationRetryDiagnostics()
        contextSource = InvocationContextSource(
            contextWindow: contextWindow,
            responseReservedTokens: responseReservedTokens,
            isCurrent: contextIsCurrent,
            includesOnDemandAttachment: includesOnDemandAttachment,
            tokenEstimator: tokenEstimator,
            activeProfileStatementIDs: activeProfileStatementIDs
        )
        let defaultIdentities = FixedInvocationIdentities(
            invocationID: try CoachInvocationID(
                "inv-20260830T120000000Z-5KMN"
            ),
            attemptID: try CoachProviderAttemptID(
                "atm-20260830T120000000Z-6NPQ"
            ),
            idempotencyValue: try ProviderIdempotencyValue(
                "synthetic-attempt-6NPQ"
            ),
            userMessageID: userMessageID,
            coachMessageID: coachMessageID,
            freshDraftID: freshDraftID
        )
        invocations = DefaultInvocations(
            persistence: persistence,
            admission: admission,
            provider: provider,
            coachContext: DefaultCoachContextFeature(source: contextSource),
            clock: clock ?? FixedInvocationClock(instant: instant),
            identities: identityGenerator ?? defaultIdentities,
            memoryIDGenerator: FixedInvocationMemoryIDs(
                memoryID: replacementMemoryID
            ),
            retrySleeper: invocationRetrySleeper ?? sleeper,
            retryDiagnostics: diagnostics,
            retryTiming: retryTiming ?? ScriptedInvocationRetryTiming(
                milliseconds: [0]
            ),
            transcriptAvailability: transcriptAvailability
        )
    }
}

private struct FixedInvocationMemoryIDs: CoachMemoryIDGenerator {
    let memoryID: CoachMemoryID

    func generateCoachMemoryID(at instant: UTCInstant) async -> CoachMemoryID {
        memoryID
    }
}

private actor MemoryInvocationPersistence:
    ProfileReconsiderationUnavailableInvocationPersistencePort
{
    enum RevalidationDirective: Sendable {
        case current
        case ineligible
    }

    enum InstallDirective: Sendable {
        case installed
        case durableOnly
        case failed
        case activeExists
        case staleWithCurrent
        case staleWithoutSnapshot
    }

    enum NextAttemptInstallDirective: Sendable {
        case installed
        case failed
        case staleWithCurrent
    }

    enum InterruptedMutationDirective: Sendable {
        case committed
        case committedButReportedFailed
    }

    enum PendingRecoveryDirective: Sendable {
        case current
        case unavailable
    }

    enum AbortDirective: Sendable {
        case committed
        case failedWithoutCommit
        case staleWithCurrent
        case staleWithoutPending
    }

    enum PublicationEvolution: Sendable {
        case unchanged
        case evolveChat
    }

    enum PublicationDirective: Sendable {
        case committed
        case failedWithoutCommit
        case staleWithCurrent
        case committedButReportedFailed(PublicationEvolution)
        case shallowImpostorButReportedFailed
    }

    enum PublicationRecoveryDirective: Sendable {
        case current
        case unavailable
    }

    enum IdentityCheckDirective: Sendable {
        case available
        case collision(InvocationLaunchIdentityCollision)
    }

    private struct OperationScript<Directive: Sendable>: Sendable {
        private var directives: [Directive] = []

        mutating func append(_ directive: Directive) {
            directives.append(directive)
        }

        mutating func append(contentsOf additions: [Directive]) {
            directives.append(contentsOf: additions)
        }

        mutating func next(defaultingTo defaultDirective: Directive) -> Directive {
            guard !directives.isEmpty else { return defaultDirective }
            return directives.removeFirst()
        }
    }

    private struct PersistenceScript: Sendable {
        var revalidations = OperationScript<RevalidationDirective>()
        var installs = OperationScript<InstallDirective>()
        var nextAttemptInstalls = OperationScript<NextAttemptInstallDirective>()
        var interruptedMutations = OperationScript<InterruptedMutationDirective>()
        var pendingRecoveries = OperationScript<PendingRecoveryDirective>()
        var aborts = OperationScript<AbortDirective>()
        var publications = OperationScript<PublicationDirective>()
        var publicationRecoveries = OperationScript<PublicationRecoveryDirective>()
        var identityChecks = OperationScript<IdentityCheckDirective>()
    }

    private enum PublicationProofState: Equatable {
        case none
        case exact
        case impostor
    }

    private var aggregate: ChatAggregate
    private var script = PersistenceScript()
    private var publicationProof = PublicationProofState.none
    private(set) var identityCheckCount = 0
    private var reservedRequest: PendingCoachInvocationRequest?
    private(set) var activeInvocation: CoachInvocation?
    private(set) var publicationCount = 0
    private(set) var publicationRecoveryCount = 0
    private(set) var lastPublication: PublishCoachInvocationMutation?
    private(set) var recoveredRequests: [PendingCoachInvocationRequest] = []
    private(set) var installedAttemptOrdinals: [UInt8] = []
    private(set) var installedAttempts: [CoachProviderAttempt] = []
    private var shouldSuspendNextAttemptInstall = false
    private var nextAttemptInstallStarted = false
    private var nextAttemptInstallContinuation: CheckedContinuation<Void, Never>?

    init(initial: ChatAggregate) {
        aggregate = initial
    }

    func aggregateSnapshot() -> ChatAggregate { aggregate }

    func isAttemptDurable(
        attemptID: CoachProviderAttemptID,
        ordinal: UInt8,
        kind: CoachProviderAttemptKind,
        providerIdempotencyValue: ProviderIdempotencyValue
    ) -> Bool {
        guard let attempt = activeInvocation?.attempt else { return false }
        return attempt.id == attemptID &&
            attempt.ordinal == ordinal &&
            attempt.kind == kind &&
            attempt.transportAuthority?.providerIdempotencyValue ==
            providerIdempotencyValue
    }

    func openNewPendingInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> InvocationPendingSessionPreparationOutcome {
        switch await prepareNewPendingInvocation(request) {
        case let .prepared(authority):
            return .opened(
                ScriptedPendingInvocationSession(
                    persistence: self,
                    authority: authority
                )
            )
        case let .stale(current): return .stale(current)
        case let .frozen(frozen): return .frozen(frozen)
        case .readOnlyLibrary: return .readOnlyLibrary
        case .activeExists: return .blockedByActiveInvocation
        case .unavailable: return .unavailable
        }
    }

    func openPendingInvocation(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingSessionAcquisitionOutcome {
        switch await acquirePendingInvocation(request) {
        case let .acquired(authority):
            return .opened(
                ScriptedPendingInvocationSession(
                    persistence: self,
                    authority: authority
                )
            )
        case let .ineligible(current): return .ineligible(current)
        case .activeExists: return .blockedByActiveInvocation
        case .unavailable: return .unavailable
        }
    }

    func scriptNextRevalidation(_ directive: RevalidationDirective) {
        script.revalidations.append(directive)
    }

    func scriptNextInstall(_ directive: InstallDirective) {
        script.installs.append(directive)
    }

    func scriptNextAttemptInstall(_ directive: NextAttemptInstallDirective) {
        script.nextAttemptInstalls.append(directive)
    }

    func scriptNextInterruptedMutation(_ directive: InterruptedMutationDirective) {
        script.interruptedMutations.append(directive)
    }

    func scriptNextPendingRecovery(_ directive: PendingRecoveryDirective) {
        script.pendingRecoveries.append(directive)
    }

    func scriptNextAbort(_ directive: AbortDirective) {
        script.aborts.append(directive)
    }

    func scriptNextPublication(_ directive: PublicationDirective) {
        script.publications.append(directive)
    }

    func scriptNextPublicationRecovery(_ directive: PublicationRecoveryDirective) {
        script.publicationRecoveries.append(directive)
    }

    func scriptIdentityChecks(_ directives: [IdentityCheckDirective]) {
        script.identityChecks.append(contentsOf: directives)
    }

    func resetForNewSend(_ unlocked: ChatAggregate) {
        aggregate = unlocked
        reservedRequest = nil
        activeInvocation = nil
        installedAttemptOrdinals = []
        installedAttempts = []
    }

    func prepareNewPendingInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> InvocationPendingPreparationOutcome {
        guard activeInvocation == nil, reservedRequest == nil else {
            return .activeExists
        }
        guard aggregate.pendingUserTurn == nil,
              aggregate.chat.id == request.chatID,
              aggregate.chat.draft == request.observedAggregate.chat.draft
        else { return .stale(aggregate) }
        aggregate = try! ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            pendingUserTurn: request.pendingUserTurn
        )
        let pendingRequest = PendingCoachInvocationRequest(
            library: request.library,
            chatID: request.chatID,
            pendingUserTurnID: request.pendingUserTurn.id
        )
        let authority = try! InvocationPendingAuthority(
            request: pendingRequest,
            aggregate: aggregate
        )
        reservedRequest = pendingRequest
        return .prepared(authority)
    }

    func acquirePendingInvocation(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingAcquisitionOutcome {
        guard activeInvocation == nil, reservedRequest == nil else {
            return .activeExists
        }
        guard request.chatID == aggregate.chat.id,
              request.pendingUserTurnID == aggregate.pendingUserTurn?.id
        else { return .ineligible(aggregate) }
        let authority = try! InvocationPendingAuthority(
            request: request,
            aggregate: aggregate
        )
        reservedRequest = request
        return .acquired(authority)
    }

    func revalidatePendingInvocation(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingResolutionOutcome {
        guard reservedRequest == authority.request else { return .unavailable }
        switch script.revalidations.next(defaultingTo: .current) {
        case .current:
            break
        case .ineligible:
            reservedRequest = nil
            return .ineligible(aggregate)
        }
        guard authority.request.chatID == aggregate.chat.id,
              authority.request.pendingUserTurnID == aggregate.pendingUserTurn?.id
        else {
            reservedRequest = nil
            return .ineligible(aggregate)
        }
        return .eligible(
            try! InvocationPendingAuthority(
                request: authority.request,
                aggregate: aggregate
            )
        )
    }

    func installInvocation(
        _ mutation: InstallCoachInvocationMutation
    ) async -> InvocationInstallOutcome {
        guard reservedRequest == mutation.authority.request else { return .failed }
        switch script.installs.next(defaultingTo: .installed) {
        case .installed:
            break
        case .durableOnly:
            let durable = try! mutation.invocation.durableProjection()
            reservedRequest = nil
            aggregate = mutation.processingAggregate
            activeInvocation = durable
            installedAttemptOrdinals = [durable.attempt.ordinal]
            installedAttempts = [mutation.invocation.attempt]
            return .installed(durable)
        case .failed:
            return .failed
        case .activeExists:
            return .activeExists
        case .staleWithCurrent:
            return .stale(aggregate)
        case .staleWithoutSnapshot:
            return .stale(nil)
        }
        guard activeInvocation == nil else { return .activeExists }
        guard mutation.authority.aggregate == aggregate else { return .stale(aggregate) }
        reservedRequest = nil
        aggregate = mutation.processingAggregate
        activeInvocation = mutation.invocation
        installedAttemptOrdinals = [mutation.invocation.attempt.ordinal]
        installedAttempts = [mutation.invocation.attempt]
        return .installed(mutation.invocation)
    }

    func installNextAttempt(
        _ mutation: InstallNextCoachProviderAttemptMutation
    ) async -> InvocationNextAttemptInstallOutcome {
        guard activeInvocation == mutation.base else { return .stale(aggregate) }
        if shouldSuspendNextAttemptInstall {
            shouldSuspendNextAttemptInstall = false
            nextAttemptInstallStarted = true
            await withCheckedContinuation {
                nextAttemptInstallContinuation = $0
            }
        }
        switch script.nextAttemptInstalls.next(defaultingTo: .installed) {
        case .installed:
            break
        case .failed:
            return .failed
        case .staleWithCurrent:
            return .stale(aggregate)
        }
        activeInvocation = mutation.replacement
        installedAttemptOrdinals.append(mutation.replacement.attempt.ordinal)
        installedAttempts.append(mutation.replacement.attempt)
        return .installed(
            ScriptedActiveInvocationSession(
                persistence: self,
                invocation: mutation.replacement,
                processingAggregate: aggregate
            )
        )
    }

    func suspendNextAttemptInstall() {
        shouldSuspendNextAttemptInstall = true
    }

    func waitUntilNextAttemptInstallStarts() async {
        while !nextAttemptInstallStarted { await Task.yield() }
    }

    func resumeNextAttemptInstall() {
        nextAttemptInstallContinuation?.resume()
        nextAttemptInstallContinuation = nil
    }

    func cancelInvocationReservation(
        _ request: PendingCoachInvocationRequest
    ) async {
        if reservedRequest == request { reservedRequest = nil }
    }

    func checkLaunchIdentity(
        _ identity: InvocationLaunchIdentity,
        for authority: InvocationPendingAuthority
    ) async -> InvocationLaunchIdentityAvailabilityOutcome {
        identityCheckCount += 1
        guard reservedRequest == authority.request,
              aggregate == authority.aggregate
        else { return .stale(aggregate) }
        switch script.identityChecks.next(defaultingTo: .available) {
        case .available:
            return .available
        case let .collision(collision):
            return .collision(collision)
        }
    }

    func markContextCapacityFailure(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome {
        markPendingFailure(authority, failure: .coachContextCannotFit)
    }

    func markInterruptedNewSend(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome {
        let outcome = markPendingFailure(authority, failure: .coachResponseInterrupted)
        switch script.interruptedMutations.next(defaultingTo: .committed) {
        case .committed:
            return outcome
        case .committedButReportedFailed:
            return .failed
        }
    }

    func recoverPendingAfterTerminalFailure(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingResolutionOutcome {
        recoveredRequests.append(request)
        switch script.pendingRecoveries.next(defaultingTo: .current) {
        case .current:
            break
        case .unavailable:
            return .unavailable
        }
        guard request.chatID == aggregate.chat.id,
              request.pendingUserTurnID == aggregate.pendingUserTurn?.id
        else { return .ineligible(aggregate) }
        if let pending = aggregate.pendingUserTurn, pending.failure == nil {
            aggregate = try! ChatAggregate(
                chat: aggregate.chat,
                memory: aggregate.memory,
                pendingUserTurn: pending.replacingFailure(
                    .coachResponseInterrupted
                )
            )
        }
        return .eligible(
            try! InvocationPendingAuthority(request: request, aggregate: aggregate)
        )
    }

    private func markPendingFailure(
        _ authority: InvocationPendingAuthority,
        failure: PendingUserTurnFailure
    ) -> InvocationPendingMutationOutcome {
        if reservedRequest == authority.request { reservedRequest = nil }
        guard authority.aggregate == aggregate, let pending = aggregate.pendingUserTurn else {
            return .stale(aggregate)
        }
        aggregate = try! ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            pendingUserTurn: pending.replacingFailure(failure)
        )
        return .committed(aggregate)
    }

    func rejectNewSend(
        _ authority: InvocationPendingAuthority
    ) async -> InvocationPendingMutationOutcome {
        if reservedRequest == authority.request { reservedRequest = nil }
        guard aggregate.pendingUserTurn?.id == authority.request.pendingUserTurnID else {
            return .stale(aggregate)
        }
        aggregate = try! ChatAggregate(chat: aggregate.chat, memory: aggregate.memory)
        return .committed(aggregate)
    }

    func abortInstalledNewSend(
        _ invocation: CoachInvocation
    ) async -> InvocationPendingMutationOutcome {
        await abortInstalledNewSend(
            invocation,
            failure: .coachResponseInterrupted
        )
    }

    func abortInstalledNewSend(
        _ invocation: CoachInvocation,
        failure: PendingUserTurnFailure
    ) async -> InvocationPendingMutationOutcome {
        guard activeInvocation == invocation else { return .stale(aggregate) }
        switch script.aborts.next(defaultingTo: .committed) {
        case .committed:
            break
        case .failedWithoutCommit:
            activeInvocation = nil
            return .failed
        case .staleWithCurrent:
            activeInvocation = nil
            return .stale(aggregate)
        case .staleWithoutPending:
            activeInvocation = nil
            aggregate = try! ChatAggregate(
                chat: aggregate.chat,
                memory: aggregate.memory
            )
            return .stale(aggregate)
        }
        if lastPublication?.replacement == aggregate {
            activeInvocation = nil
            return .stale(aggregate)
        }
        activeInvocation = nil
        aggregate = try! ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            pendingUserTurn: aggregate.pendingUserTurn?.replacingFailure(
                failure
            )
        )
        return .committed(aggregate)
    }

    func publish(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationOutcome {
        publicationCount += 1
        guard activeInvocation == mutation.invocation else { return .stale(aggregate) }
        switch script.publications.next(defaultingTo: .committed) {
        case .shallowImpostorButReportedFailed:
            lastPublication = mutation
            aggregate = mutation.replacement
            publicationProof = .impostor
            return .failed
        case let .committedButReportedFailed(evolution):
            lastPublication = mutation
            aggregate = mutation.replacement
            publicationProof = .exact
            switch evolution {
            case .unchanged:
                break
            case .evolveChat:
                let renamed = try! RenameChatMutation(
                    library: LibraryScope(
                        libraryID: mutation.invocation.libraryID
                    ),
                    base: aggregate,
                    title: ChatTitle("Later title"),
                    updatedAt: UTCInstant("2026-08-30T12:00:01.000Z")
                ).replacement
                let edited = try! renamed.chat.draft.edited(
                    text: "A later fresh Draft edit.",
                    at: UTCInstant("2026-08-30T12:00:02.000Z")
                )
                aggregate = try! ChatAggregate(
                    chat: renamed.chat.replacingDraft(with: edited),
                    memory: renamed.memory
                )
            }
            return .failed
        case .failedWithoutCommit:
            return .failed
        case .staleWithCurrent:
            return .stale(aggregate)
        case .committed:
            break
        }
        guard mutation.base == aggregate else { return .stale(aggregate) }
        lastPublication = mutation
        aggregate = mutation.replacement
        activeInvocation = nil
        publicationProof = .exact
        return .committed(aggregate)
    }

    func recoverPublishedInvocation(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationRecoveryOutcome {
        publicationRecoveryCount += 1
        switch script.publicationRecoveries.next(defaultingTo: .current) {
        case .current:
            break
        case .unavailable:
            return .unavailable
        }
        guard publicationProof == .exact,
              lastPublication == mutation
        else { return .notPublished }
        activeInvocation = nil
        return .published(aggregate)
    }
}

private actor ScriptedPendingInvocationSession: InvocationPendingPersistenceSession {
    private enum State {
        case pending(InvocationPendingAuthority)
        case finished
    }

    nonisolated let authority: InvocationPendingAuthority
    private let persistence: MemoryInvocationPersistence
    private var state: State

    init(
        persistence: MemoryInvocationPersistence,
        authority: InvocationPendingAuthority
    ) {
        self.persistence = persistence
        self.authority = authority
        state = .pending(authority)
    }

    func revalidate() async -> InvocationPendingResolutionOutcome {
        guard case let .pending(current) = state else { return .unavailable }
        let outcome = await persistence.revalidatePendingInvocation(current)
        switch outcome {
        case let .eligible(updated): state = .pending(updated)
        case .ineligible: state = .finished
        case .unavailable: break
        }
        return outcome
    }

    func checkLaunchIdentity(
        _ identity: InvocationLaunchIdentity
    ) async -> InvocationLaunchIdentityAvailabilityOutcome {
        guard case let .pending(current) = state else { return .unavailable }
        let outcome = await persistence.checkLaunchIdentity(identity, for: current)
        if case let .stale(aggregate) = outcome,
           let aggregate,
           let updated = try? InvocationPendingAuthority(
               request: current.request,
               aggregate: aggregate
           )
        {
            state = .pending(updated)
        }
        return outcome
    }

    func install(
        _ mutation: InstallCoachInvocationMutation
    ) async -> InvocationSessionInstallOutcome {
        guard case let .pending(current) = state,
              current == mutation.authority
        else { return .failed }
        switch await persistence.installInvocation(mutation) {
        case let .installed(invocation):
            state = .finished
            return .installed(
                ScriptedActiveInvocationSession(
                    persistence: persistence,
                    invocation: invocation,
                    processingAggregate: mutation.processingAggregate
                )
            )
        case .activeExists:
            return .blockedByActiveInvocation
        case let .stale(aggregate):
            if let aggregate,
               let updated = try? InvocationPendingAuthority(
                   request: current.request,
                   aggregate: aggregate
               )
            {
                state = .pending(updated)
            }
            return .stale(aggregate)
        case .failed:
            return .failed
        }
    }

    func terminate(
        _ termination: InvocationPendingTermination
    ) async -> InvocationTerminalPersistenceOutcome {
        guard case let .pending(current) = state else {
            return .recovered(.unavailable)
        }
        state = .finished
        let outcome: InvocationPendingMutationOutcome
        switch termination {
        case .contextCapacityFailure:
            outcome = await persistence.markContextCapacityFailure(current)
        case .interrupted:
            outcome = await persistence.markInterruptedNewSend(current)
        case .rejected:
            outcome = await persistence.rejectNewSend(current)
        }
        switch outcome {
        case let .committed(aggregate): return .committed(aggregate)
        case let .stale(current): return .stale(current)
        case .failed:
            return .recovered(
                await persistence.recoverPendingAfterTerminalFailure(current.request)
            )
        }
    }

    func abandon() async {
        guard case let .pending(current) = state else { return }
        state = .finished
        await persistence.cancelInvocationReservation(current.request)
    }
}

private actor ScriptedActiveInvocationSession: InvocationActivePersistenceSession {
    nonisolated let invocation: CoachInvocation
    nonisolated let processingAggregate: ChatAggregate
    private let persistence: MemoryInvocationPersistence
    private var isActive = true

    init(
        persistence: MemoryInvocationPersistence,
        invocation: CoachInvocation,
        processingAggregate: ChatAggregate
    ) {
        self.persistence = persistence
        self.invocation = invocation
        self.processingAggregate = processingAggregate
    }

    func installNextAttempt(
        _ mutation: InstallNextCoachProviderAttemptMutation
    ) async -> InvocationNextAttemptInstallOutcome {
        guard isActive, mutation.base == invocation else { return .failed }
        let outcome = await persistence.installNextAttempt(mutation)
        if case .installed = outcome { isActive = false }
        return outcome
    }

    func abort(
        failure: PendingUserTurnFailure
    ) async -> InvocationTerminalPersistenceOutcome {
        guard isActive else { return .recovered(.unavailable) }
        isActive = false
        switch await persistence.abortInstalledNewSend(invocation, failure: failure) {
        case let .committed(aggregate): return .committed(aggregate)
        case let .stale(current): return .stale(current)
        case .failed:
            return .recovered(
                await persistence.recoverPendingAfterTerminalFailure(
                    PendingCoachInvocationRequest(
                        library: LibraryScope(libraryID: invocation.libraryID),
                        chatID: invocation.chatID,
                        pendingUserTurnID: invocation.pendingUserTurnID
                    )
                )
            )
        }
    }

    func publish(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationOutcome {
        guard isActive, mutation.invocation == invocation else { return .failed }
        let outcome = await persistence.publish(mutation)
        if case .committed = outcome { isActive = false }
        return outcome
    }

    func recoverPublished(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationRecoveryOutcome {
        guard isActive, mutation.invocation == invocation else { return .unavailable }
        let outcome = await persistence.recoverPublishedInvocation(mutation)
        if case .published = outcome { isActive = false }
        return outcome
    }
}

private actor ScriptedInvocationAdmission: InvocationAdmissionPort {
    private let decision: InvocationAdmissionClaimOutcome
    private(set) var claimCount = 0
    private(set) var availabilityCount = 0
    private(set) var claimedAt: [UTCInstant] = []
    private var projectedAvailability: InvocationAdmissionAvailability = .available

    init(decision: InvocationAdmissionClaimOutcome) {
        self.decision = decision
    }

    func setAvailability(_ availability: InvocationAdmissionAvailability) {
        projectedAvailability = availability
    }

    func availability(
        library: LibraryScope,
        at instant: UTCInstant
    ) async -> InvocationAdmissionAvailability {
        availabilityCount += 1
        return projectedAvailability
    }

    func claim(
        library: LibraryScope,
        at instant: UTCInstant
    ) async -> InvocationAdmissionClaimOutcome {
        claimCount += 1
        claimedAt.append(instant)
        return decision
    }
}

private actor RecordingSyntheticCoachProvider: SyntheticCoachProviderPort {
    private(set) var serializedRequests: [[UInt8]] = []
    private(set) var requests: [SyntheticCoachProviderRequest] = []
    private(set) var launchCount = 0
    private(set) var durableBeforeLaunch: [Bool] = []
    private(set) var cancelledAttemptIDs: [CoachProviderAttemptID] = []
    private(set) var cancellationGraceMilliseconds: [Int64] = []
    private(set) var transcriptReadResults: [AttemptTranscriptAccessResult] = []
    private var outcomes: [CoachProviderAttemptOutcome]
    private let persistence: MemoryInvocationPersistence
    private let transcriptReadPlan: ProviderTranscriptReadPlan
    private var shouldSuspend = false
    private var suspendedAttemptOrdinals: Set<UInt8> = []
    private var launchStarted = false
    private var launchContinuation: CheckedContinuation<Void, Never>?
    private var shouldSuspendCancellation = false
    private var cancellationStarted = false
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private var cancellationOutcomes: [CoachProviderAttemptCancellationOutcome]
    private let transcriptReadAuthorization = TranscriptReadAuthorizationBarrier()
    private var pendingTranscriptReadTasks: [Task<AttemptTranscriptAccessResult, Never>] = []

    init(
        outcomes: [CoachProviderAttemptOutcome],
        persistence: MemoryInvocationPersistence,
        transcriptReadPlan: ProviderTranscriptReadPlan,
        cancellationOutcomes: [CoachProviderAttemptCancellationOutcome] = [.reaped]
    ) {
        self.outcomes = outcomes
        self.persistence = persistence
        self.transcriptReadPlan = transcriptReadPlan
        self.cancellationOutcomes = cancellationOutcomes
    }

    func failNextLaunch() { outcomes.insert(.userRetryableFailure, at: 0) }

    func returnInvalidResponseNextLaunch() {
        outcomes.insert(.complete(markdown: ""), at: 0)
    }

    func suspendNextLaunch() { shouldSuspend = true }

    func suspendLaunch(ordinal: UInt8) {
        suspendedAttemptOrdinals.insert(ordinal)
    }

    func suspendNextCancellation() { shouldSuspendCancellation = true }

    func waitUntilLaunchStarts() async {
        while !launchStarted { await Task.yield() }
    }

    func waitUntilLaunchCount(_ count: Int) async {
        while launchCount < count { await Task.yield() }
    }

    func resumeLaunch() {
        launchContinuation?.resume()
        launchContinuation = nil
    }

    func waitUntilCancellationStarts() async {
        while !cancellationStarted { await Task.yield() }
    }

    func waitUntilTranscriptReadCount(_ count: Int) async {
        while transcriptReadResults.count < count { await Task.yield() }
    }

    func releaseTranscriptReadAuthorization() async {
        await transcriptReadAuthorization.release()
    }

    func drainPendingTranscriptReadResults() async -> [AttemptTranscriptAccessResult] {
        let tasks = pendingTranscriptReadTasks
        pendingTranscriptReadTasks.removeAll(keepingCapacity: false)
        var results: [AttemptTranscriptAccessResult] = []
        for task in tasks {
            results.append(await task.value)
        }
        transcriptReadResults.append(contentsOf: results)
        return results
    }

    func resumeCancellation() {
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }

    func recordedAttemptKinds() -> [CoachProviderAttemptKind] {
        requests.map(\.attemptKind)
    }

    func recordedAttemptOrdinals() -> [UInt8] {
        requests.map(\.attemptOrdinal)
    }

    func run(_ request: SyntheticCoachProviderRequest) async -> CoachProviderAttemptOutcome {
        durableBeforeLaunch.append(
            await persistence.isAttemptDurable(
                attemptID: request.attemptID,
                ordinal: request.attemptOrdinal,
                kind: request.attemptKind,
                providerIdempotencyValue: request.providerIdempotencyValue
            )
        )
        launchCount += 1
        requests.append(request)
        serializedRequests.append(Array(request.exchange.request))
        launchStarted = true
        if let transcriptAccess = request.transcriptAccess {
            if transcriptReadPlan == .completeWhileReadChecksAvailability {
                pendingTranscriptReadTasks.append(
                    Task {
                        await transcriptAccess.read(
                            transportRequestID:
                                AttemptTranscriptTransportRequestID("read-1")!,
                            handles: transcriptAccess.handles
                        )
                    }
                )
                while await transcriptAccess.brokerStatusForTesting() != .checking {
                    await Task.yield()
                }
            }
            if transcriptReadPlan == .completeBeforeReadAuthorization {
                let authorization = transcriptReadAuthorization
                pendingTranscriptReadTasks.append(
                    Task {
                        await transcriptAccess.readForTesting(
                            transportRequestID:
                                AttemptTranscriptTransportRequestID("read-1")!,
                            handles: transcriptAccess.handles,
                            beforeFinalAuthorization: {
                                await authorization.arriveAndWait()
                            }
                        )
                    }
                )
                await authorization.waitUntilArrived()
            }
            if transcriptReadPlan == .terminalBeforeCoordinatorReport {
                transcriptReadResults.append(
                    await transcriptAccess.stageReadBeforeTerminalReportForTesting(
                        transportRequestID:
                            AttemptTranscriptTransportRequestID("read-1")!,
                        handles: transcriptAccess.handles
                    )
                )
            }
            let requestedBatches: [[PreparedCoachTranscriptHandle]] =
                switch transcriptReadPlan {
                case .none:
                    []
                case .all:
                    [transcriptAccess.handles]
                case .duplicateFirst:
                    transcriptAccess.handles.first.map { [[$0, $0]] } ?? []
                case .threeExactReads:
                    Array(repeating: transcriptAccess.handles, count: 3)
                case .secondSemanticExactRead:
                    Array(repeating: transcriptAccess.handles, count: 2)
                case .terminalBeforeCoordinatorReport:
                    []
                case .completeWhileReadChecksAvailability,
                     .completeBeforeReadAuthorization:
                    []
                }
            for (index, requestedHandles) in requestedBatches.enumerated() {
                let requestOrdinal = transcriptReadPlan == .secondSemanticExactRead
                    ? index + 1
                    : 1
                transcriptReadResults.append(
                    await transcriptAccess.read(
                        transportRequestID: AttemptTranscriptTransportRequestID(
                            "read-\(requestOrdinal)"
                        )!,
                        handles: requestedHandles
                    )
                )
            }
        }
        if shouldSuspend || suspendedAttemptOrdinals.remove(request.attemptOrdinal) != nil {
            shouldSuspend = false
            await withCheckedContinuation { launchContinuation = $0 }
        }
        guard !outcomes.isEmpty else {
            return .complete(markdown: "A concise **synthetic** answer.")
        }
        return outcomes.removeFirst()
    }

    func cancelAndReap(
        attemptID: CoachProviderAttemptID,
        graceMilliseconds: Int64
    ) async -> CoachProviderAttemptCancellationOutcome {
        cancelledAttemptIDs.append(attemptID)
        cancellationGraceMilliseconds.append(graceMilliseconds)
        launchContinuation?.resume()
        launchContinuation = nil
        cancellationStarted = true
        if shouldSuspendCancellation {
            shouldSuspendCancellation = false
            await withCheckedContinuation { cancellationContinuation = $0 }
        }
        return cancellationOutcomes.isEmpty
            ? .reaped
            : cancellationOutcomes.removeFirst()
    }
}

private enum ProviderTranscriptReadPlan: Equatable, Sendable {
    case none
    case all
    case duplicateFirst
    case threeExactReads
    case secondSemanticExactRead
    case terminalBeforeCoordinatorReport
    case completeWhileReadChecksAvailability
    case completeBeforeReadAuthorization
}

private actor TranscriptReadAuthorizationBarrier {
    private var arrived = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrived = true
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilArrived() async {
        while !arrived { await Task.yield() }
    }

    func release() {
        released = true
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }
}

private actor InvocationStopAuthorityRecorder {
    private var authorities: [InvocationStopAuthority] = []

    func record(_ authority: InvocationStopAuthority) {
        authorities.append(authority)
    }

    func waitForAuthority() async -> InvocationStopAuthority {
        while authorities.isEmpty { await Task.yield() }
        return authorities.removeFirst()
    }

    func waitForDistinctAttempts(_ count: Int) async -> [InvocationStopAuthority] {
        while Set(authorities.map(\.attemptID)).count < count { await Task.yield() }
        var seen: Set<CoachProviderAttemptID> = []
        return authorities.filter { seen.insert($0.attemptID).inserted }
    }
}

private func maskingTranscriptDescriptorHandles(
    in request: SyntheticCoachProviderRequest
) throws -> Data {
    guard var object = try JSONSerialization.jsonObject(
        with: request.exchange.request
    ) as? [String: Any],
        var attachments = object["sessionAttachments"] as? [[String: Any]]
    else {
        throw TranscriptRequestNormalizationError.invalidRequest
    }
    var replacedCount = 0
    for index in attachments.indices
    where attachments[index]["kind"] as? String == "onDemand" {
        guard attachments[index]["sessionTranscriptHandle"] is String else {
            throw TranscriptRequestNormalizationError.invalidRequest
        }
        attachments[index]["sessionTranscriptHandle"] =
            "<attempt-transcript-handle>"
        replacedCount += 1
    }
    guard replacedCount == request.exchange.transcriptHandles.count else {
        throw TranscriptRequestNormalizationError.invalidRequest
    }
    object["sessionAttachments"] = attachments
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private enum TranscriptRequestNormalizationError: Error {
    case invalidRequest
}

private actor RecordingInvocationRetrySleeper: InvocationRetrySleeping {
    private enum Failure: Error { case scripted }

    private(set) var delaysMilliseconds: [Int64] = []
    private var failsNextSleep = false
    private var shouldSuspend = false
    private var sleepStarted = false
    private var sleepContinuation: CheckedContinuation<Void, any Error>?

    func failNextSleep() { failsNextSleep = true }

    func suspendNextSleep() { shouldSuspend = true }

    func waitUntilSleepStarts() async {
        while !sleepStarted { await Task.yield() }
    }

    func sleep(milliseconds: Int64) async throws {
        delaysMilliseconds.append(milliseconds)
        if failsNextSleep {
            failsNextSleep = false
            throw Failure.scripted
        }
        guard shouldSuspend else { return }
        shouldSuspend = false
        sleepStarted = true
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepContinuation = continuation
            }
        } onCancel: {
            Task { await self.cancelSuspendedSleep() }
        }
    }

    private func cancelSuspendedSleep() {
        sleepContinuation?.resume(throwing: CancellationError())
        sleepContinuation = nil
    }

    func recordedDelays() -> [Int64] { delaysMilliseconds }
}

private actor NonCooperativeInvocationRetrySleeper: InvocationRetrySleeping {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var started = false
    private var finished = false

    var isSuspended: Bool { continuation != nil }

    func sleep(milliseconds: Int64) async throws {
        started = true
        try await withCheckedThrowingContinuation { continuation = $0 }
        finished = true
    }

    func waitUntilSleepStarts() async {
        while !started || continuation == nil { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    func waitUntilSleepFinishes() async {
        while !finished { await Task.yield() }
    }
}

private final class RecordingInvocationRetryDiagnostics:
    @unchecked Sendable,
    InvocationRetryDiagnostics
{
    private let lock = NSLock()
    private var events: [InvocationRetryDiagnosticEvent] = []

    func enqueue(_ event: InvocationRetryDiagnosticEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    func recordedEvents() -> [InvocationRetryDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class ScriptedInvocationRetryTiming:
    @unchecked Sendable,
    InvocationRetryTiming
{
    private let lock = NSLock()
    private let milliseconds: [UInt64]
    private var nextIndex = 0

    init(milliseconds: [UInt64]) {
        precondition(!milliseconds.isEmpty)
        self.milliseconds = milliseconds
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextIndex
    }

    func nowMilliseconds() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let index = min(nextIndex, milliseconds.count - 1)
        nextIndex += 1
        return milliseconds[index]
    }
}

private actor InvocationContextSource:
    ProfileReconsiderationUnavailableCoachContextSnapshotPort
{
    private let contextWindow: Int
    private let responseReservedTokens: Int
    private let current: Bool
    private let includesOnDemandAttachment: Bool
    private let tokenEstimator: CoachTokenEstimator
    private let activeProfileStatementIDs: [String]
    private(set) var pendingResolutionCount = 0
    private var currentCheckCount = 0
    nonisolated let profile = CoachProfileProvenance(
        revisionID: try! ProfileRevisionID("prf-20260830T115900000Z-4GHJ"),
        statementGeneration: 9
    )

    init(
        contextWindow: Int,
        responseReservedTokens: Int = 512,
        isCurrent: Bool,
        includesOnDemandAttachment: Bool = false,
        tokenEstimator: CoachTokenEstimator = .utf8ByteUpperBound(),
        activeProfileStatementIDs: [String] = []
    ) {
        self.contextWindow = contextWindow
        self.responseReservedTokens = responseReservedTokens
        current = isCurrent
        self.includesOnDemandAttachment = includesOnDemandAttachment
        self.tokenEstimator = tokenEstimator
        self.activeProfileStatementIDs = activeProfileStatementIDs
    }

    func resolveNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome { .sourceUnavailable }

    func resolveChat(
        _ request: CoachContextChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome { .sourceUnavailable }

    func resolvePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextSnapshotOutcome {
        pendingResolutionCount += 1
        do {
            return .resolved(
                try CoachContextResolvedSnapshot(
                    input: CoachContextQuoteInput(
                        profile: .object([
                            "statements": .array(
                                activeProfileStatementIDs.map { statementID in
                                    .object([
                                        "statementId": .string(statementID),
                                        "statementKind": .string("goal"),
                                        "wording": .string("Speak with clarity."),
                                        "supportingSessionCount": .integer(0),
                                    ])
                                }
                            ),
                        ]),
                        memory: .object([
                            "generalNotes": .string(""),
                            "sessionSummaries": .array([]),
                        ]),
                        history: [],
                        currentDraft: request.draft.text,
                        attachments: includesOnDemandAttachment ? [
                            .onDemand(
                                requestValue: .object([
                                    "kind": .string("onDemand"),
                                    "sessionAttachmentId": .string("attachment-1"),
                                    "displayLabel": .string("Fixture Session"),
                                    "sessionTranscriptHandle": .string(
                                        "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
                                    ),
                                ]),
                                sessionTranscriptHandle: PreparedCoachTranscriptHandle(
                                    "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
                                ),
                                transcriptDisclosure: .object([
                                    "sessionAttachmentId": .string("attachment-1"),
                                    "transcript": .object([
                                        "lines": .array([
                                            .object([
                                                "text": .string("Pause."),
                                                "timeRange": .object([
                                                    "startMs": .integer(0),
                                                    "endMs": .integer(1_000),
                                                ]),
                                                "words": .array([
                                                    .object([
                                                        "wordId": .string("w000000"),
                                                        "text": .string("Pause"),
                                                        "timeRange": .object([
                                                            "startMs": .integer(0),
                                                            "endMs": .integer(900),
                                                        ]),
                                                    ]),
                                                ]),
                                            ]),
                                        ]),
                                        "audioEvents": .array([
                                            .object([
                                                "audioEventId": .string("a000000"),
                                                "category": .string("silentPause"),
                                                "timeRange": .object([
                                                    "startMs": .integer(1_000),
                                                    "endMs": .integer(1_500),
                                                ]),
                                            ]),
                                        ]),
                                    ]),
                                ]),
                                sourceAttachment: ChatSessionAttachment(
                                    attachmentID: try ChatSessionAttachmentID(
                                        "attachment-1"
                                    ),
                                    sessionID: try SessionID(
                                        "ses-20260830T115900000Z-1ABC"
                                    ),
                                    transcriptRevisionID: try TranscriptRevisionID(
                                        "trv-20260830T115900000Z-2DEF"
                                    )
                                ),
                                revisionSHA256: String(repeating: "1", count: 64)
                            ),
                        ] : []
                    ),
                    configuration: try CoachContextConfiguration(
                        descriptor: CoachProviderDescriptor(
                            displayName: "Synthetic fixture",
                            contextBudget: CoachContextBudget(
                                contextWindowTokens: contextWindow,
                                responseReservedTokens: min(
                                    responseReservedTokens,
                                    max(1, contextWindow - 2)
                                ),
                                safetyMarginTokens: 1
                            ),
                            coachMemoryMaxTokens: 512
                        ),
                        policy: CoachProviderEstimationPolicy(
                            providerIdentifier: "synthetic-fixture-v1",
                            responseCollectorByteCeiling: 8_192,
                            framing: CoachProviderFraming(),
                            attachmentProjectionPolicy:
                                try CoachAttachmentProjectionPolicy(
                                    maximumInlineTranscriptTokens: 8_192,
                                    tokenEstimator: tokenEstimator
                                )
                        )
                    ),
                    authority: CoachContextSnapshotAuthority(
                        binding: .pending(
                            library: request.library,
                            chatID: request.chatID,
                            draftID: request.draft.draftID,
                            draftVersion: request.draft.version,
                            pendingUserTurnID: request.pendingUserTurn.id,
                            responsePositionID: request.pendingUserTurn.responsePositionID
                        ),
                        contextGeneration: 1,
                        configurationGeneration: 1,
                        profile: profile
                    )
                )
            )
        } catch {
            return .sourceUnavailable
        }
    }

    func isCurrent(_ authority: CoachContextSnapshotAuthority) async -> Bool {
        currentCheckCount += 1
        return currentCheckCount == 1 || current
    }

    func acquireAuthorityLease(
        _ authority: CoachContextSourceLeaseAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        await acquireImmutableAuthorityLease(authority)
    }
}

private struct FixedInvocationClock: ChatClock {
    let instant: UTCInstant
    func now() async -> UTCInstant { instant }
}

private actor SequencedInvocationClock: ChatClock {
    private var instants: [UTCInstant]

    init(instants: [UTCInstant]) { self.instants = instants }

    func now() async -> UTCInstant {
        precondition(!instants.isEmpty)
        return instants.removeFirst()
    }
}

private actor SequencedTranscriptAvailability {
    private var results: [AttemptTranscriptAvailability]
    private(set) var queries: [AttemptTranscriptAvailabilityQuery] = []

    init(results: [AttemptTranscriptAvailability]) {
        self.results = results
    }

    func inspect(
        _ query: AttemptTranscriptAvailabilityQuery
    ) -> AttemptTranscriptAvailability {
        queries.append(query)
        return results.isEmpty ? .available : results.removeFirst()
    }
}

private actor RetryInvocationIdentities: InvocationIdentityGenerating {
    private var invocationIndex = 0
    private var attemptIndex = 0

    func generateInvocationID(at instant: UTCInstant) async -> CoachInvocationID {
        invocationIndex += 1
        return try! CoachInvocationID(
            String(
                format: "inv-20260830T12000%d000Z-%04d",
                invocationIndex,
                5_000 + invocationIndex
            )
        )
    }

    func generateAttemptIdentity(
        at instant: UTCInstant,
        ordinal: UInt8,
        kind: CoachProviderAttemptKind,
        transcriptHandleCount: Int
    ) async -> InvocationAttemptIdentity {
        attemptIndex += 1
        let suffix = 6_000 + attemptIndex
        return InvocationAttemptIdentity(
            attemptID: try! CoachProviderAttemptID(
                String(
                    format: "atm-20260830T12000%d000Z-%04d",
                    attemptIndex,
                    suffix
                )
            ),
            idempotencyValue: try! ProviderIdempotencyValue(
                "retry-invocation-\(attemptIndex)"
            ),
            userMessageID: try! ChatMessageID(
                String(
                    format: "msg-20260830T12000%d000Z-%04d",
                    attemptIndex,
                    7_000 + attemptIndex
                )
            ),
            coachMessageID: try! ChatMessageID(
                String(
                    format: "msg-20260830T12000%d000Z-%04d",
                    attemptIndex,
                    8_000 + attemptIndex
                )
            ),
            freshDraftID: try! ChatDraftID(
                String(
                    format: "drf-20260830T12000%d000Z-%04d",
                    attemptIndex,
                    9_000 + attemptIndex
                )
            ),
            transcriptHandles: (0 ..< transcriptHandleCount).map { index in
                try! PreparedCoachTranscriptHandle(
                    String(
                        format: "00000000-0000-0000-%04x-%012x",
                        attemptIndex,
                        index + 1
                    )
                )
            }
        )
    }
}

private struct FixedInvocationIdentities: InvocationIdentityGenerating {
    let invocationID: CoachInvocationID
    let attemptID: CoachProviderAttemptID
    let idempotencyValue: ProviderIdempotencyValue
    let userMessageID: ChatMessageID
    let coachMessageID: ChatMessageID
    let freshDraftID: ChatDraftID

    func generateInvocationID(at instant: UTCInstant) async -> CoachInvocationID {
        invocationID
    }

    func generateAttemptIdentity(
        at instant: UTCInstant,
        ordinal: UInt8,
        kind: CoachProviderAttemptKind,
        transcriptHandleCount: Int
    ) async -> InvocationAttemptIdentity {
        let attemptSuffixes = ["6NPQ", "7RST", "8VWX", "9YZ0"]
        let userSuffixes = ["7RST", "A234", "D567", "G89A"]
        let coachSuffixes = ["8VWX", "B345", "E678", "H9AB"]
        let draftSuffixes = ["9YZ0", "C456", "F789", "JABC"]
        let index = Int(ordinal - 1)
        let selectedAttemptID = ordinal == 1 ? attemptID : try! CoachProviderAttemptID(
            "atm-20260830T120000000Z-\(attemptSuffixes[index])"
        )
        let selectedUserID = ordinal == 1 ? userMessageID : try! ChatMessageID(
            "msg-20260830T120000000Z-\(userSuffixes[index])"
        )
        let selectedCoachID = ordinal == 1 ? coachMessageID : try! ChatMessageID(
            "msg-20260830T120000000Z-\(coachSuffixes[index])"
        )
        let selectedDraftID = ordinal == 1 ? freshDraftID : try! ChatDraftID(
            "drf-20260830T120000000Z-\(draftSuffixes[index])"
        )
        return InvocationAttemptIdentity(
            attemptID: selectedAttemptID,
            idempotencyValue: ordinal == 1 ? idempotencyValue :
                try! ProviderIdempotencyValue("synthetic-attempt-\(ordinal)"),
            userMessageID: selectedUserID,
            coachMessageID: selectedCoachID,
            freshDraftID: selectedDraftID,
            transcriptHandles: (0 ..< transcriptHandleCount).map { handleIndex in
                try! PreparedCoachTranscriptHandle(
                    String(
                        format: "00000000-0000-0000-%04x-%012x",
                        Int(ordinal),
                        handleIndex + 1
                    )
                )
            }
        )
    }
}

private struct MalformedInitialAttemptIdentities: InvocationIdentityGenerating {
    enum Mode: CaseIterable {
        case wrongCount
        case duplicate
    }

    let mode: Mode

    func generateInvocationID(at instant: UTCInstant) async -> CoachInvocationID {
        try! CoachInvocationID("inv-20260830T120000000Z-5KMN")
    }

    func generateAttemptIdentity(
        at instant: UTCInstant,
        ordinal: UInt8,
        kind: CoachProviderAttemptKind,
        transcriptHandleCount: Int
    ) async -> InvocationAttemptIdentity {
        let duplicate = try! PreparedCoachTranscriptHandle(
            "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        )
        let handles: [PreparedCoachTranscriptHandle]
        switch mode {
        case .wrongCount: handles = []
        case .duplicate: handles = [duplicate, duplicate]
        }
        return InvocationAttemptIdentity(
            attemptID: try! CoachProviderAttemptID(
                "atm-20260830T120000000Z-6NPQ"
            ),
            idempotencyValue: try! ProviderIdempotencyValue(
                "synthetic-attempt-6NPQ"
            ),
            userMessageID: try! ChatMessageID(
                "msg-20260830T120000000Z-7RST"
            ),
            coachMessageID: try! ChatMessageID(
                "msg-20260830T120000000Z-8VWX"
            ),
            freshDraftID: try! ChatDraftID(
                "drf-20260830T120000000Z-9YZ0"
            ),
            transcriptHandles: handles
        )
    }
}

private struct MalformedNextAttemptIdentities: InvocationIdentityGenerating {
    private let valid = FixedInvocationIdentities(
        invocationID: try! CoachInvocationID("inv-20260830T120000000Z-5KMN"),
        attemptID: try! CoachProviderAttemptID("atm-20260830T120000000Z-6NPQ"),
        idempotencyValue: try! ProviderIdempotencyValue("synthetic-attempt-6NPQ"),
        userMessageID: try! ChatMessageID("msg-20260830T120000000Z-7RST"),
        coachMessageID: try! ChatMessageID("msg-20260830T120000000Z-8VWX"),
        freshDraftID: try! ChatDraftID("drf-20260830T120000000Z-9YZ0")
    )

    func generateInvocationID(at instant: UTCInstant) async -> CoachInvocationID {
        await valid.generateInvocationID(at: instant)
    }

    func generateAttemptIdentity(
        at instant: UTCInstant,
        ordinal: UInt8,
        kind: CoachProviderAttemptKind,
        transcriptHandleCount: Int
    ) async -> InvocationAttemptIdentity {
        let identity = await valid.generateAttemptIdentity(
            at: instant,
            ordinal: ordinal,
            kind: kind,
            transcriptHandleCount: transcriptHandleCount
        )
        guard ordinal > 1 else { return identity }
        let duplicate = try! PreparedCoachTranscriptHandle(
            "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        )
        return InvocationAttemptIdentity(
            attemptID: identity.attemptID,
            idempotencyValue: identity.idempotencyValue,
            userMessageID: identity.userMessageID,
            coachMessageID: identity.coachMessageID,
            freshDraftID: identity.freshDraftID,
            transcriptHandles: [duplicate, duplicate]
        )
    }
}

private actor SameInvocationCollisionIdentities: InvocationIdentityGenerating {
    enum Collision: CaseIterable, CustomStringConvertible, Equatable {
        case attemptID
        case providerIdempotencyValue
        case userMessageID
        case coachMessageID
        case freshDraftID
        case transcriptHandle

        var description: String {
            switch self {
            case .attemptID: "Attempt ID"
            case .providerIdempotencyValue: "provider idempotency value"
            case .userMessageID: "user Message ID"
            case .coachMessageID: "Coach Message ID"
            case .freshDraftID: "fresh Draft ID"
            case .transcriptHandle: "transcript handle"
            }
        }
    }

    private let collision: Collision
    private let collidingCandidateCount: Int
    private(set) var generatedAttemptIdentityCount = 0
    private var generatedNextAttemptCandidateCount = 0

    init(collision: Collision, collidingCandidateCount: Int) {
        self.collision = collision
        self.collidingCandidateCount = collidingCandidateCount
    }

    func generateInvocationID(at instant: UTCInstant) async -> CoachInvocationID {
        try! CoachInvocationID("inv-20260830T120000000Z-5KMN")
    }

    func generateAttemptIdentity(
        at instant: UTCInstant,
        ordinal: UInt8,
        kind: CoachProviderAttemptKind,
        transcriptHandleCount: Int
    ) async -> InvocationAttemptIdentity {
        generatedAttemptIdentityCount += 1
        if ordinal == 1 {
            return identity(
                attemptSuffix: "6NPQ",
                idempotencyValue: "synthetic-attempt-1",
                userSuffix: "7RST",
                coachSuffix: "8VWX",
                draftSuffix: "9YZ0",
                transcriptHandleOrdinal: 1,
                transcriptHandleCount: transcriptHandleCount
            )
        }

        generatedNextAttemptCandidateCount += 1
        let shouldCollide = generatedNextAttemptCandidateCount <= collidingCandidateCount
        var candidate = identity(
            attemptSuffix: "A234",
            idempotencyValue: "synthetic-attempt-2",
            userSuffix: "B345",
            coachSuffix: "C456",
            draftSuffix: "D567",
            transcriptHandleOrdinal: 2,
            transcriptHandleCount: transcriptHandleCount
        )
        guard shouldCollide else { return candidate }

        let first = identity(
            attemptSuffix: "6NPQ",
            idempotencyValue: "synthetic-attempt-1",
            userSuffix: "7RST",
            coachSuffix: "8VWX",
            draftSuffix: "9YZ0",
            transcriptHandleOrdinal: 1,
            transcriptHandleCount: transcriptHandleCount
        )
        candidate = InvocationAttemptIdentity(
            attemptID: collision == .attemptID ? first.attemptID : candidate.attemptID,
            idempotencyValue: collision == .providerIdempotencyValue
                ? first.idempotencyValue
                : candidate.idempotencyValue,
            userMessageID: collision == .userMessageID
                ? first.userMessageID
                : candidate.userMessageID,
            coachMessageID: collision == .coachMessageID
                ? first.coachMessageID
                : candidate.coachMessageID,
            freshDraftID: collision == .freshDraftID
                ? first.freshDraftID
                : candidate.freshDraftID,
            transcriptHandles: collision == .transcriptHandle
                ? first.transcriptHandles
                : candidate.transcriptHandles
        )
        return candidate
    }

    private func identity(
        attemptSuffix: String,
        idempotencyValue: String,
        userSuffix: String,
        coachSuffix: String,
        draftSuffix: String,
        transcriptHandleOrdinal: Int,
        transcriptHandleCount: Int
    ) -> InvocationAttemptIdentity {
        InvocationAttemptIdentity(
            attemptID: try! CoachProviderAttemptID(
                "atm-20260830T120000000Z-\(attemptSuffix)"
            ),
            idempotencyValue: try! ProviderIdempotencyValue(idempotencyValue),
            userMessageID: try! ChatMessageID(
                "msg-20260830T120000000Z-\(userSuffix)"
            ),
            coachMessageID: try! ChatMessageID(
                "msg-20260830T120000000Z-\(coachSuffix)"
            ),
            freshDraftID: try! ChatDraftID(
                "drf-20260830T120000000Z-\(draftSuffix)"
            ),
            transcriptHandles: (0 ..< transcriptHandleCount).map { handleIndex in
                try! PreparedCoachTranscriptHandle(
                    String(
                        format: "00000000-0000-0000-%04x-%012x",
                        transcriptHandleOrdinal,
                        handleIndex + 1
                    )
                )
            }
        )
    }
}
