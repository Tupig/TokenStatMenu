#!/usr/bin/env python3
"""Executable C26A checks. All fixtures are synthetic and private.

The API import intentionally fails until the paired implementation exists.
Native fixture success is not a substitute for the actual product build.
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

from package_source import PUBLIC_FILES
import release_assets as release


PROJECT = Path(__file__).resolve().parents[1]
TAG = "v1.1.3"
VERSION = "1.1.3"
BUILD = "5"
PUBLISH_IF = "$" + "{{ github.repository == 'Tupig/TokenStatMenu' && github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}"
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
        environment = {key: value for key, value in environment.items()
                       if not key.startswith("GIT_")}
        environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                           GIT_CONFIG_SYSTEM=os.devnull, GIT_TERMINAL_PROMPT="0")
        args = ("git", "-c", "core.hooksPath=" + os.devnull,
                "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", *args[1:])
    result = subprocess.run(args, cwd=cwd, env=environment,
                            text=True, capture_output=True, check=True)
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
        return [(item.filename, archive.read(item), item.external_attr >> 16)
                for item in archive.infolist()]


class Fixture:
    def __init__(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tokenstat-release-fixture-")
        self.base = Path(self.temporary.name)
        self.root = self.base / "source"
        self.root.mkdir()
        # Use actual reviewed file bytes and modes, without any real user data.
        for name in PUBLIC_FILES:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(PROJECT / name, target)
        self.source_info = plistlib.loads((self.root / "Resources/Info.plist").read_bytes())
        self.source_info["CFBundleShortVersionString"] = VERSION
        self.source_info["CFBundleVersion"] = BUILD
        (self.root / "Resources/Info.plist").write_bytes(plistlib.dumps(self.source_info))
        run("git", "init", "--quiet", "--initial-branch=main", cwd=self.root)
        run("git", "config", "user.name", "Synthetic Release Fixture", cwd=self.root)
        run("git", "config", "user.email", "release-fixture@example.invalid", cwd=self.root)
        run("git", "add", "--all", cwd=self.root)
        run("git", "commit", "--quiet", "-m", "Synthetic release fixture", cwd=self.root)
        self.commit = run("git", "rev-parse", "HEAD", cwd=self.root)
        run("git", "update-ref", "refs/remotes/origin/main", self.commit, cwd=self.root)
        run("git", "tag", TAG, cwd=self.root)
        self.identity = release.ReleaseIdentity(VERSION, BUILD, TAG, self.commit)
        self.source_zip = self.base / "source.zip"
        self.source_entries = []
        for name in PUBLIC_FILES:
            file = self.root / name
            self.source_entries.append(("TokenStatMenu/" + name, file.read_bytes(),
                                        stat.S_IFREG | stat.S_IMODE(file.stat().st_mode)))
        write_zip(self.source_zip, self.source_entries)
        self.app = self.base / "TokenStatMenu.app"
        info = dict(self.source_info, TokenStatSourceRevision=self.commit,
                    TokenStatSourceState="clean")
        contents = {
            "Contents/Info.plist": plistlib.dumps(info),
            "Contents/MacOS/TokenStatMenu": b"synthetic-native-payload",
            "Contents/Resources/AppIcon.icns": (self.root / "Resources/AppIcon.icns").read_bytes(),
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
        app_name = f"TokenStatMenu-{VERSION}-universal.zip"
        source_name = f"TokenStatMenu-{VERSION}-source.zip"
        app_entries = [("TokenStatMenu.app/" + name, (self.app / name).read_bytes(),
                        stat.S_IFREG | mode) for name, mode in APP_FILES.items()]
        write_zip(self.assets / app_name, app_entries)
        shutil.copy2(self.source_zip, self.assets / source_name)
        manifest = {
            "version": VERSION, "build": BUILD, "tag": TAG, "commit": self.commit,
            "assets": {},
        }
        for kind, name in [("universal", app_name), ("source", source_name)]:
            data = (self.assets / name).read_bytes()
            manifest["assets"][kind] = {
                "name": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            }
        (self.assets / "release-manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        self.refresh_sums()
        return manifest

    def refresh_sums(self) -> None:
        names = [f"TokenStatMenu-{VERSION}-universal.zip",
                 f"TokenStatMenu-{VERSION}-source.zip", "release-manifest.json"]
        (self.assets / "SHA256SUMS").write_text("".join(
            hashlib.sha256((self.assets / name).read_bytes()).hexdigest()
            + "  " + name + "\n" for name in sorted(names)))

    def mutate_manifest(self, change) -> None:
        file = self.assets / "release-manifest.json"
        value = json.loads(file.read_text())
        change(value)
        file.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        self.refresh_sums()


class FakeClient:
    """Only network transport is replaced; production state logic is exercised."""
    def __init__(self, fixture: Fixture, draft: bool | None = None,
                 existing: list[str] | None = None, failure: str | None = None,
                 final_readback: str | None = None) -> None:
        self.fixture = fixture
        self.tag_commit = fixture.commit
        self.remote = None if draft is None else {"id": 7, "tag": TAG, "draft": draft, "prerelease": False}
        self.assets = {} if existing is None else {
            name: (fixture.assets / name).read_bytes() for name in existing
        }
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
    def setUp(self) -> None:
        self.fixture = Fixture()
        self.addCleanup(self.fixture.close)

    def reject_source(self, entries) -> None:
        self.fixture.source_archive(entries)
        with self.assertRaises(ValueError):
            release.validate_source_archive(self.fixture.root, self.fixture.source_zip, PUBLIC_FILES)

    def test_fixture_git_explicitly_disables_hooks_and_signing(self):
        f = self.fixture
        self.assertEqual(run("git", "config", "--get", "core.hooksPath", cwd=f.root), os.devnull)
        self.assertEqual(run("git", "config", "--get", "commit.gpgsign", cwd=f.root), "false")
        self.assertEqual(run("git", "config", "--get", "tag.gpgsign", cwd=f.root), "false")

    def test_identity_accepts_real_lightweight_and_annotated_tags(self):
        f = self.fixture
        self.assertEqual(release.release_identity(f.root, TAG, f.commit), f.identity)
        run("git", "tag", "-d", TAG, cwd=f.root)
        run("git", "tag", "-a", TAG, "-m", "Synthetic annotated release", cwd=f.root)
        self.assertEqual(release.release_identity(f.root, TAG, f.commit), f.identity)

    def test_identity_rejects_malformed_and_shell_special_tags(self):
        f = self.fixture
        marker = f.base / "unexpected-marker"
        for tag in ["1.1.3", "v01.1.3", "v1.1", "v1.1.3-rc.1", "v1.1.3;false",
                    "v1.1.3\n", f"v1.1.3; touch {marker}", f"v1.1.3$(touch {marker})"]:
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
        for changed in [entries[:-1],
                        entries + [("TokenStatMenu/extra.txt", b"x", stat.S_IFREG | 0o644)],
                        entries + [entries[0]],
                        entries + [("TokenStatMenu/.hidden", b"x", stat.S_IFREG | 0o644)]]:
            with self.subTest(count=len(changed)):
                self.reject_source(changed)

    def test_source_archive_rejects_path_escape_symlink_directory_mode_and_content(self):
        entries = self.fixture.source_entries
        name, data, mode = entries[0]
        for replacement in [("/absolute", data, mode), ("TokenStatMenu/../escape", data, mode),
                            (name, b"target", stat.S_IFLNK | 0o777),
                            (name + "/", b"", stat.S_IFDIR | 0o755),
                            (name, data, stat.S_IFREG | 0o755),
                            (name, data + b"changed", mode)]:
            with self.subTest(replacement=replacement[0]):
                self.reject_source([replacement, *entries[1:]])

    def test_source_archive_rejects_source_symlink_extra_tracked_and_changed_bytes(self):
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
        self.assertEqual(release.validate_assets(f.root, f.assets, f.identity), expected)

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
        for text in [baseline.replace(baseline[:64], "0" * 64, 1),
                     baseline + baseline.splitlines()[0] + "\n",
                     baseline + "0" * 64 + "  extra.txt\n",
                     baseline.replace("  release-manifest.json", "  ../release-manifest.json")]:
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
        f.mutate_manifest(lambda x: x["assets"]["source"].update(
            bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
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
                        changed.append(("TokenStatMenu.app/.hidden", b"x", stat.S_IFREG | 0o644))
                    else:
                        item, _, _ = changed[0]
                        changed[0] = (item, b"target", stat.S_IFLNK | 0o777)
                    write_zip(archive, changed)
                data = archive.read_bytes()
                f.mutate_manifest(lambda x: x["assets"]["universal"].update(
                    bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
                with self.assertRaises(ValueError):
                    release.validate_assets(f.root, f.assets, f.identity)

    def test_assets_reject_zip_info_identity_even_with_recomputed_digests(self):
        f = self.fixture
        f.synthetic_assets()
        archive = f.assets / f"TokenStatMenu-{VERSION}-universal.zip"
        baseline = zip_entries(archive)
        for key, value in [("TokenStatSourceRevision", "a" * 40),
                           ("TokenStatSourceState", "modified"),
                           ("CFBundleShortVersionString", "9.9.9"),
                           ("CFBundleVersion", "99")]:
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
                f.mutate_manifest(lambda x: x["assets"]["universal"].update(
                    bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
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
        self.assertEqual([item[0] for item in client.mutations],
                         ["create_draft", "upload", "upload", "upload", "upload", "publish"])
        publish_index = next(i for i, item in enumerate(client.calls) if item[0] == "publish")
        before = {item[1] for item in client.calls[:publish_index] if item[0] == "download"}
        self.assertEqual(before, names)
        self.assertTrue(any(item[0] == "lookup" for item in client.calls[publish_index + 1:]))

    def test_publish_identical_published_rerun_is_read_only(self):
        f = self.fixture
        f.synthetic_assets()
        client = FakeClient(f, draft=False, existing=[p.name for p in f.assets.iterdir()])
        release.publish_release(f.root, f.assets, f.identity, client)
        self.assertEqual(client.mutations, [])
        self.assertEqual({item[1] for item in client.calls if item[0] == "download"},
                         set(client.assets))

    def test_publish_matching_partial_draft_uploads_only_missing_assets(self):
        f = self.fixture
        f.synthetic_assets()
        client = FakeClient(f, draft=True, existing=["release-manifest.json"])
        release.publish_release(f.root, f.assets, f.identity, client)
        self.assertFalse(client.remote["draft"])
        uploaded = [item[1] for item in client.mutations if item[0] == "upload"]
        self.assertEqual(set(uploaded), {p.name for p in f.assets.iterdir()} - {"release-manifest.json"})
        self.assertEqual(len(uploaded), 3)
        self.assertNotIn("create_draft", [item[0] for item in client.mutations])

    def test_existing_release_requires_explicit_false_prerelease_before_writes(self):
        f = self.fixture
        f.synthetic_assets()
        for draft in [False, True]:
            for invalid in [True, None, 0, "false", "missing"]:
                with self.subTest(draft=draft, prerelease=invalid):
                    client = FakeClient(f, draft=draft, existing=[p.name for p in f.assets.iterdir()])
                    if invalid == "missing":
                        del client.remote["prerelease"]
                    else:
                        client.remote["prerelease"] = invalid
                    with self.assertRaises(ValueError):
                        release.publish_release(f.root, f.assets, f.identity, client)
                    self.assertEqual(client.mutations, [], "never silently convert a prerelease or ambiguous release")

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
                self.assertEqual([item[0] for item in client.mutations], ["create_draft"])
                self.assertTrue(client.remote["draft"])

    def test_github_adapter_preserves_strict_boolean_prerelease_metadata(self):
        client = release.GitHubClient(self.fixture.identity)
        baseline = {"id": 7, "tag_name": TAG, "draft": False, "prerelease": False}
        with mock.patch.object(client, "_get", return_value=baseline):
            self.assertEqual(client.lookup(TAG),
                             {"id": 7, "tag": TAG, "draft": False, "prerelease": False})
        for invalid in [None, 0, "false", "missing"]:
            value = dict(baseline)
            if invalid == "missing":
                del value["prerelease"]
            else:
                value["prerelease"] = invalid
            with self.subTest(prerelease=invalid), mock.patch.object(client, "_get", return_value=value):
                with self.assertRaises(ValueError):
                    client.lookup(TAG)
        # A real boolean true is preserved by transport, then rejected by the
        # publisher. The adapter must never coerce any metadata to false.
        with mock.patch.object(client, "_get", return_value=dict(baseline, prerelease=True)):
            self.assertIs(client.lookup(TAG)["prerelease"], True)

    def test_publish_conflicts_or_retagging_never_mutate_remote_release(self):
        f = self.fixture
        f.synthetic_assets()
        names = [p.name for p in f.assets.iterdir()]
        for kind in ["published-content", "draft-content", "extra", "missing", "retagged"]:
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
        for phase in ["resolve_tag", "lookup", "create_draft", "upload", "download", "publish"]:
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
                self.assertFalse(client.remote["draft"],
                                 "a failed readback must not pretend publication was rolled back")
                self.assertEqual(client.mutations[-1][0], "publish")
                self.assertEqual([item[0] for item in client.mutations].count("publish"), 1)


@unittest.skipUnless(sys.platform == "darwin", "real private macOS signing/Universal fixture")
class NativeReleaseChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.native_directory = tempfile.TemporaryDirectory(prefix="tokenstat-native-release-check-")
        cls.addClassCleanup(cls.native_directory.cleanup)
        cls.native_root = Path(cls.native_directory.name)
        source = cls.native_root / "main.swift"
        source.write_text('print("synthetic release validation")\n')
        cls.thin = cls.native_root / "thin"
        intel = cls.native_root / "intel"
        cls.universal = cls.native_root / "universal"
        run("xcrun", "--sdk", "macosx", "swiftc", "-target", "arm64-apple-macosx13.0",
            str(source), "-o", str(cls.thin))
        run("xcrun", "--sdk", "macosx", "swiftc", "-target", "x86_64-apple-macosx13.0",
            str(source), "-o", str(intel))
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
        expected = {f"TokenStatMenu-{VERSION}-universal.zip",
                    f"TokenStatMenu-{VERSION}-source.zip",
                    "release-manifest.json", "SHA256SUMS"}
        self.assertEqual({p.name for p in f.assets.iterdir()}, expected)
        release.validate_assets(f.root, f.assets, f.identity)
        with zipfile.ZipFile(f.assets / f"TokenStatMenu-{VERSION}-universal.zip") as archive:
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
        self.assertEqual(first, second,
                         "release metadata normalization must preserve deterministic four-asset bytes")

    def test_real_signature_rejects_post_signing_plist_tamper(self):
        f = self.fixture
        file = f.app / "Contents/Info.plist"
        info = plistlib.loads(file.read_bytes())
        info["CFBundleDisplayName"] = "synthetic tamper"
        file.write_bytes(plistlib.dumps(info))
        result = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(f.app)],
                                text=True, capture_output=True)
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
        self.assertEqual(set(run("lipo", "-archs", str(binary)).split()), {"arm64", "x86_64"})
        result = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(f.app)],
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0,
                            "only the signature should distinguish this otherwise valid bundle")
        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, subprocess.run)

    def test_real_thin_signed_bundle_is_not_universal(self):
        f = self.fixture
        shutil.copy2(self.thin, f.app / "Contents/MacOS/TokenStatMenu")
        self.sign()
        self.assertEqual(run("lipo", "-archs", str(f.app / "Contents/MacOS/TokenStatMenu")), "arm64")
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
    assert document["on"] == {"push": {"tags": ["v*"]}}
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
    actions = [step["uses"] for job in [build, publish] for step in job["steps"] if "uses" in step]
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
    uploads = [step for step in build["steps"]
               if step.get("uses", "").startswith("actions/upload-artifact@")]
    assert len(uploads) == 1 and uploads[0]["with"]["if-no-files-found"] == "error"
    paths = uploads[0]["with"]["path"]
    assert "*" not in paths and len(paths.splitlines()) == 4
    scripts = "\n".join(step.get("run", "") for job in [build, publish] for step in job["steps"])
    assert "$" + "{{ github.ref_name }}" not in scripts
    assert "--clobber" not in scripts and "continue-on-error: true" not in raw
    assert "script/release_assets.py" in scripts
    assert "--universal" in scripts
    assert "script/test_release_assets.py" in scripts
    assert "GH_TOKEN" in json.dumps(publish)
    assert "GH_TOKEN" not in json.dumps(build)
    required = {
        "build": ["python3 -B script/test_release_assets.py",
                  "python3 -B script/release_assets.py preflight",
                  "./script/build_and_run.sh --universal",
                  "python3 -B script/package_source.py",
                  "python3 -B script/release_assets.py package",
                  "python3 -B script/release_assets.py verify"],
        "publish": ["python3 -B script/release_assets.py verify",
                    "python3 -B script/release_assets.py publish"],
    }
    for job_name, prefixes in required.items():
        for prefix in prefixes:
            matching = [step for step in document["jobs"][job_name]["steps"]
                        if any(line.strip().startswith(prefix)
                               for line in step.get("run", "").splitlines())]
            assert len(matching) == 1
            assert "if" not in matching[0]
            assert matching[0].get("continue-on-error", False) is False
            lines = [line.strip() for line in matching[0]["run"].splitlines()
                     if line.strip().startswith(prefix)]
            assert len(lines) == 1
            assert "||" not in lines[0] and "; true" not in lines[0]
            assert not lines[0].endswith("&")


class WorkflowChecks(unittest.TestCase):
    def test_release_workflow_has_bounded_tag_only_write_permissions(self):
        path = PROJECT / ".github/workflows/release.yml"
        workflow_contract(load_workflow(path), path.read_text())

    def test_workflow_assertions_reject_gate_permission_and_asset_mutations(self):
        path = PROJECT / ".github/workflows/release.yml"
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
        value["jobs"]["build"]["steps"].append({"run": "echo " + "$" + "{{ github.ref_name }}"})
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
            "permissions": {"contents": "write"}, "runs-on": "ubuntu-latest",
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
            for alteration in ["disabled", "removed", "commented", "shell-or", "shell-true", "background"]:
                value = copy.deepcopy(baseline)
                steps = value["jobs"][job_name]["steps"]
                index = next(i for i, step in enumerate(steps)
                             if any(line.strip().startswith("python3 -B script/release_assets.py verify")
                                    for line in step.get("run", "").splitlines()))
                if alteration == "disabled":
                    steps[index]["if"] = False
                elif alteration == "removed":
                    steps.pop(index)
                elif alteration == "commented":
                    steps[index]["run"] = "\n".join("# " + line for line in steps[index]["run"].splitlines())
                else:
                    suffix = {"shell-or": " || true", "shell-true": "; true", "background": " &"}[alteration]
                    steps[index]["run"] = "\n".join(
                        line + suffix if line.strip().startswith("python3 -B script/release_assets.py verify")
                        else line for line in steps[index]["run"].splitlines())
                variants.append(value)
        for index, value in enumerate(variants):
            with self.subTest(index=index), self.assertRaises(AssertionError):
                workflow_contract(value, raw)
        with self.assertRaises(AssertionError):
            workflow_contract(baseline, raw + "\ncontinue-on-error: true\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
