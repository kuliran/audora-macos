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
                attemptID: fixture.attemptID,
                providerIdempotencyValue: fixture.idempotency,
                library: fixture.library,
                chatID: fixture.aggregate.chat.id,
                pendingUserTurn: anotherPending,
                expectedManifestRevision: fixture.aggregate.chat.manifestRevision,
                admittedAt: fixture.instant
            ).validate(against: fixture.aggregate)
        ) { error in
            XCTAssertEqual(error as? CoachInvocationError, .pendingMismatch)
        }
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
            attemptID: attemptID,
            providerIdempotencyValue: idempotency,
            library: library,
            chatID: aggregate.chat.id,
            pendingUserTurn: pending,
            expectedManifestRevision: aggregate.chat.manifestRevision,
            admittedAt: instant
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
