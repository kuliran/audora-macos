import AudoraDomain

/// Exact immutable source whose engine-use policy governs material entering a
/// Coach request. Targets and display text are intentionally excluded: every
/// reference into one Transcript Revision carries the same source obligation.
@_spi(CoachContextQualification)
public struct CoachEvidencePolicySourceIdentity: Hashable, Sendable {
    public let sessionID: SessionID
    public let transcriptRevisionID: TranscriptRevisionID

    public init(
        sessionID: SessionID,
        transcriptRevisionID: TranscriptRevisionID
    ) {
        self.sessionID = sessionID
        self.transcriptRevisionID = transcriptRevisionID
    }

    init(_ evidence: EvidenceReference) {
        self.init(
            sessionID: evidence.sessionID,
            transcriptRevisionID: evidence.transcriptRevisionID
        )
    }
}

/// One identity-bound answer from local authoritative persistence. Returning an
/// ordered result with the identity prevents a malformed adapter from approving
/// one source by accidentally substituting another source's policy.
@_spi(CoachContextQualification)
public enum CoachEvidenceUsePolicyResolution: Equatable, Sendable {
    case resolved(
        source: CoachEvidencePolicySourceIdentity,
        policy: EngineUsePolicy
    )
    case unavailable(source: CoachEvidencePolicySourceIdentity)

    var source: CoachEvidencePolicySourceIdentity {
        switch self {
        case let .resolved(source, _), let .unavailable(source): source
        }
    }
}

/// Storage-facing policy lookup. Implementations reopen the exact immutable
/// Session/Transcript Revision pair; they never receive provider handles or
/// provider-facing transcript bytes.
@_spi(CoachContextQualification)
public protocol CoachEvidenceUsePolicySource: Sendable {
    func resolveUsePolicies(
        for sources: [CoachEvidencePolicySourceIdentity],
        in library: LibraryScope
    ) async -> [CoachEvidenceUsePolicyResolution]
}

/// Complete obligations of the active Profile snapshot supplied by a context
/// source. Construction deduplicates exact revision identity but never drops an
/// independently referenced source.
struct CoachProfileEvidenceObligations: Equatable, Sendable {
    let sources: [CoachEvidencePolicySourceIdentity]

    init(profile: ProfileSnapshot) {
        var seen: Set<CoachEvidencePolicySourceIdentity> = []
        var sources: [CoachEvidencePolicySourceIdentity] = []
        for statement in profile.statements {
            for evidence in statement.evidence {
                let source = CoachEvidencePolicySourceIdentity(evidence)
                if seen.insert(source).inserted {
                    sources.append(source)
                }
            }
        }
        self.sources = sources
    }

}

private struct UnavailableCoachEvidenceUsePolicySource:
    CoachEvidenceUsePolicySource
{
    func resolveUsePolicies(
        for sources: [CoachEvidencePolicySourceIdentity],
        in library: LibraryScope
    ) async -> [CoachEvidenceUsePolicyResolution] {
        sources.map(CoachEvidenceUsePolicyResolution.unavailable)
    }
}

/// Application-owned decision point immediately before Coach request planning.
/// Any missing, reordered, duplicated, or denied policy closes the whole request.
struct CoachExternalProcessingAuthorizer: Sendable {
    private let source: any CoachEvidenceUsePolicySource

    init(source: any CoachEvidenceUsePolicySource) {
        self.source = source
    }

    init(sourceIfAvailable: (any CoachEvidenceUsePolicySource)?) {
        source = sourceIfAvailable ?? UnavailableCoachEvidenceUsePolicySource()
    }

    init() {
        source = UnavailableCoachEvidenceUsePolicySource()
    }

    func unavailableReason(
        for obligations: CoachProfileEvidenceObligations,
        in library: LibraryScope
    ) async -> CoachContextUnavailableReason? {
        guard !obligations.sources.isEmpty else { return nil }

        let resolutions = await source.resolveUsePolicies(
            for: obligations.sources,
            in: library
        )
        guard resolutions.count == obligations.sources.count else {
            return .externalProcessingPolicyUnavailable
        }
        var policies: [EngineUsePolicy] = []
        policies.reserveCapacity(resolutions.count)
        for (expected, resolution) in zip(obligations.sources, resolutions) {
            guard resolution.source == expected else {
                return .externalProcessingPolicyUnavailable
            }
            switch resolution {
            case let .resolved(_, policy):
                policies.append(policy)
            case .unavailable:
                return .externalProcessingPolicyUnavailable
            }
        }
        return policies.allSatisfy(\.externalProcessingAllowed)
            ? nil
            : .externalProcessingDisallowed
    }
}
