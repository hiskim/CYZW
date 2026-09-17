// 探测：.bin 明文结构（lx 方案 = LZ4 + 头部掩码）
// 用法：node dump-bin.mjs '11不不.bin' '14001服-温酒.bin'
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import lz4 from 'lz4js';
import { bon } from './bonProtocol.js';

const BIN_DIR = path.join(os.homedir(), 'Library/Application Support/AccountBins');

function lxDecrypt(input) {
  const e = Uint8Array.from(input);
  if (!(e.length > 4 && e[0] === 0x70 && e[1] === 0x6c)) return e;
  const t =
    (((e[2] >> 6) & 1) << 7) |
    (((e[2] >> 4) & 1) << 6) |
    (((e[2] >> 2) & 1) << 5) |
    ((e[2] & 1) << 4) |
    (((e[3] >> 6) & 1) << 3) |
    (((e[3] >> 4) & 1) << 2) |
    (((e[3] >> 2) & 1) << 1) |
    (e[3] & 1);
  for (let n = Math.min(100, e.length); --n >= 2; ) e[n] ^= t;
  e[0] = 4; e[1] = 34; e[2] = 77; e[3] = 24;
  return lz4.decompress(e);
}

function show(value, depth = 0) {
  if (value === null || value === undefined) return String(value);
  if (value instanceof Uint8Array) {
    return `Uint8Array(${value.length}) utf8="${Buffer.from(value).subarray(0, 120).toString('utf8')}"`;
  }
  if (typeof value === 'object') {
    if (value.high !== undefined && value.low !== undefined) {
      return ((BigInt(value.high >>> 0) << 32n) | BigInt(value.low >>> 0)).toString();
    }
    if (depth > 2) return JSON.stringify(value).slice(0, 300);
    const parts = Object.entries(value).map(([k, v]) => `${k}=${show(v, depth + 1)}`);
    return `{ ${parts.join(', ')} }`;
  }
  return JSON.stringify(value);
}

for (const fileName of process.argv.slice(2)) {
  const p = path.join(BIN_DIR, fileName);
  if (!fs.existsSync(p)) { console.log(`\n===== ${fileName} 不存在`); continue; }
  const bytes = fs.readFileSync(p);
  console.log(`\n===== ${fileName}   ${bytes.length} 字节   head=${bytes.subarray(0, 8).toString('hex')}`);
  let obj = null;
  try {
    const plain = lxDecrypt(bytes);
    console.log(`  LZ4 解出 ${plain.length} 字节，前 8 字节 ${Buffer.from(plain.subarray(0, 8)).toString('hex')}`);
    obj = bon.decode(plain);
    if (obj && typeof obj.getData === 'function') obj = obj.getData();
  } catch (error) {
    console.log(`  解码失败：${error.message}`);
  }
  if (!obj) { console.log('  解析结果为空'); continue; }
  for (const [k, v] of Object.entries(obj)) {
    const text = show(v);
    console.log(`  ${k} = ${text.length > 400 ? text.slice(0, 400) + '…' : text}`);
  }
}
