#!/usr/bin/env python3
"""Advance CFBundleVersion before a local build.

WidgetKit keys the installed extension by bundle version: overwriting an app
with the same build leaves the old extension process and timeline in place.
Local build entry points call this helper so every install carries a new build
number. Release artifacts keep the build number committed for their tag.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLISTS = ("Resources/Info.plist", "Resources/WidgetExtension-Info.plist")
BUILD_PATTERN = re.compile(
    r"(<key>CFBundleVersion</key>\s*<string>)([0-9]+)(</string>)"
)
VERSION_PATTERN = re.compile(
    r"<key>CFBundleShortVersionString</key>\s*<string>([^<]+)</string>"
)
MAX_BUILD = 2_147_483_647


def _single(pattern: re.Pattern[str], text: str, path: Path):
    matches = pattern.findall(text)
    if len(matches) != 1:
        raise SystemExit(
            f"error: {path} must contain exactly one {pattern.pattern!r} match"
        )
    return matches[0]


def read_identity(root: Path) -> tuple[str, int]:
    versions: set[str] = set()
    builds: set[int] = set()
    for name in PLISTS:
        path = root / name
        if not path.is_file():
            raise SystemExit(f"error: missing {path}")
        text = path.read_text(encoding="utf-8")
        version = _single(VERSION_PATTERN, text, path)
        build = int(_single(BUILD_PATTERN, text, path)[1])
        if build < 1 or build > MAX_BUILD:
            raise SystemExit(f"error: {path} has an out-of-range CFBundleVersion")
        versions.add(version)
        builds.add(build)
    if len(versions) != 1:
        raise SystemExit("error: app and widget CFBundleShortVersionString differ")
    if len(builds) != 1:
        raise SystemExit("error: app and widget CFBundleVersion differ")
    return versions.pop(), builds.pop()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    parser.add_argument(
        "--print",
        dest="print_only",
        action="store_true",
        help="print the current version and build without changing files",
    )
    args = parser.parse_args()
    root = args.root.resolve()
    version, build = read_identity(root)
    if args.print_only:
        print(f"{version} (build {build})")
        return
    if build >= MAX_BUILD:
        raise SystemExit("error: CFBundleVersion cannot be advanced further")

    new_build = build + 1
    updated: list[tuple[Path, str]] = []
    for name in PLISTS:
        path = root / name
        text = path.read_text(encoding="utf-8")
        rewritten, count = BUILD_PATTERN.subn(rf"\g<1>{new_build}\g<3>", text, count=1)
        if count != 1:
            raise SystemExit(f"error: {path} did not contain one CFBundleVersion")
        updated.append((path, rewritten))
    # Write only after both files rewrote successfully, so a malformed plist
    # cannot leave the app and widget on different build numbers.
    for path, text in updated:
        with path.open("w", encoding="utf-8", newline="") as handle:
            handle.write(text)
    print(f"build {build} -> {new_build} ({version})")


if __name__ == "__main__":
    main()
