#!/usr/bin/env python3
"""JSON-lines worker used only by the Crisper qualification runner."""

from __future__ import annotations

import argparse
import errno
import hashlib
import importlib.metadata
import json
import os
import resource
import socket
import sys
import threading
import time
from pathlib import Path
from typing import Any


def emit(value: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(value, separators=(",", ":"), allow_nan=False) + "\n")
    sys.stdout.flush()


def fail(code: str) -> None:
    emit({"type": "failed", "code": code})


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("object required")
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


def network_probe() -> str:
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.settimeout(0.2)
    try:
        result = probe.connect_ex(("127.0.0.1", 9))
    finally:
        probe.close()
    return "denied" if result in (errno.EPERM, errno.EACCES) else "not-denied"


class MemorySampler:
    def __init__(self, torch_module: Any) -> None:
        self.torch = torch_module
        self.peak_mps = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, daemon=True)

    def start(self) -> None:
        self._sample()
        self._thread.start()

    def _sample(self) -> None:
        try:
            self.peak_mps = max(self.peak_mps, int(self.torch.mps.driver_allocated_memory()))
        except (AttributeError, RuntimeError):
            pass

    def _loop(self) -> None:
        while not self._stop.wait(0.1):
            self._sample()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=1)
        self._sample()


def word_value(word: Any) -> dict[str, Any] | None:
    text = getattr(word, "word", None) or getattr(word, "text", None)
    start = getattr(word, "start", None)
    end = getattr(word, "end", None)
    if not isinstance(text, str) or not isinstance(start, (int, float)) or not isinstance(end, (int, float)):
        return None
    return {"text": text, "startMs": round(float(start) * 1000), "endMs": round(float(end) * 1000)}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine-lock", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    try:
        lock = load_json(arguments.engine_lock)
        model_files = lock["model"]["files"]
        if any(not (arguments.model_dir / name).is_file() or sha256_file(arguments.model_dir / name) != digest for name, digest in model_files.items()):
            fail("MODEL_ASSET_MISMATCH")
            return 2
        import torch
        from crisperwhisper import CrisperWhisperModel
        if not torch.backends.mps.is_available():
            fail("MPS_UNAVAILABLE")
            return 2
        package_versions = {
            name: importlib.metadata.version(name)
            for name in ("crisperwhisper", "torch", "transformers", "accelerate", "numpy", "soundfile", "soxr", "tokenizers", "huggingface-hub")
        }
        started = time.monotonic()
        engine = lock["engine"]
        model = CrisperWhisperModel(
            str(arguments.model_dir),
            backend=engine["backend"],
            compute_type=engine["computeType"],
            device=engine["device"],
        )
        model_load_seconds = time.monotonic() - started
    except Exception:
        fail("MODEL_LOAD_FAILED")
        return 2

    emit({
        "type": "hello",
        "qualificationProfileId": lock["qualificationProfileId"],
        "engineLockSha256": canonical_json_sha256(lock),
        "modelLoadSeconds": model_load_seconds,
        "packageVersions": package_versions,
        "networkProbe": network_probe(),
    })

    decoding = lock["decoding"]
    for line in sys.stdin:
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            fail("MALFORMED_REQUEST")
            continue
        if request.get("type") == "shutdown":
            return 0
        if request.get("type") != "transcribe" or not isinstance(request.get("fixtureId"), str) or not isinstance(request.get("audioPath"), str):
            fail("INVALID_REQUEST")
            continue
        audio_path = Path(request["audioPath"])
        if not audio_path.is_file():
            fail("AUDIO_UNAVAILABLE")
            continue
        sampler = MemorySampler(torch)
        sampler.start()
        started = time.monotonic()
        try:
            result = model.transcribe(
                str(audio_path),
                language=decoding["language"],
                mode=decoding["mode"],
                hotwords=decoding["hotwords"],
                longform_strategy=decoding["longformStrategy"],
                chunk_duration=decoding["chunkDurationSeconds"],
                stride=decoding["strideSeconds"],
                context_words=decoding["contextWords"],
                drop_words=decoding["dropWords"],
                timestamp_aware_drop=decoding["timestampAwareDrop"],
                temperature_fallback=decoding["temperatureFallback"],
                max_new_tokens=decoding["maxNewTokens"],
                speculative_decoding=decoding["speculativeDecoding"],
                speculative_mode=decoding["speculativeMode"],
                hallucination_mitigation=decoding["hallucinationMitigation"],
                word_timestamps=decoding["wordTimestamps"],
                alignment_heads=None,
                suppress_tokens=None,
            )
            elapsed = time.monotonic() - started
        except Exception:
            sampler.stop()
            fail("TRANSCRIPTION_FAILED")
            continue
        sampler.stop()
        words = [value for value in (word_value(word) for word in (getattr(result, "words", None) or [])) if value is not None]
        peak_resident = int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
        emit({
            "type": "result",
            "fixtureId": request["fixtureId"],
            "text": str(getattr(result, "text", "")),
            "words": words,
            "elapsedSeconds": elapsed,
            "peakResidentBytes": peak_resident,
            "peakMpsDriverAllocatedBytes": sampler.peak_mps,
        })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
