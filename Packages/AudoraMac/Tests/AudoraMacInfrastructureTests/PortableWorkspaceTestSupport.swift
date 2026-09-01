@_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
@testable @_spi(InvocationInfrastructure) import AudoraMacInfrastructure
import Foundation

func withTemporaryParent(
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

func makeSeed(
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

func makeChatSeed(scope: LibraryScope) throws -> NewDevelopmentChatSeed {
    try NewDevelopmentChatSeed(
        library: scope,
        chatID: ChatID("cht-20260830T120000000Z-2ABC"),
        draftID: ChatDraftID("drf-20260830T120000000Z-3DEF"),
        memoryID: CoachMemoryID("mem-20260830T120000000Z-4GHJ"),
        instant: UTCInstant("2026-08-30T12:00:00.000Z"),
        profileStatementGeneration: 0
    )
}

final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func take() -> Bool {
        lock.withLock {
            guard !fired else { return false }
            fired = true
            return true
        }
    }

    var wasTaken: Bool { lock.withLock { fired } }
}

final class InvocationLivenessReleaseObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var didRelease: @Sendable () -> Void {
        { [weak self] in self?.recordRelease() }
    }

    func waitUntilReleased() async {
        if lock.withLock({ released }) { return }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if released { return true }
                waiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    private func recordRelease() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !released else { return [] }
            released = true
            defer { waiters.removeAll() }
            return waiters
        }
        continuations.forEach { $0.resume() }
    }
}

actor QueueLocations: LibraryLocationChoosing {
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

final class SyntheticBookmarks: LibraryBookmarking, @unchecked Sendable {
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

final class RecordingAccessGrantor: LibraryAccessGranting, @unchecked Sendable {
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

final class RecordingLease: LibraryAccessLease, @unchecked Sendable {
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

actor MemoryLocatorStore: MachineLibraryLocatorStoring {
    private var value: MachineLibraryLocator?
    private(set) var saveCount = 0

    init(value: MachineLibraryLocator? = nil) { self.value = value }

    func load() async throws -> MachineLibraryLocator? { value }

    func save(_ locator: MachineLibraryLocator) async throws {
        value = locator
        saveCount += 1
    }
}

actor RecordingRevealer: LibraryRevealing {
    private(set) var revealedNames: [String] = []

    func reveal(_ url: URL) async -> Bool {
        revealedNames.append(url.lastPathComponent)
        return true
    }
}
