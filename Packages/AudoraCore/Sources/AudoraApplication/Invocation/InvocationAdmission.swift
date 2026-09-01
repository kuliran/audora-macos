import AudoraDomain

@_spi(InvocationInfrastructure)
public enum RollingInvocationAdmissionLedgerError: Error, Equatable, Sendable {
    case invalidLimit
    case tooManyLibraries
    case duplicateLibrary
}

@_spi(InvocationInfrastructure)
public struct RollingInvocationAdmissionEntry: Equatable, Sendable {
    public let library: LibraryScope
    public let lastAdmittedAt: UTCInstant

    public init(library: LibraryScope, lastAdmittedAt: UTCInstant) {
        self.library = library
        self.lastAdmittedAt = lastAdmittedAt
    }
}

@_spi(InvocationInfrastructure)
public enum RollingInvocationAdmissionDecision: Equatable, Sendable {
    case admitted
    case cooldown(lastAdmittedAt: UTCInstant, reopensAt: UTCInstant)
    case clockRollback(lastAdmittedAt: UTCInstant)
    case ledgerFull
    case invalidClockRange
}

@_spi(InvocationInfrastructure)
public enum RollingInvocationAdmissionAvailability: Equatable, Sendable {
    case available
    case cooldown(lastAdmittedAt: UTCInstant, reopensAt: UTCInstant)
    case clockRollback(lastAdmittedAt: UTCInstant, reopensAt: UTCInstant)
    case ledgerFull
    case invalidClockRange
}

/// The deterministic policy value persisted by the machine-local admission adapter.
///
/// A wall-clock rollback is conservative: an instant earlier than the last durable
/// debit cannot reopen admission. Exact equality at `lastAdmittedAt + 60 seconds`
/// admits. Entries are never evicted implicitly because doing so could erase a live
/// rolling-window debit.
@_spi(InvocationInfrastructure)
public struct RollingInvocationAdmissionLedger: Equatable, Sendable {
    public static let schemaVersion: UInt32 = 1
    public static let windowMilliseconds: Int64 = 60_000
    public static let defaultMaximumLibraries = 4_096

    public private(set) var entries: [RollingInvocationAdmissionEntry]
    public let maximumLibraries: Int

    public init(maximumLibraries: Int = Self.defaultMaximumLibraries) {
        entries = []
        self.maximumLibraries = max(1, maximumLibraries)
    }

    public init(
        validating entries: [RollingInvocationAdmissionEntry],
        maximumLibraries: Int = Self.defaultMaximumLibraries
    ) throws {
        guard maximumLibraries > 0 else {
            throw RollingInvocationAdmissionLedgerError.invalidLimit
        }
        guard entries.count <= maximumLibraries else {
            throw RollingInvocationAdmissionLedgerError.tooManyLibraries
        }
        guard Set(entries.map(\.library)).count == entries.count else {
            throw RollingInvocationAdmissionLedgerError.duplicateLibrary
        }
        self.entries = entries.sorted {
            $0.library.libraryID.rawValue < $1.library.libraryID.rawValue
        }
        self.maximumLibraries = maximumLibraries
    }

    public mutating func claim(
        library: LibraryScope,
        at instant: UTCInstant
    ) -> RollingInvocationAdmissionDecision {
        switch availability(library: library, at: instant) {
        case .available:
            if let index = entries.firstIndex(where: { $0.library == library }) {
                entries[index] = RollingInvocationAdmissionEntry(
                    library: library,
                    lastAdmittedAt: instant
                )
            } else {
                entries.append(
                    RollingInvocationAdmissionEntry(
                        library: library,
                        lastAdmittedAt: instant
                    )
                )
                entries.sort {
                    $0.library.libraryID.rawValue < $1.library.libraryID.rawValue
                }
            }
            return .admitted
        case let .cooldown(lastAdmittedAt, reopensAt):
            return .cooldown(lastAdmittedAt: lastAdmittedAt, reopensAt: reopensAt)
        case let .clockRollback(lastAdmittedAt, _):
            return .clockRollback(lastAdmittedAt: lastAdmittedAt)
        case .ledgerFull:
            return .ledgerFull
        case .invalidClockRange:
            return .invalidClockRange
        }
    }

    public func availability(
        library: LibraryScope,
        at instant: UTCInstant
    ) -> RollingInvocationAdmissionAvailability {
        if let previous = entries.first(where: { $0.library == library }) {
            guard let reopensAt = previous.lastAdmittedAt.adding(
                milliseconds: Self.windowMilliseconds
            ) else {
                return .invalidClockRange
            }
            guard instant >= previous.lastAdmittedAt else {
                return .clockRollback(
                    lastAdmittedAt: previous.lastAdmittedAt,
                    reopensAt: reopensAt
                )
            }
            guard instant >= reopensAt else {
                return .cooldown(
                    lastAdmittedAt: previous.lastAdmittedAt,
                    reopensAt: reopensAt
                )
            }
            return .available
        }

        return entries.count < maximumLibraries ? .available : .ledgerFull
    }
}
