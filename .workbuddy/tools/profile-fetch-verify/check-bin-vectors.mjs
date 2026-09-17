// `.bin` 凭据对拍的结果核对（node 侧）。
//
// 两件事：
//   ① 明文**逐字节**相同（sha256）——LZ4 帧解压器与参考实现严格一致；
//   ② 派生凭据**字段一致**（规范化 dump）——换服改写只动了 serverId，
//      且参考实现能解开我们产的凭据（互操作）。
// 派生凭据的字节不可能相同（x 信封里有随机头与随机掩码），所以比结构不比字节。
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { g_utils, bon } from './bonProtocol.js';

const WORK = process.cwd();
let failed = 0;

function sha256(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex');
}
function check(label, ok, detail) {
  if (ok) {
    console.log(`   ✅ ${label}`);
  } else {
    failed++;
    console.log(`   ❌ ${label}${detail ? ' — ' + detail : ''}`);
  }
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
function read(name) {
  return fs.readFileSync(path.join(WORK, name));
}
function exists(name) {
  return fs.existsSync(path.join(WORK, name));
}

// ── ① 明文逐字节 ──────────────────────────────────────────────────────────
const referencePlain = read('bin.plain.bin');
if (!exists('swift-bin-plain.bin')) {
  console.log('   ❌ Swift 侧没有产出明文（parity-bin 提前失败了）');
  process.exit(1);
}
const swiftPlain = read('swift-bin-plain.bin');
check(`明文逐字节一致（${referencePlain.length} 字节  sha256=${sha256(referencePlain).slice(0, 16)}…）`,
  referencePlain.length === swiftPlain.length && sha256(referencePlain) === sha256(swiftPlain),
  `参考 ${referencePlain.length}B / Swift ${swiftPlain.length}B`);

// ── ② 明文的对象 dump ─────────────────────────────────────────────────────
const referenceDump = fs.readFileSync(path.join(WORK, 'bin.ref.dump'), 'utf8').trim();
const swiftDump = fs.readFileSync(path.join(WORK, 'swift-bin.ref.dump'), 'utf8').trim();
check('明文对象 dump 一致（键排序、逐字符）', referenceDump === swiftDump,
  referenceDump === swiftDump ? '' : `参考 ${referenceDump.length} 字符 / Swift ${swiftDump.length} 字符`);

// 参考实现的明文必须也能被它自己解回来 —— 顺带证明我们拿到的是同一份明文
let referenceObject = null;
try {
  const decoded = bon.decode(referencePlain);
  referenceObject = decoded && typeof decoded.getData === 'function' ? decoded.getData() : decoded;
  check('参考实现解自己的明文成功', !!referenceObject);
} catch (error) {
  check('参考实现解自己的明文成功', false, error.message);
}

// ── ③ 派生凭据：参考实现能不能解开我们产的 ──────────────────────────────
// ⚠️ 凭据是**裸对象**（没有 `cmd` 外壳），不能用 `g_utils.parse(...).getData()`——
// 那是给 `{cmd, body}` 报文用的，对裸对象返回 undefined（两边都一样，会假失败）。
// 正确姿势：剥信封 → `bon.decode`。
function decodeCredential(buf) {
  const plain = g_utils.getEnc('auto').decrypt(new Uint8Array(buf));
  return bon.decode(plain);
}

const targets = fs.readFileSync(path.join(WORK, 'bin.targets.txt'), 'utf8')
  .split('\n').map((s) => s.trim()).filter(Boolean).map(Number);

if (targets.length === 0) {
  console.log('   ❌ bin.targets.txt 为空');
  failed++;
}

for (const target of targets) {
  const file = `swift-derived-${target}.bin`;
  if (!exists(file)) {
    check(`派生 serverId=${target} 存在`, false, `${file} 缺失`);
    continue;
  }
  const bytes = read(file);
  let decoded = null;
  try {
    decoded = decodeCredential(bytes);
  } catch (error) {
    check(`派生 serverId=${target} 能被参考实现解开`, false, error.message);
    continue;
  }
  const expected = referenceObject ? { ...referenceObject, serverId: target } : null;
  const sameStructure = expected && canon(decoded) === canon(expected);
  check(`派生 serverId=${target} 能解开且字段只剩 serverId 变化（${bytes.length} 字节）`,
    decoded && Number(decoded.serverId) === target && sameStructure,
    decoded ? `serverId=${decoded.serverId} 结构${sameStructure ? '一致' : '不一致'}` : '解不开');
  check(`派生 serverId=${target} 的字段集合未变`,
    decoded && referenceObject &&
      Object.keys(decoded).sort().join(',') === Object.keys(referenceObject).sort().join(','));
  check(`派生 serverId=${target} 的 platform/platformExt/info 形态未变`,
    decoded && referenceObject &&
      decoded.platform === referenceObject.platform &&
      decoded.platformExt === referenceObject.platformExt &&
      typeof decoded.info === typeof referenceObject.info);
}

// ── ④ 参考实现的派生凭据：同一套解码器读它，结果必须与预期一致
//      （这一步同时证明上面的解码方法本身是对的，排除「两边都错」）
for (const target of targets) {
  const file = `bin-derived-${target}.bin`;
  if (!exists(file)) {
    check(`${file} 存在`, false);
    continue;
  }
  try {
    const decoded = decodeCredential(read(file));
    check(`参考实现的派生凭据 ${file} 可解码且 serverId=${target}`,
      Number(decoded.serverId) === target, `实得 serverId=${decoded.serverId}`);
  } catch (error) {
    check(`参考实现的派生凭据 ${file} 可解码`, false, error.message);
  }
}

if (failed > 0) {
  console.log(`\n❌ ${failed} 项不通过`);
  process.exit(1);
}
console.log('\n✅ .bin 凭据对拍全部通过');
