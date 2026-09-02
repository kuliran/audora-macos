@_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
import Darwin
import Foundation

@_silgen_name("flock")
private func invocationAdmissionFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

private enum MachineInvocationAdmissionError: Error {
    case unavailable
    case commitUncertain
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
    private let confined: ConfinedPersistencePrimitives<MachineInvocationAdmissionError>

    public init(
        fileURL: URL,
        maximumLibraries: Int = RollingInvocationAdmissionLedger.defaultMaximumLibraries
    ) {
        self.fileURL = fileURL
        self.maximumLibraries = maximumLibraries
        confined = Self.makeConfined()
    }

    init(
        fileURL: URL,
        maximumLibraries: Int = RollingInvocationAdmissionLedger.defaultMaximumLibraries,
        descriptorOperations: ConfinedPersistenceDescriptorOperations
    ) {
        self.fileURL = fileURL
        self.maximumLibraries = maximumLibraries
        confined = Self.makeConfined(descriptorOperations: descriptorOperations)
    }

    public func claim(
        library: LibraryScope,
        at instant: UTCInstant
    ) async -> InvocationAdmissionClaimOutcome {
        do {
            return try claimSynchronously(library: library, at: instant)
        } catch MachineInvocationAdmissionError.commitUncertain {
            return .commitUncertain
        } catch {
            return .unavailable
        }
    }

    public func availability(
        library: LibraryScope,
        at instant: UTCInstant
    ) async -> InvocationAdmissionAvailability {
        do {
            return try availabilitySynchronously(library: library, at: instant)
        } catch {
            return .unavailable
        }
    }

    private func claimSynchronously(
        library: LibraryScope,
        at instant: UTCInstant
    ) throws -> InvocationAdmissionClaimOutcome {
        try withLockedLedger { ledger, fileName, parent in
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
    }

    private func availabilitySynchronously(
        library: LibraryScope,
        at instant: UTCInstant
    ) throws -> InvocationAdmissionAvailability {
        try withLockedLedger { ledger, _, _ in
            switch ledger.availability(library: library, at: instant) {
            case .available:
                return .available
            case let .cooldown(_, reopensAt), let .clockRollback(_, reopensAt):
                return .cooldown(reopensAt: reopensAt)
            case .ledgerFull, .invalidClockRange:
                return .unavailable
            }
        }
    }

    private func withLockedLedger<Result>(
        _ operation: (
            inout RollingInvocationAdmissionLedger,
            _ fileName: String,
            _ parent: Int32
        ) throws -> Result
    ) throws -> Result {
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
        return try operation(&ledger, fileName, parent)
    }

    private func loadLedger(
        named name: String,
        under parent: Int32
    ) throws -> RollingInvocationAdmissionLedger {
        guard try confined.entryExists(named: name, under: parent) else {
            return try RollingInvocationAdmissionLedger(
                validating: [],
                maximumLibraries: maximumLibraries
            )
        }
        return try decode(confined.boundedData(
            named: name,
            under: parent,
            maximumBytes: Self.maximumLedgerBytes,
            requireSingleLink: true
        ))
    }

    private func decode(_ data: Data) throws -> RollingInvocationAdmissionLedger {
        let root = try confined.jsonDictionary(data)
        try confined.requireExactKeys(root, ["schemaVersion", "entries"])
        guard let rawEntries = root["entries"] as? [[String: Any]],
              rawEntries.count <= maximumLibraries,
              rawEntries.allSatisfy({ Set($0.keys) == ["libraryId", "lastAdmittedAt"] })
        else { throw MachineInvocationAdmissionError.invalidLedger }
        let dto = try confined.decode(LedgerDTO.self, from: data)
        guard dto.schemaVersion == RollingInvocationAdmissionLedger.schemaVersion,
              try confined.deterministicJSON(dto) == data
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
        let data = try confined.deterministicJSON(dto)
        guard data.count <= Self.maximumLedgerBytes else {
            throw MachineInvocationAdmissionError.ledgerTooLarge
        }
        guard try confined.replaceAtomically(
            data,
            named: name,
            via: ".\(name).partial",
            under: parent
        ) == .committed else {
            throw MachineInvocationAdmissionError.commitUncertain
        }
    }

    private static func makeConfined(
        descriptorOperations: ConfinedPersistenceDescriptorOperations = .init()
    ) -> ConfinedPersistencePrimitives<MachineInvocationAdmissionError> {
        ConfinedPersistencePrimitives(
            ioFailure: .unavailable,
            invalidLayout: .invalidLedger,
            expectedPathIsSymlink: .invalidLedger,
            rootTooLarge: .ledgerTooLarge,
            invalidJSON: .invalidLedger,
            invalidSchemaVersion: .invalidLedger,
            unknownKey: .invalidLedger,
            descriptorOperations: descriptorOperations
        )
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

    public func availability(
        library: LibraryScope,
        at instant: UTCInstant
    ) async -> InvocationAdmissionAvailability {
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
