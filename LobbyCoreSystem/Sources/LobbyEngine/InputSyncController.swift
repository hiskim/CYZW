import AppKit
import LobbyDomain
import WebKit

// MARK: - 键鼠同步（群控 / 镜像操作）
//
// 从上一代 ios/Shell/MacInputSync.swift 移植，语义逐条保持：
// - 纯 JS IPC 方案：坐标 0...1 归一化，各实例内部换算回自己的绝对像素；
//   **禁止 CGEvent/NSEvent 物理坐标模拟**（网格布局里物理坐标根本对不上）。
// - 混合路由：🔗「参与同步」= 收件人 + 无主控时的发言人；👑「主控」一出现就把
//   「发」的权限收归独占。路由以账号分组为隔离边界，事件不跨组串线。
// - 防回灌是互相模式的生死线：回放事件打 ECHO 标记，捕获器双闸门
//   （capture 开关 + echo 标记）忽略，只有原生真实事件会外发。
// - 代理脚本必须 atDocumentStart 预注入到每个实例（WKUserScript 无法运行时追加），
//   运行时只用 setCapture(on) 切角色。
// - 主窗口身份按账号 ID 记：卡片重载（换 WebView）不退位；只有账号级关闭才退位。

// MARK: 实例注册表

/// 运行中的 WebKit 实例登记表：账号 ID → 视口实例（弱引用）。
/// 中控路由只认账号 ID；实例销毁后条目自动失效，不会把 JS 发给死掉的页面。
@MainActor
public final class GameInstanceRegistry {
    private final class WeakBox {
        weak var instance: GameViewportInstance?
        init(_ instance: GameViewportInstance) { self.instance = instance }
    }

    private var boxes: [String: WeakBox] = [:]
    /// 已经报过错的账号（每个实例只报一次，避免刷屏）。
    private var warned: Set<String> = []

    public init() {}

    /// 「登记的就是自己」才移除——重载卡片时新实例先登记、旧实例后 stop，
    /// 顺序反了也不能把新实例的登记条目删掉。
    public func register(_ instance: GameViewportInstance, accountID: String) {
        boxes[accountID] = WeakBox(instance)
        warned.remove(accountID)
    }

    public func unregister(_ instance: GameViewportInstance, accountID: String) {
        guard boxes[accountID]?.instance === instance else { return }
        boxes.removeValue(forKey: accountID)
    }

    public func instance(for accountID: String) -> GameViewportInstance? { boxes[accountID]?.instance }
    public func isLive(_ accountID: String) -> Bool { boxes[accountID]?.instance != nil }

    /// 所有存活实例的账号 ID；弱引用失效的条目在这里一并清掉，免得越积越多。
    public func liveAccountIDs() -> [String] {
        var live: [String] = []
        var dead: [String] = []
        for (accountID, box) in boxes {
            if box.instance == nil { dead.append(accountID) } else { live.append(accountID) }
        }
        for accountID in dead { boxes.removeValue(forKey: accountID) }
        return live
    }

    /// 向指定实例注入 JS。实例不存在（已关闭）时静默忽略。
    @discardableResult
    public func evaluate(_ script: String, accountID: String) -> Bool {
        guard let instance = boxes[accountID]?.instance else { return false }
        instance.evaluateBridgeScript(script) { [weak self] error in
            guard let error else { return }
            guard let self, !self.warned.contains(accountID) else { return }
            self.warned.insert(accountID)
            LobbyLog.error("[sync] evaluate failed (%@): %@", accountID, error.localizedDescription)
        }
        return true
    }
}

// MARK: 注入脚本

/// 注入到每个 WKWebView 的 JS：既能在主窗口当「捕获器」，也能在子窗口当「回放器」。
/// 一份脚本两种角色，靠 `setCapture(on)` 切换——切换主窗口时无需重新注入。
public enum InputSyncScript {
    /// 打开 / 关闭捕获（只有主控为 true，互相同步时参与者都为 true）。
    public static func setCapture(_ enabled: Bool) -> String {
        "if(window.__LOBBY_SYNC__){window.__LOBBY_SYNC__.setCapture(\(enabled ? "true" : "false"));}void 0;"
    }

    /// 在子窗口回放一个事件（literal 是事件对象的 JSON）。
    public static func replay(literal: String) -> String {
        "if(window.__LOBBY_SYNC__){window.__LOBBY_SYNC__.replay(\(literal));}void 0;"
    }

    /// 开关波纹特效。
    public static func setRipple(_ enabled: Bool) -> String {
        "if(window.__LOBBY_SYNC__){window.__LOBBY_SYNC__.setRipple(\(enabled ? "true" : "false"));}void 0;"
    }

    /// 代理脚本（atDocumentStart 注入，只注入主框架）。三段能力：
    /// 1. **捕获**：window 上 capture 阶段挂鼠标/键盘/滚轮/右键监听，坐标归一化后
    ///    经页面桥回传原生；mousemove 用 rAF 合并成每帧一次，避免把 IPC 打满。
    /// 2. **回放**：归一化坐标换算回本窗口绝对像素，构造同类型虚拟事件派发到
    ///    `document.elementFromPoint()` 的元素（自然冒泡到 document/window，
    ///    Cocos 挂在 canvas 或 window 上的监听都能收到）。
    /// 3. **波纹**：子窗口的点击位置画一个青色圆点，0.22s 放大淡出后移除。
    public static let agent: String = {
        let channel = LobbyConfiguration.webChannelName
        return """
        (() => {
          if (window.__LOBBY_SYNC__) return;
          const HANDLER = '\(channel)';
          const RIPPLE_MS = 220;
          const RIPPLE_SIZE = 26;
          let capturing = false;
          let rippleOn = true;
          let pendingMove = null;
          let rafId = 0;

          const post = (input) => {
            try { window.webkit.messageHandlers[HANDLER].postMessage({ type: 'input', input: input }); } catch (e) {}
          };
          const mods = (e) => (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0);
          const clamp01 = (v) => { v = +v; if (!isFinite(v)) return 0; return v < 0 ? 0 : (v > 1 ? 1 : v); };
          // 归一化：以 window.innerWidth/innerHeight 为基准，多开尺寸不一也不会错位。
          const norm = (e) => {
            const w = window.innerWidth || (document.documentElement && document.documentElement.clientWidth) || 1;
            const h = window.innerHeight || (document.documentElement && document.documentElement.clientHeight) || 1;
            return [clamp01(e.clientX / w), clamp01(e.clientY / h)];
          };
          const viewport = () => {
            const w = window.innerWidth || (document.documentElement && document.documentElement.clientWidth) || 1;
            const h = window.innerHeight || (document.documentElement && document.documentElement.clientHeight) || 1;
            return [w, h];
          };
          const mouseInput = (t, e) => {
            const p = norm(e);
            return { t: t, x: +p[0].toFixed(5), y: +p[1].toFixed(5), button: e.button || 0, buttons: e.buttons || 0, mods: mods(e) };
          };
          const keyInput = (t, e) => ({ t: t, key: e.key || '', code: e.code || '', keyCode: e.keyCode || 0, mods: mods(e), repeat: !!e.repeat });

          // ── 捕获 ──
          // 防回灌：互相同步时所有参与者都在捕获，A 的事件在 B 里回放后会被 B 的
          // 捕获器再抓一次发回来 → 无限 ping-pong。回放事件一律打 ECHO 标记，
          // 捕获器见到标记直接忽略。只有原生真实事件会外发。
          const ECHO = '__lobbySyncEcho';
          const isEcho = (e) => { try { return !!e[ECHO]; } catch (err) { return false; } };
          const mark = (e) => { try { e[ECHO] = 1; } catch (err) {} return e; };
          // 捕获开关 + 回灌标记双闸门。
          const guard = (fn) => (e) => { if (!capturing || isEcho(e)) return; fn(e); };

          const onMove = (e) => {
            pendingMove = mouseInput('mousemove', e);
            if (!rafId) rafId = requestAnimationFrame(flushMove);
          };
          const flushMove = () => { rafId = 0; const p = pendingMove; pendingMove = null; if (p) post(p); };
          const onWheel = (e) => {
            const p = norm(e);
            post({ t: 'wheel', x: +p[0].toFixed(5), y: +p[1].toFixed(5), dx: e.deltaX || 0, dy: e.deltaY || 0, mods: mods(e) });
          };
          const sendMouse = (t) => (e) => { post(mouseInput(t, e)); };
          const sendKey = (t) => (e) => { post(keyInput(t, e)); };

          window.addEventListener('mousedown', guard(sendMouse('mousedown')), true);
          window.addEventListener('mouseup', guard(sendMouse('mouseup')), true);
          window.addEventListener('contextmenu', guard(sendMouse('contextmenu')), true);
          window.addEventListener('mousemove', guard(onMove), true);
          window.addEventListener('wheel', guard(onWheel), { capture: true, passive: true });
          window.addEventListener('keydown', guard(sendKey('keydown')), true);
          window.addEventListener('keyup', guard(sendKey('keyup')), true);
          // 指针移出窗口时补一个 mouseup，避免子窗口卡在「按下」状态。
          window.addEventListener('blur', () => { if (capturing) post({ t: 'mouseup', x: 0, y: 0, button: 0, buttons: 0, mods: 0 }); });

          // ── 波纹特效层 ──
          let rippleLayer = null;
          const layer = () => {
            if (rippleLayer && rippleLayer.isConnected) return rippleLayer;
            const host = document.body || document.documentElement;
            if (!host) return null;
            const el = document.createElement('div');
            el.id = '__lobby_sync_ripple__';
            el.style.cssText = 'position:fixed;left:0;top:0;width:100%;height:100%;pointer-events:none;z-index:2147483647;overflow:hidden;';
            host.appendChild(el);
            rippleLayer = el;
            return el;
          };
          const ripple = (x, y) => {
            if (!rippleOn) return;
            try {
              const host = layer();
              if (!host) return;
              const dot = document.createElement('div');
              const half = RIPPLE_SIZE / 2;
              dot.style.cssText = 'position:absolute;left:' + (x - half) + 'px;top:' + (y - half) + 'px;width:' + RIPPLE_SIZE + 'px;height:' + RIPPLE_SIZE + 'px;border-radius:50%;box-sizing:border-box;border:2px solid rgba(34,211,238,0.95);background:rgba(34,211,238,0.28);opacity:0.95;transition:transform ' + (RIPPLE_MS / 1000) + 's ease-out,opacity ' + (RIPPLE_MS / 1000) + 's ease-out;';
              host.appendChild(dot);
              requestAnimationFrame(() => { dot.style.transform = 'scale(1.9)'; dot.style.opacity = '0'; });
              setTimeout(() => { if (dot.parentNode) dot.parentNode.removeChild(dot); }, RIPPLE_MS + 20);
            } catch (e) {}
          };

          // ── 回放 ──
          const targetAt = (x, y) => {
            let el = null;
            try { el = document.elementFromPoint(x, y); } catch (e) {}
            return el || document.body || document.documentElement;
          };
          const flags = (m) => ({ shiftKey: !!(m & 1), ctrlKey: !!(m & 2), altKey: !!(m & 4), metaKey: !!(m & 8) });

          const replay = (input) => {
            if (!input || !input.t) return;
            const vp = viewport();
            const x = Math.round((input.x || 0) * vp[0]);
            const y = Math.round((input.y || 0) * vp[1]);
            const m = input.mods || 0;
            try {
              const t = input.t;
              if (t === 'mousedown' || t === 'mouseup' || t === 'mousemove' || t === 'contextmenu') {
                const el = targetAt(x, y);
                if (!el) return;
                const init = Object.assign({
                  bubbles: true, cancelable: true, composed: true, view: window,
                  screenX: x, screenY: y, clientX: x, clientY: y,
                  button: input.button || 0, buttons: input.buttons || 0,
                  detail: t === 'mousedown' || t === 'mouseup' ? 1 : 0
                }, flags(m));
                const ev = new MouseEvent(t, init);
                el.dispatchEvent(mark(ev));
                if (t === 'mousedown') ripple(x, y);
              } else if (t === 'wheel') {
                const el = targetAt(x, y);
                if (!el) return;
                const init = Object.assign({
                  bubbles: true, cancelable: true, composed: true, view: window,
                  screenX: x, screenY: y, clientX: x, clientY: y,
                  deltaX: input.dx || 0, deltaY: input.dy || 0, deltaZ: 0, deltaMode: 0
                }, flags(m));
                el.dispatchEvent(mark(new WheelEvent('wheel', init)));
              } else if (t === 'keydown' || t === 'keyup') {
                const el = document.activeElement || document.body || document.documentElement;
                if (!el) return;
                const init = Object.assign({
                  bubbles: true, cancelable: true, composed: true, view: window,
                  key: input.key || '', code: input.code || '', location: 0,
                  keyCode: input.keyCode || 0, charCode: 0, which: input.keyCode || 0,
                  repeat: t === 'keydown' ? !!input.repeat : false
                }, flags(m));
                el.dispatchEvent(mark(new KeyboardEvent(t, init)));
              }
            } catch (e) {}
          };

          window.__LOBBY_SYNC__ = {
            setCapture: (on) => { capturing = !!on; if (!capturing) { pendingMove = null; } },
            isCapturing: () => capturing,
            setRipple: (on) => { rippleOn = !!on; },
            replay: replay,
            ripple: ripple
          };
        })();
        """
    }()
}

// MARK: 群控中控

/// 键鼠同步的中控。路由以账号库分组为隔离边界：每个分组拥有独立的参与名单和
/// 主控，事件永远只在发送者所属分组内广播。
@MainActor
public final class InputSyncController: ObservableObject {
    /// 分组 ID → 分组内同步状态。`AccountGroup.allID` 是展示用伪分组，不参与同步。
    @Published public private(set) var groupStates: [String: SyncGroupState] = [:]
    /// 账号 ID → 所属同步分组 ID，由账号库分组树同步进来。
    private var accountGroupIDs: [String: String] = [:]
    private var groupNames: [String: String] = [:]

    /// mousemove 是否同步（关掉可以省掉大量 IPC，点击/按键不受影响）。
    @Published public var syncMouseMove = true
    /// 子窗口点击时是否画波纹特效（改动立即下发到所有参与同步的实例）。
    @Published public var showsRipple = true {
        didSet { pushRipple(showsRipple) }
    }

    public let registry = GameInstanceRegistry()

    /// mousemove 的派发节流间隔（与 JS 侧 rAF 合并一起，双保险）。
    private let moveInterval: TimeInterval = 1.0 / 60.0
    /// 按账号分别节流：互相同步模式下多个窗口可能交替发言，不能共用一把尺子。
    private var lastMoveSentAt: [String: TimeInterval] = [:]

    public init() {}

    // MARK: 聚合查询（UI 用）

    public var receiverAccountIDs: Set<String> {
        groupStates.values.reduce(into: Set<String>()) { result, state in
            result.formUnion(state.receiverAccountIDs)
        }
    }

    public var masterAccountID: String? {
        groupStates.values.compactMap(\.masterAccountID).first
    }

    public var receiverCount: Int { receiverAccountIDs.count }

    /// 全局摘要模式（状态胶囊三态用）。
    public var mode: SyncMode {
        if groupStates.values.contains(where: { $0.masterAccountID != nil }) { return .masterDriven }
        return receiverAccountIDs.count >= 2 ? .mutual : .idle
    }

    // MARK: 分组配置

    /// 将账号库当前的分组树注册到群控中控。`全部` 只是筛选伪分组，跳过它；
    /// 未归组账号统一落到 `未分组`。现有参与状态和主控按账号 ID 跟随账号移动，
    /// 避免改名或调整归属后产生隐形串组。
    public func configureGroups(definitions: [AccountGroup], assignments: [String: String]) {
        var nextAccountGroupIDs: [String: String] = [:]
        var nextGroupNames: [String: String] = [:]
        let realGroups = definitions.filter { !$0.isSynthetic }
        for group in realGroups {
            nextGroupNames[group.id] = group.groupName
        }
        for (accountID, groupID) in assignments where realGroups.contains(where: { $0.id == groupID }) {
            nextAccountGroupIDs[accountID] = groupID
        }
        nextGroupNames[AccountGroup.ungroupedID] = GameAccount.defaultGroupName

        let validGroupIDs = Set(realGroups.map(\.id)).union([AccountGroup.ungroupedID])
        let oldReceivers = receiverAccountIDs
        let oldMasters = groupStates.values.compactMap(\.masterAccountID)
        var nextStates = Dictionary(uniqueKeysWithValues: validGroupIDs.map { groupID in
            (groupID, SyncGroupState(id: groupID))
        })

        for accountID in oldReceivers {
            guard let groupID = nextAccountGroupIDs[accountID] else { continue }
            nextStates[groupID]?.receiverAccountIDs.insert(accountID)
        }
        for accountID in oldMasters {
            guard let groupID = nextAccountGroupIDs[accountID] else { continue }
            // 同一账号只能属于一个分组；批量移动造成主控冲突时保留先遇到的主控。
            if nextStates[groupID]?.masterAccountID == nil {
                nextStates[groupID]?.masterAccountID = accountID
            }
        }

        accountGroupIDs = nextAccountGroupIDs
        groupNames = nextGroupNames
        groupStates = nextStates

        // 分组变更可能改变主控/参与者角色，立即把新捕获状态写回存活页面。
        for accountID in registry.liveAccountIDs() {
            pushCaptureState(to: accountID)
        }
    }

    public func groupID(for accountID: String) -> String {
        accountGroupIDs[accountID] ?? AccountGroup.ungroupedID
    }

    public func groupName(for accountID: String) -> String {
        groupNames[groupID(for: accountID)] ?? GameAccount.defaultGroupName
    }

    public func masterAccountID(in groupID: String) -> String? {
        groupStates[groupID]?.masterAccountID
    }

    public func receiverCount(in groupID: String) -> Int {
        groupStates[groupID]?.receiverAccountIDs.count ?? 0
    }

    public func isGroupSyncEnabled(_ groupID: String) -> Bool {
        receiverCount(in: groupID) > 0 || masterAccountID(in: groupID) != nil
    }

    // MARK: 查询

    public func isMaster(_ accountID: String) -> Bool {
        groupStates[groupID(for: accountID)]?.masterAccountID == accountID
    }

    public func isReceiver(_ accountID: String) -> Bool {
        groupStates[groupID(for: accountID)]?.receiverAccountIDs.contains(accountID) == true
    }

    /// 该实例此刻是否应当捕获自己的键鼠事件（有主控时只有本组主控捕获）。
    public func shouldCapture(_ accountID: String) -> Bool {
        let state = groupStates[groupID(for: accountID)]
        return InputSyncRouting.shouldCapture(master: state?.masterAccountID,
                                              receivers: state?.receiverAccountIDs ?? [],
                                              account: accountID)
    }

    /// 该实例此刻是否允许向外发送事件。
    public func canSend(from accountID: String) -> Bool {
        let state = groupStates[groupID(for: accountID)]
        return InputSyncRouting.canSend(master: state?.masterAccountID,
                                        receivers: state?.receiverAccountIDs ?? [],
                                        sender: accountID)
    }

    // MARK: 主控

    /// 设为所属分组的主控 / 取消所属分组主控。
    public func toggleMaster(_ accountID: String) {
        let groupID = groupID(for: accountID)
        setMaster(groupStates[groupID]?.masterAccountID == accountID ? nil : accountID, in: groupID)
    }

    /// 取消所有分组主控（状态胶囊「主控 · N 跟随」点击退位用）。
    public func resignAllMasters() {
        for groupID in Array(groupStates.keys) { setMaster(nil, in: groupID) }
    }

    public func setMaster(_ accountID: String?, in groupID: String) {
        var state = groupStates[groupID] ?? SyncGroupState(id: groupID)
        let previous = state.masterAccountID
        if let accountID {
            guard self.groupID(for: accountID) == groupID else { return }
            state.masterAccountID = accountID
        } else {
            state.masterAccountID = nil
        }
        groupStates[groupID] = state

        // 主控一变，旧主控、新主控和本组参与者都要重新写捕获开关。
        var affected = state.receiverAccountIDs
        if let previous { affected.insert(previous) }
        if let accountID { affected.insert(accountID) }
        for id in affected { pushCaptureState(to: id) }
        guard let accountID else { return }
        pushRipple(showsRipple, to: accountID)
        registry.instance(for: accountID)?.focusWebView()
    }

    // MARK: 参与开关

    public func toggleReceiver(_ accountID: String) {
        setReceiver(accountID, enabled: !isReceiver(accountID))
    }

    /// 每个窗口独立的「参与同步」开关：既是收件人，也是无主控时的发言人。
    public func setReceiver(_ accountID: String, enabled: Bool) {
        let groupID = groupID(for: accountID)
        var state = groupStates[groupID] ?? SyncGroupState(id: groupID)
        if enabled {
            state.receiverAccountIDs.insert(accountID)
        } else {
            state.receiverAccountIDs.remove(accountID)
        }
        groupStates[groupID] = state
        pushCaptureState(to: accountID)
    }

    /// 一键开启指定分组中当前已打开的实例。
    @discardableResult
    public func enableGroup(_ groupID: String) -> Int {
        let liveIDs = Set(registry.liveAccountIDs()).filter { self.groupID(for: $0) == groupID }
        for accountID in liveIDs { setReceiver(accountID, enabled: true) }
        return liveIDs.count
    }

    /// 一键开启当前已打开实例的同步。路由仍由中控按账号所属分组隔离。
    @discardableResult
    public func enableAllLiveInstances() -> Int {
        let liveIDs = Set(registry.liveAccountIDs())
        for accountID in liveIDs { setReceiver(accountID, enabled: true) }
        return liveIDs.count
    }

    /// 一键关闭全部分组同步（参与名单 + 主控一起清）。
    public func disableAllSync() {
        let groupIDs = Array(groupStates.keys)
        for groupID in groupIDs { disableGroup(groupID) }
    }

    /// 关闭指定分组同步，并清掉该分组的主控配置。
    public func disableGroup(_ groupID: String) {
        guard var state = groupStates[groupID] else { return }
        var affected = state.receiverAccountIDs
        if let master = state.masterAccountID { affected.insert(master) }
        state.receiverAccountIDs.removeAll()
        state.masterAccountID = nil
        groupStates[groupID] = state
        for id in affected { pushCaptureState(to: id) }
    }

    /// 一键关闭所有参与（只取消参与名单，不清主控）。
    public func disableAllReceivers() {
        let ids = receiverAccountIDs
        for groupID in Array(groupStates.keys) {
            groupStates[groupID]?.receiverAccountIDs.removeAll()
        }
        for id in ids { pushCaptureState(to: id) }
    }

    // MARK: 生命周期

    /// 实例**账号级**关闭：从所属分组摘掉参与标记；是本组主控则退位。
    /// 卡片重载只是换 WebView，不走这里，重载不会丢掉主控身份。
    public func retire(accountID: String) {
        let groupID = groupID(for: accountID)
        guard var state = groupStates[groupID] else { return }
        let wasMaster = state.masterAccountID == accountID
        state.receiverAccountIDs.remove(accountID)
        if wasMaster { state.masterAccountID = nil }
        groupStates[groupID] = state
        if wasMaster {
            for id in state.receiverAccountIDs { pushCaptureState(to: id) }
        }
    }

    /// 页面加载完成 / 实例重建后，把捕获开关与波纹偏好重新写回页面。
    public func refreshCapture(forAccountID accountID: String) {
        pushCaptureState(to: accountID)
        pushRipple(showsRipple, to: accountID)
    }

    // MARK: 事件分发

    /// 收到一个实例的事件 → 按其所属分组决定谁能发、发给谁 → 逐个回放。
    public func publish(_ event: InputSyncEvent, from accountID: String) {
        guard canSend(from: accountID) else { return }
        if event.isMove {
            guard syncMouseMove else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if let last = lastMoveSentAt[accountID], now - last < moveInterval { return }
            lastMoveSentAt[accountID] = now
        }
        let state = groupStates[groupID(for: accountID)]
        let targets = InputSyncRouting.routingTargets(master: state?.masterAccountID,
                                                      receivers: state?.receiverAccountIDs ?? [],
                                                      sender: accountID)
        guard !targets.isEmpty, let literal = event.javaScriptLiteral else { return }
        let script = InputSyncScript.replay(literal: literal)
        for target in targets {
            registry.evaluate(script, accountID: target)
        }
    }

    // MARK: 私有

    /// 把「当前模式下该实例应不应该捕获」写回页面。
    private func pushCaptureState(to accountID: String) {
        registry.evaluate(InputSyncScript.setCapture(shouldCapture(accountID)), accountID: accountID)
    }

    /// 波纹开关：to 为 nil 时下发给所有分组的主控和参与者。
    private func pushRipple(_ enabled: Bool, to accountID: String? = nil) {
        let script = InputSyncScript.setRipple(enabled)
        if let accountID {
            registry.evaluate(script, accountID: accountID)
            return
        }
        var ids = receiverAccountIDs
        ids.formUnion(groupStates.values.compactMap(\.masterAccountID))
        for id in ids {
            registry.evaluate(script, accountID: id)
        }
    }
}
