#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE="${1:-run}"
APP="$ROOT/dist/TokenStatMenu.app"
case "$MODE" in run|--build-only|--verify|--release|--universal|--logs|--telemetry|--debug) ;; *) echo "Usage: $0 [--build-only|--verify|--release|--universal|--logs|--telemetry|--debug]"; exit 2 ;; esac
pkill -x TokenStatMenu 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS"
# Native SwiftPM also works with Command Line Tools; no global xcode-select changes.
if [ "$MODE" = "--universal" ]; then
    for ARCH in arm64 x86_64; do
        swift build --build-system native --arch "$ARCH" --scratch-path ".build/$ARCH" -c release --product TokenStatMenu
    done
    ARM_DIR="$(swift build --build-system native --arch arm64 --scratch-path .build/arm64 -c release --show-bin-path)"
    INTEL_DIR="$(swift build --build-system native --arch x86_64 --scratch-path .build/x86_64 -c release --show-bin-path)"
    lipo -create "$ARM_DIR/TokenStatMenu" "$INTEL_DIR/TokenStatMenu" -output "$APP/Contents/MacOS/TokenStatMenu"
else
    CONFIG=debug
    if [ "$MODE" = "--release" ]; then CONFIG=release; fi
    swift build --build-system native -c "$CONFIG" --product TokenStatMenu
    BIN_DIR="$(swift build --build-system native -c "$CONFIG" --show-bin-path)"
    cp "$BIN_DIR/TokenStatMenu" "$APP/Contents/MacOS/TokenStatMenu"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
chmod 755 "$APP/Contents/MacOS/TokenStatMenu"
# Ad hoc signing is for a local development build, not a Developer ID / notarization claim.
codesign --force --sign - "$APP"
if [ "$MODE" = "--build-only" ] || [ "$MODE" = "--universal" ]; then echo "Built: $APP"; exit 0; fi
if [ "$MODE" = "--debug" ]; then exec lldb "$APP/Contents/MacOS/TokenStatMenu"; fi
open -n "$APP"
case "$MODE" in
    --verify) sleep 1; pgrep -x TokenStatMenu >/dev/null; echo "Process launched; inspect menu title to verify UI." ;;
    --logs|--telemetry) /usr/bin/log stream --info --predicate 'process == "TokenStatMenu"' ;;
esac
