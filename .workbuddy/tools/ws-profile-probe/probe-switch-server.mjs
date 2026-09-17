// 决定性实验：不改 .bin，直接用「游戏自己的 authUser 参数体」换 serverId → 拿 roleToken
//              → 连 WSS 发 role_getroleinfo → 看拿到的是不是目标区服的那个角色。
//
// 背景：/login/authuser 有两条调用方
//   a) SDK（原生）：body = .bin 原字节        —— 我们宿主现在走这条，serverId 被服务端忽略
//   b) 游戏自己：body = BON({platform, oriPlatform, platformExt, info, serverId, scene, ...})
//      命令常量 login_authuser，URL 由 launcher 的 HTTP 客户端拼成 /login/authuser?_seq=N
//
// 用法：node probe-switch-server.mjs '11不不.bin' 9365 14028
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
  for (let n = Math.min(e.length, 100); --n >= 0; ) e[n] ^= t;
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
  return { status: res.status, ...(g_utils.parse(buf).getData() || {}) };
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
    roleToken,
    roleId,
    sessId: now * 100 + Math.floor(Math.random() * 100),
    connId: now + Math.floor(Math.random() * 10),
    isRestore: 0,
  });
  const url = `wss://xxz-xyzw.hortorgames.com/agent?p=${encodeURIComponent(token)}&e=x&lang=chinese`;
  return new Promise((resolve) => {
    const ws = new WebSocket(url);
    ws.binaryType = 'arraybuffer';
    const timer = setTimeout(() => { try { ws.close(); } catch {} resolve(null); }, 12000);
    ws.onopen = () => {
      ws.send(g_utils.encode({
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
      }, 'x'));
    };
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

const serverlist = await post('https://xxz-xyzw.hortorgames.com/login/serverlist?_seq=3', bytes);
const byServerId = new Map(Object.values(serverlist.roles || {}).map((r) => [Number(r.serverId), r]));

console.log(`凭据 ${fileName}；serverlist 里共 ${byServerId.size} 个角色\n`);

for (const serverId of targets) {
  const expect = byServerId.get(serverId);
  const paramsBody = bon.encode({
    platform: base.platform || 'hortor',
    oriPlatform: base.platform || 'hortor',
    platformExt: base.platformExt || 'mix',
    info,
    serverId,
    scene: 0,
    referrerInfo: '',
    deviceUniqueId: '',
  }, false);
  const auth = await post('https://xxz-xyzw.hortorgames.com/login/authuser?_seq=4', Buffer.from(lxEncrypt(paramsBody)));
  if (!auth.roleToken) {
    console.log(`serverId=${serverId} → authuser 没给 roleToken（keys=${Object.keys(auth).join(',')}）\n`);
    continue;
  }
  const live = await roleInfo(auth.roleToken, auth.roleId);
  const role = live?.role || {};
  const okName = expect && role.name === expect.name;
  console.log(`serverId=${serverId}`);
  console.log(`   serverlist 期望   : name=${expect?.name}  roleId=${expect?.roleId}  power=${expect?.power}`);
  console.log(`   authuser 后实拿   : name=${role.name}  levelId=${role.levelId}  power=${role.power}  serverName=${role.serverName}`);
  console.log(`   serverViewId=${live?.serverViewId}   ${okName ? '✅ 与目标区服一致' : '❌ 与目标区服不一致'}\n`);
  await new Promise((r) => setTimeout(r, 800));
}
