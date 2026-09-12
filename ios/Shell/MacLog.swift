import Foundation

/// 日志等级：数字越大越啰嗦。设置页的「日志等级」选的就是它——
/// 选了某档 = 该档及其以上（更严重）的都打，更啰嗦的直接丢掉。
///
/// 分档口径（改造时按此归类，别凭感觉）：
/// - `error` 真出错：登录失败、JS 异常、CDN 同步失败——任何等级都必须看得见。
/// - `warn` 可疑但不致命：资源 404、脚本读不出来、回退到旧数据。
/// - `info` 一次生命周期里只看一次的节点：登录开始/结束、文档加载完成、缓存清理。
/// - `debug` 排查时才需要的过程量：预取进度、帧率回写、HSDK 单次请求。
/// - `verbose` **每个资源一条**的流水：CDN 命中/下载、URL 重写——多开时是刷屏主因。
enum MacLogLevel: Int, CaseIterable, Identifiable, Comparable, Sendable {
    case error = 0
    case warn = 1
    case info = 2
    case debug = 3
    case verbose = 4

    /// 默认等级：只保留能看懂流程的节点。
    ///
    /// 改动前所有 `NSLog` 无条件打印，等价于常开 `verbose`；默认收到 `info`
    /// 之后，多开时最吵的 CDN 流水与页面 console 就不再进控制台。
    static let fallback: MacLogLevel = .info

    static func < (lhs: MacLogLevel, rhs: MacLogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var id: Int { rawValue }

    /// 设置页分段胶囊上的短标签（两字，窄侧栏里要放得下五档）。
    var label: String {
        switch self {
        case .error: return "错误"
        case .warn: return "警告"
        case .info: return "信息"
        case .debug: return "调试"
        case .verbose: return "详尽"
        }
    }

    /// 打在每行日志最前面的单字母标记，方便在 Xcode 控制台里肉眼筛。
    var tag: String {
        switch self {
        case .error: return "E"
        case .warn: return "W"
        case .info: return "I"
        case .debug: return "D"
        case .verbose: return "V"
        }
    }

    /// 设置页里跟在分段控件下面的说明，说清这一档会多放出什么。
    var summary: String {
        switch self {
        case .error: return "只留真出错的：登录失败、JS 异常、缓存同步失败"
        case .warn: return "加上可疑但能自愈的：资源 404、脚本读不出来、回退旧数据"
        case .info: return "再加上生命周期节点：登录完成、文档加载、缓存清理（推荐）"
        case .debug: return "再加上排查过程量：预取进度、帧率回写、HSDK 单次请求"
        case .verbose: return "每个资源一条的流水：CDN 命中 / 下载、URL 重写，多开时会刷屏"
        }
    }

    var accessibilityLabel: String { "日志等级：\(label)" }

    /// 从持久化值读当前档位，缺失或非法值（含旧版本留下的超范围值）回退默认档。
    static func current() -> MacLogLevel {
        let defaults = UserDefaults.standard
        // 缺键时 integer(forKey:) 返回 0 = .error，会把日志砍到只剩错误，
        // 所以这里必须用 object(forKey:) 区分「没存过」和「存了 0」。
        guard let stored = defaults.object(forKey: MacLogSettings.levelDefaultsKey) as? Int,
              let level = MacLogLevel(rawValue: stored) else { return fallback }
        return level
    }

    /// 页面 console 方法名 → 等级（原生回传的 `level` 字段就是这个字符串）。
    /// 认不出来的（自定义 level）按 `info` 处理，宁可多打也别把错误吞了。
    static func level(forJSLevel name: String?) -> MacLogLevel {
        switch name {
        case "error": return .error
        case "warn", "warning": return .warn
        case "debug", "trace": return .debug
        case "verbose": return .verbose
        default: return .info
        }
    }
}

/// 日志开关的单一真源：UserDefaults 是持久化落点，这里缓存一份供高频判定。
///
/// **为什么要缓存**：日志调用分散在 CDN 下载、WebKit 消息回调这类高频路径上，
/// 每次 `UserDefaults.standard.object(forKey:)` 都要走一遍 CFPreferences 查询，
/// 比最后那次 NSLog 本身还贵。缓存之后判定退化成「加锁读一个 Int」，
/// 关掉日志时连字符串格式化都不会发生（见 `MacLog.emit`）。
final class MacLogSettings: @unchecked Sendable {
    static let shared = MacLogSettings()

    /// 总开关：关 = 一切都不打（页面 console 也不再跨进程回传）。
    static let enabledDefaultsKey = "ios2.logEnabled"
    /// 等级：见 `MacLogLevel`，存 rawValue。
    static let levelDefaultsKey = "ios2.logLevel"
    /// 是否把页面里的 console 输出回传到原生（macOS 多开时这是最大的一块开销）。
    static let jsConsoleDefaultsKey = "ios2.logJSConsole"

    private let lock = NSLock()
    /// -1 = 总开关关闭（什么都不打）；否则 = 允许输出的最大等级 rawValue。
    private var threshold: Int
    private var level: MacLogLevel
    private var forwardsJSConsole: Bool

    init() {
        let defaults = UserDefaults.standard
        // 总开关默认开：不然新装用户遇到问题时一条日志都没有，无从下手。
        let enabled = defaults.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
        // 页面 console 默认关：游戏页（cocos2d + HSDK）动辄上百条 console.log，
        // 每条都要跨进程回传一次，多开时是最主要的一块开销；真要排查再打开。
        let jsConsole = defaults.object(forKey: Self.jsConsoleDefaultsKey) as? Bool ?? false
        let level = MacLogLevel.current()
        self.level = level
        self.threshold = enabled ? level.rawValue : -1
        self.forwardsJSConsole = jsConsole
    }

    /// 总开关是否打开（设置页与启动横幅用）。
    var isEnabled: Bool { lock.withLock { threshold >= 0 } }

    /// 当前等级（设置页用）。
    var currentLevel: MacLogLevel { lock.withLock { level } }

    /// 是否回传页面 console（设置页用）。
    var forwardsJSConsoleEnabled: Bool { lock.withLock { forwardsJSConsole } }

    /// 该等级的日志现在会不会真的打出来。
    ///
    /// 除了判定，还用来**挡住昂贵的实参**：`Self.sha256(data)` 这类比 NSLog 还贵
    /// 的计算，必须先在调用点问一次，否则「关掉日志」只省了打印、没省计算。
    func allows(_ level: MacLogLevel) -> Bool { lock.withLock { threshold >= level.rawValue } }

    /// 从 UserDefaults 重读并刷新缓存。设置面板改动、以及启动时各调一次。
    func reload() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
        let jsConsole = defaults.object(forKey: Self.jsConsoleDefaultsKey) as? Bool ?? false
        let level = MacLogLevel.current()
        lock.withLock {
            self.level = level
            self.threshold = enabled ? level.rawValue : -1
            self.forwardsJSConsole = jsConsole
        }
    }
}

/// 带等级的日志出口。替换散落各处的裸 `NSLog`：打印前先过一遍等级，
/// 不通过就直接返回——不拼字符串、不进 NSLog、不触发任何格式化。
///
/// 两种签名：
/// - `MacLog.info("纯文本")`——走 `NSLog("%@", …)`，文本里有 `%` 也不会被当格式串。
/// - `MacLog.info("…%@…", arg)`——沿用 NSLog 的 printf 格式串。
enum MacLog {
    static func error(_ message: String) { emit(.error, message) }
    static func warn(_ message: String) { emit(.warn, message) }
    static func info(_ message: String) { emit(.info, message) }
    static func debug(_ message: String) { emit(.debug, message) }
    static func verbose(_ message: String) { emit(.verbose, message) }

    static func error(_ format: String, _ args: CVarArg...) { emit(.error, format, args) }
    static func warn(_ format: String, _ args: CVarArg...) { emit(.warn, format, args) }
    static func info(_ format: String, _ args: CVarArg...) { emit(.info, format, args) }
    static func debug(_ format: String, _ args: CVarArg...) { emit(.debug, format, args) }
    static func verbose(_ format: String, _ args: CVarArg...) { emit(.verbose, format, args) }

    /// 等级由运行时决定时用（例如页面回传的 console 消息）。
    static func log(_ level: MacLogLevel, _ format: String, _ args: CVarArg...) {
        emit(level, format, args)
    }

    /// 昂贵的实参要先问一次再用，别白算。
    static func isEnabled(_ level: MacLogLevel) -> Bool { MacLogSettings.shared.allows(level) }

    // MARK: - 内部

    private static func emit(_ level: MacLogLevel, _ message: String) {
        guard MacLogSettings.shared.allows(level) else { return }
        withVaList([message]) { NSLogv("[\(level.tag)] %@", $0) }
    }

    private static func emit(_ level: MacLogLevel, _ format: String, _ args: [CVarArg]) {
        guard MacLogSettings.shared.allows(level) else { return }
        withVaList(args) { NSLogv("[\(level.tag)] " + format, $0) }
    }
}

#if os(macOS)
extension MacLogSettings {
    /// 注入到游戏页面的日志配置（放在 bootstrap 脚本最前面，`atDocumentStart`）。
    ///
    /// 页面里的 console 代理每次调用都读它决定要不要 `postMessage`：
    /// 关掉之后页面的 console 调用只剩一次属性读取，**一次 IPC 都不会发生**。
    /// 打成字面量而不是运行时查询，就是为了省掉每次日志一次跨进程往返。
    var bootstrapScript: String {
        """
        window.__IOS2_LOG__ = { enabled: \(isEnabled), level: \(currentLevel.rawValue), jsConsole: \(forwardsJSConsoleEnabled) };
        """
    }

    /// 运行时改写（设置面板改动后广播给活着的实例）——与 bootstrap 同构，
    /// 只是执行时机不同（一个随文档注入，一个由 `evaluateJavaScript` 写入）。
    var updateScript: String { bootstrapScript }

    /// 把当前设置广播给所有存活实例：不必重启游戏窗口就能生效。
    @MainActor
    func applyToRunningInstances() {
        let script = updateScript
        let accountIDs = MacGameInstanceRegistry.shared.liveAccountIDs()
        for accountID in accountIDs {
            MacGameInstanceRegistry.shared.evaluate(script, accountID: accountID)
        }
        MacLog.info("[ios2-macos] log settings applied to %ld instance(s): enabled=%@ level=%@ jsConsole=%@",
                    accountIDs.count,
                    isEnabled ? "yes" : "no",
                    currentLevel.label,
                    forwardsJSConsoleEnabled ? "yes" : "no")
    }
}

/// 页面 console 代理：按原生下发的等级过滤，超档的直接放过（不回传）。
///
/// **为什么在 JS 侧就滤掉**：`postMessage` 是一次跨进程序列化 + 原生侧
/// `userContentController` 回调，单条就要几十微秒；游戏页（cocos2d / HSDK）
/// 启动一轮能打上百条，多开时全部堆在主线程上，直接吃掉帧率。
/// 在页面侧判定后，被滤掉的日志连序列化都不会发生。
///
/// 始终保留 `original.apply`：关掉回传只是不再往原生送，Safari Web Inspector
/// 里照样能看到完整输出，排查时不用改设置。
enum MacLogConsoleBridge {
    static let script = """
    (function() {
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ios2Game;
      if (!bridge) return;
      var RANK = { error: 0, warn: 1, log: 2, info: 2, debug: 3, trace: 3 };
      ['error', 'warn', 'log', 'info', 'debug'].forEach(function(level) {
        var original = console[level];
        if (typeof original !== 'function') return;
        console[level] = function() {
          var cfg = window.__IOS2_LOG__ || {};
          var max = typeof cfg.level === 'number' ? cfg.level : 2;
          var rank = RANK[level] === undefined ? 2 : RANK[level];
          if (!cfg.enabled || !cfg.jsConsole || rank > max) return original.apply(console, arguments);
          var args = Array.prototype.slice.call(arguments);
          try {
            bridge.postMessage({
              type: 'console',
              level: level,
              instance: window.__IOS2_GAME_INSTANCE__ ? window.__IOS2_GAME_INSTANCE__.id : '',
              message: args.map(function(value) { return String((value && value.stack) || value); }).join(' ')
            });
          } catch (ignored) {}
          return original.apply(console, arguments);
        };
      });
    })();
    """
}
#endif
