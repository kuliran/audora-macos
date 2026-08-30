#!/usr/bin/env python3
"""Run the deterministic issue #4 worker-restriction qualification."""

from __future__ import annotations

import argparse
from pathlib import Path

import confinement


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    report = confinement.build_qualification_report()
    if arguments.output is not None:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(
            confinement.canonical_report_json(report), encoding="utf-8"
        )

    synthetic = report["syntheticRestrictionProof"]
    production = report["productionCrisperQualification"]
    print(
        "synthetic-restriction-proof:",
        synthetic["status"].upper(),
        f"scenarios={len(synthetic['scenarios'])}",
    )
    print(
        "production-crisper-qualification:",
        production["status"].upper(),
        "reasons=" + ",".join(production["reasonCodes"]),
    )
    return 0 if synthetic["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
