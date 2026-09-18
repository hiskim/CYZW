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

    /// 系统帧：不参与请求-响应配对（心跳/确认/错误）。
    /// 实测口径（导出数据 103 帧验证）：`_sys/ack` 是确认帧（双向都有）、
    /// `_sys/error` 是服务端错误推送；`_ws/ping` 是 WebSocket 应用层心跳
    /// （单字节 0x80，每 5s 一条，非 px 协议帧）。
    static let systemCommands: Set<String> = ["_sys/ack", "_sys/error", "heart_beat", wsPingCommand]

    /// WebSocket 应用层心跳帧的归一命令名（单字节 0x80 ping）。
    static let wsPingCommand = "_ws/ping"

    /// 账号 ID → 抓包会话。窗口与列表都从这里取。
    @Published public private(set) var sessions: [String: PacketCaptureSession] = [:]
    /// 正在抓包的账号 ID（矩阵卡片按钮的高亮态）。
    @Published public private(set) var capturingAccountIDs: Set<String> = []

    /// 指令库（抓包发现的新 cmd 自动入库；发送面板也从这里选）。
    public let catalog: GameCommandStore

    /// 账号名缓存（导出 JSON 里带上，窗口标题也用）。
    private var accountNames: [String: String] = [:]

    /// 发送历史（跨账号共享，最近 30 条；不持久化——发送是一次性操作记录）。
    @Published public private(set) var sendHistory: [SendRecord] = []

    /// 页面侧代理的诊断串（账号 ID → 最近一次 `capture.status()` 回执）。
    ///
    /// 为什么要有它：抓包「开了但没流量」的可能性不止一种——
    /// `no-handler` = 页面没装代理（构建产物旧 / 注入失败）；
    /// `hooked=0` = 代理装了但游戏还没 `new WebSocket`；
    /// `enabled=false` = 开关没推上去。窗口里常驻显示，一眼定性，不用捞日志。
    @Published public private(set) var pageDiagnostics: [String: String] = [:]

    public init(catalog: GameCommandStore) {
        self.catalog = catalog
    }

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
        let packet = Self.decode(frame)
        // 自动发现：抓包流里出现的新 cmd 进指令库（幂等，系统帧除外）。
        if !packet.command.hasPrefix("‹"), !Self.systemCommands.contains(packet.command) {
            catalog.addDiscovered(packet.command)
        }
        // 维护服务端 seq（发送构帧时的 ack 取这里）。
        if packet.direction == "recv", let seq = packet.seq, seq > 0 {
            session.noteServerSeq(seq)
        }
        session.append(packet)
    }

    // MARK: - 发送指令

    /// 构帧并发送。走**游戏已建立的连接**（独立连接会顶掉大厅实例的会话）：
    /// 宿主把完整帧编码好（BonCodec + XorFrameCipher，不依赖游戏内部符号），
    /// 页面代理只负责把字节交给登记的活跃 socket。
    ///
    /// - `ack` 取抓包里最近一个 recv 帧的服务端 seq（比猫助手的 ack=0 更符合协议）；
    /// - `seq` 用毫秒时间戳（大数，绝不与游戏递增的小 seq 撞车——猫助手实测可行）；
    /// - 注入帧会经过页面代理的 send 包装，**自然进入抓包流**，响应配对照常工作。
    @discardableResult
    public func sendCommand(accountID: String,
                            instance: GameViewportInstance,
                            entry: GameCommandEntry,
                            paramsJSON: String) async -> SendRecord {
        let record = await sendCommand(accountID: accountID, instance: instance,
                                       command: entry.command,
                                       chineseName: entry.chineseName,
                                       paramsJSON: paramsJSON)
        return record
    }

    @discardableResult
    public func sendCommand(accountID: String,
                            instance: GameViewportInstance,
                            command: String,
                            chineseName: String,
                            paramsJSON: String,
                            autoAckSeq: Bool = true,
                            manualAck: Int64? = nil,
                            manualSeq: Int64? = nil) async -> SendRecord {
        var record = SendRecord(command: command,
                                chineseName: chineseName.isEmpty ? command : chineseName,
                                paramsJSON: paramsJSON)
        let trimmedParams = paramsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        // ack/seq 编址（默认全自动，推荐）：
        //   · ack = 会话里最近 recv 帧的服务端 seq（标准确认语义）；
        //   · seq = 毫秒时间戳——**刻意不延续游戏的 1,2,3 序列**：撞号会让服务端
        //     按序去重丢掉游戏自己的请求；大数区间独立编址游戏/服务端都容忍
        //     （猫助手 Date.now seq 实测可用）。
        //   · 手动模式给懂协议的人做实验（UI 上有风险提示）。
        let ack: Int64
        let seq: Int64
        if autoAckSeq {
            ack = manualAck ?? (sessions[accountID]?.lastServerSeq ?? 0)
            seq = Int64(Date().timeIntervalSince1970 * 1000)
        } else {
            ack = manualAck ?? (sessions[accountID]?.lastServerSeq ?? 0)
            seq = manualSeq ?? Int64(Date().timeIntervalSince1970 * 1000)
        }
        record.ackUsed = ack
        record.seqUsed = seq
        do {
            let frame = try Self.buildFrame(command: command, paramsJSON: trimmedParams,
                                            ack: ack, seq: seq)
            let diagnostic = await instance.sendRawFrame(base64: frame.base64EncodedString())
            record.status = diagnostic.hasPrefix("sent") ? "已发送" : diagnostic
            record.succeeded = diagnostic.hasPrefix("sent")
            LobbyLog.info("[capture] 发送指令 %@(%@) ack=%lld seq=%lld → %@",
                          chineseName, command, ack, seq, diagnostic)
        } catch {
            record.status = "构帧失败：\(error.localizedDescription)"
            record.succeeded = false
            LobbyLog.warn("[capture] 构帧失败 %@：%@", command, String(describing: error))
        }
        sendHistory.insert(record, at: 0)
        if sendHistory.count > 30 {
            sendHistory.removeLast(sendHistory.count - 30)
        }
        return record
    }

    /// 组装完整帧：`x` 信封（BON `{cmd, ack, seq, time, body=内层BON(params)}`）。
    static func buildFrame(command: String, paramsJSON: String,
                           ack: Int64, seq: Int64? = nil) throws -> Data {
        let params = try Self.jsonToBonValue(paramsJSON)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let body = Bon.encode(params)
        let message = BonValue.object(BonObject([
            .init("cmd", .string(command)),
            .init("ack", .long(ack)),
            .init("seq", .long(seq ?? now)),
            .init("time", .long(now)),
            .init("body", .binary(body)),
        ]))
        return XorFrameCipher.seal(Bon.encode(message))
    }

    /// JSON 文本 → BonValue（发送参数编辑器的输入）。非法 JSON 抛错给 UI 展示。
    static func jsonToBonValue(_ text: String) throws -> BonValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .object(BonObject()) }
        // JSONSerialization 顶层可以是任意值（对象 / 数组 / 字面量），都接受。
        let object = try JSONSerialization.jsonObject(with: Data(trimmed.utf8))
        return bonValue(from: object)
    }

    private static func bonValue(from any: Any) -> BonValue {
        switch any {
        case is NSNull:
            return .null
        case let number as NSNumber:
            // JSONSerialization 的 Bool 也是 NSNumber，用 CF 类型区分（否则 true 变 1）。
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let double = number.doubleValue
            if double == double.rounded() && abs(double) < 9.007_199_254_740_992e15 {
                return .long(number.int64Value)
            }
            return .double(double)
        case let text as String:
            return .string(text)
        case let array as [Any]:
            return .array(array.map(bonValue(from:)))
        case let dictionary as [String: Any]:
            let fields = dictionary.map { key, value in
                BonObject.Field(key, bonValue(from: value))
            }
            return .object(BonObject(fields))
        default:
            return .string(String(describing: any))
        }
    }

    // MARK: - 导出

    /// 导出载荷（JSON）。失败返回 nil（调用方提示）。
    ///
    /// 配对字段自解释：`pairIndex`（1-based，指向配对帧在 frames 数组里的位置，
    /// 请求/响应双向都有）、`roundTripMs`、`isPush`——导出文件离线分析时
    /// 不需要再猜 seq/ack 的关系。
    public func exportPayload(accountID: String) -> Data? {
        guard let session = sessions[accountID] else { return nil }
        // uuid → 1-based 序号（配对方位）。
        let pairIndexByID = Dictionary(uniqueKeysWithValues:
            session.frames.enumerated().map { index, packet in (packet.id, index + 1) })
        let frames: [[String: Any]] = session.frames.enumerated().map { index, packet in
            var item: [String: Any] = [
                "index": index + 1,
                "time": packet.timeText,
                "direction": packet.direction,
                "command": packet.command,
                "bytes": packet.byteCount,
                "kind": packet.kind
            ]
            if let seq = packet.seq { item["seq"] = Int(seq) }
            if let ack = packet.ack { item["ack"] = Int(ack) }
            if !PacketCaptureController.systemCommands.contains(packet.command) {
                if let responseIndex = packet.matchedResponseUUID.flatMap({ pairIndexByID[$0] }) {
                    item["pairIndex"] = responseIndex
                }
                if let requestIndex = packet.matchedRequestUUID.flatMap({ pairIndexByID[$0] }) {
                    item["pairIndex"] = requestIndex
                }
                if packet.isPush { item["isPush"] = true }
                if let roundTrip = packet.roundTripMs { item["roundTripMs"] = Int(roundTrip) }
            }
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
            "pairing": "业务序号对齐（服务端串行处理）：第 k 个业务请求 ↔ 第 k 个业务响应；ack 是处理进度不是配对键",
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
        // WebSocket **应用层心跳**（非 px 协议帧）：实测游戏客户端每 5s 发一个
        // 单字节 0x80（私有 ping，浏览器 API 层看不到），服务端不回业务响应。
        // 必须归为系统帧：否则每个 ping 都会在配对队列里占一个坑，把后面
        // 真实请求的响应全部错位（导出数据里 21 条「未解码」即此）。
        if data.count == 1 {
            packet.command = Self.wsPingCommand
            packet.detail = "WebSocket 应用层心跳（0x\(String(data[data.startIndex], radix: 16))）"
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
        packet.seq = object["seq"]?.intValue
        packet.ack = object["ack"]?.intValue
        packet.isProtocolFrame = true
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

    // ── 协议字段（外层 BON 的 seq / ack，配对与发送构帧都要用）──
    /// 帧内 seq（请求=客户端序，响应=服务端序，心跳恒 0）。
    public var seq: Int64?
    /// 帧内 ack（客户端对服务端 seq 的确认）。
    public var ack: Int64?

    // ── 请求-响应配对（协议没有帧内请求 ID，按「同名 cmd + 方向 + 时间窗」配对）──
    /// recv 帧：配对上的请求包 id。
    public var matchedRequestUUID: UUID?
    /// recv 帧：配对请求的页面时间戳（冗余存储，渲染时零查找）。
    public var matchedRequestTime: Double?
    /// 往返耗时（响应 − 请求，毫秒）。
    public var roundTripMs: Double?
    /// send 帧：已收到配对响应。
    public var matchedResponseUUID: UUID?
    /// recv 帧：没等到配对请求（服务端主动推送）。
    public var isPush: Bool
    /// 是否为**合法协议帧**（px 信封解封 + BON 解码都成功）。
    /// 应用层心跳（0x80）、hex 失败帧、文本帧都不是——它们不进配对队列
    /// （占坑会把后续真实响应错位），但在抓包流里照常可见。
    public var isProtocolFrame: Bool

    public var isSystem: Bool {
        PacketCaptureController.systemCommands.contains(command)
    }

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
        self.seq = nil
        self.ack = nil
        self.matchedRequestUUID = nil
        self.matchedRequestTime = nil
        self.roundTripMs = nil
        self.matchedResponseUUID = nil
        self.isPush = false
        self.isProtocolFrame = false
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

    /// 最近收到的服务端 seq（发送构帧时的 ack 来源）。
    public private(set) var lastServerSeq: Int64 = 0
    /// 待配对的业务请求 FIFO（全局队列，跨 cmd）。
    ///
    /// ⚠️ 为什么是**全局**队列而不是按 cmd 分桶（2026-09-18.8 的方案，导出数据
    /// 103 帧实测推翻）：响应的 cmd 是游戏内部定义的 `Resp` 名——`role_getroleinfo`
    /// → `Role_GetRoleInfoResp`、`mergebox_getinfo` → `MergeBoxInfoResp`（内部缩写，
    /// **无法从请求名推导**），按 cmd 相等配对永远落空。真实机制是服务端**串行**
    /// 处理：排除系统帧后第 k 个业务请求 ↔ 第 k 个业务响应（实测 32/41 形态完全
    /// 吻合，剩余错位全部由推送帧与无响应请求解释）。
    private var pendingBusinessSends: [(uuid: UUID, time: Double)] = []

    /// 待转正缓冲（`append` 只进这里，由 flush loop 批量搬到 `frames`）。
    private var pending: [CapturedPacket] = []
    private var flushLoopTask: Task<Void, Never>?

    public init() {}

    /// 摄入一条（来自控制器解码后的成品）。
    func append(_ packet: CapturedPacket) {
        var matched = packet
        match(&matched)
        pending.append(matched)
        startFlushLoopIfNeeded()
    }

    /// 记录服务端 seq（recv 帧，>0 才有意义）。
    func noteServerSeq(_ seq: Int64) {
        lastServerSeq = max(lastServerSeq, seq)
    }

    /// 请求-响应配对（业务序号对齐）。
    ///
    /// 规则（导出数据实测口径）：
    ///   · send 业务帧（非 `_sys/ack`/`heart_beat`）压入全局 FIFO；
    ///   · recv 业务帧（非 `_sys/ack`/`_sys/error`）弹队头配对——服务端串行处理，
    ///     响应顺序 = 请求顺序；
    ///   · 没有等待中的请求 → 服务端主动推送（`isPush`）；
    ///   · **非协议帧不参与配对**（应用层心跳 0x80 每 5s 一个占坑，会把后续
    ///     真实响应全部错位——实测教训）；`ack`/`seq` 仅作详情展示。
    private func match(_ packet: inout CapturedPacket) {
        // 非协议帧（心跳 ping / 解码失败 / 文本帧）：照常展示，不碰配对队列。
        guard packet.isProtocolFrame else { return }
        // 系统帧（服务端确认/错误推送）：同样不参与业务配对。
        guard !PacketCaptureController.systemCommands.contains(packet.command) else { return }
        if packet.direction == "send" {
            pendingBusinessSends.append((packet.id, packet.timestampMs))
            return
        }
        // recv 业务帧：配队头。
        if let request = pendingBusinessSends.first {
            pendingBusinessSends.removeFirst()
            packet.matchedRequestUUID = request.uuid
            packet.matchedRequestTime = request.time
            packet.roundTripMs = max(0, packet.timestampMs - request.time)
            updateRequestSide(uuid: request.uuid,
                              responseID: packet.id,
                              roundTripMs: packet.roundTripMs ?? 0)
        } else {
            packet.isPush = true
        }
    }

    /// 双向标记响应指针（请求对象可能在 pending 或已 flush 进 frames）。
    private func updateRequestSide(uuid: UUID, responseID: UUID, roundTripMs: Double) {
        if let index = pending.firstIndex(where: { $0.id == uuid }) {
            pending[index].matchedResponseUUID = responseID
            pending[index].roundTripMs = roundTripMs
        }
        if let index = frames.firstIndex(where: { $0.id == uuid }) {
            frames[index].matchedResponseUUID = responseID
            frames[index].roundTripMs = roundTripMs
        }
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

// MARK: - JSON 美化（压缩 ↔ 展开）

/// 单行 JSON → 缩进多行（**选中时懒计算**：留存帧只存压缩串，双份存储会让
/// 5000 条上限下的内存翻倍；一次只美化当前查看的那条，开销可忽略）。
/// 非 JSON 文本（hex 预览 / 解码失败原因）原样返回。
public enum JSONBeautifier {
    public static func pretty(_ text: String) -> String {
        guard let first = text.first, first == "{" || first == "[" else { return text }
        var result = ""
        result.reserveCapacity(text.count + text.count / 4)
        let indentUnit = "  "
        var depth = 0
        var inString = false
        var escaped = false
        for character in text {
            if escaped {
                result.append(character)
                escaped = false
                continue
            }
            if inString {
                result.append(character)
                if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"":
                inString = true
                result.append(character)
            case "{", "[":
                depth += 1
                result.append(character)
                result.append("\n" + String(repeating: indentUnit, count: depth))
            case "}", "]":
                depth = max(0, depth - 1)
                result.append("\n" + String(repeating: indentUnit, count: depth))
                result.append(character)
            case ",":
                result.append(character)
                result.append("\n" + String(repeating: indentUnit, count: depth))
            case ":":
                result.append(character)
                result.append(" ")
            default:
                result.append(character)
            }
        }
        return result
    }
}

// MARK: - 发送记录

/// 一次「发送指令」的记录（发送面板的历史列表；点击可回填参数）。
public struct SendRecord: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    /// 指令字面值。
    public let command: String
    /// 中文名（指令库命中时的展示名）。
    public let chineseName: String
    /// 发送时的参数 JSON 原文（回填用）。
    public let paramsJSON: String
    /// 结果诊断（`已发送` / 页面回执错误 / 构帧失败原因）。
    public var status: String
    public var succeeded: Bool
    /// 实际使用的 ack / seq（历史里展示编址依据；自动模式 ack=最新服务端 seq、
    /// seq=毫秒时间戳）。
    public var ackUsed: Int64?
    public var seqUsed: Int64?

    public var timeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }

    init(command: String, chineseName: String, paramsJSON: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.command = command
        self.chineseName = chineseName
        self.paramsJSON = paramsJSON
        self.status = "发送中…"
        self.succeeded = false
        self.ackUsed = nil
        self.seqUsed = nil
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
