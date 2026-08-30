#!/usr/bin/env python3
"""Production-restriction process host for the worker qualification gate.

The host constructs every worker input explicitly.  It never copies the parent
environment, discovers user configuration, or reads a user home directory.
"""

from __future__ import annotations

import dataclasses
import datetime as dt
import hashlib
import json
import os
import platform
import resource
import selectors
import signal
import socket
import stat
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any


ALLOWED_ENVIRONMENT_KEYS = frozenset(
    {
        "HOME",
        "XDG_CONFIG_HOME",
        "XDG_CACHE_HOME",
        "HF_HOME",
        "HF_HUB_CACHE",
        "TRANSFORMERS_CACHE",
        "TORCH_HOME",
        "TMPDIR",
        "PATH",
        "LANG",
        "LC_ALL",
        "PYTHONNOUSERSITE",
        "PYTHONSAFEPATH",
        "HF_HUB_OFFLINE",
        "TRANSFORMERS_OFFLINE",
        "TOKENIZERS_PARALLELISM",
    }
)


def sandbox_profile_text() -> str:
    """Return the versioned Seatbelt profile used by every worker launch.

    ``dyld-support.sb`` supplies only loader bootstrap operations.  User/model
    paths remain explicit parameters, cached inference has no network rule, and
    the worker may execute only the already-resolved runtime binary.
    """

    return """\
(version 1)
(deny default)
(import "dyld-support.sb")

(allow syscall*)
(allow mach-bootstrap)
(allow sysctl-read)
(allow signal (target self))

(allow process-exec
  (literal (param "WORKER_EXECUTABLE")))

(allow file-read-metadata file-test-existence
  (path-ancestors (param "JOB_ROOT"))
  (path-ancestors (param "RUNTIME_ROOT"))
  (path-ancestors (param "MODEL_ROOT")))

(allow file-read* file-test-existence file-map-executable
  (subpath "/System")
  (subpath "/usr/lib")
  (subpath (param "JOB_ROOT"))
  (subpath (param "RUNTIME_ROOT"))
  (subpath (param "MODEL_ROOT"))
  (literal "/dev/null")
  (literal "/dev/zero")
  (literal "/dev/random")
  (literal "/dev/urandom"))

(allow file-read-data file-test-existence file-write-data
  (subpath "/dev/fd"))

(allow file-write*
  (subpath (param "JOB_ROOT")))
"""


def worker_environment(job_root: Path) -> dict[str, str]:
    """Return the complete worker environment without consulting ``os.environ``."""

    job_root = job_root.resolve()
    cache_root = job_root / "cache"
    return {
        "HOME": str(job_root / "empty-home"),
        "XDG_CONFIG_HOME": str(job_root / "empty-config"),
        "XDG_CACHE_HOME": str(cache_root),
        "HF_HOME": str(cache_root / "huggingface"),
        "HF_HUB_CACHE": str(cache_root / "huggingface" / "hub"),
        "TRANSFORMERS_CACHE": str(cache_root / "transformers"),
        "TORCH_HOME": str(cache_root / "torch"),
        "TMPDIR": str(job_root / "tmp"),
        "PATH": "/usr/bin:/bin",
        "LANG": "C",
        "LC_ALL": "C",
        "PYTHONNOUSERSITE": "1",
        "PYTHONSAFEPATH": "1",
        "HF_HUB_OFFLINE": "1",
        "TRANSFORMERS_OFFLINE": "1",
        "TOKENIZERS_PARALLELISM": "false",
    }


ROOT = Path(__file__).resolve().parent
FIXTURE_SOURCE = ROOT / "fixture_worker.c"
SANDBOX_EXEC = Path("/usr/bin/sandbox-exec")
EXPECTED_HANDSHAKE = {
    "protocolVersion": 1,
    "runtimeVersion": "synthetic-runtime-v1",
    "modelRevision": "synthetic-model-revision-v1",
    "patchId": "synthetic-progress-patch-v1",
}
MAX_STDOUT_BYTES = 4096
MAX_STDERR_BYTES = 4096
MAX_RESULT_BYTES = 4096

EXPECTED_SCENARIO_CODES = {
    "cached-inference": "CACHED_INFERENCE_COMPLETE",
    "read-unrelated": "READ_DENIED",
    "traversal": "TRAVERSAL_DENIED",
    "symlink-read": "SYMLINK_ESCAPE_DENIED",
    "write-unrelated": "WRITE_DENIED",
    "write-runtime": "RUNTIME_READ_ONLY",
    "write-model": "MODEL_READ_ONLY",
    "network": "NETWORK_DENIED",
    "process": "PROCESS_CREATION_DENIED",
    "resource-open-files": "RESOURCE_LIMIT_REACHED",
    "resource-output": "OUTPUT_LIMIT_EXCEEDED",
    "stderr-output": "STDERR_LIMIT_EXCEEDED",
    "malformed-request": "MALFORMED_REQUEST",
    "bad-output": "MALFORMED_WORKER_OUTPUT",
    "bad-handshake": "HANDSHAKE_MISMATCH",
    "no-hello": "HANDSHAKE_TIMEOUT",
    "cancel": "CANCELLED",
    "crash": "WORKER_CRASHED",
    "timeout": "WORKER_TIMEOUT",
}

# Keep report order stable while preserving the public mapping above.
SCENARIOS = tuple(EXPECTED_SCENARIO_CODES)

KNOWN_WORKER_CODES = frozenset(
    {
        "CACHED_INPUT_UNAVAILABLE",
        "MALFORMED_REQUEST",
        "MODEL_READ_ONLY",
        "NETWORK_AVAILABLE",
        "NETWORK_DENIED",
        "PROCESS_CREATION_AVAILABLE",
        "PROCESS_CREATION_DENIED",
        "READ_DENIED",
        "RESOURCE_LIMIT_MISSING",
        "RESOURCE_LIMIT_REACHED",
        "RUNTIME_READ_ONLY",
        "STAGING_WRITE_FAILED",
        "SYMLINK_ESCAPE_DENIED",
        "TRAVERSAL_DENIED",
        "UNKNOWN_SYNTHETIC_MODE",
        "WRITE_DENIED",
        "FORBIDDEN_READ_AVAILABLE",
        "FORBIDDEN_WRITE_AVAILABLE",
    }
)


@dataclasses.dataclass(frozen=True)
class ScenarioResult:
    scenario: str
    status: str
    code: str
    handshake: dict[str, Any]
    reaped: bool
    process_group_reaped: bool
    stdout_bytes: int
    stderr_bytes: int


@dataclasses.dataclass(frozen=True)
class SyntheticFixture:
    root: Path
    runtime_root: Path
    model_root: Path
    job_root: Path
    unrelated_root: Path
    executable: Path
    profile: Path


class _BoundedFailure(Exception):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


class _OutputCollector:
    def __init__(self, process: subprocess.Popen[bytes]) -> None:
        self.process = process
        self.selector = selectors.DefaultSelector()
        assert process.stdout is not None
        assert process.stderr is not None
        self.selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        self.selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        self.stdout = bytearray()
        self.stdout_bytes = 0
        self.stderr_bytes = 0

    def close(self) -> None:
        self.selector.close()

    def json_line(self, timeout: float, timeout_code: str) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while True:
            newline = self.stdout.find(b"\n")
            if newline >= 0:
                encoded = bytes(self.stdout[:newline])
                del self.stdout[: newline + 1]
                try:
                    value = json.loads(encoded.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    raise _BoundedFailure("MALFORMED_WORKER_OUTPUT")
                if not isinstance(value, dict):
                    raise _BoundedFailure("MALFORMED_WORKER_OUTPUT")
                return value

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise _BoundedFailure(timeout_code)
            events = self.selector.select(min(remaining, 0.05))
            if not events and self.process.poll() is not None:
                self._drain_available()
                if b"\n" not in self.stdout:
                    raise _BoundedFailure("WORKER_CRASHED")
                continue
            for key, _ in events:
                self._read(key.fileobj, key.data)

    def _drain_available(self) -> None:
        for key in list(self.selector.get_map().values()):
            self._read(key.fileobj, key.data)

    def _read(self, stream: Any, name: str) -> None:
        try:
            chunk = os.read(stream.fileno(), 4096)
        except BlockingIOError:
            return
        if not chunk:
            try:
                self.selector.unregister(stream)
            except KeyError:
                pass
            return
        if name == "stderr":
            self.stderr_bytes += len(chunk)
            if self.stderr_bytes > MAX_STDERR_BYTES:
                raise _BoundedFailure("STDERR_LIMIT_EXCEEDED")
            return
        self.stdout_bytes += len(chunk)
        if self.stdout_bytes > MAX_STDOUT_BYTES:
            raise _BoundedFailure("OUTPUT_LIMIT_EXCEEDED")
        self.stdout.extend(chunk)


def _explicit_tool_environment(temporary_root: Path) -> dict[str, str]:
    return {
        "HOME": str(temporary_root / "build-home"),
        "TMPDIR": str(temporary_root / "build-tmp"),
        "PATH": "/usr/bin:/bin",
        "LANG": "C",
        "LC_ALL": "C",
    }


def prepare_synthetic_fixture(root: Path) -> SyntheticFixture:
    root = root.resolve()
    runtime_root = root / "runtime"
    model_root = root / "model"
    job_root = root / "job"
    unrelated_root = root / "unrelated"
    for directory in (
        runtime_root,
        model_root,
        job_root / "empty-home",
        job_root / "empty-config",
        job_root / "cache",
        job_root / "tmp",
        job_root / "input",
        job_root / "output",
        unrelated_root,
        root / "build-home",
        root / "build-tmp",
    ):
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)

    (model_root / "model-id.txt").write_text(
        "synthetic-model-revision-v1\n", encoding="utf-8"
    )
    (runtime_root / "runtime-marker.txt").write_text(
        "synthetic-runtime-v1\n", encoding="utf-8"
    )
    (job_root / "input" / "audio.synthetic").write_text(
        "synthetic-audio-evidence\n", encoding="utf-8"
    )
    (unrelated_root / "read.txt").write_text(
        "unrelated-synthetic-fixture\n", encoding="utf-8"
    )
    (job_root / "input" / "unrelated-link").symlink_to(
        Path("../../unrelated/read.txt")
    )
    profile = job_root / "worker-profile.sb"
    profile.write_text(sandbox_profile_text(), encoding="utf-8")

    executable = runtime_root / "synthetic-worker"
    tool_environment = _explicit_tool_environment(root)
    subprocess.run(
        [
            "/usr/bin/xcrun",
            "clang",
            "-std=c17",
            "-O2",
            "-Wall",
            "-Wextra",
            "-Werror",
            str(FIXTURE_SOURCE),
            "-o",
            str(executable),
        ],
        check=True,
        capture_output=True,
        env=tool_environment,
    )
    subprocess.run(
        [
            "/usr/bin/codesign",
            "--force",
            "--sign",
            "-",
            "--options",
            "runtime",
            "--timestamp=none",
            str(executable),
        ],
        check=True,
        capture_output=True,
        env=tool_environment,
    )
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", str(executable)],
        check=True,
        capture_output=True,
        env=tool_environment,
    )
    executable.chmod(0o555)
    (runtime_root / "runtime-marker.txt").chmod(0o444)
    (model_root / "model-id.txt").chmod(0o444)
    runtime_root.chmod(0o555)
    model_root.chmod(0o555)
    return SyntheticFixture(
        root,
        runtime_root,
        model_root,
        job_root,
        unrelated_root,
        executable,
        profile,
    )


def restore_fixture_permissions(fixture: SyntheticFixture) -> None:
    fixture.runtime_root.chmod(0o700)
    fixture.model_root.chmod(0o700)
    for path in (
        fixture.executable,
        fixture.runtime_root / "runtime-marker.txt",
        fixture.model_root / "model-id.txt",
    ):
        path.chmod(0o600)


def _resource_limits() -> None:
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_CPU, (2, 2))
    resource.setrlimit(resource.RLIMIT_FSIZE, (64 * 1024, 64 * 1024))
    resource.setrlimit(resource.RLIMIT_NOFILE, (16, 16))


def _process_group_reaped(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def _terminate_and_reap(process: subprocess.Popen[bytes], grace: float = 0.5) -> None:
    if process.poll() is None:
        try:
            process.wait(timeout=0.05)
            return
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            process.wait(timeout=grace)
            return
        except PermissionError:
            process.terminate()
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            process.kill()
        process.wait(timeout=grace)


def _launch(
    fixture: SyntheticFixture, mode: str, probe_port: int
) -> tuple[subprocess.Popen[bytes], _OutputCollector]:
    command = [
        str(SANDBOX_EXEC),
        "-f",
        str(fixture.profile),
        "-D",
        f"JOB_ROOT={fixture.job_root}",
        "-D",
        f"RUNTIME_ROOT={fixture.runtime_root}",
        "-D",
        f"MODEL_ROOT={fixture.model_root}",
        "-D",
        f"WORKER_EXECUTABLE={fixture.executable}",
        str(fixture.executable),
        "--mode",
        mode,
        "--model-root",
        str(fixture.model_root),
        "--probe-port",
        str(probe_port),
        "--unrelated-root",
        str(fixture.unrelated_root),
    ]
    process = subprocess.Popen(
        command,
        cwd=fixture.job_root,
        env=worker_environment(fixture.job_root),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
        preexec_fn=_resource_limits,
    )
    assert process.stdout is not None
    assert process.stderr is not None
    os.set_blocking(process.stdout.fileno(), False)
    os.set_blocking(process.stderr.fileno(), False)
    return process, _OutputCollector(process)


def _validated_handshake(message: dict[str, Any]) -> dict[str, Any]:
    if message.get("v") != 1 or message.get("type") != "hello":
        raise _BoundedFailure("HANDSHAKE_MISMATCH")
    for key, expected in EXPECTED_HANDSHAKE.items():
        if message.get(key) != expected:
            raise _BoundedFailure("HANDSHAKE_MISMATCH")
    for key in (
        "environmentAllowlisted",
        "homeEmpty",
        "configEmpty",
        "workingDirectoryScoped",
        "ambientSentinelAbsent",
    ):
        if message.get(key) is not True:
            raise _BoundedFailure("HANDSHAKE_MISMATCH")
    return {key: message[key] for key in EXPECTED_HANDSHAKE}


def _validate_candidate(fixture: SyntheticFixture, message: dict[str, Any]) -> None:
    if message.get("result") != "output/result.json":
        raise _BoundedFailure("INVALID_CANDIDATE")
    path = fixture.job_root / message["result"]
    try:
        metadata = path.lstat()
    except OSError:
        raise _BoundedFailure("INVALID_CANDIDATE")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise _BoundedFailure("INVALID_CANDIDATE")
    resolved = path.resolve()
    try:
        resolved.relative_to(fixture.job_root.resolve())
    except ValueError:
        raise _BoundedFailure("INVALID_CANDIDATE")
    if metadata.st_size > MAX_RESULT_BYTES:
        raise _BoundedFailure("INVALID_CANDIDATE")
    try:
        digest = hashlib.sha256(resolved.read_bytes()).hexdigest()
    except OSError:
        raise _BoundedFailure("INVALID_CANDIDATE")
    if digest != message.get("sha256") or message.get("networkDenied") is not True:
        raise _BoundedFailure("INVALID_CANDIDATE")


def run_synthetic_scenario(
    fixture: SyntheticFixture, scenario: str, probe_port: int
) -> ScenarioResult:
    mode = {
        "malformed-request": "cached-inference",
        "cancel": "hang",
        "timeout": "hang",
    }.get(scenario, scenario)
    process, collector = _launch(fixture, mode, probe_port)
    handshake: dict[str, Any] = {}
    code = "UNEXPECTED_FAILURE"
    try:
        try:
            hello = collector.json_line(0.75, "HANDSHAKE_TIMEOUT")
            handshake = _validated_handshake(hello)
            assert process.stdin is not None
            request = (
                b"not-json\n"
                if scenario == "malformed-request"
                else b'{"v":1,"type":"run"}\n'
            )
            try:
                process.stdin.write(request)
                process.stdin.flush()
            except OSError:
                raise _BoundedFailure("WORKER_CRASHED")

            if scenario == "cancel":
                _terminate_and_reap(process)
                code = "CANCELLED"
            else:
                terminal_timeout = 0.25 if scenario == "timeout" else 1.5
                terminal = collector.json_line(terminal_timeout, "WORKER_TIMEOUT")
                if terminal.get("v") != 1:
                    raise _BoundedFailure("MALFORMED_WORKER_OUTPUT")
                if terminal.get("type") == "candidate_ready":
                    _validate_candidate(fixture, terminal)
                    code = "CACHED_INFERENCE_COMPLETE"
                elif terminal.get("type") == "failed":
                    error = terminal.get("error")
                    candidate_code = error.get("code") if isinstance(error, dict) else None
                    if candidate_code not in KNOWN_WORKER_CODES:
                        raise _BoundedFailure("MALFORMED_WORKER_OUTPUT")
                    code = candidate_code
                else:
                    raise _BoundedFailure("MALFORMED_WORKER_OUTPUT")
        except _BoundedFailure as failure:
            code = failure.code
        finally:
            _terminate_and_reap(process)
    finally:
        collector.close()
        if process.stdin is not None:
            process.stdin.close()
        if process.stdout is not None:
            process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()

    expected = EXPECTED_SCENARIO_CODES[scenario]
    return ScenarioResult(
        scenario=scenario,
        status="passed" if code == expected else "failed",
        code=code,
        handshake=handshake,
        reaped=process.poll() is not None,
        process_group_reaped=_process_group_reaped(process.pid),
        stdout_bytes=min(collector.stdout_bytes, MAX_STDOUT_BYTES + 1),
        stderr_bytes=min(collector.stderr_bytes, MAX_STDERR_BYTES + 1),
    )


def qualify_synthetic_scenario(scenario: str) -> ScenarioResult:
    if scenario not in EXPECTED_SCENARIO_CODES:
        raise ValueError("unknown qualification scenario")
    with tempfile.TemporaryDirectory(
        prefix="audora-worker-confinement-", dir="/private/tmp"
    ) as directory:
        fixture = prepare_synthetic_fixture(Path(directory))
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        try:
            return run_synthetic_scenario(
                fixture, scenario, int(listener.getsockname()[1])
            )
        finally:
            listener.close()
            restore_fixture_permissions(fixture)


def canonical_report_json(report: dict[str, Any]) -> str:
    return json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n"


def _scenario_report(result: ScenarioResult) -> dict[str, Any]:
    return {
        "scenario": result.scenario,
        "status": result.status,
        "code": result.code,
        "handshake": result.handshake,
        "reaped": result.reaped,
        "processGroupReaped": result.process_group_reaped,
        "stdoutBytes": result.stdout_bytes,
        "stderrBytes": result.stderr_bytes,
    }


def build_qualification_report() -> dict[str, Any]:
    engine_lock_path = ROOT.parent / "CrisperBenchmark" / "engine-lock.v1.json"
    engine_lock_bytes = engine_lock_path.read_bytes()
    engine_lock = json.loads(engine_lock_bytes)
    canonical_engine_lock = json.dumps(
        engine_lock, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")

    with tempfile.TemporaryDirectory(
        prefix="audora-worker-confinement-", dir="/private/tmp"
    ) as directory:
        fixture = prepare_synthetic_fixture(Path(directory))
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        try:
            results = [
                run_synthetic_scenario(
                    fixture, scenario, int(listener.getsockname()[1])
                )
                for scenario in SCENARIOS
            ]
        finally:
            listener.close()
            restore_fixture_permissions(fixture)

    synthetic_passed = all(result.status == "passed" for result in results)
    patch_id = engine_lock.get("engine", {}).get("audoraCompatibilityPatchId")
    reason_codes = [
        "LOCKED_RUNTIME_NOT_PROVIDED",
        "PINNED_MODEL_NOT_PROVIDED",
        "REAL_CACHED_INFERENCE_NOT_RUN",
        "MINIMUM_MACOS_15_BASELINE_NOT_RUN",
    ]
    if not isinstance(patch_id, str) or not patch_id:
        reason_codes.append("AUDORA_COMPATIBILITY_PATCH_UNPINNED")
    reason_codes.sort()

    return {
        "schemaVersion": 1,
        "recordedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace(
            "+00:00", "Z"
        ),
        "qualificationProfileId": engine_lock["qualificationProfileId"],
        "engineLockSha256": hashlib.sha256(canonical_engine_lock).hexdigest(),
        "engineSelectionChanged": False,
        "qualificationStatus": "blocked",
        "host": {
            "machine": platform.machine(),
            "operatingSystem": platform.system(),
            "operatingSystemRelease": platform.release(),
        },
        "executionProfile": {
            "mechanism": "macOS sandbox-exec Seatbelt profile v1",
            "denyByDefault": True,
            "networkAllowed": False,
            "workingDirectory": "job-scoped",
            "runtimeInput": "read-only",
            "modelInput": "read-only",
            "jobStaging": "read-write",
            "workerEnvironmentKeys": sorted(ALLOWED_ENVIRONMENT_KEYS),
            "limits": {
                "cpuSeconds": 2,
                "openFiles": 16,
                "regularFileBytes": 65536,
                "stdoutBytes": MAX_STDOUT_BYTES,
                "stderrBytes": MAX_STDERR_BYTES,
                "terminationGraceMilliseconds": 500,
            },
        },
        "syntheticRestrictionProof": {
            "status": "passed" if synthetic_passed else "failed",
            "fixture": "ad-hoc-signed Hardened Runtime synthetic worker",
            "handshake": next(
                result.handshake
                for result in results
                if result.scenario == "cached-inference"
            ),
            "scenarios": [_scenario_report(result) for result in results],
        },
        "productionCrisperQualification": {
            "status": "blocked",
            "reasonCodes": reason_codes,
            "expectedHandshake": {
                "protocolVersion": 1,
                "pythonVersion": engine_lock["runtime"]["pythonVersion"],
                "modelRevision": engine_lock["model"]["revision"],
                "patchId": patch_id,
            },
        },
    }
