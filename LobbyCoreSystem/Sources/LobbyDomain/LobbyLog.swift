import Foundation
import OSLog

/// 统一日志门面（LobbyDomain 层，全模块可用）：os.Logger 落统一子系统，
/// 等级过滤走 UserDefaults，可用
/// `defaults write com.xyzw.gamelobby.macos lobby.log.level -int 0`（verbose）
/// 临时放开排查，无需重新编译。
public enum LobbyLog {
    public static let subsystem = "com.xyzw.gamelobby.macos"

    private static let logger = Logger(subsystem: subsystem, category: "lobby")

    public enum Level: Int, Comparable, CaseIterable, Sendable {
        case verbose = 0
        case debug = 1
        case info = 2
        case warn = 3
        case error = 4

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        public var label: String {
            switch self {
            case .verbose: return "verbose"
            case .debug: return "debug"
            case .info: return "info"
            case .warn: return "warn"
            case .error: return "error"
            }
        }
    }

    /// 当前生效的最低输出等级。
    public static var minimumLevel: Level {
        let stored = UserDefaults.standard.integer(forKey: LobbyConfiguration.PreferenceKey.logLevel)
        return Level(rawValue: stored) ?? .info
    }

    public static func verbose(_ format: String, _ args: Any...) { log(.verbose, format, args) }
    public static func debug(_ format: String, _ args: Any...) { log(.debug, format, args) }
    public static func info(_ format: String, _ args: Any...) { log(.info, format, args) }
    public static func warn(_ format: String, _ args: Any...) { log(.warn, format, args) }
    public static func error(_ format: String, _ args: Any...) { log(.error, format, args) }

    public static func isEnabled(_ level: Level) -> Bool { level >= minimumLevel }

    private static func log(_ level: Level, _ format: String, _ args: [Any]) {
        guard isEnabled(level) else { return }
        let filled = String(format: format, arguments: args.map { box($0) })
        let payload = "[lobby-macos] \(filled)"
        switch level {
        case .verbose, .debug: logger.debug("\(payload, privacy: .public)")
        case .info: logger.info("\(payload, privacy: .public)")
        case .warn: logger.warning("\(payload, privacy: .public)")
        case .error: logger.error("\(payload, privacy: .public)")
        }
    }

    /// 保留参数的原始类型再喂给 String(format:)。
    /// ⚠️ 不能先 String(describing:) 全部转字符串：Foundation 的新格式校验
    /// 会因「%@/%ld 混用 + 全 String 参数」直接抛
    /// NSCocoaErrorDomain 2048，且 %ld 读到 String 盒子会打出指针乱码。
    private static func box(_ value: Any) -> CVarArg {
        switch value {
        case let text as String: return text
        case let number as Int: return number
        case let number as Int32: return number
        case let number as Int64: return number
        case let number as UInt: return number
        case let number as UInt64: return number
        case let number as Double: return number
        case let number as Bool: return number
        case let number as NSNumber: return number
        default: return String(describing: value)
        }
    }
}
