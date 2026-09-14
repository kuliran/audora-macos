@_spi(CoachContextQualification) @_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
import Foundation

/// The provider-specific transport admitted by Infrastructure qualification.
/// Configuration authority deliberately does not live on this interface: the
/// qualification bundle below owns that binding, so a transport cannot admit
/// itself by reporting configuration metadata about itself.
protocol QualifiedCoachProviderTransport: Sendable {
    func health() async -> CoachProviderHealth

    func run(
        request: CoachRequest,
        execution: ProviderAttemptMetadata,
        transcriptAccess: CoachTranscriptAccess?
    ) async throws -> CoachProviderCompleteResponse

    func cancelAndReap(
        attemptID: CoachProviderAttemptID,
        graceMilliseconds: Int64
    ) async -> CoachProviderAttemptCancellationOutcome
}

/// Immutable output of Coach-provider qualification. Only Infrastructure can
/// create one in production, binding the complete measured configuration to the
/// exact transport that qualification admitted.
struct QualifiedCoachProviderBundle: Sendable {
    let configuration: CoachProviderConfigurationBinding
    let transport: any QualifiedCoachProviderTransport

    init(
        configuration: CoachProviderConfigurationBinding,
        transport: any QualifiedCoachProviderTransport
    ) {
        self.configuration = configuration
        self.transport = transport
    }
}

/// Immutable output of transcription qualification. The worker transport and
/// acoustic-evidence transport share one exact profile authority, preventing
/// either gateway from independently declaring what it was qualified for.
struct QualifiedTranscriptionProviderBundle: Sendable {
    let profile: QualifiedTranscriptionProfile
    let workerHost: any ConfinedTranscriptionWorkerHost
    let acousticEvidence: any SessionAcousticEvidencePort

    init(
        profile: QualifiedTranscriptionProfile,
        workerHost: any ConfinedTranscriptionWorkerHost,
        acousticEvidence: any SessionAcousticEvidencePort
    ) {
        self.profile = profile
        self.workerHost = workerHost
        self.acousticEvidence = acousticEvidence
    }
}
