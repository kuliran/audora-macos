import AppKit
@_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
import Darwin
import Foundation
import UniformTypeIdentifiers

public extension UTType {
    static let audoraLibrary = UTType(exportedAs: "com.audora.library", conformingTo: .package)
}

public final class AppKitLibraryLocationChooser: LibraryLocationChoosing, @unchecked Sendable {
    public init() {}

    @MainActor
    public func chooseCreateDestination() async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.audoraLibrary]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "Audora Library.audoralibrary"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.pathExtension == "audoralibrary"
            ? url
            : url.appendingPathExtension("audoralibrary")
    }

    @MainActor
    public func chooseExistingLibrary() async -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audoraLibrary]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

public final class AppKitAudioFileChooser: AudioFileChoosing, @unchecked Sendable {
    public init() {}

    @MainActor
    public func chooseAudioFile() async -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["m4a", "wav"].compactMap {
            UTType(filenameExtension: $0)
        }
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

public struct SecurityScopedLibraryBookmarks: LibraryBookmarking {
    public init() {}

    public func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public func resolveBookmark(_ bookmark: Data) throws -> LibraryBookmarkResolution {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return LibraryBookmarkResolution(url: url, isStale: stale)
    }
}

public struct SecurityScopedLibraryAccessGrantor: LibraryAccessGranting {
    public init() {}

    public func acquireAccess(to url: URL) throws -> any LibraryAccessLease {
        SecurityScopedLibraryAccessLease(url: url)
    }
}

private final class SecurityScopedLibraryAccessLease: LibraryAccessLease, @unchecked Sendable {
    let url: URL
    private let didStartSecurityScope: Bool
    private let lock = NSLock()
    private var released = false

    init(url: URL) {
        self.url = url
        didStartSecurityScope = url.startAccessingSecurityScopedResource()
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        if didStartSecurityScope {
            url.stopAccessingSecurityScopedResource()
        }
    }

    deinit {
        release()
    }
}

public actor ApplicationSupportLibraryLocatorStore: MachineLibraryLocatorStoring {
    private struct LocatorDTO: Codable {
        let schemaVersion: UInt32
        let expectedLibraryId: String
        let restoreOnLaunch: Bool
        let bookmark: Data
    }

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() async throws -> MachineLibraryLocator? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let descriptor = fileURL.path.withCString { pointer -> Int32 in
            while true {
                let result = Darwin.open(
                    pointer,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= 1_048_576
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var data = Data(count: Int(metadata.st_size))
        let readCount = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if result == 0 { break }
                if result < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                offset += result
            }
            return offset
        }
        guard readCount == data.count else { throw CocoaError(.fileReadUnknown) }
        var trailingByte: UInt8 = 0
        let trailingCount = withUnsafeMutablePointer(to: &trailingByte) { pointer -> Int in
            while true {
                let result = Darwin.read(descriptor, pointer, 1)
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        guard trailingCount == 0 else { throw CocoaError(.fileReadCorruptFile) }
        let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let dictionary,
              Set(dictionary.keys) == Set([
                  "schemaVersion", "expectedLibraryId", "restoreOnLaunch", "bookmark",
              ])
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let dto = try JSONDecoder().decode(LocatorDTO.self, from: data)
        guard dto.schemaVersion == 1 else { throw CocoaError(.fileReadUnknown) }
        return MachineLibraryLocator(
            expectedLibraryID: try LibraryID(dto.expectedLibraryId),
            restoreOnLaunch: dto.restoreOnLaunch,
            bookmark: dto.bookmark
        )
    }

    public func save(_ locator: MachineLibraryLocator) async throws {
        let dto = LocatorDTO(
            schemaVersion: 1,
            expectedLibraryId: locator.expectedLibraryID.rawValue,
            restoreOnLaunch: locator.restoreOnLaunch,
            bookmark: locator.bookmark
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(dto)
        data.append(0x0A)

        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let partial = parent.appendingPathComponent(".library-locator.\(UUID().uuidString).partial")
        do {
            let descriptor = Darwin.open(
                partial.path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                0o600
            )
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            var descriptorOpen = true
            defer { if descriptorOpen { Darwin.close(descriptor) } }
            let wroteAll = data.withUnsafeBytes { buffer -> Bool in
                guard let base = buffer.baseAddress else { return data.isEmpty }
                var offset = 0
                while offset < buffer.count {
                    let result = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        buffer.count - offset
                    )
                    if result < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    offset += result
                }
                return true
            }
            guard wroteAll, fsync(descriptor) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard Darwin.close(descriptor) == 0 else {
                descriptorOpen = false
                throw CocoaError(.fileWriteUnknown)
            }
            descriptorOpen = false
            guard rename(partial.path, fileURL.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            try Self.flushDirectory(parent)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    private static func flushDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

public struct UnavailableMachineLibraryLocatorStore: MachineLibraryLocatorStoring {
    public init() {}

    public func load() async throws -> MachineLibraryLocator? {
        throw CocoaError(.fileReadUnknown)
    }

    public func save(_ locator: MachineLibraryLocator) async throws {
        throw CocoaError(.fileWriteUnknown)
    }
}

public enum MachineLibraryLocatorFactory {
    public static func live(
        fileManager: FileManager = .default
    ) -> any MachineLibraryLocatorStoring {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return UnavailableMachineLibraryLocatorStore()
        }
        // Resolving this URL is side-effect free. The concrete store creates its
        // machine-local parent only on the first successful locator commit.
        return ApplicationSupportLibraryLocatorStore(
            fileURL: applicationSupport
                .appendingPathComponent("Audora", isDirectory: true)
                .appendingPathComponent("library-locator.json")
        )
    }
}

public struct NSWorkspaceLibraryRevealer: LibraryRevealing {
    public init() {}

    @MainActor
    public func reveal(_ url: URL) async -> Bool {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }
}

public struct SystemLibraryClock: LibraryClock, ChatClock {
    public init() {}

    public func now() async -> UTCInstant {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return try! UTCInstant(formatter.string(from: Date()))
    }
}

private enum RandomPortableIdentifierFormatter {
    enum Prefix: String {
        case library = "lib-"
        case session = "ses-"
        case chat = "cht-"
        case draft = "drf-"
        case memory = "mem-"
        case pendingUserTurn = "ptu-"
        case responsePosition = "rsp-"
        case invocation = "inv-"
        case attempt = "atm-"
        case message = "msg-"
    }

    private static let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func make(_ prefix: Prefix, at instant: UTCInstant) -> String {
        let compact = instant.rawValue
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
        var generator = SystemRandomNumberGenerator()
        let suffix = String((0 ..< 4).map { _ in
            crockford.randomElement(using: &generator)!
        })
        return "\(prefix.rawValue)\(compact)-\(suffix)"
    }

    static func incrementingFinalCrockfordDigit(of value: String) -> String {
        let last = value.last!
        let index = crockford.firstIndex(of: last)!
        return String(value.dropLast()) + String(crockford[(index + 1) % crockford.count])
    }
}

public struct RandomChatIdentityGenerator:
    ChatIDGenerator,
    ChatDraftIDGenerator,
    CoachMemoryIDGenerator,
    PendingUserTurnIDGenerator,
    ChatResponsePositionIDGenerator
{
    public init() {}

    public func generateChatID(at instant: UTCInstant) async -> ChatID {
        try! ChatID(RandomPortableIdentifierFormatter.make(.chat, at: instant))
    }

    public func generateChatDraftID(at instant: UTCInstant) async -> ChatDraftID {
        try! ChatDraftID(RandomPortableIdentifierFormatter.make(.draft, at: instant))
    }

    public func generateCoachMemoryID(at instant: UTCInstant) async -> CoachMemoryID {
        try! CoachMemoryID(RandomPortableIdentifierFormatter.make(.memory, at: instant))
    }

    public func generatePendingUserTurnID(at instant: UTCInstant) async -> PendingUserTurnID {
        try! PendingUserTurnID(
            RandomPortableIdentifierFormatter.make(.pendingUserTurn, at: instant)
        )
    }

    public func generateChatResponsePositionID(
        at instant: UTCInstant
    ) async -> ChatResponsePositionID {
        try! ChatResponsePositionID(
            RandomPortableIdentifierFormatter.make(.responsePosition, at: instant)
        )
    }
}

@_spi(InvocationInfrastructure)
public struct RandomInvocationIdentityGenerator: InvocationIdentityGenerating {
    public init() {}

    public func generate(at instant: UTCInstant) async -> InvocationLaunchIdentity {
        let attemptID = try! CoachProviderAttemptID(
            RandomPortableIdentifierFormatter.make(.attempt, at: instant)
        )
        let userMessageRaw = RandomPortableIdentifierFormatter.make(.message, at: instant)
        return InvocationLaunchIdentity(
            invocationID: try! CoachInvocationID(
                RandomPortableIdentifierFormatter.make(.invocation, at: instant)
            ),
            attemptID: attemptID,
            idempotencyValue: try! ProviderIdempotencyValue(attemptID.rawValue),
            userMessageID: try! ChatMessageID(userMessageRaw),
            coachMessageID: try! ChatMessageID(
                RandomPortableIdentifierFormatter.incrementingFinalCrockfordDigit(
                    of: userMessageRaw
                )
            ),
            freshDraftID: try! ChatDraftID(
                RandomPortableIdentifierFormatter.make(.draft, at: instant)
            )
        )
    }
}

public struct ActiveLibraryProfileStatementGenerationReader: ProfileStatementGenerationReading {
    private let workspace: PortableLibraryWorkspace

    public init(workspace: PortableLibraryWorkspace) {
        self.workspace = workspace
    }

    public func statementGeneration(in library: LibraryScope) async -> UInt64? {
        await workspace.activeProfileStatementGeneration(in: library)
    }
}

public struct RandomLibraryIDGenerator: LibraryIDGenerator {
    public init() {}

    public func generateLibraryID(at instant: UTCInstant) async -> LibraryID {
        try! LibraryID(RandomPortableIdentifierFormatter.make(.library, at: instant))
    }
}

public struct RandomSessionIDGenerator: SessionIDGenerator {
    public init() {}

    public func generateSessionID(at instant: UTCInstant) async -> SessionID {
        try! SessionID(RandomPortableIdentifierFormatter.make(.session, at: instant))
    }
}
