import Combine
import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor
final class SettingsViewModel: ObservableObject {
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

/// 设置页（中控台侧栏「设置」分节）。
/// 视觉与脚本管理页同配方：白玻璃卡片 + 胶囊控件 + mini 开关；
/// 页面标题由外层 secondarySection 提供，这里只铺两张卡片。
struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    /// 游戏画质档位：设置面板与 WebKit 启动注入共用同一个 UserDefaults 键。
    @AppStorage(MacRenderQuality.defaultsKey) private var renderQualityRaw = MacRenderQuality.fallback.rawValue
    /// 目标帧率：设置面板与 WebKit 启动注入共用同一个 UserDefaults 键；
    /// 改动时除持久化外还会广播给正在运行的实例。
    @AppStorage(MacFrameRate.defaultsKey) private var frameRateValue = MacFrameRate.fallback.rawValue
    /// 画面左上角的实时帧率角标（实测值，用来肉眼确认设置是否生效）。
    @AppStorage(MacFrameRateHUD.defaultsKey) private var showsFrameRateHUD = false
    /// 自检结果文案（点「校验」后填充）。
    @State private var frameRateVerification = ""
    #if os(macOS)
    @State private var showingClearCDNConfirmation = false
    @AppStorage(MacCDNResourceManager.automaticCachingKey) private var automaticCachingEnabled = true
    @AppStorage(MacCDNResourceManager.idleOnlyCachingKey) private var idleOnlyCachingEnabled = false
    #endif

    /// 与 iOS 版脚本页磁贴同源的成功绿（#22B170），开关统一用它。
    private static let glowGreen = Color(red: 34 / 255.0, green: 177 / 255.0, blue: 112 / 255.0)
    /// 中控台侧栏强调青：与「中控台」标题、分组标签的强调色一致。
    private static let accentCyan = Color.cyan
    /// 危险操作红（清理缓存）。
    private static let dangerRed = Color(red: 1.0, green: 0.37, blue: 0.34)

    private var renderQuality: MacRenderQuality {
        MacRenderQuality(rawValue: renderQualityRaw) ?? MacRenderQuality.fallback
    }

    private var frameRate: MacFrameRate {
        MacFrameRate(rawValue: frameRateValue) ?? MacFrameRate.fallback
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                frameRateCard
                qualityCard
#if os(macOS)
                cdnCard
#endif
            }
            // 视口高于内容时顶部对齐（ScrollView 默认会把小内容垂直居中）。
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
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
        .onChange(of: frameRateValue) { _ in
            // 帧率不像画质：引擎支持运行时改写主循环，改完立刻广播给所有活着的实例。
            frameRate.applyToRunningInstances()
        }
        .onChange(of: showsFrameRateHUD) { _ in
            MacFrameRate.syncHUD()
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

    // MARK: - 帧率卡片

    private var frameRateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 卡头：图标磁贴 + 标题 + 行尾当前帧率胶囊。
            HStack(spacing: 10) {
                settingsIconTile("speedometer", tint: Self.accentCyan)
                Text("游戏帧率")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Text(frameRate.badgeLabel)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Self.accentCyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule(style: .continuous).fill(Self.accentCyan.opacity(0.18)))
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder(Self.accentCyan.opacity(0.85), lineWidth: 1))
            }

            frameRateSegmentedCapsule

            Text(frameRate.summary)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)

            // 角标开关 + 校验按钮：前者持续可见，后者一次性回读实测帧率。
            SettingsToggleRow(
                title: "显示实时帧率角标",
                caption: "画面左上角显示「游戏 FPS / 目标」，附屏幕刷新率仅作对照",
                isOn: $showsFrameRateHUD,
                tint: Self.glowGreen
            )

            HStack(spacing: 6) {
                capsuleButton(title: "校验", systemImage: "checkmark.circle", tone: .accent) {
                    verifyFrameRate()
                }
                if !frameRateVerification.isEmpty {
                    Text(frameRateVerification)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }

            frameRateNotes
        }
        .padding(12)
        .settingsCardSurface(cornerRadius: 12)
    }

    /// 卡片底部两行说明：拆成独立属性，避免卡片 body 过于复杂拖垮类型检查。
    private var frameRateNotes: some View {
        VStack(alignment: .leading, spacing: 4) {
            settingsNoteRow(
                "正在运行的实例立即生效，新实例启动时生效",
                systemImage: "bolt.horizontal"
            )
            settingsNoteRow(
                "只调游戏主循环，不修改显示器刷新率；实测最高只能跑满屏幕刷新率",
                systemImage: "display"
            )
        }
    }

    private func settingsNoteRow(_ text: String, systemImage: String) -> some View {
        Label {
            Text(text)
                .font(.system(size: 10.5))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.secondary)
    }

    /// 对所有存活实例做一次帧率自检：回读「实测 / 引擎目标 / 注入值」并显示。
    /// 实测值是页面里数 1 秒 requestAnimationFrame 得到的，比读设置值可信。
    private func verifyFrameRate() {
        frameRateVerification = "测量中…"
        Task { @MainActor in
            frameRateVerification = await frameRate.verifyAndLog()
        }
    }

    /// 与画质同款胶囊分段选择器，只是选项从三档扩到五档。
    private var frameRateSegmentedCapsule: some View {
        HStack(spacing: 4) {
            ForEach(MacFrameRate.allCases) { option in
                FrameRateOptionCapsule(
                    option: option,
                    isSelected: option == frameRate
                ) {
                    guard option != frameRate else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        frameRateValue = option.rawValue
                    }
                }
            }
        }
        .padding(4)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.28)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    // MARK: - 画质卡片

    /// 帧率档位胶囊：抽成独立 View，既隔离类型检查（七档塞进一张卡会让
    /// SwiftUI 的类型检查超时），也方便单独调样式。
    private struct FrameRateOptionCapsule: View {
        let option: MacFrameRate
        let isSelected: Bool
        let action: () -> Void

        private static let accentCyan = SettingsView.accentCyan

        var body: some View {
            Button(action: action) {
                Text(option.label)
                    .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.60))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isSelected ? Self.accentCyan.opacity(0.85) : Color.white.opacity(0.05))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                isSelected ? Self.accentCyan : Color.white.opacity(0.12),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: isSelected ? Self.accentCyan.opacity(0.35) : .clear,
                            radius: 6, x: 0, y: 0)
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .settingsHoverHighlight(cornerRadius: 50, intensity: isSelected ? 0.04 : 0.10)
            .accessibilityLabel(option.accessibilityLabel)
        }
    }


    private var qualityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 卡头：图标磁贴 + 标题 + 行尾当前像素比胶囊。
            HStack(spacing: 10) {
                settingsIconTile("slider.horizontal.3", tint: Self.accentCyan)
                Text("画质")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Text(renderQuality.pixelRatioLabel)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Self.accentCyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule(style: .continuous).fill(Self.accentCyan.opacity(0.18)))
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder(Self.accentCyan.opacity(0.85), lineWidth: 1))
            }

            qualitySegmentedCapsule

            Text(renderQuality.summary)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)

            Label {
                Text("重新启动游戏实例后生效")
                    .font(.system(size: 10.5))
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .settingsCardSurface(cornerRadius: 12)
    }

    /// 胶囊分段选择器：外层深色胶囊轨道，三枚等宽胶囊选项；
    /// 选中 = 实心青 + 白字 + 微光，未选中 = 白玻璃 + 描边（与分组标签同款）。
    private var qualitySegmentedCapsule: some View {
        HStack(spacing: 4) {
            ForEach(MacRenderQuality.allCases) { quality in
                let isSelected = quality == renderQuality
                Button {
                    guard !isSelected else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        renderQualityRaw = quality.rawValue
                    }
                } label: {
                    Text(quality.label)
                        .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.60))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected ? Self.accentCyan.opacity(0.85) : Color.white.opacity(0.05))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    isSelected ? Self.accentCyan : Color.white.opacity(0.12),
                                    lineWidth: 1
                                )
                        )
                        .shadow(color: isSelected ? Self.accentCyan.opacity(0.35) : .clear,
                                radius: 6, x: 0, y: 0)
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .settingsHoverHighlight(cornerRadius: 50, intensity: isSelected ? 0.04 : 0.10)
                .accessibilityLabel("画质：\(quality.label)")
            }
        }
        .padding(4)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.28)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    // MARK: - CDN 缓存卡片

#if os(macOS)
    private var cdnCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 卡头：图标磁贴 + 标题 + 行尾缓存规模胶囊。
            HStack(spacing: 10) {
                settingsIconTile("externaldrive.badge.icloud", tint: Self.accentCyan)
                Text("CDN 缓存")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                cdnStatusCapsule
            }

            Text("所有账号和实例共享同一份 CDN 缓存。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            cdnToggleRows

            if let status = viewModel.cdnCacheStatus {
                Text(status.directoryPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            HStack(spacing: 6) {
                capsuleButton(title: "同步", systemImage: "arrow.triangle.2.circlepath", tone: .accent) {
                    viewModel.synchronizeCDNCache()
                }
                capsuleButton(title: "清理", systemImage: "trash", tone: .danger) {
                    showingClearCDNConfirmation = true
                }
                capsuleButton(title: "目录", systemImage: "folder", tone: .plain) {
                    viewModel.openCDNCacheDirectory()
                }
            }
            .disabled(viewModel.isCDNBusy)

            HStack(spacing: 6) {
                if viewModel.isCDNBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                if !viewModel.cdnMessage.isEmpty {
                    Text(viewModel.cdnMessage)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .settingsCardSurface(cornerRadius: 12)
    }

    /// 行尾缓存规模胶囊：读取中显示占位，就绪后显示「N 个 · 大小」。
    @ViewBuilder
    private var cdnStatusCapsule: some View {
        if let status = viewModel.cdnCacheStatus {
            Text("\(status.fileCount) 个 · \(ByteCountFormatter.string(fromByteCount: status.byteCount, countStyle: .file))")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.75))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        } else {
            Text("读取中…")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.06)))
        }
    }

    private var cdnToggleRows: some View {
        VStack(spacing: 6) {
            SettingsToggleRow(
                title: "自动缓存 CDN 资源",
                caption: "开启后自动准备 CDN 资源；关闭则由游戏按需缓存",
                isOn: $automaticCachingEnabled,
                tint: Self.glowGreen
            )
            SettingsToggleRow(
                title: "仅空闲时自动缓存",
                caption: "无登录账号时后台预缓存，登录后暂停",
                isOn: $idleOnlyCachingEnabled,
                tint: Self.glowGreen
            )
            .disabled(!automaticCachingEnabled)
            .opacity(automaticCachingEnabled ? 1 : 0.55)
        }
    }
#endif

    // MARK: - 复用小件

    /// 卡头图标磁贴（28×28 圆角 8，主题色淡染），与脚本磁贴同款。
    private func settingsIconTile(_ systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.16))
            )
    }

    private enum CapsuleTone {
        case accent   // 实心青：主操作
        case plain    // 白玻璃描边：普通操作
        case danger   // 红描边：危险操作
    }

    /// 胶囊按钮：等宽铺满一行三枚，语义用颜色区分。
    private func capsuleButton(title: String, systemImage: String, tone: CapsuleTone,
                               action: @escaping () -> Void) -> some View {
        let filled: Bool
        let tint: Color
        switch tone {
        case .accent: filled = true; tint = Self.accentCyan
        case .plain: filled = false; tint = Color.white.opacity(0.75)
        case .danger: filled = false; tint = Self.dangerRed
        }
        return Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(filled ? Color.white : tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(filled ? tint.opacity(0.85) : Color.white.opacity(0.05))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(filled ? 0.9 : 0.55), lineWidth: 1)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .settingsHoverHighlight(cornerRadius: 50, intensity: filled ? 0.06 : 0.10)
    }
}

#if os(macOS)
/// 侧栏窄幅开关行：标题 + 一行说明 + 行尾 mini 开关（与脚本卡片同款质感）。
private struct SettingsToggleRow: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool
    var tint: Color = .green

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.90))
                    .lineLimit(1)
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(isOn ? tint : Color.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}
#endif

// MARK: - 设置页局部样式扩展

private extension View {
    /// 设置卡片表面：白玻璃填充 + 顶亮底暗的描边渐变（与脚本卡片同配方）。
    func settingsCardSurface(cornerRadius: CGFloat) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.055))
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.09)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
            }
    }

    /// 悬停高亮：macOS 走 AppKit tracking-area 版 hoverHighlight；
    /// iOS 目标下为空实现（该页在 iOS 上仍走系统 TabView 外观）。
    @ViewBuilder
    func settingsHoverHighlight(cornerRadius: CGFloat, intensity: Double = 0.08) -> some View {
#if os(macOS)
        self.hoverHighlight(cornerRadius: cornerRadius, intensity: intensity)
#else
        self
#endif
    }
}
