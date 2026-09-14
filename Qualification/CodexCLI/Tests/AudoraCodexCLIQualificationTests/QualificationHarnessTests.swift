import Foundation
import XCTest

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

    func testCaseStartsWithFreshIsolatedClientHomeWithoutGlobalInstructions() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-codex-client-home-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let executable = fixtureDirectory.appendingPathComponent("fake-codex")
        let response = "{\"messageBlocks\":[{\"kind\":\"markdown\",\"markdown\":\"Practice once.\"}]}"
        let responseEvent = try jsonString([
            "type": "item.completed",
            "item": ["type": "agent_message", "text": response],
        ])
        let usageEvent = try jsonString([
            "type": "turn.completed",
            "usage": ["output_tokens": 2],
        ])
        let script = """
        #!/bin/sh
        [ "$HOME" = "$CODEX_HOME" ] || exit 71
        case "$HOME" in
          */client-home) ;;
          *) exit 72 ;;
        esac
        [ "$HOME" != "$PWD" ] || exit 73
        [ ! -e "$HOME/AGENTS.md" ] || exit 74
        [ ! -e "$HOME/AGENTS.override.md" ] || exit 75
        [ ! -e "$HOME/auth.json" ] || exit 76
        [ ! -L "$HOME/auth.json" ] || exit 77
        while IFS= read -r _; do :; done
        printf '%s\n' '\(responseEvent)' '\(usageEvent)'
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
    }

    func testExplicitAuthorizationReachesTheSameEphemeralProviderProcess() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-codex-same-process-authorization-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let executable = fixtureDirectory.appendingPathComponent("fake-codex")
        let response = #"{"messageBlocks":[{"kind":"markdown","markdown":"Practice once."}]}"#
        let responseEvent = try jsonString([
            "type": "item.completed",
            "item": ["type": "agent_message", "text": response],
        ])
        let usageEvent = try jsonString([
            "type": "turn.completed",
            "usage": ["output_tokens": 2],
        ])
        let script = """
        #!/bin/sh
        [ "$CODEX_ACCESS_TOKEN" = "test-placeholder" ] || exit 70
        [ "$HOME" = "$CODEX_HOME" ] || exit 71
        [ ! -e "$HOME/auth.json" ] || exit 72
        while IFS= read -r _; do :; done
        printf '%s\n' '\(responseEvent)' '\(usageEvent)'
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let authorization = try XCTUnwrap(
            CodexCLIQualificationExecutionAuthorization(
                sourceEnvironment: ["CODEX_ACCESS_TOKEN": "test-placeholder"]
            )
        )

        let report = try CodexCLIQualificationHarness().runCase(
            .structuredResponse,
            executableURL: executable,
            model: "gpt-5.4",
            authorization: authorization
        )

        XCTAssertTrue(report.passed)
    }

    func testSuiteAlwaysRecordsCurrentExternalQualificationLimits() {
        let report = QualificationSuiteReport(
            cases: [],
            limits: QualificationLimits()
        )

        XCTAssertFalse(report.fullyQualifiedForProduction)
        XCTAssertFalse(report.modelFacingToolSurfaceQualified)
        XCTAssertEqual(report.externalLimitations.count, 5)
        XCTAssertTrue(report.externalLimitations.contains(where: { $0.contains("max-output-token") }))
        XCTAssertTrue(report.externalLimitations.contains(where: { $0.contains("exact tokenizer") }))
        XCTAssertTrue(report.externalLimitations.contains(where: { $0.contains("tool allowlist") }))
        XCTAssertTrue(
            report.externalLimitations.contains(where: {
                $0.contains("same-process CODEX_ACCESS_TOKEN")
                    && $0.contains("clean isolated home")
            })
        )
        XCTAssertTrue(
            report.externalLimitations.contains(where: {
                $0.contains("code-signing")
                    && $0.contains("authorized execution remains unavailable")
            })
        )
    }

    func testPublicPreflightReportsCodexCLI0143CapabilityBlockersWithoutProviderLaunch() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-codex-public-refusal-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let executable = fixtureDirectory.appendingPathComponent("fake-codex")
        let versionProbeMarker = fixtureDirectory.appendingPathComponent("version-probed")
        let providerLaunchMarker = fixtureDirectory.appendingPathComponent("provider-launched")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf '%s' 'probed' > '\(versionProbeMarker.path)'
          printf '%s\n' 'codex-cli 0.143.0'
          exit 0
        fi
        printf '%s' 'launched' > '\(providerLaunchMarker.path)'
        exit 0
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let report = try CodexCLIQualificationHarness().preflight(
            executableURL: executable,
            model: "gpt-5.4"
        )
        XCTAssertEqual(report.cliVersion, "codex-cli 0.143.0")
        XCTAssertEqual(
            report.executableSHA256,
            "unavailable",
            "a script launcher and its mutable adjacent dependencies are not exact-build authority"
        )
        XCTAssertEqual(report.providerCasesLaunched, 0)
        XCTAssertFalse(report.providerLaunchPermitted)
        XCTAssertEqual(report.viewImageDisableStatus, .unsupported)
        XCTAssertEqual(report.ephemeralExecAuthorizationStatus, .unverified)
        XCTAssertEqual(
            report.blockers,
            [
                .viewImageDisableUnsupported,
                .sameProcessEphemeralAuthorizationUnverified,
                .executableRuntimeIdentityUnverified,
            ]
        )
        XCTAssertEqual(
            report.manualHandoff,
            [
                .installIndependentlyVerifiedCLI,
                .provideDocumentedSameProcessEphemeralAuthorization,
                .implementVerifiedExecutableRuntime,
                .addExactVersionToCompatibilityMatrix,
                .rerunPublicPreflight,
            ]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: versionProbeMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: providerLaunchMarker.path))
    }

    func testPreflightRejectsDifferentExactVersionsAcrossItsTwoProbes() throws {
        let executable = URL(fileURLWithPath: "/bin/echo")
        var probeCount = 0
        let harness = CodexCLIQualificationHarness(versionProbe: { _, artifact in
            XCTAssertNotNil(artifact)
            probeCount += 1
            return probeCount == 1
                ? "codex-cli 9.999.0"
                : "codex-cli 9.999.0+fork"
        })

        let report = try harness.preflight(
            executableURL: executable,
            model: "gpt-5.4"
        )

        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(report.cliVersion, "unavailable")
        XCTAssertEqual(report.executableSHA256, "unavailable")
        XCTAssertFalse(report.providerLaunchPermitted)
    }

    func testPreflightBindsTwoStableNativeProbesToOneEntryHash() throws {
        var probeCount = 0
        let harness = CodexCLIQualificationHarness(versionProbe: { _, artifact in
            XCTAssertNotNil(artifact)
            probeCount += 1
            return "codex-cli 9.999.0+reviewed-build"
        })

        let report = try harness.preflight(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            model: "gpt-5.4"
        )

        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(report.cliVersion, "codex-cli 9.999.0+reviewed-build")
        XCTAssertEqual(report.executableSHA256.utf8.count, 64)
        XCTAssertNotEqual(report.executableSHA256, "unavailable")
        XCTAssertFalse(report.providerLaunchPermitted)
    }

    func testPreflightRejectsArtifactMutationBetweenVersionProbes() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "audora-codex-preflight-mutation-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = fixtureDirectory.appendingPathComponent("codex")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/echo"),
            to: executable
        )
        var probeCount = 0
        var mutationError: Error?
        let harness = CodexCLIQualificationHarness(versionProbe: { _, artifact in
            probeCount += 1
            if probeCount == 1, let artifact {
                do {
                    let handle = try FileHandle(forWritingTo: artifact.executableURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data([0]))
                    try handle.close()
                } catch {
                    mutationError = error
                }
            }
            return "codex-cli 9.999.0"
        })

        let report = try harness.preflight(
            executableURL: executable,
            model: "gpt-5.4"
        )

        XCTAssertEqual(probeCount, 1)
        XCTAssertNil(mutationError)
        XCTAssertEqual(report.cliVersion, "unavailable")
        XCTAssertEqual(report.executableSHA256, "unavailable")
        XCTAssertFalse(report.providerLaunchPermitted)
    }

    func testFutureAllowlistingRequiresMatchingRuntimeAuthorityProof() throws {
        XCTAssertTrue(
            CodexCLIQualificationCompatibilityMatrix.verifiedRuntimes.isEmpty,
            "shipping qualification must stay closed until a real runtime is reviewed"
        )
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "audora-runtime-authority-proof-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let artifact = try XCTUnwrap(
            CodexCLIExecutableArtifact(executableURL: URL(fileURLWithPath: "/bin/echo"))
        )
        let copiedExecutable = fixtureDirectory.appendingPathComponent("echo")
        try FileManager.default.copyItem(
            at: artifact.executableURL,
            to: copiedExecutable
        )
        let sameBytesDifferentArtifact = try XCTUnwrap(
            CodexCLIExecutableArtifact(executableURL: copiedExecutable)
        )
        XCTAssertEqual(
            sameBytesDifferentArtifact.identity.sha256,
            artifact.identity.sha256
        )
        XCTAssertNotEqual(sameBytesDifferentArtifact.identity, artifact.identity)
        let runtimeIdentity = try XCTUnwrap(
            CodexCLIQualificationRuntimeAuthorityIdentity(
                manifestSHA256: String(repeating: "b", count: 64)
            )
        )
        let approvedRuntime = CodexCLIQualificationCompatibilityMatrix.VerifiedRuntime(
            cliVersion: "codex-cli 9.999.0",
            executableSHA256: artifact.identity.sha256,
            runtimeAuthorityIdentity: runtimeIdentity
        )
        let proof = CodexCLIQualificationRuntimeAuthorityProof(
            runtimeIdentity: runtimeIdentity,
            cliVersion: approvedRuntime.cliVersion,
            executableIdentity: artifact.identity
        )
        let otherRuntimeIdentity = try XCTUnwrap(
            CodexCLIQualificationRuntimeAuthorityIdentity(
                manifestSHA256: String(repeating: "c", count: 64)
            )
        )
        let otherRuntimeProof = CodexCLIQualificationRuntimeAuthorityProof(
            runtimeIdentity: otherRuntimeIdentity,
            cliVersion: approvedRuntime.cliVersion,
            executableIdentity: artifact.identity
        )

        let entryOnly = CodexCLIQualificationPreflightReport(
            cliVersion: approvedRuntime.cliVersion,
            executableSHA256: approvedRuntime.executableSHA256,
            executableIdentity: artifact.identity,
            runtimeAuthorityProof: nil,
            verifiedRuntimes: [approvedRuntime]
        )
        let exact = CodexCLIQualificationPreflightReport(
            cliVersion: approvedRuntime.cliVersion,
            executableSHA256: approvedRuntime.executableSHA256,
            executableIdentity: artifact.identity,
            runtimeAuthorityProof: proof,
            verifiedRuntimes: [approvedRuntime]
        )
        let wrongRuntime = CodexCLIQualificationPreflightReport(
            cliVersion: approvedRuntime.cliVersion,
            executableSHA256: approvedRuntime.executableSHA256,
            executableIdentity: artifact.identity,
            runtimeAuthorityProof: otherRuntimeProof,
            verifiedRuntimes: [approvedRuntime]
        )
        let wrongArtifact = CodexCLIQualificationPreflightReport(
            cliVersion: approvedRuntime.cliVersion,
            executableSHA256: approvedRuntime.executableSHA256,
            executableIdentity: sameBytesDifferentArtifact.identity,
            runtimeAuthorityProof: proof,
            verifiedRuntimes: [approvedRuntime]
        )
        let fork = CodexCLIQualificationPreflightReport(
            cliVersion: "codex-cli 9.999.0+fork",
            executableSHA256: approvedRuntime.executableSHA256,
            executableIdentity: artifact.identity,
            runtimeAuthorityProof: proof,
            verifiedRuntimes: [approvedRuntime]
        )

        XCTAssertFalse(entryOnly.providerLaunchPermitted)
        XCTAssertTrue(entryOnly.blockers.contains(.executableRuntimeIdentityUnverified))
        XCTAssertFalse(wrongRuntime.providerLaunchPermitted)
        XCTAssertFalse(wrongArtifact.providerLaunchPermitted)
        XCTAssertEqual(exact.viewImageDisableStatus, .verified)
        XCTAssertTrue(exact.providerLaunchPermitted)
        XCTAssertEqual(exact.blockers, [])
        XCTAssertEqual(fork.viewImageDisableStatus, .unverified)
        XCTAssertTrue(fork.blockers.contains(.cliVersionUnverified))
        XCTAssertFalse(fork.providerLaunchPermitted)
    }

    func testHarnessRequiresRuntimeVerifierForAnAllowlistedRuntime() throws {
        let executableURL = URL(fileURLWithPath: "/bin/echo")
        let artifact = try XCTUnwrap(
            CodexCLIExecutableArtifact(executableURL: executableURL)
        )
        let cliVersion = "codex-cli 9.999.0+reviewed-runtime"
        let runtimeIdentity = try XCTUnwrap(
            CodexCLIQualificationRuntimeAuthorityIdentity(
                manifestSHA256: String(repeating: "d", count: 64)
            )
        )
        let allowlist: Set<CodexCLIQualificationCompatibilityMatrix.VerifiedRuntime> = [
            CodexCLIQualificationCompatibilityMatrix.VerifiedRuntime(
                cliVersion: cliVersion,
                executableSHA256: artifact.identity.sha256,
                runtimeAuthorityIdentity: runtimeIdentity
            ),
        ]
        let versionProbe: (URL, CodexCLIExecutableArtifact?) -> String = { _, _ in
            cliVersion
        }

        let entryOnlyReport = try CodexCLIQualificationHarness(
            versionProbe: versionProbe,
            verifiedRuntimes: allowlist
        ).preflight(executableURL: executableURL, model: "gpt-5.4")
        let provedRuntimeReport = try CodexCLIQualificationHarness(
            versionProbe: versionProbe,
            runtimeAuthority: SyntheticRuntimeAuthority(identity: runtimeIdentity),
            verifiedRuntimes: allowlist
        ).preflight(executableURL: executableURL, model: "gpt-5.4")

        XCTAssertFalse(entryOnlyReport.providerLaunchPermitted)
        XCTAssertTrue(provedRuntimeReport.providerLaunchPermitted)
    }

    func testAuthorizedSuiteRunsOnlyPreflightAndCannotBypassTheEmptyMatrix() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "audora-codex-script-refusal-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let executable = fixtureDirectory.appendingPathComponent("codex-launcher")
        let versionProbeMarker = fixtureDirectory.appendingPathComponent(
            "version-probed"
        )
        let providerLaunchMarker = fixtureDirectory.appendingPathComponent(
            "provider-launched"
        )
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf '%s' 'probed' > '\(versionProbeMarker.path)'
          printf '%s\n' 'codex-cli 9.999.0'
          exit 0
        fi
        printf '%s' 'launched' > '\(providerLaunchMarker.path)'
        exit 0
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let authorization = try XCTUnwrap(
            CodexCLIQualificationExecutionAuthorization(
                sourceEnvironment: ["CODEX_ACCESS_TOKEN": "test-placeholder"]
            )
        )

        XCTAssertThrowsError(
            try CodexCLIQualificationHarness().runSuite(
                executableURL: executable,
                model: "gpt-5.4",
                authorization: authorization
            )
        ) { error in
            guard case let .qualificationUnavailable(report) = error
                as? CodexCLIQualificationStartError
            else { return XCTFail("expected a closed preflight decision") }
            XCTAssertEqual(report.providerCasesLaunched, 0)
            XCTAssertFalse(report.providerLaunchPermitted)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: versionProbeMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: providerLaunchMarker.path))
    }

    func testClientHomeResidueCannotPassQualification() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "audora-codex-client-residue-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let executable = fixtureDirectory.appendingPathComponent("fake-codex")
        let response = #"{"messageBlocks":[{"kind":"markdown","markdown":"Practice once."}]}"#
        let responseEvent = try jsonString([
            "type": "item.completed",
            "item": ["type": "agent_message", "text": response],
        ])
        let usageEvent = try jsonString([
            "type": "turn.completed",
            "usage": ["output_tokens": 2],
        ])
        let script = """
        #!/bin/sh
        printf '%s' 'unexpected-state' > "$HOME/retained-state"
        while IFS= read -r _; do :; done
        printf '%s\n' '\(responseEvent)' '\(usageEvent)'
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        XCTAssertThrowsError(
            try CodexCLIQualificationHarness().runCase(
                .structuredResponse,
                executableURL: executable,
                model: "gpt-5.4"
            )
        ) { error in
            XCTAssertEqual(
                error as? CodexCLIQualificationStartError,
                .ephemeralClientStateRetained
            )
        }
    }

    func testPublicPreflightTreatsAnUnknownFutureCLIVersionAsUnverified() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-codex-unverified-version-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let executable = fixtureDirectory.appendingPathComponent("fake-codex")
        let providerLaunchMarker = fixtureDirectory.appendingPathComponent("provider-launched")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf '%s\n' 'codex-cli 9.999.0'
          exit 0
        fi
        printf '%s' 'launched' > '\(providerLaunchMarker.path)'
        exit 0
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let report = try CodexCLIQualificationHarness().preflight(
            executableURL: executable,
            model: "gpt-5.4"
        )
        XCTAssertEqual(report.cliVersion, "codex-cli 9.999.0")
        XCTAssertEqual(report.providerCasesLaunched, 0)
        XCTAssertFalse(report.providerLaunchPermitted)
        XCTAssertEqual(report.viewImageDisableStatus, .unverified)
        XCTAssertEqual(report.ephemeralExecAuthorizationStatus, .unverified)
        XCTAssertEqual(
            report.blockers,
            [
                .cliVersionUnverified,
                .viewImageDisableUnverified,
                .sameProcessEphemeralAuthorizationUnverified,
                .executableRuntimeIdentityUnverified,
            ]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: providerLaunchMarker.path))
    }

    func testSuiteReportsSanitizedCLIIdentityAndSeparateAcceptanceDecisions() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-codex-suite-fixture-\(UUID().uuidString)",
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
        let providerWorkEvent = try jsonString([
            "type": "item.started",
            "item": ["type": "reasoning", "text": "Synthetic provider work."],
        ])
        let script = """
        #!/usr/bin/perl
        if (($ARGV[0] // '') eq '--version') {
          print "codex-cli 0.143.0\n";
          exit 0;
        }
        $| = 1;
        while (<STDIN>) {}
        print '\(providerWorkEvent)', "\n";
        select undef, undef, undef, 0.2;
        print '\(responseEvent)', "\n", '\(usageEvent)', "\n";
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let report = try CodexCLIQualificationHarness().runCases(
            QualificationCase.allCases,
            executableURL: executable,
            model: "gpt-5.4"
        )

        XCTAssertEqual(report.cliVersion, "codex-cli 0.143.0")
        XCTAssertEqual(report.model, "gpt-5.4")
        XCTAssertEqual(report.responseByteCeiling, 4_096)
        XCTAssertEqual(report.outputTokenCeiling, 4_096)
        XCTAssertEqual(report.eventStreamByteCeiling, 256 * 1_024)
        XCTAssertEqual(report.failureSignalByteCeiling, 64 * 1_024)
        XCTAssertEqual(report.timeoutSeconds, 90)
        XCTAssertEqual(report.terminationGraceSeconds, 2)
        XCTAssertTrue(report.cases.allSatisfy(\.passed))
        XCTAssertFalse(report.modelFacingToolSurfaceQualified)
        XCTAssertFalse(report.issueGateAccepted)
        XCTAssertFalse(report.productionProviderQualified)
        XCTAssertFalse(report.fullyQualifiedForProduction)
        XCTAssertEqual(
            try JSONDecoder().decode(
                QualificationSuiteReport.self,
                from: JSONEncoder().encode(report)
            ),
            report
        )

        let relaxedReport = try CodexCLIQualificationHarness().runCases(
            QualificationCase.allCases,
            executableURL: executable,
            model: "gpt-5.4",
            limits: QualificationLimits(
                responseByteCeiling: 8_192,
                outputTokenCeiling: 8_192
            )
        )
        XCTAssertFalse(relaxedReport.issueGateAccepted)
        XCTAssertTrue(relaxedReport.cases.allSatisfy(\.passed))
        XCTAssertEqual(relaxedReport.responseByteCeiling, 8_192)
        XCTAssertEqual(relaxedReport.outputTokenCeiling, 8_192)
        XCTAssertEqual(
            try JSONDecoder().decode(
                QualificationSuiteReport.self,
                from: JSONEncoder().encode(relaxedReport)
            ),
            relaxedReport
        )

        let operationallyRelaxedReport = try CodexCLIQualificationHarness().runCases(
            QualificationCase.allCases,
            executableURL: executable,
            model: "gpt-5.4",
            limits: QualificationLimits(
                eventStreamByteCeiling: 512 * 1_024,
                failureSignalByteCeiling: 128 * 1_024,
                timeoutSeconds: 180,
                terminationGraceSeconds: 4
            )
        )
        XCTAssertTrue(operationallyRelaxedReport.cases.allSatisfy(\.passed))
        XCTAssertFalse(operationallyRelaxedReport.issueGateAccepted)
        XCTAssertEqual(
            operationallyRelaxedReport.eventStreamByteCeiling,
            512 * 1_024
        )
        XCTAssertEqual(
            operationallyRelaxedReport.failureSignalByteCeiling,
            128 * 1_024
        )
        XCTAssertEqual(operationallyRelaxedReport.timeoutSeconds, 180)
        XCTAssertEqual(operationallyRelaxedReport.terminationGraceSeconds, 4)
        XCTAssertEqual(
            try JSONDecoder().decode(
                QualificationSuiteReport.self,
                from: JSONEncoder().encode(operationallyRelaxedReport)
            ),
            operationallyRelaxedReport
        )
    }

    func testCLIVersionReportRetainsBuildMetadataForExactBuildMatching() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-codex-version-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let executable = fixtureDirectory.appendingPathComponent("fake-codex")
        let privateMarker = "synthetic-private-build-label"
        let script = """
        #!/bin/sh
        printf '%s\n' 'codex-cli 0.143.0+\(privateMarker)'
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let report = try CodexCLIQualificationHarness().runCases(
            [],
            executableURL: executable,
            model: "gpt-5.4"
        )

        XCTAssertEqual(report.cliVersion, "codex-cli 0.143.0+\(privateMarker)")
    }

    func testCLIVersionReportRejectsNonASCIIDigits() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-codex-version-unicode-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let executable = fixtureDirectory.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/sh
        printf '%s\n' 'codex-cli ٠.١٤٣.٠'
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let report = try CodexCLIQualificationHarness().runCases(
            [],
            executableURL: executable,
            model: "gpt-5.4"
        )

        XCTAssertEqual(report.cliVersion, "unavailable")
    }

    func testCLIVersionProbeRejectsMalformedAndPrereleaseVersions() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-codex-version-malformed-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let malformedVersions = [
            "codex-cli .0.143.0",
            "codex-cli 0..143.0",
            "codex-cli 0.143.0.",
            "codex-cli 0.143.0-preview",
            "codex-cli +0.143.0",
            "codex-cli 0.143.0+",
            "codex-cli 0.143.0+one+two",
        ]

        for (index, malformedVersion) in malformedVersions.enumerated() {
            let executable = fixtureDirectory.appendingPathComponent("fake-codex-\(index)")
            let script = """
            #!/bin/sh
            printf '%s\\n' '\(malformedVersion)'
            """
            try Data(script.utf8).write(to: executable, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )

            let report = try CodexCLIQualificationHarness().runCases(
                [],
                executableURL: executable,
                model: "gpt-5.4"
            )

            XCTAssertEqual(
                report.cliVersion,
                "unavailable",
                "accepted malformed version \(malformedVersion)"
            )
        }
    }

    func testCLIVersionProbeRejectsIdentityWhenDescendantReclamationIsUnproven() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-codex-version-descendant-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let executable = fixtureDirectory.appendingPathComponent("fake-codex")
        let descendantPIDURL = fixtureDirectory.appendingPathComponent("descendant.pid")
        let script = """
        #!/bin/sh
        /bin/sh -c 'trap "" TERM HUP; sleep 2' &
        child=$!
        printf '%s' "$child" > '\(descendantPIDURL.path)'
        printf '%s\n' 'codex-cli 0.143.0'
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let startedAt = Date()

        let report = try CodexCLIQualificationHarness().runCases(
            [],
            executableURL: executable,
            model: "gpt-5.4"
        )

        let descendantPID = try XCTUnwrap(
            pid_t(String(decoding: Data(contentsOf: descendantPIDURL), as: UTF8.self))
        )
        XCTAssertEqual(report.cliVersion, "unavailable")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        XCTAssertEqual(kill(descendantPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testIdleFixtureCannotPassCancellationQualification() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-codex-idle-cancellation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let executable = fixtureDirectory.appendingPathComponent("fake-codex")
        let script = """
        #!/usr/bin/perl
        while (<STDIN>) {}
        select undef, undef, undef, 10;
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let report = try CodexCLIQualificationHarness().runCase(
            .cancellation,
            executableURL: executable,
            model: "gpt-5.4"
        )

        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.observedReason, .processFailure)
        XCTAssertTrue(report.processWasReaped)
    }

    func testSuiteRejectsNonAllowlistedModelBeforeReportingIt() {
        XCTAssertThrowsError(
            try CodexCLIQualificationHarness().runCases(
                [],
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                model: "synthetic-private-model-name"
            )
        ) { error in
            XCTAssertEqual(error as? CodexInvocationPlanError, .modelNotAllowlisted)
        }
    }

    func testSuiteRejectsRelativeExecutableBeforeVersionProbeCanLaunch() throws {
        let fixtureName = "audora-relative-codex-\(UUID().uuidString)"
        let executable = FileManager.default.temporaryDirectory.appendingPathComponent(
            fixtureName
        )
        let launchMarker = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(fixtureName).launched"
        )
        defer {
            try? FileManager.default.removeItem(at: executable)
            try? FileManager.default.removeItem(at: launchMarker)
        }
        let script = """
        #!/bin/sh
        printf '%s' 'launched' > '\(launchMarker.path)'
        printf '%s\n' 'codex-cli 0.143.0'
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let relativeExecutable = try XCTUnwrap(URL(string: "../\(fixtureName)"))

        XCTAssertThrowsError(
            try CodexCLIQualificationHarness().runCases(
                [],
                executableURL: relativeExecutable,
                model: "gpt-5.4"
            )
        ) { error in
            XCTAssertEqual(error as? CodexInvocationPlanError, .executableMustBeAbsolute)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchMarker.path))
    }

    func testDecodesSchemaVersionOneReportWithConservativeDecisionDefaults() throws {
        let legacy = Data(
            """
            {
              "schemaVersion": 1,
              "fullyQualifiedForProduction": true,
              "cases": [],
              "externalLimitations": []
            }
            """.utf8
        )

        let report = try JSONDecoder().decode(QualificationSuiteReport.self, from: legacy)

        XCTAssertEqual(report.cliVersion, "unavailable")
        XCTAssertEqual(report.model, "unavailable")
        XCTAssertNil(report.responseByteCeiling)
        XCTAssertNil(report.outputTokenCeiling)
        XCTAssertNil(report.eventStreamByteCeiling)
        XCTAssertNil(report.failureSignalByteCeiling)
        XCTAssertNil(report.timeoutSeconds)
        XCTAssertNil(report.terminationGraceSeconds)
        XCTAssertFalse(report.modelFacingToolSurfaceQualified)
        XCTAssertFalse(report.issueGateAccepted)
        XCTAssertFalse(report.productionProviderQualified)
        XCTAssertFalse(report.fullyQualifiedForProduction)
    }

    func testPreflightDecoderRejectsForgedProviderLaunchReadiness() throws {
        let report = CodexCLIQualificationPreflightReport(
            cliVersion: "codex-cli 0.143.0",
            executableIdentity: nil,
            runtimeAuthorityProof: nil
        )
        let encoded = try JSONEncoder().encode(report)
        let original = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let mutations: [(String, Any)] = [
            ("providerCasesLaunched", 1),
            ("providerLaunchPermitted", true),
            ("viewImageDisableStatus", "verified"),
            ("ephemeralExecAuthorizationStatus", "verified"),
            ("blockers", []),
            ("manualHandoff", []),
        ]

        for (key, value) in mutations {
            var payload = original
            payload[key] = value
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    CodexCLIQualificationPreflightReport.self,
                    from: JSONSerialization.data(withJSONObject: payload)
                ),
                "accepted forged preflight field \(key)"
            )
        }
    }

    func testReportDecoderRejectsUnsupportedSchemaVersions() throws {
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(
                    QualificationSuiteReport(
                        cases: [],
                        limits: QualificationLimits()
                    )
                )
            ) as? [String: Any]
        )
        payload["schemaVersion"] = 99

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                QualificationSuiteReport.self,
                from: JSONSerialization.data(withJSONObject: payload)
            )
        )
    }

    func testReportDecoderRejectsForgedDerivedDecisions() throws {
        let encoded = try JSONEncoder().encode(
            QualificationSuiteReport(
                cases: [],
                limits: QualificationLimits()
            )
        )
        let base = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let forgedDecisions: [[String: Any]] = [
            ["issueGateAccepted": true],
            [
                "productionProviderQualified": true,
                "fullyQualifiedForProduction": true,
            ],
        ]

        for forgedDecision in forgedDecisions {
            var payload = base
            payload.merge(forgedDecision, uniquingKeysWith: { _, forged in forged })
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    QualificationSuiteReport.self,
                    from: JSONSerialization.data(withJSONObject: payload)
                )
            )
        }
    }

    func testReportDecoderRejectsForgedModelFacingToolSurfaceQualification() throws {
        let report = QualificationSuiteReport(
            cases: passingCaseReports(),
            cliVersion: "codex-cli 0.143.0",
            model: "gpt-5.4",
            limits: QualificationLimits()
        )
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(report))
                as? [String: Any]
        )
        payload["modelFacingToolSurfaceQualified"] = true

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                QualificationSuiteReport.self,
                from: JSONSerialization.data(withJSONObject: payload)
            )
        )
    }

    func testReportDecoderRequiresStructurallyValidLimitEvidence() throws {
        let validReport = QualificationSuiteReport(
            cases: passingCaseReports(),
            cliVersion: "codex-cli 0.143.0",
            model: "gpt-5.4",
            limits: QualificationLimits()
        )
        let base = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(validReport))
                as? [String: Any]
        )
        let invalidLimits: [(key: String, value: Any?)] = [
            ("responseByteCeiling", nil),
            ("outputTokenCeiling", nil),
            ("responseByteCeiling", 0),
            ("outputTokenCeiling", -1),
            ("eventStreamByteCeiling", nil),
            ("failureSignalByteCeiling", nil),
            ("timeoutSeconds", nil),
            ("terminationGraceSeconds", nil),
            ("eventStreamByteCeiling", 0),
            ("failureSignalByteCeiling", -1),
            ("timeoutSeconds", 0),
            ("terminationGraceSeconds", -1),
        ]

        for invalidLimit in invalidLimits {
            var payload = base
            payload[invalidLimit.key] = invalidLimit.value

            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    QualificationSuiteReport.self,
                    from: JSONSerialization.data(withJSONObject: payload)
                ),
                "accepted invalid \(invalidLimit.key) evidence"
            )
        }
    }

    func testReportDecoderRejectsImpossibleCaseFieldCombinations() throws {
        let validCases = [
            QualificationCaseReport(
                name: .structuredResponse,
                passed: true,
                observedReason: nil,
                retryDisposition: .none,
                responseByteCount: 80,
                outputTokenCount: 3,
                processWasReaped: true,
                workspaceRemainedEmpty: true,
                durationMilliseconds: 10
            ),
            QualificationCaseReport(
                name: .cancellation,
                passed: true,
                observedReason: .cancelled,
                retryDisposition: .user,
                responseByteCount: nil,
                outputTokenCount: nil,
                processWasReaped: true,
                workspaceRemainedEmpty: true,
                durationMilliseconds: 10
            ),
            QualificationCaseReport(
                name: .timeout,
                passed: true,
                observedReason: .timedOut,
                retryDisposition: .automatic,
                responseByteCount: nil,
                outputTokenCount: nil,
                processWasReaped: true,
                workspaceRemainedEmpty: true,
                durationMilliseconds: 10
            ),
        ]
        let validReport = QualificationSuiteReport(
            cases: validCases,
            cliVersion: "codex-cli 0.143.0",
            model: "gpt-5.4",
            limits: QualificationLimits()
        )
        let base = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(validReport))
                as? [String: Any]
        )
        let mutations: [(QualificationCase, [String: Any], Bool)] = [
            (.structuredResponse, ["responseByteCount": NSNull()], true),
            (
                .structuredResponse,
                ["responseByteCount": NSNull(), "outputTokenCount": NSNull()],
                true
            ),
            (
                .structuredResponse,
                ["observedReason": "authentication", "retryDisposition": "user"],
                true
            ),
            (.structuredResponse, ["responseByteCount": 0], true),
            (.structuredResponse, ["responseByteCount": 4_097], true),
            (.structuredResponse, ["outputTokenCount": -1], true),
            (.structuredResponse, ["outputTokenCount": 4_097], true),
            (.cancellation, ["responseByteCount": 80, "outputTokenCount": 3], true),
            (
                .cancellation,
                ["observedReason": "timedOut", "retryDisposition": "automatic"],
                true
            ),
            (.timeout, ["retryDisposition": "user"], true),
            (.timeout, ["durationMilliseconds": -1], true),
            (.structuredResponse, ["passed": false], false),
            (.cancellation, ["processWasReaped": false], false),
            (.timeout, ["workspaceRemainedEmpty": false], false),
            (.timeout, ["containsRawStandardError": true], false),
        ]

        for (name, fields, encodedGate) in mutations {
            var payload = base
            var cases = try XCTUnwrap(payload["cases"] as? [[String: Any]])
            let index = try XCTUnwrap(
                cases.firstIndex(where: { $0["name"] as? String == name.rawValue })
            )
            cases[index].merge(fields, uniquingKeysWith: { _, forged in forged })
            payload["cases"] = cases
            payload["issueGateAccepted"] = encodedGate

            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    QualificationSuiteReport.self,
                    from: JSONSerialization.data(withJSONObject: payload)
                ),
                "accepted impossible fields for \(name.rawValue): \(fields.keys.sorted())"
            )
        }
    }

    func testGateRejectsCountsAbovePinnedCeilings() throws {
        var cases = passingCaseReports()
        let structuredIndex = try XCTUnwrap(
            cases.firstIndex(where: { $0.name == .structuredResponse })
        )
        cases[structuredIndex] = QualificationCaseReport(
            name: .structuredResponse,
            passed: true,
            observedReason: nil,
            retryDisposition: .none,
            responseByteCount: 4_097,
            outputTokenCount: 4_097,
            processWasReaped: true,
            workspaceRemainedEmpty: true,
            durationMilliseconds: 1
        )

        let report = QualificationSuiteReport(
            cases: cases,
            cliVersion: "codex-cli 0.143.0",
            model: "gpt-5.4",
            limits: QualificationLimits()
        )

        XCTAssertFalse(report.issueGateAccepted)
    }

    func testGateRequiresEachPinnedLimitExactly() {
        XCTAssertTrue(QualificationLimits().matchesIssueGateProfile)

        let nonPinnedLimits = [
            QualificationLimits(responseByteCeiling: 4_095),
            QualificationLimits(responseByteCeiling: 4_097),
            QualificationLimits(outputTokenCeiling: 4_095),
            QualificationLimits(outputTokenCeiling: 4_097),
            QualificationLimits(eventStreamByteCeiling: 256 * 1_024 - 1),
            QualificationLimits(eventStreamByteCeiling: 256 * 1_024 + 1),
            QualificationLimits(failureSignalByteCeiling: 64 * 1_024 - 1),
            QualificationLimits(failureSignalByteCeiling: 64 * 1_024 + 1),
            QualificationLimits(timeoutSeconds: 89),
            QualificationLimits(timeoutSeconds: 91),
            QualificationLimits(terminationGraceSeconds: 1),
            QualificationLimits(terminationGraceSeconds: 3),
        ]

        for limits in nonPinnedLimits {
            XCTAssertFalse(limits.matchesIssueGateProfile)
        }
    }

    func testDirectReportConstructionKeepsCanonicalExactCLIIdentity() throws {
        let buildMetadata = "synthetic-cli-build"

        let report = QualificationSuiteReport(
            cases: passingCaseReports(),
            cliVersion: "codex-cli 0.143.0+\(buildMetadata)",
            model: "gpt-5.4",
            limits: QualificationLimits()
        )

        XCTAssertEqual(report.cliVersion, "codex-cli 0.143.0+\(buildMetadata)")
        XCTAssertFalse(report.modelFacingToolSurfaceQualified)
        XCTAssertFalse(report.issueGateAccepted)
        XCTAssertTrue(
            String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
                .contains(buildMetadata)
        )

        let privateModel = QualificationSuiteReport(
            cases: passingCaseReports(),
            cliVersion: "codex-cli 0.143.0",
            model: "synthetic-private-model",
            limits: QualificationLimits()
        )
        XCTAssertEqual(privateModel.model, "unavailable")
        XCTAssertFalse(privateModel.issueGateAccepted)
        XCTAssertFalse(
            String(
                decoding: try JSONEncoder().encode(privateModel),
                as: UTF8.self
            ).contains("synthetic-private-model")
        )
    }

    func testDirectReportConstructionRejectsMalformedCanonicalVersions() {
        let malformedVersions = [
            "codex-cli .0.143.0",
            "codex-cli 0..143.0",
            "codex-cli 0.143.0.",
        ]

        for malformedVersion in malformedVersions {
            let report = QualificationSuiteReport(
                cases: passingCaseReports(),
                cliVersion: malformedVersion,
                model: "gpt-5.4",
                limits: QualificationLimits()
            )

            XCTAssertEqual(report.cliVersion, "unavailable")
            XCTAssertFalse(report.issueGateAccepted)
        }
    }

    func testFullSuiteCommandExitRequiresIssueGateAcceptance() {
        let report = QualificationSuiteReport(
            cases: passingCaseReports(),
            cliVersion: "codex-cli 0.143.0",
            model: "gpt-5.4",
            limits: QualificationLimits()
        )

        XCTAssertTrue(report.cases.allSatisfy(\.passed))
        XCTAssertFalse(report.modelFacingToolSurfaceQualified)
        XCTAssertFalse(report.issueGateAccepted)
        XCTAssertFalse(
            QualificationCommandExitPolicy.succeeded(
                report: report,
                ranFullSuite: true
            )
        )
        XCTAssertTrue(
            QualificationCommandExitPolicy.succeeded(
                report: report,
                ranFullSuite: false
            )
        )
    }

    private func jsonString(_ object: Any) throws -> String {
        String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    private func passingCaseReports() -> [QualificationCaseReport] {
        [
            QualificationCaseReport(
                name: .structuredResponse,
                passed: true,
                observedReason: nil,
                retryDisposition: .none,
                responseByteCount: 80,
                outputTokenCount: 3,
                processWasReaped: true,
                workspaceRemainedEmpty: true,
                durationMilliseconds: 1
            ),
            QualificationCaseReport(
                name: .cancellation,
                passed: true,
                observedReason: .cancelled,
                retryDisposition: .user,
                responseByteCount: nil,
                outputTokenCount: nil,
                processWasReaped: true,
                workspaceRemainedEmpty: true,
                durationMilliseconds: 1
            ),
            QualificationCaseReport(
                name: .timeout,
                passed: true,
                observedReason: .timedOut,
                retryDisposition: .automatic,
                responseByteCount: nil,
                outputTokenCount: nil,
                processWasReaped: true,
                workspaceRemainedEmpty: true,
                durationMilliseconds: 1
            ),
        ]
    }
}

private struct SyntheticRuntimeAuthority: CodexCLIQualificationRuntimeAuthority {
    let identity: CodexCLIQualificationRuntimeAuthorityIdentity

    func proveRuntime(
        executableArtifact: CodexCLIExecutableArtifact,
        cliVersion: String
    ) -> CodexCLIQualificationRuntimeAuthorityProof? {
        CodexCLIQualificationRuntimeAuthorityProof(
            runtimeIdentity: identity,
            cliVersion: cliVersion,
            executableIdentity: executableArtifact.identity
        )
    }

    func revalidate(
        _ proof: CodexCLIQualificationRuntimeAuthorityProof,
        executableArtifact: CodexCLIExecutableArtifact,
        cliVersion: String
    ) -> Bool {
        proof.runtimeIdentity == identity
            && proof.binds(
                cliVersion: cliVersion,
                executableArtifact: executableArtifact
            )
            && executableArtifact.revalidate()
    }
}
