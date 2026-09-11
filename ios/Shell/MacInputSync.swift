#if os(macOS)
import Foundation
import SwiftUI
import WebKit

// MARK: - 事件载荷

/// JS ↔ Swift 之间传递的中性输入事件。
///
/// 坐标一律是 **0...1 的归一化比例**（相对各自窗口的 `window.innerWidth /
/// innerHeight`），因此主窗口与子窗口尺寸不同也不会错位——这是本方案不用
/// CGEvent/NSEvent 物理坐标模拟的关键：物理坐标在网格布局里根本对不上，
/// 归一化比例在每个实例内部再各自换算回自己的绝对坐标。
struct MacInputSyncEvent: Codable {
    /// 事件类型：mousedown / mouseup / mousemove / contextmenu / wheel / keydown / keyup
    var t: String
    /// 归一化横坐标
    var x: Double?
    /// 归一化纵坐标
    var y: Double?
    var button: Int?
    var buttons: Int?
    /// 修饰键掩码：1 shift · 2 ctrl · 4 alt · 8 meta
    var mods: Int?
    var key: String?
    var code: String?
    var keyCode: Int?
    /// wheel 的滚动增量
    var dx: Double?
    var dy: Double?
    var isRepeat: Bool?

    enum CodingKeys: String, CodingKey {
        case t, x, y, button, buttons, mods, key, code, keyCode, dx, dy
        case isRepeat = "repeat"
    }
}

extension MacInputSyncEvent {
    static let mouseDown = "mousedown"
    static let mouseUp = "mouseup"
    static let mouseMove = "mousemove"
    static let contextMenu = "contextmenu"
    static let wheel = "wheel"
    static let keyDown = "keydown"
    static let keyUp = "keyup"

    var isMove: Bool { t == Self.mouseMove }

    /// 从 WebKit 消息体解码（消息体是 `{type:"input", input:{...}}`）。
    static func decode(from body: [String: Any]) -> MacInputSyncEvent? {
        guard let payload = body["input"] as? [String: Any] else { return nil }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? JSONDecoder().decode(MacInputSyncEvent.self, from: data)
    }

    /// 编码成 JS 对象字面量（注入到子窗口回放）。
    var javaScriptLiteral: String? {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }
}

// MARK: - 实例注册表

/// 运行中的 WebKit 实例登记表：账号 ID → MacWebKitGameView。
///
/// 中控路由（MacInputSyncController）只认账号 ID，不持有 NSView 强引用，
/// 实例销毁（关窗 / 重载）后条目自动失效，不会把 JS 发给已经死掉的页面。
@MainActor
final class MacGameInstanceRegistry {
    static let shared = MacGameInstanceRegistry()

    private final class WeakBox {
        weak var view: MacWebKitGameView?
        init(_ view: MacWebKitGameView) { self.view = view }
    }

    private var boxes: [String: WeakBox] = [:]
    /// 已经报过错的账号（每个实例只报一次，避免刷屏）。
    private var warned: Set<String> = []

    func register(_ view: MacWebKitGameView, accountID: String) {
        boxes[accountID] = WeakBox(view)
        warned.remove(accountID)
    }

    /// 只有「登记的就是自己」才移除——重载卡片时新视图会先登记、旧视图后 stop，
    /// 顺序反了也不能把新视图的登记条目删掉。
    func unregister(_ view: MacWebKitGameView, accountID: String) {
        guard boxes[accountID]?.view === view else { return }
        boxes.removeValue(forKey: accountID)
    }

    func view(for accountID: String) -> MacWebKitGameView? { boxes[accountID]?.view }
    func isLive(_ accountID: String) -> Bool { boxes[accountID]?.view != nil }

    /// 向指定实例注入 JS。实例不存在（已关闭）时静默忽略。
    @discardableResult
    func evaluate(_ script: String, accountID: String) -> Bool {
        guard let view = boxes[accountID]?.view else { return false }
        view.evaluateJavaScript(script) { [weak self] error in
            guard let error else { return }
            guard let self, !self.warned.contains(accountID) else { return }
            self.warned.insert(accountID)
            NSLog("[ios2-macos] sync evaluate failed (%@): %@", accountID, error.localizedDescription)
        }
        return true
    }
}

// MARK: - 群控中控

/// 键鼠同步（群控 / 镜像操作）的中控。
///
/// 主从模型：
/// - `masterAccountID`：全局唯一的主窗口。只有它捕获事件并广播；
/// - `receiverAccountIDs`：打开了「接收同步」的窗口集合；
/// - 主窗口自身不会被回灌（避免回环），子窗口的操作也不会反向同步。
///
/// 主窗口退位：关闭主窗口 → `retire(accountID:)` → master 置空 →
/// 所有窗口恢复普通窗口（捕获开关被逐个写回 false），直到用户重新指定。
@MainActor
final class MacInputSyncController: ObservableObject {
    static let shared = MacInputSyncController()

    /// 当前主窗口的账号 ID（nil = 无人主事，群控停止）。
    @Published private(set) var masterAccountID: String?
    /// 开启了「接收同步」的账号 ID 集合。
    @Published private(set) var receiverAccountIDs: Set<String> = []

    /// mousemove 是否同步（关掉可以省掉大量 IPC，点击/按键不受影响）。
    @Published var syncMouseMove = true
    /// 子窗口点击时是否画波纹特效（改动会立即下发到所有参与同步的实例）。
    @Published var showsRipple = true {
        didSet { pushRipple(showsRipple) }
    }

    /// mousemove 的派发节流间隔（与 JS 侧 rAF 合并一起，双保险）。
    private let moveInterval: TimeInterval = 1.0 / 60.0
    private var lastMoveSentAt: TimeInterval = 0

    // MARK: 查询

    func isMaster(_ accountID: String) -> Bool { masterAccountID == accountID }
    func isReceiver(_ accountID: String) -> Bool { receiverAccountIDs.contains(accountID) }
    var receiverCount: Int { receiverAccountIDs.count }

    // MARK: 主窗口

    /// 设为主窗口 / 取消（全局唯一）。
    func toggleMaster(_ accountID: String) {
        setMaster(masterAccountID == accountID ? nil : accountID)
    }

    func setMaster(_ accountID: String?) {
        let previous = masterAccountID
        masterAccountID = accountID
        if let previous, previous != accountID {
            // 旧主窗口退位：关掉它的捕获监听。
            pushCapture(false, to: previous)
        }
        guard let accountID else { return }
        pushCapture(true, to: accountID)
        pushRipple(showsRipple, to: accountID)
        // 键盘事件只会派发给第一响应者，设为主窗口时顺手把焦点抢过来。
        MacGameInstanceRegistry.shared.view(for: accountID)?.focusWebView()
    }

    // MARK: 接收开关

    func toggleReceiver(_ accountID: String) {
        setReceiver(accountID, enabled: !receiverAccountIDs.contains(accountID))
    }

    /// 每个窗口独立的「接收同步」开关。
    func setReceiver(_ accountID: String, enabled: Bool) {
        if enabled {
            receiverAccountIDs.insert(accountID)
        } else {
            receiverAccountIDs.remove(accountID)
        }
    }

    // MARK: 生命周期

    /// 实例关闭：主窗口退位 + 摘掉接收标记。
    /// 由账号级关闭（WorkspaceViewModel.close）调用；卡片重载只是换 WebView，
    /// 不走这里，所以重载不会莫名其妙丢掉主窗口身份。
    func retire(accountID: String) {
        if masterAccountID == accountID { setMaster(nil) }
        receiverAccountIDs.remove(accountID)
    }

    /// 页面加载完成 / 实例重建后，把「是否捕获」重新写回页面
    /// （WKUserScript 只在导航时注入，重载后必须补一次，否则脚本在但开关是关的）。
    func refreshCapture(forAccountID accountID: String) {
        pushCapture(masterAccountID == accountID, to: accountID)
    }

    // MARK: 事件分发

    /// 主窗口发来一个事件 → 过滤出「开了接收同步且不是主窗口」的子窗口 → 逐个回放。
    func publish(_ event: MacInputSyncEvent, from accountID: String) {
        // 只有主窗口能广播；子窗口的事件一律丢弃。
        guard accountID == masterAccountID else { return }
        if event.isMove {
            guard syncMouseMove else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastMoveSentAt >= moveInterval else { return }
            lastMoveSentAt = now
        }
        let targets = receiverAccountIDs.filter { $0 != accountID }
        guard !targets.isEmpty, let literal = event.javaScriptLiteral else { return }
        let script = MacInputSyncScript.replay(literal: literal)
        for target in targets {
            MacGameInstanceRegistry.shared.evaluate(script, accountID: target)
        }
    }

    // MARK: 私有

    private func pushCapture(_ enabled: Bool, to accountID: String) {
        MacGameInstanceRegistry.shared.evaluate(MacInputSyncScript.setCapture(enabled), accountID: accountID)
    }

    /// 波纹开关：to 为 nil 时下发给所有参与同步的实例（主窗口 + 接收方）。
    private func pushRipple(_ enabled: Bool, to accountID: String? = nil) {
        let script = MacInputSyncScript.setRipple(enabled)
        if let accountID {
            MacGameInstanceRegistry.shared.evaluate(script, accountID: accountID)
            return
        }
        if let masterAccountID {
            MacGameInstanceRegistry.shared.evaluate(script, accountID: masterAccountID)
        }
        for id in receiverAccountIDs {
            MacGameInstanceRegistry.shared.evaluate(script, accountID: id)
        }
    }
}

// MARK: - 注入脚本

/// 注入到每个 WKWebView 的 JS：既能在主窗口当「捕获器」，也能在子窗口当「回放器」。
///
/// 一份脚本两种角色，靠 `setCapture(on)` 切换，好处是：
/// - 不需要在切换主窗口时重新注入脚本（WKUserScript 只能在导航时加）；
/// - 子窗口的回放器始终就绪，主窗口一换就能立刻接收。
enum MacInputSyncScript {
    /// 打开 / 关闭捕获（只有主窗口为 true）。
    static func setCapture(_ enabled: Bool) -> String {
        "if(window.__IOS2_SYNC__){window.__IOS2_SYNC__.setCapture(\(enabled ? "true" : "false"));}void 0;"
    }

    /// 在子窗口回放一个事件（literal 是事件对象的 JSON）。
    static func replay(literal: String) -> String {
        "if(window.__IOS2_SYNC__){window.__IOS2_SYNC__.replay(\(literal));}void 0;"
    }

    /// 开关波纹特效。
    static func setRipple(_ enabled: Bool) -> String {
        "if(window.__IOS2_SYNC__){window.__IOS2_SYNC__.setRipple(\(enabled ? "true" : "false"));}void 0;"
    }

    /// 代理脚本（注入时机 atDocumentStart，只注入主框架）。
    ///
    /// 三段能力：
    /// 1. **捕获**：window 上以 capture 阶段挂 mousedown/mousemove/mouseup/
    ///    keydown/keyup/wheel/contextmenu，坐标归一化后经
    ///    `webkit.messageHandlers.ios2Game` 回传原生；mousemove 用 rAF 合并成
    ///    每帧一次，避免把 IPC 打满。
    /// 2. **回放**：把归一化坐标换算回本窗口的绝对像素，用 MouseEvent /
    ///    KeyboardEvent / WheelEvent 构造同类型虚拟事件，派发到
    ///    `document.elementFromPoint()` 拿到的元素上（会自然冒泡到 document
    ///    和 window，Cocos 在 canvas 或 window 上挂的监听都能收到）。
    /// 3. **波纹**：子窗口的点击位置画一个青色圆点，0.2s 放大淡出后移除。
    static let agent = """
    (() => {
      if (window.__IOS2_SYNC__) return;
      const HANDLER = 'ios2Game';
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
      const onMove = (e) => {
        if (!capturing) return;
        pendingMove = mouseInput('mousemove', e);
        if (!rafId) rafId = requestAnimationFrame(flushMove);
      };
      const flushMove = () => { rafId = 0; const p = pendingMove; pendingMove = null; if (p) post(p); };
      const onWheel = (e) => {
        if (!capturing) return;
        const p = norm(e);
        post({ t: 'wheel', x: +p[0].toFixed(5), y: +p[1].toFixed(5), dx: e.deltaX || 0, dy: e.deltaY || 0, mods: mods(e) });
      };
      const sendMouse = (t) => (e) => { if (capturing) post(mouseInput(t, e)); };
      const sendKey = (t) => (e) => { if (capturing) post(keyInput(t, e)); };

      window.addEventListener('mousedown', sendMouse('mousedown'), true);
      window.addEventListener('mouseup', sendMouse('mouseup'), true);
      window.addEventListener('contextmenu', sendMouse('contextmenu'), true);
      window.addEventListener('mousemove', onMove, true);
      window.addEventListener('wheel', onWheel, { capture: true, passive: true });
      window.addEventListener('keydown', sendKey('keydown'), true);
      window.addEventListener('keyup', sendKey('keyup'), true);
      // 指针移出窗口时补一个 mouseup，避免子窗口卡在「按下」状态。
      window.addEventListener('blur', () => { if (capturing) post({ t: 'mouseup', x: 0, y: 0, button: 0, buttons: 0, mods: 0 }); });

      // ── 波纹特效层 ──
      let rippleLayer = null;
      const layer = () => {
        if (rippleLayer && rippleLayer.isConnected) return rippleLayer;
        const host = document.body || document.documentElement;
        if (!host) return null;
        const el = document.createElement('div');
        el.id = '__ios2_sync_ripple__';
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
            el.dispatchEvent(new MouseEvent(t, init));
            if (t === 'mousedown') ripple(x, y);
          } else if (t === 'wheel') {
            const el = targetAt(x, y);
            if (!el) return;
            const init = Object.assign({
              bubbles: true, cancelable: true, composed: true, view: window,
              screenX: x, screenY: y, clientX: x, clientY: y,
              deltaX: input.dx || 0, deltaY: input.dy || 0, deltaZ: 0, deltaMode: 0
            }, flags(m));
            el.dispatchEvent(new WheelEvent('wheel', init));
          } else if (t === 'keydown' || t === 'keyup') {
            const el = document.activeElement || document.body || document.documentElement;
            if (!el) return;
            const init = Object.assign({
              bubbles: true, cancelable: true, composed: true, view: window,
              key: input.key || '', code: input.code || '', location: 0,
              keyCode: input.keyCode || 0, charCode: 0, which: input.keyCode || 0,
              repeat: t === 'keydown' ? !!input.repeat : false
            }, flags(m));
            el.dispatchEvent(new KeyboardEvent(t, init));
          }
        } catch (e) {}
      };

      window.__IOS2_SYNC__ = {
        setCapture: (on) => { capturing = !!on; if (!capturing) { pendingMove = null; } },
        isCapturing: () => capturing,
        setRipple: (on) => { rippleOn = !!on; },
        replay: replay,
        ripple: ripple
      };
    })();
    """
}
#endif
