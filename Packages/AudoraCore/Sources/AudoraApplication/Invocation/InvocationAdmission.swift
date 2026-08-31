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
        guard let now = InvocationWallClock(instant) else {
            return .invalidClockRange
        }
        if let index = entries.firstIndex(where: { $0.library == library }) {
            let previous = entries[index]
            guard let admitted = InvocationWallClock(previous.lastAdmittedAt) else {
                return .invalidClockRange
            }
            guard now.milliseconds >= admitted.milliseconds else {
                return .clockRollback(lastAdmittedAt: previous.lastAdmittedAt)
            }
            let (reopeningMilliseconds, overflow) = admitted.milliseconds
                .addingReportingOverflow(Self.windowMilliseconds)
            guard !overflow,
                  let reopensAt = InvocationWallClock(
                      milliseconds: reopeningMilliseconds
                  )?.instant
            else {
                return .invalidClockRange
            }
            guard now.milliseconds >= reopeningMilliseconds else {
                return .cooldown(
                    lastAdmittedAt: previous.lastAdmittedAt,
                    reopensAt: reopensAt
                )
            }
            entries[index] = RollingInvocationAdmissionEntry(
                library: library,
                lastAdmittedAt: instant
            )
            return .admitted
        }

        guard entries.count < maximumLibraries else { return .ledgerFull }
        entries.append(
            RollingInvocationAdmissionEntry(
                library: library,
                lastAdmittedAt: instant
            )
        )
        entries.sort { $0.library.libraryID.rawValue < $1.library.libraryID.rawValue }
        return .admitted
    }
}

private struct InvocationWallClock {
    let milliseconds: Int64
    let instant: UTCInstant

    init?(_ instant: UTCInstant) {
        let bytes = Array(instant.rawValue.utf8)
        guard bytes.count == 24 else { return nil }
        let year = Self.number(bytes, 0..<4)
        let month = Self.number(bytes, 5..<7)
        let day = Self.number(bytes, 8..<10)
        let hour = Self.number(bytes, 11..<13)
        let minute = Self.number(bytes, 14..<16)
        let second = Self.number(bytes, 17..<19)
        let millisecond = Self.number(bytes, 20..<23)
        let days = Self.daysFromCivil(year: year, month: month, day: day)
        milliseconds = (((days * 24 + Int64(hour)) * 60 + Int64(minute)) * 60 +
            Int64(second)) * 1_000 + Int64(millisecond)
        self.instant = instant
    }

    init?(milliseconds: Int64) {
        let (seconds, millisecond) = Self.floorDivision(milliseconds, by: 1_000)
        let (minutes, second) = Self.floorDivision(seconds, by: 60)
        let (hours, minute) = Self.floorDivision(minutes, by: 60)
        let (days, hour) = Self.floorDivision(hours, by: 24)
        let civil = Self.civilFromDays(days)
        guard (1...9_999).contains(civil.year) else { return nil }
        let raw = "\(Self.padded(civil.year, width: 4))-" +
            "\(Self.padded(civil.month, width: 2))-" +
            "\(Self.padded(civil.day, width: 2))T" +
            "\(Self.padded(Int(hour), width: 2)):" +
            "\(Self.padded(Int(minute), width: 2)):" +
            "\(Self.padded(Int(second), width: 2))." +
            "\(Self.padded(Int(millisecond), width: 3))Z"
        guard let instant = try? UTCInstant(raw) else { return nil }
        self.milliseconds = milliseconds
        self.instant = instant
    }

    private static func number(_ bytes: [UInt8], _ range: Range<Int>) -> Int {
        range.reduce(0) { partial, index in
            partial * 10 + Int(bytes[index] - 48)
        }
    }

    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int64 {
        var adjustedYear = year
        if month <= 2 { adjustedYear -= 1 }
        let era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let adjustedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return Int64(era * 146_097 + dayOfEra - 719_468)
    }

    private static func civilFromDays(_ input: Int64) -> (year: Int, month: Int, day: Int) {
        let adjusted = input + 719_468
        let era = adjusted >= 0 ? adjusted / 146_097 : (adjusted - 146_096) / 146_097
        let dayOfEra = adjusted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 -
            dayOfEra / 146_096) / 365
        var year = Int(yearOfEra + era * 400)
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = Int(dayOfYear - (153 * monthPrime + 2) / 5 + 1)
        let month = Int(monthPrime + (monthPrime < 10 ? 3 : -9))
        if month <= 2 { year += 1 }
        return (year, month, day)
    }

    private static func floorDivision(
        _ dividend: Int64,
        by divisor: Int64
    ) -> (quotient: Int64, remainder: Int64) {
        var quotient = dividend / divisor
        var remainder = dividend % divisor
        if remainder < 0 {
            quotient -= 1
            remainder += divisor
        }
        return (quotient, remainder)
    }

    private static func padded(_ value: Int, width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}
