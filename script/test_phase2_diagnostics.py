#!/usr/bin/env python3
"""Contract tests for the non-bypassing phase-two diagnostics."""
from __future__ import annotations

import importlib.util
import subprocess
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "script/diagnose_swift_toolchain.py"


def load_diagnostic_module():
    spec = importlib.util.spec_from_file_location("diagnose_swift_toolchain", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError("diagnostic module must be importable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class PhaseTwoDiagnosticTests(unittest.TestCase):
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
        completed = subprocess.run([str(runner), "--help"], text=True, capture_output=True)
        self.assertEqual(completed.returncode, 0)
        self.assertIn("automation_environment_blocked", completed.stdout)
        self.assertIn("build-for-testing", completed.stdout)
        self.assertIn("test-without-building", completed.stdout)

    def test_runner_rejects_missing_value_without_hanging(self):
        runner = ROOT / "script/run_settings_ax_check.sh"
        completed = subprocess.run(
            [str(runner), "--project"], text=True, capture_output=True, timeout=1,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn('"classification":"configuration_error"', completed.stdout)


if __name__ == "__main__":
    unittest.main()
