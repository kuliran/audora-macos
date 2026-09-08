@_spi(CoachContextQualification) @_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
@testable @_spi(CoachContextQualification) @_spi(InvocationInfrastructure) import AudoraMacInfrastructure
import Darwin
import Foundation
import XCTest

final class PortableAttemptTranscriptAvailabilitySourceTests: XCTestCase {
    func testReopensExactChatPinFingerprintAndReportsItsLaterRemoval() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent(
                "TranscriptAvailability.audoralibrary",
                isDirectory: true
            )
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let attachment = try await installRecordedChatAttachmentFixture(
                at: root,
                in: scope
            )
            let attachments = try ChatAttachments(validating: [attachment])
            let fingerprints = try PortableTranscriptRevisionRepository(
                root: root,
                libraryID: scope.libraryID
            ).forEachResolvedChatAttachmentEvidenceSynchronously(attachments) { _ in }
            let revisionSHA256 = try XCTUnwrap(fingerprints.first?.revisionSHA256)
            let persistence = PortableChatPersistence()
            let chat = try persistence.create(
                makeChatSeed(scope: scope, attachments: attachments),
                at: root
            )
            let workspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await workspace.chooseLibrary()
            let source = PortableAttemptTranscriptAvailabilitySource.make(
                workspace: workspace,
                persistence: persistence
            )
            let query = AttemptTranscriptAvailabilityQuery(
                library: scope,
                chatID: chat.chat.id,
                sourceAttachment: attachment,
                revisionSHA256: revisionSHA256
            )

            let available = try await source.availability(for: query)
            let alteredPin = try await source.availability(
                for: AttemptTranscriptAvailabilityQuery(
                    library: scope,
                    chatID: chat.chat.id,
                    sourceAttachment: ChatSessionAttachment(
                        attachmentID: attachment.attachmentID,
                        sessionID: try SessionID("ses-20260830T130000000Z-5HJK"),
                        transcriptRevisionID: try TranscriptRevisionID(
                            "trv-20260830T131000000Z-6KMN"
                        )
                    ),
                    revisionSHA256: revisionSHA256
                )
            )
            let alteredFingerprint = try await source.availability(
                for: AttemptTranscriptAvailabilityQuery(
                    library: scope,
                    chatID: chat.chat.id,
                    sourceAttachment: attachment,
                    revisionSHA256: String(repeating: "2", count: 64)
                )
            )
            try FileManager.default.removeItem(
                at: root.appendingPathComponent(
                    "sessions/\(attachment.sessionID.rawValue)/transcripts/" +
                        attachment.transcriptRevisionID.rawValue,
                    isDirectory: true
                )
            )
            let unavailable = try await source.availability(for: query)

            XCTAssertEqual(available, .available)
            XCTAssertEqual(alteredPin, .unavailable)
            XCTAssertEqual(alteredFingerprint, .unavailable)
            XCTAssertEqual(unavailable, .unavailable)
        }
    }

    func testUnknownChatAttachmentIsDefinitivelyUnavailable() async throws {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent(
                "UnknownAttachment.audoralibrary",
                isDirectory: true
            )
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let persistence = PortableChatPersistence()
            let chat = try persistence.create(makeChatSeed(scope: scope), at: root)
            let workspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await workspace.chooseLibrary()
            let source = PortableAttemptTranscriptAvailabilitySource.make(
                workspace: workspace,
                persistence: persistence
            )

            let result = try await source.availability(
                for: AttemptTranscriptAvailabilityQuery(
                    library: scope,
                    chatID: chat.chat.id,
                    sourceAttachment: ChatSessionAttachment(
                        attachmentID: try ChatSessionAttachmentID("unknown"),
                        sessionID: try SessionID("ses-20260830T120000000Z-3DEF"),
                        transcriptRevisionID: try TranscriptRevisionID(
                            "trv-20260830T121000000Z-4FGH"
                        )
                    ),
                    revisionSHA256: String(repeating: "1", count: 64)
                )
            )

            XCTAssertEqual(result, .unavailable)
        }
    }

    func testBatchHoldsEverySessionFenceUntilTheCompleteSnapshotIsResolved()
        async throws
    {
        try await withTemporaryParent { parent in
            let root = parent.appendingPathComponent(
                "AtomicTranscriptAvailability.audoralibrary",
                isDirectory: true
            )
            let authority = try PortableLibraryPersistence().create(
                at: root,
                seed: makeSeed()
            )
            let scope = LibraryScope(libraryID: authority.manifest.libraryID)
            let first = try await installRecordedChatAttachmentFixture(
                at: root,
                in: scope,
                attachmentID: "attachment-000001"
            )
            let second = try await installRecordedChatAttachmentFixture(
                at: root,
                in: scope,
                attachmentID: "attachment-000002",
                recordingID: "rec-20260830T130000000Z-6HJK",
                sessionID: "ses-20260830T130000000Z-7JKM",
                revisionID: "trv-20260830T131000000Z-8KMN",
                jobID: "job-20260830T130500000Z-9MNP"
            )
            let attachments = try ChatAttachments(validating: [first, second])
            let repository = PortableTranscriptRevisionRepository(
                root: root,
                libraryID: scope.libraryID
            )
            let fingerprints = try repository
                .forEachResolvedChatAttachmentEvidenceSynchronously(
                    attachments
                ) { _ in }
            XCTAssertEqual(fingerprints.map(\.attachment), [first, second])
            let persistence = PortableChatPersistence()
            let chat = try persistence.create(
                makeChatSeed(scope: scope, attachments: attachments),
                at: root
            )
            let workspace = PortableLibraryWorkspace(
                locations: QueueLocations(existing: [root]),
                bookmarks: SyntheticBookmarks(),
                access: RecordingAccessGrantor(),
                locatorStore: MemoryLocatorStore(),
                revealer: RecordingRevealer()
            )
            _ = await workspace.chooseLibrary()
            let trashMove = CooperatingSessionTrashMove(
                root: root,
                sessionID: second.sessionID
            )
            let once = OneShot()
            let source = PortableAttemptTranscriptAvailabilitySource.make(
                workspace: workspace,
                persistence: persistence
            ) { point in
                guard point == .beforeChatAttachmentFinalRevalidation,
                      once.take()
                else { return }
                trashMove.start()
                trashMove.waitUntilInitialLockAttemptCompletes()
            }
            let queries = fingerprints.map { fingerprint in
                AttemptTranscriptAvailabilityQuery(
                    library: scope,
                    chatID: chat.chat.id,
                    sourceAttachment: fingerprint.attachment,
                    revisionSHA256: fingerprint.revisionSHA256
                )
            }

            let beforeTrashCompletes = try await source.availabilities(
                for: queries
            )
            trashMove.waitUntilFinished()
            let afterTrashCompletes = try await source.availabilities(
                for: queries
            )

            XCTAssertNil(trashMove.failure)
            XCTAssertTrue(
                trashMove.wasBlockedBySharedFence,
                "all requested Session locks must be held before any member is read"
            )
            XCTAssertEqual(beforeTrashCompletes, [.available, .available])
            XCTAssertEqual(afterTrashCompletes, [.available, .unavailable])
        }
    }

    func testRetryPolicyIsBoundedAndStopsOnDefinitiveResult() async throws {
        let query = AttemptTranscriptAvailabilityQuery(
            library: LibraryScope(
                libraryID: try LibraryID("lib-20260830T120000000Z-2ABC")
            ),
            chatID: try ChatID("cht-20260830T120000000Z-2ABC"),
            sourceAttachment: ChatSessionAttachment(
                attachmentID: try ChatSessionAttachmentID("attachment-1"),
                sessionID: try SessionID("ses-20260830T120000000Z-3DEF"),
                transcriptRevisionID: try TranscriptRevisionID(
                    "trv-20260830T121000000Z-4FGH"
                )
            ),
            revisionSHA256: String(repeating: "1", count: 64)
        )
        let eventuallyAvailable = ScriptedAvailabilityInspection(
            results: [nil, nil, .available]
        )
        let successSource = PortableAttemptTranscriptAvailabilitySource.make(
            maximumAttempts: 3
        ) { query in
            await eventuallyAvailable.inspect(query)
        }
        let persistentlyTransient = ScriptedAvailabilityInspection(results: [])
        let boundedSource = PortableAttemptTranscriptAvailabilitySource.make(
            maximumAttempts: 3
        ) { query in
            await persistentlyTransient.inspect(query)
        }
        let definitive = ScriptedAvailabilityInspection(results: [.unavailable])
        let definitiveSource = PortableAttemptTranscriptAvailabilitySource.make(
            maximumAttempts: 3
        ) { query in
            await definitive.inspect(query)
        }

        let success = try await successSource.availability(for: query)
        let bounded = try await boundedSource.availability(for: query)
        let unavailable = try await definitiveSource.availability(for: query)
        let successCount = await eventuallyAvailable.count
        let boundedCount = await persistentlyTransient.count
        let definitiveCount = await definitive.count

        XCTAssertEqual(success, .available)
        XCTAssertEqual(successCount, 3)
        XCTAssertEqual(bounded, .unavailable)
        XCTAssertEqual(boundedCount, 3)
        XCTAssertEqual(unavailable, .unavailable)
        XCTAssertEqual(definitiveCount, 1)
    }

    func testEveryAvailabilityLockContentionRemainsTimeBounded() async throws {
        for target in AvailabilityLockTarget.allCases {
            try await withTemporaryParent { parent in
                let root = parent.appendingPathComponent(
                    "BoundedLock-\(target.rawValue).audoralibrary",
                    isDirectory: true
                )
                let authority = try PortableLibraryPersistence().create(
                    at: root,
                    seed: makeSeed()
                )
                let scope = LibraryScope(libraryID: authority.manifest.libraryID)
                let attachment = try await installRecordedChatAttachmentFixture(
                    at: root,
                    in: scope
                )
                let attachments = try ChatAttachments(validating: [attachment])
                let fingerprints = try PortableTranscriptRevisionRepository(
                    root: root,
                    libraryID: scope.libraryID
                ).forEachResolvedChatAttachmentEvidenceSynchronously(
                    attachments
                ) { _ in }
                let persistence = PortableChatPersistence()
                let chat = try persistence.create(
                    makeChatSeed(scope: scope, attachments: attachments),
                    at: root
                )
                let workspace = PortableLibraryWorkspace(
                    locations: QueueLocations(existing: [root]),
                    bookmarks: SyntheticBookmarks(),
                    access: RecordingAccessGrantor(),
                    locatorStore: MemoryLocatorStore(),
                    revealer: RecordingRevealer()
                )
                _ = await workspace.chooseLibrary()
                let source = PortableAttemptTranscriptAvailabilitySource.make(
                    workspace: workspace,
                    persistence: persistence
                )
                let query = AttemptTranscriptAvailabilityQuery(
                    library: scope,
                    chatID: chat.chat.id,
                    sourceAttachment: attachment,
                    revisionSHA256: try XCTUnwrap(
                        fingerprints.first?.revisionSHA256
                    )
                )
                let lockURL = switch target {
                case .root:
                    root
                case .staging:
                    root.appendingPathComponent("staging", isDirectory: true)
                case .chat:
                    root.appendingPathComponent(
                        "chats/\(chat.chat.id.rawValue)",
                        isDirectory: true
                    )
                case .session:
                    root.appendingPathComponent(
                        "sessions/\(attachment.sessionID.rawValue)",
                        isDirectory: true
                    )
                }
                let exclusiveLock = try TimedExclusiveDirectoryLock(
                    url: lockURL,
                    safetyReleaseAfter: 1
                )

                let startedAt = Date()
                let result = try await source.availabilities(for: [query])
                let elapsed = Date().timeIntervalSince(startedAt)
                exclusiveLock.release()

                XCTAssertEqual(result, [.unavailable], target.rawValue)
                XCTAssertLessThan(
                    elapsed,
                    0.75,
                    "\(target.rawValue) contention must not wait for the safety unlock"
                )
            }
        }
    }
}

private enum AvailabilityLockTarget: String, CaseIterable {
    case root
    case staging
    case chat
    case session
}

@_silgen_name("flock")
private func attemptAvailabilityTestFlock(
    _ descriptor: Int32,
    _ operation: Int32
) -> Int32

private final class TimedExclusiveDirectoryLock: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32?

    init(url: URL, safetyReleaseAfter seconds: TimeInterval) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw LockFailure.openFailed }
        guard attemptAvailabilityTestFlock(descriptor, LOCK_EX | LOCK_NB) == 0
        else {
            Darwin.close(descriptor)
            throw LockFailure.lockFailed
        }
        self.descriptor = descriptor
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + seconds
        ) { [self] in
            release()
        }
    }

    func release() {
        let descriptor = stateLock.withLock { () -> Int32? in
            defer { self.descriptor = nil }
            return self.descriptor
        }
        guard let descriptor else { return }
        _ = attemptAvailabilityTestFlock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    deinit { release() }

    private enum LockFailure: Error {
        case openFailed
        case lockFailed
    }
}

private actor ScriptedAvailabilityInspection {
    private var results: [AttemptTranscriptAvailability?]
    private(set) var count = 0

    init(results: [AttemptTranscriptAvailability?]) {
        self.results = results
    }

    func inspect(
        _ query: AttemptTranscriptAvailabilityQuery
    ) -> AttemptTranscriptAvailability? {
        count += 1
        return results.isEmpty ? nil : results.removeFirst()
    }
}
