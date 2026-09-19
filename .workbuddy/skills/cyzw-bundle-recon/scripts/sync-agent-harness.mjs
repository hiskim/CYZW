// 键鼠同步代理（InputSyncScript.agent）行为回归。
//
//   AGENT_JS=/tmp/recon/agent.js $NODE scripts/sync-agent-harness.mjs
//
// 假环境要素（都是真实链路上一定会有的东西）：
//   · window 捕获阶段监听 + canvas 监听 + window 冒泡监听的**真实派发顺序**
//     （顺序错的话「回灌闸门」根本测不出来：代理挂在 window capture，游戏挂在 canvas）
//   · 游戏侧 canvas 监听：记录它到底收到哪些 mousedown/mouseup、坐标多少
//   · elementFromPoint：默认给 canvas；可切成 null 测 miss 落点
//
// 这份 harness 的存在意义是一个具体事故：v1 代理在窗口失焦时用**外发通道**补发
// mouseup(0,0)，经宿主广播到同组其它窗口，把别人刚开始的一次按下在 (0,0) 结束掉
// （引擎按 touch id 命中并改写坐标后删 id，随后真 mouseup 整段丢弃）→ 那次点击消失。
// 所以最关键的两条断言是「失焦补发**不出本窗口**」与「只有真按着才补」。

import fs from 'node:fs';
import vm from 'node:vm';

const AGENT_PATH = process.env.AGENT_JS || '/tmp/recon/agent.js';
const source = fs.readFileSync(AGENT_PATH, 'utf8');

const CHANNEL = 'ios2Game';
const W = 400;
const H = 800;

let pass = 0;
const failures = [];
function check(name, ok, detail = '') {
  if (ok) { pass += 1; console.log(`  ok   ${name}`); }
  else { failures.push(`${name}${detail ? ' — ' + detail : ''}`); console.log(`  FAIL ${name}${detail ? ' — ' + detail : ''}`); }
}

function build() {
  const outbox = [];          // 页面 → 宿主（真实外发通道）
  const gameEvents = [];      // 假「游戏」在 canvas 上收到的鼠标事件
  const windowListeners = [];
  let hitTarget = 'canvas';   // 'canvas' | 'null'

  function makeEl(tag) {
    return {
      tagName: tag,
      style: {},
      cssText: '',
      isConnected: true,
      _kids: [],
      addEventListener(type, fn) { (this._listeners || (this._listeners = [])).push({ type, fn }); },
      dispatchEvent(ev) { chain(ev, this); return true; },
      appendChild(child) { this._kids.push(child); child.parentNode = this; return child; },
      removeChild(child) { this._kids = this._kids.filter((k) => k !== child); child.parentNode = null; return child; },
      getBoundingClientRect() { return { left: 0, top: 0, width: W, height: H }; }
    };
  }

  const canvas = makeEl('CANVAS');
  const body = makeEl('BODY');
  const documentElement = makeEl('HTML');

  // 真实 DOM 派发顺序：window 捕获 → 目标 → window 冒泡。
  // ⚠️ 目标**就是 window** 时（blur / focus / keydown 这类），window 上的监听按注册顺序
  // 各跑一次（AT_TARGET 阶段）——不按这个来，`blur` 补发那类行为整条测不到。
  function chain(ev, target) {
    const order = [];
    if (target === window) {
      for (const l of windowListeners) if (l.type === ev.type) order.push(l.fn);
    } else {
      for (const l of windowListeners) if (l.type === ev.type && l.capture) order.push(l.fn);
      for (const l of (target._listeners || [])) if (l.type === ev.type) order.push(l.fn);
      for (const l of windowListeners) if (l.type === ev.type && !l.capture) order.push(l.fn);
    }
    for (const fn of order) fn(ev);
  }

  const window = {
    innerWidth: W,
    innerHeight: H,
    addEventListener(type, fn, opts) {
      windowListeners.push({ type, fn, capture: opts === true || (opts && opts.capture === true) });
    },
    removeEventListener() {},
    webkit: {
      messageHandlers: {
        [CHANNEL]: { postMessage(msg) { outbox.push(msg); } }
      }
    }
  };

  const document = {
    body,
    documentElement,
    activeElement: body,
    createElement: (tag) => makeEl(String(tag).toUpperCase()),
    elementFromPoint: () => (hitTarget === 'canvas' ? canvas : null)
  };

  class MouseEvent { constructor(type, init) { Object.assign(this, init || {}); this.type = type; } }
  class WheelEvent { constructor(type, init) { Object.assign(this, init || {}); this.type = type; } }
  class KeyboardEvent { constructor(type, init) { Object.assign(this, init || {}); this.type = type; } }

  const sandbox = {
    window, document, console,
    requestAnimationFrame: (cb) => { cb(0); return 1; },
    cancelAnimationFrame: () => {},
    setTimeout: (cb) => { cb(); return 0; },
    clearTimeout: () => {},
    setInterval: () => 0,
    clearInterval: () => {},
    MouseEvent, WheelEvent, KeyboardEvent
  };
  // window 上的 addEventListener 由沙箱里的 window 提供，这里补一层等价引用：
  window.addEventListener = window.addEventListener.bind(window);

  // 假「游戏」：挂在 canvas 上，只关心按下/抬起与坐标（Cocos 的绑定位置正是 canvas）。
  canvas.addEventListener('mousedown', (e) => gameEvents.push({ t: 'mousedown', x: e.clientX, y: e.clientY }));
  canvas.addEventListener('mouseup', (e) => gameEvents.push({ t: 'mouseup', x: e.clientX, y: e.clientY }));

  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);

  const sync = sandbox.window.__LOBBY_SYNC__;
  const outInputs = () => outbox.filter((m) => m.type === 'input');
  const outAcks = () => outbox.filter((m) => m.type === 'syncAck');
  const outParams = () => outbox.filter((m) => m.type === 'syncParams');

  // 用户在本窗口的真实操作（原生事件：窗口捕获 → canvas → 窗口冒泡）
  function native(type, x, y) {
    const ev = new MouseEvent(type, {
      clientX: x, clientY: y, button: 0, buttons: type === 'mouseup' ? 0 : 1,
      bubbles: true, cancelable: true, view: window
    });
    chain(ev, canvas);
    return ev;
  }
  function blur() { chain({ type: 'blur' }, window); }
  function setHitTarget(v) { hitTarget = v; }
  function reset() { outbox.length = 0; gameEvents.length = 0; }

  return { sync, outbox, gameEvents, native, blur, reset, setHitTarget,
           outInputs, outAcks, outParams, canvas, document,
           // v1 代理没有 stats()（旧宿主/旧代理混跑的现场），缺了就返回空对象，
           // 让断言逐条报 FAIL，而不是整个 harness 崩在这里看不出所以然。
           stats: () => (sync && typeof sync.stats === 'function' ? sync.stats() : {}) };
}

console.log(`\n[1] agent 装载与默认态（${AGENT_PATH}）`);
{
  const h = build();
  check('注入后 window.__LOBBY_SYNC__ 存在', !!h.sync);
  const s = h.stats();
  check('stats() 带 agent 版本 = 2', s.agent === 2, JSON.stringify(s));
  check('默认不捕获', s.capturing === false);
  h.native('mousedown', 100, 200);
  check('未开启同步时真实点击不外发', h.outInputs().length === 0, JSON.stringify(h.outbox));
  check('未开启同步时游戏仍收到原生点击', h.gameEvents.length === 1);
}

console.log('\n[2] 开启捕获：真实事件外发 + 归一化坐标 + 回执');
{
  const h = build();
  h.reset();
  h.sync.setCapture(true);
  h.native('mousedown', 100, 200);              // (0.25, 0.25)
  const inputs = h.outInputs();
  check('mousedown 外发一条', inputs.length === 1, JSON.stringify(inputs));
  check('类型与坐标归一化', inputs[0]?.input?.t === 'mousedown'
        && inputs[0].input.x === 0.25 && inputs[0].input.y === 0.25, JSON.stringify(inputs[0]));
  const acks = h.outAcks();
  check('mousedown 不回执（回执只由**回放**产生）', acks.length === 0, JSON.stringify(acks));
  h.native('mouseup', 100, 200);
  check('mouseup 也外发', h.outInputs().length === 2);
  const s = h.stats();
  check('计数：downs=1 ups=1 replayed=0', s.downs === 1 && s.ups === 1 && s.replayed === 0, JSON.stringify(s));
}

console.log('\n[3] 失焦补发：不外发 / 坐标用最后按压点 / 只在真按着时补  ← 本次事故的回归线');
{
  const h = build();
  h.sync.setCapture(true);
  h.reset();
  h.blur();                                     // 没按着就失焦
  check('未按着时失焦：不外发', h.outInputs().length === 0, JSON.stringify(h.outbox));
  check('未按着时失焦：游戏也没收到 mouseup', h.gameEvents.length === 0, JSON.stringify(h.gameEvents));

  h.reset();
  h.native('mousedown', 120, 640);              // 在 (0.3, 0.8) 按下
  h.reset();                                    // 只关心失焦这一下产生的东西
  h.blur();
  check('按着时失焦：**仍然不外发**（v1 这里会外发 mouseup(0,0)）',
        h.outInputs().length === 0, JSON.stringify(h.outInputs()));
  const ups = h.gameEvents.filter((e) => e.t === 'mouseup');
  check('按着时失焦：本窗口游戏收到 mouseup', ups.length === 1, JSON.stringify(h.gameEvents));
  check('补发坐标 = 最后按压点（不是 0,0）', ups[0]?.x === 120 && ups[0]?.y === 640, JSON.stringify(ups));
  check('本地释放计数 = 1', h.stats().releases === 1);
  h.reset();
  h.blur();
  check('补过之后不会重复补（避免连发）', h.gameEvents.length === 0 && h.outInputs().length === 0);
}

console.log('\n[4] 回放与回灌闸门');
{
  const h = build();
  h.sync.setCapture(true);
  h.reset();
  h.sync.replay({ t: 'mousedown', x: 0.5, y: 0.25, button: 0, buttons: 1, mods: 0 });
  check('回放落到 canvas（坐标换算成绝对像素）',
        h.gameEvents[0]?.t === 'mousedown' && h.gameEvents[0].x === 200 && h.gameEvents[0].y === 200,
        JSON.stringify(h.gameEvents));
  check('回放事件不再外发（ECHO 闸门）', h.outInputs().length === 0, JSON.stringify(h.outInputs()));
  const ack = h.outAcks()[0];
  check('回放产生回执且落点 = CANVAS', ack?.tag === 'CANVAS' && ack.t === 'mousedown', JSON.stringify(ack));
  check('回执带 capt 状态与回放计数', ack?.cap === true && ack?.n === 1, JSON.stringify(ack));
  h.native('mousedown', 200, 200);
  check('回放不会污染「最后坐标/按下态」（真事件才更新）', h.stats().downs === 1, JSON.stringify(h.stats()));
}

console.log('\n[5] 回放落点异常（elementFromPoint 拿不到元素）要能在回执里看见');
{
  const h = build();
  h.sync.setCapture(true);
  h.setHitTarget('null');
  h.reset();
  h.sync.replay({ t: 'mousedown', x: 0.1, y: 0.1, button: 0, buttons: 1, mods: 0 });
  const ack = h.outAcks()[0];
  check('miss 计数 +1', ack?.miss === 1, JSON.stringify(ack));
  check('落点回执为 BODY（游戏收不到，宿主据此判定「回放了却没反应」）', ack?.tag === 'BODY', JSON.stringify(ack));
}

console.log('\n[6] 关掉同步时要释放本窗口卡住的按下态');
{
  const h = build();
  h.sync.setCapture(true);
  h.native('mousedown', 60, 80);
  h.sync.setCapture(false);
  const ups = h.gameEvents.filter((e) => e.t === 'mouseup');
  check('关卡后本窗口游戏收到 mouseup', ups.length === 1, JSON.stringify(h.gameEvents));
  check('关卡释放同样不外发', h.outInputs().filter((m) => m.input.t === 'mouseup').length === 0);
  check('capturing 已置 false', h.stats().capturing === false);
}

console.log('\n[7] 回放目标窗口与源窗口尺寸不同也不跑偏（归一化坐标的意义）');
{
  const h = build();
  h.sync.setCapture(true);
  h.reset();
  h.sync.replay({ t: 'mouseup', x: 0.25, y: 0.25, button: 0, buttons: 0, mods: 0 });
  check('同一归一化坐标在本窗口换算成本窗口像素', h.gameEvents[0]?.x === 100 && h.gameEvents[0]?.y === 200,
        JSON.stringify(h.gameEvents));
}

console.log(`\n${pass} 项断言通过，${failures.length} 项失败`);
if (failures.length) {
  for (const f of failures) console.log(`  ! ${f}`);
  process.exit(1);
}
