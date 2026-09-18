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
        let contentRect = NSRect(x: 0, y: 0, width: 880, height: 600)
        let window = NSWindow(contentRect: contentRect,
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "抓包 · \(account.nickname)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 420)
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

// MARK: - 抓包窗口视图

/// 抓包窗口主视图。
///
/// 布局：顶栏（状态 + 开始/停止 + 清空 + 导出）
///     → 过滤栏（方向 / 包含命令 / 排除命令 / 排除心跳 / 搜索 / 计数）
///     → 列表（左）+ 详情（右）。
///
/// 过滤语义（对齐猫助手的 cmd 正则白/黑名单，改用多关键词子串匹配——排查时
/// 输入 `hero, task` 比 `[rR]eg[Ee]x` 顺手得多）：
///   · **包含**：命中任一关键词才显示（空 = 不过滤）；
///   · **排除**：命中任一关键词就隐藏（黑名单优先级最高）；
///   · **排除心跳**：一键滤掉 `heart_beat`（游戏 2s 一条，不排除必刷屏）；
///   · 关键词按逗号 / 空格 / 换行拆分，大小写不敏感，只匹配命令名（不搜 body）；
///   · **搜索**：另按命令 + 摘要全文搜（不受上面的关键词影响）。
/// 过滤是**窗口的视图状态**，不改留存——存量 5000 条随时重新过滤。
struct PacketCaptureWindowView: View {
    /// 心跳命令名（与游戏侧一致：`wsAgent.js` 的 `heartbeatCmd`，勿改）。
    static let heartbeatCommand = "heart_beat"

    @ObservedObject var session: LobbySessionModel
    /// 抓包控制器（capturing 状态驱动按钮高亮）。
    @ObservedObject private var capture: PacketCaptureController
    /// 本窗口的会话（frames 是唯一的上屏数据源）。
    @ObservedObject private var captureSession: PacketCaptureSession
    let account: GameAccount

    // 过滤状态（视图私有；改这些不重新抓包，只重算列表）
    @State private var directionFilter = 0 // 0 全部 1 发送 2 接收
    @State private var includeText = ""
    @State private var excludeText = ""
    @State private var hideHeartbeat = true
    @State private var searchText = ""
    @State private var selectedPacketID: UUID?

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

    // MARK: 过滤

    private static func keywords(in text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "，" || $0 == "、" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private var filteredFrames: [CapturedPacket] {
        let include = Self.keywords(in: includeText)
        let exclude = Self.keywords(in: excludeText)
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return captureSession.frames.filter { packet in
            switch directionFilter {
            case 1: if packet.direction != "send" { return false }
            case 2: if packet.direction != "recv" { return false }
            default: break
            }
            if hideHeartbeat, packet.command == Self.heartbeatCommand { return false }
            if !include.isEmpty, !include.contains(where: { packet.command.localizedCaseInsensitiveContains($0) }) {
                return false
            }
            if exclude.contains(where: { packet.command.localizedCaseInsensitiveContains($0) }) {
                return false
            }
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
            filterBar
            pageDiagnosticsLine
            Divider().overlay(Color.white.opacity(0.10))
            HStack(spacing: 0) {
                packetList
                    .frame(width: 360)
                Divider().overlay(Color.white.opacity(0.10))
                detailPane
            }
        }
        .background(Color(lobbyRGB: 0x14161B).ignoresSafeArea())
        // 页面侧代理诊断：常驻显示 + 5s 轮询。「没流量」时先看这行——
        // no-handler = 代理没进页面；hooked=0 = 游戏还没建 WS 连接；enabled=false = 开关没推上。
        .task {
            while !Task.isCancelled {
                session.pool.existingSurface(forAccountID: account.id)?.queryPacketCaptureStatus()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
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
            chipButton(icon: "trash", label: "清空") {
                capture.clear(accountID: account.id)
                selectedPacketID = nil
            }
            chipButton(icon: "square.and.arrow.up", label: "导出") {
                exportFrames()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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

    // MARK: 过滤栏

    private var filterBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $directionFilter) {
                Text("全部").tag(0)
                Text("发送").tag(1)
                Text("接收").tag(2)
            }
            .pickerStyle(.segmented)
            .frame(width: 168)
            filterField("包含命令", text: $includeText, placeholder: "如 hero, task（留空=不过滤）")
            filterField("排除命令", text: $excludeText, placeholder: "如 login_")
            Toggle(isOn: $hideHeartbeat) {
                Text("排除心跳").font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .toggleStyle(.checkbox)
            .fixedSize()
            filterField("搜索", text: $searchText, placeholder: "搜命令 / 内容摘要", flexible: true)
            Text("\(filteredFrames.count) / \(captureSession.frames.count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("显示条数 / 留存总条数")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.03))
    }

    private func filterField(_ label: String, text: Binding<String>, placeholder: String, flexible: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(maxWidth: flexible ? .infinity : 120)
        }
        .fixedSize(horizontal: !flexible, vertical: false)
    }

    // MARK: 列表

    private var packetList: some View {
        List(selection: $selectedPacketID) {
            ForEach(filteredFrames) { packet in
                PacketRow(packet: packet)
                    .tag(packet.id)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(selectedPacketID == packet.id
                                  ? Color.cyan.opacity(0.14)
                                  : (packet.direction == "send"
                                     ? Color(lobbyRGB: 0x3B82F6).opacity(0.05)
                                     : Color(lobbyRGB: 0x22C55E).opacity(0.05)))
                    )
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
                    Text("开始抓包后，在游戏里做任意操作即可看到 WSS 帧")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            } else if filteredFrames.isEmpty {
                Text("没有匹配过滤条件的帧")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("复制命令名") {
                if let packet = selectedPacket {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(packet.command, forType: .string)
                }
            }
        }
    }

    // MARK: 详情

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let packet = selectedPacket {
                detailHeader(packet)
                Divider().overlay(Color.white.opacity(0.08))
                ScrollView {
                    Text(packet.detail)
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
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func detailHeader(_ packet: CapturedPacket) -> some View {
        HStack(spacing: 10) {
            Text(packet.command)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(packet.direction == "send" ? Color(lobbyRGB: 0x6AA9F8) : Color(lobbyRGB: 0x4ADE80))
                .lineLimit(1)
                .textSelection(.enabled)
            directionBadge(packet)
            Text(packet.timeText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("\(packet.byteCount) B")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            if packet.truncated {
                Text("已截断")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(lobbyRGB: 0xF59E0B))
            }
            Spacer(minLength: 8)
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

/// 列表行：方向 | 命令 + 摘要 | 时间 + 字节。
private struct PacketRow: View {
    let packet: CapturedPacket

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
                }
                if let summary = packet.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(packet.timeText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("\(packet.byteCount)B")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
