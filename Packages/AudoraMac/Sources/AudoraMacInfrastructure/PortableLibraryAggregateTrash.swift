import AudoraApplication
import AudoraDomain
import Darwin
import Foundation

@_silgen_name("flock")
private func aggregateTrashFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

public enum PortableLibraryAggregateTrashFaultPoint: Hashable, Sendable {
    case afterRename
    case afterSourceParentFlush
    case afterDestinationParentFlush
    case afterActiveCatalogRead
    case afterActiveChatCatalogNameEnumeration
    case afterCatalogAggregateOpen
}

/// Descriptor-confined persistence for the Library's persistent Trash. A move
/// is one no-replace directory rename; the aggregate's complete subtree and all
/// references elsewhere in the Library remain byte-for-byte unchanged.
public struct PortableLibraryAggregateTrash: Sendable {
    private static let maximumCatalogEntriesPerKind = 32_768
    private static let maximumAggregateManifestBytes = 65_536
    private static let maximumCatalogStabilizationReads = 3
    private static let maximumTransientCatalogRetries = 3

    private let fault: @Sendable (PortableLibraryAggregateTrashFaultPoint) throws
        -> Void

    public init(
        fault: @escaping @Sendable (PortableLibraryAggregateTrashFaultPoint) throws
            -> Void = { _ in }
    ) {
        self.fault = fault
    }

    public func loadCatalog(
        at root: URL,
        in scope: LibraryScope
    ) -> LibraryCatalogLoadResult {
        do {
            let authority = try openRoot(at: root, in: scope, expectedIdentity: nil)
            defer { authority.close() }
            guard !authority.isReadOnly else { return .readOnly }

            var previous: CatalogRead?
            var stabilizationReads = 0
            var transientRetries = 0
            while stabilizationReads < Self.maximumCatalogStabilizationReads {
                let current: CatalogRead
                do {
                    current = try readCatalog(under: authority)
                } catch PortableLibraryAggregateTrashError
                    .transientCatalogChange
                {
                    transientRetries += 1
                    guard transientRetries <= Self.maximumTransientCatalogRetries
                    else { return .integrityMismatch }
                    previous = nil
                    stabilizationReads = 0
                    continue
                }
                stabilizationReads += 1
                if current == previous {
                    return current.hasActiveTrashOverlap
                        ? .integrityMismatch
                        : .available(current.snapshot)
                }
                previous = current
            }
            return .integrityMismatch
        } catch PortableLibraryAggregateTrashError.scopeMismatch {
            return .unavailable
        } catch PortableLibraryAggregateTrashError.readOnly {
            return .readOnly
        } catch PortableLibraryAggregateTrashError.invalidLayout {
            return .integrityMismatch
        } catch {
            return .unavailable
        }
    }

    public func moveToTrash(
        _ aggregate: LibraryAggregate,
        at root: URL,
        in scope: LibraryScope
    ) -> LibraryAggregateMutationOutcome {
        coordinate(aggregate, at: root, in: scope, direction: .toTrash)
    }

    public func restore(
        _ aggregate: LibraryAggregate,
        at root: URL,
        in scope: LibraryScope
    ) -> LibraryAggregateMutationOutcome {
        coordinate(aggregate, at: root, in: scope, direction: .toActive)
    }
}

/// Active-Library adapter used by Application. The Library actor keeps a
/// selection switch from crossing the complete descriptor-confined transaction.
public actor PortableLibraryAggregateTrashStore: LibraryAggregateTrashPort {
    private let persistence: PortableLibraryAggregateTrash
    private let activeLibrary: PortableLibraryWorkspace

    public init(
        persistence: PortableLibraryAggregateTrash = PortableLibraryAggregateTrash(),
        activeLibrary: PortableLibraryWorkspace
    ) {
        self.persistence = persistence
        self.activeLibrary = activeLibrary
    }

    public func loadCatalog(
        for activation: LibraryActivation
    ) async -> LibraryCatalogLoadResult {
        guard activation.generation > 0 else { return .unavailable }
        let scope = activation.scope
        let result = await activeLibrary.performActiveReadWriteOperation(in: scope) { root in
            persistence.loadCatalog(at: root, in: scope)
        }
        return switch result {
        case let .performed(catalog): catalog
        case .readOnly: .readOnly
        case .unavailable: .unavailable
        }
    }

    public func moveToTrash(
        _ aggregate: LibraryAggregate,
        for activation: LibraryActivation
    ) async -> LibraryAggregateMutationOutcome {
        guard activation.generation > 0 else { return .unavailable }
        let scope = activation.scope
        let result = await activeLibrary.performActiveReadWriteOperation(in: scope) { root in
            persistence.moveToTrash(aggregate, at: root, in: scope)
        }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly: .readOnly
        case .unavailable: .unavailable
        }
    }

    public func restore(
        _ aggregate: LibraryAggregate,
        for activation: LibraryActivation
    ) async -> LibraryAggregateMutationOutcome {
        guard activation.generation > 0 else { return .unavailable }
        let scope = activation.scope
        let result = await activeLibrary.performActiveReadWriteOperation(in: scope) { root in
            persistence.restore(aggregate, at: root, in: scope)
        }
        return switch result {
        case let .performed(outcome): outcome
        case .readOnly: .readOnly
        case .unavailable: .unavailable
        }
    }
}

private extension PortableLibraryAggregateTrash {
    enum Direction: Sendable {
        case toTrash
        case toActive
    }

    struct RootAuthority {
        let root: URL
        let parentDescriptor: Int32
        let rootDescriptor: Int32
        let rootName: String
        let rootIdentity: LibraryRootIdentity
        let libraryID: LibraryID
        let isReadOnly: Bool

        func close() {
            Darwin.close(rootDescriptor)
            Darwin.close(parentDescriptor)
        }
    }

    struct DirectoryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    struct CatalogRead: Equatable {
        let snapshot: LibraryCatalogSnapshot
        let hasActiveTrashOverlap: Bool
    }

    struct AggregateParents {
        let activeDescriptor: Int32
        let activeIdentity: DirectoryIdentity
        let activeName: String
        let trashRootDescriptor: Int32
        let trashRootIdentity: DirectoryIdentity
        let trashDescriptor: Int32
        let trashIdentity: DirectoryIdentity
        let trashName: String

        func close() {
            Darwin.close(trashDescriptor)
            Darwin.close(trashRootDescriptor)
            Darwin.close(activeDescriptor)
        }
    }

    var confined: ConfinedPersistencePrimitives<PortableLibraryAggregateTrashError> {
        ConfinedPersistencePrimitives(
            ioFailure: .io,
            invalidLayout: .invalidLayout,
            expectedPathIsSymlink: .invalidLayout,
            rootTooLarge: .invalidLayout,
            invalidJSON: .invalidLayout,
            invalidSchemaVersion: .invalidLayout,
            unknownKey: .invalidLayout
        )
    }

    func coordinate(
        _ aggregate: LibraryAggregate,
        at root: URL,
        in scope: LibraryScope,
        direction: Direction
    ) -> LibraryAggregateMutationOutcome {
        switch aggregate {
        case let .session(sessionID):
            let jobs = PortableSessionProcessingJobRepository(
                root: root,
                libraryID: scope.libraryID
            )
            do {
                guard let outcome = try jobs.withSessionAggregateTrashAuthority(
                    for: sessionID,
                    { expectedRootIdentity in
                        mutate(
                            aggregate,
                            at: root,
                            in: scope,
                            expectedRootIdentity: expectedRootIdentity,
                            direction: direction
                        )
                    }
                ) else { return .busy }
                return outcome
            } catch PortableSessionAggregateTrashCoordinationError
                .unsupportedSchema
            {
                return .unsupportedSchema
            } catch PortableSessionAggregateTrashCoordinationError
                .integrityMismatch
            {
                return .integrityMismatch
            } catch PortableSessionAggregateTrashCoordinationError.unavailable {
                return .unavailable
            } catch {
                return .failed
            }

        case .chat:
            do {
                guard let outcome = try PortableChatPersistence()
                    .withChatAggregateTrashAuthority(
                        at: root,
                        in: scope,
                        { expectedRootIdentity in
                            mutate(
                                aggregate,
                                at: root,
                                in: scope,
                                expectedRootIdentity: expectedRootIdentity,
                                direction: direction
                            )
                        }
                    )
                else { return .busy }
                return outcome
            } catch PortableChatPersistenceError.readOnlyLibrary {
                return .readOnly
            } catch PortableChatPersistenceError.libraryScopeMismatch {
                return .unavailable
            } catch {
                return .failed
            }
        }
    }

    func mutate(
        _ aggregate: LibraryAggregate,
        at root: URL,
        in scope: LibraryScope,
        expectedRootIdentity: LibraryRootIdentity,
        direction: Direction
    ) -> LibraryAggregateMutationOutcome {
        var renamed = false
        do {
            let rootAuthority = try openRoot(
                at: root,
                in: scope,
                expectedIdentity: expectedRootIdentity
            )
            defer { rootAuthority.close() }
            guard !rootAuthority.isReadOnly else { return .readOnly }
            let kind: CatalogKind = switch aggregate {
            case .session: .session
            case .chat: .chat
            }
            let parents = try openParents(for: kind, under: rootAuthority)
            defer { parents.close() }

            let sourceParent: Int32
            let destinationParent: Int32
            switch direction {
            case .toTrash:
                sourceParent = parents.activeDescriptor
                destinationParent = parents.trashDescriptor
            case .toActive:
                sourceParent = parents.trashDescriptor
                destinationParent = parents.activeDescriptor
            }
            let name = aggregateIdentifier(aggregate)
            guard try confined.entryExists(named: name, under: sourceParent) else {
                return .sourceMissing
            }
            let aggregateDescriptor = try confined.openDirectory(
                named: name,
                under: sourceParent
            )
            defer { Darwin.close(aggregateDescriptor) }
            try lockExclusively(aggregateDescriptor)
            defer { _ = aggregateTrashFlock(aggregateDescriptor, LOCK_UN) }
            let aggregateIdentity = try identity(of: aggregateDescriptor)

            try revalidate(rootAuthority)
            try revalidate(parents, under: rootAuthority)
            guard try namedDirectoryIdentity(name, under: sourceParent) ==
                aggregateIdentity
            else { throw PortableLibraryAggregateTrashError.invalidLayout }
            guard try !confined.entryExists(named: name, under: destinationParent)
            else { return .targetCollision }

            try confined.renameNoReplace(
                from: name,
                under: sourceParent,
                to: name,
                under: destinationParent,
                collision: .collision
            )
            renamed = true
            guard try namedDirectoryIdentity(name, under: destinationParent) ==
                aggregateIdentity
            else { throw PortableLibraryAggregateTrashError.invalidLayout }
            try fault(.afterRename)
            try confined.flush(sourceParent)
            try fault(.afterSourceParentFlush)
            try confined.flush(destinationParent)
            try fault(.afterDestinationParentFlush)
            try revalidate(rootAuthority)
            try revalidate(parents, under: rootAuthority)
            guard try namedDirectoryIdentity(name, under: destinationParent) ==
                aggregateIdentity
            else { throw PortableLibraryAggregateTrashError.invalidLayout }
            return .succeeded
        } catch PortableLibraryAggregateTrashError.collision {
            return .targetCollision
        } catch PortableLibraryAggregateTrashError.readOnly {
            return .readOnly
        } catch PortableLibraryAggregateTrashError.scopeMismatch {
            return .unavailable
        } catch PortableLibraryAggregateTrashError.invalidLayout {
            return renamed ? .commitUncertain : .integrityMismatch
        } catch {
            return renamed ? .commitUncertain : .failed
        }
    }

    func readCatalog(under authority: RootAuthority) throws -> CatalogRead
    {
        try revalidate(authority)
        let sessions = try openParents(for: .session, under: authority)
        defer { sessions.close() }
        let chats = try openParents(for: .chat, under: authority)
        defer { chats.close() }

        let activeSessions = try catalogEntries(
            under: sessions.activeDescriptor,
            kind: .session,
            authority: authority
        )
        let activeChats = try catalogEntries(
            under: chats.activeDescriptor,
            kind: .chat,
            authority: authority,
            afterEnumeration: .afterActiveChatCatalogNameEnumeration
        )
        let active = activeSessions + activeChats
        try fault(.afterActiveCatalogRead)
        let trash = try catalogEntries(
            under: sessions.trashDescriptor,
            kind: .session,
            authority: authority
        ) + catalogEntries(
            under: chats.trashDescriptor,
            kind: .chat,
            authority: authority
        )
        try revalidate(authority)
        try revalidate(sessions, under: authority)
        try revalidate(chats, under: authority)
        return CatalogRead(
            snapshot: LibraryCatalogSnapshot(
                active: active.sorted { $0.aggregate < $1.aggregate },
                trash: trash.sorted { $0.aggregate < $1.aggregate }
            ),
            hasActiveTrashOverlap: !Set(active.map(\.aggregate)).isDisjoint(
                with: Set(trash.map(\.aggregate))
            )
        )
    }

    enum CatalogKind {
        case session
        case chat

        var manifestName: String {
            switch self {
            case .session: "session.json"
            case .chat: "chat.json"
            }
        }
    }

    func catalogEntries(
        under descriptor: Int32,
        kind: CatalogKind,
        authority: RootAuthority,
        afterEnumeration: PortableLibraryAggregateTrashFaultPoint? = nil
    ) throws -> [LibraryCatalogRow] {
        let names = try confined.listEntryNames(
            under: descriptor,
            maximumCount: Self.maximumCatalogEntriesPerKind
        ).filter { $0 != ".DS_Store" }
        if let afterEnumeration { try fault(afterEnumeration) }
        return try names.map { name in
            let aggregate: LibraryAggregate
            switch kind {
            case .session:
                guard let sessionID = try? SessionID(name) else {
                    throw PortableLibraryAggregateTrashError.invalidLayout
                }
                aggregate = .session(sessionID)
            case .chat:
                guard let chatID = try? ChatID(name) else {
                    throw PortableLibraryAggregateTrashError.invalidLayout
                }
                aggregate = .chat(chatID)
            }

            let aggregateDescriptor = try openCatalogAggregateDirectory(
                named: name,
                under: descriptor
            )
            defer { Darwin.close(aggregateDescriptor) }
            try fault(.afterCatalogAggregateOpen)
            try lockShared(aggregateDescriptor)
            defer { _ = aggregateTrashFlock(aggregateDescriptor, LOCK_UN) }
            let aggregateIdentity = try identity(of: aggregateDescriptor)
            try revalidateCatalogAggregate(
                named: name,
                under: descriptor,
                expectedIdentity: aggregateIdentity
            )

            let row: LibraryCatalogRow
            do {
                let data = try confined.boundedData(
                    named: kind.manifestName,
                    under: aggregateDescriptor,
                    maximumBytes: Self.maximumAggregateManifestBytes
                )
                switch aggregate {
                case let .session(sessionID):
                    row = PortableTranscriptRevisionRepository(
                        root: authority.root,
                        libraryID: authority.libraryID
                    ).libraryCatalogRow(
                        fromSessionManifest: data,
                        expectedSessionID: sessionID
                    )
                case let .chat(chatID):
                    row = PortableChatPersistence().libraryCatalogRow(
                        fromChatManifest: data,
                        expectedChatID: chatID
                    )
                }
            } catch {
                row = .unavailable(aggregate, .corrupt)
            }

            try revalidateCatalogAggregate(
                named: name,
                under: descriptor,
                expectedIdentity: aggregateIdentity
            )
            return row
        }
    }

    func revalidateCatalogAggregate(
        named name: String,
        under parent: Int32,
        expectedIdentity: DirectoryIdentity
    ) throws {
        var metadata = stat()
        let result = name.withCString {
            Darwin.fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            if errno == ENOENT {
                throw PortableLibraryAggregateTrashError.transientCatalogChange
            }
            throw PortableLibraryAggregateTrashError.invalidLayout
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw PortableLibraryAggregateTrashError.invalidLayout
        }
        let currentIdentity = DirectoryIdentity(
            device: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(truncatingIfNeeded: metadata.st_ino)
        )
        guard currentIdentity == expectedIdentity else {
            throw PortableLibraryAggregateTrashError.transientCatalogChange
        }
    }

    func openCatalogAggregateDirectory(
        named name: String,
        under parent: Int32
    ) throws -> Int32 {
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
            if errno == ENOENT {
                throw PortableLibraryAggregateTrashError.transientCatalogChange
            }
            throw PortableLibraryAggregateTrashError.invalidLayout
        }
        do {
            _ = try identity(of: descriptor)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func lockShared(_ descriptor: Int32) throws {
        while aggregateTrashFlock(descriptor, LOCK_SH) != 0 {
            if errno == EINTR { continue }
            throw PortableLibraryAggregateTrashError.io
        }
    }

    func openRoot(
        at root: URL,
        in scope: LibraryScope,
        expectedIdentity: LibraryRootIdentity?
    ) throws -> RootAuthority {
        guard root.pathExtension == "audoralibrary" else {
            throw PortableLibraryAggregateTrashError.invalidLayout
        }
        let rootName = root.lastPathComponent
        guard !rootName.isEmpty, rootName != ".", rootName != "..",
              !rootName.contains("/"), !rootName.contains("\\")
        else { throw PortableLibraryAggregateTrashError.invalidLayout }
        let parent = root.deletingLastPathComponent()
        let parentDescriptor = parent.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard parentDescriptor >= 0 else {
            throw PortableLibraryAggregateTrashError.io
        }
        let rootDescriptor = rootName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard rootDescriptor >= 0 else {
            Darwin.close(parentDescriptor)
            throw PortableLibraryAggregateTrashError.io
        }
        do {
            guard let captured = LibraryRootIdentity.capture(rootDescriptor),
                  expectedIdentity == nil || expectedIdentity == captured,
                  LibraryRootIdentity.capture(root) == captured
            else { throw PortableLibraryAggregateTrashError.invalidLayout }
            let loaded = try PortableLibraryPersistence().load(
                from: rootDescriptor,
                reconcileAbandonedImports: false
            )
            let isReadOnly: Bool
            switch loaded {
            case let .readWrite(library):
                guard library.manifest.libraryID == scope.libraryID else {
                    throw PortableLibraryAggregateTrashError.scopeMismatch
                }
                isReadOnly = false
            case let .readOnly(libraryID):
                guard libraryID == scope.libraryID else {
                    throw PortableLibraryAggregateTrashError.scopeMismatch
                }
                isReadOnly = true
            }
            return RootAuthority(
                root: root,
                parentDescriptor: parentDescriptor,
                rootDescriptor: rootDescriptor,
                rootName: rootName,
                rootIdentity: captured,
                libraryID: scope.libraryID,
                isReadOnly: isReadOnly
            )
        } catch {
            Darwin.close(rootDescriptor)
            Darwin.close(parentDescriptor)
            throw error
        }
    }

    func openParents(
        for kind: CatalogKind,
        under root: RootAuthority
    ) throws -> AggregateParents {
        let name: String = switch kind {
        case .session: "sessions"
        case .chat: "chats"
        }
        let active = try confined.openDirectory(
            named: name,
            under: root.rootDescriptor
        )
        do {
            let trashRoot = try confined.openDirectory(
                named: "trash",
                under: root.rootDescriptor
            )
            do {
                let trash = try confined.openDirectory(named: name, under: trashRoot)
                return AggregateParents(
                    activeDescriptor: active,
                    activeIdentity: try identity(of: active),
                    activeName: name,
                    trashRootDescriptor: trashRoot,
                    trashRootIdentity: try identity(of: trashRoot),
                    trashDescriptor: trash,
                    trashIdentity: try identity(of: trash),
                    trashName: name
                )
            } catch {
                Darwin.close(trashRoot)
                throw error
            }
        } catch {
            Darwin.close(active)
            throw error
        }
    }

    func revalidate(_ authority: RootAuthority) throws {
        guard LibraryRootIdentity.capture(authority.rootDescriptor) ==
                authority.rootIdentity,
              LibraryRootIdentity.capture(authority.root) == authority.rootIdentity
        else { throw PortableLibraryAggregateTrashError.invalidLayout }
        let reopened = authority.rootName.withCString {
            Darwin.openat(
                authority.parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard reopened >= 0 else {
            throw PortableLibraryAggregateTrashError.invalidLayout
        }
        defer { Darwin.close(reopened) }
        guard LibraryRootIdentity.capture(reopened) == authority.rootIdentity else {
            throw PortableLibraryAggregateTrashError.invalidLayout
        }
        let loaded = try PortableLibraryPersistence().load(
            from: authority.rootDescriptor,
            reconcileAbandonedImports: false
        )
        guard case let .readWrite(library) = loaded,
              library.manifest.libraryID == authority.libraryID
        else {
            if case .readOnly = loaded {
                throw PortableLibraryAggregateTrashError.readOnly
            }
            throw PortableLibraryAggregateTrashError.scopeMismatch
        }
    }

    func revalidate(
        _ parents: AggregateParents,
        under root: RootAuthority
    ) throws {
        guard try identity(of: parents.activeDescriptor) == parents.activeIdentity,
              try namedDirectoryIdentity(
                  parents.activeName,
                  under: root.rootDescriptor
              ) == parents.activeIdentity,
              try identity(of: parents.trashRootDescriptor) ==
                parents.trashRootIdentity,
              try namedDirectoryIdentity("trash", under: root.rootDescriptor) ==
                parents.trashRootIdentity,
              try identity(of: parents.trashDescriptor) == parents.trashIdentity,
              try namedDirectoryIdentity(
                  parents.trashName,
                  under: parents.trashRootDescriptor
              ) == parents.trashIdentity
        else { throw PortableLibraryAggregateTrashError.invalidLayout }
    }

    func namedDirectoryIdentity(
        _ name: String,
        under parent: Int32
    ) throws -> DirectoryIdentity {
        var metadata = stat()
        let result = name.withCString {
            Darwin.fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0, (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw PortableLibraryAggregateTrashError.invalidLayout
        }
        return DirectoryIdentity(
            device: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(truncatingIfNeeded: metadata.st_ino)
        )
    }

    func identity(of descriptor: Int32) throws -> DirectoryIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR
        else { throw PortableLibraryAggregateTrashError.invalidLayout }
        return DirectoryIdentity(
            device: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(truncatingIfNeeded: metadata.st_ino)
        )
    }

    func lockExclusively(_ descriptor: Int32) throws {
        while aggregateTrashFlock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw PortableLibraryAggregateTrashError.io
        }
    }

    func aggregateIdentifier(_ aggregate: LibraryAggregate) -> String {
        switch aggregate {
        case let .session(sessionID): sessionID.rawValue
        case let .chat(chatID): chatID.rawValue
        }
    }

}

private enum PortableLibraryAggregateTrashError: Error {
    case collision
    case invalidLayout
    case io
    case readOnly
    case scopeMismatch
    case transientCatalogChange
}
