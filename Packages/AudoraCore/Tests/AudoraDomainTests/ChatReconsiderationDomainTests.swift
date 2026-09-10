import AudoraDomain
import XCTest

final class ChatReconsiderationDomainTests: XCTestCase {
    func testAggregateNormalizesLegacyProfileInputsIntoOneEffect() throws {
        let fixture = try makeStaleProposalFixture()

        let aggregate = try ChatAggregate(
            chat: fixture.chat,
            memory: fixture.memory,
            messages: fixture.messages,
            profileProposal: fixture.proposal
        )

        XCTAssertEqual(aggregate.profileEffect, .proposal(fixture.proposal))
        XCTAssertEqual(aggregate.profileProposal, fixture.proposal)
        XCTAssertNil(aggregate.profileEvidencePublication)

        XCTAssertThrowsError(
            try ChatAggregate(
                chat: fixture.chat,
                memory: fixture.memory,
                messages: fixture.messages,
                profileEffect: .proposal(fixture.proposal),
                profileProposal: fixture.proposal
            )
        ) { error in
            XCTAssertEqual(
                error as? ChatAggregateError,
                .multipleProfileEffects
            )
        }
    }

    func testHistoryAcceptsOrderedAnswerPairsAndCoachOnlyReconsiderGroups() throws {
        let fixture = try makeStaleProposalFixture()
        let reconsiderCoach = try coachMessage(
            id: "msg-20260909T101000000Z-1ABC",
            responsePosition: "rsp-20260909T101000000Z-2DEF",
            provenance: fixture.latest.provenance
        )
        let laterUser = try userMessage(
            id: "msg-20260909T101100000Z-3GHJ",
            responsePosition: "rsp-20260909T101100000Z-4KMN"
        )
        let laterCoach = try coachMessage(
            id: "msg-20260909T101100000Z-5PQR",
            responsePosition: laterUser.responsePositionID.rawValue,
            provenance: fixture.latest.provenance
        )
        let messages = fixture.messages + [reconsiderCoach, laterUser, laterCoach]
        let chat = try replacingMessageIDs(
            in: fixture.chat,
            with: messages.map(\.id)
        )

        XCTAssertNoThrow(
            try ChatAggregate(
                chat: chat,
                memory: fixture.memory,
                messages: messages
            )
        )

        let duplicatePositionCoach = try coachMessage(
            id: "msg-20260909T101200000Z-6RST",
            responsePosition: laterUser.responsePositionID.rawValue,
            provenance: fixture.latest.provenance
        )
        let duplicateMessages = messages + [duplicatePositionCoach]
        let duplicateChat = try replacingMessageIDs(
            in: chat,
            with: duplicateMessages.map(\.id)
        )
        XCTAssertThrowsError(
            try ChatAggregate(
                chat: duplicateChat,
                memory: fixture.memory,
                messages: duplicateMessages
            )
        ) { error in
            XCTAssertEqual(error as? ChatAggregateError, .messageHistoryMismatch)
        }

        let orphanUserMessages = fixture.messages + [laterUser]
        let orphanUserChat = try replacingMessageIDs(
            in: fixture.chat,
            with: orphanUserMessages.map(\.id)
        )
        XCTAssertThrowsError(
            try ChatAggregate(
                chat: orphanUserChat,
                memory: fixture.memory,
                messages: orphanUserMessages
            )
        ) { error in
            XCTAssertEqual(error as? ChatAggregateError, .messageHistoryMismatch)
        }
    }

    func testReconsiderationSidecarMustMatchExactEffectAndReserveFreshPosition() throws {
        let fixture = try makeStaleProposalFixture()
        let sourceEffect = ChatProfileEffect.proposal(fixture.proposal)
        let sidecar = ProfileReconsideration(
            sourceEffect: sourceEffect,
            resultResponsePositionID: try ChatResponsePositionID(
                "rsp-20260909T102000000Z-1ABC"
            )
        )

        let aggregate = try ChatAggregate(
            chat: fixture.chat,
            memory: fixture.memory,
            messages: fixture.messages,
            profileEffect: sourceEffect,
            profileReconsideration: sidecar
        )
        XCTAssertEqual(aggregate.profileReconsideration, sidecar)

        let otherIdentity = ProfileReconsideration(
            sourceEffectIdentity: .proposal(
                try ProfileChangeProposalID(
                    "prp-20260909T102100000Z-2DEF"
                )
            ),
            resultResponsePositionID: sidecar.resultResponsePositionID
        )
        XCTAssertThrowsError(
            try ChatAggregate(
                chat: fixture.chat,
                memory: fixture.memory,
                messages: fixture.messages,
                profileEffect: sourceEffect,
                profileReconsideration: otherIdentity
            )
        ) { error in
            XCTAssertEqual(
                error as? ChatAggregateError,
                .reconsiderationSourceMismatch
            )
        }

        let reusedPosition = ProfileReconsideration(
            sourceEffect: sourceEffect,
            resultResponsePositionID: fixture.proposal.responsePositionID
        )
        XCTAssertThrowsError(
            try ChatAggregate(
                chat: fixture.chat,
                memory: fixture.memory,
                messages: fixture.messages,
                profileEffect: sourceEffect,
                profileReconsideration: reusedPosition
            )
        ) { error in
            XCTAssertEqual(
                error as? ChatAggregateError,
                .reconsiderationResponsePositionMismatch
            )
        }
    }

    func testWithdrawalPublishesWithoutFabricatingCoachMessage() throws {
        let fixture = try makeStaleProposalFixture()
        let effect = ChatProfileEffect.proposal(fixture.proposal)
        let sidecar = ProfileReconsideration(
            sourceEffect: effect,
            resultResponsePositionID: try ChatResponsePositionID(
                "rsp-20260909T103000000Z-1ABC"
            )
        )
        let aggregate = try ChatAggregate(
            chat: fixture.chat,
            memory: fixture.memory,
            messages: fixture.messages,
            profileEffect: effect,
            profileReconsideration: sidecar
        )
        let basis = try ProfileReconsiderationBasis(
            sourceEffect: effect,
            baseProfile: ProfileSnapshot(revision: fixture.base),
            latestProfile: ProfileSnapshot(revision: fixture.latest)
        )

        let published = try aggregate.publishingReconsideration(
            expected: sidecar,
            basis: basis,
            preparedProfile: fixture.latest.provenance,
            coachMessage: nil,
            replacementMemory: nil,
            outcome: .withdrawal,
            at: laterInstant
        )

        XCTAssertEqual(
            published.chat.manifestRevision,
            aggregate.chat.manifestRevision + 1
        )
        XCTAssertEqual(published.chat.messageIDs, aggregate.chat.messageIDs)
        XCTAssertEqual(published.messages, aggregate.messages)
        XCTAssertEqual(published.chat.draft, aggregate.chat.draft)
        XCTAssertEqual(published.memory, aggregate.memory)
        XCTAssertNil(published.profileEffect)
        XCTAssertNil(published.profileReconsideration)
    }

    func testReconsideredEvidenceOnlyReplacementRetainsActiveAppendAndCoachOnlyMessage() throws {
        let fixture = try makeMixedProposalFixture()
        let effect = ChatProfileEffect.proposal(fixture.proposal)
        let sidecar = ProfileReconsideration(
            sourceEffect: effect,
            resultResponsePositionID: try ChatResponsePositionID(
                "rsp-20260909T104000000Z-1ABC"
            )
        )
        let aggregate = try ChatAggregate(
            chat: fixture.chat,
            memory: fixture.memory,
            messages: fixture.messages,
            profileEffect: effect,
            profileReconsideration: sidecar
        )
        let basis = try ProfileReconsiderationBasis(
            sourceEffect: effect,
            baseProfile: ProfileSnapshot(revision: fixture.base),
            latestProfile: ProfileSnapshot(revision: fixture.latest)
        )
        let replacement = try ProfileChangeProposal.reconsidered(
            id: ProfileChangeProposalID("prp-20260909T104100000Z-2DEF"),
            basis: basis,
            responsePositionID: sidecar.resultResponsePositionID,
            changes: [],
            evidenceAppends: [],
            createdAt: laterInstant
        )
        let coach = try coachMessage(
            id: "msg-20260909T104200000Z-3GHJ",
            responsePosition: sidecar.resultResponsePositionID.rawValue,
            provenance: fixture.latest.provenance
        )

        let published = try aggregate.publishingReconsideration(
            expected: sidecar,
            basis: basis,
            preparedProfile: fixture.latest.provenance,
            coachMessage: coach,
            replacementMemory: nil,
            outcome: .replacement(replacement),
            at: laterInstant
        )

        XCTAssertEqual(published.chat.messageIDs.last, coach.id)
        XCTAssertEqual(published.messages.last, coach)
        XCTAssertEqual(published.profileProposal, replacement)
        XCTAssertEqual(
            published.profileProposal?.evidenceAppends,
            basis.retainedActiveEvidenceAppends
        )
        XCTAssertNil(published.profileEvidencePublication)
        XCTAssertNil(published.profileReconsideration)

        XCTAssertThrowsError(
            try aggregate.publishingReconsideration(
                expected: sidecar,
                basis: basis,
                preparedProfile: fixture.latest.provenance,
                coachMessage: nil,
                replacementMemory: nil,
                outcome: .withdrawal,
                at: laterInstant
            )
        ) { error in
            XCTAssertEqual(
                error as? ProfileReconsiderationPublicationError,
                .retainedEvidenceRequiresReplacement
            )
        }
    }

    func testMessageFreeReviewedReplacementPublishesWithoutFabricatedHistory() throws {
        let fixture = try makeStaleProposalFixture()
        let effect = ChatProfileEffect.proposal(fixture.proposal)
        let sidecar = ProfileReconsideration(
            sourceEffect: effect,
            resultResponsePositionID: try ChatResponsePositionID(
                "rsp-20260909T104500000Z-1ABC"
            )
        )
        let aggregate = try ChatAggregate(
            chat: fixture.chat,
            memory: fixture.memory,
            messages: fixture.messages,
            profileEffect: effect,
            profileReconsideration: sidecar
        )
        let basis = try ProfileReconsiderationBasis(
            sourceEffect: effect,
            baseProfile: ProfileSnapshot(revision: fixture.base),
            latestProfile: ProfileSnapshot(revision: fixture.latest)
        )
        let replacement = try ProfileChangeProposal.reconsidered(
            id: ProfileChangeProposalID("prp-20260909T104600000Z-2DEF"),
            basis: basis,
            responsePositionID: sidecar.resultResponsePositionID,
            changes: [
                .add(
                    statement: ProfileProposedStatement(
                        statementID: ProfileStatementID(
                            "stm-20260909T104600000Z-3GHJ"
                        ),
                        statementKind: .goal,
                        wording: "Speak with a deliberate pace.",
                        evidence: []
                    )
                ),
            ],
            createdAt: laterInstant
        )

        let published = try aggregate.publishingReconsideration(
            expected: sidecar,
            basis: basis,
            preparedProfile: fixture.latest.provenance,
            coachMessage: nil,
            replacementMemory: nil,
            outcome: .replacement(replacement),
            at: laterInstant
        )

        XCTAssertEqual(published.messages, aggregate.messages)
        XCTAssertEqual(published.chat.messageIDs, aggregate.chat.messageIDs)
        XCTAssertEqual(published.profileProposal, replacement)
        XCTAssertNil(published.profileReconsideration)
    }

    func testDiscardFailureRemovesOnlySidecar() throws {
        let fixture = try makeStaleProposalFixture()
        let effect = ChatProfileEffect.proposal(fixture.proposal)
        let sidecar = ProfileReconsideration(
            sourceEffect: effect,
            resultResponsePositionID: try ChatResponsePositionID(
                "rsp-20260909T105000000Z-1ABC"
            ),
            failure: .coachResponseInvalid
        )
        let aggregate = try ChatAggregate(
            chat: fixture.chat,
            memory: fixture.memory,
            messages: fixture.messages,
            profileEffect: effect,
            profileReconsideration: sidecar
        )

        let restored = try aggregate.discardingReconsiderationFailure(
            expected: sidecar,
            at: laterInstant
        )

        XCTAssertEqual(restored.profileEffect, effect)
        XCTAssertNil(restored.profileReconsideration)
        XCTAssertEqual(restored.messages, aggregate.messages)
        XCTAssertEqual(restored.memory, aggregate.memory)
        XCTAssertEqual(
            restored.chat.manifestRevision,
            aggregate.chat.manifestRevision + 1
        )
    }

    func testReconsiderInvocationPreservesExactIntentAcrossAttemptsAndFailure() throws {
        let fixture = try makeStaleProposalFixture()
        let sourceEffect = ChatProfileEffect.proposal(fixture.proposal)
        let sidecar = ProfileReconsideration(
            sourceEffect: sourceEffect,
            resultResponsePositionID: try ChatResponsePositionID(
                "rsp-20260909T105500000Z-2DEF"
            )
        )
        let aggregate = try ChatAggregate(
            chat: fixture.chat,
            memory: fixture.memory,
            messages: fixture.messages,
            profileEffect: sourceEffect,
            profileReconsideration: sidecar
        )
        let firstAttempt = try reconsiderAttempt(
            id: "atm-20260909T105500000Z-3GHJ",
            ordinal: 1,
            coachMessageID: "msg-20260909T105500000Z-4KMN"
        )
        let invocation = try CoachInvocation(
            id: CoachInvocationID("inv-20260909T105500000Z-5PQR"),
            attempt: firstAttempt,
            library: LibraryScope(
                libraryID: try LibraryID("lib-20260909T105500000Z-6RST")
            ),
            chatID: fixture.chat.id,
            profileReconsideration: sidecar,
            preparedProfile: fixture.latest.provenance,
            expectedManifestRevision: fixture.chat.manifestRevision,
            admittedAt: laterInstant
        )

        XCTAssertEqual(invocation.persistedSchemaVersion, 5)
        XCTAssertEqual(
            invocation.intent,
            .reconsiderProfileChange(
                sourceEffectIdentity: sourceEffect.identity,
                resultResponsePositionID: sidecar.resultResponsePositionID
            )
        )
        XCTAssertEqual(
            invocation.attempt.publicationAuthority,
            .reconsiderProfileChange(
                coachMessageID: try ChatMessageID(
                    "msg-20260909T105500000Z-4KMN"
                )
            )
        )
        XCTAssertNoThrow(try invocation.validate(against: aggregate))

        let next = try reconsiderAttempt(
            id: "atm-20260909T105600000Z-7VWX",
            ordinal: 2,
            coachMessageID: "msg-20260909T105600000Z-8XYZ"
        )
        let retried = try invocation.installingAttempt(next)
        XCTAssertEqual(retried.intent, invocation.intent)
        XCTAssertEqual(try retried.durableProjection().intent, invocation.intent)
        XCTAssertEqual(
            try retried.recordingTerminalFailure(.coachProviderError).intent,
            invocation.intent
        )

        let answerAuthority = try CoachProviderAttemptPublicationAuthority(
            userMessageID: ChatMessageID("msg-20260909T105700000Z-9ABC"),
            coachMessageID: ChatMessageID("msg-20260909T105700000Z-0DEF"),
            freshDraftID: ChatDraftID("drf-20260909T105700000Z-1GHJ")
        )
        let wrongAttempt = try CoachProviderAttempt(
            id: CoachProviderAttemptID("atm-20260909T105700000Z-2KMN"),
            ordinal: 1,
            kind: .standard,
            providerIdempotencyValue: ProviderIdempotencyValue("wrong-kind"),
            transcriptHandles: [],
            publicationAuthority: answerAuthority
        )
        XCTAssertThrowsError(
            try CoachInvocation(
                id: CoachInvocationID("inv-20260909T105700000Z-3PQR"),
                attempt: wrongAttempt,
                library: LibraryScope(
                    libraryID: try LibraryID("lib-20260909T105500000Z-6RST")
                ),
                chatID: fixture.chat.id,
                profileReconsideration: sidecar,
                preparedProfile: fixture.latest.provenance,
                expectedManifestRevision: fixture.chat.manifestRevision,
                admittedAt: laterInstant
            )
        ) { error in
            XCTAssertEqual(
                error as? CoachInvocationError,
                .publicationAuthorityIntentMismatch
            )
        }
    }

    private var laterInstant: UTCInstant {
        try! UTCInstant("2026-09-09T11:00:00.000Z")
    }

    private func makeStaleProposalFixture() throws -> ReconsiderFixture {
        let target = try statement(
            id: "stm-20260909T090000000Z-1ABC",
            wording: "Pause between ideas."
        )
        let base = try revision(
            id: "prf-20260909T090100000Z-2DEF",
            generation: 3,
            statementGeneration: 2,
            statements: [target]
        )
        let latest = try revision(
            id: "prf-20260909T090200000Z-3GHJ",
            parent: base.revisionID,
            generation: 4,
            statementGeneration: 3,
            statements: []
        )
        let responsePosition = try ChatResponsePositionID(
            "rsp-20260909T090300000Z-4KMN"
        )
        let proposal = try ProfileChangeProposal(
            id: ProfileChangeProposalID("prp-20260909T090300000Z-5PQR"),
            chatID: ChatID("cht-20260909T090000000Z-6RST"),
            responsePositionID: responsePosition,
            baseProfile: base.provenance,
            changes: [
                .retire(
                    target: ProfileProposalTarget(statement: target),
                    evidence: []
                ),
            ],
            createdAt: laterInstant
        )
        return try fixture(
            chatID: proposal.chatID,
            responsePosition: responsePosition,
            coachProvenance: base.provenance,
            proposal: proposal,
            base: base,
            latest: latest,
            attachments: .empty
        )
    }

    private func makeMixedProposalFixture() throws -> ReconsiderFixture {
        let attachment = ChatSessionAttachment(
            attachmentID: try ChatSessionAttachmentID("attachment_1"),
            sessionID: try SessionID("ses-20260909T091000000Z-1ABC"),
            transcriptRevisionID: try TranscriptRevisionID(
                "trv-20260909T091100000Z-2DEF"
            )
        )
        let retiredTarget = try statement(
            id: "stm-20260909T091200000Z-3GHJ",
            wording: "Use a detailed outline."
        )
        let activeTarget = try statement(
            id: "stm-20260909T091300000Z-4KMN",
            wording: "Pause between ideas."
        )
        let base = try revision(
            id: "prf-20260909T091400000Z-5PQR",
            generation: 7,
            statementGeneration: 5,
            statements: [retiredTarget, activeTarget]
        )
        let latest = try revision(
            id: "prf-20260909T091500000Z-6RST",
            parent: base.revisionID,
            generation: 8,
            statementGeneration: 6,
            statements: [activeTarget]
        )
        let evidence = try EvidenceReference(
            sessionID: attachment.sessionID,
            transcriptRevisionID: attachment.transcriptRevisionID,
            target: .wordRange(
                startWordID: TranscriptWordID("w000001"),
                endWordID: TranscriptWordID("w000001")
            ),
            display: EvidenceReferenceDisplay(
                sessionLabel: "Practice Session",
                trustedText: "A grounded observation.",
                startMilliseconds: 100,
                endMilliseconds: 200
            )
        )
        let responsePosition = try ChatResponsePositionID(
            "rsp-20260909T091600000Z-7VWX"
        )
        let proposal = try ProfileChangeProposal(
            id: ProfileChangeProposalID("prp-20260909T091600000Z-8XYZ"),
            chatID: ChatID("cht-20260909T091000000Z-9ABC"),
            responsePositionID: responsePosition,
            baseProfile: base.provenance,
            changes: [
                .retire(
                    target: ProfileProposalTarget(statement: retiredTarget),
                    evidence: []
                ),
            ],
            evidenceAppends: [
                ProfileEvidenceAppend(
                    target: ProfileProposalTarget(statement: activeTarget),
                    evidence: [evidence]
                ),
            ],
            createdAt: laterInstant
        )
        return try fixture(
            chatID: proposal.chatID,
            responsePosition: responsePosition,
            coachProvenance: base.provenance,
            proposal: proposal,
            base: base,
            latest: latest,
            attachments: ChatAttachments(validating: [attachment])
        )
    }

    private func fixture(
        chatID: ChatID,
        responsePosition: ChatResponsePositionID,
        coachProvenance: CoachProfileProvenance,
        proposal: ProfileChangeProposal,
        base: ProfileRevision,
        latest: ProfileRevision,
        attachments: ChatAttachments
    ) throws -> ReconsiderFixture {
        let user = try userMessage(
            id: "msg-20260909T092000000Z-1ABC",
            responsePosition: responsePosition.rawValue
        )
        let coach = try coachMessage(
            id: "msg-20260909T092000000Z-2DEF",
            responsePosition: responsePosition.rawValue,
            provenance: coachProvenance
        )
        let draft = try ChatDraft(
            draftID: ChatDraftID("drf-20260909T092000000Z-3GHJ"),
            version: 0,
            text: "",
            updatedAt: laterInstant
        )
        let memoryID = try CoachMemoryID("mem-20260909T092000000Z-4KMN")
        let chat = try Chat(
            id: chatID,
            manifestRevision: 9,
            title: .newChat,
            createdAt: laterInstant,
            updatedAt: laterInstant,
            creation: ChatCreation(
                kind: .newChat,
                originAttachmentID: nil,
                attachments: attachments
            ),
            profileStatementGenerationAtCreation: 0,
            attachments: attachments,
            draft: draft,
            messageIDs: [user.id, coach.id],
            currentMemoryID: memoryID
        )
        let memory = try CoachMemory(
            memoryID: memoryID,
            chatID: chatID,
            generalNotes: "",
            sessionSummaries: [],
            attachments: attachments
        )
        return ReconsiderFixture(
            chat: chat,
            memory: memory,
            messages: [user, coach],
            proposal: proposal,
            base: base,
            latest: latest
        )
    }

    private func userMessage(
        id: String,
        responsePosition: String
    ) throws -> ChatMessage {
        try ChatMessage(
            id: ChatMessageID(id),
            responsePositionID: ChatResponsePositionID(responsePosition),
            content: .user(text: "Help me improve this."),
            createdAt: laterInstant
        )
    }

    private func coachMessage(
        id: String,
        responsePosition: String,
        provenance: CoachProfileProvenance
    ) throws -> ChatMessage {
        try ChatMessage(
            id: ChatMessageID(id),
            responsePositionID: ChatResponsePositionID(responsePosition),
            content: .coach(markdown: "Try pausing between complete ideas."),
            coachProfile: provenance,
            createdAt: laterInstant
        )
    }

    private func reconsiderAttempt(
        id: String,
        ordinal: UInt8,
        coachMessageID: String
    ) throws -> CoachProviderAttempt {
        try CoachProviderAttempt(
            id: CoachProviderAttemptID(id),
            ordinal: ordinal,
            kind: .standard,
            providerIdempotencyValue: ProviderIdempotencyValue(
                "reconsider-\(ordinal)"
            ),
            transcriptHandles: [],
            publicationAuthority: .reconsiderProfileChange(
                coachMessageID: ChatMessageID(coachMessageID)
            )
        )
    }

    private func replacingMessageIDs(
        in chat: Chat,
        with messageIDs: [ChatMessageID]
    ) throws -> Chat {
        try Chat(
            id: chat.id,
            manifestRevision: chat.manifestRevision,
            title: chat.title,
            createdAt: chat.createdAt,
            updatedAt: chat.updatedAt,
            creation: chat.creation,
            profileStatementGenerationAtCreation:
                chat.profileStatementGenerationAtCreation,
            attachments: chat.attachments,
            draft: chat.draft,
            messageIDs: messageIDs,
            currentMemoryID: chat.currentMemoryID
        )
    }

    private func revision(
        id: String,
        parent: ProfileRevisionID? = nil,
        generation: UInt64,
        statementGeneration: UInt64,
        statements: [ProfileStatement]
    ) throws -> ProfileRevision {
        try ProfileRevision(
            revisionID: ProfileRevisionID(id),
            parentRevisionID: parent,
            generation: generation,
            statementGeneration: statementGeneration,
            createdAt: laterInstant,
            statements: statements
        )
    }

    private func statement(
        id: String,
        wording: String
    ) throws -> ProfileStatement {
        try ProfileStatement(
            statementID: ProfileStatementID(id),
            statementKind: .goal,
            wording: wording,
            supportingSessionCount: 0,
            evidence: []
        )
    }
}

private struct ReconsiderFixture {
    let chat: Chat
    let memory: CoachMemory
    let messages: [ChatMessage]
    let proposal: ProfileChangeProposal
    let base: ProfileRevision
    let latest: ProfileRevision
}

private extension ProfileRevision {
    var provenance: CoachProfileProvenance {
        CoachProfileProvenance(
            revisionID: revisionID,
            statementGeneration: statementGeneration
        )
    }
}
