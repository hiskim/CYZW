import SwiftUI
import UniformTypeIdentifiers

struct AccountLibraryView: View {
    @StateObject private var viewModel = AccountLibraryViewModel()
    @State private var isPresentingImporter = false

    let onLaunch: (Account) -> Void

    private var groupedAccounts: [(name: String, accounts: [Account])] {
        let groups = Dictionary(grouping: viewModel.accounts, by: \.groupName)
        return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { name in
                guard let accounts = groups[name] else { return nil }
                return (name: name, accounts: accounts)
            }
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

                        ForEach(groupedAccounts, id: \.name) { group in
                            AccountGroupSection(
                                name: group.name,
                                accounts: group.accounts,
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
}

private struct AccountGroupSection: View {
    let name: String
    let accounts: [Account]
    @ObservedObject var viewModel: AccountLibraryViewModel
    let selectedIDs: Set<String>
    let remarkForAccount: (Account) -> String
    let onToggleSelection: (String) -> Void
    let onLaunch: (Account) -> Void

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

            VStack(spacing: 1) {
                ForEach(accounts) { account in
                    NavigationLink {
                        AccountDetailView(account: account, viewModel: viewModel, onLaunch: onLaunch)
                    } label: {
                        AccountRow(
                            account: account,
                            remark: remarkForAccount(account),
                            isSelected: selectedIDs.contains(account.id),
                            onToggle: { onToggleSelection(account.id) }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(tokens.color(.card))
            .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.card)))
            .overlay {
                RoundedRectangle(cornerRadius: tokens.radius(.card))
                    .stroke(tokens.color(.border))
            }
        }
    }
}

private struct AccountRow: View {
    let account: Account
    let remark: String
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        let tokens = DesignTokens.shared

        HStack(spacing: tokens.spacing(.md)) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(tokens.font(.xl))
                    .foregroundStyle(isSelected ? tokens.color(.accent) : tokens.color(.textMuted))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "取消选择 \(account.nickname)" : "选择 \(account.nickname)")

            VStack(alignment: .leading, spacing: 5) {
                Text(account.nickname)
                    .font(tokens.font(.xl, weight: .semibold))
                    .foregroundStyle(tokens.color(.textPrimary))
                    .lineLimit(1)
                HStack(spacing: tokens.spacing(.sm)) {
                    Text(account.fileName)
                        .lineLimit(1)
                    if !remark.isEmpty {
                        Text("·")
                        Text(remark)
                            .lineLimit(1)
                    }
                }
                .font(tokens.font(.sm))
                .foregroundStyle(tokens.color(.textSecondary))
            }

            Spacer(minLength: tokens.spacing(.sm))

            Image(systemName: "chevron.right")
                .font(tokens.font(.sm, weight: .semibold))
                .foregroundStyle(tokens.color(.textMuted))
        }
        .padding(.horizontal, tokens.spacing(.lg))
        .padding(.vertical, tokens.spacing(.md))
        .contentShape(Rectangle())
    }
}

struct AccountDetailView: View {
    let account: Account
    @ObservedObject var viewModel: AccountLibraryViewModel
    let onLaunch: (Account) -> Void

    @Environment(\.presentationMode) private var presentationMode
    @State private var draftRemark = ""
    @State private var isEditingRemark = false
    @State private var isPresentingDeleteConfirmation = false

    var body: some View {
        let tokens = DesignTokens.shared

        ScrollView {
            VStack(alignment: .leading, spacing: tokens.spacing(.lg)) {
                identityHeader(tokens: tokens)
                metadataSection(tokens: tokens)
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
            detailRow(label: "分组", value: account.groupName, icon: "folder.fill", tokens: tokens)
        }
        .background(tokens.color(.card))
        .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.card)))
        .overlay {
            RoundedRectangle(cornerRadius: tokens.radius(.card))
                .stroke(tokens.color(.border))
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
