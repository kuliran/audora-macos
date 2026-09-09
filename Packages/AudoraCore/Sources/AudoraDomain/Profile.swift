public enum ProfileIdentityError: Error, Equatable, Sendable {
    case invalidStatementID
    case invalidChangeProposalID
    case invalidWriteIntentID
}

public struct ProfileStatementID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard TypedIdentifierValidator.isValid(rawValue, prefix: "stm-") else {
            throw ProfileIdentityError.invalidStatementID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ProfileChangeProposalID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard TypedIdentifierValidator.isValid(rawValue, prefix: "prp-") else {
            throw ProfileIdentityError.invalidChangeProposalID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ProfileWriteIntentID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard TypedIdentifierValidator.isValid(rawValue, prefix: "pwi-") else {
            throw ProfileIdentityError.invalidWriteIntentID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum ProfileStatementKind: String, Equatable, Sendable, CaseIterable {
    case goal
    case coachingPreference
    case selfAssessment
    case speakingObservation
    case growthDirection
}

public enum ProfileStatementError: Error, Equatable, Sendable {
    case invalidWording
    case supportingSessionCountMismatch
}

public struct ProfileStatement: Equatable, Sendable {
    public let statementID: ProfileStatementID
    public let statementKind: ProfileStatementKind
    public let wording: String
    public let supportingSessionCount: UInt32
    public let evidence: [EvidenceReference]

    public init(
        statementID: ProfileStatementID,
        statementKind: ProfileStatementKind,
        wording: String,
        supportingSessionCount: UInt32,
        evidence: [EvidenceReference]
    ) throws {
        guard wording.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) else {
            throw ProfileStatementError.invalidWording
        }
        guard let distinctCount = UInt32(
            exactly: Set(evidence.map(\.sessionID)).count
        ), supportingSessionCount == distinctCount else {
            throw ProfileStatementError.supportingSessionCountMismatch
        }
        self.statementID = statementID
        self.statementKind = statementKind
        self.wording = wording
        self.supportingSessionCount = supportingSessionCount
        self.evidence = evidence
    }
}

public enum ProfileRevisionError: Error, Equatable, Sendable {
    case duplicateStatementID
}

public struct ProfileRevision: Equatable, Sendable {
    public static let schemaVersion: UInt32 = 1

    public let revisionID: ProfileRevisionID
    public let parentRevisionID: ProfileRevisionID?
    public let generation: UInt64
    public let statementGeneration: UInt64
    public let createdAt: UTCInstant
    public let statements: [ProfileStatement]

    public init(
        revisionID: ProfileRevisionID,
        parentRevisionID: ProfileRevisionID?,
        generation: UInt64,
        statementGeneration: UInt64,
        createdAt: UTCInstant,
        statements: [ProfileStatement]
    ) throws {
        guard Set(statements.map(\.statementID)).count == statements.count else {
            throw ProfileRevisionError.duplicateStatementID
        }
        self.revisionID = revisionID
        self.parentRevisionID = parentRevisionID
        self.generation = generation
        self.statementGeneration = statementGeneration
        self.createdAt = createdAt
        self.statements = statements
    }

    public func statement(id: ProfileStatementID) -> ProfileStatement? {
        statements.first(where: { $0.statementID == id })
    }
}

public struct ProfileProposalTarget: Equatable, Sendable {
    public let statementID: ProfileStatementID
    public let statementKind: ProfileStatementKind
    public let wording: String

    public init(
        statementID: ProfileStatementID,
        statementKind: ProfileStatementKind,
        wording: String
    ) throws {
        guard ProfileText.isValidWording(wording) else {
            throw ProfileStatementError.invalidWording
        }
        self.statementID = statementID
        self.statementKind = statementKind
        self.wording = wording
    }

    public init(statement: ProfileStatement) {
        statementID = statement.statementID
        statementKind = statement.statementKind
        wording = statement.wording
    }

    public func matches(_ statement: ProfileStatement) -> Bool {
        statement.statementID == statementID &&
            statement.statementKind == statementKind &&
            statement.wording == wording
    }
}

public struct ProfileProposedStatement: Equatable, Sendable {
    public let statementID: ProfileStatementID
    public let statementKind: ProfileStatementKind
    public let wording: String
    public let evidence: [EvidenceReference]

    public init(
        statementID: ProfileStatementID,
        statementKind: ProfileStatementKind,
        wording: String,
        evidence: [EvidenceReference]
    ) throws {
        guard ProfileText.isValidWording(wording) else {
            throw ProfileStatementError.invalidWording
        }
        self.statementID = statementID
        self.statementKind = statementKind
        self.wording = wording
        self.evidence = evidence
    }
}

public enum ProfileProposalChange: Equatable, Sendable {
    case add(statement: ProfileProposedStatement)
    case replace(
        target: ProfileProposalTarget,
        replacement: ProfileProposedStatement
    )
    case retire(target: ProfileProposalTarget, evidence: [EvidenceReference])

    public var evidence: [EvidenceReference] {
        switch self {
        case let .add(statement):
            statement.evidence
        case let .replace(_, replacement):
            replacement.evidence
        case let .retire(_, evidence):
            evidence
        }
    }

    fileprivate var target: ProfileProposalTarget? {
        switch self {
        case .add:
            nil
        case let .replace(target, _), let .retire(target, _):
            target
        }
    }

    fileprivate var proposedStatement: ProfileProposedStatement? {
        switch self {
        case let .add(statement), let .replace(_, statement):
            statement
        case .retire:
            nil
        }
    }
}

public enum ProfileEvidenceAppendError: Error, Equatable, Sendable {
    case emptyEvidence
}

public struct ProfileEvidenceAppend: Equatable, Sendable {
    public let target: ProfileProposalTarget
    public let evidence: [EvidenceReference]

    public var targetStatementID: ProfileStatementID { target.statementID }

    public init(
        target: ProfileProposalTarget,
        evidence: [EvidenceReference]
    ) throws {
        guard !evidence.isEmpty else {
            throw ProfileEvidenceAppendError.emptyEvidence
        }
        self.target = target
        self.evidence = evidence
    }
}

public enum ProfileChangeProposalError: Error, Equatable, Sendable {
    case emptyChanges
    case conflictingSemanticTarget
    case conflictingEvidenceAppend
    case inconsistentTarget
    case duplicateProposedStatementID
    case statementIDCollision
    case replacementKindMismatch
}

public struct ProfileChangeProposal: Equatable, Sendable {
    public static let schemaVersion: UInt32 = 1

    public let id: ProfileChangeProposalID
    public let chatID: ChatID
    public let responsePositionID: ChatResponsePositionID
    public let baseProfile: CoachProfileProvenance
    public let changes: [ProfileProposalChange]
    public let evidenceAppends: [ProfileEvidenceAppend]
    public let createdAt: UTCInstant

    public init(
        id: ProfileChangeProposalID,
        chatID: ChatID,
        responsePositionID: ChatResponsePositionID,
        baseProfile: CoachProfileProvenance,
        changes: [ProfileProposalChange],
        evidenceAppends: [ProfileEvidenceAppend] = [],
        createdAt: UTCInstant
    ) throws {
        guard !changes.isEmpty else {
            throw ProfileChangeProposalError.emptyChanges
        }

        var normalizedChanges: [ProfileProposalChange] = []
        var semanticTargets: [ProfileStatementID: ProfileProposalChange] = [:]
        var proposedStatementIDs: Set<ProfileStatementID> = []

        for change in changes {
            if let target = change.target {
                if let existing = semanticTargets[target.statementID] {
                    guard existing == change else {
                        throw ProfileChangeProposalError.conflictingSemanticTarget
                    }
                    continue
                }
                semanticTargets[target.statementID] = change
            }
            if case let .replace(target, replacement) = change,
               target.statementKind != replacement.statementKind
            {
                throw ProfileChangeProposalError.replacementKindMismatch
            }
            if let proposed = change.proposedStatement,
               !proposedStatementIDs.insert(proposed.statementID).inserted
            {
                throw ProfileChangeProposalError.duplicateProposedStatementID
            }
            normalizedChanges.append(change)
        }

        let semanticTargetIDs = Set(semanticTargets.keys)
        guard semanticTargetIDs.isDisjoint(with: proposedStatementIDs) else {
            throw ProfileChangeProposalError.statementIDCollision
        }

        var appendTargets: [ProfileStatementID: ProfileProposalTarget] = [:]
        for append in evidenceAppends {
            guard semanticTargets[append.target.statementID] == nil else {
                throw ProfileChangeProposalError.conflictingEvidenceAppend
            }
            if let existing = appendTargets[append.target.statementID],
               existing != append.target
            {
                throw ProfileChangeProposalError.inconsistentTarget
            }
            appendTargets[append.target.statementID] = append.target
        }

        self.id = id
        self.chatID = chatID
        self.responsePositionID = responsePositionID
        self.baseProfile = baseProfile
        self.changes = normalizedChanges
        self.evidenceAppends = evidenceAppends
        self.createdAt = createdAt
    }
}

public enum ProfileProposalApplicationError: Error, Equatable, Sendable {
    case staleSemanticBase
    case targetNotFound
    case targetMismatch
    case statementIDCollision
    case intendedRevisionIDCollision
    case generationOverflow
}

public extension ProfileChangeProposal {
    /// Applies one reviewed semantic batch to the freshest Profile Revision that
    /// still has the Proposal's Statement generation. A newer physical revision
    /// caused only by evidence therefore remains a valid base.
    func applying(
        to base: ProfileRevision?,
        intendedRevisionID: ProfileRevisionID,
        createdAt: UTCInstant
    ) throws -> ProfileRevision {
        try applying(
            to: base,
            currentHeadGeneration: base?.generation ?? baseProfile.statementGeneration,
            intendedRevisionID: intendedRevisionID,
            createdAt: createdAt
        )
    }

    /// Exact variant used by the commit coordinator. The explicit head watermark
    /// is required when recovery left the Profile null without a parent revision.
    func applying(
        to base: ProfileRevision?,
        currentHeadGeneration: UInt64,
        intendedRevisionID: ProfileRevisionID,
        createdAt: UTCInstant
    ) throws -> ProfileRevision {
        guard base?.statementGeneration ?? baseProfile.statementGeneration ==
            baseProfile.statementGeneration,
              (base == nil) == (baseProfile.revisionID == nil),
              base?.generation == nil || base?.generation == currentHeadGeneration,
              currentHeadGeneration >= baseProfile.statementGeneration
        else {
            throw ProfileProposalApplicationError.staleSemanticBase
        }
        if base?.revisionID == intendedRevisionID {
            throw ProfileProposalApplicationError.intendedRevisionIDCollision
        }

        let originalStatements = base?.statements ?? []
        for target in changes.compactMap(\.target) + evidenceAppends.map(\.target) {
            guard let statement = originalStatements.first(where: {
                $0.statementID == target.statementID
            }) else {
                throw ProfileProposalApplicationError.targetNotFound
            }
            guard target.matches(statement) else {
                throw ProfileProposalApplicationError.targetMismatch
            }
        }

        let proposedIDs = Set(changes.compactMap {
            $0.proposedStatement?.statementID
        })
        guard Set(originalStatements.map(\.statementID)).isDisjoint(
            with: proposedIDs
        ) else {
            throw ProfileProposalApplicationError.statementIDCollision
        }

        let (generation, generationOverflow) =
            currentHeadGeneration.addingReportingOverflow(1)
        let (statementGeneration, statementGenerationOverflow) =
            baseProfile.statementGeneration.addingReportingOverflow(1)
        guard !generationOverflow, !statementGenerationOverflow else {
            throw ProfileProposalApplicationError.generationOverflow
        }

        var statements = originalStatements
        for change in changes {
            switch change {
            case let .add(proposed):
                statements.append(try proposed.materialized())

            case let .replace(target, replacement):
                guard let index = statements.firstIndex(where: {
                    $0.statementID == target.statementID
                }) else {
                    throw ProfileProposalApplicationError.targetNotFound
                }
                let combinedEvidence = statements[index].evidence + replacement.evidence
                statements[index] = try replacement.materialized(
                    statementKind: target.statementKind,
                    evidence: combinedEvidence
                )

            case let .retire(target, _):
                guard let index = statements.firstIndex(where: {
                    $0.statementID == target.statementID
                }) else {
                    throw ProfileProposalApplicationError.targetNotFound
                }
                statements.remove(at: index)
            }
        }

        for append in evidenceAppends {
            guard let index = statements.firstIndex(where: {
                $0.statementID == append.target.statementID
            }) else {
                throw ProfileProposalApplicationError.targetNotFound
            }
            let current = statements[index]
            let unionedEvidence = ProfileEvidence.union(
                current.evidence,
                with: append.evidence
            )
            statements[index] = try ProfileStatement.materialized(
                statementID: current.statementID,
                statementKind: current.statementKind,
                wording: current.wording,
                evidence: unionedEvidence
            )
        }

        return try ProfileRevision(
            revisionID: intendedRevisionID,
            parentRevisionID: base?.revisionID,
            generation: generation,
            statementGeneration: statementGeneration,
            createdAt: createdAt,
            statements: statements
        )
    }
}

/// The fields of `ProfileHead` that participate in the Profile coordinator's
/// compare-and-swap. Display time is deliberately not part of write authority.
public struct ProfileHeadAuthority: Equatable, Sendable {
    public let generation: UInt64
    public let statementGeneration: UInt64
    public let selection: ProfileSelection

    public init(
        generation: UInt64,
        statementGeneration: UInt64,
        selection: ProfileSelection
    ) {
        self.generation = generation
        self.statementGeneration = statementGeneration
        self.selection = selection
    }

    public init(head: ProfileHead) {
        self.init(
            generation: head.generation,
            statementGeneration: head.statementGeneration,
            selection: head.selection
        )
    }

    public var currentRevisionID: ProfileRevisionID? {
        guard case let .revision(pointer) = selection else { return nil }
        return pointer.revisionID
    }

    public var currentRevisionSHA256: String? {
        guard case let .revision(pointer) = selection else { return nil }
        return pointer.sha256
    }
}

public extension ProfileHead {
    var authority: ProfileHeadAuthority { ProfileHeadAuthority(head: self) }
}

public enum ProfileWriteIntentError: Error, Equatable, Sendable {
    case invalidExpectedHead
    case semanticBaseMismatch
    case intendedRevisionIDCollision
}

public struct ProfileWriteIntent: Equatable, Sendable {
    public static let schemaVersion: UInt32 = 1

    public let id: ProfileWriteIntentID
    public let proposalID: ProfileChangeProposalID
    public let chatID: ChatID
    public let expectedHead: ProfileHeadAuthority
    public let intendedRevisionID: ProfileRevisionID
    public let createdAt: UTCInstant

    public init(
        id: ProfileWriteIntentID,
        proposal: ProfileChangeProposal,
        expectedHead: ProfileHead,
        intendedRevisionID: ProfileRevisionID,
        createdAt: UTCInstant
    ) throws {
        try self.init(
            id: id,
            proposal: proposal,
            expectedHead: expectedHead.authority,
            intendedRevisionID: intendedRevisionID,
            createdAt: createdAt
        )
    }

    public init(
        id: ProfileWriteIntentID,
        proposal: ProfileChangeProposal,
        expectedHead: ProfileHeadAuthority,
        intendedRevisionID: ProfileRevisionID,
        createdAt: UTCInstant
    ) throws {
        guard expectedHead.statementGeneration <= expectedHead.generation else {
            throw ProfileWriteIntentError.invalidExpectedHead
        }
        guard expectedHead.statementGeneration ==
            proposal.baseProfile.statementGeneration,
              (expectedHead.currentRevisionID == nil) ==
                (proposal.baseProfile.revisionID == nil)
        else {
            throw ProfileWriteIntentError.semanticBaseMismatch
        }
        guard expectedHead.currentRevisionID != intendedRevisionID else {
            throw ProfileWriteIntentError.intendedRevisionIDCollision
        }
        self.id = id
        proposalID = proposal.id
        chatID = proposal.chatID
        self.expectedHead = expectedHead
        self.intendedRevisionID = intendedRevisionID
        self.createdAt = createdAt
    }
}

private extension ProfileProposedStatement {
    func materialized() throws -> ProfileStatement {
        try materialized(statementKind: statementKind, evidence: evidence)
    }

    func materialized(
        statementKind: ProfileStatementKind,
        evidence: [EvidenceReference]
    ) throws -> ProfileStatement {
        try ProfileStatement.materialized(
            statementID: statementID,
            statementKind: statementKind,
            wording: wording,
            evidence: evidence
        )
    }
}

private extension ProfileStatement {
    static func materialized(
        statementID: ProfileStatementID,
        statementKind: ProfileStatementKind,
        wording: String,
        evidence: [EvidenceReference]
    ) throws -> ProfileStatement {
        guard let supportingSessionCount = UInt32(
            exactly: Set(evidence.map(\.sessionID)).count
        ) else {
            throw ProfileStatementError.supportingSessionCountMismatch
        }
        return try ProfileStatement(
            statementID: statementID,
            statementKind: statementKind,
            wording: wording,
            supportingSessionCount: supportingSessionCount,
            evidence: evidence
        )
    }
}

private enum ProfileEvidence {
    static func union(
        _ existing: [EvidenceReference],
        with appended: [EvidenceReference]
    ) -> [EvidenceReference] {
        var sessionIDs = Set(existing.map(\.sessionID))
        return existing + appended.filter {
            sessionIDs.insert($0.sessionID).inserted
        }
    }
}

private enum ProfileText {
    static func isValidWording(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: { !$0.properties.isWhitespace })
    }
}
