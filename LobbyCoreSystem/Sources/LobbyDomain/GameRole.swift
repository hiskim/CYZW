import Foundation

// MARK: - 区服编号口径
//
// `serverId` ↔ 「区服号 + 小号位」的换算。口径来自助手仓
// `src/components/ServerRoleList.vue:86-98`，已用真实文件名
// `14001服-温酒.bin`（其 `serverId = 14028`）交叉验证。
//
//   区服号 = serverId - 27（先去小号位的进位）
//   小号位 = serverId ≥ 1_000_000 ? 1 : 0；≥ 2_000_000 → 2
//
// ⚠️ **别用角色资料里的 `serverName` 反推区服号**：在合服区它对不上
// （实测 `serverId=26533` 的角色 `serverName` 是「29001服」）。展示一律用这里的口径。
public enum GameServerID {
    /// 官方区服号与内部 id 的固定偏移。
    public static let offset: Int64 = 27
    /// 第 1 / 2 个小号位的进位步长。
    public static let slotStride: Int64 = 1_000_000

    /// 内部 `serverId` → 展示用区服号。
    public static func serverNumber(for serverID: Int64) -> Int64 {
        var value = serverID
        while value >= slotStride { value -= slotStride }
        return value - offset
    }

    /// 内部 `serverId` → 小号位（0 = 大号，1 / 2 = 第 1 / 2 个小号）。
    public static func slotIndex(for serverID: Int64) -> Int {
        if serverID >= slotStride * 2 { return 2 }
        if serverID >= slotStride { return 1 }
        return 0
    }

    /// 展示用区服号 + 小号位 → 内部 `serverId`（与上两式互逆）。
    public static func serverID(serverNumber: Int64, slot: Int = 0) -> Int64 {
        serverNumber + offset + slotStride * Int64(max(0, slot))
    }
}

// MARK: - 账号名下的一个区服角色
//
// 来源：`POST /login/serverlist?_seq=3` 的 `roles` 表（**不启动游戏**即可拿到）。
// 一个 `.bin` 凭据名下通常有多个区服角色，选哪个由凭据里的 `serverId` 决定——
// 所以「在大厅里选服」= 用目标 `serverID` 派生一份新凭据（见 `BinCredential`）。
public struct GameRole: Identifiable, Hashable, Sendable {
    /// 角色 ID（服务端可信，可与 WSS `role_getroleinfo` 的 `role.roleId` 逐字段对上）。
    public let roleID: Int64
    /// 内部区服 id（决定登录落到哪个区）。
    public let serverID: Int64
    /// 角色名。
    public let name: String
    /// 服务端上报的战力。
    ///
    /// ⚠️ 这个值**只对「该凭据当前所在的那个区」可信**（实测：当前区返回 107 亿与
    /// WSS 实取一致，别的区则明显陈旧、`level` 还恒为 1）。所以它只用来排序 / 做提示，
    /// 要精确数值就走 `AccountProfileFetcher`（authuser + WSS）。
    public let power: Int64
    public let level: Int64

    /// 同一账号在一个 `serverID` 上只会有一个角色，用它当标识足够。
    public var id: Int64 { serverID }

    /// 展示用区服号。
    public var serverNumber: Int64 { GameServerID.serverNumber(for: serverID) }
    /// 小号位（0 = 大号）。
    public var slotIndex: Int { GameServerID.slotIndex(for: serverID) }

    public init(roleID: Int64, serverID: Int64, name: String, power: Int64, level: Int64) {
        self.roleID = roleID
        self.serverID = serverID
        self.name = name
        self.power = power
        self.level = level
    }

    /// 列表里的展示名，如 `14001服 · 仙✨不后`。
    public var displayName: String {
        let base = "\(serverNumber)服"
        return name.isEmpty ? base : "\(base) · \(name)"
    }

    /// 小号位的展示后缀（大号不带后缀）。
    public var slotLabel: String {
        slotIndex == 0 ? "" : "·小号\(slotIndex)"
    }

    /// 派生凭据的推荐文件名，如 `11不不@9338服.bin`、`11不不@9338服·小号1.bin`。
    ///
    /// 用 `@` 而不是覆盖原文件：原凭据一个字都不动，随时可以退回原区服。
    /// 最终落盘名还会过一遍 `AccountBinStore.safeBinName`（清洗非法字符 + 强制 .bin）。
    public func derivedBinFileName(basedOn fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return "\(base)@\(serverNumber)服\(slotLabel).bin"
    }
}

/// 一个 `.bin` 名下的全部区服角色。
public struct AccountRoleList: Sendable, Equatable {
    public let roles: [GameRole]
    /// 服务端给的 `recommendId`：**服务端记的「上次登录的区」**。
    ///
    /// ⚠️ 它**不保证**等于凭据里自带的 `serverId`（实测：同一个凭据跑过几次登录之后
    /// 这里会变成别的区）。所以它只能当「你上次玩的是哪个区」的提示，不能当凭据区服用。
    public let recommendedServerID: Int64?

    public init(roles: [GameRole], recommendedServerID: Int64?) {
        self.roles = roles
        self.recommendedServerID = recommendedServerID
    }

    public var isEmpty: Bool { roles.isEmpty }

    /// 标出哪个是当前区服。
    public func isCurrent(_ role: GameRole) -> Bool {
        guard let recommendedServerID else { return false }
        return role.serverID == recommendedServerID
    }
}
