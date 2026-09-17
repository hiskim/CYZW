#!/bin/sh
# 准备 ws-profile-probe 的运行环境。
#
# 为什么不在本目录里放一份 bonProtocol.js 副本：
# 那是助手仓的源码（唯一真源），拷一份进来必然漂移——它改了我们不知道，
# 探针就会给出与服务端实际不一致的结论。所以每次运行都从助手仓**现拷**。
#
# 用法：sh setup.sh   （之后 node probe-roleinfo.mjs）
set -eu

HELPER="${XYZW_HELPER:-/Users/gg/code/xyzw_web_helper}"
HERE=$(cd "$(dirname "$0")" && pwd)
NODE_WORKSPACE="${NODE_WORKSPACE:-$HOME/.workbuddy/binaries/node/workspace}"

[ -d "$HELPER" ] || { echo "找不到助手仓：$HELPER（用 XYZW_HELPER=... 指定）" >&2; exit 1; }

# ① BON 编解码器（每次现拷，避免副本漂移）
cp "$HELPER/src/utils/bonProtocol.js" "$HERE/bonProtocol.js"
echo "已同步 bonProtocol.js ← $HELPER/src/utils/bonProtocol.js"

# ② lz4js 只在 lx 方案用得上（本路径只遇到 px），但 bonProtocol.js 顶层就 import 了它，
#    所以必须能解析到。软链到托管 node 工作区的 node_modules（那里已装 lz4js）。
if [ ! -d "$NODE_WORKSPACE/node_modules/lz4js" ]; then
    echo "缺少 lz4js，先装："
    echo "  cd $NODE_WORKSPACE && npm install lz4js"
    exit 1
fi
ln -sfn "$NODE_WORKSPACE/node_modules" "$HERE/node_modules"
echo "已软链 node_modules → $NODE_WORKSPACE/node_modules"
echo
echo "可以跑了，例如："
echo "  node probe-serverlist.mjs '11不不.bin'"
echo "  node probe-authuser.mjs  '11不不.bin'"
echo "  node probe-roleinfo.mjs  '15小惜.bin'"
