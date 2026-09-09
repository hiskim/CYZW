#if os(macOS)
import SwiftUI

struct MacMultiOpenManagerView: View {
    @ObservedObject var coordinator: AppCoordinator
    @StateObject private var accounts = AccountLibraryViewModel()
    @State private var selectedSection: Section = .accounts
    @State private var searchText = ""

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
            sidebar
                .frame(width: 304)
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            workspace
        }
        .background(Color(red: 0.055, green: 0.075, blue: 0.11))
        .task { accounts.refresh() }
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
                Text("\(coordinator.workspace.items.count)/\(WorkspaceViewModel.maximumInstanceCount)")
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
                Button { startAll() } label: { Label("打开全部", systemImage: "play.fill") }
                    .buttonStyle(MacManagerButtonStyle(tint: .cyan))
                Button { closeAll() } label: { Label("关闭全部", systemImage: "stop.fill") }
                    .buttonStyle(MacManagerButtonStyle(tint: .red))
            }
            .controlSize(.small)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索账号", text: $searchText).textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7))
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
                        isRunning: coordinator.workspace.items.contains { $0.account.id == account.id },
                        onToggle: { accounts.toggleSelection(id: account.id) },
                        onStart: { start(account) },
                        onStop: { stop(account) }
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
            if selectedSection == .scripts { PluginPanelView(workspace: coordinator.workspace).frame(maxHeight: 430) }
        }
        .padding(18)
    }

    private var workspace: some View {
        GeometryReader { proxy in
            let columns = max(1, Int(proxy.size.width / 310))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("多开矩阵").font(.system(size: 24, weight: .bold))
                            Text("\(coordinator.workspace.items.count) 个活跃实例 · 每个账号独立 WebKit 会话")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { selectedSection = .accounts } label: { Label("管理账号", systemImage: "person.2") }
                            .buttonStyle(MacManagerButtonStyle(tint: .blue))
                    }
                    if coordinator.workspace.items.isEmpty {
                        EmptyMatrixView { selectedSection = .accounts }
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 260), spacing: 14), count: columns), spacing: 14) {
                            ForEach(coordinator.workspace.items) { item in
                                MacGameMatrixCell(item: item, workspace: coordinator.workspace)
                                    .frame(minHeight: 420)
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
    private func stop(_ account: Account) { if let item = coordinator.workspace.items.first(where: { $0.account.id == account.id }) { Task { await coordinator.workspace.close(id: item.id) } } }
    private func closeAll() { let ids = coordinator.workspace.items.map(\.id); Task { for id in ids { await coordinator.workspace.close(id: id) } } }
    private func toggleAll() { accounts.toggleSelectAll() }
}

private struct AccountManagerRow: View {
    let account: Account; let isSelected: Bool; let isRunning: Bool
    let onToggle: () -> Void; let onStart: () -> Void; let onStop: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) { Image(systemName: isSelected ? "checkmark.square.fill" : "square").foregroundStyle(.cyan) }.buttonStyle(.plain)
            Text(account.nickname).lineLimit(1).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 4)
            Circle().fill(isRunning ? Color.green : Color.gray.opacity(0.55)).frame(width: 7, height: 7)
            Button(action: isRunning ? onStop : onStart) { Image(systemName: isRunning ? "stop.fill" : "play.fill") }
                .buttonStyle(.plain).foregroundStyle(isRunning ? .orange : .green)
            Button(action: {}) { Image(systemName: "ellipsis") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9).padding(.vertical, 9)
        .background(isSelected ? Color.cyan.opacity(0.12) : Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct MacGameMatrixCell: View {
    let item: WorkspaceItem; @ObservedObject var workspace: WorkspaceViewModel
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
                .background(Color.black)
        }
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
