// 实验：省掉 O4e-Encoding 头后，改过 serverId 的 bin 能不能换出目标区服的角色
// （助手仓 token.ts 打 authuser 时既不带 O4e-Encoding，body 也可能是 x 方案重编码）
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import lz4 from 'lz4js';
import { bon, g_utils } from './bonProtocol.js';

const BIN_DIR = path.join(os.homedir(), 'Library/Application Support/AccountBins');
const fileName = process.argv[2] || '11不不.bin';
const targets = process.argv.slice(3).map(Number);
const bytes = fs.readFileSync(path.join(BIN_DIR, fileName));

function lxDecrypt(input) {
  const e = Uint8Array.from(input);
  const t =
    (((e[2] >> 6) & 1) << 7) | (((e[2] >> 4) & 1) << 6) | (((e[2] >> 2) & 1) << 5) |
    ((e[2] & 1) << 4) | (((e[3] >> 6) & 1) << 3) | (((e[3] >> 4) & 1) << 2) |
    (((e[3] >> 2) & 1) << 1) | (e[3] & 1);
  for (let n = Math.min(100, e.length); --n >= 2; ) e[n] ^= t;
  e[0] = 4; e[1] = 34; e[2] = 77; e[3] = 24;
  return lz4.decompress(e);
}
function lxEncrypt(plain) {
  const e = lz4.compress(Uint8Array.from(plain));
  const t = 2 + ~~(Math.random() * 248);
  for (let n = Math.min(100, e.length); --n >= 0; ) e[n] ^= t;
  e[0] = 112; e[1] = 108;
  e[2] = (e[2] & 0b10101010) | (((t >> 7) & 1) << 6) | (((t >> 6) & 1) << 4) | (((t >> 5) & 1) << 2) | ((t >> 4) & 1);
  e[3] = (e[3] & 0b10101010) | (((t >> 3) & 1) << 6) | (((t >> 2) & 1) << 4) | (((t >> 1) & 1) << 2) | (t & 1);
  return e;
}
async function post(url, body, headers) {
  const res = await fetch(url, { method: 'POST', headers, body });
  const buf = Buffer.from(await res.arrayBuffer());
  let data = {};
  try { data = g_utils.parse(buf).getData() || {}; } catch {}
  return { status: res.status, bytes: buf.length, ...data };
}
function flatten(value, depth = 0) {
  if (depth > 4 || value === null || value === undefined) return value;
  if (Array.isArray(value)) return value.map((v) => flatten(v, depth + 1));
  if (typeof value === 'object') {
    if (value.high !== undefined && value.low !== undefined) {
      return ((BigInt(value.high >>> 0) << 32n) | BigInt(value.low >>> 0)).toString();
    }
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = flatten(v, depth + 1);
    return out;
  }
  return value;
}
function roleInfo(roleToken, roleId) {
  const now = Date.now();
  const token = JSON.stringify({
    roleToken, roleId,
    sessId: now * 100 + Math.floor(Math.random() * 100),
    connId: now + Math.floor(Math.random() * 10),
    isRestore: 0,
  });
  const url = `wss://xxz-xyzw.hortorgames.com/agent?p=${encodeURIComponent(token)}&e=x&lang=chinese`;
  return new Promise((resolve) => {
    const ws = new WebSocket(url);
    ws.binaryType = 'arraybuffer';
    const timer = setTimeout(() => { try { ws.close(); } catch {} resolve(null); }, 12000);
    ws.onopen = () => ws.send(g_utils.encode({
      cmd: 'role_getroleinfo', ack: 0, seq: 1, time: Date.now(),
      body: bon.encode({
        clientVersion: '2.10.3-f10a39eaa0c409f4-wx', inviteUid: 0,
        platform: 'hortor', platformExt: 'mix', scene: '',
      }),
    }, 'x'));
    ws.onmessage = (evt) => {
      if (typeof evt.data === 'string') return;
      let msg;
      try { msg = g_utils.parse(Buffer.from(evt.data)); } catch { return; }
      if (!/getroleinfo/.test(String(msg.cmd))) return;
      clearTimeout(timer);
      const body = flatten(msg.getData()) || {};
      try { ws.close(); } catch {}
      resolve({ role: body.role || {}, serverViewId: body.serverViewId });
    };
    ws.onerror = () => { clearTimeout(timer); resolve(null); };
  });
}

const obj = bon.decode(lxDecrypt(bytes));
const base = obj && typeof obj.getData === 'function' ? obj.getData() : obj;

const cases = [];
for (const t of targets) {
  const clone = { ...base, serverId: t };
  cases.push([`lx 重编码 serverId=${t}`, Buffer.from(lxEncrypt(bon.encode(clone, false)))]);
  cases.push([`x  重编码 serverId=${t}`, Buffer.from(g_utils.encode(clone))]);
}
for (const [label, body] of cases) {
  for (const headerVariant of [
    ['无 O4e-Encoding', { 'Content-Type': 'application/octet-stream' }],
    ['带 O4e-Encoding: lx', { 'Content-Type': 'application/octet-stream', 'O4e-Encoding': 'lx' }],
  ]) {
    const r = await post('https://xxz-xyzw.hortorgames.com/login/authuser?_seq=1', body, headerVariant[1]);
    if (!r.roleToken) {
      console.log(`${label} | ${headerVariant[0]} → HTTP ${r.status} ${r.bytes}B 无 roleToken`);
      continue;
    }
    const live = await roleInfo(r.roleToken, r.roleId);
    const role = live?.role || {};
    console.log(`${label} | ${headerVariant[0]} → HTTP ${r.status} uid=${role.uid} name=${role.name} levelId=${role.levelId} power=${role.power} serverName=${role.serverName} serverViewId=${live?.serverViewId}`);
    await new Promise((res) => setTimeout(res, 500));
  }
}
