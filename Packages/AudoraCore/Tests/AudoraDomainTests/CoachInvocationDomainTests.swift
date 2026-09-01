import AudoraDomain
import XCTest

final class CoachInvocationDomainTests: XCTestCase {
    func testInvocationAndMessagesPublishOneCompleteTurnAndFreshDraft() throws {
        let fixture = try Fixture()
        let invocation = try fixture.invocation()
        let user = try ChatMessage(
            id: fixture.userMessageID,
            responsePositionID: fixture.pending.responsePositionID,
            content: .user(text: fixture.aggregate.chat.draft.text),
            createdAt: fixture.instant
        )
        let coach = try ChatMessage(
            id: fixture.coachMessageID,
            responsePositionID: fixture.pending.responsePositionID,
            content: .coach(markdown: "A concise **synthetic** answer."),
            coachProfile: fixture.profile,
            createdAt: fixture.instant
        )
        let freshDraft = try ChatDraft(
            draftID: fixture.freshDraftID,
            version: 0,
            text: "",
            updatedAt: fixture.instant
        )

        let published = try fixture.aggregate.publishingTurn(
            invocation: invocation,
            userMessage: user,
            coachMessage: coach,
            freshDraft: freshDraft,
            at: fixture.instant
        )

        XCTAssertEqual(
            published.chat.messageIDs,
            [fixture.userMessageID, fixture.coachMessageID]
        )
        XCTAssertEqual(published.chat.draft, freshDraft)
        XCTAssertEqual(
            published.chat.manifestRevision,
            fixture.aggregate.chat.manifestRevision + 1
        )
        XCTAssertNil(published.pendingUserTurn)
        XCTAssertEqual(published.memory, fixture.aggregate.memory)
    }

    func testPublicationRejectsStaleResponsePositionAndWrongUserText() throws {
        let fixture = try Fixture()
        let invocation = try fixture.invocation()
        let staleResponse = try ChatResponsePositionID("rsp-20260830T120000000Z-9XYZ")
        let staleUser = try ChatMessage(
            id: fixture.userMessageID,
            responsePositionID: staleResponse,
            content: .user(text: fixture.aggregate.chat.draft.text),
            createdAt: fixture.instant
        )
        let coach = try ChatMessage(
            id: fixture.coachMessageID,
            responsePositionID: fixture.pending.responsePositionID,
            content: .coach(markdown: "Synthetic answer"),
            coachProfile: fixture.profile,
            createdAt: fixture.instant
        )
        let freshDraft = try fixture.freshDraft()

        XCTAssertThrowsError(
            try fixture.aggregate.publishingTurn(
                invocation: invocation,
                userMessage: staleUser,
                coachMessage: coach,
                freshDraft: freshDraft,
                at: fixture.instant
            )
        ) { error in
            XCTAssertEqual(error as? InvocationPublicationError, .responsePositionMismatch)
        }

        let wrongUser = try ChatMessage(
            id: fixture.userMessageID,
            responsePositionID: fixture.pending.responsePositionID,
            content: .user(text: "Different text"),
            createdAt: fixture.instant
        )
        XCTAssertThrowsError(
            try fixture.aggregate.publishingTurn(
                invocation: invocation,
                userMessage: wrongUser,
                coachMessage: coach,
                freshDraft: freshDraft,
                at: fixture.instant
            )
        ) { error in
            XCTAssertEqual(error as? InvocationPublicationError, .userTextMismatch)
        }
    }

    func testOperationalValuesAreBoundedAndInvocationIsFencedToPending() throws {
        let fixture = try Fixture()

        XCTAssertThrowsError(try ProviderIdempotencyValue(""))
        XCTAssertThrowsError(
            try ProviderIdempotencyValue(String(repeating: "x", count: 129))
        )
        XCTAssertThrowsError(
            try ChatMessage(
                id: fixture.coachMessageID,
                responsePositionID: fixture.pending.responsePositionID,
                content: .coach(markdown: String(repeating: "x", count: 65_537)),
                coachProfile: fixture.profile,
                createdAt: fixture.instant
            )
        ) { error in
            XCTAssertEqual(error as? ChatMessageError, .contentTooLong)
        }

        let anotherPending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120000000Z-8WXY"),
            draftID: fixture.pending.draftID,
            draftVersion: fixture.pending.draftVersion,
            responsePositionID: fixture.pending.responsePositionID
        )
        XCTAssertThrowsError(
            try CoachInvocation(
                id: fixture.invocationID,
                attempt: fixture.attempt(),
                library: fixture.library,
                chatID: fixture.aggregate.chat.id,
                pendingUserTurn: anotherPending,
                preparedProfile: fixture.profile,
                expectedManifestRevision: fixture.aggregate.chat.manifestRevision,
                admittedAt: fixture.instant
            ).validate(against: fixture.aggregate)
        ) { error in
            XCTAssertEqual(error as? CoachInvocationError, .pendingMismatch)
        }
    }

    func testInvocationIntentAuthoritySurvivesUnrelatedManifestRename() throws {
        let fixture = try Fixture()
        let invocation = try fixture.invocation()
        let renamed = try ChatAggregate(
            chat: fixture.aggregate.chat.renamed(
                to: ChatTitle("Renamed While Coach Runs"),
                at: try UTCInstant("2026-08-30T12:00:01.000Z")
            ),
            memory: fixture.aggregate.memory,
            pendingUserTurn: fixture.pending
        )

        XCTAssertNoThrow(try invocation.validateIntent(against: renamed))
        XCTAssertThrowsError(try invocation.validate(against: renamed)) { error in
            XCTAssertEqual(
                error as? CoachInvocationError,
                .manifestRevisionMismatch
            )
        }
    }

    func testPersistedUserMessageUsesIndependentUTF8SendLimit() throws {
        let fixture = try Fixture()
        let exactBoundary = String(repeating: "é", count: 8_192)

        XCTAssertNoThrow(
            try ChatMessage(
                id: fixture.userMessageID,
                responsePositionID: fixture.pending.responsePositionID,
                content: .user(text: exactBoundary),
                createdAt: fixture.instant
            )
        )
        XCTAssertThrowsError(
            try ChatMessage(
                id: fixture.userMessageID,
                responsePositionID: fixture.pending.responsePositionID,
                content: .user(text: exactBoundary + "é"),
                createdAt: fixture.instant
            )
        ) { error in
            XCTAssertEqual(error as? ChatMessageError, .contentTooLong)
        }
    }

    func testLegacyV1UserMessageRetainsOriginalDraftSizedTextCompatibility() throws {
        let fixture = try Fixture()
        let legacyText = String(repeating: "é", count: 8_193)

        XCTAssertNoThrow(
            try ChatMessage(
                schemaVersion: 1,
                id: fixture.userMessageID,
                responsePositionID: fixture.pending.responsePositionID,
                content: .user(text: legacyText),
                createdAt: fixture.instant
            )
        )
        XCTAssertThrowsError(
            try ChatMessage(
                id: fixture.userMessageID,
                responsePositionID: fixture.pending.responsePositionID,
                content: .user(text: legacyText),
                createdAt: fixture.instant
            )
        ) { error in
            XCTAssertEqual(error as? ChatMessageError, .contentTooLong)
        }
    }

    func testPublicationRequiresExactPreparedProfileProvenance() throws {
        let fixture = try Fixture()
        let invocation = try fixture.invocation()
        let user = try ChatMessage(
            id: fixture.userMessageID,
            responsePositionID: fixture.pending.responsePositionID,
            content: .user(text: fixture.aggregate.chat.draft.text),
            createdAt: fixture.instant
        )
        let staleCoach = try ChatMessage(
            id: fixture.coachMessageID,
            responsePositionID: fixture.pending.responsePositionID,
            content: .coach(markdown: "Synthetic answer"),
            coachProfile: CoachProfileProvenance(
                revisionID: fixture.profile.revisionID,
                statementGeneration: fixture.profile.statementGeneration + 1
            ),
            createdAt: fixture.instant
        )

        XCTAssertThrowsError(
            try fixture.aggregate.publishingTurn(
                invocation: invocation,
                userMessage: user,
                coachMessage: staleCoach,
                freshDraft: fixture.freshDraft(),
                at: fixture.instant
            )
        ) { error in
            XCTAssertEqual(
                error as? InvocationPublicationError,
                .coachProfileProvenanceMismatch
            )
        }
    }

    func testTerminalIntentForbidsAnotherAttemptAndPublication() throws {
        let fixture = try Fixture()
        let terminal = try fixture.invocation().recordingTerminalFailure(
            .coachProviderError
        )
        let nextAttempt = try CoachProviderAttempt(
            id: CoachProviderAttemptID("atm-20260830T120001000Z-7RST"),
            ordinal: 2,
            kind: .standard,
            providerIdempotencyValue: ProviderIdempotencyValue("synthetic-next-7RST"),
            transcriptHandles: [],
            publicationAuthority: CoachProviderAttemptPublicationAuthority(
                userMessageID: ChatMessageID("msg-20260830T120001000Z-8VWX"),
                coachMessageID: ChatMessageID("msg-20260830T120001000Z-9YZ0"),
                freshDraftID: ChatDraftID("drf-20260830T120001000Z-0ABC")
            )
        )

        XCTAssertThrowsError(try terminal.installingAttempt(nextAttempt))

        let user = try ChatMessage(
            id: fixture.userMessageID,
            responsePositionID: fixture.pending.responsePositionID,
            content: .user(text: fixture.aggregate.chat.draft.text),
            createdAt: fixture.instant
        )
        let coach = try ChatMessage(
            id: fixture.coachMessageID,
            responsePositionID: fixture.pending.responsePositionID,
            content: .coach(markdown: "Synthetic answer"),
            coachProfile: fixture.profile,
            createdAt: fixture.instant
        )
        XCTAssertThrowsError(
            try fixture.aggregate.publishingTurn(
                invocation: terminal,
                userMessage: user,
                coachMessage: coach,
                freshDraft: fixture.freshDraft(),
                at: fixture.instant
            )
        )
    }
}

private struct Fixture {
    let instant = try! UTCInstant("2026-08-30T12:00:00.000Z")
    let aggregate: ChatAggregate
    let pending: PendingUserTurn
    let library = LibraryScope(
        libraryID: try! LibraryID("lib-20260830T115900000Z-1ABC")
    )
    let invocationID = try! CoachInvocationID("inv-20260830T120000000Z-5KMN")
    let attemptID = try! CoachProviderAttemptID("atm-20260830T120000000Z-6NPQ")
    let userMessageID = try! ChatMessageID("msg-20260830T120000000Z-7RST")
    let coachMessageID = try! ChatMessageID("msg-20260830T120000000Z-8VWX")
    let freshDraftID = try! ChatDraftID("drf-20260830T120000000Z-9YZ0")
    let idempotency = try! ProviderIdempotencyValue("synthetic-attempt-6NPQ")
    let profile = CoachProfileProvenance(
        revisionID: try! ProfileRevisionID("prf-20260830T115900000Z-4GHJ"),
        statementGeneration: 9
    )

    init() throws {
        let empty = try ChatAggregate.emptyDevelopmentChat(
            chatID: ChatID("cht-20260830T120000000Z-1ABC"),
            draftID: ChatDraftID("drf-20260830T120000000Z-2DEF"),
            memoryID: CoachMemoryID("mem-20260830T120000000Z-3GHJ"),
            instant: instant,
            profileStatementGeneration: 7
        )
        let draft = try empty.chat.draft.edited(text: "Keep this exact user text", at: instant)
        let unlocked = try ChatAggregate(
            chat: empty.chat.replacingDraft(with: draft),
            memory: empty.memory
        )
        pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120000000Z-4JKM"),
            draftID: draft.draftID,
            draftVersion: draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120000000Z-5MNP"
            )
        )
        aggregate = try ChatAggregate(
            chat: unlocked.chat,
            memory: unlocked.memory,
            pendingUserTurn: pending
        )
    }

    func invocation() throws -> CoachInvocation {
        try CoachInvocation(
            id: invocationID,
            attempt: attempt(),
            library: library,
            chatID: aggregate.chat.id,
            pendingUserTurn: pending,
            preparedProfile: profile,
            expectedManifestRevision: aggregate.chat.manifestRevision,
            admittedAt: instant
        )
    }

    func attempt() throws -> CoachProviderAttempt {
        try CoachProviderAttempt(
            id: attemptID,
            ordinal: 1,
            kind: .standard,
            providerIdempotencyValue: idempotency,
            transcriptHandles: [],
            publicationAuthority: CoachProviderAttemptPublicationAuthority(
                userMessageID: userMessageID,
                coachMessageID: coachMessageID,
                freshDraftID: freshDraftID
            )
        )
    }

    func freshDraft() throws -> ChatDraft {
        try ChatDraft(
            draftID: freshDraftID,
            version: 0,
            text: "",
            updatedAt: instant
        )
    }
}
