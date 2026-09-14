import Foundation

enum CodexCLIQualificationCompatibilityMatrix {
    struct VerifiedRuntime: Hashable, Sendable {
        let cliVersion: String
        let executableSHA256: String
        let runtimeAuthorityIdentity: CodexCLIQualificationRuntimeAuthorityIdentity
    }

    // Empty by design. A future entry is only one half of the gate: the current
    // process must also hold a matching live proof from the runtime authority.
    // Version and entry-file hash membership can never authorize execution alone.
    static let verifiedRuntimes: Set<VerifiedRuntime> = []
}

public enum CodexCLIQualificationCapabilityStatus: String, Codable, Equatable, Sendable {
    case verified
    case unsupported
    case unverified
}

public enum CodexCLIQualificationBlocker: String, Codable, Equatable, Sendable {
    case cliIdentityUnavailable
    case cliVersionUnverified
    case executableRuntimeIdentityUnverified
    case viewImageDisableUnsupported
    case viewImageDisableUnverified
    case sameProcessEphemeralAuthorizationUnsupported
    case sameProcessEphemeralAuthorizationUnverified
}

public enum CodexCLIQualificationManualAction: String, Codable, Equatable, Sendable {
    case installIndependentlyVerifiedCLI
    case provideDocumentedSameProcessEphemeralAuthorization
    case addExactVersionToCompatibilityMatrix
    case implementVerifiedExecutableRuntime
    case rerunPublicPreflight
}

public struct CodexCLIQualificationPreflightReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let cliVersion: String
    public let executableSHA256: String
    public let providerCasesLaunched: Int
    public let providerLaunchPermitted: Bool
    public let viewImageDisableStatus: CodexCLIQualificationCapabilityStatus
    public let ephemeralExecAuthorizationStatus: CodexCLIQualificationCapabilityStatus
    public let blockers: [CodexCLIQualificationBlocker]
    public let manualHandoff: [CodexCLIQualificationManualAction]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case cliVersion
        case executableSHA256
        case providerCasesLaunched
        case providerLaunchPermitted
        case viewImageDisableStatus
        case ephemeralExecAuthorizationStatus
        case blockers
        case manualHandoff
    }

    init(
        cliVersion: String,
        executableSHA256: String = "unavailable",
        executableIdentity: CodexCLIExecutableArtifact.Identity?,
        runtimeAuthorityProof: CodexCLIQualificationRuntimeAuthorityProof?,
        verifiedRuntimes: Set<CodexCLIQualificationCompatibilityMatrix.VerifiedRuntime>
            = CodexCLIQualificationCompatibilityMatrix.verifiedRuntimes
    ) {
        schemaVersion = 2
        let sanitizedCLIVersion = QualificationCLIIdentity.sanitizedReportedVersion(
            cliVersion
        )
        let sanitizedExecutableSHA256 = Self.sanitizedSHA256(executableSHA256)
        self.cliVersion = sanitizedCLIVersion
        self.executableSHA256 = sanitizedExecutableSHA256
        providerCasesLaunched = 0

        let verifiedRuntime = runtimeAuthorityProof.map {
            CodexCLIQualificationCompatibilityMatrix.VerifiedRuntime(
                cliVersion: sanitizedCLIVersion,
                executableSHA256: sanitizedExecutableSHA256,
                runtimeAuthorityIdentity: $0.runtimeIdentity
            )
        }
        let exactRuntimeVerified = sanitizedCLIVersion
            != QualificationCLIIdentity.unavailable
            && sanitizedExecutableSHA256 != QualificationCLIIdentity.unavailable
            && executableIdentity?.sha256 == sanitizedExecutableSHA256
            && executableIdentity.map { identity in
                runtimeAuthorityProof?.binds(
                    cliVersion: sanitizedCLIVersion,
                    executableIdentity: identity
                ) == true
            } == true
            && verifiedRuntime.map(verifiedRuntimes.contains) == true
        if exactRuntimeVerified {
            providerLaunchPermitted = true
            viewImageDisableStatus = .verified
            ephemeralExecAuthorizationStatus = .verified
            blockers = []
        } else if ["codex 0.143.0", "codex-cli 0.143.0"]
            .contains(self.cliVersion)
        {
            providerLaunchPermitted = false
            viewImageDisableStatus = .unsupported
            ephemeralExecAuthorizationStatus = .unverified
            blockers = [
                .viewImageDisableUnsupported,
                .sameProcessEphemeralAuthorizationUnverified,
                .executableRuntimeIdentityUnverified,
            ]
        } else if self.cliVersion == QualificationCLIIdentity.unavailable {
            providerLaunchPermitted = false
            viewImageDisableStatus = .unverified
            ephemeralExecAuthorizationStatus = .unverified
            blockers = [
                .cliIdentityUnavailable,
                .viewImageDisableUnverified,
                .sameProcessEphemeralAuthorizationUnverified,
                .executableRuntimeIdentityUnverified,
            ]
        } else {
            providerLaunchPermitted = false
            viewImageDisableStatus = .unverified
            ephemeralExecAuthorizationStatus = .unverified
            blockers = [
                .cliVersionUnverified,
                .viewImageDisableUnverified,
                .sameProcessEphemeralAuthorizationUnverified,
                .executableRuntimeIdentityUnverified,
            ]
        }
        manualHandoff = providerLaunchPermitted ? [] : [
            .installIndependentlyVerifiedCLI,
            .provideDocumentedSameProcessEphemeralAuthorization,
            .implementVerifiedExecutableRuntime,
            .addExactVersionToCompatibilityMatrix,
            .rerunPublicPreflight,
        ]
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        let decodedCLIVersion = try values.decode(String.self, forKey: .cliVersion)
        let decodedExecutableSHA256 = try values.decode(
            String.self,
            forKey: .executableSHA256
        )
        let expected = Self(
            cliVersion: decodedCLIVersion,
            executableSHA256: decodedExecutableSHA256,
            executableIdentity: nil,
            runtimeAuthorityProof: nil
        )
        guard
            decodedSchemaVersion == expected.schemaVersion,
            decodedCLIVersion == expected.cliVersion,
            decodedExecutableSHA256 == expected.executableSHA256,
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

    private static func sanitizedSHA256(_ value: String) -> String {
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ byte in
                  (0x30 ... 0x39).contains(byte) || (0x61 ... 0x66).contains(byte)
              })
        else { return "unavailable" }
        return value
    }
}
