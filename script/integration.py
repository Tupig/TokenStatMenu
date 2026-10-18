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
    "fiveHourPresent",
    "sevenDayPresent",
    "fiveHourResetPresent",
    "sevenDayResetPresent",
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
    assert report["fiveHourPresent"] is False
    assert report["sevenDayPresent"] is False
    assert report["fiveHourResetPresent"] is False
    assert report["sevenDayResetPresent"] is False
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
    (checkout / "Resources/Info.plist").write_bytes((ROOT / "Resources/Info.plist").read_bytes())
    (checkout / "Resources/AppIcon.icns").write_bytes((ROOT / "Resources/AppIcon.icns").read_bytes())
    (checkout / "script/build_and_run.sh").write_bytes((ROOT / "script/build_and_run.sh").read_bytes())
    tools = checkout / "tools"
    tools.mkdir()
    pkill_log = checkout / "pkill-called"
    open_log = checkout / "open-called"
    swift_log = checkout / "swift-arguments"
    fake_bin = checkout / "fake-bin"
    fake_bin.mkdir()
    (fake_bin / "TokenStatMenu").write_bytes(b"synthetic-executable-fixture")

    stubs = {
        "open": "#!/bin/sh\nprintf called >> \"$V23_OPEN_LOG\"\nexit 74\n",
        "pkill": "#!/bin/sh\nprintf called >> \"$BP10_PKILL_LOG\"\nexit 0\n",
        "swift": "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$V23_SWIFT_ARGUMENT_LOG\"\nfor arg in \"$@\"; do if [ \"$arg\" = --build-system ]; then exit 73; fi; done\nfor arg in \"$@\"; do if [ \"$arg\" = --show-bin-path ]; then printf '%s\\n' \"$BP10_FAKE_BIN\"; exit 0; fi; done\nexit 0\n",
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
    environment["V23_OPEN_LOG"] = str(open_log)
    environment["V23_SWIFT_ARGUMENT_LOG"] = str(swift_log)
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
    assert completed.returncode == 0, "isolated --build-only must use default SwiftPM and complete with stubbed build tools"
    assert not open_log.exists(), "--build-only must not invoke LaunchServices"
    assert "--build-system" not in swift_log.read_text().splitlines(), "build script must use the default SwiftPM build system"
    assert not pkill_log.exists(), "--build-only must not invoke a global process-name kill"
    packaged_info = plistlib.loads((checkout / "dist/TokenStatMenu.app/Contents/Info.plist").read_bytes())
    source_info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
    assert packaged_info["CFBundleShortVersionString"] == source_info["CFBundleShortVersionString"]
    assert packaged_info["CFBundleVersion"] == source_info["CFBundleVersion"]
    assert packaged_info["CFBundleIconFile"] == "AppIcon"
    assert (checkout / "dist/TokenStatMenu.app/Contents/Resources/AppIcon.icns").read_bytes() == (ROOT / "Resources/AppIcon.icns").read_bytes()
    assert packaged_info["TokenStatSourceRevision"] == "source-export", "source-only export must not acquire a machine identity"
    assert packaged_info["TokenStatSourceState"] == "unspecified"
    assert (checkout / "dist/TokenStatMenu.app/Contents/MacOS/TokenStatMenu").read_bytes() == b"synthetic-executable-fixture"
    # An exported source folder may be unpacked below an unrelated Git repo.
    # It must keep source-export rather than embed that parent repository's HEAD.
    parent_repository = root / "synthetic-parent-repository"
    parent_repository.mkdir()
    subprocess.run(["git", "init", "--quiet", str(parent_repository)], check=True,
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["git", "-C", str(parent_repository), "-c", "user.name=Synthetic Fixture",
                    "-c", "user.email=fixture@example.test", "-c", "commit.gpgsign=false",
                    "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "--allow-empty", "-m", "Synthetic parent fixture"],
                   check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    nested_checkout = parent_repository / "exported-source"
    checkout.rename(nested_checkout)
    nested_environment = environment.copy()
    nested_environment["PATH"] = str(nested_checkout / "tools") + os.pathsep + os.environ.get("PATH", "")
    nested_environment["BP10_PKILL_LOG"] = str(nested_checkout / "pkill-called")
    nested_environment["BP10_FAKE_BIN"] = str(nested_checkout / "fake-bin")
    nested_environment["V23_OPEN_LOG"] = str(nested_checkout / "open-called")
    nested_environment["V23_SWIFT_ARGUMENT_LOG"] = str(nested_checkout / "swift-arguments")
    nested = subprocess.run(["/bin/bash", str(nested_checkout / "script/build_and_run.sh"), "--build-only"],
                            cwd=nested_checkout, env=nested_environment, stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20, check=False)
    assert nested.returncode == 0, "nested exported source must build under an unrelated Git parent"
    nested_info = plistlib.loads((nested_checkout / "dist/TokenStatMenu.app/Contents/Info.plist").read_bytes())
    assert nested_info["TokenStatSourceRevision"] == "source-export", "export must not inherit an unrelated parent Git HEAD"
    assert nested_info["TokenStatSourceState"] == "unspecified"
    assert not (nested_checkout / "pkill-called").exists()
    assert not (nested_checkout / "open-called").exists()
    for script_name in ["script/build_and_run.sh", "script/test.sh", ".github/workflows/build.yml"]:
        assert "--build-system native" not in (ROOT / script_name).read_text(), "published build/test/CI commands must not force deprecated native mode"
    print("PASS: --build-only invokes no global process kill; version and project-only source identity preserved (isolated fixtures)", flush=True)


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
