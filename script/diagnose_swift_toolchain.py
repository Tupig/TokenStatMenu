#!/usr/bin/env python3
"""Run a read-only CLT/Xcode comparison without publishing raw tool output."""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import re
from typing import Sequence


ROOT = Path(__file__).resolve().parents[1]
SEARCH_PATH_WARNING = re.compile(
    r"ld: warning: search path '(/Library/Developer/CommandLineTools/Developer/[^']*)' not found",
)


@dataclass(frozen=True)
class WarningClassification:
    kind: str
    count: int
    is_build_failure: bool


def classify_linker_warnings(output: str) -> WarningClassification:
    """Classify only the known missing CLT search-path linker diagnostics."""
    count = len(SEARCH_PATH_WARNING.findall(output))
    if count:
        return WarningClassification("clt_search_path_warning", count, False)
    return WarningClassification("none", 0, False)


def _safe_env(developer_dir: str | None) -> dict[str, str]:
    allowed = {"HOME", "TMPDIR", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL"}
    env = {key: value for key, value in os.environ.items() if key in allowed}
    for key in ("SDKROOT", "LIBRARY_PATH", "FRAMEWORK_PATH", "LDFLAGS", "CPATH", "DEVELOPER_DIR"):
        env.pop(key, None)
    if developer_dir:
        env["DEVELOPER_DIR"] = developer_dir
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    return env


def _run(args: Sequence[str], cwd: Path, env: dict[str, str], timeout: int, log: Path) -> tuple[int, str, float]:
    started = time.monotonic()
    try:
        completed = subprocess.run(
            list(args), cwd=cwd, env=env, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, timeout=timeout, check=False,
        )
        output = completed.stdout or ""
        code = completed.returncode
    except subprocess.TimeoutExpired as error:
        output = error.stdout if isinstance(error.stdout, str) else ""
        code = 124
    log.write_text(output, encoding="utf-8", errors="replace")
    return code, output, round(time.monotonic() - started, 3)


def _digest(path: Path) -> str | None:
    if not path.is_file():
        return None
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _version(args: Sequence[str], env: dict[str, str], scratch: Path, timeout: int) -> tuple[int, str]:
    code, output, _ = _run(args, ROOT, env, timeout, scratch / "version.log")
    first = next((line.strip() for line in output.splitlines() if line.strip()), "unknown")
    if first.startswith("xcode-select: error"):
        first = "xcodebuild unavailable under selected toolchain"
    return code, first[:160]


def _run_one(kind: str, project: Path, timeout: int) -> dict[str, object]:
    developer_dir = "/Applications/Xcode.app/Contents/Developer" if kind == "xcode" else None
    env = _safe_env(developer_dir)
    scratch = Path(tempfile.mkdtemp(prefix="tokenstat-toolchain-"))
    (scratch / "home").mkdir()
    (scratch / "tmp").mkdir()
    (scratch / "xdg-config").mkdir()
    (scratch / "xdg-data").mkdir()
    env["HOME"] = str(scratch / "home")
    env["TMPDIR"] = str(scratch / "tmp")
    env["XDG_CONFIG_HOME"] = str(scratch / "xdg-config")
    env["XDG_DATA_HOME"] = str(scratch / "xdg-data")
    original_lock = _digest(project / "Package.resolved")
    try:
        swift_code, swift_version = _version(["swift", "--version"], env, scratch, timeout)
        sdk_code, sdk_path = _version(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env, scratch, timeout)
        xcode_code, xcode_version = _version(["xcodebuild", "-version"], env, scratch, timeout)
        hello = scratch / "hello"
        hello.mkdir()
        init_code, _, _ = _run(
            ["swift", "package", "init", "--type", "executable"], hello, env, timeout, scratch / "hello-init.log"
        )
        hello_build_code = hello_run_code = 125
        hello_classification = WarningClassification("command_not_run", 0, True)
        hello_seconds = 0.0
        if init_code == 0:
            hello_build_code, hello_output, hello_seconds = _run(
                ["swift", "build", "-v"],
                hello, env, timeout, scratch / "hello-build.log",
            )
            hello_classification = classify_linker_warnings(hello_output)
            if hello_build_code == 0:
                hello_run_code, _, _ = _run(
                    ["swift", "run", "-v"],
                    hello, env, timeout, scratch / "hello-run.log",
                )
        project_copy = scratch / "project"
        shutil.copytree(
            project, project_copy,
            ignore=shutil.ignore_patterns(
                ".git", ".build", "dist", ".integration", ".xcodebuild", "__pycache__",
                ".DS_Store", "config.plist", "auth.json", ".env", ".env.*", "*.jsonl",
            ),
            symlinks=True,
        )
        if any(path.is_symlink() for path in project_copy.rglob("*")):
            raise ValueError("symlink in controlled checkout")
        lock_before = _digest(project_copy / "Package.resolved")
        project_build_code, project_output, project_seconds = _run(
            ["swift", "build", "-v", "--force-resolved-versions", "--product", "TokenStatMenu"],
            project_copy, env, timeout, scratch / "project-build.log",
        )
        project_classification = classify_linker_warnings(project_output)
        return {
            "toolchain": kind,
            "developer_dir_set": bool(developer_dir),
            "swift_exit": swift_code,
            "swift_version": swift_version,
            "sdk_exit": sdk_code,
            "sdk_version": Path(sdk_path).name if sdk_path and sdk_path != "unknown" else sdk_path,
            "xcode_exit": xcode_code,
            "xcode_version": xcode_version,
            "hello": {"init_exit": init_code, "build_exit": hello_build_code, "run_exit": hello_run_code,
                       "warning": asdict(hello_classification), "seconds": hello_seconds},
            "project": {"build_exit": project_build_code, "warning": asdict(project_classification),
                        "seconds": project_seconds},
            "package_resolved_before_sha256": lock_before,
            "package_resolved_after_sha256": _digest(project_copy / "Package.resolved"),
            "package_resolved_checkout_sha256": original_lock,
            "status": "success" if (
                swift_code == 0 and sdk_code == 0 and project_build_code == 0
                and init_code == 0 and hello_build_code == 0 and hello_run_code == 0
                and (kind == "clt" or xcode_code == 0)
                and original_lock == lock_before == _digest(project_copy / "Package.resolved")
            ) else "failed",
        }
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toolchain", choices=("clt", "xcode", "both"), default="both")
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--timeout", type=int, default=90)
    args = parser.parse_args(argv)
    if args.timeout < 5 or args.timeout > 600:
        parser.error("--timeout must be between 5 and 600 seconds")
    if args.project.is_symlink():
        parser.error("--project must not be a symbolic link")
    project = args.project.resolve()
    if not (project / "Package.swift").is_file():
        parser.error("--project must point to a Swift package checkout")
    kinds = ("clt", "xcode") if args.toolchain == "both" else (args.toolchain,)
    try:
        reports = [_run_one(kind, project, args.timeout) for kind in kinds]
    except (OSError, ValueError, subprocess.SubprocessError):
        print(json.dumps({"kind": "upstream_toolchain_diagnostic", "status": "failed", "error": "diagnostic_setup_failed"}))
        return 1
    print(json.dumps({"kind": "upstream_toolchain_diagnostic", "reports": reports}, ensure_ascii=False, sort_keys=True))
    return 0 if all(report["status"] == "success" for report in reports) else 1


if __name__ == "__main__":
    raise SystemExit(main())
