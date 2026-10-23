#!/usr/bin/env python3
"""Compare a pure-synthetic menu workload using isolated, matching Swift builds.

Only AppModel.swift and StatusBarController.swift differ between variants:
by default the baseline comes from the compatible pre-cleanup commit and the candidate
comes from the working tree. Current Core and other App sources are shared.
No SwiftPM cache, installed app, external request or local business data is used.
Run from any directory: python3 script/benchmark_menu.py [--rounds 1].
"""

import argparse
import json
import math
import platform
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "a0d7e3ef5c916d3c0159221fe6f225a337511766"
MENU_FILES = ("AppModel.swift", "StatusBarController.swift")
CORE_FILES = (
    "Configuration.swift",
    "GatewayDiscovery.swift",
    "HTTPDecoder.swift",
    "LocalCodexUsageReader.swift",
    "MetricsEngine.swift",
    "ProxyServer.swift",
    "Quota.swift",
    "RateWindow.swift",
    "StreamParser.swift",
    "TokenHubAXScanning.swift",
    "TokenHubDirectQuota.swift",
    "TokenHubQuota.swift",
    "WindowQuota.swift",
)
APP_FILES = (
    "AppModel.swift",
    "DashboardView.swift",
    "PanelStyle.swift",
    "SettingsView.swift",
    "StatusBarController.swift",
    "Storage.swift",
    "TokenHubAXReader.swift",
    "TokenHubQuotaCard.swift",
    "WindowQuotaCard.swift",
    "WidgetSnapshotPublisher.swift",
)
WIDGET_FILES = (
    "WidgetQuotaSnapshot.swift",
    "WidgetSnapshotCodec.swift",
    "WidgetSnapshotStore.swift",
)


def command(arguments, stage):
    """Capture compiler output so normal reports contain no temporary paths."""
    result = subprocess.run(arguments, cwd=ROOT, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError(
            f"{stage} failed; check the selected full Xcode toolchain and source compatibility"
        )
    return result.stdout


def checked_source(directory, name):
    path = ROOT / "Sources" / directory / name
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("a required regular source file is unavailable")
    return path


def bounded_integer(value, upper):
    number = int(value)
    if not 1 <= number <= upper:
        raise argparse.ArgumentTypeError(f"must be between 1 and {upper}")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--baseline",
        default=BASELINE,
        help="local baseline commit; changes only the two menu source files",
    )
    parser.add_argument(
        "--rounds", type=lambda value: bounded_integer(value, 10), default=3
    )
    parser.add_argument(
        "--iterations",
        type=lambda value: bounded_integer(value, 1_000_000),
        default=10_000,
    )
    args = parser.parse_args()
    architecture = platform.machine()
    if sys.platform != "darwin" or architecture not in ("arm64", "x86_64"):
        raise RuntimeError(
            "this native AppKit benchmark requires an Apple Silicon or Intel Mac"
        )
    revision = (
        command(
            [
                "git",
                "rev-parse",
                "--verify",
                "--end-of-options",
                args.baseline + "^{commit}",
            ],
            "baseline resolution",
        )
        .decode()
        .strip()
    )
    swiftc = command(["xcrun", "--find", "swiftc"], "Swift discovery").decode().strip()
    sdk = (
        command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "SDK discovery")
        .decode()
        .strip()
    )
    # Identical SDK, target, optimization and module flags for both variants.
    flags = [
        "-target",
        architecture + "-apple-macosx13.0",
        "-sdk",
        sdk,
        "-Onone",
        "-parse-as-library",
    ]
    with tempfile.TemporaryDirectory(
        prefix="TokenStatMenu-synthetic-benchmark-"
    ) as temporary:
        workspace = Path(temporary)
        core = workspace / "core"
        core.mkdir()
        command(
            [
                swiftc,
                *flags,
                "-module-name",
                "TokenStatCore",
                "-emit-module",
                "-emit-module-path",
                str(core / "TokenStatCore.swiftmodule"),
                "-emit-library",
                *(str(checked_source("TokenStatCore", name)) for name in CORE_FILES),
                "-lsqlite3",
                "-o",
                str(core / "libTokenStatCore.dylib"),
            ],
            "isolated Core compilation",
        )
        command(
            [
                swiftc,
                *flags,
                "-module-name",
                "TokenStatWidgetShared",
                "-emit-module",
                "-emit-module-path",
                str(core / "TokenStatWidgetShared.swiftmodule"),
                "-emit-library",
                *(
                    str(checked_source("TokenStatWidgetShared", name))
                    for name in WIDGET_FILES
                ),
                "-o",
                str(core / "libTokenStatWidgetShared.dylib"),
            ],
            "isolated widget compilation",
        )
        reports = {}
        for variant in ("baseline", "current"):
            directory = workspace / variant
            directory.mkdir()
            sources = []
            for name in APP_FILES:
                if variant == "baseline" and name in MENU_FILES:
                    path = directory / name
                    path.write_bytes(
                        command(
                            [
                                "git",
                                "show",
                                revision + ":Sources/TokenStatMenu/" + name,
                            ],
                            "baseline source extraction",
                        )
                    )
                else:
                    path = checked_source("TokenStatMenu", name)
                sources.append(str(path))
            linkage = [
                "-I",
                str(core),
                "-L",
                str(core),
                "-lTokenStatCore",
                "-lTokenStatWidgetShared",
                "-Xlinker",
                "-rpath",
                "-Xlinker",
                str(core),
            ]
            command(
                [
                    swiftc,
                    *flags,
                    "-enable-testing",
                    "-D",
                    "SWIFT_PACKAGE",
                    "-module-name",
                    "TokenStatMenu",
                    "-emit-module",
                    "-emit-module-path",
                    str(directory / "TokenStatMenu.swiftmodule"),
                    "-emit-library",
                    *linkage,
                    *sources,
                    "-lsqlite3",
                    "-o",
                    str(directory / "libTokenStatMenu.dylib"),
                ],
                "isolated menu compilation",
            )
            binary = directory / "benchmark-menu"
            command(
                [
                    swiftc,
                    *flags,
                    "-I",
                    str(directory),
                    *linkage,
                    str(ROOT / "script/BenchmarkMenu.swift"),
                    "-L",
                    str(directory),
                    "-lTokenStatMenu",
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    str(directory),
                    "-o",
                    str(binary),
                ],
                "synthetic harness compilation",
            )
            reports[variant] = []
            for round_index in range(args.rounds):
                output = command(
                    [str(binary), str(args.iterations)], "synthetic workload"
                )
                if len(output) > 4096:
                    raise RuntimeError("unexpected synthetic workload output")
                report = json.loads(output)
                if (
                    set(report) != {"iterations", "elapsedMS", "objectWillChange"}
                    or report["iterations"] != args.iterations
                    or type(report["objectWillChange"]) is not int
                    or not 0 <= report["objectWillChange"] <= args.iterations * 10
                    or type(report["elapsedMS"]) not in (int, float)
                    or not math.isfinite(report["elapsedMS"])
                    or report["elapsedMS"] < 0
                ):
                    raise RuntimeError("unexpected synthetic measurement schema")
                reports[variant].append(report["elapsedMS"])
                print(
                    json.dumps(
                        {"variant": variant, "round": round_index + 1, **report},
                        sort_keys=True,
                    ),
                    flush=True,
                )
        print(
            json.dumps(
                {
                    "baselineMedianMS": statistics.median(reports["baseline"]),
                    "currentMedianMS": statistics.median(reports["current"]),
                },
                sort_keys=True,
            )
        )


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired):
        print(
            "Synthetic menu benchmark could not complete; verify local Git sources and the selected full Xcode toolchain.",
            file=sys.stderr,
        )
        raise SystemExit(1) from None
