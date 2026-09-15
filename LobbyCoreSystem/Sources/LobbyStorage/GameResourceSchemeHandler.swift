import Foundation
import LobbyDomain
import WebKit

// MARK: - game-res:// 方案处理器
//
// 游戏页面的所有请求都走自定义方案 `game-res://`：
// - host == "app"：优先命中主资源包内的 WebRuntime（引擎壳工程），
//   未命中则代理到 CDN（/remote/...）；
// - host == "cdn"：直接代理到 CDN。
//
// 三条性能 / 正确性红线（均来自真实事故）：
// 1. **WKURLSchemeHandler 是 UI actor**：didReceive* 必须从主 actor 发起。
//    多开时十几个 WebContent 同时完成一批资源，主线程会连续执行十几次大 Data
//    的 WebKit IPC，一次被堵 260~494ms，正好覆盖 Cocos 的场景切换与纹理装配
//    窗口 → 某个实例的某张贴图晚到被 assembler 静默跳过。全局投递闸门限制
//    「同时在途回传数」，它限制的是真正的 WebKit IPC 压力，不是网络并发。
// 2. **已停止的任务绝不能回调**：WebKit 明确 stop 过的任务再 didReceive /
//    didFinish / didFail 会抛 `NSInternalInconsistencyException`。但也不能按
//    实例粒度一刀切——`stop()` 可能在主文档请求发出前就被调用，一刀切会把
//    主文档拦掉，页面直接白屏。必须精确簿记。
// 3. **永不完成的任务必须主动放弃**：urlSchemeTask 一旦永远不被完成，页面里
//    那个资源就永久挂起——Cocos 的 assembler 会一直 `if (!texture.loaded) return`，
//    表现就是随机缺一块、既不报错也不重试。到点主动 didFail 把「永久挂起」
//    降级成「一次失败」，交给 Cocos 的重试。

/// 主 actor 上的全局回传闸门：两个大数据回传足够保持吞吐，又不会让十个实例
/// 同时压主线程。两批回传之间留一个很短的 RunLoop 缝隙，让 SwiftUI、WebContent
/// 消息和 Cocos 的 rAF 有机会被调度。
@MainActor
final class ResourceDeliveryGate {
    static let shared = ResourceDeliveryGate()

    private static let maxConcurrentDeliveries = 2
    private static let interDeliveryGapNanoseconds: UInt64 = 2_000_000

    private var activeDeliveries = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if activeDeliveries < Self.maxConcurrentDeliveries {
            activeDeliveries += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            activeDeliveries = max(0, activeDeliveries - 1)
            return
        }
        let continuation = waiters.removeFirst()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.interDeliveryGapNanoseconds)
            continuation.resume()
        }
    }
}

public final class GameResourceSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    /// WebRuntime 内路径别名：游戏引用的规范路径 → 主资源包内的实际文件。
    /// （Cocos 构建产物把入口命名成带指纹的文件名，页面仍按规范路径引用。）
    private static let localPathAliases: [String: String] = [
        "/index.html": "src/ios2-web-index.html",
        "/settings.js": "src/settings.b2e22.js",
        "/cocos2d.js": "src/ios2-web-cocos2d.js",
        "/physics.js": "src/ios2-web-physics.js",
        "/boot.js": "src/ios2-web-boot.js",
        "/game-defines.js": "jsb-adapter/game-defines.js"
    ]

    /// bundle 内资源的内存缓存（按绝对路径）。这些文件只读不改，但每次点击都有
    /// 一批请求打进来，命中后连磁盘都不碰。不放进 WebKit 缓存是因为宿主升级后
    /// bundle 内容会变而 URL 不变，交给 WebKit 缓存会用到旧文件。
    private static let localDataCache = NSCache<NSString, NSData>()

    private let resources: ResourceProviding
    private var bundleVersions: [String: String] = [:]

    /// 进行中的 urlSchemeTask（主线程访问）。
    private var pending: [ObjectIdentifier: (url: String, startedAt: Date)] = [:]
    /// task 对象引用：回传结束前必须自己持有。
    private var tasks: [ObjectIdentifier: WKURLSchemeTask] = [:]
    /// WebKit 明确通知过 stop 的任务：迟到的回调必须吞掉。
    private var stoppedTasks: Set<ObjectIdentifier> = []
    /// 已被主动报错收尾的任务：迟到的真实响应必须丢弃（二次回调会抛异常）。
    private var abandonedTasks: Set<ObjectIdentifier> = []
    private var lastStaleReportAt: Date = .distantPast

    /// `stoppedTasks` 上限：WebKit 不主动通知任务结束，只能靠容量兜底。
    /// 一次「一键关全部」就能超过几百条在途任务，不能设小——触发 removeAll 时
    /// 还没回传的任务失去抑制，迟到的 continuation 会打在 stopped 的任务上崩溃。
    private static let stoppedTasksLimit = 8192
    /// 只看不治的告警阈值（秒）。
    private static let pendingStaleAfter: TimeInterval = 20
    /// 主动放弃阈值。45s：game bundle 单包 16.6MB，冷启动 + 落盘确实可能要几十秒，
    /// 砍太短会把正常的大包请求也误杀掉。
    private static let pendingAbandonAfter: TimeInterval = 45

    public init(resources: ResourceProviding) {
        self.resources = resources
        super.init()
    }

    /// 认证完成后写入最新 bundle 版本表，用于改写 bundle 脚本 URL。
    public func setBundleVersions(_ versions: [String: String]) {
        bundleVersions = versions
        LobbyLog.info("[scheme] live bundle versions: launcher=%@ game=%@ internal=%@",
                      versions["launcher"] ?? "<missing>",
                      versions["game"] ?? "<missing>",
                      versions["internal"] ?? "<missing>")
    }

    /// 宿主实例停止：在途任务正常报错收尾，之后凡是 WebKit 已停止的任务一律静默丢弃。
    public func stopAll() {
        for (token, entry) in pending {
            guard let task = tasks[token] else { continue }
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                                          userInfo: [NSLocalizedDescriptionKey: entry.url]))
        }
        if stoppedTasks.count + tasks.count > Self.stoppedTasksLimit {
            stoppedTasks.removeAll(keepingCapacity: true)
        }
        stoppedTasks.formUnion(tasks.keys)
        pending.removeAll()
        tasks.removeAll()
        abandonedTasks.removeAll(keepingCapacity: true)
        // 之后 WebKit 会为这些任务补发 stop；stoppedTasks 负责拦下迟到的回调。
    }

    // MARK: - WKURLSchemeHandler

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let token = ObjectIdentifier(urlSchemeTask as AnyObject)
        // 极小的窗口：WebKit 先 stop 又为同一对象发 start。任务已作废，撒手。
        guard stoppedTasks.remove(token) == nil else {
            LobbyLog.debug("[scheme] start ignored for stopped task")
            return
        }
        tasks[token] = urlSchemeTask
        guard let requestURL = urlSchemeTask.request.url else {
            fail(urlSchemeTask, code: NSURLErrorBadURL)
            return
        }

        // ① 本地 WebRuntime 命中。
        if let localURL = Self.localResource(for: requestURL) {
            let cacheKey = localURL.path as NSString
            if let cached = Self.localDataCache.object(forKey: cacheKey) {
                enqueueDelivery(urlSchemeTask, data: cached as Data, url: requestURL, cacheControl: "no-store")
                return
            }
            // 本地 runtime 首次读取可能是 4MB 的 cocos2d.js；不能在 UI actor 里
            // `Data(contentsOf:)`，否则首个实例加载本地脚本时就能卡住主线程。
            Task { @MainActor [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try Data(contentsOf: localURL) }
                }.value
                guard let self else { return }
                switch result {
                case .success(let data):
                    Self.localDataCache.setObject(data as NSData, forKey: cacheKey)
                    self.enqueueDelivery(urlSchemeTask, data: data, url: requestURL, cacheControl: "no-store")
                case .failure(let error):
                    self.fail(urlSchemeTask, code: (error as NSError).code)
                }
            }
            return
        }

        // ② CDN 代理。
        guard let remoteURL = remoteResource(for: requestURL) else {
            fail(urlSchemeTask, code: NSURLErrorFileDoesNotExist)
            return
        }
        // 先扫一遍悬挂任务（见 pendingAbandonAfter 注释）。
        enforcePendingTimeouts()
        pending[token] = (requestURL.absoluteString, Date())
        Task { @MainActor [weak self] in
            guard let self else {
                LobbyLog.debug("[scheme] handler released, response dropped: %@", requestURL.absoluteString)
                return
            }
            do {
                let data = try await self.resources.data(for: remoteURL, source: "game")
                self.enqueueDelivery(urlSchemeTask, data: data, url: requestURL,
                                     cacheControl: Self.remoteCacheControl(for: remoteURL))
            } catch {
                LobbyLog.error("[scheme] CDN error: %@ (%@)", remoteURL.absoluteString, error.localizedDescription)
                self.fail(urlSchemeTask, code: (error as NSError).code)
            }
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let token = ObjectIdentifier(urlSchemeTask as AnyObject)
        if stoppedTasks.count >= Self.stoppedTasksLimit { stoppedTasks.removeAll(keepingCapacity: true) }
        stoppedTasks.insert(token)
        // 必须摘掉：这是 WebKit 主动取消（导航变化 / 页面重载），不是悬挂；
        // 不清掉的话超时看门狗会把正常取消误报成「请求永远没完成」。
        pending[token] = nil
        tasks[token] = nil
    }

    // MARK: - 回传

    /// 把数据投递给 WebKit：主 actor 上经过全局闸门后回传。
    private func enqueueDelivery(_ task: WKURLSchemeTask, data: Data, url: URL, cacheControl: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await ResourceDeliveryGate.shared.acquire()
            defer { ResourceDeliveryGate.shared.release() }
            guard !self.isTaskKnownStopped(task) else { return }
            self.respond(task, data: data, url: url, cacheControl: cacheControl)
        }
    }

    private func isTaskKnownStopped(_ task: WKURLSchemeTask) -> Bool {
        let token = ObjectIdentifier(task as AnyObject)
        return stoppedTasks.contains(token) || abandonedTasks.contains(token)
    }

    private func respond(_ task: WKURLSchemeTask, data: Data, url: URL, cacheControl: String) {
        let token = ObjectIdentifier(task as AnyObject)
        guard !abandonedTasks.contains(token) else {
            LobbyLog.debug("[scheme] response dropped for abandoned task: %@", url.absoluteString)
            abandonedTasks.remove(token)
            tasks[token] = nil
            pending[token] = nil
            return
        }
        guard !stoppedTasks.contains(token) else {
            LobbyLog.debug("[scheme] response suppressed after stop: %@", url.absoluteString)
            stoppedTasks.remove(token)
            tasks[token] = nil
            pending[token] = nil
            return
        }
        tasks[token] = nil
        pending[token] = nil
        // Fetch/XHR 只在自定义方案返回 HTTP 响应时才暴露 ok / status——
        // 裸 URLResponse 会让成功的下载在页面侧表现为 status 0。
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": Self.mimeType(for: url.pathExtension),
                "Content-Length": String(data.count),
                "Cache-Control": cacheControl
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask, code: Int) {
        // 即使之前没登记过（URL 非法等分支），也要先补登记再走闸门——
        // 否则 stopAll() 遍历不到它，这个请求就永远没人收尾。
        let token = ObjectIdentifier(task as AnyObject)
        if tasks[token] == nil {
            tasks[token] = task
            pending[token] = (task.request.url?.absoluteString ?? "<unknown>", Date())
        }
        guard !stoppedTasks.contains(token) else {
            LobbyLog.debug("[scheme] failure suppressed after stop (code %ld)", code)
            stoppedTasks.remove(token)
            tasks[token] = nil
            pending[token] = nil
            return
        }
        tasks[token] = nil
        pending[token] = nil
        task.didFailWithError(NSError(domain: NSURLErrorDomain, code: code))
    }

    /// 超时看门狗：20s 告警，45s 主动放弃（把「永久挂起」降级成「一次失败」）。
    private func enforcePendingTimeouts() {
        let now = Date()
        guard now.timeIntervalSince(lastStaleReportAt) > 10 else { return }
        lastStaleReportAt = now
        for (token, entry) in pending {
            let age = now.timeIntervalSince(entry.startedAt)
            guard age >= Self.pendingAbandonAfter else {
                if age >= Self.pendingStaleAfter {
                    LobbyLog.warn("[scheme] task still pending (%.0fs): %@", age, entry.url)
                }
                continue
            }
            guard let task = tasks[token] else { continue }
            LobbyLog.error("[scheme] task abandoned after %.0fs: %@", age, entry.url)
            abandonedTasks.insert(token)
            fail(task, code: NSURLErrorTimedOut)
        }
    }

    // MARK: - 路径解析

    private static func localResource(for url: URL) -> URL? {
        guard url.host == "app", let root = LobbyConfiguration.webRuntimeRoot else { return nil }
        let path = url.path
        let relativePath: String
        if let alias = localPathAliases[path] {
            relativePath = alias
        } else if path.hasPrefix("/src/") || path.hasPrefix("/assets/") || path.hasPrefix("/jsb-adapter/") {
            relativePath = String(path.dropFirst())
        } else {
            return nil
        }
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = root.standardizedFileURL.path + "/"
        guard candidate.path.hasPrefix(prefix), FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }

    private func remoteResource(for url: URL) -> URL? {
        guard url.host == "app" || url.host == "cdn" else { return nil }
        let path: String
        if url.host == "app" {
            guard !url.path.hasPrefix("/cdn/") else {
                path = String(url.path.dropFirst(4))
                return remoteURL(path: rewriteBundleVersion(in: path), query: url.query)
            }
            path = "/remote" + url.path
        } else {
            path = url.path
        }
        return remoteURL(path: rewriteBundleVersion(in: path), query: url.query)
    }

    /// bundle 脚本 URL 改写：`/remote/<bundle>/index.js` → `index.<version>.js`。
    /// （页面按无版本规范路径引用，实际文件带版本号；版本表在认证完成后写入。）
    private func rewriteBundleVersion(in path: String) -> String {
        guard !bundleVersions.isEmpty else { return path }
        var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 3 else { return path }
        for index in components.indices {
            guard let version = bundleVersions[components[index]],
                  components.index(after: index) < components.endIndex else { continue }
            let filenameIndex = components.index(after: index)
            let filename = components[filenameIndex]
            let filenameParts = filename.split(separator: ".", omittingEmptySubsequences: false)
            guard filenameParts.count == 3,
                  filenameParts[0] == "index",
                  filenameParts[2] == "js" || filenameParts[2] == "jsc" else { continue }
            components[filenameIndex] = "index.\(version).\(filenameParts[2])"
            LobbyLog.verbose("[scheme] bundle URL rewritten: %@ -> %@", path, components.joined(separator: "/"))
            return components.joined(separator: "/")
        }
        return path
    }

    private func remoteURL(path: String, query: String?) -> URL? {
        var components = URLComponents(url: LobbyConfiguration.resourceBaseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)
        components?.query = query
        return components?.url
    }

    /// 远程资源缓存策略：URL 带内容摘要的可永久缓存，其余短缓存。
    /// 全部 no-store 等于关掉 WebKit 缓存——每次点击哪怕同一个按钮都要走一遍
    /// 完整 IPC + 下载链路；带摘要的资源交给 WebKit 缓存后第二次就是纯内存命中。
    private static func remoteCacheControl(for url: URL) -> String {
        let parts = url.lastPathComponent.split(separator: ".")
        if parts.count >= 3 {
            let digest = parts[parts.count - 2]
            if digest.count >= 4, digest.allSatisfy({ $0.isHexDigit }) {
                return "public, max-age=31536000, immutable"
            }
        }
        return "public, max-age=300"
    }

    private static func mimeType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "html": return "text/html"
        case "js", "mjs", "jsc": return "application/javascript"
        case "json": return "application/json"
        case "css": return "text/css"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "mp3": return "audio/mpeg"
        case "pvr", "bin": return "application/octet-stream"
        case "atlas": return "text/plain"
        case "ttf", "otf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }
}
