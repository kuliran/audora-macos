@testable @_spi(CoachContextQualification) @_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
import Foundation
import XCTest

final class ProfileReconsiderationInvocationsTests: XCTestCase {
    func testNewReconsiderPublishesCoachOnlyMemoryAndOneReviewedReplacement()
        async throws
    {
        let response = """
        {
          "messageBlocks":[{
            "kind":"markdown",
            "markdown":"I updated the suggestion for the current Profile."
          }],
          "newMemory":{
            "generalNotes":"Use deliberate transitions.",
            "sessionSummaries":[]
          },
          "proposeProfileEdits":[{
            "edit":{
              "kind":"add",
              "statementKind":"goal",
              "wording":"Use deliberate transitions."
            }
          }]
        }
        """
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: true,
            providerOutcomes: [.complete(fixtureResponse(response))]
        )
        let prepared = try await fixture.prepareNew()

        let outcome = await fixture.invocations.tryReconsiderProfileChange(
            prepared
        )
        guard case let .published(published, _) = outcome else {
            return XCTFail("expected atomic reviewed replacement, got \(outcome)")
        }

        XCTAssertEqual(published.chat.draft, fixture.observed.chat.draft)
        XCTAssertEqual(published.chat.messageIDs, [fixture.coachMessageIDs[0]])
        XCTAssertEqual(published.messages.count, 1)
        XCTAssertEqual(
            published.memory.generalNotes,
            "Use deliberate transitions."
        )
        let replacement = try XCTUnwrap(published.profileProposal)
        XCTAssertEqual(replacement.baseProfile, fixture.basis.latestProfile.provenance)
        XCTAssertEqual(
            replacement.responsePositionID,
            fixture.reconsideration.resultResponsePositionID
        )
        XCTAssertEqual(
            replacement.evidenceAppends,
            fixture.basis.retainedActiveEvidenceAppends
        )
        XCTAssertNil(published.profileReconsideration)
        XCTAssertNil(published.pendingUserTurn)
        let installedIntent = await fixture.persistence.installedInvocation?.intent
        XCTAssertEqual(
            installedIntent,
            .reconsiderProfileChange(
                sourceEffectIdentity: fixture.reconsideration.sourceEffectIdentity,
                resultResponsePositionID:
                    fixture.reconsideration.resultResponsePositionID
            )
        )
        let durableBeforeLaunch = await fixture.provider.durableBeforeLaunch
        let admissionClaimCount = await fixture.admission.claimCount
        let contextResolutionCount = await fixture.contextSource
            .reconsiderResolutionCount
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(durableBeforeLaunch, [true])
        XCTAssertEqual(admissionClaimCount, 1)
        XCTAssertEqual(contextResolutionCount, 1)
        XCTAssertEqual(publicationCount, 1)
    }

    func testTrueZeroEffectReconsiderWithdrawsWithoutInventingMessageOrDraft()
        async throws
    {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            providerOutcomes: [.complete(fixtureResponse("{}"))]
        )
        let prepared = try await fixture.prepareNew()

        let outcome = await fixture.invocations.tryReconsiderProfileChange(
            prepared
        )
        guard case let .withdrawn(published, _) = outcome else {
            return XCTFail("expected explicit withdrawal, got \(outcome)")
        }

        XCTAssertEqual(published.chat.messageIDs, fixture.observed.chat.messageIDs)
        XCTAssertEqual(published.messages, fixture.observed.messages)
        XCTAssertEqual(published.chat.draft, fixture.observed.chat.draft)
        XCTAssertEqual(published.memory, fixture.observed.memory)
        XCTAssertNil(published.profileEffect)
        XCTAssertNil(published.profileReconsideration)
        XCTAssertNil(published.pendingUserTurn)
    }

    func testMessageFreeReconsiderPublishesReviewedReplacementWithoutFakeHistory()
        async throws
    {
        let response = """
        {
          "proposeProfileEdits":[{
            "edit":{
              "kind":"add",
              "statementKind":"goal",
              "wording":"Speak with a deliberate pace."
            }
          }]
        }
        """
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            providerOutcomes: [.complete(fixtureResponse(response))]
        )
        let prepared = try await fixture.prepareNew()

        guard case let .published(published, _) =
            await fixture.invocations.tryReconsiderProfileChange(prepared)
        else { return XCTFail("expected a reviewed replacement") }

        XCTAssertEqual(published.messages, fixture.observed.messages)
        XCTAssertEqual(published.chat.messageIDs, fixture.observed.chat.messageIDs)
        XCTAssertEqual(published.profileProposal?.changes.count, 1)
        XCTAssertNil(published.profileReconsideration)
    }

    func testReconsiderUsesBoundedRetryScheduleAndFreshAttemptAuthority()
        async throws
    {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            providerOutcomes: [
                .autoRetryableFailure,
                .autoRetryableFailure,
                .autoRetryableFailure,
                .complete(fixtureResponse("{}")),
            ]
        )
        let prepared = try await fixture.prepareNew()

        guard case .withdrawn =
            await fixture.invocations.tryReconsiderProfileChange(prepared)
        else { return XCTFail("fourth bounded Attempt should complete") }

        let requests = await fixture.provider.requests
        XCTAssertEqual(requests.map(\.attemptOrdinal), [1, 2, 3, 4])
        XCTAssertEqual(
            requests.map(\.attemptKind),
            [.standard, .standard, .standard, .standard]
        )
        let delays = await fixture.sleeper.delaysMilliseconds
        XCTAssertEqual(delays, [5_000, 10_000, 15_000])
        XCTAssertEqual(Set(requests.map(\.attemptID)).count, 4)
        XCTAssertEqual(
            Set(requests.map(\.providerIdempotencyValue)).count,
            4
        )
        let durableBeforeLaunch = await fixture.provider.durableBeforeLaunch
        XCTAssertEqual(durableBeforeLaunch, [true, true, true, true])
        let installedAttempts = await fixture.persistence.installedAttempts
        XCTAssertEqual(
            installedAttempts.compactMap { attempt -> ChatMessageID? in
                guard case let .reconsiderProfileChange(coachMessageID)? =
                    attempt.publicationAuthority
                else { return nil }
                return coachMessageID
            },
            Array(fixture.coachMessageIDs.prefix(4))
        )
        XCTAssertTrue(installedAttempts.allSatisfy {
            $0.userMessageID == nil && $0.freshDraftID == nil
        })
        let diagnostics = fixture.diagnostics.recordedEvents()
        XCTAssertEqual(
            diagnostics.map(\.reason),
            [
                .providerAutoRetryable,
                .providerAutoRetryable,
                .providerAutoRetryable,
            ]
        )
        XCTAssertTrue(diagnostics.allSatisfy {
            $0.classification == .providerAutoRetryable &&
                $0.disposition == .automaticRetry
        })
    }

    func testReconsiderAutomaticRetryExhaustionRecordsFinalUserRetryDiagnostic()
        async throws
    {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            providerOutcomes: Array(
                repeating: .autoRetryableFailure,
                count: 4
            )
        )
        let prepared = try await fixture.prepareNew()

        guard case .interrupted(_, .providerFailed) =
            await fixture.invocations.tryReconsiderProfileChange(prepared)
        else { return XCTFail("retry exhaustion must remain user-retryable") }

        let diagnostics = fixture.diagnostics.recordedEvents()
        XCTAssertEqual(
            diagnostics.map(\.reason),
            [
                .providerAutoRetryable,
                .providerAutoRetryable,
                .providerAutoRetryable,
                .automaticRetriesExhausted,
            ]
        )
        XCTAssertEqual(diagnostics.last?.classification, .providerUserRetryable)
        XCTAssertEqual(diagnostics.last?.disposition, .userRetryableFailure)
    }

    func testReconsiderProviderUserRetryableRecordsExactDiagnostic()
        async throws
    {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            providerOutcomes: [.userRetryableFailure]
        )
        let prepared = try await fixture.prepareNew()

        guard case .interrupted(_, .providerFailed) =
            await fixture.invocations.tryReconsiderProfileChange(prepared)
        else { return XCTFail("provider failure must remain retryable") }

        let event = try XCTUnwrap(fixture.diagnostics.recordedEvents().first)
        XCTAssertEqual(fixture.diagnostics.recordedEvents().count, 1)
        XCTAssertEqual(event.reason, .providerUserRetryable)
        XCTAssertEqual(event.classification, .providerUserRetryable)
        XCTAssertEqual(event.disposition, .userRetryableFailure)
        let installedInvocation = await fixture.persistence.installedInvocation
        let requests = await fixture.provider.requests
        XCTAssertEqual(event.invocationID, installedInvocation?.id)
        XCTAssertEqual(event.attemptID, requests.first?.attemptID)
        XCTAssertEqual(event.attemptOrdinal, 1)
        XCTAssertEqual(event.retryNumber, 1)
    }

    func testReconsiderRetryStaleRevalidationRecordsEligibilityDiagnostic()
        async throws
    {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            providerOutcomes: [.userRetryableFailure]
        )
        let prepared = try await fixture.prepareNew()
        guard case let .interrupted(current?, .providerFailed) =
            await fixture.invocations.tryReconsiderProfileChange(prepared)
        else { return XCTFail("fixture must first retain the exact Retry") }
        let retry = try RetryProfileReconsiderationInvocationRequest(
            library: fixture.scope,
            observedAggregate: current,
            basis: fixture.basis
        )
        await fixture.persistence.rejectNextRevalidationAsIneligible()

        guard case .rejected(_, .eligibilityChanged) =
            await fixture.invocations.tryReconsiderProfileChange(retry)
        else { return XCTFail("stale retry must remain an eligibility rejection") }

        let diagnostics = fixture.diagnostics.recordedEvents()
        XCTAssertEqual(
            diagnostics.map(\.reason),
            [.providerUserRetryable, .invocationEligibilityChanged]
        )
        XCTAssertEqual(diagnostics.last?.classification, .interruption)
        XCTAssertEqual(diagnostics.last?.disposition, .userRetryableFailure)
    }

    func testReconsiderOverflowGetsOnlyOneShorterRepair() async throws {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            providerOutcomes: [
                .responseOverflow,
                .complete(fixtureResponse("{}")),
            ]
        )
        let prepared = try await fixture.prepareNew()

        guard case .withdrawn =
            await fixture.invocations.tryReconsiderProfileChange(prepared)
        else { return XCTFail("shorter repair should complete") }

        let requests = await fixture.provider.requests
        let delays = await fixture.sleeper.delaysMilliseconds
        XCTAssertEqual(requests.map(\.attemptKind), [.standard, .shorterRepair])
        XCTAssertEqual(delays, [])
        XCTAssertTrue(
            requests[1].pinnedInstruction.contains(
                DefaultInvocations.shorterRepairInstruction
            )
        )
        let event = try XCTUnwrap(fixture.diagnostics.recordedEvents().first)
        XCTAssertEqual(fixture.diagnostics.recordedEvents().count, 1)
        XCTAssertEqual(event.reason, .responseOverflowRepair)
        XCTAssertEqual(event.classification, .invalidProviderResponse)
        XCTAssertEqual(event.disposition, .automaticRetry)
    }

    func testPreparedReconsiderCapabilityIsOneShot() async throws {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false
        )
        let prepared = try await fixture.prepareNew()

        guard case .withdrawn =
            await fixture.invocations.tryReconsiderProfileChange(prepared)
        else { return XCTFail("first capability use should publish") }
        let replay = await fixture.invocations.tryReconsiderProfileChange(
            prepared
        )

        XCTAssertEqual(replay, .rejected(nil, .eligibilityChanged))
        let providerRequestCount = await fixture.provider.requests.count
        XCTAssertEqual(providerRequestCount, 1)
    }

    func testInvalidResponseRetainsExactSourceAndSidecarWithRetryFailure()
        async throws
    {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            providerOutcomes: [
                .complete(fixtureResponse(#"{"messageBlocks":[]}"#)),
            ]
        )
        let prepared = try await fixture.prepareNew()

        guard case let .interrupted(current?, .invalidProviderResponse) =
            await fixture.invocations.tryReconsiderProfileChange(prepared)
        else { return XCTFail("invalid complete response must be retryable") }

        XCTAssertEqual(current.profileEffect, fixture.observed.profileEffect)
        XCTAssertEqual(
            current.profileReconsideration,
            fixture.reconsideration.replacingFailure(.coachResponseInvalid)
        )
        XCTAssertEqual(current.chat.messageIDs, fixture.observed.chat.messageIDs)
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(publicationCount, 0)
    }

    func testRetryAcceptsFreshBasisAndReusesReservedResultPosition()
        async throws
    {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            initialFailure: .coachProviderError,
            providerOutcomes: [.complete(fixtureResponse("{}"))]
        )
        let retry = try RetryProfileReconsiderationInvocationRequest(
            library: fixture.scope,
            observedAggregate: await fixture.persistence.aggregateSnapshot(),
            basis: fixture.basis
        )

        guard case let .withdrawn(published, _) =
            await fixture.invocations.tryReconsiderProfileChange(retry)
        else { return XCTFail("freshly assessed Retry must launch") }

        XCTAssertNil(published.profileReconsideration)
        let installedInvocation = await fixture.persistence.installedInvocation
        let installed = try XCTUnwrap(installedInvocation)
        XCTAssertEqual(
            installed.responsePositionID,
            fixture.reconsideration.resultResponsePositionID
        )
        XCTAssertEqual(installed.preparedProfile, fixture.basis.latestProfile.provenance)
        let lastBasis = await fixture.contextSource.lastBasis
        XCTAssertEqual(lastBasis, fixture.basis)
    }

    func testOperationalRetryRequiresExactProcessLiveSnapshot() async throws {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            providerOutcomes: [
                .complete(fixtureResponse(#"{"messageBlocks":[]}"#)),
                .complete(fixtureResponse("{}")),
            ],
            unavailableAbortCount: 1
        )
        let prepared = try await fixture.prepareNew()
        let first = await fixture.invocations.tryReconsiderProfileChange(
            prepared
        )
        guard case let .operationallyInterrupted(_, retry, _) = first else {
            return XCTFail("uncertain terminal persistence needs exact Retry")
        }

        let different = ProfileReconsiderationInvocationRequest(
            library: retry.library,
            chatID: retry.chatID,
            sourceEffectIdentity: retry.sourceEffectIdentity,
            resultResponsePositionID: try ChatResponsePositionID(
                "rsp-20260909T114500000Z-MVWX"
            )
        )
        let differentOutcome = await fixture.invocations
            .tryReconsiderProfileChange(different)
        XCTAssertEqual(differentOutcome, .rejected(nil, .eligibilityChanged))
        let freshCoordinator = try fixture.makeFreshCoordinator()
        let freshOutcome = await freshCoordinator.tryReconsiderProfileChange(
            retry
        )
        XCTAssertEqual(freshOutcome, .rejected(nil, .eligibilityChanged))
        let acquisitionCountBeforeRetry = await fixture.persistence
            .operationalAcquisitionCount
        XCTAssertEqual(acquisitionCountBeforeRetry, 0)

        guard case .withdrawn =
            await fixture.invocations.tryReconsiderProfileChange(retry)
        else { return XCTFail("exact process-live Retry must recover and launch") }
        let acquisitionCount = await fixture.persistence
            .operationalAcquisitionCount
        XCTAssertEqual(acquisitionCount, 1)
    }

    func testOperationalRetrySurvivesPreLaunchAdmissionRejection()
        async throws
    {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            providerOutcomes: [
                .complete(fixtureResponse(#"{"messageBlocks":[]}"#)),
                .complete(fixtureResponse("{}")),
            ],
            unavailableAbortCount: 1
        )
        let prepared = try await fixture.prepareNew()
        let first = await fixture.invocations.tryReconsiderProfileChange(
            prepared
        )
        guard case let .operationallyInterrupted(_, retry, _) = first else {
            return XCTFail("uncertain terminal persistence needs exact Retry")
        }

        await fixture.admission.setDecision(
            .cooldown(
                lastAdmittedAt: try UTCInstant(
                    "2026-09-09T11:59:00.000Z"
                ),
                reopensAt: try UTCInstant("2026-09-09T12:00:00.000Z")
            )
        )
        guard case .rejected(_, .admissionCooldown) =
            await fixture.invocations.tryReconsiderProfileChange(retry)
        else { return XCTFail("Retry must preserve admission rejection") }
        let rejected = await fixture.persistence.aggregateSnapshot()
        XCTAssertEqual(rejected.profileEffect, fixture.observed.profileEffect)
        XCTAssertEqual(
            rejected.profileReconsideration?.sourceEffectIdentity,
            retry.sourceEffectIdentity
        )
        XCTAssertNil(rejected.profileReconsideration?.failure)

        await fixture.admission.setDecision(.admitted)
        guard case .withdrawn =
            await fixture.invocations.tryReconsiderProfileChange(retry)
        else {
            return XCTFail(
                "the exact process-live Retry must remain usable"
            )
        }
        let operationalAcquisitionCount = await fixture.persistence
            .operationalAcquisitionCount
        let providerRequestCount = await fixture.provider.requests.count
        XCTAssertEqual(operationalAcquisitionCount, 2)
        XCTAssertEqual(providerRequestCount, 2)
    }

    func testOperationalRetryIsRevokedAfterEligibilityChanges() async throws {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            providerOutcomes: [
                .complete(fixtureResponse(#"{"messageBlocks":[]}"#)),
            ],
            unavailableAbortCount: 1
        )
        let prepared = try await fixture.prepareNew()
        guard case let .operationallyInterrupted(_, retry, _) =
            await fixture.invocations.tryReconsiderProfileChange(prepared)
        else { return XCTFail("fixture must retain one exact operational Retry") }

        await fixture.persistence.rejectNextRevalidationAsIneligible()
        guard case .rejected(_, .eligibilityChanged) =
            await fixture.invocations.tryReconsiderProfileChange(retry)
        else { return XCTFail("fresh revalidation must revoke stale authority") }

        let replay = await fixture.invocations.tryReconsiderProfileChange(retry)
        XCTAssertEqual(replay, .rejected(nil, .eligibilityChanged))
        let acquisitionCount = await fixture.persistence
            .operationalAcquisitionCount
        XCTAssertEqual(acquisitionCount, 1)
    }

    func testOperationalRetryProvesCommittedPublicationWithoutProviderRelaunch()
        async throws
    {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            providerOutcomes: [.complete(fixtureResponse("{}"))],
            commitPublicationButReportFailureCount: 1,
            unavailablePublicationRecoveryCount: 3
        )
        let prepared = try await fixture.prepareNew()

        guard case let .operationallyInterrupted(_, retry, _) =
            await fixture.invocations.tryReconsiderProfileChange(prepared)
        else {
            return XCTFail("lost publication acknowledgement must remain exact")
        }
        let providerCountBeforeRetry = await fixture.provider.requests.count
        let publicationCountBeforeRetry = await fixture.persistence
            .publicationCount
        XCTAssertEqual(providerCountBeforeRetry, 1)
        XCTAssertEqual(publicationCountBeforeRetry, 1)

        guard case let .withdrawn(recovered, _) =
            await fixture.invocations.tryReconsiderProfileChange(retry)
        else { return XCTFail("Retry must prove the original withdrawal") }

        XCTAssertNil(recovered.profileEffect)
        XCTAssertNil(recovered.profileReconsideration)
        let providerCount = await fixture.provider.requests.count
        let publicationCount = await fixture.persistence.publicationCount
        let acquisitionCount = await fixture.persistence
            .operationalAcquisitionCount
        XCTAssertEqual(providerCount, 1)
        XCTAssertEqual(publicationCount, 1)
        XCTAssertEqual(acquisitionCount, 0)
        let diagnostics = fixture.diagnostics.recordedEvents()
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.reason, .publicationPersistenceUnavailable)
        XCTAssertEqual(diagnostics.first?.classification, .persistenceUnavailable)
        XCTAssertEqual(diagnostics.first?.disposition, .userRetryableFailure)
    }

    func testCommittedAbortTurnsUncertainPublicationIntoOneClickDurableRetry()
        async throws
    {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            providerOutcomes: [
                .complete(fixtureResponse("{}")),
                .complete(fixtureResponse("{}")),
            ],
            failPublicationWithoutCommitCount: 1,
            unavailablePublicationRecoveryCount: 3
        )
        let prepared = try await fixture.prepareNew()

        guard case let .interrupted(current?, .persistenceUnavailable) =
            await fixture.invocations.tryReconsiderProfileChange(prepared),
            current.profileReconsideration?.failure ==
                .coachResponseInterrupted
        else { return XCTFail("committed abort must expose durable Retry") }
        let retry = try RetryProfileReconsiderationInvocationRequest(
            library: fixture.scope,
            observedAggregate: current,
            basis: fixture.basis
        )

        guard case .withdrawn =
            await fixture.invocations.tryReconsiderProfileChange(retry)
        else { return XCTFail("the next Retry click must relaunch") }
        let providerCount = await fixture.provider.requests.count
        XCTAssertEqual(providerCount, 2)
    }

    func testUnresolvedPublicationIsRetainedAcrossEligibleTerminalRecovery()
        async throws
    {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            providerOutcomes: [
                .complete(fixtureResponse("{}")),
                .complete(fixtureResponse("{}")),
            ],
            failPublicationWithoutCommitCount: 1,
            recoverAbortAsEligibleCount: 1,
            unavailablePublicationRecoveryCount: 3
        )
        let prepared = try await fixture.prepareNew()
        guard case let .operationallyInterrupted(_, retry, _) =
            await fixture.invocations.tryReconsiderProfileChange(prepared)
        else { return XCTFail("publication proof must remain process-live") }

        guard case .operationallyInterrupted =
            await fixture.invocations.tryReconsiderProfileChange(retry)
        else { return XCTFail("unavailable proof must not relaunch") }
        let providerCountWhileUnproved = await fixture.provider.requests.count
        XCTAssertEqual(providerCountWhileUnproved, 1)

        guard case .withdrawn =
            await fixture.invocations.tryReconsiderProfileChange(retry)
        else { return XCTFail("authoritative C0 may relaunch exactly once") }
        let providerCount = await fixture.provider.requests.count
        XCTAssertEqual(providerCount, 2)
    }

    func testAdmissionRejectionCleansOnlyProvisionalSidecar() async throws {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            admissionDecision: .cooldown(
                lastAdmittedAt: UTCInstant("2026-09-09T11:59:00.000Z"),
                reopensAt: UTCInstant("2026-09-09T12:00:00.000Z")
            )
        )
        let prepared = try await fixture.prepareNew()

        guard case .rejected(_, .admissionCooldown) =
            await fixture.invocations.tryReconsiderProfileChange(prepared)
        else { return XCTFail("admission rejection must stay pre-launch") }

        let current = await fixture.persistence.aggregateSnapshot()
        XCTAssertEqual(current.profileEffect, fixture.observed.profileEffect)
        XCTAssertNil(current.profileReconsideration)
        let providerRequestCount = await fixture.provider.requests.count
        let activeInvocation = await fixture.persistence.activeInvocation
        XCTAssertEqual(providerRequestCount, 0)
        XCTAssertNil(activeInvocation)
    }

    func testUnprovenPrelaunchRejectionRetainsExactOperationalRetry()
        async throws
    {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            admissionDecision: .cooldown(
                lastAdmittedAt: UTCInstant("2026-09-09T11:59:00.000Z"),
                reopensAt: UTCInstant("2026-09-09T12:00:00.000Z")
            ),
            unavailableTerminationCount: 1
        )
        let prepared = try await fixture.prepareNew()

        guard case let .operationallyInterrupted(_, retry, _) =
            await fixture.invocations.tryReconsiderProfileChange(prepared)
        else {
            return XCTFail("unproved sidecar cleanup must retain exact Retry")
        }
        XCTAssertEqual(retry, prepared.request)
        await fixture.admission.setDecision(.admitted)

        guard case .withdrawn =
            await fixture.invocations.tryReconsiderProfileChange(retry)
        else { return XCTFail("exact Retry must resume without relaunch state") }
        let providerCount = await fixture.provider.requests.count
        XCTAssertEqual(providerCount, 1)
    }

    func testConcurrentInstallRaceCleansProvisionalSidecarOnly() async throws {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            blockInvocationInstall: true
        )
        let prepared = try await fixture.prepareNew()

        guard case .rejected(_, .activeInvocation) =
            await fixture.invocations.tryReconsiderProfileChange(prepared)
        else { return XCTFail("install race must remain a pre-launch rejection") }

        let current = await fixture.persistence.aggregateSnapshot()
        XCTAssertEqual(current.profileEffect, fixture.observed.profileEffect)
        XCTAssertNil(current.profileReconsideration)
        let providerRequestCount = await fixture.provider.requests.count
        XCTAssertEqual(providerRequestCount, 0)
    }

    func testStopRevokesReconsiderBeforeReapAndLateResultCannotPublish()
        async throws
    {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            providerOutcomes: [.complete(fixtureResponse("{}"))]
        )
        await fixture.provider.suspendNextLaunch()
        let prepared = try await fixture.prepareNew()
        let authorities = ProfileReconsiderationStopAuthorityRecorder()
        let task = Task {
            await fixture.invocations.tryReconsiderProfileChange(
                prepared,
                observingStopAuthority: { authority in
                    await authorities.record(authority)
                }
            )
        }
        let authority = await authorities.waitForAuthority()

        let stop = await fixture.invocations.stopProfileReconsideration(
            StopProfileReconsiderationInvocationRequest(prepared.request),
            authority: authority
        )

        guard case let .interrupted(current) = stop else {
            return XCTFail("Stop must persist interruption after reap")
        }
        XCTAssertEqual(
            current.profileReconsideration,
            fixture.reconsideration.replacingFailure(
                .coachResponseInterrupted
            )
        )
        XCTAssertEqual(current.profileEffect, fixture.observed.profileEffect)
        let invocationOutcome = await task.value
        let cancelledAttemptIDs = await fixture.provider.cancelledAttemptIDs
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(invocationOutcome, .stopped)
        XCTAssertEqual(cancelledAttemptIDs, [authority.attemptID])
        XCTAssertEqual(publicationCount, 0)
        let event = try XCTUnwrap(fixture.diagnostics.recordedEvents().first)
        XCTAssertEqual(fixture.diagnostics.recordedEvents().count, 1)
        XCTAssertEqual(event.reason, .coachResponseStopped)
        XCTAssertEqual(event.classification, .interruption)
        XCTAssertEqual(event.disposition, .userRetryableFailure)
        XCTAssertEqual(event.attemptID, authority.attemptID)
    }

    func testUnprovenStopAbortRetainsExactOperationalRetry() async throws {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            providerOutcomes: [
                .complete(fixtureResponse("{}")),
                .complete(fixtureResponse("{}")),
            ],
            unavailableAbortCount: 1
        )
        await fixture.provider.suspendNextLaunch()
        let prepared = try await fixture.prepareNew()
        let authorities = ProfileReconsiderationStopAuthorityRecorder()
        let task = Task {
            await fixture.invocations.tryReconsiderProfileChange(
                prepared,
                observingStopAuthority: { authority in
                    await authorities.record(authority)
                }
            )
        }
        let authority = await authorities.waitForAuthority()

        guard case .persistenceUnavailable =
            await fixture.invocations.stopProfileReconsideration(
                StopProfileReconsiderationInvocationRequest(prepared.request),
                authority: authority
            )
        else { return XCTFail("Stop must surface unproved terminal state") }
        let stopped = await task.value
        XCTAssertEqual(stopped, .stopped)

        guard case .withdrawn = await fixture.invocations
            .tryReconsiderProfileChange(prepared.request)
        else { return XCTFail("Stop must retain the exact raw Retry snapshot") }
        let providerCount = await fixture.provider.requests.count
        XCTAssertEqual(providerCount, 2)
    }

    func testUnconfirmedReapFencesAnswerAndReconsiderSuccessors() async throws {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            cancellationOutcomes: [.unableToConfirm, .reaped]
        )
        await fixture.provider.suspendNextLaunch()
        let prepared = try await fixture.prepareNew()
        let authorities = ProfileReconsiderationStopAuthorityRecorder()
        let task = Task {
            await fixture.invocations.tryReconsiderProfileChange(
                prepared,
                observingStopAuthority: { authority in
                    await authorities.record(authority)
                }
            )
        }
        let authority = await authorities.waitForAuthority()
        let stopRequest = StopProfileReconsiderationInvocationRequest(
            prepared.request
        )

        let firstStop = await fixture.invocations.stopProfileReconsideration(
            stopRequest,
            authority: authority
        )
        XCTAssertEqual(firstStop, .unableToReap)
        let answer = await fixture.invocations.tryInvoke(
            PendingCoachInvocationRequest(
                library: fixture.scope,
                chatID: fixture.observed.chat.id,
                pendingUserTurnID: try PendingUserTurnID(
                    "ptu-20260909T114500000Z-KVWX"
                )
            )
        )
        XCTAssertEqual(answer, .rejected(nil, .activeInvocation))

        guard case .interrupted =
            await fixture.invocations.stopProfileReconsideration(
                stopRequest,
                authority: authority
            )
        else { return XCTFail("exact authority should finish reaping") }
        let invocationOutcome = await task.value
        XCTAssertEqual(invocationOutcome, .stopped)
    }

    func testUnreapedReconsiderStopBlocksAnswerProviderLaunchUntilReaped()
        async throws
    {
        let fixture = try ProfileReconsiderationInvocationFixture(
            retainedActiveEvidence: false,
            cancellationOutcomes: [.unableToConfirm, .reaped]
        )
        let preparedAnswer = try await fixture.prepareAnswer()
        let preparedReconsider = try await fixture.prepareNew()
        await fixture.contextSource.suspendAnswerPostInstallCheck()
        let answerTask = Task {
            await fixture.invocations.tryInvoke(preparedAnswer)
        }
        await fixture.contextSource.waitForAnswerPostInstallCheck()

        await fixture.provider.suspendNextLaunch()
        let authorities = ProfileReconsiderationStopAuthorityRecorder()
        let reconsiderTask = Task {
            await fixture.invocations.tryReconsiderProfileChange(
                preparedReconsider,
                observingStopAuthority: { authority in
                    await authorities.record(authority)
                }
            )
        }
        let authority = await authorities.waitForAuthority()
        let stopRequest = StopProfileReconsiderationInvocationRequest(
            preparedReconsider.request
        )
        let firstStop = await fixture.invocations.stopProfileReconsideration(
            stopRequest,
            authority: authority
        )
        XCTAssertEqual(firstStop, .unableToReap)

        await fixture.contextSource.resumeAnswerPostInstallCheck()
        guard case .interrupted(_, .retryInfrastructureFailed) =
            await answerTask.value
        else {
            return XCTFail(
                "the process-wide unreaped authority must block Answer launch"
            )
        }
        let providerRequestsBeforeReap = await fixture.provider.requests
        XCTAssertEqual(providerRequestsBeforeReap.count, 1)
        XCTAssertEqual(
            providerRequestsBeforeReap.first?.attemptID,
            authority.attemptID
        )

        guard case .interrupted =
            await fixture.invocations.stopProfileReconsideration(
                stopRequest,
                authority: authority
            )
        else { return XCTFail("the exact Stop authority must finish reaping") }
        let reconsiderOutcome = await reconsiderTask.value
        XCTAssertEqual(reconsiderOutcome, .stopped)
    }
}

private func fixtureResponse(_ raw: String) -> CoachProviderCompleteResponse {
    CoachProviderCompleteResponse(body: Data(raw.utf8))
}

private final class ProfileReconsiderationInvocationFixture:
    @unchecked Sendable
{
    let scope = LibraryScope(
        libraryID: try! LibraryID("lib-20260909T115000000Z-1ABC")
    )
    let answerScope = LibraryScope(
        libraryID: try! LibraryID("lib-20260909T115000000Z-2DEF")
    )
    let instant = try! UTCInstant("2026-09-09T12:00:00.000Z")
    let observed: ChatAggregate
    let basis: ProfileReconsiderationBasis
    let reconsideration: ProfileReconsideration
    let newRequest: NewProfileReconsiderationInvocationRequest?
    let persistence: ProfileReconsiderationMemoryPersistence
    let admission: ProfileReconsiderationAdmission
    let provider: ProfileReconsiderationProvider
    let sleeper = ProfileReconsiderationSleeper()
    let diagnostics = ProfileReconsiderationRetryDiagnostics()
    let contextSource: ProfileReconsiderationContextSource
    let invocations: DefaultInvocations
    let coachMessageIDs: [ChatMessageID]

    init(
        retainedActiveEvidence: Bool,
        initialFailure: PendingUserTurnFailure? = nil,
        admissionDecision: InvocationAdmissionClaimOutcome = .admitted,
        providerOutcomes: [CoachProviderAttemptOutcome] = [
            .complete(fixtureResponse("{}")),
        ],
        cancellationOutcomes: [CoachProviderAttemptCancellationOutcome] = [
            .reaped,
        ],
        unavailableAbortCount: Int = 0,
        unavailableTerminationCount: Int = 0,
        blockInvocationInstall: Bool = false,
        commitPublicationButReportFailureCount: Int = 0,
        failPublicationWithoutCommitCount: Int = 0,
        recoverAbortAsEligibleCount: Int = 0,
        unavailablePublicationRecoveryCount: Int = 0
    ) throws {
        let attachment = ChatSessionAttachment(
            attachmentID: try ChatSessionAttachmentID("reconsider-session"),
            sessionID: try SessionID("ses-20260909T110000000Z-2DEF"),
            transcriptRevisionID: try TranscriptRevisionID(
                "trv-20260909T110100000Z-3GHJ"
            )
        )
        let attachments = try ChatAttachments(validating: [attachment])
        let evidence = try EvidenceReference(
            sessionID: attachment.sessionID,
            transcriptRevisionID: attachment.transcriptRevisionID,
            target: .audioEvent(audioEventID: AudioEventID("a000001")),
            display: EvidenceReferenceDisplay(
                sessionLabel: "Practice",
                trustedText: "Silent pause",
                startMilliseconds: 100,
                endMilliseconds: 200
            )
        )
        let inactive = try ProfileStatement(
            statementID: ProfileStatementID(
                "stm-20260909T111000000Z-4KMN"
            ),
            statementKind: .speakingObservation,
            wording: "Transitions are rushed.",
            supportingSessionCount: 0,
            evidence: []
        )
        let active = try ProfileStatement(
            statementID: ProfileStatementID(
                "stm-20260909T111100000Z-5PQR"
            ),
            statementKind: .goal,
            wording: "Pause between ideas.",
            supportingSessionCount: 0,
            evidence: []
        )
        let base = try ProfileRevision(
            revisionID: ProfileRevisionID(
                "prf-20260909T111200000Z-6RST"
            ),
            parentRevisionID: nil,
            generation: 3,
            statementGeneration: 2,
            createdAt: instant,
            statements: [inactive, active]
        )
        let retainedAppend = try ProfileEvidenceAppend(
            target: ProfileProposalTarget(statement: active),
            evidence: [evidence]
        )
        let chatID = try ChatID("cht-20260909T111300000Z-7VWX")
        let sourceResponsePositionID = try ChatResponsePositionID(
            "rsp-20260909T111300000Z-8XYZ"
        )
        let proposal = try ProfileChangeProposal(
            id: ProfileChangeProposalID("prp-20260909T111300000Z-9ABC"),
            chatID: chatID,
            responsePositionID: sourceResponsePositionID,
            baseProfile: ProfileSnapshot(revision: base).provenance,
            changes: [
                .retire(
                    target: ProfileProposalTarget(statement: inactive),
                    evidence: []
                ),
            ],
            evidenceAppends: retainedActiveEvidence ? [retainedAppend] : [],
            createdAt: instant
        )
        let latest = try ProfileRevision(
            revisionID: ProfileRevisionID(
                "prf-20260909T111400000Z-ADEF"
            ),
            parentRevisionID: base.revisionID,
            generation: 4,
            statementGeneration: 3,
            createdAt: instant,
            statements: [active]
        )
        basis = try ProfileReconsiderationBasis(
            sourceEffect: .proposal(proposal),
            baseProfile: ProfileSnapshot(revision: base),
            latestProfile: ProfileSnapshot(revision: latest)
        )
        let empty = try ChatAggregate.newChat(
            chatID: chatID,
            draftID: ChatDraftID("drf-20260909T111500000Z-BGHJ"),
            memoryID: CoachMemoryID("mem-20260909T111500000Z-CKMN"),
            instant: instant,
            profileStatementGeneration: base.statementGeneration,
            attachments: attachments
        )
        observed = try ChatAggregate(
            chat: empty.chat,
            memory: empty.memory,
            profileEffect: .proposal(proposal)
        )
        reconsideration = ProfileReconsideration(
            sourceEffect: .proposal(proposal),
            resultResponsePositionID: try ChatResponsePositionID(
                "rsp-20260909T111600000Z-DPQR"
            ),
            failure: initialFailure
        )
        if initialFailure == nil {
            newRequest = try NewProfileReconsiderationInvocationRequest(
                library: scope,
                observedAggregate: observed,
                reconsideration: reconsideration,
                basis: basis
            )
            persistence = ProfileReconsiderationMemoryPersistence(
                initial: observed,
                unavailableAbortCount: unavailableAbortCount,
                unavailableTerminationCount: unavailableTerminationCount,
                blockInvocationInstall: blockInvocationInstall,
                commitPublicationButReportFailureCount:
                    commitPublicationButReportFailureCount,
                failPublicationWithoutCommitCount:
                    failPublicationWithoutCommitCount,
                recoverAbortAsEligibleCount: recoverAbortAsEligibleCount,
                unavailablePublicationRecoveryCount:
                    unavailablePublicationRecoveryCount
            )
        } else {
            newRequest = nil
            let failed = try ChatAggregate(
                chat: observed.chat,
                memory: observed.memory,
                profileEffect: observed.profileEffect,
                profileReconsideration: reconsideration
            )
            persistence = ProfileReconsiderationMemoryPersistence(
                initial: failed,
                unavailableAbortCount: unavailableAbortCount,
                unavailableTerminationCount: unavailableTerminationCount,
                blockInvocationInstall: blockInvocationInstall,
                commitPublicationButReportFailureCount:
                    commitPublicationButReportFailureCount,
                failPublicationWithoutCommitCount:
                    failPublicationWithoutCommitCount,
                recoverAbortAsEligibleCount: recoverAbortAsEligibleCount,
                unavailablePublicationRecoveryCount:
                    unavailablePublicationRecoveryCount
            )
        }
        admission = ProfileReconsiderationAdmission(
            decision: admissionDecision
        )
        provider = ProfileReconsiderationProvider(
            outcomes: providerOutcomes,
            persistence: persistence,
            cancellationOutcomes: cancellationOutcomes
        )
        contextSource = ProfileReconsiderationContextSource(
            profile: basis.latestProfile.provenance
        )
        coachMessageIDs = try (0 ..< 4).map { ordinal in
            try ChatMessageID(
                [
                    "msg-20260909T112000000Z-EABC",
                    "msg-20260909T112100000Z-FDEF",
                    "msg-20260909T112200000Z-GGHJ",
                    "msg-20260909T112300000Z-HKMN",
                ][ordinal]
            )
        }
        let identities = try ProfileReconsiderationIdentities(
            coachMessageIDs: coachMessageIDs
        )
        invocations = DefaultInvocations(
            persistence: persistence,
            admission: admission,
            provider: provider,
            coachContext: DefaultCoachContextFeature(source: contextSource),
            clock: ProfileReconsiderationClock(instant: instant),
            identities: identities,
            memoryIDGenerator: ProfileReconsiderationMemoryIDs(),
            retrySleeper: sleeper,
            retryDiagnostics: diagnostics,
            transcriptAvailability: .allAvailable
        )
    }

    func prepareNew() async throws -> PreparedProfileReconsiderationInvocation {
        let request = try XCTUnwrap(newRequest)
        let outcome = await invocations
            .prepareNewProfileReconsiderationInvocation(request)
        guard case let .prepared(prepared) = outcome else {
            throw ProfileReconsiderationFixtureError.preparationFailed
        }
        return prepared
    }

    func prepareAnswer() async throws -> PreparedPendingCoachInvocation {
        let empty = try ChatAggregate.newChat(
            chatID: ChatID("cht-20260909T114500000Z-KVWX"),
            draftID: ChatDraftID("drf-20260909T114500000Z-KXYZ"),
            memoryID: CoachMemoryID("mem-20260909T114500000Z-MABC"),
            instant: instant,
            profileStatementGeneration:
                basis.latestProfile.provenance.statementGeneration,
            attachments: .empty
        )
        let draft = try empty.chat.draft.edited(
            text: "Answer only after Reconsider has been reaped.",
            at: instant
        )
        let observed = try ChatAggregate(
            chat: empty.chat.replacingDraft(with: draft),
            memory: empty.memory
        )
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260909T114500000Z-NDEF"),
            draftID: draft.draftID,
            draftVersion: draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260909T114500000Z-PGHJ"
            ),
            failure: nil
        )
        let request = try NewPendingCoachInvocationRequest(
            library: answerScope,
            observedAggregate: observed,
            pendingUserTurn: pending
        )
        guard case let .prepared(prepared) =
            await invocations.prepareNewInvocation(request)
        else { throw ProfileReconsiderationFixtureError.preparationFailed }
        return prepared
    }

    func makeFreshCoordinator() throws -> DefaultInvocations {
        DefaultInvocations(
            persistence: persistence,
            admission: admission,
            provider: provider,
            coachContext: DefaultCoachContextFeature(source: contextSource),
            clock: ProfileReconsiderationClock(instant: instant),
            identities: try ProfileReconsiderationIdentities(
                coachMessageIDs: coachMessageIDs
            ),
            memoryIDGenerator: ProfileReconsiderationMemoryIDs(),
            retrySleeper: sleeper,
            retryDiagnostics: diagnostics,
            transcriptAvailability: .allAvailable
        )
    }
}

private enum ProfileReconsiderationFixtureError: Error {
    case preparationFailed
}

private final class ProfileReconsiderationRetryDiagnostics:
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

private actor ProfileReconsiderationMemoryPersistence:
    InvocationPersistencePort
{
    private var aggregate: ChatAggregate
    private var answerAggregate: ChatAggregate?
    private var answerReservation: InvocationPendingAuthority?
    private var answerActiveInvocation: CoachInvocation?
    private var reservation:
        (authority: InvocationProfileReconsiderationAuthority, provisional: Bool)?
    private(set) var activeInvocation: CoachInvocation?
    private(set) var installedInvocation: CoachInvocation?
    private(set) var installedAttempts: [CoachProviderAttempt] = []
    private(set) var publicationCount = 0
    private(set) var operationalAcquisitionCount = 0
    private var unavailableAbortCount: Int
    private var unavailableTerminationCount: Int
    private var commitPublicationButReportFailureCount: Int
    private var failPublicationWithoutCommitCount: Int
    private var recoverAbortAsEligibleCount: Int
    private var unavailablePublicationRecoveryCount: Int
    private var ineligibleRevalidationCount = 0
    private var installedBasis: ProfileReconsiderationBasis?
    private let blockInvocationInstall: Bool

    init(
        initial: ChatAggregate,
        unavailableAbortCount: Int,
        unavailableTerminationCount: Int,
        blockInvocationInstall: Bool,
        commitPublicationButReportFailureCount: Int,
        failPublicationWithoutCommitCount: Int,
        recoverAbortAsEligibleCount: Int,
        unavailablePublicationRecoveryCount: Int
    ) {
        aggregate = initial
        self.unavailableAbortCount = unavailableAbortCount
        self.unavailableTerminationCount = unavailableTerminationCount
        self.blockInvocationInstall = blockInvocationInstall
        self.commitPublicationButReportFailureCount =
            commitPublicationButReportFailureCount
        self.failPublicationWithoutCommitCount =
            failPublicationWithoutCommitCount
        self.recoverAbortAsEligibleCount = recoverAbortAsEligibleCount
        self.unavailablePublicationRecoveryCount =
            unavailablePublicationRecoveryCount
    }

    func aggregateSnapshot() -> ChatAggregate { aggregate }

    func rejectNextRevalidationAsIneligible() {
        ineligibleRevalidationCount += 1
    }

    func openNewPendingInvocation(
        _ request: NewPendingCoachInvocationRequest
    ) async -> InvocationPendingSessionPreparationOutcome {
        guard answerReservation == nil, answerActiveInvocation == nil else {
            return .blockedByActiveInvocation
        }
        do {
            let locked = try ChatAggregate(
                chat: request.observedAggregate.chat,
                memory: request.observedAggregate.memory,
                messages: request.observedAggregate.messages,
                pendingUserTurn: request.pendingUserTurn,
                profileProposal: request.observedAggregate.profileProposal,
                profileEvidencePublication:
                    request.observedAggregate.profileEvidencePublication
            )
            let pendingRequest = PendingCoachInvocationRequest(
                library: request.library,
                chatID: request.chatID,
                pendingUserTurnID: request.pendingUserTurn.id
            )
            let authority = try InvocationPendingAuthority(
                request: pendingRequest,
                aggregate: locked
            )
            answerAggregate = locked
            answerReservation = authority
            return .opened(
                ProfileReconsiderationAnswerPendingSession(
                    persistence: self,
                    authority: authority
                )
            )
        } catch {
            return .unavailable
        }
    }

    func openPendingInvocation(
        _ request: PendingCoachInvocationRequest
    ) async -> InvocationPendingSessionAcquisitionOutcome { .unavailable }

    func revalidateAnswer(
        _ authority: InvocationPendingAuthority
    ) -> InvocationPendingResolutionOutcome {
        guard answerReservation == authority else { return .unavailable }
        return .eligible(authority)
    }

    func checkAnswerIdentity(
        _ identity: InvocationLaunchIdentity,
        authority: InvocationPendingAuthority
    ) -> InvocationLaunchIdentityAvailabilityOutcome {
        guard answerReservation == authority else { return .unavailable }
        return .available
    }

    func installAnswer(
        _ mutation: InstallCoachInvocationMutation
    ) -> InvocationSessionInstallOutcome {
        guard answerReservation == mutation.authority else {
            return .stale(answerAggregate)
        }
        answerReservation = nil
        answerAggregate = mutation.processingAggregate
        answerActiveInvocation = mutation.invocation
        return .installed(
            ProfileReconsiderationAnswerActiveSession(
                persistence: self,
                invocation: mutation.invocation,
                processingAggregate: mutation.processingAggregate
            )
        )
    }

    func terminateAnswer(
        _ authority: InvocationPendingAuthority,
        termination: InvocationPendingTermination
    ) -> InvocationTerminalPersistenceOutcome {
        guard answerReservation == authority,
              let current = answerAggregate,
              let pending = current.pendingUserTurn
        else { return .recovered(.unavailable) }
        answerReservation = nil
        do {
            switch termination {
            case .rejected:
                answerAggregate = try ChatAggregate(
                    chat: current.chat,
                    memory: current.memory,
                    messages: current.messages
                )
            case .contextCapacityFailure:
                answerAggregate = try ChatAggregate(
                    chat: current.chat,
                    memory: current.memory,
                    messages: current.messages,
                    pendingUserTurn: pending.replacingFailure(
                        .coachContextCannotFit
                    )
                )
            case .interrupted:
                answerAggregate = try ChatAggregate(
                    chat: current.chat,
                    memory: current.memory,
                    messages: current.messages,
                    pendingUserTurn: pending.replacingFailure(
                        .coachResponseInterrupted
                    )
                )
            }
            return .committed(answerAggregate!)
        } catch {
            return .recovered(.unavailable)
        }
    }

    func abandonAnswer(_ authority: InvocationPendingAuthority) {
        guard answerReservation == authority else { return }
        answerReservation = nil
    }

    func abortAnswer(
        invocation: CoachInvocation,
        failure: PendingUserTurnFailure
    ) -> InvocationTerminalPersistenceOutcome {
        guard answerActiveInvocation == invocation,
              let current = answerAggregate,
              let pending = current.pendingUserTurn
        else { return .recovered(.unavailable) }
        answerActiveInvocation = nil
        do {
            answerAggregate = try ChatAggregate(
                chat: current.chat,
                memory: current.memory,
                messages: current.messages,
                pendingUserTurn: pending.replacingFailure(failure)
            )
            return .committed(answerAggregate!)
        } catch {
            return .recovered(.unavailable)
        }
    }

    func openNewProfileReconsiderationInvocation(
        _ request: NewProfileReconsiderationInvocationRequest
    ) async -> InvocationProfileReconsiderationSessionPreparationOutcome {
        guard reservation == nil, activeInvocation == nil,
              aggregate == request.observedAggregate
        else { return .blockedByActiveInvocation }
        do {
            aggregate = try replacingReconsideration(request.reconsideration)
            let authority = try InvocationProfileReconsiderationAuthority(
                request: request.request,
                aggregate: aggregate,
                basis: request.basis
            )
            installedBasis = request.basis
            reservation = (authority, true)
            return .opened(
                ProfileReconsiderationPendingSession(
                    persistence: self,
                    authority: authority
                )
            )
        } catch {
            return .unavailable
        }
    }

    func openRetryProfileReconsiderationInvocation(
        _ request: RetryProfileReconsiderationInvocationRequest
    ) async -> InvocationProfileReconsiderationSessionAcquisitionOutcome {
        guard reservation == nil, activeInvocation == nil,
              aggregate == request.observedAggregate
        else { return .blockedByActiveInvocation }
        do {
            let authority = try InvocationProfileReconsiderationAuthority(
                request: request.request,
                aggregate: aggregate,
                basis: request.basis
            )
            installedBasis = request.basis
            reservation = (authority, false)
            return .opened(
                ProfileReconsiderationPendingSession(
                    persistence: self,
                    authority: authority
                )
            )
        } catch {
            return .ineligible(aggregate)
        }
    }

    func openOperationalProfileReconsiderationInvocation(
        _ request: ProfileReconsiderationInvocationRequest
    ) async -> InvocationProfileReconsiderationSessionAcquisitionOutcome {
        operationalAcquisitionCount += 1
        guard reservation == nil, activeInvocation == nil,
              aggregate.profileReconsideration?.failure == nil,
              let installedBasis
        else { return .blockedByActiveInvocation }
        do {
            let authority = try InvocationProfileReconsiderationAuthority(
                request: request,
                aggregate: aggregate,
                basis: installedBasis
            )
            reservation = (authority, false)
            return .opened(
                ProfileReconsiderationPendingSession(
                    persistence: self,
                    authority: authority
                )
            )
        } catch {
            return .ineligible(aggregate)
        }
    }

    func recoverProfileReconsiderationAfterTerminalFailure(
        _ request: ProfileReconsiderationInvocationRequest
    ) async -> InvocationProfileReconsiderationResolutionOutcome {
        guard reservation == nil, activeInvocation == nil,
              let installedBasis
        else { return .unavailable }
        do {
            return .eligible(
                try InvocationProfileReconsiderationAuthority(
                    request: request,
                    aggregate: aggregate,
                    basis: installedBasis
                )
            )
        } catch {
            return .ineligible(aggregate)
        }
    }

    func recoverPublishedProfileReconsideration(
        _ mutation: PublishProfileReconsiderationInvocationMutation
    ) async -> InvocationPublicationRecoveryOutcome {
        recoverPublished(mutation)
    }

    func revalidate(
        _ authority: InvocationProfileReconsiderationAuthority
    ) -> InvocationProfileReconsiderationResolutionOutcome {
        guard reservation?.authority.request == authority.request else {
            return .unavailable
        }
        if ineligibleRevalidationCount > 0 {
            ineligibleRevalidationCount -= 1
            reservation = nil
            return .ineligible(aggregate)
        }
        do {
            return .eligible(
                try InvocationProfileReconsiderationAuthority(
                    request: authority.request,
                    aggregate: aggregate,
                    basis: authority.basis
                )
            )
        } catch {
            reservation = nil
            return .ineligible(aggregate)
        }
    }

    func checkIdentity(
        _ identity: InvocationProfileReconsiderationLaunchIdentity,
        authority: InvocationProfileReconsiderationAuthority
    ) -> InvocationLaunchIdentityAvailabilityOutcome {
        guard reservation?.authority.request == authority.request else {
            return .stale(aggregate)
        }
        return .available
    }

    func install(
        _ mutation: InstallProfileReconsiderationInvocationMutation
    ) -> InvocationProfileReconsiderationSessionInstallOutcome {
        guard reservation?.authority == mutation.authority,
              activeInvocation == nil
        else { return .stale(aggregate) }
        guard !blockInvocationInstall else {
            return .blockedByActiveInvocation
        }
        reservation = nil
        aggregate = mutation.processingAggregate
        activeInvocation = mutation.invocation
        installedInvocation = mutation.invocation
        installedBasis = mutation.authority.basis
        installedAttempts = [mutation.invocation.attempt]
        return .installed(
            ProfileReconsiderationActiveSession(
                persistence: self,
                invocation: mutation.invocation,
                processingAggregate: mutation.processingAggregate,
                reconsideration: mutation.authority.reconsideration
                    .replacingFailure(nil),
                basis: mutation.authority.basis
            )
        )
    }

    func terminate(
        _ authority: InvocationProfileReconsiderationAuthority,
        termination: InvocationProfileReconsiderationTermination
    ) -> InvocationProfileReconsiderationTerminalPersistenceOutcome {
        guard let reserved = reservation,
              reserved.authority.request == authority.request
        else { return .recovered(.unavailable) }
        reservation = nil
        if unavailableTerminationCount > 0 {
            unavailableTerminationCount -= 1
            return .recovered(.unavailable)
        }
        do {
            switch termination {
            case .rejected:
                if reserved.provisional {
                    aggregate = try replacingReconsideration(nil)
                }
            case let .failed(failure):
                aggregate = try replacingReconsideration(
                    authority.reconsideration.replacingFailure(failure)
                )
            }
            return .committed(aggregate)
        } catch {
            return .recovered(.unavailable)
        }
    }

    func abandon(_ authority: InvocationProfileReconsiderationAuthority) {
        guard let reserved = reservation,
              reserved.authority.request == authority.request
        else { return }
        reservation = nil
        if reserved.provisional {
            aggregate = try! replacingReconsideration(nil)
        }
    }

    func installNext(
        _ mutation: InstallNextProfileReconsiderationAttemptMutation,
        reconsideration: ProfileReconsideration,
        basis: ProfileReconsiderationBasis
    ) -> InvocationProfileReconsiderationNextAttemptInstallOutcome {
        guard activeInvocation == mutation.base else {
            return .stale(aggregate)
        }
        activeInvocation = mutation.replacement
        installedInvocation = mutation.replacement
        installedAttempts.append(mutation.replacement.attempt)
        return .installed(
            ProfileReconsiderationActiveSession(
                persistence: self,
                invocation: mutation.replacement,
                processingAggregate: aggregate,
                reconsideration: reconsideration,
                basis: basis
            )
        )
    }

    func abort(
        invocation: CoachInvocation,
        reconsideration: ProfileReconsideration,
        failure: PendingUserTurnFailure
    ) -> InvocationProfileReconsiderationTerminalPersistenceOutcome {
        guard activeInvocation == invocation else {
            return .stale(aggregate)
        }
        if recoverAbortAsEligibleCount > 0 {
            recoverAbortAsEligibleCount -= 1
            activeInvocation = nil
            guard let installedBasis,
                  let request = reconsiderationRequest(for: invocation),
                  let authority = try? InvocationProfileReconsiderationAuthority(
                      request: request,
                      aggregate: aggregate,
                      basis: installedBasis
                  )
            else { return .recovered(.unavailable) }
            return .recovered(.eligible(authority))
        }
        if unavailableAbortCount > 0 {
            unavailableAbortCount -= 1
            activeInvocation = nil
            return .recovered(.unavailable)
        }
        activeInvocation = nil
        do {
            aggregate = try replacingReconsideration(
                reconsideration.replacingFailure(failure)
            )
            return .committed(aggregate)
        } catch {
            return .recovered(.unavailable)
        }
    }

    func publish(
        _ mutation: PublishProfileReconsiderationInvocationMutation
    ) -> InvocationPublicationOutcome {
        publicationCount += 1
        guard activeInvocation == mutation.invocation,
              aggregate == mutation.base
        else { return .stale(aggregate) }
        if failPublicationWithoutCommitCount > 0 {
            failPublicationWithoutCommitCount -= 1
            return .failed
        }
        aggregate = mutation.replacement
        activeInvocation = nil
        if commitPublicationButReportFailureCount > 0 {
            commitPublicationButReportFailureCount -= 1
            return .failed
        }
        return .committed(aggregate)
    }

    func recoverPublished(
        _ mutation: PublishProfileReconsiderationInvocationMutation
    ) -> InvocationPublicationRecoveryOutcome {
        if unavailablePublicationRecoveryCount > 0 {
            unavailablePublicationRecoveryCount -= 1
            return .unavailable
        }
        if aggregate == mutation.replacement {
            return .published(aggregate)
        }
        if aggregate == mutation.base {
            return .notPublished
        }
        return .unavailable
    }

    func isDurable(
        attemptID: CoachProviderAttemptID,
        idempotencyValue: ProviderIdempotencyValue
    ) -> Bool {
        activeInvocation?.attempt.id == attemptID &&
            activeInvocation?.attempt.transportAuthority?
                .providerIdempotencyValue == idempotencyValue
    }

    private func replacingReconsideration(
        _ reconsideration: ProfileReconsideration?
    ) throws -> ChatAggregate {
        try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            messages: aggregate.messages,
            profileEffect: aggregate.profileEffect,
            profileReconsideration: reconsideration
        )
    }

    private func reconsiderationRequest(
        for invocation: CoachInvocation
    ) -> ProfileReconsiderationInvocationRequest? {
        guard case let .reconsiderProfileChange(
            sourceEffectIdentity,
            resultResponsePositionID
        ) = invocation.intent else { return nil }
        return ProfileReconsiderationInvocationRequest(
            library: LibraryScope(libraryID: invocation.libraryID),
            chatID: invocation.chatID,
            sourceEffectIdentity: sourceEffectIdentity,
            resultResponsePositionID: resultResponsePositionID
        )
    }

}

private actor ProfileReconsiderationAnswerPendingSession:
    InvocationPendingPersistenceSession
{
    nonisolated let authority: InvocationPendingAuthority
    private let persistence: ProfileReconsiderationMemoryPersistence
    private var active = true

    init(
        persistence: ProfileReconsiderationMemoryPersistence,
        authority: InvocationPendingAuthority
    ) {
        self.persistence = persistence
        self.authority = authority
    }

    func revalidate() async -> InvocationPendingResolutionOutcome {
        guard active else { return .unavailable }
        return await persistence.revalidateAnswer(authority)
    }

    func checkLaunchIdentity(
        _ identity: InvocationLaunchIdentity
    ) async -> InvocationLaunchIdentityAvailabilityOutcome {
        guard active else { return .unavailable }
        return await persistence.checkAnswerIdentity(
            identity,
            authority: authority
        )
    }

    func install(
        _ mutation: InstallCoachInvocationMutation
    ) async -> InvocationSessionInstallOutcome {
        guard active else { return .failed }
        let outcome = await persistence.installAnswer(mutation)
        if case .installed = outcome { active = false }
        return outcome
    }

    func terminate(
        _ termination: InvocationPendingTermination
    ) async -> InvocationTerminalPersistenceOutcome {
        guard active else { return .recovered(.unavailable) }
        active = false
        return await persistence.terminateAnswer(
            authority,
            termination: termination
        )
    }

    func abandon() async {
        guard active else { return }
        active = false
        await persistence.abandonAnswer(authority)
    }
}

private actor ProfileReconsiderationAnswerActiveSession:
    InvocationActivePersistenceSession
{
    nonisolated let invocation: CoachInvocation
    nonisolated let processingAggregate: ChatAggregate
    private let persistence: ProfileReconsiderationMemoryPersistence
    private var active = true

    init(
        persistence: ProfileReconsiderationMemoryPersistence,
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
        .failed
    }

    func abort(
        failure: PendingUserTurnFailure
    ) async -> InvocationTerminalPersistenceOutcome {
        guard active else { return .recovered(.unavailable) }
        active = false
        return await persistence.abortAnswer(
            invocation: invocation,
            failure: failure
        )
    }

    func publish(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationOutcome {
        .failed
    }

    func recoverPublished(
        _ mutation: PublishCoachInvocationMutation
    ) async -> InvocationPublicationRecoveryOutcome {
        .unavailable
    }
}

private actor ProfileReconsiderationPendingSession:
    InvocationProfileReconsiderationPersistenceSession
{
    nonisolated let authority: InvocationProfileReconsiderationAuthority
    private let persistence: ProfileReconsiderationMemoryPersistence
    private var active = true

    init(
        persistence: ProfileReconsiderationMemoryPersistence,
        authority: InvocationProfileReconsiderationAuthority
    ) {
        self.persistence = persistence
        self.authority = authority
    }

    func revalidate()
        async -> InvocationProfileReconsiderationResolutionOutcome
    {
        guard active else { return .unavailable }
        return await persistence.revalidate(authority)
    }

    func checkLaunchIdentity(
        _ identity: InvocationProfileReconsiderationLaunchIdentity
    ) async -> InvocationLaunchIdentityAvailabilityOutcome {
        guard active else { return .unavailable }
        return await persistence.checkIdentity(identity, authority: authority)
    }

    func install(
        _ mutation: InstallProfileReconsiderationInvocationMutation
    ) async -> InvocationProfileReconsiderationSessionInstallOutcome {
        guard active else { return .failed }
        let result = await persistence.install(mutation)
        if case .installed = result { active = false }
        return result
    }

    func terminate(
        _ termination: InvocationProfileReconsiderationTermination
    ) async -> InvocationProfileReconsiderationTerminalPersistenceOutcome {
        guard active else { return .recovered(.unavailable) }
        active = false
        return await persistence.terminate(
            authority,
            termination: termination
        )
    }

    func abandon() async {
        guard active else { return }
        active = false
        await persistence.abandon(authority)
    }
}

private actor ProfileReconsiderationActiveSession:
    InvocationProfileReconsiderationActivePersistenceSession
{
    nonisolated let invocation: CoachInvocation
    nonisolated let processingAggregate: ChatAggregate
    nonisolated let reconsideration: ProfileReconsideration
    nonisolated let basis: ProfileReconsiderationBasis
    private let persistence: ProfileReconsiderationMemoryPersistence
    private var active = true

    init(
        persistence: ProfileReconsiderationMemoryPersistence,
        invocation: CoachInvocation,
        processingAggregate: ChatAggregate,
        reconsideration: ProfileReconsideration,
        basis: ProfileReconsiderationBasis
    ) {
        self.persistence = persistence
        self.invocation = invocation
        self.processingAggregate = processingAggregate
        self.reconsideration = reconsideration
        self.basis = basis
    }

    func installNextAttempt(
        _ mutation: InstallNextProfileReconsiderationAttemptMutation
    ) async -> InvocationProfileReconsiderationNextAttemptInstallOutcome {
        guard active, mutation.base == invocation else { return .failed }
        let result = await persistence.installNext(
            mutation,
            reconsideration: reconsideration,
            basis: basis
        )
        if case .installed = result { active = false }
        return result
    }

    func abort(
        failure: PendingUserTurnFailure
    ) async -> InvocationProfileReconsiderationTerminalPersistenceOutcome {
        guard active else { return .recovered(.unavailable) }
        active = false
        return await persistence.abort(
            invocation: invocation,
            reconsideration: reconsideration,
            failure: failure
        )
    }

    func publish(
        _ mutation: PublishProfileReconsiderationInvocationMutation
    ) async -> InvocationPublicationOutcome {
        guard active else { return .failed }
        let result = await persistence.publish(mutation)
        if case .committed = result { active = false }
        return result
    }

    func recoverPublished(
        _ mutation: PublishProfileReconsiderationInvocationMutation
    ) async -> InvocationPublicationRecoveryOutcome {
        await persistence.recoverPublished(mutation)
    }
}

private actor ProfileReconsiderationAdmission: InvocationAdmissionPort {
    private var decision: InvocationAdmissionClaimOutcome
    private(set) var claimCount = 0

    init(decision: InvocationAdmissionClaimOutcome) {
        self.decision = decision
    }

    func setDecision(_ decision: InvocationAdmissionClaimOutcome) {
        self.decision = decision
    }

    func claim(
        library: LibraryScope,
        at instant: UTCInstant
    ) async -> InvocationAdmissionClaimOutcome {
        claimCount += 1
        return decision
    }
}

private actor ProfileReconsiderationProvider: SyntheticCoachProviderPort {
    private var outcomes: [CoachProviderAttemptOutcome]
    private let persistence: ProfileReconsiderationMemoryPersistence
    private var cancellationOutcomes: [CoachProviderAttemptCancellationOutcome]
    private var suspendNext = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var requests: [SyntheticCoachProviderRequest] = []
    private(set) var durableBeforeLaunch: [Bool] = []
    private(set) var cancelledAttemptIDs: [CoachProviderAttemptID] = []

    init(
        outcomes: [CoachProviderAttemptOutcome],
        persistence: ProfileReconsiderationMemoryPersistence,
        cancellationOutcomes: [CoachProviderAttemptCancellationOutcome]
    ) {
        self.outcomes = outcomes
        self.persistence = persistence
        self.cancellationOutcomes = cancellationOutcomes
    }

    func suspendNextLaunch() { suspendNext = true }

    func run(
        _ request: SyntheticCoachProviderRequest
    ) async -> CoachProviderAttemptOutcome {
        durableBeforeLaunch.append(
            await persistence.isDurable(
                attemptID: request.attemptID,
                idempotencyValue: request.providerIdempotencyValue
            )
        )
        requests.append(request)
        if suspendNext {
            suspendNext = false
            await withCheckedContinuation { continuation = $0 }
        }
        return outcomes.isEmpty
            ? .complete(fixtureResponse("{}"))
            : outcomes.removeFirst()
    }

    func cancelAndReap(
        attemptID: CoachProviderAttemptID,
        graceMilliseconds: Int64
    ) async -> CoachProviderAttemptCancellationOutcome {
        cancelledAttemptIDs.append(attemptID)
        continuation?.resume()
        continuation = nil
        return cancellationOutcomes.isEmpty
            ? .reaped
            : cancellationOutcomes.removeFirst()
    }
}

private actor ProfileReconsiderationSleeper: InvocationRetrySleeping {
    private(set) var delaysMilliseconds: [Int64] = []

    func sleep(milliseconds: Int64) async throws {
        delaysMilliseconds.append(milliseconds)
    }
}

private actor ProfileReconsiderationContextSource: CoachContextSnapshotPort {
    private let profile: CoachProfileProvenance
    private(set) var reconsiderResolutionCount = 0
    private(set) var lastBasis: ProfileReconsiderationBasis?
    private var pendingCurrentCheckCount = 0
    private var shouldSuspendAnswerPostInstallCheck = false
    private var answerPostInstallContinuation:
        CheckedContinuation<Void, Never>?

    init(profile: CoachProfileProvenance) {
        self.profile = profile
    }

    func suspendAnswerPostInstallCheck() {
        shouldSuspendAnswerPostInstallCheck = true
    }

    func waitForAnswerPostInstallCheck() async {
        while answerPostInstallContinuation == nil { await Task.yield() }
    }

    func resumeAnswerPostInstallCheck() {
        answerPostInstallContinuation?.resume()
        answerPostInstallContinuation = nil
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
        do {
            return .resolved(
                try CoachContextResolvedSnapshot(
                    input: CoachContextQuoteInput(
                        profile: .object(["statements": .array([])]),
                        memory: .object([
                            "generalNotes": .string(""),
                            "sessionSummaries": .array([]),
                        ]),
                        history: [],
                        currentDraft: request.draft.text
                    ),
                    configuration: try fixtureContextConfiguration(),
                    authority: CoachContextSnapshotAuthority(
                        binding: .pending(
                            library: request.library,
                            chatID: request.chatID,
                            draftID: request.draft.draftID,
                            draftVersion: request.draft.version,
                            pendingUserTurnID: request.pendingUserTurn.id,
                            responsePositionID:
                                request.pendingUserTurn.responsePositionID
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

    func resolveReconsider(
        _ request: CoachContextReconsiderRequest
    ) async -> CoachContextSnapshotOutcome {
        reconsiderResolutionCount += 1
        lastBasis = request.basis
        do {
            let attachments = request.chat.attachments.values.map {
                PreparedCoachAttachment.inline(requestValue: .object([
                    "displayLabel": .string("Practice"),
                    "kind": .string("inline"),
                    "sessionAttachmentId": .string($0.attachmentID.rawValue),
                    "transcript": .object([
                        "audioEvents": .array([]),
                        "lines": .array([]),
                    ]),
                ]))
            }
            return .resolved(
                try CoachContextResolvedSnapshot(
                    input: CoachContextQuoteInput(
                        memory: .object([
                            "generalNotes": .string(""),
                            "sessionSummaries": .array([]),
                        ]),
                        history: [],
                        reconsidering: request,
                        attachments: attachments
                    ),
                    configuration: try fixtureContextConfiguration(),
                    authority: CoachContextSnapshotAuthority(
                        binding: .reconsider(request),
                        contextGeneration: 1,
                        configurationGeneration: 1,
                        profile: request.basis.latestProfile.provenance
                    )
                )
            )
        } catch {
            return .sourceUnavailable
        }
    }

    func isCurrent(_ authority: CoachContextSnapshotAuthority) async -> Bool {
        if case .pending = authority.binding {
            pendingCurrentCheckCount += 1
            if pendingCurrentCheckCount > 1,
               shouldSuspendAnswerPostInstallCheck
            {
                shouldSuspendAnswerPostInstallCheck = false
                await withCheckedContinuation {
                    answerPostInstallContinuation = $0
                }
            }
        }
        return true
    }

    func acquireAuthorityLease(
        _ authority: CoachContextSourceLeaseAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        await acquireImmutableAuthorityLease(authority)
    }

    private func fixtureContextConfiguration() throws
        -> CoachContextConfiguration
    {
        try CoachContextConfiguration(
            descriptor: CoachProviderDescriptor(
                displayName: "Reconsider fixture",
                contextBudget: CoachContextBudget(
                    contextWindowTokens: 100_000,
                    responseReservedTokens: 2_048,
                    safetyMarginTokens: 1
                ),
                coachMemoryMaxTokens: 2_048
            ),
            policy: CoachProviderEstimationPolicy(
                providerIdentifier: "reconsider-fixture-v1",
                responseCollectorByteCeiling: 64_000,
                framing: CoachProviderFraming(),
                attachmentProjectionPolicy: try CoachAttachmentProjectionPolicy(
                    maximumInlineTranscriptTokens: 1_024,
                    tokenEstimator: .utf8ByteUpperBound()
                )
            )
        )
    }
}

private actor ProfileReconsiderationIdentities: InvocationIdentityGenerating {
    private let coachMessageIDs: [ChatMessageID]
    private var invocationOrdinal = 0
    private var attemptOrdinal = 0

    init(coachMessageIDs: [ChatMessageID]) throws {
        self.coachMessageIDs = coachMessageIDs
    }

    func generateInvocationID(
        at instant: UTCInstant
    ) async -> CoachInvocationID {
        invocationOrdinal += 1
        return try! CoachInvocationID(
            "inv-20260909T113000000Z-\(invocationOrdinal)ABC"
        )
    }

    func generateAttemptIdentity(
        at instant: UTCInstant,
        ordinal: UInt8,
        kind: CoachProviderAttemptKind,
        transcriptHandleCount: Int
    ) async -> InvocationAttemptIdentity {
        InvocationAttemptIdentity(
            attemptID: try! CoachProviderAttemptID(
                "atm-20260909T113100000Z-1DEF"
            ),
            idempotencyValue: try! ProviderIdempotencyValue("unused-answer"),
            userMessageID: try! ChatMessageID(
                "msg-20260909T113100000Z-2GHJ"
            ),
            coachMessageID: try! ChatMessageID(
                "msg-20260909T113100000Z-3KMN"
            ),
            freshDraftID: try! ChatDraftID(
                "drf-20260909T113100000Z-4PQR"
            )
        )
    }

    func generateProfileReconsiderationAttemptIdentity(
        at instant: UTCInstant,
        ordinal: UInt8,
        kind: CoachProviderAttemptKind,
        transcriptHandleCount: Int
    ) async -> InvocationProfileReconsiderationAttemptIdentity {
        let index = attemptOrdinal
        attemptOrdinal += 1
        let suffixes = ["1ABC", "2DEF", "3GHJ", "4KMN"]
        return InvocationProfileReconsiderationAttemptIdentity(
            attemptID: try! CoachProviderAttemptID(
                "atm-20260909T113200000Z-\(suffixes[index])"
            ),
            idempotencyValue: try! ProviderIdempotencyValue(
                "reconsider-attempt-\(index + 1)"
            ),
            coachMessageID: coachMessageIDs[index]
        )
    }
}

private struct ProfileReconsiderationMemoryIDs: CoachMemoryIDGenerator {
    func generateCoachMemoryID(at instant: UTCInstant) async -> CoachMemoryID {
        try! CoachMemoryID("mem-20260909T114000000Z-JRST")
    }
}

private struct ProfileReconsiderationClock: ChatClock {
    let instant: UTCInstant
    func now() async -> UTCInstant { instant }
}

private actor ProfileReconsiderationStopAuthorityRecorder {
    private var authorities: [ProfileReconsiderationInvocationStopAuthority] = []

    func record(_ authority: ProfileReconsiderationInvocationStopAuthority) {
        authorities.append(authority)
    }

    func waitForAuthority() async -> ProfileReconsiderationInvocationStopAuthority {
        while authorities.isEmpty { await Task.yield() }
        return authorities.removeFirst()
    }
}
