#!/usr/bin/env python3
"""Generate the complete source document and export only reviewed project files."""
import argparse
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PUBLIC_FILES = [
    ".gitignore", ".github/workflows/build.yml", "Package.swift", "Package.resolved", "README.md", "LICENSE", "PRIVACY.md",
    "Sources/TokenStatCore/Configuration.swift", "Sources/TokenStatCore/GatewayDiscovery.swift",
    "Sources/TokenStatCore/HTTPDecoder.swift", "Sources/TokenStatCore/LocalCodexUsageReader.swift", "Sources/TokenStatCore/MetricsEngine.swift",
    "Sources/TokenStatCore/ProxyServer.swift", "Sources/TokenStatCore/Quota.swift",
    "Sources/TokenStatCore/WindowQuota.swift", "Sources/TokenStatCore/RateWindow.swift", "Sources/TokenStatCore/StreamParser.swift",
    "Sources/TokenStatMenu/AppModel.swift", "Sources/TokenStatMenu/DashboardView.swift",
    "Sources/TokenStatMenu/QuotaClient.swift", "Sources/TokenStatMenu/SettingsView.swift",
    "Sources/TokenStatMenu/StatusBarController.swift", "Sources/TokenStatMenu/Storage.swift",
    "Sources/TokenStatMenu/TokenStatMenuApp.swift", "Sources/TokenStatMenu/PanelStyle.swift", "Sources/TokenStatMenu/WindowQuotaCard.swift",
    "Resources/Info.plist", "Resources/config.example.plist", "TokenStatMenu.xcodeproj/project.pbxproj",
    "Tests/TokenStatCoreTests/CoreChecks.swift", "Tests/TokenStatCoreTests/GatewayDiscoveryChecks.swift", "Tests/TokenStatCoreTests/WindowQuotaChecks.swift", "Tests/TokenStatCoreTests/LocalCodexUsageChecks.swift",
    "Tests/TokenStatUITests/TokenStatUISnapshotTests.swift",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testDashboardLightAndDark.dashboard-light.png",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testDashboardLightAndDark.dashboard-dark.png",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testSettingsLightAndDark.settings-light.png",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testSettingsLightAndDark.settings-dark.png",
    "script/build_and_run.sh", "script/test.sh", "script/mock_server.py", "script/integration.py",
    "script/generate_xcode_project.py", "script/render_preview.py", "script/RenderPreview.swift", "script/package_source.py", "script/check_public_content.py",
    "docs/DESIGN.md", "docs/IMPLEMENTATION.md", "docs/CONFIGURATION.md", "docs/VALIDATION.md", "docs/UI_TESTING.md", "docs/FULL_SOURCE.md",
]


def source_document():
    readme = (ROOT / "README.md").read_text()
    architecture = readme.split("## 整体架构\n", 1)[1].split("## 文件与职责", 1)[0]
    parts = ["# TokenStatMenu 完整源码\n\n## 项目整体架构\n", architecture, "\n## 分文件完整源码\n"]
    languages = {".swift": "swift", ".plist": "xml", ".pbxproj": "text", ".py": "python", ".sh": "bash", ".yml": "yaml"}
    for name in PUBLIC_FILES:
        path = ROOT / name
        if path.suffix not in languages:
            continue
        parts += [f"\n### {name}\n\n```{languages[path.suffix]}\n", path.read_text().rstrip(), "\n```\n"]
    parts += ["\n## 编译与使用\n\n", readme.split("## 构建与运行\n", 1)[1]]
    (ROOT / "docs/FULL_SOURCE.md").write_text("".join(parts))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--export", type=Path, help="Copy the allowlist into a new/empty publication directory")
    args = parser.parse_args()
    source_document()
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
