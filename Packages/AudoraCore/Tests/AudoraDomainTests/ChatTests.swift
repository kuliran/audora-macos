import AudoraDomain
import XCTest

final class ChatTests: XCTestCase {
    func testCapacityFailureReplacementPreservesPendingTurnIdentity() throws {
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120001000Z-5KMN"),
            draftID: try ChatDraftID("drf-20260830T120000000Z-3DEF"),
            draftVersion: 7,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120001000Z-6PQR"
            )
        )

        let failed = pending.replacingFailure(.coachContextCannotFit)
        let retried = failed.replacingFailure(nil)

        XCTAssertEqual(failed.id, pending.id)
        XCTAssertEqual(failed.draftID, pending.draftID)
        XCTAssertEqual(failed.draftVersion, pending.draftVersion)
        XCTAssertEqual(failed.responsePositionID, pending.responsePositionID)
        XCTAssertEqual(failed.failure, .coachContextCannotFit)
        XCTAssertEqual(retried, pending)
    }
    func testTypedChatIdentitiesValidateTheirCompletePortableShape() throws {
        XCTAssertEqual(try ChatID("cht-20260830T120000000Z-2ABC").rawValue,
                       "cht-20260830T120000000Z-2ABC")
        XCTAssertEqual(try ChatDraftID("drf-20260830T120000000Z-3DEF").rawValue,
                       "drf-20260830T120000000Z-3DEF")
        XCTAssertEqual(try CoachMemoryID("mem-20260830T120000000Z-4GHJ").rawValue,
                       "mem-20260830T120000000Z-4GHJ")
        XCTAssertEqual(try SessionID("ses-20260830T120000000Z-5KMN").rawValue,
                       "ses-20260830T120000000Z-5KMN")
        XCTAssertEqual(try TranscriptRevisionID("trv-20260830T120000000Z-6PQR").rawValue,
                       "trv-20260830T120000000Z-6PQR")

        for invalid in [
            "cht-20260230T120000000Z-2ABC",
            "cht-20260830T120000000Z-2AbC",
            "cht-20260830T120000000Z-2AOC",
            "../cht-20260830T120000000Z-2ABC",
            "ses-20260830T120000000Z-2ABC",
        ] {
            XCTAssertThrowsError(try ChatID(invalid), invalid)
        }

        XCTAssertThrowsError(try SessionID("ses-20260230T120000000Z-5KMN")) { error in
            XCTAssertEqual(error as? LibraryIdentityError, .invalidSessionID)
        }
        XCTAssertThrowsError(
            try TranscriptRevisionID("trv-20260830T120000000Z-6PQO")
        ) { error in
            XCTAssertEqual(error as? LibraryIdentityError, .invalidTranscriptRevisionID)
        }
    }

    func testChatTitleNormalizesOnlyEdgesAndRejectsUnsafeOrOversizeText() throws {
        XCTAssertEqual(try ChatTitle("  Focused practice  ").rawValue, "Focused practice")
        XCTAssertEqual(try ChatTitle("two  spaces").rawValue, "two  spaces")
        XCTAssertThrowsError(try ChatTitle(" \n "))
        XCTAssertThrowsError(try ChatTitle("unsafe\u{0000}title"))
        XCTAssertThrowsError(try ChatTitle(String(repeating: "é", count: 129)))
    }

    func testAttachmentAndCreationInvariantsAreEnforced() throws {
        let attachment = try makeAttachment()
        XCTAssertThrowsError(
            try ChatAttachments(
                validating: Array(
                    repeating: attachment,
                    count: ChatAttachments.maximumCount + 1
                )
            )
        ) { error in
            XCTAssertEqual(error as? ChatAttachmentsError, .tooManyAttachments)
        }
        XCTAssertThrowsError(try ChatAttachments(validating: [attachment, attachment]))
        let attachments = try ChatAttachments(validating: [attachment])

        XCTAssertThrowsError(
            try ChatCreation(
                kind: .newChat,
                originAttachmentID: attachment.attachmentID,
                attachments: attachments
            )
        )
        XCTAssertThrowsError(
            try ChatCreation(
                kind: .sessionAnalysis,
                originAttachmentID: nil,
                attachments: attachments
            )
        )
        XCTAssertNoThrow(
            try ChatCreation(
                kind: .sessionAnalysis,
                originAttachmentID: attachment.attachmentID,
                attachments: attachments
            )
        )
    }

    func testChatRevalidatesSessionAnalysisOriginAgainstItsOwnAttachments() throws {
        let attachment = try makeAttachment()
        let creationAttachments = try ChatAttachments(validating: [attachment])
        let creation = try ChatCreation(
            kind: .sessionAnalysis,
            originAttachmentID: attachment.attachmentID,
            attachments: creationAttachments
        )
        let instant = try UTCInstant("2026-08-30T12:00:00.000Z")

        XCTAssertThrowsError(
            try Chat(
                id: ChatID("cht-20260830T120000000Z-2ABC"),
                manifestRevision: 0,
                title: .newChat,
                createdAt: instant,
                updatedAt: instant,
                creation: creation,
                profileStatementGenerationAtCreation: 0,
                attachments: .empty,
                draft: ChatDraft(
                    draftID: ChatDraftID("drf-20260830T120000000Z-3DEF"),
                    version: 0,
                    text: "",
                    updatedAt: instant
                ),
                messageIDs: [],
                currentMemoryID: CoachMemoryID("mem-20260830T120000000Z-4GHJ")
            )
        ) { error in
            XCTAssertEqual(error as? ChatCreationError, .originNotAttached)
        }
    }

    func testCanonicalDevelopmentChatIsEmptyAndUsesStableIndependentIdentities() throws {
        let aggregate = try makeAggregate()

        XCTAssertEqual(aggregate.chat.title, .newChat)
        XCTAssertEqual(aggregate.chat.manifestRevision, 0)
        XCTAssertEqual(aggregate.chat.creation.kind, .newChat)
        XCTAssertNil(aggregate.chat.creation.originAttachmentID)
        XCTAssertEqual(aggregate.chat.attachments, .empty)
        XCTAssertEqual(aggregate.chat.draft.text, "")
        XCTAssertEqual(aggregate.chat.draft.version, 0)
        XCTAssertEqual(aggregate.chat.messageIDs, [])
        XCTAssertEqual(aggregate.chat.currentMemoryID, aggregate.memory.memoryID)
        XCTAssertEqual(aggregate.memory.chatID, aggregate.chat.id)
        XCTAssertEqual(aggregate.memory.generalNotes, "")
        XCTAssertEqual(aggregate.memory.sessionSummaries, [])
    }

    func testRenameChangesOnlyManifestTitleRevisionAndUpdatedInstant() throws {
        let original = try makeAggregate()
        let renamedChat = try original.chat.renamed(
            to: ChatTitle("Speaking goals"),
            at: UTCInstant("2026-08-30T12:01:00.000Z")
        )
        let renamed = try ChatAggregate(chat: renamedChat, memory: original.memory)

        XCTAssertEqual(renamed.chat.id, original.chat.id)
        XCTAssertEqual(renamed.chat.createdAt, original.chat.createdAt)
        XCTAssertEqual(renamed.chat.creation, original.chat.creation)
        XCTAssertEqual(renamed.chat.profileStatementGenerationAtCreation,
                       original.chat.profileStatementGenerationAtCreation)
        XCTAssertEqual(renamed.chat.attachments, original.chat.attachments)
        XCTAssertEqual(renamed.chat.draft, original.chat.draft)
        XCTAssertEqual(renamed.chat.messageIDs, original.chat.messageIDs)
        XCTAssertEqual(renamed.memory, original.memory)
        XCTAssertEqual(renamed.chat.manifestRevision, 1)
        XCTAssertEqual(renamed.chat.title.rawValue, "Speaking goals")
    }

    func testDraftEditsAdvanceMonotonicallyAndPendingTurnLocksTheExactVersion() throws {
        let original = try makeAggregate()
        let firstInstant = try UTCInstant("2026-08-30T12:00:01.000Z")
        let secondInstant = try UTCInstant("2026-08-30T12:00:02.000Z")

        let first = try original.chat.draft.edited(
            text: "Help me make this opening clearer.",
            at: firstInstant
        )
        let second = try first.edited(
            text: "Help me make this opening clearer and shorter.",
            at: secondInstant
        )
        let chat = try original.chat.replacingDraft(with: second)
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120002000Z-5KMN"),
            draftID: second.draftID,
            draftVersion: second.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120002000Z-6PQR"
            )
        )
        let locked = try ChatAggregate(
            chat: chat,
            memory: original.memory,
            pendingUserTurn: pending
        )

        XCTAssertEqual(first.version, 1)
        XCTAssertEqual(second.version, 2)
        XCTAssertEqual(locked.pendingUserTurn?.draftVersion, 2)
        XCTAssertEqual(locked.chat.draft.text,
                       "Help me make this opening clearer and shorter.")
        XCTAssertEqual(locked.chat.messageIDs, [])

        let wrongVersion = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120002000Z-7STV"),
            draftID: second.draftID,
            draftVersion: 1,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120002000Z-8WXY"
            )
        )
        XCTAssertThrowsError(
            try ChatAggregate(
                chat: chat,
                memory: original.memory,
                pendingUserTurn: wrongVersion
            )
        )
    }

    private func makeAggregate() throws -> ChatAggregate {
        try ChatAggregate.emptyDevelopmentChat(
            chatID: ChatID("cht-20260830T120000000Z-2ABC"),
            draftID: ChatDraftID("drf-20260830T120000000Z-3DEF"),
            memoryID: CoachMemoryID("mem-20260830T120000000Z-4GHJ"),
            instant: UTCInstant("2026-08-30T12:00:00.000Z"),
            profileStatementGeneration: 7
        )
    }

    private func makeAttachment() throws -> ChatSessionAttachment {
        ChatSessionAttachment(
            attachmentID: try ChatSessionAttachmentID("attachment_1"),
            sessionID: try SessionID("ses-20260830T110000000Z-5KMN"),
            transcriptRevisionID: try TranscriptRevisionID("trv-20260830T111000000Z-6PQR")
        )
    }
}
