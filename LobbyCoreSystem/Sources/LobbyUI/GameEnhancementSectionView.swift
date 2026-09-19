import SwiftUI
import LobbyEngine

/// 「游戏增强」独立分节页。
///
/// 从设置页抽出的原因：增强类功能会持续扩展（十殿加速、UI 加速、聊天窗口、…），
/// 与设置页的「全局配置」语义（画质/帧率/存储/CDN）不同类，独立成 tab
/// 后每项功能一张顶层卡，有独立的扩展空间。
///
/// 现有三项：
/// - **十殿加速**：改写 `NightmareBattlePanel.DEFAULT_TIMESCALE`，让十殿试炼的战斗
///   动画整体加速（只改画面节奏，不改战斗结算）。
/// - **UI 加速**：改引擎全局时间倍率（`cc.director.getScheduler()` 的 `_timeScale`），
///   面板过渡 / FairyGUI 补间 / cc 动作整体加快；机制与官方 APK 运行时的
///   `engineGlobalSpeed` 一致，细节见 `GameEnhancementScript` 文件头 ③。
/// - **聊天窗口**：把游戏内的聊天面板（消息列表 + 输入区）整块压成不可见；
///   切回「显示」即原地还原，不需要重载实例。
///
/// ⚠️ 「帧率显示」角标**不在这里**——它属于设置页「目标帧率」那张卡的自检工具
/// （开了就能当场看出档位到底生效没有），落在增强页会离被验证的东西太远。
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
    /// UI 加速倍率的编辑缓冲（同上，值是 Double、0.5 步进）。
    @State private var uiSpeedDraft = ""

    /// 十殿主题色（与脚本侧 `#f59e0b` 建议提示同源）。
    private static let nightmareAccent = Color(lobbyRGB: 0xF59E0B)
    /// 聊天窗口主题色（取自大厅冷蓝白氛围里的青相位）。
    private static let chatAccent = Color(lobbyRGB: 0x22D3EE)
    /// UI 加速主题色（紫相位：与十殿的橙、聊天的青互不撞色）。
    private static let uiSpeedAccent = Color(lobbyRGB: 0xA78BFA)

    init(session: LobbySessionModel) {
        self.session = session
        _enhancements = ObservedObject(wrappedValue: session.enhancements)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 分节子标题：与「全部账号」「JS 脚本管理器」同规格（12pt semibold secondary）。
                Text("游戏增强")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                nightmareCard
                uiSpeedCard
                chatCard

                // 页面侧回执：结果别只留在日志里——实测「没生效」时看一眼就能定性
                // （no-handler = 代理没进页面；chat=1/0 = 没找到面板；root=no-root/scene 说明走的哪条路径）。
                if (isNightmareOn || isChatHidden || isUISpeedOn), let report = enhancements.lastPageReport {
                    pageReportLine(report)
                }
            }
            .padding(.vertical, 2)
        }
        .onAppear {
            multiplierDraft = String(enhancements.nightmareSpeedMultiplier)
            uiSpeedDraft = Self.uiSpeedText(enhancements.uiSpeedMultiplier)
        }
        .onChange(of: enhancements.nightmareSpeedMultiplier) { _, newValue in
            let text = String(newValue)
            if multiplierDraft != text { multiplierDraft = text }
        }
        .onChange(of: enhancements.uiSpeedMultiplier) { _, newValue in
            // 与 store 同步（外部改档 / 快捷档点击后回正输入框）。
            if uiSpeedDraft != Self.uiSpeedText(newValue) { uiSpeedDraft = Self.uiSpeedText(newValue) }
        }
    }

    /// 倍率 → 输入框文本：整数档不带小数点（`3` 而不是 `3.0`）。
    private static func uiSpeedText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
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
        speedRow(draft: multiplierBinding,
                 placeholder: "100",
                 recommended: "推荐 100",
                 quickOptions: GameEnhancementSettings.quickMultipliers.map {
                     (value: Double($0), label: "x\($0)")
                 },
                 isSelected: { enhancements.nightmareSpeedMultiplier == Int($0) },
                 accent: Self.nightmareAccent,
                 onQuick: { value in
                     session.setNightmareSpeedMultiplier(Int(value))
                     multiplierDraft = String(Int(value))
                 },
                 onSubmit: { multiplierDraft = String(enhancements.nightmareSpeedMultiplier) })
    }

    /// 倍率行（十殿加速 / UI 加速共用）：文本框 + 快捷档胶囊。
    ///
    /// 两处样式**必须同源**——各自复制一份的话，改圆角 / 宽度时必漏掉一个；
    /// 差异只在值域、步进与文案，靠参数注入。
    private func speedRow(draft: Binding<String>,
                          placeholder: String,
                          recommended: String,
                          quickOptions: [(value: Double, label: String)],
                          isSelected: @escaping (Double) -> Bool,
                          accent: Color,
                          onQuick: @escaping (Double) -> Void,
                          onSubmit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("倍率")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: draft)
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
                    .onSubmit(onSubmit)
                Text("倍")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text(recommended)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 4) {
                ForEach(quickOptions, id: \.value) { option in
                    quickSpeedButton(option.label,
                                     selected: isSelected(option.value),
                                     accent: accent) {
                        onQuick(option.value)
                    }
                }
            }
        }
    }

    private func quickSpeedButton(_ label: String, selected: Bool, accent: Color,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.75))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(selected ? accent.opacity(0.55) : Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(selected ? accent.opacity(0.9) : Color.white.opacity(0.10),
                                      lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .lobbyHoverHighlight(cornerRadius: 5, intensity: 0.12)
        .help("把倍率设为 \(label)")
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

    // MARK: - UI 加速（引擎全局时间倍率）

    private var isUISpeedOn: Bool { enhancements.uiSpeedEnabled }

    /// 与十殿加速同形状（开关 + 倍率 + 快捷档 + 状态行），但改的是**引擎全局**时间倍率，
    /// 所以没有「面板没打开」这类前置：开关一开，所有界面的补间 / 过渡都变快。
    private var uiSpeedCard: some View {
        featureCard(accent: Self.uiSpeedAccent, isActive: isUISpeedOn) {
            rowHeader(icon: "⚡", title: "UI 加速", subtitle: "全局时间倍率——面板过渡 / 补间动效整体加快") {
                Toggle("", isOn: Binding(
                    get: { isUISpeedOn },
                    set: { session.setUISpeedEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Self.uiSpeedAccent)
                .help(isUISpeedOn ? "关闭并还原引擎原始节奏" : "开启 UI 加速")
            }

            if isUISpeedOn {
                uiSpeedRow
                statusLine(accent: Self.uiSpeedAccent, isActive: true, text: uiSpeedStatusText)
            }
        }
    }

    private var uiSpeedRow: some View {
        speedRow(draft: uiSpeedBinding,
                 placeholder: "3",
                 recommended: "推荐 3",
                 quickOptions: GameEnhancementSettings.quickUISpeeds.map {
                     (value: $0, label: GameEnhancementSettings.describe(speed: $0))
                 },
                 isSelected: { abs(enhancements.uiSpeedMultiplier - $0) < 0.001 },
                 accent: Self.uiSpeedAccent,
                 onQuick: { value in
                     session.setUISpeedMultiplier(value)
                     uiSpeedDraft = Self.uiSpeedText(value)
                 },
                 onSubmit: { uiSpeedDraft = Self.uiSpeedText(enhancements.uiSpeedMultiplier) })
    }

    /// 输入即钳制：只收数字与一个小数点、最多 4 字符；越界立刻回写钳制值。
    ///
    /// ⚠️ 与十殿（纯整数）的差别：**结尾是小数点时不写档**——否则输入「1.5」的
    /// 中间态 `1.` 会被解析成 1 并回写掉小数点，用户永远打不出小数。
    private var uiSpeedBinding: Binding<String> {
        Binding(
            get: { uiSpeedDraft },
            set: { newValue in
                let sanitized = Self.sanitizeSpeedInput(newValue)
                uiSpeedDraft = sanitized
                guard !sanitized.isEmpty, sanitized != ".",
                      !sanitized.hasSuffix("."),
                      let parsed = Double(sanitized) else { return }
                session.setUISpeedMultiplier(parsed)
                let clamped = Self.uiSpeedText(GameEnhancementSettings.clamp(speed: parsed))
                if clamped != sanitized { uiSpeedDraft = clamped }
            }
        )
    }

    /// 输入过滤：只留数字与第一个小数点，最多 4 个字符（`1.75` 封顶）。
    private static func sanitizeSpeedInput(_ raw: String) -> String {
        var text = ""
        var dotSeen = false
        for character in raw where character.isNumber || character == "." {
            if character == "." {
                if dotSeen { continue }
                dotSeen = true
            }
            text.append(character)
            if text.count >= 4 { break }
        }
        return text
    }

    /// 状态文案（口径与十殿一致：存活实例数取 @Published 的 `runningAccountIDs`）。
    private var uiSpeedStatusText: String {
        let live = session.runningAccountIDs.count
        let speed = GameEnhancementSettings.describe(speed: enhancements.uiSpeedMultiplier)
        guard isUISpeedOn else { return "未开启 · 保持引擎原始节奏" }
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
