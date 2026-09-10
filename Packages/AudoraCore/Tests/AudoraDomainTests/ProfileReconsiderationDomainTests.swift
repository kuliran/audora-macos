import AudoraDomain
import XCTest

final class ProfileReconsiderationDomainTests: XCTestCase {
    func testSemanticProposalStalenessUsesStatementGenerationOnly() throws {
        let target = try statement(
            id: "stm-20260909T080000000Z-1ABC",
            wording: "Pause between ideas."
        )
        let base = try revision(
            id: "prf-20260909T080100000Z-2DEF",
            generation: 4,
            statementGeneration: 3,
            statements: [target]
        )
        let proposal = try semanticProposal(
            base: base,
            target: target,
            responsePosition: "rsp-20260909T080200000Z-3GHJ"
        )
        let evidenceOnlyLatest = try revision(
            id: "prf-20260909T080300000Z-4KMN",
            parent: base.revisionID,
            generation: 5,
            statementGeneration: 3,
            statements: [target]
        )
        let semanticallyChangedLatest = try revision(
            id: "prf-20260909T080400000Z-5PQR",
            parent: evidenceOnlyLatest.revisionID,
            generation: 6,
            statementGeneration: 4,
            statements: [target]
        )

        XCTAssertFalse(
            ChatProfileEffect.proposal(proposal).requiresReconsideration(
                against: ProfileSnapshot(revision: evidenceOnlyLatest)
            )
        )
        XCTAssertTrue(
            ChatProfileEffect.proposal(proposal).requiresReconsideration(
                against: ProfileSnapshot(revision: semanticallyChangedLatest)
            )
        )
    }

    func testEvidencePublicationStalenessRequiresAnExactActiveTarget() throws {
        let target = try statement(
            id: "stm-20260909T081000000Z-1ABC",
            wording: "Pause between ideas."
        )
        let append = try evidenceAppend(target: target, suffix: "2DEF")
        let publication = try ProfileEvidencePublication(
            chatID: chatID,
            responsePositionID: ChatResponsePositionID(
                "rsp-20260909T081100000Z-3GHJ"
            ),
            evidenceAppends: [append],
            createdAt: instant
        )
        let unchanged = try revision(
            id: "prf-20260909T081200000Z-4KMN",
            generation: 8,
            statementGeneration: 4,
            statements: [target]
        )
        let replacement = try statement(
            id: target.statementID.rawValue,
            wording: "Pause after each complete idea."
        )
        let changed = try revision(
            id: "prf-20260909T081300000Z-5PQR",
            parent: unchanged.revisionID,
            generation: 9,
            statementGeneration: 5,
            statements: [replacement]
        )

        XCTAssertFalse(
            ChatProfileEffect.evidencePublication(publication)
                .requiresReconsideration(
                    against: ProfileSnapshot(revision: unchanged)
                )
        )
        XCTAssertTrue(
            ChatProfileEffect.evidencePublication(publication)
                .requiresReconsideration(
                    against: ProfileSnapshot(revision: changed)
                )
        )
        XCTAssertTrue(
            ChatProfileEffect.evidencePublication(publication)
                .requiresReconsideration(
                    against: ProfileSnapshot(nullAtStatementGeneration: 6)
                )
        )
    }

    func testProposalBasisPreservesCompleteEditsAndPartitionsStandaloneEvidence() throws {
        let retiredTarget = try statement(
            id: "stm-20260909T082000000Z-1ABC",
            kind: .speakingObservation,
            wording: "I rush transitions."
        )
        let activeAppendTarget = try statement(
            id: "stm-20260909T082100000Z-2DEF",
            wording: "Pause between ideas."
        )
        let vanishedAppendTarget = try statement(
            id: "stm-20260909T082200000Z-3GHJ",
            wording: "Use a detailed outline."
        )
        let base = try revision(
            id: "prf-20260909T082300000Z-4KMN",
            generation: 10,
            statementGeneration: 7,
            statements: [retiredTarget, activeAppendTarget, vanishedAppendTarget]
        )
        let editEvidence = try evidence(suffix: "5PQR", word: "w000001")
        let activeAppend = try evidenceAppend(
            target: activeAppendTarget,
            suffix: "6RST"
        )
        let inactiveAppend = try evidenceAppend(
            target: vanishedAppendTarget,
            suffix: "7VWX"
        )
        let previousChange = ProfileProposalChange.retire(
            target: ProfileProposalTarget(statement: retiredTarget),
            evidence: [editEvidence]
        )
        let proposal = try ProfileChangeProposal(
            id: ProfileChangeProposalID("prp-20260909T082400000Z-8XYZ"),
            chatID: chatID,
            responsePositionID: ChatResponsePositionID(
                "rsp-20260909T082400000Z-9ABC"
            ),
            baseProfile: base.provenance,
            changes: [previousChange],
            evidenceAppends: [activeAppend, inactiveAppend],
            createdAt: instant
        )
        let latest = try revision(
            id: "prf-20260909T082500000Z-1DEF",
            parent: base.revisionID,
            generation: 11,
            statementGeneration: 8,
            statements: [activeAppendTarget]
        )

        let basis = try ProfileReconsiderationBasis(
            sourceEffect: .proposal(proposal),
            baseProfile: ProfileSnapshot(revision: base),
            latestProfile: ProfileSnapshot(revision: latest)
        )

        XCTAssertEqual(basis.sourceChatID, proposal.chatID)
        XCTAssertEqual(
            basis.sourceResponsePositionID,
            proposal.responsePositionID
        )
        XCTAssertEqual(basis.previousChanges, [previousChange])
        XCTAssertEqual(
            basis.inactiveEditTargets,
            [retiredTarget, vanishedAppendTarget]
        )
        XCTAssertEqual(basis.inactiveTargetsEvidence, [inactiveAppend])
        XCTAssertEqual(basis.retainedActiveEvidenceAppends, [activeAppend])
        XCTAssertEqual(basis.latestProfile.provenance, latest.provenance)
    }

    func testStaleEvidenceBasisRetainsActiveAppendsAndResolvesVanishedTargetsOnce() throws {
        let active = try statement(
            id: "stm-20260909T083000000Z-1ABC",
            wording: "Pause between ideas."
        )
        let vanished = try statement(
            id: "stm-20260909T083100000Z-2DEF",
            wording: "Use a detailed outline."
        )
        let base = try revision(
            id: "prf-20260909T083200000Z-3GHJ",
            generation: 14,
            statementGeneration: 9,
            statements: [active, vanished]
        )
        let activeAppend = try evidenceAppend(target: active, suffix: "4KMN")
        let vanishedAppend = try evidenceAppend(target: vanished, suffix: "5PQR")
        let publication = try ProfileEvidencePublication(
            chatID: chatID,
            responsePositionID: ChatResponsePositionID(
                "rsp-20260909T083300000Z-6RST"
            ),
            evidenceAppends: [activeAppend, vanishedAppend],
            createdAt: instant
        )
        let latest = try revision(
            id: "prf-20260909T083400000Z-7VWX",
            parent: base.revisionID,
            generation: 15,
            statementGeneration: 10,
            statements: [active]
        )

        let basis = try ProfileReconsiderationBasis(
            sourceEffect: .evidencePublication(publication),
            baseProfile: ProfileSnapshot(revision: base),
            latestProfile: ProfileSnapshot(revision: latest)
        )

        XCTAssertEqual(basis.previousChanges, [])
        XCTAssertEqual(basis.inactiveEditTargets, [vanished])
        XCTAssertEqual(basis.inactiveTargetsEvidence, [vanishedAppend])
        XCTAssertEqual(basis.retainedActiveEvidenceAppends, [activeAppend])
    }

    func testBasisRejectsWrongBaseUnresolvedTargetsAndNonStaleEffects() throws {
        let target = try statement(
            id: "stm-20260909T084000000Z-1ABC",
            wording: "Pause between ideas."
        )
        let base = try revision(
            id: "prf-20260909T084100000Z-2DEF",
            generation: 20,
            statementGeneration: 11,
            statements: [target]
        )
        let proposal = try semanticProposal(
            base: base,
            target: target,
            responsePosition: "rsp-20260909T084200000Z-3GHJ"
        )

        XCTAssertThrowsError(
            try ProfileReconsiderationBasis(
                sourceEffect: .proposal(proposal),
                baseProfile: ProfileSnapshot(nullAtStatementGeneration: 11),
                latestProfile: ProfileSnapshot(nullAtStatementGeneration: 12)
            )
        ) { error in
            XCTAssertEqual(
                error as? ProfileReconsiderationBasisError,
                .sourceBaseProfileMismatch
            )
        }

        XCTAssertThrowsError(
            try ProfileReconsiderationBasis(
                sourceEffect: .proposal(proposal),
                baseProfile: ProfileSnapshot(revision: base),
                latestProfile: ProfileSnapshot(revision: base)
            )
        ) { error in
            XCTAssertEqual(
                error as? ProfileReconsiderationBasisError,
                .sourceNotStale
            )
        }
    }

    func testOnlyReconsideredProposalMayContainReviewedEvidenceWithoutSemanticEdits() throws {
        let target = try statement(
            id: "stm-20260909T085000000Z-1ABC",
            wording: "Pause between ideas."
        )
        let append = try evidenceAppend(target: target, suffix: "2DEF")
        let provenance = CoachProfileProvenance(
            revisionID: try ProfileRevisionID(
                "prf-20260909T085100000Z-3GHJ"
            ),
            statementGeneration: 14
        )

        XCTAssertThrowsError(
            try ProfileChangeProposal(
                id: ProfileChangeProposalID("prp-20260909T085200000Z-4KMN"),
                chatID: chatID,
                responsePositionID: ChatResponsePositionID(
                    "rsp-20260909T085200000Z-5PQR"
                ),
                baseProfile: provenance,
                changes: [],
                evidenceAppends: [append],
                createdAt: instant
            )
        ) { error in
            XCTAssertEqual(
                error as? ProfileChangeProposalError,
                .emptyChanges
            )
        }

        let reconsidered = try ProfileChangeProposal.reconsidered(
            id: ProfileChangeProposalID("prp-20260909T085300000Z-6RST"),
            chatID: chatID,
            responsePositionID: ChatResponsePositionID(
                "rsp-20260909T085300000Z-7VWX"
            ),
            baseProfile: provenance,
            changes: [],
            evidenceAppends: [append],
            createdAt: instant
        )

        XCTAssertEqual(reconsidered.changes, [])
        XCTAssertEqual(reconsidered.evidenceAppends, [append])
        XCTAssertThrowsError(
            try ProfileChangeProposal.reconsidered(
                id: reconsidered.id,
                chatID: reconsidered.chatID,
                responsePositionID: reconsidered.responsePositionID,
                baseProfile: provenance,
                changes: [],
                evidenceAppends: [],
                createdAt: instant
            )
        ) { error in
            XCTAssertEqual(
                error as? ProfileChangeProposalError,
                .emptyEffects
            )
        }
    }

    func testReconsideredProposalMergesRetainedAppendIntoSameTargetEdit() throws {
        let target = try statement(
            id: "stm-20260909T093000000Z-1ABC",
            wording: "Pause between ideas."
        )
        let vanished = try statement(
            id: "stm-20260909T093000000Z-2DEF",
            wording: "Use a detailed outline."
        )
        let base = try revision(
            id: "prf-20260909T093100000Z-3GHJ",
            generation: 25,
            statementGeneration: 12,
            statements: [target, vanished]
        )
        let retained = try ProfileEvidenceAppend(
            target: ProfileProposalTarget(statement: target),
            evidence: [
                try evidence(suffix: "4KMN", word: "w000001"),
                try evidence(suffix: "4KMN", word: "w000002"),
            ]
        )
        let source = try ProfileChangeProposal(
            id: ProfileChangeProposalID("prp-20260909T093200000Z-5PQR"),
            chatID: chatID,
            responsePositionID: ChatResponsePositionID(
                "rsp-20260909T093200000Z-6RST"
            ),
            baseProfile: base.provenance,
            changes: [
                .retire(
                    target: ProfileProposalTarget(statement: vanished),
                    evidence: []
                ),
            ],
            evidenceAppends: [retained],
            createdAt: instant
        )
        let latest = try revision(
            id: "prf-20260909T093300000Z-7VWX",
            parent: base.revisionID,
            generation: 26,
            statementGeneration: 13,
            statements: [target]
        )
        let basis = try ProfileReconsiderationBasis(
            sourceEffect: .proposal(source),
            baseProfile: ProfileSnapshot(revision: base),
            latestProfile: ProfileSnapshot(revision: latest)
        )
        let replacementStatement = try ProfileProposedStatement(
            statementID: ProfileStatementID(
                "stm-20260909T093400000Z-8XYZ"
            ),
            statementKind: target.statementKind,
            wording: "Pause after each complete idea.",
            evidence: []
        )

        let reconsidered = try ProfileChangeProposal.reconsidered(
            id: ProfileChangeProposalID("prp-20260909T093500000Z-9ABC"),
            basis: basis,
            responsePositionID: ChatResponsePositionID(
                "rsp-20260909T093500000Z-0DEF"
            ),
            changes: [
                .replace(
                    target: ProfileProposalTarget(statement: target),
                    replacement: replacementStatement
                ),
            ],
            createdAt: instant
        )

        XCTAssertEqual(reconsidered.evidenceAppends, [])
        guard case let .replace(_, merged) = reconsidered.changes.first else {
            return XCTFail("Expected the replacement edit")
        }
        XCTAssertEqual(merged.evidence, retained.evidence)
        let accepted = try reconsidered.applying(
            to: latest,
            intendedRevisionID: ProfileRevisionID(
                "prf-20260909T093550000Z-0BCD"
            ),
            createdAt: instant
        )
        XCTAssertEqual(
            accepted.statement(id: replacementStatement.statementID)?.evidence,
            [retained.evidence[0]],
            "replace materialization keeps only the first reference per Session"
        )

        let retired = try ProfileChangeProposal.reconsidered(
            id: ProfileChangeProposalID("prp-20260909T093600000Z-1BCD"),
            basis: basis,
            responsePositionID: ChatResponsePositionID(
                "rsp-20260909T093600000Z-2EFG"
            ),
            changes: [
                .retire(
                    target: ProfileProposalTarget(statement: target),
                    evidence: []
                ),
            ],
            createdAt: instant
        )
        guard case let .retire(_, mergedRetirementEvidence) =
            retired.changes.first
        else { return XCTFail("Expected the retirement edit") }
        XCTAssertEqual(mergedRetirementEvidence, retained.evidence)
    }

    func testAcceptedReviewedEvidenceOnlyReplacementPreservesStatementGeneration() throws {
        let target = try statement(
            id: "stm-20260909T094000000Z-1ABC",
            wording: "Pause between ideas."
        )
        let base = try revision(
            id: "prf-20260909T094100000Z-2DEF",
            generation: 30,
            statementGeneration: 14,
            statements: [target]
        )
        let append = try evidenceAppend(target: target, suffix: "3GHJ")
        let proposal = try ProfileChangeProposal.reconsidered(
            id: ProfileChangeProposalID("prp-20260909T094200000Z-4KMN"),
            chatID: chatID,
            responsePositionID: ChatResponsePositionID(
                "rsp-20260909T094200000Z-5PQR"
            ),
            baseProfile: base.provenance,
            changes: [],
            evidenceAppends: [append],
            createdAt: instant
        )

        let applied = try proposal.applying(
            to: base,
            intendedRevisionID: ProfileRevisionID(
                "prf-20260909T094300000Z-6RST"
            ),
            createdAt: instant
        )

        XCTAssertEqual(applied.generation, 31)
        XCTAssertEqual(applied.statementGeneration, 14)
        XCTAssertEqual(
            applied.statement(id: target.statementID)?.evidence,
            append.evidence
        )
    }

    private var chatID: ChatID {
        try! ChatID("cht-20260909T080000000Z-9XYZ")
    }

    private var instant: UTCInstant {
        try! UTCInstant("2026-09-09T08:00:00.000Z")
    }

    private func semanticProposal(
        base: ProfileRevision,
        target: ProfileStatement,
        responsePosition: String
    ) throws -> ProfileChangeProposal {
        try ProfileChangeProposal(
            id: ProfileChangeProposalID("prp-20260909T090000000Z-8XYZ"),
            chatID: chatID,
            responsePositionID: ChatResponsePositionID(responsePosition),
            baseProfile: base.provenance,
            changes: [
                .retire(
                    target: ProfileProposalTarget(statement: target),
                    evidence: []
                ),
            ],
            createdAt: instant
        )
    }

    private func revision(
        id: String,
        parent: ProfileRevisionID? = nil,
        generation: UInt64,
        statementGeneration: UInt64,
        statements: [ProfileStatement]
    ) throws -> ProfileRevision {
        try ProfileRevision(
            revisionID: ProfileRevisionID(id),
            parentRevisionID: parent,
            generation: generation,
            statementGeneration: statementGeneration,
            createdAt: instant,
            statements: statements
        )
    }

    private func statement(
        id: String,
        kind: ProfileStatementKind = .goal,
        wording: String
    ) throws -> ProfileStatement {
        try ProfileStatement(
            statementID: ProfileStatementID(id),
            statementKind: kind,
            wording: wording,
            supportingSessionCount: 0,
            evidence: []
        )
    }

    private func evidenceAppend(
        target: ProfileStatement,
        suffix: String
    ) throws -> ProfileEvidenceAppend {
        try ProfileEvidenceAppend(
            target: ProfileProposalTarget(statement: target),
            evidence: [try evidence(suffix: suffix, word: "w000001")]
        )
    }

    private func evidence(
        suffix: String,
        word: String
    ) throws -> EvidenceReference {
        try EvidenceReference(
            sessionID: SessionID("ses-20260909T070000000Z-\(suffix)"),
            transcriptRevisionID: TranscriptRevisionID(
                "trv-20260909T070100000Z-\(suffix)"
            ),
            target: .wordRange(
                startWordID: TranscriptWordID(word),
                endWordID: TranscriptWordID(word)
            ),
            display: EvidenceReferenceDisplay(
                sessionLabel: "Practice Session",
                trustedText: "A grounded observation.",
                startMilliseconds: 100,
                endMilliseconds: 200
            )
        )
    }
}

private extension ProfileRevision {
    var provenance: CoachProfileProvenance {
        CoachProfileProvenance(
            revisionID: revisionID,
            statementGeneration: statementGeneration
        )
    }
}
