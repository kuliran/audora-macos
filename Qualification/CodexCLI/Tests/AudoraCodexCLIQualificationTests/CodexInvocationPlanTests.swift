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
        XCTAssertTrue(plan.arguments.contains("tools.view_image=false"))
        XCTAssertTrue(plan.arguments.contains("mcp_servers={}"))
        XCTAssertTrue(plan.arguments.contains("plugins={}"))
        XCTAssertTrue(
            plan.arguments.contains("cli_auth_credentials_store=\"ephemeral\"")
        )
        XCTAssertTrue(plan.arguments.contains("skills.include_instructions=false"))
        XCTAssertTrue(
            plan.arguments.contains(
                "tools.experimental_request_user_input={enabled=false}"
            )
        )
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
        let clientHome = URL(fileURLWithPath: "/synthetic/isolated-client-home")
        let temporaryDirectory = URL(fileURLWithPath: "/synthetic/isolated-temporary")
        let result = CodexInvocationPlanBuilder.allowlistedEnvironment(
            from: [
                "HOME": "/synthetic/source-home-that-must-not-pass",
                "CODEX_HOME": "/synthetic/source-codex-home-that-must-not-pass",
                "PATH": "/synthetic/bin",
                "TMPDIR": "/synthetic/source-temporary-that-must-not-pass",
                "OPENAI_API_KEY": "placeholder-that-must-not-pass",
                "BROWSER_PROFILE": "/synthetic/browser",
                "SESSION_TOKEN": "placeholder-that-must-not-pass",
            ],
            clientHomeURL: clientHome,
            temporaryDirectoryURL: temporaryDirectory
        )

        XCTAssertEqual(result["HOME"], clientHome.path)
        XCTAssertEqual(result["CODEX_HOME"], clientHome.path)
        XCTAssertEqual(result["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(result["TMPDIR"], temporaryDirectory.path)
        XCTAssertNil(result["OPENAI_API_KEY"])
        XCTAssertNil(result["BROWSER_PROFILE"])
        XCTAssertNil(result["SESSION_TOKEN"])
        XCTAssertEqual(result["CI"], "1")
        XCTAssertEqual(result["TERM"], "dumb")
    }

    func testExplicitEphemeralAuthorizationIsTheOnlyCredentialForwarded() throws {
        let clientHome = URL(fileURLWithPath: "/synthetic/isolated-client-home")
        let temporaryDirectory = URL(fileURLWithPath: "/synthetic/isolated-temporary")
        let authorization = try XCTUnwrap(
            CodexCLIQualificationExecutionAuthorization(
                sourceEnvironment: ["CODEX_ACCESS_TOKEN": "placeholder-ephemeral-token"]
            )
        )
        let result = CodexInvocationPlanBuilder.allowlistedEnvironment(
            from: [
                "OPENAI_API_KEY": "must-not-pass",
                "SESSION_TOKEN": "must-not-pass",
            ],
            clientHomeURL: clientHome,
            temporaryDirectoryURL: temporaryDirectory,
            authorization: authorization
        )

        XCTAssertEqual(result["CODEX_ACCESS_TOKEN"], "placeholder-ephemeral-token")
        XCTAssertNil(result["OPENAI_API_KEY"])
        XCTAssertNil(result["SESSION_TOKEN"])
        XCTAssertFalse(String(describing: authorization).contains("placeholder"))
        XCTAssertFalse(String(reflecting: authorization).contains("placeholder"))

        let plan = try makePlan(
            authorization: authorization,
            sourceEnvironment: ["OPENAI_API_KEY": "must-not-pass"]
        )
        XCTAssertFalse(String(describing: plan).contains("placeholder"))
        XCTAssertFalse(String(reflecting: plan).contains("placeholder"))
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

    func testCleanProfilePinsDocumentedViewImageAndEphemeralAuthenticationControls() throws {
        let plan = try makePlan()
        let toolOverrides = plan.arguments.filter { $0.hasPrefix("tools.") }
        let toolFields = Set(toolOverrides.compactMap { override in
            override.split(separator: "=", maxSplits: 1).first.map(String.init)
        })

        let documentedToolFields: Set<String> = [
            "tools.experimental_request_user_input",
            "tools.view_image",
            "tools.web_search",
        ]

        XCTAssertEqual(toolFields, documentedToolFields)
        XCTAssertTrue(
            plan.arguments.contains("cli_auth_credentials_store=\"ephemeral\"")
        )
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
        model: String = "gpt-5.4",
        authorization: CodexCLIQualificationExecutionAuthorization? = nil,
        sourceEnvironment: [String: String] = [:]
    ) throws -> CodexInvocationPlan {
        try CodexInvocationPlanBuilder().build(
            executableURL: executableURL,
            model: model,
            workspaceURL: URL(fileURLWithPath: "/synthetic/workspace"),
            clientHomeURL: URL(fileURLWithPath: "/synthetic/client-home"),
            temporaryDirectoryURL: URL(fileURLWithPath: "/synthetic/temporary"),
            responseSchemaURL: URL(fileURLWithPath: "/synthetic/response-schema.json"),
            modelCatalogURL: URL(fileURLWithPath: "/synthetic/model-catalog.json"),
            syntheticRequest: Data("{\"profile\":{}}".utf8),
            authorization: authorization,
            sourceEnvironment: sourceEnvironment
        )
    }
}
