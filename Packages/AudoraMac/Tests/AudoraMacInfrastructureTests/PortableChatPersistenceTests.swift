import AudoraApplication
import AudoraContracts
import AudoraDomain
@testable import AudoraMacInfrastructure
import Darwin
import Foundation
import XCTest

final class PortableChatPersistenceTests: XCTestCase {
    func testCreatePublishesExactCanonicalTreeAndReopensSameAggregate() throws {
        try withCreatedLibrary { root, scope in
            let persistence = PortableChatPersistence()
            let seed = try makeChatSeed(scope: scope)

            let created = try persistence.create(seed, at: root)
            let reopened = try persistence.load(created.chat.id, at: root, in: scope)

            XCTAssertEqual(created, seed.aggregate)
            XCTAssertEqual(reopened, .readWrite(created))
            XCTAssertEqual(try tree(at: chatRoot(root, created.chat.id)), [
                "chat.json",
                "memory/",
                "memory/\(created.memory.memoryID.rawValue).json",
                "messages/",
            ].sorted())
            XCTAssertEqual(
                try Data(contentsOf: chatRoot(root, created.chat.id).appendingPathComponent("chat.json")),
                try persistence.encodeChat(created.chat)
            )
            XCTAssertEqual(
                try Data(contentsOf: chatRoot(root, created.chat.id)
                    .appendingPathComponent("memory/\(created.memory.memoryID.rawValue).json")),
                try persistence.encodeMemory(created.memory)
            )
        }
    }

    func testChatValidationNeverReconcilesActiveAudioImportStaging() throws {
        try withCreatedLibrary { root, scope in
            let activeImport = try makeRecognizedAbandonedAudioImportTree(in: root)
            let persistence = PortableChatPersistence()

            let created = try persistence.create(makeChatSeed(scope: scope), at: root)
            XCTAssertTrue(FileManager.default.fileExists(atPath: activeImport.path))

            _ = try persistence.load(created.chat.id, at: root, in: scope)
            XCTAssertTrue(FileManager.default.fileExists(atPath: activeImport.path))
        }
    }

    func testDestinationAppearingAtFinalCommitIsNeverOverwritten() throws {
        try withCreatedLibrary { root, scope in
            let seed = try makeChatSeed(scope: scope)
            let destination = chatRoot(root, seed.aggregate.chat.id)
            let persistence = PortableChatPersistence { point in
                guard point == .beforeFinalInstall else { return }
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
                try Data("keep".utf8).write(
                    to: destination.appendingPathComponent("sentinel.txt")
                )
            }

            XCTAssertThrowsError(try persistence.create(seed, at: root)) { error in
                XCTAssertEqual(error as? PortableChatPersistenceError, .collision)
            }
            XCTAssertEqual(
                try Data(contentsOf: destination.appendingPathComponent("sentinel.txt")),
                Data("keep".utf8)
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: root.appendingPathComponent("staging/publications").path
                ),
                []
            )
        }
    }

    func testCreateRejectsStagedDirectoryReplacementBeforeFinalInstall() throws {
        try withCreatedLibrary { root, scope in
            let seed = try makeChatSeed(scope: scope)
            let publications = root.appendingPathComponent(
                "staging/publications",
                isDirectory: true
            )
            let displaced = publications.appendingPathComponent(
                "displaced-validated-candidate",
                isDirectory: true
            )
            let persistence = PortableChatPersistence { point in
                guard point == .beforeFinalInstall else { return }
                let candidates = try FileManager.default.contentsOfDirectory(
                    at: publications,
                    includingPropertiesForKeys: nil
                ).filter {
                    $0.lastPathComponent.hasPrefix("chat-\(seed.aggregate.chat.id.rawValue)-")
                }
                guard candidates.count == 1, let candidate = candidates.first else {
                    throw PortableChatPersistenceError.ioFailure
                }
                try FileManager.default.moveItem(at: candidate, to: displaced)
                try FileManager.default.copyItem(at: displaced, to: candidate)
            }

            XCTAssertThrowsError(try persistence.create(seed, at: root)) { error in
                XCTAssertEqual(error as? PortableChatPersistenceError, .invalidLayout)
            }
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: chatRoot(root, seed.aggregate.chat.id).path
                )
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: publications.path).count,
                2
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: displaced.path))
        }
    }

    func testProfileGenerationChangingDuringStagingRejectsTheFinalInstall() throws {
        try withCreatedLibrary { root, scope in
            let seed = try makeChatSeed(scope: scope)
            let persistence = PortableChatPersistence { point in
                guard point == .beforeFinalInstall else { return }
                let library = PortableLibraryPersistence()
                let changedHead = ProfileHead(
                    generation: 8,
                    statementGeneration: 8,
                    selection: .null,
                    updatedAt: try UTCInstant("2026-08-30T12:01:00.000Z")
                )
                try library.atomicallyReplaceRoot(
                    library.encodeProfileHead(changedHead),
                    relativePath: try LibraryRelativePath("profile/head.json"),
                    under: root
                )
            }

            XCTAssertThrowsError(try persistence.create(seed, at: root)) { error in
                XCTAssertEqual(
                    error as? PortableChatPersistenceError,
                    .profileStatementGenerationChanged(8)
                )
            }
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: chatRoot(root, seed.aggregate.chat.id).path
                )
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: root.appendingPathComponent("staging/publications").path
                ),
                []
            )
        }
    }

    func testLibraryIdentityChangingDuringStagingRejectsTheFinalInstall() throws {
        try withCreatedLibrary { root, scope in
            let seed = try makeChatSeed(scope: scope)
            let persistence = PortableChatPersistence { point in
                guard point == .beforeFinalInstall else { return }
                let library = PortableLibraryPersistence()
                let replacement = LibraryManifest(
                    libraryID: try LibraryID("lib-20260830T121000000Z-5KMN"),
                    createdAt: try UTCInstant("2026-08-30T11:59:00.000Z")
                )
                try library.encodeManifest(replacement).write(
                    to: root.appendingPathComponent("library.json"),
                    options: .atomic
                )
            }

            XCTAssertThrowsError(try persistence.create(seed, at: root)) { error in
                XCTAssertEqual(
                    error as? PortableChatPersistenceError,
                    .libraryScopeMismatch
                )
            }
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: chatRoot(root, seed.aggregate.chat.id).path
                )
            )
        }
    }

    func testCreateFaultsLeaveChatAbsentOrFullyCoherent() throws {
        let points: [PortableChatFaultPoint] = [
            .candidateCreated, .messagesDirectoryCreated, .memoryDirectoryCreated,
            .beforeMemoryPartialWrite, .afterMemoryPartialWrite, .afterMemoryFileFlush,
            .afterMemoryInstall, .afterMemoryDirectoryFlush, .beforeChatPartialWrite,
            .afterChatPartialWrite, .afterChatFileFlush, .afterChatInstall,
            .afterCandidateFlush, .beforeStagedRead, .beforeFinalInstall,
            .afterFinalInstall, .afterChatsFlush, .beforeFinalRead,
        ]
        for point in points {
            try withCreatedLibrary { root, scope in
                let seed = try makeChatSeed(scope: scope)
                let persistence = PortableChatPersistence { reached in
                    if reached == point {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                }
                XCTAssertThrowsError(try persistence.create(seed, at: root), String(describing: point))

                let destination = chatRoot(root, seed.aggregate.chat.id)
                if FileManager.default.fileExists(atPath: destination.path) {
                    XCTAssertEqual(
                        try PortableChatPersistence().load(
                            seed.aggregate.chat.id,
                            at: root,
                            in: scope
                        ),
                        .readWrite(seed.aggregate)
                    )
                }
                XCTAssertEqual(
                    try FileManager.default.contentsOfDirectory(
                        atPath: root.appendingPathComponent("staging/publications").path
                    ),
                    []
                )
            }
        }
    }

    func testRenameUsesRevisionCASAndPreservesMemoryBytesAndIdentity() throws {
        try withCreatedLibrary { root, scope in
            let persistence = PortableChatPersistence()
            let original = try persistence.create(makeChatSeed(scope: scope), at: root)
            let memoryURL = chatRoot(root, original.chat.id)
                .appendingPathComponent("memory/\(original.memory.memoryID.rawValue).json")
            let memoryBytes = try Data(contentsOf: memoryURL)
            let renamedAt = try UTCInstant("2026-08-30T12:01:00.000Z")

            let outcome = try persistence.rename(
                RenameChatMutation(
                    library: scope,
                    base: original,
                    title: ChatTitle("Speaking Goals"),
                    updatedAt: renamedAt
                ),
                at: root
            )
            guard case let .renamed(renamed) = outcome else {
                return XCTFail("rename did not commit")
            }
            XCTAssertEqual(renamed.chat.id, original.chat.id)
            XCTAssertEqual(renamed.chat.draft, original.chat.draft)
            XCTAssertEqual(renamed.chat.attachments, original.chat.attachments)
            XCTAssertEqual(renamed.memory, original.memory)
            XCTAssertEqual(renamed.chat.manifestRevision, 1)
            XCTAssertEqual(try Data(contentsOf: memoryURL), memoryBytes)

            let stale = try persistence.rename(
                RenameChatMutation(
                    library: scope,
                    base: original,
                    title: ChatTitle("Lost Update"),
                    updatedAt: renamedAt
                ),
                at: root
            )
            XCTAssertEqual(stale, .stale(renamed))
        }
    }

    func testDelayedOlderDraftSaveCannotOverwriteNewerFlushedVersion() throws {
        try withCreatedChat { root, scope, original in
            let persistence = PortableChatPersistence()
            let first = try original.chat.draft.edited(
                text: "older autosave",
                at: UTCInstant("2026-08-30T12:00:01.000Z")
            )
            let second = try first.edited(
                text: "newer synchronous flush",
                at: UTCInstant("2026-08-30T12:00:02.000Z")
            )

            let flushed = try persistence.saveDraft(
                SaveChatDraftMutation(
                    library: scope,
                    chatID: original.chat.id,
                    replacement: second
                ),
                at: root
            )
            guard case let .committed(current) = flushed else {
                return XCTFail("newer Draft did not commit")
            }

            let delayed = try persistence.saveDraft(
                SaveChatDraftMutation(
                    library: scope,
                    chatID: original.chat.id,
                    replacement: first
                ),
                at: root
            )

            XCTAssertEqual(delayed, .stale(current))
            XCTAssertEqual(
                try persistence.load(original.chat.id, at: root, in: scope),
                .readWrite(current)
            )
            XCTAssertEqual(current.chat.draft, second)
        }
    }

    func testPendingUserTurnReopensAndDiscardUnlocksSameDraftWithoutMessages() throws {
        try withCreatedChat { root, scope, original in
            let persistence = PortableChatPersistence()
            let draft = try original.chat.draft.edited(
                text: "Keep this exact populated Draft.",
                at: UTCInstant("2026-08-30T12:00:01.000Z")
            )
            guard case let .committed(saved) = try persistence.saveDraft(
                SaveChatDraftMutation(
                    library: scope,
                    chatID: original.chat.id,
                    replacement: draft
                ),
                at: root
            ) else {
                return XCTFail("Draft did not save")
            }
            let pending = PendingUserTurn(
                id: try PendingUserTurnID("ptu-20260830T120001000Z-5KMN"),
                draftID: draft.draftID,
                draftVersion: draft.version,
                responsePositionID: try ChatResponsePositionID(
                    "rsp-20260830T120001000Z-6PQR"
                )
            )

            guard case let .committed(locked) = try persistence.lockPendingUserTurn(
                LockPendingUserTurnMutation(
                    library: scope,
                    chatID: saved.chat.id,
                    pendingUserTurn: pending
                ),
                at: root
            ) else {
                return XCTFail("Pending User Turn did not lock")
            }
            XCTAssertEqual(locked.pendingUserTurn, pending)
            XCTAssertEqual(locked.chat.messageIDs, [])
            XCTAssertEqual(
                try persistence.load(saved.chat.id, at: root, in: scope),
                .readWrite(locked)
            )

            let discard = DiscardPendingUserTurnMutation(
                library: scope,
                chatID: saved.chat.id,
                pendingUserTurn: pending
            )
            guard case let .committed(unlocked) = try persistence.discardPendingUserTurn(
                discard,
                at: root
            ) else {
                return XCTFail("Pending User Turn did not discard")
            }
            XCTAssertNil(unlocked.pendingUserTurn)
            XCTAssertEqual(unlocked.chat.draft, draft)
            XCTAssertEqual(unlocked.chat.messageIDs, [])
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: chatRoot(root, saved.chat.id)
                        .appendingPathComponent("pending-user-turn.json").path
                )
            )
            XCTAssertEqual(
                try persistence.load(saved.chat.id, at: root, in: scope),
                .readWrite(unlocked)
            )
            XCTAssertEqual(
                try persistence.discardPendingUserTurn(discard, at: root),
                .committed(unlocked)
            )
        }
    }

    func testCapacityFailureReplacementPersistsWithoutChangingPendingIdentity() throws {
        try withCreatedChat { root, scope, original in
            let persistence = PortableChatPersistence()
            let pending = PendingUserTurn(
                id: try PendingUserTurnID("ptu-20260830T120001000Z-5KMN"),
                draftID: original.chat.draft.draftID,
                draftVersion: original.chat.draft.version,
                responsePositionID: try ChatResponsePositionID(
                    "rsp-20260830T120001000Z-6PQR"
                )
            )
            guard case .committed = try persistence.lockPendingUserTurn(
                LockPendingUserTurnMutation(
                    library: scope,
                    chatID: original.chat.id,
                    pendingUserTurn: pending
                ),
                at: root
            ) else {
                return XCTFail("Pending User Turn did not lock")
            }
            let failed = pending.replacingFailure(.coachContextCannotFit)
            let mutation = try ReplacePendingUserTurnMutation(
                library: scope,
                chatID: original.chat.id,
                base: pending,
                replacement: failed
            )

            guard case let .committed(replaced) = try persistence.replacePendingUserTurn(
                mutation,
                at: root
            ) else {
                return XCTFail("Pending User Turn failure did not replace")
            }

            XCTAssertEqual(replaced.pendingUserTurn, failed)
            XCTAssertEqual(replaced.chat, original.chat)
            XCTAssertEqual(replaced.memory, original.memory)
            XCTAssertEqual(
                try persistence.load(original.chat.id, at: root, in: scope),
                .readWrite(replaced)
            )
            XCTAssertEqual(
                try persistence.replacePendingUserTurn(mutation, at: root),
                .committed(replaced)
            )
            let retryMutation = try ReplacePendingUserTurnMutation(
                library: scope,
                chatID: original.chat.id,
                base: failed,
                replacement: pending
            )
            guard case let .committed(retried) = try persistence.replacePendingUserTurn(
                retryMutation,
                at: root
            ) else {
                return XCTFail("Pending User Turn failure did not clear")
            }
            XCTAssertEqual(retried.pendingUserTurn, pending)
            XCTAssertEqual(
                try persistence.load(original.chat.id, at: root, in: scope),
                .readWrite(retried)
            )
        }
    }

    func testCapacityFailureReplacementReconcilesPostcommitFault() throws {
        try withCreatedChat { root, scope, original in
            let baseline = PortableChatPersistence()
            let pending = PendingUserTurn(
                id: try PendingUserTurnID("ptu-20260830T120001000Z-5KMN"),
                draftID: original.chat.draft.draftID,
                draftVersion: original.chat.draft.version,
                responsePositionID: try ChatResponsePositionID(
                    "rsp-20260830T120001000Z-6PQR"
                )
            )
            guard case .committed = try baseline.lockPendingUserTurn(
                LockPendingUserTurnMutation(
                    library: scope,
                    chatID: original.chat.id,
                    pendingUserTurn: pending
                ),
                at: root
            ) else {
                return XCTFail("Pending User Turn did not lock")
            }
            let failed = pending.replacingFailure(.coachContextCannotFit)
            let mutation = try ReplacePendingUserTurnMutation(
                library: scope,
                chatID: original.chat.id,
                base: pending,
                replacement: failed
            )
            let faulting = PortableChatPersistence { point in
                guard point == .afterPendingInstall else { return }
                throw PortableChatPersistenceError.injectedFault(point)
            }

            XCTAssertThrowsError(
                try faulting.replacePendingUserTurn(mutation, at: root)
            ) { error in
                XCTAssertEqual(
                    error as? PortableChatPersistenceError,
                    .injectedFault(.afterPendingInstall)
                )
            }
            XCTAssertEqual(
                try baseline.load(original.chat.id, at: root, in: scope),
                .readWrite(
                    try ChatAggregate(
                        chat: original.chat,
                        memory: original.memory,
                        pendingUserTurn: failed
                    )
                )
            )
        }
    }

    func testReopenReconcilesExactDraftAndPendingPartialsLeftByACrashedProcess() throws {
        try withCreatedChat { root, scope, aggregate in
            let chat = chatRoot(root, aggregate.chat.id)
            let draftPartial = chat.appendingPathComponent(
                ".chat.json.11111111-1111-1111-1111-111111111111.partial"
            )
            let pendingPartial = chat.appendingPathComponent(
                ".pending-user-turn.json.22222222-2222-2222-2222-222222222222.partial"
            )
            try Data("crashed Draft write".utf8).write(to: draftPartial)
            try Data("crashed Pending User Turn write".utf8).write(to: pendingPartial)

            let reopened = try PortableChatPersistence().load(
                aggregate.chat.id,
                at: root,
                in: scope
            )

            XCTAssertEqual(reopened, .readWrite(aggregate))
            XCTAssertFalse(FileManager.default.fileExists(atPath: draftPartial.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: pendingPartial.path))
        }
    }

    func testOrdinaryReadWaitsForActiveWriterBeforeReconcilingItsPartial() async throws {
        try await withCreatedLibraryAsync { root, scope in
            let original = try PortableChatPersistence().create(
                makeChatSeed(scope: scope),
                at: root
            )
            let replacement = try original.chat.draft.edited(
                text: "Writer-owned synthetic Draft",
                at: UTCInstant("2026-08-30T12:00:01.000Z")
            )
            let gate = BlockingPersistenceFaultGate()
            let writerPersistence = PortableChatPersistence { point in
                guard point == .afterDraftPartialWrite else { return }
                gate.reachAndWait()
            }
            let writer = Task.detached {
                try writerPersistence.saveDraft(
                    SaveChatDraftMutation(
                        library: scope,
                        chatID: original.chat.id,
                        replacement: replacement
                    ),
                    at: root
                )
            }
            await gate.waitUntilReached()

            let readerProgress = PersistenceReaderProgress()
            let reader = Task.detached {
                await readerProgress.markStarted()
                let loaded = try PortableChatPersistence().load(
                    original.chat.id,
                    at: root,
                    in: scope
                )
                await readerProgress.markFinished()
                return loaded
            }
            await readerProgress.waitUntilStarted()
            try await Task.sleep(nanoseconds: 50_000_000)
            let finishedWhileWriterHeldLock = await readerProgress.isFinished
            XCTAssertFalse(
                finishedWhileWriterHeldLock,
                "Read reconciled a live writer partial instead of waiting for its Chat lock"
            )

            gate.release()
            let written = try await writer.value
            let loaded = try await reader.value
            guard case let .committed(committed) = written else {
                return XCTFail("active writer lost its partial")
            }
            XCTAssertEqual(committed.chat.draft, replacement)
            XCTAssertEqual(loaded, .readWrite(committed))
        }
    }

    func testDirectLoadWaitsForCreateCandidatePublication() async throws {
        try await withCreatedLibraryAsync { root, scope in
            let seed = try makeChatSeed(scope: scope)
            let gate = BlockingPersistenceFaultGate()
            let creator = PortableChatPersistence { point in
                guard point == .afterCandidateFlush else { return }
                gate.reachAndWait()
            }
            let create = Task.detached { try creator.create(seed, at: root) }
            await gate.waitUntilReached()

            let progress = PersistenceReaderProgress()
            let read = Task.detached {
                await progress.markStarted()
                do {
                    let loaded = try PortableChatPersistence().load(
                        seed.aggregate.chat.id,
                        at: root,
                        in: scope
                    )
                    await progress.markFinished()
                    return loaded
                } catch {
                    await progress.markFinished()
                    throw error
                }
            }
            await progress.waitUntilStarted()
            try await Task.sleep(nanoseconds: 50_000_000)
            let loadFinishedDuringCreate = await progress.isFinished
            XCTAssertFalse(loadFinishedDuringCreate, "load crossed live create staging")

            gate.release()
            let installed = try await create.value
            let loaded = try await read.value
            XCTAssertEqual(installed, seed.aggregate)
            XCTAssertEqual(loaded, .readWrite(installed))
        }
    }

    func testCatalogLoadWaitsForNewlyCreatedCandidate() async throws {
        try await withCreatedLibraryAsync { root, scope in
            let seed = try makeChatSeed(scope: scope)
            let gate = BlockingPersistenceFaultGate()
            let creator = PortableChatPersistence { point in
                guard point == .candidateCreated else { return }
                gate.reachAndWait()
            }
            let create = Task.detached { try creator.create(seed, at: root) }
            await gate.waitUntilReached()

            let progress = PersistenceReaderProgress()
            let read = Task.detached {
                await progress.markStarted()
                do {
                    let loaded = try PortableChatPersistence().loadCatalog(
                        at: root,
                        in: scope
                    )
                    await progress.markFinished()
                    return loaded
                } catch {
                    await progress.markFinished()
                    throw error
                }
            }
            await progress.waitUntilStarted()
            try await Task.sleep(nanoseconds: 50_000_000)
            let catalogFinishedDuringCreate = await progress.isFinished
            XCTAssertFalse(catalogFinishedDuringCreate, "catalog crossed live create staging")

            gate.release()
            let installed = try await create.value
            let catalog = try await read.value
            XCTAssertEqual(installed, seed.aggregate)
            XCTAssertEqual(catalog, [.readWrite(installed)])
        }
    }

    func testLibraryIdentityChangingBeforeRenameInstallLeavesOriginalChatUnchanged() throws {
        try withCreatedChat { root, scope, original in
            let manifestURL = chatRoot(root, original.chat.id).appendingPathComponent("chat.json")
            let originalBytes = try Data(contentsOf: manifestURL)
            let mutation = try RenameChatMutation(
                library: scope,
                base: original,
                title: ChatTitle("Speaking Goals"),
                updatedAt: UTCInstant("2026-08-30T12:01:00.000Z")
            )
            let persistence = PortableChatPersistence { point in
                guard point == .afterRenameFileFlush else { return }
                let replacement = LibraryManifest(
                    libraryID: try LibraryID("lib-20260830T121000000Z-5KMN"),
                    createdAt: try UTCInstant("2026-08-30T11:59:00.000Z")
                )
                try PortableLibraryPersistence().encodeManifest(replacement).write(
                    to: root.appendingPathComponent("library.json"),
                    options: .atomic
                )
            }

            XCTAssertThrowsError(try persistence.rename(mutation, at: root)) { error in
                XCTAssertEqual(
                    error as? PortableChatPersistenceError,
                    .libraryScopeMismatch
                )
            }
            XCTAssertEqual(try Data(contentsOf: manifestURL), originalBytes)
        }
    }

    func testRenameCommitAuthorityPreservesConcurrentValidRename() throws {
        try withCreatedChat { root, scope, original in
            let manifestURL = chatRoot(root, original.chat.id).appendingPathComponent("chat.json")
            let concurrent = try RenameChatMutation(
                library: scope,
                base: original,
                title: ChatTitle("Other Writer"),
                updatedAt: UTCInstant("2026-08-30T12:01:00.000Z")
            )
            let concurrentBytes = try PortableChatPersistence().encodeChat(
                concurrent.replacement.chat
            )
            let requested = try RenameChatMutation(
                library: scope,
                base: original,
                title: ChatTitle("Speaking Goals"),
                updatedAt: UTCInstant("2026-08-30T12:02:00.000Z")
            )
            let persistence = PortableChatPersistence { point in
                guard point == .afterRenameFileFlush else { return }
                try concurrentBytes.write(to: manifestURL, options: .atomic)
            }

            let outcome = try persistence.rename(requested, at: root)

            XCTAssertEqual(outcome, .stale(concurrent.replacement))
            XCTAssertEqual(try Data(contentsOf: manifestURL), concurrentBytes)
        }
    }

    func testRenameCommitAuthorityFreezesConcurrentNewerAndCorruptReplacements() throws {
        let replacements: [(Data, FrozenChatReason)] = [
            (Data(#"{"futurePortableField":"preserve","schemaVersion":2}"#.utf8), .newerSchema),
            (Data("not-json".utf8), .corrupt),
        ]
        for (replacementBytes, expectedReason) in replacements {
            try withCreatedChat { root, scope, original in
                let manifestURL = chatRoot(root, original.chat.id)
                    .appendingPathComponent("chat.json")
                let requested = try RenameChatMutation(
                    library: scope,
                    base: original,
                    title: ChatTitle("Speaking Goals"),
                    updatedAt: UTCInstant("2026-08-30T12:01:00.000Z")
                )
                let persistence = PortableChatPersistence { point in
                    guard point == .afterRenameFileFlush else { return }
                    try replacementBytes.write(to: manifestURL, options: .atomic)
                }

                let outcome = try persistence.rename(requested, at: root)

                XCTAssertEqual(
                    outcome,
                    .frozen(FrozenChatSnapshot(chatID: original.chat.id, reason: expectedReason))
                )
                XCTAssertEqual(try Data(contentsOf: manifestURL), replacementBytes)
            }
        }
    }

    func testRenameCommitAuthorityRejectsCanonicalChatDirectoryReplacement() throws {
        try withCreatedChat { root, scope, original in
            let canonical = chatRoot(root, original.chat.id)
            let originalBytes = try Data(contentsOf: canonical.appendingPathComponent("chat.json"))
            let displaced = root.appendingPathComponent(
                "staging/publications/displaced-chat",
                isDirectory: true
            )
            let requested = try RenameChatMutation(
                library: scope,
                base: original,
                title: ChatTitle("Speaking Goals"),
                updatedAt: UTCInstant("2026-08-30T12:01:00.000Z")
            )
            let persistence = PortableChatPersistence { point in
                guard point == .afterRenameFileFlush else { return }
                try FileManager.default.moveItem(at: canonical, to: displaced)
                try FileManager.default.copyItem(at: displaced, to: canonical)
            }

            XCTAssertThrowsError(try persistence.rename(requested, at: root)) { error in
                XCTAssertEqual(error as? PortableChatPersistenceError, .invalidLayout)
            }
            XCTAssertEqual(
                try Data(contentsOf: canonical.appendingPathComponent("chat.json")),
                originalBytes
            )
            XCTAssertEqual(
                try Data(contentsOf: displaced.appendingPathComponent("chat.json")),
                originalBytes
            )
        }
    }

    func testRenameFaultsLeaveTheCompleteOldOrNewManifestAndStableSiblingBytes() throws {
        let points: [PortableChatFaultPoint] = [
            .beforeRenamePartialWrite, .afterRenamePartialWrite, .afterRenameFileFlush,
            .afterRenameInstall, .afterRenameDirectoryFlush, .beforeRenameFinalRead,
        ]
        for point in points {
            try withCreatedChat { root, scope, original in
                let chat = chatRoot(root, original.chat.id)
                let memoryURL = chat.appendingPathComponent(
                    "memory/\(original.memory.memoryID.rawValue).json"
                )
                let memoryBytes = try Data(contentsOf: memoryURL)
                let sentinelURL = chat.appendingPathComponent("synthetic-sibling.txt")
                let sentinelBytes = Data("keep".utf8)
                try sentinelBytes.write(to: sentinelURL)
                let persistence = PortableChatPersistence { reached in
                    if reached == point {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                }

                XCTAssertThrowsError(
                    try persistence.rename(
                        RenameChatMutation(
                            library: scope,
                            base: original,
                            title: ChatTitle("Speaking Goals"),
                            updatedAt: UTCInstant("2026-08-30T12:01:00.000Z")
                        ),
                        at: root
                    ),
                    String(describing: point)
                )

                guard case let .readWrite(reopened) = try PortableChatPersistence().load(
                    original.chat.id,
                    at: root,
                    in: scope
                ) else {
                    return XCTFail("fault left a frozen Chat: \(point)")
                }
                XCTAssertEqual(reopened.chat.id, original.chat.id)
                XCTAssertEqual(reopened.chat.createdAt, original.chat.createdAt)
                XCTAssertEqual(reopened.chat.draft, original.chat.draft)
                XCTAssertEqual(reopened.chat.attachments, original.chat.attachments)
                XCTAssertEqual(reopened.memory, original.memory)
                let renamedTitle = try ChatTitle("Speaking Goals")
                XCTAssertTrue(
                    (reopened.chat.manifestRevision == 0 && reopened.chat.title == .newChat) ||
                        (reopened.chat.manifestRevision == 1 &&
                            reopened.chat.title == renamedTitle)
                )
                XCTAssertEqual(try Data(contentsOf: memoryURL), memoryBytes)
                XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinelBytes)
                XCTAssertFalse(
                    try FileManager.default.contentsOfDirectory(atPath: chat.path)
                        .contains(where: { $0.hasSuffix(".partial") })
                )
            }
        }
    }

    func testStrictRootsRejectUnknownKeysOversizeFIFOAndSymlinkWithoutFollowing() throws {
        try withCreatedChat { root, scope, aggregate in
            let manifest = chatRoot(root, aggregate.chat.id).appendingPathComponent("chat.json")
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
            )
            object["modelPath"] = "synthetic"
            try JSONSerialization.data(withJSONObject: object).write(to: manifest)
            try assertChatFreezesAsCorrupt(aggregate.chat.id, at: root, in: scope)
        }

        try withCreatedChat { root, scope, aggregate in
            let manifest = chatRoot(root, aggregate.chat.id).appendingPathComponent("chat.json")
            try Data(repeating: 0x20, count: PortableChatPersistence.maximumRootBytes + 1)
                .write(to: manifest)
            try assertChatFreezesAsCorrupt(aggregate.chat.id, at: root, in: scope)
        }

        try withCreatedChat { root, scope, aggregate in
            let manifest = chatRoot(root, aggregate.chat.id).appendingPathComponent("chat.json")
            try FileManager.default.removeItem(at: manifest)
            XCTAssertEqual(mkfifo(manifest.path, 0o600), 0)
            try assertChatFreezesAsCorrupt(aggregate.chat.id, at: root, in: scope)
        }

        try withCreatedChat { root, scope, aggregate in
            let manifest = chatRoot(root, aggregate.chat.id).appendingPathComponent("chat.json")
            try FileManager.default.removeItem(at: manifest)
            try FileManager.default.createSymbolicLink(
                at: manifest,
                withDestinationURL: URL(fileURLWithPath: "/dev/null")
            )
            try assertChatFreezesAsCorrupt(aggregate.chat.id, at: root, in: scope)
        }
    }

    func testNewerChatFreezesAndRenamePreservesBytesExactly() throws {
        try withCreatedChat { root, scope, aggregate in
            let manifest = chatRoot(root, aggregate.chat.id).appendingPathComponent("chat.json")
            let newer = Data(
                #"{"futurePortableField":"preserve","schemaVersion":2}"#.utf8
            )
            try newer.write(to: manifest)

            XCTAssertEqual(
                try PortableChatPersistence().load(aggregate.chat.id, at: root, in: scope),
                .frozen(FrozenChatSnapshot(chatID: aggregate.chat.id, reason: .newerSchema))
            )
            XCTAssertEqual(
                try PortableChatPersistence().rename(
                    RenameChatMutation(
                        library: scope,
                        base: aggregate,
                        title: ChatTitle("Do Not Write"),
                        updatedAt: UTCInstant("2026-08-30T12:01:00.000Z")
                    ),
                    at: root
                ),
                .frozen(FrozenChatSnapshot(chatID: aggregate.chat.id, reason: .newerSchema))
            )
            XCTAssertEqual(try Data(contentsOf: manifest), newer)
        }
    }

    func testNewerChatFreezesBeforeAssumingTheCurrentVersionChildLayout() throws {
        try withCreatedChat { root, scope, aggregate in
            let chat = chatRoot(root, aggregate.chat.id)
            let manifest = chat.appendingPathComponent("chat.json")
            let renamePartial = chat.appendingPathComponent(
                ".chat.json.44444444-4444-4444-4444-444444444444.partial"
            )
            let newer = Data(
                #"{"futurePortableField":"preserve","schemaVersion":2}"#.utf8
            )
            try newer.write(to: manifest)
            try Data("future-owned".utf8).write(to: renamePartial)
            try FileManager.default.removeItem(at: chat.appendingPathComponent("messages"))
            try FileManager.default.removeItem(at: chat.appendingPathComponent("memory"))

            XCTAssertEqual(
                try PortableChatPersistence().load(aggregate.chat.id, at: root, in: scope),
                .frozen(FrozenChatSnapshot(chatID: aggregate.chat.id, reason: .newerSchema))
            )
            XCTAssertEqual(try Data(contentsOf: manifest), newer)
            XCTAssertEqual(try Data(contentsOf: renamePartial), Data("future-owned".utf8))
        }
    }

    func testRelaunchPreservesNameShapedCandidatesWithUnknownOrOversizedLayouts() throws {
        try withCreatedChat { root, scope, aggregate in
            let publications = root.appendingPathComponent("staging/publications", isDirectory: true)
            let unknownCandidate = publications.appendingPathComponent(
                "chat-\(aggregate.chat.id.rawValue)-55555555-5555-5555-5555-555555555555",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: unknownCandidate,
                withIntermediateDirectories: false
            )
            let unknownChild = unknownCandidate.appendingPathComponent("not-owned.txt")
            try Data("keep".utf8).write(to: unknownChild)

            let oversizedCandidate = publications.appendingPathComponent(
                "chat-\(aggregate.chat.id.rawValue)-66666666-6666-6666-6666-666666666666",
                isDirectory: true
            )
            let oversizedMemory = oversizedCandidate.appendingPathComponent(
                "memory",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: oversizedMemory,
                withIntermediateDirectories: true
            )
            for index in 0 ..< 17 {
                let name = String(format: "mem-20260830T12%02d00000Z-4GHJ.json", index)
                try Data("owned-shaped".utf8).write(
                    to: oversizedMemory.appendingPathComponent(name)
                )
            }

            XCTAssertEqual(
                try PortableChatPersistence().loadCatalog(at: root, in: scope),
                [.readWrite(aggregate)]
            )
            XCTAssertEqual(try Data(contentsOf: unknownChild), Data("keep".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: oversizedCandidate.path))
        }
    }

    func testRelaunchPreservesAllCandidatesWhenPublicationEnumerationExceedsBudget() throws {
        try withCreatedChat { root, scope, aggregate in
            let publications = root.appendingPathComponent("staging/publications", isDirectory: true)
            var candidates: [URL] = []
            for _ in 0 ..< 33 {
                let candidate = publications.appendingPathComponent(
                    "chat-\(aggregate.chat.id.rawValue)-\(UUID().uuidString.lowercased())",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: candidate,
                    withIntermediateDirectories: false
                )
                candidates.append(candidate)
            }

            XCTAssertEqual(
                try PortableChatPersistence().loadCatalog(at: root, in: scope),
                [.readWrite(aggregate)]
            )
            XCTAssertTrue(candidates.allSatisfy {
                FileManager.default.fileExists(atPath: $0.path)
            })
        }
    }

    func testRelaunchRejectsHostileUnicodeCandidateNamesWithoutIndexingPastBytes() throws {
        try withCreatedChat { root, scope, aggregate in
            let publications = root.appendingPathComponent("staging/publications", isDirectory: true)
            let hostileName = "chat-" + String(repeating: "😀", count: 16) + "x"
            XCTAssertEqual(hostileName.utf8.count, 70)
            let hostileCandidate = publications.appendingPathComponent(
                hostileName,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: hostileCandidate,
                withIntermediateDirectories: false
            )

            XCTAssertEqual(
                try PortableChatPersistence().loadCatalog(at: root, in: scope),
                [.readWrite(aggregate)]
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: hostileCandidate.path))
        }
    }

    func testCatalogEnumerationFailsAtItsFiniteDirectoryBound() throws {
        try withCreatedChat { root, scope, _ in
            let chats = root.appendingPathComponent("chats", isDirectory: true)
            for index in 0 ..< PortableChatPersistence.maximumChatCatalogEntries {
                try FileManager.default.createDirectory(
                    at: chats.appendingPathComponent("unowned-\(index)", isDirectory: true),
                    withIntermediateDirectories: false
                )
            }

            XCTAssertThrowsError(
                try PortableChatPersistence().loadCatalog(at: root, in: scope)
            ) { error in
                XCTAssertEqual(error as? PortableChatPersistenceError, .rootTooLarge)
            }
        }
    }

    func testMessageEnumerationFailsAtItsFiniteDirectoryBound() throws {
        try withCreatedChat { root, scope, aggregate in
            let messages = chatRoot(root, aggregate.chat.id)
                .appendingPathComponent("messages", isDirectory: true)
            for index in 0 ... PortableChatPersistence.maximumMessageDirectoryEntries {
                try Data().write(to: messages.appendingPathComponent("message-\(index).json"))
            }

            try assertChatFreezesAsCorrupt(aggregate.chat.id, at: root, in: scope)
        }
    }

    func testRenamePartialEnumerationFailsAtItsFiniteDirectoryBound() throws {
        try withCreatedChat { root, scope, aggregate in
            let chat = chatRoot(root, aggregate.chat.id)
            let partialCount = PortableChatPersistence.maximumChatRootEntries - 2
            for _ in 0 ..< partialCount {
                try Data().write(
                    to: chat.appendingPathComponent(
                        ".chat.json.\(UUID().uuidString.lowercased()).partial"
                    )
                )
            }

            try assertChatFreezesAsCorrupt(aggregate.chat.id, at: root, in: scope)
        }
    }

    func testMemoryEnumerationFailsAtItsFiniteDirectoryBound() throws {
        try withCreatedChat { root, scope, aggregate in
            let memory = chatRoot(root, aggregate.chat.id)
                .appendingPathComponent("memory", isDirectory: true)
            for index in 0 ..< PortableChatPersistence.maximumMemoryDirectoryEntries {
                try Data().write(to: memory.appendingPathComponent("unowned-\(index).json"))
            }

            try assertChatFreezesAsCorrupt(aggregate.chat.id, at: root, in: scope)
        }
    }

    func testEveryRejectedDevelopmentChatGoldenIsRejectedOrFrozenByRuntimeLoading() throws {
        for resource in [
            ContractResource.rejectedChatExplicitNullOrigin,
            .rejectedChatMissingAttachments,
            .rejectedNewChatWithOrigin,
            .rejectedChatUnknownKey,
        ] {
            try withCreatedChat { root, scope, aggregate in
                let manifest = chatRoot(root, aggregate.chat.id).appendingPathComponent("chat.json")
                try ContractResources.data(for: resource).write(to: manifest)

                try assertChatFreezesAsCorrupt(
                    aggregate.chat.id,
                    at: root,
                    in: scope,
                    message: resource.rawValue
                )
            }
        }

        try withCreatedChat { root, scope, aggregate in
            let manifest = chatRoot(root, aggregate.chat.id).appendingPathComponent("chat.json")
            let bytes = try ContractResources.data(for: .rejectedNewerChatSchema)
            try bytes.write(to: manifest)

            XCTAssertEqual(
                try PortableChatPersistence().load(aggregate.chat.id, at: root, in: scope),
                .frozen(FrozenChatSnapshot(chatID: aggregate.chat.id, reason: .newerSchema))
            )
            XCTAssertEqual(try Data(contentsOf: manifest), bytes)
        }

        try withCreatedChat { root, scope, aggregate in
            let memory = chatRoot(root, aggregate.chat.id).appendingPathComponent(
                "memory/\(aggregate.memory.memoryID.rawValue).json"
            )
            try ContractResources.data(for: .rejectedDanglingMemorySummary).write(to: memory)

            try assertChatFreezesAsCorrupt(aggregate.chat.id, at: root, in: scope)
        }
    }

    func testRelaunchStructurallyRemovesUnreferencedChatArtifactsWithoutRecencySelection() throws {
        try withCreatedChat { root, scope, aggregate in
            let publications = root.appendingPathComponent("staging/publications", isDirectory: true)
            let firstCandidate = publications.appendingPathComponent(
                "chat-\(aggregate.chat.id.rawValue)-11111111-1111-1111-1111-111111111111",
                isDirectory: true
            )
            let secondCandidate = publications.appendingPathComponent(
                "chat-\(aggregate.chat.id.rawValue)-22222222-2222-2222-2222-222222222222",
                isDirectory: true
            )
            try FileManager.default.copyItem(
                at: chatRoot(root, aggregate.chat.id),
                to: firstCandidate
            )
            try FileManager.default.createDirectory(
                at: secondCandidate.appendingPathComponent("messages", isDirectory: true),
                withIntermediateDirectories: true
            )
            let unknown = publications.appendingPathComponent("keep-user-content", isDirectory: true)
            try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)

            let chat = chatRoot(root, aggregate.chat.id)
            let partial = chat.appendingPathComponent(
                ".chat.json.33333333-3333-3333-3333-333333333333.partial"
            )
            try Data("unreferenced".utf8).write(to: partial)
            let supersededMemoryID = try CoachMemoryID("mem-20260830T120100000Z-5KMN")
            let supersededMemory = try CoachMemory(
                memoryID: supersededMemoryID,
                chatID: aggregate.chat.id,
                generalNotes: "superseded",
                sessionSummaries: [],
                attachments: .empty
            )
            let supersededMemoryURL = chat.appendingPathComponent(
                "memory/\(supersededMemoryID.rawValue).json"
            )
            try PortableChatPersistence().encodeMemory(supersededMemory).write(
                to: supersededMemoryURL
            )

            XCTAssertEqual(
                try PortableChatPersistence().loadCatalog(at: root, in: scope),
                [.readWrite(aggregate)]
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: firstCandidate.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: secondCandidate.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: supersededMemoryURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        }
    }

    private func withCreatedChat(
        _ body: (URL, LibraryScope, ChatAggregate) throws -> Void
    ) throws {
        try withCreatedLibrary { root, scope in
            let aggregate = try PortableChatPersistence().create(
                makeChatSeed(scope: scope),
                at: root
            )
            try body(root, scope, aggregate)
        }
    }

    private func withCreatedLibrary(_ body: (URL, LibraryScope) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-chat-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Synthetic.audoralibrary")
        let instant = try UTCInstant("2026-08-30T11:59:00.000Z")
        let libraryID = try LibraryID("lib-20260830T115900000Z-2ABC")
        _ = try PortableLibraryPersistence().create(
            at: root,
            seed: NewLibrarySeed(
                libraryID: libraryID,
                createdAt: instant,
                preferences: .defaults,
                profileHead: ProfileHead(
                    generation: 0,
                    statementGeneration: 7,
                    selection: .null,
                    updatedAt: instant
                )
            )
        )
        try body(root, LibraryScope(libraryID: libraryID))
    }

    private func withCreatedLibraryAsync(
        _ body: (URL, LibraryScope) async throws -> Void
    ) async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-chat-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Synthetic.audoralibrary")
        let instant = try UTCInstant("2026-08-30T11:59:00.000Z")
        let libraryID = try LibraryID("lib-20260830T115900000Z-2ABC")
        _ = try PortableLibraryPersistence().create(
            at: root,
            seed: NewLibrarySeed(
                libraryID: libraryID,
                createdAt: instant,
                preferences: .defaults,
                profileHead: ProfileHead(
                    generation: 0,
                    statementGeneration: 7,
                    selection: .null,
                    updatedAt: instant
                )
            )
        )
        try await body(root, LibraryScope(libraryID: libraryID))
    }

    private func makeChatSeed(scope: LibraryScope) throws -> NewDevelopmentChatSeed {
        try NewDevelopmentChatSeed(
            library: scope,
            chatID: ChatID("cht-20260830T120000000Z-2ABC"),
            draftID: ChatDraftID("drf-20260830T120000000Z-3DEF"),
            memoryID: CoachMemoryID("mem-20260830T120000000Z-4GHJ"),
            instant: UTCInstant("2026-08-30T12:00:00.000Z"),
            profileStatementGeneration: 7
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

    private func chatRoot(_ root: URL, _ chatID: ChatID) -> URL {
        root.appendingPathComponent("chats/\(chatID.rawValue)", isDirectory: true)
    }

    private func assertChatFreezesAsCorrupt(
        _ chatID: ChatID,
        at root: URL,
        in scope: LibraryScope,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try PortableChatPersistence().load(chatID, at: root, in: scope),
            .frozen(FrozenChatSnapshot(chatID: chatID, reason: .corrupt)),
            message,
            file: file,
            line: line
        )
    }

    private func tree(at root: URL) throws -> [String] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [],
                errorHandler: nil
            )
        )
        var values: [String] = []
        for case let url as URL in enumerator {
            let relative = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
            let directory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            values.append(relative + (directory ? "/" : ""))
        }
        return values.sorted()
    }
}

private final class BlockingPersistenceFaultGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var reached = false
    private var released = false

    func reachAndWait() {
        condition.lock()
        reached = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilReached() async {
        while !hasReached() { await Task.yield() }
    }

    private func hasReached() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return reached
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private actor PersistenceReaderProgress {
    private var started = false
    private(set) var isFinished = false

    func markStarted() {
        started = true
    }

    func markFinished() {
        isFinished = true
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}
