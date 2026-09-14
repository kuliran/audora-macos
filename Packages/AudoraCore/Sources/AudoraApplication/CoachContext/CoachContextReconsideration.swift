import AudoraDomain

enum CoachContextReconsiderTriggerError: Error, Equatable, Sendable {
    case emptyBasis
    case duplicateInactiveTargetID
    case inactiveTargetResolutionMismatch
    case evidenceNotAttached
}

/// The exact, app-derived provider trigger for one stale Profile effect.
///
/// Keeping the complete previous wrappers and inactive target snapshots typed
/// until this boundary prevents a provider adapter from rebuilding semantics
/// from Proposal-card prose.
struct CoachContextReconsiderTrigger: Equatable, Sendable {
    let previousChanges: [ProfileProposalChange]
    let inactiveEditTargets: [ProfileStatement]
    let inactiveTargetsEvidence: [ProfileEvidenceAppend]

    private let canonical: CanonicalJSONValue

    init(
        basis: ProfileReconsiderationBasis,
        attachments: ChatAttachments
    ) throws {
        try self.init(
            previousChanges: basis.previousChanges,
            inactiveEditTargets: basis.inactiveEditTargets,
            inactiveTargetsEvidence: basis.inactiveTargetsEvidence,
            latestProfile: basis.latestProfile,
            attachments: attachments
        )
    }

    /// Explicit semantic-validation seam retained for fail-closed contract tests.
    /// Production callers construct the same value from ProfileReconsiderationBasis.
    init(
        previousChanges: [ProfileProposalChange],
        inactiveEditTargets: [ProfileStatement],
        inactiveTargetsEvidence: [ProfileEvidenceAppend],
        latestProfile: ProfileSnapshot,
        attachments: ChatAttachments
    ) throws {
        guard !previousChanges.isEmpty || !inactiveEditTargets.isEmpty ||
            !inactiveTargetsEvidence.isEmpty
        else { throw CoachContextReconsiderTriggerError.emptyBasis }

        var inactiveByID: [ProfileStatementID: ProfileStatement] = [:]
        for statement in inactiveEditTargets {
            guard inactiveByID.updateValue(
                statement,
                forKey: statement.statementID
            ) == nil else {
                throw CoachContextReconsiderTriggerError
                    .duplicateInactiveTargetID
            }
        }

        var requiredInactiveIDs: Set<ProfileStatementID> = []
        for change in previousChanges {
            guard let target = Self.target(of: change),
                  !Self.isExact(target, in: latestProfile)
            else { continue }
            try Self.requireExactInactiveTarget(
                target,
                in: inactiveByID,
                requiredIDs: &requiredInactiveIDs
            )
        }
        for append in inactiveTargetsEvidence {
            guard !Self.isExact(append.target, in: latestProfile) else {
                throw CoachContextReconsiderTriggerError
                    .inactiveTargetResolutionMismatch
            }
            try Self.requireExactInactiveTarget(
                append.target,
                in: inactiveByID,
                requiredIDs: &requiredInactiveIDs
            )
        }
        guard requiredInactiveIDs == Set(inactiveByID.keys) else {
            throw CoachContextReconsiderTriggerError
                .inactiveTargetResolutionMismatch
        }

        let projector = CoachContextProfileProjector(attachments: attachments)
        let previous = try previousChanges.map {
            try projector.previousEdit($0)
        }
        let inactiveTargets = inactiveEditTargets.map {
            projector.profileStatement($0)
        }
        let inactiveEvidence = try inactiveTargetsEvidence.map {
            try projector.evidenceAppend($0)
        }

        var fields: [String: CanonicalJSONValue] = [
            "kind": .string("reconsiderProfileChange"),
        ]
        if !previous.isEmpty {
            fields["previousEdits"] = .array(previous)
        }
        if !inactiveTargets.isEmpty {
            fields["inactiveEditTargets"] = .array(inactiveTargets)
        }
        if !inactiveEvidence.isEmpty {
            fields["inactiveTargetsEvidence"] = .array(inactiveEvidence)
        }

        self.previousChanges = previousChanges
        self.inactiveEditTargets = inactiveEditTargets
        self.inactiveTargetsEvidence = inactiveTargetsEvidence
        canonical = .object(fields)
    }

    func canonicalValue() -> CanonicalJSONValue { canonical }

    private static func target(
        of change: ProfileProposalChange
    ) -> ProfileProposalTarget? {
        switch change {
        case .add:
            nil
        case let .replace(target, _), let .retire(target, _):
            target
        }
    }

    private static func isExact(
        _ target: ProfileProposalTarget,
        in profile: ProfileSnapshot
    ) -> Bool {
        profile.statement(id: target.statementID).map(target.matches) ?? false
    }

    private static func requireExactInactiveTarget(
        _ target: ProfileProposalTarget,
        in inactiveByID: [ProfileStatementID: ProfileStatement],
        requiredIDs: inout Set<ProfileStatementID>
    ) throws {
        guard let statement = inactiveByID[target.statementID],
              target.matches(statement)
        else {
            throw CoachContextReconsiderTriggerError
                .inactiveTargetResolutionMismatch
        }
        requiredIDs.insert(target.statementID)
    }
}

/// One attachment-aware projection used by both the latest Profile context and
/// the Reconsider trigger. Historical support stays counted while only evidence
/// from an exact attached Session/Transcript Revision is provider-visible.
struct CoachContextProfileProjector: Sendable {
    private struct EvidencePair: Hashable, Sendable {
        let sessionID: SessionID
        let transcriptRevisionID: TranscriptRevisionID
    }

    private let attachmentByEvidencePair:
        [EvidencePair: ChatSessionAttachmentID]

    init(attachments: ChatAttachments) {
        attachmentByEvidencePair = Dictionary(
            uniqueKeysWithValues: attachments.values.map {
                (
                    EvidencePair(
                        sessionID: $0.sessionID,
                        transcriptRevisionID: $0.transcriptRevisionID
                    ),
                    $0.attachmentID
                )
            }
        )
    }

    func profile(_ snapshot: ProfileSnapshot) -> CanonicalJSONValue {
        .object([
            "statements": .array(snapshot.statements.map(profileStatement)),
        ])
    }

    func profileStatement(_ statement: ProfileStatement) -> CanonicalJSONValue {
        var fields: [String: CanonicalJSONValue] = [
            "statementId": .string(statement.statementID.rawValue),
            "statementKind": .string(statement.statementKind.rawValue),
            "supportingSessionCount": .integer(
                Int64(statement.supportingSessionCount)
            ),
            "wording": .string(statement.wording),
        ]
        let visibleEvidence = statement.evidence.compactMap(evidencePointer)
        if !visibleEvidence.isEmpty {
            fields["evidence"] = .array(visibleEvidence)
        }
        return .object(fields)
    }

    func previousEdit(
        _ change: ProfileProposalChange
    ) throws -> CanonicalJSONValue {
        let edit: CanonicalJSONValue
        let evidence: [EvidenceReference]
        switch change {
        case let .add(statement):
            edit = .object([
                "kind": .string("add"),
                "statementKind": .string(statement.statementKind.rawValue),
                "wording": .string(statement.wording),
            ])
            evidence = statement.evidence
        case let .replace(target, replacement):
            edit = .object([
                "kind": .string("replace"),
                "targetStatementId": .string(target.statementID.rawValue),
                "wording": .string(replacement.wording),
            ])
            evidence = replacement.evidence
        case let .retire(target, references):
            edit = .object([
                "kind": .string("retire"),
                "targetStatementId": .string(target.statementID.rawValue),
            ])
            evidence = references
        }

        var fields: [String: CanonicalJSONValue] = ["edit": edit]
        if !evidence.isEmpty {
            fields["evidence"] = .array(
                try evidence.map(requiredEvidencePointer)
            )
        }
        return .object(fields)
    }

    func evidenceAppend(
        _ append: ProfileEvidenceAppend
    ) throws -> CanonicalJSONValue {
        .object([
            "targetStatementId": .string(append.targetStatementID.rawValue),
            "evidence": .array(try append.evidence.map(requiredEvidencePointer)),
        ])
    }

    private func requiredEvidencePointer(
        _ reference: EvidenceReference
    ) throws -> CanonicalJSONValue {
        guard let value = evidencePointer(reference) else {
            throw CoachContextReconsiderTriggerError.evidenceNotAttached
        }
        return value
    }

    private func evidencePointer(
        _ reference: EvidenceReference
    ) -> CanonicalJSONValue? {
        guard let attachmentID = attachmentByEvidencePair[
            EvidencePair(
                sessionID: reference.sessionID,
                transcriptRevisionID: reference.transcriptRevisionID
            )
        ] else { return nil }

        let target: CanonicalJSONValue
        switch reference.target {
        case let .wordRange(startWordID, endWordID):
            target = .object([
                "endWordId": .string(endWordID.rawValue),
                "kind": .string("wordRange"),
                "startWordId": .string(startWordID.rawValue),
            ])
        case let .audioEvent(audioEventID):
            target = .object([
                "audioEventId": .string(audioEventID.rawValue),
                "kind": .string("audioEvent"),
            ])
        }
        return .object([
            "sessionAttachmentId": .string(attachmentID.rawValue),
            "target": target,
        ])
    }
}

/// One Application-derived Profile view. Provider-visible JSON, immutable
/// provenance, and local evidence-policy obligations cannot be supplied or
/// changed independently.
struct CoachProfileContextProjection: Equatable, Sendable {
    let value: CanonicalJSONValue
    let provenance: CoachProfileProvenance
    let evidenceObligations: CoachProfileEvidenceObligations

    init(snapshot: ProfileSnapshot, attachments: ChatAttachments) {
        value = CoachContextProfileProjector(attachments: attachments)
            .profile(snapshot)
        provenance = snapshot.provenance
        evidenceObligations = CoachProfileEvidenceObligations(profile: snapshot)
    }
}
