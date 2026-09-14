@testable import AudoraApplication

extension CoachContextAuthorityLease {
    static var testNoop: CoachContextAuthorityLease {
        CoachContextAuthorityLease(release: {})
    }
}

extension CoachContextSnapshotPort {
    func acquireTestImmutableAuthorityLease(
        _ authority: CoachContextSourceLeaseAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        let current: Bool
        switch authority {
        case let .snapshot(snapshot):
            current = await isCurrent(snapshot)
        case let .configuration(generation):
            current = await isCurrentConfiguration(generation)
        }
        return current ? .acquired(.testNoop) : .stale
    }
}
