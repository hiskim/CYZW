// 定位：游戏自己的 `/login/serverlist` 为什么拿不到区服列表（「选择大区」是空的）。
//
// 游戏侧调用（game.js `SelectServerModule.getServerData`）：
//   LoginService.serverList({ platform, oriPlatform, platformExt,
//                             info: JSON.stringify(PlatformManager.instance.encryptUserInfo),
//                             areaId: 0 })
// 注意 `info` 来自 **SDK**（`encryptUserInfo`）。宿主如果没有把它喂给页面，
// 这里就是 `JSON.stringify(undefined)` → 字段直接消失 → 服务端认不出账号。
//
// 四个变体一次只变一个变量：
//   ① 裸 .bin（我们对 /login/serverlist 的已知可用姿势，作基准）
//   ② 参数体 + bin 的 info（模拟"SDK 正确喂了 info"）
//   ③ 参数体 + 没有 info（模拟"encryptUserInfo 是 undefined"）
//   ④ 参数体 + info 用 BON 对象形态（bin 里如果是对象就是这个形态）
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { g_utils, bon } from './bonProtocol.js';

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
import lz4 from 'lz4js';

let obj = bon.decode(lxDecrypt(bytes));
if (obj && typeof obj.getData === 'function') obj = obj.getData();
const infoRaw = obj.info;
const infoString = typeof infoRaw === 'string' ? infoRaw : JSON.stringify(infoRaw);
console.log(`凭据 ${fileName}：serverId=${obj.serverId}  platform=${obj.platform}  info 形态=${typeof infoRaw}`);

async function post(label, body, { header = true } = {}) {
  const headers = { 'Content-Type': 'application/octet-stream' };
  if (header) headers['O4e-Encoding'] = 'lx';
  const res = await fetch('https://xxz-xyzw.hortorgames.com/login/serverlist?_seq=3', {
    method: 'POST', headers, body: Buffer.from(body),
  });
  const buf = Buffer.from(await res.arrayBuffer());
  let data = null;
  try { data = g_utils.parse(buf).getData(); } catch (error) { data = { parseError: error.message }; }
  const areas = data?.areaList ? Object.keys(data.areaList).length : 0;
  const servers = data?.serverList ? Object.keys(data.serverList).length : 0;
  const roles = data?.roles ? Object.keys(data.roles).length : 0;
  const verdict = roles > 0 ? '✅ 有角色' : '❌ 没有角色';
  console.log(`   ${label.padEnd(34)} HTTP ${res.status} ${String(buf.length).padStart(8)}B  ` +
    `area=${areas} server=${servers} role=${roles}  code=${data?.code ?? '-'} error=${data?.error ?? '-'}  ${verdict}`);
  return data;
}

// ① 裸 .bin（基准）
await post('① 裸 .bin（基准）', bytes);

// ②/③/④ 参数体
function paramsBody({ withInfo }) {
  const fields = [
    ['platform', obj.platform],
    ['oriPlatform', obj.platform],
    ['platformExt', obj.platformExt],
  ];
  if (withInfo === 'string') fields.push(['info', infoString]);
  if (withInfo === 'object') fields.push(['info', infoRaw]);
  fields.push(['areaId', 0]);
  return g_utils.encode(Object.fromEntries(fields));
}
await post('② 参数体 + info(string)', paramsBody({ withInfo: 'string' }));
await post('③ 参数体 + 无 info', paramsBody({ withInfo: null }));
await post('④ 参数体 + info(对象)', paramsBody({ withInfo: 'object' }));

// ⑤ 参数体 + 无 info，但**不带 O4e-Encoding 头**（换编码试试）
await post('⑤ 参数体+无info 不带编码头', paramsBody({ withInfo: null }), { header: false });

// ⑥ 参数体（无 info）但用 x 方案编码 + 不带头
await post('⑥ 参数体+无info 走 x 方案', g_utils.encode(
  { platform: obj.platform, oriPlatform: obj.platform, platformExt: obj.platformExt, areaId: 0 }), { header: false });
