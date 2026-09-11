import Foundation
import Combine
import OSLog

private let accountOrderLogger = Logger(subsystem: "com.xyzw.ios2", category: "AccountSorting")

@MainActor
final class AccountLibraryViewModel: ObservableObject {
    /// 树形数据源：["全部"伪分组, "未分组"伪分组, 自定义分组...]。
    /// 每个节点的 `accounts` 由 ViewModel 按归属关系物化，侧边栏直接遍历渲染。
    @Published private(set) var groups: [AccountGroup] = []
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var remarks: [String: String]
    @Published private(set) var lastLoginTimestamps: [String: TimeInterval]
    @Published private(set) var accountOrder: [String: [String]]
    @Published private(set) var defaultGroupID: String?
    /// 侧边栏分组过滤选中项；nil 代表"全部"。
    /// （分组 ID 在本项目中为 String：自定义分组是 UUID 字符串，
    /// 另有 allID/ungroupedID 两个固定伪分组 ID，因此不用 UUID? 类型。）
    @Published var selectedGroupID: String?

    init() {
        remarks = UserDefaults.standard.dictionary(forKey: Self.remarksKey) as? [String: String] ?? [:]
        lastLoginTimestamps = Self.loadLastLoginTimestamps()
        accountOrder = Self.loadAccountOrder()
        defaultGroupID = UserDefaults.standard.string(forKey: Self.defaultGroupKey)

        var tree: [AccountGroup] = [
            Self.syntheticAllGroup(),
            Self.syntheticUngroupedGroup()
        ]
        tree.append(contentsOf: Self.loadGroups())
        groups = tree
        syncTree()
    }

    private static let remarksKey = "ios.shell.account-remarks"
    private static let lastLoginTimestampsKey = "ios.shell.account-last-login-timestamps"
    private static let accountOrderKey = "ios.shell.account-order"
    private static let groupAssignmentsKey = "ios.shell.account-groups"
    private static let groupNamesKey = "ios.shell.groups"
    private static let groupDefinitionsKey = "ios.shell.group-definitions"
    private static let defaultGroupKey = "ios.shell.default-group"
    private static let allExpandedKey = "ios.shell.all-group-expanded"
    private static let ungroupedExpandedKey = "ios.shell.ungrouped-group-expanded"

    private var groupAssignments: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.groupAssignmentsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.groupAssignmentsKey) }
    }

    var selectedAccounts: [Account] {
        accounts.filter { selectedIDs.contains($0.id) }
    }

    var allSelected: Bool {
        !accounts.isEmpty && accounts.allSatisfy { selectedIDs.contains($0.id) }
    }

    var allGroup: AccountGroup { .all }

    /// 分组定义（不含"全部"/"未分组"伪分组）。
    private var definitionGroups: [AccountGroup] {
        groups.filter { !$0.isSynthetic }
    }

    var visibleGroups: [AccountGroup] {
        orderedGroups.filter { !$0.isHidden }
    }

    var hiddenGroups: [AccountGroup] {
        orderedGroups.filter(\.isHidden)
    }

    var groupNames: [String] {
        [Account.defaultGroupName] + orderedGroups.map(\.groupName)
    }

    var orderedGroups: [AccountGroup] {
        definitionGroups.sorted(by: Self.isOrderedBefore)
    }

    /// 右侧矩阵数据源：展平所有分组中处于运行中的账号。
    /// 运行状态由视图层注入（WorkspaceViewModel 中存在同 ID 实例即视为运行中）。
    ///
    /// 必须跳过「全部」伪分组：它的成员与其余分组完全重叠，直接 flatMap
    /// 会把每个运行中的账号数两遍（2 开被算成 4 开）——矩阵按 4 列适配、
    /// 实际只渲染 2 张卡，卡片尺寸偏小且高度占不满。
    func runningAccounts(isRunning: (Account) -> Bool) -> [Account] {
        groups
            .filter { $0.id != AccountGroup.all.id }
            .flatMap(\.accounts)
            .filter(isRunning)
    }

    // MARK: - 侧边栏分组过滤

    /// 侧边栏账号列表数据源：按 selectedGroupID 过滤（nil = "全部"，同样遵循
    /// accountOrder[allID] 的持久化排序，保证拖动排序在"全部"视图下也生效）。
    var filteredAccounts: [Account] {
        guard let selectedGroupID,
              let group = groups.first(where: { $0.id == selectedGroupID }) else { return accounts(in: .all) }
        return accounts(in: group)
    }

    /// 过滤区当前选中分组的展示标题（列表头部使用）。
    var selectedGroupTitle: String {
        guard let selectedGroupID,
              let group = groups.first(where: { $0.id == selectedGroupID }) else { return "全部账号" }
        return group.groupName
    }

    // MARK: - 展开状态

    /// 更新分组展开状态。伪分组展开状态存独立键，普通分组随定义持久化。
    func setExpanded(_ expanded: Bool, forGroupID groupID: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].isExpanded = expanded
        switch groupID {
        case AccountGroup.allID:
            UserDefaults.standard.set(expanded, forKey: Self.allExpandedKey)
        case AccountGroup.ungroupedID:
            UserDefaults.standard.set(expanded, forKey: Self.ungroupedExpandedKey)
        default:
            saveGroups()
        }
    }

    // MARK: - 备注 / 登录记录

    func remark(for account: Account) -> String {
        remarks[account.id] ?? ""
    }

    func updateRemark(_ value: String, for account: Account) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.isEmpty {
            remarks.removeValue(forKey: account.id)
        } else {
            remarks[account.id] = trimmedValue
        }
        UserDefaults.standard.set(remarks, forKey: Self.remarksKey)
    }

    func lastLoginDate(for account: Account) -> Date? {
        lastLoginTimestamps[account.id].map(Date.init(timeIntervalSince1970:))
    }

    func recordLogin(for account: Account) {
        lastLoginTimestamps[account.id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(lastLoginTimestamps, forKey: Self.lastLoginTimestampsKey)
    }

    // MARK: - 分组成员查询

    /// 解析分组内的账号。"全部"返回所有账号，"未分组"返回未指派到任何分组的账号。
    func accounts(in group: AccountGroup) -> [Account] {
        let members: [Account]
        switch group.id {
        case AccountGroup.allID:
            members = accounts
        case AccountGroup.ungroupedID:
            let knownNames = Set(definitionGroups.map(\.groupName))
            members = accounts.filter {
                $0.groupName == Account.defaultGroupName || !knownNames.contains($0.groupName)
            }
        default:
            members = accounts.filter { $0.groupName == group.groupName }
        }

        let order = accountOrder[group.id] ?? []
        guard !order.isEmpty else { return members }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return members.sorted {
            switch (rank[$0.id], rank[$1.id]) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return false
            }
        }
    }

    func moveAccounts(in group: AccountGroup, from source: IndexSet, to destination: Int) {
        var ordered = accounts(in: group)
        accountOrderLogger.info("move requested: group=\(group.id, privacy: .public), count=\(ordered.count), source=\(source.description, privacy: .public), destination=\(destination)")
        ordered.move(fromOffsets: source, toOffset: destination)
        accountOrder[group.id] = ordered.map(\.id)
        UserDefaults.standard.set(accountOrder, forKey: Self.accountOrderKey)
        accountOrderLogger.info("move persisted: group=\(group.id, privacy: .public), order=\(ordered.map(\.id).joined(separator: ","), privacy: .public)")
        materializeMembers()
    }

    // MARK: - 分组管理

    func addGroup(named name: String, colorName: String = "blue", accountIDs: Set<String> = [], isDefault: Bool = false) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              trimmedName != Account.defaultGroupName,
              trimmedName != AccountGroup.all.groupName,
              !groups.contains(where: { $0.groupName == trimmedName }) else { return }
        let group = AccountGroup(groupName: trimmedName, colorName: colorName, sortOrder: (definitionGroups.map(\.sortOrder).max() ?? 0) + 1)
        groups.append(group)
        updateMembers(accountIDs, for: group)
        syncTree()
        saveGroups()
        if isDefault { setDefaultGroup(group) }
    }

    func updateGroup(_ group: AccountGroup, groupName name: String, colorName: String, accountIDs: Set<String>, isDefault: Bool) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              trimmedName != Account.defaultGroupName,
              trimmedName != AccountGroup.all.groupName,
              !groups.contains(where: { $0.groupName == trimmedName && $0.id != group.id }),
              let index = groups.firstIndex(where: { $0.id == group.id }) else { return }

        let oldName = groups[index].groupName
        groups[index].groupName = trimmedName
        groups[index].colorName = colorName
        if oldName != trimmedName {
            var assignments = groupAssignments
            for account in accounts where account.groupName == oldName {
                assignments[account.id] = trimmedName
            }
            groupAssignments = assignments
            for index in accounts.indices where accounts[index].groupName == oldName {
                accounts[index].groupName = trimmedName
            }
        }
        updateMembers(accountIDs, for: groups[index])
        syncTree()
        saveGroups()
        if isDefault { setDefaultGroup(groups[index]) }
        else if defaultGroupID == group.id { defaultGroupID = nil; UserDefaults.standard.removeObject(forKey: Self.defaultGroupKey) }
    }

    func updateGroup(_ value: String, for account: Account) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = trimmedValue.isEmpty ? Account.defaultGroupName : trimmedValue
        var assignments = groupAssignments
        assignments[account.id] = group
        groupAssignments = assignments
        addGroup(named: group)

        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].groupName = group
        materializeMembers()
    }

    func setHidden(_ hidden: Bool, for group: AccountGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        if hidden && visibleGroups.count == 1 {
            errorMessage = "至少保留一个可见分组。"
            return
        }
        groups[index].isHidden = hidden
        if hidden && selectedGroupID == group.id { selectedGroupID = nil }
        saveGroups()
    }

    func moveGroups(from source: IndexSet, to destination: Int) {
        var ordered = orderedGroups.filter { !$0.isHidden }
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, group) in ordered.enumerated() {
            guard let groupIndex = groups.firstIndex(where: { $0.id == group.id }) else { continue }
            groups[groupIndex].sortOrder = index + 1
        }
        saveGroups()
        resortTree()
    }

    func deleteGroup(_ group: AccountGroup, deletingMembers: Bool) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == group.id }) else { return }
        let members = accounts(in: group)
        if deletingMembers {
            do {
                for account in members {
                    try AccountFileManager.shared.deleteBin(named: account.fileName)
                }
                accounts.removeAll { account in members.contains(where: { $0.id == account.id }) }
                selectedIDs.subtract(Set(members.map(\.id)))
                for account in members { remarks.removeValue(forKey: account.id) }
                UserDefaults.standard.set(remarks, forKey: Self.remarksKey)
                var assignments = groupAssignments
                for account in members { assignments.removeValue(forKey: account.id) }
                groupAssignments = assignments
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        } else {
            var assignments = groupAssignments
            for account in members { assignments.removeValue(forKey: account.id) }
            groupAssignments = assignments
            for index in accounts.indices where accounts[index].groupName == group.groupName {
                accounts[index].groupName = Account.defaultGroupName
            }
        }
        groups.remove(at: groupIndex)
        if selectedGroupID == group.id { selectedGroupID = nil }
        if defaultGroupID == group.id {
            defaultGroupID = nil
            UserDefaults.standard.removeObject(forKey: Self.defaultGroupKey)
        }
        syncTree()
        saveGroups()
    }

    // MARK: - 账号导入 / 删除 / 刷新

    func refresh() {
        do {
            let assignments = groupAssignments
            accounts = try AccountFileManager.shared.loadAccountFiles().map { info in
                var account = Account(fileName: info.fileName, importedAt: info.creationDate)
                account.groupName = assignments[account.id] ?? Account.defaultGroupName
                return account
            }
            selectedIDs.formIntersection(Set(accounts.map(\.id)))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        syncTree()
    }

    func importFiles(from urls: [URL]) {
        importFiles(from: urls, targetGroupID: nil)
    }

    /// 导入 .bin 账号。`targetGroupID` 非空时把新账号直接归入该分组；
    /// 传"未分组"伪分组 ID 表示明确不指派；nil 走默认分组逻辑。
    /// 文件在导入瞬间由 AccountFileManager 物理拷贝进沙盒 AccountBins 目录，
    /// 之后 App 只依赖沙盒内副本，不再持有外部路径或安全授权。
    func importFiles(from urls: [URL], targetGroupID: String?) {
        do {
            var imported: [Account] = []
            for url in urls {
                let fileName = try AccountFileManager.shared.importBin(from: url)
                imported.append(Account(fileName: fileName))
            }

            var assignments = groupAssignments
            for account in imported {
                if targetGroupID == AccountGroup.ungroupedID { continue }
                if let targetGroup = targetGroupID.flatMap(({ id in groups.first(where: { $0.id == id }) })),
                   !targetGroup.isSynthetic {
                    assignments[account.id] = targetGroup.groupName
                } else if let defaultGroup = groups.first(where: { $0.id == defaultGroupID }) {
                    assignments[account.id] = defaultGroup.groupName
                }
            }
            groupAssignments = assignments
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(id: String) {
        delete(ids: [id])
    }

    func delete(ids: Set<String>) {
        let targets = accounts.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }

        var deletedIDs = Set<String>()
        var failures: [String] = []
        for account in targets {
            do {
                try AccountFileManager.shared.deleteBin(named: account.fileName)
                deletedIDs.insert(account.id)
            } catch {
                failures.append(account.nickname)
            }
        }

        guard !deletedIDs.isEmpty else {
            errorMessage = "无法删除所选账号。"
            return
        }

        accounts.removeAll { deletedIDs.contains($0.id) }
        selectedIDs.subtract(deletedIDs)
        remarks = remarks.filter { !deletedIDs.contains($0.key) }
        UserDefaults.standard.set(remarks, forKey: Self.remarksKey)
        lastLoginTimestamps = lastLoginTimestamps.filter { !deletedIDs.contains($0.key) }
        UserDefaults.standard.set(lastLoginTimestamps, forKey: Self.lastLoginTimestampsKey)
        accountOrder = accountOrder.mapValues { $0.filter { !deletedIDs.contains($0) } }
        UserDefaults.standard.set(accountOrder, forKey: Self.accountOrderKey)
        var assignments = groupAssignments
        for id in deletedIDs { assignments.removeValue(forKey: id) }
        groupAssignments = assignments
        errorMessage = failures.isEmpty ? nil : "以下账号未能删除：\(failures.joined(separator: "、"))。"
        materializeMembers()
    }

    // MARK: - 选择

    func toggleSelection(id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func toggleSelectAll() {
        selectedIDs = allSelected ? [] : Set(accounts.map(\.id))
    }

    /// 一键清空所有勾选（含其他分组的勾选项）。全选按钮只作用于当前视图，
    /// 跨分组勾选后用它整体复位。
    func clearSelection() {
        selectedIDs.removeAll()
    }

    func toggleSelection(in group: AccountGroup) {
        let ids = Set(accounts(in: group).map(\.id))
        guard !ids.isEmpty else { return }
        if ids.isSubset(of: selectedIDs) {
            selectedIDs.subtract(ids)
        } else {
            selectedIDs.formUnion(ids)
        }
    }

    /// 侧边栏过滤列表头部的全选切换：nil = 全部账号，否则当前选中分组。
    func toggleSelection(forGroupID groupID: String?) {
        if let groupID, let group = groups.first(where: { $0.id == groupID }) {
            toggleSelection(in: group)
        } else {
            toggleSelectAll()
        }
    }

    // MARK: - 树形数据源维护

    /// 伪分组"全部"：包含所有账号，展开状态独立持久化。
    private static func syntheticAllGroup() -> AccountGroup {
        AccountGroup(
            id: AccountGroup.allID,
            groupName: "全部",
            colorName: "gray",
            sortOrder: 0,
            isExpanded: UserDefaults.standard.object(forKey: allExpandedKey) as? Bool ?? true
        )
    }

    /// 伪分组"未分组"：收纳未指派到任何分组的账号（含指派失效的账号）。
    private static func syntheticUngroupedGroup() -> AccountGroup {
        AccountGroup(
            id: AccountGroup.ungroupedID,
            groupName: Account.defaultGroupName,
            colorName: "gray",
            sortOrder: 0,
            isExpanded: UserDefaults.standard.object(forKey: ungroupedExpandedKey) as? Bool ?? true
        )
    }

    /// 按展示顺序重排树：伪分组固定在最前，自定义分组按 sortOrder + 名称排序。
    private func resortTree() {
        let synthetic = groups.filter(\.isSynthetic)
        let definitions = groups.filter { !$0.isSynthetic }.sorted(by: Self.isOrderedBefore)
        groups = synthetic + definitions
    }

    /// 按归属关系重新物化每个分组的 accounts 数组。
    private func materializeMembers() {
        for index in groups.indices {
            groups[index].accounts = accounts(in: groups[index])
        }
    }

    private func syncTree() {
        resortTree()
        materializeMembers()
    }

    private static func isOrderedBefore(_ lhs: AccountGroup, _ rhs: AccountGroup) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.groupName.localizedStandardCompare(rhs.groupName) == .orderedAscending
    }

    private func updateMembers(_ accountIDs: Set<String>, for group: AccountGroup) {
        var assignments = groupAssignments
        for account in accounts where account.groupName == group.groupName && !accountIDs.contains(account.id) {
            assignments.removeValue(forKey: account.id)
        }
        for accountID in accountIDs { assignments[accountID] = group.groupName }
        groupAssignments = assignments
        for index in accounts.indices {
            if accountIDs.contains(accounts[index].id) { accounts[index].groupName = group.groupName }
            else if accounts[index].groupName == group.groupName { accounts[index].groupName = Account.defaultGroupName }
        }
    }

    private func setDefaultGroup(_ group: AccountGroup) {
        defaultGroupID = group.id
        UserDefaults.standard.set(group.id, forKey: Self.defaultGroupKey)
    }

    private func saveGroups() {
        let definitions = groups.filter { !$0.isSynthetic }
        if let data = try? JSONEncoder().encode(definitions) {
            UserDefaults.standard.set(data, forKey: Self.groupDefinitionsKey)
        }
    }

    private static func loadGroups() -> [AccountGroup] {
        if let data = UserDefaults.standard.data(forKey: groupDefinitionsKey),
           let groups = try? JSONDecoder().decode([AccountGroup].self, from: data) {
            return groups
        }
        let legacyNames = UserDefaults.standard.stringArray(forKey: groupNamesKey) ?? []
        return legacyNames.enumerated().map { index, name in
            AccountGroup(groupName: name, sortOrder: index + 1)
        }
    }

    private static func loadLastLoginTimestamps() -> [String: TimeInterval] {
        let storedValues = UserDefaults.standard.dictionary(forKey: lastLoginTimestampsKey) ?? [:]
        return storedValues.reduce(into: [:]) { timestamps, entry in
            guard let timestamp = (entry.value as? NSNumber)?.doubleValue else { return }
            timestamps[entry.key] = timestamp
        }
    }

    private static func loadAccountOrder() -> [String: [String]] {
        UserDefaults.standard.dictionary(forKey: accountOrderKey) as? [String: [String]] ?? [:]
    }
}

