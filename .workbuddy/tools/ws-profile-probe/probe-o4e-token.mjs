// 实验：游戏式 authuser 是否需要 O4e-Token / O4e-Version 头（由 SDK 那次登录建立）
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import lz4 from 'lz4js';
import { bon, g_utils } from './bonProtocol.js';

const BIN_DIR = path.join(os.homedir(), 'Library/Application Support/AccountBins');
const fileName = process.argv[2] || '14001服-温酒.bin';
const target = Number(process.argv[3] || 4046);
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
async function post(url, body, headers = {}) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/octet-stream', 'O4e-Encoding': 'lx', Connection: 'close', ...headers },
    body,
  });
  const buf = Buffer.from(await res.arrayBuffer());
  let data = {};
  try { data = g_utils.parse(buf).getData() || {}; } catch {}
  return { status: res.status, ...data };
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
const info = typeof base.info === 'string' ? base.info : JSON.stringify(base.info);

const sdk = await post('https://xxz-xyzw.hortorgames.com/login/authuser?_seq=1', bytes);
console.log(`SDK 登录：roleId=${sdk.roleId} roleToken.len=${String(sdk.roleToken || '').length}`);
const sdkRole = await roleInfo(sdk.roleToken, sdk.roleId);
console.log(`SDK 角色：name=${sdkRole?.role?.name} serverName=${sdkRole?.role?.serverName} serverViewId=${sdkRole?.serverViewId}\n`);

const variants = [
  ['基准（无额外头）', {}],
  ['O4e-Token = SDK roleToken', { 'O4e-Token': String(sdk.roleToken) }],
  ['O4e-Version = 0.33.0-ios', { 'O4e-Version': '0.33.0-ios' }],
  ['O4e-Token + O4e-Version', { 'O4e-Token': String(sdk.roleToken), 'O4e-Version': '0.33.0-ios' }],
];

for (const [label, headers] of variants) {
  const body = bon.encode({
    platform: base.platform, oriPlatform: base.platform, platformExt: base.platformExt,
    info, serverId: target, scene: 0, referrerInfo: '', deviceUniqueId: '',
  }, false);
  const r = await post('https://xxz-xyzw.hortorgames.com/login/authuser?_seq=4', Buffer.from(lxEncrypt(body)), headers);
  if (!r.roleToken) { console.log(`${label} → 无 roleToken`); continue; }
  const live = await roleInfo(r.roleToken, r.roleId);
  const role = live?.role || {};
  console.log(`${label}\n   → uid=${role.uid} name=${role.name} levelId=${role.levelId} power=${role.power} serverName=${role.serverName}`);
  await new Promise((res) => setTimeout(res, 600));
}
