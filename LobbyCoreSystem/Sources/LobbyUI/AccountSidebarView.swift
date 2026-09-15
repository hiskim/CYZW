import SwiftUI
import UniformTypeIdentifiers
import LobbyDomain
import LobbyEngine

/// 账号分节：分组筛选条 + 分组管理 + 账号卡片列表 + 导入入口。
/// 语义与上一代对齐：分组过滤（全部/未分组/自定义）、按归属表移动账号、
/// 分组 CRUD（重命名/改色/排序/删除，删除可选连成员一起删）。
struct AccountSidebarView: View {
    @ObservedObject var session: LobbySessionModel
    /// 群控中控：分组 chip 的同步状态指示随它刷新。
    @ObservedObject private var sync: InputSyncController
    /// 侧栏筛选选中分组；nil = 全部。
    @State private var selectedGroupID: String?
    /// 分组编辑弹窗（create = 新建；edit(group) = 编辑既有分组）。
    @State private var draft: GroupDraft?

    init(session: LobbySessionModel) {
        _session = ObservedObject(wrappedValue: session)
        _sync = ObservedObject(wrappedValue: session.sync)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            groupFilterBar
            if filteredAccounts.isEmpty {
                emptyState
            } else {
                accountList
            }
        }
        .sheet(item: $draft) { draft in
            GroupEditorSheet(session: session, draft: draft) {
                self.draft = nil
            }
        }
        .confirmationDialog(
            "删除账号",
            isPresented: Binding(
                get: { session.deletionCandidate != nil },
                set: { if !$0 { session.deletionCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除「\(session.deletionCandidate?.nickname ?? "")」的账号文件", role: .destructive) {
                session.confirmDelete()
            }
            Button("取消", role: .cancel) { session.deletionCandidate = nil }
        } message: {
            Text("凭据文件将被永久删除，且不可恢复。若该账号正在运行，实例会先被关闭。")
        }
    }

    private var filteredAccounts: [GameAccount] {
        guard let selectedGroupID else { return session.accounts }
        return session.accounts(inGroupID: selectedGroupID)
    }

    private var filterTitle: String {
        guard let selectedGroupID else { return "全部账号" }
        return session.groupName(forGroupID: selectedGroupID)
    }

    private var header: some View {
        HStack {
            Text(filterTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(filteredAccounts.count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                draft = GroupDraft()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 11, intensity: 0.15)
            .help("新建分组")

            Button {
                showImportPanel()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 11, intensity: 0.15)
            .help("导入 .bin 账号文件")
        }
    }

    /// 分组筛选条：横向胶囊（全部 / 未分组 / 自定义分组…），右键出快捷操作。
    private var groupFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(session.groupTree) { group in
                    groupChip(group)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func groupChip(_ group: AccountGroup) -> some View {
        let isSelected = (selectedGroupID ?? AccountGroup.allID) == group.id
        let swatch = GroupSwatch.rgb(for: group.colorName)
        return Button {
            selectedGroupID = group.isSynthetic && group.id == AccountGroup.allID ? nil : group.id
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color(red: swatch.0, green: swatch.1, blue: swatch.2))
                    .frame(width: 7, height: 7)
                Text(group.groupName)
                    .font(.system(size: 11, weight: .semibold))
                // 分组同步中：青色链接角标（点击分组右键可关闭组内同步）。
                if !group.isSynthetic, sync.isGroupSyncEnabled(group.id) {
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.cyan)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.72))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? Color.cyan.opacity(0.28) : Color.white.opacity(0.05))
            )

        }
        .buttonStyle(.plain)
        .lobbyHoverHighlight(cornerRadius: 50, intensity: 0.10)
        .contextMenu { groupActions(group) }
    }

    @ViewBuilder
    private func groupActions(_ group: AccountGroup) -> some View {
        if !group.isSynthetic {
            Button("编辑分组…") {
                draft = GroupDraft(group: group,
                                   name: group.groupName,
                                   colorName: group.colorName,
                                   memberIDs: Set(session.accounts(inGroupID: group.id).map(\.id)))
            }
            if session.groupDefinitions.count > 1 {
                Button("上移") { session.moveGroup(id: group.id, offset: -1) }
                Button("下移") { session.moveGroup(id: group.id, offset: 1) }
            }
            Divider()
        }
        let liveCount = session.accounts(inGroupID: group.id).filter { session.isRunning($0) }.count
        Button("启动组内全部账号（\(session.accounts(inGroupID: group.id).count)）") {
            for account in session.accounts(inGroupID: group.id) {
                session.launch(account)
            }
        }
        if liveCount > 0 {
            Button("关闭组内全部实例（\(liveCount)）") {
                for account in session.accounts(inGroupID: group.id) where session.isRunning(account) {
                    session.close(account)
                }
            }
            if session.sync.isGroupSyncEnabled(group.id) {
                Button("关闭组内同步") { session.sync.disableGroup(group.id) }
            } else {
                Button("开启组内同步") { session.sync.enableGroup(group.id) }
            }
        }
        if !group.isSynthetic {
            Divider()
            Button("删除分组…", role: .destructive) {
                session.groupDeletionCandidate = group
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(selectedGroupID == nil ? "还没有账号" : "该分组暂无账号")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("点击右上角 + 导入 .bin 凭据文件\n与上一代大厅共用同一账号库")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .lobbyGlassCard(cornerRadius: 12, fillOpacity: 0.04, material: nil)
    }

    /// 原生 List + .onMove：macOS 下行自带拖拽重排（无需编辑模式）。
    /// 行背景/分隔线/内边距全部清零，保留卡片玻璃观感。
    private var accountList: some View {
        List {
            ForEach(filteredAccounts) { account in
                AccountSidebarCard(session: session,
                                   account: account,
                                   groupContextID: selectedGroupID ?? AccountGroup.allID)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .onMove { source, destination in
                session.moveAccounts(inGroupID: selectedGroupID ?? AccountGroup.allID,
                                     from: source, to: destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func showImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        panel.message = "选择要导入的 .bin 账号文件"
        panel.begin { response in
            guard response == .OK else { return }
            session.importFiles(from: panel.urls, targetGroupID: selectedGroupID)
        }
    }
}

// MARK: - 分组编辑草稿

/// 分组新建 / 编辑的弹窗状态。`group == nil` 表示新建。
struct GroupDraft: Identifiable {
    let id = UUID()
    var group: AccountGroup?
    var name: String = ""
    var colorName: String = "blue"
    var memberIDs: Set<String> = []
}

/// 分组编辑弹窗：名称 + 色板 + 成员勾选（编辑态生效）。
struct GroupEditorSheet: View {
    @ObservedObject var session: LobbySessionModel
    @State var draft: GroupDraft
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.group == nil ? "新建分组" : "编辑分组")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)

            TextField("分组名称", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))

            HStack(spacing: 6) {
                ForEach(GroupSwatch.palette, id: \.name) { entry in
                    let rgb = GroupSwatch.rgb(for: entry.name)
                    Button {
                        draft.colorName = entry.name
                    } label: {
                        Circle()
                            .fill(Color(red: rgb.0, green: rgb.1, blue: rgb.2))
                            .frame(width: 20, height: 20)
                            .overlay(
                                Circle().strokeBorder(
                                    draft.colorName == entry.name ? Color.white : Color.clear,
                                    lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(entry.label)
                }
                Spacer()
                Text(draft.colorName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if draft.group != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("成员（勾选 = 归入本分组）")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(session.accounts) { account in
                                memberRow(account)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }

            HStack {
                Spacer()
                Button("取消", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.14)))
    }

    private func memberRow(_ account: GameAccount) -> some View {
        let isSelected = draft.memberIDs.contains(account.id)
        return Button {
            if isSelected {
                draft.memberIDs.remove(account.id)
            } else {
                draft.memberIDs.insert(account.id)
            }
        } label: {
            HStack {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.cyan : Color.secondary)
                Text(account.nickname)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func save() {
        if let group = draft.group {
            session.updateGroup(id: group.id, name: draft.name, colorName: draft.colorName)
            // 成员勾选全量覆盖：勾中的归入本组，原本在本组但没勾的回落未分组。
            let previousMembers = Set(session.accounts(inGroupID: group.id).map(\.id))
            for accountID in previousMembers where !draft.memberIDs.contains(accountID) {
                session.assign(accountID: accountID, toGroupID: AccountGroup.ungroupedID)
            }
            for accountID in draft.memberIDs {
                session.assign(accountID: accountID, toGroupID: group.id)
            }
        } else {
            session.addGroup(named: draft.name, colorName: draft.colorName)
            if let created = session.groupDefinitions.first(where: { $0.groupName == draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                for accountID in draft.memberIDs {
                    session.assign(accountID: accountID, toGroupID: created.id)
                }
            }
        }
        onDismiss()
    }
}

/// 侧栏账号卡片（含分组着色、「移动到分组」菜单与原生拖拽排序）。
struct AccountSidebarCard: View {
    @ObservedObject var session: LobbySessionModel
    let account: GameAccount
    /// 拖拽排序的分组上下文（当前筛选视图的分组 ID，「全部」= allID）。
    let groupContextID: String

    private var isRunning: Bool { session.isRunning(account) }
    private var isFocused: Bool { session.focusedAccountID == account.id }
    private var swatch: (Double, Double, Double) {
        GroupSwatch.rgb(for: session.groupColorName(forAccountID: account.id))
    }

    var body: some View {
        HStack(spacing: 10) {
            // 28×28 图标磁贴（卡片头统一配方），底色随分组色相。
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(isRunning ? Color.cyan : Color.white.opacity(0.55))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(red: swatch.0, green: swatch.1, blue: swatch.2).opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(account.nickname)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(session.groupName(forAccountID: account.id))
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: swatch.0, green: swatch.1, blue: swatch.2).opacity(0.85))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if isRunning {
                LobbyStatusCapsule(text: isFocused ? "焦点" : "运行中",
                                   tint: isFocused ? .yellow : .cyan,
                                   isSelected: isFocused)
            }

            Button {
                if isRunning {
                    session.close(account)
                } else {
                    session.launch(account)
                }
            } label: {
                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isRunning ? Color(red: 1.0, green: 0.45, blue: 0.42) : Color.green)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 13, intensity: 0.12)
            .help(isRunning ? "关闭实例" : "启动并登录")

            Button {
                session.requestDelete(account)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 13, intensity: 0.12)
            .help("删除账号文件")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(isRunning ? 0.075 : 0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.06)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
        )
        .lobbyHoverHighlight(cornerRadius: 11, intensity: 0.05)
        .contextMenu {
            if isRunning {
                Button("重新登录") { session.reload(account) }
                Button("关闭实例") { session.close(account) }
            } else {
                Button("启动并登录") { session.launch(account) }
            }
            Divider()
            moveActions
            Divider()
            Button("删除账号文件", role: .destructive) { session.requestDelete(account) }
        }
    }

    @ViewBuilder
    private var moveActions: some View {
        Menu("移动到分组") {
            Button(session.groupName(forGroupID: AccountGroup.ungroupedID)) {
                session.assign(accountID: account.id, toGroupID: AccountGroup.ungroupedID)
            }
            ForEach(session.groupDefinitions) { group in
                Button(group.groupName) {
                    session.assign(accountID: account.id, toGroupID: group.id)
                }
            }
        }
    }
}
