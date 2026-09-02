public enum LibraryIdentityError: Error, Equatable, Sendable {
    case invalidLibraryID
    case invalidSessionID
    case invalidProfileRevisionID
    case invalidRecordingID
    case invalidTranscriptRevisionID
    case invalidTranscriptionJobID
    case invalidInstant
}

public struct TranscriptionJobID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard TypedIdentifierValidator.isValid(rawValue, prefix: "job-") else {
            throw LibraryIdentityError.invalidTranscriptionJobID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct LibraryID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard TypedIdentifierValidator.isValid(rawValue, prefix: "lib-") else {
            throw LibraryIdentityError.invalidLibraryID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ProfileRevisionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard TypedIdentifierValidator.isValid(rawValue, prefix: "prf-") else {
            throw LibraryIdentityError.invalidProfileRevisionID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct RecordingID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard TypedIdentifierValidator.isValid(rawValue, prefix: "rec-") else {
            throw LibraryIdentityError.invalidRecordingID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct SessionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard TypedIdentifierValidator.isValid(rawValue, prefix: "ses-") else {
            throw LibraryIdentityError.invalidSessionID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct TranscriptRevisionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard TypedIdentifierValidator.isValid(rawValue, prefix: "trv-") else {
            throw LibraryIdentityError.invalidTranscriptRevisionID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct LibraryScope: Hashable, Sendable {
    public let libraryID: LibraryID

    public init(libraryID: LibraryID) {
        self.libraryID = libraryID
    }
}

public struct UTCInstant: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard CalendarValidator.utcInstantComponents(rawValue) != nil else {
            throw LibraryIdentityError.invalidInstant
        }
        self.rawValue = rawValue
    }

    /// Returns the exact UTC instant after applying a millisecond offset, or
    /// `nil` when the arithmetic would leave the canonical year range.
    public func adding(milliseconds: Int64) -> UTCInstant? {
        UTCInstantArithmetic.adding(milliseconds, to: self)
    }

    /// Canonical instants are fixed-width and ordered from year through
    /// millisecond, so their lexical and chronological orders are identical.
    public static func < (lhs: UTCInstant, rhs: UTCInstant) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { rawValue }
}

private enum UTCInstantArithmetic {
    static func adding(_ offset: Int64, to instant: UTCInstant) -> UTCInstant? {
        guard let current = milliseconds(in: instant) else { return nil }
        let (milliseconds, overflow) = current.addingReportingOverflow(offset)
        guard !overflow else { return nil }
        return makeInstant(milliseconds: milliseconds)
    }

    private static func milliseconds(in instant: UTCInstant) -> Int64? {
        guard let components = CalendarValidator.utcInstantComponents(instant.rawValue) else {
            return nil
        }
        let days = daysFromCivil(
            year: components.year,
            month: components.month,
            day: components.day
        )
        return (((days * 24 + Int64(components.hour)) * 60 +
            Int64(components.minute)) * 60 + Int64(components.second)) * 1_000 +
            Int64(components.millisecond)
    }

    private static func makeInstant(milliseconds: Int64) -> UTCInstant? {
        let (seconds, millisecond) = floorDivision(milliseconds, by: 1_000)
        let (minutes, second) = floorDivision(seconds, by: 60)
        let (hours, minute) = floorDivision(minutes, by: 60)
        let (days, hour) = floorDivision(hours, by: 24)
        let civil = civilFromDays(days)
        guard (1...9_999).contains(civil.year) else { return nil }
        let raw = "\(padded(civil.year, width: 4))-" +
            "\(padded(civil.month, width: 2))-" +
            "\(padded(civil.day, width: 2))T" +
            "\(padded(Int(hour), width: 2)):" +
            "\(padded(Int(minute), width: 2)):" +
            "\(padded(Int(second), width: 2))." +
            "\(padded(Int(millisecond), width: 3))Z"
        return try? UTCInstant(raw)
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

private struct UTCInstantComponents {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    let second: Int
    let millisecond: Int
}

enum TypedIdentifierValidator {
    private static let crockford = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func isValid(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix), value.utf8.count == prefix.utf8.count + 24 else {
            return false
        }

        let tail = String(value.dropFirst(prefix.count))
        guard tail.utf8.count == 24 else { return false }
        let bytes = Array(tail.utf8)
        guard bytes[8] == Character("T").asciiValue,
              bytes[18] == Character("Z").asciiValue,
              bytes[19] == Character("-").asciiValue
        else {
            return false
        }

        for index in 0..<19 where index != 8 && index != 18 {
            guard bytes[index] >= 48, bytes[index] <= 57 else { return false }
        }
        guard bytes[20..<24].allSatisfy({ crockford.contains(Character(UnicodeScalar($0))) }) else {
            return false
        }

        return CalendarValidator.isValidCompactTimestamp(String(tail.prefix(19)))
    }
}

enum CalendarValidator {
    fileprivate static func utcInstantComponents(
        _ value: String
    ) -> UTCInstantComponents? {
        guard value.utf8.count == 24 else { return nil }
        let bytes = Array(value.utf8)
        let separators: [Int: UInt8] = [
            4: 45, 7: 45, 10: 84, 13: 58, 16: 58, 19: 46, 23: 90,
        ]
        for index in 0..<24 {
            if let separator = separators[index] {
                guard bytes[index] == separator else { return nil }
            } else {
                guard bytes[index] >= 48, bytes[index] <= 57 else { return nil }
            }
        }
        let components = UTCInstantComponents(
            year: number(bytes, 0..<4),
            month: number(bytes, 5..<7),
            day: number(bytes, 8..<10),
            hour: number(bytes, 11..<13),
            minute: number(bytes, 14..<16),
            second: number(bytes, 17..<19),
            millisecond: number(bytes, 20..<23)
        )
        guard validDateTime(
            year: components.year,
            month: components.month,
            day: components.day,
            hour: components.hour,
            minute: components.minute,
            second: components.second
        ) else { return nil }
        return components
    }

    static func isValidCompactTimestamp(_ value: String) -> Bool {
        guard value.utf8.count == 19 else { return false }
        let bytes = Array(value.utf8)
        guard bytes[8] == 84, bytes[18] == 90 else { return false }
        return validDateTime(
            year: number(bytes, 0..<4),
            month: number(bytes, 4..<6),
            day: number(bytes, 6..<8),
            hour: number(bytes, 9..<11),
            minute: number(bytes, 11..<13),
            second: number(bytes, 13..<15)
        ) && bytes[15..<18].allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func number(_ bytes: [UInt8], _ range: Range<Int>) -> Int {
        range.reduce(0) { partial, index in
            partial * 10 + Int(bytes[index] - 48)
        }
    }

    private static func validDateTime(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int
    ) -> Bool {
        guard year >= 1,
              (1...12).contains(month),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second)
        else {
            return false
        }
        let days = [
            31,
            isLeapYear(year) ? 29 : 28,
            31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
        ]
        return (1...days[month - 1]).contains(day)
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
    }
}
