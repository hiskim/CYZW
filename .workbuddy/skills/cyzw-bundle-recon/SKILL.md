---
name: cyzw-bundle-recon
description: 反解 CYZW/xyzw（小y游戏大厅）线上加密 bundle，拿到游戏 UI 的真实结构（FairyGUI 节点名、控制器、生命周期），并据此为 macOS 大厅实现「游戏加强」项，最后用假环境跑行为测试。当需要知道某个游戏面板的节点/控制器/生命周期、要改游戏 UI 的布局或显隐、或要在 LobbyCoreSystem 里新增一项游戏加强时使用。
agent_created: true
---

# CYZW 线上 bundle 反解 → 游戏加强落地

游戏侧代码不在仓库里，只有 CDN 上的 **XXTEA 密文**。所以任何「改游戏 UI」的需求，
第一步都是**反解 bundle 取证**，不许靠猜节点名。

## 0. 前置事实（别搞错）

- 权威拷贝 `/Users/gg/915/CYZW`。`~/WorkBuddy/Worktrees/CYZW/*` 是历史分叉，不要动。
- 密钥 `0Aed5E79bbEa69f8`，解密实现 `ios-cocos/cocos-project/src/ios2-web-boot.js`
  的 `decryptJSC`（≈1003 行），同密钥也在 `frameworks/runtime-src/Classes/AppDelegate.cpp`
  的 `jsb_set_xxtea_key`。
- CDN 本地缓存 `~/Library/Application Support/GameLobby/CDN/`，
  `index.json` 是 `URL -> {path, byteCount}` 索引，`files/<2位>/<sha256>` 是内容。
- 命令行 `grep` 用 **`-E`**（BSD BRE 不支持 `\|`，会恒无匹配、误判成「没改动」）。

## 1. 解出明文 bundle

```bash
NODE=/Users/gg/.workbuddy/binaries/node/versions/22.22.2-2/bin/node
# 取 game bundle 的缓存路径
python3 - <<'PY'
import json,os
d=json.load(open(os.path.expanduser('~/Library/Application Support/GameLobby/CDN/index.json')))
for k,v in d.items():
    if '/remote/game/' in k or '/remote/launcher/' in k:
        print(v['byteCount'], os.path.expanduser('~/Library/Application Support/GameLobby/CDN/files/')+v['path'], k)
PY
# 解密（脚本见 scripts/decrypt-bundle.mjs）
$NODE scripts/decrypt-bundle.mjs <密文路径> /tmp/recon/game.js
```
成功标志：输出以 `window.__require=function` 开头（launcher bundle 同理，875 KB 更好读）。

## 2. 抽取目标模块

Cocos Creator 的模块题头形如 `ChatPanel:[function(e,t,i){…`，**以 `cc._RF.pop()` 结尾**：

```python
s = open('/tmp/recon/game.js', encoding='utf-8', errors='replace').read()
idx  = s.find('ChatPanel:[function(')          # 或先做 getChild 反查定位
end  = s.find('cc._RF.pop()', idx)
open('/tmp/recon/mod.js','w').write(s[idx:end+12])
```

定位技巧：
- 找模块名先看注册名：`grep -oE '"[^"]{0,40}ChatPanel[^"]{0,40}"'`。
- 想找「哪个面板有 `chatList` 子节点」，直接搜 `getChild("chatList")` 反查模块。
- 一个 UI 通常是**两个模块**：控制器（如 `ChatPanel`，导出 `NewChatPanel` 类，
  实例上有 `.ui` / `.model` / `hide()`）+ 生成基类（如 `UI_NewChatPanel`，extends
  `fgui.GComponent`，在 `onConstruct` 里 `getChild(...)` / `getController(...)`）。
  **成员名 `<->` 节点名的对照表就在生成基类的 `onConstruct` 里，这是最可靠的一手证据。**

## 3. 读结构，别猜

必读三样：
1. `onConstruct` 的 `getChild("…")` / `getController("…")` —— 节点名与控制器名。
2. 控制器的 `selectedPage` 取值（例如 `inputCompState` 的 `show`/`emoji`/`hide`）。
3. 定位类里的 `fixScene()` / `onShow` —— **面板位置由谁决定**。
   如果父容器高度是由别的面板（如 `HomeScene.ui.m_under.y - 127`）算出来的，
   那么把面板 `visible=false` 不会连带改坏排版，可以放心隐藏。
4. **框架会给窗口套一层 skin 外壳——要隐藏的是外壳，不是内容组件。**
   `UIManager` 的 `UIProxy._addUI` / `_setSkin`：

   ```
   parentUI(层) → skinUI(metadata.skin，如 UI_CommonDialogSkin：m_biaotou/m_container/m_bkmask)
                → …FguiUtil.getDeepChild(skin, ConstName.Container)… → ui(内容组件)
   ```

   同时 `(i.proxy = this).skinUI = i`、`(this.ui.proxy = this)`：**两层 proxy 是同一个控制器**。
   `@I.ui({ui, layer})` 装饰器里 `i.skin || (i.skin = t.skin)` 会**从基类继承 skin**，
   所以哪怕模块自己没写 `skin`（聊天面板就是这样），`this.skinUI` 照样存在
   （游戏代码里 `this.skinUI.m_container.height = …` 是不加保护的，可作二证）。
   > 只压 `ui` 的表现是「**外壳还在、里面空了**」——第一版就是这么翻车的。

   解析外壳的写法：从 `ui` 沿 `parent` 上溯，取「proxy 与 ui 相同的**最高**祖先」；
   再往上是层 / 父窗口，proxy 不同会自然停住。没有 skin 的窗口结果就是 `ui` 自己。
   「我们动手前它是否显示着」也要以**外壳**为准（框架隐藏窗口压的是外壳，ui 可能一直是 true）。

5. **拿 fgui 对象的两条独立路径（别只写一条）。**
   - `fgui.GRoot.inst` 是**会抛异常的 getter**：
     `get: function(){ if (D._inst) return D._inst; throw "Call GRoot.create first!" }`。
     写成 `fgui.GRoot && fgui.GRoot.inst` 时，一次 throw 会把**整段**逻辑吃掉（外面套着
     `try{}catch{}` 就成了静默的「找不到」）。正确姿势：先摸 `fgui.GRoot._inst`，
     再单独 try 一次 getter。
   - 兜底路径：**cc 场景遍历 + `node.$gobj`**。fgui 在每个 cc.Node 上挂了 `$gobj` 回指 fgui 对象
     （游戏代码里 `e.currentTarget.$gobj` 就是这么用的），完全不依赖 `GRoot`。
   两条都试、都不命中时才报「没有面板」，并在诊断串里写明命中的是哪条（`root=groot|scene`）
   以及是「连根都没有」(`no-root`) 还是「有根没面板」(`no-panel`)。

## 3.5 读**数据**（不是 UI）：找字段的真实出处

需求常常是「把某个游戏数据拿到宿主用」（例：账号卡要显示真实头像 → 要 `ROLE.headImg`）。
同样是取证，不猜字段名。三步：

1. **数次数，定范围**：`s.count('headImg')` 之类先看规模（本例 528 次，太多不能肉眼扫）。
2. **枚举唯一上下文**（最有效的一招）——同一字段的 528 次命中其实只有 ~20 种周边，
   归纳出来就能一眼看出「谁是权威定义、谁是消费者」：

   ```python
   import re, collections
   s = open('/tmp/recon/game.js', encoding='utf-8', errors='replace').read()
   ctx = collections.Counter()
   for m in re.finditer('headImg', s):
       ctx[s[max(0,m.start()-90):m.end()+90]] += 1
   for k, v in ctx.most_common(30): print(v, repr(k))
   ```

3. **找「挂到全局」的那一处**：数据类模块的权威写法是
   `globalThis.X = …`（同一段里通常还有 `X = SERVER_DATA.x` 与 `clearX()`）。
   搜 `\.ROLE\s*=` 定位到 `ServerData` 模块：

   ```
   createServerData=function(){… i.SERVER_DATA=new c; i.ROLE=i.SERVER_DATA.role;
     globalThis.SERVER_DATA=…; globalThis.ROLE=i.ROLE; …}
   ```

   → **`window.ROLE` 是游戏自己挂的**，宿主的注入脚本直接读即可。
   再搜 `模块名:\[function` 找到数据视图类（如 `RoleDataView`），
   末尾的 `t.decorate(n,{headImg:t.observable,name:t.observable,power:…})`
   就是**可用字段的完整清单**（mobx observable），比逐个猜名字快得多。

4. **外部资源型字段要单独试 URL 变体**。头像/图标这类字段是 URL，
   末段往往是尺寸参数：`thirdwx.qlogo.cn/…/132` 里 `/0`=原图(1080)、`/46 /64 /96 /132`
   都可用、`/640` 返回 400。用 `curl -o /dev/null -w '%{http_code} %{size_download}'` 逐个试，
   并确认**直连不需要 cookie**（qlogo 实测 200）。别把「游戏内能显示」当成「宿主能下载」。

> 反例提醒：本例的 `ROLE.headImg` 与第三方脚本宿主那份笔记不冲突——
> 游戏 WebRuntime 里有 `window.ROLE`；`IOS2ScriptWebView` 那个独立脚本宿主里没有，
> 靠兼容层 `__ios2ReadRole()` 从 `__require('ServerData').ROLE` 补。
> **两套宿主别混为一谈。**

## 4. 落地「游戏加强」项（六步固定接法）

| 步骤 | 文件 |
|---|---|
| 1 偏好键 | `LobbyDomain/LobbyConfiguration.swift` 的 `PreferenceKey` |
| 2 设置快照 + 存储 | `LobbyEngine/GameEnhancementStore.swift`（新字段给默认值；`@Published` + `didSet` 落盘） |
| 3 页面代理 | `LobbyEngine/GameEnhancementScript.swift`（`agent` 字符串 + `apply()` + `status()`） |
| 4 下发 | `LobbyEngine/GameViewportInstance.applyEnhancements()`（`didFinish` 时补一次） |
| 5 唯一写入口 | `LobbyUI/LobbySessionModel.setXxx()`（落盘 + `broadcastEnhancements()`） |
| 6 UI | `LobbyUI/GameEnhancementSectionView.swift`（用私有 `rowCard`/`rowHeader`/`statusLine`） |

**改完 bump `App/Sources/GameLobbyApp.swift` 的 `buildTag`**，否则日志里分不清跑的是哪一版。

代理脚本的红线：
- 必须 `atDocumentStart` **预注入**（WKUserScript 运行时无法追加）——否则「实例已跑起来才开开关」= 点了没反应。
- 只读 `window.__require`，**绝不包装**（会断父子 require 链 → 卡加载场景）。
- 模块可能还没加载 → 用**有界轮询**（如 500ms × 120），并给降级 note。
- 「关」态必须能**完全还原**（记原始值），并保证**幂等**（哨兵 `window.__LOBBY_ENHANCE__`）。
- 频繁重设的属性用**缓存 + 定时重写**，不要每拍遍历 `fgui.GRoot.inst`（找不到时降频到秒级）。
- 能挂生命周期钩子（`prototype.onShow`）就挂，消除「先闪一下再被压回」。
- 显隐类加强项：**压外壳**（见第 3 节第 4 条），并且在 `status()` 里带上
  `skin=N/M`、`root=groot|scene|no-panel|no-root` 这类结构诊断——下次出问题一眼能看出是
  「没找到」还是「找错了层」。
- **把诊断串送回原生侧并显示在大厅设置页上**（`GameEnhancementStore.notePageReport` →
  `GameEnhancementSectionView` 的 `pageReportLine`）。只写日志时，用户实测「没生效」
  你只能靠捞日志定性；截个图就能分诊，省掉一整轮来回。
  注意 `evaluateJavaScript` 的 completion 是 `@escaping`，闭包里别捕获 `self`，先取出需要的值。

## 4.5 不生效时：先上结构探针，别继续推理

实测反馈「没生效」而你已经改过一轮时，**停手，别再靠读 bundle 推理**——写一个探针把
运行时真实结构一次性报回来。探针要有这几项（`cyzw` 里叫 `probeChat()`，挂在
`window.__LOBBY_ENHANCE__.probe()`，并在 `status()` 里「开着隐藏但零命中」时自动附上）：

- `roots=` 拿到几个根；`walk=` 遍历了多少 fgui 节点；`hit=` 命中几个
- `mark=a/b/c/d` 指纹**每个条件**各自命中的对象数（区分「指纹太严」和「压根没有」）
- `near=` 2–3 个「差一点命中」的对象，形如 `ChatItem:--MM`
  （M = 成员变量命中，C = getChild 命中，- = 没有）——**这条信息量最大**
- `tops=` 根的前 6 个子节点名（看清层结构）
- `inv` **界面清单**：`GRoot → Layers → 各层容器 → 窗口`，形如
  `inv L=7 #3:3(HomeScene,MainUI,...)`；外加遍历中收集的**名字带 chat 的对象**。
  它回答的是「屏幕上到底有什么」——命中 0 时先看它，比继续猜结构快得多。
- `cc=<节点数>/<gobj 数>`：第二条路径的可达性证据
- `mod=` `__require('模块名')` 是否可用
- `env` 环境位：`fgui/groot/inst/cc/scene/req/game/top/canvas` + `rs/href`。
  `canvas=1` 而 `fgui=0` ⇒ 同文档但没加载完；两个都 0 ⇒ 根本不是同一个 window。
  实测 `didFinish` 时必然全 0，页面上报「启动沉降完成」之后才齐。

**指纹别只写一种，而且要先确认「你要改的那个 UI 到底有几个」。**
本项目最惨的一次：按 `ui_chat/NewChatPanel`（`ui://r6ibbv0plmbho`）的成员变量写了指纹，
注释里还写着「离线可查、别再猜」，结果用户在主城怎么都不生效——**主城那个聊天框其实是
`ui_main/MainPanelChat`（`ui://8fweejrdlmbhm`），成员是 `m_chatItemList`/`m_redDot`**，
两者成员变量毫无交集。所以判据要**分层**：
1. 成员变量 / `getChild(...)`（最精确，但依赖 `onConstruct` 跑过）；
2. **元数据**：`object.packageItem.name` / `object.constructor.URL`（不依赖构造流程）；
3. **特征成员**：某个只有目标 UI 才有的成员名（如 `m_chatItemList`）。

找「同族 UI」的方法：搜所有 `UI_*<关键词>*` 生成类，**看它们的 `PackageURI`**——
同一个功能常常在不同包里各有一份（主城 / 天战 / 军团各一套）。

**改显隐还有两个「压不住」的来源（都会表现为「先闪一下」）：**
1. `onConstruct()` 是构造流程的**最后一步**（`_underConstruct=false`、`applyAllControllers()`、
   `tt()` 之后）——在它之前写 `visible` 会被 `tt()` 覆盖；
2. **fgui 有对象池**，复用组件时 `GObjectPool.getObject()` /
   `UIObjectFactory.newObject()` 的池分支会调
   `resetVisible()` → `this.node.active=true; this._internalVisible=true; this.visible=true`，
   **把隐藏状态直接抹掉**。

对策：把守门挂到**生成类的原型**上（`prototype.onConstruct` + `prototype.resetVisible`，
调用原实现后立刻压回），同一帧内完成，屏幕上没有中间态。
⚠️ **只对有静态 `URL` 的生成类挂**——否则 `panel.constructor.prototype` 可能就是
`fgui.GComponent.prototype`，会把守门挂到所有组件上。
安装两条路：按模块名预先挂（`cc._RF.push(...,"UI_MainPanelChat")` 的模块名就是类名，
第一次进场景就已守住）+ 巡检扫到实例时按 `instance.constructor.URL` 补挂。
另外「缓存的外壳」要**每拍重新解析**（skin 是框架在 `_addUI` 里后补的，
构造那一刻还没有父链），缓存失效时把重扫间隔降到下一拍。

**让诊断串自己带代理版本号**（`v=N`，每次改 agent +1）。痛过三轮「你确定重建了吗」，
这一行就能一锤定音。同时把「未落实时的重试」做成两档：快档 3s×20 修时序，
慢档 15s×60 只为**让界面回执保持活着**，用户能自己看着状态变化。

**周期快照的上限别设太小。** 踩过：上限（20 条）用完之后用户才打开目标窗口，
正好错过关键那一条。留 60 条 ≈ 15min。

配套：**诊断串要同时 (a) 写日志（统一前缀如 `[enhance]` 便于筛）、(b) 回传原生侧显示在
设置页上**。只写日志时用户只能说「没生效」，你只能反复要日志；有了界面回执 + 探针，
一轮就能定性。

> 同类教训：`UIManager.getLayer(e)` 是 `this._layers[e] || this._root`，而层的填充来自
> `Layers` 窗口的 `_setLayer`（`this.ui.getChild(层号)`）——**层不一定是 GRoot 的直接子节点**。
> 所以「遍历 GRoot 一定找得到」是个不该有的假设。
>
> **另一个必踩的坑：「文档就绪」≠「游戏就绪」。** WebView 的 `didFinish` 只是文档加载完，
> 此时 `window.__require` / `window.fgui` **都还不存在**（game bundle 还没跑），
> 那一刻下发必然空转。可靠时机是页面上报的「启动沉降完成」（本项目是 `PageEvent.ready`）。
> 所以：① 在 ready 时补一次下发；② 原生侧做**确认式重试**（回执没落实就每 3s 重发，
> `apply` 幂等，最多 ~60s）；③ 让页面在「一直没命中」时每 15s 打一条结构快照到 console
> （经 console 桥回传成原生日志），这样能看到**加载完成后**的真实状态。
> 探针里的 `env` 位（`fgui/groot/inst/cc/scene/req/game/top/canvas`）用来分辨
> 「同一文档但没加载完」和「根本不在同一个 window」。

**「压时机」永远压不完 —— 要接管属性写入本身。**
逐个时机去补（构造 `onConstruct`、对象池 `resetVisible`、定时巡检）最后还是会闪，因为
**游戏自己也在写**：本项目主城面板刷新函数里就有一句
`t.m_chat.visible = e.isModuleVisible(H.ModuleType.CHAT)`（game.js @6972079），恒真，
每次刷新都点亮一次。正解是在**生成类的原型**上接管 `visible` 的访问器：

```js
// fgui：Object.defineProperty(GObject.prototype,"visible",
//        { get(){return this._visible}, set(e){ this.setVisible(e) } })   // configurable:true
// setVisible → handleVisibleChanged → this._node.active = this._finalVisible
const d = Object.getOwnPropertyDescriptor(寻找原型链上的 'visible');
Object.defineProperty(klass.prototype, 'visible', {
  configurable: true,
  get() { return d.get.call(this); },
  set(v) { d.set.call(this, hidden ? false : v); }   // 隐藏态一律削成 false
});
// 顺手把 setVisible 也包一层（GLoader.visible 那类直接调 setVisible）
```
这样构造、复用、游戏刷新、框架内部……**所有**写入路径一次性覆盖，`node.active` 自然为 false。
⚠️ 前提与红线：① 只对**有静态 `URL` 的生成类**下手（否则会改到 `fgui.GComponent.prototype`，
影响游戏里每个组件）；② descriptor 必须 `configurable: true`；③ `get` 要返回真实值，别撒谎。

**挂钩要抢在那段同步流程前面。**「下载包 → 建窗口 → 刷新」常常是一段同步代码，
250ms 巡检插不进去；用一个 50ms 的快速轮询只做 `__require`（模块表查找，代价可忽略），
挂上即停（上限 ~60s）。

## 5. 验证（两步都不能省）

```bash
# A. 把 agent 字符串导出成真 JS 再查语法（不能只靠肉眼）
cd /tmp/recon && cat > main.swift <<'EOF'
import Foundation
print(GameEnhancementScript.agent)
EOF
xcrun swiftc -o agent_dump /Users/gg/915/CYZW/LobbyCoreSystem/Sources/LobbyEngine/GameEnhancementScript.swift main.swift
./agent_dump > agent.js && $NODE --check agent.js

# B. 假游戏环境跑行为（fake fgui.GRoot + fake __require，见 scripts/agent-harness.mjs 模板）
$NODE harness.mjs

# C. 真编译
cd /Users/gg/915/CYZW/LobbyCoreSystem && \
  xcodebuild -project GameLobby.xcodeproj -scheme GameLobby -configuration Debug \
             -destination 'platform=macOS' -derivedDataPath /tmp/recon/DD build
```
注意：`node --check` **查不出**语义错误（例如把语句写成一个合法字符串表达式），
所以 B 步不能跳。假环境**必须按真实层级搭**（层 → skin → container → ui），
否则测不出「压错层」这类 bug。至少覆盖：关态不干扰 / **开态压的是外壳** /
游戏重设后被压回 / 钩子零闪烁且原始逻辑仍执行 / 还原只放回原本可见的（以外壳为准）/
缺 `__require` 与缺 `GRoot` 都不抛错 / 无 skin 的窗口退化为压 ui / 与其他加强并存 / 重复下发幂等。

> 经验：先把**旧版** agent 拿去跑新测试，能复现真实故障（这里是「外壳还在」）才算测试有效；
> 否则只是自我感觉良好。

### 5.1 导出 agent 字符串的两个细节（踩过）

`agent` 是 Swift 多行字符串，里面有 `\(插值)`。直接 `print` 得到的是**运行时文本**，
但要喂给 node 通常是在不能编译整个工程的场合做的，于是常用「Python 抽 `"""…"""` 再正则替换插值」：

```python
js = re.findall(r'return """\n(.*?)\n        """', src, re.S)[0]
values = {'agentVersion': '1', 'channel': 'ios2Game', 'fastIntervalMs': '400'}
js = re.sub(r'\\\((\w+)\)', lambda m: values[m.group(1)], js)   # ⚠️ 必须全替换
open('agent.js','w').write(js)
```

- **所有**插值都要在 `values` 里，漏一个就会在 JS 里留下 `\(x)` —— 那是**语法错误**，
  但 `node --check` 的报错位置会指到你没想到的行。
- 抽完先 `assert '\\(' not in js`，这一步比看报错快。

### 5.2 测「等时间」的逻辑：用虚拟时钟，别真 sleep

轮询类 agent（等 `__require` / 等 `window.ROLE`）的关键行为是「400ms 拍 N 次后降频」，
真等要几分钟。用一个受控的假 `setInterval`：

```js
const timers = new Map(); let nextId = 1; const clock = { now: 0 };
sandbox.setInterval = (fn, ms) => { const id = nextId++; timers.set(id, { fn, ms }); return id; };
sandbox.clearInterval = (id) => timers.delete(id);
const advance = (ms) => { for (let e = 0; e < ms; e += 50) { clock.now += 50;
  for (const [, t] of [...timers]) { t.next ??= clock.now + t.ms;
    if (clock.now >= t.next) { t.next = clock.now + t.ms; t.fn(); } } } };
```
配合 `node:vm` 起的 `window`（含 `webkit.messageHandlers` 假桥）就能在毫秒内跑完几分钟的行为。
必测项：未就绪不上报 / **重复注入被哨兵挡住**（并断言没有新定时器）/
值不变不重复上报 / 值变后补报 / 兜底路径（`__require`）/ **桥抛异常时不提交去重键**
（先提交再投递的写法会让这条资料永远发不出去，且重启也不好——这是真实踩到的坑）。

### 5.3 单测一个依赖工程内模块的 Swift 文件

没有测试 target，又不想为了测一个 store 去搭整套依赖时，用「**剥 import + 补桩**」：

```bash
mkdir -p /tmp/t && python3 - <<'PY'
src = open('…/LobbyEngine/AccountAvatarStore.swift', encoding='utf-8').read()
out = [l for l in src.split('\n') if l.strip() not in ('import LobbyDomain', 'import LobbyIPC')]
open('/tmp/t/Store.swift','w',encoding='utf-8').write('\n'.join(out))
PY
# Stubs.swift：补 LobbyLog / LobbyConfiguration / 上报结构（⚠️ 要 public，
# 否则「default 参数里引用 internal 常量」直接编译失败）
# 骨架见 scripts/swift-isolated-test.template.swift
xcrun swiftc -O -o t/run Stubs.swift Store.swift TestMain.swift -framework AppKit && t/run
```
- 主文件**不能叫 `main.swift`**（会与 `@main` 冲突），改叫 `TestMain.swift`。
- `@main struct T { @MainActor static func main() async throws { … } }` 就能直接
  `await` MainActor 隔离的 store，并用 `try await Task.sleep` 等异步下载落地。
- 这样能跑**真网络**的真实资源（本例用用户抓包的头像链接验证了「末段尺寸归一化」：
  原始 `/132` 落到 4KB / 132×132，而不是 1080px 原图）。
- ⚠️ 被剥离的 import 只影响符号可见性，**业务逻辑一字未改**——别顺手改逻辑，
  否则测的就不是产品代码了。

> 同类检查：SwiftUI 的 `body` 里**绝不允许**有会写 `@Published` 的调用
> （「懒加载 + 顺手清死引用」就是典型）。IO/状态变更一律挪到 init 或定时节拍里。

### 5.4 宽度/字号类 UI 改动：先量，再改，再复算

「文字被截断」这类问题**凭感觉调字号/缩写一定会反复翻车**（只有在位数够长的那个
账号上才暴露，肉眼试不出来）。做法是把「可用宽度」写成算式，用**真实字体**量候选字符串：

```swift
let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
func w(_ s: String) -> Double { Double((s as NSString).size(withAttributes: [.font: font]).width) }
```

- **可用宽度 = 容器宽 − 各级 padding − 同级子视图 − 间距**。侧栏那种「固定宽 + 卡片」
  的结构一定要把每一层 padding、每个按钮、每个 `HStack(spacing:)` 都算进去，
  差 8pt 就是「显示 `…`」和「显示完整」的差别。
- 先量出最窄状态（示例里：卡片「运行中」时会多出一个胶囊，可用宽度从 134pt 掉到 74pt），
  **按最窄状态设计退让档位**，而不是按最好的情况。
- 退让档位写成 `ViewThatFits(in: .horizontal)` 的候选链，顺序是
  **先换行、后丢项、最后不显示**——宁可多占一行高度，也不出一个半截数字。
- 把算式固化成脚本（示例：`LobbyCoreSystem/Scripts/stats-width-probe.sh`），
  并且**从源码里抽取真的格式化函数**（正则抓出 `private static func` 再编译），
  不要抄一份——抄的那份一定会和产品代码漂移。
- ⚠️ 无关但会浪费半小时的坑：Swift 里一长串裸字面量运算（`304.0 - 32 - 20 - …`）
  会触发 "unable to type-check this expression in reasonable time"，**全部显式标 `Double`**；
  带 `@main` 的文件**不能叫 `main.swift`**，反过来顶层代码的那个文件**必须**叫 `main.swift`。

### 5.5 构建脚本别写批量 `rm -rf`

`PhaseScriptExecution failed` 但 Swift 一点没错时，先看构建脚本的输出里有没有
`[safe-delete][SAFE_DELETE_BULK_CONFIRM_REQUIRED] {"count":N,"threshold":50,…}`——
本机沙箱对「单次删除超过 50 个文件」有确认门闸，**沙箱内和免沙箱都拦**，
所以「整目录 `rm -rf` 重建」的写法会稳定失败。
改法：拷完后按**期望清单**做差集，只删真的残留（`comm -23 actual expected`），
意图不变、更精确、正常情况下 0 删除。
另：**不要并发跑两个 build**（两份构建都去 `rm -rf` 同一个输出目录，会互相踩）。

## 6. 别忘

- 第三方脚本（`~/Downloads/*.js`、脚本库里的）**不可修改**，只能读来学机制。
- 需求若来自某个第三方脚本，说明里要写清「参考了什么、落到宿主哪一层」。
- 写完追加 `.workbuddy/memory/YYYY-MM-DD.md`（含反解偏移量等可复现证据）。
