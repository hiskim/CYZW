import Foundation
import LobbyDomain

// MARK: - 一个 `.bin` 名下有哪些区服角色
//
//   POST /login/serverlist?_seq=3   body = `.bin` 原字节
//     → { areaList, serverList, roleCount, recommendId, roles }
//     roles: { "<roleId>": { roleId, serverId, name, level, power, … } }
//
// ⚠️ **纯 HTTP，不建立游戏会话**——与 `AccountProfileFetcher`（authuser + WSS）不同，
// 这条路径不会顶掉正在运行的实例，可以随便拉。
//
// ⚠️ 请求体是**原字节**，`O4e-Encoding` 头**不发**（助手仓也是这么做的）：
// 原始 `.bin` 可能是 `lx`，也见过 `x`；不发头时服务端按首字节自动识别（实测两类都能过），
// 而发错头会被直接拒。
//
// ⚠️ `roles[].power` 只对「凭据当前所在的那个区」可信（实测别区明显陈旧、`level` 恒为 1）：
// 这里照实返回，但展示层别把它当权威值（要精确值走 `AccountProfileFetcher`）。
// `roles[].roleId` 是可信的。
public struct AccountRoleCatalog: Sendable {
    public init() {}

    /// 拉取该凭据名下的全部区服角色。
    public func roles(binData: Data) async throws -> AccountRoleList {
        let response = try await GameEndpointClient.post(
            path: LobbyConfiguration.profileServerListPath,
            body: binData,
            encodingHeader: nil)
        let payload = try GameEndpointClient.decodeMessageBody(response)
        let recommended = payload.objectValue?["recommendId"]?.intValue

        guard let table = payload.objectValue?["roles"]?.objectValue else {
            // 单角色账号可能没有 `roles` 表；不是错误，返回空列表让上层显示「只有一个区」。
            return AccountRoleList(roles: [], recommendedServerID: recommended)
        }

        var roles: [GameRole] = []
        roles.reserveCapacity(table.count)
        for field in table.fields {
            guard let entry = field.value.objectValue,
                  let serverID = entry["serverId"]?.intValue else { continue }
            // roleId 优先取条目里的字段（键名未必与它一致）。
            let roleID = entry["roleId"]?.intValue ?? Int64(field.key) ?? 0
            roles.append(GameRole(
                roleID: roleID,
                serverID: serverID,
                name: entry["name"]?.stringValue ?? "",
                power: entry["power"]?.intValue ?? 0,
                level: entry["level"]?.intValue ?? 0))
        }
        // 战力降序（与助手仓一致：先把大号排到前面），同战力按区服号升序保证稳定。
        roles.sort { lhs, rhs in
            if lhs.power != rhs.power { return lhs.power > rhs.power }
            return lhs.serverID < rhs.serverID
        }
        return AccountRoleList(roles: roles, recommendedServerID: recommended)
    }
}
