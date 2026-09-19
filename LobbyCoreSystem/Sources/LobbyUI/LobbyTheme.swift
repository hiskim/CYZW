import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LobbyDomain

// MARK: - 大厅视觉配方
//
// 毛玻璃六步配方（与上一代大厅同源，全部来自用户反复校准的结论）：
// 01 底层氛围光（深蓝底 + 大径向色斑 + 星场/光束作 blur 证据层）；
// 02 玻璃填充 白 5%（冷蓝白，中性白叠深蓝必显灰）；
// 03 材质分档：侧栏 .thinMaterial ≈ blur 50，卡片 .ultraThin ≈ 28；
// 04 1px 描边（顶亮底暗渐变）做出「厚度」；
// 05 顶边内高光（上亮下暗）；
// 06 外投影把玻璃从背景「抬起」。
// 压暗 / 提亮层必须带蓝相位——纯黑纯白在深蓝氛围上都会读成灰。

extension Color {
    init(lobbyRGB rgb: UInt32) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255.0,
                  green: Double((rgb >> 8) & 0xFF) / 255.0,
                  blue: Double(rgb & 0xFF) / 255.0,
                  opacity: 1)
    }
}

/// 径向色斑：氛围光与折射增压的基本单元。
/// 三段式衰减（实 → 40% → 0）让色斑边缘更奶、雾感更强。
func lobbyGlowBlob(_ rgb: UInt32, _ opacity: Double, _ center: UnitPoint, _ radius: CGFloat) -> some View {
    RadialGradient(
        colors: [Color(lobbyRGB: rgb).opacity(opacity),
                 Color(lobbyRGB: rgb).opacity(opacity * 0.4),
                 Color(lobbyRGB: rgb).opacity(0)],
        center: center,
        startRadius: 0,
        endRadius: radius
    )
}

/// 配方 01 · 底层氛围光。玻璃 = 对背后内容的高斯采样，这层就是被折射的「内容」。
/// 高对比细节层（星场 + 光束）是毛玻璃的「证据」：玻璃外锐利、玻璃内柔化的
/// 同屏对比比单纯的大渐变色斑明显得多。星点用固定种子 LCG 生成，启动间一致。
struct LobbyAmbientGlowBackground: View {
    static let starColors: [Color] = [.white, Color(lobbyRGB: 0x7DD3FC), Color(lobbyRGB: 0x67E8F9)]

    private struct Star {
        let x, y, diameter, opacity: Double
        let colorIndex: Int
    }

    private static let stars: [Star] = {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 11) & 0xFFFF) / Double(0xFFFF)
        }
        var result: [Star] = []
        for i in 0..<46 {
            if i % 9 == 0 {
                // 大颗「虚化光斑」：透过玻璃后是明显的 bokeh 圆盘
                result.append(Star(x: next(), y: next(),
                                   diameter: 14 + next() * 14,
                                   opacity: 0.10 + next() * 0.10,
                                   colorIndex: i % 3))
            } else {
                result.append(Star(x: next(), y: next(),
                                   diameter: 1.2 + next() * 2.4,
                                   opacity: 0.25 + next() * 0.55,
                                   colorIndex: i % 3))
            }
        }
        return result
    }()

    var body: some View {
        ZStack {
            // 渊黑蓝底（94% 近不透明）：壁纸只透 6% 明暗纹理，
            // 壁纸上的灰亮区块不再显形为「灰色团」。
            Color(red: 0.01, green: 0.028, blue: 0.075).opacity(0.94)
            lobbyGlowBlob(0x2563EB, 0.30, UnitPoint(x: 0.14, y: 0.32), 780)
            lobbyGlowBlob(0x1D4ED8, 0.24, UnitPoint(x: 0.55, y: 0.38), 820)
            lobbyGlowBlob(0x1E40AF, 0.22, UnitPoint(x: 0.40, y: 0.04), 500)
            lobbyGlowBlob(0x1E40AF, 0.22, UnitPoint(x: 0.38, y: 0.92), 760)
            lobbyGlowBlob(0x22D3EE, 0.24, UnitPoint(x: 0.95, y: 0.42), 860)
            lobbyGlowBlob(0x3B82F6, 0.22, UnitPoint(x: 0.72, y: 0.02), 660)
            lobbyGlowBlob(0x0EA5E9, 0.14, UnitPoint(x: 0.04, y: 0.96), 520)

            GeometryReader { proxy in
                ZStack {
                    ForEach(Self.stars.indices, id: \.self) { i in
                        let star = Self.stars[i]
                        Circle()
                            .fill(Self.starColors[star.colorIndex].opacity(star.opacity))
                            .frame(width: star.diameter, height: star.diameter)
                            .position(x: star.x * proxy.size.width, y: star.y * proxy.size.height)
                    }
                    // 两道斜向光束：玻璃外是清晰亮带，玻璃内被抹成柔光。
                    LinearGradient(colors: [.clear, Color.white.opacity(0.16), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width * 0.9, height: 2)
                        .rotationEffect(.degrees(-24))
                        .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.30)
                    LinearGradient(colors: [.clear, Color(lobbyRGB: 0x67E8F9).opacity(0.14), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width * 0.7, height: 1.5)
                        .rotationEffect(.degrees(-24))
                        .position(x: proxy.size.width * 0.62, y: proxy.size.height * 0.62)
                }
            }
        }
    }
}

/// 折射增压：把氛围光主色斑低透明度再叠一层到玻璃表面，模拟玻璃对背后
/// 高饱和光源的折射着色。系统材质对窗内内容的采样强度不一，这层保证玻璃
/// 始终吃进颜色。
struct LobbyRefractionTint: View {
    var body: some View {
        ZStack {
            lobbyGlowBlob(0x2563EB, 0.15, UnitPoint(x: 0.10, y: 0.28), 540)
            lobbyGlowBlob(0x1D4ED8, 0.18, UnitPoint(x: 0.55, y: 0.45), 640)
            lobbyGlowBlob(0x22D3EE, 0.13, UnitPoint(x: 1.0, y: 0.45), 560)
            lobbyGlowBlob(0x3B82F6, 0.10, UnitPoint(x: 0.80, y: 0.0), 500)
        }
    }
}

/// 真实毛玻璃底：NSVisualEffectView 以 behindWindow 混合直接折射窗口后的桌面
/// 壁纸——访达侧栏同款，比 SwiftUI Material 明显得多。
/// 强制 darkAqua 外观保证暗色振动，上层再叠品牌深蓝 tint。
struct LobbyVibrancyBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

/// 隐形窗口拖拽区：mouseDownCanMoveWindow=true 时 AppKit 把「按下并拖动」
/// 识别为移动窗口。⚠️ 条带内的 mouseDown 会被 AppKit 消费成拖窗口——
/// 单击不动毫无反馈（「点击黑洞」），**任何交互控件都必须排在条带之外**。
/// mouseDownCanMoveWindow 是只读属性，必须子类化重写。
struct LobbyTitleBarDragRegion: NSViewRepresentable {
    private final class DragRegionView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }

    func makeNSView(context: Context) -> NSView {
        DragRegionView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 配方 02–06 · 卡片级玻璃面：
/// 冷蓝白填充 + ultraThin 材质 + 1px 顶亮底暗描边 + 顶边内高光 + 外投影。
struct LobbyGlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat
    var fillOpacity: Double
    /// nil = 不加材质：小卡片叠在已模糊的面板上时，省一层模糊合成。
    var material: Material? = .ultraThin

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                ZStack {
                    if let material {
                        shape.fill(material)
                    }
                    // 冷蓝白代替中性白：中性白叠在深蓝氛围上必被读成灰。
                    shape.fill(Color(red: 0.55, green: 0.68, blue: 0.90).opacity(fillOpacity))
                }
            )
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.10), Color.white.opacity(0.07)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(0.38), radius: 20, x: 0, y: 18)
    }
}

extension View {
    /// 按六步配方给卡片挂玻璃面；fillOpacity 取 0.04–0.07。
    func lobbyGlassCard(cornerRadius: CGFloat = 12, fillOpacity: Double = 0.05, material: Material? = .ultraThin) -> some View {
        modifier(LobbyGlassCardModifier(cornerRadius: cornerRadius, fillOpacity: fillOpacity, material: material))
    }
}

// MARK: - 悬停高亮（AppKit tracking area 版）

/// 鼠标悬停白色薄高亮。
/// ⚠️ 一律用本实现（AppKit tracking area），**禁止新写 onHover + @State 悬停**——
/// 那条路与点击存在竞态、会吞 mouseDown（表现为按钮要点几次才响应）。
/// 本层永不参与事件命中（hitTest -> nil），悬停状态也不回写 SwiftUI，
/// 点击链路里不存在本层引起的视图重建。
struct LobbyHoverHighlightModifier: ViewModifier {
    var cornerRadius: CGFloat = 6
    var intensity: Double = 0.08

    func body(content: Content) -> some View {
        content
            .overlay(
                LobbyHoverHighlightView.Representable(cornerRadius: cornerRadius, intensity: intensity)
                    .allowsHitTesting(false)
            )
    }
}

private final class LobbyHoverHighlightView: NSView {
    var cornerRadius: CGFloat = 6 {
        didSet {
            guard oldValue != cornerRadius else { return }
            layer?.cornerRadius = cornerRadius
        }
    }
    var intensity: Double = 0.08 {
        didSet {
            guard oldValue != intensity else { return }
            syncHighlight()
        }
    }
    private var isHovering = false {
        didSet {
            guard oldValue != isHovering else { return }
            syncHighlight()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = cornerRadius
        syncHighlight()
        // 重新挂窗（窗口 / 层级变化）时重建 tracking area，避免悬停失效。
        for area in trackingAreas { removeTrackingArea(area) }
        guard window != nil else { return }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    /// 本层不接收任何鼠标事件；tracking area 的 enter/exit 不走 hitTest，
    /// 既能收到悬停、又永远吃不到点击。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    private func syncHighlight() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = NSColor.white
            .withAlphaComponent(isHovering ? intensity : 0)
            .cgColor
        CATransaction.commit()
    }

    struct Representable: NSViewRepresentable {
        var cornerRadius: CGFloat
        var intensity: Double

        func makeNSView(context: Context) -> LobbyHoverHighlightView {
            let view = LobbyHoverHighlightView()
            view.cornerRadius = cornerRadius
            view.intensity = intensity
            return view
        }

        func updateNSView(_ nsView: LobbyHoverHighlightView, context: Context) {
            nsView.cornerRadius = cornerRadius
            nsView.intensity = intensity
        }
    }
}

extension View {
    /// 鼠标悬停时叠加白色薄高亮；胶囊形控件传大圆角（如 50）。
    func lobbyHoverHighlight(cornerRadius: CGFloat = 6, intensity: Double = 0.08) -> some View {
        modifier(LobbyHoverHighlightModifier(cornerRadius: cornerRadius, intensity: intensity))
    }
}

// MARK: - 流式（换行）布局

/// 按可用宽度排布、放不下就换行的流式布局（侧栏胶囊条用）。
///
/// 为什么用 `Layout` 协议而不是自己算行：胶囊宽度由文字决定，字体、动态类型、
/// 本地化都会改变它，只有让 SwiftUI 逐个量出子视图的真实尺寸，换行点才是准的。
///
/// 宽度收紧：单个子视图比容器还宽时，按容器宽度摆放（配合 `lineLimit(1)`
/// 由子视图自己截断），避免又把内容顶到容器右边界外——那正是本布局要修的病。
struct LobbyFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 5
    var verticalSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0
        var totalHeight: CGFloat = 0
        var isRowEmpty = true

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let width = min(size.width, maxWidth)
            if !isRowEmpty, rowWidth + horizontalSpacing + width > maxWidth {
                widestRow = max(widestRow, rowWidth)
                totalHeight += rowHeight + verticalSpacing
                rowWidth = 0
                rowHeight = 0
                isRowEmpty = true
            }
            rowWidth += (isRowEmpty ? 0 : horizontalSpacing) + width
            rowHeight = max(rowHeight, size.height)
            isRowEmpty = false
        }
        return CGSize(width: max(widestRow, rowWidth), height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        var isRowEmpty = true

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let width = min(size.width, maxWidth)
            if !isRowEmpty, x + horizontalSpacing + width > bounds.maxX {
                y += rowHeight + verticalSpacing
                x = bounds.minX
                rowHeight = 0
                isRowEmpty = true
            }
            if !isRowEmpty { x += horizontalSpacing }
            subview.place(at: CGPoint(x: x, y: y),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: size.height))
            x += width
            rowHeight = max(rowHeight, size.height)
            isRowEmpty = false
        }
    }
}

// MARK: - 通用按钮样式

/// 深色玻璃主按钮样式（tint == .white 为「白色玻璃」特殊档：白 16% 填充 + 黑字）。
struct LobbyButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .frame(height: 16, alignment: .center)
            .foregroundStyle(tint == .white ? Color.black : Color.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(tint.opacity(configuration.isPressed ? 0.65 : (tint == .white ? 0.16 : 0.85)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.20)))
            .lobbyHoverHighlight(cornerRadius: 6, intensity: 0.15)
    }
}

/// 状态胶囊：选中 = 实色填充白字 + 微光；未选中 = 白 5% 填充 + 描边同色文字。
///
/// ⚠️ `Text` 必须 `lineLimit(1)` + `fixedSize()`：没有这两条，HStack 空间不足时
/// 胶囊被压缩、文字竖排（「目标帧率」的 15 / 120 曾被拆成 1/5、12/0 两行）。
/// `fillsWidth = true` 用于等宽网格行（如 7 个帧率档均分一行）：内边距收窄、
/// 背景铺满父级分配的格子，所有档位同宽同高，视觉成一条整齐的档位条。
struct LobbyStatusCapsule: View {
    let text: String
    let tint: Color
    let isSelected: Bool
    /// true = 铺满父级提议宽度（等宽网格）；false = 按内容自适应。
    var fillsWidth: Bool = false

    var body: some View {
        // ⚠️ 本 body 必须保持「全拆」写法：每条子表达式 ≤ 2 段链，三元只许出现在
        // 显式类型标注的 let 上。历史上两种写法（12 段原始链、部分拆分）都在
        // Xcode GUI 高负载构建时报 type-check 超时（CLI 同机可过——超时是墙钟
        // 敏感的，机器负载决定成败，改回紧凑写法前先想清楚）。
        let horizontalPadding: CGFloat = fillsWidth ? 5 : 9
        let maxWidth: CGFloat? = fillsWidth ? .infinity : nil
        let font: Font = .system(size: 11, weight: .semibold).monospacedDigit()
        let foreground: Color = isSelected ? Color.white : tint
        let fillColor: Color = isSelected ? tint.opacity(0.9) : Color.white.opacity(0.05)
        let strokeColor: Color = isSelected ? Color.white.opacity(0.25) : tint.opacity(0.45)
        let shadowColor: Color = isSelected ? tint.opacity(0.35) : .clear

        let capsule = Capsule(style: .continuous)

        let content = Text(text)
            .font(font)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .fixedSize()

        let shaped = content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 4)
            .frame(maxWidth: maxWidth)

        let fillShape = capsule.fill(fillColor)
        let strokeShape = capsule.strokeBorder(strokeColor, lineWidth: 1)

        return shaped
            .background(fillShape)
            .overlay(strokeShape)
            .shadow(color: shadowColor, radius: 6, y: 1)
    }
}

// MARK: - 文件选择面板（复用实例）

/// 一次「打开文件选择面板」的配置。
struct LobbyFilePanelSpec {
    /// 用途名 = 缓存键。不同用途各持一个实例，「上次打开的目录」互不干扰。
    var purpose: String
    var title: String
    var message: String
    /// 允许的扩展名（不含点）；空数组 = 不限制类型。
    var extensions: [String]
    var allowsMultipleSelection: Bool
}

/// 文件选择面板（NSOpenPanel）的复用封装。
///
/// ⚠️ **为什么必须复用实例**：实测 `NSOpenPanel()` 每新建一次要 **100~400ms**（首次
/// ≈380ms，之后仍在 100~200ms 徘徊），而且全部发生在主线程——点击「导入」后界面
/// 就死死卡住这么久，表现为「点了没反应，要多点几次才弹出来」。更糟的是旧写法
/// 每次点击都新建，连点会把卡顿叠加、面板叠成一摞。
/// 复用同一个实例后：改配置 ≈0ms、`begin` 到面板可见 5~35ms，点击即时响应
/// （数据来自 `/tmp/panel-cost`、`/tmp/panel-show` 两个探针）。
@MainActor
enum LobbyFilePanel {
    /// 按用途缓存的面板实例（常驻，避免点击路径上的创建开销）。
    private static var cached: [String: NSOpenPanel] = [:]
    /// 正在显示的面板：连点只把它提到最前，不再新建 / 再 begin（避免叠面板）。
    private static var presenting: NSOpenPanel?

    /// 预热：把「首次创建」的几百毫秒挪出点击路径（视图出现后的空闲期调用）。
    static func prepare(_ spec: LobbyFilePanelSpec) {
        Task { @MainActor in _ = panel(for: spec) }
    }

    /// 打开选择面板。`pick` 只在用户点了「打开」时回调（取消 / Esc 不给回调）。
    static func open(_ spec: LobbyFilePanelSpec, pick: @escaping @MainActor ([URL]) -> Void) {
        // ⚠️ 判定必须带 `isVisible`：`presenting` 只是「正在显示」的软标记，一旦某条
        // 路径没走到 completion 它就会永久非空，之后每次点击都拐进这里、什么都不做
        // ——正是「点了永远没反应」的样子。以窗口真实可见性为准才不会把自己锁死。
        if let showing = presenting, showing.isVisible {
            // 同一个用途的面板：只提到最前，不再开第二个。
            if showing === cached[spec.purpose] {
                LobbyLog.info("[panel] %@ 面板已在显示，只提到最前", spec.purpose)
                NSApp.activate(ignoringOtherApps: true)
                showing.makeKeyAndOrderFront(nil)
                return
            }
            // 另一用途的面板还开着：用户已经换了目标，关掉它让位（否则点了像没反应）。
            LobbyLog.info("[panel] %@ 关掉仍在显示的另一用途面板，改开本用途", spec.purpose)
            showing.cancel(nil)
            presenting = nil
            // cancel 的 completion 在下一个 runloop 才到，让位之后再重开一次。
            DispatchQueue.main.async { open(spec, pick: pick) }
            return
        }
        presenting = nil // 上一轮状态脏了就丢掉，别带着往下走。
        let started = CFAbsoluteTimeGetCurrent()
        let isReused = cached[spec.purpose] != nil
        let panel = panel(for: spec)
        presenting = panel
        // 刻意**不用 sheet**：sheet 是模态的，开着的时候整个大厅点不动（选文件时
        // 还想看着大厅 / 顺手切分组）。改成独立窗口 + floating 层级：既保证在最前
        // 看得见，又不锁住大厅。
        NSApp.activate(ignoringOtherApps: true)
        LobbyLog.info("[panel] %@ 打开面板（实例%@，独立窗口）",
                      spec.purpose, isReused ? "复用" : "新建")
        let finish = { (response: NSApplication.ModalResponse) in
            MainActor.assumeIsolated {
                let urls = response == .OK ? panel.urls : []
                let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
                presenting = nil
                LobbyLog.info("[panel] %@ 面板关闭：选中 %d 个，共用 %.0fms",
                              spec.purpose, urls.count, elapsed)
                // 取消 / Esc 不回调：导入侧会在空数组时打出「未选择文件」提示。
                guard response == .OK else { return }
                pick(urls)
            }
        }
        panel.begin { finish($0) }
        // 双保险：begin 之后再顶一次前台（独立窗口偶发停在别的窗口后面）。
        panel.makeKeyAndOrderFront(nil)
        // 兜底诊断：正常路径下 400ms 后面板必然可见；打出来就说明 AppKit 没把面板显示出来。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated {
                guard presenting === panel, !panel.isVisible else { return }
                LobbyLog.warn("[panel] %@ 面板打开后 400ms 仍不可见", spec.purpose)
            }
        }
    }

    @discardableResult
    private static func panel(for spec: LobbyFilePanelSpec) -> NSOpenPanel {
        let panel = cached[spec.purpose] ?? makePanel()
        cached[spec.purpose] = panel
        panel.title = spec.title
        panel.message = spec.message
        panel.allowsMultipleSelection = spec.allowsMultipleSelection
        // 刻意**不**重置 directoryURL：复用时接着用户上次打开的目录，少一次导航。
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if spec.extensions.isEmpty {
            panel.allowedContentTypes = []
        } else {
            let types = spec.extensions.compactMap { UTType(filenameExtension: $0) }
            // 扩展名没登记 UTI 时退回 public.data，与旧写法一致（不让面板变成「全灰不可选」）。
            panel.allowedContentTypes = types.isEmpty ? [.data] : types
        }
        return panel
    }

    private static func makePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        // 浮在普通窗口之上：独立窗口形态下保证一眼可见（不模态，大厅仍可操作）。
        panel.level = .floating
        return panel
    }
}
