import AudoraApplication
import AudoraDomain
@testable import AudoraMacInfrastructure
import Darwin
import Foundation
import XCTest

final class PortableLibraryWorkspaceTests: XCTestCase {
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
