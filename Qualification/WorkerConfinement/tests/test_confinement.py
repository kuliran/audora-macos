from __future__ import annotations

import platform
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import confinement  # noqa: E402


class LaunchProfileTests(unittest.TestCase):
    def test_worker_environment_is_an_exact_offline_allowlist(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            job_root = Path(directory).resolve()
            environment = confinement.worker_environment(job_root)

        self.assertEqual(set(environment), confinement.ALLOWED_ENVIRONMENT_KEYS)
        self.assertEqual(environment["HOME"], str(job_root / "empty-home"))
        self.assertEqual(
            environment["XDG_CONFIG_HOME"], str(job_root / "empty-config")
        )
        self.assertEqual(environment["HF_HUB_OFFLINE"], "1")
        self.assertEqual(environment["TRANSFORMERS_OFFLINE"], "1")
        self.assertNotIn("SSH_AUTH_SOCK", environment)
        self.assertNotIn("AUDORA_LEAK_SENTINEL", environment)

    def test_sandbox_profile_denies_by_default_and_scopes_file_access(self) -> None:
        profile = confinement.sandbox_profile_text()

        self.assertIn("(deny default)", profile)
        self.assertNotIn("(allow default)", profile)
        self.assertIn('(param "JOB_ROOT")', profile)
        self.assertIn('(param "RUNTIME_ROOT")', profile)
        self.assertIn('(param "MODEL_ROOT")', profile)
        self.assertIn('(param "WORKER_EXECUTABLE")', profile)
        self.assertNotIn("network-outbound", profile)


@unittest.skipUnless(platform.system() == "Darwin", "macOS confinement profile")
class ConfinementIntegrationTests(unittest.TestCase):
    def test_cached_inference_runs_offline_with_expected_handshake(self) -> None:
        result = confinement.qualify_synthetic_scenario("cached-inference")

        self.assertEqual(result.status, "passed")
        self.assertEqual(result.code, "CACHED_INFERENCE_COMPLETE")
        self.assertEqual(result.handshake["protocolVersion"], 1)
        self.assertEqual(result.handshake["patchId"], "synthetic-progress-patch-v1")
        self.assertTrue(result.reaped)
        self.assertTrue(result.process_group_reaped)

    def assert_scenarios_pass(self, scenarios: list[str]) -> None:
        for scenario in scenarios:
            with self.subTest(scenario=scenario):
                result = confinement.qualify_synthetic_scenario(scenario)
                self.assertEqual(result.status, "passed", result)
                self.assertEqual(
                    result.code,
                    confinement.EXPECTED_SCENARIO_CODES[scenario],
                )
                self.assertTrue(result.reaped)
                self.assertTrue(result.process_group_reaped)
                self.assertLessEqual(
                    result.stderr_bytes, confinement.MAX_STDERR_BYTES + 1
                )

    def test_unrelated_and_read_only_paths_remain_unavailable(self) -> None:
        self.assert_scenarios_pass(
            [
                "read-unrelated",
                "traversal",
                "symlink-read",
                "write-unrelated",
                "write-runtime",
                "write-model",
            ]
        )

    def test_network_process_and_resource_attacks_return_bounded_codes(self) -> None:
        self.assert_scenarios_pass(
            [
                "network",
                "process",
                "resource-open-files",
                "resource-output",
                "stderr-output",
            ]
        )

    def test_malformed_protocol_and_handshake_fail_closed(self) -> None:
        self.assert_scenarios_pass(
            [
                "malformed-request",
                "bad-output",
                "bad-handshake",
                "no-hello",
            ]
        )

    def test_cancel_crash_and_timeout_reap_the_process_group(self) -> None:
        self.assert_scenarios_pass(["cancel", "crash", "timeout"])

    def test_report_passes_synthetic_proof_but_keeps_real_engine_blocked(self) -> None:
        report = confinement.build_qualification_report()
        serialized = confinement.canonical_report_json(report)

        self.assertEqual(report["qualificationStatus"], "blocked")
        self.assertEqual(report["syntheticRestrictionProof"]["status"], "passed")
        self.assertEqual(
            report["productionCrisperQualification"]["status"], "blocked"
        )
        self.assertIn(
            "AUDORA_COMPATIBILITY_PATCH_UNPINNED",
            report["productionCrisperQualification"]["reasonCodes"],
        )
        self.assertNotIn("/private/", serialized)
        self.assertNotIn("audioPath", serialized)
        self.assertNotIn("transcript", serialized.casefold())


if __name__ == "__main__":
    unittest.main()
