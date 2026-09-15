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
    }
}
