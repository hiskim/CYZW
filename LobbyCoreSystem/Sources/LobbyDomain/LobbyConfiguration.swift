import Foundation

/// 全局配置：服务器地址、自定义协议、页面桥契约、文件系统位置与用户偏好键。
///
/// 页面桥契约说明：`webChannelName` / `instanceGlobalName` / `identityPrefix`
/// 是 WebRuntime 页面侧（`ios2-web-boot.js` 等，随游戏 bundle 分发）**硬编码的
/// 外部契约**，不属于本工程的命名规范约束——它们必须与页面侧逐字节一致，
/// 否则事件上报、启动参数与账号身份会全部静默失效。集中声明在此，禁止散落
/// 成魔法字符串。
public enum LobbyConfiguration {
    // MARK: - 网络端点

    /// 游戏认证 / 清单服务器。
    public static let gameServerURL = URL(string: "https://xxz-xyzw.hortorgames.com")!

    /// 游戏静态资源 CDN。
    public static let resourceBaseURL = URL(string: "https://xxz-xyzw-res.hortorgames.com")!

    /// 资源清单请求版本（与游戏服务端约定的 platform 版本号）。
    public static let manifestVersion = "0.33.0-ios"

    /// 启动期预热的核心 bundle（完整清单预取在阶段 2 扩展）。
    public static let coreBundles = ["launcher", "game", "TEST_REMOTE_MODULE", "main"]

    /// HSDK 上报的游戏标识与 SDK 版本。
    public static let gameID = "xyzw_mix"
    public static let hortorSDKVersion = "1.4.0"

    // MARK: - 服务端资料查询（不启动游戏，直接用 .bin 凭据问服务端）
    //
    // 链路与实测数据见 `.workbuddy/tools/ws-profile-probe/README.md`。
    // 这三项都是**服务端契约**，与助手仓共用同一套值，改则静默失效。

    /// `/login/authuser` 的路径与查询串。
    /// ⚠️ 与 `AccountAuthenticator` 打的是同一个端点（那边把响应原样交给页面，
    /// 这边要自己解出 roleToken）。改端点时两处一起改。
    public static let profileAuthUserPath = "/login/authuser?_seq=1"

    /// `/login/serverlist` 的路径与查询串：`POST` 该 `.bin` 原字节 →
    /// `{ areaList, serverList, roleCount, recommendId, roles }`。
    /// `roles` 里每项含 `roleId` / `serverId` / `name`，是「选服选角色」的唯一数据源。
    /// ⚠️ 它的 `power` 对非当前角色不可信（`level` 恒为 1），只用来取列表与名字；
    /// `roleId` 是可信的（可与 WSS `role_getroleinfo` 逐字段对上）。
    public static let profileServerListPath = "/login/serverlist?_seq=3"

    /// 凭据/请求体的编码方案标记头。**值必须与实际字节一致，或者干脆不发**——
    /// 实测「`x` 编码的体 + `lx` 头」会被服务端直接拒（无 roleToken）。
    public static let payloadEncodingHeaderName = "O4e-Encoding"

    /// `.bin`（`lx` = LZ4 帧 + 头部掩码）对应的标记值。
    public static let payloadEncodingLX = "lx"


    /// 资料查询用的 WebSocket 端点。**从 `gameServerURL` 派生**（只换 scheme 与路径），
    /// 免得主机名在两处各写一遍、换服时漏改一处。
    public static let profileWebSocketBaseURL: URL = {
        var components = URLComponents(url: gameServerURL, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        components.scheme = "wss"
        components.path = "/agent"
        components.query = nil
        return components.url ?? gameServerURL
    }()

    /// `role_getroleinfo` 请求体里的客户端版本（助手仓里的同名字段）。
    public static let profileClientVersion = "2.10.3-f10a39eaa0c409f4-wx"

    // MARK: - 页面桥契约（外部约束，勿改）

    /// 自定义 URL 方案。规格书写的是 `game-res`，但 WebRuntime 页面侧
    /// （ios2-web-index.html 的 script 标签、ios2-web-boot.js 的
    /// `settings.server = 'ios2-game://app/cdn'`、资源 bundle URL 与 URL 白名单
    /// 正则）**全链路硬编码 `ios2-game://`**——改方案名 = 子资源全部加载失败 =
    /// 黑屏。因此方案名同样是页面桥契约，必须与页面逐字节一致。
    public static let gameURLScheme = "ios2-game"

    /// WKScriptMessageHandler 通道名——页面侧写死 `webkit.messageHandlers.ios2Game`。
    public static let webChannelName = "ios2Game"

    /// 注入页面的实例全局对象名——页面侧写死读取 `__IOS2_GAME_INSTANCE__`。
    public static let instanceGlobalName = "__IOS2_GAME_INSTANCE__"

    /// SDK 身份前缀：账号 ID = 前缀 + bin 内容 SHA256。与上一代宿主保持一致，
    /// 使同一份凭据在游戏侧的 SDK 身份（distinctId / userId）完全稳定。
    public static let identityPrefix = "ios2-"

    /// HSDK 桥的类/方法对（jsb.reflection.callStaticMethod 路由白名单）。
    public static let hsdkBridgeClasses: Set<String> = [
        "SDKMessager",
        "com/hortorgames/gamesdk/SDKBridge"
    ]

    // MARK: - 文件系统

    /// Application Support 根（不存在时兜底 Caches）。
    public static var applicationSupportDirectory: URL {
        let manager = FileManager.default
        if let url = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return url
        }
        let library = manager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library.appendingPathComponent("Application Support", isDirectory: true)
    }

    /// .bin 账号文件目录：`Application Support/AccountBins`。
    /// 刻意与上一代宿主同路径——用户已导入的账号在新大厅里开箱即用。
    public static var accountBinsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("AccountBins", isDirectory: true)
    }

    /// 本宿主私有数据目录：`Application Support/GameLobby`。
    public static var lobbySupportDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("GameLobby", isDirectory: true)
    }

    /// 游戏内设置原生镜像目录：`Application Support/GameStorage`。
    /// 与上一代宿主同路径：已保存的游戏内配置（音量、省电模式等）直接延续。
    public static var gameSettingsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("GameStorage", isDirectory: true)
    }

    /// CDN 磁盘缓存目录：`Application Support/GameLobby/CDN`。
    public static var cdnCacheDirectory: URL {
        lobbySupportDirectory.appendingPathComponent("CDN", isDirectory: true)
    }

    /// JS 脚本目录：`Application Support/IOS2Scripts`。
    /// 与上一代宿主同路径（同为用户数据，与 AccountBins/GameStorage 同策略）——
    /// 旧大厅已导入的脚本在新大厅开箱即用。
    public static var scriptsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("IOS2Scripts", isDirectory: true)
    }

    /// WebKit 游戏运行时（引擎壳工程）在主资源包内的位置。
    public static var webRuntimeRoot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("WebRuntime", isDirectory: true)
    }

    // MARK: - 用户偏好键（UserDefaults）

    public enum PreferenceKey {
        /// 游戏内存储策略（GameStoragePolicy 原始值）。
        public static let storagePolicy = "lobby.gameStorage.policy"
        /// 渲染画质档位（RenderQuality 原始值）。
        public static let renderQuality = "lobby.renderQuality"
        /// 目标帧率（TargetFrameRate 原始值）。
        public static let frameRate = "lobby.frameRate"
        /// 非焦点实例是否静音（默认 true）。
        public static let muteWhenUnfocused = "lobby.audio.muteWhenUnfocused"
        /// CDN 自动缓存（默认 true）。
        public static let cdnAutomaticCaching = "lobby.cdn.automaticCaching"
        /// Safari Web Inspector 调试开关（默认 false）。
        public static let webInspector = "lobby.debug.webInspector"
        /// 日志等级（Int，0=verbose…3=error；默认 info）。
        public static let logLevel = "lobby.log.level"
        /// JS 脚本引擎总开关（默认 true）。
        public static let scriptsGlobalEnabled = "lobby.scripts.globalEnabled"
        /// 多开全局门禁（默认 false，防误操作多开注入）。
        public static let scriptsMultiGate = "lobby.scripts.multiGate"
        /// 脚本状态记录（JSON Data）。
        public static let scriptsRecords = "lobby.scripts.records"

        // 游戏加强（十殿加速 / UI 加速 / 聊天窗口）
        /// 十殿加速开关（默认 false，防误开）。
        public static let enhanceNightmareSpeedEnabled = "lobby.enhance.nightmareSpeed.enabled"
        /// 十殿加速倍率（Int，1...1000；默认 100）。
        public static let enhanceNightmareSpeedMultiplier = "lobby.enhance.nightmareSpeed.multiplier"
        /// UI 加速开关（引擎全局时间倍率，默认 false，防误开）。
        public static let enhanceUISpeedEnabled = "lobby.enhance.uiSpeed.enabled"
        /// UI 加速倍率（Double，1...10、0.5 步进；默认 3，与官方 APK 运行时的默认档一致）。
        public static let enhanceUISpeedMultiplier = "lobby.enhance.uiSpeed.multiplier"
        /// 实例画面左上角显示实测帧率角标（默认 false）。
        public static let enhanceFPSDisplay = "lobby.enhance.fpsDisplay.enabled"
        /// 战斗数据浮层：血条上方显示 攻/盾/血，怒气条下方显示 怒（默认 false）。
        public static let enhanceBattleStats = "lobby.enhance.battleStats.enabled"
        /// 隐藏游戏内聊天窗口（默认 false = 保持游戏原样的显示）。
        public static let enhanceChatHidden = "lobby.enhance.chat.hidden"
    }
}
