import AudoraDomain
import Foundation

/// Health reported by a configured Coach provider adapter. Provider prose and
/// transport diagnostics never cross this boundary.
@_spi(InvocationInfrastructure)
public enum CoachProviderHealth: Equatable, Sendable {
    case available
    case unavailable
}

/// Closed provider failures normalized by Infrastructure before they reach the
/// Application coordinator.
@_spi(InvocationInfrastructure)
public enum CoachProviderRunError: Error, Equatable, Sendable {
    case autoRetryableFailure
    case userRetryableFailure
    case responseOverflow
}

/// A complete provider result. The bytes remain opaque until Application runs
/// the whole-response trust gate.
@_spi(InvocationInfrastructure)
public struct CoachProviderCompleteResponse:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let body: Data

    public init(body: Data) {
        self.body = body
    }

    public var description: String { "<redacted Coach provider response>" }
    public var debugDescription: String { description }
}

/// The exact bounded semantic request plus launch instruction selected by
/// Application. Infrastructure may frame these values for its qualified
/// transport but must not reconstruct or supplement the semantic request.
@_spi(InvocationInfrastructure)
public struct CoachRequest:
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let body: Data
    public let outputTokenCeiling: Int
    public let pinnedInstruction: String
    /// Exact qualified configuration used to measure `body`. The production
    /// gateway sends bytes only when this matches its qualification-owned bundle.
    public let providerBinding: CoachProviderConfigurationBinding

    public init(
        body: Data,
        outputTokenCeiling: Int,
        pinnedInstruction: String,
        providerBinding: CoachProviderConfigurationBinding
    ) {
        self.body = body
        self.outputTokenCeiling = outputTokenCeiling
        self.pinnedInstruction = pinnedInstruction
        self.providerBinding = providerBinding
    }

    public var description: String { "<redacted Coach request>" }
    public var debugDescription: String { description }
}

/// Durable Attempt authority supplied separately from model-visible request
/// bytes. None of these values may be included in diagnostics or provider
/// context except through the adapter's qualified transport controls.
@_spi(InvocationInfrastructure)
public struct ProviderAttemptMetadata:
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let attemptID: CoachProviderAttemptID
    public let attemptOrdinal: UInt8
    public let attemptKind: CoachProviderAttemptKind
    public let providerIdempotencyValue: ProviderIdempotencyValue
    public let control: CoachProviderAttemptControl

    public init(
        attemptID: CoachProviderAttemptID,
        attemptOrdinal: UInt8,
        attemptKind: CoachProviderAttemptKind,
        providerIdempotencyValue: ProviderIdempotencyValue,
        control: CoachProviderAttemptControl
    ) {
        self.attemptID = attemptID
        self.attemptOrdinal = attemptOrdinal
        self.attemptKind = attemptKind
        self.providerIdempotencyValue = providerIdempotencyValue
        self.control = control
    }

    public var description: String {
        "<redacted provider Attempt metadata>"
    }

    public var debugDescription: String { description }
}

@_spi(InvocationInfrastructure)
public enum CoachProviderAttemptControl: Equatable, Sendable {
    case standard
    case shorterRepair(instruction: String)
}

@_spi(InvocationInfrastructure)
public enum CoachProviderAttemptCancellationOutcome: Equatable, Sendable {
    case reaped
    case alreadyAbsent
    case unableToConfirm
}

/// The sole provider-dependent outbound port. Application owns request
/// preparation, transcript disclosure authority, retry policy, validation, and
/// publication; Infrastructure owns only the qualified provider transport.
@_spi(InvocationInfrastructure)
public protocol CoachProvider: Sendable {
    func health() async -> CoachProviderHealth

    func run(
        request: CoachRequest,
        execution: ProviderAttemptMetadata,
        transcriptAccess: CoachTranscriptAccess?
    ) async throws -> CoachProviderCompleteResponse

    /// Idempotently requests cooperative cancellation, then force-terminates
    /// and reaps the exact Attempt within the supplied grace bound. Success is
    /// returned only after process absence is proven.
    func cancelAndReap(
        attemptID: CoachProviderAttemptID,
        graceMilliseconds: Int64
    ) async -> CoachProviderAttemptCancellationOutcome
}
