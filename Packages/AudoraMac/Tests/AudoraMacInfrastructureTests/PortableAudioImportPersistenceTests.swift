import AudoraApplication
import AudoraContracts
import AudoraDomain
@testable import AudoraMacInfrastructure
import CryptoKit
import Darwin
import Foundation
import XCTest

final class PortableAudioImportPersistenceTests: XCTestCase {
    func testLibraryAuthorityIsRevalidatedBeforeStagingAndImmediatelyBeforeInstall() throws {
        try withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Synthetic.audoralibrary")
            try createLibrary(at: root)
            let libraryManifest = root.appendingPathComponent("library.json")
            let originalManifest = try Data(contentsOf: libraryManifest)
            let newerManifest = Data(
                #"{"futurePortableField":"preserve","schemaVersion":2}"#.utf8
            )
            try newerManifest.write(to: libraryManifest)

            let persistence = PortableAudioImportPersistence()
            XCTAssertThrowsError(
                try persistence.begin(
                    root: root,
                    stagingID: AudioStagingID("staging_newer_library")!,
                    seed: importedSeed(),
                    container: .wav
                )
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .libraryChanged)
            }
            XCTAssertEqual(try Data(contentsOf: libraryManifest), newerManifest)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: root.appendingPathComponent("staging/publications").path
                ),
                []
            )

            try Data("corrupt-library-root".utf8).write(to: libraryManifest)
            XCTAssertThrowsError(
                try persistence.begin(
                    root: root,
                    stagingID: AudioStagingID("staging_corrupt_library")!,
                    seed: importedSeed(),
                    container: .wav
                )
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .candidateCorrupt)
            }

            try originalManifest.write(to: libraryManifest)
            let prepared = try prepareImport(root: root, persistence: persistence)
            defer {
                persistence.discard(prepared.location)
                prepared.location.close()
            }
            try newerManifest.write(to: libraryManifest)
            XCTAssertThrowsError(
                try persistence.install(prepared.location, expected: prepared.session)
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .libraryChanged)
            }
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: root.appendingPathComponent("sessions").path
                ),
                []
            )
            XCTAssertEqual(try Data(contentsOf: libraryManifest), newerManifest)
        }
    }

    func testInstallRetainsExactOriginalAndReopensSameCanonicalTimelineAfterRenameAndCopy() throws {
        try withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Original.audoralibrary")
            try createLibrary(at: root)
            let originalBytes = syntheticSourceWAV()
            let persistence = PortableAudioImportPersistence()
            let prepared = try prepareImport(
                root: root,
                sourceBytes: originalBytes,
                persistence: persistence
            )
            defer { prepared.location.close() }

            let reopened = try persistence.install(
                prepared.location,
                expected: prepared.session
            )

            XCTAssertEqual(reopened.session, prepared.session)
            let installed = root
                .appendingPathComponent("sessions")
                .appendingPathComponent(prepared.session.sessionID.rawValue)
            XCTAssertEqual(
                try Data(contentsOf: installed.appendingPathComponent("audio/original.wav")),
                originalBytes
            )
            XCTAssertEqual(
                try Data(contentsOf: installed.appendingPathComponent("audio/audio.wav")).count,
                50
            )
            XCTAssertEqual(
                try sessionTree(at: installed),
                [
                    "annotations/", "audio/", "audio/audio.json", "audio/audio.wav",
                    "audio/original.wav", "session.json", "transcripts/",
                ].sorted()
            )
            let roots = try Data(contentsOf: installed.appendingPathComponent("session.json")) +
                Data(contentsOf: installed.appendingPathComponent("audio/audio.json"))
            let text = try XCTUnwrap(String(data: roots, encoding: .utf8))
            for forbidden in [
                parent.path, "bookmark", "hardware", "device", "absolutePath", "file://",
            ] {
                XCTAssertFalse(text.contains(forbidden))
            }

            let renamed = parent.appendingPathComponent("Renamed.audoralibrary")
            let copied = parent.appendingPathComponent("Copied.audoralibrary")
            try FileManager.default.moveItem(at: root, to: renamed)
            XCTAssertEqual(
                try persistence.openSession(
                    at: renamed,
                    sessionID: prepared.session.sessionID
                ),
                .readWrite(prepared.session)
            )
            try FileManager.default.copyItem(at: renamed, to: copied)
            XCTAssertEqual(
                try persistence.openSession(
                    at: copied,
                    sessionID: prepared.session.sessionID
                ),
                .readWrite(prepared.session)
            )
        }
    }

    func testDestinationAppearingEmptyAtFinalCommitIsNeverOverwrittenOrMerged() throws {
        try withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Synthetic.audoralibrary")
            try createLibrary(at: root)
            let destination = root
                .appendingPathComponent("sessions")
                .appendingPathComponent(try importedSeed().sessionID.rawValue)
            let persistence = PortableAudioImportPersistence { point in
                guard point == .beforeSessionInstall else { return }
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
            }
            let prepared = try prepareImport(root: root, persistence: persistence)
            defer {
                persistence.discard(prepared.location)
                prepared.location.close()
            }
            XCTAssertThrowsError(
                try persistence.install(prepared.location, expected: prepared.session)
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .destinationCollision)
            }
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: destination.path),
                []
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: prepared.location.originalURL.path
                )
            )
        }
    }

    func testInstallRejectsAByteIdenticalStagedSessionDirectorySwapBeforeRename() throws {
        try withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Synthetic.audoralibrary")
            try createLibrary(at: root)
            let transaction = root.appendingPathComponent(
                "staging/publications/staging_fixture"
            )
            let staged = transaction.appendingPathComponent(
                try importedSeed().sessionID.rawValue
            )
            let displaced = transaction.appendingPathComponent("displaced-session")
            let persistence = PortableAudioImportPersistence { point in
                guard point == .beforeSessionInstall else { return }
                try FileManager.default.moveItem(at: staged, to: displaced)
                try FileManager.default.copyItem(at: displaced, to: staged)
            }
            let prepared = try prepareImport(root: root, persistence: persistence)
            defer {
                persistence.discard(prepared.location)
                prepared.location.close()
            }

            XCTAssertThrowsError(
                try persistence.install(prepared.location, expected: prepared.session)
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .candidateCorrupt)
            }
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: root.appendingPathComponent("sessions").path
                ),
                []
            )
        }
    }

    func testFinalReopenReportsNeedsRefreshWhenTheInstalledSessionIsRemoved() throws {
        try withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Synthetic.audoralibrary")
            try createLibrary(at: root)
            let sessionID = try importedSeed().sessionID
            let destination = root.appendingPathComponent("sessions")
                .appendingPathComponent(sessionID.rawValue)
            let displaced = parent.appendingPathComponent("displaced-session")
            let persistence = PortableAudioImportPersistence { point in
                guard point == .beforeFinalReopen else { return }
                try FileManager.default.moveItem(at: destination, to: displaced)
            }
            let prepared = try prepareImport(root: root, persistence: persistence)
            defer { prepared.location.close() }

            XCTAssertThrowsError(
                try persistence.install(prepared.location, expected: prepared.session)
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .installedNeedsRefresh)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(try sessionTree(at: displaced), [
                "annotations/", "audio/", "audio/audio.json", "audio/audio.wav",
                "audio/original.wav", "session.json", "transcripts/",
            ].sorted())
        }
    }

    func testFinalReopenReportsNeedsRefreshForAByteIdenticalInstalledReplacement() throws {
        try withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Synthetic.audoralibrary")
            try createLibrary(at: root)
            let sessionID = try importedSeed().sessionID
            let destination = root.appendingPathComponent("sessions")
                .appendingPathComponent(sessionID.rawValue)
            let displaced = parent.appendingPathComponent("displaced-session")
            let persistence = PortableAudioImportPersistence { point in
                guard point == .beforeFinalReopen else { return }
                try FileManager.default.moveItem(at: destination, to: displaced)
                try FileManager.default.copyItem(at: displaced, to: destination)
            }
            let prepared = try prepareImport(root: root, persistence: persistence)
            defer { prepared.location.close() }

            XCTAssertThrowsError(
                try persistence.install(prepared.location, expected: prepared.session)
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .installedNeedsRefresh)
            }
            XCTAssertEqual(
                try PortableAudioImportPersistence().openSession(
                    at: root,
                    sessionID: prepared.session.sessionID
                ),
                .readWrite(prepared.session)
            )
        }
    }

    func testFaultMatrixPublishesNoPartialSessionBeforeCommitAndNeverDeletesAfterCommit() throws {
        let precommit: [AudioImportPersistenceFault] = [
            .stagingCreated,
            .beforeSourceFinalValidation,
            .afterSourceCopy,
            .afterCanonicalWrite,
            .afterAudioManifestInstall,
            .afterSessionManifestInstall,
            .beforeStagedValidation,
            .beforeSessionInstall,
        ]
        let postcommit: [AudioImportPersistenceFault] = [
            .afterSessionInstall,
            .beforeFinalReopen,
        ]

        for point in precommit + postcommit {
            try withTemporaryParent { parent in
                let root = parent.appendingPathComponent("Synthetic.audoralibrary")
                try createLibrary(at: root)
                let persistence = PortableAudioImportPersistence { reached in
                    if reached == point { throw AudioImportFailure.writeFailed }
                }
                var expectedSession: ImportedSession?
                XCTAssertThrowsError(
                    try performImport(root: root, persistence: persistence) { session in
                        expectedSession = session
                    },
                    String(describing: point)
                ) { error in
                    if postcommit.contains(point) {
                        XCTAssertEqual(
                            error as? AudioImportFailure,
                            .installedNeedsRefresh
                        )
                    }
                }
                let sessions = try FileManager.default.contentsOfDirectory(
                    atPath: root.appendingPathComponent("sessions").path
                )
                if postcommit.contains(point) {
                    let expected = try XCTUnwrap(expectedSession)
                    XCTAssertEqual(sessions, [expected.sessionID.rawValue])
                    XCTAssertEqual(
                        try PortableAudioImportPersistence().openSession(
                            at: root,
                            sessionID: expected.sessionID
                        ),
                        .readWrite(expected)
                    )
                } else {
                    XCTAssertEqual(sessions, [])
                }
            }
        }
    }

    func testSourceDescriptorRejectsFIFOAndSymlinkWithoutBlockingOrFollowing() throws {
        try withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Synthetic.audoralibrary")
            try createLibrary(at: root)
            let persistence = PortableAudioImportPersistence()

            for kind in ["fifo", "symlink"] {
                let location = try persistence.begin(
                    root: root,
                    stagingID: AudioStagingID("staging_\(kind)")!,
                    seed: importedSeed(),
                    container: .wav
                )
                defer {
                    persistence.discard(location)
                    location.close()
                }
                let source = parent.appendingPathComponent("source-\(kind).wav")
                if kind == "fifo" {
                    XCTAssertEqual(mkfifo(source.path, 0o600), 0)
                } else {
                    try FileManager.default.createSymbolicLink(
                        at: source,
                        withDestinationURL: URL(fileURLWithPath: "/dev/null")
                    )
                }
                XCTAssertThrowsError(
                    try persistence.copySource(
                        from: source,
                        into: location,
                        maximumBytes: 1_024
                    )
                ) { error in
                    XCTAssertTrue(
                        error as? AudioImportFailure == .unsupportedMedia ||
                            error as? AudioImportFailure == .unavailable
                    )
                }
                try? FileManager.default.removeItem(at: source)
            }
        }
    }

    func testOwnedDecodeCapabilityRemainsBoundToCopiedRegularFileAfterPathReplacement() throws {
        try withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Synthetic.audoralibrary")
            try createLibrary(at: root)
            let persistence = PortableAudioImportPersistence()
            let location = try persistence.begin(
                root: root,
                stagingID: AudioStagingID("staging_decode_identity")!,
                seed: importedSeed(),
                container: .wav
            )
            defer {
                persistence.discard(location)
                location.close()
            }
            let originalBytes = syntheticSourceWAV()
            let source = parent.appendingPathComponent("source.wav")
            try originalBytes.write(to: source)
            let fingerprint = try persistence.copySource(
                from: source,
                into: location,
                maximumBytes: 1_024
            )
            let owned = try persistence.openOriginalForDecoding(
                in: location,
                expected: fingerprint
            )

            let stagedPath = location.originalURL
            try FileManager.default.removeItem(at: stagedPath)
            try FileManager.default.createSymbolicLink(
                at: stagedPath,
                withDestinationURL: URL(fileURLWithPath: "/dev/null")
            )
            let duplicate = try owned.duplicateDescriptor()
            defer { Darwin.close(duplicate) }
            var bytes = [UInt8](repeating: 0, count: originalBytes.count)
            XCTAssertEqual(Darwin.read(duplicate, &bytes, bytes.count), bytes.count)
            XCTAssertEqual(Data(bytes), originalBytes)
        }
    }

    func testCapacityUsesTheRetainedRootDescriptorAfterPathReplacement() throws {
        try withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Synthetic.audoralibrary")
            let movedRoot = parent.appendingPathComponent("Moved.audoralibrary")
            let missingReplacement = parent.appendingPathComponent("missing-root")
            try createLibrary(at: root)
            let persistence = PortableAudioImportPersistence()
            let location = try persistence.begin(
                root: root,
                stagingID: AudioStagingID("staging_capacity_identity")!,
                seed: importedSeed(),
                container: .wav
            )
            defer { location.close() }

            try FileManager.default.moveItem(at: root, to: movedRoot)
            try FileManager.default.createSymbolicLink(
                at: root,
                withDestinationURL: missingReplacement
            )

            guard case let .available(bytes) = persistence.availableCapacity(at: location) else {
                return XCTFail("retained root descriptor did not report capacity")
            }
            XCTAssertGreaterThan(bytes, 0)

            location.close()
            XCTAssertEqual(persistence.availableCapacity(at: location), .unavailable)
        }
    }

    func testSourceMutationAndOversizeAndMalformedPrefixFailBeforeManifestPublication() throws {
        try withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Synthetic.audoralibrary")
            try createLibrary(at: root)
            let source = parent.appendingPathComponent("mutable.wav")
            try syntheticSourceWAV().write(to: source)
            let persistence = PortableAudioImportPersistence { point in
                guard point == .beforeSourceFinalValidation else { return }
                let descriptor = Darwin.open(source.path, O_WRONLY | O_APPEND | O_CLOEXEC)
                guard descriptor >= 0 else { throw AudioImportFailure.unavailable }
                defer { Darwin.close(descriptor) }
                var byte: UInt8 = 0
                guard Darwin.write(descriptor, &byte, 1) == 1 else {
                    throw AudioImportFailure.unavailable
                }
            }
            let location = try persistence.begin(
                root: root,
                stagingID: AudioStagingID("staging_mutation")!,
                seed: importedSeed(),
                container: .wav
            )
            defer {
                persistence.discard(location)
                location.close()
            }
            XCTAssertThrowsError(
                try persistence.copySource(
                    from: source,
                    into: location,
                    maximumBytes: 1_024
                )
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .sourceChanged)
            }
        }

        try withFreshStaging { parent, persistence, location in
            let oversized = parent.appendingPathComponent("oversized.wav")
            try syntheticSourceWAV().write(to: oversized)
            XCTAssertThrowsError(
                try persistence.copySource(
                    from: oversized,
                    into: location,
                    maximumBytes: 8
                )
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .sourceTooLarge)
            }
        }

        try withFreshStaging { parent, persistence, location in
            let malformed = parent.appendingPathComponent("malformed.wav")
            try Data("not-wave-data".utf8).write(to: malformed)
            XCTAssertThrowsError(
                try persistence.copySource(
                    from: malformed,
                    into: location,
                    maximumBytes: 1_024
                )
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .unsupportedMedia)
            }
        }
    }

    func testStagedRevalidationRejectsHashChangeSymlinkFIFOAndIntermediateAlias() throws {
        enum Mutation: CaseIterable { case hash, symlink, fifo, directoryAlias }
        for mutation in Mutation.allCases {
            try withTemporaryParent { parent in
                let root = parent.appendingPathComponent("Synthetic.audoralibrary")
                try createLibrary(at: root)
                let persistence = PortableAudioImportPersistence()
                let prepared = try prepareImport(root: root, persistence: persistence)
                defer {
                    persistence.discard(prepared.location)
                    prepared.location.close()
                }
                let audio = root.appendingPathComponent(
                    prepared.location.stagedSessionComponents.joined(separator: "/")
                ).appendingPathComponent("audio")
                switch mutation {
                case .hash:
                    let original = audio.appendingPathComponent("original.wav")
                    try Data("RIFFchangedWAVE".utf8).write(to: original)
                case .symlink:
                    let manifest = audio.appendingPathComponent("audio.json")
                    try FileManager.default.removeItem(at: manifest)
                    try FileManager.default.createSymbolicLink(
                        at: manifest,
                        withDestinationURL: URL(fileURLWithPath: "/dev/null")
                    )
                case .fifo:
                    let manifest = audio.appendingPathComponent("audio.json")
                    try FileManager.default.removeItem(at: manifest)
                    XCTAssertEqual(mkfifo(manifest.path, 0o600), 0)
                case .directoryAlias:
                    let moved = audio.deletingLastPathComponent()
                        .appendingPathComponent("moved-audio")
                    try FileManager.default.moveItem(at: audio, to: moved)
                    try FileManager.default.createSymbolicLink(
                        at: audio,
                        withDestinationURL: moved
                    )
                }

                XCTAssertThrowsError(
                    try persistence.install(
                        prepared.location,
                        expected: prepared.session
                    ),
                    String(describing: mutation)
                )
                XCTAssertEqual(
                    try FileManager.default.contentsOfDirectory(
                        atPath: root.appendingPathComponent("sessions").path
                    ),
                    []
                )
            }
        }
    }

    func testNewerManifestRemainsByteIdenticalReadOnlyAndDoesNotMaskSupportedCorruption() throws {
        try withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Synthetic.audoralibrary")
            try createLibrary(at: root)
            let persistence = PortableAudioImportPersistence()
            let prepared = try prepareImport(root: root, persistence: persistence)
            defer { prepared.location.close() }
            _ = try persistence.install(prepared.location, expected: prepared.session)
            let sessionRoot = root.appendingPathComponent("sessions")
                .appendingPathComponent(prepared.session.sessionID.rawValue)
            let audioManifest = sessionRoot.appendingPathComponent("audio/audio.json")
            let newer = Data(
                #"{"futurePortableField":"preserve","schemaVersion":2}"#.utf8
            )
            try newer.write(to: audioManifest)
            let sessionManifest = sessionRoot.appendingPathComponent("session.json")
            var sessionObject = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: sessionManifest)
                ) as? [String: Any]
            )
            sessionObject["audioManifestSha256"] = sha256Hex(newer)
            try JSONSerialization.data(
                withJSONObject: sessionObject,
                options: [.sortedKeys]
            ).write(to: sessionManifest)

            XCTAssertEqual(
                try persistence.openSession(
                    at: root,
                    sessionID: prepared.session.sessionID
                ),
                .readOnly(sessionID: prepared.session.sessionID)
            )
            XCTAssertEqual(try Data(contentsOf: audioManifest), newer)

            try Data(
                #"{"audioManifestSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","createdAt":"2026-08-30T12:00:00.000Z","durationMs":1,"future":"reject","schemaVersion":1,"sessionId":"ses-20260830T120000000Z-3DEF","transcriptRevisionIds":[]}"#.utf8
            ).write(to: sessionManifest)
            XCTAssertThrowsError(
                try persistence.openSession(
                    at: root,
                    sessionID: prepared.session.sessionID
                )
            )
            XCTAssertEqual(try Data(contentsOf: audioManifest), newer)
        }
    }

    func testSchemaVersionEnvelopeRejectsBooleanFractionNegativeAndOverflow() throws {
        for version in ["true", "1.5", "-1", "18446744073709551616"] {
            try withTemporaryParent { parent in
                let root = parent.appendingPathComponent("Synthetic.audoralibrary")
                try createLibrary(at: root)
                let persistence = PortableAudioImportPersistence()
                let prepared = try prepareImport(root: root, persistence: persistence)
                defer { prepared.location.close() }
                _ = try persistence.install(prepared.location, expected: prepared.session)
                let session = root.appendingPathComponent("sessions")
                    .appendingPathComponent(prepared.session.sessionID.rawValue)
                    .appendingPathComponent("session.json")
                try Data("{\"schemaVersion\":\(version)}".utf8).write(to: session)
                XCTAssertThrowsError(
                    try persistence.openSession(
                        at: root,
                        sessionID: prepared.session.sessionID
                    ),
                    version
                )
            }
        }
    }

    func testSessionDirectoryIdentityMustMatchManifestIdentity() throws {
        try withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Synthetic.audoralibrary")
            try createLibrary(at: root)
            let persistence = PortableAudioImportPersistence()
            let prepared = try prepareImport(root: root, persistence: persistence)
            defer { prepared.location.close() }
            _ = try persistence.install(prepared.location, expected: prepared.session)
            let sessionManifest = root.appendingPathComponent("sessions")
                .appendingPathComponent(prepared.session.sessionID.rawValue)
                .appendingPathComponent("session.json")
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: sessionManifest)
                ) as? [String: Any]
            )
            object["sessionId"] = "ses-20260830T120000000Z-4EFG"
            let mismatched = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            try mismatched.write(to: sessionManifest)

            XCTAssertThrowsError(
                try persistence.openSession(
                    at: root,
                    sessionID: prepared.session.sessionID
                )
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .candidateCorrupt)
            }
        }
    }

    func testCanonicalWAVRejectsRIFFSizeThatDoesNotMatchTheExactFileLength() throws {
        try withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Synthetic.audoralibrary")
            try createLibrary(at: root)
            let persistence = PortableAudioImportPersistence()
            let prepared = try prepareImport(root: root, persistence: persistence)
            defer { prepared.location.close() }
            _ = try persistence.install(prepared.location, expected: prepared.session)

            let sessionRoot = root.appendingPathComponent("sessions")
                .appendingPathComponent(prepared.session.sessionID.rawValue)
            let canonicalURL = sessionRoot.appendingPathComponent("audio/audio.wav")
            var canonical = try Data(contentsOf: canonicalURL)
            canonical.replaceSubrange(4..<8, with: [0, 0, 0, 0])
            try canonical.write(to: canonicalURL)

            let audioURL = sessionRoot.appendingPathComponent("audio/audio.json")
            var audio = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: audioURL)) as? [String: Any]
            )
            var canonicalObject = try XCTUnwrap(audio["canonical"] as? [String: Any])
            canonicalObject["sha256"] = sha256Hex(canonical)
            audio["canonical"] = canonicalObject
            let audioData = try JSONSerialization.data(withJSONObject: audio, options: [.sortedKeys])
            try audioData.write(to: audioURL)

            let sessionURL = sessionRoot.appendingPathComponent("session.json")
            var session = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: sessionURL)) as? [String: Any]
            )
            session["audioManifestSha256"] = sha256Hex(audioData)
            try JSONSerialization.data(withJSONObject: session, options: [.sortedKeys])
                .write(to: sessionURL)

            XCTAssertThrowsError(
                try persistence.openSession(
                    at: root,
                    sessionID: prepared.session.sessionID
                )
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .candidateCorrupt)
            }
        }
    }

    func testNewerSessionRootStillBindsDirectoryIdentityAndPreservesBytes() throws {
        try withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Synthetic.audoralibrary")
            try createLibrary(at: root)
            let persistence = PortableAudioImportPersistence()
            let prepared = try prepareImport(root: root, persistence: persistence)
            defer { prepared.location.close() }
            _ = try persistence.install(prepared.location, expected: prepared.session)
            let sessionManifest = root.appendingPathComponent("sessions")
                .appendingPathComponent(prepared.session.sessionID.rawValue)
                .appendingPathComponent("session.json")
            let newerText = "{\"futurePortableField\":\"preserve\",\"schemaVersion\":2," +
                "\"sessionId\":\"\(prepared.session.sessionID.rawValue)\"}"
            let newer = Data(newerText.utf8)
            try newer.write(to: sessionManifest)

            XCTAssertEqual(
                try persistence.openSession(
                    at: root,
                    sessionID: prepared.session.sessionID
                ),
                .readOnly(sessionID: prepared.session.sessionID)
            )
            XCTAssertEqual(try Data(contentsOf: sessionManifest), newer)

            let mismatchedText =
                "{\"futurePortableField\":\"preserve\",\"schemaVersion\":2," +
                "\"sessionId\":\"ses-20260830T120000000Z-4EFG\"}"
            let mismatched = Data(mismatchedText.utf8)
            try mismatched.write(to: sessionManifest)
            XCTAssertThrowsError(
                try persistence.openSession(
                    at: root,
                    sessionID: prepared.session.sessionID
                )
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .candidateCorrupt)
            }
            XCTAssertEqual(try Data(contentsOf: sessionManifest), mismatched)
        }
    }

    func testNewerSessionRootFreezesBeforeAssumingTheVersionOneChildLayout() throws {
        try withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Synthetic.audoralibrary")
            try createLibrary(at: root)
            let persistence = PortableAudioImportPersistence()
            let prepared = try prepareImport(root: root, persistence: persistence)
            defer { prepared.location.close() }
            _ = try persistence.install(prepared.location, expected: prepared.session)
            let sessionRoot = root.appendingPathComponent("sessions")
                .appendingPathComponent(prepared.session.sessionID.rawValue)
            let sessionManifest = sessionRoot.appendingPathComponent("session.json")
            let newerText = "{\"futurePortableField\":\"preserve\",\"schemaVersion\":2," +
                "\"sessionId\":\"\(prepared.session.sessionID.rawValue)\"}"
            let newer = Data(newerText.utf8)
            try newer.write(to: sessionManifest)
            try FileManager.default.removeItem(at: sessionRoot.appendingPathComponent("audio"))

            XCTAssertEqual(
                try persistence.openSession(
                    at: root,
                    sessionID: prepared.session.sessionID
                ),
                .readOnly(sessionID: prepared.session.sessionID)
            )
            XCTAssertEqual(try Data(contentsOf: sessionManifest), newer)
        }
    }

    func testRejectedContractFixturesRunThroughThePortableRuntimeTrustBoundary() throws {
        let cases: [(ContractResource, String, Bool, Bool)] = [
            (.rejectedAudioContainerCodecMismatch, "audio/audio.json", true, false),
            (.rejectedAudioMachinePath, "audio/audio.json", true, false),
            (.rejectedNewerAudioManifest, "audio/audio.json", true, true),
            (.rejectedSessionCrossRootHash, "session.json", false, false),
        ]

        for (resource, relativePath, rebindParent, expectsReadOnly) in cases {
            try withTemporaryParent { parent in
                let root = parent.appendingPathComponent("Synthetic.audoralibrary")
                try createLibrary(at: root)
                let persistence = PortableAudioImportPersistence()
                let prepared = try prepareImport(root: root, persistence: persistence)
                defer { prepared.location.close() }
                _ = try persistence.install(prepared.location, expected: prepared.session)
                let sessionRoot = root.appendingPathComponent("sessions")
                    .appendingPathComponent(prepared.session.sessionID.rawValue)
                let fixture = try ContractResources.data(for: resource)
                let manifest = sessionRoot.appendingPathComponent(relativePath)
                try fixture.write(to: manifest)
                if rebindParent {
                    let sessionManifest = sessionRoot.appendingPathComponent("session.json")
                    var object = try XCTUnwrap(
                        JSONSerialization.jsonObject(
                            with: Data(contentsOf: sessionManifest)
                        ) as? [String: Any]
                    )
                    object["audioManifestSha256"] = sha256Hex(fixture)
                    try JSONSerialization.data(
                        withJSONObject: object,
                        options: [.sortedKeys]
                    ).write(to: sessionManifest)
                }

                if expectsReadOnly {
                    XCTAssertEqual(
                        try persistence.openSession(
                            at: root,
                            sessionID: prepared.session.sessionID
                        ),
                        .readOnly(sessionID: prepared.session.sessionID),
                        resource.rawValue
                    )
                } else {
                    XCTAssertThrowsError(
                        try persistence.openSession(
                            at: root,
                            sessionID: prepared.session.sessionID
                        ),
                        resource.rawValue
                    ) { error in
                        XCTAssertEqual(error as? AudioImportFailure, .candidateCorrupt)
                    }
                }
                XCTAssertEqual(try Data(contentsOf: manifest), fixture)
            }
        }
    }

    private func performImport(
        root: URL,
        persistence: PortableAudioImportPersistence,
        prepared: (ImportedSession) -> Void
    ) throws {
        let location = try persistence.begin(
            root: root,
            stagingID: AudioStagingID("staging_fault")!,
            seed: importedSeed(),
            container: .wav
        )
        defer { location.close() }
        let source = root.deletingLastPathComponent().appendingPathComponent("fault-source.wav")
        try syntheticSourceWAV().write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try persistence.copySource(
            from: source,
            into: location,
            maximumBytes: 1_024
        )
        let descriptor = try persistence.createCanonicalDescriptor(in: location)
        let writer = try CanonicalWAVWriter(descriptor: descriptor, maximumFrameCount: 3)
        try writer.append([-0.5, 0, 0.5])
        let normalized = try writer.finish()
        try persistence.didFinishCanonicalWrite(in: location)
        let canonical = try persistence.fingerprint(
            components: location.stagedSessionComponents + ["audio", "audio.wav"],
            under: location,
            maximumBytes: normalized.byteCount
        )
        let session = try makeImportedSession(
            original: original,
            canonical: canonical,
            normalized: normalized
        )
        let rebound = try persistence.writeManifests(for: session, in: location)
        prepared(rebound)
        _ = try persistence.validateStaged(location, expected: rebound)
        _ = try persistence.install(location, expected: rebound)
    }

    private func prepareImport(
        root: URL,
        sourceBytes: Data? = nil,
        persistence: PortableAudioImportPersistence
    ) throws -> (location: AudioImportStagingLocation, session: ImportedSession) {
        var result: (AudioImportStagingLocation, ImportedSession)?
        let location = try persistence.begin(
            root: root,
            stagingID: AudioStagingID("staging_fixture")!,
            seed: importedSeed(),
            container: .wav
        )
        do {
            let source = root.deletingLastPathComponent().appendingPathComponent("source.wav")
            try (sourceBytes ?? syntheticSourceWAV()).write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            let original = try persistence.copySource(
                from: source,
                into: location,
                maximumBytes: 1_024
            )
            let descriptor = try persistence.createCanonicalDescriptor(in: location)
            let writer = try CanonicalWAVWriter(descriptor: descriptor, maximumFrameCount: 3)
            try writer.append([-0.5, 0, 0.5])
            let normalized = try writer.finish()
            try persistence.didFinishCanonicalWrite(in: location)
            let canonical = try persistence.fingerprint(
                components: location.stagedSessionComponents + ["audio", "audio.wav"],
                under: location,
                maximumBytes: normalized.byteCount
            )
            let provisional = try makeImportedSession(
                original: original,
                canonical: canonical,
                normalized: normalized
            )
            let rebound = try persistence.writeManifests(for: provisional, in: location)
            _ = try persistence.validateStaged(location, expected: rebound)
            result = (location, rebound)
        } catch {
            persistence.discard(location)
            location.close()
            throw error
        }
        return try XCTUnwrap(result)
    }

    private func makeImportedSession(
        original: AudioArtifactFingerprint,
        canonical: AudioArtifactFingerprint,
        normalized: CanonicalNormalizationResult
    ) throws -> ImportedSession {
        let audio = try ImportedAudioAsset(
            original: OriginalAudioArtifact(
                relativePath: LibraryRelativePath("audio/original.wav"),
                container: .wav,
                fingerprint: original,
                decodedCodec: .linearPCM,
                sourceSampleRateHz: 16_000,
                sourceChannelCount: 1
            ),
            canonical: CanonicalAudioArtifact(
                relativePath: LibraryRelativePath("audio/audio.wav"),
                fingerprint: canonical,
                frameCount: normalized.frameCount,
                durationMilliseconds: normalized.durationMilliseconds
            ),
            sources: [
                try SessionAudioSource(
                    audioSourceID: .microphone,
                    role: .microphone,
                    timelineOffsetMilliseconds: 0
                ),
            ],
            normalization: .v1
        )
        return try ImportedSession(
            sessionID: importedSeed().sessionID,
            createdAt: importedSeed().createdAt,
            durationMilliseconds: normalized.durationMilliseconds,
            audioManifestSHA256: String(repeating: "0", count: 64),
            audio: audio
        )
    }

    private func withFreshStaging(
        _ body: (
            URL,
            PortableAudioImportPersistence,
            AudioImportStagingLocation
        ) throws -> Void
    ) throws {
        try withTemporaryParent { parent in
            let root = parent.appendingPathComponent("Synthetic.audoralibrary")
            try createLibrary(at: root)
            let persistence = PortableAudioImportPersistence()
            let location = try persistence.begin(
                root: root,
                stagingID: AudioStagingID("staging_fresh")!,
                seed: importedSeed(),
                container: .wav
            )
            defer {
                persistence.discard(location)
                location.close()
            }
            try body(parent, persistence, location)
        }
    }

    private func createLibrary(at root: URL) throws {
        let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
        _ = try PortableLibraryPersistence().create(
            at: root,
            seed: NewLibrarySeed(
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
        )
    }

    private func importedSeed() throws -> ImportedSessionSeed {
        ImportedSessionSeed(
            scope: AudioImportScopeIdentity(
                libraryID: try LibraryID("lib-20260830T120000000Z-2ABC"),
                workspaceGeneration: 1
            ),
            sessionID: try SessionID("ses-20260830T120000000Z-3DEF"),
            createdAt: try UTCInstant("2026-08-30T12:00:00.000Z")
        )
    }

    private func syntheticSourceWAV() -> Data {
        Data("RIFF\u{4}\0\0\0WAVEsynthetic-source".utf8)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func withTemporaryParent(_ body: (URL) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-audio-persistence-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        try body(parent)
    }

    private func sessionTree(at root: URL) throws -> [String] {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalPrefix = canonicalRoot.path + "/"
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
        )
        var values: [String] = []
        for case let url as URL in enumerator {
            let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
            guard canonicalURL.path.hasPrefix(canonicalPrefix) else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let relative = String(canonicalURL.path.dropFirst(canonicalPrefix.count))
            let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            values.append(relative + (isDirectory ? "/" : ""))
        }
        return values.sorted()
    }
}
