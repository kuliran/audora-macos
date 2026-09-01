@_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
@testable @_spi(InvocationInfrastructure) import AudoraMacInfrastructure
import Darwin
import Foundation
import XCTest

final class PortableLibraryWorkspaceTests: XCTestCase {
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
                guard point == .afterInvocationAbortPendingRemoval,
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

    func testCrashedStoreReleasesLivenessAndRelaunchReconcilesItsInvocation() async throws {
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

            let relaunched = PortableInvocationStore(workspace: fixture.workspace)
            let reservation = await relaunched.reserveInvocation(
                fixture.competingAuthority.request
            )
            XCTAssertEqual(reservation, .none)
            XCTAssertFalse(
                try PortableChatPersistence().hasActiveInvocation(
                    at: fixture.root,
                    in: fixture.scope
                )
            )
            guard case let .readWrite(reopened) = try PortableChatPersistence().load(
                fixture.locked.chat.id,
                at: fixture.root,
                in: fixture.scope
            ) else { return XCTFail("reconciled Chat was unavailable") }
            XCTAssertNil(reopened.pendingUserTurn)
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

    func testProcessingScopeDoesNotReviveAfterSwitchingAwayAndBack() async throws {
        try await withTwoLibraries { first, second, firstAuthority, _ in
            let workspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [first, second, first]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await workspace.chooseLibrary()
            let acquired = await workspace.acquireSessionProcessingScope(
                for: LibraryScope(libraryID: firstAuthority.manifest.libraryID)
            )
            let scope = try XCTUnwrap(acquired)

            _ = await workspace.chooseLibrary()
            _ = await workspace.chooseLibrary()

            let current = await workspace.isCurrentSessionProcessingScope(
                scope.identity
            )
            XCTAssertFalse(current)
        }
    }

    func testProcessingScopeRejectsSamePathRootReplacement() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Root.audoralibrary")
            let moved = parent.appendingPathComponent("Original.audoralibrary")
            let seed = try makeSeed()
            let authority = try PortableLibraryPersistence().create(at: root, seed: seed)
            let workspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await workspace.chooseLibrary()
            let acquired = await workspace.acquireSessionProcessingScope(
                for: LibraryScope(libraryID: authority.manifest.libraryID)
            )
            let scope = try XCTUnwrap(acquired)

            try FileManager.default.moveItem(at: root, to: moved)
            _ = try PortableLibraryPersistence().create(at: root, seed: seed)

            let current = await workspace.isCurrentSessionProcessingScope(
                scope.identity
            )
            XCTAssertFalse(current)
        }
    }

    func testSuccessfulSwitchAcquiresCandidateBeforeReleasingOldLease() async throws {
        try await withTwoLibraries { first, second, firstAuthority, secondAuthority in
            let access = RecordingAccessGrantor()
            let locations = QueueLocations(existing: [first, second])
            let store = MemoryLocatorStore()
            let workspace = PortableLibraryWorkspace(
                locations: locations,
                bookmarks: SyntheticBookmarks(),
                access: access,
                locatorStore: store,
                revealer: RecordingRevealer()
            )

            let firstOpen = await workspace.chooseLibrary()
            let secondOpen = await workspace.chooseLibrary()
            XCTAssertEqual(firstOpen, .opened(firstAuthority.snapshot))
            XCTAssertEqual(secondOpen, .opened(secondAuthority.snapshot))

            XCTAssertEqual(
                access.events,
                ["acquire:First.audoralibrary", "acquire:Second.audoralibrary", "release:First.audoralibrary"]
            )
            let close = await workspace.closeActiveLibrary()
            XCTAssertEqual(close, .succeeded(recentAvailable: true))
            XCTAssertEqual(access.events.last, "release:Second.audoralibrary")
        }
    }

    func testFailedCandidateReleasesOnlyCandidateAndKeepsOldScopeRevealable() async throws {
        try await withTwoLibraries { first, second, firstAuthority, _ in
            try Data("not-json".utf8).write(
                to: second.appendingPathComponent("preferences.json")
            )
            let access = RecordingAccessGrantor()
            let revealer = RecordingRevealer()
            let workspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [first, second]),
                bookmarks: SyntheticBookmarks(),
                access: access,
                locatorStore: MemoryLocatorStore(),
                revealer: revealer
            )

            let firstOpen = await workspace.chooseLibrary()
            let failedOpen = await workspace.chooseLibrary()
            let reveal = await workspace.revealActiveLibrary()
            let revealedNames = await revealer.revealedNames
            XCTAssertEqual(firstOpen, .opened(firstAuthority.snapshot))
            XCTAssertEqual(failedOpen, .failed(.candidateCorrupt))
            XCTAssertEqual(reveal, .succeeded())

            XCTAssertEqual(
                access.events,
                ["acquire:First.audoralibrary", "acquire:Second.audoralibrary", "release:Second.audoralibrary"]
            )
            XCTAssertEqual(revealedNames, ["First.audoralibrary"])
        }
    }

    func testBookmarkIdentityMismatchCannotRetargetActiveScope() async throws {
        try await withTwoLibraries { first, second, firstAuthority, _ in
            let access = RecordingAccessGrantor()
            let bookmarks = SyntheticBookmarks()
            let store = MemoryLocatorStore()
            let revealer = RecordingRevealer()
            let workspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [first]),
                bookmarks: bookmarks,
                access: access,
                locatorStore: store,
                revealer: revealer
            )
            let firstOpen = await workspace.chooseLibrary()
            XCTAssertEqual(firstOpen, .opened(firstAuthority.snapshot))

            let secondBookmark = try bookmarks.makeBookmark(for: second)
            try await store.save(
                MachineLibraryLocator(
                    expectedLibraryID: firstAuthority.manifest.libraryID,
                    restoreOnLaunch: true,
                    bookmark: secondBookmark
                )
            )
            let mismatch = await workspace.reopenRecentLibrary()
            let reveal = await workspace.revealActiveLibrary()
            let revealedNames = await revealer.revealedNames
            XCTAssertEqual(mismatch, .failed(.identityMismatch))
            XCTAssertEqual(reveal, .succeeded())
            XCTAssertEqual(revealedNames, ["First.audoralibrary"])
            XCTAssertEqual(
                Array(access.events.suffix(2)),
                ["acquire:Second.audoralibrary", "release:Second.audoralibrary"]
            )
        }
    }

    func testStaleBookmarkRequiresReselectionWithoutAcquiringOrWriting() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Stale.audoralibrary")
            let authority = try PortableLibraryPersistence().create(at: root, seed: makeSeed())
            let bookmarks = SyntheticBookmarks(staleNames: [root.lastPathComponent])
            let bookmark = try bookmarks.makeBookmark(for: root)
            let store = MemoryLocatorStore(
                value: MachineLibraryLocator(
                    expectedLibraryID: authority.manifest.libraryID,
                    restoreOnLaunch: true,
                    bookmark: bookmark
                )
            )
            let access = RecordingAccessGrantor()
            let workspace = PortableLibraryWorkspace(
                locations: QueueLocations(),
                bookmarks: bookmarks,
                access: access,
                locatorStore: store,
                revealer: RecordingRevealer()
            )

            let restore = await workspace.restoreActiveLibrary()
            let saveCount = await store.saveCount
            XCTAssertEqual(restore, .failed(.selectionRequired))
            XCTAssertEqual(access.events, [])
            XCTAssertEqual(saveCount, 0)
        }
    }

    func testLocatorWriteFailureAfterCreateLeavesInstalledLibraryActiveAndRecoverable() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Created.audoralibrary")
            let seed = try makeSeed()
            let revealer = RecordingRevealer()
            let workspace = PortableLibraryWorkspace(
                locations: QueueLocations(create: [root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: FailingLocatorStore(),
                revealer: revealer
            )

            let create = await workspace.createLibrary(seed)
            XCTAssertEqual(
                create,
                .opened(
                    ActiveLibrarySnapshot(
                        libraryID: seed.libraryID,
                        preferences: seed.preferences,
                        profile: .nullProfile(statementCount: 0)
                    ),
                    notice: .locatorUpdateFailed
                )
            )
            guard case .readWrite = try PortableLibraryPersistence().open(at: root) else {
                return XCTFail("committed Library was not recoverable")
            }
            let reveal = await workspace.revealActiveLibrary()
            let revealedNames = await revealer.revealedNames
            XCTAssertEqual(reveal, .succeeded())
            XCTAssertEqual(revealedNames, ["Created.audoralibrary"])
        }
    }

    func testUnavailableOrCorruptMachineStateStartsRecoverablyWithoutLibraryWrite() async throws {
        let unavailableWorkspace = PortableLibraryWorkspace(
            locations: QueueLocations(),
            bookmarks: SyntheticBookmarks(),
            access: RecordingAccessGrantor(),
            locatorStore: UnavailableMachineLibraryLocatorStore(),
            revealer: RecordingRevealer()
        )
        let unavailableRestore = await unavailableWorkspace.restoreActiveLibrary()
        XCTAssertEqual(
            unavailableRestore,
            .noLibrarySelected(recentAvailable: false)
        )

        try await withTemporaryParent { parent in
            let locator = parent.appendingPathComponent("locator.json")
            try Data(#"{"schemaVersion":1}"#.utf8).write(to: locator)
            let workspace = PortableLibraryWorkspace(
                locations: QueueLocations(),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: ApplicationSupportLibraryLocatorStore(fileURL: locator),
                revealer: RecordingRevealer()
            )
            let corruptRestore = await workspace.restoreActiveLibrary()
            XCTAssertEqual(
                corruptRestore,
                .noLibrarySelected(recentAvailable: false)
            )
            XCTAssertEqual(try Data(contentsOf: locator), Data(#"{"schemaVersion":1}"#.utf8))
        }
    }

    func testLocatorReaderBoundsBeforeAllocationAndRejectsSymlinkAndFIFO() async throws {
        try await withTemporaryParent { parent in
            let locator = parent.appendingPathComponent("oversized.json")
            try Data(repeating: 0x20, count: 1_048_577).write(to: locator)
            let store = ApplicationSupportLibraryLocatorStore(fileURL: locator)
            do {
                _ = try await store.load()
                XCTFail("oversized locator unexpectedly loaded")
            } catch {
                // Bounded semantic failure is expected; no bytes are exposed.
            }

            let link = parent.appendingPathComponent("link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: locator)
            let linkedStore = ApplicationSupportLibraryLocatorStore(fileURL: link)
            do {
                _ = try await linkedStore.load()
                XCTFail("symlink locator unexpectedly loaded")
            } catch {
                // No-follow open is the required behavior.
            }

            let fifo = parent.appendingPathComponent("locator.fifo")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            let fifoStore = ApplicationSupportLibraryLocatorStore(fileURL: fifo)
            do {
                _ = try await fifoStore.load()
                XCTFail("FIFO locator unexpectedly loaded")
            } catch {
                // O_NONBLOCK plus exact regular-file fstat prevents a blocking read.
            }
        }
    }

    func testMachineLocatorIsIndependentVersionedAndUserOnly() async throws {
        try await withTemporaryParent { parent in
            let locatorURL = parent.appendingPathComponent("locator.json")
            let store = ApplicationSupportLibraryLocatorStore(fileURL: locatorURL)
            let locator = MachineLibraryLocator(
                expectedLibraryID: try LibraryID("lib-20260830T120000000Z-2ABC"),
                restoreOnLaunch: true,
                bookmark: Data([0x01, 0x02, 0x03])
            )

            try await store.save(locator)
            let loaded = try await store.load()
            XCTAssertEqual(loaded, locator)
            let attributes = try FileManager.default.attributesOfItem(atPath: locatorURL.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        }
    }

    func testConcurrentWorkspaceCreateStartsOnlyOneLocationRequest() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Concurrent.audoralibrary")
            let locations = SuspendedCreateLocations(url: root)
            let workspace = PortableLibraryWorkspace(
                locations: locations,
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            let seed = try makeSeed()

            let first = Task { await workspace.createLibrary(seed) }
            await locations.waitUntilRequested()
            let second = await workspace.createLibrary(seed)
            let countWhileSuspended = await locations.requestCount
            XCTAssertEqual(second, .failed(.createFailed))
            XCTAssertEqual(countWhileSuspended, 1)
            await locations.resume()
            _ = await first.value
            let finalCount = await locations.requestCount
            XCTAssertEqual(finalCount, 1)
        }
    }

    func testRepeatedExternalCallbacksKeepOneCapabilityAndExplicitRevocationLeavesNone() async throws {
        try await withTemporaryParent { parent in
            let firstURL = parent.appendingPathComponent("First.audoralibrary")
            let secondURL = parent.appendingPathComponent("Second.audoralibrary")
            let access = RecordingAccessGrantor()
            let workspace = PortableLibraryWorkspace(
                locations: QueueLocations(),
                bookmarks: SyntheticBookmarks(),
                access: access,
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )

            let first = await workspace.registerExternalOpenRequest(firstURL)
            let second = await workspace.registerExternalOpenRequest(secondURL)
            let pendingAfterReplacement = await workspace.pendingExternalRequestCount
            let expiredFirst = await workspace.openExternalRequest(first)
            await workspace.revokeExternalOpenRequest(second)
            let pendingAfterRevoke = await workspace.pendingExternalRequestCount

            XCTAssertEqual(pendingAfterReplacement, 1)
            XCTAssertEqual(expiredFirst, .failed(.externalOpenRequestExpired))
            XCTAssertEqual(pendingAfterRevoke, 0)
            XCTAssertEqual(access.events, [])
        }
    }

    func testProfileStatementGenerationReadReloadsTheCurrentValidatedHead() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("CurrentProfile.audoralibrary")
            let persistence = PortableLibraryPersistence()
            let authority = try persistence.create(at: root, seed: makeSeed())
            let workspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await workspace.chooseLibrary()
            let changedHead = ProfileHead(
                generation: 9,
                statementGeneration: 7,
                selection: .null,
                updatedAt: try UTCInstant("2026-08-30T12:10:00.000Z")
            )
            try persistence.atomicallyReplaceRoot(
                persistence.encodeProfileHead(changedHead),
                relativePath: LibraryRelativePath("profile/head.json"),
                under: root
            )

            let generation = await workspace.activeProfileStatementGeneration(
                in: LibraryScope(libraryID: authority.manifest.libraryID)
            )

            XCTAssertEqual(generation, 7)
        }
    }

    func testProfileStatementGenerationReadNeverReconcilesActiveAudioImportStaging() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("ActiveImport.audoralibrary")
            let authority = try PortableLibraryPersistence().create(at: root, seed: makeSeed())
            let workspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await workspace.chooseLibrary()
            let activeImport = try makeRecognizedAbandonedAudioImportTree(in: root)

            let generation = await workspace.activeProfileStatementGeneration(
                in: LibraryScope(libraryID: authority.manifest.libraryID)
            )

            XCTAssertEqual(generation, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: activeImport.path))
        }
    }

    func testChatLoadPreservesTheActiveReadOnlyLibraryOutcome() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("ReadOnly.audoralibrary")
            let authority = try PortableLibraryPersistence().create(at: root, seed: makeSeed())
            let preferences = root.appendingPathComponent("preferences.json")
            try Data(
                #"{"annotationsVisible":false,"futurePortablePreference":"preserve","language":"en","playbackRate":1.25,"schemaVersion":2}"#.utf8
            ).write(to: preferences)
            let workspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await workspace.chooseLibrary()
            let store = PortableChatStore(workspace: workspace)

            let outcome = await store.load(
                try ChatID("cht-20260830T120000000Z-2ABC"),
                in: LibraryScope(libraryID: authority.manifest.libraryID)
            )

            XCTAssertEqual(outcome, .readOnlyLibrary)
        }
    }

    func testChatStoreReconcilesCreateCommittedBeforePostcommitFault() async throws {
        let points: [PortableChatFaultPoint] = [
            .afterFinalInstall,
            .afterChatsFlush,
            .beforeFinalRead,
        ]
        for point in points {
            try await withTemporaryParent { parent in
                let root = parent.appendingPathComponent("Create-\(point).audoralibrary")
                let authority = try PortableLibraryPersistence().create(
                    at: root,
                    seed: makeSeed()
                )
                let scope = LibraryScope(libraryID: authority.manifest.libraryID)
                let workspace = PortableLibraryWorkspace(
                    locations: QueueLocations(existing: [root]),
                    bookmarks: SyntheticBookmarks(),
                    access: RecordingAccessGrantor(),
                    locatorStore: MemoryLocatorStore(),
                    revealer: RecordingRevealer()
                )
                _ = await workspace.chooseLibrary()
                let seed = try makeChatSeed(scope: scope)
                let store = PortableChatStore(
                    persistence: PortableChatPersistence { reached in
                        if reached == point {
                            throw PortableChatPersistenceError.injectedFault(point)
                        }
                    },
                    workspace: workspace
                )

                let outcome = await store.create(seed)
                let reopened = await store.load(seed.aggregate.chat.id, in: scope)

                XCTAssertEqual(
                    outcome,
                    .committed(seed.aggregate),
                    String(describing: point)
                )
                XCTAssertEqual(
                    reopened,
                    .loaded(seed.aggregate),
                    String(describing: point)
                )
            }
        }
    }

    func testChatStoreReconcilesRenameCommittedBeforePostcommitFault() async throws {
        let points: [PortableChatFaultPoint] = [
            .afterRenameInstall,
            .afterRenameDirectoryFlush,
            .beforeRenameFinalRead,
        ]
        for point in points {
            try await withTemporaryParent { parent in
                let root = parent.appendingPathComponent("Rename-\(point).audoralibrary")
                let authority = try PortableLibraryPersistence().create(
                    at: root,
                    seed: makeSeed()
                )
                let scope = LibraryScope(libraryID: authority.manifest.libraryID)
                let workspace = PortableLibraryWorkspace(
                    locations: QueueLocations(existing: [root]),
                    bookmarks: SyntheticBookmarks(),
                    access: RecordingAccessGrantor(),
                    locatorStore: MemoryLocatorStore(),
                    revealer: RecordingRevealer()
                )
                _ = await workspace.chooseLibrary()
                let seed = try makeChatSeed(scope: scope)
                let initialStore = PortableChatStore(workspace: workspace)
                let created = await initialStore.create(seed)
                XCTAssertEqual(created, .committed(seed.aggregate))
                let mutation = try RenameChatMutation(
                    library: scope,
                    base: seed.aggregate,
                    title: ChatTitle("Speaking Goals"),
                    updatedAt: UTCInstant("2026-08-30T12:01:00.000Z")
                )
                let store = PortableChatStore(
                    persistence: PortableChatPersistence { reached in
                        if reached == point {
                            throw PortableChatPersistenceError.injectedFault(point)
                        }
                    },
                    workspace: workspace
                )

                let outcome = await store.rename(mutation)
                let reopened = await store.load(mutation.chatID, in: scope)

                XCTAssertEqual(
                    outcome,
                    .committed(mutation.replacement),
                    String(describing: point)
                )
                XCTAssertEqual(
                    reopened,
                    .loaded(mutation.replacement),
                    String(describing: point)
                )
            }
        }
    }

    func testChatStoreReconcilesDraftCommittedBeforePostcommitFault() async throws {
        let points: [PortableChatFaultPoint] = [
            .afterDraftInstall,
            .afterDraftDirectoryFlush,
            .beforeDraftFinalRead,
        ]
        for point in points {
            try await withTemporaryParent { parent in
                let root = parent.appendingPathComponent("Draft-\(point).audoralibrary")
                let authority = try PortableLibraryPersistence().create(
                    at: root,
                    seed: makeSeed()
                )
                let scope = LibraryScope(libraryID: authority.manifest.libraryID)
                let workspace = PortableLibraryWorkspace(
                    locations: QueueLocations(existing: [root]),
                    bookmarks: SyntheticBookmarks(),
                    access: RecordingAccessGrantor(),
                    locatorStore: MemoryLocatorStore(),
                    revealer: RecordingRevealer()
                )
                _ = await workspace.chooseLibrary()
                let seed = try makeChatSeed(scope: scope)
                let initialStore = PortableChatStore(workspace: workspace)
                let created = await initialStore.create(seed)
                XCTAssertEqual(created, .committed(seed.aggregate))
                let draft = try seed.aggregate.chat.draft.edited(
                    text: "Durable synthetic Draft",
                    at: UTCInstant("2026-08-30T12:01:00.000Z")
                )
                let mutation = SaveChatDraftMutation(
                    library: scope,
                    chatID: seed.aggregate.chat.id,
                    replacement: draft
                )
                let store = PortableChatStore(
                    persistence: PortableChatPersistence { reached in
                        if reached == point {
                            throw PortableChatPersistenceError.injectedFault(point)
                        }
                    },
                    workspace: workspace
                )

                let outcome = await store.saveDraft(mutation)
                guard case let .committed(committed) = outcome else {
                    return XCTFail("Draft commit was not reconciled at \(point): \(outcome)")
                }
                XCTAssertEqual(committed.chat.draft, draft)
                let reopened = await store.load(mutation.chatID, in: scope)
                XCTAssertEqual(reopened, .loaded(committed))
            }
        }
    }

    func testChatStoreReconcilesPendingLockCommittedBeforePostcommitFault() async throws {
        let points: [PortableChatFaultPoint] = [
            .afterPendingInstall,
            .afterPendingDirectoryFlush,
            .beforePendingFinalRead,
        ]
        for point in points {
            try await withTemporaryParent { parent in
                let root = parent.appendingPathComponent("Pending-\(point).audoralibrary")
                let authority = try PortableLibraryPersistence().create(
                    at: root,
                    seed: makeSeed()
                )
                let scope = LibraryScope(libraryID: authority.manifest.libraryID)
                let workspace = PortableLibraryWorkspace(
                    locations: QueueLocations(existing: [root]),
                    bookmarks: SyntheticBookmarks(),
                    access: RecordingAccessGrantor(),
                    locatorStore: MemoryLocatorStore(),
                    revealer: RecordingRevealer()
                )
                _ = await workspace.chooseLibrary()
                let seed = try makeChatSeed(scope: scope)
                let initialStore = PortableChatStore(workspace: workspace)
                let created = await initialStore.create(seed)
                XCTAssertEqual(created, .committed(seed.aggregate))
                let pending = PendingUserTurn(
                    id: try PendingUserTurnID("ptu-20260830T120100000Z-5KMN"),
                    draftID: seed.aggregate.chat.draft.draftID,
                    draftVersion: seed.aggregate.chat.draft.version,
                    responsePositionID: try ChatResponsePositionID(
                        "rsp-20260830T120100000Z-6PQR"
                    )
                )
                let mutation = LockPendingUserTurnMutation(
                    library: scope,
                    chatID: seed.aggregate.chat.id,
                    pendingUserTurn: pending
                )
                let store = PortableChatStore(
                    persistence: PortableChatPersistence { reached in
                        if reached == point {
                            throw PortableChatPersistenceError.injectedFault(point)
                        }
                    },
                    workspace: workspace
                )

                let outcome = await store.lockPendingUserTurn(mutation)
                guard case let .committed(committed) = outcome else {
                    return XCTFail("Pending lock was not reconciled at \(point): \(outcome)")
                }
                XCTAssertEqual(committed.pendingUserTurn, pending)
                let reopened = await store.load(mutation.chatID, in: scope)
                XCTAssertEqual(reopened, .loaded(committed))
            }
        }
    }

    func testChatStoreReconcilesPendingFailureReplacementAfterPostcommitFault() async throws {
        let points: [PortableChatFaultPoint] = [
            .afterPendingInstall,
            .afterPendingDirectoryFlush,
            .beforePendingFinalRead,
        ]
        for point in points {
            try await withTemporaryParent { parent in
                let root = parent.appendingPathComponent("Replace-\(point).audoralibrary")
                let authority = try PortableLibraryPersistence().create(
                    at: root,
                    seed: makeSeed()
                )
                let scope = LibraryScope(libraryID: authority.manifest.libraryID)
                let workspace = PortableLibraryWorkspace(
                    locations: QueueLocations(existing: [root]),
                    bookmarks: SyntheticBookmarks(),
                    access: RecordingAccessGrantor(),
                    locatorStore: MemoryLocatorStore(),
                    revealer: RecordingRevealer()
                )
                _ = await workspace.chooseLibrary()
                let seed = try makeChatSeed(scope: scope)
                let initialStore = PortableChatStore(workspace: workspace)
                let created = await initialStore.create(seed)
                XCTAssertEqual(created, .committed(seed.aggregate))
                let pending = PendingUserTurn(
                    id: try PendingUserTurnID("ptu-20260830T120100000Z-5KMN"),
                    draftID: seed.aggregate.chat.draft.draftID,
                    draftVersion: seed.aggregate.chat.draft.version,
                    responsePositionID: try ChatResponsePositionID(
                        "rsp-20260830T120100000Z-6PQR"
                    )
                )
                guard case .committed = await initialStore.lockPendingUserTurn(
                    LockPendingUserTurnMutation(
                        library: scope,
                        chatID: seed.aggregate.chat.id,
                        pendingUserTurn: pending
                    )
                ) else {
                    return XCTFail("Pending setup did not commit")
                }
                let failed = pending.replacingFailure(.coachContextCannotFit)
                let mutation = try ReplacePendingUserTurnMutation(
                    library: scope,
                    chatID: seed.aggregate.chat.id,
                    base: pending,
                    replacement: failed
                )
                let store = PortableChatStore(
                    persistence: PortableChatPersistence { reached in
                        if reached == point {
                            throw PortableChatPersistenceError.injectedFault(point)
                        }
                    },
                    workspace: workspace
                )

                let outcome = await store.replacePendingUserTurn(mutation)
                guard case let .committed(committed) = outcome else {
                    return XCTFail(
                        "Pending replacement was not reconciled at \(point): \(outcome)"
                    )
                }
                XCTAssertEqual(committed.pendingUserTurn, failed)
                let reopened = await store.load(mutation.chatID, in: scope)
                XCTAssertEqual(
                    reopened,
                    .loaded(committed)
                )
            }
        }
    }

    func testChatStoreReconcilesPendingDiscardCommittedBeforePostcommitFault() async throws {
        let points: [PortableChatFaultPoint] = [
            .afterPendingRemoval,
            .afterPendingRemovalDirectoryFlush,
        ]
        for point in points {
            try await withTemporaryParent { parent in
                let root = parent.appendingPathComponent("Discard-\(point).audoralibrary")
                let authority = try PortableLibraryPersistence().create(
                    at: root,
                    seed: makeSeed()
                )
                let scope = LibraryScope(libraryID: authority.manifest.libraryID)
                let workspace = PortableLibraryWorkspace(
                    locations: QueueLocations(existing: [root]),
                    bookmarks: SyntheticBookmarks(),
                    access: RecordingAccessGrantor(),
                    locatorStore: MemoryLocatorStore(),
                    revealer: RecordingRevealer()
                )
                _ = await workspace.chooseLibrary()
                let seed = try makeChatSeed(scope: scope)
                let initialStore = PortableChatStore(workspace: workspace)
                let created = await initialStore.create(seed)
                XCTAssertEqual(created, .committed(seed.aggregate))
                let pending = PendingUserTurn(
                    id: try PendingUserTurnID("ptu-20260830T120100000Z-5KMN"),
                    draftID: seed.aggregate.chat.draft.draftID,
                    draftVersion: seed.aggregate.chat.draft.version,
                    responsePositionID: try ChatResponsePositionID(
                        "rsp-20260830T120100000Z-6PQR"
                    )
                )
                let lock = LockPendingUserTurnMutation(
                    library: scope,
                    chatID: seed.aggregate.chat.id,
                    pendingUserTurn: pending
                )
                guard case .committed = await initialStore.lockPendingUserTurn(lock) else {
                    return XCTFail("Pending setup did not commit")
                }
                let mutation = DiscardPendingUserTurnMutation(
                    library: scope,
                    chatID: seed.aggregate.chat.id,
                    pendingUserTurn: pending
                )
                let store = PortableChatStore(
                    persistence: PortableChatPersistence { reached in
                        if reached == point {
                            throw PortableChatPersistenceError.injectedFault(point)
                        }
                    },
                    workspace: workspace
                )

                let outcome = await store.discardPendingUserTurn(mutation)
                guard case let .committed(committed) = outcome else {
                    return XCTFail("Pending discard was not reconciled at \(point): \(outcome)")
                }
                XCTAssertNil(committed.pendingUserTurn)
                XCTAssertEqual(committed.chat.draft, seed.aggregate.chat.draft)
                let reopened = await store.load(mutation.chatID, in: scope)
                XCTAssertEqual(reopened, .loaded(committed))
            }
        }
    }

    func testChatStoreMapsLibraryIdentityMismatchToFailedInsteadOfCorruptChat() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Retargeted.audoralibrary")
            let authority = try PortableLibraryPersistence().create(at: root, seed: makeSeed())
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let seed = try makeChatSeed(scope: scope)
            _ = try PortableChatPersistence().create(seed, at: root)
            let workspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await workspace.chooseLibrary()
            let replacement = LibraryManifest(
                libraryID: try LibraryID("lib-20260830T121000000Z-5KMN"),
                createdAt: authority.manifest.createdAt
            )
            try PortableLibraryPersistence().encodeManifest(replacement).write(
                to: root.appendingPathComponent("library.json"),
                options: .atomic
            )
            let store = PortableChatStore(workspace: workspace)

            let outcome = await store.load(seed.aggregate.chat.id, in: scope)

            XCTAssertEqual(outcome, .failed)
        }
    }

    func testChatStoreMapsActiveLibraryRootSymlinkToFailedInsteadOfCorruptChat() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("RetargetedRoot.audoralibrary")
            let authority = try PortableLibraryPersistence().create(at: root, seed: makeSeed())
            let workspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await workspace.chooseLibrary()
            let movedRoot = parent.appendingPathComponent("MovedRoot.audoralibrary")
            try FileManager.default.moveItem(at: root, to: movedRoot)
            try FileManager.default.createSymbolicLink(
                at: root,
                withDestinationURL: movedRoot
            )
            let store = PortableChatStore(workspace: workspace)

            let outcome = await store.load(
                try ChatID("cht-20260830T120000000Z-2ABC"),
                in: LibraryScope(libraryID: authority.manifest.libraryID)
            )

            XCTAssertEqual(outcome, .failed)
        }
    }

    private func withTwoLibraries(
        _ body: (
            URL,
            URL,
            PortableLibraryAuthority,
            PortableLibraryAuthority
        ) async throws -> Void
    ) async throws {
        try await withTemporaryParent { parent in
            let first = parent.appendingPathComponent("First.audoralibrary")
            let second = parent.appendingPathComponent("Second.audoralibrary")
            let persistence = PortableLibraryPersistence()
            let firstAuthority = try persistence.create(at: first, seed: makeSeed())
            let secondAuthority = try persistence.create(
                at: second,
                seed: makeSeed(id: "lib-20260830T121000000Z-3DEF")
            )
            try await body(first, second, firstAuthority, secondAuthority)
        }
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

    private func makeInvocationStoreFixture(
        in parent: URL
    ) async throws -> InvocationStoreFixture {
        let root = parent.appendingPathComponent("Invocation.audoralibrary")
        let library = try PortableLibraryPersistence().create(at: root, seed: makeSeed())
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

    private func makeRecognizedAbandonedAudioImportTree(in root: URL) throws -> URL {
        let transaction = root
            .appendingPathComponent("staging/publications", isDirectory: true)
            .appendingPathComponent(
                "audio_staging_0123456789ABCDEF0123456789ABCDEF",
                isDirectory: true
            )
        let session = transaction.appendingPathComponent(
            "ses-20260830T120000000Z-3DEF",
            isDirectory: true
        )
        for directory in [
            session.appendingPathComponent("audio", isDirectory: true),
            session.appendingPathComponent("transcripts", isDirectory: true),
            session.appendingPathComponent("annotations", isDirectory: true),
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try Data("incomplete".utf8).write(
            to: session.appendingPathComponent(
                ".session.json.11111111-1111-1111-1111-111111111111.partial"
            )
        )
        try Data("incomplete".utf8).write(
            to: session.appendingPathComponent("audio").appendingPathComponent(
                ".audio.json.22222222-2222-2222-2222-222222222222.partial"
            )
        )
        return transaction
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

private actor SuspendedCreateLocations: LibraryLocationChoosing {
    private let url: URL
    private(set) var requestCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(url: URL) { self.url = url }

    func chooseCreateDestination() async -> URL? {
        requestCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return url
    }

    func chooseExistingLibrary() async -> URL? { nil }

    func waitUntilRequested() async {
        while requestCount == 0 { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
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

private struct FailingLocatorStore: MachineLibraryLocatorStoring {
    func load() async throws -> MachineLibraryLocator? { nil }
    func save(_ locator: MachineLibraryLocator) async throws {
        throw CocoaError(.fileWriteUnknown)
    }
}

private actor RecordingRevealer: LibraryRevealing {
    private(set) var revealedNames: [String] = []

    func reveal(_ url: URL) async -> Bool {
        revealedNames.append(url.lastPathComponent)
        return true
    }
}
