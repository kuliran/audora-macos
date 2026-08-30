import AudoraApplication
import AudoraDomain
@testable import AudoraMacInfrastructure
import Darwin
import Foundation
import XCTest

final class PortableLibraryPersistenceTests: XCTestCase {
    func testCreatePublishesExactLayoutAndReopensSamePortableAuthority() throws {
        try withTemporaryParent { parent in
            let destination = parent.appendingPathComponent("Practice.audoralibrary")
            let persistence = PortableLibraryPersistence()
            let seed = try makeSeed()

            let created = try persistence.create(at: destination, seed: seed)
            let reopened = try persistence.open(at: destination)

            XCTAssertEqual(created.manifest.libraryID, seed.libraryID)
            XCTAssertEqual(created.preferences, seed.preferences)
            XCTAssertEqual(created.profileHead, seed.profileHead)
            XCTAssertEqual(reopened, .readWrite(created))
            XCTAssertEqual(try tree(at: destination), Self.expectedInitialTree)

            let manifest = try Data(contentsOf: destination.appendingPathComponent("library.json"))
            let preferences = try Data(contentsOf: destination.appendingPathComponent("preferences.json"))
            let head = try Data(contentsOf: destination.appendingPathComponent("profile/head.json"))
            XCTAssertEqual(manifest, try persistence.encodeManifest(created.manifest))
            XCTAssertEqual(preferences, try persistence.encodePreferences(created.preferences))
            XCTAssertEqual(head, try persistence.encodeProfileHead(created.profileHead))
            XCTAssertEqual(manifest.last, 0x0A)
            XCTAssertEqual(preferences.last, 0x0A)
            XCTAssertEqual(head.last, 0x0A)

            let combined = try XCTUnwrap(
                String(data: manifest + preferences + head, encoding: .utf8)
            )
            for forbidden in [
                "bookmark", "absolutePath", "modelPath", "cachePath", "credential",
                "permissionGrant", "hardwareId",
            ] {
                XCTAssertFalse(combined.contains(forbidden))
            }
        }
    }

    func testRenameAndClosedCopyPreserveIdentityAndPreferences() throws {
        try withTemporaryParent { parent in
            let original = parent.appendingPathComponent("Original.audoralibrary")
            let renamed = parent.appendingPathComponent("Renamed.audoralibrary")
            let copied = parent.appendingPathComponent("Copied.audoralibrary")
            let persistence = PortableLibraryPersistence()
            let authority = try persistence.create(at: original, seed: makeSeed())

            try FileManager.default.moveItem(at: original, to: renamed)
            guard case let .readWrite(afterRename) = try persistence.open(at: renamed) else {
                return XCTFail("renamed Library became read-only")
            }
            XCTAssertEqual(afterRename, authority)

            try FileManager.default.copyItem(at: renamed, to: copied)
            guard case let .readWrite(afterCopy) = try persistence.open(at: copied) else {
                return XCTFail("copied Library became read-only")
            }
            XCTAssertEqual(afterCopy, authority)
        }
    }

    func testExistingDestinationIsNeverOverwrittenOrMerged() throws {
        try withTemporaryParent { parent in
            let destination = parent.appendingPathComponent("Existing.audoralibrary")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let sentinel = destination.appendingPathComponent("sentinel.txt")
            try Data("keep".utf8).write(to: sentinel)

            XCTAssertThrowsError(
                try PortableLibraryPersistence().create(at: destination, seed: makeSeed())
            ) { error in
                XCTAssertEqual(error as? PortableLibraryPersistenceError, .destinationExists)
            }
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["sentinel.txt"])
        }
    }

    func testDestinationAppearingAtFinalCommitIsNeverOverwrittenOrMerged() throws {
        try withTemporaryParent { parent in
            let destination = parent.appendingPathComponent("Raced.audoralibrary")
            let persistence = PortableLibraryPersistence { point in
                guard point == .beforeFinalInstall else { return }
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
            }

            XCTAssertThrowsError(
                try persistence.create(at: destination, seed: makeSeed())
            ) { error in
                XCTAssertEqual(error as? PortableLibraryPersistenceError, .destinationExists)
            }
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: destination.path),
                []
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: parent.path)
                    .filter { $0.hasPrefix(".audora-create-") },
                []
            )
        }
    }

    func testCreateFaultMatrixLeavesFinalAbsentOrFullyCoherent() throws {
        let roots = ["library.json", "preferences.json", "profile/head.json"]
        var points: [PortableLibraryFaultPoint] = [
            .stagingDirectoryCreated,
            .beforeStagedValidation,
            .beforeFinalInstall,
            .afterFinalInstall,
            .afterParentFlush,
        ]
        for root in roots {
            points.append(contentsOf: [
                .beforeRootPartialWrite(root),
                .afterRootPartialWrite(root),
                .afterRootFileFlush(root),
                .afterRootInstall(root),
                .afterDirectoryFlush(root),
            ])
        }

        for point in points {
            try withTemporaryParent { parent in
                let destination = parent.appendingPathComponent("Faulted.audoralibrary")
                let persistence = PortableLibraryPersistence { reached in
                    if reached == point {
                        throw PortableLibraryPersistenceError.injectedFault(point)
                    }
                }
                XCTAssertThrowsError(
                    try persistence.create(at: destination, seed: makeSeed()),
                    String(describing: point)
                )

                if FileManager.default.fileExists(atPath: destination.path) {
                    guard case .readWrite = try PortableLibraryPersistence().open(at: destination) else {
                        return XCTFail("installed fault result was not coherent")
                    }
                    XCTAssertEqual(try tree(at: destination), Self.expectedInitialTree)
                }
                let leftovers = try FileManager.default.contentsOfDirectory(atPath: parent.path)
                    .filter { $0.hasPrefix(".audora-create-") }
                XCTAssertEqual(leftovers, [], String(describing: point))
            }
        }
    }

    func testSupportedRootsStrictlyRejectUnknownKeysInvalidValuesAndOversize() throws {
        let mutations: [(String, Data)] = [
            (
                "preferences.json",
                Data(#"{"annotationsVisible":true,"language":"en","modelPath":"synthetic","playbackRate":1.0,"schemaVersion":1}"#.utf8)
            ),
            (
                "library.json",
                Data(#"{"createdAt":"2026-08-30T12:00:00.000Z","formatName":"audora-library","lastSuccessfulMigration":1,"libraryId":"ses-20260830T120000000Z-2ABC","schemaVersion":1}"#.utf8)
            ),
            (
                "library.json",
                Data(#"{"createdAt":"2026-02-30T12:00:00.000Z","formatName":"audora-library","lastSuccessfulMigration":1,"libraryId":"lib-20260830T120000000Z-2ABC","schemaVersion":1}"#.utf8)
            ),
            (
                "profile/head.json",
                Data(#"{"currentRevisionId":"prf-20260830T120100000Z-3DEF","generation":1,"schemaVersion":1,"statementGeneration":1,"updatedAt":"2026-08-30T12:01:00.000Z"}"#.utf8)
            ),
            (
                "profile/head.json",
                Data(#"{"generation":-1,"schemaVersion":1,"statementGeneration":0,"updatedAt":"2026-08-30T12:00:00.000Z"}"#.utf8)
            ),
            (
                "preferences.json",
                Data(repeating: 0x20, count: PortableLibraryPersistence.maximumRootBytes + 1)
            ),
        ]

        for (relative, bytes) in mutations {
            try withCreatedLibrary { root, _ in
                try bytes.write(to: root.appendingPathComponent(relative))
                XCTAssertThrowsError(
                    try PortableLibraryPersistence().open(at: root),
                    relative
                )
            }
        }
    }

    func testSchemaEnvelopeRejectsBooleanFractionNegativeAndOverflowExactly() throws {
        let invalidVersions = [
            "true",
            "1.5",
            "-1",
            "18446744073709551616",
        ]
        for version in invalidVersions {
            try withCreatedLibrary { root, _ in
                let bytes = Data(
                    "{\"annotationsVisible\":true,\"language\":\"en\",\"playbackRate\":1.0,\"schemaVersion\":\(version)}".utf8
                )
                try bytes.write(to: root.appendingPathComponent("preferences.json"))
                XCTAssertThrowsError(try PortableLibraryPersistence().open(at: root), version)
            }
        }
    }

    func testRootReadRejectsFIFOAndSymlinkWithoutBlockingOrFollowing() throws {
        try withCreatedLibrary { root, _ in
            let preference = root.appendingPathComponent("preferences.json")
            try FileManager.default.removeItem(at: preference)
            XCTAssertEqual(mkfifo(preference.path, 0o600), 0)
            XCTAssertThrowsError(try PortableLibraryPersistence().open(at: root)) { error in
                XCTAssertEqual(error as? PortableLibraryPersistenceError, .invalidLayout)
            }
        }

        try withCreatedLibrary { root, _ in
            let preference = root.appendingPathComponent("preferences.json")
            try FileManager.default.removeItem(at: preference)
            try FileManager.default.createSymbolicLink(
                at: preference,
                withDestinationURL: URL(fileURLWithPath: "/dev/null")
            )
            XCTAssertThrowsError(try PortableLibraryPersistence().open(at: root)) { error in
                XCTAssertEqual(
                    error as? PortableLibraryPersistenceError,
                    .expectedPathIsSymlink
                )
            }
        }
    }

    func testOpenRemainsAnchoredWhenSelectedRootEntryIsReplacedAfterOpen() throws {
        try withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Selected.audoralibrary")
            let movedRoot = parent.appendingPathComponent("Moved.audoralibrary")
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let persistence = PortableLibraryPersistence { point in
                guard point == .afterRootDescriptorOpened else { return }
                try FileManager.default.moveItem(at: root, to: movedRoot)
                try FileManager.default.createSymbolicLink(
                    at: root,
                    withDestinationURL: URL(fileURLWithPath: "/dev/null")
                )
            }

            XCTAssertEqual(try persistence.open(at: root), .readWrite(authority))
        }
    }

    func testIntermediateDirectorySwapToSymlinkIsRejectedAfterLayoutValidation() throws {
        try withCreatedLibrary { root, _ in
            let profile = root.appendingPathComponent("profile", isDirectory: true)
            let movedProfile = root.appendingPathComponent("moved-profile", isDirectory: true)
            let persistence = PortableLibraryPersistence { point in
                guard point == .beforeRootRead("profile/head.json") else { return }
                try FileManager.default.moveItem(at: profile, to: movedProfile)
                try FileManager.default.createSymbolicLink(
                    at: profile,
                    withDestinationURL: movedProfile
                )
            }

            XCTAssertThrowsError(try persistence.open(at: root)) { error in
                XCTAssertEqual(
                    error as? PortableLibraryPersistenceError,
                    .expectedPathIsSymlink
                )
            }
        }
    }

    func testNewerRootOpensReadOnlyAndRemainsByteIdentical() throws {
        try withCreatedLibrary { root, authority in
            let preferences = root.appendingPathComponent("preferences.json")
            let newer = Data(
                #"{"annotationsVisible":false,"futurePortablePreference":"preserve-exactly","language":"en","playbackRate":1.25,"schemaVersion":2}"#.utf8
            )
            try newer.write(to: preferences)

            XCTAssertEqual(
                try PortableLibraryPersistence().open(at: root),
                .readOnly(libraryID: authority.manifest.libraryID)
            )
            XCTAssertEqual(try Data(contentsOf: preferences), newer)
        }
    }

    func testMutableRootWriterRejectsReadOnlyLibraryAndPreservesNewerBytes() throws {
        try withCreatedLibrary { root, _ in
            let preferences = root.appendingPathComponent("preferences.json")
            let newer = Data(
                #"{"annotationsVisible":false,"futurePortablePreference":"preserve-exactly","language":"en","playbackRate":1.25,"schemaVersion":2}"#.utf8
            )
            try newer.write(to: preferences)
            let persistence = PortableLibraryPersistence()
            let supportedReplacement = try persistence.encodePreferences(.defaults)

            XCTAssertThrowsError(
                try persistence.atomicallyReplaceRoot(
                    supportedReplacement,
                    relativePath: LibraryRelativePath("preferences.json"),
                    under: root
                )
            ) { error in
                XCTAssertEqual(error as? PortableLibraryPersistenceError, .readOnlyLibrary)
            }
            XCTAssertEqual(try Data(contentsOf: preferences), newer)
        }
    }

    func testMutableRootWriterRejectsNonMutableAuthoritativeRoot() throws {
        try withCreatedLibrary { root, authority in
            let persistence = PortableLibraryPersistence()
            let manifest = try persistence.encodeManifest(authority.manifest)
            XCTAssertThrowsError(
                try persistence.atomicallyReplaceRoot(
                    manifest,
                    relativePath: LibraryRelativePath("library.json"),
                    under: root
                )
            ) { error in
                XCTAssertEqual(
                    error as? PortableLibraryPersistenceError,
                    .unsupportedMutableRoot
                )
            }
        }
    }

    func testNewerRootDoesNotHideCorruptionInAnotherSupportedRoot() throws {
        try withCreatedLibrary { root, _ in
            let newer = Data(
                #"{"annotationsVisible":false,"future":"preserve","language":"en","playbackRate":1.25,"schemaVersion":2}"#.utf8
            )
            try newer.write(to: root.appendingPathComponent("preferences.json"))
            try Data(#"{"generation":-1,"schemaVersion":1,"statementGeneration":0,"updatedAt":"2026-08-30T12:00:00.000Z"}"#.utf8)
                .write(to: root.appendingPathComponent("profile/head.json"))

            XCTAssertThrowsError(try PortableLibraryPersistence().open(at: root))
            XCTAssertEqual(
                try Data(contentsOf: root.appendingPathComponent("preferences.json")),
                newer
            )
        }
    }

    func testSiblingPartialReplacementReopensCompleteOldOrNewRoots() throws {
        for relativeRaw in ["preferences.json", "profile/head.json"] {
            let relative = try LibraryRelativePath(relativeRaw)
            for afterInstall in [false, true] {
                try withCreatedLibrary { root, authority in
                    let point: PortableLibraryFaultPoint = afterInstall
                        ? .afterMutableRootInstall(relativeRaw)
                        : .beforeMutableRootInstall(relativeRaw)
                    let persistence = PortableLibraryPersistence { reached in
                        if reached == point {
                            throw PortableLibraryPersistenceError.injectedFault(point)
                        }
                    }
                    let newData: Data
                    if relativeRaw == "preferences.json" {
                        newData = try persistence.encodePreferences(
                            LibraryPreferences(
                                language: .english,
                                annotationsVisible: false,
                                playbackRate: 1.25
                            )
                        )
                    } else {
                        newData = try persistence.encodeProfileHead(
                            ProfileHead(
                                generation: 1,
                                statementGeneration: 1,
                                selection: .null,
                                updatedAt: try UTCInstant("2026-08-30T12:01:00.000Z")
                            )
                        )
                    }
                    XCTAssertThrowsError(
                        try persistence.atomicallyReplaceRoot(
                            newData,
                            relativePath: relative,
                            under: root
                        )
                    )
                    guard case let .readWrite(reopened) = try PortableLibraryPersistence().open(at: root) else {
                        return XCTFail("supported replacement became read-only")
                    }
                    if relativeRaw == "preferences.json" {
                        XCTAssertEqual(reopened.preferences.annotationsVisible, afterInstall ? false : true)
                        XCTAssertEqual(reopened.preferences.playbackRate, afterInstall ? 1.25 : 1.0)
                    } else {
                        XCTAssertEqual(reopened.profileHead.generation, afterInstall ? 1 : authority.profileHead.generation)
                    }
                }
            }
        }
    }

    func testOpenReconcilesOnlyARecognizedAbandonedAudioImportTree() throws {
        try withCreatedLibrary { root, _ in
            let publications = root.appendingPathComponent("staging/publications")
            let transaction = publications.appendingPathComponent(
                "audio_staging_0123456789ABCDEF0123456789ABCDEF"
            )
            let session = transaction.appendingPathComponent(
                "ses-20260830T120000000Z-3DEF"
            )
            for directory in [
                session.appendingPathComponent("audio"),
                session.appendingPathComponent("transcripts"),
                session.appendingPathComponent("annotations"),
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

            guard case .readWrite = try PortableLibraryPersistence().open(at: root) else {
                return XCTFail("supported Library became read-only")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.path))
        }
    }

    func testOpenPreservesUnknownNewerAndOversizedPublicationEntries() throws {
        try withCreatedLibrary { root, _ in
            let publications = root.appendingPathComponent("staging/publications")
            let unknown = publications.appendingPathComponent("future-publication")
            try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
            let sentinel = Data("preserve-unknown".utf8)
            try sentinel.write(to: unknown.appendingPathComponent("sentinel"))

            let newer = publications.appendingPathComponent(
                "audio_staging_11111111111111111111111111111111"
            ).appendingPathComponent("ses-20260830T120000000Z-3DEF")
            try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
            let newerBytes = Data(
                #"{"future":"preserve","schemaVersion":2,"sessionId":"ses-20260830T120000000Z-3DEF"}"#.utf8
            )
            try newerBytes.write(to: newer.appendingPathComponent("session.json"))

            let oversized = publications.appendingPathComponent(
                "audio_staging_22222222222222222222222222222222"
            ).appendingPathComponent("ses-20260830T120000000Z-4EFG")
            try FileManager.default.createDirectory(at: oversized, withIntermediateDirectories: true)
            let oversizedURL = oversized.appendingPathComponent(
                ".session.json.33333333-3333-3333-3333-333333333333.partial"
            )
            let oversizedBytes = Data(
                repeating: 0x20,
                count: PortableAudioImportPersistence.maximumManifestBytes + 1
            )
            try oversizedBytes.write(to: oversizedURL)

            guard case .readWrite = try PortableLibraryPersistence().open(at: root) else {
                return XCTFail("supported Library became read-only")
            }
            XCTAssertEqual(try Data(contentsOf: unknown.appendingPathComponent("sentinel")), sentinel)
            XCTAssertEqual(try Data(contentsOf: newer.appendingPathComponent("session.json")), newerBytes)
            XCTAssertEqual(try Data(contentsOf: oversizedURL), oversizedBytes)
        }
    }

    private func withCreatedLibrary(
        _ body: (URL, PortableLibraryAuthority) throws -> Void
    ) throws {
        try withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Synthetic.audoralibrary")
            let authority = try PortableLibraryPersistence().create(at: root, seed: makeSeed())
            try body(root, authority)
        }
    }

    private func withTemporaryParent(_ body: (URL) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-library-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        try body(parent)
    }

    private func makeSeed() throws -> NewLibrarySeed {
        let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
        return NewLibrarySeed(
            libraryID: try LibraryID("lib-20260830T120000000Z-2ABC"),
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

    private func tree(at root: URL) throws -> [String] {
        var values: [String] = []
        try appendTree(at: root, relativeToRoot: "", into: &values)
        return values.sorted()
    }

    private func appendTree(
        at directory: URL,
        relativeToRoot parent: String,
        into values: inout [String]
    ) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        for child in children {
            let relative = parent.isEmpty
                ? child.lastPathComponent
                : "\(parent)/\(child.lastPathComponent)"
            let metadata = try child.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            let isDirectory = metadata.isDirectory == true
            values.append(relative + (isDirectory ? "/" : ""))
            if isDirectory, metadata.isSymbolicLink != true {
                try appendTree(
                    at: child,
                    relativeToRoot: relative,
                    into: &values
                )
            }
        }
    }

    private static let expectedInitialTree = [
        "chats/",
        "invocations/",
        "jobs/",
        "library.json",
        "preferences.json",
        "profile/",
        "profile/head.json",
        "profile/revisions/",
        "sessions/",
        "staging/",
        "staging/jobs/",
        "staging/publications/",
        "staging/recordings/",
        "trash/",
        "trash/chats/",
        "trash/sessions/",
    ].sorted()
}
