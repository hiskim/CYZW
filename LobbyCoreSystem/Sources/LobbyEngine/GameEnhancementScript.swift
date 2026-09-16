import Foundation

// MARK: - 游戏加强 · 页面侧代理
//
// 与 `InputSyncScript` 同策略：代理脚本在 `atDocumentStart` **预注入**每个实例
// （WKUserScript 只能在导航时注入、运行时无法追加），运行时只推配置——否则
// 「实例已经跑起来才打开开关」就只能等下一次导航，用户看到的是「点了没反应」。
//
// 目前只有一项加强：**十殿加速**。原理与第三方脚本（猫助手）完全一致——
// 改写 `NightmareBattlePanel.DEFAULT_TIMESCALE`，让十殿试炼的战斗动画整体加速，
// 只改画面节奏、不改战斗结算：
//
// 1. **钩子**：`__require('NightmareBattlePanel')` 取到类，包一层
//    `prototype.onShow`；每次 onShow 之后按当前开关把 `DEFAULT_TIMESCALE`
//    改成目标倍率（关闭时还原原始值）。
// 2. **现场**：已经在战斗里的面板不会再触发 onShow，所以在场景树里找活的
//    `NightmareBattlePanel` 组件直接改 `DEFAULT_TIMESCALE`。
//    这一路**不依赖 `__require`**（只用 `cc.director.getScene()`），所以即使模块
//    还没加载，玩家当前这一场战斗也能立刻加速——钩子随后由轮询补上，负责后续场次。
//
// ⚠️ `window.__require` 是**游戏自己的**跨 bundle 模块注册表（不是宿主符号，
// 见 `ios2-script-runtime.js` 的注释），文档起点注入时它还不存在，且
// `NightmareBattlePanel` 要等玩家进十殿才会被加载。所以这里用**有界轮询**
// 等它就绪（500ms × 120 ≈ 60s），而不是一次性失败。
//
// ⚠️ 幂等：整段以 `window.__LOBBY_ENHANCE__` 是否存在作为哨兵，
// 重复注入（池化实例重新导航）不会叠加钩子。
public enum GameEnhancementScript {
    /// 十殿面板的模块名 / 组件名（与游戏侧一致，勿改）。
    public static let nightmarePanelName = "NightmareBattlePanel"

    /// 推一次配置（幂等，可重复调用）。
    /// 返回值是页面侧的诊断串：`running=1 speed=100 hook=1 panel=1 note=...`；
    /// 代理不存在时返回 `no-handler`（页面未装代理脚本）。
    public static func apply(enabled: Bool, speed: Int) -> String {
        "window.__LOBBY_ENHANCE__ ? window.__LOBBY_ENHANCE__.apply(" +
            "{enabled:\(enabled ? "true" : "false"),speed:\(speed)}) : 'no-handler'"
    }

    /// 只读诊断：当前页面侧加强状态。
    public static func status() -> String {
        "window.__LOBBY_ENHANCE__ ? window.__LOBBY_ENHANCE__.status() : 'no-handler'"
    }

    /// 代理脚本本体（`atDocumentStart` 注入，只注入主框架）。
    public static let agent: String = {
        let panelName = nightmarePanelName
        return """
        (() => {
          if (window.__LOBBY_ENHANCE__) return;

          const PANEL_NAME = '\(panelName)';
          const RETRY_INTERVAL_MS = 500;
          const MAX_RETRIES = 120;
          const MIN_SPEED = 1;
          const MAX_SPEED = 1000;
          const DEFAULT_SPEED = 100;

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

          const status = () => 'running=' + (state.running ? 1 : 0) +
            ' speed=' + state.speed +
            ' hook=' + (state.hookInstalled ? 1 : 0) +
            ' panel=' + (state.panel ? 1 : 0) +
            ' note=' + state.note;

          const apply = (config) => {
            const next = config || {};
            state.speed = clampSpeed(next.speed);
            const enabled = !!next.enabled;

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
            status: status
          };
        })();
        """
    }()
}
