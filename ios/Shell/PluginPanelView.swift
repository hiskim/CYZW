import SwiftUI

struct PluginPanelView: View {
    @Bindable var workspace: WorkspaceViewModel
    @State private var plugins = [
        Plugin(name: "资源 JS 配置", detail: "向目标实例注入已验证资源", assetName: "settings.js", isEnabled: true),
        Plugin(name: "状态监视器", detail: "订阅实例生命周期事件", assetName: "status-monitor.js", isEnabled: false)
    ]
    @State private var targetID: UUID?
    @State private var statusMessage: String?

    var body: some View {
        let tokens = DesignTokens.shared

        ScrollView {
            VStack(alignment: .leading, spacing: tokens.spacing(.lg)) {
                Text("插件")
                    .font(tokens.font(.xxl, weight: .semibold))
                    .foregroundStyle(tokens.color(.textPrimary))

                Picker("注入目标", selection: $targetID) {
                    Text("选择实例")
                        .font(tokens.font(.lg))
                        .tag(nil as UUID?)
                    ForEach(workspace.items) { item in
                        Text(item.account.nickname)
                            .font(tokens.font(.lg))
                            .tag(item.id as UUID?)
                    }
                }
                .font(tokens.font(.lg))
                .tint(tokens.color(.accent))
                .padding(tokens.spacing(.md))
                .background(tokens.color(.card))
                .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.control)))

                if let statusMessage {
                    Text(statusMessage)
                        .font(tokens.font(.md))
                        .foregroundStyle(tokens.color(.textSecondary))
                }

                ForEach($plugins) { $plugin in
                    PluginRow(plugin: $plugin) {
                        inject(plugin)
                    }
                }
            }
            .padding(tokens.spacing(.xl))
        }
        .background(tokens.color(.canvas))
    }

    private func inject(_ plugin: Plugin) {
        guard plugin.isEnabled, let targetID, let host = workspace.host(for: targetID) else {
            statusMessage = "请选择已启用插件和目标实例。"
            return
        }
        Task {
            do {
                try await host.inject(resource: .bundled(assetName: plugin.assetName))
                statusMessage = "已向目标实例请求注入 \(plugin.name)。"
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }
}

private struct PluginRow: View {
    @Binding var plugin: Plugin
    let onInject: () -> Void

    var body: some View {
        let tokens = DesignTokens.shared

        VStack(alignment: .leading, spacing: tokens.spacing(.md)) {
            HStack(spacing: tokens.spacing(.md)) {
                VStack(alignment: .leading, spacing: tokens.spacing(.sm)) {
                    Text(plugin.name)
                        .font(tokens.font(.xl, weight: .semibold))
                        .foregroundStyle(tokens.color(.textPrimary))
                    Text(plugin.detail)
                        .font(tokens.font(.md))
                        .foregroundStyle(tokens.color(.textSecondary))
                }
                Spacer()
                Toggle(plugin.name, isOn: $plugin.isEnabled)
                    .labelsHidden()
                    .tint(tokens.color(.accent))
            }
            Button("注入目标实例", action: onInject)
                .buttonStyle(TokenSecondaryButtonStyle())
                .disabled(!plugin.isEnabled)
        }
        .padding(tokens.spacing(.lg))
        .background(tokens.color(.card))
        .clipShape(RoundedRectangle(cornerRadius: tokens.radius(.card)))
        .overlay {
            RoundedRectangle(cornerRadius: tokens.radius(.card))
                .stroke(tokens.color(.border))
        }
    }
}
