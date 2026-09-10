@_spi(InvocationTesting) import AudoraApplication
import AudoraDomain
@testable import AudoraMacPresentation
import Foundation
import XCTest

@MainActor
final class ChatProfileUpdateTimelineTests: XCTestCase {
    func testSemanticGenerationsInsertDividersBeforeTheTurnsThatUsedThem() throws {
        let aggregate = try makeAggregate(
            creationGeneration: 1,
            turns: [
                Turn(generation: 1, userText: "First question", coachText: "First answer"),
                Turn(generation: 2, userText: nil, coachText: "Reconsidered answer"),
                Turn(generation: 4, userText: "Latest question", coachText: "Latest answer"),
            ]
        )
        let state = ChatFeatureState(
            selection: .open(aggregate),
            currentProfileStatementGeneration: 5
        )

        let projection = ChatTimelinePresentation.project(
            aggregate,
            state: state
        )

        XCTAssertEqual(
            projection.successfulHistory.map(EntrySummary.init),
            [
                .message("First question"),
                .message("First answer"),
                .profileUpdate(2),
                .message("Reconsidered answer"),
                .profileUpdate(4),
                .message("Latest question"),
                .message("Latest answer"),
            ]
        )
        XCTAssertEqual(
            projection.tailProfileUpdate,
            ProfileUpdateDividerPresentation(statementGeneration: 5)
        )
        XCTAssertEqual(projection.tailPlacement, .afterSuccessfulContent)
    }

    func testLatestUnusedTailGenerationCoalescesWithoutPersistingAnEvent() throws {
        let aggregate = try makeAggregate(creationGeneration: 3, turns: [])

        let first = ChatTimelinePresentation.project(
            aggregate,
            state: ChatFeatureState(
                selection: .open(aggregate),
                currentProfileStatementGeneration: 7
            )
        )
        let replacement = ChatTimelinePresentation.project(
            aggregate,
            state: ChatFeatureState(
                selection: .open(aggregate),
                currentProfileStatementGeneration: 9
            )
        )

        XCTAssertTrue(first.successfulHistory.isEmpty)
        XCTAssertEqual(first.tailProfileUpdate?.statementGeneration, 7)
        XCTAssertEqual(replacement.tailProfileUpdate?.statementGeneration, 9)
        XCTAssertEqual(aggregate.chat.messageIDs, [])
    }

    func testUnchangedStatementGenerationKeepsEvidenceOnlyUpdatesSilent() throws {
        let aggregate = try makeAggregate(
            creationGeneration: 6,
            turns: [Turn(generation: 6, userText: "Question", coachText: "Answer")]
        )

        let projection = ChatTimelinePresentation.project(
            aggregate,
            state: ChatFeatureState(
                selection: .open(aggregate),
                currentProfileStatementGeneration: 6
            )
        )

        XCTAssertEqual(
            projection.successfulHistory.map(EntrySummary.init),
            [.message("Question"), .message("Answer")]
        )
        XCTAssertNil(projection.tailProfileUpdate)
        XCTAssertNil(projection.tailPlacement)
    }

    func testLegacyCoachMessagePreservesLastKnownGenerationAnchor() throws {
        let aggregate = try makeAggregate(
            creationGeneration: 1,
            turns: [
                Turn(generation: 3, userText: "First", coachText: "Known"),
                Turn(
                    generation: nil,
                    userText: nil,
                    coachText: "Legacy",
                    schemaVersion: 1
                ),
                Turn(generation: 4, userText: "Next", coachText: "Newer"),
            ]
        )

        let projection = ChatTimelinePresentation.project(
            aggregate,
            state: ChatFeatureState(
                selection: .open(aggregate),
                currentProfileStatementGeneration: 4
            )
        )

        XCTAssertEqual(
            projection.successfulHistory.map(EntrySummary.init),
            [
                .profileUpdate(3),
                .message("First"),
                .message("Known"),
                .message("Legacy"),
                .profileUpdate(4),
                .message("Next"),
                .message("Newer"),
            ]
        )
        XCTAssertNil(projection.tailProfileUpdate)
    }

    func testUnavailableCurrentHeadDoesNotInventATailDivider() throws {
        let aggregate = try makeAggregate(creationGeneration: 3, turns: [])

        let projection = ChatTimelinePresentation.project(
            aggregate,
            state: ChatFeatureState(selection: .open(aggregate))
        )

        XCTAssertTrue(projection.successfulHistory.isEmpty)
        XCTAssertNil(projection.tailProfileUpdate)
        XCTAssertNil(projection.tailPlacement)
    }

    func testUnloadedMessageBodiesSuppressDerivedMarkers() throws {
        let loaded = try makeAggregate(
            creationGeneration: 1,
            turns: [Turn(generation: 5, userText: "Question", coachText: "Answer")]
        )
        let unloaded = try ChatAggregate(
            chat: loaded.chat,
            memory: loaded.memory,
            messages: []
        )

        let projection = ChatTimelinePresentation.project(
            unloaded,
            state: ChatFeatureState(
                selection: .open(unloaded),
                currentProfileStatementGeneration: 9
            )
        )

        XCTAssertTrue(projection.successfulHistory.isEmpty)
        XCTAssertNil(projection.pendingActionProfileUpdate)
        XCTAssertNil(projection.tailProfileUpdate)
        XCTAssertNil(projection.tailPlacement)
    }

    func testProfileUpdateWaitsWhileTheOriginalUserTurnIsStillProcessing() throws {
        let aggregate = try makeAggregate(
            creationGeneration: 2,
            turns: [],
            pendingFailure: nil,
            includesPendingTurn: true
        )
        let state = ChatFeatureState(
            selection: .open(aggregate),
            composer: .locked(
                aggregate.chat.draft,
                try XCTUnwrap(aggregate.pendingUserTurn)
            ),
            currentProfileStatementGeneration: 3,
            activity: .invokingCoach(aggregate.chat.id)
        )

        let projection = ChatTimelinePresentation.project(aggregate, state: state)

        XCTAssertEqual(projection.tailProfileUpdate?.statementGeneration, 3)
        XCTAssertEqual(projection.tailPlacement, .deferred)
    }

    func testProfileUpdateAppearsAfterAnInterruptedUserTurn() throws {
        let aggregate = try makeAggregate(
            creationGeneration: 2,
            turns: [],
            pendingFailure: .coachResponseInterrupted,
            includesPendingTurn: true
        )
        let state = ChatFeatureState(
            selection: .open(aggregate),
            composer: .locked(
                aggregate.chat.draft,
                try XCTUnwrap(aggregate.pendingUserTurn)
            ),
            currentProfileStatementGeneration: 4
        )

        let projection = ChatTimelinePresentation.project(aggregate, state: state)

        XCTAssertEqual(projection.tailProfileUpdate?.statementGeneration, 4)
        XCTAssertEqual(projection.tailPlacement, .afterPendingUserTurn)
    }

    func testRetryPreparedWithNewProfilePlacesItsDividerBeforePendingAction() throws {
        let aggregate = try makeAggregate(
            creationGeneration: 2,
            turns: [],
            includesPendingTurn: true,
            pendingPreparedGeneration: 5
        )
        let state = ChatFeatureState(
            selection: .open(aggregate),
            composer: .locked(
                aggregate.chat.draft,
                try XCTUnwrap(aggregate.pendingUserTurn)
            ),
            currentProfileStatementGeneration: 5,
            activity: .invokingCoach(aggregate.chat.id)
        )

        let projection = ChatTimelinePresentation.project(aggregate, state: state)

        XCTAssertEqual(
            projection.pendingActionProfileUpdate,
            ProfileUpdateDividerPresentation(statementGeneration: 5)
        )
        XCTAssertEqual(
            projection.pendingActionPlacement,
            .beforePendingUserTurn
        )
        XCTAssertNil(projection.tailProfileUpdate)
        XCTAssertNil(projection.tailPlacement)
    }

    func testNewerHeadWaitsBehindRetryPreparedProfile() throws {
        let aggregate = try makeAggregate(
            creationGeneration: 2,
            turns: [],
            includesPendingTurn: true,
            pendingPreparedGeneration: 5
        )
        let state = ChatFeatureState(
            selection: .open(aggregate),
            composer: .locked(
                aggregate.chat.draft,
                try XCTUnwrap(aggregate.pendingUserTurn)
            ),
            currentProfileStatementGeneration: 7,
            activity: .invokingCoach(aggregate.chat.id)
        )

        let projection = ChatTimelinePresentation.project(aggregate, state: state)

        XCTAssertEqual(
            projection.pendingActionProfileUpdate?.statementGeneration,
            5
        )
        XCTAssertEqual(
            projection.pendingActionPlacement,
            .beforePendingUserTurn
        )
        XCTAssertEqual(projection.tailProfileUpdate?.statementGeneration, 7)
        XCTAssertEqual(projection.tailPlacement, .deferred)
    }

    func testActiveAttemptAuthoritySuppliesExactPreparedGeneration() throws {
        let aggregate = try makeAggregate(
            creationGeneration: 2,
            turns: [],
            includesPendingTurn: true
        )
        let pending = try XCTUnwrap(aggregate.pendingUserTurn)
        let authority = InvocationStopAuthority(
            testingRequest: StopCoachInvocationRequest(
                library: LibraryScope(
                    libraryID: try LibraryID(
                        "lib-20260910T120000000Z-9ABC"
                    )
                ),
                chatID: aggregate.chat.id,
                pendingUserTurnID: pending.id
            ),
            invocationID: try CoachInvocationID(
                "inv-20260910T120000000Z-1DEF"
            ),
            attemptID: try CoachProviderAttemptID(
                "atm-20260910T120000000Z-2GHJ"
            ),
            preparedProfile: CoachProfileProvenance(
                revisionID: nil,
                statementGeneration: 5
            ),
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000333"
            )!
        )
        let state = ChatFeatureState(
            selection: .open(aggregate),
            composer: .locked(aggregate.chat.draft, pending),
            currentProfileStatementGeneration: 7,
            coachInvocationStopAuthority: authority,
            activity: .invokingCoach(aggregate.chat.id)
        )

        let projection = ChatTimelinePresentation.project(aggregate, state: state)

        XCTAssertEqual(
            projection.pendingActionProfileUpdate?.statementGeneration,
            5
        )
        XCTAssertEqual(projection.tailProfileUpdate?.statementGeneration, 7)
        XCTAssertEqual(projection.tailPlacement, .deferred)
    }

    func testNewerDurablePendingGenerationWinsOverMatchingAttemptAuthority()
        throws
    {
        let aggregate = try makeAggregate(
            creationGeneration: 2,
            turns: [],
            includesPendingTurn: true,
            pendingPreparedGeneration: 5
        )
        let pending = try XCTUnwrap(aggregate.pendingUserTurn)
        let authority = InvocationStopAuthority(
            testingRequest: StopCoachInvocationRequest(
                library: LibraryScope(
                    libraryID: try LibraryID(
                        "lib-20260910T120000000Z-1YZA"
                    )
                ),
                chatID: aggregate.chat.id,
                pendingUserTurnID: pending.id
            ),
            invocationID: try CoachInvocationID(
                "inv-20260910T120000000Z-2BCD"
            ),
            attemptID: try CoachProviderAttemptID(
                "atm-20260910T120000000Z-3EFG"
            ),
            preparedProfile: CoachProfileProvenance(
                revisionID: nil,
                statementGeneration: 4
            ),
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000336"
            )!
        )
        let state = ChatFeatureState(
            selection: .open(aggregate),
            composer: .locked(aggregate.chat.draft, pending),
            currentProfileStatementGeneration: 7,
            coachInvocationStopAuthority: authority,
            activity: .invokingCoach(aggregate.chat.id)
        )

        let projection = ChatTimelinePresentation.project(
            aggregate,
            state: state
        )

        XCTAssertEqual(
            projection.pendingActionProfileUpdate?.statementGeneration,
            5
        )
        XCTAssertEqual(projection.tailProfileUpdate?.statementGeneration, 7)
    }

    func testNewerMatchingAttemptAuthorityWinsOverStaleDurablePendingGeneration()
        throws
    {
        let aggregate = try makeAggregate(
            creationGeneration: 2,
            turns: [],
            includesPendingTurn: true,
            pendingPreparedGeneration: 5
        )
        let pending = try XCTUnwrap(aggregate.pendingUserTurn)
        let authority = InvocationStopAuthority(
            testingRequest: StopCoachInvocationRequest(
                library: LibraryScope(
                    libraryID: try LibraryID(
                        "lib-20260910T120000000Z-1YZA"
                    )
                ),
                chatID: aggregate.chat.id,
                pendingUserTurnID: pending.id
            ),
            invocationID: try CoachInvocationID(
                "inv-20260910T120000000Z-2BCD"
            ),
            attemptID: try CoachProviderAttemptID(
                "atm-20260910T120000000Z-3EFG"
            ),
            preparedProfile: CoachProfileProvenance(
                revisionID: nil,
                statementGeneration: 7
            ),
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000338"
            )!
        )
        let state = ChatFeatureState(
            selection: .open(aggregate),
            composer: .locked(aggregate.chat.draft, pending),
            currentProfileStatementGeneration: 9,
            coachInvocationStopAuthority: authority,
            activity: .invokingCoach(aggregate.chat.id)
        )

        let projection = ChatTimelinePresentation.project(
            aggregate,
            state: state
        )

        XCTAssertEqual(
            projection.pendingActionProfileUpdate?.statementGeneration,
            7
        )
        XCTAssertEqual(
            projection.pendingActionPlacement,
            .beforePendingUserTurn
        )
        XCTAssertEqual(projection.tailProfileUpdate?.statementGeneration, 9)
        XCTAssertEqual(projection.tailPlacement, .deferred)
    }

    func testMismatchedAttemptAuthorityCannotMoveThePendingDivider() throws {
        let aggregate = try makeAggregate(
            creationGeneration: 2,
            turns: [],
            includesPendingTurn: true
        )
        let pending = try XCTUnwrap(aggregate.pendingUserTurn)
        let staleAuthority = InvocationStopAuthority(
            testingRequest: StopCoachInvocationRequest(
                library: LibraryScope(
                    libraryID: try LibraryID(
                        "lib-20260910T120000000Z-3KMN"
                    )
                ),
                chatID: aggregate.chat.id,
                pendingUserTurnID: try PendingUserTurnID(
                    "ptu-20260910T120000000Z-4PQR"
                )
            ),
            invocationID: try CoachInvocationID(
                "inv-20260910T120000000Z-5RST"
            ),
            attemptID: try CoachProviderAttemptID(
                "atm-20260910T120000000Z-6VWX"
            ),
            preparedProfile: CoachProfileProvenance(
                revisionID: nil,
                statementGeneration: 5
            ),
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000334"
            )!
        )
        let state = ChatFeatureState(
            selection: .open(aggregate),
            composer: .locked(aggregate.chat.draft, pending),
            currentProfileStatementGeneration: 7,
            coachInvocationStopAuthority: staleAuthority,
            activity: .invokingCoach(aggregate.chat.id)
        )

        let projection = ChatTimelinePresentation.project(aggregate, state: state)

        XCTAssertNil(projection.pendingActionProfileUpdate)
        XCTAssertNil(projection.pendingActionPlacement)
        XCTAssertEqual(projection.tailProfileUpdate?.statementGeneration, 7)
        XCTAssertEqual(projection.tailPlacement, .deferred)
    }

    func testInterruptedRetryKeepsItsPreparedDividerBeforeNewerTail() throws {
        let aggregate = try makeAggregate(
            creationGeneration: 2,
            turns: [],
            pendingFailure: .coachResponseInterrupted,
            includesPendingTurn: true,
            pendingPreparedGeneration: 5
        )
        let state = ChatFeatureState(
            selection: .open(aggregate),
            composer: .locked(
                aggregate.chat.draft,
                try XCTUnwrap(aggregate.pendingUserTurn)
            ),
            currentProfileStatementGeneration: 7
        )

        let projection = ChatTimelinePresentation.project(aggregate, state: state)

        XCTAssertEqual(
            projection.pendingActionProfileUpdate?.statementGeneration,
            5
        )
        XCTAssertEqual(
            projection.pendingActionPlacement,
            .beforePendingUserTurn
        )
        XCTAssertEqual(projection.tailProfileUpdate?.statementGeneration, 7)
        XCTAssertEqual(projection.tailPlacement, .afterPendingUserTurn)
    }

    func testNewerHeadWaitsBehindActiveReconsideration() throws {
        let base = try makeAggregate(creationGeneration: 2, turns: [])
        let aggregate = try addingReconsideration(
            to: base,
            failure: nil,
            preparedGeneration: 5
        )
        let state = ChatFeatureState(
            selection: .open(aggregate),
            currentProfileStatementGeneration: 7,
            activity: .reconsideringProfileEffect(aggregate.chat.id)
        )

        let projection = ChatTimelinePresentation.project(aggregate, state: state)

        XCTAssertEqual(
            projection.pendingActionProfileUpdate?.statementGeneration,
            5
        )
        XCTAssertEqual(
            projection.pendingActionPlacement,
            .beforeProfileReconsiderationResult
        )
        XCTAssertEqual(projection.tailProfileUpdate?.statementGeneration, 7)
        XCTAssertEqual(projection.tailPlacement, .deferred)
    }

    func testActiveReconsiderationAuthoritySuppliesExactPreparedGeneration()
        throws
    {
        let base = try makeAggregate(creationGeneration: 2, turns: [])
        let aggregate = try addingReconsideration(
            to: base,
            failure: nil,
            preparedGeneration: nil
        )
        let reconsideration = try XCTUnwrap(aggregate.profileReconsideration)
        let authority = ProfileReconsiderationInvocationStopAuthority(
            testingRequest: StopProfileReconsiderationInvocationRequest(
                library: LibraryScope(
                    libraryID: try LibraryID(
                        "lib-20260910T120000000Z-7VWX"
                    )
                ),
                chatID: aggregate.chat.id,
                sourceEffectIdentity: reconsideration.sourceEffectIdentity,
                resultResponsePositionID:
                    reconsideration.resultResponsePositionID
            ),
            invocationID: try CoachInvocationID(
                "inv-20260910T120000000Z-8YZA"
            ),
            attemptID: try CoachProviderAttemptID(
                "atm-20260910T120000000Z-9BCD"
            ),
            preparedProfile: CoachProfileProvenance(
                revisionID: nil,
                statementGeneration: 5
            ),
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000335"
            )!
        )
        let state = ChatFeatureState(
            selection: .open(aggregate),
            currentProfileStatementGeneration: 7,
            profileReconsiderationStopAuthority: authority,
            activity: .reconsideringProfileEffect(aggregate.chat.id)
        )

        let projection = ChatTimelinePresentation.project(
            aggregate,
            state: state
        )

        XCTAssertEqual(
            projection.pendingActionProfileUpdate?.statementGeneration,
            5
        )
        XCTAssertEqual(
            projection.pendingActionPlacement,
            .beforeProfileReconsiderationResult
        )
        XCTAssertEqual(projection.tailProfileUpdate?.statementGeneration, 7)
        XCTAssertEqual(projection.tailPlacement, .deferred)
    }

    func testNewerDurableReconsiderationGenerationWinsOverMatchingAuthority()
        throws
    {
        let base = try makeAggregate(creationGeneration: 2, turns: [])
        let aggregate = try addingReconsideration(
            to: base,
            failure: nil,
            preparedGeneration: 5
        )
        let reconsideration = try XCTUnwrap(aggregate.profileReconsideration)
        let authority = ProfileReconsiderationInvocationStopAuthority(
            testingRequest: StopProfileReconsiderationInvocationRequest(
                library: LibraryScope(
                    libraryID: try LibraryID(
                        "lib-20260910T120000000Z-4GHJ"
                    )
                ),
                chatID: aggregate.chat.id,
                sourceEffectIdentity: reconsideration.sourceEffectIdentity,
                resultResponsePositionID:
                    reconsideration.resultResponsePositionID
            ),
            invocationID: try CoachInvocationID(
                "inv-20260910T120000000Z-5KMN"
            ),
            attemptID: try CoachProviderAttemptID(
                "atm-20260910T120000000Z-6PQR"
            ),
            preparedProfile: CoachProfileProvenance(
                revisionID: nil,
                statementGeneration: 4
            ),
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000337"
            )!
        )
        let state = ChatFeatureState(
            selection: .open(aggregate),
            currentProfileStatementGeneration: 7,
            profileReconsiderationStopAuthority: authority,
            activity: .reconsideringProfileEffect(aggregate.chat.id)
        )

        let projection = ChatTimelinePresentation.project(
            aggregate,
            state: state
        )

        XCTAssertEqual(
            projection.pendingActionProfileUpdate?.statementGeneration,
            5
        )
        XCTAssertEqual(projection.tailProfileUpdate?.statementGeneration, 7)
    }

    func testNewerMatchingReconsiderationAuthorityWinsOverStaleDurableGeneration()
        throws
    {
        let base = try makeAggregate(creationGeneration: 2, turns: [])
        let aggregate = try addingReconsideration(
            to: base,
            failure: nil,
            preparedGeneration: 5
        )
        let reconsideration = try XCTUnwrap(aggregate.profileReconsideration)
        let authority = ProfileReconsiderationInvocationStopAuthority(
            testingRequest: StopProfileReconsiderationInvocationRequest(
                library: LibraryScope(
                    libraryID: try LibraryID(
                        "lib-20260910T120000000Z-4GHJ"
                    )
                ),
                chatID: aggregate.chat.id,
                sourceEffectIdentity: reconsideration.sourceEffectIdentity,
                resultResponsePositionID:
                    reconsideration.resultResponsePositionID
            ),
            invocationID: try CoachInvocationID(
                "inv-20260910T120000000Z-5KMN"
            ),
            attemptID: try CoachProviderAttemptID(
                "atm-20260910T120000000Z-6PQR"
            ),
            preparedProfile: CoachProfileProvenance(
                revisionID: nil,
                statementGeneration: 7
            ),
            capabilityID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000339"
            )!
        )
        let state = ChatFeatureState(
            selection: .open(aggregate),
            currentProfileStatementGeneration: 9,
            profileReconsiderationStopAuthority: authority,
            activity: .reconsideringProfileEffect(aggregate.chat.id)
        )

        let projection = ChatTimelinePresentation.project(
            aggregate,
            state: state
        )

        XCTAssertEqual(
            projection.pendingActionProfileUpdate?.statementGeneration,
            7
        )
        XCTAssertEqual(
            projection.pendingActionPlacement,
            .beforeProfileReconsiderationResult
        )
        XCTAssertEqual(projection.tailProfileUpdate?.statementGeneration, 9)
        XCTAssertEqual(projection.tailPlacement, .deferred)
    }

    func testInterruptedReconsiderationKeepsPreparedDividerBeforeNewerTail()
        throws
    {
        let base = try makeAggregate(creationGeneration: 2, turns: [])
        let aggregate = try addingReconsideration(
            to: base,
            failure: .coachResponseInterrupted,
            preparedGeneration: 5
        )
        let state = ChatFeatureState(
            selection: .open(aggregate),
            currentProfileStatementGeneration: 7
        )

        let projection = ChatTimelinePresentation.project(aggregate, state: state)

        XCTAssertEqual(
            projection.pendingActionProfileUpdate?.statementGeneration,
            5
        )
        XCTAssertEqual(
            projection.pendingActionPlacement,
            .beforeProfileReconsiderationResult
        )
        XCTAssertEqual(projection.tailProfileUpdate?.statementGeneration, 7)
        XCTAssertEqual(projection.tailPlacement, .afterProfileReconsideration)
        let independentlyAccessibleDividers = [
            projection.pendingActionProfileUpdate,
            projection.tailProfileUpdate,
        ].compactMap { $0 }
        XCTAssertEqual(
            independentlyAccessibleDividers.map(\.statementGeneration),
            [5, 7]
        )
        XCTAssertEqual(
            independentlyAccessibleDividers.map(\.accessibilityLabel),
            ["Profile was updated", "Profile was updated"]
        )
    }

    func testMessageFreeReconsiderationReplacementAnchorsAroundProposalCard()
        throws
    {
        let base = try makeAggregate(creationGeneration: 2, turns: [])
        let aggregate = try addingCompletedReconsiderationReplacement(
            to: base,
            baseGeneration: 5
        )
        let state = ChatFeatureState(
            selection: .open(aggregate),
            currentProfileStatementGeneration: 7
        )

        let projection = ChatTimelinePresentation.project(
            aggregate,
            state: state
        )

        XCTAssertEqual(
            projection.profileEffectProfileUpdate?.statementGeneration,
            5
        )
        XCTAssertNil(projection.pendingActionProfileUpdate)
        XCTAssertNil(projection.pendingActionPlacement)
        XCTAssertEqual(projection.tailProfileUpdate?.statementGeneration, 7)
        XCTAssertEqual(projection.tailPlacement, .afterProfileEffectCard)
    }

    func testMessageFreeReplacementAnchorSurvivesASecondReconsideration()
        throws
    {
        let base = try makeAggregate(creationGeneration: 2, turns: [])
        let replacement = try addingCompletedReconsiderationReplacement(
            to: base,
            baseGeneration: 5
        )

        for (failure, expectedTailPlacement) in [
            (nil, ChatTimelineTailPlacement.deferred),
            (
                PendingUserTurnFailure.coachResponseInterrupted,
                ChatTimelineTailPlacement.afterProfileReconsideration
            ),
        ] {
            let aggregate = try addingReconsiderationToExistingEffect(
                to: replacement,
                failure: failure,
                preparedGeneration: 7
            )
            let state = ChatFeatureState(
                selection: .open(aggregate),
                currentProfileStatementGeneration: 9,
                activity: failure == nil
                    ? .reconsideringProfileEffect(aggregate.chat.id)
                    : nil
            )

            let projection = ChatTimelinePresentation.project(
                aggregate,
                state: state
            )

            XCTAssertEqual(
                projection.profileEffectProfileUpdate?.statementGeneration,
                5
            )
            XCTAssertEqual(
                projection.pendingActionProfileUpdate?.statementGeneration,
                7
            )
            XCTAssertEqual(
                projection.pendingActionPlacement,
                .beforeProfileReconsiderationResult
            )
            XCTAssertEqual(
                projection.tailProfileUpdate?.statementGeneration,
                9
            )
            XCTAssertEqual(
                projection.tailPlacement,
                expectedTailPlacement
            )
        }
    }

    func testCurrentHeadTailFollowsCompletedEvidencePublicationCard() throws {
        let attachment = try ChatSessionAttachment(
            attachmentID: ChatSessionAttachmentID(
                "timeline-evidence-attachment"
            ),
            sessionID: SessionID("ses-20260910T120300000Z-7YZA"),
            transcriptRevisionID: TranscriptRevisionID(
                "trv-20260910T120300000Z-8BCD"
            )
        )
        let base = try makeAggregate(
            creationGeneration: 2,
            turns: [
                Turn(
                    generation: 2,
                    userText: "Review this evidence",
                    coachText: "This supports your existing observation."
                )
            ],
            attachments: ChatAttachments(validating: [attachment])
        )
        let aggregate = try addingEvidencePublication(
            to: base,
            attachment: attachment
        )

        let projection = ChatTimelinePresentation.project(
            aggregate,
            state: ChatFeatureState(
                selection: .open(aggregate),
                currentProfileStatementGeneration: 4
            )
        )

        XCTAssertNil(projection.pendingActionProfileUpdate)
        XCTAssertEqual(projection.tailProfileUpdate?.statementGeneration, 4)
        XCTAssertEqual(projection.tailPlacement, .afterProfileEffectCard)
    }

    func testCurrentHeadTailFollowsOrdinaryCoachProposalCard() throws {
        let base = try makeAggregate(
            creationGeneration: 2,
            turns: [
                Turn(
                    generation: 5,
                    userText: "Help me slow down",
                    coachText: "Try pausing before each key point."
                )
            ]
        )
        let aggregate = try addingProposalForLastResponse(
            to: base,
            baseGeneration: 5
        )

        let projection = ChatTimelinePresentation.project(
            aggregate,
            state: ChatFeatureState(
                selection: .open(aggregate),
                currentProfileStatementGeneration: 7
            )
        )

        XCTAssertEqual(
            projection.successfulHistory.map(EntrySummary.init),
            [
                .profileUpdate(5),
                .message("Help me slow down"),
                .message("Try pausing before each key point."),
            ]
        )
        XCTAssertNil(projection.pendingActionProfileUpdate)
        XCTAssertEqual(projection.tailProfileUpdate?.statementGeneration, 7)
        XCTAssertEqual(projection.tailPlacement, .afterProfileEffectCard)
    }

    func testMessageFreeWithdrawalLeavesLatestDividerAfterSuccessfulHistory()
        throws
    {
        let aggregate = try makeAggregate(
            creationGeneration: 2,
            turns: [
                Turn(
                    generation: 2,
                    userText: "Earlier question",
                    coachText: "Earlier answer"
                )
            ]
        )

        let projection = ChatTimelinePresentation.project(
            aggregate,
            state: ChatFeatureState(
                selection: .open(aggregate),
                currentProfileStatementGeneration: 5
            )
        )

        XCTAssertNil(projection.pendingActionProfileUpdate)
        XCTAssertEqual(projection.tailProfileUpdate?.statementGeneration, 5)
        XCTAssertEqual(projection.tailPlacement, .afterSuccessfulContent)
    }

    func testRetryUsingANewerProfilePlacesDividerBeforePublishedUserTurn() throws {
        let aggregate = try makeAggregate(
            creationGeneration: 2,
            turns: [Turn(generation: 5, userText: "Retry text", coachText: "Retry answer")]
        )

        let projection = ChatTimelinePresentation.project(
            aggregate,
            state: ChatFeatureState(
                selection: .open(aggregate),
                currentProfileStatementGeneration: 5
            )
        )

        XCTAssertEqual(
            projection.successfulHistory.map(EntrySummary.init),
            [
                .profileUpdate(5),
                .message("Retry text"),
                .message("Retry answer"),
            ]
        )
        XCTAssertNil(projection.tailProfileUpdate)
    }

    func testDividerHasNeutralAccessibleCopy() {
        let divider = ProfileUpdateDividerPresentation(statementGeneration: 12)

        XCTAssertEqual(divider.visibleText, "Profile was updated")
        XCTAssertEqual(divider.accessibilityLabel, "Profile was updated")
    }

    private struct Turn {
        let generation: UInt64?
        let userText: String?
        let coachText: String
        let schemaVersion: UInt32

        init(
            generation: UInt64?,
            userText: String?,
            coachText: String,
            schemaVersion: UInt32 = ChatMessage.schemaVersion
        ) {
            self.generation = generation
            self.userText = userText
            self.coachText = coachText
            self.schemaVersion = schemaVersion
        }
    }

    private enum EntrySummary: Equatable {
        case profileUpdate(UInt64)
        case message(String)

        init(_ entry: ChatTimelineEntryPresentation) {
            switch entry {
            case let .profileUpdate(divider):
                self = .profileUpdate(divider.statementGeneration)
            case let .message(message):
                switch message.content {
                case let .user(text):
                    self = .message(text)
                case let .coach(blocks):
                    self = .message(blocks.map(\.markdown).joined())
                }
            }
        }
    }

    private func makeAggregate(
        creationGeneration: UInt64,
        turns: [Turn],
        pendingFailure: PendingUserTurnFailure? = nil,
        includesPendingTurn: Bool = false,
        pendingPreparedGeneration: UInt64? = nil,
        attachments: ChatAttachments = .empty
    ) throws -> ChatAggregate {
        let instant = try UTCInstant("2026-09-10T12:00:00.000Z")
        let chatID = try ChatID("cht-20260910T120000000Z-1ABC")
        let draftID = try ChatDraftID("drf-20260910T120000000Z-2DEF")
        let memoryID = try CoachMemoryID("mem-20260910T120000000Z-3GHJ")
        let draft = try ChatDraft(
            draftID: draftID,
            version: 0,
            text: includesPendingTurn ? "Locked text" : "",
            updatedAt: instant
        )
        var messages: [ChatMessage] = []
        for (index, turn) in turns.enumerated() {
            let position = try ChatResponsePositionID(
                "rsp-20260910T12000\(index)000Z-4KMN"
            )
            if let userText = turn.userText {
                messages.append(
                    try ChatMessage(
                        schemaVersion: turn.schemaVersion,
                        id: ChatMessageID(
                            "msg-20260910T12000\(index)100Z-5PQR"
                        ),
                        responsePositionID: position,
                        content: .user(text: userText),
                        createdAt: instant
                    )
                )
            }
            messages.append(
                try ChatMessage(
                    schemaVersion: turn.schemaVersion,
                    id: ChatMessageID(
                        "msg-20260910T12000\(index)200Z-6RST"
                    ),
                    responsePositionID: position,
                    content: .coach(markdown: turn.coachText),
                    coachProfile: turn.generation.map {
                        CoachProfileProvenance(
                            revisionID: nil,
                            statementGeneration: $0
                        )
                    },
                    createdAt: instant
                )
            )
        }
        let chat = try Chat(
            id: chatID,
            manifestRevision: 0,
            title: ChatTitle("Timeline"),
            createdAt: instant,
            updatedAt: instant,
            creation: ChatCreation(
                kind: .newChat,
                originAttachmentID: nil,
                attachments: attachments
            ),
            profileStatementGenerationAtCreation: creationGeneration,
            attachments: attachments,
            draft: draft,
            messageIDs: messages.map(\.id),
            currentMemoryID: memoryID
        )
        let pending =
            includesPendingTurn
            ? PendingUserTurn(
                id: try PendingUserTurnID("ptu-20260910T120000000Z-7VWX"),
                draftID: draftID,
                draftVersion: draft.version,
                responsePositionID: try ChatResponsePositionID(
                    "rsp-20260910T120000000Z-8XYZ"
                ),
                failure: pendingFailure,
                preparedProfileStatementGeneration:
                    pendingPreparedGeneration
            )
            : nil
        return try ChatAggregate(
            chat: chat,
            memory: CoachMemory(
                memoryID: memoryID,
                chatID: chatID,
                generalNotes: "",
                sessionSummaries: [],
                attachments: attachments
            ),
            messages: messages,
            pendingUserTurn: pending
        )
    }

    private func addingReconsideration(
        to aggregate: ChatAggregate,
        failure: PendingUserTurnFailure?,
        preparedGeneration: UInt64?
    ) throws -> ChatAggregate {
        let instant = try UTCInstant("2026-09-10T12:01:00.000Z")
        let proposal = try ProfileChangeProposal(
            id: ProfileChangeProposalID(
                "prp-20260910T120100000Z-9ABC"
            ),
            chatID: aggregate.chat.id,
            responsePositionID: ChatResponsePositionID(
                "rsp-20260910T120100000Z-1DEF"
            ),
            baseProfile: CoachProfileProvenance(
                revisionID: nil,
                statementGeneration:
                    aggregate.chat.profileStatementGenerationAtCreation
            ),
            changes: [
                .add(
                    statement: try ProfileProposedStatement(
                        statementID: ProfileStatementID(
                            "stm-20260910T120100000Z-2GHJ"
                        ),
                        statementKind: .goal,
                        wording: "Pause between ideas.",
                        evidence: []
                    )
                )
            ],
            createdAt: instant
        )
        let effect = ChatProfileEffect.proposal(proposal)
        return try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            messages: aggregate.messages,
            profileEffect: effect,
            profileReconsideration: ProfileReconsideration(
                sourceEffect: effect,
                resultResponsePositionID: try ChatResponsePositionID(
                    "rsp-20260910T120100000Z-3KMN"
                ),
                failure: failure,
                preparedProfileStatementGeneration: preparedGeneration
            )
        )
    }

    private func addingCompletedReconsiderationReplacement(
        to aggregate: ChatAggregate,
        baseGeneration: UInt64
    ) throws -> ChatAggregate {
        let instant = try UTCInstant("2026-09-10T12:02:00.000Z")
        let proposal = try ProfileChangeProposal.reconsidered(
            id: ProfileChangeProposalID(
                "prp-20260910T120200000Z-4PQR"
            ),
            chatID: aggregate.chat.id,
            responsePositionID: ChatResponsePositionID(
                "rsp-20260910T120200000Z-5RST"
            ),
            baseProfile: CoachProfileProvenance(
                revisionID: nil,
                statementGeneration: baseGeneration
            ),
            changes: [
                .add(
                    statement: try ProfileProposedStatement(
                        statementID: ProfileStatementID(
                            "stm-20260910T120200000Z-6VWX"
                        ),
                        statementKind: .goal,
                        wording: "Pause before each key point.",
                        evidence: []
                    )
                )
            ],
            createdAt: instant
        )
        return try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            messages: aggregate.messages,
            profileEffect: .proposal(proposal)
        )
    }

    private func addingReconsiderationToExistingEffect(
        to aggregate: ChatAggregate,
        failure: PendingUserTurnFailure?,
        preparedGeneration: UInt64
    ) throws -> ChatAggregate {
        let effect = try XCTUnwrap(aggregate.profileEffect)
        return try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            messages: aggregate.messages,
            profileEffect: effect,
            profileReconsideration: ProfileReconsideration(
                sourceEffect: effect,
                resultResponsePositionID: try ChatResponsePositionID(
                    "rsp-20260910T120200000Z-7YZA"
                ),
                failure: failure,
                preparedProfileStatementGeneration: preparedGeneration
            )
        )
    }

    private func addingEvidencePublication(
        to aggregate: ChatAggregate,
        attachment: ChatSessionAttachment
    ) throws -> ChatAggregate {
        let instant = try UTCInstant("2026-09-10T12:03:00.000Z")
        let evidence = try EvidenceReference(
            sessionID: attachment.sessionID,
            transcriptRevisionID: attachment.transcriptRevisionID,
            target: .wordRange(
                startWordID: TranscriptWordID("w000001"),
                endWordID: TranscriptWordID("w000002")
            ),
            display: EvidenceReferenceDisplay(
                sessionLabel: "Timeline Session",
                trustedText: "A grounded observation.",
                startMilliseconds: 1_000,
                endMilliseconds: 1_500
            )
        )
        let publication = try ProfileEvidencePublication(
            chatID: aggregate.chat.id,
            responsePositionID: XCTUnwrap(
                aggregate.messages.last?.responsePositionID
            ),
            evidenceAppends: [
                ProfileEvidenceAppend(
                    target: ProfileProposalTarget(
                        statementID: ProfileStatementID(
                            "stm-20260910T120300000Z-9EFG"
                        ),
                        statementKind: .speakingObservation,
                        wording: "Pause briefly between points."
                    ),
                    evidence: [evidence]
                )
            ],
            createdAt: instant
        )
        return try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            messages: aggregate.messages,
            profileEffect: .evidencePublication(publication)
        )
    }

    private func addingProposalForLastResponse(
        to aggregate: ChatAggregate,
        baseGeneration: UInt64
    ) throws -> ChatAggregate {
        let instant = try UTCInstant("2026-09-10T12:04:00.000Z")
        let proposal = try ProfileChangeProposal(
            id: ProfileChangeProposalID(
                "prp-20260910T120400000Z-1GHJ"
            ),
            chatID: aggregate.chat.id,
            responsePositionID: XCTUnwrap(
                aggregate.messages.last?.responsePositionID
            ),
            baseProfile: CoachProfileProvenance(
                revisionID: nil,
                statementGeneration: baseGeneration
            ),
            changes: [
                .add(
                    statement: try ProfileProposedStatement(
                        statementID: ProfileStatementID(
                            "stm-20260910T120400000Z-2KMN"
                        ),
                        statementKind: .goal,
                        wording: "Pause before each key point.",
                        evidence: []
                    )
                )
            ],
            createdAt: instant
        )
        return try ChatAggregate(
            chat: aggregate.chat,
            memory: aggregate.memory,
            messages: aggregate.messages,
            profileEffect: .proposal(proposal)
        )
    }
}
