// 实验：批量改 serverId 打 authuser，观察 roleId 是否变化 + 看完整 authuser 返回
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import lz4 from 'lz4js';
import { bon, g_utils } from './bonProtocol.js';

const BIN_DIR = path.join(os.homedir(), 'Library/Application Support/AccountBins');
const fileName = process.argv[2] || '11不不.bin';
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
async function authUser(body) {
  const res = await fetch('https://xxz-xyzw.hortorgames.com/login/authuser?_seq=1', {
    method: 'POST',
    headers: { 'Content-Type': 'application/octet-stream', 'O4e-Encoding': 'lx', Connection: 'close' },
    body,
  });
  const buf = Buffer.from(await res.arrayBuffer());
  return { status: res.status, ...(g_utils.parse(buf).getData() || {}) };
}

const obj = bon.decode(lxDecrypt(bytes));
const base = obj && typeof obj.getData === 'function' ? obj.getData() : obj;
console.log(`原 bin serverId=${base.serverId}\n`);

const original = await authUser(bytes);
console.log('原始 authuser 全部字段：');
for (const [k, v] of Object.entries(original)) {
  const s = typeof v === 'object' && v !== null ? JSON.stringify(v) : String(v);
  console.log(`   ${k} = ${s.length > 120 ? s.slice(0, 120) + '…' : s}`);
}

// serverlist 拿全部角色
const slRes = await fetch('https://xxz-xyzw.hortorgames.com/login/serverlist?_seq=3', {
  method: 'POST',
  headers: { 'Content-Type': 'application/octet-stream', 'O4e-Encoding': 'lx' },
  body: bytes,
});
const sl = g_utils.parse(Buffer.from(await slRes.arrayBuffer())).getData();
const roles = Object.values(sl.roles || {});
console.log(`\nserverlist 共 ${roles.length} 个角色；逐个改 serverId 打 authuser：`);
for (const r of roles) {
  const clone = { ...base, serverId: Number(r.serverId) };
  const res = await authUser(Buffer.from(lxEncrypt(bon.encode(clone, false))));
  const match = Number(res.roleId) === Number(r.roleId) ? '✅ 命中该角色' : '';
  console.log(`   serverId=${String(r.serverId).padStart(7)} (${String(r.name).padEnd(10)}) → authuser.roleId=${res.roleId} ${match}`);
  await new Promise((r2) => setTimeout(r2, 250));
}
