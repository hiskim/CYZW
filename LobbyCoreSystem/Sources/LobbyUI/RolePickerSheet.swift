import SwiftUI
import LobbyDomain
import LobbyEngine

/// 选区面板：把一个 `.bin` 名下的多个区服角色摊开，选一个生成独立的账号副本。
///
/// 为什么是「生成副本」而不是「切换本账号的区服」：
/// 账号 ID = 凭据文件内容的 SHA256，所以换过 `serverId` 的凭据**天生就是另一个账号**——
/// 实例、`WKWebsiteDataStore`、localStorage、头像、分组全部自动隔离，
/// 存储层一行都不用改，而且不同区可以**同时多开**。原凭据一字不动，随时退回。
///
/// 数据来源是 `/login/serverlist`：**纯 HTTP，不建立游戏会话**，
/// 所以正在运行的账号也能查（不会顶号）。
struct RolePickerSheet: View {
    @ObservedObject var session: LobbySessionModel
    let account: GameAccount
    let onDismiss: () -> Void

    /// 本次面板已生成过的文件名（只用于把那一行标成「已生成」，不碰磁盘）。
    @State private var generated: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            divider
            content
            divider
            footer
        }
        .padding(16)
        .frame(width: 460)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.14)))
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("选择区服与角色 · \(account.nickname)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("选中哪个区服，就为它生成一份独立的账号副本（原账号不动）。"
                 + "副本是独立实例，可以同时开在不同区服上。")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.rolePickerState {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在查询该账号名下的区服角色…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.65))
            }
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text("查询失败：\(message)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                    .fixedSize(horizontal: false, vertical: true)
                Button("重试") { session.requestRoles(for: account) }
            }
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)

        case .loaded(let list):
            if list.roles.isEmpty {
                Text("服务端没有返回这个账号的区服角色列表。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.65))
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(list.roles) { role in
                            roleRow(role, list: list)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
    }

    private func roleRow(_ role: GameRole, list: AccountRoleList) -> some View {
        let fileName = role.derivedBinFileName(basedOn: account.fileName)
        let isCurrent = list.isCurrent(role)
        let isGenerated = generated.contains(fileName)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("\(role.serverNumber) 服")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    if role.slotIndex > 0 {
                        tag("小号\(role.slotIndex)", tint: Color.white.opacity(0.5))
                    }
                    if isCurrent {
                        tag("上次登录", tint: Color(red: 1.0, green: 0.78, blue: 0.30))
                    }
                }
                Text(role.name.isEmpty ? "（无角色名）" : role.name)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if role.power > 0 {
                Text(AccountSidebarCard.abridgedPower(Int(clamping: role.power)))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(AccountSidebarCard.powerTint)
                    .help("服务端上报的战力 \(role.power)")
            }
            if isCurrent {
                // ⚠️ 这里标的是「服务端记的上次登录区」（`recommendId`），**不是**凭据自带的
                // 区服 —— 两者实测会不一致（跑过几次登录之后 recommendId 会变）。所以文案
                // 不能写成「原账号已在此区」，否则用户会以为原账号就在这个区。
                Text("上次登录区")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.4))
            } else if isGenerated {
                Text("已生成")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(red: 0.55, green: 0.86, blue: 1.0))
            } else {
                Button("生成账号") {
                    if session.deriveAccount(from: account, role: role) != nil {
                        generated.insert(fileName)
                    }
                }
                .controlSize(.small)
                .disabled(session.derivingRoleID != nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(isCurrent ? 0.07 : 0.04)))
    }

    private func tag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.16)))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("战力为服务端上报值，仅当前区服准确；生成后可点「刷新资料」拉取精确数据。")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("关闭", action: onDismiss)
                .keyboardShortcut(.cancelAction)
        }
    }
}
