import Foundation
import LobbyDomain

/// 实例环境：决定脚本注入面与矩阵口径。
public enum InstanceEnvironment: Sendable {
    /// 独立窗口（单开）。
    case single
    /// 多开矩阵实例。
    case multi
}

/// 生命周期事件回调（实例池 → 上层会话模型）。
@MainActor
public protocol GameInstancePoolDelegate: AnyObject {
    /// 实例渲染完整性连续恶化 / WebGL 丢失，需要整页兜底重载。
    func instancePoolDidRequestReload(accountID: String, reason: String)
    /// 实例启动沉降完成（用于就绪后统一重放焦点能耗策略）。
    func instancePoolDidFinishStartup(accountID: String)
}

/// 游戏视口实例池：拥有全部存活的 `GameViewportInstance`。
///
/// WKWebView 不是廉价视图：它背着自己的 WebGL 上下文、GPU backing store 和
/// 一整局已启动的游戏。SwiftUI 格子被拆掉时如果跟着销毁实例，滚动 / 侧栏收放
/// 就会整局重启。池把所有权拿走之后，SwiftUI 想重建格子多少次都行——格子每次
/// 拿到的是同一个活视图；真正的拆除只发生在「永久关闭」和「重新登录」。
///
/// 关键簿记（全部来自真实事故）：
/// - `reloadPending`：点「重新登录」**不能立刻 stop** 旧实例——旧 view 还挂在
///   SwiftUI 旧宿主里，立刻抽走等于在 WKNavigation 在飞的时候拆视图。延迟到
///   下次 `surface(for:)`（旧宿主已拆除）再 stop，生命周期与无池时完全一致。
/// - `destroyPending`：实例是懒创建的，关闭请求可能跑在创建之前。destroy 意图
///   必须落盘，等创建时补上，否则留下永不被关的孤儿实例（WKWebView + WebGL +
///   整局游戏全泄漏，卡片还挂在矩阵里）。
/// - **启动并发闸门**：一个实例启动要拉 16.6MB bundle、解析几百张 PVR、把纹理
///   逐张上传 GPU。N 个实例同时启动会瞬间打满主线程与 GPU 进程，队尾实例的
///   资源回调排在几百条请求后面——画面上就是「随机几个实例元素不全」。限 2 路
///   既能压峰值又不至于排队太久；ready 迟迟不来（加载失败）也不能把后面的
///   实例永久堵死，90s 超时强制放行。
@MainActor
public final class GameInstancePool {
    public typealias Factory = @MainActor (GameAccount, InstanceEnvironment) -> GameViewportInstance

    private let makeInstance: Factory
    public weak var delegate: GameInstancePoolDelegate?

    private var surfaces: [String: GameViewportInstance] = [:]
    private var reloadPending: Set<String> = []
    private var destroyPending: Set<String> = []

    /// 每个账号的**自动**兜底重载次数。必须记在池里而不是视图里：每次重载都会
    /// 换新视图，视图内计数随之归零，「最多自动重载 N 次」的闸门就失效了。
    private var automaticReloads: [String: Int] = [:]

    // MARK: 启动并发闸门

    private static let concurrentStartupLimit = 2
    private static let startupSlotTimeout: TimeInterval = 90
    private var startupQueue: [GameViewportInstance] = []
    private var startingAccounts: Set<String> = []
    private var startupTimeouts: [String: DispatchWorkItem] = [:]

    public init(factory: @escaping Factory) {
        self.makeInstance = factory
    }

    // 注意：超时工作项以 weak self 捕获，池释放后自然 no-op，无需 deinit 清理
    // （Swift 6.3 下 deinit 是 nonisolated，不能访问 actor 隔离状态）。

    // MARK: - 获取 / 关闭

    /// 账号的存活实例，首次使用时创建并排队启动。重复调用返回同一实例。
    public func surface(for account: GameAccount, environment: InstanceEnvironment = .multi) -> GameViewportInstance {
        // 关实例的请求可能早于本次创建：这里补一次拆除，
        // 保证「关了就一定不会留下活着的实例」。
        if destroyPending.remove(account.id) != nil {
            if let doomed = surfaces.removeValue(forKey: account.id) {
                doomed.removeFromSuperview()
                doomed.stop()
            }
        }
        if reloadPending.remove(account.id) != nil, let old = surfaces.removeValue(forKey: account.id) {
            old.removeFromSuperview()
            old.stop()
        }
        if let existing = surfaces[account.id] {
            return existing
        }
        let instance = makeInstance(account, environment)
        instance.pool = self
        surfaces[account.id] = instance
        enqueueStartup(instance)
        return instance
    }

    public func existingSurface(forAccountID accountID: String) -> GameViewportInstance? {
        surfaces[accountID]
    }

    /// 池中存活实例数。多开矩阵用它决定渲染像素比与引导注入的 instanceCount。
    public var liveCount: Int { surfaces.count }

    /// 全部存活实例（焦点能耗仲裁遍历用）。
    public var allSurfaces: [GameViewportInstance] { Array(surfaces.values) }

    /// 永久关闭（懒创建 + 关闭与启动同帧时先落意图，创建时补拆）。
    public func destroy(accountID: String) {
        destroyPending.insert(accountID)
        reloadPending.remove(accountID)
        automaticReloads[accountID] = nil
        cancelPendingStartup(accountID: accountID)
        guard let view = surfaces.removeValue(forKey: accountID) else { return }
        view.removeFromSuperview()
        view.stop()
    }

    /// 用户主动「重新登录」：生命周期重来，自动重载闸门一起归零。
    public func requestReload(accountID: String) {
        automaticReloads[accountID] = nil
        cancelPendingStartup(accountID: accountID)
        reloadPending.insert(accountID)
    }

    // MARK: - 自动兜底重载记账

    public func automaticReloadCount(forAccountID accountID: String) -> Int {
        automaticReloads[accountID] ?? 0
    }

    /// 记一次自动重载。**只累加，不清零**（清零会让闸门失效）。
    public func noteAutomaticReload(forAccountID accountID: String) {
        automaticReloads[accountID, default: 0] += 1
    }

    // MARK: - 启动队列

    public func enqueueStartup(_ instance: GameViewportInstance) {
        startupQueue.append(instance)
        pumpStartupQueue()
    }

    /// 页面报告启动沉降完成（`type: 'ready'`），释放槽位给下一个实例。
    public func noteInstanceReady(accountID: String) {
        guard startingAccounts.remove(accountID) != nil else { return }
        startupTimeouts.removeValue(forKey: accountID)?.cancel()
        LobbyLog.info("[pool] startup slot released: %@ (queued=%ld)", accountID, startupQueue.count)
        pumpStartupQueue()
        delegate?.instancePoolDidFinishStartup(accountID: accountID)
    }

    /// 实例被关闭 / 重载：不管在排队还是启动中，一律撤下。
    public func cancelPendingStartup(accountID: String) {
        startupQueue.removeAll { $0.accountID == accountID }
        startingAccounts.remove(accountID)
        startupTimeouts.removeValue(forKey: accountID)?.cancel()
    }

    private func pumpStartupQueue() {
        guard !startupQueue.isEmpty else { return }
        while startingAccounts.count < Self.concurrentStartupLimit, !startupQueue.isEmpty {
            let instance = startupQueue.removeFirst()
            let accountID = instance.accountID
            startingAccounts.insert(accountID)
            LobbyLog.info("[pool] startup slot acquired: %@ (active=%ld, queued=%ld)",
                          accountID, startingAccounts.count, startupQueue.count)
            scheduleStartupTimeout(accountID)
            instance.start()
        }
    }

    private func scheduleStartupTimeout(_ accountID: String) {
        startupTimeouts[accountID]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            LobbyLog.warn("[pool] startup slot timed out after %.0fs: %@", Self.startupSlotTimeout, accountID)
            self.noteInstanceReady(accountID: accountID)
        }
        startupTimeouts[accountID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startupSlotTimeout, execute: work)
    }
}
