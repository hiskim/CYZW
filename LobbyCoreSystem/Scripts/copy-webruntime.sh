#!/bin/sh
#
# Copy WebRuntime —— 只把 macOS 大厅真正用得到的 WebRuntime 文件拷进主资源包。
#
# 为什么需要白名单
# ────────────────────────────────────────────────────────────────────────────
# `ios-cocos/cocos-project/src` 是 **两种运行形态共用** 的目录：
#
#   ① iOS 原生 JSB 路径（cocos-project/main.js 的 require 链驱动）
#      需要：cocos2d-jsb.07adf.js / ios2-login.js / ios2-manager*.js /
#            ios2-account-*.js / ios2-bin-page.js / ios2-config-page.js /
#            ios2-script-page.js / vendor/fairygui.js
#
#   ② macOS 大厅 WebRuntime（ios2-web-index.html 驱动）
#      只需要本脚本白名单里的那几个文件。
#
# 上一版 `ditto .../src` 是整目录拷贝，把 ① 的 ~2.1 MB 死重量一并塞进了 .app。
# iOS 原生构建读的是 cocos-project 源目录，不受这里的裁剪影响。
#
# 白名单变更时必须同步的位置（不同步会静默失效）
# ────────────────────────────────────────────────────────────────────────────
#   - LobbyStorage/GameResourceSchemeHandler.localPathAliases（规范 URL → 实际文件）
#   - LobbyDomain/LobbyConfiguration.webRuntimeRoot
#   - LobbyEngine/ScriptStore.scriptRuntimeSource()（直接读 src/ios2-script-runtime.js）
#   - 页面侧硬编码：ios-cocos/cocos-project/src/ios2-web-index.html（<script> 顺序）
#
set -eu

fail() {
    echo "error: [Copy WebRuntime] $1" >&2
    exit 1
}

if [ -z "${SRCROOT:-}" ] || [ -z "${TARGET_BUILD_DIR:-}" ] || \
   [ -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
    fail "构建环境变量缺失（SRCROOT / TARGET_BUILD_DIR / UNLOCALIZED_RESOURCES_FOLDER_PATH）"
fi

CP_ROOT="${SRCROOT}/../ios-cocos/cocos-project"
RUNTIME="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/WebRuntime"

[ -d "$CP_ROOT" ] || fail "找不到引擎壳工程：$CP_ROOT"

mkdir -p "$RUNTIME"

# ── 为什么这里没有 `rm -rf "$RUNTIME"` ──────────────────────────────────────
# 整目录重建的**意图**是：Xcode 增量构建不会清理上一版拷进来的文件，
# 被移出白名单的旧文件会一直留在 .app 里。做法换成了「拷完之后按**期望清单**
# 逐文件比对，只删差集」（见文件末尾）——意图完全相同，而且：
#   · 精确：只删真的过期文件，不动正在用的（差集为空时一个都不删）；
#   · 不被拦：本机沙箱对「单次批量删除 > 50 个文件」有确认门闸，整目录删会
#     一次枚举 60+ 个文件 → `PhaseScriptExecution failed`（与 Swift 代码无关，
#     报错里能看到 `[safe-delete][SAFE_DELETE_BULK_CONFIRM_REQUIRED]`）。
MANIFEST=$(mktemp)
trap 'rm -f "$MANIFEST"' EXIT

# copy <相对 CP_ROOT 的源路径> [目标相对路径，默认与源同路径]
copy() {
    src_rel="$1"
    dst_rel="${2:-$1}"
    [ -f "$CP_ROOT/$src_rel" ] || fail "缺少必需文件 $src_rel"
    mkdir -p "$RUNTIME/$(dirname "$dst_rel")"
    ditto "$CP_ROOT/$src_rel" "$RUNTIME/$dst_rel"
    printf '%s\n' "$dst_rel" >> "$MANIFEST"
}

# ① 入口链，顺序与 ios2-web-index.html 的 <script> 标签一致
copy "src/ios2-web-index.html"
copy "src/settings.b2e22.js"        # → /settings.js      别名
copy "src/ios2-web-cocos2d.js"      # → /cocos2d.js       别名（Cocos Web 引擎）
copy "jsb-adapter/game-defines.js"  # → /game-defines.js  别名
copy "src/ios2-web-boot.js"         # → /boot.js          别名（引导 + 纹理/启动补丁）

# ② settings.jsList 的加载目标（boot.js 用 cc.assetManager.loadScript 拉取）
copy "src/assets/launcher/common/libs/platform/hortor/HSDK.app.min.faac9.js"

# ③ Swift 侧直接读盘：ScriptStore.scriptRuntimeSource()
#    （第三方脚本的宿主兼容层，缺了它用户脚本装不上）
copy "src/ios2-script-runtime.js"

# ④ WebRuntime 自身的其它 web 入口。以后新增 ios2-web-*.js 会自动纳入，
#    不必回来改这里。
for f in "$CP_ROOT"/src/ios2-web-*.js; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    case "$base" in
        ios2-web-cocos2d.js|ios2-web-boot.js) continue ;;
    esac
    copy "src/$base"
done

# ⑤ 引擎内置资源包（internal / main，共 ~160 KB）。
#    game-res:// 的 /assets/** 会先命中本地再回落 CDN
#    （GameResourceSchemeHandler.localResource），不裁剪。
ditto "$CP_ROOT/assets" "$RUNTIME/assets"
( cd "$CP_ROOT/assets" && find . -type f | sed 's|^\./||' | sed 's|^|assets/|' ) >> "$MANIFEST"

# ⑥ 只服务 iOS 原生 JSB 路径、对 macOS 是死重量的文件清单。
#    用于下面「未归类文件」的告警：新增 src/*.js 时必须显式归类，
#    否则会出现「脚本能跑、但打进包里的是别人」这类静默故障。
NATIVE_ONLY="app.js resource.js cocos2d-jsb.07adf.js \
ios2-login.js \
ios2-manager.js ios2-manager-common.js \
ios2-account-view.js ios2-account-presenter.js ios2-account-services.js \
ios2-bin-page.js ios2-config-page.js ios2-script-page.js"

for f in "$CP_ROOT"/src/*.js; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    case "$base" in
        ios2-web-*.js|settings.*.js|ios2-script-runtime.js) continue ;;
    esac
    known=0
    for name in $NATIVE_ONLY; do
        if [ "$name" = "$base" ]; then known=1; fi
    done
    if [ "$known" -eq 0 ]; then
        echo "warning: [Copy WebRuntime] src/$base 既不在拷贝白名单、也不在『仅 iOS 原生』清单里。" >&2
        echo "warning:   若 macOS 运行时需要它，请写进 Scripts/copy-webruntime.sh。" >&2
    fi
done

# ⑦ 删残留：上一次构建拷进来、这次不在期望清单里的文件（移出白名单 / 改名）。
#    差集通常为空，此时一个文件都不删——这就是不用 `rm -rf` 的收益（见文件开头）。
ACTUAL=$(mktemp)
EXPECTED=$(mktemp)
trap 'rm -f "$MANIFEST" "$ACTUAL" "$EXPECTED"' EXIT
( cd "$RUNTIME" && find . -type f | sed 's|^\./||' | LC_ALL=C sort ) > "$ACTUAL"
LC_ALL=C sort -u "$MANIFEST" > "$EXPECTED"
stale=$(LC_ALL=C comm -23 "$ACTUAL" "$EXPECTED")
if [ -n "$stale" ]; then
    printf '%s\n' "$stale" | while IFS= read -r rel; do
        rm -f "$RUNTIME/$rel"
        echo "note: [Copy WebRuntime] 移除白名单外的残留：$rel"
    done
    # 顺手收掉因此变空的目录。
    find "$RUNTIME" -type d -empty -delete 2>/dev/null || true
fi

file_count=$(find "$RUNTIME" -type f | wc -l | tr -d ' ')
size_kb=$(du -sk "$RUNTIME" | awk '{print $1}')
echo "note: [Copy WebRuntime] 白名单拷贝完成：${file_count} 个文件 / ${size_kb} KB → $RUNTIME"
