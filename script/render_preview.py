#!/usr/bin/env python3
"""Render fixture-only light/dark dashboards and settings using actual SwiftUI code."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
sources = sorted((root / "Sources").rglob("*.swift"))
sources = [str(p) for p in sources if p.name != "TokenStatMenuApp.swift"]
binary = root / ".build/preview-renderer"
binary.parent.mkdir(exist_ok=True)
subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-module-name", "TokenStatMenuPreview", *sources, str(root / "script/RenderPreview.swift"), "-o", str(binary)], check=True)
subprocess.run([str(binary), str(root / "dist/previews"), "--test-fixture"], check=True)
