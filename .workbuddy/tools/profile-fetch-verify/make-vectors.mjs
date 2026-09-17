// 生成对拍基准：用助手仓的参考实现产出
//   ① authuser 的真实响应字节 + 参考解码的规范化 dump
//   ② 固定参数的 role_getroleinfo 外层报文的 BON 字节（十六进制）
// Swift 侧用同一份输入产出同样格式，diff 应当为空。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { g_utils, bon } from './bonProtocol.js';

const OUT = process.cwd();
fs.mkdirSync(OUT, { recursive: true });

// ── ① 真实响应 ──────────────────────────────────────────────────────────────
const bin = fs.readFileSync(path.join(os.homedir(), 'Library/Application Support/AccountBins',
  process.argv[2] || '15小惜.bin'));
const res = await fetch('https://xxz-xyzw.hortorgames.com/login/authuser?_seq=1', {
  method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: bin,
});
const raw = Buffer.from(await res.arrayBuffer());
fs.writeFileSync(path.join(OUT, 'authuser.bin'), raw);

// 规范化 dump：键排序、整数不带小数点、浮点固定 6 位、字符串 JSON 转义。
// 两边必须产出**逐字符相同**的文本，否则对拍没意义。
function canon(v) {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'number') {
    if (Number.isInteger(v)) return String(v);
    return v.toFixed(6);
  }
  if (typeof v === 'string') return JSON.stringify(v);
  if (v instanceof Uint8Array) return '<binary:' + v.length + '>';
  if (Array.isArray(v)) return '[' + v.map(canon).join(',') + ']';
  if (typeof v === 'object') {
    const keys = Object.keys(v).sort();
    return '{' + keys.map((k) => JSON.stringify(k) + ':' + canon(v[k])).join(',') + '}';
  }
  return JSON.stringify(String(v));
}

const decoded = g_utils.parse(raw).getData();
fs.writeFileSync(path.join(OUT, 'authuser.ref.dump'), canon(decoded) + '\n');
console.log(`① authuser.bin ${raw.length} 字节 → authuser.ref.dump ${canon(decoded).length} 字符`);

// ── ② 固定参数的外层报文 BON 字节 ──────────────────────────────────────────
const bodyBytes = bon.encode({
  clientVersion: '2.10.3-f10a39eaa0c409f4-wx',
  inviteUid: 0, platform: 'hortor', platformExt: 'mix', scene: '',
});
const message = { cmd: 'role_getroleinfo', ack: 0, seq: 1, time: 1758000000000, body: bodyBytes };
const frame = bon.encode(message);
fs.writeFileSync(path.join(OUT, 'request.ref.hex'), Buffer.from(frame).toString('hex') + '\n');
fs.writeFileSync(path.join(OUT, 'request-body.ref.hex'), Buffer.from(bodyBytes).toString('hex') + '\n');
console.log(`② request.ref.hex ${frame.length} 字节 / body ${bodyBytes.length} 字节`);
console.log(`   body hex 头 16 字节：${Buffer.from(bodyBytes.subarray(0, 16)).toString('hex')}`);

// ── ③ WSS 的 role_getroleinforesp：字段最多、嵌套最深，是解码器的真考验 ──────
const auth = g_utils.parse(raw).getData();
const now = Date.now();
const token = JSON.stringify({
  ...auth,
  sessId: now * 100 + Math.floor(Math.random() * 100),
  connId: now + Math.floor(Math.random() * 10),
  isRestore: 0,
});
const ws = new WebSocket(
  `wss://xxz-xyzw.hortorgames.com/agent?p=${encodeURIComponent(token)}&e=x&lang=chinese`);
ws.binaryType = 'arraybuffer';
ws.onopen = () => ws.send(g_utils.encode({
  cmd: 'role_getroleinfo', ack: 0, seq: 1, time: 1758000000000, body: bodyBytes,
}, 'x'));
ws.onmessage = (evt) => {
  const u8 = new Uint8Array(evt.data);
  // ⚠️ 参考实现的 decrypt 是**就地修改**输入数组的（XOR 回去 + 返回 subarray(4)）。
  // 所以要在调用它**之前**把原始线上字节存下来，否则存下来的是「已解密的帧」，
  // 拿它当信封去对拍会得到莫名其妙的失败（我踩了这一次）。
  fs.writeFileSync(path.join(OUT, 'roleinfo-envelope.bin'), Buffer.from(u8));
  const plain = g_utils.getEnc('auto').decrypt(u8);
  fs.writeFileSync(path.join(OUT, 'roleinfo.bin'), Buffer.from(plain));
  const outer = bon.decode(plain);
  fs.writeFileSync(path.join(OUT, 'roleinfo.ref.dump'), canon(outer) + '\n');
  // 外层报文的 body 是**再一层 BON 编码**的字节串，真正的角色数据在里面
  const inner = bon.decode(outer.body);
  fs.writeFileSync(path.join(OUT, 'roleinfo-inner.ref.dump'), canon(inner) + '\n');
  console.log(`③ roleinfo.bin ${plain.length} 字节（信封 ${u8.length} 字节）`);
  console.log(`   外层 dump ${canon(outer).length} 字符 / 内层 dump ${canon(inner).length} 字符`);
  process.exit(0);
};
setTimeout(() => { console.log('③ 超时'); process.exit(3); }, 15000);
