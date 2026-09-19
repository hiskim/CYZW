// 引擎级「游戏加强」项的假环境测试（UI 加速 / 帧率角标）。
//
//   AGENT_JS=/tmp/recon/agent.js node engine-speed-harness.mjs
//
// agent.js 的导出方式见 SKILL.md §5.1（Python 抽 """…""" + 替换 \(插值)）。
// 与 agent-harness.mjs 的区别：那个搭的是 FairyGUI 面板树，这个搭的是假 **cc 引擎**，
// 用来测「改引擎全局状态 / 读引擎帧节奏」这类功能（时间倍率、帧率角标、director 包装）。
//
// 假引擎照抄真实口径：
//   · ios2-web-cocos2d.js  cc.Scheduler.update = function (t) { 1 !== this._timeScale && (t *= this._timeScale); … }
//     → 断言直接看 `_timeScale`，不用猜；
//   · cc.game._runMainLoop 每出一帧调一次 `cc.director.mainLoop`（30 档是隔帧才调）
//     → 帧率钩子就是「手动敲 N 次 mainLoop + 推虚拟时钟，看读数」。
import fs from 'node:fs';

const AGENT_PATH = process.env.AGENT_JS || '/tmp/recon/agent.js';
const agentSource = fs.readFileSync(AGENT_PATH, 'utf8');

// ── 可控时钟：帧率 = 次数 / 时间，必须能自己推时间轴（别真 sleep 到点）──
let fakeNow = 1_000_000;
Date.now = () => fakeNow;

// ── 极简 DOM（帧率角标要 createElement / body.appendChild / removeChild）──
const noop = () => {};
const appended = [];
global.window = global;
global.document = {
  readyState: 'complete',
  hidden: false,
  addEventListener: noop,
  removeEventListener: noop,
  getElementById: () => null,
  createElement: () => ({ style: {}, parentNode: null, textContent: '', setAttribute: noop }),
  body: {
    appendChild(node) { node.parentNode = this; appended.push(node); },
    removeChild(node) { node.parentNode = null; },
  },
};
global.addEventListener = noop;
global.removeEventListener = noop;
global.location = { search: '', href: 'https://example.invalid/' };
global.performance = { now: () => fakeNow };

function makeScheduler() {
  return {
    _timeScale: 1,
    setTimeScale(value) { this._timeScale = value; },
    getTimeScale() { return this._timeScale; },
    update(t) { if (this._timeScale !== 1) t = t * this._timeScale; return t; },
  };
}
const scheduler = makeScheduler();
const frameRateConfig = { frameRate: 60 };
global.cc = {
  game: { config: frameRateConfig },
  director: {
    getScheduler: () => scheduler,
    getScene: () => null,
    mainLoop() { return 'frame'; },
  },
};

eval(agentSource);
const api = global.__LOBBY_ENHANCE__;

const failures = [];
const expect = (ok, label) => {
  if (!ok) failures.push(label);
  console.log((ok ? 'PASS' : 'FAIL') + ' - ' + label);
};
const uiOf = (text) => (text.split(' ui=')[1] || '').split(' note=')[0];
const fpsOf = (text) => (text.split(' fps=')[1] || '').split(' hk=')[0];
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// 下发口径按 apply() 的真实字段名改（见 GameEnhancementScript.apply）。
const apply = (config) => api.apply(Object.assign(
  { enabled: false, speed: 100, hideChat: false, uiSpeedEnabled: false, uiSpeed: 3, fpsDisplay: false },
  config));

(async () => {
  console.log('初始 status:', api.status());

  // ── ① UI 加速（引擎全局时间倍率）──
  apply({ uiSpeedEnabled: true, uiSpeed: 4 });
  expect(scheduler._timeScale === 4, '开启 → scheduler._timeScale = 4');
  expect(scheduler.update.__lobbyUISpeedWrapped === true, '开启 → update 已被包装');
  expect(uiOf(api.status()).startsWith('1x4'), 'status 报 ui=1x4');

  scheduler._timeScale = 1;                                  // 游戏自己改回去
  scheduler.update(0.016);                                   // 走一帧
  expect(scheduler._timeScale === 4, '游戏改回后被下一帧顶回 4');

  apply({ uiSpeedEnabled: true, uiSpeed: 1.5 });
  expect(scheduler._timeScale === 1.5, '半档倍率生效（1.5）');
  apply({ uiSpeedEnabled: true, uiSpeed: 99 });
  expect(scheduler._timeScale === 10, '越界 99 → 钳到上界 10');
  apply({ uiSpeedEnabled: true, uiSpeed: 'abc' });
  expect(scheduler._timeScale === 3, '脏值 → 回默认档 3');

  const originalUpdate = scheduler.update.__lobbyUISpeedOriginal;
  apply({ uiSpeedEnabled: false });
  expect(scheduler._timeScale === 1, '关闭 → 还原接管前的倍率');
  expect(scheduler.update === originalUpdate, '关闭 → update 解包回原函数');
  scheduler.update(0.016);
  expect(scheduler._timeScale === 1, '关闭后不再改写倍率');
  expect(uiOf(api.status()).startsWith('0x'), 'status 报 ui=0');

  // ── ② 帧率角标 ──
  const originalMainLoop = global.cc.director.mainLoop;
  fakeNow += 5000;
  apply({ fpsDisplay: true });
  expect(global.cc.director.mainLoop.__lobbyFpsWrapped === true, '开启 → cc.director.mainLoop 已被包装');
  expect(appended.some((node) => node.id === 'lobby-fps-badge'), '开启 → 角标已插入 body');
  expect(fpsOf(api.status()).startsWith('1:'), 'status 报 fps=1');

  // 敲 60 帧 + 推 1s 虚拟时间 → 下一次采样拍读到 60/60。
  const badge = appended.find((node) => node.id === 'lobby-fps-badge');
  for (let index = 0; index < 60; index += 1) global.cc.director.mainLoop();
  fakeNow += 1000;
  await sleep(700);                                           // 等一次 500ms 采样拍
  expect(badge.textContent === 'FPS 60/60', `读数口径 = 「实测/目标」（现在读 ${badge.textContent}）`);
  expect(fpsOf(api.status()).startsWith('1:60/60'), `status 报 1:60/60（现在 ${fpsOf(api.status())}）`);

  // 目标档位改 30：斜杠后半段跟着走（正是「帧率设置生效没有」要看的地方）。
  frameRateConfig.frameRate = 30;
  for (let index = 0; index < 30; index += 1) global.cc.director.mainLoop();
  fakeNow += 1000;
  await sleep(700);
  expect(badge.textContent.endsWith('/30'), `目标跟随 cc.game.config.frameRate（现在读 ${badge.textContent}）`);

  // 页面隐藏时不采样（引擎停了，掉到 0 会误导）。
  global.document.hidden = true;
  const valueBeforeHide = badge.textContent;
  fakeNow += 2000;
  await sleep(700);
  expect(badge.textContent === valueBeforeHide, '页面隐藏时角标停在最后读数');
  global.document.hidden = false;

  apply({ fpsDisplay: false });
  expect(global.cc.director.mainLoop === originalMainLoop, '关闭 → mainLoop 解包回原函数');
  expect(!appended.some((node) => node.id === 'lobby-fps-badge' && node.parentNode), '关闭 → 角标已从 body 摘掉');
  expect(fpsOf(api.status()).startsWith('0:'), 'status 报 fps=0');

  // ── ③ 引导路径：文档起点注入时 cc 还不存在（真机常态）──
  delete global.cc;
  apply({ uiSpeedEnabled: true, uiSpeed: 5 });
  expect(api.status().includes('uiNote=ui-waiting-engine'), '引擎未就绪 → ui-waiting-engine');

  const lateScheduler = makeScheduler();
  setTimeout(() => {
    global.cc = { game: { config: { frameRate: 60 } },
                  director: { getScheduler: () => lateScheduler, mainLoop() {} } };
  }, 60);
  await sleep(500);
  expect(lateScheduler._timeScale === 5, '引擎出现后被 20ms 引导轮询接管（_timeScale=5）');
  const status = api.status();
  expect(status.includes('sched=1') && status.includes('wrap=1'), '引导后 sched=1 / wrap=1');
  expect(status.includes('uiNote=ui-running'), '引导后 uiNote=ui-running');

  console.log(failures.length ? `\n${failures.length} 项失败：\n- ${failures.join('\n- ')}` : '\n全部通过');
  process.exit(failures.length ? 1 : 0);
})();
