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
        window.minSize = NSSize(width: 500, height: 500)
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

    /// Mini 视图窗口尺寸切换：mini = 320 宽单列（minSize 同步放宽）；
    /// 退出恢复标准 1180 宽两栏。
    public func applyMiniMode(_ mini: Bool, window: NSWindow) {
        if mini {
            window.minSize = NSSize(width: 300, height: 480)
            window.setContentSize(NSSize(width: 320, height: 780))
        } else {
            window.minSize = NSSize(width: 500, height: 500)
            window.setContentSize(NSSize(width: 1180, height: 780))
        }
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
    /// Mini 视图：320 宽单列纵向布局（窗口尺寸随切换调整）。
    @State private var isMini = UserDefaults.standard.bool(forKey: "salt.chart.mini")
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
    /// 主连接查到的实时落位（战场没进场也有）。
    private var liveBattlefield: SaltLiveBattlefield? { controller.liveBattlefields[account.id] }
    /// 实时地图链的进度 / 失败文案。
    private var liveStatus: String? { controller.liveStatus[account.id] }
    private var isPolling: Bool { controller.pollingAccountIDs.contains(account.id) }
    private var warActive: Bool { controller.warActiveAccountIDs.contains(account.id) }

    var body: some View {
        Group {
            if isMini {
                miniBody
            } else {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    content
                }
            }
        }
        .background(Color(nsColor: NSColor(calibratedWhite: 0.99, alpha: 1)))
        .preferredColorScheme(.light)
        .onAppear(perform: applyWindowSettings)
    }

    /// Mini 视图：320 宽单列（工具条精简为 模式切换 + 退出 mini）。
    private var miniBody: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Picker("", selection: $mode) {
                        ForEach(WindowMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    Spacer()
                    Button {
                        toggleMini()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(red: 0.10, green: 0.42, blue: 0.29))
                    }
                    .buttonStyle(.plain)
                    .help("退出 Mini 视图（恢复标准窗口）")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                Divider()
                content
            }
        }
    }

    /// 进入/退出 Mini：窗口尺寸与 minSize 同步切换（见 WindowManager.applyMiniMode）。
    private func toggleMini() {
        isMini.toggle()
        UserDefaults.standard.set(isMini, forKey: "salt.chart.mini")
        guard let window = windowRef.window else { return }
        session.saltFieldWindows.applyMiniMode(isMini, window: window)
        applyWindowSettings()
    }

    // MARK: 工具栏（模式切换 + 按模式的控件组）
    //
    // ⚠️ 窗口可以缩到 500pt 宽（minSize），而实时模式工具栏控件的固有宽度合计
    // ≈ 1130–1200pt（随状态文案长短浮动）。
    // 原先是一条固定 HStack：窄窗口里它不换行，只**压扁子视图**——
    // 短标签（置顶/穿透/透明）被压到一个字宽 → 竖排成「一个字一行的柱子」；
    // 状态文本被压成 20 多行 → 整条工具栏涨到 **310pt 高**。
    // 实测（探针 /tmp/salt-toolbar-probe，`sh run.sh` 可重跑，编译的就是本文件）：
    //   改前：宽 1180 → 44pt（单行正常）· 宽 1000 → 156pt · 宽 ≤900 → 310pt（用户报的「显示异常」）；
    //   改后：宽 1180 → 40pt（单行）· 1000/900 → 65pt（两行）· ≤800 → 97pt（三行），全程无竖排。
    //
    // 现在按可用宽度**分档换行**（`ViewThatFits` 按各档理想宽度择一；换档语义已实测）：
    //   档1 单行 —— 宽窗口（与原布局逐项一致）
    //   档2 两行 —— 模式+状态+拉取控制 / 窗口偏好（置顶·穿透·透明度·Mini）
    //   档3 三行 —— 模式+状态 / 拉取控制 / 窗口偏好（缩到 minSize 500 也不挤）
    // 配套硬约束（缺一条就会退回「竖排」）：
    //   · 短标签 / 图标按钮一律 `fixedSize()` —— 宁可整行换档，也不许被压成竖排；
    //   · 状态文本 `lineLimit(1)` + `.tail` —— 宁可省略号，也不许把整条撑高。
    private var toolbar: some View {
        toolbarRows
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // 工具栏实测高度 → 穿透豁免区（macOS 15 onGeometryChange；实测失败时
            // 豁免高度有 44pt 保底，见 topInteractiveHeight）。换行后高度会变，
            // 每次变化都重新上报一次。
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                guard abs(height - toolbarHeight) > 0.5 else { return }
                toolbarHeight = height
                applyWindowSettings()
            }
    }

    /// 按模式选控件组；每组再按可用宽度分档（单行 / 两行 / 三行）。
    @ViewBuilder
    private var toolbarRows: some View {
        switch mode {
        case .live:
            ViewThatFits(in: .horizontal) {
                liveRowSingle
                liveRowsDouble
                liveRowsTriple
            }
        case .history:
            ViewThatFits(in: .horizontal) {
                historyRowSingle
                historyRowsDouble
            }
        }
    }

    // ── 实时战况的三种排布 ──

    /// 档1：单行（宽窗口，逐项等于原布局）。
    private var liveRowSingle: some View {
        HStack(spacing: 10) {
            modePicker
            statusView
            Spacer(minLength: 6)
            pollingToggle
            layoutPicker
            statModePicker
            refreshButton
            Divider().frame(height: 16)
            windowPreferenceControls
        }
    }

    /// 档2：两行 —— 拉取控制一行、窗口偏好一行。
    private var liveRowsDouble: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                modePicker
                statusView
                Spacer(minLength: 6)
                pollingToggle
                layoutPicker
                statModePicker
                refreshButton
            }
            HStack(spacing: 10) {
                windowPreferenceControls
                Spacer(minLength: 0)
            }
        }
    }

    /// 档3：三行 —— 模式+状态 / 拉取控制 / 窗口偏好（minSize 500 也装得下）。
    /// 首行**不放 Spacer**：状态文本是贪婪的，放 Spacer 会让「剩余空间」被它俩平分，
    /// 状态文案白丢一半可用宽度（如 476 可用时只剩 153pt 显示）。
    private var liveRowsTriple: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                modePicker
                statusView
            }
            HStack(spacing: 10) {
                pollingToggle
                layoutPicker
                statModePicker
                refreshButton
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                windowPreferenceControls
                Spacer(minLength: 0)
            }
        }
    }

    // ── 历史战绩的两种排布 ──

    private var historyRowSingle: some View {
        HStack(spacing: 10) {
            modePicker
            historyStatusText
            Spacer(minLength: 6)
            historyFetchButton
            Divider().frame(height: 16)
            miniButton
        }
    }

    private var historyRowsDouble: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                modePicker
                historyStatusText
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                historyFetchButton
                Divider().frame(height: 16)
                miniButton
                Spacer(minLength: 0)
            }
        }
    }

    // ── 工具栏零件（各档共用，改一处各档同步）──

    /// 模式切换（实时 / 历史）。
    private var modePicker: some View {
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
    }

    private var pollingToggle: some View {
        Toggle("轮询", isOn: Binding(
            get: { isPolling },
            set: { session.setSaltFieldPolling($0, account: account) }
        ))
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
        .fixedSize()
        .help("每 4 秒向盐场连接自动拉取一次战场信息")
    }

    private var layoutPicker: some View {
        Picker("", selection: $layout) {
            ForEach(MapLayout.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 168)
        .help("占领布局 = 俱乐部占领区连通染色；分布布局 = 只亮各大本营位置")
    }

    private var statModePicker: some View {
        Picker("", selection: $statMode) {
            ForEach(StatMode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 168)
        .help("俱乐部战况 = 按俱乐部汇总；个人战况 = 全部成员按击杀排序")
    }

    private var refreshButton: some View {
        Button {
            session.refreshSaltFieldNow(account: account)
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("立即拉取一次")
    }

    /// 窗口偏好组：置顶 / 穿透 / 透明度 / Mini（各档共用同一串控件）。
    private var windowPreferenceControls: some View {
        HStack(spacing: 10) {
            floatingToggle
            clickThroughToggle
            opacityLabel
            opacitySlider
            opacityPercent
            Divider().frame(height: 16)
            miniButton
        }
    }

    private var floatingToggle: some View {
        Toggle("置顶", isOn: $floating)
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            .fixedSize()
            .onChange(of: floating) { _, _ in applyWindowSettings() }
            .help("窗口悬浮在所有实例窗口之上")
    }

    private var clickThroughToggle: some View {
        Toggle("穿透", isOn: $clickThrough)
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            .fixedSize()
            .onChange(of: clickThrough) { _, _ in applyWindowSettings() }
            .help("开启后仅地图与战况表区域穿透（点击直达下层游戏窗口）；\n标题栏与本工具栏始终可正常拖动/点击；\n按住 Control 可临时点击穿透中的内容区（如滚动表格）")
    }

    private var opacityLabel: some View {
        Text("透明")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var opacitySlider: some View {
        Slider(value: $opacity, in: 0.25...1.0)
            .frame(width: 110)
            .onChange(of: opacity) { _, _ in applyWindowSettings() }
            .help("窗口透明度：低透明度悬浮在实例上不挡操作")
    }

    private var opacityPercent: some View {
        Text("\(Int(opacity * 100))%")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 34)
    }

    /// Mini 视图切换（实时 / 历史两套工具栏共用）。
    private var miniButton: some View {
        Button {
            toggleMini()
        } label: {
            Image(systemName: "rectangle.compress.vertical")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.10, green: 0.42, blue: 0.29))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("切换 Mini 视图：窗口缩到 320 宽单列（总览+明细+榜单+日历纵向排列），适合贴边悬浮")
    }

    /// 历史战绩的状态文案（窄档下宁可省略号，也不许竖排撑高）。
    private var historyStatusText: some View {
        Text(controller.historyStatus[account.id] ?? "选择右侧日历中的盐场日期查询当场总榜")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var historyFetchButton: some View {
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
        .fixedSize()
        .disabled(controller.historyBusy.contains(account.id))
        .help("拉取本账号的盐场历史场次（legion_getinfo），日历上会标注我方名次")
    }

    /// 连接/轮询状态（一眼定性「没数据」是哪一环）。
    ///
    /// 文本两条约束都不能少：
    ///   · `lineLimit(1)`：状态文案有长有短（最长「未检测到盐场连接（请在游戏内进入盐场战场）」
    ///     ≈240pt），窄档下要退化成省略号，而不是竖排成 20 多行把工具栏撑到 300pt；
    ///   · `idealWidth: 170`：换档判据看的是**理想宽度**，不设这个的话状态文案一长
    ///     （240pt）就把单行档的理想宽度顶到 1202pt > 默认窗口的 1156pt → 宽窗口也变两行。
    ///     给个 170 的「理想值」后，单行档理想 = 1132pt，默认 1180 窗口稳在单行；
    ///     实际布局里它是贪婪的（maxWidth ∞），有空间就铺开显示完整文案。
    private var statusView: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, idealWidth: 170, maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusColor: Color {
        if isPolling, snapshot != nil { return .green }
        if liveBattlefield != nil { return .green }
        if warActive || liveStatus != nil { return .yellow }
        return .gray
    }

    /// 一行状态（优先级：战场快照 → 实时地图落位 → 链中途文案 → 连接探测）。
    private var statusText: String {
        if let snapshot {
            let updated = Self.clockText(snapshot.timestampMs / 1000)
            let mode = isPolling ? "轮询中" : "手动"
            return "\(mode) · \(updated) 更新"
        }
        if let live = liveBattlefield {
            return "战场 #\(live.battlefieldID) · \(live.clubs.count) 家落位 · "
                + "\(Self.clockText(live.fetchedAt.timeIntervalSince1970)) 更新（等战场数据）"
        }
        if let text = liveStatus { return text }
        if warActive { return "已检测到盐场连接，等待战场数据…" }
        return "未检测到盐场连接（请在游戏内进入盐场战场）"
    }

    /// 时间戳（秒）→ HH:mm:ss。
    private static func clockText(_ seconds: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    // MARK: 内容（按窗口模式：实时 / 历史）

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .live:
            liveContent
        case .history:
            SaltHistoryView(session: session, account: account, isMini: isMini)
                .id(account.id)
        }
    }

    /// 实时内容：**地图永远先画出来**（静态骨架打底），有数据再叠实时情况——
    ///   · 有战场快照 → 用快照节点（服务端归属 + 占领路径染色）；
    ///   · 只有主连接落位 → 静态骨架 + 大本营联盟色/俱乐部名（参考脚本「星驰」那条路）；
    ///   · 什么都没有 → 纯静态骨架（道路/据点/大本营），左下角角标说明卡在哪一步。
    /// 右侧表格在没有快照时显示占位，不遮挡地图。
    private var liveContent: some View {
        liveSplit(nodes: snapshot?.nodes ?? Self.staticNodes, snapshot: snapshot)
    }

    /// 静态骨架节点（地图底图；与快照节点同构，窗口画法不变）。
    private static let staticNodes: [String: SaltRenderedNode] =
        SaltFieldChartController.staticNodes()

    /// 左图右表（Mini 视图里改上下堆叠——320pt 宽塞不下 430pt 的表）。
    private func liveSplit(nodes: [String: SaltRenderedNode],
                           snapshot: SaltFieldSnapshot?) -> some View {
        let map = SaltFieldMapView(nodes: nodes,
                                   layout: layout,
                                   legionNameByID: snapshot.map { snap in
                                       Dictionary(uniqueKeysWithValues: snap.legions.map { ($0.id, $0.name) })
                                   } ?? [:],
                                   clubsByPosition: liveBattlefield?.clubByPosition ?? [:])
        let table = Group {
            if let snapshot {
                SaltFieldStatView(snapshot: snapshot, mode: statMode)
            } else {
                statPlaceholder
            }
        }
        return Group {
            if isMini {
                VStack(spacing: 0) {
                    map.frame(height: 300)
                        .overlay(alignment: .bottomLeading) { mapCaption }
                    Divider()
                    table.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    map
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottomLeading) { mapCaption }
                    Divider()
                    table.frame(width: 430)
                }
            }
        }
    }

    /// 地图左下角角标：有落位就报「哪一场 / 几家落位 / 什么时候拉的」，
    /// 没有就报当前卡在哪一步（未进盐场 / 正在定位 / 本月非盐场周）。
    private var mapCaption: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(mapCaptionColor)
                .frame(width: 6, height: 6)
            Text(mapCaptionText)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.85), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.black.opacity(0.10)))
        .padding(8)
    }

    private var mapCaptionText: String {
        if let live = liveBattlefield {
            return "战场 #\(live.battlefieldID) · \(live.clubs.count) 家落位 · "
                + "\(Self.clockText(live.fetchedAt.timeIntervalSince1970)) 更新"
        }
        if let text = liveStatus { return text }
        if warActive { return "已检测到盐场连接，等待战场数据…" }
        return "未检测到盐场连接（请在游戏内进入盐场战场）"
    }

    private var mapCaptionColor: Color {
        if liveBattlefield != nil { return .green }
        if liveStatus != nil || warActive { return .orange }
        return .gray
    }

    /// 右侧表格占位：地图已经画出来了，实时战况还等战场数据。
    private var statPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "tablecells")
                .font(.system(size: 28))
                .foregroundStyle(.quaternary)
            Text("等待战场数据")
                .font(.system(size: 12, weight: .semibold))
            Text("左侧地图已按静态骨架绘制"
                 + (liveBattlefield == nil ? "；查到俱乐部落位后会自动标上大本营。"
                                           : "，并已标出各俱乐部的大本营落位。")
                 + "\n实时战况（击杀/死亡/积分）需要实例进入盐场战场后才有。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
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
    /// 渲染节点（静态骨架 + 快照里的动态归属；无快照时只传静态骨架）。
    let nodes: [String: SaltRenderedNode]
    let layout: SaltFieldChartWindowView.MapLayout
    let legionNameByID: [Int64: String]
    /// 大本营序号 → 俱乐部（主连接 `legion_getopponent` 的实时落位；可为空）。
    var clubsByPosition: [Int: SaltLiveClub] = [:]

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

    /// 该大本营在实时落位表里的俱乐部（快照给了归属就不用了——服务端数据更权威）。
    private func liveClub(of node: SaltRenderedNode) -> SaltLiveClub? {
        guard node.isStronghold, node.belongsLegionID == nil,
              let position = SaltFieldChartController.strongholdPosition(nodeID: node.id) else { return nil }
        return clubsByPosition[position]
    }

    /// 核心四周那 6 格（固定粉红标记；它们本身是道路，正常会被染成蓝色）。
    private static let coreRingIDs: Set<String> =
        Set(SaltFieldChartController.coreRingNodeIDs())

    /// 节点的最终染色：
    ///   ⓪ 核心四周 6 格 → 固定粉红（用户点名的焦点标记，不参与归属染色）；
    ///   ① 大本营且**只有主连接落位**（快照还没来）→ 用该俱乐部的联盟色
    ///      （参考脚本「星驰」getAllianceColor 口径：梦盟红 / 大联盟绿 / 龍盟蓝）；
    ///      认不出联盟的用大本营底色 #DC143C（参考脚本 SALT_BUILDING_TYPES[57].bgColor）
    ///      ——联盟色表里的「未知」是近白 #f8f9fa，直接刷在六边形上会看不见。
    ///   ② 占领布局用快照染好的 colorHex；③ 分布布局只有大本营亮俱乐部色，其余统一道路蓝
    ///      （照抄自助手仓的分布布局口径）。
    private func color(of node: SaltRenderedNode, club: SaltLiveClub?) -> Color {
        if Self.coreRingIDs.contains(node.id) {
            return SaltColorPalette.color(SaltColorPalette.coreRingColor)
        }
        if let club {
            return SaltColorPalette.color(club.alliance == .unknown
                                          ? "#DC143C" : club.alliance.fillHex)
        }
        if layout == .occupy {
            return SaltColorPalette.color(node.colorHex)
        }
        if node.isStronghold, node.belongsLegionID != nil {
            return SaltColorPalette.color(node.colorHex)
        }
        return SaltColorPalette.color(SaltColorPalette.typeColor(9))
    }

    /// 六边形路径（顶点角 0/60/120…；与 centerX/centerY 同一套几何）。
    private func hexPath(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for corner in 0..<6 {
            let angle = CGFloat(corner) * .pi / 3
            let point = CGPoint(x: center.x + radius * cos(angle),
                                y: center.y + radius * sin(angle))
            if corner == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let map = mapSize
        let scale = min(size.width / map.width, size.height / map.height, 1.6)
        let offsetX = max(0, (size.width - map.width * scale) / 2)
        let offsetY = max(0, (size.height - map.height * scale) / 2)
        let radius = hexSize * scale

        func screenCenter(col: Int, row: Int) -> CGPoint {
            CGPoint(x: offsetX + centerX(col) * scale,
                    y: offsetY + centerY(row, col: col) * scale)
        }

        // ① 先铺**整张网格**：骨架之外的格子画成白色（细描边），地图边界一眼可见。
        //    （用户口径：地图周围没用到的六角框用白色框表示。）
        let emptyFill = SaltColorPalette.color(SaltColorPalette.emptyCellColor)
        for col in 0..<SaltFieldChartController.gridColumns {
            for row in 0..<SaltFieldChartController.gridRows where nodes["\(col)_\(row)"] == nil {
                let path = hexPath(center: screenCenter(col: col, row: row), radius: radius)
                context.fill(path, with: .color(emptyFill))
                context.stroke(path, with: .color(.black.opacity(0.10)), lineWidth: 0.5)
            }
        }

        // ② 再画有内容的格子（骨架 + 动态归属）。
        var labels: [(CGPoint, String, Color)] = []
        /// 俱乐部名标签：带底色的胶囊（联盟色填充 + 对应文字色），画在大本营上方。
        var clubChips: [(CGPoint, String, SaltAlliance.Name)] = []
        for node in nodes.values {
            let center = screenCenter(col: node.x, row: node.y)
            let path = hexPath(center: center, radius: radius)
            let club = liveClub(of: node)
            context.fill(path, with: .color(color(of: node, club: club)))
            context.stroke(path, with: .color(.black.opacity(0.22)), lineWidth: 0.6)

            // 标注：大本营 → 俱乐部名（快照归属优先，其次主连接落位）；
            //       据点 → 血量短名（30/50/80/100 血）。
            if node.isStronghold {
                if let club {
                    clubChips.append((CGPoint(x: center.x, y: center.y - radius * 1.25),
                                      club.labelText, club.alliance))
                } else if let legionID = node.belongsLegionID, let name = legionNameByID[legionID] {
                    labels.append((center, name, .black))
                } else if let position = SaltFieldChartController.strongholdPosition(nodeID: node.id) {
                    // 既没归属也没落位：至少把大本营序号标出来（方便对号入座）。
                    labels.append((center, "\(position)", .black.opacity(0.75)))
                }
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
        let chipFont = max(7, 10.5 * scale)
        for (center, text, alliance) in clubChips {
            let resolved = context.resolve(Text(text)
                .font(.system(size: chipFont, weight: .semibold))
                .foregroundStyle(SaltColorPalette.color(alliance.textHex)))
            let measured = resolved.measure(in: CGSize(width: 900, height: 60))
            let rect = CGRect(x: center.x - measured.width / 2 - 3.5,
                              y: center.y - measured.height / 2 - 2,
                              width: measured.width + 7,
                              height: measured.height + 4)
            context.fill(Path(roundedRect: rect, cornerRadius: 3),
                         with: .color(SaltColorPalette.color(alliance.fillHex)))
            context.stroke(Path(roundedRect: rect, cornerRadius: 3),
                           with: .color(.black.opacity(0.25)), lineWidth: 0.6)
            context.draw(resolved, at: center)
        }
    }
}

// MARK: - 战况表

/// 右侧战况表：俱乐部模式（11 列）或个人模式（10 列，全部成员按击杀排序）。
/// 死亡 / K/D 是参考脚本（雪碧助手 renderGlobalWarReport）在 legion 层没有、
/// 由成员累加出来的两个量——服务端只给每人的 `d`，俱乐部口径靠 Σ 还原。
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
        // ⚠️ 双向 ScrollView 在内容小于视口时会把内容**居中**（实测：只有两行数据的表
        // 浮在面板正中，看着像没加载出来）。`frame(maxHeight: .infinity)` 之类都没用，
        // 只有 `defaultScrollAnchor(.topLeading)` 真管用（同场对照探针 /tmp/saltfield-anchor-probe）。
        .defaultScrollAnchor(.topLeading)
    }

    // MARK: 俱乐部表

    private var legionTable: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                statHeader("俱乐部", width: 96)
                statHeader("击杀", width: 44)
                statHeader("死亡", width: 44)
                statHeader("K/D", width: 46)
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
                    statCell(legion.isEliminated ? "\(legion.name)·淘汰" : legion.name,
                             width: 96, bold: true,
                             tint: legion.isEliminated ? .secondary : nil)
                    statCell("\(legion.killCount)", width: 44)
                    statCell("\(legion.deaths)", width: 44)
                    statCell(legion.kdText, width: 46)
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
    /// 容器实际宽度（窄窗口自适应：缩日历/隐藏积分榜/缩列宽）。
    @State private var availableWidth: CGFloat = 0

    /// 紧凑判定：< 800 视为紧凑布局（5 张总览卡 + 4 张 TOP3 至少需要 ~880 宽）。
    private var isCompact: Bool { availableWidth > 0 && availableWidth < 800 }

    /// 极窄判定：< 500（窗口缩到最小）：TOP 榜移到日历上方、总览隐藏总积分。
    private var isUltraNarrow: Bool { availableWidth > 0 && availableWidth < 500 }

    /// 列宽自适应：紧凑/极窄布局下按 0.8 缩。
    private func cw(_ regular: CGFloat) -> CGFloat { isCompact ? regular * 0.8 : regular }

    /// Mini 单列布局标志（由窗口视图传入；窗口宽 320 时为 true）。
    let isMini: Bool

    init(session: LobbySessionModel, account: GameAccount, isMini: Bool) {
        _controller = ObservedObject(wrappedValue: session.saltField)
        self.account = account
        self.isMini = isMini
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
        Group {
            if isMini {
                miniLayout
            } else {
                VStack(spacing: 0) {
                    monthNavigator
                    Divider()
                    HStack(spacing: 0) {
                        // 极窄时左栏 = TOP 榜（竖排，在日历上方）+ 日历；明细独占右侧全高。
                        VStack(spacing: 8) {
                            if isUltraNarrow, let result = controller.historyDetails[account.id] {
                                topPodiums(result)
                            }
                            calendarView
                        }
                        .frame(width: isUltraNarrow ? 170 : (isCompact ? 190 : 330))
                        .padding(isCompact ? 3 : 8)
                        Divider()
                        rankView
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            availableWidth = width
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

    /// Mini 单列布局：我的场次 → 总览卡 → 成员明细 → TOP 榜 → 日历。
    private var miniLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button {
                        controller.fetchHistoryBattles(accountID: account.id)
                    } label: {
                        Text("我的场次")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.10, green: 0.42, blue: 0.29))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                if let result = controller.historyDetails[account.id] {
                    overviewCards(result)
                    Divider()
                    miniDetailTable(result)
                    Divider()
                    topPodiums(result)
                }
                calendarView
            }
            .padding(8)
        }
    }

    /// Mini 成员明细（4 列：# / 成员 / 击杀 / 死亡；死亡 ≥6 红胶囊提示）。
    private func miniDetailTable(_ result: SaltWarDetailsResult) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("#").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .leading)
                Text("成员").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    if sortKey == .kill { sortAscending.toggle() } else { sortKey = .kill; sortAscending = false }
                } label: {
                    HStack(spacing: 2) {
                        Text("击杀")
                        if sortKey == .kill {
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                    }
                    .font(.system(size: 10, weight: sortKey == .kill ? .bold : .semibold))
                    .foregroundStyle(sortKey == .kill ? Color(red: 0.10, green: 0.26, blue: 0.20) : .secondary)
                    .frame(width: 40, alignment: .trailing)
                }
                .buttonStyle(.plain)
                Text("死亡").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            .frame(height: 20)
            ForEach(Array(sortedRows(result.rows).enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 0) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .leading)
                    Text(row.name)
                        .font(.system(size: 10.5, weight: index < 3 ? .semibold : .regular))
                        .foregroundStyle(.primary.opacity(index < 3 ? 0.95 : 0.82))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(row.win)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.10, green: 0.42, blue: 0.29))
                        .frame(width: 40, alignment: .trailing)
                    Group {
                        if row.lose >= 6 {
                            Text("\(row.lose)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color(red: 0.86, green: 0.15, blue: 0.15)))
                        } else {
                            Text("\(row.lose)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Color(red: 0.80, green: 0.32, blue: 0.25))
                        }
                    }
                    .frame(width: 36, alignment: .trailing)
                }
                .frame(height: 24)
                .background(index < 3 ? Color.yellow.opacity(0.08) : Color.clear)
            }
        }
    }

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
                    .font(.system(size: isCompact ? 9.5 : 11, weight: salt ? .bold : .regular))
                    .foregroundStyle(salt ? Color(red: 0.10, green: 0.26, blue: 0.20)
                                          : Color.primary.opacity(0.55))
                if let battle {
                    Text(battle.rank > 0 ? "第\(battle.rank)名" : battle.warTypeName)
                        .font(.system(size: isCompact ? 7 : 8, weight: .semibold))
                        .foregroundStyle(rankColor(battle.rank))
                } else if salt && !isCompact {
                    Text("盐场")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color(red: 0.10, green: 0.26, blue: 0.20).opacity(0.75))
                }
            }
            .frame(maxWidth: .infinity, minHeight: isCompact ? 26 : 34)
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
                // 上栏二：四个 TOP3 榜单（极窄时已移到左栏日历上方）。
                if !isUltraNarrow {
                    topPodiums(result)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    Divider()
                }
                // 底部：全部成员明细（可点表头排序；默认击杀降序）。
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            rankHeader("#", width: cw(40), alignment: .center)
                            // 成员列弹性拉伸，让明细表与上栏榜单卡同宽。
                            Text("成员")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary.opacity(0.75))
                                .frame(minWidth: cw(60), maxWidth: .infinity, alignment: .leading)
                                .frame(height: 24)
                                .padding(.horizontal, 4)
                                .background(Color.black.opacity(0.05))
                            if !isUltraNarrow {
                                sortableHeader("攻城", key: .siege, width: cw(72))
                            }
                            sortableHeader("击杀", key: .kill, width: cw(60))
                            sortableHeader("死亡", key: .death, width: cw(60))
                            sortableHeader("K/D", key: .kd, width: cw(62))
                            sortableHeader("总积分", key: .score, width: cw(70))
                        }
                        .frame(minWidth: isCompact ? 380 : 520, maxWidth: .infinity, alignment: .leading)
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
    @ViewBuilder
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
            // 极窄时总积分卡隐藏（重要数据在明细表里都有）。
            if !isUltraNarrow {
                overviewCard(label: "总积分", tint: Color(red: 0.15, green: 0.39, blue: 0.92),
                             icon: "star.fill", value: "\(totalScore)")
            }
        }
    }

    /// 紧凑总览卡：标题（着色）在上、大数字（同色）在下。
    private func overviewCard(label: String, tint: Color, icon: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: isCompact ? 2 : 4) {
            Text(label)
                .font(.system(size: isCompact ? 10 : 12, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(.system(size: isCompact ? 16 : 22, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(tint.opacity(0.22)))
    }

    @ViewBuilder
    private func topPodiums(_ result: SaltWarDetailsResult) -> some View {
        let killTop3 = result.rows.sorted { $0.win > $1.win }.prefix(3)
        let siegeTop3 = result.rows.sorted { $0.building > $1.building }.prefix(3)
        let kdTop3 = result.rows.sorted { $0.kd > $1.kd }.prefix(3)
        let scoreTop3 = result.rows.sorted { $0.score > $1.score }.prefix(3)
        // 极窄：三张榜单竖排堆叠（放日历上方）。
        if isUltraNarrow {
            VStack(alignment: .leading, spacing: 6) {
                podiumCard(title: "⚔️ 击杀榜", rows: Array(killTop3)) { "\($0.win)" }
                podiumCard(title: "🏰 攻城榜", rows: Array(siegeTop3)) { "\($0.building)" }
                podiumCard(title: "📈 K/D 榜", rows: Array(kdTop3)) { $0.kdText }
            }
        } else {
            HStack(alignment: .top, spacing: isCompact ? 5 : 8) {
                podiumCard(title: "⚔️ 击杀榜", rows: Array(killTop3)) { "\($0.win)" }
                podiumCard(title: "🏰 攻城榜", rows: Array(siegeTop3)) { "\($0.building)" }
                podiumCard(title: "📈 K/D 榜", rows: Array(kdTop3)) { $0.kdText }
                // 窄窗口挤不下四个榜：隐藏积分榜（宽度足够才显示）。
                if !isCompact {
                    podiumCard(title: "⭐️ 积分榜", rows: Array(scoreTop3)) { "\($0.score)" }
                }
            }
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
            // 成员（左对齐，弹性宽度）：游戏名称最多 6 字，列宽按 6 字约 76pt 起步。
            Text(row.name)
                .font(.system(size: 11, weight: index < 3 ? .semibold : .regular))
                .foregroundStyle(.primary.opacity(index < 3 ? 0.95 : 0.82))
                .lineLimit(1)
                .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            // 攻城：DataBar 底 + 数字（右对齐）；极窄时整列隐藏（击杀/死亡更重要）。
            if !isUltraNarrow {
                HStack {
                    Spacer()
                    buildingBar(value: row.building, maxValue: maxBuilding)
                }
                .frame(width: cw(72))
                .padding(.horizontal, 4)
            }
            // 击杀（绿）。
            HStack {
                Spacer()
                Text("\(row.win)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.10, green: 0.42, blue: 0.29))
            }
            .frame(width: cw(56))
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
            .frame(width: cw(56))
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
            .frame(width: cw(56))
            .padding(.horizontal, 4)
            // 总积分 = 击杀×10 + 死亡×1 + 攻城×1（本地计算，墨绿加粗突出）。
            HStack {
                Spacer()
                Text("\(row.score)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.10, green: 0.26, blue: 0.20))
            }
            .frame(width: cw(56))
            .padding(.horizontal, 4)
        }
        .frame(minWidth: isCompact ? 380 : 520, maxWidth: .infinity, alignment: .leading)
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
