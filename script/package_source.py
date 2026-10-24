#!/usr/bin/env python3
"""Build the reviewed source archive or explicitly export the reviewed files."""

import argparse
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PUBLIC_FILES = [
    ".gitignore",
    ".github/workflows/ci.yml",
    "Package.swift",
    "Package.resolved",
    "README.md",
    "LICENSE",
    "Sources/TokenStatCore/Configuration.swift",
    "Sources/TokenStatCore/GatewayDiscovery.swift",
    "Sources/TokenStatCore/HTTPDecoder.swift",
    "Sources/TokenStatCore/LocalCodexUsageReader.swift",
    "Sources/TokenStatCore/MetricsEngine.swift",
    "Sources/TokenStatCore/ProxyServer.swift",
    "Sources/TokenStatCore/Quota.swift",
    "Sources/TokenStatCore/WindowQuota.swift",
    "Sources/TokenStatCore/RateWindow.swift",
    "Sources/TokenStatCore/StreamParser.swift",
    "Sources/TokenStatCore/TokenHubQuota.swift",
    "Sources/TokenStatCore/TokenHubAXScanning.swift",
    "Sources/TokenStatCore/TokenHubDirectQuota.swift",
    "Sources/TokenStatMenu/AppModel.swift",
    "Sources/TokenStatMenu/DashboardView.swift",
    "Sources/TokenStatMenu/SettingsView.swift",
    "Sources/TokenStatMenu/StatusBarController.swift",
    "Sources/TokenStatMenu/Storage.swift",
    "Sources/TokenStatMenu/TokenStatMenuApp.swift",
    "Sources/TokenStatMenu/PanelStyle.swift",
    "Sources/TokenStatMenu/WindowQuotaCard.swift",
    "Sources/TokenStatMenu/TokenHubAXReader.swift",
    "Sources/TokenStatMenu/TokenHubQuotaCard.swift",
    "Sources/TokenStatMenu/WidgetSnapshotPublisher.swift",
    "Sources/TokenStatWidgetShared/WidgetQuotaSnapshot.swift",
    "Sources/TokenStatWidgetShared/WidgetSnapshotCodec.swift",
    "Sources/TokenStatWidgetShared/WidgetSnapshotStore.swift",
    "Sources/TokenStatWidgetExtension/TokenStatWidget.swift",
    "Sources/TokenStatWidgetExtension/WidgetEntryView.swift",
    "Sources/TokenStatDevWidgetShared/WidgetSnapshot.swift",
    "Sources/TokenStatDevWidgetShared/WidgetSnapshotStore.swift",
    "Sources/TokenStatDevWidgetShared/DevProbeAudit.swift",
    "Sources/TokenStatDevWidgetShared/DevProbeRunner.swift",
    "Sources/TokenStatDevWidgetExtension/DevProvider.swift",
    "Tests/TokenStatDevWidgetLogicTests/DevWidgetProductTests.swift",
    "TokenStatMenu.xcodeproj/xcshareddata/xcschemes/TokenStatDevWidgetLogicTests.xcscheme",
    "Sources/TokenStatDevWidgetHost/main.swift",
    "Sources/TokenStatDevWidgetExtension/DevWidget.swift",
    "Tests/TokenStatWidgetSharedTests/WidgetSnapshotCodecTests.swift",
    "Tests/TokenStatWidgetSharedTests/WidgetSnapshotStoreTests.swift",
    "Tests/TokenStatWidgetSharedTests/WidgetPublishDecisionTests.swift",
    "Tests/TokenStatWidgetSharedTests/WidgetPublisherFailureTests.swift",
    "Tests/TokenStatWidgetUITests/WidgetEntryViewTests.swift",
    "Tests/TokenStatDevWidgetSharedTests/DevWidgetProbeTests.swift",
    "Resources/Info.plist",
    "Resources/config.example.plist",
    "Resources/AppIcon.png",
    "Resources/AppIcon.icns",
    "TokenStatMenu.xcodeproj/project.pbxproj",
    "TokenStatMenu.xcodeproj/xcshareddata/xcschemes/TokenStatMenu.xcscheme",
    "TokenStatMenu.xcodeproj/xcshareddata/xcschemes/TokenStatMenuWidget.xcscheme",
    "TokenStatMenu.xcodeproj/xcshareddata/xcschemes/TokenStatMenuDevWidgetTest.xcscheme",
    "Resources/WidgetExtension-Info.plist",
    "Resources/WidgetExtension.entitlements",
    "Resources/TokenStatMenu.entitlements",
    "Resources/DevWidgetHost-Info.plist",
    "Resources/DevWidgetHost.entitlements",
    "Resources/DevWidgetExtension-Info.plist",
    "Resources/DevWidgetExtension.entitlements",
    "Tests/TokenStatCoreTests/CoreChecks.swift",
    "Tests/TokenStatCoreTests/GatewayDiscoveryChecks.swift",
    "Tests/TokenStatCoreTests/WindowQuotaChecks.swift",
    "Tests/TokenStatCoreTests/LocalCodexUsageChecks.swift",
    "Tests/TokenStatCoreTests/DirectQuotaChecks.swift",
    "Tests/TokenStatUITests/TokenStatUISnapshotTests.swift",
    "Tests/TokenStatCoreTests/TokenHubQuotaChecks.swift",
    "Tests/TokenStatCoreTests/ResetVoucherChecks.swift",
    "Tests/TokenStatUITests/TokenHubQuotaStateTests.swift",
    "Tests/TokenStatUITests/SeasunStartupContractTests.swift",
    "Tests/TokenStatUITests/DashboardHistoryTests.swift",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testDashboardLightAndDark.dashboard-light.png",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testDashboardLightAndDark.dashboard-dark.png",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testSettingsLightAndDark.settings-light.png",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testSettingsLightAndDark.settings-dark.png",
    "script/build_and_run.sh",
    "script/sign_developer_id.py",
    "script/test_sign_developer_id.py",
    "script/test_build_entrypoint.py",
    "script/test_release_dmg.py",
    "script/test_release_profiles.py",
    "script/verify_public_release.py",
    "script/test_verify_public_release.py",
    "script/bump_build.py",
    "script/test.sh",
    "script/integration.py",
    "script/release_assets.py",
    "script/test_release_assets.py",
    "script/BenchmarkMenu.swift",
    "script/benchmark_menu.py",
    "script/RenderAppIcon.swift",
    "script/make_app_icon.sh",
    "script/check_docs.py",
    "script/generate_xcode_project.py",
    "script/render_preview.py",
    "script/RenderPreview.swift",
    "script/package_source.py",
    "script/check_public_content.py",
    "script/diagnose_swift_toolchain.py",
    "script/run_settings_ax_check.sh",
    "script/classify_settings_ax.py",
    "script/test_phase2_diagnostics.py",
    "docs/wiki/Home.md",
    "docs/wiki/_Sidebar.md",
    "docs/wiki/_Footer.md",
    "docs/wiki/安装与使用.md",
    "docs/wiki/统计口径.md",
    "docs/wiki/常见问题.md",
    "docs/wiki/编译指南.md",
    "docs/wiki/测试指南.md",
    "docs/wiki/命令行参数.md",
    "docs/wiki/CI-CD.md",
    "docs/wiki/贡献指南.md",
]

# These paths stay local even if a future allowlist edit accidentally names them.
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


def is_local_only(name: str) -> bool:
    return name in LOCAL_ONLY_FILES or name.startswith(LOCAL_ONLY_PREFIXES)


def validate_public_files(names: list[str]) -> None:
    if len(names) != len(set(names)):
        raise SystemExit("Duplicate publication path in allowlist")
    denied = [name for name in names if is_local_only(name)]
    if denied:
        raise SystemExit("Local-only publication path rejected: " + ", ".join(denied))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--export",
        type=Path,
        help="Copy the allowlist into a new/empty publication directory",
    )
    args = parser.parse_args()
    validate_public_files(PUBLIC_FILES)
    for name in PUBLIC_FILES:
        path = ROOT / name
        if path.is_symlink() or not path.is_file():
            raise SystemExit("Missing or symbolic-link publication file: " + name)
    if args.export:
        if args.export.exists() and any(args.export.iterdir()):
            raise SystemExit("Export directory must be empty")
        for name in PUBLIC_FILES:
            target = args.export / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
    output = ROOT / "dist/TokenStatMenu-source.zip"
    output.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for name in PUBLIC_FILES:
            archive.write(ROOT / name, "TokenStatMenu/" + name)
    print(f"Packaged {len(PUBLIC_FILES)} allowlisted files")


if __name__ == "__main__":
    main()
