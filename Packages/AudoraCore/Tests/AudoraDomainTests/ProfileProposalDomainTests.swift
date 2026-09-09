import AudoraDomain
import XCTest

final class ProfileProposalDomainTests: XCTestCase {
    func testProfileStatementCountsDistinctSupportingSessions() throws {
        let first = try evidence(
            session: "ses-20260901T100000000Z-1ABC",
            revision: "trv-20260901T100100000Z-2DEF",
            word: "w000001"
        )
        let secondAnchorInSameSession = try evidence(
            session: "ses-20260901T100000000Z-1ABC",
            revision: "trv-20260901T100100000Z-2DEF",
            word: "w000002"
        )

        let statement = try ProfileStatement(
            statementID: ProfileStatementID("stm-20260901T110000000Z-3GHJ"),
            statementKind: .speakingObservation,
            wording: "I rush transitions between ideas.",
            supportingSessionCount: 1,
            evidence: [first, secondAnchorInSameSession]
        )

        XCTAssertEqual(statement.supportingSessionCount, 1)
        XCTAssertThrowsError(
            try ProfileStatement(
                statementID: statement.statementID,
                statementKind: statement.statementKind,
                wording: statement.wording,
                supportingSessionCount: 2,
                evidence: statement.evidence
            )
        )
    }

    func testProfileIdentitiesRequireTheirTypedPrefixes() throws {
        XCTAssertEqual(
            try ProfileStatementID("stm-20260901T110000000Z-3GHJ").rawValue,
            "stm-20260901T110000000Z-3GHJ"
        )
        XCTAssertEqual(
            try ProfileChangeProposalID("prp-20260901T110100000Z-4KMN").rawValue,
            "prp-20260901T110100000Z-4KMN"
        )
        XCTAssertEqual(
            try ProfileWriteIntentID("pwi-20260901T110200000Z-5PQR").rawValue,
            "pwi-20260901T110200000Z-5PQR"
        )

        XCTAssertThrowsError(
            try ProfileStatementID("prp-20260901T110000000Z-3GHJ")
        )
        XCTAssertThrowsError(
            try ProfileChangeProposalID("stm-20260901T110100000Z-4KMN")
        )
        XCTAssertThrowsError(
            try ProfileWriteIntentID("prf-20260901T110200000Z-5PQR")
        )
    }

    func testProfileRevisionIsAnImmutableSnapshotWithUniqueStatements() throws {
        let first = try statement(
            id: "stm-20260901T110000000Z-3GHJ",
            wording: "Pause before moving to the next idea."
        )
        let second = try statement(
            id: "stm-20260901T110100000Z-4KMN",
            wording: "Explain one idea at a time."
        )
        let revision = try ProfileRevision(
            revisionID: ProfileRevisionID("prf-20260901T120000000Z-5PQR"),
            parentRevisionID: nil,
            generation: 1,
            statementGeneration: 1,
            createdAt: UTCInstant("2026-09-01T12:00:00.000Z"),
            statements: [first, second]
        )

        XCTAssertEqual(revision.statements, [first, second])
        XCTAssertEqual(revision.statement(id: second.statementID), second)
        XCTAssertNil(
            revision.statement(
                id: try ProfileStatementID("stm-20260901T110200000Z-6RST")
            )
        )
        XCTAssertThrowsError(
            try ProfileRevision(
                revisionID: revision.revisionID,
                parentRevisionID: revision.parentRevisionID,
                generation: revision.generation,
                statementGeneration: revision.statementGeneration,
                createdAt: revision.createdAt,
                statements: [first, first]
            )
        )
    }

    func testPureEvidencePublicationUnionsFirstSessionOccurrenceWithoutChangingStatements() throws {
        let existing = try evidence(
            session: "ses-20260901T100000000Z-1ABC",
            revision: "trv-20260901T100100000Z-2DEF",
            word: "w000001"
        )
        let firstNewSessionOccurrence = try evidence(
            session: "ses-20260902T100000000Z-3GHJ",
            revision: "trv-20260902T100100000Z-4KMN",
            word: "w000002"
        )
        let laterNewSessionOccurrence = try evidence(
            session: "ses-20260902T100000000Z-3GHJ",
            revision: "trv-20260902T100100000Z-4KMN",
            word: "w000003"
        )
        let target = try statement(
            id: "stm-20260901T110000000Z-5PQR",
            kind: .speakingObservation,
            wording: "I rush transitions between ideas.",
            evidence: [existing]
        )
        let unaffected = try statement(
            id: "stm-20260901T110100000Z-6RST",
            wording: "Pause before moving to the next idea."
        )
        let base = try ProfileRevision(
            revisionID: ProfileRevisionID("prf-20260903T090000000Z-7VWX"),
            parentRevisionID: nil,
            generation: 7,
            statementGeneration: 4,
            createdAt: UTCInstant("2026-09-03T09:00:00.000Z"),
            statements: [target, unaffected]
        )
        let publication = try ProfileEvidencePublication(
            chatID: ChatID("cht-20260903T100000000Z-8XYZ"),
            responsePositionID: ChatResponsePositionID(
                "rsp-20260903T100000000Z-9ABC"
            ),
            evidenceAppends: [
                ProfileEvidenceAppend(
                    target: ProfileProposalTarget(statement: target),
                    evidence: [
                        existing,
                        firstNewSessionOccurrence,
                        laterNewSessionOccurrence,
                    ]
                ),
            ],
            createdAt: UTCInstant("2026-09-03T10:00:00.000Z")
        )

        let result = try base.applying(
            publication,
            intendedRevisionID: ProfileRevisionID(
                "prf-20260903T100100000Z-1DEF"
            ),
            createdAt: UTCInstant("2026-09-03T10:01:00.000Z")
        )
        guard case let .changed(revision) = result else {
            return XCTFail("Expected an evidence-only revision")
        }

        XCTAssertEqual(revision.generation, 8)
        XCTAssertEqual(revision.statementGeneration, 4)
        XCTAssertEqual(revision.parentRevisionID, base.revisionID)
        XCTAssertEqual(revision.statements.map(\.statementID), [
            target.statementID,
            unaffected.statementID,
        ])
        XCTAssertEqual(
            revision.statement(id: target.statementID)?.evidence,
            [existing, firstNewSessionOccurrence]
        )
        XCTAssertEqual(
            revision.statement(id: target.statementID)?.supportingSessionCount,
            2
        )
        XCTAssertEqual(revision.statement(id: unaffected.statementID), unaffected)
    }

    func testPureEvidencePublicationNormalizesByStatementAndSessionInProviderOrder() throws {
        let firstTarget = try statement(
            id: "stm-20260904T090000000Z-1ABC",
            wording: "Pause before moving to the next idea."
        )
        let secondTarget = try statement(
            id: "stm-20260904T090100000Z-2DEF",
            wording: "Land one idea before starting another."
        )
        let sessionAFirst = try evidence(
            session: "ses-20260904T080000000Z-3GHJ",
            revision: "trv-20260904T080100000Z-4KMN",
            word: "w000001"
        )
        let sessionASecond = try evidence(
            session: "ses-20260904T080000000Z-3GHJ",
            revision: "trv-20260904T080100000Z-4KMN",
            word: "w000002"
        )
        let sessionB = try evidence(
            session: "ses-20260904T081000000Z-5PQR",
            revision: "trv-20260904T081100000Z-6RST",
            word: "w000003"
        )
        let chatID = try ChatID("cht-20260904T100000000Z-7VWX")
        let responsePositionID = try ChatResponsePositionID(
            "rsp-20260904T100000000Z-8XYZ"
        )
        let createdAt = try UTCInstant("2026-09-04T10:00:00.000Z")

        let publication = try ProfileEvidencePublication(
            chatID: chatID,
            responsePositionID: responsePositionID,
            evidenceAppends: [
                ProfileEvidenceAppend(
                    target: ProfileProposalTarget(statement: firstTarget),
                    evidence: [sessionAFirst]
                ),
                ProfileEvidenceAppend(
                    target: ProfileProposalTarget(statement: secondTarget),
                    evidence: [sessionASecond]
                ),
                ProfileEvidenceAppend(
                    target: ProfileProposalTarget(statement: firstTarget),
                    evidence: [sessionASecond, sessionB]
                ),
            ],
            createdAt: createdAt
        )

        XCTAssertEqual(ProfileEvidencePublication.schemaVersion, 1)
        XCTAssertEqual(publication.chatID, chatID)
        XCTAssertEqual(publication.responsePositionID, responsePositionID)
        XCTAssertEqual(publication.createdAt, createdAt)
        XCTAssertEqual(
            publication.evidenceAppends.map(\.targetStatementID),
            [firstTarget.statementID, secondTarget.statementID]
        )
        XCTAssertEqual(
            publication.evidenceAppends.map(\.evidence),
            [[sessionAFirst, sessionB], [sessionASecond]]
        )
    }

    func testPureEvidencePublicationReturnsNoOpForExistingSessionSupport() throws {
        let existing = try evidence(
            session: "ses-20260905T080000000Z-1ABC",
            revision: "trv-20260905T080100000Z-2DEF",
            word: "w000001"
        )
        let duplicateSession = try evidence(
            session: "ses-20260905T080000000Z-1ABC",
            revision: "trv-20260905T080100000Z-2DEF",
            word: "w000002"
        )
        let target = try statement(
            id: "stm-20260905T090000000Z-3GHJ",
            wording: "Pause before moving to the next idea.",
            evidence: [existing]
        )
        let base = try ProfileRevision(
            revisionID: ProfileRevisionID("prf-20260905T090100000Z-4KMN"),
            parentRevisionID: nil,
            generation: 9,
            statementGeneration: 6,
            createdAt: UTCInstant("2026-09-05T09:01:00.000Z"),
            statements: [target]
        )
        let publication = try profileEvidencePublication(
            target: target,
            evidence: [duplicateSession]
        )

        XCTAssertEqual(
            try base.applying(
                publication,
                intendedRevisionID: base.revisionID,
                createdAt: UTCInstant("2026-09-05T10:01:00.000Z")
            ),
            .noOp
        )
    }

    func testPureEvidencePublicationReportsRetiredOrChangedTargetAsStale() throws {
        let active = try statement(
            id: "stm-20260906T090000000Z-1ABC",
            kind: .growthDirection,
            wording: "Pause before moving to the next idea."
        )
        let evidence = try evidence(
            session: "ses-20260906T080000000Z-2DEF",
            revision: "trv-20260906T080100000Z-3GHJ",
            word: "w000001"
        )
        let base = try ProfileRevision(
            revisionID: ProfileRevisionID("prf-20260906T090100000Z-4KMN"),
            parentRevisionID: nil,
            generation: 10,
            statementGeneration: 7,
            createdAt: UTCInstant("2026-09-06T09:01:00.000Z"),
            statements: [active]
        )
        let retired = try statement(
            id: "stm-20260906T090200000Z-5PQR",
            wording: "Land one idea before starting another."
        )
        let changedSnapshot = try ProfileProposalTarget(
            statementID: active.statementID,
            statementKind: active.statementKind,
            wording: "Pause after moving to the next idea."
        )
        let retiredPublication = try profileEvidencePublication(
            target: retired,
            evidence: [evidence]
        )
        let changedPublication = try ProfileEvidencePublication(
            chatID: retiredPublication.chatID,
            responsePositionID: retiredPublication.responsePositionID,
            evidenceAppends: [
                ProfileEvidenceAppend(
                    target: changedSnapshot,
                    evidence: [evidence]
                ),
            ],
            createdAt: retiredPublication.createdAt
        )

        for publication in [retiredPublication, changedPublication] {
            XCTAssertThrowsError(
                try base.applying(
                    publication,
                    intendedRevisionID: ProfileRevisionID(
                        "prf-20260906T100000000Z-6RST"
                    ),
                    createdAt: UTCInstant("2026-09-06T10:00:00.000Z")
                )
            ) { error in
                XCTAssertEqual(
                    error as? ProfileEvidencePublicationApplicationError,
                    .staleTarget
                )
            }
        }
    }

    func testPureEvidencePublicationRequiresOneConsistentTargetedAppend() throws {
        XCTAssertThrowsError(
            try ProfileEvidencePublication(
                chatID: ChatID("cht-20260907T100000000Z-1ABC"),
                responsePositionID: ChatResponsePositionID(
                    "rsp-20260907T100000000Z-2DEF"
                ),
                evidenceAppends: [],
                createdAt: UTCInstant("2026-09-07T10:00:00.000Z")
            )
        ) { error in
            XCTAssertEqual(
                error as? ProfileEvidencePublicationError,
                .emptyEvidenceAppends
            )
        }
    }

    func testProfileProposalBindsItsOwnerAndRejectsConflictingTargets() throws {
        let targetStatement = try statement(
            id: "stm-20260901T110000000Z-3GHJ",
            kind: .speakingObservation,
            wording: "I rush transitions between ideas."
        )
        let target = ProfileProposalTarget(statement: targetStatement)
        let proposal = try ProfileChangeProposal(
            id: ProfileChangeProposalID("prp-20260901T120000000Z-4KMN"),
            chatID: ChatID("cht-20260901T120000000Z-5PQR"),
            responsePositionID: ChatResponsePositionID(
                "rsp-20260901T120000000Z-6RST"
            ),
            baseProfile: CoachProfileProvenance(
                revisionID: ProfileRevisionID("prf-20260901T115900000Z-7VWX"),
                statementGeneration: 4
            ),
            changes: [
                .replace(
                    target: target,
                    replacement: try ProfileProposedStatement(
                        statementID: ProfileStatementID(
                            "stm-20260901T120100000Z-8XYZ"
                        ),
                        statementKind: target.statementKind,
                        wording: "I pause between ideas.",
                        evidence: []
                    )
                ),
            ],
            evidenceAppends: [],
            createdAt: UTCInstant("2026-09-01T12:00:00.000Z")
        )

        XCTAssertEqual(proposal.changes[0].evidence, [])
        XCTAssertEqual(proposal.chatID.rawValue, "cht-20260901T120000000Z-5PQR")
        XCTAssertEqual(proposal.baseProfile.statementGeneration, 4)

        XCTAssertThrowsError(
            try ProfileChangeProposal(
                id: proposal.id,
                chatID: proposal.chatID,
                responsePositionID: proposal.responsePositionID,
                baseProfile: proposal.baseProfile,
                changes: [],
                evidenceAppends: [],
                createdAt: proposal.createdAt
            )
        )
        XCTAssertThrowsError(
            try ProfileChangeProposal(
                id: proposal.id,
                chatID: proposal.chatID,
                responsePositionID: proposal.responsePositionID,
                baseProfile: proposal.baseProfile,
                changes: proposal.changes,
                evidenceAppends: [
                    ProfileEvidenceAppend(
                        target: target,
                        evidence: [
                            try evidence(
                                session: "ses-20260901T100000000Z-1ABC",
                                revision: "trv-20260901T100100000Z-2DEF",
                                word: "w000001"
                            ),
                        ]
                    ),
                ],
                createdAt: proposal.createdAt
            )
        )
    }

    func testApplyingMixedProposalCreatesOneFreshSemanticRevision() throws {
        let sessionAFirst = try evidence(
            session: "ses-20260901T100000000Z-1ABC",
            revision: "trv-20260901T100100000Z-2DEF",
            word: "w000001"
        )
        let sessionASecond = try evidence(
            session: "ses-20260901T100000000Z-1ABC",
            revision: "trv-20260901T100100000Z-2DEF",
            word: "w000002"
        )
        let sessionBFirst = try evidence(
            session: "ses-20260902T100000000Z-3GHJ",
            revision: "trv-20260902T100100000Z-4KMN",
            word: "w000003"
        )
        let sessionBSecond = try evidence(
            session: "ses-20260902T100000000Z-3GHJ",
            revision: "trv-20260902T100100000Z-4KMN",
            word: "w000004"
        )
        let sessionCFirst = try evidence(
            session: "ses-20260903T100000000Z-5PQR",
            revision: "trv-20260903T100100000Z-6RST",
            word: "w000005"
        )
        let sessionCSecond = try evidence(
            session: "ses-20260903T100000000Z-5PQR",
            revision: "trv-20260903T100100000Z-6RST",
            word: "w000006"
        )

        let replaceTarget = try statement(
            id: "stm-20260901T110000000Z-1ABC",
            kind: .speakingObservation,
            wording: "I rush transitions.",
            evidence: [sessionAFirst]
        )
        let retireTarget = try statement(
            id: "stm-20260901T110100000Z-2DEF",
            wording: "Use a detailed outline."
        )
        let appendTarget = try statement(
            id: "stm-20260901T110200000Z-3GHJ",
            kind: .growthDirection,
            wording: "Pause between ideas.",
            evidence: [sessionBFirst, sessionBSecond]
        )
        let unaffected = try statement(
            id: "stm-20260901T110300000Z-4KMN",
            kind: .coachingPreference,
            wording: "Give me direct feedback."
        )
        let freshBase = try ProfileRevision(
            revisionID: ProfileRevisionID("prf-20260904T090000000Z-5PQR"),
            parentRevisionID: ProfileRevisionID(
                "prf-20260903T090000000Z-6RST"
            ),
            generation: 7,
            statementGeneration: 4,
            createdAt: UTCInstant("2026-09-04T09:00:00.000Z"),
            statements: [replaceTarget, retireTarget, appendTarget, unaffected]
        )

        let addedID = try ProfileStatementID("stm-20260904T100000000Z-7VWX")
        let replacementID = try ProfileStatementID(
            "stm-20260904T100100000Z-8XYZ"
        )
        let proposal = try ProfileChangeProposal(
            id: ProfileChangeProposalID("prp-20260904T100200000Z-9ABC"),
            chatID: ChatID("cht-20260904T100200000Z-1DEF"),
            responsePositionID: ChatResponsePositionID(
                "rsp-20260904T100200000Z-2GHJ"
            ),
            baseProfile: CoachProfileProvenance(
                revisionID: ProfileRevisionID(
                    "prf-20260904T080000000Z-3KMN"
                ),
                statementGeneration: 4
            ),
            changes: [
                .add(
                    statement: ProfileProposedStatement(
                        statementID: addedID,
                        statementKind: .goal,
                        wording: "Land one idea before starting another.",
                        evidence: [sessionAFirst, sessionASecond]
                    )
                ),
                .replace(
                    target: ProfileProposalTarget(statement: replaceTarget),
                    replacement: ProfileProposedStatement(
                        statementID: replacementID,
                        statementKind: .speakingObservation,
                        wording: "I pause deliberately between ideas.",
                        evidence: [sessionASecond, sessionCFirst]
                    )
                ),
                .retire(
                    target: ProfileProposalTarget(statement: retireTarget),
                    evidence: []
                ),
            ],
            evidenceAppends: [
                ProfileEvidenceAppend(
                    target: ProfileProposalTarget(statement: appendTarget),
                    evidence: [sessionBSecond, sessionCFirst, sessionCSecond]
                ),
            ],
            createdAt: UTCInstant("2026-09-04T10:02:00.000Z")
        )
        let intendedRevisionID = try ProfileRevisionID(
            "prf-20260904T100300000Z-4PQR"
        )

        let applied = try proposal.applying(
            to: freshBase,
            intendedRevisionID: intendedRevisionID,
            createdAt: UTCInstant("2026-09-04T10:03:00.000Z")
        )

        XCTAssertEqual(applied.revisionID, intendedRevisionID)
        XCTAssertEqual(applied.parentRevisionID, freshBase.revisionID)
        XCTAssertEqual(applied.generation, 8)
        XCTAssertEqual(applied.statementGeneration, 5)
        XCTAssertEqual(
            applied.statements.map(\.statementID),
            [replacementID, appendTarget.statementID, unaffected.statementID, addedID]
        )
        let replacement = try XCTUnwrap(applied.statement(id: replacementID))
        XCTAssertEqual(replacement.statementKind, replaceTarget.statementKind)
        XCTAssertEqual(
            replacement.evidence,
            [sessionAFirst, sessionASecond, sessionCFirst]
        )
        XCTAssertEqual(replacement.supportingSessionCount, 2)
        let appended = try XCTUnwrap(
            applied.statement(id: appendTarget.statementID)
        )
        XCTAssertEqual(
            appended.evidence,
            [sessionBFirst, sessionBSecond, sessionCFirst]
        )
        XCTAssertEqual(appended.supportingSessionCount, 2)
        let added = try XCTUnwrap(applied.statement(id: addedID))
        XCTAssertEqual(added.evidence, [sessionAFirst, sessionASecond])
        XCTAssertEqual(added.supportingSessionCount, 1)
        XCTAssertNil(applied.statement(id: retireTarget.statementID))
    }

    func testApplyingToRecoveredNullProfileUsesExactHeadGeneration() throws {
        let addedID = try ProfileStatementID("stm-20260905T100000000Z-1ABC")
        let proposal = try ProfileChangeProposal(
            id: ProfileChangeProposalID("prp-20260905T100100000Z-2DEF"),
            chatID: ChatID("cht-20260905T100100000Z-3GHJ"),
            responsePositionID: ChatResponsePositionID(
                "rsp-20260905T100100000Z-4KMN"
            ),
            baseProfile: CoachProfileProvenance(
                revisionID: nil,
                statementGeneration: 11
            ),
            changes: [
                .add(
                    statement: ProfileProposedStatement(
                        statementID: addedID,
                        statementKind: .goal,
                        wording: "Pause before each new point.",
                        evidence: []
                    )
                ),
            ],
            createdAt: UTCInstant("2026-09-05T10:01:00.000Z")
        )

        let applied = try proposal.applying(
            to: nil,
            currentHeadGeneration: 20,
            intendedRevisionID: ProfileRevisionID(
                "prf-20260905T100200000Z-5PQR"
            ),
            createdAt: UTCInstant("2026-09-05T10:02:00.000Z")
        )

        XCTAssertNil(applied.parentRevisionID)
        XCTAssertEqual(applied.generation, 21)
        XCTAssertEqual(applied.statementGeneration, 12)
        XCTAssertEqual(applied.statements.map(\.statementID), [addedID])
    }

    func testProfileWriteIntentBindsProposalAndExactHeadAuthority() throws {
        let proposal = try ProfileChangeProposal(
            id: ProfileChangeProposalID("prp-20260906T100000000Z-1ABC"),
            chatID: ChatID("cht-20260906T100000000Z-2DEF"),
            responsePositionID: ChatResponsePositionID(
                "rsp-20260906T100000000Z-3GHJ"
            ),
            baseProfile: CoachProfileProvenance(
                revisionID: ProfileRevisionID(
                    "prf-20260906T090000000Z-4KMN"
                ),
                statementGeneration: 4
            ),
            changes: [
                .add(
                    statement: ProfileProposedStatement(
                        statementID: ProfileStatementID(
                            "stm-20260906T100100000Z-5PQR"
                        ),
                        statementKind: .goal,
                        wording: "Pause before each new point.",
                        evidence: []
                    )
                ),
            ],
            createdAt: UTCInstant("2026-09-06T10:00:00.000Z")
        )
        let selected = try ProfileRevisionPointer(
            revisionID: ProfileRevisionID("prf-20260906T093000000Z-6RST"),
            sha256: String(repeating: "a", count: 64)
        )
        let head = ProfileHead(
            generation: 8,
            statementGeneration: 4,
            selection: .revision(selected),
            updatedAt: try UTCInstant("2026-09-06T09:30:00.000Z")
        )
        let intendedRevisionID = try ProfileRevisionID(
            "prf-20260906T100200000Z-7VWX"
        )
        let intent = try ProfileWriteIntent(
            id: ProfileWriteIntentID("pwi-20260906T100200000Z-8XYZ"),
            proposal: proposal,
            expectedHead: head,
            intendedRevisionID: intendedRevisionID,
            createdAt: UTCInstant("2026-09-06T10:02:00.000Z")
        )

        XCTAssertEqual(intent.proposalID, proposal.id)
        XCTAssertEqual(intent.chatID, proposal.chatID)
        XCTAssertEqual(intent.expectedHead, ProfileHeadAuthority(head: head))
        XCTAssertEqual(intent.intendedRevisionID, intendedRevisionID)
        XCTAssertThrowsError(
            try ProfileWriteIntent(
                id: intent.id,
                proposal: proposal,
                expectedHead: ProfileHead(
                    generation: 9,
                    statementGeneration: 5,
                    selection: .revision(selected),
                    updatedAt: head.updatedAt
                ),
                intendedRevisionID: intendedRevisionID,
                createdAt: intent.createdAt
            )
        )
    }

    private func evidence(
        session: String,
        revision: String,
        word: String
    ) throws -> EvidenceReference {
        try EvidenceReference(
            sessionID: SessionID(session),
            transcriptRevisionID: TranscriptRevisionID(revision),
            target: .wordRange(
                startWordID: TranscriptWordID(word),
                endWordID: TranscriptWordID(word)
            ),
            display: EvidenceReferenceDisplay(
                sessionLabel: "Practice Session",
                trustedText: "A locally resolved phrase",
                startMilliseconds: 1_000,
                endMilliseconds: 2_000
            )
        )
    }


    private func statement(
        id: String,
        kind: ProfileStatementKind = .goal,
        wording: String,
        evidence: [EvidenceReference] = []
    ) throws -> ProfileStatement {
        try ProfileStatement(
            statementID: ProfileStatementID(id),
            statementKind: kind,
            wording: wording,
            supportingSessionCount: UInt32(Set(evidence.map(\.sessionID)).count),
            evidence: evidence
        )
    }

    private func profileEvidencePublication(
        target: ProfileStatement,
        evidence: [EvidenceReference]
    ) throws -> ProfileEvidencePublication {
        try ProfileEvidencePublication(
            chatID: ChatID("cht-20260905T100000000Z-7VWX"),
            responsePositionID: ChatResponsePositionID(
                "rsp-20260905T100000000Z-8XYZ"
            ),
            evidenceAppends: [
                ProfileEvidenceAppend(
                    target: ProfileProposalTarget(statement: target),
                    evidence: evidence
                ),
            ],
            createdAt: UTCInstant("2026-09-05T10:00:00.000Z")
        )
    }
}
