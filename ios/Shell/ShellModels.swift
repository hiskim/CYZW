import Foundation

struct Account: Identifiable, Codable, Hashable {
    let id: UUID
    var nickname: String
    var gameName: String
    var groupName: String

    init(id: UUID = UUID(), nickname: String, gameName: String, groupName: String) {
        self.id = id
        self.nickname = nickname
        self.gameName = gameName
        self.groupName = groupName
    }
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
