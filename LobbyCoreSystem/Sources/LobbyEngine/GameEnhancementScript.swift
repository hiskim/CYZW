import Foundation

// MARK: - 游戏加强 · 页面侧代理
//
// 与 `InputSyncScript` 同策略：代理脚本在 `atDocumentStart` **预注入**每个实例
// （WKUserScript 只能在导航时注入、运行时无法追加），运行时只推配置——否则
// 「实例已经跑起来才打开开关」就只能等下一次导航，用户看到的是「点了没反应」。
//
// 目前两项加强：
//
// ── ① 十殿加速 ─────────────────────────────────────────────────────────────
// 原理与第三方脚本（猫助手）完全一致——改写 `NightmareBattlePanel.DEFAULT_TIMESCALE`，
// 让十殿试炼的战斗动画整体加速，只改画面节奏、不改战斗结算：
//
// 1. **钩子**：`__require('NightmareBattlePanel')` 取到类，包一层
//    `prototype.onShow`；每次 onShow 之后按当前开关把 `DEFAULT_TIMESCALE`
//    改成目标倍率（关闭时还原原始值）。
// 2. **现场**：已经在战斗里的面板不会再触发 onShow，所以在场景树里找活的
//    `NightmareBattlePanel` 组件直接改 `DEFAULT_TIMESCALE`。
//    这一路**不依赖 `__require`**（只用 `cc.director.getScene()`），所以即使模块
//    还没加载，玩家当前这一场战斗也能立刻加速——钩子随后由轮询补上，负责后续场次。
//
// ── ② 聊天窗口显示 / 隐藏 ──────────────────────────────────────────────────
// 结构来自**线上 bundle 反解**（`remote/game/index.<ver>.jsc` 是 XXTEA 密文，
// 用 `ios2-web-boot.js` 的 `decryptJSC` 解出明文后读 `ChatPanel` 模块 + `UI_NewChatPanel`）：
//
//   - 模块 `ChatPanel` 导出 `{ NewChatPanel: 控制器类 }`；控制器实例的 `.ui` 是
//     FairyGUI 组件 `ui://r6ibbv0plmbho`（`UI_NewChatPanel`，extends `fgui.GComponent`）。
//   - 子节点：`notice` `leftChannel` `chatList` `btnChannelList` `slide` `btnChatClose`
//     `emojis` `inputContent` `input` `btnTrumpet` `btnEmoji` `btnSend` `inputBar`
//     `inputComp` `btnToBottom` `btnSetting`；
//     控制器：`haveNew` `showTrumpet` `inputCompState`（页面 `show` / `emoji` / `hide`）`showExtBg`。
//   - 生命周期：`onAwake` / `onShow` / `onHide` / `onClose` / `fixScene`。
//
// 实现只做一件事：把**窗口外壳**的 `visible` 置 false——不动布局、不动游戏数据、
// 不碰 `inputCompState`（那是游戏自己管输入框折叠 / 表情的控制器）。
// 面板位置由游戏自己的 `fixScene()` 写在 `ui.parent.height = HomeScene.ui.m_under.y - 127`，
// 与我们的 `visible` 无关，所以隐藏它不会连带改坏场景排版。
//
// ⚠️ **要隐藏的是外壳，不是内容组件（踩过一次的坑）。**
// 游戏的 UI 框架（`UIManager` + `UIProxy._addUI` / `_setSkin`）在
// `uiProxyMetadata.skin` 存在时会把面板包一层 skin：
//
//     层(parentUI) → skinUI(UI_CommonDialogSkin：m_biaotou 标题头 / m_container / m_bkmask)
//                  → …（FguiUtil.getDeepChild(skin, ConstName.Container)）… → ui(NewChatPanel)
//
// 而且 `(i.proxy = this).skinUI = i`、`(this.ui.proxy = this)`——**两层 proxy 是同一个控制器**。
// `ChatPanel` 的装饰器自己没写 skin，是从基类元数据继承来的
// （`o.ui` 里 `i.skin || (i.skin = t.skin)`），所以**一定有 skinUI**。
// 只压 `ui` 的实际表现就是「外壳还在、里面空了」。
// 因此这里沿父链上溯到「proxy 与 ui 相同的最高祖先」= skinUI；没有 skin 时它自然就是 ui。
//
//   - **第一次找到**：从 `window.fgui.GRoot.inst` 递归扫（`numChildren` / `getChildAt`），
//     按子节点指纹认面板（`chatList` + `inputComp` + `input` + `btnSend` 同时在）。
//   - **之后**：只对外壳重写一次 `visible`（一次属性赋值，不重扫整棵树）。
//     外壳被回收 / 换场景后自动降频重扫（约 2s 一次），避免空转遍历 GRoot。
//   - **钩子**：额外包一层 `NewChatPanel.prototype.onShow`，面板刚显示的那一帧就压住，
//     消除「先闪 250ms 再被隐藏」的观感。
//   - **还原**：只在「我们动手前它是显示着的」时才重新 `visible = true`
//     （`restoreTo` 标记）——免得在本来就不该有聊天的场景里硬把它弹出来。
//   - **诊断**：`status()` 里的 `skin=N/M` 表示 M 个面板里有 N 个解析到了 skin 外壳；
//     若为 0 而界面仍有残留，说明该窗口走的是另一套挂载路径，需要再取证。
//
// ⚠️ `window.__require` 是**游戏自己的**跨 bundle 模块注册表（不是宿主符号，
// 见 `ios2-script-runtime.js` 的注释），文档起点注入时它还不存在，且
// `NightmareBattlePanel` / `ChatPanel` 都要等对应玩法才会被加载。所以这里用
// **有界轮询**等它就绪（500ms × 120 ≈ 60s），而不是一次性失败。
//
// ⚠️ 幂等：整段以 `window.__LOBBY_ENHANCE__` 是否存在作为哨兵，
// 重复注入（池化实例重新导航）不会叠加钩子。
public enum GameEnhancementScript {
    /// 十殿面板的模块名 / 组件名（与游戏侧一致，勿改）。
    public static let nightmarePanelName = "NightmareBattlePanel"

    /// 代理脚本版本号。**每次改 `agent` 就 +1**。
    /// 诊断串里带 `v=`，一眼就能确认页面里跑的到底是哪一版——
    /// 省掉「你确定重建了吗 / 跑的是不是这一版」这类来回（已经吃过三次亏）。
    public static let agentVersion = "10"

    /// 聊天面板的模块名（与游戏侧一致，勿改）。
    public static let chatPanelModuleName = "ChatPanel"

    /// 推一次配置（幂等，可重复调用）。
    /// 返回值是页面侧的诊断串：
    /// `running=1 speed=100 hook=1 panel=1 chat=1/1:hidden note=running-live`；
    /// 代理不存在时返回 `no-handler`（页面未装代理脚本）。
    public static func apply(enabled: Bool, speed: Int, hideChat: Bool) -> String {
        "window.__LOBBY_ENHANCE__ ? window.__LOBBY_ENHANCE__.apply(" +
            "{enabled:\(enabled ? "true" : "false"),speed:\(speed)," +
            "hideChat:\(hideChat ? "true" : "false")}) : 'no-handler'"
    }

    /// 只读诊断：当前页面侧加强状态。
    public static func status() -> String {
        "window.__LOBBY_ENHANCE__ ? window.__LOBBY_ENHANCE__.status() : 'no-handler'"
    }

    /// 代理脚本本体（`atDocumentStart` 注入，只注入主框架）。
    public static let agent: String = {
        let panelName = nightmarePanelName
        let chatModule = chatPanelModuleName
        let agentVersion = Self.agentVersion
        return """
        (() => {
          if (window.__LOBBY_ENHANCE__) return;

          const AGENT_VERSION = '\(agentVersion)';
          const PANEL_NAME = '\(panelName)';
          const RETRY_INTERVAL_MS = 500;
          const MAX_RETRIES = 120;
          const MIN_SPEED = 1;
          const MAX_SPEED = 1000;
          const DEFAULT_SPEED = 100;

          // 聊天窗口显隐
          const CHAT_PANEL_MODULE = '\(chatModule)';
          const CHAT_TICK_MS = 250;
          // 找不到面板时的降频：每 8 拍（≈2s）才重扫一次 GRoot。
          const CHAT_SLOW_SCAN_EVERY = 8;
          // 遍历上限，防病态场景把主线程拖住。
          const CHAT_WALK_LIMIT = 4000;

          const state = {
            running: false,
            speed: DEFAULT_SPEED,
            hookInstalled: false,
            originalDefaultTimescale: null,
            panel: null,
            retryTimer: 0,
            retries: 0,
            note: 'idle'
          };

          // 聊天窗口显隐的独立状态（与十殿加速互不影响）。
          // shells 项：{ ui, shell, isSkin, restoreTo }
          //   ui    = 内容组件（指纹命中的 NewChatPanel 本体）
          //   shell = 真正被隐藏的节点（有 skin 时是 skinUI，否则就是 ui）
          //   isSkin= 是否解析到 skin 外壳（诊断用：skin=N/M）
          //   restoreTo = 我们动手前它是不是显示着
          const chat = {
            hidden: false,
            shells: [],
            hookInstalled: false,
            timer: 0,
            scanIn: 0,       // 还有几拍才去重扫 GRoot（0 = 下一拍就扫）
            reportIn: 0,     // 还有几拍才往页面 console 打一次结构快照
            reports: 0,      // 已经打过几条（封顶，别把日志刷爆）
            classHooks: 0,   // 已挂上「构造 / 复用」守门的生成类数量（诊断用）
            visibleGuards: 0,// 已接管 `visible` 访问器的生成类数量（诊断用）
            hookPoll: 0,     // 快速挂钩轮询定时器
            hookTries: 0,    // 快速挂钩已尝试次数
            root: 'none',    // 上次命中路径：groot / scene / no-panel / no-root
            note: 'idle'
          };

          const clampSpeed = (value) => {
            const parsed = parseInt(value, 10);
            if (!isFinite(parsed)) return DEFAULT_SPEED;
            return Math.max(MIN_SPEED, Math.min(MAX_SPEED, parsed));
          };

          // 游戏自己的跨 bundle 模块注册表：只读，绝不包装（包装会断掉
          // 各 bundle 之间串起来的父 require 链，表现是卡在加载场景）。
          const resolveRequire = () => {
            if (typeof window.__require === 'function') return window.__require;
            if (typeof window.require === 'function') return window.require;
            return null;
          };

          const resolvePanelClass = () => {
            const require = resolveRequire();
            if (!require) { state.note = 'waiting-require'; return null; }
            let module = null;
            try {
              module = require(PANEL_NAME);
            } catch (error) {
              state.note = 'require-threw';
              return null;
            }
            if (!module) { state.note = 'waiting-module'; return null; }
            const klass = module.NightmareBattlePanel || module.default || null;
            if (typeof klass !== 'function') { state.note = 'no-class'; return null; }
            return klass;
          };

          // ── 钩子：包一层 prototype.onShow ──
          const installHook = () => {
            if (state.hookInstalled) return true;
            const klass = resolvePanelClass();
            if (!klass || !klass.prototype) return false;
            const proto = klass.prototype;
            if (typeof proto.onShow !== 'function') { state.note = 'no-onshow'; return false; }
            if (proto.onShow.__lobbyEnhancePatched) {
              state.hookInstalled = true;
              state.note = 'hook-ready';
              return true;
            }
            const originalOnShow = proto.onShow;
            proto.onShow = function () {
              const result = originalOnShow.apply(this, arguments);
              try {
                // 面板实例上另存一份原始节奏，避免与第三方脚本的钩子互相覆盖。
                if (this.__lobbyEnhanceOriginalTimescale === undefined) {
                  this.__lobbyEnhanceOriginalTimescale = this.DEFAULT_TIMESCALE;
                }
                this.DEFAULT_TIMESCALE = state.running
                  ? state.speed
                  : this.__lobbyEnhanceOriginalTimescale;
              } catch (error) {}
              return result;
            };
            proto.onShow.__lobbyEnhancePatched = true;
            state.hookInstalled = true;
            state.note = 'hook-ready';
            return true;
          };

          // ── 现场：找当前场景里活着的面板组件 ──
          const findLivePanel = () => {
            try {
              const cc = window.cc;
              const director = cc && cc.director;
              const scene = director && typeof director.getScene === 'function' && director.getScene();
              if (!scene) return null;
              if (typeof scene.getComponentInChildren === 'function') {
                const byName = scene.getComponentInChildren(PANEL_NAME);
                if (byName) return byName;
              }
              // 兜底：按 constructor.name 递归扫 _components（注册名拿不到时走这条）。
              const stack = [scene];
              while (stack.length) {
                const node = stack.pop();
                const components = node && node._components;
                if (components && components.length) {
                  for (let index = 0; index < components.length; index++) {
                    const component = components[index];
                    if (component && component.constructor && component.constructor.name === PANEL_NAME) {
                      return component;
                    }
                  }
                }
                const children = (node && node.children) || [];
                for (let index = 0; index < children.length; index++) stack.push(children[index]);
              }
            } catch (error) {}
            return null;
          };

          const applyLive = () => {
            const panel = findLivePanel();
            if (!panel) return false;
            state.panel = panel;
            try {
              if (state.originalDefaultTimescale === null) {
                state.originalDefaultTimescale = panel.DEFAULT_TIMESCALE || 1.4;
              }
              panel.DEFAULT_TIMESCALE = state.speed;
              return true;
            } catch (error) {
              return false;
            }
          };

          const stop = () => {
            if (state.retryTimer) {
              clearInterval(state.retryTimer);
              state.retryTimer = 0;
            }
            if (state.panel && state.originalDefaultTimescale !== null) {
              try { state.panel.DEFAULT_TIMESCALE = state.originalDefaultTimescale; } catch (error) {}
            }
            state.panel = null;
            state.originalDefaultTimescale = null;
          };

          const scheduleRetry = () => {
            if (state.retryTimer || state.retries >= MAX_RETRIES) return;
            state.retryTimer = setInterval(() => {
              state.retries += 1;
              if (!state.running) {
                clearInterval(state.retryTimer);
                state.retryTimer = 0;
                return;
              }
              if (installHook()) {
                applyLive();
                state.note = state.panel ? 'running-live' : 'running-hook';
                clearInterval(state.retryTimer);
                state.retryTimer = 0;
                return;
              }
              if (state.retries >= MAX_RETRIES) {
                state.note = 'give-up';
                clearInterval(state.retryTimer);
                state.retryTimer = 0;
              }
            }, RETRY_INTERVAL_MS);
          };

          // ── 聊天窗口：找面板 / 压 visible / 还原 ──
          //
          // 指纹与线上 `UI_NewChatPanel.onConstruct` 的 getChild 列表对得上就认。
          // 成员变量（`ui.m_chatList`）与 `getChild('chatList')` 两条路都认：
          // 前者是游戏绑好的，后者在它还没绑上时兜底。
          // 指纹一：子节点（成员变量 / getChild 两条路）。来自线上
          // `UI_NewChatPanel.onConstruct`，是"面板内容长什么样"的判据。
          //
          // 指纹二：**元数据名字 / URL**。为什么必须有——游戏里有**两个**聊天 UI：
          //   · `ui_chat/NewChatPanel`（`ui://r6ibbv0plmbho`）——点开的完整聊天窗；
          //   · `ui_main/MainPanelChat`（`ui://8fweejrdlmbhm`）——**主城里那个聊天框**，
          //     即 `UI_MainPanel.m_chat`（`this.m_chat = this.getChild("chat")`），
          //     由 `MainPanelChatComp` 驱动（`_chatUI = e.ui.m_chat`，
          //     成员是 `m_chatItemList` / `m_redDot` / 控制器 `showRed`）。
          //   两者成员变量完全不同，只认前者的话在主城「怎么都不生效」——踩过。
          //   名字/URL 不依赖构造流程，是更稳的判据。
          const CHAT_PANEL_NAMES = ['NewChatPanel', 'ChatDialog', 'TopChatDialog',
                                    'TopPlushChatDialog', 'MainPanelChat'];
          const CHAT_PANEL_URLS = ['ui://r6ibbv0plmbho', 'ui://8fweejrdlmbhm'];

          const chatPanelByMeta = (object) => {
            try {
              const item = object.packageItem;
              if (item && item.name && CHAT_PANEL_NAMES.indexOf(item.name) >= 0) return true;
              const klass = object.constructor;
              if (klass && klass.URL && CHAT_PANEL_URLS.indexOf(klass.URL) >= 0) return true;
            } catch (error) {}
            return false;
          };

          const looksLikeChatPanel = (object) => {
            if (!object) return false;
            if (chatPanelByMeta(object)) return true;
            // 指纹三：主城聊天框特有的成员（`MainPanelChat.m_chatItemList`）。
            if (object.m_chatItemList) return true;
            if (typeof object.getChild !== 'function') return false;
            const pick = (member, name) => {
              try {
                if (object[member]) return object[member];
                return object.getChild(name);
              } catch (error) { return null; }
            };
            return !!(pick('m_chatList', 'chatList') &&
                      pick('m_inputComp', 'inputComp') &&
                      pick('m_input', 'input') &&
                      pick('m_btnSend', 'btnSend'));
          };

          const isAlivePanel = (panel) => !!(panel &&
            !panel._disposed && !panel._destroyed &&
            !(panel.node && panel.node._destroyed));

          // 内容组件 → 窗口外壳。框架把面板塞进了 skin 的深层 container，
          // 所以沿父链上溯到「proxy 与 ui 相同的最高祖先」：
          // skinUI 的 proxy 就是同一个控制器（`(i.proxy = this).skinUI = i`），
          // 再往上的层 / 父窗口不在同一条 proxy 上，会自然停住。
          // 没有 skin 的窗口上溯不出东西，结果就是 ui 本身。
          const resolveChatShell = (ui) => {
            let shell = ui;
            let isSkin = false;
            try {
              const controller = ui && ui.proxy;
              let node = ui;
              for (let depth = 0; depth < 10 && node; depth++) {
                const parent = node.parent;
                if (!parent) break;
                if (controller && parent.proxy === controller) { shell = parent; isSkin = true; }
                node = parent;
              }
            } catch (error) {}
            return { shell: shell, isSkin: isSkin };
          };

          // 登记一个面板（按 ui 去重）。返回 null 表示已在册。
          // `forceRestoreTo` 传 undefined 时按**外壳**当前可见性推断；onShow 钩子显式传 true。
          const rememberChat = (ui, forceRestoreTo) => {
            for (let index = 0; index < chat.shells.length; index++) {
              if (chat.shells[index].ui === ui) return null;
            }
            const resolved = resolveChatShell(ui);
            const entry = {
              ui: ui,
              shell: resolved.shell,
              isSkin: resolved.isSkin,
              // 「我们动手前它是不是显示着」必须以**外壳**为准：框架隐藏窗口时压的就是
              // 外壳，ui 自己可能一直是 true（踩过：用 ui 判断会把不该显示的窗口硬弹出来）。
              restoreTo: forceRestoreTo !== undefined
                ? forceRestoreTo
                : resolved.shell.visible !== false
            };
            chat.shells.push(entry);
            installPanelHooks(ui);
            return entry;
          };

          // ── 构造 / 复用守门 ──
          //
          // 为什么光靠定时巡检不够（用户实测「进主城会先闪一下」）：
          //   · `onConstruct()` 是构造流程的**最后一步**（`_underConstruct=false`、
          //     `applyAllControllers()` 之后），在这里置 `visible=false` 才算数；
          //   · fgui 有**对象池**：复用组件时 `constructFromResourceAlone()` 之后会调
          //     **`resetVisible()`**（`node.active=true, _internalVisible=true,
          //     visible=true`）——正好把我们的隐藏状态抹掉，那一帧就是「先显示一下」。
          // 所以把守门挂到**生成类的原型**上：构造时压一次、复用后立刻压一次，
          // 都在同一帧内完成，屏幕上不会出现中间态。定时巡检退化成兜底。

          // 把一个面板立刻压住并纳入巡检。`restoreTo` 传 undefined 时按外壳现况推断。
          const suppressPanel = (ui, restoreTo) => {
            if (!ui) return;
            const entry = rememberChat(ui, restoreTo);
            const shell = entry ? entry.shell : resolveChatShell(ui).shell;
            try { shell.visible = false; } catch (error) {}
            chat.scanIn = 0;
          };

          // 被我们「削」过写入的面板：轻量入册。
          // 不走 `suppressPanel`，避免从 `visible` 写入里再递归回去。
          const noteSuppressed = (ui) => {
            if (!ui || ui.__lobbyChatNoted) return;
            ui.__lobbyChatNoted = true;
            const entry = rememberChat(ui, true);
            if (entry) { try { entry.shell.visible = false; } catch (error) {} }
            chat.scanIn = 0;
          };

          // ── 接管 `visible` 访问器（这条才是根治）──
          //
          // 为什么「构造 / 复用 / 巡检」三个点还不够：
          // 游戏自己会在刷新主城面板时把聊天框显出来——
          //   `t.m_chat.visible = e.isModuleVisible(H.ModuleType.CHAT)`   （game.js @6972079）
          // 任何一次外部写入都能把它点亮一帧，我们只能事后追赶 → 用户看到「闪一下」。
          //
          // fgui 的实现（runtime @15072581）：
          //   Object.defineProperty(GObject.prototype,"visible",
          //     { get(){return this._visible}, set(e){ this.setVisible(e) } })   // configurable:true
          //   setVisible(e){ ...; this.handleVisibleChanged() }  →  handleVisibleChanged:
          //     this._node.active = this._finalVisible    // _finalVisible = _visible && _internalVisible
          // 所以只要**把写入本身削掉**，`node.active` 自然就是 false，
          // 对象池的 `resetVisible()`（它也是走 `visible = true`）一并失效。
          const installVisibleGuard = (klass) => {
            if (!klass || !klass.URL || klass.__lobbyVisibleGuarded) return false;
            const proto = klass.prototype;
            if (!proto) return false;
            let descriptor = null;
            let owner = proto;
            while (owner && !descriptor) {
              descriptor = Object.getOwnPropertyDescriptor(owner, 'visible');
              if (!descriptor) owner = Object.getPrototypeOf(owner);
            }
            if (!descriptor ||
                typeof descriptor.get !== 'function' ||
                typeof descriptor.set !== 'function') return false;
            try {
              Object.defineProperty(proto, 'visible', {
                configurable: true,
                enumerable: descriptor.enumerable,
                get: function () { return descriptor.get.call(this); },
                set: function (value) {
                  const coerced = chat.hidden ? false : value;
                  descriptor.set.call(this, coerced);
                  if (chat.hidden && value !== false) noteSuppressed(this);
                }
              });
            } catch (error) {
              return false;
            }
            // 有的代码直接调 `setVisible(...)`（例如 GLoader.visible），一并削掉。
            const originalSetVisible = proto.setVisible;
            if (typeof originalSetVisible === 'function' &&
                !originalSetVisible.__lobbyVisibleGuarded) {
              const wrapped = function (value) {
                const result = originalSetVisible.call(this, chat.hidden ? false : value);
                if (chat.hidden && value !== false) noteSuppressed(this);
                return result;
              };
              wrapped.__lobbyVisibleGuarded = true;
              proto.setVisible = wrapped;
            }
            klass.__lobbyVisibleGuarded = true;
            return true;
          };

          const wrapSuppressing = (proto, methodName) => {
            if (!proto || typeof proto[methodName] !== 'function') return false;
            const original = proto[methodName];
            if (original.__lobbyChatGuarded) return true;
            const wrapped = function () {
              const result = original.apply(this, arguments);
              // 构造 / 复用都说明「游戏本来要把它显示出来」——恢复时照旧显示。
              if (chat.hidden) suppressPanel(this, true);
              return result;
            };
            wrapped.__lobbyChatGuarded = true;
            proto[methodName] = wrapped;
            return true;
          };

          // 只对**有生成类**的元件挂（有静态 URL）。否则 `panel.constructor.prototype`
          // 可能就是 `fgui.GComponent.prototype`——那会把守卫挂到所有组件上，后果不可控。
          const installClassHook = (klass) => {
            if (!klass || !klass.URL) return false;
            const proto = klass.prototype;
            if (!proto) return false;
            const a = wrapSuppressing(proto, 'onConstruct');
            const b = wrapSuppressing(proto, 'resetVisible');
            const c = installVisibleGuard(klass);
            if (c) chat.visibleGuards += 1;
            return a || b || c;
          };

          // 预先按模块名挂钩：`cc._RF.push(...,"UI_MainPanelChat")` 的模块名就是类名，
          // 这样**第一次进主城**就已经被守住，不用等我们先「看见」一个实例。
          const CHAT_UI_MODULES = ['UI_MainPanelChat', 'UI_NewChatPanel'];
          const installClassHooks = () => {
            const require = resolveRequire();
            if (!require) return 0;
            let installed = 0;
            for (let index = 0; index < CHAT_UI_MODULES.length; index++) {
              const name = CHAT_UI_MODULES[index];
              let klass = null;
              try {
                const module = require(name);
                klass = module && (module.default || module[name] || module);
              } catch (error) { klass = null; }
              try { if (klass && installClassHook(klass)) installed += 1; } catch (error) {}
            }
            if (installed > chat.classHooks) chat.classHooks = installed;
            return installed;
          };

          // 巡检扫到的实例也补挂（模块名对不上时兜底，比如别的包里的同类元件）。
          const installPanelHooks = (panel) => {
            try {
              const klass = panel && panel.constructor;
              if (klass && klass.URL) installClassHook(klass);
            } catch (error) {}
          };

          // ── 快速挂钩轮询 ──
          // 「下载包 → 建窗口 → 刷新（把 m_chat.visible 设 true）」很可能是一段**同步**流程，
          // 250ms 的巡检根本来不及插进去。这里用 50ms 只做 2 次 `__require`（模块表查找），
          // 代价可忽略；一旦挂上（或超时 ≈60s）就停。
          const HOOK_POLL_MS = 50;
          const HOOK_POLL_MAX = 1200;

          const stopHookPoll = () => {
            if (chat.hookPoll) { clearInterval(chat.hookPoll); chat.hookPoll = 0; }
          };

          const hookPollTick = () => {
            if (!chat.hidden) { stopHookPoll(); return; }
            installChatHook();
            const installed = installClassHooks();
            chat.hookTries += 1;
            if (installed >= 1 || chat.hookTries >= HOOK_POLL_MAX) stopHookPoll();
          };

          const startHookPoll = () => {
            if (chat.hookPoll) return;
            chat.hookTries = 0;
            chat.hookPoll = setInterval(hookPollTick, HOOK_POLL_MS);
            hookPollTick();
          };

          // 找根。两条**互相独立**的路径，任一条命中即可：
          //
          // ① fgui 自己的显示树。⚠️ `GRoot.inst` 是**会抛异常的 getter**
          //    （runtime：`if (D._inst) return D._inst; throw "Call GRoot.create first!"`），
          //    所以先摸 `_inst`、再退回 getter，两边都包住——不然一个异常就把整条路径吃掉。
          // ② cc 场景遍历：每个 fgui 对象的 cc.Node 上都有 `$gobj` 回指 fgui 对象
          //    （游戏代码里 `e.currentTarget.$gobj` 就是这么用的），完全不依赖 ①。
          const chatRoots = () => {
            const roots = [];
            const fgui = window.fgui;
            if (fgui && fgui.GRoot) {
              try { if (fgui.GRoot._inst) roots.push(fgui.GRoot._inst); } catch (error) {}
              try {
                const viaGetter = fgui.GRoot.inst;
                if (viaGetter && roots.indexOf(viaGetter) < 0) roots.push(viaGetter);
              } catch (error) {}
            }
            return roots;
          };

          const pushUnique = (list, object) => {
            if (!object) return;
            for (let index = 0; index < list.length; index++) {
              if (list[index] === object) return;
            }
            list.push(object);
          };

          // 路径 ②：遍历 cc 场景，收集每个节点上的 `$gobj`。
          // `seen` 用来区分「根本没找到 fgui 对象」和「有对象但没有聊天面板」。
          const collectChatPanelsFromScene = () => {
            const found = [];
            let seen = 0;
            try {
              const cc = window.cc;
              const director = cc && cc.director;
              const scene = director && typeof director.getScene === 'function' && director.getScene();
              if (!scene) return { found: found, seen: seen };
              const stack = [scene];
              let visited = 0;
              while (stack.length && visited < CHAT_WALK_LIMIT) {
                const node = stack.pop();
                visited += 1;
                if (!node) continue;
                if (node.$gobj) {
                  seen += 1;
                  if (looksLikeChatPanel(node.$gobj)) pushUnique(found, node.$gobj);
                }
                const children = node.children || [];
                for (let index = 0; index < children.length; index++) stack.push(children[index]);
              }
            } catch (error) {}
            return { found: found, seen: seen };
          };

          const collectChatPanels = () => {
            const found = [];
            const roots = chatRoots();
            let root = 'groot';
            for (let index = 0; index < roots.length && !found.length; index++) {
              const stack = [roots[index]];
              let visited = 0;
              while (stack.length && visited < CHAT_WALK_LIMIT) {
                const node = stack.pop();
                visited += 1;
                if (!node) continue;
                if (looksLikeChatPanel(node)) { pushUnique(found, node); continue; }
                const count = Number(node.numChildren) || 0;
                for (let child = 0; child < count; child++) {
                  try { stack.push(node.getChildAt(child)); } catch (error) {}
                }
              }
            }
            let seenObjects = roots.length;
            if (!found.length) {
              const fromScene = collectChatPanelsFromScene();
              seenObjects += fromScene.seen;
              for (let index = 0; index < fromScene.found.length; index++) {
                pushUnique(found, fromScene.found[index]);
              }
              if (found.length) root = 'scene';
            }
            // 诊断口径：命中的是哪条路径；两条都没命中时，是「连根都没有」还是「有根没面板」。
            chat.root = found.length ? root : (seenObjects > 0 ? 'no-panel' : 'no-root');
            return found;
          };

          const adoptChatPanels = (panels) => {
            for (let index = 0; index < panels.length; index++) {
              const entry = rememberChat(panels[index], undefined);
              if (!entry) continue;
              // 压外壳（不是压 ui）——见文件头「要隐藏的是外壳」那段。
              try { entry.shell.visible = false; } catch (error) {}
            }
          };

          const hideChatNow = () => {
            let alive = 0;
            for (let index = 0; index < chat.shells.length; index++) {
              const entry = chat.shells[index];
              if (!isAlivePanel(entry.ui)) continue;
              alive += 1;
              // **每拍重新解析一次外壳**：skin 是框架在 `_addUI` 里后补的，
              // 构造那一刻还没有父链，缓存下来的「外壳」可能只是 ui 自己。
              // 一次父链上溯（≤10 跳）代价极小，换来的是「永远压对层」。
              const resolved = resolveChatShell(entry.ui);
              entry.shell = resolved.shell;
              entry.isSkin = resolved.isSkin;
              // 游戏自己会把它显出来（进主城 / 层切换 / 对象池复用），这里负责压回去。
              // 除此之外不做任何事——不碰布局、不碰游戏数据。
              try { entry.shell.visible = false; } catch (error) {}
            }
            chat.shells = chat.shells.filter(
              (entry) => isAlivePanel(entry.ui) && isAlivePanel(entry.shell));
            if (alive > 0) { chat.note = 'chat-hidden'; return; }
            // 缓存全失效（换场景 / 面板被回收）：**下一拍就重扫**——
            // 这一拍 250ms 里屏幕上是空的，用户看到的就是「闪一下」。
            // 降频只用在「一直没有找到过」的情况（下面 scanIn 的赋值）。
            if (chat.scanIn > 0) { chat.scanIn -= 1; return; }
            installChatHook();
            installClassHooks();
            const found = collectChatPanels();
            if (found.length) {
              adoptChatPanels(found);
              chat.note = 'chat-hidden';
              chat.scanIn = 0;
            } else {
              // 没找到：降频重扫（约 2s 一次），别每拍遍历整棵树。
              chat.scanIn = CHAT_SLOW_SCAN_EVERY;
              chat.note = chat.root === 'no-root' ? 'chat-waiting-root' : 'chat-waiting-panel';
            }
          };

          const showChatNow = () => {
            for (let index = 0; index < chat.shells.length; index++) {
              const entry = chat.shells[index];
              if (!entry.restoreTo || !isAlivePanel(entry.shell)) continue;
              try { entry.shell.visible = true; } catch (error) {}
            }
            chat.shells = [];
            chat.note = 'chat-shown';
          };

          // 包一层 NewChatPanel.prototype.onShow：面板刚显示的那一帧就压住，
          // 消掉「先闪一下再被隐藏」。取不到模块/类就等下一轮重扫再试。
          const installChatHook = () => {
            if (chat.hookInstalled) return true;
            const require = resolveRequire();
            if (!require) return false;
            let module = null;
            try { module = require(CHAT_PANEL_MODULE); } catch (error) { return false; }
            const klass = module && (module.NewChatPanel || module.default);
            const proto = klass && klass.prototype;
            if (!proto || typeof proto.onShow !== 'function') return false;
            if (proto.onShow.__lobbyChatHiddenPatched) { chat.hookInstalled = true; return true; }
            const originalOnShow = proto.onShow;
            proto.onShow = function () {
              const result = originalOnShow.apply(this, arguments);
              if (chat.hidden) {
                const panel = this && this.ui;
                if (panel) {
                  // onShow 说明游戏本来就要显示它 —— 恢复时照旧显示。
                  const entry = rememberChat(panel, true);
                  if (entry) { try { entry.shell.visible = false; } catch (error) {} }
                  chat.scanIn = 0;
                  chat.note = 'chat-hidden';
                }
              }
              return result;
            };
            proto.onShow.__lobbyChatHiddenPatched = true;
            chat.hookInstalled = true;
            return true;
          };

          const chatTick = () => {
            if (!chat.hidden) return;
            hideChatNow();
            // 一直找不到面板时，每 ~15s 往页面 console 打一条结构快照（最多 60 条 ≈ 15min）。
            // 引导脚本的 console 桥会把它回传到原生日志（`[js] …`）。
            // 为什么需要：下发往往发生在游戏 bundle 装载之前，那一刻的探针只能看到
            // 「什么都没有」；只有**加载完成后 / 打开聊天之后**的快照才能定性。
            // 上限别设太小——踩过：上限用完后聊天窗口才被打开，正好错过关键那一条。
            if (chat.shells.length) {
              chat.reportIn = 0;
              chat.reports = 0;
            } else if (chat.reports < 60) {
              chat.reportIn += 1;
              if (chat.reportIn >= 60) {
                chat.reportIn = 0;
                chat.reports += 1;
                try { console.log('[enhance] ' + status()); } catch (error) {}
              }
            }
          };

          // ── 结构探针 ──
          // 只在「开着隐藏但一个面板都没命中」时进诊断串：把真实结构一次性报回来，
          // 免得再来回猜是该路径不对、还是指纹太严。常规路径不产生任何开销。
          const CHAT_MARKERS = [
            ['m_chatList', 'chatList'],
            ['m_inputComp', 'inputComp'],
            ['m_input', 'input'],
            ['m_btnSend', 'btnSend'],
            ['m_chatItemList', 'chatItemList']    // 主城聊天框 MainPanelChat
          ];

          // 每个标记给一个字符：M = 成员变量命中，C = getChild 命中，- = 没有。
          const markerFlags = (object) => {
            let flags = '';
            for (let index = 0; index < CHAT_MARKERS.length; index++) {
              const pair = CHAT_MARKERS[index];
              let flag = '-';
              try {
                if (object[pair[0]]) flag = 'M';
                else if (typeof object.getChild === 'function' && object.getChild(pair[1])) flag = 'C';
              } catch (error) {}
              flags += flag;
            }
            return flags;
          };

          // 尽量给一个可读的名字：FairyGUI 的包内元件名 → 生成类的 URL → cc 节点名。
          const nameOf = (object) => {
            let name = '';
            try {
              if (object.packageItem && object.packageItem.name) name = object.packageItem.name;
              else if (object.constructor && object.constructor.URL) name = object.constructor.URL;
              else if (object.node && object.node.name) name = object.node.name;
              else if (object.name) name = object.name;
            } catch (error) {}
            return name || '?';
          };

          const describeObject = (object) => nameOf(object) + ':' + markerFlags(object);

          const probeChat = () => {
            const marks = CHAT_MARKERS.map(() => 0);
            const near = [];
            // 名字带 chat 的对象：屏幕上真有个聊天 UI 时，无论指纹怎么判都会落在这里。
            const chatNames = [];
            let visited = 0;
            let hits = 0;
            let tops = '';
            const roots = chatRoots();

            // 环境标志。这一组是「排到最后」时最需要的：判「同一个 window 里游戏到底
            // 装起来没有」。`canvas` 在而 `fgui` 不在 ⇒ 同文档、只是还没加载完；
            // 两个都不在 ⇒ 我们跟游戏根本不是同一个文档 / 世界。
            const env = [];
            const flag = (name, value) => { env.push(name + '=' + (value ? 1 : 0)); };
            const fgui = window.fgui;
            flag('fgui', !!fgui);
            flag('groot', !!(fgui && fgui.GRoot));
            flag('inst', !!(fgui && fgui.GRoot && fgui.GRoot._inst));
            flag('cc', !!window.cc);
            let scene = null;
            try {
              const director = window.cc && window.cc.director;
              scene = director && director.getScene && director.getScene();
            } catch (error) {}
            flag('scene', !!scene);
            flag('req', typeof window.__require === 'function' || typeof window.require === 'function');
            flag('game', !!window.__IOS2_GAME_INSTANCE__);
            flag('top', window === window.top);
            let canvas = 0;
            try { canvas = document.getElementById('GameCanvas') ? 1 : 0; } catch (error) {}
            flag('canvas', canvas);
            let readyState = '?';
            try { readyState = String(document.readyState); } catch (error) {}
            let href = '?';
            try {
              href = String(window.location.href);
              if (href.length > 44) href = href.slice(0, 44);
            } catch (error) {}

            const inspect = (object) => {
              if (!object) return;
              const flags = markerFlags(object);
              let count = 0;
              for (let index = 0; index < flags.length; index++) {
                if (flags[index] !== '-') { marks[index] += 1; count += 1; }
              }
              if (count === CHAT_MARKERS.length) hits += 1;
              // 「差一点就命中」的对象最有价值：说明指纹太严，或结构变了。
              else if (count > 0 && near.length < 3) near.push(describeObject(object));
              if (chatNames.length < 6) {
                let raw = '';
                try {
                  raw = String((object.packageItem && object.packageItem.name) || '') +
                    ' ' + String((object.node && object.node.name) || '') +
                    ' ' + String((object.constructor && object.constructor.URL) || '');
                } catch (error) {}
                if (raw.toLowerCase().indexOf('chat') >= 0) chatNames.push(describeObject(object));
              }
            };

            try {
              for (let index = 0; index < roots.length; index++) {
                const top = roots[index];
                const kids = Number(top.numChildren) || 0;
                for (let child = 0; child < kids && child < 6; child++) {
                  try {
                    tops += (tops ? ',' : '') + describeObject(top.getChildAt(child)).split(':')[0];
                  } catch (error) {}
                }
                const stack = [top];
                while (stack.length && visited < CHAT_WALK_LIMIT) {
                  const node = stack.pop();
                  visited += 1;
                  if (!node) continue;
                  inspect(node);
                  const count = Number(node.numChildren) || 0;
                  for (let child = 0; child < count; child++) {
                    try { stack.push(node.getChildAt(child)); } catch (error) {}
                  }
                }
              }
            } catch (error) {}

            // cc 侧：有多少 fgui 对象挂在场景里（第二条路径的可达性证据）。
            let sceneNodes = 0;
            let sceneGobj = 0;
            if (scene) {
              try {
                const stack = [scene];
                while (stack.length && sceneNodes < CHAT_WALK_LIMIT) {
                  const node = stack.pop();
                  sceneNodes += 1;
                  if (node && node.$gobj) {
                    sceneGobj += 1;
                    inspect(node.$gobj);
                  }
                  const children = (node && node.children) || [];
                  for (let index = 0; index < children.length; index++) stack.push(children[index]);
                }
              } catch (error) {}
            }

            const require = resolveRequire();
            let moduleOk = 0;
            try { moduleOk = require && require(CHAT_PANEL_MODULE) ? 1 : 0; } catch (error) {}

            // 界面清单：GRoot 唯一子节点就是 Layers，层的子节点才是窗口。
            // 这一项用来回答「屏幕上到底有什么」——命中 0 时先看清单里有没有那个窗口。
            let inventory = '';
            try {
              let layersNode = null;
              for (let index = 0; index < roots.length && !layersNode; index++) {
                const top = roots[index];
                const kids = Number(top.numChildren) || 0;
                for (let child = 0; child < kids; child++) {
                  const node = top.getChildAt(child);
                  if (node && nameOf(node) === 'Layers') { layersNode = node; break; }
                }
              }
              if (layersNode) {
                const layerCount = Number(layersNode.numChildren) || 0;
                inventory = 'inv L=' + layerCount;
                for (let index = 0; index < layerCount && index < 10; index++) {
                  const layer = layersNode.getChildAt(index);
                  const count = Number(layer && layer.numChildren) || 0;
                  if (count === 0) continue;
                  let kids = '';
                  for (let child = 0; child < count && child < 5; child++) {
                    kids += (kids ? ',' : '') + nameOf(layer.getChildAt(child));
                  }
                  inventory += ' #' + index + ':' + count + '(' + kids + ')';
                }
              }
            } catch (error) {}
            if (chatNames.length) inventory += ' chatObjs=' + chatNames.join(' ');

            const text = 'probe ' + env.join(' ') +
              ' rs=' + readyState + ' href=' + href +
              ' roots=' + roots.length +
              ' walk=' + visited +
              ' hit=' + hits +
              ' mark=' + marks.join('/') +
              ' near=' + (near.join(' ') || '-') +
              ' tops=' + (tops || '-') +
              ' ccwalk=' + sceneNodes + '/' + sceneGobj +
              ' mod=' + moduleOk +
              (inventory ? ' ' + inventory : '');
            return text.length > 620 ? text.slice(0, 620) + '…' : text;
          };

          // 显隐开关（幂等）。关掉时停掉轮询，不留空转定时器。
          const setChatHidden = (hidden) => {
            const next = !!hidden;
            if (next === chat.hidden) return status();
            chat.hidden = next;
            if (next) {
              chat.scanIn = 0;
              hideChatNow();
              installChatHook();
              installClassHooks();
              // 关键：抢在「建窗口 → 刷新」那段同步流程前面把守门挂上。
              startHookPoll();
              if (!chat.timer) chat.timer = setInterval(chatTick, CHAT_TICK_MS);
            } else {
              stopHookPoll();
              if (chat.timer) { clearInterval(chat.timer); chat.timer = 0; }
              showChatNow();
            }
            return status();
          };

          // 「开着隐藏但一个面板都没命中」时自动附上结构探针——一次截图就能定位。
          const status = () => {
            let text = 'v=' + AGENT_VERSION +
              ' running=' + (state.running ? 1 : 0) +
              ' speed=' + state.speed +
              ' hook=' + (state.hookInstalled ? 1 : 0) +
              ' panel=' + (state.panel ? 1 : 0) +
              ' chat=' + (chat.hidden ? 1 : 0) + '/' + chat.shells.length +
              ' skin=' + chat.shells.filter((entry) => entry.isSkin).length +
              '/' + chat.shells.length +
              ' root=' + chat.root +
              ' mh=' + chat.classHooks +
              ' vg=' + chat.visibleGuards +
              ' note=' + state.note + ' chatNote=' + chat.note;
            if (chat.hidden && !chat.shells.length) {
              text += ' ' + probeChat();
            }
            return text;
          };

          const apply = (config) => {
            const next = config || {};
            state.speed = clampSpeed(next.speed);
            const enabled = !!next.enabled;

            // 聊天窗口显隐与十殿加速互相独立：先处理，免得被下面的早退吃掉。
            setChatHidden(!!next.hideChat);

            if (enabled === state.running) {
              // 只改倍率：钩子已经在了，现场重扫一次面板即可（没面板时
              // 下一次 onShow 会读到新倍率）。
              if (enabled) {
                applyLive();
                state.note = state.panel ? 'running-live' : state.note;
              }
              return status();
            }

            state.running = enabled;
            if (enabled) {
              state.retries = 0;
              const hooked = installHook();
              const applied = applyLive();
              if (hooked) {
                state.note = applied ? 'running-live' : 'running-hook';
              } else {
                scheduleRetry();
              }
            } else {
              stop();
              state.note = 'stopped';
            }
            return status();
          };

          window.__LOBBY_ENHANCE__ = {
            apply: apply,
            stop: () => { state.running = false; stop(); state.note = 'stopped'; return status(); },
            chat: setChatHidden,
            probe: probeChat,
            status: status
          };
        })();
        """
    }()
}
