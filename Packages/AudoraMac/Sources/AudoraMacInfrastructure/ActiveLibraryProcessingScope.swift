import AudoraDomain
import Darwin
import Foundation

public struct SessionProcessingRootIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    static func capture(_ root: URL) -> SessionProcessingRootIdentity? {
        let descriptor = root.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR
        else { return nil }
        return SessionProcessingRootIdentity(
            device: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(truncatingIfNeeded: metadata.st_ino)
        )
    }
}

public struct SessionProcessingScopeIdentity: Equatable, Sendable {
    public let libraryID: LibraryID
    public let workspaceGeneration: UInt64
    public let rootIdentity: SessionProcessingRootIdentity

    public init(
        libraryID: LibraryID,
        workspaceGeneration: UInt64,
        rootIdentity: SessionProcessingRootIdentity
    ) {
        self.libraryID = libraryID
        self.workspaceGeneration = workspaceGeneration
        self.rootIdentity = rootIdentity
    }
}

public final class ActiveLibraryProcessingScope: @unchecked Sendable {
    public let identity: SessionProcessingScopeIdentity
    public let root: URL
    private let lease: any LibraryAccessLease

    init(
        identity: SessionProcessingScopeIdentity,
        root: URL,
        lease: any LibraryAccessLease
    ) {
        self.identity = identity
        self.root = root
        self.lease = lease
    }

    deinit { lease.release() }
}

public enum SessionProcessingScopeError: Error, Equatable, Sendable {
    case changed
}

public protocol SessionProcessingLibraryScopeProviding: Sendable {
    func acquireSessionProcessingScope(
        for scope: LibraryScope
    ) async -> ActiveLibraryProcessingScope?

    func isCurrentSessionProcessingScope(
        _ identity: SessionProcessingScopeIdentity
    ) async -> Bool

    func withCurrentSessionProcessingScope<Result: Sendable>(
        _ identity: SessionProcessingScopeIdentity,
        perform operation: @Sendable () throws -> Result
    ) async throws -> Result
}

extension PortableLibraryWorkspace: SessionProcessingLibraryScopeProviding {}
