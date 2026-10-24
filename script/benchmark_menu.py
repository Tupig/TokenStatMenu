#!/usr/bin/env python3
"""Compare a pure-synthetic menu workload using isolated, matching Swift builds.

Only AppModel.swift, DashboardView.swift and LocalCodexUsageReader.swift differ:
the baseline comes from the exact selected commit and the candidate from the working
tree. Other sources are snapshotted once and shared. Both variants use Release -O.
No SwiftPM cache, installed app, external request or local business data is used.
Run from any directory: python3 script/benchmark_menu.py [--rounds 1].
"""

import argparse
import json
import math
import os
import platform
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "fcffb94"
MENU_FILES = ("AppModel.swift", "DashboardView.swift")
VARIANT_CORE_FILES = ("LocalCodexUsageReader.swift",)
BUILD_ENV = None
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
    result = subprocess.run(
        arguments, cwd=ROOT, env=BUILD_ENV, capture_output=True, timeout=240
    )
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
        help="local baseline commit; changes only the three optimization source files",
    )
    parser.add_argument(
        "--rounds", type=lambda value: bounded_integer(value, 10), default=3
    )
    parser.add_argument(
        "--iterations",
        type=lambda value: bounded_integer(value, 1_000_000),
        default=10_000,
    )
    parser.add_argument(
        "--scan-iterations", type=lambda value: bounded_integer(value, 100), default=5
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
        "-O",
        "-parse-as-library",
    ]
    with tempfile.TemporaryDirectory(
        prefix="TokenStatMenu-synthetic-benchmark-"
    ) as temporary:
        workspace = Path(temporary)
        global BUILD_ENV
        BUILD_ENV = dict(os.environ)
        for key in (
            "HOME",
            "CFFIXED_USER_HOME",
            "TMPDIR",
            "CLANG_MODULE_CACHE_PATH",
            "SWIFT_MODULECACHE_PATH",
        ):
            location = workspace / key.lower()
            location.mkdir()
            BUILD_ENV[key] = str(location)
        flags += ["-module-cache-path", str(workspace / "swift_modulecache_path")]
        shared = workspace / "sources"
        shared.mkdir()
        for group, names in (
            ("TokenStatCore", CORE_FILES),
            ("TokenStatMenu", APP_FILES),
            ("TokenStatWidgetShared", WIDGET_FILES),
        ):
            destination = shared / group
            destination.mkdir()
            for name in names:
                (destination / name).write_bytes(
                    checked_source(group, name).read_bytes()
                )
        harness = workspace / "BenchmarkMenu.swift"
        harness.write_bytes((ROOT / "script/BenchmarkMenu.swift").read_bytes())
        widget = workspace / "widget"
        widget.mkdir()
        command(
            [
                swiftc,
                *flags,
                "-module-name",
                "TokenStatWidgetShared",
                "-emit-module",
                "-emit-module-path",
                str(widget / "TokenStatWidgetShared.swiftmodule"),
                "-emit-library",
                *(
                    str(shared / "TokenStatWidgetShared" / name)
                    for name in WIDGET_FILES
                ),
                "-o",
                str(widget / "libTokenStatWidgetShared.dylib"),
            ],
            "isolated widget compilation",
        )
        reports = {}
        binaries = {}
        for variant in ("baseline", "current"):
            directory = workspace / variant
            directory.mkdir()
            core = directory / "core"
            core.mkdir()
            core_sources = []
            for name in CORE_FILES:
                path = shared / "TokenStatCore" / name
                if variant == "baseline" and name in VARIANT_CORE_FILES:
                    path = core / name
                    path.write_bytes(
                        command(
                            [
                                "git",
                                "show",
                                revision + ":Sources/TokenStatCore/" + name,
                            ],
                            "baseline Core source extraction",
                        )
                    )
                core_sources.append(str(path))
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
                    *core_sources,
                    "-lsqlite3",
                    "-o",
                    str(core / "libTokenStatCore.dylib"),
                ],
                "isolated Core compilation",
            )
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
                    path = shared / "TokenStatMenu" / name
                sources.append(str(path))
            linkage = [
                "-I",
                str(core),
                "-I",
                str(widget),
                "-L",
                str(core),
                "-L",
                str(widget),
                "-lTokenStatCore",
                "-lTokenStatWidgetShared",
                "-Xlinker",
                "-rpath",
                "-Xlinker",
                str(core),
                "-Xlinker",
                "-rpath",
                "-Xlinker",
                str(widget),
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
                    str(harness),
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
            binaries[variant] = binary
        print(
            json.dumps(
                {
                    "baselineRevision": revision,
                    "optimization": "-O",
                    "scanCache": "new empty reader cache per scan; OS cache not purged",
                    "peakRSS": "Darwin getrusage ru_maxrss bytes; whole workload process",
                }
            ),
            flush=True,
        )
        evidence = {}
        for round_index in range(args.rounds):
            # Alternate order to reduce systematic thermal / filesystem-cache bias.
            order = (
                ("baseline", "current")
                if round_index % 2 == 0
                else ("current", "baseline")
            )
            for workload in ("tick", "monthly", "scan"):
                iterations = (
                    args.scan_iterations if workload == "scan" else args.iterations
                )
                for variant in order:
                    output = command(
                        [str(binaries[variant]), workload, str(iterations)],
                        "synthetic workload",
                    )
                    if len(output) > 16384:
                        raise RuntimeError("unexpected synthetic workload output")
                    report = json.loads(output)
                    if (
                        set(report)
                        != {
                            "iterations",
                            "workload",
                            "elapsedMS",
                            "peakRSSBytes",
                            "evidence",
                        }
                        or report["iterations"] != iterations
                        or report["workload"] != workload
                        or type(report["peakRSSBytes"]) is not int
                        or report["peakRSSBytes"] <= 0
                        or type(report["elapsedMS"]) not in (int, float)
                        or not math.isfinite(report["elapsedMS"])
                        or report["elapsedMS"] < 0
                        or not isinstance(report["evidence"], dict)
                    ):
                        raise RuntimeError("unexpected synthetic measurement schema")
                    if (
                        workload in evidence
                        and evidence[workload] != report["evidence"]
                    ):
                        raise RuntimeError("baseline/current behavior evidence differs")
                    evidence[workload] = report["evidence"]
                    reports.setdefault((variant, workload), []).append(report)
                    print(
                        json.dumps(
                            {"variant": variant, "round": round_index + 1, **report},
                            sort_keys=True,
                        ),
                        flush=True,
                    )
        for workload in ("tick", "monthly", "scan"):
            summary = {"workload": workload, "behaviorIdentical": True}
            for variant in ("baseline", "current"):
                measurements = reports[(variant, workload)]
                times = [item["elapsedMS"] for item in measurements]
                peaks = [item["peakRSSBytes"] for item in measurements]
                summary[variant] = {
                    "medianMS": statistics.median(times),
                    "minMS": min(times),
                    "maxMS": max(times),
                    "medianPeakRSSBytes": statistics.median(peaks),
                    "minPeakRSSBytes": min(peaks),
                    "maxPeakRSSBytes": max(peaks),
                }
            print(json.dumps(summary, sort_keys=True), flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired):
        print(
            "Synthetic menu benchmark could not complete; verify local Git sources and the selected full Xcode toolchain.",
            file=sys.stderr,
        )
        raise SystemExit(1) from None
