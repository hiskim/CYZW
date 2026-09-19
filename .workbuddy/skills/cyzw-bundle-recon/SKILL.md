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
- 查**产物里有没有某段代码**：`strings -a <二进制> | grep` 只对 ASCII 可靠，
  **中文字面量要用 `grep -c -a -- "中文" <二进制>`**（`strings` 把非 ASCII 当不可打印，
  会让「明明编进去了」显示成 0 条，白查半天）。Debug 的代码在
  `Contents/MacOS/潮音之王.debug.dylib`，不是 40KB 的主二进制。
- **要找「某功能是怎么实现的」时，先在官方 APK 运行时里找，别从零猜**：
  `~/Library/Application Support/RemoteRuntime/*/assets/game/` 下有整套内置脚本
  （`native-game-host.js` = 宿主侧：引擎加速 / 帧率 / 断线重连 / 盐场视野；`builtin-*-apk.js`
  = 各功能脚本）。`builtin-ten-temple-speed-apk.js` 之类往往是小号版的答案。
  ⚠️ 注意 `assets/game/assets/` 只是 Cocos 资源仓（`internal/index.js` + 散装资源），
  **JS 脚本都在上一层 `assets/game/` 根目录**，别在资源仓里翻。
- **战斗数据浮层（攻/盾/血/怒）的挂点与口径**（参考 `builtin-battle-stats-overlay-apk.js`，1201 行）：
  · 挂钩 `SystemHeadBoard.prototype._updateLifeAndRage(entity)`——游戏自己刷血条/怒气条的地方；
  · **借游戏的手拿组件**：包装 `entity.getComponent` **一个调用周期**，收集游戏自己要的组件
    （不猜类名、不遍历组件树）。这条模式在很多「我要知道属性/位置」的需求里都能复用；
  · 标签画在 `headBoard.boardDisplay.ui` 上，样式克隆 `headBoard.nameDisplay.ui.m_name`
    然后**把官方名字藏起来**（关掉时文本 + 可见性原样还回去）；
  · 数值口径：血 = life 组件 `current`（挑 `isInfinite()` 或 `max > 1000` 的那个）、
    怒 = 另一个 `current/max` 组件、盾 = 有 `getAllArmor()` 的组件、
    攻 = `comp-attributes` 候选键（`Configs.BattleAttributeKey` 的 ATTACK_FIGHTING /
    ATTACK_FINAL / BATTLE_ATTACK → 实体快照 `attack/atk` → `ATTACK_ABS`）；
  · ⚠️ 战斗模块**只在进战斗时加载**：装钩子必须降频轮询兜底（前 60s 每 500ms、之后每 5s），
    不能像十殿那样限时放弃，否则「先进战斗再开开关」就永远装不上；
  · 参考实现里另有 comp-attributes 写入观察者/影子层（回放态攻击值）、竞技场对手攻击预取
    （PVP 敌方攻击不在本地属性里）——不抄这两个，就要在 UI 上说明 `攻` 会显示 `--`。
- **玩家ID（显示 / 一键复制）的口径**（参考 `builtin-player-info-id-apk.js`）：
  · 玩家信息弹窗**本来就有** `m_playerid` / `m_btnCopyID` / `m_serverName`（外加
    `m_serverName.parent` 下那个分隔线 `n101`）——官方客户端把它们藏起来了。所以
    「显示 ID」= 把这几个节点放出来 + 填 `ID:<roleId>`，**不用自己画控件**；
  · 挂 `PlayerInfoDialog` / `PlayerInfoTopDialog` 的 `onShow` / `onShown` / `onFixShow`，
    且要在同一拍 + 0ms + 120ms 各同步一次（UI 有时晚于 `onShow` 才建好）；
  · roleId 出处：`dialog.model.get(ModelConst.ROLE_INFO | 'roleInfo' | 'ROLE_INFO')` → `dialog.roleInfo`
    （`consts.ModelConst.ROLE_INFO` 只是键名常量，取不到就用字符串键）；
  · 复制按钮要**先 `clearClick()` 再 `onClick()`**（官方那颗在 WebKit 上走平台桥，不干活）；
  · ⚠️ **复制必须由宿主写系统剪贴板**：页面 origin 是自定义 scheme（非安全上下文），
    `navigator.clipboard` 不可用。链路：页面 `{type:'clipboard'}` → `PageEvent.clipboardWrite`
    → `NSPasteboard`（长度封顶 256），页面再用 `TipsManager.SHOW_TIP` 飘字；兜底才是
    参考实现那套 `execCommand('copy')`。**这条通道以后复制别的东西也能复用**；
  · 弹窗类同样只在第一次打开时加载 → 降频轮询兜底（前 90s 每 1s、之后每 10s）。
- **游戏自己的 WebSocket 发帧形状（要发命令先抄这个，别自己发明 seq/ack）**：
  `socket.sendAsync({ ack: 0, cmd, params, seq: Date.now(), time: Date.now() })`
  ——出处 `builtin-salt-field-apk.js:533` 的 `sendReadCommand`，雪碧助手 `sendBattleCommand`
  同形（它的抓包版 `sendGameCommand` 也一样）。**ack 恒 0、seq 取时间戳**；若页面上有
  `g_utils.bon.encode`，就把 `params` 换成 `body = bon.encode(params)`。
  ① **别名只覆盖主连接**：`window.ws` / `h5websocket.ws` 指的是主连接；盐场战场是**第二条
  WebSocket**（URL 含 `e=x&sid2=`，见雪碧 `findBattleWebSocket` 注释），别名列表里根本没有它；
  ② 所以要发到战场连接，必须**按 sid 点名**（本项目的 `sendViaGameOnSocket`），
  ③ 也别自己算 seq 发原生帧：主连接历史查询当初就是因为「原生日发 seq 撞号被服务端静默丢弃」
  才改成走游戏封装的。
- **本机引擎的加速口径**（`ios-cocos/cocos-project/src/cocos2d-jsb.07adf.js`，如需「加速」类需求先读这一段）：
  `cc.Scheduler.update(t)` 开头 `1 !== this._timeScale && (t *= this._timeScale)`；
  `director.mainLoop` = `_compScheduler.updatePhase(dt)` → `_scheduler.update(dt)`；
  `ActionManager` / `AnimationManager` 在 `director.init()` 里 `scheduler.scheduleUpdate(…)`；
  FairyGUI 的 `TweenManager.update` 在 `createTween` 里 `scheduler.schedule(TweenManager.update, _root, 0, false)`。
  ⇒ `director.getScheduler().setTimeScale(n)` = **补间 / 动作 / 转场加速，组件 `update(dt)` 不加速**
  （官方 APK 的 `engineGlobalSpeed` 就是这个机制，默认档 3）。要「某个面板内部」的节奏才用
  `DEFAULT_TIMESCALE` 那种面板级钩子（十殿加速）。
- **帧率口径**（`src/ios2-web-cocos2d.js` + `src/ios2-web-boot.js`，问「帧率设置生效没有」时必读）：
  · 启动走注入对象：`__IOS2_GAME_INSTANCE__.frameRate` → `preferredFrameRate()` 白名单
    `[15,24,30,45,60,90,120]` → `cc.game.init({frameRate})`；
    `TargetFrameRate` 的档位必须与该白名单严格一致，白名单外会被静默回退 60。
  · 运行时改档走宿主 `applyFrameRate()`（pause → 等 `max(120ms, 3×帧长)` → 改
    `config.frameRate` + `_setAnimFrame()` + resume）；**别直接调 `cc.game.setFrameRate`**：
    它会 `_paused=true` 后立刻 `_runMainLoop()`，旧循环里排队的 setTimeout→rAF 回调还会跑完，
    `_paused` 被新循环置回 false → 旧循环复活 → 两条主循环并存（实测帧率冲到 2 倍）。
  · `_setAnimFrame()` 有两条分支，直接影响「帧率读数」与「rAF 语义」：
    非 30/60 档把**全局** `window.requestAnimationFrame` 换成 `_stTimeWithRAF`
    （setTimeout 计时后仍 rAF）→ 90/120 档受 vsync 封顶（60Hz 屏只有 60）；
    30 档是 `_runMainLoop` 里 `30 === a && (s = !s)` 的**隔帧跳过**（rAF 照跑，刷新率不变）。
    ⇒ **测帧率要数 `cc.director.mainLoop`，别数 rAF**（数 rAF 会把 30 读成 60）。
  · `PageEvent.frameRateWrite`（页面报「谁写了帧率」）目前**没有生产者**，是预留通道。

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
| 6 UI | `LobbyUI/GameEnhancementSectionView.swift`（用私有 `featureCard`/`rowHeader`/`statusLine`） |

**两个 bump 都要做**：`App/Sources/GameLobbyApp.swift` 的 `buildTag`（否则日志里分不清跑的是哪一版）
+ `GameEnhancementScript.agentVersion`（诊断串里的 `v=`，否则分不清页面里跑的是哪一代代理）。

UI 细节（踩过）：
- **入口按语义归属，别一律塞增强页**：纯「自检 / 读数」类开关（帧率角标）放在它**验证的对象**
  旁边（设置页「目标帧率」卡）；增强页只留改游戏行为的项。这是用户明确提过的偏好。
- 想要**实时读数**就得自己拉：页面回执只在 `apply` 那一刻刷新，下发 settle 之后不再变
  → 视图里读 `lastPageReport` 会永远停在旧值。做法：加一个只取状态、不改配置的诊断入口
  （`GameViewportInstance.refreshEnhancementReport()` → `LobbySessionModel.refreshEnhancementReports()`），
  由视图 `.task(id:)` 在「功能开着 + 页面可见」时按 2s 驱动——离开即取消，不留空闲轮询。
- 多实例的读数按**账号**分桶存（只留最后一个会在几路之间跳）；值没变就别写 `@Published`，
  否则每拍触发一次重绘。
- 倍率行别逐项复制，抽成共用 helper（现为 `speedRow(…)` / `quickSpeedButton(…)`）——两个功能
  各自的输入框样式必须同源，否则改圆角 / 宽度必漏一个。
- **小数倍率输入框：结尾是小数点时不许写档**。中间态 `1.` 会被 `Double("1.")=1` 解析并回写，
  把小数点吞掉，用户永远打不出 `1.5`（整数倍率那套「输入即钳制」的写法不能照抄）。
- 读 `Double` 偏好键必须 `object(forKey:) as? Double ?? 默认`，**不能用 `double(forKey:)`**
  ——缺省键返回 0，钳制后变下界 1，表现是「默认档静默变 1（等于没开）」。

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
# ⚠️ 该文件现在有 `import LobbyDomain`，隔离编译要剥掉并补个同名桩
#    （只补 webChannelName 这类稳定契约，别补业务）：
python3 - <<'PY'
src = open('/Users/gg/915/CYZW/LobbyCoreSystem/Sources/LobbyEngine/GameEnhancementScript.swift', encoding='utf-8').read()
src = src.replace('import LobbyDomain',
                  'public enum LobbyConfiguration { public static let webChannelName = "ios2Game" }')
open('/tmp/recon/Agent.swift', 'w', encoding='utf-8').write(src)
PY
xcrun swiftc -Xfrontend -disable-sandbox -o agent_dump Agent.swift main.swift
./agent_dump > agent.js && $NODE --check agent.js
grep -nE "const (AGENT_VERSION|PID_CHANNEL)" agent.js     # ← 顺带核对插值真的进去了

# B. 假游戏环境跑行为（fake fgui.GRoot + fake __require，见 scripts/agent-harness.mjs 模板）
$NODE harness.mjs

# B'. 改**引擎全局状态 / 读引擎节奏**的功能（时间倍率、帧率角标、director 包装）改用：
AGENT_JS=/tmp/recon/agent.js $NODE scripts/engine-speed-harness.mjs
#     该模板自带可控时钟（`Date.now` 可推）+ 假 `cc.game/director`（含 mainLoop 计数），
#     帧率类断言就是「敲 N 次 mainLoop + 推 1s → 读角标文案」。

# B''. 战斗内功能（战斗数据浮层）用 scripts/battle-stats-harness.mjs：
AGENT_JS=/tmp/recon/agent.js $NODE scripts/battle-stats-harness.mjs
#     ⚠️ 假 `_updateLifeAndRage` 必须**真的去调 `entity.getComponent`**——代理是借游戏
#     自己的组件查询来收集组件的，假 update 不查就整条捕获路径都测不到（测了个寂寞）。

# B'''. 弹窗类功能（玩家ID 显示/复制）用 scripts/player-id-harness.mjs：
AGENT_JS=/tmp/recon/agent.js $NODE scripts/player-id-harness.mjs
#     假弹窗给全 onShow/onShown/onFixShow + ui.m_playerid/m_btnCopyID（**初始隐藏**，
#     官方客户端就是这样）+ 假 `webkit.messageHandlers.<channel>`，断言「复制真的落到了宿主」。

# B''''. 改**页面代理 / 抓包**（PacketCaptureScript）用 scripts/packet-agent-harness.mjs：
EXPECT_VERSION=5 AGENT_JS=/tmp/recon/agent.js $NODE scripts/packet-agent-harness.mjs
#     假 WebSocket（主连接 + 含 `e=x&sid2=` 的战场连接）+ 假 `g_utils.bon.encode`，
#     断言：sid 登记、`sendViaGameOnSocket` **定向到战场那条**、请求形状 `{ack:0, seq:时间戳}`、
#     回执里的 Map 被 `sanitize` 摊平、以及三个失败串（`no-such-socket` /
#     `socket-has-no-sendAsync` / `sendAsync-threw`）——宿主正是靠这三个串决定要不要降级。

# B'''''. 改**键鼠同步代理**（InputSyncScript）用 scripts/sync-agent-harness.mjs：
AGENT_JS=/tmp/recon/agent.js $NODE scripts/sync-agent-harness.mjs
#     假 DOM（window 捕获 / canvas / window 冒泡的**真实派发顺序** + elementFromPoint 可控）
#     + 假「游戏」canvas 监听。断言：关态不外发、开态外发且坐标归一化、回放落到 canvas 且
#     **不再外发**（ECHO 闸门）、miss 时回执落点为 BODY、以及最要命的那条——
#     **失焦补发不外发 + 坐标用最后按压点 + 只在真按着时补**。
#     ⚠️ 目标就是 window 的事件（blur/focus）在假环境里必须按 AT_TARGET 跑一遍 window 监听，
#     否则「失焦补发」整条路径测不到（第一版 harness 就栽在这，28 项里漏了 3 项）。

> ⚠️ **页面代理里任何「补发事件」都不能走 `post()`**：那是**外发通道**，宿主会把它路由给
> 同组其它实例。v1 同步代理在 `blur` 时用 `post()` 补 `mouseup(0,0)`，结果每次失焦都往别人
> 窗口扔一条释放——引擎 `handleTouchesEnd` 按 touch id（鼠标恒为 0）命中活动 touch 后会把
> 它的坐标改写成释放点并删掉该 id，随后那条真实 mouseup 被整段丢弃 → **一次点击凭空消失**，
> 且是竞态（合成包早到/晚到都无害）→ 表现为「部分窗口有概率不响应」。
> 判据：写 `post()` 前先问一句「这条包落到别的窗口会怎么被消费」。要本地补，就调 `replay()`
> （它自带 ECHO 标记，闸门会拦住外发）。

> ⚠️ **别用 `strings -a <dylib> | grep` 从二进制里捞 agent 再 `node --check`**：agent 里
> 大量中文注释是非 ASCII，`strings` 会把它切成碎片且顺序错乱，捞出来必然报「语法错误」
> ——那不是代码坏了，是取证工具不对。老老实实走 A 步的隔离编译导出。

> ⚠️ 各 harness 都要喂 **A 步导出的那份 `agent.js`**（不是「Python 抽 `"""…"""` 得到的
> 源码副本」）：后者插值还是 `\(channel)` 这种占位符、行首缩进也不同，测出来的是另一份东西。
> A 步顺带验证了插值，成本一条 `grep`——**别省**（插值名字写错时只有这一步抓得到）。

# C. 真编译
cd /Users/gg/915/CYZW/LobbyCoreSystem && \
  xcodebuild -project GameLobby.xcodeproj -scheme GameLobby -configuration Debug \
             -destination 'platform=macOS' -derivedDataPath /tmp/recon/DD build
```

⚠️ **受控沙箱里编译必挂，先加一个 flag。** Swift 编译器自己会用 `sandbox-exec` 隔离宏插件进程，
在已经受限的环境里那次 `sandbox_apply` 会失败，报错长这样：

```
sandbox-exec: sandbox_apply: Operation not permitted
error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
       for macro 'State()'; …swift-plugin-server produced malformed response
```

它会**逐个 `@State` 报一遍**，看着像 SwiftUI 用法写错了——其实跟代码无关（单独
`swiftc -typecheck` 一个三行 `@State` 文件也一样报）。绕过（关掉 Bash 沙箱**无效**）：

```bash
xcodebuild … OTHER_SWIFT_FLAGS='-Xfrontend -disable-sandbox' build
# 单独验证时同理：xcrun swiftc -typecheck -Xfrontend -disable-sandbox probe.swift
```

⚠️ **验产物要看对地方**：Debug 的代码在 `Contents/MacOS/潮音之王.debug.dylib`（十几 MB），
主可执行文件只有 40KB——在主二进制上 `strings | grep` 什么都查不到，别据此判「改动没编进去」：

```bash
strings -a "…/潮音之王.app/Contents/MacOS/潮音之王.debug.dylib" | grep -c uiNote=
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
- ⚠️ **反过来的坑：JS 里也不能出现「反斜杠 + 任意字符」**。Swift 多行字面量会把
  `\.` 当转义序列，编译直接报 `Invalid escape sequence in literal`——而
  `node --check` 完全查不出（它看到的是合法 JS 正则）。写正则时能不用就不用
  （例：`'1.0' → '1'` 用 `text.slice(-2) === '.0'` 而不是 `replace(/\.0$/, '')`）；
  实在要写就用 `String.raw` 或者把该段拼成普通字符串。

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
- 最划算的用处是**字符串 / 回执解析这类纯函数**：整包编译要几十秒，隔离编译 1 秒。
  本轮就在这一步抓到 `fpsReadings[key] != reading`（字典下标是 Optional，元组不可比较，
  整包也会报，但先在这里报便宜得多）。
- 桩文件里被真实代码引用的键/常量在**真实文件**改过名的话，这里不会跟着变——
  所以只补「键名」这类稳定契约，别在桩里写业务。
- 沙箱里若报宏插件失败（`SwiftUIMacros… produced malformed response`），加
  `-Xfrontend -disable-sandbox`；纯 store / 解析函数不涉及宏，一般不用加。

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

## 6. 另一个方向：不跑游戏，直接从服务端取数据

需求若是「账号不启动也要显示头像/战力/等级」，**不要**去反解 bundle——那只能改游戏内行为。
游戏服务端有一套 HTTP + WSS 接口，用 `.bin` 凭据就能直接问（实测 ~300ms/账号，零 WebView）。
**这是首选路径**，实测与游戏内 `ROLE` 同源（同一账号返回的 `headImg` 逐字节一致）。

协议细节、可复现探针、三条路的对比表都在
**`.workbuddy/tools/ws-profile-probe/README.md`**，这里只留判据：

- 凭据 = `.bin` **原字节** POST，`Content-Type: application/octet-stream`。
- `/login/authuser?_seq=1` → `{roleToken, roleId}`；拼成
  `JSON.stringify({...data, sessId, connId, isRestore:0})` 当 WSS 的 `p=`；
  然后 `role_getroleinfo` → `role.headImg` / `power` / `levelId` / `name`。
  ⚠️ **这里的 `roleId` 是账号 uid，不是游戏角色 ID**（同一账号恒为同一个值，
  与请求里的 `serverId` 无关）。**别拿它判「换服有没有生效」**——会得到
  「服务端忽略 serverId」的完全错误结论（已踩）。判据只能是 WSS 侧 `role.name` / `role.roleId`。
- 帧格式 = BON 编码 + **x 方案**（4 字节头 + 单字节 XOR，密钥藏在头里）；
  HTTP 响应没有加密信封。报文体是**外层 BON 里再嵌一段 BON**，要解两层。
- `.bin` 本体编码是 **`lx`**（首两字节 `70 6c`）＝ **LZ4 压缩 + 头掩码**，
  解开后是 `{platform, platformExt, info, serverId, scene, referrerInfo}`——
  **就是一次 `login_authuser` 的请求参数**。`serverId` 决定落在哪个区服角色：
  区服号 = `serverId - 27`，`≥1e6 / ≥2e6` = 第 1/2 个小号位。
  → **改 `serverId` 再按 `lx` 重编码，换服就成立了**（实测 4/5 命中，见
  `probe-pick-role.mjs`）。Swift 侧实现见 `LobbyEngine/BinCredential.swift`。
  ⚠️ **不要**去手搓「游戏式参数体」（`{platform, oriPlatform, platformExt, info, serverId,
  scene, referrerInfo, deviceUniqueId}`）：`serverViewId` 会跟着 `serverId` 走，
  但角色是空的（`name=111`、`levelId=1`、`gold=10`、uid 变成另一个），缺 SDK 会话上下文。
- ⚠️ **两条只能靠实测发现、且都会静默失败的协议事实**（详见
  `BIN登录认证优化方案.md` §8.2）：
  1. **响应编码跟随请求的 `O4e-Encoding`**：发 `lx` 就收回 `70 6c` 包着的 BON，
     不发就收回裸 BON（首字节 `08`）。所以「宿主喂给游戏的响应」与「请求体」必须同编码——
     游戏的 HTTP 客户端把编码写死成 `lx`，给它裸 BON 会解不开。
  2. **服务端会校验 LZ4 帧头校验和（HC）**：自己封的 LZ4 帧里 HC 必须用 XXH32 真算；
     写 0 的表现是 `error=指令解析错误`（HTTP 200、长度正常、就是没有 roleToken）。
     「只存不压」的块（块头最高位置 1）是合法的，可以省掉压缩器。
     三向对照：`probe-lx-variants.mjs`。
- ⚠️ **`/login/serverlist` 的 `power` 是错的**（与该账号当前角色对不上、level 恒为 1）——
  它只能取「区服 / 角色列表」；但 `roles[].roleId` 是**可信**的（可与 WSS 逐字段对上）。
  另外 `role.serverName` 在合服区不一定等于 `serverId - 27`，展示区服号请用后者。
- ⚠️ **`/login/*` 家族只认「体 = 凭据本身」**：游戏自己发的是**参数体**
  （`LoginService.serverList({platform, oriPlatform, platformExt, info, areaId})`），
  服务端回一个**空的 200**（105 字节 / 0 区 / 0 角色 / 连 `error` 都没有）。
  补 `_raw`（上号器 hook 里的字段名）也没用。一次一变量：
  `probe-serverlist-params.mjs` / `probe-raw-field.mjs`。
  → 要拿到数据，**必须**把请求体换成凭据本体（宿主的做法见
  `BootstrapScriptBuilder` 的 XHR 垫片第三种去向）。
- ⚠️ **但光有数据还不够：响应缺字段会让游戏解析器当场中断，而且没有任何报错。**
  实测 `/login/serverlist` 的响应只有
  `{areaList, serverList, roleCount, recommendId, roles}`，而
  `SelectServerModule._parseFirstServerList` 需要 **`deletedRoles`（必须是 `Map`）**
  与 **`maxViewId`** —— 缺第一个就 `e.deletedRoles.forEach(...)` 抛 TypeError，
  后面的 `BigServerConf.map.forEach(...)`（真正填 `bigServerList` 的那段）永远到不了，
  表现就是「选择大区」**面板空白、没有报错**。
  另外 `serverList` 在 BON 里是**数组（tag 9）**不是 map；`maxViewId` = 最大
  `serverList[].viewId`。
  → 修法是**在数据进解析器之前补这两个字段**（打 `SelectServerModule.prototype`
  的两个 `_parse*` 方法）——不需要 BON 解码器、不需要搬大包、失败就不补（无回归）。
  **教训：补丁尽量靠近消费方**；「页面里没有任何报错、就是空的」先怀疑必需字段缺失。
- ⚠️ **引导脚本里的 console 桥必须最先安装**：它原来挂在 `makeScript` 产物末尾，
  于是引导脚本更早的 `console.*` 全部回不到宿主 —— 「日志里没出现 = 没发生」这个
  推论会**错**（我为此刻意踩了两轮）。
- ⚠️⚠️ **垫在游戏既有调用路径上的垫片（XHR / 原型方法 / 事件监听）必须异常安全。**
  这类地方抛异常不会变成「功能失效」，而是**静默卡死**——因为调用方几乎都在 promise 链里，
  异常被吞掉，页面就停在「正在加载游戏场景」之类的地方，日志里什么都没有。
  真实事故：往统计对象里加了个字段却漏了初始化，`undefined.indexOf` 抛在
  `__bridgedXHR.prototype.open()` 里，`/login/*` 的每次 open 都炸 → 加载任务被打断。
  所以：① 整个 entry 包 `try/catch` 且兜底动作是「原样放行」；
  ② 诊断/统计代码**再单独包一层** `try/catch`；
  ③ 加断言「诊断结构的字段必须全部存在」+ 「一串 URL 的 open/send 一个都不许抛」；
  ④ **改完先 dump 产物脚本看一眼**（初始化行 + `new Function(src)` 过语法），比开游戏快得多。
- 排查入口：登录链路的关键行会落盘到
  `~/Library/Application Support/GameLobby/diagnostics.log`（`LobbyStorage/DiagnosticsLog.swift`），
  **不要让用户从几千行控制台里挑行粘贴**——两次都恰好截在关键处之前。
- ⚠️ **绝不能对正在运行的账号做**：会建立第二个会话，很可能顶掉大厅里的实例。
  宿主侧必须先判「该账号无运行实例」，并且**顺序 + 间隔**，不要并发。
  （例外：`/login/serverlist` 是纯 HTTP，**不建会话**，运行中也能查。）
- 要搜「游戏自己怎么调这些端点」，用 `.workbuddy/tools/cdn-bundle/scan-login-cmds.mjs`
  （一次解密**全部** CDN bundle 并搜关键词，`DUMP_DIR=` 导出明文）——
  `decrypt.js` 只导 game+launcher，而命令枚举与 `LoginService` 真身在
  **`TEST_REMOTE_MODULE`** 里（`login_authuser` / `login_serverlist` / `login_selectserver`…）。
- 页面里 `/login/authuser` 的**唯一调用方是游戏自己**（`HSDK.app.min.js` 与
  `ios2-web-*.js` 都不碰这个端点）——所以「换服」这件事必须由**宿主**来回答，
  放行给游戏自己会让它拿不到凭据。实现见 `LobbyEngine/LoginProxy.swift`。

**移植时的验证方式：与参考实现逐字节对拍**（`.workbuddy/tools/profile-fetch-verify/run.sh`）。
BON 解析是**静默失败**的——解码器与编码器共享一张字符串表，漏一次 push 之后所有
tag 99 引用都会错位，读出来是「看着正常、值不对」的字符串。所以：

- 判据只有「同一份输入 → 逐字符相同的 dump / 逐字节相同的二进制」，
  **「能跑通」不算数**；编码器要比字节（解码对了不代表编码对）。
- 一手真数据当向量：真实 HTTP 响应 + 真实 WSS 响应（十几万字节、内层 dump 近 20 万字符）。
- 再加一条互操作测试（参考实现能解开我们封的帧），才闭环。
- 三个坑（都在 README 里）：参考实现的 decrypt **就地改**输入数组（原始信封要在解密前存）；
  BON 要解两层（`getData()` 取内层）；ESM 相对 import 相对**脚本自身**解析。

> 通用教训：拿到一个新数据源时，**先拿一个已知答案的样本做对拍**（本例：用页面内
> `ROLE` 已有的 13 个账号资料当基准），再决定信不信它。不做对拍的话，
> `serverlist` 那个对不上号的 `power` 会被一路带到 UI 上。

## 7. 别忘

- 第三方脚本（`~/Downloads/*.js`、脚本库里的）**不可修改**，只能读来学机制。
- 需求若来自某个第三方脚本，说明里要写清「参考了什么、落到宿主哪一层」。
- 说「某某脚本好像支持 X」时，**先取证它到底支持什么**：同目录下往往还有别的脚本才是真正
  干这事的（例：被指的两个脚本一个只管帧率角标、一个是面板级加速，而「全局加速」其实在宿主的
  `native-game-host.js` 里）。判据是 grep 出来的代码行，不是文件名。
- 要「加速 / 减速 / 暂停」类需求，先按 §0 最后一条判作用域（Scheduler 那一支 vs 组件 `update`），
  再决定改 `setTimeScale` 还是改面板的 `DEFAULT_TIMESCALE`——选错了会得到
  「UI 快了但战斗没快」或反过来的假结论。
- 写完追加 `.workbuddy/memory/YYYY-MM-DD.md`（含反解偏移量等可复现证据）。
- **先想清楚「这个需求真的需要反解 bundle 吗」**：如果只是要一份数据（资料 / 排行 / 列表），
  服务端 HTTP+WSS 往往直接给（见 §6），比改游戏内行为便宜一个数量级。
