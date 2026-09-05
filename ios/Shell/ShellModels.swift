import Foundation

struct AccountGroup: Identifiable, Codable, Hashable {
    static let allID = "all-accounts"
    static let all = AccountGroup(id: allID, name: "全部", colorName: "gray", isHidden: false, sortOrder: 0)

    let id: String
    var name: String
    var colorName: String
    var isHidden: Bool
    var sortOrder: Int

    init(
        id: String = UUID().uuidString,
        name: String,
        colorName: String = "blue",
        isHidden: Bool = false,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.colorName = colorName
        self.isHidden = isHidden
        self.sortOrder = sortOrder
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
