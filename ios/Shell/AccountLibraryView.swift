import SwiftUI
import UniformTypeIdentifiers

struct AccountLibraryView: View {
    @StateObject private var viewModel = AccountLibraryViewModel()
    @State private var isPresentingImporter = false

    let onLaunch: (Account) -> Void

    var body: some View {
        let tokens = DesignTokens.shared
        VStack(spacing: tokens.spacing(.lg)) {
            HStack(spacing: tokens.spacing(.md)) {
                VStack(alignment: .leading, spacing: tokens.spacing(.sm)) {
                    Text("账号库")
                        .font(tokens.font(.xxl, weight: .semibold))
                        .foregroundStyle(tokens.color(.textPrimary))
                    Text("\(viewModel.accounts.count) 个账号 · \(viewModel.selectedIDs.count) 个已选")
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

            HStack(spacing: tokens.spacing(.md)) {
                Button(viewModel.allSelected ? "取消全选" : "全选") {
                    viewModel.toggleSelectAll()
                }
                .buttonStyle(TokenSecondaryButtonStyle())

                Spacer()

                Button("启动已选") {
                    guard let account = viewModel.selectedAccounts.first,
                          viewModel.selectedAccounts.count == 1 else { return }
                    onLaunch(account)
                }
                .buttonStyle(TokenPrimaryButtonStyle())
                .disabled(viewModel.selectedAccounts.count != 1)
            }

            if viewModel.selectedAccounts.count > 1 {
                Text("原生 Cocos 仅支持单实例，请选择一个账号启动。")
                    .font(tokens.font(.sm))
                    .foregroundStyle(tokens.color(.textSecondary))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(tokens.font(.sm))
                    .foregroundStyle(tokens.color(.danger))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            List {
                ForEach(viewModel.accounts) { account in
                    AccountRow(
                        account: account,
                        isSelected: viewModel.selectedIDs.contains(account.id),
                        onToggle: { viewModel.toggleSelection(id: account.id) },
                        onDelete: { viewModel.delete(id: account.id) }
                    )
                    .listRowBackground(tokens.color(.card))
                    .listRowSeparatorTint(tokens.color(.border))
                }
                .onDelete { offsets in
                    for index in offsets {
                        viewModel.delete(id: viewModel.accounts[index].id)
                    }
                }
            }
            .background(tokens.color(.canvas))
        }
        .padding(tokens.spacing(.xl))
        .background(tokens.color(.canvas))
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
}

private struct AccountRow: View {
    let account: Account
    let isSelected: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

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

            Button(action: onDelete) {
                Image(systemName: "trash")
                .font(tokens.font(.lg))
                .foregroundStyle(tokens.color(.danger))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除 \(account.nickname)")
        }
        .padding(.vertical, tokens.spacing(.sm))
    }
}
