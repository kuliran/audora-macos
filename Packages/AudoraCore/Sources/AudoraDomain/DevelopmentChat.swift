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
    case duplicateAttachmentID
    case duplicateSessionRevision
}

public struct ChatAttachments: Equatable, Sendable {
    public static let empty = try! ChatAttachments(validating: [])

    public let values: [ChatSessionAttachment]

    public init(validating values: [ChatSessionAttachment]) throws {
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

public enum PendingUserTurnFailure: String, Equatable, Sendable {
    case coachContextCannotFit
    case coachResponseInterrupted
}

public struct PendingUserTurn: Equatable, Sendable {
    public static let schemaVersion: UInt32 = 1

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
}

public enum ChatAggregateError: Error, Equatable, Sendable {
    case duplicateMessageID
    case draftIdentityChanged
    case draftVersionDidNotAdvance
    case pendingDraftMismatch
    case memoryPointerMismatch
    case memoryOwnerMismatch
    case manifestRevisionOverflow
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
    public let pendingUserTurn: PendingUserTurn?

    public init(
        chat: Chat,
        memory: CoachMemory,
        pendingUserTurn: PendingUserTurn? = nil
    ) throws {
        guard chat.currentMemoryID == memory.memoryID else {
            throw ChatAggregateError.memoryPointerMismatch
        }
        guard chat.id == memory.chatID else {
            throw ChatAggregateError.memoryOwnerMismatch
        }
        if let pendingUserTurn {
            guard pendingUserTurn.draftID == chat.draft.draftID,
                  pendingUserTurn.draftVersion == chat.draft.version
            else {
                throw ChatAggregateError.pendingDraftMismatch
            }
        }
        self.chat = chat
        self.memory = memory
        self.pendingUserTurn = pendingUserTurn
    }

    public static func emptyDevelopmentChat(
        chatID: ChatID,
        draftID: ChatDraftID,
        memoryID: CoachMemoryID,
        instant: UTCInstant,
        profileStatementGeneration: UInt64
    ) throws -> ChatAggregate {
        let attachments = ChatAttachments.empty
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
