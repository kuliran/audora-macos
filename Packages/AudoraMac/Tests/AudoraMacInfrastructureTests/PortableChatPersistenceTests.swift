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
            XCTAssertThrowsError(
                try PortableChatPersistence().load(aggregate.chat.id, at: root, in: scope)
            )
        }

        try withCreatedChat { root, scope, aggregate in
            let manifest = chatRoot(root, aggregate.chat.id).appendingPathComponent("chat.json")
            try Data(repeating: 0x20, count: PortableChatPersistence.maximumRootBytes + 1)
                .write(to: manifest)
            XCTAssertThrowsError(
                try PortableChatPersistence().load(aggregate.chat.id, at: root, in: scope)
            ) { error in
                XCTAssertEqual(error as? PortableChatPersistenceError, .rootTooLarge)
            }
        }

        try withCreatedChat { root, scope, aggregate in
            let manifest = chatRoot(root, aggregate.chat.id).appendingPathComponent("chat.json")
            try FileManager.default.removeItem(at: manifest)
            XCTAssertEqual(mkfifo(manifest.path, 0o600), 0)
            XCTAssertThrowsError(
                try PortableChatPersistence().load(aggregate.chat.id, at: root, in: scope)
            )
        }

        try withCreatedChat { root, scope, aggregate in
            let manifest = chatRoot(root, aggregate.chat.id).appendingPathComponent("chat.json")
            try FileManager.default.removeItem(at: manifest)
            try FileManager.default.createSymbolicLink(
                at: manifest,
                withDestinationURL: URL(fileURLWithPath: "/dev/null")
            )
            XCTAssertThrowsError(
                try PortableChatPersistence().load(aggregate.chat.id, at: root, in: scope)
            ) { error in
                XCTAssertEqual(error as? PortableChatPersistenceError, .expectedPathIsSymlink)
            }
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

            XCTAssertThrowsError(
                try PortableChatPersistence().load(aggregate.chat.id, at: root, in: scope)
            ) { error in
                XCTAssertEqual(error as? PortableChatPersistenceError, .rootTooLarge)
            }
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

            XCTAssertThrowsError(
                try PortableChatPersistence().load(aggregate.chat.id, at: root, in: scope)
            ) { error in
                XCTAssertEqual(error as? PortableChatPersistenceError, .rootTooLarge)
            }
        }
    }

    func testMemoryEnumerationFailsAtItsFiniteDirectoryBound() throws {
        try withCreatedChat { root, scope, aggregate in
            let memory = chatRoot(root, aggregate.chat.id)
                .appendingPathComponent("memory", isDirectory: true)
            for index in 0 ..< PortableChatPersistence.maximumMemoryDirectoryEntries {
                try Data().write(to: memory.appendingPathComponent("unowned-\(index).json"))
            }

            XCTAssertThrowsError(
                try PortableChatPersistence().load(aggregate.chat.id, at: root, in: scope)
            ) { error in
                XCTAssertEqual(error as? PortableChatPersistenceError, .rootTooLarge)
            }
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

                XCTAssertThrowsError(
                    try PortableChatPersistence().load(aggregate.chat.id, at: root, in: scope),
                    resource.rawValue
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

            XCTAssertThrowsError(
                try PortableChatPersistence().load(aggregate.chat.id, at: root, in: scope)
            )
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

    private func chatRoot(_ root: URL, _ chatID: ChatID) -> URL {
        root.appendingPathComponent("chats/\(chatID.rawValue)", isDirectory: true)
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
