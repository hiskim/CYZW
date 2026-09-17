// 假环境行为测试：AccountProfileScript.agent（账号资料只读探针）
// 用法：node profile-agent-test.mjs
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync('/tmp/cyzw-recon/profile-agent.js', 'utf8');

function makeEnv({ role, requireRole, brokenBridge = false } = {}) {
  const posted = [];
  const logs = [];
  const timers = new Map();
  let nextId = 1;
  const clock = { now: 0 };

  const window = {
    webkit: {
      messageHandlers: {
        ios2Game: {
          postMessage: brokenBridge
            ? () => { throw new Error('bridge down'); }
            : (m) => posted.push(m),
        },
      },
    },
  };
  if (role !== undefined) window.ROLE = role;
  if (requireRole) {
    window.__require = (name) => (name === 'ServerData' ? { ROLE: requireRole } : null);
  }

  const sandbox = {
    window,
    console: { log: (...a) => logs.push(a.join(' ')) },
    setInterval: (fn, ms) => { const id = nextId++; timers.set(id, { fn, ms }); return id; },
    clearInterval: (id) => { timers.delete(id); },
    Number, Math, isFinite, String,
  };
  sandbox.globalThis = sandbox;
  sandbox.globalThis.window = window;

  const advance = (ms) => {
    const step = 50;
    for (let elapsed = 0; elapsed < ms; elapsed += step) {
      clock.now += step;
      for (const [id, t] of [...timers]) {
        if (t.next === undefined) t.next = clock.now + t.ms;
        if (clock.now >= t.next) { t.next = clock.now + t.ms; t.fn(); }
      }
    }
  };

  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return { window, posted, logs, advance, timers };
}

const results = [];
const check = (name, pass, detail = '') => {
  results.push({ name, pass, detail });
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? '  → ' + detail : ''}`);
};

// ① ROLE 未就绪：不上报，处于 waiting-role
{
  const env = makeEnv({});
  env.advance(2000);
  check('① ROLE 未就绪不上报', env.posted.length === 0, `posted=${env.posted.length}`);
  check('① 诊断串为 waiting-role',
    env.window.__LOBBY_PROFILE__.status().includes('note=waiting-role'),
    env.window.__LOBBY_PROFILE__.status());
}

// ② headImg 为空：也不上报（半成品不送过桥）
{
  const env = makeEnv({ role: { headImg: '', name: 'x' } });
  env.advance(2000);
  check('② headImg 为空不上报', env.posted.length === 0, `posted=${env.posted.length}`);
}

// ③ 首次命中：一条上报，字段完整且数值已归一
{
  const env = makeEnv({
    role: { headImg: 'https://thirdwx.qlogo.cn/mmopen/vi_32/AAA/132', name: '烟味', power: 2181261311, levelId: 750, vip: 12 },
  });
  env.advance(600);
  const msg = env.posted[0];
  check('③ 首次命中上报一条', env.posted.length === 1, `posted=${env.posted.length}`);
  check('③ 报文 type/字段正确',
    msg && msg.type === 'avatar' && msg.name === '烟味' && msg.power === 2181261311 &&
    msg.level === 750 && msg.vip === 12 && msg.headImg.endsWith('/132'),
    JSON.stringify(msg));
  check('③ 模式已转 slow',
    env.window.__LOBBY_PROFILE__.status().includes('mode=slow'),
    env.window.__LOBBY_PROFILE__.status());
}

// ④ 值不变时慢档不重复上报（去重键生效）
{
  const role = { headImg: 'https://thirdwx.qlogo.cn/mmopen/vi_32/AAA/132', name: '烟味', power: 100, levelId: 5 };
  const env = makeEnv({ role });
  env.advance(600);
  const afterFirst = env.posted.length;
  env.advance(30_000);
  check('④ 30s 慢档巡检不重复上报',
    env.posted.length === afterFirst && afterFirst === 1,
    `posted=${env.posted.length}`);
}

// ⑤ 换头像 / 升级 → 再上报一次
{
  const role = { headImg: 'https://thirdwx.qlogo.cn/mmopen/vi_32/AAA/132', name: '烟味', power: 100, levelId: 5 };
  const env = makeEnv({ role });
  env.advance(600);
  role.headImg = 'https://thirdwx.qlogo.cn/mmopen/vi_32/BBB/132';
  role.levelId = 6;
  env.advance(10_000);
  check('⑤ 资料变化后补报', env.posted.length === 2, `posted=${env.posted.length}`);
  check('⑤ 第二条带新值',
    env.posted[1]?.headImg.includes('/BBB/') && env.posted[1]?.level === 6,
    JSON.stringify(env.posted[1]));
}

// ⑥ __require('ServerData').ROLE 兜底路径
{
  const env = makeEnv({
    requireRole: { headImg: 'https://thirdwx.qlogo.cn/mmopen/vi_32/CCC/132', name: '兜底', power: 7, levelId: 1 },
  });
  env.advance(600);
  check('⑥ __require 兜底命中', env.posted.length === 1 && env.posted[0].name === '兜底',
    JSON.stringify(env.posted[0]));
}

// ⑦ 幂等：重复注入不叠加定时器、不重复上报
{
  const env = makeEnv({
    role: { headImg: 'https://thirdwx.qlogo.cn/mmopen/vi_32/AAA/132', name: '烟味', power: 100, levelId: 5 },
  });
  const before = env.timers.size;
  vm.runInContext(source, vm.createContext({
    window: env.window, console: { log() {} },
    setInterval: () => { throw new Error('重复注入又起了定时器'); },
    clearInterval: () => {}, Number, Math, isFinite, String, globalThis: {},
  }));
  check('⑦ 重复注入被哨兵挡住', env.timers.size === before, `timers=${env.timers.size}/${before}`);
  env.advance(600);
  check('⑦ 重复注入不重复上报', env.posted.length === 1, `posted=${env.posted.length}`);
}

// ⑧ 桥一开始就抛异常：不崩、标记 post-failed，且**不提交去重键**（桥恢复后必须补报）
{
  const env = makeEnv({
    role: { headImg: 'https://thirdwx.qlogo.cn/mmopen/vi_32/AAA/132', name: 'a', power: 1, levelId: 1 },
    brokenBridge: true,
  });
  env.advance(1200);
  check('⑧ 桥异常不崩且标记 post-failed',
    env.window.__LOBBY_PROFILE__.status().includes('note=post-failed'),
    env.window.__LOBBY_PROFILE__.status());
  check('⑧ 失败期间不误计上报数',
    env.window.__LOBBY_PROFILE__.status().includes('reports=0'),
    env.window.__LOBBY_PROFILE__.status());
  check('⑧ 失败期间没有送达', env.posted.length === 0, `posted=${env.posted.length}`);
  env.window.webkit.messageHandlers.ios2Game.postMessage = (m) => env.posted.push(m);
  env.advance(1000);
  check('⑧ 桥恢复后补报成功（去重键未误提交）',
    env.posted.length === 1 && env.posted[0].name === 'a',
    `posted=${env.posted.length}`);
  env.advance(30_000);
  check('⑧ 补报后回到不重复上报', env.posted.length === 1, `posted=${env.posted.length}`);
}

// ⑨ 快档超时（一直没有 ROLE）→ 转慢档并只打一条日志
{
  const env = makeEnv({});
  env.advance(400 * 300 + 4000);
  check('⑨ 快档耗尽转慢档',
    env.window.__LOBBY_PROFILE__.status().includes('mode=slow'),
    env.window.__LOBBY_PROFILE__.status());
  check('⑨ 放弃等待只记一条日志',
    env.logs.filter((l) => l.includes('gave up')).length === 1,
    `logs=${JSON.stringify(env.logs)}`);
  check('⑨ 超时后仍不上报', env.posted.length === 0, `posted=${env.posted.length}`);
}

const failed = results.filter((r) => !r.pass);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length ? 1 : 0);
