@testable @_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
@testable @_spi(InvocationInfrastructure) import AudoraMacInfrastructure
import CryptoKit
import Foundation
import XCTest

final class PortableProfileProposalCoordinatorTests: XCTestCase {
    func testAssessmentKeepsProposalCurrentAcrossEvidenceOnlyRevision()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedTargetProposalFixture(in: parent)
            let evidenceOnly = try makeConcurrentEvidenceRevision(
                in: fixture.source
            )
            try installProfileRevision(evidenceOnly, in: fixture.source)
            let request = try AssessProfileEffectRequest(
                library: fixture.source.scope,
                base: fixture.published,
                sourceEffectIdentity: .proposal(fixture.proposal.id)
            )
            let coordinator = PortableProfileProposalCoordinator(
                persistence: fixture.source.persistence,
                workspace: fixture.source.workspace
            )

            guard case let .current(current) = await coordinator.assess(request)
            else {
                return XCTFail("Evidence-only revision made Proposal stale")
            }
            XCTAssertEqual(current, fixture.published)
        }
    }

    func testAssessmentBuildsExactBasisForStaleProposal() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedTargetProposalFixture(in: parent)
            let latestTarget = try ProfileStatement(
                statementID: fixture.source.target.statementID,
                statementKind: fixture.source.target.statementKind,
                wording: "Pause after every complete thought.",
                supportingSessionCount: fixture.source.target
                    .supportingSessionCount,
                evidence: fixture.source.target.evidence
            )
            let latest = try ProfileRevision(
                revisionID: ProfileRevisionID(
                    "prf-20260910T130000000Z-8ABC"
                ),
                parentRevisionID: fixture.source.baseRevision.revisionID,
                generation: 2,
                statementGeneration: 2,
                createdAt: UTCInstant("2026-09-10T13:00:00.000Z"),
                statements: [latestTarget]
            )
            try installProfileRevision(latest, in: fixture.source)
            let request = try AssessProfileEffectRequest(
                library: fixture.source.scope,
                base: fixture.published,
                sourceEffectIdentity: .proposal(fixture.proposal.id)
            )
            let coordinator = PortableProfileProposalCoordinator(
                persistence: fixture.source.persistence,
                workspace: fixture.source.workspace
            )

            guard case let .stale(current, basis) = await coordinator.assess(
                request
            ) else { return XCTFail("Semantic revision did not stale Proposal") }
            XCTAssertEqual(current, fixture.published)
            XCTAssertEqual(basis.sourceEffect, .proposal(fixture.proposal))
            XCTAssertEqual(
                basis.baseProfile,
                ProfileSnapshot(revision: fixture.source.baseRevision)
            )
            XCTAssertEqual(basis.latestProfile, ProfileSnapshot(revision: latest))
            XCTAssertEqual(basis.previousChanges, fixture.proposal.changes)
            XCTAssertEqual(
                basis.inactiveEditTargets,
                [fixture.source.target]
            )
            XCTAssertEqual(basis.inactiveTargetsEvidence, [])
            XCTAssertEqual(basis.retainedActiveEvidenceAppends, [])
        }
    }

    func testPortableReconsiderPublishesMessageFreeReviewedReplacementAndReloads()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePortableReconsiderationFixture(
                in: parent
            )
            let store = PortableInvocationStore(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )
            guard case let .opened(pending) = await store
                .openNewProfileReconsiderationInvocation(fixture.request)
            else { return XCTFail("Reconsider reservation did not open") }
            let install = try makeReconsiderationInstall(
                authority: pending.authority,
                basis: fixture.basis
            )
            guard case let .installed(active) = await pending.install(install)
            else { return XCTFail("Reconsider Invocation did not install") }
            XCTAssertEqual(
                active.processingAggregate.profileReconsideration?
                    .preparedProfileStatementGeneration,
                fixture.basis.latestProfile.provenance.statementGeneration
            )
            let response = ValidatedCoachResponse(
                messageBlocks: [],
                newMemory: nil,
                proposedProfileEdits: [
                    ValidatedCoachProfileEditProposal(
                        edit: .add(
                            statementKind: .goal,
                            wording: "Use one deliberate pause between ideas."
                        ),
                        evidence: []
                    ),
                ],
                appendedProfileEvidence: [],
                profileEffectPublicationMode: .reviewRequired
            )
            let mutation = try PublishProfileReconsiderationInvocationMutation(
                base: active.processingAggregate,
                invocation: active.invocation,
                reconsideration: active.reconsideration,
                basis: active.basis,
                validatedResponse: response,
                replacementMemory: nil,
                completedAt: UTCInstant("2026-09-10T14:00:03.000Z")
            )

            guard case let .committed(published) = await active.publish(mutation)
            else { return XCTFail("Message-free replacement did not commit") }
            XCTAssertEqual(
                published.chat.messageIDs,
                fixture.observed.chat.messageIDs
            )
            XCTAssertNotNil(published.profileProposal)
            XCTAssertNil(published.profileReconsideration)
            guard case let .readWrite(reloaded) = try fixture.persistence.load(
                published.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("Message-free Proposal did not reload") }
            XCTAssertEqual(reloaded, published)
            let assessment = await PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            ).assess(
                try AssessProfileEffectRequest(
                    library: fixture.scope,
                    base: reloaded,
                    sourceEffectIdentity: try XCTUnwrap(
                        reloaded.profileEffect?.identity
                    )
                )
            )
            guard case let .current(assessed) = assessment else {
                return XCTFail(
                    "Message-free Proposal could not be assessed after reload"
                )
            }
            XCTAssertEqual(assessed, reloaded)
        }
    }

    func testRelaunchFinishesCommittedMessageFreeReconsiderWithdrawal()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePortableReconsiderationFixture(
                in: parent
            )
            let manifestFault = OneShot()
            let persistence = PortableChatPersistence { point in
                if point == .afterPublicationManifestInstall,
                   manifestFault.take()
                {
                    throw PortableChatPersistenceError.injectedFault(point)
                }
            }
            guard case let .prepared(authority, lease) = try persistence
                .prepareNewProfileReconsiderationInvocation(
                    fixture.request,
                    at: fixture.root,
                    in: fixture.scope
                )
            else { return XCTFail("Reconsider reservation did not open") }
            let install = try makeReconsiderationInstall(
                authority: authority,
                basis: fixture.basis
            )
            guard case .installed = try persistence
                .installProfileReconsiderationInvocation(
                    install,
                    at: fixture.root,
                    holding: lease
                )
            else { return XCTFail("Reconsider Invocation did not install") }
            let mutation = try PublishProfileReconsiderationInvocationMutation(
                base: install.processingAggregate,
                invocation: install.invocation,
                reconsideration: install.processingReconsideration,
                basis: authority.basis,
                validatedResponse: ValidatedCoachResponse(
                    messageBlocks: [],
                    newMemory: nil,
                    proposedProfileEdits: [],
                    appendedProfileEvidence: [],
                    profileEffectPublicationMode: .reviewRequired
                ),
                replacementMemory: nil,
                completedAt: UTCInstant("2026-09-10T14:00:03.000Z")
            )
            XCTAssertThrowsError(
                try persistence.publishProfileReconsideration(
                    mutation,
                    at: fixture.root,
                    in: fixture.scope,
                    holding: lease
                )
            )
            lease.release() // Simulates kernel liveness loss at process death.
            XCTAssertTrue(manifestFault.wasTaken)

            let relaunched = try await relaunchedWorkspace(
                root: fixture.root
            )
            do {
                try persistence.reconcileInterruptedInvocations(
                    at: fixture.root,
                    in: fixture.scope
                )
            } catch {
                return XCTFail("Reconsider relaunch recovery failed: \(error)")
            }
            let chatStore = PortableChatStore(workspace: relaunched)
            guard case let .loaded(recovered) = await chatStore.load(
                fixture.observed.chat.id,
                in: fixture.scope
            ) else { return XCTFail("Relaunch did not finish withdrawal") }
            XCTAssertNil(recovered.profileEffect)
            XCTAssertNil(recovered.profileReconsideration)
            XCTAssertEqual(
                recovered.chat.messageIDs,
                fixture.observed.chat.messageIDs
            )
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(
                    "invocations/inv-20260910T140002000Z-1ABC"
                ).path
            ))
        }
    }

    func testRelaunchFinishesProposalSourceReplacementAfterCanonicalInstall()
        async throws
    {
        try await withTemporaryParent { parent in
            try assertRelaunchFinishesReplacementAfterCanonicalInstall(
                try await makePortableReconsiderationFixture(in: parent)
            )
        }
    }

    func testRelaunchFinishesEvidenceSourceReplacementAfterCanonicalInstall()
        async throws
    {
        try await withTemporaryParent { parent in
            try assertRelaunchFinishesReplacementAfterCanonicalInstall(
                try await makePortableEvidenceReconsiderationFixture(in: parent)
            )
        }
    }

    func testCommittedReconsiderProofSurvivesLaterRenameAndFreshDraft()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePortableReconsiderationFixture(
                in: parent
            )
            let retirementFault = OneShot()
            let persistence = PortableChatPersistence { point in
                if point == .beforeReconsiderationPublishedInvocationRetirement,
                   retirementFault.take()
                {
                    throw PortableChatPersistenceError.injectedFault(point)
                }
            }
            guard case let .prepared(authority, lease) = try persistence
                .prepareNewProfileReconsiderationInvocation(
                    fixture.request,
                    at: fixture.root,
                    in: fixture.scope
                )
            else { return XCTFail("Reconsider reservation did not open") }
            let install = try makeReconsiderationInstall(
                authority: authority,
                basis: fixture.basis
            )
            guard case .installed = try persistence
                .installProfileReconsiderationInvocation(
                    install,
                    at: fixture.root,
                    holding: lease
                )
            else { return XCTFail("Reconsider Invocation did not install") }
            let mutation = try PublishProfileReconsiderationInvocationMutation(
                base: install.processingAggregate,
                invocation: install.invocation,
                reconsideration: install.processingReconsideration,
                basis: authority.basis,
                validatedResponse: replacementReconsiderationResponse(),
                replacementMemory: nil,
                completedAt: UTCInstant("2026-09-10T14:00:03.000Z")
            )
            XCTAssertThrowsError(
                try persistence.publishProfileReconsideration(
                    mutation,
                    at: fixture.root,
                    in: fixture.scope,
                    holding: lease
                )
            )
            XCTAssertTrue(retirementFault.wasTaken)

            guard case let .renamed(renamed) = try persistence.rename(
                RenameChatMutation(
                    library: fixture.scope,
                    base: mutation.replacement,
                    title: ChatTitle("Later reconsidered title"),
                    updatedAt: UTCInstant("2026-09-10T14:00:04.000Z")
                ),
                at: fixture.root
            ) else { return XCTFail("Later title did not commit") }
            let freshDraft = try renamed.chat.draft.edited(
                text: "A fresh Draft after committed reconsideration.",
                at: UTCInstant("2026-09-10T14:00:05.000Z")
            )
            guard case let .committed(evolved) = try persistence.saveDraft(
                SaveChatDraftMutation(
                    library: fixture.scope,
                    chatID: renamed.chat.id,
                    replacement: freshDraft
                ),
                at: fixture.root
            ) else { return XCTFail("Later Draft did not commit") }

            let recovered = try XCTUnwrap(
                persistence.reconcileCommittedProfileReconsiderationPublication(
                    mutation,
                    at: fixture.root,
                    in: fixture.scope,
                    holding: lease
                )
            )
            XCTAssertEqual(recovered, evolved)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(
                    "invocations/\(install.invocation.id.rawValue)"
                ).path
            ))
            lease.release()
        }
    }

    func testRelaunchRepairsUninstalledFailureFreeReconsiderSidecar()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePortableReconsiderationFixture(
                in: parent
            )
            let chatRoot = fixture.root.appendingPathComponent(
                "chats/\(fixture.observed.chat.id.rawValue)",
                isDirectory: true
            )
            var legacySidecar = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: fixture.persistence.encodeProfileReconsideration(
                        fixture.reconsideration
                    )
                ) as? [String: Any]
            )
            legacySidecar["schemaVersion"] = 1
            try JSONSerialization.data(
                withJSONObject: legacySidecar,
                options: [.sortedKeys]
            ).write(
                to: chatRoot.appendingPathComponent(
                    "profile-reconsideration.json"
                )
            )
            let relaunched = try await relaunchedWorkspace(root: fixture.root)
            let store = PortableChatStore(workspace: relaunched)

            guard case let .loaded(recovered) = await store.load(
                fixture.observed.chat.id,
                in: fixture.scope
            ) else { return XCTFail("Orphan Reconsider sidecar was not repaired") }
            XCTAssertEqual(recovered.profileEffect, fixture.observed.profileEffect)
            XCTAssertEqual(
                recovered.profileReconsideration,
                fixture.reconsideration.replacingFailure(
                    .coachResponseInterrupted
                )
            )
        }
    }

    func testRelaunchRetainsInstalledReconsiderPreparedProfileGeneration()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePortableReconsiderationFixture(
                in: parent
            )
            guard case let .prepared(authority, lease) = try fixture.persistence
                .prepareNewProfileReconsiderationInvocation(
                    fixture.request,
                    at: fixture.root,
                    in: fixture.scope
                )
            else { return XCTFail("Reconsider reservation did not open") }
            let install = try makeReconsiderationInstall(
                authority: authority,
                basis: fixture.basis
            )
            guard case .installed = try fixture.persistence
                .installProfileReconsiderationInvocation(
                    install,
                    at: fixture.root,
                    holding: lease
                )
            else { return XCTFail("Reconsider Invocation did not install") }
            lease.release()

            try fixture.persistence.reconcileInterruptedInvocations(
                at: fixture.root,
                in: fixture.scope
            )

            guard case let .readWrite(reopened) = try fixture.persistence.load(
                fixture.observed.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("Interrupted Reconsider did not reload") }
            XCTAssertEqual(
                reopened.profileReconsideration?.failure,
                .coachResponseInterrupted
            )
            XCTAssertEqual(
                reopened.profileReconsideration?
                    .preparedProfileStatementGeneration,
                fixture.basis.latestProfile.provenance.statementGeneration
            )
        }
    }

    func testAssessmentKeepsEvidencePublicationCurrentWhileExactTargetIsActive()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedEvidenceFixture(in: parent)
            let evidenceOnly = try makeConcurrentEvidenceRevision(in: fixture)
            try installProfileRevision(evidenceOnly, in: fixture)
            let request = try AssessProfileEffectRequest(
                library: fixture.scope,
                base: fixture.published,
                sourceEffectIdentity: .evidencePublication(
                    fixture.profilePublication.responsePositionID
                )
            )
            let coordinator = PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )

            guard case let .current(current) = await coordinator.assess(request)
            else { return XCTFail("Active exact evidence target was stale") }
            XCTAssertEqual(current, fixture.published)
        }
    }

    func testAssessmentBuildsExactBasisWhenEvidenceTargetIsNoLongerActive()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedEvidenceFixture(in: parent)
            let latest = try ProfileRevision(
                revisionID: ProfileRevisionID(
                    "prf-20260910T130100000Z-9DEF"
                ),
                parentRevisionID: fixture.baseRevision.revisionID,
                generation: 2,
                statementGeneration: 2,
                createdAt: UTCInstant("2026-09-10T13:01:00.000Z"),
                statements: []
            )
            try installProfileRevision(latest, in: fixture)
            let request = try AssessProfileEffectRequest(
                library: fixture.scope,
                base: fixture.published,
                sourceEffectIdentity: .evidencePublication(
                    fixture.profilePublication.responsePositionID
                )
            )
            let coordinator = PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )

            guard case let .stale(current, basis) = await coordinator.assess(
                request
            ) else {
                return XCTFail("Inactive evidence target was not stale")
            }
            XCTAssertEqual(current, fixture.published)
            XCTAssertEqual(
                basis.sourceEffect,
                .evidencePublication(fixture.profilePublication)
            )
            XCTAssertEqual(
                basis.baseProfile,
                ProfileSnapshot(revision: fixture.baseRevision)
            )
            XCTAssertEqual(basis.latestProfile, ProfileSnapshot(revision: latest))
            XCTAssertEqual(basis.previousChanges, [])
            XCTAssertEqual(basis.inactiveEditTargets, [fixture.target])
            XCTAssertEqual(
                basis.inactiveTargetsEvidence,
                fixture.profilePublication.evidenceAppends
            )
            XCTAssertEqual(basis.retainedActiveEvidenceAppends, [])
        }
    }

    func testAssessmentReconcilesAcceptedWriteBeforeClassifying() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let request = try AssessProfileEffectRequest(
                library: fixture.scope,
                base: fixture.published,
                sourceEffectIdentity: .proposal(fixture.proposal.id)
            )
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:05:00.000Z")
            )
            let injected = OneShot()
            let interrupted = PortableChatPersistence { point in
                guard point == .afterProfileWriteIntentDirectoryFlush,
                      injected.take()
                else { return }
                throw PortableChatPersistenceError.injectedFault(point)
            }
            let interruptedCoordinator = PortableProfileProposalCoordinator(
                persistence: interrupted,
                workspace: fixture.workspace
            )
            let interruptedOutcome = await interruptedCoordinator.accept(mutation)
            XCTAssertEqual(interruptedOutcome, .failed)

            let coordinator = PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )
            let assessment = await coordinator.assess(request)
            XCTAssertEqual(assessment, .failed)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: chatRoot(fixture).appendingPathComponent(
                        "proposal.json"
                    ).path
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: chatRoot(fixture).appendingPathComponent(
                        "profile-write.json"
                    ).path
                )
            )
            XCTAssertEqual(try loadProfileHead(in: fixture).generation, 1)
        }
    }

    func testAssessmentFailsClosedForUnprovedOrMismatchedAuthority()
        async throws
    {
        try await withTemporaryParent { parent in
            let unproved = try await makePublishedEvidenceFixture(in: parent)
            try Data(repeating: 48, count: 64).write(
                to: unproved.root.appendingPathComponent(
                    "profile/revisions/\(unproved.baseRevision.revisionID.rawValue)/revision.sha256"
                ),
                options: .atomic
            )
            let unprovedRequest = try AssessProfileEffectRequest(
                library: unproved.scope,
                base: unproved.published,
                sourceEffectIdentity: .evidencePublication(
                    unproved.profilePublication.responsePositionID
                )
            )
            let unprovedCoordinator = PortableProfileProposalCoordinator(
                persistence: unproved.persistence,
                workspace: unproved.workspace
            )
            let unprovedAssessment = await unprovedCoordinator.assess(
                unprovedRequest
            )
            XCTAssertEqual(unprovedAssessment, .failed)

            let mismatched = try await makePublishedProposalFixture(
                in: parent,
                ordinal: 1
            )
            let mismatchedRequest = try AssessProfileEffectRequest(
                library: mismatched.scope,
                base: mismatched.published,
                sourceEffectIdentity: .proposal(mismatched.proposal.id)
            )
            let replacement = try ProfileChangeProposal(
                id: ProfileChangeProposalID(
                    "prp-20260909T130100000Z-7VWX"
                ),
                chatID: mismatched.published.chat.id,
                responsePositionID: mismatched.proposal.responsePositionID,
                baseProfile: mismatched.proposal.baseProfile,
                changes: mismatched.proposal.changes,
                createdAt: mismatched.proposal.createdAt
            )
            try mismatched.persistence.encodeProfileProposal(replacement).write(
                to: chatRoot(mismatched).appendingPathComponent("proposal.json"),
                options: .atomic
            )
            let mismatchedCoordinator = PortableProfileProposalCoordinator(
                persistence: mismatched.persistence,
                workspace: mismatched.workspace
            )
            let mismatchedAssessment = await mismatchedCoordinator.assess(
                mismatchedRequest
            )
            XCTAssertEqual(mismatchedAssessment, .failed)
        }
    }

    func testEvidencePublicationStagesWithTurnThenSilentlyRebasesProfile()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedEvidenceFixture(in: parent)
            let publicationURL = chatRoot(fixture).appendingPathComponent(
                "profile-publication.json"
            )

            XCTAssertEqual(
                try Data(contentsOf: publicationURL),
                try fixture.persistence.encodeProfileEvidencePublication(
                    fixture.profilePublication
                )
            )
            guard case let .readWrite(reopened) = try fixture.persistence.load(
                fixture.published.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else {
                return XCTFail("Published evidence operation did not reopen")
            }
            XCTAssertEqual(reopened, fixture.published)

            let concurrent = try makeConcurrentEvidenceRevision(in: fixture)
            try installProfileRevision(concurrent, in: fixture)
            let coordinator = PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )
            let mutation = try PublishProfileEvidenceMutation(
                library: fixture.scope,
                base: fixture.published,
                responsePositionID: fixture.profilePublication.responsePositionID
            )

            guard case let .committed(resolved) = await coordinator.publishEvidence(
                mutation
            ) else {
                return XCTFail("Evidence-only Profile publication did not commit")
            }

            XCTAssertNil(resolved.profileEvidencePublication)
            XCTAssertEqual(resolved.chat, fixture.published.chat)
            XCTAssertEqual(resolved.messages, fixture.published.messages)
            XCTAssertEqual(resolved.memory, fixture.published.memory)
            XCTAssertFalse(FileManager.default.fileExists(atPath: publicationURL.path))
            let head = try loadProfileHead(in: fixture)
            XCTAssertEqual(head.generation, 3)
            XCTAssertEqual(head.statementGeneration, 1)
            guard case let .revision(pointer) = head.selection else {
                return XCTFail("Evidence-only publication did not select a revision")
            }
            XCTAssertEqual(pointer.revisionID, mutation.intendedRevisionID)
            let revision = try fixture.persistence.decodeProfileRevision(
                Data(contentsOf: profileRevisionURL(pointer.revisionID, in: fixture))
            )
            XCTAssertEqual(revision.parentRevisionID, concurrent.revisionID)
            XCTAssertEqual(revision.statementGeneration, concurrent.statementGeneration)
            XCTAssertEqual(
                revision.statement(id: fixture.target.statementID)?.evidence,
                concurrent.statement(id: fixture.target.statementID)!.evidence +
                    [fixture.appendedEvidence]
            )
        }
    }

    func testEvidencePublicationNoOpClearsOnlyOperationWithoutNewRevision()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedEvidenceFixture(
                in: parent,
                existingEvidence: true
            )
            let beforeHead = try Data(
                contentsOf: fixture.root.appendingPathComponent("profile/head.json")
            )
            let beforeRevisionNames = try profileRevisionDirectoryNames(in: fixture)
            let coordinator = PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )
            let mutation = try PublishProfileEvidenceMutation(
                library: fixture.scope,
                base: fixture.published,
                responsePositionID: fixture.profilePublication.responsePositionID
            )

            guard case let .committed(resolved) = await coordinator.publishEvidence(
                mutation
            ) else { return XCTFail("Existing evidence did not resolve as a no-op") }

            XCTAssertNil(resolved.profileEvidencePublication)
            XCTAssertEqual(
                try Data(
                    contentsOf: fixture.root.appendingPathComponent(
                        "profile/head.json"
                    )
                ),
                beforeHead
            )
            XCTAssertEqual(
                try profileRevisionDirectoryNames(in: fixture),
                beforeRevisionNames
            )
        }
    }

    func testEvidencePublicationFailureRetainsExactOperationForLocalRetry()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedEvidenceFixture(in: parent)
            let injected = OneShot()
            let faulting = PortableChatPersistence { point in
                guard point == .afterProfileRevisionInstall, injected.take() else {
                    return
                }
                throw PortableChatPersistenceError.injectedFault(point)
            }
            let mutation = try PublishProfileEvidenceMutation(
                library: fixture.scope,
                base: fixture.published,
                responsePositionID: fixture.profilePublication.responsePositionID
            )
            let first = PortableProfileProposalCoordinator(
                persistence: faulting,
                workspace: fixture.workspace
            )

            let firstOutcome = await first.publishEvidence(mutation)
            XCTAssertEqual(firstOutcome, .failed)
            XCTAssertTrue(injected.wasTaken)
            XCTAssertEqual(try loadProfileHead(in: fixture).generation, 1)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: chatRoot(fixture).appendingPathComponent(
                        "profile-publication.json"
                    ).path
                )
            )

            let retry = PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )
            guard case let .committed(resolved) = await retry.publishEvidence(
                mutation
            ) else { return XCTFail("Local retry did not finish the exact operation") }
            XCTAssertNil(resolved.profileEvidencePublication)
            XCTAssertEqual(try loadProfileHead(in: fixture).generation, 2)
        }
    }

    func testEvidenceDiscardAfterRevisionInstallFailureRemovesProvedOrphan()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedEvidenceFixture(in: parent)
            let injected = OneShot()
            let faulting = PortableChatPersistence { point in
                guard point == .afterProfileRevisionInstall, injected.take() else {
                    return
                }
                throw PortableChatPersistenceError.injectedFault(point)
            }
            let publish = try PublishProfileEvidenceMutation(
                library: fixture.scope,
                base: fixture.published,
                responsePositionID:
                    fixture.profilePublication.responsePositionID
            )
            let coordinator = PortableProfileProposalCoordinator(
                persistence: faulting,
                workspace: fixture.workspace
            )

            let publishOutcome = await coordinator.publishEvidence(publish)
            XCTAssertEqual(publishOutcome, .failed)
            XCTAssertEqual(try loadProfileHead(in: fixture).generation, 1)
            XCTAssertTrue(
                try profileRevisionDirectoryNames(in: fixture).contains(
                    publish.intendedRevisionID.rawValue
                )
            )

            let discard = try DiscardProfileEvidencePublicationMutation(
                library: fixture.scope,
                base: fixture.published,
                responsePositionID:
                    fixture.profilePublication.responsePositionID
            )
            guard case let .committed(resolved) = await coordinator
                .discardEvidence(discard)
            else {
                return XCTFail("Discard did not remove the interrupted operation")
            }
            XCTAssertNil(resolved.profileEvidencePublication)
            XCTAssertEqual(resolved.chat, fixture.published.chat)
            XCTAssertEqual(resolved.messages, fixture.published.messages)
            XCTAssertEqual(resolved.memory, fixture.published.memory)
            XCTAssertEqual(try loadProfileHead(in: fixture).generation, 1)
            XCTAssertEqual(
                try profileRevisionDirectoryNames(in: fixture),
                [fixture.baseRevision.revisionID.rawValue]
            )
        }
    }

    func testEvidencePublicationRetryReplacesProvedOrphanAfterLostHeadCAS()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedEvidenceFixture(in: parent)
            let concurrent = try makeConcurrentEvidenceRevision(in: fixture)
            let concurrentHead = try installProfileRevision(
                concurrent,
                in: fixture
            )
            let baseData = try fixture.persistence.encodeProfileRevision(
                fixture.baseRevision
            )
            let baseHead = ProfileHead(
                generation: fixture.baseRevision.generation,
                statementGeneration: fixture.baseRevision.statementGeneration,
                selection: .revision(
                    try ProfileRevisionPointer(
                        revisionID: fixture.baseRevision.revisionID,
                        sha256: sha256(baseData)
                    )
                ),
                updatedAt: fixture.baseRevision.createdAt
            )
            let library = PortableLibraryPersistence()
            try library.atomicallyReplaceRootForTesting(
                library.encodeProfileHead(baseHead),
                relativePath: try LibraryRelativePath("profile/head.json"),
                under: fixture.root
            )
            let moved = OneShot()
            let racing = PortableChatPersistence { point in
                guard point == .beforeProfileHeadInstall, moved.take() else {
                    return
                }
                try library.atomicallyReplaceRootForTesting(
                    library.encodeProfileHead(concurrentHead),
                    relativePath: try LibraryRelativePath("profile/head.json"),
                    under: fixture.root
                )
            }
            let mutation = try PublishProfileEvidenceMutation(
                library: fixture.scope,
                base: fixture.published,
                responsePositionID:
                    fixture.profilePublication.responsePositionID
            )
            let first = PortableProfileProposalCoordinator(
                persistence: racing,
                workspace: fixture.workspace
            )

            let firstOutcome = await first.publishEvidence(mutation)
            XCTAssertEqual(firstOutcome, .stale(fixture.published))
            XCTAssertTrue(moved.wasTaken)
            XCTAssertEqual(try loadProfileHead(in: fixture), concurrentHead)
            XCTAssertTrue(
                try profileRevisionDirectoryNames(in: fixture).contains(
                    mutation.intendedRevisionID.rawValue
                )
            )

            let retry = PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )
            guard case let .committed(resolved) = await retry.publishEvidence(
                mutation
            ) else {
                return XCTFail("Retry did not safely replace the proved orphan")
            }
            XCTAssertNil(resolved.profileEvidencePublication)
            let head = try loadProfileHead(in: fixture)
            XCTAssertEqual(head.generation, 3)
            guard case let .revision(pointer) = head.selection else {
                return XCTFail("Retry did not select the rebased revision")
            }
            XCTAssertEqual(pointer.revisionID, mutation.intendedRevisionID)
            let installed = try fixture.persistence.decodeProfileRevision(
                Data(
                    contentsOf: profileRevisionURL(
                        mutation.intendedRevisionID,
                        in: fixture
                    )
                )
            )
            XCTAssertEqual(installed.parentRevisionID, concurrent.revisionID)
        }
    }

    func testEvidencePublicationNoOpRetryRemovesProvedPreHeadOrphan()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedEvidenceFixture(in: parent)
            let concurrentStatement = try ProfileStatement(
                statementID: fixture.target.statementID,
                statementKind: fixture.target.statementKind,
                wording: fixture.target.wording,
                supportingSessionCount: 1,
                evidence: [fixture.appendedEvidence]
            )
            let concurrent = try ProfileRevision(
                revisionID: ProfileRevisionID(
                    "prf-20260910T125300000Z-8ABC"
                ),
                parentRevisionID: fixture.baseRevision.revisionID,
                generation: 2,
                statementGeneration: 1,
                createdAt: UTCInstant("2026-09-10T12:53:00.000Z"),
                statements: [concurrentStatement]
            )
            let concurrentHead = try installProfileRevision(
                concurrent,
                in: fixture
            )
            let baseData = try fixture.persistence.encodeProfileRevision(
                fixture.baseRevision
            )
            let baseHead = ProfileHead(
                generation: fixture.baseRevision.generation,
                statementGeneration: fixture.baseRevision.statementGeneration,
                selection: .revision(
                    try ProfileRevisionPointer(
                        revisionID: fixture.baseRevision.revisionID,
                        sha256: sha256(baseData)
                    )
                ),
                updatedAt: fixture.baseRevision.createdAt
            )
            let library = PortableLibraryPersistence()
            try library.atomicallyReplaceRootForTesting(
                library.encodeProfileHead(baseHead),
                relativePath: try LibraryRelativePath("profile/head.json"),
                under: fixture.root
            )
            let moved = OneShot()
            let racing = PortableChatPersistence { point in
                guard point == .beforeProfileHeadInstall, moved.take() else {
                    return
                }
                try library.atomicallyReplaceRootForTesting(
                    library.encodeProfileHead(concurrentHead),
                    relativePath: try LibraryRelativePath("profile/head.json"),
                    under: fixture.root
                )
            }
            let mutation = try PublishProfileEvidenceMutation(
                library: fixture.scope,
                base: fixture.published,
                responsePositionID:
                    fixture.profilePublication.responsePositionID
            )
            let first = PortableProfileProposalCoordinator(
                persistence: racing,
                workspace: fixture.workspace
            )

            let firstOutcome = await first.publishEvidence(mutation)
            XCTAssertEqual(firstOutcome, .stale(fixture.published))
            XCTAssertTrue(
                try profileRevisionDirectoryNames(in: fixture).contains(
                    mutation.intendedRevisionID.rawValue
                )
            )

            let retry = PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )
            guard case let .committed(resolved) = await retry.publishEvidence(
                mutation
            ) else { return XCTFail("Concurrent support did not become a no-op") }
            XCTAssertNil(resolved.profileEvidencePublication)
            XCTAssertEqual(try loadProfileHead(in: fixture), concurrentHead)
            XCTAssertFalse(
                try profileRevisionDirectoryNames(in: fixture).contains(
                    mutation.intendedRevisionID.rawValue
                )
            )
        }
    }

    func testEvidencePublicationPostCommitFaultsReconcileAndCleanOperation()
        async throws
    {
        for point in [
            PortableChatFaultPoint.afterProfileHeadInstall,
            .afterProfileHeadDirectoryFlush,
            .afterProfileEvidencePublicationRemoval,
        ] {
            try await withTemporaryParent { parent in
                let fixture = try await makePublishedEvidenceFixture(in: parent)
                let injected = OneShot()
                let faulting = PortableChatPersistence { visited in
                    guard visited == point, injected.take() else { return }
                    throw PortableChatPersistenceError.injectedFault(visited)
                }
                let coordinator = PortableProfileProposalCoordinator(
                    persistence: faulting,
                    workspace: fixture.workspace
                )
                let mutation = try PublishProfileEvidenceMutation(
                    library: fixture.scope,
                    base: fixture.published,
                    responsePositionID:
                        fixture.profilePublication.responsePositionID
                )

                guard case let .committed(resolved) = await coordinator
                    .publishEvidence(mutation)
                else {
                    return XCTFail("Post-commit fault did not reconcile at \(point)")
                }

                XCTAssertTrue(injected.wasTaken)
                XCTAssertNil(resolved.profileEvidencePublication)
                XCTAssertEqual(try loadProfileHead(in: fixture).generation, 2)
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: chatRoot(fixture).appendingPathComponent(
                            "profile-publication.json"
                        ).path
                    )
                )
            }
        }
    }

    func testEvidenceNoOpRemovalFaultFlushesBeforeReportingReconciledCommit()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedEvidenceFixture(
                in: parent,
                existingEvidence: true
            )
            let injected = OneShot()
            let faulting = PortableChatPersistence { point in
                guard point == .afterProfileEvidencePublicationRemoval,
                      injected.take()
                else { return }
                throw PortableChatPersistenceError.injectedFault(point)
            }
            let coordinator = PortableProfileProposalCoordinator(
                persistence: faulting,
                workspace: fixture.workspace
            )
            let mutation = try PublishProfileEvidenceMutation(
                library: fixture.scope,
                base: fixture.published,
                responsePositionID:
                    fixture.profilePublication.responsePositionID
            )

            guard case let .committed(resolved) = await coordinator
                .publishEvidence(mutation)
            else { return XCTFail("No-op removal was not reconciled") }
            XCTAssertTrue(injected.wasTaken)
            XCTAssertNil(resolved.profileEvidencePublication)
            XCTAssertFalse(
                fileExists(chatRoot(fixture), "profile-publication.json")
            )
            XCTAssertEqual(try loadProfileHead(in: fixture).generation, 1)
        }
    }

    func testEvidenceDiscardRemovalFaultFlushesBeforeReportingReconciledCommit()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedEvidenceFixture(in: parent)
            let injected = OneShot()
            let faulting = PortableChatPersistence { point in
                guard point == .afterProfileEvidencePublicationRemoval,
                      injected.take()
                else { return }
                throw PortableChatPersistenceError.injectedFault(point)
            }
            let coordinator = PortableProfileProposalCoordinator(
                persistence: faulting,
                workspace: fixture.workspace
            )
            let mutation = try DiscardProfileEvidencePublicationMutation(
                library: fixture.scope,
                base: fixture.published,
                responsePositionID:
                    fixture.profilePublication.responsePositionID
            )

            guard case let .committed(resolved) = await coordinator
                .discardEvidence(mutation)
            else { return XCTFail("Discard removal was not reconciled") }
            XCTAssertTrue(injected.wasTaken)
            XCTAssertNil(resolved.profileEvidencePublication)
            XCTAssertFalse(
                fileExists(chatRoot(fixture), "profile-publication.json")
            )
            XCTAssertEqual(try loadProfileHead(in: fixture).generation, 1)
        }
    }

    func testStaleEvidenceTargetIsRetainedAndDiscardDoesNotRollbackTurn()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedEvidenceFixture(in: parent)
            let retired = try ProfileRevision(
                revisionID: ProfileRevisionID("prf-20260910T130000000Z-2DEF"),
                parentRevisionID: fixture.baseRevision.revisionID,
                generation: 2,
                statementGeneration: 2,
                createdAt: UTCInstant("2026-09-10T13:00:00.000Z"),
                statements: []
            )
            let retiredHead = try installProfileRevision(retired, in: fixture)
            let coordinator = PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )
            let publish = try PublishProfileEvidenceMutation(
                library: fixture.scope,
                base: fixture.published,
                responsePositionID: fixture.profilePublication.responsePositionID
            )

            let staleOutcome = await coordinator.publishEvidence(publish)
            XCTAssertEqual(staleOutcome, .stale(fixture.published))
            XCTAssertEqual(try loadProfileHead(in: fixture), retiredHead)

            let discard = try DiscardProfileEvidencePublicationMutation(
                library: fixture.scope,
                base: fixture.published,
                responsePositionID: fixture.profilePublication.responsePositionID
            )
            guard case let .committed(resolved) = await coordinator.discardEvidence(
                discard
            ) else { return XCTFail("Evidence operation was not discarded") }
            XCTAssertNil(resolved.profileEvidencePublication)
            XCTAssertEqual(resolved.chat, fixture.published.chat)
            XCTAssertEqual(resolved.messages, fixture.published.messages)
            XCTAssertEqual(resolved.memory, fixture.published.memory)
            XCTAssertEqual(try loadProfileHead(in: fixture), retiredHead)
        }
    }

    func testProposalPublicationReopensTheExactChatOwnedProposal() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let proposalURL = chatRoot(fixture).appendingPathComponent(
                "proposal.json"
            )

            XCTAssertEqual(
                try Data(contentsOf: proposalURL),
                try fixture.persistence.encodeProfileProposal(fixture.proposal)
            )
            guard case let .readWrite(reopened) = try fixture.persistence.load(
                fixture.published.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else {
                return XCTFail("Published proposal did not reopen read-write")
            }
            XCTAssertEqual(reopened, fixture.published)
            XCTAssertEqual(reopened.profileProposal, fixture.proposal)
            XCTAssertEqual(
                reopened.profileProposal?.responsePositionID,
                fixture.publication.coachMessage.responsePositionID
            )
        }
    }

    func testAcceptPublishesVerifiedImmutableRevisionAndPreservesMemory()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let acceptedAt = try UTCInstant("2026-09-09T12:05:00.000Z")
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: acceptedAt
            )
            let coordinator = PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )

            let outcome = await coordinator.accept(mutation)

            guard case let .committed(resolved) = outcome else {
                return XCTFail("Expected accepted Profile proposal, got \(outcome)")
            }
            XCTAssertNil(resolved.profileProposal)
            XCTAssertEqual(resolved.chat, fixture.published.chat)
            XCTAssertEqual(resolved.messages, fixture.published.messages)
            XCTAssertEqual(resolved.memory, fixture.published.memory)
            XCTAssertEqual(
                resolved.memory.generalNotes,
                "Keep the exact synthetic coaching context."
            )

            let chatDirectory = chatRoot(fixture)
            XCTAssertFalse(fileExists(chatDirectory, "proposal.json"))
            XCTAssertFalse(fileExists(chatDirectory, "profile-write.json"))

            let headData = try Data(
                contentsOf: fixture.root.appendingPathComponent(
                    "profile/head.json"
                )
            )
            let head = try PortableLibraryPersistence().decodeProfileHead(
                headData
            )
            XCTAssertEqual(head.generation, 1)
            XCTAssertEqual(head.statementGeneration, 1)
            XCTAssertEqual(head.updatedAt, acceptedAt)
            guard case let .revision(pointer) = head.selection else {
                return XCTFail("Accepted Profile head did not select a revision")
            }
            XCTAssertEqual(pointer.revisionID, mutation.intendedRevisionID)

            let revisionDirectory = fixture.root.appendingPathComponent(
                "profile/revisions/\(pointer.revisionID.rawValue)",
                isDirectory: true
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: revisionDirectory.path
                ).sorted(),
                ["revision.json", "revision.sha256"]
            )
            let revisionData = try Data(
                contentsOf: revisionDirectory.appendingPathComponent(
                    "revision.json"
                )
            )
            let detachedDigest = try String(
                contentsOf: revisionDirectory.appendingPathComponent(
                    "revision.sha256"
                ),
                encoding: .utf8
            )
            XCTAssertEqual(pointer.sha256, sha256(revisionData))
            XCTAssertEqual(detachedDigest, pointer.sha256)

            let revision = try fixture.persistence.decodeProfileRevision(
                revisionData
            )
            XCTAssertEqual(revision.revisionID, mutation.intendedRevisionID)
            XCTAssertNil(revision.parentRevisionID)
            XCTAssertEqual(revision.generation, 1)
            XCTAssertEqual(revision.statementGeneration, 1)
            XCTAssertEqual(revision.createdAt, acceptedAt)
            XCTAssertEqual(revision.statements.count, 1)
            let statement = try XCTUnwrap(revision.statements.first)
            XCTAssertEqual(
                statement.statementID,
                fixture.proposedStatement.statementID
            )
            XCTAssertEqual(
                statement.statementKind,
                fixture.proposedStatement.statementKind
            )
            XCTAssertEqual(
                statement.wording,
                fixture.proposedStatement.wording
            )
            XCTAssertEqual(statement.supportingSessionCount, 0)
            XCTAssertEqual(statement.evidence, [])

            guard case let .readWrite(reopened) = try fixture.persistence.load(
                fixture.published.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else {
                return XCTFail("Accepted Chat did not reopen read-write")
            }
            XCTAssertEqual(reopened, resolved)
            XCTAssertEqual(reopened.memory, fixture.published.memory)
        }
    }

    func testAcceptEvidenceOnlyReconsiderProposalPreservesStatementGeneration()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedEvidenceOnlyProposalFixture(
                in: parent
            )
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.source.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-10T15:00:00.000Z")
            )
            let coordinator = PortableProfileProposalCoordinator(
                persistence: fixture.source.persistence,
                workspace: fixture.source.workspace
            )

            guard case let .committed(resolved) = await coordinator.accept(
                mutation
            ) else {
                return XCTFail("Evidence-only reviewed Proposal did not commit")
            }

            XCTAssertNil(resolved.profileProposal)
            XCTAssertFalse(fileExists(
                chatRoot(fixture.source),
                "proposal.json"
            ))
            XCTAssertFalse(fileExists(
                chatRoot(fixture.source),
                "profile-write.json"
            ))
            let head = try loadProfileHead(in: fixture.source)
            XCTAssertEqual(
                head.generation,
                fixture.source.baseRevision.generation + 1
            )
            XCTAssertEqual(
                head.statementGeneration,
                fixture.source.baseRevision.statementGeneration
            )
            guard case let .revision(pointer) = head.selection else {
                return XCTFail("Evidence-only Accept did not select its revision")
            }
            XCTAssertEqual(pointer.revisionID, mutation.intendedRevisionID)
        }
    }

    func testRelaunchFinishesEvidenceOnlyAcceptAfterDurableHeadInstall()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedEvidenceOnlyProposalFixture(
                in: parent
            )
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.source.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-10T15:01:00.000Z")
            )
            let oneShot = OneShot()
            let interrupted = PortableChatPersistence { point in
                guard point == .afterProfileHeadDirectoryFlush,
                      oneShot.take()
                else { return }
                throw PortableChatPersistenceError.injectedFault(point)
            }

            XCTAssertThrowsError(
                try interrupted.acceptProfileProposal(
                    mutation,
                    at: fixture.source.root
                )
            )
            XCTAssertTrue(oneShot.wasTaken)
            XCTAssertTrue(fileExists(
                chatRoot(fixture.source),
                "proposal.json"
            ))
            XCTAssertTrue(fileExists(
                chatRoot(fixture.source),
                "profile-write.json"
            ))

            guard case let .readWrite(recovered) = try fixture.source
                .persistence.load(
                    fixture.published.chat.id,
                    at: fixture.source.root,
                    in: fixture.source.scope
                )
            else {
                return XCTFail("Relaunch did not finish evidence-only Accept")
            }
            XCTAssertNil(recovered.profileProposal)
            XCTAssertFalse(fileExists(
                chatRoot(fixture.source),
                "proposal.json"
            ))
            XCTAssertFalse(fileExists(
                chatRoot(fixture.source),
                "profile-write.json"
            ))
            let head = try loadProfileHead(in: fixture.source)
            XCTAssertEqual(
                head.statementGeneration,
                fixture.source.baseRevision.statementGeneration
            )
            guard case let .revision(pointer) = head.selection else {
                return XCTFail("Recovered evidence-only head was not selected")
            }
            XCTAssertEqual(pointer.revisionID, mutation.intendedRevisionID)
        }
    }

    func testDiscardRemovesOnlyProposalAndPreservesProfileChatAndMemory()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let before = try unchangedDurableBytes(in: fixture)
            let mutation = try DiscardProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id
            )
            let coordinator = PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )

            let outcome = await coordinator.discard(mutation)

            guard case let .committed(resolved) = outcome else {
                return XCTFail("Expected discarded Profile proposal, got \(outcome)")
            }
            XCTAssertNil(resolved.profileProposal)
            XCTAssertEqual(resolved.chat, fixture.published.chat)
            XCTAssertEqual(resolved.messages, fixture.published.messages)
            XCTAssertEqual(resolved.memory, fixture.published.memory)
            XCTAssertEqual(try unchangedDurableBytes(in: fixture), before)
            XCTAssertFalse(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertFalse(fileExists(chatRoot(fixture), "profile-write.json"))
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: fixture.root.appendingPathComponent(
                        "profile/revisions"
                    ).path
                ),
                []
            )

            guard case let .readWrite(reopened) = try fixture.persistence.load(
                fixture.published.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else {
                return XCTFail("Discarded Chat did not reopen read-write")
            }
            XCTAssertEqual(reopened, resolved)
        }
    }

    func testStaleProfileHeadKeepsProposalForExplicitRecovery() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let competingHead = ProfileHead(
                generation: 1,
                statementGeneration: 1,
                selection: .null,
                updatedAt: try UTCInstant("2026-09-09T12:04:00.000Z")
            )
            let libraryPersistence = PortableLibraryPersistence()
            try libraryPersistence.atomicallyReplaceRootForTesting(
                libraryPersistence.encodeProfileHead(competingHead),
                relativePath: try LibraryRelativePath("profile/head.json"),
                under: fixture.root
            )
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: try UTCInstant("2026-09-09T12:05:00.000Z")
            )
            let coordinator = PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )

            let outcome = await coordinator.accept(mutation)

            XCTAssertEqual(outcome, .stale(fixture.published))
            XCTAssertTrue(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertFalse(fileExists(chatRoot(fixture), "profile-write.json"))
            XCTAssertEqual(
                try libraryPersistence.decodeProfileHead(
                    Data(
                        contentsOf: fixture.root.appendingPathComponent(
                            "profile/head.json"
                        )
                    )
                ),
                competingHead
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: fixture.root.appendingPathComponent(
                        "profile/revisions"
                    ).path
                ),
                []
            )
            guard case let .readWrite(reopened) = try fixture.persistence.load(
                fixture.published.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else {
                return XCTFail("Stale proposal did not remain readable")
            }
            XCTAssertEqual(reopened, fixture.published)
        }
    }

    func testRetryAfterPreIntentWriteFailureStartsFromUnchangedProposalState()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let before = try unchangedDurableBytes(in: fixture)
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:05:00.000Z")
            )
            let oneShot = OneShot()
            let faultingPersistence = PortableChatPersistence { point in
                guard point == .beforeProfileWriteIntentPartialWrite,
                      oneShot.take()
                else { return }
                throw PortableChatPersistenceError.injectedFault(point)
            }
            let coordinator = PortableProfileProposalCoordinator(
                persistence: faultingPersistence,
                workspace: fixture.workspace
            )

            let interrupted = await coordinator.accept(mutation)

            XCTAssertEqual(interrupted, .failed)
            XCTAssertTrue(oneShot.wasTaken)
            XCTAssertTrue(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertFalse(fileExists(chatRoot(fixture), "profile-write.json"))
            XCTAssertEqual(try profileRevisionDirectoryNames(in: fixture), [])
            XCTAssertEqual(try unchangedDurableBytes(in: fixture), before)
            guard case let .readWrite(stillProposed) = try fixture.persistence.load(
                fixture.published.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else {
                return XCTFail("Pre-intent crash did not leave a readable Chat")
            }
            XCTAssertEqual(stillProposed, fixture.published)
            XCTAssertEqual(stillProposed.memory, fixture.published.memory)

            let retryMutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:06:00.000Z")
            )
            let retried = await coordinator.accept(retryMutation)

            guard case let .committed(resolved) = retried else {
                return XCTFail("Retry after pre-intent crash did not commit")
            }
            XCTAssertNil(resolved.profileProposal)
            XCTAssertEqual(resolved.memory, fixture.published.memory)
            XCTAssertFalse(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertFalse(fileExists(chatRoot(fixture), "profile-write.json"))
            XCTAssertEqual(
                try profileRevisionDirectoryNames(in: fixture),
                [mutation.intendedRevisionID.rawValue]
            )
            let head = try loadProfileHead(in: fixture)
            guard case let .revision(pointer) = head.selection else {
                return XCTFail("Retry did not publish a Profile revision")
            }
            XCTAssertEqual(pointer.revisionID, mutation.intendedRevisionID)
        }
    }

    func testRetryAfterRevisionInstallFailureReusesExactRevisionAndCleansIntent()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let acceptedAt = try UTCInstant("2026-09-09T12:05:00.000Z")
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: acceptedAt
            )
            let oneShot = OneShot()
            let faultingPersistence = PortableChatPersistence { point in
                guard point == .afterProfileRevisionInstall,
                      oneShot.take()
                else { return }
                throw PortableChatPersistenceError.injectedFault(point)
            }
            let coordinator = PortableProfileProposalCoordinator(
                persistence: faultingPersistence,
                workspace: fixture.workspace
            )

            let interrupted = await coordinator.accept(mutation)

            XCTAssertEqual(interrupted, .failed)
            XCTAssertTrue(oneShot.wasTaken)
            XCTAssertTrue(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertTrue(fileExists(chatRoot(fixture), "profile-write.json"))
            XCTAssertEqual(
                try profileRevisionDirectoryNames(in: fixture),
                [mutation.intendedRevisionID.rawValue]
            )
            let revisionURL = profileRevisionURL(
                mutation.intendedRevisionID,
                in: fixture
            )
            let installedRevisionData = try Data(contentsOf: revisionURL)
            let interruptedHead = try loadProfileHead(in: fixture)
            XCTAssertEqual(interruptedHead.generation, 0)
            XCTAssertEqual(interruptedHead.statementGeneration, 0)
            XCTAssertEqual(interruptedHead.selection, .null)

            let retryMutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:06:00.000Z")
            )
            let retried = await coordinator.accept(retryMutation)

            guard case let .committed(resolved) = retried else {
                return XCTFail("Retry did not finish the exact Profile commit")
            }
            XCTAssertNil(resolved.profileProposal)
            XCTAssertEqual(resolved.memory, fixture.published.memory)
            XCTAssertFalse(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertFalse(fileExists(chatRoot(fixture), "profile-write.json"))
            XCTAssertEqual(
                try profileRevisionDirectoryNames(in: fixture),
                [mutation.intendedRevisionID.rawValue]
            )
            XCTAssertEqual(
                try Data(contentsOf: revisionURL),
                installedRevisionData,
                "Retry must verify and reuse the immutable installed revision"
            )
            let committedHead = try loadProfileHead(in: fixture)
            XCTAssertEqual(committedHead.generation, 1)
            XCTAssertEqual(committedHead.statementGeneration, 1)
            XCTAssertEqual(committedHead.updatedAt, acceptedAt)
            guard case let .revision(pointer) = committedHead.selection else {
                return XCTFail("Retry did not select the intended revision")
            }
            XCTAssertEqual(pointer.revisionID, mutation.intendedRevisionID)
        }
    }

    func testPostCommitFaultsReconcileAcceptanceAndCleanTransientFiles()
        async throws
    {
        let points: [PortableChatFaultPoint] = [
            .afterProfileHeadInstall,
            .afterProfileProposalRemoval,
        ]
        try await withTemporaryParent { parent in
            for (ordinal, point) in points.enumerated() {
                let fixture = try await makePublishedProposalFixture(
                    in: parent,
                    ordinal: ordinal
                )
                let hour = ordinal == 0 ? "12" : "13"
                let mutation = try AcceptProfileProposalMutation(
                    library: fixture.scope,
                    base: fixture.published,
                    proposalID: fixture.proposal.id,
                    acceptedAt: UTCInstant(
                        "2026-09-09T\(hour):05:00.000Z"
                    )
                )
                let oneShot = OneShot()
                let faultingPersistence = PortableChatPersistence { reached in
                    guard reached == point, oneShot.take() else { return }
                    throw PortableChatPersistenceError.injectedFault(reached)
                }
                let coordinator = PortableProfileProposalCoordinator(
                    persistence: faultingPersistence,
                    workspace: fixture.workspace
                )

                let outcome = await coordinator.accept(mutation)

                guard case let .committed(resolved) = outcome else {
                    return XCTFail(
                        "Post-commit fault \(point) did not reconcile as committed"
                    )
                }
                XCTAssertTrue(oneShot.wasTaken, String(describing: point))
                XCTAssertNil(resolved.profileProposal, String(describing: point))
                XCTAssertEqual(
                    resolved.memory,
                    fixture.published.memory,
                    String(describing: point)
                )
                XCTAssertFalse(
                    fileExists(chatRoot(fixture), "proposal.json"),
                    String(describing: point)
                )
                XCTAssertFalse(
                    fileExists(chatRoot(fixture), "profile-write.json"),
                    String(describing: point)
                )
                XCTAssertEqual(
                    try profileRevisionDirectoryNames(in: fixture),
                    [mutation.intendedRevisionID.rawValue],
                    String(describing: point)
                )
                let head = try loadProfileHead(in: fixture)
                guard case let .revision(pointer) = head.selection else {
                    return XCTFail(
                        "Post-commit fault \(point) lost the selected revision"
                    )
                }
                XCTAssertEqual(
                    pointer.revisionID,
                    mutation.intendedRevisionID,
                    String(describing: point)
                )
                guard case let .readWrite(reopened) = try fixture.persistence.load(
                    fixture.published.chat.id,
                    at: fixture.root,
                    in: fixture.scope
                ) else {
                    return XCTFail(
                        "Post-commit fault \(point) did not leave a readable Chat"
                    )
                }
                XCTAssertEqual(reopened, resolved, String(describing: point))
            }
        }
    }

    func testDiscardAfterPreHeadAcceptFailureProvesNoCommitAndCleansIntent()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let acceptedAt = try UTCInstant("2026-09-09T12:05:00.000Z")
            let acceptance = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: acceptedAt
            )
            let oneShot = OneShot()
            let faultingPersistence = PortableChatPersistence { point in
                guard point == .afterProfileRevisionInstall,
                      oneShot.take()
                else { return }
                throw PortableChatPersistenceError.injectedFault(point)
            }
            let coordinator = PortableProfileProposalCoordinator(
                persistence: faultingPersistence,
                workspace: fixture.workspace
            )

            let interrupted = await coordinator.accept(acceptance)
            XCTAssertEqual(interrupted, .failed)
            XCTAssertTrue(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertTrue(fileExists(chatRoot(fixture), "profile-write.json"))
            XCTAssertEqual(
                try profileRevisionDirectoryNames(in: fixture),
                [acceptance.intendedRevisionID.rawValue]
            )

            let discard = try DiscardProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id
            )
            let outcome = await coordinator.discard(discard)

            guard case let .committed(resolved) = outcome else {
                return XCTFail("Discard could not prove the interrupted Accept was uncommitted")
            }
            XCTAssertNil(resolved.profileProposal)
            XCTAssertEqual(resolved.memory, fixture.published.memory)
            XCTAssertFalse(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertFalse(fileExists(chatRoot(fixture), "profile-write.json"))
            XCTAssertEqual(try profileRevisionDirectoryNames(in: fixture), [])
            let head = try loadProfileHead(in: fixture)
            XCTAssertEqual(head.generation, 0)
            XCTAssertEqual(head.statementGeneration, 0)
            XCTAssertEqual(head.selection, .null)
        }
    }

    func testRelaunchFinishesInterruptedAcceptDiscardAfterProposalCleanup()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let acceptance = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:05:00.000Z")
            )
            let acceptFault = OneShot()
            let interruptedAccept = PortableChatPersistence { point in
                guard point == .afterProfileRevisionInstall,
                      acceptFault.take()
                else { return }
                throw PortableChatPersistenceError.injectedFault(point)
            }
            XCTAssertThrowsError(
                try interruptedAccept.acceptProfileProposal(
                    acceptance,
                    at: fixture.root
                )
            )
            XCTAssertTrue(acceptFault.wasTaken)

            let discardFault = OneShot()
            let interruptedDiscard = PortableChatPersistence { point in
                guard point == .afterProfileProposalRemoval,
                      discardFault.take()
                else { return }
                throw PortableChatPersistenceError.injectedFault(point)
            }
            XCTAssertThrowsError(
                try interruptedDiscard.discardProfileProposal(
                    DiscardProfileProposalMutation(
                        library: fixture.scope,
                        base: fixture.published,
                        proposalID: fixture.proposal.id
                    ),
                    at: fixture.root
                )
            )

            XCTAssertTrue(discardFault.wasTaken)
            XCTAssertFalse(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertTrue(
                fileExists(chatRoot(fixture), "profile-write.json"),
                "The durable intent must retire only after Proposal cleanup"
            )

            guard case let .readWrite(recovered) = try fixture.persistence.load(
                fixture.published.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else {
                return XCTFail("Relaunch did not finish interrupted Discard")
            }
            XCTAssertNil(recovered.profileProposal)
            XCTAssertFalse(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertFalse(fileExists(chatRoot(fixture), "profile-write.json"))
            XCTAssertEqual(try profileRevisionDirectoryNames(in: fixture), [])
            XCTAssertEqual(try loadProfileHead(in: fixture).selection, .null)
        }
    }

    func testRetryAfterWriteIntentInstallUsesDurableIntentTimestamp()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let acceptedAt = try UTCInstant("2026-09-09T12:05:00.000Z")
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: acceptedAt
            )
            let oneShot = OneShot()
            let faulting = PortableChatPersistence { point in
                guard point == .afterProfileWriteIntentInstall,
                      oneShot.take()
                else { return }
                throw PortableChatPersistenceError.injectedFault(point)
            }
            let faultingCoordinator = PortableProfileProposalCoordinator(
                persistence: faulting,
                workspace: fixture.workspace
            )

            let interrupted = await faultingCoordinator.accept(mutation)

            XCTAssertEqual(interrupted, .failed)
            XCTAssertTrue(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertTrue(fileExists(chatRoot(fixture), "profile-write.json"))
            XCTAssertEqual(try profileRevisionDirectoryNames(in: fixture), [])

            let retry = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:06:00.000Z")
            )
            let coordinator = PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )
            guard case .committed = await coordinator.accept(retry) else {
                return XCTFail("Retry did not complete the durable write intent")
            }
            XCTAssertEqual(try loadProfileHead(in: fixture).updatedAt, acceptedAt)
        }
    }

    func testRelaunchResumesAcceptedProposalBeforeExposingChat() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:05:00.000Z")
            )
            let interrupted = PortableChatPersistence { point in
                guard point == .afterProfileWriteIntentInstall else { return }
                throw PortableChatPersistenceError.injectedFault(point)
            }

            XCTAssertThrowsError(
                try interrupted.acceptProfileProposal(
                    mutation,
                    at: fixture.root
                )
            )
            XCTAssertTrue(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertTrue(fileExists(chatRoot(fixture), "profile-write.json"))

            let catalog = try fixture.persistence.loadCatalog(
                at: fixture.root,
                in: fixture.scope
            )
            guard catalog.count == 1,
                  case let .readWrite(reopened) = catalog[0]
            else {
                return XCTFail("Relaunch did not finish the accepted proposal")
            }

            XCTAssertNil(reopened.profileProposal)
            XCTAssertFalse(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertFalse(fileExists(chatRoot(fixture), "profile-write.json"))
            let head = try loadProfileHead(in: fixture)
            guard case let .revision(pointer) = head.selection else {
                return XCTFail("Relaunch did not select the intended revision")
            }
            XCTAssertEqual(pointer.revisionID, mutation.intendedRevisionID)
        }
    }

    func testStoreCatalogReconcilesAcceptedProfileWriteBeforeInvocationRecovery()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:05:00.000Z")
            )
            let interrupted = PortableChatPersistence { point in
                guard point == .afterProfileWriteIntentDirectoryFlush else {
                    return
                }
                throw PortableChatPersistenceError.injectedFault(point)
            }

            XCTAssertThrowsError(
                try interrupted.acceptProfileProposal(
                    mutation,
                    at: fixture.root
                )
            )
            XCTAssertTrue(fileExists(chatRoot(fixture), "profile-write.json"))

            let store = PortableChatStore(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )
            guard case let .loaded(entries) = await store.loadCatalog(
                in: fixture.scope
            ), entries.count == 1,
                case let .available(reopened) = entries[0]
            else {
                return XCTFail(
                    "Store catalog failed before reconciling the accepted Profile write"
                )
            }

            XCTAssertNil(reopened.profileProposal)
            XCTAssertFalse(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertFalse(fileExists(chatRoot(fixture), "profile-write.json"))
            guard case let .revision(pointer) = try loadProfileHead(
                in: fixture
            ).selection else {
                return XCTFail("Store catalog did not select the intended revision")
            }
            XCTAssertEqual(pointer.revisionID, mutation.intendedRevisionID)
        }
    }

    func testStoreOpenReconcilesAcceptedProfileWriteBeforeInvocationRecovery()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:05:00.000Z")
            )
            let interrupted = PortableChatPersistence { point in
                guard point == .afterProfileWriteIntentDirectoryFlush else {
                    return
                }
                throw PortableChatPersistenceError.injectedFault(point)
            }

            XCTAssertThrowsError(
                try interrupted.acceptProfileProposal(
                    mutation,
                    at: fixture.root
                )
            )
            XCTAssertTrue(fileExists(chatRoot(fixture), "profile-write.json"))

            let store = PortableChatStore(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )
            guard case let .loaded(reopened) = await store.load(
                fixture.published.chat.id,
                in: fixture.scope
            ) else {
                return XCTFail(
                    "Store open failed before reconciling the accepted Profile write"
                )
            }

            XCTAssertNil(reopened.profileProposal)
            XCTAssertFalse(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertFalse(fileExists(chatRoot(fixture), "profile-write.json"))
            guard case let .revision(pointer) = try loadProfileHead(
                in: fixture
            ).selection else {
                return XCTFail("Store open did not select the intended revision")
            }
            XCTAssertEqual(pointer.revisionID, mutation.intendedRevisionID)
        }
    }

    func testRelaunchRecoversEveryDurableAcceptCrashPhase() async throws {
        let points: [PortableChatFaultPoint] = [
            .afterProfileWriteIntentDirectoryFlush,
            .afterProfileRevisionInstall,
            .beforeProfileHeadPartialWrite,
            .afterProfileHeadPartialWrite,
            .afterProfileHeadFileFlush,
            .beforeProfileHeadInstall,
            .afterProfileHeadInstall,
            .afterProfileHeadDirectoryFlush,
            .afterProfileProposalRemoval,
            .afterProfileWriteIntentRemoval,
        ]
        try await withTemporaryParent { parent in
            for (ordinal, point) in points.enumerated() {
                let fixture = try await makePublishedProposalFixture(
                    in: parent,
                    ordinal: ordinal + 10
                )
                let mutation = try AcceptProfileProposalMutation(
                    library: fixture.scope,
                    base: fixture.published,
                    proposalID: fixture.proposal.id,
                    acceptedAt: UTCInstant("2026-09-09T14:05:00.000Z")
                )
                let interrupted = PortableChatPersistence { reached in
                    guard reached == point else { return }
                    throw PortableChatPersistenceError.injectedFault(reached)
                }

                XCTAssertThrowsError(
                    try interrupted.acceptProfileProposal(
                        mutation,
                        at: fixture.root
                    ),
                    String(describing: point)
                )
                guard case let .readWrite(reopened) = try fixture.persistence
                    .load(
                        fixture.published.chat.id,
                        at: fixture.root,
                        in: fixture.scope
                    )
                else {
                    return XCTFail(
                        "Relaunch did not recover \(point)"
                    )
                }
                XCTAssertNil(
                    reopened.profileProposal,
                    String(describing: point)
                )
                XCTAssertFalse(
                    fileExists(chatRoot(fixture), "proposal.json"),
                    String(describing: point)
                )
                XCTAssertFalse(
                    fileExists(chatRoot(fixture), "profile-write.json"),
                    String(describing: point)
                )
                XCTAssertEqual(
                    try profileRevisionDirectoryNames(in: fixture),
                    [mutation.intendedRevisionID.rawValue],
                    String(describing: point)
                )
                guard case let .revision(pointer) = try loadProfileHead(
                    in: fixture
                ).selection else {
                    return XCTFail("Relaunch lost the Profile head at \(point)")
                }
                XCTAssertEqual(
                    pointer.revisionID,
                    mutation.intendedRevisionID,
                    String(describing: point)
                )
            }
        }
    }

    func testRelaunchFailsClosedForUnboundLegacyWriteIntent() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:05:00.000Z")
            )
            let interrupted = PortableChatPersistence { point in
                guard point == .afterProfileWriteIntentInstall else { return }
                throw PortableChatPersistenceError.injectedFault(point)
            }
            XCTAssertThrowsError(
                try interrupted.acceptProfileProposal(
                    mutation,
                    at: fixture.root
                )
            )
            let intentURL = chatRoot(fixture).appendingPathComponent(
                "profile-write.json"
            )
            var legacy = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: intentURL)
                ) as? [String: Any]
            )
            legacy["schemaVersion"] = 1
            legacy.removeValue(forKey: "proposalSha256")
            legacy.removeValue(forKey: "intendedRevisionSha256")
            try JSONSerialization.data(
                withJSONObject: legacy,
                options: [.sortedKeys]
            ).write(to: intentURL)

            XCTAssertThrowsError(try fixture.persistence.loadCatalog(
                at: fixture.root,
                in: fixture.scope
            )) { error in
                XCTAssertEqual(
                    error as? PortableChatPersistenceError,
                    .invalidLayout
                )
            }
            XCTAssertTrue(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertTrue(fileExists(chatRoot(fixture), "profile-write.json"))
            XCTAssertEqual(try loadProfileHead(in: fixture).selection, .null)
        }
    }

    func testRelaunchFailsClosedForTamperedIntentBinding() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:05:00.000Z")
            )
            let interrupted = PortableChatPersistence { point in
                guard point == .afterProfileWriteIntentInstall else { return }
                throw PortableChatPersistenceError.injectedFault(point)
            }
            XCTAssertThrowsError(
                try interrupted.acceptProfileProposal(
                    mutation,
                    at: fixture.root
                )
            )
            let intentURL = chatRoot(fixture).appendingPathComponent(
                "profile-write.json"
            )
            var intent = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: intentURL)
                ) as? [String: Any]
            )
            intent["proposalSha256"] = String(repeating: "0", count: 64)
            try JSONSerialization.data(
                withJSONObject: intent,
                options: [.sortedKeys]
            ).write(to: intentURL)

            XCTAssertThrowsError(try fixture.persistence.load(
                fixture.published.chat.id,
                at: fixture.root,
                in: fixture.scope
            )) { error in
                XCTAssertEqual(
                    error as? PortableChatPersistenceError,
                    .invalidLayout
                )
            }
            XCTAssertTrue(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertTrue(fileExists(chatRoot(fixture), "profile-write.json"))
            XCTAssertEqual(try profileRevisionDirectoryNames(in: fixture), [])
            XCTAssertEqual(try loadProfileHead(in: fixture).selection, .null)
        }
    }

    func testRelaunchFailsClosedForDivergentProfileHead() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:05:00.000Z")
            )
            let interrupted = PortableChatPersistence { point in
                guard point == .afterProfileWriteIntentInstall else { return }
                throw PortableChatPersistenceError.injectedFault(point)
            }
            XCTAssertThrowsError(
                try interrupted.acceptProfileProposal(
                    mutation,
                    at: fixture.root
                )
            )
            let divergent = ProfileHead(
                generation: 1,
                statementGeneration: 0,
                selection: .null,
                updatedAt: try UTCInstant("2026-09-09T12:04:00.000Z")
            )
            let library = PortableLibraryPersistence()
            try library.atomicallyReplaceRootForTesting(
                library.encodeProfileHead(divergent),
                relativePath: LibraryRelativePath("profile/head.json"),
                under: fixture.root
            )

            XCTAssertThrowsError(try fixture.persistence.load(
                fixture.published.chat.id,
                at: fixture.root,
                in: fixture.scope
            )) { error in
                XCTAssertEqual(
                    error as? PortableChatPersistenceError,
                    .invalidLayout
                )
            }
            XCTAssertTrue(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertTrue(fileExists(chatRoot(fixture), "profile-write.json"))
            XCTAssertEqual(try profileRevisionDirectoryNames(in: fixture), [])
            XCTAssertEqual(try loadProfileHead(in: fixture), divergent)
        }
    }

    func testRelaunchFailsClosedWhenLibraryContainsMultipleWriteIntents()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:05:00.000Z")
            )
            let interrupted = PortableChatPersistence { point in
                guard point == .afterProfileWriteIntentInstall else { return }
                throw PortableChatPersistenceError.injectedFault(point)
            }
            XCTAssertThrowsError(
                try interrupted.acceptProfileProposal(
                    mutation,
                    at: fixture.root
                )
            )
            let second = fixture.root.appendingPathComponent(
                "chats/cht-20260909T150000000Z-1ABC",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: second,
                withIntermediateDirectories: false
            )
            try Data(
                contentsOf: chatRoot(fixture).appendingPathComponent(
                    "profile-write.json"
                )
            ).write(to: second.appendingPathComponent("profile-write.json"))

            XCTAssertThrowsError(try fixture.persistence.loadCatalog(
                at: fixture.root,
                in: fixture.scope
            )) { error in
                XCTAssertEqual(
                    error as? PortableChatPersistenceError,
                    .invalidLayout
                )
            }
            XCTAssertTrue(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertTrue(fileExists(chatRoot(fixture), "profile-write.json"))
            XCTAssertEqual(try loadProfileHead(in: fixture).selection, .null)
        }
    }

    func testAcceptRejectsCanonicalChatDirectoryReplacementBeforeHeadCommit()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let canonical = chatRoot(fixture)
            let displaced = parent.appendingPathComponent(
                "displaced-profile-proposal-chat",
                isDirectory: true
            )
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:05:00.000Z")
            )
            let oneShot = OneShot()
            let faulting = PortableChatPersistence { point in
                guard point == .afterProfileRevisionInstall,
                      oneShot.take()
                else { return }
                try FileManager.default.moveItem(at: canonical, to: displaced)
                try FileManager.default.copyItem(at: displaced, to: canonical)
            }
            let coordinator = PortableProfileProposalCoordinator(
                persistence: faulting,
                workspace: fixture.workspace
            )

            let outcome = await coordinator.accept(mutation)

            XCTAssertEqual(outcome, .failed)
            XCTAssertTrue(oneShot.wasTaken)
            XCTAssertEqual(try loadProfileHead(in: fixture).selection, .null)
            XCTAssertTrue(fileExists(canonical, "proposal.json"))
            XCTAssertTrue(fileExists(canonical, "profile-write.json"))
            XCTAssertTrue(fileExists(displaced, "proposal.json"))
            XCTAssertTrue(fileExists(displaced, "profile-write.json"))
        }
    }

    func testForeignWriteIntentFencesAcceptButDoesNotBlockPlainDiscard()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let foreign = fixture.root.appendingPathComponent(
                "chats/cht-20260909T110000000Z-0AAA",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: foreign,
                withIntermediateDirectories: false
            )
            try Data("synthetic outstanding intent".utf8).write(
                to: foreign.appendingPathComponent("profile-write.json")
            )
            let coordinator = PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )
            let accept = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:05:00.000Z")
            )

            let fenced = await coordinator.accept(accept)
            XCTAssertEqual(fenced, .failed)
            XCTAssertFalse(fileExists(chatRoot(fixture), "profile-write.json"))
            XCTAssertEqual(try loadProfileHead(in: fixture).selection, .null)

            let discard = try DiscardProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id
            )
            guard case let .committed(resolved) = await coordinator.discard(
                discard
            ) else {
                return XCTFail("Foreign Profile writer blocked a plain Discard")
            }
            XCTAssertNil(resolved.profileProposal)
            XCTAssertTrue(fileExists(foreign, "profile-write.json"))
        }
    }

    func testDiscardReconcilesAfterProposalRemovalDespiteStaleProfileHead()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let competingHead = ProfileHead(
                generation: 1,
                statementGeneration: 1,
                selection: .null,
                updatedAt: try UTCInstant("2026-09-09T12:04:00.000Z")
            )
            let libraryPersistence = PortableLibraryPersistence()
            try libraryPersistence.atomicallyReplaceRootForTesting(
                libraryPersistence.encodeProfileHead(competingHead),
                relativePath: try LibraryRelativePath("profile/head.json"),
                under: fixture.root
            )
            let oneShot = OneShot()
            let faulting = PortableChatPersistence { point in
                guard point == .afterProfileProposalRemoval,
                      oneShot.take()
                else { return }
                throw PortableChatPersistenceError.injectedFault(point)
            }
            let coordinator = PortableProfileProposalCoordinator(
                persistence: faulting,
                workspace: fixture.workspace
            )
            let discard = try DiscardProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id
            )

            let outcome = await coordinator.discard(discard)
            XCTAssertEqual(
                outcome,
                .failed,
                "an absent decision marker cannot prove Discard beat a semantic Profile commit"
            )
            XCTAssertFalse(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertEqual(try loadProfileHead(in: fixture), competingHead)
        }
    }

    func testCatalogRecoveryRemovesOwnedProfileRevisionTombstone()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:05:00.000Z")
            )
            let coordinator = PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )
            guard case .committed = await coordinator.accept(mutation) else {
                return XCTFail("Fixture acceptance did not commit")
            }
            let installed = fixture.root.appendingPathComponent(
                "profile/revisions/\(mutation.intendedRevisionID.rawValue)",
                isDirectory: true
            )
            let tombstone = fixture.root.appendingPathComponent(
                "staging/publications/.profile-\(mutation.intendedRevisionID.rawValue)-00000000-0000-0000-0000-000000000000.partial",
                isDirectory: true
            )
            try FileManager.default.copyItem(at: installed, to: tombstone)

            _ = try fixture.persistence.load(
                fixture.published.chat.id,
                at: fixture.root,
                in: fixture.scope
            )

            XCTAssertFalse(FileManager.default.fileExists(atPath: tombstone.path))
        }
    }

    func testCatalogRecoveryPreservesOversizedProfileNamedCandidate()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let candidate = fixture.root.appendingPathComponent(
                "staging/publications/.profile-prf-20260909T120500000Z-8XYZ-00000000-0000-0000-0000-000000000000.partial",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: candidate,
                withIntermediateDirectories: false
            )
            for name in ["revision.json", "revision.sha256", "unknown"] {
                try Data(name.utf8).write(
                    to: candidate.appendingPathComponent(name)
                )
            }

            guard case .readWrite = try fixture.persistence.load(
                fixture.published.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("Healthy Chat did not remain readable") }

            XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
        }
    }

    func testRetryAfterAbortRenameMakesRevisionAbsenceDurableBeforeDiscard()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let acceptance = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:05:00.000Z")
            )
            let acceptFault = OneShot()
            let interruptedAccept = PortableProfileProposalCoordinator(
                persistence: PortableChatPersistence { point in
                    guard point == .afterProfileRevisionInstall,
                          acceptFault.take()
                    else { return }
                    throw PortableChatPersistenceError.injectedFault(point)
                },
                workspace: fixture.workspace
            )
            let interruptedAcceptOutcome = await interruptedAccept.accept(
                acceptance
            )
            XCTAssertEqual(interruptedAcceptOutcome, .failed)

            let discard = try DiscardProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id
            )
            let renameFault = OneShot()
            let interruptedRename = PortableProfileProposalCoordinator(
                persistence: PortableChatPersistence { point in
                    guard point == .afterProfileRevisionAbortRename,
                          renameFault.take()
                    else { return }
                    throw PortableChatPersistenceError.injectedFault(point)
                },
                workspace: fixture.workspace
            )
            let interruptedRenameOutcome = await interruptedRename.discard(
                discard
            )
            XCTAssertEqual(interruptedRenameOutcome, .failed)
            XCTAssertTrue(renameFault.wasTaken)
            XCTAssertTrue(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertTrue(fileExists(chatRoot(fixture), "profile-write.json"))
            XCTAssertEqual(try profileRevisionDirectoryNames(in: fixture), [])

            let absenceFault = OneShot()
            let interruptedAbsenceProof = PortableProfileProposalCoordinator(
                persistence: PortableChatPersistence { point in
                    guard point == .afterProfileRevisionAbsenceDirectoryFlush,
                          absenceFault.take()
                    else { return }
                    throw PortableChatPersistenceError.injectedFault(point)
                },
                workspace: fixture.workspace
            )
            let interruptedAbsenceOutcome = await interruptedAbsenceProof.discard(
                discard
            )
            XCTAssertEqual(interruptedAbsenceOutcome, .failed)
            XCTAssertTrue(absenceFault.wasTaken)
            XCTAssertTrue(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertTrue(fileExists(chatRoot(fixture), "profile-write.json"))

            let retry = PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )
            guard case let .committed(resolved) = await retry.discard(discard)
            else { return XCTFail("Durably proved retry did not finish Discard") }
            XCTAssertNil(resolved.profileProposal)
            XCTAssertFalse(fileExists(chatRoot(fixture), "proposal.json"))
            XCTAssertFalse(fileExists(chatRoot(fixture), "profile-write.json"))
            XCTAssertEqual(try profileRevisionDirectoryNames(in: fixture), [])
            XCTAssertEqual(try loadProfileHead(in: fixture).selection, .null)
        }
    }

    func testCatalogRecoveryRejectsProfileCandidateDirectoryReplacement()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:05:00.000Z")
            )
            let coordinator = PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )
            guard case .committed = await coordinator.accept(mutation) else {
                return XCTFail("Fixture acceptance did not commit")
            }
            let installed = fixture.root.appendingPathComponent(
                "profile/revisions/\(mutation.intendedRevisionID.rawValue)",
                isDirectory: true
            )
            let candidate = fixture.root.appendingPathComponent(
                "staging/publications/.profile-\(mutation.intendedRevisionID.rawValue)-11111111-1111-1111-1111-111111111111.partial",
                isDirectory: true
            )
            let displaced = parent.appendingPathComponent(
                "displaced-profile-cleanup-candidate",
                isDirectory: true
            )
            try FileManager.default.copyItem(at: installed, to: candidate)
            let foreignData = Data("synthetic foreign replacement".utf8)
            let oneShot = OneShot()
            let faulting = PortableChatPersistence { point in
                guard point == .beforeStagedProfileRevisionCleanup,
                      oneShot.take()
                else { return }
                try FileManager.default.moveItem(at: candidate, to: displaced)
                try FileManager.default.createDirectory(
                    at: candidate,
                    withIntermediateDirectories: false
                )
                try foreignData.write(
                    to: candidate.appendingPathComponent("revision.json")
                )
            }

            XCTAssertThrowsError(try faulting.load(
                fixture.published.chat.id,
                at: fixture.root,
                in: fixture.scope
            )) { error in
                XCTAssertEqual(
                    error as? PortableChatPersistenceError,
                    .invalidLayout
                )
            }
            XCTAssertTrue(oneShot.wasTaken)
            XCTAssertEqual(
                try Data(contentsOf: candidate.appendingPathComponent(
                    "revision.json"
                )),
                foreignData
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: displaced.path))
        }
    }

    func testCatalogRecoveryRejectsProfileCandidateLeafReplacement()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:05:00.000Z")
            )
            let coordinator = PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )
            guard case .committed = await coordinator.accept(mutation) else {
                return XCTFail("Fixture acceptance did not commit")
            }
            let installed = fixture.root.appendingPathComponent(
                "profile/revisions/\(mutation.intendedRevisionID.rawValue)",
                isDirectory: true
            )
            let candidate = fixture.root.appendingPathComponent(
                "staging/publications/.profile-\(mutation.intendedRevisionID.rawValue)-22222222-2222-2222-2222-222222222222.partial",
                isDirectory: true
            )
            try FileManager.default.copyItem(at: installed, to: candidate)
            let digest = candidate.appendingPathComponent("revision.sha256")
            let displacedDigest = parent.appendingPathComponent(
                "displaced-profile-revision.sha256"
            )
            let foreignData = Data(String(repeating: "f", count: 64).utf8)
            let oneShot = OneShot()
            let faulting = PortableChatPersistence { point in
                guard point == .beforeStagedProfileRevisionLeafCleanup,
                      oneShot.take()
                else { return }
                try FileManager.default.moveItem(
                    at: digest,
                    to: displacedDigest
                )
                try foreignData.write(to: digest)
            }

            XCTAssertThrowsError(try faulting.load(
                fixture.published.chat.id,
                at: fixture.root,
                in: fixture.scope
            )) { error in
                XCTAssertEqual(
                    error as? PortableChatPersistenceError,
                    .invalidLayout
                )
            }
            XCTAssertTrue(oneShot.wasTaken)
            XCTAssertEqual(try Data(contentsOf: digest), foreignData)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: displacedDigest.path
            ))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("revision.json").path
            ))
        }
    }

    func testCatalogRecoveryRejectsInPlaceProfileCandidateMutation()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:05:00.000Z")
            )
            let coordinator = PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )
            guard case .committed = await coordinator.accept(mutation) else {
                return XCTFail("Fixture acceptance did not commit")
            }
            let candidate = fixture.root.appendingPathComponent(
                "staging/publications/.profile-\(mutation.intendedRevisionID.rawValue)-55555555-5555-5555-5555-555555555555.partial",
                isDirectory: true
            )
            try FileManager.default.copyItem(
                at: fixture.root.appendingPathComponent(
                    "profile/revisions/\(mutation.intendedRevisionID.rawValue)",
                    isDirectory: true
                ),
                to: candidate
            )
            let digest = candidate.appendingPathComponent("revision.sha256")
            let foreignData = Data(String(repeating: "f", count: 64).utf8)
            let oneShot = OneShot()
            let faulting = PortableChatPersistence { point in
                guard point == .beforeStagedProfileRevisionLeafCleanup,
                      oneShot.take()
                else { return }
                let handle = try FileHandle(forWritingTo: digest)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: foreignData)
                try handle.close()
            }

            XCTAssertThrowsError(try faulting.load(
                fixture.published.chat.id,
                at: fixture.root,
                in: fixture.scope
            )) { error in
                XCTAssertEqual(
                    error as? PortableChatPersistenceError,
                    .invalidLayout
                )
            }
            XCTAssertTrue(oneShot.wasTaken)
            XCTAssertEqual(try Data(contentsOf: digest), foreignData)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("revision.json").path
            ))
        }
    }

    func testCatalogRecoveryPreservesUnprovedProfileCandidatePhases()
        async throws
    {
        try await withTemporaryParent { parent in
            let fixture = try await makePublishedProposalFixture(in: parent)
            let mutation = try AcceptProfileProposalMutation(
                library: fixture.scope,
                base: fixture.published,
                proposalID: fixture.proposal.id,
                acceptedAt: UTCInstant("2026-09-09T12:05:00.000Z")
            )
            let coordinator = PortableProfileProposalCoordinator(
                persistence: fixture.persistence,
                workspace: fixture.workspace
            )
            guard case .committed = await coordinator.accept(mutation) else {
                return XCTFail("Fixture acceptance did not commit")
            }
            let publications = fixture.root.appendingPathComponent(
                "staging/publications",
                isDirectory: true
            )
            let shaOnly = publications.appendingPathComponent(
                ".profile-\(mutation.intendedRevisionID.rawValue)-33333333-3333-3333-3333-333333333333.partial",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: shaOnly,
                withIntermediateDirectories: false
            )
            try Data(String(repeating: "0", count: 64).utf8).write(
                to: shaOnly.appendingPathComponent("revision.sha256")
            )
            let mismatched = publications.appendingPathComponent(
                ".profile-\(mutation.intendedRevisionID.rawValue)-44444444-4444-4444-4444-444444444444.partial",
                isDirectory: true
            )
            try FileManager.default.copyItem(
                at: fixture.root.appendingPathComponent(
                    "profile/revisions/\(mutation.intendedRevisionID.rawValue)",
                    isDirectory: true
                ),
                to: mismatched
            )
            try Data(String(repeating: "0", count: 64).utf8).write(
                to: mismatched.appendingPathComponent("revision.sha256"),
                options: .atomic
            )

            guard case .readWrite = try fixture.persistence.load(
                fixture.published.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("Healthy Chat did not remain readable") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: shaOnly.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: mismatched.path))
        }
    }

    func testFirstCommittedAcceptOrDiscardMakesOppositeDecisionStale()
        async throws
    {
        try await withTemporaryParent { parent in
            let acceptFirst = try await makePublishedProposalFixture(
                in: parent,
                ordinal: 0
            )
            let acceptMutation = try AcceptProfileProposalMutation(
                library: acceptFirst.scope,
                base: acceptFirst.published,
                proposalID: acceptFirst.proposal.id,
                acceptedAt: try UTCInstant("2026-09-09T12:05:00.000Z")
            )
            let discardAfterAccept = try DiscardProfileProposalMutation(
                library: acceptFirst.scope,
                base: acceptFirst.published,
                proposalID: acceptFirst.proposal.id
            )
            let firstCoordinator = PortableProfileProposalCoordinator(
                persistence: acceptFirst.persistence,
                workspace: acceptFirst.workspace
            )

            guard case .committed = await firstCoordinator.accept(
                acceptMutation
            ) else {
                return XCTFail("First Accept did not commit")
            }
            guard case let .stale(afterAccept) = await firstCoordinator.discard(
                discardAfterAccept
            ) else {
                return XCTFail("Discard after Accept was not stale")
            }
            XCTAssertNil(afterAccept.profileProposal)

            let discardFirst = try await makePublishedProposalFixture(
                in: parent,
                ordinal: 1
            )
            let discardMutation = try DiscardProfileProposalMutation(
                library: discardFirst.scope,
                base: discardFirst.published,
                proposalID: discardFirst.proposal.id
            )
            let acceptAfterDiscard = try AcceptProfileProposalMutation(
                library: discardFirst.scope,
                base: discardFirst.published,
                proposalID: discardFirst.proposal.id,
                acceptedAt: try UTCInstant("2026-09-09T13:05:00.000Z")
            )
            let secondCoordinator = PortableProfileProposalCoordinator(
                persistence: discardFirst.persistence,
                workspace: discardFirst.workspace
            )

            guard case .committed = await secondCoordinator.discard(
                discardMutation
            ) else {
                return XCTFail("First Discard did not commit")
            }
            guard case let .stale(afterDiscard) = await secondCoordinator.accept(
                acceptAfterDiscard
            ) else {
                return XCTFail("Accept after Discard was not stale")
            }
            XCTAssertNil(afterDiscard.profileProposal)
        }
    }

    private struct PortableReconsiderationFixture {
        let root: URL
        let scope: LibraryScope
        let workspace: PortableLibraryWorkspace
        let persistence: PortableChatPersistence
        let observed: ChatAggregate
        let basis: ProfileReconsiderationBasis
        let reconsideration: ProfileReconsideration
        let request: NewProfileReconsiderationInvocationRequest
    }

    private func makePortableReconsiderationFixture(
        in parent: URL
    ) async throws -> PortableReconsiderationFixture {
        let source = try await makePublishedTargetProposalFixture(in: parent)
        let latestTarget = try ProfileStatement(
            statementID: source.source.target.statementID,
            statementKind: source.source.target.statementKind,
            wording: "Pause after each complete thought.",
            supportingSessionCount:
                source.source.target.supportingSessionCount,
            evidence: source.source.target.evidence
        )
        let latest = try ProfileRevision(
            revisionID: ProfileRevisionID(
                "prf-20260910T140000000Z-9ABC"
            ),
            parentRevisionID: source.source.baseRevision.revisionID,
            generation: source.source.baseRevision.generation + 1,
            statementGeneration:
                source.source.baseRevision.statementGeneration + 1,
            createdAt: UTCInstant("2026-09-10T14:00:00.000Z"),
            statements: [latestTarget]
        )
        try installProfileRevision(latest, in: source.source)
        let assessment = await PortableProfileProposalCoordinator(
            persistence: source.source.persistence,
            workspace: source.source.workspace
        ).assess(
            try AssessProfileEffectRequest(
                library: source.source.scope,
                base: source.published,
                sourceEffectIdentity: .proposal(source.proposal.id)
            )
        )
        guard case let .stale(observed, basis) = assessment else {
            throw FixtureError.chatMutationDidNotCommit
        }
        let reconsideration = ProfileReconsideration(
            sourceEffect: try XCTUnwrap(observed.profileEffect),
            resultResponsePositionID: try ChatResponsePositionID(
                "rsp-20260910T140001000Z-0DEF"
            )
        )
        let request = try NewProfileReconsiderationInvocationRequest(
            library: source.source.scope,
            observedAggregate: observed,
            reconsideration: reconsideration,
            basis: basis
        )
        return PortableReconsiderationFixture(
            root: source.source.root,
            scope: source.source.scope,
            workspace: source.source.workspace,
            persistence: source.source.persistence,
            observed: observed,
            basis: basis,
            reconsideration: reconsideration,
            request: request
        )
    }

    private func makePortableEvidenceReconsiderationFixture(
        in parent: URL
    ) async throws -> PortableReconsiderationFixture {
        let source = try await makePublishedEvidenceFixture(in: parent)
        let latest = try ProfileRevision(
            revisionID: ProfileRevisionID(
                "prf-20260910T140000000Z-9ABC"
            ),
            parentRevisionID: source.baseRevision.revisionID,
            generation: source.baseRevision.generation + 1,
            statementGeneration: source.baseRevision.statementGeneration + 1,
            createdAt: UTCInstant("2026-09-10T14:00:00.000Z"),
            statements: []
        )
        try installProfileRevision(latest, in: source)
        let assessment = await PortableProfileProposalCoordinator(
            persistence: source.persistence,
            workspace: source.workspace
        ).assess(
            try AssessProfileEffectRequest(
                library: source.scope,
                base: source.published,
                sourceEffectIdentity: .evidencePublication(
                    source.profilePublication.responsePositionID
                )
            )
        )
        guard case let .stale(observed, basis) = assessment else {
            throw FixtureError.chatMutationDidNotCommit
        }
        let reconsideration = ProfileReconsideration(
            sourceEffect: try XCTUnwrap(observed.profileEffect),
            resultResponsePositionID: try ChatResponsePositionID(
                "rsp-20260910T140001000Z-0DEF"
            )
        )
        let request = try NewProfileReconsiderationInvocationRequest(
            library: source.scope,
            observedAggregate: observed,
            reconsideration: reconsideration,
            basis: basis
        )
        return PortableReconsiderationFixture(
            root: source.root,
            scope: source.scope,
            workspace: source.workspace,
            persistence: source.persistence,
            observed: observed,
            basis: basis,
            reconsideration: reconsideration,
            request: request
        )
    }

    private func assertRelaunchFinishesReplacementAfterCanonicalInstall(
        _ fixture: PortableReconsiderationFixture
    ) throws {
        let installFault = OneShot()
        let persistence = PortableChatPersistence { point in
            if point == .afterReconsiderationReplacementProposalCommitInstall,
               installFault.take()
            {
                throw PortableChatPersistenceError.injectedFault(point)
            }
        }
        guard case let .prepared(authority, lease) = try persistence
            .prepareNewProfileReconsiderationInvocation(
                fixture.request,
                at: fixture.root,
                in: fixture.scope
            )
        else { return XCTFail("Reconsider reservation did not open") }
        let install = try makeReconsiderationInstall(
            authority: authority,
            basis: fixture.basis
        )
        guard case .installed = try persistence
            .installProfileReconsiderationInvocation(
                install,
                at: fixture.root,
                holding: lease
            )
        else { return XCTFail("Reconsider Invocation did not install") }
        let response = replacementReconsiderationResponse()
        let mutation = try PublishProfileReconsiderationInvocationMutation(
            base: install.processingAggregate,
            invocation: install.invocation,
            reconsideration: install.processingReconsideration,
            basis: authority.basis,
            validatedResponse: response,
            replacementMemory: nil,
            completedAt: UTCInstant("2026-09-10T14:00:03.000Z")
        )
        XCTAssertThrowsError(
            try persistence.publishProfileReconsideration(
                mutation,
                at: fixture.root,
                in: fixture.scope,
                holding: lease
            )
        )
        lease.release() // Simulates kernel liveness loss at process death.
        XCTAssertTrue(installFault.wasTaken)

        try persistence.reconcileInterruptedInvocations(
            at: fixture.root,
            in: fixture.scope
        )
        guard case let .readWrite(recovered) = try persistence.load(
            fixture.observed.chat.id,
            at: fixture.root,
            in: fixture.scope
        ) else { return XCTFail("Committed replacement did not reload") }
        XCTAssertEqual(recovered, mutation.replacement)
        XCTAssertNil(recovered.profileEvidencePublication)
        XCTAssertNil(recovered.profileReconsideration)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(
                "invocations/\(install.invocation.id.rawValue)"
            ).path
        ))
    }

    private func replacementReconsiderationResponse() -> ValidatedCoachResponse {
        ValidatedCoachResponse(
            messageBlocks: [],
            newMemory: nil,
            proposedProfileEdits: [
                ValidatedCoachProfileEditProposal(
                    edit: .add(
                        statementKind: .goal,
                        wording: "Use one deliberate pause between ideas."
                    ),
                    evidence: []
                ),
            ],
            appendedProfileEvidence: [],
            profileEffectPublicationMode: .reviewRequired
        )
    }

    private func makeReconsiderationInstall(
        authority: InvocationProfileReconsiderationAuthority,
        basis: ProfileReconsiderationBasis
    ) throws -> InstallProfileReconsiderationInvocationMutation {
        try InstallProfileReconsiderationInvocationMutation(
            authority: authority,
            identity: InvocationProfileReconsiderationLaunchIdentity(
                invocationID: try CoachInvocationID(
                    "inv-20260910T140002000Z-1ABC"
                ),
                attemptIdentity: InvocationProfileReconsiderationAttemptIdentity(
                    attemptID: try CoachProviderAttemptID(
                        "atm-20260910T140002000Z-2DEF"
                    ),
                    idempotencyValue: try ProviderIdempotencyValue(
                        "portable-reconsider-attempt"
                    ),
                    coachMessageID: try ChatMessageID(
                        "msg-20260910T140002000Z-3GHJ"
                    )
                )
            ),
            preparedProfile: basis.latestProfile.provenance,
            admittedAt: UTCInstant("2026-09-10T14:00:02.000Z")
        )
    }

    private func relaunchedWorkspace(
        root: URL
    ) async throws -> PortableLibraryWorkspace {
        let workspace = PortableLibraryWorkspace(
            locations: QueueLocations(existing: [root]),
            bookmarks: SyntheticBookmarks(),
            access: RecordingAccessGrantor(),
            locatorStore: MemoryLocatorStore(),
            revealer: RecordingRevealer()
        )
        guard case .opened = await workspace.chooseLibrary() else {
            throw FixtureError.workspaceDidNotOpen
        }
        return workspace
    }

    private struct PublishedTargetProposalFixture {
        let source: PublishedEvidenceFixture
        let proposal: ProfileChangeProposal
        let published: ChatAggregate
    }

    private func makePublishedTargetProposalFixture(
        in parent: URL
    ) async throws -> PublishedTargetProposalFixture {
        let source = try await makePublishedEvidenceFixture(in: parent)
        let replacement = try ProfileProposedStatement(
            statementID: ProfileStatementID(
                "stm-20260910T120004000Z-5VWX"
            ),
            statementKind: source.target.statementKind,
            wording: "Pause after every complete idea.",
            evidence: source.target.evidence
        )
        let proposal = try ProfileChangeProposal(
            id: ProfileChangeProposalID("prp-20260910T120004000Z-6XYZ"),
            chatID: source.published.chat.id,
            responsePositionID: source.profilePublication.responsePositionID,
            baseProfile: ProfileSnapshot(
                revision: source.baseRevision
            ).provenance,
            changes: [
                .replace(
                    target: ProfileProposalTarget(statement: source.target),
                    replacement: replacement
                ),
            ],
            createdAt: source.profilePublication.createdAt
        )
        let root = chatRoot(source)
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("profile-publication.json")
        )
        try source.persistence.encodeProfileProposal(proposal).write(
            to: root.appendingPathComponent("proposal.json"),
            options: .atomic
        )
        guard case let .readWrite(published) = try source.persistence.load(
            source.published.chat.id,
            at: source.root,
            in: source.scope
        ) else { throw FixtureError.chatMutationDidNotCommit }
        return PublishedTargetProposalFixture(
            source: source,
            proposal: proposal,
            published: published
        )
    }

    private struct PublishedEvidenceFixture {
        let root: URL
        let scope: LibraryScope
        let workspace: PortableLibraryWorkspace
        let persistence: PortableChatPersistence
        let publication: PublishCoachInvocationMutation
        let profilePublication: ProfileEvidencePublication
        let target: ProfileStatement
        let appendedEvidence: EvidenceReference
        let baseRevision: ProfileRevision
        let published: ChatAggregate
    }

    private struct PublishedEvidenceOnlyProposalFixture {
        let source: PublishedEvidenceFixture
        let proposal: ProfileChangeProposal
        let published: ChatAggregate
    }

    private func makePublishedEvidenceOnlyProposalFixture(
        in parent: URL
    ) async throws -> PublishedEvidenceOnlyProposalFixture {
        let source = try await makePublishedEvidenceFixture(in: parent)
        let proposal = try ProfileChangeProposal.reconsidered(
            id: ProfileChangeProposalID("prp-20260910T150000000Z-1ABC"),
            chatID: source.published.chat.id,
            responsePositionID: source.profilePublication.responsePositionID,
            baseProfile: ProfileSnapshot(
                revision: source.baseRevision
            ).provenance,
            changes: [],
            evidenceAppends: source.profilePublication.evidenceAppends,
            createdAt: UTCInstant("2026-09-10T15:00:00.000Z")
        )
        let root = chatRoot(source)
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("profile-publication.json")
        )
        try source.persistence.encodeProfileProposal(proposal).write(
            to: root.appendingPathComponent("proposal.json"),
            options: .atomic
        )
        guard case let .readWrite(published) = try source.persistence.load(
            source.published.chat.id,
            at: source.root,
            in: source.scope
        ) else { throw FixtureError.chatMutationDidNotCommit }
        return PublishedEvidenceOnlyProposalFixture(
            source: source,
            proposal: proposal,
            published: published
        )
    }

    private func makePublishedEvidenceFixture(
        in parent: URL,
        existingEvidence: Bool = false
    ) async throws -> PublishedEvidenceFixture {
        let root = parent.appendingPathComponent(
            "ProfileEvidencePublication.audoralibrary",
            isDirectory: true
        )
        let libraryID = try LibraryID("lib-20260910T115900000Z-1ABC")
        _ = try PortableLibraryPersistence().create(
            at: root,
            seed: makeSeed(id: libraryID.rawValue)
        )
        let scope = LibraryScope(libraryID: libraryID)
        let attachment = try await installRecordedChatAttachmentFixture(
            at: root,
            in: scope
        )
        let appendedEvidence = try EvidenceReference(
            sessionID: attachment.sessionID,
            transcriptRevisionID: attachment.transcriptRevisionID,
            target: .wordRange(
                startWordID: TranscriptWordID("w000000"),
                endWordID: TranscriptWordID("w000000")
            ),
            display: EvidenceReferenceDisplay(
                sessionLabel: "Planning reflection",
                trustedText: "Hi",
                startMilliseconds: 0,
                endMilliseconds: 1
            )
        )
        let target = try ProfileStatement(
            statementID: ProfileStatementID(
                "stm-20260910T110000000Z-2DEF"
            ),
            statementKind: .speakingObservation,
            wording: "Pause briefly between points.",
            supportingSessionCount: existingEvidence ? 1 : 0,
            evidence: existingEvidence ? [appendedEvidence] : []
        )
        let baseRevision = try ProfileRevision(
            revisionID: ProfileRevisionID("prf-20260910T110100000Z-3GHJ"),
            parentRevisionID: nil,
            generation: 1,
            statementGeneration: 1,
            createdAt: UTCInstant("2026-09-10T11:01:00.000Z"),
            statements: [target]
        )
        let persistence = PortableChatPersistence()
        _ = try installProfileRevision(
            baseRevision,
            at: root,
            persistence: persistence
        )
        let workspace = PortableLibraryWorkspace(
            locations: QueueLocations(existing: [root]),
            bookmarks: SyntheticBookmarks(),
            access: RecordingAccessGrantor(),
            locatorStore: MemoryLocatorStore(),
            revealer: RecordingRevealer()
        )
        guard case .opened = await workspace.chooseLibrary() else {
            throw FixtureError.workspaceDidNotOpen
        }
        let attachments = try ChatAttachments(validating: [attachment])
        let created = try persistence.create(
            NewChatSeed(
                library: scope,
                chatID: ChatID("cht-20260910T120000000Z-4KMN"),
                draftID: ChatDraftID("drf-20260910T120000000Z-5PQR"),
                memoryID: CoachMemoryID("mem-20260910T120000000Z-6RST"),
                instant: UTCInstant("2026-09-10T12:00:00.000Z"),
                profileStatementGeneration: 1,
                attachments: attachments
            ),
            at: root
        )
        let editedDraft = try created.chat.draft.edited(
            text: "Keep the exact supporting evidence.",
            at: UTCInstant("2026-09-10T12:00:00.500Z")
        )
        guard case let .committed(drafted) = try persistence.saveDraft(
            SaveChatDraftMutation(
                library: scope,
                chatID: created.chat.id,
                replacement: editedDraft
            ),
            at: root
        ) else { throw FixtureError.chatMutationDidNotCommit }
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260910T120001000Z-7VWX"),
            draftID: drafted.chat.draft.draftID,
            draftVersion: drafted.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260910T120001000Z-8XYZ"
            )
        )
        guard case let .committed(locked) = try persistence.lockPendingUserTurn(
            LockPendingUserTurnMutation(
                library: scope,
                chatID: drafted.chat.id,
                pendingUserTurn: pending
            ),
            at: root
        ) else { throw FixtureError.chatMutationDidNotCommit }
        let request = PendingCoachInvocationRequest(
            library: scope,
            chatID: locked.chat.id,
            pendingUserTurnID: pending.id
        )
        let identity = InvocationLaunchIdentity(
            invocationID: try CoachInvocationID(
                "inv-20260910T120002000Z-9ABC"
            ),
            attemptID: try CoachProviderAttemptID(
                "atm-20260910T120002000Z-1DEF"
            ),
            idempotencyValue: try ProviderIdempotencyValue(
                "synthetic-profile-evidence-publication"
            ),
            userMessageID: try ChatMessageID(
                "msg-20260910T120003000Z-2GHJ"
            ),
            coachMessageID: try ChatMessageID(
                "msg-20260910T120003000Z-3KMN"
            ),
            freshDraftID: try ChatDraftID(
                "drf-20260910T120003000Z-4PQR"
            )
        )
        let preparedProfile = CoachProfileProvenance(
            revisionID: baseRevision.revisionID,
            statementGeneration: baseRevision.statementGeneration
        )
        let install = try InstallCoachInvocationMutation(
            authority: InvocationPendingAuthority(
                request: request,
                aggregate: locked
            ),
            identity: identity,
            preparedProfile: preparedProfile,
            admittedAt: UTCInstant("2026-09-10T12:00:02.000Z")
        )
        guard case .installed = try persistence.installInvocation(
            install,
            at: root
        ) else { throw FixtureError.invocationDidNotInstall }
        let profilePublication = try ProfileEvidencePublication(
            chatID: locked.chat.id,
            responsePositionID: pending.responsePositionID,
            evidenceAppends: [
                ProfileEvidenceAppend(
                    target: ProfileProposalTarget(statement: target),
                    evidence: [appendedEvidence]
                ),
            ],
            createdAt: UTCInstant("2026-09-10T12:00:03.000Z")
        )
        let publication = try PublishCoachInvocationMutation(
            base: install.processingAggregate,
            invocation: install.invocation,
            coachBlocks: [.markdown("A complete synthetic Coach response.")],
            profileEvidencePublication: profilePublication,
            completedAt: profilePublication.createdAt
        )
        guard case let .committed(published) = try persistence.publishInvocation(
            publication,
            at: root,
            in: scope
        ) else { throw FixtureError.invocationDidNotPublish }
        return PublishedEvidenceFixture(
            root: root,
            scope: scope,
            workspace: workspace,
            persistence: persistence,
            publication: publication,
            profilePublication: profilePublication,
            target: target,
            appendedEvidence: appendedEvidence,
            baseRevision: baseRevision,
            published: published
        )
    }

    private func makeConcurrentEvidenceRevision(
        in fixture: PublishedEvidenceFixture
    ) throws -> ProfileRevision {
        let concurrentEvidence = try EvidenceReference(
            sessionID: SessionID("ses-20260910T125000000Z-5RST"),
            transcriptRevisionID: TranscriptRevisionID(
                "trv-20260910T125100000Z-6VWX"
            ),
            target: .wordRange(
                startWordID: TranscriptWordID("w000010"),
                endWordID: TranscriptWordID("w000010")
            ),
            display: EvidenceReferenceDisplay(
                sessionLabel: "Concurrent reflection",
                trustedText: "Pause",
                startMilliseconds: 10,
                endMilliseconds: 20
            )
        )
        let statement = try ProfileStatement(
            statementID: fixture.target.statementID,
            statementKind: fixture.target.statementKind,
            wording: fixture.target.wording,
            supportingSessionCount: fixture.target.evidence.isEmpty ? 1 : 2,
            evidence: fixture.target.evidence + [concurrentEvidence]
        )
        return try ProfileRevision(
            revisionID: ProfileRevisionID("prf-20260910T125200000Z-7XYZ"),
            parentRevisionID: fixture.baseRevision.revisionID,
            generation: 2,
            statementGeneration: 1,
            createdAt: UTCInstant("2026-09-10T12:52:00.000Z"),
            statements: [statement]
        )
    }

    @discardableResult
    private func installProfileRevision(
        _ revision: ProfileRevision,
        in fixture: PublishedEvidenceFixture
    ) throws -> ProfileHead {
        try installProfileRevision(
            revision,
            at: fixture.root,
            persistence: fixture.persistence
        )
    }

    @discardableResult
    private func installProfileRevision(
        _ revision: ProfileRevision,
        at root: URL,
        persistence: PortableChatPersistence
    ) throws -> ProfileHead {
        let data = try persistence.encodeProfileRevision(revision)
        let digest = sha256(data)
        let revisionRoot = root.appendingPathComponent(
            "profile/revisions/\(revision.revisionID.rawValue)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: revisionRoot,
            withIntermediateDirectories: false
        )
        try data.write(to: revisionRoot.appendingPathComponent("revision.json"))
        try Data(digest.utf8).write(
            to: revisionRoot.appendingPathComponent("revision.sha256")
        )
        let head = ProfileHead(
            generation: revision.generation,
            statementGeneration: revision.statementGeneration,
            selection: .revision(
                try ProfileRevisionPointer(
                    revisionID: revision.revisionID,
                    sha256: digest
                )
            ),
            updatedAt: revision.createdAt
        )
        let library = PortableLibraryPersistence()
        try library.atomicallyReplaceRootForTesting(
            library.encodeProfileHead(head),
            relativePath: LibraryRelativePath("profile/head.json"),
            under: root
        )
        return head
    }

    private struct PublishedProposalFixture {
        let root: URL
        let scope: LibraryScope
        let workspace: PortableLibraryWorkspace
        let persistence: PortableChatPersistence
        let publication: PublishCoachInvocationMutation
        let proposal: ProfileChangeProposal
        let proposedStatement: ProfileProposedStatement
        let published: ChatAggregate
    }

    private enum FixtureError: Error {
        case chatMutationDidNotCommit
        case invocationDidNotInstall
        case invocationDidNotPublish
        case workspaceDidNotOpen
    }

    private func makePublishedProposalFixture(
        in parent: URL,
        ordinal: Int = 0
    ) async throws -> PublishedProposalFixture {
        let hour = ordinal == 0 ? "12" : "13"
        let root = parent.appendingPathComponent(
            "ProfileProposal-\(ordinal).audoralibrary",
            isDirectory: true
        )
        let libraryID = try LibraryID(
            ordinal == 0
                ? "lib-20260909T115900000Z-1ABC"
                : "lib-20260909T125900000Z-2DEF"
        )
        _ = try PortableLibraryPersistence().create(
            at: root,
            seed: makeSeed(id: libraryID.rawValue)
        )
        let scope = LibraryScope(libraryID: libraryID)
        let workspace = PortableLibraryWorkspace(
            locations: QueueLocations(existing: [root]),
            bookmarks: SyntheticBookmarks(),
            access: RecordingAccessGrantor(),
            locatorStore: MemoryLocatorStore(),
            revealer: RecordingRevealer()
        )
        guard case .opened = await workspace.chooseLibrary() else {
            throw FixtureError.workspaceDidNotOpen
        }

        let persistence = PortableChatPersistence()
        let created = try persistence.create(
            makeChatSeed(scope: scope),
            at: root
        )
        let editedDraft = try created.chat.draft.edited(
            text: "Please remember this exact synthetic coaching result.",
            at: UTCInstant("2026-09-09T\(hour):00:00.500Z")
        )
        guard case let .committed(drafted) = try persistence.saveDraft(
            SaveChatDraftMutation(
                library: scope,
                chatID: created.chat.id,
                replacement: editedDraft
            ),
            at: root
        ) else {
            throw FixtureError.chatMutationDidNotCommit
        }
        let pending = PendingUserTurn(
            id: try PendingUserTurnID(
                "ptu-20260909T\(hour)0001000Z-3GHJ"
            ),
            draftID: drafted.chat.draft.draftID,
            draftVersion: drafted.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260909T\(hour)0001000Z-4KMN"
            )
        )
        guard case let .committed(locked) = try persistence.lockPendingUserTurn(
            LockPendingUserTurnMutation(
                library: scope,
                chatID: drafted.chat.id,
                pendingUserTurn: pending
            ),
            at: root
        ) else {
            throw FixtureError.chatMutationDidNotCommit
        }
        let request = PendingCoachInvocationRequest(
            library: scope,
            chatID: locked.chat.id,
            pendingUserTurnID: pending.id
        )
        let authority = try InvocationPendingAuthority(
            request: request,
            aggregate: locked
        )
        let identity = InvocationLaunchIdentity(
            invocationID: try CoachInvocationID(
                "inv-20260909T\(hour)0002000Z-5PQR"
            ),
            attemptID: try CoachProviderAttemptID(
                "atm-20260909T\(hour)0002000Z-6RST"
            ),
            idempotencyValue: try ProviderIdempotencyValue(
                "synthetic-profile-proposal-\(ordinal)"
            ),
            userMessageID: try ChatMessageID(
                "msg-20260909T\(hour)0003000Z-7VWX"
            ),
            coachMessageID: try ChatMessageID(
                "msg-20260909T\(hour)0003000Z-8XYZ"
            ),
            freshDraftID: try ChatDraftID(
                "drf-20260909T\(hour)0003000Z-9ABC"
            )
        )
        let profile = CoachProfileProvenance(
            revisionID: nil,
            statementGeneration: 0
        )
        let install = try InstallCoachInvocationMutation(
            authority: authority,
            identity: identity,
            preparedProfile: profile,
            admittedAt: UTCInstant("2026-09-09T\(hour):00:02.000Z")
        )
        guard case .installed = try persistence.installInvocation(
            install,
            at: root
        ) else {
            throw FixtureError.invocationDidNotInstall
        }

        let proposedStatement = try ProfileProposedStatement(
            statementID: ProfileStatementID(
                "stm-20260909T\(hour)0003000Z-9DEF"
            ),
            statementKind: .goal,
            wording: "Pause after each main idea.",
            evidence: []
        )
        let proposal = try ProfileChangeProposal(
            id: ProfileChangeProposalID(
                "prp-20260909T\(hour)0003000Z-8XYZ"
            ),
            chatID: locked.chat.id,
            responsePositionID: pending.responsePositionID,
            baseProfile: profile,
            changes: [.add(statement: proposedStatement)],
            createdAt: UTCInstant("2026-09-09T\(hour):00:03.000Z")
        )
        let replacementMemory = try CoachMemory(
            memoryID: CoachMemoryID(
                "mem-20260909T\(hour)0003000Z-1ABC"
            ),
            chatID: locked.chat.id,
            generalNotes: "Keep the exact synthetic coaching context.",
            sessionSummaries: [],
            attachments: locked.chat.attachments
        )
        let publication = try PublishCoachInvocationMutation(
            base: install.processingAggregate,
            invocation: install.invocation,
            coachBlocks: [.markdown("A complete synthetic Coach response.")],
            replacementMemory: replacementMemory,
            profileProposal: proposal,
            completedAt: UTCInstant("2026-09-09T\(hour):00:03.000Z")
        )
        guard case let .committed(published) = try persistence.publishInvocation(
            publication,
            at: root,
            in: scope
        ) else {
            throw FixtureError.invocationDidNotPublish
        }
        return PublishedProposalFixture(
            root: root,
            scope: scope,
            workspace: workspace,
            persistence: persistence,
            publication: publication,
            proposal: proposal,
            proposedStatement: proposedStatement,
            published: published
        )
    }

    private func unchangedDurableBytes(
        in fixture: PublishedProposalFixture
    ) throws -> [String: Data] {
        let chatDirectory = chatRoot(fixture)
        var relativePaths = [
            "chat.json",
            "memory/\(fixture.published.memory.memoryID.rawValue).json",
        ]
        relativePaths += fixture.published.chat.messageIDs.map {
            "messages/\($0.rawValue).json"
        }
        var values = try Dictionary(
            uniqueKeysWithValues: relativePaths.map { path in
                (
                    "chat/\(path)",
                    try Data(
                        contentsOf: chatDirectory.appendingPathComponent(path)
                    )
                )
            }
        )
        values["profile/head.json"] = try Data(
            contentsOf: fixture.root.appendingPathComponent(
                "profile/head.json"
            )
        )
        return values
    }

    private func loadProfileHead(
        in fixture: PublishedProposalFixture
    ) throws -> ProfileHead {
        try PortableLibraryPersistence().decodeProfileHead(
            Data(
                contentsOf: fixture.root.appendingPathComponent(
                    "profile/head.json"
                )
            )
        )
    }

    private func loadProfileHead(
        in fixture: PublishedEvidenceFixture
    ) throws -> ProfileHead {
        try PortableLibraryPersistence().decodeProfileHead(
            Data(
                contentsOf: fixture.root.appendingPathComponent(
                    "profile/head.json"
                )
            )
        )
    }

    private func profileRevisionDirectoryNames(
        in fixture: PublishedProposalFixture
    ) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: fixture.root.appendingPathComponent(
                "profile/revisions"
            ).path
        ).sorted()
    }

    private func profileRevisionDirectoryNames(
        in fixture: PublishedEvidenceFixture
    ) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: fixture.root.appendingPathComponent(
                "profile/revisions"
            ).path
        ).sorted()
    }

    private func profileRevisionURL(
        _ revisionID: ProfileRevisionID,
        in fixture: PublishedProposalFixture
    ) -> URL {
        fixture.root.appendingPathComponent(
            "profile/revisions/\(revisionID.rawValue)/revision.json"
        )
    }

    private func profileRevisionURL(
        _ revisionID: ProfileRevisionID,
        in fixture: PublishedEvidenceFixture
    ) -> URL {
        fixture.root.appendingPathComponent(
            "profile/revisions/\(revisionID.rawValue)/revision.json"
        )
    }

    private func chatRoot(_ fixture: PublishedProposalFixture) -> URL {
        fixture.root.appendingPathComponent(
            "chats/\(fixture.published.chat.id.rawValue)",
            isDirectory: true
        )
    }

    private func chatRoot(_ fixture: PublishedEvidenceFixture) -> URL {
        fixture.root.appendingPathComponent(
            "chats/\(fixture.published.chat.id.rawValue)",
            isDirectory: true
        )
    }

    private func fileExists(_ root: URL, _ relativePath: String) -> Bool {
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent(relativePath).path
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
