import Foundation
import LobbyDomain
import LobbyIPC

// MARK: - 盐场实时图表 · 宿主侧控制器
//
// 与 `PacketCaptureController`（通用抓包）并行的一条**专题解码线**：
// 同样的页面帧（`PageEvent.packet`）进来，这里只关心**盐场战场连接**（游戏进盐场
// 时自建的第二条 WSS，`war_*` 命令族）上的流量，把 `war_enterbattlefield`
// 响应解成「地图占领 + 俱乐部/个人战况」快照，供独立图表窗口渲染。
//
//   PageEvent.packet(PacketFrame)
//     → px 信封解封（`XorFrameCipher`）→ BON 外层（cmd/ack/seq/body）
//     → body 内层再 BON → battlefield{buildingData, legions, roles}
//     → SaltFieldSnapshot（静态骨架合并 + 占领布局 BFS 染色）
//
// ⚠️ 实时数据的**命令口径以参考脚本为准**（2026-09-18 核对 雪碧助手.js / 星驰-无登录.js）：
//   · 战场连接（实时战况）：`war_enterbattlefield { battlefieldId }`
//     —— 雪碧助手 fetchGlobalWarReport 的主命令，响应 `body.battlefield{legions,roles,...}`。
//     早先这里发的是 `war_getbattlefieldinfo`（指令库里 inferred 的猜测名）——两个脚本里
//     **都没有这个命令**，服务端不认，于是快照永远为空（就是「实时战况没有数据」的根因）。
//   · 主连接（实时地图）：`legion_getbattlefield {}` → `info{phase, battlefieldId}`；
//     `legion_getopponent { phase, battlefieldId }` → 每条 legion 的 `position`（大本营序号）；
//     `legion_getinfo` / `legion_getinfobyid` → 俱乐部名/服号/红淬/公告。
//     这两步**不依赖战场连接**，盐场没进场也能查到落位，是地图能在「没快照」时也画出来的原因。
//
// 与抓包的分工/共存：图表开着时若抓包没开，会话模型会顺手把页面上报打开
// （见 `LobbySessionModel.toggleSaltFieldChart`）——页面帧只有一份，两条解码线
// 各取所需互不干扰；抓包窗口照常能看见这些帧。
//
// 主动轮询（实时性）：游戏页面只有玩家操作时才拉战场信息，图表要"实时"就得
// 自己发。这里每 4s 对已开启图表的账号构一帧 `war_enterbattlefield`
// （`PacketCaptureController.buildFrame` 同源构帧），**定向**发给盐场 socket：
//   · socket 定向：主连接与盐场连接的 URL 都含 "agent"（实测主连接
//     `wss://xxz-xyzw.hortorgames.com/agent?…`），按 URL 挑会发错——
//     页面代理 v3 起给每个构造的 socket 发 `sid`，盐场帧路过时记住 sid，
//     发送时点名（`sendRawFrame(base64:socketID:)`）；没有盐场 sid 就说明
//     战场连接还没出现，此时不轮询（等玩家进场，游戏自己会发第一帧）；
//   · seq 编址：盐场连接有**独立的** seq 序列（与主连接的计数值完全无关），
//     这里只统计 war_* 帧的 seq 维护盐场自己的 client/server 游标；
//   · battlefieldId：优先取主连接 `legion_getbattlefield` 的结果（不进场也有），
//     兜底用游戏自发的心跳 `war_ping` / `war_enterbattlefield` body 里的值。
@MainActor
public final class SaltFieldChartController: ObservableObject {
    /// 轮询周期（毫秒）。盐场心跳 5s 一条，4s 拉一次信息在节流与实时之间取平衡。
    public static let pollIntervalNanos: UInt64 = 4_000_000_000

    /// 实时地图归属的重查间隔（以轮询拍数计；8 拍 × 4s ≈ 32s）。
    private static let liveMapRefreshTicks = 8

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

    // MARK: 实时地图归属（主连接链；与战场快照相互独立）
    /// 账号 → 实时地图归属（phase / battlefieldId / 各俱乐部落位）。
    @Published public private(set) var liveBattlefields: [String: SaltLiveBattlefield] = [:]
    /// 账号 → 实时地图状态文案（窗口顶部提示 / 排错用）。
    @Published public private(set) var liveStatus: [String: String] = [:]
    /// 账号 → **我方军团 ID**（`legion_getinfo` 的 info.id）——用来自动认领我方大本营。
    @Published public private(set) var ownLegionIDs: [String: Int64] = [:]
    /// 正在跑实时地图链的账号（防重入）。
    private var liveBusy: Set<String> = []
    /// 链中途的暂存（battlefield → opponent → 各家详情逐级填充）。
    private struct LiveMapDraft {
        var phase = 0
        var battlefieldID: Int64 = 0
        var positions: [(legionID: Int64, position: Int)] = []
        var clubs: [SaltLiveClub] = []
        /// 已发起详情的家数 / 已回来的家数（全回来才发布）。
        var requested = 0
        var received = 0
    }
    private var liveDrafts: [String: LiveMapDraft] = [:]
    /// 俱乐部详情缓存（legionID → 详情）：刷新时只补没缓存的，省掉每轮 20 次往返。
    struct ClubDetail {
        let name: String
        let serverID: Int64
        let power: Int64
        let quench: Int
        let announcement: String
    }
    private var clubDetails: [Int64: ClubDetail] = [:]
    /// 每轮实时地图最多查多少家详情（对手名单可能很长，但盐场就是 20 个大本营）。
    private static let maxClubDetailsPerRound = 24

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

    /// 在途历史查询（响应匹配：`resp` 字段 → cmd 包含 → FIFO 兜底；无响应自动重试）。
    private struct PendingHistoryQuery {
        enum Kind {
            case warType(monthFirstSaturday: String)   // 命中后接着查 totalRank
            case totalRank(battleDate: Date)
            case legionInfo                            // 我方历史场次（warMap 名次）
            case warDetails(battleDate: Date)          // 指定日期成员明细（主路径）
            // ── 实时地图链（主连接；口径见文件头注释）──
            case battlefieldInfo                       // legion_getbattlefield → phase + battlefieldId
            case opponentLegions                       // legion_getopponent → 各家 position（大本营序号）
            case legionDetail(legionID: Int64)         // legion_getinfobyid → 俱乐部详情

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
                case .battlefieldInfo:
                    return loweredResponseCommand.contains("legion_getbattlefield")
                        || compact.contains("legiongetbattlefield")
                case .opponentLegions:
                    return loweredResponseCommand.contains("legion_getopponent")
                        || compact.contains("legiongetopponent")
                case .legionDetail:
                    return loweredResponseCommand.contains("legion_getinfobyid")
                        || compact.contains("legiongetinfobyid")
                }
            }
        }
        /// 请求所属通道：历史战绩 / 实时地图（决定状态文案与 busy 标记写哪一套）。
        enum Channel { case history, live }
        let kind: Kind
        let channel: Channel
        let command: String
        let paramsJSON: String
        var seq: Int64
        var issuedAt: Date
        var retryCount: Int = 0
    }
    private var pendingHistory: [String: [PendingHistoryQuery]] = [:]
    private static let historyTimeout: TimeInterval = 12
    /// 无响应自动重试次数上限。
    private static let maxRetry = 2
    /// FIFO 兜底配对的信任窗口（秒）：查询在途时到达的第一个业务响应按序配对，
    /// 超过窗口的帧只认 resp/cmd 精确匹配（防误吞游戏自己的推送）。
    private static let fifoWindowSeconds: TimeInterval = 8
    /// 未匹配业务帧的诊断日志计数（每账号限 3 条，防刷屏）。
    private var unmatchedLogCounts: [String: Int] = [:]

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
        // 游戏自己发的进场帧：把它的 body 结构打一条日志（每账号一次）——
        // 我们轮询的 params 就是照它抄的，出问题时这是唯一可对照的现场。
        if frame.direction == "send", lowered.contains("war_enterbattlefield") {
            let key = "\(accountID)#enterSend"
            if unmatchedLogCounts[key, default: 0] == 0 {
                unmatchedLogCounts[key] = 1
                LobbyLog.info("[saltfield] %@ 游戏进场帧结构：%@",
                              accountID, Self.describeBodyKeys(inner: decoded.inner))
            }
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
        //
        // ⚠️ 命令是 `war_enterbattlefield`（不是早先猜的 war_getbattlefieldinfo）：
        //    · 游戏自己在玩家进盐场时会发它 —— 白捡一份快照，不用等我们的轮询；
        //    · 我们的 4s 轮询也发它（见 poll），响应走同一条路。
        // 旧名保留在判断里只是为了兼容可能存在的服务端别名，无副作用。
        if frame.direction == "recv",
           lowered.contains("war_enterbattlefield") || lowered.contains("war_getbattlefieldinfo"),
           let body = decoded.inner, let battlefield = body.path("battlefield")?.objectValue {
            // 响应里的 battlefieldId 优先（进战场那一刻我们可能还没学到 id）。
            let responseID = body.path("battlefieldId")?.intValue ?? 0
            if responseID > 0, state.battlefieldID != responseID {
                state.battlefieldID = responseID
                changedLink = true
            }
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
            // 一次性诊断：据点条目里到底有哪些字段——「每个据点自己的名称」在不在服务端，
            // 看这一条日志就知道（不在的话得另找来源，见 SaltBuilding.name 注释）。
            let probeKey = "\(accountID)#buildingFields"
            if unmatchedLogCounts[probeKey, default: 0] == 0 {
                var logged = false
                Self.forEachEntry(battlefield["buildingData"]) { _, value in
                    guard !logged, let object = value.objectValue else { return }
                    logged = true
                    let keys = object.fields.map { $0.key }.joined(separator: ",")
                    LobbyLog.info("[saltfield] %@ 据点条目字段：[%@] name=「%@」",
                                  accountID, keys, object["name"]?.stringValue ?? "")
                }
                if logged { unmatchedLogCounts[probeKey] = 1 }
            }
        } else if frame.direction == "recv", lowered.contains("war_enterbattlefield") {
            // 收到进场响应却解不出 battlefield：结构诊断（服务端换字段 / 压了 body /
            // 我们发的 params 不对，都会落到这里）。限 3 条防刷屏。
            let key = "\(accountID)#enter"
            let count = unmatchedLogCounts[key, default: 0]
            unmatchedLogCounts[key] = count + 1
            if count < 3 {
                LobbyLog.warn("[saltfield] %@ war_enterbattlefield 响应无 battlefield 字段（结构：%@）",
                              accountID, Self.describeBodyKeys(inner: decoded.inner))
            }
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
        // 实时地图归属（与快照同生命周期：实例关了就没有「实时」可言）
        liveBattlefields.removeValue(forKey: accountID)
        ownLegionIDs.removeValue(forKey: accountID)
        liveStatus.removeValue(forKey: accountID)
        liveBusy.remove(accountID)
        liveDrafts.removeValue(forKey: accountID)
    }

    // MARK: - 轮询

    /// 开/关某账号的主动轮询（图表窗口开关的直连入口）。
    /// 开启时顺手拉一轮实时地图归属（主连接链）——它不依赖战场连接，
    /// 是「窗口一打开就有东西看」的那条路。
    public func setPolling(_ enabled: Bool, accountID: String) {
        if enabled {
            pollingAccountIDs.insert(accountID)
            refreshLiveMap(accountID: accountID)
        } else {
            pollingAccountIDs.remove(accountID)
        }
        startPollLoopIfNeeded()
    }

    /// 立即对指定账号拉一轮（图表窗口的「立即拉取」按钮）：战场快照 + 地图归属。
    public func pollNow(accountID: String) {
        poll(accountID: accountID)
        refreshLiveMap(accountID: accountID)
    }

    // MARK: - 历史战绩查询（主连接；协议口径见 SaltFieldModels 注释）

    /// 拉取我方历史场次（`legion_getinfo` → info.warMap + warRank）。
    /// 日历的可点日期与我方名次都来自这里。
    public func fetchHistoryBattles(accountID: String) {
        enqueueHistorySend(accountID: accountID, command: "legion_getinfo",
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
            enqueueHistorySend(accountID: accountID,
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
        enqueueHistorySend(accountID: accountID,
                           command: "saltroad_getsaltroadwartotalrank",
                           paramsJSON: "{\"date\":\"\(dateKey)\",\"startRank\":\(range.startRank),\"endRank\":\(range.endRank)}",
                           kind: .totalRank(battleDate: battleDate),
                           startStatus: "正在查询 \(SaltHistoryCatalog.warTypeName(warType)) 榜单…")
    }

    /// 串行队列：同一账号的历史查询**按发起顺序逐个执行**——前一个拿到响应后才发
    /// 下一个。并发两连发会在游戏封装里响应错位（实测：legion_getinfo 与
    /// legionwar_getdetails 同时在途时，后者的 Promise 拿到前者的响应 → 解析为空）。
    private var historyChainTasks: [String: Task<Void, Never>] = [:]

    private func enqueueHistorySend(accountID: String, command: String, paramsJSON: String,
                                    kind: PendingHistoryQuery.Kind, startStatus: String,
                                    channel: PendingHistoryQuery.Channel = .history) {
        let previous = historyChainTasks[accountID]
        historyChainTasks[accountID] = Task { @MainActor [weak self] in
            _ = await previous?.value
            await self?.performHistorySend(accountID: accountID, command: command,
                                           paramsJSON: paramsJSON, kind: kind,
                                           startStatus: startStatus, channel: channel)
        }
    }

    /// 发送历史查询命令。**主路径走游戏自己的发送封装**（`window.ws.sendAsync`，
    /// 猫助手同款）：seq 由游戏计数器管理，与游戏自身请求天然连续（宿主直发的
    /// 撞号 seq 会被服务端静默丢弃），且响应经封装的 Promise 直接带回（body 已由
    /// 游戏解码），无需抓包流配对。封装不可用时回退「原生日发 + pending 匹配」。
    private func performHistorySend(accountID: String, command: String, paramsJSON: String,
                                    kind: PendingHistoryQuery.Kind, startStatus: String,
                                    channel: PendingHistoryQuery.Channel) async {
        guard let instance = pool?.existingSurface(forAccountID: accountID) else {
            setBusy(channel, accountID: accountID, busy: false)
            setStatus(channel, accountID: accountID, text: "实例未运行")
            return
        }
        setBusy(channel, accountID: accountID, busy: true)
        setStatus(channel, accountID: accountID, text: startStatus)
        let pending = PendingHistoryQuery(kind: kind, channel: channel, command: command,
                                          paramsJSON: paramsJSON, seq: 0, issuedAt: Date())
        let js = PacketCaptureScript.sendViaGame(command: command, paramsJSON: paramsJSON)
        let responseText = await instance.evaluatePageJS(js)
        guard let inner = Self.parseViaGameResponse(responseText) else {
            LobbyLog.warn("[saltfield-history] %@ 游戏封装不可用/失败，回退直发通道：%@",
                          accountID, responseText.prefix(200))
            fallbackSendRaw(accountID: accountID, pending: pending)
            return
        }
        handleHistoryResponse(pending: pending, inner: inner, accountID: accountID)
    }

    /// 通道 → 状态文案 / busy 标记（历史战绩与实时地图各一套，互不覆盖）。
    private func setStatus(_ channel: PendingHistoryQuery.Channel, accountID: String, text: String) {
        switch channel {
        case .history: historyStatus[accountID] = text
        case .live: liveStatus[accountID] = text
        }
    }

    private func setBusy(_ channel: PendingHistoryQuery.Channel, accountID: String, busy: Bool) {
        switch channel {
        case .history:
            if busy { historyBusy.insert(accountID) } else { historyBusy.remove(accountID) }
        case .live:
            if busy { liveBusy.insert(accountID) } else { liveBusy.remove(accountID) }
        }
    }

    /// 解析 sendViaGame 的页面回执：`{"__ok":true,"data":…}` → data 的 BonValue 树。
    private static func parseViaGameResponse(_ text: String) -> BonValue? {
        guard !text.contains("__error"),
              let data = text.data(using: .utf8),
              let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (wrapper["__ok"] as? Bool) == true,
              let payload = wrapper["data"] else { return nil }
        let payloadJSON = (try? JSONSerialization.data(withJSONObject: payload))
            ?? Data("{}".utf8)
        return try? PacketCaptureController.jsonToBonValue(
            String(decoding: payloadJSON, as: UTF8.self))
    }

    /// 回退通道：原生日发（sendRawFrame + pending 响应匹配 + 超时重试）。
    private func fallbackSendRaw(accountID: String, pending: PendingHistoryQuery) {
        let channel = pending.channel
        guard let main = mainStates[accountID],
              main.socketID >= 0 || main.serverSeq > 0 else {
            setBusy(channel, accountID: accountID, busy: false)
            setStatus(channel, accountID: accountID, text: "主连接未就绪：请先启动该账号的游戏实例")
            return
        }
        guard let instance = pool?.existingSurface(forAccountID: accountID) else {
            setBusy(channel, accountID: accountID, busy: false)
            setStatus(channel, accountID: accountID, text: "实例未运行")
            return
        }
        let seq = main.clientSeq + 1
        guard let frame = try? PacketCaptureController.buildFrame(
            command: pending.command, paramsJSON: pending.paramsJSON,
            ack: main.serverSeq, seq: seq) else {
            setBusy(channel, accountID: accountID, busy: false)
            setStatus(channel, accountID: accountID, text: "构帧失败")
            return
        }
        mainStates[accountID]?.clientSeq = seq
        var queued = pending
        queued.seq = seq
        queued.issuedAt = Date()
        pendingHistory[accountID, default: []].append(queued)
        unmatchedLogCounts[accountID] = 0
        let socketID = main.socketID
        Task { @MainActor [weak self] in
            let diagnostic = await instance.sendRawFrame(base64: frame.base64EncodedString(),
                                                         socketID: socketID)
            if !diagnostic.hasPrefix("sent") {
                self?.setStatus(pending.channel, accountID: accountID,
                                text: "发送失败：\(diagnostic)")
                self?.pendingHistory[accountID]?.removeAll { $0.seq == seq }
                LobbyLog.warn("[saltfield-history] %@ 发送 %@ 失败：%@",
                              accountID, pending.command, diagnostic)
            } else {
                LobbyLog.info("[saltfield-history] %@ 已发 %@ seq=%lld ack=%lld",
                              accountID, pending.command, seq, main.serverSeq)
            }
        }
        scheduleHistoryTimeout(accountID: accountID, seq: seq)
    }

    /// 超时调度：12s 无响应 → 自动重试（新 seq 重新入队），重试上限后报失败。
    private func scheduleHistoryTimeout(accountID: String, seq: Int64) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.historyTimeout * 1_000_000_000))
            guard let self, var queue = self.pendingHistory[accountID],
                  let index = queue.firstIndex(where: { $0.seq == seq }) else { return }
            let pending = queue.remove(at: index)
            self.pendingHistory[accountID] = queue
            guard Date().timeIntervalSince(pending.issuedAt) >= Self.historyTimeout - 1 else { return }
            if pending.retryCount < Self.maxRetry {
                LobbyLog.warn("[saltfield-history] %@ %@ 无响应（seq=%lld），重试 %ld/%ld",
                              accountID, pending.command, seq,
                              pending.retryCount + 1, Self.maxRetry)
                self.setStatus(pending.channel, accountID: accountID,
                               text: "无响应，自动重试 \(pending.retryCount + 1)/\(Self.maxRetry)（seq 序列校验或 cmd 匹配问题）")
                self.resendHistoryFrame(accountID: accountID, pending: pending)
            } else {
                self.setBusy(pending.channel, accountID: accountID, busy: false)
                self.setStatus(pending.channel, accountID: accountID,
                               text: "查询失败：\(pending.command) 重试 \(Self.maxRetry) 次均无响应（服务端可能丢弃了不连续的 seq，建议稍后再试）")
                LobbyLog.warn("[saltfield-history] %@ %@ 重试耗尽", accountID, pending.command)
            }
        }
    }

    /// 用新 seq 重发同一命令（服务端按连续 seq 校验，撞号/跳号会被静默丢弃——重试换号）。
    private func resendHistoryFrame(accountID: String, pending: PendingHistoryQuery) {
        guard let main = mainStates[accountID],
              let instance = pool?.existingSurface(forAccountID: accountID) else {
            setBusy(pending.channel, accountID: accountID, busy: false)
            setStatus(pending.channel, accountID: accountID, text: "实例未运行，查询中断")
            return
        }
        let seq = main.clientSeq + 1
        guard let frame = try? PacketCaptureController.buildFrame(
            command: pending.command, paramsJSON: pending.paramsJSON,
            ack: main.serverSeq, seq: seq) else { return }
        mainStates[accountID]?.clientSeq = seq
        var retried = pending
        retried.seq = seq
        retried.issuedAt = Date()
        retried.retryCount += 1
        pendingHistory[accountID, default: []].append(retried)
        let socketID = main.socketID
        Task { @MainActor in
            let diagnostic = await instance.sendRawFrame(base64: frame.base64EncodedString(),
                                                         socketID: socketID)
            LobbyLog.info("[saltfield-history] %@ 重试 %@ seq=%lld → %@",
                          accountID, pending.command, seq, diagnostic)
        }
        scheduleHistoryTimeout(accountID: accountID, seq: seq)
    }

    /// 响应匹配（逐级退化）：① 响应外层 `resp` 字段 == 在途请求 seq；
    /// ② 响应 cmd（小写）按 Kind.matches 命中。命中处理并返回 true。
    private func tryMatchHistoryResponse(command: String, object: BonObject?,
                                         inner: BonValue?, accountID: String) -> Bool {
        guard var queue = pendingHistory[accountID], !queue.isEmpty else { return false }
        let lowered = command.lowercased()
        var matched: PendingHistoryQuery?
        var matchedBy = ""
        if let respSeq = object?["resp"]?.intValue,
           let index = queue.firstIndex(where: { $0.seq == respSeq }) {
            matched = queue.remove(at: index)
            matchedBy = "resp 字段"
        } else if let index = queue.firstIndex(where: { $0.kind.matches(lowered) }) {
            matched = queue.remove(at: index)
            matchedBy = "cmd 匹配"
        } else if !queue.isEmpty,
                  Date().timeIntervalSince(queue[0].issuedAt) < Self.fifoWindowSeconds {
            // FIFO 兜底：查询在途且在信任窗口内，到达的第一个业务响应按序配对
            // （服务端串行处理，游戏空闲时第一个响应即我们的响应）。
            matched = queue.remove(at: 0)
            matchedBy = "fifo 兜底"
        }
        guard let pending = matched else {
            // 在途查询存在但帧没对上：打结构诊断（限 3 条/账号），帮助定位响应 cmd 名。
            unmatchedLogCounts[accountID, default: 0] += 1
            if unmatchedLogCounts[accountID] ?? 0 <= 3 {
                LobbyLog.warn("[saltfield-history] %@ 收到未匹配业务帧 cmd=%@ 结构：%@",
                              accountID, command, Self.describeBodyKeys(inner: inner))
            }
            pendingHistory[accountID] = queue
            return false
        }
        unmatchedLogCounts[accountID] = 0
        pendingHistory[accountID] = queue
        LobbyLog.info("[saltfield-history] %@ 响应匹配（%@）：%@", accountID, matchedBy, command)
        handleHistoryResponse(pending: pending, inner: inner, accountID: accountID)
        return true
    }

    private func handleHistoryResponse(pending: PendingHistoryQuery,
                                       inner: BonValue?, accountID: String) {
        switch pending.kind {
        case .legionInfo:
            setBusy(pending.channel, accountID: accountID, busy: false)
            // 我方军团 ID（自动认领我方大本营用；历史页与实时页都会走到这里）。
            if let ownID = Self.parseOwnLegionID(inner: inner) {
                if ownLegionIDs[accountID] != ownID {
                    ownLegionIDs[accountID] = ownID
                    LobbyLog.info("[saltfield-live] %@ 我方军团 ID = %lld", accountID, ownID)
                }
            }
            let battles = Self.parseHistoryBattles(inner: inner)
            if battles.isEmpty {
                let structure = Self.describeBodyKeys(inner: inner)
                setStatus(pending.channel, accountID: accountID,
                          text: "未查到历史场次（结构诊断见 diagnostics.log 的 [saltfield-history]）")
                LobbyLog.warn("[saltfield-history] %@ warMap 解析为空。响应结构：%@",
                              accountID, structure)
            } else {
                setStatus(pending.channel, accountID: accountID,
                          text: "历史场次已加载：共 \(battles.count) 场")
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
        case .battlefieldInfo:
            // 第一步：legion_getbattlefield → phase + battlefieldId。
            guard let info = Self.parseBattlefieldInfo(inner: inner) else {
                setBusy(.live, accountID: accountID, busy: false)
                setStatus(.live, accountID: accountID,
                          text: "未找到盐场战场（本月非盐场周 / 尚未报名？）")
                LobbyLog.warn("[saltfield-live] %@ legion_getbattlefield 无 battlefieldId，结构：%@",
                              accountID, Self.describeBodyKeys(inner: inner))
                return
            }
            var draft = LiveMapDraft()
            draft.phase = info.phase
            draft.battlefieldID = info.battlefieldID
            liveDrafts[accountID] = draft
            // 顺手喂给战场连接状态：即使游戏没发过心跳，战场轮询也能靠它起步。
            var linkState = states[accountID] ?? WarLinkState()
            if linkState.battlefieldID != info.battlefieldID {
                linkState.battlefieldID = info.battlefieldID
                states[accountID] = linkState
            }
            setStatus(.live, accountID: accountID,
                      text: "已定位战场 #\(info.battlefieldID)（phase \(info.phase)），正在查对手…")
            LobbyLog.info("[saltfield-live] %@ 战场 #%lld phase=%ld",
                          accountID, info.battlefieldID, info.phase)
            enqueueHistorySend(accountID: accountID,
                               command: "legion_getopponent",
                               paramsJSON: "{\"phase\":\(info.phase),\"battlefieldId\":\(info.battlefieldID)}",
                               kind: .opponentLegions,
                               startStatus: "正在查对手俱乐部…",
                               channel: .live)
        case .opponentLegions:
            // 第二步：拿到各家 position（大本营序号）→ 补详情（缓存命中直接用）。
            guard var draft = liveDrafts[accountID] else { return }
            let entries = Self.parseOpponentLegions(inner: inner)
            guard !entries.isEmpty else {
                setBusy(.live, accountID: accountID, busy: false)
                setStatus(.live, accountID: accountID,
                          text: "战场 #\(draft.battlefieldID) 没有对手名单（可能尚未分组）")
                LobbyLog.warn("[saltfield-live] %@ legion_getopponent 无 legions，结构：%@",
                              accountID, Self.describeBodyKeys(inner: inner))
                return
            }
            draft.positions = entries
            draft.clubs = []
            draft.requested = 0
            draft.received = 0
            var missing: [Int64] = []
            for entry in entries {
                if let detail = clubDetails[entry.legionID] {
                    draft.clubs.append(Self.club(legionID: entry.legionID, position: entry.position,
                                                 detail: detail))
                } else if missing.count < Self.maxClubDetailsPerRound {
                    missing.append(entry.legionID)
                }
            }
            draft.requested = missing.count
            liveDrafts[accountID] = draft
            // 顺手查一次我方军团信息（拿 info.id → 自动认领我方大本营）。
            // 复用 .legionInfo 这条 kind（同一个命令），但走 live 通道：状态文案写 liveStatus，
            // 不会污染历史战绩页；顺带把历史场次也刷新一遍（同一份数据，无害）。
            if ownLegionIDs[accountID] == nil {
                enqueueHistorySend(accountID: accountID,
                                   command: "legion_getinfo",
                                   paramsJSON: "{}",
                                   kind: .legionInfo,
                                   startStatus: "正在认领我方大本营…",
                                   channel: .live)
            }
            LobbyLog.info("[saltfield-live] %@ 对手 %ld 家（缓存命中 %ld，待补 %ld）",
                          accountID, entries.count, draft.clubs.count, missing.count)
            guard !missing.isEmpty else {
                publishLiveBattlefield(accountID: accountID)
                return
            }
            setStatus(.live, accountID: accountID,
                      text: "战场 #\(draft.battlefieldID)：\(entries.count) 家俱乐部，正在补详情…")
            for legionID in missing {
                enqueueHistorySend(accountID: accountID,
                                   command: "legion_getinfobyid",
                                   paramsJSON: "{\"legionId\":\(legionID)}",
                                   kind: .legionDetail(legionID: legionID),
                                   startStatus: "正在补俱乐部详情…",
                                   channel: .live)
            }
        case .legionDetail(let legionID):
            // 第三步：逐家详情回填，全回来（或到上限）后发布。
            guard var draft = liveDrafts[accountID] else { return }
            if let detail = Self.parseClubDetail(inner: inner) {
                clubDetails[legionID] = detail
                if let position = draft.positions.first(where: { $0.legionID == legionID })?.position {
                    draft.clubs.removeAll { $0.legionID == legionID }
                    draft.clubs.append(Self.club(legionID: legionID, position: position,
                                                 detail: detail))
                }
            } else {
                LobbyLog.warn("[saltfield-live] %@ 俱乐部 %lld 详情解析为空，结构：%@",
                              accountID, legionID, Self.describeBodyKeys(inner: inner))
            }
            draft.received += 1
            liveDrafts[accountID] = draft
            if draft.received >= draft.requested {
                publishLiveBattlefield(accountID: accountID)
            }
        }
    }

    /// 俱乐部详情 → 地图归属条目。
    private static func club(legionID: Int64, position: Int,
                             detail: ClubDetail) -> SaltLiveClub {
        SaltLiveClub(legionID: legionID, position: position, name: detail.name,
                     serverID: detail.serverID, power: detail.power,
                     quench: detail.quench, announcement: detail.announcement)
    }

    /// 发布一轮实时地图归属（按大本营序号排序）。
    private func publishLiveBattlefield(accountID: String) {
        guard let draft = liveDrafts[accountID] else { return }
        let clubs = draft.clubs.sorted {
            $0.position != $1.position ? $0.position < $1.position : $0.legionID < $1.legionID
        }
        liveBattlefields[accountID] = SaltLiveBattlefield(phase: draft.phase,
                                                          battlefieldID: draft.battlefieldID,
                                                          clubs: clubs,
                                                          fetchedAt: Date())
        setBusy(.live, accountID: accountID, busy: false)
        var counts: [SaltAlliance.Name: Int] = [:]
        for club in clubs { counts[club.alliance, default: 0] += 1 }
        let allianceText = SaltAlliance.Name.allCases
            .filter { $0 != .unknown }
            .compactMap { name in counts[name].map { "\(name.rawValue)\($0)" } }
            .joined(separator: " ")
        setStatus(.live, accountID: accountID,
                  text: "战场 #\(draft.battlefieldID) 已定位：\(clubs.count) 家俱乐部落位"
                        + (allianceText.isEmpty ? "" : "（\(allianceText)）"))
        LobbyLog.info("[saltfield-live] %@ 实时地图归属发布：%ld 家（phase=%ld battlefieldId=%lld）",
                      accountID, clubs.count, draft.phase, draft.battlefieldID)
    }

    /// 刷新实时地图归属（主连接链：战场 → 对手 → 各家详情）。**不依赖战场连接**。
    public func refreshLiveMap(accountID: String) {
        guard !liveBusy.contains(accountID) else { return }
        liveBusy.insert(accountID)
        setStatus(.live, accountID: accountID, text: "正在定位盐场战场…")
        enqueueHistorySend(accountID: accountID,
                           command: "legion_getbattlefield",
                           paramsJSON: "{}",
                           kind: .battlefieldInfo,
                           startStatus: "正在定位盐场战场…",
                           channel: .live)
    }

    /// warType 链式查询时的目标场次日期（在 issueTotalRank 之前由 UI 写入）。
    private var chainedBattleDate: [String: Date] = [:]

    /// 查询指定日期的盐场战绩（**主路径**，猫助手同源口径）：
    /// `legionwar_getdetails { date: "YYYY/MM/DD" }` → roleDetailsList（成员 胜/负/攻城）。
    public func requestWarDetails(accountID: String, battleDate: Date) {
        let dateKey = SaltHistoryCatalog.slashDateString(of: battleDate)
        enqueueHistorySend(accountID: accountID,
                           command: "legionwar_getdetails",
                           paramsJSON: "{\"date\":\"\(dateKey)\"}",
                           kind: .warDetails(battleDate: battleDate),
                           startStatus: "正在查询 \(dateKey) 的盐场战绩…")
    }

    /// 该场次日期所属月份的 warType（已缓存才返回，否则 0）。
    private func monthlyWarType(for battleDate: Date, accountID: String) -> Int {
        let monthKey = SaltHistoryCatalog.firstSaturdayString(of: battleDate)
        return monthlyWarTypes[accountID]?[monthKey] ?? 0
    }

    private func startPollLoopIfNeeded() {
        guard pollTask == nil, !pollingAccountIDs.isEmpty else { return }
        pollTask = Task { @MainActor [weak self] in
            var tick = 0
            while let self, !self.pollingAccountIDs.isEmpty {
                self.pollOnce()
                // 实时地图归属（主连接链）不必每 4s 重查：落位在开场几分钟内就定了，
                // 每 8 拍（≈32s）刷一次足够，且不会跟战场轮询抢游戏封装的发送队列。
                tick += 1
                if tick % Self.liveMapRefreshTicks == 0 {
                    for accountID in self.pollingAccountIDs {
                        self.refreshLiveMap(accountID: accountID)
                    }
                }
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanos)
            }
            self?.pollTask = nil
        }
    }

    /// 对所有开启轮询的账号发一轮 `war_enterbattlefield`。
    private func pollOnce() {
        for accountID in pollingAccountIDs {
            poll(accountID: accountID)
        }
    }

    private func poll(accountID: String) {
        guard let instance = pool?.existingSurface(forAccountID: accountID) else { return }
        // battlefieldId：优先游戏心跳/进场帧学到的，其次主连接查到的（legion_getbattlefield）。
        let battlefieldID = states[accountID].flatMap { $0.battlefieldID > 0 ? $0.battlefieldID : nil }
            ?? liveBattlefields[accountID]?.battlefieldID ?? 0
        guard battlefieldID > 0 else { return }
        // 盐场 socket 必须先出现过（sid 从 war_* 流量学到）。没出现 = 玩家还没进盐场，
        // 此时发也没用，而且会误发到主连接上（主/盐场 URL 都含 "agent"，无法按 URL 区分）。
        guard let state = states[accountID], state.socketID >= 0 else { return }
        // ack = 盐场最近响应 seq；seq = 盐场 client 游标 + 1（发送后即推进游标，
        // 与游戏自己的盐场请求交错使用同一连续序列——服务端按连续性校验）。
        //
        // ⚠️ 刻意**不带** `useGzip`（参考脚本传的是 useGzip:true）：我们这条是原生帧通道，
        // body 由宿主自己解 BON；一旦服务端压了 body，`XorFrameCipher.open` + `Bon.decode`
        // 就解不开（诊断日志会打「响应无 battlefield 字段」）。不带这个参数时服务端回明文。
        let seq = state.clientSeq + 1
        guard let frame = try? PacketCaptureController.buildFrame(
            command: "war_enterbattlefield",
            paramsJSON: "{\"battlefieldId\":\(battlefieldID)}",
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
                // 每个据点自己的名称（同类型也不同名）；服务端不给就留空 → 类型表兜底。
                name: object["name"]?.stringValue ?? object["nameStr"]?.stringValue ?? "",
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
            var deaths: Int64 = 0
            var digGround: Int64 = 0
            var combo: Int64 = 0
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
            /// 服务端状态原文（normal=正常；其余按已淘汰处理）。
            var state = ""
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
            draft.state = object["state"]?.stringValue ?? ""
            var buildingIDs: [String] = []
            forEachEntry(object["buildings"]) { key, _ in
                buildingIDs.append(key)
            }
            draft.buildingIDs = buildingIDs.sorted { lhs, rhs in
                let (lx, ly) = Self.coords(lhs), (rx, ry) = Self.coords(rhs)
                return lx != rx ? lx < rx : ly < ry
            }
            // 积分 = 占领点的分值和 + 四圣分（口径照抄自助手仓 extractValidData）。
            // 单点分值走 `buildingScore`：类型表优先（同类型同分），表里没填才用服务端 point。
            var score = draft.blessingScore
            for buildingID in draft.buildingIDs {
                score += Self.buildingScore(buildings[buildingID])
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
                // 参考脚本口径：死亡 / 刨地 / 连击在 legion 层没有，按成员累加。
                draft.deaths += die
                draft.digGround += object["aB"]?.intValue ?? 0
                draft.combo += object["mCK"]?.intValue ?? 0
                drafts[legionID] = draft
            }
        }

        let legions = drafts.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        let saltLegions = legions.map { draft in
            SaltLegion(id: draft.id, name: draft.name, colorIndex: draft.colorIndex,
                       power: draft.power, killCount: draft.killCount,
                       deaths: draft.deaths, digGround: draft.digGround, combo: draft.combo,
                       reviveCount: draft.reviveCount, danCount: draft.danCount,
                       redCount: draft.redCount, memberCount: draft.memberCount,
                       participantsCount: draft.participantsCount,
                       onlineCount: draft.onlineCount,
                       blessingCount: draft.blessingCount,
                       blessingScore: draft.blessingScore, score: draft.score,
                       buildingCount: draft.buildingIDs.count,
                       buildingIDs: draft.buildingIDs,
                       strongholdID: draft.strongholdID,
                       state: draft.state)
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

    /// 单个据点的积分（用户口径：**同类型同分**，所以优先查类型表）。
    ///   ① 类型表 `score > 0` → 用表（最可靠，不依赖服务端是否给 point）；
    ///   ② 否则用服务端 `buildingData[...].point`；
    ///   ③ 都没有 → 0。
    /// 表在 `SaltFieldModels.SaltFieldCatalog.strongholds`——要填的就是那里。
    static func buildingScore(_ building: SaltBuilding?) -> Int64 {
        guard let building else { return 0 }
        if let spec = SaltFieldCatalog.stronghold(type: building.type), spec.score > 0 {
            return spec.score
        }
        return building.point
    }

    /// BON 的对象（key 索引）与数组两种形态统一遍历（服务端结构形态不受文档约束）。
    private static func forEachEntry(_ value: BonValue?, _ body: (String, BonValue) -> Void) {
        if let object = value?.objectValue {
            for field in object.fields { body(field.key, field.value) }
        } else if let array = value?.arrayValue {
            for (index, item) in array.enumerated() { body(String(index), item) }
        }
    }

    // MARK: 实时地图链解析（主连接；口径见文件头注释与 SaltFieldModels）
    //
    // 三个响应都是「业务体」，与战场快照一样可能被 `info` / `legionData` 包一层，
    // 也可能直接摊在顶层——统一按「先取包装、再退化到顶层」解析，结构出入靠诊断日志定位。

    /// `legion_getbattlefield` → (phase, battlefieldId)。
    static func parseBattlefieldInfo(inner: BonValue?) -> (phase: Int, battlefieldID: Int64)? {
        let node = inner?.path("info") ?? inner
        let id = node?.path("battlefieldId")?.intValue
            ?? node?.path("battlefieldID")?.intValue
            ?? 0
        guard id > 0 else { return nil }
        let phase = node?.path("phase")?.intValue ?? 0
        return (Int(phase), id)
    }

    /// `legion_getinfo` → **我方军团 ID**（`info.id`）。配合 `legion_getopponent` 的
    /// 对手名单就能自动认出「我方大本营是哪一号」——参考脚本「星驰」也是这么配的
    /// （它拿 legion_getinfo 的 id 与 legion_getopponent 的 legionId 比对）。
    static func parseOwnLegionID(inner: BonValue?) -> Int64? {
        let node = inner?.path("info") ?? inner
        let id = node?.path("id")?.intValue ?? node?.path("legionId")?.intValue ?? 0
        return id > 0 ? id : nil
    }

    /// `legion_getopponent` → [(legionID, position)]（position = 大本营序号）。
    static func parseOpponentLegions(inner: BonValue?) -> [(legionID: Int64, position: Int)] {
        var result: [(legionID: Int64, position: Int)] = []
        let container = inner?.path("legions") ?? inner?.path("info")?.path("legions")
        forEachEntry(container) { _, value in
            guard let object = value.objectValue else { return }
            let id = object["legionId"]?.intValue ?? object["id"]?.intValue ?? 0
            guard id > 0 else { return }
            let position = object["position"]?.intValue ?? 0
            result.append((id, Int(position)))
        }
        return result.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
    }

    /// `legion_getinfobyid` / `legion_getinfo` → 俱乐部详情（名字是必需项，缺了当解析失败）。
    static func parseClubDetail(inner: BonValue?) -> ClubDetail? {
        let node = inner?.path("legionData") ?? inner?.path("info") ?? inner
        guard let object = node?.objectValue else { return nil }
        let name = object["name"]?.stringValue ?? ""
        guard !name.isEmpty else { return nil }
        return ClubDetail(name: name,
                          serverID: object["serverId"]?.intValue ?? object["serverID"]?.intValue ?? 0,
                          power: object["power"]?.intValue ?? 0,
                          quench: Int(object["quenchNum"]?.intValue ?? 0),
                          announcement: object["announcement"]?.stringValue ?? "")
    }

    // MARK: 历史响应解析

    /// 静态骨架的渲染节点（无战场快照时地图的底图：道路 + 各分据点 + 大本营 + 核心，
    /// 不带任何归属染色）。给 UI 用，所以是 public。
    public static func staticNodes() -> [String: SaltRenderedNode] {
        renderNodes(buildings: [:], legions: [])
    }

    /// 大本营序号 → 地图节点 id（静态表见 `SaltFieldRoadPoints.strongholdNodeIDs`）。
    public static func strongholdNodeID(position: Int) -> String? {
        SaltFieldRoadPoints.strongholdNodeID(position: position)
    }

    /// 两个格子之间的最短通路（含起点与终点；不可达返回空数组）。
    ///
    /// ⚠️ 必须走**全节点**图，不能只走道路：骨架里的道路是**分段**的（实测仅道路有 87 个
    /// 连通块、20 个大本营 0 个落在最大块里），而全节点是单一连通块（323 个、20/20 大本营）。
    /// 所以「我方大本营 → 目标大本营」的路线会沿道路走、必要时穿过中间的据点格子。
    ///
    /// 用于地图上的「进攻路线」高亮（用户 2026-09-19 要求）。
    public static func route(from startID: String, to endID: String,
                             in nodes: [String: SaltRenderedNode]) -> [String] {
        guard startID != endID, nodes[startID] != nil, nodes[endID] != nil else {
            return startID == endID && nodes[startID] != nil ? [startID] : []
        }
        // 邻接表：只在「有内容的格子」之间连边（空格不参与，路线不该穿空地）。
        var adjacency: [String: [String]] = [:]
        for id in nodes.keys { adjacency[id] = SaltFieldRoadPoints.neighborIDs(of: id) }
        var previous: [String: String] = [:]
        var visited: Set<String> = [startID]
        var queue: [String] = [startID]
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            if current == endID { break }
            for neighbor in adjacency[current] ?? [] where nodes[neighbor] != nil {
                if visited.insert(neighbor).inserted {
                    previous[neighbor] = current
                    queue.append(neighbor)
                }
            }
        }
        guard visited.contains(endID) else { return [] }
        var path: [String] = []
        var cursor: String? = endID
        while let id = cursor {
            path.append(id)
            cursor = previous[id]
        }
        return path.reversed()
    }

    /// 地图网格尺寸（整张网格都要画：骨架之外的格子留白框）。
    public static var gridColumns: Int { SaltFieldRoadPoints.columns }
    public static var gridRows: Int { SaltFieldRoadPoints.rows }

    /// 核心四周那 6 格（地图上单独染粉红）。
    public static func coreRingNodeIDs() -> [String] {
        SaltFieldRoadPoints.coreRingNodeIDs
    }

    /// 地图节点 id → 大本营序号（实时落位查表用）。
    public static func strongholdPosition(nodeID: String) -> Int? {
        SaltFieldRoadPoints.strongholdPositionByNodeID[nodeID]
    }

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

    /// `legionwar_getdetails` → 成员明细（roleDetailsList；击杀降序 = 猫助手排序口径）。
    /// 容错：roleDetailsList 优先，退化尝试 body 顶层同名数组。
    /// 字段口径：winCnt=击杀、loseCnt=死亡、buildingCnt=攻城；
    /// 总积分本地计算 = 击杀×10 + 死亡×1 + 攻城×1（用户确认口径）。
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
            // 名称优先级：**手填坐标表** → 服务端 buildingData.name → 类型表名 → 「N血」
            // （后两级在 SaltRenderedNode.labelText 里兜底）。手填表放最前，是为了让
            // 「骨架提前填好的名字」在进盐场前后表现一致——用户口径 2026-09-19。
            let name = SaltFieldNodeNames.name(nodeID: id) ?? building?.name ?? ""
            result[id] = SaltRenderedNode(
                id: id, name: name, x: x, y: y, type: type,
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
