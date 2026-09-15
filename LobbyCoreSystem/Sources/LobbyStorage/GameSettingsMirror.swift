import Foundation
import LobbyDomain
import WebKit

/// 游戏 localStorage 的原生镜像。
///
/// 这是持久化 data store 之外的第二层保险：游戏跑在自定义 scheme 上，
/// WebKit 对这类 origin 的 localStorage 落盘策略不稳定，所以页面每次写
/// localStorage 都实时回传原生并节流落盘；下次登录在文档创建之前把镜像写回
/// localStorage，游戏内配置（音量、省电模式等）就不会回到默认值。
///
/// 存储分区跟随 `GameStoragePolicy`：
/// - `sharedAcrossAccounts`：所有账号共用 `shared.json`（一处改、全账号生效）；
/// - `isolatedPerAccount`：按账号各一份 `<账号>.json`；
/// - `ephemeral`：不回写、不落盘（原生镜像作为唯一兜底依然生效，但不持久化）。
public final class GameSettingsMirror: @unchecked Sendable {
    /// 单条 value 超过该长度的一般是资源缓存而非配置，不做镜像。
    public static let maxMirroredValueLength = 262_144

    private let directoryURL: URL
    private let queue = DispatchQueue(label: "com.xyzw.gamelobby.gamessettings")
    private var mirror: [String: [String: String]] = [:]
    private var flushWork: [String: DispatchWorkItem] = [:]
    private var loadedPartitions: Set<String> = []
    private let policyProvider: @Sendable () -> GameStoragePolicy

    public init(directoryURL: URL = LobbyConfiguration.gameSettingsDirectory,
                policyProvider: @escaping @Sendable () -> GameStoragePolicy = { GameStoragePolicy.current() }) {
        self.directoryURL = directoryURL
        self.policyProvider = policyProvider
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.flushAll() }
    }

    // MARK: - 读写

    /// 存储分区键。
    private func partition(for accountID: String) -> String {
        switch policyProvider() {
        case .sharedAcrossAccounts: return "shared"
        case .isolatedPerAccount: return accountID
        case .ephemeral: return "ephemeral"
        }
    }

    private var persistenceEnabled: Bool { policyProvider() != .ephemeral }

    public func snapshot(forAccount accountID: String) -> [String: String] {
        let key = partition(for: accountID)
        return queue.sync {
            loadIfNeeded(key)
            return mirror[key] ?? [:]
        }
    }

    /// `value` 为 nil 表示删除该键。
    public func setValue(_ value: String?, forKey key: String, accountID: String) {
        let partitionKey = partition(for: accountID)
        // 调用方是主线程上的 script message 回调，游戏里点一下按钮就可能写几次
        // storage。这里绝不能 sync——那等于让主线程等一次磁盘 IO，多开时所有
        // 实例的事件回调和渲染一起排队，表现为全体掉帧。
        queue.async {
            self.loadIfNeeded(partitionKey)
            var storage = self.mirror[partitionKey] ?? [:]
            if let value {
                storage[key] = value
            } else {
                storage.removeValue(forKey: key)
            }
            self.mirror[partitionKey] = storage
            self.scheduleFlush(partitionKey)
        }
    }

    /// 用页面里的全量快照替换镜像（关窗前的兜底同步）。
    public func replaceAll(with storage: [String: String], accountID: String) {
        let partitionKey = partition(for: accountID)
        queue.async {
            self.mirror[partitionKey] = storage
            self.loadedPartitions.insert(partitionKey)
            self.scheduleFlush(partitionKey)
        }
    }

    public func flush(accountID: String) {
        let partitionKey = partition(for: accountID)
        queue.sync { write(partitionKey) }
    }

    public func flushAll() {
        queue.sync { mirror.keys.forEach(write) }
    }

    // MARK: - 注入脚本

    /// 文档创建之前把上次保存的配置写回 localStorage。
    ///
    /// 共享模式直接覆盖本地值（保证「一个账号改过，所有账号都跟着变」，
    /// 也顺便统一掉从隔离模式切过来时残留的旧值）；隔离模式只补缺失的键，
    /// 避免覆盖本次会话中更新的值。
    public func restoreScript(forAccount accountID: String) -> String {
        guard persistenceEnabled else { return "" }
        let entries = snapshot(forAccount: accountID)
        guard !entries.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: entries),
              let json = String(data: data, encoding: .utf8) else { return "" }
        let overwrite = policyProvider() == .sharedAcrossAccounts ? "true" : "false"
        return """
        (() => {
          const overwrite = \(overwrite);
          const saved = \(json);
          try {
            for (const key of Object.keys(saved)) {
              try { if (overwrite || window.localStorage.getItem(key) === null) window.localStorage.setItem(key, saved[key]); } catch (ignored) {}
            }
          } catch (ignored) {}
        })();
        """
    }

    /// Hook `Storage.prototype`，页面每次写 localStorage 都实时回传原生。
    /// 通道名来自页面桥契约（见 LobbyConfiguration.webChannelName）。
    public static var mirrorScript: String {
        """
        (() => {
          const limit = \(maxMirroredValueLength);
          const channel = '\(LobbyConfiguration.webChannelName)';
          const post = (payload) => { try { window.webkit.messageHandlers[channel].postMessage(payload); } catch (ignored) {} };
          const nativeSetItem = Storage.prototype.setItem;
          const nativeRemoveItem = Storage.prototype.removeItem;
          Storage.prototype.setItem = function (key, value) {
            try {
              const text = String(value);
              if (text.length <= limit) post({ type: 'storage', op: 'set', key: String(key), value: text });
            } catch (ignored) {}
            return nativeSetItem.apply(this, arguments);
          };
          Storage.prototype.removeItem = function (key) {
            try { post({ type: 'storage', op: 'remove', key: String(key) }); } catch (ignored) {}
            return nativeRemoveItem.apply(this, arguments);
          };
        })();
        """
    }

    // MARK: - 内部

    private func fileURL(for partition: String) -> URL {
        let invalid = CharacterSet(charactersIn: "/\\:").union(.newlines).union(.controlCharacters)
        let name = partition.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }.joined()
        return directoryURL.appendingPathComponent((name.isEmpty ? "default" : name) + ".json")
    }

    private func loadIfNeeded(_ partition: String) {
        guard !loadedPartitions.contains(partition) else { return }
        loadedPartitions.insert(partition)
        guard persistenceEnabled,
              let data = try? Data(contentsOf: fileURL(for: partition)),
              let object = try? JSONSerialization.jsonObject(with: data),
              let storage = object as? [String: String] else { return }
        mirror[partition] = storage
    }

    private func scheduleFlush(_ partition: String) {
        guard persistenceEnabled else { return }
        flushWork[partition]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write(partition) }
        flushWork[partition] = work
        queue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func write(_ partition: String) {
        guard persistenceEnabled,
              let storage = mirror[partition], !storage.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: storage) else { return }
        try? data.write(to: fileURL(for: partition), options: .atomic)
    }
}
