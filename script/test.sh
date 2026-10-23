#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# XCTest.framework ships with full Xcode, not with Command Line Tools. Select a
# toolchain that has it, or fail clearly instead of letting an unresolved
# 'XCTest' module look like a code bug.
xctest_framework_for() {
    local platform_path
    platform_path="$(DEVELOPER_DIR="$1" xcrun --show-sdk-platform-path 2>/dev/null || true)"
    [ -n "$platform_path" ] && [ -d "$platform_path/Developer/Library/Frameworks/XCTest.framework" ]
}

if [ -n "${DEVELOPER_DIR:-}" ] && xctest_framework_for "$DEVELOPER_DIR"; then
    :
elif [ -d /Applications/Xcode.app/Contents/Developer ] && xctest_framework_for /Applications/Xcode.app/Contents/Developer; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    echo "info: using $DEVELOPER_DIR (Command Line Tools has no XCTest.framework)"
elif xctest_framework_for "$(xcode-select -p 2>/dev/null || echo /nonexistent)"; then
    :
else
    echo "error: XCTest.framework not found for any available toolchain." >&2
    echo "       swift test needs full Xcode, not Command Line Tools." >&2
    exit 1
fi

swift run --force-resolved-versions TokenStatCoreChecks
swift test --force-resolved-versions
./script/build_and_run.sh --build-only
python3 script/integration.py
