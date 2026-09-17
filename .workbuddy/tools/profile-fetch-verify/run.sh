#!/bin/sh
# 协议层验证：BON 编解码 / 帧信封 与参考实现逐字节对拍 + 端到端抓取冒烟。
#
# 为什么要有这个：BON 解码器一旦错位不会报错，只会让字段值**悄悄变成别的字符串**
# （字符串表错位是静默的），所以「能跑通」不算数，必须与参考实现逐字符对拍。
#
# 用法：
#   sh run.sh [对拍账号.bin]            # 全部
#   OFFLINE_ONLY=1 sh run.sh <账号>      # 只跑**不建游戏会话**的那几段
#
# ⚠️ 大厅正在跑的时候一定要用 OFFLINE_ONLY：authuser + WSS 会建立第二个会话，
#    很可能把正在玩的实例顶掉。纯 HTTP 的 `/login/serverlist` 不建会话，可以照跑。
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
NODE=/Users/gg/.workbuddy/binaries/node/versions/22.22.2-2/bin/node
WORK=${WORK:-/tmp/profile-fetch-verify}
SRC="$ROOT/LobbyCoreSystem/Sources"
ACCOUNT=${1:-15小惜.bin}
OFFLINE_ONLY=${OFFLINE_ONLY:-}

mkdir -p "$WORK"

# 会建立游戏会话的段落统一用这个开关挡住。
if [ -n "$OFFLINE_ONLY" ]; then
    echo "（OFFLINE_ONLY：跳过所有 authuser + WSS 段落）"
    if pgrep -f "GameLobby.app/Contents/MacOS/GameLobby" >/dev/null 2>&1; then
        echo "（检测到大厅正在运行，这个选择是对的）"
    fi
fi

# ① BON 编解码器：从助手仓现拷（避免副本漂移）
sh "$ROOT/.workbuddy/tools/ws-profile-probe/setup.sh" >/dev/null
cp "$ROOT/.workbuddy/tools/ws-profile-probe/bonProtocol.js" "$WORK/bonProtocol.js"
ln -sfn "$ROOT/.workbuddy/tools/ws-profile-probe/node_modules" "$WORK/node_modules"

if [ -z "$OFFLINE_ONLY" ]; then
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
# `AccountProfileFetcher` 现在要解「可能带信封」的响应，所以带上凭据编解码。
sed 's/^import LobbyDomain$//' "$SRC/LobbyEngine/BinCredential.swift" > "$WORK/BinCredential.swift"
xcrun swiftc -O -o "$WORK/fetch-smoke" \
    "$SRC/LobbyDomain/LobbyConfiguration.swift" \
    "$SRC/LobbyDomain/GameRole.swift" \
    "$SRC/LobbyDomain/InputSyncRouting.swift" \
    "$WORK/PageEvent.swift" \
    "$SRC/LobbyEngine/BonCodec.swift" \
    "$SRC/LobbyEngine/XorFrameCipher.swift" \
    "$SRC/LobbyEngine/Lz4Frame.swift" \
    "$WORK/BinCredential.swift" \
    "$WORK/Fetcher.swift" "$WORK/FetchStubs.swift" "$WORK/main.swift"
(cd "$WORK" && ./fetch-smoke "$ACCOUNT")
fi   # ← 结束「会建会话」的段落（② ③）

echo
echo "── .bin 凭据对拍（LZ4 帧解压 + 换服改写）"
# 纯本地：不联网、不建会话。判据是「明文逐字节相同」+「派生凭据字段只剩 serverId 变化」。
cp "$HERE/make-bin-vectors.mjs" "$WORK/make-bin-vectors.mjs"
cp "$HERE/check-bin-vectors.mjs" "$WORK/check-bin-vectors.mjs"
(cd "$WORK" && "$NODE" ./make-bin-vectors.mjs "$ACCOUNT" "4046,9365")
cp "$HERE/parity-bin.swift" "$WORK/main.swift"
# 同 §"端到端抓取"：剥掉工程内部模块的 import 才能独立编译，业务逻辑一字未改。
sed 's/^import LobbyDomain$//' "$SRC/LobbyEngine/BinCredential.swift" > "$WORK/BinCredential.swift"
xcrun swiftc -O -o "$WORK/parity-bin" \
    "$SRC/LobbyDomain/LobbyConfiguration.swift" \
    "$SRC/LobbyDomain/GameRole.swift" \
    "$SRC/LobbyEngine/BonCodec.swift" \
    "$SRC/LobbyEngine/XorFrameCipher.swift" \
    "$SRC/LobbyEngine/Lz4Frame.swift" \
    "$WORK/BinCredential.swift" \
    "$WORK/main.swift"
(cd "$WORK" && ./parity-bin)
(cd "$WORK" && "$NODE" ./check-bin-vectors.mjs)

echo
echo "── 区服角色目录（产品代码，真实服务端，只读不建会话）"
sed 's/^import LobbyDomain$//' "$SRC/LobbyEngine/BinCredential.swift" > "$WORK/BinCredential.swift"
sed 's/^import LobbyDomain$//' "$SRC/LobbyEngine/AccountRoleCatalog.swift" > "$WORK/AccountRoleCatalog.swift"
sed 's/^import LobbyDomain$//' "$SRC/LobbyEngine/GameEndpointClient.swift" > "$WORK/GameEndpointClient.swift"
sed 's/^import LobbyDomain$//' "$HERE/rolelist-smoke.swift" > "$WORK/main.swift"
xcrun swiftc -O -o "$WORK/rolelist-smoke" \
    "$SRC/LobbyDomain/LobbyConfiguration.swift" \
    "$SRC/LobbyDomain/GameRole.swift" \
    "$SRC/LobbyEngine/BonCodec.swift" \
    "$SRC/LobbyEngine/XorFrameCipher.swift" \
    "$SRC/LobbyEngine/Lz4Frame.swift" \
    "$WORK/BinCredential.swift" \
    "$WORK/GameEndpointClient.swift" \
    "$WORK/AccountRoleCatalog.swift" \
    "$WORK/main.swift"
(cd "$WORK" && ./rolelist-smoke "$ACCOUNT")

if [ -z "$OFFLINE_ONLY" ]; then
echo
echo "── 登录代理端到端（产品代码，真实服务端 + WSS；会建会话，务必用没在跑的账号）"
sed 's/^import LobbyDomain$//' "$SRC/LobbyEngine/BinCredential.swift" > "$WORK/BinCredential.swift"
sed 's/^import LobbyDomain$//' "$SRC/LobbyEngine/AccountRoleCatalog.swift" > "$WORK/AccountRoleCatalog.swift"
sed 's/^import LobbyDomain$//' "$SRC/LobbyEngine/GameEndpointClient.swift" > "$WORK/GameEndpointClient.swift"
sed 's/^import LobbyDomain$//; s/^import LobbyIPC$//' \
    "$SRC/LobbyEngine/AccountProfileFetcher.swift" > "$WORK/Fetcher.swift"
sed 's/^import LobbyDomain$//' "$SRC/LobbyIPC/PageEvent.swift" > "$WORK/PageEvent.swift"
sed 's/^import LobbyDomain$//' "$SRC/LobbyEngine/LoginProxy.swift" > "$WORK/LoginProxy.swift"
sed 's/^import LobbyDomain$//' "$HERE/loginproxy-smoke.swift" > "$WORK/main.swift"
xcrun swiftc -O -o "$WORK/loginproxy-smoke" \
    "$SRC/LobbyDomain/LobbyConfiguration.swift" \
    "$SRC/LobbyDomain/GameRole.swift" \
    "$SRC/LobbyDomain/InputSyncRouting.swift" \
    "$SRC/LobbyEngine/BonCodec.swift" \
    "$SRC/LobbyEngine/XorFrameCipher.swift" \
    "$SRC/LobbyEngine/Lz4Frame.swift" \
    "$WORK/BinCredential.swift" \
    "$WORK/GameEndpointClient.swift" \
    "$WORK/AccountRoleCatalog.swift" \
    "$WORK/Fetcher.swift" \
    "$WORK/PageEvent.swift" \
    "$WORK/LoginProxy.swift" \
    "$WORK/FetchStubs.swift" \
    "$WORK/main.swift"
(cd "$WORK" && ./loginproxy-smoke "$ACCOUNT")
fi   # ← 结束「会建会话」的段落（⑥）

echo
echo "── 页面引导脚本垫片（离线：在假 window 里跑真实产物）"
# 三条去向都不能错：authuser 走原生代理、serverlist 换凭据体、其余原样放行。
sed 's/^import LobbyDomain$//' "$SRC/LobbyEngine/BootstrapScriptBuilder.swift" > "$WORK/Bootstrap.swift"
cp "$HERE/dump-bootstrap.swift" "$WORK/main.swift"
xcrun swiftc -O -o "$WORK/dump-bootstrap" \
    "$SRC/LobbyDomain/LobbyConfiguration.swift" \
    "$WORK/Bootstrap.swift" "$WORK/main.swift"
(cd "$WORK" && ./dump-bootstrap > bootstrap.js && ./dump-bootstrap --no-credential > bootstrap-nocred.js)
cp "$HERE/verify-bootstrap-shim.mjs" "$WORK/verify-bootstrap-shim.mjs"
(cd "$WORK" && "$NODE" ./verify-bootstrap-shim.mjs bootstrap.js bootstrap-nocred.js)

echo
echo "全部通过。"
