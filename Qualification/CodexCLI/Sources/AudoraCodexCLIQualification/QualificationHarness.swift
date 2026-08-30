import Foundation

public struct CodexCLIQualificationHarness {
    private let runner: CodexCLIRunner
    private let fileManager: FileManager

    public init(
        runner: CodexCLIRunner = CodexCLIRunner(),
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public func runSuite(
        executableURL: URL,
        model: String,
        limits: QualificationLimits = QualificationLimits()
    ) throws -> QualificationSuiteReport {
        let reports = try QualificationCase.allCases.map {
            try runCase(
                $0,
                executableURL: executableURL,
                model: model,
                limits: limits
            )
        }
        return QualificationSuiteReport(cases: reports)
    }

    public func runCase(
        _ qualificationCase: QualificationCase,
        executableURL: URL,
        model: String,
        limits: QualificationLimits = QualificationLimits()
    ) throws -> QualificationCaseReport {
        let scopeURL = fileManager.temporaryDirectory.appendingPathComponent(
            "audora-codex-qualification-\(UUID().uuidString)",
            isDirectory: true
        )
        let workspaceURL = scopeURL.appendingPathComponent("workspace", isDirectory: true)
        let transportURL = scopeURL.appendingPathComponent("transport", isDirectory: true)

        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: transportURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scopeURL) }

        let responseSchemaURL = transportURL.appendingPathComponent("response-schema.json")
        let modelCatalogURL = transportURL.appendingPathComponent("model-catalog.json")
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
            responseSchemaURL: responseSchemaURL,
            modelCatalogURL: modelCatalogURL,
            syntheticRequest: QualificationFixtures.syntheticRequestData()
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

        let outcome = runner.run(plan: plan, limits: caseLimits, control: control)
        let workspaceIsEmptyAfterRun = try directoryIsEmpty(workspaceURL)
        let workspaceRemainedEmpty = workspaceWasEmptyAtLaunch && workspaceIsEmptyAfterRun
        return report(
            for: qualificationCase,
            outcome: outcome,
            workspaceRemainedEmpty: workspaceRemainedEmpty
        )
    }

    private func directoryIsEmpty(_ url: URL) throws -> Bool {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ).isEmpty
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
