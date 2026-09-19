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
    ///
    /// ⚠️ 带 **TTL 与场次归属**（2026-09-19 加）：早先这个缓存是永不过期的纯 `[Int64:]`，
    /// 而 legionID 会跨场次复用、名称/战力/红淬每场都在变 —— 第二周打开窗口会看到
    /// 上一周的俱乐部资料，且因为「缓存命中」永远不会去查新的（最难查的那种错）。
    /// 现在按 `battlefieldId` 分区，并给每条加时间戳，超过 `clubDetailTTL` 视为过期。
    struct ClubDetail {
        let name: String
        let serverID: Int64
        let power: Int64
        let quench: Int
        let announcement: String
    }
    private struct CachedClubDetail {
        let detail: ClubDetail
        let battlefieldID: Int64
        let storedAt: Date
    }
    private var clubDetails: [Int64: CachedClubDetail] = [:]
    /// 详情缓存有效期（一场盐场 1 小时出头；10 分钟足够省往返又能跟上战况变化）。
    private static let clubDetailTTL: TimeInterval = 600

    /// 取缓存详情（过期 / 跨场次都当没有）。
    /// `battlefieldID == nil` = 不看场次分区（给自己家那条用：它是本账号自己的军团）。
    private func cachedClubDetail(_ legionID: Int64, battlefieldID: Int64?) -> ClubDetail? {
        guard let cached = clubDetails[legionID] else { return nil }
        guard Date().timeIntervalSince(cached.storedAt) < Self.clubDetailTTL else { return nil }
        // 缓存里记的战场 id 为 0 = 当时还不知道（先放过），否则必须同场次。
        if let battlefieldID, cached.battlefieldID != 0, cached.battlefieldID != battlefieldID {
            return nil
        }
        return cached.detail
    }

    private func storeClubDetail(_ detail: ClubDetail, legionID: Int64, battlefieldID: Int64) {
        clubDetails[legionID] = CachedClubDetail(detail: detail,
                                                 battlefieldID: battlefieldID,
                                                 storedAt: Date())
    }
    /// 每轮实时地图最多查多少家详情（对手名单可能很长，但盐场就是 20 个大本营）。
    private static let maxClubDetailsPerRound = 24

    /// 发送轮询帧要借实例的 WebView 出口。会话模型装配时接上。
    public weak var pool: GameInstancePool?

    // MARK: 每账号盐场连接状态（内部；非 published——轮询游标不需要驱动 UI）
    private struct WarLinkState {
        var socketID: Int = -1          // 盐场 socket 的页面侧 id（定向发送用）
        var battlefieldID: Int64 = 0    // 心跳 / 进场帧的 body.battlefieldId
        var serverSeq: Int64 = 0        // 盐场响应 seq 游标（原生日发回退通道的 ack）
        var clientSeq: Int64 = 0        // 盐场**发送**帧的 seq 水位（包时间戳型，见 poll）
        /// 游戏自己发的 `war_enterbattlefield` 的 params（原样复用，见 poll 注释）。
        var gameEnterParams: BonObject?
        /// 游戏自己发的进场帧的 ack（原生日发回退通道的 ack 来源之一）。
        var gameEnterAck: Int64?
        /// 已经用游戏封装成功发过一次（决定日志里的通道标记）。
        var usedGameChannel = false
        /// 游戏封装不可用的原因（`socket-has-no-sendAsync` 等），只记一次。
        var gameChannelFailure: String?
    }
    private var states: [String: WarLinkState] = [:]
    private var pollTask: Task<Void, Never>?
    /// 正在等游戏封装回执的账号（防每 4s 叠一个在途请求，见 poll）。
    private var gameChannelInFlight: Set<String> = []

    // MARK: 盐场时段（窗口常开、只在开赛时段取数）
    /// 当前时段状态（窗口状态条 + 轮询门控共用）。轮询每拍重算一次。
    @Published public private(set) var eventWindow = SaltFieldEventWindow.state()
    /// 手动忽略时段门控（排错开关）：非开赛时段也想验证链路通不通时打开。
    /// 打开后轮询照发，服务端多半回空战场 —— 能拿到「响应结构」本身就是证据。
    @Published public var ignoresEventWindow = false

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

    // MARK: 解码诊断（2026-09-19 起：解不开不再静默）
    /// 账号 → 最近一次解码失败说明（窗口状态条显示）。**成功解出一帧即清空** ——
    /// 它的语义是「这条线上现在有没有解不开的东西」，不是历史累计。
    @Published public private(set) var decodeIssues: [String: String] = [:]
    /// 账号 → 累计解码失败帧数（不清零：用来判断「一直解不开」还是「偶发一帧」）。
    @Published public private(set) var decodeFailureCounts: [String: Int] = [:]
    /// 解码失败日志：每账号上限（同一个原因只打一次，见下）。
    private static let decodeFailureLogLimit = 6
    private var decodeFailureLogCounts: [String: Int] = [:]
    private var decodeFailureLoggedReasons: Set<String> = []

    public init() {}

    // MARK: - 帧摄入（GameViewportInstance 路由，与抓包 ingest 并列）

    public func ingest(frame: PacketFrame, accountID: String) {
        let decoded: DecodedFrame
        switch Self.decode(frame) {
        case .decoded(let value):
            decoded = value
            noteDecodeSuccess(accountID: accountID)
        case .notApplicable:
            return
        case .failure(let reason, let scheme, let preview):
            noteDecodeFailure(accountID: accountID, reason: reason, scheme: scheme,
                              preview: preview, frame: frame)
            return
        }
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
        // 游戏自己发的进场帧：params **原样存下来**，轮询时照抄（见 poll 注释）——
        // 这是唯一能确认「要不要带 useGzip」「参数叫什么」的权威来源，不靠猜。
        if frame.direction == "send", lowered.contains("war_enterbattlefield") {
            let gameAck = decoded.outerObject?["ack"]?.intValue
            if let body = decoded.inner?.objectValue {
                state.gameEnterParams = body
                state.gameEnterAck = gameAck
                let key = "\(accountID)#enterSend"
                if unmatchedLogCounts[key, default: 0] == 0 {
                    unmatchedLogCounts[key] = 1
                    LobbyLog.info("[saltfield] %@ 游戏进场帧：ack=%lld seq=%lld 参数=%@",
                                  accountID, gameAck ?? -1, decoded.seq ?? -1,
                                  Self.describeBodyKeys(inner: decoded.inner))
                }
            }
        }

        // 盐场 seq 游标（与主连接完全独立的两套计数）。
        //
        // ⚠️ 早先发送侧带 `seq < 1_000_000` 过滤（原意「排除时间戳型 seq」），后果是：
        // 游戏自己的盐场请求**清一色**用 `seq: Date.now()`（内置脚本
        // `builtin-salt-field-apk.js` 的 `sendReadCommand`、雪碧助手 `sendBattleCommand`
        // 都是 `{ ack: 0, seq: Date.now(), time: Date.now() }`），过滤后游标恒为 0，
        // 我们发出的永远是 `seq: 1` —— 一个明显不属于本连接的序号。
        // 现在照单全收：`clientSeq + 1` 直接续在游戏自己的序列上。
        if let seq = decoded.seq, seq > 0 {
            if frame.direction == "recv" {
                state.serverSeq = max(state.serverSeq, seq)
            } else {
                state.clientSeq = max(state.clientSeq, seq)
            }
        }

        // 战场信息响应 → 快照。
        //
        // ⚠️ 命令是 `war_enterbattlefield`（不是早先猜的 war_getbattlefieldinfo）：
        //    · 游戏自己在玩家进盐场时会发它 —— 白捡一份快照，不用等我们的轮询；
        //    · 我们的轮询也发它（见 poll），响应走同一条路（或直接走游戏封装回执）。
        // 旧名保留在判断里只是为了兼容可能存在的服务端别名，无副作用。
        if frame.direction == "recv",
           lowered.contains("war_enterbattlefield") || lowered.contains("war_getbattlefieldinfo"),
           let applied = applyBattlefieldResponse(accountID: accountID, body: decoded.inner,
                                                  fallbackBattlefieldID: state.battlefieldID,
                                                  byteCount: frame.byteCount,
                                                  timestampMs: frame.timestampMs,
                                                  source: "抓包流", note: decoded.bodyNote),
           applied != state.battlefieldID {
            state.battlefieldID = applied
            changedLink = true
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

    /// 从响应里取出 `battlefield` 对象。
    ///
    /// 层级**不确定**，必须逐层试（每层都是真实存在的可能）：
    ///   · `body.battlefield` —— 页面 `sendAsync` 回执直接给解码后的 body（雪碧助手
    ///     就是 `result.battlefield`，对应抓包流的 `decoded.inner`）；
    ///   · `body.body.battlefield` / `body.data.battlefield` —— 回执给的其实是整条
    ///     消息（外层还带着 cmd/ack/seq）；
    ///   · **未解码的二进制** —— 页面的 `sanitize` 会把 `ArrayBuffer` 转成
    ///     `{"__b64":…}`；BON 解码在宿主是现成的，自己解一次就行，不必让页面懂协议。
    private static func battlefieldObject(in body: BonValue?) -> BonObject? {
        var candidates: [BonValue?] = [
            body,
            body?.path("body"),
            body?.path("data"),
            body?.path("result"),
            body?.path("payload"),
        ]
        if let base64 = body?.path("__b64")?.stringValue,
           let bytes = Data(base64Encoded: base64),
           let decoded = try? Bon.decode(bytes) {
            candidates.insert(decoded, at: 1)
            candidates.append(decoded.path("body"))
        }
        for candidate in candidates {
            if let object = candidate?.path("battlefield")?.objectValue { return object }
        }
        return nil
    }

    /// 已解码的 `war_enterbattlefield` 响应内层 → 快照，返回实际采用的 battlefieldId
    /// （`nil` = 没解出 battlefield）。
    ///
    /// 两条数据来源共用这一份：**抓包流**（游戏自己的请求 / 我们的原生日发）与
    /// **游戏封装回执**（页面 `sendAsync` 直接给解码好的对象，见 poll）。分成两处写
    /// 的话，字段一改就会只改一处。`source` 只进日志。
    @discardableResult
    private func applyBattlefieldResponse(accountID: String, body: BonValue?,
                                          fallbackBattlefieldID: Int64,
                                          byteCount: Int, timestampMs: Double,
                                          source: String, note: String? = nil) -> Int64? {
        guard let battlefield = Self.battlefieldObject(in: body) else {
            // 解不出 battlefield：结构诊断（服务端换字段 / 压了 body / params 不对都落这里）。
            var structure = Self.describeBodyKeys(inner: body)
            if body?.path("__b64") != nil {
                structure += "（回执是纯二进制，宿主 BON 解码失败）"
            }
            if let note { structure += " ⚠️\(note)" }
            let key = "\(accountID)#enter"
            let count = unmatchedLogCounts[key, default: 0]
            unmatchedLogCounts[key] = count + 1
            if count < 3 {
                LobbyLog.warn("[saltfield] %@ war_enterbattlefield 响应无 battlefield 字段（来源=%@，结构：%@）",
                              accountID, source, structure)
            }
            decodeIssues[accountID] = "响应无 battlefield 字段 · \(structure)"
            return nil
        }
        // 响应里的 battlefieldId 优先（进战场那一刻我们可能还没学到 id）。
        let responseID = body?.path("battlefieldId")?.intValue ?? 0
        let battlefieldID = responseID > 0 ? responseID : fallbackBattlefieldID
        let snapshot = Self.buildSnapshot(battlefield: battlefield, battlefieldID: battlefieldID,
                                          timestampMs: timestampMs)
        snapshots[accountID] = snapshot
        warActiveAccountIDs.insert(accountID)
        LobbyLog.info("[saltfield] %@ 战场快照更新（%@）：据点 %ld 俱乐部 %ld 成员 %ld%@",
                      accountID, source, snapshot.nodes.count, snapshot.legions.count,
                      snapshot.members.count,
                      byteCount > 0 ? "（\(byteCount) 字节）" : "")
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
        return battlefieldID
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
        // 解码诊断（新周期重新计数；不清会一直顶着上一局的失败原因）
        decodeIssues.removeValue(forKey: accountID)
        decodeFailureCounts.removeValue(forKey: accountID)
        decodeFailureLogCounts.removeValue(forKey: accountID)
        decodeFailureLoggedReasons = decodeFailureLoggedReasons.filter {
            !$0.hasPrefix("\(accountID)#")
        }
        gameChannelInFlight.remove(accountID)
    }

    // MARK: - 轮询

    /// 开/关某账号的主动轮询（图表窗口开关的直连入口）。
    /// 开启时顺手拉一轮实时地图归属（主连接链）——它不依赖战场连接，
    /// 是「窗口一打开就有东西看」的那条路。
    public func setPolling(_ enabled: Bool, accountID: String) {
        if enabled {
            pollingAccountIDs.insert(accountID)
            refreshEventWindow()
            refreshLiveMap(accountID: accountID)
        } else {
            pollingAccountIDs.remove(accountID)
            // 关窗即清「解码失败」提示：它的语义是「这条线现在有没有解不开的东西」，
            // 窗口关了就不该留着吓人（累计计数保留，见 decodeFailureCounts）。
            decodeIssues[accountID] = nil
        }
        startPollLoopIfNeeded()
    }

    /// 立即对指定账号拉一轮（图表窗口的「立即拉取」按钮）：战场快照 + 地图归属。
    /// 属于**显式用户动作**，绕开时段门控（非开赛时段想验证链路时全靠它）。
    public func pollNow(accountID: String) {
        eventWindow = SaltFieldEventWindow.state()
        poll(accountID: accountID, forced: true)
        refreshLiveMap(accountID: accountID)
    }

    /// 重算时段状态并返回（窗口状态条倒计时要刷新时调）。
    @discardableResult
    public func refreshEventWindow() -> SaltFieldEventWindow {
        let state = SaltFieldEventWindow.state()
        if state != eventWindow { eventWindow = state }
        return state
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
        // ── 服务端错误码先行 ──
        // 早先完全不看 `code`，于是「命令被服务端拒绝」和「数据本来为空」在日志里长得
        // 一模一样（都是「无 legions / 无 battlefield」），排查时指不到方向。
        // 参考脚本都是先判码的（雪碧：`if (bfData.code !== 0)`）。
        if let code = inner?.path("code")?.intValue, code != 0 {
            let hint = Self.errorCodeHint(code)
            setBusy(pending.channel, accountID: accountID, busy: false)
            setStatus(pending.channel, accountID: accountID,
                      text: "服务端错误码 \(code)\(hint)")
            LobbyLog.warn("[saltfield-live] %@ %@ 被服务端拒绝：code=%ld%@",
                          accountID, pending.command, code, hint)
            return
        }
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
            // 顺手把「我方俱乐部详情」也缓存下来：实时地图链到自己家时直接用它，
            // **不再发 legion_getinfobyid**（参考脚本 isMyClub 分支同款；也避开
            // 自家 id 查询偶发的 2300400）。战场 id 未知时先记 0，后续查到时会被
            // `cachedClubDetail` 的宽容匹配接上。
            if let ownID = ownLegionIDs[accountID], let own = Self.parseClubDetail(inner: inner) {
                storeClubDetail(own, legionID: ownID,
                                battlefieldID: liveBattlefields[accountID]?.battlefieldID ?? 0)
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
            let ownID = ownLegionIDs[accountID]
            var missing: [Int64] = []
            for entry in entries {
                // 自己家：只看 TTL、不看场次分区（它就是本账号自己的军团详情）。
                let isOwn = entry.legionID == ownID
                if let detail = cachedClubDetail(entry.legionID,
                                                 battlefieldID: isOwn ? nil : draft.battlefieldID) {
                    if isOwn {
                        // 顺手把它也归到本场次分区下，下轮就不用再走宽容匹配。
                        storeClubDetail(detail, legionID: entry.legionID,
                                        battlefieldID: draft.battlefieldID)
                    }
                    draft.clubs.append(Self.club(legionID: entry.legionID, position: entry.position,
                                                 detail: detail))
                } else if missing.count < Self.maxClubDetailsPerRound {
                    missing.append(entry.legionID)
                }
            }
            draft.requested = missing.count
            liveDrafts[accountID] = draft
            // 顺手查一次我方军团信息（拿 info.id → 自动认领我方大本营 + 自家详情缓存）。
            // 复用 .legionInfo 这条 kind（同一个命令），但走 live 通道：状态文案写 liveStatus，
            // 不会污染历史战绩页；顺带把历史场次也刷新一遍（同一份数据，无害）。
            if ownID == nil || cachedClubDetail(ownID ?? 0, battlefieldID: nil) == nil {
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
                storeClubDetail(detail, legionID: legionID, battlefieldID: draft.battlefieldID)
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
                // 时段状态每拍重算（很便宜）。窗口可以常开当装饰，取数只看这个开关。
                self.eventWindow = SaltFieldEventWindow.state()
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
    /// ⚠️ 时段门控在 `poll(accountID:forced:)` 里，不放这里 —— 这样「立即拉取」
    /// 这类**显式用户动作**（`pollNow`）可以带 `forced` 绕开，而自动轮询照旧受控。
    private func pollOnce() {
        for accountID in pollingAccountIDs {
            poll(accountID: accountID)
        }
    }

    /// 盐场轮询一拍：一条 `war_enterbattlefield`。
    ///
    /// ⚠️ **时段门控**：非开赛时段直接不发（`forced` 或「忽略时段门控」开关可绕开）。
    /// 窗口允许常开当装饰，但取数只认开赛时段 —— 非时段服务端只会回空战场，
    /// 白耗帧还会污染状态（表现是「窗口开着一直显示 0 据点」，比关着更难判断）。
    ///
    /// 两条通道，优先级明确：
    ///
    ///   ① **游戏封装**（主路径，2026-09-19 起）：对盐场 socket 调它自己的
    ///      `sendAsync`（页面代理 v5 的 `sendViaGameOnSocket`）。seq / ack / body
    ///      编码全交给游戏，响应直接是解码好的对象。这和主连接历史查询早就改用的
    ///      做法一致 —— 那条路当初就是因为「原生日发 seq 撞号，被服务端静默丢弃」
    ///      才改的；盐场这条一直没改，是「实时战况没有数据」的高概率成因。
    ///      请求形状照抄游戏内置脚本：`{ ack: 0, cmd, params, seq: Date.now(), time: Date.now() }`。
    ///   ② **原生日发**（回退）：自构帧 + 定向 socket。只在 ① 明确不可用时走，
    ///      并打一条 warn 说明原因（`socket-has-no-sendAsync` 是最可能的那个）。
    ///
    /// 参数口径：**优先照抄游戏自己那条进场帧的 params**（`gameEnterParams`），
    /// 只把 `battlefieldId` 换成我们学到的最新值。这样「要不要带 useGzip」之类
    /// 的问题不需要猜——游戏怎么发我们就怎么发；还没看到游戏进场帧时退化为
    /// 只带 battlefieldId。
    private func poll(accountID: String, forced: Bool = false) {
        guard forced || ignoresEventWindow || eventWindow.isOpen else { return }
        guard let instance = pool?.existingSurface(forAccountID: accountID) else { return }
        // battlefieldId：优先游戏心跳/进场帧学到的，其次主连接查到的（legion_getbattlefield）。
        let battlefieldID = states[accountID].flatMap { $0.battlefieldID > 0 ? $0.battlefieldID : nil }
            ?? liveBattlefields[accountID]?.battlefieldID ?? 0
        guard battlefieldID > 0 else { return }
        // 盐场 socket 必须先出现过（sid 从 war_* 流量学到）。没出现 = 玩家还没进盐场，
        // 此时发也没用，而且会误发到主连接上（主/盐场 URL 都含 "agent"，无法按 URL 区分）。
        guard let state = states[accountID], state.socketID >= 0 else { return }
        let paramsJSON = Self.enterParamsJSON(game: state.gameEnterParams,
                                              battlefieldID: battlefieldID)
        let socketID = state.socketID

        if state.gameChannelFailure == nil {
            // 游戏封装的回执是异步的、可能很慢（雪碧助手给自己留了 30s 超时）。
            // 不设这个闸的话，每 4s 就会叠一个在途请求，越堆越多还会互相插队。
            guard !gameChannelInFlight.contains(accountID) else { return }
            gameChannelInFlight.insert(accountID)
            Task { @MainActor [weak self] in
                await self?.pollViaGameChannel(accountID: accountID, instance: instance,
                                               socketID: socketID, paramsJSON: paramsJSON)
                self?.gameChannelInFlight.remove(accountID)
            }
            return
        }
        sendNativePollFrame(accountID: accountID, instance: instance,
                            socketID: socketID, paramsJSON: paramsJSON)
    }

    /// 通道 ①：让页面在**指定的盐场 socket** 上调游戏自己的 `sendAsync`。
    /// 成功 → 回执里已是解码好的对象，直接套快照；失败 → 记原因、永久降级到通道 ②。
    private func pollViaGameChannel(accountID: String, instance: GameViewportInstance,
                                    socketID: Int, paramsJSON: String) async {
        let script = PacketCaptureScript.sendViaGameOnSocket(
            socketID, command: "war_enterbattlefield", paramsJSON: paramsJSON)
        let receipt = await instance.evaluatePageJS(script)
        if let inner = Self.parseViaGameResponse(receipt) {
            states[accountID]?.usedGameChannel = true
            if let applied = applyBattlefieldResponse(
                accountID: accountID, body: inner,
                fallbackBattlefieldID: states[accountID]?.battlefieldID ?? 0,
                byteCount: 0, timestampMs: Date().timeIntervalSince1970 * 1000,
                source: "游戏封装") {
                states[accountID]?.battlefieldID = applied
            }
            return
        }
        let reason = Self.viaGameError(receipt)
        if states[accountID]?.gameChannelFailure != reason {
            states[accountID]?.gameChannelFailure = reason
            LobbyLog.warn("[saltfield] %@ 盐场轮询降级为原生日发：游戏封装不可用（%@）",
                          accountID, reason)
        }
        // 这一拍不浪费：立刻用原生日发补一次。
        sendNativePollFrame(accountID: accountID, instance: instance,
                            socketID: socketID, paramsJSON: paramsJSON)
    }

    /// 通道 ②：原生日发（自构帧 + socket 定向）。
    ///
    /// ack 取游戏自己那条进场帧的 ack（拿不到再退回盐场最近响应 seq）；
    /// seq 续在**盐场发送帧的 seq 水位**之后（游戏自己用的是 `Date.now()` 时间戳，
    /// 所以这个值也是时间戳量级——不再是我们早先恒定的 `1`）。
    private func sendNativePollFrame(accountID: String, instance: GameViewportInstance,
                                     socketID: Int, paramsJSON: String) {
        guard let state = states[accountID] else { return }
        let seq = state.clientSeq > 0
            ? state.clientSeq + 1
            : Int64(Date().timeIntervalSince1970 * 1000)
        let ack = state.gameEnterAck ?? state.serverSeq
        guard let frame = try? PacketCaptureController.buildFrame(
            command: "war_enterbattlefield", paramsJSON: paramsJSON,
            ack: ack, seq: seq) else { return }
        states[accountID]?.clientSeq = seq
        Task { @MainActor in
            let diagnostic = await instance.sendRawFrame(base64: frame.base64EncodedString(),
                                                         socketID: socketID)
            if !diagnostic.hasPrefix("sent") {
                LobbyLog.warn("[saltfield] %@ 轮询帧未送达（ack=%lld seq=%lld）：%@",
                              accountID, ack, seq, diagnostic)
            }
        }
    }

    /// 轮询 params：照抄游戏自己的进场参数，只把 battlefieldId 覆盖成最新值。
    private static func enterParamsJSON(game: BonObject?, battlefieldID: Int64) -> String {
        var fields: [BonObject.Field] = [.init("battlefieldId", .long(battlefieldID))]
        for field in game?.fields ?? [] where field.key != "battlefieldId" {
            fields.append(field)
        }
        return jsonText(.object(BonObject(fields))) ?? "{\"battlefieldId\":\(battlefieldID)}"
    }

    /// BonValue → JSON 文本（发给页面前要过 `JSON.parse`；二进制按 base64 走）。
    private static func jsonText(_ value: BonValue) -> String? {
        func quote(_ text: String) -> String {
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
            return "\"\(escaped)\""
        }
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .long(let number): return String(number)
        case .float(let number): return String(number)
        case .double(let number): return String(number)
        case .date(let number): return String(number)
        case .string(let text): return quote(text)
        case .binary(let data): return quote(data.base64EncodedString())
        case .array(let items):
            return "[" + items.compactMap { jsonText($0) }.joined(separator: ",") + "]"
        case .object(let object):
            let pairs = object.fields.compactMap { field -> String? in
                guard let text = jsonText(field.value) else { return nil }
                return quote(field.key) + ":" + text
            }
            return "{" + pairs.joined(separator: ",") + "}"
        }
    }

    /// 页面回执里的失败原因（`{"__error":"socket-has-no-sendAsync"}` → 该串）。
    private static func viaGameError(_ receipt: String) -> String {
        guard let data = receipt.data(using: .utf8),
              let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = wrapper["__error"] as? String else {
            return receipt.isEmpty ? "页面无回执" : String(receipt.prefix(120))
        }
        return error
    }

    // MARK: - 解码诊断

    /// 解出一帧：清掉「这条线现在有解不开的东西」的标记。
    private func noteDecodeSuccess(accountID: String) {
        if decodeIssues[accountID] != nil { decodeIssues[accountID] = nil }
    }

    /// 解不开一帧：计数 + 更新状态说明 + 限次落日志（含信封种类与帧头 hex）。
    ///
    /// 帧头 hex 是关键证据：`70 78` = 旧的 px、`70 6c` = lx（LZ4）、`70 74` = xtm（XXTEA）。
    /// 三种都能从这 8 个字节里一眼看出来，不用再去抓包。
    private func noteDecodeFailure(accountID: String, reason: String, scheme: String,
                                   preview: String, frame: PacketFrame) {
        let total = (decodeFailureCounts[accountID] ?? 0) + 1
        decodeFailureCounts[accountID] = total
        let issue = "\(scheme) · \(reason)"
        if decodeIssues[accountID] != issue { decodeIssues[accountID] = issue }

        let reasonKey = "\(accountID)#\(issue)"
        guard (decodeFailureLogCounts[accountID] ?? 0) < Self.decodeFailureLogLimit else { return }
        guard decodeFailureLoggedReasons.insert(reasonKey).inserted else { return }
        decodeFailureLogCounts[accountID] = (decodeFailureLogCounts[accountID] ?? 0) + 1
        LobbyLog.warn("[saltfield] %@ 帧解码失败 累计#%ld：%@ | 信封=%@ 头=[%@] | %ld 字节 %@向 sid=%ld",
                      accountID, total, reason, scheme, preview,
                      frame.byteCount, frame.direction, frame.socketID)
    }

    // MARK: - 解码（与 PacketCaptureController.decode 同源，取沙场所需的子集）

    private struct DecodedFrame {
        let command: String
        let seq: Int64?
        let outerObject: BonObject?
        let inner: BonValue?
        /// 内层 body 没能解成 BON 时的证据串（`nil` = 正常 / 没有 body）。
        /// 关键价值：能一眼区分「服务端换了字段」和「body 被压缩了」（`1f 8b` = gzip）。
        let bodyNote: String?
    }

    /// 解码结果三态。
    ///
    /// ⚠️ 早先这里是 `-> DecodedFrame?`，任何一步失败都 `return nil` —— 表现是
    /// **「实时战况没有数据、日志里也什么都没有」**，无法区分下面三种完全不同的原因：
    ///   ① 这段流量本来就不是盐场的（文本帧 / 主连接的其它命令）；
    ///   ② 服务端换了信封（`lx` / `xtm`），我们解不开；
    ///   ③ 信封解开了但 BON 结构变了（命令名 / 字段改名）。
    /// 三态之后，②③ 会落一条带**信封种类 + 帧头 hex**的诊断日志，① 保持安静。
    private enum DecodeOutcome {
        case decoded(DecodedFrame)
        /// 本线不关心的帧形态（非 binary / base64 坏 / 解出来没有 cmd）——正常，不记日志。
        case notApplicable
        /// 看起来是游戏帧信封，但解不开 / 结构对不上——要留证据。
        case failure(reason: String, scheme: String, preview: String)
    }

    /// 解码一帧；失败原因不丢弃，交由 `ingest` 落限次诊断日志。
    private static func decode(_ frame: PacketFrame) -> DecodeOutcome {
        guard frame.kind == "binary",
              let data = Data(base64Encoded: frame.payloadBase64),
              data.count > 1 else { return .notApplicable }
        // 只对信封帧做诊断：非 0x70 开头的多半是盐场连接上的其它流量（协议层噪声）。
        guard data[data.startIndex] == 0x70 else { return .notApplicable }
        let scheme = XorFrameCipher.schemeName(data)
        let preview = XorFrameCipher.hexPreview(data)
        let plain: Data
        do {
            plain = try XorFrameCipher.open(data)
        } catch {
            return .failure(reason: "\(error)", scheme: scheme, preview: preview)
        }
        guard let outer = try? Bon.decode(plain), let object = outer.objectValue else {
            return .failure(reason: "信封已解开（\(plain.count) 字节）但 BON 外层解析失败",
                            scheme: scheme, preview: preview)
        }
        guard let command = object["cmd"]?.stringValue else {
            return .failure(reason: "BON 外层没有 cmd 字段（键：\(object.keys.sorted().joined(separator: ","))）",
                            scheme: scheme, preview: preview)
        }
        var inner: BonValue?
        var bodyNote: String?
        if case .binary(let body)? = object["body"], !body.isEmpty {
            if let decodedBody = try? Bon.decode(body) {
                inner = decodedBody
            } else {
                // 内层解不开不算致命（战场对象也可能摊在外层），但**必须留证据**：
                // 早先这里是 `try?` + 静默 nil，于是「服务端把 body 压了」和
                // 「服务端换了字段名」在日志里完全一样，都是「响应无 battlefield」。
                bodyNote = "body \(body.count) 字节解不成 BON，头=\(XorFrameCipher.hexPreview(body, limit: 4))"
            }
        }
        return .decoded(DecodedFrame(command: command, seq: object["seq"]?.intValue,
                                     outerObject: object, inner: inner, bodyNote: bodyNote))
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
    ///
    /// ⚠️ 容器名有两种、形态也有两种（2026-09-19 对齐参考脚本）：
    ///    · 名字：`legions`（老口径）或 **`opponentList`**（雪碧助手两种都读：
    ///      `oppData.opponentList || oppData.legions`）；也可能嵌在 `info` 下；
    ///    · 形态：**数组**（`opponentList` 通常是数组）或**映射**（`legions` 是
    ///      legionKey → 条目）。早先只认 `legions`/`info.legions` 的映射形态，
    ///      服务端一换名字或改成数组就会得到「没有对手名单」——而实际数据在那儿。
    static func parseOpponentLegions(inner: BonValue?) -> [(legionID: Int64, position: Int)] {
        var result: [(legionID: Int64, position: Int)] = []
        let candidates: [BonValue?] = [
            inner?.path("legions"),
            inner?.path("opponentList"),
            inner?.path("info")?.path("legions"),
            inner?.path("info")?.path("opponentList"),
            inner?.path("list"),
            // 兜底：响应本身就是数组（雪碧的 `Array.isArray(rawLegions)` 分支）。
            // ⚠️ 但**不能**把 `inner` 当映射兜底：响应常见形态是 `{code, info:{id,…}}`，
            // 那样会把 info 的 `id` 当成一个「对手 legionID」收进来（假数据比没数据更坏）。
            (inner?.arrayValue?.isEmpty == false) ? inner : nil,
        ]
        var container: BonValue?
        for candidate in candidates {
            guard let candidate else { continue }
            if let items = candidate.arrayValue, !items.isEmpty {
                container = candidate
                break
            }
            if let object = candidate.objectValue, object.count > 0 {
                container = candidate
                break
            }
        }
        forEachEntry(container) { _, value in
            guard let object = value.objectValue else { return }
            let id = object["legionId"]?.intValue ?? object["id"]?.intValue ?? 0
            guard id > 0 else { return }
            // position = 大本营序号；服务端可能叫 position / pos / strongholdPos。
            let position = object["position"]?.intValue
                ?? object["pos"]?.intValue
                ?? object["strongholdPos"]?.intValue
                ?? 0
            result.append((id, Int(position)))
        }
        return result.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
    }

    /// 服务端错误码 → 人话（只收已经确认过的，未知码原样展示）。
    private static func errorCodeHint(_ code: Int64) -> String {
        switch code {
        case 2300400:
            return "（该俱乐部不在本战场 / 无权查看——参考脚本遇此码时退回自家 getinfo 数据）"
        default:
            return ""
        }
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
