import Foundation
import XCTest

@testable import AudoraCodexCLIQualification

final class CodexInvocationPlanTests: XCTestCase {
    func testBuildPinsIsolationFlagsAndKeepsPromptOffArguments() throws {
        let plan = try makePlan()

        XCTAssertTrue(plan.arguments.contains("--ignore-user-config"))
        XCTAssertTrue(plan.arguments.contains("--ignore-rules"))
        XCTAssertTrue(plan.arguments.contains("--ephemeral"))
        XCTAssertTrue(plan.arguments.contains("--strict-config"))
        XCTAssertTrue(plan.arguments.contains("--skip-git-repo-check"))
        XCTAssertTrue(plan.arguments.contains("read-only"))
        XCTAssertTrue(plan.arguments.contains("web_search=\"disabled\""))
        XCTAssertTrue(plan.arguments.contains("mcp_servers={}"))
        XCTAssertTrue(plan.arguments.contains("plugins={}"))
        XCTAssertTrue(plan.arguments.contains("project_doc_max_bytes=0"))
        XCTAssertEqual(plan.arguments.last, "-")
        XCTAssertFalse(plan.arguments.contains(where: { $0.contains("Synthetic CoachRequest") }))

        for feature in CodexInvocationPlanBuilder.disabledFeatures {
            XCTAssertTrue(
                zip(plan.arguments, plan.arguments.dropFirst()).contains {
                    $0 == "--disable" && $1 == feature
                },
                "missing explicit disable for \(feature)"
            )
        }
    }

    func testEnvironmentAllowlistDropsCredentialAndBrowserVariables() {
        let result = CodexInvocationPlanBuilder.allowlistedEnvironment(from: [
            "HOME": "/synthetic/home",
            "PATH": "/synthetic/bin",
            "OPENAI_API_KEY": "placeholder-that-must-not-pass",
            "BROWSER_PROFILE": "/synthetic/browser",
            "SESSION_TOKEN": "placeholder-that-must-not-pass",
        ])

        XCTAssertEqual(result["HOME"], "/synthetic/home")
        XCTAssertEqual(result["PATH"], "/synthetic/bin")
        XCTAssertNil(result["OPENAI_API_KEY"])
        XCTAssertNil(result["BROWSER_PROFILE"])
        XCTAssertNil(result["SESSION_TOKEN"])
        XCTAssertEqual(result["CI"], "1")
        XCTAssertEqual(result["TERM"], "dumb")
    }

    func testModelCatalogDisablesExecutableAndImageCapabilities() throws {
        let data = try CodexInvocationPlanBuilder.modelCatalogData(for: "gpt-5.4")
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let models = try XCTUnwrap(root["models"] as? [[String: Any]])
        let model = try XCTUnwrap(models.first)

        XCTAssertEqual(model["shell_type"] as? String, "disabled")
        XCTAssertTrue(model["apply_patch_tool_type"] is NSNull)
        XCTAssertEqual(model["input_modalities"] as? [String], ["text"])
        XCTAssertEqual(model["supports_search_tool"] as? Bool, false)
        XCTAssertEqual(model["multi_agent_version"] as? String, "disabled")
        XCTAssertEqual(model["include_skills_usage_instructions"] as? Bool, false)
    }

    func testRejectsArbitraryModelAndRelativeExecutable() throws {
        XCTAssertThrowsError(
            try makePlan(model: "arbitrary-model")
        ) { error in
            XCTAssertEqual(error as? CodexInvocationPlanError, .modelNotAllowlisted)
        }
        XCTAssertThrowsError(
            try makePlan(executableURL: URL(string: "relative-codex")!)
        ) { error in
            XCTAssertEqual(error as? CodexInvocationPlanError, .executableMustBeAbsolute)
        }
    }

    private func makePlan(
        executableURL: URL = URL(fileURLWithPath: "/synthetic/codex"),
        model: String = "gpt-5.4"
    ) throws -> CodexInvocationPlan {
        try CodexInvocationPlanBuilder().build(
            executableURL: executableURL,
            model: model,
            workspaceURL: URL(fileURLWithPath: "/synthetic/workspace"),
            responseSchemaURL: URL(fileURLWithPath: "/synthetic/response-schema.json"),
            modelCatalogURL: URL(fileURLWithPath: "/synthetic/model-catalog.json"),
            syntheticRequest: Data("{\"profile\":{}}".utf8),
            sourceEnvironment: [:]
        )
    }
}
