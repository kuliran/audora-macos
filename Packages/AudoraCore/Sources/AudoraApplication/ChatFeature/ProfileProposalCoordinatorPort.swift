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

public enum ProfileReconsiderationFailureMutationError:
    Error,
    Equatable,
    Sendable
{
    case effectMismatch
    case failureRequired
}

public struct DiscardProfileReconsiderationFailureMutation:
    Equatable,
    Sendable
{
    public let library: LibraryScope
    public let base: ChatAggregate
    public let sourceEffectIdentity: ChatProfileEffectIdentity
    public let discardedAt: UTCInstant

    public init(
        library: LibraryScope,
        base: ChatAggregate,
        sourceEffectIdentity: ChatProfileEffectIdentity,
        discardedAt: UTCInstant
    ) throws {
        guard base.profileEffect?.identity == sourceEffectIdentity,
              base.profileReconsideration?.sourceEffectIdentity ==
                sourceEffectIdentity
        else {
            throw ProfileReconsiderationFailureMutationError.effectMismatch
        }
        guard base.profileReconsideration?.failure != nil else {
            throw ProfileReconsiderationFailureMutationError.failureRequired
        }
        self.library = library
        self.base = base
        self.sourceEffectIdentity = sourceEffectIdentity
        self.discardedAt = discardedAt
    }
}

/// The common result of every local Chat/Profile effect transaction. Keeping one
/// result vocabulary makes it impossible for semantic proposals and evidence
/// publications to drift into subtly different failure handling.
public enum ProfileEffectMutationOutcome: Equatable, Sendable {
    case committed(ChatAggregate)
    case stale(ChatAggregate)
    case readOnlyLibrary
    case failed
}

public typealias ProfileProposalMutationOutcome = ProfileEffectMutationOutcome
public typealias ProfileEvidencePublicationMutationOutcome =
    ProfileEffectMutationOutcome

public enum ProfileEffectAssessmentError: Error, Equatable, Sendable {
    case effectMismatch
}

/// Requests an authoritative comparison between one exact Chat-owned effect and
/// the current Profile. The coordinator may reconcile local Profile transaction
/// recovery before it returns, so callers always install the returned aggregate.
public struct AssessProfileEffectRequest: Equatable, Sendable {
    public let library: LibraryScope
    public let base: ChatAggregate
    public let sourceEffectIdentity: ChatProfileEffectIdentity

    public init(
        library: LibraryScope,
        base: ChatAggregate,
        sourceEffectIdentity: ChatProfileEffectIdentity
    ) throws {
        guard base.profileEffect?.identity == sourceEffectIdentity else {
            throw ProfileEffectAssessmentError.effectMismatch
        }
        self.library = library
        self.base = base
        self.sourceEffectIdentity = sourceEffectIdentity
    }
}

public enum ProfileEffectAssessmentOutcome: Equatable, Sendable {
    /// The effect can still use its ordinary local Accept/publication path.
    case current(ChatAggregate)
    /// The exact effect must be reconsidered against this complete derived basis.
    case stale(ChatAggregate, ProfileReconsiderationBasis)
    case readOnlyLibrary
    case failed
}

public protocol ProfileEffectCoordinating: Sendable {
    func assess(
        _ request: AssessProfileEffectRequest
    ) async -> ProfileEffectAssessmentOutcome

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

    func discardReconsiderationFailure(
        _ mutation: DiscardProfileReconsiderationFailureMutation
    ) async -> ProfileEffectMutationOutcome
}

/// Source-compatible name retained for callers compiled against the proposal-only
/// slice. New code should use `ProfileEffectCoordinating`.
public typealias ProfileProposalCoordinating = ProfileEffectCoordinating

public struct UnavailableProfileEffectCoordinator:
    ProfileEffectCoordinating
{
    public init() {}

    public func assess(
        _ request: AssessProfileEffectRequest
    ) async -> ProfileEffectAssessmentOutcome {
        .failed
    }

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

    public func discardReconsiderationFailure(
        _ mutation: DiscardProfileReconsiderationFailureMutation
    ) async -> ProfileEffectMutationOutcome {
        .failed
    }
}

public typealias UnavailableProfileProposalCoordinator =
    UnavailableProfileEffectCoordinator
