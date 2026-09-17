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
/// - `sharedAcrossAccounts`：所有账号共用 `shared.json`（共享池）；
/// - `isolatedPerAccount`：按账号各一份 `<账号>.json`；
/// - `ephemeral`：不回写、不落盘（原生镜像作为唯一兜底依然生效，但不持久化）。
///
/// ⚠️ **登录关键键永不进镜像、永不还原**（`serverId` / `uid` / `puid` /
/// `__lobby*` 前缀，见 `isLoginCritical`）。教训（2026-09-18，log.txt/log2.txt）：
/// 镜像曾把「游戏内切服写的 serverId」连同第三方脚本的跨角色状态一起落盘，
/// 下次启动还原回来就是**别的 bin 的区**；配合钉住脚本的时序差，页面会带着
/// 别人的 serverId 去请求认证 → 同账号多 bin 落到同一个区 → 服务端顶号。
/// serverId 的归属由引导脚本的「钉回凭据区」唯一负责，镜像层不再插手。
///
/// ⚠️ **共享池只补缺、不覆盖**。历史版本在共享模式下整包覆盖各账号的
/// localStorage，等于把「上一个活跃账号的整份状态」（含角色态）灌进所有账号
/// ——这正是多开互相顶号的帮凶。改为补缺后语义是：**新账号 / 丢键的账号继承
/// 共享配置，老账号自己的值永不被别人覆盖**（设置同步以账号自身为准）。
public final class GameSettingsMirror: @unchecked Sendable {
    /// 单条 value 超过该长度的一般是资源缓存而非配置，不做镜像。
    public static let maxMirroredValueLength = 262_144

    /// 登录 / 宿主关键键：**永不镜像、永不还原**。
    ///
    /// · `serverId`：游戏的切服目标（裸键，`LoginManager._authUser` 读它拼进
    ///   authuser 参数）。宿主在每次会话首载时把它钉回凭据自带区——镜像若把它
    ///   还原回来（时序上或脚本再写之前），就是拿别的 bin 的区覆盖本 bin 归属。
    /// · `uid` / `puid`：切服确认回调写的账号 / 平台标识（裸键），跨账号还原
    ///   等于让页面以别人的身份恢复会话。
    /// · `__lobby` 前缀：宿主内部哨兵（如 `__lobbyServerIdPinned`），
    ///   曾被 Storage 钩子误捕进共享池。
    public static func isLoginCritical(_ key: String) -> Bool {
        key == "serverId" || key == "uid" || key == "puid" || key.hasPrefix("__lobby")
    }

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
    /// 登录关键键直接丢弃（见 `isLoginCritical`）——它们不进镜像，也就永远不会
    /// 被还原回页面。
    public func setValue(_ value: String?, forKey key: String, accountID: String) {
        guard !Self.isLoginCritical(key) else { return }
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
    /// 快照里混进的登录关键键同样剔除（与 `setValue` 的捕获过滤对齐）。
    public func replaceAll(with storage: [String: String], accountID: String) {
        let partitionKey = partition(for: accountID)
        let filtered = storage.filter { !Self.isLoginCritical($0.key) }
        queue.async {
            self.mirror[partitionKey] = filtered
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
    /// ⚠️ **一律只补缺失的键，不覆盖已有值**（历史版本在共享模式下会整包覆盖
    /// ——那等于把共享池里「上一个活跃账号的状态」灌进所有账号，是多开互顶的
    /// 帮凶之一，已废）。两种模式的行为差异只剩分区来源：
    /// 共享池（新账号继承全账号配置）/ 账号自己的分区。
    /// 登录关键键在还原侧再滤一次：磁盘上历史版本落盘的镜像文件里就存着
    /// 串了区的 `serverId`（实测 41石大.bin.json 存着 42石二 的 14028），
    /// 不过滤的话毒数据会一直复活。
    public func restoreScript(forAccount accountID: String) -> String {
        guard persistenceEnabled else { return "" }
        let entries = snapshot(forAccount: accountID)
            .filter { !Self.isLoginCritical($0.key) }
        guard !entries.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: entries),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return """
        (() => {
          const saved = \(json);
          try {
            for (const key of Object.keys(saved)) {
              try { if (window.localStorage.getItem(key) === null) window.localStorage.setItem(key, saved[key]); } catch (ignored) {}
            }
          } catch (ignored) {}
        })();
        """
    }

    /// Hook `Storage.prototype`，页面每次写 localStorage 都实时回传原生。
    /// 通道名来自页面桥契约（见 LobbyConfiguration.webChannelName）。
    ///
    /// ⚠️ 登录关键键（`serverId` / `uid` / `puid` / `__lobby*`）在页面侧就不上报：
    /// 与原生 `setValue` / `restoreScript` 的过滤是同一条规则的三道闸。
    public static var mirrorScript: String {
        """
        (() => {
          const limit = \(maxMirroredValueLength);
          const channel = '\(LobbyConfiguration.webChannelName)';
          const unmirrored = (key) => key === 'serverId' || key === 'uid' || key === 'puid'
            || String(key).indexOf('__lobby') === 0;
          const post = (payload) => { try { window.webkit.messageHandlers[channel].postMessage(payload); } catch (ignored) {} };
          const nativeSetItem = Storage.prototype.setItem;
          const nativeRemoveItem = Storage.prototype.removeItem;
          Storage.prototype.setItem = function (key, value) {
            try {
              const name = String(key);
              const text = String(value);
              if (text.length <= limit && !unmirrored(name)) post({ type: 'storage', op: 'set', key: name, value: text });
            } catch (ignored) {}
            return nativeSetItem.apply(this, arguments);
          };
          Storage.prototype.removeItem = function (key) {
            try { if (!unmirrored(String(key))) post({ type: 'storage', op: 'remove', key: String(key) }); } catch (ignored) {}
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
