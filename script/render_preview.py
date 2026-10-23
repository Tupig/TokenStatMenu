#!/usr/bin/env python3
"""Render fixture-only light/dark dashboards and settings using actual SwiftUI code."""

from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
sources = sorted(
    path
    for target in ("TokenStatCore", "TokenStatMenu", "TokenStatWidgetShared")
    for path in (root / "Sources" / target).glob("*.swift")
)
sources = [str(p) for p in sources if p.name != "TokenStatMenuApp.swift"]
binary = root / ".build/preview-renderer"
binary.parent.mkdir(exist_ok=True)
subprocess.run(
    [
        "xcrun",
        "swiftc",
        "-parse-as-library",
        "-swift-version",
        "5",
        "-module-name",
        "TokenStatMenuPreview",
        *sources,
        str(root / "script/RenderPreview.swift"),
        "-o",
        str(binary),
    ],
    check=True,
)
if "--focus-diagnostic" in sys.argv:
    subprocess.run(
        [
            str(binary),
            str(root / "dist/focus-previews"),
            "--test-fixture",
            "--focus-diagnostic",
        ],
        check=True,
    )
else:
    subprocess.run(
        [str(binary), str(root / "dist/previews"), "--test-fixture"], check=True
    )
