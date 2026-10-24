#!/usr/bin/env python3
"""Run isolated entrypoint copies with rejecting tools; never build or sign."""
# fmt: off

from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
CI_FLAGS = (
    "CI",
    "CONTINUOUS_INTEGRATION",
    "GITHUB_ACTIONS",
    "GITHUB_RUN_ID",
    "GITLAB_CI",
    "TF_BUILD",
    "JENKINS_URL",
    "BUILD_NUMBER",
    "BUILD_ID",
    "TEAMCITY_VERSION",
    "CIRCLECI",
    "TRAVIS",
    "BUILDKITE",
    "CODEBUILD_BUILD_ID",
    "BITBUCKET_BUILD_NUMBER",
    "DRONE",
    "APPVEYOR",
    "XCS",
    "CI_WORKFLOW",
)
MODES = (
    (),
    ("run",),
    ("--build-only",),
    ("--verify",),
    ("--release",),
    ("--arm64",),
    ("--universal",),
    ("--developer-id",),
    ("--dev-widget",),
    ("--logs",),
    ("--telemetry",),
    ("--debug",),
)

class BuildEntrypointChecks(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tokenstat-ci-entrypoint-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.root = self.base / "isolated-project"
        self.root.mkdir()
        script = self.root / "script"
        script.mkdir()
        self.entrypoint = script / "build_and_run.sh"
        self.entrypoint.write_bytes((PROJECT / "script/build_and_run.sh").read_bytes())
        resources = self.root / "Resources"
        resources.mkdir()
        for name in ["Info.plist", "WidgetInfo.plist"]:
            (resources / name).write_bytes(
                plistlib.dumps({"CFBundleVersion": "123", "Sentinel": "unchanged"})
            )
        self.home = self.base / "isolated-home"
        self.home.mkdir()
        self.log = self.base / "forbidden-tools.log"
        tools = self.base / "rejecting-tools"
        tools.mkdir()
        # dirname is the sole bootstrap utility. Replace it with a shell
        # function so PATH contains only tools that reject every invocation.
        bootstrap = self.base / "bash-env"
        bootstrap.write_text(
            'dirname() { printf "%s\\n" "${1%/*}"; }\n'
            "command_not_found_handle() {\n"
            '    printf "%s\\n" "$*" >> "$TOOL_LOG"\n'
            "    return 97\n"
            "}\n",
            encoding="utf-8",
        )
        reject = '#!/bin/bash\nprintf "%s\\n" "${0##*/} $*" >> "$TOOL_LOG"\nexit 97\n'
        for name in (
            "uname",
            "python3",
            "swift",
            "xcodebuild",
            "xcrun",
            "codesign",
            "security",
            "openssl",
            "mkdir",
            "rm",
            "cp",
            "ditto",
            "sed",
            "grep",
            "head",
            "git",
            "chmod",
            "open",
            "killall",
            "lldb",
            "sleep",
            "pgrep",
            "hdiutil",
            "log",
            "PlistBuddy",
            "bash",
            "sh",
        ):
            target = tools / name
            target.write_text(reject, encoding="utf-8")
            target.chmod(0o755)
        # Do not inherit credentials, shell functions, CI flags, or signing
        # inputs from the machine running the tests.
        self.environment = {
            "PATH": str(tools),
            "HOME": str(self.home),
            "BASH_ENV": str(bootstrap),
            "TOOL_LOG": str(self.log),
            "LC_ALL": "C",
            "TMPDIR": str(self.base),
        }

    def snapshot(self):
        result = {}
        for top in [self.root, self.home]:
            for path in sorted(top.rglob("*")):
                result[str(path.relative_to(self.base))] = (
                    stat.S_IMODE(path.lstat().st_mode),
                    path.read_bytes() if path.is_file() else None,
                )
        return result

    def run_entrypoint(self, mode, flags):
        if self.log.exists():
            self.log.unlink()
        before = self.snapshot()
        result = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", str(self.entrypoint), *mode],
            cwd=self.base,
            env=dict(self.environment, **flags),
            text=True,
            capture_output=True,
            check=False,
            timeout=5,
        )
        self.assertEqual(
            self.snapshot(), before, "guard must not mutate any project or HOME file"
        )
        self.assertFalse((self.root / "dist").exists())
        self.assertFalse((self.root / ".build").exists())
        self.assertFalse((self.home / "Applications").exists())
        return result

    def assert_ci_rejected(self, mode, flags):
        result = self.run_entrypoint(mode, flags)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("signing builds are local-only", result.stderr)
        self.assertIn("unsigned build/test", result.stderr)
        self.assertFalse(
            self.log.exists(),
            "CI guard must reject before architecture checks, Python, or any build/sign/install tool",
        )

    def test_each_ci_provider_rejects_every_entrypoint_mode_before_side_effects(self):
        for flag in CI_FLAGS:
            for mode in MODES:
                with self.subTest(flag=flag, mode=mode):
                    self.assert_ci_rejected(mode, {flag: "true"})

    def test_nonempty_ci_values_fail_closed_for_default_and_developer_id_modes(self):
        for value in ["1", "yes", "TRUE", "FALSE", "00", "https://ci.invalid/job/1"]:
            for mode in [(), ("--developer-id",)]:
                with self.subTest(value=value, mode=mode):
                    self.assert_ci_rejected(mode, {"CI": value})

    def test_false_valued_flags_and_other_provider_flags_still_reject(self):
        self.assert_ci_rejected(
            ("--developer-id",), {"CI": "false", "GITHUB_ACTIONS": "true"}
        )
        self.assert_ci_rejected(
            ("--universal",), {"CI": "0", "TEAMCITY_VERSION": "2026.1"}
        )

    def test_each_present_flag_rejects_false_zero_and_empty_values_in_every_mode(self):
        for flag in CI_FLAGS:
            for value in ["", "false", "0"]:
                for mode in MODES:
                    with self.subTest(flag=flag, value=value, mode=mode):
                        self.assert_ci_rejected(mode, {flag: value})

    def test_no_ci_environment_reaches_only_the_rejecting_architecture_stub(self):
        result = self.run_entrypoint((), {})
        # uname runs inside a conditional, so the entrypoint reports its own
        # architecture error rather than the rejecting stub's exit status.
        self.assertEqual(result.returncode, 2)
        self.assertIn("requires Apple Silicon", result.stderr)
        self.assertEqual(self.log.read_text(encoding="utf-8"), "uname -m\n")

    def test_extra_arguments_are_rejected_before_any_external_tool(self):
        for mode in MODES:
            with self.subTest(mode=mode):
                arguments = (*mode, "unexpected") if mode else ("run", "unexpected")
                result = self.run_entrypoint(arguments, {})
                self.assertEqual(result.returncode, 2)
                self.assertIn("extra arguments", result.stderr)
                self.assertFalse(self.log.exists())

# Every dispatcher operation is synthetic and restricted to the fixture root.
# In particular, the python3 adapter never executes the signing helper.
LOCAL_TOOL = r'''
import json
import os
from pathlib import Path
import plistlib
import shutil
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ["FIXTURE_ROOT"])
app = root / "dist/developer-id/TokenStatMenu.app"
phase = "validate" if name == "python3" and "--validate-only" in args else name
if name == "python3" and phase != "validate":
    phase = "sign"
with open(os.environ["TOOL_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps(dict(tool=name, args=args, phase=phase,
        dist_exists=(root / "dist").exists(), app_exists=app.exists())) + "\n")
if os.environ.get("FAIL_PHASE") == phase:
    sys.exit(41)

def safe(value):
    path = Path(value)
    if not path.is_absolute():
        path = root / path
    path.resolve().relative_to(root.resolve())
    return path

if name == "uname":
    assert args == ["-m"]
    print("arm64")
elif name == "python3":
    assert args[:2] == ["-B", str(root / "script/sign_developer_id.py")]
    if phase == "validate":
        assert "--validate-only" in args
    else:
        assert app.is_dir()
        for info in [app / "Contents/Info.plist", app / "Contents/PlugIns/TokenStatMenuWidget.appex/Contents/Info.plist"]:
            data = plistlib.loads(info.read_bytes())
            assert data["TokenStatSourceRevision"] == "source-export"
            assert data["TokenStatSourceState"] == "unspecified"
elif name == "mkdir":
    assert args[0] == "-p"
    for path in args[1:]:
        safe(path).mkdir(parents=True, exist_ok=True)
elif name == "xcodebuild":
    if args != ["-version"]:
        assert args[-1] == "build"
        if os.environ.get("FAIL_PHASE") == "build":
            sys.exit(42)
        output = safe(args[args.index("-derivedDataPath") + 1]) / "Build/Products/Release/TokenStatMenu.app"
        for relative in ["Contents/Info.plist", "Contents/PlugIns/TokenStatMenuWidget.appex/Contents/Info.plist"]:
            path = output / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(plistlib.dumps(dict(TokenStatWidgetGroup=os.environ["TOKENSTAT_WIDGET_GROUP"], CFBundleShortVersionString="1.2.3", CFBundleVersion="123")))
        binary = output / "Contents/MacOS/TokenStatMenu"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"synthetic-not-an-executable")
elif name == "PlistBuddy":
    assert args[0] == "-c"
    action = args[1].split()
    path = safe(args[2])
    data = plistlib.loads(path.read_bytes())
    key = action[1].lstrip(":")
    if action[0] == "Print":
        print(data[key])
    else:
        assert action[0] == "Add" and action[2] == "string"
        data[key] = action[3]
        path.write_bytes(plistlib.dumps(data))
elif name == "grep":
    needle = args[1]
    text = safe(args[2]).read_text() if len(args) > 2 else sys.stdin.read()
    sys.exit(0 if (needle in text.splitlines() if args[0] == "-Fxq" else needle in text) else 1)
elif name == "rm":
    assert args[0] == "-rf"
    path = safe(args[1])
    if path.exists():
        shutil.rmtree(path)
elif name == "cp":
    assert args[0] == "-R"
    shutil.copytree(safe(args[1]), safe(args[2]))
elif name == "sed":
    assert args[0].startswith("s|") and args[0].endswith("|g")
    print(safe(args[1]).read_text().replace("$(TOKENSTAT_WIDGET_GROUP)", os.environ["TOKENSTAT_WIDGET_GROUP"]), end="")
elif name == "git":
    assert args == ["rev-parse", "--show-toplevel"]
    sys.exit(1)
elif name == "chmod":
    safe(args[1]).chmod(int(args[0], 8))
elif name == "codesign":
    assert args == ["--verify", "--deep", "--strict", str(app)], "no fallback signing is permitted"
else:
    raise AssertionError("forbidden external tool: " + name)
'''

class LocalDeveloperIDFixture:
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tokenstat-local-entrypoint-")
        self.base = Path(self.temporary.name)
        self.root = self.base / "project"
        (self.root / "script").mkdir(parents=True)
        self.home = self.base / "private-home"
        self.home.mkdir()
        (self.home / "preserve").write_bytes(b"unchanged-home")
        self.log = self.base / "tools.jsonl"
        tools = self.base / "fake-tools"
        tools.mkdir()
        for name in ["uname", "python3", "mkdir", "xcodebuild", "PlistBuddy", "grep", "rm", "cp", "sed", "git", "chmod", "codesign", "open", "killall", "ditto", "swift", "security", "xcrun", "head", "openssl", "lldb", "hdiutil", "sleep", "pgrep"]:
            path = tools / name
            path.write_text("#!" + sys.executable + "\n" + LOCAL_TOOL, encoding="utf-8")
            path.chmod(0o755)
        bootstrap = self.base / "bash-env"
        bootstrap.write_text(
            'dirname() { printf "%s\\n" "${1%/*}"; }\n'
            'command_not_found_handle() { printf "%s\\n" "FORBIDDEN: $*" >&2; return 97; }\n',
            encoding="utf-8",
        )
        self.entrypoint = self.root / "script/build_and_run.sh"
        source = (PROJECT / "script/build_and_run.sh").read_text(encoding="utf-8")
        # Only redirect the absolute system utility; all control flow remains
        # the production script's, and no real system plist utility is run.
        self.entrypoint.write_text(
            source.replace("/usr/libexec/PlistBuddy", '"' + str(tools / "PlistBuddy") + '"'),
            encoding="utf-8",
        )
        resources = self.root / "Resources"
        resources.mkdir()
        (resources / "Info.plist").write_bytes(plistlib.dumps({"CFBundleVersion": "123"}))
        for name in ["WidgetExtension.entitlements", "TokenStatMenu.entitlements"]:
            (resources / name).write_text("$(TOKENSTAT_WIDGET_GROUP)\n", encoding="utf-8")
        self.environment = {
            "PATH": str(tools), "HOME": str(self.home), "BASH_ENV": str(bootstrap),
            "TOOL_LOG": str(self.log), "FIXTURE_ROOT": str(self.root), "LC_ALL": "C",
            "TMPDIR": str(self.base), "PYTHONDONTWRITEBYTECODE": "1",
            "TOKENSTAT_TEAM_ID": "AB12CD34EF", "TOKENSTAT_WIDGET_GROUP": "group.synthetic.menu",
            "TOKENSTAT_SIGN_IDENTITY": "Developer ID Application: Synthetic (AB12CD34EF)",
            "TOKENSTAT_APP_PROFILE": str(self.base / "app-profile"),
            "TOKENSTAT_WIDGET_PROFILE": str(self.base / "widget-profile"),
        }
        self.app = self.root / "dist/developer-id/TokenStatMenu.app"

    def run(self, failure=None, arguments=("--developer-id",)):
        environment = dict(self.environment)
        if failure:
            environment["FAIL_PHASE"] = failure
        return subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", str(self.entrypoint), *arguments],
            cwd=self.base, env=environment, text=True, capture_output=True,
            check=False, timeout=15,
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def snapshot(self):
        records = {}
        for path in self.base.rglob("*"):
            if path == self.log:
                continue
            records[str(path.relative_to(self.base))] = (
                stat.S_IMODE(path.lstat().st_mode),
                os.readlink(path) if path.is_symlink() else path.read_bytes() if path.is_file() else None,
            )
        return records

class LocalDeveloperIDChecks(unittest.TestCase):
    def fixture(self):
        fixture = LocalDeveloperIDFixture()
        self.addCleanup(fixture.temporary.cleanup)
        return fixture

    def assert_no_install_or_bump(self, fixture):
        self.assertFalse((fixture.home / "Applications").exists())
        self.assertEqual((fixture.home / "preserve").read_bytes(), b"unchanged-home")
        self.assertEqual(plistlib.loads((fixture.root / "Resources/Info.plist").read_bytes()), {"CFBundleVersion": "123"})
        for call in fixture.calls():
            self.assertNotIn(call["tool"], ["open", "killall", "ditto", "swift", "security"])
            self.assertFalse(any("bump_build.py" in argument for argument in call["args"]))
            self.assertNotIn("--sign", call["args"])

    def test_local_developer_id_prevalidates_builds_unsigned_and_signs_without_install(self):
        fixture = self.fixture()
        result = fixture.run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Built: " + str(fixture.app), result.stdout)
        calls = fixture.calls()
        self.assertEqual(calls[0]["phase"], "validate")
        self.assertFalse(calls[0]["dist_exists"])
        self.assertEqual([call["phase"] for call in calls if call["tool"] == "python3"], ["validate", "sign"])
        build = next(call for call in calls if call["tool"] == "xcodebuild" and "build" in call["args"])
        for argument in ["ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "TOKENSTAT_WIDGET_GROUP=group.synthetic.menu"]:
            self.assertIn(argument, build["args"])
        self.assertEqual(build["args"][build["args"].index("-derivedDataPath") + 1], str(fixture.root / ".build/xcode-developer-id"))
        phases = [call["phase"] for call in calls]
        self.assertLess(phases.index("validate"), phases.index("mkdir"))
        self.assertLess(phases.index("validate"), phases.index("xcodebuild"))
        self.assertGreater(phases.index("sign"), phases.index("cp"))
        for call in [call for call in calls if call["tool"] == "python3"]:
            args = call["args"]
            for option, value in [("--app", str(fixture.app)), ("--team", fixture.environment["TOKENSTAT_TEAM_ID"]), ("--group", fixture.environment["TOKENSTAT_WIDGET_GROUP"]), ("--identity", fixture.environment["TOKENSTAT_SIGN_IDENTITY"]), ("--app-profile", fixture.environment["TOKENSTAT_APP_PROFILE"]), ("--widget-profile", fixture.environment["TOKENSTAT_WIDGET_PROFILE"])]:
                self.assertEqual(args[args.index(option) + 1], value)
        self.assert_no_install_or_bump(fixture)

    def test_helper_prevalidation_failure_has_no_output_or_mutation(self):
        fixture = self.fixture()
        before = fixture.snapshot()
        result = fixture.run("validate")
        self.assertEqual(result.returncode, 41)
        self.assertNotIn("Built:", result.stdout)
        self.assertEqual([call["phase"] for call in fixture.calls()], ["validate"])
        self.assertEqual(fixture.snapshot(), before)
        self.assertFalse((fixture.root / "dist").exists())
        self.assert_no_install_or_bump(fixture)

    def test_failed_unsigned_build_never_signs_or_reports_success_even_with_old_product(self):
        for old in [False, True]:
            with self.subTest(old_product=old):
                fixture = self.fixture()
                if old:
                    fixture.app.mkdir(parents=True)
                    (fixture.app / "old-product").write_bytes(b"preserve-old")
                    stale = fixture.root / ".build/xcode-developer-id/Build/Products/Release/TokenStatMenu.app/Contents/PlugIns/TokenStatMenuWidget.appex"
                    stale.mkdir(parents=True)
                result = fixture.run("build")
                self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
                self.assertNotIn("Built:", result.stdout)
                self.assertNotIn("sign", [call["phase"] for call in fixture.calls()])
                self.assertNotIn("codesign", [call["tool"] for call in fixture.calls()])
                self.assertNotIn("cp", [call["tool"] for call in fixture.calls()])
                if old:
                    self.assertEqual((fixture.app / "old-product").read_bytes(), b"preserve-old")
                self.assert_no_install_or_bump(fixture)

    def test_final_signing_helper_failure_never_falls_back_to_adhoc_or_success(self):
        fixture = self.fixture()
        result = fixture.run("sign")
        self.assertEqual(result.returncode, 41, result.stdout + result.stderr)
        self.assertNotIn("Built:", result.stdout)
        self.assertEqual([call["phase"] for call in fixture.calls() if call["tool"] == "python3"], ["validate", "sign"])
        self.assertNotIn("codesign", [call["tool"] for call in fixture.calls()])
        self.assert_no_install_or_bump(fixture)

    def test_final_verification_failure_never_reports_success(self):
        fixture = self.fixture()
        result = fixture.run("codesign")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Built:", result.stdout)
        self.assertIn("signature verification failed", result.stderr)
        self.assert_no_install_or_bump(fixture)

    def test_symbolic_output_parents_are_rejected_before_validation_or_writes(self):
        for relative in ["dist", "dist/developer-id", ".build", ".build/xcode-developer-id"]:
            for dangling in [False, True]:
                with self.subTest(parent=relative, dangling=dangling):
                    fixture = self.fixture()
                    outside = fixture.base / "protected-target"
                    if not dangling:
                        outside.mkdir()
                        (outside / "preserve").write_bytes(b"do-not-touch")
                    link = fixture.root / relative
                    link.parent.mkdir(parents=True, exist_ok=True)
                    link.symlink_to(outside, target_is_directory=True)
                    before = fixture.snapshot()
                    result = fixture.run()
                    self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                    self.assertIn("symbolic output directories", result.stderr)
                    self.assertNotIn("Built:", result.stdout)
                    self.assertEqual(fixture.calls(), [])
                    self.assertEqual(fixture.snapshot(), before)

if __name__ == "__main__":
    unittest.main()
