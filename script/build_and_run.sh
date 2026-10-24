#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE="${1:-run}"
APP="$ROOT/dist/TokenStatMenu.app"
if [ "$#" -gt 1 ]; then
    echo "error: exactly one build mode is allowed; extra arguments are not supported" >&2
    exit 2
fi
case "$MODE" in run|--build-only|--verify|--release|--arm64|--universal|--developer-id|--dev-widget|--logs|--telemetry|--debug) ;; *) echo "Usage: $0 [--build-only|--verify|--release|--arm64|--developer-id|--dev-widget|--logs|--telemetry|--debug]"; exit 2 ;; esac
# Every mode below signs a product. CI must use the explicit unsigned Xcode
# build/test commands, never this local build/install entry point.
for CI_FLAG in CI CONTINUOUS_INTEGRATION GITHUB_ACTIONS GITHUB_RUN_ID GITLAB_CI TF_BUILD \
    JENKINS_URL BUILD_NUMBER BUILD_ID TEAMCITY_VERSION CIRCLECI TRAVIS BUILDKITE \
    CODEBUILD_BUILD_ID BITBUCKET_BUILD_NUMBER DRONE APPVEYOR XCS CI_WORKFLOW; do
    if [ "${!CI_FLAG+x}" = x ]; then
        echo "error: signing builds are local-only; CI must run unsigned build/test commands" >&2
        exit 2
    fi
done
# Keep the old release entry point without producing an Intel slice.
if [ "$MODE" = "--arm64" ]; then MODE=--universal; fi
# Refuse parent links before copying/removing output. In particular, a local
# signing candidate must never resolve into an existing Applications install.
for OUTPUT_DIR in "$ROOT/dist" "$ROOT/.build"; do
    if [ -L "$OUTPUT_DIR" ]; then
        echo "error: symbolic output directories are forbidden" >&2
        exit 2
    fi
done
if [ "$MODE" = "--developer-id" ]; then
    for OUTPUT_DIR in "$ROOT/dist/developer-id" "$ROOT/.build/xcode-developer-id"; do
        if [ -L "$OUTPUT_DIR" ]; then
            echo "error: symbolic output directories are forbidden" >&2
            exit 2
        fi
    done
fi
if [ "$MODE" = "--developer-id" ]; then
    # Validate only explicit inputs before any version bump or output writes.
    TEAM="${TOKENSTAT_TEAM_ID:-}"
    GROUP="${TOKENSTAT_WIDGET_GROUP:-}"
    IDENTITY="${TOKENSTAT_SIGN_IDENTITY:-}"
    APP_PROFILE="${TOKENSTAT_APP_PROFILE:-}"
    WIDGET_PROFILE="${TOKENSTAT_WIDGET_PROFILE:-}"
    APP="$ROOT/dist/developer-id/TokenStatMenu.app"
    python3 -B "$ROOT/script/sign_developer_id.py" --validate-only \
        --app "$APP" --team "$TEAM" --group "$GROUP" --identity "$IDENTITY" \
        --app-profile "$APP_PROFILE" --widget-profile "$WIDGET_PROFILE"
fi
if [ "$(uname -m)" != arm64 ]; then
    echo "error: TokenStatMenu requires Apple Silicon (M-series); run outside Rosetta" >&2
    exit 2
fi
mkdir -p "$(dirname "$APP")"
# Local installs advance CFBundleVersion so WidgetKit treats the bundle as a
# new build and reloads the extension. --universal is a release artifact and
# must keep the version committed for its tag.
if [ "$MODE" != "--universal" ] && [ "$MODE" != "--developer-id" ] && [ "${TOKENSTAT_SKIP_BUILD_BUMP:-0}" != "1" ]; then
    python3 -B "$ROOT/script/bump_build.py"
fi
# Native SwiftPM also works with Command Line Tools; no global xcode-select changes.
if [ "$MODE" = "--universal" ] || [ "$MODE" = "--developer-id" ]; then
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
    if [ "$MODE" = "--developer-id" ]; then DERIVED="$ROOT/.build/xcode-developer-id"; fi
    xcodebuild -project "$ROOT/TokenStatMenu.xcodeproj" -scheme TokenStatMenu \
        -configuration Release -derivedDataPath "$DERIVED" \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
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
    # Resolve development entitlements without modifying the source templates.
    # The Developer ID branch validates its profiles and signs separately below;
    # the historical local candidate uses these ad hoc entitlements.
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
elif [ "$MODE" = "--dev-widget" ]; then
    # Signed local install for widget development. Ad hoc signing cannot grant
    # the App Group, so this branch uses the Apple Development identity and
    # installs over the existing ~/Applications copy.
    TEAM="${TOKENSTAT_TEAM_ID:-}"
    if [ -z "$TEAM" ]; then
        # The name in find-identity is the Apple ID, not the team. The signing
        # team is the certificate subject OU (the same value codesign reports
        # as TeamIdentifier).
        TEAM="$(security find-certificate -a -c 'Apple Development' -p 2>/dev/null \
            | openssl x509 -noout -subject -nameopt sep_comma_plus 2>/dev/null \
            | sed -n 's/.*OU=\([A-Z0-9][A-Z0-9]*\).*/\1/p' \
            | head -n 1)"
    fi
    if [ -z "$TEAM" ]; then
        echo "error: --dev-widget needs an Apple Development identity; set TOKENSTAT_TEAM_ID" >&2
        exit 2
    fi
    GROUP="${TOKENSTAT_WIDGET_GROUP:-$TEAM.com.tupig.TokenStatMenu}"
    if ! [[ "$GROUP" =~ ^(group|[A-Z0-9]{10})(\.[A-Za-z0-9]+([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
        echo "error: invalid TOKENSTAT_WIDGET_GROUP: $GROUP" >&2
        exit 2
    fi
    if ! xcodebuild -version >/dev/null 2>&1 && [ -d /Applications/Xcode.app/Contents/Developer ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
    DERIVED="$ROOT/.build/xcode-dev"
    xcodebuild -project "$ROOT/TokenStatMenu.xcodeproj" -scheme TokenStatMenu \
        -configuration Release -derivedDataPath "$DERIVED" \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
        CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" \
        CODE_SIGN_IDENTITY="Apple Development" \
        TOKENSTAT_WIDGET_GROUP="$GROUP" build
    BUILT_APP="$DERIVED/Build/Products/Release/TokenStatMenu.app"
    if [ ! -d "$BUILT_APP/Contents/PlugIns/TokenStatMenuWidget.appex" ]; then
        echo "error: built app contains no TokenStatMenuWidget.appex" >&2
        exit 1
    fi
    INSTALL_DIR="${TOKENSTAT_INSTALL_DIR:-$HOME/Applications}"
    INSTALLED_APP="$INSTALL_DIR/TokenStatMenu.app"
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALLED_APP"
    ditto "$BUILT_APP" "$INSTALLED_APP"
    if ! codesign --verify --deep --strict "$INSTALLED_APP"; then
        echo "error: signature verification failed" >&2
        exit 1
    fi
    # Replace the cached extension and timeline with this build.
    killall TokenStatMenu 2>/dev/null || true
    killall TokenStatMenuWidget 2>/dev/null || true
    killall chronod 2>/dev/null || true
    open -n "$INSTALLED_APP"
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED_APP/Contents/Info.plist")"
    BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED_APP/Contents/Info.plist")"
    echo "Installed: $INSTALLED_APP ($VERSION build $BUILD)"
    exit 0
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
if [ "$MODE" = "--developer-id" ]; then
    # Both distribution channels validate the same source revision on the host
    # and extension. Complete these edits before either bundle is signed.
    /usr/libexec/PlistBuddy -c "Add :TokenStatSourceRevision string $SOURCE_REVISION" \
        "$APP/Contents/PlugIns/TokenStatMenuWidget.appex/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :TokenStatSourceState string $SOURCE_STATE" \
        "$APP/Contents/PlugIns/TokenStatMenuWidget.appex/Contents/Info.plist"
fi
chmod 755 "$APP/Contents/MacOS/TokenStatMenu"
# Ad hoc signing is for a local development build, not a Developer ID / notarization claim.
# The universal product is signed last, after the source identity is added:
# signing before that edit would leave the Info.plist and signature mismatched.
if [ "$MODE" = "--developer-id" ]; then
    python3 -B "$ROOT/script/sign_developer_id.py" \
        --app "$APP" --team "$TEAM" --group "$GROUP" --identity "$IDENTITY" \
        --app-profile "$APP_PROFILE" --widget-profile "$WIDGET_PROFILE"
elif [ "$MODE" = "--universal" ]; then
    codesign --force --sign - --entitlements "$SIGN_DIR/WidgetExtension.entitlements" \
        "$APP/Contents/PlugIns/TokenStatMenuWidget.appex"
    codesign --force --sign - --entitlements "$SIGN_DIR/TokenStatMenu.entitlements" "$APP"
else
    codesign --force --sign - "$APP"
fi
if ! codesign --verify --deep --strict "$APP"; then
    echo "error: signature verification failed" >&2
    exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
if [ "$MODE" = "--build-only" ] || [ "$MODE" = "--universal" ] || [ "$MODE" = "--developer-id" ]; then echo "Built: $APP ($VERSION build $BUILD, arm64)"; exit 0; fi
if [ "$MODE" = "--debug" ]; then exec lldb "$APP/Contents/MacOS/TokenStatMenu"; fi
open -n "$APP"
case "$MODE" in
    --verify) sleep 1; pgrep -x TokenStatMenu >/dev/null; echo "Process launched; inspect menu title to verify UI." ;;
    --logs|--telemetry) /usr/bin/log stream --info --predicate 'process == "TokenStatMenu"' ;;
esac
