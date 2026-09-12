from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import struct
import sys
import tempfile
import unittest
import wave
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "crisper_public_fixture_preparer",
    ROOT / "prepare_public_fixtures.py",
)
assert SPEC is not None and SPEC.loader is not None
preparer = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = preparer
SPEC.loader.exec_module(preparer)


FIXTURE_IDS = ("short", "one-minute", "twelve-minute", "forty-five-minute")


def wav_bytes(samples: list[int]) -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(16000)
        audio.writeframes(struct.pack(f"<{len(samples)}h", *samples))
    return output.getvalue()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


class PreparationCLITests(unittest.TestCase):
    def test_current_plan_pins_converter_and_podcast_outputs(self) -> None:
        plan = json.loads((ROOT / "public-source-plan.v1.json").read_text())
        manifest = json.loads((ROOT / "corpus-manifest.v1.json").read_text())

        self.assertEqual(
            plan["podcastConversion"],
            {
                "tool": "ffmpeg",
                "argumentsProfile": "audora-pcm16le-16khz-mono-v1",
                "executableSha256": (
                    "c997afe238f01223e11f47f945e1599e506217bc7ed7f02b0205f21f56fb73c3"
                ),
                "versionLine": "ffmpeg version 8.0 Copyright (c) 2000-2025 the FFmpeg developers",
                "status": "pinned-and-reproduced",
            },
        )
        planned_by_id = {fixture["id"]: fixture for fixture in plan["fixtures"]}
        manifest_by_id = {
            fixture["id"]: fixture for fixture in manifest["fixtures"]
        }
        expected_hashes = {
            "twelve-minute": (
                "e357cbf3a8568a39b897846ba8a988beb86630c7bba22deb2675e652abfa37eb"
            ),
            "forty-five-minute": (
                "8bef07a1cadea11f9a2505592e5ac20c46577c4868499b2d7aeb8fcfe60a08c5"
            ),
        }
        for fixture_id, expected_hash in expected_hashes.items():
            planned_hash = planned_by_id[fixture_id]["candidateAudioSha256"]
            self.assertEqual(planned_hash, expected_hash)
            self.assertEqual(manifest_by_id[fixture_id]["audioSha256"], planned_hash)
            self.assertEqual(
                manifest_by_id[fixture_id]["assetStatus"],
                "awaiting-acoustic-and-reference-review",
            )
            self.assertEqual(
                manifest_by_id[fixture_id]["sourceProvenance"][
                    "candidateAudioSha256"
                ],
                planned_hash,
            )

    def make_pcm_plan(
        self,
        source_bytes: bytes,
        *,
        short_output: str = "audio/short.wav",
    ) -> dict:
        fixtures = []
        for fixture_id in FIXTURE_IDS:
            fixtures.append(
                {
                    "id": fixture_id,
                    "sourceId": "test-source",
                    "startMs": 10,
                    "durationMs": 20,
                    "outputPath": (
                        short_output
                        if fixture_id == "short"
                        else f"audio/{fixture_id}.wav"
                    ),
                }
            )
        return {
            "schemaVersion": 1,
            "planId": "test-public-audio-v1",
            "sources": {
                "test-source": {
                    "mediaUrl": "https://example.invalid/source.wav",
                    "fileName": "source.wav",
                    "sizeBytes": len(source_bytes),
                    "sha256": sha256_bytes(source_bytes),
                    "mediaKind": "pcm-wav",
                }
            },
            "fixtures": fixtures,
        }

    def invoke(
        self,
        plan: dict,
        root: Path,
        *,
        extra_arguments: list[str] | None = None,
        source_bytes: bytes | None = None,
        fixture_id: str = "short",
    ) -> tuple[int, str, str]:
        plan_path = root / "plan.json"
        source_dir = root / "source"
        fixtures_dir = root / "fixtures"
        plan_path.write_text(json.dumps(plan), encoding="utf-8")
        if source_bytes is not None:
            source_dir.mkdir(parents=True)
            (source_dir / "source.wav").write_bytes(source_bytes)
        arguments = [
            "--plan",
            str(plan_path),
            "--source-dir",
            str(source_dir),
            "--fixtures-dir",
            str(fixtures_dir),
            "--fixtures",
            fixture_id,
        ]
        arguments.extend(extra_arguments or [])
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            return preparer.main(arguments), stdout.getvalue(), stderr.getvalue()

    def test_output_path_cannot_escape_fixture_directory(self) -> None:
        source_bytes = wav_bytes(list(range(1600)))
        plan = self.make_pcm_plan(source_bytes, short_output="../escaped.wav")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            code, stdout, stderr = self.invoke(
                plan,
                root,
                source_bytes=source_bytes,
            )

            self.assertEqual(code, 2)
            self.assertEqual(stdout, "")
            self.assertIn("SOURCE_PLAN_PATH_INVALID", stderr)
            self.assertFalse((root / "escaped.wav").exists())

    def test_output_path_is_restricted_to_audio_wav_files_before_replace(self) -> None:
        source_bytes = wav_bytes(list(range(1600)))
        for unsafe_output in (
            "reference/short.json",
            "reference/short.wav",
            "audio/short.json",
        ):
            with self.subTest(output=unsafe_output), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                plan = self.make_pcm_plan(source_bytes, short_output=unsafe_output)
                destination = root / "fixtures" / unsafe_output
                destination.parent.mkdir(parents=True)
                destination.write_bytes(b"human-reviewed label")

                code, stdout, stderr = self.invoke(
                    plan,
                    root,
                    extra_arguments=["--replace"],
                    source_bytes=source_bytes,
                )

                self.assertEqual(code, 2)
                self.assertEqual(stdout, "")
                self.assertIn("SOURCE_PLAN_PATH_INVALID", stderr)
                self.assertEqual(destination.read_bytes(), b"human-reviewed label")

    def test_invalid_plan_id_fails_before_replacing_any_output(self) -> None:
        source_bytes = wav_bytes(list(range(1600)))
        plan = self.make_pcm_plan(source_bytes)
        del plan["planId"]

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / "fixtures" / "audio" / "short.wav"
            destination.parent.mkdir(parents=True)
            destination.write_bytes(b"reviewed fixture")

            code, stdout, stderr = self.invoke(
                plan,
                root,
                extra_arguments=["--replace"],
                source_bytes=source_bytes,
            )

            self.assertEqual(code, 2)
            self.assertEqual(stdout, "")
            self.assertIn("SOURCE_PLAN_ID_INVALID", stderr)
            self.assertEqual(destination.read_bytes(), b"reviewed fixture")

    def test_duplicate_fixture_records_fail_before_any_download_or_write(self) -> None:
        source_bytes = wav_bytes(list(range(1600)))
        plan = self.make_pcm_plan(source_bytes)
        plan["fixtures"].append(dict(plan["fixtures"][0]))

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            preparer.urllib.request,
            "build_opener",
        ) as build_opener:
            root = Path(directory)
            code, stdout, stderr = self.invoke(
                plan,
                root,
                extra_arguments=["--download"],
            )

            self.assertEqual(code, 2)
            self.assertEqual(stdout, "")
            self.assertIn("SOURCE_PLAN_FIXTURES_INVALID", stderr)
            build_opener.assert_not_called()
            self.assertFalse((root / "source").exists())
            self.assertFalse((root / "fixtures").exists())

    def test_duplicate_normalized_output_paths_fail_before_any_download_or_write(self) -> None:
        source_bytes = wav_bytes(list(range(1600)))
        plan = self.make_pcm_plan(source_bytes)
        plan["fixtures"][1]["outputPath"] = "audio//short.wav"

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            preparer.urllib.request,
            "build_opener",
        ) as build_opener:
            root = Path(directory)
            code, stdout, stderr = self.invoke(
                plan,
                root,
                extra_arguments=["--download"],
            )

            self.assertEqual(code, 2)
            self.assertEqual(stdout, "")
            self.assertIn("SOURCE_PLAN_OUTPUT_PATHS_INVALID", stderr)
            build_opener.assert_not_called()
            self.assertFalse((root / "source").exists())
            self.assertFalse((root / "fixtures").exists())

    def test_source_size_and_hash_must_match_the_plan(self) -> None:
        source_bytes = wav_bytes(list(range(1600)))
        cases = (
            ("sizeBytes", len(source_bytes) + 1, "SOURCE_SIZE_MISMATCH"),
            ("sha256", "0" * 64, "SOURCE_HASH_MISMATCH"),
        )

        for field, invalid_value, reason in cases:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                plan = self.make_pcm_plan(source_bytes)
                plan["sources"]["test-source"][field] = invalid_value

                code, stdout, stderr = self.invoke(
                    plan,
                    root,
                    source_bytes=source_bytes,
                )

                self.assertEqual(code, 2)
                self.assertEqual(stdout, "")
                self.assertIn(reason, stderr)
                self.assertFalse((root / "fixtures" / "audio" / "short.wav").exists())

    def test_download_reads_at_most_one_byte_beyond_the_pinned_size(self) -> None:
        source_bytes = wav_bytes(list(range(1600)))
        plan = self.make_pcm_plan(source_bytes)
        oversized_response = source_bytes + b"unexpected trailing bytes"

        class Response:
            def __init__(self, payload: bytes) -> None:
                self.payload = payload
                self.offset = 0
                self.bytes_read = 0

            def __enter__(self) -> "Response":
                return self

            def __exit__(self, *unused: object) -> None:
                return None

            def geturl(self) -> str:
                return "https://example.invalid/source.wav"

            def read(self, size: int) -> bytes:
                result = self.payload[self.offset : self.offset + size]
                self.offset += len(result)
                self.bytes_read += len(result)
                return result

        response = Response(oversized_response)
        opener = mock.Mock()
        opener.open.return_value = response
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            preparer.urllib.request,
            "build_opener",
            return_value=opener,
        ):
            root = Path(directory)
            code, stdout, stderr = self.invoke(
                plan,
                root,
                extra_arguments=["--download"],
            )

            self.assertEqual(code, 2)
            self.assertEqual(stdout, "")
            self.assertIn("SOURCE_SIZE_MISMATCH", stderr)
            self.assertEqual(response.bytes_read, len(source_bytes) + 1)
            self.assertFalse((root / "source" / "source.wav").exists())
            self.assertEqual(list((root / "source").glob(".test-source-*")), [])

    def test_download_redirect_is_rejected_without_local_mutation(self) -> None:
        requested_urls: list[str] = []
        source_url = "https://example.invalid/source.wav"
        redirected_url = "https://redirected.example.invalid/source.wav"

        class Opener:
            def __init__(self, handler: object) -> None:
                self.handler = handler

            def open(self, request: object, timeout: float) -> None:
                requested_urls.append(request.full_url)
                redirected_request = self.handler.redirect_request(
                    request,
                    None,
                    302,
                    "Found",
                    {"Location": redirected_url},
                    redirected_url,
                )
                if redirected_request is not None:
                    requested_urls.append(redirected_request.full_url)
                raise preparer.urllib.error.HTTPError(
                    source_url,
                    302,
                    "Found",
                    {"Location": redirected_url},
                    None,
                )

        def build_opener(handler: object) -> Opener:
            self.assertIsInstance(handler, preparer._NoRedirectHandler)
            return Opener(handler)

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            preparer.urllib.request,
            "build_opener",
            side_effect=build_opener,
        ), mock.patch.object(
            preparer.urllib.request,
            "urlopen",
            side_effect=AssertionError("default redirect-following opener must not be used"),
        ):
            destination = Path(directory) / "source.wav"
            source = {
                "mediaUrl": source_url,
                "sizeBytes": 1,
                "sha256": sha256_bytes(b"x"),
            }
            with self.assertRaisesRegex(
                preparer.PreparationError,
                "SOURCE_REDIRECT_FORBIDDEN:test-source",
            ):
                preparer._download_source("test-source", source, destination)

            self.assertEqual(requested_urls, [source_url])
            self.assertFalse(destination.exists())

    def test_pcm_source_is_clipped_on_exact_sample_boundaries(self) -> None:
        source_samples = list(range(1600))
        source_bytes = wav_bytes(source_samples)
        plan = self.make_pcm_plan(source_bytes)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            code, stdout, stderr = self.invoke(
                plan,
                root,
                source_bytes=source_bytes,
            )

            self.assertEqual(code, 0)
            self.assertEqual(stderr, "")
            report = json.loads(stdout)
            self.assertFalse(report["qualificationReady"])
            destination = root / "fixtures" / "audio" / "short.wav"
            with wave.open(str(destination), "rb") as audio:
                self.assertEqual(audio.getparams()[:4], (1, 2, 16000, 320))
                samples = struct.unpack("<320h", audio.readframes(320))
            self.assertEqual(samples, tuple(source_samples[160:480]))

    def test_existing_output_is_never_partially_overwritten(self) -> None:
        source_bytes = wav_bytes(list(range(1600)))
        original = b"existing reviewed fixture"

        for arguments, expected_reason in (
            ([], "DERIVED_AUDIO_EXISTS"),
            (["--replace"], "DERIVED_AUDIO_HASH_MISMATCH"),
        ):
            with self.subTest(arguments=arguments), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                plan = self.make_pcm_plan(source_bytes)
                plan["fixtures"][0]["candidateAudioSha256"] = "0" * 64
                destination = root / "fixtures" / "audio" / "short.wav"
                destination.parent.mkdir(parents=True)
                destination.write_bytes(original)

                code, stdout, stderr = self.invoke(
                    plan,
                    root,
                    extra_arguments=arguments,
                    source_bytes=source_bytes,
                )

                self.assertEqual(code, 2)
                self.assertEqual(stdout, "")
                self.assertIn(expected_reason, stderr)
                self.assertEqual(destination.read_bytes(), original)
                self.assertEqual(list(destination.parent.glob(".short-*.wav")), [])

    def test_report_cannot_alias_plan_source_or_fixture_assets(self) -> None:
        source_bytes = wav_bytes(list(range(1600)))
        plan = self.make_pcm_plan(source_bytes)
        protected_paths = (
            "plan.json",
            "source/source.wav",
            "fixtures/reference/short.json",
            "fixtures/audio/short.wav",
        )

        for relative_path in protected_paths:
            with self.subTest(path=relative_path), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                target = root / relative_path
                if relative_path.startswith("fixtures/"):
                    target.parent.mkdir(parents=True)
                    target.write_bytes(b"protected fixture asset")
                    expected = b"protected fixture asset"
                elif relative_path == "source/source.wav":
                    expected = source_bytes
                else:
                    expected = json.dumps(plan).encode()

                code, stdout, stderr = self.invoke(
                    plan,
                    root,
                    extra_arguments=["--replace", "--report", str(target)],
                    source_bytes=source_bytes,
                )

                self.assertEqual(code, 2)
                self.assertEqual(stdout, "")
                self.assertIn("REPORT_PATH_INVALID", stderr)
                self.assertEqual(target.read_bytes(), expected)

    def test_existing_safe_report_is_refused_before_preparation(self) -> None:
        source_bytes = wav_bytes(list(range(1600)))
        plan = self.make_pcm_plan(source_bytes)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report_path = root / "reports" / "preparation.json"
            report_path.parent.mkdir(parents=True)
            report_path.write_bytes(b"existing report")

            code, stdout, stderr = self.invoke(
                plan,
                root,
                extra_arguments=["--report", str(report_path)],
                source_bytes=source_bytes,
            )

            self.assertEqual(code, 2)
            self.assertEqual(stdout, "")
            self.assertIn("REPORT_EXISTS", stderr)
            self.assertEqual(report_path.read_bytes(), b"existing report")
            self.assertFalse((root / "fixtures" / "audio" / "short.wav").exists())

    def test_new_safe_report_is_created_with_the_stdout_document(self) -> None:
        source_bytes = wav_bytes(list(range(1600)))
        plan = self.make_pcm_plan(source_bytes)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report_path = root / "reports" / "preparation.json"
            code, stdout, stderr = self.invoke(
                plan,
                root,
                extra_arguments=["--report", str(report_path)],
                source_bytes=source_bytes,
            )

            self.assertEqual(code, 0)
            self.assertEqual(stderr, "")
            self.assertEqual(report_path.read_text(encoding="utf-8"), stdout)

    def test_report_directory_failure_is_a_bounded_path_free_cli_error(self) -> None:
        source_bytes = wav_bytes(list(range(1600)))
        plan = self.make_pcm_plan(source_bytes)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            non_directory = root / "not-a-directory"
            non_directory.write_bytes(b"occupied")
            report_path = non_directory / "preparation.json"

            code, stdout, stderr = self.invoke(
                plan,
                root,
                extra_arguments=["--report", str(report_path)],
                source_bytes=source_bytes,
            )

            self.assertEqual(code, 2)
            self.assertEqual(stdout, "")
            self.assertEqual(
                stderr,
                "Public fixture preparation blocked: REPORT_WRITE_FAILED\n",
            )
            self.assertNotIn(str(root), stderr)
            self.assertNotIn("Traceback", stderr)

    def test_report_write_and_cleanup_failures_remain_a_bounded_cli_error(self) -> None:
        source_bytes = wav_bytes(list(range(1600)))
        plan = self.make_pcm_plan(source_bytes)

        class FailingReportStream:
            def __init__(self, descriptor: int) -> None:
                self.descriptor = descriptor

            def __enter__(self) -> "FailingReportStream":
                return self

            def __exit__(self, *unused: object) -> None:
                preparer.os.close(self.descriptor)

            def write(self, unused: str) -> None:
                raise OSError("simulated write failure")

        original_unlink = Path.unlink
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report_path = root / "reports" / "preparation.json"

            def fail_report_cleanup(path: Path, *args: object, **kwargs: object) -> None:
                if path == report_path:
                    raise OSError("simulated cleanup failure")
                original_unlink(path, *args, **kwargs)

            with mock.patch.object(
                preparer.os,
                "fdopen",
                side_effect=lambda descriptor, *args, **kwargs: FailingReportStream(
                    descriptor
                ),
            ), mock.patch.object(Path, "unlink", autospec=True, side_effect=fail_report_cleanup):
                code, stdout, stderr = self.invoke(
                    plan,
                    root,
                    extra_arguments=["--report", str(report_path)],
                    source_bytes=source_bytes,
                )

            self.assertEqual(code, 2)
            self.assertEqual(stdout, "")
            self.assertEqual(
                stderr,
                "Public fixture preparation blocked: REPORT_WRITE_FAILED\n",
            )
            self.assertNotIn(str(root), stderr)
            self.assertNotIn("Traceback", stderr)

    def test_report_created_during_preparation_is_not_replaced(self) -> None:
        source_bytes = wav_bytes(list(range(1600)))
        plan = self.make_pcm_plan(source_bytes)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report_path = root / "reports" / "preparation.json"

            def collide_with_report(*unused_args, **unused_kwargs):
                report_path.parent.mkdir(parents=True, exist_ok=True)
                report_path.write_bytes(b"concurrent report")
                return {
                    "id": "short",
                    "status": "prepared-awaiting-human-reference-review",
                    "durationMs": 20,
                    "audioSha256": "0" * 64,
                }

            with mock.patch.object(
                preparer,
                "prepare_fixture",
                side_effect=collide_with_report,
            ):
                code, stdout, stderr = self.invoke(
                    plan,
                    root,
                    extra_arguments=["--report", str(report_path)],
                    source_bytes=source_bytes,
                )

            self.assertEqual(code, 2)
            self.assertEqual(stdout, "")
            self.assertIn("REPORT_EXISTS", stderr)
            self.assertEqual(report_path.read_bytes(), b"concurrent report")

    def test_podcast_conversion_requires_pinned_converter_and_output_hash(self) -> None:
        source_bytes = b"deterministic fake podcast source"
        plan = self.make_pcm_plan(source_bytes)
        plan["sources"]["test-source"].update(
            {"mediaKind": "mp3", "fileName": "source.wav"}
        )

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            preparer.shutil,
            "which",
        ) as which:
            root = Path(directory)
            code, stdout, stderr = self.invoke(
                plan,
                root,
                source_bytes=source_bytes,
                fixture_id="twelve-minute",
            )

            self.assertEqual(code, 2)
            self.assertEqual(stdout, "")
            self.assertIn("PODCAST_REPRODUCIBILITY_NOT_PINNED", stderr)
            which.assert_not_called()

    def test_selecting_one_podcast_requires_hashes_for_every_podcast_fixture(self) -> None:
        source_bytes = b"deterministic fake podcast source"
        plan = self.make_pcm_plan(source_bytes)
        plan["sources"]["test-source"].update(
            {"mediaKind": "mp3", "fileName": "source.wav"}
        )
        plan["fixtures"][2]["candidateAudioSha256"] = "1" * 64
        plan["podcastConversion"] = {
            "tool": "ffmpeg",
            "argumentsProfile": "audora-pcm16le-16khz-mono-v1",
            "executableSha256": "2" * 64,
            "versionLine": "ffmpeg version pinned-test",
        }

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            preparer.shutil,
            "which",
            return_value=None,
        ) as which:
            root = Path(directory)
            code, stdout, stderr = self.invoke(
                plan,
                root,
                source_bytes=source_bytes,
                fixture_id="twelve-minute",
            )

            self.assertEqual(code, 2)
            self.assertEqual(stdout, "")
            self.assertIn("PODCAST_REPRODUCIBILITY_NOT_PINNED", stderr)
            which.assert_not_called()
            self.assertFalse(
                (root / "fixtures" / "audio" / "twelve-minute.wav").exists()
            )

    def test_podcast_converter_executable_must_match_pinned_identity(self) -> None:
        source_bytes = b"deterministic fake podcast source"
        plan = self.make_pcm_plan(source_bytes)
        plan["sources"]["test-source"].update(
            {"mediaKind": "mp3", "fileName": "source.wav"}
        )
        for fixture in plan["fixtures"]:
            fixture["candidateAudioSha256"] = "1" * 64
        plan["podcastConversion"] = {
            "tool": "ffmpeg",
            "argumentsProfile": "audora-pcm16le-16khz-mono-v1",
            "executableSha256": "0" * 64,
            "versionLine": "ffmpeg version test",
        }

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_ffmpeg = root / "fake-ffmpeg"
            fake_ffmpeg.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_ffmpeg.chmod(0o755)

            code, stdout, stderr = self.invoke(
                plan,
                root,
                extra_arguments=["--ffmpeg", str(fake_ffmpeg)],
                source_bytes=source_bytes,
                fixture_id="twelve-minute",
            )

            self.assertEqual(code, 2)
            self.assertEqual(stdout, "")
            self.assertIn("PODCAST_CONVERTER_IDENTITY_MISMATCH", stderr)
            self.assertFalse(
                (root / "fixtures" / "audio" / "twelve-minute.wav").exists()
            )

    def test_podcast_converter_version_must_match_pinned_identity(self) -> None:
        source_bytes = b"deterministic fake podcast source"
        plan = self.make_pcm_plan(source_bytes)
        plan["sources"]["test-source"].update(
            {"mediaKind": "mp3", "fileName": "source.wav"}
        )
        for fixture in plan["fixtures"]:
            fixture["candidateAudioSha256"] = "1" * 64

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_ffmpeg = root / "fake-ffmpeg"
            fake_ffmpeg.write_text(
                "#!/bin/sh\necho 'ffmpeg version actual'\n",
                encoding="utf-8",
            )
            fake_ffmpeg.chmod(0o755)
            plan["podcastConversion"] = {
                "tool": "ffmpeg",
                "argumentsProfile": "audora-pcm16le-16khz-mono-v1",
                "executableSha256": sha256_bytes(fake_ffmpeg.read_bytes()),
                "versionLine": "ffmpeg version expected",
            }

            code, stdout, stderr = self.invoke(
                plan,
                root,
                extra_arguments=["--ffmpeg", str(fake_ffmpeg)],
                source_bytes=source_bytes,
                fixture_id="twelve-minute",
            )

            self.assertEqual(code, 2)
            self.assertEqual(stdout, "")
            self.assertIn("PODCAST_CONVERTER_IDENTITY_MISMATCH", stderr)

    def test_pinned_podcast_converter_overwrites_only_the_temporary_file(self) -> None:
        source_bytes = b"deterministic fake podcast source"
        plan = self.make_pcm_plan(source_bytes)
        plan["sources"]["test-source"].update(
            {"mediaKind": "mp3", "fileName": "source.wav"}
        )
        for fixture in plan["fixtures"]:
            fixture["candidateAudioSha256"] = "1" * 64
        plan["fixtures"][2]["candidateAudioSha256"] = (
            "6d5a57285af5ab10fd11ee5fb4f564281eac95b3131bcadad5812952a39558e1"
        )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_ffmpeg = root / "fake-ffmpeg"
            fake_ffmpeg.write_text(
                "#!/usr/bin/env python3\n"
                "import json, pathlib, sys, wave\n"
                "if sys.argv[1:] == ['-version']:\n"
                "    print('ffmpeg version pinned-test')\n"
                "    raise SystemExit(0)\n"
                "arguments = sys.argv[1:]\n"
                "pathlib.Path(__file__).with_suffix('.args.json').write_text(json.dumps(arguments))\n"
                "destination = pathlib.Path(arguments[-1])\n"
                "if destination.exists() and '-y' not in arguments:\n"
                "    raise SystemExit(17)\n"
                "with wave.open(str(destination), 'wb') as audio:\n"
                "    audio.setnchannels(1)\n"
                "    audio.setsampwidth(2)\n"
                "    audio.setframerate(16000)\n"
                "    audio.writeframes(bytes(640))\n",
                encoding="utf-8",
            )
            fake_ffmpeg.chmod(0o755)
            plan["podcastConversion"] = {
                "tool": "ffmpeg",
                "argumentsProfile": "audora-pcm16le-16khz-mono-v1",
                "executableSha256": sha256_bytes(fake_ffmpeg.read_bytes()),
                "versionLine": "ffmpeg version pinned-test",
            }

            code, stdout, stderr = self.invoke(
                plan,
                root,
                extra_arguments=["--ffmpeg", str(fake_ffmpeg)],
                source_bytes=source_bytes,
                fixture_id="twelve-minute",
            )

            self.assertEqual(code, 0)
            self.assertEqual(stderr, "")
            report = json.loads(stdout)
            self.assertEqual(
                report["fixtures"][0]["audioSha256"],
                "6d5a57285af5ab10fd11ee5fb4f564281eac95b3131bcadad5812952a39558e1",
            )
            converter_arguments = json.loads(
                fake_ffmpeg.with_suffix(".args.json").read_text(encoding="utf-8")
            )
            self.assertIn("-y", converter_arguments)
            self.assertEqual(Path(converter_arguments[-1]).suffix, ".wav")
            self.assertTrue(
                (root / "fixtures" / "audio" / "twelve-minute.wav").is_file()
            )


if __name__ == "__main__":
    unittest.main()
