#!/usr/bin/env python3
"""Check publication file boundaries and common private data patterns locally.

This is a guardrail, not a substitute for reviewing the exact diff. Reports
locations/categories only, never the matched secret value. No network calls.
"""
import argparse
import re
import subprocess
from pathlib import Path
from package_source import PUBLIC_FILES, ROOT

SYNTHETIC_PNG_SHA256 = {
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testDashboardLightAndDark.dashboard-light.png": "9e7211478398860b90f2d62fca4c84b7cc590d38a1deb001cc636ba0355e0afe",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testDashboardLightAndDark.dashboard-dark.png": "5bd230f17acb18e7d6eeda0a1dbe2c8f369afbae92064ab9f5d3f9c512b0bac2",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testSettingsLightAndDark.settings-light.png": "64ea172d17a5d3be86176c4b3ede3c7b68b6f9c841709ffa92c49edfbfdfb101",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testSettingsLightAndDark.settings-dark.png": "98c5ede0f59bd9f69d064b52b3e49731b98c70447407148b1cc84a3dc1ce352b",
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--git-index", action="store_true", help="Inspect exact staged blobs instead of working files")
    args = parser.parse_args()
    if args.git_index:
        names = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().strip("\0").split("\0")
    else:
        names = PUBLIC_FILES
    patterns = {
        "private key": r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
        "access token": r"\b(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{20,})",
        "personal absolute home path": "/" + r"(?:Users|home)/[A-Za-z0-9_.-]+/",
        "credential in URL": r"https?://[^\s/\"']+:[^\s/\"']+@",
        "sensitive query value": r"[?&](?:api_key|access_token|token|password|secret)=[^\s\"'<>]+",
    }
    # Synthetic fixtures intentionally include invalid credential URLs to test rejection.
    fixture_files = {"Tests/TokenStatCoreTests/GatewayDiscoveryChecks.swift", "docs/FULL_SOURCE.md"}
    failures = []
    for name in names:
        if name not in PUBLIC_FILES:
            failures.append((name, 0, "file not on publication allowlist")); continue
        if args.git_index:
            mode = subprocess.check_output(["git", "ls-files", "--stage", "--", name], cwd=ROOT).decode().split()[0]
            if mode not in ("100644", "100755"):
                failures.append((name, 0, "non-regular tracked file")); continue
            data = subprocess.check_output(["git", "show", ":" + name], cwd=ROOT)
        else:
            path = ROOT / name
            if path.is_symlink() or not path.is_file():
                failures.append((name, 0, "missing or symbolic-link file")); continue
            data = path.read_bytes()
        if name in SYNTHETIC_PNG_SHA256:
            import hashlib
            if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                failures.append((name, 0, "reviewed synthetic PNG signature mismatch")); continue
            if hashlib.sha256(data).hexdigest() != SYNTHETIC_PNG_SHA256[name]:
                failures.append((name, 0, "reviewed synthetic PNG hash mismatch")); continue
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            failures.append((name, 0, "unexpected binary file")); continue
        for category, pattern in patterns.items():
            for match in re.finditer(pattern, text, re.IGNORECASE):
                value = match.group()
                if name in fixture_files and category in ("credential in URL", "sensitive query value"):
                    if value == "https://" + "user:password@" or value == "?" + "api_key=fixture":
                        continue
                failures.append((name, text.count("\n", 0, match.start()) + 1, category))
    for name, line, category in failures:
        print(f"FAIL {name}:{line}: {category}")
    if failures:
        raise SystemExit(1)
    print(f"PASS: {len(names)} publication files checked; no forbidden file or configured private-data pattern found")


if __name__ == "__main__":
    main()
