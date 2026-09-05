import Foundation

struct Account: Identifiable, Codable, Hashable {
    /// The legacy credential file is opaque. Its persisted filename is the
    /// account identity, so selection remains stable across shell launches.
    let fileName: String
    let importedAt: Date

    var id: String { fileName }
    var nickname: String { (fileName as NSString).deletingPathExtension }
    var gameName: String { "旧 .bin 账号" }
    var groupName: String { "本地文件" }

    init(fileName: String, importedAt: Date = .now) {
        self.fileName = fileName
        self.importedAt = importedAt
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
