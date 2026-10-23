#!/usr/bin/env python3
"""Classify native test evidence without treating exit 65 as an environment error."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def classify(summary: object, test_exit: int, log: str) -> str:
    if not isinstance(summary, dict):
        summary = {}
    failures = summary.get("testFailures", [])
    if not isinstance(failures, list) or any(
        not isinstance(item, dict) for item in failures
    ):
        return "test_failed"
    failure_text = (
        " ".join(
            item.get("failureText", "")
            for item in failures
            if isinstance(item, dict) and isinstance(item.get("failureText"), str)
        )
        if isinstance(failures, list)
        else ""
    )
    evidence = (log + "\n" + failure_text).lower()
    if "xctassert" in evidence and "failed" in evidence:
        return "test_failed"
    # Only explicit runner initialization failures establish an environment
    # block. Generic "automation" text or exit 65 can also be a test failure.
    blocked = any(
        marker in evidence
        for marker in (
            "timed out while enabling automation mode",
            "runner failed to initialize",
            "native pipe closed before response",
        )
    )
    if blocked and "xctassert" not in evidence:
        return "automation_environment_blocked"
    counts = [
        summary.get(name)
        for name in ("totalTestCount", "passedTests", "failedTests", "skippedTests")
    ]
    if (
        not failures
        and test_exit == 0
        and all(type(value) is int for value in counts)
        and counts == [1, 1, 0, 0]
    ):
        return "passed"
    return "test_failed"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--exit-code", type=int, required=True)
    args = parser.parse_args()
    try:
        summary = json.loads(args.summary.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        summary = None
    try:
        log = args.log.read_text(encoding="utf-8", errors="replace")
    except OSError:
        log = ""
    print(classify(summary, args.exit_code, log))


if __name__ == "__main__":
    main()
