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
    case invalidOrdinal
    case repairMustFollowAnEarlierAttempt
    case duplicateMessageID
    case duplicateTranscriptHandle
}

/// Process-live provider transport authority. These opaque values are never a
/// durable part of an Attempt; relaunch retires work instead of reconstructing
/// or resuming this capability.
public struct CoachProviderAttemptTransportAuthority: Equatable, Sendable {
    public let providerIdempotencyValue: ProviderIdempotencyValue
    public let transcriptHandles: [CoachProviderTranscriptHandle]

    public init(
        providerIdempotencyValue: ProviderIdempotencyValue,
        transcriptHandles: [CoachProviderTranscriptHandle]
    ) throws {
        guard transcriptHandles.count <= CoachProviderAttempt.maximumTranscriptHandles,
              Set(transcriptHandles).count == transcriptHandles.count
        else { throw CoachProviderAttemptError.duplicateTranscriptHandle }
        self.providerIdempotencyValue = providerIdempotencyValue
        self.transcriptHandles = transcriptHandles
    }
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
    public static let maximumOrdinal: UInt8 = 4
    public static let maximumTranscriptHandles = 128

    public let id: CoachProviderAttemptID
    public let ordinal: UInt8
    public let kind: CoachProviderAttemptKind
    public let publicationAuthority: CoachProviderAttemptPublicationAuthority?
    public let transportAuthority: CoachProviderAttemptTransportAuthority?

    public init(
        id: CoachProviderAttemptID,
        ordinal: UInt8,
        kind: CoachProviderAttemptKind,
        providerIdempotencyValue: ProviderIdempotencyValue,
        transcriptHandles: [CoachProviderTranscriptHandle],
        publicationAuthority: CoachProviderAttemptPublicationAuthority
    ) throws {
        try Self.validate(ordinal: ordinal, kind: kind)
        self.id = id
        self.ordinal = ordinal
        self.kind = kind
        self.publicationAuthority = publicationAuthority
        transportAuthority = try CoachProviderAttemptTransportAuthority(
            providerIdempotencyValue: providerIdempotencyValue,
            transcriptHandles: transcriptHandles
        )
    }

    /// Reconstitutes only the safe durable projection embedded by Invocation
    /// schema v3. No provider transport authority can be recovered from disk.
    public init(
        durableID id: CoachProviderAttemptID,
        ordinal: UInt8,
        kind: CoachProviderAttemptKind,
        publicationAuthority: CoachProviderAttemptPublicationAuthority
    ) throws {
        try Self.validate(ordinal: ordinal, kind: kind)
        self.id = id
        self.ordinal = ordinal
        self.kind = kind
        self.publicationAuthority = publicationAuthority
        transportAuthority = nil
    }

    public init(
        legacyID: CoachProviderAttemptID,
        providerIdempotencyValue: ProviderIdempotencyValue
    ) throws {
        id = legacyID
        ordinal = 1
        kind = .standard
        publicationAuthority = nil
        transportAuthority = try CoachProviderAttemptTransportAuthority(
            providerIdempotencyValue: providerIdempotencyValue,
            transcriptHandles: []
        )
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
        ordinal: UInt8,
        kind: CoachProviderAttemptKind
    ) throws {
        guard (1 ... Self.maximumOrdinal).contains(ordinal) else {
            throw CoachProviderAttemptError.invalidOrdinal
        }
        guard kind != .shorterRepair || ordinal > 1 else {
            throw CoachProviderAttemptError.repairMustFollowAnEarlierAttempt
        }
    }

    public func removingTransportAuthority() throws -> Self {
        guard let publicationAuthority else {
            // Legacy v1/v2 records remain flat at the Invocation root and are
            // never upgraded by projecting a nested v3 Attempt.
            return self
        }
        return try CoachProviderAttempt(
            durableID: id,
            ordinal: ordinal,
            kind: kind,
            publicationAuthority: publicationAuthority
        )
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
    case invalidTerminalFailure
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
    public let terminalFailure: PendingUserTurnFailure?

    public init(
        schemaVersion: UInt32 = Self.schemaVersion,
        id: CoachInvocationID,
        attempt: CoachProviderAttempt,
        library: LibraryScope,
        chatID: ChatID,
        pendingUserTurn: PendingUserTurn,
        preparedProfile: CoachProfileProvenance?,
        expectedManifestRevision: UInt64,
        admittedAt: UTCInstant,
        terminalFailure: PendingUserTurnFailure? = nil
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
            admittedAt: admittedAt,
            terminalFailure: terminalFailure
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
        admittedAt: UTCInstant,
        terminalFailure: PendingUserTurnFailure? = nil
    ) throws {
        guard let attempt = attempts.last else {
            throw CoachInvocationError.attemptPublicationAuthorityRequired
        }
        let transportAuthorities = attempts.compactMap(\.transportAuthority)
        guard attempts.count <= Int(CoachProviderAttempt.maximumOrdinal),
              attempts.enumerated().allSatisfy({ index, value in
                  value.ordinal == UInt8(index + 1) &&
                      (value.kind == .standard || index == attempts.count - 1)
              }),
              Set(attempts.map(\.id)).count == attempts.count,
              transportAuthorities.isEmpty ||
              transportAuthorities.count == attempts.count,
              Set(transportAuthorities.map(\.providerIdempotencyValue)).count ==
              transportAuthorities.count,
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
              Set(transportAuthorities.flatMap(\.transcriptHandles)).count ==
              transportAuthorities.flatMap(\.transcriptHandles).count
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
        guard terminalFailure != .coachContextCannotFit,
              schemaVersion == Self.schemaVersion || terminalFailure == nil
        else { throw CoachInvocationError.invalidTerminalFailure }
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
        self.terminalFailure = terminalFailure
    }

    public var attempt: CoachProviderAttempt {
        // Every initializer rejects an empty durable sequence.
        attempts[attempts.count - 1]
    }

    public var attemptID: CoachProviderAttemptID { attempt.id }

    public var providerIdempotencyValue: ProviderIdempotencyValue? {
        attempt.transportAuthority?.providerIdempotencyValue
    }

    /// Returns the same admitted Invocation authority with one newly persisted
    /// current Attempt. Callers still need an Infrastructure CAS against the
    /// previous exact value before launching the provider.
    public func installingAttempt(_ next: CoachProviderAttempt) throws -> Self {
        guard persistedSchemaVersion == Self.schemaVersion,
              terminalFailure == nil,
              preparedProfile != nil,
              next.publicationAuthority != nil,
              let nextTransport = next.transportAuthority,
              let currentTransport = attempt.transportAuthority,
              attempts.allSatisfy({ $0.transportAuthority != nil }),
              attempts.count < Int(CoachProviderAttempt.maximumOrdinal),
              next.ordinal == attempt.ordinal + 1,
              attempt.kind == .standard,
              Set(attempts.map(\.id)).isDisjoint(with: [next.id]),
              Set(attempts.compactMap {
                  $0.transportAuthority?.providerIdempotencyValue
              }).isDisjoint(
                  with: [nextTransport.providerIdempotencyValue]
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
              Set(attempts.compactMap(\.transportAuthority).flatMap(
                  \.transcriptHandles
              )).isDisjoint(
                  with: nextTransport.transcriptHandles
              ),
              nextTransport.transcriptHandles.count ==
              currentTransport.transcriptHandles.count
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

    /// Safe schema-v3 disk representation. Transport authority intentionally
    /// disappears; every other immutable binding remains exact.
    public func durableProjection() throws -> Self {
        guard persistedSchemaVersion == Self.schemaVersion else { return self }
        return try CoachInvocation(
            schemaVersion: persistedSchemaVersion,
            id: id,
            attempts: try attempts.map { try $0.removingTransportAuthority() },
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
            admittedAt: admittedAt,
            terminalFailure: terminalFailure
        )
    }

    public func hasSameDurableProjection(as other: Self) -> Bool {
        guard let left = try? durableProjection(),
              let right = try? other.durableProjection()
        else { return false }
        return left == right
    }

    /// Records the exact typed terminal write that recovery must finish. The
    /// Invocation remains the durable authority until its Pending mutation and
    /// retirement are both reconciled.
    public func recordingTerminalFailure(
        _ failure: PendingUserTurnFailure
    ) throws -> Self {
        guard persistedSchemaVersion == Self.schemaVersion,
              failure != .coachContextCannotFit,
              terminalFailure == nil || terminalFailure == failure
        else { throw CoachInvocationError.invalidTerminalFailure }
        return try CoachInvocation(
            schemaVersion: persistedSchemaVersion,
            id: id,
            attempts: attempts,
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
            admittedAt: admittedAt,
            terminalFailure: failure
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
              invocation.terminalFailure == nil,
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
