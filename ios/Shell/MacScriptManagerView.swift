#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 脚本管理器主视图（多开管理器右侧工作区的「脚本」分页）

/// JS 脚本管理页：顶部「双卡片磁贴」全局控制区 + 脚本卡片列表。
/// 配色沿用 macOS 版的深蓝氛围玻璃风（白 5% 填充 + 渐变描边 + 悬停提亮），
/// 总开关开启时绿色微光描边，与 iOS 版脚本页（ios2-script-page.js）的语义一一对应。
struct MacScriptManagerView: View {
    @ObservedObject private var manager = ScriptManager.shared
    /// 当前弹出操作窗口的脚本名（nil = 无弹窗）。
    @State private var popupScriptName: String?

    /// 已启用脚本数（与 iOS 版「已启用 x/y」标题一致）。
    private var enabledCount: Int {
        manager.scripts.filter { $0.isEnabled }.count
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            globalControlTiles
            listHeader

            // 脚本列表：总开关关闭时整列加透明蒙版（Opacity 60%）+「全局已暂停」提示。
            ScrollView {
                LazyVStack(spacing: 10) {
                    if manager.scripts.isEmpty {
                        emptyState
                    } else {
                        ForEach(manager.scripts) { record in
                            ScriptCard(
                                record: record,
                                onToggle: { manager.setEnabled($0, for: record.name) },
                                onCycleScope: { manager.cycleScope(for: record.name) },
                                onClick: { withAnimation(.easeOut(duration: 0.15)) { popupScriptName = record.name } }
                            )
                        }
                    }
                }
                .padding(16)
                .opacity(manager.isGlobalEnabled ? 1 : 0.6)
            }
            .overlay(alignment: .top) {
                if !manager.isGlobalEnabled {
                    pausedBanner
                        .padding(.top, 22)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(canvasGlass)
            .overlay { canvasGlassStroke }
            .shadow(color: .black.opacity(0.38), radius: 24, x: 0, y: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .overlay { popupOverlay }
        .animation(.easeInOut(duration: 0.2), value: manager.isGlobalEnabled)
    }

    // MARK: 头部（304pt 中控台侧栏 · 紧凑布局）

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("JS 脚本管理器")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                importButton
            }
            Text("导入的脚本在登录游戏窗口时注入")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var importButton: some View {
        Button {
            // AppKit NSOpenPanel：SwiftUI .fileImporter 在无边框玻璃窗的深层
            // 子视图里会静默不弹（实测点按钮无反应），NSOpenPanel 任何层级都可靠。
            ScriptImporter.pickAndImport()
        } label: {
            Label("导入脚本", systemImage: "plus")
        }
        .buttonStyle(MacManagerButtonStyle(tint: .cyan))
    }

    // MARK: 顶部全局控制区 · 双卡片磁贴

    private var globalControlTiles: some View {
        // 侧栏窄幅：两枚精简开关行竖排，行尾短状态词代替说明文字。
        VStack(spacing: 10) {
            globalSwitchTile
            multiGateTile
        }
    }

    private var globalSwitchTile: some View {
        GlobalControlTile(
            icon: "chevron.left.forwardslash.chevron.right",
            title: "JS 引擎总开关",
            isOn: manager.isGlobalEnabled,
            onHint: "运行中",
            offHint: "已暂停",
            offAccent: .gray,
            onToggle: { manager.isGlobalEnabled.toggle() }
        )
    }

    private var multiGateTile: some View {
        GlobalControlTile(
            icon: "shield.lefthalf.filled",
            title: "多开全局门禁",
            isOn: manager.isMultiOpenGateEnabled,
            onHint: "多开允许",
            offHint: "多开禁止",
            offAccent: .red,
            onToggle: { manager.isMultiOpenGateEnabled.toggle() }
        )
    }

    // MARK: 列表头

    private var listHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("脚本列表 · 已启用 \(enabledCount)/\(manager.scripts.count)")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if let message = manager.lastMessage {
                // 导入/删除等操作的反馈消息（ScriptManager 写入，短暂显示）。
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            } else {
                Text("点击卡片配置状态")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: 空状态 / 蒙版提示

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("暂无导入的 JS 脚本")
                .font(.system(size: 16, weight: .semibold))
            Text("点击上方「导入脚本」添加 .js 文件，新脚本默认单开生效")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    /// 总开关关闭时悬浮在列表上方的提示胶囊。
    private var pausedBanner: some View {
        Label("全局已暂停，脚本暂不注入", systemImage: "pause.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.72)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 6)
    }

    // MARK: 操作弹窗（点击脚本卡片弹出）

    @ViewBuilder
    private var popupOverlay: some View {
        if let name = popupScriptName,
           let record = manager.scripts.first(where: { $0.name == name }) {
            ZStack {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.15)) { popupScriptName = nil }
                    }
                ScriptActionPopup(
                    record: record,
                    onApplyState: { state in
                        manager.setRunState(state, for: record.name)
                        withAnimation(.easeOut(duration: 0.15)) { popupScriptName = nil }
                    },
                    onDelete: {
                        manager.delete(named: record.name)
                        withAnimation(.easeOut(duration: 0.15)) { popupScriptName = nil }
                    }
                )
                // 窄窗口下与窗缘保持间距，弹窗随 maxWidth 收缩。
                .padding(.horizontal, 20)
            }
            .zIndex(10)
        }
    }

    // MARK: 列表画布玻璃面（与多开矩阵画布同配方）

    private var canvasGlass: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
            AmbientRefractionTint()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.012, green: 0.032, blue: 0.085).opacity(0.42))
        }
    }

    private var canvasGlassStroke: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                LinearGradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0.10), Color.white.opacity(0.07)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1
            )
    }
}

// MARK: - 全局开关行（精简版）

/// 单枚精简开关行（侧栏窄幅）：
/// - 开启：描边发绿色微光（描边 + 同色 shadow），图标高亮，行尾短状态词绿色；
/// - 关闭：offAccent 描边（总开关灰 / 门禁红警示）+ 行尾状态词转灰。
/// 原来说明文字精简为行尾两三个字的状态词（运行中/已暂停、多开允许/多开禁止）。
private struct GlobalControlTile: View {
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
        .hoverHighlight(cornerRadius: 10, intensity: 0.05)
    }
}

// MARK: - 脚本卡片（胶囊标签 + 单主开关）

/// 脚本列表项：
/// - 左侧「胶囊标签」显示当前标签状态（单开生效=蓝 / 单多开生效=紫 / 禁用=灰），
///   启用状态下点击即切 单开 ⇄ 单多开；
/// - 右侧只保留 1 个主开关（关 = 禁用，开 = 按已保存作用域生效）；
/// - 点击卡片其余区域弹出操作窗口（单开生效 / 单多开生效 / 禁用 / 删除）。
private struct ScriptCard: View {
    let record: ScriptRecord
    /// 主开关回调：参数为 SwiftUI Toggle 传回的新状态（true=开，false=关）。
    let onToggle: (Bool) -> Void
    let onCycleScope: () -> Void
    let onClick: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // 可点击区 = 胶囊标签 + 名称/描述。弹窗手势只挂在这里，
            // 不盖住右侧开关（macOS 上父级 onTapGesture 会拦截 Toggle 点击）。
            HStack(spacing: 12) {
                stateCapsule

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(record.isEnabled ? Color.white : Color.secondary)
                        // 统一高度方案：名称换行显示（最多两行）；极端超长时
                        // 轻微缩小字号（最少 85%）兜底，保证名称完整可读。
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(metaText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
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
        // 统一高度：所有卡片固定 66pt——两行名称(32) + 元信息(13) + 间距与
        // 上下边距刚好占满；单行名称的内容垂直居中。列表因此整齐等高，
        // 长名称也不被截断（两行换行 + minimumScaleFactor 兜底）。
        .frame(height: 66)
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
        .hoverHighlight(cornerRadius: 10, intensity: 0.05)
    }

    /// 左侧胶囊标签：状态一目了然，点击即切（禁用态点击不生效，提示先开主开关）。
    /// 用 shortTitle 短文案，给脚本名称让宽度；全称见操作弹窗。
    private var stateCapsule: some View {
        Button(action: onCycleScope) {
            Text(record.runState.shortTitle)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(stateColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule(style: .continuous).fill(stateColor.opacity(record.isEnabled ? 0.18 : 0.10)))
                .overlay(Capsule(style: .continuous).strokeBorder(stateColor.opacity(record.isEnabled ? 0.85 : 0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 50, intensity: 0.10)
        .disabled(!record.isEnabled)
        .help(record.isEnabled ? "点击切换单开 / 单多开" : "脚本已禁用 · 打开右侧开关后可切环境")
        .accessibilityLabel("脚本状态：\(record.runState.title)")
    }

    private var metaText: String {
        var parts: [String] = []
        if let size = record.size, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        // 短文案：侧栏卡片宽度有限，完整描述见操作弹窗。
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

// MARK: - 操作弹窗

/// 点击脚本卡片弹出的操作窗口：单开生效 / 单多开生效 / 禁用 / 删除。
/// 当前状态行带 ✓ 标记；删除为红色危险操作，与其余三项视觉隔离。
private struct ScriptActionPopup: View {
    let record: ScriptRecord
    let onApplyState: (ScriptRunState) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.cyan)
                Text(record.name)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(record.runState.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }

            stateOption(.singleOnly, icon: "macwindow", title: "单开生效",
                        detail: "只有单开窗口加载此脚本")
            stateOption(.singleAndMulti, icon: "square.grid.2x2", title: "单多开生效",
                        detail: "单开和多开窗口都加载此脚本")
            stateOption(.disabled, icon: "pause.circle", title: "禁用",
                        detail: "不加载此脚本（保留文件）")

            Button(action: onDelete) {
                Label("删除此脚本", systemImage: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.red.opacity(0.85)))
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 9, intensity: 0.15)
            .help("从磁盘删除该 .js 文件，不可恢复")

            Text("新导入的脚本默认「单开生效」")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(18)
        // 上限 400pt；窄窗口（~345pt 中控台）随容器收缩，inner 行已用
        // maxWidth: .infinity 拉伸，宽度收缩时布局不破。
        .frame(maxWidth: 400)
        .glassCard(cornerRadius: 14, fillOpacity: 0.07, material: .ultraThin)
    }

    private func stateOption(_ state: ScriptRunState, icon: String, title: String, detail: String) -> some View {
        let isSelected = record.runState == state
        return Button {
            onApplyState(state)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.cyan : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(isSelected ? 0.12 : 0.05))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.cyan)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
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
        .hoverHighlight(cornerRadius: 9, intensity: 0.07)
    }
}

// MARK: - 脚本导入（AppKit 文件选择器）

/// 统一的 .js 导入入口。用 NSOpenPanel 而非 SwiftUI .fileImporter：
/// 无边框（hiddenTitleBar）玻璃窗的深层子视图里，fileImporter 会静默不弹
/// （用户实测点「导入脚本」无任何反应）；NSOpenPanel 是 AppKit 原生面板，
/// 任意宿主层级、任意窗宽下都可靠弹出，且天然支持沙盒下的用户选文件访问。
@MainActor
enum ScriptImporter {
    static func pickAndImport() {
        let panel = NSOpenPanel()
        panel.title = "选择要导入的 JS 脚本"
        panel.message = "可多选 .js 文件；导入后默认「单开生效」"
        panel.allowedContentTypes = [UTType(filenameExtension: "js") ?? .data]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            ScriptManager.shared.importFiles(from: panel.urls)
        }
    }
}
#endif
