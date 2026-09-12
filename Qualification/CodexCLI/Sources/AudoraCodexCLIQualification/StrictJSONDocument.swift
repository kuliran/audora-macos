import Foundation

enum StrictJSONDocument {
    static func hasUniqueObjectKeys(_ data: Data) -> Bool {
        guard String(data: data, encoding: .utf8) != nil else { return false }

        var parser = StrictJSONParser(bytes: [UInt8](data))
        return parser.parseDocument()
    }
}

private struct StrictJSONParser {
    private let maximumDepth = 64
    let bytes: [UInt8]
    var index = 0

    mutating func parseDocument() -> Bool {
        skipWhitespace()
        guard parseValue(depth: 0) else { return false }
        skipWhitespace()
        return index == bytes.count
    }

    private mutating func parseValue(depth: Int) -> Bool {
        guard depth <= maximumDepth, index < bytes.count else { return false }

        switch bytes[index] {
        case 0x7b:
            return parseObject(depth: depth)
        case 0x5b:
            return parseArray(depth: depth)
        case 0x22:
            return parseString() != nil
        case 0x74:
            return consume("true")
        case 0x66:
            return consume("false")
        case 0x6e:
            return consume("null")
        case 0x2d, 0x30 ... 0x39:
            return parseNumber()
        default:
            return false
        }
    }

    private mutating func parseObject(depth: Int) -> Bool {
        index += 1
        skipWhitespace()
        if consumeByte(0x7d) { return true }

        var keys = Set<String>()
        while true {
            guard let key = parseString(), keys.insert(key).inserted else {
                return false
            }
            skipWhitespace()
            guard consumeByte(0x3a) else { return false }
            skipWhitespace()
            guard parseValue(depth: depth + 1) else { return false }
            skipWhitespace()
            if consumeByte(0x7d) { return true }
            guard consumeByte(0x2c) else { return false }
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) -> Bool {
        index += 1
        skipWhitespace()
        if consumeByte(0x5d) { return true }

        while true {
            guard parseValue(depth: depth + 1) else { return false }
            skipWhitespace()
            if consumeByte(0x5d) { return true }
            guard consumeByte(0x2c) else { return false }
            skipWhitespace()
        }
    }

    private mutating func parseString() -> String? {
        guard index < bytes.count, bytes[index] == 0x22 else { return nil }

        let start = index
        index += 1
        while index < bytes.count {
            switch bytes[index] {
            case 0x22:
                index += 1
                let encoded = Data(bytes[start ..< index])
                guard
                    let decoded = try? JSONSerialization.jsonObject(
                        with: encoded,
                        options: [.fragmentsAllowed]
                    ) as? String
                else {
                    return nil
                }
                return decoded
            case 0x5c:
                index += 1
                guard index < bytes.count else { return nil }
                switch bytes[index] {
                case 0x22, 0x2f, 0x5c, 0x62, 0x66, 0x6e, 0x72, 0x74:
                    index += 1
                case 0x75:
                    guard index + 4 < bytes.count else { return nil }
                    for offset in 1 ... 4 where !isHexDigit(bytes[index + offset]) {
                        return nil
                    }
                    index += 5
                default:
                    return nil
                }
            case 0x00 ... 0x1f:
                return nil
            default:
                index += 1
            }
        }
        return nil
    }

    private mutating func parseNumber() -> Bool {
        _ = consumeByte(0x2d)
        guard index < bytes.count else { return false }

        if consumeByte(0x30) {
            if index < bytes.count, isDigit(bytes[index]) {
                return false
            }
        } else {
            guard index < bytes.count, (0x31 ... 0x39).contains(bytes[index]) else {
                return false
            }
            repeat { index += 1 } while index < bytes.count && isDigit(bytes[index])
        }

        if consumeByte(0x2e) {
            guard index < bytes.count, isDigit(bytes[index]) else { return false }
            repeat { index += 1 } while index < bytes.count && isDigit(bytes[index])
        }

        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            if index < bytes.count, bytes[index] == 0x2b || bytes[index] == 0x2d {
                index += 1
            }
            guard index < bytes.count, isDigit(bytes[index]) else { return false }
            repeat { index += 1 } while index < bytes.count && isDigit(bytes[index])
        }
        return true
    }

    private mutating func consume(_ literal: StaticString) -> Bool {
        let literalBytes = literal.withUTF8Buffer { Array($0) }
        guard index + literalBytes.count <= bytes.count else { return false }
        guard bytes[index ..< index + literalBytes.count].elementsEqual(literalBytes) else {
            return false
        }
        index += literalBytes.count
        return true
    }

    private mutating func consumeByte(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0a, 0x0d:
                index += 1
            default:
                return
            }
        }
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
    }

    private func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte)
            || (0x41 ... 0x46).contains(byte)
            || (0x61 ... 0x66).contains(byte)
    }
}
