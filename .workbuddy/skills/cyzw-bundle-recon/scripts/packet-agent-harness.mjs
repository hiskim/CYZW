// 页面代理（PacketCaptureScript）行为 harness。
//
// 用途：改过 `Sources/LobbyEngine/PacketCaptureScript.swift` 的 agent 后，在**不启动游戏**的
// 前提下验证它真的能干这几件事：
//   · 构造器 hook 之后每个 socket 都拿到编号（宿主定向发送全靠这个）；
//   · `sendViaGameOnSocket(sid, cmd, params)` 发到**指定的那条** socket、请求形状正确、
//     回执能被 `sanitize` 摊平（Map → 对象）；
//   · 三个失败分支各自给出可分辨的原因串（宿主靠它们决定降级）。
//
// 喂的是 **A 步隔离编译导出的 `agent.js`**（不是 Swift 源码，插值才已落实）：
//   AGENT_JS=/tmp/recon/agent.js $NODE scripts/packet-agent-harness.mjs
//
// ⚠️ 别想着用 `strings -a <dylib> | grep` 从二进制里捞这份 agent 再 `node --check`：
//    agent 里大量中文注释是非 ASCII，`strings` 会把它切成碎片并打乱顺序，捞出来的
//    必然「语法错误」——那不是代码坏了，是取证工具不对（我踩过）。

import fs from 'node:fs';
import vm from 'node:vm';

const AGENT_PATH = process.env.AGENT_JS || '/tmp/recon/agent.js';
const source = fs.readFileSync(AGENT_PATH, 'utf8');

// ── 假游戏 WebSocket：主连接与战场连接各一条（战场 URL 含 `e=x&sid2=`，官方客户端就是这样）──
const calls = [];
class FakeWS {
  constructor(url) { this.url = url; this.readyState = 1; this.listeners = {}; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  send() {}
  async sendAsync(request) {
    calls.push({ url: this.url, request: JSON.stringify(request) });
    if (this.url.includes('sid2')) {
      // 战场连接的「已解码」响应：带 Map（官方脚本自己就在判 `value instanceof Map`）
      return { body: { code: 0, battlefield: {
        battlefieldId: 4321,
        legions: new Map([['k1', { legionId: 7, position: 3 }]]),
      } } };
    }
    return { body: { code: 0, info: { id: 99 } } };
  }
}

const sandbox = {
  console,
  ArrayBuffer, Uint8Array, Date, JSON, Map, Set, Promise, Error, String, Number, TextEncoder,
  URLSearchParams,
  setTimeout, clearTimeout,
  WebSocket: FakeWS,
  g_utils: { bon: { encode: (o) => ({ __bon: o }) } },
  webkit: { messageHandlers: { ios2Game: { postMessage() {} } } },
  document: null,
  location: null,
};
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(source, sandbox, { filename: AGENT_PATH });

const window = sandbox.window;
const api = window.__LOBBY_CAPTURE__;
if (!api) { console.error('❌ agent 没有挂上 __LOBBY_CAPTURE__'); process.exit(1); }

let failed = 0;
const check = (label, ok, extra) => {
  console.log((ok ? '  ✅ ' : '  ❌ ') + label + (extra ? `  ${extra}` : ''));
  if (!ok) failed++;
};

// 代理在构造时就往实例上写 `__lobbySocketID`（登记表是闭包私有的，只能这么读回编号）
const sidOf = (socket) => socket.__lobbySocketID;

const battle = new window.WebSocket('wss://xxz-xyzw.hortorgames.com/agent?e=x&sid2=7');
const main = new window.WebSocket('wss://xxz-xyzw.hortorgames.com/agent?token=1');
const plain = new window.WebSocket('wss://x/plain');
plain.sendAsync = undefined;   // 模拟没有游戏封装的连接（必须**经代理构造**才会被登记）

console.log(`agentVersion=${api.version}`);
console.log('socket 一览:', api.sockets().split(' | ').join('\n              '));

const expectVersion = process.env.EXPECT_VERSION;
if (expectVersion) check(`版本号 = ${expectVersion}`, api.version === expectVersion, api.version);

(async () => {
  // ── ① 正常路径：定向到战场 socket，回执被摊平 ──
  const receipt = JSON.parse(await api.sendViaGameOnSocket(
    sidOf(battle), 'war_enterbattlefield', '{"battlefieldId":4321}'));
  check('回执 __ok', receipt.__ok === true);
  check('Map → 对象（legions.k1.position=3）',
        receipt.data?.battlefield?.legions?.k1?.position === 3,
        JSON.stringify(receipt.data?.battlefield?.legions));
  const request = JSON.parse(calls[0].request);
  check('请求 ack 恒 0（官方脚本口径）', request.ack === 0);
  check('请求 seq 是时间戳量级', typeof request.seq === 'number' && request.seq > 1e12);
  check('params 经 g_utils.bon.encode → body',
        !!request.body && request.params === undefined, JSON.stringify(request.body));
  check('帧确实发在战场连接上', calls[0].url.includes('sid2'));

  // ── ② 失败分支：原因串必须可分辨（宿主靠它决定要不要降级）──
  const missing = JSON.parse(await api.sendViaGameOnSocket(99, 'x', '{}'));
  check('不存在的 sid → no-such-socket', missing.__error === 'no-such-socket', missing.__error);
  const noAsync = JSON.parse(await api.sendViaGameOnSocket(sidOf(plain), 'x', '{}'));
  check('无 sendAsync → socket-has-no-sendAsync',
        noAsync.__error === 'socket-has-no-sendAsync', noAsync.__error);

  battle.sendAsync = async () => { throw new Error('boom'); };
  const threw = JSON.parse(await api.sendViaGameOnSocket(sidOf(battle), 'x', '{}'));
  check('sendAsync 抛错被兜住', String(threw.__error).startsWith('sendAsync-threw'), threw.__error);

  console.log(failed === 0 ? '\n✅ 全部通过' : `\n❌ ${failed} 项失败`);
  process.exit(failed === 0 ? 0 : 1);
})();
