// 对照：SDK 式（body=.bin）与游戏式（body=BON 参数）两条 authuser 路径拿到的角色是否一致
// 用法：node probe-auth-compare.mjs '11不不.bin' 14028
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import lz4 from 'lz4js';
import { bon, g_utils } from './bonProtocol.js';

const BIN_DIR = path.join(os.homedir(), 'Library/Application Support/AccountBins');
const fileName = process.argv[2] || '11不不.bin';
const serverId = Number(process.argv[3] || 14028);
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
async function post(url, body) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/octet-stream', 'O4e-Encoding': 'lx', Connection: 'close' },
    body,
  });
  const buf = Buffer.from(await res.arrayBuffer());
  return g_utils.parse(buf).getData() || {};
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
function roleInfo(roleToken, roleId, label) {
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
      resolve({ label, role: body.role || {}, serverViewId: body.serverViewId });
    };
    ws.onerror = () => { clearTimeout(timer); resolve(null); };
  });
}

const obj = bon.decode(lxDecrypt(bytes));
const base = obj && typeof obj.getData === 'function' ? obj.getData() : obj;
const infoRaw = base.info;
const info = typeof infoRaw === 'string' ? infoRaw : JSON.stringify(infoRaw);

const cases = [];
// A. SDK 式：raw bin
cases.push(['A SDK 式 body=.bin', bytes]);
// B. 游戏式：BON 参数，serverId 用 bin 里那个
cases.push([`B 参数体 serverId=${base.serverId}（与 bin 同）`, Buffer.from(lxEncrypt(bon.encode({
  platform: base.platform, oriPlatform: base.platform, platformExt: base.platformExt,
  info, serverId: Number(base.serverId), scene: 0, referrerInfo: '', deviceUniqueId: '',
}, false)))]);
// C. 游戏式：换个 serverId
cases.push([`C 参数体 serverId=${serverId}（指定换服）`, Buffer.from(lxEncrypt(bon.encode({
  platform: base.platform, oriPlatform: base.platform, platformExt: base.platformExt,
  info, serverId, scene: 0, referrerInfo: '', deviceUniqueId: '',
}, false)))]);

for (const [label, body] of cases) {
  const auth = await post('https://xxz-xyzw.hortorgames.com/login/authuser?_seq=4', body);
  console.log(`\n===== ${label} =====`);
  console.log(`  authuser keys=${Object.keys(auth).join(',')} roleId=${auth.roleId} roleToken.len=${String(auth.roleToken || '').length}`);
  if (!auth.roleToken) continue;
  const live = await roleInfo(auth.roleToken, auth.roleId, label);
  const role = live?.role || {};
  const shown = ['roleId', 'uid', 'platformUId', 'name', 'levelId', 'power', 'serverId', 'serverName', 'vip', 'gold', 'diamond', 'isFirstLogin', 'createTime'];
  console.log(`  serverViewId=${live?.serverViewId}`);
  for (const k of shown) if (role[k] !== undefined) console.log(`    ${k} = ${role[k]}`);
  console.log(`  role 字段总数 = ${Object.keys(role).length}`);
  await new Promise((r) => setTimeout(r, 700));
}
