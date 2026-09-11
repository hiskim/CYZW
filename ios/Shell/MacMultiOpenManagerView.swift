#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacMultiOpenManagerView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var liveWorkspace: WorkspaceViewModel
    @StateObject private var accounts = AccountLibraryViewModel()
    @State private var selectedSection: Section = .accounts
    @State private var searchText = ""
    @State private var isPresentingImporter = false
    @State private var sidebarVisible = true
    @State private var fixedColumnCount: Int?
    @State private var instanceWidth: CGFloat = 280
    @State private var deletionRequest: AccountDeletionRequest?
    @State private var deletionBlockedMessage: String?
    @State private var isPresentingGroupManagement = false
    /// 分组管理弹窗的当前模式（Binding 传给弹窗）：.list 管理列表 / .create 新建分组。
    /// 由入口按钮显式设置，弹窗内的模式切换也写回这里——避免 sheet 复用
    /// 残留 @State 导致「＋增加分组」打开的却是列表模式。
    @State private var groupManagementMode: GroupManagementMode = .list
    /// 记录本次文件导入的目标分组（nil = 走默认分组逻辑）。
    @State private var importTargetGroupID: String?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _liveWorkspace = ObservedObject(wrappedValue: coordinator.workspace)
    }

    enum Section: String, CaseIterable, Identifiable {
        case accounts, scripts, settings
        var id: String { rawValue }
        var title: String {
            switch self { case .accounts: return "账号"; case .scripts: return "脚本"; case .settings: return "设置" }
        }
        var icon: String {
            switch self { case .accounts: return "person.2"; case .scripts: return "curlybraces"; case .settings: return "gearshape" }
        }
    }

    // MARK: - 运行状态

    /// 右侧矩阵数据源：展平所有分组中处于运行中的账号（树序 = 分组顺序）。
    private var allRunningAccounts: [Account] {
        accounts.runningAccounts { isRunning($0) }
    }

    private func isRunning(_ account: Account) -> Bool {
        liveWorkspace.items.contains { $0.account.id == account.id }
    }

    var body: some View {
        ZStack {
            // ── 第 -1 层 · 真实毛玻璃：behindWindow 直接折射桌面壁纸。
            // 壁纸的纹理和色彩透过整窗，毛玻璃不再靠渐变自证。
            VibrancyBackdrop()
                .ignoresSafeArea()

            // ── 第 0 层 · 底层氛围光（配方 01）：深色底 + 超大径向色斑。
            // 玻璃的观感 = 对背后内容的高斯采样；没有这层，透出来的永远是
            // 同一块纯色，玻璃只会变成灰板。顺序必须反过来：先铺氛围光，再做玻璃。
            AmbientGlowBackground()
                .ignoresSafeArea()

            // ── 第 1 层 · 玻璃面板层。材质档位就是模糊半径的层级语言：
            // 侧栏 ≈ blur 50 → .thinMaterial；卡片画布 ≈ 28 → .ultraThinMaterial。
            // 大厅区不再整面铺材质：参考稿的主区就是「裸氛围光」，
            // 玻璃只出现在侧栏和卡片画布容器上。
            HStack(spacing: 0) {
                if sidebarVisible {
                    ZStack {
                        // 真实毛玻璃：直接折射桌面壁纸（访达侧栏同款 .sidebar 材质），
                        // 比窗内 Material 明显得多；壁纸移动时玻璃内容实时变化
                        VibrancyBackdrop(material: .sidebar)
                        Color.black.opacity(0.34)                    // 压暗：侧栏直接采壁纸，亮壁纸上必须重压
                        AmbientRefractionTint()                      // 品牌深蓝统一
                        Rectangle()
                            .fill(Color.white.opacity(0.05))         // 02 玻璃填充 白 5%
                    }
                    .frame(width: 304)
                    // 04 右缘 1px 描边（上亮下暗）——玻璃的「厚度感」全靠这条线
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.07)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 1)
                    }
                    // 06 外投影：黑 40%，向右偏移，把侧栏从大厅上「抬起」
                    .shadow(color: .black.opacity(0.40), radius: 22, x: 6, y: 0)
                    .zIndex(1)
                }
            }
            // 关键：HStack 里只有侧栏一个孩子时，它会被 ZStack 默认居中——
            // 304pt 宽的玻璃面板会「飞」到窗口中央变成一块灰板（灰板悬案的元凶）。
            // 必须显式靠左铺满，让玻璃垫回侧栏正下方。
            .frame(maxWidth: .infinity, alignment: .leading)
            .ignoresSafeArea()
            // 05 窗口顶边 1px 内高光：整块玻璃的「顶面」受光线（左亮右暗）
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.05)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
            }

            // ── 内容层：尊重安全区，列宽与背景层一一对应。
            HStack(spacing: 0) {
                if sidebarVisible {
                    sidebar
                        .frame(width: 304)
                    Color.clear.frame(width: 1)
                }
                workspace
            }
        }
        .overlay(alignment: .top) {
            // hiddenTitleBar 顶部拖拽兜底：一条 28pt 的隐形拖拽区，
            // 按住可拖动窗口；条带内没有交互控件，不影响点击。
            TitleBarDragRegion()
                .frame(height: 28)
                .frame(maxWidth: .infinity)
        }
        .task { accounts.refresh() }
        .fileImporter(isPresented: $isPresentingImporter,
                      allowedContentTypes: [UTType(filenameExtension: "bin") ?? .data],
                      allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                accounts.importFiles(from: urls, targetGroupID: importTargetGroupID)
                importTargetGroupID = nil
            }
        }
        .alert(item: $deletionRequest) { request in
            Alert(
                title: Text(request.accounts.count == 1 ? "删除 \(request.accounts[0].nickname)？" : "删除 \(request.accounts.count) 个账号？"),
                message: Text("删除后将移除本地 .bin 文件及账号记录，且无法恢复。"),
                primaryButton: .destructive(Text("删除")) {
                    accounts.delete(ids: Set(request.accounts.map(\.id)))
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .alert("无法删除账号", isPresented: Binding(
            get: { deletionBlockedMessage != nil },
            set: { if !$0 { deletionBlockedMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { deletionBlockedMessage = nil }
        } message: {
            Text(deletionBlockedMessage ?? "")
        }
        .sheet(isPresented: $isPresentingGroupManagement) {
            // 尺寸由 GroupManagementView 的 macBody 内部定义（560×470）。
            // 此处不要再套 frame，否则双层 frame 会把底部「新建分组/完成」
            // 工具栏裁剪出可视区域。
            GroupManagementView(viewModel: accounts, mode: $groupManagementMode)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.cyan)
                Text("中控台")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 20)
            // 顶部额外留白：hiddenTitleBar 下红黄绿交通灯悬浮在侧栏上，为它们让位。
            .padding(.top, 36)
            .padding(.bottom, 16)

            HStack(spacing: 4) {
                ForEach(Section.allCases) { section in
                    Button { selectedSection = section } label: {
                        VStack(spacing: 5) {
                            Image(systemName: section.icon).font(.system(size: 14, weight: .semibold))
                            Text(section.title).font(.system(size: 12, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(selectedSection == section ? .white : .secondary)
                        .background(selectedSection == section ? Color.cyan.opacity(0.2) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)

            Divider().overlay(Color.white.opacity(0.1)).padding(.vertical, 12)

            if selectedSection == .accounts {
                accountControls
                accountList
            } else {
                secondarySection
            }
            Spacer(minLength: 0)
            HStack {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("系统就绪").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text("\(liveWorkspace.items.count) 个实例 · 不限数量")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .foregroundStyle(.white)
    }

    // MARK: - 顶部控制区

    private var accountControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    importTargetGroupID = nil
                    isPresentingImporter = true
                } label: { Label("添加账号", systemImage: "plus") }
                    .buttonStyle(MacManagerButtonStyle(tint: .cyan))
                Button { startAll() } label: {
                    Label("启动全部", systemImage: "play.fill")
                }
                    .buttonStyle(MacManagerButtonStyle(tint: .green))
                Button { closeAll() } label: { Label("关闭全部", systemImage: "stop.fill") }
                    .buttonStyle(MacManagerButtonStyle(tint: .red))
            }
            .controlSize(.small)
            if !accounts.selectedAccounts.isEmpty {
                Button { requestDeletion(of: accounts.selectedAccounts) } label: {
                    Label("删除已选 \(accounts.selectedAccounts.count) 个", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MacManagerButtonStyle(tint: .red))
                .accessibilityLabel("删除已选账号")
            }
            // 分组列表移到搜索栏上方：分组标签 + 行尾「增加分组」按钮（见 groupFilterRow）。
            groupFilterRow
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索账号", text: $searchText).textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
            }
            .padding(8)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            if let errorMessage = accounts.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: - 分组过滤区 + 账号列表

    /// 过滤按钮区数据源：全部 + 自定义分组 + 未分组（隐藏分组不显示）。
    private var filterChips: [GroupFilterView.ChipData] {
        accounts.groups.filter { !$0.isHidden }.map { group in
            let running = group.accounts.filter { isRunning($0) }.count
            return GroupFilterView.ChipData(
                id: group.id,
                title: group.groupName,
                detail: group.accounts.isEmpty ? nil : "\(running)/\(group.accounts.count)",
                color: group.macSwatchColor,
                isSelected: group.id == AccountGroup.allID
                    ? accounts.selectedGroupID == nil || accounts.selectedGroupID == AccountGroup.allID
                    : accounts.selectedGroupID == group.id
            )
        }
    }

    /// 分组行（位于搜索栏上方）：分组标签列表 + 行尾「增加分组 / 管理分组」按钮。
    /// 标签云流式布局；标签过多换行时按钮跟随流动，不会被挤变形。
    private var groupFilterRow: some View {
        GroupFilterView(
            chips: filterChips,
            onSelect: selectFilterGroup,
            onStartGroup: startGroupByID,
            onStopGroup: stopGroupByID,
            onAddAccount: importIntoGroup,
            // 「＋增加分组」：打开分组弹窗并直接进入新建分组模式。
            onAddGroup: {
                groupManagementMode = .create
                isPresentingGroupManagement = true
            },
            onManageGroups: {
                groupManagementMode = .list
                isPresentingGroupManagement = true
            }
        )
    }

    /// 过滤 + 搜索后的扁平账号列表。
    private var displayAccounts: [Account] {
        let base = accounts.filteredAccounts
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter { $0.nickname.localizedCaseInsensitiveContains(query) }
    }

    private var currentFilterAllSelected: Bool {
        !displayAccounts.isEmpty && displayAccounts.allSatisfy { accounts.selectedIDs.contains($0.id) }
    }

    private var accountList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                HStack {
                    Button {
                        accounts.toggleSelection(forGroupID: accounts.selectedGroupID)
                    } label: {
                        Image(systemName: currentFilterAllSelected ? "checkmark.square.fill" : "square")
                            .foregroundStyle(.cyan)
                    }
                    .buttonStyle(.plain)
                    .help("全选当前列表")
                    Text(accounts.selectedGroupTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(displayAccounts.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                if displayAccounts.isEmpty {
                    Text(accounts.selectedGroupID == nil ? "还没有账号，点击上方“添加账号”导入" : "该分组暂无账号")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else {
                    ForEach(displayAccounts) { account in
                        AccountManagerRow(
                            account: account,
                            isSelected: accounts.selectedIDs.contains(account.id),
                            isRunning: isRunning(account),
                            onToggle: { accounts.toggleSelection(id: account.id) },
                            onStart: { start(account) },
                            onStop: { stop(account) },
                            onDelete: { requestDeletion(of: [account]) },
                            groupNames: accounts.groupNames,
                            currentGroupName: account.groupName,
                            onMoveToGroup: { groupName in accounts.updateGroup(groupName, for: account) }
                        )
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: - 过滤交互

    /// 点击过滤标签：点"全部"回到 nil；再次点击已选分组取消选中（回到全部）。
    private func selectFilterGroup(_ groupID: String) {
        if groupID == AccountGroup.allID {
            accounts.selectedGroupID = nil
        } else if accounts.selectedGroupID == groupID {
            accounts.selectedGroupID = nil
        } else {
            accounts.selectedGroupID = groupID
        }
    }

    private func groupByID(_ groupID: String) -> AccountGroup? {
        accounts.groups.first { $0.id == groupID }
    }

    private func startGroupByID(_ groupID: String) {
        if let group = groupByID(groupID) { startGroup(group) }
    }

    private func stopGroupByID(_ groupID: String) {
        if let group = groupByID(groupID) { stopGroup(group) }
    }

    // MARK: - 批量启停

    private func start(_ account: Account) {
        accounts.recordLogin(for: account)
        coordinator.openWorkspace(accounts: [account])
    }

    private func stop(_ account: Account) {
        if let item = liveWorkspace.items.first(where: { $0.account.id == account.id }) {
            Task { await liveWorkspace.close(id: item.id) }
        }
    }

    /// 一键启动分组：遍历组内账号并批量拉起实例。
    /// WorkspaceViewModel.start 会自动跳过已运行的账号，因此可以全量传入。
    private func startGroup(_ group: AccountGroup) {
        guard !group.accounts.isEmpty else { return }
        group.accounts.forEach { accounts.recordLogin(for: $0) }
        coordinator.openWorkspace(accounts: group.accounts)
    }

    /// 一键停止分组：遍历组内账号，逐个关闭其运行中的实例。
    private func stopGroup(_ group: AccountGroup) {
        let memberIDs = Set(group.accounts.map(\.id))
        let itemIDs = liveWorkspace.items
            .filter { memberIDs.contains($0.account.id) }
            .map(\.id)
        guard !itemIDs.isEmpty else { return }
        Task {
            for id in itemIDs {
                await liveWorkspace.close(id: id)
            }
        }
    }

    private func startAll() {
        let allAccounts = accounts.accounts
        guard !allAccounts.isEmpty else { return }
        allAccounts.forEach { accounts.recordLogin(for: $0) }
        coordinator.openWorkspace(accounts: allAccounts)
    }

    private func closeAll() {
        let ids = liveWorkspace.items.map(\.id)
        Task { for id in ids { await liveWorkspace.close(id: id) } }
    }

    /// 从分组表头的 ➕ 触发：导入账号并直接归入该分组。
    private func importIntoGroup(_ groupID: String) {
        importTargetGroupID = groupID
        isPresentingImporter = true
    }

    private func requestDeletion(of targets: [Account]) {
        let runningCount = targets.filter { account in
            liveWorkspace.items.contains { $0.account.id == account.id }
        }.count
        guard runningCount == 0 else {
            deletionBlockedMessage = runningCount == 1
                ? "请先关闭该账号的游戏实例，再删除账号。"
                : "请先关闭这 \(runningCount) 个账号的游戏实例，再批量删除。"
            return
        }
        deletionRequest = AccountDeletionRequest(accounts: targets)
    }

    private var secondarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(selectedSection.title).font(.system(size: 20, weight: .bold))
            Text(selectedSection == .scripts ? "脚本插件将在这里管理。" : "应用与缓存设置。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if selectedSection == .settings { SettingsView().frame(maxHeight: 430) }
            if selectedSection == .scripts { PluginPanelView(workspace: liveWorkspace).frame(maxHeight: 430) }
        }
        .padding(18)
    }

    private var workspace: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 14
            // 画布容器外边距 24×2 + 容器内边距 16×2 = 80
            let availableWidth = max(160, proxy.size.width - 80)
            let automaticColumns = max(1, Int((availableWidth + spacing) / (instanceWidth + spacing)))
            let columnCount = max(1, fixedColumnCount ?? automaticColumns)
            // In a fixed-column layout, fit the requested number into the
            // available width. The size buttons still control the preferred
            // width, while the grid never creates an accidental landscape
            // card or clips the game surface.
            let fittedWidth = (availableWidth - spacing * CGFloat(max(0, columnCount - 1))) / CGFloat(columnCount)
            let cardWidth = fixedColumnCount == nil ? instanceWidth : min(instanceWidth, max(96, fittedWidth))
            VStack(spacing: 0) {
                workspaceHeader
                matrixCanvas(cardWidth: cardWidth, columnCount: columnCount, spacing: spacing)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }
        }
    }

    /// 顶部控制条：固定在氛围光上，不随卡片滚动（参考稿同款布局）。
    private var workspaceHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible.toggle() } } label: {
                Image(systemName: sidebarVisible ? "sidebar.left" : "sidebar.right")
            }
            .buttonStyle(MacManagerButtonStyle(tint: .gray))
            .help(sidebarVisible ? "隐藏侧边栏" : "显示侧边栏")
            VStack(alignment: .leading, spacing: 4) {
                Text("多开矩阵").font(.system(size: 24, weight: .bold))
                Text("\(allRunningAccounts.count) 个活跃实例 · 每个账号独立 WebKit 会话")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Text("尺寸 \(Int(instanceWidth)) · 9:16")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button {
                    instanceWidth = max(160, instanceWidth - 20)
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(MacManagerButtonStyle(tint: .gray))
                Button {
                    instanceWidth = min(720, instanceWidth + 20)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(MacManagerButtonStyle(tint: .gray))
            }
            Menu {
                Button {
                    fixedColumnCount = nil
                } label: {
                    if fixedColumnCount == nil {
                        Label("自动", systemImage: "checkmark")
                    } else {
                        Text("自动")
                    }
                }
                Divider()
                ForEach(1...12, id: \.self) { count in
                    Button {
                        fixedColumnCount = count
                    } label: {
                        if fixedColumnCount == count {
                            Label("每行 \(count) 个", systemImage: "checkmark")
                        } else {
                            Text("每行 \(count) 个")
                        }
                    }
                }
            } label: {
                Label(
                    fixedColumnCount.map { "布局：每行 \($0) 个" } ?? "布局：自动",
                    systemImage: "rectangle.split.3x1"
                )
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(MacManagerButtonStyle(tint: .gray))
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// 玻璃画布容器（参考稿主区的大圆角玻璃面）：卡片矩阵装在玻璃里，
    /// 四周留出氛围光。02 白填充 4% + 03 ultraThin 模糊 + 折射增压 + 压暗；
    /// 描边与投影挂在 background 之外，避免随滚动内容重绘。
    private func matrixCanvas(cardWidth: CGFloat, columnCount: Int, spacing: CGFloat) -> some View {
        ScrollView {
            Group {
                if allRunningAccounts.isEmpty {
                    EmptyMatrixView { selectedSection = .accounts }
                } else {
                    // 矩阵数据源绑定 allRunningAccounts（flatMap 展平所有分组的运行中账号），
                    // 单元格仍复用 WorkspaceItem 以保留暂停/恢复/关闭等实例控制。
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: columnCount), spacing: spacing) {
                        ForEach(allRunningAccounts) { account in
                            if let item = liveWorkspace.items.first(where: { $0.account.id == account.id }) {
                                MacGameMatrixCell(item: item, workspace: liveWorkspace, width: cardWidth)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(canvasGlass)
        .overlay { canvasGlassStroke }
        .shadow(color: .black.opacity(0.38), radius: 24, x: 0, y: 16)
    }

    /// 画布玻璃面：材质模糊（03）→ 氛围光折射增压 → 压暗 → 白填充（02）。
    private var canvasGlass: some View {
        ZStack {
            // ultraThin：材质自带的灰色填充更少——thin 的灰在暗底上会显成一整块灰板
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
            AmbientRefractionTint()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            // 深藏蓝罩代替「黑+白」双层：纯黑/纯白是中性色，混进深蓝氛围必被读成灰；
            // 用同色相的深蓝压暗，玻璃面与周围氛围保持同一色温
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.012, green: 0.032, blue: 0.085).opacity(0.42))
        }
    }

    /// 04/05：1px 渐变描边（Inside 对齐），上亮下暗等效顶边内高光。
    private var canvasGlassStroke: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                LinearGradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0.10), Color.white.opacity(0.07)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1
            )
    }
}

private struct AccountDeletionRequest: Identifiable {
    let id = UUID()
    let accounts: [Account]
}

// MARK: - 分组过滤按钮区（标签云）

/// 侧边栏分组过滤组件：标签云式流式布局，超宽自动换行。
/// 选中态填充主题色 + 白字；未选中态透明底 + 1px 主题色描边 + 同色文字。
/// 每个标签附带右键菜单：启动此组 / 停止此组 / 添加账号到此组。
/// `onAddGroup` / `onManageGroups` 非 nil 时，在标签列表末尾追加对应按钮
///（如「增加分组」），随流式布局一起换行。刻意保持非泛型：泛型会让
/// `GroupFilterView.ChipData` 这类嵌套类型引用必须写泛型参数。
struct GroupFilterView: View {
    struct ChipData: Identifiable {
        let id: String
        let title: String
        /// 角标（如 "3/10" 运行中/总数），nil 不显示。
        let detail: String?
        let color: Color
        let isSelected: Bool
    }

    let chips: [ChipData]
    /// 点击标签回调（父级负责全部/取消选中的语义）。
    let onSelect: (String) -> Void
    let onStartGroup: (String) -> Void
    let onStopGroup: (String) -> Void
    let onAddAccount: (String) -> Void
    /// 非 nil 时在标签列表末尾追加「增加分组」按钮（随流式布局换行）。
    var onAddGroup: (() -> Void)? = nil
    /// 非 nil 时在「增加分组」之后追加「管理分组」按钮。
    var onManageGroups: (() -> Void)? = nil

    var body: some View {
        // macOS 13+ 使用原生 Layout 协议流式布局；
        // 部署目标 12.0 回退到 LazyVGrid 自适应列（等宽换行网格）。
        Group {
            if #available(macOS 13.0, *) {
                FlowLayout(spacing: 6) {
                    ForEach(chips) { chip in
                        chipView(chip)
                    }
                    trailingButtons
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 84, maximum: 140), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(chips) { chip in
                        chipView(chip)
                    }
                    trailingButtons
                }
            }
        }
    }

    /// 行尾按钮区：与过滤标签（≈24pt）同高，流式布局内垂直居中对齐。
    @ViewBuilder
    private var trailingButtons: some View {
        if onAddGroup != nil || onManageGroups != nil {
            HStack(spacing: 8) {
                if let onAddGroup {
                    Button(action: onAddGroup) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.cyan)
                    .help("增加分组")
                    .accessibilityLabel("增加分组")
                }
                if let onManageGroups {
                    Button(action: onManageGroups) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.cyan)
                    .help("管理分组")
                    .accessibilityLabel("管理分组")
                }
            }
            .frame(height: 24, alignment: .center)
        }
    }

    @ViewBuilder
    private func chipView(_ chip: ChipData) -> some View {
        GroupFilterChip(data: chip, action: { onSelect(chip.id) })
            .contextMenu {
                Button { onStartGroup(chip.id) } label: {
                    Label("启动此组", systemImage: "play.fill")
                }
                Button { onStopGroup(chip.id) } label: {
                    Label("停止此组", systemImage: "stop.fill")
                }
                Divider()
                Button { onAddAccount(chip.id) } label: {
                    Label("添加账号到此组", systemImage: "person.crop.badge.plus")
                }
            }
    }
}

/// 单个过滤标签按钮（胶囊样式：未选中描边同色文字，选中填充主题色白字）。
private struct GroupFilterChip: View {
    let data: GroupFilterView.ChipData
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(data.title)
                    .lineLimit(1)
                if let detail = data.detail {
                    Text(detail)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .opacity(0.75)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(data.isSelected ? Color.white : data.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(data.isSelected ? data.color : Color.white.opacity(0.05))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(data.color.opacity(data.isSelected ? 1 : 0.85), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(data.title)
    }
}

/// macOS 13+ 原生流式布局：子视图按固有尺寸从左到右排列，超出容器宽度自动换行。
@available(macOS 13.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : max(0, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 账号行（保留：复选框 + 名称 + 分组菜单 + 独立启停）

private struct AccountManagerRow: View {
    let account: Account; let isSelected: Bool; let isRunning: Bool
    let onToggle: () -> Void; let onStart: () -> Void; let onStop: () -> Void; let onDelete: () -> Void
    let groupNames: [String]
    let currentGroupName: String
    let onMoveToGroup: (String) -> Void
    @State private var isDeleteRevealed = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 52, height: 34)
                    .foregroundStyle(.white)
                    .background(Color.red.opacity(isRunning ? 0.35 : 0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(isRunning)
            .help(isRunning ? "请先关闭实例" : "删除账号")
            .opacity(isDeleteRevealed ? 1 : 0)
            .zIndex(2)

            HStack(spacing: 8) {
                Button(action: onToggle) { Image(systemName: isSelected ? "checkmark.square.fill" : "square").foregroundStyle(.cyan) }.buttonStyle(.plain)
                Text(account.nickname).lineLimit(1).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 4)
                Menu { groupActions } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.cyan)
                }
                .menuStyle(.borderlessButton)
                .help("移动到分组")
                .accessibilityLabel("移动到分组")
                Circle().fill(isRunning ? Color.green : Color.gray.opacity(0.55)).frame(width: 7, height: 7)
                Button(action: isRunning ? onStop : onStart) { Image(systemName: isRunning ? "stop.fill" : "play.fill") }
                    .buttonStyle(.plain).foregroundStyle(isRunning ? .orange : .green)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.cyan.opacity(0.12) : Color.white.opacity(0.035))
            .offset(x: dragOffset)
            .contentShape(Rectangle())
            .contextMenu {
                Menu("移动到分组") {
                    groupActions
                }
            }
            .allowsHitTesting(!isDeleteRevealed)
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard value.translation.width < 0 || isDeleteRevealed else { return }
                        let baseOffset: CGFloat = isDeleteRevealed ? -60 : 0
                        dragOffset = max(-60, baseOffset + value.translation.width)
                    }
                    .onEnded { value in
                        let shouldReveal = isDeleteRevealed
                            ? value.translation.width > -24 ? false : true
                            : value.translation.width < -34
                        withAnimation(.easeOut(duration: 0.16)) {
                            isDeleteRevealed = shouldReveal
                            dragOffset = shouldReveal ? -60 : 0
                        }
                    }
            )
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var groupActions: some View {
        ForEach(groupNames, id: \.self) { groupName in
            Button {
                onMoveToGroup(groupName)
            } label: {
                if groupName == currentGroupName {
                    Label(groupName, systemImage: "checkmark")
                } else {
                    Text(groupName)
                }
            }
        }
    }
}

private extension AccountGroup {
    var macSwatchColor: Color {
        switch colorName {
        case "green": return Color(red: 0.19, green: 0.82, blue: 0.35)
        case "orange": return Color(red: 1, green: 0.58, blue: 0.16)
        case "red": return Color(red: 1, green: 0.27, blue: 0.23)
        case "purple": return Color(red: 0.69, green: 0.39, blue: 0.94)
        case "teal": return Color(red: 0.22, green: 0.74, blue: 0.70)
        case "yellow": return Color(red: 1, green: 0.78, blue: 0.12)
        case "gray": return Color(red: 0.56, green: 0.56, blue: 0.60)
        default: return Color(red: 0.16, green: 0.59, blue: 1)
        }
    }
}

private struct MacGameMatrixCell: View {
    let item: WorkspaceItem
    @ObservedObject var workspace: WorkspaceViewModel
    let width: CGFloat
    @State private var reloadKey = UUID()
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(workspace.items.firstIndex(where: { $0.id == item.id }).map { $0 + 1 } ?? 0)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.black)
                    .frame(width: 22, height: 22).background(.white).clipShape(Circle())
                Text(item.account.nickname).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Circle().fill(item.host.state == .running ? Color.green : Color.orange).frame(width: 7, height: 7)
                Button { Task { if item.host.state == .running { await workspace.pause(id: item.id) } else { await workspace.resume(id: item.id) } } } label: { Image(systemName: item.host.state == .paused ? "play.fill" : "pause.fill") }
                Button { reloadKey = UUID() } label: { Image(systemName: "arrow.clockwise") }
                Button { Task { await workspace.close(id: item.id) } } label: { Image(systemName: "xmark") }.foregroundStyle(.red)
            }
            // 卡片头部条：深色玻璃面（参考稿同款），不与氛围光抢色
            .padding(.horizontal, 10).frame(height: 38).background(Color.black.opacity(0.45))
            MacEmbeddedGameView(account: item.account).id(reloadKey)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The game is a portrait surface: width:height = 9:16.
                // Keeping this ratio prevents the WebView from being laid
                // out as a landscape rectangle with side bars.
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
        }
        .frame(width: width)
        // 卡片叠在已模糊 50 档的面板上，游戏 WebView 又几乎铺满卡面，
        // 再叠一层材质只会在圆角缝隙里可见、白耗一层模糊合成——只做 02/04/05/06。
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // 04 1px 白描边（Inside 对齐）+ 05 顶边内高光：上亮下暗渐变描边
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.10)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
        }
        // 06 外投影：黑 35% / y 12 / blur≈32——卡片浮在画布玻璃上，投影比画布轻一档
        .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 12)
    }
}

private struct EmptyMatrixView: View {
    let onManage: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.3.group").font(.system(size: 42)).foregroundStyle(.secondary)
            Text("暂无运行中的账号").font(.system(size: 18, weight: .semibold))
            Button("选择账号并启动", action: onManage).buttonStyle(MacManagerButtonStyle(tint: .green))
        }
        .frame(maxWidth: .infinity, minHeight: 420)
        // 已在画布玻璃之上：不再叠材质（双层 blur 只会更暗更灰），只做白填充+描边+投影
        .glassCard(cornerRadius: 10, material: nil)
    }
}

private struct MacManagerButtonStyle: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        // tint == .white 是「白色玻璃」特殊档：白 16% 填充 + 黑字，用于深蓝底上的中性主按钮
        configuration.label.font(.system(size: 12, weight: .semibold))
            // 统一内容行高：任何 SF Symbol 的固有高度都不会把个别按钮撑高，
            // 走此样式的按钮严格等高（16 + 7×2 = 30pt）。
            .frame(height: 16, alignment: .center)
            .foregroundStyle(tint == .white ? Color.black : Color.white)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(tint.opacity(configuration.isPressed ? 0.65 : (tint == .white ? 0.16 : 0.85)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // 1px 白描边：色块按钮从深蓝背景/玻璃上「浮起来」的最低成本手段
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.20)))
    }
}

// MARK: - 毛玻璃六步配方

/// 径向色斑：配方 01 的基本单元（氛围光与折射增压共用）。
/// 三段式衰减（实→40%→0）让色斑边缘更奶，整体雾感更强。
private func glowBlob(_ rgb: UInt32, _ opacity: Double, _ center: UnitPoint, _ radius: CGFloat) -> some View {
    RadialGradient(
        colors: [Color(rgb: rgb).opacity(opacity),
                 Color(rgb: rgb).opacity(opacity * 0.4),
                 Color(rgb: rgb).opacity(0)],
        center: center,
        startRadius: 0,
        endRadius: radius
    )
}

/// 配方 01 · 底层氛围光：深色底 + 超大径向色斑。玻璃 = 对背后内容的高斯采样，
/// 这层就是被折射的「内容」；色斑错落布置，避免叠成均匀色。
/// 浓度对齐参考稿：靛蓝/紫/青高饱和大色斑，肉眼可辨的星云感。
/// 高对比细节层（星场 + 光束）：毛玻璃的「证据」。玻璃外它们是锐利亮点/亮带，
/// 透过侧栏与画布材质后变成柔光斑——锐与柔的同屏对比就是「真的是毛玻璃」的
/// 直观证明，比单纯的大渐变色斑明显得多。点位置用固定种子 LCG 生成，启动间完全一致。
private struct AmbientGlowBackground: View {
    static let starColors: [Color] = [.white, Color(rgb: 0x7DD3FC), Color(rgb: 0x67E8F9)]

    private struct Star {
        let x, y, diameter, opacity: Double
        let colorIndex: Int
    }

    private static let stars: [Star] = {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 11) & 0xFFFF) / Double(0xFFFF)
        }
        var result: [Star] = []
        for i in 0..<46 {
            if i % 9 == 0 {
                // 大颗「虚化光斑」：透过玻璃后是明显的 bokeh 圆盘
                result.append(Star(x: next(), y: next(),
                                   diameter: 14 + next() * 14,
                                   opacity: 0.10 + next() * 0.10,
                                   colorIndex: i % 3))
            } else {
                result.append(Star(x: next(), y: next(),
                                   diameter: 1.2 + next() * 2.4,
                                   opacity: 0.25 + next() * 0.55,
                                   colorIndex: i % 3))
            }
        }
        return result
    }()

    var body: some View {
        ZStack {
            // 渊黑蓝底（94% 近不透明）：壁纸只透 6% 的明暗纹理——玻璃折射的
            // 证据保留，但壁纸上的灰亮区块不再显形为「灰色团」
            Color(red: 0.01, green: 0.028, blue: 0.075).opacity(0.94)
            glowBlob(0x2563EB, 0.30, UnitPoint(x: 0.14, y: 0.32), 780) // 深蓝 · 左侧主光（侧栏后）
            glowBlob(0x1D4ED8, 0.24, UnitPoint(x: 0.55, y: 0.38), 820) // 深蓝 · 画布正后方（玻璃要有东西可折射）
            glowBlob(0x1E40AF, 0.22, UnitPoint(x: 0.40, y: 0.04), 500) // 藏蓝 · 顶部左段（工作区头部，堵住无光死区的灰）
            glowBlob(0x1E40AF, 0.22, UnitPoint(x: 0.38, y: 0.92), 760) // 藏蓝 · 底部
            glowBlob(0x22D3EE, 0.24, UnitPoint(x: 0.95, y: 0.42), 860) // 青 · 右缘（与账号区青色呼应）
            glowBlob(0x3B82F6, 0.22, UnitPoint(x: 0.72, y: 0.02), 660) // 蓝 · 顶部
            glowBlob(0x0EA5E9, 0.14, UnitPoint(x: 0.04, y: 0.96), 520) // 天青 · 左下角

            GeometryReader { proxy in
                ZStack {
                    ForEach(Self.stars.indices, id: \.self) { i in
                        let s = Self.stars[i]
                        Circle()
                            .fill(Self.starColors[s.colorIndex].opacity(s.opacity))
                            .frame(width: s.diameter, height: s.diameter)
                            .position(x: s.x * proxy.size.width, y: s.y * proxy.size.height)
                    }
                    // 两道斜向光束：玻璃外是清晰亮带，玻璃内被抹成柔光
                    LinearGradient(colors: [.clear, Color.white.opacity(0.16), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width * 0.9, height: 2)
                        .rotationEffect(.degrees(-24))
                        .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.30)
                    LinearGradient(colors: [.clear, Color(rgb: 0x67E8F9).opacity(0.14), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width * 0.7, height: 1.5)
                        .rotationEffect(.degrees(-24))
                        .position(x: proxy.size.width * 0.62, y: proxy.size.height * 0.62)
                }
            }
        }
    }
}

/// 折射增压：把氛围光主色斑以低透明度再叠一层到玻璃表面，模拟玻璃对背后
/// 高饱和光源的折射着色（参考稿的侧栏/画布都明显带着氛围光色）。系统材质
/// 在不同系统版本对窗内内容的采样强度不一，这层保证玻璃始终吃进颜色。
private struct AmbientRefractionTint: View {
    var body: some View {
        ZStack {
            glowBlob(0x2563EB, 0.15, UnitPoint(x: 0.10, y: 0.28), 540)
            glowBlob(0x1D4ED8, 0.18, UnitPoint(x: 0.55, y: 0.45), 640) // 表面中心主 tint
            glowBlob(0x22D3EE, 0.13, UnitPoint(x: 1.0, y: 0.45), 560)
            glowBlob(0x3B82F6, 0.10, UnitPoint(x: 0.80, y: 0.0), 500)
        }
    }
}

private extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255.0,
                  green: Double((rgb >> 8) & 0xFF) / 255.0,
                  blue: Double(rgb & 0xFF) / 255.0,
                  opacity: 1)
    }
}

/// 配方 02–06 · 卡片级玻璃面：
/// 02 玻璃填充 白 5%；03 ultraThin 模糊（≈28px 档，与面板 .thin≈50 拉开层级）；
/// 04 1px 白描边（strokeBorder = Inside 对齐）；05 顶边内高光（上亮下暗渐变描边，
/// 等效 Inner Shadow 白 16% / y=1 / blur=1）；06 外投影 黑 38% / y 18 / blur≈40
/// （「负 spread / 关闭投影穿透」在 SwiftUI 中天然成立：投影不会穿透半透明填充）。
private struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat
    var fillOpacity: Double
    /// nil = 不加材质：小卡片叠在已模糊的面板上时，省一层模糊合成
    var material: Material? = .ultraThin

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                ZStack {
                    if let material {
                        shape.fill(material)
                    }
                    // 冷蓝白代替中性白：中性白叠在深蓝氛围上必被读成灰
                    shape.fill(Color(red: 0.55, green: 0.68, blue: 0.90).opacity(fillOpacity))
                }
            )
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.10), Color.white.opacity(0.07)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(0.38), radius: 20, x: 0, y: 18)
    }
}

private extension View {
    /// 按六步配方给卡片挂玻璃面；fillOpacity 取 0.04–0.07。
    func glassCard(cornerRadius: CGFloat = 12, fillOpacity: Double = 0.05, material: Material? = .ultraThin) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, fillOpacity: fillOpacity, material: material))
    }
}

/// 真实毛玻璃底：NSVisualEffectView 以 behindWindow 混合直接折射窗口后的桌面
/// 壁纸——访达侧栏/邮件 App 的同款效果，比 SwiftUI Material（窗内模糊+自带灰填充）
/// 明显得多。强制 darkAqua 外观保证暗色振动，上面再由调用方叠品牌深蓝 tint。
private struct VibrancyBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

/// 隐形窗口拖拽区：NSView 的 mouseDownCanMoveWindow=true 时，AppKit 会把
/// 该区域的「按下并拖动」识别为移动窗口（双击 = 缩放）。红黄绿交通灯属于
/// 窗口框架层，永远浮在内容之上，不会被此视图遮挡。
/// 注意：mouseDownCanMoveWindow 是只读属性，必须子类化重写，不能直接赋值。
private struct TitleBarDragRegion: NSViewRepresentable {
    private final class DragRegionView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }

    func makeNSView(context: Context) -> NSView {
        DragRegionView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
