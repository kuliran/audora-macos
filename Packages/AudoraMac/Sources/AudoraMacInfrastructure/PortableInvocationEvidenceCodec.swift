@_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
import CryptoKit
import Foundation

/// Canonical bytes gathered by persistence while it owns the publication
/// transaction. The codec alone decides how those bytes bind a durable proof.
struct PortableInvocationPublicationSourceEvidence {
    let publishedChat: Data
    let stableChat: Data
    let memory: Data
    let pendingUserTurn: Data
    let userMessage: Data
    let coachMessage: Data
    let freshDraft: Data
}

/// Bounded persisted evidence gathered under the Chat and Invocation locks.
/// Decoded values carry semantic identity while bytes preserve exact on-disk
/// authority; neither representation can substitute for the other.
struct PortableInvocationPublicationCurrentEvidence {
    let aggregate: ChatAggregate
    let canonicalChat: Data
    let stableChat: Data
    let memory: Data
    let freshDraft: Data
    let pendingUserTurnData: Data?
    let pendingUserTurn: PendingUserTurn?
    let userMessageData: Data
    let userMessage: ChatMessage
    let coachMessageData: Data
    let coachMessage: ChatMessage
}

/// The schema-stable identity shared by every supported and future Invocation
/// root. Its bounded bytes and narrowly indexed durable public IDs support
/// conservative collision checks when the version-specific body cannot decode.
/// Unknown body strings, including provider transport values, are never retained.
struct PortableInvocationCommonIdentityEnvelope {
    let schemaVersion: UInt64
    let invocationID: CoachInvocationID
    let libraryID: LibraryID
    let chatID: ChatID
    let rawBytes: Data
    private let attemptIDs: Set<CoachProviderAttemptID>
    private let messageIDs: Set<ChatMessageID>
    private let draftIDs: Set<ChatDraftID>

    init(
        schemaVersion: UInt64,
        invocationID: CoachInvocationID,
        libraryID: LibraryID,
        chatID: ChatID,
        rawBytes: Data,
        attemptIDs: Set<CoachProviderAttemptID>,
        messageIDs: Set<ChatMessageID>,
        draftIDs: Set<ChatDraftID>
    ) {
        self.schemaVersion = schemaVersion
        self.invocationID = invocationID
        self.libraryID = libraryID
        self.chatID = chatID
        self.rawBytes = rawBytes
        self.attemptIDs = attemptIDs
        self.messageIDs = messageIDs
        self.draftIDs = draftIDs
    }

    var hasSupportedBody: Bool {
        schemaVersion <= UInt64(CoachInvocation.schemaVersion)
    }

    func contains(_ attemptID: CoachProviderAttemptID) -> Bool {
        attemptIDs.contains(attemptID)
    }

    func contains(_ messageID: ChatMessageID) -> Bool {
        messageIDs.contains(messageID)
    }

    func contains(_ draftID: ChatDraftID) -> Bool {
        draftIDs.contains(draftID)
    }
}

/// The durable public namespaces exposed by a bounded Chat root. Only the
/// schema-stable `draft.draftId` and root `messageIds` values are retained;
/// Draft text and future private values remain opaque.
struct PortableChatDurablePublicIDs {
    let draftID: ChatDraftID
    let messageIDs: Set<ChatMessageID>

    func contains(_ messageID: ChatMessageID) -> Bool {
        messageIDs.contains(messageID)
    }

    func contains(_ draftID: ChatDraftID) -> Bool {
        self.draftID == draftID
    }
}

struct InvocationPublicationProof: Equatable {
    static let schemaVersion: UInt32 = 1

    let invocationID: CoachInvocationID
    let libraryID: LibraryID
    let chatID: ChatID
    let pendingUserTurnID: PendingUserTurnID
    let responsePositionID: ChatResponsePositionID
    let publishedManifestRevision: UInt64
    let publishedChatSHA256: String
    let stableChatSHA256: String
    let memorySHA256: String
    let pendingUserTurnSHA256: String
    let messageIDs: [ChatMessageID]
    let userMessageID: ChatMessageID
    let userMessageSHA256: String
    let coachMessageID: ChatMessageID
    let coachMessageSHA256: String
    let freshDraftID: ChatDraftID
    let freshDraftVersion: UInt64
    let freshDraftSHA256: String
}

/// Pure schema and exact-publication policy for durable Coach Invocation
/// evidence. Filesystem confinement and transaction ordering stay in
/// `PortableChatPersistence`; no proof rule is duplicated there.
struct PortableInvocationEvidenceCodec {
    let maximumRootBytes: Int
    let maximumMessageCount: Int

    private var json: ConfinedPersistencePrimitives<PortableChatPersistenceError> {
        ConfinedPersistencePrimitives(
            ioFailure: .ioFailure,
            invalidLayout: .invalidLayout,
            expectedPathIsSymlink: .expectedPathIsSymlink,
            rootTooLarge: .rootTooLarge,
            invalidJSON: .invalidJSON,
            invalidSchemaVersion: .invalidSchemaVersion,
            unknownKey: .unknownKey
        )
    }

    func encodeInvocation(_ invocation: CoachInvocation) throws -> Data {
        try boundedDeterministicJSON(CoachInvocationDTO(
            schemaVersion: invocation.persistedSchemaVersion,
            invocationId: invocation.id.rawValue,
            attemptId: invocation.persistedSchemaVersion < CoachInvocation.schemaVersion
                ? invocation.attemptID.rawValue
                : nil,
            providerIdempotencyValue: invocation.persistedSchemaVersion <
                CoachInvocation.schemaVersion
                ? invocation.providerIdempotencyValue?.rawValue
                : nil,
            attempts: invocation.persistedSchemaVersion == CoachInvocation.schemaVersion
                ? invocation.attempts.map(CoachProviderAttemptDTO.init)
                : nil,
            libraryId: invocation.libraryID.rawValue,
            chatId: invocation.chatID.rawValue,
            pendingUserTurnId: invocation.pendingUserTurnID.rawValue,
            draftId: invocation.draftID.rawValue,
            draftVersion: invocation.draftVersion,
            responsePositionId: invocation.responsePositionID.rawValue,
            expectedManifestRevision: invocation.expectedManifestRevision,
            profileRevisionId: invocation.preparedProfile?.revisionID?.rawValue,
            profileStatementGeneration: invocation.preparedProfile?.statementGeneration,
            admittedAt: invocation.admittedAt.rawValue,
            terminalFailure: invocation.terminalFailure?.rawValue
        ))
    }

    func decodeCommonInvocationIdentity(
        _ data: Data,
        expectedInvocationID: CoachInvocationID,
        expectedLibraryID: LibraryID
    ) throws -> PortableInvocationCommonIdentityEnvelope {
        guard data.count <= maximumRootBytes else {
            throw PortableChatPersistenceError.rootTooLarge
        }
        let publicIDs = try scanInvocationJSON(
            in: data,
            duplicatePolicy: .commonIdentityRoot
        )
        let dto = try json.decode(CoachInvocationCommonIdentityDTO.self, from: data)
        guard dto.schemaVersion >= 1 else {
            throw PortableChatPersistenceError.invalidSchemaVersion
        }
        return try mapPersistedDomainValidation {
            let invocationID = try CoachInvocationID(dto.invocationId)
            let libraryID = try LibraryID(dto.libraryId)
            let chatID = try ChatID(dto.chatId)
            guard invocationID == expectedInvocationID,
                  libraryID == expectedLibraryID
            else { throw PortableChatPersistenceError.invalidLayout }
            return PortableInvocationCommonIdentityEnvelope(
                schemaVersion: dto.schemaVersion,
                invocationID: invocationID,
                libraryID: libraryID,
                chatID: chatID,
                rawBytes: data,
                attemptIDs: publicIDs.attemptIDs,
                messageIDs: publicIDs.messageIDs,
                draftIDs: publicIDs.draftIDs
            )
        }
    }

    func decodeSupportedInvocation(
        _ identity: PortableInvocationCommonIdentityEnvelope
    ) throws -> CoachInvocation {
        guard identity.hasSupportedBody else {
            throw PortableChatPersistenceError.invalidSchemaVersion
        }
        let invocation = try decodeInvocation(identity.rawBytes)
        guard invocation.id == identity.invocationID,
              invocation.libraryID == identity.libraryID,
              invocation.chatID == identity.chatID
        else { throw PortableChatPersistenceError.invalidLayout }
        return invocation
    }

    func decodeChatDurablePublicIDs(_ data: Data) throws -> PortableChatDurablePublicIDs {
        guard data.count <= maximumRootBytes else {
            throw PortableChatPersistenceError.rootTooLarge
        }
        var scanner = PortableChatJSONScanner(data: data)
        let raw = try scanner.scan()
        guard raw.messageIDs.count <= maximumMessageCount else {
            throw PortableChatPersistenceError.invalidJSON
        }
        return try mapPersistedDomainValidation {
            PortableChatDurablePublicIDs(
                draftID: try ChatDraftID(raw.draftID),
                messageIDs: Set(try raw.messageIDs.map(ChatMessageID.init))
            )
        }
    }

    func decodeInvocation(_ data: Data) throws -> CoachInvocation {
        guard data.count <= maximumRootBytes else {
            throw PortableChatPersistenceError.rootTooLarge
        }
        let dictionary = try json.jsonDictionary(data)
        _ = try scanInvocationJSON(
            in: data,
            duplicatePolicy: .allObjects
        )
        let dto = try json.decode(CoachInvocationDTO.self, from: data)
        let common: Set<String> = [
            "schemaVersion", "invocationId", "libraryId", "chatId",
            "pendingUserTurnId", "draftId", "draftVersion",
            "responsePositionId", "expectedManifestRevision", "admittedAt",
        ]
        guard (1 ... CoachInvocation.schemaVersion).contains(dto.schemaVersion)
        else { throw PortableChatPersistenceError.invalidSchemaVersion }
        if dto.schemaVersion == 1 {
            try json.requireExactKeys(
                dictionary,
                common.union(["attemptId", "providerIdempotencyValue"])
            )
        } else if dto.schemaVersion == 2 {
            let v2 = common.union([
                "attemptId", "providerIdempotencyValue",
                "profileStatementGeneration",
            ])
            let actualKeys = Set(dictionary.keys)
            guard actualKeys == v2 || actualKeys == v2.union(["profileRevisionId"])
            else { throw PortableChatPersistenceError.unknownKey }
            if actualKeys.contains("profileRevisionId"),
               dictionary["profileRevisionId"] is NSNull
            {
                throw PortableChatPersistenceError.invalidJSON
            }
        } else {
            let v3 = common.union(["attempts", "profileStatementGeneration"])
            let actualKeys = Set(dictionary.keys)
            let allowedOptional: Set<String> = [
                "profileRevisionId", "terminalFailure",
            ]
            guard actualKeys.isSuperset(of: v3),
                  actualKeys.subtracting(v3).isSubset(of: allowedOptional)
            else { throw PortableChatPersistenceError.unknownKey }
            if actualKeys.contains("profileRevisionId"),
               dictionary["profileRevisionId"] is NSNull
            {
                throw PortableChatPersistenceError.invalidJSON
            }
            if actualKeys.contains("terminalFailure"),
               dictionary["terminalFailure"] is NSNull
            {
                throw PortableChatPersistenceError.invalidJSON
            }
            guard let rawAttempts = dictionary["attempts"] as? [[String: Any]],
                  !rawAttempts.isEmpty,
                  rawAttempts.count <= Int(CoachProviderAttempt.maximumOrdinal)
            else { throw PortableChatPersistenceError.invalidJSON }
            for rawAttempt in rawAttempts {
                try json.requireExactKeys(rawAttempt, [
                    "attemptId", "ordinal", "kind",
                    "userMessageId", "coachMessageId", "freshDraftId",
                ])
            }
        }
        return try mapPersistedDomainValidation {
            let pending = PendingUserTurn(
                id: try PendingUserTurnID(dto.pendingUserTurnId),
                draftID: try ChatDraftID(dto.draftId),
                draftVersion: dto.draftVersion,
                responsePositionID: try ChatResponsePositionID(dto.responsePositionId)
            )
            let preparedProfile: CoachProfileProvenance?
            if dto.schemaVersion == 1 {
                guard dto.profileRevisionId == nil,
                      dto.profileStatementGeneration == nil
                else { throw PortableChatPersistenceError.invalidJSON }
                preparedProfile = nil
            } else {
                guard let statementGeneration = dto.profileStatementGeneration else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                preparedProfile = CoachProfileProvenance(
                    revisionID: try dto.profileRevisionId.map(ProfileRevisionID.init),
                    statementGeneration: statementGeneration
                )
            }
            let attempts: [CoachProviderAttempt]
            if dto.schemaVersion == CoachInvocation.schemaVersion {
                guard dto.attemptId == nil,
                      dto.providerIdempotencyValue == nil,
                      let attemptDTOs = dto.attempts
                else { throw PortableChatPersistenceError.invalidJSON }
                attempts = try attemptDTOs.map { try $0.domainValue() }
            } else {
                guard let attemptID = dto.attemptId,
                      let idempotencyValue = dto.providerIdempotencyValue,
                      dto.attempts == nil
                else { throw PortableChatPersistenceError.invalidJSON }
                attempts = [try CoachProviderAttempt(
                    legacyID: try CoachProviderAttemptID(attemptID),
                    providerIdempotencyValue: try ProviderIdempotencyValue(
                        idempotencyValue
                    )
                )]
            }
            return try CoachInvocation(
                schemaVersion: dto.schemaVersion,
                id: try CoachInvocationID(dto.invocationId),
                attempts: attempts,
                library: LibraryScope(libraryID: try LibraryID(dto.libraryId)),
                chatID: ChatID(dto.chatId),
                pendingUserTurn: pending,
                preparedProfile: preparedProfile,
                expectedManifestRevision: dto.expectedManifestRevision,
                admittedAt: UTCInstant(dto.admittedAt),
                terminalFailure: try dto.terminalFailure.map { rawValue in
                    guard let failure = PendingUserTurnFailure(rawValue: rawValue) else {
                        throw PortableChatPersistenceError.invalidJSON
                    }
                    return failure
                }
            )
        }
    }

    func makePublicationProof(
        for mutation: PublishCoachInvocationMutation,
        evidence: PortableInvocationPublicationSourceEvidence
    ) throws -> InvocationPublicationProof {
        guard mutation.base.pendingUserTurn != nil else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let published = mutation.replacement
        return InvocationPublicationProof(
            invocationID: mutation.invocation.id,
            libraryID: mutation.invocation.libraryID,
            chatID: mutation.invocation.chatID,
            pendingUserTurnID: mutation.invocation.pendingUserTurnID,
            responsePositionID: mutation.invocation.responsePositionID,
            publishedManifestRevision: published.chat.manifestRevision,
            publishedChatSHA256: Self.sha256(evidence.publishedChat),
            stableChatSHA256: Self.sha256(evidence.stableChat),
            memorySHA256: Self.sha256(evidence.memory),
            pendingUserTurnSHA256: Self.sha256(evidence.pendingUserTurn),
            messageIDs: published.chat.messageIDs,
            userMessageID: mutation.userMessage.id,
            userMessageSHA256: Self.sha256(evidence.userMessage),
            coachMessageID: mutation.coachMessage.id,
            coachMessageSHA256: Self.sha256(evidence.coachMessage),
            freshDraftID: mutation.freshDraft.draftID,
            freshDraftVersion: mutation.freshDraft.version,
            freshDraftSHA256: Self.sha256(evidence.freshDraft)
        )
    }

    func encodePublicationProof(_ proof: InvocationPublicationProof) throws -> Data {
        try boundedDeterministicJSON(InvocationPublicationProofDTO(
            schemaVersion: InvocationPublicationProof.schemaVersion,
            invocationId: proof.invocationID.rawValue,
            libraryId: proof.libraryID.rawValue,
            chatId: proof.chatID.rawValue,
            pendingUserTurnId: proof.pendingUserTurnID.rawValue,
            responsePositionId: proof.responsePositionID.rawValue,
            publishedManifestRevision: proof.publishedManifestRevision,
            publishedChatSha256: proof.publishedChatSHA256,
            stableChatSha256: proof.stableChatSHA256,
            memorySha256: proof.memorySHA256,
            pendingUserTurnSha256: proof.pendingUserTurnSHA256,
            messageIds: proof.messageIDs.map(\.rawValue),
            userMessageId: proof.userMessageID.rawValue,
            userMessageSha256: proof.userMessageSHA256,
            coachMessageId: proof.coachMessageID.rawValue,
            coachMessageSha256: proof.coachMessageSHA256,
            freshDraftId: proof.freshDraftID.rawValue,
            freshDraftVersion: proof.freshDraftVersion,
            freshDraftSha256: proof.freshDraftSHA256
        ))
    }

    func decodePublicationProof(_ data: Data) throws -> InvocationPublicationProof {
        guard data.count <= maximumRootBytes else {
            throw PortableChatPersistenceError.rootTooLarge
        }
        let dictionary = try json.jsonDictionary(data)
        try json.requireExactKeys(dictionary, [
            "schemaVersion", "invocationId", "libraryId", "chatId",
            "pendingUserTurnId", "responsePositionId", "publishedManifestRevision",
            "publishedChatSha256", "stableChatSha256", "memorySha256",
            "pendingUserTurnSha256", "messageIds", "userMessageId",
            "userMessageSha256", "coachMessageId", "coachMessageSha256",
            "freshDraftId", "freshDraftVersion", "freshDraftSha256",
        ])
        let dto = try json.decode(InvocationPublicationProofDTO.self, from: data)
        guard dto.schemaVersion == InvocationPublicationProof.schemaVersion else {
            throw PortableChatPersistenceError.invalidSchemaVersion
        }
        guard Self.isSHA256(dto.publishedChatSha256),
              Self.isSHA256(dto.stableChatSha256),
              Self.isSHA256(dto.memorySha256),
              Self.isSHA256(dto.pendingUserTurnSha256),
              Self.isSHA256(dto.userMessageSha256),
              Self.isSHA256(dto.coachMessageSha256),
              Self.isSHA256(dto.freshDraftSha256),
              dto.messageIds.count <= maximumMessageCount
        else { throw PortableChatPersistenceError.invalidJSON }
        return try mapPersistedDomainValidation {
            InvocationPublicationProof(
                invocationID: try CoachInvocationID(dto.invocationId),
                libraryID: try LibraryID(dto.libraryId),
                chatID: try ChatID(dto.chatId),
                pendingUserTurnID: try PendingUserTurnID(dto.pendingUserTurnId),
                responsePositionID: try ChatResponsePositionID(dto.responsePositionId),
                publishedManifestRevision: dto.publishedManifestRevision,
                publishedChatSHA256: dto.publishedChatSha256,
                stableChatSHA256: dto.stableChatSha256,
                memorySHA256: dto.memorySha256,
                pendingUserTurnSHA256: dto.pendingUserTurnSha256,
                messageIDs: try dto.messageIds.map(ChatMessageID.init),
                userMessageID: try ChatMessageID(dto.userMessageId),
                userMessageSHA256: dto.userMessageSha256,
                coachMessageID: try ChatMessageID(dto.coachMessageId),
                coachMessageSHA256: dto.coachMessageSha256,
                freshDraftID: try ChatDraftID(dto.freshDraftId),
                freshDraftVersion: dto.freshDraftVersion,
                freshDraftSHA256: dto.freshDraftSha256
            )
        }
    }

    func proof(
        _ proof: InvocationPublicationProof,
        isBoundTo invocation: CoachInvocation
    ) -> Bool {
        let (publishedRevision, overflow) = invocation.expectedManifestRevision
            .addingReportingOverflow(1)
        let hasVersionSpecificAuthority: Bool
        switch invocation.persistedSchemaVersion {
        case 2:
            // The prior binary's v2 record did not persist Attempt publication
            // authority. Its proof remains bound by the exact Chat, Pending,
            // message hashes/order, fresh Draft, and Profile checks below.
            hasVersionSpecificAuthority = invocation.preparedProfile != nil
        case CoachInvocation.schemaVersion:
            hasVersionSpecificAuthority = invocation.preparedProfile != nil &&
                invocation.attempt.userMessageID == proof.userMessageID &&
                invocation.attempt.coachMessageID == proof.coachMessageID &&
                invocation.attempt.freshDraftID == proof.freshDraftID
        default:
            hasVersionSpecificAuthority = false
        }
        return !overflow &&
            hasVersionSpecificAuthority &&
            proof.invocationID == invocation.id &&
            proof.libraryID == invocation.libraryID &&
            proof.chatID == invocation.chatID &&
            proof.pendingUserTurnID == invocation.pendingUserTurnID &&
            proof.responsePositionID == invocation.responsePositionID &&
            proof.publishedManifestRevision == publishedRevision &&
            proof.freshDraftVersion == 0 &&
            proof.userMessageID != proof.coachMessageID &&
            proof.messageIDs.count >= 2 &&
            Array(proof.messageIDs.suffix(2)) == [
                proof.userMessageID,
                proof.coachMessageID,
            ]
    }

    func isExactPublishedInvocation(
        _ proof: InvocationPublicationProof,
        invocation: CoachInvocation,
        evidence: PortableInvocationPublicationCurrentEvidence
    ) -> Bool {
        let current = evidence.aggregate.chat
        let user = evidence.userMessage
        let coach = evidence.coachMessage
        guard self.proof(proof, isBoundTo: invocation),
              current.id == proof.chatID,
              evidence.aggregate.pendingUserTurn == nil,
              current.manifestRevision >= proof.publishedManifestRevision,
              current.messageIDs == proof.messageIDs,
              current.draft.draftID == proof.freshDraftID,
              current.draft.version >= proof.freshDraftVersion,
              Self.sha256(evidence.stableChat) == proof.stableChatSHA256,
              Self.sha256(evidence.memory) == proof.memorySHA256,
              Self.sha256(evidence.userMessageData) == proof.userMessageSHA256,
              Self.sha256(evidence.coachMessageData) == proof.coachMessageSHA256,
              user.id == proof.userMessageID,
              coach.id == proof.coachMessageID,
              user.responsePositionID == invocation.responsePositionID,
              coach.responsePositionID == invocation.responsePositionID,
              user.persistedSchemaVersion == ChatMessage.schemaVersion,
              coach.persistedSchemaVersion == ChatMessage.schemaVersion,
              user.coachProfile == nil,
              coach.coachProfile == invocation.preparedProfile,
              case .user = user.content,
              case .coach = coach.content
        else { return false }
        if current.manifestRevision == proof.publishedManifestRevision,
           Self.sha256(evidence.canonicalChat) != proof.publishedChatSHA256
        {
            return false
        }
        if current.draft.version == proof.freshDraftVersion,
           Self.sha256(evidence.freshDraft) != proof.freshDraftSHA256
        {
            return false
        }
        if let pendingData = evidence.pendingUserTurnData {
            guard Self.sha256(pendingData) == proof.pendingUserTurnSHA256,
                  let pending = evidence.pendingUserTurn,
                  pending.id == invocation.pendingUserTurnID,
                  pending.draftID == invocation.draftID,
                  pending.draftVersion == invocation.draftVersion,
                  pending.responsePositionID == invocation.responsePositionID,
                  invocation.persistedSchemaVersion < CoachInvocation.schemaVersion ||
                  pending.failure == nil
            else { return false }
        } else if evidence.pendingUserTurn != nil {
            return false
        }
        return true
    }

    private func boundedDeterministicJSON<T: Encodable>(_ value: T) throws -> Data {
        let data = try json.deterministicJSON(value)
        guard data.count <= maximumRootBytes else {
            throw PortableChatPersistenceError.rootTooLarge
        }
        return data
    }

    /// Foundation accepts duplicate object keys. The common pass rejects only
    /// duplicate root routing keys, while a supported body rejects duplicates
    /// at every object depth. The bounded walk decodes values only under the
    /// four durable-public-ID field names; all unknown body values are skipped.
    private func scanInvocationJSON(
        in data: Data,
        duplicatePolicy: PortableInvocationJSONDuplicatePolicy
    ) throws -> PortableInvocationDurablePublicIDs {
        var scanner = PortableInvocationJSONScanner(
            data: data,
            duplicatePolicy: duplicatePolicy
        )
        return try scanner.scan()
    }

    private func mapPersistedDomainValidation<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let error as PortableChatPersistenceError {
            throw error
        } catch {
            throw PortableChatPersistenceError.invalidJSON
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }
}

private struct PortableChatRawDurablePublicIDs {
    let draftID: String
    let messageIDs: [String]
}

/// A path-aware bounded scan of the two Chat-root public namespaces. Values at
/// every other path are advanced over without constructing a Swift String.
private struct PortableChatJSONScanner {
    private static let maximumContainerDepth = 128

    private enum ObjectContext {
        case root
        case draft
        case opaque
    }

    private let bytes: [UInt8]
    private var index = 0
    private var draftID: String?
    private var messageIDs: [String]?

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func scan() throws -> PortableChatRawDurablePublicIDs {
        skipWhitespace()
        try parseObject(depth: 0, context: .root)
        skipWhitespace()
        guard index == bytes.count,
              let draftID,
              let messageIDs
        else { throw PortableChatPersistenceError.invalidJSON }
        return PortableChatRawDurablePublicIDs(
            draftID: draftID,
            messageIDs: messageIDs
        )
    }

    private mutating func parseObject(
        depth: Int,
        context: ObjectContext
    ) throws {
        guard depth < Self.maximumContainerDepth,
              index < bytes.count,
              bytes[index] == 0x7B
        else { throw PortableChatPersistenceError.invalidJSON }
        index += 1
        skipWhitespace()
        if consume(0x7D) {
            if context == .draft {
                throw PortableChatPersistenceError.invalidJSON
            }
            return
        }

        var keys: Set<String> = []
        while true {
            let key = try requiredJSONString()
            if !keys.insert(key).inserted,
               isRelevant(key, in: context)
            {
                throw PortableChatPersistenceError.invalidJSON
            }
            skipWhitespace()
            guard consume(0x3A) else {
                throw PortableChatPersistenceError.invalidJSON
            }
            skipWhitespace()
            switch (context, key) {
            case (.root, "draft"):
                guard draftID == nil else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                try parseObject(depth: depth + 1, context: .draft)
            case (.root, "messageIds"):
                guard messageIDs == nil else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                messageIDs = try parseMessageIDs(depth: depth + 1)
            case (.draft, "draftId"):
                guard draftID == nil else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                draftID = try requiredJSONString()
            default:
                try parseValue(depth: depth + 1)
            }
            skipWhitespace()
            if consume(0x7D) {
                if context == .draft, draftID == nil {
                    throw PortableChatPersistenceError.invalidJSON
                }
                return
            }
            guard consume(0x2C) else {
                throw PortableChatPersistenceError.invalidJSON
            }
            skipWhitespace()
            guard index < bytes.count, bytes[index] != 0x7D else {
                throw PortableChatPersistenceError.invalidJSON
            }
        }
    }

    private mutating func parseMessageIDs(depth: Int) throws -> [String] {
        guard depth < Self.maximumContainerDepth,
              index < bytes.count,
              bytes[index] == 0x5B
        else { throw PortableChatPersistenceError.invalidJSON }
        index += 1
        skipWhitespace()
        if consume(0x5D) { return [] }

        var values: [String] = []
        while true {
            values.append(try requiredJSONString())
            skipWhitespace()
            if consume(0x5D) { return values }
            guard consume(0x2C) else {
                throw PortableChatPersistenceError.invalidJSON
            }
            skipWhitespace()
            guard index < bytes.count, bytes[index] != 0x5D else {
                throw PortableChatPersistenceError.invalidJSON
            }
        }
    }

    private mutating func parseArray(depth: Int) throws {
        guard depth < Self.maximumContainerDepth,
              index < bytes.count,
              bytes[index] == 0x5B
        else { throw PortableChatPersistenceError.invalidJSON }
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }

        while true {
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else {
                throw PortableChatPersistenceError.invalidJSON
            }
            skipWhitespace()
            guard index < bytes.count, bytes[index] != 0x5D else {
                throw PortableChatPersistenceError.invalidJSON
            }
        }
    }

    private mutating func parseValue(depth: Int) throws {
        guard index < bytes.count else {
            throw PortableChatPersistenceError.invalidJSON
        }
        switch bytes[index] {
        case 0x22:
            try skipJSONString()
        case 0x7B:
            try parseObject(depth: depth, context: .opaque)
        case 0x5B:
            try parseArray(depth: depth)
        default:
            try parsePrimitive()
        }
    }

    private mutating func requiredJSONString() throws -> String {
        guard let value = try parseJSONString(materialize: true) else {
            throw PortableChatPersistenceError.invalidJSON
        }
        return value
    }

    private mutating func skipJSONString() throws {
        _ = try parseJSONString(materialize: false)
    }

    private mutating func parseJSONString(materialize: Bool) throws -> String? {
        guard index < bytes.count, bytes[index] == 0x22 else {
            throw PortableChatPersistenceError.invalidJSON
        }
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                guard materialize else { return nil }
                do {
                    return try JSONDecoder().decode(
                        String.self,
                        from: Data(bytes[start ..< index])
                    )
                } catch {
                    throw PortableChatPersistenceError.invalidJSON
                }
            }
            if byte == 0x5C {
                index += 1
                guard index < bytes.count else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                switch bytes[index] {
                case 0x22, 0x2F, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    index += 1
                case 0x75:
                    let first = try parseUnicodeEscape()
                    if (0xD800 ... 0xDBFF).contains(first) {
                        guard index + 5 < bytes.count,
                              bytes[index] == 0x5C,
                              bytes[index + 1] == 0x75
                        else { throw PortableChatPersistenceError.invalidJSON }
                        index += 1
                        let second = try parseUnicodeEscape()
                        guard (0xDC00 ... 0xDFFF).contains(second) else {
                            throw PortableChatPersistenceError.invalidJSON
                        }
                    } else if (0xDC00 ... 0xDFFF).contains(first) {
                        throw PortableChatPersistenceError.invalidJSON
                    }
                default:
                    throw PortableChatPersistenceError.invalidJSON
                }
                continue
            }
            guard byte >= 0x20 else {
                throw PortableChatPersistenceError.invalidJSON
            }
            try advanceUTF8Scalar()
        }
        throw PortableChatPersistenceError.invalidJSON
    }

    private mutating func parsePrimitive() throws {
        if consumeLiteral([0x74, 0x72, 0x75, 0x65]) ||
            consumeLiteral([0x66, 0x61, 0x6C, 0x73, 0x65]) ||
            consumeLiteral([0x6E, 0x75, 0x6C, 0x6C])
        {
            return
        }
        try parseNumber()
    }

    private mutating func parseNumber() throws {
        if consume(0x2D), index == bytes.count {
            throw PortableChatPersistenceError.invalidJSON
        }
        guard index < bytes.count else {
            throw PortableChatPersistenceError.invalidJSON
        }
        if consume(0x30) {
            guard index == bytes.count || !Self.isDigit(bytes[index]) else {
                throw PortableChatPersistenceError.invalidJSON
            }
        } else {
            guard (0x31 ... 0x39).contains(bytes[index]) else {
                throw PortableChatPersistenceError.invalidJSON
            }
            repeat { index += 1 } while index < bytes.count && Self.isDigit(bytes[index])
        }
        if consume(0x2E) {
            guard index < bytes.count, Self.isDigit(bytes[index]) else {
                throw PortableChatPersistenceError.invalidJSON
            }
            repeat { index += 1 } while index < bytes.count && Self.isDigit(bytes[index])
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
                index += 1
            }
            guard index < bytes.count, Self.isDigit(bytes[index]) else {
                throw PortableChatPersistenceError.invalidJSON
            }
            repeat { index += 1 } while index < bytes.count && Self.isDigit(bytes[index])
        }
    }

    private mutating func parseUnicodeEscape() throws -> UInt16 {
        guard index + 4 < bytes.count,
              bytes[index] == 0x75,
              bytes[(index + 1) ... (index + 4)].allSatisfy(Self.isHex)
        else { throw PortableChatPersistenceError.invalidJSON }
        var value: UInt16 = 0
        for byte in bytes[(index + 1) ... (index + 4)] {
            value = value * 16 + UInt16(Self.hexValue(byte))
        }
        index += 5
        return value
    }

    private mutating func advanceUTF8Scalar() throws {
        let first = bytes[index]
        if first <= 0x7F {
            index += 1
            return
        }
        let continuationCount: Int
        let secondRange: ClosedRange<UInt8>
        switch first {
        case 0xC2 ... 0xDF:
            continuationCount = 1
            secondRange = 0x80 ... 0xBF
        case 0xE0:
            continuationCount = 2
            secondRange = 0xA0 ... 0xBF
        case 0xE1 ... 0xEC, 0xEE ... 0xEF:
            continuationCount = 2
            secondRange = 0x80 ... 0xBF
        case 0xED:
            continuationCount = 2
            secondRange = 0x80 ... 0x9F
        case 0xF0:
            continuationCount = 3
            secondRange = 0x90 ... 0xBF
        case 0xF1 ... 0xF3:
            continuationCount = 3
            secondRange = 0x80 ... 0xBF
        case 0xF4:
            continuationCount = 3
            secondRange = 0x80 ... 0x8F
        default:
            throw PortableChatPersistenceError.invalidJSON
        }
        guard index + continuationCount < bytes.count,
              secondRange.contains(bytes[index + 1])
        else { throw PortableChatPersistenceError.invalidJSON }
        if continuationCount > 1 {
            for offset in 2 ... continuationCount {
                guard (0x80 ... 0xBF).contains(bytes[index + offset]) else {
                    throw PortableChatPersistenceError.invalidJSON
                }
            }
        }
        index += continuationCount + 1
    }

    private mutating func consumeLiteral(_ literal: [UInt8]) -> Bool {
        guard index + literal.count <= bytes.count,
              Array(bytes[index ..< (index + literal.count)]) == literal
        else { return false }
        index += literal.count
        return true
    }

    private func isRelevant(_ key: String, in context: ObjectContext) -> Bool {
        switch context {
        case .root:
            key == "draft" || key == "messageIds"
        case .draft:
            key == "draftId"
        case .opaque:
            false
        }
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            default:
                return
            }
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) ||
            (65 ... 70).contains(byte) ||
            (97 ... 102).contains(byte)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8 {
        switch byte {
        case 48 ... 57:
            byte - 48
        case 65 ... 70:
            byte - 55
        default:
            byte - 87
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte)
    }
}

private enum PortableInvocationJSONDuplicatePolicy {
    case commonIdentityRoot
    case allObjects
}

private struct PortableInvocationDurablePublicIDs {
    var attemptIDs: Set<CoachProviderAttemptID> = []
    var messageIDs: Set<ChatMessageID> = []
    var draftIDs: Set<ChatDraftID> = []

    mutating func insert(_ value: String, for key: String) {
        switch key {
        case "attemptId":
            if let id = try? CoachProviderAttemptID(value) {
                attemptIDs.insert(id)
            }
        case "userMessageId", "coachMessageId":
            if let id = try? ChatMessageID(value) {
                messageIDs.insert(id)
            }
        case "draftId", "freshDraftId":
            if let id = try? ChatDraftID(value) {
                draftIDs.insert(id)
            }
        default:
            break
        }
    }
}

/// A syntax-bounded routing scanner. It materializes object keys so duplicate
/// policy can be enforced, but materializes a string value only when its key is
/// one of the durable public-ID fields. In particular, values below future
/// provider transport keys are advanced over without creating a Swift String.
private struct PortableInvocationJSONScanner {
    private static let commonIdentityKeys: Set<String> = [
        "schemaVersion", "invocationId", "libraryId", "chatId",
    ]
    private static let durablePublicIDKeys: Set<String> = [
        "attemptId", "userMessageId", "coachMessageId", "draftId", "freshDraftId",
    ]
    private static let maximumContainerDepth = 128

    private let bytes: [UInt8]
    private let duplicatePolicy: PortableInvocationJSONDuplicatePolicy
    private var index = 0
    private var publicIDs = PortableInvocationDurablePublicIDs()

    init(data: Data, duplicatePolicy: PortableInvocationJSONDuplicatePolicy) {
        bytes = Array(data)
        self.duplicatePolicy = duplicatePolicy
    }

    mutating func scan() throws -> PortableInvocationDurablePublicIDs {
        skipWhitespace()
        try parseObject(depth: 0)
        skipWhitespace()
        guard index == bytes.count else {
            throw PortableChatPersistenceError.invalidJSON
        }
        return publicIDs
    }

    private mutating func parseObject(depth: Int) throws {
        guard depth < Self.maximumContainerDepth,
              index < bytes.count,
              bytes[index] == 0x7B
        else { throw PortableChatPersistenceError.invalidJSON }
        index += 1
        skipWhitespace()
        if consume(0x7D) { return }

        var keys: Set<String> = []
        while true {
            let key = try parseJSONString(materialize: true)
            guard let key else {
                throw PortableChatPersistenceError.invalidJSON
            }
            if !keys.insert(key).inserted, rejectsDuplicate(key, depth: depth) {
                throw PortableChatPersistenceError.invalidJSON
            }
            skipWhitespace()
            guard consume(0x3A) else {
                throw PortableChatPersistenceError.invalidJSON
            }
            skipWhitespace()
            try parseValue(
                depth: depth + 1,
                publicIDKey: Self.durablePublicIDKeys.contains(key) ? key : nil
            )
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else {
                throw PortableChatPersistenceError.invalidJSON
            }
            skipWhitespace()
            guard index < bytes.count, bytes[index] != 0x7D else {
                throw PortableChatPersistenceError.invalidJSON
            }
        }
    }

    private mutating func parseArray(depth: Int) throws {
        guard depth < Self.maximumContainerDepth,
              index < bytes.count,
              bytes[index] == 0x5B
        else { throw PortableChatPersistenceError.invalidJSON }
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }

        while true {
            try parseValue(depth: depth + 1, publicIDKey: nil)
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else {
                throw PortableChatPersistenceError.invalidJSON
            }
            skipWhitespace()
            guard index < bytes.count, bytes[index] != 0x5D else {
                throw PortableChatPersistenceError.invalidJSON
            }
        }
    }

    private mutating func parseValue(
        depth: Int,
        publicIDKey: String?
    ) throws {
        guard index < bytes.count else {
            throw PortableChatPersistenceError.invalidJSON
        }
        switch bytes[index] {
        case 0x22:
            let value = try parseJSONString(materialize: publicIDKey != nil)
            if let publicIDKey, let value {
                publicIDs.insert(value, for: publicIDKey)
            }
        case 0x7B:
            try parseObject(depth: depth)
        case 0x5B:
            try parseArray(depth: depth)
        default:
            try parsePrimitive()
        }
    }

    private mutating func parseJSONString(materialize: Bool) throws -> String? {
        guard index < bytes.count, bytes[index] == 0x22 else {
            throw PortableChatPersistenceError.invalidJSON
        }
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                guard materialize else { return nil }
                do {
                    return try JSONDecoder().decode(
                        String.self,
                        from: Data(bytes[start ..< index])
                    )
                } catch {
                    throw PortableChatPersistenceError.invalidJSON
                }
            }
            if byte == 0x5C {
                index += 1
                guard index < bytes.count else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                switch bytes[index] {
                case 0x22, 0x2F, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    index += 1
                case 0x75:
                    guard index + 4 < bytes.count,
                          bytes[(index + 1) ... (index + 4)].allSatisfy(Self.isHex)
                    else { throw PortableChatPersistenceError.invalidJSON }
                    index += 5
                default:
                    throw PortableChatPersistenceError.invalidJSON
                }
                continue
            }
            guard byte >= 0x20 else {
                throw PortableChatPersistenceError.invalidJSON
            }
            index += 1
        }
        throw PortableChatPersistenceError.invalidJSON
    }

    private mutating func parsePrimitive() throws {
        let start = index
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D:
                guard index > start else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                return
            default:
                index += 1
            }
        }
        guard index > start else {
            throw PortableChatPersistenceError.invalidJSON
        }
    }

    private func rejectsDuplicate(_ key: String, depth: Int) -> Bool {
        switch duplicatePolicy {
        case .commonIdentityRoot:
            depth == 0 && Self.commonIdentityKeys.contains(key)
        case .allObjects:
            true
        }
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            default:
                return
            }
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) ||
            (65 ... 70).contains(byte) ||
            (97 ... 102).contains(byte)
    }
}

private struct CoachInvocationDTO: Codable {
    let schemaVersion: UInt32
    let invocationId: String
    let attemptId: String?
    let providerIdempotencyValue: String?
    let attempts: [CoachProviderAttemptDTO]?
    let libraryId: String
    let chatId: String
    let pendingUserTurnId: String
    let draftId: String
    let draftVersion: UInt64
    let responsePositionId: String
    let expectedManifestRevision: UInt64
    let profileRevisionId: String?
    let profileStatementGeneration: UInt64?
    let admittedAt: String
    let terminalFailure: String?
}

private struct CoachInvocationCommonIdentityDTO: Decodable {
    let schemaVersion: UInt64
    let invocationId: String
    let libraryId: String
    let chatId: String
}

private struct CoachProviderAttemptDTO: Codable {
    let attemptId: String
    let ordinal: UInt8
    let kind: String
    let userMessageId: String
    let coachMessageId: String
    let freshDraftId: String

    init(_ attempt: CoachProviderAttempt) {
        guard let authority = attempt.publicationAuthority else {
            preconditionFailure("current Coach Attempts require publication authority")
        }
        attemptId = attempt.id.rawValue
        ordinal = attempt.ordinal
        kind = attempt.kind.rawValue
        userMessageId = authority.userMessageID.rawValue
        coachMessageId = authority.coachMessageID.rawValue
        freshDraftId = authority.freshDraftID.rawValue
    }

    func domainValue() throws -> CoachProviderAttempt {
        guard let parsedKind = CoachProviderAttemptKind(rawValue: kind)
        else { throw PortableChatPersistenceError.invalidJSON }
        return try CoachProviderAttempt(
            durableID: CoachProviderAttemptID(attemptId),
            ordinal: ordinal,
            kind: parsedKind,
            publicationAuthority: CoachProviderAttemptPublicationAuthority(
                userMessageID: ChatMessageID(userMessageId),
                coachMessageID: ChatMessageID(coachMessageId),
                freshDraftID: ChatDraftID(freshDraftId)
            )
        )
    }
}

private struct InvocationPublicationProofDTO: Codable {
    let schemaVersion: UInt32
    let invocationId: String
    let libraryId: String
    let chatId: String
    let pendingUserTurnId: String
    let responsePositionId: String
    let publishedManifestRevision: UInt64
    let publishedChatSha256: String
    let stableChatSha256: String
    let memorySha256: String
    let pendingUserTurnSha256: String
    let messageIds: [String]
    let userMessageId: String
    let userMessageSha256: String
    let coachMessageId: String
    let coachMessageSha256: String
    let freshDraftId: String
    let freshDraftVersion: UInt64
    let freshDraftSha256: String
}
