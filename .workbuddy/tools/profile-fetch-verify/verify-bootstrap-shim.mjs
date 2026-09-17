// 页面引导脚本（XHR 垫片）的离线验证：在假 window 里跑**真实产物**，断言每条请求的去向。
//
// 为什么要有它：垫片现在有三种去向，任何一种走错都只在开游戏时才看得出来，
// 而「错」的表现往往只是「界面是空的」——
//   ① `/login/authuser`          → 交给原生代理（不回落到网络）
//   ② `/login/serverlist`        → **把体换成凭据**再发（服务端只认凭据体）
//   ③ 其它                        → 原样放行，body 不许被改
// 另外还要验：原生回填能完成挂起的那条 XHR、凭据缺失时退回原样放行。
//
// 用法：node verify-bootstrap-shim.mjs <bootstrap.js> [<bootstrap-no-credential.js>]
import fs from 'node:fs';

let failed = 0;
function check(label, ok, detail) {
  console.log(`   ${ok ? '✅' : '❌'} ${label}${ok || !detail ? '' : ' — ' + detail}`);
  if (!ok) failed++;
}

/** 造一个可以观测的假 XHR。 */
function makeHarness() {
  const sent = [];
  const posts = [];
  class FakeXHR {
    constructor() {
      this.headers = {};
      this.openedWith = null;
      this.body = undefined;
    }
    open(method, url) { this.openedWith = { method, url }; this.readyState = 1; }
    setRequestHeader(name, value) { this.headers[String(name).toLowerCase()] = value; }
    send(body) { this.body = body; sent.push(this); }
    abort() { this.aborted = true; }
    getAllResponseHeaders() { return ''; }
    getResponseHeader() { return null; }
  }
  const window = {
    XMLHttpRequest: FakeXHR,
    addEventListener() {},
    webkit: { messageHandlers: { ios2Game: { postMessage: (message) => posts.push(message) } } },
    localStorage: { getItem: () => null, setItem() {} },
  };
  window.window = window;
  return { window, sent, posts };
}

/** 在假 window 里跑一份引导脚本，返回可观测的现场。 */
function run(scriptSource) {
  const harness = makeHarness();
  const { window } = harness;
  const console_ = console;
  const sandboxConsole = {
    log: (...args) => console_.log('      [page]', ...args),
    info: () => {},
    warn: (...args) => console_.log('      [page:warn]', ...args),
    error: (...args) => console_.log('      [page:error]', ...args),
    debug: () => {},
  };
  const fn = new Function('window', 'document', 'console', 'atob', 'btoa', 'setTimeout',
                          'clearTimeout', 'String', scriptSource);
  fn(window, { createElement: () => ({ style: {}, remove() {} }) }, sandboxConsole,
     globalThis.atob, globalThis.btoa, setTimeout, clearTimeout, String);
  return harness;
}

// ── ① 有凭据的引导脚本 ────────────────────────────────────────────────────
const scriptPath = process.argv[2];
if (!scriptPath) {
  console.error('用法：node verify-bootstrap-shim.mjs <bootstrap.js> [<bootstrap-no-credential.js>]');
  process.exit(2);
}
const script = fs.readFileSync(scriptPath, 'utf8');
console.log(`引导脚本 ${script.length} 字符\n`);

{
  const { window, sent, posts } = run(script);
  const base = 'https://xxz-xyzw.hortorgames.com';

  console.log('① /login/authuser 交给原生代理，不落到网络');
  const auth = new window.XMLHttpRequest();
  auth.open('POST', base + '/login/authuser?_seq=1');
  auth.send(new Uint8Array([1, 2, 3, 4]).buffer);
  const authPost = posts.find((m) => m.type === 'loginAuth');
  check('发出了 loginAuth 上报', !!authPost, JSON.stringify(posts.map((m) => m.type)));
  check('没有真的发这条请求', sent.length === 0, `sent=${sent.length}`);
  check('上报里带 requestId / body', !!authPost?.requestId && typeof authPost.body === 'string',
        JSON.stringify(authPost));
  check('上报的 body 是原请求体（base64）', authPost?.body === 'AQIDBA==', authPost?.body);

  console.log('\n② 原生回填能完成那条挂起的 XHR');
  const forged = globalThis.btoa('ANSWER-BYTES-1234');
  const done = window.__LOBBY_LOGIN__.complete(authPost.requestId, forged, 'derived');
  check('complete() 认领成功', done === true);
  const answered = new Uint8Array(auth.response ?? new ArrayBuffer(0));
  check('XHR 拿到了回填字节', answered.length === 'ANSWER-BYTES-1234'.length,
        `length=${answered.length}`);
  check('readyState 到 4 / status 200', auth.readyState === 4 && auth.status === 200,
        `readyState=${auth.readyState} status=${auth.status}`);

  console.log('\n③ /login/serverlist 由宿主代发（自定义头页面发不出去）');
  const list = new window.XMLHttpRequest();
  list.open('POST', base + '/login/serverlist?_seq=3');
  list.responseType = 'arraybuffer';
  list.send(new Uint8Array([9, 9, 9]).buffer);
  check('不落到网络（由原生代发）', !sent.includes(list._native), `sent=${sent.length}`);
  check('上报里带 kind=serverList',
        posts.some((m) => m.type === 'loginAuth' && m.kind === 'serverList'),
        JSON.stringify(posts.filter((m) => m.type === 'loginAuth').map((m) => m.kind)));
  const serverListPost = posts.find((m) => m.type === 'loginAuth' && m.kind === 'serverList');
  check('上报里带 requestId', !!serverListPost?.requestId, JSON.stringify(serverListPost));

  console.log('   原生回填 → XHR 拿到字节');
  const forgedList = globalThis.btoa('SERVERLIST-BYTES-HERE');
  const listDone = window.__LOBBY_LOGIN__.complete(serverListPost.requestId, forgedList, 'native-serverlist');
  check('complete() 认领成功', listDone === true);
  const listBytes = new Uint8Array(list.response ?? new ArrayBuffer(0));
  check('XHR 拿到回填字节', listBytes.length === 'SERVERLIST-BYTES-HERE'.length, `length=${listBytes.length}`);
  check('readyState=4 / status=200', list.readyState === 4 && list.status === 200,
        `readyState=${list.readyState} status=${list.status}`);
  check('响应头是二进制（游戏按 lx 解）',
        /octet-stream/.test(list.getAllResponseHeaders() || ''), list.getAllResponseHeaders());

  console.log('\n④ 其它请求原样放行（body 一字不改）');
  const other = new window.XMLHttpRequest();
  other.open('POST', base + '/role/getroleinfo?_seq=7');
  const original = new Uint8Array([7, 7]).buffer;
  other.send(original);
  check('发给了网络', sent.includes(other._native));
  check('body 原样', other._native.body === original);
  check('没有塞编码头', other._native.headers['o4e-encoding'] === undefined,
        JSON.stringify(other._native.headers));

  console.log('\n⑤ 凭据缺失时退回原样放行（前向/回退兼容）');
  const noCredentialPath = process.argv[3];
  if (!noCredentialPath) {
    console.log('   （未提供无凭据脚本，跳过）');
  } else {
    const plain = run(fs.readFileSync(noCredentialPath, 'utf8'));
    const fallback = new plain.window.XMLHttpRequest();
    fallback.open('POST', base + '/login/serverlist?_seq=3');
    const paramBody = new Uint8Array([9, 9, 9]).buffer;
    fallback.send(paramBody);
    check('仍然是放行到网络', plain.sent.includes(fallback._native));
    check('body 没被替换（退化为改造前行为）', fallback._native.body === paramBody);
    check('没有塞编码头', fallback._native.headers['o4e-encoding'] === undefined);
    check('credentialBytes() = 0', plain.window.__LOBBY_LOGIN__.credentialBytes() === 0);
  }

  console.log('\n⑥ 诊断计数（出问题时唯一的判据就是它）');
  const stats = JSON.parse(window.__LOBBY_LOGIN__.stats());
  check('authXHR 计到 1（authuser 走过代理）', stats.authXHR === 1, JSON.stringify(stats));
  check('serverListXHR 计到 1（serverlist 走了原生代发）', stats.serverListXHR === 1, JSON.stringify(stats));
  check('passthroughLoginXHR 为 0（没有漏网的 /login/*）', stats.passthroughLoginXHR === 0,
        JSON.stringify(stats));
  check('credentialBytes() = 凭据长度', window.__LOBBY_LOGIN__.credentialBytes() === 28,
        String(window.__LOBBY_LOGIN__.credentialBytes()));
}

// ── ⑦ 解析补丁：给服务端响应补上游戏解析器要的字段 ──────────────────────────
// 实测响应是 `{areaList, serverList, roleCount, recommendId, roles}`，
// 缺 `deletedRoles` / `maxViewId` —— 前者缺失会让 `_parseFirstServerList`
// 第一句就 `e.deletedRoles.forEach` 抛异常，列表永远填不上（而且没有报错可看）。
{
  console.log('\n⑦ SelectServerModule 解析补丁');
  const harness = run(script);
  const w = harness.window;
  let originalArgs = null;
  let originalCalled = 0;
  function SelectServerModule() {}
  SelectServerModule.prototype._parseFirstServerList = function (data) {
    originalCalled++; originalArgs = data;
    // 复刻游戏第一句：`e.deletedRoles.forEach(...)` —— 补丁没生效这里就抛。
    data.deletedRoles.forEach(function () {});
    return 'parsed';
  };
  SelectServerModule.prototype._parseServerList = SelectServerModule.prototype._parseFirstServerList;
  w.__require = (name) => (name === 'SelectServerModule' ? { SelectServerModule } : null);

  await new Promise((r) => setTimeout(r, 700));   // 轮询一拍是 500ms
  check('解析方法已被包住', !!SelectServerModule.prototype._parseFirstServerList.__lobbyPatched);
  check('统计里 parseHooked=true',
        JSON.parse(w.__LOBBY_LOGIN__.stats()).parseHooked === true);
  check('补丁安装通过 postMessage 上报',
        harness.posts.some((m) => m.type === 'loginDiag' && /解析补丁已挂上/.test(m.message || '')),
        JSON.stringify(harness.posts.map((m) => m.type)));

  // 模拟服务端响应（只有 5 个字段，正是线上的样子）
  const response = {
    areaList: [{ areaId: 1 }],
    serverList: [{ id: 1, viewId: 1 }, { id: 26501, viewId: 29501 }],
    roleCount: {},
    recommendId: 14028,
    roles: {},
  };
  const instance = new SelectServerModule();
  const returned = instance._parseFirstServerList(response);
  check('原实现被调用且拿到同一个对象', originalCalled === 1 && originalArgs === response);
  check('返回值原样透传', returned === 'parsed');
  check('补上了 deletedRoles（必须是 Map，游戏按 `0 < i.size` / `i.forEach` 用）',
        response.deletedRoles instanceof Map);
  check('补上了 maxViewId（由 serverList[].viewId 推得）', response.maxViewId === 29501,
        String(response.maxViewId));
  check('原有字段没被动过', response.recommendId === 14028 && response.serverList.length === 2);
  check('统计里记下了服务器数量',
        JSON.parse(w.__LOBBY_LOGIN__.stats()).parsedServers === 2);
}

// ── ⑧ 垫片健壮性：任何 URL 都不许抛，统计字段必须齐全 ────────────────────────
// 这条是有血的教训的：曾经往统计里加字段却漏了初始化，于是 `open()` 在
// `/login/*` 上抛异常 —— 游戏直接卡在「正在加载游戏场景」，而且没有任何报错。
{
  console.log('\n⑧ 垫片健壮性（open/send 绝不许抛）');
  const h = run(script);
  const w = h.window;
  const stats = JSON.parse(w.__LOBBY_LOGIN__.stats());
  for (const key of ['authXHR', 'credentialXHR', 'passthroughLoginXHR',
                     'passthroughPaths', 'parseHooked', 'wsLoginCmds']) {
    check(`统计字段 ${key} 存在`, Object.prototype.hasOwnProperty.call(stats, key),
          JSON.stringify(stats));
  }
  const urls = ['https://x/login/authuser?_seq=1', 'https://x/login/serverlist?_seq=3',
                'https://x/login/dataversion?_seq=9', 'https://x/login/', 'https://x/login',
                'https://x/role/getroleinfo', '', null, undefined,
                'ios2-game://app/index.html', 'https://x/login/serverlist'];
  let thrown = 0;
  for (const url of urls) {
    try {
      const probe = new w.XMLHttpRequest();
      probe.open('POST', url);
      probe.send(new Uint8Array([1, 2]).buffer);
    } catch (error) {
      thrown++;
      console.log(`      [throw] ${String(url)} → ${error.message}`);
    }
  }
  check('全部 URL 的 open/send 都不抛', thrown === 0, `${thrown} 个抛出`);
  const after = JSON.parse(w.__LOBBY_LOGIN__.stats());
  check('未接管的 /login/* 被记进 passthroughPaths',
        (after.passthroughPaths || []).includes('dataversion'), JSON.stringify(after.passthroughPaths));
  check('计数与路径一致', after.passthroughLoginXHR >= (after.passthroughPaths || []).length);
}

console.log(failed === 0 ? '\n✅ 引导脚本垫片全部通过' : `\n❌ ${failed} 项不通过`);
process.exit(failed === 0 ? 0 : 1);
