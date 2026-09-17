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
    /// 正在编辑备注的账号（nil = 无弹窗）。
    @State private var remarkDraft: GameAccount?

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
        .sheet(item: $remarkDraft) { account in
            RemarkEditorSheet(session: session, account: account) {
                remarkDraft = nil
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
            // 刷新资料：不启动游戏，直接从服务端把「当前筛选范围」内账号的资料拉回来。
            // 运行中的账号会被自动跳过（见 LobbySessionModel.refreshProfiles 的注释）。
            Button {
                session.refreshProfiles(filteredAccounts, reason: "侧栏")
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 11, intensity: 0.15)
            .disabled(session.profileRefreshInFlight.isEmpty == false)
            .help("刷新资料：直接从服务端取这些账号的头像 / 昵称 / 等级 / 战力（跳过运行中的）")

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
        Button("刷新本组资料（跳过运行中）") {
            session.refreshProfiles(session.accounts(inGroupID: group.id), reason: "分组")
        }
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
                                   groupContextID: selectedGroupID ?? AccountGroup.allID,
                                   onEditRemark: { remarkDraft = account })
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

/// 备注编辑弹窗：单行输入，保存写入备注表（空串清除）。
struct RemarkEditorSheet: View {
    @ObservedObject var session: LobbySessionModel
    let account: GameAccount
    @State private var text: String
    let onDismiss: () -> Void

    init(session: LobbySessionModel, account: GameAccount, onDismiss: @escaping () -> Void) {
        self.session = session
        self.account = account
        _text = State(initialValue: session.remark(forAccountID: account.id))
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("备注 · \(account.nickname)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            TextField("选填，方便区分账号用途", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            HStack {
                Spacer()
                Button("取消", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    session.updateRemark(text, forAccountID: account.id)
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.14)))
    }
}

/// 侧栏账号卡片（含头像、分组着色、「移动到分组」菜单与原生拖拽排序）。
struct AccountSidebarCard: View {
    @ObservedObject var session: LobbySessionModel
    /// 账号资料库（头像 / 游戏内昵称 / 等级战力）。单独观察，取到图就刷新。
    @ObservedObject private var avatars: AccountAvatarStore
    let account: GameAccount
    /// 拖拽排序的分组上下文（当前筛选视图的分组 ID，「全部」= allID）。
    let groupContextID: String
    /// 编辑备注回调（状态由外层 AccountSidebarView 持有）。
    let onEditRemark: () -> Void

    init(session: LobbySessionModel,
         account: GameAccount,
         groupContextID: String,
         onEditRemark: @escaping () -> Void) {
        _session = ObservedObject(wrappedValue: session)
        _avatars = ObservedObject(wrappedValue: session.avatars)
        self.account = account
        self.groupContextID = groupContextID
        self.onEditRemark = onEditRemark
    }

    private var isRunning: Bool { session.isRunning(account) }
    private var isFocused: Bool { session.focusedAccountID == account.id }
    private var swatch: (Double, Double, Double) {
        GroupSwatch.rgb(for: session.groupColorName(forAccountID: account.id))
    }
    private var remarkText: String {
        session.remark(forAccountID: account.id)
    }
    private var profile: AccountAvatarStore.Record? {
        avatars.profile(forAccountID: account.id)
    }

    var body: some View {
        // 行内间距 9（原 10）、按钮 24（原 26）：侧栏文字列只有 ~126pt，
        // 这里每抠出 1pt 都直接变成「等级 / 战力」的可读空间（见 statsView 的宽度账）。
        // 24pt 的圆形按钮与 26pt 肉眼几乎无差，换来的是一整档数值不至于退让。
        HStack(spacing: 9) {
            avatarBadge

            VStack(alignment: .leading, spacing: 3) {
                Text(account.nickname)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                // 第二行：用户自己写的备注优先（那是刻意记的），没有才退到游戏内昵称。
                if !remarkText.isEmpty {
                    Text(remarkText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.30).opacity(0.9))
                        .lineLimit(1)
                        .help(remarkText)
                } else if let name = profile?.name, !name.isEmpty {
                    Text(name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineLimit(1)
                        .help(name)
                }
                // 第三行：分组名（分组色）+ 游戏内等级 / 战力（右对齐，拿到资料才有）。
                //
                // ⚠️ 宽度是这里最稀缺的资源，实测账（可用 `Scripts/stats-width-probe.sh` 复算）：
                //  304 侧栏 − 32 侧栏内边距 − 20 卡片内边距 − 28 头像 − 4×9 行内间距
                //  − 24×2 按钮 − 6 本行 Spacer 下限 = **文字列 134pt**。
                // （原先「运行中」胶囊还会再吃掉 60pt、只剩 74pt —— 胶囊已经删掉，
                //   它的功能由青色头像环 + 红色停止按钮承担，见 avatarBadge 与上方注释。）
                // 而 `Lv9090 · 21.8亿` 实测 82pt（10pt monospacedDigit），所以常规情况
                // 一行放得下，只有**分组名很长**时才会挤压。三层应对：
                //  ① 不该占字的分组名不显示（未分组 = 本来就没有分组；已在按该分组
                //     筛选时 chip 上已经写着，卡片再写一遍是纯噪音）→ 省下 30–40pt；
                //  ② 数值缩写到 4–5 字符（`21.81亿` → `21.8亿`、`5253.4万` → `5253万`）；
                //  ③ `ViewThatFits` 四档退让（见 `statsView`）——**先换行、后丢项**，
                //     所以既不会出现被截断的半截数字，也不会真的少一个数。
                HStack(spacing: 4) {
                    if showsGroupLabel {
                        Text(session.groupName(forAccountID: account.id))
                            .font(.system(size: 10))
                            .foregroundStyle(Color(red: swatch.0, green: swatch.1, blue: swatch.2).opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    if let profile, profile.level > 0 || profile.power > 0 {
                        statsView(profile)
                            .help(Self.exactStatsHelp(level: profile.level, power: profile.power))
                    }
                }
            }

            Spacer(minLength: 6)

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
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 12, intensity: 0.12)
            .help(isRunning ? "关闭实例" : "启动并登录")

            Button {
                session.requestDelete(account)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 12, intensity: 0.12)
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
                    // 焦点态的弱信号：焦点卡片的描边偏暖黄（与矩阵卡的黄色光晕同一套语言）。
                    // 这里**刻意不做胶囊/文字**——「运行中」胶囊已经删掉了（运行态在本卡上
                    // 有三重冗余表达：青色头像环 + 红色停止按钮 + 更亮的卡底，胶囊只是噪音，
                    // 还白占 ~60pt 横向空间）。焦点是另一件事，用 1pt 描边带过即可。
                    LinearGradient(
                        colors: isFocused
                            ? [Color(red: 1.0, green: 0.78, blue: 0.30).opacity(0.42),
                               Color(red: 1.0, green: 0.78, blue: 0.30).opacity(0.14)]
                            : [Color.white.opacity(0.14), Color.white.opacity(0.06)],
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
            Button("编辑备注…") { onEditRemark() }
            // 不启动游戏，直接从服务端把这个账号的资料拉回来（头像 / 昵称 / 等级 / 战力）。
            // 运行中的账号会被跳过——那会顶掉正在跑的实例，且运行中本来就有页面上报。
            Button(isRunning ? "刷新资料（运行中，已跳过）" : "刷新资料") {
                session.refreshProfiles([account], reason: "账号卡")
            }
            .disabled(isRunning)
            moveActions
            Divider()
            Button("删除账号文件", role: .destructive) { session.requestDelete(account) }
        }
    }

    /// 28×28 圆形头像。拿到真实头像就显示，没拿到时回落原图标磁贴
    /// （冷启动 / 这个账号还没跑过 → 库里有账号但没资料，这是常态）。
    ///
    /// 描边承担两件事，所以它是这个卡片里信息密度最高的 1pt：
    /// · **运行态**：青色（头像上没法 tint，只能靠环色表达）；
    /// · **空闲态**：分组色。第三行已经不写分组名了（未分组没信息量、
    ///   按分组筛选时 chip 上写着），分组信息改由环色承担——颜色本来就是
    ///   分组色板存在的意义，比重复一遍文字更省宽度。
    private var avatarBadge: some View {
        let groupColor = Color(red: swatch.0, green: swatch.1, blue: swatch.2)
        let ringColor = isRunning ? Color.cyan : groupColor.opacity(0.6)
        return ZStack {
            Circle()
                .fill(groupColor.opacity(0.14))
            if session.isRefreshingProfile(account) {
                // 正在从服务端拉资料：转圈优先于头像（此时头像可能正要被替换）。
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            } else if let image = avatars.image(forAccountID: account.id) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(ringColor, lineWidth: 1))
        .help(session.isRefreshingProfile(account) ? "正在拉取资料…" : account.nickname)
    }

    /// 第三行要不要显示分组名。
    ///
    /// 两种情况不显示——它们都不是「有分组信息但被省略」，而是**本来就没有信息量**：
    /// · 未分组：没有分组 = 事实上的缺席，写「未分组」只是占字；
    /// · 当前正在按该分组筛选：分组 chip 已经高亮着，每张卡再重复一遍纯属噪音。
    /// 省下来的宽度全给「等级 / 战力」。
    private var showsGroupLabel: Bool {
        let accountGroupID = session.groupID(forAccountID: account.id)
        guard accountGroupID != AccountGroup.ungroupedID else { return false }
        return accountGroupID != groupContextID
    }

    /// 等级 / 战力的自适应退让（4 档有内容 + 1 档空白）。
    /// `ViewThatFits` 取**第一个放得下的**变体，一个都放不下时用最后一个（空）——
    /// 所以设计上不存在「显示成 `…`」这一档。
    ///
    /// 退让顺序刻意是「**先换行、后丢项**」：
    ///  ① `Lv9090 · 21.8亿`（带空格，最好读）
    ///  ② `Lv9090·21.8亿`（去空格，省 6pt）
    ///  ③ 竖排两行 `Lv9090` / `21.8亿`（卡片长高 ~12pt，但**一个数都不少**）
    ///  ④ 只留战力（多开/搬砖时最常横向比较的那个数）
    ///  ⑤ 什么都不画（宽度连一项都塞不进时）
    /// 实测宽度（10pt monospacedDigit）：① ~82pt ② ~76pt ③ ~37pt ④ ~34pt；
    /// 文字列可用宽度 **134pt**（运行态与空闲态相同——「运行中」胶囊已删）。
    /// 所以常规账号永远走①；只有**分组名很长**时才会退到②，退到③的概率极低。
    /// 保留这套档位是因为分组名长度不可控（用户可以建任意长的分组名）。
    private func statsView(_ profile: AccountAvatarStore.Record) -> some View {
        ViewThatFits(in: .horizontal) {
            statsRow(profile, spacing: 4)
            statsRow(profile, spacing: 2)
            statsStacked(profile)
            // 只剩一个位置时留**战力**：多开/搬砖场景下它是用来横向比较账号的那个数。
            powerOnly(profile)
            EmptyView()
        }
    }

    private func statsRow(_ profile: AccountAvatarStore.Record, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            if profile.level > 0 {
                Text("Lv\(profile.level)")
                    .foregroundStyle(Color.white.opacity(0.42))
            }
            if profile.level > 0, profile.power > 0 {
                Text("·").foregroundStyle(Color.white.opacity(0.32))
            }
            if profile.power > 0 {
                Text(Self.abridgedPower(profile.power))
                    .foregroundStyle(Self.powerTint)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
    }

    /// 竖排退让档：宽 37pt 就能放下，代价只是卡片高 12pt。
    private func statsStacked(_ profile: AccountAvatarStore.Record) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            if profile.level > 0 {
                Text("Lv\(profile.level)")
                    .foregroundStyle(Color.white.opacity(0.42))
            }
            if profile.power > 0 {
                Text(Self.abridgedPower(profile.power))
                    .foregroundStyle(Self.powerTint)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
    }

    private func powerOnly(_ profile: AccountAvatarStore.Record) -> some View {
        Text(profile.power > 0 ? Self.abridgedPower(profile.power) : "Lv\(profile.level)")
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(profile.power > 0 ? Self.powerTint : Color.white.opacity(0.42))
            .lineLimit(1)
    }

    /// 战力的专用色：冷青，与运行态的 cyan 呼应但更弱，让数字在灰白文字里跳出来。
    private static let powerTint = Color(red: 0.55, green: 0.86, blue: 1.0).opacity(0.92)

    /// 缩写只为了「放得下」，精确值放在 tooltip 与这个函数里。
    private static func abridgedPower(_ value: Int) -> String {
        let amount = Double(value)
        if value >= 100_000_000 {
            let yi = amount / 100_000_000
            // ≥100 亿 时小数位没有意义，砍掉换宽度（123.4亿 → 123亿）。
            return yi >= 100 ? String(format: "%.0f亿", yi) : String(format: "%.1f亿", yi)
        }
        if value >= 10_000 {
            // 万档一律取整：`5253.4万` 比 `5253万` 多一个字符却不提供任何决策信息。
            return String(format: "%.0f万", amount / 10_000)
        }
        return String(value)
    }

    private static func exactStatsHelp(level: Int, power: Int) -> String {
        var parts: [String] = []
        if level > 0 { parts.append("等级 \(level)") }
        if power > 0 {
            parts.append("战力 \(power.formatted(.number.grouping(.automatic)))")
        }
        return parts.joined(separator: " · ")
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
