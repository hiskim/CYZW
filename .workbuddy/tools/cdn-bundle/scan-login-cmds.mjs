// 在 CDN 缓存里给出所有 .jsc bundle，解密后搜索登录/选区协议常量。
// 复用 ios2-web-boot.js 里的 decryptJSC（与 decrypt.js 同一份实现，不手抄算法）。
//
// 用法：node scan-login-cmds.mjs [关键词...]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const bootPath = path.resolve(here, '../../../ios-cocos/cocos-project/src/ios2-web-boot.js');
const boot = fs.readFileSync(bootPath, 'utf8');
const m = boot.match(/function decryptJSC\(data, keyText\) \{[\s\S]*?\n        return out;\n    \}/)
  || boot.match(/function decryptJSC\(data, keyText\) \{[\s\S]*?\n        return output;\n    \}/);
if (!m) throw new Error('抠不出 decryptJSC');
const decryptJSC = new Function('return (' + m[0] + ')')();

const ROOT = path.join(process.env.HOME, 'Library/Application Support/GameLobby/CDN');
const idx = JSON.parse(fs.readFileSync(path.join(ROOT, 'index.json'), 'utf8'));
const patterns = process.argv.slice(2).length
  ? process.argv.slice(2)
  : ['login_authuser', 'login_serverlist', 'login_selectserver', 'login_unfreeze', 'Login_AuthUser'];

const keys = Object.keys(idx).filter((k) => k.includes('.jsc'));
for (const key of keys) {
  const rec = idx[key];
  const file = path.join(ROOT, 'files', rec.path);
  if (!fs.existsSync(file)) continue;
  const raw = fs.readFileSync(file);
  let out;
  let mode = 'decrypted';
  try {
    out = Buffer.from(decryptJSC(new Uint8Array(raw), '0Aed5E79bbEa69f8'));
  } catch {
    mode = 'plain';
    out = raw;
  }
  const text = out.toString('utf8');
  const hits = patterns.filter((p) => text.includes(p));
  const name = key.split('/remote/')[1];
  if (process.env.DUMP_DIR) {
    fs.mkdirSync(process.env.DUMP_DIR, { recursive: true });
    fs.writeFileSync(path.join(process.env.DUMP_DIR, name.replace(/\//g, '__')), out);
  }
  if (hits.length) {
    console.log(`✅ ${name}  ${out.length}B  ${mode}  命中: ${hits.join(', ')}`);
    for (const p of hits) {
      const i = text.indexOf(p);
      console.log(`     …${text.slice(Math.max(0, i - 120), i + 160).replace(/\n/g, ' ')}…`);
    }
  } else {
    console.log(`   ${name}  ${out.length}B  ${mode}  -`);
  }
}
