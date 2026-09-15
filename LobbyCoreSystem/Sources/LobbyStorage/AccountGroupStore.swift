import Foundation
import LobbyDomain

/// 分组定义 + 账号归属的持久化存储。
///
/// 与上一代的差异：旧版归属按**分组名**字符串匹配（改名要搬家），本代统一用
/// `账号 ID → 分组 ID` 归属表，重命名天然安全。持久化到
/// `Application Support/GameLobby/groups.json`（不再塞 UserDefaults）。
public final class AccountGroupStore: GroupStoring, @unchecked Sendable {
    private struct Document: Codable {
        var groups: [AccountGroup] = []
        /// 账号 ID → 分组 ID（伪分组 ID 不落表，缺席即「未分组」）。
        var assignments: [String: String] = [:]
        /// 伪分组展开状态（自定义分组的展开状态随定义持久化）。
        var expansions: [String: Bool] = [:]
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.xyzw.gamelobby.groups")

    public init(fileURL: URL = LobbyConfiguration.lobbySupportDirectory.appendingPathComponent("groups.json")) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    // MARK: - 读写

    public func loadDefinitions() -> [AccountGroup] {
        queue.sync { load().groups }
    }

    public func loadAssignments() -> [String: String] {
        queue.sync { load().assignments }
    }

    public func loadExpansions() -> [String: Bool] {
        queue.sync { load().expansions }
    }

    public func save(definitions: [AccountGroup], assignments: [String: String], expansions: [String: Bool]) {
        queue.async { [fileURL] in
            let document = Document(groups: definitions.filter { !$0.isSynthetic },
                                    assignments: assignments,
                                    expansions: expansions)
            guard let data = try? JSONEncoder().encode(document) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func load() -> Document {
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(Document.self, from: data) else { return Document() }
        return document
    }
}
