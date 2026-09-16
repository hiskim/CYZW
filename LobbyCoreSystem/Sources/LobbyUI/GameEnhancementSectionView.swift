import SwiftUI
import LobbyEngine

/// 配置菜单 ·「游戏加强」功能项。
///
/// 目前包含**十殿加速**：改写 `NightmareBattlePanel.DEFAULT_TIMESCALE`，让十殿
/// 试炼的战斗动画整体加速（只改画面节奏，不改战斗结算）。开关与倍率即时落
/// UserDefaults，并经会话模型下发全部存活实例；新实例在文档就绪时自行下发。
///
/// 视觉沿用设置页配方（与 `SidebarSettingsView.settingCard` 同源），本视图只
/// 负责行内容——卡片外壳由调用方提供。
struct GameEnhancementSectionView: View {
    @ObservedObject var session: LobbySessionModel
    @ObservedObject private var enhancements: GameEnhancementStore
    /// 倍率输入框的编辑缓冲：输入即钳制并回写，避免出现「显示 9999、实际 1000」。
    @State private var multiplierDraft = ""

    /// 十殿主题色（与脚本侧 `#f59e0b` 建议提示同源）。
    private static let accent = Color(red: 0.96, green: 0.62, blue: 0.04)

    init(session: LobbySessionModel) {
        self.session = session
        _enhancements = ObservedObject(wrappedValue: session.enhancements)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            nightmareSpeedRow
        }
        .onAppear { multiplierDraft = String(enhancements.nightmareSpeedMultiplier) }
        .onChange(of: enhancements.nightmareSpeedMultiplier) { _, newValue in
            let text = String(newValue)
            if multiplierDraft != text { multiplierDraft = text }
        }
    }

    // MARK: - 十殿加速

    private var isOn: Bool { enhancements.nightmareSpeedEnabled }

    private var nightmareSpeedRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("👹")
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 2) {
                    Text("十殿加速")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("十殿试炼战斗动画整体加速")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { session.setNightmareSpeedEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Self.accent)
                .help(isOn ? "关闭并恢复原始战斗节奏" : "开启十殿加速")
            }

            if isOn {
                multiplierRow
                statusLine
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(isOn ? 0.055 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isOn ? Self.accent.opacity(0.55) : Color.white.opacity(0.08), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.16), value: isOn)
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
                        .fill(isSelected ? Self.accent.opacity(0.55) : Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isSelected ? Self.accent.opacity(0.9) : Color.white.opacity(0.10),
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

    private var statusLine: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isOn ? Self.accent : Color.secondary)
                .frame(width: 5, height: 5)
            Text(statusText)
                .font(.system(size: 10))
                .foregroundStyle(isOn ? Self.accent.opacity(0.95) : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    /// 状态文案。存活实例数取 `runningAccountIDs`（@Published，会驱动重绘），
    /// 不用 `pool.liveCount`（不是 @Published，文案会停在旧值上）。
    private var statusText: String {
        let live = session.runningAccountIDs.count
        let speed = "x\(enhancements.nightmareSpeedMultiplier)"
        guard isOn else { return "未开启 · 保持原始战斗节奏" }
        return live > 0
            ? "已开启 \(speed) · 已下发 \(live) 个实例"
            : "已开启 \(speed) · 实例启动后自动生效"
    }
}
