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

    private let authenticator: GameAuthenticating
    private let resources: ResourceProviding
    private let settingsMirror: GameSettingsMirror
    private var schemeHandler: GameResourceSchemeHandler!
    private lazy var webView: WKWebView = makeWebView()
    private var hsdkResponder: HSDKResponder?

    private let loadingOverlay = NSView()
    private let loadingSpinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "正在准备游戏资源…")
    private var gameSessionStarted = false
    private var startupTask: Task<Void, Never>?
    private var storageSyncTask: Task<Void, Never>?
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
                enhancements: GameEnhancementStore? = nil) {
        self.account = account
        self.environment = environment
        self.authenticator = authenticator
        self.resources = resources
        self.settingsMirror = settingsMirror
        self.sync = sync
        self.scripts = scripts
        self.enhancements = enhancements
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

    /// 下发游戏加强设置（十殿加速开关 + 倍率）。幂等，可重复调用。
    /// 两条触发路径：① 文档就绪时补一次（代理已在 atDocumentStart 装好，
    /// 此刻只差配置）；② 用户在设置页改档，由会话模型广播到全部存活实例。
    public func applyEnhancements() {
        guard let enhancements else { return }
        let settings = enhancements.settings
        let script = GameEnhancementScript.apply(enabled: settings.nightmareSpeedEnabled,
                                                speed: settings.nightmareSpeedMultiplier)
        webView.evaluateJavaScript(script) { result, error in
            if let error {
                LobbyLog.warn("[instance] enhancement apply failed: %@", error.localizedDescription)
            } else {
                // 诊断串形如 `running=1 speed=100 hook=1 panel=1 note=running-live`。
                // no-handler = 代理脚本没进页面（构建产物未更新）。
                LobbyLog.info("[instance] enhancement apply -> %@",
                              (result as? String) ?? String(describing: result))
            }
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
            instanceCount: instanceCount
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
        case .error(let message):
            LobbyLog.error("[instance] JS error: %@", message)
        case .ready(let readiness):
            // 启动沉降完成：释放启动槽位。多开时靠这个把「N 个实例同时抢
            // I/O 和 GPU」变成排队通过。
            LobbyLog.info("[instance] ready: elapsed=%ldms stable=%@",
                          readiness.elapsedMs, readiness.stable ? "yes" : "no")
            pool?.noteInstanceReady(accountID: account.id)
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
        case .unknown(let type):
            LobbyLog.debug("[instance] page event: %@", type)
        }
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
