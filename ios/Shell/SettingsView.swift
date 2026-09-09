import Combine
import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor
final class SettingsViewModel: ObservableObject {
    enum AccentChoice: String, CaseIterable, Identifiable {
        case accent
        case primaryButton
        case success

        var id: String { rawValue }

        var label: String {
            switch self {
            case .accent: return "强调蓝"
            case .primaryButton: return "主按钮蓝"
            case .success: return "成功绿"
            }
        }

        var token: DesignColorToken {
            switch self {
            case .accent: return .accent
            case .primaryButton: return .primaryButton
            case .success: return .success
            }
        }
    }

    enum PerformanceProfile: String, CaseIterable, Identifiable {
        case balanced
        case performance
        case batterySaver

        var id: String { rawValue }

        var label: String {
            switch self {
            case .balanced: return "均衡"
            case .performance: return "性能优先"
            case .batterySaver: return "省电"
            }
        }
    }

    @Published var accentChoice: AccentChoice = .accent
    @Published var fontToken: DesignFontToken = .lg
    @Published var performanceProfile: PerformanceProfile = .balanced

#if os(macOS)
    @Published var cdnCacheStatus: MacCDNCacheStatus?
    @Published var isCDNBusy = false
    @Published var cdnMessage = ""

    func refreshCDNCacheStatus() {
        Task { @MainActor in
            cdnCacheStatus = await MacCDNResourceManager.shared.cacheStatus()
        }
    }

    func synchronizeCDNCache() {
        guard !isCDNBusy else { return }
        isCDNBusy = true
        cdnMessage = "正在同步 CDN 缓存..."
        Task { @MainActor in
            let success = await MacCDNResourceManager.shared.synchronizeCache()
            cdnCacheStatus = await MacCDNResourceManager.shared.cacheStatus()
            isCDNBusy = false
            cdnMessage = success ? "同步完成" : "同步失败，请查看 Xcode 控制台日志"
        }
    }

    func clearCDNCache() {
        guard !isCDNBusy else { return }
        isCDNBusy = true
        cdnMessage = "正在清理 CDN 缓存..."
        Task { @MainActor in
            cdnCacheStatus = await MacCDNResourceManager.shared.clearCache()
            isCDNBusy = false
            cdnMessage = "缓存已清理"
        }
    }

    func openCDNCacheDirectory() {
        Task { @MainActor in
            let url = await MacCDNResourceManager.shared.cacheDirectoryURL()
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        }
    }
#endif
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    #if os(macOS)
    @State private var showingClearCDNConfirmation = false
    @AppStorage(MacCDNResourceManager.automaticCachingKey) private var automaticCachingEnabled = true
    @AppStorage(MacCDNResourceManager.idleOnlyCachingKey) private var idleOnlyCachingEnabled = false
    #endif

    var body: some View {
        let tokens = DesignTokens.shared
        ScrollView {
            VStack(alignment: .leading, spacing: tokens.spacing(.lg)) {
                Text("设置")
                    .font(tokens.font(.xxl, weight: .semibold))
                    .foregroundStyle(tokens.color(.textPrimary))

                TokenSettingsCard(title: "主题色") {
                    Picker("主题色", selection: $viewModel.accentChoice) {
                        ForEach(SettingsViewModel.AccentChoice.allCases) { choice in
                            HStack(spacing: tokens.spacing(.sm)) {
                                Circle()
                                    .fill(tokens.color(choice.token))
                                    .frame(width: tokens.spacing(.md), height: tokens.spacing(.md))
                                Text(choice.label).font(tokens.font(.lg))
                            }
                            .tag(choice)
                        }
                    }
                    .font(tokens.font(.lg))
                    .tint(tokens.color(.accent))
                }

                TokenSettingsCard(title: "字号") {
                    Picker("字号", selection: $viewModel.fontToken) {
                        ForEach(DesignFontToken.allCases, id: \.self) { token in
                            Text("\(token.rawValue) · \(Int(tokens.fontSize(token)))px")
                                .font(tokens.font(token))
                                .tag(token)
                        }
                    }
                    .font(tokens.font(.lg))
                    .tint(tokens.color(.accent))
                    Text("预览文本")
                        .font(tokens.font(viewModel.fontToken))
                        .foregroundStyle(tokens.color(.textPrimary))
                }

                TokenSettingsCard(title: "性能档位") {
                    Picker("性能档位", selection: $viewModel.performanceProfile) {
                        ForEach(SettingsViewModel.PerformanceProfile.allCases) { profile in
                            Text(profile.label)
                                .font(tokens.font(.lg))
                                .tag(profile)
                        }
                    }
                    .font(tokens.font(.lg))
                    .tint(tokens.color(.accent))
                }

#if os(macOS)
                TokenSettingsCard(title: "多开实例") {
                    Text("每个 macOS 进程使用独立的 Shell 状态，可分别登录不同账号。")
                        .font(tokens.font(.md))
                    Button {
                        MacOSShellInstanceLauncher.openNewInstance()
                    } label: {
                        Label("打开新的应用实例", systemImage: "plus.rectangle.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TokenSecondaryButtonStyle())
                }

                TokenSettingsCard(title: "CDN 缓存") {
                    VStack(alignment: .leading, spacing: tokens.spacing(.md)) {
                        Text("所有账号和实例共享同一份 CDN 缓存。")
                            .font(tokens.font(.md))

                        Toggle("自动缓存 CDN 资源", isOn: $automaticCachingEnabled)
                            .font(tokens.font(.md, weight: .medium))
                        Text("开启后，应用会自动准备 CDN 资源；关闭后只由游戏进入后按需缓存。")
                            .font(tokens.font(.sm))
                            .foregroundStyle(tokens.color(.textMuted))

                        Toggle("仅空闲时自动缓存", isOn: $idleOnlyCachingEnabled)
                            .font(tokens.font(.md, weight: .medium))
                            .disabled(!automaticCachingEnabled)
                        Text("开启后，仅在没有登录账号时后台预缓存；登录后暂停，改由游戏自身按需缓存。")
                            .font(tokens.font(.sm))
                            .foregroundStyle(tokens.color(.textMuted))

                        if let status = viewModel.cdnCacheStatus {
                            Text("已缓存 \(status.fileCount) 个文件 · \(ByteCountFormatter.string(fromByteCount: status.byteCount, countStyle: .file))")
                                .font(tokens.font(.md, weight: .medium))
                                .foregroundStyle(tokens.color(.textPrimary))
                            Text(status.directoryPath)
                                .font(.system(size: tokens.fontSize(.sm), design: .monospaced))
                                .foregroundStyle(tokens.color(.textMuted))
                                .textSelection(.enabled)
                                .lineLimit(2)
                        } else {
                            Text("正在读取缓存状态...")
                                .font(tokens.font(.md))
                        }

                        HStack(spacing: tokens.spacing(.sm)) {
                            Button {
                                viewModel.synchronizeCDNCache()
                            } label: {
                                Label("同步缓存", systemImage: "arrow.triangle.2.circlepath")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(TokenPrimaryButtonStyle())

                            Button {
                                showingClearCDNConfirmation = true
                            } label: {
                                Label("清理缓存", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(TokenSecondaryButtonStyle())

                            Button {
                                viewModel.openCDNCacheDirectory()
                            } label: {
                                Label("打开目录", systemImage: "folder")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(TokenSecondaryButtonStyle())
                        }
                        .disabled(viewModel.isCDNBusy)

                        if viewModel.isCDNBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        if !viewModel.cdnMessage.isEmpty {
                            Text(viewModel.cdnMessage)
                                .font(tokens.font(.sm))
                                .foregroundStyle(tokens.color(.textSecondary))
                        }
                    }
                }
#endif
            }
            .padding(tokens.spacing(.xl))
        }
        .background(tokens.color(.canvas))
#if os(macOS)
        .task {
            viewModel.refreshCDNCacheStatus()
        }
        .onChange(of: automaticCachingEnabled) { _ in
            Task { await MacCDNResourceManager.shared.updateCachingSettings() }
        }
        .onChange(of: idleOnlyCachingEnabled) { _ in
            Task { await MacCDNResourceManager.shared.updateCachingSettings() }
        }
        .confirmationDialog(
            "确认清理 CDN 缓存？",
            isPresented: $showingClearCDNConfirmation,
            titleVisibility: .visible
        ) {
            Button("清理缓存", role: .destructive) {
                viewModel.clearCDNCache()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清理后，下次同步或进入游戏时会重新下载资源。")
        }
#endif
    }
}

private struct TokenSettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        let tokens = DesignTokens.shared
        VStack(alignment: .leading, spacing: tokens.spacing(.md)) {
            Text(title)
                .font(tokens.font(.xl, weight: .semibold))
                .foregroundStyle(tokens.color(.textPrimary))
            content
                .foregroundStyle(tokens.color(.textSecondary))
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

#if os(macOS)
/// Starts another process of the installed app. This stays in the Shell layer
/// and does not change authentication or game startup.
enum MacOSShellInstanceLauncher {
    static func openNewInstance() {
        guard #available(macOS 10.15, *) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        )
    }
}
#endif
