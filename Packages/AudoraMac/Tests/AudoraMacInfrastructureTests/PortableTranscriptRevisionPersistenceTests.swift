@testable import AudoraMacInfrastructure
import AudoraApplication
import AudoraDomain
import CryptoKit
import Foundation
import XCTest

final class PortableTranscriptRevisionPersistenceTests: XCTestCase {
    func testPublishesAndReopensImportedSessionWithoutChangingOwnedAudio() async throws {
        try await withImportedSession { root, libraryID, imported in
            let originalURL = root.appendingPathComponent(
                "sessions/\(imported.sessionID.rawValue)/audio/original.wav"
            )
            let audioManifestURL = root.appendingPathComponent(
                "sessions/\(imported.sessionID.rawValue)/audio/audio.json"
            )
            let beforeOriginal = try Data(contentsOf: originalURL)
            let beforeAudioManifest = try Data(contentsOf: audioManifestURL)
            let beforeSession = try sessionJSONObject(
                root: root,
                sessionID: imported.sessionID
            )
            let revision = try transcriptRevision(for: imported)
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: libraryID
            )

            _ = try await repository.publishAndSelect(
                revision,
                expectedSelectedRevisionID: nil
            )
            let reopened = try await PortableTranscriptRevisionRepository(
                root: root,
                libraryID: libraryID
            ).reopenSelected(sessionID: imported.sessionID)

            XCTAssertEqual(reopened.selectedRevision, revision)
            XCTAssertEqual(try Data(contentsOf: originalURL), beforeOriginal)
            XCTAssertEqual(try Data(contentsOf: audioManifestURL), beforeAudioManifest)
            let afterSession = try sessionJSONObject(root: root, sessionID: imported.sessionID)
            for key in [
                "schemaVersion", "sessionId", "createdAt", "durationMs",
                "audioManifestSha256",
            ] {
                XCTAssertEqual(
                    String(describing: afterSession[key]),
                    String(describing: beforeSession[key]),
                    key
                )
            }
            guard case let .readWrite(reopenedImport) = try PortableAudioImportPersistence()
                .openSession(at: root, sessionID: imported.sessionID)
            else {
                return XCTFail("published imported Session did not reopen read-write")
            }
            XCTAssertEqual(reopenedImport.audio, imported.audio)
            XCTAssertEqual(reopenedImport.audioManifestSHA256, imported.audioManifestSHA256)
            XCTAssertEqual(reopenedImport.transcriptRevisionIDs, [revision.revisionID])
            XCTAssertEqual(
                reopenedImport.selectedTranscriptRevision?.revisionID,
                revision.revisionID
            )
        }
    }

    func testImportedSessionRejectsNullAndUnknownNestedSelectionShape() async throws {
        try await withImportedSession { root, libraryID, imported in
            let sessionURL = root.appendingPathComponent(
                "sessions/\(imported.sessionID.rawValue)/session.json"
            )
            let initial = try Data(contentsOf: sessionURL)
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: initial) as? [String: Any]
            )
            object["selectedTranscriptRevision"] = NSNull()
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                .write(to: sessionURL)
            XCTAssertThrowsError(
                try PortableAudioImportPersistence().openSession(
                    at: root,
                    sessionID: imported.sessionID
                )
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .candidateCorrupt)
            }

            try initial.write(to: sessionURL)
            let revision = try transcriptRevision(for: imported)
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: libraryID
            )
            _ = try await repository.publishAndSelect(
                revision,
                expectedSelectedRevisionID: nil
            )
            object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: sessionURL))
                    as? [String: Any]
            )
            var selected = try XCTUnwrap(
                object["selectedTranscriptRevision"] as? [String: Any]
            )
            selected["unknown"] = true
            object["selectedTranscriptRevision"] = selected
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                .write(to: sessionURL)

            XCTAssertThrowsError(
                try PortableAudioImportPersistence().openSession(
                    at: root,
                    sessionID: imported.sessionID
                )
            ) { error in
                XCTAssertEqual(error as? AudioImportFailure, .candidateCorrupt)
            }
            do {
                _ = try await repository.reopenSelected(sessionID: imported.sessionID)
                XCTFail("expected strict nested selection rejection")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .sessionIntegrityMismatch
                )
            }
        }
    }

    func testRecordedSessionNewerSchemaIsUnsupportedAndPreservedByteForByte() async throws {
        try await withRecordedSession { root, receipt in
            let sessionURL = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/session.json"
            )
            var object = try sessionJSONObject(root: root, sessionID: receipt.sessionID)
            object["schemaVersion"] = 2
            object["futureSessionField"] = ["preserve": true]
            let newerData = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            try newerData.write(to: sessionURL)
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            )

            do {
                _ = try await repository.reopenSelected(sessionID: receipt.sessionID)
                XCTFail("expected unsupported newer recorded Session")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .unsupportedSchema
                )
            }
            do {
                _ = try await repository.publishAndSelect(
                    transcriptRevision(for: receipt),
                    expectedSelectedRevisionID: nil
                )
                XCTFail("expected unsupported newer recorded Session to remain immutable")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .unsupportedSchema
                )
            }
            XCTAssertEqual(try Data(contentsOf: sessionURL), newerData)
        }
    }

    func testImportedSessionNewerSchemaIsUnsupportedAndPreservedByteForByte() async throws {
        try await withImportedSession { root, libraryID, imported in
            let sessionURL = root.appendingPathComponent(
                "sessions/\(imported.sessionID.rawValue)/session.json"
            )
            var object = try sessionJSONObject(root: root, sessionID: imported.sessionID)
            object["schemaVersion"] = 2
            object["futureSessionField"] = ["preserve": true]
            let newerData = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            try newerData.write(to: sessionURL)
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: libraryID
            )

            do {
                _ = try await repository.reopenSelected(sessionID: imported.sessionID)
                XCTFail("expected unsupported newer imported Session")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .unsupportedSchema
                )
            }
            do {
                _ = try await repository.publishAndSelect(
                    transcriptRevision(for: imported),
                    expectedSelectedRevisionID: nil
                )
                XCTFail("expected unsupported newer imported Session to remain immutable")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .unsupportedSchema
                )
            }
            XCTAssertEqual(try Data(contentsOf: sessionURL), newerData)
        }
    }

    func testMalformedVersionOneSessionRemainsAnIntegrityMismatch() async throws {
        try await withRecordedSession { root, receipt in
            let sessionURL = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/session.json"
            )
            var object = try sessionJSONObject(root: root, sessionID: receipt.sessionID)
            object["unexpectedVersionOneField"] = true
            let malformedData = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            try malformedData.write(to: sessionURL)

            do {
                _ = try await PortableTranscriptRevisionRepository(
                    root: root,
                    libraryID: receipt.libraryID
                ).reopenSelected(sessionID: receipt.sessionID)
                XCTFail("expected malformed version-one Session rejection")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .sessionIntegrityMismatch
                )
            }
            XCTAssertEqual(try Data(contentsOf: sessionURL), malformedData)
        }
    }

    func testPublishesAndReopensExactImmutableRevisionWithStableAnchors() async throws {
        try await withRecordedSession { root, receipt in
            let revision = try transcriptRevision(for: receipt)
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            )

            let published = try await repository.publishAndSelect(
                revision,
                expectedSelectedRevisionID: nil
            )
            let reopened = try await PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            ).reopenSelected(sessionID: receipt.sessionID)

            XCTAssertEqual(published, reopened)
            XCTAssertEqual(reopened.selectedRevision, revision)
            XCTAssertEqual(reopened.selectedRevision.lines[0].lineID.rawValue, "l000000")
            XCTAssertEqual(reopened.selectedRevision.lines[0].words[0].wordID.rawValue, "w000000")
            XCTAssertEqual(reopened.selectedRevision.audioEvents[0].audioEventID.rawValue, "a000000")
            XCTAssertEqual(reopened.selectedRevision.lines[0].text, "Hi.")
            XCTAssertEqual(reopened.selectedRevision.lines[0].words.map(\.text), ["Hi"])

            let revisionRoot = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/transcripts/\(revision.revisionID.rawValue)"
            )
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: revisionRoot.appendingPathComponent("revision.json").path
            ))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: revisionRoot.appendingPathComponent("revision.sha256").path
            ))
        }
    }

    func testReopensAndBytePreservesLegacyVersionOneRevisionWithoutQualification() async throws {
        try await withRecordedSession { root, receipt in
            let revision = try transcriptRevision(for: receipt)
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            )
            _ = try await repository.publishAndSelect(
                revision,
                expectedSelectedRevisionID: nil
            )
            let revisionRoot = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/transcripts/\(revision.revisionID.rawValue)"
            )
            let revisionURL = revisionRoot.appendingPathComponent("revision.json")
            let hashURL = revisionRoot.appendingPathComponent("revision.sha256")
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: revisionURL))
                    as? [String: Any]
            )
            object["schemaVersion"] = 1
            var engine = try XCTUnwrap(object["engine"] as? [String: Any])
            engine.removeValue(forKey: "qualification")
            object["engine"] = engine
            let legacyBytes = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            let legacyDigest = SHA256.hash(data: legacyBytes).hexLowercase
            try legacyBytes.write(to: revisionURL)
            try Data(legacyDigest.utf8).write(to: hashURL)
            let sessionURL = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/session.json"
            )
            var session = try sessionJSONObject(root: root, sessionID: receipt.sessionID)
            session["selectedTranscriptRevision"] = [
                "revisionId": revision.revisionID.rawValue,
                "revisionSha256": legacyDigest,
            ]
            try JSONSerialization.data(withJSONObject: session, options: [.sortedKeys])
                .write(to: sessionURL)

            let reopened = try await repository.reopenSelected(
                sessionID: receipt.sessionID
            )

            XCTAssertNil(reopened.selectedRevision.engine.qualification)
            XCTAssertEqual(reopened.selectedRevision.revisionID, revision.revisionID)
            XCTAssertEqual(try Data(contentsOf: revisionURL), legacyBytes)
            XCTAssertEqual(try Data(contentsOf: hashURL), Data(legacyDigest.utf8))
        }
    }

    func testInstalledUnselectedRevisionIsIdempotentlyReusedOnRetry() async throws {
        try await withRecordedSession { root, receipt in
            let revision = try transcriptRevision(for: receipt)
            let failing = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            ) { point in
                if point == .afterRevisionDirectoryInstall {
                    throw TranscriptRevisionPersistenceTestFault.injected
                }
            }

            do {
                _ = try await failing.publishAndSelect(
                    revision,
                    expectedSelectedRevisionID: nil
                )
                XCTFail("expected injected precommit failure")
            } catch {
                XCTAssertEqual(error as? TranscriptRevisionRepositoryFailure, .writeFailed)
            }
            let beforeRetry = try sessionJSONObject(root: root, sessionID: receipt.sessionID)
            XCTAssertEqual(beforeRetry["transcriptRevisionIds"] as? [String], [])
            XCTAssertNil(beforeRetry["selectedTranscriptRevision"])

            let reopened = try await PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            ).publishAndSelect(revision, expectedSelectedRevisionID: nil)

            XCTAssertEqual(reopened.selectedRevision, revision)
            let transcriptNames = try FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent(
                    "sessions/\(receipt.sessionID.rawValue)/transcripts"
                ).path
            ).filter { !$0.hasPrefix(".") }
            XCTAssertEqual(transcriptNames, [revision.revisionID.rawValue])
        }
    }

    func testPostcommitFailureKeepsNewSelectionAndReopensIt() async throws {
        try await withRecordedSession { root, receipt in
            let revision = try transcriptRevision(for: receipt)
            let failing = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            ) { point in
                if point == .afterSessionManifestInstall {
                    throw TranscriptRevisionPersistenceTestFault.injected
                }
            }

            do {
                _ = try await failing.publishAndSelect(
                    revision,
                    expectedSelectedRevisionID: nil
                )
                XCTFail("expected injected postcommit failure")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .installedNeedsRefresh
                )
            }

            let reopened = try await PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            ).reopenSelected(sessionID: receipt.sessionID)
            XCTAssertEqual(reopened.selectedRevision, revision)
        }
    }

    func testEveryTypedFailureAfterSelectionInstallRequiresRefresh() async throws {
        for injectedFailure in [
            TranscriptRevisionRepositoryFailure.staleSelection,
            .revisionCollision,
            .unsupportedSchema,
        ] {
            try await withRecordedSession { root, receipt in
                let revision = try transcriptRevision(for: receipt)
                let failing = PortableTranscriptRevisionRepository(
                    root: root,
                    libraryID: receipt.libraryID
                ) { point in
                    if point == .afterSessionManifestInstall {
                        throw injectedFailure
                    }
                }

                do {
                    _ = try await failing.publishAndSelect(
                        revision,
                        expectedSelectedRevisionID: nil
                    )
                    XCTFail("expected injected postcommit failure")
                } catch {
                    XCTAssertEqual(
                        error as? TranscriptRevisionRepositoryFailure,
                        .installedNeedsRefresh
                    )
                }

                let reopened = try await PortableTranscriptRevisionRepository(
                    root: root,
                    libraryID: receipt.libraryID
                ).reopenSelected(sessionID: receipt.sessionID)
                XCTAssertEqual(reopened.selectedRevision, revision)
            }
        }
    }

    func testSameRevisionIdentityCanNeverOverwriteDifferentImmutableBytes() async throws {
        try await withRecordedSession { root, receipt in
            let revision = try transcriptRevision(for: receipt)
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            )
            _ = try await repository.publishAndSelect(
                revision,
                expectedSelectedRevisionID: nil
            )
            let collision = try transcriptRevision(for: receipt, word: "No", lineText: "No.")

            do {
                _ = try await repository.publishAndSelect(
                    collision,
                    expectedSelectedRevisionID: revision.revisionID
                )
                XCTFail("expected immutable identity collision")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .revisionCollision
                )
            }
            let reopened = try await repository.reopenSelected(sessionID: receipt.sessionID)
            XCTAssertEqual(reopened.selectedRevision, revision)
        }
    }

    func testStaleExpectedSelectionCannotInstallOrRewriteACompetingRevision() async throws {
        try await withRecordedSession { root, receipt in
            let selected = try transcriptRevision(for: receipt)
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            )
            _ = try await repository.publishAndSelect(
                selected,
                expectedSelectedRevisionID: nil
            )
            let sessionURL = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/session.json"
            )
            let before = try Data(contentsOf: sessionURL)
            let loser = try transcriptRevision(
                for: receipt,
                revisionID: "trv-20260830T121100000Z-6HJK"
            )

            do {
                _ = try await repository.publishAndSelect(
                    loser,
                    expectedSelectedRevisionID: nil
                )
                XCTFail("expected stale compare-and-swap")
            } catch {
                XCTAssertEqual(error as? TranscriptRevisionRepositoryFailure, .staleSelection)
            }

            XCTAssertEqual(try Data(contentsOf: sessionURL), before)
            let transcriptNames = try FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent(
                    "sessions/\(receipt.sessionID.rawValue)/transcripts"
                ).path
            ).filter { !$0.hasPrefix(".") }
            XCTAssertEqual(transcriptNames, [selected.revisionID.rawValue])
            let reopened = try await repository.reopenSelected(
                sessionID: receipt.sessionID
            )
            XCTAssertEqual(reopened.selectedRevision, selected)
        }
    }

    func testInventoriedRevisionIDCannotBeReincarnatedAfterItsBundleIsDeleted() async throws {
        try await withRecordedSession { root, receipt in
            let revisionA = try transcriptRevision(for: receipt)
            let revisionB = try transcriptRevision(
                for: receipt,
                revisionID: "trv-20260830T121100000Z-6HJK"
            )
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            )
            _ = try await repository.publishAndSelect(
                revisionA,
                expectedSelectedRevisionID: nil
            )
            _ = try await repository.publishAndSelect(
                revisionB,
                expectedSelectedRevisionID: revisionA.revisionID
            )

            let sessionURL = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/session.json"
            )
            let before = try Data(contentsOf: sessionURL)
            let revisionARoot = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/transcripts/\(revisionA.revisionID.rawValue)"
            )
            try FileManager.default.removeItem(at: revisionARoot)
            let reincarnation = try transcriptRevision(
                for: receipt,
                revisionID: revisionA.revisionID.rawValue,
                word: "No",
                lineText: "No."
            )

            do {
                _ = try await repository.publishAndSelect(
                    reincarnation,
                    expectedSelectedRevisionID: revisionB.revisionID
                )
                XCTFail("expected immutable inventoried identity collision")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .revisionCollision
                )
            }

            XCTAssertEqual(try Data(contentsOf: sessionURL), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: revisionARoot.path))
            let selected = try sessionJSONObject(root: root, sessionID: receipt.sessionID)
            XCTAssertEqual(
                (selected["selectedTranscriptRevision"] as? [String: Any])?["revisionId"]
                    as? String,
                revisionB.revisionID.rawValue
            )
        }
    }

    func testFullRevisionInventoryRejectsPublicationBeforeCreatingTranscriptState() async throws {
        try await withRecordedSession { root, receipt in
            let existingIDs = try (0..<TranscriptRevisionLimits.maximumSessionRevisionCount)
                .map { index in
                    try TranscriptRevisionID(
                        "trv-20260829T121000000Z-\(String(format: "%04d", index))"
                    )
                }
            let selectedID = try XCTUnwrap(existingIDs.first)
            let sessionURL = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/session.json"
            )
            var session = try sessionJSONObject(root: root, sessionID: receipt.sessionID)
            session["transcriptRevisionIds"] = existingIDs.map(\.rawValue)
            session["selectedTranscriptRevision"] = [
                "revisionId": selectedID.rawValue,
                "revisionSha256": String(repeating: "0", count: 64),
            ]
            let fullInventory = try JSONSerialization.data(
                withJSONObject: session,
                options: [.sortedKeys]
            )
            try fullInventory.write(to: sessionURL)

            let revision = try transcriptRevision(for: receipt)
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            )
            do {
                _ = try await repository.publishAndSelect(
                    revision,
                    expectedSelectedRevisionID: selectedID
                )
                XCTFail("expected the bounded revision inventory to reject growth")
            } catch {
                XCTAssertEqual(error as? TranscriptRevisionRepositoryFailure, .writeFailed)
            }

            XCTAssertEqual(try Data(contentsOf: sessionURL), fullInventory)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "sessions/\(receipt.sessionID.rawValue)/transcripts"
                ).path
            ))
        }
    }

    func testRootPathReplacementBeforeCommitCannotRedirectOrCommitPublication() async throws {
        try await withRecordedSession { root, receipt in
            let parent = root.deletingLastPathComponent()
            let displaced = parent.appendingPathComponent("Displaced.audoralibrary")
            let replacement = parent.appendingPathComponent("Replacement.audoralibrary")
            try createEmptyLibrary(at: replacement, libraryID: receipt.libraryID)
            let originalSession = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/session.json"
            )
            let before = try Data(contentsOf: originalSession)
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            ) { point in
                guard point == .afterSessionManifestPartialFlush else { return }
                try FileManager.default.moveItem(at: root, to: displaced)
                try FileManager.default.createSymbolicLink(at: root, withDestinationURL: replacement)
            }

            do {
                _ = try await repository.publishAndSelect(
                    transcriptRevision(for: receipt),
                    expectedSelectedRevisionID: nil
                )
                XCTFail("expected replaced root rejection")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .sessionIntegrityMismatch
                )
            }

            XCTAssertEqual(
                try Data(contentsOf: displaced.appendingPathComponent(
                    "sessions/\(receipt.sessionID.rawValue)/session.json"
                )),
                before
            )
            do {
                _ = try await PortableTranscriptRevisionRepository(
                    root: root,
                    libraryID: receipt.libraryID
                ).reopenSelected(sessionID: receipt.sessionID)
                XCTFail("expected symlinked root rejection")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .sessionUnavailable
                )
            }
        }
    }

    func testRootParentReplacementBeforeCommitCannotPublishIntoDisplacedLibrary() async throws {
        try await withRecordedSession { root, receipt in
            let parent = root.deletingLastPathComponent()
            let container = parent.deletingLastPathComponent()
            let displacedParent = container.appendingPathComponent(
                parent.lastPathComponent + "-displaced"
            )
            let replacementParent = container.appendingPathComponent(
                parent.lastPathComponent + "-replacement"
            )
            try FileManager.default.createDirectory(
                at: replacementParent,
                withIntermediateDirectories: false
            )
            let replacementRoot = replacementParent.appendingPathComponent(root.lastPathComponent)
            try createEmptyLibrary(at: replacementRoot, libraryID: receipt.libraryID)
            defer {
                try? FileManager.default.removeItem(at: parent)
                try? FileManager.default.removeItem(at: displacedParent)
                try? FileManager.default.removeItem(at: replacementParent)
            }
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            ) { point in
                guard point == .afterSessionManifestPartialFlush else { return }
                try FileManager.default.moveItem(at: parent, to: displacedParent)
                try FileManager.default.createSymbolicLink(
                    at: parent,
                    withDestinationURL: replacementParent
                )
            }

            do {
                _ = try await repository.publishAndSelect(
                    transcriptRevision(for: receipt),
                    expectedSelectedRevisionID: nil
                )
                XCTFail("expected replaced root parent rejection")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .sessionIntegrityMismatch
                )
            }
            XCTAssertEqual(
                try sessionJSONObject(
                    root: displacedParent.appendingPathComponent(root.lastPathComponent),
                    sessionID: receipt.sessionID
                )["transcriptRevisionIds"] as? [String],
                []
            )
        }
    }

    func testWholeSessionsDirectoryReplacementBeforeCommitIsRejected() async throws {
        try await withRecordedSession { root, receipt in
            let sessions = root.appendingPathComponent("sessions")
            let replacement = root.appendingPathComponent("sessions-replacement")
            let displaced = root.appendingPathComponent("sessions-displaced")
            try FileManager.default.copyItem(at: sessions, to: replacement)
            let originalSession = sessions.appendingPathComponent(
                "\(receipt.sessionID.rawValue)/session.json"
            )
            let before = try Data(contentsOf: originalSession)
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            ) { point in
                guard point == .afterSessionManifestPartialFlush else { return }
                try FileManager.default.moveItem(at: sessions, to: displaced)
                try FileManager.default.moveItem(at: replacement, to: sessions)
            }

            do {
                _ = try await repository.publishAndSelect(
                    transcriptRevision(for: receipt),
                    expectedSelectedRevisionID: nil
                )
                XCTFail("expected replaced sessions directory rejection")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .sessionIntegrityMismatch
                )
            }
            XCTAssertEqual(
                try Data(contentsOf: displaced.appendingPathComponent(
                    "\(receipt.sessionID.rawValue)/session.json"
                )),
                before
            )
            XCTAssertEqual(
                try Data(contentsOf: sessions.appendingPathComponent(
                    "\(receipt.sessionID.rawValue)/session.json"
                )),
                before
            )
        }
    }

    func testSessionDirectoryReplacementBeforeCommitIsRejected() async throws {
        try await withRecordedSession { root, receipt in
            let sessions = root.appendingPathComponent("sessions")
            let name = receipt.sessionID.rawValue
            let session = sessions.appendingPathComponent(name)
            let replacement = sessions.appendingPathComponent("\(name)-replacement")
            let displaced = sessions.appendingPathComponent("\(name)-displaced")
            try FileManager.default.copyItem(at: session, to: replacement)
            let before = try Data(contentsOf: session.appendingPathComponent("session.json"))
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            ) { point in
                guard point == .afterSessionManifestPartialFlush else { return }
                try FileManager.default.moveItem(at: session, to: displaced)
                try FileManager.default.moveItem(at: replacement, to: session)
            }

            do {
                _ = try await repository.publishAndSelect(
                    transcriptRevision(for: receipt),
                    expectedSelectedRevisionID: nil
                )
                XCTFail("expected replaced Session rejection")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .sessionIntegrityMismatch
                )
            }
            XCTAssertEqual(
                try Data(contentsOf: displaced.appendingPathComponent("session.json")),
                before
            )
            XCTAssertEqual(
                try Data(contentsOf: session.appendingPathComponent("session.json")),
                before
            )
        }
    }

    func testCompetingSelectionWrittenBeforeCommitWinsCompareAndSwap() async throws {
        try await withRecordedSession { root, receipt in
            let sessionURL = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/session.json"
            )
            let competitorID = try TranscriptRevisionID(
                "trv-20260830T120900000Z-2CDE"
            )
            let competitorSHA = String(repeating: "f", count: 64)
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            ) { point in
                guard point == .afterSessionManifestPartialFlush else { return }
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: sessionURL))
                        as? [String: Any]
                )
                object["transcriptRevisionIds"] = [competitorID.rawValue]
                object["selectedTranscriptRevision"] = [
                    "revisionId": competitorID.rawValue,
                    "revisionSha256": competitorSHA,
                ]
                try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                    .write(to: sessionURL)
            }

            do {
                _ = try await repository.publishAndSelect(
                    transcriptRevision(for: receipt),
                    expectedSelectedRevisionID: nil
                )
                XCTFail("expected competing selection to win")
            } catch {
                XCTAssertEqual(error as? TranscriptRevisionRepositoryFailure, .staleSelection)
            }
            let current = try sessionJSONObject(root: root, sessionID: receipt.sessionID)
            XCTAssertEqual(current["transcriptRevisionIds"] as? [String], [competitorID.rawValue])
            XCTAssertEqual(
                (current["selectedTranscriptRevision"] as? [String: Any])?["revisionId"]
                    as? String,
                competitorID.rawValue
            )
        }
    }

    func testNonselectionSessionManifestMutationBeforeCommitIsNotOverwritten() async throws {
        try await withRecordedSession { root, receipt in
            let sessionURL = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/session.json"
            )
            let changedInstant = "2026-08-30T12:00:01.000Z"
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            ) { point in
                guard point == .afterSessionManifestPartialFlush else { return }
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: sessionURL))
                        as? [String: Any]
                )
                object["createdAt"] = changedInstant
                try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                    .write(to: sessionURL)
            }

            do {
                _ = try await repository.publishAndSelect(
                    transcriptRevision(for: receipt),
                    expectedSelectedRevisionID: nil
                )
                XCTFail("expected changed Session authority rejection")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .sessionIntegrityMismatch
                )
            }
            XCTAssertEqual(
                try sessionJSONObject(root: root, sessionID: receipt.sessionID)["createdAt"]
                    as? String,
                changedInstant
            )
        }
    }

    func testInstalledRevisionDirectoryReplacementBeforeSelectionIsRejected() async throws {
        try await assertInstalledRevisionReplacementIsRejected { revisionRoot in
            let displaced = revisionRoot.deletingLastPathComponent()
                .appendingPathComponent("displaced-revision")
            try FileManager.default.moveItem(at: revisionRoot, to: displaced)
            try FileManager.default.copyItem(at: displaced, to: revisionRoot)
        }
    }

    func testInstalledRevisionJSONReplacementBeforeSelectionIsRejected() async throws {
        try await assertInstalledRevisionReplacementIsRejected { revisionRoot in
            let revision = revisionRoot.appendingPathComponent("revision.json")
            try Data(contentsOf: revision).write(to: revision, options: .atomic)
        }
    }

    func testInstalledRevisionHashReplacementBeforeSelectionIsRejected() async throws {
        try await assertInstalledRevisionReplacementIsRejected { revisionRoot in
            let hash = revisionRoot.appendingPathComponent("revision.sha256")
            try Data(contentsOf: hash).write(to: hash, options: .atomic)
        }
    }

    func testRecordedAudioAuthorityRejectsFrameIntervalAndWAVTampering() async throws {
        for mutation in 0..<3 {
            try await withRecordedSession { root, receipt in
                let audioRoot = root.appendingPathComponent(
                    "sessions/\(receipt.sessionID.rawValue)/audio"
                )
                if mutation == 0 {
                    let manifest = audioRoot.appendingPathComponent("audio.json")
                    var object = try XCTUnwrap(
                        JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
                            as? [String: Any]
                    )
                    object["frameCount"] = 15
                    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                        .write(to: manifest)
                } else if mutation == 1 {
                    let manifest = audioRoot.appendingPathComponent("audio.json")
                    var object = try XCTUnwrap(
                        JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
                            as? [String: Any]
                    )
                    object["unavailableIntervals"] = [[
                        "startFrame": 0,
                        "endFrame": 5,
                        "reasons": ["muted"],
                    ]]
                    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                        .write(to: manifest)
                } else {
                    let wav = audioRoot.appendingPathComponent("audio.wav")
                    var bytes = try Data(contentsOf: wav)
                    bytes[0] ^= 0xff
                    try bytes.write(to: wav)
                }
                let repository = PortableTranscriptRevisionRepository(
                    root: root,
                    libraryID: receipt.libraryID
                )

                do {
                    _ = try await repository.publishAndSelect(
                        transcriptRevision(for: receipt),
                        expectedSelectedRevisionID: nil
                    )
                    XCTFail("expected recorded audio authority rejection")
                } catch {
                    XCTAssertEqual(
                        error as? TranscriptRevisionRepositoryFailure,
                        .sessionIntegrityMismatch,
                        "mutation \(mutation)"
                    )
                }
                let session = try sessionJSONObject(root: root, sessionID: receipt.sessionID)
                XCTAssertEqual(session["transcriptRevisionIds"] as? [String], [])
            }
        }
    }

    func testSessionManifestPartialSubstitutionCannotChangeCommitBytes() async throws {
        try await withRecordedSession { root, receipt in
            let sessionRoot = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)"
            )
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            ) { point in
                guard point == .afterSessionManifestPartialFlush else { return }
                let name = try XCTUnwrap(
                    FileManager.default.contentsOfDirectory(atPath: sessionRoot.path)
                        .first { $0.hasPrefix(".session-") && $0.hasSuffix(".partial") }
                )
                let partial = sessionRoot.appendingPathComponent(name)
                try Data(contentsOf: partial).write(to: partial, options: .atomic)
            }

            do {
                _ = try await repository.publishAndSelect(
                    transcriptRevision(for: receipt),
                    expectedSelectedRevisionID: nil
                )
                XCTFail("expected substituted Session partial rejection")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .sessionIntegrityMismatch
                )
            }
            XCTAssertEqual(
                try sessionJSONObject(root: root, sessionID: receipt.sessionID)[
                    "transcriptRevisionIds"
                ] as? [String],
                []
            )
        }
    }

    func testRevisionBundlePartialSubstitutionCannotInstallAlternateDirectory() async throws {
        try await withRecordedSession { root, receipt in
            let transcripts = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/transcripts"
            )
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            ) { point in
                guard point == .afterRevisionFilesFlush else { return }
                let name = try XCTUnwrap(
                    FileManager.default.contentsOfDirectory(atPath: transcripts.path)
                        .first { $0.hasPrefix(".trv-") && $0.hasSuffix(".partial") }
                )
                let partial = transcripts.appendingPathComponent(name)
                let displaced = transcripts.appendingPathComponent("displaced-partial")
                try FileManager.default.moveItem(at: partial, to: displaced)
                try FileManager.default.copyItem(at: displaced, to: partial)
            }

            do {
                _ = try await repository.publishAndSelect(
                    transcriptRevision(for: receipt),
                    expectedSelectedRevisionID: nil
                )
                XCTFail("expected substituted Revision partial rejection")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .sessionIntegrityMismatch
                )
            }
            let visible = try FileManager.default.contentsOfDirectory(atPath: transcripts.path)
                .filter { !$0.hasPrefix(".") && $0 != "displaced-partial" }
            XCTAssertEqual(visible, [])
        }
    }

    func testTranscriptsDirectoryIsFlushedBeforeAnyRevisionOrSelectionMutation() async throws {
        try await withRecordedSession { root, receipt in
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            ) { point in
                if point == .afterTranscriptsDirectoryFlush {
                    throw TranscriptRevisionPersistenceTestFault.injected
                }
            }
            do {
                _ = try await repository.publishAndSelect(
                    transcriptRevision(for: receipt),
                    expectedSelectedRevisionID: nil
                )
                XCTFail("expected post-directory-flush fault")
            } catch {
                XCTAssertEqual(error as? TranscriptRevisionRepositoryFailure, .writeFailed)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/transcripts"
            ).path))
            XCTAssertEqual(
                try sessionJSONObject(root: root, sessionID: receipt.sessionID)[
                    "transcriptRevisionIds"
                ] as? [String],
                []
            )
        }
    }

    func testSelectedNewerRevisionSchemaIsUnsupportedAndPreservedByteForByte() async throws {
        try await withRecordedSession { root, receipt in
            let revision = try transcriptRevision(for: receipt)
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            )
            _ = try await repository.publishAndSelect(
                revision,
                expectedSelectedRevisionID: nil
            )

            let revisionRoot = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/transcripts/\(revision.revisionID.rawValue)"
            )
            let revisionURL = revisionRoot.appendingPathComponent("revision.json")
            let hashURL = revisionRoot.appendingPathComponent("revision.sha256")
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: revisionURL))
                    as? [String: Any]
            )
            object["schemaVersion"] = 3
            object["newerField"] = ["preserve": true]
            let newerData = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            let newerDigest = SHA256.hash(data: newerData).hexLowercase
            let newerHashData = Data(newerDigest.utf8)
            try newerData.write(to: revisionURL)
            try newerHashData.write(to: hashURL)

            let sessionURL = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/session.json"
            )
            var session = try sessionJSONObject(root: root, sessionID: receipt.sessionID)
            session["selectedTranscriptRevision"] = [
                "revisionId": revision.revisionID.rawValue,
                "revisionSha256": newerDigest,
            ]
            let selectedSessionData = try JSONSerialization.data(
                withJSONObject: session,
                options: [.sortedKeys]
            )
            try selectedSessionData.write(to: sessionURL)

            do {
                _ = try await repository.reopenSelected(sessionID: receipt.sessionID)
                XCTFail("expected unsupported newer Transcript Revision")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .unsupportedSchema
                )
            }
            XCTAssertEqual(try Data(contentsOf: revisionURL), newerData)
            XCTAssertEqual(try Data(contentsOf: hashURL), newerHashData)
            XCTAssertEqual(try Data(contentsOf: sessionURL), selectedSessionData)
        }
    }

    func testReopenRunsDomainIntegrityValidationEvenWhenHashesAreSelfConsistent() async throws {
        try await withRecordedSession { root, receipt in
            let revision = try transcriptRevision(for: receipt)
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            )
            _ = try await repository.publishAndSelect(
                revision,
                expectedSelectedRevisionID: nil
            )

            let revisionRoot = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/transcripts/\(revision.revisionID.rawValue)"
            )
            let revisionURL = revisionRoot.appendingPathComponent("revision.json")
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: revisionURL))
                    as? [String: Any]
            )
            var lines = try XCTUnwrap(object["lines"] as? [[String: Any]])
            var words = try XCTUnwrap(lines[0]["words"] as? [[String: Any]])
            var displayRange = try XCTUnwrap(words[0]["displayRange"] as? [String: Any])
            displayRange["endUtf8Byte"] = 1
            words[0]["displayRange"] = displayRange
            lines[0]["words"] = words
            object["lines"] = lines
            let malformed = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            let digest = SHA256.hash(data: malformed).hexLowercase
            try malformed.write(to: revisionURL)
            try Data(digest.utf8).write(
                to: revisionRoot.appendingPathComponent("revision.sha256")
            )

            let sessionURL = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/session.json"
            )
            var session = try sessionJSONObject(root: root, sessionID: receipt.sessionID)
            session["selectedTranscriptRevision"] = [
                "revisionId": revision.revisionID.rawValue,
                "revisionSha256": digest,
            ]
            try JSONSerialization.data(withJSONObject: session, options: [.sortedKeys])
                .write(to: sessionURL)

            do {
                _ = try await PortableTranscriptRevisionRepository(
                    root: root,
                    libraryID: receipt.libraryID
                ).reopenSelected(sessionID: receipt.sessionID)
                XCTFail("expected structurally invalid Revision rejection")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .sessionIntegrityMismatch
                )
            }
        }
    }

    func testReopenRejectsNullConfidenceEvenWhenHashesAreSelfConsistent() async throws {
        try await withRecordedSession { root, receipt in
            let revision = try transcriptRevision(for: receipt)
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            )
            _ = try await repository.publishAndSelect(
                revision,
                expectedSelectedRevisionID: nil
            )

            let revisionRoot = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/transcripts/\(revision.revisionID.rawValue)"
            )
            let revisionURL = revisionRoot.appendingPathComponent("revision.json")
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: revisionURL))
                    as? [String: Any]
            )
            var lines = try XCTUnwrap(object["lines"] as? [[String: Any]])
            var words = try XCTUnwrap(lines[0]["words"] as? [[String: Any]])
            words[0]["confidence"] = NSNull()
            lines[0]["words"] = words
            object["lines"] = lines
            let malformed = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            let digest = SHA256.hash(data: malformed).hexLowercase
            try malformed.write(to: revisionURL)
            try Data(digest.utf8).write(
                to: revisionRoot.appendingPathComponent("revision.sha256")
            )

            let sessionURL = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/session.json"
            )
            var session = try sessionJSONObject(root: root, sessionID: receipt.sessionID)
            session["selectedTranscriptRevision"] = [
                "revisionId": revision.revisionID.rawValue,
                "revisionSha256": digest,
            ]
            try JSONSerialization.data(withJSONObject: session, options: [.sortedKeys])
                .write(to: sessionURL)

            do {
                _ = try await PortableTranscriptRevisionRepository(
                    root: root,
                    libraryID: receipt.libraryID
                ).reopenSelected(sessionID: receipt.sessionID)
                XCTFail("expected explicit-null confidence rejection")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .sessionIntegrityMismatch
                )
            }
        }
    }

    func testReopenRejectsPathologicalRepetitionEvenWhenHashesAreSelfConsistent() async throws {
        try await withRecordedSession { root, receipt in
            let revision = try transcriptRevision(for: receipt)
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            )
            _ = try await repository.publishAndSelect(
                revision,
                expectedSelectedRevisionID: nil
            )

            let revisionRoot = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/transcripts/\(revision.revisionID.rawValue)"
            )
            let revisionURL = revisionRoot.appendingPathComponent("revision.json")
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: revisionURL))
                    as? [String: Any]
            )
            var lines = try XCTUnwrap(object["lines"] as? [[String: Any]])
            let tokens = Array(repeating: "go", count: 9)
            var cursor = 0
            lines[0]["text"] = tokens.joined(separator: " ")
            lines[0]["words"] = tokens.enumerated().map { index, token in
                let start = cursor
                cursor += token.utf8.count + 1
                return [
                    "displayRange": [
                        "endUtf8Byte": start + token.utf8.count,
                        "startUtf8Byte": start,
                    ],
                    "ordinal": index,
                    "text": token,
                    "wordId": String(format: "w%06d", index),
                    "wordKind": "lexical",
                ] as [String: Any]
            }
            object["lines"] = lines
            let malformed = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            let digest = SHA256.hash(data: malformed).hexLowercase
            try malformed.write(to: revisionURL)
            try Data(digest.utf8).write(
                to: revisionRoot.appendingPathComponent("revision.sha256")
            )

            let sessionURL = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/session.json"
            )
            var session = try sessionJSONObject(root: root, sessionID: receipt.sessionID)
            session["selectedTranscriptRevision"] = [
                "revisionId": revision.revisionID.rawValue,
                "revisionSha256": digest,
            ]
            try JSONSerialization.data(withJSONObject: session, options: [.sortedKeys])
                .write(to: sessionURL)

            do {
                _ = try await PortableTranscriptRevisionRepository(
                    root: root,
                    libraryID: receipt.libraryID
                ).reopenSelected(sessionID: receipt.sessionID)
                XCTFail("expected pathological repetition rejection")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .sessionIntegrityMismatch
                )
            }
        }
    }

    private func assertInstalledRevisionReplacementIsRejected(
        _ replacement: @escaping @Sendable (URL) throws -> Void
    ) async throws {
        try await withRecordedSession { root, receipt in
            let revision = try transcriptRevision(for: receipt)
            let revisionRoot = root.appendingPathComponent(
                "sessions/\(receipt.sessionID.rawValue)/transcripts/" +
                    revision.revisionID.rawValue
            )
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: receipt.libraryID
            ) { point in
                guard point == .afterSessionManifestPartialFlush else { return }
                try replacement(revisionRoot)
            }

            do {
                _ = try await repository.publishAndSelect(
                    revision,
                    expectedSelectedRevisionID: nil
                )
                XCTFail("expected installed Revision authority rejection")
            } catch {
                XCTAssertEqual(
                    error as? TranscriptRevisionRepositoryFailure,
                    .sessionIntegrityMismatch
                )
            }
            let session = try sessionJSONObject(root: root, sessionID: receipt.sessionID)
            XCTAssertEqual(session["transcriptRevisionIds"] as? [String], [])
            XCTAssertNil(session["selectedTranscriptRevision"])
        }
    }
}

private enum TranscriptRevisionPersistenceTestFault: Error {
    case injected
}

private func withRecordedSession(
    _ body: (URL, SessionSealedReceipt) async throws -> Void
) async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
        "audora-transcript-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("Synthetic.audoralibrary", isDirectory: true)
    let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
    let libraryID = try LibraryID("lib-20260830T120000000Z-1ABC")
    _ = try PortableLibraryPersistence().create(
        at: root,
        seed: NewLibrarySeed(
            libraryID: libraryID,
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
    let request = MicrophoneRecordingRequest(
        libraryScope: LibraryScope(libraryID: libraryID),
        recordingID: try RecordingID("rec-20260830T120000000Z-2ABC"),
        sessionID: try SessionID("ses-20260830T120000000Z-3DEF"),
        startedAt: instant
    )
    let persistence = RecordingPersistence()
    let handle = try persistence.prepare(request, under: root)
    try persistence.append(
        CanonicalPCMSpan(
            frameCount: 4,
            pcmLittleEndian: Data(repeating: 1, count: 8),
            reasons: [],
            level: 0.2
        ),
        to: handle
    )
    let candidate = try persistence.stageSeal(handle, reason: .userStop)
    let publication = try RecordingSealCandidateValidator.validate(candidate, expected: request)
    let receipt = try persistence.install(publication, using: handle)
    try await body(root, receipt)
}

private func withImportedSession(
    _ body: (URL, LibraryID, ImportedSession) async throws -> Void
) async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
        "audora-transcript-import-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("Synthetic.audoralibrary", isDirectory: true)
    let libraryID = try LibraryID("lib-20260830T120000000Z-2ABC")
    try createEmptyLibrary(at: root, libraryID: libraryID)
    let seed = ImportedSessionSeed(
        scope: AudioImportScopeIdentity(libraryID: libraryID, workspaceGeneration: 1),
        sessionID: try SessionID("ses-20260830T120000000Z-3DEF"),
        createdAt: try UTCInstant("2026-08-30T12:00:00.000Z")
    )
    let persistence = PortableAudioImportPersistence()
    let location = try persistence.begin(
        root: root,
        stagingID: AudioStagingID("staging_transcript_revision")!,
        seed: seed,
        container: .wav
    )
    defer { location.close() }
    let source = parent.appendingPathComponent("source.wav")
    try Data("RIFF\u{4}\0\0\0WAVEsynthetic-transcript-source".utf8).write(to: source)
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
    let provisional = try ImportedSession(
        sessionID: seed.sessionID,
        createdAt: seed.createdAt,
        durationMilliseconds: normalized.durationMilliseconds,
        audioManifestSHA256: String(repeating: "0", count: 64),
        audio: audio
    )
    let rebound = try persistence.writeManifests(for: provisional, in: location)
    _ = try persistence.validateStaged(location, expected: rebound)
    let installed = try persistence.install(location, expected: rebound)
    try await body(root, libraryID, installed.session)
}

private func transcriptRevision(
    for receipt: SessionSealedReceipt,
    revisionID: String = "trv-20260830T121000000Z-4FGH",
    word: String = "Hi",
    lineText: String = "Hi."
) throws -> TranscriptRevision {
    try transcriptRevision(
        sessionID: receipt.sessionID,
        durationMilliseconds: 1,
        audioFingerprint: receipt.fingerprint,
        revisionID: revisionID,
        word: word,
        lineText: lineText
    )
}

private func transcriptRevision(
    for session: ImportedSession,
    revisionID: String = "trv-20260830T121000000Z-4FGH"
) throws -> TranscriptRevision {
    try transcriptRevision(
        sessionID: session.sessionID,
        durationMilliseconds: session.durationMilliseconds,
        audioFingerprint: AudioFingerprint(
            sha256: session.audio.canonical.fingerprint.sha256
        ),
        revisionID: revisionID,
        word: "Hi",
        lineText: "Hi."
    )
}

private func transcriptRevision(
    sessionID: SessionID,
    durationMilliseconds: UInt64,
    audioFingerprint: AudioFingerprint,
    revisionID: String,
    word: String,
    lineText: String
) throws -> TranscriptRevision {
    let timeRange = try SessionTimeRange(
        startMilliseconds: 0,
        endMilliseconds: durationMilliseconds,
        sessionDurationMilliseconds: durationMilliseconds
    )
    let usePolicy = try EngineUsePolicy(
        policyID: "crisper-evaluation-v1",
        coveredArtifacts: [.transcriptRevision],
        privateLocalUseAllowed: true,
        privateExportAllowed: true,
        externalProcessingAllowed: false,
        publicDistributionAllowed: false,
        commercialUseAllowed: false,
        licenseReference: "pinned-license-reference",
        licenseSHA256: String(repeating: "e", count: 64)
    )
    return try TranscriptRevision(
        revisionID: try TranscriptRevisionID(revisionID),
        sessionID: sessionID,
        jobID: try TranscriptionJobID("job-20260830T120500000Z-5GHJ"),
        createdAt: try UTCInstant("2026-08-30T12:10:00.000Z"),
        durationMilliseconds: durationMilliseconds,
        audioFingerprint: audioFingerprint,
        sourceFingerprints: [
            TranscriptSourceFingerprint(
                audioSourceID: .microphone,
                fingerprint: audioFingerprint
            ),
        ],
        candidateArtifactFingerprint: try AudioFingerprint(
            sha256: String(repeating: "b", count: 64)
        ),
        engine: try TranscriptEngineProvenance(
            provider: "crisperwhisper",
            model: "small",
            revision: "pinned-revision",
            language: "en",
            mode: "verbatim",
            decodingOptionsSHA256: String(repeating: "c", count: 64),
            qualification: try TranscriptEngineQualification(
                qualificationProfileID: "synthetic-qualified-v1",
                engineLockSHA256: String(repeating: "f", count: 64),
                runtimeIdentity: "synthetic-runtime-v1",
                runtimeLockSHA256: String(repeating: "d", count: 64),
                compatibilityPatchID: "synthetic-progress-patch-v1"
            ),
            usePolicy: usePolicy
        ),
        lines: [
            TranscriptLine(
                lineID: try TranscriptLineID("l000000"),
                order: 0,
                audioSourceID: .microphone,
                timeRange: timeRange,
                text: lineText,
                words: [
                    TranscriptWord(
                        wordID: try TranscriptWordID("w000000"),
                        ordinal: 0,
                        text: word,
                        displayRange: LineTextRange(
                            startUTF8Byte: 0,
                            endUTF8Byte: word.utf8.count
                        ),
                        timeRange: timeRange,
                        confidence: 0.95,
                        wordKind: .lexical
                    ),
                ]
            ),
        ],
        audioEvents: [
            TranscriptAudioEvent(
                audioEventID: try AudioEventID("a000000"),
                category: .nonSpeech,
                audioSourceID: .microphone,
                timeRange: timeRange
            ),
        ]
    )
}

private func sessionJSONObject(
    root: URL,
    sessionID: SessionID
) throws -> [String: Any] {
    let data = try Data(contentsOf: root.appendingPathComponent(
        "sessions/\(sessionID.rawValue)/session.json"
    ))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func createEmptyLibrary(at root: URL, libraryID: LibraryID) throws {
    let instant = try UTCInstant("2026-08-30T12:00:00.000Z")
    _ = try PortableLibraryPersistence().create(
        at: root,
        seed: NewLibrarySeed(
            libraryID: libraryID,
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

private extension SHA256.Digest {
    var hexLowercase: String { map { String(format: "%02x", $0) }.joined() }
}
