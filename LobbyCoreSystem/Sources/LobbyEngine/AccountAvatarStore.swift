import AppKit
import Combine
import CryptoKit
import Foundation
import LobbyDomain
import LobbyIPC

// MARK: - 账号资料 + 头像缓存
//
// 「每个账号在游戏里长什么样」在原生侧的唯一真源。
//
// 数据链路：页面 `window.ROLE`（游戏 `ServerData.createServerData()` 挂上去的）
// → 只读探针 `AccountProfileScript` → `ios2Game` 桥 → `PageEvent.accountProfile`
// → `GameViewportInstance` → 本 store。
//
// 为什么要落盘两层：
//   · `avatars.json` 存**资料快照**（头像 URL / 游戏内昵称 / 等级战力）；
//   · `avatars/<sha256>.img` 存**图片字节**，账号卡直接读本地，离线也在。
// 不落盘的话「账号卡显示头像」就变成「必须先跑一遍这个账号」，等于没有。
//
// ⚠️ 头像 URL 是可变的（换头像会换 hash），但**不能因为失败就删旧图**：
// 网络抖一下就把用户已经看到的头像抹掉，观感比过期更差。所以只在**成功下到
// 新图**时才替换 `avatarFile`；失败只记日志，卡片继续显示旧图。
//
// ⚠️ 尺寸归一化：qlogo 的 URL 末段是尺寸（`/0`=原图 1080、`/46 /64 /96 /132`
// 可用、`/640` 返回 400，均已实测）。游戏自己取的就是 `/132`；卡片只要 28pt，
// 统一改成 132 → 一屏 20 个账号从 ~1.4MB 降到 ~80KB。
@MainActor
public final class AccountAvatarStore: ObservableObject {
    /// 单个账号的资料快照（落盘口径）。
    public struct Record: Codable, Equatable, Sendable {
        /// 头像远端 URL（原样保存页面给的那条，归一化只作用于下载与缓存键）。
        public var headImg: String
        /// 游戏内角色名。
        public var name: String
        public var power: Int
        public var level: Int
        public var vip: Int
        /// 最近一次上报时间。
        public var updatedAt: Date
        /// 本地头像文件名（`avatars/` 内）。nil = 还没成功下过。
        public var avatarFile: String?

        public init(headImg: String, name: String, power: Int, level: Int, vip: Int,
                    updatedAt: Date = .now, avatarFile: String? = nil) {
            self.headImg = headImg
            self.name = name
            self.power = power
            self.level = level
            self.vip = vip
            self.updatedAt = updatedAt
            self.avatarFile = avatarFile
        }
    }

    /// 账号 ID → 资料快照。
    @Published public private(set) var profiles: [String: Record] = [:]
    /// 账号 ID → 头像图（内存缓存；磁盘是权威）。
    @Published public private(set) var images: [String: NSImage] = [:]

    /// 单张头像的下载上限。正常 132px JPEG 约 4KB；超过这个数只能是被换成了
    /// 别的东西（HTML 错误页 / 重定向到原图），不落盘。
    private static let maxAvatarBytes = 2 * 1024 * 1024
    /// 卡片渲染用的目标尺寸档（与游戏自身请求的一致）。
    private static let preferedQlogoSegment = "132"

    private struct Document: Codable {
        var version: Int = 1
        var profiles: [String: Record] = [:]
    }

    private let indexURL: URL
    private let imageDirectory: URL
    /// 在途下载（按账号 ID 去重，避免慢档巡检/重复上报把同一张图下多次）。
    private var inFlight: Set<String> = []
    private var downloads: [String: Task<Void, Never>] = [:]
    /// 每账号的下载尝试次数（成功即清零）。见 `retryMissingAvatars`。
    private var attempts: [String: Int] = [:]
    private var retryTask: Task<Void, Never>?

    /// 兜底重试节奏：60s 一次，单账号最多 20 次（≈20min）。
    /// 为什么需要：页面侧只在**资料变化**时上报，下载失败后若不自己重试，
    /// 那张头像就要等到下次升级 / 切角色才补得回来——用户看到的是
    /// 「有的账号有头像、有的永远没有」，而实际上只是第一次抓图时网抖了一下。
    private static let retryIntervalNanos: UInt64 = 60_000_000_000
    private static let maxDownloadAttempts = 20

    public init(directory: URL = LobbyConfiguration.lobbySupportDirectory) {
        indexURL = directory.appendingPathComponent("avatars.json")
        imageDirectory = directory.appendingPathComponent("avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: imageDirectory,
                                                 withIntermediateDirectories: true)
        loadIndex()
        startRetryLoop()
    }

    // MARK: - 查询（UI 用）

    public func profile(forAccountID accountID: String) -> Record? {
        profiles[accountID]
    }

    /// 头像图。**纯读**——磁盘内容在 `preloadImages()` 里已经灌进 `images`，
    /// 这里绝不做 IO、更不改任何 `@Published`。
    ///
    /// ⚠️ 为什么强调这一点：这个方法是**在 SwiftUI 的 `body` 求值期**被卡片调用的。
    /// 早先的版本在这里做「懒加载 + 顺手清死引用」，等于在视图更新过程中写
    /// `@Published` → 触发 "Publishing changes from within view updates"，
    /// 轻则控制台刷警告，重则渲染循环。IO 一律挪到 body 之外（init / 重试节拍）。
    public func image(forAccountID accountID: String) -> NSImage? {
        images[accountID]
    }

    // MARK: - 写入（实例上报入口）

    /// 记一次页面上报。只更新变化的字段；头像 URL 变了才触发下载。
    public func record(_ snapshot: AccountProfileSnapshot, forAccountID accountID: String) {
        guard !snapshot.isEmpty else { return }
        var record = profiles[accountID] ?? Record(headImg: snapshot.headImg,
                                                  name: snapshot.name,
                                                  power: snapshot.power,
                                                  level: snapshot.level,
                                                  vip: snapshot.vip)
        let avatarChanged = record.headImg != snapshot.headImg
        record.headImg = snapshot.headImg
        record.name = snapshot.name
        record.power = snapshot.power
        record.level = snapshot.level
        record.vip = snapshot.vip
        record.updatedAt = .now
        let isNew = profiles[accountID] == nil
        profiles[accountID] = record
        // 首次登记 / 换头像 → 拉图；其余情况（只涨了战力）不折腾网络。
        // 注意这里**不做「补读磁盘」**：图片在 `preloadImages()` 里已经全部就位，
        // 少了说明是文件被外部删掉，交给兜底重试节拍去发现与补下。
        if isNew || avatarChanged || record.avatarFile == nil {
            startDownload(accountID: accountID, headImg: snapshot.headImg)
        }
        persist()
    }

    /// 账号被删除时清理（文件 + 索引一起）。
    public func forget(accountIDs: [String]) {
        guard !accountIDs.isEmpty else { return }
        var changed = false
        for accountID in accountIDs {
            downloads[accountID]?.cancel()
            downloads[accountID] = nil
            inFlight.remove(accountID)
            attempts.removeValue(forKey: accountID)
            images.removeValue(forKey: accountID)
            guard let record = profiles.removeValue(forKey: accountID) else { continue }
            changed = true
            removeImageFile(named: record.avatarFile)
        }
        if changed { persist() }
    }

    /// 丢掉不在账号库里的残留（用户在 Finder 里手删了 .bin 的情况）。
    public func prune(keeping accountIDs: Set<String>) {
        let stale = profiles.keys.filter { !accountIDs.contains($0) }
        guard !stale.isEmpty else { return }
        LobbyLog.debug("[avatar] prune %ld stale profile(s)", stale.count)
        forget(accountIDs: stale)
    }

    // MARK: - 下载

    private func startDownload(accountID: String, headImg: String) {
        guard let target = Self.normalizedDownloadURL(headImg) else {
            LobbyLog.debug("[avatar] unsupported headImg for %@: %@",
                           accountID, Self.shortened(headImg))
            return
        }
        guard !inFlight.contains(accountID) else { return }
        inFlight.insert(accountID)
        attempts[accountID, default: 0] += 1
        let cacheName = Self.cacheFileName(for: target.cacheKey)
        downloads[accountID] = Task { @MainActor [weak self] in
            defer {
                self?.inFlight.remove(accountID)
                self?.downloads[accountID] = nil
            }
            do {
                var request = URLRequest(url: target.url)
                request.timeoutInterval = 20
                // 头像是公开资源（qlogo 实测无需 cookie），但仍然带上 UA：
                // 少了它有些 CDN 会回 403。
                request.setValue("GameLobby/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    LobbyLog.debug("[avatar] %@ download http %ld", accountID, http.statusCode)
                    return
                }
                guard data.count > 64, data.count <= Self.maxAvatarBytes,
                      Self.looksLikeImage(data, response: response) else {
                    LobbyLog.warn("[avatar] %@ payload rejected (%ld bytes)", accountID, data.count)
                    return
                }
                guard let self else { return }
                let fileURL = self.imageDirectory.appendingPathComponent(cacheName)
                try data.write(to: fileURL, options: .atomic)
                // 下载期间页面可能又上报了新 URL：只在还一致时挂上去。
                guard var record = self.profiles[accountID],
                      record.headImg == headImg else {
                    self.removeImageFile(named: cacheName)
                    return
                }
                let previous = record.avatarFile
                record.avatarFile = cacheName
                self.profiles[accountID] = record
                self.images[accountID] = NSImage(data: data)
                self.attempts.removeValue(forKey: accountID)
                if previous != cacheName { self.removeImageFile(named: previous) }
                self.persist()
                LobbyLog.info("[avatar] %@ cached %@ (%ld bytes, level=%ld power=%ld)",
                              accountID, cacheName.prefix(12), data.count,
                              record.level, record.power)
            } catch {
                LobbyLog.debug("[avatar] %@ download failed: %@",
                               accountID, error.localizedDescription)
            }
        }
    }

    private func removeImageFile(named fileName: String?) {
        guard let fileName, !fileName.isEmpty else { return }
        try? FileManager.default.removeItem(at: imageDirectory.appendingPathComponent(fileName))
    }

    // MARK: - 兜底重试

    private func startRetryLoop() {
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.retryIntervalNanos)
                guard !Task.isCancelled, let self else { return }
                self.retryMissingAvatars()
            }
        }
    }

    /// 把「有资料但没图」的账号捞出来补下。启动时也会命中上一轮没下成的记录。
    private func retryMissingAvatars() {
        // 先修正「索引说有图、内存里却没有」的不一致（缓存文件被外部删掉 / 写坏）。
        // 只在真的不一致时才碰磁盘，常态一拍代价是零。
        let inconsistent = profiles.contains { $0.value.avatarFile != nil && images[$0.key] == nil }
        if inconsistent { preloadImages() }
        for (accountID, record) in profiles where record.avatarFile == nil {
            guard attempts[accountID, default: 0] < Self.maxDownloadAttempts,
                  !inFlight.contains(accountID), !record.headImg.isEmpty else { continue }
            startDownload(accountID: accountID, headImg: record.headImg)
        }
    }

    // MARK: - 落盘

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let document = try? JSONDecoder().decode(Document.self, from: data) else { return }
        profiles = document.profiles
        LobbyLog.debug("[avatar] loaded %ld profile(s)", profiles.count)
        preloadImages()
    }

    /// 把索引里指向的图片一次性读进内存。
    ///
    /// 时机固定在 init 与兜底重试节拍里——**绝不在视图 body 里偷懒加载**
    /// （原因见 `image(forAccountID:)` 的注释）。
    /// `NSImage(contentsOf:)` 是惰性解码（只读文件头），几十张的量级可以忽略。
    private func preloadImages() {
        var loaded: [String: NSImage] = [:]
        var broken: [String] = []
        for (accountID, record) in profiles {
            guard let fileName = record.avatarFile else { continue }
            let url = imageDirectory.appendingPathComponent(fileName)
            if let image = NSImage(contentsOf: url), image.size.width > 0 {
                loaded[accountID] = image
            } else {
                broken.append(accountID)
            }
        }
        images = loaded
        guard !broken.isEmpty else { return }
        // 图片文件被外面删了 / 写坏了：清掉死引用，兜底重试下一拍会重新下。
        LobbyLog.debug("[avatar] %ld cached image(s) missing on disk, will refetch", broken.count)
        for accountID in broken { profiles[accountID]?.avatarFile = nil }
        persist()
    }

    private func persist() {
        let document = Document(profiles: profiles)
        guard let data = try? JSONEncoder().encode(document) else { return }
        // 同步写：调用点都在主线程，且文件很小（几十条记录 ≈ 几 KB），
        // 异步写反而要处理「连续两次写入乱序」的问题。
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: - URL 与文件名工具

    /// 归一化下载地址。
    ///
    /// 只对 `qlogo.cn`（微信 / QQ 头像）改末段尺寸；游戏自建 CDN
    /// （`mars-face.hortorgames.com`）的路径没有尺寸语义，一律原样使用。
    private static func normalizedDownloadURL(_ raw: String) -> (url: URL, cacheKey: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased() else { return nil }
        guard components.path.count < 512 else { return nil }
        if host.hasSuffix("qlogo.cn") {
            var segments = components.path.split(separator: "/", omittingEmptySubsequences: false)
            if let last = segments.last, !last.isEmpty,
               last.allSatisfy({ $0.isNumber }), last != preferedQlogoSegment {
                segments[segments.count - 1] = Substring(preferedQlogoSegment)
                components.path = segments.joined(separator: "/")
            }
        }
        guard let url = components.url else { return nil }
        return (url, url.absoluteString)
    }

    private static func cacheFileName(for cacheKey: String) -> String {
        let digest = SHA256.hash(data: Data(cacheKey.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "\(digest).img"
    }

    /// 松判断为图片：优先信 Content-Type，其次认 JPEG / PNG 魔数。
    /// 有些 CDN 回 `application/octet-stream`，只认头会误杀。
    private static func looksLikeImage(_ data: Data, response: URLResponse) -> Bool {
        if let mime = response.mimeType?.lowercased(), mime.hasPrefix("image/") { return true }
        guard data.count >= 8 else { return false }
        let bytes = [UInt8](data.prefix(8))
        if bytes[0] == 0xFF, bytes[1] == 0xD8 { return true }                       // JPEG
        if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 { // PNG
            return true
        }
        return false
    }

    /// 日志里不打完整（可能带 hash 与查询串），只留头像描述性的一小段。
    private static func shortened(_ url: String) -> String {
        guard let range = url.range(of: "/vi_32/") else {
            return url.count > 60 ? String(url.prefix(60)) + "…" : url
        }
        let tail = url[range.upperBound...]
        return "…/vi_32/" + (tail.count > 24 ? String(tail.prefix(24)) + "…" : tail)
    }
}
