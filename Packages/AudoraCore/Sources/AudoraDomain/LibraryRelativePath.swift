public enum LibraryRelativePathError: Error, Equatable, Sendable {
    case empty
    case absolute
    case invalidComponent
    case invalidCharacter
}

public struct LibraryRelativePath: Hashable, Sendable, CustomStringConvertible {
    public let components: [String]

    public init(_ serialized: String) throws {
        guard !serialized.isEmpty else { throw LibraryRelativePathError.empty }
        guard !serialized.hasPrefix("/"), !serialized.hasPrefix("~") else {
            throw LibraryRelativePathError.absolute
        }
        guard !serialized.contains("\\"),
              !serialized.unicodeScalars.contains(where: { $0.value == 0 }),
              !Self.hasDrivePrefix(serialized),
              !Self.hasURIScheme(serialized)
        else {
            throw LibraryRelativePathError.invalidCharacter
        }

        let components = serialized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LibraryRelativePathError.invalidComponent
        }
        self.components = components
    }

    public var description: String { components.joined(separator: "/") }

    private static func hasDrivePrefix(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= 2 else { return false }
        let first = bytes[0]
        return ((65...90).contains(first) || (97...122).contains(first)) && bytes[1] == 58
    }

    private static func hasURIScheme(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":") else { return false }
        let prefix = value[..<colon]
        guard let first = prefix.utf8.first,
              (65...90).contains(first) || (97...122).contains(first)
        else {
            return false
        }
        return prefix.utf8.dropFirst().allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) ||
                (48...57).contains($0) || $0 == 43 || $0 == 45 || $0 == 46
        }
    }
}
