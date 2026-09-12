#!/usr/bin/env python3
"""Prepare candidate WAV fixtures from the pinned public-source plan.

This utility is deliberately separate from the qualification runner. It may
download only the URLs declared in the plan, verifies every source hash before
use, and creates audio candidates only. It never creates reference labels,
changes the corpus manifest, or marks a qualification gate ready.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import wave
from pathlib import Path, PurePosixPath
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parent
DEFAULT_PLAN = ROOT / "public-source-plan.v1.json"
DEFAULT_SOURCE_DIR = ROOT / "fixtures" / "source"
DEFAULT_FIXTURES_DIR = ROOT / "fixtures"
EXPECTED_FIXTURES = {
    "short",
    "one-minute",
    "twelve-minute",
    "forty-five-minute",
}
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
IDENTIFIER_PATTERN = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
PODCAST_ARGUMENTS_PROFILE = "audora-pcm16le-16khz-mono-v1"


class PreparationError(Exception):
    """A bounded source-plan, download, or conversion failure."""


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Turn redirects into terminal HTTP responses before a new request is made."""

    def redirect_request(
        self,
        request: Any,
        file_pointer: Any,
        code: int,
        message: str,
        headers: Any,
        new_url: str,
    ) -> None:
        return None


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
    return (frame_count * 1000 + sample_rate - 1) // sample_rate


def load_plan(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PreparationError("SOURCE_PLAN_INVALID") from error
    if not isinstance(value, dict):
        raise PreparationError("SOURCE_PLAN_INVALID")
    return value


def _safe_relative_path(root: Path, value: str) -> Path:
    relative = Path(value)
    if relative.is_absolute() or not relative.parts or ".." in relative.parts:
        raise PreparationError("SOURCE_PLAN_PATH_INVALID")
    path = root / relative
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError as error:
        raise PreparationError("SOURCE_PLAN_PATH_INVALID") from error
    return path


def validate_plan(plan: dict[str, Any]) -> None:
    if plan.get("schemaVersion") != 1:
        raise PreparationError("SOURCE_PLAN_SCHEMA_UNSUPPORTED")
    plan_id = plan.get("planId")
    if (
        not isinstance(plan_id, str)
        or len(plan_id) > 128
        or not IDENTIFIER_PATTERN.fullmatch(plan_id)
    ):
        raise PreparationError("SOURCE_PLAN_ID_INVALID")
    sources = plan.get("sources")
    fixtures = plan.get("fixtures")
    if not isinstance(sources, dict) or not isinstance(fixtures, list):
        raise PreparationError("SOURCE_PLAN_INVALID")
    fixture_ids = [
        fixture.get("id")
        for fixture in fixtures
        if isinstance(fixture, dict)
    ]
    if (
        len(fixture_ids) != len(fixtures)
        or len(fixture_ids) != len(set(fixture_ids))
        or set(fixture_ids) != EXPECTED_FIXTURES
    ):
        raise PreparationError("SOURCE_PLAN_FIXTURES_INVALID")
    for source_id, source in sources.items():
        if not isinstance(source_id, str) or not IDENTIFIER_PATTERN.fullmatch(source_id):
            raise PreparationError("SOURCE_PLAN_SOURCE_INVALID")
        if not isinstance(source, dict):
            raise PreparationError("SOURCE_PLAN_SOURCE_INVALID")
        if source.get("mediaKind") not in {"pcm-wav", "mp3"}:
            raise PreparationError("SOURCE_PLAN_SOURCE_INVALID")
        if not isinstance(source.get("mediaUrl"), str) or not source["mediaUrl"].startswith("https://"):
            raise PreparationError("SOURCE_PLAN_SOURCE_INVALID")
        if not isinstance(source.get("fileName"), str):
            raise PreparationError("SOURCE_PLAN_SOURCE_INVALID")
        if not isinstance(source.get("sizeBytes"), int) or source["sizeBytes"] <= 0:
            raise PreparationError("SOURCE_PLAN_SOURCE_INVALID")
        if not isinstance(source.get("sha256"), str) or not SHA256_PATTERN.fullmatch(source["sha256"]):
            raise PreparationError("SOURCE_PLAN_SOURCE_INVALID")
    normalized_output_paths: list[str] = []
    for fixture in fixtures:
        if not isinstance(fixture, dict) or fixture.get("sourceId") not in sources:
            raise PreparationError("SOURCE_PLAN_FIXTURE_INVALID")
        if not isinstance(fixture.get("startMs"), int) or fixture["startMs"] < 0:
            raise PreparationError("SOURCE_PLAN_FIXTURE_INVALID")
        if not isinstance(fixture.get("durationMs"), int) or fixture["durationMs"] <= 0:
            raise PreparationError("SOURCE_PLAN_FIXTURE_INVALID")
        output_path = fixture.get("outputPath")
        if not isinstance(output_path, str) or "\\" in output_path:
            raise PreparationError("SOURCE_PLAN_PATH_INVALID")
        relative_output = PurePosixPath(output_path)
        if (
            relative_output.is_absolute()
            or len(relative_output.parts) < 2
            or relative_output.parts[0] != "audio"
            or any(part in {"", ".", ".."} for part in relative_output.parts)
            or relative_output.suffix != ".wav"
            or relative_output.name == ".wav"
        ):
            raise PreparationError("SOURCE_PLAN_PATH_INVALID")
        normalized_output_paths.append(relative_output.as_posix())
    if len(normalized_output_paths) != len(set(normalized_output_paths)):
        raise PreparationError("SOURCE_PLAN_OUTPUT_PATHS_INVALID")


def require_podcast_reproducibility(
    plan: dict[str, Any],
    fixtures: list[dict[str, Any]],
) -> dict[str, str] | None:
    selected_podcast_fixtures = [
        fixture
        for fixture in fixtures
        if plan["sources"][fixture["sourceId"]]["mediaKind"] == "mp3"
    ]
    if not selected_podcast_fixtures:
        return None
    podcast_fixtures = [
        fixture
        for fixture in plan["fixtures"]
        if plan["sources"][fixture["sourceId"]]["mediaKind"] == "mp3"
    ]
    conversion = plan.get("podcastConversion")
    if (
        not isinstance(conversion, dict)
        or conversion.get("tool") != "ffmpeg"
        or conversion.get("argumentsProfile") != PODCAST_ARGUMENTS_PROFILE
        or not isinstance(conversion.get("executableSha256"), str)
        or not SHA256_PATTERN.fullmatch(conversion["executableSha256"])
        or not isinstance(conversion.get("versionLine"), str)
        or not conversion["versionLine"]
        or len(conversion["versionLine"]) > 512
        or any(
            not isinstance(fixture.get("candidateAudioSha256"), str)
            or not SHA256_PATTERN.fullmatch(fixture["candidateAudioSha256"])
            for fixture in podcast_fixtures
        )
    ):
        raise PreparationError("PODCAST_REPRODUCIBILITY_NOT_PINNED")
    return {
        "executableSha256": conversion["executableSha256"],
        "versionLine": conversion["versionLine"],
    }


def resolve_pinned_converter(requested: str, identity: dict[str, str]) -> str:
    executable = shutil.which(requested)
    if executable is None:
        raise PreparationError("FFMPEG_REQUIRED_FOR_PODCAST_FIXTURES")
    try:
        if sha256_file(Path(executable)) != identity["executableSha256"]:
            raise PreparationError("PODCAST_CONVERTER_IDENTITY_MISMATCH")
        completed = subprocess.run(
            [executable, "-version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            text=True,
            timeout=10,
        )
    except PreparationError:
        raise
    except (OSError, subprocess.TimeoutExpired) as error:
        raise PreparationError("PODCAST_CONVERTER_IDENTITY_MISMATCH") from error
    version_lines = completed.stdout.splitlines()
    if (
        completed.returncode != 0
        or not version_lines
        or version_lines[0] != identity["versionLine"]
    ):
        raise PreparationError("PODCAST_CONVERTER_IDENTITY_MISMATCH")
    return executable


def _download_source(source_id: str, source: dict[str, Any], destination: Path) -> None:
    temporary: Path | None = None
    try:
        request = urllib.request.Request(
            source["mediaUrl"],
            headers={"User-Agent": "Audora qualification fixture preparer/1"},
        )
        opener = urllib.request.build_opener(_NoRedirectHandler())
        with opener.open(request, timeout=60) as response:
            destination.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(
                prefix=f".{source_id}-",
                dir=destination.parent,
                delete=False,
            ) as output:
                temporary = Path(output.name)
                remaining = source["sizeBytes"] + 1
                while remaining:
                    chunk = response.read(min(1024 * 1024, remaining))
                    if not chunk:
                        break
                    output.write(chunk)
                    remaining -= len(chunk)
        if temporary.stat().st_size != source["sizeBytes"]:
            raise PreparationError(f"SOURCE_SIZE_MISMATCH:{source_id}")
        if sha256_file(temporary) != source["sha256"]:
            raise PreparationError(f"SOURCE_HASH_MISMATCH:{source_id}")
        os.replace(temporary, destination)
        temporary = None
    except urllib.error.HTTPError as error:
        if 300 <= error.code < 400:
            raise PreparationError(f"SOURCE_REDIRECT_FORBIDDEN:{source_id}") from error
        raise PreparationError(f"SOURCE_DOWNLOAD_FAILED:{source_id}") from error
    except PreparationError:
        raise
    except (OSError, urllib.error.URLError) as error:
        raise PreparationError(f"SOURCE_DOWNLOAD_FAILED:{source_id}") from error
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def acquire_sources(
    plan: dict[str, Any],
    source_dir: Path,
    source_ids: Iterable[str],
    *,
    download: bool,
) -> dict[str, Path]:
    acquired: dict[str, Path] = {}
    for source_id in sorted(set(source_ids)):
        source = plan["sources"][source_id]
        path = _safe_relative_path(source_dir, source["fileName"])
        if not path.is_file():
            if not download:
                raise PreparationError(f"SOURCE_FILE_MISSING:{source_id}")
            _download_source(source_id, source, path)
        if path.stat().st_size != source["sizeBytes"]:
            raise PreparationError(f"SOURCE_SIZE_MISMATCH:{source_id}")
        if sha256_file(path) != source["sha256"]:
            raise PreparationError(f"SOURCE_HASH_MISMATCH:{source_id}")
        acquired[source_id] = path
    return acquired


def _validate_wave(path: Path, expected_duration_ms: int) -> None:
    try:
        with wave.open(str(path), "rb") as audio:
            duration_ms = canonical_audio_duration_ms(
                audio.getnframes(),
                audio.getframerate(),
            )
            valid = (
                audio.getnchannels() == 1
                and audio.getsampwidth() == 2
                and audio.getframerate() == 16000
                and audio.getcomptype() == "NONE"
                and duration_ms == expected_duration_ms
            )
    except (OSError, EOFError, wave.Error):
        valid = False
    if not valid:
        raise PreparationError("DERIVED_AUDIO_INVALID")


def _extract_pcm_wave(
    source: Path,
    destination: Path,
    start_ms: int,
    duration_ms: int,
) -> None:
    try:
        with wave.open(str(source), "rb") as audio:
            rate = audio.getframerate()
            if (
                audio.getnchannels() != 1
                or audio.getsampwidth() != 2
                or rate != 16000
                or audio.getcomptype() != "NONE"
            ):
                raise PreparationError("SOURCE_WAVE_FORMAT_INVALID")
            if start_ms * rate % 1000 or duration_ms * rate % 1000:
                raise PreparationError("SOURCE_PLAN_SAMPLE_BOUNDARY_INVALID")
            start_frame = start_ms * rate // 1000
            frame_count = duration_ms * rate // 1000
            if start_frame + frame_count > audio.getnframes():
                raise PreparationError("SOURCE_INTERVAL_OUT_OF_BOUNDS")
            audio.setpos(start_frame)
            frames = audio.readframes(frame_count)
        with wave.open(str(destination), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(16000)
            output.writeframes(frames)
    except PreparationError:
        raise
    except (OSError, EOFError, wave.Error) as error:
        raise PreparationError("SOURCE_WAVE_READ_FAILED") from error


def _extract_mp3_with_ffmpeg(
    ffmpeg: str,
    source: Path,
    destination: Path,
    start_ms: int,
    duration_ms: int,
) -> None:
    command = [
        ffmpeg,
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(source),
        "-ss",
        f"{start_ms / 1000:.3f}",
        "-t",
        f"{duration_ms / 1000:.3f}",
        "-map_metadata",
        "-1",
        "-vn",
        "-ac",
        "1",
        "-ar",
        "16000",
        "-c:a",
        "pcm_s16le",
        "-bitexact",
        "-fflags",
        "+bitexact",
        str(destination),
    ]
    try:
        completed = subprocess.run(
            command,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=900,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise PreparationError("PODCAST_CONVERSION_FAILED") from error
    if completed.returncode != 0:
        raise PreparationError("PODCAST_CONVERSION_FAILED")


def prepare_fixture(
    fixture: dict[str, Any],
    source: dict[str, Any],
    source_path: Path,
    fixtures_dir: Path,
    *,
    ffmpeg: str | None,
    replace: bool,
) -> dict[str, Any]:
    destination = _safe_relative_path(fixtures_dir, fixture["outputPath"])
    if destination.exists() and not replace:
        raise PreparationError(f"DERIVED_AUDIO_EXISTS:{fixture['id']}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        prefix=f".{fixture['id']}-",
        suffix=".wav",
        dir=destination.parent,
        delete=False,
    ) as temporary_file:
        temporary = Path(temporary_file.name)
    try:
        if source["mediaKind"] == "pcm-wav":
            _extract_pcm_wave(
                source_path,
                temporary,
                fixture["startMs"],
                fixture["durationMs"],
            )
        else:
            if ffmpeg is None:
                raise PreparationError("FFMPEG_REQUIRED_FOR_PODCAST_FIXTURES")
            _extract_mp3_with_ffmpeg(
                ffmpeg,
                source_path,
                temporary,
                fixture["startMs"],
                fixture["durationMs"],
            )
        _validate_wave(temporary, fixture["durationMs"])
        actual_hash = sha256_file(temporary)
        expected_hash = fixture.get("candidateAudioSha256")
        if expected_hash is not None and actual_hash != expected_hash:
            raise PreparationError(
                f"DERIVED_AUDIO_HASH_MISMATCH:{fixture['id']}"
            )
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return {
        "id": fixture["id"],
        "status": "prepared-awaiting-human-reference-review",
        "durationMs": fixture["durationMs"],
        "audioSha256": actual_hash,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, default=DEFAULT_PLAN)
    parser.add_argument("--source-dir", type=Path, default=DEFAULT_SOURCE_DIR)
    parser.add_argument("--fixtures-dir", type=Path, default=DEFAULT_FIXTURES_DIR)
    parser.add_argument("--fixtures", nargs="+", default=sorted(EXPECTED_FIXTURES))
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--replace", action="store_true")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--report", type=Path)
    return parser.parse_args(argv)


def _is_within(path: Path, directory: Path) -> bool:
    try:
        path.relative_to(directory)
    except ValueError:
        return False
    return True


def validate_report_destination(
    report_path: Path | None,
    *,
    plan_path: Path,
    source_dir: Path,
    fixtures_dir: Path,
) -> None:
    if report_path is None:
        return
    resolved_report = report_path.resolve(strict=False)
    protected_plan = plan_path.resolve(strict=False)
    protected_directories = (
        source_dir.resolve(strict=False),
        fixtures_dir.resolve(strict=False),
    )
    if resolved_report == protected_plan or any(
        _is_within(resolved_report, directory)
        for directory in protected_directories
    ):
        raise PreparationError("REPORT_PATH_INVALID")
    if report_path.exists() or report_path.is_symlink():
        raise PreparationError("REPORT_EXISTS")


def write_new_report(report_path: Path, serialized: str) -> None:
    try:
        report_path.parent.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        raise PreparationError("REPORT_WRITE_FAILED") from error
    try:
        descriptor = os.open(
            report_path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
    except FileExistsError as error:
        raise PreparationError("REPORT_EXISTS") from error
    except OSError as error:
        raise PreparationError("REPORT_WRITE_FAILED") from error
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(serialized)
    except OSError as error:
        try:
            report_path.unlink(missing_ok=True)
        except OSError:
            pass
        raise PreparationError("REPORT_WRITE_FAILED") from error


def main(argv: list[str] | None = None) -> int:
    arguments = parse_args(argv if argv is not None else sys.argv[1:])
    try:
        plan = load_plan(arguments.plan)
        validate_plan(plan)
        validate_report_destination(
            arguments.report,
            plan_path=arguments.plan,
            source_dir=arguments.source_dir,
            fixtures_dir=arguments.fixtures_dir,
        )
        selected = set(arguments.fixtures)
        if not selected or not selected.issubset(EXPECTED_FIXTURES):
            raise PreparationError("UNKNOWN_FIXTURE")
        fixtures = [fixture for fixture in plan["fixtures"] if fixture["id"] in selected]
        source_ids = [fixture["sourceId"] for fixture in fixtures]
        podcast_identity = require_podcast_reproducibility(plan, fixtures)
        ffmpeg = (
            resolve_pinned_converter(arguments.ffmpeg, podcast_identity)
            if podcast_identity is not None
            else None
        )
        sources = acquire_sources(
            plan,
            arguments.source_dir,
            source_ids,
            download=arguments.download,
        )
        destinations = [
            _safe_relative_path(arguments.fixtures_dir, fixture["outputPath"])
            for fixture in fixtures
        ]
        if not arguments.replace and any(path.exists() for path in destinations):
            raise PreparationError("DERIVED_AUDIO_EXISTS")
        results = [
            prepare_fixture(
                fixture,
                plan["sources"][fixture["sourceId"]],
                sources[fixture["sourceId"]],
                arguments.fixtures_dir,
                ffmpeg=ffmpeg,
                replace=arguments.replace,
            )
            for fixture in fixtures
        ]
        report = {
            "schemaVersion": 1,
            "sourcePlanId": plan["planId"],
            "sourcePlanSha256": canonical_json_sha256(plan),
            "status": "prepared-awaiting-human-reference-review",
            "qualificationReady": False,
            "fixtures": results,
        }
        serialized = json.dumps(report, indent=2, sort_keys=True) + "\n"
        if arguments.report is not None:
            write_new_report(arguments.report, serialized)
        print(serialized, end="")
        return 0
    except PreparationError as error:
        print(f"Public fixture preparation blocked: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
