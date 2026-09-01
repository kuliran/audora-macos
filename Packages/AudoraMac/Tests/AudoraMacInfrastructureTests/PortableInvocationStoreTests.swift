@_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
@testable @_spi(InvocationInfrastructure) import AudoraMacInfrastructure
import Darwin
import Foundation
import XCTest

private enum TestInvocationReservationOutcome: Equatable {
    case none
    case exists
    case ineligible
    case unavailable
}

private extension PortableInvocationStore {
    func reserveInvocation(
        _ request: PendingCoachInvocationRequest
    ) async -> TestInvocationReservationOutcome {
        switch await acquirePendingInvocation(request) {
        case .acquired: .none
        case .activeExists: .exists
        case .ineligible: .ineligible
        case .unavailable: .unavailable
        }
    }
}

final class PortableInvocationStoreTests: XCTestCase {
    func testRelaunchRollsBackEveryPrecommitPublicationCrashToRetryablePending() async throws {
        let cases: [(PortableChatFaultPoint, String)] = [
            (.afterPublicationProofInstall, "lib-20260830T120000000Z-2ABC"),
            (.afterPublicationProofDirectoryFlush, "lib-20260830T120000000Z-3DEF"),
            (.afterUserMessageInstall, "lib-20260830T120000000Z-4GHJ"),
            (.afterCoachMessageInstall, "lib-20260830T120000000Z-5KMN"),
            (.afterPublicationManifestFileFlush, "lib-20260830T120000000Z-6PQR"),
        ]

        try await withTemporaryParent { parent in
            for (index, faultCase) in cases.enumerated() {
                let (point, libraryID) = faultCase
                let caseParent = parent.appendingPathComponent(
                    "precommit-case-\(index)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: caseParent,
                    withIntermediateDirectories: false
                )
                let fixture = try await makeInvocationStoreFixture(
                    in: caseParent,
                    libraryID: libraryID
                )
                let crash = await leavePrecommitPublicationForRelaunch(
                    fixture,
                    at: point
                )
                XCTAssertEqual(crash.outcome, .failed, String(describing: point))
                XCTAssertTrue(
                    crash.publicationFaultReached,
                    "publication fault was not reached: \(point)"
                )
                XCTAssertTrue(
                    crash.reconciliationFaultReached,
                    "immediate reconciliation was not blocked: \(point)"
                )
                XCTAssertTrue(crash.storeReleased, String(describing: point))
                try assertPrecommitPublicationCrashArtifacts(
                    fixture,
                    at: point
                )

                let relaunchedWorkspace = PortableLibraryWorkspace(
                    locations: QueueLocations(existing: [fixture.root]),
                    bookmarks: SyntheticBookmarks(),
                    access: RecordingAccessGrantor(),
                    locatorStore: MemoryLocatorStore(),
                    revealer: RecordingRevealer()
                )
                _ = await relaunchedWorkspace.chooseLibrary()
                let chats = PortableChatStore(workspace: relaunchedWorkspace)
                guard case let .loaded(reopened) = await chats.load(
                    fixture.locked.chat.id,
                    in: fixture.scope
                ) else {
                    XCTFail("precommit crash froze the Chat at \(point)")
                    continue
                }

                try await assertRetryablePrecommitRecovery(
                    reopened,
                    fixture: fixture,
                    workspace: relaunchedWorkspace,
                    label: String(describing: point)
                )
            }
        }
    }

    func testRelaunchRollsBackPrecommitPublicationCASConflictAfterOwnerDeath() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let rename = try RenameChatMutation(
                library: fixture.scope,
                base: fixture.locked,
                title: ChatTitle("Renamed while publishing"),
                updatedAt: UTCInstant("2026-08-30T12:00:02.500Z")
            )
            let crash = await leavePrecommitCASConflictForRelaunch(
                fixture,
                rename: rename
            )
            XCTAssertEqual(crash.outcome, .stale(fixture.locked))
            XCTAssertTrue(crash.conflictReached)
            XCTAssertTrue(crash.storeReleased)
            try assertPrecommitPublicationCrashArtifacts(
                fixture,
                at: .afterPublicationManifestFileFlush
            )

            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let chats = PortableChatStore(workspace: relaunchedWorkspace)
            guard case let .loaded(reopened) = await chats.load(
                fixture.locked.chat.id,
                in: fixture.scope
            ) else {
                return XCTFail("precommit CAS conflict froze the Chat")
            }
            XCTAssertEqual(reopened.chat.title, rename.replacement.chat.title)
            XCTAssertEqual(
                reopened.chat.manifestRevision,
                rename.replacement.chat.manifestRevision
            )

            try await assertRetryablePrecommitRecovery(
                reopened,
                fixture: fixture,
                workspace: relaunchedWorkspace,
                label: "precommit CAS conflict"
            )
        }
    }

    func testPreparedNewPendingIsNeverRecoverableBetweenExactBindingAndHandoff() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let baseline = PortableChatPersistence()
            guard case let .committed(unlocked) = try baseline.discardPendingUserTurn(
                DiscardPendingUserTurnMutation(
                    library: fixture.scope,
                    chatID: fixture.locked.chat.id,
                    pendingUserTurn: fixture.install.authority.pendingUserTurn
                ),
                at: fixture.root
            ) else { return XCTFail("Pending setup did not unlock") }
            guard case .committed = try baseline.discardPendingUserTurn(
                DiscardPendingUserTurnMutation(
                    library: fixture.scope,
                    chatID: fixture.competingAuthority.request.chatID,
                    pendingUserTurn: fixture.competingAuthority.pendingUserTurn
                ),
                at: fixture.root
            ) else { return XCTFail("sibling Pending setup did not unlock") }
            let request = try NewPendingCoachInvocationRequest(
                library: fixture.scope,
                observedAggregate: unlocked,
                pendingUserTurn: fixture.install.authority.pendingUserTurn
            )
            let suspension = SuspendedInvocationAcquisition()
            let owner = PortableInvocationStore(
                persistence: PortableChatPersistence { point in
                    guard point == .afterPendingInvocationAuthorityBound else { return }
                    suspension.suspend()
                },
                workspace: fixture.workspace
            )
            let recoveryWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await recoveryWorkspace.chooseLibrary()
            let recoveringChats = PortableChatStore(workspace: recoveryWorkspace)

            async let preparation = owner.prepareNewPendingInvocation(request)
            await suspension.waitUntilSuspended()

            guard case let .loaded(entries) = await recoveringChats.loadCatalog(
                in: fixture.scope
            ) else {
                suspension.resume()
                return XCTFail("catalog recovery did not load")
            }
            let live = entries.compactMap { entry -> ChatAggregate? in
                guard case let .available(aggregate) = entry,
                      aggregate.chat.id == request.chatID
                else { return nil }
                return aggregate
            }.first
            XCTAssertEqual(live?.pendingUserTurn, request.pendingUserTurn)
            XCTAssertNil(live?.pendingUserTurn?.failure)

            suspension.resume()
            guard case let .prepared(authority) = await preparation else {
                return XCTFail("new Send did not retain its bound authority")
            }
            XCTAssertEqual(authority.aggregate.pendingUserTurn, request.pendingUserTurn)
            XCTAssertNil(authority.pendingUserTurn.failure)
            await owner.cancelInvocationReservation(authority.request)
        }
    }

    func testRecoveryOwnerPreventsPendingInstallAndLeavesDraftUnchanged() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let baseline = PortableChatPersistence()
            guard case let .committed(unlocked) = try baseline.discardPendingUserTurn(
                DiscardPendingUserTurnMutation(
                    library: fixture.scope,
                    chatID: fixture.locked.chat.id,
                    pendingUserTurn: fixture.install.authority.pendingUserTurn
                ),
                at: fixture.root
            ) else { return XCTFail("Pending setup did not unlock") }
            let request = try NewPendingCoachInvocationRequest(
                library: fixture.scope,
                observedAggregate: unlocked,
                pendingUserTurn: fixture.install.authority.pendingUserTurn
            )
            let suspension = SuspendedInvocationAcquisition()
            let recoveryWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await recoveryWorkspace.chooseLibrary()
            let recoveringChats = PortableChatStore(
                persistence: PortableChatPersistence { point in
                    guard point == .beforeInvocationReconciliation else { return }
                    suspension.suspend()
                },
                workspace: recoveryWorkspace
            )
            let owner = PortableInvocationStore(workspace: fixture.workspace)

            async let catalog = recoveringChats.loadCatalog(in: fixture.scope)
            await suspension.waitUntilSuspended()

            let preparation = await owner.prepareNewPendingInvocation(request)
            XCTAssertEqual(
                preparation,
                .activeExists
            )
            guard case let .readWrite(duringRecovery) = try baseline.load(
                request.chatID,
                at: fixture.root,
                in: fixture.scope
            ) else {
                suspension.resume()
                return XCTFail("Chat did not remain readable")
            }
            XCTAssertEqual(duringRecovery, unlocked)

            suspension.resume()
            guard case .loaded = await catalog else {
                return XCTFail("recovery did not finish")
            }
        }
    }

    func testPreparedNewPendingReconcilesEveryPostcommitLockFaultWhileStillOwned() async throws {
        let points: [PortableChatFaultPoint] = [
            .afterPendingInstall,
            .afterPendingDirectoryFlush,
            .beforePendingFinalRead,
            .afterPendingInvocationAuthorityBound,
        ]
        for point in points {
            try await withTemporaryParent { parent in
                let fixture = try await makeInvocationStoreFixture(in: parent)
                let baseline = PortableChatPersistence()
                guard case let .committed(unlocked) = try baseline
                    .discardPendingUserTurn(
                        DiscardPendingUserTurnMutation(
                            library: fixture.scope,
                            chatID: fixture.locked.chat.id,
                            pendingUserTurn: fixture.install.authority.pendingUserTurn
                        ),
                        at: fixture.root
                    ),
                    case .committed = try baseline.discardPendingUserTurn(
                        DiscardPendingUserTurnMutation(
                            library: fixture.scope,
                            chatID: fixture.competingAuthority.request.chatID,
                            pendingUserTurn: fixture.competingAuthority.pendingUserTurn
                        ),
                        at: fixture.root
                    )
                else { return XCTFail("Pending setup did not unlock") }
                let request = try NewPendingCoachInvocationRequest(
                    library: fixture.scope,
                    observedAggregate: unlocked,
                    pendingUserTurn: fixture.install.authority.pendingUserTurn
                )
                let store = PortableInvocationStore(
                    persistence: PortableChatPersistence { reached in
                        if reached == point {
                            throw PortableChatPersistenceError.injectedFault(point)
                        }
                    },
                    workspace: fixture.workspace
                )

                guard case let .prepared(authority) = await store
                    .prepareNewPendingInvocation(request)
                else {
                    return XCTFail("exact committed Pending was lost at \(point)")
                }
                XCTAssertEqual(authority.aggregate.pendingUserTurn, request.pendingUserTurn)
                XCTAssertNil(authority.pendingUserTurn.failure)
                await store.cancelInvocationReservation(authority.request)
            }
        }
    }

    func testCatalogLoadCannotReconcilePendingBetweenAtomicResolutionAndOwnership() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let suspension = SuspendedInvocationAcquisition()
            let persistence = PortableChatPersistence { point in
                guard point == .beforeInvocationReconciliation else { return }
                suspension.suspend()
            }
            let invocations = PortableInvocationStore(
                persistence: persistence,
                workspace: fixture.workspace
            )
            let catalogWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await catalogWorkspace.chooseLibrary()
            let chats = PortableChatStore(workspace: catalogWorkspace)

            async let acquisition = invocations.acquirePendingInvocation(
                fixture.install.authority.request
            )
            await suspension.waitUntilSuspended()

            guard case let .loaded(entries) = await chats.loadCatalog(
                in: fixture.scope
            ) else {
                suspension.resume()
                return XCTFail("catalog did not retain the live Chat")
            }
            let duringAcquisition = entries.compactMap { entry -> ChatAggregate? in
                guard case let .available(aggregate) = entry,
                      aggregate.chat.id == fixture.locked.chat.id
                else { return nil }
                return aggregate
            }.first
            guard let duringAcquisition else {
                suspension.resume()
                return XCTFail("catalog did not retain the live Chat")
            }
            XCTAssertNil(duringAcquisition.pendingUserTurn?.failure)

            suspension.resume()
            let acquired = await acquisition
            XCTAssertEqual(
                acquired,
                .acquired(fixture.install.authority)
            )
        }
    }

    func testIneligibleAtomicAcquisitionReleasesLibraryLivenessAuthority() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            try Data("{}".utf8).write(
                to: fixture.root
                    .appendingPathComponent("chats", isDirectory: true)
                    .appendingPathComponent(
                        fixture.locked.chat.id.rawValue,
                        isDirectory: true
                    )
                    .appendingPathComponent("chat.json"),
                options: .atomic
            )
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)

            let ineligible = await owner.acquirePendingInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(ineligible, .ineligible(nil))
            let acquired = await contender.acquirePendingInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(acquired, .acquired(fixture.competingAuthority))
        }
    }

    func testInterruptedTerminalMutationReleasesLibraryLivenessAuthority() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)
            let acquired = await owner.acquirePendingInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(acquired, .acquired(fixture.install.authority))

            guard case .committed = await owner.markInterruptedNewSend(
                fixture.install.authority
            ) else { return XCTFail("interruption did not persist") }

            let next = await contender.acquirePendingInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(next, .acquired(fixture.competingAuthority))
        }
    }

    func testConcurrentInvocationStoresReserveExactlyOneLibraryLivenessAuthorityBeforeInstall() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let first = PortableInvocationStore(workspace: fixture.workspace)
            let second = PortableInvocationStore(workspace: fixture.workspace)

            async let firstCheck = first.reserveInvocation(
                fixture.install.authority.request
            )
            async let secondCheck = second.reserveInvocation(
                fixture.install.authority.request
            )
            let outcomes = await [firstCheck, secondCheck]

            XCTAssertEqual(outcomes.filter { $0 == .none }.count, 1, "\(outcomes)")
            XCTAssertEqual(outcomes.filter { $0 == .exists }.count, 1, "\(outcomes)")
        }
    }

    func testSecondLiveInvocationStoreCannotReapAnotherStoresActiveInvocation() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let first = PortableInvocationStore(workspace: fixture.workspace)
            let second = PortableInvocationStore(workspace: fixture.workspace)

            let firstCheck = await first.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(firstCheck, .none)
            guard case .installed = await first.installInvocation(fixture.install) else {
                return XCTFail("first store did not install its Invocation")
            }

            let secondCheck = await second.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(secondCheck, .exists)
            XCTAssertTrue(
                try PortableChatPersistence().hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
            guard case let .readWrite(reopened) = try PortableChatPersistence().load(
                fixture.locked.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("live Invocation froze its Chat") }
            XCTAssertEqual(reopened, fixture.locked)
        }
    }

    func testCrossChatReservationReconcilesCrashedInvocationWithItsOwnPendingLease() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            guard case .installed = try PortableChatPersistence().installInvocation(
                fixture.install,
                at: fixture.root
            ) else { return XCTFail("crashed Invocation fixture did not install") }
            let store = PortableInvocationStore(workspace: fixture.workspace)

            let reservation = await store.reserveInvocation(
                fixture.competingAuthority.request
            )

            XCTAssertEqual(reservation, .none)
            guard case let .readWrite(reopened) = try PortableChatPersistence().load(
                fixture.locked.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("recovery froze the interrupted Chat") }
            XCTAssertEqual(
                reopened.pendingUserTurn?.failure,
                .coachResponseInterrupted
            )
            XCTAssertFalse(
                try PortableChatPersistence().hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
            await store.cancelInvocationReservation(
                fixture.competingAuthority.request
            )
        }
    }

    func testIdenticalContenderCannotDiscardPendingWhileWinningProviderIsSuspended() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)

            let winningReservation = await owner.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(winningReservation, .none)
            let competingReservation = await contender.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(competingReservation, .exists)
            guard case .installed = await owner.installInvocation(fixture.install) else {
                return XCTFail("winning store did not install its Invocation")
            }

            let competingRejection = await contender.rejectNewSend(
                fixture.install.authority
            )
            XCTAssertEqual(competingRejection, .stale(fixture.locked))

            guard case let .committed(published) = await owner.publish(
                fixture.publication
            ) else { return XCTFail("winning Invocation did not publish") }
            XCTAssertEqual(published, fixture.publication.replacement)
        }
    }

    func testIdenticalContenderCannotReplacePendingWhileWinningProviderIsSuspended() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)

            let reservation = await owner.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .none)
            guard case .installed = await owner.installInvocation(fixture.install) else {
                return XCTFail("winning store did not install its Invocation")
            }

            let competingReplacement = await contender.markContextCapacityFailure(
                fixture.install.authority
            )
            XCTAssertEqual(competingReplacement, .stale(fixture.locked))

            guard case let .committed(published) = await owner.publish(
                fixture.publication
            ) else { return XCTFail("winning Invocation did not publish") }
            XCTAssertEqual(published, fixture.publication.replacement)
        }
    }

    func testRejectedCompetingRequestDoesNotReleaseWinningRequestLivenessAuthority() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)

            let winningReservation = await owner.reserveInvocation(
                fixture.install.authority.request
            )
            let competingReservation = await owner.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(winningReservation, .none)
            XCTAssertEqual(competingReservation, .exists)
            guard case .committed = await owner.rejectNewSend(fixture.competingAuthority) else {
                return XCTFail("competing request was not rejected")
            }

            let contenderReservation = await contender.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(contenderReservation, .exists)
        }
    }

    func testReservationCancellationReleasesOnlyTheExactPendingRequest() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await owner.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .none)

            await owner.cancelInvocationReservation(
                fixture.competingAuthority.request
            )
            let stillBlocked = await contender.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(stillBlocked, .exists)

            await owner.cancelInvocationReservation(
                fixture.install.authority.request
            )
            let released = await contender.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(released, .none)
        }
    }

    func testInvocationInstallRejectsLibraryRootReplacementAfterReservation() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let store = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await store.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .none)

            let original = parent.appendingPathComponent(
                "Reserved-Library-Root.audoralibrary"
            )
            try FileManager.default.moveItem(at: fixture.root, to: original)
            try FileManager.default.copyItem(at: original, to: fixture.root)

            let outcome = await store.installInvocation(fixture.install)
            XCTAssertEqual(outcome, .failed)
            let cleanup = await store.rejectNewSend(fixture.install.authority)
            XCTAssertEqual(cleanup, .failed)
            XCTAssertFalse(
                try PortableChatPersistence().hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
            guard case let .readWrite(current) = try PortableChatPersistence().load(
                fixture.locked.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("replacement Library did not retain its Chat") }
            XCTAssertEqual(current, fixture.locked)
        }
    }

    func testInvocationPublicationRejectsInvocationsDirectoryReplacement() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let store = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await store.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .none)
            guard case .installed = await store.installInvocation(fixture.install) else {
                return XCTFail("Invocation was not installed")
            }

            let invocations = fixture.root.appendingPathComponent(
                "invocations",
                isDirectory: true
            )
            let ownedInvocations = parent.appendingPathComponent(
                "Reserved-Invocations",
                isDirectory: true
            )
            try FileManager.default.moveItem(at: invocations, to: ownedInvocations)
            try FileManager.default.copyItem(at: ownedInvocations, to: invocations)

            let outcome = await store.publish(fixture.publication)
            XCTAssertEqual(outcome, .failed)
            guard case let .readWrite(current) = try PortableChatPersistence().load(
                fixture.locked.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("replacement Library did not retain its Chat") }
            XCTAssertEqual(current, fixture.locked)
        }
    }

    func testReservedPendingMutationRejectsLibraryRootReplacement() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let store = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await store.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .none)

            let original = parent.appendingPathComponent(
                "Reserved-Pending-Library.audoralibrary"
            )
            try FileManager.default.moveItem(at: fixture.root, to: original)
            try FileManager.default.copyItem(at: original, to: fixture.root)

            let outcome = await store.rejectNewSend(fixture.install.authority)
            XCTAssertEqual(outcome, .failed)
            guard case let .readWrite(current) = try PortableChatPersistence().load(
                fixture.locked.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("replacement Library did not retain its Chat") }
            XCTAssertEqual(current, fixture.locked)
        }
    }

    func testReservationRejectsLibraryRootReplacementBeforeReconciliation() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let original = parent.appendingPathComponent(
                "Reserved-Reconciliation-Library.audoralibrary"
            )
            let persistence = PortableChatPersistence { point in
                guard point == .beforeInvocationReconciliation else { return }
                try FileManager.default.moveItem(at: fixture.root, to: original)
                try FileManager.default.copyItem(at: original, to: fixture.root)
            }
            let store = PortableInvocationStore(
                persistence: persistence,
                workspace: fixture.workspace
            )

            let outcome = await store.reserveInvocation(
                fixture.install.authority.request
            )

            XCTAssertEqual(outcome, .unavailable)
            XCTAssertFalse(
                try PortableChatPersistence().hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
        }
    }

    func testReconciliationRevalidatesLibraryAuthorityAtDestructiveCommit() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            do {
                let crashed = PortableInvocationStore(workspace: fixture.workspace)
                let reservation = await crashed.reserveInvocation(
                    fixture.install.authority.request
                )
                XCTAssertEqual(reservation, .none)
                guard case .installed = await crashed.installInvocation(fixture.install) else {
                    return XCTFail("Invocation was not installed")
                }
            }

            let original = parent.appendingPathComponent(
                "Reserved-Reconciliation-Commit.audoralibrary"
            )
            let oneShot = OneShot()
            let persistence = PortableChatPersistence { point in
                guard point == .beforeInvocationReconciliationCommit,
                      oneShot.take()
                else { return }
                try FileManager.default.moveItem(at: fixture.root, to: original)
                try FileManager.default.copyItem(at: original, to: fixture.root)
            }
            let recovering = PortableInvocationStore(
                persistence: persistence,
                workspace: fixture.workspace
            )

            let outcome = await recovering.reserveInvocation(
                fixture.competingAuthority.request
            )

            XCTAssertEqual(outcome, .unavailable)
            XCTAssertTrue(
                try PortableChatPersistence().hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
            guard case let .readWrite(current) = try PortableChatPersistence().load(
                fixture.locked.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("replacement Library did not retain its Chat") }
            XCTAssertEqual(current, fixture.locked)
        }
    }

    func testAbortRevalidatesLibraryAuthorityBetweenDestructiveCommits() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let original = parent.appendingPathComponent(
                "Reserved-Abort-Commit.audoralibrary"
            )
            let oneShot = OneShot()
            let persistence = PortableChatPersistence { point in
                guard point == .afterInvocationAbortPendingFailureInstall,
                      oneShot.take()
                else { return }
                try FileManager.default.moveItem(at: fixture.root, to: original)
                try FileManager.default.copyItem(at: original, to: fixture.root)
            }
            let store = PortableInvocationStore(
                persistence: persistence,
                workspace: fixture.workspace
            )
            let reservation = await store.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .none)
            guard case let .installed(invocation) = await store.installInvocation(
                fixture.install
            ) else { return XCTFail("Invocation was not installed") }

            let outcome = await store.abortInstalledNewSend(invocation)

            XCTAssertEqual(outcome, .failed)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: original
                        .appendingPathComponent("chats", isDirectory: true)
                        .appendingPathComponent(invocation.chatID.rawValue, isDirectory: true)
                        .appendingPathComponent("aborting-invocation.json")
                        .path
                ),
                "the detached Library must not receive a second destructive commit"
            )
        }
    }

    func testLibraryLoadReconcilesCrashedInvocationBeforeAnyNewReservation() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            weak var releasedStore: PortableInvocationStore?
            do {
                let store = PortableInvocationStore(workspace: fixture.workspace)
                releasedStore = store
                let reservation = await store.reserveInvocation(
                    fixture.install.authority.request
                )
                XCTAssertEqual(reservation, .none)
                guard case .installed = await store.installInvocation(fixture.install) else {
                    return XCTFail("Invocation was not installed")
                }
            }
            for _ in 0 ..< 20 where releasedStore != nil {
                await Task.yield()
            }
            XCTAssertNil(releasedStore)

            let relaunched = PortableChatStore(workspace: fixture.workspace)
            guard case let .loaded(reopened) = await relaunched.load(
                fixture.locked.chat.id,
                in: fixture.scope
            ) else { return XCTFail("reconciled Chat was unavailable") }
            XCTAssertFalse(
                try PortableChatPersistence().hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
            XCTAssertEqual(
                reopened.pendingUserTurn?.failure,
                .coachResponseInterrupted
            )
            XCTAssertEqual(reopened.chat.draft, fixture.locked.chat.draft)
            XCTAssertEqual(reopened.chat.messageIDs, [])
        }
    }

    func testLibraryLoadReconcilesPreinstallCrashToRetryablePendingIntent() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            XCTAssertFalse(
                try PortableChatPersistence().hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
            let persistence = PortableChatPersistence()
            let competing = fixture.competingAuthority.pendingUserTurn
            guard case .committed = try persistence.replacePendingUserTurn(
                ReplacePendingUserTurnMutation(
                    library: fixture.scope,
                    chatID: fixture.competingAuthority.request.chatID,
                    base: competing,
                    replacement: competing.replacingFailure(
                        .coachContextCannotFit
                    )
                ),
                at: fixture.root
            ) else { return XCTFail("failed to install existing recovery state") }

            let relaunched = PortableChatStore(workspace: fixture.workspace)
            guard case let .loaded(reopened) = await relaunched.load(
                fixture.locked.chat.id,
                in: fixture.scope
            ) else { return XCTFail("reconciled Chat was unavailable") }

            XCTAssertEqual(reopened.pendingUserTurn?.id, fixture.locked.pendingUserTurn?.id)
            XCTAssertEqual(
                reopened.pendingUserTurn?.failure,
                .coachResponseInterrupted
            )
            XCTAssertEqual(reopened.chat.draft, fixture.locked.chat.draft)
            XCTAssertEqual(reopened.chat.messageIDs, [])
            guard case let .readWrite(competingReopened) = try persistence.load(
                fixture.competingAuthority.request.chatID,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("existing recovery Chat did not reopen") }
            XCTAssertEqual(
                competingReopened.pendingUserTurn?.failure,
                .coachContextCannotFit
            )
        }
    }

    func testCatalogReconcilesHealthyPreinstallPendingWhenSiblingChatIsCorrupt() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let corruptChatID = fixture.competingAuthority.request.chatID
            try Data("not-json".utf8).write(
                to: fixture.root
                    .appendingPathComponent("chats", isDirectory: true)
                    .appendingPathComponent(corruptChatID.rawValue, isDirectory: true)
                    .appendingPathComponent("chat.json")
            )

            let relaunched = PortableChatStore(workspace: fixture.workspace)
            guard case let .loaded(entries) = await relaunched.loadCatalog(
                in: fixture.scope
            ) else { return XCTFail("one corrupt Chat must not fail the catalog") }

            XCTAssertEqual(entries.count, 2)
            XCTAssertTrue(entries.contains(.frozen(
                FrozenChatSnapshot(chatID: corruptChatID, reason: .corrupt)
            )))
            guard let healthy = entries.compactMap({ entry -> ChatAggregate? in
                guard case let .available(aggregate) = entry,
                      aggregate.chat.id == fixture.locked.chat.id
                else { return nil }
                return aggregate
            }).first else { return XCTFail("healthy sibling was hidden") }
            XCTAssertEqual(healthy.pendingUserTurn?.failure, .coachResponseInterrupted)
            XCTAssertEqual(healthy.chat.draft, fixture.locked.chat.draft)
            XCTAssertEqual(healthy.chat.messageIDs, [])
        }
    }

    func testCatalogReconcilesHealthyPendingWhenSiblingHasMalformedDomainIdentity() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let malformedChatID = fixture.competingAuthority.request.chatID
            let manifest = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(malformedChatID.rawValue, isDirectory: true)
                .appendingPathComponent("chat.json")
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: manifest)
                ) as? [String: Any]
            )
            object["messageIds"] = ["not-a-message-id"]
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ).write(to: manifest)

            let relaunched = PortableChatStore(workspace: fixture.workspace)
            guard case let .loaded(entries) = await relaunched.loadCatalog(
                in: fixture.scope
            ) else { return XCTFail("malformed sibling identity must remain isolated") }

            XCTAssertTrue(entries.contains(.frozen(
                FrozenChatSnapshot(chatID: malformedChatID, reason: .corrupt)
            )))
            let healthy = entries.compactMap { entry -> ChatAggregate? in
                guard case let .available(aggregate) = entry,
                      aggregate.chat.id == fixture.locked.chat.id
                else { return nil }
                return aggregate
            }.first
            XCTAssertEqual(
                healthy?.pendingUserTurn?.failure,
                .coachResponseInterrupted
            )
        }
    }

    func testInvocationGatewayAcquisitionDoesNotMisclassifyItsLivePendingAsCrashed() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let store = PortableInvocationStore(workspace: fixture.workspace)

            let resolution = await store.acquirePendingInvocation(
                fixture.install.authority.request
            )

            XCTAssertEqual(resolution, .acquired(fixture.install.authority))
            guard case let .readWrite(reopened) = try PortableChatPersistence().load(
                fixture.locked.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("live Pending did not reopen") }
            XCTAssertNil(reopened.pendingUserTurn?.failure)
            await store.cancelInvocationReservation(
                fixture.install.authority.request
            )
        }
    }

    func testPendingRejectionReleasesLibraryLivenessAuthority() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await owner.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .none)
            guard case .committed = await owner.rejectNewSend(
                fixture.install.authority
            ) else { return XCTFail("Pending User Turn was not rejected") }

            let next = await contender.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(next, .none)
        }
    }

    func testFailedInstallKeepsLivenessUntilItsPendingTerminalMutation() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let persistence = PortableChatPersistence { point in
                guard point == .beforeInvocationPartialWrite else { return }
                throw PortableChatPersistenceError.injectedFault(point)
            }
            let owner = PortableInvocationStore(
                persistence: persistence,
                workspace: fixture.workspace
            )
            let contender = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await owner.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .none)
            let install = await owner.installInvocation(fixture.install)
            XCTAssertEqual(install, .failed)

            let blocked = await contender.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(blocked, .exists)
            guard case .committed = await owner.rejectNewSend(
                fixture.install.authority
            ) else { return XCTFail("failed Invocation did not terminate") }
            let released = await contender.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(released, .none)
        }
    }

    func testContextCapacityFailureReleasesLibraryLivenessAuthority() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await owner.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .none)
            guard case .committed = await owner.markContextCapacityFailure(
                fixture.install.authority
            ) else { return XCTFail("capacity failure was not persisted") }

            let next = await contender.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(next, .none)
        }
    }

    func testInvocationAbortReleasesLibraryLivenessAuthority() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await owner.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .none)
            guard case let .installed(invocation) = await owner.installInvocation(
                fixture.install
            ) else { return XCTFail("Invocation was not installed") }
            guard case .committed = await owner.abortInstalledNewSend(invocation) else {
                return XCTFail("Invocation was not aborted")
            }

            let next = await contender.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(next, .none)
        }
    }

    func testLaunchIdentityPreflightOwnsEveryDurableNamespaceIncludingOrphans() async throws {
        for expected in InvocationLaunchIdentityCollision.allCases {
            try await withTemporaryParent { parent in
                let fixture = try await makeInvocationStoreFixture(in: parent)
                let persistence = PortableChatPersistence()
                let store = PortableInvocationStore(
                    persistence: persistence,
                    workspace: fixture.workspace
                )
                let reservation = await store.reserveInvocation(
                    fixture.install.authority.request
                )
                XCTAssertEqual(reservation, .none)
                let candidate = InvocationLaunchIdentity(
                    invocationID: fixture.install.invocation.id,
                    attemptID: fixture.install.invocation.attemptID,
                    idempotencyValue:
                        fixture.install.invocation.providerIdempotencyValue,
                    userMessageID: fixture.publication.userMessage.id,
                    coachMessageID: fixture.publication.coachMessage.id,
                    freshDraftID: expected == .freshDraftID
                        ? fixture.locked.chat.draft.draftID
                        : fixture.publication.freshDraft.draftID
                )
                let invocationsRoot = fixture.root.appendingPathComponent(
                    "invocations",
                    isDirectory: true
                )
                let messagesRoot = fixture.root
                    .appendingPathComponent("chats", isDirectory: true)
                    .appendingPathComponent(
                        fixture.locked.chat.id.rawValue,
                        isDirectory: true
                    )
                    .appendingPathComponent("messages", isDirectory: true)

                switch expected {
                case .invocationID:
                    try FileManager.default.createDirectory(
                        at: invocationsRoot.appendingPathComponent(
                            candidate.invocationID.rawValue,
                            isDirectory: true
                        ),
                        withIntermediateDirectories: false
                    )
                case .attemptID, .providerIdempotencyValue:
                    let alternate = try CoachInvocation(
                        id: CoachInvocationID("inv-20260830T120002000Z-7STV"),
                        attemptID: expected == .attemptID
                            ? candidate.attemptID
                            : CoachProviderAttemptID(
                                "atm-20260830T120002000Z-8WXY"
                            ),
                        providerIdempotencyValue:
                            expected == .providerIdempotencyValue
                            ? candidate.idempotencyValue
                            : ProviderIdempotencyValue("alternate-8WXY"),
                        library: fixture.scope,
                        chatID: fixture.locked.chat.id,
                        pendingUserTurn: fixture.locked.pendingUserTurn!,
                        preparedProfile: fixture.install.invocation.preparedProfile,
                        expectedManifestRevision:
                            fixture.locked.chat.manifestRevision,
                        admittedAt: fixture.install.invocation.admittedAt
                    )
                    let root = invocationsRoot.appendingPathComponent(
                        alternate.id.rawValue,
                        isDirectory: true
                    )
                    try FileManager.default.createDirectory(
                        at: root,
                        withIntermediateDirectories: false
                    )
                    try persistence.encodeInvocation(alternate).write(
                        to: root.appendingPathComponent("invocation.json")
                    )
                case .userMessageID:
                    try persistence.encodeMessage(fixture.publication.userMessage).write(
                        to: messagesRoot.appendingPathComponent(
                            "\(candidate.userMessageID.rawValue).json"
                        )
                    )
                case .coachMessageID:
                    try persistence.encodeMessage(fixture.publication.coachMessage).write(
                        to: messagesRoot.appendingPathComponent(
                            "\(candidate.coachMessageID.rawValue).json"
                        )
                    )
                case .freshDraftID:
                    break
                }

                let availability = await store.checkLaunchIdentity(
                    candidate,
                    for: fixture.install.authority
                )
                XCTAssertEqual(
                    availability,
                    .collision(expected),
                    String(describing: expected)
                )
                await store.cancelInvocationReservation(
                    fixture.install.authority.request
                )
            }
        }
    }

    func testLaunchIdentityPreflightIgnoresUnreadableSiblingAggregate() async throws {
        for corruption in ["corrupt", "newer"] {
            try await withTemporaryParent { parent in
                let fixture = try await makeInvocationStoreFixture(in: parent)
                let persistence = PortableChatPersistence()
                let store = PortableInvocationStore(
                    persistence: persistence,
                    workspace: fixture.workspace
                )
                let reservation = await store.reserveInvocation(
                    fixture.install.authority.request
                )
                XCTAssertEqual(reservation, .none)
                let siblingManifest = fixture.root
                    .appendingPathComponent("chats", isDirectory: true)
                    .appendingPathComponent(
                        fixture.competingAuthority.request.chatID.rawValue,
                        isDirectory: true
                    )
                    .appendingPathComponent("chat.json")
                if corruption == "corrupt" {
                    try Data("not-json".utf8).write(to: siblingManifest)
                } else {
                    var object = try XCTUnwrap(
                        JSONSerialization.jsonObject(
                            with: Data(contentsOf: siblingManifest)
                        ) as? [String: Any]
                    )
                    object["schemaVersion"] = Chat.schemaVersion + 1
                    try JSONSerialization.data(
                        withJSONObject: object,
                        options: [.sortedKeys]
                    ).write(to: siblingManifest)
                }

                let invocation = fixture.install.invocation
                let candidate = InvocationLaunchIdentity(
                    invocationID: invocation.id,
                    attemptID: invocation.attemptID,
                    idempotencyValue: invocation.providerIdempotencyValue,
                    userMessageID: fixture.publication.userMessage.id,
                    coachMessageID: fixture.publication.coachMessage.id,
                    freshDraftID: fixture.publication.freshDraft.draftID
                )

                let availability = await store.checkLaunchIdentity(
                    candidate,
                    for: fixture.install.authority
                )
                XCTAssertEqual(availability, .available, corruption)
                await store.cancelInvocationReservation(
                    fixture.install.authority.request
                )
            }
        }
    }

    func testLaunchIdentityPreflightFailsClosedWhenSiblingNamespaceHasIOFailure() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let persistence = PortableChatPersistence()
            let store = PortableInvocationStore(
                persistence: persistence,
                workspace: fixture.workspace
            )
            let reservation = await store.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .none)
            let candidate = InvocationLaunchIdentity(
                invocationID: fixture.install.invocation.id,
                attemptID: fixture.install.invocation.attemptID,
                idempotencyValue: fixture.install.invocation.providerIdempotencyValue,
                userMessageID: fixture.publication.userMessage.id,
                coachMessageID: fixture.publication.coachMessage.id,
                freshDraftID: fixture.publication.freshDraft.draftID
            )
            let messages = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(
                    fixture.competingAuthority.request.chatID.rawValue,
                    isDirectory: true
                )
                .appendingPathComponent("messages", isDirectory: true)
            let collisionFile = messages.appendingPathComponent(
                "\(candidate.userMessageID.rawValue).json"
            )
            try persistence.encodeMessage(fixture.publication.userMessage).write(
                to: collisionFile
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: collisionFile.path))
            XCTAssertEqual(messages.path.withCString { Darwin.chmod($0, 0) }, 0)
            defer {
                _ = messages.path.withCString { Darwin.chmod($0, 0o700) }
            }
            let permissionProbe = messages.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            }
            if permissionProbe >= 0 { Darwin.close(permissionProbe) }
            XCTAssertLessThan(permissionProbe, 0)

            let availability = await store.checkLaunchIdentity(
                candidate,
                for: fixture.install.authority
            )
            XCTAssertEqual(availability, .unavailable)
            await store.cancelInvocationReservation(
                fixture.install.authority.request
            )
        }
    }

    func testLaunchIdentityReservationFencesFreshDraftNamespaceWriterBeforeProvider() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let store = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await store.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .none)
            let invocation = fixture.install.invocation
            let identity = InvocationLaunchIdentity(
                invocationID: invocation.id,
                attemptID: invocation.attemptID,
                idempotencyValue: invocation.providerIdempotencyValue,
                userMessageID: fixture.publication.userMessage.id,
                coachMessageID: fixture.publication.coachMessage.id,
                freshDraftID: fixture.publication.freshDraft.draftID
            )
            let identityAvailability = await store.checkLaunchIdentity(
                identity,
                for: fixture.install.authority
            )
            XCTAssertEqual(identityAvailability, .available)
            let conflictingSeed = try NewDevelopmentChatSeed(
                library: fixture.scope,
                chatID: ChatID("cht-20260830T120020000Z-3DEF"),
                draftID: fixture.publication.freshDraft.draftID,
                memoryID: CoachMemoryID("mem-20260830T120020000Z-5KMN"),
                instant: UTCInstant("2026-08-30T12:00:20.000Z"),
                profileStatementGeneration: 0
            )

            XCTAssertThrowsError(
                try PortableChatPersistence().create(
                    conflictingSeed,
                    at: fixture.root
                )
            ) { error in
                XCTAssertEqual(error as? PortableChatPersistenceError, .ioFailure)
            }

            await store.cancelInvocationReservation(
                fixture.install.authority.request
            )
            XCTAssertNoThrow(
                try PortableChatPersistence().create(
                    conflictingSeed,
                    at: fixture.root
                )
            )
        }
    }

    func testInvocationPublicationReleasesLibraryLivenessAuthority() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await owner.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .none)
            guard case .installed = await owner.installInvocation(fixture.install) else {
                return XCTFail("Invocation was not installed")
            }
            guard case .committed = await owner.publish(fixture.publication) else {
                return XCTFail("Invocation was not published")
            }

            let next = await contender.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(next, .none)
        }
    }

    func testLivePublicationProofPartialDoesNotFreezeOrMutatePendingRead() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            guard case .acquired = await owner.acquirePendingInvocation(
                fixture.install.authority.request
            ) else { return XCTFail("Pending authority was not acquired") }
            guard case .installed = await owner.installInvocation(fixture.install) else {
                return XCTFail("Invocation was not installed")
            }
            let partial = fixture.root
                .appendingPathComponent("invocations", isDirectory: true)
                .appendingPathComponent(
                    fixture.install.invocation.id.rawValue,
                    isDirectory: true
                )
                .appendingPathComponent(
                    ".publication-proof.json.11111111-1111-1111-1111-111111111111.partial"
                )
            try Data("in-progress".utf8).write(to: partial)

            let readingWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await readingWorkspace.chooseLibrary()
            let reader = PortableChatStore(workspace: readingWorkspace)
            let load = await reader.load(fixture.locked.chat.id, in: fixture.scope)

            XCTAssertEqual(load, .loaded(fixture.locked))
            XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
            _ = await owner.abortInstalledNewSend(fixture.install.invocation)
        }
    }

    func testCommittedPublicationSurvivesFailedImmediateReconciliationAndRecoveryReread() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let persistence = PortableChatPersistence { point in
                if point == .afterPublicationManifestInstall
                    || point == .beforePublicationReconciliationRead
                {
                    throw PortableChatPersistenceError.injectedFault(point)
                }
            }
            let store = PortableInvocationStore(
                persistence: persistence,
                workspace: fixture.workspace
            )
            let acquired = await store.acquirePendingInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(acquired, .acquired(fixture.install.authority))
            guard case .installed = await store.installInvocation(fixture.install) else {
                return XCTFail("Invocation was not installed")
            }

            let publish = await store.publish(fixture.publication)
            XCTAssertEqual(publish, .failed)
            let abort = await store.abortInstalledNewSend(
                fixture.install.invocation
            )
            XCTAssertEqual(abort, .stale(fixture.publication.replacement))
            let recovery = await store.recoverPendingAfterTerminalFailure(
                fixture.install.authority.request
            )
            XCTAssertEqual(
                recovery,
                .ineligible(fixture.publication.replacement)
            )
        }
    }

    func testTypedRecoveryRejectsBoundButDifferentDurablePublicationProof() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let publicationFault = OneShot()
            let reconciliationFault = OneShot()
            let owner = PortableInvocationStore(
                persistence: PortableChatPersistence { point in
                    if point == .afterPublicationManifestInstall,
                       publicationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                    if point == .beforePublicationReconciliationRead,
                       reconciliationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                },
                workspace: fixture.workspace
            )
            guard case .acquired = await owner.acquirePendingInvocation(
                fixture.install.authority.request
            ) else { return XCTFail("Pending authority was not acquired") }
            guard case .installed = await owner.installInvocation(fixture.install) else {
                return XCTFail("Invocation was not installed")
            }
            let publication = await owner.publish(fixture.publication)
            XCTAssertEqual(publication, .failed)

            let invocationRoot = fixture.root
                .appendingPathComponent("invocations", isDirectory: true)
                .appendingPathComponent(
                    fixture.install.invocation.id.rawValue,
                    isDirectory: true
                )
            let proofURL = invocationRoot.appendingPathComponent("publication-proof.json")
            var proof = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: proofURL)
                ) as? [String: Any]
            )
            proof["coachMessageSha256"] = String(repeating: "0", count: 64)
            try JSONSerialization.data(
                withJSONObject: proof,
                options: [.sortedKeys]
            ).write(to: proofURL)

            let recovery = await owner.recoverPublishedInvocation(fixture.publication)

            XCTAssertEqual(recovery, .unavailable)
            XCTAssertTrue(FileManager.default.fileExists(atPath: proofURL.path))
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.root
                        .appendingPathComponent("chats", isDirectory: true)
                        .appendingPathComponent(
                            fixture.locked.chat.id.rawValue,
                            isDirectory: true
                        )
                        .appendingPathComponent("pending-user-turn.json").path
                )
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: invocationRoot.path))
        }
    }

    func testExactPublishedRecoveryAllowsLaterRenameAndFreshDraftEdit() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let publicationFault = OneShot()
            let reconciliationFault = OneShot()
            let owner = PortableInvocationStore(
                persistence: PortableChatPersistence { point in
                    if point == .afterPublicationManifestInstall,
                       publicationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                    if point == .beforePublicationReconciliationRead,
                       reconciliationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                },
                workspace: fixture.workspace
            )
            let editingWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await editingWorkspace.chooseLibrary()
            let editor = PortableChatStore(workspace: editingWorkspace)
            let acquired = await owner.acquirePendingInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(acquired, .acquired(fixture.install.authority))
            guard case .installed = await owner.installInvocation(fixture.install) else {
                return XCTFail("Invocation was not installed")
            }
            let publish = await owner.publish(fixture.publication)
            XCTAssertEqual(publish, .failed)

            guard case let .loaded(published) = await editor.load(
                fixture.locked.chat.id,
                in: fixture.scope
            ) else { return XCTFail("Published Chat was not readable") }
            let rename = try RenameChatMutation(
                library: fixture.scope,
                base: published,
                title: ChatTitle("Later title"),
                updatedAt: UTCInstant("2026-08-30T12:00:04.000Z")
            )
            guard case let .committed(renamed) = await editor.rename(rename) else {
                return XCTFail("Later rename did not commit")
            }
            let laterDraft = try renamed.chat.draft.edited(
                text: "A later fresh Draft edit.",
                at: UTCInstant("2026-08-30T12:00:05.000Z")
            )
            guard case let .committed(evolved) = await editor.saveDraft(
                SaveChatDraftMutation(
                    library: fixture.scope,
                    chatID: renamed.chat.id,
                    replacement: laterDraft
                )
            ) else { return XCTFail("Later Draft edit did not commit") }

            let recovery = await owner.recoverPublishedInvocation(
                fixture.publication
            )
            XCTAssertEqual(recovery, .published(evolved))
        }
    }

    func testExactPublishedRecoveryRejectsIDOnlyMessageImpostor() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let publicationFault = OneShot()
            let reconciliationFault = OneShot()
            let owner = PortableInvocationStore(
                persistence: PortableChatPersistence { point in
                    if point == .afterPublicationManifestInstall,
                       publicationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                    if point == .beforePublicationReconciliationRead,
                       reconciliationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                },
                workspace: fixture.workspace
            )
            let readingWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await readingWorkspace.chooseLibrary()
            let reader = PortableChatStore(workspace: readingWorkspace)
            guard case .acquired = await owner.acquirePendingInvocation(
                fixture.install.authority.request
            ) else { return XCTFail("Pending authority was not acquired") }
            guard case .installed = await owner.installInvocation(fixture.install) else {
                return XCTFail("Invocation was not installed")
            }
            let publish = await owner.publish(fixture.publication)
            XCTAssertEqual(publish, .failed)
            guard case .loaded = await reader.load(
                fixture.locked.chat.id,
                in: fixture.scope
            ) else { return XCTFail("Published Chat was not readable") }

            let expected = fixture.publication.coachMessage
            let impostor = try ChatMessage(
                id: expected.id,
                responsePositionID: expected.responsePositionID,
                content: .coach(markdown: "Altered immutable response."),
                coachProfile: expected.coachProfile,
                createdAt: expected.createdAt
            )
            let messageURL = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(fixture.locked.chat.id.rawValue, isDirectory: true)
                .appendingPathComponent("messages", isDirectory: true)
                .appendingPathComponent("\(expected.id.rawValue).json")
            try PortableChatPersistence().encodeMessage(impostor).write(to: messageURL)

            let recovery = await owner.recoverPublishedInvocation(
                fixture.publication
            )
            XCTAssertEqual(recovery, .notPublished)
            _ = await owner.abortInstalledNewSend(fixture.install.invocation)
        }
    }

    func testRelaunchPreservesPendingAndInvocationForAlteredPublishedMessage() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let publicationFault = OneShot()
            let reconciliationFault = OneShot()
            weak var releasedStore: PortableInvocationStore?
            do {
                let crashed = PortableInvocationStore(
                    persistence: PortableChatPersistence { point in
                        if point == .afterPublicationManifestInstall,
                           publicationFault.take()
                        {
                            throw PortableChatPersistenceError.injectedFault(point)
                        }
                        if point == .beforePublicationReconciliationRead,
                           reconciliationFault.take()
                        {
                            throw PortableChatPersistenceError.injectedFault(point)
                        }
                    },
                    workspace: fixture.workspace
                )
                releasedStore = crashed
                guard case .acquired = await crashed.acquirePendingInvocation(
                    fixture.install.authority.request
                ) else { return XCTFail("Pending authority was not acquired") }
                guard case .installed = await crashed.installInvocation(fixture.install) else {
                    return XCTFail("Invocation was not installed")
                }
                let publication = await crashed.publish(fixture.publication)
                XCTAssertEqual(publication, .failed)
            }
            for _ in 0 ..< 20 where releasedStore != nil {
                await Task.yield()
            }
            XCTAssertNil(releasedStore)

            let expected = fixture.publication.coachMessage
            let impostor = try ChatMessage(
                id: expected.id,
                responsePositionID: expected.responsePositionID,
                content: .coach(markdown: "Altered immutable response."),
                coachProfile: expected.coachProfile,
                createdAt: expected.createdAt
            )
            let chatRoot = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(fixture.locked.chat.id.rawValue, isDirectory: true)
            try PortableChatPersistence().encodeMessage(impostor).write(
                to: chatRoot
                    .appendingPathComponent("messages", isDirectory: true)
                    .appendingPathComponent("\(expected.id.rawValue).json")
            )

            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let relaunched = PortableChatStore(workspace: relaunchedWorkspace)

            let load = await relaunched.load(fixture.locked.chat.id, in: fixture.scope)
            XCTAssertEqual(load, .failed)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: chatRoot.appendingPathComponent("pending-user-turn.json").path
                )
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.root
                        .appendingPathComponent("invocations", isDirectory: true)
                        .appendingPathComponent(
                            fixture.install.invocation.id.rawValue,
                            isDirectory: true
                        ).path
                )
            )
        }
    }

    func testRelaunchPreservesPendingAndInvocationForAlteredCoachProvenance() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let crash = await leaveCommittedPublicationForRelaunch(fixture)
            XCTAssertEqual(crash.outcome, .failed)
            XCTAssertTrue(crash.storeReleased)

            let expected = fixture.publication.coachMessage
            let impostor = try ChatMessage(
                id: expected.id,
                responsePositionID: expected.responsePositionID,
                content: expected.content,
                coachProfile: CoachProfileProvenance(
                    revisionID: expected.coachProfile?.revisionID,
                    statementGeneration: 10
                ),
                createdAt: expected.createdAt
            )
            let chatRoot = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(fixture.locked.chat.id.rawValue, isDirectory: true)
            try PortableChatPersistence().encodeMessage(impostor).write(
                to: chatRoot
                    .appendingPathComponent("messages", isDirectory: true)
                    .appendingPathComponent("\(expected.id.rawValue).json")
            )

            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let relaunched = PortableChatStore(workspace: relaunchedWorkspace)
            let load = await relaunched.load(fixture.locked.chat.id, in: fixture.scope)

            XCTAssertEqual(load, .failed)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: chatRoot.appendingPathComponent("pending-user-turn.json").path
                )
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.root
                        .appendingPathComponent("invocations", isDirectory: true)
                        .appendingPathComponent(
                            fixture.install.invocation.id.rawValue,
                            isDirectory: true
                        ).path
                )
            )
        }
    }

    func testRelaunchRecognizesExactCommittedPublicationAndFinishesCleanup() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let crash = await leaveCommittedPublicationForRelaunch(fixture)
            XCTAssertEqual(crash.outcome, .failed)
            XCTAssertTrue(crash.storeReleased)

            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let relaunched = PortableChatStore(workspace: relaunchedWorkspace)

            let load = await relaunched.load(fixture.locked.chat.id, in: fixture.scope)
            XCTAssertEqual(load, .loaded(fixture.publication.replacement))
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.root
                        .appendingPathComponent("chats", isDirectory: true)
                        .appendingPathComponent(
                            fixture.locked.chat.id.rawValue,
                            isDirectory: true
                        )
                        .appendingPathComponent("pending-user-turn.json").path
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.root
                        .appendingPathComponent("invocations", isDirectory: true)
                        .appendingPathComponent(
                            fixture.install.invocation.id.rawValue,
                            isDirectory: true
                        ).path
                )
            )
        }
    }

    func testRelaunchPreservesPostSwitchInvocationWithoutPublicationProof() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let crash = await leaveCommittedPublicationForRelaunch(fixture)
            XCTAssertEqual(crash.outcome, .failed)
            XCTAssertTrue(crash.storeReleased)

            let invocationRoot = fixture.root
                .appendingPathComponent("invocations", isDirectory: true)
                .appendingPathComponent(
                    fixture.install.invocation.id.rawValue,
                    isDirectory: true
                )
            try FileManager.default.removeItem(
                at: invocationRoot.appendingPathComponent("publication-proof.json")
            )
            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let relaunched = PortableChatStore(workspace: relaunchedWorkspace)

            let load = await relaunched.load(fixture.locked.chat.id, in: fixture.scope)
            XCTAssertEqual(load, .failed)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.root
                        .appendingPathComponent("chats", isDirectory: true)
                        .appendingPathComponent(
                            fixture.locked.chat.id.rawValue,
                            isDirectory: true
                        )
                        .appendingPathComponent("pending-user-turn.json").path
                )
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: invocationRoot.path))
        }
    }

    func testCorruptPublicationProofFreezesOnlyItsTargetChatInCatalog() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let crash = await leaveCommittedPublicationForRelaunch(fixture)
            XCTAssertEqual(crash.outcome, .failed)
            XCTAssertTrue(crash.storeReleased)

            let invocationRoot = fixture.root
                .appendingPathComponent("invocations", isDirectory: true)
                .appendingPathComponent(
                    fixture.install.invocation.id.rawValue,
                    isDirectory: true
                )
            let proofURL = invocationRoot.appendingPathComponent("publication-proof.json")
            var proof = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: proofURL)
                ) as? [String: Any]
            )
            proof["schemaVersion"] = 2
            try JSONSerialization.data(
                withJSONObject: proof,
                options: [.sortedKeys]
            ).write(to: proofURL)
            let invocationURL = invocationRoot.appendingPathComponent("invocation.json")
            let pendingURL = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(
                    fixture.locked.chat.id.rawValue,
                    isDirectory: true
                )
                .appendingPathComponent("pending-user-turn.json")
            let proofBytes = try Data(contentsOf: proofURL)
            let invocationBytes = try Data(contentsOf: invocationURL)
            let pendingBytes = try Data(contentsOf: pendingURL)

            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let store = PortableChatStore(workspace: relaunchedWorkspace)

            guard case let .loaded(entries) = await store.loadCatalog(
                in: fixture.scope
            ) else { return XCTFail("corrupt target blocked the production catalog") }

            XCTAssertEqual(entries.count, 2)
            XCTAssertTrue(entries.contains(.frozen(
                FrozenChatSnapshot(chatID: fixture.locked.chat.id, reason: .corrupt)
            )))
            XCTAssertTrue(entries.contains { entry in
                guard case let .available(aggregate) = entry else { return false }
                return aggregate.chat.id == fixture.competingAuthority.request.chatID
            })
            XCTAssertEqual(try Data(contentsOf: proofURL), proofBytes)
            XCTAssertEqual(try Data(contentsOf: invocationURL), invocationBytes)
            XCTAssertEqual(try Data(contentsOf: pendingURL), pendingBytes)
        }
    }

    func testCorruptPublicationProofDoesNotBlockHealthySiblingInvocationStart() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let crash = await leaveCommittedPublicationForRelaunch(fixture)
            XCTAssertEqual(crash.outcome, .failed)
            XCTAssertTrue(crash.storeReleased)

            let invocationRoot = fixture.root
                .appendingPathComponent("invocations", isDirectory: true)
                .appendingPathComponent(
                    fixture.install.invocation.id.rawValue,
                    isDirectory: true
                )
            let proofURL = invocationRoot.appendingPathComponent("publication-proof.json")
            var proof = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: proofURL)
                ) as? [String: Any]
            )
            proof["schemaVersion"] = 2
            try JSONSerialization.data(
                withJSONObject: proof,
                options: [.sortedKeys]
            ).write(to: proofURL)

            let targetChatRoot = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(
                    fixture.locked.chat.id.rawValue,
                    isDirectory: true
                )
            let evidenceURLs = [
                invocationRoot.appendingPathComponent("invocation.json"),
                proofURL,
                targetChatRoot.appendingPathComponent("chat.json"),
                targetChatRoot.appendingPathComponent("pending-user-turn.json"),
                targetChatRoot.appendingPathComponent("memory", isDirectory: true)
                    .appendingPathComponent(
                        "\(fixture.locked.memory.memoryID.rawValue).json"
                    ),
                targetChatRoot.appendingPathComponent("messages", isDirectory: true)
                    .appendingPathComponent(
                        "\(fixture.publication.userMessage.id.rawValue).json"
                    ),
                targetChatRoot.appendingPathComponent("messages", isDirectory: true)
                    .appendingPathComponent(
                        "\(fixture.publication.coachMessage.id.rawValue).json"
                    ),
            ]
            let evidenceBytes = try evidenceURLs.map { try Data(contentsOf: $0) }
            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let store = PortableInvocationStore(workspace: relaunchedWorkspace)

            let acquired = await store.acquirePendingInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(acquired, .acquired(fixture.competingAuthority))
            let identity = InvocationLaunchIdentity(
                invocationID: try CoachInvocationID(
                    "inv-20260830T120012000Z-7STV"
                ),
                attemptID: try CoachProviderAttemptID(
                    "atm-20260830T120012000Z-8WXY"
                ),
                idempotencyValue: try ProviderIdempotencyValue(
                    "synthetic-competing-9YZ0"
                ),
                userMessageID: try ChatMessageID(
                    "msg-20260830T120013000Z-0ABC"
                ),
                coachMessageID: try ChatMessageID(
                    "msg-20260830T120013000Z-1BCD"
                ),
                freshDraftID: try ChatDraftID(
                    "drf-20260830T120013000Z-2CDE"
                )
            )
            let identityAvailability = await store.checkLaunchIdentity(
                identity,
                for: fixture.competingAuthority
            )
            XCTAssertEqual(identityAvailability, .available)
            let install = try InstallCoachInvocationMutation(
                authority: fixture.competingAuthority,
                identity: identity,
                preparedProfile: try XCTUnwrap(
                    fixture.install.invocation.preparedProfile
                ),
                admittedAt: UTCInstant("2026-08-30T12:00:12.000Z")
            )
            let installation = await store.installInvocation(install)
            XCTAssertEqual(installation, .installed(install.invocation))

            XCTAssertTrue(
                try PortableChatPersistence().hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
            let reader = PortableChatStore(workspace: relaunchedWorkspace)
            let frozenTarget = await reader.load(
                fixture.locked.chat.id,
                in: fixture.scope
            )
            XCTAssertEqual(
                frozenTarget,
                .frozen(FrozenChatSnapshot(
                    chatID: fixture.locked.chat.id,
                    reason: .corrupt
                ))
            )
            for (url, expected) in zip(evidenceURLs, evidenceBytes) {
                XCTAssertEqual(try Data(contentsOf: url), expected, url.path)
            }
        }
    }

    func testDuplicateFrozenInvocationAuthoritiesForOneChatFailClosed() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let crash = await leaveCommittedPublicationForRelaunch(fixture)
            XCTAssertEqual(crash.outcome, .failed)
            XCTAssertTrue(crash.storeReleased)

            let invocationsRoot = fixture.root.appendingPathComponent(
                "invocations",
                isDirectory: true
            )
            let originalRoot = invocationsRoot.appendingPathComponent(
                fixture.install.invocation.id.rawValue,
                isDirectory: true
            )
            let proofURL = originalRoot.appendingPathComponent("publication-proof.json")
            var proof = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: proofURL)
                ) as? [String: Any]
            )
            proof["schemaVersion"] = 2
            let corruptProof = try JSONSerialization.data(
                withJSONObject: proof,
                options: [.sortedKeys]
            )
            try corruptProof.write(to: proofURL)

            let alternateIdentity = InvocationLaunchIdentity(
                invocationID: try CoachInvocationID(
                    "inv-20260830T120002000Z-9YZ0"
                ),
                attemptID: try CoachProviderAttemptID(
                    "atm-20260830T120002000Z-0ABC"
                ),
                idempotencyValue: try ProviderIdempotencyValue(
                    "synthetic-duplicate-1BCD"
                ),
                userMessageID: try ChatMessageID(
                    "msg-20260830T120003000Z-2CDE"
                ),
                coachMessageID: try ChatMessageID(
                    "msg-20260830T120003000Z-3DEF"
                ),
                freshDraftID: try ChatDraftID(
                    "drf-20260830T120003000Z-4GHJ"
                )
            )
            let alternate = try InstallCoachInvocationMutation(
                authority: fixture.install.authority,
                identity: alternateIdentity,
                preparedProfile: try XCTUnwrap(
                    fixture.install.invocation.preparedProfile
                ),
                admittedAt: UTCInstant("2026-08-30T12:00:02.000Z")
            ).invocation
            let alternateRoot = invocationsRoot.appendingPathComponent(
                alternate.id.rawValue,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: alternateRoot,
                withIntermediateDirectories: false
            )
            try PortableChatPersistence().encodeInvocation(alternate).write(
                to: alternateRoot.appendingPathComponent("invocation.json")
            )
            try corruptProof.write(
                to: alternateRoot.appendingPathComponent("publication-proof.json")
            )

            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let store = PortableChatStore(workspace: relaunchedWorkspace)

            let catalog = await store.loadCatalog(in: fixture.scope)
            XCTAssertEqual(catalog, .failed)
            XCTAssertEqual(try Data(contentsOf: proofURL), corruptProof)
            XCTAssertEqual(
                try Data(contentsOf: alternateRoot.appendingPathComponent(
                    "publication-proof.json"
                )),
                corruptProof
            )
        }
    }

    func testUsableAndFrozenInvocationAuthoritiesForOneChatFailClosed() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let crash = await leaveCommittedPublicationForRelaunch(fixture)
            XCTAssertEqual(crash.outcome, .failed)
            XCTAssertTrue(crash.storeReleased)

            let invocationsRoot = fixture.root.appendingPathComponent(
                "invocations",
                isDirectory: true
            )
            let originalRoot = invocationsRoot.appendingPathComponent(
                fixture.install.invocation.id.rawValue,
                isDirectory: true
            )
            let proofURL = originalRoot.appendingPathComponent(
                "publication-proof.json"
            )
            let proofBytes = try Data(contentsOf: proofURL)
            let alternateIdentity = InvocationLaunchIdentity(
                invocationID: try CoachInvocationID(
                    "inv-20260830T120002000Z-9YZ0"
                ),
                attemptID: try CoachProviderAttemptID(
                    "atm-20260830T120002000Z-0ABC"
                ),
                idempotencyValue: try ProviderIdempotencyValue(
                    "synthetic-overlap-1BCD"
                ),
                userMessageID: try ChatMessageID(
                    "msg-20260830T120003000Z-2CDE"
                ),
                coachMessageID: try ChatMessageID(
                    "msg-20260830T120003000Z-3DEF"
                ),
                freshDraftID: try ChatDraftID(
                    "drf-20260830T120003000Z-4GHJ"
                )
            )
            let alternate = try InstallCoachInvocationMutation(
                authority: fixture.install.authority,
                identity: alternateIdentity,
                preparedProfile: try XCTUnwrap(
                    fixture.install.invocation.preparedProfile
                ),
                admittedAt: UTCInstant("2026-08-30T12:00:02.000Z")
            ).invocation
            let alternateRoot = invocationsRoot.appendingPathComponent(
                alternate.id.rawValue,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: alternateRoot,
                withIntermediateDirectories: false
            )
            try PortableChatPersistence().encodeInvocation(alternate).write(
                to: alternateRoot.appendingPathComponent("invocation.json")
            )
            try proofBytes.write(
                to: alternateRoot.appendingPathComponent(
                    "publication-proof.json"
                )
            )

            XCTAssertThrowsError(
                try PortableChatPersistence().loadCatalog(
                    at: fixture.root,
                    in: fixture.scope
                )
            ) { error in
                XCTAssertEqual(
                    error as? PortableChatPersistenceError,
                    .invalidLayout
                )
            }
            XCTAssertEqual(try Data(contentsOf: proofURL), proofBytes)
            XCTAssertEqual(
                try Data(contentsOf: alternateRoot.appendingPathComponent(
                    "publication-proof.json"
                )),
                proofBytes
            )
        }
    }

    func testRelaunchPreservesPendingAndInvocationForDifferentPublishedMessageIDs() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let crash = await leaveCommittedPublicationForRelaunch(fixture)
            XCTAssertEqual(crash.outcome, .failed)
            XCTAssertTrue(crash.storeReleased)

            let published = fixture.publication.replacement.chat
            let userID = try ChatMessageID("msg-20260830T120004000Z-3DEF")
            let coachID = try ChatMessageID("msg-20260830T120004000Z-4GHJ")
            let user = try ChatMessage(
                id: userID,
                responsePositionID: fixture.install.invocation.responsePositionID,
                content: fixture.publication.userMessage.content,
                createdAt: fixture.publication.userMessage.createdAt
            )
            let coach = try ChatMessage(
                id: coachID,
                responsePositionID: fixture.install.invocation.responsePositionID,
                content: fixture.publication.coachMessage.content,
                coachProfile: fixture.publication.coachMessage.coachProfile,
                createdAt: fixture.publication.coachMessage.createdAt
            )
            let impostor = try Chat(
                id: published.id,
                manifestRevision: published.manifestRevision,
                title: published.title,
                createdAt: published.createdAt,
                updatedAt: published.updatedAt,
                creation: published.creation,
                profileStatementGenerationAtCreation:
                    published.profileStatementGenerationAtCreation,
                attachments: published.attachments,
                draft: published.draft,
                messageIDs: Array(published.messageIDs.dropLast(2)) + [userID, coachID],
                currentMemoryID: published.currentMemoryID
            )
            let chatRoot = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(published.id.rawValue, isDirectory: true)
            let messages = chatRoot.appendingPathComponent("messages", isDirectory: true)
            try PortableChatPersistence().encodeMessage(user).write(
                to: messages.appendingPathComponent("\(userID.rawValue).json")
            )
            try PortableChatPersistence().encodeMessage(coach).write(
                to: messages.appendingPathComponent("\(coachID.rawValue).json")
            )
            try PortableChatPersistence().encodeChat(impostor).write(
                to: chatRoot.appendingPathComponent("chat.json")
            )

            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let relaunched = PortableChatStore(workspace: relaunchedWorkspace)
            let load = await relaunched.load(published.id, in: fixture.scope)

            XCTAssertEqual(load, .failed)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: chatRoot.appendingPathComponent("pending-user-turn.json").path
                )
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.root
                        .appendingPathComponent("invocations", isDirectory: true)
                        .appendingPathComponent(
                            fixture.install.invocation.id.rawValue,
                            isDirectory: true
                        ).path
                )
            )
        }
    }

    func testRelaunchPreservesPendingAndInvocationForUnrelatedTwoMessageTail() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let crash = await leaveCommittedPublicationForRelaunch(fixture)
            XCTAssertEqual(crash.outcome, .failed)
            XCTAssertTrue(crash.storeReleased)

            let published = fixture.publication.replacement.chat
            let userID = try ChatMessageID("msg-20260830T120005000Z-5KMN")
            let coachID = try ChatMessageID("msg-20260830T120005000Z-6PQR")
            let user = try ChatMessage(
                id: userID,
                responsePositionID: fixture.install.invocation.responsePositionID,
                content: .user(text: "Unrelated later user message."),
                createdAt: try UTCInstant("2026-08-30T12:00:05.000Z")
            )
            let coach = try ChatMessage(
                id: coachID,
                responsePositionID: fixture.install.invocation.responsePositionID,
                content: .coach(markdown: "Unrelated later coach message."),
                coachProfile: fixture.install.invocation.preparedProfile,
                createdAt: try UTCInstant("2026-08-30T12:00:05.000Z")
            )
            let impostor = try Chat(
                id: published.id,
                manifestRevision: published.manifestRevision + 1,
                title: published.title,
                createdAt: published.createdAt,
                updatedAt: try UTCInstant("2026-08-30T12:00:05.000Z"),
                creation: published.creation,
                profileStatementGenerationAtCreation:
                    published.profileStatementGenerationAtCreation,
                attachments: published.attachments,
                draft: published.draft,
                messageIDs: published.messageIDs + [userID, coachID],
                currentMemoryID: published.currentMemoryID
            )
            let chatRoot = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(published.id.rawValue, isDirectory: true)
            let messages = chatRoot.appendingPathComponent("messages", isDirectory: true)
            try PortableChatPersistence().encodeMessage(user).write(
                to: messages.appendingPathComponent("\(userID.rawValue).json")
            )
            try PortableChatPersistence().encodeMessage(coach).write(
                to: messages.appendingPathComponent("\(coachID.rawValue).json")
            )
            try PortableChatPersistence().encodeChat(impostor).write(
                to: chatRoot.appendingPathComponent("chat.json")
            )

            let relaunchedWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await relaunchedWorkspace.chooseLibrary()
            let relaunched = PortableChatStore(workspace: relaunchedWorkspace)
            let load = await relaunched.load(published.id, in: fixture.scope)

            XCTAssertEqual(load, .failed)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: chatRoot.appendingPathComponent("pending-user-turn.json").path
                )
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.root
                        .appendingPathComponent("invocations", isDirectory: true)
                        .appendingPathComponent(
                            fixture.install.invocation.id.rawValue,
                            isDirectory: true
                        ).path
                )
            )
        }
    }

    func testExactPublishedRecoveryRejectsFreshDraftChangeWithoutManifestRevision() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let publicationFault = OneShot()
            let reconciliationFault = OneShot()
            let owner = PortableInvocationStore(
                persistence: PortableChatPersistence { point in
                    if point == .afterPublicationManifestInstall,
                       publicationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                    if point == .beforePublicationReconciliationRead,
                       reconciliationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                },
                workspace: fixture.workspace
            )
            guard case .acquired = await owner.acquirePendingInvocation(
                fixture.install.authority.request
            ) else { return XCTFail("Pending authority was not acquired") }
            guard case .installed = await owner.installInvocation(fixture.install) else {
                return XCTFail("Invocation was not installed")
            }
            let publish = await owner.publish(fixture.publication)
            XCTAssertEqual(publish, .failed)

            let published = fixture.publication.replacement.chat
            let unversionedDraft = try published.draft.edited(
                text: "This edit has no manifest lineage.",
                at: UTCInstant("2026-08-30T12:00:05.000Z")
            )
            let impostor = try Chat(
                id: published.id,
                manifestRevision: published.manifestRevision,
                title: published.title,
                createdAt: published.createdAt,
                updatedAt: unversionedDraft.updatedAt,
                creation: published.creation,
                profileStatementGenerationAtCreation:
                    published.profileStatementGenerationAtCreation,
                attachments: published.attachments,
                draft: unversionedDraft,
                messageIDs: published.messageIDs,
                currentMemoryID: published.currentMemoryID
            )
            let chatURL = fixture.root
                .appendingPathComponent("chats", isDirectory: true)
                .appendingPathComponent(fixture.locked.chat.id.rawValue, isDirectory: true)
                .appendingPathComponent("chat.json")
            try PortableChatPersistence().encodeChat(impostor).write(to: chatURL)

            let recovery = await owner.recoverPublishedInvocation(
                fixture.publication
            )
            XCTAssertEqual(recovery, .unavailable)
            _ = await owner.abortInstalledNewSend(fixture.install.invocation)
        }
    }

    func testExactPublishedRecoveryReacquiresAuthorityAfterAbortReleasedLease() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let publicationFault = OneShot()
            let firstReconciliationFault = OneShot()
            let secondReconciliationFault = OneShot()
            let owner = PortableInvocationStore(
                persistence: PortableChatPersistence { point in
                    if point == .afterPublicationManifestInstall,
                       publicationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                    if point == .beforePublicationReconciliationRead,
                       firstReconciliationFault.take()
                            || secondReconciliationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                },
                workspace: fixture.workspace
            )
            let editingWorkspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [fixture.root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await editingWorkspace.chooseLibrary()
            let editor = PortableChatStore(workspace: editingWorkspace)
            guard case .acquired = await owner.acquirePendingInvocation(
                fixture.install.authority.request
            ) else { return XCTFail("Pending authority was not acquired") }
            guard case .installed = await owner.installInvocation(fixture.install) else {
                return XCTFail("Invocation was not installed")
            }
            let publish = await owner.publish(fixture.publication)
            XCTAssertEqual(publish, .failed)

            guard case let .loaded(published) = await editor.load(
                fixture.locked.chat.id,
                in: fixture.scope
            ) else { return XCTFail("Published Chat was not readable") }
            let rename = try RenameChatMutation(
                library: fixture.scope,
                base: published,
                title: ChatTitle("Later title"),
                updatedAt: UTCInstant("2026-08-30T12:00:04.000Z")
            )
            guard case let .committed(renamed) = await editor.rename(rename) else {
                return XCTFail("Later rename did not commit")
            }
            let laterDraft = try renamed.chat.draft.edited(
                text: "A later fresh Draft edit.",
                at: UTCInstant("2026-08-30T12:00:05.000Z")
            )
            guard case let .committed(evolved) = await editor.saveDraft(
                SaveChatDraftMutation(
                    library: fixture.scope,
                    chatID: renamed.chat.id,
                    replacement: laterDraft
                )
            ) else { return XCTFail("Later Draft edit did not commit") }

            let unavailable = await owner.recoverPublishedInvocation(
                fixture.publication
            )
            XCTAssertEqual(unavailable, .unavailable)
            let abort = await owner.abortInstalledNewSend(
                fixture.install.invocation
            )
            XCTAssertEqual(abort, .stale(evolved))

            let recovered = await owner.recoverPublishedInvocation(
                fixture.publication
            )
            XCTAssertEqual(recovered, .published(evolved))
        }
    }

    func testSameIDInvocationCannotConsumeAnotherInvocationLivenessAuthority() async throws {
        try await withTemporaryParent { parent in
            let fixture = try await makeInvocationStoreFixture(in: parent)
            let owner = PortableInvocationStore(workspace: fixture.workspace)
            let contender = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await owner.reserveInvocation(
                fixture.install.authority.request
            )
            XCTAssertEqual(reservation, .none)
            guard case .installed = await owner.installInvocation(fixture.install) else {
                return XCTFail("Invocation was not installed")
            }
            let alternateIdentity = InvocationLaunchIdentity(
                invocationID: fixture.install.invocation.id,
                attemptID: try CoachProviderAttemptID(
                    "atm-20260830T120002000Z-7STV"
                ),
                idempotencyValue: try ProviderIdempotencyValue(
                    "synthetic-attempt-7STV"
                ),
                userMessageID: try ChatMessageID(
                    "msg-20260830T120003000Z-8WXY"
                ),
                coachMessageID: try ChatMessageID(
                    "msg-20260830T120003000Z-9YZ0"
                ),
                freshDraftID: try ChatDraftID(
                    "drf-20260830T120003000Z-0ABC"
                )
            )
            let alternateInstall = try InstallCoachInvocationMutation(
                authority: fixture.install.authority,
                identity: alternateIdentity,
                preparedProfile: fixture.install.invocation.preparedProfile!,
                admittedAt: UTCInstant("2026-08-30T12:00:02.000Z")
            )
            let alternatePublication = try PublishCoachInvocationMutation(
                base: fixture.locked,
                invocation: alternateInstall.invocation,
                identity: alternateIdentity,
                coachMarkdown: "Unowned response.",
                completedAt: UTCInstant("2026-08-30T12:00:03.000Z")
            )

            let malformedAbort = await owner.abortInstalledNewSend(
                alternateInstall.invocation
            )
            let malformedPublication = await owner.publish(alternatePublication)
            XCTAssertEqual(malformedAbort, .failed)
            XCTAssertEqual(malformedPublication, .failed)
            let blocked = await contender.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(blocked, .exists)
            XCTAssertTrue(
                try PortableChatPersistence().hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
        }
    }
    private func leavePrecommitPublicationForRelaunch(
        _ fixture: InvocationStoreFixture,
        at point: PortableChatFaultPoint
    ) async -> (
        outcome: InvocationPublicationOutcome,
        publicationFaultReached: Bool,
        reconciliationFaultReached: Bool,
        storeReleased: Bool
    ) {
        let publicationFault = OneShot()
        let reconciliationFault = OneShot()
        weak var releasedStore: PortableInvocationStore?
        var outcome = InvocationPublicationOutcome.failed
        do {
            let crashed = PortableInvocationStore(
                persistence: PortableChatPersistence { reached in
                    if reached == point, publicationFault.take() {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                    if reached == .beforePublicationReconciliationRead,
                       reconciliationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(reached)
                    }
                },
                workspace: fixture.workspace
            )
            releasedStore = crashed
            guard case .acquired = await crashed.acquirePendingInvocation(
                fixture.install.authority.request
            ), case .installed = await crashed.installInvocation(fixture.install)
            else { return (.failed, false, false, false) }
            outcome = await crashed.publish(fixture.publication)
        }
        for _ in 0 ..< 20 where releasedStore != nil {
            await Task.yield()
        }
        return (
            outcome,
            publicationFault.wasTaken,
            reconciliationFault.wasTaken,
            releasedStore == nil
        )
    }

    private func leavePrecommitCASConflictForRelaunch(
        _ fixture: InvocationStoreFixture,
        rename: RenameChatMutation
    ) async -> (
        outcome: InvocationPublicationOutcome,
        conflictReached: Bool,
        storeReleased: Bool
    ) {
        let conflict = OneShot()
        weak var releasedStore: PortableInvocationStore?
        var outcome = InvocationPublicationOutcome.failed
        do {
            let crashed = PortableInvocationStore(
                persistence: PortableChatPersistence { reached in
                    guard reached == .afterPublicationManifestFileFlush,
                          conflict.take()
                    else { return }
                    let manifest = fixture.root
                        .appendingPathComponent("chats", isDirectory: true)
                        .appendingPathComponent(rename.chatID.rawValue, isDirectory: true)
                        .appendingPathComponent("chat.json")
                    try PortableChatPersistence()
                        .encodeChat(rename.replacement.chat)
                        .write(to: manifest, options: .atomic)
                },
                workspace: fixture.workspace
            )
            releasedStore = crashed
            guard case .acquired = await crashed.acquirePendingInvocation(
                fixture.install.authority.request
            ), case .installed = await crashed.installInvocation(fixture.install)
            else { return (.failed, false, false) }
            outcome = await crashed.publish(fixture.publication)
        }
        for _ in 0 ..< 20 where releasedStore != nil {
            await Task.yield()
        }
        return (outcome, conflict.wasTaken, releasedStore == nil)
    }

    private func assertPrecommitPublicationCrashArtifacts(
        _ fixture: InvocationStoreFixture,
        at point: PortableChatFaultPoint
    ) throws {
        let label = String(describing: point)
        let invocationRoot = fixture.root
            .appendingPathComponent("invocations", isDirectory: true)
            .appendingPathComponent(
                fixture.install.invocation.id.rawValue,
                isDirectory: true
            )
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: invocationRoot.path)),
            ["invocation.json", "publication-proof.json"],
            label
        )

        let chatRoot = fixture.root
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent(fixture.locked.chat.id.rawValue, isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: chatRoot.appendingPathComponent("pending-user-turn.json").path
            ),
            label
        )
        let messagesRoot = chatRoot.appendingPathComponent(
            "messages",
            isDirectory: true
        )
        let expectedMessages: Set<String>
        switch point {
        case .afterPublicationProofInstall,
             .afterPublicationProofDirectoryFlush:
            expectedMessages = []
        case .afterUserMessageInstall:
            expectedMessages = [
                "\(fixture.publication.userMessage.id.rawValue).json"
            ]
        case .afterCoachMessageInstall,
             .afterPublicationManifestFileFlush:
            expectedMessages = [
                "\(fixture.publication.userMessage.id.rawValue).json",
                "\(fixture.publication.coachMessage.id.rawValue).json",
            ]
        default:
            XCTFail("unsupported precommit fault point: \(point)")
            return
        }
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: messagesRoot.path)),
            expectedMessages,
            label
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: chatRoot.path)
                .contains(where: {
                    $0.hasPrefix(".chat.json.") && $0.hasSuffix(".partial")
                }),
            label
        )
    }

    private func assertRetryablePrecommitRecovery(
        _ reopened: ChatAggregate,
        fixture: InvocationStoreFixture,
        workspace: PortableLibraryWorkspace,
        label: String
    ) async throws {
        XCTAssertEqual(
            reopened.pendingUserTurn,
            fixture.locked.pendingUserTurn?.replacingFailure(
                .coachResponseInterrupted
            ),
            label
        )
        XCTAssertEqual(
            reopened.pendingUserTurn?.id,
            fixture.locked.pendingUserTurn?.id,
            label
        )
        XCTAssertEqual(reopened.chat.draft, fixture.locked.chat.draft, label)
        XCTAssertEqual(
            reopened.chat.draft.draftID,
            fixture.locked.chat.draft.draftID,
            label
        )
        XCTAssertEqual(reopened.chat.messageIDs, [], label)

        let invocationRoot = fixture.root
            .appendingPathComponent("invocations", isDirectory: true)
            .appendingPathComponent(
                fixture.install.invocation.id.rawValue,
                isDirectory: true
            )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: invocationRoot.path),
            label
        )
        let messagesRoot = fixture.root
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent(reopened.chat.id.rawValue, isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: messagesRoot.path),
            [],
            label
        )
        let chatRoot = messagesRoot.deletingLastPathComponent()
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: chatRoot.path)
                .contains(where: {
                    $0.hasPrefix(".chat.json.") && $0.hasSuffix(".partial")
                }),
            label
        )

        let retry = PortableInvocationStore(workspace: workspace)
        guard case let .acquired(authority) = await retry.acquirePendingInvocation(
            fixture.install.authority.request
        ) else {
            return XCTFail("recovered Pending was not retryable: \(label)")
        }
        XCTAssertEqual(authority.aggregate, reopened, label)
        XCTAssertEqual(authority.pendingUserTurn, reopened.pendingUserTurn, label)
        await retry.cancelInvocationReservation(authority.request)
    }

    private func withTemporaryParent(
        _ body: (URL) async throws -> Void
    ) async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-workspace-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        try await body(parent)
    }

    private func makeSeed(
        id: String = "lib-20260830T120000000Z-2ABC"
    ) throws -> NewLibrarySeed {
        let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
        return NewLibrarySeed(
            libraryID: try LibraryID(id),
            createdAt: instant,
            preferences: .defaults,
            profileHead: ProfileHead(
                generation: 0,
                statementGeneration: 0,
                selection: .null,
                updatedAt: instant
            )
        )
    }

    private func makeChatSeed(scope: LibraryScope) throws -> NewDevelopmentChatSeed {
        try NewDevelopmentChatSeed(
            library: scope,
            chatID: ChatID("cht-20260830T120000000Z-2ABC"),
            draftID: ChatDraftID("drf-20260830T120000000Z-3DEF"),
            memoryID: CoachMemoryID("mem-20260830T120000000Z-4GHJ"),
            instant: UTCInstant("2026-08-30T12:00:00.000Z"),
            profileStatementGeneration: 0
        )
    }

    private struct InvocationStoreFixture {
        let root: URL
        let scope: LibraryScope
        let workspace: PortableLibraryWorkspace
        let locked: ChatAggregate
        let install: InstallCoachInvocationMutation
        let publication: PublishCoachInvocationMutation
        let competingAuthority: InvocationPendingAuthority
    }

    private func leaveCommittedPublicationForRelaunch(
        _ fixture: InvocationStoreFixture
    ) async -> (outcome: InvocationPublicationOutcome, storeReleased: Bool) {
        let publicationFault = OneShot()
        let reconciliationFault = OneShot()
        weak var releasedStore: PortableInvocationStore?
        var outcome = InvocationPublicationOutcome.failed
        do {
            let crashed = PortableInvocationStore(
                persistence: PortableChatPersistence { point in
                    if point == .afterPublicationManifestInstall,
                       publicationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                    if point == .beforePublicationReconciliationRead,
                       reconciliationFault.take()
                    {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                },
                workspace: fixture.workspace
            )
            releasedStore = crashed
            guard case .acquired = await crashed.acquirePendingInvocation(
                fixture.install.authority.request
            ), case .installed = await crashed.installInvocation(fixture.install)
            else { return (.failed, false) }
            outcome = await crashed.publish(fixture.publication)
        }
        for _ in 0 ..< 20 where releasedStore != nil {
            await Task.yield()
        }
        return (outcome, releasedStore == nil)
    }

    private func makeInvocationStoreFixture(
        in parent: URL,
        libraryID: String = "lib-20260830T120000000Z-2ABC"
    ) async throws -> InvocationStoreFixture {
        let root = parent.appendingPathComponent("Invocation.audoralibrary")
        let library = try PortableLibraryPersistence().create(
            at: root,
            seed: makeSeed(id: libraryID)
        )
        let scope = LibraryScope(libraryID: library.manifest.libraryID)
        let workspace = PortableLibraryWorkspace(
            locations: QueueLocations(existing: [root]),
            bookmarks: SyntheticBookmarks(),
            access: RecordingAccessGrantor(),
            locatorStore: MemoryLocatorStore(),
            revealer: RecordingRevealer()
        )
        _ = await workspace.chooseLibrary()
        let persistence = PortableChatPersistence()
        let seed = try makeChatSeed(scope: scope)
        let created = try persistence.create(seed, at: root)
        let editedDraft = try created.chat.draft.edited(
            text: "Please help me say this more naturally.",
            at: UTCInstant("2026-08-30T12:00:00.500Z")
        )
        guard case let .committed(drafted) = try persistence.saveDraft(
            SaveChatDraftMutation(
                library: scope,
                chatID: created.chat.id,
                replacement: editedDraft
            ),
            at: root
        ) else { throw CocoaError(.fileWriteUnknown) }
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120001000Z-5KMN"),
            draftID: drafted.chat.draft.draftID,
            draftVersion: drafted.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120001000Z-6PQR"
            )
        )
        let lock = LockPendingUserTurnMutation(
            library: scope,
            chatID: drafted.chat.id,
            pendingUserTurn: pending
        )
        guard case let .committed(locked) = try persistence.lockPendingUserTurn(
            lock,
            at: root
        ) else { throw CocoaError(.fileWriteUnknown) }
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
            invocationID: try CoachInvocationID("inv-20260830T120002000Z-5KMN"),
            attemptID: try CoachProviderAttemptID("atm-20260830T120002000Z-6PQR"),
            idempotencyValue: try ProviderIdempotencyValue("synthetic-attempt-6PQR"),
            userMessageID: try ChatMessageID("msg-20260830T120003000Z-7STV"),
            coachMessageID: try ChatMessageID("msg-20260830T120003000Z-8WXY"),
            freshDraftID: try ChatDraftID("drf-20260830T120003000Z-9YZ0")
        )
        let competingSeed = try NewDevelopmentChatSeed(
            library: scope,
            chatID: ChatID("cht-20260830T120010000Z-3DEF"),
            draftID: ChatDraftID("drf-20260830T120010000Z-4GHJ"),
            memoryID: CoachMemoryID("mem-20260830T120010000Z-5KMN"),
            instant: UTCInstant("2026-08-30T12:00:10.000Z"),
            profileStatementGeneration: 0
        )
        let competingCreated = try persistence.create(competingSeed, at: root)
        let competingPending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120011000Z-6PQR"),
            draftID: competingCreated.chat.draft.draftID,
            draftVersion: competingCreated.chat.draft.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120011000Z-7STV"
            )
        )
        guard case let .committed(competingLocked) = try persistence.lockPendingUserTurn(
            LockPendingUserTurnMutation(
                library: scope,
                chatID: competingCreated.chat.id,
                pendingUserTurn: competingPending
            ),
            at: root
        ) else { throw CocoaError(.fileWriteUnknown) }
        let competingRequest = PendingCoachInvocationRequest(
            library: scope,
            chatID: competingLocked.chat.id,
            pendingUserTurnID: competingPending.id
        )
        let install = try InstallCoachInvocationMutation(
            authority: authority,
            identity: identity,
            preparedProfile: CoachProfileProvenance(
                revisionID: try ProfileRevisionID("prf-20260830T115900000Z-4GHJ"),
                statementGeneration: 9
            ),
            admittedAt: UTCInstant("2026-08-30T12:00:02.000Z")
        )
        return InvocationStoreFixture(
            root: root,
            scope: scope,
            workspace: workspace,
            locked: locked,
            install: install,
            publication: try PublishCoachInvocationMutation(
                base: locked,
                invocation: install.invocation,
                identity: identity,
                coachMarkdown: "Synthetic coaching response.",
                completedAt: UTCInstant("2026-08-30T12:00:03.000Z")
            ),
            competingAuthority: try InvocationPendingAuthority(
                request: competingRequest,
                aggregate: competingLocked
            )
        )
    }
}

private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func take() -> Bool {
        lock.withLock {
            guard !fired else { return false }
            fired = true
            return true
        }
    }

    var wasTaken: Bool { lock.withLock { fired } }
}

private final class SuspendedInvocationAcquisition: @unchecked Sendable {
    private let condition = NSCondition()
    private var isSuspended = false
    private var isResumed = false

    func suspend() {
        condition.lock()
        isSuspended = true
        condition.broadcast()
        while !isResumed { condition.wait() }
        condition.unlock()
    }

    func waitUntilSuspended() async {
        while !suspendedSnapshot() { await Task.yield() }
    }

    private func suspendedSnapshot() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return isSuspended
    }

    func resume() {
        condition.lock()
        isResumed = true
        condition.broadcast()
        condition.unlock()
    }
}

private actor QueueLocations: LibraryLocationChoosing {
    private var createURLs: [URL]
    private var existingURLs: [URL]

    init(create: [URL] = [], existing: [URL] = []) {
        createURLs = create
        existingURLs = existing
    }

    func chooseCreateDestination() async -> URL? {
        createURLs.isEmpty ? nil : createURLs.removeFirst()
    }

    func chooseExistingLibrary() async -> URL? {
        existingURLs.isEmpty ? nil : existingURLs.removeFirst()
    }
}

private final class SyntheticBookmarks: LibraryBookmarking, @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt8 = 1
    private var urls: [Data: URL] = [:]
    private let staleNames: Set<String>

    init(staleNames: Set<String> = []) {
        self.staleNames = staleNames
    }

    func makeBookmark(for url: URL) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let existing = urls.first(where: { $0.value == url })?.key { return existing }
        let value = Data([next])
        next &+= 1
        urls[value] = url
        return value
    }

    func resolveBookmark(_ bookmark: Data) throws -> LibraryBookmarkResolution {
        lock.lock()
        defer { lock.unlock() }
        guard let url = urls[bookmark] else { throw CocoaError(.fileNoSuchFile) }
        return LibraryBookmarkResolution(
            url: url,
            isStale: staleNames.contains(url.lastPathComponent)
        )
    }
}

private final class RecordingAccessGrantor: LibraryAccessGranting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var events: [String] {
        lock.withLock { recorded }
    }

    func acquireAccess(to url: URL) throws -> any LibraryAccessLease {
        let name = url.lastPathComponent
        lock.withLock { recorded.append("acquire:\(name)") }
        return RecordingLease(url: url) { [weak self] in
            self?.lock.withLock { self?.recorded.append("release:\(name)") }
        }
    }
}

private final class RecordingLease: LibraryAccessLease, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var released = false
    private let onRelease: @Sendable () -> Void

    init(url: URL, onRelease: @escaping @Sendable () -> Void) {
        self.url = url
        self.onRelease = onRelease
    }

    func release() {
        lock.withLock {
            guard !released else { return }
            released = true
            onRelease()
        }
    }
}

private actor MemoryLocatorStore: MachineLibraryLocatorStoring {
    private var value: MachineLibraryLocator?
    private(set) var saveCount = 0

    init(value: MachineLibraryLocator? = nil) { self.value = value }

    func load() async throws -> MachineLibraryLocator? { value }

    func save(_ locator: MachineLibraryLocator) async throws {
        value = locator
        saveCount += 1
    }
}

private actor RecordingRevealer: LibraryRevealing {
    private(set) var revealedNames: [String] = []

    func reveal(_ url: URL) async -> Bool {
        revealedNames.append(url.lastPathComponent)
        return true
    }
}
