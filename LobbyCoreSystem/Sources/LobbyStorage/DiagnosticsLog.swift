import Foundation
import LobbyDomain
import OSLog

// MARK: - 排查用诊断日志（落盘）
//
// 为什么要有它：登录链路出问题时**界面只是空着**，关键判据全在页面侧与控制台里，
// 而控制台输出「贴给谁看」这件事本身很脆——会话日志动辄几千行，粘贴经常正好把
// 出问题的最后几十行截掉（已经发生过两次，白跑两轮）。
//
// 所以：把**极少数几条**关键行同时落一份到
//   `~/Library/Application Support/GameLobby/diagnostics.log`
// 排查者可以直接读文件，不需要用户从控制台里挑行粘贴。
//
// 只记「登录链路」的事件，不接通用日志——它不是一个日志系统，是一张取证卡片。
public enum DiagnosticsLog {
    /// 单文件上限（超出后只保留尾部一半）。这类文件只服务于一次排查，不需要长期留存。
    private static let sizeLimit = 256 * 1024

    private static let queue = DispatchQueue(label: "com.xyzw.gamelobby.diagnostics")
    private static let logger = Logger(subsystem: LobbyLog.subsystem, category: "diagnostics")

    /// 文件位置（用户排查时可以直接打开）。
    public static var fileURL: URL {
        LobbyConfiguration.lobbySupportDirectory.appendingPathComponent("diagnostics.log")
    }

    /// 追加一行。自带毫秒时间戳；任何 IO 失败都静默（诊断绝不影响主流程）。
    public static func append(_ message: String) {
        queue.async {
            let stamp = Self.timestamp()
            let line = "[\(stamp)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let manager = FileManager.default
            do {
                try manager.createDirectory(at: LobbyConfiguration.lobbySupportDirectory,
                                            withIntermediateDirectories: true)
                if !manager.fileExists(atPath: fileURL.path) {
                    // 首次创建时写一行头，避免看到一份没有上下文的文件。
                    let header = "# Lobby 登录链路诊断（每次启动追加，超过 256KB 只留尾部）\n"
                    try? Data(header.utf8).write(to: fileURL)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try Self.truncateIfNeeded(handle: handle, manager: manager)
            } catch {
                logger.debug("diagnostics append failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 超过上限时只留尾部一半（先截断再继续追加，不会无限增长）。
    private static func truncateIfNeeded(handle: FileHandle, manager: FileManager) throws {
        let size = try handle.offset()
        guard size > UInt64(sizeLimit) else { return }
        let keep = sizeLimit / 2
        let all = try Data(contentsOf: fileURL)
        let tail = all.suffix(keep)
        try Data("# …（已截断，只保留尾部）\n".utf8).write(to: fileURL)
        let rewritten = try FileHandle(forWritingTo: fileURL)
        defer { try? rewritten.close() }
        try rewritten.seekToEnd()
        try rewritten.write(contentsOf: tail)
        _ = manager
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
