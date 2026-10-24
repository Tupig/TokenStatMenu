#!/usr/bin/env python3
"""Profile-bearing release checks using only synthetic profiles and mocked tools."""

from __future__ import annotations

import copy
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile

import release_assets as release

TEAM = "AB12CD34EF"
GROUP = "group.tokenstat.menu"
WIDGET = "Contents/PlugIns/TokenStatMenuWidget.appex"
GROUP_KEY = "com.apple.security.application-groups"
TEAM_KEY = "com.apple.developer.team-identifier"
APP_ID_KEY = "com.apple.application-identifier"
SANDBOX_KEY = "com.apple.security.app-sandbox"


class ProfileReleaseChecks(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tokenstat-profile-check-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.root = self.base / "source"
        resources = self.root / "Resources"
        resources.mkdir(parents=True)
        source = plistlib.loads(
            (Path(__file__).resolve().parents[1] / "Resources/Info.plist").read_bytes()
        )
        source.update(CFBundleShortVersionString="1.1.7", CFBundleVersion="21")
        (resources / "Info.plist").write_bytes(plistlib.dumps(source))
        (resources / "AppIcon.icns").write_bytes(b"synthetic-icon")
        self.identity = release.ReleaseIdentity("1.1.7", "21", "v1.1.7", "a" * 40)
        self.app = self.base / "TokenStatMenu.app"
        self.bundles = (self.app, self.app / WIDGET)
        self.ids = ("com.tupig.TokenStatMenu", "com.tupig.TokenStatMenu.Widget")
        app_info = dict(
            source,
            TokenStatWidgetGroup=GROUP,
            TokenStatSourceRevision=self.identity.commit,
            TokenStatSourceState="clean",
        )
        widget_info = {
            "CFBundleIdentifier": self.ids[1],
            "CFBundleExecutable": "TokenStatMenuWidget",
            "CFBundlePackageType": "XPC!",
            "CFBundleShortVersionString": "1.1.7",
            "CFBundleVersion": "21",
            "TokenStatWidgetGroup": GROUP,
            "TokenStatSourceRevision": self.identity.commit,
            "TokenStatSourceState": "clean",
            "NSExtension": {
                "NSExtensionPointIdentifier": "com.apple.widgetkit-extension"
            },
        }
        content = {name: b"synthetic-payload" for name in release.WIDGET_APP_FILES}
        content.update(
            {
                "Contents/Info.plist": plistlib.dumps(app_info),
                "Contents/PkgInfo": b"APPL????",
                "Contents/Resources/AppIcon.icns": b"synthetic-icon",
                WIDGET + "/Contents/Info.plist": plistlib.dumps(widget_info),
            }
        )
        for name, data in content.items():
            path = self.app / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(release.WIDGET_APP_FILES[name])
        self.profiles = []
        self.leaves = [b"synthetic-app-leaf-DER", b"synthetic-widget-leaf-DER"]
        self.trusted = [True, True]
        self.extracted_paths = []
        self.entitlements = []
        self.details = []
        self.profile_paths = [
            bundle / "Contents/embedded.provisionprofile" for bundle in self.bundles
        ]
        now = datetime.now(timezone.utc).replace(tzinfo=None)
        for index, (path, identifier) in enumerate(zip(self.profile_paths, self.ids)):
            path.write_bytes(b"synthetic-CMS-" + str(index).encode())
            path.chmod(0o644)
            entitlements = {
                GROUP_KEY: [GROUP],
                TEAM_KEY: TEAM,
                APP_ID_KEY: TEAM + "." + identifier,
            }
            if index:
                entitlements[SANDBOX_KEY] = True
            self.entitlements.append(entitlements)
            self.profiles.append(
                {
                    "TeamIdentifier": [TEAM],
                    "ApplicationIdentifierPrefix": [TEAM],
                    "Platform": ["OSX"],
                    "ProvisionsAllDevices": True,
                    "CreationDate": now - timedelta(days=1),
                    "ExpirationDate": now + timedelta(days=1),
                    "Entitlements": copy.deepcopy(entitlements),
                    "DeveloperCertificates": [self.leaves[index]],
                }
            )
            self.details.append(
                f"Identifier={identifier}\nTeamIdentifier={TEAM}\n"
                f"Authority=Developer ID Application: Synthetic Fixture ({TEAM})\n"
                "Authority=Developer ID Certification Authority\nAuthority=Apple Root CA\n"
                "CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+2 location=embedded\n"
                "Timestamp=synthetic\n"
            )
        self.calls = []
        self.failure = None

    def tool(self, args, **kwargs):
        self.calls.append(args)
        if args[0] == "/usr/bin/security":
            self.assertEqual(args[:4], ["/usr/bin/security", "cms", "-D", "-i"])
            self.assertEqual(len(args), 5)
            self.assertNotIn("text", kwargs)
            index = self.profile_paths.index(Path(args[4]))
            return subprocess.CompletedProcess(
                args, 0, plistlib.dumps(self.profiles[index]), b""
            )
        if args[0] == "lipo":
            return subprocess.CompletedProcess(args, 0, "arm64\n", "")
        self.assertEqual(args[0], "codesign")
        index = self.bundles.index(Path(args[-1]))
        if "--entitlements" in args:
            output = plistlib.dumps(self.entitlements[index]).decode()
        elif "--verbose=4" in args:
            output = self.details[index]
        elif "--test-requirement" in args:
            requirement = args[args.index("--test-requirement") + 1]
            self.assertEqual(
                requirement,
                'anchor apple generic and identifier "' + self.ids[index] + '"'
                ' and certificate leaf[subject.OU] = "' + TEAM + '"'
                " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists",
            )
            self.assertIn("--strict", args)
            self.assertIn("--verify", args)
            return subprocess.CompletedProcess(
                args, 0 if self.trusted[index] else 1, "", ""
            )
        elif "--extract-certificates" in args:
            prefix = Path(args[args.index("--extract-certificates") + 1])
            self.assertTrue(prefix.parent.is_dir())
            self.assertFalse(prefix.is_relative_to(self.app))
            self.extracted_paths.append(prefix.parent)
            Path(str(prefix) + "0").write_bytes(self.leaves[index])
            output = ""
        else:
            self.assertEqual(args[1:-1], ["--verify", "--deep", "--strict"])
            return subprocess.CompletedProcess(args, 1 if self.failure else 0, "", "")
        self.assertEqual(args[args.index("--arch") + 1], "arm64")
        return subprocess.CompletedProcess(args, 0, output, "")

    def validate(self):
        return release.validate_app(self.root, self.app, self.identity, self.tool)

    def test_paired_profiles_validate_using_only_two_explicit_readonly_paths(self):
        files = self.validate()
        self.assertEqual(
            set(files), set(release.WIDGET_APP_FILES) | set(release.PROFILE_FILES)
        )
        decoded = [args[-1] for args in self.calls if args[0] == "/usr/bin/security"]
        self.assertEqual(decoded, list(map(str, self.profile_paths)))
        self.assertEqual(sum("--verbose=4" in args for args in self.calls), 2)
        self.assertEqual(sum("--test-requirement" in args for args in self.calls), 2)
        self.assertEqual(len(self.extracted_paths), 2)
        self.assertEqual(len(set(self.extracted_paths)), 2)
        self.assertTrue(all(not path.exists() for path in self.extracted_paths))

    def test_both_identifier_spellings_match_profile_and_signature(self):
        for index in range(2):
            value = self.entitlements[index][APP_ID_KEY]
            self.entitlements[index]["application-identifier"] = value
            self.profiles[index]["Entitlements"]["application-identifier"] = value
        self.validate()
        for index in range(2):
            del self.entitlements[index][APP_ID_KEY]
            del self.profiles[index]["Entitlements"][APP_ID_KEY]
        self.validate()

    def test_profile_pair_is_version_gated(self):
        for missing in self.profile_paths:
            raw = missing.read_bytes()
            missing.unlink()
            with self.assertRaisesRegex(ValueError, "complete 1.1.7"):
                self.validate()
            missing.write_bytes(raw)
        old = release.ReleaseIdentity("1.1.6", "21", "v1.1.6", "a" * 40)
        with self.assertRaisesRegex(ValueError, "complete 1.1.7"):
            release.validate_app(self.root, self.app, old, self.tool)

    def test_profile_files_must_be_nonempty_regular_0644_without_extra_paths(self):
        for path in self.profile_paths:
            raw = path.read_bytes()
            for mode in (0o600, 0o755):
                path.chmod(mode)
                with self.assertRaises(ValueError):
                    self.validate()
            path.chmod(0o644)
            path.write_bytes(b"")
            with self.assertRaises(ValueError):
                self.validate()
            path.unlink()
            outside = self.base / "outside-profile"
            outside.write_bytes(raw)
            path.symlink_to(outside)
            with self.assertRaises(ValueError):
                self.validate()
            path.unlink()
            path.mkdir()
            with self.assertRaises(ValueError):
                self.validate()
            path.rmdir()
            path.write_bytes(raw)
            path.chmod(0o644)
        extra = self.app / "Contents/other.provisionprofile"
        extra.write_bytes(b"not-allowed")
        with self.assertRaises(ValueError):
            self.validate()

    def test_profile_identity_validity_and_distribution_fail_closed(self):
        now = datetime.now(timezone.utc).replace(tzinfo=None)
        mutations = [
            lambda p: p.update(TeamIdentifier=[]),
            lambda p: p.update(TeamIdentifier=[TEAM, TEAM]),
            lambda p: p.update(TeamIdentifier=["bad-team"]),
            lambda p: p.update(ApplicationIdentifierPrefix=["ZZ99YY88XX"]),
            lambda p: p.update(ExpirationDate=now - timedelta(seconds=1)),
            lambda p: p.pop("ExpirationDate"),
            lambda p: p.update(ExpirationDate="2099-01-01"),
            lambda p: p.update(CreationDate=now + timedelta(days=2)),
            lambda p: p.update(Platform=["iOS"]),
            lambda p: p.update(ProvisionsAllDevices=1),
            lambda p: p.pop("ProvisionsAllDevices"),
            lambda p: p.update(ProvisionedDevices=[]),
            lambda p: p.update(Entitlements=[]),
            lambda p: p.pop("DeveloperCertificates"),
            lambda p: p.update(DeveloperCertificates=[]),
            lambda p: p.update(DeveloperCertificates=[b""]),
            lambda p: p.update(DeveloperCertificates=["not-DER"]),
            lambda p: p["Entitlements"].update({TEAM_KEY: "ZZ99YY88XX"}),
            lambda p: p["Entitlements"].pop(APP_ID_KEY),
            lambda p: p["Entitlements"].update({APP_ID_KEY: TEAM + ".*"}),
            lambda p: p["Entitlements"].update(
                {"application-identifier": TEAM + ".wrong"}
            ),
            lambda p: p["Entitlements"].update({GROUP_KEY: ["group.other"]}),
            lambda p: p["Entitlements"].update({GROUP_KEY: ["*"]}),
            lambda p: p["Entitlements"].update({"get-task-allow": True}),
            lambda p: p["Entitlements"].update(
                {"com.apple.security.get-task-allow": 0}
            ),
        ]
        for index in range(2):
            baseline = copy.deepcopy(self.profiles[index])
            for number, mutate in enumerate(mutations):
                with self.subTest(bundle=index, mutation=number):
                    self.profiles[index] = copy.deepcopy(baseline)
                    mutate(self.profiles[index])
                    with self.assertRaises(ValueError):
                        self.validate()
            self.profiles[index] = copy.deepcopy(baseline)
            self.profiles[index]["Entitlements"][SANDBOX_KEY] = not bool(index)
            with self.assertRaises(ValueError):
                self.validate()
            self.profiles[index] = baseline

    def test_profile_pair_team_and_team_prefixed_group_must_match(self):
        profile = self.profiles[1]
        other = "ZZ99YY88XX"
        profile.update(TeamIdentifier=[other], ApplicationIdentifierPrefix=[other])
        profile["Entitlements"].update(
            {TEAM_KEY: other, APP_ID_KEY: other + "." + self.ids[1]}
        )
        with self.assertRaisesRegex(ValueError, "pair Teams differ"):
            self.validate()
        with self.assertRaisesRegex(ValueError, "App Group Team differs"):
            release._profile_entitlements(
                self.profile_paths[0],
                self.profile_paths[0].read_bytes(),
                self.ids[0],
                other + ".com.example",
                False,
                self.tool,
            )

    def test_signed_entitlements_have_closed_permission_surface(self):
        for index in range(2):
            baseline = copy.deepcopy(self.entitlements[index])
            for key, value in (
                (TEAM_KEY, "ZZ99YY88XX"),
                (APP_ID_KEY, TEAM + ".wrong"),
                (GROUP_KEY, ["group.other"]),
                (SANDBOX_KEY, not bool(index)),
                ("get-task-allow", False),
                ("com.apple.security.get-task-allow", True),
                ("com.apple.security.network.client", True),
            ):
                self.entitlements[index] = dict(baseline, **{key: value})
                with self.subTest(bundle=index, key=key), self.assertRaises(ValueError):
                    self.validate()
            self.entitlements[index] = baseline

    def test_actual_codesign_team_identifier_and_authority_are_checked(self):
        for index in range(2):
            baseline = self.details[index]
            bad_details = [
                baseline.replace("TeamIdentifier=" + TEAM, "TeamIdentifier=ZZ99YY88XX"),
                baseline + "TeamIdentifier=" + TEAM + "\n",
                baseline.replace(
                    "Identifier=" + self.ids[index], "Identifier=com.other"
                ),
                baseline.replace("Developer ID Application:", "Apple Development:"),
                baseline.replace("(" + TEAM + ")", "(ZZ99YY88XX)"),
                baseline.replace(
                    "Authority=Developer ID Certification Authority\n", ""
                ),
                baseline.replace("flags=0x10000(runtime)", "flags=0x0(none)"),
                baseline.replace("Timestamp=synthetic\n", ""),
                baseline + "Signature=adhoc\n",
                "Signature=adhoc\n",
            ]
            for details in bad_details:
                self.details[index] = details
                with (
                    self.subTest(bundle=index, details=details),
                    self.assertRaises(ValueError),
                ):
                    self.validate()
            self.details[index] = baseline
        chain_baseline = self.details[0]
        for snippet, replacement in (
            ("Authority=Developer ID Certification Authority\n", ""),
            ("flags=0x10000(runtime)", "flags=0x0(none)"),
            ("Timestamp=synthetic\n", ""),
        ):
            self.details[0] = chain_baseline.replace(snippet, replacement)
            with (
                self.subTest(snippet=snippet),
                self.assertRaisesRegex(ValueError, "timestamped hardened Developer ID"),
            ):
                self.validate()
        self.details[0] = chain_baseline
        self.failure = True
        with self.assertRaisesRegex(ValueError, "strict application signature"):
            self.validate()

    def test_decode_failure_malformed_data_and_changed_profile_fail_closed(self):
        for returncode, data in (
            (1, b""),
            (0, b"not-a-plist"),
            (0, plistlib.dumps([])),
        ):

            def tool(args, **kwargs):
                if args[0] == "/usr/bin/security":
                    return subprocess.CompletedProcess(args, returncode, data, b"")
                return self.tool(args, **kwargs)

            with (
                self.subTest(returncode=returncode, data=data),
                self.assertRaises(ValueError),
            ):
                release.validate_app(self.root, self.app, self.identity, tool)

        def changed(args, **kwargs):
            output = self.tool(args, **kwargs)
            if args[0] == "/usr/bin/security":
                Path(args[-1]).write_bytes(b"changed-profile")
            return output

        with self.assertRaisesRegex(ValueError, "changed during validation"):
            release.validate_app(self.root, self.app, self.identity, changed)

    def test_no_profile_development_shape_is_retained_without_identity_claims(self):
        for path in self.profile_paths:
            path.unlink()
        for entitlements in self.entitlements:
            entitlements.pop(TEAM_KEY)
            entitlements.pop(APP_ID_KEY)
        self.validate()
        self.assertFalse(
            any(
                args[0] == "/usr/bin/security" or "--verbose=4" in args
                for args in self.calls
            )
        )

    def test_native_tool_errors_and_unreadable_signatures_fail_closed(self):
        for operation in (
            "cms",
            "--entitlements",
            "--verbose=4",
            "--test-requirement",
            "--extract-certificates",
        ):
            for failure in (
                OSError("synthetic"),
                subprocess.SubprocessError("synthetic"),
                None,
            ):

                def failed(args, **kwargs):
                    if operation in args:
                        if failure is not None:
                            raise failure
                        output = b"" if args[0] == "/usr/bin/security" else ""
                        return subprocess.CompletedProcess(args, 1, output, output)
                    return self.tool(args, **kwargs)

                with (
                    self.subTest(operation=operation, failure=failure),
                    self.assertRaises(ValueError),
                ):
                    release.validate_app(self.root, self.app, self.identity, failed)

    def test_displayed_developer_id_names_cannot_replace_apple_anchor(self):
        for index in range(2):
            self.trusted[index] = False
            baseline = self.details[index]
            self.details[index] = "\n".join(baseline.splitlines()[:3]) + "\n"
            # A truncated self-reported chain fails before the Apple anchor check.
            with (
                self.subTest(bundle=index),
                self.assertRaisesRegex(ValueError, "timestamped hardened Developer ID"),
            ):
                self.validate()
            self.trusted[index] = True
            self.details[index] = baseline

    def test_actual_leaf_must_be_in_each_profiles_developer_certificates(self):
        for index in range(2):
            baseline = self.profiles[index]["DeveloperCertificates"]
            self.profiles[index]["DeveloperCertificates"] = [b"unrelated-DER"]
            with (
                self.subTest(bundle=index),
                self.assertRaisesRegex(ValueError, "not authorized"),
            ):
                self.validate()
            self.assertTrue(all(not path.exists() for path in self.extracted_paths))
            self.profiles[index]["DeveloperCertificates"] = [
                b"unrelated-DER",
                *baseline,
            ]
            self.validate()
            self.profiles[index]["DeveloperCertificates"] = baseline

    def test_missing_empty_or_symbolic_extracted_leaf_is_rejected(self):
        for kind in ("missing", "empty", "symlink"):

            def tool(args, **kwargs):
                result = self.tool(args, **kwargs)
                if "--extract-certificates" in args:
                    leaf = Path(args[args.index("--extract-certificates") + 1] + "0")
                    leaf.unlink()
                    if kind == "empty":
                        leaf.write_bytes(b"")
                    elif kind == "symlink":
                        leaf.symlink_to(self.profile_paths[0])
                return result

            with self.subTest(kind=kind), self.assertRaises(ValueError):
                release.validate_app(self.root, self.app, self.identity, tool)

    def archive_assets(self, content):
        directory = self.base / "assets"
        directory.mkdir(exist_ok=True)
        release._canonical_zip(
            directory / "TokenStatMenu.zip", "TokenStatMenu.app/", content
        )
        (directory / "TokenStatMenu-source.zip").write_bytes(b"synthetic-source")
        (directory / "TokenStatMenu.dmg").write_bytes(b"synthetic-dmg")
        manifest = dict(release._identity_fields(self.identity), assets={})
        for kind, name in release._names(self.identity).items():
            raw = (directory / name).read_bytes()
            manifest["assets"][kind] = dict(
                name=name, bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest()
            )
        (directory / "release-manifest.json").write_text(json.dumps(manifest))
        (directory / "SHA256SUMS").write_bytes(
            release._sums(
                directory,
                [*release._names(self.identity).values(), "release-manifest.json"],
            )
        )
        return directory

    def test_zip_exact_pair_shape_source_validation_and_dmg_payload_comparison_are_preserved(
        self,
    ):
        content = self.validate()
        directory = self.archive_assets(content)
        with (
            mock.patch.object(release, "validate_source_archive") as source,
            mock.patch.object(release, "validate_dmg") as dmg,
        ):
            release.validate_assets(
                self.root, directory, self.identity, True, self.tool
            )
        source.assert_called_once_with(
            self.root, directory / "TokenStatMenu-source.zip", release.PUBLIC_FILES
        )
        self.assertEqual(dmg.call_args.kwargs["expected_bundle"], content)
        for name in release.PROFILE_FILES:
            for replacement in (None, (b"", 0o644), (b"profile", 0o600)):
                modified = dict(content)
                if replacement is None:
                    del modified[name]
                else:
                    modified[name] = replacement
                directory = self.archive_assets(modified)
                with (
                    mock.patch.object(release, "validate_source_archive"),
                    self.assertRaises(ValueError),
                ):
                    release.validate_assets(self.root, directory, self.identity)
        directory = self.archive_assets(content)
        with zipfile.ZipFile(directory / "TokenStatMenu.zip") as archive:
            entries = [
                (member.filename, archive.read(member), member.external_attr)
                for member in archive.infolist()
            ]
        # A symlink cannot hide behind the profile allowlist, even with fresh hashes.
        with zipfile.ZipFile(directory / "TokenStatMenu.zip", "w") as archive:
            for name, raw, mode in entries:
                member = zipfile.ZipInfo(name)
                member.create_system = 3
                member.external_attr = (
                    ((stat.S_IFLNK | 0o644) << 16)
                    if name.endswith("embedded.provisionprofile")
                    else mode
                )
                archive.writestr(member, raw)
        manifest_path = directory / "release-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        raw = (directory / "TokenStatMenu.zip").read_bytes()
        manifest["assets"]["universal"].update(
            bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest()
        )
        manifest_path.write_text(json.dumps(manifest))
        (directory / "SHA256SUMS").write_bytes(
            release._sums(
                directory,
                [*release._names(self.identity).values(), "release-manifest.json"],
            )
        )
        with (
            mock.patch.object(release, "validate_source_archive"),
            self.assertRaisesRegex(ValueError, "symbolic link"),
        ):
            release.validate_assets(self.root, directory, self.identity)


class ReleaseSafetyRegressionChecks(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tokenstat-release-safety-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.dmg = self.base / "synthetic.dmg"
        self.dmg.write_bytes(b"synthetic-image")
        self.mount = self.base / "exclusive-mount"
        self.calls = []
        self.attach_status = 0
        self.attach_error = False
        self.attach_output = "/dev/disk999\tApple_HFS\t/unrelated-volume\n"
        self.detach_status = 0
        self.detach_error = False
        self.imageinfo_status = 0
        self.identity = release.ReleaseIdentity("1.1.7", "21", "v1.1.7", "a" * 40)

    def tool(self, args, **kwargs):
        self.calls.append(args)
        self.assertEqual(args[0], "/usr/bin/hdiutil")
        if args[1] == "imageinfo":
            return subprocess.CompletedProcess(args, self.imageinfo_status, "", "")
        if args[1] == "attach":
            self.assertEqual(args[args.index("-mountpoint") + 1], str(self.mount))
            (self.mount / "TokenStatMenu.app").mkdir()
            (self.mount / "Applications").symlink_to("/Applications")
            (self.mount / "sentinel").write_bytes(b"preserve-mounted-content")
            if self.attach_error:
                raise OSError("synthetic partial attach")
            return subprocess.CompletedProcess(
                args, self.attach_status, self.attach_output, ""
            )
        self.assertEqual(args[1], "detach")
        if self.detach_error:
            raise OSError("synthetic detach failure")
        return subprocess.CompletedProcess(args, self.detach_status, "", "")

    def validate(self):
        def make_mount(**kwargs):
            self.mount.mkdir()
            return str(self.mount)

        with (
            mock.patch.object(release.tempfile, "mkdtemp", side_effect=make_mount),
            mock.patch.object(release, "validate_app") as app,
        ):
            try:
                return release.validate_dmg(
                    self.base, self.dmg, self.identity, self.tool
                )
            finally:
                app.assert_not_called()

    def test_unparseable_successful_attach_detaches_only_exclusive_mountpoint(self):
        with self.assertRaisesRegex(ValueError, "no owned device"):
            self.validate()
        self.assertEqual(
            self.calls[-1], ["/usr/bin/hdiutil", "detach", str(self.mount)]
        )
        self.assertFalse(self.mount.exists())

    def test_failed_or_raised_partial_attach_detaches_exclusive_mountpoint(self):
        for raised in (False, True):
            self.calls.clear()
            self.attach_status = 1
            self.attach_error = raised
            with (
                self.subTest(raised=raised),
                self.assertRaises((ValueError, RuntimeError)),
            ):
                self.validate()
            self.assertEqual(
                self.calls[-1], ["/usr/bin/hdiutil", "detach", str(self.mount)]
            )
            self.assertFalse(self.mount.exists())

    def test_partial_attach_with_owned_device_prefers_owned_device(self):
        self.attach_status = 1
        self.attach_output += f"/dev/disk900s1\tApple_HFS\t{self.mount}\n"
        with self.assertRaisesRegex(ValueError, "attach failed"):
            self.validate()
        self.assertEqual(
            self.calls[-1], ["/usr/bin/hdiutil", "detach", "/dev/disk900s1"]
        )
        self.assertFalse(self.mount.exists())

    def test_detach_failure_preserves_directory_and_contents_without_recursive_delete(
        self,
    ):
        for raised in (False, True):
            self.calls.clear()
            self.detach_status = 1
            self.detach_error = raised
            with mock.patch.object(release.shutil, "rmtree") as delete:
                with (
                    self.subTest(raised=raised),
                    self.assertRaisesRegex(RuntimeError, "owned DMG detach failed"),
                ):
                    self.validate()
                delete.assert_not_called()
            self.assertTrue(self.mount.is_dir())
            self.assertEqual(
                (self.mount / "sentinel").read_bytes(), b"preserve-mounted-content"
            )
            # Remove only our synthetic, never-mounted fixture between cases.
            (self.mount / "sentinel").unlink()
            (self.mount / "Applications").unlink()
            (self.mount / "TokenStatMenu.app").rmdir()
            self.mount.rmdir()

    def test_imageinfo_failure_does_not_detach_unattempted_mount(self):
        self.imageinfo_status = 1
        with self.assertRaisesRegex(ValueError, "imageinfo failed"):
            self.validate()
        self.assertEqual([args[1] for args in self.calls], ["imageinfo"])
        self.assertFalse(self.mount.exists())

    def test_release_notes_are_bilingual_and_do_not_infer_signature_from_profiles(self):
        client = release.GitHubClient(self.identity)
        captured = []

        def command(arguments, phase):
            self.assertEqual(phase, "create-draft")
            path = Path(arguments[arguments.index("--notes-file") + 1])
            captured.append(path.read_text())
            return b""

        with (
            mock.patch.object(client, "_command", side_effect=command),
            mock.patch.object(client, "lookup", return_value={"draft": True}),
        ):
            client.create_draft(self.identity)
        self.assertEqual(len(captured), 1)
        notes = captured[0]
        for expected in (
            "签名类型以本次资产验签为准",
            "Developer ID 和公证须独立核验",
            "不能因存在 profile 推断",
            "The signature type must be determined by verification",
            "Developer ID signing and notarization require independent verification",
            "neither may be inferred from the presence of a profile",
        ):
            self.assertIn(expected, notes)
        self.assertNotIn("当前为 ad hoc", notes)
        self.assertNotIn("Downloads are ad hoc signed", notes)
        self.assertNotIn("Developer ID authorization validated", notes)


if __name__ == "__main__":
    unittest.main()
