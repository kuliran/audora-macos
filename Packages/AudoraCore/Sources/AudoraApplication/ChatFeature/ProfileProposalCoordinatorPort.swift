import AudoraDomain

public enum ProfileProposalMutationError: Error, Equatable, Sendable {
    case proposalMismatch
    case invalidDerivedIdentity
}

public enum ProfileEvidencePublicationMutationError: Error, Equatable, Sendable {
    case publicationMismatch
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

public struct PublishProfileEvidenceMutation: Equatable, Sendable {
    public let library: LibraryScope
    public let base: ChatAggregate
    public let responsePositionID: ChatResponsePositionID
    public let intendedRevisionID: ProfileRevisionID

    public init(
        library: LibraryScope,
        base: ChatAggregate,
        responsePositionID: ChatResponsePositionID
    ) throws {
        guard base.profileEvidencePublication?.responsePositionID ==
            responsePositionID
        else {
            throw ProfileEvidencePublicationMutationError.publicationMismatch
        }
        let tail = String(
            responsePositionID.rawValue.dropFirst("rsp-".count)
        )
        guard let intendedRevisionID = try? ProfileRevisionID("prf-\(tail)")
        else {
            throw ProfileEvidencePublicationMutationError.invalidDerivedIdentity
        }
        self.library = library
        self.base = base
        self.responsePositionID = responsePositionID
        self.intendedRevisionID = intendedRevisionID
    }
}

public struct DiscardProfileEvidencePublicationMutation: Equatable, Sendable {
    public let library: LibraryScope
    public let base: ChatAggregate
    public let responsePositionID: ChatResponsePositionID

    public init(
        library: LibraryScope,
        base: ChatAggregate,
        responsePositionID: ChatResponsePositionID
    ) throws {
        guard base.profileEvidencePublication?.responsePositionID ==
            responsePositionID
        else {
            throw ProfileEvidencePublicationMutationError.publicationMismatch
        }
        self.library = library
        self.base = base
        self.responsePositionID = responsePositionID
    }
}

public enum ProfileProposalMutationOutcome: Equatable, Sendable {
    case committed(ChatAggregate)
    case stale(ChatAggregate)
    case readOnlyLibrary
    case failed
}

public enum ProfileEvidencePublicationMutationOutcome: Equatable, Sendable {
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

    func publishEvidence(
        _ mutation: PublishProfileEvidenceMutation
    ) async -> ProfileEvidencePublicationMutationOutcome

    func discardEvidence(
        _ mutation: DiscardProfileEvidencePublicationMutation
    ) async -> ProfileEvidencePublicationMutationOutcome
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

    public func publishEvidence(
        _ mutation: PublishProfileEvidenceMutation
    ) async -> ProfileEvidencePublicationMutationOutcome {
        .failed
    }

    public func discardEvidence(
        _ mutation: DiscardProfileEvidencePublicationMutation
    ) async -> ProfileEvidencePublicationMutationOutcome {
        .failed
    }
}

public extension ProfileProposalCoordinating {
    func publishEvidence(
        _ mutation: PublishProfileEvidenceMutation
    ) async -> ProfileEvidencePublicationMutationOutcome {
        .failed
    }

    func discardEvidence(
        _ mutation: DiscardProfileEvidencePublicationMutation
    ) async -> ProfileEvidencePublicationMutationOutcome {
        .failed
    }
}
