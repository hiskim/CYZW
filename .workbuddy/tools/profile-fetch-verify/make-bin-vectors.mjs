// 生成 `.bin` 凭据的对拍基准（**纯本地，不联网、不建会话**）。
//
//   ① bin.raw            —— 原始 .bin（lx 信封）
//   ② bin.plain.bin      —— 参考实现（lz4js + bonProtocol）解出的 BON 明文
//   ③ bin.ref.dump       —— 明文对象的规范化 dump（键排序）
//   ④ bin-derived-*.bin  —— 参考实现产出的「换服后」凭据
//
// Swift 侧（parity-bin.swift）用同一份输入产出同格式产物，由
// check-bin-vectors.mjs 做**双向**比对：
//   · 我们的解 = 参考的解（逐字节）
//   · 参考能解开我们产的凭据，且字段与参考产的完全一致（互操作）
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import lz4 from 'lz4js';
import { g_utils, bon } from './bonProtocol.js';

const OUT = process.cwd();
const file = process.argv[2] || '11不不.bin';
const bin = fs.readFileSync(path.join(os.homedir(), 'Library/Application Support/AccountBins', file));

fs.writeFileSync(path.join(OUT, 'bin.raw'), bin);

// 与 Swift 侧同一套：从 [2][3] 反解掩码 → 从尾往头 XOR → 还原 LZ4 帧 magic → 解压
function openLX(input) {
  const e = Uint8Array.from(input);
  const t =
    (((e[2] >> 6) & 1) << 7) | (((e[2] >> 4) & 1) << 6) | (((e[2] >> 2) & 1) << 5) |
    ((e[2] & 1) << 4) | (((e[3] >> 6) & 1) << 3) | (((e[3] >> 4) & 1) << 2) |
    (((e[3] >> 2) & 1) << 1) | (e[3] & 1);
  for (let n = Math.min(100, e.length); --n >= 2; ) e[n] ^= t;
  e[0] = 4; e[1] = 34; e[2] = 77; e[3] = 24;
  return lz4.decompress(e);
}

function canon(v) {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'number') return Number.isInteger(v) ? String(v) : v.toFixed(6);
  if (typeof v === 'string') return JSON.stringify(v);
  if (v instanceof Uint8Array) return '<binary:' + v.length + '>';
  if (Array.isArray(v)) return '[' + v.map(canon).join(',') + ']';
  if (typeof v === 'object') {
    const keys = Object.keys(v).sort();
    return '{' + keys.map((k) => JSON.stringify(k) + ':' + canon(v[k])).join(',') + '}';
  }
  return JSON.stringify(String(v));
}

const plain = openLX(bin);
fs.writeFileSync(path.join(OUT, 'bin.plain.bin'), Buffer.from(plain));

let obj = bon.decode(plain);
if (obj && typeof obj.getData === 'function') obj = obj.getData();
fs.writeFileSync(path.join(OUT, 'bin.ref.dump'), canon(obj) + '\n');
fs.writeFileSync(path.join(OUT, 'bin.ref.json'), JSON.stringify({
  serverId: obj.serverId,
  platform: obj.platform,
  platformExt: obj.platformExt,
  keys: Object.keys(obj),
  infoIsObject: obj.info !== null && typeof obj.info === 'object' && !(obj.info instanceof Uint8Array),
}) + '\n');

console.log(`① ${file} ${bin.length} 字节 → 明文 ${plain.length} 字节`);
console.log(`② serverId=${obj.serverId}（= ${Number(obj.serverId) - 27} 服）  platform=${obj.platform} platformExt=${obj.platformExt}`);
console.log(`   字段顺序：${Object.keys(obj).join(', ')}   info 形态：${typeof obj.info}`);

// ④ 参考实现产出的换服凭据（用 x 方案，与 Swift 侧同一条路径）
const targets = (process.argv[3] || '').split(',').filter(Boolean).map(Number);
const list = targets.length ? targets : [Number(obj.serverId) === 4046 ? 9365 : 4046];
for (const serverId of list) {
  const derived = g_utils.encode({ ...obj, serverId });
  fs.writeFileSync(path.join(OUT, `bin-derived-${serverId}.bin`), Buffer.from(derived));
  fs.writeFileSync(path.join(OUT, `bin-derived-${serverId}.ref.dump`),
    canon({ ...obj, serverId }) + '\n');
  console.log(`④ 派生 serverId=${serverId} → bin-derived-${serverId}.bin（${derived.byteLength} 字节）`);
}
fs.writeFileSync(path.join(OUT, 'bin.targets.txt'), list.map(String).join('\n') + '\n');
