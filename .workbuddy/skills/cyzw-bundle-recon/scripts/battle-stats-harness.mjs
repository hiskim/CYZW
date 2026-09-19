// 「战斗数据（攻/盾/血/怒）」的假环境测试。
//
//   AGENT_JS=/tmp/recon/agent.js node battle-stats-harness.mjs
//
// 搭的是一套**假战斗实体**：SystemHeadBoard._updateLifeAndRage 会被游戏逐帧调用，
// 里面自己去 getComponent 拿 life / rage / shield / attributes / headBoard——
// 这正是代理「借游戏的手拿组件」（包装 getComponent 一个调用周期）能生效的前提。
// 所以这里必须让假 update **真的去调 entity.getComponent**，否则测不出捕获路径。
import fs from 'node:fs';

const AGENT_PATH = process.env.AGENT_JS || '/tmp/recon/agent.js';
const agentSource = fs.readFileSync(AGENT_PATH, 'utf8');

let fakeNow = 5_000_000;
Date.now = () => fakeNow;

// ── 极简 DOM（帧率角标要用；本测试不启用它，但脚本初始化时会摸 document）──
const noop = () => {};
global.window = global;
global.document = {
  readyState: 'complete', hidden: false,
  addEventListener: noop, removeEventListener: noop, getElementById: () => null,
  createElement: () => ({ style: {}, parentNode: null, textContent: '', setAttribute: noop }),
  body: { appendChild: noop, removeChild: noop },
};
global.addEventListener = noop;
global.removeEventListener = noop;
global.location = { search: '', href: 'https://example.invalid/' };
global.performance = { now: () => fakeNow };

// ── 假 cc（颜色转换要用）──
global.cc = {
  Color: function Color() { this.hex = ''; },
};
global.cc.Color.fromHEX = function (color, hex) { color.hex = hex; return color; };

// ── 假 FairyGUI：只需要 GTextField 的 text / 尺寸 / 父子关系 ──
const boardChildren = [];
function makeTextField() {
  return {
    text: '', visible: true, fontSize: 20, color: null, touchable: true,
    singleLine: false, align: '', verticalAlign: '', parent: null,
    textWidth: 0,
    setSize(width, height) { this.width = width; this.height = height; },
    setPosition(x, y) { this.x = x; this.y = y; },
    removeFromParent() {
      if (this.parent) {
        const index = this.parent.children.indexOf(this);
        if (index >= 0) this.parent.children.splice(index, 1);
        this.parent = null;
      }
    },
  };
}
global.fgui = {
  AutoSizeType: { None: 0, Both: 1 },
  GTextField: function GTextField() { return makeTextField(); },
};

// ── 假战斗实体组件 ──
const LifeClass = function Life() {};
const RageClass = function Rage() {};
const ShieldClass = function Shield() {};
const AttributesClass = function CompAttributes() {};
const BuffFlyClass = function CompBuffFlyEffect() {};
BuffFlyClass.prototype.setPosition = function (x, y) { this.last = [x, y]; return this; };

// 官方角色名模板（代理要克隆它的样式并把名字藏起来）
const nameTemplate = makeTextField();
nameTemplate.text = '逍遥·小号A';
nameTemplate.fontSize = 20;
const nameParent = {
  visible: true,
  m_name: nameTemplate,
  getChild: () => null,
};
const lifeBar = { x: 10, y: 0, _barObjectH: { x: 0, y: 0, width: 80, height: 6, initWidth: 80 } };
const rageBar = { x: 10, y: 30, _barObjectH: { x: 0, y: 0, width: 80, height: 6, initWidth: 80 } };
const boardParent = {
  visible: true,
  children: boardChildren,
  m_lifeBar: lifeBar,
  m_rageBar: rageBar,
  addChild(child) { child.parent = this; this.children.push(child); },
  removeChild(child) { child.removeFromParent(); },
};

const life = { current: 1234567, max: 2000000, isInfinite: () => false };
const rage = { current: 88, max: 100 };
const shield = { getAllArmor: () => 45678 };
const attributes = {
  _get(key) {
    // 11 = ATTACK_FIGHTING（参考实现的兜底候选键），1 = ATTACK_ABS
    if (key === 11) return 987654;
    if (key === 1) return 111111;
    return null;
  },
};
const headBoard = { boardDisplay: { ui: boardParent }, nameDisplay: { ui: nameParent } };

function makeEntity(id) {
  return {
    ID: id,
    actor: { id: id, camp: 1 },
    getComponent(klass) {
      if (klass === LifeClass) return life;
      if (klass === RageClass) return rage;
      if (klass === ShieldClass) return shield;
      if (klass === AttributesClass) return attributes;
      return null;   // headBoard 走捕获列表（游戏自己 getComponent(HeadClass) 之外还会遍历）
    },
  };
}
const HeadBoardClass = function SystemHeadBoard() {};
const originalUpdate = function (entity) {
  // 游戏自己会问这几个组件 —— 代理正是借此收集「本帧用到的组件」
  entity.getComponent(LifeClass);
  entity.getComponent(RageClass);
  entity.getComponent(ShieldClass);
  entity.getComponent(AttributesClass);
  entity.getComponent(HeadBoardClass);      // 返回 null，但捕获列表里要能认出 headBoard
  return 'updated';
};
HeadBoardClass.prototype._updateLifeAndRage = originalUpdate;
HeadBoardClass.prototype.onEntityRemoved = function () { return 'removed'; };

// headBoard 组件本身要能被认出（boardDisplay/nameDisplay）
const headBoardComponent = {
  boardDisplay: { ui: boardParent }, nameDisplay: { ui: nameParent },
};
const entity = makeEntity(9527);
const entityGetComponent = entity.getComponent;
entity.getComponent = function (klass) {
  if (klass === HeadBoardClass) return headBoardComponent;
  return entityGetComponent.call(this, klass);
};

// ── 模块表 ──
let modules = {
  'system-head-board': { SystemHeadBoard: HeadBoardClass },
  'comp-attributes': { CompAttributes: AttributesClass },
  'comp-buff-fly-effect': { CompBuffFlyEffect: BuffFlyClass },
  'Configs': { BattleAttributeKey: { ATTACK_ABS: 1, ATTACK: 5, ATTACK_FIGHTING: 11 } },
};
global.__require = (id) => {
  if (!modules[id]) throw new Error('module not found: ' + id);
  return modules[id];
};

eval(agentSource);
const api = global.__LOBBY_ENHANCE__;

const failures = [];
const expect = (ok, label) => {
  if (!ok) failures.push(label);
  console.log((ok ? 'PASS' : 'FAIL') + ' - ' + label);
};
const battleOf = (text) => (text.split(' battle=')[1] || '').split(' note=')[0];
const apply = (config) => api.apply(Object.assign(
  { enabled: false, speed: 100, hideChat: false, uiSpeedEnabled: false, uiSpeed: 3,
    fpsDisplay: false, battleStats: false }, config));
const labelsOf = () => boardParent.children.filter((child) => child.name);
const byName = (name) => boardParent.children.find((child) => child.name === name);
const tick = () => HeadBoardClass.prototype._updateLifeAndRage.call(new HeadBoardClass(), entity);

(async () => {
  console.log('初始 status:', api.status().split(' battle=')[1].split(' note=')[0]);

  // ① 开启即装钩子（模块已可解析）
  apply({ battleStats: true });
  expect(HeadBoardClass.prototype._updateLifeAndRage.__lobbyBattlePatched === true,
         '开启 → _updateLifeAndRage 已被包装');
  expect(battleOf(api.status()).startsWith('1/'), 'status 报 battle=1');

  // ② 走一帧：4 个标签画上血条容器，官方名字被藏起来
  tick();
  expect(labelsOf().length === 4, `一帧后画出 4 个标签（现在 ${labelsOf().length} 个）`);
  expect(byName('lobbyBattleStat-attack') && byName('lobbyBattleStat-attack').text === '攻98.8万',
         `攻读出候选键 11 的值并格式化为「万」（现在 ${byName('lobbyBattleStat-attack') && byName('lobbyBattleStat-attack').text}）`);
  expect(byName('lobbyBattleStat-shield').text === '盾4.6万',
         `盾读 getAllArmor（现在 ${byName('lobbyBattleStat-shield').text}）`);
  expect(byName('lobbyBattleStat-hp').text === '血123.5万',
         `血读 life.current（现在 ${byName('lobbyBattleStat-hp').text}）`);
  expect(byName('lobbyBattleStat-rage').text === '怒88',
         `怒读 rage.current（现在 ${byName('lobbyBattleStat-rage').text}）`);
  expect(nameTemplate.visible === false, '官方角色名被隐藏（原生样式的来源）');
  expect(byName('lobbyBattleStat-attack').color && byName('lobbyBattleStat-attack').color.hex === '#FFD45A',
         '攻用语义色 #FFD45A');
  expect(byName('lobbyBattleStat-attack').fontSize === 16,
         `字号按官方模板 ×0.78 并封顶 16（现在 ${byName('lobbyBattleStat-attack').fontSize}）`);
  // 布局：攻/盾/血 在血条上方三行（y 递减），怒在怒气条下方
  const ys = ['attack', 'shield', 'hp'].map((kind) => byName('lobbyBattleStat-' + kind).y);
  expect(ys[0] < ys[1] && ys[1] < ys[2], '攻/盾/血 自上而下排（y 递增）');
  expect(byName('lobbyBattleStat-rage').y === rageBar.y + rageBar._barObjectH.height,
         '怒贴在怒气条下方');

  // ③ 数值变化 + 快采样（50ms 路径）
  life.current = 800;
  rage.current = 100;
  fakeNow += 200;
  tick();
  expect(byName('lobbyBattleStat-hp').text === '血800', `血量跟着变（现在 ${byName('lobbyBattleStat-hp').text}）`);
  life.current = 700;
  fakeNow += 60;                 // 只过 60ms：全量采样被 120ms 节流挡下，靠 50ms 快采样刷新
  tick();
  expect(byName('lobbyBattleStat-hp').text === '血700', '50ms 快采样刷新血量（不必等 120ms 全量）');

  // ④ 实体离场 → 标签摘掉、官方名字还原
  HeadBoardClass.prototype.onEntityRemoved.call(new HeadBoardClass(), entity);
  expect(labelsOf().length === 0, '实体离场后标签清空');
  expect(nameTemplate.visible === true && nameTemplate.text === '逍遥·小号A',
         '官方角色名的可见性与文本原样还原');

  // ⑤ 关闭 → 原型还原
  apply({ battleStats: false });
  expect(HeadBoardClass.prototype._updateLifeAndRage === originalUpdate,
         '关闭 → _updateLifeAndRage 还原为原函数');
  expect(battleOf(api.status()).startsWith('0/'), 'status 报 battle=0');

  // ⑥ 模块还没加载（先进游戏再开开关）：报 waiting，不抛错；模块出现后能装上
  modules = {};
  apply({ battleStats: true });
  expect(api.status().includes('bNote=battle-waiting-module'), '模块缺失 → bNote=battle-waiting-module');
  expect(HeadBoardClass.prototype._updateLifeAndRage === originalUpdate, '模块缺失时不乱改原型');
  modules = { 'system-head-board': { SystemHeadBoard: HeadBoardClass },
              'comp-attributes': { CompAttributes: AttributesClass },
              'Configs': { BattleAttributeKey: { ATTACK_ABS: 1, ATTACK_FIGHTING: 11 } } };
  await new Promise((resolve) => setTimeout(resolve, 700));    // 等一次 500ms 轮询
  expect(HeadBoardClass.prototype._updateLifeAndRage.__lobbyBattlePatched === true,
         '模块出现后被轮询装上钩子（战斗里开关随时生效）');

  apply({ battleStats: false });
  console.log(failures.length ? `\n${failures.length} 项失败：\n- ${failures.join('\n- ')}` : '\n全部通过');
  process.exit(failures.length ? 1 : 0);
})();
