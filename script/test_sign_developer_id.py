#!/usr/bin/env python3
# fmt: off
"""Offline signing-policy tests: every external process is intercepted."""

from __future__ import annotations

import argparse
import contextlib
import copy
from datetime import datetime, timedelta, timezone
import hashlib
import io
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import sign_developer_id as signing

TEAM = "ABCDE12345"
GROUP = TEAM + ".com.tupig.TokenStatMenu"
NAME = "Developer ID Application: Synthetic Test (" + TEAM + ")"
CERTIFICATE = b"synthetic certificate fixture, never a real credential"
FINGERPRINT = hashlib.sha1(CERTIFICATE).hexdigest().upper()
NOW = datetime(2026, 10, 24, tzinfo=timezone.utc)
IDS = ("com.tupig.TokenStatMenu", "com.tupig.TokenStatMenu.Widget")

class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tokenstat-signing-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "Resources").mkdir()
        for name in (
            "Info.plist",
            "WidgetExtension-Info.plist",
            "TokenStatMenu.entitlements",
            "WidgetExtension.entitlements",
        ):
            shutil.copyfile(
                signing.ROOT / "Resources" / name, self.root / "Resources" / name
            )
        (self.root / "TokenStatMenu.xcodeproj").mkdir()
        shutil.copyfile(
            signing.ROOT / "TokenStatMenu.xcodeproj/project.pbxproj",
            self.root / "TokenStatMenu.xcodeproj/project.pbxproj",
        )
        self.args = argparse.Namespace(
            app=str(self.root / "dist/TokenStatMenu.app"),
            team=TEAM,
            group=GROUP,
            identity=NAME,
            app_profile=str(self.root / "app.provisionprofile"),
            widget_profile=str(self.root / "widget.provisionprofile"),
            validate_only=True,
        )
        self.profiles = {}
        for path, identifier in zip(
            (self.args.app_profile, self.args.widget_profile), IDS
        ):
            Path(path).write_bytes(b"synthetic explicit CMS input")
            self.profiles[path] = {
                "CreationDate": (NOW - timedelta(days=1)).replace(tzinfo=None),
                "ExpirationDate": (NOW + timedelta(days=1)).replace(tzinfo=None),
                "TeamIdentifier": [TEAM],
                "Platform": ["OSX"],
                "ApplicationIdentifierPrefix": [TEAM],
                "ProvisionsAllDevices": True,
                "DeveloperCertificates": [CERTIFICATE],
                "Entitlements": {
                    signing.TEAM_KEY: TEAM,
                    signing.IDENTIFIER_KEYS[0]: TEAM + "." + identifier,
                    signing.GROUP_KEY: [GROUP],
                    "get-task-allow": False,
                },
            }
        self.signed_entitlements = {}
        self.details_override = None
        self.entitlements_override = None
        self.leaf = CERTIFICATE
        self.certificate_name = NAME
        self.certificate_team = TEAM
        self.certificate_oid = "1.2.840.113635.100.6.1.13"
        self.certificate_start = "Jan  1 00:00:00 2026 GMT"
        self.certificate_end = "Jan  1 00:00:00 2027 GMT"
        self.extra_certificates = {}
        self.fail_sign = False
        self.apple_anchored = True
        self.subprocess = mock.patch.object(
            signing.subprocess, "run", side_effect=self.fake_run
        ).start()
        self.addCleanup(mock.patch.stopall)

    def fake_run(self, command, **kwargs):
        self.assertTrue(kwargs["capture_output"])
        self.assertTrue(kwargs["check"])
        self.assertEqual(kwargs["timeout"], 120)
        self.assertNotIn("shell", kwargs)
        stdout = stderr = b""
        if command[0] == signing.SECURITY:
            self.assertEqual(command[:4], [signing.SECURITY, "cms", "-D", "-i"])
            self.assertIn(command[4], self.profiles)
            stdout = plistlib.dumps(self.profiles[command[4]])
        elif command[0] == signing.OPENSSL:
            certificate = kwargs["input"]
            if certificate == CERTIFICATE:
                name, team, oid, start, end = (
                    self.certificate_name, self.certificate_team, self.certificate_oid,
                    self.certificate_start, self.certificate_end,
                )
            else:
                self.assertIn(certificate, self.extra_certificates)
                metadata = self.extra_certificates[certificate]
                if isinstance(metadata, Exception):
                    raise metadata
                name, team, oid, start, end = metadata
            digest = hashlib.sha1(certificate).hexdigest().upper()
            if "-checkend" in command:
                stdout = f"notBefore={start}\nnotAfter={end}\n".encode()
                return subprocess.CompletedProcess(command, 0, stdout, stderr)
            stdout = (
                f"subject=\n    OU = {team}\n"
                f"    CN = {name}\n"
                f"SHA1 Fingerprint={digest}\n"
                f"    {oid}: critical\n"
            ).encode()
        elif command[0] == signing.CODESIGN:
            bundle = command[-1]
            if "--sign" in command:
                if self.fail_sign:
                    raise subprocess.CalledProcessError(
                        1, command, stderr=b"SECRET TOOL OUTPUT"
                    )
                self.assertNotIn("--deep", command)
                self.assertIn("--timestamp", command)
                self.assertEqual(command[command.index("--options") + 1], "runtime")
                self.assertEqual(command[command.index("--sign") + 1], FINGERPRINT)
                self.signed_entitlements[bundle] = plistlib.loads(
                    Path(command[command.index("--entitlements") + 1]).read_bytes()
                )
            elif "--test-requirement" in command:
                identifier = IDS[1] if bundle.endswith(".appex") else IDS[0]
                expected = (
                    'anchor apple generic and identifier "' + identifier + '"'
                    ' and certificate leaf[subject.OU] = "' + TEAM + '"'
                    " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
                )
                self.assertEqual(command, [signing.CODESIGN, "--verify", "--strict",
                                          "--test-requirement", expected, bundle])
                if not self.apple_anchored:
                    raise subprocess.CalledProcessError(
                        1, command, stderr=b"PRIVATE untrusted self-signed certificate",
                    )
            elif "--verbose=4" in command:
                stderr = (
                    self.details_override
                    or (
                        f"Authority={NAME}\nAuthority=Developer ID Certification Authority\n"
                        "Authority=Apple Root CA\n"
                        f"TeamIdentifier={TEAM}\nCodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1\n"
                        "Timestamp=Oct 24, 2026 at 12:00:00\n"
                    ).encode()
                )
            elif "--entitlements" in command:
                value = self.entitlements_override
                stdout = plistlib.dumps(
                    self.signed_entitlements[bundle] if value is None else value
                )
            elif "--extract-certificates" in command:
                prefix = command[command.index("--extract-certificates") + 1]
                Path(prefix + "0").write_bytes(self.leaf)
            else:
                self.assertIn("--verify", command)
        else:
            self.fail(f"Unexpected external command: {command[0]}")
        return subprocess.CompletedProcess(command, 0, stdout, stderr)

    def execute(self):
        signing.execute(self.args, root=self.root, environment={}, now=NOW)

    def make_app(self):
        self.args.validate_only = False
        app = Path(self.args.app)
        for bundle, identifier, executable in (
            (app, IDS[0], "TokenStatMenu"),
            (
                app / "Contents/PlugIns/TokenStatMenuWidget.appex",
                IDS[1],
                "TokenStatMenuWidget",
            ),
        ):
            (bundle / "Contents/MacOS").mkdir(parents=True)
            (bundle / "Contents/MacOS" / executable).write_bytes(
                b"synthetic executable"
            )
            (bundle / "Contents/Info.plist").write_bytes(
                plistlib.dumps(
                    {
                        "CFBundleIdentifier": identifier,
                        "CFBundleExecutable": executable,
                        "TokenStatWidgetGroup": self.args.group,
                    }
                )
            )
        return app

    def test_source_bundle_identifiers(self):
        self.assertEqual(signing.bundle_ids(self.root), IDS)

    def test_validate_only_never_reads_or_creates_app_or_signs(self):
        with mock.patch.object(
            signing, "inspect_app", side_effect=AssertionError("app read")
        ):
            self.execute()
        self.assertFalse(Path(self.args.app).exists())
        commands = [call.args[0] for call in self.subprocess.call_args_list]
        self.assertEqual(
            [c for c in commands if c[0] == signing.SECURITY],
            [
                [signing.SECURITY, "cms", "-D", "-i", self.args.app_profile],
                [signing.SECURITY, "cms", "-D", "-i", self.args.widget_profile],
            ],
        )
        self.assertFalse(any(c[0] == signing.CODESIGN for c in commands))

    def test_ci_presence_blocks_all_external_commands(self):
        for key in signing.CI_KEYS:
            for value in ("", "false", "true"):
                with (
                    self.subTest(key=key, value=value),
                    self.assertRaisesRegex(signing.SigningError, "CI"),
                ):
                    signing.execute(
                        self.args, root=self.root, environment={key: value}, now=NOW
                    )
        self.subprocess.assert_not_called()

    def test_argument_rejections_happen_before_profile_read(self):
        for key, value in (
            ("team", "short"),
            ("team", "abcde12345"),
            ("group", "OTHER12345.name"),
            ("group", "group.*"),
            ("group", "group.-bad"),
            ("group", "group.bad."),
            ("group", "group." + "x" * 128),
            ("identity", "-"),
            ("identity", "Apple Development: Synthetic (" + TEAM + ")"),
            ("identity", "Developer ID Application"),
            ("identity", "a" * 39),
            ("identity", "Developer ID Application: Test (OTHER12345)"),
        ):
            with self.subTest(key=key, value=value):
                args = copy.copy(self.args)
                setattr(args, key, value)
                with self.assertRaises(signing.SigningError):
                    signing.execute(args, root=self.root, environment={}, now=NOW)
        self.subprocess.assert_not_called()

    def test_explicit_sha1_and_group_prefix_are_supported(self):
        self.args.identity = FINGERPRINT.lower()
        self.args.group = "group.com.tupig.TokenStatMenu"
        for profile in self.profiles.values():
            profile["Entitlements"][signing.GROUP_KEY] = [self.args.group]
        self.execute()

    def test_profile_rejections(self):
        cases = [
            ("ExpirationDate", NOW.replace(tzinfo=None)),
            ("CreationDate", (NOW + timedelta(seconds=1)).replace(tzinfo=None)),
            ("ExpirationDate", "not a date"),
            ("TeamIdentifier", ["OTHER12345"]),
            ("Platform", ["iOS"]),
            ("ProvisionsAllDevices", False),
            ("ProvisionedDevices", []),
            ("ApplicationIdentifierPrefix", ["OTHER12345"]),
            ("DeveloperCertificates", []),
        ]
        original = copy.deepcopy(self.profiles[self.args.app_profile])
        for key, value in cases:
            with self.subTest(key=key):
                self.profiles[self.args.app_profile] = copy.deepcopy(original)
                self.profiles[self.args.app_profile][key] = value
                with self.assertRaises(signing.SigningError):
                    self.execute()

    def test_entitlement_rejections(self):
        original = copy.deepcopy(self.profiles[self.args.app_profile])
        cases = [
            (signing.TEAM_KEY, "OTHER12345"),
            (signing.GROUP_KEY, ["group.*"]),
            (signing.GROUP_KEY, GROUP),
            ("get-task-allow", True),
            ("com.apple.security.get-task-allow", True),
            (signing.IDENTIFIER_KEYS[0], TEAM + ".*"),
            (signing.IDENTIFIER_KEYS[0], TEAM + "." + IDS[1]),
            (signing.IDENTIFIER_KEYS[1], TEAM + ".different"),
            (signing.SANDBOX_KEY, True),
        ]
        for key, value in cases:
            with self.subTest(key=key):
                self.profiles[self.args.app_profile] = copy.deepcopy(original)
                self.profiles[self.args.app_profile]["Entitlements"][key] = value
                with self.assertRaises(signing.SigningError):
                    self.execute()

    def test_missing_identifier_is_not_fabricated(self):
        del self.profiles[self.args.app_profile]["Entitlements"][
            signing.IDENTIFIER_KEYS[0]
        ]
        with self.assertRaisesRegex(
            signing.SigningError, "explicitly authorize this bundle"
        ):
            self.execute()

    def test_development_certificate_and_wrong_team_fail_even_for_sha1(self):
        self.args.identity = FINGERPRINT
        self.certificate_name = "Apple Development: Synthetic (" + TEAM + ")"
        with self.assertRaises(signing.SigningError):
            self.execute()
        self.certificate_name = NAME
        self.certificate_team = "OTHER12345"
        with self.assertRaises(signing.SigningError):
            self.execute()

    def test_missing_or_symlinked_profile_is_not_decoded(self):
        path = Path(self.args.app_profile)
        path.unlink()
        with self.assertRaises(signing.SigningError):
            self.execute()
        path.symlink_to(self.args.widget_profile)
        with self.assertRaises(signing.SigningError):
            self.execute()
        self.subprocess.assert_not_called()

    def test_matching_certificate_name_without_developer_id_purpose_fails(self):
        self.certificate_oid = "1.2.840.113635.100.6.1.12"
        with self.assertRaises(signing.SigningError):
            self.execute()

    def test_expired_certificate_error_is_redacted(self):
        original = self.subprocess.side_effect

        def expired(command, **kwargs):
            if command[0] == signing.OPENSSL:
                raise subprocess.CalledProcessError(
                    1, command, output=b"PRIVATE CERTIFICATE"
                )
            return original(command, **kwargs)

        self.subprocess.side_effect = expired
        with self.assertRaises(signing.SigningError) as error:
            self.execute()
        self.assertNotIn("PRIVATE", str(error.exception))

    def test_certificate_not_yet_valid_and_expired_dates_fail(self):
        self.certificate_start = "Jan  1 00:00:00 2027 GMT"
        with self.assertRaisesRegex(
            signing.SigningError, "Certificate is not currently valid"
        ):
            self.execute()
        self.certificate_start = "Jan  1 00:00:00 2026 GMT"
        self.certificate_end = "Jan  1 00:00:00 2026 GMT"
        with self.assertRaisesRegex(
            signing.SigningError, "Certificate is not currently valid"
        ):
            self.execute()

    def test_malformed_cms_xml_is_reported_safely(self):
        self.subprocess.return_value = subprocess.CompletedProcess(
            [], 0, b"<plist><dict><", b""
        )
        self.subprocess.side_effect = None
        with self.assertRaisesRegex(signing.SigningError, "Cannot decode"):
            self.execute()

    def add_rotation_certificate(self, name=None):
        certificate = b"synthetic expired rotation certificate"
        self.extra_certificates[certificate] = (
            name or "Developer ID Application: Retired Test (" + TEAM + ")",
            TEAM, self.certificate_oid, "Jan  1 00:00:00 2020 GMT",
            "Jan  1 00:00:00 2021 GMT",
        )
        return certificate

    def validity_inputs(self):
        return [call.kwargs["input"] for call in self.subprocess.call_args_list
                if "-checkend" in call.args[0]]

    def test_rotation_expired_unselected_certificate_does_not_block(self):
        retired = self.add_rotation_certificate()
        for profile in self.profiles.values():
            profile["DeveloperCertificates"] = [retired, CERTIFICATE]
        for identity in (NAME, FINGERPRINT):
            with self.subTest(identity=identity):
                self.subprocess.reset_mock()
                self.args.identity = identity
                self.execute()
                self.assertEqual(self.validity_inputs(), [CERTIFICATE])

    def test_rotation_same_name_sha1_selects_only_explicit_certificate(self):
        retired = self.add_rotation_certificate(NAME)
        for profile in self.profiles.values():
            profile["DeveloperCertificates"] = [CERTIFICATE, retired]
        self.args.identity = FINGERPRINT
        self.execute()
        self.assertEqual(self.validity_inputs(), [CERTIFICATE])

    def test_rotation_name_resolves_common_candidate_before_validity(self):
        retired = self.add_rotation_certificate(NAME)
        self.profiles[self.args.app_profile]["DeveloperCertificates"] = [retired, CERTIFICATE]
        self.execute()
        self.assertEqual(self.validity_inputs(), [CERTIFICATE])

    def test_rotation_selected_expired_certificate_fails_without_fallback(self):
        retired = self.add_rotation_certificate()
        for profile in self.profiles.values():
            profile["DeveloperCertificates"] = [CERTIFICATE, retired]
        for identity in (self.extra_certificates[retired][0], hashlib.sha1(retired).hexdigest()):
            with self.subTest(identity=identity):
                self.subprocess.reset_mock()
                self.args.identity = identity
                with self.assertRaisesRegex(signing.SigningError, "Certificate is not currently valid"):
                    self.execute()
                self.assertEqual(self.validity_inputs(), [retired])
                self.assertFalse(self.signed_entitlements)

    def test_rotation_ambiguous_common_name_does_not_fallback_to_valid_certificate(self):
        retired = self.add_rotation_certificate(NAME)
        for profile in self.profiles.values():
            profile["DeveloperCertificates"] = [CERTIFICATE, retired]
        with self.assertRaisesRegex(signing.SigningError, "unambiguous"):
            self.execute()
        self.assertEqual(self.validity_inputs(), [])

    def test_bad_unselected_certificate_fails_closed_without_disclosure(self):
        retired = self.add_rotation_certificate()
        self.extra_certificates[retired] = subprocess.CalledProcessError(
            1, [signing.OPENSSL], output=b"PRIVATE BAD CERTIFICATE",
        )
        self.profiles[self.args.app_profile]["DeveloperCertificates"] = [CERTIFICATE, retired]
        with self.assertRaises(signing.SigningError) as error:
            self.execute()
        self.assertNotIn("PRIVATE", str(error.exception))
        self.assertEqual(self.validity_inputs(), [])

    def test_selected_validity_tool_failure_never_falls_back(self):
        original = self.subprocess.side_effect

        def failed_validity(command, **kwargs):
            if "-checkend" in command:
                raise subprocess.CalledProcessError(1, command, output=b"PRIVATE CERTIFICATE")
            return original(command, **kwargs)

        self.subprocess.side_effect = failed_validity
        with self.assertRaises(signing.SigningError) as error:
            self.execute()
        self.assertNotIn("PRIVATE", str(error.exception))
        self.assertEqual(self.validity_inputs(), [CERTIFICATE])

    def test_sign_inside_out_and_verify_without_fallback(self):
        app = self.make_app()
        self.execute()
        commands = [call.args[0] for call in self.subprocess.call_args_list]
        signs = [c for c in commands if "--sign" in c]
        self.assertEqual(
            [c[-1] for c in signs],
            [
                str(app / "Contents/PlugIns/TokenStatMenuWidget.appex"),
                str(app),
            ],
        )
        self.assertEqual(
            commands[-1], [signing.CODESIGN, "--verify", "--deep", "--strict", str(app)]
        )
        for path, entitlements in self.signed_entitlements.items():
            self.assertEqual(
                entitlements.get(signing.SANDBOX_KEY, False), path.endswith(".appex")
            )
            self.assertEqual(entitlements[signing.GROUP_KEY], [GROUP])
            self.assertEqual(entitlements[signing.TEAM_KEY], TEAM)
            self.assertFalse(any("$(" in str(value) for value in entitlements.values()))
            self.assertNotIn("get-task-allow", entitlements)
            self.assertEqual(
                (Path(path) / "Contents/embedded.provisionprofile").read_bytes(),
                b"synthetic explicit CMS input",
            )

    def test_embedded_profiles_are_0644_under_umask_077(self):
        app = self.make_app()
        previous = os.umask(0o077)
        try:
            self.execute()
        finally:
            os.umask(previous)
        for bundle in (app, app / "Contents/PlugIns/TokenStatMenuWidget.appex"):
            profile = bundle / "Contents/embedded.provisionprofile"
            self.assertEqual(profile.stat().st_mode & 0o777, 0o644)

    def test_apple_requirement_checks_both_real_identifiers_before_metadata(self):
        app = self.make_app()
        self.execute()
        commands = [call.args[0] for call in self.subprocess.call_args_list]
        checks = [command for command in commands if "--test-requirement" in command]
        self.assertEqual([command[-1] for command in checks], [
            str(app / "Contents/PlugIns/TokenStatMenuWidget.appex"), str(app),
        ])
        for command in checks:
            display = [signing.CODESIGN, "--display", "--verbose=4", command[-1]]
            self.assertLess(commands.index(command), commands.index(display))

    def test_self_signed_same_name_chain_and_matching_leaf_are_rejected(self):
        self.make_app()
        # These are identical to the successful fixture: metadata/SHA alone would pass.
        self.details_override = (
            f"Authority={NAME}\nAuthority=Developer ID Certification Authority\n"
            f"Authority=Apple Root CA\nTeamIdentifier={TEAM}\n"
            "CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1\n"
            "Timestamp=Oct 24, 2026\n"
        ).encode()
        self.leaf = CERTIFICATE
        self.apple_anchored = False
        with self.assertRaises(signing.SigningError) as error:
            self.execute()
        self.assertNotIn("PRIVATE", str(error.exception))
        commands = [call.args[0] for call in self.subprocess.call_args_list]
        self.assertEqual(len([command for command in commands if "--sign" in command]), 1)
        self.assertIn("--test-requirement", commands[-1])
        self.assertFalse(any("--display" in command for command in commands))

    def test_requirement_tool_error_fails_without_plain_verify_or_sign_fallback(self):
        self.make_app()
        original = self.subprocess.side_effect

        def unavailable(command, **kwargs):
            if "--test-requirement" in command:
                raise OSError("PRIVATE requirement evaluation failure")
            return original(command, **kwargs)

        self.subprocess.side_effect = unavailable
        with self.assertRaises(signing.SigningError) as error:
            self.execute()
        self.assertNotIn("PRIVATE", str(error.exception))
        commands = [call.args[0] for call in self.subprocess.call_args_list]
        self.assertEqual(len([command for command in commands if "--sign" in command]), 1)
        verifies = [command for command in commands if "--verify" in command]
        self.assertEqual(len(verifies), 1)
        self.assertIn("--test-requirement", verifies[0])
        self.assertEqual(commands[-1], verifies[0])

    def test_signing_failure_is_redacted_and_never_falls_back(self):
        self.make_app()
        self.fail_sign = True
        with self.assertRaises(signing.SigningError) as error:
            self.execute()
        self.assertNotIn("SECRET", str(error.exception))
        signs = [
            c.args[0] for c in self.subprocess.call_args_list if "--sign" in c.args[0]
        ]
        self.assertEqual(len(signs), 1)

    def test_post_sign_team_authority_runtime_timestamp_must_match(self):
        self.make_app()
        original = (
            f"Authority={NAME}\nAuthority=Developer ID Certification Authority\n"
            f"Authority=Apple Root CA\nTeamIdentifier={TEAM}\n"
            "CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1\n"
            "Timestamp=Oct 24, 2026\n"
        ).encode()
        for old, new in (
            (TEAM.encode(), b"OTHER12345"),
            (b"Developer ID Application", b"Apple Development"),
            (b"(runtime)", b"(none)"),
            (b"Timestamp=Oct 24, 2026\n", b""),
        ):
            with self.subTest(old=old):
                self.details_override = original.replace(old, new)
                with self.assertRaises(signing.SigningError):
                    self.execute()

    def test_post_sign_entitlements_and_leaf_must_match(self):
        self.make_app()
        self.entitlements_override = {"get-task-allow": True}
        with self.assertRaisesRegex(signing.SigningError, "entitlements differ"):
            self.execute()
        self.entitlements_override = None
        self.leaf = b"different certificate"
        with self.assertRaisesRegex(signing.SigningError, "certificate differs"):
            self.execute()

    def test_wrong_bundle_or_group_does_not_modify_app(self):
        app = self.make_app()
        info_path = app / "Contents/Info.plist"
        original = plistlib.loads(info_path.read_bytes())
        for key in ("CFBundleIdentifier", "TokenStatWidgetGroup"):
            modified = dict(original, **{key: "wrong"})
            info_path.write_bytes(plistlib.dumps(modified))
            with self.assertRaises(signing.SigningError):
                self.execute()
            self.assertFalse((app / "Contents/embedded.provisionprofile").exists())
        self.assertFalse(self.signed_entitlements)

    def test_unexpected_nested_code_and_symlinks_fail_before_sign(self):
        app = self.make_app()
        extra = app / "Contents/Other.xpc"
        extra.mkdir()
        with self.assertRaisesRegex(signing.SigningError, "nested code"):
            self.execute()
        extra.rmdir()
        (app / "Contents/alias").symlink_to(app / "Contents/Info.plist")
        with self.assertRaisesRegex(signing.SigningError, "Symlinks"):
            self.execute()
        self.assertFalse(self.signed_entitlements)

    def test_ambiguous_xcode_identifier_fails_closed(self):
        project = self.root / "TokenStatMenu.xcodeproj/project.pbxproj"
        project.write_text(
            project.read_text() + "\nbuildSettings = { INFOPLIST_FILE = "
            "Resources/WidgetExtension-Info.plist; "
            "PRODUCT_BUNDLE_IDENTIFIER = com.other.Widget; };\n"
        )
        with self.assertRaisesRegex(signing.SigningError, "Ambiguous"):
            self.execute()

    def test_tool_errors_do_not_disclose_output(self):
        self.subprocess.side_effect = subprocess.CalledProcessError(
            1,
            [signing.SECURITY],
            output=b"SENSITIVE PROFILE",
            stderr=b"SENSITIVE ERROR",
        )
        with self.assertRaises(signing.SigningError) as error:
            self.execute()
        self.assertNotIn("SENSITIVE", str(error.exception))

    def test_installed_path_is_rejected_before_any_bundle_read(self):
        self.args.app = "/Applications/SyntheticSigningTest.app"
        self.args.validate_only = False
        with (
            mock.patch.object(Path, "is_dir", return_value=True),
            mock.patch.object(Path, "is_symlink", return_value=False),
        ):
            with self.assertRaisesRegex(signing.SigningError, "installed/system"):
                self.execute()

    def test_cli_contract_and_redacted_failure(self):
        arguments = [
            "--app",
            self.args.app,
            "--team",
            TEAM,
            "--group",
            GROUP,
            "--identity",
            NAME,
            "--app-profile",
            self.args.app_profile,
            "--widget-profile",
            self.args.widget_profile,
            "--validate-only",
        ]
        output = io.StringIO()
        with (
            mock.patch.object(signing, "execute") as execute,
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(signing.main(arguments), 0)
        self.assertTrue(execute.call_args.args[0].validate_only)
        self.assertIn("authorization validated", output.getvalue())
        with (
            mock.patch.object(signing, "execute", side_effect=OSError("PRIVATE PATH")),
            contextlib.redirect_stderr(output),
        ):
            self.assertEqual(signing.main(arguments[:-1]), 1)
        self.assertNotIn("PRIVATE PATH", output.getvalue())

if __name__ == "__main__":
    unittest.main()
