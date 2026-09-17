// 定位：我们自己造的「只存不压」LZ4 帧为什么被服务端拒（error=指令解析错误）。
// 三向对照，一次只变一个变量：
//   ① 参考实现 lz4js 的真压缩帧（已知可用）
//   ② 只存不压帧，帧头校验和抄 ① 的
//   ③ 只存不压帧，帧头校验和写 0（Swift 侧现在的做法）
// 用法：node probe-lx-variants.mjs '11不不.bin'
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

// 与参考实现 lx.encrypt 同序：掩码从 min(100,len)-1 一路异或到 0，再写 magic 与密钥位
function lxMask(frame) {
  const e = Uint8Array.from(frame);
  const t = 2 + ~~(Math.random() * 248);
  for (let n = Math.min(100, e.length); --n >= 0; ) e[n] ^= t;
  e[0] = 112; e[1] = 108;
  e[2] = (e[2] & 0b10101010) | (((t >> 7) & 1) << 6) | (((t >> 6) & 1) << 4) | (((t >> 5) & 1) << 2) | ((t >> 4) & 1);
  e[3] = (e[3] & 0b10101010) | (((t >> 3) & 1) << 6) | (((t >> 2) & 1) << 4) | (((t >> 1) & 1) << 2) | (t & 1);
  return e;
}

// 只存不压：magic + FLG + BD + HC + 每块 [0x80000000|size][原样字节] + EndMark
function storeFrame(plain, { flg, bd, hc }) {
  const out = [0x04, 0x22, 0x4d, 0x18, flg, bd, hc];
  const maxBlock = 64 * 1024;
  for (let offset = 0; offset < plain.length; offset += maxBlock) {
    const size = Math.min(maxBlock, plain.length - offset);
    const header = (size | 0x80000000) >>> 0;
    out.push(header & 0xff, (header >>> 8) & 0xff, (header >>> 16) & 0xff, (header >>> 24) & 0xff);
    for (let i = 0; i < size; i++) out.push(plain[offset + i]);
  }
  out.push(0, 0, 0, 0);
  return Uint8Array.from(out);
}

let obj = bon.decode(lxDecrypt(raw));
if (obj && typeof obj.getData === 'function') obj = obj.getData();
const target = Number(process.argv[3] || 26533);
const plain = bon.encode({ ...obj, serverId: target }, false);

async function post(body, label) {
  const res = await fetch('https://xxz-xyzw.hortorgames.com/login/authuser?_seq=1', {
    method: 'POST',
    headers: { 'Content-Type': 'application/octet-stream', 'O4e-Encoding': 'lx' },
    body: Buffer.from(body),
  });
  const buf = Buffer.from(await res.arrayBuffer());
  let data = {};
  try { data = g_utils.parse(buf).getData() || {}; } catch {}
  const ok = !!data.roleToken;
  console.log(`   ${label.padEnd(40)} HTTP ${res.status} ${buf.length}B  ${ok ? '✅ roleToken' : '❌ ' + (data.error ?? JSON.stringify(Object.keys(data)))}`);
  return ok;
}

const reference = lz4.compress(plain);           // ① 真压缩帧（解掩码后的形态）
const flg = reference[4], bd = reference[5], hc = reference[6];
console.log(`参考压缩帧：${reference.length} 字节  FLG=0x${flg.toString(16)} BD=0x${bd.toString(16)} HC=0x${hc.toString(16)}`);
console.log(`明文 ${plain.length} 字节；目标 serverId=${target}\n`);

console.log('打 authuser（都带 O4e-Encoding: lx）：');
await post(lxMask(reference), '① 参考实现真压缩帧');
await post(lxMask(storeFrame(plain, { flg, bd, hc })), '② 只存不压 + 抄来的 HC');
await post(lxMask(storeFrame(plain, { flg, bd, hc: 0 })), '③ 只存不压 + HC=0（Swift 现状）');

// 顺带确认：我们的只存不压帧能不能被参考实现解开（能解 = 帧本身合法）
const decoded = lz4.decompress(storeFrame(plain, { flg, bd, hc: 0 }));
const same = Buffer.from(decoded).equals(Buffer.from(plain));
console.log(`\n参考实现解「只存不压」帧：${same ? '✅ 与明文逐字节一致' : '❌ 不一致'}`);
