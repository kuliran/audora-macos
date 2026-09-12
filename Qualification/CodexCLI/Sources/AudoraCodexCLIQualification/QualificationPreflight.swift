import Foundation

enum CodexCLIQualificationCompatibilityMatrix {
    // Add only exact versions whose runtime config and same-process ephemeral
    // authorization channel have both been independently verified.
    static let verifiedCleanVersions: Set<String> = []
}

public enum CodexCLIQualificationCapabilityStatus: String, Codable, Equatable, Sendable {
    case verified
    case unsupported
    case unverified
}

public enum CodexCLIQualificationBlocker: String, Codable, Equatable, Sendable {
    case cliIdentityUnavailable
    case cliVersionUnverified
    case viewImageDisableUnsupported
    case viewImageDisableUnverified
    case sameProcessEphemeralAuthorizationUnsupported
    case sameProcessEphemeralAuthorizationUnverified
}

public enum CodexCLIQualificationManualAction: String, Codable, Equatable, Sendable {
    case installIndependentlyVerifiedCLI
    case provideDocumentedSameProcessEphemeralAuthorization
    case addExactVersionToCompatibilityMatrix
    case rerunPublicPreflight
}

public struct CodexCLIQualificationPreflightReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let cliVersion: String
    public let providerCasesLaunched: Int
    public let providerLaunchPermitted: Bool
    public let viewImageDisableStatus: CodexCLIQualificationCapabilityStatus
    public let ephemeralExecAuthorizationStatus: CodexCLIQualificationCapabilityStatus
    public let blockers: [CodexCLIQualificationBlocker]
    public let manualHandoff: [CodexCLIQualificationManualAction]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case cliVersion
        case providerCasesLaunched
        case providerLaunchPermitted
        case viewImageDisableStatus
        case ephemeralExecAuthorizationStatus
        case blockers
        case manualHandoff
    }

    init(cliVersion: String) {
        schemaVersion = 1
        self.cliVersion = QualificationCLIIdentity.sanitizedReportedVersion(cliVersion)
        providerCasesLaunched = 0

        switch self.cliVersion {
        case let version
            where CodexCLIQualificationCompatibilityMatrix.verifiedCleanVersions
                .contains(version):
            providerLaunchPermitted = true
            viewImageDisableStatus = .verified
            ephemeralExecAuthorizationStatus = .verified
            blockers = []
        case "codex 0.143.0", "codex-cli 0.143.0":
            providerLaunchPermitted = false
            viewImageDisableStatus = .unsupported
            ephemeralExecAuthorizationStatus = .unsupported
            blockers = [
                .viewImageDisableUnsupported,
                .sameProcessEphemeralAuthorizationUnsupported,
            ]
        case QualificationCLIIdentity.unavailable:
            providerLaunchPermitted = false
            viewImageDisableStatus = .unverified
            ephemeralExecAuthorizationStatus = .unverified
            blockers = [
                .cliIdentityUnavailable,
                .viewImageDisableUnverified,
                .sameProcessEphemeralAuthorizationUnverified,
            ]
        default:
            providerLaunchPermitted = false
            viewImageDisableStatus = .unverified
            ephemeralExecAuthorizationStatus = .unverified
            blockers = [
                .cliVersionUnverified,
                .viewImageDisableUnverified,
                .sameProcessEphemeralAuthorizationUnverified,
            ]
        }
        manualHandoff = providerLaunchPermitted ? [] : [
            .installIndependentlyVerifiedCLI,
            .provideDocumentedSameProcessEphemeralAuthorization,
            .addExactVersionToCompatibilityMatrix,
            .rerunPublicPreflight,
        ]
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        let decodedCLIVersion = try values.decode(String.self, forKey: .cliVersion)
        let expected = Self(cliVersion: decodedCLIVersion)
        guard
            decodedSchemaVersion == expected.schemaVersion,
            decodedCLIVersion == expected.cliVersion,
            try values.decode(Int.self, forKey: .providerCasesLaunched)
                == expected.providerCasesLaunched,
            try values.decode(Bool.self, forKey: .providerLaunchPermitted)
                == expected.providerLaunchPermitted,
            try values.decode(
                CodexCLIQualificationCapabilityStatus.self,
                forKey: .viewImageDisableStatus
            ) == expected.viewImageDisableStatus,
            try values.decode(
                CodexCLIQualificationCapabilityStatus.self,
                forKey: .ephemeralExecAuthorizationStatus
            ) == expected.ephemeralExecAuthorizationStatus,
            try values.decode(
                [CodexCLIQualificationBlocker].self,
                forKey: .blockers
            ) == expected.blockers,
            try values.decode(
                [CodexCLIQualificationManualAction].self,
                forKey: .manualHandoff
            ) == expected.manualHandoff
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .providerLaunchPermitted,
                in: values,
                debugDescription: "Qualification preflight fields contradict the probed identity."
            )
        }
        self = expected
    }
}
