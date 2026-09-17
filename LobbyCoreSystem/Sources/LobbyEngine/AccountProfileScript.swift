import Foundation
import LobbyDomain

// MARK: - 账号资料 · 页面侧只读探针
//
// 目的：把「这个账号在游戏里长什么样」搬回原生，供账号卡显示真实头像 /
// 游戏内昵称 / 等级战力。
//
// 数据源来自**线上 bundle 反解**（16MB 明文，`ServerData` 模块 @9676816）：
//
//   createServerData() { … i.SERVER_DATA = new c; i.ROLE = i.SERVER_DATA.role;
//                        globalThis.SERVER_DATA = …; globalThis.ROLE = i.ROLE; }
//
// 也就是说 `window.ROLE` 是**游戏自己挂的**，登录完成、服务端数据到位后就有。
// `RoleDataView` 模块的 mobx 字段清单（@8995214）里可直接用的是：
//   `headImg` `name` `power` `vip` `levelId`（= 角色等级）…
// `headImg` 形态：微信 `thirdwx.qlogo.cn/mmopen/vi_32/<hash>/132`；
// QQ `thirdqq.qlogo.cn`（`HSUtils._appendQQAvatarCacheBuster` 专门处理）；
// 自建 CDN `mars-face.hortorgames.com`。同族字段还有 `avatarFrame`（头像框），
// 这里不上报——账号卡上没地方画。
//
// ⚠️ 本探针**只读**：不 patch 任何游戏对象、不写 `ROLE`、不发 socket。
//   （对比参考的那两份第三方「换头像」脚本：明文那份是本地伪造成功
//   `RoleService.changeHeadImg` 返回 code:0 + 改写 `ROLE.headImg` 成假 URL，
//   会让账号数据与服务端不一致——我们不做这种事。）
//
// ⚠️ 时机：`window.ROLE` 要等**登录 + 服务端数据到位**，比 `__require` 还晚，
//   而且冷缓存下 game bundle 下载就要几十秒。所以用**有界轮询**等它：
//   400ms × 300 次（≈2min）快档，命中或超时后转 5s 慢档常驻。
//   慢档不是浪费——换头像 / 切角色之后 `ROLE` 会变，慢档负责把变化捞回来；
//   每拍只是三次属性读取，代价可忽略。
//
// ⚠️ 幂等：以 `window.__LOBBY_PROFILE__` 为哨兵。`atDocumentStart` 注入在池化
//   实例重新导航时会再执行一次，不挡就会叠定时器。
public enum AccountProfileScript {
    /// 代理脚本版本号。**每次改 `agent` 就 +1**（诊断串里带 `v=`）。
    public static let agentVersion = "1"

    /// 快档轮询间隔 / 上限（等待登录完成）。
    private static let fastIntervalMs = 400
    private static let fastMaxTries = 300
    /// 慢档轮询间隔（命中后的常驻巡检，负责换头像 / 切角色的变化）。
    private static let slowIntervalMs = 5000

    /// 代理脚本本体（`atDocumentStart` 注入，只注入主框架）。
    public static let agent: String = {
        let agentVersion = Self.agentVersion
        let channel = LobbyConfiguration.webChannelName
        return """
        (() => {
          if (window.__LOBBY_PROFILE__) return;

          const AGENT_VERSION = '\(agentVersion)';
          const CHANNEL = '\(channel)';
          const FAST_INTERVAL_MS = \(fastIntervalMs);
          const FAST_MAX_TRIES = \(fastMaxTries);
          const SLOW_INTERVAL_MS = \(slowIntervalMs);

          const state = {
            timer: 0,
            mode: 'fast',
            tries: 0,
            reports: 0,
            lastKey: '',
            note: 'idle',
            loggedReady: false,
            loggedGiveUp: false
          };

          // 非负数兜底：服务端字段缺失 / 是字符串时都不要把 NaN 送过桥。
          const num = (value) => {
            const parsed = Number(value);
            if (!isFinite(parsed) || parsed < 0) return 0;
            return Math.floor(parsed);
          };

          // 取角色数据。两条**互相独立**的路径，任一命中即可：
          // ① 游戏自己挂在 globalThis 上的 ROLE（正常路径）；
          // ② 游戏自己的模块注册表 `__require('ServerData').ROLE`（兜底，
          //    兼容层接管 __require 时它内部也是读 window.ROLE，同样安全）。
          // ⚠️ 绝不包装 / 改写 `__require`——那会断掉各 bundle 之间串起来的
          //   父 require 链，表现是卡在加载场景。
          const readRole = () => {
            try {
              const direct = window.ROLE;
              if (direct && direct.headImg) return direct;
            } catch (error) {}
            try {
              const require = typeof window.__require === 'function'
                ? window.__require
                : (typeof window.require === 'function' ? window.require : null);
              if (require) {
                const module = require('ServerData');
                const role = module && module.ROLE;
                if (role && role.headImg) return role;
              }
            } catch (error) {}
            return null;
          };

          const report = () => {
            const role = readRole();
            if (!role) { state.note = 'waiting-role'; return false; }
            const headImg = String(role.headImg || '');
            if (!headImg) { state.note = 'waiting-headimg'; return false; }

            const name = String(role.name == null ? '' : role.name);
            const power = num(role.power);
            const level = num(role.levelId);
            const vip = num(role.vip);
            // 去重键：整份可用资料一起比。任一字段变了才上报，
            // 免得慢档每 5s 把同一条消息刷进原生日志。
            const key = headImg + '|' + name + '|' + power + '|' + level + '|' + vip;
            if (key === state.lastKey) { state.note = 'unchanged'; return true; }
            // ⚠️ `lastKey` 必须在**投递成功之后**才提交。先提交再发的话，
            // 一旦 postMessage 抛异常（原生 handler 被摘掉 / 页面正在被拆），
            // 这条资料就永远不会重发——表现是「这个账号一直没有头像」，
            // 而且怎么重启都不好，因为去重键还记着它「已经报过」了。
            try {
              window.webkit.messageHandlers[CHANNEL].postMessage({
                type: 'avatar',
                headImg: headImg,
                name: name,
                power: power,
                level: level,
                vip: vip
              });
            } catch (error) {
              state.note = 'post-failed';
              return false;
            }
            state.lastKey = key;
            state.reports += 1;
            state.note = 'reported';
            if (!state.loggedReady) {
              state.loggedReady = true;
              // 只打一条：账号卡出不来时，这一条就能区分
              // 「没登录完（waiting-role）」和「已上报但原生没存」。
              try {
                console.log('[profile] v=' + AGENT_VERSION + ' first report: level=' + level +
                            ' power=' + power + ' headImg=' + headImg.length + ' chars');
              } catch (error) {}
            }
            return true;
          };

          const toSlow = () => {
            if (state.timer) { clearInterval(state.timer); state.timer = 0; }
            state.mode = 'slow';
            state.timer = setInterval(report, SLOW_INTERVAL_MS);
            report();
          };

          const tick = () => {
            state.tries += 1;
            // 命中就立刻降频：资料已经拿到，之后只需要盯变化。
            if (report()) { toSlow(); return; }
            if (state.tries >= FAST_MAX_TRIES) {
              if (!state.loggedGiveUp) {
                state.loggedGiveUp = true;
                try {
                  console.log('[profile] v=' + AGENT_VERSION + ' gave up waiting ROLE after ' +
                              state.tries + ' tries; switching to slow watch');
                } catch (error) {}
              }
              toSlow();
            }
          };

          state.timer = setInterval(tick, FAST_INTERVAL_MS);
          tick();

          // 只读诊断入口，Web Inspector 里可直接看：
          //   __LOBBY_PROFILE__.status()  →  'v=1 mode=slow tries=5 reports=1 note=unchanged'
          window.__LOBBY_PROFILE__ = {
            version: AGENT_VERSION,
            probe: report,
            status: function () {
              return 'v=' + AGENT_VERSION +
                ' mode=' + state.mode +
                ' tries=' + state.tries +
                ' reports=' + state.reports +
                ' note=' + state.note;
            }
          };
        })();
        """
    }()
}
