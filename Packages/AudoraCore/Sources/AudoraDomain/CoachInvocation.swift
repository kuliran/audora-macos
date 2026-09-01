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

public enum CoachProviderAttemptKind: String, Codable, Equatable, Sendable {
    case standard
    case shorterRepair
}

public enum CoachProviderTranscriptHandleError: Error, Equatable, Sendable {
    case notCanonicalUUID
}

/// Opaque Attempt-local route to one on-demand Chat Session Attachment.
public struct CoachProviderTranscriptHandle: Hashable, Sendable {
    public static let canonicalUTF8ByteCount = 36
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard rawValue.utf8.count == Self.canonicalUTF8ByteCount else {
            throw CoachProviderTranscriptHandleError.notCanonicalUUID
        }
        let bytes = Array(rawValue.utf8)
        guard bytes.enumerated().allSatisfy({ index, byte in
            switch index {
            case 8, 13, 18, 23:
                byte == 45
            default:
                (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
            }
        }) else {
            throw CoachProviderTranscriptHandleError.notCanonicalUUID
        }
        self.rawValue = rawValue
    }
}

public enum CoachProviderAttemptError: Error, Equatable, Sendable {
    case invalidSchemaVersion
    case invalidOrdinal
    case repairMustFollowAnEarlierAttempt
    case duplicateMessageID
    case duplicateTranscriptHandle
}

/// Fresh authority for the only atomic publication an Attempt may propose.
public struct CoachProviderAttemptPublicationAuthority: Equatable, Sendable {
    public let userMessageID: ChatMessageID
    public let coachMessageID: ChatMessageID
    public let freshDraftID: ChatDraftID

    public init(
        userMessageID: ChatMessageID,
        coachMessageID: ChatMessageID,
        freshDraftID: ChatDraftID
    ) throws {
        guard userMessageID != coachMessageID else {
            throw CoachProviderAttemptError.duplicateMessageID
        }
        self.userMessageID = userMessageID
        self.coachMessageID = coachMessageID
        self.freshDraftID = freshDraftID
    }
}

/// One durable external launch inside an Invocation. Current records always own
/// publication authority; legacy #22 records omit it because relaunch only
/// retires those interrupted records and never resumes their provider work.
public struct CoachProviderAttempt: Equatable, Sendable {
    public static let schemaVersion: UInt32 = 1
    public static let maximumOrdinal: UInt8 = 4
    public static let maximumTranscriptHandles = 128

    public let persistedSchemaVersion: UInt32
    public let id: CoachProviderAttemptID
    public let ordinal: UInt8
    public let kind: CoachProviderAttemptKind
    public let providerIdempotencyValue: ProviderIdempotencyValue
    public let transcriptHandles: [CoachProviderTranscriptHandle]
    public let publicationAuthority: CoachProviderAttemptPublicationAuthority?

    public init(
        schemaVersion: UInt32 = Self.schemaVersion,
        id: CoachProviderAttemptID,
        ordinal: UInt8,
        kind: CoachProviderAttemptKind,
        providerIdempotencyValue: ProviderIdempotencyValue,
        transcriptHandles: [CoachProviderTranscriptHandle],
        publicationAuthority: CoachProviderAttemptPublicationAuthority
    ) throws {
        try Self.validate(
            schemaVersion: schemaVersion,
            ordinal: ordinal,
            kind: kind,
            transcriptHandles: transcriptHandles
        )
        persistedSchemaVersion = schemaVersion
        self.id = id
        self.ordinal = ordinal
        self.kind = kind
        self.providerIdempotencyValue = providerIdempotencyValue
        self.transcriptHandles = transcriptHandles
        self.publicationAuthority = publicationAuthority
    }

    public init(
        legacyID: CoachProviderAttemptID,
        providerIdempotencyValue: ProviderIdempotencyValue
    ) {
        persistedSchemaVersion = Self.schemaVersion
        id = legacyID
        ordinal = 1
        kind = .standard
        self.providerIdempotencyValue = providerIdempotencyValue
        transcriptHandles = []
        publicationAuthority = nil
    }

    public var userMessageID: ChatMessageID? {
        publicationAuthority?.userMessageID
    }

    public var coachMessageID: ChatMessageID? {
        publicationAuthority?.coachMessageID
    }

    public var freshDraftID: ChatDraftID? {
        publicationAuthority?.freshDraftID
    }

    private static func validate(
        schemaVersion: UInt32,
        ordinal: UInt8,
        kind: CoachProviderAttemptKind,
        transcriptHandles: [CoachProviderTranscriptHandle]
    ) throws {
        guard schemaVersion == Self.schemaVersion else {
            throw CoachProviderAttemptError.invalidSchemaVersion
        }
        guard (1 ... Self.maximumOrdinal).contains(ordinal) else {
            throw CoachProviderAttemptError.invalidOrdinal
        }
        guard kind != .shorterRepair || ordinal > 1 else {
            throw CoachProviderAttemptError.repairMustFollowAnEarlierAttempt
        }
        guard transcriptHandles.count <= Self.maximumTranscriptHandles,
              Set(transcriptHandles).count == transcriptHandles.count
        else {
            throw CoachProviderAttemptError.duplicateTranscriptHandle
        }
    }
}

public enum ChatMessageContent: Equatable, Sendable {
    case user(text: String)
    case coach(markdown: String)
}

/// Exact Profile authority used to prepare one Coach response. A `nil`
/// revision represents the canonical no-selected-Profile head; the statement
/// generation still fences semantic changes to that head.
public struct CoachProfileProvenance: Equatable, Sendable {
    public let revisionID: ProfileRevisionID?
    public let statementGeneration: UInt64

    public init(
        revisionID: ProfileRevisionID?,
        statementGeneration: UInt64
    ) {
        self.revisionID = revisionID
        self.statementGeneration = statementGeneration
    }
}

public enum ChatMessageError: Error, Equatable, Sendable {
    case invalidSchemaVersion
    case emptyContent
    case contentTooLong
    case invalidContent
    case profileProvenanceMismatch
}

public struct ChatMessage: Equatable, Sendable {
    public static let schemaVersion: UInt32 = 2
    public static let maximumUserTextUTF8Bytes = 16_384
    /// Bounded provider text; persistence separately checks the exact encoded envelope.
    public static let maximumCoachMarkdownUTF8Bytes = 64_000

    public let persistedSchemaVersion: UInt32
    public let id: ChatMessageID
    public let responsePositionID: ChatResponsePositionID
    public let content: ChatMessageContent
    public let coachProfile: CoachProfileProvenance?
    public let createdAt: UTCInstant

    public init(
        schemaVersion: UInt32 = Self.schemaVersion,
        id: ChatMessageID,
        responsePositionID: ChatResponsePositionID,
        content: ChatMessageContent,
        coachProfile: CoachProfileProvenance? = nil,
        createdAt: UTCInstant
    ) throws {
        let text: String
        let maximum: Int
        switch content {
        case let .user(value):
            text = value
            maximum = schemaVersion == 1
                ? ChatDraft.maximumUTF8Bytes
                : Self.maximumUserTextUTF8Bytes
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
        switch (schemaVersion, content, coachProfile) {
        case (1, .user, nil), (1, .coach, nil),
             (Self.schemaVersion, .user, nil),
             (Self.schemaVersion, .coach, .some):
            break
        case (1, _, .some), (Self.schemaVersion, _, _):
            throw ChatMessageError.profileProvenanceMismatch
        default:
            throw ChatMessageError.invalidSchemaVersion
        }
        persistedSchemaVersion = schemaVersion
        self.id = id
        self.responsePositionID = responsePositionID
        self.content = content
        self.coachProfile = coachProfile
        self.createdAt = createdAt
    }
}

public enum CoachInvocationError: Error, Equatable, Sendable {
    case invalidSchemaVersion
    case chatMismatch
    case pendingMismatch
    case draftMismatch
    case responsePositionMismatch
    case manifestRevisionMismatch
    case failedPending
    case profileProvenanceMismatch
    case attemptPublicationAuthorityRequired
}

/// Durable top-level authority for one admitted Coach operation. Its identity,
/// intent, admission, and frozen semantic context stay stable while the nested
/// current Attempt is atomically replaced.
public struct CoachInvocation: Equatable, Sendable {
    public static let schemaVersion: UInt32 = 3

    public let persistedSchemaVersion: UInt32
    public let id: CoachInvocationID
    public let attempts: [CoachProviderAttempt]
    public let libraryID: LibraryID
    public let chatID: ChatID
    public let pendingUserTurnID: PendingUserTurnID
    public let draftID: ChatDraftID
    public let draftVersion: UInt64
    public let responsePositionID: ChatResponsePositionID
    public let preparedProfile: CoachProfileProvenance?
    public let expectedManifestRevision: UInt64
    public let admittedAt: UTCInstant

    public init(
        schemaVersion: UInt32 = Self.schemaVersion,
        id: CoachInvocationID,
        attempt: CoachProviderAttempt,
        library: LibraryScope,
        chatID: ChatID,
        pendingUserTurn: PendingUserTurn,
        preparedProfile: CoachProfileProvenance?,
        expectedManifestRevision: UInt64,
        admittedAt: UTCInstant
    ) throws {
        try self.init(
            schemaVersion: schemaVersion,
            id: id,
            attempts: [attempt],
            library: library,
            chatID: chatID,
            pendingUserTurn: pendingUserTurn,
            preparedProfile: preparedProfile,
            expectedManifestRevision: expectedManifestRevision,
            admittedAt: admittedAt
        )
    }

    public init(
        schemaVersion: UInt32,
        id: CoachInvocationID,
        attempts: [CoachProviderAttempt],
        library: LibraryScope,
        chatID: ChatID,
        pendingUserTurn: PendingUserTurn,
        preparedProfile: CoachProfileProvenance?,
        expectedManifestRevision: UInt64,
        admittedAt: UTCInstant
    ) throws {
        guard let attempt = attempts.last else {
            throw CoachInvocationError.attemptPublicationAuthorityRequired
        }
        guard attempts.count <= Int(CoachProviderAttempt.maximumOrdinal),
              attempts.enumerated().allSatisfy({ index, value in
                  value.ordinal == UInt8(index + 1) &&
                      (value.kind == .standard || index == attempts.count - 1)
              }),
              Set(attempts.map(\.id)).count == attempts.count,
              Set(attempts.map(\.providerIdempotencyValue)).count == attempts.count,
              Set(attempts.compactMap(\.userMessageID)).count ==
              attempts.compactMap(\.userMessageID).count,
              Set(attempts.compactMap(\.coachMessageID)).count ==
              attempts.compactMap(\.coachMessageID).count,
              Set(attempts.flatMap { attempt in
                  [attempt.userMessageID, attempt.coachMessageID].compactMap { $0 }
              }).count == attempts.flatMap({ attempt in
                  [attempt.userMessageID, attempt.coachMessageID].compactMap { $0 }
              }).count,
              Set(attempts.compactMap(\.freshDraftID)).count ==
              attempts.compactMap(\.freshDraftID).count,
              Set(attempts.flatMap(\.transcriptHandles)).count ==
              attempts.flatMap(\.transcriptHandles).count
        else { throw CoachInvocationError.attemptPublicationAuthorityRequired }
        switch (schemaVersion, preparedProfile, attempt.publicationAuthority) {
        case (1, nil, nil), (2, .some, nil), (Self.schemaVersion, .some, .some):
            break
        case (1, .some, _), (2, nil, _), (Self.schemaVersion, nil, _):
            throw CoachInvocationError.profileProvenanceMismatch
        case (Self.schemaVersion, .some, nil):
            throw CoachInvocationError.attemptPublicationAuthorityRequired
        default:
            throw CoachInvocationError.invalidSchemaVersion
        }
        if schemaVersion == Self.schemaVersion,
           attempts.contains(where: { $0.publicationAuthority == nil })
        {
            throw CoachInvocationError.attemptPublicationAuthorityRequired
        }
        persistedSchemaVersion = schemaVersion
        self.id = id
        self.attempts = attempts
        libraryID = library.libraryID
        self.chatID = chatID
        pendingUserTurnID = pendingUserTurn.id
        draftID = pendingUserTurn.draftID
        draftVersion = pendingUserTurn.draftVersion
        responsePositionID = pendingUserTurn.responsePositionID
        self.preparedProfile = preparedProfile
        self.expectedManifestRevision = expectedManifestRevision
        self.admittedAt = admittedAt
    }

    public var attempt: CoachProviderAttempt {
        // Every initializer rejects an empty durable sequence.
        attempts[attempts.count - 1]
    }

    public var attemptID: CoachProviderAttemptID { attempt.id }

    public var providerIdempotencyValue: ProviderIdempotencyValue {
        attempt.providerIdempotencyValue
    }

    /// Returns the same admitted Invocation authority with one newly persisted
    /// current Attempt. Callers still need an Infrastructure CAS against the
    /// previous exact value before launching the provider.
    public func installingAttempt(_ next: CoachProviderAttempt) throws -> Self {
        guard persistedSchemaVersion == Self.schemaVersion,
              preparedProfile != nil,
              next.publicationAuthority != nil,
              attempts.count < Int(CoachProviderAttempt.maximumOrdinal),
              next.ordinal == attempt.ordinal + 1,
              attempt.kind == .standard,
              Set(attempts.map(\.id)).isDisjoint(with: [next.id]),
              Set(attempts.map(\.providerIdempotencyValue)).isDisjoint(
                  with: [next.providerIdempotencyValue]
              ),
              Set(attempts.compactMap(\.userMessageID)).isDisjoint(
                  with: [next.userMessageID].compactMap { $0 }
              ),
              Set(attempts.compactMap(\.coachMessageID)).isDisjoint(
                  with: [next.coachMessageID].compactMap { $0 }
              ),
              Set(attempts.flatMap { attempt in
                  [attempt.userMessageID, attempt.coachMessageID].compactMap { $0 }
              }).isDisjoint(with: [
                  next.userMessageID,
                  next.coachMessageID,
              ].compactMap { $0 }),
              Set(attempts.compactMap(\.freshDraftID)).isDisjoint(
                  with: [next.freshDraftID].compactMap { $0 }
              ),
              Set(attempts.flatMap(\.transcriptHandles)).isDisjoint(
                  with: next.transcriptHandles
              ),
              next.transcriptHandles.count == attempt.transcriptHandles.count
        else { throw CoachInvocationError.attemptPublicationAuthorityRequired }
        return try CoachInvocation(
            schemaVersion: Self.schemaVersion,
            id: id,
            attempts: attempts + [next],
            library: LibraryScope(libraryID: libraryID),
            chatID: chatID,
            pendingUserTurn: PendingUserTurn(
                id: pendingUserTurnID,
                draftID: draftID,
                draftVersion: draftVersion,
                responsePositionID: responsePositionID
            ),
            preparedProfile: preparedProfile,
            expectedManifestRevision: expectedManifestRevision,
            admittedAt: admittedAt
        )
    }

    /// Validates the durable user intent independently of the Chat manifest CAS.
    /// Title-only metadata changes may advance the manifest while preserving this
    /// exact Pending/Draft/response authority, which recovery must still retire.
    public func validateIntent(against aggregate: ChatAggregate) throws {
        guard aggregate.chat.id == chatID else { throw CoachInvocationError.chatMismatch }
        guard let pending = aggregate.pendingUserTurn,
              pending.id == pendingUserTurnID
        else {
            throw CoachInvocationError.pendingMismatch
        }
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
    }

    public func validate(against aggregate: ChatAggregate) throws {
        try validateIntent(against: aggregate)
        guard aggregate.chat.manifestRevision == expectedManifestRevision else {
            throw CoachInvocationError.manifestRevisionMismatch
        }
    }
}

public enum InvocationPublicationError: Error, Equatable, Sendable {
    case responsePositionMismatch
    case userMessageRequired
    case coachMessageRequired
    case coachProfileProvenanceMismatch
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
        guard invocation.persistedSchemaVersion == CoachInvocation.schemaVersion,
              let attemptAuthority = invocation.attempt.publicationAuthority,
              attemptAuthority.userMessageID == userMessage.id,
              attemptAuthority.coachMessageID == coachMessage.id,
              attemptAuthority.freshDraftID == freshDraft.draftID,
              userMessage.persistedSchemaVersion == ChatMessage.schemaVersion,
              coachMessage.persistedSchemaVersion == ChatMessage.schemaVersion,
              let preparedProfile = invocation.preparedProfile,
              userMessage.coachProfile == nil,
              coachMessage.coachProfile == preparedProfile
        else {
            throw InvocationPublicationError.coachProfileProvenanceMismatch
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
