import Foundation

// MARK: - 盐场战场快照 · 数据模型
//
// 字段口径全部对齐自助手仓 `legionWar.js` 的 `extractValidData`（实测协议字段名）：
// battlefield{buildingData, legions, roles}。快照是**渲染就绪**形态——
// 地图染色（BFS 路径）在控制器构建时一次算完，图表窗口只画不算。

/// 一个建筑/据点/道路点（服务端 `buildingData` 条目）。
public struct SaltBuilding: Sendable {
    public let id: String
    /// 9=道路 1/2/3/5=30/50/80/100 分据点 4=大本营 6=核心。
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

    /// 免费复活剩余（150 − 已用，下限 0）。
    public var reviveRemaining: Int64 { max(0, 150 - reviveCount) }
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

    /// 据点短名（typeBg 的中文口径；道路不参与）。
    public var typeName: String {
        switch type {
        case 1: return "30分"
        case 2: return "50分"
        case 3: return "80分"
        case 4: return "大本营"
        case 5: return "100分"
        case 6: return "核心"
        default: return ""
        }
    }
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
public struct SaltWarDetailRow: Sendable, Identifiable {
    public let name: String
    /// 胜场（winCnt）。
    public let win: Int
    /// 负场（loseCnt）。
    public let lose: Int
    /// 攻城次数（buildingCnt）。
    public let building: Int

    public var id: String { name }
    public var total: Int { win + lose }
    /// 胜率（百分比，四舍五入；无战斗为 0）。
    public var rate: Int { total > 0 ? Int((Double(win) / Double(total) * 100).rounded()) : 0 }
}

/// 一次成员明细查询的结果。
public struct SaltWarDetailsResult: Sendable {
    public let battleDate: Date
    /// 成员明细（胜次降序，与猫助手排序口径一致）。
    public let rows: [SaltWarDetailRow]
    public let fetchedAt: Date

    public var totalWin: Int { rows.reduce(0) { $0 + $1.win } }
    public var totalLose: Int { rows.reduce(0) { $0 + $1.lose } }
    public var totalBuilding: Int { rows.reduce(0) { $0 + $1.building } }
}

// MARK: - 颜色

/// 盐场调色板（与自助手仓 `colorArray` / `typeBg` 逐色对齐）。
public enum SaltColorPalette {
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
