#!/usr/bin/env python3
"""Executable C26A checks. All fixtures are synthetic and private.

The API import intentionally fails until the paired implementation exists.
Native fixture success is not a substitute for the actual product build.
"""

from __future__ import annotations

import copy
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import shlex
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

from package_source import PUBLIC_FILES
import package_source as packaging
import check_public_content as public_guard
import release_assets as release

PROJECT = Path(__file__).resolve().parents[1]
TAG = "v1.1.3"
VERSION = "1.1.3"
BUILD = "5"
PUBLISH_IF = (
    "$"
    + "{{ vars.TOKENSTAT_CLOUD_RELEASE == 'enabled' && github.repository == 'Tupig/TokenStatMenu' && github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}"
)
TAG_ONLY_IF = (
    "$"
    + "{{ vars.TOKENSTAT_CLOUD_RELEASE == 'enabled' && github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}"
)
APP_FILES = {
    "Contents/Info.plist": 0o644,
    "Contents/MacOS/TokenStatMenu": 0o755,
    "Contents/Resources/AppIcon.icns": 0o644,
    "Contents/_CodeSignature/CodeResources": 0o644,
}


def run(*args: str, cwd: Path | None = None) -> str:
    environment = os.environ.copy()
    if args[0] == "git":
        # A private fixture must not execute user hooks, read signing settings,
        # inherit another index/worktree, or ask for any real credentials.
        environment = {
            key: value
            for key, value in environment.items()
            if not key.startswith("GIT_")
        }
        environment.update(
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_CONFIG_SYSTEM=os.devnull,
            GIT_TERMINAL_PROMPT="0",
        )
        args = (
            "git",
            "-c",
            "core.hooksPath=" + os.devnull,
            "-c",
            "commit.gpgsign=false",
            "-c",
            "tag.gpgsign=false",
            "-c",
            "gc.auto=0",
            "-c",
            "maintenance.auto=false",
            *args[1:],
        )
    result = subprocess.run(
        args, cwd=cwd, env=environment, text=True, capture_output=True, check=True
    )
    return result.stdout.strip()


def write_zip(path: Path, entries: list[tuple[str, bytes, int]]) -> None:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data, mode in entries:
            item = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            item.create_system = 3
            item.external_attr = mode << 16
            archive.writestr(item, data)


def zip_entries(path: Path) -> list[tuple[str, bytes, int]]:
    with zipfile.ZipFile(path) as archive:
        return [
            (item.filename, archive.read(item), item.external_attr >> 16)
            for item in archive.infolist()
        ]


class Fixture:
    def __init__(self) -> None:
        self.version = VERSION
        self.build = BUILD
        self.tag = TAG
        self.temporary = tempfile.TemporaryDirectory(
            prefix="tokenstat-release-fixture-"
        )
        self.base = Path(self.temporary.name)
        self.root = self.base / "source"
        self.root.mkdir()
        # Use actual reviewed file bytes and modes, without any real user data.
        for name in PUBLIC_FILES:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(PROJECT / name, target)
        self.source_info = plistlib.loads(
            (self.root / "Resources/Info.plist").read_bytes()
        )
        self.source_info["CFBundleShortVersionString"] = self.version
        self.source_info["CFBundleVersion"] = self.build
        (self.root / "Resources/Info.plist").write_bytes(
            plistlib.dumps(self.source_info)
        )
        run("git", "init", "--quiet", "--initial-branch=main", cwd=self.root)
        run("git", "config", "user.name", "Synthetic Release Fixture", cwd=self.root)
        run(
            "git",
            "config",
            "user.email",
            "release-fixture@example.invalid",
            cwd=self.root,
        )
        run("git", "add", "--all", cwd=self.root)
        run(
            "git", "commit", "--quiet", "-m", "Synthetic release fixture", cwd=self.root
        )
        self.commit = run("git", "rev-parse", "HEAD", cwd=self.root)
        run("git", "update-ref", "refs/remotes/origin/main", self.commit, cwd=self.root)
        run("git", "tag", self.tag, cwd=self.root)
        self.identity = release.ReleaseIdentity(
            self.version, self.build, self.tag, self.commit
        )
        self.source_zip = self.base / "source.zip"
        self.source_entries = []
        for name in PUBLIC_FILES:
            file = self.root / name
            self.source_entries.append(
                (
                    "TokenStatMenu/" + name,
                    file.read_bytes(),
                    stat.S_IFREG | stat.S_IMODE(file.stat().st_mode),
                )
            )
        write_zip(self.source_zip, self.source_entries)
        self.app = self.base / "TokenStatMenu.app"
        info = dict(
            self.source_info,
            TokenStatSourceRevision=self.commit,
            TokenStatSourceState="clean",
        )
        contents = {
            "Contents/Info.plist": plistlib.dumps(info),
            "Contents/MacOS/TokenStatMenu": b"synthetic-native-payload",
            "Contents/Resources/AppIcon.icns": (
                self.root / "Resources/AppIcon.icns"
            ).read_bytes(),
            "Contents/_CodeSignature/CodeResources": b"synthetic-signature-resource",
        }
        for name, data in contents.items():
            file = self.app / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(data)
            file.chmod(APP_FILES[name])
        self.assets = self.base / "assets"

    def close(self) -> None:
        self.temporary.cleanup()

    def source_archive(self, entries: list[tuple[str, bytes, int]]) -> None:
        write_zip(self.source_zip, entries)

    def synthetic_assets(self) -> dict:
        """Independent file-format fixture; no production packager is called."""
        self.assets.mkdir()
        app_name = f"TokenStatMenu-{self.version}-universal.zip"
        source_name = f"TokenStatMenu-{self.version}-source.zip"
        app_entries = [
            (
                "TokenStatMenu.app/" + name,
                (self.app / name).read_bytes(),
                stat.S_IFREG | mode,
            )
            for name, mode in APP_FILES.items()
        ]
        write_zip(self.assets / app_name, app_entries)
        shutil.copy2(self.source_zip, self.assets / source_name)
        manifest = {
            "version": self.version,
            "build": self.build,
            "tag": self.tag,
            "commit": self.commit,
            "assets": {},
        }
        for kind, name in [("universal", app_name), ("source", source_name)]:
            data = (self.assets / name).read_bytes()
            manifest["assets"][kind] = {
                "name": name,
                "bytes": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
            }
        (self.assets / "release-manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n"
        )
        self.refresh_sums()
        return manifest

    def refresh_sums(self) -> None:
        names = [
            f"TokenStatMenu-{self.version}-universal.zip",
            f"TokenStatMenu-{self.version}-source.zip",
            "release-manifest.json",
        ]
        (self.assets / "SHA256SUMS").write_text(
            "".join(
                hashlib.sha256((self.assets / name).read_bytes()).hexdigest()
                + "  "
                + name
                + "\n"
                for name in sorted(names)
            )
        )

    def mutate_manifest(self, change) -> None:
        file = self.assets / "release-manifest.json"
        value = json.loads(file.read_text())
        change(value)
        file.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        self.refresh_sums()


class FakeClient:
    """Only network transport is replaced; production state logic is exercised."""

    def __init__(
        self,
        fixture: Fixture,
        draft: bool | None = None,
        existing: list[str] | None = None,
        failure: str | None = None,
        final_readback: str | None = None,
    ) -> None:
        self.fixture = fixture
        self.tag_commit = fixture.commit
        self.remote = (
            None
            if draft is None
            else {"id": 7, "tag": TAG, "draft": draft, "prerelease": False}
        )
        self.assets = (
            {}
            if existing is None
            else {name: (fixture.assets / name).read_bytes() for name in existing}
        )
        self.calls: list[tuple] = []
        self.mutations: list[tuple] = []
        self.failure = failure
        self.final_readback = final_readback
        self.after_publish = False

    def record(self, name: str, *args, mutation: bool = False) -> None:
        self.calls.append((name, *args))
        if mutation:
            self.mutations.append((name, *args))
        if self.failure == name:
            raise RuntimeError("synthetic transport failure: " + name)

    def resolve_tag(self, tag: str) -> str:
        self.record("resolve_tag", tag)
        return self.tag_commit

    def lookup(self, tag: str) -> dict | None:
        self.record("lookup", tag)
        if self.after_publish and self.final_readback == "lookup-failed":
            raise RuntimeError("synthetic final lookup failure")
        result = copy.deepcopy(self.remote)
        if self.after_publish and self.final_readback == "still-draft":
            result["draft"] = True
        if self.after_publish and self.final_readback == "wrong-tag":
            result["tag"] = "v9.9.9"
        if self.after_publish and self.final_readback == "prerelease":
            result["prerelease"] = True
        return result

    def list_assets(self, release_id: int) -> list[str]:
        self.record("list_assets", release_id)
        return list(self.assets)

    def create_draft(self, identity) -> dict:
        self.record("create_draft", identity.tag, mutation=True)
        self.remote = {"id": 7, "tag": identity.tag, "draft": True, "prerelease": False}
        return copy.deepcopy(self.remote)

    def upload(self, release_id: int, path: Path) -> None:
        self.record("upload", Path(path).name, mutation=True)
        assert Path(path).name not in self.assets, "client must not clobber"
        self.assets[Path(path).name] = Path(path).read_bytes()

    def download(self, release_id: int, name: str) -> bytes:
        self.record("download", name)
        return self.assets[name]

    def publish(self, release_id: int) -> None:
        self.record("publish", release_id, mutation=True)
        self.remote["draft"] = False
        self.after_publish = True


class ReleaseChecks(unittest.TestCase):
    def test_widget_group_validation_matches_runtime_and_build(self):
        valid = [
            "group.tokenstat.menu",
            "AB12CD34EF.com.example.TokenStatMenu",
            "group." + "a" * 122,
        ]
        invalid = [
            "",
            "group.",
            "group.a..b",
            "group.a/../b",
            "group.-a",
            "group.a-",
            "group.a.-b",
            "group.a-.b",
            "FICTEAM123.example",
            "ab12cd34ef.example",
            "AB12CD34E.example",
            "AB12CD34EF.",
            "com.seasun.tokenhub.desktop",
            "$(TOKENSTAT_WIDGET_GROUP)",
            "group." + "a" * 123,
        ]
        script = (PROJECT / "script/build_and_run.sh").read_text()
        condition = next(
            line.strip()[3:-6]
            for line in script.splitlines()
            if line.strip().startswith('if ! [[ "$GROUP" =~')
        )
        for value in valid + invalid:
            expected = value in valid
            self.assertEqual(
                release.GROUP_PATTERN.fullmatch(value) is not None, expected, value
            )
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'GROUP="$1"; if ' + condition + "; then exit 1; fi",
                    "check",
                    value,
                ],
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0 if expected else 1, value)

    def setUp(self) -> None:
        self.fixture = Fixture()
        self.addCleanup(self.fixture.close)

    def reject_source(self, entries) -> None:
        self.fixture.source_archive(entries)
        with self.assertRaises(ValueError):
            release.validate_source_archive(
                self.fixture.root, self.fixture.source_zip, PUBLIC_FILES
            )

    def test_fixture_git_explicitly_disables_hooks_and_signing(self):
        f = self.fixture
        self.assertEqual(
            run("git", "config", "--get", "core.hooksPath", cwd=f.root), os.devnull
        )
        self.assertEqual(
            run("git", "config", "--get", "commit.gpgsign", cwd=f.root), "false"
        )
        self.assertEqual(
            run("git", "config", "--get", "tag.gpgsign", cwd=f.root), "false"
        )

    def test_identity_accepts_real_lightweight_and_annotated_tags(self):
        f = self.fixture
        self.assertEqual(release.release_identity(f.root, TAG, f.commit), f.identity)
        run("git", "tag", "-d", TAG, cwd=f.root)
        run("git", "tag", "-a", TAG, "-m", "Synthetic annotated release", cwd=f.root)
        self.assertEqual(release.release_identity(f.root, TAG, f.commit), f.identity)

    def test_identity_rejects_malformed_and_shell_special_tags(self):
        f = self.fixture
        marker = f.base / "unexpected-marker"
        for tag in [
            "1.1.3",
            "v01.1.3",
            "v1.1",
            "v1.1.3-rc.1",
            "v1.1.3;false",
            "v1.1.3\n",
            f"v1.1.3; touch {marker}",
            f"v1.1.3$(touch {marker})",
        ]:
            with self.subTest(tag=repr(tag)), self.assertRaises(ValueError):
                release.release_identity(f.root, tag, f.commit)
        self.assertFalse(marker.exists())

    def test_identity_rejects_wrong_commit_or_info_and_non_main_history(self):
        f = self.fixture
        with self.assertRaises(ValueError):
            release.release_identity(f.root, TAG, "a" * 40)
        run("git", "update-ref", "-d", "refs/remotes/origin/main", cwd=f.root)
        with self.assertRaises(ValueError):
            release.release_identity(f.root, TAG, f.commit)
        run("git", "update-ref", "refs/remotes/origin/main", f.commit, cwd=f.root)
        info = dict(f.source_info, CFBundleShortVersionString="9.9.9")
        (f.root / "Resources/Info.plist").write_bytes(plistlib.dumps(info))
        run("git", "add", "Resources/Info.plist", cwd=f.root)
        run("git", "commit", "--quiet", "-m", "Synthetic version mismatch", cwd=f.root)
        commit = run("git", "rev-parse", "HEAD", cwd=f.root)
        run("git", "tag", "-f", TAG, commit, cwd=f.root)
        run("git", "update-ref", "refs/remotes/origin/main", commit, cwd=f.root)
        with self.assertRaises(ValueError):
            release.release_identity(f.root, TAG, commit)

    def test_identity_rejects_dirty_staged_and_untracked_source(self):
        f = self.fixture
        (f.root / "README.md").write_text("synthetic changed source\n")
        with self.assertRaises(ValueError):
            release.release_identity(f.root, TAG, f.commit)
        run("git", "add", "README.md", cwd=f.root)
        with self.assertRaises(ValueError):
            release.release_identity(f.root, TAG, f.commit)
        run("git", "reset", "--hard", "HEAD", cwd=f.root)
        (f.root / "unreviewed.txt").write_text("synthetic\n")
        with self.assertRaises(ValueError):
            release.release_identity(f.root, TAG, f.commit)

    def test_identity_rejects_wrong_tag_target_and_unmerged_commit(self):
        f = self.fixture
        (f.root / "README.md").write_text("synthetic next commit\n")
        run("git", "add", "README.md", cwd=f.root)
        run("git", "commit", "--quiet", "-m", "Synthetic next commit", cwd=f.root)
        next_commit = run("git", "rev-parse", "HEAD", cwd=f.root)
        run("git", "update-ref", "refs/remotes/origin/main", next_commit, cwd=f.root)
        with self.assertRaises(ValueError):
            release.release_identity(f.root, TAG, next_commit)
        run("git", "tag", "-f", TAG, next_commit, cwd=f.root)
        run("git", "update-ref", "refs/remotes/origin/main", f.commit, cwd=f.root)
        with self.assertRaises(ValueError):
            release.release_identity(f.root, TAG, next_commit)

    def test_identity_rejects_invalid_build_metadata_after_clean_commit(self):
        f = self.fixture
        info = dict(f.source_info, CFBundleVersion="not-an-integer")
        (f.root / "Resources/Info.plist").write_bytes(plistlib.dumps(info))
        run("git", "add", "Resources/Info.plist", cwd=f.root)
        run("git", "commit", "--quiet", "-m", "Synthetic invalid build", cwd=f.root)
        commit = run("git", "rev-parse", "HEAD", cwd=f.root)
        run("git", "tag", "-f", TAG, commit, cwd=f.root)
        run("git", "update-ref", "refs/remotes/origin/main", commit, cwd=f.root)
        with self.assertRaises(ValueError):
            release.release_identity(f.root, TAG, commit)

    def test_identity_rejects_missing_tag_and_parent_repository_identity(self):
        f = self.fixture
        run("git", "tag", "-d", TAG, cwd=f.root)
        with self.assertRaises(ValueError):
            release.release_identity(f.root, TAG, f.commit)
        run("git", "tag", TAG, cwd=f.root)
        nested = f.root / "nested-export"
        nested.mkdir()
        with self.assertRaises(ValueError):
            release.release_identity(nested, TAG, f.commit)

    def test_source_archive_accepts_all_actual_commit_bytes_and_modes(self):
        f = self.fixture
        release.validate_source_archive(f.root, f.source_zip, PUBLIC_FILES)

    def test_source_archive_rejects_missing_extra_duplicate_and_hidden_members(self):
        entries = self.fixture.source_entries
        for changed in [
            entries[:-1],
            entries + [("TokenStatMenu/extra.txt", b"x", stat.S_IFREG | 0o644)],
            entries + [entries[0]],
            entries + [("TokenStatMenu/.hidden", b"x", stat.S_IFREG | 0o644)],
        ]:
            with self.subTest(count=len(changed)):
                self.reject_source(changed)

    def test_source_archive_rejects_path_escape_symlink_directory_mode_and_content(
        self,
    ):
        entries = self.fixture.source_entries
        name, data, mode = entries[0]
        for replacement in [
            ("/absolute", data, mode),
            ("TokenStatMenu/../escape", data, mode),
            (name, b"target", stat.S_IFLNK | 0o777),
            (name + "/", b"", stat.S_IFDIR | 0o755),
            (name, data, stat.S_IFREG | 0o755),
            (name, data + b"changed", mode),
        ]:
            with self.subTest(replacement=replacement[0]):
                self.reject_source([replacement, *entries[1:]])

    def test_source_archive_rejects_source_symlink_extra_tracked_and_changed_bytes(
        self,
    ):
        f = self.fixture
        target = f.root / "README.md"
        target.unlink()
        target.symlink_to(f.root / "LICENSE")
        with self.assertRaises(ValueError):
            release.validate_source_archive(f.root, f.source_zip, PUBLIC_FILES)
        target.unlink()
        run("git", "checkout", "--", "README.md", cwd=f.root)
        (f.root / "unreviewed.txt").write_text("synthetic")
        run("git", "add", "unreviewed.txt", cwd=f.root)
        with self.assertRaises(ValueError):
            release.validate_source_archive(f.root, f.source_zip, PUBLIC_FILES)
        run("git", "reset", "--hard", "HEAD", cwd=f.root)
        target.write_text("changed fixture")
        with self.assertRaises(ValueError):
            release.validate_source_archive(f.root, f.source_zip, PUBLIC_FILES)

    def test_cross_platform_assets_accept_independently_formatted_fixture(self):
        f = self.fixture
        expected = f.synthetic_assets()
        self.assertEqual(
            release.validate_assets(f.root, f.assets, f.identity), expected
        )

    def test_next_release_asset_names_add_universal_dmg_without_retroactive_legacy_asset(
        self,
    ):
        f = self.fixture
        next_identity = release.ReleaseIdentity("1.1.5", "7", "v1.1.5", f.commit)
        legacy_identity = release.ReleaseIdentity("1.1.4", "6", "v1.1.4", f.commit)
        self.assertEqual(
            release._names(next_identity),
            {
                "universal": "TokenStatMenu-1.1.5-universal.zip",
                "source": "TokenStatMenu-1.1.5-source.zip",
                "dmg": "TokenStatMenu-1.1.5-universal.dmg",
            },
        )
        self.assertNotIn("dmg", release._names(legacy_identity))
        self.assertEqual(
            release._names(release.ReleaseIdentity("1.1.7", "21", "v1.1.7", f.commit)),
            {
                "universal": "TokenStatMenu.zip",
                "source": "TokenStatMenu-source.zip",
                "dmg": "TokenStatMenu.dmg",
            },
        )

    def test_verify_and_publish_request_native_dmg_validation(self):
        f = self.fixture
        f.synthetic_assets()
        with mock.patch.object(
            release, "validate_assets", wraps=release.validate_assets
        ) as validator:
            release.publish_release(f.root, f.assets, f.identity, FakeClient(f))
            self.assertTrue(validator.call_args.kwargs["validate_dmg_image"])

        argv = [
            "release_assets.py",
            "verify",
            "--root",
            str(f.root),
            "--tag",
            f.identity.tag,
            "--commit",
            f.identity.commit,
            "--directory",
            str(f.assets),
        ]
        with (
            mock.patch.object(release, "release_identity", return_value=f.identity),
            mock.patch.object(
                release, "validate_assets", return_value={}
            ) as cli_validator,
            mock.patch.object(sys, "argv", argv),
        ):
            release.main()
        self.assertTrue(cli_validator.call_args.kwargs["validate_dmg_image"])

    def test_assets_reject_extra_hidden_missing_and_symlink(self):
        f = self.fixture
        f.synthetic_assets()
        hidden = f.assets / ".unreviewed"
        hidden.write_bytes(b"synthetic")
        with self.assertRaises(ValueError):
            release.validate_assets(f.root, f.assets, f.identity)
        hidden.unlink()
        target = f.assets / "SHA256SUMS"
        data = target.read_bytes()
        target.unlink()
        with self.assertRaises(ValueError):
            release.validate_assets(f.root, f.assets, f.identity)
        outside = f.base / "sums"
        outside.write_bytes(data)
        target.symlink_to(outside)
        with self.assertRaises(ValueError):
            release.validate_assets(f.root, f.assets, f.identity)

    def test_assets_reject_unexpected_empty_subdirectory(self):
        f = self.fixture
        f.synthetic_assets()
        (f.assets / ".unexpected-directory").mkdir()
        with self.assertRaises(ValueError):
            release.validate_assets(f.root, f.assets, f.identity)

    def test_assets_reject_manifest_identity_unknown_keys_names_and_numeric_types(self):
        f = self.fixture
        baseline = f.synthetic_assets()
        changes = [
            lambda x: x.update(commit="a" * 40),
            lambda x: x.update(version="9.9.9"),
            lambda x: x.update(build="99"),
            lambda x: x.update(tag="v9.9.9"),
            lambda x: x.update(environment="not-an-approved-key"),
            lambda x: x["assets"]["source"].update(name="../source.zip"),
            lambda x: x["assets"]["source"].update(bytes=True),
            lambda x: x["assets"]["source"].update(bytes=-1),
            lambda x: x["assets"]["source"].update(sha256="A" * 64),
            lambda x: x["assets"]["source"].update(unreviewed=True),
        ]
        for change in changes:
            with self.subTest(change=changes.index(change)):
                (f.assets / "release-manifest.json").write_text(json.dumps(baseline))
                f.mutate_manifest(change)
                with self.assertRaises(ValueError):
                    release.validate_assets(f.root, f.assets, f.identity)

    def test_assets_reject_changed_checksum_duplicate_extra_and_path_sums(self):
        f = self.fixture
        f.synthetic_assets()
        target = f.assets / "SHA256SUMS"
        baseline = target.read_text()
        for text in [
            baseline.replace(baseline[:64], "0" * 64, 1),
            baseline + baseline.splitlines()[0] + "\n",
            baseline + "0" * 64 + "  extra.txt\n",
            baseline.replace("  release-manifest.json", "  ../release-manifest.json"),
        ]:
            with self.subTest(text_length=len(text)):
                target.write_text(text)
                with self.assertRaises(ValueError):
                    release.validate_assets(f.root, f.assets, f.identity)

    def test_assets_reject_zip_bytes_even_when_manifest_and_sums_are_recomputed(self):
        f = self.fixture
        f.synthetic_assets()
        source_name = f"TokenStatMenu-{VERSION}-source.zip"
        write_zip(f.assets / source_name, f.source_entries[:-1])
        data = (f.assets / source_name).read_bytes()
        f.mutate_manifest(
            lambda x: x["assets"]["source"].update(
                bytes=len(data), sha256=hashlib.sha256(data).hexdigest()
            )
        )
        with self.assertRaises(ValueError):
            release.validate_assets(f.root, f.assets, f.identity)

    def test_assets_reject_truncated_or_duplicate_bundle_zip(self):
        f = self.fixture
        f.synthetic_assets()
        name = f"TokenStatMenu-{VERSION}-universal.zip"
        archive = f.assets / name
        baseline = archive.read_bytes()
        original = zip_entries(archive)
        for kind in ["truncated", "duplicate", "hidden", "symlink"]:
            with self.subTest(kind=kind):
                if kind == "truncated":
                    archive.write_bytes(baseline[:20])
                else:
                    changed = list(original)
                    if kind == "duplicate":
                        changed.append(original[0])
                    elif kind == "hidden":
                        changed.append(
                            ("TokenStatMenu.app/.hidden", b"x", stat.S_IFREG | 0o644)
                        )
                    else:
                        item, _, _ = changed[0]
                        changed[0] = (item, b"target", stat.S_IFLNK | 0o777)
                    write_zip(archive, changed)
                data = archive.read_bytes()
                f.mutate_manifest(
                    lambda x: x["assets"]["universal"].update(
                        bytes=len(data), sha256=hashlib.sha256(data).hexdigest()
                    )
                )
                with self.assertRaises(ValueError):
                    release.validate_assets(f.root, f.assets, f.identity)

    def test_assets_reject_zip_info_identity_even_with_recomputed_digests(self):
        f = self.fixture
        f.synthetic_assets()
        archive = f.assets / f"TokenStatMenu-{VERSION}-universal.zip"
        baseline = zip_entries(archive)
        for key, value in [
            ("TokenStatSourceRevision", "a" * 40),
            ("TokenStatSourceState", "modified"),
            ("CFBundleShortVersionString", "9.9.9"),
            ("CFBundleVersion", "99"),
        ]:
            with self.subTest(key=key):
                changed = []
                for name, data, mode in baseline:
                    if name == "TokenStatMenu.app/Contents/Info.plist":
                        info = plistlib.loads(data)
                        info[key] = value
                        data = plistlib.dumps(info)
                    changed.append((name, data, mode))
                write_zip(archive, changed)
                data = archive.read_bytes()
                f.mutate_manifest(
                    lambda x: x["assets"]["universal"].update(
                        bytes=len(data), sha256=hashlib.sha256(data).hexdigest()
                    )
                )
                with self.assertRaises(ValueError):
                    release.validate_assets(f.root, f.assets, f.identity)

    def test_publish_creates_draft_reads_back_every_asset_then_publishes(self):
        f = self.fixture
        f.synthetic_assets()
        client = FakeClient(f)
        release.publish_release(f.root, f.assets, f.identity, client)
        names = set(p.name for p in f.assets.iterdir())
        self.assertEqual(set(client.assets), names)
        self.assertFalse(client.remote["draft"])
        self.assertEqual(
            [item[0] for item in client.mutations],
            ["create_draft", "upload", "upload", "upload", "upload", "publish"],
        )
        publish_index = next(
            i for i, item in enumerate(client.calls) if item[0] == "publish"
        )
        before = {
            item[1] for item in client.calls[:publish_index] if item[0] == "download"
        }
        self.assertEqual(before, names)
        self.assertTrue(
            any(item[0] == "lookup" for item in client.calls[publish_index + 1 :])
        )

    def test_publish_identical_published_rerun_is_read_only(self):
        f = self.fixture
        f.synthetic_assets()
        client = FakeClient(
            f, draft=False, existing=[p.name for p in f.assets.iterdir()]
        )
        release.publish_release(f.root, f.assets, f.identity, client)
        self.assertEqual(client.mutations, [])
        self.assertEqual(
            {item[1] for item in client.calls if item[0] == "download"},
            set(client.assets),
        )

    def test_publish_matching_partial_draft_uploads_only_missing_assets(self):
        f = self.fixture
        f.synthetic_assets()
        client = FakeClient(f, draft=True, existing=["release-manifest.json"])
        release.publish_release(f.root, f.assets, f.identity, client)
        self.assertFalse(client.remote["draft"])
        uploaded = [item[1] for item in client.mutations if item[0] == "upload"]
        self.assertEqual(
            set(uploaded),
            {p.name for p in f.assets.iterdir()} - {"release-manifest.json"},
        )
        self.assertEqual(len(uploaded), 3)
        self.assertNotIn("create_draft", [item[0] for item in client.mutations])

    def test_existing_release_requires_explicit_false_prerelease_before_writes(self):
        f = self.fixture
        f.synthetic_assets()
        for draft in [False, True]:
            for invalid in [True, None, 0, "false", "missing"]:
                with self.subTest(draft=draft, prerelease=invalid):
                    client = FakeClient(
                        f, draft=draft, existing=[p.name for p in f.assets.iterdir()]
                    )
                    if invalid == "missing":
                        del client.remote["prerelease"]
                    else:
                        client.remote["prerelease"] = invalid
                    with self.assertRaises(ValueError):
                        release.publish_release(f.root, f.assets, f.identity, client)
                    self.assertEqual(
                        client.mutations,
                        [],
                        "never silently convert a prerelease or ambiguous release",
                    )

    def test_new_draft_requires_explicit_false_prerelease_before_uploads(self):
        f = self.fixture
        f.synthetic_assets()
        for invalid in [True, None, 0, "false", "missing"]:
            with self.subTest(prerelease=invalid):
                client = FakeClient(f)
                original = client.create_draft

                def create_invalid(identity):
                    remote = original(identity)
                    if invalid == "missing":
                        del remote["prerelease"]
                    else:
                        remote["prerelease"] = invalid
                    return remote

                client.create_draft = create_invalid
                with self.assertRaises(ValueError):
                    release.publish_release(f.root, f.assets, f.identity, client)
                self.assertEqual(
                    [item[0] for item in client.mutations], ["create_draft"]
                )
                self.assertTrue(client.remote["draft"])

    def test_github_adapter_preserves_strict_boolean_prerelease_metadata(self):
        client = release.GitHubClient(self.fixture.identity)
        baseline = {"id": 7, "tag_name": TAG, "draft": False, "prerelease": False}
        with mock.patch.object(client, "_get", return_value=baseline):
            self.assertEqual(
                client.lookup(TAG),
                {"id": 7, "tag": TAG, "draft": False, "prerelease": False},
            )
        for invalid in [None, 0, "false", "missing"]:
            value = dict(baseline)
            if invalid == "missing":
                del value["prerelease"]
            else:
                value["prerelease"] = invalid
            with (
                self.subTest(prerelease=invalid),
                mock.patch.object(client, "_get", return_value=value),
            ):
                with self.assertRaises(ValueError):
                    client.lookup(TAG)
        # A real boolean true is preserved by transport, then rejected by the
        # publisher. The adapter must never coerce any metadata to false.
        with mock.patch.object(
            client, "_get", return_value=dict(baseline, prerelease=True)
        ):
            self.assertIs(client.lookup(TAG)["prerelease"], True)

    def test_github_lookup_404_fallback_accepts_one_exact_draft_only(self):
        client = release.GitHubClient(self.fixture.identity)
        draft = {"id": 77, "tag_name": TAG, "draft": True, "prerelease": False}
        calls = []

        def get(path, *, missing=False):
            calls.append((path, missing))
            if path.endswith("/releases/tags/" + TAG):
                return None
            return [
                dict(draft),
                {"id": 78, "tag_name": "v1.1.30", "draft": True, "prerelease": False},
            ]

        with mock.patch.object(client, "_get", side_effect=get):
            self.assertEqual(
                client.lookup(TAG),
                {"id": 77, "tag": TAG, "draft": True, "prerelease": False},
            )
        self.assertEqual(
            calls,
            [
                ("repos/Tupig/TokenStatMenu/releases/tags/" + TAG, True),
                ("repos/Tupig/TokenStatMenu/releases?per_page=100", False),
            ],
        )

    def test_github_lookup_404_fallback_empty_or_unrelated_is_absent(self):
        client = release.GitHubClient(self.fixture.identity)
        for releases in [
            [],
            [{"id": 78, "tag_name": "v1.1.30", "draft": True, "prerelease": False}],
        ]:
            with (
                self.subTest(releases=releases),
                mock.patch.object(client, "_get", side_effect=[None, releases]),
            ):
                self.assertIsNone(client.lookup(TAG))

    def test_github_lookup_404_fallback_rejects_duplicate_conflicts_and_bad_lists(self):
        client = release.GitHubClient(self.fixture.identity)
        valid = {"id": 77, "tag_name": TAG, "draft": True, "prerelease": False}
        cases = [
            [valid, dict(valid, id=78)],
            [dict(valid, draft=False)],
            [dict(valid, prerelease=True)],
            [dict(valid, tag_name=TAG, draft="true")],
            [{"id": 77, "tag_name": TAG}],
            [{"id": 77, "tag_name": TAG, "draft": True, "prerelease": False}] * 100,
            {"items": [valid]},
        ]
        for releases in cases:
            with (
                self.subTest(releases=releases),
                mock.patch.object(client, "_get", side_effect=[None, releases]),
            ):
                with self.assertRaises((ValueError, RuntimeError)):
                    client.lookup(TAG)

    def test_create_draft_retries_only_post_create_visibility_miss(self):
        f = self.fixture
        sleeps = []
        commands = []
        client = release.GitHubClient(
            f.identity, visibility_retries=2, visibility_delay=0.25, sleep=sleeps.append
        )
        draft = {"id": 77, "tag": TAG, "draft": True, "prerelease": False}
        with (
            mock.patch.object(
                client,
                "_command",
                side_effect=lambda arguments, phase: commands.append(
                    (arguments, phase)
                ),
            ),
            mock.patch.object(client, "lookup", side_effect=[None, draft]) as lookup,
        ):
            self.assertEqual(client.create_draft(f.identity), draft)
        self.assertEqual(lookup.call_count, 2)
        self.assertEqual(sleeps, [0.25])
        self.assertEqual([phase for _, phase in commands], ["create-draft"])

    def test_create_draft_visibility_retry_is_bounded_and_transport_errors_do_not_retry(
        self,
    ):
        f = self.fixture
        for lookup_values, expected_sleeps in [
            ([None, None, None], [0.25, 0.25]),
            ([RuntimeError("synthetic transport")], []),
        ]:
            with self.subTest(expected_sleeps=expected_sleeps):
                sleeps = []
                commands = []
                client = release.GitHubClient(
                    f.identity,
                    visibility_retries=2,
                    visibility_delay=0.25,
                    sleep=sleeps.append,
                )
                with (
                    mock.patch.object(
                        client,
                        "_command",
                        side_effect=lambda arguments, phase: commands.append(
                            (arguments, phase)
                        ),
                    ),
                    mock.patch.object(
                        client, "lookup", side_effect=lookup_values
                    ) as lookup,
                ):
                    with self.assertRaises((ValueError, RuntimeError)):
                        client.create_draft(f.identity)
                self.assertEqual(lookup.call_count, len(lookup_values))
                self.assertEqual(sleeps, expected_sleeps)
                self.assertEqual([phase for _, phase in commands], ["create-draft"])

    def test_publish_resumes_single_fallback_draft_without_creating_release(self):
        f = self.fixture
        f.synthetic_assets()
        client = FakeClient(f, draft=True, existing=["release-manifest.json"])
        release.publish_release(f.root, f.assets, f.identity, client)
        self.assertNotIn("create_draft", [item[0] for item in client.mutations])
        self.assertFalse(client.remote["draft"])
        self.assertEqual(
            len([item for item in client.mutations if item[0] == "upload"]), 3
        )

    def test_publish_conflicts_or_retagging_never_mutate_remote_release(self):
        f = self.fixture
        f.synthetic_assets()
        names = [p.name for p in f.assets.iterdir()]
        for kind in [
            "published-content",
            "draft-content",
            "extra",
            "missing",
            "retagged",
        ]:
            with self.subTest(kind=kind):
                client = FakeClient(f, draft=(kind == "draft-content"), existing=names)
                if kind.endswith("content"):
                    client.assets[names[0]] += b"conflict"
                elif kind == "extra":
                    client.assets["unreviewed.txt"] = b"synthetic"
                elif kind == "missing":
                    del client.assets[names[0]]
                else:
                    client.tag_commit = "a" * 40
                with self.assertRaises((ValueError, RuntimeError)):
                    release.publish_release(f.root, f.assets, f.identity, client)
                self.assertEqual(client.mutations, [])

    def test_publish_rejects_invalid_local_assets_before_any_mutation(self):
        f = self.fixture
        f.synthetic_assets()
        (f.assets / "unexpected.txt").write_text("synthetic")
        client = FakeClient(f)
        with self.assertRaises(ValueError):
            release.publish_release(f.root, f.assets, f.identity, client)
        self.assertEqual(client.mutations, [])

    def test_publish_transport_failures_are_not_missing_release_or_success(self):
        f = self.fixture
        f.synthetic_assets()
        for phase in [
            "resolve_tag",
            "lookup",
            "create_draft",
            "upload",
            "download",
            "publish",
        ]:
            with self.subTest(phase=phase):
                client = FakeClient(f, failure=phase)
                with self.assertRaises((ValueError, RuntimeError)):
                    release.publish_release(f.root, f.assets, f.identity, client)
                if phase in ["resolve_tag", "lookup"]:
                    self.assertEqual(client.mutations, [])
                if phase in ["upload", "download"]:
                    self.assertTrue(client.remote["draft"])
                    self.assertNotIn("publish", [item[0] for item in client.mutations])

    def test_post_publish_readback_failures_do_not_claim_success_or_rollback(self):
        f = self.fixture
        f.synthetic_assets()
        for mode in ["lookup-failed", "still-draft", "wrong-tag", "prerelease"]:
            with self.subTest(mode=mode):
                client = FakeClient(f, final_readback=mode)
                with self.assertRaises((ValueError, RuntimeError)):
                    release.publish_release(f.root, f.assets, f.identity, client)
                self.assertTrue(client.after_publish)
                self.assertFalse(
                    client.remote["draft"],
                    "a failed readback must not pretend publication was rolled back",
                )
                self.assertEqual(client.mutations[-1][0], "publish")
                self.assertEqual(
                    [item[0] for item in client.mutations].count("publish"), 1
                )


@unittest.skipUnless(
    sys.platform == "darwin", "real private macOS signing/Universal fixture"
)
class NativeReleaseChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.native_directory = tempfile.TemporaryDirectory(
            prefix="tokenstat-native-release-check-"
        )
        cls.addClassCleanup(cls.native_directory.cleanup)
        cls.native_root = Path(cls.native_directory.name)
        source = cls.native_root / "main.swift"
        source.write_text('print("synthetic release validation")\n')
        cls.thin = cls.native_root / "thin"
        intel = cls.native_root / "intel"
        cls.universal = cls.native_root / "universal"
        run(
            "xcrun",
            "--sdk",
            "macosx",
            "swiftc",
            "-target",
            "arm64-apple-macosx13.0",
            str(source),
            "-o",
            str(cls.thin),
        )
        run(
            "xcrun",
            "--sdk",
            "macosx",
            "swiftc",
            "-target",
            "x86_64-apple-macosx13.0",
            str(source),
            "-o",
            str(intel),
        )
        run("lipo", "-create", str(cls.thin), str(intel), "-output", str(cls.universal))

    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.close)
        f = self.fixture
        shutil.copy2(self.universal, f.app / "Contents/MacOS/TokenStatMenu")
        self.sign()

    def sign(self):
        run("codesign", "--force", "--sign", "-", str(self.fixture.app))

    def test_real_private_universal_signature_and_packaging(self):
        f = self.fixture
        release.validate_app(f.root, f.app, f.identity, subprocess.run)
        release.package_assets(f.root, f.app, f.source_zip, f.assets, f.identity)
        expected = {
            f"TokenStatMenu-{VERSION}-universal.zip",
            f"TokenStatMenu-{VERSION}-source.zip",
            "release-manifest.json",
            "SHA256SUMS",
        }
        self.assertEqual({p.name for p in f.assets.iterdir()}, expected)
        release.validate_assets(f.root, f.assets, f.identity)
        with zipfile.ZipFile(
            f.assets / f"TokenStatMenu-{VERSION}-universal.zip"
        ) as archive:
            for name, mode in APP_FILES.items():
                member = archive.getinfo("TokenStatMenu.app/" + name)
                self.assertEqual(archive.read(member), (f.app / name).read_bytes())
                self.assertEqual(stat.S_IMODE(member.external_attr >> 16), mode)

    def test_release_assets_ignore_only_filesystem_and_input_zip_metadata(self):
        f = self.fixture
        release.package_assets(f.root, f.app, f.source_zip, f.assets, f.identity)
        first = {path.name: path.read_bytes() for path in f.assets.iterdir()}
        original_source_zip = f.source_zip.read_bytes()
        for file in f.app.rglob("*"):
            if file.is_file():
                original = file.stat()
                os.utime(file, (original.st_atime + 3600, original.st_mtime + 3600))
        with zipfile.ZipFile(f.source_zip, "w", zipfile.ZIP_STORED) as archive:
            archive.comment = b"synthetic source archive metadata"
            for name, data, mode in reversed(f.source_entries):
                member = zipfile.ZipInfo(name, (2026, 2, 2, 1, 2, 4))
                member.create_system = 3
                member.external_attr = mode << 16
                member.comment = b"synthetic entry metadata"
                archive.writestr(member, data)
        self.assertNotEqual(f.source_zip.read_bytes(), original_source_zip)
        second_dir = f.base / "assets-second"
        release.package_assets(f.root, f.app, f.source_zip, second_dir, f.identity)
        second = {path.name: path.read_bytes() for path in second_dir.iterdir()}
        self.assertEqual(
            first,
            second,
            "release metadata normalization must preserve deterministic four-asset bytes",
        )

    def test_real_signature_rejects_post_signing_plist_tamper(self):
        f = self.fixture
        file = f.app / "Contents/Info.plist"
        info = plistlib.loads(file.read_bytes())
        info["CFBundleDisplayName"] = "synthetic tamper"
        file.write_bytes(plistlib.dumps(info))
        result = subprocess.run(
            ["codesign", "--verify", "--deep", "--strict", str(f.app)],
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, subprocess.run)

    def test_signature_is_required_when_only_signed_executable_bytes_change(self):
        f = self.fixture
        info = (f.app / "Contents/Info.plist").read_bytes()
        icon = (f.app / "Contents/Resources/AppIcon.icns").read_bytes()
        binary = f.app / "Contents/MacOS/TokenStatMenu"
        data = bytearray(binary.read_bytes())
        offset = data.index(b"synthetic release validation")
        data[offset] ^= 1
        binary.write_bytes(data)
        self.assertEqual((f.app / "Contents/Info.plist").read_bytes(), info)
        self.assertEqual((f.app / "Contents/Resources/AppIcon.icns").read_bytes(), icon)
        self.assertEqual(
            set(run("lipo", "-archs", str(binary)).split()), {"arm64", "x86_64"}
        )
        result = subprocess.run(
            ["codesign", "--verify", "--deep", "--strict", str(f.app)],
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(
            result.returncode,
            0,
            "only the signature should distinguish this otherwise valid bundle",
        )
        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, subprocess.run)

    def test_real_thin_signed_bundle_is_not_universal(self):
        f = self.fixture
        shutil.copy2(self.thin, f.app / "Contents/MacOS/TokenStatMenu")
        self.sign()
        self.assertEqual(
            run("lipo", "-archs", str(f.app / "Contents/MacOS/TokenStatMenu")), "arm64"
        )
        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, subprocess.run)

    def test_architecture_reader_rejects_additional_unapproved_architecture(self):
        f = self.fixture

        def synthetic_tool_result(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, "arm64 x86_64 arm64e\n", "")

        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, synthetic_tool_result)

    def test_packaging_refuses_nonempty_staging_without_deleting_anything(self):
        f = self.fixture
        f.assets.mkdir()
        sentinel = f.assets / "preserve-this-file"
        sentinel.write_bytes(b"synthetic sentinel")
        with self.assertRaises(ValueError):
            release.package_assets(f.root, f.app, f.source_zip, f.assets, f.identity)
        self.assertEqual({p.name for p in f.assets.iterdir()}, {sentinel.name})
        self.assertEqual(sentinel.read_bytes(), b"synthetic sentinel")

    def test_bundle_full_tree_modes_identity_and_icon_are_enforced(self):
        f = self.fixture
        hidden = f.app / ".hidden"
        hidden.write_bytes(b"synthetic")
        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, subprocess.run)
        hidden.unlink()
        binary = f.app / "Contents/MacOS/TokenStatMenu"
        binary.chmod(0o644)
        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, subprocess.run)
        binary.chmod(0o755)
        icon = f.app / "Contents/Resources/AppIcon.icns"
        icon.write_bytes(b"synthetic wrong icon")
        self.sign()
        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, subprocess.run)

    def test_bundle_symlink_missing_resource_and_wrong_provenance_are_rejected(self):
        f = self.fixture
        resource = f.app / "Contents/_CodeSignature/CodeResources"
        saved = resource.read_bytes()
        resource.unlink()
        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, subprocess.run)
        outside = f.base / "resource"
        outside.write_bytes(saved)
        resource.symlink_to(outside)
        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, subprocess.run)
        resource.unlink()
        resource.write_bytes(saved)
        file = f.app / "Contents/Info.plist"
        info = plistlib.loads(file.read_bytes())
        info["TokenStatSourceRevision"] = "a" * 40
        info["TokenStatSourceState"] = "modified"
        file.write_bytes(plistlib.dumps(info))
        self.sign()
        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, subprocess.run)

    def test_116_requires_and_accepts_the_embedded_widget(self):
        self.check_embedded_widget("1.1.6")

    def test_117_requires_arm64_widget_and_rejects_universal(self):
        self.check_embedded_widget("1.1.7")

    def check_embedded_widget(self, version):
        f = self.fixture
        identity = release.ReleaseIdentity(version, "9", "v" + version, f.commit)
        self.assertEqual(
            release._bundle_shape(identity),
            (release.WIDGET_APP_FILES, release.WIDGET_APP_DIRECTORIES),
        )
        self.assertEqual(
            release._bundle_shape(
                release.ReleaseIdentity("1.1.5", "8", "v1.1.5", f.commit)
            ),
            (release.APP_FILES, release.APP_DIRECTORIES),
            "the published 1.1.5 shape must keep validating",
        )

        source_info = dict(
            f.source_info,
            CFBundleShortVersionString=version,
            CFBundleVersion="9",
        )
        (f.root / "Resources/Info.plist").write_bytes(plistlib.dumps(source_info))
        app_info = dict(
            source_info,
            TokenStatSourceRevision=f.commit,
            TokenStatSourceState="clean",
            TokenStatWidgetGroup="group.com.tupig.TokenStatMenu",
        )
        (f.app / "Contents/Info.plist").write_bytes(plistlib.dumps(app_info))
        (f.app / "Contents/PkgInfo").write_bytes(b"APPL????")
        (f.app / "Contents/PkgInfo").chmod(0o644)
        self.sign()

        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, identity, subprocess.run)

        widget = f.app / "Contents/PlugIns/TokenStatMenuWidget.appex"
        (widget / "Contents/MacOS").mkdir(parents=True)
        (widget / "Contents/Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleIdentifier": "com.tupig.TokenStatMenu.Widget",
                    "CFBundleExecutable": "TokenStatMenuWidget",
                    "CFBundlePackageType": "XPC!",
                    "CFBundleVersion": "9",
                    "CFBundleShortVersionString": version,
                    "TokenStatWidgetGroup": "group.com.tupig.TokenStatMenu",
                    "NSExtension": {
                        "NSExtensionPointIdentifier": "com.apple.widgetkit-extension"
                    },
                }
            )
        )
        shutil.copy2(self.universal, widget / "Contents/MacOS/TokenStatMenuWidget")
        widget_entitlements = f.root / "widget.entitlements"
        widget_entitlements.write_bytes(
            plistlib.dumps(
                {
                    "com.apple.security.app-sandbox": True,
                    "com.apple.security.application-groups": [
                        "group.com.tupig.TokenStatMenu"
                    ],
                }
            )
        )
        run(
            "codesign",
            "--force",
            "--sign",
            "-",
            "--entitlements",
            str(widget_entitlements),
            str(widget),
        )
        app_entitlements = f.root / "app.entitlements"
        app_entitlements.write_bytes(
            plistlib.dumps(
                {
                    "com.apple.security.application-groups": [
                        "group.com.tupig.TokenStatMenu"
                    ]
                }
            )
        )
        run(
            "codesign",
            "--force",
            "--sign",
            "-",
            "--entitlements",
            str(app_entitlements),
            str(f.app),
        )
        for name, mode in release.WIDGET_APP_FILES.items():
            (f.app / name).chmod(mode)
        if version == "1.1.7":
            with self.assertRaisesRegex(ValueError, "architectures differ"):
                release.validate_app(f.root, f.app, identity, subprocess.run)
            for binary in [
                f.app / "Contents/MacOS/TokenStatMenu",
                widget / "Contents/MacOS/TokenStatMenuWidget",
            ]:
                thin = binary.with_suffix(".thin")
                run("lipo", str(binary), "-thin", "arm64", "-output", str(thin))
                os.replace(thin, binary)
                binary.chmod(0o755)
            run(
                "codesign",
                "--force",
                "--sign",
                "-",
                "--entitlements",
                str(widget_entitlements),
                str(widget),
            )
            run(
                "codesign",
                "--force",
                "--sign",
                "-",
                "--entitlements",
                str(app_entitlements),
                str(f.app),
            )
        release.validate_app(f.root, f.app, identity, subprocess.run)

        # A matching version and group are not enough: the extension bundle
        # identifier is part of the contract.
        widget_info = plistlib.loads((widget / "Contents/Info.plist").read_bytes())
        widget_info["CFBundleIdentifier"] = "com.tupig.Other"
        (widget / "Contents/Info.plist").write_bytes(plistlib.dumps(widget_info))
        run(
            "codesign",
            "--force",
            "--sign",
            "-",
            "--entitlements",
            str(widget_entitlements),
            str(widget),
        )
        run(
            "codesign",
            "--force",
            "--sign",
            "-",
            "--entitlements",
            str(app_entitlements),
            str(f.app),
        )
        with self.assertRaisesRegex(ValueError, "unexpected widget extension identity"):
            release.validate_app(f.root, f.app, identity, subprocess.run)

        # An extension without the sandbox entitlement is rejected as well.
        widget_info["CFBundleIdentifier"] = "com.tupig.TokenStatMenu.Widget"
        (widget / "Contents/Info.plist").write_bytes(plistlib.dumps(widget_info))
        widget_entitlements.write_bytes(
            plistlib.dumps(
                {
                    "com.apple.security.application-groups": [
                        "group.com.tupig.TokenStatMenu"
                    ]
                }
            )
        )
        run(
            "codesign",
            "--force",
            "--sign",
            "-",
            "--entitlements",
            str(widget_entitlements),
            str(widget),
        )
        run(
            "codesign",
            "--force",
            "--sign",
            "-",
            "--entitlements",
            str(app_entitlements),
            str(f.app),
        )
        with self.assertRaisesRegex(ValueError, "widget extension entitlements differ"):
            release.validate_app(f.root, f.app, identity, subprocess.run)

        # The host application must stay unsandboxed: an accidental sandbox
        # would break the ~/.codex and sessions reads the widget relies on.
        widget_entitlements.write_bytes(
            plistlib.dumps(
                {
                    "com.apple.security.app-sandbox": True,
                    "com.apple.security.application-groups": [
                        "group.com.tupig.TokenStatMenu"
                    ],
                }
            )
        )
        run(
            "codesign",
            "--force",
            "--sign",
            "-",
            "--entitlements",
            str(widget_entitlements),
            str(widget),
        )
        app_entitlements.write_bytes(
            plistlib.dumps(
                {
                    "com.apple.security.app-sandbox": True,
                    "com.apple.security.application-groups": [
                        "group.com.tupig.TokenStatMenu"
                    ],
                }
            )
        )
        run(
            "codesign",
            "--force",
            "--sign",
            "-",
            "--entitlements",
            str(app_entitlements),
            str(f.app),
        )
        with self.assertRaisesRegex(ValueError, "application entitlements differ"):
            release.validate_app(f.root, f.app, identity, subprocess.run)


class CleanupChecks(unittest.TestCase):
    """C40 uses only synthetic publication roots, never local user material."""

    LOCAL_ONLY_FILES = ("docs/FULL_SOURCE.md",)
    LOCAL_ONLY_PREFIXES = (
        "docs/superpowers/",
        "governance/",
        "docs/local/",
        "reports/",
        "artifacts/",
        ".local/",
    )

    def synthetic_root(self) -> Path:
        temporary = tempfile.TemporaryDirectory(prefix="tokenstat-cleanup-fixture-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / "docs").mkdir()
        # The old generator can consume this too: a rejection must not arise
        # from a missing README section or output directory.
        (root / "README.md").write_text(
            "# Synthetic project\n\n## 整体架构\nSynthetic architecture.\n"
            "## 文件与职责\nSynthetic files.\n## 构建与运行\nSynthetic usage.\n"
        )
        return root

    def invoke_main(self, module, root: Path, names: list[str]) -> int:
        with (
            mock.patch.object(module, "ROOT", root),
            mock.patch.object(module, "PUBLIC_FILES", names),
            mock.patch.object(sys, "argv", [module.__name__]),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            try:
                module.main()
            except SystemExit as failure:
                return (
                    0
                    if failure.code is None
                    else int(failure.code)
                    if isinstance(failure.code, int)
                    else 1
                )
            except ValueError:
                return 1
        return 0

    def test_packager_and_guard_accept_safe_public_readme(self):
        for module in [packaging, public_guard]:
            with self.subTest(entrypoint=module.__name__):
                self.assertEqual(
                    self.invoke_main(module, self.synthetic_root(), ["README.md"]), 0
                )

    def test_both_entrypoints_reject_local_only_even_when_allowlisted(self):
        denied = list(self.LOCAL_ONLY_FILES) + [
            prefix + "synthetic-canary.md" for prefix in self.LOCAL_ONLY_PREFIXES
        ]
        for module in [packaging, public_guard]:
            for name in denied:
                with self.subTest(entrypoint=module.__name__, denied=name):
                    root = self.synthetic_root()
                    candidate = root / name
                    candidate.parent.mkdir(parents=True, exist_ok=True)
                    candidate.write_text("Synthetic local-only canary.\n")
                    self.assertNotEqual(
                        self.invoke_main(module, root, ["README.md", name]),
                        0,
                        "Adding a local-only path to PUBLIC_FILES cannot authorize it",
                    )

    def test_default_packaging_preserves_tracked_bytes_modes_and_git_state(self):
        root = self.synthetic_root()
        (root / ".gitignore").write_text("dist/\n")
        (root / "docs/wiki").mkdir()
        (root / "docs/wiki/Home.md").write_text(
            "# Synthetic validation\nUnchanged sentinel.\n"
        )
        names = ["README.md", ".gitignore", "docs/wiki/Home.md"]
        run("git", "init", "--quiet", "--initial-branch=main", cwd=root)
        run("git", "config", "user.name", "Synthetic Cleanup Fixture", cwd=root)
        run("git", "config", "user.email", "cleanup-fixture@example.invalid", cwd=root)
        run("git", "add", "--all", cwd=root)
        run("git", "commit", "--quiet", "-m", "Synthetic cleanup fixture", cwd=root)

        def tracked_state():
            paths = run("git", "ls-files", "-z", cwd=root).split("\0")
            return {
                name: (
                    (root / name).read_bytes(),
                    stat.S_IMODE((root / name).stat().st_mode),
                )
                for name in paths
                if name
            }

        before = tracked_state()
        before_status = run(
            "git", "status", "--porcelain=v1", "--untracked-files=all", cwd=root
        )
        self.assertEqual(self.invoke_main(packaging, root, names), 0)
        self.assertEqual(tracked_state(), before)
        self.assertEqual(
            run("git", "status", "--porcelain=v1", "--untracked-files=all", cwd=root),
            before_status,
        )
        self.assertFalse(
            (root / "docs/FULL_SOURCE.md").exists(),
            "Default packaging cannot regenerate documentation",
        )
        entries = zip_entries(root / "dist/TokenStatMenu-source.zip")
        self.assertEqual(len(entries), len(names))
        self.assertEqual(
            {name for name, _, _ in entries},
            {"TokenStatMenu/" + name for name in names},
        )
        for name, data, mode in entries:
            relative = name.removeprefix("TokenStatMenu/")
            self.assertEqual(data, before[relative][0])
            self.assertEqual(stat.S_IMODE(mode), before[relative][1])


def load_workflow(path: Path) -> dict:
    # Ruby standard YAML is the frozen parser; normalize YAML1.1 on=>true.
    program = (
        "require 'yaml'; require 'json'; "
        "value=YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true); "
        "value['on']=value.delete(true) if value.key?(true); "
        "STDOUT.write(JSON.generate(value))"
    )
    return json.loads(run("ruby", "-e", program, str(path)))


def workflow_contract(document: dict, raw: str) -> None:
    """A bounded assertion for this workflow, not a general workflow scanner."""
    assert document["on"] == {
        "push": {"branches": ["main"], "tags": ["v*"]},
        "pull_request": {},
    }
    assert document["permissions"] == {"contents": "read"}
    assert set(document["jobs"]) == {"build", "publish"}
    build = document["jobs"]["build"]
    publish = document["jobs"]["publish"]
    assert "if" not in build
    assert all(job.get("continue-on-error", False) is False for job in [build, publish])
    assert build.get("permissions", document["permissions"]) == {"contents": "read"}
    assert publish["permissions"] == {"contents": "write"}
    assert publish["needs"] in ["build", ["build"]]
    assert " ".join(publish["if"].split()) == PUBLISH_IF
    assert document["concurrency"]["cancel-in-progress"] is False
    actions = [
        step["uses"]
        for job in [build, publish]
        for step in job["steps"]
        if "uses" in step
    ]
    allowed = {
        "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
        "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9",
        "actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333",
    }
    assert set(actions) == allowed
    for job in [build, publish]:
        for step in job["steps"]:
            if step.get("uses", "").startswith("actions/checkout@"):
                assert step["with"]["persist-credentials"] is False
    assert any(step.get("with", {}).get("fetch-depth") == 0 for step in build["steps"])
    uploads = [
        step
        for step in build["steps"]
        if step.get("uses", "").startswith("actions/upload-artifact@")
    ]
    assert len(uploads) == 1 and uploads[0]["with"]["if-no-files-found"] == "error"
    assert " ".join(uploads[0].get("if", "").split()) == TAG_ONLY_IF
    paths = uploads[0]["with"]["path"]
    assert "*" not in paths and len(paths.splitlines()) == 5
    assert set(paths.splitlines()) == {
        "dist/release/TokenStatMenu.zip",
        "dist/release/TokenStatMenu-source.zip",
        "dist/release/TokenStatMenu.dmg",
        "dist/release/release-manifest.json",
        "dist/release/SHA256SUMS",
    }
    scripts = "\n".join(
        step.get("run", "") for job in [build, publish] for step in job["steps"]
    )
    assert "$" + "{{ github.ref_name }}" not in scripts
    assert "--clobber" not in scripts and "continue-on-error: true" not in raw
    assert "script/release_assets.py" in scripts
    assert "--arm64" in scripts
    assert "script/test_release_assets.py" in scripts
    assert "GH_TOKEN" in json.dumps(publish)
    assert "GH_TOKEN" not in json.dumps(build)

    def assert_step(
        job_name: str, prefix: str, expected_if: str | None, expected_lines: int = 1
    ) -> None:
        matching = [
            step
            for step in document["jobs"][job_name]["steps"]
            if any(
                line.strip().startswith(prefix)
                for line in step.get("run", "").splitlines()
            )
        ]
        assert len(matching) == 1
        step = matching[0]
        if expected_if is None:
            assert "if" not in step
        else:
            if_value = step.get("if", "")
            assert isinstance(if_value, str)
            assert " ".join(if_value.split()) == expected_if
        assert step.get("continue-on-error", False) is False
        lines = [
            line.strip()
            for line in step["run"].splitlines()
            if line.strip().startswith(prefix)
        ]
        assert len(lines) == expected_lines
        for line in lines:
            assert "||" not in line and "; true" not in line
            assert not line.endswith("&")

    for prefix in [
        "python3 -B script/test_release_assets.py",
        "swift run --force-resolved-versions TokenStatCoreChecks",
        "xcodebuild -project TokenStatMenu.xcodeproj -scheme TokenStatMenu ",
        "xcodebuild -project TokenStatMenu.xcodeproj -scheme TokenStatDevWidgetLogicTests ",
        "xcodebuild -project TokenStatMenu.xcodeproj -scheme TokenStatMenuDevWidgetTest ",
        "git diff --exit-code -- Package.resolved",
    ]:
        assert_step("build", prefix, None)
    native_test = next(
        step["run"]
        for step in build["steps"]
        if "-scheme TokenStatDevWidgetLogicTests " in step.get("run", "")
    )
    assert shlex.split(native_test) == [
        "xcodebuild",
        "-project",
        "TokenStatMenu.xcodeproj",
        "-scheme",
        "TokenStatDevWidgetLogicTests",
        "-destination",
        "platform=macOS,arch=arm64",
        "-derivedDataPath",
        "$RUNNER_TEMP/TokenStatDevWidgetLogicTests",
        "-parallel-testing-enabled",
        "NO",
        "CODE_SIGNING_ALLOWED=NO",
        "CODE_SIGNING_REQUIRED=NO",
        "test",
    ]
    # The full-suite step runs the same prefix, so count only filtered runs
    # here. The unfiltered `--skip` step is asserted separately below.
    assert_step(
        "build", "swift test --force-resolved-versions --filter", None, expected_lines=3
    )
    expected_ui_selectors = [
        "TokenStatUISnapshotTests.testCredentialAccountNamesAreURLAndPurposeBoundWithoutKeychainIO",
        "TokenStatUISnapshotTests.testImageMatcherDetectsDeliberateMismatchWithoutRecording",
        "TokenHubQuotaStateTests.*testBP39",
    ]
    base_command = ["swift", "test", "--force-resolved-versions"]
    actual_ui_commands = [
        shlex.split(line.strip())
        for step in build["steps"]
        for line in step.get("run", "").splitlines()
        if line.strip().startswith("swift test --force-resolved-versions --filter")
    ]
    assert actual_ui_commands == [
        base_command + ["--filter", selector] for selector in expected_ui_selectors
    ]
    # The full-suite run must exclude the pixel-comparing image snapshots,
    # whose output depends on the runner's font and rendering stack.
    full_runs = [
        line.strip()
        for step in build["steps"]
        for line in step.get("run", "").splitlines()
        if line.strip().startswith("swift test --force-resolved-versions")
        and "--filter" not in line
    ]
    assert len(full_runs) == 1
    assert "--skip" in "\n".join(
        step.get("run", "")
        for step in build["steps"]
        if "swift test --force-resolved-versions" in step.get("run", "")
        and "--filter" not in step.get("run", "")
    )
    for prefix in [
        "python3 -B script/release_assets.py preflight",
        "./script/build_and_run.sh --arm64",
        "python3 -B script/package_source.py",
        "python3 -B script/release_assets.py package",
        "python3 -B script/release_assets.py verify",
    ]:
        assert_step("build", prefix, TAG_ONLY_IF)
    assert_step("publish", "python3 -B script/release_assets.py verify", None)
    assert_step("publish", "python3 -B script/release_assets.py publish", None)


class WorkflowChecks(unittest.TestCase):
    def test_workflow_requires_unsigned_native_product_tests_without_skipping(self):
        path = PROJECT / ".github/workflows/ci.yml"
        raw = path.read_text()
        baseline = load_workflow(path)
        workflow_contract(baseline, raw)
        for mutation in ["remove", "build-only", "skip"]:
            value = copy.deepcopy(baseline)
            steps = value["jobs"]["build"]["steps"]
            target = next(
                step
                for step in steps
                if "-scheme TokenStatDevWidgetLogicTests " in step.get("run", "")
            )
            if mutation == "remove":
                steps.remove(target)
            elif mutation == "build-only":
                target["run"] = target["run"].removesuffix("test") + "build"
            else:
                target["run"] += " -skip-testing:TokenStatDevWidgetLogicTests"
            with self.assertRaises(AssertionError, msg=mutation):
                workflow_contract(value, raw)

    def test_repository_has_one_workflow_entrypoint(self):
        workflow_root = PROJECT / ".github/workflows"
        workflow_files = sorted(
            path.name
            for path in workflow_root.iterdir()
            if path.is_file() and path.suffix in {".yml", ".yaml"}
        )
        self.assertEqual(workflow_files, ["ci.yml"])

    def test_release_workflow_has_bounded_tag_only_write_permissions(self):
        path = PROJECT / ".github/workflows/ci.yml"
        workflow_contract(load_workflow(path), path.read_text())

    def test_workflow_rejects_removed_or_changed_bp39_selector(self):
        path = PROJECT / ".github/workflows/ci.yml"
        raw = path.read_text()
        baseline = load_workflow(path)
        workflow_contract(baseline, raw)
        for alteration in ["removed", "changed"]:
            value = copy.deepcopy(baseline)
            for step in value["jobs"]["build"]["steps"]:
                lines = step.get("run", "").splitlines()
                if any("TokenHubQuotaStateTests.*testBP39" in line for line in lines):
                    changed_lines = []
                    for line in lines:
                        if "TokenHubQuotaStateTests.*testBP39" not in line:
                            changed_lines.append(line)
                        elif alteration == "changed":
                            changed_lines.append(line.replace("testBP39", "testBP38"))
                    step["run"] = "\n".join(changed_lines)
            with self.subTest(alteration=alteration), self.assertRaises(AssertionError):
                workflow_contract(value, raw)

    def test_workflow_assertions_reject_gate_permission_and_asset_mutations(self):
        path = PROJECT / ".github/workflows/ci.yml"
        raw = path.read_text()
        baseline = load_workflow(path)
        variants = []
        value = copy.deepcopy(baseline)
        value["on"]["pull_request_target"] = {}
        variants.append(value)
        value = copy.deepcopy(baseline)
        value["permissions"] = {"contents": "write"}
        variants.append(value)
        value = copy.deepcopy(baseline)
        value["jobs"]["publish"]["needs"] = []
        variants.append(value)
        value = copy.deepcopy(baseline)
        value["jobs"]["publish"]["if"] = "always()"
        variants.append(value)
        value = copy.deepcopy(baseline)
        value["jobs"]["build"]["steps"].append(
            {"run": "echo " + "$" + "{{ github.ref_name }}"}
        )
        variants.append(value)
        value = copy.deepcopy(baseline)
        for step in value["jobs"]["build"]["steps"]:
            if step.get("uses", "").startswith("actions/upload-artifact@"):
                step["with"]["path"] = "dist/*"
        variants.append(value)
        value = copy.deepcopy(baseline)
        value["jobs"]["publish"]["steps"].append({"run": "gh release upload --clobber"})
        variants.append(value)
        value = copy.deepcopy(baseline)
        value["jobs"]["unexpected-writer"] = {
            "permissions": {"contents": "write"},
            "runs-on": "ubuntu-latest",
            "steps": [{"run": "false"}],
        }
        variants.append(value)
        for job_name in ["build", "publish"]:
            value = copy.deepcopy(baseline)
            value["jobs"][job_name]["continue-on-error"] = True
            variants.append(value)
            if job_name == "build":
                value = copy.deepcopy(baseline)
                value["jobs"][job_name]["if"] = False
                variants.append(value)
            for alteration in [
                "disabled",
                "removed",
                "commented",
                "shell-or",
                "shell-true",
                "background",
            ]:
                value = copy.deepcopy(baseline)
                steps = value["jobs"][job_name]["steps"]
                index = next(
                    i
                    for i, step in enumerate(steps)
                    if any(
                        line.strip().startswith(
                            "python3 -B script/release_assets.py verify"
                        )
                        for line in step.get("run", "").splitlines()
                    )
                )
                if alteration == "disabled":
                    steps[index]["if"] = False
                elif alteration == "removed":
                    steps.pop(index)
                elif alteration == "commented":
                    steps[index]["run"] = "\n".join(
                        "# " + line for line in steps[index]["run"].splitlines()
                    )
                else:
                    suffix = {
                        "shell-or": " || true",
                        "shell-true": "; true",
                        "background": " &",
                    }[alteration]
                    steps[index]["run"] = "\n".join(
                        line + suffix
                        if line.strip().startswith(
                            "python3 -B script/release_assets.py verify"
                        )
                        else line
                        for line in steps[index]["run"].splitlines()
                    )
                variants.append(value)
        for index, value in enumerate(variants):
            with self.subTest(index=index), self.assertRaises(AssertionError):
                workflow_contract(value, raw)
        with self.assertRaises(AssertionError):
            workflow_contract(baseline, raw + "\ncontinue-on-error: true\n")


PLIST_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleShortVersionString</key>
\t<string>{version}</string>
\t<key>CFBundleVersion</key>
\t<string>{build}</string>
</dict>
</plist>
"""


class BumpBuildChecks(unittest.TestCase):
    """Local builds advance both plists; release builds stay at tag identity."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="tokenstat-bump-"))
        self.addCleanup(shutil.rmtree, self.root)
        self.write_plists("1.2.3", "7", "1.2.3", "7")

    def write_plists(self, app_version, app_build, widget_version, widget_build):
        for name, version, build in (
            ("Resources/Info.plist", app_version, app_build),
            ("Resources/WidgetExtension-Info.plist", widget_version, widget_build),
        ):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(
                PLIST_TEMPLATE.format(version=version, build=build),
                encoding="utf-8",
            )

    def bump(self, *args):
        return subprocess.run(
            [
                sys.executable,
                "-B",
                str(PROJECT / "script/bump_build.py"),
                "--root",
                str(self.root),
                *args,
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def contents(self):
        return {
            name: (self.root / name).read_text(encoding="utf-8")
            for name in (
                "Resources/Info.plist",
                "Resources/WidgetExtension-Info.plist",
            )
        }

    def test_increments_both_plists(self):
        before = self.contents()
        result = self.bump()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "build 7 -> 8 (1.2.3)")
        after = self.contents()
        for name, text in after.items():
            self.assertEqual(text.count("<string>8</string>"), 1)
            self.assertEqual(
                text.replace("<string>8</string>", "<string>7</string>"),
                before[name],
            )
        printed = self.bump("--print")
        self.assertEqual(printed.returncode, 0, printed.stderr)
        self.assertEqual(printed.stdout.strip(), "1.2.3 (build 8)")

    def test_print_leaves_files_unchanged(self):
        before = self.contents()
        result = self.bump("--print")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "1.2.3 (build 7)")
        self.assertEqual(self.contents(), before)

    def test_rejects_drifted_builds(self):
        self.write_plists("1.2.3", "7", "1.2.3", "9")
        before = self.contents()
        result = self.bump()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CFBundleVersion differ", result.stderr)
        self.assertEqual(self.contents(), before)

    def test_rejects_drifted_versions(self):
        self.write_plists("1.2.3", "7", "1.2.4", "7")
        result = self.bump()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CFBundleShortVersionString differ", result.stderr)

    def test_rejects_non_integer_build(self):
        self.write_plists("1.2.3", "abc", "1.2.3", "abc")
        before = self.contents()
        result = self.bump()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CFBundleVersion", result.stderr)
        self.assertEqual(self.contents(), before)

    def test_rejects_missing_plist(self):
        (self.root / "Resources/WidgetExtension-Info.plist").unlink()
        result = self.bump()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
