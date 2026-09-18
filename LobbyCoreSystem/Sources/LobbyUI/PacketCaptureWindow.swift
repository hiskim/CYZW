import AppKit
import LobbyDomain
import LobbyEngine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 抓包窗口管理
//
// 每个账号一个**独立 NSWindow**（与多开矩阵一一对应）：
//   · 打开 = 用户点了实例卡片的抓包按钮（会话模型先开了抓包再叫开窗口）；
//   · 关窗（红点）= 自动停止抓包（留存帧保留在会话里，重开按钮可继续看 / 导出）；
//   · 实例关闭 = 窗口一起关、会话整体丢弃。
//
// `isReleasedWhenClosed = false` + 手动从字典摘除：窗口对象由管理器持有，
// 关闭只触发 delegate 回调，绝不让 AppKit 在事件循环里偷偷释放（经典崩溃源）。
@MainActor
public final class PacketCaptureWindowManager: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    private weak var session: LobbySessionModel?
    /// 新窗口的级联偏移（多开时窗口不叠死在同一位置）。
    private static var cascadeIndex = 0

    public override init() {}

    func attach(session: LobbySessionModel) {
        self.session = session
    }

    /// 打开（或前置）账号的抓包窗口。
    public func openWindow(for account: GameAccount) {
        if let existing = windows[account.id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let contentRect = NSRect(x: 0, y: 0, width: 920, height: 640)
        let window = NSWindow(contentRect: contentRect,
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "抓包 · \(account.nickname)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 460)
        // 工具窗口跟随大厅的深色气质（SwiftUI 的 preferredColorScheme 只管主窗口）。
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1)
        guard let session else {
            LobbyLog.warn("[capture] 会话模型未挂接，抓包窗口无法创建")
            return
        }
        window.contentView = NSHostingView(rootView: PacketCaptureWindowView(
            session: session,
            account: account
        ))
        // 级联定位：固定起点 + 每窗偏移，多开抓包不叠窗。
        Self.cascadeIndex += 1
        window.cascadeTopLeft(from: NSPoint(x: 160 + Self.cascadeIndex * 28,
                                            y: 140 + Self.cascadeIndex * 24))
        // delegate 挂在管理器上：用户点红点关窗时必须在 windowWillClose 里
        // 摘除登记并停抓——不挂 delegate 的表现为「窗口关了但还在抓、对象泄漏」。
        window.delegate = self
        windows[account.id] = window
        window.makeKeyAndOrderFront(nil)
    }

    /// 关闭并丢弃窗口（实例关闭时调用；不改变抓包状态——由会话模型一并处理）。
    public func closeWindow(forAccountID accountID: String) {
        let window = windows.removeValue(forKey: accountID)
        window?.close()
    }

    /// 用户点红点关窗（NSWindowDelegate）：摘除登记 + 自动停抓这一个账号。
    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let accountID = windows.first(where: { $0.value === window })?.key else { return }
        windows.removeValue(forKey: accountID)
        session?.packetCaptureWindowDidClose(accountID: accountID)
    }
}

// MARK: - 抓包窗口视图（三页签）

/// 抓包窗口主视图：【抓包流】【发送指令】【指令库】三页签。
///
/// 布局动机（用户确认的单窗口三页签方案）：白/黑名单以 chip 形式内嵌在抓包流
/// 的过滤区（替代自由文本框——指令库里点两下就完成精确过滤，上下文连贯）；
/// 发送与指令库独立成页签，各自有完整的操作空间。
struct PacketCaptureWindowView: View {
    enum CaptureTab: Int, CaseIterable, Identifiable {
        case stream, pairs, send, catalog
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .stream: return "抓包流"
            case .pairs: return "配对"
            case .send: return "发送指令"
            case .catalog: return "指令库"
            }
        }
    }

    /// 系统帧（与引擎侧口径一致：配对页签不展示，心跳排除开关同时滤掉——
    /// 含 WebSocket 应用层心跳 0x80 ping）。
    static let systemCommands: Set<String> = ["heart_beat", "_sys/ack", "_sys/error", "_ws/ping"]

    @ObservedObject var session: LobbySessionModel
    /// 抓包控制器（capturing 状态 + 发送历史 + 页面回执）。
    @ObservedObject private var capture: PacketCaptureController
    /// 本窗口的会话（frames 是唯一的上屏数据源）。
    @ObservedObject private var captureSession: PacketCaptureSession
    let account: GameAccount

    @State private var activeTab: CaptureTab = .stream
    // ── 抓包流过滤状态（改这些不重新抓包，只重算列表）──
    @State private var directionFilter = 0 // 0 全部 1 发送 2 接收
    @State private var includeCommands: [String] = [] // 白名单 chip（精确 cmd）
    @State private var excludeCommands: [String] = [] // 黑名单 chip（精确 cmd）
    /// 正则过滤（大小写不敏感；非法表达式不生效并在栏上提示）。
    @State private var includeRegexText = ""
    @State private var excludeRegexText = ""
    @State private var hideHeartbeat = true
    @State private var searchText = ""
    @State private var selectedPacketID: UUID?
    /// JSON 视图模式：false = 压缩单行（默认），true = 缩进展开（懒美化，仅当前查看的帧）。
    /// 抓包流详情面板与配对页签的展开区共用这一开关。
    @State private var jsonPretty = false
    // ── 跨页签联动：配对/指令库「填入发送」→ 发送页签预填；配对行点击 → 抓包流定位 ──
    @State private var sendDraftCommand: String?

    init(session: LobbySessionModel, account: GameAccount) {
        self.session = session
        self.account = account
        _capture = ObservedObject(wrappedValue: session.capture)
        // 会话可能还没有（按钮点开就开抓，beginSession 先建会话再开窗口），
        // 兜底一个空会话保证视图构造不炸。
        if let existing = session.capture.session(forAccountID: account.id) {
            _captureSession = ObservedObject(wrappedValue: existing)
        } else {
            let fresh = PacketCaptureSession()
            _captureSession = ObservedObject(wrappedValue: fresh)
        }
    }

    private var isCapturing: Bool { capture.isCapturing(accountID: account.id) }

    // MARK: 正则过滤（编译失败返回 nil = 不生效，由过滤栏提示）

    private var includeRegex: NSRegularExpression? {
        guard !includeRegexText.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: includeRegexText, options: [.caseInsensitive])
    }

    private var excludeRegex: NSRegularExpression? {
        guard !excludeRegexText.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: excludeRegexText, options: [.caseInsensitive])
    }

    // MARK: 过滤

    private func matchesRegex(_ regex: NSRegularExpression?, command: String) -> Bool? {
        guard let regex else { return nil }
        let range = NSRange(command.startIndex..., in: command)
        return regex.firstMatch(in: command, options: [], range: range) != nil
    }

    private var filteredFrames: [CapturedPacket] {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let include = includeRegex
        let exclude = excludeRegex
        return captureSession.frames.filter { packet in
            switch directionFilter {
            case 1: if packet.direction != "send" { return false }
            case 2: if packet.direction != "recv" { return false }
            default: break
            }
            if hideHeartbeat, Self.systemCommands.contains(packet.command) { return false }
            // 白名单 chip（精确）+ 包含正则；黑名单 chip + 排除正则（黑名单优先级最高）。
            if !includeCommands.isEmpty, !includeCommands.contains(packet.command) { return false }
            if let hit = matchesRegex(include, command: packet.command), !hit { return false }
            if excludeCommands.contains(packet.command) { return false }
            if let hit = matchesRegex(exclude, command: packet.command), hit { return false }
            if !search.isEmpty {
                let hit = packet.command.localizedCaseInsensitiveContains(search)
                    || (packet.summary?.localizedCaseInsensitiveContains(search) ?? false)
                if !hit { return false }
            }
            return true
        }
    }

    private var selectedPacket: CapturedPacket? {
        guard let selectedPacketID else { return nil }
        return captureSession.frames.first { $0.id == selectedPacketID }
    }

    // MARK: 布局

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Color.white.opacity(0.10))
            switch activeTab {
            case .stream:
                streamPane
            case .pairs:
                PairingPane(session: session,
                            captureSession: captureSession,
                            selectedPacketID: $selectedPacketID,
                            jsonPretty: jsonPretty,
                            switchToStream: { activeTab = .stream })
            case .send:
                SendCommandPane(session: session,
                                account: account,
                                capture: capture,
                                catalog: session.commandCatalog,
                                draftCommand: $sendDraftCommand,
                                jsonPretty: jsonPretty)
            case .catalog:
                CommandCatalogPane(catalog: session.commandCatalog,
                                   includeCommands: $includeCommands,
                                   excludeCommands: $excludeCommands,
                                   sendDraftCommand: $sendDraftCommand)
            }
        }
        .background(Color(lobbyRGB: 0x14161B).ignoresSafeArea())
        .task {
            // 页面回执轮询（三页签共用，抓包流诊断行 + 发送可用性都看它）。
            while !Task.isCancelled {
                session.pool.existingSurface(forAccountID: account.id)?.queryPacketCaptureStatus()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    // MARK: 顶栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isCapturing ? Color(red: 1.0, green: 0.35, blue: 0.30) : Color.white.opacity(0.25))
                .frame(width: 8, height: 8)
                .shadow(color: isCapturing ? Color(red: 1.0, green: 0.35, blue: 0.30).opacity(0.8) : .clear,
                        radius: 4)
            Text(account.nickname)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(isCapturing ? "抓包中" : "已停止")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isCapturing ? Color(red: 1.0, green: 0.45, blue: 0.42) : .secondary)
            Spacer(minLength: 10)
            Picker("", selection: $activeTab) {
                ForEach(CaptureTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 380)
            Spacer(minLength: 10)
            Button {
                session.togglePacketCapture(account)
            } label: {
                Text(isCapturing ? "停止抓包" : "开始抓包")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(
                (isCapturing ? Color(red: 1.0, green: 0.45, blue: 0.42) : Color.cyan).opacity(0.16)))
            .overlay(Capsule(style: .continuous).strokeBorder(
                (isCapturing ? Color(red: 1.0, green: 0.45, blue: 0.42) : Color.cyan).opacity(0.5), lineWidth: 1))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: 抓包流页签

    private var streamPane: some View {
        VStack(spacing: 0) {
            filterChipsBar
            filterBar
            regexBar
            pageDiagnosticsLine
            Divider().overlay(Color.white.opacity(0.10))
            HStack(spacing: 0) {
                packetList
                    .frame(width: 370)
                Divider().overlay(Color.white.opacity(0.10))
                detailPane
            }
        }
    }

    /// 正则过滤行（大小写不敏感；非法表达式红色提示且不生效）。
    private var regexBar: some View {
        HStack(spacing: 8) {
            Text("正则")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(lobbyRGB: 0x3B82F6))
            HStack(spacing: 4) {
                Text("包含")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("如 ^(role|hero)_.*|Resp$", text: $includeRegexText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(includeRegex == nil && !includeRegexText.isEmpty ? .red : .primary)
            }
            HStack(spacing: 4) {
                Text("排除")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("如 _sys|heart", text: $excludeRegexText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(excludeRegex == nil && !excludeRegexText.isEmpty ? .red : .primary)
            }
            if includeRegex == nil && !includeRegexText.isEmpty {
                Text("包含正则非法")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.red)
            }
            if excludeRegex == nil && !excludeRegexText.isEmpty {
                Text("排除正则非法")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.02))
    }

    /// 白 / 黑名单 chip 行（从指令库页签「加入白名单 / 黑名单」或行内 + 添加）。
    private var filterChipsBar: some View {
        HStack(alignment: .top, spacing: 10) {
            chipRow(title: "只抓", color: Color(lobbyRGB: 0x3B82F6),
                    commands: $includeCommands)
            chipRow(title: "过滤", color: Color(lobbyRGB: 0xF59E0B),
                    commands: $excludeCommands)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.03))
    }

    private func chipRow(title: String, color: Color, commands: Binding<[String]>) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
            ForEach(commands.wrappedValue, id: \.self) { command in
                HStack(spacing: 3) {
                    Text(command)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Button {
                        commands.wrappedValue.removeAll { $0 == command }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.16)))
                .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
            }
            Menu {
                ForEach(session.commandCatalog.entries) { entry in
                    Button {
                        if !commands.wrappedValue.contains(entry.command) {
                            commands.wrappedValue.append(entry.command)
                        }
                    } label: {
                        Label("\(entry.chineseName) · \(entry.command)", systemImage: entry.isHighRisk ? "exclamationmark.triangle" : "circle.fill")
                    }
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(color)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("从指令库添加（精确匹配；指令库页签可批量管理）")
            if commands.wrappedValue.isEmpty {
                Text("空 = 不过滤")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $directionFilter) {
                Text("全部").tag(0)
                Text("发送").tag(1)
                Text("接收").tag(2)
            }
            .pickerStyle(.segmented)
            .frame(width: 168)
            Toggle(isOn: $hideHeartbeat) {
                Text("排除心跳").font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .toggleStyle(.checkbox)
            .fixedSize()
            HStack(spacing: 4) {
                Text("搜索")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("搜命令 / 内容摘要", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }
            Text("\(filteredFrames.count) / \(captureSession.frames.count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("显示条数 / 留存总条数")
            chipButton(icon: "trash", label: "清空") {
                capture.clear(accountID: account.id)
                selectedPacketID = nil
            }
            chipButton(icon: "square.and.arrow.up", label: "导出") {
                exportFrames()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func chipButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(label).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }

    /// 页面回执行：只在窗口开着时展示（跟随 capture.pageDiagnostics）。
    @ViewBuilder
    private var pageDiagnosticsLine: some View {
        if let diagnostics = capture.pageDiagnostics[account.id] {
            HStack(spacing: 5) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(diagnostics)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(diagnostics.contains("no-handler")
                                     ? Color(lobbyRGB: 0xF59E0B) : .white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.02))
        }
    }

    // MARK: 列表（抓包流）

    private var packetList: some View {
        List(selection: $selectedPacketID) {
            ForEach(filteredFrames) { packet in
                PacketRow(packet: packet,
                          displayName: session.commandCatalog.displayName(for: packet.command))
                    .tag(packet.id)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(selectedPacketID == packet.id
                                  ? Color.cyan.opacity(0.14)
                                  : (packet.direction == "send"
                                     ? Color(lobbyRGB: 0x3B82F6).opacity(0.05)
                                     : Color(lobbyRGB: 0x22C55E).opacity(0.05)))
                    )
                    // 右键 = 把该指令直接加进过滤（白名单 / 黑名单 / 包含正则 / 排除正则）。
                    .contextMenu {
                        Button("加入「只抓」白名单") {
                            if !includeCommands.contains(packet.command) {
                                includeCommands.append(packet.command)
                            }
                        }
                        Button("加入「过滤」黑名单") {
                            if !excludeCommands.contains(packet.command) {
                                excludeCommands.append(packet.command)
                            }
                        }
                        Divider()
                        Button("追加到「包含正则」") {
                            includeRegexText = appendRegexAlternative(includeRegexText,
                                                                      command: packet.command)
                        }
                        Button("追加到「排除正则」") {
                            excludeRegexText = appendRegexAlternative(excludeRegexText,
                                                                      command: packet.command)
                        }
                        Divider()
                        Button("复制命令名") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(packet.command, forType: .string)
                        }
                        Button("复制 JSON") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(packet.detail, forType: .string)
                        }
                    }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if captureSession.frames.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 26, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                    Text(isCapturing ? "等待游戏流量…" : "未在抓包")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("开始抓包后，在游戏里做任意操作即可看到 WSS 帧\n右键任意帧可直接加入过滤")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            } else if filteredFrames.isEmpty {
                Text("没有匹配过滤条件的帧")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 正则追加：cmd 做字面转义后用 `|` 并入现有表达式（空则直接成为表达式）。
    private func appendRegexAlternative(_ current: String, command: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: command)
        if current.trimmingCharacters(in: .whitespaces).isEmpty {
            return escaped
        }
        return current + "|" + escaped
    }

    // MARK: 详情（抓包流）

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let packet = selectedPacket {
                detailHeader(packet)
                Divider().overlay(Color.white.opacity(0.08))
                ScrollView {
                    // 默认压缩单行；「展开」时对当前选中的帧懒美化（存储始终是压缩串）。
                    Text(jsonPretty ? JSONBeautifier.pretty(packet.detail) : packet.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.88))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 24, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                    Text("选择左侧的帧查看解码详情")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("↩ = 配对响应 · 推 = 服务端主动推送")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func detailHeader(_ packet: CapturedPacket) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(packet.command)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(packet.direction == "send" ? Color(lobbyRGB: 0x6AA9F8) : Color(lobbyRGB: 0x4ADE80))
                    .lineLimit(1)
                    .textSelection(.enabled)
                directionBadge(packet)
                Text(session.commandCatalog.displayName(for: packet.command))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer(minLength: 8)
                // JSON 视图模式：默认压缩单行；展开 = 缩进美化（只对当前选中的帧懒计算）。
                Picker("", selection: $jsonPretty) {
                    Text("压缩").tag(false)
                    Text("展开").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
                .help("JSON 内容的显示格式（导出始终是压缩单行）")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(packet.detail, forType: .string)
                } label: {
                    Label("复制 JSON", systemImage: "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 10) {
                Text(packet.timeText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("\(packet.byteCount) B")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let seq = packet.seq { Text("seq=\(seq)").miniMeta }
                if let ack = packet.ack { Text("ack=\(ack)").miniMeta }
                if packet.truncated {
                    Text("已截断")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(lobbyRGB: 0xF59E0B))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
    }

    private func directionBadge(_ packet: CapturedPacket) -> some View {
        Text(packet.direction == "send" ? "↑ 发送" : "↓ 接收")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(packet.direction == "send" ? Color(lobbyRGB: 0x3B82F6) : Color(lobbyRGB: 0x22C55E))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill((packet.direction == "send"
                                        ? Color(lobbyRGB: 0x3B82F6)
                                        : Color(lobbyRGB: 0x22C55E)).opacity(0.12)))
    }

    // MARK: 导出

    private func exportFrames() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "抓包-\(account.nickname)-\(Int(Date().timeIntervalSince1970)).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let data = session.capture.exportPayload(accountID: account.id) else {
                session.statusMessage = "导出失败：没有可导出的抓包数据。"
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                LobbyLog.info("[capture] 导出 %ld 条到 %@", captureSession.frames.count, url.path)
            } catch {
                session.statusMessage = "导出失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - 列表行

/// 列表行：方向 | 命令 + 中文名/摘要 | 配对标记 | 时间 + 字节。
private struct PacketRow: View {
    let packet: CapturedPacket
    /// 指令库展示名（渲染前查好传入，行内不做查找）。
    let displayName: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: packet.direction == "send" ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(packet.direction == "send"
                                 ? Color(lobbyRGB: 0x3B82F6) : Color(lobbyRGB: 0x22C55E))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(packet.command)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if packet.kind == "text" {
                        Text("TXT")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(lobbyRGB: 0xF59E0B))
                    }
                    // 配对 / 推送标记
                    if packet.direction == "recv", packet.matchedRequestUUID != nil {
                        Text("↩")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(lobbyRGB: 0x4ADE80))
                            .help("已配对到同名请求")
                    }
                    if packet.isPush {
                        Text("推")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(lobbyRGB: 0xA78BFA))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color(lobbyRGB: 0xA78BFA).opacity(0.16)))
                            .help("服务端主动推送（时间窗内没有同名请求）")
                    }
                    if packet.direction == "send", packet.matchedResponseUUID != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(lobbyRGB: 0x4ADE80))
                            .help("已收到响应")
                    }
                }
                HStack(spacing: 4) {
                    if displayName != packet.command {
                        Text(displayName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color(lobbyRGB: 0x93C5FD))
                            .lineLimit(1)
                    }
                    if let summary = packet.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(packet.timeText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    if let roundTrip = packet.roundTripMs {
                        Text(String(format: "%.0fms", roundTrip))
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(lobbyRGB: 0x4ADE80).opacity(0.8))
                    }
                    Text("\(packet.byteCount)B")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 配对页签

/// 请求-响应成对视图。
///
/// 组织方式 = 「业务序号对齐」（与引擎侧配对算法同一口径）：每个业务请求一行，
/// 展开它的响应（含往返耗时）；无响应的请求标 ⏳（在途 / 服务端未回）；服务端
/// 主动推送单独列在推送区。点行 = 选中该帧并切到抓包流看详情。
private struct PairingPane: View {
    @ObservedObject var session: LobbySessionModel
    @ObservedObject var captureSession: PacketCaptureSession
    @Binding var selectedPacketID: UUID?
    /// JSON 视图模式（与抓包流详情面板共用；默认压缩）。
    let jsonPretty: Bool
    let switchToStream: () -> Void

    /// 一行 = 一个业务请求 + 它的响应（可能没有）。
    struct PairRow: Identifiable {
        let request: CapturedPacket
        let index: Int
        let response: CapturedPacket?
        var id: UUID { request.id }
    }

    /// 指令库展示名缓存（一次构建，避免行渲染逐条查找）。
    private var displayNames: [String: String] {
        var map: [String: String] = [:]
        for packet in captureSession.frames {
            if map[packet.command] == nil {
                map[packet.command] = session.commandCatalog.displayName(for: packet.command)
            }
        }
        return map
    }

    private var pairRows: [PairRow] {
        let lookup = Dictionary(uniqueKeysWithValues: captureSession.frames.map { ($0.id, $0) })
        var rows: [PairRow] = []
        var index = 0
        for packet in captureSession.frames {
            guard packet.direction == "send",
                  !PacketCaptureWindowView.systemCommands.contains(packet.command) else { continue }
            index += 1
            rows.append(PairRow(request: packet,
                                index: index,
                                response: packet.matchedResponseUUID.flatMap { lookup[$0] }))
        }
        return rows
    }

    private var pushes: [CapturedPacket] {
        captureSession.frames.filter { $0.direction == "recv" && $0.isPush }
    }

    private var unansweredCount: Int {
        pairRows.filter { $0.response == nil }.count
    }

    var body: some View {
        let names = displayNames
        List {
            Section {
                ForEach(pairRows) { row in
                    PairRowView(row: row,
                                names: names,
                                jsonPretty: jsonPretty,
                                selectedPacketID: $selectedPacketID,
                                switchToStream: switchToStream)
                }
            } header: {
                Text("请求 → 响应（\(pairRows.count) 对，\(unansweredCount) 条无响应）· 点 ⌄ 展开两帧 JSON")
            }
            if !pushes.isEmpty {
                Section {
                    ForEach(pushes) { packet in
                        pushRow(packet, names: names)
                    }
                } header: {
                    Text("服务端推送（\(pushes.count)，时间窗内没有对应请求）")
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if captureSession.frames.isEmpty {
                Text("暂无帧。开始抓包后这里的配对会实时更新。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pushRow(_ packet: CapturedPacket, names: [String: String]) -> some View {
        Button {
            selectedPacketID = packet.id
            switchToStream()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(lobbyRGB: 0xA78BFA))
                Text(names[packet.command] ?? packet.command)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(packet.command)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let seq = packet.seq {
                    Text("srvSeq=\(seq)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                Text(packet.timeText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 配对单元视图：请求行 + 响应行（缩进），⌄ 展开后**内联显示两帧的 JSON 内容**
/// （跟随全局「压缩/展开」模式；默认压缩——存储与显示口径一致，JSON 文本可选中复制）。
private struct PairRowView: View {
    let row: PairingPane.PairRow
    let names: [String: String]
    let jsonPretty: Bool
    @Binding var selectedPacketID: UUID?
    let switchToStream: () -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // ── 请求行（右侧展开按钮：显眼胶囊 + 独立命中区，不与行点击混淆）──
            HStack(spacing: 8) {
                requestButton
                expandButton
            }
            // ── 响应行（收起态摘要）──
            if let response = row.response {
                responseLine(response)
            } else {
                noResponseLine
            }
            // ── 展开态：两帧 JSON 内容内联 ──
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    jsonBlock(label: "请求", packet: row.request,
                              tint: Color(lobbyRGB: 0x3B82F6))
                    if let response = row.response {
                        jsonBlock(label: "响应", packet: response,
                                  tint: Color(lobbyRGB: 0x22C55E))
                    }
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // 展开收起的动画挂在行容器上：高度变化整体平滑（List 行内 withAnimation 不连贯）。
        .animation(.easeInOut(duration: 0.18), value: expanded)
        .padding(.vertical, 2)
    }

    /// 展开按钮：青色胶囊（图标 + 文字），醒目且命中区大——灰色小圆图标
    /// 太淡太小还贴着行点击区，实测经常误触跳转抓包流。
    private var expandButton: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                Text("JSON")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(expanded ? Color.white : Color(lobbyRGB: 0x67E8F9))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(expanded ? Color.cyan.opacity(0.30) : Color.cyan.opacity(0.14)))
            .overlay(Capsule().strokeBorder(Color.cyan.opacity(expanded ? 0.75 : 0.45), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(expanded ? "收起 JSON" : "展开请求与响应的 JSON 内容")
    }

    private var requestButton: some View {
        Button {
            selectedPacketID = row.request.id
            switchToStream()
        } label: {
            HStack(spacing: 6) {
                Text("#\(row.index)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 30, alignment: .leading)
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(lobbyRGB: 0x3B82F6))
                Text(names[row.request.command] ?? row.request.command)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(row.request.command)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let seq = row.request.seq {
                    Text("seq=\(seq)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                Text(row.request.timeText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 6)
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func responseLine(_ response: CapturedPacket) -> some View {
        Button {
            selectedPacketID = response.id
            switchToStream()
        } label: {
            HStack(spacing: 6) {
                Text("└")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 30, alignment: .leading)
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(lobbyRGB: 0x22C55E))
                Text(response.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(lobbyRGB: 0x4ADE80))
                    .lineLimit(1)
                if let roundTrip = response.roundTripMs {
                    Text(String(format: "%.0f ms", roundTrip))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(lobbyRGB: 0x4ADE80).opacity(0.85))
                }
                Spacer(minLength: 4)
                Text(response.timeText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 10)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var noResponseLine: some View {
        HStack(spacing: 6) {
            Text("└")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .leading)
            Label("无响应（在途或服务端未回）", systemImage: "hourglass")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
    }

    /// 一帧的 JSON 内容块（跟随全局压缩/展开模式；高度封顶防大包撑爆列表）。
    private func jsonBlock(label: String, packet: CapturedPacket, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
                Text(packet.command)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(packet.byteCount) B")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            ScrollView {
                Text(jsonPretty ? JSONBeautifier.pretty(packet.detail) : packet.detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.82))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.10)))
        }
        .padding(.leading, 10)
    }
}

// MARK: - 流式布局（胶囊卡片横+竖排列）

/// 自定义 Layout：子视图从左到右排列，放不下就换行（标签云 / 胶囊组）。
/// 用于发送页签的指令卡片分类流（List 竖列选指令太难找，用户确认改胶囊卡片）。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 发送指令页签

/// 发送指令：从指令库选指令（可搜索）→ 参数 JSON 编辑（预填模板）→ 二次确认发送。
/// 发送是**真实游戏操作**（消耗资源类红色警示）；走游戏已建立的连接，
/// 注入帧自然进抓包流，响应配对照常工作。
private struct SendCommandPane: View {
    @ObservedObject var session: LobbySessionModel
    let account: GameAccount
    @ObservedObject var capture: PacketCaptureController
    @ObservedObject var catalog: GameCommandStore
    /// 指令库页签「填入发送」的跨页签联动。
    @Binding var draftCommand: String?
    /// JSON 视图模式（与抓包流详情面板共用；默认压缩）。
    let jsonPretty: Bool

    @State private var search = ""
    @State private var selectedCommandID: String?
    @State private var paramsDraft = "{}"
    @State private var sendStatus: String?
    @State private var sendStatusIsError = false
    @State private var confirmCandidate: GameCommandEntry?
    /// 参数模式：自动 = 用指令库默认参数模板（推荐）；手动 = 编辑器可改。
    @State private var paramModeAuto = true
    /// ack/seq 编址模式（实测：时间戳 seq 服务端拒收；跟随游戏序列服务端才认）。
    @State private var addressing: SeqAddressing = .followGame
    @State private var manualAckText = ""
    @State private var manualSeqText = ""
    /// 最近一次发送捕获到的响应帧（页面底部结果窗口；靠抓包配对定位）。
    @State private var resultResponse: CapturedPacket?
    @State private var responseWatchTask: Task<Void, Never>?

    /// 搜索过滤后的条目。
    private var filteredEntries: [GameCommandEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return catalog.entries }
        return catalog.entries.filter {
            $0.command.localizedCaseInsensitiveContains(query)
                || $0.chineseName.localizedCaseInsensitiveContains(query)
        }
    }

    /// 已识别（内置确认 / 语义推断 / 自定义）按分类分组。
    private var identifiedGroups: [(category: String, entries: [GameCommandEntry])] {
        let groups = Dictionary(grouping: filteredEntries.filter { $0.origin != "discovered" },
                                by: \.category)
        return catalog.categories.compactMap { category in
            guard let entries = groups[category] else { return nil }
            return (category, entries)
        }
    }

    /// 未识别新指令（抓包自动发现、还没补中文名的）——单独一个区。
    private var discoveredEntries: [GameCommandEntry] {
        filteredEntries.filter { $0.origin == "discovered" }
    }

    /// 分类稳定色：同分类恒同色（unicode 求和散列，跨启动不变）。
    private static let categoryPalette: [Color] = [
        Color(lobbyRGB: 0x3B82F6), Color(lobbyRGB: 0x22C55E), Color(lobbyRGB: 0xF59E0B),
        Color(lobbyRGB: 0xA78BFA), Color(lobbyRGB: 0x22D3EE), Color(lobbyRGB: 0xF472B6),
        Color(lobbyRGB: 0xFACC15), Color(lobbyRGB: 0xFB7185), Color(lobbyRGB: 0x34D399),
        Color(lobbyRGB: 0x60A5FA)
    ]

    private func categoryColor(_ category: String) -> Color {
        let sum = category.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Self.categoryPalette[sum % Self.categoryPalette.count]
    }

    /// 自动模式下实际将使用的 ack / seq 预览。
    private var previewAck: Int64 {
        capture.session(forAccountID: account.id)?.lastServerSeq ?? 0
    }

    private var selectedEntry: GameCommandEntry? {
        guard let selectedCommandID else { return nil }
        return catalog.lookup(selectedCommandID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            commandPicker
            paramsEditor
            statusLine
            resultPanel
            historyList
            Spacer(minLength: 0)
        }
        .padding(12)
        .onDisappear {
            responseWatchTask?.cancel()
        }
        .onAppear {
            if selectedCommandID == nil, let first = catalog.entries.first {
                selectedCommandID = first.id
                paramsDraft = first.defaultParamsJSON
            }
        }
        .onChange(of: selectedCommandID) { _, newValue in
            guard let id = newValue, let entry = catalog.lookup(id) else { return }
            paramsDraft = entry.defaultParamsJSON
            sendStatus = nil
        }
        .onChange(of: draftCommand) { _, newValue in
            guard let command = newValue else { return }
            draftCommand = nil
            if let entry = catalog.lookup(command) {
                selectedCommandID = entry.id
                paramsDraft = entry.defaultParamsJSON
                sendStatus = nil
            }
        }
        .confirmationDialog(
            confirmText,
            isPresented: Binding(
                get: { confirmCandidate != nil },
                set: { if !$0 { confirmCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            let confirmRole: ButtonRole? = confirmCandidate?.isHighRisk == true ? .destructive : nil
            Button("确认发送", role: confirmRole) {
                if let entry = confirmCandidate {
                    send(entry)
                }
                confirmCandidate = nil
            }
            Button("取消", role: .cancel) { confirmCandidate = nil }
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: 子视图（每条子表达式 ≤ 2 段链——本项目的 type-check 红线）

    /// 指令选择区：**已识别**（分类分组 + 彩色胶囊流）与**未识别新指令**两个区。
    private var commandPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("指令")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("搜索指令（中文名或 cmd）", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(maxWidth: 320)
                if let entry = selectedEntry {
                    riskBadge(entry)
                    Text("已选：\(entry.chineseName)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(lobbyRGB: 0x67E8F9))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // ── 已识别指令（按分类着色，紧凑排列）──
                    ForEach(identifiedGroups, id: \.category) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.category)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(categoryColor(group.category))
                            FlowLayout(spacing: 3) {
                                ForEach(group.entries) { entry in
                                    commandCard(entry, tint: categoryColor(group.category))
                                }
                            }
                        }
                    }
                    // ── 未识别新指令（独立区，紫色系）──
                    if !discoveredEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("未识别新指令（\(discoveredEntries.count)，可在指令库页签补名）")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color(lobbyRGB: 0xA78BFA))
                            FlowLayout(spacing: 3) {
                                ForEach(discoveredEntries) { entry in
                                    commandCard(entry, tint: Color(lobbyRGB: 0xA78BFA))
                                }
                            }
                        }
                    }
                }
                .padding(2)
            }
            .frame(height: 190)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03)))
        }
    }

    /// 指令胶囊卡片：分类着色（背景浅 / 描边中），高危橙警示覆盖，选中青色高亮。
    private func commandCard(_ entry: GameCommandEntry, tint: Color) -> some View {
        let isSelected = selectedCommandID == entry.id
        return Button {
            selectedCommandID = entry.id
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 2) {
                    Text(entry.chineseName)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                    if entry.isHighRisk {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(Color(lobbyRGB: 0xF59E0B))
                    }
                }
                Text(entry.command)
                    .font(.system(size: 8, design: .monospaced))
                    .opacity(0.55)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.white.opacity(isSelected ? 1 : 0.82))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(isSelected ? Color.cyan.opacity(0.30) : tint.opacity(0.13)))
            .overlay(Capsule().strokeBorder(isSelected ? Color.cyan.opacity(0.85) : tint.opacity(0.4), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(entry.chineseName) · \(entry.command)\(entry.isHighRisk ? "\n⚠️ 高危：可能消耗资源" : "")")
    }

    /// 参数编辑区：自动模式（模板只读）/ 手动模式（编辑器可改）+ ack/seq 编址行。
    private var paramsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("参数 (JSON)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                // 参数模式：自动 = 用指令库默认模板；手动 = 编辑器可改。
                Picker("", selection: $paramModeAuto) {
                    Text("自动参数").tag(true)
                    Text("手动参数").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .help("自动参数 = 使用指令库默认参数模板；手动参数 = 自行编辑 JSON")
                if paramModeAuto {
                    Text("（使用指令库模板）")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                } else {
                    Button("还原模板") {
                        if let entry = selectedEntry {
                            paramsDraft = entry.defaultParamsJSON
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(lobbyRGB: 0x93C5FD))
                }
                Spacer(minLength: 0)
                if !canSend {
                    Label("实例未运行", systemImage: "pause.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(lobbyRGB: 0xF59E0B))
                }
                sendButton
            }
            TextEditor(text: $paramsDraft)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.12)))
                .frame(height: 100)
                .disabled(paramModeAuto)
                .opacity(paramModeAuto ? 0.75 : 1)
            ackSeqRow
        }
    }

    /// ack / seq 编址行：跟随游戏（推荐）/ 时间戳 / 手动指定。
    private var ackSeqRow: some View {
        HStack(spacing: 8) {
            Text("ack / seq")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: $addressing) {
                ForEach(SeqAddressing.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .help("跟随游戏 = seq 取游戏最近业务请求 + 1（服务端只认连续序列，实测时间戳 seq 被拒收）；时间戳 = 独立编址（实验）；手动 = 自行指定")
            switch addressing {
            case .followGame:
                Text("ack=\(previewAck) · seq=\(previewSeq)（游戏最近 seq + 1）")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .help("注意：游戏自己的下一个请求可能与我们撞 seq，服务端去重行为未实证——如游戏出现卡顿请立即停止注入")
            case .timestamp:
                Text("seq=发送时刻时间戳（实测服务端拒收 seq 跳跃，仅供实验）")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color(lobbyRGB: 0xF59E0B).opacity(0.7))
            case .manual:
                metaField("ack", text: $manualAckText, placeholder: "如 41")
                metaField("seq", text: $manualSeqText, placeholder: "如 42")
                Text("⚠️ 手工编址可能与游戏自身请求冲突，仅供实验")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(lobbyRGB: 0xF59E0B))
            }
            Spacer(minLength: 0)
        }
    }

    /// 「跟随游戏」模式的 seq 预览。
    private var previewSeq: Int64 {
        (capture.session(forAccountID: account.id)?.lastClientSeq ?? 0) + 1
    }

    private func metaField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 130)
        }
    }

    private var sendButton: some View {
        Button {
            if let entry = selectedEntry {
                confirmCandidate = entry
            }
        } label: {
            Label("发送", systemImage: "paperplane.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Capsule().fill(sendButtonColor))
        }
        .buttonStyle(.plain)
        .disabled(selectedEntry == nil || !canSend)
    }

    /// 发送状态行。
    @ViewBuilder
    private var statusLine: some View {
        if let sendStatus {
            let tint: Color = sendStatusIsError
                ? Color(red: 1.0, green: 0.45, blue: 0.42)
                : Color(lobbyRGB: 0x4ADE80)
            Label(sendStatus, systemImage: sendStatusIsError ? "xmark.circle" : "checkmark.circle")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(2)
        }
    }

    // MARK: 响应结果窗口

    /// 页面底部结果窗口：发送后捕获到的响应帧内容（靠抓包配对定位——
    /// 注入帧经 send 包装进抓包流，业务序号对齐会把它和响应配上；
    /// 用 seq 精确定位注入帧，因此要求抓包处于开启状态）。
    @ViewBuilder
    private var resultPanel: some View {
        if let response = resultResponse {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("响应结果")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(lobbyRGB: 0x4ADE80))
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(lobbyRGB: 0x22C55E))
                    Text(response.command)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(lobbyRGB: 0x4ADE80))
                        .lineLimit(1)
                    if let roundTrip = response.roundTripMs {
                        Text(String(format: "%.0f ms", roundTrip))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(lobbyRGB: 0x4ADE80).opacity(0.85))
                    }
                    Spacer(minLength: 8)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(response.detail, forType: .string)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.8))
                }
                ScrollView {
                    Text(jsonPretty ? JSONBeautifier.pretty(response.detail) : response.detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(height: 130)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(lobbyRGB: 0x22C55E).opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(lobbyRGB: 0x22C55E).opacity(0.18)))
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(lobbyRGB: 0x22C55E).opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(lobbyRGB: 0x22C55E).opacity(0.22)))
        }
    }

    /// 发送后监视配对响应：用**注入帧自己的 seq**（时间戳模式全局唯一 / 跟随模式
    /// 序列唯一）在抓包流里定位 send 帧 → 它的配对响应。轮询 10s（250ms 一次，
    /// 抓包流 0.25s 批量上屏 + 配对在摄入时完成）；抓包未开启 / 超时未收到 →
    /// 状态行明确提示「未捕获响应」，区分「服务端没回」和「没抓到」。
    private func startResponseWatch(_ record: SendRecord) {
        resultResponse = nil
        responseWatchTask?.cancel()
        guard let seq = record.seqUsed else { return }
        let deadline = Date().addingTimeInterval(10)
        responseWatchTask = Task { @MainActor in
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let session = capture.session(forAccountID: account.id) else { continue }
                if let sent = session.frames.first(where: {
                    $0.direction == "send" && $0.command == record.command && $0.seq == seq
                }), let responseID = sent.matchedResponseUUID,
                   let response = session.frames.first(where: { $0.id == responseID }) {
                    resultResponse = response
                    return
                }
            }
            if !Task.isCancelled {
                sendStatus = (sendStatus ?? "") + " · 10s 未捕获响应（服务端未回 / 抓包已停 / 帧被挤出留存）"
                sendStatusIsError = true
            }
        }
    }

    /// 发送历史（点击回填）。
    @ViewBuilder
    private var historyList: some View {
        if !capture.sendHistory.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("发送历史（点击回填参数）")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(capture.sendHistory) { record in
                            historyRow(record)
                        }
                    }
                }
                .frame(maxHeight: 130)
            }
        }
    }

    private func historyRow(_ record: SendRecord) -> some View {
        let statusColor: Color = record.succeeded
            ? Color(lobbyRGB: 0x4ADE80)
            : Color(red: 1.0, green: 0.45, blue: 0.42)
        return Button {
            if let entry = catalog.lookup(record.command) {
                selectedCommandID = entry.id
            }
            paramsDraft = record.paramsJSON
        } label: {
            HStack(spacing: 6) {
                Text(record.timeText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(record.chineseName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(record.command)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let ack = record.ackUsed, let seq = record.seqUsed {
                    Text("ack=\(ack) seq=\(seq)")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text(record.status)
                    .font(.system(size: 9))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var canSend: Bool {
        session.runningAccountIDs.contains(account.id)
            && session.pool.existingSurface(forAccountID: account.id) != nil
    }

    private var sendButtonColor: Color {
        guard let entry = selectedEntry else { return .gray }
        return entry.isHighRisk ? Color(red: 0.85, green: 0.33, blue: 0.28) : Color(lobbyRGB: 0x2563EB)
    }

    private var confirmText: String {
        guard let entry = confirmCandidate else { return "发送指令" }
        return entry.isHighRisk ? "⚠️ 高危指令：\(entry.chineseName)" : "发送指令：\(entry.chineseName)"
    }

    private var confirmMessage: String {
        guard let entry = confirmCandidate else { return "" }
        let effectiveParams = paramModeAuto ? (selectedEntry?.defaultParamsJSON ?? paramsDraft) : paramsDraft
        var lines = "cmd = \(entry.command)\n参数 = \(effectiveParams)\n编址 = \(addressing.rawValue)\n\n将注入到「\(account.nickname)」的游戏连接并真实执行。"
        switch addressing {
        case .followGame:
            lines += "\n注意：游戏自己的下一个请求可能与我们撞 seq，若游戏出现卡顿请立即停止注入。"
        case .manual:
            lines += "\nack / seq = 手动指定（与游戏自身请求撞 seq 可能被服务端去重）。"
        case .timestamp:
            lines += "\n实测时间戳 seq 会被服务端拒收（仅供实验）。"
        }
        if entry.isHighRisk {
            lines += "\n\n该指令可能消耗游戏资源（购买 / 招募 / 抽取类），请确认参数。"
        }
        return lines
    }

    private func riskBadge(_ entry: GameCommandEntry) -> some View {
        Group {
            if entry.isHighRisk {
                Label("高危：可能消耗资源", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(lobbyRGB: 0xF59E0B))
            }
        }
    }

    private func send(_ entry: GameCommandEntry) {
        guard let instance = session.pool.existingSurface(forAccountID: account.id) else { return }
        // 自动参数模式：直接用指令库模板（编辑器在自动态只读显示同一份内容）。
        let effectiveParams = paramModeAuto ? entry.defaultParamsJSON : paramsDraft
        // 手动 ack/seq 解析（非法值直接提示，不发送）。
        var manualAck: Int64?
        var manualSeq: Int64?
        if addressing == .manual {
            manualAck = Int64(manualAckText.trimmingCharacters(in: .whitespaces))
            manualSeq = Int64(manualSeqText.trimmingCharacters(in: .whitespaces))
            if manualAck == nil || manualSeq == nil {
                sendStatus = "手动 ack/seq 必须是整数。"
                sendStatusIsError = true
                return
            }
        }
        sendStatus = "发送中…"
        sendStatusIsError = false
        Task { @MainActor in
            let record = await capture.sendCommand(accountID: account.id,
                                                   instance: instance,
                                                   command: entry.command,
                                                   chineseName: entry.chineseName,
                                                   paramsJSON: effectiveParams,
                                                   addressing: addressing,
                                                   manualAck: manualAck,
                                                   manualSeq: manualSeq)
            var detailText = record.status
            if record.succeeded, let ack = record.ackUsed, let seq = record.seqUsed {
                detailText += "（ack=\(ack) seq=\(seq)）"
                if capture.isCapturing(accountID: account.id) {
                    detailText += " · 等待响应…"
                } else {
                    detailText += " · 抓包未开启，无法追踪响应"
                }
            }
            sendStatus = detailText
            sendStatusIsError = !record.succeeded
            if record.succeeded {
                startResponseWatch(record)
            }
        }
    }
}

// MARK: - 指令库页签

/// 指令库：搜索 / 分组过滤 + 添加自定义指令 + 行操作（白名单 / 黑名单 / 填入发送 / 编辑 / 删除）。
private struct CommandCatalogPane: View {
    @ObservedObject var catalog: GameCommandStore
    @Binding var includeCommands: [String]
    @Binding var excludeCommands: [String]
    @Binding var sendDraftCommand: String?

    @State private var search = ""
    @State private var categoryFilter = "全部分组"
    @State private var addSheetPresented = false
    @State private var editingEntry: GameCommandEntry?

    private var rows: [GameCommandEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.entries.filter { entry in
            guard categoryFilter == "全部分组" || entry.category == categoryFilter else { return false }
            if query.isEmpty { return true }
            return entry.command.localizedCaseInsensitiveContains(query)
                || entry.chineseName.localizedCaseInsensitiveContains(query)
        }
    }

    private var discoveredCount: Int {
        catalog.entries.filter { $0.origin == "discovered" }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("指令库")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(catalog.entries.count) 条")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if discoveredCount > 0 {
                    Text("含 \(discoveredCount) 条抓包发现（可编辑补名）")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(lobbyRGB: 0xA78BFA))
                }
                Spacer(minLength: 8)
                Picker("", selection: $categoryFilter) {
                    Text("全部分组").tag("全部分组")
                    ForEach(catalog.categories, id: \.self) { category in
                        Text(category).tag(category)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 130)
                TextField("搜索指令", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(maxWidth: 220)
                Button {
                    addSheetPresented = true
                } label: {
                    Label("添加指令", systemImage: "plus.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color(lobbyRGB: 0x2563EB)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().overlay(Color.white.opacity(0.08))
            List {
                ForEach(rows) { entry in
                    CatalogRow(entry: entry,
                               includeCommands: $includeCommands,
                               excludeCommands: $excludeCommands,
                               sendDraftCommand: $sendDraftCommand,
                               onEdit: { editingEntry = entry },
                               onDelete: { catalog.remove(entry) })
                        .listRowBackground(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.03)))
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .sheet(isPresented: $addSheetPresented) {
            AddCommandSheet(catalog: catalog, existing: nil)
        }
        .sheet(item: $editingEntry) { entry in
            AddCommandSheet(catalog: catalog, existing: entry)
        }
    }
}

/// 指令库行：中文名 + cmd + 分组 + 来源徽标 + 快捷操作。
private struct CatalogRow: View {
    let entry: GameCommandEntry
    @Binding var includeCommands: [String]
    @Binding var excludeCommands: [String]
    @Binding var sendDraftCommand: String?
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var originBadge: (String, Color)? {
        switch entry.origin {
        case "inferred": return ("推断", Color(lobbyRGB: 0xA78BFA))
        case "custom": return ("自定义", Color(lobbyRGB: 0x34D399))
        case "discovered": return ("发现", Color(lobbyRGB: 0xA78BFA))
        default: return nil // 内置确认不挂徽标
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(entry.chineseName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(entry.category)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                    if let origin = originBadge {
                        Text(origin.0)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(origin.1)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(origin.1.opacity(0.14)))
                    }
                    if entry.isHighRisk {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(lobbyRGB: 0xF59E0B))
                            .help("高危：可能消耗游戏资源")
                    }
                }
                Text(entry.command)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            rowButton(icon: "arrow.up.circle.fill", tint: Color(lobbyRGB: 0x3B82F6)) {
                toggle($includeCommands)
            }
            .help("加入「只抓」白名单（抓包流精确过滤）")
            rowButton(icon: "arrow.down.circle.fill", tint: Color(lobbyRGB: 0xF59E0B)) {
                toggle($excludeCommands)
            }
            .help("加入「过滤」黑名单（抓包流隐藏该指令）")
            rowButton(icon: "paperplane.fill", tint: Color(lobbyRGB: 0x93C5FD)) {
                sendDraftCommand = entry.command
            }
            .help("填入「发送指令」页签")
            // 行菜单：编辑 / 删除（自定义 / 发现可改可删；内置只读）。
            Menu {
                if isUserOwned {
                    Button("编辑…") { onEdit() }
                    Button("删除", role: .destructive) { onDelete() }
                } else {
                    Text("内置指令不可编辑")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 1)
    }

    /// 发现 / 自定义条目可编辑删除（编辑保存后转自定义）。
    private var isUserOwned: Bool {
        entry.origin == "custom" || entry.origin == "discovered"
    }

    private func toggle(_ list: Binding<[String]>) {
        if let index = list.wrappedValue.firstIndex(of: entry.command) {
            list.wrappedValue.remove(at: index)
        } else {
            list.wrappedValue.append(entry.command)
        }
    }

    private func rowButton(icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint.opacity(0.85))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 添加 / 编辑指令的表单。
private struct AddCommandSheet: View {
    @ObservedObject var catalog: GameCommandStore
    /// nil = 新增；非 nil = 编辑该条。
    let existing: GameCommandEntry?

    @Environment(\.dismiss) private var dismiss
    @State private var command = ""
    @State private var chineseName = ""
    @State private var category = ""
    @State private var paramsJSON = "{}"
    @State private var note = ""

    private var isValid: Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.contains(" ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "添加自定义指令" : "编辑指令")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
            formRow("指令 (cmd)") {
                TextField("如 role_getroleinfo", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(existing != nil && existing?.origin == nil)
            }
            formRow("中文名") {
                TextField("如 获取角色信息", text: $chineseName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            formRow("分组") {
                TextField("留空按 cmd 前缀自动归组", text: $category)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            formRow("默认参数模板 (JSON)") {
                TextEditor(text: $paramsJSON)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                    .frame(height: 90)
            }
            formRow("备注") {
                TextField("可选", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "添加" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear {
            if let existing {
                command = existing.command
                chineseName = existing.chineseName
                category = existing.category
                paramsJSON = existing.defaultParamsJSON
                note = existing.note
            }
        }
    }

    private func formRow(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func save() {
        var entry = GameCommandEntry(
            command: command.trimmingCharacters(in: .whitespaces),
            chineseName: chineseName.trimmingCharacters(in: .whitespaces).isEmpty
                ? command.trimmingCharacters(in: .whitespaces)
                : chineseName.trimmingCharacters(in: .whitespaces),
            category: category.trimmingCharacters(in: .whitespaces).isEmpty
                ? GameCommandStore.categoryForCommand(command)
                : category.trimmingCharacters(in: .whitespaces),
            defaultParamsJSON: paramsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "{}" : paramsJSON,
            note: note)
        if let existing {
            entry.origin = existing.origin // 编辑保留原来源徽标语义（发现 → 保存仍是发现，但已有名字）
        }
        catalog.upsert(entry)
        dismiss()
    }
}

// MARK: - 小工具

private extension Text {
    /// 详情头的元数据小字（seq= / ack=）。
    var miniMeta: some View {
        self.font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}
