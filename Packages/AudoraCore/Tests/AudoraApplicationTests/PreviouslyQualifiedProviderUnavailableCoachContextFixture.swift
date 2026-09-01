@testable @_spi(CoachContextQualification) import AudoraApplication
import AudoraDomain

/// Test-only model of a configuration that was genuinely qualified before its
/// provider transport became unavailable. Live composition must never create
/// this authority on its own.
struct PreviouslyQualifiedProviderUnavailableSnapshotPort:
    CoachContextSnapshotPort
{
    private let configurationGeneration: UInt64 = 7
    private let configuration = previouslyQualifiedProviderUnavailableConfiguration()

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

    func currentQualifiedConfiguration()
        async -> CoachQualifiedConfigurationOutcome
    {
        .knownQualified(
            configuration: configuration,
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

func previouslyQualifiedProviderUnavailableCapacityLowerBound()
    -> ChatCreationCapacityLowerBound
{
    try! CoachContextCapacity().lowerBoundNewChat(
        creation: try! ChatCreation(
            kind: .newChat,
            originAttachmentID: nil,
            attachments: .empty
        ),
        attachments: [],
        configuration: previouslyQualifiedProviderUnavailableConfiguration()
    )
}

/// Test adapters in this target own their attachment source separately from the
/// base Coach context. Recover only the base's provider-outage classification;
/// the adapter remains responsible for projecting the selected attachments.
func fixtureNewChatQuotePreservingProviderOutage(
    from base: any CoachContextCoordinating,
    request: CoachContextNewChatQuoteRequest
) async -> ChatCreationQuoteOutcome {
    let outcome = await base.quoteNewChat(request)
    guard outcome == .unavailable(.sourceUnavailable),
          !request.attachments.values.isEmpty,
          let emptyRequest = try? CoachContextNewChatQuoteRequest(
              library: request.library,
              attachments: .empty,
              creationKind: request.creation.kind
          )
    else {
        return outcome
    }
    let providerProbe = await base.quoteNewChat(emptyRequest)
    return providerProbe == .unavailable(.providerUnavailable)
        ? providerProbe
        : outcome
}

private func previouslyQualifiedProviderUnavailableConfiguration()
    -> CoachContextConfiguration
{
    try! CoachContextConfiguration(
        descriptor: CoachProviderDescriptor(
            displayName: "Previously qualified unavailable fixture",
            contextBudget: CoachContextBudget(
                contextWindowTokens: 100_000,
                responseReservedTokens: 32,
                safetyMarginTokens: 8
            ),
            coachMemoryMaxTokens: 1
        ),
        policy: CoachProviderEstimationPolicy(
            providerIdentifier: "previously-qualified-unavailable-v1",
            responseCollectorByteCeiling: 8_192,
            framing: CoachProviderFraming(),
            attachmentProjectionPolicy: try! CoachAttachmentProjectionPolicy(
                maximumInlineTranscriptTokens: 64,
                tokenEstimator: .utf8ByteUpperBound()
            )
        )
    )
}

func previouslyQualifiedProviderUnavailableCoachContextFixture()
    -> DefaultCoachContextFeature
{
    DefaultCoachContextFeature(
        source: PreviouslyQualifiedProviderUnavailableSnapshotPort()
    )
}
