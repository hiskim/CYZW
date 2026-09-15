import Foundation

/// 游戏账号：一份 `.bin` 凭据文件的引用。
///
/// 凭据文件本身是宿主不可读的黑盒；持久化文件名就是账号身份（跨启动稳定），
/// 登录时由认证器把文件内容原样提交给认证服务。
public struct GameAccount: Identifiable, Codable, Hashable, Sendable {
    /// `.bin` 文件名（含扩展名），即账号稳定 ID。
    public let fileName: String
    /// 导入时间（列表排序兜底用）。
    public var importedAt: Date
    /// 归属分组名。阶段 1 只有「未分组」一个系统分组，分组管理在阶段 2 扩展。
    public var groupName: String

    public static let defaultGroupName = "未分组"

    public init(fileName: String, importedAt: Date = .now, groupName: String = GameAccount.defaultGroupName) {
        self.fileName = fileName
        self.importedAt = importedAt
        self.groupName = groupName
    }

    public var id: String { fileName }
    /// 展示名：去掉扩展名的文件名。
    public var nickname: String { (fileName as NSString).deletingPathExtension }
}

/// 账号文件在库中的元信息（扫描目录得到，不含文件内容）。
public struct AccountBinFileInfo: Identifiable, Hashable, Sendable {
    public let fileName: String
    public let creationDate: Date
    public let modificationDate: Date

    public var id: String { fileName }

    public init(fileName: String, creationDate: Date, modificationDate: Date) {
        self.fileName = fileName
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }
}
