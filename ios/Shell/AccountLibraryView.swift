import SwiftUI
import UniformTypeIdentifiers

struct AccountLibraryView: View {
    @StateObject private var viewModel = AccountLibraryViewModel()
    @State private var isPresentingImporter = false
    @State private var selectedGroupID = AccountGroup.allID

    let onLaunch: (Account) -> Void

    private var currentGroup: AccountGroup {
        if selectedGroupID == AccountGroup.allID { return .all }
        return viewModel.visibleGroups.first(where: { $0.id == selectedGroupID }) ?? .all
    }

    private var visibleAccounts: [Account] {
        viewModel.accounts(in: currentGroup)
    }

    var body: some View {
        let tokens = DesignTokens.shared

        VStack(alignment: .leading, spacing: 0) {
            header(tokens: tokens)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(tokens.font(.sm))
                    .foregroundStyle(tokens.color(.danger))
                    .padding(.top, tokens.spacing(.md))
            }

            if viewModel.accounts.isEmpty {
                emptyState(tokens: tokens)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: tokens.spacing(.xl)) {
                        if viewModel.selectedAccounts.count > 1 {
                            Text("原生 Cocos 仅支持单实例，请选择一个账号启动。")
                                .font(tokens.font(.sm))
                                .foregroundStyle(tokens.color(.textSecondary))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if visibleAccounts.isEmpty {
                            groupEmptyState(tokens: tokens)
                        } else {
                            AccountGroupSection(
                                name: currentGroup.name,
                                accounts: visibleAccounts,
                                viewModel: viewModel,
                                selectedIDs: viewModel.selectedIDs,
                                remarkForAccount: { viewModel.remark(for: $0) },
                                onToggleSelection: { viewModel.toggleSelection(id: $0) },
                                onLaunch: onLaunch
                            )
                        }
                    }
                    .padding(.top, tokens.spacing(.lg))
                    .padding(.bottom, tokens.spacing(.xl))
                }
            }
        }
        .padding(.horizontal, tokens.spacing(.xl))
        .background(tokens.color(.canvas).ignoresSafeArea())
        .task {
            viewModel.refresh()
        }
        .onChange(of: viewModel.visibleGroups) { groups in
            let visibleIDs = Set(groups.map(\.id)).union([AccountGroup.allID])
            if !visibleIDs.contains(selectedGroupID) {
                selectedGroupID = AccountGroup.allID
            }
        }
        .fileImporter(
            isPresented: $isPresentingImporter,
            allowedContentTypes: [UTType(filenameExtension: "bin") ?? .data],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                viewModel.importFiles(from: urls)
            }
        }
    }

    @ViewBuilder
    private func header(tokens: DesignTokens) -> some View {
        HStack(alignment: .top, spacing: tokens.spacing(.md)) {
            VStack(alignment: .leading, spacing: tokens.spacing(.sm)) {
                HStack(spacing: tokens.spacing(.sm)) {
                    Text("账号库")
                        .font(tokens.font(.xxl, weight: .semibold))
                        .foregroundStyle(tokens.color(.textPrimary))
                    Text("S18")
                        .font(tokens.font(.xs, weight: .semibold))
                        .foregroundStyle(tokens.color(.accent))
                        .padding(.horizontal, tokens.spacing(.sm))
                        .padding(.vertical, 4)
                        .background(tokens.color(.accent).opacity(0.14))
                        .clipShape(Capsule())
                }
                Text("按分组管理本地账号")
                    .font(tokens.font(.md))
                    .foregroundStyle(tokens.color(.textSecondary))
            }

            Spacer()

            Button {
                isPresentingImporter = true
            } label: {
                Image(systemName: "plus")
                    .font(tokens.font(.lg, weight: .semibold))
            }
            .buttonStyle(TokenIconButtonStyle())
            .accessibilityLabel("导入 .bin 账号")
        }
        .padding(.top, tokens.spacing(.xl))

        HStack(spacing: tokens.spacing(.md)) {
            Label("\(viewModel.accounts.count) 个账号", systemImage: "person.2")
            Text("已选 \(viewModel.selectedIDs.count)")
                .foregroundStyle(tokens.color(.textSecondary))
            Spacer()
            Button(viewModel.allSelected ? "取消全选" : "全选") {
                viewModel.toggleSelectAll()
            }
            .font(tokens.font(.sm, weight: .medium))
            .foregroundStyle(tokens.color(.accent))
            .buttonStyle(.plain)
        }
        .font(tokens.font(.sm, weight: .medium))
        .foregroundStyle(tokens.color(.textPrimary))
        .padding(.top, tokens.spacing(.xl))
        .padding(.bottom, tokens.spacing(.md))

        Divider()
            .overlay(tokens.color(.border))

        groupTabs(tokens: tokens)

        if viewModel.selectedAccounts.count == 1, let account = viewModel.selectedAccounts.first {
            Button {
                onLaunch(account)
            } label: {
                Label("启动已选", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TokenPrimaryButtonStyle())
            .padding(.top, tokens.spacing(.md))
        }
    }

    @ViewBuilder
    private func groupTabs(tokens: DesignTokens) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: tokens.spacing(.sm)) {
                ForEach([viewModel.allGroup] + viewModel.visibleGroups) { group in
                    let isSelected = currentGroup.id == group.id
                    let groupColor = group.swatchColor
                    Button {
                        selectedGroupID = group.id
                    } label: {
                        HStack(spacing: 6) {
                            Text(group.name)
                            Text("\(viewModel.accounts(in: group).count)")
                                .foregroundStyle(
                                    isSelected
                                        ? Color.white.opacity(0.82)
                                        : groupColor
                                )
                        }
                        .font(tokens.font(.sm, weight: .medium))
                        .foregroundStyle(
                            isSelected ? Color.white : groupColor
                        )
                        .padding(.horizontal, tokens.spacing(.md))
                        .padding(.vertical, tokens.spacing(.sm))
                        .background(
                            isSelected ? groupColor : Color.clear
                        )
                        .clipShape(Capsule())
                        .overlay {
                            if !isSelected {
                                Capsule().stroke(groupColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                NavigationLink {
                    GroupManagementView(viewModel: viewModel)
                } label: {
                    Label("管理", systemImage: "plus")
                        .font(tokens.font(.sm, weight: .medium))
                        .foregroundStyle(tokens.color(.accent))
                        .padding(.horizontal, tokens.spacing(.md))
                        .padding(.vertical, tokens.spacing(.sm))
                        .overlay {
                            Capsule().stroke(tokens.color(.border), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, tokens.spacing(.sm))
        }
    }

    @ViewBuilder
    private func emptyState(tokens: DesignTokens) -> some View {
        VStack(spacing: tokens.spacing(.md)) {
            Image(systemName: "person.crop.rectangle.stack")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(tokens.color(.textMuted))
            Text("暂无账号")
                .font(tokens.font(.xl, weight: .semibold))
                .foregroundStyle(tokens.color(.textPrimary))
            Text("导入 .bin 文件后，账号会按分组显示在这里。")
                .font(tokens.font(.md))
                .foregroundStyle(tokens.color(.textSecondary))
                .multilineTextAlignment(.center)
            Button {
                isPresentingImporter = true
            } label: {
                Label("导入账号", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(TokenPrimaryButtonStyle())
            .padding(.top, tokens.spacing(.sm))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func groupEmptyState(tokens: DesignTokens) -> some View {
        VStack(spacing: tokens.spacing(.md)) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(tokens.color(.textMuted))
            Text("该分组暂无账号")
                .font(tokens.font(.xl, weight: .semibold))
                .foregroundStyle(tokens.color(.textPrimary))
            Text("进入账号详情即可调整分组。")
                .font(tokens.font(.md))
                .foregroundStyle(tokens.color(.textSecondary))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, tokens.spacing(.xl))
    }
}

private struct GroupManagementView: View {
    @ObservedObject var viewModel: AccountLibraryViewModel
    @State private var isCreatingGroup = false
    @State private var editingGroup: AccountGroup?
    @State private var deletingGroup: AccountGroup?

    var body: some View {
        let tokens = DesignTokens.shared

        List {
            Section("固定分组") {
                GroupManagementRow(
                    group: viewModel.allGroup,
                    memberCount: viewModel.accounts.count,
                    isLocked: true,
                    isDefault: false,
                    onEdit: {},
                    onToggleHidden: {},
                    onDelete: {}
                )
            }

            Section("我的分组") {
                if viewModel.visibleGroups.isEmpty {
                    Text("还没有自定义分组")
                        .font(tokens.font(.md))
                        .foregroundStyle(tokens.color(.textSecondary))
                } else {
                    ForEach(viewModel.visibleGroups) { group in
                        groupRow(group)
                    }
                    .onMove(perform: viewModel.moveGroups)
                }
            }

            Section("已隐藏") {
                if viewModel.hiddenGroups.isEmpty {
                    Text("没有隐藏的分组")
                        .font(tokens.font(.md))
                        .foregroundStyle(tokens.color(.textSecondary))
                } else {
                    ForEach(viewModel.hiddenGroups) { group in
                        groupRow(group)
                    }
                }
            }

            Section {
                Button {
                    isCreatingGroup = true
                } label: {
                    Label("新建分组", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TokenSecondaryButtonStyle())
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .background(tokens.color(.canvas).ignoresSafeArea())
        .navigationTitle("分组管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
        }
        .sheet(isPresented: $isCreatingGroup) {
            GroupEditorSheet(viewModel: viewModel, group: nil)
        }
        .sheet(item: $editingGroup) { group in
            GroupEditorSheet(viewModel: viewModel, group: group)
        }
        .sheet(item: $deletingGroup) { group in
            GroupDeletionSheet(viewModel: viewModel, group: group)
        }
    }

    @ViewBuilder
    private func groupRow(_ group: AccountGroup) -> some View {
        GroupManagementRow(
            group: group,
            memberCount: viewModel.accounts(in: group).count,
            isLocked: false,
            isDefault: viewModel.defaultGroupID == group.id,
            onEdit: { editingGroup = group },
            onToggleHidden: { viewModel.setHidden(!group.isHidden, for: group) },
            onDelete: { deletingGroup = group }
        )
    }
}

private struct GroupManagementRow: View {
    let group: AccountGroup
    let memberCount: Int
    let isLocked: Bool
    let isDefault: Bool
    let onEdit: () -> Void
    let onToggleHidden: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let tokens = DesignTokens.shared

        HStack(spacing: tokens.spacing(.md)) {
            Image(systemName: isLocked ? "lock.fill" : "line.3.horizontal")
                .font(tokens.font(.sm, weight: .semibold))
                .foregroundStyle(isLocked ? tokens.color(.textMuted) : tokens.color(.textSecondary))
                .frame(width: 18)

            Circle()
                .fill(group.swatchColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: tokens.spacing(.sm)) {
                    Text(group.name)
                        .font(tokens.font(.lg, weight: .semibold))
                        .foregroundStyle(tokens.color(.textPrimary))
                    if isLocked || isDefault {
                        Text(isLocked ? "内置" : "默认")
                            .font(tokens.font(.xs, weight: .medium))
                            .foregroundStyle(tokens.color(.textSecondary))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tokens.color(.cardRaised))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text("\(memberCount) 个账号")
                    .font(tokens.font(.sm))
                    .foregroundStyle(tokens.color(.textSecondary))
            }

            Spacer()

            if !isLocked {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("编辑分组")

                Button(action: onToggleHidden) {
                    Image(systemName: group.isHidden ? "eye" : "eye.slash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(group.isHidden ? "显示分组" : "隐藏分组")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("删除分组")
            }
        }
        .font(tokens.font(.md, weight: .medium))
        .foregroundStyle(tokens.color(.textSecondary))
    }
}

private struct GroupEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: AccountLibraryViewModel
    let group: AccountGroup?

    @State private var name: String
    @State private var colorName: String
    @State private var selectedAccountIDs: Set<String>
    @State private var isDefault: Bool
    @State private var searchText = ""

    init(viewModel: AccountLibraryViewModel, group: AccountGroup?) {
        self.viewModel = viewModel
        self.group = group
        _name = State(initialValue: group?.name ?? "")
        _colorName = State(initialValue: group?.colorName ?? "blue")
        _selectedAccountIDs = State(initialValue: Set(group.map { viewModel.accounts(in: $0).map(\.id) } ?? []))
        _isDefault = State(initialValue: group.map { viewModel.defaultGroupID == $0.id } ?? false)
    }

    private var filteredAccounts: [Account] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.accounts }
        return viewModel.accounts.filter {
            $0.nickname.localizedCaseInsensitiveContains(query) || $0.fileName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let tokens = DesignTokens.shared

        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: tokens.spacing(.xl)) {
                    Text("颜色")
                        .font(tokens.font(.sm, weight: .semibold))
                        .foregroundStyle(tokens.color(.textSecondary))
                    HStack(spacing: tokens.spacing(.sm)) {
                        ForEach(AccountGroup.swatchNames, id: \.self) { color in
                            Button {
                                colorName = color
                            } label: {
                                Circle()
                                    .fill(AccountGroup.swatchColor(named: color))
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if colorName == color {
                                            Circle().stroke(tokens.color(.textPrimary), lineWidth: 2)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("选择\(color)色")
                        }
                    }

                    VStack(alignment: .leading, spacing: tokens.spacing(.sm)) {
                        Text("分组名称")
                            .font(tokens.font(.sm, weight: .semibold))
                            .foregroundStyle(tokens.color(.textSecondary))
                        TextField("例如：日常账号", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: tokens.spacing(.sm)) {
                        Text("账号")
                            .font(tokens.font(.sm, weight: .semibold))
                            .foregroundStyle(tokens.color(.textSecondary))
                        TextField("搜索账号", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                        ForEach(filteredAccounts) { account in
                            Button {
                                if selectedAccountIDs.contains(account.id) { selectedAccountIDs.remove(account.id) }
                                else { selectedAccountIDs.insert(account.id) }
                            } label: {
                                HStack(spacing: tokens.spacing(.md)) {
                                    Image(systemName: selectedAccountIDs.contains(account.id) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(selectedAccountIDs.contains(account.id) ? tokens.color(.accent) : tokens.color(.textMuted))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(account.nickname)
                                        Text(account.fileName)
                                            .font(tokens.font(.sm))
                                            .foregroundStyle(tokens.color(.textSecondary))
                                    }
                                    Spacer()
                                }
                                .foregroundStyle(tokens.color(.textPrimary))
                                .padding(tokens.spacing(.md))
                                .background(tokens.color(.card))
                                .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.control)))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Toggle("设为默认分组", isOn: $isDefault)
                        .font(tokens.font(.md, weight: .medium))
                        .tint(tokens.color(.accent))

                    Button(group == nil ? "创建分组" : "保存修改") {
                        if let group {
                            viewModel.updateGroup(group, name: name, colorName: colorName, accountIDs: selectedAccountIDs, isDefault: isDefault)
                        } else {
                            viewModel.addGroup(named: name, colorName: colorName, accountIDs: selectedAccountIDs, isDefault: isDefault)
                        }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(TokenPrimaryButtonStyle())
                }
                .padding(tokens.spacing(.xl))
            }
            .background(tokens.color(.canvas).ignoresSafeArea())
            .navigationTitle(group == nil ? "新建分组" : "编辑分组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

private struct GroupDeletionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: AccountLibraryViewModel
    let group: AccountGroup
    @State private var deletesAccounts = false

    var body: some View {
        let tokens = DesignTokens.shared
        let memberCount = viewModel.accounts(in: group).count

        VStack(alignment: .leading, spacing: tokens.spacing(.lg)) {
            Capsule()
                .fill(tokens.color(.border))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
            Label("删除 \(group.name)", systemImage: "trash")
                .font(tokens.font(.xl, weight: .semibold))
                .foregroundStyle(tokens.color(.danger))
            Text("请选择如何处理分组内的 \(memberCount) 个账号。")
                .font(tokens.font(.md))
                .foregroundStyle(tokens.color(.textSecondary))

            deletionOption(
                title: "仅删除分组，账号保留",
                detail: "推荐。账号回到“全部”，登录记录不受影响。",
                isSelected: !deletesAccounts,
                isDanger: false
            ) { deletesAccounts = false }

            deletionOption(
                title: "同时删除这 \(memberCount) 个账号",
                detail: "账号与登录凭证一并清除，不可恢复。",
                isSelected: deletesAccounts,
                isDanger: true
            ) { deletesAccounts = true }

            HStack(spacing: tokens.spacing(.md)) {
                Button("取消") { dismiss() }
                    .buttonStyle(TokenSecondaryButtonStyle())
                Button("删除", role: .destructive) {
                    viewModel.deleteGroup(group, deletingMembers: deletesAccounts)
                    dismiss()
                }
                .font(tokens.font(.lg, weight: .semibold))
                .foregroundStyle(tokens.color(.textPrimary))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, tokens.spacing(.lg))
                .padding(.vertical, tokens.spacing(.md))
                .background(tokens.color(.danger))
                .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.control)))
            }
        }
        .padding(tokens.spacing(.xl))
        .background(tokens.color(.panel))
    }

    @ViewBuilder
    private func deletionOption(title: String, detail: String, isSelected: Bool, isDanger: Bool, action: @escaping () -> Void) -> some View {
        let tokens = DesignTokens.shared
        Button(action: action) {
            HStack(alignment: .top, spacing: tokens.spacing(.md)) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? tokens.color(.accent) : tokens.color(.textMuted))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(tokens.font(.md, weight: .semibold))
                        .foregroundStyle(isDanger ? tokens.color(.danger) : tokens.color(.textPrimary))
                    Text(detail)
                        .font(tokens.font(.sm))
                        .foregroundStyle(tokens.color(.textSecondary))
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(tokens.spacing(.lg))
            .background(tokens.color(.card))
            .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.control)))
            .overlay {
                RoundedRectangle(cornerRadius: tokens.radius(.control))
                    .stroke(isSelected ? tokens.color(.accent) : tokens.color(.border))
            }
        }
        .buttonStyle(.plain)
    }
}

private extension AccountGroup {
    static let swatchNames = ["blue", "green", "orange", "red", "purple", "teal", "yellow", "gray"]

    var swatchColor: Color { Self.swatchColor(named: colorName) }

    static func swatchColor(named name: String) -> Color {
        switch name {
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

private struct AccountGroupSection: View {
    let name: String
    let accounts: [Account]
    @ObservedObject var viewModel: AccountLibraryViewModel
    let selectedIDs: Set<String>
    let remarkForAccount: (Account) -> String
    let onToggleSelection: (String) -> Void
    let onLaunch: (Account) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = DesignTokens.shared

        VStack(alignment: .leading, spacing: tokens.spacing(.md)) {
            HStack(alignment: .firstTextBaseline) {
                Label(name, systemImage: "folder.fill")
                    .font(tokens.font(.lg, weight: .semibold))
                    .foregroundStyle(tokens.color(.textPrimary))
                Spacer()
                Text("\(accounts.count) 人")
                    .font(tokens.font(.sm))
                    .foregroundStyle(tokens.color(.textSecondary))
            }

            VStack(spacing: 8) {
                ForEach(accounts) { account in
                    AccountRow(
                        account: account,
                        remark: remarkForAccount(account),
                        isSelected: selectedIDs.contains(account.id),
                        isOnline: account.importedAt != .distantPast,
                        onToggle: { onToggleSelection(account.id) },
                        onLaunch: { onLaunch(account) }
                    ) {
                        AccountDetailView(account: account, viewModel: viewModel, onLaunch: onLaunch)
                    }

                    .background(tokens.color(.card))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(colorScheme == .light ? Color.gray.opacity(0.28) : tokens.color(.border), lineWidth: 1)
                    }
                    .opacity(account.importedAt != .distantPast ? 1 : 0.62)
                }
            }
        }
    }
}

private struct AccountRow<Destination: View>: View {
    let account: Account
    let remark: String
    let isSelected: Bool
    let isOnline: Bool
    let onToggle: () -> Void
    let onLaunch: () -> Void
    @ViewBuilder let destination: Destination

    var body: some View {
        let tokens = DesignTokens.shared

        HStack(spacing: 11) {
            Button(action: onToggle) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(isSelected ? tokens.color(.accent).opacity(0.22) : tokens.color(.panel))
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(isSelected ? tokens.color(.accent) : tokens.color(.textSecondary))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(isSelected ? tokens.color(.accent) : Color.clear, lineWidth: 1.5)
                        }

                    Image(systemName: isOnline ? "checkmark.circle.fill" : "circle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isOnline ? tokens.color(.success) : tokens.color(.textMuted), tokens.color(.card))
                        .offset(x: 3, y: 3)
                }
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "取消选择 \(account.nickname)" : "选择 \(account.nickname)")

            NavigationLink {
                destination
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.nickname)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tokens.color(.textPrimary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(remark.isEmpty ? account.fileName : remark)
                        .font(.system(size: 12))
                        .foregroundStyle(tokens.color(.textSecondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button(action: onLaunch) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(tokens.color(.textPrimary))
                    .background(tokens.color(.primaryButton))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("启动 \(account.nickname)")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
    }
}

struct AccountDetailView: View {
    let account: Account
    @ObservedObject var viewModel: AccountLibraryViewModel
    let onLaunch: (Account) -> Void

    @Environment(\.presentationMode) private var presentationMode
    @State private var draftRemark = ""
    @State private var draftGroup = Account.defaultGroupName
    @State private var currentGroupName = Account.defaultGroupName
    @State private var isEditingRemark = false
    @State private var isEditingGroup = false
    @State private var isPresentingDeleteConfirmation = false

    var body: some View {
        let tokens = DesignTokens.shared

        ScrollView {
            VStack(alignment: .leading, spacing: tokens.spacing(.lg)) {
                identityHeader(tokens: tokens)
                metadataSection(tokens: tokens)
                groupSection(tokens: tokens)
                remarkSection(tokens: tokens)
                actionsSection(tokens: tokens)
            }
            .padding(tokens.spacing(.xl))
        }
        .background(tokens.color(.canvas).ignoresSafeArea())
        .navigationTitle("账号详情")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            draftRemark = viewModel.remark(for: account)
            draftGroup = account.groupName
            currentGroupName = account.groupName
        }
        .alert(isPresented: $isPresentingDeleteConfirmation) {
            Alert(
                title: Text("删除账号？"),
                message: Text("删除后将移除本地 .bin 文件，且无法恢复。"),
                primaryButton: .destructive(Text("删除")) {
                    viewModel.delete(id: account.id)
                    presentationMode.wrappedValue.dismiss()
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    @ViewBuilder
    private func identityHeader(tokens: DesignTokens) -> some View {
        HStack(spacing: tokens.spacing(.md)) {
            ZStack {
                RoundedRectangle(cornerRadius: tokens.radius(.control))
                    .fill(tokens.color(.accent).opacity(0.16))
                Image(systemName: "person.fill")
                    .font(tokens.font(.xl, weight: .semibold))
                    .foregroundStyle(tokens.color(.accent))
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: tokens.spacing(.sm)) {
                Text(account.nickname)
                    .font(tokens.font(.xxl, weight: .semibold))
                    .foregroundStyle(tokens.color(.textPrimary))
                Text("账号昵称")
                    .font(tokens.font(.sm))
                    .foregroundStyle(tokens.color(.textSecondary))
            }
            Spacer()
        }
        .padding(.bottom, tokens.spacing(.sm))
    }

    @ViewBuilder
    private func metadataSection(tokens: DesignTokens) -> some View {
        VStack(spacing: 0) {
            detailRow(label: "账号昵称", value: account.nickname, icon: "person", tokens: tokens)
            detailRow(label: ".bin 文件名", value: account.fileName, icon: "doc.fill", tokens: tokens)
            detailRow(label: "导入时间", value: formattedDate(account.importedAt), icon: "clock", tokens: tokens)
            detailRow(label: "分组", value: currentGroupName, icon: "folder.fill", tokens: tokens)
        }
        .background(tokens.color(.card))
        .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.card)))
        .overlay {
            RoundedRectangle(cornerRadius: tokens.radius(.card))
                .stroke(tokens.color(.border))
        }
    }

    @ViewBuilder
    private func groupSection(tokens: DesignTokens) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing(.md)) {
            HStack {
                Text("所属分组")
                    .font(tokens.font(.lg, weight: .semibold))
                    .foregroundStyle(tokens.color(.textPrimary))
                Spacer()
                Button {
                    if isEditingGroup {
                        viewModel.updateGroup(draftGroup, for: account)
                        currentGroupName = draftGroup.isEmpty ? Account.defaultGroupName : draftGroup
                    }
                    isEditingGroup.toggle()
                } label: {
                    Image(systemName: isEditingGroup ? "checkmark" : "pencil")
                        .font(tokens.font(.md, weight: .semibold))
                }
                .foregroundStyle(tokens.color(.accent))
                .buttonStyle(.plain)
                .accessibilityLabel(isEditingGroup ? "保存分组" : "编辑分组")
            }

            if isEditingGroup {
                Picker("分组", selection: $draftGroup) {
                    ForEach(viewModel.groupNames, id: \.self) { groupName in
                        Text(groupName).tag(groupName)
                    }
                }
                .pickerStyle(.menu)
                .font(tokens.font(.md, weight: .medium))
                .foregroundStyle(tokens.color(.textPrimary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, tokens.spacing(.lg))
                .padding(.vertical, tokens.spacing(.sm))
                .background(tokens.color(.card))
                .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.control)))
            } else {
                Label(currentGroupName, systemImage: "folder.fill")
                    .font(tokens.font(.md, weight: .medium))
                    .foregroundStyle(tokens.color(.textPrimary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(tokens.spacing(.lg))
                    .background(tokens.color(.card))
                    .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.control)))
            }
        }
    }

    @ViewBuilder
    private func detailRow(label: String, value: String, icon: String, tokens: DesignTokens) -> some View {
        HStack(spacing: tokens.spacing(.md)) {
            Image(systemName: icon)
                .font(tokens.font(.md))
                .foregroundStyle(tokens.color(.accent))
                .frame(width: 20)
            Text(label)
                .font(tokens.font(.md))
                .foregroundStyle(tokens.color(.textSecondary))
            Spacer(minLength: tokens.spacing(.md))
            Text(value)
                .font(tokens.font(.md, weight: .medium))
                .foregroundStyle(tokens.color(.textPrimary))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.horizontal, tokens.spacing(.lg))
        .padding(.vertical, tokens.spacing(.md))
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(tokens.color(.border))
                .padding(.leading, 52)
        }
    }

    @ViewBuilder
    private func remarkSection(tokens: DesignTokens) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing(.md)) {
            HStack {
                Text("备注")
                    .font(tokens.font(.lg, weight: .semibold))
                    .foregroundStyle(tokens.color(.textPrimary))
                Spacer()
                Button {
                    if isEditingRemark {
                        viewModel.updateRemark(draftRemark, for: account)
                    }
                    isEditingRemark.toggle()
                } label: {
                    Image(systemName: isEditingRemark ? "checkmark" : "pencil")
                        .font(tokens.font(.md, weight: .semibold))
                }
                .foregroundStyle(tokens.color(.accent))
                .buttonStyle(.plain)
                .accessibilityLabel(isEditingRemark ? "保存备注" : "编辑备注")
            }

            if isEditingRemark {
                TextEditor(text: $draftRemark)
                    .font(tokens.font(.md))
                    .foregroundStyle(tokens.color(.textPrimary))
                    .frame(minHeight: 90)
                    .padding(tokens.spacing(.sm))
                    .background(tokens.color(.panel))
                    .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.control)))
            } else {
                Text(draftRemark.isEmpty ? "暂无备注" : draftRemark)
                    .font(tokens.font(.md))
                    .foregroundStyle(draftRemark.isEmpty ? tokens.color(.textMuted) : tokens.color(.textPrimary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(tokens.spacing(.lg))
                    .background(tokens.color(.card))
                    .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.control)))
            }
        }
    }

    @ViewBuilder
    private func actionsSection(tokens: DesignTokens) -> some View {
        VStack(spacing: tokens.spacing(.md)) {
            Button {
                onLaunch(account)
            } label: {
                Label("启动该账号", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TokenPrimaryButtonStyle())

            Button {
                isPresentingDeleteConfirmation = true
            } label: {
                Label("删除账号", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .font(tokens.font(.lg, weight: .medium))
            .foregroundStyle(tokens.color(.danger))
            .padding(.vertical, tokens.spacing(.md))
            .background(tokens.color(.card))
            .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.control)))
            .overlay {
                RoundedRectangle(cornerRadius: tokens.radius(.control))
                    .stroke(tokens.color(.danger).opacity(0.55))
            }
        }
    }

    private func formattedDate(_ date: Date) -> String {
        guard date != .distantPast else { return "未知" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }
}
