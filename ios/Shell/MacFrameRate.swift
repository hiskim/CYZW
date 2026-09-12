import Foundation

/// WebKit 游戏的目标渲染帧率（15 / 24 / 30 / 45 / 60 / 90 / 120 FPS）。
///
/// **范围边界**：这里调的只是游戏页面里 Cocos 主循环的节奏，**不碰显示器刷新率**，
/// 也不改任何系统/屏幕设置。写入点只有两个，都在 WKWebView 内部：
/// 启动时 `window.__IOS2_GAME_INSTANCE__.frameRate`，运行中 `cc.game.config.frameRate`。
/// 因此 100Hz 屏上 90/120 档只会被 vsync 封顶到 ~98 —— 这是预期的，不要为此去动屏幕。
///
/// 档位集合与 ios-cocos WebRuntime 的 `preferredFrameRate()` 白名单
/// `[15, 24, 30, 45, 60, 90, 120]` **严格对齐**：不在白名单里的值会被页面丢弃并
/// 回退到 60，所以这里不要随便加档位，加档必须同时改 WebRuntime 的 `preferredFrameRate()`。
///
/// **目标值不等于实测值**：引擎 `_setAnimFrame()` 对帧率分两路调度——
/// - 30 / 60：引擎把这两档当特例，走裸 `requestAnimationFrame` **不做时间节流**——
///   60 实测 = 显示器刷新率（100Hz 屏上是 100），30 还要再叠加 `_runMainLoop` 里
///   `30 === a && (s = !s)` 隔帧跳过 = 刷新率的一半（100Hz 屏上是 49）。
///   两者都已由 `installExactRate()` 修正：启动循环前把 frameRate 临时写成
///   `keep - 0.001`（29.999 / 59.999）让引擎切到节流路径，起完立刻还原，
///   `getFrameRate()` 对外仍是 30 / 60。
///   （节流路径能精确命中，靠的是 `_stTimeWithRAF` 里 `_lastTime` 记的是理想时刻
///   而非实际时刻，长跑会自动收敛；不要因为前几帧看着偏就以为它不准。）
/// - 其它档位：`_stTimeWithRAF`（`setTimeout` 计时后再对齐 rAF），命中准确，
///   但回调仍落在 vsync 上，所以**物理上限就是显示器刷新率**——120 档在 100Hz
///   屏上只会跑到 ~98。
/// 想要确定的帧率用 15 / 24 / 30 / 45；60 是「跑满屏幕」，90 / 120 受屏幕封顶。
///
    /// 帧率在**实例启动时**随 `__IOS2_GAME_INSTANCE__` 注入，被 Cocos 用作主循环
    /// 的目标帧率；与画质不同，它还能在**运行中**的实例上立即改写（走
    /// `applyScript` 的暂停→等待→重启路径，不是 `setFrameRate`），
    /// 所以设置面板改动后会同时广播给所有活着的窗口。
enum MacFrameRate: Int, CaseIterable, Identifiable {
    case fps15 = 15
    case fps24 = 24
    case fps30 = 30
    case fps45 = 45
    case fps60 = 60
    case fps90 = 90
    case fps120 = 120

    /// 默认帧率：与改动前硬编码的 `frameRate: 60` 保持一致。
    static let fallback: MacFrameRate = .fps60

    /// UserDefaults 持久化键：设置面板写入，WebKit 启动注入时读取。
    static let defaultsKey = "ios2.frameRate"

    var id: Int { rawValue }

    /// 分段控件里的短标签。
    var label: String { "\(rawValue)" }

    /// 卡头行尾胶囊标签。
    var badgeLabel: String { "\(rawValue) FPS" }

    /// 面向用户的档位说明：说清"省多少、顿多少"。
    var summary: String {
        switch self {
        case .fps15: return "占用最低，动作有明显卡顿感，只适合挂机或超多开"
        case .fps24: return "低占用，接近电影帧率，动态画面略顿"
        case .fps30: return "占用与流畅度较均衡，动作稍欠顺滑"
        case .fps45: return "较流畅，占用略低于满帧"
        case .fps60: return "画面顺滑，CPU / GPU 占用较高；实测会精确落在 60"
        case .fps90: return "高刷档；显示器刷新率不足 90Hz 时实测止步于刷新率"
        case .fps120: return "最高档；需要 ≥120Hz 显示器，否则实测止步于刷新率"
        }
    }

    /// 一行档位速记，给无障碍朗读用。
    var accessibilityLabel: String { "帧率：\(rawValue) FPS" }

    /// 读取当前持久化帧率，缺失或非法值（含白名单外的旧值）回退到默认档位。
    static func current() -> MacFrameRate {
        // UserDefaults 缺键时 integer(forKey:) 返回 0，rawValue 0 不存在 → 走 fallback。
        let stored = UserDefaults.standard.integer(forKey: defaultsKey)
        return MacFrameRate(rawValue: stored) ?? fallback
    }
}

#if os(macOS)
extension MacFrameRate {
    /// 运行时改写主循环帧率的 JS（**函数体**，给 `callAsyncJavaScript` 用，允许 `await`）。
    ///
    /// **绝不能直接用 `cc.game.setFrameRate()`** —— Cocos 2.4.9 这个接口有缺陷
    /// （`ios2-web-cocos2d.js:17181` `setFrameRate` / `17354` `_runMainLoop`）：
    ///
    /// ```js
    /// setFrameRate(t) { config.frameRate = t; cancelAnimFrame(_intervalId);
    ///                   _paused = true; _setAnimFrame(); _runMainLoop(); }  // ← 立刻又置回 false
    /// t = (i) => { if (!e._paused) {                    // 旧循环看到 false → 复活
    ///        e._intervalId = requestAnimFrame(t);       // 还会覆盖新循环存的 id
    ///        if (30 === a && (s = !s)) return;          // a = 旧循环启动时捕获的帧率
    ///        r.mainLoop(i); } };                        // 继续渲染
    /// ```
    ///
    /// 主循环闭包只有看到 `_paused === true` 才不再自我续命。而 `setFrameRate` 刚把
    /// `_paused` 置 true，`_runMainLoop()` 紧接着又置回 false，于是**每改一次帧率就
    /// 多一条主循环并存**。后果：
    /// - 实测帧率能冲到显示器刷新率的 2 倍（100Hz 屏上 60 档测出 196 = 2×98；
    ///   30 档测出 145 ≈ 98 + 49，即一条满速 + 一条隔帧跳过的旧循环）
    /// - 多条循环共写模块级 `_lastTime`，把 `_stTimeWithRAF` 的节流计时搅乱
    ///   （45 档只跑出 34）
    /// - CPU / GPU 白烧，风扇狂转
    ///
    /// 正解走「暂停 → 等旧回调自然退出 → 重启」：暂停期间旧循环逐个触发、看到
    /// `_paused` 为 true 就不再排队，等足够长时间后链条断干净，再起唯一一条新循环。
    /// 收尾用公开的 `resume()`（会顺带 `_restore` 音频、重置 deltaTime），
    /// 不用内部的 `_runMainLoop()`，否则音频会被 `pause()` 的 `_break()` 卡住。
    var applyScript: String {
        """
        const fps = \(rawValue);
        if (window.__IOS2_GAME_INSTANCE__) window.__IOS2_GAME_INSTANCE__.frameRate = fps;
        const g = window.cc && window.cc.game;
        // 引擎没起来（页面还在登录 / 加载资源）：值已写进注入对象，boot 时自己会读。
        if (!g || !g.config) return 'deferred:' + fps;
        if (g.config.frameRate === fps) return 'noop:' + fps;
        // 下面三步依赖引擎内部结构（`_setAnimFrame`）。换了 cocos 版本没有它时
        // 退回公开接口——宁可忍受上面那条旧缺陷，也不能让帧率根本改不动。
        if (typeof g._setAnimFrame !== 'function' || typeof g.pause !== 'function' || typeof g.resume !== 'function') {
          if (typeof g.setFrameRate === 'function') { g.setFrameRate(fps); return 'ok-legacy:' + fps; }
          return 'unavailable:' + fps;
        }
        const wasPaused = !!g._paused;
        try { g.pause(); } catch (error) { /* 取消不掉也继续，靠下面的等待兜底 */ }
        // 等旧回调跑完并自然退出：3 倍当前帧时长，且不少于 120ms，
        // 保证慢档（15fps 一帧 66ms）排队的 setTimeout 也来得及触发。
        const wait = Math.max(120, 3 * (1000 / (g.config.frameRate || 60)));
        await new Promise((resolve) => setTimeout(resolve, wait));
        g.config.frameRate = fps;
        // 开头已经写过一次（那时是为了让等待期间启动的新实例拿到新值），
        // 这里再写一次，让「注入」和「目标」在同一时刻一起变——否则自检会读到
        // 「注入 = 下一个档位、目标 = 当前档位」这种错位的组合。
        if (window.__IOS2_GAME_INSTANCE__) window.__IOS2_GAME_INSTANCE__.frameRate = fps;
        g._setAnimFrame();
        if (!wasPaused) g.resume();
        return 'ok-restart:' + fps;
        """
    }

    /// 自检脚本：**实测**当前页面真正的帧率，而不只是读设置值。
    ///
    /// 给 `WKWebView.callAsyncJavaScript` 用（函数体，允许 await）。四件事一起回读：
    /// - `injected`：启动注入 / 运行时写回的 `__IOS2_GAME_INSTANCE__.frameRate`
    /// - `engine`：`cc.game.getFrameRate()`——引擎主循环**的目标**帧率
    /// - `game`：1 秒内 `cc.director` 主循环实际跑了几次——**游戏的真实 FPS**
    /// - `vsync`：1 秒内 `requestAnimationFrame` 回调次数——显示器刷新率（跟游戏无关）
    ///
    /// 只有 `game` 接近 `engine` 才说明帧率真的落到了页面上：
    /// `engine` 变了但 `game` 没变 = 引擎没重启主循环；
    /// `game` 明显低于 `engine` = GPU/CPU 跑不动（或窗口被遮挡被节流）；
    /// `vsync` 高达 100 但 `game` 只有 15 是**正常**的——见 `MacFrameRateHUD.samplerScript` 注释。
    static let verifyScript = """
    const sampler = window.__ios2Fps || null;
    const startMain = sampler ? sampler.main : 0;
    const startVsync = sampler ? sampler.vsync : 0;
    const startDupes = sampler ? (sampler.dupes || 0) : 0;
    const startT = performance.now();
    await new Promise((resolve) => setTimeout(resolve, 1000));
    const elapsed = (performance.now() - startT) / 1000;
    const injected = window.__IOS2_GAME_INSTANCE__ ? window.__IOS2_GAME_INSTANCE__.frameRate : null;
    const engine = (window.cc && cc.game && cc.game.config && typeof cc.game.getFrameRate === 'function')
      ? cc.game.getFrameRate() : null;
    return JSON.stringify({
      injected: injected,
      engine: engine,
      game: sampler && sampler.hook && elapsed > 0 ? Math.round((sampler.main - startMain) / elapsed) : null,
      vsync: sampler && elapsed > 0 ? Math.round((sampler.vsync - startVsync) / elapsed) : null,
      // 同一 vsync 帧内被重复调用、被守卫丢弃的主循环次数：> 0 说明还有残留循环并存。
      dupes: sampler && elapsed > 0 ? Math.round(((sampler.dupes || 0) - startDupes) / elapsed) : null,
      // 主循环事件监听器挂了几个：正常为 1，> 1 说明采样器被重复安装，读数会成倍虚高。
      hooks: sampler ? (sampler.hooks || 0) : null
    });
    """

    /// 把角标状态广播给所有存活实例（设置页开关切换时调用）。
    @MainActor
    static func syncHUD() {
        let script = MacFrameRateHUD.isEnabled ? MacFrameRateHUD.overlayShowScript
                                               : MacFrameRateHUD.overlayHideScript
        let accountIDs = MacGameInstanceRegistry.shared.liveAccountIDs()
        for accountID in accountIDs {
            MacGameInstanceRegistry.shared.evaluate(script, accountID: accountID)
        }
        MacLog.debug("[ios2-macos] frame rate HUD %@ across %d instance(s)",
                     MacFrameRateHUD.isEnabled ? "shown" : "hidden", accountIDs.count)
    }

    // MARK: - 串行化

    /// 「改帧率 + 自检」这一整套后台任务。同一时刻只允许跑一轮。
    ///
    /// 连续快速切档时若放任并发，读数会互相污染，出现两种假象：
    /// - 实测被拉低：`applyScript` 会先 `pause()` 再等 120~400ms 才 `resume()`，
    ///   后一次切档的暂停窗口正好压在前一次 1 秒采样窗口里
    ///   （实测见过 45 档只测出 28，而静置后复测是 44）
    /// - 注入值跑到目标值前面：`applyScript` 一进来就写
    ///   `__IOS2_GAME_INSTANCE__.frameRate`，但要等一会儿才写 `config.frameRate`，
    ///   于是自检会读到「注入 = 下一个档位、目标 = 当前档位」
    private static var pendingWork: Task<Void, Never>?

    /// 世代号。网页里的 `evaluateAsync` 一旦发出就收不回，光靠 `cancel()`
    /// 拦不住已经飞出去的采样，所以还要用世代号把过期结果丢掉。
    private static var workGeneration = 0

    /// 开始新一轮工作前调用：作废上一轮尚未跑完的改帧率 / 自检。
    static func cancelPendingWork() {
        pendingWork?.cancel()
        pendingWork = nil
        workGeneration &+= 1
    }

    /// 广播给所有活着的游戏实例：设置面板改档后立即生效，不必重启实例。
    ///
    /// 实例还没加载完（页面在登录/加载资源）时 `cc` 尚不存在，会返回
    /// `deferred`——这是无害的，新实例启动时会从持久化值注入正确帧率。
    /// 改完之后跑一次自检，把「注入值 / 引擎目标 / 实测」打到 Xcode 控制台。
    ///
    /// 走异步通道是因为重启主循环要「暂停→等待→恢复」三步，脚本内部要 `await`，
    /// 也顺带把每实例的回执（`ok-restart` / `noop` / `deferred`）打出来，
    /// 便于确认到底有没有真的重启。
    @MainActor
    func applyToRunningInstances() {
        let script = applyScript
        let fps = rawValue
        Self.cancelPendingWork()
        let generation = Self.workGeneration
        Self.pendingWork = Task { @MainActor in
            let accountIDs = MacGameInstanceRegistry.shared.liveAccountIDs()
            for accountID in accountIDs {
                guard !Task.isCancelled else { return }
                let receipt = await MacGameInstanceRegistry.shared.evaluateAsync(script, accountID: accountID)
                guard Self.workGeneration == generation else { return }
                MacLog.debug("[ios2-macos] frame rate %d fps -> %@: %@", fps, accountID, receipt ?? "（无回执）")
            }
            guard !Task.isCancelled, Self.workGeneration == generation else { return }
            MacLog.info("[ios2-macos] frame rate %d fps applied to %d running instance(s)",
                        fps, accountIDs.count)
            // 刚 resume 的头几百毫秒主循环还在爬坡，立刻采样会偏低；
            // 等它稳定下来再测，否则读到的是"重启过程"而不是"稳态帧率"。
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, Self.workGeneration == generation else { return }
            let report = await verifyInRunningInstances()
            guard Self.workGeneration == generation else { return }
            MacLog.info("[ios2-macos] frame rate verify: %@", report)
        }
    }

    /// 手动校验（设置页「校验」按钮）。同样先作废上一轮，避免和自动自检撞车；
    /// 期间又改了帧率的话，本次结果作废并给出说明，不打误导人的数字。
    @MainActor
    func verifyAndLog() async -> String {
        Self.cancelPendingWork()
        let generation = Self.workGeneration
        let report = await verifyInRunningInstances()
        guard Self.workGeneration == generation else { return "（已被新的帧率改动取消，请重新校验）" }
        MacLog.info("[ios2-macos] frame rate verify: %@", report)
        return report
    }

    /// 对所有存活实例做一次帧率自检，返回一行可读报告。
    @MainActor
    func verifyInRunningInstances() async -> String {
        let accountIDs = MacGameInstanceRegistry.shared.liveAccountIDs()
        guard !accountIDs.isEmpty else { return "没有正在运行的实例" }
        var lines: [String] = []
        for accountID in accountIDs {
            let payload = await Self.evaluateWithTimeout(MacFrameRate.verifyScript, accountID: accountID)
            lines.append(Self.describe(accountID: accountID, payload: payload))
        }
        return lines.joined(separator: "； ")
    }

    /// 单次自检：等结果，或 3 秒没回来就放弃。
    ///
    /// 页面被遮挡 / 在后台时 WebKit 会停掉 `requestAnimationFrame`，自检脚本里的
    /// Promise 永远不 resolve，没有超时就会一直挂着（UI 停在「测量中…」）。
    @MainActor
    private static func evaluateWithTimeout(_ script: String, accountID: String) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor in
                await MacGameInstanceRegistry.shared.evaluateAsync(script, accountID: accountID)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            return first ?? nil
        }
    }

    /// 把自检 JSON 翻成一行人话：`账号 实测 30 / 目标 30 / 注入 30`。
    private static func describe(accountID: String, payload: String?) -> String {
        guard let payload,
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "\(accountID)：页面未就绪或窗口不可见"
        }
        func number(_ key: String) -> String {
            guard let value = object[key], !(value is NSNull) else { return "?" }
            if let int = value as? Int { return "\(int)" }
            if let double = value as? Double { return "\(Int(double.rounded()))" }
            return "\(value)"
        }
        var line = "\(accountID)：游戏 \(number("game")) / 目标 \(number("engine")) / 注入 \(number("injected")) / vsync \(number("vsync"))"
        // 有重复主循环时单独点出来——这是帧率读数虚高的直接证据。
        if let dupes = object["dupes"] as? Int, dupes > 0 {
            line += " ⚠️ 重复主循环 \(dupes)/s"
        }
        // 监听器挂重了会让读数成倍虚高，必须和「真的有多条循环」区分开。
        if let hooks = object["hooks"] as? Int, hooks > 1 {
            line += " ⚠️ 监听器 ×\(hooks)"
        }
        return line
    }
}
#endif

// MARK: - 帧率悬浮层

/// 游戏画面左上角的实时帧率角标，用来**肉眼确认**帧率到底生效没有。
///
/// 关键：HUD 显示的「游戏 FPS」来自 Cocos 的 `director_after_update` 事件，计的是
/// **主循环实际跑了多少次**（也就是 `cc.director.mainLoop()` 的真实调用频率），
/// 而不是显示器的 vsync。两者不一样——
/// `ios2-web-cocos2d.js` 的 `_setAnimFrame()` 在非 30/60 档位下会用
/// `setTimeout(_frameTime)`（1000/frameRate 毫秒）调度主循环，所以 15 FPS 设定下
/// 主循环确实每秒只跑 15 次，跟 100Hz 显示器的 rAF 是两件事。
///
/// 为了让「校验」按钮也能数到主循环，**采样器总是常驻**（不管角标开关），仅
/// 角标显示 / 隐藏用单独的 overlay 脚本控制。
enum MacFrameRateHUD {
    static let defaultsKey = "ios2.showFrameRateHUD"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// 采样器：始终在 `atDocumentStart` 注入，幂等。
    ///
    /// - `hook`：`cc.director.on('director_after_update', …)` 是否挂上；引擎在
    ///   文档就绪后才初始化，所以这里 50ms 轮询重试。
    /// - `main`：主循环回调累计次数；HUD 和「校验」都从它取数。
    /// - `vsync`：`requestAnimationFrame` 累计次数；标准 rAF **不被引擎覆盖**
    ///   （引擎只覆盖了内部的 `window.requestAnimFrame`），所以这里永远是显示器的真实刷新率。
    static let samplerScript = """
    (() => {
      const state = (window.__ios2Fps = window.__ios2Fps || { main: 0, vsync: 0, hook: false, hooks: 0, vsyncHandle: 0, writes: [], dupes: 0 });
      // 探针：包住 cc.game.setFrameRate，任何改动帧率的调用都记下 fps + 调用栈，
      // 并立刻回传原生打到控制台——用来抓"设置 90 却变成 30"是谁干的。
      const installSpy = () => {
        try {
          const game = window.cc && window.cc.game;
          if (!game || game.__ios2FpsSpy || typeof game.setFrameRate !== 'function') return;
          game.__ios2FpsSpy = true;
          const original = game.setFrameRate;
          game.setFrameRate = function (fps) {
            try {
              const stack = String((new Error().stack) || '')
                .split('\\n').slice(1, 4).join(' | ');
              state.writes.push({ fps: fps, stack: stack, t: Date.now() });
              if (state.writes.length > 5) state.writes.shift();
              const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ios2Game;
              if (bridge) bridge.postMessage({ type: 'frameRate', fps: fps, stack: stack });
            } catch (ignored) { /* 探针本身绝不能影响游戏 */ }
            return original.call(this, fps);
          };
        } catch (ignored) { /* 同上 */ }
      };
      // 读用户设定的帧率（原生启动时注入），拿不到就返回 0 表示"不干预"。
      const preferredRate = () => {
        const holder = window.__IOS2_GAME_INSTANCE__;
        const value = holder ? Number(holder.frameRate) : 0;
        return value > 0 ? value : 0;
      };
      // 把帧率拉回用户设定值。跟 applyScript 一样走「暂停→等待→重启」：
      // 只改 config.frameRate 会让旧主循环继续活着，帧率读数会翻倍。
      const restorePreferred = (reason) => {
        try {
          const game = window.cc && window.cc.game;
          if (!game || !game.config) return;
          const preferred = preferredRate();
          if (!preferred || game.config.frameRate === preferred) return;
          if (typeof game.pause !== 'function' || typeof game._setAnimFrame !== 'function') return;
          const wasPaused = !!game._paused;
          game.pause();
          const wait = Math.max(120, 3 * (1000 / (game.config.frameRate || 60)));
          setTimeout(() => {
            try {
              game.config.frameRate = preferred;
              if (window.__IOS2_GAME_INSTANCE__) window.__IOS2_GAME_INSTANCE__.frameRate = preferred;
              game._setAnimFrame();
              if (!wasPaused && typeof game.resume === 'function') game.resume();
              const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ios2Game;
              if (bridge) bridge.postMessage({ type: 'frameRateRestore', fps: preferred, reason: reason });
            } catch (ignored) { /* 同上 */ }
          }, wait);
        } catch (ignored) { /* 同上 */ }
      };
      // 登录守卫：游戏 bundle 处理登录响应时会把自己的默认值 30 塞进来
      // （`ios2-login.js:210` 的注释就是这么写的）。原生壳靠 `main.js` 的
      // 「拦截 setFrameRate + 登录后 0/500/2000ms 三次恢复」顶住，
      // WebKit 壳走 `ios2-web-boot.js`，这两道防线都没有 → 登录后目标被打回 30。
      // 这里补上：先拦住不符的改写，再按同样的节奏恢复三次（覆盖异步设值）。
      const installLoginGuard = () => {
        try {
          const game = window.cc && window.cc.game;
          if (!game || game.__ios2LoginGuard || typeof game.setFrameRate !== 'function') return;
          game.__ios2LoginGuard = true;
          const original = game.setFrameRate;
          game.setFrameRate = function (fps) {
            const preferred = preferredRate();
            if (preferred && Number(fps) !== preferred) {
              state.blocked = (state.blocked || 0) + 1;
              const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ios2Game;
              if (bridge) bridge.postMessage({ type: 'frameRateBlocked', fps: fps, preferred: preferred });
              return;   // 不转给引擎，保持用户设定
            }
            return original.call(this, fps);
          };
        } catch (ignored) { /* 同上 */ }
      };
      // `ios2-login.js` 在登录就绪时会调这个钩子（原本只有原生壳的 main.js 定义过）。
      window.__ios2SchedulePerformanceRestore = (reason) => {
        [0, 500, 2000].forEach((delay) => {
          setTimeout(() => restorePreferred(reason + '+' + delay + 'ms'), delay);
        });
      };
      // 主循环去重：运行时改帧率会让引擎残留多条主循环。
      // `_stTimeWithRAF` 是 setTimeout(→rAF) 两段式，返回的 id 是 setTimeout 的；
      // setFrameRate 只用 clearTimeout 取消，若此刻回调已排进 rAF 队列就取消不掉，
      // 旧循环继续活着，而所有循环都动态取 window.requestAnimFrame，
      // 于是多条循环一起跑 → 实测帧率超过显示器刷新率（见过 60 档测出 196）。
      // 同一帧内所有 rAF 回调的时间戳相同，据此丢弃重复调用即可。
      const installMainLoopGuard = () => {
        try {
          const director = window.cc && window.cc.director;
          if (!director || director.__ios2MainLoopGuard) return;
          const original = director.mainLoop;
          if (typeof original !== 'function') return;
          director.__ios2MainLoopGuard = true;
          let lastTimestamp = -1;
          director.mainLoop = function (timestamp) {
            if (typeof timestamp === 'number' && timestamp === lastTimestamp) {
              state.dupes = (state.dupes || 0) + 1;
              return;
            }
            lastTimestamp = timestamp;
            return original.call(this, timestamp);
          };
        } catch (ignored) { /* 守卫本身不能影响游戏 */ }
      };
      // 30 档精确化：引擎把 `config.frameRate === 30` 当作「隔帧跳过」的暗号——
      // `_runMainLoop` 里 `if (30 === a && (s = !s)) return;` 直接跳过一半的帧，
      // 于是 30 档实际帧率 = **显示器刷新率的一半**（60Hz 屏上正好 30，100Hz 屏上是 49）。
      // 修法：启动循环前把 frameRate 临时改成 29.999 并重跑 _setAnimFrame()——
      // 29.999 不在 {30, 60} 里，引擎会自动切到 `_stTimeWithRAF` 节流路径
      // （_frameTime 按 29.999 算出 33.3ms），循环起完立刻还原成 30，
      // 所以 getFrameRate() 对外仍然是 30。放在这里而不是 applyScript 里，
      // 是因为它必须在引擎 boot 时 `_runMainLoop()` 之前就位，
      // 而且以后任何一次 resume()（比如窗口重新可见）都会再走一遍。
      const installExactRate = () => {
        try {
          const game = window.cc && window.cc.game;
          if (!game || game.__ios2ExactRate || typeof game._runMainLoop !== 'function') return;
          game.__ios2ExactRate = true;
          const original = game._runMainLoop;
          game._runMainLoop = function () {
            const keep = this.config ? this.config.frameRate : undefined;
            // 30 和 60 是引擎的「特例档」：`_setAnimFrame()` 只对它们走裸 rAF 不做节流，
            // 于是 60 实际 = 刷新率全速（100Hz 屏上是 100），30 还要再叠加
            // `30 === a && (s = !s)` 隔帧跳过 = 刷新率的一半。两者都名不副实。
            if (keep === 30 || keep === 60) {
              this.config.frameRate = keep - 0.001;
              try { this._setAnimFrame(); } catch (ignored) { /* 失败就退回引擎默认行为 */ }
            }
            try {
              return original.call(this);
            } finally {
              // 无论成功失败都要还原，否则 getFrameRate() 会一直报 29.999。
              if (this.config) this.config.frameRate = keep;
            }
          };
        } catch (ignored) { /* 同上 */ }
      };
      const tryHook = () => {
        if (state.hook) return;
        if (window.cc && window.cc.director && window.cc.Director && window.cc.Director.EVENT_AFTER_UPDATE) {
          window.cc.director.on(window.cc.Director.EVENT_AFTER_UPDATE, () => { state.main += 1; });
          // 正常只会有 1。>1 说明监听器被挂了多次，实测帧率会是真实值的整数倍
          // （2 个监听器 → 60 档测出 196），这跟多条主循环是两种不同的故障。
          state.hooks = (state.hooks || 0) + 1;
          installSpy();
          installLoginGuard();
          installMainLoopGuard();
          installExactRate();
          state.hook = true;
          return;
        }
        setTimeout(tryHook, 50);
      };
      tryHook();
      if (!state.vsyncHandle) {
        const tick = () => { state.vsync += 1; state.vsyncHandle = requestAnimationFrame(tick); };
        state.vsyncHandle = requestAnimationFrame(tick);
      }
      return 'sampler-installed';
    })()
    """

    /// 装上可见角标（幂等）。**自带采样器补装**——页面可能是在采样器注入逻辑上线之前
    /// 就加载好的（已运行实例），那种页面里 `window.__ios2Fps` 不存在，不补装就会
    /// 直接 return，表现就是"开关打开了但什么都不显示"。
    static let overlayShowScript = samplerScript + "\n;\n" + overlayBodyScript

    /// 角标本体：建 DOM + 启 setInterval 刷新。依赖采样器，外部请用 `overlayShowScript`。
    private static let overlayBodyScript = """
    (() => {
      const state = window.__ios2Fps;
      if (!state) return 'sampler-missing';
      const attach = () => {
        let element = document.getElementById('__ios2_fps_hud__');
        if (!element) {
          // documentEnd 注入时 body 可能还没建好，等一下再挂。
          if (!document.body) { setTimeout(attach, 50); return; }
          element = document.createElement('div');
          element.id = '__ios2_fps_hud__';
          element.style.cssText = 'position:fixed;left:8px;top:8px;z-index:2147483647;' +
            'padding:6px 10px;border-radius:6px;background:rgba(0,0,0,0.6);' +
            'color:#7DF9FF;font:600 12px/1.5 ui-monospace,Menlo,monospace;' +
            'pointer-events:none;white-space:pre;';
          document.body.appendChild(element);
        }
        element.style.display = '';
        let prevMain = state.main;
        let prevVsync = state.vsync;
        let prevT = performance.now();
        const update = () => {
          try {
            if (!window.__ios2Fps) return;
            // 自愈：页面后续改动（重建 body / 插入容器）可能把角标摘掉，
            // 元素引用还在，重新挂回去即可，不必重建。
            if (!element.isConnected && document.body) document.body.appendChild(element);
            const cur = window.__ios2Fps;
            const now = performance.now();
            const dt = (now - prevT) / 1000;
            const game = cur.hook && dt > 0 ? Math.round((cur.main - prevMain) / dt) : null;
            const vsync = dt > 0 ? Math.round((cur.vsync - prevVsync) / dt) : 0;
            prevMain = cur.main; prevVsync = cur.vsync; prevT = now;
            // 目标值只能在引擎 config 就位之后读：`cc.game.getFrameRate()` 的实现是
            // `return this.config.frameRate`，文档刚加载完时 config 仍是 null，
            // 直接调会抛 TypeError——这个异常曾把整个脚本打断，导致角标建了但定时器没起。
            let target = window.__IOS2_GAME_INSTANCE__ ? window.__IOS2_GAME_INSTANCE__.frameRate : '?';
            try {
              if (window.cc && cc.game && cc.game.config && typeof cc.game.getFrameRate === 'function') {
                target = cc.game.getFrameRate();
              }
            } catch (ignored) { /* config 未就绪，保留注入值 */ }
            const gameText = (game === null) ? '主循环未启动' : (game + ' FPS');
            // 第二行的屏幕刷新率只是参照系：本设置从不改动它，
            // 它的唯一用途是判断「游戏 FPS 是否超过了物理上限」。
            element.textContent = '游戏 ' + gameText + ' · 目标 ' + target +
              '\\n屏幕 ' + vsync + ' Hz（仅对照）';
          } catch (error) {
            // 单次渲染失败绝不能带走定时器，否则角标会变成"建了但永远空着"。
            element.textContent = 'FPS 角标异常: ' + (error && error.message ? error.message : error);
          }
        };
        // 先起定时器再跑第一次：顺序反了的话，update 抛异常会把定时器一起带走。
        if (window.__ios2FpsUpdater) clearInterval(window.__ios2FpsUpdater);
        window.__ios2FpsUpdater = setInterval(update, 500);
        update();
      };
      attach();
      return 'shown';
    })()
    """

    /// 隐去角标：停刷新 + 隐藏 DOM；采样器保持运行（校验仍能读到主循环计数）。
    static let overlayHideScript = """
    (() => {
      if (window.__ios2FpsUpdater) { clearInterval(window.__ios2FpsUpdater); window.__ios2FpsUpdater = null; }
      const element = document.getElementById('__ios2_fps_hud__');
      if (element) element.style.display = 'none';
      return 'hidden';
    })()
    """

    /// 诊断：回读角标在页面里的真实状态，用来区分"脚本没跑"和"跑了但没显示"。
    static let diagnosticScript = """
    (() => {
      const state = window.__ios2Fps;
      const element = document.getElementById('__ios2_fps_hud__');
      return JSON.stringify({
        sampler: !!state,
        hook: state ? state.hook : null,
        lastWrite: (state && state.writes && state.writes.length)
          ? state.writes[state.writes.length - 1] : null,
        element: !!element,
        connected: element ? !!element.isConnected : null,
        display: element ? (element.style.display || 'block') : null,
        updater: !!window.__ios2FpsUpdater,
        body: !!document.body,
        cc: !!window.cc
      });
    })()
    """

    /// 完全卸载（实例销毁时）：停角标 + 停 rAF + 清采样器状态。
    static let fullRemoveScript = """
    (() => {
      if (window.__ios2FpsUpdater) { clearInterval(window.__ios2FpsUpdater); window.__ios2FpsUpdater = null; }
      if (window.__ios2Fps) {
        if (window.__ios2Fps.vsyncHandle) { cancelAnimationFrame(window.__ios2Fps.vsyncHandle); window.__ios2Fps.vsyncHandle = 0; }
        window.__ios2Fps = null;
      }
      const element = document.getElementById('__ios2_fps_hud__');
      if (element) element.remove();
      return 'removed';
    })()
    """
}
