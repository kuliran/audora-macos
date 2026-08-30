import Foundation

public struct CodexInvocationPlan: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectoryURL: URL
    public let standardInput: Data

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectoryURL: URL,
        standardInput: Data
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.standardInput = standardInput
    }
}

public enum CodexInvocationPlanError: Error, Equatable {
    case executableMustBeAbsolute
    case modelNotAllowlisted
    case invalidSyntheticFixture
}

public struct CodexInvocationPlanBuilder: Sendable {
    public static let allowlistedModels: Set<String> = [
        "gpt-5.4",
        "gpt-5.5",
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
    ]

    public static let disabledFeatures = [
        "apps",
        "artifact",
        "auth_elicitation",
        "browser_use",
        "browser_use_external",
        "browser_use_full_cdp_access",
        "code_mode",
        "code_mode_only",
        "computer_use",
        "current_time_reminder",
        "deferred_executor",
        "enable_fanout",
        "enable_mcp_apps",
        "goals",
        "hooks",
        "image_generation",
        "imagegenext",
        "in_app_browser",
        "multi_agent",
        "multi_agent_v2",
        "plugin_sharing",
        "plugins",
        "remote_plugin",
        "request_permissions_tool",
        "shell_snapshot",
        "shell_tool",
        "skill_mcp_dependency_install",
        "standalone_web_search",
        "token_budget",
        "tool_call_mcp_elicitation",
        "tool_suggest",
        "unified_exec",
        "workspace_dependencies",
    ]

    public init() {}

    public func build(
        executableURL: URL,
        model: String,
        workspaceURL: URL,
        responseSchemaURL: URL,
        modelCatalogURL: URL,
        syntheticRequest: Data,
        sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> CodexInvocationPlan {
        guard executableURL.path.hasPrefix("/") else {
            throw CodexInvocationPlanError.executableMustBeAbsolute
        }
        guard Self.allowlistedModels.contains(model) else {
            throw CodexInvocationPlanError.modelNotAllowlisted
        }
        guard JSONSerialization.isValidJSONObject(
            try JSONSerialization.jsonObject(with: syntheticRequest)
        ) else {
            throw CodexInvocationPlanError.invalidSyntheticFixture
        }

        var arguments = [
            "exec",
            "--ignore-user-config",
            "--ignore-rules",
            "--strict-config",
            "--ephemeral",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "--model", model,
            "--output-schema", responseSchemaURL.path,
            "--json",
            "--color", "never",
            "--cd", workspaceURL.path,
        ]
        for feature in Self.disabledFeatures {
            arguments.append(contentsOf: ["--disable", feature])
        }
        let overrides = [
            "approval_policy=\"never\"",
            "analytics.enabled=false",
            "check_for_update_on_startup=false",
            "feedback=false",
            "history.persistence=\"none\"",
            "hooks={}",
            "include_apps_instructions=false",
            "include_collaboration_mode_instructions=false",
            "include_environment_context=false",
            "include_permissions_instructions=false",
            "marketplaces={}",
            "mcp_servers={}",
            "model_catalog_json=\(tomlString(modelCatalogURL.path))",
            "model_reasoning_effort=\"low\"",
            "model_verbosity=\"low\"",
            "personality=\"none\"",
            "plugins={}",
            "project_doc_fallback_filenames=[]",
            "project_doc_max_bytes=0",
            "project_root_markers=[]",
            "sandbox_mode=\"read-only\"",
            "shell_environment_policy.experimental_use_profile=false",
            "shell_environment_policy.ignore_default_excludes=false",
            "shell_environment_policy.inherit=\"none\"",
            "shell_environment_policy.include_only=[]",
            "skills={config=[]}",
            "suppress_unstable_features_warning=true",
            "tools.web_search=false",
            "web_search=\"disabled\"",
        ]
        for override in overrides {
            arguments.append(contentsOf: ["--config", override])
        }
        arguments.append("-")

        return CodexInvocationPlan(
            executableURL: executableURL,
            arguments: arguments,
            environment: Self.allowlistedEnvironment(from: sourceEnvironment),
            workingDirectoryURL: workspaceURL,
            standardInput: Self.prompt(for: syntheticRequest)
        )
    }

    public static func allowlistedEnvironment(
        from source: [String: String]
    ) -> [String: String] {
        let allowedNames = ["CODEX_HOME", "HOME", "LANG", "LC_ALL", "PATH", "TMPDIR"]
        var result = source.filter { allowedNames.contains($0.key) }
        result["CI"] = "1"
        result["NO_COLOR"] = "1"
        result["TERM"] = "dumb"
        if result["PATH"] == nil {
            result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        return result
    }

    public static func modelCatalogData(for model: String) throws -> Data {
        guard allowlistedModels.contains(model) else {
            throw CodexInvocationPlanError.modelNotAllowlisted
        }
        let catalog: [String: Any] = [
            "models": [[
                "slug": model,
                "display_name": "Audora qualification model",
                "description": "Synthetic, text-only Coach Provider qualification.",
                "default_reasoning_level": "low",
                "supported_reasoning_levels": [[
                    "effort": "low",
                    "description": "Bounded qualification reasoning.",
                ]],
                "shell_type": "disabled",
                "visibility": "none",
                "supported_in_api": true,
                "priority": 0,
                "additional_speed_tiers": [],
                "service_tiers": [],
                "availability_nux": NSNull(),
                "upgrade": NSNull(),
                "base_instructions": "You are Audora's constrained speech coach. Use only the synthetic request supplied in the current turn. Never call tools, inspect files, or use outside information. Return one complete response matching the supplied JSON Schema.",
                "include_skills_usage_instructions": false,
                "supports_reasoning_summaries": false,
                "default_reasoning_summary": "none",
                "support_verbosity": true,
                "default_verbosity": "low",
                "apply_patch_tool_type": NSNull(),
                "web_search_tool_type": "text",
                "truncation_policy": ["mode": "tokens", "limit": 16_384],
                "supports_parallel_tool_calls": false,
                "supports_image_detail_original": false,
                "context_window": 128_000,
                "max_context_window": 128_000,
                "effective_context_window_percent": 80,
                "experimental_supported_tools": [],
                "input_modalities": ["text"],
                "supports_search_tool": false,
                "use_responses_lite": false,
                "tool_mode": "direct",
                "multi_agent_version": "disabled",
            ]],
        ]
        return try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
    }

    private func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func prompt(for request: Data) -> Data {
        let requestText = String(decoding: request, as: UTF8.self)
        return Data(
            """
            This is an isolated Coach Provider qualification using synthetic data only.
            Do not call any tool or use any information outside the JSON below.
            Return exactly one complete JSON object matching the response schema.
            Keep the markdown under 120 characters and the complete response under 4096 bytes.

            Synthetic CoachRequest:
            \(requestText)
            """.utf8
        )
    }
}
