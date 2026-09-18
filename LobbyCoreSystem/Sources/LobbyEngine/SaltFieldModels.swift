import Foundation

// MARK: - 盐场战场快照 · 数据模型
//
// 字段口径全部对齐自助手仓 `legionWar.js` 的 `extractValidData`（实测协议字段名）：
// battlefield{buildingData, legions, roles}。快照是**渲染就绪**形态——
// 地图染色（BFS 路径）在控制器构建时一次算完，图表窗口只画不算。

/// 一个建筑/据点/道路点（服务端 `buildingData` 条目）。
public struct SaltBuilding: Sendable {
    public let id: String
    /// **这个据点自己的名称**（服务端 `buildingData[...].name`；可能为空）。
    /// 用户口径（2026-09-19）：同一类型的不同据点，名称也不一样 —— 所以名称是
    /// **按点**的，不能只靠类型表；类型表里的 name 只是服务端没给名称时的兜底。
    public let name: String
    /// 9=道路 · 1/2/3/5=据点（对应生命值 30/50/80/100）· 4=大本营 · 6=核心。
    ///
    /// ⚠️ 这几个数字是据点的**生命值（血量）**，不是分值——2026-09-18 用户纠正：
    /// 早先把 1/2/3/5 当「30/50/80/100 分据点」，标签写成「30分」是错的。
    /// 真正的积分来自服务端 `point` 字段（见 buildSnapshot 的 score 累加）。
    public let type: Int
    public let belongsLegionID: Int64?
    public let hp: Int64
    public let maxHP: Int64
    public let point: Int64
}

/// 一个俱乐部的战况（`legions` 条目 + roles 统计）。
public struct SaltLegion: Sendable, Identifiable {
    public let id: Int64
    public let name: String
    /// 颜色序号（`colorArray[index]`，0...19）。
    public let colorIndex: Int
    public let power: Int64
    /// 击杀数（`killCnt`）。
    public let killCount: Int64
    /// 死亡数（Σ role.d——服务端 legion 层不给，参考脚本同样按成员累加）。
    public let deaths: Int64
    /// 刨地次数（Σ role.aB）。
    public let digGround: Int64
    /// 连击（Σ role.mCK）。
    public let combo: Int64
    /// 免费复活已用合计（Σ role.revive，上限 150）。
    public let reviveCount: Int64
    /// 复活丹合计（Σ max(0, role.d - 6)）。
    public let danCount: Int64
    /// 红数（`custom["red:quench"]`）。
    public let redCount: Int64
    /// 报名人数（membersV2 键数）。
    public let memberCount: Int
    /// 实际参战人数（roles 条目数）。
    public let participantsCount: Int
    public let onlineCount: Int
    /// 四圣个数 / 四圣分数。
    public let blessingCount: Int
    public let blessingScore: Int64
    /// 积分 = 占领点分值和 + 四圣分。
    public let score: Int64
    public let buildingCount: Int
    /// 占领点 id 列表（`buildings` 的 key，x 优先排序——路径染色的配对口径）。
    public let buildingIDs: [String]
    /// 大本营坐标（"x_y"）。
    public let strongholdID: String
    /// 服务端状态原文（`state`：normal=正常，其余=已淘汰）。
    public let state: String

    /// 免费复活剩余（150 − 已用，下限 0）。
    public var reviveRemaining: Int64 { max(0, 150 - reviveCount) }

    /// 是否已淘汰（`state != "normal"`）。
    public var isEliminated: Bool { state != "normal" }

    public var stateText: String { isEliminated ? "已淘汰" : "正常" }

    /// K/D（击杀 ÷ 死亡；零死亡按击杀数展示，口径同参考脚本）。
    public var kdText: String {
        guard deaths > 0 else { return "\(killCount)" }
        return String(format: "%.2f", Double(killCount) / Double(deaths))
    }
}

/// 一个成员的战况（`roles` 条目）。
public struct SaltMember: Sendable, Identifiable {
    public let name: String
    public let legionID: Int64
    /// idle=空闲 march=行进 watching=观看 over=死亡。
    public let state: String
    /// 刨地次数（`aB`）。
    public let digGround: Int64
    /// 击杀（`killCnt`）。
    public let kill: Int64
    /// 免费复活已用（上限 5）。
    public let revive: Int64
    /// 死亡次数（`d`；6 次以内免费）。
    public let die: Int64
    /// 复活丹（max(0, d-6)）。
    public let dan: Int64
    public let point: Int64
    public let isOnline: Bool

    public var id: String { "\(legionID)_\(name)" }

    public var stateText: String {
        switch state {
        case "idle": return "空闲"
        case "march": return "行进"
        case "watching": return "观看"
        case "over": return "死亡"
        default: return state.isEmpty ? "未知" : state
        }
    }

    /// K/D（两位小数；无死亡时按击杀数展示）。
    public var kdText: String {
        guard die > 0 else { return String(kill) }
        return String(format: "%.2f", Double(kill) / Double(die))
    }
}

/// 渲染就绪的地图节点（染色已定，窗口直接画）。
public struct SaltRenderedNode: Sendable {
    public let id: String
    /// 据点自己的名称（服务端给的；空 = 用类型表兜底）。
    public let name: String
    /// 列 0...40（奇数列下错半格）。
    public let x: Int
    /// 行 0...31。
    public let y: Int
    public let type: Int
    /// 最终染色（含占领路径扩散后的俱乐部色）。
    public let colorHex: String
    public let belongsLegionID: Int64?
    public let point: Int64
    public let hp: Int64
    public let maxHP: Int64

    public var isRoad: Bool { type == 9 }
    public var isStronghold: Bool { type == 4 }
    public var isCore: Bool { type == 6 }

    /// 地图标注文本，优先级：
    ///   ① **这个据点自己的名称**（服务端 buildingData.name）——同类型不同点名称也不同；
    ///   ② 类型表里的名称（服务端没给名称时的类型级兜底）；
    ///   ③ 生命值短名「30血」（都没填时）。
    public var labelText: String {
        if !name.isEmpty { return name }
        if let spec = SaltFieldCatalog.stronghold(type: type), !spec.name.isEmpty {
            return spec.name
        }
        return typeName
    }

    /// 据点短名（**兜底**标签：类型表里名称没填时用，道路不参与）。
    ///
    /// ⚠️ 1/2/3/5 那四个数字是**据点生命值**（30/50/80/100 血），不是分值——
    /// 2026-09-18 用户纠正。分值另有其物，见 `SaltStrongholdSpec.score`。
    public var typeName: String {
        switch type {
        case 1: return "30血"
        case 2: return "50血"
        case 3: return "80血"
        case 4: return "大本营"
        case 5: return "100血"
        case 6: return "核心"
        default: return ""
        }
    }
}

// MARK: - 据点目录（按类型固定的名称 / 生命值 / 积分）
//
// 用户口径（2026-09-19）：
//   · **同一类型**的据点，生命值和积分都一样；不同类型不一样 → 两个值都按 type 定，
//     不需要逐个据点填；
//   · 名称**按据点实例**各不相同（同类型也不一样）→ 地图标注优先用服务端给的点名；
//     本表 `name` 只是「服务端没给名称」时的**类型级兜底**（没填则退回「30血」）。
//
// 取值优先级（见 `SaltFieldChartController.buildingScore`）：
//   ① 表里 `score > 0` → 用表（类型固定值，最可靠）；
//   ② 否则用服务端 `buildingData[...].point`（服务端给了就用）；
//   ③ 都没有 → 0（现状：积分只算四圣分）。
//
// ⚠️ **要填的就是这张表**：`name` 与 `score` 两列（生命值已知，已填好）。
//    只改这里就行——地图标注与俱乐部积分都读它，不需要动别处。

/// 一种据点的固定属性。
public struct SaltStrongholdSpec: Sendable {
    public let type: Int
    /// 据点名称（地图标注用；空串 = 未填 → 退回生命值短名）。
    public let name: String
    /// 生命值（1/2/3/5 = 30/50/80/100，用户口径）。
    public let hp: Int64
    /// 积分（同类型同分；0 = 未填 → 退回服务端 `point`）。
    public let score: Int64

    public init(type: Int, name: String = "", hp: Int64, score: Int64 = 0) {
        self.type = type
        self.name = name
        self.hp = hp
        self.score = score
    }

    /// 地图标注文本（名称没填时退回「N血」）。
    public var label: String { name.isEmpty ? "\(hp)血" : name }
}

// MARK: - 地图几何（错列六边形 odd-q）

/// 盐场六边形地图的几何：格子中心 / 画布自适应 / **坐标命中**。
///
/// 为什么单独抽成一个类型：绘制与悬停命中**必须用同一套数学**——两处各算一遍必然漂移，
/// 表现就是「鼠标指着 A 格，提示写 B 格」。抽出来后探针也能直接做
/// 「格子中心 → 命中 → 回到原格子」的往返测试（见 /tmp/saltfield-live-probe）。
///
/// 口径：odd-q（奇数列下移半格），hexSize 13.25 / gap 2.75，与助手仓 LegionWar.vue 的
/// 绘制参数一致；网格尺寸取自 `SaltFieldRoadPoints.columns/rows`（41×32）。
public struct SaltFieldMapGeometry: Sendable {
    public let hexSize: CGFloat
    public let gap: CGFloat

    public init(hexSize: CGFloat = 13.25, gap: CGFloat = 2.75) {
        self.hexSize = hexSize
        self.gap = gap
    }

    public var hexHeight: CGFloat { CGFloat(3).squareRoot() * hexSize }

    /// 列 → 中心横坐标。
    public func centerX(_ col: Int) -> CGFloat {
        CGFloat(col) * (hexSize * 1.5 + gap) + hexSize
    }

    /// 行（列 col 内）→ 中心纵坐标（奇数列下错半格）。
    public func centerY(_ row: Int, col: Int) -> CGFloat {
        CGFloat(row) * (hexHeight + gap) + hexSize + (col % 2 == 1 ? hexHeight / 2 : 0)
    }

    /// 整张网格的画布尺寸。
    public var mapSize: CGSize {
        CGSize(width: centerX(SaltFieldRoadPoints.columns - 1) + hexSize + gap,
               height: centerY(SaltFieldRoadPoints.rows - 1, col: 0) + hexHeight + gap)
    }

    /// 画布尺寸 → 缩放（上限 1.6）与居中偏移。
    public func fit(in size: CGSize) -> (scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat) {
        let map = mapSize
        guard map.width > 0, map.height > 0 else { return (1, 0, 0) }
        let scale = min(size.width / map.width, size.height / map.height, 1.6)
        return (scale,
                max(0, (size.width - map.width * scale) / 2),
                max(0, (size.height - map.height * scale) / 2))
    }

    /// 格子中心在画布里的位置。
    public func center(col: Int, row: Int, in size: CGSize) -> CGPoint {
        let fit = fit(in: size)
        return CGPoint(x: fit.offsetX + centerX(col) * fit.scale,
                       y: fit.offsetY + centerY(row, col: col) * fit.scale)
    }

    /// 画布坐标 → 节点 id（逆变换：先估列，再在 ±1 列/行里找最近且落在六边形内的格子）。
    /// 命中不到（落在空白处）返回 nil。
    public func nodeID(at point: CGPoint, in size: CGSize) -> String? {
        let fit = fit(in: size)
        let stepX = (hexSize * 1.5 + gap) * fit.scale
        let stepY = (hexHeight + gap) * fit.scale
        let radius = hexSize * fit.scale
        guard stepX > 0, stepY > 0, radius > 0 else { return nil }
        let colGuess = Int(((point.x - fit.offsetX - hexSize * fit.scale) / stepX).rounded())
        for col in (colGuess - 1)...(colGuess + 1) {
            guard col >= 0, col < SaltFieldRoadPoints.columns else { continue }
            let stagger = (col % 2 == 1) ? hexHeight / 2 * fit.scale : 0
            let rowGuess = Int(((point.y - fit.offsetY - hexSize * fit.scale - stagger) / stepY).rounded())
            for row in (rowGuess - 1)...(rowGuess + 1) {
                guard row >= 0, row < SaltFieldRoadPoints.rows else { continue }
                let center = CGPoint(x: fit.offsetX + centerX(col) * fit.scale,
                                     y: fit.offsetY + centerY(row, col: col) * fit.scale)
                if hypot(point.x - center.x, point.y - center.y) <= radius {
                    return "\(col)_\(row)"
                }
            }
        }
        return nil
    }
}

/// 据点名称**坐标表**（手填）：节点 id（"列_行"，如 "27_10"）→ 该据点自己的名称。
///
/// 用途：地图骨架是静态的、服务端数据要进盐场才有 —— 这张表让你**提前**把每个据点的
/// 名字填好，没数据时地图也能显示正确名称。
///
/// 怎么取坐标：把鼠标移到盐场窗口地图上的据点，光标旁会浮出它的坐标（如 `27_10`），
/// 照着往下面填一行即可；悬停时该格还会描一圈黑边，方便对准。
/// （注意：工具栏开了「穿透」时窗口不收鼠标事件，悬停不生效，先关掉穿透再取坐标。）
///
/// 优先级（见 `SaltFieldChartController.renderNodes`）：
///   本表 → 服务端 `buildingData[...].name` → 类型表名 → 「30血」。
/// 所以**只填你想要的**就行，没填的点自动走后面几级。
public enum SaltFieldNodeNames {
    /// 节点 id → 名称。**照着这个格式加行**（逗号分隔）：
    /// ```
    /// public static let byNodeID: [String: String] = [
    ///     "27_10": "青龙坛",
    ///     "28_15": "白虎营",
    /// ]
    /// ```
    /// 现在留空 `[:]` = 全部走服务端/类型兜底。
    public static let byNodeID: [String: String] = [:]

    /// 查名称（没填返回 nil）。
    public static func name(nodeID: String) -> String? {
        guard let value = byNodeID[nodeID], !value.isEmpty else { return nil }
        return value
    }
}

/// 据点类型目录（`buildingData.type` → **按类型固定**的属性：生命值 / 积分 / 类型级兜底名）。
public enum SaltFieldCatalog {
    /// 类型 → 据点属性。**名称与积分待填**：把游戏里的名称/积分写进对应行即可。
    /// 4=大本营 / 6=核心 的血量与积分随服务端 `buildingData`（这里 hp 留 0，仅提供名称）。
    public static let strongholds: [Int: SaltStrongholdSpec] = [
        1: SaltStrongholdSpec(type: 1, name: "", hp: 30, score: 0),
        2: SaltStrongholdSpec(type: 2, name: "", hp: 50, score: 0),
        3: SaltStrongholdSpec(type: 3, name: "", hp: 80, score: 0),
        5: SaltStrongholdSpec(type: 5, name: "", hp: 100, score: 0),
        4: SaltStrongholdSpec(type: 4, name: "大本营", hp: 0, score: 0),
        6: SaltStrongholdSpec(type: 6, name: "核心", hp: 0, score: 0),
    ]

    /// 类型对应的据点属性（道路 9 / 未知类型返回 nil）。
    public static func stronghold(type: Int) -> SaltStrongholdSpec? { strongholds[type] }
}

/// 一次战场快照（图表窗口的完整数据源，4s 级轮询整体替换）。
public struct SaltFieldSnapshot: Sendable {
    /// 页面时钟（毫秒）——「最后更新」显示用。
    public let timestampMs: Double
    public let battlefieldID: Int64?
    /// 地图渲染节点（id → node；含静态道路骨架 + 动态建筑）。
    public let nodes: [String: SaltRenderedNode]
    /// 俱乐部战况（积分降序）。
    public let legions: [SaltLegion]
    /// 成员战况（击杀降序）。
    public let members: [SaltMember]
}

// MARK: - 实时地图归属（主连接查询：战场 → 对手 → 俱乐部详情）
//
// 两个参考脚本各出一半，合起来才是完整的「实时盐场」：
//   · 雪碧助手 → **战场连接** `war_enterbattlefield { battlefieldId }` 拿实时战况
//     （`battlefield.legions` / `battlefield.roles`，见 renderGlobalWarReport 的统计口径）；
//   · 星驰     → **主连接** `legion_getbattlefield`（phase + battlefieldId）→
//     `legion_getopponent { phase, battlefieldId }`（每条 legion 的 `position` = 大本营序号）→
//     `legion_getinfo` / `legion_getinfobyid`（俱乐部名 / 服号 / 红淬 / 公告）。
//     这是**实时地图**的数据源：服务端只给序号，坐标由静态表换算
//     （`SaltFieldRoadPoints.strongholdNodeID(position:)`）。
//
// 为什么两条都要：战场连接只在「玩家人在盐场战场界面」时存在；主连接任何时候都在。
// 所以没进场时地图仍能标出各俱乐部的落位，进场后叠加实时战况。

/// 联盟口径（参考脚本「星驰」`getAllianceColor`：靠俱乐部公告里的关键词分盟）。
public enum SaltAlliance {
    public enum Name: String, CaseIterable, Sendable {
        case meng = "梦盟"
        case union = "大联盟"
        case dragon = "龍盟"
        case unknown = "未知联盟"

        /// 地图填充色（参考脚本三盟配色原值）。
        public var fillHex: String {
            switch self {
            case .meng: return "#ff6b6b"
            case .union: return "#26de81"
            case .dragon: return "#48dbfb"
            case .unknown: return "#f8f9fa"
            }
        }

        /// 标签文字色（深底白字 / 浅底深字）。
        public var textHex: String {
            switch self {
            case .meng, .union: return "#ffffff"
            case .dragon, .unknown: return "#333333"
            }
        }
    }

    /// 公告 → 联盟（大小写不敏感；「龍盟」与「龙盟」都认）。
    public static func name(of announcement: String) -> Name {
        let text = announcement.lowercased()
        if text.contains("梦盟") { return .meng }
        if text.contains("大联盟") { return .union }
        if text.contains("龍盟") || text.contains("龙盟") { return .dragon }
        return .unknown
    }
}

/// 一家参战俱乐部（`legion_getopponent` 的 position + `legion_getinfobyid` 的详情）。
public struct SaltLiveClub: Sendable, Identifiable {
    public let legionID: Int64
    /// 大本营序号（1...20；格子由 `SaltFieldRoadPoints.strongholdNodeID(position:)` 换算）。
    public let position: Int
    public let name: String
    public let serverID: Int64
    public let power: Int64
    /// 红淬数（`quenchNum`）。
    public let quench: Int
    /// 俱乐部公告（联盟色靠它识别）。
    public let announcement: String

    public var id: Int64 { legionID }

    /// 地图标签（参考脚本口径：`【N服】俱乐部名`；服号缺失时只留名字）。
    public var labelText: String { serverID > 0 ? "【\(serverID)服】\(name)" : name }

    public var alliance: SaltAlliance.Name { SaltAlliance.name(of: announcement) }

    /// 战力显示（亿/万档，与战况表同口径）。
    public var powerText: String {
        if power >= 100_000_000 { return String(format: "%.2f亿", Double(power) / 100_000_000) }
        if power >= 10_000 { return String(format: "%.1f万", Double(power) / 10_000) }
        return "\(power)"
    }
}

/// 一次实时地图归属查询的结果（主连接链：战场 → 对手 → 各家详情）。
public struct SaltLiveBattlefield: Sendable {
    /// 场次阶段（查对手要带上）。
    public let phase: Int
    public let battlefieldID: Int64
    /// 参战俱乐部（按大本营序号升序）。
    public let clubs: [SaltLiveClub]
    public let fetchedAt: Date

    /// 大本营序号 → 俱乐部（地图标签查表用）。
    public var clubByPosition: [Int: SaltLiveClub] {
        Dictionary(uniqueKeysWithValues: clubs.map { ($0.position, $0) })
    }

    /// 按联盟分组的俱乐部数（诊断 / 图例用）。
    public var allianceCounts: [SaltAlliance.Name: Int] {
        var counts: [SaltAlliance.Name: Int] = [:]
        for club in clubs { counts[club.alliance, default: 0] += 1 }
        return counts
    }
}

// MARK: - 历史战绩（主连接查询，任意时间可查）
//
// 协议口径对齐自助手仓 GreatRouteRankListPageCard.vue / clubBattleUtils.js：
//   ① `saltroad_getwartype { date: "YYYY/MM/DD"(当月首个周六) }` → warType
//   ② warType → 榜单范围（青铜 1-1000 / 秘蓝 1-500 / 月宫 1-200 / 天宫 1-80）
//   ③ `saltroad_getsaltroadwartotalrank { date: "YYMMDD"(场次日), startRank, endRank }`
//      → legionList[]（rank/name/score/redQuench/power/serverId）
//   我方历史场次：`legion_getinfo` → info.warMap（按周分组的 {legionWarType, warDate(秒)}）
//   + info.warRank（与 warMap 展开后倒序对齐的名次）。

/// 历史盐场名称 / 榜单范围口径（自助手仓 getRankParams / getWarTypeName）。
public enum SaltHistoryCatalog {
    /// warType → 中文名。
    public static func warTypeName(_ type: Int) -> String {
        switch type {
        case 15: return "灰岩岛"
        case 16: return "进阶周赛"
        case 17: return "进阶月赛"
        case 18: return "青铜周赛"
        case 19: return "青铜月赛"
        case 20: return "秘蓝周赛"
        case 21: return "秘蓝月赛"
        case 22: return "月宫周赛"
        case 23: return "月宫月赛"
        case 24: return "天宫周赛"
        case 25: return "天宫月赛"
        case 6: return "夺旗赛"
        default: return "伟大航路"
        }
    }

    /// warType → 榜单查询范围（endRank 上限 + 岛名）。
    /// 青铜/秘蓝/月宫/天宫的范围来自自助手仓 getRankParams；其余类型（灰岩/进阶/
    /// 夺旗等，参考项目未收录）放开用最大范围 1-1000 **尝试性查询**——
    /// 服务端不认就返回空（界面有提示），2026-09 实测类型「进阶周赛」就是这样进来的。
    public static func rankParams(_ type: Int) -> (startRank: Int, endRank: Int, name: String)? {
        switch type {
        case 18, 19: return (1, 1000, "青铜岛")
        case 20, 21: return (1, 500, "秘蓝岛")
        case 22, 23: return (1, 200, "紫青月宫")
        case 24, 25: return (1, 80, "黄金天宫")
        default: return (1, 1000, warTypeName(type))
        }
    }

    // MARK: 日期口径（自助手仓 getFirstSaturdayOfMonth / getRankQueryDate / 开放时间）

    private static let calendar = Calendar.current

    /// 当月第一个周六（`saltroad_getwartype` 的 date，格式 "YYYY/MM/DD"）。
    public static func firstSaturdayString(of date: Date) -> String {
        let firstSaturday = firstSaturday(of: date)
        let components = calendar.dateComponents([.year, .month, .day], from: firstSaturday)
        return String(format: "%04ld/%02ld/%02ld",
                      components.year ?? 2026, components.month ?? 1, components.day ?? 1)
    }

    /// 当月第一个周六（Date）。
    public static func firstSaturday(of date: Date) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        let first = calendar.date(from: DateComponents(year: components.year,
                                                       month: components.month, day: 1)) ?? date
        let weekday = calendar.component(.weekday, from: first) // 1=周日 … 7=周六
        let diff = (7 - weekday) % 7
        return calendar.date(byAdding: .day, value: diff, to: first) ?? first
    }

    /// 场次日期（`saltroad_getsaltroadwartotalrank` 的 date，格式 "YYMMDD"）。
    public static func yymmddString(of date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = (components.year ?? 2026) % 100
        return String(format: "%02ld%02ld%02ld", year, components.month ?? 1, components.day ?? 1)
    }

    /// 场次日期（`legionwar_getdetails` 的 date，格式 "YYYY/MM/DD"——猫助手同源）。
    public static func slashDateString(of date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld/%02ld/%02ld",
                      components.year ?? 2026, components.month ?? 1, components.day ?? 1)
    }

    /// 月份内全部盐场日（自助手仓的开放口径：前四周周六周赛 + 第四周周日月赛）。
    public static func saltDates(in month: Date) -> [Date] {
        let components = calendar.dateComponents([.year, .month], from: month)
        guard let first = calendar.date(from: DateComponents(year: components.year,
                                                             month: components.month, day: 1)),
              let daysInMonth = calendar.range(of: .day, in: .month, for: first)?.count else {
            return []
        }
        var saturdays: [Date] = []
        var sundays: [Date] = []
        for day in 1...daysInMonth {
            guard let date = calendar.date(from: DateComponents(year: components.year,
                                                                month: components.month, day: day)) else { continue }
            let weekday = calendar.component(.weekday, from: date)
            if weekday == 7 { saturdays.append(date) }       // 周六
            if weekday == 1 { sundays.append(date) }         // 周日
        }
        var dates = Array(saturdays.prefix(4))
        if sundays.count >= 4 { dates.append(sundays[3]) }   // 第 4 周周日（月赛）
        return dates
    }

    /// 同一日判断（日历选中态）。
    public static func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }
}

/// 我俱乐部的一场历史盐场（日历点数据源）。
public struct SaltHistoryBattle: Sendable, Identifiable {
    /// 场次日期（warDate 秒级时间戳换算，取当日）。
    public let date: Date
    public let warType: Int
    /// 我方名次（warRank 对应位）。
    public let rank: Int

    public var id: String { "\(warType)-\(Int(date.timeIntervalSince1970))" }
    public var warTypeName: String { SaltHistoryCatalog.warTypeName(warType) }
}

/// 历史总榜的一行（legionList 条目）。
public struct SaltHistoryClubRow: Sendable, Identifiable {
    public let rank: Int
    public let id: Int64
    public let name: String
    public let power: Int64
    /// 盐场积分（legionList.score）。
    public let score: Int64
    /// 红淬数（legionList.redQuench）。
    public let redQuench: Int
    public let serverID: Int64

    public var idValue: Int64 { id }
    public var powerText: String {
        if power >= 100_000_000 { return String(format: "%.2f亿", Double(power) / 100_000_000) }
        if power >= 10_000 { return String(format: "%.1f万", Double(power) / 10_000) }
        return "\(power)"
    }
}

/// 一次历史总榜查询的结果。
public struct SaltHistoryResult: Sendable {
    /// 查询的场次日期。
    public let battleDate: Date
    /// 当月盐场类型（0 = 未取到，榜单名退化为"盐场"）。
    public let warType: Int
    public let rows: [SaltHistoryClubRow]
    public let fetchedAt: Date

    public var warTypeName: String { SaltHistoryCatalog.warTypeName(warType) }
    /// 榜单范围名（青铜岛/秘蓝岛/…；类型未知或不可查时退化为"盐场"）。
    public var rangeName: String { SaltHistoryCatalog.rankParams(warType)?.name ?? "盐场" }
}

// MARK: - 历史成员明细（legionwar_getdetails，猫助手同源口径）
//
// `legionwar_getdetails { date: "YYYY/MM/DD" }` → roleDetailsList：
// **该场盐场我俱乐部每个成员**的 胜/负/攻城 明细——这才是「指定日期的盐场战绩」
// 的主数据（盐场未开放也能查）。

/// 明细表的一行（一个成员）。
/// 字段语义（星驰参考图口径）：winCnt=**击杀**、loseCnt=**死亡**、buildingCnt=攻城。
public struct SaltWarDetailRow: Sendable, Identifiable {
    public let name: String
    /// 击杀数（winCnt）。
    public let win: Int
    /// 死亡数（loseCnt）。
    public let lose: Int
    /// 攻城次数（buildingCnt）。
    public let building: Int

    public var id: String { name }
    /// K/D = 击杀数 ÷ 死亡次数；零死亡按击杀数本身计（杀100死20 → 5.00）。
    public var kd: Double { lose > 0 ? Double(win) / Double(lose) : Double(win) }
    public var kdText: String { String(format: "%.2f", kd) }
    /// 总积分 = 击杀×10 + 死亡×1 + 攻城×1（用户确认口径，2026-09-18）。
    public var score: Int { win * 10 + lose + building }
}

/// 一次成员明细查询的结果。
public struct SaltWarDetailsResult: Sendable {
    public let battleDate: Date
    /// 成员明细（击杀降序，猫助手排序口径一致）。
    public let rows: [SaltWarDetailRow]
    public let fetchedAt: Date

    public var totalKill: Int { rows.reduce(0) { $0 + $1.win } }
    public var totalDeath: Int { rows.reduce(0) { $0 + $1.lose } }
    public var totalBuilding: Int { rows.reduce(0) { $0 + $1.building } }
    /// 整体 K/D = 总击杀 ÷ 总死亡（总死亡为 0 时按总击杀计）。
    public var overallKDText: String {
        totalDeath > 0 ? String(format: "%.2f", Double(totalKill) / Double(totalDeath))
                       : String(format: "%.2f", Double(totalKill))
    }
}

// MARK: - 颜色

/// 盐场调色板（与自助手仓 `colorArray` / `typeBg` 逐色对齐）。
public enum SaltColorPalette {
    /// 核心四周那 6 格的高亮色（粉红：全场唯一争抢焦点，用户点名要标出来）。
    public static let coreRingColor = "#FF69B4"

    /// 骨架之外的「空格子」底色（整张网格都要画，空格留白框）。
    public static let emptyCellColor = "#FFFFFF"
    /// 俱乐部色表（index 0...19；带透明度的 hex 原样保留，渲染层解析）。
    static let legionColors: [String] = [
        "#ff000033", "#00ff0033", "#0000ff33", "#FFFF0033", "#FF00FF33",
        "#00ffff33", "#66666633", "#cdcdcd", "#f77aff", "#c9a0ff",
        "#a0c6ff", "#a0fffb", "#a0ffb0", "#cdffa0", "#fffca0",
        "#ffdda0", "#ffbfa0", "#f16f5a", "#fb9494", "#dcdd9a"
    ]

    /// 俱乐部颜色（越界回退灰）。
    public static func legionColor(_ index: Int) -> String {
        guard legionColors.indices.contains(index) else { return "#66666666" }
        return legionColors[index]
    }

    /// 类型底色（typeBg 口径）。
    public static func typeColor(_ type: Int) -> String {
        switch type {
        case 1: return "orange"
        case 2: return "yellow"
        case 3: return "gray"
        case 4: return "red"
        case 5: return "green"
        case 6: return "#1bd7d7"
        case 9: return "#2452f7"
        default: return "#3a3a3a"
        }
    }
}
