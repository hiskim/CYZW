import Combine
import Foundation
import LobbyDomain
import LobbyIPC

// MARK: - 抓包 · 宿主侧控制器
//
// 与 `PacketCaptureScript`（页面侧抓原始字节）配套：这里做**解码 + 会话管理 + 导出**。
//
//   PageEvent.packet(PacketFrame) → base64 还原 → px 信封解封（`XorFrameCipher`）
//     → BON 解码（`Bon`）→ cmd / body 提取 → CapturedPacket → 会话（节流上屏）
//
// 解码放宿主的理由：① `XorFrameCipher` / `Bon` 都是现成的（与服务端协议逐字节对拍过）；
// ② 过滤条件（包含 / 排除 / 心跳 / 方向 / 搜索）是 UI 状态，放在宿主可以随时改、
// 对**全量留存**的帧重新过滤，页面侧只管上报原始帧，一条都不丢。
//
// 帧结构（与 `AccountProfileFetcher.roleInfoRequestFrame` 同源，实测口径）：
//
//   WS 帧 = x 信封（0x70 0x78 …）→ BON 明文 `{ cmd, ack, seq, time, body(binary) }`
//   body 是**内层再 BON 编码**的字节串（两层）。
//
// 容量与性能：
//   · 每会话留存上限 `maxFrames`（FIFO 挤掉最旧，计数记入 `droppedTotal`）；
//   · 页面 → 宿主的帧先进 `pending` 缓冲，0.25s 批量转正一次——BON 解码也在这一步，
//     避免「每条帧都触发一次 SwiftUI diff」造成的矩阵卡顿（列表是 5000 行级的）。
@MainActor
public final class PacketCaptureController: ObservableObject {
    /// 单会话留存上限。超出 FIFO 挤掉最旧（抓包窗口显示的是「最近 5000 条」）。
    public static let maxFrames = 5000

    /// 账号 ID → 抓包会话。窗口与列表都从这里取。
    @Published public private(set) var sessions: [String: PacketCaptureSession] = [:]
    /// 正在抓包的账号 ID（矩阵卡片按钮的高亮态）。
    @Published public private(set) var capturingAccountIDs: Set<String> = []

    /// 账号名缓存（导出 JSON 里带上，窗口标题也用）。
    private var accountNames: [String: String] = [:]

    /// 页面侧代理的诊断串（账号 ID → 最近一次 `capture.status()` 回执）。
    ///
    /// 为什么要有它：抓包「开了但没流量」的可能性不止一种——
    /// `no-handler` = 页面没装代理（构建产物旧 / 注入失败）；
    /// `hooked=0` = 代理装了但游戏还没 `new WebSocket`；
    /// `enabled=false` = 开关没推上去。窗口里常驻显示，一眼定性，不用捞日志。
    @Published public private(set) var pageDiagnostics: [String: String] = [:]

    public init() {}

    /// 记录一次页面侧诊断回执（实例查询回来后写入）。
    public func notePageDiagnostics(_ text: String, accountID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if pageDiagnostics[accountID] != trimmed {
            pageDiagnostics[accountID] = trimmed
        }
    }

    // MARK: - 会话生命周期

    public func isCapturing(accountID: String) -> Bool {
        capturingAccountIDs.contains(accountID)
    }

    /// 该账号是否已有留存数据（决定「抓包」按钮点开后窗口里是否有东西可看）。
    public func session(forAccountID accountID: String) -> PacketCaptureSession? {
        sessions[accountID]
    }

    /// 开始抓包（幂等：已在抓的账号重复调用只会把会话续上）。
    public func beginSession(accountID: String, accountName: String) {
        accountNames[accountID] = accountName
        if sessions[accountID] == nil {
            sessions[accountID] = PacketCaptureSession()
        }
        sessions[accountID]?.begin()
        capturingAccountIDs.insert(accountID)
        LobbyLog.info("[capture] 开始抓包：%@", accountName)
    }

    /// 停止抓包。窗口里的留存帧保留（可以继续查看 / 导出），只是不再进新帧。
    public func endSession(accountID: String) {
        guard capturingAccountIDs.remove(accountID) != nil else { return }
        sessions[accountID]?.end()
        LobbyLog.info("[capture] 停止抓包：%@（留存 %ld 条）",
                      accountNames[accountID] ?? accountID,
                      sessions[accountID]?.frames.count ?? 0)
    }

    /// 实例关闭：停抓 + 丢弃留存 + 移除会话（窗口由会话模型层负责关闭）。
    public func discardSession(accountID: String) {
        endSession(accountID: accountID)
        sessions.removeValue(forKey: accountID)
    }

    public func clear(accountID: String) {
        sessions[accountID]?.clear()
    }

    // MARK: - 帧摄入（GameViewportInstance 路由过来）

    public func ingest(frame: PacketFrame, accountID: String) {
        guard isCapturing(accountID: accountID), let session = sessions[accountID] else { return }
        session.append(Self.decode(frame))
    }

    // MARK: - 导出

    /// 导出载荷（JSON）。失败返回 nil（调用方提示）。
    public func exportPayload(accountID: String) -> Data? {
        guard let session = sessions[accountID] else { return nil }
        let frames: [[String: Any]] = session.frames.map { packet in
            var item: [String: Any] = [
                "time": packet.timeText,
                "direction": packet.direction,
                "command": packet.command,
                "bytes": packet.byteCount,
                "kind": packet.kind
            ]
            if let summary = packet.summary, !summary.isEmpty { item["summary"] = summary }
            item["detail"] = packet.detail
            if packet.truncated { item["truncated"] = true }
            return item
        }
        let payload: [String: Any] = [
            "account": accountNames[accountID] ?? accountID,
            "accountID": accountID,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "captured": session.frames.count,
            "dropped": session.droppedTotal,
            "frames": frames
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - 解码

    /// 一帧 → `CapturedPacket`。**任何一步失败都不丢弃**：
    /// 解不开 px 信封就记 hex 预览（「服务端改了协议」和「数据坏了」都要能看见）。
    private static func decode(_ frame: PacketFrame) -> CapturedPacket {
        var packet = CapturedPacket(
            timestampMs: frame.timestampMs,
            direction: frame.direction,
            kind: frame.kind,
            byteCount: frame.byteCount,
            truncated: frame.truncated
        )
        guard let data = Data(base64Encoded: frame.payloadBase64), !data.isEmpty else {
            packet.command = "‹空帧›"
            packet.detail = "base64 还原失败（\(frame.payloadBase64.prefix(32))…）"
            return packet
        }
        // 文本帧：不走 px/BON，直接把原文当内容展示（游戏协议是二进制 px，文本帧极少见，
        // 出现时通常意味着服务端/网关在发别的——原样保留最有排查价值）。
        if frame.kind == "text" {
            let text = String(decoding: data, as: UTF8.self)
            packet.command = "‹文本›"
            packet.summary = String(text.prefix(CapturedPacket.summaryLimit))
            packet.detail = text
            return packet
        }
        guard let plain = try? XorFrameCipher.open(data) else {
            packet.command = "‹未解码›"
            packet.detail = "px 信封解封失败（非 px 帧？）。前 64 字节：\n"
                + Self.hexPreview(data)
            return packet
        }
        guard let outer = try? Bon.decode(plain), let object = outer.objectValue else {
            packet.command = "‹未解码›"
            packet.detail = "信封已解（\(plain.count) 字节）但 BON 解析失败。明文前 64 字节：\n"
                + Self.hexPreview(plain)
            return packet
        }
        packet.command = object["cmd"]?.stringValue ?? "‹无cmd›"
        // detail：外层对象渲染。body（binary）在渲染时尝试解内层 BON，解不开就 hex。
        packet.detail = BonJSON.render(outer, bodyKey: "body")
        // summary：内层 body 的 JSON（列表行预览）。没有 body 的帧（如心跳）留空。
        if case .binary(let bodyBytes)? = object["body"], !bodyBytes.isEmpty {
            if let inner = try? Bon.decode(bodyBytes) {
                packet.summary = String(BonJSON.render(inner).prefix(CapturedPacket.summaryLimit))
            }
        } else if let seq = object["seq"]?.intValue {
            packet.summary = "seq=\(seq)"
        }
        return packet
    }

    private static func hexPreview(_ data: Data) -> String {
        data.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

// MARK: - 单条捕获包

/// 一条已解码的捕获包。列表行 + 详情面板 + 导出共用这一份快照。
public struct CapturedPacket: Identifiable, Sendable {
    /// 详情/摘要的截断长度（列表行预览用；详情面板另有全文）。
    static let summaryLimit = 220

    public let id: UUID
    /// 页面侧时间戳（毫秒，页面时钟）。
    public let timestampMs: Double
    /// `"send"`（游戏发出）/ `"recv"`（游戏收到）。
    public let direction: String
    /// `"binary"` / `"text"`。
    public let kind: String
    /// 页面侧计的原始字节数。
    public let byteCount: Int
    /// 页面侧超限截断（详情保留的是前缀字节，cmd 已足够解出）。
    public let truncated: Bool
    /// 协议命令（BON 外层 `cmd`；解不开时是 `‹未解码›` 等占位）。
    public var command: String
    /// 列表行预览（内层 body JSON 前缀；无 body 的帧给 seq）。
    public var summary: String?
    /// 详情面板全文（渲染后的外层 JSON；解不开时是 hex 预览 + 原因）。
    public var detail: String

    public var timeText: String {
        let date = Date(timeIntervalSince1970: timestampMs / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    init(timestampMs: Double, direction: String, kind: String,
         byteCount: Int, truncated: Bool) {
        self.id = UUID()
        self.timestampMs = timestampMs
        self.direction = direction
        self.kind = kind
        self.byteCount = byteCount
        self.truncated = truncated
        self.command = "?"
        self.summary = nil
        self.detail = ""
    }
}

// MARK: - 单账号会话

/// 一个账号（实例）的抓包会话：留存帧 + 节流上屏。
/// 过滤（包含 / 排除 / 心跳 / 方向 / 搜索）是**窗口的视图状态**，不在这里——
/// 存量帧永远全量留存，改过滤条件立即对全部历史生效。
@MainActor
public final class PacketCaptureSession: ObservableObject {
    /// 批量转正的节奏（毫秒）。
    private static let flushIntervalNanos: UInt64 = 250_000_000

    /// 留存帧（FIFO，上限 `PacketCaptureController.maxFrames`）。
    @Published public private(set) var frames: [CapturedPacket] = []
    /// 因容量上限被挤掉的最旧帧数（导出与状态栏展示，防止「总数对不上」的困惑）。
    @Published public private(set) var droppedTotal = 0
    @Published public private(set) var isCapturing = false

    /// 待转正缓冲（`append` 只进这里，由 flush loop 批量搬到 `frames`）。
    private var pending: [CapturedPacket] = []
    private var flushLoopTask: Task<Void, Never>?

    public init() {}

    /// 摄入一条（来自控制器解码后的成品）。
    func append(_ packet: CapturedPacket) {
        pending.append(packet)
        startFlushLoopIfNeeded()
    }

    public func begin() {
        guard !isCapturing else { return }
        isCapturing = true
        startFlushLoopIfNeeded()
    }

    /// 停止：进帧口关闭，剩余缓冲立即转正（最后几帧不丢）。
    public func end() {
        guard isCapturing else { return }
        isCapturing = false
        flushNow()
    }

    /// 清空留存（不影响抓包状态）。
    public func clear() {
        pending.removeAll(keepingCapacity: true)
        frames.removeAll(keepingCapacity: true)
        droppedTotal = 0
    }

    private func startFlushLoopIfNeeded() {
        guard flushLoopTask == nil else { return }
        flushLoopTask = Task { @MainActor [weak self] in
            while let self, self.isCapturing {
                try? await Task.sleep(nanoseconds: Self.flushIntervalNanos)
                self.flushNow()
            }
            self?.flushLoopTask = nil
        }
    }

    private func flushNow() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        frames.append(contentsOf: batch)
        if frames.count > PacketCaptureController.maxFrames {
            let overflow = frames.count - PacketCaptureController.maxFrames
            frames.removeFirst(overflow)
            droppedTotal += overflow
        }
    }
}

// MARK: - BON → JSON 渲染（保序）

/// 把 `BonValue` 渲染成**保序**的 JSON 文本。
///
/// 不走 `[String: Any]` + JSONSerialization：字典无序，字段顺序是排查协议时的
/// 一等线索（服务端写序 = BON 出现序），宁可手写渲染也不丢。
/// `bodyKey` 非空时，外层同名 binary 字段会尝试解内层 BON（解不开回退 hex）——
/// 游戏帧的 body 是「内层再 BON」，这正是抓包最有价值的部分。
enum BonJSON {
    /// binary 值在 JSON 里最多展示多少字节 hex。
    private static let binaryHexLimit = 96

    static func render(_ value: BonValue, bodyKey: String? = nil) -> String {
        render(value, bodyKey: bodyKey, depth: 0)
    }

    private static func render(_ value: BonValue, bodyKey: String?, depth: Int) -> String {
        switch value {
        case .null:
            return "null"
        case .int(let value):
            return String(value)
        case .long(let value):
            return String(value)
        case .float(let value):
            return formatNumber(Double(value))
        case .double(let value):
            return formatNumber(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .string(let text):
            return quoted(text)
        case .binary(let data):
            return binary(data)
        case .date(let milliseconds):
            return "{\"__date\":\(milliseconds)}"
        case .array(let items):
            if depth > 12 { return "…" }
            return "[" + items.map { render($0, bodyKey: nil, depth: depth + 1) }.joined(separator: ",") + "]"
        case .object(let object):
            if depth > 12 { return "…" }
            let fields = object.fields.map { field -> String in
                var rendered: String
                if field.key == bodyKey, case .binary(let bytes) = field.value,
                   let inner = try? Bon.decode(bytes) {
                    // 内层 BON 解开了：作为普通 JSON 值嵌进去（不再递归再解 binary）。
                    rendered = render(inner, bodyKey: nil, depth: depth + 1)
                } else {
                    rendered = render(field.value, bodyKey: bodyKey, depth: depth + 1)
                }
                return quoted(field.key) + ":" + rendered
            }
            return "{" + fields.joined(separator: ",") + "}"
        }
    }

    private static func binary(_ data: Data) -> String {
        let preview = data.prefix(binaryHexLimit)
            .map { String(format: "%02x", $0) }.joined()
        let more = data.count > binaryHexLimit ? "…" : ""
        return "{\"__bin\":\(data.count),\"hex\":\(quoted(preview + more))}"
    }

    private static func formatNumber(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    /// 最小 JSON 字符串转义（控制符 + 引号 + 反斜杠）。非法代理对随缘——
    /// 这是诊断展示，不是序列化契约。
    private static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        result += "\""
        return result
    }
}
