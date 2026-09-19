// 引擎级「游戏加强」项的假环境测试（以 UI 加速 / 全局时间倍率为例）。
//
//   AGENT_JS=/tmp/recon/agent.js node engine-speed-harness.mjs
//
// agent.js 的导出方式见 SKILL.md §5.1（Python 抽 """…""" + 替换 \(插值)）。
// 与 agent-harness.mjs 的区别：那个搭的是 FairyGUI 面板树，这个搭的是假 **cc 引擎**，
// 用来测「改引擎全局状态」这类功能（时间倍率、帧率、director 包装）。
//
// 假引擎照抄 ios-cocos/cocos-project/src/cocos2d-jsb.07adf.js 的真实口径：
//   cc.Scheduler.prototype.update = function (t) { 1 !== this._timeScale && (t *= this._timeScale); … }
// 所以断言可以直接看 `_timeScale`，不需要猜。
import fs from 'node:fs';

const AGENT_PATH = process.env.AGENT_JS || '/tmp/recon/agent.js';
const agentSource = fs.readFileSync(AGENT_PATH, 'utf8');

const noop = () => {};
global.window = global;
global.document = {
  readyState: 'complete',
  hidden: false,
  addEventListener: noop,
  removeEventListener: noop,
  getElementById: () => null,
  createElement: () => ({ style: {}, setAttribute: noop, appendChild: noop }),
  body: { appendChild: noop },
};
global.addEventListener = noop;
global.removeEventListener = noop;
global.location = { search: '', href: 'https://example.invalid/' };
global.performance = { now: () => Date.now() };

function makeScheduler() {
  return {
    _timeScale: 1,
    setTimeScale(value) { this._timeScale = value; },
    getTimeScale() { return this._timeScale; },
    update(t) { if (this._timeScale !== 1) t = t * this._timeScale; return t; },
  };
}
const scheduler = makeScheduler();
global.cc = { director: { getScheduler: () => scheduler, getScene: () => null } };

eval(agentSource);
const api = global.__LOBBY_ENHANCE__;

let failed = 0;
const expect = (ok, label) => {
  if (!ok) failed += 1;
  console.log((ok ? 'PASS' : 'FAIL') + ' - ' + label);
};
const uiOf = (text) => (text.split(' ui=')[1] || '').split(' note=')[0];

// 下发口径按 apply() 的真实字段名改（见 GameEnhancementScript.apply）。
const apply = (config) => api.apply(Object.assign(
  { enabled: false, speed: 100, hideChat: false, uiSpeedEnabled: false, uiSpeed: 3 }, config));

console.log('初始 status:', api.status());

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

const original = scheduler.update.__lobbyUISpeedOriginal;
apply({ uiSpeedEnabled: false });
expect(scheduler._timeScale === 1, '关闭 → 还原接管前的倍率');
expect(scheduler.update === original, '关闭 → update 解包回原函数');
scheduler.update(0.016);
expect(scheduler._timeScale === 1, '关闭后不再改写倍率');
expect(uiOf(api.status()).startsWith('0x'), 'status 报 ui=0');

// ── 引导路径：文档起点注入时 cc 还不存在（真机常态）──
delete global.cc;
apply({ uiSpeedEnabled: true, uiSpeed: 5 });
expect(api.status().includes('uiNote=ui-waiting-engine'), '引擎未就绪 → ui-waiting-engine');

setTimeout(() => { global.cc = { director: { getScheduler: () => scheduler } }; }, 60);
setTimeout(() => {
  expect(scheduler._timeScale === 5, '引擎出现后被 20ms 引导轮询接管（_timeScale=5）');
  const status = api.status();
  expect(status.includes('sched=1') && status.includes('wrap=1'), '引导后 sched=1 / wrap=1');
  expect(status.includes('uiNote=ui-running'), '引导后 uiNote=ui-running');
  console.log(failed ? `\n${failed} 项失败` : '\n全部通过');
  process.exit(failed ? 1 : 0);
}, 300);
