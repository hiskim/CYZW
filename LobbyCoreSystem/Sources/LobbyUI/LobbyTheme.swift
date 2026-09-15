import AppKit
import SwiftUI

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
struct LobbyStatusCapsule: View {
    let text: String
    let tint: Color
    let isSelected: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isSelected ? Color.white : tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? tint.opacity(0.9) : Color.white.opacity(0.05))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isSelected ? Color.white.opacity(0.25) : tint.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: isSelected ? tint.opacity(0.35) : .clear, radius: 6, y: 1)
    }
}
