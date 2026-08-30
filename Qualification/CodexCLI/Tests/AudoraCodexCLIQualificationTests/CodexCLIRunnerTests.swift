import Foundation
import XCTest

@testable import AudoraCodexCLIQualification

final class CodexCLIRunnerTests: XCTestCase {
    func testCollectsValidStructuredResponseWithinBounds() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "Practice one calm opening sentence."]],
        ])
        let plan = try eventPlan(lines: [
            try jsonString(["type": "thread.started", "thread_id": "synthetic-thread"]),
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": response],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["input_tokens": 100, "output_tokens": 42],
            ]),
        ])

        let outcome = CodexCLIRunner().run(plan: plan)

        guard case let .success(result) = outcome else {
            return XCTFail("expected a successful bounded response")
        }
        XCTAssertEqual(result.responseByteCount, response.utf8.count)
        XCTAssertEqual(result.outputTokenCount, 42)
        XCTAssertTrue(result.processWasReaped)
    }

    func testRejectsMalformedResponseWithoutReturningIt() throws {
        let marker = "synthetic-private-provider-output"
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": marker],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["output_tokens": 2],
            ]),
        ])

        let outcome = CodexCLIRunner().run(plan: plan)

        XCTAssertEqual(failure(outcome)?.reason, .malformedOutput)
        XCTAssertFalse(String(describing: outcome).contains(marker))
    }

    func testRejectsAnyToolEvent() throws {
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "item.completed",
                "item": ["type": "command_execution", "command": "pwd"],
            ]),
        ])

        XCTAssertEqual(
            failure(CodexCLIRunner().run(plan: plan))?.reason,
            .forbiddenCapabilityUsed
        )
    }

    func testEnforcesResponseAndReportedTokenBounds() throws {
        let response = try jsonString([
            "messageBlocks": [["kind": "markdown", "markdown": "A bounded response."]],
        ])
        let plan = try eventPlan(lines: [
            try jsonString([
                "type": "item.completed",
                "item": ["type": "agent_message", "text": response],
            ]),
            try jsonString([
                "type": "turn.completed",
                "usage": ["output_tokens": 42],
            ]),
        ])

        let byteLimited = CodexCLIRunner().run(
            plan: plan,
            limits: QualificationLimits(responseByteCeiling: 8)
        )
        XCTAssertEqual(failure(byteLimited)?.reason, .responseByteLimit)

        let tokenLimited = CodexCLIRunner().run(
            plan: plan,
            limits: QualificationLimits(outputTokenCeiling: 8)
        )
        XCTAssertEqual(failure(tokenLimited)?.reason, .outputTokenLimit)
    }

    func testCancellationAndTimeoutTerminateAndReapProcess() throws {
        let plan = try processPlan(executable: "/bin/sleep", arguments: ["10"])

        let cancelled = CodexCLIRunner().run(
            plan: plan,
            limits: QualificationLimits(timeoutSeconds: 2, terminationGraceSeconds: 0.1),
            control: CodexRunControl(cancelAfterSeconds: 0.02)
        )
        XCTAssertEqual(failure(cancelled)?.reason, .cancelled)
        XCTAssertEqual(failure(cancelled)?.processWasReaped, true)

        let timedOut = CodexCLIRunner().run(
            plan: plan,
            limits: QualificationLimits(timeoutSeconds: 0.02, terminationGraceSeconds: 0.1)
        )
        XCTAssertEqual(failure(timedOut)?.reason, .timedOut)
        XCTAssertEqual(failure(timedOut)?.processWasReaped, true)
    }

    func testLaunchFailureIsSanitizedAndReaped() throws {
        let plan = try processPlan(
            executable: "/synthetic/does-not-exist",
            arguments: []
        )

        let result = failure(CodexCLIRunner().run(plan: plan))

        XCTAssertEqual(result?.reason, .processFailure)
        XCTAssertEqual(result?.processWasReaped, true)
        XCTAssertFalse(String(describing: result).contains("does-not-exist"))
    }

    func testClassifiesRequiredFailureReasonsFromSyntheticSignals() {
        let cases: [(String, SanitizedFailureReason)] = [
            ("Authentication failed", .authentication),
            ("insufficient_quota", .quota),
            ("rate limit status 429", .transient),
            ("model_not_found", .unavailableModel),
            ("invalid JSON structured output", .malformedOutput),
            ("child exited unexpectedly", .processFailure),
        ]

        for (signal, expected) in cases {
            XCTAssertEqual(
                SanitizedErrorClassifier.classify(
                    standardErrorSignal: Data(signal.utf8)
                ),
                expected
            )
        }
    }

    func testProcessFailureMapsStderrWithoutExposingIt() throws {
        let marker = "Authentication failed: synthetic-provider-detail"
        let plan = try processPlan(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s' \"$1\" >&2; exit 1", "fixture", marker]
        )

        let outcome = CodexCLIRunner().run(plan: plan)

        XCTAssertEqual(failure(outcome)?.reason, .authentication)
        XCTAssertFalse(String(describing: outcome).contains(marker))
    }

    private func eventPlan(lines: [String]) throws -> CodexInvocationPlan {
        try processPlan(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "while IFS= read -r _; do :; done; for value do printf '%s\\n' \"$value\"; done",
                "fixture",
            ] + lines,
            standardInput: Data("synthetic\n".utf8)
        )
    }

    private func processPlan(
        executable: String,
        arguments: [String],
        standardInput: Data = Data()
    ) throws -> CodexInvocationPlan {
        let directory = FileManager.default.temporaryDirectory
        return CodexInvocationPlan(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin", "TERM": "dumb"],
            workingDirectoryURL: directory,
            standardInput: standardInput
        )
    }

    private func jsonString(_ object: Any) throws -> String {
        String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    private func failure(_ outcome: CodexRunOutcome) -> SanitizedFailure? {
        guard case let .failure(failure) = outcome else { return nil }
        return failure
    }
}
