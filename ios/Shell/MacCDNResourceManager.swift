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
    private let manifestURL: URL
    private var index: [String: CacheRecord]
    private var latestManifestValue: MacCDNManifest?
    private var preparationTask: Task<MacCDNManifest, Error>?
    private var manifestTask: Task<MacCDNManifest, Error>?
    private var downloads: [String: Task<Data, Error>] = [:]
    private var cacheGeneration = 0

    init() {
        let manager = FileManager.default
        let applicationSupport = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.fileManager = manager
        cacheDirectory = applicationSupport
            .appendingPathComponent("IOS2", isDirectory: true)
            .appendingPathComponent("CDN", isDirectory: true)
        filesDirectory = cacheDirectory.appendingPathComponent("files", isDirectory: true)
        indexURL = cacheDirectory.appendingPathComponent("index.json")
        manifestURL = cacheDirectory.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: indexURL),
           let records = try? JSONDecoder().decode([String: CacheRecord].self, from: data) {
            index = records
        } else {
            index = [:]
        }
    }

    /// Called when the macOS app opens. Concurrent callers share one task.
    /// Failure is deliberately non-fatal: a game window can retry the manifest
    /// request and individual CDN requests later.
    func prepareForLaunch() async -> MacCDNManifest? {
        NSLog("[ios2-macos][cdn] launch preparation started")
        if let preparationTask {
            return try? await preparationTask.value
        }

        let task = Task<MacCDNManifest, Error> { [self] in
            let manifest = try await latestManifest()
            await prefetchCoreBundles(from: manifest)
            return manifest
        }
        preparationTask = task
        defer { preparationTask = nil }
        let manifest = try? await task.value
        if let manifest {
            NSLog("[ios2-macos][cdn] launch preparation complete: %ld bundle versions", manifest.bundleVersions.count)
        } else {
            NSLog("[ios2-macos][cdn] launch preparation failed; game requests will retry lazily")
        }
        return manifest
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
        NSLog("[ios2-macos][cdn] cache synchronization requested")
        do {
            // A manual sync must contact the CDN directly. Unlike normal game
            // startup, do not silently fall back to the persisted manifest.
            let manifest = try await Self.fetchManifest()
            try? persist(manifest: manifest)
            latestManifestValue = manifest
            NSLog("[ios2-macos][cdn] manifest synchronized: %ld bundle versions", manifest.bundleVersions.count)
            await prefetchCoreBundles(from: manifest)
            NSLog("[ios2-macos][cdn] cache synchronization complete")
            return true
        } catch {
            NSLog("[ios2-macos][cdn] cache synchronization failed: %@", error.localizedDescription)
            return false
        }
    }

    /// Deletes the shared CDN cache used by all game windows and accounts.
    func clearCache() async -> MacCDNCacheStatus {
        cacheGeneration &+= 1
        preparationTask?.cancel()
        manifestTask?.cancel()
        downloads.values.forEach { $0.cancel() }
        preparationTask = nil
        manifestTask = nil
        downloads.removeAll()
        latestManifestValue = nil
        index.removeAll()

        try? fileManager.removeItem(at: filesDirectory)
        try? fileManager.removeItem(at: indexURL)
        try? fileManager.removeItem(at: manifestURL)
        NSLog("[ios2-macos][cdn] cache cleared: %@", cacheDirectory.path)
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
                NSLog("[ios2-macos][cdn] manifest downloaded: %ld bundle versions", manifest.bundleVersions.count)
                return manifest
            } catch {
                if let persisted = loadPersistedManifest() {
                    NSLog("[ios2-macos][cdn] manifest network request failed; using persisted manifest")
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
    func data(for remoteURL: URL) async throws -> Data {
        let key = remoteURL.absoluteString
        let generation = cacheGeneration
        if let cached = try cachedData(for: key) {
            NSLog("[ios2-macos][cdn] cache hit: %@ (%lld bytes)", key, Int64(cached.count))
            return cached
        }
        if let download = downloads[key] {
            NSLog("[ios2-macos][cdn] waiting for shared download: %@", key)
            return try await download.value
        }

        NSLog("[ios2-macos][cdn] download started: %@", key)
        let download = Task.detached(priority: .utility) {
            var request = URLRequest(url: remoteURL)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = 90
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "CDN HTTP (\(status))"])
            }
            guard !data.isEmpty else { throw URLError(.zeroByteResource) }
            return data
        }
        downloads[key] = download
        do {
            let data = try await download.value
            guard generation == cacheGeneration else { throw CancellationError() }
            try store(data: data, for: key)
            downloads[key] = nil
            NSLog("[ios2-macos][cdn] download completed and cached: %@ (%lld bytes)", key, Int64(data.count))
            return data
        } catch {
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
                    NSLog("[ios2-macos][cdn] prefetch complete: %@", url.absoluteString)
                } catch {
                    // Optional bundles are still downloaded lazily by the game.
                    NSLog("[ios2-macos] CDN prefetch failed: %@ (%@)", url.absoluteString, error.localizedDescription)
                }
            }
        }
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
        let indexData = try JSONEncoder().encode(index)
        try indexData.write(to: indexURL, options: .atomic)
    }

    private func persist(manifest: MacCDNManifest) throws {
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(PersistedManifest(json: manifest.json, bundleVersions: manifest.bundleVersions))
        try data.write(to: manifestURL, options: .atomic)
    }

    private func loadPersistedManifest() -> MacCDNManifest? {
        guard let data = try? Data(contentsOf: manifestURL),
              let persisted = try? JSONDecoder().decode(PersistedManifest.self, from: data),
              !persisted.bundleVersions.isEmpty else { return nil }
        return MacCDNManifest(json: persisted.json, bundleVersions: persisted.bundleVersions)
    }
}
#endif
