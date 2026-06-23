#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WORK="$ROOT/.icon-build"
ICONSET="$WORK/AppIcon.iconset"
MASTER="$WORK/AppIcon_1024.png"
OUT="$ROOT/Resources/AppIcon.icns"

rm -rf "$WORK"
mkdir -p "$ICONSET" "$ROOT/Resources"

echo "==> Rendering 1024 master"
swift run Claudance --render-icon "$WORK" >/dev/null

echo "==> Generating iconset sizes"
gen() { sips -z "$2" "$2" "$MASTER" --out "$ICONSET/$1" >/dev/null; }
gen icon_16x16.png        16
gen icon_16x16@2x.png     32
gen icon_32x32.png        32
gen icon_32x32@2x.png     64
gen icon_128x128.png      128
gen icon_128x128@2x.png   256
gen icon_256x256.png      256
gen icon_256x256@2x.png   512
gen icon_512x512.png      512
cp "$MASTER" "$ICONSET/icon_512x512@2x.png"

echo "==> Packing $OUT"
iconutil -c icns "$ICONSET" -o "$OUT"
echo "==> Done: $OUT"
