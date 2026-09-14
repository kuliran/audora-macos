@testable @_spi(CoachContextQualification) @_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
import Foundation

struct RecordedCoachProviderExchange: Sendable {
    let request: Data
    let transcriptHandles: [CoachProviderTranscriptHandle]
}

/// Test-only joined view of the production port's deliberately separate
/// request, execution, and transcript-access arguments.
struct RecordedCoachProviderCall: Sendable {
    let request: CoachRequest
    let execution: ProviderAttemptMetadata
    let transcriptAccess: CoachTranscriptAccess?

    var attemptID: CoachProviderAttemptID { execution.attemptID }
    var attemptOrdinal: UInt8 { execution.attemptOrdinal }
    var attemptKind: CoachProviderAttemptKind { execution.attemptKind }
    var providerIdempotencyValue: ProviderIdempotencyValue {
        execution.providerIdempotencyValue
    }
    var exchange: RecordedCoachProviderExchange {
        RecordedCoachProviderExchange(
            request: request.body,
            transcriptHandles: transcriptAccess?.handles ?? []
        )
    }
    var outputTokenCeiling: Int { request.outputTokenCeiling }
    var pinnedInstruction: String { request.pinnedInstruction }
    var control: CoachProviderAttemptControl { execution.control }
}

extension CoachProvider {
    func health() async -> CoachProviderHealth { .available }
}

extension CoachProviderCompleteResponse {
    static func singleMarkdown(_ markdown: String) -> Self {
        CoachProviderCompleteResponse(
            body: CanonicalJSON.serialize(
                .object([
                    "messageBlocks": .array([
                        .object([
                            "kind": .string("markdown"),
                            "markdown": .string(markdown),
                        ]),
                    ]),
                ])
            )
        )
    }
}

extension CoachProviderAttemptOutcome {
    static func complete(markdown: String) -> Self {
        .complete(.singleMarkdown(markdown))
    }
}

func resolveScriptedCoachProviderOutcome(
    _ outcome: CoachProviderAttemptOutcome
) throws -> CoachProviderCompleteResponse {
    switch outcome {
    case let .complete(response):
        response
    case .autoRetryableFailure:
        throw CoachProviderRunError.autoRetryableFailure
    case .userRetryableFailure:
        throw CoachProviderRunError.userRetryableFailure
    case .responseOverflow:
        throw CoachProviderRunError.responseOverflow
    }
}

extension AttemptTranscriptAvailabilitySource {
    static let testAllAvailable = AttemptTranscriptAvailabilitySource(
        batchImplementation: { queries in
            Array(repeating: .available, count: queries.count)
        }
    )
}

extension AttemptTranscriptAvailabilityChecker {
    static let testAllAvailable = AttemptTranscriptAvailabilityChecker(
        batchImplementation: { sources in
            Array(repeating: .available, count: sources.count)
        }
    )
}

extension AttemptTranscriptAccessGrantIssuer {
    func issue(
        exchange: CanonicalCoachExchange,
        freshHandles: [PreparedCoachTranscriptHandle],
        pinnedInstruction: String? = nil,
        limits: AttemptTranscriptAccessLimits = AttemptTranscriptAccessLimits()
    ) throws -> AttemptTranscriptAccessGrant {
        try issue(
            exchange: exchange,
            freshHandles: freshHandles,
            pinnedInstruction: pinnedInstruction,
            availabilityChecker: .testAllAvailable,
            limits: limits
        )
    }
}
