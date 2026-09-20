import Foundation

enum QualificationCLIIdentity {
    static let unavailable = "unavailable"

    static func sanitizedReportedVersion(_ value: String) -> String {
        isCanonicalVersion(value) ? value : unavailable
    }

    static func normalizedProbeOutput(_ value: String) -> String {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = raw.split(whereSeparator: \Character.isWhitespace)
        guard
            components.count == 2,
            ["codex", "codex-cli"].contains(String(components[0]))
        else {
            return unavailable
        }

        let versionAndMetadata = components[1].split(
            separator: "+",
            omittingEmptySubsequences: false
        )
        guard
            versionAndMetadata.count == 1
                || (versionAndMetadata.count == 2
                    && isValidBuildMetadata(versionAndMetadata[1])),
            isNumericVersion(versionAndMetadata[0])
        else {
            return unavailable
        }
        return "\(components[0]) \(components[1])"
    }

    private static func isCanonicalVersion(_ value: String) -> Bool {
        if value == unavailable { return true }

        let components = value.split(
            separator: " ",
            omittingEmptySubsequences: false
        )
        return components.count == 2
            && ["codex", "codex-cli"].contains(String(components[0]))
            && isCanonicalVersionComponent(components[1])
    }

    private static func isCanonicalVersionComponent(_ value: Substring) -> Bool {
        let versionAndMetadata = value.split(
            separator: "+",
            omittingEmptySubsequences: false
        )
        return (versionAndMetadata.count == 1
            || (versionAndMetadata.count == 2
                && isValidBuildMetadata(versionAndMetadata[1])))
            && isNumericVersion(versionAndMetadata[0])
    }

    private static func isNumericVersion(_ value: Substring) -> Bool {
        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        return components.count == 3
            && components.allSatisfy({ component in
                (1 ... 9).contains(component.utf8.count)
                    && component.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) })
            })
    }

    private static func isValidBuildMetadata(_ value: Substring) -> Bool {
        value.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy({ identifier in
                !identifier.isEmpty
                    && identifier.utf8.allSatisfy({ byte in
                        (0x30 ... 0x39).contains(byte)
                            || (0x41 ... 0x5a).contains(byte)
                            || (0x61 ... 0x7a).contains(byte)
                            || byte == 0x2d
                    })
            })
    }
}

public struct QualificationLimits: Equatable, Sendable {
    public static let issueGateResponseByteCeiling = 4_096
    public static let issueGateOutputTokenCeiling = 4_096
    public static let issueGateEventStreamByteCeiling = 256 * 1_024
    public static let issueGateFailureSignalByteCeiling = 64 * 1_024
    public static let issueGateTimeoutSeconds: TimeInterval = 90
    public static let issueGateTerminationGraceSeconds: TimeInterval = 2

    public var responseByteCeiling: Int
    public var outputTokenCeiling: Int
    public var eventStreamByteCeiling: Int
    public var failureSignalByteCeiling: Int
    public var timeoutSeconds: TimeInterval
    public var terminationGraceSeconds: TimeInterval

    public init(
        responseByteCeiling: Int = QualificationLimits.issueGateResponseByteCeiling,
        outputTokenCeiling: Int = QualificationLimits.issueGateOutputTokenCeiling,
        eventStreamByteCeiling: Int = QualificationLimits.issueGateEventStreamByteCeiling,
        failureSignalByteCeiling: Int = QualificationLimits.issueGateFailureSignalByteCeiling,
        timeoutSeconds: TimeInterval = QualificationLimits.issueGateTimeoutSeconds,
        terminationGraceSeconds: TimeInterval = QualificationLimits.issueGateTerminationGraceSeconds
    ) {
        precondition(responseByteCeiling > 0)
        precondition(outputTokenCeiling > 0)
        precondition(eventStreamByteCeiling > 0)
        precondition(failureSignalByteCeiling > 0)
        precondition(timeoutSeconds.isFinite && timeoutSeconds > 0)
        precondition(terminationGraceSeconds.isFinite && terminationGraceSeconds >= 0)

        self.responseByteCeiling = responseByteCeiling
        self.outputTokenCeiling = outputTokenCeiling
        self.eventStreamByteCeiling = eventStreamByteCeiling
        self.failureSignalByteCeiling = failureSignalByteCeiling
        self.timeoutSeconds = timeoutSeconds
        self.terminationGraceSeconds = terminationGraceSeconds
    }

    var matchesIssueGateProfile: Bool {
        responseByteCeiling == Self.issueGateResponseByteCeiling
            && outputTokenCeiling == Self.issueGateOutputTokenCeiling
            && eventStreamByteCeiling == Self.issueGateEventStreamByteCeiling
            && failureSignalByteCeiling == Self.issueGateFailureSignalByteCeiling
            && timeoutSeconds == Self.issueGateTimeoutSeconds
            && terminationGraceSeconds == Self.issueGateTerminationGraceSeconds
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

struct SanitizedFailure: Equatable, Sendable {
    let reason: SanitizedFailureReason
    let processWasReaped: Bool
    let durationMilliseconds: Int

    init(
        reason: SanitizedFailureReason,
        processWasReaped: Bool,
        durationMilliseconds: Int
    ) {
        self.reason = reason
        self.processWasReaped = processWasReaped
        self.durationMilliseconds = durationMilliseconds
    }
}

struct QualifiedResponse: Equatable, Sendable {
    let responseByteCount: Int
    let outputTokenCount: Int
    let processWasReaped: Bool
    let durationMilliseconds: Int

    init(
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

enum CodexRunOutcome: Equatable, Sendable {
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

    fileprivate func isValidForSchemaTwo(
        responseByteCeiling: Int,
        outputTokenCeiling: Int
    ) -> Bool {
        guard durationMilliseconds >= 0, !containsRawStandardError else {
            return false
        }

        switch (responseByteCount, outputTokenCount) {
        case let (responseByteCount?, outputTokenCount?):
            guard
                responseByteCount > 0,
                responseByteCount <= responseByteCeiling,
                outputTokenCount >= 0,
                outputTokenCount <= outputTokenCeiling
            else {
                return false
            }
            if workspaceRemainedEmpty {
                guard observedReason == nil, retryDisposition == .none else {
                    return false
                }
            } else {
                guard
                    observedReason == .forbiddenCapabilityUsed,
                    retryDisposition == .user
                else {
                    return false
                }
            }
        case (nil, nil):
            guard
                let observedReason,
                retryDisposition == observedReason.retryDisposition
            else {
                return false
            }
        default:
            return false
        }

        return passed == qualifiesIssueGateCase
    }

    fileprivate var qualifiesIssueGateCase: Bool {
        guard
            processWasReaped,
            workspaceRemainedEmpty,
            !containsRawStandardError
        else {
            return false
        }

        switch name {
        case .structuredResponse:
            return responseByteCount.map({ $0 > 0 }) == true
                && outputTokenCount.map({ $0 >= 0 }) == true
                && observedReason == nil
                && retryDisposition == .none
        case .cancellation:
            return responseByteCount == nil
                && outputTokenCount == nil
                && observedReason == .cancelled
                && retryDisposition == .user
        case .timeout:
            return responseByteCount == nil
                && outputTokenCount == nil
                && observedReason == .timedOut
                && retryDisposition == .automatic
        }
    }
}

public struct QualificationSuiteReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let cliVersion: String
    public let model: String
    public let responseByteCeiling: Int?
    public let outputTokenCeiling: Int?
    public let eventStreamByteCeiling: Int?
    public let failureSignalByteCeiling: Int?
    public let timeoutSeconds: TimeInterval?
    public let terminationGraceSeconds: TimeInterval?
    public let modelFacingToolSurfaceQualified: Bool
    public let issueGateAccepted: Bool
    public let productionProviderQualified: Bool
    public let fullyQualifiedForProduction: Bool
    public let cases: [QualificationCaseReport]
    public let externalLimitations: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case cliVersion
        case model
        case responseByteCeiling
        case outputTokenCeiling
        case eventStreamByteCeiling
        case failureSignalByteCeiling
        case timeoutSeconds
        case terminationGraceSeconds
        case modelFacingToolSurfaceQualified
        case issueGateAccepted
        case productionProviderQualified
        case fullyQualifiedForProduction
        case cases
        case externalLimitations
    }

    public init(
        cases: [QualificationCaseReport],
        cliVersion: String = "unavailable",
        model: String = "unavailable",
        limits: QualificationLimits
    ) {
        schemaVersion = 2
        let sanitizedCLIVersion = QualificationCLIIdentity.sanitizedReportedVersion(
            cliVersion
        )
        let allowlistedModel = CodexInvocationPlanBuilder.allowlistedModels.contains(model)
            ? model
            : "unavailable"
        self.cliVersion = sanitizedCLIVersion
        self.model = allowlistedModel
        responseByteCeiling = limits.responseByteCeiling
        outputTokenCeiling = limits.outputTokenCeiling
        eventStreamByteCeiling = limits.eventStreamByteCeiling
        failureSignalByteCeiling = limits.failureSignalByteCeiling
        timeoutSeconds = limits.timeoutSeconds
        terminationGraceSeconds = limits.terminationGraceSeconds
        modelFacingToolSurfaceQualified = false
        issueGateAccepted = Self.derivedIssueGateAcceptance(
            cases: cases,
            cliVersion: sanitizedCLIVersion,
            model: allowlistedModel,
            responseByteCeiling: limits.responseByteCeiling,
            outputTokenCeiling: limits.outputTokenCeiling,
            eventStreamByteCeiling: limits.eventStreamByteCeiling,
            failureSignalByteCeiling: limits.failureSignalByteCeiling,
            timeoutSeconds: limits.timeoutSeconds,
            terminationGraceSeconds: limits.terminationGraceSeconds,
            modelFacingToolSurfaceQualified: modelFacingToolSurfaceQualified
        )
        productionProviderQualified = false
        fullyQualifiedForProduction = productionProviderQualified
        self.cases = cases
        externalLimitations = [
            "The qualified Codex CLI surface does not expose a provider-side max-output-token setting; the spike verifies reported usage and enforces a local byte collector ceiling.",
            "The shipping Codex CLI/model pair has no pinned exact tokenizer or documented complete model-framing count; the synthetic model-catalog context values are harness inputs, not a qualified context-window claim.",
            "The recorded Codex CLI 0.143 probe did not establish an exact model-facing tool allowlist for an independently verified build; current configuration documentation alone is not runtime qualification.",
            "Current Codex documentation defines same-process CODEX_ACCESS_TOKEN input, but no exact executable/runtime pair has been authorized and exercised from a clean isolated home.",
            "An entry-executable hash does not bind macOS code-signing or quarantine state, non-system dynamic libraries, runtime-loaded code, or helper executables; authorized execution remains unavailable until one complete runtime authority preserves and verifies those controls.",
            "The 20 September 2026 owner attestation records that the ChatGPT training control is off, but no qualification-bound provider data-use assurance currently binds its evidence hash to the exact shipping authentication/runtime configuration; until that binding exists, submitted content is not qualified as prohibited from training or model-improvement use.",
        ]
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        guard decodedSchemaVersion == 1 || decodedSchemaVersion == 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported qualification report schema."
            )
        }

        let decodedCases = try values.decode(
            [QualificationCaseReport].self,
            forKey: .cases
        )
        let decodedLimitations = try values.decode(
            [String].self,
            forKey: .externalLimitations
        )
        schemaVersion = decodedSchemaVersion
        cases = decodedCases
        externalLimitations = decodedLimitations

        if decodedSchemaVersion == 1 {
            cliVersion = "unavailable"
            model = "unavailable"
            responseByteCeiling = nil
            outputTokenCeiling = nil
            eventStreamByteCeiling = nil
            failureSignalByteCeiling = nil
            timeoutSeconds = nil
            terminationGraceSeconds = nil
            modelFacingToolSurfaceQualified = false
            issueGateAccepted = false
            productionProviderQualified = false
            fullyQualifiedForProduction = false
            return
        }

        let decodedResponseByteCeiling = try values.decode(
            Int.self,
            forKey: .responseByteCeiling
        )
        let decodedOutputTokenCeiling = try values.decode(
            Int.self,
            forKey: .outputTokenCeiling
        )
        let decodedEventStreamByteCeiling = try values.decode(
            Int.self,
            forKey: .eventStreamByteCeiling
        )
        let decodedFailureSignalByteCeiling = try values.decode(
            Int.self,
            forKey: .failureSignalByteCeiling
        )
        let decodedTimeoutSeconds = try values.decode(
            TimeInterval.self,
            forKey: .timeoutSeconds
        )
        let decodedTerminationGraceSeconds = try values.decode(
            TimeInterval.self,
            forKey: .terminationGraceSeconds
        )
        let decodedModelFacingToolSurfaceQualified = try values.decode(
            Bool.self,
            forKey: .modelFacingToolSurfaceQualified
        )
        guard
            decodedResponseByteCeiling > 0,
            decodedOutputTokenCeiling > 0,
            decodedEventStreamByteCeiling > 0,
            decodedFailureSignalByteCeiling > 0,
            decodedTimeoutSeconds.isFinite,
            decodedTimeoutSeconds > 0,
            decodedTerminationGraceSeconds.isFinite,
            decodedTerminationGraceSeconds >= 0,
            !decodedModelFacingToolSurfaceQualified,
            decodedCases.allSatisfy({
                $0.isValidForSchemaTwo(
                    responseByteCeiling: decodedResponseByteCeiling,
                    outputTokenCeiling: decodedOutputTokenCeiling
                )
            })
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .cases,
                in: values,
                debugDescription: "Qualification case fields contradict their outcome."
            )
        }

        let decodedCLIVersion = try values.decode(String.self, forKey: .cliVersion)
        let decodedModel = try values.decode(String.self, forKey: .model)
        guard
            QualificationCLIIdentity.sanitizedReportedVersion(decodedCLIVersion)
                == decodedCLIVersion,
            decodedModel == "unavailable"
                || CodexInvocationPlanBuilder.allowlistedModels.contains(decodedModel)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .cliVersion,
                in: values,
                debugDescription: "Qualification identity is not allowlisted."
            )
        }
        let derivedIssueGateAccepted = Self.derivedIssueGateAcceptance(
            cases: decodedCases,
            cliVersion: decodedCLIVersion,
            model: decodedModel,
            responseByteCeiling: decodedResponseByteCeiling,
            outputTokenCeiling: decodedOutputTokenCeiling,
            eventStreamByteCeiling: decodedEventStreamByteCeiling,
            failureSignalByteCeiling: decodedFailureSignalByteCeiling,
            timeoutSeconds: decodedTimeoutSeconds,
            terminationGraceSeconds: decodedTerminationGraceSeconds,
            modelFacingToolSurfaceQualified: decodedModelFacingToolSurfaceQualified
        )
        let encodedIssueGateAccepted = try values.decode(
            Bool.self,
            forKey: .issueGateAccepted
        )
        let encodedProductionQualified = try values.decode(
            Bool.self,
            forKey: .productionProviderQualified
        )
        let encodedLegacyQualified = try values.decode(
            Bool.self,
            forKey: .fullyQualifiedForProduction
        )
        guard
            encodedIssueGateAccepted == derivedIssueGateAccepted,
            !encodedProductionQualified,
            encodedLegacyQualified == encodedProductionQualified
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .issueGateAccepted,
                in: values,
                debugDescription: "Qualification decisions contradict their payload."
            )
        }

        cliVersion = decodedCLIVersion
        model = decodedModel
        responseByteCeiling = decodedResponseByteCeiling
        outputTokenCeiling = decodedOutputTokenCeiling
        eventStreamByteCeiling = decodedEventStreamByteCeiling
        failureSignalByteCeiling = decodedFailureSignalByteCeiling
        timeoutSeconds = decodedTimeoutSeconds
        terminationGraceSeconds = decodedTerminationGraceSeconds
        modelFacingToolSurfaceQualified = decodedModelFacingToolSurfaceQualified
        issueGateAccepted = derivedIssueGateAccepted
        productionProviderQualified = false
        fullyQualifiedForProduction = false
    }

    private static func derivedIssueGateAcceptance(
        cases: [QualificationCaseReport],
        cliVersion: String,
        model: String,
        responseByteCeiling: Int,
        outputTokenCeiling: Int,
        eventStreamByteCeiling: Int,
        failureSignalByteCeiling: Int,
        timeoutSeconds: TimeInterval,
        terminationGraceSeconds: TimeInterval,
        modelFacingToolSurfaceQualified: Bool
    ) -> Bool {
        let limits = QualificationLimits(
            responseByteCeiling: responseByteCeiling,
            outputTokenCeiling: outputTokenCeiling,
            eventStreamByteCeiling: eventStreamByteCeiling,
            failureSignalByteCeiling: failureSignalByteCeiling,
            timeoutSeconds: timeoutSeconds,
            terminationGraceSeconds: terminationGraceSeconds
        )

        return modelFacingToolSurfaceQualified
            && limits.matchesIssueGateProfile
            && cliVersion != "unavailable"
            && CodexInvocationPlanBuilder.allowlistedModels.contains(model)
            && cases.count == QualificationCase.allCases.count
            && Set(cases.map(\.name)) == Set(QualificationCase.allCases)
            && cases.allSatisfy({
                $0.isValidForSchemaTwo(
                    responseByteCeiling: responseByteCeiling,
                    outputTokenCeiling: outputTokenCeiling
                )
            })
            && cases.allSatisfy(\.qualifiesIssueGateCase)
    }

}

public enum QualificationCommandExitPolicy {
    public static func succeeded(
        report: QualificationSuiteReport,
        ranFullSuite: Bool
    ) -> Bool {
        if ranFullSuite {
            return report.issueGateAccepted
        }
        return report.cases.allSatisfy(\.passed)
    }
}
