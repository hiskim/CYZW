#!/bin/sh
# 协议层验证：BON 编解码 / 帧信封 与参考实现逐字节对拍 + 端到端抓取冒烟。
#
# 为什么要有这个：BON 解码器一旦错位不会报错，只会让字段值**悄悄变成别的字符串**
# （字符串表错位是静默的），所以「能跑通」不算数，必须与参考实现逐字符对拍。
#
# 用法：sh run.sh [对拍账号.bin]
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
NODE=/Users/gg/.workbuddy/binaries/node/versions/22.22.2-2/bin/node
WORK=${WORK:-/tmp/profile-fetch-verify}
SRC="$ROOT/LobbyCoreSystem/Sources"
ACCOUNT=${1:-15小惜.bin}

mkdir -p "$WORK"

# ① BON 编解码器：从助手仓现拷（避免副本漂移）
sh "$ROOT/.workbuddy/tools/ws-profile-probe/setup.sh" >/dev/null
cp "$ROOT/.workbuddy/tools/ws-profile-probe/bonProtocol.js" "$WORK/bonProtocol.js"
ln -sfn "$ROOT/.workbuddy/tools/ws-profile-probe/node_modules" "$WORK/node_modules"

# ② 生成基准向量（含一次真实 WSS 往返，用没在运行的账号）
#    ⚠️ 脚本要拷进 $WORK 再跑：ESM 的 `./bonProtocol.js` 是**相对脚本自身**解析的，
#    不是相对 cwd——用 `cd $WORK && node <工具目录>/make-vectors.mjs` 会找不到模组。
echo "── 生成基准向量（$ACCOUNT）"
cp "$HERE/make-vectors.mjs" "$WORK/make-vectors.mjs"
(cd "$WORK" && "$NODE" ./make-vectors.mjs "$ACCOUNT")

# ③ BON / 帧信封 对拍：直接编译**产品代码**
echo
echo "── BON 编解码对拍"
cp "$HERE/parity-bon.swift" "$WORK/main.swift"
xcrun swiftc -O -o "$WORK/parity-bon" "$SRC/LobbyEngine/BonCodec.swift" "$WORK/main.swift"
(cd "$WORK" && ./parity-bon)

echo
echo "── 帧信封对拍"
cp "$HERE/parity-cipher.swift" "$WORK/main.swift"
xcrun swiftc -O -o "$WORK/parity-cipher" "$SRC/LobbyEngine/XorFrameCipher.swift" "$WORK/main.swift"
(cd "$WORK" && ./parity-cipher)

echo
echo "── 端到端抓取（产品代码，真实服务端）"
# 剥掉工程内部模块的 import 才能独立编译；**业务逻辑一字未改**。
sed 's/^import LobbyDomain$//; s/^import LobbyIPC$//' \
    "$SRC/LobbyEngine/AccountProfileFetcher.swift" > "$WORK/Fetcher.swift"
sed 's/^import LobbyDomain$//' "$SRC/LobbyIPC/PageEvent.swift" > "$WORK/PageEvent.swift"
cat > "$WORK/FetchStubs.swift" <<'SWIFT'
import Foundation
public enum LobbyLog {
    public static func debug(_ format: String, _ args: Any...) {}
    public static func info(_ format: String, _ args: Any...) { print("[info ] " + format) }
    public static func warn(_ format: String, _ args: Any...) { print("[warn ] " + format) }
    public static func error(_ format: String, _ args: Any...) { print("[error] " + format) }
}
SWIFT
cp "$HERE/fetch-smoke.swift" "$WORK/main.swift"
xcrun swiftc -O -o "$WORK/fetch-smoke" \
    "$SRC/LobbyDomain/LobbyConfiguration.swift" \
    "$SRC/LobbyDomain/InputSyncRouting.swift" \
    "$WORK/PageEvent.swift" \
    "$SRC/LobbyEngine/BonCodec.swift" \
    "$SRC/LobbyEngine/XorFrameCipher.swift" \
    "$WORK/Fetcher.swift" "$WORK/FetchStubs.swift" "$WORK/main.swift"
(cd "$WORK" && ./fetch-smoke "$ACCOUNT")

echo
echo "全部通过。"
