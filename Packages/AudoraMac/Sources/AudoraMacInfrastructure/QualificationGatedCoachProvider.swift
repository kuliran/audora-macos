@_spi(CoachContextQualification) @_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain

/// Stable production gateway between Application and the immutable bundle
/// produced by Coach-provider qualification. An empty gateway is intentionally
/// fail-closed; later provider adapters remain behind this same boundary.
@_spi(InvocationInfrastructure)
public struct QualificationGatedCoachProvider: CoachProvider {
    private let qualifiedBundle: QualifiedCoachProviderBundle?

    /// Shipping composition has no way to self-assert qualification.
    public init() {
        qualifiedBundle = nil
    }

    /// A qualification factory in this module may expose the already-gated
    /// value, never the bundle or its raw transport.
    init(qualifiedBundle: QualifiedCoachProviderBundle) {
        self.qualifiedBundle = qualifiedBundle
    }

    public func health() async -> CoachProviderHealth {
        guard let qualifiedBundle else { return .unavailable }
        return await qualifiedBundle.transport.health()
    }

    public func run(
        request: CoachRequest,
        execution: ProviderAttemptMetadata,
        transcriptAccess: CoachTranscriptAccess?
    ) async throws -> CoachProviderCompleteResponse {
        guard let qualifiedBundle,
              request.providerBinding == qualifiedBundle.configuration,
              await qualifiedBundle.transport.health() == .available
        else {
            throw CoachProviderRunError.userRetryableFailure
        }
        return try await qualifiedBundle.transport.run(
            request: request,
            execution: execution,
            transcriptAccess: transcriptAccess
        )
    }

    public func cancelAndReap(
        attemptID: CoachProviderAttemptID,
        graceMilliseconds: Int64
    ) async -> CoachProviderAttemptCancellationOutcome {
        guard let qualifiedBundle else { return .alreadyAbsent }
        return await qualifiedBundle.transport.cancelAndReap(
            attemptID: attemptID,
            graceMilliseconds: graceMilliseconds
        )
    }
}
