#!/bin/bash
# Render original native geometry, then build every native icon size.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SOURCE="$ROOT/Resources/AppIcon.png"
ICONSET="$ROOT/.build/AppIcon.iconset"
xcrun swift "$ROOT/script/RenderAppIcon.swift" "$SOURCE"
if [ "$(sips -g pixelWidth "$SOURCE" | awk '/pixelWidth/ {print $2}')" != "1024" ] || \
   [ "$(sips -g pixelHeight "$SOURCE" | awk '/pixelHeight/ {print $2}')" != "1024" ]; then
    echo "AppIcon.png must be the reviewed 1024 by 1024 PNG master." >&2
    exit 1
fi
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil --convert icns "$ICONSET" --output "$ROOT/Resources/AppIcon.icns"
echo "Built Resources/AppIcon.icns with macOS sips and iconutil."
