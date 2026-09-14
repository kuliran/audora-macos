import Foundation

public enum CodexCLIQualificationStartError: Error, Equatable, Sendable {
    case executableMustBeAbsolute
    case modelNotAllowlisted
    case executableRuntimeIdentityUnavailable
    case runtimeAuthorityUnavailable
    case ephemeralClientStateRetained
    case temporaryScopeCleanupFailed
    case sameProcessAuthorizationUnavailable
    case qualificationUnavailable(CodexCLIQualificationPreflightReport)
}

/// One invocation-scoped authorization value. It can only be sourced explicitly
/// by the process launching the qualification suite and is never encoded or
/// printed. The current public suite refuses before forwarding it; a future
/// qualified runtime may forward it only to the verified provider child.
public struct CodexCLIQualificationExecutionAuthorization: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let accessToken: String

    public init?(sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let value = sourceEnvironment["CODEX_ACCESS_TOKEN"],
              !value.isEmpty,
              value.utf8.count <= 16 * 1_024,
              !value.unicodeScalars.contains(where: {
                  $0.value == 0 || $0.properties.generalCategory == .control
              })
        else { return nil }
        accessToken = value
    }

    public var description: String { "<redacted ephemeral Codex authorization>" }
    public var debugDescription: String { description }
}

public struct CodexCLIQualificationHarness {
    private let runner: CodexCLIRunner
    private let fileManager: FileManager
    private let versionProbeOverride: ((URL, CodexCLIExecutableArtifact?) -> String)?
    private let runtimeAuthority: (any CodexCLIQualificationRuntimeAuthority)?
    private let verifiedRuntimes: Set<
        CodexCLIQualificationCompatibilityMatrix.VerifiedRuntime
    >

    public init() {
        runner = CodexCLIRunner()
        fileManager = .default
        versionProbeOverride = nil
        runtimeAuthority = nil
        verifiedRuntimes = CodexCLIQualificationCompatibilityMatrix.verifiedRuntimes
    }

    init(
        runner: CodexCLIRunner = CodexCLIRunner(),
        fileManager: FileManager = .default,
        versionProbe: ((URL, CodexCLIExecutableArtifact?) -> String)? = nil,
        runtimeAuthority: (any CodexCLIQualificationRuntimeAuthority)? = nil,
        verifiedRuntimes: Set<
            CodexCLIQualificationCompatibilityMatrix.VerifiedRuntime
        > = CodexCLIQualificationCompatibilityMatrix.verifiedRuntimes
    ) {
        self.runner = runner
        self.fileManager = fileManager
        versionProbeOverride = versionProbe
        self.runtimeAuthority = runtimeAuthority
        self.verifiedRuntimes = verifiedRuntimes
    }

    /// Performs only the public, credential-free build probe. It never invokes a
    /// provider case, even when the exact build is present in the compatibility
    /// matrix.
    public func preflight(
        executableURL: URL,
        model: String
    ) throws -> CodexCLIQualificationPreflightReport {
        let resolvedExecutableURL = try validatedExecutableURL(
            executableURL,
            model: model
        )
        return observePreflight(executableURL: resolvedExecutableURL).report
    }

    public func runSuite(
        executableURL: URL,
        model: String,
        authorization: CodexCLIQualificationExecutionAuthorization,
        limits: QualificationLimits = QualificationLimits()
    ) throws -> QualificationSuiteReport {
        let resolvedExecutableURL = try validatedExecutableURL(
            executableURL,
            model: model
        )
        let observation = observePreflight(executableURL: resolvedExecutableURL)
        guard observation.report.providerLaunchPermitted else {
            throw CodexCLIQualificationStartError.qualificationUnavailable(
                observation.report
            )
        }
        guard let artifact = observation.executableArtifact,
              let runtimeAuthorityProof = observation.runtimeAuthorityProof,
              runtimeAuthorityIsCurrent(
                  runtimeAuthorityProof,
                  executableArtifact: artifact,
                  cliVersion: observation.report.cliVersion
              ),
              probeCLIVersion(
                  executableURL: resolvedExecutableURL,
                  executableArtifact: artifact
              ) == observation.report.cliVersion,
              runtimeAuthorityIsCurrent(
                  runtimeAuthorityProof,
                  executableArtifact: artifact,
                  cliVersion: observation.report.cliVersion
              )
        else {
            throw CodexCLIQualificationStartError
                .runtimeAuthorityUnavailable
        }
        return try runCases(
            QualificationCase.allCases,
            executableURL: resolvedExecutableURL,
            model: model,
            limits: limits,
            authorization: authorization,
            executableArtifact: artifact,
            preflightCLIVersion: observation.report.cliVersion,
            runtimeAuthorityProof: runtimeAuthorityProof
        )
    }

    func runCases(
        _ qualificationCases: [QualificationCase],
        executableURL: URL,
        model: String,
        limits: QualificationLimits = QualificationLimits(),
        authorization: CodexCLIQualificationExecutionAuthorization? = nil,
        executableArtifact: CodexCLIExecutableArtifact? = nil,
        preflightCLIVersion: String? = nil,
        runtimeAuthorityProof: CodexCLIQualificationRuntimeAuthorityProof? = nil
    ) throws -> QualificationSuiteReport {
        guard executableURL.path.hasPrefix("/") else {
            throw CodexInvocationPlanError.executableMustBeAbsolute
        }
        guard CodexInvocationPlanBuilder.allowlistedModels.contains(model) else {
            throw CodexInvocationPlanError.modelNotAllowlisted
        }
        let cliVersion: String
        if let executableArtifact {
            guard executableArtifact.revalidate(),
                  let preflightCLIVersion,
                  probeCLIVersion(
                      executableURL: executableURL,
                      executableArtifact: executableArtifact
                  ) == preflightCLIVersion,
                  executableArtifact.revalidate()
            else {
                throw CodexCLIQualificationStartError
                    .executableRuntimeIdentityUnavailable
            }
            cliVersion = preflightCLIVersion
        } else {
            guard runtimeAuthorityProof == nil else {
                throw CodexCLIQualificationStartError.runtimeAuthorityUnavailable
            }
            cliVersion = sanitizedCLIVersion(executableURL: executableURL)
        }
        if let runtimeAuthorityProof, let executableArtifact {
            guard runtimeAuthorityIsCurrent(
                runtimeAuthorityProof,
                executableArtifact: executableArtifact,
                cliVersion: cliVersion
            ) else {
                throw CodexCLIQualificationStartError.runtimeAuthorityUnavailable
            }
        }
        let reports = try qualificationCases.map {
            let result = try runCase(
                $0,
                executableURL: executableURL,
                model: model,
                limits: limits,
                authorization: authorization,
                executableArtifact: executableArtifact,
                preflightCLIVersion: preflightCLIVersion,
                runtimeAuthorityProof: runtimeAuthorityProof
            )
            guard executableArtifact?.revalidate() != false else {
                throw CodexCLIQualificationStartError
                    .executableRuntimeIdentityUnavailable
            }
            if let runtimeAuthorityProof, let executableArtifact {
                guard runtimeAuthorityIsCurrent(
                    runtimeAuthorityProof,
                    executableArtifact: executableArtifact,
                    cliVersion: cliVersion
                ) else {
                    throw CodexCLIQualificationStartError.runtimeAuthorityUnavailable
                }
            }
            return result
        }
        return QualificationSuiteReport(
            cases: reports,
            cliVersion: cliVersion,
            model: model,
            limits: limits
        )
    }

    func runCase(
        _ qualificationCase: QualificationCase,
        executableURL: URL,
        model: String,
        limits: QualificationLimits = QualificationLimits(),
        authorization: CodexCLIQualificationExecutionAuthorization? = nil,
        executableArtifact: CodexCLIExecutableArtifact? = nil,
        preflightCLIVersion: String? = nil,
        runtimeAuthorityProof: CodexCLIQualificationRuntimeAuthorityProof? = nil
    ) throws -> QualificationCaseReport {
        try withRemovedTemporaryScope(prefix: "audora-codex-qualification") {
            scopeURL in
            let workspaceURL = scopeURL.appendingPathComponent(
                "workspace",
                isDirectory: true
            )
            let clientHomeURL = scopeURL.appendingPathComponent(
                "client-home",
                isDirectory: true
            )
            let temporaryDirectoryURL = scopeURL.appendingPathComponent(
                "temporary",
                isDirectory: true
            )
            let transportURL = scopeURL.appendingPathComponent(
                "transport",
                isDirectory: true
            )

            for directoryURL in [
                workspaceURL,
                clientHomeURL,
                temporaryDirectoryURL,
                transportURL,
            ] {
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }

            let responseSchemaURL = transportURL.appendingPathComponent(
                "response-schema.json"
            )
            let modelCatalogURL = transportURL.appendingPathComponent(
                "model-catalog.json"
            )
            try QualificationFixtures.responseSchemaData().write(
                to: responseSchemaURL,
                options: .atomic
            )
            try CodexInvocationPlanBuilder.modelCatalogData(for: model).write(
                to: modelCatalogURL,
                options: .atomic
            )

            let workspaceWasEmptyAtLaunch = try directoryIsEmpty(workspaceURL)
            let plan = try CodexInvocationPlanBuilder().build(
                executableURL: executableURL,
                model: model,
                workspaceURL: workspaceURL,
                clientHomeURL: clientHomeURL,
                temporaryDirectoryURL: temporaryDirectoryURL,
                responseSchemaURL: responseSchemaURL,
                modelCatalogURL: modelCatalogURL,
                syntheticRequest: QualificationFixtures.syntheticRequestData(),
                authorization: authorization
            )

            let caseLimits: QualificationLimits
            let control: CodexRunControl
            switch qualificationCase {
            case .structuredResponse:
                caseLimits = limits
                control = CodexRunControl()
            case .cancellation:
                caseLimits = limits
                control = CodexRunControl(cancelAfterSeconds: 0.05)
            case .timeout:
                caseLimits = QualificationLimits(
                    responseByteCeiling: limits.responseByteCeiling,
                    outputTokenCeiling: limits.outputTokenCeiling,
                    eventStreamByteCeiling: limits.eventStreamByteCeiling,
                    failureSignalByteCeiling: limits.failureSignalByteCeiling,
                    timeoutSeconds: 0.05,
                    terminationGraceSeconds: limits.terminationGraceSeconds
                )
                control = CodexRunControl()
            }

            if let runtimeAuthorityProof {
                guard let executableArtifact,
                      let preflightCLIVersion,
                      runtimeAuthorityIsCurrent(
                          runtimeAuthorityProof,
                          executableArtifact: executableArtifact,
                          cliVersion: preflightCLIVersion
                      )
                else {
                    throw CodexCLIQualificationStartError.runtimeAuthorityUnavailable
                }
            }
            let outcome = runner.run(
                plan: plan,
                executableArtifact: executableArtifact,
                limits: caseLimits,
                control: control
            )
            if let runtimeAuthorityProof {
                guard let executableArtifact,
                      let preflightCLIVersion,
                      runtimeAuthorityIsCurrent(
                          runtimeAuthorityProof,
                          executableArtifact: executableArtifact,
                          cliVersion: preflightCLIVersion
                      )
                else {
                    throw CodexCLIQualificationStartError.runtimeAuthorityUnavailable
                }
            }
            let workspaceIsEmptyAfterRun = try directoryIsEmpty(workspaceURL)
            let workspaceRemainedEmpty = workspaceWasEmptyAtLaunch
                && workspaceIsEmptyAfterRun
            guard (try? directoryIsEmpty(clientHomeURL)) == true else {
                throw CodexCLIQualificationStartError.ephemeralClientStateRetained
            }
            return report(
                for: qualificationCase,
                outcome: outcome,
                workspaceRemainedEmpty: workspaceRemainedEmpty
            )
        }
    }

    private func withRemovedTemporaryScope<Value>(
        prefix: String,
        _ operation: (URL) throws -> Value
    ) throws -> Value {
        let scopeURL = fileManager.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: scopeURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let outcome = Result { try operation(scopeURL) }
        do {
            try fileManager.removeItem(at: scopeURL)
        } catch {
            throw CodexCLIQualificationStartError.temporaryScopeCleanupFailed
        }
        return try outcome.get()
    }

    private func directoryIsEmpty(_ url: URL) throws -> Bool {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ).isEmpty
    }

    private func validatedExecutableURL(_ executableURL: URL, model: String) throws -> URL {
        guard executableURL.path.hasPrefix("/") else {
            throw CodexCLIQualificationStartError.executableMustBeAbsolute
        }
        guard CodexInvocationPlanBuilder.allowlistedModels.contains(model) else {
            throw CodexCLIQualificationStartError.modelNotAllowlisted
        }
        return executableURL.resolvingSymlinksInPath()
    }

    private struct PreflightObservation {
        let report: CodexCLIQualificationPreflightReport
        let executableArtifact: CodexCLIExecutableArtifact?
        let runtimeAuthorityProof: CodexCLIQualificationRuntimeAuthorityProof?
    }

    private func observePreflight(
        executableURL: URL
    ) -> PreflightObservation {
        let artifact = CodexCLIExecutableArtifact(executableURL: executableURL)
        let firstVersion = probeCLIVersion(
            executableURL: executableURL,
            executableArtifact: artifact
        )
        guard artifact?.revalidate() != false else {
            return PreflightObservation(
                report: CodexCLIQualificationPreflightReport(
                    cliVersion: QualificationCLIIdentity.unavailable,
                    executableIdentity: nil,
                    runtimeAuthorityProof: nil
                ),
                executableArtifact: nil,
                runtimeAuthorityProof: nil
            )
        }
        let secondVersion = probeCLIVersion(
            executableURL: executableURL,
            executableArtifact: artifact
        )
        guard firstVersion == secondVersion,
              firstVersion != QualificationCLIIdentity.unavailable,
              artifact?.revalidate() != false
        else {
            return PreflightObservation(
                report: CodexCLIQualificationPreflightReport(
                    cliVersion: QualificationCLIIdentity.unavailable,
                    executableIdentity: nil,
                    runtimeAuthorityProof: nil
                ),
                executableArtifact: nil,
                runtimeAuthorityProof: nil
            )
        }
        let runtimeAuthorityProof: CodexCLIQualificationRuntimeAuthorityProof?
        if let artifact, let runtimeAuthority,
           let candidate = runtimeAuthority.proveRuntime(
               executableArtifact: artifact,
               cliVersion: firstVersion
           ),
           candidate.binds(
               cliVersion: firstVersion,
               executableArtifact: artifact
           ),
           runtimeAuthority.revalidate(
               candidate,
               executableArtifact: artifact,
               cliVersion: firstVersion
           )
        {
            runtimeAuthorityProof = candidate
        } else {
            runtimeAuthorityProof = nil
        }
        return PreflightObservation(
            report: CodexCLIQualificationPreflightReport(
                cliVersion: firstVersion,
                executableSHA256: artifact?.identity.sha256
                    ?? QualificationCLIIdentity.unavailable,
                executableIdentity: artifact?.identity,
                runtimeAuthorityProof: runtimeAuthorityProof,
                verifiedRuntimes: verifiedRuntimes
            ),
            executableArtifact: artifact,
            runtimeAuthorityProof: runtimeAuthorityProof
        )
    }

    private func runtimeAuthorityIsCurrent(
        _ proof: CodexCLIQualificationRuntimeAuthorityProof,
        executableArtifact: CodexCLIExecutableArtifact,
        cliVersion: String
    ) -> Bool {
        guard let runtimeAuthority,
              executableArtifact.revalidate(),
              proof.binds(
                  cliVersion: cliVersion,
                  executableArtifact: executableArtifact
              )
        else { return false }
        return runtimeAuthority.revalidate(
            proof,
            executableArtifact: executableArtifact,
            cliVersion: cliVersion
        )
    }

    private func sanitizedCLIVersion(executableURL: URL) -> String {
        probeCLIVersion(executableURL: executableURL, executableArtifact: nil)
    }

    private func probeCLIVersion(
        executableURL: URL,
        executableArtifact: CodexCLIExecutableArtifact?
    ) -> String {
        if let versionProbeOverride {
            return QualificationCLIIdentity.sanitizedReportedVersion(
                versionProbeOverride(executableURL, executableArtifact)
            )
        }
        return (try? withRemovedTemporaryScope(prefix: "audora-codex-version") {
            scopeURL in
            let process = BoundedProcessHost().run(
                BoundedProcessRequest(
                    executableURL: executableURL,
                    executableArtifact: executableArtifact,
                    arguments: ["--version"],
                    environment: [
                        "CI": "1",
                        "CODEX_HOME": scopeURL.path,
                        "HOME": scopeURL.path,
                        "NO_COLOR": "1",
                        "PATH": CodexInvocationPlanBuilder.pinnedExecutableSearchPath,
                        "TERM": "dumb",
                        "TMPDIR": scopeURL.path,
                    ],
                    workingDirectoryURL: scopeURL,
                    standardInput: Data(),
                    standardOutputByteCeiling: 128,
                    standardErrorByteCeiling: 128,
                    timeoutSeconds: 2,
                    cancelAfterSeconds: nil,
                    terminationGraceSeconds: 0.2
                )
            )

            guard
                process.launched,
                process.stopReason == nil,
                process.standardInputWasWritten,
                process.exitedNormally,
                process.exitStatus == 0,
                process.processGroupWasReaped,
                let versionOutput = String(
                    data: process.standardOutput,
                    encoding: .utf8
                )
            else {
                return QualificationCLIIdentity.unavailable
            }
            return QualificationCLIIdentity.normalizedProbeOutput(versionOutput)
        }) ?? QualificationCLIIdentity.unavailable
    }

    private func report(
        for qualificationCase: QualificationCase,
        outcome: CodexRunOutcome,
        workspaceRemainedEmpty: Bool
    ) -> QualificationCaseReport {
        switch outcome {
        case let .success(response):
            return QualificationCaseReport(
                name: qualificationCase,
                passed: qualificationCase == .structuredResponse
                    && response.processWasReaped
                    && workspaceRemainedEmpty,
                observedReason: workspaceRemainedEmpty ? nil : .forbiddenCapabilityUsed,
                retryDisposition: workspaceRemainedEmpty ? .none : .user,
                responseByteCount: response.responseByteCount,
                outputTokenCount: response.outputTokenCount,
                processWasReaped: response.processWasReaped,
                workspaceRemainedEmpty: workspaceRemainedEmpty,
                durationMilliseconds: response.durationMilliseconds
            )
        case let .failure(failure):
            let expectedReason: SanitizedFailureReason? = switch qualificationCase {
            case .structuredResponse: nil
            case .cancellation: .cancelled
            case .timeout: .timedOut
            }
            return QualificationCaseReport(
                name: qualificationCase,
                passed: failure.reason == expectedReason
                    && failure.processWasReaped
                    && workspaceRemainedEmpty,
                observedReason: failure.reason,
                retryDisposition: failure.reason.retryDisposition,
                responseByteCount: nil,
                outputTokenCount: nil,
                processWasReaped: failure.processWasReaped,
                workspaceRemainedEmpty: workspaceRemainedEmpty,
                durationMilliseconds: failure.durationMilliseconds
            )
        }
    }
}
