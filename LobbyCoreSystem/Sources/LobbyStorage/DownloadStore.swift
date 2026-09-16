import Foundation
import LobbyDomain

/// 页面导出的落盘目标。
///
/// 背景：WKWebView **不实现 HTML 的 `download` 属性**。第三方脚本的导出普遍是
/// `Blob` + 脱离文档的 `a.click()`（脚本里那句 `/storage/emulated/0/Download/`
/// 只是它自己硬编码的提示文案，跟真实路径无关）。页面侧的下载垫片把内容经
/// `type: 'download'` 事件交回这里，由原生写进**系统「下载」目录**。
///
/// 文件名来自第三方脚本，按不可信输入处理：剥掉路径分隔符与 `..`，限制长度，
/// 缺扩展名时按 MIME 补一个，重名自动追加 `-2`、`-3`…（与脚本导入同策略）。
public enum DownloadStore {
    /// 单文件上限：与页面侧 `MAX_EXPORT_BYTES` 保持一致（32 MB）。
    public static let maximumBytes = 32 * 1024 * 1024

    /// 系统「下载」目录。本 App 未启用沙盒（`CODE_SIGN_IDENTITY = "-"`、无
    /// entitlements），因此这里拿到的是真实的 ~/Downloads。
    public static var directory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
    }

    /// WebKit 自己写盘时的目的地。
    ///
    /// `WKDownloadDelegate.download(_:decideDestinationUsing:suggestedFilename:completionHandler:)`
    /// 只负责**挑一个位置**，文件由 WebKit 落盘。这里复用同一套净化 + 去重规则，
    /// 传出去的必须是一个尚不存在的路径（已存在 WebKit 会直接覆盖）。
    ///
    /// 注意这是「先问后写」：WebKit 拿到路径之后才真正落盘，中间有窗口。所以同一个
    /// 目的地会被**预约**下来，等下载结束（成功或失败）再释放 —— 否则同一批导出里
    /// 两次同名会拿到同一个路径，后者把前者覆盖掉。
    public static func destinationURL(preferredName: String, mimeType: String) -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            LobbyLog.error("[download] cannot create downloads directory: %@", error.localizedDescription)
            return nil
        }
        let target = uniqueURL(for: sanitizedName(preferredName, mimeType: mimeType))
        reserve(target)
        return target
    }

    /// 释放 `destinationURL` 的预约。下载结束（成功或失败）都必须调用。
    public static func release(destination: URL) {
        reservationLock.lock()
        defer { reservationLock.unlock() }
        reservations.remove(destination.path)
    }

    /// 写入 base64 内容，返回最终落盘路径；失败返回 nil（原因已记日志）。
    @discardableResult
    public static func write(base64: String, preferredName: String, mimeType: String) -> URL? {
        // base64 体积约为原文 4/3，先按编码后长度粗筛，避免无谓解码。
        guard base64.utf8.count <= (maximumBytes / 3 + 1) * 4 else {
            LobbyLog.warn("[download] rejected oversized payload: %@", preferredName)
            return nil
        }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            LobbyLog.warn("[download] invalid base64 payload: %@", preferredName)
            return nil
        }
        guard data.count <= maximumBytes else {
            LobbyLog.warn("[download] rejected oversized payload (%ld bytes): %@", data.count, preferredName)
            return nil
        }
        return write(data: data, preferredName: preferredName, mimeType: mimeType)
    }

    /// 写入 Data，返回最终落盘路径。
    @discardableResult
    public static func write(data: Data, preferredName: String, mimeType: String) -> URL? {
        guard data.count <= maximumBytes else {
            LobbyLog.warn("[download] rejected oversized payload (%ld bytes): %@", data.count, preferredName)
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = uniqueURL(for: sanitizedName(preferredName, mimeType: mimeType))
            // 并发写同一文件名时避免两个调用挑到同一个路径（后者覆盖前者）。
            reserve(target)
            defer { release(destination: target) }
            try data.write(to: target, options: .atomic)
            LobbyLog.info("[download] saved %ld bytes -> %@", data.count, target.path)
            return target
        } catch {
            LobbyLog.error("[download] write failed for %@: %@", preferredName, error.localizedDescription)
            return nil
        }
    }

    /// 把已下载好的临时文件移入下载目录，返回最终路径。
    @discardableResult
    public static func adopt(temporaryFile: URL, preferredName: String, mimeType: String) -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = uniqueURL(for: sanitizedName(preferredName, mimeType: mimeType))
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: temporaryFile, to: target)
            LobbyLog.info("[download] saved -> %@", target.path)
            return target
        } catch {
            LobbyLog.error("[download] adopt failed for %@: %@", preferredName, error.localizedDescription)
            return nil
        }
    }

    // MARK: - 私有实现

    // 已发出但尚未落盘的目的地。见 `destinationURL` 的说明。
    private static let reservationLock = NSLock()
    nonisolated(unsafe) private static var reservations: Set<String> = []

    private static func reserve(_ url: URL) {
        reservationLock.lock()
        defer { reservationLock.unlock() }
        reservations.insert(url.path)
    }

    /// 文件已存在，或已被某个在途下载预约。
    private static func isTaken(_ url: URL) -> Bool {
        reservationLock.lock()
        let reserved = reservations.contains(url.path)
        reservationLock.unlock()
        if reserved { return true }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 文件名净化：第三方脚本可以直接给 `../../x`，必须当不可信输入处理。
    private static func sanitizedName(_ name: String, mimeType: String) -> String {
        // 只取最后一段，剥掉路径分隔符与 Windows 盘符
        var candidate = name.replacingOccurrences(of: "\\", with: "/")
        candidate = (candidate as NSString).lastPathComponent
        candidate = candidate.replacingOccurrences(of: ":", with: "-")
        // 去掉控制字符与前后空白/点（`.`、`..`、`.hidden` 一律退化）
        candidate = candidate.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if candidate.isEmpty { candidate = "download" }
        if candidate.count > 120 { candidate = String(candidate.prefix(120)) }
        if (candidate as NSString).pathExtension.isEmpty {
            candidate += extensionFor(mimeType: mimeType)
        }
        return candidate
    }

    /// 无扩展名时按 MIME 补一个，让文件能双击打开。
    private static func extensionFor(mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png": return ".png"
        case "image/jpeg": return ".jpg"
        case "image/gif": return ".gif"
        case "image/webp": return ".webp"
        case "application/json": return ".json"
        case "text/csv": return ".csv"
        case "text/html": return ".html"
        case "text/plain": return ".txt"
        default: return ""
        }
    }

    /// 同名自动改名：`name-2.ext`、`name-3.ext` …… 与脚本导入同策略。
    private static func uniqueURL(for fileName: String) -> URL {
        let initial = directory.appendingPathComponent(fileName)
        guard !isTaken(initial) else {
            return advancedURL(for: fileName)
        }
        return initial
    }

    private static func advancedURL(for fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        for counter in 2...999 {
            let candidate = ext.isEmpty
                ? "\(base)-\(counter)"
                : "\(base)-\(counter).\(ext)"
            let url = directory.appendingPathComponent(candidate)
            if !isTaken(url) { return url }
        }
        return directory.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8))\(ext.isEmpty ? "" : ".\(ext)")")
    }
}
