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

    /// 每个账号的「启动代次」：每次 `launch` 自增，矩阵格子身份里带上它。
    ///
    /// 为什么必须有这个计数（实测事故）：矩阵格子一旦被 SwiftUI 记住，**关掉实例
    /// 再把同一个账号启动起来时，格子不会被重建** —— 把子项从 `ForEach` 里移出再
    /// 放回同一 identity，SwiftUI 既不调 `dismantleNSView`，也不再调 `makeNSView`
    /// （只补一次 `updateNSView`）。而实例是懒创建的：唯一创建入口就是格子
    /// `makeNSView` 里的 `pool.surface(for:)`。于是「退出 → 再点登录」时：
    /// 卡片回来了，但池里根本没有新实例，格子上挂的还是那个已被 `destroy`
    /// 从视图树里摘掉、`stop()` 过的旧 WKWebView —— 游戏区一片空白，
    /// 用户看到的就是「点了登录没反应 / 无法登录」。
    ///
    /// 代次进格子身份 → 每次启动都换身份 → SwiftUI 必定重建格子 → 必定新建实例。
    /// （与 `reloadRevision` 同一套思路，区别是它按账号记账，不会连累其它格子。）
    @Published public private(set) var launchGenerations: [String: Int] = [:]

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

    /// 正在抓资料的账号 ID（账号卡上显示进度圈用）。
    ///
    /// 与「页面内探针」的分工：运行中的账号由页面探针实时上报（免费、无需联网动作），
    /// 这个集合只覆盖「没在运行、由服务端直取」的那些账号。
    @Published public private(set) var profileRefreshInFlight: Set<String> = []

    /// 资料刷新的串行任务（非 nil = 有批次在跑，用于挡住重复触发）。
    private var profileRefreshTask: Task<Void, Never>?
    /// 账号之间的间隔：服务端不是靶子，别把 30 多个账号一股脑并发出去。
    private static let profileRefreshGapNanos: UInt64 = 400_000_000

    // MARK: 依赖

    public let bins: AccountStoring
    public let pool: GameInstancePool
    public let sync: InputSyncController
    public let scripts: ScriptStore
    /// 游戏加强设置库（十殿加速等）。
    public let enhancements: GameEnhancementStore
    /// 账号资料库（头像 / 游戏内昵称 / 等级战力）。账号卡直接观察它取图。
    public let avatars: AccountAvatarStore
    /// 抓包控制器：解码 + 每账号会话（帧留存）。窗口与列表都从这里取数据。
    ///
    /// ⚠️ **必须由装配根注入，且与实例工厂收到的是同一个对象**（2026-09-18.6 的
    /// 实测事故）：这里若走默认值初始化，就会出现「UI 在实例 A 上开抓包、帧却
    /// 流向实例 B」的分裂——窗口正常弹出但一条帧都收不到；又因为实例 B 没有强
    /// 持有者，ARC 释放后实例里的 weak 引用直接变 nil。装配根两处传同一实例即可。
    public let capture: PacketCaptureController
    /// 指令库（抓包窗口的指令库页签 / 发送面板共用；抓包发现的新 cmd 自动入库）。
    public let commandCatalog: GameCommandStore
    /// 抓包窗口管理器：每账号一个独立 NSWindow（开抓时创建，关窗 = 自动停抓）。
    public let captureWindows = PacketCaptureWindowManager()
    /// 盐场图表控制器：与抓包并列的第二条解码线（只认盐场连接的 war_* 帧族），
    /// 持有每账号的战场快照 + 负责轮询帧发送。装配根与实例工厂传同一实例。
    public let saltField: SaltFieldChartController
    /// 盐场图表窗口管理器：每账号一个独立 NSWindow（可透明 / 置顶 / 鼠标穿透）。
    public let saltFieldWindows = SaltFieldChartWindowManager()
    /// 因「开盐场图表」而顺带开启的页面上报（关图表时要一并关掉的账号）。
    private var saltFieldOwnsCapture: Set<String> = []
    /// 盐场图表窗口可见的账号（实例卡片按钮的高亮态）。
    @Published public private(set) var saltFieldChartsVisible: Set<String> = []
    /// 资料抓取器：**不启动游戏**，直接用 `.bin` 凭据问服务端（见 `AccountProfileFetcher`）。
    public let profileFetcher = AccountProfileFetcher()

    private let groupStore: GroupStoring

    public init(bins: AccountStoring,
                pool: GameInstancePool,
                sync: InputSyncController,
                groupStore: GroupStoring,
                scripts: ScriptStore,
                enhancements: GameEnhancementStore,
                avatars: AccountAvatarStore,
                capture: PacketCaptureController,
                commandCatalog: GameCommandStore,
                saltField: SaltFieldChartController) {
        self.bins = bins
        self.pool = pool
        self.sync = sync
        self.groupStore = groupStore
        self.scripts = scripts
        self.enhancements = enhancements
        self.avatars = avatars
        self.capture = capture
        self.commandCatalog = commandCatalog
        self.saltField = saltField
        pool.delegate = self
        groupDefinitions = groupStore.loadDefinitions().sorted(by: Self.groupOrder)
        assignments = groupStore.loadAssignments()
        expansions = groupStore.loadExpansions()
        accountOrders = groupStore.loadOrders()
        matrixOrder = groupStore.loadMatrixOrder()
        remarks = groupStore.loadRemarks()
        captureWindows.attach(session: self)
        saltFieldWindows.attach(session: self)
        saltField.pool = pool
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
            // 账号没了，头像快照与缓存图一起清掉（否则会一直躺着几十张孤儿图）。
            avatars.forget(accountIDs: members.map(\.id))
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
            // 剪掉不在库里的资料残留（用户在 Finder 里手删 .bin 的情况）。
            // ⚠️ 只在**扫描成功**时剪：扫描失败时 `accounts` 可能还是空的，
            // 那一刻 prune 会把所有头像快照误删。
            avatars.prune(keeping: Set(accounts.map(\.id)))
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
            avatars.forget(accountIDs: [account.id])
            persistGroups()
        } catch {
            statusMessage = "删除失败：\(error.localizedDescription)"
        }
        refresh()
    }

    // MARK: - 选服（一个 .bin 名下的多个区服角色）

    /// 正在选服选的账号（非 nil = 弹选区面板）。
    @Published public var rolePickerAccount: GameAccount?
    /// 选区面板的数据状态。
    @Published public private(set) var rolePickerState: RolePickerState = .idle
    /// 正在派生的角色（按钮转圈用；同时挡住重复点击）。
    @Published public private(set) var derivingRoleID: Int64?

    public enum RolePickerState: Equatable, Sendable {
        case idle
        case loading
        case loaded(AccountRoleList)
        case failed(String)
    }

    /// 区服角色目录（纯 HTTP，不建会话）。
    private let roleCatalog = AccountRoleCatalog()

    /// 打开选区面板并拉取该账号名下的区服角色。
    ///
    /// ⚠️ 与 `refreshProfiles` 不同：`/login/serverlist` **不会建立游戏会话**，
    /// 所以运行中的账号也能查（不会顶号）。
    public func requestRoles(for account: GameAccount) {
        rolePickerAccount = account
        rolePickerState = .loading
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let binData = try self.bins.readBinData(for: account.fileName)
                let list = try await self.roleCatalog.roles(binData: binData)
                // 面板可能已经被换到别的账号上，别把结果投错。
                guard self.rolePickerAccount?.id == account.id else { return }
                self.rolePickerState = .loaded(list)
            } catch {
                guard self.rolePickerAccount?.id == account.id else { return }
                self.rolePickerState = .failed(error.localizedDescription)
            }
        }
    }

    public func dismissRolePicker() {
        rolePickerAccount = nil
        rolePickerState = .idle
        derivingRoleID = nil
    }

    /// 某个 `.bin` 文件当前落在哪个区服（解不开返回 nil）。
    public func serverID(ofFileName fileName: String) -> Int64? {
        guard let data = try? bins.readBinData(for: fileName),
              let credential = try? BinCredential(data: data) else { return nil }
        return credential.serverID
    }

    /// 把「切到这个区服」落成一份**派生凭据**并入库，返回新账号文件名（失败 nil）。
    ///
    /// 因为账号 ID = 文件内容的 SHA256，派生出来的凭据天然就是另一个账号：
    /// 实例、`WKWebsiteDataStore`、localStorage、头像、分组全部自动隔离，
    /// **存储层一行都不用改**。原凭据一字不动，随时可以退回原区服。
    ///
    /// 幂等：同一个区服重复点不会堆出 `X-2.bin`、`X-3.bin`。
    @discardableResult
    public func deriveAccount(from account: GameAccount, role: GameRole) -> String? {
        guard derivingRoleID == nil else { return nil }
        derivingRoleID = role.roleID
        defer { derivingRoleID = nil }

        let preferredName = role.derivedBinFileName(basedOn: account.fileName)
        if bins.contains(fileName: preferredName), serverID(ofFileName: preferredName) == role.serverID {
            statusMessage = "「\(preferredName)」已经在 \(role.serverNumber) 服了，没有重复生成。"
            return preferredName
        }

        do {
            let binData = try bins.readBinData(for: account.fileName)
            let credential = try BinCredential(data: binData)
            let derived = try credential.derivedBinData(serverID: role.serverID)
            let fileName = try bins.writeBin(derived, preferredName: preferredName)
            // 派生账号留在原账号所在的分组里：用户的组织意图要延续过去。
            let groupID = groupID(forAccountID: account.id)
            if groupID != AccountGroup.ungroupedID,
               groupDefinitions.contains(where: { $0.id == groupID }) {
                assignments[fileName] = groupID
                persistGroups()
            }
            refresh()
            statusMessage = "已生成「\(fileName)」（\(role.displayName)）。原账号未改动，可直接启动。"
            // 新账号还没跑过游戏，资料先走服务端直取（纯 HTTP + 一次 WSS，不建实例）。
            if let created = accounts.first(where: { $0.id == fileName }) {
                refreshProfiles([created], reason: "选服派生")
            }
            return fileName
        } catch {
            statusMessage = "生成账号副本失败：\(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - 账号资料（服务端直取，不启动游戏）

    /// 自动补拉「还没有资料」的账号。启动后调一次。
    ///
    /// 只补**缺失**的（不刷已有资料：那需要联网动作，应该由用户主动触发），
    /// 且**跳过正在运行的账号**——运行中由页面探针负责，而且对运行中的账号再建
    /// 一次会话很可能把大厅里的窗口顶掉。
    public func autoRefreshMissingProfiles() {
        let missing = accounts.filter { avatars.profile(forAccountID: $0.id) == nil }
        guard !missing.isEmpty else {
            LobbyLog.debug("[session] 资料补拉：没有缺失（%ld 个账号都已有资料）", accounts.count)
            return
        }
        LobbyLog.info("[session] 资料补拉：%ld 个账号缺资料", missing.count)
        refreshProfiles(missing, reason: "补拉")
    }

    /// 手动 / 自动刷新账号资料。
    ///
    /// - Parameter targets: 要刷的账号；传 nil = 全部账号。
    /// - Parameter reason: 只用于日志与提示文案。
    ///
    /// 三条硬约束（都是踩过的）：
    /// ① **跳过正在运行的账号**——对运行中的账号再建一次游戏会话，很可能顶掉大厅实例；
    /// ② **串行 + 间隔**（每个账号 400ms 之后才发下一个），不把服务端当靶子；
    /// ③ **同一时刻只允许一个批次**，避免连点几十次刷出几十个并发会话。
    public func refreshProfiles(_ targets: [GameAccount]? = nil, reason: String = "手动") {
        guard profileRefreshTask == nil else {
            statusMessage = "资料刷新正在进行中，请稍候。"
            return
        }
        let requested = targets ?? accounts
        guard !requested.isEmpty else { return }
        let candidates = requested.filter { !runningAccountIDs.contains($0.id) }
        let skipped = requested.count - candidates.count
        guard !candidates.isEmpty else {
            statusMessage = skipped > 0 ? "这些账号都在运行中，已跳过（运行中的账号由游戏内自动上报）" : "没有可刷新的账号。"
            return
        }
        LobbyLog.info("[session] 资料刷新(%@)：%ld 个待刷，跳过 %ld 个运行中的",
                      reason, candidates.count, skipped)
        statusMessage = "正在刷新 \(candidates.count) 个账号的资料…"

        profileRefreshTask = Task { @MainActor [weak self] in
            var succeeded = 0
            var failed = 0
            for account in candidates {
                guard let self, !Task.isCancelled else { return }
                self.profileRefreshInFlight.insert(account.id)
                do {
                    let binData = try self.bins.readBinData(for: account.fileName)
                    let snapshot = try await self.profileFetcher.fetch(binData: binData)
                    self.avatars.record(snapshot, forAccountID: account.id)
                    succeeded += 1
                    LobbyLog.info("[session] 资料刷新成功：%@ → %@ Lv%ld",
                                  account.fileName, snapshot.name, snapshot.level)
                } catch {
                    failed += 1
                    // 单个账号失败不该中断整批（凭据过期 / 网络抖动都只影响那一个）。
                    LobbyLog.warn("[session] 资料刷新失败：%@ — %@",
                                  account.fileName, String(describing: error))
                }
                self.profileRefreshInFlight.remove(account.id)
                // 间隔（最后一个不用等）。
                if succeeded + failed < candidates.count {
                    try? await Task.sleep(nanoseconds: Self.profileRefreshGapNanos)
                }
            }
            guard let self else { return }
            self.profileRefreshTask = nil
            var summary = "资料刷新完成：成功 \(succeeded)"
            if failed > 0 { summary += "，失败 \(failed)" }
            if skipped > 0 { summary += "，跳过运行中 \(skipped)" }
            self.statusMessage = summary
            LobbyLog.info("[session] %@", summary)
        }
    }

    /// 该账号是否正在抓资料（卡片显示进度圈）。
    public func isRefreshingProfile(_ account: GameAccount) -> Bool {
        profileRefreshInFlight.contains(account.id)
    }

    // MARK: - 实例生命周期

    /// 启动账号（幂等；已在跑的实例直接聚焦）。
    public func launch(_ account: GameAccount) {
        guard !runningAccountIDs.contains(account.id) else {
            focus(account.id)
            return
        }
        runningAccountIDs.append(account.id)
        // 启动代次自增：格子身份随之变化，保证「关掉再启动」也一定会重建格子
        // （否则 SwiftUI 复用旧格子 → 不调 makeNSView → 池里不新建实例，见属性注释）。
        launchGenerations[account.id, default: 0] += 1
        if focusedAccountID == nil {
            focus(account.id)
        }
        // 实例懒创建：矩阵格子下一帧 makeNSView 时经池 surface(for:) 建立。
    }

    /// 该账号的启动代次（矩阵格子身份用；0 = 从未启动过）。
    public func launchGeneration(forAccountID accountID: String) -> Int {
        launchGenerations[accountID] ?? 0
    }

    /// 关闭实例（账号级：群控参与/主控随账号退休）。
    public func close(_ account: GameAccount) {
        runningAccountIDs.removeAll { $0 == account.id }
        // 抓包随实例一起收摊：停抓 + 丢会话 + 关窗口（抓包窗口是实例的伴生工具）。
        capture.discardSession(accountID: account.id)
        captureWindows.closeWindow(forAccountID: account.id)
        // 盐场图表同样随实例收摊：停轮询 + 丢快照 + 关窗口。
        saltField.discard(accountID: account.id)
        saltFieldWindows.closeWindow(forAccountID: account.id)
        saltFieldOwnsCapture.remove(account.id)
        saltFieldChartsVisible.remove(account.id)
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

    // MARK: - 画质广播

    /// 设置页改档后广播给所有存活实例（页面桥重设 maxPixelRatio 并触发画布
    /// 重算，不重启游戏）；新启动的实例由引导脚本从 UserDefaults 读档位。
    public func broadcastQualityChange(_ quality: RenderQuality) {
        let surfaces = pool.allSurfaces
        LobbyLog.info("[session] quality broadcast(%@): %ld instance(s)", quality.rawValue, surfaces.count)
        for instance in surfaces {
            instance.applyQuality(quality)
        }
    }

    // MARK: - 游戏加强下发（十殿加速 / UI 加速 / 聊天窗口显隐）

    /// 十殿加速开关变更：落盘（store 内 didSet）+ 下发全部存活实例。
    /// 唯一写入路径——不让 UI 直接改 store，避免「改了值但没下发」的静默状态。
    public func setNightmareSpeedEnabled(_ enabled: Bool) {
        guard enhancements.nightmareSpeedEnabled != enabled else { return }
        enhancements.nightmareSpeedEnabled = enabled
        broadcastEnhancements()
    }

    /// 十殿加速倍率变更（越界钳制到 1...1000）：落盘 + 下发全部存活实例。
    public func setNightmareSpeedMultiplier(_ multiplier: Int) {
        let clamped = GameEnhancementSettings.clamp(multiplier: multiplier)
        guard enhancements.nightmareSpeedMultiplier != clamped else { return }
        enhancements.nightmareSpeedMultiplier = clamped
        broadcastEnhancements()
    }

    /// UI 加速开关变更：落盘 + 下发全部存活实例。
    public func setUISpeedEnabled(_ enabled: Bool) {
        guard enhancements.uiSpeedEnabled != enabled else { return }
        enhancements.uiSpeedEnabled = enabled
        broadcastEnhancements()
    }

    /// UI 加速倍率变更（钳制到 1...10、0.5 步进）：落盘 + 下发全部存活实例。
    public func setUISpeedMultiplier(_ multiplier: Double) {
        let clamped = GameEnhancementSettings.clamp(speed: multiplier)
        guard enhancements.uiSpeedMultiplier != clamped else { return }
        enhancements.uiSpeedMultiplier = clamped
        broadcastEnhancements()
    }

    /// 聊天窗口显隐变更：落盘 + 下发全部存活实例。
    /// 关掉（显示）时页面侧会把当初被压住的面板放回来，不需要重载实例。
    public func setChatPanelHidden(_ hidden: Bool) {
        guard enhancements.chatPanelHidden != hidden else { return }
        enhancements.chatPanelHidden = hidden
        broadcastEnhancements()
    }

    /// 帧率角标开关变更：落盘 + 下发全部存活实例。
    public func setFPSDisplayEnabled(_ enabled: Bool) {
        guard enhancements.fpsDisplayEnabled != enabled else { return }
        enhancements.fpsDisplayEnabled = enabled
        broadcastEnhancements()
    }

    /// 战斗数据浮层开关变更：落盘 + 下发全部存活实例。
    /// 页面侧要等「战斗模块加载 / 进战斗」才装得上钩子（自带降频轮询），
    /// 所以开着的时候战斗里晚一两秒生效是正常的。
    public func setBattleStatsEnabled(_ enabled: Bool) {
        guard enhancements.battleStatsEnabled != enabled else { return }
        enhancements.battleStatsEnabled = enabled
        broadcastEnhancements()
    }

    /// 玩家ID 显示 / 复制开关变更：落盘 + 下发全部存活实例。
    /// 页面侧要等玩家信息弹窗类被加载（第一次打开弹窗时才加载），自带降频轮询。
    public func setPlayerIDEnabled(_ enabled: Bool) {
        guard enhancements.playerIDEnabled != enabled else { return }
        enhancements.playerIDEnabled = enabled
        broadcastEnhancements()
    }

    /// 帧率档位改档后重放能耗仲裁。
    ///
    /// 为什么要专门一条：页面侧的帧率只在**两处**下发——实例启动（先按非焦点 15 FPS）
    /// 与焦点变化。设置页的档位是 `@AppStorage` 直写 UserDefaults，没有广播的话，
    /// 正在跑的实例要等到「切换账号 / 重启实例」才会读到新档，用户看到的就是
    /// 「改了没反应」。这里按当前焦点重放一遍：焦点实例用新档，非焦点仍 15 FPS。
    public func broadcastFrameRateChange() {
        LobbyLog.info("[session] frame rate change → %ld FPS (focused only)",
                      TargetFrameRate.current().rawValue)
        reapplyEnergyPolicy()
    }

    /// 向所有存活实例取一次状态回执（只为刷新帧率读数）。
    /// 由设置页在「帧率角标开着 + 页面可见」时按 2s 节拍调用——没有空闲轮询。
    public func refreshEnhancementReports() {
        for instance in pool.allSurfaces {
            instance.refreshEnhancementReport()
        }
    }

    /// 焦点账号的昵称（设置页显示「这路跑多少」时用来挑读数）。
    public var focusedAccountNickname: String? {
        guard let id = focusedAccountID else { return nil }
        return accounts.first { $0.id == id }?.nickname
    }

    /// 把当前游戏加强设置推给所有存活实例。
    /// 新启动的实例不在这里管：它在文档就绪时自行下发一次。
    public func broadcastEnhancements() {
        let surfaces = pool.allSurfaces
        let settings = enhancements.settings
        LobbyLog.info("[session] enhancement broadcast(nightmareSpeed=%@ x%ld uiSpeed=%@ %@ fps=%@ battle=%@ pid=%@ chat=%@): %ld instance(s)",
                      settings.nightmareSpeedEnabled ? "on" : "off",
                      settings.nightmareSpeedMultiplier,
                      settings.uiSpeedEnabled ? "on" : "off",
                      GameEnhancementSettings.describe(speed: settings.uiSpeedMultiplier),
                      settings.fpsDisplayEnabled ? "on" : "off",
                      settings.battleStatsEnabled ? "on" : "off",
                      settings.playerIDEnabled ? "on" : "off",
                      settings.chatPanelHidden ? "hidden" : "shown",
                      surfaces.count)
        for instance in surfaces {
            instance.applyEnhancements()
        }
    }

    // MARK: - 抓包（WSS 帧捕获 + 独立抓包窗口）

    /// 开 / 停某账号的抓包（矩阵卡片按钮的唯一入口）。
    ///
    /// 开：会话建档 → 页面开关推 on → 弹独立抓包窗口（此后页面帧持续进会话，
    ///     窗口里 0.25s 批量上屏，过滤随时改）。
    /// 停：页面开关推 off（hook 保留、零开销路径）→ 留存帧保留（窗口里仍可看 / 导出），
    ///     再点一次按钮可继续追加。
    /// 前置：实例必须在运行——开关下发要打在活页面上。
    public func togglePacketCapture(_ account: GameAccount) {
        guard runningAccountIDs.contains(account.id),
              let instance = pool.existingSurface(forAccountID: account.id) else {
            statusMessage = "抓包需要账号处于运行状态，请先启动「\(account.nickname)」。"
            return
        }
        if capture.isCapturing(accountID: account.id) {
            capture.endSession(accountID: account.id)
            instance.setPacketCaptureEnabled(false)
            statusMessage = "已停止「\(account.nickname)」抓包（留存帧可在窗口中查看 / 导出）。"
        } else {
            capture.beginSession(accountID: account.id, accountName: account.nickname)
            instance.setPacketCaptureEnabled(true)
            captureWindows.openWindow(for: account)
        }
    }

    /// 抓包窗口被用户关闭（红点）：自动停抓这一个账号（留存帧保留）。
    /// 由 `PacketCaptureWindowManager.windowDidClose` 回调。
    public func packetCaptureWindowDidClose(accountID: String) {
        guard capture.isCapturing(accountID: accountID),
              let instance = pool.existingSurface(forAccountID: accountID) else { return }
        capture.endSession(accountID: accountID)
        instance.setPacketCaptureEnabled(false)
    }

    // MARK: - 盐场实时图表（独立窗口 · 可透明 / 置顶 / 鼠标穿透）

    /// 开 / 关某账号的盐场图表窗口（矩阵卡片按钮的唯一入口）。
    ///
    /// 开：确保页面上报开着（图表与抓包共用同一条页面上报通道；若抓包本来没开，
    ///     记入 `saltFieldOwnsCapture`，关图表时一并关掉）→ 开轮询 → 弹独立窗口。
    /// 关：停轮询 → 若上报是因图表而开的则关掉 → 关窗口。
    /// 前置：实例必须在运行（轮询帧要从活页面发出去）。
    public func toggleSaltFieldChart(_ account: GameAccount) {
        guard runningAccountIDs.contains(account.id),
              let instance = pool.existingSurface(forAccountID: account.id) else {
            statusMessage = "盐场图表需要账号处于运行状态，请先启动「\(account.nickname)」。"
            return
        }
        if saltFieldChartsVisible.contains(account.id) {
            closeSaltFieldChart(accountID: account.id, instance: instance)
            statusMessage = "已关闭「\(account.nickname)」盐场图表。"
        } else {
            if !capture.isCapturing(accountID: account.id) {
                capture.beginSession(accountID: account.id, accountName: account.nickname)
                instance.setPacketCaptureEnabled(true)
                saltFieldOwnsCapture.insert(account.id)
            } else {
                saltFieldOwnsCapture.remove(account.id)
            }
            saltField.setPolling(true, accountID: account.id)
            saltFieldChartsVisible.insert(account.id)
            saltFieldWindows.openWindow(for: account)
            statusMessage = "盐场图表已打开：进入游戏内盐场战场后自动拉取（每 4 秒）。"
        }
    }

    /// 关图表的公共路径（按钮二次点击 / 窗口红点 / 实例关闭）。
    private func closeSaltFieldChart(accountID: String, instance: GameViewportInstance? = nil) {
        saltField.setPolling(false, accountID: accountID)
        saltFieldChartsVisible.remove(accountID)
        if saltFieldOwnsCapture.remove(accountID) != nil {
            let target = instance ?? pool.existingSurface(forAccountID: accountID)
            capture.endSession(accountID: accountID)
            target?.setPacketCaptureEnabled(false)
        }
        saltFieldWindows.closeWindow(forAccountID: accountID)
    }

    /// 图表窗口被用户关闭（红点）：停轮询 + 归还页面上报（若因图表而开）。
    /// 由 `SaltFieldChartWindowManager.windowWillClose` 回调。
    public func saltFieldChartWindowDidClose(accountID: String) {
        closeSaltFieldChart(accountID: accountID)
    }

    /// 图表窗口的轮询开关（窗口工具栏）。
    public func setSaltFieldPolling(_ enabled: Bool, account: GameAccount) {
        saltField.setPolling(enabled, accountID: account.id)
    }

    /// 图表窗口的「立即拉取」。
    public func refreshSaltFieldNow(account: GameAccount) {
        saltField.pollNow(accountID: account.id)
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

    // MARK: - 一键取证

    /// 抓页面侧诊断快照并落盘。
    ///
    /// 触发入口（菜单栏「诊断」）：
    /// - **抓取渲染诊断快照**（⇧⌘A）—— 只抓**当前焦点**实例
    /// - **抓取全部实例诊断快照**（⇧⌘D）—— 一次抓**所有在跑实例**
    ///
    /// 为什么还要"全部"那一个：缺口/异常是**单个窗口**的现象，要定位就得**横向比**。
    /// 而逐个窗口按快捷键时，**两次按之间总会发生点击**（用户自己点、或同步回放），
    /// 于是两份快照**不是同一时刻**、界面对不上——实测就踩过这个坑（§29）。
    /// 一次抓全部 ⇒ 同一瞬间的 N 份快照，才真的可比。
    public func captureRenderAudit(allInstances: Bool = false) async {
        let surfaces = pool.allSurfaces
        var targets = surfaces
        if !allInstances, let focused = focusedAccountID,
           let hit = surfaces.first(where: { $0.accountID == focused }) {
            targets = [hit]
        }
        guard !targets.isEmpty else {
            // 落盘由实例层负责（那里能拿到 DiagnosticsLog）；这里只记控制台。
            LobbyLog.warn("[session] audit snapshot requested but no running instance")
            return
        }
        LobbyLog.info("[session] audit snapshot requested: %ld instance(s)", targets.count)
        for instance in targets {
            await instance.captureDiagnosticsSnapshot(reason: allInstances ? "hotkey-all" : "hotkey")
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
