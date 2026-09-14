import AudoraDomain

/// Exact Session identities affected by one catalog mutation. The retained
/// Library activation prevents a same-ID replacement root from inheriting a
/// prior process-local reservation.
public struct LibraryCatalogSessionMutation: Equatable, Sendable {
    public let activation: LibraryActivation
    public let sessionIDs: Set<SessionID>

    public init(
        activation: LibraryActivation,
        sessionIDs: Set<SessionID>
    ) {
        precondition(!sessionIDs.isEmpty)
        self.activation = activation
        self.sessionIDs = sessionIDs
    }
}

/// Opaque authority proving that one dependent feature has quiesced its
/// Session state for an exact catalog mutation.
public struct LibraryCatalogSessionMutationLease: Equatable, Sendable {
    let token: UInt64
    let mutation: LibraryCatalogSessionMutation

    init(
        token: UInt64,
        mutation: LibraryCatalogSessionMutation
    ) {
        precondition(token > 0)
        self.token = token
        self.mutation = mutation
    }
}

public enum LibraryCatalogSessionMutationCompletion: Equatable, Sendable {
    /// No aggregate mutation was attempted. A captured selection may be
    /// rebound to the unchanged authoritative source.
    case aborted
    /// Mutation processing finished and this is the authoritative catalog
    /// readback. Unavailable readback must leave captured state cleared.
    case completed(LibraryCatalogLoadResult)
}

/// The release result for an exact Session-mutation authority.
///
/// A participant must consume every lease it owns, even when it cannot restore
/// current state. This prevents a failed reload from silently stranding the
/// participant behind a permanent mutation fence.
public enum LibraryCatalogSessionMutationFinishResult: Equatable, Sendable {
    /// The matching lease was consumed and the participant reflects the
    /// supplied completion.
    case consumed
    /// The matching lease was consumed, but a changed outer authority forced
    /// the participant to retain only its conservative invalidated state.
    case consumedWithInvalidatedState
    /// The supplied lease was not the participant's active lease. Nothing was
    /// consumed or changed.
    case notOwned

    var didConsumeLease: Bool {
        switch self {
        case .consumed, .consumedWithInvalidatedState: true
        case .notOwned: false
        }
    }

    var didFinishAuthoritativeState: Bool { self == .consumed }
}

/// Two-phase lifecycle shared by Session-processing and Review features.
/// The fail-closed defaults let lightweight consumers remain read-only while
/// ensuring they can never authorize a Session aggregate mutation.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol LibraryCatalogSessionLifecycle: Sendable {
    func reserveLibraryCatalogSessionMutation(
        _ mutation: LibraryCatalogSessionMutation
    ) async -> LibraryCatalogSessionMutationLease?

    func finishLibraryCatalogSessionMutation(
        _ lease: LibraryCatalogSessionMutationLease,
        completion: LibraryCatalogSessionMutationCompletion
    ) async -> LibraryCatalogSessionMutationFinishResult
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public extension LibraryCatalogSessionLifecycle {
    func reserveLibraryCatalogSessionMutation(
        _ mutation: LibraryCatalogSessionMutation
    ) async -> LibraryCatalogSessionMutationLease? { nil }

    func finishLibraryCatalogSessionMutation(
        _ lease: LibraryCatalogSessionMutationLease,
        completion: LibraryCatalogSessionMutationCompletion
    ) async -> LibraryCatalogSessionMutationFinishResult { .notOwned }
}

extension LibraryCatalogSessionMutation {
    init?(_ command: LibraryCatalogCommand) {
        let activation: LibraryActivation
        let aggregates: Set<LibraryAggregate>
        switch command {
        case .refresh:
            return nil
        case let .moveToTrash(selectedActivation, selectedAggregates),
             let .restore(selectedActivation, selectedAggregates):
            activation = selectedActivation
            aggregates = selectedAggregates
        }
        let extractedSessionIDs: [SessionID] = aggregates.compactMap { aggregate in
            guard case let .session(sessionID) = aggregate else { return nil }
            return sessionID
        }
        let sessionIDs = Set(extractedSessionIDs)
        guard !sessionIDs.isEmpty else { return nil }
        self.init(activation: activation, sessionIDs: sessionIDs)
    }
}
