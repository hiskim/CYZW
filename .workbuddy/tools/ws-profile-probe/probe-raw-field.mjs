// 假设：游戏自己的 login_* 请求里还带一个 `_raw`（= 凭据字节），
// 只有它才能让服务端认账 —— 这是从"上号器"的 authUser hook 里看出来的：
//   if (raw !== undefined) loginRequest._raw = raw;
//   // raw = codec.encrypt(codec.lz4XorEncode(plain))，即重编码后的 .bin
// 所以只要给参数体补上 `_raw`，服务端就应该像收到裸 .bin 一样回应。
//
// 用法：node probe-raw-field.mjs '11不不.bin' [serverId]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import lz4 from 'lz4js';
import { g_utils, bon } from './bonProtocol.js';

const BIN_DIR = path.join(os.homedir(), 'Library/Application Support/AccountBins');
const fileName = process.argv[2] || '11不不.bin';
const raw = fs.readFileSync(path.join(BIN_DIR, fileName));

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

let obj = bon.decode(lxDecrypt(raw));
if (obj && typeof obj.getData === 'function') obj = obj.getData();
const infoString = typeof obj.info === 'string' ? obj.info : JSON.stringify(obj.info);

async function post(endpoint, seq, label, body) {
  const res = await fetch(`https://xxz-xyzw.hortorgames.com/${endpoint}?_seq=${seq}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/octet-stream', 'O4e-Encoding': 'lx' },
    body: Buffer.from(body),
  });
  const buf = Buffer.from(await res.arrayBuffer());
  let data = {};
  try { data = g_utils.parse(buf).getData() || {}; } catch (error) { data = { parseError: error.message }; }
  const areas = data.areaList ? Object.keys(data.areaList).length : 0;
  const servers = data.serverList ? Object.keys(data.serverList).length : 0;
  const roles = data.roles ? Object.keys(data.roles).length : 0;
  console.log(`   ${label.padEnd(30)} HTTP ${res.status} ${String(buf.length).padStart(8)}B  ` +
    `area=${areas} server=${servers} role=${roles}` +
    (data.roleToken ? `  roleToken=${String(data.roleToken).length}字符 roleId=${data.roleId}` : '') +
    (data.error ? `  error=${data.error}` : ''));
  return data;
}

const binBody = { ...obj };
const paramsOnly = {
  platform: obj.platform, oriPlatform: obj.platform, platformExt: obj.platformExt,
  info: infoString, areaId: 0,
};
const paramsWithRaw = { ...paramsOnly, _raw: new Uint8Array(raw) };

console.log(`凭据 ${fileName}：serverId=${obj.serverId}\n`);

console.log('── /login/serverlist（选择大区/服务器的数据源）');
await post('login/serverlist', 3, '① 裸 .bin（基准）', binBody._raw ?? raw);
await post('login/serverlist', 3, '② 参数体（无 _raw）', g_utils.encode(paramsOnly));
await post('login/serverlist', 3, '③ 参数体 + _raw', g_utils.encode(paramsWithRaw));

console.log('\n── /login/authuser（换服登录）');
await post('login/authuser', 1, '① 裸 .bin（基准）', binBody._raw ?? raw);
await post('login/authuser', 1, '② 参数体（无 _raw）', g_utils.encode(paramsOnly));
await post('login/authuser', 1, '③ 参数体 + _raw', g_utils.encode(paramsWithRaw));

// 换服：改 serverId 后重编码再当 _raw
const target = Number(process.argv[3] || 26533);
const derivedPlain = bon.encode({ ...obj, serverId: target }, false);
const derivedRaw = g_utils.encode({ ...obj, serverId: target });
console.log(`\n── 换服到 serverId=${target}`);
await post('login/serverlist', 3, '④ 参数体 + _raw(目标区)',
  g_utils.encode({ ...paramsOnly, _raw: new Uint8Array(derivedRaw) }));
const auth = await post('login/authuser', 1, '④ 参数体 + _raw(目标区)',
  g_utils.encode({ ...paramsOnly, serverId: target, _raw: new Uint8Array(derivedRaw) }));

// 决定性验证：拿这次 authuser 的 token 去 WSS 看落在哪个角色
if (auth.roleToken) {
  const now = Date.now();
  const token = JSON.stringify({
    ...auth, sessId: now * 100 + Math.floor(Math.random() * 100),
    connId: now + Math.floor(Math.random() * 10), isRestore: 0,
  });
  const ws = new WebSocket(`wss://xxz-xyzw.hortorgames.com/agent?p=${encodeURIComponent(token)}&e=x&lang=chinese`);
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => ws.send(g_utils.encode({
    cmd: 'role_getroleinfo', ack: 0, seq: 1, time: Date.now(),
    body: bon.encode({ clientVersion: '2.10.3-f10a39eaa0c409f4-wx', inviteUid: 0, platform: 'hortor', platformExt: 'mix', scene: '' }),
  }, 'x'));
  ws.onmessage = (evt) => {
    if (typeof evt.data === 'string') return;
    let msg; try { msg = g_utils.parse(Buffer.from(evt.data)); } catch { return; }
    if (!/getroleinfo/.test(String(msg.cmd))) return;
    const role = msg.getData()?.role ?? {};
    console.log(`   WSS 实拿：roleId=${role.roleId} name=${role.name} serverId=${role.serverId} serverName=${role.serverName}`);
    process.exit(0);
  };
  setTimeout(() => { console.log('   WSS 超时'); process.exit(3); }, 12000);
}
