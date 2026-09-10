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
    let proposal: Data?
    let profileEvidencePublication: Data?
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
    let proposalData: Data?
    let profileEvidencePublicationData: Data?
}

struct PortableProfileReconsiderationPublicationSourceEvidence {
    let baseChat: Data
    let publishedChat: Data
    let stableChat: Data
    let baseMemory: Data
    let publishedMemory: Data
    let sourceEffect: Data
    let profileReconsideration: Data
    let coachMessage: Data?
    let replacementProposal: Data?
}

struct PortableProfileReconsiderationPublicationCurrentEvidence {
    let aggregate: ChatAggregate
    let canonicalChat: Data
    let stableChat: Data
    let memory: Data
    let coachMessageData: Data?
    let coachMessage: ChatMessage?
    let replacementProposalData: Data?
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

enum InvocationPublicationProofIntent: Equatable {
    case answerPendingUserTurn(
        pendingUserTurnID: PendingUserTurnID,
        pendingUserTurnSHA256: String,
        userMessageID: ChatMessageID,
        userMessageSHA256: String,
        freshDraftID: ChatDraftID,
        freshDraftVersion: UInt64,
        freshDraftSHA256: String
    )
    case reconsiderProfileChange(
        sourceEffectIdentity: ChatProfileEffectIdentity,
        baseManifestRevision: UInt64,
        baseChatSHA256: String,
        baseMemorySHA256: String,
        sourceEffectSHA256: String,
        profileReconsiderationSHA256: String
    )
}

struct InvocationPublicationProof: Equatable {
    static let schemaVersion: UInt32 = 4

    let persistedSchemaVersion: UInt32
    let invocationID: CoachInvocationID
    let libraryID: LibraryID
    let chatID: ChatID
    let responsePositionID: ChatResponsePositionID
    let publishedManifestRevision: UInt64
    let publishedChatSHA256: String
    let stableChatSHA256: String
    let memorySHA256: String
    let messageIDs: [ChatMessageID]
    let coachMessageID: ChatMessageID
    let coachMessageSHA256: String?
    let proposalSHA256: String?
    let profileEvidencePublicationSHA256: String?
    let intent: InvocationPublicationProofIntent
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
        let usesAttemptSequence = invocation.persistedSchemaVersion >=
            CoachInvocation.attemptSequenceSchemaVersion
        let usesSealedIntent = invocation.persistedSchemaVersion >=
            CoachInvocation.schemaVersion
        let legacyAnswerIntent: (
            pendingUserTurnID: PendingUserTurnID,
            draftID: ChatDraftID,
            draftVersion: UInt64,
            responsePositionID: ChatResponsePositionID
        )? = switch invocation.intent {
        case let .answerPendingUserTurn(
            pendingUserTurnID,
            draftID,
            draftVersion,
            responsePositionID
        ):
            (pendingUserTurnID, draftID, draftVersion, responsePositionID)
        case .reconsiderProfileChange:
            nil
        }
        guard usesSealedIntent || legacyAnswerIntent != nil else {
            throw PortableChatPersistenceError.invalidLayout
        }
        return try boundedDeterministicJSON(CoachInvocationDTO(
            schemaVersion: invocation.persistedSchemaVersion,
            invocationId: invocation.id.rawValue,
            attemptId: usesAttemptSequence
                ? nil
                : invocation.attemptID.rawValue,
            providerIdempotencyValue: usesAttemptSequence
                ? nil
                : invocation.providerIdempotencyValue?.rawValue,
            attempts: usesAttemptSequence
                ? try invocation.attempts.map {
                    try CoachProviderAttemptDTO(
                        $0,
                        usesSealedAuthority: usesSealedIntent
                    )
                }
                : nil,
            libraryId: invocation.libraryID.rawValue,
            chatId: invocation.chatID.rawValue,
            pendingUserTurnId: usesSealedIntent
                ? nil
                : legacyAnswerIntent?.pendingUserTurnID.rawValue,
            draftId: usesSealedIntent ? nil : legacyAnswerIntent?.draftID.rawValue,
            draftVersion: usesSealedIntent
                ? nil
                : legacyAnswerIntent?.draftVersion,
            responsePositionId: usesSealedIntent
                ? nil
                : legacyAnswerIntent?.responsePositionID.rawValue,
            intent: usesSealedIntent
                ? try CoachInvocationIntentDTO(invocation.intent)
                : nil,
            expectedManifestRevision: invocation.expectedManifestRevision,
            profileRevisionId: invocation.preparedProfile?.revisionID?.rawValue,
            profileStatementGeneration: invocation.preparedProfile?.statementGeneration,
            admittedAt: invocation.admittedAt.rawValue,
            terminalFailure: invocation.terminalFailure?.rawValue,
            transcriptReadFailure: invocation.terminalFailure?
                .transcriptReadFailureSummary
                .map(PortableCoachTranscriptReadFailureSummaryDTO.init)
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
        let legacyCommon: Set<String> = [
            "schemaVersion", "invocationId", "libraryId", "chatId",
            "pendingUserTurnId", "draftId", "draftVersion",
            "responsePositionId", "expectedManifestRevision", "admittedAt",
        ]
        guard (1 ... CoachInvocation.schemaVersion).contains(dto.schemaVersion)
        else { throw PortableChatPersistenceError.invalidSchemaVersion }
        if dto.schemaVersion == 1 {
            try json.requireExactKeys(
                dictionary,
                legacyCommon.union(["attemptId", "providerIdempotencyValue"])
            )
        } else if dto.schemaVersion == 2 {
            let v2 = legacyCommon.union([
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
        } else if dto.schemaVersion == CoachInvocation.attemptSequenceSchemaVersion {
            let v3 = legacyCommon.union(["attempts", "profileStatementGeneration"])
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
        } else if dto.schemaVersion ==
            CoachInvocation.transcriptReadFailureSchemaVersion
        {
            let v4 = legacyCommon.union(["attempts", "profileStatementGeneration"])
            let actualKeys = Set(dictionary.keys)
            let allowedOptional: Set<String> = [
                "profileRevisionId", "terminalFailure", "transcriptReadFailure",
            ]
            guard actualKeys.isSuperset(of: v4),
                  actualKeys.subtracting(v4).isSubset(of: allowedOptional)
            else { throw PortableChatPersistenceError.unknownKey }
            for optionalKey in allowedOptional where actualKeys.contains(optionalKey) {
                if dictionary[optionalKey] is NSNull {
                    throw PortableChatPersistenceError.invalidJSON
                }
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
            if actualKeys.contains("transcriptReadFailure") {
                guard let summary = dictionary["transcriptReadFailure"]
                    as? [String: Any]
                else { throw PortableChatPersistenceError.invalidJSON }
                try json.requireExactKeys(
                    summary,
                    ["sessions", "additionalSessionCount"]
                )
                guard let sessions = summary["sessions"] as? [[String: Any]] else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                for session in sessions {
                    try json.requireExactKeys(
                        session,
                        ["sessionAttachmentId", "displayLabel"]
                    )
                }
            }
        } else {
            let v5: Set<String> = [
                "schemaVersion", "invocationId", "attempts", "libraryId",
                "chatId", "intent", "expectedManifestRevision",
                "profileStatementGeneration", "admittedAt",
            ]
            let actualKeys = Set(dictionary.keys)
            let allowedOptional: Set<String> = [
                "profileRevisionId", "terminalFailure", "transcriptReadFailure",
            ]
            guard actualKeys.isSuperset(of: v5),
                  actualKeys.subtracting(v5).isSubset(of: allowedOptional)
            else { throw PortableChatPersistenceError.unknownKey }
            for optionalKey in allowedOptional where actualKeys.contains(optionalKey) {
                if dictionary[optionalKey] is NSNull {
                    throw PortableChatPersistenceError.invalidJSON
                }
            }
            guard let rawAttempts = dictionary["attempts"] as? [[String: Any]],
                  !rawAttempts.isEmpty,
                  rawAttempts.count <= Int(CoachProviderAttempt.maximumOrdinal)
            else { throw PortableChatPersistenceError.invalidJSON }
            for rawAttempt in rawAttempts {
                try json.requireExactKeys(rawAttempt, [
                    "attemptId", "ordinal", "kind", "publicationAuthority",
                ])
                guard let authority = rawAttempt["publicationAuthority"]
                    as? [String: Any],
                    let kind = authority["kind"] as? String
                else { throw PortableChatPersistenceError.invalidJSON }
                switch kind {
                case "answerPendingUserTurn":
                    try json.requireExactKeys(authority, [
                        "kind", "userMessageId", "coachMessageId",
                        "freshDraftId",
                    ])
                case "reconsiderProfileChange":
                    try json.requireExactKeys(authority, [
                        "kind", "coachMessageId",
                    ])
                default:
                    throw PortableChatPersistenceError.invalidJSON
                }
            }
            guard let rawIntent = dictionary["intent"] as? [String: Any],
                  let intentKind = rawIntent["kind"] as? String
            else { throw PortableChatPersistenceError.invalidJSON }
            switch intentKind {
            case "answerPendingUserTurn":
                try json.requireExactKeys(rawIntent, [
                    "kind", "pendingUserTurnId", "draftId", "draftVersion",
                    "responsePositionId",
                ])
            case "reconsiderProfileChange":
                try json.requireExactKeys(rawIntent, [
                    "kind", "sourceEffectIdentity", "resultResponsePositionId",
                ])
                guard let source = rawIntent["sourceEffectIdentity"]
                    as? [String: Any],
                    let sourceKind = source["kind"] as? String
                else { throw PortableChatPersistenceError.invalidJSON }
                switch sourceKind {
                case "proposal":
                    try json.requireExactKeys(source, ["kind", "proposalId"])
                case "evidencePublication":
                    try json.requireExactKeys(
                        source,
                        ["kind", "responsePositionId"]
                    )
                default:
                    throw PortableChatPersistenceError.invalidJSON
                }
            default:
                throw PortableChatPersistenceError.invalidJSON
            }
            if actualKeys.contains("transcriptReadFailure") {
                guard let summary = dictionary["transcriptReadFailure"]
                    as? [String: Any]
                else { throw PortableChatPersistenceError.invalidJSON }
                try json.requireExactKeys(
                    summary,
                    ["sessions", "additionalSessionCount"]
                )
                guard let sessions = summary["sessions"] as? [[String: Any]] else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                for session in sessions {
                    try json.requireExactKeys(
                        session,
                        ["sessionAttachmentId", "displayLabel"]
                    )
                }
            }
        }
        return try mapPersistedDomainValidation {
            let intent: CoachInvocationIntent
            if dto.schemaVersion >= CoachInvocation.schemaVersion {
                guard dto.pendingUserTurnId == nil,
                      dto.draftId == nil,
                      dto.draftVersion == nil,
                      dto.responsePositionId == nil,
                      let persistedIntent = dto.intent
                else { throw PortableChatPersistenceError.invalidJSON }
                intent = try persistedIntent.domainValue()
            } else {
                guard let pendingUserTurnId = dto.pendingUserTurnId,
                      let draftId = dto.draftId,
                      let draftVersion = dto.draftVersion,
                      let responsePositionId = dto.responsePositionId,
                      dto.intent == nil
                else { throw PortableChatPersistenceError.invalidJSON }
                intent = .answerPendingUserTurn(
                    pendingUserTurnID: try PendingUserTurnID(pendingUserTurnId),
                    draftID: try ChatDraftID(draftId),
                    draftVersion: draftVersion,
                    responsePositionID: try ChatResponsePositionID(
                        responsePositionId
                    )
                )
            }
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
            if dto.schemaVersion >= CoachInvocation.attemptSequenceSchemaVersion {
                guard dto.attemptId == nil,
                      dto.providerIdempotencyValue == nil,
                      let attemptDTOs = dto.attempts
                else { throw PortableChatPersistenceError.invalidJSON }
                attempts = try attemptDTOs.map {
                    try $0.domainValue(
                        usesSealedAuthority:
                            dto.schemaVersion >= CoachInvocation.schemaVersion
                    )
                }
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
            let terminalFailure: PendingUserTurnFailure?
            if dto.terminalFailure == "coachTranscriptReadFailed" {
                guard dto.schemaVersion >=
                        CoachInvocation.transcriptReadFailureSchemaVersion,
                      let summary = try dto.transcriptReadFailure?.domainValue()
                else { throw PortableChatPersistenceError.invalidJSON }
                terminalFailure = .coachTranscriptReadFailed(summary)
            } else {
                guard dto.transcriptReadFailure == nil else {
                    throw PortableChatPersistenceError.invalidJSON
                }
                terminalFailure = try dto.terminalFailure.map { rawValue in
                    guard let failure = PendingUserTurnFailure(rawValue: rawValue) else {
                        throw PortableChatPersistenceError.invalidJSON
                    }
                    return failure
                }
            }
            return try CoachInvocation(
                schemaVersion: dto.schemaVersion,
                id: try CoachInvocationID(dto.invocationId),
                attempts: attempts,
                library: LibraryScope(libraryID: try LibraryID(dto.libraryId)),
                chatID: ChatID(dto.chatId),
                intent: intent,
                preparedProfile: preparedProfile,
                expectedManifestRevision: dto.expectedManifestRevision,
                admittedAt: UTCInstant(dto.admittedAt),
                terminalFailure: terminalFailure
            )
        }
    }

    func makePublicationProof(
        for mutation: PublishCoachInvocationMutation,
        evidence: PortableInvocationPublicationSourceEvidence
    ) throws -> InvocationPublicationProof {
        guard mutation.base.pendingUserTurn != nil,
              evidence.proposal == nil || evidence.profileEvidencePublication == nil
        else {
            throw PortableChatPersistenceError.invalidLayout
        }
        let published = mutation.replacement
        return InvocationPublicationProof(
            persistedSchemaVersion: 3,
            invocationID: mutation.invocation.id,
            libraryID: mutation.invocation.libraryID,
            chatID: mutation.invocation.chatID,
            responsePositionID: mutation.invocation.responsePositionID,
            publishedManifestRevision: published.chat.manifestRevision,
            publishedChatSHA256: Self.sha256(evidence.publishedChat),
            stableChatSHA256: Self.sha256(evidence.stableChat),
            memorySHA256: Self.sha256(evidence.memory),
            messageIDs: published.chat.messageIDs,
            coachMessageID: mutation.coachMessage.id,
            coachMessageSHA256: Self.sha256(evidence.coachMessage),
            proposalSHA256: evidence.proposal.map(Self.sha256),
            profileEvidencePublicationSHA256: evidence
                .profileEvidencePublication.map(Self.sha256),
            intent: .answerPendingUserTurn(
                pendingUserTurnID: mutation.invocation.pendingUserTurnID,
                pendingUserTurnSHA256: Self.sha256(
                    evidence.pendingUserTurn
                ),
                userMessageID: mutation.userMessage.id,
                userMessageSHA256: Self.sha256(evidence.userMessage),
                freshDraftID: mutation.freshDraft.draftID,
                freshDraftVersion: mutation.freshDraft.version,
                freshDraftSHA256: Self.sha256(evidence.freshDraft)
            )
        )
    }

    func makePublicationProof(
        for mutation: PublishProfileReconsiderationInvocationMutation,
        evidence: PortableProfileReconsiderationPublicationSourceEvidence
    ) throws -> InvocationPublicationProof {
        guard case let .reconsiderProfileChange(source, result) =
            mutation.invocation.intent,
              source == mutation.reconsideration.sourceEffectIdentity,
              result == mutation.reconsideration.resultResponsePositionID,
              mutation.base.profileReconsideration == mutation.reconsideration,
              mutation.base.profileEffect?.identity == source,
              mutation.replacement.profileReconsideration == nil,
              mutation.replacement.profileEffect?.proposal ==
                mutation.replacementProposal,
              mutation.isWithdrawal ==
                (mutation.replacementProposal == nil),
              case let .reconsiderProfileChange(coachMessageID)? =
                mutation.invocation.attempt.publicationAuthority,
              evidence.coachMessage == nil || mutation.coachMessage != nil,
              evidence.coachMessage != nil || mutation.coachMessage == nil,
              evidence.replacementProposal == nil ||
                mutation.replacementProposal != nil,
              evidence.replacementProposal != nil ||
                mutation.replacementProposal == nil
        else { throw PortableChatPersistenceError.invalidLayout }
        let (publishedRevision, overflow) = mutation.base.chat.manifestRevision
            .addingReportingOverflow(1)
        guard !overflow,
              mutation.replacement.chat.manifestRevision == publishedRevision,
              mutation.invocation.expectedManifestRevision ==
                mutation.base.chat.manifestRevision
        else { throw PortableChatPersistenceError.invalidLayout }
        return InvocationPublicationProof(
            persistedSchemaVersion: InvocationPublicationProof.schemaVersion,
            invocationID: mutation.invocation.id,
            libraryID: mutation.invocation.libraryID,
            chatID: mutation.invocation.chatID,
            responsePositionID: result,
            publishedManifestRevision: publishedRevision,
            publishedChatSHA256: Self.sha256(evidence.publishedChat),
            stableChatSHA256: Self.sha256(evidence.stableChat),
            memorySHA256: Self.sha256(evidence.publishedMemory),
            messageIDs: mutation.replacement.chat.messageIDs,
            coachMessageID: coachMessageID,
            coachMessageSHA256: evidence.coachMessage.map(Self.sha256),
            proposalSHA256: evidence.replacementProposal.map(Self.sha256),
            profileEvidencePublicationSHA256: nil,
            intent: .reconsiderProfileChange(
                sourceEffectIdentity: source,
                baseManifestRevision: mutation.base.chat.manifestRevision,
                baseChatSHA256: Self.sha256(evidence.baseChat),
                baseMemorySHA256: Self.sha256(evidence.baseMemory),
                sourceEffectSHA256: Self.sha256(evidence.sourceEffect),
                profileReconsiderationSHA256: Self.sha256(
                    evidence.profileReconsideration
                )
            )
        )
    }

    func encodePublicationProof(_ proof: InvocationPublicationProof) throws -> Data {
        let dto: InvocationPublicationProofDTO
        switch proof.intent {
        case let .answerPendingUserTurn(
            pendingUserTurnID,
            pendingUserTurnSHA256,
            userMessageID,
            userMessageSHA256,
            freshDraftID,
            freshDraftVersion,
            freshDraftSHA256
        ):
            guard proof.persistedSchemaVersion == 3,
                  let coachMessageSHA256 = proof.coachMessageSHA256
            else { throw PortableChatPersistenceError.invalidLayout }
            dto = InvocationPublicationProofDTO(
                schemaVersion: 3,
                kind: nil,
                invocationId: proof.invocationID.rawValue,
                libraryId: proof.libraryID.rawValue,
                chatId: proof.chatID.rawValue,
                responsePositionId: proof.responsePositionID.rawValue,
                publishedManifestRevision: proof.publishedManifestRevision,
                publishedChatSha256: proof.publishedChatSHA256,
                stableChatSha256: proof.stableChatSHA256,
                memorySha256: proof.memorySHA256,
                messageIds: proof.messageIDs.map(\.rawValue),
                coachMessageId: proof.coachMessageID.rawValue,
                coachMessageSha256: coachMessageSHA256,
                proposalSha256: proof.proposalSHA256,
                profileEvidencePublicationSha256:
                    proof.profileEvidencePublicationSHA256,
                pendingUserTurnId: pendingUserTurnID.rawValue,
                pendingUserTurnSha256: pendingUserTurnSHA256,
                userMessageId: userMessageID.rawValue,
                userMessageSha256: userMessageSHA256,
                freshDraftId: freshDraftID.rawValue,
                freshDraftVersion: freshDraftVersion,
                freshDraftSha256: freshDraftSHA256,
                sourceEffect: nil,
                baseManifestRevision: nil,
                baseChatSha256: nil,
                baseMemorySha256: nil,
                sourceEffectSha256: nil,
                profileReconsiderationSha256: nil
            )
        case let .reconsiderProfileChange(
            sourceEffectIdentity,
            baseManifestRevision,
            baseChatSHA256,
            baseMemorySHA256,
            sourceEffectSHA256,
            profileReconsiderationSHA256
        ):
            guard proof.persistedSchemaVersion ==
                InvocationPublicationProof.schemaVersion,
                proof.profileEvidencePublicationSHA256 == nil
            else { throw PortableChatPersistenceError.invalidLayout }
            dto = InvocationPublicationProofDTO(
                schemaVersion: InvocationPublicationProof.schemaVersion,
                kind: "reconsiderProfileChange",
                invocationId: proof.invocationID.rawValue,
                libraryId: proof.libraryID.rawValue,
                chatId: proof.chatID.rawValue,
                responsePositionId: proof.responsePositionID.rawValue,
                publishedManifestRevision: proof.publishedManifestRevision,
                publishedChatSha256: proof.publishedChatSHA256,
                stableChatSha256: proof.stableChatSHA256,
                memorySha256: proof.memorySHA256,
                messageIds: proof.messageIDs.map(\.rawValue),
                coachMessageId: proof.coachMessageID.rawValue,
                coachMessageSha256: proof.coachMessageSHA256,
                proposalSha256: proof.proposalSHA256,
                profileEvidencePublicationSha256: nil,
                pendingUserTurnId: nil,
                pendingUserTurnSha256: nil,
                userMessageId: nil,
                userMessageSha256: nil,
                freshDraftId: nil,
                freshDraftVersion: nil,
                freshDraftSha256: nil,
                sourceEffect: ChatProfileEffectIdentityDTO(
                    sourceEffectIdentity
                ),
                baseManifestRevision: baseManifestRevision,
                baseChatSha256: baseChatSHA256,
                baseMemorySha256: baseMemorySHA256,
                sourceEffectSha256: sourceEffectSHA256,
                profileReconsiderationSha256:
                    profileReconsiderationSHA256
            )
        }
        return try boundedDeterministicJSON(dto)
    }

    func decodePublicationProof(_ data: Data) throws -> InvocationPublicationProof {
        guard data.count <= maximumRootBytes else {
            throw PortableChatPersistenceError.rootTooLarge
        }
        let dictionary = try json.jsonDictionary(data)
        let v1Keys: Set<String> = [
            "schemaVersion", "invocationId", "libraryId", "chatId",
            "pendingUserTurnId", "responsePositionId", "publishedManifestRevision",
            "publishedChatSha256", "stableChatSha256", "memorySha256",
            "pendingUserTurnSha256", "messageIds", "userMessageId",
            "userMessageSha256", "coachMessageId", "coachMessageSha256",
            "freshDraftId", "freshDraftVersion", "freshDraftSha256",
        ]
        let v2Keys = v1Keys.union(["proposalSha256"])
        let v3Keys = v2Keys.union(["profileEvidencePublicationSha256"])
        let v4RequiredKeys: Set<String> = [
            "schemaVersion", "kind", "invocationId", "libraryId", "chatId",
            "responsePositionId", "baseManifestRevision", "baseChatSha256",
            "baseMemorySha256", "publishedManifestRevision",
            "publishedChatSha256", "stableChatSha256", "memorySha256",
            "messageIds", "coachMessageId", "sourceEffect",
            "sourceEffectSha256", "profileReconsiderationSha256",
        ]
        let v4OptionalKeys: Set<String> = [
            "coachMessageSha256", "proposalSha256",
        ]
        let dto = try json.decode(InvocationPublicationProofDTO.self, from: data)
        guard (1 ... InvocationPublicationProof.schemaVersion).contains(
            dto.schemaVersion
        ) else {
            throw PortableChatPersistenceError.invalidSchemaVersion
        }
        switch dto.schemaVersion {
        case 1:
            try json.requireExactKeys(dictionary, v1Keys)
            guard dto.proposalSha256 == nil,
                  dto.profileEvidencePublicationSha256 == nil
            else {
                throw PortableChatPersistenceError.invalidJSON
            }
        case 2:
            let actual = Set(dictionary.keys)
            guard actual == v1Keys || actual == v2Keys,
                  dto.profileEvidencePublicationSha256 == nil
            else { throw PortableChatPersistenceError.unknownKey }
            if actual.contains("proposalSha256"),
               dictionary["proposalSha256"] is NSNull
            {
                throw PortableChatPersistenceError.invalidJSON
            }
        case 3:
            let actual = Set(dictionary.keys)
            guard actual.isSubset(of: v3Keys), v1Keys.isSubset(of: actual),
                  dto.proposalSha256 == nil ||
                    dto.profileEvidencePublicationSha256 == nil
            else { throw PortableChatPersistenceError.unknownKey }
            for key in [
                "proposalSha256", "profileEvidencePublicationSha256",
            ] where actual.contains(key) && dictionary[key] is NSNull {
                throw PortableChatPersistenceError.invalidJSON
            }
        case InvocationPublicationProof.schemaVersion:
            let actual = Set(dictionary.keys)
            guard v4RequiredKeys.isSubset(of: actual),
                  actual.isSubset(of: v4RequiredKeys.union(v4OptionalKeys)),
                  dto.kind == "reconsiderProfileChange",
                  dto.pendingUserTurnId == nil,
                  dto.pendingUserTurnSha256 == nil,
                  dto.userMessageId == nil,
                  dto.userMessageSha256 == nil,
                  dto.freshDraftId == nil,
                  dto.freshDraftVersion == nil,
                  dto.freshDraftSha256 == nil,
                  dto.profileEvidencePublicationSha256 == nil,
                  let sourceEffectDictionary =
                    dictionary["sourceEffect"] as? [String: Any]
            else { throw PortableChatPersistenceError.unknownKey }
            switch sourceEffectDictionary["kind"] as? String {
            case "proposal":
                try json.requireExactKeys(
                    sourceEffectDictionary,
                    ["kind", "proposalId"]
                )
            case "evidencePublication":
                try json.requireExactKeys(
                    sourceEffectDictionary,
                    ["kind", "responsePositionId"]
                )
            default:
                throw PortableChatPersistenceError.invalidJSON
            }
            for key in v4OptionalKeys
                where actual.contains(key) && dictionary[key] is NSNull
            {
                throw PortableChatPersistenceError.invalidJSON
            }
        default:
            throw PortableChatPersistenceError.invalidSchemaVersion
        }
        guard Self.isSHA256(dto.publishedChatSha256),
              Self.isSHA256(dto.stableChatSha256),
              Self.isSHA256(dto.memorySha256),
              dto.pendingUserTurnSha256.map(Self.isSHA256) ?? true,
              dto.userMessageSha256.map(Self.isSHA256) ?? true,
              dto.coachMessageSha256.map(Self.isSHA256) ?? true,
              dto.freshDraftSha256.map(Self.isSHA256) ?? true,
              dto.baseChatSha256.map(Self.isSHA256) ?? true,
              dto.baseMemorySha256.map(Self.isSHA256) ?? true,
              dto.sourceEffectSha256.map(Self.isSHA256) ?? true,
              dto.profileReconsiderationSha256.map(Self.isSHA256) ?? true,
              dto.proposalSha256.map(Self.isSHA256) ?? true,
              dto.profileEvidencePublicationSha256.map(Self.isSHA256) ?? true,
              dto.messageIds.count <= maximumMessageCount
        else { throw PortableChatPersistenceError.invalidJSON }
        return try mapPersistedDomainValidation {
            let intent: InvocationPublicationProofIntent
            switch dto.schemaVersion {
            case 1 ... 3:
                guard dto.kind == nil,
                      let pendingUserTurnID = dto.pendingUserTurnId,
                      let pendingUserTurnSHA256 = dto.pendingUserTurnSha256,
                      let userMessageID = dto.userMessageId,
                      let userMessageSHA256 = dto.userMessageSha256,
                      let freshDraftID = dto.freshDraftId,
                      let freshDraftVersion = dto.freshDraftVersion,
                      let freshDraftSHA256 = dto.freshDraftSha256,
                      dto.sourceEffect == nil,
                      dto.baseManifestRevision == nil,
                      dto.baseChatSha256 == nil,
                      dto.baseMemorySha256 == nil,
                      dto.sourceEffectSha256 == nil,
                      dto.profileReconsiderationSha256 == nil,
                      dto.coachMessageSha256 != nil
                else { throw PortableChatPersistenceError.invalidJSON }
                intent = .answerPendingUserTurn(
                    pendingUserTurnID: try PendingUserTurnID(
                        pendingUserTurnID
                    ),
                    pendingUserTurnSHA256: pendingUserTurnSHA256,
                    userMessageID: try ChatMessageID(userMessageID),
                    userMessageSHA256: userMessageSHA256,
                    freshDraftID: try ChatDraftID(freshDraftID),
                    freshDraftVersion: freshDraftVersion,
                    freshDraftSHA256: freshDraftSHA256
                )
            case InvocationPublicationProof.schemaVersion:
                guard let sourceEffect = dto.sourceEffect,
                      let baseManifestRevision = dto.baseManifestRevision,
                      let baseChatSHA256 = dto.baseChatSha256,
                      let baseMemorySHA256 = dto.baseMemorySha256,
                      let sourceEffectSHA256 = dto.sourceEffectSha256,
                      let profileReconsiderationSHA256 =
                        dto.profileReconsiderationSha256
                else { throw PortableChatPersistenceError.invalidJSON }
                intent = .reconsiderProfileChange(
                    sourceEffectIdentity: try sourceEffect.domainValue(),
                    baseManifestRevision: baseManifestRevision,
                    baseChatSHA256: baseChatSHA256,
                    baseMemorySHA256: baseMemorySHA256,
                    sourceEffectSHA256: sourceEffectSHA256,
                    profileReconsiderationSHA256:
                        profileReconsiderationSHA256
                )
            default:
                throw PortableChatPersistenceError.invalidSchemaVersion
            }
            let proof = InvocationPublicationProof(
                persistedSchemaVersion: dto.schemaVersion,
                invocationID: try CoachInvocationID(dto.invocationId),
                libraryID: try LibraryID(dto.libraryId),
                chatID: try ChatID(dto.chatId),
                responsePositionID: try ChatResponsePositionID(dto.responsePositionId),
                publishedManifestRevision: dto.publishedManifestRevision,
                publishedChatSHA256: dto.publishedChatSha256,
                stableChatSHA256: dto.stableChatSha256,
                memorySHA256: dto.memorySha256,
                messageIDs: try dto.messageIds.map(ChatMessageID.init),
                coachMessageID: try ChatMessageID(dto.coachMessageId),
                coachMessageSHA256: dto.coachMessageSha256,
                proposalSHA256: dto.proposalSha256,
                profileEvidencePublicationSHA256:
                    dto.profileEvidencePublicationSha256,
                intent: intent
            )
            guard proof.messageIDs.count == Set(proof.messageIDs).count else {
                throw PortableChatPersistenceError.invalidJSON
            }
            return proof
        }
    }

    func proof(
        _ proof: InvocationPublicationProof,
        isBoundTo invocation: CoachInvocation
    ) -> Bool {
        let (publishedRevision, overflow) = invocation.expectedManifestRevision
            .addingReportingOverflow(1)
        guard !overflow,
              invocation.preparedProfile != nil,
              proof.invocationID == invocation.id,
              proof.libraryID == invocation.libraryID,
              proof.chatID == invocation.chatID,
              proof.responsePositionID == invocation.responsePositionID,
              proof.publishedManifestRevision == publishedRevision
        else { return false }
        switch proof.intent {
        case let .answerPendingUserTurn(
            pendingUserTurnID,
            _,
            userMessageID,
            _,
            freshDraftID,
            freshDraftVersion,
            _
        ):
            guard case let .answerPendingUserTurn(
                invocationPendingID,
                _,
                _,
                _
            ) = invocation.intent,
                pendingUserTurnID == invocationPendingID,
                proof.persistedSchemaVersion <= 3,
                freshDraftVersion == 0,
                userMessageID != proof.coachMessageID,
                proof.coachMessageSHA256 != nil,
                proof.messageIDs.count >= 2,
                Array(proof.messageIDs.suffix(2)) == [
                    userMessageID,
                    proof.coachMessageID,
                ]
            else { return false }
            switch invocation.persistedSchemaVersion {
            case 2:
                return true
            case CoachInvocation.attemptSequenceSchemaVersion ...
                CoachInvocation.schemaVersion:
                guard case let .answerPendingUserTurn(
                    attemptUserMessageID,
                    attemptCoachMessageID,
                    attemptFreshDraftID
                ) = invocation.attempt.publicationAuthority
                else { return false }
                return attemptUserMessageID == userMessageID &&
                    attemptCoachMessageID == proof.coachMessageID &&
                    attemptFreshDraftID == freshDraftID
            default:
                return false
            }

        case let .reconsiderProfileChange(
            sourceEffectIdentity,
            baseManifestRevision,
            _,
            _,
            _,
            _
        ):
            guard proof.persistedSchemaVersion ==
                    InvocationPublicationProof.schemaVersion,
                  invocation.persistedSchemaVersion ==
                    CoachInvocation.schemaVersion,
                  baseManifestRevision == invocation.expectedManifestRevision,
                  proof.profileEvidencePublicationSHA256 == nil,
                  case let .reconsiderProfileChange(source, result) =
                    invocation.intent,
                  source == sourceEffectIdentity,
                  result == proof.responsePositionID,
                  case let .reconsiderProfileChange(coachMessageID)? =
                    invocation.attempt.publicationAuthority,
                  coachMessageID == proof.coachMessageID
            else { return false }
            if proof.coachMessageSHA256 != nil {
                return proof.messageIDs.last == proof.coachMessageID
            }
            return !proof.messageIDs.contains(proof.coachMessageID)
        }
    }

    func isExactPublishedInvocation(
        _ proof: InvocationPublicationProof,
        invocation: CoachInvocation,
        evidence: PortableInvocationPublicationCurrentEvidence
    ) -> Bool {
        let current = evidence.aggregate.chat
        let user = evidence.userMessage
        let coach = evidence.coachMessage
        guard case let .answerPendingUserTurn(
            pendingUserTurnID,
            pendingUserTurnSHA256,
            userMessageID,
            userMessageSHA256,
            freshDraftID,
            freshDraftVersion,
            freshDraftSHA256
        ) = proof.intent,
              let coachMessageSHA256 = proof.coachMessageSHA256,
              self.proof(proof, isBoundTo: invocation),
              current.id == proof.chatID,
              evidence.aggregate.pendingUserTurn == nil,
              current.manifestRevision >= proof.publishedManifestRevision,
              current.messageIDs == proof.messageIDs,
              current.draft.draftID == freshDraftID,
              current.draft.version >= freshDraftVersion,
              Self.sha256(evidence.stableChat) == proof.stableChatSHA256,
              Self.sha256(evidence.memory) == proof.memorySHA256,
              Self.sha256(evidence.userMessageData) == userMessageSHA256,
              Self.sha256(evidence.coachMessageData) == coachMessageSHA256,
              user.id == userMessageID,
              coach.id == proof.coachMessageID,
              user.responsePositionID == invocation.responsePositionID,
              coach.responsePositionID == invocation.responsePositionID,
              user.persistedSchemaVersion == coach.persistedSchemaVersion,
              [
                  ChatMessage.profileProvenanceSchemaVersion,
                  ChatMessage.schemaVersion,
              ].contains(user.persistedSchemaVersion),
              user.coachProfile == nil,
              coach.coachProfile == invocation.preparedProfile,
              case .user = user.content,
              case .coach = coach.content
        else { return false }
        if let proposalSHA256 = proof.proposalSHA256 {
            guard let proposalData = evidence.proposalData,
                  Self.sha256(proposalData) == proposalSHA256
            else { return false }
        } else if evidence.proposalData != nil {
            return false
        }
        if let publicationSHA256 = proof.profileEvidencePublicationSHA256 {
            guard let publicationData = evidence.profileEvidencePublicationData,
                  Self.sha256(publicationData) == publicationSHA256
            else { return false }
        } else if evidence.profileEvidencePublicationData != nil {
            return false
        }
        if current.manifestRevision == proof.publishedManifestRevision,
           Self.sha256(evidence.canonicalChat) != proof.publishedChatSHA256
        {
            return false
        }
        if current.draft.version == freshDraftVersion,
           Self.sha256(evidence.freshDraft) != freshDraftSHA256
        {
            return false
        }
        if let pendingData = evidence.pendingUserTurnData {
            guard Self.sha256(pendingData) == pendingUserTurnSHA256,
                  let pending = evidence.pendingUserTurn,
                  pending.id == pendingUserTurnID,
                  pending.draftID == invocation.draftID,
                  pending.draftVersion == invocation.draftVersion,
                  pending.responsePositionID == invocation.responsePositionID,
                  invocation.persistedSchemaVersion <
                  CoachInvocation.attemptSequenceSchemaVersion ||
                  pending.failure == nil
            else { return false }
        } else if evidence.pendingUserTurn != nil {
            return false
        }
        return true
    }

    func isExactPublishedProfileReconsideration(
        _ proof: InvocationPublicationProof,
        invocation: CoachInvocation,
        evidence: PortableProfileReconsiderationPublicationCurrentEvidence
    ) -> Bool {
        guard case .reconsiderProfileChange = proof.intent,
              self.proof(proof, isBoundTo: invocation),
              evidence.aggregate.chat.id == proof.chatID,
              evidence.aggregate.chat.manifestRevision >=
                proof.publishedManifestRevision,
              evidence.aggregate.chat.messageIDs == proof.messageIDs,
              evidence.aggregate.pendingUserTurn == nil,
              evidence.aggregate.profileReconsideration == nil,
              evidence.aggregate.profileEvidencePublication == nil,
              (evidence.aggregate.profileProposal != nil) ==
                (proof.proposalSHA256 != nil),
              Self.sha256(evidence.stableChat) == proof.stableChatSHA256,
              Self.sha256(evidence.memory) == proof.memorySHA256
        else { return false }
        if evidence.aggregate.chat.manifestRevision ==
            proof.publishedManifestRevision,
           Self.sha256(evidence.canonicalChat) != proof.publishedChatSHA256
        {
            return false
        }
        if let expectedMessageSHA256 = proof.coachMessageSHA256 {
            guard let messageData = evidence.coachMessageData,
                  let message = evidence.coachMessage,
                  Self.sha256(messageData) == expectedMessageSHA256,
                  message.id == proof.coachMessageID,
                  message.responsePositionID == proof.responsePositionID,
                  message.coachProfile == invocation.preparedProfile,
                  case .coach = message.content
            else { return false }
        } else if evidence.coachMessageData != nil ||
                    evidence.coachMessage != nil
        {
            return false
        }
        if let expectedProposalSHA256 = proof.proposalSHA256 {
            guard let proposalData = evidence.replacementProposalData,
                  Self.sha256(proposalData) == expectedProposalSHA256
            else { return false }
        } else if evidence.replacementProposalData != nil {
            return false
        }
        return true
    }

    func isExactProfileReconsiderationPublicationBase(
        _ proof: InvocationPublicationProof,
        invocation: CoachInvocation,
        aggregate: ChatAggregate,
        canonicalChat: Data,
        memory: Data,
        sourceEffect: Data,
        profileReconsideration: Data
    ) -> Bool {
        guard case let .reconsiderProfileChange(
            sourceEffectIdentity,
            baseManifestRevision,
            baseChatSHA256,
            baseMemorySHA256,
            sourceEffectSHA256,
            profileReconsiderationSHA256
        ) = proof.intent,
              self.proof(proof, isBoundTo: invocation),
              aggregate.chat.id == proof.chatID,
              aggregate.chat.manifestRevision == baseManifestRevision,
              aggregate.profileEffect?.identity == sourceEffectIdentity,
              aggregate.profileReconsideration?.sourceEffectIdentity ==
                sourceEffectIdentity,
              aggregate.profileReconsideration?.resultResponsePositionID ==
                proof.responsePositionID,
              aggregate.profileReconsideration?.failure == nil,
              Self.sha256(canonicalChat) == baseChatSHA256,
              Self.sha256(memory) == baseMemorySHA256,
              Self.sha256(sourceEffect) == sourceEffectSHA256,
              Self.sha256(profileReconsideration) ==
                profileReconsiderationSHA256
        else { return false }
        return true
    }

    func proof(
        _ proof: InvocationPublicationProof,
        bindsReconsiderationSourceEffectData data: Data
    ) -> Bool {
        guard case let .reconsiderProfileChange(_, _, _, _, expected, _) =
            proof.intent
        else { return false }
        return Self.sha256(data) == expected
    }

    func proof(
        _ proof: InvocationPublicationProof,
        bindsProfileReconsiderationData data: Data
    ) -> Bool {
        guard case let .reconsiderProfileChange(_, _, _, _, _, expected) =
            proof.intent
        else { return false }
        return Self.sha256(data) == expected
    }

    func proof(
        _ proof: InvocationPublicationProof,
        bindsReconsiderationBaseChatData data: Data
    ) -> Bool {
        guard case let .reconsiderProfileChange(_, _, expected, _, _, _) =
            proof.intent
        else { return false }
        return Self.sha256(data) == expected
    }

    func proof(
        _ proof: InvocationPublicationProof,
        bindsReconsiderationBaseMemoryData data: Data
    ) -> Bool {
        guard case let .reconsiderProfileChange(_, _, _, expected, _, _) =
            proof.intent
        else { return false }
        return Self.sha256(data) == expected
    }

    func proof(
        _ proof: InvocationPublicationProof,
        bindsPublishedChatData data: Data
    ) -> Bool {
        Self.sha256(data) == proof.publishedChatSHA256
    }

    func proof(
        _ proof: InvocationPublicationProof,
        bindsStableChatData data: Data
    ) -> Bool {
        Self.sha256(data) == proof.stableChatSHA256
    }

    func proof(
        _ proof: InvocationPublicationProof,
        bindsPublishedMemoryData data: Data
    ) -> Bool {
        Self.sha256(data) == proof.memorySHA256
    }

    func proof(
        _ proof: InvocationPublicationProof,
        bindsCoachMessageData data: Data
    ) -> Bool {
        guard let expected = proof.coachMessageSHA256 else { return false }
        return Self.sha256(data) == expected
    }

    func proof(
        _ proof: InvocationPublicationProof,
        bindsProposalData proposalData: Data
    ) -> Bool {
        guard let expected = proof.proposalSHA256 else { return false }
        return Self.sha256(proposalData) == expected
    }

    func proof(
        _ proof: InvocationPublicationProof,
        bindsProfileEvidencePublicationData publicationData: Data
    ) -> Bool {
        guard let expected = proof.profileEvidencePublicationSHA256 else {
            return false
        }
        return Self.sha256(publicationData) == expected
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

private enum PortableJSONLexicalPolicy {
    /// Full JSON lexical validation for persisted Chat roots.
    case strict

    /// Framing-only validation for future Invocation body values. Object keys
    /// and routed durable IDs are still decoded as JSON strings, while opaque
    /// primitives and string contents retain the existing forward-compatible
    /// routing behavior.
    case routing
}

/// Shared bounded byte cursor for the two persistence scanners. It owns only
/// JSON mechanics; each scanner remains responsible for its own paths,
/// duplicate policy, and which string values become durable public identity.
private struct PortableJSONCursor {
    private static let maximumContainerDepth = 128

    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    var currentByte: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    mutating func finishDocument() throws {
        skipWhitespace()
        guard index == bytes.count else {
            throw PortableChatPersistenceError.invalidJSON
        }
    }

    /// Opens an object or array and returns whether it was empty.
    mutating func beginContainer(
        opening: UInt8,
        closing: UInt8,
        depth: Int
    ) throws -> Bool {
        guard depth < Self.maximumContainerDepth,
              index < bytes.count,
              bytes[index] == opening
        else { throw PortableChatPersistenceError.invalidJSON }
        index += 1
        skipWhitespace()
        return consume(closing)
    }

    mutating func consumeNameSeparator() throws {
        skipWhitespace()
        guard consume(0x3A) else {
            throw PortableChatPersistenceError.invalidJSON
        }
        skipWhitespace()
    }

    /// Completes one container element. Returns `true` at the closing token or
    /// positions the cursor at the next element and returns `false`.
    mutating func completeElement(closing: UInt8) throws -> Bool {
        skipWhitespace()
        if consume(closing) { return true }
        guard consume(0x2C) else {
            throw PortableChatPersistenceError.invalidJSON
        }
        skipWhitespace()
        guard index < bytes.count, bytes[index] != closing else {
            throw PortableChatPersistenceError.invalidJSON
        }
        return false
    }

    mutating func requiredJSONString(
        policy: PortableJSONLexicalPolicy
    ) throws -> String {
        guard let value = try parseJSONString(materialize: true, policy: policy) else {
            throw PortableChatPersistenceError.invalidJSON
        }
        return value
    }

    mutating func parseJSONString(
        materialize: Bool,
        policy: PortableJSONLexicalPolicy
    ) throws -> String? {
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
                    if policy == .strict {
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
                    }
                default:
                    throw PortableChatPersistenceError.invalidJSON
                }
                continue
            }
            guard byte >= 0x20 else {
                throw PortableChatPersistenceError.invalidJSON
            }
            switch policy {
            case .strict:
                try advanceUTF8Scalar()
            case .routing:
                index += 1
            }
        }
        throw PortableChatPersistenceError.invalidJSON
    }

    mutating func parsePrimitive(policy: PortableJSONLexicalPolicy) throws {
        switch policy {
        case .strict:
            if consumeLiteral([0x74, 0x72, 0x75, 0x65]) ||
                consumeLiteral([0x66, 0x61, 0x6C, 0x73, 0x65]) ||
                consumeLiteral([0x6E, 0x75, 0x6C, 0x6C])
            {
                return
            }
            try parseNumber()
        case .routing:
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
    }

    mutating func skipValue(
        depth: Int,
        policy: PortableJSONLexicalPolicy
    ) throws {
        guard let currentByte else {
            throw PortableChatPersistenceError.invalidJSON
        }
        switch currentByte {
        case 0x22:
            _ = try parseJSONString(materialize: false, policy: policy)
        case 0x7B:
            try skipObject(depth: depth, policy: policy)
        case 0x5B:
            try skipArray(depth: depth, policy: policy)
        default:
            try parsePrimitive(policy: policy)
        }
    }

    private mutating func skipObject(
        depth: Int,
        policy: PortableJSONLexicalPolicy
    ) throws {
        if try beginContainer(opening: 0x7B, closing: 0x7D, depth: depth) {
            return
        }
        while true {
            _ = try requiredJSONString(policy: policy)
            try consumeNameSeparator()
            try skipValue(depth: depth + 1, policy: policy)
            if try completeElement(closing: 0x7D) { return }
        }
    }

    private mutating func skipArray(
        depth: Int,
        policy: PortableJSONLexicalPolicy
    ) throws {
        if try beginContainer(opening: 0x5B, closing: 0x5D, depth: depth) {
            return
        }
        while true {
            try skipValue(depth: depth + 1, policy: policy)
            if try completeElement(closing: 0x5D) { return }
        }
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

    mutating func skipWhitespace() {
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

/// A path-aware bounded scan of the two Chat-root public namespaces. Values at
/// every other path are advanced over without constructing a Swift String.
private struct PortableChatJSONScanner {
    private enum ObjectContext {
        case root
        case draft
    }

    private var cursor: PortableJSONCursor
    private var draftID: String?
    private var messageIDs: [String]?

    init(data: Data) {
        cursor = PortableJSONCursor(data: data)
    }

    mutating func scan() throws -> PortableChatRawDurablePublicIDs {
        cursor.skipWhitespace()
        try parseObject(depth: 0, context: .root)
        try cursor.finishDocument()
        guard let draftID,
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
        if try cursor.beginContainer(opening: 0x7B, closing: 0x7D, depth: depth) {
            if context == .draft {
                throw PortableChatPersistenceError.invalidJSON
            }
            return
        }

        var keys: Set<String> = []
        while true {
            let key = try cursor.requiredJSONString(policy: .strict)
            if !keys.insert(key).inserted,
               isRelevant(key, in: context)
            {
                throw PortableChatPersistenceError.invalidJSON
            }
            try cursor.consumeNameSeparator()
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
                draftID = try cursor.requiredJSONString(policy: .strict)
            default:
                try cursor.skipValue(depth: depth + 1, policy: .strict)
            }
            if try cursor.completeElement(closing: 0x7D) {
                if context == .draft, draftID == nil {
                    throw PortableChatPersistenceError.invalidJSON
                }
                return
            }
        }
    }

    private mutating func parseMessageIDs(depth: Int) throws -> [String] {
        if try cursor.beginContainer(opening: 0x5B, closing: 0x5D, depth: depth) {
            return []
        }

        var values: [String] = []
        while true {
            values.append(try cursor.requiredJSONString(policy: .strict))
            if try cursor.completeElement(closing: 0x5D) { return values }
        }
    }

    private func isRelevant(_ key: String, in context: ObjectContext) -> Bool {
        switch context {
        case .root:
            key == "draft" || key == "messageIds"
        case .draft:
            key == "draftId"
        }
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
    private var cursor: PortableJSONCursor
    private let duplicatePolicy: PortableInvocationJSONDuplicatePolicy
    private var publicIDs = PortableInvocationDurablePublicIDs()

    init(data: Data, duplicatePolicy: PortableInvocationJSONDuplicatePolicy) {
        cursor = PortableJSONCursor(data: data)
        self.duplicatePolicy = duplicatePolicy
    }

    mutating func scan() throws -> PortableInvocationDurablePublicIDs {
        cursor.skipWhitespace()
        try parseObject(depth: 0)
        try cursor.finishDocument()
        return publicIDs
    }

    private mutating func parseObject(depth: Int) throws {
        if try cursor.beginContainer(opening: 0x7B, closing: 0x7D, depth: depth) {
            return
        }

        var keys: Set<String> = []
        while true {
            let key = try cursor.requiredJSONString(policy: .routing)
            if !keys.insert(key).inserted, rejectsDuplicate(key, depth: depth) {
                throw PortableChatPersistenceError.invalidJSON
            }
            try cursor.consumeNameSeparator()
            try parseValue(
                depth: depth + 1,
                publicIDKey: Self.durablePublicIDKeys.contains(key) ? key : nil
            )
            if try cursor.completeElement(closing: 0x7D) { return }
        }
    }

    private mutating func parseArray(depth: Int) throws {
        if try cursor.beginContainer(opening: 0x5B, closing: 0x5D, depth: depth) {
            return
        }

        while true {
            try parseValue(depth: depth + 1, publicIDKey: nil)
            if try cursor.completeElement(closing: 0x5D) { return }
        }
    }

    private mutating func parseValue(
        depth: Int,
        publicIDKey: String?
    ) throws {
        guard let currentByte = cursor.currentByte else {
            throw PortableChatPersistenceError.invalidJSON
        }
        switch currentByte {
        case 0x22:
            let value = try cursor.parseJSONString(
                materialize: publicIDKey != nil,
                policy: .routing
            )
            if let publicIDKey, let value {
                publicIDs.insert(value, for: publicIDKey)
            }
        case 0x7B:
            try parseObject(depth: depth)
        case 0x5B:
            try parseArray(depth: depth)
        default:
            try cursor.parsePrimitive(policy: .routing)
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
}

private struct CoachInvocationDTO: Codable {
    let schemaVersion: UInt32
    let invocationId: String
    let attemptId: String?
    let providerIdempotencyValue: String?
    let attempts: [CoachProviderAttemptDTO]?
    let libraryId: String
    let chatId: String
    let pendingUserTurnId: String?
    let draftId: String?
    let draftVersion: UInt64?
    let responsePositionId: String?
    let intent: CoachInvocationIntentDTO?
    let expectedManifestRevision: UInt64
    let profileRevisionId: String?
    let profileStatementGeneration: UInt64?
    let admittedAt: String
    let terminalFailure: String?
    let transcriptReadFailure: PortableCoachTranscriptReadFailureSummaryDTO?
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
    let userMessageId: String?
    let coachMessageId: String?
    let freshDraftId: String?
    let publicationAuthority: CoachProviderAttemptPublicationAuthorityDTO?

    init(
        _ attempt: CoachProviderAttempt,
        usesSealedAuthority: Bool
    ) throws {
        guard let authority = attempt.publicationAuthority else {
            throw PortableChatPersistenceError.invalidLayout
        }
        attemptId = attempt.id.rawValue
        ordinal = attempt.ordinal
        kind = attempt.kind.rawValue
        if usesSealedAuthority {
            userMessageId = nil
            coachMessageId = nil
            freshDraftId = nil
            publicationAuthority =
                CoachProviderAttemptPublicationAuthorityDTO(authority)
        } else {
            guard case let .answerPendingUserTurn(
                userMessageID,
                coachMessageID,
                freshDraftID
            ) = authority else {
                throw PortableChatPersistenceError.invalidLayout
            }
            userMessageId = userMessageID.rawValue
            coachMessageId = coachMessageID.rawValue
            freshDraftId = freshDraftID.rawValue
            publicationAuthority = nil
        }
    }

    func domainValue(usesSealedAuthority: Bool) throws -> CoachProviderAttempt {
        guard let parsedKind = CoachProviderAttemptKind(rawValue: kind)
        else { throw PortableChatPersistenceError.invalidJSON }
        let authority: CoachProviderAttemptPublicationAuthority
        if usesSealedAuthority {
            guard userMessageId == nil,
                  coachMessageId == nil,
                  freshDraftId == nil,
                  let publicationAuthority
            else { throw PortableChatPersistenceError.invalidJSON }
            authority = try publicationAuthority.domainValue()
        } else {
            guard let userMessageId,
                  let coachMessageId,
                  let freshDraftId,
                  publicationAuthority == nil
            else { throw PortableChatPersistenceError.invalidJSON }
            authority = try CoachProviderAttemptPublicationAuthority(
                userMessageID: ChatMessageID(userMessageId),
                coachMessageID: ChatMessageID(coachMessageId),
                freshDraftID: ChatDraftID(freshDraftId)
            )
        }
        return try CoachProviderAttempt(
            durableID: CoachProviderAttemptID(attemptId),
            ordinal: ordinal,
            kind: parsedKind,
            publicationAuthority: authority
        )
    }
}

private struct CoachInvocationIntentDTO: Codable, Equatable {
    let kind: String
    let pendingUserTurnId: String?
    let draftId: String?
    let draftVersion: UInt64?
    let responsePositionId: String?
    let sourceEffectIdentity: ChatProfileEffectIdentityDTO?
    let resultResponsePositionId: String?

    init(_ intent: CoachInvocationIntent) throws {
        switch intent {
        case let .answerPendingUserTurn(
            pendingUserTurnID,
            draftID,
            draftVersion,
            responsePositionID
        ):
            kind = "answerPendingUserTurn"
            pendingUserTurnId = pendingUserTurnID.rawValue
            draftId = draftID.rawValue
            self.draftVersion = draftVersion
            responsePositionId = responsePositionID.rawValue
            sourceEffectIdentity = nil
            resultResponsePositionId = nil
        case let .reconsiderProfileChange(
            sourceEffectIdentity,
            resultResponsePositionID
        ):
            kind = "reconsiderProfileChange"
            pendingUserTurnId = nil
            draftId = nil
            draftVersion = nil
            responsePositionId = nil
            self.sourceEffectIdentity =
                ChatProfileEffectIdentityDTO(sourceEffectIdentity)
            resultResponsePositionId = resultResponsePositionID.rawValue
        }
    }

    func domainValue() throws -> CoachInvocationIntent {
        switch kind {
        case "answerPendingUserTurn":
            guard let pendingUserTurnId,
                  let draftId,
                  let draftVersion,
                  let responsePositionId,
                  sourceEffectIdentity == nil,
                  resultResponsePositionId == nil
            else { throw PortableChatPersistenceError.invalidJSON }
            return .answerPendingUserTurn(
                pendingUserTurnID: try PendingUserTurnID(pendingUserTurnId),
                draftID: try ChatDraftID(draftId),
                draftVersion: draftVersion,
                responsePositionID: try ChatResponsePositionID(
                    responsePositionId
                )
            )
        case "reconsiderProfileChange":
            guard pendingUserTurnId == nil,
                  draftId == nil,
                  draftVersion == nil,
                  responsePositionId == nil,
                  let sourceEffectIdentity,
                  let resultResponsePositionId
            else { throw PortableChatPersistenceError.invalidJSON }
            return .reconsiderProfileChange(
                sourceEffectIdentity: try sourceEffectIdentity.domainValue(),
                resultResponsePositionID: try ChatResponsePositionID(
                    resultResponsePositionId
                )
            )
        default:
            throw PortableChatPersistenceError.invalidJSON
        }
    }
}

private struct CoachProviderAttemptPublicationAuthorityDTO: Codable, Equatable {
    let kind: String
    let userMessageId: String?
    let coachMessageId: String
    let freshDraftId: String?

    init(_ authority: CoachProviderAttemptPublicationAuthority) {
        switch authority {
        case let .answerPendingUserTurn(
            userMessageID,
            coachMessageID,
            freshDraftID
        ):
            kind = "answerPendingUserTurn"
            userMessageId = userMessageID.rawValue
            coachMessageId = coachMessageID.rawValue
            freshDraftId = freshDraftID.rawValue
        case let .reconsiderProfileChange(coachMessageID):
            kind = "reconsiderProfileChange"
            userMessageId = nil
            coachMessageId = coachMessageID.rawValue
            freshDraftId = nil
        }
    }

    func domainValue() throws -> CoachProviderAttemptPublicationAuthority {
        switch kind {
        case "answerPendingUserTurn":
            guard let userMessageId, let freshDraftId else {
                throw PortableChatPersistenceError.invalidJSON
            }
            return try CoachProviderAttemptPublicationAuthority(
                userMessageID: ChatMessageID(userMessageId),
                coachMessageID: ChatMessageID(coachMessageId),
                freshDraftID: ChatDraftID(freshDraftId)
            )
        case "reconsiderProfileChange":
            guard userMessageId == nil, freshDraftId == nil else {
                throw PortableChatPersistenceError.invalidJSON
            }
            return .reconsiderProfileChange(
                coachMessageID: try ChatMessageID(coachMessageId)
            )
        default:
            throw PortableChatPersistenceError.invalidJSON
        }
    }
}

private struct ChatProfileEffectIdentityDTO: Codable, Equatable {
    let kind: String
    let proposalId: String?
    let responsePositionId: String?

    init(_ identity: ChatProfileEffectIdentity) {
        switch identity {
        case let .proposal(proposalID):
            kind = "proposal"
            proposalId = proposalID.rawValue
            responsePositionId = nil
        case let .evidencePublication(responsePositionID):
            kind = "evidencePublication"
            proposalId = nil
            responsePositionId = responsePositionID.rawValue
        }
    }

    func domainValue() throws -> ChatProfileEffectIdentity {
        switch kind {
        case "proposal":
            guard let proposalId, responsePositionId == nil else {
                throw PortableChatPersistenceError.invalidJSON
            }
            return .proposal(try ProfileChangeProposalID(proposalId))
        case "evidencePublication":
            guard proposalId == nil, let responsePositionId else {
                throw PortableChatPersistenceError.invalidJSON
            }
            return .evidencePublication(
                try ChatResponsePositionID(responsePositionId)
            )
        default:
            throw PortableChatPersistenceError.invalidJSON
        }
    }
}

private struct InvocationPublicationProofDTO: Codable {
    let schemaVersion: UInt32
    let kind: String?
    let invocationId: String
    let libraryId: String
    let chatId: String
    let responsePositionId: String
    let publishedManifestRevision: UInt64
    let publishedChatSha256: String
    let stableChatSha256: String
    let memorySha256: String
    let messageIds: [String]
    let coachMessageId: String
    let coachMessageSha256: String?
    let proposalSha256: String?
    let profileEvidencePublicationSha256: String?
    let pendingUserTurnId: String?
    let pendingUserTurnSha256: String?
    let userMessageId: String?
    let userMessageSha256: String?
    let freshDraftId: String?
    let freshDraftVersion: UInt64?
    let freshDraftSha256: String?
    let sourceEffect: ChatProfileEffectIdentityDTO?
    let baseManifestRevision: UInt64?
    let baseChatSha256: String?
    let baseMemorySha256: String?
    let sourceEffectSha256: String?
    let profileReconsiderationSha256: String?
}
