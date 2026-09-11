import Foundation

/// 账号模型别名：与架构文档中的 AccountModel 命名对齐。
/// 分组树、侧边栏与批量启停逻辑统一使用 AccountModel 指代单个账号。
typealias AccountModel = Account

/// 侧边栏树形分组节点：分组定义 + 展开状态 + 组内账号。
///
/// 持久化契约：`accounts` 是运行时物化数据（由 ViewModel 按归属关系注入），
/// 刻意不参与 Codable；`isExpanded` 会随分组定义一并持久化，缺失时默认展开。
/// 旧版本持久化数据使用 `name` 键，解码时自动迁移为 `groupName`。
struct AccountGroup: Identifiable, Hashable, Codable {
    static let allID = "all-accounts"
    static let ungroupedID = "ungrouped-accounts"
    static let all = AccountGroup(id: allID, groupName: "全部", colorName: "gray", isHidden: false, sortOrder: 0)

    let id: String                 // 分组ID
    var groupName: String          // 分组名称
    var colorName: String
    var isHidden: Bool
    var sortOrder: Int
    var isExpanded: Bool           // 是否展开
    var accounts: [AccountModel] = []   // 该组下的账号（运行时物化，不持久化）

    /// 伪分组（"全部"/"未分组"）不由用户创建，不参与分组定义的持久化。
    var isSynthetic: Bool { id == Self.allID || id == Self.ungroupedID }

    init(
        id: String = UUID().uuidString,
        groupName: String,
        colorName: String = "blue",
        isHidden: Bool = false,
        sortOrder: Int = 0,
        isExpanded: Bool = true,
        accounts: [AccountModel] = []
    ) {
        self.id = id
        self.groupName = groupName
        self.colorName = colorName
        self.isHidden = isHidden
        self.sortOrder = sortOrder
        self.isExpanded = isExpanded
        self.accounts = accounts
    }

    private enum CodingKeys: String, CodingKey {
        case id, groupName, colorName, isHidden, sortOrder, isExpanded
        case legacyName = "name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        groupName = try container.decodeIfPresent(String.self, forKey: .groupName)
            ?? container.decodeIfPresent(String.self, forKey: .legacyName)
            ?? ""
        colorName = try container.decodeIfPresent(String.self, forKey: .colorName) ?? "blue"
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        accounts = []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(groupName, forKey: .groupName)
        try container.encode(colorName, forKey: .colorName)
        try container.encode(isHidden, forKey: .isHidden)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(isExpanded, forKey: .isExpanded)
    }
}

struct Account: Identifiable, Codable, Hashable {
    /// The legacy credential file is opaque. Its persisted filename is the
    /// account identity, so selection remains stable across shell launches.
    let fileName: String
    let importedAt: Date
    var groupName: String

    static let defaultGroupName = "未分组"

    var id: String { fileName }
    var nickname: String { (fileName as NSString).deletingPathExtension }
    var gameName: String { "旧 .bin 账号" }
    init(fileName: String, importedAt: Date = .now, groupName: String = Account.defaultGroupName) {
        self.fileName = fileName
        self.importedAt = importedAt
        self.groupName = groupName
    }
}

enum LegacyCocosLaunch {
    static let notification = Notification.Name("com.xyzw.ios2.launchLegacyCocos")
    static let binFileNameKey = "binFileName"
    static let stateNotification = Notification.Name("com.xyzw.ios2.legacyCocosState")
    static let stateKey = "state"
    static let messageKey = "message"

    static func request(binFileName: String) {
        NotificationCenter.default.post(
            name: notification,
            object: nil,
            userInfo: [binFileNameKey: binFileName]
        )
    }
}

enum LegacyCocosPresentation: Equatable {
    case shell
    case loggingIn(Account)
    case failed(Account, String)
    case game
}

struct Plugin: Identifiable, Hashable {
    let id: UUID
    var name: String
    var detail: String
    var assetName: String
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, detail: String, assetName: String, isEnabled: Bool) {
        self.id = id
        self.name = name
        self.detail = detail
        self.assetName = assetName
        self.isEnabled = isEnabled
    }
}
