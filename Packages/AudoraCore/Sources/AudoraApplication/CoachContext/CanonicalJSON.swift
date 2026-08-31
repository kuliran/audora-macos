import Foundation

// Shared by Application context preparation and provider qualification fixtures.

/// The JSON subset used by Audora's provider contracts.
///
/// Numbers in the current contracts are integers. Keeping the value model this
/// small avoids platform-dependent floating-point spelling and makes the exact
/// bytes sent to a provider reproducible on macOS and Linux.
public indirect enum CanonicalJSONValue: Equatable, Sendable {
    case object([String: CanonicalJSONValue])
    case array([CanonicalJSONValue])
    case string(String)
    case integer(Int64)
    case boolean(Bool)
    case null
}

public enum CanonicalJSONMeasurementError: Error, Equatable, Sendable {
    case invalidMaximumByteCount
    case byteLimitExceeded
    case nestingLimitExceeded
    case integerOverflow
}

public enum CanonicalJSON {
    public static let maximumMeasuredNestingDepth = 256

    /// Serializes compact UTF-8 JSON with keys ordered by their UTF-8 bytes.
    ///
    /// String contents are not normalized. Quotes, reverse solidus, and control
    /// scalars are escaped; every other Unicode scalar is emitted as UTF-8.
    public static func serialize(_ value: CanonicalJSONValue) -> Data {
        var bytes: [UInt8] = []
        append(value, to: &bytes)
        return Data(bytes)
    }

    /// Counts the exact canonical bytes without constructing the serialized value.
    /// Measurement stops as soon as the caller's bound is exceeded.
    public static func byteCount(
        of value: CanonicalJSONValue,
        maximumByteCount: Int,
        maximumNestingDepth: Int = maximumMeasuredNestingDepth
    ) throws -> Int {
        guard maximumByteCount >= 0 else {
            throw CanonicalJSONMeasurementError.invalidMaximumByteCount
        }
        guard maximumNestingDepth >= 0 else {
            throw CanonicalJSONMeasurementError.nestingLimitExceeded
        }
        var counter = CanonicalJSONByteCounter(maximum: maximumByteCount)
        try counter.measure(value, depth: 0, maximumDepth: maximumNestingDepth)
        return counter.count
    }

    private static func append(_ value: CanonicalJSONValue, to bytes: inout [UInt8]) {
        switch value {
        case let .object(fields):
            bytes.append(ascii: "{")
            let keys = fields.keys.sorted(by: utf8Precedes)
            for (index, key) in keys.enumerated() {
                if index > 0 {
                    bytes.append(ascii: ",")
                }
                appendJSONString(key, to: &bytes)
                bytes.append(ascii: ":")
                // The key came from this dictionary, so the lookup cannot fail.
                append(fields[key]!, to: &bytes)
            }
            bytes.append(ascii: "}")

        case let .array(values):
            bytes.append(ascii: "[")
            for (index, element) in values.enumerated() {
                if index > 0 {
                    bytes.append(ascii: ",")
                }
                append(element, to: &bytes)
            }
            bytes.append(ascii: "]")

        case let .string(value):
            appendJSONString(value, to: &bytes)

        case let .integer(value):
            bytes.append(contentsOf: String(value).utf8)

        case let .boolean(value):
            bytes.append(contentsOf: value ? "true".utf8 : "false".utf8)

        case .null:
            bytes.append(contentsOf: "null".utf8)
        }
    }

    private static func appendJSONString(_ value: String, to bytes: inout [UInt8]) {
        bytes.append(ascii: "\"")
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08:
                bytes.append(contentsOf: "\\b".utf8)
            case 0x09:
                bytes.append(contentsOf: "\\t".utf8)
            case 0x0A:
                bytes.append(contentsOf: "\\n".utf8)
            case 0x0C:
                bytes.append(contentsOf: "\\f".utf8)
            case 0x0D:
                bytes.append(contentsOf: "\\r".utf8)
            case 0x00 ... 0x1F:
                let hex = String(scalar.value, radix: 16, uppercase: false)
                bytes.append(contentsOf: "\\u".utf8)
                bytes.append(contentsOf: repeatElement(UInt8(ascii: "0"), count: 4 - hex.count))
                bytes.append(contentsOf: hex.utf8)
            case 0x22:
                bytes.append(contentsOf: "\\\"".utf8)
            case 0x5C:
                bytes.append(contentsOf: "\\\\".utf8)
            default:
                bytes.append(contentsOf: String(scalar).utf8)
            }
        }
        bytes.append(ascii: "\"")
    }

    private static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

private struct CanonicalJSONByteCounter {
    let maximum: Int
    private(set) var count = 0

    mutating func measure(
        _ value: CanonicalJSONValue,
        depth: Int,
        maximumDepth: Int
    ) throws {
        guard depth <= maximumDepth else {
            throw CanonicalJSONMeasurementError.nestingLimitExceeded
        }
        switch value {
        case let .object(fields):
            try add(1)
            let keys = fields.keys.sorted(by: utf8Precedes)
            for (index, key) in keys.enumerated() {
                if index > 0 { try add(1) }
                try measureJSONString(key)
                try add(1)
                try measure(fields[key]!, depth: depth + 1, maximumDepth: maximumDepth)
            }
            try add(1)
        case let .array(values):
            try add(1)
            for (index, element) in values.enumerated() {
                if index > 0 { try add(1) }
                try measure(element, depth: depth + 1, maximumDepth: maximumDepth)
            }
            try add(1)
        case let .string(string):
            try measureJSONString(string)
        case let .integer(integer):
            try add(String(integer).utf8.count)
        case let .boolean(boolean):
            try add(boolean ? 4 : 5)
        case .null:
            try add(4)
        }
    }

    private mutating func measureJSONString(_ value: String) throws {
        try add(1)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x22, 0x5C:
                try add(2)
            case 0x00 ... 0x1F:
                try add(6)
            default:
                try add(String(scalar).utf8.count)
            }
        }
        try add(1)
    }

    private mutating func add(_ amount: Int) throws {
        let addition = count.addingReportingOverflow(amount)
        guard !addition.overflow else {
            throw CanonicalJSONMeasurementError.integerOverflow
        }
        guard addition.partialValue <= maximum else {
            throw CanonicalJSONMeasurementError.byteLimitExceeded
        }
        count = addition.partialValue
    }

    private func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

private extension Array where Element == UInt8 {
    mutating func append(ascii character: Character) {
        append(character.asciiValue!)
    }
}
