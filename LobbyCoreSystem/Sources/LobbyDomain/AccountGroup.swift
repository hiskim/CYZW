import Foundation

/// 侧边栏树形分组节点：分组定义 + 展开状态。
///
/// 与上一代（ios/Shell ShellModels.AccountGroup）语义对齐：
/// - `allID` / `ungroupedID` 是两个**伪分组**，不由用户创建、不参与定义持久化；
/// - 成员归属不再按分组名匹配（旧版按 groupName 字符串），本代统一用
///   `账号 ID → 分组 ID` 的归属表（重命名天然安全），
///   成员数组由会话模型在运行时物化，不参与 Codable。
public struct AccountGroup: Identifiable, Hashable, Codable, Sendable {
    /// 「全部」伪分组 ID：成员与所有分组重叠，仅作筛选与展示。
    public static let allID = "all-accounts"
    /// 「未分组」伪分组 ID：收纳未指派到任何分组的账号。
    public static let ungroupedID = "ungrouped-accounts"

    /// 「全部」伪分组。
    public static let all = AccountGroup(id: allID, groupName: "全部",
                                         colorName: "gray", sortOrder: 0)
    /// 「未分组」伪分组。
    public static let ungrouped = AccountGroup(id: ungroupedID, groupName: GameAccount.defaultGroupName,
                                               colorName: "gray", sortOrder: 0)

    public let id: String
    public var groupName: String
    /// 色板名（green/orange/red/purple/teal/yellow/gray/blue…），UI 层映射为 Color。
    public var colorName: String
    public var isHidden: Bool
    public var sortOrder: Int
    public var isExpanded: Bool

    /// 伪分组不由用户创建，不参与分组定义的持久化。
    public var isSynthetic: Bool { id == Self.allID || id == Self.ungroupedID }

    public init(id: String = UUID().uuidString,
                groupName: String,
                colorName: String = "blue",
                isHidden: Bool = false,
                sortOrder: Int = 0,
                isExpanded: Bool = true) {
        self.id = id
        self.groupName = groupName
        self.colorName = colorName
        self.isHidden = isHidden
        self.sortOrder = sortOrder
        self.isExpanded = isExpanded
    }
}

/// 分组内成员排序规则（纯函数，便于无头单测）。
/// 表内账号按 rank 排；缺席的保持相对顺序追加在表内账号之后
/// ——与上一代 accounts(in:) 的口径一致。
public enum AccountOrder {
    public static func apply(_ members: [GameAccount], order: [String]) -> [GameAccount] {
        guard !order.isEmpty else { return members }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return members.sorted { lhs, rhs in
            switch (rank[lhs.id], rank[rhs.id]) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return false
            }
        }
    }
}

/// 分组色板名 → 固定 RGB（UI 层再映射为 Color）。与上一代 macSwatchColor 同源。
public enum GroupSwatch {
    public static func rgb(for colorName: String) -> (Double, Double, Double) {
        switch colorName {
        case "green": return (0.19, 0.82, 0.35)
        case "orange": return (1.0, 0.58, 0.16)
        case "red": return (1.0, 0.27, 0.23)
        case "purple": return (0.69, 0.39, 0.94)
        case "teal": return (0.22, 0.74, 0.70)
        case "yellow": return (1.0, 0.78, 0.12)
        case "gray": return (0.56, 0.56, 0.60)
        default: return (0.16, 0.59, 1.0)
        }
    }

    /// 侧栏管理用的色板候选。
    public static let palette: [(name: String, label: String)] = [
        ("blue", "蓝"), ("green", "绿"), ("orange", "橙"), ("red", "红"),
        ("purple", "紫"), ("teal", "青"), ("yellow", "黄"), ("gray", "灰")
    ]
}
