#!/bin/sh
#
# Generate AppIcon —— 从源图生成 AppIcon.icns，放进构建产物的 Resources。
#
# 为什么独立成脚本 + 挂到 Xcode 构建阶段
# ────────────────────────────────────────────────────────────────────────────
# 图标如果只由 Scripts/build-dmg.sh 生成，那 Xcode 直接 ⌘R / xcodebuild 出来的
# .app 就没有图标（只有打 dmg 的那一版有）。所以照 Copy WebRuntime 的模式做成
# Xcode 构建阶段：每次编译都跑，调试版和发包版都带图标。
#
# 两个必须知道的工具约定（都踩过）
# ────────────────────────────────────────────────────────────────────────────
#   1. `sips` 不会按扩展名自动转格式：源是 JPEG 时 `--out xxx.png` 只换名不换
#      格式，iconutil 会以 "Invalid Iconset" 拒绝。必须显式 `-s format png`。
#   2. 传给 iconutil 的目录名必须以 `.iconset` 结尾，否则同样 "Invalid Iconset"。
#      而 mktemp 的模板又必须以 XXXX 结尾，两者冲突 → 套一层：mktemp 出临时父
#      目录，里面再建 AppIcon.iconset。
#
set -eu

fail() {
    echo "error: [Generate AppIcon] $1" >&2
    exit 1
}

if [ -z "${SRCROOT:-}" ] || [ -z "${TARGET_BUILD_DIR:-}" ] || \
   [ -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
    fail "构建环境变量缺失（SRCROOT / TARGET_BUILD_DIR / UNLOCALIZED_RESOURCES_FOLDER_PATH）"
fi

ICON_SRC="${SRCROOT}/App/Assets/AppIcon-source.jpg"
RESOURCES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"

[ -f "$ICON_SRC" ] || fail "找不到图标源图：$ICON_SRC"

mkdir -p "$RESOURCES"

TMP_PARENT=$(mktemp -d)
ICONSET="${TMP_PARENT}/AppIcon.iconset"
mkdir -p "$ICONSET"
# 清理失败无所谓，临时目录本来就可弃；不能让它把构建打断。
trap 'rm -rf "$TMP_PARENT" 2>/dev/null || true' EXIT

# iconutil 约定的 10 个尺寸（含 @2x）
for spec in "16|icon_16x16.png" \
            "32|icon_16x16@2x.png" \
            "32|icon_32x32.png" \
            "64|icon_32x32@2x.png" \
            "128|icon_128x128.png" \
            "256|icon_128x128@2x.png" \
            "256|icon_256x256.png" \
            "512|icon_256x256@2x.png" \
            "512|icon_512x512.png" \
            "1024|icon_512x512@2x.png"; do
    px="${spec%|*}"
    fn="${spec#*|}"
    sips -s format png -z "$px" "$px" "$ICON_SRC" --out "$ICONSET/$fn" >/dev/null
done

iconutil -c icns "$ICONSET" -o "${RESOURCES}/AppIcon.icns"

size=$(stat -f%z "${RESOURCES}/AppIcon.icns" 2>/dev/null || echo 0)
echo "note: [Generate AppIcon] 已生成 AppIcon.icns（${size} 字节）→ $RESOURCES"
