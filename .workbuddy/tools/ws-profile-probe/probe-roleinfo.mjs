// ③ 走 WSS 直接取角色资料（头像 / 战力 / 等级 / 名字）
// 参考：/Users/gg/code/xyzw_web_helper
//   src/utils/token.ts            —— /login/authuser 换 roleToken
//   src/stores/tokenStore.ts:677  —— wss://xxz-xyzw.hortorgames.com/agent?p=<token>&e=x&lang=chinese
//   src/utils/xyzwWebSocket.js    —— 帧格式：BON(encode) 后用 x 方案加密
//   src/utils/xyzwWebSocket.js:724—— 连上后第一件事就是 send("role_getroleinfo")
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { g_utils, bon } from './bonProtocol.js';

const BIN_DIR = path.join(os.homedir(), 'Library/Application Support/AccountBins');
const fileName = process.argv[2] || '15小惜.bin';
const bytes = fs.readFileSync(path.join(BIN_DIR, fileName));
console.log(`凭据：${fileName}（${bytes.length} 字节）\n`);

function plain(value, depth = 0) {
  if (depth > 5 || value === null) return value;
  if (typeof value === 'bigint') return value.toString();
  if (Array.isArray(value)) return value.map((v) => plain(v, depth + 1));
  if (value && typeof value === 'object') {
    if (value.high !== undefined && value.low !== undefined) {
      return ((BigInt(value.high >>> 0) << 32n) | BigInt(value.low >>> 0)).toString();
    }
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = plain(v, depth + 1);
    return out;
  }
  return value;
}

// ① authuser → roleToken / roleId
const authRes = await fetch('https://xxz-xyzw.hortorgames.com/login/authuser?_seq=1', {
  method: 'POST',
  headers: { 'Content-Type': 'application/octet-stream' },
  body: bytes,
});
const authData = g_utils.parse(Buffer.from(await authRes.arrayBuffer())).getData();
console.log(`① authuser → HTTP ${authRes.status}，roleId=${authData.roleId}，roleToken ${String(authData.roleToken).length} 字符`);

// ② 拼 wss URL 用的 token（与助手 transformToken 一致）
const now = Date.now();
const token = JSON.stringify({
  ...authData,
  sessId: now * 100 + Math.floor(Math.random() * 100),
  connId: now + Math.floor(Math.random() * 10),
  isRestore: 0,
});
const url = `wss://xxz-xyzw.hortorgames.com/agent?p=${encodeURIComponent(token)}&e=x&lang=chinese`;
console.log(`② wss 目标：${url.slice(0, 72)}…（p 长 ${encodeURIComponent(token).length}）\n`);

const ws = new WebSocket(url);
ws.binaryType = 'arraybuffer';
const started = Date.now();
let got = false;

const done = (code) => {
  try { ws.close(); } catch {}
  setTimeout(() => process.exit(code), 200);
};

ws.onopen = () => {
  console.log(`③ 已连接（${Date.now() - started}ms）`);
  const raw = {
    cmd: 'role_getroleinfo',
    ack: 0,
    seq: 1,
    time: Date.now(),
    body: bon.encode({
      clientVersion: '2.10.3-f10a39eaa0c409f4-wx',
      inviteUid: 0,
      platform: 'hortor',
      platformExt: 'mix',
      scene: '',
    }),
  };
  const frame = g_utils.encode(raw, 'x');
  console.log(`④ 发送 role_getroleinfo（帧 ${frame.byteLength} 字节）`);
  ws.send(frame);
};

ws.onmessage = (evt) => {
  if (typeof evt.data === 'string') {
    console.log('   非二进制消息：' + evt.data.slice(0, 200));
    return;
  }
  let msg;
  try {
    msg = g_utils.parse(Buffer.from(evt.data));
  } catch (error) {
    console.log(`   解析失败：${error.message}（${evt.data.byteLength} 字节）`);
    return;
  }
  const cmd = msg.cmd;
  if (!/getroleinfo/.test(String(cmd))) {
    console.log(`   ← ${cmd}（${evt.data.byteLength} 字节，忽略）`);
    return;
  }
  got = true;
  const body = plain(msg.getData());
  const role = body?.role || {};
  console.log(`\n⑤ 收到 ${cmd}（${Date.now() - started}ms）`);
  console.log(`   body 顶层键：${Object.keys(body || {}).join(', ')}`);
  console.log(`   role 字段数：${Object.keys(role).length}`);
  console.log('   ── 我们关心的四个字段 ──');
  console.log(`   name    = ${role.name}`);
  console.log(`   levelId = ${role.levelId ?? role.level}`);
  console.log(`   power   = ${role.power}`);
  console.log(`   headImg = ${role.headImg}`);
  const json = JSON.stringify(body);
  console.log(`   含 headImg ? ${/headImg/i.test(json)}   含 qlogo ? ${/qlogo/i.test(json)}`);
  done(0);
};

ws.onerror = (event) => {
  console.log(`   WebSocket 错误：${event?.message || event?.error?.message || 'unknown'}`);
};
ws.onclose = (event) => {
  console.log(`   WebSocket 关闭：code=${event.code} reason=${event.reason || '-'}（${Date.now() - started}ms）`);
  if (!got) done(2);
};

setTimeout(() => {
  if (!got) console.log('   超时：15s 内没等到 role_getroleinfo');
  done(got ? 0 : 3);
}, 15000);
