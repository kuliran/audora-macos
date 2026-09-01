@_spi(InvocationInfrastructure) import AudoraApplication
import AudoraContracts
import AudoraDomain
@testable @_spi(InvocationInfrastructure) import AudoraMacInfrastructure
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

    func testPendingUserTurnEncoderWritesV2ForInterruptedFailure() throws {
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T120001000Z-5KMN"),
            draftID: try ChatDraftID("drf-20260830T120000000Z-3DEF"),
            draftVersion: 1,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T120001000Z-6PQR"
            ),
            failure: .coachResponseInterrupted
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: PortableChatPersistence().encodePendingUserTurn(pending)
            ) as? [String: Any]
        )

        XCTAssertEqual((object["schemaVersion"] as? NSNumber)?.uint32Value, 2)
        XCTAssertEqual(object["failure"] as? String, "coachResponseInterrupted")
    }

    func testLegacyV1PendingFailuresAreStrictAndValidStateUpgradesOnWrite() throws {
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
            guard case let .committed(locked) = try persistence.lockPendingUserTurn(
                LockPendingUserTurnMutation(
                    library: scope,
                    chatID: original.chat.id,
                    pendingUserTurn: pending
                ),
                at: root
            ) else { return XCTFail("Pending setup did not commit") }
            let pendingURL = chatRoot(root, original.chat.id)
                .appendingPathComponent("pending-user-turn.json")

            try rewritePending(
                at: pendingURL,
                schemaVersion: 1,
                failure: nil
            )
            XCTAssertEqual(
                try persistence.load(original.chat.id, at: root, in: scope),
                .readWrite(locked)
            )

            let capacity = pending.replacingFailure(.coachContextCannotFit)
            guard case let .committed(upgraded) = try persistence.replacePendingUserTurn(
                ReplacePendingUserTurnMutation(
                    library: scope,
                    chatID: original.chat.id,
                    base: pending,
                    replacement: capacity
                ),
                at: root
            ) else { return XCTFail("legacy Pending did not upgrade on write") }
            let upgradedObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: pendingURL))
                    as? [String: Any]
            )
            XCTAssertEqual(
                (upgradedObject["schemaVersion"] as? NSNumber)?.uint32Value,
                2
            )
            XCTAssertEqual(upgraded.pendingUserTurn, capacity)

            try rewritePending(
                at: pendingURL,
                schemaVersion: 1,
                failure: .coachContextCannotFit
            )
            XCTAssertEqual(
                try persistence.load(original.chat.id, at: root, in: scope),
                .readWrite(upgraded)
            )

            try rewritePending(
                at: pendingURL,
                schemaVersion: 1,
                failure: .coachResponseInterrupted
            )
            try assertChatFreezesAsCorrupt(original.chat.id, at: root, in: scope)

            try rewritePending(
                at: pendingURL,
                schemaVersion: 3,
                failure: .coachResponseInterrupted
            )
            XCTAssertEqual(
                try persistence.load(original.chat.id, at: root, in: scope),
                .frozen(
                    FrozenChatSnapshot(
                        chatID: original.chat.id,
                        reason: .newerSchema
                    )
                )
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

    func testInvocationInstallFaultsExposeLaunchAuthorityOnlyAfterDurableReconciliation() throws {
        let preInstall: [PortableChatFaultPoint] = [
            .beforeInvocationPartialWrite,
            .afterInvocationPartialWrite,
            .afterInvocationFileFlush,
        ]
        let postInstall: [PortableChatFaultPoint] = [
            .afterInvocationInstall,
            .afterInvocationDirectoryFlush,
        ]
        for point in preInstall + postInstall {
            try withCreatedLibrary { root, scope in
                let baseline = PortableChatPersistence()
                let fixture = try makeInvocationFixture(
                    persistence: baseline,
                    root: root,
                    scope: scope
                )
                let faulting = PortableChatPersistence { reached in
                    if reached == point {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                }

                XCTAssertThrowsError(
                    try faulting.installInvocation(fixture.install, at: root),
                    String(describing: point)
                )
                let reconciled = try faulting.reconcileInstalledInvocation(
                    fixture.install,
                    at: root
                )
                if preInstall.contains(point) {
                    XCTAssertNil(reconciled, String(describing: point))
                    XCTAssertFalse(
                        try baseline.hasActiveInvocation(at: root, in: scope),
                        String(describing: point)
                    )
                } else {
                    XCTAssertEqual(
                        reconciled,
                        fixture.install.invocation,
                        String(describing: point)
                    )
                    XCTAssertTrue(
                        try baseline.hasActiveInvocation(at: root, in: scope),
                        String(describing: point)
                    )
                }
                guard case let .readWrite(reopened) = try baseline.load(
                    fixture.locked.chat.id,
                    at: root,
                    in: scope
                ) else { return XCTFail("Invocation fault froze the Chat") }
                XCTAssertEqual(reopened, fixture.locked)
                XCTAssertEqual(reopened.chat.messageIDs, [])
            }
        }
    }

    func testInvocationInstallRejectsLibraryIdentityReplacementBeforeCommit() throws {
        try withCreatedLibrary { root, scope in
            let baseline = PortableChatPersistence()
            let fixture = try makeInvocationFixture(
                persistence: baseline,
                root: root,
                scope: scope
            )
            let replacement = LibraryManifest(
                libraryID: try LibraryID("lib-20260830T121000000Z-5KMN"),
                createdAt: try UTCInstant("2026-08-30T11:59:00.000Z")
            )
            let faulting = PortableChatPersistence { point in
                guard point == .afterInvocationFileFlush else { return }
                try PortableLibraryPersistence().encodeManifest(replacement).write(
                    to: root.appendingPathComponent("library.json"),
                    options: .atomic
                )
            }

            XCTAssertThrowsError(
                try faulting.installInvocation(fixture.install, at: root)
            ) { error in
                XCTAssertEqual(
                    error as? PortableChatPersistenceError,
                    .libraryScopeMismatch
                )
            }
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: root.appendingPathComponent("invocations").path
                ),
                []
            )
        }
    }

    func testConcurrentChatInstallsAdmitOnlyOneActiveInvocationPerLibrary() async throws {
        try await withCreatedLibraryAsync { root, scope in
            let persistence = PortableChatPersistence()
            let first = try makeInvocationFixture(
                persistence: persistence,
                root: root,
                scope: scope,
                ordinal: 0
            )
            let second = try makeInvocationFixture(
                persistence: persistence,
                root: root,
                scope: scope,
                ordinal: 1
            )

            let outcomes = await withTaskGroup(of: InvocationInstallOutcome.self) { group in
                for mutation in [first.install, second.install] {
                    group.addTask {
                        (try? persistence.installInvocation(mutation, at: root)) ?? .failed
                    }
                }
                var values: [InvocationInstallOutcome] = []
                for await value in group { values.append(value) }
                return values
            }

            XCTAssertEqual(outcomes.filter {
                if case .installed = $0 { return true }
                return false
            }.count, 1)
            XCTAssertEqual(outcomes.filter { $0 == .activeExists }.count, 1)
            XCTAssertTrue(try persistence.hasActiveInvocation(at: root, in: scope))
        }
    }

    func testPublicationFaultsExposeNeitherSideBeforeManifestCommitAndBothAfterIt() throws {
        let beforeCommit: [PortableChatFaultPoint] = [
            .afterUserMessageInstall,
            .afterCoachMessageInstall,
            .afterPublicationManifestFileFlush,
        ]
        let afterCommit: [PortableChatFaultPoint] = [
            .afterPublicationManifestInstall,
            .afterPublicationManifestDirectoryFlush,
            .beforePublicationCleanup,
        ]
        for point in beforeCommit + afterCommit {
            try withCreatedLibrary { root, scope in
                let baseline = PortableChatPersistence()
                let fixture = try makeInvocationFixture(
                    persistence: baseline,
                    root: root,
                    scope: scope
                )
                guard case .installed = try baseline.installInvocation(
                    fixture.install,
                    at: root
                ) else { return XCTFail("Invocation did not install") }
                let faulting = PortableChatPersistence { reached in
                    if reached == point {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                }

                XCTAssertThrowsError(
                    try faulting.publishInvocation(
                        fixture.publication,
                        at: root,
                        in: scope
                    ),
                    String(describing: point)
                )
                guard case let .readWrite(reopened) = try baseline.load(
                    fixture.locked.chat.id,
                    at: root,
                    in: scope
                ) else { return XCTFail("publication fault froze the Chat") }
                if beforeCommit.contains(point) {
                    XCTAssertEqual(reopened, fixture.locked, String(describing: point))
                    XCTAssertEqual(reopened.chat.messageIDs, [], String(describing: point))
                    XCTAssertTrue(
                        try baseline.hasActiveInvocation(at: root, in: scope),
                        String(describing: point)
                    )
                } else {
                    XCTAssertEqual(
                        reopened,
                        fixture.publication.replacement,
                        String(describing: point)
                    )
                    XCTAssertEqual(
                        reopened.chat.messageIDs,
                        [
                            fixture.publication.userMessage.id,
                            fixture.publication.coachMessage.id,
                        ],
                        String(describing: point)
                    )
                    XCTAssertFalse(
                        try baseline.hasActiveInvocation(at: root, in: scope),
                        String(describing: point)
                    )
                }
            }
        }
    }

    func testRelaunchPreservesInvocationWhenPublishedTailProfileConflicts() throws {
        try withCreatedLibrary { root, scope in
            let persistence = PortableChatPersistence()
            let fixture = try makeInvocationFixture(
                persistence: persistence,
                root: root,
                scope: scope
            )
            guard case .installed = try persistence.installInvocation(
                fixture.install,
                at: root
            ) else { return XCTFail("Invocation did not install") }
            let faulting = PortableChatPersistence { point in
                if point == .afterPublicationManifestInstall {
                    throw PortableChatPersistenceError.injectedFault(point)
                }
            }
            XCTAssertThrowsError(
                try faulting.publishInvocation(
                    fixture.publication,
                    at: root,
                    in: scope
                )
            )
            let coachURL = chatRoot(root, fixture.locked.chat.id)
                .appendingPathComponent("messages", isDirectory: true)
                .appendingPathComponent(
                    "\(fixture.publication.coachMessage.id.rawValue).json"
                )
            var coach = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: coachURL))
                    as? [String: Any]
            )
            coach["profileStatementGeneration"] = 10
            try JSONSerialization.data(
                withJSONObject: coach,
                options: [.sortedKeys]
            ).write(to: coachURL, options: .atomic)
            let invocationRoot = root.appendingPathComponent(
                "invocations/\(fixture.install.invocation.id.rawValue)",
                isDirectory: true
            )

            XCTAssertThrowsError(
                try persistence.reconcileInterruptedInvocations(
                    at: root,
                    in: scope
                )
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: invocationRoot.path)
            )
        }
    }

    func testInvocationPublicationRejectsLibraryIdentityReplacementBeforeCommit() throws {
        try withCreatedLibrary { root, scope in
            let baseline = PortableChatPersistence()
            let fixture = try makeInvocationFixture(
                persistence: baseline,
                root: root,
                scope: scope
            )
            guard case .installed = try baseline.installInvocation(
                fixture.install,
                at: root
            ) else { return XCTFail("Invocation did not install") }
            let chatManifest = chatRoot(root, fixture.locked.chat.id)
                .appendingPathComponent("chat.json")
            let originalBytes = try Data(contentsOf: chatManifest)
            let replacement = LibraryManifest(
                libraryID: try LibraryID("lib-20260830T121000000Z-5KMN"),
                createdAt: try UTCInstant("2026-08-30T11:59:00.000Z")
            )
            let faulting = PortableChatPersistence { point in
                guard point == .afterPublicationManifestFileFlush else { return }
                try PortableLibraryPersistence().encodeManifest(replacement).write(
                    to: root.appendingPathComponent("library.json"),
                    options: .atomic
                )
            }

            XCTAssertThrowsError(
                try faulting.publishInvocation(
                    fixture.publication,
                    at: root,
                    in: scope
                )
            ) { error in
                XCTAssertEqual(
                    error as? PortableChatPersistenceError,
                    .libraryScopeMismatch
                )
            }
            XCTAssertEqual(try Data(contentsOf: chatManifest), originalBytes)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(
                        "invocations/\(fixture.install.invocation.id.rawValue)"
                    ).path
                )
            )
        }
    }

    func testPublicationIsIdempotentAfterCommitAndAbortRetainsRetryableIntentWithoutMessages() throws {
        try withCreatedLibrary { root, scope in
            let persistence = PortableChatPersistence()
            let fixture = try makeInvocationFixture(
                persistence: persistence,
                root: root,
                scope: scope
            )
            guard case .installed = try persistence.installInvocation(
                fixture.install,
                at: root
            ) else { return XCTFail("Invocation did not install") }
            XCTAssertEqual(
                try persistence.publishInvocation(
                    fixture.publication,
                    at: root,
                    in: scope
                ),
                .committed(fixture.publication.replacement)
            )
            XCTAssertEqual(
                try persistence.publishInvocation(
                    fixture.publication,
                    at: root,
                    in: scope
                ),
                .committed(fixture.publication.replacement)
            )
        }

        try withCreatedLibrary { root, scope in
            let persistence = PortableChatPersistence()
            let fixture = try makeInvocationFixture(
                persistence: persistence,
                root: root,
                scope: scope
            )
            guard case .installed = try persistence.installInvocation(
                fixture.install,
                at: root
            ) else { return XCTFail("Invocation did not install") }
            guard case let .committed(unlocked) = try persistence.abortInstalledNewSend(
                fixture.install.invocation,
                at: root,
                in: scope
            ) else { return XCTFail("Invocation abort did not commit") }
            XCTAssertEqual(
                unlocked.pendingUserTurn?.failure,
                .coachResponseInterrupted
            )
            XCTAssertEqual(unlocked.chat.draft, fixture.locked.chat.draft)
            XCTAssertEqual(unlocked.chat.messageIDs, [])
            XCTAssertFalse(try persistence.hasActiveInvocation(at: root, in: scope))
        }
    }

    func testAbortAfterTitleRenameRetainsExactRetryableIntent() throws {
        try withCreatedLibrary { root, scope in
            let persistence = PortableChatPersistence()
            let fixture = try makeInvocationFixture(
                persistence: persistence,
                root: root,
                scope: scope
            )
            guard case .installed = try persistence.installInvocation(
                fixture.install,
                at: root
            ) else { return XCTFail("Invocation did not install") }
            let title = try ChatTitle("Renamed While Coach Runs")
            guard case let .renamed(renamed) = try persistence.rename(
                RenameChatMutation(
                    library: scope,
                    base: fixture.locked,
                    title: title,
                    updatedAt: try UTCInstant("2026-08-30T12:00:02.500Z")
                ),
                at: root
            ) else { return XCTFail("Chat rename did not commit") }
            XCTAssertTrue(try persistence.hasActiveInvocation(at: root, in: scope))

            guard case let .committed(interrupted) = try persistence.abortInstalledNewSend(
                fixture.install.invocation,
                at: root,
                in: scope
            ) else { return XCTFail("Invocation abort did not preserve the intent") }

            XCTAssertEqual(interrupted.chat.title, title)
            XCTAssertEqual(interrupted.chat.manifestRevision, renamed.chat.manifestRevision)
            XCTAssertEqual(
                interrupted.pendingUserTurn,
                renamed.pendingUserTurn?.replacingFailure(.coachResponseInterrupted)
            )
            XCTAssertEqual(interrupted.chat.draft, fixture.locked.chat.draft)
            XCTAssertEqual(interrupted.chat.messageIDs, [])
            XCTAssertFalse(try persistence.hasActiveInvocation(at: root, in: scope))
        }
    }

    func testLoadFreezesCanonicalHistoryWithOneSidedResponse() throws {
        try withPublishedInvocation { root, scope, persistence, fixture in
            let published = fixture.publication.replacement.chat
            let oneSided = try chat(
                published,
                replacingMessageIDsWith: [fixture.publication.userMessage.id]
            )
            try persistence.encodeChat(oneSided).write(
                to: chatRoot(root, published.id).appendingPathComponent("chat.json"),
                options: .atomic
            )

            try assertChatFreezesAsCorrupt(published.id, at: root, in: scope)
        }
    }

    func testLoadFreezesCanonicalHistoryWithReversedRoleOrder() throws {
        try withPublishedInvocation { root, scope, persistence, fixture in
            let userSlot = try ChatMessage(
                id: fixture.publication.userMessage.id,
                responsePositionID: fixture.publication.userMessage.responsePositionID,
                content: .coach(markdown: "Coach content in the user slot."),
                coachProfile: fixture.install.invocation.preparedProfile,
                createdAt: fixture.publication.userMessage.createdAt
            )
            let coachSlot = try ChatMessage(
                id: fixture.publication.coachMessage.id,
                responsePositionID: fixture.publication.coachMessage.responsePositionID,
                content: .user(text: "User content in the Coach slot."),
                createdAt: fixture.publication.coachMessage.createdAt
            )
            try writeMessage(
                userSlot,
                using: persistence,
                under: root,
                chatID: fixture.locked.chat.id
            )
            try writeMessage(
                coachSlot,
                using: persistence,
                under: root,
                chatID: fixture.locked.chat.id
            )

            try assertChatFreezesAsCorrupt(
                fixture.locked.chat.id,
                at: root,
                in: scope
            )
        }
    }

    func testLoadFreezesCanonicalHistoryWithMismatchedResponsePositions() throws {
        try withPublishedInvocation { root, scope, persistence, fixture in
            let mismatchedCoach = try ChatMessage(
                id: fixture.publication.coachMessage.id,
                responsePositionID: ChatResponsePositionID(
                    "rsp-20260830T120004000Z-9Z23"
                ),
                content: fixture.publication.coachMessage.content,
                coachProfile: fixture.publication.coachMessage.coachProfile,
                createdAt: fixture.publication.coachMessage.createdAt
            )
            try writeMessage(
                mismatchedCoach,
                using: persistence,
                under: root,
                chatID: fixture.locked.chat.id
            )

            try assertChatFreezesAsCorrupt(
                fixture.locked.chat.id,
                at: root,
                in: scope
            )
        }
    }

    func testLegacyV1MessagePairReopensWithoutInventingProfileProvenance() throws {
        try withPublishedInvocation { root, scope, persistence, fixture in
            for message in [
                fixture.publication.userMessage,
                fixture.publication.coachMessage,
            ] {
                let url = chatRoot(root, fixture.locked.chat.id)
                    .appendingPathComponent("messages", isDirectory: true)
                    .appendingPathComponent("\(message.id.rawValue).json")
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: url))
                        as? [String: Any]
                )
                object["schemaVersion"] = 1
                object.removeValue(forKey: "profileRevisionId")
                object.removeValue(forKey: "profileStatementGeneration")
                if message.id == fixture.publication.userMessage.id {
                    object["text"] = String(repeating: "é", count: 8_193)
                }
                try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys]
                ).write(to: url, options: .atomic)
            }

            XCTAssertEqual(
                try persistence.load(
                    fixture.locked.chat.id,
                    at: root,
                    in: scope
                ),
                .readWrite(fixture.publication.replacement)
            )
        }
    }

    func testV2CoachMessageWithoutProfileProvenanceFreezesChat() throws {
        try withPublishedInvocation { root, scope, _, fixture in
            let coach = fixture.publication.coachMessage
            let url = chatRoot(root, fixture.locked.chat.id)
                .appendingPathComponent("messages", isDirectory: true)
                .appendingPathComponent("\(coach.id.rawValue).json")
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: url))
                    as? [String: Any]
            )
            object.removeValue(forKey: "profileRevisionId")
            object.removeValue(forKey: "profileStatementGeneration")
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ).write(to: url, options: .atomic)

            try assertChatFreezesAsCorrupt(
                fixture.locked.chat.id,
                at: root,
                in: scope
            )
        }
    }

    func testMixedV1V2MessagePairFreezesChat() throws {
        try withPublishedInvocation { root, scope, _, fixture in
            let user = fixture.publication.userMessage
            let url = chatRoot(root, fixture.locked.chat.id)
                .appendingPathComponent("messages", isDirectory: true)
                .appendingPathComponent("\(user.id.rawValue).json")
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: url))
                    as? [String: Any]
            )
            object["schemaVersion"] = 1
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ).write(to: url, options: .atomic)

            try assertChatFreezesAsCorrupt(
                fixture.locked.chat.id,
                at: root,
                in: scope
            )
        }
    }

    func testRelaunchReconciliationAbortsOneInterruptedInvocationWithoutMessages() throws {
        try withCreatedLibrary { root, scope in
            let persistence = PortableChatPersistence()
            let fixture = try makeInvocationFixture(
                persistence: persistence,
                root: root,
                scope: scope
            )
            guard case .installed = try persistence.installInvocation(
                fixture.install,
                at: root
            ) else { return XCTFail("Invocation did not install") }
            let invocationRoot = root.appendingPathComponent(
                "invocations/\(fixture.install.invocation.id.rawValue)",
                isDirectory: true
            )
            XCTAssertEqual(try tree(at: invocationRoot), ["invocation.json"])

            try persistence.reconcileInterruptedInvocations(at: root, in: scope)

            guard case let .readWrite(reopened) = try persistence.load(
                fixture.locked.chat.id,
                at: root,
                in: scope
            ) else { return XCTFail("recovery froze the Chat") }
            XCTAssertEqual(
                reopened.pendingUserTurn?.failure,
                .coachResponseInterrupted
            )
            XCTAssertEqual(reopened.chat.draft, fixture.locked.chat.draft)
            XCTAssertEqual(reopened.chat.messageIDs, [])
            XCTAssertFalse(try persistence.hasActiveInvocation(at: root, in: scope))
            XCTAssertFalse(FileManager.default.fileExists(atPath: invocationRoot.path))
        }
    }

    func testRelaunchAfterTitleRenameRetainsExactRetryableIntent() throws {
        try withCreatedLibrary { root, scope in
            let persistence = PortableChatPersistence()
            let fixture = try makeInvocationFixture(
                persistence: persistence,
                root: root,
                scope: scope
            )
            guard case .installed = try persistence.installInvocation(
                fixture.install,
                at: root
            ) else { return XCTFail("Invocation did not install") }
            let title = try ChatTitle("Renamed Before Relaunch")
            guard case let .renamed(renamed) = try persistence.rename(
                RenameChatMutation(
                    library: scope,
                    base: fixture.locked,
                    title: title,
                    updatedAt: try UTCInstant("2026-08-30T12:00:02.500Z")
                ),
                at: root
            ) else { return XCTFail("Chat rename did not commit") }

            try persistence.reconcileInterruptedInvocations(at: root, in: scope)

            guard case let .readWrite(reopened) = try persistence.load(
                fixture.locked.chat.id,
                at: root,
                in: scope
            ) else { return XCTFail("recovery froze the Chat") }
            XCTAssertEqual(reopened.chat.title, title)
            XCTAssertEqual(reopened.chat.manifestRevision, renamed.chat.manifestRevision)
            XCTAssertEqual(
                reopened.pendingUserTurn,
                renamed.pendingUserTurn?.replacingFailure(.coachResponseInterrupted)
            )
            XCTAssertEqual(reopened.chat.draft, fixture.locked.chat.draft)
            XCTAssertEqual(reopened.chat.messageIDs, [])
            XCTAssertFalse(try persistence.hasActiveInvocation(at: root, in: scope))
        }
    }

    func testRelaunchSafelyRetiresLegacyV1InvocationWithoutInventingProfile() throws {
        try withCreatedLibrary { root, scope in
            let persistence = PortableChatPersistence()
            let fixture = try makeInvocationFixture(
                persistence: persistence,
                root: root,
                scope: scope
            )
            guard case .installed = try persistence.installInvocation(
                fixture.install,
                at: root
            ) else { return XCTFail("Invocation did not install") }
            let url = root.appendingPathComponent(
                "invocations/\(fixture.install.invocation.id.rawValue)/invocation.json"
            )
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: url))
                    as? [String: Any]
            )
            object["schemaVersion"] = 1
            object.removeValue(forKey: "profileRevisionId")
            object.removeValue(forKey: "profileStatementGeneration")
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ).write(to: url, options: .atomic)

            try persistence.reconcileInterruptedInvocations(at: root, in: scope)

            guard case let .readWrite(reopened) = try persistence.load(
                fixture.locked.chat.id,
                at: root,
                in: scope
            ) else { return XCTFail("legacy recovery froze the Chat") }
            XCTAssertEqual(
                reopened.pendingUserTurn?.failure,
                .coachResponseInterrupted
            )
            XCTAssertEqual(reopened.chat.messageIDs, [])
            XCTAssertFalse(try persistence.hasActiveInvocation(at: root, in: scope))
        }
    }

    func testMalformedV2InvocationWithNullProfileGenerationIsRejectedWithoutTrap() throws {
        try withCreatedLibrary { root, scope in
            let persistence = PortableChatPersistence()
            let fixture = try makeInvocationFixture(
                persistence: persistence,
                root: root,
                scope: scope
            )
            guard case .installed = try persistence.installInvocation(
                fixture.install,
                at: root
            ) else { return XCTFail("Invocation did not install") }
            let url = root.appendingPathComponent(
                "invocations/\(fixture.install.invocation.id.rawValue)/invocation.json"
            )
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: url))
                    as? [String: Any]
            )
            object["profileStatementGeneration"] = NSNull()
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ).write(to: url, options: .atomic)

            XCTAssertThrowsError(
                try persistence.reconcileInterruptedInvocations(at: root, in: scope)
            )
        }
    }

    func testV2InvocationWithoutSelectedProfileOmitsRevisionInsteadOfEncodingNull() throws {
        try withCreatedLibrary { root, scope in
            let persistence = PortableChatPersistence()
            let fixture = try makeInvocationFixture(
                persistence: persistence,
                root: root,
                scope: scope
            )
            let original = fixture.install.invocation
            let authority = try InvocationPendingAuthority(
                request: PendingCoachInvocationRequest(
                    library: scope,
                    chatID: original.chatID,
                    pendingUserTurnID: original.pendingUserTurnID
                ),
                aggregate: fixture.locked
            )
            let identity = InvocationLaunchIdentity(
                invocationID: original.id,
                attemptID: original.attemptID,
                idempotencyValue: original.providerIdempotencyValue,
                userMessageID: fixture.publication.userMessage.id,
                coachMessageID: fixture.publication.coachMessage.id,
                freshDraftID: fixture.publication.freshDraft.draftID
            )
            let install = try InstallCoachInvocationMutation(
                authority: authority,
                identity: identity,
                preparedProfile: CoachProfileProvenance(
                    revisionID: nil,
                    statementGeneration: 9
                ),
                admittedAt: original.admittedAt
            )

            guard case .installed = try persistence.installInvocation(
                install,
                at: root
            ) else { return XCTFail("Invocation did not install") }
            let url = root.appendingPathComponent(
                "invocations/\(install.invocation.id.rawValue)/invocation.json"
            )
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: url))
                    as? [String: Any]
            )
            XCTAssertFalse(object.keys.contains("profileRevisionId"))
            XCTAssertEqual(
                (object["profileStatementGeneration"] as? NSNumber)?.uint64Value,
                9
            )
        }
    }

    func testAbortRetiresInvocationEvenWhenThePendingAuthorityIsAlreadyStale() throws {
        try withCreatedLibrary { root, scope in
            let persistence = PortableChatPersistence()
            let fixture = try makeInvocationFixture(
                persistence: persistence,
                root: root,
                scope: scope
            )
            guard case .installed = try persistence.installInvocation(
                fixture.install,
                at: root
            ) else { return XCTFail("Invocation did not install") }
            guard let pending = fixture.locked.pendingUserTurn,
                  case let .committed(unlocked) = try persistence.discardPendingUserTurn(
                      DiscardPendingUserTurnMutation(
                          library: scope,
                          chatID: fixture.locked.chat.id,
                          pendingUserTurn: pending
                      ),
                      at: root
                  )
            else { return XCTFail("failed to construct stale publication authority") }

            XCTAssertEqual(
                try persistence.abortInstalledNewSend(
                    fixture.install.invocation,
                    at: root,
                    in: scope
                ),
                .stale(unlocked)
            )
            XCTAssertFalse(try persistence.hasActiveInvocation(at: root, in: scope))
            XCTAssertEqual(unlocked.chat.messageIDs, [])
            XCTAssertEqual(unlocked.chat.draft, fixture.locked.chat.draft)
        }
    }

    func testAbortFaultsReconcileToRetryableDraftAndNoActiveInvocation() throws {
        let points: [PortableChatFaultPoint] = [
            .afterInvocationAbortMarkerInstall,
            .afterInvocationAbortDirectoryRemoval,
            .afterInvocationAbortPendingFailureInstall,
        ]
        for point in points {
            try withCreatedLibrary { root, scope in
                let baseline = PortableChatPersistence()
                let fixture = try makeInvocationFixture(
                    persistence: baseline,
                    root: root,
                    scope: scope
                )
                guard case .installed = try baseline.installInvocation(
                    fixture.install,
                    at: root
                ) else { return XCTFail("Invocation did not install") }
                let faulting = PortableChatPersistence { reached in
                    if reached == point {
                        throw PortableChatPersistenceError.injectedFault(point)
                    }
                }

                XCTAssertThrowsError(
                    try faulting.abortInstalledNewSend(
                        fixture.install.invocation,
                        at: root,
                        in: scope
                    ),
                    String(describing: point)
                )
                guard case let .readWrite(reopened) = try baseline.load(
                    fixture.locked.chat.id,
                    at: root,
                    in: scope
                ) else { return XCTFail("abort recovery froze the Chat") }
                XCTAssertEqual(
                    reopened.pendingUserTurn?.failure,
                    .coachResponseInterrupted,
                    String(describing: point)
                )
                XCTAssertEqual(
                    reopened.chat.draft,
                    fixture.locked.chat.draft,
                    String(describing: point)
                )
                XCTAssertEqual(reopened.chat.messageIDs, [], String(describing: point))
                XCTAssertFalse(
                    try baseline.hasActiveInvocation(at: root, in: scope),
                    String(describing: point)
                )
            }
        }
    }

    func testExactPublicationSerializationRejectsEnvelopesAboveTheRootBudget() throws {
        let message = try ChatMessage(
            id: ChatMessageID("msg-20260830T120003000Z-7STV"),
            responsePositionID: ChatResponsePositionID(
                "rsp-20260830T120001000Z-6PQR"
            ),
            content: .coach(
                markdown: String(
                    repeating: "\"",
                    count: ChatMessage.maximumCoachMarkdownUTF8Bytes
                )
            ),
            coachProfile: CoachProfileProvenance(
                revisionID: try ProfileRevisionID("prf-20260830T115900000Z-4GHJ"),
                statementGeneration: 9
            ),
            createdAt: UTCInstant("2026-08-30T12:00:03.000Z")
        )

        XCTAssertThrowsError(try PortableChatPersistence().encodeMessage(message)) { error in
            XCTAssertEqual(error as? PortableChatPersistenceError, .rootTooLarge)
        }

        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let messageIDs = try (0..<4_096).map { ordinal in
            var remainder = ordinal
            var suffix = Array(repeating: Character("0"), count: 4)
            for index in suffix.indices.reversed() {
                suffix[index] = alphabet[remainder % alphabet.count]
                remainder /= alphabet.count
            }
            return try ChatMessageID(
                "msg-20260830T120003000Z-\(String(suffix))"
            )
        }
        let seed = try makeChatSeed(scope: LibraryScope(
            libraryID: LibraryID("lib-20260830T115900000Z-2ABC")
        ))
        let oversizedManifest = try Chat(
            id: seed.aggregate.chat.id,
            manifestRevision: seed.aggregate.chat.manifestRevision,
            title: seed.aggregate.chat.title,
            createdAt: seed.aggregate.chat.createdAt,
            updatedAt: seed.aggregate.chat.updatedAt,
            creation: seed.aggregate.chat.creation,
            profileStatementGenerationAtCreation: seed.aggregate.chat
                .profileStatementGenerationAtCreation,
            attachments: seed.aggregate.chat.attachments,
            draft: seed.aggregate.chat.draft,
            messageIDs: messageIDs,
            currentMemoryID: seed.aggregate.chat.currentMemoryID
        )
        XCTAssertThrowsError(
            try PortableChatPersistence().encodeChat(oversizedManifest)
        ) { error in
            XCTAssertEqual(error as? PortableChatPersistenceError, .rootTooLarge)
        }
    }

    private struct InvocationPersistenceFixture {
        let locked: ChatAggregate
        let install: InstallCoachInvocationMutation
        let publication: PublishCoachInvocationMutation
    }

    private func makeInvocationFixture(
        persistence: PortableChatPersistence,
        root: URL,
        scope: LibraryScope,
        ordinal: Int = 0
    ) throws -> InvocationPersistenceFixture {
        let minute = ordinal == 0 ? "00" : "01"
        let chatID = try ChatID("cht-20260830T12\(minute)00000Z-2ABC")
        let draftID = try ChatDraftID("drf-20260830T12\(minute)00000Z-3DEF")
        let memoryID = try CoachMemoryID("mem-20260830T12\(minute)00000Z-4GHJ")
        let createdAt = try UTCInstant("2026-08-30T12:\(minute):00.000Z")
        let created = try persistence.create(
            NewDevelopmentChatSeed(
                library: scope,
                chatID: chatID,
                draftID: draftID,
                memoryID: memoryID,
                instant: createdAt,
                profileStatementGeneration: 7
            ),
            at: root
        )
        let edited = try created.chat.draft.edited(
            text: "Publish this exact synthetic Draft \(ordinal).",
            at: createdAt
        )
        guard case .committed = try persistence.saveDraft(
            SaveChatDraftMutation(
                library: scope,
                chatID: chatID,
                replacement: edited
            ),
            at: root
        ) else { throw PortableChatPersistenceError.ioFailure }
        let pending = PendingUserTurn(
            id: try PendingUserTurnID("ptu-20260830T12\(minute)01000Z-5KMN"),
            draftID: edited.draftID,
            draftVersion: edited.version,
            responsePositionID: try ChatResponsePositionID(
                "rsp-20260830T12\(minute)01000Z-6PQR"
            )
        )
        guard case let .committed(locked) = try persistence.lockPendingUserTurn(
            LockPendingUserTurnMutation(
                library: scope,
                chatID: chatID,
                pendingUserTurn: pending
            ),
            at: root
        ) else { throw PortableChatPersistenceError.ioFailure }
        let request = PendingCoachInvocationRequest(
            library: scope,
            chatID: chatID,
            pendingUserTurnID: pending.id
        )
        let authority = try InvocationPendingAuthority(
            request: request,
            aggregate: locked
        )
        let identity = InvocationLaunchIdentity(
            invocationID: try CoachInvocationID(
                "inv-20260830T12\(minute)02000Z-5KMN"
            ),
            attemptID: try CoachProviderAttemptID(
                "atm-20260830T12\(minute)02000Z-6PQR"
            ),
            idempotencyValue: try ProviderIdempotencyValue(
                "synthetic-\(ordinal)-6PQR"
            ),
            userMessageID: try ChatMessageID(
                "msg-20260830T12\(minute)03000Z-7STV"
            ),
            coachMessageID: try ChatMessageID(
                "msg-20260830T12\(minute)03000Z-8WXY"
            ),
            freshDraftID: try ChatDraftID(
                "drf-20260830T12\(minute)03000Z-9Z23"
            )
        )
        let install = try InstallCoachInvocationMutation(
            authority: authority,
            identity: identity,
            preparedProfile: CoachProfileProvenance(
                revisionID: try ProfileRevisionID("prf-20260830T115900000Z-4GHJ"),
                statementGeneration: 9
            ),
            admittedAt: try UTCInstant("2026-08-30T12:\(minute):02.000Z")
        )
        let publication = try PublishCoachInvocationMutation(
            base: locked,
            invocation: install.invocation,
            identity: identity,
            coachMarkdown: "A complete **synthetic** Coach response.",
            completedAt: try UTCInstant("2026-08-30T12:\(minute):03.000Z")
        )
        return InvocationPersistenceFixture(
            locked: locked,
            install: install,
            publication: publication
        )
    }

    private func withPublishedInvocation(
        _ body: (
            URL,
            LibraryScope,
            PortableChatPersistence,
            InvocationPersistenceFixture
        ) throws -> Void
    ) throws {
        try withCreatedLibrary { root, scope in
            let persistence = PortableChatPersistence()
            let fixture = try makeInvocationFixture(
                persistence: persistence,
                root: root,
                scope: scope
            )
            guard case .installed = try persistence.installInvocation(
                fixture.install,
                at: root
            ) else { return XCTFail("Invocation did not install") }
            guard case .committed = try persistence.publishInvocation(
                fixture.publication,
                at: root,
                in: scope
            ) else { return XCTFail("Invocation did not publish") }
            try body(root, scope, persistence, fixture)
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

    private func chat(
        _ source: Chat,
        replacingMessageIDsWith messageIDs: [ChatMessageID]
    ) throws -> Chat {
        try Chat(
            id: source.id,
            manifestRevision: source.manifestRevision,
            title: source.title,
            createdAt: source.createdAt,
            updatedAt: source.updatedAt,
            creation: source.creation,
            profileStatementGenerationAtCreation: source
                .profileStatementGenerationAtCreation,
            attachments: source.attachments,
            draft: source.draft,
            messageIDs: messageIDs,
            currentMemoryID: source.currentMemoryID
        )
    }

    private func writeMessage(
        _ message: ChatMessage,
        using persistence: PortableChatPersistence,
        under root: URL,
        chatID: ChatID
    ) throws {
        try persistence.encodeMessage(message).write(
            to: chatRoot(root, chatID)
                .appendingPathComponent("messages/\(message.id.rawValue).json"),
            options: .atomic
        )
    }

    private func rewritePending(
        at url: URL,
        schemaVersion: UInt32,
        failure: PendingUserTurnFailure?
    ) throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
        object["schemaVersion"] = schemaVersion
        if let failure {
            object["failure"] = failure.rawValue
        } else {
            object.removeValue(forKey: "failure")
        }
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: url, options: .atomic)
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
