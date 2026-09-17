import AppKit
import LobbyDomain
import LobbyIPC
import LobbyStorage
import WebKit

/// 单个游戏视口实例：一个 WKWebView + 整局游戏。
///
/// 职责：装配隔离存储与方案处理器、预认证并注入引导脚本、托管加载遮罩、
/// 路由页面事件（配置镜像 / 日志 / 就绪 / HSDK / 渲染完整性）、执行能耗策略
/// （焦点 → 满帧出声；失焦 → 降帧静音）。
///
/// 尺寸红线：Cocos 在文档 boot 阶段就读 window.innerWidth/Height 决定 canvas
/// 尺寸，WKWebView 以 0×0 起步会建一个 0×0 的 canvas 且不会自愈——游戏逻辑
/// 照跑、画面永远黑。所以宿主视图必须以非零兜底尺寸起步，任何零尺寸一律忽略。
@MainActor
public final class GameViewportInstance: NSView {
    /// 兜底尺寸（9:16）。
    private static let fallbackSize = NSSize(width: 270, height: 480)

    /// 主线程慢调用探针阈值（秒）。
    private static let slowMainWorkThreshold: CFTimeInterval = 0.03

    /// 连续多少个采样周期仍报缺失，才认定「不是加载中，是真的坏了」。
    /// 12s × 3 = 36s：足够排除切场景时的大批资源在途。
    private static let renderIntegrityBadSampleLimit = 3
    /// 单个实例最多自动重载几次（超过只报警，防止重启循环）。
    private static let renderIntegrityAutoReloadLimit = 2

    /// 非焦点省电帧率（白名单内最低档；规格的「20 FPS」不在白名单内，取 15）。
    private static let idleFrameRate = TargetFrameRate.idleFallback

    /// 加强下发未落实时的重试节奏：**快档 3s × 20 次**（≈1min，覆盖冷启动 + 装 game bundle），
    /// 之后转**慢档 15s × 60 次**（≈15min）。
    /// 慢档的意义不是「还能修好」，而是**让配置页那行回执一直活着**——
    /// 用户可以随时打开/关掉聊天窗口，看着回执从 `chat=1/0` 变成 `chat=1/1`，
    /// 不必再去捞日志、也不用来回问「到底有没有生效」。
    private static let enhancementRetryFastCount = 20
    private static let enhancementRetryFastNanos: UInt64 = 3_000_000_000
    private static let enhancementRetrySlowNanos: UInt64 = 15_000_000_000
    private static let enhancementRetryLimit = 80

    public let account: GameAccount
    public let environment: InstanceEnvironment
    public let instanceID = UUID().uuidString
    public private(set) var authenticatedAccountID = ""

    /// 所属实例池（生命周期与启动闸门）。
    public weak var pool: GameInstancePool?
    /// 键鼠同步中控（事件上报入口 + 捕获开关写回）。
    public weak var sync: InputSyncController?
    /// JS 脚本库（启动时按环境注入启用中的脚本）。
    public weak var scripts: ScriptStore?
    /// 游戏加强设置库（十殿加速等；文档就绪时下发，改档由会话模型广播）。
    public weak var enhancements: GameEnhancementStore?
    /// 账号资料库（头像 / 游戏内昵称 / 等级战力；页面探针上报后写入）。
    public weak var avatars: AccountAvatarStore?

    private let authenticator: GameAuthenticating
    private let resources: ResourceProviding
    private let settingsMirror: GameSettingsMirror
    private var schemeHandler: GameResourceSchemeHandler!
    private lazy var webView: WKWebView = makeWebView()
    private var hsdkResponder: HSDKResponder?
    /// 登录代理：页面里的 `login_authuser`（游戏内换服 / 回流选区）由它按请求的
    /// `serverId` 现算应答。认证成功后装配；凭据解不开时为 nil（页面侧自动退回
    /// 预认证字节，即改造前的行为）。
    private var loginProxy: LoginProxy?
    /// 预认证响应（base64）。代理不可用时页面靠它兜底，所以必须留在手上。
    private var authResponseBase64 = ""
    /// 给 `/login/serverlist` 这类「体必须是凭据」的端点用的体（与匹配的编码头）。
    private var loginCredential: BinCredential.LoginBody?
    /// 已拦下切服后资料上报的标记（只记一次诊断，不刷屏）。
    private var skippedProfileForServerMismatch = false

    private let loadingOverlay = NSView()
    private let loadingSpinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "正在准备游戏资源…")
    private var gameSessionStarted = false
    private var startupTask: Task<Void, Never>?
    private var storageSyncTask: Task<Void, Never>?
    /// 加强下发的确认重试（见 `sendEnhancementApply`）。
    private var enhancementRetryTask: Task<Void, Never>?
    private var enhancementAttempt = 0
    private var isStopped = false
    private var renderBadSamples = 0
    /// 在途下载的代理。`WKDownload.delegate` 是弱引用，不自己持有就会被提前释放，
    /// 表现为「下载一动不动、也不报错」。
    private var activeDownloads: [ObjectIdentifier: ScriptDownloadSink] = [:]

    /// 存储分区键（镜像 / 数据存储共用口径）。
    public var storageKey: String { account.id }
    /// 启动队列记账用的稳定标识。
    public var accountID: String { account.id }

    public init(account: GameAccount,
                environment: InstanceEnvironment,
                authenticator: GameAuthenticating,
                resources: ResourceProviding,
                settingsMirror: GameSettingsMirror,
                sync: InputSyncController? = nil,
                scripts: ScriptStore? = nil,
                enhancements: GameEnhancementStore? = nil,
                avatars: AccountAvatarStore? = nil) {
        self.account = account
        self.environment = environment
        self.authenticator = authenticator
        self.resources = resources
        self.settingsMirror = settingsMirror
        self.sync = sync
        self.scripts = scripts
        self.enhancements = enhancements
        self.avatars = avatars
        super.init(frame: NSRect(origin: .zero, size: Self.fallbackSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        schemeHandler = GameResourceSchemeHandler(resources: resources)
        addSubview(webView)
        webView.frame = bounds
        buildLoadingOverlay()
        // 登记到群控注册表：中控只认账号 ID，实例的 JS 注入全靠它寻址。
        sync?.registry.register(self, accountID: account.id)
    }

    required init?(coder: NSCoder) { nil }

    // 注意：没有 deinit 兜底拆除——实例的生命周期完全由 GameInstancePool 持有
    // 并经 stop() 显式拆除（Swift 6.3 下 deinit 是 nonisolated，不能再调 @MainActor
    // 方法；池的 destroy/reloadPending 簿记本就保证了唯一拆除路径）。

    override public func layout() {
        super.layout()
        webView.frame = bounds
    }

    /// AppKit 通过 autoresizing mask 改 subview 尺寸时**不会**调用 subview 的
    /// `layout()`。矩阵格子里这一层是宿主视图直接赋 frame，走的正是那条路径。
    /// 零尺寸一律忽略：SwiftUI 布局过程的瞬时 0×0 会把画布清零。
    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize.width > 0.5, newSize.height > 0.5 else { return }
        webView.frame = bounds
    }

    // MARK: - 生命周期

    /// 启动：清单 → 认证 → 会话登记 → 注入脚本 → 装载游戏文档。
    /// 不等待完整 CDN 预热：清单请求与认证可以立刻开始，其余资源由方案处理器
    /// 在游戏可见后惰性缓存。
    public func start() {
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let manifest = try? await self.resources.latestManifest()
                guard !self.isStopped else { return }
                self.loadingLabel.stringValue = "正在登录游戏…"
                LobbyLog.info("[instance] authentication started: %@", self.account.fileName)
                let authentication = try await self.authenticator.authenticate(account: self.account, manifest: manifest)
                LobbyLog.info("[instance] authentication complete: %@", self.account.fileName)
                await self.resources.beginGameSession()
                self.gameSessionStarted = true
                self.authenticatedAccountID = authentication.accountID
                self.authResponseBase64 = authentication.authResponseBase64
                self.prepareLoginProxy(authentication: authentication)
                self.schemeHandler.setBundleVersions(authentication.bundleVersions)
                // 引导脚本每次进游戏前重新登记（视图是池化复用的，登记过期值会污染下一次装载）。
                self.webView.configuration.userContentController.addUserScript(
                    WKUserScript(source: self.bootstrapSource(authentication: authentication),
                                 injectionTime: .atDocumentStart, forMainFrameOnly: true)
                )
                // 注入启用中的 JS 脚本（上一代 _enabledScriptRecords 语义）：
                // 单开环境取「单开生效 + 单多开生效」；多开环境过「多开全局门禁」
                // 后仅取「单多开生效」；总开关关闭 → 一律不注入（只做门闸，
                // 不修改子开关状态）。atDocumentEnd 注入、仅主框架。
                if let scripts = self.scripts {
                    let allowMulti: Bool
                    switch self.environment {
                    case .single: allowMulti = true
                    case .multi: allowMulti = scripts.isMultiOpenGateEnabled
                    }
                    let enabledRecords = scripts.enabledScripts(allowMulti: allowMulti)
                    // 兼容层必须先于用户脚本安装，且在游戏 boot 之前：
                    // ① 接管 `window.__require`——游戏的模块加载器会把它当外层 require
                    //    缓存下来，用户脚本也靠它拿游戏模块（macOS 上原本没人建这个符号，
                    //    脚本因此拿不到 ROLE / 模块 / g_utils，UI 根本不挂载）；
                    // ② 捕获游戏第一条 WebSocket，并把 ws/gameWs/gameSocket/
                    //    WebSocketClient/h5websocket 五个别名一次给全；
                    // ③ 打 DOM 垫片、装 GM_* 垫片。
                    // install() 内部自带「1s × 60 有界轮询」补齐环境（socket、模块、
                    // ROLE 谁先就绪谁先接上），所以不需要额外调用 waitForGame——
                    // 那条路径是旧架构（脚本跑在独立覆盖 WebView）用的。
                    if !enabledRecords.isEmpty, let runtimeSource = scripts.scriptRuntimeSource(),
                       !runtimeSource.isEmpty {
                        self.webView.configuration.userContentController.addUserScript(
                            WKUserScript(source: runtimeSource,
                                         injectionTime: .atDocumentStart, forMainFrameOnly: true)
                        )
                        let glue = "if(window.__ios2ScriptRuntime){window.__ios2ScriptRuntime.install();" +
                            "console.log('[lobby] script runtime installed');}"
                        self.webView.configuration.userContentController.addUserScript(
                            WKUserScript(source: glue,
                                         injectionTime: .atDocumentStart, forMainFrameOnly: true)
                        )
                        LobbyLog.info("[instance] script runtime injected (%ld user script(s))",
                                      enabledRecords.count)
                    }
                    for record in enabledRecords {
                        guard let source = scripts.scriptSource(named: record.name),
                              !source.isEmpty else {
                            LobbyLog.warn("[instance] user script skipped (unreadable): %@", record.name)
                            continue
                        }
                        self.webView.configuration.userContentController.addUserScript(
                            WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
                        )
                        LobbyLog.info("[instance] user script injected: %@ (%@)",
                                      record.name, self.environment == .single ? "single" : "multi")
                    }
                }
                let entry = URL(string: "\(LobbyConfiguration.gameURLScheme)://app/index.html?revision=lobby-macos-1")!
                LobbyLog.debug("[instance] loading game document: %@", entry.absoluteString)
                self.webView.load(URLRequest(url: entry))
            } catch {
                guard !isStopped else { return }
                loadingSpinner.stopAnimation(nil)
                loadingLabel.stringValue = "登录失败：\(error.localizedDescription)"
                showError(title: "账号登录失败", message: error.localizedDescription)
            }
        }
    }

    /// 永久停止。幂等。
    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        // 关窗前把游戏内配置最后一次同步到磁盘（异步执行；平时实时回传已把
        // 绝大部分配置写进镜像）。只捕获局部量，避免从 deinit 逃逸捕获 self。
        let snapshotWebView = webView
        let storageKey = storageKey
        let mirror = settingsMirror
        Task { @MainActor in
            await Self.captureStorageSnapshot(from: snapshotWebView, accountID: storageKey, mirror: mirror)
        }
        startupTask?.cancel()
        startupTask = nil
        storageSyncTask?.cancel()
        storageSyncTask = nil
        enhancementRetryTask?.cancel()
        enhancementRetryTask = nil
        // 关闭前的 scheme 任务收尾：仍在途的任务正常报错结束，之后凡是 WebKit
        // 已停止的任务一律静默丢弃（见 GameResourceSchemeHandler.stopAll）。
        schemeHandler.stopAll()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: LobbyConfiguration.webChannelName)
        // WKUserScript 绑在 userContentController 上、随每次导航注入。start() 是
        // 追加式的，只摘消息处理器会让引导脚本 / 兼容层 / 用户脚本残留并叠加
        // 注入——实例池复用时尤其危险，这里一次清干净。
        webView.configuration.userContentController.removeAllUserScripts()
        // 从群控注册表摘除（identity 校验：重载卡片时新实例已登记，不能误删）。
        sync?.registry.unregister(self, accountID: account.id)
        if gameSessionStarted {
            gameSessionStarted = false
            let resources = self.resources
            Task { await resources.endGameSession() }
        }
        releaseWebView()
    }

    /// stop() 的收尾：把整局游戏连同 WebView 一起放掉。
    ///
    /// 为什么必须放掉，而不是「留着一个已停止的 WebView 不管」：
    /// **SwiftUI 的懒容器不会释放它创建过的平台视图**（实测：把子项移出 `ForEach`、
    /// 换 identity、改窗口尺寸，10 轮下来一个 `deinit` 都没有），而矩阵格子的平台
    /// 视图就是本实例。于是「关闭实例」之后这个实例仍被格子的缓存吊着——只要它手里
    /// 还攥着那个装着整局游戏的 `WKWebView`，就等于没关：WebContent 进程、
    /// 十几 MB 游戏字节码、纹理与 WebGL 上下文全留在内存里。同一个机制也解释了
    /// 「重新登录」为什么越点越胖：`reloadRevision` 换掉的是格子身份，被换掉的旧格子
    /// 连同旧实例一起留在缓存里。
    ///
    /// 换成一个从不导航的空壳之后，旧 WebView 立刻失去最后一个强引用（关窗前的
    /// 配置快照任务自己持有一份，它拿完即放），进程与游戏内存随之归还系统。
    /// 空壳同时是一道安全网：stop() 之后任何迟到的回调（`didFinish`、能量策略、
    /// 群控注入、加强下发重试）打在它身上都是无害的 no-op，不会再碰已停止的页面。
    private func releaseWebView() {
        // 遮罩还在转的话，被缓存的死实例会一直空转烧 CPU。
        loadingSpinner.stopAnimation(nil)
        loadingOverlay.isHidden = true
        let retired = webView
        retired.removeFromSuperview()
        webView = WKWebView(frame: bounds)
    }

    /// 运行时切换画质：调用页面桥 `__LOBBY_QUALITY__.set()`，
    /// 重设 cc.view._maxPixelRatio 并触发画布重算（不重启游戏）。
    /// 引擎未就绪时页面侧返回 deferred（boot 时会读注入对象的档位）。
    public func applyQuality(_ quality: RenderQuality) {
        let raw = quality.rawValue
        // 返回值诊断：ok:<ratio>=成功；deferred=引擎未就绪（boot 会读注入对象，
        // 无需重试）；no-handler=页面没有运行时 setter（构建产物未更新）。
        let script = "window.__LOBBY_QUALITY__ ? window.__LOBBY_QUALITY__.set('\(raw)') : 'no-handler'"
        webView.evaluateJavaScript(script) { result, error in
            if let error {
                LobbyLog.warn("[instance] quality apply(%@) failed: %@", raw, error.localizedDescription)
            } else {
                LobbyLog.info("[instance] quality apply(%@) -> %@", raw,
                              (result as? String) ?? String(describing: result))
            }
        }
    }

    /// 群控中控向本实例页面注入 JS（回放事件 / 切捕获开关 / 波纹开关）。
    public func evaluateBridgeScript(_ script: String, completion: ((Error?) -> Void)? = nil) {
        webView.evaluateJavaScript(script) { _, error in completion?(error) }
    }

    /// 下发游戏加强设置（十殿加速开关 + 倍率 / 聊天窗口显隐）。
    ///
    /// 幂等，可重复调用。三条触发路径：① 文档就绪（`didFinish`）；② 页面的启动沉降
    /// 结束（`ready`，这时游戏才真的装好）；③ 用户改档，由会话模型广播。
    ///
    /// 因为「下发那一刻页面还没装好游戏」是常态（实测 `didFinish` 时
    /// `window.fgui` / `__require` 都还不存在），这里再做一层**确认重试**：
    /// 回执没落实就每 3s 重发一次（最多 20 次 ≈ 60s），顺便把界面上的回执刷新成活的。
    public func applyEnhancements() {
        enhancementAttempt = 0
        sendEnhancementApply()
    }

    /// 一次下发 + 校验回执；未落实则排下一次。
    private func sendEnhancementApply() {
        guard let enhancements, !isStopped,
              enhancementAttempt < Self.enhancementRetryLimit else { return }
        let settings = enhancements.settings
        let script = GameEnhancementScript.apply(enabled: settings.nightmareSpeedEnabled,
                                                speed: settings.nightmareSpeedMultiplier,
                                                hideChat: settings.chatPanelHidden)
        // 闭包会逃逸（evaluateJavaScript 的 completion 是 @escaping），
        // 所以只捕获值 + weak self，不把实例吊住。
        let accountName = account.nickname
        let attempt = enhancementAttempt
        webView.evaluateJavaScript(script) { [weak self] result, error in
            if let error {
                // 失败也要回执：只进日志的话，用户实测「没反应」时界面上什么都没变，
                // 分不清是「没下发」还是「下发失败」。
                LobbyLog.warn("[instance] enhancement apply failed: %@", error.localizedDescription)
                enhancements.notePageReport("apply-error: \(error.localizedDescription)",
                                            account: accountName)
                return
            }
            // 诊断串形如
            // `running=1 speed=100 hook=1 panel=1 chat=0/0 skin=0/0 root=groot note=running-live chatNote=idle`；
            // 一个面板都没命中时还会自动附上结构探针（`probe env … roots=…`）。
            // no-handler = 代理脚本没进页面（构建产物未更新）。
            let diagnostic = (result as? String) ?? String(describing: result)
            // 统一前缀便于捞：控制台筛 `[enhance]` 即可看到全部下发回执。
            LobbyLog.info("[enhance] %@", diagnostic)
            // 同时回执给设置页：用户实测「没生效」时不用捞日志。
            enhancements.notePageReport(diagnostic, account: accountName)

            guard let self, !self.isStopped else { return }
            let settled = Self.enhancementIsSettled(diagnostic: diagnostic, settings: settings)
            guard !settled else {
                if attempt > 0 {
                    LobbyLog.info("[instance] enhancement settled after %ld attempt(s)", attempt + 1)
                }
                return
            }
            self.scheduleEnhancementRetry()
        }
    }

    /// 回执是否已落实：代理不在（页面没装）或聊天窗口还没被压住，都还要再试。
    private static func enhancementIsSettled(diagnostic: String,
                                             settings: GameEnhancementSettings) -> Bool {
        guard !diagnostic.contains("no-handler") else { return false }
        if settings.chatPanelHidden, !diagnostic.contains("chat=1/1") { return false }
        return true
    }

    private func scheduleEnhancementRetry() {
        enhancementAttempt += 1
        let nanos = enhancementAttempt <= Self.enhancementRetryFastCount
            ? Self.enhancementRetryFastNanos
            : Self.enhancementRetrySlowNanos
        enhancementRetryTask?.cancel()
        enhancementRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            self?.sendEnhancementApply()
        }
    }

    /// 用户主动「重新登录」。
    public func requestReload() {
        pool?.requestReload(accountID: account.id)
    }

    /// 抢焦点：键盘事件只会派发给第一响应者。
    public func focusWebView() {
        guard let window = webView.window ?? self.window else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
    }

    // MARK: - 能耗仲裁（规格 §4.1）

    /// 焦点实例满帧出声；非焦点实例降帧静音。
    /// 帧率走「暂停 → 等旧循环退出 → 重启」路径（`cc.game.setFrameRate` 在
    /// Cocos 2.4.9 有缺陷：每调一次多一条主循环并存，实测帧率能冲到刷新率 2 倍）。
    public func applyEnergyPolicy(isFocused: Bool) {
        let muteWhenUnfocused = UserDefaults.standard.object(forKey: LobbyConfiguration.PreferenceKey.muteWhenUnfocused) as? Bool ?? true
        applyAudioMuted(isFocused ? false : muteWhenUnfocused)
        applyFrameRate(isFocused ? TargetFrameRate.current() : Self.idleFrameRate)
    }

    /// 运行时改写主循环帧率的 JS（callAsyncJavaScript 函数体，允许 await）。
    private static func frameRateApplyScript(for fps: Int) -> String {
        let global = LobbyConfiguration.instanceGlobalName
        return """
        const fps = \(fps);
        if (window.\(global)) window.\(global).frameRate = fps;
        const g = window.cc && window.cc.game;
        // 引擎没起来（页面还在登录 / 加载资源）：值已写进注入对象，boot 时自己会读。
        if (!g || !g.config) return 'deferred:' + fps;
        if (g.config.frameRate === fps) return 'noop:' + fps;
        // 依赖引擎内部结构（_setAnimFrame）；换了 cocos 版本没有它时退回公开接口——
        // 宁可忍受旧缺陷，也不能让帧率根本改不动。
        if (typeof g._setAnimFrame !== 'function' || typeof g.pause !== 'function' || typeof g.resume !== 'function') {
          if (typeof g.setFrameRate === 'function') { g.setFrameRate(fps); return 'ok-legacy:' + fps; }
          return 'unavailable:' + fps;
        }
        const wasPaused = !!g._paused;
        try { g.pause(); } catch (error) {}
        // 等旧回调跑完并自然退出：3 倍当前帧时长且不少于 120ms，
        // 保证慢档（15fps 一帧 66ms）排队的 setTimeout 也来得及触发。
        const wait = Math.max(120, 3 * (1000 / (g.config.frameRate || 60)));
        await new Promise((resolve) => setTimeout(resolve, wait));
        g.config.frameRate = fps;
        if (window.\(global)) window.\(global).frameRate = fps;
        g._setAnimFrame();
        if (!wasPaused) g.resume();
        return 'ok-restart:' + fps;
        """
    }

    private func applyFrameRate(_ fps: TargetFrameRate) {
        let body = Self.frameRateApplyScript(for: fps.rawValue)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
            } catch {
                LobbyLog.warn("[instance] frame rate apply failed: %@", error.localizedDescription)
            }
        }
    }

    /// 多开静音：N 个实例同时播放 = N 路音频解码 + N 个注定失败的进程断言请求。
    /// 静音时把音量 setter 顶掉——游戏后续会自己调回来，光设 0 不够。
    private func applyAudioMuted(_ muted: Bool) {
        let script = """
        (function () {
          var muted = \(muted ? "true" : "false");
          var volume = muted ? 0 : 1;
          var tries = 0;
          function apply() {
            try {
              if (!(window.cc && cc.audioEngine)) return false;
              if (muted) {
                if (!cc.audioEngine.__lobbyMuted) {
                  cc.audioEngine.__lobbyOrigSetMusic = cc.audioEngine.setMusicVolume;
                  cc.audioEngine.__lobbyOrigSetEffects = cc.audioEngine.setEffectsVolume;
                  cc.audioEngine.__lobbyMuted = true;
                }
                cc.audioEngine.__lobbyOrigSetMusic.call(cc.audioEngine, 0);
                cc.audioEngine.__lobbyOrigSetEffects.call(cc.audioEngine, 0);
                cc.audioEngine.setMusicVolume = function () {};
                cc.audioEngine.setEffectsVolume = function () {};
              } else if (cc.audioEngine.__lobbyMuted) {
                cc.audioEngine.__lobbyMuted = false;
                cc.audioEngine.setMusicVolume = cc.audioEngine.__lobbyOrigSetMusic;
                cc.audioEngine.setEffectsVolume = cc.audioEngine.__lobbyOrigSetEffects;
                cc.audioEngine.setMusicVolume(volume);
                cc.audioEngine.setEffectsVolume(volume);
              }
              return true;
            } catch (error) { return false; }
          }
          // cc.audioEngine 要等 Cocos 起来才有，这里轮询等一下。
          if (!apply()) {
            var timer = setInterval(function () {
              if (apply() || ++tries > 60) clearInterval(timer);
            }, 250);
          }
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - 装配

    private func makeWebView() -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(self, name: LobbyConfiguration.webChannelName)

        // ① 文档创建之前先把上次保存的游戏配置写回 localStorage。
        let restore = settingsMirror.restoreScript(forAccount: storageKey)
        if !restore.isEmpty {
            LobbyLog.debug("[instance] restoring persisted game settings: %@", storageKey)
            contentController.addUserScript(
                WKUserScript(source: restore, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }
        // ② 之后每一次写入都实时同步到原生镜像，关窗 / 崩溃都不丢配置。
        contentController.addUserScript(
            WKUserScript(source: GameSettingsMirror.mirrorScript,
                         injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        // ③ 键鼠同步代理：捕获器 + 回放器 + 波纹特效层。每个实例都装，
        // 谁是主控 / 谁参与同步由 InputSyncController 用 setCapture(on) 切换
        // （WKUserScript 只能在导航时注入，运行时无法追加，所以必须预先装好）。
        contentController.addUserScript(
            WKUserScript(source: InputSyncScript.agent,
                         injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        // ④ 游戏加强代理（十殿加速等）：同样必须预注入——用户在实例已经跑起来
        // 之后才打开开关时，运行时只能推配置，没法再补装代理。
        contentController.addUserScript(
            WKUserScript(source: GameEnhancementScript.agent,
                         injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        // ⑤ 账号资料探针（只读 `window.ROLE` → 头像 / 昵称 / 等级战力）。
        // 没有开关：它是纯读的，代价是三次属性读取 + 首次上报后每 5s 一次比对，
        // 而且不预注入就永远补不上（账号卡的头像要等下一次导航才有）。
        contentController.addUserScript(
            WKUserScript(source: AccountProfileScript.agent,
                         injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: LobbyConfiguration.gameURLScheme)
        configuration.websiteDataStore = Self.websiteDataStore(forAccountID: storageKey)
        configuration.userContentController = contentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = false
        // 排查用：`defaults write com.xyzw.gamelobby.macos lobby.debug.webInspector -bool true`
        // 打开后可在页面上右键「检查元素」调出 Safari Web Inspector。
        view.isInspectable = UserDefaults.standard.bool(forKey: LobbyConfiguration.PreferenceKey.webInspector)

        hsdkResponder = HSDKResponder(
            dispatchJS: { [weak view] script in
                view?.evaluateJavaScript(script, completionHandler: nil)
            },
            identityProvider: { [weak self] in
                guard let self, !self.authenticatedAccountID.isEmpty else {
                    return StableIdentifier.fallbackIdentity(forFileName: self?.account.fileName ?? "")
                }
                return self.authenticatedAccountID
            }
        )
        return view
    }

    private func buildLoadingOverlay() {
        loadingOverlay.wantsLayer = true
        loadingOverlay.layer?.backgroundColor = NSColor(calibratedRed: 0.063, green: 0.075, blue: 0.094, alpha: 1).cgColor
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(loadingOverlay)

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingSpinner.isIndeterminate = true
        loadingSpinner.startAnimation(nil)
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(loadingSpinner)

        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.font = .systemFont(ofSize: 14)
        loadingLabel.alignment = .center
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(loadingLabel)

        NSLayoutConstraint.activate([
            loadingOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            loadingOverlay.topAnchor.constraint(equalTo: topAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            loadingSpinner.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor, constant: -14),
            loadingLabel.topAnchor.constraint(equalTo: loadingSpinner.bottomAnchor, constant: 12),
            loadingLabel.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor)
        ])
    }

    // MARK: - 存储策略

    /// 按 GameStoragePolicy 选型 WKWebsiteDataStore（规格 §2.2 账号强隔离）。
    /// 隔离 / 共享都用确定性 UUID：同一账号每次启动拿到同一个存储区。
    private static func websiteDataStore(forAccountID accountID: String) -> WKWebsiteDataStore {
        switch GameStoragePolicy.current() {
        case .ephemeral:
            return .nonPersistent()
        case .sharedAcrossAccounts:
            return WKWebsiteDataStore(forIdentifier: StableIdentifier.uuid(from: "lobby-game-store-shared"))
        case .isolatedPerAccount:
            return WKWebsiteDataStore(forIdentifier: StableIdentifier.uuid(from: "lobby-game-store-\(accountID)"))
        }
    }

    // MARK: - 引导脚本

    private func bootstrapSource(authentication: AuthResult) -> String {
        // 多开时把实例数告诉页面：WebRuntime 据此压低渲染像素比。独立窗口恒为 1。
        let instanceCount = environment == .multi ? (pool?.liveCount ?? 1) : 1
        return BootstrapScriptBuilder.makeScript(configuration: .init(
            instanceID: instanceID,
            accountName: account.nickname,
            authResponseBase64: authentication.authResponseBase64,
            manifestJSON: Self.normalizedManifest(authentication.manifestJSON),
            frameRate: TargetFrameRate.current().rawValue,
            qualityRawValue: RenderQuality.current().rawValue,
            instanceCount: instanceCount,
            credentialBase64: loginCredential?.bytes.base64EncodedString() ?? "",
            credentialEncoding: loginCredential?.encodingHeader,
            serverOrigin: LobbyConfiguration.gameServerURL.absoluteString,
            credentialServerID: loginProxy?.credentialServerID
        ))
    }

    /// 清单 JSON 归一化（非法时回退空对象，页面侧能容忍）。
    private static func normalizedManifest(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let encoded = try? JSONSerialization.data(withJSONObject: object),
              let value = String(data: encoded, encoding: .utf8) else { return "{}" }
        return value
    }

    // MARK: - 页面事件路由

    private func handle(pageEvent: PageEvent) {
        switch pageEvent {
        case .hsdk(let requestJSON):
            hsdkResponder?.handle(requestJSON: requestJSON)
        case .storageSet(let key, let value):
            settingsMirror.setValue(value, forKey: key, accountID: storageKey)
        case .storageRemove(let key):
            settingsMirror.setValue(nil, forKey: key, accountID: storageKey)
        case .console(let level, let message):
            switch level {
            case "error": LobbyLog.error("[js] %@", message)
            case "warn": LobbyLog.warn("[js] %@", message)
            case "info": LobbyLog.info("[js] %@", message)
            default: LobbyLog.debug("[js] %@", message)
            }
            // 引导脚本 / 登录链路的诊断行额外落一份盘：控制台粘贴经常正好截掉
            // 出问题的那几十行（已经因此白跑两轮），落盘之后可以直接读文件。
            if message.contains("[lobby]") {
                DiagnosticsLog.append("[js] \(message)")
            }
        case .error(let message):
            LobbyLog.error("[instance] JS error: %@", message)
        case .ready(let readiness):
            // 启动沉降完成：释放启动槽位。多开时靠这个把「N 个实例同时抢
            // I/O 和 GPU」变成排队通过。
            LobbyLog.info("[instance] ready: elapsed=%ldms stable=%@",
                          readiness.elapsedMs, readiness.stable ? "yes" : "no")
            pool?.noteInstanceReady(accountID: account.id)
            // 再补一次加强下发。`didFinish` 只是**文档**加载完，此时 WebRuntime 往往
            // 还没把游戏 bundle 装起来（`window.fgui` / `__require` 都还不存在），
            // 那一刻下发等于空转——实测就是这样：日志里只有一条 `waiting-require` 的
            // 空下发，页面侧拿不到任何可操作的对象。`ready` 才是「游戏真的跑起来了」。
            applyEnhancements()
        case .render(let sample):
            handleRenderIntegrity(sample)
        case .webGLFatal:
            // 上下文丢了且没恢复：Cocos 2.4 的 gfx 后端没有任何重建路径，
            // 局部补纹理救不回 program / buffer / VAO，只能整页重载。
            LobbyLog.error("[instance] WebGL context unrecoverable, reloading")
            requestAutomaticReload(reason: "webgl context lost")
        case .memory(let reason, let assets, let nodes):
            LobbyLog.debug("[instance] web memory (%@): assets=%@ nodes=%@", reason, assets, nodes)
        case .graphics(let event, let message):
            LobbyLog.warn("[instance] WebGL %@: %@", event, message)
        case .frameRateWrite(let fps, let stack):
            LobbyLog.debug("[instance] frame rate write: fps=%@ stack=%@", fps, stack)
        case .input(let event):
            // 键鼠同步：本实例只有被允许发言时中控才会路由（中控会再校验一次）。
            sync?.publish(event, from: account.id)
        case .openURL(let url):
            openExternally(url)
        case .downloadFile(let name, let mimeType, let base64):
            saveExportedFile(base64: base64, name: name, mimeType: mimeType)
        case .downloadURL(let url, let name):
            downloadExportedFile(url: url, name: name)
        case .accountProfile(let snapshot):
            // 资料探针只认「运行中的页面」，不认「账号归属」：游戏内切服之后，
            // 页面里的 ROLE 是**新区**的角色。若照单全收，原账号卡会被刷成新区角色，
            // 用户就分不清这张卡是旧 bin 还是新区 —— 所以只接受「归属一致」的资料：
            //   · 快照没带 serverID（旧探针 / 字段缺失）→ 放行（保持旧兼容）；
            //   · 凭据没有 serverId（少数 bin，归属本身未知）→ 放行；
            //   · 其余：不一致 = 游戏内切服产生的新区资料 → 拦下（只记一条诊断）。
            if let expected = loginProxy?.credentialServerID, expected != 0,
               snapshot.serverID != 0, snapshot.serverID != Int(expected) {
                if !skippedProfileForServerMismatch {
                    skippedProfileForServerMismatch = true
                    LobbyLog.info("[instance] 拦下切服后的资料上报（页面 serverId=%ld ≠ 凭据 %lld），账号卡保持原区资料",
                                  snapshot.serverID, expected)
                    DiagnosticsLog.append("[instance] 拦下切服后的资料上报"
                        + "（页面 serverId=\(snapshot.serverID) ≠ 凭据 \(expected)）——账号卡保持原区资料")
                }
                return
            }
            // 账号资料只读上报：直接归属到本实例自己的账号。
            // 落盘 + 拉头像由 store 负责（卡片从 store 读，不碰实例）。
            avatars?.record(snapshot, forAccountID: account.id)
        case .loginAuth(let kind, let requestID, let bodyBase64):
            respondToLoginRequest(kind: kind, requestID: requestID, bodyBase64: bodyBase64)
        case .loginDiag(let message):
            // 页面侧的登录链路诊断：直接落盘。这条通道特意**不经过 console**
            // （游戏 boot 后会把 console 整个换掉，我们包装的那层会失效）。
            LobbyLog.info("[login-diag] %@", message)
            DiagnosticsLog.append("[diag] \(message)")
        case .unknown(let type):
            LobbyLog.debug("[instance] page event: %@", type)
        }
    }

    // MARK: - 登录代理

    /// 装配登录代理。
    ///
    /// 只在凭据**能解开**时装：解不开就没有「按 serverId 重算」的原料，退回页面侧的
    /// 预认证字节兜底（= 改造前的行为）比分发出一个半残的代理安全。
    private func prepareLoginProxy(authentication: AuthResult) {
        guard let credential = try? BinCredential(data: authentication.binData),
              let response = Data(base64Encoded: authentication.authResponseBase64),
              response.count > 4 else {
            loginProxy = nil
            loginCredential = nil
            LobbyLog.warn("[instance] 凭据无法解析，登录代理停用（游戏内选区将退回原区服）：%@",
                          account.fileName)
            return
        }
        loginProxy = LoginProxy(credential: credential, defaultResponse: response)
        // 页面侧还有一类请求需要「体 = 凭据本身」（`/login/serverlist`）：
        // 游戏自己发的是参数体，服务端只会回一个空列表 —— 「选择大区」因此是空的。
        loginCredential = try? credential.loginBody(serverID: nil)
        LobbyLog.info("[instance] 登录代理就绪：凭据区服 serverId=%lld（凭据体 %ld 字节，编码头 %@）",
                      credential.serverID ?? 0,
                      loginCredential?.bytes.count ?? 0,
                      loginCredential?.encodingHeader ?? "（不发）")
        DiagnosticsLog.append("[agent] \(account.fileName) 凭据 serverId=\(credential.serverID.map(String.init) ?? "无")"
            + " 凭据体 \(loginCredential?.bytes.count ?? 0) 字节"
            + " 编码头 \(loginCredential?.encodingHeader ?? "（不发）")")
    }

    /// 页面里的登录请求：按 `kind` 分派。
    ///
    /// 任何失败路径都退回预认证字节 —— 代理只能让事情**变好**，不能成为新的故障点。
    private func respondToLoginRequest(kind: String, requestID: String, bodyBase64: String) {
        guard let loginProxy else {
            completeLoginRequest(requestID: requestID,
                                 base64: authResponseBase64,
                                 source: "no-proxy")
            return
        }
        // serverlist：页面发不出 `O4e-Encoding`（自定义 scheme 的跨源 XHR 会丢非安全头），
        // 必须由宿主带凭据去发，响应才是游戏解得开的 `lx`。
        if kind == "serverList" {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let answer = await loginProxy.serverListResponse()
                guard !self.isStopped else { return }
                LobbyLog.info("[login-proxy] serverlist 应答 %@（%ld 字节）",
                              requestID, answer.bytes.count)
                DiagnosticsLog.append("[login-proxy] serverlist 应答 \(requestID)"
                    + "（来源=\(answer.source)，\(answer.bytes.count) 字节）")
                self.completeLoginRequest(requestID: requestID,
                                          base64: answer.bytes.base64EncodedString(),
                                          source: answer.source)
            }
            return
        }
        let body = Data(base64Encoded: bodyBase64)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let answer = await loginProxy.respond(gameRequestBody: body)
            guard !self.isStopped else { return }
            LobbyLog.info("[login-proxy] 应答 %@（来源=%@，%ld 字节）",
                          requestID, answer.source, answer.bytes.count)
            DiagnosticsLog.append("[login-proxy] 应答 \(requestID)（来源=\(answer.source)，\(answer.bytes.count) 字节）")
            self.completeLoginRequest(requestID: requestID,
                                      base64: answer.bytes.base64EncodedString(),
                                      source: answer.source)
        }
    }

    private func completeLoginRequest(requestID: String, base64: String, source: String) {
        let script = "window.__LOBBY_LOGIN__ && window.__LOBBY_LOGIN__.complete("
            + jsonLiteral(requestID) + "," + jsonLiteral(base64) + "," + jsonLiteral(source) + ")"
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                // 页面侧本来就有 15s 超时兜底，这里只记一条便于定位。
                LobbyLog.warn("[login-proxy] 回填失败 %@：%@", requestID, error.localizedDescription)
            }
        }
    }

    /// Swift 字符串 → JS 字符串字面量（用 JSONEncoder，避免手写转义出错）。
    private func jsonLiteral(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text),
              let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal
    }

    /// 脚本经 GM_openInTab 请求打开外链。只放行 http/https：脚本是第三方来源，
    /// 不能让它用自定义 scheme 去触发本机应用或系统设置跳转。
    private func openExternally(_ urlString: String) {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            LobbyLog.warn("[instance] blocked external open request: %@", urlString)
            return
        }
        LobbyLog.info("[instance] opening externally: %@", urlString)
        NSWorkspace.shared.open(url)
    }

    /// 脚本导出（`<a download>` + Blob）落盘到系统「下载」目录。
    /// 解码 + 写盘丢到后台：单文件上限 32 MB，在主线程解 base64 会直接撞上
    /// `slow main work` 探针，还会拖住这一个格子的画面。
    private func saveExportedFile(base64: String, name: String, mimeType: String) {
        Task.detached(priority: .utility) {
            guard let url = DownloadStore.write(base64: base64, preferredName: name, mimeType: mimeType) else {
                LobbyLog.warn("[instance] export dropped: %@", name)
                return
            }
            LobbyLog.info("[instance] export saved: %@", url.path)
        }
    }

    /// 脚本导出的是远端 URL（`<a download href="https://…">`）：原生代下，
    /// 同样只放行 http/https，并复用下载目录的改名 / 净化规则。
    private func downloadExportedFile(url urlString: String, name: String) {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            LobbyLog.warn("[instance] blocked download request: %@", urlString)
            return
        }
        let preferredName = name.isEmpty ? url.lastPathComponent : name
        Task.detached(priority: .utility) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            do {
                let (temporary, response) = try await session.download(from: url)
                let mimeType = response.mimeType ?? "application/octet-stream"
                DownloadStore.adopt(temporaryFile: temporary, preferredName: preferredName, mimeType: mimeType)
            } catch {
                LobbyLog.error("[instance] download failed %@: %@", urlString, error.localizedDescription)
            }
        }
    }

    /// 渲染完整性：连续 3 个采样周期报缺失 → 请求整页兜底重载（有限次数）。
    private func handleRenderIntegrity(_ sample: RenderHealthSample) {
        guard sample.missingCount > 0 else {
            if renderBadSamples > 0 {
                LobbyLog.info("[instance] render integrity recovered after %ld degraded sample(s)", renderBadSamples)
            }
            renderBadSamples = 0
            return
        }
        // 上下文已丢的场景交给 webgl-fatal 单独兜底，不重复触发。
        guard !sample.contextLost else {
            LobbyLog.warn("[instance] render integrity degraded while WebGL context is lost; deferring to webgl-fatal")
            return
        }
        renderBadSamples += 1
        LobbyLog.warn("[instance] render integrity degraded (%@): missing=%ld/%ld texture=%ld material=%ld",
                      sample.reason, sample.missingCount, sample.visible,
                      sample.missingTexture, sample.missingMaterial)
        guard renderBadSamples >= Self.renderIntegrityBadSampleLimit else { return }
        requestAutomaticReload(reason: "missing \(sample.missingCount)/\(sample.visible) after \(renderBadSamples) samples")
    }

    /// 触发一次兜底重载。这不是「重试」，而是承认局部状态已经不可信：
    /// Cocos 的渲染管线没有自愈路径，重新拉起一局是最省事也最可靠的兜底。
    private func requestAutomaticReload(reason: String) {
        guard !isStopped, let pool else { return }
        let used = pool.automaticReloadCount(forAccountID: account.id)
        guard used < Self.renderIntegrityAutoReloadLimit else {
            LobbyLog.error("[instance] still failing after %ld auto reload(s), stop retrying: %@", used, reason)
            return
        }
        pool.noteAutomaticReload(forAccountID: account.id)
        renderBadSamples = 0
        LobbyLog.warn("[instance] auto reloading (%ld/%ld): %@", used + 1,
                      Self.renderIntegrityAutoReloadLimit, reason)
        pool.requestReload(accountID: account.id)
    }

    // MARK: - 配置快照兜底

    /// 每 20 秒把页面里的 localStorage 全量镜像一次到磁盘
    /// （兜住实时回传被绕过的情况，例如页面直接改 storage 的内部实现）。
    private func startStorageSync() {
        storageSyncTask?.cancel()
        storageSyncTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, !self.isStopped else { return }
                await Self.captureStorageSnapshot(from: self.webView, accountID: self.storageKey,
                                                  mirror: self.settingsMirror)
            }
        }
    }

    private static func captureStorageSnapshot(from webView: WKWebView, accountID: String,
                                               mirror: GameSettingsMirror) async {
        let script = """
        (() => {
          try {
            const limit = \(GameSettingsMirror.maxMirroredValueLength);
            const store = window.localStorage;
            const out = {};
            for (let index = 0; index < store.length; index++) {
              const key = store.key(index);
              if (key === null) continue;
              const value = store.getItem(key);
              if (typeof value === 'string' && value.length <= limit) out[key] = value;
            }
            return JSON.stringify(out);
          } catch (error) { return '{}'; }
        })()
        """
        guard let result = try? await webView.evaluateJavaScript(script),
              let json = result as? String,
              let data = json.data(using: .utf8),
              let storage = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              !storage.isEmpty else { return }
        mirror.replaceAll(with: storage, accountID: accountID)
        mirror.flush(accountID: accountID)
    }

    // MARK: - 错误展示

    private func showNavigationError(_ error: Error) {
        loadingSpinner.stopAnimation(nil)
        loadingLabel.stringValue = "游戏页面加载失败：\(error.localizedDescription)"
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        if let target = window ?? NSApp.mainWindow {
            alert.beginSheetModal(for: target)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - WKNavigationDelegate

extension GameViewportInstance: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        // 导航失败就等不到页面的 ready 了，必须手动放掉启动槽位，
        // 否则后面的实例要白等满 90s 超时。
        pool?.noteInstanceReady(accountID: account.id)
        showNavigationError(error)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        pool?.noteInstanceReady(accountID: account.id)
        showNavigationError(error)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadingOverlay.isHidden = true
        LobbyLog.info("[instance] game document loaded")
        startStorageSync()
        // 页面就绪后把「是否捕获 / 波纹开关」写回页面：WKUserScript 在导航时已注入
        // 代理，但捕获开关是运行时状态（重载/新建实例都必须补一次）。
        sync?.refreshCapture(forAccountID: account.id)
        // 游戏加强（十殿加速）同理：代理已随文档起点注入，这里补一次当前配置。
        applyEnhancements()
        // 就绪后先按「非焦点」降帧静音；焦点仲裁由会话模型在 ready 后统一重放。
        applyEnergyPolicy(isFocused: false)
        scheduleLoginStatsSnapshots()
    }

    /// 定时把页面侧的登录链路计数捞回来。
    ///
    /// 为什么需要：这条链路出问题时**界面只是空着**，没有异常、没有报错，
    /// 「有没有发过那条请求 / 走的哪条通道」是最关键的判据，而它只在页面里。
    /// 页面自己的 `console.warn` 已经会回传，这里是「不用翻日志也能一眼看到」的备份。
    private func scheduleLoginStatsSnapshots() {
        for delay in [10.0, 25.0, 40.0, 60.0, 90.0, 150.0] {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !self.isStopped else { return }
                // 用 async 版（completionHandler 版在新 SDK 的 async 上下文里会告警）。
                let result = try? await self.webView.evaluateJavaScript(
                    "window.__LOBBY_LOGIN__ ? window.__LOBBY_LOGIN__.stats() : 'no-login-shim'"
                )
                let text = (result as? String) ?? "?"
                LobbyLog.info("[login-stats] +%lds %@", Int(delay), text)
                DiagnosticsLog.append("[login-stats] +\(Int(delay))s \(text)")
            }
        }
    }

    // MARK: - 页面导出的下载通道

    /// 第三方脚本的导出是 `Blob` + `<a download>` + `a.click()`（锚点常常脱离文档）。
    /// 实测 WebKit **原生支持**这种下载：锚点带 `download` 属性时
    /// `navigationAction.shouldPerformDownload == true`，并且它会把脚本指定的文件名
    /// 原样带进 `suggestedFilename`。所以宿主只需要把策略放成 `.download`、
    /// 在 `didBecome` 时挂上代理、在代理里挑一个落盘位置就完事。
    ///
    /// 这一步**必须在原生侧做**：靠页面侧垫片接管锚点的话，导出就会依赖
    /// 脚本运行时被注入（那是另一条独立链路），而且要走一次 base64 中转、受大小限制。
    /// 缺了这里，WebKit 会进入下载通道却拿不到目的地 —— 日志里就会看到
    /// `Could not create a sandbox extension for ''`，导出表现为「点了没反应」。
    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            // 这行是排查「导出点了没反应」的分水岭：
            // 有它 → 页面确实触发了下载，问题在宿主的目的地/落盘；
            // 没它 → 点击根本没走到 WebKit，问题在页面/脚本侧。
            LobbyLog.info("[download] shouldPerformDownload url=%@", navigationAction.request.url?.absoluteString ?? "?")
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    /// 兜住「响应本身无法在页面里显示」的下载（未知 MIME / 附件）。
    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            LobbyLog.info("[download] canShowMIMEType=false url=%@", navigationResponse.response.url?.absoluteString ?? "?")
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView,
                        navigationAction: WKNavigationAction,
                        didBecome download: WKDownload) {
        attachDownloadDelegate(to: download,
                               suggestedName: navigationAction.request.url?.lastPathComponent ?? "")
    }

    public func webView(_ webView: WKWebView,
                        navigationResponse: WKNavigationResponse,
                        didBecome download: WKDownload) {
        attachDownloadDelegate(to: download,
                               suggestedName: navigationResponse.response.url?.lastPathComponent ?? "")
    }

    /// `WKDownload.delegate` 是**弱引用**：不自己持有的话，下载还没落盘代理就没了。
    private func attachDownloadDelegate(to download: WKDownload, suggestedName: String) {
        let sink = ScriptDownloadSink(fallbackName: suggestedName) { [weak self] identifier in
            self?.activeDownloads.removeValue(forKey: identifier)
        }
        activeDownloads[ObjectIdentifier(download)] = sink
        download.delegate = sink
    }
}

/// 把 WebKit 的下载落到系统「下载」目录。
///
/// 只做「挑位置 + 记账」：内容由 WebKit 流式写盘，因此大文件也不会在内存里过一遍。
private final class ScriptDownloadSink: NSObject, WKDownloadDelegate {
    private let fallbackName: String
    private let onFinish: (ObjectIdentifier) -> Void
    /// WebKit 拿到目的地之后才落盘，这中间路径是被预约的，结束必须释放。
    private var destination: URL?

    init(fallbackName: String, onFinish: @escaping (ObjectIdentifier) -> Void) {
        self.fallbackName = fallbackName
        self.onFinish = onFinish
    }

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        // suggestedFilename 来自锚点的 download 属性（脚本自己定的名字），
        // 拿不到时才退回响应里的文件名。
        let preferred = suggestedFilename.isEmpty ? fallbackName : suggestedFilename
        let mimeType = response.mimeType ?? "application/octet-stream"
        guard let destination = DownloadStore.destinationURL(preferredName: preferred, mimeType: mimeType) else {
            LobbyLog.warn("[download] no writable destination for: %@", preferred)
            completionHandler(nil)
            return
        }
        self.destination = destination
        LobbyLog.info("[download] webkit download -> %@", destination.path)
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        LobbyLog.info("[download] webkit download finished")
        finish(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        LobbyLog.error("[download] webkit download failed: %@", error.localizedDescription)
        finish(download)
    }

    private func finish(_ download: WKDownload) {
        if let destination { DownloadStore.release(destination: destination) }
        destination = nil
        onFinish(ObjectIdentifier(download))
    }
}

// MARK: - WKScriptMessageHandler

extension GameViewportInstance: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer {
            let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            if ms >= Self.slowMainWorkThreshold * 1000 {
                let kind = (message.body as? [String: Any])?["type"] as? String ?? "?"
                LobbyLog.warn("[instance] slow main work: script message '%@' took %.0f ms", kind, ms)
            }
        }
        guard message.name == LobbyConfiguration.webChannelName,
              let body = message.body as? [String: Any] else { return }
        handle(pageEvent: PageEvent.decode(from: body))
    }
}
