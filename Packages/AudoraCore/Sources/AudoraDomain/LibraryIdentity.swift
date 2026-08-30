public enum LibraryIdentityError: Error, Equatable, Sendable {
    case invalidLibraryID
    case invalidProfileRevisionID
    case invalidInstant
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

public struct LibraryScope: Hashable, Sendable {
    public let libraryID: LibraryID

    public init(libraryID: LibraryID) {
        self.libraryID = libraryID
    }
}

public struct UTCInstant: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard CalendarValidator.isValidUTCInstant(rawValue) else {
            throw LibraryIdentityError.invalidInstant
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

private enum TypedIdentifierValidator {
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

private enum CalendarValidator {
    static func isValidUTCInstant(_ value: String) -> Bool {
        guard value.utf8.count == 24 else { return false }
        let bytes = Array(value.utf8)
        let separators: [Int: UInt8] = [
            4: 45, 7: 45, 10: 84, 13: 58, 16: 58, 19: 46, 23: 90,
        ]
        for index in 0..<24 {
            if let separator = separators[index] {
                guard bytes[index] == separator else { return false }
            } else {
                guard bytes[index] >= 48, bytes[index] <= 57 else { return false }
            }
        }

        return validDateTime(
            year: number(bytes, 0..<4),
            month: number(bytes, 5..<7),
            day: number(bytes, 8..<10),
            hour: number(bytes, 11..<13),
            minute: number(bytes, 14..<16),
            second: number(bytes, 17..<19)
        )
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
