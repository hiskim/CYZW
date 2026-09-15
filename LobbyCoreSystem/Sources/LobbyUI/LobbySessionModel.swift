import Foundation
import LobbyDomain
import LobbyEngine
import SwiftUI

/// 大厅会话门面：账号库 CRUD、实例启停、焦点能耗仲裁。
/// 表现层只跟它说话；引擎细节（实例池、认证、CDN）全部在门面之后。
@MainActor
public final class LobbySessionModel: ObservableObject {
    /// 账号列表（库扫描序：修改时间新 → 旧）。
    @Published public private(set) var accounts: [GameAccount] = []
    /// 运行中的账号 ID（保持账号列表相对顺序）。
    @Published public private(set) var runningAccountIDs: [String] = []
    /// 当前焦点实例（满帧出声；其余降帧静音）。
    @Published public var focusedAccountID: String?
    /// 需要用户确认删除的账号（非 nil 时弹确认框）。
    @Published public var deletionCandidate: GameAccount?
    /// 操作提示（导入失败等）。
    @Published public var statusMessage: String?
    /// 兜底重载请求计数：矩阵视图监听它强制重建对应格子，
    /// 让 `makeNSView` 重新 `surface(for:)`，触发池的延迟重载。
    @Published public private(set) var reloadRevision = 0

    public let bins: AccountStoring
    public let pool: GameInstancePool

    public init(bins: AccountStoring, pool: GameInstancePool) {
        self.bins = bins
        self.pool = pool
        pool.delegate = self
    }

    // MARK: - 账号库

    public func refresh() {
        do {
            let files = try bins.listAccountFiles()
            let known = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
            accounts = files.map { file in
                known[file.id] ?? GameAccount(fileName: file.fileName, importedAt: file.creationDate)
            }
        } catch {
            statusMessage = "读取账号库失败：\(error.localizedDescription)"
        }
    }

    /// 导入 .bin（NSOpenPanel 多选）。
    public func importFiles(from urls: [URL]) {
        for url in urls {
            do {
                _ = try bins.importBin(from: url)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
        refresh()
    }

    /// 用户请求删除（先弹确认）。
    public func requestDelete(_ account: GameAccount) {
        deletionCandidate = account
    }

    /// 确认删除：若在运行先关实例，再删文件、刷新列表。
    public func confirmDelete() {
        guard let account = deletionCandidate else { return }
        deletionCandidate = nil
        if runningAccountIDs.contains(account.id) {
            close(account)
        }
        do {
            try bins.deleteBin(named: account.fileName)
        } catch {
            statusMessage = "删除失败：\(error.localizedDescription)"
        }
        refresh()
    }

    // MARK: - 实例生命周期

    /// 启动账号（幂等；已在跑的实例直接聚焦）。
    public func launch(_ account: GameAccount) {
        guard !runningAccountIDs.contains(account.id) else {
            focus(account.id)
            return
        }
        runningAccountIDs.append(account.id)
        // 首个实例自动成为焦点。
        if focusedAccountID == nil {
            focus(account.id)
        }
        // 实例懒创建：矩阵格子下一帧 makeNSView 时经池 surface(for:) 建立。
    }

    /// 关闭实例。
    public func close(_ account: GameAccount) {
        runningAccountIDs.removeAll { $0 == account.id }
        pool.destroy(accountID: account.id)
        if focusedAccountID == account.id {
            focus(runningAccountIDs.first)
        }
    }

    /// 重新登录：生命周期重来（池延迟拆除旧实例），矩阵格子强制重建。
    public func reload(_ account: GameAccount) {
        guard runningAccountIDs.contains(account.id) else { return }
        pool.requestReload(accountID: account.id)
        reloadRevision &+= 1
    }

    /// 矩阵数据源：运行账号（账号列表相对顺序）。
    public var matrixAccounts: [GameAccount] {
        accounts.filter { runningAccountIDs.contains($0.id) }
    }

    public func isRunning(_ account: GameAccount) -> Bool {
        runningAccountIDs.contains(account.id)
    }

    // MARK: - 焦点能耗仲裁

    /// 抢焦点：焦点实例满帧出声，其余降帧静音（规格 §4.1）。
    public func focus(_ accountID: String?) {
        focusedAccountID = accountID
        reapplyEnergyPolicy()
    }

    private func reapplyEnergyPolicy() {
        for instance in pool.allSurfaces {
            instance.applyEnergyPolicy(isFocused: instance.accountID == focusedAccountID)
        }
    }
}

// MARK: - GameInstancePoolDelegate

extension LobbySessionModel: GameInstancePoolDelegate {
    public func instancePoolDidRequestReload(accountID: String, reason: String) {
        LobbyLog.warn("[session] auto reload requested: %@ (%@)", accountID, reason)
        reloadRevision &+= 1
    }

    public func instancePoolDidFinishStartup(accountID: String) {
        // 实例就绪时页面先按「非焦点」降帧静音；这里按当前焦点重放一次，
        // 保证焦点实例从第一秒起就是满帧出声。
        reapplyEnergyPolicy()
    }
}
