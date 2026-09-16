# cdn-bundle —— 解开游戏真实代码

游戏的可执行 bundle 以 XXTEA 加密的 `.jsc` 从 CDN 下发，密钥在
`ios-cocos/cocos-project/src/ios2-web-boot.js` 的 `decryptJSC(buffer, '0Aed5E79bbEa69f8')`。
本目录的脚本复用 boot 里**同一个 decryptJSC 实现**（从源码里抠出来直接跑，
不手抄算法），把磁盘缓存里已下好的 bundle 解成明文，用来回答
「游戏真实代码到底怎么写」这类问题。

```bash
cd .workbuddy/tools/cdn-bundle
node decrypt.js            # 零依赖，只用内置 fs / path
# 产物: /tmp/dec-game.js  /tmp/dec-launcher.js
```

缓存位置与索引：
- `~/Library/Application Support/GameLobby/CDN/files/<shard>/<hash>` —— 内容
- `~/Library/Application Support/GameLobby/CDN/index.json` —— URL → 缓存路径
- bundle 的键是 `.../remote/<bundle>/index.<ver>.jsc`

## 靠它查到的事实（2026-09-16）

1. **`window.__require` 是游戏自己的跨 bundle 模块注册表**，不是宿主符号。
   每个 bundle 的 IIFE 第一句就是 `window.__require=function a(r,s,l){…}`，
   并在加载时用 `var c="function"==typeof __require&&__require` 捕获**上一个**加载器
   作为父 require，串成链。→ **宿主绝不可定义/包装它**。
2. 模块表的**键是短名**（`AFKDialog`、`ServerData`、`Configs`、`PlatformManager`…），
   所以脚本 `__require('ServerData')` 能直接解析。
3. 游戏**不**提供 `window.ROLE` / `window.ws` / `window.g_utils` —— 这些确实要靠宿主补。
   （`g_utils` 在现在的 CDN bundle 里根本没有对应模块。）
4. `ServerData` 模块导出 `ROLE`。
