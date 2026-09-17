#!/bin/bash
#
# Build DMG —— 一键编译 macOS 大厅，打成可分发的 .dmg 安装包。
#
# 用法
# ────────────────────────────────────────────────────────────────────────────
#   ./Scripts/build-dmg.sh                        # Release / 双架构 / 自动选签名档位
#   ./Scripts/build-dmg.sh -v 1.2.0 -b 42         # 指定版本号与构建号
#   ./Scripts/build-dmg.sh --arch native          # 只编本机架构（约省一半时间）
#   ./Scripts/build-dmg.sh --identity -            # 强制 ad-hoc 签名
#   ./Scripts/build-dmg.sh --notarize             # Developer ID 签名 + 公证 + 装订
#   ./Scripts/build-dmg.sh --clean --fancy        # 全量重编 + 带窗口布局的 dmg
#
# 产物
# ────────────────────────────────────────────────────────────────────────────
#   build/dist/<显示名>-<版本>.dmg          显示名读自 CFBundleDisplayName（当前：潮音之王）
#   build/dist/<显示名>-<版本>.dmg.sha256
#   build/logs/build-<时间戳>.log          xcodebuild 完整日志
#
# 为什么签名要脚本自己做（工程里 CODE_SIGNING_ALLOWED = NO）
# ────────────────────────────────────────────────────────────────────────────
# pbxproj 的 Debug/Release 都显式关掉了 Xcode 签名——那是本机日常开发的配置，
# 但 dmg 是要分发出去的：
#   · arm64 可执行文件**必须**至少有 ad-hoc 签名，否则内核直接拒绝执行
#     （linker 会自动给可执行文件补一个，但那不覆盖 .app 外壳）；
#   · 没有 bundle 级签名，接收方 Gatekeeper 直接报「已损坏，无法打开」。
# 所以流程是：Xcode 构建 → 脚本改版本号 → 脚本签名 → 打包 dmg。顺序不能换，
# 签名必须在改 Info.plist 之后，否则一改就把签名改失效了。
#
# 签名档位（自动选择，可用 --identity 强制）
# ────────────────────────────────────────────────────────────────────────────
#   ① Developer ID Application  可分发的正式签名，带 hardened runtime + 时间戳
#      · 本机当前没有该证书；拿到证书后不用改脚本，自动升到这一档
#   ② ad-hoc（codesign -s -）    本机自用 / 内测
#      · 接收方首次打开要「右键 → 打开」，或先执行
#        xattr -dr com.apple.quarantine /Applications/潮音之王.app
#
# 为什么默认双架构
# ────────────────────────────────────────────────────────────────────────────
# Release 配置里 ONLY_ACTIVE_ARCH = NO，工程本来就按 ARCHS_STANDARD 出双架构。
# 只是自用想快点就加 --arch native。
#
# 维护须知：中文文案里的变量一律写成 ${VAR}
# ────────────────────────────────────────────────────────────────────────────
# `$VAR（` 这种写法 **C locale 能跑、UTF-8 locale 会崩**：bash 在多字节 locale 下
# 会把紧跟的全角标点算进变量名，于是它要展开的是 `VAR（` 这个不存在的变量，
# `set -u` 下直接报 unbound variable（报错里那个乱码字符就是全角括号本身）。
# 本机终端是 zh_CN.UTF-8，必现；CI 若跑在 C locale 下又一切正常——极易漏测。
# 所以：凡是变量后面紧跟中文或全角符号，必须写成 ${VAR}。
#
set -euo pipefail

# ── 路径常量 ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"                 # LobbyCoreSystem/
REPO_DIR="$(cd "$PROJECT_DIR/.." && pwd)"                   # CYZW/
PROJECT="$PROJECT_DIR/GameLobby.xcodeproj"
RUNTIME_SRC="$REPO_DIR/ios-cocos/cocos-project"             # Copy WebRuntime 的输入
SCHEME="GameLobby"
# 产物文件名 / 可执行文件名 = pbxproj 里 GameLobby target 的 PRODUCT_NAME。
# ⚠️ 改 app 显示名时要同步两处：App/Info.plist 的 CFBundleDisplayName 和
# pbxproj 的 PRODUCT_NAME；脚本这边只改 PRODUCT_NAME 这一行即可派生出
# APP_NAME 和可执行文件路径。
PRODUCT_NAME="潮音之王"
APP_NAME="${PRODUCT_NAME}.app"

WORK_DIR="$PROJECT_DIR/build"
DERIVED_DIR="$WORK_DIR/DerivedData"
LOG_DIR="$WORK_DIR/logs"
OUTPUT_DIR="$WORK_DIR/dist"

# ── 默认参数 ────────────────────────────────────────────────────────────────
CONFIG="Release"
ARCH_MODE="universal"
VERSION=""
BUILD_NUMBER=""
SIGN_IDENTITY=""        # 空 = 自动探测
NOTARIZE=0
NOTARY_PROFILE="AC_NOTARY"
FANCY=0
KEEP_STAGE=0
DO_CLEAN=0
VERBOSE=0
REVEAL=0
JOBS=""

# ── 输出样式 ────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    C_DIM=$'\033[2m'; C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_OFF=$'\033[0m'
else
    C_DIM=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_OFF=""
fi

step()  { printf '%s==>%s %s\n' "$C_CYAN" "$C_OFF" "$*"; }
note()  { printf '%snote:%s %s\n' "$C_DIM" "$C_OFF" "$*"; }
warn()  { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
fail()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
ok()    { printf '%s%s%s\n' "$C_GREEN" "$*" "$C_OFF"; }

usage() {
    # 动态打印文件头部的连续注释块（跳过 shebang），**不要**写死行号：
    # 原来用 `sed -n '2,40p'`，头部注释一增删就会截断或错位（实测已截掉末行）。
    awk 'NR == 1        { next }                 # shebang
         /^#/           { sub(/^# ?/, ""); print; next }
         /^[[:space:]]*$/ { next }               # 注释块里的空行
         { exit }' "${BASH_SOURCE[0]}"            # 第一条真代码 → 停
    exit 0
}

# ── 参数解析 ────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        -c|--configuration) CONFIG="$2"; shift 2 ;;
        -v|--version)       VERSION="$2"; shift 2 ;;
        -b|--build)         BUILD_NUMBER="$2"; shift 2 ;;
        -o|--output)        OUTPUT_DIR="$2"; shift 2 ;;
        -a|--arch)          ARCH_MODE="$2"; shift 2 ;;
        -i|--identity)      SIGN_IDENTITY="$2"; shift 2 ;;
        --notarize)         NOTARIZE=1; shift ;;
        --notary-profile)   NOTARY_PROFILE="$2"; shift 2 ;;
        --fancy)            FANCY=1; shift ;;
        --keep-stage)       KEEP_STAGE=1; shift ;;
        --clean)            DO_CLEAN=1; shift ;;
        --verbose)          VERBOSE=1; shift ;;
        --reveal)           REVEAL=1; shift ;;
        --jobs)             JOBS="$2"; shift 2 ;;
        -h|--help)          usage ;;
        *)                  fail "未知参数：$1（用 --help 看用法）" ;;
    esac
done

case "$CONFIG" in Debug|Release) ;; *) fail "配置只能是 Debug 或 Release：$CONFIG" ;; esac

case "$ARCH_MODE" in
    universal)      ARCHS_VALUE="arm64 x86_64" ;;
    native)         ARCHS_VALUE="$(uname -m)" ;;
    arm64|x86_64)   ARCHS_VALUE="$ARCH_MODE" ;;
    *)              fail "架构只能是 universal / native / arm64 / x86_64：$ARCH_MODE" ;;
esac

# ── 前置检查 ────────────────────────────────────────────────────────────────
step "前置检查"

command -v xcodebuild >/dev/null 2>&1 || fail "找不到 xcodebuild，请先装 Xcode 命令行工具"
[ -d "$PROJECT" ] || fail "找不到工程：$PROJECT"
[ -d "$RUNTIME_SRC" ] || fail "找不到 WebRuntime 源目录：$RUNTIME_SRC
        Copy WebRuntime 构建阶段依赖它，缺了会编译失败。"

# 别写成 `xcodebuild -version | head -1`——head 读完第一行就退出，xcodebuild 写第二行
# 时收到 SIGPIPE 被杀（141）；脚本开着 `set -euo pipefail`，于是**静默**终止，
# 不报错也不继续。冷启动时 xcodebuild 慢，head 抢先退出，必现；第二次已预热、
# 两行一次写完就侥幸通过——表现为「第一次跑直接退出，再跑一次才编译」。
# 所以这里先完整取回输出再截断，全程不出现「提前退出的读端」。
xcode_version="$(xcodebuild -version 2>/dev/null || true)"
printf '%s\n' "${xcode_version%%$'\n'*}"

if [ -n "$VERSION" ] && ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+)*$'; then
    fail "版本号格式不合法：${VERSION}（应形如 1.2 或 1.2.3）"
fi
if [ -n "$BUILD_NUMBER" ] && ! printf '%s' "$BUILD_NUMBER" | grep -Eq '^[0-9]+$'; then
    fail "构建号必须是整数：$BUILD_NUMBER"
fi

mkdir -p "$DERIVED_DIR" "$LOG_DIR" "$OUTPUT_DIR"

BUILD_LOG="$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log"
note "配置 $CONFIG / 架构 $ARCHS_VALUE / 产物目录 $OUTPUT_DIR"

# ── 构建 ────────────────────────────────────────────────────────────────────
if [ "$DO_CLEAN" -eq 1 ]; then
    step "清理上一次构建"
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" clean \
        >"$LOG_DIR/clean-$(date +%Y%m%d-%H%M%S).log" 2>&1 || true
    # xcodebuild clean 已经把构建产物清了，这一步是连索引/日志一起清掉。
    # 与舞台目录同理：整目录删会被批量删除限制拦下，失败了不该让构建中止。
    rm -rf "$DERIVED_DIR" 2>/dev/null \
        || warn "未能删除 DerivedData（批量删除受限？），xcodebuild clean 已生效，继续构建"
    mkdir -p "$DERIVED_DIR"
fi

step "编译 ${SCHEME}（${CONFIG}，${ARCHS_VALUE}）"

XCB_ARGS=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration "$CONFIG"
    -derivedDataPath "$DERIVED_DIR"
    -destination "generic/platform=macOS"
    "ARCHS=$ARCHS_VALUE"
    ONLY_ACTIVE_ARCH=NO
    # 签名完全交给本脚本：覆盖 pbxproj 里的 CODE_SIGN_IDENTITY = "-"，
    # 免得 Xcode 先签一次、我们再签一次。
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=""
)
[ "$VERBOSE" -eq 0 ] && XCB_ARGS+=( -quiet )
[ -n "$JOBS" ] && XCB_ARGS+=( -jobs "$JOBS" )

set +e
xcodebuild "${XCB_ARGS[@]}" build 2>&1 | tee "$BUILD_LOG"
build_rc=${PIPESTATUS[0]}
set -e

if [ "$build_rc" -ne 0 ]; then
    echo
    warn "编译失败（退出码 ${build_rc}），日志末尾 40 行："
    tail -40 "$BUILD_LOG" >&2
    fail "完整日志：$BUILD_LOG"
fi

APP_PATH="$DERIVED_DIR/Build/Products/$CONFIG/$APP_NAME"
[ -d "$APP_PATH" ] || fail "编译结束但找不到产物：$APP_PATH"

# WebRuntime 是运行时命脉，缺了 app 能起来但游戏黑屏——这里显式拦一道。
RUNTIME_OUT="$APP_PATH/Contents/Resources/WebRuntime"
[ -d "$RUNTIME_OUT" ] || fail "产物里没有 WebRuntime（Copy WebRuntime 阶段可能被跳过）：$RUNTIME_OUT"
runtime_files=$(find "$RUNTIME_OUT" -type f | wc -l | tr -d ' ')
note "WebRuntime 已入包：$runtime_files 个文件"

# ── 版本号 ──────────────────────────────────────────────────────────────────
plist_set() {
    local key="$1" value="$2" plist="$3"
    if /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist"
    else
        /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist"
    fi
}

APP_PLIST="$APP_PATH/Contents/Info.plist"
[ -f "$APP_PLIST" ] || fail "产物里没有 Info.plist：$APP_PLIST"

FINAL_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PLIST" 2>/dev/null || echo "1.0")"
FINAL_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PLIST" 2>/dev/null || echo "1")"

if [ -n "$VERSION" ] || [ -n "$BUILD_NUMBER" ]; then
    step "写入版本号"
    # 必须在签名之前改：签名覆盖 Info.plist 的内容摘要，改完再签才对得上。
    [ -n "$VERSION" ]      && { plist_set CFBundleShortVersionString "$VERSION" "$APP_PLIST"; FINAL_VERSION="$VERSION"; }
    [ -n "$BUILD_NUMBER" ] && { plist_set CFBundleVersion "$BUILD_NUMBER" "$APP_PLIST"; FINAL_BUILD="$BUILD_NUMBER"; }
fi
note "版本 ${FINAL_VERSION}（build ${FINAL_BUILD}）"

# ── 应用图标（由 Xcode 构建阶段生成，这里只校验）─────────────────────────────
# 图标**不能**只在本脚本里生成：Xcode 直接 ⌘R / xcodebuild 不过本脚本，那样编出来
# 的 .app 就没有图标。所以照 Copy WebRuntime 的模式挂成 Xcode 构建阶段
# （Generate AppIcon → Scripts/make-appicon.sh），每次编译都跑。
# 本脚本只确认产物里确实有 icns——没有就说明构建阶段没跑或被摘掉了。
ICNS_IN_APP="$APP_PATH/Contents/Resources/AppIcon.icns"
if [ -f "$ICNS_IN_APP" ]; then
    note "图标已就位（$(stat -f%z "$ICNS_IN_APP" 2>/dev/null || echo 0) 字节）"
else
    warn "产物里没有 AppIcon.icns —— 检查 GameLobby target 的 Generate AppIcon 构建阶段是否还在"
fi

# ── 签名 ────────────────────────────────────────────────────────────────────
step "代码签名"

SIGN_KIND=""
# 钥匙串身份先**整体取回**再匹配，不要写成 `security ... | grep -qF`：
# grep -q 命中即退出，写入方收到 SIGPIPE（141），pipefail 会把整条管道判为失败，
# 结果**明明有这个身份却报「找不到」**。同理下面用 sed -n '1p' 而非 head -1。
identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

if [ "$SIGN_IDENTITY" = "-" ] || [ "$SIGN_IDENTITY" = "adhoc" ]; then
    SIGN_KIND="adhoc"
elif [ -n "$SIGN_IDENTITY" ]; then
    case "$identities" in
        *"$SIGN_IDENTITY"*) ;;
        *) fail "钥匙串里找不到签名身份：${SIGN_IDENTITY}（security find-identity -v -p codesigning 可列出）" ;;
    esac
    SIGN_KIND="developer-id"
else
    # 自动探测：优先可分发的 Developer ID，退而求其次 ad-hoc。
    auto_id="$(printf '%s\n' "$identities" \
        | sed -n 's/.*"\(.*\)"/\1/p' | grep '^Developer ID Application:' | sed -n '1p' || true)"
    if [ -n "$auto_id" ]; then
        SIGN_IDENTITY="$auto_id"
        SIGN_KIND="developer-id"
    else
        SIGN_IDENTITY="-"
        SIGN_KIND="adhoc"
    fi
fi

if [ "$SIGN_KIND" = "developer-id" ]; then
    CODESIGN_OPTS=( --force --options runtime --timestamp --sign "$SIGN_IDENTITY" )
    note "档位 ① Developer ID（可分发，带 hardened runtime）"
    note "身份 $SIGN_IDENTITY"
else
    CODESIGN_OPTS=( --force --timestamp=none --sign - )
    note "档位 ② ad-hoc（本机自用 / 内测）"
    warn "没有 Developer ID Application 证书，只能 ad-hoc 签名。"
    warn "接收方首次打开需「右键 → 打开」，或先执行："
    warn "  xattr -dr com.apple.quarantine /Applications/$APP_NAME"
fi

# 先签嵌套的框架 / 动态库（由内向外），再签主 bundle——顺序反了会被外壳签名作废。
nested=$(find "$APP_PATH/Contents" -depth \
    \( -name "*.framework" -o -name "*.dylib" -o -name "*.app" \) 2>/dev/null || true)
if [ -n "$nested" ]; then
    while IFS= read -r item; do
        [ -e "$item" ] || continue
        codesign "${CODESIGN_OPTS[@]}" "$item"
    done <<< "$nested"
    note "已签嵌套组件 $(printf '%s\n' "$nested" | wc -l | tr -d ' ') 个"
fi

codesign "${CODESIGN_OPTS[@]}" "$APP_PATH"
# 显式判失败：否则 pipefail 会让脚本在这里静默退出，只剩 codesign 的原始报错。
if ! codesign --verify --deep --strict --verbose=1 "$APP_PATH" 2>&1 | sed 's/^/    /'; then
    fail "签名校验未通过（见上方 codesign 输出）"
fi
ok "签名校验通过"

# ── 打包 DMG ────────────────────────────────────────────────────────────────
step "打包 dmg"

# 卷名 / dmg 文件名取 app 的**显示名**（CFBundleDisplayName），与 App/Info.plist
# 同源：以后改名只要动 Info.plist，脚本不用跟着改。读不到（比如极老的产物）就
# 退回 target 名，不让打包因此失败。
# ⚠️ 别写成 `PlistBuddy ... | head`：见本脚本「提前退出的读端」那节，会静默退出。
DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_PLIST" 2>/dev/null || true)"
[ -n "$DISPLAY_NAME" ] || DISPLAY_NAME="$PRODUCT_NAME"

VOL_NAME="${DISPLAY_NAME} ${FINAL_VERSION}"
arch_suffix=""
[ "$ARCH_MODE" != "universal" ] && arch_suffix="-$ARCHS_VALUE"
DMG_PATH="$OUTPUT_DIR/${DISPLAY_NAME}-${FINAL_VERSION}${arch_suffix}.dmg"

# 舞台目录每次**新建**，不复用、也不先删旧的。
# 刻意不用「固定目录 + rm -rf 重建」：本机沙箱对「单次批量删除 > 50 个文件」
# 有确认门闸，删一个装好 app 的舞台目录（60+ 个文件）会被拦下直接失败
# （copy-webruntime.sh 头部注释里踩过同一个坑）。每次新建既能天然避免上一版
# 残留，也不需要任何删除动作。
STAGE_DIR="$(mktemp -d "$WORK_DIR/stage.XXXXXX")" || fail "无法创建舞台目录：$WORK_DIR"
ditto "$APP_PATH" "$STAGE_DIR/$APP_NAME"
ln -s /Applications "$STAGE_DIR/Applications"      # 经典「拖进 Applications」布局

if [ "$FANCY" -eq 1 ]; then
    # 带窗口布局的 dmg：先做读写镜像 → 挂载 → Finder 摆图标 → 卸载 → 转压缩。
    # 需要「自动化 → Finder」权限；不需要花哨布局就别开（见下方超时处理）。
    RW_DMG="$WORK_DIR/.rw-tmp.dmg"
    MNT="$WORK_DIR/.mnt"
    rm -f "$RW_DMG"
    rm -rf "$MNT"
    mkdir -p "$MNT"

    hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE_DIR" -ov -format UDRW "$RW_DMG" >/dev/null
    hdiutil attach "$RW_DMG" -nobrowse -readwrite -mountpoint "$MNT" >/dev/null

    # 为什么 osascript 放后台 + 20 秒上限
    # ────────────────────────────────────────────────────────────────────────
    # 「自动化 → Finder」未授权时，osascript 会弹授权框然后**一直等**，脚本会
    # 无限卡住（CI / 无人值守场景就是挂死）。布局只是锦上添花，不能拖垮构建，
    # 所以：后台跑，超时就杀掉并降级——dmg 照出，只是没有图标摆位。
    osascript <<APPLESCRIPT >/dev/null 2>&1 &
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 160, 800, 560}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 110
        set position of item "$APP_NAME" of container window to {150, 170}
        set position of item "Applications" of container window to {450, 170}
        close
    end tell
end tell
APPLESCRIPT
    osascript_pid=$!

    layout_ok=0
    for _ in $(seq 1 40); do                       # 40 × 0.5s = 20s
        kill -0 "$osascript_pid" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "$osascript_pid" 2>/dev/null; then
        kill "$osascript_pid" 2>/dev/null || true
        wait "$osascript_pid" 2>/dev/null || true
        warn "窗口布局设置超时，已跳过（未授权 Finder 自动化时会卡在授权框）"
    else
        wait "$osascript_pid" 2>/dev/null && layout_ok=1 || true
    fi
    if [ "$layout_ok" -eq 1 ]; then
        note "已写入 dmg 窗口布局"
    else
        warn "窗口布局未生效，dmg 仍可正常安装（图标位置由系统默认排布）"
    fi

    # 读写挂载 + Finder 会往卷里写 .fseventsd / .Trashes 这类系统目录。
    # 尽力清掉（.fseventsd 基本清得掉）；.Trashes 可能在我删完后又被 Finder
    # 重建，但那只是个隐藏空目录，不影响挂载与拖拽安装，不值得为它中断构建。
    rm -rf "$MNT/.fseventsd" "$MNT/.Trashes" 2>/dev/null || true

    sync
    hdiutil detach "$MNT" >/dev/null || hdiutil detach "$MNT" -force >/dev/null
    rm -f "$DMG_PATH"
    hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
    rm -f "$RW_DMG"
    rm -rf "$MNT"
else
    hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE_DIR" -ov \
        -format UDZO -imagekey zlib-level=9 "$DMG_PATH" >/dev/null
fi

[ -f "$DMG_PATH" ] || fail "dmg 没有生成：$DMG_PATH"

# ── 校验 ────────────────────────────────────────────────────────────────────
step "校验产物"

# 同理：`A && B` 里 A 失败会让整条语句返回非 0，set -e 直接终止且不说原因。
if hdiutil verify "$DMG_PATH" >/dev/null; then
    note "dmg 镜像校验通过"
else
    fail "dmg 镜像校验失败：$DMG_PATH"
fi

( cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256" )

if [ "$NOTARIZE" -eq 1 ]; then
    [ "$SIGN_KIND" = "developer-id" ] || fail "公证要求 Developer ID 签名，当前是 ad-hoc"
    step "提交公证（notarytool，profile: ${NOTARY_PROFILE}）"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    ok "公证完成并已装订"
fi

if [ "$KEEP_STAGE" -eq 0 ]; then
    # 清理失败不该让完成的构建前功尽弃——舞台目录在 build/ 下，本就是可弃物。
    rm -rf "$STAGE_DIR" 2>/dev/null \
        || warn "舞台目录未能自动清理（多半撞上批量删除限制），可手动删：$STAGE_DIR"
else
    note "保留舞台目录：$STAGE_DIR"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
dmg_size=$(du -h "$DMG_PATH" | awk '{print $1}')
# 可执行文件名跟 PRODUCT_NAME 走（Xcode 26 的 Release 是单一静态可执行文件；
# Debug 的主程序是空壳、代码在 .debug.dylib 里，架构以主程序为准即可）。
app_archs=$(lipo -archs "$APP_PATH/Contents/MacOS/${PRODUCT_NAME}" 2>/dev/null || echo "未知")
dmg_sha=$(awk '{print $1}' "$OUTPUT_DIR/$(basename "$DMG_PATH").sha256")

echo
ok "════════ 构建完成 ════════"
printf '  安装包   %s\n' "$DMG_PATH"
printf '  大小     %s\n' "$dmg_size"
printf '  版本     %s (build %s)\n' "$FINAL_VERSION" "$FINAL_BUILD"
printf '  架构     %s\n' "$app_archs"
printf '  签名     %s\n' "$SIGN_KIND"
printf '  SHA256   %s\n' "$dmg_sha"
printf '  日志     %s\n' "$BUILD_LOG"
echo

if [ "$SIGN_KIND" = "adhoc" ]; then
    printf '%s提醒：ad-hoc 签名未公证，接收方首次打开需要右键 → 打开。%s\n' "$C_YELLOW" "$C_OFF"
fi

if [ "$REVEAL" -eq 1 ]; then
    open -R "$DMG_PATH"
fi
