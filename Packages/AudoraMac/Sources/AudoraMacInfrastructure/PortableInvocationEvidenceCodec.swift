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

    func decodeInvocation(_ data: Data) throws -> CoachInvocation {
        guard data.count <= maximumRootBytes else {
            throw PortableChatPersistenceError.rootTooLarge
        }
        let dictionary = try json.jsonDictionary(data)
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
