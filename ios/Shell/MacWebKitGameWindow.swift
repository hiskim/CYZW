#if os(macOS)
import AppKit
import CryptoKit
import Foundation
import SwiftUI
import WebKit

/// SwiftUI bridge used by the macOS multi-open matrix. Each representable
/// creates a fresh `MacWebKitGameView`, and therefore a fresh non-persistent
/// website data store and isolated game session. The matrix is the 多开
/// environment, so script injection respects the 多开全局门禁.

/// Owns the `MacWebKitGameView` instances for the multi-open matrix.
///
/// A `WKWebView` is not a cheap view: it carries its own WebGL context, GPU
/// backing store and a fully booted Cocos game. When the SwiftUI cell that
/// hosts it is torn down, `dismantleNSView` used to call `stop()`, which
/// destroyed all of that. Scrolling a card out of the matrix — or any
/// layout/sidebar change that made SwiftUI rebuild the cell — therefore
/// restarted the whole game, and switching back showed a half-loaded scene:
/// missing UI textures and a canvas still sized for the previous cell.
///
/// The pool keeps ownership of the game view, so SwiftUI can create and tear
/// down its cell as often as it likes without the game noticing: the cell is
/// handed the same live view every time, and `dismantleNSView` deliberately
/// does nothing. The real teardown happens once, when the instance is closed
/// for good or the user asks for a fresh login.
///
/// Main-thread only (same contract as `MacGameInstanceRegistry`).
final class MacGameInstancePool {
    static let shared = MacGameInstancePool()

    private var surfaces: [String: MacWebKitGameView] = [:]
    /// 标记哪些账号点过"重新登录"——下一次 `surface(for:)` 拿到这个标记就会
    /// 先把旧实例 stop 掉再返回新实例。这里**不能**立刻 stop：旧 view 还挂在
    /// SwiftUI 旧宿主里，立刻 stop 等于在 WKWebView 还嵌在窗口层级、WKNavigation
    /// 仍在飞的时候把它抽走，老 navigation 既收不到 didFail、也不会立刻停，
    /// 紧接着 SwiftUI 重建宿主、新 view 的 start() 会被同窗口里的旧资源卡住。
    /// 延迟到 SwiftUI 拆除旧宿主之后（也就是下次 bind 发生时）才 stop，
    /// 整条生命周期就跟当初没有 pool 时的 reload 行为完全一致。
    private var reloadPending: Set<String> = []

    /// The live surface for `account`, created and booted on first use.
    /// Repeated calls return the same instance, so rebuilding a cell never
    /// restarts the game — unless the user explicitly requested a reload.
    func surface(for account: Account, environment: ScriptEnvironment = .multi) -> MacWebKitGameView {
        if reloadPending.remove(account.id) != nil,
           let old = surfaces.removeValue(forKey: account.id) {
            old.removeFromSuperview()
            old.stop()
        }
        if let existing = surfaces[account.id] {
            // 池化实例重新挂回 SwiftUI：`start()` 不会再跑，帧率角标这类
            // 「运行时开关」状态必须在这里补一次，否则开关开着也不会显示。
            existing.syncFrameRateHUD()
            return existing
        }
        let view = MacWebKitGameView(account: account, scriptEnvironment: environment)
        surfaces[account.id] = view
        view.start()
        return view
    }

    func existingSurface(forAccountID accountID: String) -> MacWebKitGameView? {
        surfaces[accountID]
    }

    /// 由"重新登录"按钮调用：仅记录意图，真正的销毁推迟到 SwiftUI 拆除旧格子
    /// 之后、下一次 `surface(for:)` 时执行。
    func requestReload(accountID: String) {
        reloadPending.insert(accountID)
    }

    /// Genuine teardown: the instance is being closed.
    func destroy(accountID: String) {
        guard let view = surfaces.removeValue(forKey: accountID) else { return }
        view.removeFromSuperview()
        view.stop()
    }
}

/// 矩阵格子：直接把池里的 `MacWebKitGameView` 交给 SwiftUI。
///
/// 曾经在这中间套过一层 `MacGameSurfaceHostView` 做「借用」，但那层额外的
/// layer-backed 容器既挡住了尺寸传递（Cocos 拿到 0×0 canvas），又挡住了合成
/// （尺寸对了仍黑屏）。改回直接返回：SwiftUI 自己持有并布局游戏视图，
/// 层级与最初能正常渲染时完全一致；保活靠 `dismantleNSView` 里什么都不做——
/// 格子被销毁时视图只是脱离了层级，实例仍然活着，下次 `makeNSView` 直接复用。
struct MacEmbeddedGameView: NSViewRepresentable {
    let account: Account

    func makeNSView(context: Context) -> MacWebKitGameView {
        MacGameInstancePool.shared.surface(for: account, environment: .multi)
    }

    func updateNSView(_ nsView: MacWebKitGameView, context: Context) {}

    static func dismantleNSView(_ nsView: MacWebKitGameView, coordinator: ()) {
        // 不 stop、不 removeFromSuperview（SwiftUI 自己会摘）。
        // 滚动 / 重排 / 侧栏收放导致的格子销毁不能拆掉 WebKit 实例，
        // 否则切回来就要重新加载整局游戏。
        // 真正的销毁只在关闭实例和「重新登录」时由池执行。
    }
}

@MainActor
enum MacWebKitGameWindowController {
    private static var windows: [UUID: NSWindowController] = [:]

    static func open(account: Account) {
        let identifier = UUID()
        let gameView = MacWebKitGameView(account: account)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = account.nickname + " - WebKit"
        window.minSize = NSSize(width: 900, height: 600)
        window.center()
        window.contentView = gameView
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        windows[identifier] = controller
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                gameView.stop()
                windows.removeValue(forKey: identifier)
            }
        }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        gameView.start()
    }
}

// MARK: - 游戏内设置持久化

/// 游戏实例的持久化 website data store。
///
/// `.nonPersistent()` 让 localStorage 只活在内存里，游戏内的省电模式等配置
/// （写入 `window.localStorage` / `cc.sys.localStorage`）关掉窗口就回到默认值；
/// `.default()` 则会和 App 内其它网页内容混在一起。
///
/// 默认**所有账号共用一份**：游戏设置本来就该全局一致（真机也是一个 App 一份
/// localStorage，切换账号时由游戏自己按 uid 区分数据），没必要每账号存一份。
private enum MacGameDataStore {
    /// 紧急回退开关：默认开启持久化。若某个游戏版本因为复用本地会话缓存导致
    /// 登录异常，可执行
    /// `defaults write com.xyzw.ios2.webkit.macos ios2.gameStorage.persistentDataStore -bool false`
    /// 退回旧的 non-persistent 行为（此时仍由原生镜像层保证配置不丢）。
    static let persistentStoreEnabledKey = "ios2.gameStorage.persistentDataStore"

    /// 默认开启：所有账号共享同一份游戏内配置。设为 false 则退回「每账号独立」。
    /// `defaults write com.xyzw.ios2.webkit.macos ios2.gameStorage.sharedAcrossAccounts -bool false`
    static let sharedAcrossAccountsKey = "ios2.gameStorage.sharedAcrossAccounts"

    /// 是否所有账号共用一份游戏内配置。
    static var isShared: Bool {
        UserDefaults.standard.object(forKey: sharedAcrossAccountsKey) as? Bool ?? true
    }

    static func store(forAccountID accountID: String) -> WKWebsiteDataStore {
        let defaults = UserDefaults.standard
        let persisted = defaults.object(forKey: persistentStoreEnabledKey) as? Bool ?? true
        guard persisted else { return .nonPersistent() }
        // 共享模式：所有账号同一个存储区，配置在一个账号里改过，其余账号同生效。
        let seed = isShared ? "shared-game-store" : accountID
        return WKWebsiteDataStore(forIdentifier: stableUUID(from: seed))
    }

    /// 由账号名确定性地派生 UUID，保证同一账号每次启动拿到同一个存储区。
    private static func stableUUID(from seed: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("ios2-game-store-" + seed).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40   // UUID version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        let bridged = bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) }
        return UUID(uuidString: bridged.uuidString) ?? UUID()
    }
}

/// 游戏 localStorage 的原生镜像（`Application Support/GameStorage/shared.json`）。
///
/// 这是持久化 data store 之外的第二层保险：游戏跑在自定义 scheme
/// `ios2-game://` 上，WebKit 对这类 origin 的 localStorage 落盘策略不稳定，
/// 所以页面每次写 `localStorage` 都实时回传原生并节流落盘；下次登录在文档
/// 创建之前把镜像写回 `localStorage`，配置就不会再回到默认值。
///
/// 镜像默认**所有账号共用一份**（与 WebKit 存储区口径一致），游戏内设置改一次
/// 全账号生效；把 `ios2.gameStorage.sharedAcrossAccounts` 设为 false 可退回
/// 每个账号各存一份。
final class MacGameSettingsStore: @unchecked Sendable {
    static let shared = MacGameSettingsStore()

    /// 单条 value 超过该长度的一般是资源缓存而非配置，不做镜像。
    static let maxMirroredValueLength = 262_144

    private let directoryURL: URL
    private let queue = DispatchQueue(label: "com.xyzw.ios2.gamestorage")
    private var mirror: [String: [String: String]] = [:]
    private var flushWork: [String: DispatchWorkItem] = [:]
    private var loadedAccounts: Set<String> = []

    private init() {
        let fileManager = FileManager.default
        var appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if appSupport == nil {
            let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
            appSupport = library.appendingPathComponent("Application Support", isDirectory: true)
        }
        directoryURL = appSupport!.appendingPathComponent("GameStorage", isDirectory: true)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.flushAll() }
        mergeLegacyPerAccountFilesIfNeeded()
    }

    // MARK: 读写

    /// 存储分区：默认所有账号共用一份；关闭共享开关后按账号各自一份。
    private func partition(for accountID: String) -> String {
        MacGameDataStore.isShared ? "shared" : accountID
    }

    func snapshot(forAccount accountID: String) -> [String: String] {
        let key = partition(for: accountID)
        return queue.sync {
            loadIfNeeded(key)
            return mirror[key] ?? [:]
        }
    }

    /// `value` 为 nil 表示删除该键。
    func setValue(_ value: String?, forKey key: String, accountID: String) {
        let partitionKey = partition(for: accountID)
        queue.sync {
            loadIfNeeded(partitionKey)
            var storage = mirror[partitionKey] ?? [:]
            if let value {
                storage[key] = value
            } else {
                storage.removeValue(forKey: key)
            }
            mirror[partitionKey] = storage
            scheduleFlush(partitionKey)
        }
    }

    /// 用页面里的全量快照替换镜像（关窗前的兜底同步）。
    func replaceAll(with storage: [String: String], accountID: String) {
        let partitionKey = partition(for: accountID)
        queue.sync {
            mirror[partitionKey] = storage
            loadedAccounts.insert(partitionKey)
            scheduleFlush(partitionKey)
        }
    }

    func flush(accountID: String) {
        let partitionKey = partition(for: accountID)
        queue.sync { write(partitionKey) }
    }

    func flushAll() {
        queue.sync { mirror.keys.forEach(write) }
    }

    // MARK: 注入脚本

    /// 文档创建之前把上次保存的配置写回 localStorage。
    ///
    /// 共享模式下直接覆盖本地值，保证「一个账号改过，所有账号都跟着变」，
    /// 也顺便把从每账号独立模式切过来时残留的旧值统一掉；
    /// 独立模式只补本地缺失的键，避免覆盖本次会话中更新的值。
    func restoreScript(forAccount accountID: String) -> String {
        let entries = snapshot(forAccount: accountID)
        guard !entries.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: entries),
              let json = String(data: data, encoding: .utf8) else { return "" }
        let overwrite = MacGameDataStore.isShared ? "true" : "false"
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
    static let mirrorScript = """
    (() => {
      const limit = \(maxMirroredValueLength);
      const post = (payload) => { try { window.webkit.messageHandlers.ios2Game.postMessage(payload); } catch (ignored) {} };
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

    // MARK: 私有实现

    /// 从「每账号一份」切到「全局共享」时，把已有的账号镜像合并进 shared.json，
    /// 免得用户刚设好的配置看起来又没了。只在 shared.json 还不存在时跑一次。
    private func mergeLegacyPerAccountFilesIfNeeded() {
        guard MacGameDataStore.isShared else { return }
        let sharedURL = fileURL(for: "shared")
        guard !FileManager.default.fileExists(atPath: sharedURL.path),
              let files = try? FileManager.default.contentsOfDirectory(at: directoryURL,
                                                                      includingPropertiesForKeys: nil) else { return }
        var merged: [String: String] = [:]
        for file in files where file.pathExtension == "json" && file.lastPathComponent != "shared.json" {
            guard let data = try? Data(contentsOf: file),
                  let storage = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { continue }
            merged.merge(storage) { _, latest in latest }
        }
        guard !merged.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: merged) else { return }
        try? data.write(to: sharedURL, options: .atomic)
        MacLog.info("[ios2-macos] migrated %d legacy game settings into shared.json", merged.count)
    }

    private func fileURL(for partition: String) -> URL {
        let invalid = CharacterSet(charactersIn: "/\\:").union(.newlines).union(.controlCharacters)
        let name = partition.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }.joined()
        return directoryURL.appendingPathComponent((name.isEmpty ? "default" : name) + ".json")
    }

    private func loadIfNeeded(_ partition: String) {
        guard !loadedAccounts.contains(partition) else { return }
        loadedAccounts.insert(partition)
        guard let data = try? Data(contentsOf: fileURL(for: partition)),
              let object = try? JSONSerialization.jsonObject(with: data),
              let storage = object as? [String: String] else { return }
        mirror[partition] = storage
    }

    private func scheduleFlush(_ partition: String) {
        flushWork[partition]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write(partition) }
        flushWork[partition] = work
        queue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func write(_ partition: String) {
        guard let storage = mirror[partition], !storage.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: storage) else { return }
        try? data.write(to: fileURL(for: partition), options: .atomic)
    }
}

final class MacWebKitGameView: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    private let account: Account
    /// 脚本运行环境：独立窗口 = 单开，多开矩阵实例 = 多开。
    /// 决定注入哪些脚本（单开生效 / 单多开生效）以及是否受多开门禁约束。
    private let scriptEnvironment: ScriptEnvironment
    private let instanceID = UUID().uuidString
    private var authenticatedAccountID = ""
    private let schemeHandler = MacGameSchemeHandler()
    private lazy var webView: WKWebView = makeWebView()
    private let loadingOverlay = NSView()
    private let loadingSpinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "正在准备游戏资源…")
    private var gameSessionStarted = false
    private var startupTask: Task<Void, Never>?
    private var storageSyncTask: Task<Void, Never>?
    private var isStopped = false

    /// 游戏内设置的存储分区：默认所有账号共用一份（"shared"），
    /// 关闭共享开关后按 `Account.id`（= 账号文件名，跨启动稳定）各自一份。
    private var accountStorageKey: String { account.id }

    /// 兜底尺寸（9:16）。Cocos 在文档 boot 阶段就读 window.innerWidth/Height
    /// 决定 canvas 尺寸，WKWebView 一旦以 0×0 起步，它就会建一个 0×0 的
    /// canvas 且不会自己恢复——游戏逻辑照跑，画面永远是黑的（重载尤其容易踩：
    /// CDN 缓存全热，页面 700ms 就起来，AppKit 还没来得及做 layout）。
    /// 所以这里绝不能从 .zero 起步。
    private static let fallbackSize = NSSize(width: 270, height: 480)

    init(account: Account, scriptEnvironment: ScriptEnvironment = .single) {
        self.account = account
        self.scriptEnvironment = scriptEnvironment
        super.init(frame: NSRect(origin: .zero, size: Self.fallbackSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(webView)
        webView.frame = bounds

        // Do not leave an empty white WebKit surface visible while the shared
        // CDN warm-up and account authentication are in flight.
        loadingOverlay.wantsLayer = true
        loadingOverlay.layer?.backgroundColor = NSColor(calibratedRed: 0.063, green: 0.075, blue: 0.094, alpha: 1).cgColor
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(loadingOverlay)

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingSpinner.isIndeterminate = true
        loadingSpinner.startAnimation(nil)
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(loadingSpinner)

        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.font = .systemFont(ofSize: 14)
        loadingLabel.alignment = .center
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(loadingLabel)

        NSLayoutConstraint.activate([
            loadingOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            loadingOverlay.topAnchor.constraint(equalTo: topAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            loadingSpinner.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor, constant: -14),
            loadingLabel.topAnchor.constraint(equalTo: loadingSpinner.bottomAnchor, constant: 12),
            loadingLabel.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor)
        ])
        // 登记到群控注册表：中控只认账号 ID，实例的 JS 注入全靠它寻址。
        MacGameInstanceRegistry.shared.register(self, accountID: account.id)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        stop()
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    /// AppKit 通过 autoresizing mask 改 subview 尺寸时**不会**调用 subview 的
    /// `layout()`。矩阵格子里这一层是宿主视图直接赋 frame，走的正是那条路径，
    /// 只靠 `layout()` 会让 WKWebView 一直停在 init 时的尺寸（重载时是 0×0）。
    /// 这里补一道，任何尺寸变化都把 WKWebView 钉回 bounds；零尺寸一律忽略，
    /// 避免 SwiftUI 布局过程中的瞬时 0×0 把画布清零。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize.width > 0.5, newSize.height > 0.5 else { return }
        webView.frame = bounds
    }

    // MARK: 键鼠同步

    /// 向本实例的页面注入 JS（群控中控用：回放事件 / 切换捕获开关）。
    func evaluateJavaScript(_ script: String, completion: ((Error?) -> Void)? = nil) {
        webView.evaluateJavaScript(script) { _, error in completion?(error) }
    }

    /// 注入**异步** JS 并取回返回值。
    ///
    /// `callAsyncJavaScript` 会把脚本当 async 函数体执行并自动 await 返回的
    /// Promise，所以帧率自检那种「采样 1 秒再回传」的脚本只能走这条通道——
    /// 普通的 `evaluateJavaScript` 拿不到 Promise 的结果。
    func evaluateAsync(_ script: String) async throws -> String? {
        // WebKit 把 completion 版本 refine 成了 async 版本，这里只能用 await 形式。
        let value = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        return value as? String
    }

    /// 抢焦点：键盘事件只会派发给第一响应者，主窗口必须是它。
    func focusWebView() {
        guard let window = webView.window ?? window else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
    }

    func start() {
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Do not wait for the optional full CDN prefetch here. The
                // manifest request and account authentication can begin
                // immediately; remaining resources are cached lazily by the
                // scheme handler while the game is already visible.
                let manifest = try? await MacCDNResourceManager.shared.latestManifest()
                guard !isStopped else { return }
                loadingLabel.stringValue = "正在登录游戏…"
                MacLog.info("[ios2-macos] account authentication started: %@", account.fileName)
                let authentication = try await MacWebKitAuth.authenticate(account: account, manifest: manifest)
                MacLog.info("[ios2-macos] account authentication complete: %@", account.fileName)
                await MacCDNResourceManager.shared.beginGameSession()
                gameSessionStarted = true
                authenticatedAccountID = authentication.accountID
                schemeHandler.setBundleVersions(authentication.bundleVersions)
                webView.configuration.userContentController.addUserScript(
                    WKUserScript(source: bootstrapScript(authResponse: authentication.authResponse,
                                                         manifestJSON: authentication.manifestJSON),
                                  injectionTime: .atDocumentStart, forMainFrameOnly: true)
                )
                // 帧率采样器：始终装上，「校验」按钮和角标都靠它读主循环计数。
                // 跟 bootstrap 一样每次进游戏前登记（实例视图是池化复用的，
                // 视图创建时读开关会拿到过期值）。引擎还没初始化时靠 50ms 轮询重试。
                webView.configuration.userContentController.addUserScript(
                    WKUserScript(source: MacFrameRateHUD.samplerScript,
                                 injectionTime: .atDocumentStart, forMainFrameOnly: true)
                )
                // 帧率角标（默认关闭）：开关开着就随文档就绪装上显示层。
                if MacFrameRateHUD.isEnabled {
                    MacLog.debug("[ios2-macos] frame rate HUD enabled, injecting overlay")
                    webView.configuration.userContentController.addUserScript(
                        WKUserScript(source: MacFrameRateHUD.overlayShowScript,
                                     injectionTime: .atDocumentEnd, forMainFrameOnly: true)
                    )
                }
                // 注入启用中的 JS 脚本（iOS 版 _enabledScriptRecords 的语义）：
                // 总开关关闭 → 不注入任何脚本；多开实例还要过「多开全局门禁」；
                // 按脚本自身状态过滤（单开生效 / 单多开生效 / 禁用）。
                let scriptRecords = ScriptManager.shared.enabledScripts(for: scriptEnvironment)
                for record in scriptRecords {
                    guard let source = ScriptManager.shared.scriptSource(named: record.name),
                          !source.isEmpty else {
                        MacLog.warn("[ios2-macos] user script skipped (unreadable): %@", record.name)
                        continue
                    }
                    webView.configuration.userContentController.addUserScript(
                        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
                    )
                    MacLog.info("[ios2-macos] user script injected: %@ (%@)",
                                record.name, scriptEnvironment == .single ? "single" : "multi")
                }
                let entry = URL(string: "ios2-game://app/index.html?revision=macos-webkit-2")!
                MacLog.debug("[ios2-macos] loading WebKit game document: %@", entry.absoluteString)
                webView.load(URLRequest(url: entry))
            } catch {
                guard !isStopped else { return }
                loadingSpinner.stopAnimation(nil)
                loadingLabel.stringValue = "登录失败：\(error.localizedDescription)"
                showError(title: "账号登录失败", message: error.localizedDescription)
            }
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        // 从群控注册表摘除（identity 校验：重载卡片时新视图已登记，不能误删）。
        MacGameInstanceRegistry.shared.unregister(self, accountID: account.id)
        // 关窗前把游戏内配置最后一次同步到磁盘（异步执行，抓不到就算了：
        // 平时的实时回传已经把绝大部分配置写进镜像了）。
        let snapshotWebView = webView
        let accountKey = accountStorageKey
        Task { @MainActor in
            await Self.captureStorageSnapshot(from: snapshotWebView, accountID: accountKey)
        }
        startupTask?.cancel()
        startupTask = nil
        storageSyncTask?.cancel()
        storageSyncTask = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "ios2Game")
        if gameSessionStarted {
            gameSessionStarted = false
            Task { await MacCDNResourceManager.shared.endGameSession() }
        }
    }

    private func makeWebView() -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(self, name: "ios2Game")

        // ① 文档创建之前先把上次保存的游戏配置写回 localStorage。
        let restore = MacGameSettingsStore.shared.restoreScript(forAccount: accountStorageKey)
        if !restore.isEmpty {
            MacLog.debug("[ios2-macos] restoring persisted game settings: %@", accountStorageKey)
            contentController.addUserScript(
                WKUserScript(source: restore, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }
        // ② 之后每一次写入都实时同步到原生镜像，关窗/崩溃都不丢配置。
        contentController.addUserScript(
            WKUserScript(source: MacGameSettingsStore.mirrorScript,
                         injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        // ③ 键鼠同步代理：捕获器 + 回放器 + 波纹特效层。每个实例都装，
        // 谁是主窗口由 MacInputSyncController 用 setCapture(on) 切换
        // （WKUserScript 只能在导航时注入，运行时无法追加，所以必须预先装好）。
        contentController.addUserScript(
            WKUserScript(source: MacInputSyncScript.agent,
                         injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        // 注意：帧率采样器与角标**不在这里**登记——实例视图是池化复用的
        // （`MacGameInstancePool`），视图可能早在开关打开之前就创建好了，
        // 在这里读开关会拿到过期的旧值。两者统一放到 `start()` 里、
        // 跟 bootstrap 一起在每次进入游戏前重新登记。

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "ios2-game")
        // 改为「持久化存储」，且默认所有账号共用一份：non-persistent 会让游戏内
        // 配置（省电模式等）每次登录都回到默认值；.default() 会和 App 内其它网页
        // 内容混在一起。
        configuration.websiteDataStore = MacGameDataStore.store(forAccountID: accountStorageKey)
        configuration.userContentController = contentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let result = WKWebView(frame: .zero, configuration: configuration)
        result.navigationDelegate = self
        result.allowsBackForwardNavigationGestures = false
        // 排查用：打开后可在页面上右键「检查元素」调出 Safari Web Inspector，
        // 直接看到 WebRuntime 打的 `[ios2-web] target frame rate` 等日志。
        // 默认关闭，用 `defaults write com.xyzw.ios2.webkit.macos ios2.debug.webInspector -bool true` 开启。
        result.isInspectable = UserDefaults.standard.bool(forKey: "ios2.debug.webInspector")
        return result
    }

    private func bootstrapScript(authResponse: String, manifestJSON: String) -> String {
        let accountJSON = try? String(data: JSONEncoder().encode(account.nickname), encoding: .utf8)
        let idJSON = try? String(data: JSONEncoder().encode(instanceID), encoding: .utf8)
        let authJSON = try? String(data: JSONEncoder().encode(authResponse), encoding: .utf8)
        let manifestValue: String
        if let data = manifestJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let encoded = try? JSONSerialization.data(withJSONObject: object),
           let value = String(data: encoded, encoding: .utf8) {
            manifestValue = value
        } else {
            manifestValue = "{}"
        }
        // 画质档位来自设置面板（ios2.renderQuality）。WebRuntime 只在场景加载前
        // 读一次，用来决定画布 backing store 的像素比，所以已运行的实例改档位
        // 后需要重新启动才生效。
        let quality = MacRenderQuality.current()
        // 目标帧率来自设置面板（ios2.frameRate）。同样在启动时读一次，
        // 但与画质不同，运行中的实例会被设置面板即时改写——走 MacFrameRate 的
        // 「暂停→等待旧主循环退出→重启」路径，不走 cc.game.setFrameRate（有缺陷）。
        let frameRate = MacFrameRate.current()
        return """
        // 日志配置必须第一个落地：后面所有的 console 调用都要读它决定要不要
        // 回传原生（含本脚本自己打的那一条）。放晚了会漏掉启动期最吵的一段。
        \(MacLogSettings.shared.bootstrapScript)
        window.__IOS2_GAME_INSTANCE__ = {
          id: \(idJSON ?? "\\\"\\\""),
          account: \(accountJSON ?? "\\\"账号\\\""),
          authResponse: \(authJSON ?? "\\\"\\\"") ,
          frameRate: \(frameRate.rawValue),
          qualitySingle: '\(quality.rawValue)',
          qualityMulti: '\(quality.rawValue)',
          // macOS matrix cells are resizable multi-open surfaces. This also
          // enables the web bootstrap's EXACT_FIT policy to avoid side bars.
          multiOpen: true,
          startupMode: 'serial',
          scripts: [],
          manifest: \(manifestValue),
        };
        window.jsb = window.jsb || {};
        window.jsb.reflection = window.jsb.reflection || {};
        window.jsb.reflection.callStaticMethod = function() {
          var args = Array.prototype.slice.call(arguments), klass = args.shift(), method = args.shift();
          if (klass === 'IOS2Native' && method === 'runtimeBackend') return 'webkit';
          // HSDK selects the iOS class only when cc.sys reports iOS. A
          // macOS WebKit page reports macOS, so the same SDK build otherwise
          // falls back to its Android-style class/method pair and the request
          // silently disappears. Accept both native entry points here; the
          // payload format is identical.
          if ((klass === 'SDKMessager' && method === 'callNative:withMessage:') ||
              (klass === 'com/hortorgames/gamesdk/SDKBridge' && method === 'receiveMsgFromHSDK')) {
            var hsdkChannel = method === 'receiveMsgFromHSDK' ? 'sdk' : (args[0] || 'sdk');
            var hsdkMessage = method === 'receiveMsgFromHSDK' ? args[1] : args[1];
            try { window.webkit.messageHandlers.ios2Game.postMessage({type:'hsdk', instance: window.__IOS2_GAME_INSTANCE__.id, channel: hsdkChannel, message: String(hsdkMessage || '{}')}); } catch (error) { console.error(error); }
          }
          return null;
        };
        var __ios2AuthBuffer = null;
        function __ios2AuthBytes() {
          if (__ios2AuthBuffer) return __ios2AuthBuffer.slice(0);
          var binary = atob(window.__IOS2_GAME_INSTANCE__.authResponse || ''), bytes = new Uint8Array(binary.length);
          for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
          __ios2AuthBuffer = bytes.buffer;
          window.__IOS2_GAME_INSTANCE__.authResponse = '';
          return __ios2AuthBuffer.slice(0);
        }
        console.log('[ios2-macos] live manifest injected',
          window.__IOS2_GAME_INSTANCE__.manifest &&
          window.__IOS2_GAME_INSTANCE__.manifest.bundleVers);
        var __ios2NativeXHR = window.XMLHttpRequest;
        function __ios2XHR() {
          this._native = new __ios2NativeXHR(); this._fake = false; this._readyState = 0; this._status = 0;
          this._response = null; this._responseType = ''; this._listeners = {};
          var self = this;
          ['readystatechange','load','error','timeout','abort','loadend','progress'].forEach(function(type) {
            self._native['on' + type] = function(event) { self._emit(type, event); };
          });
        }
        __ios2XHR.prototype.open = function(method, url) {
          this._fake = /\\/login\\/authuser(?:\\?|$)/.test(String(url || ''));
          if (this._fake) { this._readyState = 1; this._emit('readystatechange'); }
          else this._native.open.apply(this._native, arguments);
        };
        __ios2XHR.prototype.send = function(body) {
          if (!this._fake) return this._native.send(body);
          var self = this; setTimeout(function() {
            self._status = 200; self._response = __ios2AuthBytes();
            self._readyState = 2; self._emit('readystatechange');
            self._readyState = 3; self._emit('readystatechange');
            self._readyState = 4; self._emit('readystatechange'); self._emit('load'); self._emit('loadend');
          }, 0);
        };
        __ios2XHR.prototype.abort = function() { if (this._fake) { this._readyState = 0; this._emit('abort'); this._emit('loadend'); } else this._native.abort(); };
        __ios2XHR.prototype.setRequestHeader = function(name, value) { if (!this._fake) this._native.setRequestHeader(name, value); };
        __ios2XHR.prototype.getAllResponseHeaders = function() { return this._fake ? 'Content-Type: application/octet-stream\\r\\n' : this._native.getAllResponseHeaders(); };
        __ios2XHR.prototype.getResponseHeader = function(name) { return this._fake && String(name).toLowerCase() === 'content-type' ? 'application/octet-stream' : (this._fake ? null : this._native.getResponseHeader(name)); };
        __ios2XHR.prototype.overrideMimeType = function(value) { if (!this._fake && this._native.overrideMimeType) this._native.overrideMimeType(value); };
        __ios2XHR.prototype.addEventListener = function(type, listener) { if (typeof listener === 'function') (this._listeners[type] || (this._listeners[type] = [])).push(listener); };
        __ios2XHR.prototype.removeEventListener = function(type, listener) { var list = this._listeners[type] || [], index = list.indexOf(listener); if (index >= 0) list.splice(index, 1); };
        __ios2XHR.prototype._emit = function(type, event) { event = event || {type:type, target:this}; var handler = this['on' + type]; if (typeof handler === 'function') handler.call(this, event); var list = (this._listeners[type] || []).slice(); for (var i = 0; i < list.length; i++) list[i].call(this, event); };
        Object.defineProperties(__ios2XHR.prototype, {
          readyState:{get:function(){return this._fake ? this._readyState : this._native.readyState;}},
          status:{get:function(){return this._fake ? this._status : this._native.status;}},
          statusText:{get:function(){return this._fake ? 'OK' : this._native.statusText;}},
          response:{get:function(){return this._fake ? this._response : this._native.response;}},
          responseText:{get:function(){return this._fake ? '' : this._native.responseText;}},
          responseType:{get:function(){return this._fake ? this._responseType : this._native.responseType;},set:function(value){this._responseType=value||'';if(!this._fake)this._native.responseType=value;}},
          timeout:{get:function(){return this._native.timeout;},set:function(value){this._native.timeout=value;}},
          withCredentials:{get:function(){return this._fake ? false : this._native.withCredentials;},set:function(value){if(!this._fake)this._native.withCredentials=value;}}
        });
        __ios2XHR.UNSENT = 0; __ios2XHR.OPENED = 1; __ios2XHR.HEADERS_RECEIVED = 2; __ios2XHR.LOADING = 3; __ios2XHR.DONE = 4;
        window.XMLHttpRequest = __ios2XHR;
        window.addEventListener('error', function(event) {
          try { window.webkit.messageHandlers.ios2Game.postMessage({type:'error', instance:window.__IOS2_GAME_INSTANCE__.id, message:String(event.error && event.error.stack || event.message || 'Web game error')}); } catch (ignored) {}
        });
        window.addEventListener('unhandledrejection', function(event) {
          try { window.webkit.messageHandlers.ios2Game.postMessage({type:'error', instance:window.__IOS2_GAME_INSTANCE__.id, message:String(event.reason && event.reason.stack || event.reason || 'Unhandled rejection')}); } catch (ignored) {}
        });
        \(MacLogConsoleBridge.script)
        """
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "ios2Game" else { return }
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
            MacLog.warn("[ios2-macos] WebKit event: %@", String(describing: message.body))
            return
        }
        switch type {
        case "hsdk":
            guard let requestJSON = body["message"] as? String else {
                MacLog.error("[ios2-macos] malformed HSDK event: %@", String(describing: body))
                return
            }
            handleHSDKRequest(requestJSON)
        case "input":
            // 键鼠同步：本实例只有被指定为主窗口时才会捕获事件，中控会再校验一次。
            guard let event = MacInputSyncEvent.decode(from: body) else { return }
            MacInputSyncController.shared.publish(event, from: account.id)
        case "storage":
            // 游戏内配置（省电模式等）写入 localStorage 的实时回传，落盘到
            // Application Support/GameStorage/<账号>.json。
            guard let key = body["key"] as? String else { return }
            if (body["op"] as? String) == "remove" {
                MacGameSettingsStore.shared.setValue(nil, forKey: key, accountID: accountStorageKey)
            } else if let value = body["value"] as? String {
                MacGameSettingsStore.shared.setValue(value, forKey: key, accountID: accountStorageKey)
            }
        case "console":
            // 页面侧已经按等级滤过一道（见 MacLogConsoleBridge），这里再判一次
            // 只是兜底：实例重载、旧页面残留都可能带着过期的配置打过来。
            MacLog.log(MacLogLevel.level(forJSLevel: body["level"] as? String),
                       "[ios2-macos] JS %@: %@",
                       body["level"] as? String ?? "log",
                       body["message"] as? String ?? "")
        case "memory":
            MacLog.debug("[ios2-macos] Web runtime memory (%@, %@): assets=%@ nodes=%@",
                         body["reason"] as? String ?? "sample",
                         body["phase"] as? String ?? "sample",
                         String(describing: body["assets"] ?? "?"),
                         String(describing: body["nodes"] ?? "?"))
        case "graphics":
            MacLog.warn("[ios2-macos] WebGL %@: %@",
                        body["event"] as? String ?? "event",
                        body["message"] as? String ?? "")
        case "error":
            MacLog.error("[ios2-macos] JS error: %@", body["message"] as? String ?? "Unknown error")
        case "frameRate":
            // 页面里任何 cc.game.setFrameRate 调用都会打到这里（含调用栈），
            // 用来定位"设置 90 却被改成 30"是谁干的。
            MacLog.debug("[ios2-macos] frame rate write: fps=%@ stack=%@",
                         String(describing: body["fps"] ?? "?"),
                         String(describing: body["stack"] ?? "?"))
        case "frameRateBlocked":
            // 游戏 bundle 登录时会把自己的默认值（30）塞进来，与用户设定不符时拦下。
            MacLog.info("[ios2-macos] frame rate blocked: 游戏要 %@ / 保持用户设定 %@",
                        String(describing: body["fps"] ?? "?"),
                        String(describing: body["preferred"] ?? "?"))
        case "frameRateRestore":
            // 登录后按 0 / 500 / 2000ms 三次把帧率拉回用户设定。
            MacLog.debug("[ios2-macos] frame rate restore: %@ (%@)",
                         String(describing: body["fps"] ?? "?"),
                         String(describing: body["reason"] ?? "?"))
        default:
            MacLog.debug("[ios2-macos] WebKit event: %@", String(describing: body))
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        showNavigationError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        showNavigationError(error)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadingOverlay.isHidden = true
        MacLog.info("[ios2-macos] WebKit game document loaded")
        // 页面就绪后把「是否为主窗口」写回页面：WKUserScript 在导航时已注入代理，
        // 但捕获开关是运行时状态（重载/新建实例都必须补一次）。
        MacInputSyncController.shared.refreshCapture(forAccountID: account.id)
        self.evaluateJavaScript(MacInputSyncScript.setRipple(MacInputSyncController.shared.showsRipple))
        // 帧率角标同理：开关是运行时状态，光靠 WKUserScript 不可靠
        // （池化实例重载 / 复用时文档已经加载过，注入时机对不上）。
        syncFrameRateHUD()
        startStorageSync()
    }

    /// 按当前设置同步帧率角标（显示 / 隐藏）。
    ///
    /// 两个必须补的时机，都走 `evaluateJavaScript`（跟群控捕获开关同款，已验证有效）：
    /// ① `didFinish`——文档加载完；② 池化实例重新挂回 SwiftUI——那种情况
    /// `start()` 不会再跑，WKUserScript 那条路完全没有第二次机会。
    func syncFrameRateHUD() {
        let enabled = MacFrameRateHUD.isEnabled
        evaluateJavaScript(enabled ? MacFrameRateHUD.overlayShowScript
                                  : MacFrameRateHUD.overlayHideScript) { error in
            guard let error else { return }
            MacLog.warn("[ios2-macos] frame rate HUD sync failed: %@", error.localizedDescription)
        }
        guard enabled else { return }
        webView.evaluateJavaScript(MacFrameRateHUD.diagnosticScript) { value, error in
            let payload = (value as? String) ?? "nil / \(error?.localizedDescription ?? "no error")"
            MacLog.debug("[ios2-macos] fps hud diag: %@", payload)
        }
    }

    // MARK: 游戏内设置持久化

    /// 兜底同步：即使实时回传被绕过（例如页面直接改 storage 的内部实现），
    /// 每 20 秒也会把页面里的 localStorage 全量镜像一次到磁盘。
    private func startStorageSync() {
        storageSyncTask?.cancel()
        storageSyncTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, !self.isStopped else { return }
                await Self.captureStorageSnapshot(from: self.webView, accountID: self.accountStorageKey)
            }
        }
    }

    private static func captureStorageSnapshot(from webView: WKWebView, accountID: String) async {
        let script = """
        (() => {
          try {
            const limit = \(MacGameSettingsStore.maxMirroredValueLength);
            const store = window.localStorage;
            const out = {};
            for (let index = 0; index < store.length; index++) {
              const key = store.key(index);
              if (key === null) continue;
              const value = store.getItem(key);
              if (typeof value === 'string' && value.length <= limit) out[key] = value;
            }
            return JSON.stringify(out);
          } catch (error) { return '{}'; }
        })()
        """
        guard let result = try? await webView.evaluateJavaScript(script),
              let json = result as? String,
              let data = json.data(using: .utf8),
              let storage = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              !storage.isEmpty else { return }
        MacGameSettingsStore.shared.replaceAll(with: storage, accountID: accountID)
        MacGameSettingsStore.shared.flush(accountID: accountID)
    }

    private func showNavigationError(_ error: Error) {
        loadingSpinner.stopAnimation(nil)
        loadingLabel.stringValue = "游戏页面加载失败：\(error.localizedDescription)"
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window ?? NSApp.mainWindow ?? NSWindow())
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window ?? NSApp.mainWindow ?? NSWindow())
    }

    private func handleHSDKRequest(_ requestJSON: String) {
        guard let data = requestJSON.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = request["action"] as? String else { return }
        let extra = request["extra"] as? [String: Any] ?? [:]
        MacLog.debug("[ios2-macos] HSDK request: %@", action)
        let responseExtra: [String: Any]
        switch action {
        case "game-init":
            responseExtra = ["gameID": "xyzw_mix", "env": 0, "gameVersion": "0.33.0-ios",
                             "channel": "AppStore", "distinctId": accountID(),
                             "deviceInfo": deviceInfo()]
        case "user_login_show_dialog", "user-tokenlogin", "user-multi-platform-login":
            // The selected .bin was authenticated before this WebKit instance
            // was created. Match iOS loginForSDK: publish the listener event
            // first, then resolve the SDK login promise.
            sendHSDKMessage(action: "sdk-get-userId",
                            extra: ["userId": accountID(), "uniqueId": accountID()],
                            errorCode: 0)
            sendHSDKMessage(action: action, extra: [:], errorCode: 0)
            return
        case "user-logout":
            sendHSDKMessage(action: action, extra: [:], errorCode: 0)
            sendHSDKMessage(action: "user-logout-from-sdk", extra: [:], errorCode: 0)
            return
        case "sdk-get-device-info":
            responseExtra = ["deviceUniqueId": accountID(), "gameId": "xyzw_mix", "gameTp": "ios",
                             "uniqueId": accountID(), "sysInfo": deviceInfo()]
        case "sdk-get-userId", "user-getuserinfo":
            responseExtra = ["userId": accountID(), "uniqueId": accountID()]
        case "get-check-switchs":
            let switchIDs = extra["switchIdList"] as? [Any] ?? []
            let values = switchIDs.map { value -> Int in
                guard let switchID = value as? String else { return 0 }
                return ["ChatWorldSwitch", "PaySwitch", "FasterSubPage", "ControllerSubPage"].contains(switchID) ? 1 : 0
            }
            responseExtra = ["sequence": extra["sequence"] as? NSNumber ?? 0,
                             "data": values]
        case "sdk-sync-passbord":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString((extra["text"] as? String) ?? (extra["data"] as? String) ?? "", forType: .string)
            responseExtra = [:]
        case "sdk-get-passbord":
            responseExtra = ["text": NSPasteboard.general.string(forType: .string) ?? ""]
        case "game_addiction_quit", "send-url-param", "app-activity-resume", "app-activity-pause",
             "sdk-app-back":
            // These are event/listener registrations on iOS. Replying here
            // would invoke the listener during startup as if the event fired.
            MacLog.debug("[ios2-macos] HSDK listener registered: %@", action)
            return
        default:
            responseExtra = [:]
        }
        sendHSDKMessage(action: action, extra: responseExtra, errorCode: 0)
    }

    private func deviceInfo() -> [String: String] {
        ["deviceSystem": "macOS", "deviceModel": "Mac", "deviceBrand": "Apple",
         "deviceVersion": ProcessInfo.processInfo.operatingSystemVersionString,
         "hortorSDKVersion": "1.4.0", "deviceName": Host.current().localizedName ?? "Mac"]
    }

    private func sendHSDKMessage(action: String, extra: [String: Any], errorCode: Int) {
        let payload: [String: Any] = ["action": action, "meta": ["errCode": errorCode], "extra": extra]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let message = String(data: data, encoding: .utf8),
              // JSONSerialization rejects a top-level Swift String on newer
              // Foundation implementations (and throws an Obj-C exception
              // that Swift try? cannot catch). JSONEncoder safely produces
              // the quoted JS string literal needed by HSDK.onMessage.
              let messageData = try? JSONEncoder().encode(message),
              let argument = String(data: messageData, encoding: .utf8) else { return }
        webView.evaluateJavaScript("if(window.HSDK&&typeof window.HSDK.onMessage==='function'){window.HSDK.onMessage('sdk',\(argument));}else{throw new Error('HSDK.onMessage is unavailable while responding to \(action)');}") { _, error in
            if let error {
                MacLog.error("[ios2-macos] HSDK response %@ failed: %@", action, error.localizedDescription)
            } else {
                MacLog.debug("[ios2-macos] HSDK response sent: %@", action)
            }
        }
    }

    private func accountID() -> String {
        if !authenticatedAccountID.isEmpty { return authenticatedAccountID }
        let digest = SHA256.hash(data: Data(account.fileName.utf8))
        return "ios2-" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

private enum MacWebKitAuth {
    private static let gameServer = "https://xxz-xyzw.hortorgames.com"

    struct Result {
        let authResponse: String
        let accountID: String
        let manifestJSON: String
        let bundleVersions: [String: String]
    }
    enum AuthError: LocalizedError {
        case missingFile
        case invalidResponse(String)
        var errorDescription: String? {
            switch self {
            case .missingFile: return "找不到账号 .bin 文件。"
            case .invalidResponse(let detail): return detail
            }
        }
    }

    static func authenticate(account: Account, manifest: MacCDNManifest? = nil) async throws -> Result {
        // 从沙盒内 Application Support/AccountBins 读取账号文件（AccountFileManager 托管）。
        guard let binData = try? AccountFileManager.shared.readBinData(for: account.fileName),
              !binData.isEmpty else {
            throw AuthError.missingFile
        }
        var request = URLRequest(url: URL(string: "\(gameServer)/login/authuser?_seq=1")!)
        request.httpMethod = "POST"
        request.httpBody = binData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("lx", forHTTPHeaderField: "O4e-Encoding")
        request.setValue("close", forHTTPHeaderField: "Connection")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), data.count > 4 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AuthError.invalidResponse("认证服务返回异常（HTTP \(status)）。")
        }

        let liveManifest: MacCDNManifest
        if let manifest {
            liveManifest = manifest
        } else {
            liveManifest = try await MacCDNResourceManager.shared.latestManifest()
        }
        let bundleVersions = liveManifest.bundleVersions

        let digest = SHA256.hash(data: binData)
        let accountID = "ios2-" + digest.map { String(format: "%02x", $0) }.joined()
        return Result(authResponse: data.base64EncodedString(), accountID: accountID,
                      manifestJSON: liveManifest.json,
                      bundleVersions: bundleVersions)
    }
}

private final class MacGameSchemeHandler: NSObject, WKURLSchemeHandler {
    private let remoteBaseURL = URL(string: "https://xxz-xyzw-res.hortorgames.com")!
    private var bundleVersions: [String: String] = [:]

    func setBundleVersions(_ versions: [String: String]) {
        bundleVersions = versions
        MacLog.info("[ios2-macos] live bundle versions: launcher=%@ game=%@ internal=%@",
                    versions["launcher"] ?? "<missing>",
                    versions["game"] ?? "<missing>",
                    versions["internal"] ?? "<missing>")
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            fail(urlSchemeTask, code: NSURLErrorBadURL)
            return
        }

        if let localURL = localResource(for: requestURL) {
            do {
                try respond(urlSchemeTask, data: Data(contentsOf: localURL), url: requestURL)
            } catch {
                urlSchemeTask.didFailWithError(error)
            }
            return
        }

        guard let remoteURL = remoteResource(for: requestURL) else {
            fail(urlSchemeTask, code: NSURLErrorFileDoesNotExist)
            return
        }
        MacLog.verbose("[ios2-macos] CDN request: %@ -> %@", requestURL.absoluteString, remoteURL.absoluteString)
        Task { @MainActor [weak self] in
            do {
                let data = try await MacCDNResourceManager.shared.data(for: remoteURL, source: "game")
                self?.respond(urlSchemeTask, data: data, url: requestURL)
            } catch {
                MacLog.error("[ios2-macos] CDN error: %@ (%@)", remoteURL.absoluteString, error.localizedDescription)
                self?.fail(urlSchemeTask, code: (error as NSError).code)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // The shared actor may still finish a request for another window.
        // WebKit ignores callbacks for a stopped scheme task, so no per-window
        // cancellation or cache bookkeeping is needed here.
    }

    private func localResource(for url: URL) -> URL? {
        guard url.host == "app", let root = Bundle.main.resourceURL?.appendingPathComponent("WebRuntime") else {
            return nil
        }
        let path = url.path
        let aliases = [
            "/index.html": "src/ios2-web-index.html",
            "/settings.js": "src/settings.b2e22.js",
            "/cocos2d.js": "src/ios2-web-cocos2d.js",
            "/physics.js": "src/ios2-web-physics.js",
            "/boot.js": "src/ios2-web-boot.js",
            "/game-defines.js": "jsb-adapter/game-defines.js"
        ]
        let relativePath: String
        if let alias = aliases[path] {
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
            MacLog.verbose("[ios2-macos] bundle URL rewritten: %@ -> %@", path, components.joined(separator: "/"))
            return components.joined(separator: "/")
        }
        return path
    }

    private func remoteURL(path: String, query: String?) -> URL? {
        var components = URLComponents(url: remoteBaseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.query = query
        return components?.url
    }

    private func respond(_ task: WKURLSchemeTask, data: Data, url: URL) {
        // Fetch/XHR only exposes `ok` and `status` when the custom scheme
        // returns an HTTP response. A plain URLResponse makes a successful
        // CDN download look like status 0 to the WebKit runtime.
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mimeType(for: url.pathExtension),
                "Content-Length": String(data.count),
                "Cache-Control": "no-store"
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask, code: Int) {
        task.didFailWithError(NSError(domain: NSURLErrorDomain, code: code))
    }

    private func mimeType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "html": return "text/html"
        case "js", "mjs", "jsc": return "application/javascript"
        case "json": return "application/json"
        case "css": return "text/css"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        default: return "application/octet-stream"
        }
    }
}
#endif
