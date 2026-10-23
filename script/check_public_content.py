#!/usr/bin/env python3
"""Check publication file boundaries and common private data patterns locally.

This is a guardrail, not a substitute for reviewing the exact diff. Reports
locations/categories only, never the matched secret value. No network calls.
"""

import argparse
import hashlib
import struct
import re
import subprocess
from pathlib import Path
from package_source import PUBLIC_FILES, ROOT

# Kept independent from the packager: allowlisting a local path cannot bypass
# this publication boundary.
LOCAL_ONLY_FILES = frozenset(
    {
        "docs/FULL_SOURCE.md",
    }
)
LOCAL_ONLY_PREFIXES = (
    "docs/superpowers/",
    "governance/",
    "docs/local/",
    "reports/",
    "artifacts/",
    ".local/",
)

SYNTHETIC_PNG_SHA256 = {
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testDashboardLightAndDark.dashboard-light.png": "4f0730e13672d2bfe3eb83839a8ddd8963b2a1b62da2b5f5da59998f44e1f6b4",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testDashboardLightAndDark.dashboard-dark.png": "87dbcd12bb9e8c4389f05937f338230f5e95f88e75f6acda470f763ee56d4a43",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testSettingsLightAndDark.settings-light.png": "8c08eb7e09e42e28d7ed4097eb1f1fa9cc190126e0f24facd12e0c5c4dfe08ac",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testSettingsLightAndDark.settings-dark.png": "4a0a1af5a93f2cc6e65ab12dcf85654e50be9cc59983cc6eb78446b986376155",
}

# Original code-native assets, independently reviewed at 1024/64/32px.
# No wildcard, file extension, or directory grants a binary exception.
REVIEWED_ICON_ASSETS = {
    "Resources/AppIcon.png": (
        "png-rgba-1024",
        "664e54034f49380b3dc60d72841ec8c7d9bae142e5e20f154c8e5dfcbae1e16f",
    ),
    "Resources/AppIcon.icns": (
        "icns",
        "edfc3aa520be04f987cc6c8a273995f57bafca68603d89f8265c640d0009e980",
    ),
}


def is_local_only(name: str) -> bool:
    return name in LOCAL_ONLY_FILES or name.startswith(LOCAL_ONLY_PREFIXES)


def reviewed_icon_failure(name: str, data: bytes):
    format_name, digest = REVIEWED_ICON_ASSETS[name]
    if format_name == "png-rgba-1024":
        if (
            len(data) < 33
            or not data.startswith(b"\x89PNG\r\n\x1a\n")
            or data[8:16] != b"\x00\x00\x00\rIHDR"
            or struct.unpack(">II", data[16:24]) != (1024, 1024)
            or data[24:26] != b"\x08\x06"
        ):
            return "reviewed icon PNG format/dimensions/alpha mismatch"
    elif format_name == "icns":
        if (
            len(data) < 8
            or data[:4] != b"icns"
            or struct.unpack(">I", data[4:8])[0] != len(data)
        ):
            return "reviewed icon ICNS signature/length mismatch"
    else:
        return "unsupported reviewed icon format"
    if hashlib.sha256(data).hexdigest() != digest:
        return "reviewed icon hash mismatch"
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--git-index",
        action="store_true",
        help="Inspect exact staged blobs instead of working files",
    )
    args = parser.parse_args()
    if args.git_index:
        names = (
            subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT)
            .decode()
            .strip("\0")
            .split("\0")
        )
    else:
        names = PUBLIC_FILES
    denied = sorted({name for name in names if is_local_only(name)})
    if denied:
        for name in denied:
            print(f"FAIL {name}: local-only publication path")
        raise SystemExit(1)
    patterns = {
        "private key": r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
        "access token": r"\b(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{20,})",
        "personal absolute home path": "/" + r"(?:Users|home)/[A-Za-z0-9_.-]+/",
        "credential in URL": r"https?://[^\s/\"']+:[^\s/\"']+@",
        "sensitive query value": r"[?&](?:api_key|access_token|token|password|secret)=[^\s\"'<>]+",
    }
    # Synthetic fixtures intentionally include invalid credential URLs to test rejection.
    fixture_files = {
        "Tests/TokenStatCoreTests/GatewayDiscoveryChecks.swift",
        "Tests/TokenStatCoreTests/DirectQuotaChecks.swift",
    }
    failures = []
    for name in names:
        if name not in PUBLIC_FILES:
            failures.append((name, 0, "file not on publication allowlist"))
            continue
        if args.git_index:
            mode = (
                subprocess.check_output(
                    ["git", "ls-files", "--stage", "--", name], cwd=ROOT
                )
                .decode()
                .split()[0]
            )
            if mode not in ("100644", "100755"):
                failures.append((name, 0, "non-regular tracked file"))
                continue
            data = subprocess.check_output(["git", "show", ":" + name], cwd=ROOT)
        else:
            path = ROOT / name
            if path.is_symlink() or not path.is_file():
                failures.append((name, 0, "missing or symbolic-link file"))
                continue
            data = path.read_bytes()
        if name in REVIEWED_ICON_ASSETS:
            reason = reviewed_icon_failure(name, data)
            if reason:
                failures.append((name, 0, reason))
            continue
        if name in SYNTHETIC_PNG_SHA256:
            if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                failures.append((name, 0, "reviewed synthetic PNG signature mismatch"))
                continue
            if hashlib.sha256(data).hexdigest() != SYNTHETIC_PNG_SHA256[name]:
                failures.append((name, 0, "reviewed synthetic PNG hash mismatch"))
                continue
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            failures.append((name, 0, "unexpected binary file"))
            continue
        for category, pattern in patterns.items():
            for match in re.finditer(pattern, text, re.IGNORECASE):
                value = match.group()
                if name in fixture_files and category in (
                    "credential in URL",
                    "sensitive query value",
                ):
                    if (
                        value == "https://" + "user:password@"
                        or value == "?" + "api_key=fixture"
                    ):
                        continue
                failures.append(
                    (name, text.count("\n", 0, match.start()) + 1, category)
                )
    for name, line, category in failures:
        print(f"FAIL {name}:{line}: {category}")
    if failures:
        raise SystemExit(1)
    print(
        f"PASS: {len(names)} publication files checked; no forbidden file or configured private-data pattern found"
    )


if __name__ == "__main__":
    main()
