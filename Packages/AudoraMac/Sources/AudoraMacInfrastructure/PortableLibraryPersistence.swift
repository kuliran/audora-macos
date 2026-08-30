import AudoraApplication
import AudoraDomain
import Darwin
import Foundation

public enum PortableLibraryFaultPoint: Hashable, Sendable {
    case stagingDirectoryCreated
    case afterRootDescriptorOpened
    case beforeRootRead(String)
    case beforeRootPartialWrite(String)
    case afterRootPartialWrite(String)
    case afterRootFileFlush(String)
    case afterRootInstall(String)
    case afterDirectoryFlush(String)
    case beforeStagedValidation
    case beforeFinalInstall
    case afterFinalInstall
    case afterParentFlush
    case beforeMutableRootInstall(String)
    case afterMutableRootInstall(String)
}

public enum PortableLibraryPersistenceError: Error, Equatable, Sendable {
    case destinationExists
    case invalidPackage
    case invalidLayout
    case expectedPathIsSymlink
    case rootTooLarge
    case invalidJSON
    case invalidSchemaVersion
    case unsupportedOlderSchema
    case unknownKey
    case invalidManifest
    case invalidPreferences
    case invalidProfileHead
    case installedLibraryMismatch
    case readOnlyLibrary
    case unsupportedMutableRoot
    case ioFailure
    case injectedFault(PortableLibraryFaultPoint)
}

public enum LoadedPortableLibrary: Equatable, Sendable {
    case readWrite(PortableLibraryAuthority)
    case readOnly(libraryID: LibraryID?)
}

public struct PortableLibraryAuthority: Equatable, Sendable {
    public let manifest: LibraryManifest
    public let preferences: LibraryPreferences
    public let profileHead: ProfileHead

    public init(
        manifest: LibraryManifest,
        preferences: LibraryPreferences,
        profileHead: ProfileHead
    ) {
        self.manifest = manifest
        self.preferences = preferences
        self.profileHead = profileHead
    }

    public var snapshot: ActiveLibrarySnapshot {
        let profile: ActiveLibrarySnapshot.ProfileSummary
        switch profileHead.selection {
        case .null:
            profile = .nullProfile(statementCount: 0)
        case let .revision(pointer):
            profile = .selected(
                revisionID: pointer.revisionID,
                statementGeneration: profileHead.statementGeneration
            )
        }
        return ActiveLibrarySnapshot(
            libraryID: manifest.libraryID,
            preferences: preferences,
            profile: profile
        )
    }
}

public struct PortableLibraryPersistence: @unchecked Sendable {
    public static let maximumRootBytes = 65_536

    private let fault: @Sendable (PortableLibraryFaultPoint) throws -> Void

    public init(
        fault: @escaping @Sendable (PortableLibraryFaultPoint) throws -> Void = { _ in }
    ) {
        self.fault = fault
    }

    public func create(
        at destination: URL,
        seed: NewLibrarySeed
    ) throws -> PortableLibraryAuthority {
        guard destination.pathExtension == "audoralibrary" else {
            throw PortableLibraryPersistenceError.invalidPackage
        }

        let parent = destination.deletingLastPathComponent()
        let parentDescriptor = try openDirectoryDescriptor(at: parent)
        defer { Darwin.close(parentDescriptor) }
        let destinationName = destination.lastPathComponent
        guard try !entryExists(named: destinationName, under: parentDescriptor) else {
            throw PortableLibraryPersistenceError.destinationExists
        }
        let stagingName = ".audora-create-\(UUID().uuidString).partial"
        var stagingCreated = false
        var finalInstalled = false
        defer {
            if stagingCreated, !finalInstalled {
                removeOwnedStaging(named: stagingName, under: parentDescriptor)
            }
        }

        do {
            guard mkdirat(parentDescriptor, stagingName, 0o700) == 0 else {
                throw PortableLibraryPersistenceError.ioFailure
            }
            stagingCreated = true
            let stagingDescriptor = try openDirectoryDescriptor(
                components: [stagingName],
                under: parentDescriptor
            )
            defer { Darwin.close(stagingDescriptor) }
            try fault(.stagingDirectoryCreated)
            try createInitialLayout(under: stagingDescriptor)

            let manifest = LibraryManifest(
                libraryID: seed.libraryID,
                createdAt: seed.createdAt
            )
            try writeRoot(
                encodeManifest(manifest),
                relativePath: "library.json",
                under: stagingDescriptor
            )
            try writeRoot(
                encodePreferences(seed.preferences),
                relativePath: "preferences.json",
                under: stagingDescriptor
            )
            try writeRoot(
                encodeProfileHead(seed.profileHead),
                relativePath: "profile/head.json",
                under: stagingDescriptor
            )

            try flushOwnedDirectories(under: stagingDescriptor)
            try fault(.beforeStagedValidation)
            let staged = try load(from: stagingDescriptor)
            guard case let .readWrite(authority) = staged,
                  authority.manifest.libraryID == seed.libraryID,
                  authority.preferences == seed.preferences,
                  authority.profileHead == seed.profileHead
            else {
                throw PortableLibraryPersistenceError.installedLibraryMismatch
            }

            try fault(.beforeFinalInstall)
            try noReplaceRename(
                from: stagingName,
                to: destinationName,
                under: parentDescriptor
            )
            finalInstalled = true
            try fault(.afterFinalInstall)
            try flushDescriptor(parentDescriptor)
            try fault(.afterParentFlush)

            let installed = try open(at: destination)
            guard case let .readWrite(authority) = installed,
                  authority == stagedAuthority(staged)
            else {
                throw PortableLibraryPersistenceError.installedLibraryMismatch
            }
            return authority
        } catch let error as PortableLibraryPersistenceError {
            throw error
        } catch {
            throw PortableLibraryPersistenceError.ioFailure
        }
    }

    public func open(
        at root: URL,
        requirePackageExtension: Bool = true
    ) throws -> LoadedPortableLibrary {
        do {
            if requirePackageExtension, root.pathExtension != "audoralibrary" {
                throw PortableLibraryPersistenceError.invalidPackage
            }
            let rootDescriptor = try openDirectoryDescriptor(at: root)
            defer { Darwin.close(rootDescriptor) }
            try fault(.afterRootDescriptorOpened)
            return try load(from: rootDescriptor)
        } catch let error as PortableLibraryPersistenceError {
            throw error
        } catch {
            throw PortableLibraryPersistenceError.ioFailure
        }
    }

    public func atomicallyReplaceRoot(
        _ data: Data,
        relativePath: LibraryRelativePath,
        under root: URL
    ) throws {
        let relative = relativePath.description
        guard relative == "preferences.json" || relative == "profile/head.json" else {
            throw PortableLibraryPersistenceError.unsupportedMutableRoot
        }
        if relative == "preferences.json" {
            _ = try decodePreferences(data)
        } else {
            _ = try decodeProfileHead(data)
        }

        let rootDescriptor = try openDirectoryDescriptor(at: root)
        defer { Darwin.close(rootDescriptor) }
        guard case .readWrite = try load(from: rootDescriptor) else {
            throw PortableLibraryPersistenceError.readOnlyLibrary
        }

        let parentComponents = Array(relativePath.components.dropLast())
        let parentDescriptor = try openDirectoryDescriptor(
            components: parentComponents,
            under: rootDescriptor
        )
        defer { Darwin.close(parentDescriptor) }
        let targetName = relativePath.components.last!
        let partialName = ".\(targetName).\(UUID().uuidString).partial"
        do {
            try writeExclusive(data, named: partialName, under: parentDescriptor)
            try fault(.beforeMutableRootInstall(relative))
            guard renameat(parentDescriptor, partialName, parentDescriptor, targetName) == 0 else {
                throw PortableLibraryPersistenceError.ioFailure
            }
            try fault(.afterMutableRootInstall(relative))
            try flushDescriptor(parentDescriptor)
        } catch let error as PortableLibraryPersistenceError {
            _ = unlinkat(parentDescriptor, partialName, 0)
            throw error
        } catch {
            _ = unlinkat(parentDescriptor, partialName, 0)
            throw PortableLibraryPersistenceError.ioFailure
        }
    }

    public func resolve(
        _ relativePath: LibraryRelativePath,
        under root: URL
    ) throws -> URL {
        let rootDescriptor = try openDirectoryDescriptor(at: root)
        defer { Darwin.close(rootDescriptor) }
        let parent = try openDirectoryDescriptor(
            components: Array(relativePath.components.dropLast()),
            under: rootDescriptor
        )
        defer { Darwin.close(parent) }
        if let final = relativePath.components.last {
            try rejectSymlinkIfPresent(named: final, under: parent)
        }
        var current = root
        for component in relativePath.components {
            current.appendPathComponent(component, isDirectory: false)
        }
        let rootPath = root.standardizedFileURL.path
        let candidatePath = current.standardizedFileURL.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw PortableLibraryPersistenceError.invalidLayout
        }
        return current
    }

    public func encodeManifest(_ manifest: LibraryManifest) throws -> Data {
        try deterministicJSON(
            LibraryManifestDTO(
                schemaVersion: 1,
                formatName: LibraryManifest.formatName,
                libraryId: manifest.libraryID.rawValue,
                createdAt: manifest.createdAt.rawValue,
                lastSuccessfulMigration: manifest.lastSuccessfulMigration
            )
        )
    }

    public func encodePreferences(_ preferences: LibraryPreferences) throws -> Data {
        try deterministicJSON(
            LibraryPreferencesDTO(
                schemaVersion: 1,
                language: preferences.language.rawValue,
                annotationsVisible: preferences.annotationsVisible,
                playbackRate: preferences.playbackRate
            )
        )
    }

    public func encodeProfileHead(_ head: ProfileHead) throws -> Data {
        let revisionID: String?
        let sha256: String?
        switch head.selection {
        case .null:
            revisionID = nil
            sha256 = nil
        case let .revision(pointer):
            revisionID = pointer.revisionID.rawValue
            sha256 = pointer.sha256
        }
        return try deterministicJSON(
            ProfileHeadDTO(
                schemaVersion: 1,
                generation: head.generation,
                statementGeneration: head.statementGeneration,
                updatedAt: head.updatedAt.rawValue,
                currentRevisionId: revisionID,
                currentRevisionSha256: sha256
            )
        )
    }

    private func stagedAuthority(_ loaded: LoadedPortableLibrary) -> PortableLibraryAuthority? {
        guard case let .readWrite(authority) = loaded else { return nil }
        return authority
    }

    private func load(from rootDescriptor: Int32) throws -> LoadedPortableLibrary {
        try validateExpectedLayout(under: rootDescriptor)

        let manifestData = try boundedRootData(
            at: try LibraryRelativePath("library.json"),
            under: rootDescriptor
        )
        let preferencesData = try boundedRootData(
            at: try LibraryRelativePath("preferences.json"),
            under: rootDescriptor
        )
        let profileHeadData = try boundedRootData(
            at: try LibraryRelativePath("profile/head.json"),
            under: rootDescriptor
        )

        let manifestVersion = try schemaVersion(in: manifestData)
        let preferencesVersion = try schemaVersion(in: preferencesData)
        let profileVersion = try schemaVersion(in: profileHeadData)

        guard manifestVersion >= 1,
              preferencesVersion >= 1,
              profileVersion >= 1
        else {
            throw PortableLibraryPersistenceError.unsupportedOlderSchema
        }

        let manifest = manifestVersion == 1 ? try decodeManifest(manifestData) : nil
        let preferences = preferencesVersion == 1
            ? try decodePreferences(preferencesData)
            : nil
        let profileHead = profileVersion == 1
            ? try decodeProfileHead(profileHeadData)
            : nil

        if manifestVersion > 1 || preferencesVersion > 1 || profileVersion > 1 {
            return .readOnly(libraryID: manifest?.libraryID)
        }

        guard let manifest, let preferences, let profileHead else {
            throw PortableLibraryPersistenceError.invalidSchemaVersion
        }
        return .readWrite(
            PortableLibraryAuthority(
                manifest: manifest,
                preferences: preferences,
                profileHead: profileHead
            )
        )
    }

    private func createInitialLayout(under rootDescriptor: Int32) throws {
        for relative in Self.initialDirectories {
            let path = try LibraryRelativePath(relative)
            let parent = try openDirectoryDescriptor(
                components: Array(path.components.dropLast()),
                under: rootDescriptor
            )
            defer { Darwin.close(parent) }
            guard mkdirat(parent, path.components.last!, 0o700) == 0 else {
                throw PortableLibraryPersistenceError.ioFailure
            }
        }
    }

    private func validateExpectedLayout(under rootDescriptor: Int32) throws {
        for relative in Self.initialDirectories {
            let directory = try openDirectoryDescriptor(
                components: try LibraryRelativePath(relative).components,
                under: rootDescriptor
            )
            Darwin.close(directory)
        }
    }

    private func writeRoot(
        _ data: Data,
        relativePath: String,
        under rootDescriptor: Int32
    ) throws {
        let path = try LibraryRelativePath(relativePath)
        let parentDescriptor = try openDirectoryDescriptor(
            components: Array(path.components.dropLast()),
            under: rootDescriptor
        )
        defer { Darwin.close(parentDescriptor) }
        let targetName = path.components.last!
        let partialName = ".\(targetName).\(UUID().uuidString).partial"
        do {
            try fault(.beforeRootPartialWrite(relativePath))
            try writeExclusive(data, named: partialName, under: parentDescriptor)
            try fault(.afterRootPartialWrite(relativePath))
            try fault(.afterRootFileFlush(relativePath))
            try noReplaceRename(
                from: partialName,
                to: targetName,
                under: parentDescriptor
            )
            try fault(.afterRootInstall(relativePath))
            try flushDescriptor(parentDescriptor)
            try fault(.afterDirectoryFlush(relativePath))
        } catch {
            _ = unlinkat(parentDescriptor, partialName, 0)
            throw error
        }
    }

    private func writeExclusive(
        _ data: Data,
        named name: String,
        under parentDescriptor: Int32
    ) throws {
        let descriptor = name.withCString { pointer in
            Darwin.openat(
                parentDescriptor,
                pointer,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard descriptor >= 0 else { throw PortableLibraryPersistenceError.ioFailure }
        var closeRequired = true
        defer { if closeRequired { Darwin.close(descriptor) } }
        let writeResult = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if count == 0 { return false }
                offset += count
            }
            return true
        }
        guard writeResult else {
            throw PortableLibraryPersistenceError.ioFailure
        }
        try flushDescriptor(descriptor)
        guard Darwin.close(descriptor) == 0 else {
            closeRequired = false
            throw PortableLibraryPersistenceError.ioFailure
        }
        closeRequired = false
    }

    private func noReplaceRename(
        from sourceName: String,
        to destinationName: String,
        under parentDescriptor: Int32
    ) throws {
        let result = sourceName.withCString { sourcePath in
            destinationName.withCString { destinationPath in
                renameatx_np(
                    parentDescriptor,
                    sourcePath,
                    parentDescriptor,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw PortableLibraryPersistenceError.destinationExists }
            throw PortableLibraryPersistenceError.ioFailure
        }
    }

    private func flushOwnedDirectories(under rootDescriptor: Int32) throws {
        for relative in Self.initialDirectories.reversed() {
            let descriptor = try openDirectoryDescriptor(
                components: try LibraryRelativePath(relative).components,
                under: rootDescriptor
            )
            defer { Darwin.close(descriptor) }
            try flushDescriptor(descriptor)
        }
        try flushDescriptor(rootDescriptor)
    }

    private func flushDescriptor(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw PortableLibraryPersistenceError.ioFailure
        }
    }

    private func boundedRootData(
        at path: LibraryRelativePath,
        under rootDescriptor: Int32
    ) throws -> Data {
        try fault(.beforeRootRead(path.description))
        let parent = try openDirectoryDescriptor(
            components: Array(path.components.dropLast()),
            under: rootDescriptor
        )
        defer { Darwin.close(parent) }
        let finalName = path.components.last!
        let descriptor = finalName.withCString { pointer in
            Darwin.openat(
                parent,
                pointer,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            if isSymlink(named: finalName, under: parent) {
                throw PortableLibraryPersistenceError.expectedPathIsSymlink
            }
            throw PortableLibraryPersistenceError.invalidLayout
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG
        else {
            throw PortableLibraryPersistenceError.invalidLayout
        }

        var data = Data(count: Self.maximumRootBytes + 1)
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
        guard count >= 0 else { throw PortableLibraryPersistenceError.ioFailure }
        data.removeSubrange(count..<data.count)
        guard data.count <= Self.maximumRootBytes else {
            throw PortableLibraryPersistenceError.rootTooLarge
        }
        return data
    }

    private func schemaVersion(in data: Data) throws -> UInt64 {
        _ = try jsonDictionary(data)
        do {
            return try JSONDecoder().decode(
                SchemaVersionEnvelope.self,
                from: data
            ).schemaVersion
        } catch {
            throw PortableLibraryPersistenceError.invalidSchemaVersion
        }
    }

    private func decodeManifest(_ data: Data) throws -> LibraryManifest {
        let dictionary = try jsonDictionary(data)
        try requireExactKeys(
            dictionary,
            ["schemaVersion", "formatName", "libraryId", "createdAt", "lastSuccessfulMigration"]
        )
        let dto: LibraryManifestDTO = try decode(LibraryManifestDTO.self, data)
        guard dto.schemaVersion == 1,
              dto.formatName == LibraryManifest.formatName,
              dto.lastSuccessfulMigration >= 1,
              let libraryID = try? LibraryID(dto.libraryId),
              let createdAt = try? UTCInstant(dto.createdAt)
        else {
            throw PortableLibraryPersistenceError.invalidManifest
        }
        return LibraryManifest(
            libraryID: libraryID,
            createdAt: createdAt,
            lastSuccessfulMigration: dto.lastSuccessfulMigration
        )
    }

    private func decodePreferences(_ data: Data) throws -> LibraryPreferences {
        let dictionary = try jsonDictionary(data)
        try requireExactKeys(
            dictionary,
            ["schemaVersion", "language", "annotationsVisible", "playbackRate"]
        )
        let dto: LibraryPreferencesDTO = try decode(LibraryPreferencesDTO.self, data)
        guard dto.schemaVersion == 1,
              let language = LibraryLanguage(rawValue: dto.language),
              let preferences = try? LibraryPreferences(
                  language: language,
                  annotationsVisible: dto.annotationsVisible,
                  playbackRate: dto.playbackRate
              )
        else {
            throw PortableLibraryPersistenceError.invalidPreferences
        }
        return preferences
    }

    private func decodeProfileHead(_ data: Data) throws -> ProfileHead {
        let dictionary = try jsonDictionary(data)
        let common = Set(["schemaVersion", "generation", "statementGeneration", "updatedAt"])
        let idPresent = dictionary.keys.contains("currentRevisionId")
        let shaPresent = dictionary.keys.contains("currentRevisionSha256")
        guard idPresent == shaPresent else {
            throw PortableLibraryPersistenceError.invalidProfileHead
        }
        let expected = idPresent
            ? common.union(["currentRevisionId", "currentRevisionSha256"])
            : common
        try requireExactKeys(dictionary, expected)
        if idPresent,
           dictionary["currentRevisionId"] is NSNull ||
            dictionary["currentRevisionSha256"] is NSNull
        {
            throw PortableLibraryPersistenceError.invalidProfileHead
        }

        let dto: ProfileHeadDTO = try decode(ProfileHeadDTO.self, data)
        guard dto.schemaVersion == 1,
              let updatedAt = try? UTCInstant(dto.updatedAt)
        else {
            throw PortableLibraryPersistenceError.invalidProfileHead
        }

        let selection: ProfileSelection
        if let revision = dto.currentRevisionId, let sha256 = dto.currentRevisionSha256 {
            guard let revisionID = try? ProfileRevisionID(revision),
                  let pointer = try? ProfileRevisionPointer(
                      revisionID: revisionID,
                      sha256: sha256
                  )
            else {
                throw PortableLibraryPersistenceError.invalidProfileHead
            }
            selection = .revision(pointer)
        } else if dto.currentRevisionId == nil, dto.currentRevisionSha256 == nil {
            selection = .null
        } else {
            throw PortableLibraryPersistenceError.invalidProfileHead
        }
        return ProfileHead(
            generation: dto.generation,
            statementGeneration: dto.statementGeneration,
            selection: selection,
            updatedAt: updatedAt
        )
    }

    private func requireExactKeys(_ dictionary: [String: Any], _ expected: Set<String>) throws {
        guard Set(dictionary.keys) == expected else {
            throw PortableLibraryPersistenceError.unknownKey
        }
    }

    private func jsonDictionary(_ data: Data) throws -> [String: Any] {
        do {
            guard let dictionary = try JSONSerialization.jsonObject(
                with: data,
                options: []
            ) as? [String: Any] else {
                throw PortableLibraryPersistenceError.invalidJSON
            }
            return dictionary
        } catch let error as PortableLibraryPersistenceError {
            throw error
        } catch {
            throw PortableLibraryPersistenceError.invalidJSON
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw PortableLibraryPersistenceError.invalidJSON
        }
    }

    private func deterministicJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    private func openDirectoryDescriptor(at url: URL) throws -> Int32 {
        let descriptor = url.path.withCString { pointer -> Int32 in
            while true {
                let result = Darwin.open(
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        guard descriptor >= 0 else {
            var metadata = stat()
            if lstat(url.path, &metadata) == 0,
               (metadata.st_mode & S_IFMT) == S_IFLNK
            {
                throw PortableLibraryPersistenceError.expectedPathIsSymlink
            }
            throw PortableLibraryPersistenceError.invalidLayout
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR
        else {
            Darwin.close(descriptor)
            throw PortableLibraryPersistenceError.invalidLayout
        }
        return descriptor
    }

    private func openDirectoryDescriptor(
        components: [String],
        under rootDescriptor: Int32
    ) throws -> Int32 {
        var current = Darwin.openat(
            rootDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else { throw PortableLibraryPersistenceError.ioFailure }
        do {
            for component in components {
                let next = component.withCString { pointer -> Int32 in
                    while true {
                        let result = Darwin.openat(
                            current,
                            pointer,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                        )
                        if result < 0, errno == EINTR { continue }
                        return result
                    }
                }
                guard next >= 0 else {
                    if isSymlink(named: component, under: current) {
                        throw PortableLibraryPersistenceError.expectedPathIsSymlink
                    }
                    throw PortableLibraryPersistenceError.invalidLayout
                }
                var metadata = stat()
                guard fstat(next, &metadata) == 0,
                      (metadata.st_mode & S_IFMT) == S_IFDIR
                else {
                    Darwin.close(next)
                    throw PortableLibraryPersistenceError.invalidLayout
                }
                Darwin.close(current)
                current = next
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private func rejectSymlinkIfPresent(named name: String, under descriptor: Int32) throws {
        var metadata = stat()
        let result = name.withCString { pointer in
            fstatat(descriptor, pointer, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            if errno == ENOENT { return }
            throw PortableLibraryPersistenceError.ioFailure
        }
        if (metadata.st_mode & S_IFMT) == S_IFLNK {
            throw PortableLibraryPersistenceError.expectedPathIsSymlink
        }
    }

    private func isSymlink(named name: String, under descriptor: Int32) -> Bool {
        var metadata = stat()
        let result = name.withCString { pointer in
            fstatat(descriptor, pointer, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        return result == 0 && (metadata.st_mode & S_IFMT) == S_IFLNK
    }

    private func entryExists(named name: String, under descriptor: Int32) throws -> Bool {
        var metadata = stat()
        let result = name.withCString { pointer in
            fstatat(descriptor, pointer, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return true }
        if errno == ENOENT { return false }
        throw PortableLibraryPersistenceError.ioFailure
    }

    private func removeOwnedStaging(named name: String, under parentDescriptor: Int32) {
        guard let root = try? openDirectoryDescriptor(
            components: [name],
            under: parentDescriptor
        ) else {
            return
        }

        _ = unlinkat(root, "library.json", 0)
        _ = unlinkat(root, "preferences.json", 0)
        if let profile = try? openDirectoryDescriptor(
            components: ["profile"],
            under: root
        ) {
            _ = unlinkat(profile, "head.json", 0)
            Darwin.close(profile)
        }

        for relative in Self.initialDirectories.reversed() {
            guard let path = try? LibraryRelativePath(relative),
                  let parent = try? openDirectoryDescriptor(
                      components: Array(path.components.dropLast()),
                      under: root
                  )
            else {
                continue
            }
            _ = unlinkat(parent, path.components.last!, AT_REMOVEDIR)
            Darwin.close(parent)
        }
        Darwin.close(root)
        _ = unlinkat(parentDescriptor, name, AT_REMOVEDIR)
    }

    private static let initialDirectories = [
        "profile",
        "profile/revisions",
        "sessions",
        "chats",
        "invocations",
        "jobs",
        "staging",
        "staging/recordings",
        "staging/jobs",
        "staging/publications",
        "trash",
        "trash/sessions",
        "trash/chats",
    ]
}

private struct SchemaVersionEnvelope: Decodable {
    let schemaVersion: UInt64
}

private struct LibraryManifestDTO: Codable {
    let schemaVersion: UInt64
    let formatName: String
    let libraryId: String
    let createdAt: String
    let lastSuccessfulMigration: UInt64
}

private struct LibraryPreferencesDTO: Codable {
    let schemaVersion: UInt64
    let language: String
    let annotationsVisible: Bool
    let playbackRate: Double
}

private struct ProfileHeadDTO: Codable {
    let schemaVersion: UInt64
    let generation: UInt64
    let statementGeneration: UInt64
    let updatedAt: String
    let currentRevisionId: String?
    let currentRevisionSha256: String?
}
