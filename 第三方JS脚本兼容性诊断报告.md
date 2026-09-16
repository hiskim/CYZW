# 第三方 JS 脚本（xyzw-ls 4.5.5 免费版）在 macOS 大厅的兼容性诊断 · v2

> **脱敏说明**：本文档记录的是第三方脚本的兼容性结论。为免把第三方服务的
> 基础设施信息落到仓库里，以下内容已做占位符替换（不影响结论）：
> 认证服务器主机 → `<auth-host>`；其接口命名空间 → `/<auth>/`、`/<auth-config>/`、`/<updates>/`；
> 本机绝对路径 → `<repo>` / `<home>` / `<脚本目录>` / `<另一个 worktree 拷贝>`。
> 原文保留在本地未入库版本中。


> v2 修正：上一版把门闸说成"卡密鉴权"是错的。**免费版确实跳过卡密校验**
> （`CARD_REQUIRED` / `CARD_EXPIRED` 不会拦），但它仍然强制走**设备认证**
> （`/<auth>/verify` 拿 `data.token`）。这是两件不同的事。
> 而且 `authPassed` 不是唯一门闸 —— `roleInitialized` 必须同时为真。
> 下面所有结论都有实测对照。

---

## 一、结论

脚本的 UI 挂载被**两把锁**同时把住，缺任何一个都不会出现悬浮球图标：

| 门闸 | 依赖 | 我们的宿主 |
|---|---|---|
| `authPassed` | `POST http://<auth-host>/api/<auth>/verify` 返回 `data.token` | ❌ 明文 HTTP 被 ATS 拦（`Info.plist` 无 ATS 例外） |
| `roleInitialized` | `window.ROLE`（或 `__require('ServerData').ROLE`） | ❌ WebRuntime 里没有 `require`，ROLE 永远为空 |

### 实测 2×2 对照（同一份脚本，jsdom + 完整宿主垫片）

| 设备认证 | `window.ROLE` | `.qa-root` | `.floating-orb` | `<style>` 数 | DOM 元素数 |
|---|---|---|---|---|---|
| ✅ 返回 token | ✅ 有 | **true** | **true** | 2 | 1851 |
| ✅ 返回 token | ❌ 无 | false | false | 0 | 7 |
| ❌ 无 token | ✅ 有 | false | false | 0 | 7 |
| ❌ 请求失败（模拟被拦） | ✅ 有 | false | false | 0 | 7 |

**两把锁都开 → 图标出现；任一把没开 → 图标永远不出现。** 与"脚本无法启动、游戏中没有显示脚本的图标"完全吻合。

### 复现脚本的启动链路

```
load
 ├─ document.getElementById('qa-panel')          已挂载守卫
 ├─ document.querySelector('.floating-orb')      已挂载守卫
 ├─ 注册全局热键/鼠标监听（focus/keydown/mousedown/mouseout…）
 ├─ 画水印（读 ROLE.name / serverViewId / serverName）
 ├─ readROLE()  反复读 ROLE.roleId        → roleInitialized
 ├─ POST http://<auth-host>/api/<auth>/verify
 │    读响应 resp.data → data.frozen / data.disabled / data.error / data.token
 │    → authPassed（必须有 data.token）
 └─ 两把锁都开 → mount()
       injectStyle → <head>.appendChild(<style>)     （实测 2 个 <style>）
       div#qa-orb.floating-orb + SVG 图标
         title="点击展开/收起 / 长按切换主题 / 可拖动位置"
       div#qa-panel.panel-shell（menu-nav / content-area / #qa-watermark）
       body.appendChild
       → 之后才开始初始化功能模块
```

---

## 二、脚本依赖的宿主接口（明文清单）

### 全局符号（脚本自己的 keep-alive 块里逐字列出，75 个）

```
WebKit/DOM : document Node Element HTMLElement HTMLCanvasElement HTMLInputElement
             HTMLButtonElement HTMLSelectElement Image MutationObserver CustomEvent
             MessageEvent DOMException
网络/编码  : fetch Headers Response WebSocket Blob File FileReader URL URLSearchParams
             AbortController CompressionStream DecompressionStream atob btoa
             TextEncoder TextDecoder
油猴       : GM_xmlhttpRequest GM_download GM_openInTab unsafeWindow
游戏桥     : __require window.ROLE window.cc window.g_utils
存储/其它  : localStorage navigator performance screen requestAnimationFrame
```

### 网络端点（全部在明文 HTTP 的 `http://<auth-host>/api`，实测抓到的完整清单）

| 方法 | 路径 | 作用 | 是否为图标门闸 |
|---|---|---|---|
| `POST` | `/<auth>/verify` | **设备认证，返回 `data.token`** | ✅ **是（必需）** |
| `GET` | `/<auth-config>/layout-scope/current` | 布局配置同步 | 挂载后 |
| `GET` | `/<updates>/latest?scriptEdition=free&t=…` | 版本更新检查 → `CustomEvent('versionOutdated')` | 挂载后 |
| `POST` | `/<auth>/heartbeat` | 周期心跳 | 挂载后 |
| `GET` | `/coop/status`（带 `Authorization: Bearer`） | 联网助战统计 | 按需 |

> 注意：请求体带 `fingerprint` / `deviceInfo` / `scriptEdition` / `scriptVersion`，
> 并显式拼了一堆 cookie 头（`_ga`、`__cf_bm`、`HMACCOUNT`…）和 `X-Forwarded-Cookie` /
> `X-CF-Challenge` / `x-time` / `x-update-time`。`scriptEdition` 实测值为 **`free`**。

### 游戏模块（`__require`，实测跨三种写法）

```
短名        : Configs / index-ui / PlayerInfoDialog / HeroAttributeToolTip
相对路径    : ../orange/data/ServerData   ../orange/dataView/HeroDataView
              ../../launcher/config/Configs
```

→ `__require` 必须**同时**支持短名与相对路径（做路径归一化，取末段）。

### socket

```
window.ws / window.gameWs / window.gameSocket / window.WebSocketClient
window.h5websocket(.ws) / socket.sendAsync()
实测请求体：{"ack":0,"body":{},"cmd":"presetteam_getinfo","seq":1,"time":…}
```

### 平台探测

```
navigator.userAgent.test(/iPad|iPhone|iPod/)          → isIOS
navigator.userAgent.test(/Android|webOS|iPhone|…/)     → isMobile
PlatformManager.instance.isIOS / isAndroid / isMobile / platformExt
```

---

## 三、逐项缺陷（实测 + 文件:行号）

### ①【P0 · 图标不出现的直接原因】`Info.plist` 缺 ATS 例外

`LobbyCoreSystem/App/Info.plist`（全文 30 行）**没有 `NSAppTransportSecurity` 键**。
脚本必须完成 `POST http://<auth-host>/api/<auth>/verify`（明文 HTTP + IP 直连）才能拿到
`data.token` → 置 `authPassed`。WKWebView 默认按 ATS 拦截非 HTTPS 请求 → 请求失败 → 无图标
（上表第 4 行实测复现）。

参考宿主两边都开了：

| 文件 | 值 |
|---|---|
| `ios-cocos/.../proj.ios_mac/ios/Info.plist` | `NSAppTransportSecurity → NSAllowsArbitraryLoads = true` |
| `ios-cocos/.../proj.ios_mac/mac/Info.plist` | `NSAppTransportSecurity → NSAllowsArbitraryLoads = true` |

**修**：`App/Info.plist` 补

```xml
<key>NSAppTransportSecurity</key>
<dict><key>NSAllowsArbitraryLoads</key><true/></dict>
```

> 附带要验证的风险：页面 origin 是自定义 scheme（`ios2-game://app`），向 `http://<auth-host>`
> 发起的是跨域 `fetch`。iOS 参考宿主把脚本页面放在 `https://ios2.local/`，我们的 origin 不同，
> 需要确认服务端返回的 `Access-Control-Allow-Origin` 能接受。若不行，就得让游戏页面跑在一个
> 被服务端白名单认可的 origin 下。

### ②【P0 · 第二把锁】`__require` / `window.ROLE` 在 macOS 上永远不存在

`ios2-script-runtime.js:248-252` 只做两路探测：

```js
if (typeof global.__require === 'function') return global.__require;
if (typeof global.require  === 'function') return global.require;
return null;          // ← macOS 上永远走这里
```

而 WebRuntime（`ios-cocos/cocos-project`）**没有任何地方创建 `__require` / `require`**
（全仓只有 `assets/*/index.*.js` 的 `typeof __require` 探测、`main.js:99` 的读取、以及兼容层自己）。
于是 `refreshGlobals()`（`:367-416`）里

```js
if (!global.g_utils && requireFn) global.g_utils = requireFn('g_utils');          // 不执行
if (!global.ROLE    && requireFn) global.ROLE = requireFn('ServerData').ROLE;     // 不执行
```

→ `window.ROLE` 永远为空 → `roleInitialized` 永假 → 无图标（上表第 2 行实测复现）。

参考实现 `IOS2ScriptWebView.mm:55` 是**主动造**的：

```js
window.__require = function (name) {
  if (name === 'ServerData')    return { ROLE: window.ROLE || {} };
  if (name === 'GlobalSignal')  return { GlobalSignal: signals };
  if (name === 'ModuleManager') return { GET_MODULE: …, getModule: … };
  return window.__ios2ModuleProxy(name);
};
```

配合 `:43` 的 `__ios2ApplyRole()` 与原生每秒 `syncRole:`。

> 实测：脚本挂载后会调 `require(Configs)` / `require(index-ui)` / `require(PlayerInfoDialog)` /
> `require(HeroAttributeToolTip)`。所以即使只为了"能启动"，`__require` 也必须真的能返回东西，
> 否则面板起来了但功能全废。

### ③【P0】socket 五个别名只读不写

`_findSocket()`（`:228-246`）只**读** `ws / h5websocket(.ws) / gameWs / WebSocketClient / _ws / gameSocket`；
兼容层**从不写** `gameWs / gameSocket / WebSocketClient / h5websocket`，`window.ws` 也只在
`_patchWebSocket`（`:93-122`）捕获到游戏 WebSocket 首次 `send` 时才补。
参考实现 `:50` 一把给全五个。实测脚本挂载后会直接 `ws.sendAsync({cmd:'presetteam_getinfo',…})`。

### ④【P1】`waitForGame()` 在 macOS 主路径上从未被调用

`GameViewportInstance.swift:150-164` 注入兼容层后只调 `install()`，那一刻是 atDocumentStart，
游戏还没建 socket、还没登录；会轮询的 `waitForGame()`（`:418-434`）只有旧的
`ios2-script-page.js` 在用。用户脚本在 **atDocumentEnd** 注入（`:165-176`），早于游戏 socket 建立。

### ⑤【P1】`IOS2Native.*` 方法族只剩 `runtimeBackend` 活着

`BootstrapScriptBuilder.swift:64-76`：非 `runtimeBackend` 且非两个 HSDK 类 → `return null`。
Swift 侧（`Sources/**`）也**没有任何 `IOS2Native` 处理分支**。页面侧实际调用的
`showScripts:` / `scriptFileContent:` / `listScriptFiles` / `selectScriptFile` / `hideScriptWebView` /
`syncRole:` / `webViewEvent:` / `webViewResponse:` / `trace:` 全部被静默吞掉
→ `startRoleSync()` 每秒推的 ROLE 白推；游戏内那套 JS 脚本页面在 macOS 上是死的。

### ⑥【P2】`GM_*` 无垫片；`<a download>` 在 WKWebView 不弹保存框

脚本 keep-alive 明确列了 `GM_xmlhttpRequest` / `GM_download` / `GM_openInTab`。
导出功能（实测 blob #3313）走 `Blob + URL.createObjectURL + <a download>`，WKWebView 里不会触发下载。

### ⑦【P2】架构残留：`_mirrorSocket` / `_ensureSendAsync`

- `_mirrorSocket`（`:181-226`）逐包 `_copyJSONSafe` + `JSON.stringify` 后调用一个**已被丢弃**的
  `IOS2Native.webViewEvent:`，四开就是 4 份主线程 JSON 序列化（会撞 `slowMainWork` 探针）。
- `_ensureSendAsync`（`:124-177`）**临时顶掉游戏自己的 `socket.onmessage`** 去匹配响应，10s 超时才还原。
- iOS 参考实现是给脚本一个**独立假 socket**（`:49`）经原生转发（`:274-290`），不碰游戏 socket。
  macOS 上脚本与游戏同页，这套跨 WebView 镜像纯属负担。

### ⑧【轻微】平台口径自相矛盾

`ios2-web-boot.js:1431-1438` 把游戏 `PlatformManager.isH5` 强改 `false` 伪装原生 iOS，
而 `navigator.userAgent` 仍是 Mac。脚本两处都判（`PlatformManager.isIOS` 和 UA 正则）。

---

## 四、修复优先级

| 优先级 | 改动 | 位置 |
|---|---|---|
| **P0** | 补 `NSAppTransportSecurity / NSAllowsArbitraryLoads` | `LobbyCoreSystem/App/Info.plist` |
| **P0** | 造 `window.__require`（短名 + 相对路径归一化，至少提供 `ServerData.ROLE`、`GlobalSignal`、`ModuleManager`）+ `window.ROLE` + `window.g_utils` | `ios2-script-runtime.js:refreshGlobals` |
| **P0** | `_findSocket` 命中后**写回**全部别名 `gameWs / gameSocket / WebSocketClient / h5websocket` | `ios2-script-runtime.js:228-246` |
| P1 | 注入兼容层后调 `waitForGame(15000, …)`，别只 `install()`；或让 runtime 自己周期重跑 `refreshGlobals` | `GameViewportInstance.swift:156` |
| P1 | 给 `IOS2Native` 加真实路由（至少 `trace:` / `syncRole:`）或按 macOS 语义实现 | `BootstrapScriptBuilder.swift:64-76` + 新响应器 |
| P2 | 加 `GM_*` 垫片（`GM_xmlhttpRequest` 用 `fetch` 实现即可，跨域由 ATS 例外放开） | `ios2-script-runtime.js:install` |
| P2 | 关掉 `_mirrorSocket`；`sendAsync` 改成独立代理 socket，别顶替游戏 `onmessage` | `ios2-script-runtime.js:181-226 / 124-177` |
| P3 | 统一平台口径；`stop()` 补 `removeAllUserScripts()` | `ios2-web-boot.js:1431` / `GameViewportInstance.swift:210` |

---

## 五、验证方法

打开 Web Inspector（`defaults write com.xyzw.gamelobby.macos lobby.debug.webInspector -bool true`，
右键「检查元素」），在游戏页 Console 里跑：

```js
// 1) ATS 是否放开 + 设备认证是否可通
await fetch('http://<auth-host>/api/<auth>/verify', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ fingerprint: 'probe', deviceInfo: {}, scriptEdition: 'free', scriptVersion: '4.5.5' })
}).then(r => r.json()).then(j => console.log('verify ->', j.data && j.data.token ? 'TOKEN OK' : j),
                          e => console.log('verify BLOCKED', e));

// 2) 第二把锁
console.log('ROLE =', window.ROLE, ' __require =', typeof window.__require,
            ' g_utils =', window.g_utils, ' ws =', window.ws, ' WebSocketClient =', window.WebSocketClient);

// 3) 脚本是否挂载
console.log(document.querySelector('#qa-root'), document.querySelector('.floating-orb'));
```

脚本内部日志带 `[XYZW BattleFloat]` / `[英雄队伍增强]` 前缀，搜索这些可以看它走到哪一步。

---

## 附：诊断用沙箱（可复用）

```bash
cd <home>/.workbuddy/binaries/node/workspace

# token 正常 + ROLE 正常  → 悬浮球出现
NODE_PATH=$PWD/node_modules <home>/.workbuddy/binaries/node/versions/22.22.2-2/bin/node ab_run.js full

# 对照组
NO_TOKEN=1    ... ab_run.js full     # 无 token        → 不挂载
NO_ROLE=1     ... ab_run.js full     # 无 window.ROLE  → 不挂载
FETCH_FAIL=1  ... ab_run.js full     # 请求失败        → 不挂载
                  ... ab_run.js ios  # 对照 iOS 参考宿主
                  ... ab_run.js macos# 对照我们的 macOS 兼容层
```

文件：`ab_run.js`（A/B 主程序）、`host_full.js`（完整宿主垫片 + fetch/JSON 埋点）、
`host_ios.js`（`IOS2ScriptWebView.mm` 的 JS 移植）、`host_macos.js`（复刻我们的垫片语义）、
`canvas_mock.js`（jsdom 无 canvas 后端）、`xyzw_probe*.js`（早期探测）。

---

# v3：已实施的修复与验证

## 改动清单

### ① `LobbyCoreSystem/App/Info.plist`
新增 `NSAppTransportSecurity → NSAllowsArbitraryLoads = true`（附注释说明为什么必须开）。

### ② `ios-cocos/cocos-project/src/ios2-script-runtime.js`（兼容层）

| 改动 | 说明 |
|---|---|
| `_installRequireHooks()` **新增** | 用 `Object.defineProperty(window,'__require',{get,set})` 接管模块入口。`get` 返回宿主包装器（用户脚本 + 游戏加载器共用）；`set` 把游戏自己装载的 require **记成 delegate**，而不是让出符号。带深度闸避免 delegate ⇄ wrapper 互递归。 |
| `_resolveModuleName()` **新增** | `../orange/data/ServerData` → `ServerData`；短名与相对路径都能落到同一模块。 |
| `_fallbackModule()` / `_moduleProxy()` **新增** | 对齐参考实现的约定模块：`ServerData→{ROLE}`、`GlobalSignal→{signals}`、`ModuleManager→{GET_MODULE}`，其余走 Proxy（方法调用转为不抛异常的 no-op）。 |
| `_installSignalBus()` **新增** | GlobalSignal 总线的宿主实现（on/add/once/off/emit/dispatch/trigger）。 |
| `_readRole()` / `_applyRole()` / `syncRole()` **新增** | ROLE 从 `__require('ServerData').ROLE` 或 `window.ServerData` 解析，装上 `window.ROLE` 并补 `enchantMap.get`，同时广播 `ROLE` 信号。 |
| `_publishSocketAliases()` **新增** | 一次写全 `ws / gameWs / gameSocket / WebSocketClient / h5websocket`（只写空缺的，绝不覆盖游戏自己的）。 |
| `_startEnvironmentPolling()` **新增** | `install()` 内启动 1s × 60 有界轮询补齐环境（原来只跑一次 `refreshGlobals`，且跑在 atDocumentStart，必然落空）。 |
| `_installGMApi()` **新增** | `GM_xmlhttpRequest`（基于 fetch + 超时中止）、`GM_download`（Blob + a[download]）、`GM_openInTab`（window.open 失败时上报 `openurl` 给原生）。 |
| `_encodeRequest()` **新增** | `sendAsync` 优先用真实 `g_utils.bon.encode`（仅当它返回字符串才采用），否则回退 JSON。 |
| `_ensureSendAsync()` / `_sendAsyncOnce()` **改写** | 并发 `sendAsync` 串行化（原来两个请求会互相抢 `socket.onmessage`）；还原时只在「还是我们装的那个 handler」时才还原，不顶掉游戏中途换上的处理器。 |
| `_mirrorInbound` / `_forwardRoleToNative` **新增宿主形态开关** | 同页（macOS）默认关：不再每包深拷贝 + JSON.stringify 去调用一个已被丢弃的 `IOS2Native.webViewEvent:`，也不再每秒把 ROLE 推给没人接的原生方法。`waitForGame()` 会打开它们（旧覆盖 WebView 架构照旧）。 |
| `refreshGlobals()` **改写** | 接入 require hooks / 信号总线；`g_utils` 只在能拿到真实模块时才安装（同页形态不给恒等实现——那会把自定义协议体写成明文对象，属静默发错包）。 |
| `reset()` **改写** | 只收回本层自己写的别名（`_ownedSocketAliases` 列表），并停掉轮询。 |

> `g_utils` 的取舍是刻意的：参考实现给的是**恒等**实现，那是安全的——因为它的真编码
> 由原生侧完成。我们同页形态没有那个原生编码器，给恒等实现反而会静默发错包，
> 所以拿不到真模块时宁可不给。

### ③ `LobbyCoreSystem/Sources/LobbyEngine/GameViewportInstance.swift`
- `start()` 里兼容层注入处补注释，说明 `install()` 自带环境轮询、**不需要**再调 `waitForGame`（那是旧覆盖 WebView 架构的路径）。
- `stop()` 补 `removeAllUserScripts()`（`WKUserScript` 绑在 userContentController 上、随导航注入，只摘消息处理器会残留叠加）。
- 新增 `openExternally(_:)`：只放行 http/https 才交给 `NSWorkspace`，防止脚本用自定义 scheme 触发本机调用。

### ④ `LobbyCoreSystem/Sources/LobbyIPC/PageEvent.swift`
新增 `case openURL(url:)` + `"openurl"` 解码分支（`GM_openInTab` 的原生兜底路径）。

## 验证结果

**编译**：`xcodebuild -project GameLobby.xcodeproj -scheme GameLobby -configuration Debug build` → **BUILD SUCCEEDED**；
产物体内 `Resources/WebRuntime/src/ios2-script-runtime.js` 与源**逐字节一致**，`Contents/Info.plist` 的 ATS 已生效。

**端到端**（沙箱跑**真实的**改造后 `ios2-script-runtime.js` + 复刻 macOS 宿主语义的 jsb 垫片；
`socket` 与游戏模块**晚于**用户脚本上线，用于验证轮询）：

| 场景 | `window.ROLE` | `#qa-root` | `.floating-orb` | `<style>` | 元素数 |
|---|---|---|---|---|---|
| 默认（ATS 已修 + 游戏上线） | roleId 12345678 | **true** | **true** | 2 | 1838 |
| ATS 未修（fetch 被拦） | 有 | false | false | 0 | 9 |
| 游戏未上线（无模块/socket） | undefined | false | false | 0 | 9 |

关键点：`window.ROLE` **不是测试预置的**，是兼容层自己从 `require('ServerData').ROLE` 解析出来的；
五个 socket 别名也全部由兼容层发布；游戏加载器 delegate 调用轨迹实测为
`ServerData → GlobalSignal → Configs → index-ui → PlayerInfoDialog → HeroAttributeToolTip`，
说明**真实模块走通了，且没有与宿主兜底互递归**。

## 仍需上机确认的两点（无法在沙箱判定）

1. **真实游戏是否真的把它的模块加载器赋给 `window.__require`。**
   沙箱里是模拟的 delegate。若真机不给，`__require` 就只剩约定模块兜底
   （`ServerData.ROLE`、`GlobalSignal`、`ModuleManager`），ROLE 仍能拿到、图标仍会出现，
   但 `Configs` / `index-ui` / `PlayerInfoDialog` 这些面板功能会退化成 no-op。
   验证：Console 里 `window.__require.__ios2HostRequire === true` 且
   `window.__require('Configs')` 返回真实对象（不是 `__ios2ModuleName` 代理）。
2. **设备认证接口的跨域放行。** 页面 origin 是自定义 scheme `ios2-game://app`，
   向 `http://<auth-host>` 是跨域 `fetch`，需服务端 `Access-Control-Allow-Origin` 接受。
   验证：Console 里跑报告 §五 的第 1 段代码，看返回 `TOKEN OK` 还是 `BLOCKED`。
   若被 CORS 拦，就要让游戏页面跑在一个被服务端白名单认可的 origin 下。

---

# v5：导出功能修复（`/storage/emulated/0/Download/` 问题）

> v4 走过一次弯路，这里更正：我先做了「页面侧接管控件点击」的方案，
> 但用真实 WKWebView 验证后发现 **WebKit 原生就完整支持这条路径**，
> 只要宿主实现下载代理即可。页面垫片不但多余、还更差（依赖脚本运行时被注入
> ——而那正是当前坏掉的那条链路），已**全部撤掉**。

## 一、现象与两个关键事实

现象：脚本提示 `导出成功 → /storage/emulated/0/Download/`，macOS 上没有任何文件；
日志里有 `Could not create a sandbox extension for ''`。

**事实 1：那句路径只是脚本硬编码的提示文案。**
脚本（猫助手系列，未混淆版可直接读源码）有 5 处这样的提示，跟真实落盘位置无关。
不去改它 —— 也不该改，改了下次更新就没了。

**事实 2：真实机制是 `Blob` + `<a download>`，全脚本 10 处、形态完全一致：**

```js
const blob = new Blob([text], { type: 'text/plain' });
const a = document.createElement('a');
a.href = URL.createObjectURL(blob);
a.download = '兑换码.txt';
a.click();                    // ← 多数处根本没把锚点插进文档
URL.revokeObjectURL(a.href);
```

## 二、根因：宿主没实现 WebKit 的下载代理

用真实 WKWebView 做了最小探针（见 `.workbuddy/tools/wkwebview-probe/`），
**不加任何页面垫片**时 WebKit 的行为是：

```
POLICY: shouldPerformDownload=true → .download
didBecome download (navigationAction)
DECIDE-DESTINATION suggested=probe-out.txt → /tmp/dlprobe/out/probe-out.txt
downloadDidFinish
文件落盘: true 内容=EXPORT-PAYLOAD        ← blob: 成功
文件落盘: true 内容=DATA-PAYLOAD          ← data: 也成功
```

三条结论：

1. `shouldPerformDownload == true` **对脱离文档的锚点同样成立** ——
   脚本那种 `a.click()` 不 append 的写法，WebKit 一样认。
2. WebKit 会把锚点 `download` 属性的值**原样**带进 `suggestedFilename`
   （上面 `probe-out.txt` 就是脚本指定的名字），不需要我们从 URL 里猜文件名。
3. 只要宿主在 `decideDestinationUsing` 里给出位置，`blob:` 与 `data:` 都能正常落盘。

而我们的 app **一个下载代理都没实现** → WebKit 进了下载通道却拿不到目的地 →
日志打的就是那条空路径 `Could not create a sandbox extension for ''`，下载被丢弃。
这就是「导出了但什么都没有」的全部原因。

## 三、修复

### `Sources/LobbyEngine/GameViewportInstance.swift`

`WKNavigationDelegate` 补上三件事，外加一个 `WKDownloadDelegate`：

```swift
// ① 锚点带 download 属性 → 走下载通道
if navigationAction.shouldPerformDownload { decisionHandler(.download) }

// ② 响应无法在页面里显示（未知 MIME / 附件）也走下载
if !navigationResponse.canShowMIMEType { decisionHandler(.download) }

// ③ 拿到 WKDownload 后挂代理（delegate 是弱引用，必须自己持有）
private var activeDownloads: [ObjectIdentifier: ScriptDownloadSink] = [:]
```

新增 `ScriptDownloadSink`（文件内 `private final class`）：

- `decideDestinationUsing` → `DownloadStore.destinationURL(...)`，只挑位置，
  **内容由 WebKit 流式写盘**，所以再大的文件也不在内存里过一遍；
- `downloadDidFinish` / `didFailWithError` → 释放目的地预约 + 记账。

### `Sources/LobbyStorage/DownloadStore.swift`

- 落盘目录 = 系统「下载」目录（app 未启用沙盒，拿到的是真实 `~/Downloads`）；
- `destinationURL(preferredName:mimeType:)`：文件名按**不可信输入**处理
  （拍平路径穿越、剥前后点、限长、按 MIME 补扩展名、重名 `-2`/`-3`）；
- **目的地预约**：`destinationURL` 是「先问后写」，WebKit 拿到路径之后才落盘，
  中间有窗口 —— 同一批导出里两次同名会撞到同一路径、后者覆盖前者。
  所以发出即登记，下载结束（成功或失败）释放；
- 保留 base64 写入通道（`PageEvent` 的 `download` / `downloadurl` 两个 case），
  作为脚本主动交字节给原生时的入口；当前打入的运行时不会走这条，
  但它是页面桥契约的一部分，且已覆盖测试。

## 四、验证

**编译**：`xcodebuild … build` → **BUILD SUCCEEDED**；
产物二进制含 `[download] webkit download ->` 等新日志，`DownloadStore` 38 个符号；
WebRuntime 内的兼容层已确认**不再含**下载桥。

**WebKit 行为**（真实 WKWebView 探针，`--kind=blob` / `--kind=data`）：见上，均落盘成功。

**`DownloadStore` 逻辑**（编译真实源文件跑的 13 项断言，全部落在临时目录）：

| 用例 | 结果 |
|---|---|
| `../../../etc/导出.txt` → 拍平成 `导出.txt`，且确认在下载目录内 | PASS |
| 目的地初始不存在（WebKit 会覆盖已存在路径） | PASS |
| 无扩展名 + `image/png` → `cap.png` | PASS |
| 在途同名第一次 `same.txt`、第二次自动 `same-2.txt` | PASS |
| 释放后可重新复用该名字 | PASS |
| 已落盘文件仍然避让（`taken.txt` → `taken-2.txt`） | PASS |
| **6 个线程并发写同名 → 6 个文件 / 6 种内容**（预约机制生效） | PASS |
| 超 32 MB 拒绝 / 非法 base64 拒绝 / 空内容可落盘 / 中文往返正确 | PASS |

## 五、使用说明

- 导出成功后**脚本的提示文案不会变**（还是那句 Android 路径）。文件在 `~/Downloads`。
- 同名文件不覆盖，会自动 `-2`、`-3`。同一天反复导战报会得到多份副本，这是刻意的。
- 现在这条链路**不依赖脚本运行时**了：即使脚本兼容层没被注入（也就是「图标不出现」
  那个问题），导出照样能用。日志里搜 `[download] webkit download ->` 能看到最终路径。

---

# v6：排查前置 —— 先确认「你跑的是哪一份产物」

这次卡了好几轮，根因不在代码，而在**跑错了产物**。记录下来避免重犯。

## 现象

改动 + 构建都成功，用户重装后现象「完全一样」，包括日志都一模一样。

## 真相

机器上同时存在两份工程拷贝，产物落在**两个不同的 DerivedData**：

| | 工程路径 | 产物构建时间 | 今天的修复 |
|---|---|---|---|
| **用户 Xcode 里跑的** | `<另一个 worktree 拷贝>/LobbyCoreSystem/` | 11:50 | ❌ 一条都没有 |
| **本会话改的（唯一有效）** | `<repo>/LobbyCoreSystem/` | 18:34 | ✅ 全部 |

两份是**无共同祖先**的两条历史（`git merge-base` 为空），所以不能 merge，只能复制文件。
判定证据：

```bash
# 当前运行的进程路径
pgrep -fl GameLobby
lsappinfo find bundleid=com.xyzw.gamelobby.macos | xargs -I{} lsappinfo info -only bundlepath {}
# → <home>/Library/Developer/Xcode/DerivedData/GameLobby-hbppmdglnberbiblnrotsnlpdcwe/...   ← 不是我构建的那个

# 那个 DerivedData 属于哪个工程
plutil -p <DerivedData>/info.plist | grep WorkspacePath
# → <另一个 worktree 拷贝>/LobbyCoreSystem/GameLobby.xcodeproj

# 那个产物里有没有今天的修复
nm -U <那个产物>/GameLobby.debug.dylib | grep -c DownloadStore
# → 0
```

## 结论 / 规矩

1. **本仓库的权威拷贝是 `<repo>`。** 不要用
   `<另一个 worktree 拷贝>` 下的 worktree（历史分叉，且不含修复）。
2. Xcode 里要打开的工程是
   `<repo>/LobbyCoreSystem/GameLobby.xcodeproj`。
3. 每次汇报「还是不行」之前，先看一眼启动第一行日志：
   ```
   [lobby] build 2026-09-16.5 | scriptRuntime=on downloadDelegate=on openURL=on | webInspector=off
   ```
   `buildTag` 定义在 `App/Sources/GameLobbyApp.swift`，**每次改动宿主行为都要 bump**。
   看不到这行 = 跑的不是这一版，先解决这个再谈别的。
4. 命令行构建的 DerivedData 与 Xcode 的**可能是两个**。核对产物时用
   `plutil -p <DerivedData>/info.plist | grep WorkspacePath` 确认它属于哪个工程。

---

# v7：回归修复 —— 宿主不能接管 `window.__require`

## 现象

打开「脚本加载」开关后，游戏**卡在「正在加载游戏场景」**。（关掉就正常 → 问题在兼容层。）

## 根因：v3 的 `__require` 接管是错的

v3 我用 `Object.defineProperty(window,'__require',{get,set})` 接管了模块入口，
出发点是一个**错误的前提**：「WebRuntime 里没人创建 `__require`」。
那个结论来自 grep 本地仓库（`ios-cocos/cocos-project`）—— 但 `__require` 是在
**CDN 下发的加密 bundle 里**创建的，本地 grep 看不见。

把缓存里的真实 bundle 解开（见 `.workbuddy/tools/cdn-bundle/`），**第一句**就是：

```js
window.__require = function a(r, s, l) {
  function u(t, e, i) {
    if (!s[t]) {
      if (!r[t]) {
        var o = t; t.includes("./") && (o = (o = t.split("/"))[o.length - 1]);
        if (!r[o]) {
          var n = "function" == typeof __require && __require;
          if (!e && n) return n(o, !0);      // ← 回落到「宿主」
          if (c) return c(o, !0);            // ← 父 require：跨 bundle 就靠这条
          throw new Error("Cannot find module '"+t+"'")
        }
        t = o
      }
      ...
  }
  for (var c = "function" == typeof __require && __require, e = 0; e < l.length; e++) u(l[e]);
  return u
}({ AFKDialog: [...], ... })
```

也就是说：

- **`window.__require` 是游戏自己的跨 bundle 模块注册表**。每个 bundle 加载时把自己挂上去，
  并用 `typeof __require === 'function' && __require` 捕获**上一个**加载器作为父 require，
  串成一条链。
- 我把它改成 getter/setter 后：**游戏对 `window.__require` 的赋值全被 setter 吞掉**
  （只记成 `_requireDelegate`），`window.__require` 永远是宿主的包装器；
  后续 bundle 捕获到的「父 require」因此是包装器而不是上一个真加载器 → **链断**。
- 更糟的是包装器的兜底：深度闸一触发就返回**代理桩**而不是真模块。
  于是跨 bundle 的模块（`Configs` / `PlatformManager` / `LocalStorage` …）全变成垃圾对象
  → 加载流程走不完 → **卡在「正在加载游戏场景」**。

顺带纠正 v3 的另一处推论：脚本要的短名（`ServerData` / `Configs` / `PlatformManager` /
`GlobalSignal` / `ModuleManager` / `HeroDataView`）**本来就是游戏模块表的键**，
游戏自己的加载器直接解析得到 —— 宿主压根不需要兜底模块。

## 修复

`ios2-script-runtime.js`（净删 7.1 KB）：

| 动作 | 说明 |
|---|---|
| **删除** `_installRequireHooks` | 不再 defineProperty / 包装 `window.__require`（附长注释写清为什么绝对不能碰） |
| **删除** `_resolveModuleName` / `_fallbackModule` / `_moduleProxy` / `_installSignalBus` | 兜底模块机制不再需要，一并移除以避免误用 |
| `_findRequire` 回到纯读取 | `global.__require` → `global.require` → `null` |
| `_readRole` 改走游戏加载器 | `__require('ServerData').ROLE`；失败重试上限 10 次，避免每秒让加载器抛一次 |
| `g_utils` 只试一次 | CDN bundle 里没有这个模块；拿不到就真的没有，**不给恒等实现**（恒等编码 = 静默发错包） |
| `_mirrorSignals` 同页形态直接不装 | 信号镜像只服务于旧的双 WebView 架构 |

保留的改动（与本次回归无关、且确有价值）：socket 五别名写回、环境轮询、
`GM_*` 垫片、`sendAsync` 串行化与真实编码、WebKit 下载代理、ATS 例外。

## 验证

新增**不变量回归测试** `workspace/test_require_untouched.js`（用加载器的最小复刻把规矩钉死）：

| 断言 | 结果 |
|---|---|
| ① 第一个 bundle 加载时 `typeof __require` 仍是 `undefined` | PASS |
| ② 第一个 bundle 捕获到的父 require 是 `false`（不是宿主函数） | PASS |
| ③ 游戏对 `window.__require` 的赋值原样生效（未被吞掉） | PASS |
| ④ 跨 bundle 解析走通（没有落到宿主兜底桩） | PASS |
| ⑤ 宿主包装器不存在 | PASS |
| ⑥ 兼容层能借游戏加载器取到 `ROLE` | PASS |

原脚本挂载回归（`ab_run.js macos`）同时通过：悬浮球出现，模块全部经游戏加载器解析
（`ServerData → Configs → index-ui → PlayerInfoDialog → HeroAttributeToolTip`）。

构建产物核对：构建指纹 `2026-09-16.6`、兼容层已无 `_installRequireHooks`、
仍保留 `__require` 读取、下载代理仍在。

---

# v8：`模拟对战.js`「能运行但没有效果」—— `window.ws.sendAsync` 发错格式

## 脚本侧证据

`模拟对战.js`（未混淆，`@name 战斗模拟`）真正"动手"的地方只有一个：

```js
async sendCommand(cmd, params = {}) {
    if (!window.ws || typeof window.ws.sendAsync !== 'function') {
        throw new Error('WebSocket sendAsync 不可用');
    }
    return window.ws.sendAsync({ ack: 0, cmd, params, seq: Date.now(), time: Date.now() });
}
```

它靠 `__require` / `ModuleManager.GET_MODULE` / `GlobalSignal` 读游戏数据，靠
`window.ws.sendAsync({cmd, params})` 下命令。前者我们上一版已修好；**后者格式是错的**。

## 游戏侧证据：socket 是二进制 + 自定义分帧的私有 RPC

解开 `launcher/index.6db9f.jsc`（真实游戏代码）：

```js
var d = new WebSocket(r);
d.binaryType = "arraybuffer";
d.onmessage = function (e) {
    if (3 <= t.connVer) e.data instanceof ArrayBuffer && e.data.byteLength === 1
        && new Uint8Array(e.data)[0] == 3
        ? t._sm.changeState(Running)                 // ← 1 字节握手
        : (console.error("handshake error"), ...);
    else t.addResp(e.data);
};

sendInternal = function (e) {
    n = { ack: this.getAndUseAck(), body: a.encode(e.params), hint: e.hint,
          time: Date.now(), seq: ++t.seq };
    e.c ? n.c = e.c : n.cmd = e.cmd;
    o = He(n, this.enc);                              // ← 分帧成二进制
    t.enqueue(o);
};
B.prototype.sendAsync = function (e) { … 返回 Promise 回包 … };
```

连接 URL 还带 `?p=<encodeURIComponent(connParam)>&e=<encoding>&ack=<seq>&perMessageDeflate=0`。

所以：**裸 socket 只接受已经分好帧的二进制**，`body` 编码器在 `@o4e/core` 里、帧格式是私有的，
宿主一个都拿不到。我们原来的做法（把 `JSON.stringify(...)` 塞进裸 socket）只会把 RPC 流写坏，
命令到不了服务端 —— 表现就是「能运行但没有效果」。

## 正确入口

同一个 bundle 里就有：

```js
_.sendAsync = function (e) { return _.wsDelegate.sendAsync(e); }   // NetworkManager
// 游戏自己也是这么发的：
a.NetworkManager.sendAsync({ cmd: r.CMDS.Hero_GoIntoBattle, params: { slot: e, heroId: t } })
```

入参形状正是 `{cmd, params}` —— 与脚本完全对上。

## 修复（`ios2-script-runtime.js`）

- 新增 `_gameNetwork()`：经游戏加载器取 `NetworkManager` 模块（缓存，但未就绪时不缓存 null）。
- 改写 `_ensureSendAsync()`：`window.ws.sendAsync(req)` → `NetworkManager.sendAsync(req)`。
- **拿不到 NetworkManager 时明确 reject**，绝不退回「写裸 socket」——那比不工作更糟，
  可能打断整条连接。
- 删除因此失效的 `_encodeRequest` / `_sendAsyncOnce`（净删 3.8 KB）。

## 验证

新增 `workspace/test_sendasync_network.js`（7 项断言，全 PASS）：

| 断言 | 结果 |
|---|---|
| ① 抓到的游戏 socket 被补了 `sendAsync` | PASS |
| ② `sendAsync` 转发给游戏 `NetworkManager` | PASS |
| ②b 入参原样透传（`cmd` / `params`） | PASS |
| ③ **裸 socket 全程没收到 JSON**（协议没被写坏） | PASS |
| ④ NetworkManager 未就绪时明确 reject | PASS |
| ④b 此时也没往裸 socket 写任何东西 | PASS |
| ⑤ 回包原样透传 | PASS |

另两项回归同时通过：`__require` 不变量 6/6、原脚本挂载（悬浮球出现）。
构建指纹 bump 到 `2026-09-16.7`。

## 顺手查清的两件事

1. **模块表键是「basename」**（含带引号的键），`index-ui` / `manager-factory` 确实存在于
   `game` bundle（各 1308 / 74 处字符串引用）；脚本要的 `Configs` / `ServerData` /
   `GlobalSignal` / `ModuleManager` / `BattleUIManager` / `MainPanel` 也都在。
   只有 `data-index` / `battle-data` / `decimal-number` / `launcher-server` / `comp-lord`
   在 `game` 与 `launcher` 里找不到 —— 脚本对这几个本来就有 `safeCall` 兜底与多候选名回退。
2. **资源型 bundle 的 `index.js` 是空 loader 骨架**（670 字节，`})({}, {}, [])`，
   没有任何模块）。全部 6534 个模块都在 `game`（16 MB）与 `launcher` 里。
   → 排查模块问题时不要被那些小文件误导。

---

# v9：排查提示 —— 「能运行但没效果」先看场景有没有进过

实机确认：v8 的修复有效。同时确认了另一条**非宿主问题**的原因，值得单独记一笔。

## 结论

这类脚本（用 `__require` + `NetworkManager` 操作游戏内部模块的）**必须先进入对应场景 / 玩法**，
相关 bundle 下载并按需加载之后才会生效。

**冷缓存下的表现就是「脚本能运行、面板正常、但没有效果」** —— 这不是宿主兼容问题。
典型触发方式：先进一次目标玩法（让它的 bundle 落盘），再回来用脚本。

## 为什么

- 游戏的 bundle 是**按需下载**的：本地只预热了 `launcher` / `game` / `TEST_REMOTE_MODULE`
  这几个核心 bundle（`LobbyConfiguration.coreBundles`），其余（`ui_*` / `map_*` / `battle*` …）
  在进入对应场景时才拉取。
- 缓存位置：`~/Library/Application Support/GameLobby/CDN/`
  （`index.json` 是 URL → 缓存路径的索引，`files/<shard>/<hash>` 是内容）。
- 脚本要的模块如果用 `Runtime.require` 取不到，它内部是 `Utils.safeCall` 兜底 + 写进自己的
  诊断面板（`pushDataSource`），**不会抛错** —— 所以看起来"运行正常但没效果"。
- 顺带印证了另一条观察：**资源型 bundle 的 `index.js` 是空 loader 骨架**
  （670 字节的 `})({}, {}, [])`，零个模块），全部 6534 个模块都在 `game`(16 MB) + `launcher` 里。
  排查模块问题时不要被那些小文件误导。

## 排查顺序（建议固化成习惯）

1. **先确认跑的是哪一版**：启动第一行 `[lobby] build 2026-09-16.7 | …`。
2. **再确认场景进过**：目标玩法是否至少进去过一次（bundle 是否已落盘）。
3. **然后看脚本自己的诊断面板**：`pushDataSource('… 不可用 …')` 那些条目会指出缺什么。
4. 最后才怀疑宿主侧契约（`__require` / `NetworkManager.sendAsync` / `window.ROLE` / socket 别名）。
