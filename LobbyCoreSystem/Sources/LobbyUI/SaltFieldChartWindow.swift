import AppKit
import LobbyDomain
import LobbyEngine
import SwiftUI

// MARK: - 盐场图表窗口管理
//
// 与抓包窗口（`PacketCaptureWindowManager`）同款生命周期：
//   · 打开 = 用户点了实例卡片的盐场按钮（会话模型开轮询 + 确保页面上报开着）；
//   · 关窗（红点）= 自动停轮询（若页面上报是因图表而开的，一并关掉）；
//   · 实例关闭 = 窗口一起关、快照丢弃。
//
// 专为「打盐场悬浮参考」做的三件窗口特性：
//   · **透明度**（alphaValue 0.25...1.0）：半透明盖在实例窗口上看得到游戏画面；
//   · **悬浮置顶**（level .floating）：压在所有普通实例窗口之上；
//   · **鼠标穿透**（ignoresMouseEvents）：开着时点击穿过图表直达下面的游戏窗口
//     ——穿透期间不能拖动/调参，需先回图表窗口关掉（从大厅再点一次盐场按钮前置）。
@MainActor
public final class SaltFieldChartWindowManager: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    /// 每账号一个穿透控制器（窗口开着时才存在；Control 键逃生通道见类型注释）。
    private var passthroughs: [String: SaltFieldPassthroughController] = [:]
    private weak var session: LobbySessionModel?
    /// 新窗口的级联偏移（多开不叠死）。
    private static var cascadeIndex = 0

    public override init() {}

    func attach(session: LobbySessionModel) {
        self.session = session
    }

    /// 视图把穿透开关打到 NSWindow 上（工具栏 Toggle / 窗口偏好恢复的唯一出口）。
    /// `topInteractiveHeight` = 标题栏 + 工具栏实测高度（这部分永不穿透）。
    public func applyPassthrough(_ enabled: Bool, window: NSWindow, accountID: String,
                                 topInteractiveHeight: CGFloat = 28) {
        let controller = passthroughs[accountID] ?? SaltFieldPassthroughController()
        passthroughs[accountID] = controller
        controller.topInteractiveHeight = topInteractiveHeight
        controller.setEnabled(enabled, window: window)
    }

    /// 打开（或前置）账号的盐场图表窗口。
    public func openWindow(for account: GameAccount) {
        if let existing = windows[account.id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let contentRect = NSRect(x: 0, y: 0, width: 1180, height: 780)
        let window = NSWindow(contentRect: contentRect,
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "盐场战况 · \(account.nickname)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 560)
        // 浅色主题（2026-09-18 用户要求白底）：实时地图本来就是白底绘制，
        // 历史战报浅色化后对比度更好；控件随 aqua 自动深字。
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.99, alpha: 1)
        guard let session else {
            LobbyLog.warn("[saltfield] 会话模型未挂接，盐场图表窗口无法创建")
            return
        }
        window.contentView = NSHostingView(rootView: SaltFieldChartWindowView(
            session: session,
            account: account,
            windowRef: WeakWindowRef(window)
        ))
        Self.cascadeIndex += 1
        window.cascadeTopLeft(from: NSPoint(x: 220 + Self.cascadeIndex * 30,
                                            y: 120 + Self.cascadeIndex * 26))
        window.delegate = self
        windows[account.id] = window
        window.makeKeyAndOrderFront(nil)
    }

    /// 关闭并丢弃窗口（实例关闭 / 用户主动关图表时调用）。
    public func closeWindow(forAccountID accountID: String) {
        let window = windows.removeValue(forKey: accountID)
        passthroughs.removeValue(forKey: accountID)?.stop()
        window?.close()
    }

    /// 用户点红点关窗（NSWindowDelegate）：摘除登记 + 回调会话模型收尾。
    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let accountID = windows.first(where: { $0.value === window })?.key else { return }
        windows.removeValue(forKey: accountID)
        passthroughs.removeValue(forKey: accountID)?.stop()
        session?.saltFieldChartWindowDidClose(accountID: accountID)
    }
}

/// 视图侧的窗口弱引用（窗口归管理器所有，视图只读写不持有）。
final class WeakWindowRef {
    private(set) weak var window: NSWindow?
    init(_ window: NSWindow?) { self.window = window }
}

// MARK: - 鼠标穿透控制（区域化豁免 + Control 键兜底）
//
// `ignoresMouseEvents` 是**全窗口**无差别的：穿透一开，关闭按钮/开关/拖动
// 全部点不到——用户会把自己锁在窗口外（实测 2026-09-18）。
//
// 穿透语义（用户确认口径）：**只穿透地图与战况表内容区**，标题栏 + 工具栏
// 始终可交互（拖窗 / 关窗 / 调透明度 / 切布局都不需要任何前置动作）。
// 实现：80ms 轮询 `NSEvent.mouseLocation`（全局坐标，**零权限**——不用 CGEvent tap
// 或全局事件监听，都绕不开辅助功能授权）：
//   · 鼠标在**顶部 chrome 区**（标题栏 + 工具栏，高度由视图实测上报）→ 实体化；
//   · 鼠标在**内容区** → 穿透（开关开着时）；
//   · **按住 Control** → 任意位置临时实体化（兜底：穿透期间要滚动/点选内容区的表格行）。
@MainActor
final class SaltFieldPassthroughController {
    /// 轮询节拍（穿透开启期间）。
    private static let interval: TimeInterval = 0.08

    private var timer: Timer?
    private weak var window: NSWindow?
    /// 穿透开关的期望值（视图 Toggle 的状态；轮询在它为 true 时才工作）。
    private(set) var isEnabled = false
    /// 顶部始终可交互的高度（标准标题栏 ≈28 + 工具栏实测高度；由视图上报）。
    var topInteractiveHeight: CGFloat = 28
    /// 上次应用的穿透状态（只在变化时打诊断日志，避免刷屏）。
    private var lastApplied: Bool?

    /// 应用穿透开关（窗口关闭/开关切换都要走这里，保证 Timer 生命周期正确）。
    func setEnabled(_ enabled: Bool, window: NSWindow) {
        isEnabled = enabled
        self.window = window
        guard enabled else {
            window.ignoresMouseEvents = false
            lastApplied = false
            timer?.invalidate()
            timer = nil
            return
        }
        evaluate()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        // .common = default + eventTracking（拖窗/按住鼠标时轮询不中断）。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 窗口关闭（红点 / 实例关闭）：停轮询并还原（窗口对象由管理器释放）。
    func stop() {
        timer?.invalidate()
        timer = nil
        window = nil
        isEnabled = false
        lastApplied = nil
    }

    /// 顶部 chrome / 按住 Control → 实体化；其余区域 → 穿透（若开关开着）。
    /// 状态切换时打一条诊断日志（豁免高度 / 鼠标 / 窗口 frame——排查「工具栏还穿透」用）。
    private func evaluate() {
        guard let window, isEnabled else { return }
        let frame = window.frame
        let mouse = NSEvent.mouseLocation
        guard frame.contains(mouse) else {
            applyState(true, mouse: mouse, frame: frame)
            return
        }
        // 全局坐标 y 向上：顶部 chrome 区 = 窗口顶边往下 topInteractiveHeight。
        let interactiveTop = NSRect(x: frame.minX, y: frame.maxY - topInteractiveHeight,
                                    width: frame.width, height: topInteractiveHeight)
        let overChrome = interactiveTop.contains(mouse)
        let controlHeld = NSEvent.modifierFlags.contains(.control)
        applyState(!(overChrome || controlHeld), mouse: mouse, frame: frame)
    }

    private func applyState(_ passThrough: Bool, mouse: CGPoint, frame: NSRect) {
        guard let window, window.ignoresMouseEvents != passThrough else { return }
        window.ignoresMouseEvents = passThrough
        LobbyLog.info("[saltfield-pass] 穿透=%@ 豁免高=%.0f 鼠标=(%.0f,%.0f) 窗口=(%.0f,%.0f %.0f×%.0f)",
                      passThrough ? "on" : "off", topInteractiveHeight,
                      mouse.x, mouse.y, frame.minX, frame.minY, frame.width, frame.height)
    }
}

// MARK: - 颜色转换（UI 层；引擎层模型只带 CSS 字面量）

extension SaltColorPalette {
    /// CSS 颜色字面量 → SwiftUI Color（#RRGGBB / #RRGGBBAA / typeBg 具名色子集）。
    static func color(_ literal: String) -> Color {
        if let rgb = hexRGBA(literal) { return rgb }
        switch literal {
        case "orange": return Color(red: 1.0, green: 0.65, blue: 0.15)
        case "yellow": return Color(red: 1.0, green: 0.92, blue: 0.25)
        case "gray": return Color(red: 0.55, green: 0.55, blue: 0.58)
        case "red": return Color(red: 0.92, green: 0.28, blue: 0.24)
        case "green": return Color(red: 0.30, green: 0.78, blue: 0.42)
        default: return Color(red: 0.25, green: 0.25, blue: 0.28)
        }
    }

    private static func hexRGBA(_ text: String) -> Color? {
        guard text.hasPrefix("#") else { return nil }
        let hex = text.dropFirst()
        guard hex.count == 6 || hex.count == 8,
              let value = UInt64(hex, radix: 16) else { return nil }
        if hex.count == 6 {
            return Color(red: Double((value >> 16) & 0xFF) / 255.0,
                         green: Double((value >> 8) & 0xFF) / 255.0,
                         blue: Double(value & 0xFF) / 255.0)
        }
        return Color(red: Double((value >> 24) & 0xFF) / 255.0,
                     green: Double((value >> 16) & 0xFF) / 255.0,
                     blue: Double((value >> 8) & 0xFF) / 255.0,
                     opacity: Double(value & 0xFF) / 255.0)
    }
}

// MARK: - 盐场图表窗口视图

struct SaltFieldChartWindowView: View {
    /// 布局模式：占领布局（连通路径染色）/ 分布置（只亮大本营）。
    enum MapLayout: Int, CaseIterable, Identifiable {
        case occupy, distribution
        var id: Int { rawValue }
        var label: String { self == .occupy ? "占领布局" : "分布布局" }
    }

    /// 战况表：俱乐部 / 个人。
    enum StatMode: Int, CaseIterable, Identifiable {
        case legion, member
        var id: Int { rawValue }
        var label: String { self == .legion ? "俱乐部战况" : "个人战况" }
    }

    /// 窗口模式：实时战况（盐场连接轮询）/ 历史战绩（主连接按日期查总榜）。
    enum WindowMode: Int, CaseIterable, Identifiable {
        case live, history
        var id: Int { rawValue }
        var label: String { self == .live ? "实时战况" : "历史战绩" }
    }

    // ── 窗口偏好（UserDefaults 持久化，跨会话记住手感）──
    private static let opacityKey = "salt.chart.opacity"
    private static let floatingKey = "salt.chart.floating"
    private static let clickThroughKey = "salt.chart.clickThrough"

    @ObservedObject var session: LobbySessionModel
    let account: GameAccount
    /// 宿主窗口弱引用（透明度 / 置顶 / 穿透直接打到 NSWindow 上）。
    let windowRef: WeakWindowRef

    @ObservedObject private var controller: SaltFieldChartController

    @State private var mode: WindowMode = .live
    @State private var layout: MapLayout = .occupy
    @State private var statMode: StatMode = .legion
    @State private var opacity: Double = UserDefaults.standard.object(forKey: Self.opacityKey) as? Double ?? 0.92
    @State private var floating = UserDefaults.standard.bool(forKey: Self.floatingKey)
    @State private var clickThrough = UserDefaults.standard.bool(forKey: Self.clickThroughKey)
    /// 工具栏实测高度（穿透时顶部豁免区 = 标题栏 + 这个值）。
    @State private var toolbarHeight: CGFloat = 0

    init(session: LobbySessionModel, account: GameAccount, windowRef: WeakWindowRef) {
        self.session = session
        self.account = account
        self.windowRef = windowRef
        _controller = ObservedObject(wrappedValue: session.saltField)
    }

    /// 穿透豁免区高度 = 标准标题栏（≈28）+ 工具栏高度（实测；上报失败按 44 保底，
    /// 宁可豁免区略大——工具栏多点一下没事，穿透失败会被用户感知为「开关失效」）。
    private var topInteractiveHeight: CGFloat { 28 + max(toolbarHeight, 44) }

    private var snapshot: SaltFieldSnapshot? { controller.snapshots[account.id] }
    private var isPolling: Bool { controller.pollingAccountIDs.contains(account.id) }
    private var warActive: Bool { controller.warActiveAccountIDs.contains(account.id) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .background(Color(nsColor: NSColor(calibratedWhite: 0.99, alpha: 1)))
        .preferredColorScheme(.light)
        .onAppear(perform: applyWindowSettings)
    }

    // MARK: 工具栏（模式切换 + 按模式的控件组）

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $mode) {
                ForEach(WindowMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .onChange(of: mode) { _, newMode in
                // 历史模式的日历/榜单需要正常交互，穿透自动关掉（回实时模式可再开）。
                if newMode == .history, clickThrough {
                    clickThrough = false
                }
            }
            .help("实时战况 = 盐场连接轮询（需游戏内进战场）；历史战绩 = 主连接按日期查任意场次总榜")
            switch mode {
            case .live:
                liveToolbarControls
            case .history:
                historyToolbarControls
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // 工具栏实测高度 → 穿透豁免区（macOS 15 onGeometryChange；实测失败时
        // 豁免高度有 44pt 保底，见 topInteractiveHeight）。
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            guard abs(height - toolbarHeight) > 0.5 else { return }
            toolbarHeight = height
            applyWindowSettings()
        }
    }

    /// 实时战况的工具栏控件（原口径）。
    @ViewBuilder
    private var liveToolbarControls: some View {
        statusView
        Spacer(minLength: 6)
        Toggle("轮询", isOn: Binding(
            get: { isPolling },
            set: { session.setSaltFieldPolling($0, account: account) }
        ))
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
        .help("每 4 秒向盐场连接自动拉取一次战场信息")
        Picker("", selection: $layout) {
            ForEach(MapLayout.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 168)
        .help("占领布局 = 俱乐部占领区连通染色；分布布局 = 只亮各大本营位置")
        Picker("", selection: $statMode) {
            ForEach(StatMode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 168)
        Button {
            session.refreshSaltFieldNow(account: account)
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain)
        .help("立即拉取一次")
        Divider().frame(height: 16)
        Toggle("置顶", isOn: $floating)
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            .onChange(of: floating) { _, _ in applyWindowSettings() }
            .help("窗口悬浮在所有实例窗口之上")
        Toggle("穿透", isOn: $clickThrough)
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            .onChange(of: clickThrough) { _, _ in applyWindowSettings() }
            .help("开启后仅地图与战况表区域穿透（点击直达下层游戏窗口）；\n标题栏与本工具栏始终可正常拖动/点击；\n按住 Control 可临时点击穿透中的内容区（如滚动表格）")
        Text("透明")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        Slider(value: $opacity, in: 0.25...1.0)
            .frame(width: 110)
            .onChange(of: opacity) { _, _ in applyWindowSettings() }
            .help("窗口透明度：低透明度悬浮在实例上不挡操作")
        Text("\(Int(opacity * 100))%")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 34)
    }

    /// 历史战绩的工具栏控件（月份导航 + 状态 + 拉取场次）。
    @ViewBuilder
    private var historyToolbarControls: some View {
        Text(controller.historyStatus[account.id] ?? "选择右侧日历中的盐场日期查询当场总榜")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        Spacer(minLength: 6)
        Button {
            controller.fetchHistoryBattles(accountID: account.id)
        } label: {
            HStack(spacing: 3) {
                if controller.historyBusy.contains(account.id) {
                    ProgressView().controlSize(.mini)
                }
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                Text("我的场次")
                    .font(.system(size: 11))
            }
        }
        .buttonStyle(.plain)
        .disabled(controller.historyBusy.contains(account.id))
        .help("拉取本账号的盐场历史场次（legion_getinfo），日历上会标注我方名次")
    }

    /// 连接/轮询状态（一眼定性「没数据」是哪一环）。
    private var statusView: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        if isPolling, snapshot != nil { return .green }
        if warActive { return .yellow }
        return .gray
    }

    private var statusText: String {
        if let snapshot {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let updated = formatter.string(from: Date(timeIntervalSince1970: snapshot.timestampMs / 1000))
            let mode = isPolling ? "轮询中" : "手动"
            return "\(mode) · \(updated) 更新"
        }
        if warActive { return "已检测到盐场连接，等待战场数据…" }
        return "未检测到盐场连接（请在游戏内进入盐场战场）"
    }

    // MARK: 内容（按窗口模式：实时 / 历史）

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .live:
            liveContent
        case .history:
            SaltHistoryView(session: session, account: account)
                .id(account.id)
        }
    }

    @ViewBuilder
    private var liveContent: some View {
        if let snapshot {
            HStack(spacing: 0) {
                SaltFieldMapView(snapshot: snapshot,
                                 layout: layout,
                                 legionNameByID: Dictionary(uniqueKeysWithValues:
                                    snapshot.legions.map { ($0.id, $0.name) }))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                SaltFieldStatView(snapshot: snapshot,
                                  mode: statMode)
                    .frame(width: 430)
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "map")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
            Text("暂无战场数据")
                .font(.headline)
            Text("确认该实例已运行并进入游戏内的盐场战场界面；\n检测到盐场连接后图表会自动开始拉取。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 把工具栏设置应用到 NSWindow（透明度 / 置顶 / 穿透），并持久化。
    private func applyWindowSettings() {
        UserDefaults.standard.set(opacity, forKey: Self.opacityKey)
        UserDefaults.standard.set(floating, forKey: Self.floatingKey)
        UserDefaults.standard.set(clickThrough, forKey: Self.clickThroughKey)
        guard let window = windowRef.window else { return }
        window.alphaValue = opacity
        window.level = floating ? .floating : .normal
        // 穿透走管理器的控制器：标题栏/工具栏永不穿透，内容区穿透、Control 兜底
        // （见 SaltFieldPassthroughController——直接设 ignoresMouseEvents 会锁死窗口）。
        session.saltFieldWindows.applyPassthrough(clickThrough, window: window,
                                                  accountID: account.id,
                                                  topInteractiveHeight: topInteractiveHeight)
    }
}

// MARK: - 地图视图（六边形 Canvas）

/// 盐场六边形地图（口径照抄自助手仓 LegionWar.vue 的绘制参数）：
/// 错列六边形（odd-q），hexSize 13.25 / gap 2.75，41 列 × 32 行，整体自适应缩放。
struct SaltFieldMapView: View {
    let snapshot: SaltFieldSnapshot
    let layout: SaltFieldChartWindowView.MapLayout
    let legionNameByID: [Int64: String]

    private let hexSize: CGFloat = 13.25
    private let gap: CGFloat = 2.75
    private var hexHeight: CGFloat { sqrt(3) * hexSize }

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                draw(context: &context, size: size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// 列 x 的中心横坐标。
    private func centerX(_ col: Int) -> CGFloat {
        CGFloat(col) * (hexSize * 1.5 + gap) + hexSize
    }

    /// 列 x 行 y 的中心纵坐标（奇数列下错半格）。
    private func centerY(_ row: Int, col: Int) -> CGFloat {
        CGFloat(row) * (hexHeight + gap) + hexSize + (col % 2 == 1 ? hexHeight / 2 : 0)
    }

    private var mapSize: CGSize {
        CGSize(width: centerX(40) + hexSize + gap,
               height: centerY(31, col: 0) + hexHeight + gap)
    }

    /// 节点的最终染色：占领布局用快照染好的 colorHex；分布布局只有大本营亮俱乐部色，
    /// 其余统一道路蓝（照抄自助手仓的分布布局口径）。
    private func color(of node: SaltRenderedNode) -> Color {
        if layout == .occupy {
            return SaltColorPalette.color(node.colorHex)
        }
        if node.isStronghold, node.belongsLegionID != nil {
            return SaltColorPalette.color(node.colorHex)
        }
        return SaltColorPalette.color(SaltColorPalette.typeColor(9))
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let map = mapSize
        let scale = min(size.width / map.width, size.height / map.height, 1.6)
        let offsetX = max(0, (size.width - map.width * scale) / 2)
        let offsetY = max(0, (size.height - map.height * scale) / 2)

        var labels: [(CGPoint, String, Color)] = []
        for node in snapshot.nodes.values {
            let center = CGPoint(x: offsetX + centerX(node.x) * scale,
                                 y: offsetY + centerY(node.y, col: node.x) * scale)
            let radius = hexSize * scale
            var path = Path()
            for corner in 0..<6 {
                let angle = CGFloat(corner) * .pi / 3
                let point = CGPoint(x: center.x + radius * cos(angle),
                                    y: center.y + radius * sin(angle))
                if corner == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            let fill = color(of: node)
            context.fill(path, with: .color(fill))
            context.stroke(path, with: .color(.black.opacity(0.22)), lineWidth: 0.6)

            // 标注：大本营 → 俱乐部名；据点 → 分值短名。
            if node.isStronghold, let legionID = node.belongsLegionID,
               let name = legionNameByID[legionID] {
                labels.append((center, name, .black))
            } else if !node.isRoad {
                labels.append((center, node.typeName, .black.opacity(0.85)))
            }
        }
        let fontSize = max(6.5, 11 * scale)
        for (center, text, tint) in labels {
            context.draw(Text(text)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(tint),
                at: center)
        }
    }
}

// MARK: - 战况表

/// 右侧战况表：俱乐部模式（9 列）或个人模式（10 列，全部成员按击杀排序）。
struct SaltFieldStatView: View {
    let snapshot: SaltFieldSnapshot
    let mode: SaltFieldChartWindowView.StatMode

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                switch mode {
                case .legion: legionTable
                case .member: memberTable
                }
            }
            .padding(8)
        }
    }

    // MARK: 俱乐部表

    private var legionTable: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                statHeader("俱乐部", width: 96)
                statHeader("击杀", width: 44)
                statHeader("免费复活", width: 56)
                statHeader("积分", width: 56)
                statHeader("红数", width: 40)
                statHeader("战力", width: 62)
                statHeader("人数", width: 46)
                statHeader("丹", width: 40)
                statHeader("四圣", width: 60)
            }
            ForEach(snapshot.legions) { legion in
                GridRow {
                    statCell(legion.name, width: 96, bold: true)
                    statCell("\(legion.killCount)", width: 44)
                    statCell("\(legion.reviveCount)/150", width: 56)
                    statCell("\(legion.score)", width: 56, bold: true)
                    statCell("\(legion.redCount)", width: 40,
                             tint: legion.redCount > 0 ? .red : nil)
                    statCell(powerText(legion.power), width: 62)
                    statCell("\(legion.participantsCount)/\(legion.memberCount)", width: 46)
                    statCell("\(legion.danCount)", width: 40)
                    statCell("\(legion.blessingCount)·\(legion.blessingScore)", width: 60)
                }
                .background(rowTint(colorIndex: legion.colorIndex))
            }
        }
    }

    // MARK: 个人表

    private var memberTable: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                statHeader("名称", width: 86)
                statHeader("俱乐部", width: 86)
                statHeader("击杀", width: 40)
                statHeader("死亡", width: 40)
                statHeader("复活", width: 40)
                statHeader("积分", width: 46)
                statHeader("刨地", width: 40)
                statHeader("丹", width: 36)
                statHeader("K/D", width: 44)
                statHeader("状态", width: 40)
            }
            ForEach(snapshot.members) { member in
                GridRow {
                    statCell(member.name, width: 86, bold: true)
                    statCell(legionName(member.legionID), width: 86)
                    statCell("\(member.kill)", width: 40)
                    statCell("\(member.die)", width: 40)
                    statCell("\(member.revive)/5", width: 40)
                    statCell("\(member.point)", width: 46)
                    statCell("\(member.digGround)", width: 40)
                    statCell("\(member.dan)", width: 36)
                    statCell(member.kdText, width: 44)
                    statCell(member.stateText, width: 40,
                             tint: member.state == "over" ? .red : .green)
                }
                .background(rowTint(colorIndex: colorIndex(byLegionID: member.legionID)))
            }
        }
    }

    private func legionName(_ id: Int64) -> String {
        snapshot.legions.first(where: { $0.id == id })?.name ?? "?"
    }

    private func colorIndex(byLegionID id: Int64) -> Int {
        snapshot.legions.first(where: { $0.id == id })?.colorIndex ?? 7
    }

    private func powerText(_ power: Int64) -> String {
        if power >= 100_000_000 { return String(format: "%.2f亿", Double(power) / 100_000_000) }
        if power >= 10_000 { return String(format: "%.1f万", Double(power) / 10_000) }
        return "\(power)"
    }

    private func rowTint(colorIndex: Int) -> Color {
        SaltColorPalette.color(SaltColorPalette.legionColor(colorIndex))
            .opacity(0.55)
    }

    // MARK: 单元格（浅色主题）

    private func statHeader(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: width, height: 24, alignment: .leading)
            .padding(.horizontal, 4)
            .background(Color.black.opacity(0.05))
    }

    private func statCell(_ value: String, width: CGFloat,
                          bold: Bool = false, tint: Color? = nil) -> some View {
        Text(value)
            .font(.system(size: 11, weight: bold ? .semibold : .regular, design: .monospaced))
            .foregroundStyle(tint ?? .primary.opacity(0.85))
            .lineLimit(1)
            .frame(width: width, height: 22, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

// MARK: - 历史战绩视图（月历 + 指定日期总榜）
//
// 数据全部走主连接（`legion_getinfo` / `saltroad_getwartype` /
// `saltroad_getsaltroadwartotalrank`），盐场没开放时也能查——这正是它存在的意义：
// 盐场只在周六 20:00 与月赛日开放，平时想复盘只能查历史。
//
// 交互：日历上**盐场日**（前四周周六 + 第 4 周周日）可点击 → 查询当场总榜；
// 已拉取「我的场次」的日期会标注我方名次（金/银/铜/普通色）。

struct SaltHistoryView: View {
    @ObservedObject private var controller: SaltFieldChartController
    let account: GameAccount

    /// 当前显示的月份（取该月任意一天代表）。
    @State private var month: Date = Date()
    /// 选中的场次日期（点日历设置，触发查询）。
    @State private var selectedDate: Date?
    /// 明细表排序（点表头切换；默认击杀降序）。
    @State private var sortKey: HistorySortKey = .kill
    @State private var sortAscending = false

    init(session: LobbySessionModel, account: GameAccount) {
        _controller = ObservedObject(wrappedValue: session.saltField)
        self.account = account
    }

    private var battles: [SaltHistoryBattle] { controller.historyBattles[account.id] ?? [] }
    private var isBusy: Bool { controller.historyBusy.contains(account.id) }
    private var statusText: String { controller.historyStatus[account.id] ?? "" }

    /// 当前月的我方场次。
    private var battlesOfMonth: [SaltHistoryBattle] {
        battles.filter { isSameMonth($0.date, month) }
    }

    /// 当前月的盐场日。
    private var saltDatesOfMonth: [Date] {
        SaltHistoryCatalog.saltDates(in: month).filter { isSameMonth($0, month) }
    }

    private func battle(on date: Date) -> SaltHistoryBattle? {
        battlesOfMonth.first { SaltHistoryCatalog.isSameDay($0.date, date) }
    }

    private func isSaltDay(_ date: Date) -> Bool {
        saltDatesOfMonth.contains { SaltHistoryCatalog.isSameDay($0, date) }
    }

    /// 同月判断（日历过滤用；isSameDay 只对同一天成立，语义不同）。
    private func isSameMonth(_ lhs: Date, _ rhs: Date) -> Bool {
        Calendar.current.dateComponents([.year, .month], from: lhs)
            == Calendar.current.dateComponents([.year, .month], from: rhs)
    }

    var body: some View {
        VStack(spacing: 0) {
            monthNavigator
            Divider()
            HStack(spacing: 0) {
                calendarView
                    .frame(width: 330)
                    .padding(8)
                Divider()
                rankView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            // 窗口切到历史模式自动拉一次我方场次（幂等：已有数据也刷新）。
            controller.fetchHistoryBattles(accountID: account.id)
            // 默认选中「离当前时间最近的盐场日」（今天若正好是盐场日则选今天，
            // 否则选上一个周六/月赛日，可能落在上月）并自动查询。
            if selectedDate == nil {
                let calendar = Calendar.current
                let today = calendar.startOfDay(for: Date())
                let lastMonth = calendar.date(byAdding: .month, value: -1, to: month) ?? month
                let candidates = (SaltHistoryCatalog.saltDates(in: lastMonth)
                    + SaltHistoryCatalog.saltDates(in: month))
                    .map { calendar.startOfDay(for: $0) }
                    .filter { $0 <= today }
                if let latest = candidates.max() {
                    selectedDate = latest
                    controller.requestWarDetails(accountID: account.id, battleDate: latest)
                }
            }
        }
    }

    // MARK: 月份导航

    private var monthNavigator: some View {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月"
        return HStack(spacing: 8) {
            Button {
                month = Calendar.current.date(byAdding: .month, value: -1, to: month) ?? month
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("上一月")
            Text(formatter.string(from: month))
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 90)
            Button {
                month = Calendar.current.date(byAdding: .month, value: 1, to: month) ?? month
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("下一月")
            Text("周六＝周赛 · 第 4 周周日＝月赛")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: 月历（行式显式构建）
    //
    // ⚠️ 不用 LazyVGrid + 多 ForEach 混排：实测（2026-09-18）占位与日期两个
    // ForEach 在 LazyVGrid 里渲染不完整（第一周 1-6 号整段缺失，id 去重修复无效），
    // 改为按「行」显式组装 HStack——结构完全确定，1 号必然在第 leading+1 列。

    private var calendarView: some View {
        VStack(spacing: 6) {
            calendarHeader
            calendarGrid
            if statusText.isEmpty {
                Text("点击任意日期查询该日盐场战绩；周六（盐场日）高亮")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(isBusy ? .orange : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// 星期表头：跟随系统「每周第一天」设置旋转（与网格 leading 同口径）。
    private var calendarHeader: some View {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        let ordered = (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
        return HStack(spacing: 4) {
            ForEach(ordered, id: \.self) { symbol in
                Text(symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// 网格：显式按「行」构建（每行 7 格，前 leading 格为占位）。
    private var calendarGrid: some View {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: month)
        let first = calendar.date(from: DateComponents(year: components.year,
                                                       month: components.month, day: 1)) ?? month
        let daysInMonth = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        let leading = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let dates: [Date?] = Array(repeating: nil, count: leading)
            + (1...daysInMonth).map { day in
                calendar.date(from: DateComponents(year: components.year,
                                                   month: components.month, day: day)) ?? first
            }
        let rows = stride(from: 0, to: dates.count, by: 7).map {
            Array(dates[$0..<min($0 + 7, dates.count)])
        }
        return VStack(spacing: 4) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { column in
                        if column < rows[rowIndex].count, let date = rows[rowIndex][column] {
                            dayCell(date: date)
                        } else {
                            Color.clear.frame(height: 34)
                        }
                    }
                }
            }
        }
    }

    /// 日历格（浅色）：所有日期可点（盐场日高亮，其他日期服务端无数据会有提示）；
    /// 有我方场次的标注名次。
    private func dayCell(date: Date) -> some View {
        let battle = battle(on: date)
        let isSelected = selectedDate.map({ SaltHistoryCatalog.isSameDay($0, date) }) ?? false
        let salt = isSaltDay(date)
        let dayNumber = Calendar.current.component(.day, from: date)

        return Button {
            selectedDate = date
            controller.requestWarDetails(accountID: account.id, battleDate: date)
        } label: {
            VStack(spacing: 1) {
                Text("\(dayNumber)")
                    .font(.system(size: 11, weight: salt ? .bold : .regular))
                    .foregroundStyle(salt ? Color(red: 0.10, green: 0.26, blue: 0.20)
                                          : Color.primary.opacity(0.55))
                if let battle {
                    Text(battle.rank > 0 ? "第\(battle.rank)名" : battle.warTypeName)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(rankColor(battle.rank))
                } else if salt {
                    Text("盐场")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color(red: 0.10, green: 0.26, blue: 0.20).opacity(0.75))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(cellBackground(isSaltDay: salt,
                                       battle: battle, isSelected: isSelected))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(salt ? Color(red: 0.10, green: 0.26, blue: 0.20).opacity(0.35)
                                       : Color.clear,
                                  lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("点击查询 \(dayNumber) 日盐场战绩" + (salt ? "（盐场日）" : ""))
    }

    private func cellBackground(isSaltDay: Bool,
                                battle: SaltHistoryBattle?, isSelected: Bool) -> Color {
        if isSelected { return Color(red: 0.10, green: 0.26, blue: 0.20).opacity(0.18) }
        if isSaltDay { return Color(red: 0.10, green: 0.26, blue: 0.20).opacity(0.10) }
        if battle != nil { return Color.black.opacity(0.05) }
        return Color.black.opacity(0.015)
    }

    /// 我方名次徽标配色。
    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return .orange
        case 2: return Color(red: 0.42, green: 0.45, blue: 0.50)
        case 3: return Color(red: 0.72, green: 0.45, blue: 0.20)
        case 4...20: return Color(red: 0.10, green: 0.26, blue: 0.20)
        default: return .secondary
        }
    }

    // MARK: 榜单表

    /// 场次日期短格式（榜单表头）。
    private static let battleDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    @ViewBuilder
    private var rankView: some View {
        if let result = controller.historyDetails[account.id] {
            VStack(spacing: 0) {
                // 上栏一：总览卡（总击杀 / 总死亡 / 总攻城 / 平均 K.D）。
                overviewCards(result)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                // 上栏二：四个 TOP3 榜单。
                topPodiums(result)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                Divider()
                // 底部：全部成员明细（可点表头排序；默认击杀降序）。
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            rankHeader("#", width: 40, alignment: .center)
                            // 成员列弹性拉伸，让明细表与上栏榜单卡同宽（下限 520）。
                            Text("成员")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary.opacity(0.75))
                                .frame(minWidth: 122, maxWidth: .infinity, alignment: .leading)
                                .frame(height: 24)
                                .padding(.horizontal, 4)
                                .background(Color.black.opacity(0.05))
                            sortableHeader("攻城", key: .siege, width: 72)
                            sortableHeader("击杀", key: .kill, width: 60)
                            sortableHeader("死亡", key: .death, width: 60)
                            sortableHeader("K/D", key: .kd, width: 62)
                            sortableHeader("总积分", key: .score, width: 70)
                        }
                        .frame(minWidth: 520, maxWidth: .infinity, alignment: .leading)
                        let maxBuilding = result.rows.map(\.building).max() ?? 0
                        ForEach(Array(sortedRows(result.rows).enumerated()), id: \.element.id) { index, row in
                            warDetailRow(index: index, row: row, maxBuilding: maxBuilding)
                        }
                    }
                    .padding(8)
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 36))
                    .foregroundStyle(.quaternary)
                Text("选择左侧日历中的盐场日期")
                    .font(.headline)
                Text("点击带底色的日期即可查询该场盐场的成员战绩（击杀/死亡/攻城/K.D）；\n日历上的名次徽标来自「我的场次」拉取结果。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 上栏 · 四个 TOP3 榜单（击杀 / 攻城 / K.D / 积分）

    /// 排序键（明细表点表头切换；默认击杀降序）。
    enum HistorySortKey: String, CaseIterable {
        case kill, death, siege, kd, score
        var label: String {
            switch self {
            case .kill: return "击杀"
            case .death: return "死亡"
            case .siege: return "攻城"
            case .kd: return "K/D"
            case .score: return "总积分"
            }
        }
    }

    private func sortedRows(_ rows: [SaltWarDetailRow]) -> [SaltWarDetailRow] {
        let key: (SaltWarDetailRow) -> Double = { row in
            switch sortKey {
            case .kill: return Double(row.win)
            case .death: return Double(row.lose)
            case .siege: return Double(row.building)
            case .kd: return row.kd
            case .score: return Double(row.score)
            }
        }
        return rows.sorted { sortAscending ? key($0) < key($1) : key($0) > key($1) }
    }

    /// 可排序表头：点击按该列降序，再点同列切换升序；当前排序列带箭头高亮。
    private func sortableHeader(_ title: String, key: HistorySortKey, width: CGFloat) -> some View {
        Button {
            if sortKey == key {
                sortAscending.toggle()
            } else {
                sortKey = key
                sortAscending = false
            }
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if sortKey == key {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .font(.system(size: 11, weight: sortKey == key ? .bold : .semibold))
            .foregroundStyle(sortKey == key ? Color(red: 0.10, green: 0.26, blue: 0.20) : .primary.opacity(0.75))
            .frame(width: width, height: 24, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.black.opacity(0.05))
    }

    /// 总览卡（标题在上、数字在下，按指标着色）：
    /// 总击杀=绿 · 总死亡=红 · 总攻城=橙 · 平均 K/D=紫 · 总积分=蓝。
    private func overviewCards(_ result: SaltWarDetailsResult) -> some View {
        let totalScore = result.rows.reduce(0) { $0 + $1.score }
        return HStack(spacing: 8) {
            overviewCard(label: "总击杀", tint: Color(red: 0.10, green: 0.42, blue: 0.29),
                         icon: "scope", value: "\(result.totalKill)")
            overviewCard(label: "总死亡", tint: Color(red: 0.80, green: 0.20, blue: 0.16),
                         icon: "shield.slash.fill", value: "\(result.totalDeath)")
            overviewCard(label: "总攻城", tint: Color(red: 0.85, green: 0.47, blue: 0.02),
                         icon: "building.castle.fill", value: "\(result.totalBuilding)")
            overviewCard(label: "平均 K/D", tint: Color(red: 0.49, green: 0.23, blue: 0.93),
                         icon: "divide", value: result.overallKDText)
            overviewCard(label: "总积分", tint: Color(red: 0.15, green: 0.39, blue: 0.92),
                         icon: "star.fill", value: "\(totalScore)")
        }
    }

    /// 紧凑总览卡：标题（着色）在上、大数字（同色）在下。
    private func overviewCard(label: String, tint: Color, icon: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(tint.opacity(0.22)))
    }

    private func topPodiums(_ result: SaltWarDetailsResult) -> some View {
        let killTop3 = result.rows.sorted { $0.win > $1.win }.prefix(3)
        let siegeTop3 = result.rows.sorted { $0.building > $1.building }.prefix(3)
        let kdTop3 = result.rows.sorted { $0.kd > $1.kd }.prefix(3)
        let scoreTop3 = result.rows.sorted { $0.score > $1.score }.prefix(3)
        return HStack(alignment: .top, spacing: 8) {
            podiumCard(title: "⚔️ 击杀榜 TOP3", rows: Array(killTop3)) { "\($0.win)" }
            podiumCard(title: "🏰 攻城榜 TOP3", rows: Array(siegeTop3)) { "\($0.building)" }
            podiumCard(title: "📈 K/D 榜 TOP3", rows: Array(kdTop3)) { $0.kdText }
            podiumCard(title: "⭐️ 积分榜 TOP3", rows: Array(scoreTop3)) { "\($0.score)" }
        }
    }

    /// 单个榜单卡：墨绿标题 + 三行（角标/头像/昵称/右对齐绿色数值）。
    private func podiumCard(title: String,
                            rows: [SaltWarDetailRow],
                            figure: @escaping (SaltWarDetailRow) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(red: 0.10, green: 0.26, blue: 0.20))
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, member in
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(RoundedRectangle(cornerRadius: 3.5)
                            .fill(index == 0 ? Color(red: 0.10, green: 0.26, blue: 0.20)
                                  : (index == 1 ? Color(red: 0.24, green: 0.38, blue: 0.34)
                                     : Color(red: 0.35, green: 0.49, blue: 0.43))))
                    Text(String(member.name.prefix(1)))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(LinearGradient(
                            colors: [memberGradient(member).0, memberGradient(member).1],
                            startPoint: .topLeading, endPoint: .bottomTrailing)))
                    Text(member.name)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(figure(member))
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.10, green: 0.42, blue: 0.29))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color(red: 0.10, green: 0.26, blue: 0.20).opacity(0.14)))
    }

    /// 成员头像渐变（按名字稳定取色）。
    private func memberGradient(_ member: SaltWarDetailRow) -> (Color, Color) {
        let pool: [(Color, Color)] = [
            (Color(red: 0.18, green: 0.42, blue: 0.31), Color(red: 0.45, green: 0.66, blue: 0.57)),
            (Color(red: 0.15, green: 0.39, blue: 0.92), Color(red: 0.49, green: 0.66, blue: 0.96)),
            (Color(red: 0.49, green: 0.23, blue: 0.93), Color(red: 0.72, green: 0.61, blue: 0.96)),
            (Color(red: 0.85, green: 0.47, blue: 0.02), Color(red: 0.94, green: 0.72, blue: 0.38)),
            (Color(red: 0.86, green: 0.15, blue: 0.47), Color(red: 0.94, green: 0.57, blue: 0.75)),
            (Color(red: 0.06, green: 0.46, blue: 0.43), Color(red: 0.37, green: 0.77, blue: 0.71)),
            (Color(red: 0.28, green: 0.33, blue: 0.41), Color(red: 0.58, green: 0.65, blue: 0.72)),
        ]
        let hash = abs(member.name.hashValue) % pool.count
        return pool[hash]
    }

    // MARK: 明细行（奖牌 / 攻城 / 击杀 / 死亡 / K/D / 总积分 / 评价）

    private func warDetailRow(index: Int, row: SaltWarDetailRow, maxBuilding: Int) -> some View {
        HStack(spacing: 0) {
            // 名次：前三名奖牌图标。
            Group {
                if let medal = medalInfo(index) {
                    Image(systemName: medal.symbol)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(medal.color)
                        .frame(width: 40)
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.4))
                        .frame(width: 40)
                }
            }
            // 成员（左对齐，弹性宽度——明细表与上栏同宽）。
            Text(row.name)
                .font(.system(size: 11, weight: index < 3 ? .semibold : .regular))
                .foregroundStyle(.primary.opacity(index < 3 ? 0.95 : 0.82))
                .lineLimit(1)
                .frame(minWidth: 116, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            // 攻城：DataBar 底 + 数字（右对齐）。
            HStack {
                Spacer()
                buildingBar(value: row.building, maxValue: maxBuilding)
            }
            .frame(width: 76)
            .padding(.horizontal, 4)
            // 击杀（绿）。
            HStack {
                Spacer()
                Text("\(row.win)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.10, green: 0.42, blue: 0.29))
            }
            .frame(width: 56)
            .padding(.horizontal, 4)
            // 死亡：≥6 = 免费复活额度耗尽（1 条命 + 5 次免费复活），
            // 红底白字胶囊加粗提示「不能再免费复活」；<6 普通暗红。
            HStack {
                Spacer()
                if row.lose >= 6 {
                    Text("\(row.lose)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color(red: 0.86, green: 0.15, blue: 0.15)))
                        .help("死亡已达 6 次：免费复活额度（1 命 + 5 次）已耗尽，再死需要消耗复活丹")
                } else {
                    Text("\(row.lose)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(red: 0.80, green: 0.32, blue: 0.25))
                }
            }
            .frame(width: 56)
            .padding(.horizontal, 4)
            // K/D：≥2 绿、≥1 中性、<1 暗红（右对齐）。
            HStack {
                Spacer()
                Text(row.kdText)
                    .font(.system(size: 11, weight: row.kd >= 2 ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(row.kd >= 2 ? Color(red: 0.10, green: 0.42, blue: 0.29)
                                                    : (row.kd >= 1 ? .primary.opacity(0.75)
                                                       : Color(red: 0.80, green: 0.32, blue: 0.25)))
            }
            .frame(width: 56)
            .padding(.horizontal, 4)
            // 总积分 = 击杀×10 + 死亡×1 + 攻城×1（本地计算，墨绿加粗突出）。
            HStack {
                Spacer()
                Text("\(row.score)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.10, green: 0.26, blue: 0.20))
            }
            .frame(width: 56)
            .padding(.horizontal, 4)
        }
        .frame(minWidth: 520, maxWidth: .infinity, alignment: .leading)
        .frame(height: 30)
        .background(rankRowBackground(index))
    }

    /// 前三名行底：极淡的金银铜渐变；其余行斑马纹。
    private func rankRowBackground(_ index: Int) -> some View {
        Group {
            switch index {
            case 0:
                LinearGradient(colors: [Color.yellow.opacity(0.16), Color.yellow.opacity(0.03)],
                               startPoint: .leading, endPoint: .trailing)
            case 1:
                LinearGradient(colors: [Color.black.opacity(0.05), Color.black.opacity(0.01)],
                               startPoint: .leading, endPoint: .trailing)
            case 2:
                LinearGradient(colors: [Color.orange.opacity(0.10), Color.orange.opacity(0.015)],
                               startPoint: .leading, endPoint: .trailing)
            default:
                Color.clear
            }
        }
    }

    /// 奖牌图标（SF medal.fill）。
    private func medalInfo(_ index: Int) -> (symbol: String, color: Color)? {
        switch index {
        case 0: return ("medal.fill", Color(red: 0.85, green: 0.62, blue: 0.05))
        case 1: return ("medal.fill", Color(red: 0.48, green: 0.52, blue: 0.58))
        case 2: return ("medal.fill", Color(red: 0.72, green: 0.42, blue: 0.16))
        default: return nil
        }
    }

    /// 攻城 DataBar：半透明橙条按最高值归一化，数字右对齐叠在条上。
    private func buildingBar(value: Int, maxValue: Int) -> some View {
        let ratio = maxValue > 0 ? Double(value) / Double(maxValue) : 0
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.black.opacity(0.05))
            if value > 0 {
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.orange.opacity(0.55))
                        .frame(width: max(6, geo.size.width * ratio))
                }
            }
            HStack {
                Spacer()
                Text("\(value)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange)
                    .padding(.trailing, 6)
            }
        }
        .frame(width: 84, height: 16)
    }

    private func rankHeader(_ title: String, width: CGFloat,
                            alignment: Alignment = .leading) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.75))
            .frame(width: width, height: 24, alignment: alignment)
            .padding(.horizontal, 4)
            .background(Color.black.opacity(0.05))
    }
}

/// 日历格悬停提示的空占位（保留扩展点；当前用 .help 提供即可）。
private extension View {
    func dayCellHover(day: Int, calendar: Calendar, saltDate: Date?) -> some View { self }
}
