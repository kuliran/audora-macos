from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import wave
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("crisper_benchmark", ROOT / "benchmark.py")
assert SPEC is not None and SPEC.loader is not None
benchmark = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = benchmark
SPEC.loader.exec_module(benchmark)


def word_timings(count: int, *, last_end_ms: int) -> list[dict[str, int]]:
    timings = [
        {"startMs": index * 600, "endMs": index * 600 + 400}
        for index in range(count)
    ]
    if timings:
        timings[-1]["endMs"] = last_end_ms
    return timings


FIXTURE_NUMERIC_GATE_EVIDENCE = {
    "quality.word-error-rate": (0.1, 0.2),
    "quality.reference-word-coverage": (1.0, 0.8),
    "quality.verbatim-event-recall": (1.0, 0.85),
    "quality.beginning-anchor-coverage": (1.0, 1.0),
    "quality.tail-anchor-coverage": (1.0, 1.0),
    "quality.word-count-ratio-minimum": (1.0, 0.8),
    "quality.word-count-ratio-maximum": (1.0, 1.2),
    "quality.excess-repeated-ngram-run": (0, 1),
    "timing.timed-word-ratio": (1.0, 0.98),
    "timing.zero-duration-word-ratio": (0.0, 0.0),
    "timing.tail-lag-ms": (0, 1500),
    "timing.maximum-word-start-error-ms": (100, 750),
    "timing.maximum-word-end-error-ms": (100, 750),
    "timing.aligned-word-timing-ratio": (1.0, 0.8),
    "timing.long-pause-timing-recall": (1.0, 1.0),
    "timing.longform-boundary-timing-recall": (1.0, 1.0),
    "timing.final-underfilled-window-timing-recall": (1.0, 1.0),
    "runtime.cold-real-time-factor": (0.5, 1.0),
    "runtime.warm-real-time-factor": (0.25, 0.75),
    "runtime.peak-resident-bytes": (1024, 6442450944),
    "runtime.peak-mps-driver-allocated-bytes": (512, 4294967296),
    "runtime.thermal-recovery-seconds": (0.0, 300),
}
FIXTURE_BOOLEAN_GATES = {
    "timing.text-word-count-match",
    "timing.one-token-per-word",
    "timing.text-word-content-match",
    "timing.monotonic",
    "timing.within-audio",
    "quality.cold-warm-output-match",
}


def passing_fixture_result(fixture_id: str) -> dict:
    duration_ms = {
        "short": 10_000,
        "one-minute": 55_000,
        "twelve-minute": 710_000,
        "forty-five-minute": 2_690_000,
    }[fixture_id]
    duration_seconds = duration_ms / 1000
    gates = [
        {
            "gate": name,
            "status": "passed",
            "measured": evidence[0],
            "threshold": evidence[1],
        }
        for name, evidence in sorted(FIXTURE_NUMERIC_GATE_EVIDENCE.items())
    ]
    gates.extend(
        {"gate": name, "status": "passed", "measured": True, "threshold": True}
        for name in sorted(FIXTURE_BOOLEAN_GATES)
    )
    gates.append(
        {
            "gate": "runtime.maximum-thermal-state",
            "status": "passed",
            "measured": "fair",
            "threshold": "serious",
        }
    )
    return {
        "id": fixture_id,
        "status": "passed",
        "measurements": {
            "referenceWordCount": 100,
            "candidateWordCount": 100,
            "wordErrorRate": 0.1,
            "referenceWordCoverage": 1.0,
            "verbatimEventRecall": 1.0,
            "beginningAnchorCoverage": 1.0,
            "tailAnchorCoverage": 1.0,
            "wordCountRatio": 1.0,
            "referenceMaximumRepeatedNgramRun": 1,
            "candidateMaximumRepeatedNgramRun": 1,
            "excessRepeatedNgramRun": 0,
            "timedWordRatio": 1.0,
            "textWordCountMatches": True,
            "oneTokenPerTimedWord": True,
            "textWordContentMatches": True,
            "zeroDurationWordRatio": 0.0,
            "monotonicWordTimes": True,
            "wordsWithinAudio": True,
            "tailLagMs": 0,
            "maximumWordStartErrorMs": 100,
            "maximumWordEndErrorMs": 100,
            "alignedWordTimingRatio": 1.0,
            "longPauseTimingRecall": 1.0,
            "longformBoundaryTimingRecall": 1.0,
            "finalUnderfilledWindowTimingRecall": 1.0,
            "audioDurationMs": duration_ms,
            "modelLoadSeconds": 1.0,
            "coldInferenceSeconds": duration_seconds * 0.5 - 1.0,
            "warmInferenceSeconds": duration_seconds * 0.25,
            "coldRealTimeFactor": 0.5,
            "warmRealTimeFactor": 0.25,
            "peakResidentBytes": 1024,
            "peakMpsDriverAllocatedBytes": 512,
            "maximumThermalState": "fair",
            "thermalRecoverySeconds": 0.0,
            "coldWarmOutputMatch": True,
        },
        "gates": gates,
    }


def passing_cancellation_result() -> dict:
    return {
        "status": "passed",
        "modelLoadSeconds": 1.0,
        "activeInferenceAcknowledged": True,
        "terminationSeconds": 0.1,
        "forcedKill": False,
        "workerReaped": True,
        "gates": [
            {
                "gate": "cancellation.transcription-active",
                "status": "passed",
                "measured": True,
                "threshold": True,
            },
            {
                "gate": "cancellation.termination-seconds",
                "status": "passed",
                "measured": 0.1,
                "threshold": 5,
            },
            {
                "gate": "cancellation.no-forced-kill",
                "status": "passed",
                "measured": True,
                "threshold": True,
            },
            {
                "gate": "cancellation.worker-reaped",
                "status": "passed",
                "measured": True,
                "threshold": True,
            },
        ],
    }


def passing_cached_offline_result() -> dict:
    return {
        "status": "passed",
        "gates": [
            {
                "gate": "cached-offline.inference",
                "status": "passed",
                "measured": True,
                "threshold": True,
            },
            {
                "gate": "cached-offline.network-denied",
                "status": "passed",
                "measured": True,
                "threshold": True,
            },
        ],
    }


def bind_manifest_to_source_plan(manifest: dict, source_plan: dict) -> None:
    manifest_by_id = {fixture["id"]: fixture for fixture in manifest["fixtures"]}
    for planned_fixture in source_plan["fixtures"]:
        manifest_fixture = manifest_by_id[planned_fixture["id"]]
        manifest_fixture["audioSha256"] = planned_fixture["candidateAudioSha256"]
        manifest_fixture["sourceProvenance"] = {
            "sourceId": planned_fixture["sourceId"],
            "startMs": planned_fixture["startMs"],
            "durationMs": planned_fixture["durationMs"],
            "candidateAudioSha256": planned_fixture["candidateAudioSha256"],
        }
    manifest["publicSourcePlan"] = {
        "planId": source_plan["planId"],
        "sha256": benchmark.canonical_json_sha256(source_plan),
    }


def qualification_inputs_with_pinned_public_audio() -> tuple[dict, dict, dict]:
    lock = benchmark.load_json(benchmark.ENGINE_LOCK)
    manifest = benchmark.load_json(benchmark.CORPUS_MANIFEST)
    source_plan = benchmark.load_json(benchmark.PUBLIC_SOURCE_PLAN)
    for planned_fixture in source_plan["fixtures"]:
        if planned_fixture["candidateAudioSha256"] is None:
            planned_fixture["candidateAudioSha256"] = hashlib.sha256(
                planned_fixture["id"].encode()
            ).hexdigest()
    bind_manifest_to_source_plan(manifest, source_plan)
    return lock, manifest, source_plan


class ConfigurationTests(unittest.TestCase):
    def test_committed_manifest_is_bound_to_the_public_source_plan(self) -> None:
        lock = benchmark.load_json(benchmark.ENGINE_LOCK)
        manifest = benchmark.load_json(benchmark.CORPUS_MANIFEST)
        source_plan = benchmark.load_json(benchmark.PUBLIC_SOURCE_PLAN)

        benchmark.validate_locked_configuration(lock, manifest, source_plan)

        self.assertEqual(
            manifest["publicSourcePlan"],
            {
                "planId": source_plan["planId"],
                "sha256": "b2570a7ee4a4ad08f93ccda227861e5431e4ab392c0654db923120fa87fe70e9",
            },
        )
        manifest_by_id = {fixture["id"]: fixture for fixture in manifest["fixtures"]}
        for planned_fixture in source_plan["fixtures"]:
            with self.subTest(fixture=planned_fixture["id"]):
                fixture = manifest_by_id[planned_fixture["id"]]
                self.assertEqual(
                    fixture["sourceProvenance"],
                    {
                        "sourceId": planned_fixture["sourceId"],
                        "startMs": planned_fixture["startMs"],
                        "durationMs": planned_fixture["durationMs"],
                        "candidateAudioSha256": planned_fixture[
                            "candidateAudioSha256"
                        ],
                    },
                )
                self.assertEqual(
                    fixture["audioSha256"],
                    planned_fixture["candidateAudioSha256"],
                )

    def test_public_source_plan_shape_and_fixture_provenance_are_validated(self) -> None:
        lock = benchmark.load_json(benchmark.ENGINE_LOCK)
        original_manifest = benchmark.load_json(benchmark.CORPUS_MANIFEST)
        original_plan = benchmark.load_json(benchmark.PUBLIC_SOURCE_PLAN)

        malformed_id = copy.deepcopy(original_plan)
        malformed_id["planId"] = {"unexpected": "object"}
        malformed_id_manifest = copy.deepcopy(original_manifest)
        malformed_id_manifest["publicSourcePlan"] = {
            "planId": malformed_id["planId"],
            "sha256": benchmark.canonical_json_sha256(malformed_id),
        }

        moved_interval = copy.deepcopy(original_plan)
        moved_interval["fixtures"][0]["startMs"] += 1
        moved_interval_manifest = copy.deepcopy(original_manifest)
        moved_interval_manifest["publicSourcePlan"]["sha256"] = (
            benchmark.canonical_json_sha256(moved_interval)
        )

        malformed_fixture_id = copy.deepcopy(original_plan)
        malformed_fixture_id["fixtures"][0]["id"] = {"unexpected": "object"}
        malformed_fixture_id_manifest = copy.deepcopy(original_manifest)
        malformed_fixture_id_manifest["publicSourcePlan"]["sha256"] = (
            benchmark.canonical_json_sha256(malformed_fixture_id)
        )

        for name, manifest, source_plan in (
            ("malformed-plan-id", malformed_id_manifest, malformed_id),
            ("moved-source-interval", moved_interval_manifest, moved_interval),
            (
                "malformed-fixture-id",
                malformed_fixture_id_manifest,
                malformed_fixture_id,
            ),
        ):
            with self.subTest(case=name), self.assertRaises(
                benchmark.QualificationError
            ):
                benchmark.validate_locked_configuration(lock, manifest, source_plan)

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

    def test_manifest_requires_exact_unique_records_and_safe_distinct_paths(self) -> None:
        lock = benchmark.load_json(benchmark.ENGINE_LOCK)
        original = benchmark.load_json(benchmark.CORPUS_MANIFEST)

        duplicate_record = copy.deepcopy(original)
        duplicate_record["fixtures"].append(copy.deepcopy(duplicate_record["fixtures"][0]))

        duplicate_audio = copy.deepcopy(original)
        duplicate_audio["fixtures"][1]["audioPath"] = duplicate_audio["fixtures"][0][
            "audioPath"
        ]

        duplicate_reference = copy.deepcopy(original)
        duplicate_reference["fixtures"][1]["referencePath"] = duplicate_reference[
            "fixtures"
        ][0]["referencePath"]

        escaping_path = copy.deepcopy(original)
        escaping_path["fixtures"][0]["audioPath"] = "../outside.wav"

        wrong_seam = copy.deepcopy(original)
        wrong_seam["thresholds"]["timing"]["longformBoundaryIntervalMs"] = 30000

        wrong_final_window = copy.deepcopy(original)
        wrong_final_window["thresholds"]["timing"]["finalWindowSizeMs"] = 26000

        malformed_id = copy.deepcopy(original)
        malformed_id["fixtures"][0]["id"] = {"id": "short"}

        extra_field = copy.deepcopy(original)
        extra_field["fixtures"][0]["unexpected"] = True

        missing_range = copy.deepcopy(original)
        del missing_range["fixtures"][0]["durationRangeMs"]

        malformed_range = copy.deepcopy(original)
        malformed_range["fixtures"][0]["durationRangeMs"] = [True, "30000"]

        malformed_phenomena = copy.deepcopy(original)
        malformed_phenomena["fixtures"][0]["requiredPhenomena"] = [
            "tail-speech",
            "tail-speech",
        ]

        malformed_hash = copy.deepcopy(original)
        malformed_hash["fixtures"][0]["audioSha256"] = "not-a-sha256"

        ready_without_hashes = copy.deepcopy(original)
        ready_without_hashes["fixtures"][0]["assetStatus"] = "ready"

        for name, manifest in {
            "duplicate-record": duplicate_record,
            "duplicate-audio": duplicate_audio,
            "duplicate-reference": duplicate_reference,
            "escaping-path": escaping_path,
            "wrong-longform-seam": wrong_seam,
            "wrong-final-window": wrong_final_window,
            "malformed-id": malformed_id,
            "extra-field": extra_field,
            "missing-range": missing_range,
            "malformed-range": malformed_range,
            "malformed-phenomena": malformed_phenomena,
            "malformed-hash": malformed_hash,
            "ready-without-hashes": ready_without_hashes,
        }.items():
            with self.subTest(case=name), self.assertRaises(benchmark.QualificationError):
                benchmark.validate_locked_configuration(lock, manifest)

    def test_forty_five_minute_range_guarantees_an_underfilled_final_window(self) -> None:
        manifest = benchmark.load_json(benchmark.CORPUS_MANIFEST)
        fixture = next(
            item for item in manifest["fixtures"] if item["id"] == "forty-five-minute"
        )
        minimum_duration, maximum_duration = fixture["durationRangeMs"]
        chunk_ms = manifest["thresholds"]["timing"]["finalWindowSizeMs"]
        stride_ms = manifest["thresholds"]["timing"]["longformBoundaryIntervalMs"]

        self.assertEqual(
            benchmark._final_window_start_ms(65_000, chunk_ms, stride_ms),
            52_000,
        )
        self.assertEqual(
            benchmark._final_window_start_ms(2_695_000, chunk_ms, stride_ms),
            2_678_000,
        )
        self.assertEqual(
            2_695_000
            - benchmark._final_window_start_ms(2_695_000, chunk_ms, stride_ms),
            17_000,
        )
        self.assertEqual(
            benchmark._first_full_final_window_duration_ms(
                minimum_duration,
                chunk_ms,
                stride_ms,
            ),
            2_708_000,
        )
        self.assertGreater(2_708_000, maximum_duration)
        self.assertEqual(
            benchmark._first_full_final_window_duration_ms(
                2_680_000,
                chunk_ms,
                stride_ms,
            ),
            2_682_000,
        )
        self.assertEqual(
            benchmark._first_full_final_window_duration_ms(
                2_700_000,
                chunk_ms,
                stride_ms,
            ),
            2_708_000,
        )

        for full_duration in (2_682_000, 2_708_000):
            with self.subTest(full_duration=full_duration):
                start = benchmark._final_window_start_ms(
                    full_duration,
                    chunk_ms,
                    stride_ms,
                )
                self.assertEqual(start + chunk_ms, full_duration)

    def test_manifest_pins_each_duration_class_and_required_phenomena(self) -> None:
        lock = benchmark.load_json(benchmark.ENGINE_LOCK)
        manifest = benchmark.load_json(benchmark.CORPUS_MANIFEST)
        for fixture in manifest["fixtures"]:
            fixture["durationRangeMs"] = [1000, 1000]
            fixture["requiredPhenomena"] = ["beginning-speech", "tail-speech"]

        with self.assertRaises(benchmark.QualificationError):
            benchmark.validate_locked_configuration(lock, manifest)

    def test_current_blocked_preflight_matches_the_committed_configuration(self) -> None:
        lock = benchmark.load_json(benchmark.ENGINE_LOCK)
        manifest = benchmark.load_json(benchmark.CORPUS_MANIFEST)
        source_plan = benchmark.load_json(benchmark.PUBLIC_SOURCE_PLAN)
        report = benchmark.load_json(
            benchmark.ROOT / "results" / "2026-09-12-local-preflight.json"
        )

        self.assertEqual(report["reportKind"], "preflight-only")
        self.assertEqual(report["qualificationStatus"], "blocked")
        self.assertEqual(report["engineLockSha256"], benchmark.canonical_json_sha256(lock))
        self.assertEqual(
            report["corpusManifestSha256"],
            benchmark.canonical_json_sha256(manifest),
        )
        self.assertEqual(report["publicSourcePlanId"], source_plan["planId"])
        self.assertEqual(
            report["publicSourcePlanSha256"],
            benchmark.canonical_json_sha256(source_plan),
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
            ("quality", "anchorBoundaryWindowWords"),
            ("quality", "minimumWordCountRatio"),
            ("quality", "maximumWordCountRatio"),
            ("quality", "maximumExcessRepeatedNgramRun"),
            ("timing", "minimumTimedWordRatio"),
            ("timing", "maximumZeroDurationWordRatio"),
            ("timing", "maximumTailLagMs"),
            ("timing", "maximumWordStartErrorMs"),
            ("timing", "maximumWordEndErrorMs"),
            ("timing", "minimumAlignedWordTimingRatio"),
            ("timing", "minimumLongPauseMs"),
            ("timing", "maximumLongPauseBoundaryErrorMs"),
            ("timing", "maximumLongPauseDurationErrorMs"),
            ("timing", "minimumLongPauseTimingRecall"),
            ("timing", "longformBoundaryIntervalMs"),
            ("timing", "maximumLongformBoundaryErrorMs"),
            ("timing", "minimumLongformBoundaryTimingRecall"),
            ("timing", "finalWindowSizeMs"),
            ("timing", "maximumFinalUnderfilledWindowErrorMs"),
            ("timing", "minimumFinalUnderfilledWindowTimingRecall"),
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
            "wordTimings": word_timings(8, last_end_ms=4750),
            "beginningAnchors": [["we", "[um]", "we"]],
            "tailAnchors": [["start", "now"]],
            "verbatimEvents": [
                {"kind": "filled-pause", "startWordIndex": 1, "endWordIndex": 1},
                {
                    "kind": "immediate-repetition",
                    "startWordIndex": 2,
                    "endWordIndex": 3,
                },
            ],
        }

    def candidate(self, text: str, word_count: int, *, invalid_timing: bool = False) -> dict:
        words = []
        tokens = benchmark.normalize_tokens(text)
        for index in range(word_count):
            start = index * 600
            end = start + 400
            word = tokens[index] if index < len(tokens) else f"extra{index}"
            words.append({"text": word, "startMs": start, "endMs": end})
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

    def test_exact_words_with_arbitrary_millisecond_timestamps_fail(self) -> None:
        candidate = self.candidate("we [um] we we need to start now", 8)
        for index, timing in enumerate(candidate["words"][:-1]):
            timing["startMs"] = index * 2
            timing["endMs"] = index * 2 + 1

        result = benchmark.evaluate_transcript(self.reference, candidate, self.thresholds)
        failed = {gate["gate"] for gate in result["gates"] if gate["status"] == "failed"}

        self.assertEqual(result["status"], "failed")
        self.assertIn("timing.maximum-word-start-error-ms", failed)
        self.assertIn("timing.maximum-word-end-error-ms", failed)
        self.assertIn("timing.aligned-word-timing-ratio", failed)

    def test_labeled_pause_and_longform_windows_require_kind_specific_timing(self) -> None:
        reference = {
            "schemaVersion": 1,
            "fixtureId": "forty-five-minute",
            "durationMs": 65000,
            "lastSpeechEndMs": 64500,
            "words": [
                "opening",
                "before",
                "after",
                "seam-left",
                "seam-right",
                "tail",
            ],
            "wordTimings": [
                {"startMs": 0, "endMs": 400},
                {"startMs": 23000, "endMs": 24500},
                {"startMs": 27500, "endMs": 28500},
                {"startMs": 51000, "endMs": 51900},
                {"startMs": 52100, "endMs": 52900},
                {"startMs": 64000, "endMs": 64500},
            ],
            "beginningAnchors": [["opening"]],
            "tailAnchors": [["tail"]],
            "verbatimEvents": [
                {"kind": "long-pause", "beforeWordIndex": 1, "afterWordIndex": 2},
                {
                    "kind": "longform-boundary",
                    "beforeWordIndex": 3,
                    "afterWordIndex": 4,
                    "boundaryMs": 52000,
                },
                {
                    "kind": "final-underfilled-window",
                    "startWordIndex": 4,
                    "endWordIndex": 5,
                    "windowStartMs": 52000,
                },
            ],
        }
        candidate = {
            "text": " ".join(reference["words"]),
            "words": [
                {"text": word, **timing}
                for word, timing in zip(reference["words"], reference["wordTimings"])
            ],
        }

        exact = benchmark.evaluate_transcript(reference, candidate, self.thresholds)
        self.assertEqual(exact["status"], "passed")

        cases = {
            "timing.long-pause-timing-recall": {
                2: {"startMs": 25000, "endMs": 26000},
            },
            "timing.longform-boundary-timing-recall": {
                3: {"startMs": 54000, "endMs": 54900},
                4: {"startMs": 55100, "endMs": 55900},
            },
            "timing.final-underfilled-window-timing-recall": {
                5: {"startMs": 60500, "endMs": 61000},
            },
        }
        for expected_gate, replacements in cases.items():
            with self.subTest(gate=expected_gate):
                moved = copy.deepcopy(candidate)
                for index, timing in replacements.items():
                    moved["words"][index].update(timing)
                result = benchmark.evaluate_transcript(reference, moved, self.thresholds)
                failed = {
                    gate["gate"] for gate in result["gates"] if gate["status"] == "failed"
                }
                self.assertIn(expected_gate, failed)

    def test_final_underfilled_window_requires_its_complete_contiguous_span(self) -> None:
        reference = {
            "schemaVersion": 1,
            "fixtureId": "forty-five-minute",
            "durationMs": 65000,
            "lastSpeechEndMs": 64500,
            "words": [
                "opening",
                "one",
                "two",
                "three",
                "four",
                "before-window",
                "window-one",
                "window-two",
                "window-three",
                "tail",
            ],
            "wordTimings": [
                {"startMs": 0, "endMs": 400},
                {"startMs": 5000, "endMs": 5400},
                {"startMs": 10000, "endMs": 10400},
                {"startMs": 30000, "endMs": 30400},
                {"startMs": 40000, "endMs": 40400},
                {"startMs": 58000, "endMs": 59000},
                {"startMs": 60500, "endMs": 61000},
                {"startMs": 61500, "endMs": 62000},
                {"startMs": 62500, "endMs": 63000},
                {"startMs": 64000, "endMs": 64500},
            ],
            "beginningAnchors": [["opening"]],
            "tailAnchors": [["tail"]],
            "verbatimEvents": [
                {
                    "kind": "final-underfilled-window",
                    "startWordIndex": 5,
                    "endWordIndex": 9,
                    "windowStartMs": 52000,
                }
            ],
        }
        retained_indices = [0, 1, 2, 3, 4, 5, 6, 8, 9]
        candidate = {
            "text": " ".join(reference["words"][index] for index in retained_indices),
            "words": [
                {
                    "text": reference["words"][index],
                    **reference["wordTimings"][index],
                }
                for index in retained_indices
            ],
        }

        result = benchmark.evaluate_transcript(reference, candidate, self.thresholds)
        final_window = next(
            gate
            for gate in result["gates"]
            if gate["gate"] == "timing.final-underfilled-window-timing-recall"
        )

        self.assertEqual(result["status"], "failed")
        self.assertEqual(final_window["status"], "failed")

    def test_collapse_and_pathological_repetition_fail_closed(self) -> None:
        candidate = self.candidate("we we we we", 4)

        result = benchmark.evaluate_transcript(self.reference, candidate, self.thresholds)
        failed = {gate["gate"] for gate in result["gates"] if gate["status"] == "failed"}

        self.assertEqual(result["status"], "failed")
        self.assertIn("quality.word-error-rate", failed)
        self.assertIn("quality.verbatim-event-recall", failed)
        self.assertIn("quality.beginning-anchor-coverage", failed)
        self.assertIn("quality.tail-anchor-coverage", failed)
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

    def test_text_and_timed_word_count_must_describe_the_same_candidate(self) -> None:
        candidate = self.candidate("we [um] we we need to start now", 8)
        candidate["words"].append({"text": "extra", "startMs": 4800, "endMs": 4900})

        result = benchmark.evaluate_transcript(self.reference, candidate, self.thresholds)
        failed = {gate["gate"] for gate in result["gates"] if gate["status"] == "failed"}

        self.assertEqual(result["status"], "failed")
        self.assertIn("timing.text-word-count-match", failed)

    def test_timed_words_must_match_the_candidate_text(self) -> None:
        candidate = self.candidate("we [um] we we need to start now", 8)
        candidate["words"][4]["text"] = "changed"

        result = benchmark.evaluate_transcript(self.reference, candidate, self.thresholds)
        failed = {gate["gate"] for gate in result["gates"] if gate["status"] == "failed"}

        self.assertEqual(result["status"], "failed")
        self.assertIn("timing.text-word-content-match", failed)

    def test_malformed_timed_words_raise_a_bounded_qualification_error(self) -> None:
        candidate = {
            "text": "we [um] we we need to start now",
            "words": "not-a-word-array",
        }

        with self.assertRaises(benchmark.QualificationError):
            benchmark.evaluate_transcript(self.reference, candidate, self.thresholds)

    def test_each_timed_word_must_normalize_to_exactly_one_candidate_token(self) -> None:
        candidate = self.candidate("we [um] we we need to start now", 8)
        candidate["words"][0]["text"] = "we [um]"
        candidate["words"][1]["text"] = ""

        result = benchmark.evaluate_transcript(self.reference, candidate, self.thresholds)
        failed = {gate["gate"] for gate in result["gates"] if gate["status"] == "failed"}

        self.assertEqual(result["status"], "failed")
        self.assertIn("timing.one-token-per-word", failed)
        self.assertIn("timing.text-word-content-match", failed)

    def test_repetition_gate_detects_loops_longer_than_five_tokens(self) -> None:
        phrase = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
        reference = {
            **self.reference,
            "durationMs": 12000,
            "lastSpeechEndMs": 11000,
            "words": phrase,
            "wordTimings": word_timings(len(phrase), last_end_ms=11000),
            "beginningAnchors": [phrase[:2]],
            "tailAnchors": [phrase[-2:]],
            "verbatimEvents": [
                {"kind": "quiet-speech", "startWordIndex": 2, "endWordIndex": 3}
            ],
        }
        repeated = phrase * 3
        candidate = self.candidate(" ".join(repeated), len(repeated))
        candidate["words"][-1]["endMs"] = 11000

        result = benchmark.evaluate_transcript(reference, candidate, self.thresholds)
        repetition_gate = next(
            gate
            for gate in result["gates"]
            if gate["gate"] == "quality.excess-repeated-ngram-run"
        )

        self.assertEqual(result["measurements"]["candidateMaximumRepeatedNgramRun"], 3)
        self.assertEqual(repetition_gate["status"], "failed")

    def test_boundary_anchors_do_not_pass_when_they_only_appear_in_the_middle(self) -> None:
        middle = [f"word{index}" for index in range(26)]
        reference_words = ["opening", "anchor", *middle, "tail", "anchor"]
        candidate_words = list(reference_words)
        candidate_words[:2] = ["missing", "opening"]
        candidate_words[-2:] = ["missing", "tail"]
        candidate_words[10:12] = ["opening", "anchor"]
        candidate_words[18:20] = ["tail", "anchor"]
        reference = {
            **self.reference,
            "durationMs": 30000,
            "lastSpeechEndMs": 29500,
            "words": reference_words,
            "wordTimings": word_timings(len(reference_words), last_end_ms=29500),
            "beginningAnchors": [["opening", "anchor"]],
            "tailAnchors": [["tail", "anchor"]],
            "verbatimEvents": [
                {
                    "kind": "quiet-speech",
                    "startWordIndex": 14,
                    "endWordIndex": 14,
                }
            ],
        }
        thresholds = copy.deepcopy(self.thresholds)
        thresholds["quality"]["anchorBoundaryWindowWords"] = 5
        candidate = self.candidate(" ".join(candidate_words), len(candidate_words))
        candidate["words"][-1]["endMs"] = 29500

        result = benchmark.evaluate_transcript(reference, candidate, thresholds)
        status_by_gate = {gate["gate"]: gate["status"] for gate in result["gates"]}

        self.assertEqual(status_by_gate["quality.beginning-anchor-coverage"], "failed")
        self.assertEqual(status_by_gate["quality.tail-anchor-coverage"], "failed")

    def test_timing_rejects_reference_duration_that_disagrees_with_audio(self) -> None:
        candidate = self.candidate("we [um] we we need to start now", 8)

        with self.assertRaises(benchmark.QualificationError):
            benchmark.evaluate_transcript(
                self.reference,
                candidate,
                self.thresholds,
                audio_duration_ms=4000,
            )


class PreflightTests(unittest.TestCase):
    def reasons_for_single_reference(
        self,
        reference: dict,
        required_phenomena: list[str],
    ) -> list[str]:
        lock = copy.deepcopy(benchmark.load_json(benchmark.ENGINE_LOCK))
        manifest = copy.deepcopy(benchmark.load_json(benchmark.CORPUS_MANIFEST))
        source_plan = copy.deepcopy(benchmark.load_json(benchmark.PUBLIC_SOURCE_PLAN))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixtures_dir = root / "fixtures"
            (fixtures_dir / "audio").mkdir(parents=True)
            (fixtures_dir / "reference").mkdir(parents=True)
            fixture = next(item for item in manifest["fixtures"] if item["id"] == "short")
            fixture["assetStatus"] = "ready"
            fixture["durationRangeMs"] = [1000, 1000]
            fixture["requiredPhenomena"] = required_phenomena
            audio_path = fixtures_dir / fixture["audioPath"]
            with wave.open(str(audio_path), "wb") as audio:
                audio.setnchannels(1)
                audio.setsampwidth(2)
                audio.setframerate(16000)
                audio.writeframes(b"\0\0" * 16000)
            reference_path = fixtures_dir / fixture["referencePath"]
            reference_path.write_text(json.dumps(reference), encoding="utf-8")
            fixture["audioSha256"] = benchmark.sha256_file(audio_path)
            fixture["referenceSha256"] = benchmark.sha256_file(reference_path)
            planned_fixture = next(
                item for item in source_plan["fixtures"] if item["id"] == "short"
            )
            planned_fixture["durationMs"] = 1000
            planned_fixture["candidateAudioSha256"] = fixture["audioSha256"]
            bind_manifest_to_source_plan(manifest, source_plan)
            fixture_specs = dict(benchmark.EXPECTED_FIXTURE_SPECS)
            fixture_specs["short"] = (
                (1000, 1000),
                frozenset(required_phenomena),
            )
            with mock.patch.object(
                benchmark,
                "EXPECTED_FIXTURE_SPECS",
                fixture_specs,
            ):
                _, reasons = benchmark.preflight(
                    lock,
                    manifest,
                    fixtures_dir,
                    None,
                    source_plan=source_plan,
                )
            return reasons["short"]

    def test_required_phenomena_need_valid_event_or_anchor_labels(self) -> None:
        base = {
            "schemaVersion": 1,
            "fixtureId": "short",
            "durationMs": 1000,
            "lastSpeechEndMs": 900,
            "words": ["opening", "[um]", "repeat", "repeat", "tail"],
            "wordTimings": [
                {"startMs": 0, "endMs": 100},
                {"startMs": 150, "endMs": 250},
                {"startMs": 300, "endMs": 400},
                {"startMs": 450, "endMs": 550},
                {"startMs": 800, "endMs": 900},
            ],
            "phenomena": [
                "beginning-speech",
                "filled-pause",
                "immediate-repetition",
                "tail-speech",
            ],
            "beginningAnchors": [["opening"]],
            "tailAnchors": [["tail"]],
            "verbatimEvents": [],
        }
        required = list(base["phenomena"])
        missing_labels = self.reasons_for_single_reference(base, required)

        valid = copy.deepcopy(base)
        valid["verbatimEvents"] = [
            {"kind": "filled-pause", "startWordIndex": 1, "endWordIndex": 1},
            {
                "kind": "immediate-repetition",
                "startWordIndex": 2,
                "endWordIndex": 3,
            },
        ]
        valid_labels = self.reasons_for_single_reference(valid, required)

        unknown_event = copy.deepcopy(base)
        unknown_event["phenomena"].append("invented-event")
        unknown_event["verbatimEvents"] = [
            {"kind": "invented-event", "startWordIndex": 2, "endWordIndex": 2}
        ]
        invalid_kinds = self.reasons_for_single_reference(unknown_event, required)

        misplaced_anchors = copy.deepcopy(base)
        misplaced_anchors["phenomena"] = ["beginning-speech", "tail-speech"]
        misplaced_anchors["beginningAnchors"] = [["repeat"]]
        misplaced_anchors["tailAnchors"] = [["opening"]]
        invalid_anchors = self.reasons_for_single_reference(
            misplaced_anchors,
            ["beginning-speech", "tail-speech"],
        )

        malformed_anchor_tokens = copy.deepcopy(valid)
        malformed_anchor_tokens["beginningAnchors"] = [["opening [um]", "!!!"]]
        invalid_anchor_tokens = self.reasons_for_single_reference(
            malformed_anchor_tokens,
            required,
        )

        self.assertIn("REFERENCE_PHENOMENA_INCOMPLETE", missing_labels)
        self.assertNotIn("REFERENCE_PHENOMENA_INCOMPLETE", valid_labels)
        self.assertNotIn("REFERENCE_EVENT_INVALID", valid_labels)
        self.assertIn("REFERENCE_EVENT_INVALID", invalid_kinds)
        self.assertIn("REFERENCE_ANCHORS_INVALID", invalid_anchors)
        self.assertIn("REFERENCE_ANCHORS_INVALID", invalid_anchor_tokens)

    def test_reference_words_are_nonempty_single_string_tokens(self) -> None:
        base = {
            "schemaVersion": 1,
            "fixtureId": "short",
            "durationMs": 1000,
            "lastSpeechEndMs": 900,
            "words": ["opening", "tail"],
            "wordTimings": [
                {"startMs": 0, "endMs": 400},
                {"startMs": 600, "endMs": 900},
            ],
            "phenomena": ["beginning-speech", "tail-speech"],
            "beginningAnchors": [["opening"]],
            "tailAnchors": [["tail"]],
            "verbatimEvents": [],
        }

        for words in (
            [],
            ["opening", 7],
            ["opening", None],
            ["opening", {"word": "tail"}],
            ["opening", "two words"],
        ):
            with self.subTest(words=words):
                invalid = copy.deepcopy(base)
                invalid["words"] = words
                reasons = self.reasons_for_single_reference(
                    invalid,
                    ["beginning-speech", "tail-speech"],
                )
                self.assertIn("REFERENCE_WORDS_INVALID", reasons)

    def test_reference_requires_complete_hand_aligned_word_timings(self) -> None:
        reference = {
            "schemaVersion": 1,
            "fixtureId": "short",
            "durationMs": 1000,
            "lastSpeechEndMs": 900,
            "words": ["opening", "tail"],
            "wordTimings": [{"startMs": 0, "endMs": 400}],
            "phenomena": ["beginning-speech", "tail-speech"],
            "beginningAnchors": [["opening"]],
            "tailAnchors": [["tail"]],
            "verbatimEvents": [],
        }

        reasons = self.reasons_for_single_reference(
            reference,
            ["beginning-speech", "tail-speech"],
        )

        self.assertIn("REFERENCE_WORD_TIMINGS_INVALID", reasons)

    def test_reference_duration_must_match_frame_derived_audio_duration(self) -> None:
        lock = copy.deepcopy(benchmark.load_json(benchmark.ENGINE_LOCK))
        manifest = copy.deepcopy(benchmark.load_json(benchmark.CORPUS_MANIFEST))
        source_plan = copy.deepcopy(benchmark.load_json(benchmark.PUBLIC_SOURCE_PLAN))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixtures_dir = root / "fixtures"
            (fixtures_dir / "audio").mkdir(parents=True)
            (fixtures_dir / "reference").mkdir(parents=True)
            fixture = next(item for item in manifest["fixtures"] if item["id"] == "short")
            fixture["assetStatus"] = "ready"
            fixture["durationRangeMs"] = [1000, 1001]
            fixture["requiredPhenomena"] = ["beginning-speech", "tail-speech"]
            audio_path = fixtures_dir / fixture["audioPath"]
            with wave.open(str(audio_path), "wb") as audio:
                audio.setnchannels(1)
                audio.setsampwidth(2)
                audio.setframerate(16000)
                audio.writeframes(b"\0\0" * 16001)
            reference = {
                "schemaVersion": 1,
                "fixtureId": "short",
                "durationMs": 1000,
                "lastSpeechEndMs": 900,
                "words": ["opening", "tail"],
                "wordTimings": [
                    {"startMs": 0, "endMs": 400},
                    {"startMs": 600, "endMs": 900},
                ],
                "phenomena": ["beginning-speech", "tail-speech"],
                "beginningAnchors": [["opening"]],
                "tailAnchors": [["tail"]],
                "verbatimEvents": [],
            }
            reference_path = fixtures_dir / fixture["referencePath"]
            reference_path.write_text(json.dumps(reference), encoding="utf-8")
            fixture["audioSha256"] = benchmark.sha256_file(audio_path)
            fixture["referenceSha256"] = benchmark.sha256_file(reference_path)
            planned_fixture = next(
                item for item in source_plan["fixtures"] if item["id"] == "short"
            )
            planned_fixture["durationMs"] = 1001
            planned_fixture["candidateAudioSha256"] = fixture["audioSha256"]
            bind_manifest_to_source_plan(manifest, source_plan)

            fixture_specs = dict(benchmark.EXPECTED_FIXTURE_SPECS)
            fixture_specs["short"] = (
                (1000, 1001),
                frozenset({"beginning-speech", "tail-speech"}),
            )
            with mock.patch.object(
                benchmark,
                "EXPECTED_FIXTURE_SPECS",
                fixture_specs,
            ):
                _, reasons = benchmark.preflight(
                    lock,
                    manifest,
                    fixtures_dir,
                    None,
                    source_plan=source_plan,
                )

        self.assertIn("REFERENCE_AUDIO_DURATION_MISMATCH", reasons["short"])

    def test_ready_external_assets_are_explicitly_reported_as_passed(self) -> None:
        lock = copy.deepcopy(benchmark.load_json(benchmark.ENGINE_LOCK))
        lock["engine"]["audoraCompatibilityPatchId"] = (
            "test-active-inference-callback-v1"
        )
        manifest = copy.deepcopy(benchmark.load_json(benchmark.CORPUS_MANIFEST))
        source_plan = copy.deepcopy(benchmark.load_json(benchmark.PUBLIC_SOURCE_PLAN))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixtures_dir = root / "fixtures"
            model_dir = root / "model"
            (fixtures_dir / "audio").mkdir(parents=True)
            (fixtures_dir / "reference").mkdir(parents=True)
            model_dir.mkdir()

            package_lock = b"locked dependencies\n"
            (root / lock["runtime"]["packageLock"]).write_bytes(package_lock)
            lock["runtime"]["packageLockSha256"] = hashlib.sha256(package_lock).hexdigest()

            model = b"pinned model"
            lock["model"]["files"] = {
                "model.safetensors": hashlib.sha256(model).hexdigest()
            }
            (model_dir / "model.safetensors").write_bytes(model)

            for fixture in manifest["fixtures"]:
                fixture["assetStatus"] = "ready"
                fixture["durationRangeMs"] = [1000, 1000]
                fixture["requiredPhenomena"] = [
                    "beginning-speech",
                    "tail-speech",
                ]
                audio_path = fixtures_dir / fixture["audioPath"]
                with wave.open(str(audio_path), "wb") as audio:
                    audio.setnchannels(1)
                    audio.setsampwidth(2)
                    audio.setframerate(16000)
                    audio.writeframes(b"\0\0" * 16000)
                reference = {
                    "schemaVersion": 1,
                    "fixtureId": fixture["id"],
                    "durationMs": 1000,
                    "lastSpeechEndMs": 900,
                    "words": ["hello"],
                    "wordTimings": [{"startMs": 0, "endMs": 900}],
                    "beginningAnchors": [["hello"]],
                    "tailAnchors": [["hello"]],
                    "verbatimEvents": [],
                    "phenomena": fixture["requiredPhenomena"],
                }
                reference_path = fixtures_dir / fixture["referencePath"]
                reference_path.write_text(json.dumps(reference), encoding="utf-8")
                fixture["audioSha256"] = benchmark.sha256_file(audio_path)
                fixture["referenceSha256"] = benchmark.sha256_file(reference_path)
                planned_fixture = next(
                    item
                    for item in source_plan["fixtures"]
                    if item["id"] == fixture["id"]
                )
                planned_fixture["durationMs"] = 1000
                planned_fixture["candidateAudioSha256"] = fixture["audioSha256"]

            bind_manifest_to_source_plan(manifest, source_plan)

            versions = {
                "crisperwhisper": "2.0.0",
                "torch": "2.13.0",
                "transformers": "5.14.1",
                "accelerate": "1.14.0",
                "numpy": "2.5.1",
                "soundfile": "0.14.0",
                "soxr": "1.1.0",
                "tokenizers": "0.22.2",
                "huggingface-hub": "1.24.0",
            }
            fixture_specs = {
                fixture_id: (
                    (1000, 1000),
                    frozenset({"beginning-speech", "tail-speech"}),
                )
                for fixture_id in benchmark.EXPECTED_FIXTURES
            }
            with (
                mock.patch.object(benchmark, "ROOT", root),
                mock.patch.object(
                    benchmark,
                    "EXPECTED_FIXTURE_SPECS",
                    fixture_specs,
                ),
                mock.patch.object(
                    benchmark.importlib.metadata,
                    "version",
                    side_effect=versions.__getitem__,
                ),
                mock.patch.object(
                    benchmark.platform,
                    "python_version",
                    return_value=lock["runtime"]["pythonVersion"],
                ),
                mock.patch.object(benchmark.platform, "system", return_value="Darwin"),
                mock.patch.object(benchmark.platform, "machine", return_value="arm64"),
            ):
                gates, reasons = benchmark.preflight(
                    lock,
                    manifest,
                    fixtures_dir,
                    model_dir,
                    source_plan=source_plan,
                )

        self.assertTrue(all(gate.status == "passed" for gate in gates))
        self.assertTrue(all(not fixture_reasons for fixture_reasons in reasons.values()))
        self.assertEqual(
            {
                gate.gate
                for gate in gates
                if gate.gate.endswith(".asset-status") and gate.status == "passed"
            },
            {
                f"fixture.{fixture_id}.asset-status"
                for fixture_id in benchmark.EXPECTED_FIXTURES
            },
        )

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

    def test_preflight_blocks_unpinned_public_derived_audio_hashes(self) -> None:
        lock = benchmark.load_json(benchmark.ENGINE_LOCK)
        manifest = benchmark.load_json(benchmark.CORPUS_MANIFEST)
        source_plan = benchmark.load_json(benchmark.PUBLIC_SOURCE_PLAN)
        with tempfile.TemporaryDirectory() as directory:
            gates, reasons = benchmark.preflight(
                lock,
                manifest,
                Path(directory),
                None,
                source_plan=source_plan,
            )

        gates_by_name = {gate.gate: gate for gate in gates}
        for fixture_id in ("short", "one-minute"):
            self.assertEqual(
                gates_by_name[f"fixture.{fixture_id}.public-derived-audio-hash"].status,
                "passed",
            )
        for fixture_id in ("twelve-minute", "forty-five-minute"):
            gate = gates_by_name[
                f"fixture.{fixture_id}.public-derived-audio-hash"
            ]
            self.assertEqual(gate.status, "blocked")
            self.assertEqual(gate.reason, "DERIVED_AUDIO_HASH_NOT_PINNED")
            self.assertIn("DERIVED_AUDIO_HASH_NOT_PINNED", reasons[fixture_id])

    def test_blocked_report_records_public_source_plan_and_fixture_provenance(self) -> None:
        lock = benchmark.load_json(benchmark.ENGINE_LOCK)
        manifest = benchmark.load_json(benchmark.CORPUS_MANIFEST)
        source_plan = benchmark.load_json(benchmark.PUBLIC_SOURCE_PLAN)
        with tempfile.TemporaryDirectory() as directory:
            gates, reasons = benchmark.preflight(
                lock,
                manifest,
                Path(directory),
                None,
                source_plan=source_plan,
            )
        report = benchmark.blocked_report(
            lock,
            manifest,
            gates,
            reasons,
            source_plan=source_plan,
        )

        self.assertEqual(report["publicSourcePlanId"], source_plan["planId"])
        self.assertEqual(
            report["publicSourcePlanSha256"],
            "b2570a7ee4a4ad08f93ccda227861e5431e4ab392c0654db923120fa87fe70e9",
        )
        provenance_by_id = {
            fixture["id"]: fixture["sourceProvenance"]
            for fixture in report["fixtures"]
        }
        self.assertEqual(
            provenance_by_id,
            {
                fixture["id"]: {
                    "sourceId": fixture["sourceId"],
                    "startMs": fixture["startMs"],
                    "durationMs": fixture["durationMs"],
                    "candidateAudioSha256": fixture["candidateAudioSha256"],
                }
                for fixture in source_plan["fixtures"]
            },
        )

    def test_preflight_blocks_cancellation_without_inside_model_active_proof(self) -> None:
        lock = benchmark.load_json(benchmark.ENGINE_LOCK)
        manifest = benchmark.load_json(benchmark.CORPUS_MANIFEST)
        with tempfile.TemporaryDirectory() as directory:
            gates, reasons = benchmark.preflight(lock, manifest, Path(directory), None)
        report = benchmark.blocked_report(lock, manifest, gates, reasons)
        proof_gate = next(
            gate for gate in gates if gate.gate == "cancellation.active-inference-proof"
        )

        self.assertEqual(proof_gate.status, "blocked")
        self.assertEqual(proof_gate.reason, "ACTIVE_INFERENCE_PROOF_UNAVAILABLE")
        self.assertIn(
            "ACTIVE_INFERENCE_PROOF_UNAVAILABLE",
            report["cancellation"]["reasonCodes"],
        )

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


class CancellationExecutionTests(unittest.TestCase):
    def test_current_profile_does_not_start_a_worker_without_active_proof(self) -> None:
        manifest = benchmark.load_json(benchmark.CORPUS_MANIFEST)
        fixture = next(
            item for item in manifest["fixtures"] if item["id"] == "forty-five-minute"
        )
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            benchmark,
            "WorkerSession",
            side_effect=AssertionError("worker must not start"),
        ):
            root = Path(directory)
            result = benchmark.run_cancellation(
                fixture,
                manifest,
                root / "fixtures",
                root / "model",
                root / "workspace",
            )

        active_gate = next(
            gate
            for gate in result["gates"]
            if gate["gate"] == "cancellation.transcription-active"
        )
        self.assertEqual(result["status"], "failed")
        self.assertFalse(result["activeInferenceAcknowledged"])
        self.assertEqual(active_gate["reason"], "ACTIVE_INFERENCE_PROOF_UNAVAILABLE")

    def test_early_completion_cannot_satisfy_cancellation(self) -> None:
        class Process:
            def poll(self) -> int:
                return 0

        class EarlyCompletionSession:
            def __init__(self, *unused: object, **unused_keywords: object) -> None:
                self.process = Process()

            def hello(self) -> dict:
                return {"modelLoadSeconds": 1.0}

            def begin_transcribe(self, fixture_id: str, audio_path: Path) -> None:
                return None

            def await_transcription_started(
                self,
                fixture_id: str,
                timeout: float,
                *,
                require_active_proof: bool = False,
            ) -> None:
                return None

            def require_transcription_active_for(self, fixture_id: str, duration: float) -> None:
                raise benchmark.QualificationError("transcription completed before cancellation")

            def terminate_for_cancellation(self, maximum_seconds: float) -> tuple[float, bool]:
                return 0.1, False

            def close(self) -> None:
                return None

        manifest = benchmark.load_json(benchmark.CORPUS_MANIFEST)
        fixture = next(
            item for item in manifest["fixtures"] if item["id"] == "forty-five-minute"
        )
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            benchmark,
            "WorkerSession",
            EarlyCompletionSession,
        ), mock.patch.object(
            benchmark,
            "_active_inference_proof_reason",
            return_value=None,
        ), mock.patch.object(benchmark.time, "sleep"):
            root = Path(directory)
            with self.assertRaises(benchmark.QualificationError):
                benchmark.run_cancellation(
                    fixture,
                    manifest,
                    root / "fixtures",
                    root / "model",
                    root / "workspace",
                )

    def test_completed_cancellation_worker_streams_are_closed(self) -> None:
        class Process:
            def poll(self) -> int:
                return -15

        class CompletedSession:
            closed = False

            def __init__(self, *unused: object, **unused_keywords: object) -> None:
                self.process = Process()

            def hello(self) -> dict:
                return {"modelLoadSeconds": 1.0}

            def begin_transcribe(self, fixture_id: str, audio_path: Path) -> None:
                return None

            def await_transcription_started(
                self,
                fixture_id: str,
                timeout: float,
                *,
                require_active_proof: bool = False,
            ) -> None:
                return None

            def require_transcription_active_for(self, fixture_id: str, duration: float) -> None:
                return None

            def terminate_for_cancellation(self, maximum_seconds: float) -> tuple[float, bool]:
                return 0.1, False

            def close(self) -> None:
                type(self).closed = True

        manifest = benchmark.load_json(benchmark.CORPUS_MANIFEST)
        fixture = next(
            item for item in manifest["fixtures"] if item["id"] == "forty-five-minute"
        )
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            benchmark,
            "WorkerSession",
            CompletedSession,
        ), mock.patch.object(
            benchmark,
            "_active_inference_proof_reason",
            return_value=None,
        ):
            root = Path(directory)
            benchmark.run_cancellation(
                fixture,
                manifest,
                root / "fixtures",
                root / "model",
                root / "workspace",
            )

        self.assertTrue(CompletedSession.closed)


class WorkerSessionTests(unittest.TestCase):
    @staticmethod
    def session_with_stdout(stdout: object) -> benchmark.WorkerSession:
        class Process:
            def __init__(self) -> None:
                self.stdout = stdout

            def poll(self) -> None:
                return None

        session = benchmark.WorkerSession.__new__(benchmark.WorkerSession)
        session.process = Process()
        session._stdout_buffer = bytearray()
        return session

    @staticmethod
    def hello_session(message: dict, *, network_guarded: bool = False) -> benchmark.WorkerSession:
        session = benchmark.WorkerSession.__new__(benchmark.WorkerSession)
        session.lock = benchmark.load_json(benchmark.ENGINE_LOCK)
        session.network_guarded = network_guarded
        session._read_json = mock.Mock(return_value=message)
        return session

    @staticmethod
    def valid_hello() -> dict:
        lock = benchmark.load_json(benchmark.ENGINE_LOCK)
        return {
            "type": "hello",
            "qualificationProfileId": lock["qualificationProfileId"],
            "engineLockSha256": benchmark.canonical_json_sha256(lock),
            "modelLoadSeconds": 1.25,
            "packageVersions": {
                "crisperwhisper": "2.0.0",
                "torch": "2.13.0",
                "transformers": "5.14.1",
                "accelerate": "1.14.0",
                "numpy": "2.5.1",
                "soundfile": "0.14.0",
                "soxr": "1.1.0",
                "tokenizers": "0.22.2",
                "huggingface-hub": "1.24.0",
            },
            "networkProbe": "not-denied",
        }

    def test_hello_strictly_matches_the_pinned_worker_identity(self) -> None:
        valid = self.valid_hello()
        self.assertEqual(self.hello_session(valid).hello(), valid)

        invalid_messages: list[tuple[str, dict, bool]] = []
        wrong_profile = copy.deepcopy(valid)
        wrong_profile["qualificationProfileId"] = "another-profile"
        invalid_messages.append(("profile", wrong_profile, False))
        wrong_lock = copy.deepcopy(valid)
        wrong_lock["engineLockSha256"] = "0" * 64
        invalid_messages.append(("lock", wrong_lock, False))
        wrong_packages = copy.deepcopy(valid)
        wrong_packages["packageVersions"]["torch"] = "0.0.0"
        invalid_messages.append(("packages", wrong_packages, False))
        boolean_time = copy.deepcopy(valid)
        boolean_time["modelLoadSeconds"] = True
        invalid_messages.append(("boolean-time", boolean_time, False))
        negative_time = copy.deepcopy(valid)
        negative_time["modelLoadSeconds"] = -0.1
        invalid_messages.append(("negative-time", negative_time, False))
        bad_network = copy.deepcopy(valid)
        bad_network["networkProbe"] = "unknown"
        invalid_messages.append(("network-type", bad_network, False))
        unproved_guard = copy.deepcopy(valid)
        invalid_messages.append(("guarded-network", unproved_guard, True))
        extra_field = copy.deepcopy(valid)
        extra_field["modelPath"] = "/private/model"
        invalid_messages.append(("extra-field", extra_field, False))

        for name, message, guarded in invalid_messages:
            with self.subTest(case=name), self.assertRaises(benchmark.QualificationError):
                self.hello_session(message, network_guarded=guarded).hello()

    def test_partial_protocol_line_cannot_block_past_timeout(self) -> None:
        read_fd, write_fd = os.pipe()
        stdout = os.fdopen(read_fd, "r", encoding="utf-8")
        os.write(write_fd, b'{"type":')
        session = self.session_with_stdout(stdout)
        outcome: list[BaseException] = []

        def read() -> None:
            try:
                session._read_json(0.05)
            except BaseException as error:
                outcome.append(error)

        reader = threading.Thread(target=read)
        reader.start()
        reader.join(timeout=0.25)
        completed_before_cleanup = not reader.is_alive()
        os.close(write_fd)
        reader.join(timeout=1)
        stdout.close()

        self.assertTrue(completed_before_cleanup)
        self.assertEqual(len(outcome), 1)
        self.assertIsInstance(outcome[0], benchmark.QualificationError)
        self.assertIn("timed out", str(outcome[0]))

    def test_transcription_ack_and_result_share_one_deadline(self) -> None:
        session = benchmark.WorkerSession.__new__(benchmark.WorkerSession)
        session.begin_transcribe = mock.Mock()
        session.await_transcription_started = mock.Mock()
        session._read_json = mock.Mock(
            return_value={"type": "result", "fixtureId": "short"}
        )
        audio_path = Path("fixture.wav")

        with mock.patch.object(
            benchmark.time,
            "monotonic",
            side_effect=[100.0, 101.0, 103.0],
        ):
            result = session.send_transcribe("short", audio_path, 10.0)

        self.assertEqual(result["type"], "result")
        session.await_transcription_started.assert_called_once_with("short", 9.0)
        session._read_json.assert_called_once_with(7.0)

    def test_buffered_early_result_fails_active_cancellation_window(self) -> None:
        read_fd, write_fd = os.pipe()
        stdout = os.fdopen(read_fd, "r", encoding="utf-8")
        os.write(
            write_fd,
            b'{"type":"transcription-started","fixtureId":"long"}\n'
            b'{"type":"result","fixtureId":"long"}\n',
        )
        session = self.session_with_stdout(stdout)

        acknowledgement = session._read_json(0.1)
        with self.assertRaises(benchmark.QualificationError):
            session.require_transcription_active_for("long", 0.01)

        self.assertEqual(acknowledgement["type"], "transcription-started")
        os.close(write_fd)
        stdout.close()

    def test_pre_call_acknowledgement_is_not_active_inference_proof(self) -> None:
        read_fd, write_fd = os.pipe()
        stdout = os.fdopen(read_fd, "r", encoding="utf-8")
        os.write(
            write_fd,
            b'{"type":"transcription-started","fixtureId":"long"}\n',
        )
        session = self.session_with_stdout(stdout)

        with self.assertRaises(benchmark.QualificationError):
            session.await_transcription_started(
                "long",
                0.1,
                require_active_proof=True,
            )

        os.close(write_fd)
        stdout.close()

    def test_close_escalates_and_reaps_a_worker_that_ignores_termination(self) -> None:
        class Stream:
            def __init__(self) -> None:
                self.writes: list[object] = []
                self.closed = False

            def write(self, value: object) -> None:
                self.writes.append(value)

            def flush(self) -> None:
                return None

            def close(self) -> None:
                self.closed = True

        class Process:
            def __init__(self) -> None:
                self.stdin = Stream()
                self.stdout = Stream()
                self.status: int | None = None
                self.wait_count = 0
                self.terminated = False
                self.killed = False

            def poll(self) -> int | None:
                return self.status

            def wait(self, timeout: float) -> int:
                self.wait_count += 1
                if self.wait_count <= 2:
                    raise subprocess.TimeoutExpired("worker", timeout)
                self.status = -9
                return self.status

            def terminate(self) -> None:
                self.terminated = True

            def kill(self) -> None:
                self.killed = True

        process = Process()
        session = benchmark.WorkerSession.__new__(benchmark.WorkerSession)
        session.process = process
        session._stdout_buffer = bytearray()
        session._monitor_stop = threading.Event()
        session._monitor = mock.Mock()

        session.close()

        self.assertTrue(process.terminated)
        self.assertTrue(process.killed)
        self.assertEqual(process.wait_count, 3)
        self.assertIsNotNone(process.poll())
        self.assertTrue(process.stdin.closed)
        self.assertTrue(process.stdout.closed)


class FixtureExecutionTests(unittest.TestCase):
    def test_runtime_uses_canonical_audio_duration_and_fails_missing_memory(self) -> None:
        class Session:
            def __init__(self, *unused: object, **unused_keywords: object) -> None:
                self.peak_resident_bytes = None

            def hello(self) -> dict:
                return {"modelLoadSeconds": 0.1}

            def send_transcribe(self, fixture_id: str, audio_path: Path, timeout: float) -> dict:
                return {
                    "text": "opening tail",
                    "words": [
                        {"text": "opening", "startMs": 0, "endMs": 400},
                        {"text": "tail", "startMs": 600, "endMs": 1000},
                    ],
                    "elapsedSeconds": 0.1,
                }

            def close(self) -> None:
                return None

        class Thermal:
            def __init__(self, workspace: Path) -> None:
                return None

            def prepare(self) -> None:
                return None

            def start(self) -> None:
                return None

            def stop(self) -> None:
                return None

            def wait_for_recovery(self, target: str, maximum_seconds: float) -> float:
                return 0.0

            def maximum_state(self) -> str:
                return "fair"

        manifest = copy.deepcopy(benchmark.load_json(benchmark.CORPUS_MANIFEST))
        fixture = next(item for item in manifest["fixtures"] if item["id"] == "short")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixtures_dir = root / "fixtures"
            audio_path = fixtures_dir / fixture["audioPath"]
            reference_path = fixtures_dir / fixture["referencePath"]
            audio_path.parent.mkdir(parents=True)
            reference_path.parent.mkdir(parents=True)
            with wave.open(str(audio_path), "wb") as audio:
                audio.setnchannels(1)
                audio.setsampwidth(2)
                audio.setframerate(16000)
                audio.writeframes(b"\0\0" * 16001)
            reference_path.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "fixtureId": "short",
                        "durationMs": 1001,
                        "lastSpeechEndMs": 1000,
                        "words": ["opening", "tail"],
                        "wordTimings": [
                            {"startMs": 0, "endMs": 400},
                            {"startMs": 600, "endMs": 1000},
                        ],
                        "phenomena": [
                            "beginning-speech",
                            "quiet-speech",
                            "tail-speech",
                        ],
                        "beginningAnchors": [["opening"]],
                        "tailAnchors": [["tail"]],
                        "verbatimEvents": [
                            {
                                "kind": "quiet-speech",
                                "startWordIndex": 0,
                                "endWordIndex": 0,
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            with mock.patch.object(benchmark, "WorkerSession", Session), mock.patch.object(
                benchmark,
                "ThermalSampler",
                Thermal,
            ):
                result = benchmark.run_fixture(
                    fixture,
                    manifest,
                    fixtures_dir,
                    root / "model",
                    root / "workspace",
                )

        self.assertAlmostEqual(
            result["measurements"]["coldRealTimeFactor"],
            0.2 / 1.001,
        )
        self.assertIsNone(result["measurements"]["peakResidentBytes"])
        self.assertIsNone(result["measurements"]["peakMpsDriverAllocatedBytes"])
        reason_by_gate = {
            gate["gate"]: gate.get("reason") for gate in result["gates"]
        }
        self.assertEqual(
            reason_by_gate["runtime.peak-resident-bytes"],
            "RSS_MEASUREMENT_UNAVAILABLE",
        )
        self.assertEqual(
            reason_by_gate["runtime.peak-mps-driver-allocated-bytes"],
            "MPS_MEASUREMENT_UNAVAILABLE",
        )
        self.assertEqual(result["status"], "failed")


class ProductionInputBindingTests(unittest.TestCase):
    def test_default_execution_uses_the_snapshotted_lock_not_the_global_path(self) -> None:
        lock = benchmark.load_json(benchmark.ENGINE_LOCK)
        manifest = copy.deepcopy(benchmark.load_json(benchmark.CORPUS_MANIFEST))
        source_plan = copy.deepcopy(benchmark.load_json(benchmark.PUBLIC_SOURCE_PLAN))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixtures_dir = root / "fixtures"
            reference_by_fixture: dict[str, dict] = {}
            for fixture in manifest["fixtures"]:
                fixture["assetStatus"] = "ready"
                audio_path = fixtures_dir / fixture["audioPath"]
                reference_path = fixtures_dir / fixture["referencePath"]
                audio_path.parent.mkdir(parents=True, exist_ok=True)
                reference_path.parent.mkdir(parents=True, exist_ok=True)
                audio_path.write_bytes(f"{fixture['id']} audio".encode())
                reference_by_fixture[fixture["id"]] = {
                    "fixtureId": fixture["id"],
                    "words": ["private", "reference"],
                }
                reference_path.write_text(
                    json.dumps(reference_by_fixture[fixture["id"]]),
                    encoding="utf-8",
                )
                fixture["audioSha256"] = benchmark.sha256_file(audio_path)
                fixture["referenceSha256"] = benchmark.sha256_file(reference_path)
                planned_fixture = next(
                    item
                    for item in source_plan["fixtures"]
                    if item["id"] == fixture["id"]
                )
                planned_fixture["candidateAudioSha256"] = fixture["audioSha256"]

            bind_manifest_to_source_plan(manifest, source_plan)
            source_plan_hash = benchmark.canonical_json_sha256(source_plan)

            changed_lock = copy.deepcopy(lock)
            changed_lock["qualificationProfileId"] = "changed-after-preflight"
            changed_lock_path = root / "changed-engine-lock.json"
            changed_lock_path.write_text(json.dumps(changed_lock), encoding="utf-8")
            changed_source_plan = copy.deepcopy(source_plan)
            changed_source_plan["fixtures"][0]["startMs"] += 1
            changed_source_plan_path = root / "changed-public-source-plan.json"
            changed_source_plan_path.write_text(
                json.dumps(changed_source_plan),
                encoding="utf-8",
            )
            observed_lock_hashes: list[str] = []
            observed_run_roots: set[Path] = set()

            def verify_lock(lock_path: Path) -> None:
                self.assertNotEqual(lock_path, changed_lock_path)
                observed = benchmark.load_json(lock_path)
                observed_lock_hashes.append(benchmark.canonical_json_sha256(observed))
                self.assertEqual(observed, lock)

            def fake_fixture(
                fixture,
                manifest,
                staged_fixtures_dir,
                model_dir,
                workspace,
                *,
                lock_path,
                reference_snapshot,
            ):
                verify_lock(lock_path)
                self.assertNotEqual(staged_fixtures_dir, fixtures_dir)
                run_root = workspace.parent
                observed_run_roots.add(run_root)
                with self.assertRaises(ValueError):
                    run_root.resolve().relative_to(root.resolve())
                with self.assertRaises(ValueError):
                    run_root.resolve().relative_to(benchmark.ROOT.resolve())
                self.assertEqual(run_root.stat().st_mode & 0o777, 0o700)
                self.assertEqual(
                    benchmark.sha256_file(staged_fixtures_dir / fixture["audioPath"]),
                    fixture["audioSha256"],
                )
                self.assertEqual(
                    (staged_fixtures_dir / fixture["audioPath"]).stat().st_mode
                    & 0o777,
                    0o600,
                )
                self.assertFalse(
                    (staged_fixtures_dir / fixture["referencePath"]).exists()
                )
                self.assertEqual(
                    reference_snapshot,
                    reference_by_fixture[fixture["id"]],
                )
                return passing_fixture_result(fixture["id"])

            def fake_cancellation(
                fixture,
                manifest,
                staged_fixtures_dir,
                model_dir,
                workspace,
                *,
                lock_path,
            ):
                verify_lock(lock_path)
                return passing_cancellation_result()

            def fake_offline(
                fixture,
                staged_fixtures_dir,
                model_dir,
                workspace,
                *,
                lock_path,
            ):
                verify_lock(lock_path)
                return passing_cached_offline_result()

            with (
                mock.patch.object(benchmark, "ENGINE_LOCK", changed_lock_path),
                mock.patch.object(
                    benchmark,
                    "PUBLIC_SOURCE_PLAN",
                    changed_source_plan_path,
                ),
                mock.patch.object(benchmark, "run_fixture", side_effect=fake_fixture),
                mock.patch.object(
                    benchmark,
                    "run_cancellation",
                    side_effect=fake_cancellation,
                ),
                mock.patch.object(
                    benchmark,
                    "run_cached_offline",
                    side_effect=fake_offline,
                ),
            ):
                report = benchmark.run_qualification(
                    lock,
                    manifest,
                    fixtures_dir,
                    root / "model",
                    root,
                    source_plan=source_plan,
                )

        self.assertEqual(report["qualificationStatus"], "passed")
        self.assertEqual(report["engineLockSha256"], benchmark.canonical_json_sha256(lock))
        self.assertEqual(report["publicSourcePlanSha256"], source_plan_hash)
        self.assertEqual(len(observed_lock_hashes), 6)
        self.assertEqual(set(observed_lock_hashes), {benchmark.canonical_json_sha256(lock)})
        self.assertEqual(len(observed_run_roots), 1)
        self.assertTrue(all(not path.exists() for path in observed_run_roots))

    def test_local_execution_rejects_assets_changed_after_preflight(self) -> None:
        lock = benchmark.load_json(benchmark.ENGINE_LOCK)
        manifest = benchmark.load_json(benchmark.CORPUS_MANIFEST)

        for changed_key, hash_key in (
            ("audioPath", "audioSha256"),
            ("referencePath", "referenceSha256"),
        ):
            with self.subTest(asset=changed_key), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                fixtures_dir = root / "fixtures"
                fixture = copy.deepcopy(
                    next(item for item in manifest["fixtures"] if item["id"] == "short")
                )
                for path_key, digest_key in (
                    ("audioPath", "audioSha256"),
                    ("referencePath", "referenceSha256"),
                ):
                    path = fixtures_dir / fixture[path_key]
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(f"pinned {path_key}".encode())
                    fixture[digest_key] = benchmark.sha256_file(path)
                changed_path = fixtures_dir / fixture[changed_key]
                changed_path.write_bytes(b"changed after preflight")

                executor = benchmark.LocalQualificationExecutor(lock)
                with mock.patch.object(benchmark, "run_fixture") as run_fixture:
                    with self.assertRaises(benchmark.QualificationError):
                        executor.run_fixture(
                            fixture,
                            manifest,
                            fixtures_dir,
                            root / "model",
                            root / "workspace",
                        )
                    run_fixture.assert_not_called()


class QualificationRunTests(unittest.TestCase):
    def test_unpinned_public_derived_hash_blocks_before_any_inference(self) -> None:
        class NeverRunEngine:
            def run_fixture(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                raise AssertionError("inference must not start")

            def run_cancellation(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                raise AssertionError("cancellation must not start")

            def run_cached_offline(self, fixture, fixtures_dir, model_dir, workspace):
                raise AssertionError("offline inference must not start")

        lock = benchmark.load_json(benchmark.ENGINE_LOCK)
        manifest = benchmark.load_json(benchmark.CORPUS_MANIFEST)
        source_plan = benchmark.load_json(benchmark.PUBLIC_SOURCE_PLAN)
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(
            benchmark.QualificationError
        ):
            root = Path(directory)
            benchmark.run_qualification(
                lock,
                manifest,
                root / "fixtures",
                root / "model",
                root,
                executor=NeverRunEngine(),
                source_plan=source_plan,
            )

    def test_qualification_report_is_bound_to_snapshotted_public_provenance(self) -> None:
        class PassingEngine:
            def run_fixture(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                return passing_fixture_result(fixture["id"])

            def run_cancellation(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                return passing_cancellation_result()

            def run_cached_offline(self, fixture, fixtures_dir, model_dir, workspace):
                return passing_cached_offline_result()

        lock, manifest, source_plan = qualification_inputs_with_pinned_public_audio()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = benchmark.run_qualification(
                lock,
                manifest,
                root / "fixtures",
                root / "model",
                root,
                executor=PassingEngine(),
                source_plan=source_plan,
            )

        self.assertEqual(report["publicSourcePlanId"], source_plan["planId"])
        self.assertEqual(
            report["publicSourcePlanSha256"],
            benchmark.canonical_json_sha256(source_plan),
        )
        self.assertEqual(
            {
                fixture["id"]: fixture["sourceProvenance"]
                for fixture in report["fixtures"]
            },
            {
                fixture["id"]: {
                    "sourceId": fixture["sourceId"],
                    "startMs": fixture["startMs"],
                    "durationMs": fixture["durationMs"],
                    "candidateAudioSha256": fixture["candidateAudioSha256"],
                }
                for fixture in source_plan["fixtures"]
            },
        )

    def test_fixture_audio_duration_is_bound_to_its_manifest_record(self) -> None:
        class OutOfRangeDurationEngine:
            def run_fixture(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                result = passing_fixture_result(fixture["id"])
                result["measurements"].update(
                    {
                        "audioDurationMs": 4000,
                        "modelLoadSeconds": 1.0,
                        "coldInferenceSeconds": 1.0,
                        "warmInferenceSeconds": 1.0,
                        "coldRealTimeFactor": 0.5,
                        "warmRealTimeFactor": 0.25,
                    }
                )
                return result

            def run_cancellation(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                return passing_cancellation_result()

            def run_cached_offline(self, fixture, fixtures_dir, model_dir, workspace):
                return passing_cached_offline_result()

        lock, manifest, source_plan = qualification_inputs_with_pinned_public_audio()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = benchmark.run_qualification(
                lock,
                manifest,
                root / "fixtures",
                root / "model",
                root,
                executor=OutOfRangeDurationEngine(),
                source_plan=source_plan,
            )

        self.assertEqual(report["qualificationStatus"], "failed")
        self.assertTrue(all(item["status"] == "failed" for item in report["fixtures"]))

    def test_impossible_word_count_and_alignment_evidence_fails_closed(self) -> None:
        class ImpossibleEvidenceEngine:
            def run_fixture(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                result = passing_fixture_result(fixture["id"])
                measurements = result["measurements"]
                if fixture["id"] == "short":
                    measurements.update(
                        {
                            "referenceWordCount": 0,
                            "candidateWordCount": 0,
                            "referenceMaximumRepeatedNgramRun": 0,
                            "candidateMaximumRepeatedNgramRun": 0,
                            "excessRepeatedNgramRun": 0,
                        }
                    )
                elif fixture["id"] == "one-minute":
                    measurements["candidateWordCount"] = 50
                elif fixture["id"] == "twelve-minute":
                    measurements["candidateMaximumRepeatedNgramRun"] = 4
                else:
                    measurements["referenceWordCoverage"] = 0.8
                    gate = next(
                        item
                        for item in result["gates"]
                        if item["gate"] == "quality.reference-word-coverage"
                    )
                    gate["measured"] = 0.8
                return result

            def run_cancellation(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                return passing_cancellation_result()

            def run_cached_offline(self, fixture, fixtures_dir, model_dir, workspace):
                return passing_cached_offline_result()

        lock, manifest, source_plan = qualification_inputs_with_pinned_public_audio()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = benchmark.run_qualification(
                lock,
                manifest,
                root / "fixtures",
                root / "model",
                root,
                executor=ImpossibleEvidenceEngine(),
                source_plan=source_plan,
            )

        self.assertEqual(report["qualificationStatus"], "failed")
        self.assertTrue(all(item["status"] == "failed" for item in report["fixtures"]))

    def test_fractional_or_impossible_transcript_counts_fail_closed(self) -> None:
        class ImpossibleCountEngine:
            def run_fixture(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                result = passing_fixture_result(fixture["id"])
                measurements = result["measurements"]
                gates = {item["gate"]: item for item in result["gates"]}
                if fixture["id"] == "short":
                    measurements.update(
                        {
                            "candidateWordCount": 80,
                            "wordCountRatio": 0.8,
                            "wordErrorRate": 0.0,
                            "referenceWordCoverage": 1.0,
                        }
                    )
                    gates["quality.word-count-ratio-minimum"]["measured"] = 0.8
                    gates["quality.word-count-ratio-maximum"]["measured"] = 0.8
                    gates["quality.word-error-rate"]["measured"] = 0.0
                elif fixture["id"] == "one-minute":
                    measurements["wordErrorRate"] = 0.105
                    gates["quality.word-error-rate"]["measured"] = 0.105
                elif fixture["id"] == "twelve-minute":
                    measurements["timedWordRatio"] = 0.995
                    gates["timing.timed-word-ratio"]["measured"] = 0.995
                else:
                    measurements["alignedWordTimingRatio"] = 0.995
                    gates["timing.aligned-word-timing-ratio"]["measured"] = 0.995
                return result

            def run_cancellation(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                return passing_cancellation_result()

            def run_cached_offline(self, fixture, fixtures_dir, model_dir, workspace):
                return passing_cached_offline_result()

        lock, manifest, source_plan = qualification_inputs_with_pinned_public_audio()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = benchmark.run_qualification(
                lock,
                manifest,
                root / "fixtures",
                root / "model",
                root,
                executor=ImpossibleCountEngine(),
                source_plan=source_plan,
            )

        self.assertEqual(report["qualificationStatus"], "failed")
        self.assertTrue(all(item["status"] == "failed" for item in report["fixtures"]))

    def test_zero_duration_and_timed_counts_cannot_overlap(self) -> None:
        measurements = passing_fixture_result("short")["measurements"]
        measurements["zeroDurationWordRatio"] = 0.01

        with self.assertRaises(benchmark.QualificationError):
            benchmark._sanitize_measurements(measurements)

    def test_duration_rtf_and_percentage_evidence_is_cross_checked(self) -> None:
        class ContradictoryRuntimeEngine:
            def run_fixture(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                result = passing_fixture_result(fixture["id"])
                measurements = result["measurements"]
                if fixture["id"] == "short":
                    measurements["audioDurationMs"] = 0
                elif fixture["id"] == "one-minute":
                    measurements["coldRealTimeFactor"] = 0.4
                    gate = next(
                        item
                        for item in result["gates"]
                        if item["gate"] == "runtime.cold-real-time-factor"
                    )
                    gate["measured"] = 0.4
                elif fixture["id"] == "twelve-minute":
                    measurements["warmRealTimeFactor"] = 0.2
                    gate = next(
                        item
                        for item in result["gates"]
                        if item["gate"] == "runtime.warm-real-time-factor"
                    )
                    gate["measured"] = 0.2
                else:
                    measurements["verbatimEventRecall"] = 1.1
                    gate = next(
                        item
                        for item in result["gates"]
                        if item["gate"] == "quality.verbatim-event-recall"
                    )
                    gate["measured"] = 1.1
                return result

            def run_cancellation(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                return passing_cancellation_result()

            def run_cached_offline(self, fixture, fixtures_dir, model_dir, workspace):
                return passing_cached_offline_result()

        lock, manifest, source_plan = qualification_inputs_with_pinned_public_audio()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = benchmark.run_qualification(
                lock,
                manifest,
                root / "fixtures",
                root / "model",
                root,
                executor=ContradictoryRuntimeEngine(),
                source_plan=source_plan,
            )

        self.assertEqual(report["qualificationStatus"], "failed")
        self.assertTrue(all(item["status"] == "failed" for item in report["fixtures"]))

    def test_cancellation_worker_reaped_gate_matches_the_real_measurement(self) -> None:
        class ContradictoryCancellationEngine:
            def run_fixture(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                return passing_fixture_result(fixture["id"])

            def run_cancellation(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                result = passing_cancellation_result()
                result["workerReaped"] = False
                return result

            def run_cached_offline(self, fixture, fixtures_dir, model_dir, workspace):
                return passing_cached_offline_result()

        lock, manifest, source_plan = qualification_inputs_with_pinned_public_audio()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = benchmark.run_qualification(
                lock,
                manifest,
                root / "fixtures",
                root / "model",
                root,
                executor=ContradictoryCancellationEngine(),
                source_plan=source_plan,
            )

        self.assertEqual(report["qualificationStatus"], "failed")
        self.assertEqual(report["cancellation"]["status"], "failed")

    def test_zero_memory_values_cannot_stand_in_for_missing_telemetry(self) -> None:
        class MissingTelemetryEngine:
            def run_fixture(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                result = passing_fixture_result(fixture["id"])
                for gate_name, measurement_name in (
                    ("runtime.peak-resident-bytes", "peakResidentBytes"),
                    (
                        "runtime.peak-mps-driver-allocated-bytes",
                        "peakMpsDriverAllocatedBytes",
                    ),
                ):
                    result["measurements"][measurement_name] = 0
                    gate = next(
                        item for item in result["gates"] if item["gate"] == gate_name
                    )
                    gate["measured"] = 0
                return result

            def run_cancellation(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                return passing_cancellation_result()

            def run_cached_offline(self, fixture, fixtures_dir, model_dir, workspace):
                return passing_cached_offline_result()

        lock, manifest, source_plan = qualification_inputs_with_pinned_public_audio()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = benchmark.run_qualification(
                lock,
                manifest,
                root / "fixtures",
                root / "model",
                root,
                executor=MissingTelemetryEngine(),
                source_plan=source_plan,
            )

        self.assertEqual(report["qualificationStatus"], "failed")
        self.assertTrue(all(item["status"] == "failed" for item in report["fixtures"]))

    def test_reported_stage_failure_is_never_promoted_by_passing_gates(self) -> None:
        class ReportedFailureEngine:
            def run_fixture(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                result = passing_fixture_result(fixture["id"])
                result["status"] = "failed"
                return result

            def run_cancellation(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                result = passing_cancellation_result()
                result["status"] = "failed"
                return result

            def run_cached_offline(self, fixture, fixtures_dir, model_dir, workspace):
                result = passing_cached_offline_result()
                result["status"] = "failed"
                return result

        lock, manifest, source_plan = qualification_inputs_with_pinned_public_audio()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = benchmark.run_qualification(
                lock,
                manifest,
                root / "fixtures",
                root / "model",
                root,
                executor=ReportedFailureEngine(),
                source_plan=source_plan,
            )

        self.assertEqual(report["qualificationStatus"], "failed")
        self.assertTrue(all(item["status"] == "failed" for item in report["fixtures"]))
        self.assertEqual(report["cancellation"]["status"], "failed")
        self.assertEqual(report["cachedOffline"]["status"], "failed")

    def test_gate_measurements_must_match_typed_stage_measurements(self) -> None:
        class ContradictoryMeasurementEngine:
            def run_fixture(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                result = passing_fixture_result(fixture["id"])
                mutations = {
                    "short": ("wordErrorRate", 999),
                    "one-minute": ("coldWarmOutputMatch", False),
                    "twelve-minute": ("maximumThermalState", "critical"),
                    "forty-five-minute": ("tailLagMs", 999999),
                }
                measurement_name, contradictory_value = mutations[fixture["id"]]
                result["measurements"][measurement_name] = contradictory_value
                return result

            def run_cancellation(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                result = passing_cancellation_result()
                result["terminationSeconds"] = 999
                return result

            def run_cached_offline(self, fixture, fixtures_dir, model_dir, workspace):
                return passing_cached_offline_result()

        lock, manifest, source_plan = qualification_inputs_with_pinned_public_audio()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = benchmark.run_qualification(
                lock,
                manifest,
                root / "fixtures",
                root / "model",
                root,
                executor=ContradictoryMeasurementEngine(),
                source_plan=source_plan,
            )

        self.assertEqual(report["qualificationStatus"], "failed")
        self.assertTrue(all(item["status"] == "failed" for item in report["fixtures"]))
        self.assertEqual(report["cancellation"]["status"], "failed")
        self.assertEqual(report["cachedOffline"]["status"], "passed")

    def test_negative_counts_times_and_byte_measurements_fail_closed(self) -> None:
        class NegativeMeasurementEngine:
            def run_fixture(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                result = passing_fixture_result(fixture["id"])
                if fixture["id"] == "short":
                    result["measurements"]["referenceWordCount"] = -1
                elif fixture["id"] == "one-minute":
                    result["measurements"]["coldInferenceSeconds"] = -0.1
                elif fixture["id"] == "twelve-minute":
                    result["measurements"]["peakResidentBytes"] = -1
                    gate = next(
                        item
                        for item in result["gates"]
                        if item["gate"] == "runtime.peak-resident-bytes"
                    )
                    gate["measured"] = -1
                else:
                    result["measurements"]["tailLagMs"] = -1
                    gate = next(
                        item
                        for item in result["gates"]
                        if item["gate"] == "timing.tail-lag-ms"
                    )
                    gate["measured"] = -1
                return result

            def run_cancellation(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                result = passing_cancellation_result()
                result["modelLoadSeconds"] = -0.1
                return result

            def run_cached_offline(self, fixture, fixtures_dir, model_dir, workspace):
                return passing_cached_offline_result()

        lock, manifest, source_plan = qualification_inputs_with_pinned_public_audio()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = benchmark.run_qualification(
                lock,
                manifest,
                root / "fixtures",
                root / "model",
                root,
                executor=NegativeMeasurementEngine(),
                source_plan=source_plan,
            )

        self.assertEqual(report["qualificationStatus"], "failed")
        self.assertTrue(all(item["status"] == "failed" for item in report["fixtures"]))
        self.assertEqual(report["cancellation"]["status"], "failed")
        self.assertEqual(report["cachedOffline"]["status"], "passed")

    def test_gate_outcomes_are_derived_from_pinned_thresholds(self) -> None:
        class ContradictoryGateEngine:
            def run_fixture(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                result = passing_fixture_result(fixture["id"])
                mutations = {
                    "short": ("quality.word-error-rate", "wordErrorRate", 1.0, 2.0),
                    "one-minute": (
                        "quality.reference-word-coverage",
                        "referenceWordCoverage",
                        -1,
                        -2,
                    ),
                    "twelve-minute": (
                        "runtime.maximum-thermal-state",
                        "maximumThermalState",
                        "critical",
                        "critical",
                    ),
                    "forty-five-minute": (
                        "quality.cold-warm-output-match",
                        "coldWarmOutputMatch",
                        False,
                        False,
                    ),
                }
                gate_name, measurement_name, measured, claimed_threshold = mutations[
                    fixture["id"]
                ]
                result["measurements"][measurement_name] = measured
                gate = next(item for item in result["gates"] if item["gate"] == gate_name)
                gate.update(
                    {
                        "status": "passed",
                        "measured": measured,
                        "threshold": claimed_threshold,
                    }
                )
                return result

            def run_cancellation(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                result = passing_cancellation_result()
                gate = next(
                    item
                    for item in result["gates"]
                    if item["gate"] == "cancellation.termination-seconds"
                )
                result["terminationSeconds"] = 999
                gate.update({"status": "passed", "measured": 999, "threshold": 1000})
                return result

            def run_cached_offline(self, fixture, fixtures_dir, model_dir, workspace):
                result = passing_cached_offline_result()
                gate = next(
                    item
                    for item in result["gates"]
                    if item["gate"] == "cached-offline.network-denied"
                )
                gate.update({"status": "passed", "measured": False, "threshold": False})
                return result

        lock, manifest, source_plan = qualification_inputs_with_pinned_public_audio()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = benchmark.run_qualification(
                lock,
                manifest,
                root / "fixtures",
                root / "model",
                root,
                executor=ContradictoryGateEngine(),
                source_plan=source_plan,
            )

        self.assertEqual(report["qualificationStatus"], "failed")
        self.assertTrue(all(item["status"] == "failed" for item in report["fixtures"]))
        self.assertEqual(report["cancellation"]["status"], "failed")
        self.assertEqual(report["cachedOffline"]["status"], "failed")
        short = next(item for item in report["fixtures"] if item["id"] == "short")
        word_error_rate = next(
            gate
            for gate in short["gates"]
            if gate["gate"] == "quality.word-error-rate"
        )
        self.assertEqual(
            word_error_rate["threshold"],
            manifest["thresholds"]["quality"]["maximumWordErrorRate"],
        )
        self.assertEqual(word_error_rate["status"], "failed")

    def test_missing_fixture_gate_and_measurement_evidence_fails_closed(self) -> None:
        class IncompleteEvidenceEngine:
            def run_fixture(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                return {
                    "id": fixture["id"],
                    "status": "passed",
                    "measurements": {},
                    "gates": [],
                }

            def run_cancellation(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                return passing_cancellation_result()

            def run_cached_offline(self, fixture, fixtures_dir, model_dir, workspace):
                return passing_cached_offline_result()

        lock, manifest, source_plan = qualification_inputs_with_pinned_public_audio()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = benchmark.run_qualification(
                lock,
                manifest,
                root / "fixtures",
                root / "model",
                root,
                executor=IncompleteEvidenceEngine(),
                source_plan=source_plan,
            )

        self.assertEqual(report["qualificationStatus"], "failed")
        self.assertTrue(
            all(fixture["status"] == "failed" for fixture in report["fixtures"])
        )

    def test_stage_status_is_derived_from_validated_gate_statuses(self) -> None:
        class ContradictoryStatusEngine:
            def run_fixture(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                result = passing_fixture_result(fixture["id"])
                if fixture["id"] == "one-minute":
                    result["gates"][0]["status"] = "failed"
                return result

            def run_cancellation(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                return passing_cancellation_result()

            def run_cached_offline(self, fixture, fixtures_dir, model_dir, workspace):
                return passing_cached_offline_result()

        lock, manifest, source_plan = qualification_inputs_with_pinned_public_audio()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = benchmark.run_qualification(
                lock,
                manifest,
                root / "fixtures",
                root / "model",
                root,
                executor=ContradictoryStatusEngine(),
                source_plan=source_plan,
            )

        fixture_by_id = {fixture["id"]: fixture for fixture in report["fixtures"]}
        self.assertEqual(report["qualificationStatus"], "failed")
        self.assertEqual(fixture_by_id["one-minute"]["status"], "failed")

    def test_all_fixture_cancellation_and_offline_results_must_pass_the_gate(self) -> None:
        class PassingEngine:
            def run_fixture(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                return passing_fixture_result(fixture["id"])

            def run_cancellation(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                return passing_cancellation_result()

            def run_cached_offline(self, fixture, fixtures_dir, model_dir, workspace):
                return passing_cached_offline_result()

        lock, manifest, source_plan = qualification_inputs_with_pinned_public_audio()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = benchmark.run_qualification(
                lock,
                manifest,
                root / "fixtures",
                root / "model",
                root,
                executor=PassingEngine(),
                source_plan=source_plan,
            )

        self.assertEqual(report["qualificationStatus"], "passed")
        self.assertEqual(
            {fixture["id"] for fixture in report["fixtures"]},
            benchmark.EXPECTED_FIXTURES,
        )
        self.assertEqual(report["cancellation"]["status"], "passed")
        self.assertEqual(report["cachedOffline"]["status"], "passed")
        self.assertEqual(
            {
                gate["gate"]
                for gate in report["cachedOffline"]["gates"]
            },
            {"cached-offline.inference", "cached-offline.network-denied"},
        )
        self.assertTrue(
            all(
                {
                    "coldRealTimeFactor",
                    "warmRealTimeFactor",
                    "peakResidentBytes",
                    "peakMpsDriverAllocatedBytes",
                    "maximumThermalState",
                    "thermalRecoverySeconds",
                }.issubset(fixture["measurements"])
                for fixture in report["fixtures"]
            )
        )
        self.assertFalse(report["engineSelectionChanged"])

    def test_aggregate_report_drops_unrecognized_sensitive_fields(self) -> None:
        class LeakyEngine:
            def run_fixture(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                result = passing_fixture_result(fixture["id"])
                result["measurements"]["transcript"] = "private spoken words"
                result["gates"][0]["audioPath"] = "/private/speaker.wav"
                return result

            def run_cancellation(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                result = passing_cancellation_result()
                result["gates"][0]["stderr"] = "private provider output"
                return result

            def run_cached_offline(self, fixture, fixtures_dir, model_dir, workspace):
                result = passing_cached_offline_result()
                result["gates"][0]["modelPath"] = "/private/model"
                return result

        lock, manifest, source_plan = qualification_inputs_with_pinned_public_audio()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = benchmark.run_qualification(
                lock,
                manifest,
                root / "fixtures",
                root / "model",
                root,
                executor=LeakyEngine(),
                source_plan=source_plan,
            )

        serialized = json.dumps(report)
        self.assertNotIn("private", serialized.casefold())
        self.assertNotIn("transcript", serialized.casefold())
        self.assertNotIn("audioPath", serialized)

    def test_malformed_cancellation_result_maps_to_a_bounded_failure(self) -> None:
        class MalformedCancellationEngine:
            def run_fixture(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                return passing_fixture_result(fixture["id"])

            def run_cancellation(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                return {"gates": [], "transcript": "must not escape"}

            def run_cached_offline(self, fixture, fixtures_dir, model_dir, workspace):
                return passing_cached_offline_result()

        lock, manifest, source_plan = qualification_inputs_with_pinned_public_audio()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = benchmark.run_qualification(
                lock,
                manifest,
                root / "fixtures",
                root / "model",
                root,
                executor=MalformedCancellationEngine(),
                source_plan=source_plan,
            )

        self.assertEqual(report["qualificationStatus"], "failed")
        self.assertEqual(report["cancellation"]["status"], "failed")
        self.assertEqual(
            report["cancellation"]["gates"][0]["reason"],
            "QUALIFICATION_EXECUTION_FAILED",
        )
        self.assertNotIn("transcript", json.dumps(report).casefold())

    def test_wrong_fixture_identity_fails_only_that_fixture_closed(self) -> None:
        class WrongIdentityEngine:
            def run_fixture(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                return passing_fixture_result("short")

            def run_cancellation(self, fixture, manifest, fixtures_dir, model_dir, workspace):
                return passing_cancellation_result()

            def run_cached_offline(self, fixture, fixtures_dir, model_dir, workspace):
                return passing_cached_offline_result()

        lock, manifest, source_plan = qualification_inputs_with_pinned_public_audio()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = benchmark.run_qualification(
                lock,
                manifest,
                root / "fixtures",
                root / "model",
                root,
                executor=WrongIdentityEngine(),
                source_plan=source_plan,
            )

        fixture_by_id = {fixture["id"]: fixture for fixture in report["fixtures"]}
        self.assertEqual(report["qualificationStatus"], "failed")
        self.assertEqual(set(fixture_by_id), benchmark.EXPECTED_FIXTURES)
        self.assertEqual(fixture_by_id["short"]["status"], "passed")
        self.assertTrue(
            all(
                fixture_by_id[fixture_id]["status"] == "failed"
                for fixture_id in benchmark.EXPECTED_FIXTURES - {"short"}
            )
        )


if __name__ == "__main__":
    unittest.main()
