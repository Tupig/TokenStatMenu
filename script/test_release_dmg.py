#!/usr/bin/env python3
"""Offline DMG contract checks; never mount, build, sign, or install an App."""
# fmt: off

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile

import release_assets as release

IDENTITY = release.ReleaseIdentity("1.1.5", "7", "v1.1.5", "a" * 40)
BUNDLE = {
    "Contents/Info.plist": (b"synthetic-plist", 0o644),
    "Contents/MacOS/TokenStatMenu": (b"synthetic-executable", 0o755),
    "Contents/Resources/AppIcon.icns": (b"synthetic-icon", 0o644),
    "Contents/_CodeSignature/CodeResources": (b"synthetic-signature", 0o644),
}

class DmgChecks(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tokenstat-offline-dmg-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.dmg = self.base / "TokenStatMenu.dmg"
        self.dmg.write_bytes(b"synthetic-image-not-a-real-dmg")
        self.mount = self.base / "owned-mount"
        self.calls = []
        self.root_change = None
        self.failure = None
        self.attach_stdout = None
        self.expected_detach_target = "/dev/disk900s1"
        self.canonical_mount = False
        self.validator = self.enterContext(
            mock.patch.object(release, "validate_app", return_value=dict(BUNDLE))
        )
        self.enterContext(
            mock.patch.object(release.tempfile, "mkdtemp", side_effect=self.make_mount)
        )
        # A missed dependency injection must fail, not invoke a native tool.
        self.enterContext(
            mock.patch.object(
                release.subprocess,
                "run",
                side_effect=AssertionError("real subprocess is forbidden"),
            )
        )

    def make_mount(self, **kwargs):
        self.assertEqual(kwargs, {"prefix": "tokenstat-dmg-mount-"})
        self.mount.mkdir()
        return str(self.mount)

    def tool(self, arguments, **kwargs):
        self.assertEqual(kwargs, dict(text=True, capture_output=True, check=False))
        self.calls.append(arguments)
        operation = arguments[1]
        self.assertEqual(arguments[0], "/usr/bin/hdiutil")
        if operation == "imageinfo":
            self.assertEqual(
                arguments, ["/usr/bin/hdiutil", "imageinfo", str(self.dmg)]
            )
            output = "synthetic image info\n"
        elif operation == "attach":
            self.assertEqual(
                arguments,
                [
                    "/usr/bin/hdiutil",
                    "attach",
                    "-readonly",
                    "-nobrowse",
                    "-mountpoint",
                    str(self.mount),
                    str(self.dmg),
                ],
            )
            (self.mount / "TokenStatMenu.app").mkdir()
            (self.mount / "Applications").symlink_to("/Applications")
            if self.root_change is not None:
                self.root_change(self.mount)
            mount_text = (
                os.path.realpath(self.mount)
                if self.canonical_mount
                else str(self.mount)
            )
            output = (
                "正在验证校验和…\n/dev/disk900\tGUID_partition_scheme\n"
                "/dev/disk999s1\tApple_HFS\t/unrelated-volume\n"
                f"/dev/disk900s1\tApple_HFS\t{mount_text}\n"
            )
            if self.attach_stdout is not None:
                output = self.attach_stdout
        elif operation == "detach":
            self.assertEqual(
                arguments, ["/usr/bin/hdiutil", "detach", self.expected_detach_target]
            )
            output = "detached\n"
        else:
            self.fail("unexpected native operation: " + repr(arguments))
        if self.failure == operation + "-exception":
            raise OSError("synthetic hdiutil failure")
        status = 1 if self.failure == operation else 0
        return subprocess.CompletedProcess(arguments, status, output, "")

    def validate(self, expected_bundle=BUNDLE):
        return release.validate_dmg(
            self.base, self.dmg, IDENTITY, self.tool, expected_bundle=expected_bundle
        )

    def assert_detached(self, retained=False):
        self.assertEqual(
            [call[1] for call in self.calls], ["imageinfo", "attach", "detach"]
        )
        if retained:
            self.assertTrue(self.mount.is_dir(), "failed detach must preserve the mount directory")
            self.assertTrue((self.mount / "TokenStatMenu.app").is_dir())
            self.assertTrue((self.mount / "Applications").is_symlink())
        else:
            self.assertFalse(self.mount.exists(), "owned mount directory must be cleaned")

    def test_identical_payload_succeeds_with_read_only_mount_and_owned_detach(self):
        result = self.validate()
        self.assertEqual(
            result,
            dict(
                name=self.dmg.name,
                bytes=len(self.dmg.read_bytes()),
                sha256=hashlib.sha256(self.dmg.read_bytes()).hexdigest(),
            ),
        )
        self.validator.assert_called_once_with(
            self.base, self.mount / "TokenStatMenu.app", IDENTITY, self.tool
        )
        self.assert_detached()

    def test_canonical_owned_mount_path_is_accepted(self):
        self.canonical_mount = True
        self.validate()
        self.assert_detached()

    def test_optional_expected_bundle_preserves_standalone_inspection(self):
        self.validate(expected_bundle=None)
        self.validator.assert_called_once()
        self.assert_detached()

    def test_payload_bytes_mismatch_is_rejected_and_detached(self):
        changed = dict(BUNDLE)
        changed["Contents/MacOS/TokenStatMenu"] = (b"different-executable", 0o755)
        self.validator.return_value = changed
        with self.assertRaisesRegex(ValueError, "ZIP and DMG App payloads differ"):
            self.validate()
        self.assert_detached()

    def test_payload_mode_mismatch_is_rejected_and_detached(self):
        changed = dict(BUNDLE)
        changed["Contents/MacOS/TokenStatMenu"] = (
            BUNDLE["Contents/MacOS/TokenStatMenu"][0],
            0o644,
        )
        self.validator.return_value = changed
        with self.assertRaisesRegex(ValueError, "ZIP and DMG App payloads differ"):
            self.validate()
        self.assert_detached()

    def test_payload_missing_file_is_rejected_and_detached(self):
        changed = dict(BUNDLE)
        del changed["Contents/Resources/AppIcon.icns"]
        self.validator.return_value = changed
        with self.assertRaisesRegex(ValueError, "ZIP and DMG App payloads differ"):
            self.validate()
        self.assert_detached()

    def test_payload_extra_file_is_rejected_and_detached(self):
        self.validator.return_value = dict(BUNDLE, unexpected=(b"extra", 0o644))
        with self.assertRaisesRegex(ValueError, "ZIP and DMG App payloads differ"):
            self.validate()
        self.assert_detached()

    def test_extra_root_member_is_rejected_before_app_validation(self):
        self.root_change = lambda mount: (mount / ".hidden").write_bytes(b"extra")
        with self.assertRaisesRegex(ValueError, "DMG root has unexpected members"):
            self.validate()
        self.validator.assert_not_called()
        self.assert_detached()

    def test_missing_root_member_is_rejected_and_detached(self):
        self.root_change = lambda mount: (mount / "Applications").unlink()
        with self.assertRaisesRegex(ValueError, "DMG root has unexpected members"):
            self.validate()
        self.validator.assert_not_called()
        self.assert_detached()

    def test_unsafe_applications_links_or_regular_directory_are_rejected(self):
        for target in ["../Applications", "/tmp/Applications", None]:
            with self.subTest(target=target):
                self.calls.clear()

                def change(mount):
                    alias = mount / "Applications"
                    alias.unlink()
                    if target is None:
                        alias.mkdir()
                    else:
                        alias.symlink_to(target)

                self.root_change = change
                with self.assertRaisesRegex(
                    ValueError, "DMG Applications alias is unsafe"
                ):
                    self.validate()
                self.validator.assert_not_called()
                self.assert_detached()

    def test_symbolic_app_is_rejected_and_detached(self):
        def change(mount):
            app = mount / "TokenStatMenu.app"
            app.rmdir()
            app.symlink_to(self.base, target_is_directory=True)

        self.root_change = change
        with self.assertRaisesRegex(ValueError, "DMG App is missing or symbolic"):
            self.validate()
        self.validator.assert_not_called()
        self.assert_detached()

    def test_native_app_validation_failure_is_rejected_and_detached(self):
        self.validator.side_effect = ValueError("synthetic invalid native app")
        with self.assertRaisesRegex(ValueError, "synthetic invalid native app"):
            self.validate()
        self.assert_detached()

    def test_detach_failure_prevents_success_even_with_identical_payload(self):
        for failure in ["detach", "detach-exception"]:
            with self.subTest(failure=failure):
                self.calls.clear()
                self.failure = failure
                with self.assertRaisesRegex(RuntimeError, "owned DMG detach failed"):
                    self.validate()
                self.assert_detached(retained=True)
                # No image is mounted: remove only this synthetic test tree
                # after verifying production code left the directory intact.
                shutil.rmtree(self.mount)

    def test_detach_failure_remains_visible_after_payload_failure(self):
        self.failure = "detach"
        self.validator.side_effect = ValueError("synthetic invalid native app")
        with self.assertRaisesRegex(RuntimeError, "owned DMG detach failed") as caught:
            self.validate()
        self.assertIsNotNone(caught.exception.__cause__)
        self.assert_detached(retained=True)

    def test_imageinfo_and_attach_failures_never_run_app_validator(self):
        for failure in [
            "imageinfo",
            "attach",
            "imageinfo-exception",
            "attach-exception",
        ]:
            with self.subTest(failure=failure):
                self.calls.clear()
                self.failure = failure
                self.expected_detach_target = str(self.mount) if failure == "attach-exception" else "/dev/disk900s1"
                with self.assertRaises((ValueError, RuntimeError)):
                    self.validate()
                self.validator.assert_not_called()
                if failure.startswith("imageinfo"):
                    self.assertEqual([call[1] for call in self.calls], ["imageinfo"])
                else:
                    self.assert_detached()
                self.assertFalse(self.mount.exists())

    def test_successful_attach_without_owned_device_rejects_and_detaches_mountpoint(self):
        for stdout in ["", "unparseable localized output\n", "/dev/disk999s1\tApple_HFS\t/unrelated-volume\n"]:
            with self.subTest(stdout=stdout):
                self.calls.clear()
                self.attach_stdout = stdout
                self.expected_detach_target = str(self.mount)
                with self.assertRaisesRegex(ValueError, "hdiutil attach returned no owned device"):
                    self.validate()
                self.validator.assert_not_called()
                self.assert_detached()

    def test_failed_attach_without_device_uses_mountpoint_and_preserves_on_detach_failure(self):
        self.attach_stdout = "unparseable localized output\n"
        self.expected_detach_target = str(self.mount)
        original_tool = self.tool

        def failed_attach_and_detach(arguments, **kwargs):
            self.failure = arguments[1] if arguments[1] in ["attach", "detach"] else None
            return original_tool(arguments, **kwargs)

        with self.assertRaisesRegex(RuntimeError, "owned DMG detach failed"):
            release.validate_dmg(
                self.base, self.dmg, IDENTITY, failed_attach_and_detach, expected_bundle=BUNDLE
            )
        self.validator.assert_not_called()
        self.assert_detached(retained=True)

class AssetDmgForwardingChecks(unittest.TestCase):
    def test_validate_assets_passes_the_zip_bundle_to_native_dmg_validation(self):
        with tempfile.TemporaryDirectory(prefix="tokenstat-dmg-assets-") as temporary:
            root = Path(temporary)
            names = {
                "universal": "TokenStatMenu-1.1.5-universal.zip",
                "source": "TokenStatMenu-1.1.5-source.zip",
                "dmg": "TokenStatMenu-1.1.5-universal.dmg",
            }
            with zipfile.ZipFile(root / names["universal"], "w") as archive:
                for name, (data, mode) in BUNDLE.items():
                    member = zipfile.ZipInfo("TokenStatMenu.app/" + name)
                    member.create_system = 3
                    member.external_attr = (stat.S_IFREG | mode) << 16
                    archive.writestr(member, data)
            (root / names["source"]).write_bytes(b"synthetic source archive")
            (root / names["dmg"]).write_bytes(b"synthetic disk image")
            manifest = {
                "version": IDENTITY.version,
                "build": IDENTITY.build,
                "tag": IDENTITY.tag,
                "commit": IDENTITY.commit,
                "assets": {},
            }
            for kind, name in names.items():
                data = (root / name).read_bytes()
                manifest["assets"][kind] = dict(
                    name=name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest()
                )
            (root / "release-manifest.json").write_text(
                json.dumps(manifest) + "\n", encoding="utf-8"
            )
            (root / "SHA256SUMS").write_text(
                "".join(
                    hashlib.sha256((root / name).read_bytes()).hexdigest()
                    + "  "
                    + name
                    + "\n"
                    for name in sorted([*names.values(), "release-manifest.json"])
                ),
                encoding="utf-8",
            )
            runner = mock.Mock(side_effect=AssertionError("native tools are forbidden"))
            with (
                mock.patch.object(release, "validate_source_archive") as source,
                mock.patch.object(release, "_bundle_content") as content,
                mock.patch.object(release, "validate_dmg") as dmg,
            ):
                self.assertEqual(
                    release.validate_assets(root, root, IDENTITY, True, runner),
                    manifest,
                )
                source.assert_called_once_with(
                    root, root / names["source"], release.PUBLIC_FILES
                )
                content.assert_called_once_with(root, BUNDLE, IDENTITY)
                dmg.assert_called_once_with(
                    root, root / names["dmg"], IDENTITY, runner, expected_bundle=BUNDLE
                )
                self.assertIs(
                    dmg.call_args.kwargs["expected_bundle"], content.call_args.args[1]
                )
                dmg.reset_mock()
                release.validate_assets(root, root, IDENTITY, False, runner)
                dmg.assert_not_called()
            runner.assert_not_called()

if __name__ == "__main__":
    unittest.main()
