import Foundation
import LobbyDomain
import LobbyEngine
import SwiftUI

/// 大厅会话门面：账号库 CRUD、分组管理、实例启停、焦点能耗仲裁、群控接线。
/// 表现层只跟它说话；引擎细节（实例池、认证、CDN、键鼠同步）全部在门面之后。
@MainActor
public final class LobbySessionModel: ObservableObject {
    /// 账号列表（库扫描序：修改时间新 → 旧）。
    @Published public private(set) var accounts: [GameAccount] = []
    /// 运行中的账号 ID。
    @Published public private(set) var runningAccountIDs: [String] = []
    /// 当前焦点实例（满帧出声；其余降帧静音）。
    @Published public var focusedAccountID: String?
    /// 需要用户确认删除的账号（非 nil 时弹确认框）。
    @Published public var deletionCandidate: GameAccount?
    /// 需要确认的分组删除（非 nil 时弹确认框；携带分组名供文案使用）。
    @Published public var groupDeletionCandidate: AccountGroup?
    /// 操作提示（导入失败等）。
    @Published public var statusMessage: String?
    /// 兜底重载请求计数：矩阵视图监听它强制重建对应格子。
    @Published public private(set) var reloadRevision = 0

    // MARK: 分组状态

    /// 自定义分组定义（已按 sortOrder + 名称排序，不含伪分组）。
    @Published public private(set) var groupDefinitions: [AccountGroup] = []
    /// 账号 ID → 分组 ID（缺席 = 未分组；重命名安全，不按分组名匹配）。
    @Published public private(set) var assignments: [String: String] = [:]
    /// 伪分组展开状态。
    @Published public var expansions: [String: Bool] = [:]
    /// 分组内账号拖拽排序表：分组 ID → 有序账号 ID 列表（缺席 = 库扫描序）。
    @Published public private(set) var accountOrders: [String: [String]] = [:]
    /// 多开矩阵窗口排列表（账号 ID 序；缺席账号按分组序追加在尾部）。
    @Published public private(set) var matrixOrder: [String] = []
    /// 账号备注表：账号 ID → 备注文本。
    @Published public private(set) var remarks: [String: String] = [:]
    /// 正被拖拽的矩阵卡（视觉反馈用：抬起 + 加深阴影）。
    @Published public var draggingMatrixAccountID: String?

    /// 待确认删除的分组是否连成员一起删（确认框选项）。
    @Published public var deleteGroupMembers = false

    // MARK: 依赖

    public let bins: AccountStoring
    public let pool: GameInstancePool
    public let sync: InputSyncController
    public let scripts: ScriptStore
    private let groupStore: GroupStoring

    public init(bins: AccountStoring,
                pool: GameInstancePool,
                sync: InputSyncController,
                groupStore: GroupStoring,
                scripts: ScriptStore) {
        self.bins = bins
        self.pool = pool
        self.sync = sync
        self.groupStore = groupStore
        self.scripts = scripts
        pool.delegate = self
        groupDefinitions = groupStore.loadDefinitions().sorted(by: Self.groupOrder)
        assignments = groupStore.loadAssignments()
        expansions = groupStore.loadExpansions()
        accountOrders = groupStore.loadOrders()
        matrixOrder = groupStore.loadMatrixOrder()
        remarks = groupStore.loadRemarks()
    }

    /// 分组定义排序：sortOrder 优先，再按名称本地化比较（与上一代口径一致）。
    private static func groupOrder(_ lhs: AccountGroup, _ rhs: AccountGroup) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.groupName.localizedStandardCompare(rhs.groupName) == .orderedAscending
    }

    // MARK: - 分组树（运行时物化）

    /// 侧边栏树：[全部, 未分组] + 自定义分组（定义序）。
    public var groupTree: [AccountGroup] {
        var tree: [AccountGroup] = [AccountGroup.all, AccountGroup.ungrouped]
        tree.append(contentsOf: groupDefinitions)
        return tree
    }

    /// 解析分组 ID 的展示名。
    public func groupName(forGroupID groupID: String) -> String {
        switch groupID {
        case AccountGroup.allID: return AccountGroup.all.groupName
        case AccountGroup.ungroupedID: return GameAccount.defaultGroupName
        default: return groupDefinitions.first(where: { $0.id == groupID })?.groupName
            ?? GameAccount.defaultGroupName
        }
    }

    /// 账号当前所属分组 ID（缺席 = 未分组）。
    public func groupID(forAccountID accountID: String) -> String {
        assignments[accountID] ?? AccountGroup.ungroupedID
    }

    public func groupName(forAccountID accountID: String) -> String {
        groupName(forGroupID: groupID(forAccountID: accountID))
    }

    /// 分组内的账号（先按归属过滤，再应用拖拽排序表；未排序的保持库扫描序）。
    public func accounts(inGroupID groupID: String) -> [GameAccount] {
        let members: [GameAccount]
        switch groupID {
        case AccountGroup.allID:
            members = accounts
        case AccountGroup.ungroupedID:
            let validGroupIDs = Set(groupDefinitions.map(\.id))
            members = accounts.filter { account in
                let assigned = assignments[account.id]
                return assigned == nil || !validGroupIDs.contains(assigned!)
            }
        default:
            members = accounts.filter { assignments[$0.id] == groupID }
        }
        return AccountOrder.apply(members, order: accountOrders[groupID] ?? [])
    }

    // MARK: - 拖拽排序（List + .onMove，原生列表重排）

    /// List.onMove 语义：把 `source` 行移动到 `destination` 位置（同一分组内）。
    /// 与上一代 moveAccounts(in:from:to:) 的口径一致；排序表持久化到 groups.json。
    public func moveAccounts(inGroupID groupID: String,
                             from source: IndexSet, to destination: Int) {
        var ordered = accounts(inGroupID: groupID).map(\.id)
        guard !ordered.isEmpty else { return }
        ordered.move(fromOffsets: source, toOffset: destination)
        withAnimation(.easeInOut(duration: 0.18)) {
            accountOrders[groupID] = ordered
        }
        persistGroups()
    }

    /// 删除账号后清理排序表中的残留项。
    private func removeOrderEntries(for deletedIDs: [String]) {
        let removed = Set(deletedIDs)
        accountOrders = accountOrders.mapValues { $0.filter { !removed.contains($0) } }
        matrixOrder.removeAll { removed.contains($0) }
        for id in removed { remarks.removeValue(forKey: id) }
    }

    /// 伪分组 / 自定义分组的展开状态。
    public func isExpanded(_ groupID: String) -> Bool {
        if let custom = groupDefinitions.first(where: { $0.id == groupID }) {
            return custom.isExpanded
        }
        return expansions[groupID] ?? true
    }

    public func setExpanded(_ expanded: Bool, forGroupID groupID: String) {
        if let index = groupDefinitions.firstIndex(where: { $0.id == groupID }) {
            groupDefinitions[index].isExpanded = expanded
            persistGroups()
        } else {
            expansions[groupID] = expanded
            persistGroups()
        }
    }

    /// 账号卡片 / 矩阵描边的分组色板名。
    public func groupColorName(forAccountID accountID: String) -> String {
        let groupID = groupID(forAccountID: accountID)
        return groupDefinitions.first(where: { $0.id == groupID })?.colorName ?? "gray"
    }

    // MARK: - 分组管理

    /// 新建分组（重名 / 与伪分组重名 / 空名直接忽略）。
    public func addGroup(named name: String, colorName: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != GameAccount.defaultGroupName,
              trimmed != AccountGroup.all.groupName,
              !groupDefinitions.contains(where: { $0.groupName == trimmed }) else {
            statusMessage = "分组名重复或非法。"
            return
        }
        let sortOrder = (groupDefinitions.map(\.sortOrder).max() ?? 0) + 1
        groupDefinitions.append(AccountGroup(groupName: trimmed, colorName: colorName, sortOrder: sortOrder))
        persistGroups()
    }

    /// 重命名 / 改色（归属表按 ID 记录，改名无需搬家）。
    public func updateGroup(id: String, name: String, colorName: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != GameAccount.defaultGroupName,
              trimmed != AccountGroup.all.groupName,
              !groupDefinitions.contains(where: { $0.groupName == trimmed && $0.id != id }) else {
            statusMessage = "分组名重复或非法。"
            return
        }
        guard let index = groupDefinitions.firstIndex(where: { $0.id == id }) else { return }
        groupDefinitions[index].groupName = trimmed
        groupDefinitions[index].colorName = colorName
        persistGroups()
    }

    /// 上移 / 下移分组（重排 sortOrder）。
    public func moveGroup(id: String, offset: Int) {
        guard let index = groupDefinitions.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard groupDefinitions.indices.contains(target) else { return }
        groupDefinitions.swapAt(index, target)
        for (order, _) in groupDefinitions.enumerated() {
            groupDefinitions[order].sortOrder = order + 1
        }
        persistGroups()
    }

    /// 删除分组。`deletingMembers = true` 时连成员账号文件一起删（需先经确认框）；
    /// 否则成员回落到未分组。
    public func deleteGroup(id: String, deletingMembers: Bool) {
        guard let index = groupDefinitions.firstIndex(where: { $0.id == id }) else { return }
        let members = accounts(inGroupID: id)
        if deletingMembers {
            for account in members {
                if runningAccountIDs.contains(account.id) {
                    close(account)
                }
                try? bins.deleteBin(named: account.fileName)
            }
            accounts.removeAll { member in members.contains(where: { $0.id == member.id }) }
        }
        for account in members where !deletingMembers {
            assignments.removeValue(forKey: account.id)
        }
        // 连成员删除时也清掉归属与同步参与状态。
        for account in members {
            assignments.removeValue(forKey: account.id)
            sync.retire(accountID: account.id)
        }
        groupDefinitions.remove(at: index)
        if focusedAccountID != nil, !runningAccountIDs.contains(focusedAccountID!) {
            focus(runningAccountIDs.first)
        }
        removeOrderEntries(for: members.map(\.id))
        persistGroups()
        refresh()
    }

    /// 把账号指派到分组（groupID 传未分组伪分组 ID = 移出分组）。
    public func assign(accountID: String, toGroupID groupID: String) {
        if groupID == AccountGroup.ungroupedID {
            assignments.removeValue(forKey: accountID)
        } else {
            guard groupDefinitions.contains(where: { $0.id == groupID }) else { return }
            assignments[accountID] = groupID
        }
        persistGroups()
        // 分组变更可能改变群控路由边界，立即重新注册。
        sync.configureGroups(definitions: groupDefinitions, assignments: assignments)
    }

    private func persistGroups() {
        var allExpansions = expansions
        for group in groupDefinitions {
            allExpansions[group.id] = group.isExpanded
        }
        groupStore.save(definitions: groupDefinitions, assignments: assignments,
                        expansions: allExpansions, orders: accountOrders,
                        matrixOrder: matrixOrder, remarks: remarks)
        sync.configureGroups(definitions: groupDefinitions, assignments: assignments)
    }

    // MARK: - 备注

    public func remark(forAccountID accountID: String) -> String {
        remarks[accountID] ?? ""
    }

    /// 更新备注（空串 = 清除）。
    public func updateRemark(_ value: String, forAccountID accountID: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            remarks.removeValue(forKey: accountID)
        } else {
            remarks[accountID] = trimmed
        }
        persistGroups()
    }

    // MARK: - 账号库

    public func refresh() {
        do {
            let files = try bins.listAccountFiles()
            let known = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
            accounts = files.map { file in
                var account = known[file.id] ?? GameAccount(fileName: file.fileName, importedAt: file.creationDate)
                account.groupName = groupName(forAccountID: account.id)
                return account
            }
        } catch {
            statusMessage = "读取账号库失败：\(error.localizedDescription)"
        }
        sync.configureGroups(definitions: groupDefinitions, assignments: assignments)
    }

    /// 导入 .bin（NSOpenPanel 多选）。`targetGroupID` 非空时把新账号直接归入该分组。
    public func importFiles(from urls: [URL], targetGroupID: String? = nil) {
        for url in urls {
            do {
                let fileName = try bins.importBin(from: url)
                if let targetGroupID, targetGroupID != AccountGroup.ungroupedID,
                   groupDefinitions.contains(where: { $0.id == targetGroupID }) {
                    assignments[fileName] = targetGroupID
                }
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

    /// 确认删除：若在运行先关实例，再删文件、清归属、刷新列表。
    public func confirmDelete() {
        guard let account = deletionCandidate else { return }
        deletionCandidate = nil
        if runningAccountIDs.contains(account.id) {
            close(account)
        }
        do {
            try bins.deleteBin(named: account.fileName)
            assignments.removeValue(forKey: account.id)
            sync.retire(accountID: account.id)
            removeOrderEntries(for: [account.id])
            persistGroups()
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
        if focusedAccountID == nil {
            focus(account.id)
        }
        // 实例懒创建：矩阵格子下一帧 makeNSView 时经池 surface(for:) 建立。
    }

    /// 关闭实例（账号级：群控参与/主控随账号退休）。
    public func close(_ account: GameAccount) {
        runningAccountIDs.removeAll { $0 == account.id }
        sync.retire(accountID: account.id)
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

    /// 矩阵数据源：按「未分组 → 自定义分组定义序」展平运行中的账号。
    /// 必须跳过「全部」伪分组（成员与其余分组完全重叠，直接 flatMap 会数两遍）；
    /// 显式分组顺序保证先启动 A 组再启动 B 组时矩阵仍按分组连续排列。
    public var matrixAccounts: [GameAccount] {
        let ordered = [AccountGroup.ungroupedID] + groupDefinitions.map(\.id)
        var seen = Set<String>()
        var result: [GameAccount] = []
        for groupID in ordered {
            for account in accounts(inGroupID: groupID) where runningAccountIDs.contains(account.id) {
                if seen.insert(account.id).inserted {
                    result.append(account)
                }
            }
        }
        // 兜底：归属失效但仍在运行的账号也进矩阵（归属刷新前的一瞬）。
        for account in accounts where runningAccountIDs.contains(account.id) {
            if seen.insert(account.id).inserted {
                result.append(account)
            }
        }
        // 矩阵拖拽排列表优先（标题栏拖动换位用）：表内账号按 rank，
        // 缺席账号（新启动等）按分组序追加在尾部。
        return AccountOrder.apply(result, order: matrixOrder)
    }

    /// 一键关闭全部运行中的账号（逐个走账号级关闭：群控退休 + 池销毁）。
    public func closeAll() {
        for account in accounts where runningAccountIDs.contains(account.id) {
            close(account)
        }
    }

    /// 矩阵标题栏拖拽换位：把 `draggedID` 移到 `targetID` 当前所在的位置。
    /// 由矩阵舞台在拖动经过其它卡片时调用，实时重排并持久化。
    /// 插入方向随拖拽方向变化：向左拖 = 插到目标**之前**；向右拖 = 插到目标
    /// **之后**（否则向右拖到紧邻的卡上会落回原位，表现为"第一个窗口拖不动"）。
    public func moveMatrixAccount(_ draggedID: String, before targetID: String) {
        guard draggedID != targetID else { return }
        var ordered = matrixAccounts.map(\.id)
        guard let from = ordered.firstIndex(of: draggedID),
              let to = ordered.firstIndex(of: targetID),
              from != to else { return }
        let draggingRight = from < to
        ordered.remove(at: from)
        guard let targetIndex = ordered.firstIndex(of: targetID) else { return }
        ordered.insert(draggedID, at: draggingRight ? targetIndex + 1 : targetIndex)
        withAnimation(.easeInOut(duration: 0.18)) {
            matrixOrder = ordered
        }
        persistGroups()
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
