#if os(macOS)
import CryptoKit
import Foundation

/// Versioned, account-independent storage for the WebKit game's CDN files.
///
/// The cache lives in Application Support rather than a WKWebView data store:
/// every game window and every account in the same macOS installation can use
/// the same bytes, while cookies and local storage remain isolated per window.
struct MacCDNManifest: Sendable {
    let json: String
    let bundleVersions: [String: String]
}

struct MacCDNCacheStatus: Sendable {
    let fileCount: Int
    let byteCount: Int64
    let directoryPath: String
}

actor MacCDNResourceManager {
    static let shared = MacCDNResourceManager()

    static let automaticCachingKey = "ios2.cdn.automaticCachingEnabled"
    static let idleOnlyCachingKey = "ios2.cdn.idleOnlyCachingEnabled"

    private static let gameServer = URL(string: "https://xxz-xyzw.hortorgames.com")!
    private static let remoteBase = URL(string: "https://xxz-xyzw-res.hortorgames.com")!
    private static let manifestVersion = "0.33.0-ios"
    private static let coreBundles = ["launcher", "game", "TEST_REMOTE_MODULE", "main"]

    private struct CacheRecord: Codable {
        let path: String
        let byteCount: Int
        let storedAt: Date
    }

    private struct PersistedManifest: Codable {
        let json: String
        let bundleVersions: [String: String]
    }

    private let fileManager: FileManager
    private let cacheDirectory: URL
    private let filesDirectory: URL
    private let indexURL: URL
    private let missingURL: URL
    private let manifestURL: URL
    private var index: [String: CacheRecord]
    private var missingURLs: [String: Date]
    /// 最近一批 404 的时间戳（滑动窗口）。
    ///
    /// 一次 CDN 抖动会在几十秒内返回成百上千个 404。若照单全收地记进黑名单并
    /// 落盘，接下来整个 TTL 内这些资源一律「秒失败、不发网络请求」，画面会大
    /// 面积缺图——实测曾出现 19 分钟内写入 8171 条（其中 5105 条是 icons）。
    /// 所以窗口内 404 超过阈值时判定为**故障**而非「资源真的不存在」，只报错、
    /// 不记录。
    private var recentNotFound: [Date] = []
    /// 404 名单有改动待落盘（配合 `missingFlushTask` 做合并写）。
    private var missingDirty = false
    private var missingFlushTask: Task<Void, Never>?
    /// 缓存索引有改动待落盘（配合 `indexFlushTask` 做合并写）。
    private var indexDirty = false
    private var indexFlushTask: Task<Void, Never>?
    /// 滑动窗口内允许记入黑名单的 404 条数，超过即判定为故障。
    private static let notFoundBurstLimit = 24
    /// 404 滑动窗口长度（秒）。
    private static let notFoundBurstWindow: TimeInterval = 60
    /// 被认定「确实不存在」后的屏蔽时长。
    private static let missingTTL: TimeInterval = 6 * 60 * 60

    /// 已缓存资源的内容缓存，**跨实例共享**。
    ///
    /// `MacCDNResourceManager` 是 actor，方法串行执行；而缓存命中走的是
    /// `Data(contentsOf:)` 同步磁盘读，读的时候一直占着 actor。多开切场景时
    /// 请求量是「实例数 × 资源数」，这些同步读会排成一条长队，队尾的实例
    /// 就表现为「元素加载不完」。
    ///
    /// 关键点：所有实例请求的是**同一批 URL**（同一个游戏），所以这里一份
    /// 内存副本就能服务全部实例——第二次命中（含其他实例）既不碰磁盘、
    /// 也不占 actor。来回切场景的收益尤其大，因为每次切回来都是同一批资源。
    private static let contentCache = NSCache<NSString, NSData>()
    /// 内容缓存上限（字节）。按成本淘汰，超过就交给 NSCache 自己丢。
    private static let contentCacheLimit = 256 * 1024 * 1024

    /// 记录一次 404，返回 true 表示当前处于 404 风暴（不应记入黑名单）。
    private func noteNotFound() -> Bool {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.notFoundBurstWindow)
        if recentNotFound.count > Self.notFoundBurstLimit * 4 {
            recentNotFound = recentNotFound.filter { $0 > cutoff }
        } else {
            recentNotFound = recentNotFound.filter { $0 > cutoff }
        }
        recentNotFound.append(now)
        return recentNotFound.count >= Self.notFoundBurstLimit
    }

    private var latestManifestValue: MacCDNManifest?
    private var preparationTask: Task<MacCDNManifest, Error>?
    private var manifestTask: Task<MacCDNManifest, Error>?
    private var downloads: [String: Task<Data, Error>] = [:]
    private var cacheGeneration = 0
    private var fullPrefetchManifestKey: String?
    private var fullPrefetchTask: Task<Void, Never>?
    private var activeGameSessions = 0

    private struct BundleConfig {
        let bundle: String
        let importBase: String
        let nativeBase: String
        let uuids: [String]
        let paths: [(Int, [Any])]
        let versions: [String: [Int: String]]
    }

    init() {
        let manager = FileManager.default
        let applicationSupport = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.fileManager = manager
        Self.contentCache.totalCostLimit = Self.contentCacheLimit
        cacheDirectory = applicationSupport
            .appendingPathComponent("IOS2", isDirectory: true)
            .appendingPathComponent("CDN", isDirectory: true)
        filesDirectory = cacheDirectory.appendingPathComponent("files", isDirectory: true)
        indexURL = cacheDirectory.appendingPathComponent("index.json")
        missingURL = cacheDirectory.appendingPathComponent("missing.json")
        manifestURL = cacheDirectory.appendingPathComponent("manifest.json")
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
            // 顺手瘦身：过期条目留在文件里只会让后续每次全量重写都更贵。
            if live.count != records.count {
                MacLog.info("[ios2-macos][cdn] pruning %ld expired missing URL record(s)",
                            Int64(records.count - live.count))
                scheduleMissingPersist()
            }
        } else {
            missingURLs = [:]
        }
    }

    /// Called when the macOS app opens. Concurrent callers share one task.
    /// Failure is deliberately non-fatal: a game window can retry the manifest
    /// request and individual CDN requests later.
    func prepareForLaunch() async -> MacCDNManifest? {
        MacLog.info("[ios2-macos][cdn] launch preparation started")
        if let preparationTask {
            return try? await preparationTask.value
        }

        let task = Task<MacCDNManifest, Error> { [self] in
            let manifest = try await latestManifest()
            if automaticCachingEnabled {
                await prefetchCoreBundles(from: manifest)
                if !shouldPrefetchWhileIdle || activeGameSessions == 0 {
                    startFullPrefetchIfNeeded(from: manifest)
                }
            } else {
                MacLog.info("[ios2-macos][cdn] automatic caching disabled; game will cache lazily")
            }
            return manifest
        }
        preparationTask = task
        defer { preparationTask = nil }
        let manifest = try? await task.value
        if let manifest {
            MacLog.info("[ios2-macos][cdn] launch preparation complete: %ld bundle versions", manifest.bundleVersions.count)
        } else {
            MacLog.error("[ios2-macos][cdn] launch preparation failed; game requests will retry lazily")
        }
        return manifest
    }

    /// Called after an account has authenticated. Idle-only prefetching must
    /// stop while any game window is active; lazy game requests continue to
    /// use the same shared cache.
    func beginGameSession() {
        activeGameSessions += 1
        if shouldPrefetchWhileIdle {
            fullPrefetchTask?.cancel()
            fullPrefetchTask = nil
            fullPrefetchManifestKey = nil
            MacLog.debug("[ios2-macos][cdn] active account session started; idle prefetch paused")
        }
    }

    /// Called when a game window is closed.
    func endGameSession() async {
        activeGameSessions = max(0, activeGameSessions - 1)
        guard activeGameSessions == 0, automaticCachingEnabled, shouldPrefetchWhileIdle else { return }
        if let manifest = try? await latestManifest() {
            startFullPrefetchIfNeeded(from: manifest)
            MacLog.debug("[ios2-macos][cdn] no active account sessions; idle prefetch resumed")
        }
    }

    /// Applies settings changes immediately to an already-running app.
    func updateCachingSettings() async {
        guard automaticCachingEnabled else {
            fullPrefetchTask?.cancel()
            fullPrefetchTask = nil
            fullPrefetchManifestKey = nil
            MacLog.info("[ios2-macos][cdn] automatic caching disabled")
            return
        }
        if shouldPrefetchWhileIdle && activeGameSessions > 0 {
            fullPrefetchTask?.cancel()
            fullPrefetchTask = nil
            return
        }
        if let manifest = try? await latestManifest() {
            await prefetchCoreBundles(from: manifest)
            startFullPrefetchIfNeeded(from: manifest)
        }
    }

    private var automaticCachingEnabled: Bool {
        if UserDefaults.standard.object(forKey: Self.automaticCachingKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: Self.automaticCachingKey)
    }

    private var shouldPrefetchWhileIdle: Bool {
        UserDefaults.standard.bool(forKey: Self.idleOnlyCachingKey)
    }

    /// Re-fetches the manifest and warms the core entry files again. Existing
    /// files are retained and reused when their URL is unchanged.
    func synchronizeCache() async -> Bool {
        // Wait for the launch warm-up (or another manifest request) before
        // invalidating its in-memory result. This avoids overlapping refreshes
        // when the button is clicked immediately after app launch.
        if let preparationTask {
            _ = try? await preparationTask.value
        }
        if let manifestTask {
            _ = try? await manifestTask.value
        }
        latestManifestValue = nil
        fullPrefetchManifestKey = nil
        fullPrefetchTask?.cancel()
        fullPrefetchTask = nil
        MacLog.info("[ios2-macos][cdn] cache synchronization requested")
        do {
            // A manual sync must contact the CDN directly. Unlike normal game
            // startup, do not silently fall back to the persisted manifest.
            let manifest = try await Self.fetchManifest()
            try? persist(manifest: manifest)
            latestManifestValue = manifest
            MacLog.debug("[ios2-macos][cdn] manifest synchronized: %ld bundle versions", manifest.bundleVersions.count)
            await prefetchCoreBundles(from: manifest)
            await prefetchAllResources(from: manifest)
            fullPrefetchManifestKey = manifest.bundleVersions.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: "&")
            MacLog.info("[ios2-macos][cdn] cache synchronization complete")
            return true
        } catch {
            MacLog.error("[ios2-macos][cdn] cache synchronization failed: %@", error.localizedDescription)
            return false
        }
    }

    /// Deletes the shared CDN cache used by all game windows and accounts.
    func clearCache() async -> MacCDNCacheStatus {
        cacheGeneration &+= 1
        preparationTask?.cancel()
        manifestTask?.cancel()
        fullPrefetchTask?.cancel()
        downloads.values.forEach { $0.cancel() }
        preparationTask = nil
        manifestTask = nil
        downloads.removeAll()
        fullPrefetchTask = nil
        latestManifestValue = nil
        index.removeAll()
        missingURLs.removeAll()
        Self.contentCache.removeAllObjects()

        try? fileManager.removeItem(at: filesDirectory)
        try? fileManager.removeItem(at: indexURL)
        try? fileManager.removeItem(at: missingURL)
        try? fileManager.removeItem(at: manifestURL)
        MacLog.info("[ios2-macos][cdn] cache cleared: %@", cacheDirectory.path)
        return cacheStatus()
    }

    func cacheDirectoryURL() -> URL {
        cacheDirectory
    }

    func cacheStatus() -> MacCDNCacheStatus {
        var fileCount = 0
        var byteCount: Int64 = 0
        var staleKeys: [String] = []
        let prefix = filesDirectory.standardizedFileURL.path + "/"

        for (key, record) in index {
            let fileURL = filesDirectory.appendingPathComponent(record.path).standardizedFileURL
            guard fileURL.path.hasPrefix(prefix),
                  let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value == Int64(record.byteCount) else {
                staleKeys.append(key)
                continue
            }
            fileCount += 1
            byteCount += size.int64Value
        }

        for key in staleKeys { index[key] = nil }
        if !staleKeys.isEmpty, let data = try? JSONEncoder().encode(index) {
            try? data.write(to: indexURL, options: .atomic)
        }
        return MacCDNCacheStatus(
            fileCount: fileCount,
            byteCount: byteCount,
            directoryPath: cacheDirectory.path
        )
    }

    func latestManifest() async throws -> MacCDNManifest {
        if let latestManifestValue { return latestManifestValue }
        if let manifestTask { return try await manifestTask.value }

        let task = Task<MacCDNManifest, Error> { [self] in
            do {
                let manifest = try await Self.fetchManifest()
                try? persist(manifest: manifest)
                MacLog.debug("[ios2-macos][cdn] manifest downloaded: %ld bundle versions", manifest.bundleVersions.count)
                return manifest
            } catch {
                if let persisted = loadPersistedManifest() {
                    MacLog.warn("[ios2-macos][cdn] manifest network request failed; using persisted manifest")
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

    /// Returns a cached file or downloads it once for all waiting windows.
    func data(for remoteURL: URL, source: String = "prefetch") async throws -> Data {
        let key = remoteURL.absoluteString
        let generation = cacheGeneration
        if let expiry = missingURLs[key] {
            if expiry > Date() {
                // warn 而不是 debug：默认档位是 info，debug 根本不会输出，
                // 一旦有资源被误屏蔽，控制台里一点痕迹都没有，无从排查。
                MacLog.warn("[ios2-macos][cdn] known missing (skip retry): %@", key)
                throw URLError(.fileDoesNotExist)
            }
            missingURLs[key] = nil
            persistMissingURLs()
        }
        // 内存副本优先：既不用碰磁盘，也不用排 actor 的队。多开时这份副本
        // 服务的是**所有实例**，来回切场景时基本全是命中。
        if let hit = Self.contentCache.object(forKey: key as NSString) {
            return hit as Data
        }
        if let cached = try cachedData(for: key) {
            Self.contentCache.setObject(cached as NSData, forKey: key as NSString, cost: cached.count)
            // sha256 只为了打这一行日志。缓存命中是**每个资源一次**的热路径
            // （一个 bundle 几百个文件），开关关掉时必须连哈希一起省掉，
            // 否则「关日志」只省了打印、没省掉比打印更贵的计算。
            if MacLog.isEnabled(.verbose) {
                let digest = Self.sha256(cached)
                let path = index[key]?.path ?? "<unknown>"
                MacLog.verbose("[ios2-macos][cdn] %@ served from shared cache: %@ (%lld bytes, sha256=%@, file=%@)", source, key, Int64(cached.count), digest, path)
            }
            return cached
        }
        if let download = downloads[key] {
            MacLog.verbose("[ios2-macos][cdn] waiting for shared download: %@", key)
            let data = try await download.value
            Self.contentCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
            return data
        }

        MacLog.verbose("[ios2-macos][cdn] %@ network download started: %@", source, key)
        let download = Task.detached(priority: .utility) {
            var request = URLRequest(url: remoteURL)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = 90
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "CDN HTTP (\(status))", "ios2StatusCode": status])
            }
            guard !data.isEmpty else { throw URLError(.zeroByteResource) }
            return data
        }
        downloads[key] = download
        do {
            let data = try await download.value
            guard generation == cacheGeneration else { throw CancellationError() }
            try store(data: data, for: key)
            Self.contentCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
            downloads[key] = nil
            // 同上：整包 sha256 只在真的要打这条日志时才算。
            if MacLog.isEnabled(.debug) {
                MacLog.debug("[ios2-macos][cdn] %@ network download completed and cached: %@ (%lld bytes, sha256=%@)", source, key, Int64(data.count), Self.sha256(data))
            }
            return data
        } catch {
            if ((error as NSError).userInfo["ios2StatusCode"] as? Int) == 404 {
                if noteNotFound() {
                    // 404 风暴：当作 CDN 故障处理，只报错不屏蔽。否则一次抖动
                    // 会把上千个资源钉死一个 TTL，画面大面积缺图。
                    MacLog.error("[ios2-macos][cdn] 404 burst (%ld in %gs), not blacklisting: %@",
                                 Int64(recentNotFound.count), Self.notFoundBurstWindow, key)
                } else {
                    missingURLs[key] = Date().addingTimeInterval(Self.missingTTL)
                    persistMissingURLs()
                    MacLog.warn("[ios2-macos][cdn] recorded missing URL for %gh: %@",
                                Self.missingTTL / 3600, key)
                }
            }
            downloads[key] = nil
            throw error
        }
    }

    private static func fetchManifest() async throws -> MacCDNManifest {
        let encodedVersion = manifestVersion.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? manifestVersion
        var components = URLComponents(url: gameServer.appendingPathComponent("login/manifest"), resolvingAgainstBaseURL: false)!
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
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "游戏资源版本清单异常（HTTP \(status)）"])
        }

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
            throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "游戏资源版本清单缺少 launcher 版本。"])
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        return MacCDNManifest(json: String(data: bodyData, encoding: .utf8) ?? "{}", bundleVersions: versions)
    }

    private func prefetchCoreBundles(from manifest: MacCDNManifest) async {
        for bundle in Self.coreBundles {
            guard let version = manifest.bundleVersions[bundle], !version.isEmpty else { continue }
            let base = Self.remoteBase.appendingPathComponent("remote/\(bundle)")
            let urls = [
                base.appendingPathComponent("config.\(version).json"),
                base.appendingPathComponent("index.\(version).jsc")
            ]
            for url in urls {
                do {
                    _ = try await data(for: url)
                    MacLog.verbose("[ios2-macos][cdn] prefetch complete: %@", url.absoluteString)
                } catch {
                    // Optional bundles are still downloaded lazily by the game.
                    MacLog.warn("[ios2-macos] CDN prefetch failed: %@ (%@)", url.absoluteString, error.localizedDescription)
                }
            }
        }
    }

    /// Expands every bundle config into its import/native CDN URLs. This is the
    /// part that contains the large pvr/bin payloads, which are not discoverable
    /// from the top-level manifest alone.
    private func prefetchAllResources(from manifest: MacCDNManifest) async {
        var configs: [BundleConfig] = []
        for (bundle, version) in manifest.bundleVersions.sorted(by: { $0.key < $1.key }) {
            guard !Task.isCancelled else { return }
            guard let configURL = Self.remoteBase
                .appendingPathComponent("remote/\(bundle)")
                .appendingPathComponent("config.\(version).json") as URL? else { continue }
            do {
                let data = try await self.data(for: configURL)
                if let config = parseBundleConfig(bundle: bundle, data: data) {
                    configs.append(config)
                }
            } catch {
                MacLog.error("[ios2-macos][cdn] bundle config failed: %@ (%@)", bundle, error.localizedDescription)
            }
        }

        var urls = Set<String>()
        for config in configs {
            let base = Self.remoteBase.appendingPathComponent("remote/\(config.bundle)")
            for (uuidIndex, entry) in config.paths {
                guard entry.count >= 1,
                      let path = entry[0] as? String,
                      uuidIndex >= 0, uuidIndex < config.uuids.count else { continue }
                let uuid = decodeUUID(config.uuids[uuidIndex])
                // Import files exist for every entry. The version suffix is
                // optional when Cocos did not fingerprint that asset.
                let importSuffix = config.versions["import"]?[uuidIndex].map { ".\($0)" } ?? ""
                urls.insert(base.appendingPathComponent("\(config.importBase)/\(uuid.prefix(2))/\(uuid)\(importSuffix).json").absoluteString)
                if let nativeVersion = config.versions["native"]?[uuidIndex] {
                    for ext in nativeExtensions(for: path) {
                        let nativeSuffix = nativeVersion.isEmpty ? "" : ".\(nativeVersion)"
                        urls.insert(base.appendingPathComponent("\(config.nativeBase)/\(uuid.prefix(2))/\(uuid)\(nativeSuffix).\(ext)").absoluteString)
                    }
                }
            }
        }

        let total = urls.count
        MacLog.info("[ios2-macos][cdn] full resource prefetch started: %ld URLs from %ld bundles", total, configs.count)
        var completed = 0
        let sortedURLs = urls.sorted()
        // Keep a small number of requests in flight so a full sync is fast
        // without opening thousands of sockets or starving the game window.
        for batchStart in stride(from: 0, to: sortedURLs.count, by: 8) {
            guard !Task.isCancelled else {
                MacLog.info("[ios2-macos][cdn] full resource prefetch cancelled: %ld/%ld", completed, total)
                return
            }
            let batch = Array(sortedURLs[batchStart..<min(batchStart + 8, sortedURLs.count)])
            await withTaskGroup(of: Void.self) { group in
                for urlString in batch {
                    group.addTask { [self] in
                        guard let url = URL(string: urlString) else { return }
                        do {
                            _ = try await data(for: url)
                        } catch {
                            // Some native types use an extension not represented
                            // by the compact config. They remain available
                            // through lazy WebKit loading.
                            MacLog.warn("[ios2-macos][cdn] resource prefetch failed: %@ (%@)", urlString, error.localizedDescription)
                        }
                    }
                }
                await group.waitForAll()
            }
            completed += batch.count
            if completed == total || completed % 100 < batch.count {
                MacLog.debug("[ios2-macos][cdn] full resource prefetch progress: %ld/%ld", completed, total)
            }
        }
        MacLog.info("[ios2-macos][cdn] full resource prefetch complete: %ld URLs", total)
    }

    /// Full pvr/bin warm-up is deliberately detached from launch readiness:
    /// the login window only needs the manifest and core JavaScript files.
    /// Keeping this in the background prevents a long first download from
    /// presenting the user with a blank game window.
    private func startFullPrefetchIfNeeded(from manifest: MacCDNManifest) {
        let key = manifest.bundleVersions.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        guard fullPrefetchManifestKey != key else {
            MacLog.debug("[ios2-macos][cdn] full resource prefetch already running or complete")
            return
        }
        fullPrefetchManifestKey = key
        fullPrefetchTask = Task { [self] in
            await prefetchAllResources(from: manifest)
        }
        MacLog.debug("[ios2-macos][cdn] full resource prefetch continuing in background")
    }

    private func parseBundleConfig(bundle: String, data: Data) -> BundleConfig? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uuids = object["uuids"] as? [String],
              let pathsObject = object["paths"] as? [String: Any] else { return nil }
        let paths = pathsObject.compactMap { key, value -> (Int, [Any])? in
            guard let index = Int(key), let entry = value as? [Any] else { return nil }
            return (index, entry)
        }
        let versionsObject = object["versions"] as? [String: Any] ?? [:]
        var versions: [String: [Int: String]] = [:]
        for (kind, raw) in versionsObject {
            guard let list = raw as? [Any] else { continue }
            var values: [Int: String] = [:]
            var index = 0
            while index + 1 < list.count {
                if let uuidIndex = list[index] as? Int, let version = list[index + 1] as? String {
                    values[uuidIndex] = version
                }
                index += 2
            }
            versions[kind] = values
        }
        return BundleConfig(
            bundle: bundle,
            importBase: object["importBase"] as? String ?? "import",
            nativeBase: object["nativeBase"] as? String ?? "native",
            uuids: uuids,
            paths: paths,
            versions: versions
        )
    }

    private func nativeExtensions(for path: String) -> [String] {
        let lower = path.lowercased()
        if lower.hasSuffix(".mp3") { return ["mp3"] }
        if lower.hasSuffix(".ttf") { return ["ttf"] }
        if [".png", ".jpg", ".jpeg", ".webp"].contains(where: { lower.hasSuffix($0) }) {
            return ["pvr"]
        }
        // Generic serialized/native assets use .bin. Avoid probing both
        // extensions for every asset, which creates expected 404 traffic.
        return ["bin"]
    }

    private func decodeUUID(_ value: String) -> String {
        guard value.count == 22 else { return value }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        let chars = Array(value)
        let hex = Array("0123456789abcdef")
        var output: [Character] = [chars[0], chars[1]]
        var index = 2
        while index + 1 < chars.count {
            guard let first = alphabet.firstIndex(of: chars[index]),
                  let second = alphabet.firstIndex(of: chars[index + 1]) else { return value }
            let a = Int(first), b = Int(second)
            output.append(hex[a >> 2])
            output.append(hex[((a & 3) << 2) | (b >> 4)])
            output.append(hex[b & 15])
            index += 2
        }
        guard output.count == 32 else { return value }
        let uuid = String(output)
        return String(uuid.prefix(8)) + "-" + String(uuid.dropFirst(8).prefix(4)) + "-" + String(uuid.dropFirst(12).prefix(4)) + "-" + String(uuid.dropFirst(16).prefix(4)) + "-" + String(uuid.dropFirst(20))
    }

    private func cachedData(for key: String) throws -> Data? {
        guard let record = index[key] else { return nil }
        let fileURL = filesDirectory.appendingPathComponent(record.path).standardizedFileURL
        let prefix = filesDirectory.standardizedFileURL.path + "/"
        guard fileURL.path.hasPrefix(prefix), fileManager.fileExists(atPath: fileURL.path) else {
            index[key] = nil
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        guard data.count == record.byteCount else {
            index[key] = nil
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        return data
    }

    private func store(data: Data, for key: String) throws {
        try fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let ext = URL(string: key)?.pathExtension.isEmpty == false ? URL(string: key)!.pathExtension : "bin"
        let relativePath = "\(digest).\(ext)"
        let fileURL = filesDirectory.appendingPathComponent(relativePath)
        try data.write(to: fileURL, options: .atomic)
        index[key] = CacheRecord(path: relativePath, byteCount: data.count, storedAt: Date())
        // 索引落盘是**全量重写**（无增量格式），实测已长到 6.2MB。若每缓存一个
        // 资源就编码 + 原子写一次，多开批量预热时等于持续重写几 MB 文件，
        // 既吃 CPU 也吃磁盘 I/O。改成标脏 + 合并写。
        scheduleIndexPersist()
    }

    private static let indexPersistDelay: Duration = .seconds(5)

    private func scheduleIndexPersist() {
        indexDirty = true
        guard indexFlushTask == nil else { return }
        indexFlushTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: MacCDNResourceManager.indexPersistDelay)
            await self?.flushIndex()
        }
    }

    private func flushIndex() {
        indexFlushTask = nil
        guard indexDirty else { return }
        indexDirty = false
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func persist(manifest: MacCDNManifest) throws {
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(PersistedManifest(json: manifest.json, bundleVersions: manifest.bundleVersions))
        try data.write(to: manifestURL, options: .atomic)
    }

    /// 404 名单的落盘是**全量重写**（没有增量格式）。文件曾膨胀到 1.1MB /
    /// 8171 条，风暴期每来一个 404 就整个重写一次，等于持续往磁盘灌数 GB。
    /// 所以写入一律合并：先标脏，最多每 `missingPersistDelay` 落一次。
    private static let missingPersistDelay: Duration = .seconds(5)

    private func scheduleMissingPersist() {
        missingDirty = true
        guard missingFlushTask == nil else { return }
        missingFlushTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: MacCDNResourceManager.missingPersistDelay)
            await self?.flushMissingURLs()
        }
    }

    private func flushMissingURLs() {
        missingFlushTask = nil
        guard missingDirty else { return }
        missingDirty = false
        guard !missingURLs.isEmpty else {
            try? fileManager.removeItem(at: missingURL)
            return
        }
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(missingURLs) {
            try? data.write(to: missingURL, options: .atomic)
        }
    }

    private func persistMissingURLs() {
        scheduleMissingPersist()
    }

    private func loadPersistedManifest() -> MacCDNManifest? {
        guard let data = try? Data(contentsOf: manifestURL),
              let persisted = try? JSONDecoder().decode(PersistedManifest.self, from: data),
              !persisted.bundleVersions.isEmpty else { return nil }
        return MacCDNManifest(json: persisted.json, bundleVersions: persisted.bundleVersions)
    }
}
#endif
