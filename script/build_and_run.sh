#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE="${1:-run}"
APP="$ROOT/dist/TokenStatMenu.app"
case "$MODE" in run|--build-only|--verify|--release|--universal|--logs|--telemetry|--debug) ;; *) echo "Usage: $0 [--build-only|--verify|--release|--universal|--logs|--telemetry|--debug]"; exit 2 ;; esac
mkdir -p "$(dirname "$APP")"
# Native SwiftPM also works with Command Line Tools; no global xcode-select changes.
if [ "$MODE" = "--universal" ]; then
    # A universal distribution build must come from the Xcode project: only
    # that target graph embeds the widget extension and substitutes the App
    # Group placeholder in both Info.plists and entitlements.
    GROUP="${TOKENSTAT_WIDGET_GROUP:-}"
    if [ -z "$GROUP" ]; then
        echo "error: --universal requires TOKENSTAT_WIDGET_GROUP=group.<name> or TEAMID.<name>" >&2
        exit 2
    fi
    if ! [[ "$GROUP" =~ ^(group|[A-Z0-9]{10})(\.[A-Za-z0-9]+([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] || [[ "$GROUP" == FICTEAM* ]] || [ "${#GROUP}" -gt 128 ]; then
        echo "error: TOKENSTAT_WIDGET_GROUP must look like group.<name> or TEAMID.<name>" >&2
        exit 2
    fi
    if ! xcodebuild -version >/dev/null 2>&1 && [ -d /Applications/Xcode.app/Contents/Developer ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
    DERIVED="$ROOT/.build/xcode-universal"
    xcodebuild -project "$ROOT/TokenStatMenu.xcodeproj" -scheme TokenStatMenu \
        -configuration Release -derivedDataPath "$DERIVED" \
        ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
        TOKENSTAT_WIDGET_GROUP="$GROUP" build
    BUILT_APP="$DERIVED/Build/Products/Release/TokenStatMenu.app"
    WIDGET_APPEX="$BUILT_APP/Contents/PlugIns/TokenStatMenuWidget.appex"
    if [ ! -d "$WIDGET_APPEX" ]; then
        echo "error: built app contains no TokenStatMenuWidget.appex" >&2
        exit 1
    fi
    if ! /usr/libexec/PlistBuddy -c "Print :TokenStatWidgetGroup" \
            "$BUILT_APP/Contents/Info.plist" 2>/dev/null | grep -Fxq "$GROUP"; then
        echo "error: built Info.plist does not carry TOKENSTAT_WIDGET_GROUP" >&2
        exit 1
    fi
    if ! /usr/libexec/PlistBuddy -c "Print :TokenStatWidgetGroup" \
            "$WIDGET_APPEX/Contents/Info.plist" 2>/dev/null | grep -Fxq "$GROUP"; then
        echo "error: widget Info.plist does not carry TOKENSTAT_WIDGET_GROUP" >&2
        exit 1
    fi
    rm -rf "$APP"
    cp -R "$BUILT_APP" "$APP"
    # The local machine has no signing identity, so Xcode cannot sign the
    # product. Sign it ad hoc after embedding the resolved group in the
    # entitlement plists; a signed build never reaches this branch.
    SIGN_DIR="$DERIVED/signing"
    mkdir -p "$SIGN_DIR"
    sed "s|\$(TOKENSTAT_WIDGET_GROUP)|$GROUP|g" Resources/WidgetExtension.entitlements \
        > "$SIGN_DIR/WidgetExtension.entitlements"
    sed "s|\$(TOKENSTAT_WIDGET_GROUP)|$GROUP|g" Resources/TokenStatMenu.entitlements \
        > "$SIGN_DIR/TokenStatMenu.entitlements"
    for ENTITLEMENTS in "$SIGN_DIR/WidgetExtension.entitlements" "$SIGN_DIR/TokenStatMenu.entitlements"; do
        if ! grep -Fq "$GROUP" "$ENTITLEMENTS" || grep -Fq '$(' "$ENTITLEMENTS"; then
            echo "error: $ENTITLEMENTS does not carry a resolved widget group" >&2
            exit 1
        fi
    done
else
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    CONFIG=debug
    if [ "$MODE" = "--release" ]; then CONFIG=release; fi
    swift build --force-resolved-versions -c "$CONFIG" --product TokenStatMenu
    BIN_DIR="$(swift build --force-resolved-versions -c "$CONFIG" --show-bin-path)"
    cp "$BIN_DIR/TokenStatMenu" "$APP/Contents/MacOS/TokenStatMenu"
    cp Resources/Info.plist "$APP/Contents/Info.plist"
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# Only public source identity enters the bundle: never include a machine path,
# hostname, account, configuration, or session. Exported source has no Git ID.
SOURCE_REVISION="source-export"
SOURCE_STATE="unspecified"
SOURCE_GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
# A source export unpacked below another repository must never inherit that
# unrelated repository's revision or working-tree state.
if [ -n "$SOURCE_GIT_ROOT" ] && [ "$(cd "$SOURCE_GIT_ROOT" && pwd -P)" = "$(pwd -P)" ]; then
    SOURCE_CANDIDATE_REVISION="$(git rev-parse --verify HEAD 2>/dev/null || true)"
    if [ -n "$SOURCE_CANDIDATE_REVISION" ]; then
        SOURCE_REVISION="$SOURCE_CANDIDATE_REVISION"
        SOURCE_STATE="clean"
        if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then SOURCE_STATE="modified"; fi
    fi
fi
/usr/libexec/PlistBuddy -c "Add :TokenStatSourceRevision string $SOURCE_REVISION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :TokenStatSourceState string $SOURCE_STATE" "$APP/Contents/Info.plist"
chmod 755 "$APP/Contents/MacOS/TokenStatMenu"
# Ad hoc signing is for a local development build, not a Developer ID / notarization claim.
# The universal product is signed last, after the source identity is added:
# signing before that edit would leave the Info.plist and signature mismatched.
if [ "$MODE" = "--universal" ]; then
    codesign --force --sign - --entitlements "$SIGN_DIR/WidgetExtension.entitlements" \
        "$APP/Contents/PlugIns/TokenStatMenuWidget.appex"
    codesign --force --sign - --entitlements "$SIGN_DIR/TokenStatMenu.entitlements" "$APP"
else
    codesign --force --sign - "$APP"
fi
if ! codesign --verify --deep --strict "$APP"; then
    echo "error: ad hoc signature verification failed" >&2
    exit 1
fi
if [ "$MODE" = "--build-only" ] || [ "$MODE" = "--universal" ]; then echo "Built: $APP"; exit 0; fi
if [ "$MODE" = "--debug" ]; then exec lldb "$APP/Contents/MacOS/TokenStatMenu"; fi
open -n "$APP"
case "$MODE" in
    --verify) sleep 1; pgrep -x TokenStatMenu >/dev/null; echo "Process launched; inspect menu title to verify UI." ;;
    --logs|--telemetry) /usr/bin/log stream --info --predicate 'process == "TokenStatMenu"' ;;
esac
