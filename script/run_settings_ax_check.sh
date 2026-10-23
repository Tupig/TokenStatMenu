#!/bin/bash
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: run_settings_ax_check.sh --project PROJECT --scheme SCHEME \
  --fixture-manifest MANIFEST --fixture-bundle BUNDLE [options]

Runs the private C27 macOS AX runner with full Xcode. It validates the frozen
fixture manifest and project source before build-for-testing, then runs
 test-without-building and verifies the transient xcresult summary. An
automation-mode timeout is reported as automation_environment_blocked and keeps
its non-zero exit code; no result is converted to a pass.

Options:
  --project PATH       Private C27 Xcode project (required)
  --scheme NAME        Private C27 scheme (required)
  --fixture-manifest PATH  Frozen C27 manifest (required)
  --fixture-bundle PATH    Frozen C27 fixture bundle (required)
  --timeout SECONDS    Per-command timeout, 30..600 (default: 120)
  --help               Show this help
USAGE
}

configuration_error() {
  echo '{"classification":"configuration_error","exit":2}'
  exit 2
}

project=""
scheme=""
fixture_manifest=""
fixture_bundle=""
timeout_seconds=120
while (($#)); do
  case "$1" in
    --project)
      (($# >= 2)) || configuration_error
      project="$2"; shift 2 ;;
    --scheme)
      (($# >= 2)) || configuration_error
      scheme="$2"; shift 2 ;;
    --fixture-manifest)
      (($# >= 2)) || configuration_error
      fixture_manifest="$2"; shift 2 ;;
    --fixture-bundle)
      (($# >= 2)) || configuration_error
      fixture_bundle="$2"; shift 2 ;;
    --derived-data) configuration_error ;;
    --timeout)
      (($# >= 2)) || configuration_error
      timeout_seconds="$2"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) configuration_error ;;
  esac
done

[[ -n "$project" && -n "$scheme" && -n "$fixture_manifest" && -n "$fixture_bundle" ]] || configuration_error
[[ -n "${DEVELOPER_DIR:-}" ]] || configuration_error
[[ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" && -x "/usr/bin/xcrun" ]] || configuration_error
if ! [[ "$timeout_seconds" =~ ^[0-9]+$ ]]; then configuration_error; fi
if (( timeout_seconds < 30 )); then configuration_error; fi
if (( timeout_seconds > 600 )); then configuration_error; fi

[[ ! -L "$project" && ! -L "$fixture_manifest" && ! -L "$fixture_bundle" ]] || configuration_error
project_real="$(cd "$project" 2>/dev/null && pwd -P)" || configuration_error
bundle_real="$(cd "$fixture_bundle" 2>/dev/null && pwd -P)" || configuration_error
[[ -f "$project_real/project.pbxproj" ]] || configuration_error
scheme_file="$project_real/xcshareddata/xcschemes/$scheme.xcscheme"
[[ -f "$scheme_file" ]] || configuration_error
project_parent="$(dirname "$project_real")"
test_source="$project_parent/Tests/NativeSettingsAXTests.swift"
[[ -f "$test_source" ]] || configuration_error
# Bind the wrapper to the reviewed C27 project/test shape, not an arbitrary UI test.
grep -Fq 'C27SettingsAXUITests' "$project_real/project.pbxproj" || configuration_error
grep -Fq 'NativeSettingsAXTests' "$test_source" || configuration_error
grep -Fq 'XCUIApplication(url:' "$test_source" || configuration_error
grep -Fq -- '--test-fixture' "$test_source" || configuration_error
grep -Fq -- '--disable-background-services' "$test_source" || configuration_error
grep -Fq 'A07' "$test_source" || configuration_error
[[ "$(shasum -a 256 "$project_real/project.pbxproj" | awk '{print $1}')" == "0ab0c1958fb718cc572519ac451dcc1c78227c4a7093dff42451b22856593d5f" ]] || configuration_error
[[ "$(shasum -a 256 "$scheme_file" | awk '{print $1}')" == "d8e2920aaced40f6b47fb1267015b2fd87c67eb5996f3d56b6064493d54fede1" ]] || configuration_error
[[ "$(shasum -a 256 "$test_source" | awk '{print $1}')" == "4b03e8190cb510ea5904bb12a94c8bd8c71f922cba509f0950c9c721760dfc78" ]] || configuration_error

python3 - "$fixture_manifest" "$fixture_bundle" <<'PY' || exit 2
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

manifest_input = Path(sys.argv[1])
bundle_input = Path(sys.argv[2])
if manifest_input.is_symlink() or bundle_input.is_symlink():
    raise SystemExit(2)
manifest_bytes = manifest_input.read_bytes()
if hashlib.sha256(manifest_bytes).hexdigest() != "be265d66e7322bb9a790b6ac2b99532ede0d274182c1b143895785dd46e99c93":
    raise SystemExit(2)
manifest_path = manifest_input.resolve()
bundle = bundle_input.resolve()
try:
    manifest = json.loads(manifest_bytes.decode("utf-8"))
    expected_files = manifest["bundleFiles"]
    if manifest.get("syntheticOnly") is not True:
        raise ValueError
    if Path(manifest["bundlePath"]).resolve() != bundle:
        raise ValueError
    if manifest["bundleIdentifier"] != "com.tupig.TokenStatMenu.AXFixture.c23.jk1svxze":
        raise ValueError
    if manifest["requiredArguments"] != ["--test-fixture", "--disable-background-services"]:
        raise ValueError
    if manifest.get("privateHarnessSHA256") != "b0fa06419695bd0b1e2e0c34989b2081a75e2d5d63883f8a29bb651d03f97e53":
        raise ValueError
    if manifest.get("sourceFiles", {}).get("Sources/TokenStatMenu/SettingsView.swift") != "dae957654ee285b45825e6f4afacdebf76b2f9790dcb0d42f963f3709f161bb3":
        raise ValueError
    if set(expected_files) != {"Contents/Info.plist", "Contents/MacOS/TokenStatAXFixture", "Contents/_CodeSignature/CodeResources"}:
        raise ValueError
    if bundle.is_symlink() or not bundle.is_dir():
        raise ValueError
    found_files = set()
    found_dirs = set()
    for root, dirs, files in os.walk(bundle, followlinks=False):
        root_path = Path(root)
        for name in dirs:
            path = root_path / name
            if path.is_symlink():
                raise ValueError
            found_dirs.add(str(path.relative_to(bundle)))
        for name in files:
            path = root_path / name
            if path.is_symlink():
                raise ValueError
            rel = str(path.relative_to(bundle))
            record = expected_files.get(rel)
            if record is None:
                raise ValueError
            data = path.read_bytes()
            mode = oct(path.stat().st_mode & 0o777)
            if len(data) != record["bytes"] or hashlib.sha256(data).hexdigest() != record["sha256"] or mode != record["mode"]:
                raise ValueError
            found_files.add(rel)
    if found_files != set(expected_files) or found_dirs != {"Contents", "Contents/MacOS", "Contents/_CodeSignature"}:
        raise ValueError
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != manifest["bundleIdentifier"] or info.get("CFBundleExecutable") != "TokenStatAXFixture":
        raise ValueError
    verified = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if verified.returncode != 0:
        raise ValueError
except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(2)
PY

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/tokenstatmenu-ax-check.XXXXXX")" || exit 2
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
derived_data="$tmp_dir/DerivedData"
mkdir -p "$derived_data"

run_bounded() {
  local log="$1"
  shift
  "$DEVELOPER_DIR/usr/bin/xcodebuild" "$@" >"$log" 2>&1 &
  local child=$!
  local waited=0
  while kill -0 "$child" 2>/dev/null; do
    if (( waited >= timeout_seconds )); then
      kill "$child" 2>/dev/null || true
      wait "$child" 2>/dev/null || true
      return 124
    fi
    sleep 1
    ((waited += 1))
  done
  wait "$child"
}

build_log="$tmp_dir/build.log"
run_bounded "$build_log" -project "$project_real" -scheme "$scheme" -configuration Debug \
  -derivedDataPath "$derived_data" -destination 'platform=macOS' -parallel-testing-enabled NO build-for-testing
build_exit=$?
if (( build_exit != 0 )); then
  printf '{"classification":"build_failed","build_exit":%d,"test_exit":null,"fixture_manifest_verified":true,"fixture_bundle_identity_verified":true,"a01_a07_executed":false}\n' "$build_exit"
  exit "$build_exit"
fi

test_log="$tmp_dir/test.log"
run_bounded "$test_log" -project "$project_real" -scheme "$scheme" -configuration Debug \
  -derivedDataPath "$derived_data" -destination 'platform=macOS' -parallel-testing-enabled NO \
  -only-testing:C27SettingsAXUITests/NativeSettingsAXTests/testFrozenSettingsExposeExpectedAXControls \
  test-without-building -resultBundlePath "$tmp_dir/result.xcresult"
test_exit=$?

summary_file="$tmp_dir/summary.json"
if [[ -d "$tmp_dir/result.xcresult" ]]; then
  "/usr/bin/xcrun" xcresulttool get test-results summary --path "$tmp_dir/result.xcresult" --format json >"$summary_file" 2>/dev/null || true
fi
classification="$(python3 "$(dirname "$0")/classify_settings_ax.py" \
  --summary "$summary_file" --log "$test_log" --exit-code "$test_exit")"
case "$classification" in passed|test_failed|automation_environment_blocked) ;; *) classification=test_failed ;; esac

if [[ "$classification" == passed ]]; then executed=true; else executed=false; fi
printf '{"classification":"%s","build_exit":%d,"test_exit":%d,"fixture_manifest_verified":true,"fixture_bundle_identity_verified":true,"a01_a07_executed":%s}\n' \
  "$classification" "$build_exit" "$test_exit" "$executed"
if [[ "$classification" == passed ]]; then exit 0; fi
if (( test_exit != 0 )); then exit "$test_exit"; fi
exit 1
