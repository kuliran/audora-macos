import Foundation

public struct QualificationLimits: Equatable, Sendable {
    public var responseByteCeiling: Int
    public var outputTokenCeiling: Int
    public var eventStreamByteCeiling: Int
    public var failureSignalByteCeiling: Int
    public var timeoutSeconds: TimeInterval
    public var terminationGraceSeconds: TimeInterval

    public init(
        responseByteCeiling: Int = 4_096,
        outputTokenCeiling: Int = 4_096,
        eventStreamByteCeiling: Int = 256 * 1_024,
        failureSignalByteCeiling: Int = 64 * 1_024,
        timeoutSeconds: TimeInterval = 90,
        terminationGraceSeconds: TimeInterval = 2
    ) {
        precondition(responseByteCeiling > 0)
        precondition(outputTokenCeiling > 0)
        precondition(eventStreamByteCeiling > 0)
        precondition(failureSignalByteCeiling > 0)
        precondition(timeoutSeconds > 0)
        precondition(terminationGraceSeconds >= 0)

        self.responseByteCeiling = responseByteCeiling
        self.outputTokenCeiling = outputTokenCeiling
        self.eventStreamByteCeiling = eventStreamByteCeiling
        self.failureSignalByteCeiling = failureSignalByteCeiling
        self.timeoutSeconds = timeoutSeconds
        self.terminationGraceSeconds = terminationGraceSeconds
    }
}

public enum RetryDisposition: String, Codable, Equatable, Sendable {
    case automatic
    case user
    case none
}

public enum SanitizedFailureReason: String, Codable, Equatable, Sendable {
    case authentication
    case quota
    case transient
    case unavailableModel
    case malformedOutput
    case processFailure
    case responseByteLimit
    case outputTokenLimit
    case forbiddenCapabilityUsed
    case cancelled
    case timedOut

    public var retryDisposition: RetryDisposition {
        switch self {
        case .transient, .timedOut:
            .automatic
        case .authentication, .quota, .unavailableModel, .malformedOutput,
             .processFailure, .responseByteLimit, .outputTokenLimit,
             .forbiddenCapabilityUsed, .cancelled:
            .user
        }
    }

    public var displayMessage: String {
        switch self {
        case .authentication:
            "Codex authentication is unavailable."
        case .quota:
            "Codex quota is unavailable."
        case .transient:
            "The coach provider is temporarily unavailable."
        case .unavailableModel:
            "The configured coach model is unavailable."
        case .malformedOutput, .responseByteLimit, .outputTokenLimit:
            "The coach returned an incomplete or invalid response."
        case .processFailure, .forbiddenCapabilityUsed:
            "The coach provider could not complete the request."
        case .cancelled, .timedOut:
            "Coach response was interrupted."
        }
    }
}

public struct SanitizedFailure: Equatable, Sendable {
    public let reason: SanitizedFailureReason
    public let processWasReaped: Bool
    public let durationMilliseconds: Int

    public init(
        reason: SanitizedFailureReason,
        processWasReaped: Bool,
        durationMilliseconds: Int
    ) {
        self.reason = reason
        self.processWasReaped = processWasReaped
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct QualifiedResponse: Equatable, Sendable {
    public let responseByteCount: Int
    public let outputTokenCount: Int
    public let processWasReaped: Bool
    public let durationMilliseconds: Int

    public init(
        responseByteCount: Int,
        outputTokenCount: Int,
        processWasReaped: Bool,
        durationMilliseconds: Int
    ) {
        self.responseByteCount = responseByteCount
        self.outputTokenCount = outputTokenCount
        self.processWasReaped = processWasReaped
        self.durationMilliseconds = durationMilliseconds
    }
}

public enum CodexRunOutcome: Equatable, Sendable {
    case success(QualifiedResponse)
    case failure(SanitizedFailure)
}

public enum QualificationCase: String, CaseIterable, Codable, Sendable {
    case structuredResponse
    case cancellation
    case timeout
}

public struct QualificationCaseReport: Codable, Equatable, Sendable {
    public let name: QualificationCase
    public let passed: Bool
    public let observedReason: SanitizedFailureReason?
    public let retryDisposition: RetryDisposition
    public let responseByteCount: Int?
    public let outputTokenCount: Int?
    public let processWasReaped: Bool
    public let workspaceRemainedEmpty: Bool
    public let durationMilliseconds: Int
    public let containsRawStandardError: Bool

    public init(
        name: QualificationCase,
        passed: Bool,
        observedReason: SanitizedFailureReason?,
        retryDisposition: RetryDisposition,
        responseByteCount: Int?,
        outputTokenCount: Int?,
        processWasReaped: Bool,
        workspaceRemainedEmpty: Bool,
        durationMilliseconds: Int
    ) {
        self.name = name
        self.passed = passed
        self.observedReason = observedReason
        self.retryDisposition = retryDisposition
        self.responseByteCount = responseByteCount
        self.outputTokenCount = outputTokenCount
        self.processWasReaped = processWasReaped
        self.workspaceRemainedEmpty = workspaceRemainedEmpty
        self.durationMilliseconds = durationMilliseconds
        containsRawStandardError = false
    }
}

public struct QualificationSuiteReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let fullyQualifiedForProduction: Bool
    public let cases: [QualificationCaseReport]
    public let externalLimitations: [String]

    public init(cases: [QualificationCaseReport]) {
        schemaVersion = 1
        fullyQualifiedForProduction = false
        self.cases = cases
        externalLimitations = [
            "Codex CLI 0.143.0 does not expose a provider-side max-output-token setting; the spike verifies reported usage and enforces a local byte collector ceiling.",
            "The shipping Codex CLI/model pair has no pinned exact tokenizer or documented complete model-framing count; the synthetic model-catalog context values are harness inputs, not a qualified context-window claim.",
            "Codex CLI 0.143.0 still advertises core plan and text-model-disabled view_image entries, so its model-facing tool list cannot yet be reduced to exactly Audora's optional transcript read.",
            "Authentication, quota, and transient mappings are covered with synthetic process fixtures; real account failures are not manufactured or inspected.",
        ]
    }
}
