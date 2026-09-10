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

    private var filteredAccounts: [Account] {
        let source = accounts.accounts(in: .all)
        guard !searchText.isEmpty else { return source }
        return source.filter { $0.nickname.localizedCaseInsensitiveContains(searchText) }
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
            if case let .success(urls) = result { accounts.importFiles(from: urls) }
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

    private var accountControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button { isPresentingImporter = true } label: { Label("添加账号", systemImage: "plus") }
                    .buttonStyle(MacManagerButtonStyle(tint: .blue))
                Button { startAll() } label: { Label("打开全部", systemImage: "play.fill") }
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
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索账号", text: $searchText).textFieldStyle(.plain)
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

    private var accountList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                HStack {
                    Button { toggleAll() } label: {
                        Image(systemName: accounts.allSelected ? "checkmark.square.fill" : "square")
                            .foregroundStyle(.cyan)
                    }.buttonStyle(.plain)
                    Text("全部账号").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(filteredAccounts.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                ForEach(filteredAccounts) { account in
                    AccountManagerRow(
                        account: account,
                        isSelected: accounts.selectedIDs.contains(account.id),
                        isRunning: liveWorkspace.items.contains { $0.account.id == account.id },
                        onToggle: { accounts.toggleSelection(id: account.id) },
                        onStart: { start(account) },
                        onStop: { stop(account) },
                        onDelete: { requestDeletion(of: [account]) }
                    )
                }
            }
            .padding(.horizontal, 8)
        }
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
                            Text("\(liveWorkspace.items.count) 个活跃实例 · 每个账号独立 WebKit 会话")
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
                    if liveWorkspace.items.isEmpty {
                        EmptyMatrixView { selectedSection = .accounts }
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: columnCount), spacing: spacing) {
                            ForEach(liveWorkspace.items) { item in
                                MacGameMatrixCell(item: item, workspace: liveWorkspace, width: cardWidth)
                            }
                        }
                    }
                }
                .padding(24)
            }
            .background(Color(red: 0.075, green: 0.095, blue: 0.135))
        }
    }

    private func start(_ account: Account) { accounts.recordLogin(for: account); coordinator.openWorkspace(accounts: [account]) }
    private func startAll() { let all = accounts.accounts; all.forEach { accounts.recordLogin(for: $0) }; coordinator.openWorkspace(accounts: all) }
    private func stop(_ account: Account) { if let item = liveWorkspace.items.first(where: { $0.account.id == account.id }) { Task { await liveWorkspace.close(id: item.id) } } }
    private func closeAll() { let ids = liveWorkspace.items.map(\.id); Task { for id in ids { await liveWorkspace.close(id: id) } } }
    private func toggleAll() { accounts.toggleSelectAll() }

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
}

private struct AccountDeletionRequest: Identifiable {
    let id = UUID()
    let accounts: [Account]
}

private struct AccountManagerRow: View {
    let account: Account; let isSelected: Bool; let isRunning: Bool
    let onToggle: () -> Void; let onStart: () -> Void; let onStop: () -> Void; let onDelete: () -> Void
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
