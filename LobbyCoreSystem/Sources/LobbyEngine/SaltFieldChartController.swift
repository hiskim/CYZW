import Foundation
import LobbyDomain
import LobbyIPC

// MARK: - 盐场实时图表 · 宿主侧控制器
//
// 与 `PacketCaptureController`（通用抓包）并行的一条**专题解码线**：
// 同样的页面帧（`PageEvent.packet`）进来，这里只关心**盐场战场连接**（游戏进盐场
// 时自建的第二条 WSS，`war_*` 命令族）上的流量，把 `war_getbattlefieldinfo`
// 响应解成「地图占领 + 俱乐部/个人战况」快照，供独立图表窗口渲染。
//
//   PageEvent.packet(PacketFrame)
//     → px 信封解封（`XorFrameCipher`）→ BON 外层（cmd/ack/seq/body）
//     → body 内层再 BON → battlefield{buildingData, legions, roles}
//     → SaltFieldSnapshot（静态骨架合并 + 占领布局 BFS 染色）
//
// 与抓包的分工/共存：图表开着时若抓包没开，会话模型会顺手把页面上报打开
// （见 `LobbySessionModel.toggleSaltFieldChart`）——页面帧只有一份，两条解码线
// 各取所需互不干扰；抓包窗口照常能看见这些帧。
//
// 主动轮询（实时性）：游戏页面只有玩家操作时才拉战场信息，图表要"实时"就得
// 自己发。这里每 4s 对已开启图表的账号构一帧 `war_getbattlefieldinfo`
// （`PacketCaptureController.buildFrame` 同源构帧），**定向**发给盐场 socket：
//   · socket 定向：主连接与盐场连接的 URL 都含 "agent"（实测主连接
//     `wss://xxz-xyzw.hortorgames.com/agent?…`），按 URL 挑会发错——
//     页面代理 v3 起给每个构造的 socket 发 `sid`，盐场帧路过时记住 sid，
//     发送时点名（`sendRawFrame(base64:socketID:)`）；
//   · seq 编址：盐场连接有**独立的** seq 序列（与主连接的计数值完全无关），
//     这里只统计 war_* 帧的 seq 维护盐场自己的 client/server 游标；
//   · battlefieldId：来自游戏自发的心跳 `war_ping` / `war_enterbattlefield`
//     的 body（进盐场后每 5s 一条心跳，天然持续可得）。
@MainActor
public final class SaltFieldChartController: ObservableObject {
    /// 轮询周期（毫秒）。盐场心跳 5s 一条，4s 拉一次信息在节流与实时之间取平衡。
    public static let pollIntervalNanos: UInt64 = 4_000_000_000

    /// 账号 ID → 最新战场快照（图表窗口的唯一数据源）。
    @Published public private(set) var snapshots: [String: SaltFieldSnapshot] = [:]
    /// 见过盐场 `war_*` 流量的账号（说明盐场连接存在 / 曾存在）。
    @Published public private(set) var warActiveAccountIDs: Set<String> = []
    /// 开启了主动轮询的账号（图表窗口打开时置位，关窗撤位）。
    @Published public private(set) var pollingAccountIDs: Set<String> = []

    // MARK: 历史战绩（主连接查询；协议口径见 SaltFieldModels 注释）
    /// 账号 → 我方历史场次（warMap 展开 + warRank 对齐，新场次在前）。
    @Published public private(set) var historyBattles: [String: [SaltHistoryBattle]] = [:]
    /// 账号 → 最近一次历史总榜查询结果。
    @Published public private(set) var historyResults: [String: SaltHistoryResult] = [:]
    /// 账号 → 最近一次成员明细查询（legionwar_getdetails；历史战绩页的主数据）。
    @Published public private(set) var historyDetails: [String: SaltWarDetailsResult] = [:]
    /// 账号 → 历史查询状态文本（窗口显示）。
    @Published public private(set) var historyStatus: [String: String] = [:]
    /// 正在查询历史的账号（按钮 loading 态）。
    @Published public private(set) var historyBusy: Set<String> = []
    /// 每账号当月 warType 缓存（key = 首周六 "YYYY/MM/DD"）。
    private var monthlyWarTypes: [String: [String: Int]] = [:]

    /// 发送轮询帧要借实例的 WebView 出口。会话模型装配时接上。
    public weak var pool: GameInstancePool?

    // MARK: 每账号盐场连接状态（内部；非 published——轮询游标不需要驱动 UI）
    private struct WarLinkState {
        var socketID: Int = -1          // 盐场 socket 的页面侧 id（定向发送用）
        var battlefieldID: Int64 = 0    // 心跳 / 进场帧的 body.battlefieldId
        var serverSeq: Int64 = 0        // 盐场响应 seq 游标（构帧 ack）
        var clientSeq: Int64 = 0        // 盐场请求 seq 游标（构帧 seq = +1）
    }
    private var states: [String: WarLinkState] = [:]
    private var pollTask: Task<Void, Never>?

    // MARK: 每账号主连接状态（历史查询构帧用；与盐场连接的游标相互独立）
    private struct MainLinkState {
        var socketID = -1
        var serverSeq: Int64 = 0
        var clientSeq: Int64 = 0
    }
    private var mainStates: [String: MainLinkState] = [:]

    /// 在途历史查询（响应匹配；`resp` 字段 / cmd 包含逐级退化，超时 12s 判失败）。
    private struct PendingHistoryQuery {
        enum Kind {
            case warType(monthFirstSaturday: String)   // 命中后接着查 totalRank
            case totalRank(battleDate: Date)
            case legionInfo                            // 我方历史场次（warMap 名次）
            case warDetails(battleDate: Date)          // 指定日期成员明细（主路径）

            /// 响应 cmd（小写）是否命中本请求。legionInfo 需排除 getinfobyid——
            /// 其响应名同样包含 "legion_getinfo" 前缀，会抢走配对。
            /// 兜底再加「去下划线包含」：服务端响应名可能不带下划线
            /// （抓包实测口径：mergebox_getinfo 的响应是缩写 MergeBoxInfoResp）。
            func matches(_ loweredResponseCommand: String) -> Bool {
                let compact = loweredResponseCommand.replacingOccurrences(of: "_", with: "")
                switch self {
                case .warType:
                    return loweredResponseCommand.contains("saltroad_getwartype")
                case .totalRank:
                    return loweredResponseCommand.contains("saltroad_getsaltroadwartotalrank")
                case .legionInfo:
                    return loweredResponseCommand.contains("legion_getinfo")
                        && !loweredResponseCommand.contains("byid")
                case .warDetails:
                    return loweredResponseCommand.contains("legionwar_getdetails")
                        || compact.contains("legionwargetdetails")
                }
            }
        }
        let kind: Kind
        let seq: Int64
        let issuedAt: Date
    }
    private var pendingHistory: [String: [PendingHistoryQuery]] = [:]
    private static let historyTimeout: TimeInterval = 12

    public init() {}

    // MARK: - 帧摄入（GameViewportInstance 路由，与抓包 ingest 并列）

    public func ingest(frame: PacketFrame, accountID: String) {
        guard let decoded = Self.decode(frame) else { return }
        let lowered = decoded.command.lowercased()
        let isWarFamily = lowered.contains("war_enterbattlefield")
                || lowered.contains("war_getbattlefieldinfo")
                || lowered == "war_ping" || lowered.contains("war_ping")
                || lowered.hasPrefix("war_")

        // ── 历史查询响应匹配（主连接；在 war 族过滤之前——响应 cmd 可能是任意内部名）──
        if frame.direction == "recv", !isWarFamily {
            if tryMatchHistoryResponse(command: decoded.command,
                                       object: decoded.outerObject,
                                       inner: decoded.inner,
                                       accountID: accountID) {
                trackMainLink(frame: frame, lowered: lowered, accountID: accountID, seq: decoded.seq)
                return
            }
        }

        guard isWarFamily else {
            // 主连接游标：历史查询构帧的 ack / seq / socket 定向来源。
            trackMainLink(frame: frame, lowered: lowered, accountID: accountID, seq: decoded.seq)
            return
        }

        var state = states[accountID] ?? WarLinkState()
        var changedLink = false
        if frame.socketID >= 0, state.socketID != frame.socketID {
            state.socketID = frame.socketID
            changedLink = true
        }

        // 战场 id：游戏自己发的进场 / 心跳帧 body 里带着。
        if frame.direction == "send",
           let body = decoded.inner, let id = body.path("battlefieldId")?.intValue,
           id > 0, id != state.battlefieldID {
            state.battlefieldID = id
            changedLink = true
        }

        // 盐场 seq 游标（与主连接完全独立的两套计数）。
        if let seq = decoded.seq, seq > 0 {
            if frame.direction == "recv" {
                state.serverSeq = max(state.serverSeq, seq)
            } else if seq < 1_000_000 { // 只认小整数（排除时间戳 seq，口径同抓包）
                state.clientSeq = max(state.clientSeq, seq)
            }
        }

        // 战场信息响应 → 快照。
        if frame.direction == "recv", lowered.contains("war_getbattlefieldinfo"),
           let body = decoded.inner, let battlefield = body.path("battlefield")?.objectValue {
            let snapshot = Self.buildSnapshot(battlefield: battlefield,
                                              battlefieldID: state.battlefieldID,
                                              timestampMs: frame.timestampMs)
            snapshots[accountID] = snapshot
            if snapshots[accountID] != nil, !warActiveAccountIDs.contains(accountID) {
                warActiveAccountIDs.insert(accountID)
            }
            LobbyLog.info("[saltfield] %@ 战场快照更新：据点 %ld 俱乐部 %ld 成员 %ld（%ld 字节）",
                          accountID, snapshot.nodes.count,
                          snapshot.legions.count, snapshot.members.count, frame.byteCount)
        }

        if !warActiveAccountIDs.contains(accountID) {
            warActiveAccountIDs.insert(accountID)
            LobbyLog.info("[saltfield] %@ 检测到盐场连接流量（%@）", accountID, decoded.command)
        }
        states[accountID] = state
        if changedLink, pollingAccountIDs.contains(accountID) {
            LobbyLog.info("[saltfield] %@ 盐场连接就绪：socket=%lld battlefieldId=%lld",
                          accountID, state.socketID, state.battlefieldID)
        }
    }

    /// 主连接游标跟踪：非 war 族的 send/recv 帧都算主连接流量。
    private func trackMainLink(frame: PacketFrame, lowered: String, accountID: String,
                               seq: Int64?) {
        var state = mainStates[accountID] ?? MainLinkState()
        if frame.socketID >= 0, state.socketID != frame.socketID {
            state.socketID = frame.socketID
        }
        if let seq, seq > 0 {
            if frame.direction == "recv" {
                state.serverSeq = max(state.serverSeq, seq)
            } else if seq < 1_000_000 {
                state.clientSeq = max(state.clientSeq, seq)
            }
        }
        mainStates[accountID] = state
    }

    /// 实例关闭：丢弃该账号的快照与连接状态（窗口由会话模型关）。
    public func discard(accountID: String) {
        snapshots.removeValue(forKey: accountID)
        states.removeValue(forKey: accountID)
        pollingAccountIDs.remove(accountID)
        warActiveAccountIDs.remove(accountID)
        mainStates.removeValue(forKey: accountID)
        pendingHistory.removeValue(forKey: accountID)
        historyBusy.remove(accountID)
        historyStatus.removeValue(forKey: accountID)
        historyDetails.removeValue(forKey: accountID)
        chainedBattleDate.removeValue(forKey: accountID)
    }

    // MARK: - 轮询

    /// 开/关某账号的主动轮询（图表窗口开关的直连入口）。
    public func setPolling(_ enabled: Bool, accountID: String) {
        if enabled {
            pollingAccountIDs.insert(accountID)
        } else {
            pollingAccountIDs.remove(accountID)
        }
        startPollLoopIfNeeded()
    }

    /// 立即对指定账号拉一轮（图表窗口的「立即拉取」按钮）。
    public func pollNow(accountID: String) {
        poll(accountID: accountID)
    }

    // MARK: - 历史战绩查询（主连接；协议口径见 SaltFieldModels 注释）

    /// 拉取我方历史场次（`legion_getinfo` → info.warMap + warRank）。
    /// 日历的可点日期与我方名次都来自这里。
    public func fetchHistoryBattles(accountID: String) {
        guard !historyBusy.contains(accountID) else { return }
        sendHistoryFrame(accountID: accountID, command: "legion_getinfo",
                         paramsJSON: "{}",
                         kind: .legionInfo,
                         startStatus: "正在拉取历史场次…")
    }

    /// 查询指定场次的盐场总榜。两步链式：warType（当月未缓存时）→ totalRank。
    public func queryHistoryRank(accountID: String, battleDate: Date) {
        guard !historyBusy.contains(accountID) else {
            historyStatus[accountID] = "已有查询在进行，请稍候…"
            return
        }
        let monthKey = SaltHistoryCatalog.firstSaturdayString(of: battleDate)
        if let warType = monthlyWarTypes[accountID]?[monthKey] {
            issueTotalRank(accountID: accountID, battleDate: battleDate, warType: warType)
        } else {
            historyBusy.insert(accountID)
            historyStatus[accountID] = "正在获取当月盐场类型…"
            sendHistoryFrame(accountID: accountID,
                             command: "saltroad_getwartype",
                             paramsJSON: "{\"date\":\"\(monthKey)\"}",
                             kind: .warType(monthFirstSaturday: monthKey),
                             startStatus: "正在获取当月盐场类型…")
        }
    }

    /// 第二步：按 warType 确定的榜单范围查总榜。
    private func issueTotalRank(accountID: String, battleDate: Date, warType: Int) {
        guard let range = SaltHistoryCatalog.rankParams(warType) else {
            historyBusy.remove(accountID)
            historyStatus[accountID] =
                "类型「\(SaltHistoryCatalog.warTypeName(warType))」不支持排行查询（仅青铜/秘蓝/月宫/天宫）"
            return
        }
        let dateKey = SaltHistoryCatalog.yymmddString(of: battleDate)
        historyBusy.insert(accountID)
        historyStatus[accountID] = "正在查询 \(SaltHistoryCatalog.warTypeName(warType)) 榜单…"
        sendHistoryFrame(accountID: accountID,
                         command: "saltroad_getsaltroadwartotalrank",
                         paramsJSON: "{\"date\":\"\(dateKey)\",\"startRank\":\(range.startRank),\"endRank\":\(range.endRank)}",
                         kind: .totalRank(battleDate: battleDate),
                         startStatus: historyStatus[accountID] ?? "查询中…")
    }

    /// 构帧发送 + 登记在途查询 + 超时定时。
    private func sendHistoryFrame(accountID: String, command: String, paramsJSON: String,
                                  kind: PendingHistoryQuery.Kind, startStatus: String) {
        guard let main = mainStates[accountID], main.socketID >= 0 || main.serverSeq > 0 else {
            historyStatus[accountID] = "主连接未就绪：请先启动该账号的游戏实例"
            return
        }
        guard let instance = pool?.existingSurface(forAccountID: accountID) else {
            historyStatus[accountID] = "实例未运行"
            return
        }
        let seq = main.clientSeq + 1
        guard let frame = try? PacketCaptureController.buildFrame(
            command: command, paramsJSON: paramsJSON,
            ack: main.serverSeq, seq: seq) else {
            historyStatus[accountID] = "构帧失败"
            return
        }
        mainStates[accountID]?.clientSeq = seq
        pendingHistory[accountID, default: []].append(
            PendingHistoryQuery(kind: kind, seq: seq, issuedAt: Date()))
        historyStatus[accountID] = startStatus
        let socketID = main.socketID
        Task { @MainActor [weak self] in
            let diagnostic = await instance.sendRawFrame(base64: frame.base64EncodedString(),
                                                         socketID: socketID)
            if !diagnostic.hasPrefix("sent") {
                self?.historyStatus[accountID] = "发送失败：\(diagnostic)"
                self?.pendingHistory[accountID]?.removeAll { $0.seq == seq }
                LobbyLog.warn("[saltfield-history] %@ 发送 %@ 失败：%@", accountID, command, diagnostic)
            } else {
                LobbyLog.info("[saltfield-history] %@ 已发 %@ seq=%lld", accountID, command, seq)
            }
        }
        // 超时：响应匹配失败（resp / cmd 都没对上）时明确报出来，方便从抓包对 cmd。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.historyTimeout * 1_000_000_000))
            guard let self, var queue = self.pendingHistory[accountID],
                  let index = queue.firstIndex(where: { $0.seq == seq }) else { return }
            let pending = queue.remove(at: index)
            self.pendingHistory[accountID] = queue
            guard Date().timeIntervalSince(pending.issuedAt) >= Self.historyTimeout - 1 else { return }
            if case .warType = pending.kind { self.historyBusy.remove(accountID) }
            if case .totalRank = pending.kind { self.historyBusy.remove(accountID) }
            if case .legionInfo = pending.kind { self.historyBusy.remove(accountID) }
            self.historyStatus[accountID] = "查询超时：未匹配到 \(command) 的响应（可在抓包窗口查看响应 cmd 后反馈）"
            LobbyLog.warn("[saltfield-history] %@ %@ 响应超时", accountID, command)
        }
    }

    /// 响应匹配（逐级退化）：① 响应外层 `resp` 字段 == 在途请求 seq；
    /// ② 响应 cmd（小写）按 Kind.matches 命中。命中处理并返回 true。
    private func tryMatchHistoryResponse(command: String, object: BonObject?,
                                         inner: BonValue?, accountID: String) -> Bool {
        guard var queue = pendingHistory[accountID], !queue.isEmpty else { return false }
        let lowered = command.lowercased()
        var matched: PendingHistoryQuery?
        if let respSeq = object?["resp"]?.intValue,
           let index = queue.firstIndex(where: { $0.seq == respSeq }) {
            matched = queue.remove(at: index)
        } else if let index = queue.firstIndex(where: { $0.kind.matches(lowered) }) {
            matched = queue.remove(at: index)
        }
        guard let pending = matched else { return false }
        pendingHistory[accountID] = queue
        handleHistoryResponse(pending: pending, inner: inner, accountID: accountID)
        return true
    }

    private func handleHistoryResponse(pending: PendingHistoryQuery,
                                       inner: BonValue?, accountID: String) {
        switch pending.kind {
        case .legionInfo:
            historyBusy.remove(accountID)
            let battles = Self.parseHistoryBattles(inner: inner)
            if battles.isEmpty {
                let structure = Self.describeBodyKeys(inner: inner)
                historyStatus[accountID] = "未查到历史场次（结构诊断见 diagnostics.log 的 [saltfield-history]）"
                LobbyLog.warn("[saltfield-history] %@ warMap 解析为空。响应结构：%@",
                              accountID, structure)
            } else {
                historyStatus[accountID] = "历史场次已加载：共 \(battles.count) 场"
            }
            historyBattles[accountID] = battles
            LobbyLog.info("[saltfield-history] %@ 历史场次 %ld", accountID, battles.count)
        case .warType(let monthKey):
            let warType = Int(inner?.path("warType")?.intValue ?? 0)
            monthlyWarTypes[accountID, default: [:]][monthKey] = warType
            guard warType > 0 else {
                historyBusy.remove(accountID)
                historyStatus[accountID] = "未获取到当月盐场类型（服务端返回 warType=0）"
                return
            }
            // 链式继续：warType 到手 → 发 totalRank。battleDate 从 UI 侧最后点击取不到，
            // 由 warType 查询发起时暂存在 status 之外的专用槽里。
            guard let battleDate = chainedBattleDate[accountID] else {
                historyBusy.remove(accountID)
                return
            }
            issueTotalRank(accountID: accountID, battleDate: battleDate, warType: warType)
        case .warDetails(let battleDate):
            historyBusy.remove(accountID)
            let rows = Self.parseWarDetails(inner: inner)
            if rows.isEmpty {
                historyStatus[accountID] = "\(SaltHistoryCatalog.slashDateString(of: battleDate)) 无成员战绩（结构诊断见 diagnostics.log 的 [saltfield-history]）"
                LobbyLog.warn("[saltfield-history] %@ roleDetailsList 解析为空（date=%@）。响应结构：%@",
                              accountID, SaltHistoryCatalog.slashDateString(of: battleDate),
                              Self.describeBodyKeys(inner: inner))
            } else {
                historyStatus[accountID] = "查询成功：\(rows.count) 人参战"
            }
            historyDetails[accountID] = SaltWarDetailsResult(battleDate: battleDate,
                                                             rows: rows,
                                                             fetchedAt: Date())
            LobbyLog.info("[saltfield-history] %@ 成员明细 %ld 条（date=%@）",
                          accountID, rows.count, SaltHistoryCatalog.slashDateString(of: battleDate))
        case .totalRank(let battleDate):
            historyBusy.remove(accountID)
            chainedBattleDate.removeValue(forKey: accountID)
            let warType = monthlyWarType(for: battleDate, accountID: accountID)
            let rows = Self.parseRankList(inner: inner)
            if rows.isEmpty {
                historyStatus[accountID] = "该场次无榜单数据（结构诊断见 diagnostics.log 的 [saltfield-history]）"
                LobbyLog.warn("[saltfield-history] %@ legionList 解析为空（date=%@）。响应结构：%@",
                              accountID, SaltHistoryCatalog.yymmddString(of: battleDate),
                              Self.describeBodyKeys(inner: inner))
            } else {
                historyStatus[accountID] = "查询成功：\(rows.count) 条"
            }
            historyResults[accountID] = SaltHistoryResult(battleDate: battleDate,
                                                          warType: warType,
                                                          rows: rows,
                                                          fetchedAt: Date())
            LobbyLog.info("[saltfield-history] %@ 榜单 %ld 条（date=%@）",
                          accountID, rows.count, SaltHistoryCatalog.yymmddString(of: battleDate))
        }
    }

    /// warType 链式查询时的目标场次日期（在 issueTotalRank 之前由 UI 写入）。
    private var chainedBattleDate: [String: Date] = [:]

    /// 查询指定日期的盐场战绩（**主路径**，猫助手同源口径）：
    /// `legionwar_getdetails { date: "YYYY/MM/DD" }` → roleDetailsList（成员 胜/负/攻城）。
    public func requestWarDetails(accountID: String, battleDate: Date) {
        let dateKey = SaltHistoryCatalog.slashDateString(of: battleDate)
        historyBusy.insert(accountID)
        historyStatus[accountID] = "正在查询 \(dateKey) 的盐场战绩…"
        sendHistoryFrame(accountID: accountID,
                         command: "legionwar_getdetails",
                         paramsJSON: "{\"date\":\"\(dateKey)\"}",
                         kind: .warDetails(battleDate: battleDate),
                         startStatus: historyStatus[accountID] ?? "查询中…")
    }

    /// 该场次日期所属月份的 warType（已缓存才返回，否则 0）。
    private func monthlyWarType(for battleDate: Date, accountID: String) -> Int {
        let monthKey = SaltHistoryCatalog.firstSaturdayString(of: battleDate)
        return monthlyWarTypes[accountID]?[monthKey] ?? 0
    }

    private func startPollLoopIfNeeded() {
        guard pollTask == nil, !pollingAccountIDs.isEmpty else { return }
        pollTask = Task { @MainActor [weak self] in
            while let self, !self.pollingAccountIDs.isEmpty {
                self.pollOnce()
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanos)
            }
            self?.pollTask = nil
        }
    }

    /// 对所有开启轮询的账号发一轮 `war_getbattlefieldinfo`。
    private func pollOnce() {
        for accountID in pollingAccountIDs {
            poll(accountID: accountID)
        }
    }

    private func poll(accountID: String) {
        guard let state = states[accountID], state.battlefieldID > 0 else { return }
        guard let instance = pool?.existingSurface(forAccountID: accountID) else { return }
        // ack = 盐场最近响应 seq；seq = 盐场 client 游标 + 1（发送后即推进游标，
        // 与游戏自己的盐场请求交错使用同一连续序列——服务端按连续性校验）。
        let seq = state.clientSeq + 1
        guard let frame = try? PacketCaptureController.buildFrame(
            command: "war_getbattlefieldinfo",
            paramsJSON: "{\"battlefieldId\":\(state.battlefieldID)}",
            ack: state.serverSeq,
            seq: seq) else { return }
        states[accountID]?.clientSeq = seq
        let socketID = state.socketID
        Task { @MainActor in
            let diagnostic = await instance.sendRawFrame(base64: frame.base64EncodedString(),
                                                         socketID: socketID)
            if !diagnostic.hasPrefix("sent") {
                LobbyLog.warn("[saltfield] %@ 轮询帧未送达：%@", accountID, diagnostic)
            }
        }
    }

    // MARK: - 解码（与 PacketCaptureController.decode 同源，取沙场所需的子集）

    private struct DecodedFrame {
        let command: String
        let seq: Int64?
        let outerObject: BonObject?
        let inner: BonValue?
    }

    /// 任何一步失败返回 nil（非 px 帧 / 非 BON——盐场线上只可能是别的流量形态，交给抓包线）。
    private static func decode(_ frame: PacketFrame) -> DecodedFrame? {
        guard let data = Data(base64Encoded: frame.payloadBase64),
              data.count > 1, frame.kind == "binary" else { return nil }
        guard let plain = try? XorFrameCipher.open(data),
              let outer = try? Bon.decode(plain), let object = outer.objectValue else { return nil }
        guard let command = object["cmd"]?.stringValue else { return nil }
        var inner: BonValue?
        if case .binary(let body)? = object["body"], !body.isEmpty {
            inner = try? Bon.decode(body)
        }
        return DecodedFrame(command: command, seq: object["seq"]?.intValue,
                            outerObject: object, inner: inner)
    }

    // MARK: - 战场快照构建

    /// battlefield BON 对象 → 快照（含静态骨架合并 + 占领布局染色）。
    static func buildSnapshot(battlefield: BonObject,
                              battlefieldID: Int64,
                              timestampMs: Double) -> SaltFieldSnapshot {
        // ── 1. 建筑点（服务端动态，覆盖静态骨架）──
        var buildings: [String: SaltBuilding] = [:]
        forEachEntry(battlefield["buildingData"]) { _, value in
            guard let object = value.objectValue, let id = object["id"]?.stringValue else { return }
            buildings[id] = SaltBuilding(
                id: id,
                type: object["type"]?.intValue.flatMap(Int.init(exactly:)) ?? 9,
                belongsLegionID: object["belongsLegionId"]?.intValue.flatMap { $0 >= 0 ? $0 : nil },
                hp: object["hP"]?.intValue ?? 0,
                maxHP: object["maxHP"]?.intValue ?? 0,
                point: object["point"]?.intValue ?? 0
            )
        }

        // ── 2. 俱乐部 ──
        struct LegionDraft {
            var id: Int64 = 0
            var name = ""
            var colorIndex = 0
            var power: Int64 = 0
            var killCount: Int64 = 0
            var redCount: Int64 = 0
            var memberCount = 0
            var participantsCount = 0
            var onlineCount = 0
            var blessingCount = 0
            var blessingScore: Int64 = 0
            var reviveCount: Int64 = 0
            var danCount: Int64 = 0
            var buildingIDs: [String] = []
            var strongholdID = ""
            var score: Int64 = 0
        }
        var drafts: [Int64: LegionDraft] = [:]
        forEachEntry(battlefield["legions"]) { _, value in
            guard let object = value.objectValue, let id = object["id"]?.intValue else { return }
            var draft = LegionDraft()
            draft.id = id
            draft.name = object["name"]?.stringValue ?? "俱乐部\(id)"
            draft.colorIndex = object["color"]?.intValue.flatMap(Int.init(exactly:)) ?? 0
            draft.power = object["power"]?.intValue ?? 0
            draft.killCount = object["killCnt"]?.intValue ?? 0
            draft.redCount = object["custom"].flatMap { $0.path("red:quench") }?.intValue ?? 0
            draft.memberCount = object["membersV2"]?.objectValue?.count ?? 0
            draft.blessingCount = object["blessingIdList"]?.arrayValue?.count ?? 0
            draft.blessingScore = object["blessingScore"]?.intValue ?? 0
            draft.strongholdID = object["strongholdId"]?.stringValue ?? ""
            var buildingIDs: [String] = []
            forEachEntry(object["buildings"]) { key, _ in
                buildingIDs.append(key)
            }
            draft.buildingIDs = buildingIDs.sorted { lhs, rhs in
                let (lx, ly) = Self.coords(lhs), (rx, ry) = Self.coords(rhs)
                return lx != rx ? lx < rx : ly < ry
            }
            // 积分 = 占领点的分值和 + 四圣分（口径照抄自助手仓 extractValidData）。
            var score = draft.blessingScore
            for buildingID in draft.buildingIDs {
                score += buildings[buildingID]?.point ?? 0
            }
            draft.score = score
            drafts[id] = draft
        }

        // ── 3. 成员（顺路统计俱乐部的参与/在线/复活/丹）──
        var members: [SaltMember] = []
        forEachEntry(battlefield["roles"]) { _, value in
            guard let object = value.objectValue else { return }
            let legionID = object["legionID"]?.intValue ?? 0
            let die = object["d"]?.intValue ?? 0
            let revive = object["revive"]?.intValue ?? 0
            members.append(SaltMember(
                name: object["name"]?.stringValue ?? "?",
                legionID: legionID,
                state: object["state"]?.stringValue ?? "",
                digGround: object["aB"]?.intValue ?? 0,
                kill: object["killCnt"]?.intValue ?? 0,
                revive: revive,
                die: die,
                dan: max(0, die - 6),
                point: object["point"]?.intValue ?? 0,
                isOnline: object["isOnline"]?.boolValue ?? false
            ))
            if var draft = drafts[legionID] {
                draft.participantsCount += 1
                if object["isOnline"]?.boolValue == true { draft.onlineCount += 1 }
                draft.reviveCount += revive
                draft.danCount += max(0, die - 6)
                drafts[legionID] = draft
            }
        }

        let legions = drafts.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        let saltLegions = legions.map { draft in
            SaltLegion(id: draft.id, name: draft.name, colorIndex: draft.colorIndex,
                       power: draft.power, killCount: draft.killCount,
                       reviveCount: draft.reviveCount, danCount: draft.danCount,
                       redCount: draft.redCount, memberCount: draft.memberCount,
                       participantsCount: draft.participantsCount,
                       onlineCount: draft.onlineCount,
                       blessingCount: draft.blessingCount,
                       blessingScore: draft.blessingScore, score: draft.score,
                       buildingCount: draft.buildingIDs.count,
                       buildingIDs: draft.buildingIDs,
                       strongholdID: draft.strongholdID)
        }

        // ── 4. 地图渲染节点（静态骨架 + 动态归属 + 占领路径染色）──
        let nodes = Self.renderNodes(buildings: buildings, legions: saltLegions)

        return SaltFieldSnapshot(
            timestampMs: timestampMs,
            battlefieldID: battlefieldID > 0 ? battlefieldID : nil,
            nodes: nodes,
            legions: saltLegions,
            members: members.sorted { $0.kill != $1.kill ? $0.kill > $1.kill : $0.die < $1.die }
        )
    }

    /// BON 的对象（key 索引）与数组两种形态统一遍历（服务端结构形态不受文档约束）。
    private static func forEachEntry(_ value: BonValue?, _ body: (String, BonValue) -> Void) {
        if let object = value?.objectValue {
            for field in object.fields { body(field.key, field.value) }
        } else if let array = value?.arrayValue {
            for (index, item) in array.enumerated() { body(String(index), item) }
        }
    }

    // MARK: 历史响应解析

    /// `legion_getinfo` → 我方历史场次（口径照抄自助手仓 ClubHistoryRecords：
    /// warMap 按周分组 → flatten → reverse；warRank 同步 reverse 对齐）。
    /// 容错：`info` 包装缺失时退化用 body 顶层（响应结构若有出入，靠诊断日志定位）。
    static func parseHistoryBattles(inner: BonValue?) -> [SaltHistoryBattle] {
        let calendar = Calendar.current
        let source = inner?.path("info") ?? inner
        var raw: [(date: Date, type: Int)] = []
        forEachEntry(source?.path("warMap")) { _, value in
            forEachEntry(value) { _, battle in
                guard let stamp = battle.path("warDate")?.intValue, stamp > 0 else { return }
                let type = Int(battle.path("legionWarType")?.intValue ?? 0)
                raw.append((Date(timeIntervalSince1970: TimeInterval(stamp)), type))
            }
        }
        let ranks = source?.path("warRank")?.arrayValue?
            .compactMap { $0.intValue.flatMap(Int.init(exactly:)) } ?? []
        // 参考项目把两者都 reverse 后按下标对齐（reverse 后最新场次在前）。
        let reversed = raw.reversed()
        let reversedRanks = Array(ranks.reversed())
        var battles: [SaltHistoryBattle] = []
        for (index, item) in reversed.enumerated() {
            let day = calendar.startOfDay(for: item.date)
            battles.append(SaltHistoryBattle(date: day,
                                             warType: item.type,
                                             rank: index < reversedRanks.count ? reversedRanks[index] : 0))
        }
        return battles
    }

    /// 响应结构诊断：顶层与二级字段名（解析失败时进日志，直接对照真实结构改路径）。
    static func describeBodyKeys(inner: BonValue?) -> String {
        guard let object = inner?.objectValue else { return "（body 非对象）" }
        let top = object.keys.prefix(14).joined(separator: ",")
        var result = "顶层[\(top)]"
        if let info = object["info"]?.objectValue {
            result += " info[\(info.keys.prefix(14).joined(separator: ","))]"
        }
        return result
    }

    /// `saltroad_getsaltroadwartotalrank` → 总榜行（legionList；积分降序服务端已排）。
    static func parseRankList(inner: BonValue?) -> [SaltHistoryClubRow] {
        var rows: [SaltHistoryClubRow] = []
        forEachEntry(inner?.path("legionList")) { _, value in
            guard let object = value.objectValue else { return }
            rows.append(SaltHistoryClubRow(
                rank: object["rank"]?.intValue.flatMap(Int.init(exactly:)) ?? rows.count + 1,
                id: object["id"]?.intValue ?? 0,
                name: object["name"]?.stringValue ?? "?",
                power: object["power"]?.intValue ?? 0,
                score: object["score"]?.intValue ?? 0,
                redQuench: object["redQuench"]?.intValue.flatMap(Int.init(exactly:)) ?? 0,
                serverID: object["serverId"]?.intValue ?? 0
            ))
        }
        return rows.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.score > $1.score }
    }

    /// `legionwar_getdetails` → 成员明细（roleDetailsList；胜次降序 = 猫助手排序口径）。
    /// 容错：roleDetailsList 优先，退化尝试 body 顶层同名数组。
    static func parseWarDetails(inner: BonValue?) -> [SaltWarDetailRow] {
        var rows: [SaltWarDetailRow] = []
        let source = inner?.path("roleDetailsList") ?? inner
        forEachEntry(source) { _, value in
            guard let object = value.objectValue else { return }
            let name = object["name"]?.stringValue
                ?? object["roleName"]?.stringValue
                ?? object["nickname"]?.stringValue
                ?? "?"
            rows.append(SaltWarDetailRow(
                name: name,
                win: object["winCnt"]?.intValue.flatMap(Int.init(exactly:)) ?? 0,
                lose: object["loseCnt"]?.intValue.flatMap(Int.init(exactly:)) ?? 0,
                building: object["buildingCnt"]?.intValue.flatMap(Int.init(exactly:)) ?? 0
            ))
        }
        return rows.sorted { $0.win != $1.win ? $0.win > $1.win : $0.building > $1.building }
    }

    private static func coords(_ id: String) -> (Int, Int) {
        let parts = id.split(separator: "_")
        guard parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]) else { return (-1, -1) }
        return (x, y)
    }

    // MARK: 地图渲染（占领/分布布局的节点染色）

    /// 六边形错列邻接方向（odd-q；与自助手仓 HexGraph 一致）。
    private static let evenQDirs = [(-1, 0), (-1, -1), (0, 1), (0, -1), (1, 0), (1, -1)]
    private static let oddQDirs = [(-1, 0), (-1, 1), (0, 1), (0, -1), (1, 0), (1, 1)]

    /// 核心周围需要跟着核心染色的 6 个点（自助手仓的实测写死口径）。
    private static let coreNeighbors = ["19_16", "19_17", "20_16", "20_18", "21_16", "21_17"]
    private static let coreID = "20_17"

    /// 生成染色后的渲染节点表。
    /// 占领布局口径（自助手仓 drawCanvasLeft）：每个俱乐部对占领点两两 BFS
    /// （只走道路或本俱乐部节点），路径染俱乐部色；建筑自带归属即其基色。
    static func renderNodes(buildings: [String: SaltBuilding],
                            legions: [SaltLegion]) -> [String: SaltRenderedNode] {
        // 1. 合并节点：静态骨架打底，buildingData 覆盖。
        var typeByID = SaltFieldRoadPoints.nodes
        for (id, building) in buildings { typeByID[id] = building.type }
        // 2. 归属：buildingData 的 belongsLegionId 为准（大本营的归属来自 legions.strongholdId）。
        var ownerByID: [String: Int64] = [:]
        for (id, building) in buildings {
            if let legionID = building.belongsLegionID { ownerByID[id] = legionID }
        }
        var strongholdByLegion: [Int64: String] = [:]
        for legion in legions where !legion.strongholdID.isEmpty {
            strongholdByLegion[legion.id] = legion.strongholdID
            ownerByID[legion.strongholdID] = legion.id
        }
        // 3. 邻接表（只在已知节点之间连边）。
        var adjacency: [String: [String]] = [:]
        for id in typeByID.keys {
            let (x, y) = coords(id)
            guard x >= 0 else { continue }
            let dirs = x % 2 == 0 ? evenQDirs : oddQDirs
            var neighbors: [String] = []
            for (dq, dr) in dirs {
                let neighbor = "\(x + dq)_\(y + dr)"
                if typeByID[neighbor] != nil { neighbors.append(neighbor) }
            }
            adjacency[id] = neighbors
        }
        // 4. 基色：有归属 → 俱乐部色；否则按类型。
        var colorByID: [String: String] = [:]
        for id in typeByID.keys {
            if let legionID = ownerByID[id],
               let legion = legions.first(where: { $0.id == legionID }) {
                colorByID[id] = SaltColorPalette.legionColor(legion.colorIndex)
            } else {
                colorByID[id] = SaltColorPalette.typeColor(typeByID[id] ?? 9)
            }
        }
        // 5. 占领路径染色：两两 BFS，只走道路或本俱乐部节点，路径染俱乐部色。
        //    占领点集合直接用 legions.buildings 的 key（与自助手仓同源；
        //    buildingData 的归属只做基色）。
        var belongsByID = ownerByID
        for legion in legions {
            var owned = legion.buildingIDs
            if owned.isEmpty {
                owned = legionBuildingIDs(legionID: legion.id, buildings: buildings,
                                          stronghold: legion.strongholdID)
            }
            guard owned.count > 1 else { continue }
            for i in 0..<(owned.count - 1) {
                for j in (i + 1)..<owned.count {
                    let path = shortestPath(from: owned[i], to: owned[j],
                                            legionID: legion.id, typeByID: typeByID,
                                            belongsByID: belongsByID, adjacency: adjacency)
                    for nodeID in path {
                        belongsByID[nodeID] = legion.id
                        colorByID[nodeID] = SaltColorPalette.legionColor(legion.colorIndex)
                    }
                }
            }
        }
        // 6. 核心及其 6 邻点跟随核心归属（照抄自助手仓的特殊处理）。
        if let coreOwner = belongsByID[coreID], let coreColor = colorByID[coreID] {
            for neighbor in coreNeighbors where typeByID[neighbor] != nil {
                belongsByID[neighbor] = coreOwner
                colorByID[neighbor] = coreColor
            }
        }
        // 7. 产出渲染节点。
        var result: [String: SaltRenderedNode] = [:]
        for (id, type) in typeByID {
            let (x, y) = coords(id)
            guard x >= 0 else { continue }
            let building = buildings[id]
            result[id] = SaltRenderedNode(
                id: id, x: x, y: y, type: type,
                colorHex: colorByID[id] ?? SaltColorPalette.typeColor(type),
                belongsLegionID: belongsByID[id],
                point: building?.point ?? 0,
                hp: building?.hp ?? 0,
                maxHP: building?.maxHP ?? 0
            )
        }
        return result
    }

    /// 俱乐部的占领点集合：legions.buildings 的 key（服务端字段）。
    /// 快照里为了传输精简只留了数量，这里从 buildings 的归属反推（归属 = 该俱乐部的点）。
    private static func legionBuildingIDs(legionID: Int64,
                                          buildings: [String: SaltBuilding],
                                          stronghold: String) -> [String] {
        var ids = buildings.filter { $0.value.belongsLegionID == legionID }.map(\.key)
        if !stronghold.isEmpty, !ids.contains(stronghold) { ids.append(stronghold) }
        // 与自助手仓同序：先 x 后 y 排序（路径染色对配对顺序敏感，保持同口径）。
        return ids.sorted { lhs, rhs in
            let (lx, ly) = coords(lhs), (rx, ry) = coords(rhs)
            return lx != rx ? lx < rx : ly < ry
        }
    }

    /// BFS 最短路径（限制：途经点必须是道路或该俱乐部节点）。
    /// 返回含起点终点的完整路径；不可达返回空。
    private static func shortestPath(from startID: String, to endID: String,
                                     legionID: Int64,
                                     typeByID: [String: Int],
                                     belongsByID: [String: Int64],
                                     adjacency: [String: [String]]) -> [String] {
        guard startID != endID, typeByID[startID] != nil, typeByID[endID] != nil else { return [] }
        var predecessors: [String: String?] = [startID: nil]
        var queue = [startID]
        var found = false
        while !queue.isEmpty && !found {
            let current = queue.removeFirst()
            // 与自助手仓一致：非道路的中转点必须是本俱乐部节点。
            if typeByID[current] != 9, belongsByID[current] != legionID { continue }
            for neighbor in adjacency[current] ?? [] where predecessors[neighbor] == nil {
                predecessors[neighbor] = current
                if neighbor == endID { found = true; break }
                queue.append(neighbor)
            }
        }
        guard found, let _ = predecessors[endID] else { return [] }
        var path: [String] = []
        var cursor: String? = endID
        while let node = cursor {
            path.append(node)
            cursor = predecessors[node] ?? nil
        }
        return path.reversed()
    }
}
