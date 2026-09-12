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
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Protocol


ROOT = Path(__file__).resolve().parent
ENGINE_LOCK = ROOT / "engine-lock.v1.json"
CORPUS_MANIFEST = ROOT / "corpus-manifest.v1.json"
PUBLIC_SOURCE_PLAN = ROOT / "public-source-plan.v1.json"
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
EXPECTED_PACKAGE_VERSIONS = {
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
EXPECTED_FIXTURE_SPECS = {
    "short": (
        (10_000, 30_000),
        frozenset(
            {
                "beginning-speech",
                "filled-pause",
                "immediate-repetition",
                "tail-speech",
            }
        ),
    ),
    "one-minute": (
        (55_000, 65_000),
        frozenset(
            {
                "quiet-speech",
                "filled-pause",
                "immediate-repetition",
                "partial-word",
                "laughter",
                "long-pause",
                "tail-speech",
            }
        ),
    ),
    "twelve-minute": (
        (710_000, 730_000),
        frozenset(
            {
                "quiet-speech",
                "filled-pause",
                "immediate-repetition",
                "partial-word",
                "laughter",
                "long-pause",
                "longform-boundary",
                "tail-speech",
            }
        ),
    ),
    "forty-five-minute": (
        (2_690_000, 2_699_999),
        frozenset(
            {
                "quiet-speech",
                "filled-pause",
                "immediate-repetition",
                "partial-word",
                "laughter",
                "long-pause",
                "longform-boundary",
                "final-underfilled-window",
                "tail-speech",
            }
        ),
    ),
}
THERMAL_ORDER = {"nominal": 0, "fair": 1, "serious": 2, "critical": 3}
TOKEN_PATTERN = re.compile(r"\[[^\]\s]+\]|[a-z0-9]+(?:['-][a-z0-9]+)*-?")
SAFE_REASON_PATTERN = re.compile(r"[A-Z][A-Z0-9_]{0,63}")
SAFE_PATCH_ID_PATTERN = re.compile(r"[a-z0-9][a-z0-9._-]{0,127}")
SAFE_SOURCE_IDENTIFIER_PATTERN = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
SAFE_FIXTURE_PATH_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,255}")
ANCHOR_PHENOMENA = {"beginning-speech", "tail-speech"}
VERBATIM_EVENT_KINDS = {
    "quiet-speech",
    "filled-pause",
    "immediate-repetition",
    "partial-word",
    "laughter",
    "long-pause",
    "longform-boundary",
    "final-underfilled-window",
}
WORD_SPAN_EVENT_KINDS = {
    "quiet-speech",
    "filled-pause",
    "immediate-repetition",
    "partial-word",
    "laughter",
}
SUPPORTED_PHENOMENA = ANCHOR_PHENOMENA | VERBATIM_EVENT_KINDS
MAX_WORKER_PROTOCOL_LINE_BYTES = 16 * 1024 * 1024
FIXTURE_FIELDS = {
    "id",
    "audioPath",
    "referencePath",
    "audioSha256",
    "referenceSha256",
    "durationRangeMs",
    "requiredPhenomena",
    "sourceProvenance",
    "assetStatus",
}

FIXTURE_MEASUREMENT_KINDS = {
    "audioDurationMs": "integer",
    "referenceWordCount": "integer",
    "candidateWordCount": "integer",
    "wordErrorRate": "number",
    "referenceWordCoverage": "number",
    "verbatimEventRecall": "number",
    "beginningAnchorCoverage": "number",
    "tailAnchorCoverage": "number",
    "wordCountRatio": "number",
    "referenceMaximumRepeatedNgramRun": "integer",
    "candidateMaximumRepeatedNgramRun": "integer",
    "excessRepeatedNgramRun": "integer",
    "timedWordRatio": "number",
    "textWordCountMatches": "boolean",
    "oneTokenPerTimedWord": "boolean",
    "textWordContentMatches": "boolean",
    "zeroDurationWordRatio": "number",
    "monotonicWordTimes": "boolean",
    "wordsWithinAudio": "boolean",
    "tailLagMs": "integer",
    "maximumWordStartErrorMs": "integer",
    "maximumWordEndErrorMs": "integer",
    "alignedWordTimingRatio": "number",
    "longPauseTimingRecall": "number",
    "longformBoundaryTimingRecall": "number",
    "finalUnderfilledWindowTimingRecall": "number",
    "modelLoadSeconds": "number",
    "coldInferenceSeconds": "number",
    "warmInferenceSeconds": "number",
    "coldRealTimeFactor": "number",
    "warmRealTimeFactor": "number",
    "peakResidentBytes": "optional-integer",
    "peakMpsDriverAllocatedBytes": "optional-integer",
    "maximumThermalState": "optional-thermal",
    "thermalRecoverySeconds": "optional-number",
    "coldWarmOutputMatch": "boolean",
}
FIXTURE_GATE_MEASUREMENTS = {
    "quality.word-error-rate": "wordErrorRate",
    "quality.reference-word-coverage": "referenceWordCoverage",
    "quality.verbatim-event-recall": "verbatimEventRecall",
    "quality.beginning-anchor-coverage": "beginningAnchorCoverage",
    "quality.tail-anchor-coverage": "tailAnchorCoverage",
    "quality.word-count-ratio-minimum": "wordCountRatio",
    "quality.word-count-ratio-maximum": "wordCountRatio",
    "quality.excess-repeated-ngram-run": "excessRepeatedNgramRun",
    "timing.timed-word-ratio": "timedWordRatio",
    "timing.text-word-count-match": "textWordCountMatches",
    "timing.one-token-per-word": "oneTokenPerTimedWord",
    "timing.text-word-content-match": "textWordContentMatches",
    "timing.zero-duration-word-ratio": "zeroDurationWordRatio",
    "timing.tail-lag-ms": "tailLagMs",
    "timing.maximum-word-start-error-ms": "maximumWordStartErrorMs",
    "timing.maximum-word-end-error-ms": "maximumWordEndErrorMs",
    "timing.aligned-word-timing-ratio": "alignedWordTimingRatio",
    "timing.long-pause-timing-recall": "longPauseTimingRecall",
    "timing.longform-boundary-timing-recall": "longformBoundaryTimingRecall",
    "timing.final-underfilled-window-timing-recall": "finalUnderfilledWindowTimingRecall",
    "timing.monotonic": "monotonicWordTimes",
    "timing.within-audio": "wordsWithinAudio",
    "runtime.cold-real-time-factor": "coldRealTimeFactor",
    "runtime.warm-real-time-factor": "warmRealTimeFactor",
    "runtime.peak-resident-bytes": "peakResidentBytes",
    "runtime.peak-mps-driver-allocated-bytes": "peakMpsDriverAllocatedBytes",
    "runtime.maximum-thermal-state": "maximumThermalState",
    "runtime.thermal-recovery-seconds": "thermalRecoverySeconds",
    "quality.cold-warm-output-match": "coldWarmOutputMatch",
}


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


def canonical_audio_duration_ms(frame_count: int, sample_rate: int) -> int:
    if type(frame_count) is not int or frame_count < 0:
        raise QualificationError("audio frame count is invalid")
    if type(sample_rate) is not int or sample_rate <= 0:
        raise QualificationError("audio sample rate is invalid")
    return (frame_count * 1000 + sample_rate - 1) // sample_rate


def _final_window_start_ms(
    duration_ms: int,
    chunk_duration_ms: int,
    stride_ms: int,
) -> int:
    if (
        type(duration_ms) is not int
        or type(chunk_duration_ms) is not int
        or type(stride_ms) is not int
        or duration_ms <= 0
        or chunk_duration_ms <= 0
        or stride_ms <= 0
    ):
        raise QualificationError("longform window values must be positive integers")
    if duration_ms <= chunk_duration_ms:
        return 0
    return (
        (duration_ms - chunk_duration_ms + stride_ms - 1) // stride_ms
    ) * stride_ms


def _first_full_final_window_duration_ms(
    minimum_duration_ms: int,
    chunk_duration_ms: int,
    stride_ms: int,
) -> int:
    if (
        type(minimum_duration_ms) is not int
        or type(chunk_duration_ms) is not int
        or type(stride_ms) is not int
        or minimum_duration_ms <= 0
        or chunk_duration_ms <= 0
        or stride_ms <= 0
    ):
        raise QualificationError("longform window values must be positive integers")
    stride_count = max(
        0,
        (minimum_duration_ms - chunk_duration_ms + stride_ms - 1) // stride_ms,
    )
    return chunk_duration_ms + stride_count * stride_ms


def _validated_wave_duration_ms(path: Path, audio_format: dict[str, Any]) -> int:
    try:
        with wave.open(str(path), "rb") as audio:
            valid = (
                audio.getnchannels() == audio_format["channels"]
                and audio.getsampwidth() == 2
                and audio.getframerate() == audio_format["sampleRateHz"]
                and audio.getcomptype() == "NONE"
            )
            duration_ms = canonical_audio_duration_ms(
                audio.getnframes(),
                audio.getframerate(),
            )
    except (OSError, EOFError, wave.Error) as error:
        raise QualificationError("audio WAV is invalid") from error
    if not valid:
        raise QualificationError("audio WAV format is invalid")
    return duration_ms


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


def anchor_coverage(
    tokens: list[str],
    anchors: list[list[str]],
    *,
    position: str,
    boundary_words: int,
) -> float:
    if not anchors:
        return 0.0
    window_size = min(boundary_words, max(1, len(tokens) // 2))
    if position == "beginning":
        boundary_tokens = tokens[:window_size]
    elif position == "tail":
        boundary_tokens = tokens[-window_size:]
    else:
        raise QualificationError("anchor position is invalid")
    present = sum(
        phrase_occurrences(boundary_tokens, normalize_tokens(anchor)) > 0
        for anchor in anchors
    )
    return present / len(anchors)


def _strict_reference_tokens(reference: dict[str, Any]) -> list[str]:
    words = reference.get("words")
    if type(words) is not list or not words:
        raise QualificationError("reference words must be a nonempty array")
    normalized: list[str] = []
    for word in words:
        if not isinstance(word, str):
            raise QualificationError("reference words must contain only strings")
        tokens = normalize_tokens(word)
        if len(tokens) != 1:
            raise QualificationError("each reference word must normalize to one token")
        normalized.append(tokens[0])
    return normalized


def _validated_reference_word_timings(
    reference: dict[str, Any],
    token_count: int,
    duration_ms: int,
    last_speech_end_ms: int,
) -> list[dict[str, int]]:
    timings = reference.get("wordTimings")
    if type(timings) is not list or len(timings) != token_count:
        raise QualificationError("reference word timings must align one-to-one")
    validated: list[dict[str, int]] = []
    previous_start = -1
    previous_end = -1
    for timing in timings:
        if not isinstance(timing, dict) or set(timing) != {"startMs", "endMs"}:
            raise QualificationError("reference word timing shape is invalid")
        start = timing.get("startMs")
        end = timing.get("endMs")
        if (
            type(start) is not int
            or type(end) is not int
            or not 0 <= start < end <= duration_ms
            or start < previous_start
            or end < previous_end
        ):
            raise QualificationError("reference word timing value is invalid")
        validated.append({"startMs": start, "endMs": end})
        previous_start = start
        previous_end = end
    if validated[-1]["endMs"] != last_speech_end_ms:
        raise QualificationError("last reference word must end at lastSpeechEndMs")
    return validated


def _word_span(event: dict[str, Any], token_count: int) -> tuple[int, int]:
    start = event.get("startWordIndex")
    end = event.get("endWordIndex")
    if (
        type(start) is not int
        or type(end) is not int
        or not 0 <= start <= end < token_count
    ):
        raise QualificationError("reference event word span is invalid")
    return start, end


def _pause_span(event: dict[str, Any], token_count: int) -> tuple[int, int]:
    before = event.get("beforeWordIndex")
    after = event.get("afterWordIndex")
    if (
        type(before) is not int
        or type(after) is not int
        or not 0 <= before < after < token_count
        or after != before + 1
    ):
        raise QualificationError("reference event pause span is invalid")
    return before, after


def _validated_reference_events(
    reference: dict[str, Any],
    tokens: list[str],
    word_timings: list[dict[str, int]],
    timing_thresholds: dict[str, Any],
    duration_ms: int,
) -> list[dict[str, Any]]:
    events = reference.get("verbatimEvents")
    if type(events) is not list:
        raise QualificationError("reference verbatim events must be an array")
    validated: list[dict[str, Any]] = []
    for event in events:
        if not isinstance(event, dict) or event.get("kind") not in VERBATIM_EVENT_KINDS:
            raise QualificationError("reference verbatim event kind is invalid")
        kind = event["kind"]
        if kind in WORD_SPAN_EVENT_KINDS:
            if set(event) != {"kind", "startWordIndex", "endWordIndex"}:
                raise QualificationError("reference word event shape is invalid")
            start, end = _word_span(event, len(tokens))
            span = tokens[start : end + 1]
            semantic = (
                kind == "quiet-speech"
                or (
                    kind == "filled-pause"
                    and any(
                        token in {"um", "uh", "erm", "hmm", "[um]", "[uh]", "[erm]", "[hmm]"}
                        for token in span
                    )
                )
                or (
                    kind == "immediate-repetition"
                    and maximum_repeated_ngram_run(span) >= 2
                )
                or (kind == "partial-word" and any(token.endswith("-") for token in span))
                or (
                    kind == "laughter"
                    and any(token in {"[laughter]", "[laughing]", "[laugh]"} for token in span)
                )
            )
            if not semantic:
                raise QualificationError("reference word event does not match its kind")
        elif kind == "long-pause":
            if set(event) != {"kind", "beforeWordIndex", "afterWordIndex"}:
                raise QualificationError("reference long-pause event shape is invalid")
            before, after = _pause_span(event, len(tokens))
            pause_ms = (
                word_timings[after]["startMs"] - word_timings[before]["endMs"]
            )
            if pause_ms < timing_thresholds["minimumLongPauseMs"]:
                raise QualificationError("reference long pause is below the pinned minimum")
        elif kind == "longform-boundary":
            if set(event) != {
                "kind",
                "beforeWordIndex",
                "afterWordIndex",
                "boundaryMs",
            }:
                raise QualificationError("reference longform boundary shape is invalid")
            before, after = _pause_span(event, len(tokens))
            boundary = event.get("boundaryMs")
            interval = timing_thresholds["longformBoundaryIntervalMs"]
            if (
                type(boundary) is not int
                or type(interval) is not int
                or interval <= 0
                or boundary <= 0
                or boundary >= duration_ms
                or boundary % interval != 0
                or word_timings[before]["endMs"] > boundary
                or word_timings[after]["startMs"] < boundary
            ):
                raise QualificationError("reference longform boundary is misplaced")
        else:
            if set(event) != {
                "kind",
                "startWordIndex",
                "endWordIndex",
                "windowStartMs",
            }:
                raise QualificationError("reference final-window event shape is invalid")
            start, end = _word_span(event, len(tokens))
            window_start = event.get("windowStartMs")
            window_size = timing_thresholds["finalWindowSizeMs"]
            stride = timing_thresholds["longformBoundaryIntervalMs"]
            expected_start = _final_window_start_ms(
                duration_ms,
                window_size,
                stride,
            )
            if (
                type(window_start) is not int
                or duration_ms - expected_start >= window_size
                or window_start != expected_start
                or end != len(tokens) - 1
                or word_timings[start]["endMs"] <= window_start
                or (start > 0 and word_timings[start - 1]["endMs"] > window_start)
            ):
                raise QualificationError("reference final underfilled window is misplaced")
        validated.append(dict(event))
    return validated


def _reference_candidate_alignment(
    matcher: difflib.SequenceMatcher,
) -> dict[int, int]:
    alignment: dict[int, int] = {}
    for block in matcher.get_matching_blocks():
        for offset in range(block.size):
            alignment[block.a + offset] = block.b + offset
    return alignment


def _ratio(successes: list[bool]) -> float:
    return sum(successes) / len(successes) if successes else 1.0


def maximum_repeated_ngram_run(
    tokens: list[str],
    maximum_ngram: int | None = None,
) -> int:
    """Return the longest adjacent phrase run without truncating phrase length."""

    if not tokens:
        return 0
    token_ids: dict[str, int] = {}
    encoded = [token_ids.setdefault(token, len(token_ids) + 1) for token in tokens]
    base = 1_000_003
    mask = (1 << 64) - 1
    prefixes = [0]
    powers = [1]
    for token_id in encoded:
        prefixes.append((prefixes[-1] * base + token_id) & mask)
        powers.append((powers[-1] * base) & mask)

    def block_hash(start: int, size: int) -> int:
        return (
            prefixes[start + size] - prefixes[start] * powers[size]
        ) & mask

    maximum = 1 if tokens else 0
    configured_limit = len(tokens) // 2 if maximum_ngram is None else maximum_ngram
    size = 1
    while size <= min(configured_limit, len(tokens) // (maximum + 1)):
        for start in range(0, len(tokens) - size + 1):
            if start + size * (maximum + 1) > len(tokens):
                break
            cursor = start + size
            phrase_hash = block_hash(start, size)
            if block_hash(cursor, size) != phrase_hash:
                continue
            phrase = tokens[start : start + size]
            run = 1
            while (
                cursor + size <= len(tokens)
                and block_hash(cursor, size) == phrase_hash
                and tokens[cursor : cursor + size] == phrase
            ):
                run += 1
                cursor += size
            maximum = max(maximum, run)
        size += 1
    return maximum


def _gate_maximum(name: str, measured: float, threshold: float) -> Gate:
    return Gate(name, "passed" if measured <= threshold else "failed", measured, threshold)


def _gate_minimum(name: str, measured: float, threshold: float) -> Gate:
    return Gate(name, "passed" if measured >= threshold else "failed", measured, threshold)


def evaluate_transcript(
    reference: dict[str, Any],
    candidate: dict[str, Any],
    thresholds: dict[str, Any],
    *,
    audio_duration_ms: int | None = None,
) -> dict[str, Any]:
    reference_tokens = _strict_reference_tokens(reference)
    candidate_tokens = normalize_tokens(candidate.get("text", ""))

    reference_duration_ms = reference.get("durationMs")
    last_speech_end_ms = reference.get("lastSpeechEndMs")
    if (
        type(reference_duration_ms) is not int
        or reference_duration_ms <= 0
        or type(last_speech_end_ms) is not int
        or not 0 < last_speech_end_ms <= reference_duration_ms
    ):
        raise QualificationError("reference timeline is invalid")
    if audio_duration_ms is None:
        duration_ms = reference_duration_ms
    elif type(audio_duration_ms) is not int or audio_duration_ms <= 0:
        raise QualificationError("audio duration must be a positive integer")
    elif reference_duration_ms != audio_duration_ms:
        raise QualificationError("reference duration does not match audio duration")
    else:
        duration_ms = audio_duration_ms
    reference_word_timings = _validated_reference_word_timings(
        reference,
        len(reference_tokens),
        duration_ms,
        last_speech_end_ms,
    )
    timing = thresholds["timing"]
    events = _validated_reference_events(
        reference,
        reference_tokens,
        reference_word_timings,
        timing,
        duration_ms,
    )

    distance = levenshtein_distance(reference_tokens, candidate_tokens)
    matcher = difflib.SequenceMatcher(a=reference_tokens, b=candidate_tokens, autojunk=False)
    alignment = _reference_candidate_alignment(matcher)
    matched_reference_words = len(alignment)
    word_error_rate = distance / len(reference_tokens)
    reference_coverage = matched_reference_words / len(reference_tokens)
    word_count_ratio = len(candidate_tokens) / len(reference_tokens)
    boundary_words = thresholds["quality"]["anchorBoundaryWindowWords"]
    if type(boundary_words) is not int or boundary_words <= 0:
        raise QualificationError("anchor boundary window must be a positive integer")
    if anchor_coverage(
        reference_tokens,
        reference.get("beginningAnchors", []),
        position="beginning",
        boundary_words=boundary_words,
    ) != 1.0 or anchor_coverage(
        reference_tokens,
        reference.get("tailAnchors", []),
        position="tail",
        boundary_words=boundary_words,
    ) != 1.0:
        raise QualificationError("reference anchors are not at their labeled boundaries")
    beginning_coverage = anchor_coverage(
        candidate_tokens,
        reference.get("beginningAnchors", []),
        position="beginning",
        boundary_words=boundary_words,
    )
    tail_coverage = anchor_coverage(
        candidate_tokens,
        reference.get("tailAnchors", []),
        position="tail",
        boundary_words=boundary_words,
    )
    reference_run = maximum_repeated_ngram_run(reference_tokens)
    candidate_run = maximum_repeated_ngram_run(candidate_tokens)
    excess_run = max(0, candidate_run - reference_run)

    timed_words = candidate.get("words", [])
    if not isinstance(timed_words, list) or not all(
        isinstance(word, dict) for word in timed_words
    ):
        raise QualificationError("candidate timed words must be an array of objects")
    text_word_count_matches = len(timed_words) == len(candidate_tokens)
    normalized_timed_words = [
        normalize_tokens(str(word.get("text", ""))) for word in timed_words
    ]
    one_token_per_word = all(len(tokens) == 1 for tokens in normalized_timed_words)
    text_word_content_matches = one_token_per_word and [
        tokens[0] for tokens in normalized_timed_words
    ] == candidate_tokens
    valid_timed = 0
    zero_duration = 0
    monotonic = True
    within_audio = True
    last_start = -1
    last_end = -1
    latest_end = 0
    candidate_word_timings: list[dict[str, int] | None] = []
    for word in timed_words:
        start = word.get("startMs")
        end = word.get("endMs")
        if type(start) is not int or type(end) is not int:
            candidate_word_timings.append(None)
            continue
        if start == end:
            zero_duration += 1
        in_bounds = 0 <= start < end <= duration_ms
        within_audio = within_audio and in_bounds
        monotonic = monotonic and start >= last_start and end >= last_end
        if in_bounds:
            valid_timed += 1
            latest_end = max(latest_end, end)
            candidate_word_timings.append({"startMs": start, "endMs": end})
        else:
            candidate_word_timings.append(None)
        last_start = start
        last_end = end

    timed_ratio = valid_timed / max(1, len(candidate_tokens))
    zero_duration_ratio = zero_duration / max(1, len(candidate_tokens))
    tail_lag_ms = max(0, last_speech_end_ms - latest_end)

    start_errors: list[int] = []
    end_errors: list[int] = []
    aligned_timing_matches = 0
    for reference_index, candidate_index in alignment.items():
        if candidate_index >= len(candidate_word_timings):
            continue
        candidate_timing = candidate_word_timings[candidate_index]
        if candidate_timing is None:
            continue
        reference_timing = reference_word_timings[reference_index]
        start_error = abs(candidate_timing["startMs"] - reference_timing["startMs"])
        end_error = abs(candidate_timing["endMs"] - reference_timing["endMs"])
        start_errors.append(start_error)
        end_errors.append(end_error)
        if (
            start_error <= timing["maximumWordStartErrorMs"]
            and end_error <= timing["maximumWordEndErrorMs"]
        ):
            aligned_timing_matches += 1
    maximum_start_error_ms = max(start_errors, default=duration_ms)
    maximum_end_error_ms = max(end_errors, default=duration_ms)
    aligned_word_timing_ratio = aligned_timing_matches / len(reference_tokens)

    def mapped_timing(reference_index: int) -> tuple[int, dict[str, int]] | None:
        candidate_index = alignment.get(reference_index)
        if candidate_index is None or candidate_index >= len(candidate_word_timings):
            return None
        candidate_timing = candidate_word_timings[candidate_index]
        if candidate_timing is None:
            return None
        return candidate_index, candidate_timing

    event_matches: list[bool] = []
    kind_matches: dict[str, list[bool]] = {
        "long-pause": [],
        "longform-boundary": [],
        "final-underfilled-window": [],
    }
    for event in events:
        kind = event["kind"]
        matched = False
        if kind in WORD_SPAN_EVENT_KINDS:
            start = event["startWordIndex"]
            end = event["endWordIndex"]
            mapped = [mapped_timing(index) for index in range(start, end + 1)]
            if all(item is not None for item in mapped):
                present = [item for item in mapped if item is not None]
                candidate_indices = [item[0] for item in present]
                matched = candidate_indices == list(
                    range(candidate_indices[0], candidate_indices[0] + len(candidate_indices))
                ) and all(
                    abs(item[1]["startMs"] - reference_word_timings[index]["startMs"])
                    <= timing["maximumWordStartErrorMs"]
                    and abs(item[1]["endMs"] - reference_word_timings[index]["endMs"])
                    <= timing["maximumWordEndErrorMs"]
                    for index, item in zip(range(start, end + 1), present)
                )
        elif kind == "long-pause":
            before = event["beforeWordIndex"]
            after = event["afterWordIndex"]
            mapped_before = mapped_timing(before)
            mapped_after = mapped_timing(after)
            if mapped_before is not None and mapped_after is not None:
                reference_gap = (
                    reference_word_timings[after]["startMs"]
                    - reference_word_timings[before]["endMs"]
                )
                candidate_gap = (
                    mapped_after[1]["startMs"] - mapped_before[1]["endMs"]
                )
                matched = (
                    mapped_after[0] == mapped_before[0] + 1
                    and abs(
                        mapped_before[1]["endMs"]
                        - reference_word_timings[before]["endMs"]
                    )
                    <= timing["maximumLongPauseBoundaryErrorMs"]
                    and abs(
                        mapped_after[1]["startMs"]
                        - reference_word_timings[after]["startMs"]
                    )
                    <= timing["maximumLongPauseBoundaryErrorMs"]
                    and abs(candidate_gap - reference_gap)
                    <= timing["maximumLongPauseDurationErrorMs"]
                )
        elif kind == "longform-boundary":
            before = event["beforeWordIndex"]
            after = event["afterWordIndex"]
            boundary = event["boundaryMs"]
            mapped_before = mapped_timing(before)
            mapped_after = mapped_timing(after)
            if mapped_before is not None and mapped_after is not None:
                error = timing["maximumLongformBoundaryErrorMs"]
                matched = (
                    mapped_after[0] == mapped_before[0] + 1
                    and abs(
                        mapped_before[1]["endMs"]
                        - reference_word_timings[before]["endMs"]
                    )
                    <= error
                    and abs(
                        mapped_after[1]["startMs"]
                        - reference_word_timings[after]["startMs"]
                    )
                    <= error
                    and mapped_before[1]["endMs"] <= boundary + error
                    and mapped_after[1]["startMs"] >= boundary - error
                )
        else:
            start = event["startWordIndex"]
            end = event["endWordIndex"]
            mapped = [mapped_timing(index) for index in range(start, end + 1)]
            if all(item is not None for item in mapped):
                present = [item for item in mapped if item is not None]
                candidate_indices = [item[0] for item in present]
                mapped_start = present[0]
                mapped_end = present[-1]
                error = timing["maximumFinalUnderfilledWindowErrorMs"]
                matched = (
                    candidate_indices
                    == list(
                        range(
                            candidate_indices[0],
                            candidate_indices[0] + len(candidate_indices),
                        )
                    )
                    and abs(
                        mapped_start[1]["startMs"]
                        - reference_word_timings[start]["startMs"]
                    )
                    <= error
                    and abs(
                        mapped_end[1]["endMs"]
                        - reference_word_timings[end]["endMs"]
                    )
                    <= error
                )
        event_matches.append(matched)
        if kind in kind_matches:
            kind_matches[kind].append(matched)

    event_recall = sum(event_matches) / len(event_matches) if event_matches else 0.0
    long_pause_timing_recall = _ratio(kind_matches["long-pause"])
    longform_boundary_timing_recall = _ratio(kind_matches["longform-boundary"])
    final_underfilled_window_timing_recall = _ratio(
        kind_matches["final-underfilled-window"]
    )

    quality = thresholds["quality"]
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
        Gate(
            "timing.text-word-count-match",
            "passed" if text_word_count_matches else "failed",
            text_word_count_matches,
            True,
        ),
        Gate(
            "timing.one-token-per-word",
            "passed" if one_token_per_word else "failed",
            one_token_per_word,
            True,
        ),
        Gate(
            "timing.text-word-content-match",
            "passed" if text_word_content_matches else "failed",
            text_word_content_matches,
            True,
        ),
        _gate_maximum("timing.zero-duration-word-ratio", zero_duration_ratio, timing["maximumZeroDurationWordRatio"]),
        _gate_maximum("timing.tail-lag-ms", tail_lag_ms, timing["maximumTailLagMs"]),
        _gate_maximum(
            "timing.maximum-word-start-error-ms",
            maximum_start_error_ms,
            timing["maximumWordStartErrorMs"],
        ),
        _gate_maximum(
            "timing.maximum-word-end-error-ms",
            maximum_end_error_ms,
            timing["maximumWordEndErrorMs"],
        ),
        _gate_minimum(
            "timing.aligned-word-timing-ratio",
            aligned_word_timing_ratio,
            timing["minimumAlignedWordTimingRatio"],
        ),
        _gate_minimum(
            "timing.long-pause-timing-recall",
            long_pause_timing_recall,
            timing["minimumLongPauseTimingRecall"],
        ),
        _gate_minimum(
            "timing.longform-boundary-timing-recall",
            longform_boundary_timing_recall,
            timing["minimumLongformBoundaryTimingRecall"],
        ),
        _gate_minimum(
            "timing.final-underfilled-window-timing-recall",
            final_underfilled_window_timing_recall,
            timing["minimumFinalUnderfilledWindowTimingRecall"],
        ),
        Gate("timing.monotonic", "passed" if monotonic else "failed", monotonic, True),
        Gate("timing.within-audio", "passed" if within_audio else "failed", within_audio, True),
    ]
    measurements = {
        "audioDurationMs": duration_ms,
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
        "textWordCountMatches": text_word_count_matches,
        "oneTokenPerTimedWord": one_token_per_word,
        "textWordContentMatches": text_word_content_matches,
        "zeroDurationWordRatio": zero_duration_ratio,
        "monotonicWordTimes": monotonic,
        "wordsWithinAudio": within_audio,
        "tailLagMs": tail_lag_ms,
        "maximumWordStartErrorMs": maximum_start_error_ms,
        "maximumWordEndErrorMs": maximum_end_error_ms,
        "alignedWordTimingRatio": aligned_word_timing_ratio,
        "longPauseTimingRecall": long_pause_timing_recall,
        "longformBoundaryTimingRecall": longform_boundary_timing_recall,
        "finalUnderfilledWindowTimingRecall": final_underfilled_window_timing_recall,
    }
    return {
        "status": "passed" if all(gate.status == "passed" for gate in gates) else "failed",
        "measurements": measurements,
        "gates": [gate.as_json() for gate in gates],
    }


def _public_source_provenance(plan_fixture: dict[str, Any]) -> dict[str, Any]:
    return {
        "sourceId": plan_fixture["sourceId"],
        "startMs": plan_fixture["startMs"],
        "durationMs": plan_fixture["durationMs"],
        "candidateAudioSha256": plan_fixture["candidateAudioSha256"],
    }


def _validate_public_source_plan(
    source_plan: dict[str, Any],
    manifest: dict[str, Any],
) -> None:
    plan_id = source_plan.get("planId")
    if (
        source_plan.get("schemaVersion") != 1
        or not isinstance(plan_id, str)
        or len(plan_id) > 128
        or SAFE_SOURCE_IDENTIFIER_PATTERN.fullmatch(plan_id) is None
        or source_plan.get("qualificationProfileId") != EXPECTED_PROFILE_ID
    ):
        raise QualificationError("public source plan identity is invalid")
    if manifest.get("publicSourcePlan") != {
        "planId": plan_id,
        "sha256": canonical_json_sha256(source_plan),
    }:
        raise QualificationError("corpus public source plan binding is invalid")

    sources = source_plan.get("sources")
    plan_fixtures = source_plan.get("fixtures")
    manifest_fixtures = manifest.get("fixtures")
    if not isinstance(sources, dict) or not isinstance(plan_fixtures, list):
        raise QualificationError("public source plan shape is invalid")
    if not isinstance(manifest_fixtures, list):
        raise QualificationError("corpus fixture shape is invalid")
    for source_id, source in sources.items():
        if (
            not isinstance(source_id, str)
            or SAFE_SOURCE_IDENTIFIER_PATTERN.fullmatch(source_id) is None
            or not isinstance(source, dict)
            or source.get("mediaKind") not in {"pcm-wav", "mp3"}
            or not isinstance(source.get("mediaUrl"), str)
            or not source["mediaUrl"].startswith("https://")
            or not isinstance(source.get("fileName"), str)
            or type(source.get("sizeBytes")) is not int
            or source["sizeBytes"] <= 0
            or not isinstance(source.get("sha256"), str)
            or SHA256_PATTERN.fullmatch(source["sha256"]) is None
        ):
            raise QualificationError("public source record is invalid")

    if (
        len(plan_fixtures) != len(EXPECTED_FIXTURES)
        or not all(isinstance(fixture, dict) for fixture in plan_fixtures)
    ):
        raise QualificationError("public source fixtures are invalid")
    plan_ids = [fixture.get("id") for fixture in plan_fixtures]
    if (
        not all(isinstance(fixture_id, str) for fixture_id in plan_ids)
        or len(set(plan_ids)) != len(plan_ids)
        or set(plan_ids) != EXPECTED_FIXTURES
    ):
        raise QualificationError("public source fixture identities are invalid")
    manifest_by_id = {
        fixture.get("id"): fixture
        for fixture in manifest_fixtures
        if isinstance(fixture, dict)
    }
    output_paths: set[str] = set()
    for plan_fixture in plan_fixtures:
        fixture_id = plan_fixture["id"]
        source_id = plan_fixture.get("sourceId")
        start_ms = plan_fixture.get("startMs")
        duration_ms = plan_fixture.get("durationMs")
        output_path = plan_fixture.get("outputPath")
        candidate_hash = plan_fixture.get("candidateAudioSha256")
        if (
            not isinstance(source_id, str)
            or SAFE_SOURCE_IDENTIFIER_PATTERN.fullmatch(source_id) is None
            or source_id not in sources
            or type(start_ms) is not int
            or start_ms < 0
            or type(duration_ms) is not int
            or duration_ms <= 0
            or not isinstance(output_path, str)
            or "\\" in output_path
            or "candidateAudioSha256" not in plan_fixture
            or (
                candidate_hash is not None
                and (
                    not isinstance(candidate_hash, str)
                    or SHA256_PATTERN.fullmatch(candidate_hash) is None
                )
            )
        ):
            raise QualificationError("public source fixture is invalid")
        relative_output = PurePosixPath(output_path)
        if (
            relative_output.is_absolute()
            or len(relative_output.parts) < 2
            or relative_output.parts[0] != "audio"
            or any(part in {"", ".", ".."} for part in relative_output.parts)
            or relative_output.suffix != ".wav"
            or output_path in output_paths
        ):
            raise QualificationError("public source fixture path is invalid")
        output_paths.add(output_path)

        manifest_fixture = manifest_by_id.get(fixture_id)
        if (
            manifest_fixture is None
            or manifest_fixture.get("audioPath") != output_path
            or manifest_fixture.get("audioSha256") != candidate_hash
            or manifest_fixture.get("sourceProvenance")
            != _public_source_provenance(plan_fixture)
            or not (
                manifest_fixture.get("durationRangeMs", [1, 0])[0]
                <= duration_ms
                <= manifest_fixture.get("durationRangeMs", [1, 0])[1]
            )
        ):
            raise QualificationError("corpus fixture provenance is invalid")


def validate_locked_configuration(
    lock: dict[str, Any],
    manifest: dict[str, Any],
    source_plan: dict[str, Any] | None = None,
) -> None:
    source_plan = source_plan if source_plan is not None else load_json(PUBLIC_SOURCE_PLAN)
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
    timing_thresholds = manifest.get("thresholds", {}).get("timing", {})
    if timing_thresholds.get("longformBoundaryIntervalMs") != round(
        lock["decoding"]["strideSeconds"] * 1000
    ):
        raise QualificationError("longform boundary interval does not match decoding")
    if timing_thresholds.get("finalWindowSizeMs") != round(
        lock["decoding"]["chunkDurationSeconds"] * 1000
    ):
        raise QualificationError("final window size does not match decoding")
    fixtures = manifest.get("fixtures")
    if (
        type(fixtures) is not list
        or len(fixtures) != len(EXPECTED_FIXTURES)
        or not all(isinstance(fixture, dict) for fixture in fixtures)
    ):
        raise QualificationError("corpus must contain exactly the four required fixtures")
    fixture_ids = [fixture.get("id") for fixture in fixtures]
    if (
        not all(isinstance(fixture_id, str) for fixture_id in fixture_ids)
        or len(set(fixture_ids)) != len(fixture_ids)
        or set(fixture_ids) != EXPECTED_FIXTURES
    ):
        raise QualificationError("corpus fixture identities must be unique")

    observed_paths: set[str] = set()
    for fixture in fixtures:
        if set(fixture) != FIXTURE_FIELDS:
            raise QualificationError("corpus fixture record shape is invalid")
        duration_range = fixture["durationRangeMs"]
        if (
            type(duration_range) is not list
            or len(duration_range) != 2
            or not all(type(value) is int and value > 0 for value in duration_range)
            or duration_range[0] > duration_range[1]
        ):
            raise QualificationError("corpus fixture duration range is invalid")
        required_phenomena = fixture["requiredPhenomena"]
        if (
            type(required_phenomena) is not list
            or not required_phenomena
            or not all(isinstance(value, str) for value in required_phenomena)
            or len(set(required_phenomena)) != len(required_phenomena)
            or not set(required_phenomena).issubset(SUPPORTED_PHENOMENA)
        ):
            raise QualificationError("corpus fixture phenomena are invalid")
        expected_duration_range, expected_phenomena = EXPECTED_FIXTURE_SPECS[
            fixture["id"]
        ]
        if tuple(duration_range) != expected_duration_range:
            raise QualificationError("corpus fixture duration class changed")
        if frozenset(required_phenomena) != expected_phenomena:
            raise QualificationError("corpus fixture required phenomena changed")
        asset_status = fixture["assetStatus"]
        if not isinstance(asset_status, str) or asset_status not in {
            "ready",
            "awaiting-capture-and-hand-label",
            "awaiting-acoustic-and-reference-review",
        }:
            raise QualificationError("corpus fixture asset status is invalid")
        for hash_key in ("audioSha256", "referenceSha256"):
            digest = fixture[hash_key]
            if digest is not None and (
                not isinstance(digest, str) or SHA256_PATTERN.fullmatch(digest) is None
            ):
                raise QualificationError("corpus fixture hash is invalid")
        if asset_status == "ready" and (
            fixture["audioSha256"] is None or fixture["referenceSha256"] is None
        ):
            raise QualificationError("ready corpus fixture hashes must be pinned")
        for key in ("audioPath", "referencePath"):
            raw_path = fixture.get(key)
            if (
                not isinstance(raw_path, str)
                or SAFE_FIXTURE_PATH_PATTERN.fullmatch(raw_path) is None
                or "\\" in raw_path
            ):
                raise QualificationError("corpus fixture path is invalid")
            path = PurePosixPath(raw_path)
            expected_parent = "audio" if key == "audioPath" else "reference"
            if (
                path.is_absolute()
                or raw_path != path.as_posix()
                or not path.parts
                or path.parts[0] != expected_parent
                or any(part in {"", ".", ".."} for part in path.parts)
                or raw_path in observed_paths
            ):
                raise QualificationError("corpus fixture paths must be safe and distinct")
            observed_paths.add(raw_path)
        if "final-underfilled-window" in required_phenomena:
            final_window_size = timing_thresholds["finalWindowSizeMs"]
            stride = timing_thresholds["longformBoundaryIntervalMs"]
            first_full = _first_full_final_window_duration_ms(
                duration_range[0],
                final_window_size,
                stride,
            )
            if first_full <= duration_range[1]:
                raise QualificationError(
                    "final-window fixture duration range includes a full window"
                )
    _validate_public_source_plan(source_plan, manifest)


def _runtime_preflight(lock: dict[str, Any]) -> list[Gate]:
    gates: list[Gate] = []
    package_lock = ROOT / lock["runtime"]["packageLock"]
    expected_lock_hash = lock["runtime"]["packageLockSha256"]
    actual_lock_hash = sha256_file(package_lock) if package_lock.is_file() else None
    gates.append(Gate("runtime.package-lock", "passed" if actual_lock_hash == expected_lock_hash else "blocked", actual_lock_hash, expected_lock_hash, None if actual_lock_hash == expected_lock_hash else "PACKAGE_LOCK_MISSING_OR_DRIFTED"))
    expected_python = lock["runtime"]["pythonVersion"]
    actual_python = platform.python_version()
    gates.append(Gate("runtime.python-version", "passed" if actual_python == expected_python else "blocked", actual_python, expected_python, None if actual_python == expected_python else "RUNTIME_VERSION_MISMATCH"))
    for package, expected in EXPECTED_PACKAGE_VERSIONS.items():
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


def _active_inference_proof_reason(lock: dict[str, Any]) -> str | None:
    """Require a pinned patch capable of signaling from inside model inference."""
    patch_id = lock.get("engine", {}).get("audoraCompatibilityPatchId")
    if (
        not isinstance(patch_id, str)
        or SAFE_PATCH_ID_PATTERN.fullmatch(patch_id) is None
    ):
        return "ACTIVE_INFERENCE_PROOF_UNAVAILABLE"
    return None


def _reference_labels_reason(
    reference: dict[str, Any],
    fixture: dict[str, Any],
    boundary_words: int,
    timing_thresholds: dict[str, Any],
) -> str | None:
    try:
        reference_tokens = _strict_reference_tokens(reference)
        reference_timings = _validated_reference_word_timings(
            reference,
            len(reference_tokens),
            reference["durationMs"],
            reference["lastSpeechEndMs"],
        )
    except (KeyError, QualificationError):
        return "REFERENCE_WORD_TIMINGS_INVALID"
    beginning_anchors = reference.get("beginningAnchors")
    tail_anchors = reference.get("tailAnchors")
    for anchors in (beginning_anchors, tail_anchors):
        if (
            not isinstance(anchors, list)
            or not anchors
            or not all(
                isinstance(anchor, list)
                and anchor
                and all(isinstance(word, str) for word in anchor)
                and all(len(normalize_tokens(word)) == 1 for word in anchor)
                for anchor in anchors
            )
        ):
            return "REFERENCE_ANCHORS_INVALID"
    if anchor_coverage(
        reference_tokens,
        beginning_anchors,
        position="beginning",
        boundary_words=boundary_words,
    ) != 1.0 or anchor_coverage(
        reference_tokens,
        tail_anchors,
        position="tail",
        boundary_words=boundary_words,
    ) != 1.0:
        return "REFERENCE_ANCHORS_INVALID"

    phenomena = reference.get("phenomena")
    if (
        not isinstance(phenomena, list)
        or not all(isinstance(item, str) for item in phenomena)
        or len(set(phenomena)) != len(phenomena)
    ):
        return "REFERENCE_PHENOMENA_INVALID"
    declared = set(phenomena)
    raw_events = reference.get("verbatimEvents")
    try:
        events = _validated_reference_events(
            reference,
            reference_tokens,
            reference_timings,
            timing_thresholds,
            reference["durationMs"],
        )
    except (KeyError, QualificationError):
        return "REFERENCE_EVENT_INVALID"
    if not isinstance(raw_events, list):
        return "REFERENCE_EVENT_INVALID"
    event_kinds = {event["kind"] for event in events}
    if not event_kinds.issubset(declared):
        return "REFERENCE_EVENT_INVALID"
    if not declared.issubset(SUPPORTED_PHENOMENA):
        return "REFERENCE_PHENOMENA_INVALID"

    required = set(fixture["requiredPhenomena"])
    if not required.issubset(declared):
        return "REFERENCE_PHENOMENA_INCOMPLETE"
    required_event_kinds = (required | (declared - ANCHOR_PHENOMENA)) - ANCHOR_PHENOMENA
    if not required_event_kinds.issubset(event_kinds):
        return "REFERENCE_PHENOMENA_INCOMPLETE"
    return None


def _reference_preflight(
    reference: dict[str, Any],
    fixture: dict[str, Any],
    *,
    audio_duration_ms: int | None,
    anchor_boundary_words: int,
    timing_thresholds: dict[str, Any],
) -> str | None:
    if reference.get("schemaVersion") != 1 or reference.get("fixtureId") != fixture["id"]:
        return "REFERENCE_IDENTITY_INVALID"
    try:
        reference_tokens = _strict_reference_tokens(reference)
    except QualificationError:
        return "REFERENCE_WORDS_INVALID"
    duration = reference.get("durationMs")
    last_speech = reference.get("lastSpeechEndMs")
    if (
        type(duration) is not int
        or type(last_speech) is not int
        or not 0 < last_speech <= duration
    ):
        return "REFERENCE_TIMELINE_INVALID"
    if audio_duration_ms is not None and duration != audio_duration_ms:
        return "REFERENCE_AUDIO_DURATION_MISMATCH"
    try:
        _validated_reference_word_timings(
            reference,
            len(reference_tokens),
            duration,
            last_speech,
        )
    except QualificationError:
        return "REFERENCE_WORD_TIMINGS_INVALID"
    return _reference_labels_reason(
        reference,
        fixture,
        anchor_boundary_words,
        timing_thresholds,
    )


def _fixture_preflight(manifest: dict[str, Any], fixtures_dir: Path) -> tuple[list[Gate], dict[str, list[str]]]:
    gates: list[Gate] = []
    reasons_by_fixture: dict[str, list[str]] = {}
    audio_format = manifest["audioFormat"]
    for fixture in manifest["fixtures"]:
        fixture_id = fixture["id"]
        reasons: list[str] = []
        prefix = f"fixture.{fixture_id}"
        asset_ready = fixture.get("assetStatus") == "ready"
        gates.append(
            Gate(
                f"{prefix}.asset-status",
                "passed" if asset_ready else "blocked",
                fixture.get("assetStatus"),
                "ready",
                None if asset_ready else "CORPUS_ASSET_NOT_READY",
            )
        )
        if not asset_ready:
            reasons.append("CORPUS_ASSET_NOT_READY")

        audio_path = fixtures_dir / fixture["audioPath"]
        reference_path = fixtures_dir / fixture["referencePath"]
        audio_duration_ms: int | None = None
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
                    duration_ms = canonical_audio_duration_ms(frames, rate)
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
            if format_ok:
                audio_duration_ms = duration_ms

        if reference_path.is_file():
            try:
                reference = load_json(reference_path)
                reference_reason = _reference_preflight(
                    reference,
                    fixture,
                    audio_duration_ms=audio_duration_ms,
                    anchor_boundary_words=manifest["thresholds"]["quality"][
                        "anchorBoundaryWindowWords"
                    ],
                    timing_thresholds=manifest["thresholds"]["timing"],
                )
            except (OSError, json.JSONDecodeError, QualificationError):
                reference_reason = "REFERENCE_INVALID"
            if reference_reason:
                reasons.append(reference_reason)
            gates.append(Gate(f"{prefix}.reference-shape", "passed" if reference_reason is None else "blocked", threshold="valid hand label", reason=reference_reason))

        reasons_by_fixture[fixture_id] = sorted(set(reasons))
    return gates, reasons_by_fixture


def _public_source_preflight(
    manifest: dict[str, Any],
) -> tuple[list[Gate], dict[str, list[str]]]:
    gates: list[Gate] = []
    reasons: dict[str, list[str]] = {}
    for fixture in manifest["fixtures"]:
        fixture_id = fixture["id"]
        candidate_hash = fixture["sourceProvenance"]["candidateAudioSha256"]
        pinned = (
            isinstance(candidate_hash, str)
            and SHA256_PATTERN.fullmatch(candidate_hash) is not None
        )
        reason = None if pinned else "DERIVED_AUDIO_HASH_NOT_PINNED"
        gates.append(
            Gate(
                f"fixture.{fixture_id}.public-derived-audio-hash",
                "passed" if pinned else "blocked",
                candidate_hash,
                "sha256",
                reason,
            )
        )
        reasons[fixture_id] = [] if reason is None else [reason]
    return gates, reasons


def preflight(
    lock: dict[str, Any],
    manifest: dict[str, Any],
    fixtures_dir: Path,
    model_dir: Path | None,
    *,
    source_plan: dict[str, Any] | None = None,
) -> tuple[list[Gate], dict[str, list[str]]]:
    source_plan_snapshot = json.loads(
        json.dumps(
            source_plan if source_plan is not None else load_json(PUBLIC_SOURCE_PLAN)
        )
    )
    validate_locked_configuration(lock, manifest, source_plan_snapshot)
    gates = _runtime_preflight(lock)
    gates.extend(_model_preflight(lock, model_dir))
    active_proof_reason = _active_inference_proof_reason(lock)
    gates.append(
        Gate(
            "cancellation.active-inference-proof",
            "passed" if active_proof_reason is None else "blocked",
            active_proof_reason is None,
            True,
            active_proof_reason,
        )
    )
    source_gates, source_reasons = _public_source_preflight(manifest)
    gates.extend(source_gates)
    fixture_gates, reasons = _fixture_preflight(manifest, fixtures_dir)
    gates.extend(fixture_gates)
    for fixture_id, source_fixture_reasons in source_reasons.items():
        reasons[fixture_id] = sorted(
            set(reasons[fixture_id] + source_fixture_reasons)
        )
    global_reasons = sorted(
        {
            gate.reason
            for gate in gates
            if gate.status != "passed"
            and gate.reason
            and not gate.gate.startswith(("fixture.", "cancellation."))
        }
    )
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
        self.lock = load_json(lock_path)
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
            text=False,
            bufsize=0,
        )
        self._stdout_buffer = bytearray()
        self.peak_resident_bytes: int | None = None
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
                measured = int(completed.stdout.strip()) * 1024
                if completed.returncode == 0 and measured > 0:
                    self.peak_resident_bytes = max(
                        self.peak_resident_bytes or measured,
                        measured,
                    )
            except ValueError:
                pass

    def _read_json(self, timeout: float) -> dict[str, Any]:
        if self.process.stdout is None:
            raise QualificationError("worker stdout unavailable")
        deadline = time.monotonic() + max(0.0, timeout)
        while b"\n" not in self._stdout_buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise QualificationError("worker response timed out")
            selector = selectors.DefaultSelector()
            try:
                selector.register(self.process.stdout, selectors.EVENT_READ)
                events = selector.select(remaining)
            finally:
                selector.close()
            if not events:
                raise QualificationError("worker response timed out")
            chunk = os.read(self.process.stdout.fileno(), 64 * 1024)
            if not chunk:
                raise QualificationError("worker exited before a complete response")
            self._stdout_buffer.extend(chunk)
            if len(self._stdout_buffer) > MAX_WORKER_PROTOCOL_LINE_BYTES:
                raise QualificationError("worker response exceeded the protocol limit")
        encoded, _, remainder = self._stdout_buffer.partition(b"\n")
        self._stdout_buffer = bytearray(remainder)
        try:
            line = encoded.decode("utf-8")
            value = json.loads(line)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise QualificationError("worker emitted malformed protocol JSON") from error
        if not isinstance(value, dict):
            raise QualificationError("worker response must be an object")
        if value.get("type") == "failed":
            raise QualificationError(f"worker failed: {value.get('code', 'UNKNOWN')}")
        return value

    def hello(self, timeout: float = 180) -> dict[str, Any]:
        message = self._read_json(timeout)
        expected_fields = {
            "type",
            "qualificationProfileId",
            "engineLockSha256",
            "modelLoadSeconds",
            "packageVersions",
            "networkProbe",
        }
        network_probe = message.get("networkProbe")
        if (
            set(message) != expected_fields
            or message.get("type") != "hello"
            or message.get("qualificationProfileId")
            != self.lock.get("qualificationProfileId")
            or message.get("engineLockSha256") != canonical_json_sha256(self.lock)
            or message.get("packageVersions") != EXPECTED_PACKAGE_VERSIONS
            or not _is_number(message.get("modelLoadSeconds"))
            or message["modelLoadSeconds"] < 0
            or network_probe not in {"denied", "not-denied"}
            or (self.network_guarded and network_probe != "denied")
        ):
            raise QualificationError("worker hello does not match the pinned identity")
        return message

    def send_transcribe(self, fixture_id: str, audio_path: Path, timeout: float) -> dict[str, Any]:
        if not _is_number(timeout) or timeout <= 0:
            raise QualificationError("transcription timeout must be positive")
        deadline = time.monotonic() + timeout

        def remaining() -> float:
            value = deadline - time.monotonic()
            if value <= 0:
                raise QualificationError("worker response timed out")
            return value

        self.begin_transcribe(fixture_id, audio_path)
        self.await_transcription_started(fixture_id, remaining())
        message = self._read_json(remaining())
        if message.get("type") != "result" or message.get("fixtureId") != fixture_id:
            raise QualificationError("worker returned the wrong result identity")
        return message

    def begin_transcribe(self, fixture_id: str, audio_path: Path) -> None:
        if self.process.stdin is None:
            raise QualificationError("worker stdin unavailable")
        request = {"type": "transcribe", "fixtureId": fixture_id, "audioPath": str(audio_path)}
        self.process.stdin.write(
            (json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8")
        )
        self.process.stdin.flush()

    def await_transcription_started(
        self,
        fixture_id: str,
        timeout: float,
        *,
        require_active_proof: bool = False,
    ) -> None:
        message = self._read_json(timeout)
        if (
            message.get("type") != "transcription-started"
            or message.get("fixtureId") != fixture_id
            or (
                require_active_proof
                and message.get("proof") != "compatibility-patch-callback"
            )
        ):
            raise QualificationError("worker did not acknowledge active transcription")

    def require_transcription_active_for(self, fixture_id: str, duration: float) -> None:
        if self.process.stdout is None or self.process.poll() is not None:
            raise QualificationError("transcription ended before cancellation")
        if self._stdout_buffer:
            raise QualificationError(
                f"transcription {fixture_id} ended before cancellation"
            )
        selector = selectors.DefaultSelector()
        selector.register(self.process.stdout, selectors.EVENT_READ)
        events = selector.select(duration)
        selector.close()
        if events or self.process.poll() is not None:
            raise QualificationError(
                f"transcription {fixture_id} ended before cancellation"
            )

    def close(self) -> None:
        self._monitor_stop.set()
        try:
            if self.process.poll() is not None:
                self.process.wait(timeout=0)
                return
            try:
                if self.process.stdin is not None:
                    self.process.stdin.write(b'{"type":"shutdown"}\n')
                    self.process.stdin.flush()
                self.process.wait(timeout=10)
                return
            except (BrokenPipeError, OSError, subprocess.TimeoutExpired):
                pass
            try:
                self.process.terminate()
            except ProcessLookupError:
                pass
            try:
                self.process.wait(timeout=2)
                return
            except subprocess.TimeoutExpired:
                pass
            try:
                self.process.kill()
            except ProcessLookupError:
                pass
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired as error:
                raise QualificationError("worker could not be reaped") from error
        finally:
            self._monitor.join(timeout=2)
            for stream in (self.process.stdin, self.process.stdout):
                if stream is not None:
                    try:
                        stream.close()
                    except OSError:
                        pass

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
    peak_resident_bytes: int | None,
    maximum_thermal_state: str | None,
    thermal_recovery_seconds: float | None,
) -> tuple[dict[str, Any], list[Gate]]:
    thresholds = manifest["thresholds"]["runtime"]
    cold_rtf = (float(hello["modelLoadSeconds"]) + float(first["elapsedSeconds"])) / duration_seconds
    warm_rtf = float(warm["elapsedSeconds"]) / duration_seconds
    def observed_peak(*values: Any) -> int | None:
        observed = [value for value in values if type(value) is int and value > 0]
        return max(observed) if observed else None

    peak_resident = observed_peak(
        peak_resident_bytes,
        first.get("peakResidentBytes"),
        warm.get("peakResidentBytes"),
    )
    peak_mps = observed_peak(
        first.get("peakMpsDriverAllocatedBytes"),
        warm.get("peakMpsDriverAllocatedBytes"),
    )
    gates = [
        _gate_maximum("runtime.cold-real-time-factor", cold_rtf, thresholds["maximumColdRealTimeFactor"]),
        _gate_maximum("runtime.warm-real-time-factor", warm_rtf, thresholds["maximumWarmRealTimeFactor"]),
    ]
    if peak_resident is None:
        gates.append(Gate("runtime.peak-resident-bytes", "failed", threshold=thresholds["maximumPeakResidentBytes"], reason="RSS_MEASUREMENT_UNAVAILABLE"))
    else:
        gates.append(_gate_maximum("runtime.peak-resident-bytes", peak_resident, thresholds["maximumPeakResidentBytes"]))
    if peak_mps is None:
        gates.append(Gate("runtime.peak-mps-driver-allocated-bytes", "failed", threshold=thresholds["maximumPeakMpsDriverAllocatedBytes"], reason="MPS_MEASUREMENT_UNAVAILABLE"))
    else:
        gates.append(_gate_maximum("runtime.peak-mps-driver-allocated-bytes", peak_mps, thresholds["maximumPeakMpsDriverAllocatedBytes"]))
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
        "peakResidentBytes": peak_resident,
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
    *,
    lock_path: Path = ENGINE_LOCK,
    reference_snapshot: dict[str, Any] | None = None,
) -> dict[str, Any]:
    audio_path = fixtures_dir / fixture["audioPath"]
    reference = (
        reference_snapshot
        if reference_snapshot is not None
        else load_json(fixtures_dir / fixture["referencePath"])
    )
    audio_duration_ms = _validated_wave_duration_ms(
        audio_path,
        manifest["audioFormat"],
    )
    if reference.get("durationMs") != audio_duration_ms:
        raise QualificationError("reference duration does not match audio duration")
    duration_seconds = audio_duration_ms / 1000
    thermal = ThermalSampler(workspace / "thermal")
    thermal.prepare()
    thermal.start()
    session: WorkerSession | None = None
    try:
        session = WorkerSession(model_dir, lock_path, workspace / "worker")
        hello = session.hello()
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

    quality = evaluate_transcript(
        reference,
        first,
        manifest["thresholds"],
        audio_duration_ms=audio_duration_ms,
    )
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
    *,
    lock_path: Path = ENGINE_LOCK,
) -> dict[str, Any]:
    thresholds = manifest["thresholds"]["cancellation"]
    active_proof_reason = _active_inference_proof_reason(load_json(lock_path))
    if active_proof_reason is not None:
        gates = [
            Gate(
                "cancellation.transcription-active",
                "failed",
                False,
                True,
                active_proof_reason,
            ),
            _gate_maximum(
                "cancellation.termination-seconds",
                0.0,
                thresholds["maximumTerminationSeconds"],
            ),
            Gate(
                "cancellation.no-forced-kill",
                "passed",
                True,
                thresholds["mustExitWithoutForcedKill"],
            ),
            Gate(
                "cancellation.worker-reaped",
                "failed",
                False,
                True,
                "CANCELLATION_NOT_RUN",
            ),
        ]
        return {
            "status": "failed",
            "modelLoadSeconds": 0.0,
            "activeInferenceAcknowledged": False,
            "terminationSeconds": 0.0,
            "forcedKill": False,
            "workerReaped": False,
            "gates": [gate.as_json() for gate in gates],
        }
    session: WorkerSession | None = None
    try:
        session = WorkerSession(model_dir, lock_path, workspace)
        hello = session.hello()
        session.begin_transcribe(fixture["id"], fixtures_dir / fixture["audioPath"])
        session.await_transcription_started(
            fixture["id"],
            thresholds["maximumTerminationSeconds"],
            require_active_proof=True,
        )
        session.require_transcription_active_for(
            fixture["id"],
            thresholds["cancelAfterSeconds"],
        )
        elapsed, forced_kill = session.terminate_for_cancellation(thresholds["maximumTerminationSeconds"])
    finally:
        if session is not None:
            session.close()
    if session is None:
        raise QualificationError("cancellation worker did not start")
    worker_reaped = session.process.poll() is not None
    gates = [
        Gate("cancellation.transcription-active", "passed", True, True),
        _gate_maximum("cancellation.termination-seconds", elapsed, thresholds["maximumTerminationSeconds"]),
        Gate("cancellation.no-forced-kill", "passed" if not forced_kill else "failed", not forced_kill, thresholds["mustExitWithoutForcedKill"]),
        Gate("cancellation.worker-reaped", "passed" if worker_reaped else "failed", worker_reaped, True),
    ]
    return {
        "status": "passed" if all(gate.status == "passed" for gate in gates) else "failed",
        "modelLoadSeconds": hello["modelLoadSeconds"],
        "activeInferenceAcknowledged": True,
        "terminationSeconds": elapsed,
        "forcedKill": forced_kill,
        "workerReaped": worker_reaped,
        "gates": [gate.as_json() for gate in gates],
    }


def run_cached_offline(
    fixture: dict[str, Any],
    fixtures_dir: Path,
    model_dir: Path,
    workspace: Path,
    *,
    lock_path: Path = ENGINE_LOCK,
) -> dict[str, Any]:
    session: WorkerSession | None = None
    try:
        session = WorkerSession(model_dir, lock_path, workspace, prove_offline=True)
        hello = session.hello()
        with wave.open(str(fixtures_dir / fixture["audioPath"]), "rb") as audio:
            duration_seconds = canonical_audio_duration_ms(
                audio.getnframes(),
                audio.getframerate(),
            ) / 1000
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


def blocked_report(
    lock: dict[str, Any],
    manifest: dict[str, Any],
    gates: list[Gate],
    reasons: dict[str, list[str]],
    *,
    source_plan: dict[str, Any] | None = None,
) -> dict[str, Any]:
    source_plan_snapshot = json.loads(
        json.dumps(
            source_plan if source_plan is not None else load_json(PUBLIC_SOURCE_PLAN)
        )
    )
    validate_locked_configuration(lock, manifest, source_plan_snapshot)
    cases = [
        {
            "id": fixture["id"],
            "status": "blocked",
            "reasonCodes": reasons[fixture["id"]],
            "sourceProvenance": json.loads(
                json.dumps(fixture["sourceProvenance"])
            ),
        }
        for fixture in manifest["fixtures"]
    ]
    cancellation_reasons = sorted(
        set(reasons["forty-five-minute"])
        | {
            gate.reason
            for gate in gates
            if gate.status != "passed"
            and gate.reason
            and gate.gate.startswith("cancellation.")
        }
    )
    return {
        "schemaVersion": 1,
        "reportKind": "preflight-only",
        "recordedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "qualificationProfileId": lock["qualificationProfileId"],
        "engineLockSha256": canonical_json_sha256(lock),
        "corpusManifestSha256": canonical_json_sha256(manifest),
        "publicSourcePlanId": source_plan_snapshot["planId"],
        "publicSourcePlanSha256": canonical_json_sha256(source_plan_snapshot),
        "environment": {
            "operatingSystem": platform.system(),
            "operatingSystemRelease": platform.release(),
            "machine": platform.machine(),
            "pythonVersion": platform.python_version(),
        },
        "qualificationStatus": "blocked",
        "preflight": [gate.as_json() for gate in gates],
        "fixtures": cases,
        "cancellation": {"status": "blocked", "reasonCodes": cancellation_reasons},
        "cachedOffline": {"status": "blocked", "reasonCodes": reasons["short"]},
        "engineSelectionChanged": False,
    }


class QualificationExecutor(Protocol):
    """External inference operations consumed by the qualification aggregator."""

    def run_fixture(
        self,
        fixture: dict[str, Any],
        manifest: dict[str, Any],
        fixtures_dir: Path,
        model_dir: Path,
        workspace: Path,
    ) -> dict[str, Any]: ...

    def run_cancellation(
        self,
        fixture: dict[str, Any],
        manifest: dict[str, Any],
        fixtures_dir: Path,
        model_dir: Path,
        workspace: Path,
    ) -> dict[str, Any]: ...

    def run_cached_offline(
        self,
        fixture: dict[str, Any],
        fixtures_dir: Path,
        model_dir: Path,
        workspace: Path,
    ) -> dict[str, Any]: ...


class LocalQualificationExecutor:
    """Production adapter for the pinned local Crisper worker."""

    def __init__(self, lock: dict[str, Any]) -> None:
        self._lock = json.loads(json.dumps(lock))
        self._lock_sha256 = canonical_json_sha256(self._lock)

    def _stage_lock(self, workspace: Path) -> Path:
        workspace.mkdir(mode=0o700, parents=True, exist_ok=True)
        workspace.chmod(0o700)
        destination = workspace / "engine-lock.snapshot.json"
        try:
            with destination.open("x", encoding="utf-8") as stream:
                json.dump(self._lock, stream, indent=2, sort_keys=True)
                stream.write("\n")
        except FileExistsError as error:
            raise QualificationError("execution workspace is not fresh") from error
        destination.chmod(0o600)
        if canonical_json_sha256(load_json(destination)) != self._lock_sha256:
            raise QualificationError("engine lock snapshot changed")
        return destination

    def _stage_audio(
        self,
        fixture: dict[str, Any],
        fixtures_dir: Path,
        workspace: Path,
    ) -> Path:
        staged_fixtures_dir = workspace / "verified-fixtures"
        expected_hash = fixture.get("audioSha256")
        if (
            not isinstance(expected_hash, str)
            or SHA256_PATTERN.fullmatch(expected_hash) is None
        ):
            raise QualificationError("fixture asset hash is not pinned")
        source = fixtures_dir / fixture["audioPath"]
        destination = staged_fixtures_dir / fixture["audioPath"]
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        staged_fixtures_dir.chmod(0o700)
        destination.parent.chmod(0o700)
        try:
            shutil.copyfile(source, destination)
            destination.chmod(0o600)
            if sha256_file(destination) != expected_hash:
                raise QualificationError("fixture asset changed after preflight")
        except OSError as error:
            destination.unlink(missing_ok=True)
            raise QualificationError("fixture asset changed after preflight") from error
        except QualificationError:
            destination.unlink(missing_ok=True)
            raise
        return staged_fixtures_dir

    def _verified_reference_snapshot(
        self,
        fixture: dict[str, Any],
        fixtures_dir: Path,
    ) -> dict[str, Any]:
        expected_hash = fixture.get("referenceSha256")
        if (
            not isinstance(expected_hash, str)
            or SHA256_PATTERN.fullmatch(expected_hash) is None
        ):
            raise QualificationError("fixture asset hash is not pinned")
        try:
            encoded = (fixtures_dir / fixture["referencePath"]).read_bytes()
        except OSError as error:
            raise QualificationError("fixture asset changed after preflight") from error
        if hashlib.sha256(encoded).hexdigest() != expected_hash:
            raise QualificationError("fixture asset changed after preflight")
        try:
            reference = json.loads(encoded)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise QualificationError("fixture reference is invalid") from error
        if not isinstance(reference, dict):
            raise QualificationError("fixture reference is invalid")
        return reference

    def run_fixture(
        self,
        fixture: dict[str, Any],
        manifest: dict[str, Any],
        fixtures_dir: Path,
        model_dir: Path,
        workspace: Path,
    ) -> dict[str, Any]:
        lock_path = self._stage_lock(workspace)
        staged_fixtures_dir = self._stage_audio(
            fixture,
            fixtures_dir,
            workspace,
        )
        reference_snapshot = self._verified_reference_snapshot(fixture, fixtures_dir)
        return run_fixture(
            fixture,
            manifest,
            staged_fixtures_dir,
            model_dir,
            workspace,
            lock_path=lock_path,
            reference_snapshot=reference_snapshot,
        )

    def run_cancellation(
        self,
        fixture: dict[str, Any],
        manifest: dict[str, Any],
        fixtures_dir: Path,
        model_dir: Path,
        workspace: Path,
    ) -> dict[str, Any]:
        lock_path = self._stage_lock(workspace)
        staged_fixtures_dir = self._stage_audio(
            fixture,
            fixtures_dir,
            workspace,
        )
        return run_cancellation(
            fixture,
            manifest,
            staged_fixtures_dir,
            model_dir,
            workspace,
            lock_path=lock_path,
        )

    def run_cached_offline(
        self,
        fixture: dict[str, Any],
        fixtures_dir: Path,
        model_dir: Path,
        workspace: Path,
    ) -> dict[str, Any]:
        lock_path = self._stage_lock(workspace)
        staged_fixtures_dir = self._stage_audio(
            fixture,
            fixtures_dir,
            workspace,
        )
        return run_cached_offline(
            fixture,
            staged_fixtures_dir,
            model_dir,
            workspace,
            lock_path=lock_path,
        )


def _is_number(value: Any) -> bool:
    return type(value) in {int, float} and math.isfinite(value)


def _sanitize_measurements(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != set(FIXTURE_MEASUREMENT_KINDS):
        raise QualificationError("fixture measurements are incomplete")
    sanitized: dict[str, Any] = {}
    for name, kind in FIXTURE_MEASUREMENT_KINDS.items():
        measured = value[name]
        valid = (
            (kind == "integer" and type(measured) is int)
            or (kind == "number" and _is_number(measured))
            or (kind == "boolean" and type(measured) is bool)
            or (
                kind == "optional-number"
                and (measured is None or _is_number(measured))
            )
            or (
                kind == "optional-integer"
                and (measured is None or type(measured) is int)
            )
            or (
                kind == "optional-thermal"
                and (measured is None or measured in THERMAL_ORDER)
            )
        )
        if not valid:
            raise QualificationError("fixture measurement type is invalid")
        if (
            kind in {"integer", "number", "optional-number", "optional-integer"}
            and measured is not None
            and measured < 0
        ):
            raise QualificationError("fixture measurement cannot be negative")
        if name in {"peakResidentBytes", "peakMpsDriverAllocatedBytes"} and measured == 0:
            raise QualificationError("memory telemetry must be positive when present")
        sanitized[name] = measured

    reference_count = sanitized["referenceWordCount"]
    candidate_count = sanitized["candidateWordCount"]
    audio_duration_ms = sanitized["audioDurationMs"]
    if reference_count <= 0:
        raise QualificationError("reference word count must be positive")
    if audio_duration_ms <= 0:
        raise QualificationError("audio duration must be positive")
    expected_word_count_ratio = candidate_count / reference_count
    if not math.isclose(
        sanitized["wordCountRatio"],
        expected_word_count_ratio,
        rel_tol=1e-12,
        abs_tol=1e-12,
    ):
        raise QualificationError("word count ratio is contradictory")

    percentage_measurements = {
        "referenceWordCoverage",
        "verbatimEventRecall",
        "beginningAnchorCoverage",
        "tailAnchorCoverage",
        "timedWordRatio",
        "zeroDurationWordRatio",
        "alignedWordTimingRatio",
        "longPauseTimingRecall",
        "longformBoundaryTimingRecall",
        "finalUnderfilledWindowTimingRecall",
    }
    if any(not 0 <= sanitized[name] <= 1 for name in percentage_measurements):
        raise QualificationError("percentage measurement is out of range")
    if sanitized["alignedWordTimingRatio"] > sanitized["referenceWordCoverage"]:
        raise QualificationError("aligned timing exceeds reference word coverage")

    def integer_count(value: float, description: str) -> int:
        nearest = round(value)
        if not math.isclose(value, nearest, rel_tol=0.0, abs_tol=1e-9):
            raise QualificationError(f"{description} is not an integer count")
        return nearest

    edit_distance = integer_count(
        sanitized["wordErrorRate"] * reference_count,
        "word error distance",
    )
    matched_reference_count = integer_count(
        sanitized["referenceWordCoverage"] * reference_count,
        "reference match count",
    )
    if candidate_count == 0:
        if sanitized["timedWordRatio"] != 0:
            raise QualificationError("timed word ratio is contradictory")
        valid_timed_count = 0
    else:
        valid_timed_count = integer_count(
            sanitized["timedWordRatio"] * candidate_count,
            "valid timed word count",
        )
    aligned_timing_count = integer_count(
        sanitized["alignedWordTimingRatio"] * reference_count,
        "aligned timing count",
    )
    zero_duration_count = integer_count(
        sanitized["zeroDurationWordRatio"] * candidate_count,
        "zero-duration word count",
    )
    if not abs(reference_count - candidate_count) <= edit_distance <= max(
        reference_count,
        candidate_count,
    ):
        raise QualificationError("word error distance is contradictory")
    if not 0 <= matched_reference_count <= min(reference_count, candidate_count):
        raise QualificationError("reference match count is contradictory")
    if not 0 <= valid_timed_count <= candidate_count:
        raise QualificationError("valid timed word count is contradictory")
    if not 0 <= aligned_timing_count <= min(
        matched_reference_count,
        valid_timed_count,
    ):
        raise QualificationError("aligned timing count is contradictory")
    if not 0 <= zero_duration_count or (
        zero_duration_count + valid_timed_count > candidate_count
    ):
        raise QualificationError("zero-duration word count is contradictory")

    reference_run = sanitized["referenceMaximumRepeatedNgramRun"]
    candidate_run = sanitized["candidateMaximumRepeatedNgramRun"]
    if not 1 <= reference_run <= reference_count:
        raise QualificationError("reference repetition measurement is contradictory")
    if (
        (candidate_count == 0 and candidate_run != 0)
        or (candidate_count > 0 and not 1 <= candidate_run <= candidate_count)
    ):
        raise QualificationError("candidate repetition measurement is contradictory")
    if sanitized["excessRepeatedNgramRun"] != max(0, candidate_run - reference_run):
        raise QualificationError("excess repetition measurement is contradictory")

    duration_seconds = audio_duration_ms / 1000
    expected_cold_rtf = (
        sanitized["modelLoadSeconds"] + sanitized["coldInferenceSeconds"]
    ) / duration_seconds
    expected_warm_rtf = sanitized["warmInferenceSeconds"] / duration_seconds
    if not math.isclose(
        sanitized["coldRealTimeFactor"],
        expected_cold_rtf,
        rel_tol=1e-12,
        abs_tol=1e-12,
    ) or not math.isclose(
        sanitized["warmRealTimeFactor"],
        expected_warm_rtf,
        rel_tol=1e-12,
        abs_tol=1e-12,
    ):
        raise QualificationError("real-time factor measurement is contradictory")
    return sanitized


def _sanitize_gate_value(value: Any, kind: str) -> Any:
    if kind == "number" and _is_number(value):
        return value
    if kind == "boolean" and type(value) is bool:
        return value
    if kind == "thermal" and isinstance(value, str) and value in THERMAL_ORDER:
        return value
    raise QualificationError("qualification gate value is invalid")


def _fixture_gate_rules(manifest: dict[str, Any]) -> dict[str, tuple[str, Any]]:
    quality = manifest["thresholds"]["quality"]
    timing = manifest["thresholds"]["timing"]
    runtime = manifest["thresholds"]["runtime"]
    return {
        "quality.word-error-rate": ("maximum", quality["maximumWordErrorRate"]),
        "quality.reference-word-coverage": (
            "minimum",
            quality["minimumReferenceWordCoverage"],
        ),
        "quality.verbatim-event-recall": (
            "minimum",
            quality["minimumVerbatimEventRecall"],
        ),
        "quality.beginning-anchor-coverage": (
            "minimum",
            quality["minimumBeginningAnchorCoverage"],
        ),
        "quality.tail-anchor-coverage": (
            "minimum",
            quality["minimumTailAnchorCoverage"],
        ),
        "quality.word-count-ratio-minimum": (
            "minimum",
            quality["minimumWordCountRatio"],
        ),
        "quality.word-count-ratio-maximum": (
            "maximum",
            quality["maximumWordCountRatio"],
        ),
        "quality.excess-repeated-ngram-run": (
            "maximum",
            quality["maximumExcessRepeatedNgramRun"],
        ),
        "timing.timed-word-ratio": ("minimum", timing["minimumTimedWordRatio"]),
        "timing.text-word-count-match": ("equals", True),
        "timing.one-token-per-word": ("equals", True),
        "timing.text-word-content-match": ("equals", True),
        "timing.zero-duration-word-ratio": (
            "maximum",
            timing["maximumZeroDurationWordRatio"],
        ),
        "timing.tail-lag-ms": ("maximum", timing["maximumTailLagMs"]),
        "timing.maximum-word-start-error-ms": (
            "maximum",
            timing["maximumWordStartErrorMs"],
        ),
        "timing.maximum-word-end-error-ms": (
            "maximum",
            timing["maximumWordEndErrorMs"],
        ),
        "timing.aligned-word-timing-ratio": (
            "minimum",
            timing["minimumAlignedWordTimingRatio"],
        ),
        "timing.long-pause-timing-recall": (
            "minimum",
            timing["minimumLongPauseTimingRecall"],
        ),
        "timing.longform-boundary-timing-recall": (
            "minimum",
            timing["minimumLongformBoundaryTimingRecall"],
        ),
        "timing.final-underfilled-window-timing-recall": (
            "minimum",
            timing["minimumFinalUnderfilledWindowTimingRecall"],
        ),
        "timing.monotonic": ("equals", timing["requireMonotonicWordTimes"]),
        "timing.within-audio": ("equals", timing["requireWordsWithinAudio"]),
        "runtime.cold-real-time-factor": (
            "maximum",
            runtime["maximumColdRealTimeFactor"],
        ),
        "runtime.warm-real-time-factor": (
            "maximum",
            runtime["maximumWarmRealTimeFactor"],
        ),
        "runtime.peak-resident-bytes": (
            "maximum",
            runtime["maximumPeakResidentBytes"],
        ),
        "runtime.peak-mps-driver-allocated-bytes": (
            "maximum",
            runtime["maximumPeakMpsDriverAllocatedBytes"],
        ),
        "runtime.maximum-thermal-state": (
            "thermal-maximum",
            runtime["maximumThermalState"],
        ),
        "runtime.thermal-recovery-seconds": (
            "maximum",
            runtime["maximumThermalRecoverySeconds"],
        ),
        "quality.cold-warm-output-match": ("equals", True),
    }


def _cancellation_gate_rules(manifest: dict[str, Any]) -> dict[str, tuple[str, Any]]:
    thresholds = manifest["thresholds"]["cancellation"]
    return {
        "cancellation.transcription-active": ("equals", True),
        "cancellation.termination-seconds": (
            "maximum",
            thresholds["maximumTerminationSeconds"],
        ),
        "cancellation.no-forced-kill": (
            "equals",
            thresholds["mustExitWithoutForcedKill"],
        ),
        "cancellation.worker-reaped": ("equals", True),
    }


def _cached_offline_gate_rules(manifest: dict[str, Any]) -> dict[str, tuple[str, Any]]:
    thresholds = manifest["thresholds"]["cachedOffline"]
    return {
        "cached-offline.inference": ("equals", thresholds["mustSucceed"]),
        "cached-offline.network-denied": (
            "equals",
            thresholds["mustProveNetworkDenied"],
        ),
    }


def _gate_kind(comparison: str) -> str:
    if comparison in {"minimum", "maximum"}:
        return "number"
    if comparison == "equals":
        return "boolean"
    if comparison == "thermal-maximum":
        return "thermal"
    raise QualificationError("qualification gate comparison is invalid")


def _gate_evidence_passes(measured: Any, comparison: str, threshold: Any) -> bool:
    if comparison == "minimum":
        return measured >= threshold
    if comparison == "maximum":
        return measured <= threshold
    if comparison == "equals":
        return measured == threshold
    if comparison == "thermal-maximum":
        return THERMAL_ORDER[measured] <= THERMAL_ORDER[threshold]
    raise QualificationError("qualification gate comparison is invalid")


def _sanitize_gates(
    value: Any,
    *,
    rules: dict[str, tuple[str, Any]],
    measurements: dict[str, Any] | None = None,
    gate_measurements: dict[str, str] | None = None,
) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        raise QualificationError("qualification gates must be an array")
    expected = set(rules)
    sanitized: list[dict[str, Any]] = []
    observed: set[str] = set()
    allowed_fields = {"gate", "status", "measured", "threshold", "reason"}
    for gate in value:
        if not isinstance(gate, dict) or not set(gate).issubset(allowed_fields):
            raise QualificationError("qualification gate shape is invalid")
        name = gate.get("gate")
        status = gate.get("status")
        if name not in expected or name in observed or status not in {"passed", "failed"}:
            raise QualificationError("qualification gate identity is invalid")
        if "threshold" not in gate:
            raise QualificationError("qualification gate threshold is missing")
        comparison, pinned_threshold = rules[name]
        kind = _gate_kind(comparison)
        _sanitize_gate_value(gate["threshold"], kind)
        pinned_threshold = _sanitize_gate_value(pinned_threshold, kind)
        measured = None
        if "measured" in gate:
            measured = _sanitize_gate_value(gate["measured"], kind)
        elif status == "passed":
            raise QualificationError("passed qualification gate has no measurement")
        measurement_name = (gate_measurements or {}).get(name)
        if measurement_name is not None:
            if measurements is None or measurement_name not in measurements:
                raise QualificationError("qualification gate measurement is missing")
            canonical_measurement = measurements[measurement_name]
            if measured != canonical_measurement:
                raise QualificationError("qualification gate measurement is contradictory")
        evidence_passes = measured is not None and _gate_evidence_passes(
            measured,
            comparison,
            pinned_threshold,
        )
        result: dict[str, Any] = {
            "gate": name,
            "status": "passed" if status == "passed" and evidence_passes else "failed",
            "threshold": pinned_threshold,
        }
        if measured is not None:
            result["measured"] = measured
        reason = gate.get("reason")
        if reason is not None:
            if not isinstance(reason, str) or not SAFE_REASON_PATTERN.fullmatch(reason):
                raise QualificationError("qualification gate reason is invalid")
            result["reason"] = reason
        observed.add(name)
        sanitized.append(result)
    if observed != expected:
        raise QualificationError("qualification gate evidence is incomplete")
    return sanitized


def _sanitize_fixture_result(
    value: Any,
    fixture: dict[str, Any],
    manifest: dict[str, Any],
) -> dict[str, Any]:
    fixture_id = fixture["id"]
    if not isinstance(value, dict) or value.get("id") != fixture_id:
        raise QualificationError("fixture result identity mismatch")
    reported_status = value.get("status")
    if reported_status not in {"passed", "failed"}:
        raise QualificationError("fixture result status is invalid")
    measurements = _sanitize_measurements(value.get("measurements"))
    minimum_duration_ms, maximum_duration_ms = fixture["durationRangeMs"]
    if not minimum_duration_ms <= measurements["audioDurationMs"] <= maximum_duration_ms:
        raise QualificationError("fixture audio duration is outside its manifest range")
    gates = _sanitize_gates(
        value.get("gates"),
        rules=_fixture_gate_rules(manifest),
        measurements=measurements,
        gate_measurements=FIXTURE_GATE_MEASUREMENTS,
    )
    return {
        "id": fixture_id,
        "status": (
            "passed"
            if reported_status == "passed"
            and all(gate["status"] == "passed" for gate in gates)
            else "failed"
        ),
        "measurements": measurements,
        "gates": gates,
    }


def _sanitize_cancellation_result(
    value: Any,
    manifest: dict[str, Any],
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise QualificationError("cancellation result is invalid")
    reported_status = value.get("status")
    if reported_status not in {"passed", "failed"}:
        raise QualificationError("cancellation result is invalid")
    model_load = value.get("modelLoadSeconds")
    active_inference = value.get("activeInferenceAcknowledged")
    termination = value.get("terminationSeconds")
    forced_kill = value.get("forcedKill")
    worker_reaped = value.get("workerReaped")
    if (
        not _is_number(model_load)
        or model_load < 0
        or type(active_inference) is not bool
        or not _is_number(termination)
        or termination < 0
        or type(forced_kill) is not bool
        or type(worker_reaped) is not bool
    ):
        raise QualificationError("cancellation measurements are invalid")
    gates = _sanitize_gates(
        value.get("gates"),
        rules=_cancellation_gate_rules(manifest),
        measurements={
            "activeInferenceAcknowledged": active_inference,
            "terminationSeconds": termination,
            "noForcedKill": not forced_kill,
            "workerReaped": worker_reaped,
        },
        gate_measurements={
            "cancellation.transcription-active": "activeInferenceAcknowledged",
            "cancellation.termination-seconds": "terminationSeconds",
            "cancellation.no-forced-kill": "noForcedKill",
            "cancellation.worker-reaped": "workerReaped",
        },
    )
    return {
        "status": (
            "passed"
            if reported_status == "passed"
            and all(gate["status"] == "passed" for gate in gates)
            else "failed"
        ),
        "modelLoadSeconds": model_load,
        "activeInferenceAcknowledged": active_inference,
        "terminationSeconds": termination,
        "forcedKill": forced_kill,
        "workerReaped": worker_reaped,
        "gates": gates,
    }


def _sanitize_cached_offline_result(
    value: Any,
    manifest: dict[str, Any],
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise QualificationError("cached-offline result is invalid")
    reported_status = value.get("status")
    if reported_status not in {"passed", "failed"}:
        raise QualificationError("cached-offline result is invalid")
    gates = _sanitize_gates(
        value.get("gates"),
        rules=_cached_offline_gate_rules(manifest),
    )
    return {
        "status": (
            "passed"
            if reported_status == "passed"
            and all(gate["status"] == "passed" for gate in gates)
            else "failed"
        ),
        "gates": gates,
    }


def _private_run_workspace(output_parent: Path) -> Path:
    workspace = Path(tempfile.mkdtemp(prefix="audora-crisper-"))
    try:
        workspace.chmod(0o700)
        resolved_workspace = workspace.resolve()
        for protected in (output_parent.resolve(), ROOT.resolve()):
            try:
                resolved_workspace.relative_to(protected)
            except ValueError:
                continue
            raise QualificationError(
                "system temporary directory overlaps qualification outputs"
            )
        if workspace.stat().st_mode & 0o777 != 0o700:
            raise QualificationError("qualification workspace is not private")
        return workspace
    except Exception:
        shutil.rmtree(workspace, ignore_errors=True)
        raise


def run_qualification(
    lock: dict[str, Any],
    manifest: dict[str, Any],
    fixtures_dir: Path,
    model_dir: Path,
    output_parent: Path,
    *,
    executor: QualificationExecutor | None = None,
    source_plan: dict[str, Any] | None = None,
) -> dict[str, Any]:
    lock_snapshot = json.loads(json.dumps(lock))
    manifest_snapshot = json.loads(json.dumps(manifest))
    source_plan_snapshot = json.loads(
        json.dumps(
            source_plan if source_plan is not None else load_json(PUBLIC_SOURCE_PLAN)
        )
    )
    validate_locked_configuration(
        lock_snapshot,
        manifest_snapshot,
        source_plan_snapshot,
    )
    source_gates, _ = _public_source_preflight(manifest_snapshot)
    if any(gate.status != "passed" for gate in source_gates):
        raise QualificationError("public derived audio hashes are not pinned")
    lock_sha256 = canonical_json_sha256(lock_snapshot)
    manifest_sha256 = canonical_json_sha256(manifest_snapshot)
    executor = executor or LocalQualificationExecutor(lock_snapshot)
    run_workspace = _private_run_workspace(output_parent)
    try:
        fixtures = []
        for fixture in manifest_snapshot["fixtures"]:
            try:
                result = executor.run_fixture(
                    json.loads(json.dumps(fixture)),
                    json.loads(json.dumps(manifest_snapshot)),
                    fixtures_dir,
                    model_dir,
                    run_workspace / fixture["id"],
                )
                result = _sanitize_fixture_result(
                    result,
                    fixture,
                    manifest_snapshot,
                )
            except Exception:
                result = {"id": fixture["id"], "status": "failed", "gates": [Gate("runner.execution", "failed", reason="QUALIFICATION_EXECUTION_FAILED").as_json()]}
            result["sourceProvenance"] = json.loads(
                json.dumps(fixture["sourceProvenance"])
            )
            fixtures.append(result)
        fixture_by_id = {
            fixture["id"]: fixture for fixture in manifest_snapshot["fixtures"]
        }
        try:
            cancellation = executor.run_cancellation(
                json.loads(json.dumps(fixture_by_id["forty-five-minute"])),
                json.loads(json.dumps(manifest_snapshot)),
                fixtures_dir,
                model_dir,
                run_workspace / "cancellation",
            )
            cancellation = _sanitize_cancellation_result(
                cancellation,
                manifest_snapshot,
            )
        except Exception:
            cancellation = {"status": "failed", "gates": [Gate("cancellation.execution", "failed", reason="QUALIFICATION_EXECUTION_FAILED").as_json()]}
        try:
            cached_offline = executor.run_cached_offline(
                json.loads(json.dumps(fixture_by_id["short"])),
                fixtures_dir,
                model_dir,
                run_workspace / "cached-offline",
            )
            cached_offline = _sanitize_cached_offline_result(
                cached_offline,
                manifest_snapshot,
            )
        except Exception:
            cached_offline = {"status": "failed", "gates": [Gate("cached-offline.execution", "failed", reason="QUALIFICATION_EXECUTION_FAILED").as_json()]}
        passed = all(item["status"] == "passed" for item in fixtures) and cancellation["status"] == "passed" and cached_offline["status"] == "passed"
        return {
            "schemaVersion": 1,
            "recordedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
            "qualificationProfileId": lock_snapshot["qualificationProfileId"],
            "engineLockSha256": lock_sha256,
            "corpusManifestSha256": manifest_sha256,
            "publicSourcePlanId": source_plan_snapshot["planId"],
            "publicSourcePlanSha256": canonical_json_sha256(source_plan_snapshot),
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
    source_plan = load_json(PUBLIC_SOURCE_PLAN)
    model_dir = arguments.model_dir
    if model_dir is None and os.environ.get("AUDORA_CRISPER_MODEL_DIR"):
        model_dir = Path(os.environ["AUDORA_CRISPER_MODEL_DIR"])
    gates, reasons = preflight(
        lock,
        manifest,
        arguments.fixtures_dir,
        model_dir,
        source_plan=source_plan,
    )
    preflight_passed = all(gate.status == "passed" for gate in gates)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    if arguments.preflight_only or not preflight_passed:
        report = blocked_report(
            lock,
            manifest,
            gates,
            reasons,
            source_plan=source_plan,
        )
    else:
        if model_dir is None:
            raise AssertionError("preflight accepted an absent model")
        report = run_qualification(
            lock,
            manifest,
            arguments.fixtures_dir,
            model_dir,
            arguments.output.parent,
            source_plan=source_plan,
        )
    arguments.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Crisper qualification: {report['qualificationStatus']}")
    return 0 if report["qualificationStatus"] == "passed" or arguments.preflight_only else 2


if __name__ == "__main__":
    raise SystemExit(main())
