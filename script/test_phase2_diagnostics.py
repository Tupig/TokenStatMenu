#!/usr/bin/env python3
"""Contract tests for the non-bypassing phase-two diagnostics."""

from __future__ import annotations

import importlib.util
import subprocess
from pathlib import Path
import sys
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "script/diagnose_swift_toolchain.py"


def load_diagnostic_module():
    spec = importlib.util.spec_from_file_location(
        "diagnose_swift_toolchain", MODULE_PATH
    )
    if spec is None or spec.loader is None:
        raise AssertionError("diagnostic module must be importable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class PhaseTwoDiagnosticTests(unittest.TestCase):
    def test_native_development_tests_bind_real_product_sources_without_app_host(self):
        scheme = ET.parse(
            ROOT
            / "TokenStatMenu.xcodeproj/xcshareddata/xcschemes/TokenStatDevWidgetLogicTests.xcscheme"
        ).getroot()
        testable = scheme.find("./TestAction/Testables/TestableReference")
        self.assertIsNotNone(testable)
        self.assertEqual(testable.get("skipped"), "NO")
        reference = testable.find("BuildableReference")
        self.assertEqual(reference.get("BlueprintName"), "TokenStatDevWidgetLogicTests")
        self.assertIsNone(scheme.find(".//BuildableProductRunnable"))
        project = (ROOT / "TokenStatMenu.xcodeproj/project.pbxproj").read_text()
        target_id = reference.get("BlueprintIdentifier")
        target = project.split(target_id + " = {", 1)[1].split("};", 1)[0]
        self.assertIn('productType = "com.apple.product-type.bundle.unit-test"', target)
        self.assertIn("dependencies = ()", target)
        generator = (ROOT / "script/generate_xcode_project.py").read_text()
        for marker in [
            "Sources/TokenStatDevWidgetShared/",
            "/DevProvider.swift",
            'TEST_HOST = ""',
            'BUNDLE_LOADER = ""',
            "CODE_SIGNING_ALLOWED = NO",
        ]:
            self.assertIn(marker, generator)
        host = (ROOT / "Sources/TokenStatDevWidgetHost/main.swift").read_text()
        self.assertLess(
            host.index("DevProbeHostRunner.run("), host.index("NSApplication.shared")
        )
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("-scheme TokenStatDevWidgetLogicTests", workflow)
        self.assertIn("CODE_SIGNING_REQUIRED=NO test", workflow)

    def test_ax_summary_requires_one_real_pass_and_zero_failures(self):
        sys.path.insert(0, str(ROOT / "script"))
        from classify_settings_ax import classify

        passed = dict(totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0)
        self.assertEqual(classify(passed, 0, ""), "passed")
        for summary in [
            None,
            {},
            dict(passed, totalTestCount=0),
            dict(passed, skippedTests=1),
            dict(passed, failedTests=1),
            dict(passed, passedTests=True),
        ]:
            self.assertEqual(classify(summary, 0, ""), "test_failed")
        self.assertEqual(classify(passed, 65, ""), "test_failed")
        for log in [
            "XCTAssertEqual failed",
            "XCTAssertEqual failed: runner failed to initialize",
        ]:
            self.assertEqual(classify(passed, 0, log), "test_failed")
        for failures in [
            "invalid",
            ["invalid"],
            [{"failureText": "XCTAssertEqual failed"}],
        ]:
            self.assertEqual(
                classify(dict(passed, testFailures=failures), 0, ""), "test_failed"
            )
        self.assertEqual(
            classify(
                dict(passed, failedTests=1),
                65,
                "XCTAssertEqual failed: runner failed to initialize",
            ),
            "test_failed",
        )
        self.assertEqual(
            classify(None, 65, "XCTAssertEqual failed in automation test"),
            "test_failed",
        )
        for marker in [
            "Timed out while enabling automation mode",
            "runner failed to initialize",
        ]:
            self.assertEqual(
                classify(None, 65, marker), "automation_environment_blocked"
            )
        runner = (ROOT / "script/run_settings_ax_check.sh").read_text()
        self.assertIn('[[ -d "$tmp_dir/result.xcresult" ]]', runner)
        self.assertNotIn('[[ -f "$tmp_dir/result.xcresult" ]]', runner)

    def test_missing_clt_search_paths_are_reported_as_nonfatal(self):
        module = load_diagnostic_module()
        result = module.classify_linker_warnings(
            "ld: warning: search path '/Library/Developer/CommandLineTools/Developer/usr/lib' not found\n"
        )
        self.assertEqual(result.kind, "clt_search_path_warning")
        self.assertEqual(result.count, 1)
        self.assertFalse(result.is_build_failure)

    def test_verbose_swiftpm_warning_is_not_linker_warning(self):
        module = load_diagnostic_module()
        result = module.classify_linker_warnings(
            "warning: 'TokenStatMenu': manifest compiler invocation\n"
        )
        self.assertEqual(result.kind, "none")
        self.assertEqual(result.count, 0)

    def test_runner_help_describes_blocked_exit(self):
        runner = ROOT / "script/run_settings_ax_check.sh"
        completed = subprocess.run(
            [str(runner), "--help"], text=True, capture_output=True
        )
        self.assertEqual(completed.returncode, 0)
        self.assertIn("automation_environment_blocked", completed.stdout)
        self.assertIn("build-for-testing", completed.stdout)
        self.assertIn("test-without-building", completed.stdout)

    def test_runner_rejects_missing_value_without_hanging(self):
        runner = ROOT / "script/run_settings_ax_check.sh"
        completed = subprocess.run(
            [str(runner), "--project"],
            text=True,
            capture_output=True,
            timeout=1,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn('"classification":"configuration_error"', completed.stdout)


if __name__ == "__main__":
    unittest.main()
