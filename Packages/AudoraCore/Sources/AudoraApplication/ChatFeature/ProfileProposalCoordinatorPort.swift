import AudoraDomain

public enum ProfileProposalMutationError: Error, Equatable, Sendable {
    case proposalMismatch
    case invalidDerivedIdentity
}

public struct AcceptProfileProposalMutation: Equatable, Sendable {
    public let library: LibraryScope
    public let base: ChatAggregate
    public let proposalID: ProfileChangeProposalID
    public let intendedRevisionID: ProfileRevisionID
    public let writeIntentID: ProfileWriteIntentID
    public let acceptedAt: UTCInstant

    public init(
        library: LibraryScope,
        base: ChatAggregate,
        proposalID: ProfileChangeProposalID,
        acceptedAt: UTCInstant
    ) throws {
        guard base.profileProposal?.id == proposalID else {
            throw ProfileProposalMutationError.proposalMismatch
        }
        let tail = String(proposalID.rawValue.dropFirst("prp-".count))
        guard let intendedRevisionID = try? ProfileRevisionID("prf-\(tail)"),
              let writeIntentID = try? ProfileWriteIntentID("pwi-\(tail)")
        else { throw ProfileProposalMutationError.invalidDerivedIdentity }
        self.library = library
        self.base = base
        self.proposalID = proposalID
        self.intendedRevisionID = intendedRevisionID
        self.writeIntentID = writeIntentID
        self.acceptedAt = acceptedAt
    }
}

public struct DiscardProfileProposalMutation: Equatable, Sendable {
    public let library: LibraryScope
    public let base: ChatAggregate
    public let proposalID: ProfileChangeProposalID

    public init(
        library: LibraryScope,
        base: ChatAggregate,
        proposalID: ProfileChangeProposalID
    ) throws {
        guard base.profileProposal?.id == proposalID else {
            throw ProfileProposalMutationError.proposalMismatch
        }
        self.library = library
        self.base = base
        self.proposalID = proposalID
    }
}

public enum ProfileProposalMutationOutcome: Equatable, Sendable {
    case committed(ChatAggregate)
    case stale(ChatAggregate)
    case readOnlyLibrary
    case failed
}

public protocol ProfileProposalCoordinating: Sendable {
    func accept(
        _ mutation: AcceptProfileProposalMutation
    ) async -> ProfileProposalMutationOutcome

    func discard(
        _ mutation: DiscardProfileProposalMutation
    ) async -> ProfileProposalMutationOutcome
}

public struct UnavailableProfileProposalCoordinator:
    ProfileProposalCoordinating
{
    public init() {}

    public func accept(
        _ mutation: AcceptProfileProposalMutation
    ) async -> ProfileProposalMutationOutcome {
        .failed
    }

    public func discard(
        _ mutation: DiscardProfileProposalMutation
    ) async -> ProfileProposalMutationOutcome {
        .failed
    }
}
