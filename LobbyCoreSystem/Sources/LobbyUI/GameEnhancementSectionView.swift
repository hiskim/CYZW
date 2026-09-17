import SwiftUI
import LobbyEngine

/// 「游戏增强」独立分节页。
///
/// 从设置页抽出的原因：增强类功能会持续扩展（十殿加速、聊天窗口、…），
/// 与设置页的「全局配置」语义（画质/帧率/存储/CDN）不同类，独立成 tab
/// 后每项功能一张顶层卡，有独立的扩展空间。
///
/// 现有两项：
/// - **十殿加速**：改写 `NightmareBattlePanel.DEFAULT_TIMESCALE`，让十殿试炼的战斗
///   动画整体加速（只改画面节奏，不改战斗结算）。
/// - **聊天窗口**：把游戏内的聊天面板（消息列表 + 输入区）整块压成不可见；
///   切回「显示」即原地还原，不需要重载实例。
///
/// 全部即时落 UserDefaults，并经会话模型下发全部存活实例；新实例在文档就绪时自行下发。
///
/// **新增功能配方**：照 `chatCard` 复制一张 `featureCard`（rowHeader + 内容 + statusLine），
/// 数据走 `GameEnhancementStore` 加字段 + `session.setXxx()` 即时下发，别新开配置页。
///
/// 文件名保持 `GameEnhancementSectionView.swift`（struct 已从「设置页嵌段」升格为
/// 「独立分节页」并改名）——避免动 pbxproj 的文件登记。
struct EnhancementsSidebarView: View {
    @ObservedObject var session: LobbySessionModel
    @ObservedObject private var enhancements: GameEnhancementStore
    /// 倍率输入框的编辑缓冲：输入即钳制并回写，避免出现「显示 9999、实际 1000」。
    @State private var multiplierDraft = ""

    /// 十殿主题色（与脚本侧 `#f59e0b` 建议提示同源）。
    private static let nightmareAccent = Color(lobbyRGB: 0xF59E0B)
    /// 聊天窗口主题色（取自大厅冷蓝白氛围里的青相位）。
    private static let chatAccent = Color(lobbyRGB: 0x22D3EE)

    init(session: LobbySessionModel) {
        self.session = session
        _enhancements = ObservedObject(wrappedValue: session.enhancements)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 页面大标题：标签页上是短名「增强」，这里放全称。
                Text("游戏增强")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("改写游戏内行为，改档即时下发到存活实例")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -6)

                nightmareCard
                chatCard

                // 页面侧回执：结果别只留在日志里——实测「没生效」时看一眼就能定性
                // （no-handler = 代理没进页面；chat=1/0 = 没找到面板；root=no-root/scene 说明走的哪条路径）。
                if (isNightmareOn || isChatHidden), let report = enhancements.lastPageReport {
                    pageReportLine(report)
                }
            }
            .padding(.vertical, 2)
        }
        .onAppear { multiplierDraft = String(enhancements.nightmareSpeedMultiplier) }
        .onChange(of: enhancements.nightmareSpeedMultiplier) { _, newValue in
            let text = String(newValue)
            if multiplierDraft != text { multiplierDraft = text }
        }
    }

    /// 原样打印页面回执，可选中复制。
    private func pageReportLine(_ report: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(report)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .help("游戏页面回传的实时状态")
    }

    // MARK: - 十殿加速

    private var isNightmareOn: Bool { enhancements.nightmareSpeedEnabled }

    private var nightmareCard: some View {
        featureCard(accent: Self.nightmareAccent, isActive: isNightmareOn) {
            rowHeader(icon: "👹", title: "十殿加速", subtitle: "十殿试炼战斗动画整体加速") {
                Toggle("", isOn: Binding(
                    get: { isNightmareOn },
                    set: { session.setNightmareSpeedEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Self.nightmareAccent)
                .help(isNightmareOn ? "关闭并恢复原始战斗节奏" : "开启十殿加速")
            }

            if isNightmareOn {
                multiplierRow
                statusLine(accent: Self.nightmareAccent, isActive: true, text: nightmareStatusText)
            }
        }
    }

    private var multiplierRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("倍率")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("100", text: multiplierBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.black.opacity(0.28))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .onSubmit { multiplierDraft = String(enhancements.nightmareSpeedMultiplier) }
                Text("倍")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text("推荐 100")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 4) {
                ForEach(GameEnhancementSettings.quickMultipliers, id: \.self) { value in
                    quickMultiplierButton(value)
                }
            }
        }
    }

    private func quickMultiplierButton(_ value: Int) -> some View {
        let isSelected = enhancements.nightmareSpeedMultiplier == value
        return Button {
            session.setNightmareSpeedMultiplier(value)
            multiplierDraft = String(value)
        } label: {
            Text("x\(value)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.75))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Self.nightmareAccent.opacity(0.55) : Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isSelected ? Self.nightmareAccent.opacity(0.9) : Color.white.opacity(0.10),
                                      lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .lobbyHoverHighlight(cornerRadius: 5, intensity: 0.12)
        .help("把倍率设为 x\(value)")
    }

    /// 输入即钳制：只收数字、最多 4 位，越界立刻回写钳制值。
    private var multiplierBinding: Binding<String> {
        Binding(
            get: { multiplierDraft },
            set: { newValue in
                let digits = String(newValue.filter(\.isNumber).prefix(4))
                guard !digits.isEmpty else {
                    // 清空输入框：保留空串（不回退），提交时再还原。
                    multiplierDraft = ""
                    return
                }
                let value = GameEnhancementSettings.clamp(
                    multiplier: Int(digits) ?? GameEnhancementSettings.defaultMultiplier)
                multiplierDraft = String(value)
                session.setNightmareSpeedMultiplier(value)
            }
        )
    }

    /// 状态文案。存活实例数取 `runningAccountIDs`（@Published，会驱动重绘），
    /// 不用 `pool.liveCount`（不是 @Published，文案会停在旧值上）。
    private var nightmareStatusText: String {
        let live = session.runningAccountIDs.count
        let speed = "x\(enhancements.nightmareSpeedMultiplier)"
        guard isNightmareOn else { return "未开启 · 保持原始战斗节奏" }
        return live > 0
            ? "已开启 \(speed) · 已下发 \(live) 个实例"
            : "已开启 \(speed) · 实例启动后自动生效"
    }

    // MARK: - 聊天窗口显示 / 隐藏

    private var isChatHidden: Bool { enhancements.chatPanelHidden }

    private var chatCard: some View {
        featureCard(accent: Self.chatAccent, isActive: isChatHidden) {
            rowHeader(icon: "💬", title: "聊天窗口", subtitle: "整块隐藏游戏内的聊天面板") {}
            chatVisibilityPicker
            statusLine(accent: Self.chatAccent, isActive: isChatHidden, text: chatStatusText)
        }
    }

    /// 两档胶囊（显示 / 隐藏）。用显式两档而不是开关：语义上「显示」也是用户
    /// 主动选的，而开关的「关」容易被读成「这项功能没开」。
    private var chatVisibilityPicker: some View {
        HStack(spacing: 5) {
            chatVisibilityOption(title: "显示", hidden: false)
            chatVisibilityOption(title: "隐藏", hidden: true)
        }
    }

    private func chatVisibilityOption(title: String, hidden: Bool) -> some View {
        let isSelected = enhancements.chatPanelHidden == hidden
        return Button {
            session.setChatPanelHidden(hidden)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : Self.chatAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Self.chatAccent.opacity(0.55) : Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isSelected ? Self.chatAccent.opacity(0.9) : Color.white.opacity(0.10),
                                      lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .lobbyHoverHighlight(cornerRadius: 5, intensity: 0.12)
        .help(hidden ? "隐藏聊天窗口（消息列表 + 输入区）" : "恢复显示聊天窗口")
    }

    private var chatStatusText: String {
        let live = session.runningAccountIDs.count
        guard isChatHidden else { return "正常显示 · 游戏原样" }
        return live > 0
            ? "已隐藏 · 已下发 \(live) 个实例"
            : "已隐藏 · 实例启动后自动生效"
    }

    // MARK: - 卡片配方（顶层卡，与设置页 settingCard 同源）

    /// 功能卡外壳：与 `SidebarSettingsView.settingCard` 同一配方（撑满列宽 + 白 5.5%
    /// 填充 + 顶亮底暗渐变描边），差异仅在「激活时描边染上功能强调色」——
    /// 一眼看出哪个功能开着，不必读状态行文字。
    ///
    /// ⚠️ `.frame(maxWidth: .infinity)` 必须在 padding/background 之前（设置页踩过：
    /// 放后面只有 frame 区域透明拉伸，背景不跟随）。
    private func featureCard<Content: View>(accent: Color, isActive: Bool,
                                            @ViewBuilder content: () -> Content) -> some View {
        let inactiveStroke = LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.06)],
                                            startPoint: .top, endPoint: .bottom)
        let activeStroke = LinearGradient(colors: [accent.opacity(0.55), accent.opacity(0.28)],
                                          startPoint: .top, endPoint: .bottom)
        return VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.white.opacity(isActive ? 0.07 : 0.055)))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isActive ? activeStroke : inactiveStroke, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.16), value: isActive)
    }

    /// 行首：图标 + 标题 + 副标题（+ 右侧控件）。
    private func rowHeader<Accessory: View>(icon: String, title: String, subtitle: String,
                                            @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 8) {
            Text(icon)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            accessory()
        }
    }

    private func statusLine(accent: Color, isActive: Bool, text: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isActive ? accent : Color.secondary)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(isActive ? accent.opacity(0.95) : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}
