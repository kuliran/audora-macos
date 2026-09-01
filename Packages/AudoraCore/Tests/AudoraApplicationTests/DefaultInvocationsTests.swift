@testable @_spi(CoachContextQualification) @_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
import XCTest

final class DefaultInvocationsTests: XCTestCase {
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
        XCTAssertEqual(requests.map(\.attempt.ordinal), [1, 2, 3, 4])
        XCTAssertEqual(requests.map(\.attempt.kind), [
            .standard, .standard, .standard, .standard,
        ])
        XCTAssertEqual(Set(requests.map(\.attempt.id)).count, 4)
        XCTAssertEqual(
            Set(requests.compactMap {
                $0.attempt.transportAuthority?.providerIdempotencyValue
            }).count,
            4
        )
        XCTAssertEqual(Set(requests.map(\.attempt.userMessageID)).count, 4)
        XCTAssertEqual(Set(requests.map(\.attempt.coachMessageID)).count, 4)
        XCTAssertEqual(Set(requests.map(\.attempt.freshDraftID)).count, 4)
        XCTAssertEqual(
            Set(requests.compactMap { $0.transcriptAccess.handles.first }).count,
            4
        )
        XCTAssertEqual(
            requests.map { $0.exchange.request },
            Array(repeating: requests[0].exchange.request, count: 4),
            "automatic retry must keep the frozen semantic request bytes"
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
        XCTAssertEqual(requests.map(\.attempt.ordinal), [1, 2])
        XCTAssertEqual(requests.map(\.attempt.kind), [.standard, .shorterRepair])
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
        XCTAssertEqual(
            aggregate.chat.messageIDs,
            [
                try XCTUnwrap(requests[1].attempt.userMessageID),
                try XCTUnwrap(requests[1].attempt.coachMessageID),
            ]
        )
        XCTAssertEqual(aggregate.chat.draft.draftID, requests[1].attempt.freshDraftID)
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
        XCTAssertEqual(requests.map(\.attempt.ordinal), [1, 2, 3, 4])
        XCTAssertEqual(
            requests.map(\.attempt.kind),
            [.standard, .standard, .standard, .standard]
        )
        let delays = await fixture.sleeper.recordedDelays()
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(delays, [5_000, 10_000, 15_000])
        XCTAssertEqual(publicationCount, 0)
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
    }

    func testAdmissionRejectionLaunchesNothingAndUnlocksTheSamePopulatedDraft() async throws {
        let fixture = try InvocationFixture(
            contextWindow: 100_000,
            admissionDecision: .cooldown(
                lastAdmittedAt: UTCInstant("2026-08-30T11:59:30.001Z"),
                reopensAt: UTCInstant("2026-08-30T12:00:30.001Z")
            )
        )

        let outcome = await fixture.invocations.tryInvoke(fixture.request)

        guard case let .rejected(aggregate, .admissionCooldown) = outcome else {
            return XCTFail("expected a typed cooldown rejection")
        }
        XCTAssertEqual(aggregate?.chat.draft, fixture.initial.chat.draft)
        XCTAssertNil(aggregate?.pendingUserTurn)
        let launchCount = await fixture.provider.launchCount
        let publicationCount = await fixture.persistence.publicationCount
        XCTAssertEqual(launchCount, 0)
        XCTAssertEqual(publicationCount, 0)
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
    let contextSource: InvocationContextSource
    let invocations: DefaultInvocations

    let userMessageID = try! ChatMessageID("msg-20260830T120000000Z-7RST")
    let coachMessageID = try! ChatMessageID("msg-20260830T120000000Z-8VWX")
    let freshDraftID = try! ChatDraftID("drf-20260830T120000000Z-9YZ0")

    init(
        contextWindow: Int,
        admissionDecision: InvocationAdmissionClaimOutcome = .admitted,
        draftText: String = "Keep this exact user Draft",
        contextIsCurrent: Bool = true,
        pendingFailure: PendingUserTurnFailure? = nil,
        clock: (any ChatClock)? = nil,
        providerOutcomes: [CoachProviderAttemptOutcome] = [
            .complete(markdown: "A concise **synthetic** answer."),
        ],
        includesOnDemandAttachment: Bool = false,
        identityGenerator: (any InvocationIdentityGenerating)? = nil
    ) throws {
        let empty = try ChatAggregate.emptyDevelopmentChat(
            chatID: ChatID("cht-20260830T120000000Z-1ABC"),
            draftID: ChatDraftID("drf-20260830T120000000Z-2DEF"),
            memoryID: CoachMemoryID("mem-20260830T120000000Z-3GHJ"),
            instant: instant,
            profileStatementGeneration: 7
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
            persistence: persistence
        )
        sleeper = RecordingInvocationRetrySleeper()
        contextSource = InvocationContextSource(
            contextWindow: contextWindow,
            isCurrent: contextIsCurrent,
            includesOnDemandAttachment: includesOnDemandAttachment
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
            retrySleeper: sleeper
        )
    }
}

private actor MemoryInvocationPersistence: InvocationPersistencePort {
    enum RevalidationDirective: Sendable {
        case current
        case ineligible
    }

    enum InstallDirective: Sendable {
        case installed
        case failed
        case activeExists
        case staleWithCurrent
        case staleWithoutSnapshot
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

    init(initial: ChatAggregate) {
        aggregate = initial
    }

    func isDurable(_ invocation: CoachInvocation) -> Bool {
        activeInvocation == invocation
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
        return .installed(mutation.invocation)
    }

    func installNextAttempt(
        _ mutation: InstallNextCoachProviderAttemptMutation
    ) async -> InvocationNextAttemptInstallOutcome {
        guard activeInvocation == mutation.base else { return .stale(aggregate) }
        activeInvocation = mutation.replacement
        installedAttemptOrdinals.append(mutation.replacement.attempt.ordinal)
        return .installed(
            ScriptedActiveInvocationSession(
                persistence: self,
                invocation: mutation.replacement,
                processingAggregate: aggregate
            )
        )
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
    private var outcomes: [CoachProviderAttemptOutcome]
    private let persistence: MemoryInvocationPersistence
    private var shouldSuspend = false
    private var launchStarted = false
    private var launchContinuation: CheckedContinuation<Void, Never>?

    init(
        outcomes: [CoachProviderAttemptOutcome],
        persistence: MemoryInvocationPersistence
    ) {
        self.outcomes = outcomes
        self.persistence = persistence
    }

    func failNextLaunch() { outcomes.insert(.userRetryableFailure, at: 0) }

    func returnInvalidResponseNextLaunch() {
        outcomes.insert(.complete(markdown: ""), at: 0)
    }

    func suspendNextLaunch() { shouldSuspend = true }

    func waitUntilLaunchStarts() async {
        while !launchStarted { await Task.yield() }
    }

    func resumeLaunch() {
        launchContinuation?.resume()
        launchContinuation = nil
    }

    func recordedAttemptKinds() -> [CoachProviderAttemptKind] {
        requests.map(\.attempt.kind)
    }

    func recordedAttemptOrdinals() -> [UInt8] {
        requests.map(\.attempt.ordinal)
    }

    func run(_ request: SyntheticCoachProviderRequest) async -> CoachProviderAttemptOutcome {
        durableBeforeLaunch.append(await persistence.isDurable(request.invocation))
        launchCount += 1
        requests.append(request)
        serializedRequests.append(Array(request.exchange.request))
        launchStarted = true
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { launchContinuation = $0 }
        }
        guard !outcomes.isEmpty else {
            return .complete(markdown: "A concise **synthetic** answer.")
        }
        return outcomes.removeFirst()
    }
}

private actor RecordingInvocationRetrySleeper: InvocationRetrySleeping {
    private(set) var delaysMilliseconds: [Int64] = []

    func sleep(milliseconds: Int64) async throws {
        delaysMilliseconds.append(milliseconds)
    }

    func recordedDelays() -> [Int64] { delaysMilliseconds }
}

private actor InvocationContextSource: CoachContextSnapshotPort {
    private let contextWindow: Int
    private let current: Bool
    private let includesOnDemandAttachment: Bool
    private(set) var pendingResolutionCount = 0
    private var currentCheckCount = 0
    nonisolated let profile = CoachProfileProvenance(
        revisionID: try! ProfileRevisionID("prf-20260830T115900000Z-4GHJ"),
        statementGeneration: 9
    )

    init(
        contextWindow: Int,
        isCurrent: Bool,
        includesOnDemandAttachment: Bool = false
    ) {
        self.contextWindow = contextWindow
        current = isCurrent
        self.includesOnDemandAttachment = includesOnDemandAttachment
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
                        profile: .object(["statements": .array([])]),
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
                                        "lines": .array([]),
                                        "audioEvents": .array([]),
                                    ]),
                                ])
                            ),
                        ] : []
                    ),
                    configuration: try CoachContextConfiguration(
                        descriptor: CoachProviderDescriptor(
                            displayName: "Synthetic fixture",
                            contextBudget: CoachContextBudget(
                                contextWindowTokens: contextWindow,
                                responseReservedTokens: min(4, max(1, contextWindow - 2)),
                                safetyMarginTokens: 1
                            ),
                            coachMemoryMaxTokens: 1
                        ),
                        policy: CoachProviderEstimationPolicy(
                            providerIdentifier: "synthetic-fixture-v1",
                            responseCollectorByteCeiling: 8_192,
                            framing: CoachProviderFraming(),
                            tokenEstimator: .utf8ByteUpperBound()
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
