// 探测：游戏服务端能用 .bin 凭据直接拿到哪些账号资料（不启动游戏、不连 WSS）。
// 参考实现：/Users/gg/code/xyzw_web_helper（src/utils/token.ts 的两个 POST）
//
// 用法：node probe.mjs [bin文件名]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { g_utils } from './bonProtocol.js';

const BIN_DIR = path.join(os.homedir(), 'Library/Application Support/AccountBins');
const fileName = process.argv[2] || '11不不.bin';
const binPath = path.join(BIN_DIR, fileName);

const bytes = fs.readFileSync(binPath);
console.log(`凭据：${fileName}（${bytes.length} 字节）\n`);

// 服务端返回的东西里有 Int64 之类的对象，普通 stringify 会丢结构，这里递归展开。
function plain(value, depth = 0) {
  if (depth > 6 || value === null) return value;
  if (typeof value === 'bigint') return value.toString();
  if (Array.isArray(value)) return value.map((v) => plain(v, depth + 1));
  if (value && typeof value === 'object') {
    if (value.high !== undefined && value.low !== undefined) {
      // Int64：按无符号拼一下，方便和游戏里显示的数字对照
      const v = (BigInt(value.high >>> 0) << 32n) | BigInt(value.low >>> 0);
      return { int64: v.toString(), high: value.high, low: value.low };
    }
    if (typeof value.getData === 'function') return plain(value.getData(), depth + 1);
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = plain(v, depth + 1);
    return out;
  }
  return value;
}

async function post(endpoint, seq, buffer) {
  const url = `https://xxz-xyzw.hortorgames.com/${endpoint}?_seq=${seq}`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/octet-stream' },
    body: buffer,
  });
  return { status: res.status, buf: Buffer.from(await res.arrayBuffer()) };
}

// ① /login/serverlist —— 助手的「导入 .bin 后选角色」走的就是这条
{
  const { status, buf } = await post('login/serverlist', 3, bytes);
  console.log(`① POST /login/serverlist  →  HTTP ${status}，${buf.length} 字节`);
  console.log(`   前 16 字节：${buf.subarray(0, 16).toString('hex')}`);
  try {
    const msg = g_utils.parse(buf);
    const data = msg.getData();
    const roles = data?.roles;
    console.log(`   解析出 data 的键：${Object.keys(data || {}).join(', ')}`);
    if (roles) {
      const list = Object.values(roles);
      console.log(`   角色数：${list.length}`);
      console.log(`   每个角色的字段：${Object.keys(list[0] || {}).join(', ')}`);
      for (const r of list.slice(0, 6)) {
        console.log('   ---');
        console.log('   ' + JSON.stringify(plain(r), null, 2).replace(/\n/g, '\n   '));
      }
    } else {
      console.log('   完整 data：' + JSON.stringify(plain(data), null, 2));
    }
  } catch (error) {
    console.log(`   解析失败：${error.message}`);
  }
}
