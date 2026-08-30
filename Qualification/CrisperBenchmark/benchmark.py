#!/usr/bin/env python3
"""Reproducible qualification runner for Audora's pinned Crisper profile.

The runner never downloads a model or corpus asset. It validates immutable local
inputs, runs the exact engine lock, keeps transcript content in memory, and writes
only aggregate measurements and gate outcomes.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import difflib
import hashlib
import importlib.metadata
import json
import math
import os
import platform
import re
import selectors
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parent
ENGINE_LOCK = ROOT / "engine-lock.v1.json"
CORPUS_MANIFEST = ROOT / "corpus-manifest.v1.json"
WORKER = ROOT / "crisper_worker.py"
THERMAL_PROBE = ROOT / "ThermalStateProbe.swift"

EXPECTED_PROFILE_ID = "crisperwhisper-2-small-transformers-mps-v1"
EXPECTED_ENGINE = {
    "provider": "crisperwhisper",
    "backend": "transformers",
    "device": "mps",
    "computeType": "float16",
}
EXPECTED_DECODING = {
    "language": "en",
    "mode": "verbatim",
    "wordTimestamps": True,
    "hotwords": None,
    "longformStrategy": "continuation",
    "chunkDurationSeconds": 30.0,
    "strideSeconds": 26.0,
    "contextWords": 12,
    "dropWords": 2,
    "timestampAwareDrop": True,
    "temperatureFallback": True,
    "maxNewTokens": 256,
    "speculativeDecoding": False,
    "speculativeMode": "strict",
    "hallucinationMitigation": True,
    "alignmentHeads": "model-default",
    "suppressTokens": "model-default",
}
EXPECTED_FIXTURES = {
    "short",
    "one-minute",
    "twelve-minute",
    "forty-five-minute",
}
THERMAL_ORDER = {"nominal": 0, "fair": 1, "serious": 2, "critical": 3}
TOKEN_PATTERN = re.compile(r"\[[^\]\s]+\]|[a-z0-9]+(?:['-][a-z0-9]+)*-?")


class QualificationError(Exception):
    """A bounded configuration or worker-protocol failure."""


@dataclasses.dataclass(frozen=True)
class Gate:
    gate: str
    status: str
    measured: Any = None
    threshold: Any = None
    reason: str | None = None

    def as_json(self) -> dict[str, Any]:
        value = dataclasses.asdict(self)
        return {key: item for key, item in value.items() if item is not None}


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise QualificationError("JSON root must be an object")
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json_sha256(value: dict[str, Any]) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def normalize_tokens(value: str | Iterable[str]) -> list[str]:
    text = value if isinstance(value, str) else " ".join(str(item) for item in value)
    return TOKEN_PATTERN.findall(text.casefold())


def levenshtein_distance(left: list[str], right: list[str]) -> int:
    previous = list(range(len(right) + 1))
    for left_index, left_token in enumerate(left, start=1):
        current = [left_index]
        for right_index, right_token in enumerate(right, start=1):
            substitution = previous[right_index - 1] + (left_token != right_token)
            current.append(
                min(previous[right_index] + 1, current[-1] + 1, substitution)
            )
        previous = current
    return previous[-1]


def phrase_occurrences(tokens: list[str], phrase: list[str]) -> int:
    if not phrase or len(phrase) > len(tokens):
        return 0
    return sum(
        tokens[index : index + len(phrase)] == phrase
        for index in range(len(tokens) - len(phrase) + 1)
    )


def anchor_coverage(tokens: list[str], anchors: list[list[str]]) -> float:
    if not anchors:
        return 0.0
    present = sum(phrase_occurrences(tokens, normalize_tokens(anchor)) > 0 for anchor in anchors)
    return present / len(anchors)


def verbatim_event_recall(tokens: list[str], events: list[dict[str, Any]]) -> float:
    if not events:
        return 0.0
    found = 0
    used: dict[tuple[str, ...], int] = {}
    for event in events:
        phrase = tuple(normalize_tokens(event.get("words", [])))
        if not phrase:
            continue
        occurrence = used.get(phrase, 0) + 1
        used[phrase] = occurrence
        if phrase_occurrences(tokens, list(phrase)) >= occurrence:
            found += 1
    return found / len(events)


def maximum_repeated_ngram_run(tokens: list[str], maximum_ngram: int = 5) -> int:
    maximum = 1 if tokens else 0
    for size in range(1, min(maximum_ngram, len(tokens) // 2) + 1):
        for start in range(0, len(tokens) - size + 1):
            phrase = tokens[start : start + size]
            run = 1
            cursor = start + size
            while cursor + size <= len(tokens) and tokens[cursor : cursor + size] == phrase:
                run += 1
                cursor += size
            maximum = max(maximum, run)
    return maximum


def _gate_maximum(name: str, measured: float, threshold: float) -> Gate:
    return Gate(name, "passed" if measured <= threshold else "failed", measured, threshold)


def _gate_minimum(name: str, measured: float, threshold: float) -> Gate:
    return Gate(name, "passed" if measured >= threshold else "failed", measured, threshold)


def evaluate_transcript(
    reference: dict[str, Any],
    candidate: dict[str, Any],
    thresholds: dict[str, Any],
) -> dict[str, Any]:
    reference_tokens = normalize_tokens(reference.get("words", []))
    candidate_tokens = normalize_tokens(candidate.get("text", ""))
    if not reference_tokens:
        raise QualificationError("reference contains no words")

    distance = levenshtein_distance(reference_tokens, candidate_tokens)
    matcher = difflib.SequenceMatcher(a=reference_tokens, b=candidate_tokens, autojunk=False)
    matched_reference_words = sum(block.size for block in matcher.get_matching_blocks())
    word_error_rate = distance / len(reference_tokens)
    reference_coverage = matched_reference_words / len(reference_tokens)
    word_count_ratio = len(candidate_tokens) / len(reference_tokens)
    beginning_coverage = anchor_coverage(candidate_tokens, reference.get("beginningAnchors", []))
    tail_coverage = anchor_coverage(candidate_tokens, reference.get("tailAnchors", []))
    event_recall = verbatim_event_recall(candidate_tokens, reference.get("verbatimEvents", []))
    reference_run = maximum_repeated_ngram_run(reference_tokens)
    candidate_run = maximum_repeated_ngram_run(candidate_tokens)
    excess_run = max(0, candidate_run - reference_run)

    duration_ms = int(reference["durationMs"])
    timed_words = candidate.get("words", [])
    valid_timed = 0
    zero_duration = 0
    monotonic = True
    within_audio = True
    last_start = -1
    last_end = -1
    latest_end = 0
    for word in timed_words:
        start = word.get("startMs")
        end = word.get("endMs")
        if not isinstance(start, int) or not isinstance(end, int):
            continue
        if start == end:
            zero_duration += 1
        finite = math.isfinite(start) and math.isfinite(end)
        in_bounds = finite and 0 <= start < end <= duration_ms
        within_audio = within_audio and in_bounds
        monotonic = monotonic and start >= last_start and end >= last_end
        if in_bounds:
            valid_timed += 1
            latest_end = max(latest_end, end)
        last_start = start
        last_end = end

    timed_ratio = valid_timed / max(1, len(candidate_tokens))
    zero_duration_ratio = zero_duration / max(1, len(timed_words))
    tail_lag_ms = max(0, int(reference["lastSpeechEndMs"]) - latest_end)

    quality = thresholds["quality"]
    timing = thresholds["timing"]
    gates = [
        _gate_maximum("quality.word-error-rate", word_error_rate, quality["maximumWordErrorRate"]),
        _gate_minimum("quality.reference-word-coverage", reference_coverage, quality["minimumReferenceWordCoverage"]),
        _gate_minimum("quality.verbatim-event-recall", event_recall, quality["minimumVerbatimEventRecall"]),
        _gate_minimum("quality.beginning-anchor-coverage", beginning_coverage, quality["minimumBeginningAnchorCoverage"]),
        _gate_minimum("quality.tail-anchor-coverage", tail_coverage, quality["minimumTailAnchorCoverage"]),
        _gate_minimum("quality.word-count-ratio-minimum", word_count_ratio, quality["minimumWordCountRatio"]),
        _gate_maximum("quality.word-count-ratio-maximum", word_count_ratio, quality["maximumWordCountRatio"]),
        _gate_maximum("quality.excess-repeated-ngram-run", excess_run, quality["maximumExcessRepeatedNgramRun"]),
        _gate_minimum("timing.timed-word-ratio", timed_ratio, timing["minimumTimedWordRatio"]),
        _gate_maximum("timing.zero-duration-word-ratio", zero_duration_ratio, timing["maximumZeroDurationWordRatio"]),
        _gate_maximum("timing.tail-lag-ms", tail_lag_ms, timing["maximumTailLagMs"]),
        Gate("timing.monotonic", "passed" if monotonic else "failed", monotonic, True),
        Gate("timing.within-audio", "passed" if within_audio else "failed", within_audio, True),
    ]
    measurements = {
        "referenceWordCount": len(reference_tokens),
        "candidateWordCount": len(candidate_tokens),
        "wordErrorRate": word_error_rate,
        "referenceWordCoverage": reference_coverage,
        "verbatimEventRecall": event_recall,
        "beginningAnchorCoverage": beginning_coverage,
        "tailAnchorCoverage": tail_coverage,
        "wordCountRatio": word_count_ratio,
        "referenceMaximumRepeatedNgramRun": reference_run,
        "candidateMaximumRepeatedNgramRun": candidate_run,
        "excessRepeatedNgramRun": excess_run,
        "timedWordRatio": timed_ratio,
        "zeroDurationWordRatio": zero_duration_ratio,
        "monotonicWordTimes": monotonic,
        "wordsWithinAudio": within_audio,
        "tailLagMs": tail_lag_ms,
    }
    return {
        "status": "passed" if all(gate.status == "passed" for gate in gates) else "failed",
        "measurements": measurements,
        "gates": [gate.as_json() for gate in gates],
    }


def validate_locked_configuration(lock: dict[str, Any], manifest: dict[str, Any]) -> None:
    if lock.get("schemaVersion") != 1 or manifest.get("schemaVersion") != 1:
        raise QualificationError("unsupported qualification schema")
    if lock.get("qualificationProfileId") != EXPECTED_PROFILE_ID:
        raise QualificationError("unexpected engine profile")
    if manifest.get("qualificationProfileId") != EXPECTED_PROFILE_ID:
        raise QualificationError("corpus targets a different engine profile")
    engine = lock.get("engine", {})
    for key, expected in EXPECTED_ENGINE.items():
        if engine.get(key) != expected:
            raise QualificationError(f"engine lock changed {key}")
    if engine.get("package", {}).get("version") != "2.0.0":
        raise QualificationError("unexpected CrisperWhisper package version")
    if lock.get("model", {}).get("repository") != "nyralabs/CrisperWhisper2.0_small":
        raise QualificationError("unexpected model repository")
    if lock.get("decoding") != EXPECTED_DECODING:
        raise QualificationError("decoding lock does not match the selected configuration")
    fixture_ids = {fixture.get("id") for fixture in manifest.get("fixtures", [])}
    if fixture_ids != EXPECTED_FIXTURES:
        raise QualificationError("corpus must contain exactly the four required fixtures")


def _runtime_preflight(lock: dict[str, Any]) -> list[Gate]:
    gates: list[Gate] = []
    package_lock = ROOT / lock["runtime"]["packageLock"]
    expected_lock_hash = lock["runtime"]["packageLockSha256"]
    actual_lock_hash = sha256_file(package_lock) if package_lock.is_file() else None
    gates.append(Gate("runtime.package-lock", "passed" if actual_lock_hash == expected_lock_hash else "blocked", actual_lock_hash, expected_lock_hash, None if actual_lock_hash == expected_lock_hash else "PACKAGE_LOCK_MISSING_OR_DRIFTED"))
    expected_python = lock["runtime"]["pythonVersion"]
    actual_python = platform.python_version()
    gates.append(Gate("runtime.python-version", "passed" if actual_python == expected_python else "blocked", actual_python, expected_python, None if actual_python == expected_python else "RUNTIME_VERSION_MISMATCH"))
    expected_packages = {
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
    for package, expected in expected_packages.items():
        try:
            actual = importlib.metadata.version(package)
        except importlib.metadata.PackageNotFoundError:
            actual = None
        gates.append(Gate(f"runtime.package.{package}", "passed" if actual == expected else "blocked", actual, expected, None if actual == expected else "PACKAGE_MISSING_OR_DRIFTED"))

    machine_ok = platform.system() == "Darwin" and platform.machine() == "arm64"
    gates.append(Gate("runtime.platform", "passed" if machine_ok else "blocked", f"{platform.system()}-{platform.machine()}", "Darwin-arm64", None if machine_ok else "UNSUPPORTED_PLATFORM"))
    return gates


def _model_preflight(lock: dict[str, Any], model_dir: Path | None) -> list[Gate]:
    if model_dir is None:
        return [Gate("model.local-assets", "blocked", threshold="all pinned files", reason="MODEL_DIRECTORY_NOT_PROVIDED")]
    if not model_dir.is_dir():
        return [Gate("model.local-assets", "blocked", threshold="all pinned files", reason="MODEL_DIRECTORY_UNAVAILABLE")]
    gates: list[Gate] = []
    for name, expected_hash in lock["model"]["files"].items():
        path = model_dir / name
        if not path.is_file():
            gates.append(Gate(f"model.file.{name}", "blocked", threshold=expected_hash, reason="MODEL_FILE_MISSING"))
            continue
        actual_hash = sha256_file(path)
        gates.append(Gate(f"model.file.{name}", "passed" if actual_hash == expected_hash else "blocked", actual_hash, expected_hash, None if actual_hash == expected_hash else "MODEL_FILE_HASH_MISMATCH"))
    return gates


def _reference_preflight(reference: dict[str, Any], fixture: dict[str, Any]) -> str | None:
    if reference.get("schemaVersion") != 1 or reference.get("fixtureId") != fixture["id"]:
        return "REFERENCE_IDENTITY_INVALID"
    if not normalize_tokens(reference.get("words", [])):
        return "REFERENCE_WORDS_MISSING"
    if not reference.get("beginningAnchors") or not reference.get("tailAnchors"):
        return "REFERENCE_ANCHORS_MISSING"
    duration = reference.get("durationMs")
    last_speech = reference.get("lastSpeechEndMs")
    if not isinstance(duration, int) or not isinstance(last_speech, int) or not 0 < last_speech <= duration:
        return "REFERENCE_TIMELINE_INVALID"
    phenomena = set(reference.get("phenomena", []))
    if not set(fixture["requiredPhenomena"]).issubset(phenomena):
        return "REFERENCE_PHENOMENA_INCOMPLETE"
    return None


def _fixture_preflight(manifest: dict[str, Any], fixtures_dir: Path) -> tuple[list[Gate], dict[str, list[str]]]:
    gates: list[Gate] = []
    reasons_by_fixture: dict[str, list[str]] = {}
    audio_format = manifest["audioFormat"]
    for fixture in manifest["fixtures"]:
        fixture_id = fixture["id"]
        reasons: list[str] = []
        prefix = f"fixture.{fixture_id}"
        if fixture.get("assetStatus") != "ready":
            reasons.append("CORPUS_ASSET_NOT_READY")
            gates.append(Gate(f"{prefix}.asset-status", "blocked", fixture.get("assetStatus"), "ready", "CORPUS_ASSET_NOT_READY"))

        audio_path = fixtures_dir / fixture["audioPath"]
        reference_path = fixtures_dir / fixture["referencePath"]
        for kind, path, expected_hash in (
            ("audio", audio_path, fixture.get("audioSha256")),
            ("reference", reference_path, fixture.get("referenceSha256")),
        ):
            if not expected_hash:
                reasons.append(f"{kind.upper()}_HASH_NOT_PINNED")
                gates.append(Gate(f"{prefix}.{kind}-hash", "blocked", threshold="sha256", reason=f"{kind.upper()}_HASH_NOT_PINNED"))
            elif not path.is_file():
                reasons.append(f"{kind.upper()}_FILE_MISSING")
                gates.append(Gate(f"{prefix}.{kind}-file", "blocked", threshold="present", reason=f"{kind.upper()}_FILE_MISSING"))
            else:
                actual = sha256_file(path)
                status = "passed" if actual == expected_hash else "blocked"
                reason = None if status == "passed" else f"{kind.upper()}_HASH_MISMATCH"
                if reason:
                    reasons.append(reason)
                gates.append(Gate(f"{prefix}.{kind}-hash", status, actual, expected_hash, reason))

        if audio_path.is_file():
            try:
                with wave.open(str(audio_path), "rb") as audio:
                    frames = audio.getnframes()
                    rate = audio.getframerate()
                    duration_ms = round(frames * 1000 / rate)
                    format_ok = (
                        audio.getnchannels() == audio_format["channels"]
                        and audio.getsampwidth() == 2
                        and rate == audio_format["sampleRateHz"]
                        and audio.getcomptype() == "NONE"
                    )
            except (wave.Error, EOFError):
                format_ok = False
                duration_ms = -1
            duration_ok = fixture["durationRangeMs"][0] <= duration_ms <= fixture["durationRangeMs"][1]
            if not format_ok:
                reasons.append("AUDIO_FORMAT_INVALID")
            if not duration_ok:
                reasons.append("AUDIO_DURATION_INVALID")
            gates.append(Gate(f"{prefix}.audio-format", "passed" if format_ok else "blocked", format_ok, True, None if format_ok else "AUDIO_FORMAT_INVALID"))
            gates.append(Gate(f"{prefix}.audio-duration-ms", "passed" if duration_ok else "blocked", duration_ms, fixture["durationRangeMs"], None if duration_ok else "AUDIO_DURATION_INVALID"))

        if reference_path.is_file():
            try:
                reference = load_json(reference_path)
                reference_reason = _reference_preflight(reference, fixture)
            except (OSError, json.JSONDecodeError, QualificationError):
                reference_reason = "REFERENCE_INVALID"
            if reference_reason:
                reasons.append(reference_reason)
            gates.append(Gate(f"{prefix}.reference-shape", "passed" if reference_reason is None else "blocked", threshold="valid hand label", reason=reference_reason))

        reasons_by_fixture[fixture_id] = sorted(set(reasons))
    return gates, reasons_by_fixture


def preflight(lock: dict[str, Any], manifest: dict[str, Any], fixtures_dir: Path, model_dir: Path | None) -> tuple[list[Gate], dict[str, list[str]]]:
    validate_locked_configuration(lock, manifest)
    gates = _runtime_preflight(lock)
    gates.extend(_model_preflight(lock, model_dir))
    fixture_gates, reasons = _fixture_preflight(manifest, fixtures_dir)
    gates.extend(fixture_gates)
    global_reasons = sorted({gate.reason for gate in gates if gate.status != "passed" and gate.reason and not gate.gate.startswith("fixture.")})
    for fixture_id in reasons:
        reasons[fixture_id] = sorted(set(reasons[fixture_id] + global_reasons))
    return gates, reasons


class ThermalSampler:
    def __init__(self, workspace: Path) -> None:
        self.binary = workspace / "thermal-state-probe"
        self.module_cache = workspace / "swift-module-cache"
        self.states: list[str] = []
        self.available = False
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def prepare(self) -> None:
        self.module_cache.mkdir(parents=True, exist_ok=True)
        completed = subprocess.run(
            ["swiftc", "-module-cache-path", str(self.module_cache), str(THERMAL_PROBE), "-o", str(self.binary)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        self.available = completed.returncode == 0

    def sample_once(self) -> str | None:
        if not self.available:
            return None
        completed = subprocess.run([str(self.binary)], capture_output=True, text=True, check=False)
        state = completed.stdout.strip()
        if completed.returncode != 0 or state not in THERMAL_ORDER:
            self.available = False
            return None
        self.states.append(state)
        return state

    def start(self) -> None:
        self.sample_once()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def _loop(self) -> None:
        while not self._stop.wait(2):
            self.sample_once()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=3)
        self.sample_once()

    def maximum_state(self) -> str | None:
        return max(self.states, key=THERMAL_ORDER.get) if self.states else None

    def wait_for_recovery(self, target: str, maximum_seconds: float) -> float | None:
        if not self.available:
            return None
        maximum = self.maximum_state()
        if maximum is not None and THERMAL_ORDER[maximum] <= THERMAL_ORDER[target]:
            return 0.0
        started = time.monotonic()
        while time.monotonic() - started <= maximum_seconds:
            state = self.sample_once()
            if state is not None and THERMAL_ORDER[state] <= THERMAL_ORDER[target]:
                return time.monotonic() - started
            time.sleep(5)
        return None


class WorkerSession:
    def __init__(self, model_dir: Path, lock_path: Path, workspace: Path, prove_offline: bool = True) -> None:
        self.workspace = workspace
        self.workspace.mkdir(parents=True, exist_ok=True)
        command = [sys.executable, str(WORKER), "--engine-lock", str(lock_path), "--model-dir", str(model_dir)]
        self.network_guarded = False
        sandbox_exec = Path("/usr/bin/sandbox-exec")
        if prove_offline and sandbox_exec.is_file():
            command = [str(sandbox_exec), "-p", "(version 1) (allow default) (deny network*)"] + command
            self.network_guarded = True
        allowed_environment = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "HOME": str(self.workspace / "empty-home"),
            "TMPDIR": str(self.workspace / "tmp"),
            "XDG_CACHE_HOME": str(self.workspace / "cache"),
            "PYTHONNOUSERSITE": "1",
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "TOKENIZERS_PARALLELISM": "false",
        }
        Path(allowed_environment["HOME"]).mkdir(parents=True, exist_ok=True)
        Path(allowed_environment["TMPDIR"]).mkdir(parents=True, exist_ok=True)
        self.process = subprocess.Popen(
            command,
            cwd=self.workspace,
            env=allowed_environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        self.peak_resident_bytes = 0
        self._monitor_stop = threading.Event()
        self._monitor = threading.Thread(target=self._monitor_memory, daemon=True)
        self._monitor.start()

    def _monitor_memory(self) -> None:
        while not self._monitor_stop.wait(0.2):
            completed = subprocess.run(
                ["/bin/ps", "-o", "rss=", "-p", str(self.process.pid)],
                capture_output=True,
                text=True,
                check=False,
            )
            try:
                self.peak_resident_bytes = max(self.peak_resident_bytes, int(completed.stdout.strip()) * 1024)
            except ValueError:
                pass

    def _read_json(self, timeout: float) -> dict[str, Any]:
        if self.process.stdout is None:
            raise QualificationError("worker stdout unavailable")
        selector = selectors.DefaultSelector()
        selector.register(self.process.stdout, selectors.EVENT_READ)
        events = selector.select(timeout)
        selector.close()
        if not events:
            raise QualificationError("worker response timed out")
        line = self.process.stdout.readline()
        if not line:
            raise QualificationError("worker exited before a complete response")
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            raise QualificationError("worker emitted malformed protocol JSON") from error
        if not isinstance(value, dict):
            raise QualificationError("worker response must be an object")
        if value.get("type") == "failed":
            raise QualificationError(f"worker failed: {value.get('code', 'UNKNOWN')}")
        return value

    def hello(self, timeout: float = 180) -> dict[str, Any]:
        message = self._read_json(timeout)
        if message.get("type") != "hello":
            raise QualificationError("worker did not emit hello")
        return message

    def send_transcribe(self, fixture_id: str, audio_path: Path, timeout: float) -> dict[str, Any]:
        self.begin_transcribe(fixture_id, audio_path)
        message = self._read_json(timeout)
        if message.get("type") != "result" or message.get("fixtureId") != fixture_id:
            raise QualificationError("worker returned the wrong result identity")
        return message

    def begin_transcribe(self, fixture_id: str, audio_path: Path) -> None:
        if self.process.stdin is None:
            raise QualificationError("worker stdin unavailable")
        request = {"type": "transcribe", "fixtureId": fixture_id, "audioPath": str(audio_path)}
        self.process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

    def close(self) -> None:
        if self.process.poll() is None and self.process.stdin is not None:
            try:
                self.process.stdin.write('{"type":"shutdown"}\n')
                self.process.stdin.flush()
                self.process.wait(timeout=10)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                self.process.terminate()
        self._monitor_stop.set()
        self._monitor.join(timeout=2)

    def terminate_for_cancellation(self, maximum_seconds: float) -> tuple[float, bool]:
        started = time.monotonic()
        self.process.terminate()
        forced_kill = False
        try:
            self.process.wait(timeout=maximum_seconds)
        except subprocess.TimeoutExpired:
            forced_kill = True
            self.process.kill()
            self.process.wait(timeout=2)
        elapsed = time.monotonic() - started
        self._monitor_stop.set()
        self._monitor.join(timeout=2)
        return elapsed, forced_kill


def _runtime_gates(
    manifest: dict[str, Any],
    duration_seconds: float,
    hello: dict[str, Any],
    first: dict[str, Any],
    warm: dict[str, Any],
    peak_resident_bytes: int,
    maximum_thermal_state: str | None,
    thermal_recovery_seconds: float | None,
) -> tuple[dict[str, Any], list[Gate]]:
    thresholds = manifest["thresholds"]["runtime"]
    cold_rtf = (float(hello["modelLoadSeconds"]) + float(first["elapsedSeconds"])) / duration_seconds
    warm_rtf = float(warm["elapsedSeconds"]) / duration_seconds
    peak_mps = max(int(first.get("peakMpsDriverAllocatedBytes", 0)), int(warm.get("peakMpsDriverAllocatedBytes", 0)))
    gates = [
        _gate_maximum("runtime.cold-real-time-factor", cold_rtf, thresholds["maximumColdRealTimeFactor"]),
        _gate_maximum("runtime.warm-real-time-factor", warm_rtf, thresholds["maximumWarmRealTimeFactor"]),
        _gate_maximum("runtime.peak-resident-bytes", peak_resident_bytes, thresholds["maximumPeakResidentBytes"]),
        _gate_maximum("runtime.peak-mps-driver-allocated-bytes", peak_mps, thresholds["maximumPeakMpsDriverAllocatedBytes"]),
    ]
    if maximum_thermal_state is None:
        gates.append(Gate("runtime.maximum-thermal-state", "failed", threshold=thresholds["maximumThermalState"], reason="THERMAL_MEASUREMENT_UNAVAILABLE"))
    else:
        threshold_value = THERMAL_ORDER[thresholds["maximumThermalState"]]
        measured_value = THERMAL_ORDER[maximum_thermal_state]
        gates.append(Gate("runtime.maximum-thermal-state", "passed" if measured_value <= threshold_value else "failed", maximum_thermal_state, thresholds["maximumThermalState"]))
    if thermal_recovery_seconds is None:
        gates.append(Gate("runtime.thermal-recovery-seconds", "failed", threshold=thresholds["maximumThermalRecoverySeconds"], reason="THERMAL_RECOVERY_NOT_OBSERVED"))
    else:
        gates.append(_gate_maximum("runtime.thermal-recovery-seconds", thermal_recovery_seconds, thresholds["maximumThermalRecoverySeconds"]))
    measurements = {
        "modelLoadSeconds": hello["modelLoadSeconds"],
        "coldInferenceSeconds": first["elapsedSeconds"],
        "warmInferenceSeconds": warm["elapsedSeconds"],
        "coldRealTimeFactor": cold_rtf,
        "warmRealTimeFactor": warm_rtf,
        "peakResidentBytes": peak_resident_bytes,
        "peakMpsDriverAllocatedBytes": peak_mps,
        "maximumThermalState": maximum_thermal_state,
        "thermalRecoverySeconds": thermal_recovery_seconds,
    }
    return measurements, gates


def run_fixture(
    fixture: dict[str, Any],
    manifest: dict[str, Any],
    fixtures_dir: Path,
    model_dir: Path,
    workspace: Path,
) -> dict[str, Any]:
    audio_path = fixtures_dir / fixture["audioPath"]
    reference = load_json(fixtures_dir / fixture["referencePath"])
    thermal = ThermalSampler(workspace / "thermal")
    thermal.prepare()
    thermal.start()
    session: WorkerSession | None = None
    try:
        session = WorkerSession(model_dir, ENGINE_LOCK, workspace / "worker")
        hello = session.hello()
        duration_seconds = reference["durationMs"] / 1000
        timeout = max(300.0, duration_seconds * 2)
        first = session.send_transcribe(fixture["id"], audio_path, timeout)
        warm = session.send_transcribe(fixture["id"], audio_path, timeout)
    finally:
        if session is not None:
            session.close()
        thermal.stop()

    runtime_thresholds = manifest["thresholds"]["runtime"]
    thermal_recovery_seconds = thermal.wait_for_recovery(
        runtime_thresholds["thermalRecoveryTarget"],
        runtime_thresholds["maximumThermalRecoverySeconds"],
    )

    quality = evaluate_transcript(reference, first, manifest["thresholds"])
    runtime_measurements, runtime_gates = _runtime_gates(
        manifest,
        duration_seconds,
        hello,
        first,
        warm,
        session.peak_resident_bytes,
        thermal.maximum_state(),
        thermal_recovery_seconds,
    )
    deterministic = normalize_tokens(first["text"]) == normalize_tokens(warm["text"])
    runtime_gates.append(Gate("quality.cold-warm-output-match", "passed" if deterministic else "failed", deterministic, True))
    gates = quality["gates"] + [gate.as_json() for gate in runtime_gates]
    return {
        "id": fixture["id"],
        "status": "passed" if all(gate["status"] == "passed" for gate in gates) else "failed",
        "measurements": {**quality["measurements"], **runtime_measurements, "coldWarmOutputMatch": deterministic},
        "gates": gates,
    }


def run_cancellation(
    fixture: dict[str, Any],
    manifest: dict[str, Any],
    fixtures_dir: Path,
    model_dir: Path,
    workspace: Path,
) -> dict[str, Any]:
    thresholds = manifest["thresholds"]["cancellation"]
    session: WorkerSession | None = None
    try:
        session = WorkerSession(model_dir, ENGINE_LOCK, workspace)
        hello = session.hello()
        session.begin_transcribe(fixture["id"], fixtures_dir / fixture["audioPath"])
        time.sleep(thresholds["cancelAfterSeconds"])
        elapsed, forced_kill = session.terminate_for_cancellation(thresholds["maximumTerminationSeconds"])
    finally:
        if session is not None and session.process.poll() is None:
            session.close()
    if session is None:
        raise QualificationError("cancellation worker did not start")
    gates = [
        _gate_maximum("cancellation.termination-seconds", elapsed, thresholds["maximumTerminationSeconds"]),
        Gate("cancellation.no-forced-kill", "passed" if not forced_kill else "failed", not forced_kill, thresholds["mustExitWithoutForcedKill"]),
        Gate("cancellation.worker-reaped", "passed" if session.process.poll() is not None else "failed", session.process.poll() is not None, True),
    ]
    return {
        "status": "passed" if all(gate.status == "passed" for gate in gates) else "failed",
        "modelLoadSeconds": hello["modelLoadSeconds"],
        "terminationSeconds": elapsed,
        "forcedKill": forced_kill,
        "gates": [gate.as_json() for gate in gates],
    }


def run_cached_offline(
    fixture: dict[str, Any],
    fixtures_dir: Path,
    model_dir: Path,
    workspace: Path,
) -> dict[str, Any]:
    session: WorkerSession | None = None
    try:
        session = WorkerSession(model_dir, ENGINE_LOCK, workspace, prove_offline=True)
        hello = session.hello()
        with wave.open(str(fixtures_dir / fixture["audioPath"]), "rb") as audio:
            duration_seconds = audio.getnframes() / audio.getframerate()
        session.send_transcribe(fixture["id"], fixtures_dir / fixture["audioPath"], max(300, duration_seconds * 2))
        succeeded = True
    except QualificationError:
        succeeded = False
        hello = {}
    finally:
        if session is not None:
            session.close()
    if session is None:
        raise QualificationError("offline worker did not start")
    network_denied = session.network_guarded and hello.get("networkProbe") == "denied"
    gates = [
        Gate("cached-offline.inference", "passed" if succeeded else "failed", succeeded, True),
        Gate("cached-offline.network-denied", "passed" if network_denied else "failed", network_denied, True),
    ]
    return {
        "status": "passed" if all(gate.status == "passed" for gate in gates) else "failed",
        "gates": [gate.as_json() for gate in gates],
    }


def blocked_report(lock: dict[str, Any], manifest: dict[str, Any], gates: list[Gate], reasons: dict[str, list[str]]) -> dict[str, Any]:
    cases = [{"id": fixture["id"], "status": "blocked", "reasonCodes": reasons[fixture["id"]]} for fixture in manifest["fixtures"]]
    return {
        "schemaVersion": 1,
        "recordedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "qualificationProfileId": lock["qualificationProfileId"],
        "engineLockSha256": canonical_json_sha256(lock),
        "corpusManifestSha256": canonical_json_sha256(manifest),
        "environment": {
            "operatingSystem": platform.system(),
            "operatingSystemRelease": platform.release(),
            "machine": platform.machine(),
            "pythonVersion": platform.python_version(),
        },
        "qualificationStatus": "blocked",
        "preflight": [gate.as_json() for gate in gates],
        "fixtures": cases,
        "cancellation": {"status": "blocked", "reasonCodes": reasons["forty-five-minute"]},
        "cachedOffline": {"status": "blocked", "reasonCodes": reasons["short"]},
        "engineSelectionChanged": False,
    }


def run_qualification(lock: dict[str, Any], manifest: dict[str, Any], fixtures_dir: Path, model_dir: Path, output_parent: Path) -> dict[str, Any]:
    run_workspace = Path(tempfile.mkdtemp(prefix="audora-crisper-", dir=output_parent))
    try:
        fixtures = []
        for fixture in manifest["fixtures"]:
            try:
                result = run_fixture(fixture, manifest, fixtures_dir, model_dir, run_workspace / fixture["id"])
            except Exception:
                result = {"id": fixture["id"], "status": "failed", "gates": [Gate("runner.execution", "failed", reason="QUALIFICATION_EXECUTION_FAILED").as_json()]}
            fixtures.append(result)
        fixture_by_id = {fixture["id"]: fixture for fixture in manifest["fixtures"]}
        try:
            cancellation = run_cancellation(fixture_by_id["forty-five-minute"], manifest, fixtures_dir, model_dir, run_workspace / "cancellation")
        except Exception:
            cancellation = {"status": "failed", "gates": [Gate("cancellation.execution", "failed", reason="QUALIFICATION_EXECUTION_FAILED").as_json()]}
        try:
            cached_offline = run_cached_offline(fixture_by_id["short"], fixtures_dir, model_dir, run_workspace / "cached-offline")
        except Exception:
            cached_offline = {"status": "failed", "gates": [Gate("cached-offline.execution", "failed", reason="QUALIFICATION_EXECUTION_FAILED").as_json()]}
        passed = all(item["status"] == "passed" for item in fixtures) and cancellation["status"] == "passed" and cached_offline["status"] == "passed"
        return {
            "schemaVersion": 1,
            "recordedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
            "qualificationProfileId": lock["qualificationProfileId"],
            "engineLockSha256": canonical_json_sha256(lock),
            "corpusManifestSha256": canonical_json_sha256(manifest),
            "environment": {
                "operatingSystem": platform.system(),
                "operatingSystemRelease": platform.release(),
                "machine": platform.machine(),
                "pythonVersion": platform.python_version(),
            },
            "qualificationStatus": "passed" if passed else "failed",
            "fixtures": fixtures,
            "cancellation": cancellation,
            "cachedOffline": cached_offline,
            "engineSelectionChanged": False,
        }
    finally:
        shutil.rmtree(run_workspace, ignore_errors=True)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures-dir", type=Path, default=ROOT / "fixtures")
    parser.add_argument("--model-dir", type=Path, default=None, help="Local immutable model snapshot; never downloaded by this runner")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--preflight-only", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_args(argv if argv is not None else sys.argv[1:])
    lock = load_json(ENGINE_LOCK)
    manifest = load_json(CORPUS_MANIFEST)
    model_dir = arguments.model_dir
    if model_dir is None and os.environ.get("AUDORA_CRISPER_MODEL_DIR"):
        model_dir = Path(os.environ["AUDORA_CRISPER_MODEL_DIR"])
    gates, reasons = preflight(lock, manifest, arguments.fixtures_dir, model_dir)
    preflight_passed = all(gate.status == "passed" for gate in gates)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    if arguments.preflight_only or not preflight_passed:
        report = blocked_report(lock, manifest, gates, reasons)
    else:
        if model_dir is None:
            raise AssertionError("preflight accepted an absent model")
        report = run_qualification(lock, manifest, arguments.fixtures_dir, model_dir, arguments.output.parent)
    arguments.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Crisper qualification: {report['qualificationStatus']}")
    return 0 if report["qualificationStatus"] == "passed" or arguments.preflight_only else 2


if __name__ == "__main__":
    raise SystemExit(main())
