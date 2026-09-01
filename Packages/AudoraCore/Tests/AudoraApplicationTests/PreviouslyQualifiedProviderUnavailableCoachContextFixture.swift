@testable @_spi(CoachContextQualification) import AudoraApplication

/// Test-only model of a configuration that was genuinely qualified before its
/// provider transport became unavailable. Live composition must never create
/// this authority on its own.
struct PreviouslyQualifiedProviderUnavailableSnapshotPort:
    CoachContextSnapshotPort
{
    private let configurationGeneration: UInt64 = 7
    private let policy = try! CoachAttachmentProjectionPolicy(
        maximumInlineTranscriptTokens: 64,
        tokenEstimator: .utf8ByteUpperBound()
    )

    func resolveNewChat(
        _ request: CoachContextNewChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        .providerUnavailable
    }

    func resolveChat(
        _ request: CoachContextChatQuoteRequest
    ) async -> CoachContextSnapshotOutcome {
        .providerUnavailable
    }

    func resolvePendingUserTurn(
        _ request: CoachContextPendingTurnRequest
    ) async -> CoachContextSnapshotOutcome {
        .providerUnavailable
    }

    func isCurrent(_ authority: CoachContextSnapshotAuthority) async -> Bool {
        false
    }

    func currentAttachmentProjectionPolicy()
        async -> CoachAttachmentProjectionPolicyOutcome
    {
        .knownQualified(
            policy: policy,
            configurationGeneration: configurationGeneration
        )
    }

    func isCurrentConfiguration(_ candidate: UInt64) async -> Bool {
        candidate == configurationGeneration
    }

    func acquireAuthorityLease(
        _ authority: CoachContextSourceLeaseAuthority
    ) async -> CoachContextAuthorityLeaseOutcome {
        guard authority == .configuration(generation: configurationGeneration) else {
            return .stale
        }
        return .acquired(CoachContextAuthorityLease())
    }
}

func previouslyQualifiedProviderUnavailableCoachContextFixture()
    -> DefaultCoachContextFeature
{
    DefaultCoachContextFeature(
        source: PreviouslyQualifiedProviderUnavailableSnapshotPort()
    )
}
