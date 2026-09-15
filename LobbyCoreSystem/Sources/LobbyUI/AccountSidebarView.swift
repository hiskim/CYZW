import SwiftUI
import UniformTypeIdentifiers
import LobbyDomain
import LobbyEngine

/// 账号分节：账号卡片列表 + 导入入口。
/// 卡片配方：白玻璃填充 + 顶亮底暗描边 + 图标磁贴 + 状态胶囊。
struct AccountSidebarView: View {
    @ObservedObject var session: LobbySessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if session.accounts.isEmpty {
                emptyState
            } else {
                accountList
            }
        }
    }

    private var header: some View {
        HStack {
            Text("账号库")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有账号")
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

    private var accountList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(session.accounts) { account in
                    AccountSidebarCard(session: session, account: account)
                }
            }
            .padding(.vertical, 2)
        }
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
            session.importFiles(from: panel.urls)
        }
    }
}

/// 侧栏账号卡片。
struct AccountSidebarCard: View {
    @ObservedObject var session: LobbySessionModel
    let account: GameAccount

    private var isRunning: Bool { session.isRunning(account) }
    private var isFocused: Bool { session.focusedAccountID == account.id }

    var body: some View {
        HStack(spacing: 10) {
            // 28×28 图标磁贴（卡片头统一配方）。
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(isRunning ? Color.cyan : Color.white.opacity(0.55))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
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
                Text(account.groupName)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            // 状态胶囊 + 主操作。
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
            Button("删除账号文件", role: .destructive) { session.requestDelete(account) }
        }
    }
}
