#!/usr/bin/env python3
"""Isolated BP10b startup integration for the formal Seasun-only app.

This test deliberately does not start a proxy/mock server, send inference
requests, inspect credentials, or read diagnostic values. It launches only its
own app child process against temporary plist fixtures and terminates that
exact child PID. Source call-graph review remains necessary: the optional
URLProtocol tripwire in XCTest cannot establish comprehensive network silence.
"""
from __future__ import annotations

import json
import os
import pathlib
import plistlib
import signal
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / "dist/TokenStatMenu.app"
EXECUTABLE = APP / "Contents/MacOS/TokenStatMenu"
ALLOWED_REPORT_KEYS = {
    "seasunOnlyMode",
    "backgroundServicesStarted",
    "statusItemVisible",
    "permissionPromptRequested",
    "quotaPresent",
    "directQuotaPresent",
    "directQuotaStatus",
    "resetTimePresent",
    "monthlyUsagePresent",
    "liveTokenSpeedPresent",
    "sourceStatus",
    "backgroundServiceResources",
}
EXPECTED_QUIET_RESOURCE_COUNTS = {
    "timerCount": 0,
    "workspaceObserverCount": 0,
    "localScanQueuedCount": 0,
    "axRefreshScheduledCount": 0,
    "axScanInFlightCount": 0,
}


def wait_for_report(path: pathlib.Path, process: subprocess.Popen[bytes], timeout: float = 15.0) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError("isolated app process exited before writing readiness booleans")
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(value, dict):
                return value
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            pass
        time.sleep(0.1)
    raise AssertionError("timed out waiting for isolated startup readiness booleans")


def stop_own_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        # Kill only the Popen child created by this test. Never use pkill or
        # match process names, which could terminate a user's running app.
        process.kill()
        process.wait(timeout=5)


def verify_report(report: dict) -> None:
    assert set(report) == ALLOWED_REPORT_KEYS, "diagnostics must contain only the approved readiness schema"
    assert report["seasunOnlyMode"] is True
    assert report["backgroundServicesStarted"] is False
    assert report["permissionPromptRequested"] is False
    assert report["quotaPresent"] is False
    assert report["directQuotaPresent"] is False
    assert isinstance(report["directQuotaStatus"], str) and report["directQuotaStatus"]
    assert report["resetTimePresent"] is False
    assert report["monthlyUsagePresent"] is False
    assert report["liveTokenSpeedPresent"] is False
    assert report["statusItemVisible"] is True
    assert report["sourceStatus"] in {"notConnected", "unavailable", "unknown"}
    assert report["backgroundServiceResources"] == EXPECTED_QUIET_RESOURCE_COUNTS


def fixture_cases() -> list[tuple[str, bytes | None]]:
    return [
        ("no-config", None),
        ("legacy-proxy-arbitrary-endpoint", plistlib.dumps({
            "dataSource": "proxy",
            "endpoint": "https://legacy.invalid/v1/chat/completions",
            "usageURL": "https://quota.invalid/api",
            "model": "legacy-model",
            "port": 18765,
            "monthlyLimit": 900000,
            "tokenHubAutomaticReadingEnabled": False,
        })),
        ("invalid-legacy-endpoint", plistlib.dumps({
            "dataSource": "proxy",
            "endpoint": "file:///private/legacy",
            "usageURL": "https://quota.invalid/api",
        })),
        ("malformed-plist", b"not a property list"),
        ("non-dictionary-root", plistlib.dumps(["legacy", "array"])),
    ]


def verify_build_only_never_invokes_global_kill(root: pathlib.Path) -> None:
    """Run a copy of the build-only control flow with kill/build tools stubbed.

    The pkill stub records a call and never signals any process. Thus this
    check can detect a regression without risking a user-owned app process.
    """
    checkout = root / "build-script-fixture"
    (checkout / "script").mkdir(parents=True)
    (checkout / "Resources").mkdir()
    (checkout / "Resources/Info.plist").write_bytes(b"fixture")
    (checkout / "script/build_and_run.sh").write_bytes((ROOT / "script/build_and_run.sh").read_bytes())
    tools = checkout / "tools"
    tools.mkdir()
    pkill_log = checkout / "pkill-called"
    fake_bin = checkout / "fake-bin"
    fake_bin.mkdir()

    stubs = {
        "pkill": "#!/bin/sh\nprintf called >> \"$BP10_PKILL_LOG\"\nexit 0\n",
        "swift": "#!/bin/sh\nfor arg in \"$@\"; do if [ \"$arg\" = --show-bin-path ]; then printf '%s\\n' \"$BP10_FAKE_BIN\"; exit 0; fi; done\nexit 0\n",
        "cp": "#!/bin/sh\nexit 0\n",
        "chmod": "#!/bin/sh\nexit 0\n",
        "codesign": "#!/bin/sh\nexit 0\n",
    }
    for name, content in stubs.items():
        path = tools / name
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    environment = os.environ.copy()
    environment["PATH"] = str(tools) + os.pathsep + environment.get("PATH", "")
    environment["BP10_PKILL_LOG"] = str(pkill_log)
    environment["BP10_FAKE_BIN"] = str(fake_bin)
    completed = subprocess.run(
        ["/bin/bash", str(checkout / "script/build_and_run.sh"), "--build-only"],
        cwd=checkout,
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=20,
        check=False,
    )
    assert completed.returncode == 0, "isolated --build-only control flow should complete with stubbed build tools"
    assert not pkill_log.exists(), "--build-only must not invoke a global process-name kill"
    print("PASS: --build-only invokes no global process kill (stubbed, isolated script copy)", flush=True)


def run_case(name: str, source: bytes | None, root: pathlib.Path) -> None:
    case = root / name
    case.mkdir()
    config = case / "config.plist"
    if source is not None:
        config.write_bytes(source)
    before = config.read_bytes() if config.exists() else None
    report_path = case / "readiness.json"

    process = subprocess.Popen(
        [str(EXECUTABLE), "--config", str(config), "--disable-background-services",
         "--diagnostics-output", str(report_path)],
        cwd=case,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        report = wait_for_report(report_path, process)
        verify_report(report)
        after = config.read_bytes() if config.exists() else None
        assert after == before, "startup must not rewrite, migrate, or normalize the old configuration"
    finally:
        stop_own_process(process)
    print(f"PASS: {name} (safe startup booleans; config unchanged)", flush=True)


def main() -> int:
    if not EXECUTABLE.is_file():
        raise FileNotFoundError(f"BP10b app executable is missing: {EXECUTABLE}")
    if not os.access(EXECUTABLE, os.X_OK):
        raise PermissionError("BP10b app executable is not executable")
    with tempfile.TemporaryDirectory(prefix="tokenstat-bp10-startup-") as temporary:
        root = pathlib.Path(temporary)
        verify_build_only_never_invokes_global_kill(root)
        for name, source in fixture_cases():
            run_case(name, source, root)
    print("PASS: isolated Seasun-only startup cases; no proxy fixture server or inference traffic", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
