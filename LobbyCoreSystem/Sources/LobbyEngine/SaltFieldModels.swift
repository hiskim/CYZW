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
