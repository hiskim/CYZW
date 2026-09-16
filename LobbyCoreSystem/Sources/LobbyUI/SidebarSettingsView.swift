import SwiftUI
import LobbyDomain

/// 设置分节：画质 / 帧率 / 存储策略 / 音频 / CDN / 调试。
/// 改动即时写 UserDefaults；画质改档经页面桥对存活实例即时生效，
/// 存储策略在实例启动时读取（改档需重启实例）。
struct SidebarSettingsView: View {
    @ObservedObject var session: LobbySessionModel
    @AppStorage(LobbyConfiguration.PreferenceKey.renderQuality) private var renderQualityRaw: String = RenderQuality.fallback.rawValue
    @AppStorage(LobbyConfiguration.PreferenceKey.frameRate) private var frameRateRaw: Int = TargetFrameRate.fallback.rawValue
    @AppStorage(LobbyConfiguration.PreferenceKey.storagePolicy) private var storagePolicyRaw: String = GameStoragePolicy.fallback.rawValue
    @AppStorage(LobbyConfiguration.PreferenceKey.muteWhenUnfocused) private var muteWhenUnfocused: Bool = true
    @AppStorage(LobbyConfiguration.PreferenceKey.cdnAutomaticCaching) private var cdnAutomaticCaching: Bool = true
    @AppStorage(LobbyConfiguration.PreferenceKey.webInspector) private var webInspector: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                settingCard(title: "渲染画质",
                            summary: "多开画布的像素比档位，改档即时生效") {
                    pickerRow(options: RenderQuality.allCases, selection: $renderQualityRaw) { $0.label }
                }
                settingCard(title: "目标帧率",
                            summary: "焦点实例的主循环帧率；非焦点自动降到 \(TargetFrameRate.idleFallback.rawValue) FPS 省电") {
                    pickerRow(options: TargetFrameRate.allCases, selection: $frameRateRaw) { "\($0.rawValue)" }
                }
                settingCard(title: "游戏内存储",
                            summary: "WebKit 持久化容器策略，改档需重启实例") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(GameStoragePolicy.allCases) { policy in
                            Button {
                                storagePolicyRaw = policy.rawValue
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(policy.label)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.white)
                                        Text(policy.summary)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    if storagePolicyRaw == policy.rawValue {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.cyan)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .lobbyHoverHighlight(cornerRadius: 6, intensity: 0.06)
                        }
                    }
                }
                toggleCard(title: "非焦点静音", summary: "多开时未聚焦实例自动静音（推荐）",
                           isOn: $muteWhenUnfocused)
                settingCard(title: "游戏加强",
                            summary: "改档即时下发到存活实例") {
                    GameEnhancementSectionView(session: session)
                }
                toggleCard(title: "CDN 自动缓存", summary: "启动预热核心资源并共享给全部实例",
                           isOn: $cdnAutomaticCaching)
                toggleCard(title: "Web 检查器", summary: "允许右键调出 Safari Web Inspector（排障用）",
                           isOn: $webInspector)
            }
            .padding(.vertical, 2)
        }
        .onChange(of: renderQualityRaw) { _, newValue in
            // 画质改档即时生效：广播给所有存活实例（页面桥重算画布）；
            // 新实例由引导脚本从 UserDefaults 读取。
            if let quality = RenderQuality(rawValue: newValue) {
                session.broadcastQualityChange(quality)
            }
        }
    }

    // MARK: - 卡片模板（侧栏统一配方）

    private func settingCard<Content: View>(title: String, summary: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text(summary)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.055)))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.06)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
        )
    }

    private func toggleCard(title: String, summary: String, isOn: Binding<Bool>) -> some View {
        settingCard(title: title, summary: summary) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    /// 横向胶囊选择行。
    private func pickerRow<Option: Identifiable>(options: [Option],
                                                 selection: Binding<Option.ID>,
                                                 label: @escaping (Option) -> String) -> some View {
        HStack(spacing: 5) {
            ForEach(options) { option in
                Button {
                    selection.wrappedValue = option.id
                } label: {
                    LobbyStatusCapsule(text: label(option),
                                       tint: .cyan,
                                       isSelected: selection.wrappedValue == option.id)
                }
                .buttonStyle(.plain)
                .lobbyHoverHighlight(cornerRadius: 50, intensity: 0.10)
            }
        }
    }
}
