// ② /login/authuser 的返回结构（纯 HTTP，不建立游戏会话）
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { g_utils } from './bonProtocol.js';

const BIN_DIR = path.join(os.homedir(), 'Library/Application Support/AccountBins');
const fileName = process.argv[2] || '11不不.bin';
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

const res = await fetch('https://xxz-xyzw.hortorgames.com/login/authuser?_seq=1', {
  method: 'POST',
  headers: { 'Content-Type': 'application/octet-stream' },
  body: bytes,
});
const buf = Buffer.from(await res.arrayBuffer());
console.log(`HTTP ${res.status}，${buf.length} 字节，前 16 字节 ${buf.subarray(0, 16).toString('hex')}\n`);

const msg = g_utils.parse(buf);
const data = msg.getData();
const flat = plain(data);
const json = JSON.stringify(flat);

console.log('data 顶层键：' + Object.keys(data || {}).join(', '));
console.log('含 headImg ?  ' + /headImg/i.test(json));
console.log('含 qlogo   ?  ' + /qlogo/i.test(json));
console.log('含 power   ?  ' + /"power"/i.test(json));
console.log('含 level   ?  ' + /"level/i.test(json));
console.log('');

// 递归找所有含 headImg / power 的路径，看看它们挂在哪
const hits = [];
(function walk(node, trail) {
  if (!node || typeof node !== 'object' || trail.length > 4) return;
  for (const [k, v] of Object.entries(node)) {
    const p = [...trail, k];
    if (/headimg|avatar|qlogo|power|level/i.test(k)) {
      const shown = typeof v === 'object' ? JSON.stringify(v).slice(0, 90) : String(v).slice(0, 90);
      hits.push(`${p.join('.')} = ${shown}`);
    }
    walk(v, p);
  }
})(flat, []);
console.log(`命中字段（最多 40 条）：`);
for (const line of hits.slice(0, 40)) console.log('  ' + line);

console.log('\n完整 data（截断 3000 字符）：');
console.log(JSON.stringify(flat, null, 2).slice(0, 3000));
