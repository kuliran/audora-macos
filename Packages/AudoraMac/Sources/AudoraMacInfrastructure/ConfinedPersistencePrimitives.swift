import Darwin
import Foundation

enum ConfinedAtomicReplaceOutcome: Equatable, Sendable {
    case committed
    case commitUncertain
}

/// The descriptor boundary used by confined atomic replacement. Production
/// defaults are POSIX operations; tests can inject one failing boundary without
/// reimplementing the persistence transaction.
struct ConfinedPersistenceDescriptorOperations: Sendable {
    let write: @Sendable (Int32, UnsafeRawPointer, Int) -> Int
    let close: @Sendable (Int32) -> Int32
    let synchronizeDirectory: @Sendable (Int32) -> Bool

    init(
        write: @escaping @Sendable (Int32, UnsafeRawPointer, Int) -> Int = {
            Darwin.write($0, $1, $2)
        },
        close: @escaping @Sendable (Int32) -> Int32 = { Darwin.close($0) },
        synchronizeDirectory: @escaping @Sendable (Int32) -> Bool = { descriptor in
            while Darwin.fsync(descriptor) != 0 {
                if errno == EINTR { continue }
                return false
            }
            return true
        }
    ) {
        self.write = write
        self.close = close
        self.synchronizeDirectory = synchronizeDirectory
    }
}

/// Descriptor-relative mechanics shared by confined aggregate persistence.
/// Callers retain ownership of layout rules and translate failures through the
/// concrete error values supplied at construction.
struct ConfinedPersistencePrimitives<Failure: Error> {
    let ioFailure: Failure
    let invalidLayout: Failure
    let expectedPathIsSymlink: Failure
    let rootTooLarge: Failure
    let invalidJSON: Failure
    let invalidSchemaVersion: Failure
    let unknownKey: Failure
    private let descriptorOperations: ConfinedPersistenceDescriptorOperations

    init(
        ioFailure: Failure,
        invalidLayout: Failure,
        expectedPathIsSymlink: Failure,
        rootTooLarge: Failure,
        invalidJSON: Failure,
        invalidSchemaVersion: Failure,
        unknownKey: Failure,
        descriptorOperations: ConfinedPersistenceDescriptorOperations = .init()
    ) {
        self.ioFailure = ioFailure
        self.invalidLayout = invalidLayout
        self.expectedPathIsSymlink = expectedPathIsSymlink
        self.rootTooLarge = rootTooLarge
        self.invalidJSON = invalidJSON
        self.invalidSchemaVersion = invalidSchemaVersion
        self.unknownKey = unknownKey
        self.descriptorOperations = descriptorOperations
    }

    func writeExclusive(
        _ data: Data,
        named name: String,
        under parent: Int32,
        flushBeforeClose: Bool
    ) throws {
        let descriptor = name.withCString { pointer -> Int32 in
            while true {
                let result = Darwin.openat(
                    parent,
                    pointer,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    0o600
                )
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        guard descriptor >= 0 else { throw ioFailure }
        var closeRequired = true
        defer { if closeRequired { _ = descriptorOperations.close(descriptor) } }
        let success = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < buffer.count {
                let count = descriptorOperations.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if count == 0 { return false }
                offset += count
            }
            return true
        }
        guard success else { throw ioFailure }
        if flushBeforeClose { try flush(descriptor) }
        guard descriptorOperations.close(descriptor) == 0 else {
            closeRequired = false
            throw ioFailure
        }
        closeRequired = false
    }

    /// Durably writes a sibling partial, closes it, atomically replaces the
    /// destination, and then reports whether the parent-directory switch was
    /// proven durable. A failure before the rename removes the partial and is
    /// never reported as a possible commit.
    func replaceAtomically(
        _ data: Data,
        named destinationName: String,
        via partialName: String,
        under parent: Int32
    ) throws -> ConfinedAtomicReplaceOutcome {
        guard destinationName != partialName else { throw invalidLayout }
        try removeReplacePartialIfPresent(named: partialName, under: parent)
        var ownsPartial = true
        defer {
            if ownsPartial { _ = unlinkat(parent, partialName, 0) }
        }

        try writeExclusive(
            data,
            named: partialName,
            under: parent,
            flushBeforeClose: true
        )
        let renameStatus = partialName.withCString { source in
            destinationName.withCString { destination in
                Darwin.renameat(parent, source, parent, destination)
            }
        }
        guard renameStatus == 0 else { throw ioFailure }
        ownsPartial = false
        return descriptorOperations.synchronizeDirectory(parent)
            ? .committed
            : .commitUncertain
    }

    private func removeReplacePartialIfPresent(
        named name: String,
        under parent: Int32
    ) throws {
        var metadata = stat()
        let status = name.withCString {
            Darwin.fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if status == 0 {
            guard (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_nlink == 1
            else { throw invalidLayout }
            guard unlinkat(parent, name, 0) == 0 else { throw ioFailure }
        } else if errno != ENOENT {
            throw ioFailure
        }
    }

    func renameNoReplace(
        from source: String,
        under sourceParent: Int32,
        to destination: String,
        under destinationParent: Int32,
        collision: Failure
    ) throws {
        let result = source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                renameatx_np(
                    sourceParent,
                    sourcePointer,
                    destinationParent,
                    destinationPointer,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw collision }
            throw ioFailure
        }
    }

    func boundedData(
        named name: String,
        under parent: Int32,
        maximumBytes: Int,
        requireSingleLink: Bool = false
    ) throws -> Data {
        let descriptor = name.withCString { pointer -> Int32 in
            while true {
                let result = Darwin.openat(
                    parent,
                    pointer,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        guard descriptor >= 0 else {
            if isSymlink(named: name, under: parent) { throw expectedPathIsSymlink }
            throw invalidLayout
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              !requireSingleLink || metadata.st_nlink == 1,
              maximumBytes >= 0,
              metadata.st_size >= 0,
              UInt64(metadata.st_size) <= UInt64(maximumBytes),
              UInt64(metadata.st_size) < UInt64(Int.max)
        else {
            if maximumBytes >= 0,
               metadata.st_size >= 0,
               UInt64(metadata.st_size) > UInt64(maximumBytes)
            {
                throw rootTooLarge
            }
            throw invalidLayout
        }
        // Allocate from the trusted regular-file size, not from the policy ceiling.
        // The extra byte detects growth between `fstat` and `read` without making a
        // tiny file pay the cost of a potentially large aggregate limit.
        var data = Data(count: Int(metadata.st_size) + 1)
        let count = data.withUnsafeMutableBytes { buffer -> Int in
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
        guard count >= 0 else { throw ioFailure }
        data.removeSubrange(count ..< data.count)
        guard data.count <= maximumBytes else { throw rootTooLarge }
        guard data.count == Int(metadata.st_size) else { throw invalidLayout }
        return data
    }

    func openDirectory(named name: String, under parent: Int32) throws -> Int32 {
        let descriptor = name.withCString { pointer -> Int32 in
            while true {
                let result = Darwin.openat(
                    parent,
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        guard descriptor >= 0 else {
            if isSymlink(named: name, under: parent) { throw expectedPathIsSymlink }
            throw invalidLayout
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR
        else {
            Darwin.close(descriptor)
            throw invalidLayout
        }
        return descriptor
    }

    func openRegularFile(named name: String, under parent: Int32) throws -> Int32 {
        let descriptor = name.withCString { pointer -> Int32 in
            while true {
                let result = Darwin.openat(
                    parent,
                    pointer,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        guard descriptor >= 0 else { throw ioFailure }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG
        else {
            Darwin.close(descriptor)
            throw invalidLayout
        }
        return descriptor
    }

    func flush(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw ioFailure
        }
    }

    func entryExists(named name: String, under parent: Int32) throws -> Bool {
        var metadata = stat()
        let result = name.withCString {
            Darwin.fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return true }
        if errno == ENOENT { return false }
        throw ioFailure
    }

    func isSymlink(named name: String, under parent: Int32) -> Bool {
        var metadata = stat()
        let result = name.withCString {
            Darwin.fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        return result == 0 && (metadata.st_mode & S_IFMT) == S_IFLNK
    }

    func listEntryNames(
        under descriptor: Int32,
        maximumCount: Int? = nil
    ) throws -> [String] {
        // `dup` would share the directory stream offset with the authority FD,
        // making a second integrity check observe an empty suffix. Reopen `.`
        // relative to the pinned directory so each enumeration is independent.
        let enumerationDescriptor = Darwin.openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard enumerationDescriptor >= 0 else { throw ioFailure }
        guard let directory = fdopendir(enumerationDescriptor) else {
            Darwin.close(enumerationDescriptor)
            throw ioFailure
        }
        defer { closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                names.append(name)
                if let maximumCount, names.count > maximumCount { throw rootTooLarge }
            }
            errno = 0
        }
        guard errno == 0 else { throw ioFailure }
        return names.sorted()
    }

    func schemaVersion(in data: Data) throws -> UInt64 {
        _ = try jsonDictionary(data)
        do {
            return try JSONDecoder().decode(
                ConfinedSchemaVersionEnvelope.self,
                from: data
            ).schemaVersion
        } catch {
            throw invalidSchemaVersion
        }
    }

    func jsonDictionary(_ data: Data) throws -> [String: Any] {
        do {
            guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw invalidJSON
            }
            return dictionary
        } catch {
            throw invalidJSON
        }
    }

    func requireExactKeys(_ dictionary: [String: Any], _ expected: Set<String>) throws {
        guard Set(dictionary.keys) == expected else { throw unknownKey }
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw invalidJSON
        }
    }

    func deterministicJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}

private struct ConfinedSchemaVersionEnvelope: Decodable {
    let schemaVersion: UInt64
}
