@_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
import Darwin
import Foundation

@_silgen_name("flock")
private func invocationAdmissionFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

private enum MachineInvocationAdmissionError: Error {
    case unavailable
    case invalidLedger
    case ledgerTooLarge
}

/// Machine-local, Library-keyed rolling admission. The lock covers read,
/// decision, and durable replacement so separate app processes cannot both
/// consume the same 60-second window.
@_spi(InvocationInfrastructure)
public actor ApplicationSupportInvocationAdmission: InvocationAdmissionPort {
    public static let maximumLedgerBytes = 1_048_576
    /// Darwin `flock` ownership is process-wide. This mutex preserves the same
    /// exclusion between independently composed actors in one app process;
    /// `flock` remains the cross-process authority.
    private static let processLock = NSLock()

    private struct LedgerDTO: Codable {
        let schemaVersion: UInt32
        let entries: [EntryDTO]
    }

    private struct EntryDTO: Codable {
        let libraryId: String
        let lastAdmittedAt: String
    }

    private let fileURL: URL
    private let maximumLibraries: Int

    public init(
        fileURL: URL,
        maximumLibraries: Int = RollingInvocationAdmissionLedger.defaultMaximumLibraries
    ) {
        self.fileURL = fileURL
        self.maximumLibraries = maximumLibraries
    }

    public func claim(
        library: LibraryScope,
        at instant: UTCInstant
    ) async -> InvocationAdmissionClaimOutcome {
        do {
            return try claimSynchronously(library: library, at: instant)
        } catch {
            return .unavailable
        }
    }

    private func claimSynchronously(
        library: LibraryScope,
        at instant: UTCInstant
    ) throws -> InvocationAdmissionClaimOutcome {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard maximumLibraries > 0 else { throw MachineInvocationAdmissionError.unavailable }
        let parentURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let parent = Darwin.open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parent >= 0 else { throw MachineInvocationAdmissionError.unavailable }
        defer { Darwin.close(parent) }

        let fileName = fileURL.lastPathComponent
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/")
        else { throw MachineInvocationAdmissionError.unavailable }

        let lockName = ".\(fileName).lock"
        let lockDescriptor = lockName.withCString { pointer -> Int32 in
            while true {
                let value = Darwin.openat(
                    parent,
                    pointer,
                    O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                    0o600
                )
                if value < 0, errno == EINTR { continue }
                return value
            }
        }
        guard lockDescriptor >= 0 else { throw MachineInvocationAdmissionError.unavailable }
        defer { Darwin.close(lockDescriptor) }
        var lockMetadata = stat()
        guard fstat(lockDescriptor, &lockMetadata) == 0,
              (lockMetadata.st_mode & S_IFMT) == S_IFREG,
              lockMetadata.st_nlink == 1
        else { throw MachineInvocationAdmissionError.unavailable }
        while invocationAdmissionFlock(lockDescriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw MachineInvocationAdmissionError.unavailable
        }
        defer { _ = invocationAdmissionFlock(lockDescriptor, LOCK_UN) }

        var ledger = try loadLedger(named: fileName, under: parent)
        let decision = ledger.claim(library: library, at: instant)
        switch decision {
        case .admitted:
            try persist(ledger, named: fileName, under: parent)
            return .admitted
        case let .cooldown(lastAdmittedAt, reopensAt):
            return .cooldown(lastAdmittedAt: lastAdmittedAt, reopensAt: reopensAt)
        case let .clockRollback(lastAdmittedAt):
            return .clockRollback(lastAdmittedAt: lastAdmittedAt)
        case .ledgerFull:
            return .ledgerFull
        case .invalidClockRange:
            return .unavailable
        }
    }

    private func loadLedger(
        named name: String,
        under parent: Int32
    ) throws -> RollingInvocationAdmissionLedger {
        let descriptor = name.withCString { pointer -> Int32 in
            while true {
                let value = Darwin.openat(
                    parent,
                    pointer,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                if value < 0, errno == EINTR { continue }
                return value
            }
        }
        if descriptor < 0 {
            guard errno == ENOENT else { throw MachineInvocationAdmissionError.unavailable }
            return try RollingInvocationAdmissionLedger(
                validating: [],
                maximumLibraries: maximumLibraries
            )
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0
        else { throw MachineInvocationAdmissionError.invalidLedger }
        guard metadata.st_size <= Self.maximumLedgerBytes else {
            throw MachineInvocationAdmissionError.ledgerTooLarge
        }
        var data = Data(count: Int(metadata.st_size) + 1)
        let count = data.withUnsafeMutableBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            var offset = 0
            while offset < bytes.count {
                let value = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if value == 0 { break }
                if value < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                offset += value
            }
            return offset
        }
        guard count >= 0,
              count == Int(metadata.st_size),
              count <= Self.maximumLedgerBytes
        else { throw MachineInvocationAdmissionError.invalidLedger }
        data.removeSubrange(count ..< data.count)
        return try decode(data)
    }

    private func decode(_ data: Data) throws -> RollingInvocationAdmissionLedger {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["schemaVersion", "entries"],
              let rawEntries = root["entries"] as? [[String: Any]],
              rawEntries.count <= maximumLibraries,
              rawEntries.allSatisfy({ Set($0.keys) == ["libraryId", "lastAdmittedAt"] })
        else { throw MachineInvocationAdmissionError.invalidLedger }
        let dto = try JSONDecoder().decode(LedgerDTO.self, from: data)
        guard dto.schemaVersion == RollingInvocationAdmissionLedger.schemaVersion,
              try encode(dto) == data
        else { throw MachineInvocationAdmissionError.invalidLedger }
        let entries = try dto.entries.map { entry in
            RollingInvocationAdmissionEntry(
                library: LibraryScope(libraryID: try LibraryID(entry.libraryId)),
                lastAdmittedAt: try UTCInstant(entry.lastAdmittedAt)
            )
        }
        return try RollingInvocationAdmissionLedger(
            validating: entries,
            maximumLibraries: maximumLibraries
        )
    }

    private func persist(
        _ ledger: RollingInvocationAdmissionLedger,
        named name: String,
        under parent: Int32
    ) throws {
        let dto = LedgerDTO(
            schemaVersion: RollingInvocationAdmissionLedger.schemaVersion,
            entries: ledger.entries.map {
                EntryDTO(
                    libraryId: $0.library.libraryID.rawValue,
                    lastAdmittedAt: $0.lastAdmittedAt.rawValue
                )
            }
        )
        let data = try encode(dto)
        guard data.count <= Self.maximumLedgerBytes else {
            throw MachineInvocationAdmissionError.ledgerTooLarge
        }
        let partialName = ".\(name).partial"
        var partialMetadata = stat()
        let partialStatus = partialName.withCString {
            Darwin.fstatat(parent, $0, &partialMetadata, AT_SYMLINK_NOFOLLOW)
        }
        if partialStatus == 0 {
            guard (partialMetadata.st_mode & S_IFMT) == S_IFREG,
                  partialMetadata.st_nlink == 1,
                  unlinkat(parent, partialName, 0) == 0
            else { throw MachineInvocationAdmissionError.unavailable }
        } else if errno != ENOENT {
            throw MachineInvocationAdmissionError.unavailable
        }

        let descriptor = partialName.withCString { pointer -> Int32 in
            while true {
                let value = Darwin.openat(
                    parent,
                    pointer,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    0o600
                )
                if value < 0, errno == EINTR { continue }
                return value
            }
        }
        guard descriptor >= 0 else { throw MachineInvocationAdmissionError.unavailable }
        var ownsPartial = true
        defer {
            Darwin.close(descriptor)
            if ownsPartial { _ = unlinkat(parent, partialName, 0) }
        }
        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let value = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if value < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if value == 0 { return false }
                offset += value
            }
            return true
        }
        guard wroteAll, fsyncRetrying(descriptor) else {
            throw MachineInvocationAdmissionError.unavailable
        }
        let renameStatus = partialName.withCString { source in
            name.withCString { destination in
                Darwin.renameat(parent, source, parent, destination)
            }
        }
        guard renameStatus == 0 else { throw MachineInvocationAdmissionError.unavailable }
        ownsPartial = false
        guard fsyncRetrying(parent) else { throw MachineInvocationAdmissionError.unavailable }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    private func fsyncRetrying(_ descriptor: Int32) -> Bool {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            return false
        }
        return true
    }
}

@_spi(InvocationInfrastructure)
public struct UnavailableInvocationAdmission: InvocationAdmissionPort {
    public init() {}

    public func claim(
        library: LibraryScope,
        at instant: UTCInstant
    ) async -> InvocationAdmissionClaimOutcome {
        .unavailable
    }
}

@_spi(InvocationInfrastructure)
public enum MachineInvocationAdmissionFactory {
    public static func live(
        fileManager: FileManager = .default
    ) -> any InvocationAdmissionPort {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return UnavailableInvocationAdmission()
        }
        return ApplicationSupportInvocationAdmission(
            fileURL: applicationSupport
                .appendingPathComponent("Audora", isDirectory: true)
                .appendingPathComponent("invocation-admission.json")
        )
    }
}
