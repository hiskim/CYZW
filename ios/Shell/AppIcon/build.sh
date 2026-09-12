#!/usr/bin/env bash
# 生成 macOS App Icon 全套资源：1024 源 + 各级 PNG + .icns + AppIcon.appiconset
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
SRC="$ROOT/icon.svg"

OUT_ROOT="$ROOT/dist"
ICONSET="$OUT_ROOT/AppIcon.iconset"
APPICONSET="$OUT_ROOT/AppIcon.appiconset"

rm -rf "$OUT_ROOT"
mkdir -p "$ICONSET" "$APPICONSET"

NODE_BIN="/Users/gg/.workbuddy-ai/binaries/node/versions/22.22.2-2/bin/node"
NODE_PATH="/Users/gg/.workbuddy-ai/binaries/node/workspace/node_modules"

render() {
  local size="$1"; local out="$2"
  NODE_PATH="$NODE_PATH" "$NODE_BIN" "$ROOT/render.js" "$SRC" "$out" "$size" >/dev/null
}

# 1. 各级 PNG
SIZES=(16 32 64 128 256 512 1024)
for s in "${SIZES[@]}"; do
  render "$s" "$ICONSET/icon_${s}x${s}.png"
done

# @2x 派生
cp "$ICONSET/icon_32x32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"

# Xcode AppIcon.appiconset 命名（1024 现代源 + 各级）
cp "$ICONSET/icon_16x16.png"   "$APPICONSET/icon_16x16.png"
cp "$ICONSET/icon_16x16@2x.png" "$APPICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_32x32.png"   "$APPICONSET/icon_32x32.png"
cp "$ICONSET/icon_32x32@2x.png" "$APPICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_128x128.png" "$APPICONSET/icon_128x128.png"
cp "$ICONSET/icon_128x128@2x.png" "$APPICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_256x256.png" "$APPICONSET/icon_256x256.png"
cp "$ICONSET/icon_256x256@2x.png" "$APPICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_512x512.png" "$APPICONSET/icon_512x512.png"
cp "$ICONSET/icon_512x512@2x.png" "$APPICONSET/icon_512x512@2x.png"

# 现代 Xcode AppIcon 仅需 1024
cp "$ICONSET/icon_1024x1024.png" "$APPICONSET/icon_1024x1024.png"

# 2. .icns
iconutil -c icns "$ICONSET" -o "$OUT_ROOT/CYZW.icns"

# 3. Contents.json
cat > "$APPICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png",       "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png",    "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",       "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png",    "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",     "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",     "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",     "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "Done."
echo "  iconset: $ICONSET"
echo "  appiconset: $APPICONSET"
echo "  icns: $OUT_ROOT/CYZW.icns"
ls -la "$OUT_ROOT"