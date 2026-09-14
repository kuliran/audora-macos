@_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
@testable @_spi(InvocationInfrastructure) import AudoraMacInfrastructure
import Foundation
import XCTest

final class PortableLibraryAggregateTrashTests: XCTestCase {
    func testSessionMoveAndRestorePreserveWholeTreeAndChatReference() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Practice.audoralibrary")
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let attachment = try await installRecordedChatAttachmentFixture(
                at: root,
                in: scope
            )
            let chat = try PortableChatPersistence().create(
                makeChatSeed(
                    scope: scope,
                    attachments: ChatAttachments(validating: [attachment])
                ),
                at: root
            )
            let activeSession = root.appendingPathComponent(
                "sessions/\(attachment.sessionID.rawValue)"
            )
            let trashedSession = root.appendingPathComponent(
                "trash/sessions/\(attachment.sessionID.rawValue)"
            )
            let originalSessionTree = try snapshotTree(at: activeSession)
            let chatManifest = root.appendingPathComponent(
                "chats/\(chat.chat.id.rawValue)/chat.json"
            )
            let originalChatManifest = try Data(contentsOf: chatManifest)
            let persistence = PortableLibraryAggregateTrash()

            XCTAssertEqual(
                persistence.moveToTrash(
                    .session(attachment.sessionID),
                    at: root,
                    in: scope
                ),
                .succeeded
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: activeSession.path))
            XCTAssertEqual(try snapshotTree(at: trashedSession), originalSessionTree)
            XCTAssertEqual(try Data(contentsOf: chatManifest), originalChatManifest)
            XCTAssertEqual(
                persistence.loadCatalog(at: root, in: scope),
                .available(
                    LibraryCatalogSnapshot(
                        active: [
                            .chat(
                                chat.chat.id,
                                LibraryChatCatalogMetadata(
                                    title: .newChat,
                                    createdAt: try UTCInstant(
                                        "2026-08-30T12:00:00.000Z"
                                    ),
                                    updatedAt: try UTCInstant(
                                        "2026-08-30T12:00:00.000Z"
                                    )
                                )
                            ),
                        ],
                        trash: [
                            .session(
                                attachment.sessionID,
                                LibrarySessionCatalogMetadata(
                                    acquisition: .recorded,
                                    createdAt: try UTCInstant(
                                        "2026-08-30T12:00:00.000Z"
                                    ),
                                    hasSelectedTranscript: true
                                )
                            ),
                        ]
                    )
                )
            )

            XCTAssertEqual(
                persistence.restore(
                    .session(attachment.sessionID),
                    at: root,
                    in: scope
                ),
                .succeeded
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: trashedSession.path))
            XCTAssertEqual(try snapshotTree(at: activeSession), originalSessionTree)
            XCTAssertEqual(try Data(contentsOf: chatManifest), originalChatManifest)
        }
    }

    func testChatMoveAndRestorePreserveEveryUnresolvedSidecar() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Practice.audoralibrary")
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let chat = try PortableChatPersistence().create(
                makeChatSeed(scope: scope),
                at: root
            )
            let activeChat = root.appendingPathComponent(
                "chats/\(chat.chat.id.rawValue)"
            )
            let trashedChat = root.appendingPathComponent(
                "trash/chats/\(chat.chat.id.rawValue)"
            )
            let sidecars: [String: Data] = [
                "proposal.json": Data("unresolved-proposal".utf8),
                "profile-publication.json": Data("unresolved-publication".utf8),
                "profile-reconsideration.json": Data("unresolved-reconsideration".utf8),
                "profile-write.json": Data("unresolved-profile-write".utf8),
            ]
            for (name, bytes) in sidecars {
                try bytes.write(to: activeChat.appendingPathComponent(name))
            }
            let originalTree = try snapshotTree(at: activeChat)
            let profileHead = root.appendingPathComponent("profile/head.json")
            let originalProfileHead = try Data(contentsOf: profileHead)
            let persistence = PortableLibraryAggregateTrash()

            XCTAssertEqual(
                persistence.moveToTrash(.chat(chat.chat.id), at: root, in: scope),
                .succeeded
            )
            XCTAssertEqual(try snapshotTree(at: trashedChat), originalTree)
            XCTAssertEqual(try Data(contentsOf: profileHead), originalProfileHead)

            XCTAssertEqual(
                persistence.restore(.chat(chat.chat.id), at: root, in: scope),
                .succeeded
            )
            XCTAssertEqual(try snapshotTree(at: activeChat), originalTree)
            XCTAssertEqual(try Data(contentsOf: profileHead), originalProfileHead)
        }
    }

    func testCatalogReadsPersistedChatMetadataInActiveAndTrash() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Practice.audoralibrary")
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let chats = PortableChatPersistence()
            let original = try chats.create(makeChatSeed(scope: scope), at: root)
            let title = try ChatTitle("Café Conversation")
            let updatedAt = try UTCInstant("2026-08-30T12:01:00.000Z")
            guard case let .renamed(renamed) = try chats.rename(
                RenameChatMutation(
                    library: scope,
                    base: original,
                    title: title,
                    updatedAt: updatedAt
                ),
                at: root
            ) else {
                return XCTFail("Chat rename did not commit")
            }
            let expectedRow = LibraryCatalogRow.chat(
                renamed.chat.id,
                LibraryChatCatalogMetadata(
                    title: title,
                    createdAt: try UTCInstant("2026-08-30T12:00:00.000Z"),
                    updatedAt: updatedAt
                )
            )
            let persistence = PortableLibraryAggregateTrash()

            XCTAssertEqual(
                persistence.loadCatalog(at: root, in: scope),
                .available(
                    LibraryCatalogSnapshot(active: [expectedRow], trash: [])
                )
            )

            XCTAssertEqual(
                persistence.moveToTrash(.chat(renamed.chat.id), at: root, in: scope),
                .succeeded
            )
            XCTAssertEqual(
                persistence.loadCatalog(at: root, in: scope),
                .available(
                    LibraryCatalogSnapshot(active: [], trash: [expectedRow])
                )
            )
        }
    }

    func testRestoreCollisionPreservesBothCompleteTrees() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Practice.audoralibrary")
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let sessionID = try SessionID("ses-20260830T120100000Z-2CDE")
            let active = root.appendingPathComponent(
                "sessions/\(sessionID.rawValue)"
            )
            let trash = root.appendingPathComponent(
                "trash/sessions/\(sessionID.rawValue)"
            )
            try FileManager.default.createDirectory(
                at: active,
                withIntermediateDirectories: false
            )
            let originalBytes = Data("original-session-tree".utf8)
            try originalBytes.write(to: active.appendingPathComponent("sentinel"))
            let persistence = PortableLibraryAggregateTrash()
            XCTAssertEqual(
                persistence.moveToTrash(.session(sessionID), at: root, in: scope),
                .succeeded
            )

            try FileManager.default.createDirectory(
                at: active,
                withIntermediateDirectories: false
            )
            let collisionBytes = Data("new-active-tree".utf8)
            try collisionBytes.write(to: active.appendingPathComponent("sentinel"))

            XCTAssertEqual(
                persistence.restore(.session(sessionID), at: root, in: scope),
                .targetCollision
            )
            XCTAssertEqual(
                try Data(contentsOf: active.appendingPathComponent("sentinel")),
                collisionBytes
            )
            XCTAssertEqual(
                try Data(contentsOf: trash.appendingPathComponent("sentinel")),
                originalBytes
            )
        }
    }

    func testCatalogNeverExpiresOrCleansOldTrash() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Practice.audoralibrary")
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let chatID = try ChatID("cht-20260830T120000000Z-2ABC")
            let trashed = root.appendingPathComponent(
                "trash/chats/\(chatID.rawValue)"
            )
            try FileManager.default.createDirectory(
                at: trashed,
                withIntermediateDirectories: false
            )
            let sentinel = trashed.appendingPathComponent("sentinel")
            let bytes = Data("retain-forever".utf8)
            try bytes.write(to: sentinel)
            let old = Date(timeIntervalSince1970: 1)
            try FileManager.default.setAttributes(
                [.modificationDate: old],
                ofItemAtPath: sentinel.path
            )
            try FileManager.default.setAttributes(
                [.modificationDate: old],
                ofItemAtPath: trashed.path
            )
            let expected = LibraryCatalogLoadResult.available(
                LibraryCatalogSnapshot(
                    active: [],
                    trash: [
                        .unavailable(.chat(chatID), .corrupt),
                    ]
                )
            )

            XCTAssertEqual(
                PortableLibraryAggregateTrash().loadCatalog(at: root, in: scope),
                expected
            )
            XCTAssertEqual(
                PortableLibraryAggregateTrash().loadCatalog(at: root, in: scope),
                expected
            )
            XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
        }
    }

    func testCatalogRejectsAggregateThatExistsInActiveLibraryAndTrash()
        async throws
    {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Practice.audoralibrary")
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let chatID = try ChatID("cht-20260830T120000000Z-2ABC")
            for parentPath in ["chats", "trash/chats"] {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(
                        "\(parentPath)/\(chatID.rawValue)"
                    ),
                    withIntermediateDirectories: false
                )
            }

            XCTAssertEqual(
                PortableLibraryAggregateTrash().loadCatalog(
                    at: root,
                    in: scope
                ),
                .integrityMismatch
            )
        }
    }

    func testCatalogRetriesOverlapObservedDuringAnotherProcessMove()
        async throws
    {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Practice.audoralibrary")
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let chat = try PortableChatPersistence().create(
                makeChatSeed(scope: scope),
                at: root
            )
            let aggregate = LibraryAggregate.chat(chat.chat.id)
            let oneShot = TrashCatalogReadRaceGate()
            let mover = PortableLibraryAggregateTrash()
            let reader = PortableLibraryAggregateTrash { point in
                guard point == .afterActiveCatalogRead, oneShot.claim() else {
                    return
                }
                guard mover.moveToTrash(
                    aggregate,
                    at: root,
                    in: scope
                ) == .succeeded else {
                    throw TrashInjectedFault()
                }
            }

            XCTAssertEqual(
                reader.loadCatalog(at: root, in: scope),
                .available(
                    LibraryCatalogSnapshot(
                        active: [],
                        trash: [
                            .chat(
                                chat.chat.id,
                                LibraryChatCatalogMetadata(
                                    title: .newChat,
                                    createdAt: try UTCInstant(
                                        "2026-08-30T12:00:00.000Z"
                                    ),
                                    updatedAt: try UTCInstant(
                                        "2026-08-30T12:00:00.000Z"
                                    )
                                )
                            ),
                        ]
                    )
                )
            )
        }
    }

    func testCatalogRetriesAggregateMovedAfterNameEnumerationBeforeOpen()
        async throws
    {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Practice.audoralibrary")
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let chat = try PortableChatPersistence().create(
                makeChatSeed(scope: scope),
                at: root
            )
            let aggregate = LibraryAggregate.chat(chat.chat.id)
            let oneShot = TrashCatalogReadRaceGate()
            let mover = PortableLibraryAggregateTrash()
            let reader = PortableLibraryAggregateTrash { point in
                guard point == .afterActiveChatCatalogNameEnumeration,
                      oneShot.claim()
                else { return }
                guard mover.moveToTrash(aggregate, at: root, in: scope) ==
                    .succeeded
                else { throw TrashInjectedFault() }
            }

            XCTAssertEqual(
                reader.loadCatalog(at: root, in: scope),
                .available(
                    LibraryCatalogSnapshot(
                        active: [],
                        trash: [try defaultChatCatalogRow(chat.chat.id)]
                    )
                )
            )
        }
    }

    func testCatalogRestartsStabilizationWhenAggregateMovesAfterOpen()
        async throws
    {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Practice.audoralibrary")
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let chat = try PortableChatPersistence().create(
                makeChatSeed(scope: scope),
                at: root
            )
            let aggregate = LibraryAggregate.chat(chat.chat.id)
            let faultCounter = TrashCatalogFaultCounter()
            let mover = PortableLibraryAggregateTrash()
            let reader = PortableLibraryAggregateTrash { point in
                guard point == .afterCatalogAggregateOpen,
                      faultCounter.claim(occurrence: 2)
                else { return }
                guard mover.moveToTrash(aggregate, at: root, in: scope) ==
                    .succeeded
                else { throw TrashInjectedFault() }
            }

            XCTAssertEqual(
                reader.loadCatalog(at: root, in: scope),
                .available(
                    LibraryCatalogSnapshot(
                        active: [],
                        trash: [try defaultChatCatalogRow(chat.chat.id)]
                    )
                )
            )
            XCTAssertGreaterThanOrEqual(faultCounter.occurrenceCount, 4)
        }
    }

    func testCatalogToleratesOnlyFinderMetadataAmongAggregateNames()
        async throws
    {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Practice.audoralibrary")
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let chat = try PortableChatPersistence().create(
                makeChatSeed(scope: scope),
                at: root
            )
            for relativeParent in [
                "sessions",
                "chats",
                "trash/sessions",
                "trash/chats",
            ] {
                try Data("finder-metadata".utf8).write(
                    to: root.appendingPathComponent(
                        "\(relativeParent)/.DS_Store"
                    )
                )
            }

            XCTAssertEqual(
                PortableLibraryAggregateTrash().loadCatalog(at: root, in: scope),
                .available(
                    LibraryCatalogSnapshot(
                        active: [try defaultChatCatalogRow(chat.chat.id)],
                        trash: []
                    )
                )
            )
        }
    }

    func testCatalogRejectsUnexpectedAggregateDirectoryName() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Practice.audoralibrary")
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("chats/not-a-chat"),
                withIntermediateDirectories: false
            )

            XCTAssertEqual(
                PortableLibraryAggregateTrash().loadCatalog(at: root, in: scope),
                .integrityMismatch
            )
        }
    }

    func testCatalogRetriesWhenManifestMetadataChangesMidRead() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Practice.audoralibrary")
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let chats = PortableChatPersistence()
            let original = try chats.create(makeChatSeed(scope: scope), at: root)
            let title = try ChatTitle("Revised Café Notes")
            let updatedAt = try UTCInstant("2026-08-30T12:01:00.000Z")
            let oneShot = TrashCatalogReadRaceGate()
            let reader = PortableLibraryAggregateTrash { point in
                guard point == .afterActiveCatalogRead, oneShot.claim() else {
                    return
                }
                guard case .renamed = try chats.rename(
                    RenameChatMutation(
                        library: scope,
                        base: original,
                        title: title,
                        updatedAt: updatedAt
                    ),
                    at: root
                ) else {
                    throw TrashInjectedFault()
                }
            }

            XCTAssertEqual(
                reader.loadCatalog(at: root, in: scope),
                .available(
                    LibraryCatalogSnapshot(
                        active: [
                            .chat(
                                original.chat.id,
                                LibraryChatCatalogMetadata(
                                    title: title,
                                    createdAt: try UTCInstant(
                                        "2026-08-30T12:00:00.000Z"
                                    ),
                                    updatedAt: updatedAt
                                )
                            ),
                        ],
                        trash: []
                    )
                )
            )
        }
    }

    func testCatalogKeepsNewerSchemaAggregateVisibleWithoutInventedMetadata()
        async throws
    {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Practice.audoralibrary")
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let chat = try PortableChatPersistence().create(
                makeChatSeed(scope: scope),
                at: root
            )
            let manifest = root.appendingPathComponent(
                "chats/\(chat.chat.id.rawValue)/chat.json"
            )
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
                    as? [String: Any]
            )
            object["schemaVersion"] = 2
            try JSONSerialization.data(withJSONObject: object)
                .write(to: manifest, options: .atomic)

            XCTAssertEqual(
                PortableLibraryAggregateTrash().loadCatalog(at: root, in: scope),
                .available(
                    LibraryCatalogSnapshot(
                        active: [
                            .unavailable(.chat(chat.chat.id), .newerSchema),
                        ],
                        trash: []
                    )
                )
            )
        }
    }

    func testSessionCatalogClassifiesSchemaVersionWithoutInventingMetadata()
        async throws
    {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Practice.audoralibrary")
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let attachment = try await installRecordedChatAttachmentFixture(
                at: root,
                in: scope
            )
            let manifest = root.appendingPathComponent(
                "sessions/\(attachment.sessionID.rawValue)/session.json"
            )
            let original = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
                    as? [String: Any]
            )
            let cases: [
                (value: Any?, reason: LibraryCatalogRowUnavailableReason)
            ] = [
                (nil, .corrupt),
                (true, .corrupt),
                (1.5, .corrupt),
                (0, .unsupportedSchema),
                (2, .newerSchema),
            ]
            let persistence = PortableLibraryAggregateTrash()

            for testCase in cases {
                var object = original
                if let value = testCase.value {
                    object["schemaVersion"] = value
                } else {
                    object.removeValue(forKey: "schemaVersion")
                }
                try JSONSerialization.data(withJSONObject: object)
                    .write(to: manifest, options: .atomic)

                XCTAssertEqual(
                    persistence.loadCatalog(at: root, in: scope),
                    .available(
                        LibraryCatalogSnapshot(
                            active: [
                                .unavailable(
                                    .session(attachment.sessionID),
                                    testCase.reason
                                ),
                            ],
                            trash: []
                        )
                    )
                )
            }
        }
    }

    func testMoveFlushesBothOwningDirectoriesAfterTheRename() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Practice.audoralibrary")
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let chat = try PortableChatPersistence().create(
                makeChatSeed(scope: scope),
                at: root
            )
            let observation = TrashFaultObservation()
            let persistence = PortableLibraryAggregateTrash { point in
                observation.record(point)
            }

            XCTAssertEqual(
                persistence.moveToTrash(.chat(chat.chat.id), at: root, in: scope),
                .succeeded
            )
            XCTAssertEqual(
                observation.points,
                [
                    .afterRename,
                    .afterSourceParentFlush,
                    .afterDestinationParentFlush,
                ]
            )
        }
    }

    func testFailureAfterAtomicRenameReportsCommitUncertainWithoutReversingMove() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Practice.audoralibrary")
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let chat = try PortableChatPersistence().create(
                makeChatSeed(scope: scope),
                at: root
            )
            let active = root.appendingPathComponent(
                "chats/\(chat.chat.id.rawValue)"
            )
            let trashed = root.appendingPathComponent(
                "trash/chats/\(chat.chat.id.rawValue)"
            )
            let originalTree = try snapshotTree(at: active)
            let persistence = PortableLibraryAggregateTrash { point in
                if point == .afterRename { throw TrashInjectedFault() }
            }

            XCTAssertEqual(
                persistence.moveToTrash(.chat(chat.chat.id), at: root, in: scope),
                .commitUncertain
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: active.path))
            XCTAssertEqual(try snapshotTree(at: trashed), originalTree)
        }
    }

    func testNonterminalSessionJobBlocksMoveUnderTheJobsAuthority() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Practice.audoralibrary")
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let sessionID = try SessionID("ses-20260830T120100000Z-2CDE")
            let active = root.appendingPathComponent(
                "sessions/\(sessionID.rawValue)"
            )
            try FileManager.default.createDirectory(
                at: active,
                withIntermediateDirectories: false
            )
            let job = SessionProcessingJob(
                jobID: try TranscriptionJobID("job-20260830T120500000Z-5GHJ"),
                sessionID: sessionID,
                revisionID: try TranscriptRevisionID(
                    "trv-20260830T120600000Z-6JKM"
                ),
                profileID: "qualified-profile-v1",
                createdAt: try UTCInstant("2026-08-30T12:05:00.000Z"),
                state: .queued,
                expectedSelectedRevisionID: nil,
                cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                    "cancel-trash-test"
                )
            )
            let jobs = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: scope.libraryID
            )
            let createdJob = await jobs.create(job)
            XCTAssertEqual(createdJob, .written(job))

            XCTAssertEqual(
                PortableLibraryAggregateTrash().moveToTrash(
                    .session(sessionID),
                    at: root,
                    in: scope
                ),
                .busy
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(
                        "trash/sessions/\(sessionID.rawValue)"
                    ).path
                )
            )
        }
    }

    func testSessionThatWinsMoveAuthorityCannotStartANewJobFromStaleSelection()
        async throws
    {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Practice.audoralibrary")
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let sessionID = try SessionID("ses-20260830T120100000Z-2CDE")
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("sessions/\(sessionID.rawValue)"),
                withIntermediateDirectories: false
            )
            let jobs = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: scope.libraryID
            )
            let job = SessionProcessingJob(
                jobID: try TranscriptionJobID("job-20260830T120500000Z-5GHJ"),
                sessionID: sessionID,
                revisionID: try TranscriptRevisionID(
                    "trv-20260830T120600000Z-6JKM"
                ),
                profileID: "qualified-profile-v1",
                createdAt: try UTCInstant("2026-08-30T12:05:00.000Z"),
                state: .queued,
                expectedSelectedRevisionID: nil,
                cancellationAuthorityID: try TranscriptionCancellationAuthorityID(
                    "cancel-stale-selection-trash-test"
                )
            )

            XCTAssertEqual(
                PortableLibraryAggregateTrash().moveToTrash(
                    .session(sessionID),
                    at: root,
                    in: scope
                ),
                .succeeded
            )
            let createResult = await jobs.create(job)
            XCTAssertEqual(createResult, .failed)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(
                        "jobs/\(job.jobID.rawValue)"
                    ).path
                )
            )
        }
    }

    func testLiveChatInvocationBlocksMoveUsingTheInvocationNamespace() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Practice.audoralibrary")
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let chats = PortableChatPersistence()
            let created = try chats.create(makeChatSeed(scope: scope), at: root)
            let edited = try created.chat.draft.edited(
                text: "Keep this exact pending turn.",
                at: try UTCInstant("2026-08-30T12:00:01.000Z")
            )
            guard case .committed = try chats.saveDraft(
                SaveChatDraftMutation(
                    library: scope,
                    chatID: created.chat.id,
                    replacement: edited
                ),
                at: root
            ) else { return XCTFail("Draft did not commit") }
            let pending = PendingUserTurn(
                id: try PendingUserTurnID("ptu-20260830T120002000Z-5KMN"),
                draftID: edited.draftID,
                draftVersion: edited.version,
                responsePositionID: try ChatResponsePositionID(
                    "rsp-20260830T120002000Z-6PQR"
                )
            )
            guard case .committed = try chats.lockPendingUserTurn(
                LockPendingUserTurnMutation(
                    library: scope,
                    chatID: created.chat.id,
                    pendingUserTurn: pending
                ),
                at: root
            ) else { return XCTFail("Pending User Turn did not commit") }
            let lease = try XCTUnwrap(
                chats.acquireInvocationLivenessLease(
                    at: root,
                    in: scope,
                    for: PendingCoachInvocationRequest(
                        library: scope,
                        chatID: created.chat.id,
                        pendingUserTurnID: pending.id
                    )
                )
            )
            let trash = PortableLibraryAggregateTrash()

            XCTAssertEqual(
                trash.moveToTrash(.chat(created.chat.id), at: root, in: scope),
                .busy
            )
            lease.release()
            XCTAssertEqual(
                trash.moveToTrash(.chat(created.chat.id), at: root, in: scope),
                .succeeded
            )
        }
    }
}

private final class TrashFaultObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PortableLibraryAggregateTrashFaultPoint] = []

    var points: [PortableLibraryAggregateTrashFaultPoint] {
        lock.withLock { recorded }
    }

    func record(_ point: PortableLibraryAggregateTrashFaultPoint) {
        lock.withLock { recorded.append(point) }
    }
}

private final class TrashCatalogReadRaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isAvailable = true

    func claim() -> Bool {
        lock.withLock {
            guard isAvailable else { return false }
            isAvailable = false
            return true
        }
    }
}

private final class TrashCatalogFaultCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var occurrenceCount: Int { lock.withLock { count } }

    func claim(occurrence: Int) -> Bool {
        lock.withLock {
            count += 1
            return count == occurrence
        }
    }
}

private struct TrashInjectedFault: Error {}

private func defaultChatCatalogRow(_ chatID: ChatID) throws -> LibraryCatalogRow {
    .chat(
        chatID,
        LibraryChatCatalogMetadata(
            title: .newChat,
            createdAt: try UTCInstant("2026-08-30T12:00:00.000Z"),
            updatedAt: try UTCInstant("2026-08-30T12:00:00.000Z")
        )
    )
}

private func snapshotTree(at root: URL) throws -> [String: Data?] {
    let enumerator = try XCTUnwrap(
        FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
    )
    var snapshot: [String: Data?] = [:]
    while let entry = enumerator.nextObject() as? URL {
        let relative = String(entry.path.dropFirst(root.path.count + 1))
        let values = try entry.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        if values.isSymbolicLink == true {
            snapshot[relative] = Data("symlink".utf8)
        } else if values.isDirectory == true {
            snapshot[relative] = nil
        } else {
            snapshot[relative] = try Data(contentsOf: entry)
        }
    }
    return snapshot
}
