import AudoraDomain

public enum LibraryActivityKind: Equatable, Sendable {
    case audioImport
    case recording
    case selectionMutation
    case catalogAccess
}

public enum LibrarySelectionAuthorityUpdate: Equatable, Sendable {
    case retain
    case activate(LibraryActivation)
    case deactivate
}

public enum LibraryCatalogAccessReservation: Equatable, Sendable {
    case acquired(LibraryActivityLease)
    /// The exact activation is current, but another Library activity owns the
    /// mutation boundary. No catalog work was attempted.
    case busy
    /// The requested activation is not the coordinator's current authority.
    case unavailable
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
    func acquireAudioImport() async -> LibraryActivityLease?
    func acquireRecording(in scope: LibraryScope) async -> LibraryActivityLease?
    func acquireSelectionMutation() async -> LibraryActivityLease?
    func acquireCatalogAccess(
        for activation: LibraryActivation
    ) async -> LibraryCatalogAccessReservation
    func finishSelectionMutation(
        _ lease: LibraryActivityLease,
        authorityUpdate: LibrarySelectionAuthorityUpdate
    ) async
    func release(_ lease: LibraryActivityLease) async
}

public extension LibraryActivityCoordinating {
    /// Custom coordinators that predate catalog authority stay fail-closed.
    func acquireCatalogAccess(
        for activation: LibraryActivation
    ) async -> LibraryCatalogAccessReservation { .unavailable }

    func finishSelectionMutation(
        _ lease: LibraryActivityLease,
        authorityUpdate: LibrarySelectionAuthorityUpdate
    ) async {
        await release(lease)
    }
}

public actor LibraryActivityCoordinator: LibraryActivityCoordinating {
    private var current: LibraryActivityLease?
    private var activeActivation: LibraryActivation?
    private var nextToken: UInt64 = 1

    public init() {}

    public func acquireAudioImport() -> LibraryActivityLease? {
        acquire(kind: .audioImport, libraryID: nil)
    }

    public func acquireRecording(in scope: LibraryScope) -> LibraryActivityLease? {
        acquire(kind: .recording, libraryID: scope.libraryID)
    }

    public func acquireSelectionMutation() -> LibraryActivityLease? {
        acquire(kind: .selectionMutation, libraryID: nil)
    }

    public func acquireCatalogAccess(
        for activation: LibraryActivation
    ) async -> LibraryCatalogAccessReservation {
        guard activation.generation > 0,
              activeActivation == activation
        else { return .unavailable }
        guard let lease = acquire(
            kind: .catalogAccess,
            libraryID: activation.scope.libraryID
        ) else { return .busy }
        return .acquired(lease)
    }

    public func finishSelectionMutation(
        _ lease: LibraryActivityLease,
        authorityUpdate: LibrarySelectionAuthorityUpdate
    ) async {
        guard current == lease, lease.kind == .selectionMutation else { return }
        switch authorityUpdate {
        case .retain:
            break
        case let .activate(activation):
            activeActivation = activation
        case .deactivate:
            activeActivation = nil
        }
        current = nil
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
