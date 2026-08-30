import AudoraDomain

public enum LibraryActivityKind: Equatable, Sendable {
    case recording
    case selectionMutation
}

public struct LibraryActivityLease: Equatable, Sendable {
    public let token: UInt64
    public let kind: LibraryActivityKind
    public let libraryID: LibraryID?

    init(token: UInt64, kind: LibraryActivityKind, libraryID: LibraryID?) {
        self.token = token
        self.kind = kind
        self.libraryID = libraryID
    }
}

public protocol LibraryActivityCoordinating: Sendable {
    func acquireRecording(in scope: LibraryScope) async -> LibraryActivityLease?
    func acquireSelectionMutation() async -> LibraryActivityLease?
    func release(_ lease: LibraryActivityLease) async
}

public actor LibraryActivityCoordinator: LibraryActivityCoordinating {
    private var current: LibraryActivityLease?
    private var nextToken: UInt64 = 1

    public init() {}

    public func acquireRecording(in scope: LibraryScope) -> LibraryActivityLease? {
        acquire(kind: .recording, libraryID: scope.libraryID)
    }

    public func acquireSelectionMutation() -> LibraryActivityLease? {
        acquire(kind: .selectionMutation, libraryID: nil)
    }

    public func release(_ lease: LibraryActivityLease) {
        guard current == lease else { return }
        current = nil
    }

    public var activeKind: LibraryActivityKind? { current?.kind }

    private func acquire(
        kind: LibraryActivityKind,
        libraryID: LibraryID?
    ) -> LibraryActivityLease? {
        guard current == nil else { return nil }
        let lease = LibraryActivityLease(
            token: nextToken,
            kind: kind,
            libraryID: libraryID
        )
        nextToken &+= 1
        current = lease
        return lease
    }
}
