// 「玩家ID（显示 + 一键复制）」的假环境测试。
//
//   AGENT_JS=/tmp/recon/agent.js node player-id-harness.mjs
//
// 搭的是**假的玩家信息弹窗**：原型上有 onShow / onShown / onFixShow 生命周期，
// 实例上有 `ui.m_playerid` / `ui.m_serverName` / `ui.m_btnCopyID`（初始都是隐藏的，
// 这正是官方客户端的样子），以及 `model.get('ROLE_INFO')` 提供的 roleId。
// 原生侧的 `webkit.messageHandlers.ios2Game` 收 clipboard 消息 —— 断言「复制」这条
// 链路真的落到了宿主（而不是只调了个假函数）。
import fs from 'node:fs';

const AGENT_PATH = process.env.AGENT_JS || '/tmp/recon/agent.js';
// 抽出来的 agent 里插值还没替换（Swift 侧才会替换）——这里补上通道名。
const agentSource = fs
  .readFileSync(AGENT_PATH, 'utf8')
  .replace(/\\\(channel\)/g, 'ios2Game');

const noop = () => {};
global.window = global;
const clipboardMessages = [];
global.webkit = {
  messageHandlers: {
    ios2Game: { postMessage: (message) => clipboardMessages.push(message) },
  },
};
global.document = {
  readyState: 'complete', hidden: false,
  addEventListener: noop, removeEventListener: noop, getElementById: () => null,
  createElement: () => ({ style: {}, parentNode: null, value: '', setAttribute: noop,
                          select: noop, appendChild: noop }),
  execCommand: () => true,          // 兜底路径用
  body: { appendChild: noop, removeChild: noop },
};
global.addEventListener = noop;
global.removeEventListener = noop;
global.location = { search: '', href: 'https://example.invalid/' };
global.performance = { now: () => Date.now() };

// ── 假 UI 节点：`node.active` 就是可见性（参考实现按 _node/node/自身 三条路找） ──
const node = (active) => ({ active: active, visible: active });
function makeUI() {
  const divider = node(false);
  return {
    m_playerid: { text: '', node: node(false) },
    m_serverName: { node: node(false), parent: { getChild: (name) => (name === 'n101' ? divider : null) } },
    m_btnCopyID: {
      node: node(false),
      clicked: null,
      clearClick() { this.clicked = null; this.cleared = (this.cleared || 0) + 1; },
      onClick(handler) { this.clicked = handler; },
    },
    divider: divider,
  };
}

// ── 假弹窗类 ──
const ROLE_ID = 12345678;
function PlayerInfoDialog() {
  this.ui = makeUI();
  this.model = { get: (key) => (key === 'ROLE_INFO' ? { roleId: ROLE_ID } : null) };
}
PlayerInfoDialog.prototype.onShow = function () { return 'shown'; };
PlayerInfoDialog.prototype.onShown = function () { return 'shown2'; };
PlayerInfoDialog.prototype.onFixShow = function () { return 'fixshow'; };

// ── 假模块表 + 假飘字 ──
const tips = [];
let modules = {
  'PlayerInfoDialog': { PlayerInfoDialog: PlayerInfoDialog },
  'TipsManager': { SHOW_TIP: (text) => tips.push(text) },
  'consts': { ModelConst: { ROLE_INFO: 'ROLE_INFO' } },
};
global.__require = (id) => {
  if (!modules[id]) throw new Error('module not found: ' + id);
  return modules[id];
};

eval(agentSource);
const api = global.__LOBBY_ENHANCE__;

const failures = [];
const expect = (ok, label) => {
  if (!ok) failures.push(label);
  console.log((ok ? 'PASS' : 'FAIL') + ' - ' + label);
};
const pidOf = (text) => (text.split(' pid=')[1] || '').split(' note=')[0];
const apply = (config) => api.apply(Object.assign(
  { enabled: false, speed: 100, hideChat: false, uiSpeedEnabled: false, uiSpeed: 3,
    fpsDisplay: false, battleStats: false, playerID: false }, config));

(async () => {
  const originalOnShow = PlayerInfoDialog.prototype.onShow;

  // ① 开启即挂生命周期（模块已可解析）
  apply({ playerID: true });
  expect(PlayerInfoDialog.prototype.onShow.__lobbyPidPatched === true,
         '开启 → onShow 已被包装');
  expect(PlayerInfoDialog.prototype.onShown.__lobbyPidPatched === true, 'onShown 同时被包装');
  expect(pidOf(api.status()).startsWith('1/'), 'status 报 pid=1');

  // ② 打开弹窗 → 三个节点放出来 + 填 ID + 分隔线
  const dialog = new PlayerInfoDialog();
  expect(dialog.onShow(), '被包装的 onShow 仍执行原逻辑（返回值原样透出）');
  expect(dialog.ui.m_playerid.text === 'ID:' + ROLE_ID,
         `m_playerid 填成 ID:<roleId>（现在「${dialog.ui.m_playerid.text}」）`);
  expect(dialog.ui.m_playerid.node.active === true, 'm_playerid 已显示');
  expect(dialog.ui.m_serverName.node.active === true, 'm_serverName 已显示');
  expect(dialog.ui.m_btnCopyID.node.active === true, '复制按钮已显示');
  expect(dialog.ui.divider.active === true, 'm_serverName.parent 下 n101 分隔线已显示');

  // ③ 复制：走原生通道（消息落到宿主）
  expect(typeof dialog.ui.m_btnCopyID.clicked === 'function', '复制按钮已重绑点击');
  dialog.ui.m_btnCopyID.clicked();
  expect(clipboardMessages.length === 1 && clipboardMessages[0].type === 'clipboard',
         '点了复制 → 向宿主发 type:clipboard 消息');
  expect(clipboardMessages[0].text === String(ROLE_ID), '消息里带的就是这个弹窗的 roleId');
  expect(tips[tips.length - 1] === '复制成功', '走原生路径时飘字「复制成功」');
  expect(api.status().includes('pNote=pid-copied'), 'status 记 pid-copied');

  // ④ 桥不可用 → 退回 execCommand 兜底
  const bridge = global.webkit;
  delete global.webkit;
  dialog.ui.m_btnCopyID.clicked();
  expect(clipboardMessages.length === 1, '桥不可用时不发消息');
  expect(api.status().includes('pNote=pid-copied-fallback'), 'status 记 pid-copied-fallback（兜底成功）');
  global.webkit = bridge;

  // ⑤ 每次打开都同步（第二次打开同一个实例也填）
  dialog.ui.m_playerid.text = '';
  dialog.onShown();
  expect(dialog.ui.m_playerid.text === 'ID:' + ROLE_ID, '再次显示（onShown）也会重新同步');

  // ⑥ 关闭 → 原型还原
  apply({ playerID: false });
  expect(PlayerInfoDialog.prototype.onShow === originalOnShow, '关闭 → onShow 还原为原函数');
  expect(pidOf(api.status()).startsWith('0/'), 'status 报 pid=0');

  // ⑦ 模块还没加载（还没打开过玩家信息）：报 waiting，不抛错；模块出现后被轮询装上
  modules = {};
  apply({ playerID: true });
  expect(api.status().includes('pNote=pid-waiting-module'), '模块缺失 → pNote=pid-waiting-module');
  expect(PlayerInfoDialog.prototype.onShow === originalOnShow, '模块缺失时不乱改原型');
  modules = { 'PlayerInfoDialog': { PlayerInfoDialog: PlayerInfoDialog } };
  await new Promise((resolve) => setTimeout(resolve, 1300));    // 等一次 1s 轮询
  expect(PlayerInfoDialog.prototype.onShow.__lobbyPidPatched === true,
         '模块出现后被轮询装上钩子（第一次打开弹窗前开开关也能生效）');

  apply({ playerID: false });
  console.log(failures.length ? `\n${failures.length} 项失败：\n- ${failures.join('\n- ')}` : '\n全部通过');
  process.exit(failures.length ? 1 : 0);
})();
