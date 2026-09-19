@testable @_spi(CoachContextQualification) @_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
import XCTest

final class CoachContextReconsiderationTests: XCTestCase {
    func testReconsiderPreparationUsesLatestContextAndCanonicalEvidenceValidation()
        async throws
    {
        let fixture = try makeFixture()
        let source = ReconsiderContextSnapshotPort(
            attachments: fixture.attachments
        )
        let feature = DefaultCoachContextFeature(source: source)
        let request = try CoachContextReconsiderRequest(
            library: Self.library,
            aggregate: fixture.aggregate,
            basis: fixture.basis
        )

        let outcome = await feature.prepareReconsider(request)

        guard case let .prepared(prepared) = outcome else {
            return XCTFail("expected exact Reconsider launch context")
        }
        XCTAssertNotNil(prepared.exchange.transcriptReadRequest)
        let requestText = String(
            decoding: prepared.exchange.request,
            as: UTF8.self
        )
        XCTAssertTrue(requestText.contains(#""kind":"reconsiderProfileChange""#))
        XCTAssertTrue(requestText.contains(#""generalNotes":"Latest Memory""#))
        XCTAssertTrue(requestText.contains(#""text":"Earlier coaching""#))
        XCTAssertTrue(
            requestText.contains(fixture.active.statementID.rawValue)
        )
        XCTAssertFalse(
            requestText.contains(fixture.replaced.statementID.rawValue) &&
                !requestText.contains(#""inactiveEditTargets""#)
        )

        let validationContext = try CoachResponseValidationContext(
            prepared: prepared,
            base: fixture.aggregate
        )
        let validated = try CoachResponseValidator().validate(
            CoachProviderCompleteResponse(
                body: Data(
                    """
                    {
                      "appendProfileEvidence":[
                        {
                          "targetStatementId":"\(fixture.active.statementID.rawValue)",
                          "evidence":[
                            {
                              "sessionAttachmentId":"practice-b",
                              "target":{
                                "kind":"audioEvent",
                                "audioEventId":"a000001"
                              }
                            }
                          ]
                        }
                      ]
                    }
                    """.utf8
                )
            ),
            in: validationContext
        )
        XCTAssertTrue(validated.messageBlocks.isEmpty)
        XCTAssertEqual(validated.appendedProfileEvidence.count, 1)
        XCTAssertEqual(
            validated.appendedProfileEvidence[0].evidence,
            fixture.basis.previousChanges[0].evidence
        )
        XCTAssertEqual(
            validated.profileEffectPublicationMode,
            CoachResponseProfileEffectPublicationMode.reviewRequired
        )
        let observedRequests = await source.requests
        XCTAssertEqual(observedRequests, [request])
    }

    func testReconsiderBlocksWhenActiveProfileEvidenceDisallowsExternalProcessing()
        async throws
    {
        let fixture = try makeFixture(activeEvidenceIsCovered: true)
        let source = ReconsiderContextSnapshotPort(
            attachments: fixture.attachments
        )
        let policySource = DeniedReconsiderEvidencePolicySource()
        let feature = DefaultCoachContextFeature(
            source: source,
            evidenceUsePolicySource: policySource
        )
        let request = try CoachContextReconsiderRequest(
            library: Self.library,
            aggregate: fixture.aggregate,
            basis: fixture.basis
        )

        let outcome = await feature.prepareReconsider(request)

        XCTAssertEqual(outcome, .unavailable(.externalProcessingDisallowed))
        let expected = CoachProfileEvidenceObligations(
            profile: fixture.basis.latestProfile
        ).sources
        XCTAssertFalse(expected.isEmpty)
        let requestedSources = await policySource.requestedSources
        XCTAssertEqual(requestedSources, expected)
    }

    func testTriggerProjectsCompletePreviousBasisWithoutInventingProviderIDs()
        throws
    {
        let fixture = try makeFixture()

        let trigger = try CoachContextReconsiderTrigger(
            basis: fixture.basis,
            attachments: fixture.attachments
        )

        let expected: CanonicalJSONValue = .object([
                "kind": .string("reconsiderProfileChange"),
                "previousEdits": .array([
                    .object([
                        "edit": .object([
                            "kind": .string("replace"),
                            "targetStatementId": .string(
                                fixture.replaced.statementID.rawValue
                            ),
                            "wording": .string("Make transitions deliberate."),
                        ]),
                        "evidence": .array([
                            pointer(
                                attachmentID: "practice-b",
                                target: .object([
                                    "audioEventId": .string("a000001"),
                                    "kind": .string("audioEvent"),
                                ])
                            ),
                        ]),
                    ]),
                ]),
                "inactiveEditTargets": .array([
                    .object([
                        "evidence": .array([
                            pointer(
                                attachmentID: "practice-a",
                                target: .object([
                                    "endWordId": .string("w000002"),
                                    "kind": .string("wordRange"),
                                    "startWordId": .string("w000001"),
                                ])
                            ),
                        ]),
                        "statementId": .string(
                            fixture.replaced.statementID.rawValue
                        ),
                        "statementKind": .string("speakingObservation"),
                        "supportingSessionCount": .integer(1),
                        "wording": .string("I rush transitions."),
                    ]),
                    .object([
                        "statementId": .string(
                            fixture.appended.statementID.rawValue
                        ),
                        "statementKind": .string("goal"),
                        "supportingSessionCount": .integer(0),
                        "wording": .string("Use a detailed outline."),
                    ]),
                ]),
                "inactiveTargetsEvidence": .array([
                    .object([
                        "evidence": .array([
                            pointer(
                                attachmentID: "practice-a",
                                target: .object([
                                    "endWordId": .string("w000002"),
                                    "kind": .string("wordRange"),
                                    "startWordId": .string("w000001"),
                                ])
                            ),
                        ]),
                        "targetStatementId": .string(
                            fixture.appended.statementID.rawValue
                        ),
                    ]),
                ]),
            ])
        XCTAssertEqual(trigger.canonicalValue(), expected)
    }

    func testTriggerRejectsEmptyDuplicateAndInexactInactiveTargetCollections()
        throws
    {
        let fixture = try makeFixture()

        XCTAssertThrowsError(
            try CoachContextReconsiderTrigger(
                previousChanges: [],
                inactiveEditTargets: [],
                inactiveTargetsEvidence: [],
                latestProfile: fixture.basis.latestProfile,
                attachments: fixture.attachments
            )
        ) { error in
            XCTAssertEqual(
                error as? CoachContextReconsiderTriggerError,
                CoachContextReconsiderTriggerError.emptyBasis
            )
        }

        XCTAssertThrowsError(
            try CoachContextReconsiderTrigger(
                previousChanges: fixture.basis.previousChanges,
                inactiveEditTargets: [fixture.replaced, fixture.replaced],
                inactiveTargetsEvidence: [],
                latestProfile: fixture.basis.latestProfile,
                attachments: fixture.attachments
            )
        ) { error in
            XCTAssertEqual(
                error as? CoachContextReconsiderTriggerError,
                CoachContextReconsiderTriggerError.duplicateInactiveTargetID
            )
        }

        let inexact = try statement(
            id: fixture.replaced.statementID.rawValue,
            kind: fixture.replaced.statementKind,
            wording: "A different historical statement.",
            evidence: fixture.replaced.evidence
        )
        XCTAssertThrowsError(
            try CoachContextReconsiderTrigger(
                previousChanges: fixture.basis.previousChanges,
                inactiveEditTargets: [inexact],
                inactiveTargetsEvidence: [],
                latestProfile: fixture.basis.latestProfile,
                attachments: fixture.attachments
            )
        ) { error in
            XCTAssertEqual(
                error as? CoachContextReconsiderTriggerError,
                CoachContextReconsiderTriggerError
                    .inactiveTargetResolutionMismatch
            )
        }
    }

    func testPreviousEffectEvidenceMustStillResolveToTheExactChatAttachment()
        throws
    {
        let fixture = try makeFixture()

        XCTAssertThrowsError(
            try CoachContextReconsiderTrigger(
                basis: fixture.basis,
                attachments: .empty
            )
        ) { error in
            XCTAssertEqual(
                error as? CoachContextReconsiderTriggerError,
                CoachContextReconsiderTriggerError.evidenceNotAttached
            )
        }
    }

    func testLatestProfileProjectionKeepsHistoricalSupportButOnlyAttachedEvidence()
        throws
    {
        let fixture = try makeFixture()
        let attached = try evidence(
            session: "ses-20260909T070000000Z-1ABC",
            revision: "trv-20260909T070100000Z-2DEF",
            target: .wordRange(
                startWordID: TranscriptWordID("w000001"),
                endWordID: TranscriptWordID("w000002")
            )
        )
        let unattached = try evidence(
            session: "ses-20260909T072000000Z-3GHJ",
            revision: "trv-20260909T072100000Z-4KMN",
            target: .audioEvent(audioEventID: AudioEventID("a000009"))
        )
        let current = try statement(
            id: "stm-20260909T092000000Z-5PQR",
            kind: .growthDirection,
            wording: "Keep transitions deliberate.",
            evidence: [attached, unattached]
        )
        let latest = try revision(
            id: "prf-20260909T092100000Z-6RST",
            generation: 8,
            statementGeneration: 5,
            statements: [current]
        )

        let projected = CoachContextProfileProjector(
            attachments: fixture.attachments
        ).profile(ProfileSnapshot(revision: latest))

        let expected: CanonicalJSONValue = .object([
                "statements": .array([
                    .object([
                        "evidence": .array([
                            pointer(
                                attachmentID: "practice-a",
                                target: .object([
                                    "endWordId": .string("w000002"),
                                    "kind": .string("wordRange"),
                                    "startWordId": .string("w000001"),
                                ])
                            ),
                        ]),
                        "statementId": .string(current.statementID.rawValue),
                        "statementKind": .string("growthDirection"),
                        "supportingSessionCount": .integer(2),
                        "wording": .string("Keep transitions deliberate."),
                    ]),
                ]),
            ])
        XCTAssertEqual(projected, expected)
    }

    private struct Fixture {
        let attachments: ChatAttachments
        let basis: ProfileReconsiderationBasis
        let aggregate: ChatAggregate
        let replaced: ProfileStatement
        let appended: ProfileStatement
        let active: ProfileStatement
    }

    private func makeFixture(
        activeEvidenceIsCovered: Bool = false
    ) throws -> Fixture {
        let firstEvidence = try evidence(
            session: "ses-20260909T070000000Z-1ABC",
            revision: "trv-20260909T070100000Z-2DEF",
            target: .wordRange(
                startWordID: TranscriptWordID("w000001"),
                endWordID: TranscriptWordID("w000002")
            )
        )
        let secondEvidence = try EvidenceReference(
            sessionID: SessionID("ses-20260909T071000000Z-3GHJ"),
            transcriptRevisionID: TranscriptRevisionID(
                "trv-20260909T071100000Z-4KMN"
            ),
            target: .audioEvent(audioEventID: AudioEventID("a000001")),
            display: EvidenceReferenceDisplay(
                sessionLabel: "Practice B",
                trustedText: "Silent pause",
                startMilliseconds: 200,
                endMilliseconds: 201
            )
        )
        let attachments = try ChatAttachments(validating: [
            ChatSessionAttachment(
                attachmentID: ChatSessionAttachmentID("practice-a"),
                sessionID: firstEvidence.sessionID,
                transcriptRevisionID: firstEvidence.transcriptRevisionID
            ),
            ChatSessionAttachment(
                attachmentID: ChatSessionAttachmentID("practice-b"),
                sessionID: secondEvidence.sessionID,
                transcriptRevisionID: secondEvidence.transcriptRevisionID
            ),
        ])
        let replaced = try statement(
            id: "stm-20260909T090000000Z-5PQR",
            kind: .speakingObservation,
            wording: "I rush transitions.",
            evidence: [firstEvidence]
        )
        let appended = try statement(
            id: "stm-20260909T090100000Z-6RST",
            kind: .goal,
            wording: "Use a detailed outline.",
            evidence: []
        )
        let active = try statement(
            id: "stm-20260909T090150000Z-7ABC",
            kind: .goal,
            wording: "Pause before each conclusion.",
            evidence: activeEvidenceIsCovered ? [firstEvidence] : []
        )
        let base = try revision(
            id: "prf-20260909T090200000Z-7VWX",
            generation: 6,
            statementGeneration: 3,
            statements: [replaced, appended, active]
        )
        let replacement = try ProfileProposedStatement(
            statementID: ProfileStatementID(
                "stm-20260909T090300000Z-8XYZ"
            ),
            statementKind: .speakingObservation,
            wording: "Make transitions deliberate.",
            evidence: [secondEvidence]
        )
        let inactiveAppend = try ProfileEvidenceAppend(
            target: ProfileProposalTarget(statement: appended),
            evidence: [firstEvidence]
        )
        let proposal = try ProfileChangeProposal(
            id: ProfileChangeProposalID("prp-20260909T090400000Z-9ABC"),
            chatID: ChatID("cht-20260909T090400000Z-1DEF"),
            responsePositionID: ChatResponsePositionID(
                "rsp-20260909T090400000Z-2GHJ"
            ),
            baseProfile: base.provenance,
            changes: [
                .replace(
                    target: ProfileProposalTarget(statement: replaced),
                    replacement: replacement
                ),
            ],
            evidenceAppends: [inactiveAppend],
            createdAt: try UTCInstant("2026-09-09T09:04:00.000Z")
        )
        let latest = try revision(
            id: "prf-20260909T090500000Z-3KMN",
            parent: base.revisionID,
            generation: 7,
            statementGeneration: 4,
            statements: [active]
        )
        let effect = ChatProfileEffect.proposal(proposal)
        let empty = try ChatAggregate.newChat(
            chatID: proposal.chatID,
            draftID: ChatDraftID("drf-20260909T090500000Z-4PQR"),
            memoryID: CoachMemoryID("mem-20260909T090500000Z-5RST"),
            instant: UTCInstant("2026-09-09T09:05:00.000Z"),
            profileStatementGeneration: base.statementGeneration,
            attachments: attachments
        )
        let aggregate = try ChatAggregate(
            chat: empty.chat,
            memory: empty.memory,
            profileEffect: effect,
            profileReconsideration: ProfileReconsideration(
                sourceEffect: effect,
                resultResponsePositionID: ChatResponsePositionID(
                    "rsp-20260909T090500000Z-6VWX"
                )
            )
        )
        return Fixture(
            attachments: attachments,
            basis: try ProfileReconsiderationBasis(
                sourceEffect: effect,
                baseProfile: ProfileSnapshot(revision: base),
                latestProfile: ProfileSnapshot(revision: latest)
            ),
            aggregate: aggregate,
            replaced: replaced,
            appended: appended,
            active: active
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
            createdAt: UTCInstant("2026-09-09T09:00:00.000Z"),
            statements: statements
        )
    }

    private func statement(
        id: String,
        kind: ProfileStatementKind,
        wording: String,
        evidence: [EvidenceReference]
    ) throws -> ProfileStatement {
        try ProfileStatement(
            statementID: ProfileStatementID(id),
            statementKind: kind,
            wording: wording,
            supportingSessionCount: UInt32(
                Set(evidence.map(\.sessionID)).count
            ),
            evidence: evidence
        )
    }

    private func evidence(
        session: String,
        revision: String,
        target: EvidenceReferenceTarget
    ) throws -> EvidenceReference {
        try EvidenceReference(
            sessionID: SessionID(session),
            transcriptRevisionID: TranscriptRevisionID(revision),
            target: target,
            display: EvidenceReferenceDisplay(
                sessionLabel: "Practice",
                trustedText: "Grounded text",
                startMilliseconds: 100,
                endMilliseconds: 200
            )
        )
    }

    private func pointer(
        attachmentID: String,
        target: CanonicalJSONValue
    ) -> CanonicalJSONValue {
        .object([
            "sessionAttachmentId": .string(attachmentID),
            "target": target,
        ])
    }

    private static let library = LibraryScope(
        libraryID: try! LibraryID("lib-20260909T080000000Z-1ABC")
    )
}

private actor DeniedReconsiderEvidencePolicySource:
    CoachEvidenceUsePolicySource
{
    private(set) var requestedSources: [CoachEvidencePolicySourceIdentity] = []

    func resolveUsePolicies(
        for sources: [CoachEvidencePolicySourceIdentity],
        in library: LibraryScope
    ) async -> [CoachEvidenceUsePolicyResolution] {
        requestedSources = sources
        return sources.map { source in
            .resolved(source: source, policy: Self.policy)
        }
    }

    private static let policy = try! EngineUsePolicy(
        policyID: "reconsider-policy-denied-v1",
        coveredArtifacts: [.transcriptRevision],
        privateLocalUseAllowed: true,
        privateExportAllowed: true,
        externalProcessingAllowed: false,
        publicDistributionAllowed: false,
        commercialUseAllowed: false,
        licenseReference: "test-license",
        licenseSHA256: String(repeating: "4", count: 64)
    )
}

private actor ReconsiderContextSnapshotPort: CoachContextSnapshotPort {
    private let attachments: ChatAttachments
    private(set) var requests: [CoachContextReconsiderRequest] = []

    init(attachments: ChatAttachments) {
        self.attachments = attachments
    }

    func resolveNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome { .sourceUnavailable }

    func resolveChat(
        _ request: CoachContextChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome { .sourceUnavailable }

    func resolvePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextSnapshotOutcome { .sourceUnavailable }

    func resolveReconsider(
        _ request: CoachContextReconsiderRequest
    ) async -> CoachContextSnapshotOutcome {
        requests.append(request)
        do {
            let first = attachments.values[0]
            let second = attachments.values[1]
            let prepared: [PreparedCoachAttachment] = [
                .inline(requestValue: .object([
                    "displayLabel": .string("Practice A"),
                    "kind": .string("inline"),
                    "sessionAttachmentId": .string(first.attachmentID.rawValue),
                    "transcript": Self.firstTranscript,
                ])),
                .onDemand(
                    requestValue: .object([
                        "displayLabel": .string("Practice B"),
                        "kind": .string("onDemand"),
                        "sessionAttachmentId": .string(
                            second.attachmentID.rawValue
                        ),
                        "sessionTranscriptHandle": .string(
                            "00000000-0000-0000-0000-000000000032"
                        ),
                    ]),
                    sessionTranscriptHandle: try PreparedCoachTranscriptHandle(
                        "00000000-0000-0000-0000-000000000032"
                    ),
                    transcriptDisclosure: .object([
                        "sessionAttachmentId": .string(
                            second.attachmentID.rawValue
                        ),
                        "transcript": Self.secondTranscript,
                    ]),
                    sourceAttachment: second,
                    revisionSHA256: String(repeating: "2", count: 64)
                ),
            ]
            let input = try CoachContextQuoteInput(
                memory: .object([
                    "generalNotes": .string("Latest Memory"),
                    "sessionSummaries": .array([]),
                ]),
                history: [.coach(markdownBlocks: ["Earlier coaching"])],
                reconsidering: request,
                attachments: prepared
            )
            let profileProjection = CoachProfileContextProjection(
                snapshot: request.basis.latestProfile,
                attachments: attachments
            )
            return .resolved(
                try CoachContextResolvedSnapshot(
                    input: input,
                    configuration: Self.configuration,
                    authority: CoachContextSnapshotAuthority(
                        binding: request.snapshotBinding,
                        contextGeneration: 11,
                        configurationGeneration: 7,
                        profile: profileProjection.provenance
                    ),
                    profileProjection: profileProjection
                )
            )
        } catch {
            return .sourceUnavailable
        }
    }

    func isCurrent(_ authority: CoachContextSnapshotAuthority) async -> Bool {
        authority.contextGeneration == 11 &&
            authority.configurationGeneration == 7
    }

    func acquireAuthorityLease(
        _ authority: CoachContextSourceLeaseAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        await acquireTestImmutableAuthorityLease(authority)
    }

    private static let configuration = try! CoachContextConfiguration(
        descriptor: CoachProviderDescriptor(
            displayName: "Synthetic Reconsider fixture",
            contextBudget: CoachContextBudget(
                contextWindowTokens: 100_000,
                responseReservedTokens: 10_000,
                safetyMarginTokens: 100
            ),
            coachMemoryMaxTokens: 1_000
        ),
        policy: CoachProviderEstimationPolicy(
            providerIdentifier: "synthetic-reconsider-v1",
            responseCollectorByteCeiling: 100_000,
            framing: .testZero,
            attachmentProjectionPolicy: try! CoachAttachmentProjectionPolicy(
                maximumInlineTranscriptTokens: 100_000,
                tokenEstimator: .utf8ByteUpperBound()
            )
        )
    )

    private static let firstTranscript = transcript(
        words: ["w000001", "w000002"],
        audioEvents: []
    )
    private static let secondTranscript = transcript(
        words: ["w000010"],
        audioEvents: ["a000001"]
    )

    private static func transcript(
        words: [String],
        audioEvents: [String]
    ) -> CanonicalJSONValue {
        .object([
            "audioEvents": .array(audioEvents.enumerated().map { index, id in
                .object([
                    "audioEventId": .string(id),
                    "category": .string("silentPause"),
                    "timeRange": .object([
                        "endMs": .integer(Int64(index + 201)),
                        "startMs": .integer(Int64(index + 200)),
                    ]),
                ])
            }),
            "lines": .array([
                .object([
                    "text": .string("Synthetic transcript"),
                    "timeRange": .object([
                        "endMs": .integer(100),
                        "startMs": .integer(0),
                    ]),
                    "words": .array(words.enumerated().map { index, id in
                        .object([
                            "text": .string(id),
                            "timeRange": .object([
                                "endMs": .integer(Int64(index + 2)),
                                "startMs": .integer(Int64(index + 1)),
                            ]),
                            "wordId": .string(id),
                        ])
                    }),
                ]),
            ]),
        ])
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
