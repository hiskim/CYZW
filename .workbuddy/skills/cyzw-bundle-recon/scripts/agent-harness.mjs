import fs from 'node:fs';
import vm from 'node:vm';

const AGENT_PATH = process.env.AGENT_JS || '/tmp/recon/agent.js';
const agentSource = fs.readFileSync(AGENT_PATH, 'utf8');

// ── 假 FairyGUI ───────────────────────────────────────────────────────────
// 指纹取自线上 UI_NewChatPanel.onConstruct 的 getChild 列表。
const CHILD_NAMES = ['chatList', 'inputComp', 'input', 'btnSend'];

function makePanel({ visible = true } = {}) {
  const children = {};
  for (const name of CHILD_NAMES) children[name] = { _name: name };
  const panel = {
    _disposed: false,
    visible,
    _kids: [],
    numChildren: 0,
    // 游戏里这些是 onConstruct 绑好的成员变量（不是 getChild 动态查的）
    m_chatList: children.chatList,
    m_inputComp: children.inputComp,
    m_input: children.input,
    m_btnSend: children.btnSend,
    proxy: null,
    parent: null,
    getChild() { return null; },     // 成员变量已覆盖指纹，这里返回 null 更严格
    getChildAt(index) { return this._kids[index] || null; }
  };
  return panel;
}

function makeNode(proxy = null) {
  return {
    _kids: [],
    numChildren: 0,
    visible: true,                 // 真实 GComponent 默认可见，压之前是 true
    proxy,
    parent: null,
    getChild() { return null; },
    getChildAt(index) { return this._kids[index] || null; }
  };
}

function attach(parent, child) {
  parent._kids.push(child);
  parent.numChildren = parent._kids.length;
  child.parent = parent;
  return child;
}

// ── 假 UI 框架：层 → skinUI → m_container → ui ────────────────────────────
// 依据线上 UIProxy._addUI / _setSkin：
//   skin = metadata.skin.createInstance(); container = getDeepChild(skin, 'Container');
//   skin.parent = parentUI; container.addChild(ui); (skin.proxy = controller).skinUI = skin;
function makeSkinWindow({ visible = true } = {}) {
  const controller = { name: 'FakeChatPanelProxy' };
  const ui = makePanel({ visible });
  ui.proxy = controller;                        // _awake: (this.ui.proxy = this)

  const container = makeNode();                 // proxy 不设（真实里也是普通节点）
  const skin = makeNode(controller);            // skinUI.proxy = 同一个控制器
  const layer = makeNode();
  attach(skin, container);
  attach(container, ui);
  attach(layer, skin);

  // 外壳自身的标题头 / 遮罩（skin 的子节点，隐藏 skin 时一并消失）
  attach(skin, makeNode());
  attach(skin, makeNode());

  return { controller, ui, container, skin, layer };
}

// 没有 skin 的窗口：层 → ui（UIProxy._addUI 的 else 分支）
function makeBareWindow({ visible = true } = {}) {
  const controller = { name: 'FakeBareProxy' };
  const ui = makePanel({ visible });
  ui.proxy = controller;
  const layer = makeNode();
  attach(layer, ui);
  return { controller, ui, layer };
}

// ── 假游戏模块表 ─────────────────────────────────────────────────────────
const onShowCalls = [];
class FakeChatPanel {
  constructor(ui) { this.ui = ui; }
  onShow() { onShowCalls.push(this.ui); }
}
const modules = { ChatPanel: { NewChatPanel: FakeChatPanel } };

// cc 场景节点（`$gobj` 回指 fgui 对象）
function makeCcNode(gobj = null) {
  return { children: [], $gobj: gobj, parent: null };
}

function buildEnv({
  withRequire = true,
  withRoot = true,
  grootThrows = false,    // 模拟 GRoot.create 之前：inst getter 会抛
  withScene = false,      // 只给 cc 场景（$gobj），不给 fgui 树
  window: win = null
} = {}) {
  const built = win || makeSkinWindow();
  const root = withRoot ? makeNode() : null;
  if (root) attach(root, built.layer);

  // fgui.GRoot：inst 是会抛异常的 getter（与线上 runtime 一致）
  const fgui = {};
  if (withRoot || grootThrows) {
    const holder = { _inst: withRoot ? root : null };
    Object.defineProperty(holder, 'inst', {
      get() { if (this._inst) return this._inst; throw new Error('Call GRoot.create first!'); }
    });
    fgui.GRoot = holder;
  }

  // cc 场景：节点上挂 $gobj
  let scene = null;
  if (withScene) {
    scene = makeCcNode(null);
    const holder = makeCcNode(built.ui);
    scene.children.push(holder);
  }

  const page = {
    console,
    setInterval, clearInterval, setTimeout,
    fgui: Object.keys(fgui).length ? fgui : undefined,
    cc: scene ? { director: { getScene: () => scene } } : undefined
  };
  if (withRequire) page.__require = (name) => modules[name] || null;
  const sandbox = { window: page, console, setInterval, clearInterval, setTimeout };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  new vm.Script(agentSource, { filename: 'agent.js' }).runInContext(sandbox);
  return { win: page, ...built, root, scene };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let pass = 0, fail = 0;
function check(label, ok, detail) {
  if (ok) { pass += 1; console.log('  OK   ' + label + (detail ? ' — ' + detail : '')); }
  else { fail += 1; console.log('  FAIL ' + label + (detail ? ' — ' + detail : '')); }
}
const hide = (win, on) => win.__LOBBY_ENHANCE__.apply({ enabled: false, speed: 100, hideChat: on });

// ═══ 1. 关态不干扰 ═══════════════════════════════════════════════════════
console.log('\n[1] 关态：什么都不做');
{
  const { win, ui, skin } = buildEnv();
  const r = hide(win, false);
  check('ui 与外壳都可见', ui.visible === true && skin.visible === true);
  check('status = chat=0/0 skin=0', r.includes('chat=0/0') && r.includes('skin=0'), r);
}

// ═══ 2. 开态：隐藏的是**外壳**（旧版只压 ui → 留空壳） ═══════════════════
console.log('\n[2] 开态：外壳整体不显示（回归点）');
{
  const { win, ui, skin, container } = buildEnv();
  const r = hide(win, true);
  check('皮肤外壳被压成不可见', skin.visible === false);
  check('内容组件挂在 skin 的 container 里（一起被隐藏）',
        skin._kids.includes(container) && container._kids.includes(ui));
  check('status 记为 chat=1/1 skin=1/1', r.includes('chat=1/1') && r.includes('skin=1/1'), r);
  check('chatNote=chat-hidden', r.includes('chatNote=chat-hidden'), r);
  check('onShow 钩子已装上', FakeChatPanel.prototype.onShow.__lobbyChatHiddenPatched === true);
}

// ═══ 3. 游戏自己重新显示外壳 → 压回 ═════════════════════════════════════
console.log('\n[3] 游戏重显 → 下一拍压回');
{
  const { win, skin } = buildEnv();
  hide(win, true);
  skin.visible = true;
  await sleep(400);
  check('轮询把外壳压回不可见', skin.visible === false);
}

// ═══ 4. onShow 钩子：新窗口同帧压住 ═════════════════════════════════════
console.log('\n[4] onShow 钩子零闪烁');
{
  const { win } = buildEnv();
  hide(win, true);
  const fresh = makeSkinWindow({ visible: false });
  new FakeChatPanel(fresh.ui).onShow();
  check('新窗口的外壳同帧被压成不可见', fresh.skin.visible === false);
  check('onShow 原始逻辑仍被调用', onShowCalls.includes(fresh.ui));
}

// ═══ 5. 还原 ═════════════════════════════════════════════════════════════
console.log('\n[5] 关态：还原');
{
  const { win, skin } = buildEnv();
  hide(win, true);
  hide(win, false);
  check('原本可见的外壳被放回来', skin.visible === true);

  const { win: win2, skin: skin2 } = buildEnv({ window: makeSkinWindow() });
  skin2.visible = false;                    // 游戏本来就不想显示它
  hide(win2, true);
  hide(win2, false);
  check('原本不可见的外壳不被硬弹出来', skin2.visible === false);
}

// ═══ 6. 降级路径 ═════════════════════════════════════════════════════════
console.log('\n[6] 降级：缺 __require / 缺 GRoot 不能抛错');
{
  const { win, skin } = buildEnv({ withRequire: false, withRoot: false });
  const r = hide(win, true);
  check('不抛错且外壳原样', skin.visible === true);
  check('note 说明卡在 GRoot', r.includes('chat-waiting-root'), r);
}
{
  const { win, skin } = buildEnv({ withRequire: false });
  const r = hide(win, true);
  check('无 __require 时扫树兜底生效', skin.visible === false, r);
}

// ═══ 7. 没有 skin 的窗口 → 隐藏 ui 本身 ═══════════════════════════════════
console.log('\n[7] 无 skin 的窗口（有的聊天窗走 ChatDialog/TopChatDialog）');
{
  const { win, ui } = buildEnv({ window: makeBareWindow() });
  const r = hide(win, true);
  check('直接隐藏 ui', ui.visible === false);
  check('skin=0/1（如实标记没解析到外壳）', r.includes('skin=0/1'), r);
}

// ═══ 8. 与十殿加速并存 ═══════════════════════════════════════════════════
console.log('\n[8] 与十殿加速并存');
{
  const { win, skin } = buildEnv();
  const r1 = win.__LOBBY_ENHANCE__.apply({ enabled: true, speed: 250, hideChat: true });
  check('两者同时生效', skin.visible === false && r1.includes('speed=250'), r1);
  const r2 = win.__LOBBY_ENHANCE__.apply({ enabled: true, speed: 250, hideChat: false });
  check('只关聊天、十殿不受影响', r2.includes('running=1') && r2.includes('chat=0/0'), r2);
}

// ═══ 9. 幂等 ═════════════════════════════════════════════════════════════
console.log('\n[9] 幂等：重复下发不叠加');
{
  const { win } = buildEnv();
  const before = FakeChatPanel.prototype.onShow;
  for (let i = 0; i < 5; i++) hide(win, true);
  check('钩子只包一层', FakeChatPanel.prototype.onShow === before);
  const r = hide(win, true);
  check('窗口没有重复入册（chat=1/1）', r.includes('chat=1/1'), r);
}

// ═══ 10. GRoot 会抛异常时不能整条路径被吃掉 ══════════════════════════════
console.log('\n[10] GRoot.inst 抛异常（create 之前）');
{
  // 只有会抛的 getter、没有 _inst；但有 cc 场景 → 走 scene 路径
  const { win, skin } = buildEnv({ withRoot: false, grootThrows: true, withScene: true });
  const r = hide(win, true);
  check('getter 抛异常不影响找面板', skin.visible === false, r);
  check('诊断标明走的是 scene 路径', r.includes('root=scene'), r);
}
{
  const { win, skin } = buildEnv({ withRoot: false, grootThrows: true });
  const r = hide(win, true);
  check('rethrow 被吃掉、不崩', skin.visible === true);
  check('如实报 no-root / chat-waiting-root',
        r.includes('root=no-root') && r.includes('chat-waiting-root'), r);
}
{
  // 有 fgui 树也有场景：优先 groot，且不重复入册
  const { win, skin } = buildEnv({ withScene: true });
  const r = hide(win, true);
  check('两条路径都有时优先 groot 且只入册一次',
        r.includes('root=groot') && r.includes('chat=1/1'), r);
  check('外壳被压住', skin.visible === false);
}
{
  // 有根、但这局里根本没有聊天面板（没进过主城）
  const layer = makeNode();
  const empty = makeNode();
  attach(layer, empty);
  const { win } = buildEnv({ window: { ui: empty, layer } });
  const r = hide(win, true);
  check('无面板时报 no-panel / chat-waiting-panel（不误报 no-root）',
        r.includes('root=no-panel') && r.includes('chat-waiting-panel'), r);
}

// ═══ 11. 元数据名字兜底匹配（成员变量没绑上时） ═══════════════════════════
console.log('\n[11] 成员变量缺失时按 packageItem.name 命中');
{
  // 面板若是被别的路径造出来的，onConstruct 没跑过 → m_chatList 等全没有，
  // 只有包内元件名还在。这条路径必须能兜住。
  const controller = { name: 'FakeChatPanelProxy' };
  const bare = makeNode();
  bare.packageItem = { name: 'NewChatPanel' };
  bare.proxy = controller;
  const container = makeNode();
  const shell = makeNode(controller);
  const layer = makeNode();
  attach(shell, container);
  attach(container, bare);
  attach(layer, shell);

  const { win } = buildEnv({ window: { ui: bare, skin: shell, layer } });
  const r = hide(win, true);
  check('按名字命中并压住外壳', shell.visible === false, r);
  check('仍然解析出 skin 外壳', r.includes('skin=1/1'), r);
}

// ═══ 12. 主城聊天框 MainPanelChat（成员变量完全不同） ═════════════════════
console.log('\n[12] 主城聊天框：m_chatItemList 指纹 / packageItem.name');
{
  // 复刻线上：UI_MainPanel.m_chat = getChild("chat")，类型是 ui_main/MainPanelChat。
  // 它没有 proxy（不是窗口），所以外壳解析应退回它自己。
  const mainPanel = makeNode();                 // UI_MainPanel 的 ui
  const chat = makeNode();
  chat.m_chatItemList = { numItems: 3 };        // 指纹三
  chat.packageItem = { name: 'MainPanelChat' }; // 指纹二
  attach(mainPanel, chat);

  const { win } = buildEnv({ window: { ui: mainPanel, layer: mainPanel } });
  const r = hide(win, true);
  check('主城聊天框被隐藏', chat.visible === false, r);
  check('没有 proxy 时退回自身（skin=0/1）', r.includes('skin=0/1'), r);
  check('父面板不受影响', mainPanel.visible === true);
}
{
  // 只有 packageItem.name，成员一个都没有
  const mainPanel = makeNode();
  const chat = makeNode();
  chat.packageItem = { name: 'MainPanelChat' };
  attach(mainPanel, chat);
  const { win } = buildEnv({ window: { ui: mainPanel, layer: mainPanel } });
  const r = hide(win, true);
  check('按 packageItem.name 也能命中', chat.visible === false, r);
}

// ═══ 13. 构造 / 复用守门：进主城不再闪一下 ══════════════════════════════
console.log('\n[13] 构造 / 复用守门（fgui 对象池会调 resetVisible）');
{
  // 复刻 fgui 的对象池路径：复用组件时 resetVisible() 会把 visible 拉回 true。
  const base = { onConstruct() {}, resetVisible() { this.visible = true; } };
  function FakeMainPanelChat() {}
  FakeMainPanelChat.prototype = Object.create(base);
  FakeMainPanelChat.prototype.constructor = FakeMainPanelChat;
  FakeMainPanelChat.URL = 'ui://8fweejrdlmbhm';
  modules['UI_MainPanelChat'] = { default: FakeMainPanelChat };

  const holder = makeNode();
  const { win } = buildEnv({ window: { ui: holder, layer: holder } });
  const r = hide(win, true);
  check('生成类守门已挂上（mh>0）', !r.includes('mh=0'), r);

  const fresh = new FakeMainPanelChat();
  Object.assign(fresh, makeNode());
  fresh.packageItem = { name: 'MainPanelChat' };
  fresh.m_chatItemList = { numItems: 2 };
  fresh.visible = true;
  fresh.onConstruct();
  check('构造后同帧被压住（零闪烁，不用等定时器）', fresh.visible === false);

  fresh.resetVisible();
  check('对象池复用后同帧被压住', fresh.visible === false);

  // 关闭后不再干预
  hide(win, false);
  fresh.visible = true;
  fresh.resetVisible();
  check('关闭态不再干预 resetVisible', fresh.visible === true);
}

// ═══ 14. 接管 visible 访问器：游戏自己写 visible=true 也点不亮 ═══════════
console.log('\n[14] visible 守门（游戏刷新会写 m_chat.visible = true）');
{
  // 复刻 fgui：visible 是 GObject 原型上的访问器，setVisible 走它。
  const baseProto = {};
  Object.defineProperty(baseProto, 'visible', {
    get() { return this._visible; },
    set(v) { this._visible = v; },
    configurable: true
  });
  baseProto.setVisible = function (v) { this.visible = v; };
  function GuardedPanel() { this._visible = false; }
  GuardedPanel.prototype = Object.create(baseProto);
  GuardedPanel.prototype.constructor = GuardedPanel;
  GuardedPanel.URL = 'ui://8fweejrdlmbhm';
  modules['UI_MainPanelChat'] = { default: GuardedPanel };

  const holder = makeNode();
  const { win } = buildEnv({ window: { ui: holder, layer: holder } });
  const r = hide(win, true);
  check('visible 守门已接管（vg>0）', r.includes('vg=1'), r);

  const p = new GuardedPanel();
  p.packageItem = { name: 'MainPanelChat' };
  p.m_chatItemList = { numItems: 1 };
  p.getChild = () => null;
  p.getChildAt = () => null;
  p.numChildren = 0;

  // 游戏自己的刷新写法：t.m_chat.visible = isModuleVisible(CHAT)
  p.visible = true;
  check('游戏写 visible=true 被削成 false', p.visible === false, 'visible=' + p.visible);

  // fgui 对象池 / GLoader 走 setVisible
  p.setVisible(true);
  check('setVisible(true) 同样被削', p.visible === false, 'visible=' + p.visible);

  // get 仍返回真实值，不撒谎
  check('get 返回真实值', p.visible === false);

  // 关掉之后不再干预
  hide(win, false);
  p.visible = true;
  check('关闭态恢复正常写入', p.visible === true, 'visible=' + p.visible);
}

console.log('\n' + (fail === 0 ? '全部通过' : '有失败') + '：' + pass + ' passed / ' + fail + ' failed');
process.exit(fail === 0 ? 0 : 1);
