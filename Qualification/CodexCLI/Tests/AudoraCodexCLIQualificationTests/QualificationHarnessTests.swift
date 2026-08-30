import Foundation
import XCTest

@testable import AudoraCodexCLIQualification

final class QualificationHarnessTests: XCTestCase {
    func testStructuredCaseStartsInEmptyWorkspaceAndReportsNoRawStderr() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-codex-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let executable = fixtureDirectory.appendingPathComponent("fake-codex")
        let response = "{\"messageBlocks\":[{\"kind\":\"markdown\",\"markdown\":\"Practice a calm opening.\"}]}"
        let responseEvent = try jsonString([
            "type": "item.completed",
            "item": ["type": "agent_message", "text": response],
        ])
        let usageEvent = try jsonString([
            "type": "turn.completed",
            "usage": ["output_tokens": 24],
        ])
        let script = """
        #!/bin/sh
        while IFS= read -r _; do :; done
        printf '%s\\n' '\(responseEvent)' '\(usageEvent)'
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let report = try CodexCLIQualificationHarness().runCase(
            .structuredResponse,
            executableURL: executable,
            model: "gpt-5.4"
        )

        XCTAssertTrue(report.passed)
        XCTAssertTrue(report.workspaceRemainedEmpty)
        XCTAssertTrue(report.processWasReaped)
        XCTAssertFalse(report.containsRawStandardError)
        XCTAssertEqual(report.responseByteCount, response.utf8.count)
        XCTAssertEqual(report.outputTokenCount, 24)
    }

    func testSuiteAlwaysRecordsCurrentExternalQualificationLimits() {
        let report = QualificationSuiteReport(cases: [])

        XCTAssertFalse(report.fullyQualifiedForProduction)
        XCTAssertEqual(report.externalLimitations.count, 4)
        XCTAssertTrue(report.externalLimitations.contains(where: { $0.contains("max-output-token") }))
        XCTAssertTrue(report.externalLimitations.contains(where: { $0.contains("exact tokenizer") }))
        XCTAssertTrue(report.externalLimitations.contains(where: { $0.contains("view_image") }))
    }

    private func jsonString(_ object: Any) throws -> String {
        String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            as: UTF8.self
        )
    }
}
