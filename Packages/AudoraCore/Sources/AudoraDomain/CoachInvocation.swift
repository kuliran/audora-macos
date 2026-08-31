public enum CoachInvocationIdentityError: Error, Equatable, Sendable {
    case invalidInvocationID
    case invalidAttemptID
}

public struct CoachInvocationID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard TypedIdentifierValidator.isValid(rawValue, prefix: "inv-") else {
            throw CoachInvocationIdentityError.invalidInvocationID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct CoachProviderAttemptID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard TypedIdentifierValidator.isValid(rawValue, prefix: "atm-") else {
            throw CoachInvocationIdentityError.invalidAttemptID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum ProviderIdempotencyValueError: Error, Equatable, Sendable {
    case empty
    case tooLong
    case invalidCharacter
}

/// Opaque provider deduplication authority. It is deliberately non-descriptive
/// and never projected to Presentation or diagnostics.
public struct ProviderIdempotencyValue: Hashable, Sendable {
    public static let maximumUTF8Bytes = 128
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty else { throw ProviderIdempotencyValueError.empty }
        guard rawValue.utf8.count <= Self.maximumUTF8Bytes else {
            throw ProviderIdempotencyValueError.tooLong
        }
        guard rawValue.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (65...90).contains(byte) ||
                (97...122).contains(byte) || byte == 45 || byte == 46 || byte == 95
        }) else {
            throw ProviderIdempotencyValueError.invalidCharacter
        }
        self.rawValue = rawValue
    }
}

public enum ChatMessageContent: Equatable, Sendable {
    case user(text: String)
    case coach(markdown: String)
}

public enum ChatMessageError: Error, Equatable, Sendable {
    case emptyContent
    case contentTooLong
    case invalidContent
}

public struct ChatMessage: Equatable, Sendable {
    public static let schemaVersion: UInt32 = 1
    public static let maximumUserTextUTF8Bytes = ChatDraft.maximumUTF8Bytes
    /// Bounded provider text; persistence separately checks the exact encoded envelope.
    public static let maximumCoachMarkdownUTF8Bytes = 64_000

    public let id: ChatMessageID
    public let responsePositionID: ChatResponsePositionID
    public let content: ChatMessageContent
    public let createdAt: UTCInstant

    public init(
        id: ChatMessageID,
        responsePositionID: ChatResponsePositionID,
        content: ChatMessageContent,
        createdAt: UTCInstant
    ) throws {
        let text: String
        let maximum: Int
        switch content {
        case let .user(value):
            text = value
            maximum = Self.maximumUserTextUTF8Bytes
        case let .coach(value):
            text = value
            maximum = Self.maximumCoachMarkdownUTF8Bytes
        }
        guard text.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) else {
            throw ChatMessageError.emptyContent
        }
        guard text.utf8.count <= maximum else { throw ChatMessageError.contentTooLong }
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ChatMessageError.invalidContent
        }
        self.id = id
        self.responsePositionID = responsePositionID
        self.content = content
        self.createdAt = createdAt
    }
}

public enum CoachInvocationError: Error, Equatable, Sendable {
    case chatMismatch
    case pendingMismatch
    case draftMismatch
    case responsePositionMismatch
    case manifestRevisionMismatch
    case failedPending
}

/// Durable launch authority for one admitted top-level Coach operation.
public struct CoachInvocation: Equatable, Sendable {
    public static let schemaVersion: UInt32 = 1

    public let id: CoachInvocationID
    public let attemptID: CoachProviderAttemptID
    public let providerIdempotencyValue: ProviderIdempotencyValue
    public let libraryID: LibraryID
    public let chatID: ChatID
    public let pendingUserTurnID: PendingUserTurnID
    public let draftID: ChatDraftID
    public let draftVersion: UInt64
    public let responsePositionID: ChatResponsePositionID
    public let expectedManifestRevision: UInt64
    public let admittedAt: UTCInstant

    public init(
        id: CoachInvocationID,
        attemptID: CoachProviderAttemptID,
        providerIdempotencyValue: ProviderIdempotencyValue,
        library: LibraryScope,
        chatID: ChatID,
        pendingUserTurn: PendingUserTurn,
        expectedManifestRevision: UInt64,
        admittedAt: UTCInstant
    ) throws {
        guard pendingUserTurn.failure == nil else { throw CoachInvocationError.failedPending }
        self.id = id
        self.attemptID = attemptID
        self.providerIdempotencyValue = providerIdempotencyValue
        libraryID = library.libraryID
        self.chatID = chatID
        pendingUserTurnID = pendingUserTurn.id
        draftID = pendingUserTurn.draftID
        draftVersion = pendingUserTurn.draftVersion
        responsePositionID = pendingUserTurn.responsePositionID
        self.expectedManifestRevision = expectedManifestRevision
        self.admittedAt = admittedAt
    }

    public func validate(against aggregate: ChatAggregate) throws {
        guard aggregate.chat.id == chatID else { throw CoachInvocationError.chatMismatch }
        guard let pending = aggregate.pendingUserTurn,
              pending.id == pendingUserTurnID
        else {
            throw CoachInvocationError.pendingMismatch
        }
        guard pending.failure == nil else { throw CoachInvocationError.failedPending }
        guard aggregate.chat.draft.draftID == draftID,
              aggregate.chat.draft.version == draftVersion,
              pending.draftID == draftID,
              pending.draftVersion == draftVersion
        else {
            throw CoachInvocationError.draftMismatch
        }
        guard pending.responsePositionID == responsePositionID else {
            throw CoachInvocationError.responsePositionMismatch
        }
        guard aggregate.chat.manifestRevision == expectedManifestRevision else {
            throw CoachInvocationError.manifestRevisionMismatch
        }
    }
}

public enum InvocationPublicationError: Error, Equatable, Sendable {
    case responsePositionMismatch
    case userMessageRequired
    case coachMessageRequired
    case userTextMismatch
    case duplicateMessageID
    case freshDraftRequired
    case manifestRevisionOverflow
}

public extension ChatAggregate {
    /// Constructs the sole atomic publication replacement. Persistence stages both
    /// messages and uses the resulting Chat manifest as the commit marker.
    func publishingTurn(
        invocation: CoachInvocation,
        userMessage: ChatMessage,
        coachMessage: ChatMessage,
        freshDraft: ChatDraft,
        at instant: UTCInstant
    ) throws -> ChatAggregate {
        try invocation.validate(against: self)
        guard userMessage.responsePositionID == invocation.responsePositionID,
              coachMessage.responsePositionID == invocation.responsePositionID
        else {
            throw InvocationPublicationError.responsePositionMismatch
        }
        guard case let .user(userText) = userMessage.content else {
            throw InvocationPublicationError.userMessageRequired
        }
        guard case .coach = coachMessage.content else {
            throw InvocationPublicationError.coachMessageRequired
        }
        guard userText == chat.draft.text else {
            throw InvocationPublicationError.userTextMismatch
        }
        guard userMessage.id != coachMessage.id,
              !chat.messageIDs.contains(userMessage.id),
              !chat.messageIDs.contains(coachMessage.id)
        else {
            throw InvocationPublicationError.duplicateMessageID
        }
        guard freshDraft.draftID != chat.draft.draftID,
              freshDraft.version == 0,
              freshDraft.text.isEmpty
        else {
            throw InvocationPublicationError.freshDraftRequired
        }
        let (revision, overflow) = chat.manifestRevision.addingReportingOverflow(1)
        guard !overflow else { throw InvocationPublicationError.manifestRevisionOverflow }
        let replacement = try Chat(
            id: chat.id,
            manifestRevision: revision,
            title: chat.title,
            createdAt: chat.createdAt,
            updatedAt: instant,
            creation: chat.creation,
            profileStatementGenerationAtCreation: chat.profileStatementGenerationAtCreation,
            attachments: chat.attachments,
            draft: freshDraft,
            messageIDs: chat.messageIDs + [userMessage.id, coachMessage.id],
            currentMemoryID: chat.currentMemoryID
        )
        return try ChatAggregate(chat: replacement, memory: memory)
    }
}
