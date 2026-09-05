import SwiftUI

struct AccountLibraryView: View {
    @State private var viewModel = AccountLibraryViewModel()
    @State private var isPresentingEditor = false
    @State private var editingAccount: Account?

    let onLaunch: ([Account]) -> Void

    var body: some View {
        let tokens = DesignTokens.shared
        @Bindable var model = viewModel

        VStack(spacing: tokens.spacing(.lg)) {
            HStack(spacing: tokens.spacing(.md)) {
                VStack(alignment: .leading, spacing: tokens.spacing(.sm)) {
                    Text("账号库")
                        .font(tokens.font(.xxl, weight: .semibold))
                        .foregroundStyle(tokens.color(.textPrimary))
                    Text("\(model.accounts.count) 个账号 · \(model.selectedIDs.count) 个已选")
                        .font(tokens.font(.md))
                        .foregroundStyle(tokens.color(.textSecondary))
                }
                Spacer()
                Button {
                    editingAccount = nil
                    isPresentingEditor = true
                } label: {
                    Image(systemName: "plus")
                        .font(tokens.font(.lg, weight: .semibold))
                }
                .buttonStyle(TokenIconButtonStyle())
                .accessibilityLabel("新增账号")
            }

            HStack(spacing: tokens.spacing(.md)) {
                Button(model.allSelected ? "取消全选" : "全选") {
                    model.toggleSelectAll()
                }
                .buttonStyle(TokenSecondaryButtonStyle())

                Spacer()

                Button("启动已选") {
                    onLaunch(model.selectedAccounts)
                }
                .buttonStyle(TokenPrimaryButtonStyle())
                .disabled(model.selectedAccounts.isEmpty)
            }

            List {
                ForEach(model.accounts) { account in
                    AccountRow(
                        account: account,
                        isSelected: model.selectedIDs.contains(account.id),
                        onToggle: { model.toggleSelection(id: account.id) },
                        onEdit: {
                            editingAccount = account
                            isPresentingEditor = true
                        }
                    )
                    .listRowBackground(tokens.color(.card))
                    .listRowSeparatorTint(tokens.color(.border))
                }
                .onDelete { offsets in
                    for index in offsets {
                        model.delete(id: model.accounts[index].id)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(tokens.color(.canvas))
        }
        .padding(tokens.spacing(.xl))
        .background(tokens.color(.canvas))
        .sheet(isPresented: $isPresentingEditor) {
            AccountEditorView(account: editingAccount) { account in
                if editingAccount == nil {
                    model.add(account)
                } else {
                    model.update(account)
                }
            }
            .presentationBackground(tokens.color(.panel))
        }
    }
}

private struct AccountRow: View {
    let account: Account
    let isSelected: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void

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

            VStack(alignment: .leading, spacing: tokens.spacing(.sm)) {
                Text(account.nickname)
                    .font(tokens.font(.xl, weight: .semibold))
                    .foregroundStyle(tokens.color(.textPrimary))
                Text("\(account.gameName) · \(account.groupName)")
                    .font(tokens.font(.md))
                    .foregroundStyle(tokens.color(.textSecondary))
            }

            Spacer()

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(tokens.font(.lg))
                    .foregroundStyle(tokens.color(.accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑 \(account.nickname)")
        }
        .padding(.vertical, tokens.spacing(.sm))
    }
}

private struct AccountEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var nickname: String
    @State private var gameName: String
    @State private var groupName: String

    let existingID: UUID?
    let onSave: (Account) -> Void

    init(account: Account?, onSave: @escaping (Account) -> Void) {
        _nickname = State(initialValue: account?.nickname ?? "")
        _gameName = State(initialValue: account?.gameName ?? "")
        _groupName = State(initialValue: account?.groupName ?? "")
        existingID = account?.id
        self.onSave = onSave
    }

    var body: some View {
        let tokens = DesignTokens.shared

        VStack(alignment: .leading, spacing: tokens.spacing(.lg)) {
            Text(existingID == nil ? "新增账号" : "编辑账号")
                .font(tokens.font(.xl, weight: .semibold))
                .foregroundStyle(tokens.color(.textPrimary))

            TokenTextField(title: "昵称", text: $nickname)
            TokenTextField(title: "游戏名", text: $gameName)
            TokenTextField(title: "分组", text: $groupName)

            HStack(spacing: tokens.spacing(.md)) {
                Button("取消") { dismiss() }
                    .buttonStyle(TokenSecondaryButtonStyle())
                Spacer()
                Button("保存") {
                    onSave(Account(id: existingID ?? UUID(), nickname: nickname, gameName: gameName, groupName: groupName))
                    dismiss()
                }
                .buttonStyle(TokenPrimaryButtonStyle())
                .disabled(nickname.isEmpty || gameName.isEmpty || groupName.isEmpty)
            }
        }
        .padding(tokens.spacing(.xl))
        .background(tokens.color(.panel))
    }
}

private struct TokenTextField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        let tokens = DesignTokens.shared
        TextField(title, text: $text)
            .font(tokens.font(.lg))
            .foregroundStyle(tokens.color(.textPrimary))
            .padding(tokens.spacing(.md))
            .background(tokens.color(.card))
            .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.control)))
            .overlay {
                RoundedRectangle(cornerRadius: tokens.radius(.control))
                    .stroke(tokens.color(.border))
            }
    }
}
