from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("crisper_benchmark", ROOT / "benchmark.py")
assert SPEC is not None and SPEC.loader is not None
benchmark = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = benchmark
SPEC.loader.exec_module(benchmark)


class ConfigurationTests(unittest.TestCase):
    def test_committed_lock_is_the_selected_crisper_profile(self) -> None:
        lock = benchmark.load_json(benchmark.ENGINE_LOCK)
        manifest = benchmark.load_json(benchmark.CORPUS_MANIFEST)

        benchmark.validate_locked_configuration(lock, manifest)

        self.assertEqual(lock["engine"]["provider"], "crisperwhisper")
        self.assertEqual(lock["model"]["repository"], "nyralabs/CrisperWhisper2.0_small")
        self.assertEqual(lock["engine"]["backend"], "transformers")
        self.assertEqual(lock["engine"]["device"], "mps")
        self.assertTrue(lock["decoding"]["wordTimestamps"])
        self.assertEqual(
            {fixture["id"] for fixture in manifest["fixtures"]},
            benchmark.EXPECTED_FIXTURES,
        )

    def test_every_required_threshold_is_numeric_and_predeclared(self) -> None:
        manifest = benchmark.load_json(benchmark.CORPUS_MANIFEST)
        thresholds = manifest["thresholds"]

        numeric_paths = [
            ("quality", "maximumWordErrorRate"),
            ("quality", "minimumReferenceWordCoverage"),
            ("quality", "minimumVerbatimEventRecall"),
            ("quality", "minimumBeginningAnchorCoverage"),
            ("quality", "minimumTailAnchorCoverage"),
            ("quality", "minimumWordCountRatio"),
            ("quality", "maximumWordCountRatio"),
            ("quality", "maximumExcessRepeatedNgramRun"),
            ("timing", "minimumTimedWordRatio"),
            ("timing", "maximumZeroDurationWordRatio"),
            ("timing", "maximumTailLagMs"),
            ("runtime", "maximumColdRealTimeFactor"),
            ("runtime", "maximumWarmRealTimeFactor"),
            ("runtime", "maximumPeakResidentBytes"),
            ("runtime", "maximumPeakMpsDriverAllocatedBytes"),
            ("runtime", "maximumThermalRecoverySeconds"),
            ("cancellation", "cancelAfterSeconds"),
            ("cancellation", "maximumTerminationSeconds"),
        ]
        for group, name in numeric_paths:
            with self.subTest(group=group, name=name):
                self.assertIsInstance(thresholds[group][name], (int, float))


class EvaluationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.thresholds = benchmark.load_json(benchmark.CORPUS_MANIFEST)["thresholds"]
        self.reference = {
            "schemaVersion": 1,
            "fixtureId": "short",
            "durationMs": 5000,
            "lastSpeechEndMs": 4750,
            "words": ["we", "[um]", "we", "we", "need", "to", "start", "now"],
            "beginningAnchors": [["we", "[um]", "we"]],
            "tailAnchors": [["start", "now"]],
            "verbatimEvents": [
                {"kind": "filled-pause", "words": ["[um]"]},
                {"kind": "immediate-repetition", "words": ["we", "we"]},
            ],
        }

    def candidate(self, text: str, word_count: int, *, invalid_timing: bool = False) -> dict:
        words = []
        for index in range(word_count):
            start = index * 600
            end = start + 400
            words.append({"text": f"w{index}", "startMs": start, "endMs": end})
        if words:
            words[-1]["endMs"] = 4750
        if invalid_timing:
            words[1] = {"text": "w1", "startMs": 900, "endMs": 900}
            words[2] = {"text": "w2", "startMs": 500, "endMs": 700}
        return {"text": text, "words": words}

    def test_exact_verbatim_candidate_passes_quality_and_timing(self) -> None:
        candidate = self.candidate("we [um] we we need to start now", 8)

        result = benchmark.evaluate_transcript(self.reference, candidate, self.thresholds)

        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["measurements"]["wordErrorRate"], 0)
        self.assertEqual(result["measurements"]["verbatimEventRecall"], 1)
        self.assertTrue(result["measurements"]["monotonicWordTimes"])

    def test_collapse_and_pathological_repetition_fail_closed(self) -> None:
        candidate = self.candidate("we we we we", 4)

        result = benchmark.evaluate_transcript(self.reference, candidate, self.thresholds)
        failed = {gate["gate"] for gate in result["gates"] if gate["status"] == "failed"}

        self.assertEqual(result["status"], "failed")
        self.assertIn("quality.word-error-rate", failed)
        self.assertIn("quality.verbatim-event-recall", failed)
        self.assertIn("quality.word-count-ratio-minimum", failed)
        self.assertIn("quality.excess-repeated-ngram-run", failed)

    def test_invalid_word_times_fail_integrity_gates(self) -> None:
        candidate = self.candidate(
            "we [um] we we need to start now",
            8,
            invalid_timing=True,
        )

        result = benchmark.evaluate_transcript(self.reference, candidate, self.thresholds)
        failed = {gate["gate"] for gate in result["gates"] if gate["status"] == "failed"}

        self.assertIn("timing.zero-duration-word-ratio", failed)
        self.assertIn("timing.monotonic", failed)
        self.assertIn("timing.within-audio", failed)


class PreflightTests(unittest.TestCase):
    def test_missing_external_assets_block_every_case_without_early_exit(self) -> None:
        lock = benchmark.load_json(benchmark.ENGINE_LOCK)
        manifest = benchmark.load_json(benchmark.CORPUS_MANIFEST)
        with tempfile.TemporaryDirectory() as directory:
            gates, reasons = benchmark.preflight(
                lock,
                manifest,
                Path(directory),
                None,
            )

        self.assertEqual(set(reasons), benchmark.EXPECTED_FIXTURES)
        self.assertTrue(all(reasons[fixture] for fixture in benchmark.EXPECTED_FIXTURES))
        self.assertTrue(any(gate.gate == "model.local-assets" and gate.status == "blocked" for gate in gates))
        self.assertTrue(all("CORPUS_ASSET_NOT_READY" in reasons[fixture] for fixture in benchmark.EXPECTED_FIXTURES))

    def test_blocked_report_contains_no_transcript_or_local_path(self) -> None:
        lock = benchmark.load_json(benchmark.ENGINE_LOCK)
        manifest = benchmark.load_json(benchmark.CORPUS_MANIFEST)
        with tempfile.TemporaryDirectory() as directory:
            gates, reasons = benchmark.preflight(lock, manifest, Path(directory), None)
        report = benchmark.blocked_report(lock, manifest, gates, reasons)
        serialized = json.dumps(report)

        self.assertEqual(report["qualificationStatus"], "blocked")
        self.assertNotIn(directory, serialized)
        self.assertNotIn("audioPath", serialized)
        self.assertNotIn("transcript", serialized.casefold())


if __name__ == "__main__":
    unittest.main()
