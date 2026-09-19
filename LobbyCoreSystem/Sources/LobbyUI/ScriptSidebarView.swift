import SwiftUI
import UniformTypeIdentifiers
import LobbyDomain
import LobbyEngine

/// 脚本分节（304pt 中控台侧栏）：全局双开关磁贴 + 脚本卡片列表。
/// 语义与上一代 MacScriptManagerView 一一对应：
/// - 总开关关闭 → 整列蒙版 +「全局已暂停」横幅，不注入任何脚本；
/// - 多开门禁关闭 → 多开矩阵实例不注入（防误操作多开封号）；
/// - 卡片：状态胶囊（单开=蓝 / 单多开=紫 / 禁用=灰，启用时点击切环境）
///   + 主开关 + 点击弹操作窗（三态 / 删除）。
/// 导入用 NSOpenPanel（.fileImporter 在无边框玻璃窗深层子视图会静默不弹）。
struct ScriptSidebarView: View {
    /// 脚本库（session 持有，观察它驱动列表刷新）。
    @ObservedObject private var scripts: ScriptStore
    /// 当前弹出操作窗的脚本（nil = 无弹窗）。
    @State private var popupScript: ScriptRecord?

    init(session: LobbySessionModel) {
        _scripts = ObservedObject(wrappedValue: session.scripts)
    }

    /// 导入面板配置（面板实例按 purpose 复用，见 LobbyTheme.swift 的 LobbyFilePanel）。
    private static let importSpec = LobbyFilePanelSpec(
        purpose: "scripts",
        title: "选择要导入的 JS 脚本",
        message: "可多选 .js 文件；导入后默认「单开生效」",
        extensions: ["js"],
        allowsMultipleSelection: true)

    /// 已启用脚本数（与旧版「已启用 x/y」标题一致）。
    private var enabledCount: Int {
        scripts.scripts.filter { $0.isEnabled }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScriptGlobalTile(
                icon: "chevron.left.forwardslash.chevron.right",
                title: "JS 引擎总开关",
                isOn: scripts.isGlobalEnabled,
                onHint: "运行中",
                offHint: "已暂停",
                offAccent: .gray,
                onToggle: { scripts.isGlobalEnabled.toggle() }
            )
            ScriptGlobalTile(
                icon: "shield.lefthalf.filled",
                title: "多开全局门禁",
                isOn: scripts.isMultiOpenGateEnabled,
                onHint: "多开允许",
                offHint: "多开禁止",
                offAccent: .red,
                onToggle: { scripts.isMultiOpenGateEnabled.toggle() }
            )

            if scripts.isGlobalEnabled {
                listHeader
            }

            if scripts.isGlobalEnabled {
                scriptList
                    .opacity(scripts.scripts.isEmpty ? 0 : 1)
                    .overlay {
                        if scripts.scripts.isEmpty { emptyState }
                    }
            } else {
                emptyState
                    .opacity(0.55)
            }
        }
        // 分节一出现就预热面板实例（空闲期；把首次创建的几百毫秒挪出点击路径）。
        .onAppear { LobbyFilePanel.prepare(Self.importSpec) }
        .sheet(item: $popupScript) { record in
            ScriptActionSheet(scripts: scripts, record: record) {
                popupScript = nil
            }
        }
    }

    private var header: some View {
        HStack {
            Text("JS 脚本管理器")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                showImportPanel()
            } label: {
                Label("导入", systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(Color.cyan.opacity(0.28)))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.cyan.opacity(0.7), lineWidth: 1))
            .lobbyHoverHighlight(cornerRadius: 50, intensity: 0.12)
            .help("导入 .js 脚本文件（可多选）")
        }
    }

    private var listHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("脚本列表 · 已启用 \(enabledCount)/\(scripts.scripts.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let message = scripts.lastMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            } else {
                Text("点击卡片配置状态")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var scriptList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(scripts.scripts) { record in
                    ScriptCard(
                        record: record,
                        onToggle: { scripts.setEnabled($0, for: record.name) },
                        onCycleScope: { scripts.cycleScope(for: record.name) },
                        onClick: { popupScript = record }
                    )
                }
            }
            .padding(.vertical, 2)
            .animation(.easeInOut(duration: 0.2), value: scripts.scripts)
        }
        .overlay(alignment: .top) {
            if !scripts.isGlobalEnabled {
                pausedBanner
            }
        }
    }

    /// 总开关关闭时悬浮的提示胶囊。
    private var pausedBanner: some View {
        Label("全局已暂停，脚本暂不注入", systemImage: "pause.circle.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.72)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 6)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(scripts.isGlobalEnabled ? "暂无导入的 JS 脚本" : "脚本引擎已暂停")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(scripts.isGlobalEnabled
                 ? "点击右上角「导入」添加 .js 文件\n新脚本默认单开生效"
                 : "打开总开关后按原状态恢复注入")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .lobbyGlassCard(cornerRadius: 12, fillOpacity: 0.04, material: nil)
    }

    private func showImportPanel() {
        // 走 LobbyFilePanel：面板实例按用途复用（每次新建要 100~400ms，
        // 正是「点了没反应」的来源），且已在显示时不会再开第二个。
        LobbyFilePanel.open(Self.importSpec) { urls in
            scripts.importFiles(from: urls)
        }
    }
}

// MARK: - 全局开关磁贴（绿色微光配方，与 iOS 版脚本页磁贴同源）

/// 单枚精简开关行：开启时描边发绿色微光（#22B170），关闭时 offAccent 描边 + 状态词转灰。
struct ScriptGlobalTile: View {
    let icon: String
    let title: String
    let isOn: Bool
    let onHint: String
    let offHint: String
    let offAccent: Color
    let onToggle: () -> Void

    /// 与 iOS 版脚本页磁贴描边同源的成功绿（#22B170）。
    private static let glowGreen = Color(red: 34 / 255.0, green: 177 / 255.0, blue: 112 / 255.0)

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Self.glowGreen : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill((isOn ? Self.glowGreen : Color.white).opacity(isOn ? 0.16 : 0.07))
                )
                .shadow(color: isOn ? Self.glowGreen.opacity(0.45) : .clear, radius: 6, x: 0, y: 0)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? .white : Color.white.opacity(0.82))
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(isOn ? onHint : offHint)
                .font(.system(size: 11))
                .foregroundStyle(isOn ? Self.glowGreen.opacity(0.9) : Color.secondary)
                .lineLimit(1)

            Toggle("", isOn: Binding(
                get: { isOn },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(isOn ? Self.glowGreen : Color.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(isOn ? 0.055 : 0.035))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isOn ? Self.glowGreen.opacity(0.85) : offAccent.opacity(0.55),
                    lineWidth: isOn ? 1.4 : 1
                )
        }
        // 绿色微光：开启态用同色 shadow 打在描边上；关闭态只留常规投影。
        .shadow(color: isOn ? Self.glowGreen.opacity(0.30) : offAccent.opacity(0.10),
                radius: isOn ? 9 : 6, x: 0, y: isOn ? 0 : 4)
        .opacity(isOn ? 1 : 0.88)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .lobbyHoverHighlight(cornerRadius: 10, intensity: 0.05)
    }
}

// MARK: - 脚本卡片（胶囊标签 + 主开关）

/// 脚本列表项：状态胶囊（启用时点击切 单开 ⇄ 单多开）+ 主开关 + 点击弹操作窗。
struct ScriptCard: View {
    let record: ScriptRecord
    let onToggle: (Bool) -> Void
    let onCycleScope: () -> Void
    let onClick: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // 可点击区 = 胶囊标签 + 名称/元信息；弹窗手势只挂这里，
            // 不盖住右侧开关（macOS 上父级 onTapGesture 会拦截 Toggle 点击）。
            HStack(spacing: 10) {
                stateCapsule

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(record.isEnabled ? Color.white : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(metaText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture(perform: onClick)

            Toggle("", isOn: Binding(
                get: { record.isEnabled },
                set: { newValue in onToggle(newValue) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(ScriptCard.glowGreen)
            .help(record.isEnabled ? "关闭 = 禁用此脚本" : "打开 = 按已保存作用域生效")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(record.isEnabled ? 0.055 : 0.03))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    record.isEnabled
                        ? LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.09)],
                                         startPoint: .top, endPoint: .bottom)
                        : LinearGradient(colors: [Color.white.opacity(0.07), Color.white.opacity(0.05)],
                                         startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
        }
        .lobbyHoverHighlight(cornerRadius: 10, intensity: 0.05)
    }

    /// 左侧胶囊标签：状态一目了然，点击即切（禁用态点击不生效）。
    private var stateCapsule: some View {
        Button(action: onCycleScope) {
            Text(record.runState.shortTitle)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(stateColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule(style: .continuous).fill(stateColor.opacity(record.isEnabled ? 0.18 : 0.10)))
                .overlay(Capsule(style: .continuous).strokeBorder(stateColor.opacity(record.isEnabled ? 0.85 : 0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .lobbyHoverHighlight(cornerRadius: 50, intensity: 0.10)
        .disabled(!record.isEnabled)
        .help(record.isEnabled ? "点击切换单开 / 单多开" : "脚本已禁用 · 打开右侧开关后可切环境")
        .accessibilityLabel("脚本状态：\(record.runState.title)")
    }

    private var metaText: String {
        var parts: [String] = []
        if let size = record.size, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        switch record.runState {
        case .singleOnly: parts.append("仅单开")
        case .singleAndMulti: parts.append("单开+多开")
        case .disabled: parts.append("不注入")
        }
        return parts.joined(separator: " · ")
    }

    /// 标签状态颜色：单开生效 = 蓝，单多开生效 = 紫，禁用 = 灰。
    private var stateColor: Color {
        switch record.runState {
        case .singleOnly: return Color(red: 0.16, green: 0.59, blue: 1.0)
        case .singleAndMulti: return Color(red: 0.69, green: 0.39, blue: 0.94)
        case .disabled: return Color(red: 0.56, green: 0.56, blue: 0.60)
        }
    }

    /// 与磁贴同源的成功绿。
    static let glowGreen = Color(red: 34 / 255.0, green: 177 / 255.0, blue: 112 / 255.0)
}

// MARK: - 操作弹窗（sheet：三态 / 删除）

/// 点击脚本卡片弹出的操作窗：单开生效 / 单多开生效 / 禁用 / 删除。
/// 当前状态带 ✓ 标记；删除为红色危险操作，与其余三项视觉隔离。
struct ScriptActionSheet: View {
    @ObservedObject var scripts: ScriptStore
    let record: ScriptRecord
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.cyan)
                Text(record.name)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(record.runState.title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }

            stateOption(.singleOnly, icon: "macwindow", title: "单开生效",
                        detail: "只有单开窗口加载此脚本")
            stateOption(.singleAndMulti, icon: "square.grid.2x2", title: "单多开生效",
                        detail: "单开和多开窗口都加载此脚本")
            stateOption(.disabled, icon: "pause.circle", title: "禁用",
                        detail: "不加载此脚本（保留文件）")

            Button {
                scripts.delete(named: record.name)
                onDismiss()
            } label: {
                Label("删除此脚本", systemImage: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.red.opacity(0.85)))
            }
            .buttonStyle(.plain)
            .lobbyHoverHighlight(cornerRadius: 9, intensity: 0.15)
            .help("从磁盘删除该 .js 文件，不可恢复")

            Text("新导入的脚本默认「单开生效」")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.14)))
    }

    private func stateOption(_ state: ScriptRunState, icon: String, title: String, detail: String) -> some View {
        let isSelected = record.runState == state
        return Button {
            scripts.setRunState(state, for: record.name)
            onDismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.cyan : Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(isSelected ? 0.12 : 0.05))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.cyan)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.08 : 0.04))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(isSelected ? 0.22 : 0.06), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .lobbyHoverHighlight(cornerRadius: 9, intensity: 0.07)
    }
}
