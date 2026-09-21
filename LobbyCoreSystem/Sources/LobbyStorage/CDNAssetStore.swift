import CryptoKit
import Foundation
import LobbyDomain

/// 共享 CDN 资产仓（actor）：全部实例共用一份磁盘与内存缓存。
///
/// 核心机制（每一条都对应一次真实事故的修复）：
/// - **下载合并**：同一 URL 的并发请求共享一个 Task，N 个实例同时拉同一资源
///   只发一次网络请求（Thundering Herd 治理）。
/// - **跨实例内存副本**：actor 内 `Data(contentsOf:)` 是同步磁盘读，多开切场景
///   的请求量 = 实例数 × 资源数；所有实例请求的是同一批 URL，一份内存副本
///   服务全部实例后，二次命中既不碰磁盘也不占 actor。
/// - **404 风暴防护**：一次 CDN 抖动会返回成百上千个 404，照单全收进黑名单
///   会让整批资源「秒失败、不发请求」，画面大面积缺图。滑动窗口内 404 超过
///   阈值判定为**故障**而非「资源真的不存在」，只报错、不记录。
/// - **会话感知预取**：游戏内请求优先级高于预取；有实例活着时暂停闲时预取。
public actor CDNAssetStore: ResourceProviding {
    private let fileManager: FileManager
    private let cacheDirectory: URL
    private let filesDirectory: URL
    private let indexURL: URL
    private let missingURL: URL
    private let manifestURL: URL
    private var index: [String: CacheRecord]
    private var missingURLs: [String: Date]
    private var recentNotFound: [Date] = []
    private var missingDirty = false
    private var missingFlushTask: Task<Void, Never>?
    private var indexDirty = false
    private var indexFlushTask: Task<Void, Never>?

    private struct CacheRecord: Codable, Sendable {
        let path: String
        let byteCount: Int
        let storedAt: Date
    }

    private struct PersistedManifest: Codable, Sendable {
        let json: String
        let bundleVersions: [String: String]
    }

    /// 滑动窗口内允许记入黑名单的 404 条数，超过即判定为故障。
    private static let notFoundBurstLimit = 24
    /// 404 滑动窗口长度（秒）。
    private static let notFoundBurstWindow: TimeInterval = 60
    /// 被认定「确实不存在」后的屏蔽时长（6 小时）。
    private static let missingTTL: TimeInterval = 6 * 60 * 60

    /// 已缓存资源的内容缓存，跨实例共享。
    /// 条目上限必须设：只按字节算成本时，几张 1.4MB 的活动页 PVR 就能把上千个
    /// 小图标挤出去，而多开时图标正是每个场景都要重读的那批。
    private static let contentCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 256 * 1024 * 1024
        cache.countLimit = 8192
        return cache
    }()

    private var latestManifestValue: ResourceManifest?
    private var preparationTask: Task<ResourceManifest, Error>?
    private var manifestTask: Task<ResourceManifest, Error>?
    private var downloads: [String: Task<Data, Error>] = [:]
    private var activeGameSessions = 0

    public init(cacheDirectory directory: URL = LobbyConfiguration.cdnCacheDirectory) {
        let manager = FileManager.default
        self.fileManager = manager
        self.cacheDirectory = directory
        filesDirectory = directory.appendingPathComponent("files", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        missingURL = directory.appendingPathComponent("missing.json")
        manifestURL = directory.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: indexURL),
           let records = try? JSONDecoder().decode([String: CacheRecord].self, from: data) {
            index = records
        } else {
            index = [:]
        }
        if let data = try? Data(contentsOf: missingURL),
           let records = try? JSONDecoder().decode([String: Date].self, from: data) {
            let live = records.filter { $0.value > Date() }
            missingURLs = live
            // 过期条目留在文件里只会让后续每次全量重写都更贵，顺手瘦身。
            // （actor 的 init 是 nonisolated，直接内联写盘，不调隔离方法。）
            if live.count != records.count {
                LobbyLog.info("[cdn] pruning %ld expired missing URL record(s)", records.count - live.count)
                if let data = try? JSONEncoder().encode(live) {
                    try? data.write(to: missingURL, options: .atomic)
                }
            }
        } else {
            missingURLs = [:]
        }
    }

    // MARK: - ResourceProviding

    /// 启动预热：拉清单 + 核心 bundle。失败不致命（游戏窗口可以稍后惰性重试）。
    public func prepareForLaunch() async -> ResourceManifest? {
        LobbyLog.info("[cdn] launch preparation started")
        if let preparationTask {
            return try? await preparationTask.value
        }
        let task = Task<ResourceManifest, Error> { [self] in
            let manifest = try await latestManifest()
            if automaticCachingEnabled {
                await prefetchCoreBundles(from: manifest)
            } else {
                LobbyLog.info("[cdn] automatic caching disabled; game will cache lazily")
            }
            return manifest
        }
        preparationTask = task
        defer { preparationTask = nil }
        let manifest = try? await task.value
        if let manifest {
            LobbyLog.info("[cdn] launch preparation complete: %ld bundle versions", manifest.bundleVersions.count)
        } else {
            LobbyLog.error("[cdn] launch preparation failed; game requests will retry lazily")
        }
        return manifest
    }

    public func beginGameSession() async {
        activeGameSessions += 1
        LobbyLog.debug("[cdn] active session started (count=%ld)", activeGameSessions)
    }

    public func endGameSession() async {
        activeGameSessions = max(0, activeGameSessions - 1)
        LobbyLog.debug("[cdn] active session ended (count=%ld)", activeGameSessions)
    }

    public func latestManifest() async throws -> ResourceManifest {
        if let latestManifestValue { return latestManifestValue }
        if let manifestTask { return try await manifestTask.value }

        let task = Task<ResourceManifest, Error> { [self] in
            do {
                let manifest = try await Self.fetchManifest()
                try? persist(manifest: manifest)
                LobbyLog.debug("[cdn] manifest downloaded: %ld bundle versions", manifest.bundleVersions.count)
                return manifest
            } catch {
                if let persisted = loadPersistedManifest() {
                    LobbyLog.warn("[cdn] manifest network request failed; using persisted manifest")
                    return persisted
                }
                throw error
            }
        }
        manifestTask = task
        do {
            let manifest = try await task.value
            latestManifestValue = manifest
            manifestTask = nil
            return manifest
        } catch {
            manifestTask = nil
            throw error
        }
    }

    /// 返回缓存数据或发起（合并后的）下载。
    /// - Parameter source: "game" = 实例在途请求（高优先级、短超时）；"prefetch" = 预取。
    /// - Parameter requester: 发起方账号名，只进日志（见 `ResourceProviding.data` 的说明）。
    public func data(for remoteURL: URL, source: String, requester: String? = nil) async throws -> Data {
        let key = remoteURL.absoluteString
        let by = requester ?? "-"
        if let expiry = missingURLs[key] {
            if expiry > Date() {
                // 用 warn 而不是 debug：默认档位是 info，debug 根本不会输出——
                // 一旦有资源被误屏蔽，控制台里一点痕迹都没有，无从排查。
                LobbyLog.warn("[cdn] known missing (skip retry): %@", key)
                throw URLError(.fileDoesNotExist)
            }
            missingURLs[key] = nil
            persistMissingURLs()
        }
        if let hit = Self.contentCache.object(forKey: key as NSString) {
            return hit as Data
        }
        if let cached = cachedData(for: key) {
            Self.contentCache.setObject(cached as NSData, forKey: key as NSString, cost: cached.count)
            return cached
        }
        if let download = downloads[key] {
            // 这一行是「N 个实例在等同一份下载」的直接证据：同一 key 会出现多条、
            // 每条的 by= 都不同。哪个账号在这一列上出现得最多、出现得最晚，
            // 哪个账号的这块画面就补得最晚。
            LobbyLog.verbose("[cdn] %@ waiting for shared download: %@ (by=%@)", source, key, by)
            let data = try await download.value
            Self.contentCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
            return data
        }

        LobbyLog.verbose("[cdn] %@ network download started: %@ (by=%@)", source, key, by)
        // 游戏内的请求不能按后台预取对待：`.utility` 会被排在用户等待的工作之后，
        // 多开时十来个实例同时拉资源，这类任务容易被饿死——而它卡住的是所有
        // `await downloads[key]` 的实例。超时同理：预取 90s 没问题，游戏内请求
        // 一个资源卡 90s，画面上这一块就空 90s——早点失败让 Cocos 自己重试
        // （它配了 maxRetryCount: 4，第二次基本都能命中原生缓存）。
        let interactive = (source == "game")
        let download = Task.detached(priority: interactive ? .userInitiated : .utility) {
            var request = URLRequest(url: remoteURL)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = interactive ? 30 : 90
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw URLError(.badServerResponse,
                               userInfo: [NSLocalizedDescriptionKey: "CDN HTTP (\(status))",
                                          "lobbyStatusCode": status])
            }
            guard !data.isEmpty else { throw URLError(.zeroByteResource) }
            return data
        }
        downloads[key] = download
        do {
            let data = try await download.value
            try store(data: data, for: key)
            Self.contentCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
            downloads[key] = nil
            LobbyLog.verbose("[cdn] %@ download completed and cached: %@ (%ld bytes) (by=%@)",
                             source, key, data.count, by)
            return data
        } catch {
            if ((error as NSError).userInfo["lobbyStatusCode"] as? Int) == 404 {
                if noteNotFound() {
                    // 404 风暴：当作 CDN 故障处理，只报错不屏蔽。
                    LobbyLog.error("[cdn] 404 burst (%ld in %gs), not blacklisting: %@",
                                   recentNotFound.count, Self.notFoundBurstWindow, key)
                } else {
                    missingURLs[key] = Date().addingTimeInterval(Self.missingTTL)
                    persistMissingURLs()
                    LobbyLog.warn("[cdn] recorded missing URL for %gh: %@", Self.missingTTL / 3600, key)
                }
            }
            downloads[key] = nil
            throw error
        }
    }

    // MARK: - 清单

    private static func fetchManifest() async throws -> ResourceManifest {
        let encodedVersion = LobbyConfiguration.manifestVersion
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? LobbyConfiguration.manifestVersion
        var components = URLComponents(url: LobbyConfiguration.gameServerURL.appendingPathComponent("login/manifest"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "platform", value: "hortor"),
            URLQueryItem(name: "version", value: encodedVersion)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = Data()
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("close", forHTTPHeaderField: "Connection")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = object["body"] as? [String: Any],
              let value = body["bundleVers"] else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse,
                           userInfo: [NSLocalizedDescriptionKey: "游戏资源版本清单异常（HTTP \(status)）"])
        }

        // bundleVers 可能是 JSON 字符串（需要二次解码）或直接是字典。
        let versions: [String: String]
        if let string = value as? String,
           let versionData = string.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: versionData) as? [String: Any] {
            versions = decoded.reduce(into: [:]) { result, item in
                if let version = item.value as? String, !version.isEmpty { result[item.key] = version }
            }
        } else if let decoded = value as? [String: Any] {
            versions = decoded.reduce(into: [:]) { result, item in
                if let version = item.value as? String, !version.isEmpty { result[item.key] = version }
            }
        } else {
            versions = [:]
        }
        guard versions["launcher"] != nil else {
            throw URLError(.cannotParseResponse,
                           userInfo: [NSLocalizedDescriptionKey: "游戏资源版本清单缺少 launcher 版本。"])
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        return ResourceManifest(json: String(data: bodyData, encoding: .utf8) ?? "{}", bundleVersions: versions)
    }

    // MARK: - 预取

    /// 核心 bundle（config + 脚本）预热。完整资源清单预取（PVR/BIN 全量）在阶段 2 扩展。
    private func prefetchCoreBundles(from manifest: ResourceManifest) async {
        for bundle in LobbyConfiguration.coreBundles {
            guard let version = manifest.bundleVersions[bundle], !version.isEmpty else { continue }
            let base = LobbyConfiguration.resourceBaseURL.appendingPathComponent("remote/\(bundle)")
            let urls = [
                base.appendingPathComponent("config.\(version).json"),
                base.appendingPathComponent("index.\(version).jsc")
            ]
            for url in urls {
                do {
                    _ = try await data(for: url, source: "prefetch", requester: nil)
                } catch {
                    // 可选 bundle 由游戏惰性下载，失败不阻断预热。
                    LobbyLog.warn("[cdn] core prefetch failed: %@ (%@)", url.absoluteString, error.localizedDescription)
                }
            }
        }
    }

    // MARK: - 磁盘缓存

    private var automaticCachingEnabled: Bool {
        UserDefaults.standard.object(forKey: LobbyConfiguration.PreferenceKey.cdnAutomaticCaching) as? Bool ?? true
    }

    private func cachedData(for key: String) -> Data? {
        guard let record = index[key] else { return nil }
        return try? Data(contentsOf: filesDirectory.appendingPathComponent(record.path))
    }

    private func store(data: Data, for key: String) throws {
        let digest = Self.sha256(key)
        let relative = "\(digest.prefix(2))/\(digest)"
        let fileURL = filesDirectory.appendingPathComponent(relative)
        try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        index[key] = CacheRecord(path: relative, byteCount: data.count, storedAt: Date())
        scheduleIndexPersist()
    }

    private func scheduleIndexPersist() {
        guard !indexDirty else { return }
        indexDirty = true
        indexFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.finalizeIndexPersist()
        }
    }

    /// actor 隔离的落盘收尾（debounce Task 从外部跳回 actor）。
    private func finalizeIndexPersist() {
        indexDirty = false
        persistIndex()
    }

    private func persistIndex() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// 记录一次 404，返回 true 表示当前处于 404 风暴（不应记入黑名单）。
    private func noteNotFound() -> Bool {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.notFoundBurstWindow)
        recentNotFound = recentNotFound.filter { $0 > cutoff }
        recentNotFound.append(now)
        return recentNotFound.count >= Self.notFoundBurstLimit
    }

    private func persistMissingURLs() {
        guard !missingDirty else { return }
        missingDirty = true
        missingFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.finalizeMissingPersist()
        }
    }

    /// actor 隔离的落盘收尾（debounce Task 从外部跳回 actor）。
    private func finalizeMissingPersist() {
        missingDirty = false
        guard let data = try? JSONEncoder().encode(missingURLs) else { return }
        try? data.write(to: missingURL, options: .atomic)
    }

    private func persist(manifest: ResourceManifest) throws {
        let record = PersistedManifest(json: manifest.json, bundleVersions: manifest.bundleVersions)
        let data = try JSONEncoder().encode(record)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func loadPersistedManifest() -> ResourceManifest? {
        guard let data = try? Data(contentsOf: manifestURL),
              let record = try? JSONDecoder().decode(PersistedManifest.self, from: data) else { return nil }
        return ResourceManifest(json: record.json, bundleVersions: record.bundleVersions)
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
