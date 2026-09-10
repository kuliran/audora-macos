public enum ChatIdentityError: Error, Equatable, Sendable {
    case invalidChatID
    case invalidDraftID
    case invalidPendingUserTurnID
    case invalidResponsePositionID
    case invalidMemoryID
    case invalidMessageID
    case invalidAttachmentID
}

public struct PendingUserTurnID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard TypedIdentifierValidator.isValid(rawValue, prefix: "ptu-") else {
            throw ChatIdentityError.invalidPendingUserTurnID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ChatResponsePositionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard TypedIdentifierValidator.isValid(rawValue, prefix: "rsp-") else {
            throw ChatIdentityError.invalidResponsePositionID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ChatID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard TypedIdentifierValidator.isValid(rawValue, prefix: "cht-") else {
            throw ChatIdentityError.invalidChatID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ChatDraftID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard TypedIdentifierValidator.isValid(rawValue, prefix: "drf-") else {
            throw ChatIdentityError.invalidDraftID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct CoachMemoryID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard TypedIdentifierValidator.isValid(rawValue, prefix: "mem-") else {
            throw ChatIdentityError.invalidMemoryID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ChatMessageID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard TypedIdentifierValidator.isValid(rawValue, prefix: "msg-") else {
            throw ChatIdentityError.invalidMessageID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ChatSessionAttachmentID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard (1...64).contains(rawValue.utf8.count),
              rawValue.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) ||
                      (97...122).contains($0) || $0 == 45 || $0 == 95
              })
        else {
            throw ChatIdentityError.invalidAttachmentID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum ChatTitleError: Error, Equatable, Sendable {
    case empty
    case invalidCharacter
    case tooLong
}

public struct ChatTitle: Hashable, Sendable, CustomStringConvertible {
    public static let maximumUTF8Bytes = 256
    public static let newChat = try! ChatTitle("New Chat")

    public let rawValue: String

    public init(_ input: String) throws {
        let scalars = Array(input.unicodeScalars)
        let first = scalars.firstIndex { !$0.properties.isWhitespace } ?? scalars.endIndex
        let last = scalars.lastIndex { !$0.properties.isWhitespace }
        guard let last, first <= last else { throw ChatTitleError.empty }
        let trimmed = String(String.UnicodeScalarView(Array(scalars[first...last])))
        guard !trimmed.unicodeScalars.contains(where: Self.isForbidden) else {
            throw ChatTitleError.invalidCharacter
        }
        guard trimmed.utf8.count <= Self.maximumUTF8Bytes else {
            throw ChatTitleError.tooLong
        }
        rawValue = trimmed
    }

    public var description: String { rawValue }

    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator:
            true
        default:
            scalar.value == 0
        }
    }
}

public enum ChatFilterQueryError: Error, Equatable, Sendable {
    case tooLong
    case invalidCharacter
}

public struct ChatFilterQuery: Hashable, Sendable {
    public static let empty = try! ChatFilterQuery("")

    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard rawValue.utf8.count <= ChatTitle.maximumUTF8Bytes else {
            throw ChatFilterQueryError.tooLong
        }
        guard !rawValue.unicodeScalars.contains(where: {
            $0.value == 0 || $0.properties.generalCategory == .control
        }) else {
            throw ChatFilterQueryError.invalidCharacter
        }
        self.rawValue = rawValue
    }
}

public struct ChatSessionAttachment: Equatable, Sendable {
    public let attachmentID: ChatSessionAttachmentID
    public let sessionID: SessionID
    public let transcriptRevisionID: TranscriptRevisionID

    public init(
        attachmentID: ChatSessionAttachmentID,
        sessionID: SessionID,
        transcriptRevisionID: TranscriptRevisionID
    ) {
        self.attachmentID = attachmentID
        self.sessionID = sessionID
        self.transcriptRevisionID = transcriptRevisionID
    }
}

public enum ChatAttachmentsError: Error, Equatable, Sendable {
    case tooManyAttachments
    case duplicateAttachmentID
    case duplicateSessionRevision
}

public struct ChatAttachments: Equatable, Sendable {
    public static let maximumCount = 128
    public static let empty = try! ChatAttachments(validating: [])

    public let values: [ChatSessionAttachment]

    public init(validating values: [ChatSessionAttachment]) throws {
        guard values.count <= Self.maximumCount else {
            throw ChatAttachmentsError.tooManyAttachments
        }
        var attachmentIDs: Set<ChatSessionAttachmentID> = []
        var pairs: Set<SessionRevisionPair> = []
        for value in values {
            guard attachmentIDs.insert(value.attachmentID).inserted else {
                throw ChatAttachmentsError.duplicateAttachmentID
            }
            guard pairs.insert(
                SessionRevisionPair(
                    sessionID: value.sessionID,
                    transcriptRevisionID: value.transcriptRevisionID
                )
            ).inserted else {
                throw ChatAttachmentsError.duplicateSessionRevision
            }
        }
        self.values = values
    }

    private struct SessionRevisionPair: Hashable {
        let sessionID: SessionID
        let transcriptRevisionID: TranscriptRevisionID
    }
}

public enum ChatCreationKind: String, Equatable, Sendable {
    case newChat
    case sessionAnalysis
}

public enum ChatCreationError: Error, Equatable, Sendable {
    case unexpectedOrigin
    case missingOrigin
    case originNotAttached
}

public struct ChatCreation: Equatable, Sendable {
    public let kind: ChatCreationKind
    public let originAttachmentID: ChatSessionAttachmentID?

    public init(
        kind: ChatCreationKind,
        originAttachmentID: ChatSessionAttachmentID?,
        attachments: ChatAttachments
    ) throws {
        switch (kind, originAttachmentID) {
        case (.newChat, nil):
            break
        case (.newChat, .some):
            throw ChatCreationError.unexpectedOrigin
        case (.sessionAnalysis, nil):
            throw ChatCreationError.missingOrigin
        case let (.sessionAnalysis, .some(origin)):
            guard attachments.values.contains(where: { $0.attachmentID == origin }) else {
                throw ChatCreationError.originNotAttached
            }
        }
        self.kind = kind
        self.originAttachmentID = originAttachmentID
    }
}

public enum ChatDraftError: Error, Equatable, Sendable {
    case textTooLong
    case invalidText
    case versionOverflow
}

public struct ChatDraft: Equatable, Sendable {
    public static let maximumUTF8Bytes = 32_768

    public let draftID: ChatDraftID
    public let version: UInt64
    public let text: String
    public let updatedAt: UTCInstant

    public init(
        draftID: ChatDraftID,
        version: UInt64,
        text: String,
        updatedAt: UTCInstant
    ) throws {
        guard text.utf8.count <= Self.maximumUTF8Bytes else {
            throw ChatDraftError.textTooLong
        }
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ChatDraftError.invalidText
        }
        self.draftID = draftID
        self.version = version
        self.text = text
        self.updatedAt = updatedAt
    }

    public func edited(text: String, at instant: UTCInstant) throws -> ChatDraft {
        let (nextVersion, overflow) = version.addingReportingOverflow(1)
        guard !overflow else { throw ChatDraftError.versionOverflow }
        return try ChatDraft(
            draftID: draftID,
            version: nextVersion,
            text: text,
            updatedAt: instant
        )
    }
}

public enum CoachTranscriptReadFailureSummaryError: Error, Equatable, Sendable {
    case invalidDisplayLabel
    case invalidSessionCount
    case duplicateSessionAttachment
    case invalidAdditionalSessionCount
}

/// A privacy-bounded, durable link to one affected Chat attachment.
///
/// The Chat-scoped attachment ID is the only identity retained. Session,
/// Transcript Revision, Library, storage, and provider transport identities
/// remain outside this value.
public struct CoachTranscriptReadFailureSession: Equatable, Sendable {
    public static let maximumDisplayLabelUnicodeScalars = 256

    public let sessionAttachmentID: ChatSessionAttachmentID
    public let displayLabel: String

    public init(
        sessionAttachmentID: ChatSessionAttachmentID,
        displayLabel: String
    ) throws {
        guard !displayLabel.isEmpty,
              displayLabel.unicodeScalars.count <=
              Self.maximumDisplayLabelUnicodeScalars,
              !displayLabel.unicodeScalars.contains(where: {
                  $0.value == 0 || $0.properties.generalCategory == .control
              })
        else {
            throw CoachTranscriptReadFailureSummaryError.invalidDisplayLabel
        }
        self.sessionAttachmentID = sessionAttachmentID
        self.displayLabel = displayLabel
    }
}

/// The complete durable UI summary for an atomic transcript-read failure.
///
/// At most three Sessions become links. A positive remainder is valid only
/// after all three link slots are occupied, preventing malformed summaries
/// from understating the affected set.
public struct CoachTranscriptReadFailureSummary: Equatable, Sendable {
    public static let maximumLinkedSessionCount = 3
    public static let maximumAdditionalSessionCount =
        ChatAttachments.maximumCount - maximumLinkedSessionCount

    public let sessions: [CoachTranscriptReadFailureSession]
    public let additionalSessionCount: UInt8

    public init(
        sessions: [CoachTranscriptReadFailureSession],
        additionalSessionCount: UInt8
    ) throws {
        guard (1 ... Self.maximumLinkedSessionCount).contains(sessions.count) else {
            throw CoachTranscriptReadFailureSummaryError.invalidSessionCount
        }
        guard Set(sessions.map(\.sessionAttachmentID)).count == sessions.count else {
            throw CoachTranscriptReadFailureSummaryError.duplicateSessionAttachment
        }
        guard Int(additionalSessionCount) <= Self.maximumAdditionalSessionCount,
              additionalSessionCount == 0 ||
              sessions.count == Self.maximumLinkedSessionCount
        else {
            throw CoachTranscriptReadFailureSummaryError.invalidAdditionalSessionCount
        }
        self.sessions = sessions
        self.additionalSessionCount = additionalSessionCount
    }
}

public enum PendingUserTurnFailure: RawRepresentable, Equatable, Sendable {
    case coachContextCannotFit
    case coachResponseInterrupted
    case coachProviderError
    case coachResponseInvalid
    case coachTranscriptReadFailed(CoachTranscriptReadFailureSummary)

    public init?(rawValue: String) {
        switch rawValue {
        case "coachContextCannotFit": self = .coachContextCannotFit
        case "coachResponseInterrupted": self = .coachResponseInterrupted
        case "coachProviderError": self = .coachProviderError
        case "coachResponseInvalid": self = .coachResponseInvalid
        // This kind is invalid without its required privacy-bounded summary.
        case "coachTranscriptReadFailed": return nil
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .coachContextCannotFit: "coachContextCannotFit"
        case .coachResponseInterrupted: "coachResponseInterrupted"
        case .coachProviderError: "coachProviderError"
        case .coachResponseInvalid: "coachResponseInvalid"
        case .coachTranscriptReadFailed: "coachTranscriptReadFailed"
        }
    }

    public var transcriptReadFailureSummary: CoachTranscriptReadFailureSummary? {
        guard case let .coachTranscriptReadFailed(summary) = self else { return nil }
        return summary
    }
}

public struct PendingUserTurn: Equatable, Sendable {
    public static let schemaVersion: UInt32 = 4

    public let id: PendingUserTurnID
    public let draftID: ChatDraftID
    public let draftVersion: UInt64
    public let responsePositionID: ChatResponsePositionID
    public let failure: PendingUserTurnFailure?

    public init(
        id: PendingUserTurnID,
        draftID: ChatDraftID,
        draftVersion: UInt64,
        responsePositionID: ChatResponsePositionID,
        failure: PendingUserTurnFailure? = nil
    ) {
        self.id = id
        self.draftID = draftID
        self.draftVersion = draftVersion
        self.responsePositionID = responsePositionID
        self.failure = failure
    }

    public func replacingFailure(
        _ failure: PendingUserTurnFailure?
    ) -> PendingUserTurn {
        PendingUserTurn(
            id: id,
            draftID: draftID,
            draftVersion: draftVersion,
            responsePositionID: responsePositionID,
            failure: failure
        )
    }
}

/// Durable Chat-owned authority for one Reconsider Invocation. The source
/// effect remains installed until a successful result replaces or withdraws it.
public struct ProfileReconsideration: Equatable, Sendable {
    public static let schemaVersion: UInt32 = 1

    public let sourceEffectIdentity: ChatProfileEffectIdentity
    public let resultResponsePositionID: ChatResponsePositionID
    public let failure: PendingUserTurnFailure?

    public init(
        sourceEffectIdentity: ChatProfileEffectIdentity,
        resultResponsePositionID: ChatResponsePositionID,
        failure: PendingUserTurnFailure? = nil
    ) {
        self.sourceEffectIdentity = sourceEffectIdentity
        self.resultResponsePositionID = resultResponsePositionID
        self.failure = failure
    }

    public init(
        sourceEffect: ChatProfileEffect,
        resultResponsePositionID: ChatResponsePositionID,
        failure: PendingUserTurnFailure? = nil
    ) {
        self.init(
            sourceEffectIdentity: sourceEffect.identity,
            resultResponsePositionID: resultResponsePositionID,
            failure: failure
        )
    }

    public func replacingFailure(
        _ failure: PendingUserTurnFailure?
    ) -> ProfileReconsideration {
        ProfileReconsideration(
            sourceEffectIdentity: sourceEffectIdentity,
            resultResponsePositionID: resultResponsePositionID,
            failure: failure
        )
    }
}

public struct CoachMemorySessionSummary: Equatable, Sendable {
    public let sessionAttachmentID: ChatSessionAttachmentID
    public let notes: String

    public init(sessionAttachmentID: ChatSessionAttachmentID, notes: String) {
        self.sessionAttachmentID = sessionAttachmentID
        self.notes = notes
    }
}

public enum CoachMemoryError: Error, Equatable, Sendable {
    case duplicateSessionSummary
    case danglingSessionSummary
    case contentTooLong
    case invalidContent
}

public struct CoachMemory: Equatable, Sendable {
    public static let schemaVersion: UInt32 = 1
    public static let maximumTextUTF8Bytes = 32_768

    public let memoryID: CoachMemoryID
    public let chatID: ChatID
    public let generalNotes: String
    public let sessionSummaries: [CoachMemorySessionSummary]

    public init(
        memoryID: CoachMemoryID,
        chatID: ChatID,
        generalNotes: String,
        sessionSummaries: [CoachMemorySessionSummary],
        attachments: ChatAttachments
    ) throws {
        let allText = [generalNotes] + sessionSummaries.map(\.notes)
        guard allText.allSatisfy({ $0.utf8.count <= Self.maximumTextUTF8Bytes }) else {
            throw CoachMemoryError.contentTooLong
        }
        guard allText.allSatisfy({ !$0.unicodeScalars.contains(where: { $0.value == 0 }) }) else {
            throw CoachMemoryError.invalidContent
        }
        var summaryIDs: Set<ChatSessionAttachmentID> = []
        let attachmentIDs = Set(attachments.values.map(\.attachmentID))
        for summary in sessionSummaries {
            guard summaryIDs.insert(summary.sessionAttachmentID).inserted else {
                throw CoachMemoryError.duplicateSessionSummary
            }
            guard attachmentIDs.contains(summary.sessionAttachmentID) else {
                throw CoachMemoryError.danglingSessionSummary
            }
        }
        self.memoryID = memoryID
        self.chatID = chatID
        self.generalNotes = generalNotes
        self.sessionSummaries = sessionSummaries
    }

    /// Compares the canonical provider-authored payload while deliberately
    /// ignoring the app-assigned snapshot identity and owning Chat identity.
    public func hasSameCanonicalContent(as other: CoachMemory) -> Bool {
        generalNotes == other.generalNotes &&
            sessionSummaries == other.sessionSummaries
    }
}

public enum ChatAggregateError: Error, Equatable, Sendable {
    case duplicateMessageID
    case draftIdentityChanged
    case draftVersionDidNotAdvance
    case pendingDraftMismatch
    case pendingFailureAttachmentMismatch
    case memoryPointerMismatch
    case memoryOwnerMismatch
    case manifestRevisionOverflow
    case messageHistoryMismatch
    case multipleProfileEffects
    case reconsiderationSourceMismatch
    case reconsiderationResponsePositionMismatch
    case reconsiderationFailureAttachmentMismatch
}

public struct Chat: Equatable, Sendable {
    public static let schemaVersion: UInt32 = 1

    public let id: ChatID
    public let manifestRevision: UInt64
    public let title: ChatTitle
    public let createdAt: UTCInstant
    public let updatedAt: UTCInstant
    public let creation: ChatCreation
    public let profileStatementGenerationAtCreation: UInt64
    public let attachments: ChatAttachments
    public let draft: ChatDraft
    public let messageIDs: [ChatMessageID]
    public let currentMemoryID: CoachMemoryID

    public init(
        id: ChatID,
        manifestRevision: UInt64,
        title: ChatTitle,
        createdAt: UTCInstant,
        updatedAt: UTCInstant,
        creation: ChatCreation,
        profileStatementGenerationAtCreation: UInt64,
        attachments: ChatAttachments,
        draft: ChatDraft,
        messageIDs: [ChatMessageID],
        currentMemoryID: CoachMemoryID
    ) throws {
        _ = try ChatCreation(
            kind: creation.kind,
            originAttachmentID: creation.originAttachmentID,
            attachments: attachments
        )
        guard Set(messageIDs).count == messageIDs.count else {
            throw ChatAggregateError.duplicateMessageID
        }
        self.id = id
        self.manifestRevision = manifestRevision
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.creation = creation
        self.profileStatementGenerationAtCreation = profileStatementGenerationAtCreation
        self.attachments = attachments
        self.draft = draft
        self.messageIDs = messageIDs
        self.currentMemoryID = currentMemoryID
    }

    public func renamed(to title: ChatTitle, at instant: UTCInstant) throws -> Chat {
        guard title != self.title else { return self }
        let (revision, overflow) = manifestRevision.addingReportingOverflow(1)
        guard !overflow else { throw ChatAggregateError.manifestRevisionOverflow }
        return try Chat(
            id: id,
            manifestRevision: revision,
            title: title,
            createdAt: createdAt,
            updatedAt: instant,
            creation: creation,
            profileStatementGenerationAtCreation: profileStatementGenerationAtCreation,
            attachments: attachments,
            draft: draft,
            messageIDs: messageIDs,
            currentMemoryID: currentMemoryID
        )
    }

    public func replacingDraft(with replacement: ChatDraft) throws -> Chat {
        guard replacement.draftID == draft.draftID else {
            throw ChatAggregateError.draftIdentityChanged
        }
        guard replacement.version > draft.version else {
            throw ChatAggregateError.draftVersionDidNotAdvance
        }
        let (revision, overflow) = manifestRevision.addingReportingOverflow(1)
        guard !overflow else { throw ChatAggregateError.manifestRevisionOverflow }
        return try Chat(
            id: id,
            manifestRevision: revision,
            title: title,
            createdAt: createdAt,
            updatedAt: replacement.updatedAt,
            creation: creation,
            profileStatementGenerationAtCreation: profileStatementGenerationAtCreation,
            attachments: attachments,
            draft: replacement,
            messageIDs: messageIDs,
            currentMemoryID: currentMemoryID
        )
    }
}

public struct ChatAggregate: Equatable, Sendable {
    public let chat: Chat
    public let memory: CoachMemory
    public let messages: [ChatMessage]
    public let pendingUserTurn: PendingUserTurn?
    public let profileEffect: ChatProfileEffect?
    public let profileReconsideration: ProfileReconsideration?

    /// Compatibility projections for callers and persisted schema adapters from
    /// the pre-Reconsider slices. New transformations should preserve the single
    /// `profileEffect` value directly.
    public var profileProposal: ProfileChangeProposal? {
        profileEffect?.proposal
    }

    public var profileEvidencePublication: ProfileEvidencePublication? {
        profileEffect?.evidencePublication
    }

    public init(
        chat: Chat,
        memory: CoachMemory,
        messages: [ChatMessage] = [],
        pendingUserTurn: PendingUserTurn? = nil,
        profileEffect: ChatProfileEffect? = nil,
        profileProposal: ProfileChangeProposal? = nil,
        profileEvidencePublication: ProfileEvidencePublication? = nil,
        profileReconsideration: ProfileReconsideration? = nil
    ) throws {
        let legacyEffects: [ChatProfileEffect] = [
            profileProposal.map(ChatProfileEffect.proposal),
            profileEvidencePublication.map(
                ChatProfileEffect.evidencePublication
            ),
        ].compactMap { $0 }
        guard legacyEffects.count <= 1,
              profileEffect == nil || legacyEffects.isEmpty
        else { throw ChatAggregateError.multipleProfileEffects }
        let resolvedProfileEffect = profileEffect ?? legacyEffects.first

        guard chat.currentMemoryID == memory.memoryID else {
            throw ChatAggregateError.memoryPointerMismatch
        }
        guard chat.id == memory.chatID else {
            throw ChatAggregateError.memoryOwnerMismatch
        }
        if !messages.isEmpty || chat.messageIDs.isEmpty {
            guard messages.map(\.id) == chat.messageIDs else {
                throw ChatAggregateError.messageHistoryMismatch
            }
            var responsePositions: Set<ChatResponsePositionID> = []
            var index = 0
            while index < messages.count {
                let first = messages[index]
                guard responsePositions.insert(
                    first.responsePositionID
                ).inserted else {
                    throw ChatAggregateError.messageHistoryMismatch
                }
                switch first.content {
                case .coach:
                    // A coach-only group is a successful Reconsider result.
                    index += 1
                case .user:
                    guard index + 1 < messages.count else {
                        throw ChatAggregateError.messageHistoryMismatch
                    }
                    let second = messages[index + 1]
                    guard case .coach = second.content,
                          second.responsePositionID ==
                            first.responsePositionID,
                          first.persistedSchemaVersion ==
                            second.persistedSchemaVersion
                    else {
                        throw ChatAggregateError.messageHistoryMismatch
                    }
                    index += 2
                }
            }
            let attachmentPairs = Set(chat.attachments.values.map {
                EvidenceAttachmentPair(
                    sessionID: $0.sessionID,
                    transcriptRevisionID: $0.transcriptRevisionID
                )
            })
            for message in messages {
                guard case let .coach(blocks) = message.content else { continue }
                for block in blocks {
                    guard case let .evidenceObservation(_, evidence) = block else {
                        continue
                    }
                    guard evidence.allSatisfy({ reference in
                        attachmentPairs.contains(
                            EvidenceAttachmentPair(
                                sessionID: reference.sessionID,
                                transcriptRevisionID:
                                    reference.transcriptRevisionID
                            )
                        )
                    }) else { throw ChatAggregateError.messageHistoryMismatch }
                }
            }
        }
        let profileProposal = resolvedProfileEffect?.proposal
        let profileEvidencePublication =
            resolvedProfileEffect?.evidencePublication
        if let pendingUserTurn {
            guard pendingUserTurn.draftID == chat.draft.draftID,
                  pendingUserTurn.draftVersion == chat.draft.version,
                  messages.isEmpty || !messages.contains(where: {
                      $0.responsePositionID == pendingUserTurn.responsePositionID
                  })
            else {
                throw ChatAggregateError.pendingDraftMismatch
            }
            if let summary = pendingUserTurn.failure?.transcriptReadFailureSummary {
                let attachmentIDs = Set(chat.attachments.values.map(\.attachmentID))
                guard summary.sessions.allSatisfy({
                    attachmentIDs.contains($0.sessionAttachmentID)
                }),
                    summary.sessions.count + Int(summary.additionalSessionCount) <=
                    attachmentIDs.count
                else {
                    throw ChatAggregateError.pendingFailureAttachmentMismatch
                }
            }
        }
        if let profileProposal {
            guard pendingUserTurn == nil,
                  profileEvidencePublication == nil,
                  profileProposal.chatID == chat.id
            else { throw ChatAggregateError.messageHistoryMismatch }
            if !messages.isEmpty {
                let sourceMessages = messages.filter { message in
                    message.responsePositionID ==
                        profileProposal.responsePositionID && {
                            if case .coach = message.content { return true }
                            return false
                        }()
                }
                // Reconsider may publish a reviewed replacement without adding
                // a coach message. When a source message is present it still
                // has to be the single, exact response for this proposal.
                guard sourceMessages.count <= 1 else {
                    throw ChatAggregateError.messageHistoryMismatch
                }
                if let sourceMessage = sourceMessages.first {
                    guard sourceMessage.coachProfile ==
                            profileProposal.baseProfile
                    else { throw ChatAggregateError.messageHistoryMismatch }
                }
            }
            let attachmentPairs = Set(chat.attachments.values.map {
                EvidenceAttachmentPair(
                    sessionID: $0.sessionID,
                    transcriptRevisionID: $0.transcriptRevisionID
                )
            })
            let proposalEvidence = profileProposal.changes.flatMap(\.evidence) +
                profileProposal.evidenceAppends.flatMap(\.evidence)
            guard proposalEvidence.allSatisfy({ reference in
                attachmentPairs.contains(
                    EvidenceAttachmentPair(
                        sessionID: reference.sessionID,
                        transcriptRevisionID: reference.transcriptRevisionID
                    )
                )
            }) else { throw ChatAggregateError.messageHistoryMismatch }
        }
        if let profileEvidencePublication {
            guard pendingUserTurn == nil,
                  profileProposal == nil,
                  profileEvidencePublication.chatID == chat.id,
                  !chat.messageIDs.isEmpty
            else { throw ChatAggregateError.messageHistoryMismatch }
            if !messages.isEmpty {
                let sourceMessages = messages.filter { message in
                    message.responsePositionID ==
                        profileEvidencePublication.responsePositionID && {
                            if case .coach = message.content { return true }
                            return false
                        }()
                }
                guard sourceMessages.count == 1 else {
                    throw ChatAggregateError.messageHistoryMismatch
                }
            }
            let attachmentPairs = Set(chat.attachments.values.map {
                EvidenceAttachmentPair(
                    sessionID: $0.sessionID,
                    transcriptRevisionID: $0.transcriptRevisionID
                )
            })
            let publicationEvidence = profileEvidencePublication
                .evidenceAppends.flatMap(\.evidence)
            guard publicationEvidence.allSatisfy({ reference in
                attachmentPairs.contains(
                    EvidenceAttachmentPair(
                        sessionID: reference.sessionID,
                        transcriptRevisionID: reference.transcriptRevisionID
                    )
                )
            }) else { throw ChatAggregateError.messageHistoryMismatch }
        }
        if let profileReconsideration {
            guard pendingUserTurn == nil,
                  let resolvedProfileEffect,
                  resolvedProfileEffect.identity ==
                    profileReconsideration.sourceEffectIdentity
            else {
                throw ChatAggregateError.reconsiderationSourceMismatch
            }
            guard profileReconsideration.resultResponsePositionID !=
                    resolvedProfileEffect.responsePositionID,
                  messages.isEmpty || !messages.contains(where: {
                      $0.responsePositionID ==
                        profileReconsideration.resultResponsePositionID
                  })
            else {
                throw ChatAggregateError
                    .reconsiderationResponsePositionMismatch
            }
            if let summary = profileReconsideration.failure?
                .transcriptReadFailureSummary
            {
                let attachmentIDs = Set(
                    chat.attachments.values.map(\.attachmentID)
                )
                guard summary.sessions.allSatisfy({
                    attachmentIDs.contains($0.sessionAttachmentID)
                }), summary.sessions.count +
                    Int(summary.additionalSessionCount) <= attachmentIDs.count
                else {
                    throw ChatAggregateError
                        .reconsiderationFailureAttachmentMismatch
                }
            }
        }
        self.chat = chat
        self.memory = memory
        self.messages = messages
        self.pendingUserTurn = pendingUserTurn
        self.profileEffect = resolvedProfileEffect
        self.profileReconsideration = profileReconsideration
    }

    public static func emptyDevelopmentChat(
        chatID: ChatID,
        draftID: ChatDraftID,
        memoryID: CoachMemoryID,
        instant: UTCInstant,
        profileStatementGeneration: UInt64
    ) throws -> ChatAggregate {
        try newChat(
            chatID: chatID,
            draftID: draftID,
            memoryID: memoryID,
            instant: instant,
            profileStatementGeneration: profileStatementGeneration,
            attachments: .empty
        )
    }

    public static func newChat(
        chatID: ChatID,
        draftID: ChatDraftID,
        memoryID: CoachMemoryID,
        instant: UTCInstant,
        profileStatementGeneration: UInt64,
        attachments: ChatAttachments
    ) throws -> ChatAggregate {
        let creation = try ChatCreation(
            kind: .newChat,
            originAttachmentID: nil,
            attachments: attachments
        )
        let draft = try ChatDraft(
            draftID: draftID,
            version: 0,
            text: "",
            updatedAt: instant
        )
        let chat = try Chat(
            id: chatID,
            manifestRevision: 0,
            title: .newChat,
            createdAt: instant,
            updatedAt: instant,
            creation: creation,
            profileStatementGenerationAtCreation: profileStatementGeneration,
            attachments: attachments,
            draft: draft,
            messageIDs: [],
            currentMemoryID: memoryID
        )
        let memory = try CoachMemory(
            memoryID: memoryID,
            chatID: chatID,
            generalNotes: "",
            sessionSummaries: [],
            attachments: attachments
        )
        return try ChatAggregate(chat: chat, memory: memory)
    }
}

private struct EvidenceAttachmentPair: Hashable {
    let sessionID: SessionID
    let transcriptRevisionID: TranscriptRevisionID
}
