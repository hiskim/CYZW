import SwiftUI
import LobbyDomain
import LobbyEngine

/// 设置分节：画质 / 帧率 / 存储策略 / 音频 / CDN / 调试。
/// 改动即时写 UserDefaults；画质改档经页面桥对存活实例即时生效，
/// 存储策略在实例启动时读取（改档需重启实例）。
struct SidebarSettingsView: View {
    @ObservedObject var session: LobbySessionModel
    /// 帧率角标开关与读数都走加强设置库（与增强页同一份真源），只是**入口放在这里**。
    @ObservedObject private var enhancements: GameEnhancementStore
    @AppStorage(LobbyConfiguration.PreferenceKey.renderQuality) private var renderQualityRaw: String = RenderQuality.fallback.rawValue
    @AppStorage(LobbyConfiguration.PreferenceKey.frameRate) private var frameRateRaw: Int = TargetFrameRate.fallback.rawValue
    @AppStorage(LobbyConfiguration.PreferenceKey.storagePolicy) private var storagePolicyRaw: String = GameStoragePolicy.fallback.rawValue
    @AppStorage(LobbyConfiguration.PreferenceKey.muteWhenUnfocused) private var muteWhenUnfocused: Bool = true
    @AppStorage(LobbyConfiguration.PreferenceKey.cdnAutomaticCaching) private var cdnAutomaticCaching: Bool = true
    @AppStorage(LobbyConfiguration.PreferenceKey.webInspector) private var webInspector: Bool = false

    /// 帧率读数主题色（与增强页的语义色无关，这里只作达标/偏差/没跑满三档）。
    private static let fpsAccent = Color(lobbyRGB: 0x34D399)

    init(session: LobbySessionModel) {
        self.session = session
        _enhancements = ObservedObject(wrappedValue: session.enhancements)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                settingCard(title: "渲染画质",
                            summary: "多开画布的像素比档位，改档即时生效") {
                    pickerRow(options: RenderQuality.allCases, selection: $renderQualityRaw) { $0.label }
                }
                settingCard(title: "目标帧率",
                            summary: "焦点实例的主循环帧率，改档即时生效；非焦点自动降到 \(TargetFrameRate.idleFallback.rawValue) FPS 省电（90/120 受显示器刷新率封顶）") {
                    VStack(alignment: .leading, spacing: 9) {
                        // 7 个档位等宽均分一行：内容自适应放不下会压缩换行（15→1/5 竖排，已踩过）。
                        pickerRow(options: TargetFrameRate.allCases, selection: $frameRateRaw,
                                  label: { "\($0.rawValue)" }, fillsWidth: true)
                        fpsBadgeRow
                    }
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
        .onChange(of: frameRateRaw) { _, _ in
            // 帧率改档同样要推一次：页面侧的帧率只在「实例启动 / 焦点变化」时下发，
            // 少了这一步，正在跑的实例要等到切换账号才读新档（表现为「改了没反应」）。
            session.broadcastFrameRateChange()
        }
        // 角标开着时按 2s 节拍取活读数；关掉 / 离开本页即停（`.task` 随视图消失取消），
        // 不留空闲轮询。
        .task(id: enhancements.fpsDisplayEnabled) {
            guard enhancements.fpsDisplayEnabled else { return }
            while !Task.isCancelled {
                session.refreshEnhancementReports()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: - 帧率角标（档位的自检工具）

    /// 画面帧率角标：开关 + **解析自页面回执**的实测读数。
    ///
    /// 为什么归在这里而不是「游戏增强」页：它的唯一用途就是验证上面那一排档位
    /// 到底生效没有——离被验证的东西越近越好（用户反馈原话即此）。
    private var fpsBadgeRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("画面显示帧率")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("实例画面左上角显示「实测/目标」，用来验证上面档位")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Toggle("", isOn: Binding(
                    get: { enhancements.fpsDisplayEnabled },
                    set: { session.setFPSDisplayEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Self.fpsAccent)
                .help(enhancements.fpsDisplayEnabled
                      ? "关掉角标（同时拆掉页面里的计数钩子）"
                      : "在游戏画面左上角显示帧率")
            }
            if enhancements.fpsDisplayEnabled {
                fpsReadingRow
            }
        }
    }

    /// 实测读数。取**焦点账号**那一路的数（多开时每路不同：焦点跑用户档、其余钉在
    /// 15 FPS）——所以键用账号昵称，与页面回执的 `账号：…` 前缀同源。
    /// 取不到就**把原始回执摆出来**：`no-handler` / `fps=0:0/60` 这类线索比一句
    /// 「暂无数据」有用得多。
    @ViewBuilder
    private var fpsReadingRow: some View {
        if let nickname = session.focusedAccountNickname,
           let reading = enhancements.fpsReading(forAccount: nickname) {
            HStack(spacing: 5) {
                Circle()
                    .fill(fpsReadingColor(reading))
                    .frame(width: 5, height: 5)
                Text("\(nickname) · \(fpsReadingText(reading))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(fpsReadingColor(reading))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        } else if let report = enhancements.lastPageReport {
            Text(report)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("等待实例回执…（实例启动后自动生效）")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func fpsReadingText(_ reading: (measured: Int?, target: Int)) -> String {
        guard let measured = reading.measured else { return "FPS --/\(reading.target) · 采样中" }
        return "FPS \(measured)/\(reading.target)"
    }

    /// 绿 = 达标（≥ 85% 目标）、黄 = 有偏差（≥ 55%）、灰 = 还没有数。
    private func fpsReadingColor(_ reading: (measured: Int?, target: Int)) -> Color {
        guard let measured = reading.measured, reading.target > 0 else { return Color.secondary }
        let ratio = Double(measured) / Double(reading.target)
        if ratio >= 0.85 { return Self.fpsAccent }
        if ratio >= 0.55 { return Color(lobbyRGB: 0xFBBF24) }
        return Color(lobbyRGB: 0xF87171)
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
        // ⚠️ 必须在 padding/background 之前撑满：所有卡片统一 = 内容列宽，
        // 否则各卡按自身内容理想宽度布局，侧栏里一列卡片宽窄不一。
        .frame(maxWidth: .infinity, alignment: .leading)
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
    ///
    /// - `fillsWidth = false`（默认）：胶囊按内容自适应，放不下时经 `LobbyFlowLayout`
    ///   优雅换行——绝不压缩胶囊（压缩 = 文字竖排，目标帧率曾踩过）。
    /// - `fillsWidth = true`：档位多时（如 7 个帧率档）等宽均分一行，铺满卡片内宽，
    ///   视觉成一条整齐的档位条。
    private func pickerRow<Option: Identifiable>(options: [Option],
                                                 selection: Binding<Option.ID>,
                                                 label: @escaping (Option) -> String,
                                                 fillsWidth: Bool = false) -> some View {
        Group {
            if fillsWidth {
                HStack(spacing: 5) {
                    ForEach(options) { option in
                        capsule(option, selection: selection, label: label, fillsWidth: true)
                    }
                }
            } else {
                LobbyFlowLayout(horizontalSpacing: 5, verticalSpacing: 5) {
                    ForEach(options) { option in
                        capsule(option, selection: selection, label: label, fillsWidth: false)
                    }
                }
            }
        }
    }

    private func capsule<Option: Identifiable>( _ option: Option,
                                                selection: Binding<Option.ID>,
                                                label: @escaping (Option) -> String,
                                                fillsWidth: Bool) -> some View {
        Button {
            selection.wrappedValue = option.id
        } label: {
            LobbyStatusCapsule(text: label(option),
                               tint: .cyan,
                               isSelected: selection.wrappedValue == option.id,
                               fillsWidth: fillsWidth)
        }
        .buttonStyle(.plain)
        .lobbyHoverHighlight(cornerRadius: 50, intensity: 0.10)
    }
}
