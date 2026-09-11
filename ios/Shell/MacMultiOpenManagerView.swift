#if os(macOS)
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
    /// 记录本次文件导入的目标分组（nil = 走默认分组逻辑）。
    @State private var importTargetGroupID: String?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _liveWorkspace = ObservedObject(wrappedValue: coordinator.workspace)
    }

    enum Section: String, CaseIterable, Identifiable {
        case accounts, games, scripts, settings
        var id: String { rawValue }
        var title: String {
            switch self { case .accounts: return "账号"; case .games: return "游戏"; case .scripts: return "脚本"; case .settings: return "设置" }
        }
        var icon: String {
            switch self { case .accounts: return "person.2"; case .games: return "gamecontroller"; case .scripts: return "curlybraces"; case .settings: return "gearshape" }
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
        HStack(spacing: 0) {
            if sidebarVisible {
                sidebar
                    .frame(width: 304)
                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            }
            workspace
        }
        .background(Color(red: 0.055, green: 0.075, blue: 0.11))
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
            GroupManagementView(viewModel: accounts)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.cyan)
                Text("网页游戏中控台")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
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
                groupedAccountList
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
                    .buttonStyle(MacManagerButtonStyle(tint: .blue))
                Button { startAll() } label: {
                    Label("启动全部", systemImage: "play.fill")
                }
                    .buttonStyle(MacManagerButtonStyle(tint: .cyan))
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
            HStack(spacing: 8) {
                Text("分组").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(accounts.visibleGroups.count) 个自定义分组")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { isPresentingGroupManagement = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.cyan)
                .help("管理分组")
                .accessibilityLabel("管理分组")
            }
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

    // MARK: - 树形分组账号列表

    private var groupedAccountList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(accounts.groups) { group in
                    AccountGroupSection(
                        group: group,
                        searchText: searchText,
                        viewModel: accounts,
                        isRunning: isRunning,
                        onToggleSelection: { accounts.toggleSelection(id: $0) },
                        onStart: { start($0) },
                        onStop: { stop($0) },
                        onDelete: { requestDeletion(of: [$0]) },
                        onMoveToGroup: { account, groupName in accounts.updateGroup(groupName, for: account) },
                        onAddAccount: { importIntoGroup(group.id) },
                        onStartGroup: { startGroup(group) },
                        onStopGroup: { stopGroup(group) }
                    )
                }
            }
            .padding(.horizontal, 8)
        }
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
            Text(selectedSection == .games ? "运行中的游戏实例会显示在右侧矩阵。" : selectedSection == .scripts ? "脚本插件将在这里管理。" : "应用与缓存设置。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if selectedSection == .settings { SettingsView().frame(maxHeight: 430) }
            if selectedSection == .scripts { PluginPanelView(workspace: liveWorkspace).frame(maxHeight: 430) }
        }
        .padding(18)
    }

    private var workspace: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 14
            let availableWidth = max(160, proxy.size.width - 48)
            let automaticColumns = max(1, Int((availableWidth + spacing) / (instanceWidth + spacing)))
            let columnCount = max(1, fixedColumnCount ?? automaticColumns)
            // In a fixed-column layout, fit the requested number into the
            // available width. The size buttons still control the preferred
            // width, while the grid never creates an accidental landscape
            // card or clips the game surface.
            let fittedWidth = (availableWidth - spacing * CGFloat(max(0, columnCount - 1))) / CGFloat(columnCount)
            let cardWidth = fixedColumnCount == nil ? instanceWidth : min(instanceWidth, max(96, fittedWidth))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
                        Button { selectedSection = .accounts } label: { Label("管理账号", systemImage: "person.2") }
                            .buttonStyle(MacManagerButtonStyle(tint: .blue))
                    }
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
                .padding(24)
            }
            .background(Color(red: 0.075, green: 0.095, blue: 0.135))
        }
    }
}

private struct AccountDeletionRequest: Identifiable {
    let id = UUID()
    let accounts: [Account]
}

// MARK: - 分组节点（DisclosureGroup）

/// 单个分组的树形节点：可展开表头 + 组内账号行。
/// 表头展示「分组名 [运行中/总数]」与快捷操作（添加账号 / 一键启动 / 一键停止）。
private struct AccountGroupSection: View {
    let group: AccountGroup
    let searchText: String
    @ObservedObject var viewModel: AccountLibraryViewModel
    let isRunning: (Account) -> Bool
    let onToggleSelection: (String) -> Void
    let onStart: (Account) -> Void
    let onStop: (Account) -> Void
    let onDelete: (Account) -> Void
    let onMoveToGroup: (Account, String) -> Void
    let onAddAccount: () -> Void
    let onStartGroup: () -> Void
    let onStopGroup: () -> Void

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 搜索时在组内过滤；无搜索时展示全组账号。
    private var displayAccounts: [Account] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return group.accounts }
        return group.accounts.filter { $0.nickname.localizedCaseInsensitiveContains(query) }
    }

    private var runningCount: Int {
        group.accounts.filter { isRunning($0) }.count
    }

    /// 展开状态绑定：搜索时强制展开，其余读写持久化的 isExpanded。
    private var expansionBinding: Binding<Bool> {
        Binding(
            get: {
                if isSearching { return true }
                return viewModel.groups.first(where: { $0.id == group.id })?.isExpanded ?? true
            },
            set: { viewModel.setExpanded($0, forGroupID: group.id) }
        )
    }

    var body: some View {
        if isSearching && displayAccounts.isEmpty {
            EmptyView()
        } else {
            DisclosureGroup(isExpanded: expansionBinding) {
                LazyVStack(spacing: 4) {
                    ForEach(displayAccounts) { account in
                        AccountManagerRow(
                            account: account,
                            isSelected: viewModel.selectedIDs.contains(account.id),
                            isRunning: isRunning(account),
                            onToggle: { onToggleSelection(account.id) },
                            onStart: { onStart(account) },
                            onStop: { onStop(account) },
                            onDelete: { onDelete(account) },
                            groupNames: viewModel.groupNames,
                            currentGroupName: account.groupName,
                            onMoveToGroup: { onMoveToGroup(account, $0) }
                        )
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 4)
                .padding(.bottom, 6)
            } label: {
                header
            }
            .background(Color.white.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(group.macSwatchColor)
                .frame(width: 8, height: 8)
            Text(group.groupName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text("[\(runningCount)/\(group.accounts.count)]")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(runningCount > 0 ? Color.green : Color.secondary)
            Spacer(minLength: 6)
            quickActions
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    /// 表头快捷按钮区：添加账号 ➕ / 一键启动 ▶️ / 一键停止 ⏹️。
    private var quickActions: some View {
        HStack(spacing: 6) {
            Button(action: onAddAccount) {
                Image(systemName: "person.crop.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.cyan)
            }
            .buttonStyle(.plain)
            .help("添加账号到此组")
            .accessibilityLabel("添加账号到\(group.groupName)")

            Button(action: onStartGroup) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .disabled(group.accounts.isEmpty)
            .opacity(group.accounts.isEmpty ? 0.35 : 1)
            .help("一键启动此组")
            .accessibilityLabel("启动\(group.groupName)")

            Button(action: onStopGroup) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .disabled(runningCount == 0)
            .opacity(runningCount == 0 ? 0.35 : 1)
            .help("一键停止此组")
            .accessibilityLabel("停止\(group.groupName)")
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
            .padding(.horizontal, 10).frame(height: 38).background(Color(red: 0.08, green: 0.56, blue: 0.57))
            MacEmbeddedGameView(account: item.account).id(reloadKey)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The game is a portrait surface: width:height = 9:16.
                // Keeping this ratio prevents the WebView from being laid
                // out as a landscape rectangle with side bars.
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
        }
        .frame(width: width)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(Color.cyan.opacity(0.55), lineWidth: 1) }
        .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
    }
}

private struct EmptyMatrixView: View {
    let onManage: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.3.group").font(.system(size: 42)).foregroundStyle(.secondary)
            Text("暂无运行中的账号").font(.system(size: 18, weight: .semibold))
            Button("选择账号并启动", action: onManage).buttonStyle(MacManagerButtonStyle(tint: .cyan))
        }
        .frame(maxWidth: .infinity, minHeight: 420).background(Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct MacManagerButtonStyle: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 11).padding(.vertical, 7).background(tint.opacity(configuration.isPressed ? 0.65 : 0.85)).clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
#endif
