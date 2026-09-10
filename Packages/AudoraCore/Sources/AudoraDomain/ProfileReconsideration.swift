public enum ProfileReconsiderationPublicationOutcome: Equatable, Sendable {
    case replacement(ProfileChangeProposal)
    case withdrawal
}

public enum ProfileReconsiderationPublicationError: Error, Equatable, Sendable {
    case sidecarMismatch
    case failedSidecarCannotPublish
    case sourceBasisMismatch
    case preparedProfileMismatch
    case coachMessageRequiredRole
    case coachMessageResponsePositionMismatch
    case coachMessageProfileMismatch
    case duplicateMessageID
    case replacementProposalMismatch
    case replacementDropsRetainedEvidence
    case retainedEvidenceRequiresReplacement
    case replacementMemoryOwnerMismatch
    case replacementMemoryIdentityReused
    case replacementMemoryContentUnchanged
    case replacementMemoryAttachmentMismatch
    case manifestRevisionOverflow
    case failureRequired
}

public extension ChatAggregate {
    /// Publishes the complete local result of one Reconsider Invocation. A
    /// result may contain one coach-only history message, a Memory replacement,
    /// and one reviewed replacement Proposal. Withdrawal deliberately accepts
    /// no fabricated message and still advances the Chat manifest when removing
    /// the stale source effect and its sidecar.
    func publishingReconsideration(
        expected: ProfileReconsideration,
        basis: ProfileReconsiderationBasis,
        preparedProfile: CoachProfileProvenance,
        coachMessage: ChatMessage?,
        replacementMemory: CoachMemory? = nil,
        outcome: ProfileReconsiderationPublicationOutcome,
        at instant: UTCInstant
    ) throws -> ChatAggregate {
        guard profileReconsideration == expected else {
            throw ProfileReconsiderationPublicationError.sidecarMismatch
        }
        guard expected.failure == nil else {
            throw ProfileReconsiderationPublicationError
                .failedSidecarCannotPublish
        }
        guard profileEffect == basis.sourceEffect,
              expected.sourceEffectIdentity == basis.sourceEffect.identity
        else {
            throw ProfileReconsiderationPublicationError.sourceBasisMismatch
        }
        guard basis.latestProfile.provenance == preparedProfile else {
            throw ProfileReconsiderationPublicationError.preparedProfileMismatch
        }

        if let coachMessage {
            guard case .coach = coachMessage.content else {
                throw ProfileReconsiderationPublicationError
                    .coachMessageRequiredRole
            }
            guard coachMessage.responsePositionID ==
                    expected.resultResponsePositionID
            else {
                throw ProfileReconsiderationPublicationError
                    .coachMessageResponsePositionMismatch
            }
            guard coachMessage.persistedSchemaVersion ==
                    ChatMessage.schemaVersion,
                  coachMessage.coachProfile == preparedProfile
            else {
                throw ProfileReconsiderationPublicationError
                    .coachMessageProfileMismatch
            }
            guard !chat.messageIDs.contains(coachMessage.id) else {
                throw ProfileReconsiderationPublicationError.duplicateMessageID
            }
        }

        let replacementEffect: ChatProfileEffect?
        switch outcome {
        case let .replacement(proposal):
            guard proposal.chatID == chat.id,
                  proposal.responsePositionID ==
                    expected.resultResponsePositionID,
                  proposal.baseProfile == preparedProfile
            else {
                throw ProfileReconsiderationPublicationError
                    .replacementProposalMismatch
            }
            guard Self.replacement(
                proposal,
                contains: basis.retainedActiveEvidenceAppends
            ) else {
                throw ProfileReconsiderationPublicationError
                    .replacementDropsRetainedEvidence
            }
            replacementEffect = .proposal(proposal)

        case .withdrawal:
            guard basis.retainedActiveEvidenceAppends.isEmpty else {
                throw ProfileReconsiderationPublicationError
                    .retainedEvidenceRequiresReplacement
            }
            replacementEffect = nil
        }

        try Self.validateReconsiderationMemory(
            replacementMemory,
            current: memory,
            chat: chat
        )
        let (revision, overflow) = chat.manifestRevision.addingReportingOverflow(1)
        guard !overflow else {
            throw ProfileReconsiderationPublicationError
                .manifestRevisionOverflow
        }

        let replacementChat = try Chat(
            id: chat.id,
            manifestRevision: revision,
            title: chat.title,
            createdAt: chat.createdAt,
            updatedAt: instant,
            creation: chat.creation,
            profileStatementGenerationAtCreation:
                chat.profileStatementGenerationAtCreation,
            attachments: chat.attachments,
            draft: chat.draft,
            messageIDs: chat.messageIDs + (coachMessage.map { [$0.id] } ?? []),
            currentMemoryID: replacementMemory?.memoryID ??
                chat.currentMemoryID
        )
        let replacementMessages: [ChatMessage]
        if let coachMessage {
            replacementMessages = messages.isEmpty && !chat.messageIDs.isEmpty
                ? []
                : messages + [coachMessage]
        } else {
            replacementMessages = messages
        }
        return try ChatAggregate(
            chat: replacementChat,
            memory: replacementMemory ?? memory,
            messages: replacementMessages,
            profileEffect: replacementEffect
        )
    }

    /// Discarding a failed Reconsider attempt restores the unchanged stale
    /// source effect and its ordinary Reconsider/Discard actions.
    func discardingReconsiderationFailure(
        expected: ProfileReconsideration,
        at instant: UTCInstant
    ) throws -> ChatAggregate {
        guard profileReconsideration == expected else {
            throw ProfileReconsiderationPublicationError.sidecarMismatch
        }
        guard expected.failure != nil else {
            throw ProfileReconsiderationPublicationError.failureRequired
        }
        let (revision, overflow) = chat.manifestRevision.addingReportingOverflow(1)
        guard !overflow else {
            throw ProfileReconsiderationPublicationError
                .manifestRevisionOverflow
        }
        let replacementChat = try Chat(
            id: chat.id,
            manifestRevision: revision,
            title: chat.title,
            createdAt: chat.createdAt,
            updatedAt: instant,
            creation: chat.creation,
            profileStatementGenerationAtCreation:
                chat.profileStatementGenerationAtCreation,
            attachments: chat.attachments,
            draft: chat.draft,
            messageIDs: chat.messageIDs,
            currentMemoryID: chat.currentMemoryID
        )
        return try ChatAggregate(
            chat: replacementChat,
            memory: memory,
            messages: messages,
            profileEffect: profileEffect
        )
    }

    private static func replacement(
        _ proposal: ProfileChangeProposal,
        contains retainedAppends: [ProfileEvidenceAppend]
    ) -> Bool {
        retainedAppends.allSatisfy { retained in
            let standaloneEvidence = proposal.evidenceAppends
                .filter { $0.target == retained.target }
                .flatMap(\.evidence)
            let semanticEvidence = proposal.changes
                .filter { $0.target == retained.target }
                .flatMap(\.evidence)
            let matchingEvidence = standaloneEvidence + semanticEvidence
            return retained.evidence.allSatisfy(matchingEvidence.contains)
        }
    }

    private static func validateReconsiderationMemory(
        _ replacement: CoachMemory?,
        current: CoachMemory,
        chat: Chat
    ) throws {
        guard let replacement else { return }
        guard replacement.chatID == chat.id else {
            throw ProfileReconsiderationPublicationError
                .replacementMemoryOwnerMismatch
        }
        guard replacement.memoryID != current.memoryID else {
            throw ProfileReconsiderationPublicationError
                .replacementMemoryIdentityReused
        }
        guard !replacement.hasSameCanonicalContent(as: current) else {
            throw ProfileReconsiderationPublicationError
                .replacementMemoryContentUnchanged
        }
        let attachmentIDs = Set(chat.attachments.values.map(\.attachmentID))
        guard replacement.sessionSummaries.allSatisfy({
            attachmentIDs.contains($0.sessionAttachmentID)
        }) else {
            throw ProfileReconsiderationPublicationError
                .replacementMemoryAttachmentMismatch
        }
    }
}
