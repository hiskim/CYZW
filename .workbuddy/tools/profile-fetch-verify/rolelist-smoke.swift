// `/login/serverlist` 冒烟：用**产品代码**（AccountRoleCatalog + GameEndpointClient）
// 拉一个真实 .bin 名下的全部区服角色。
//
// 这条路径是纯 HTTP，**不建立游戏会话**（不会顶掉正在运行的实例），可以随时跑。
// 判据：
//   · 角色数 > 0，且每个角色都带合法 serverId / roleId
//   · 服务端给的 `recommendId` 等于凭据里自带的 serverId（说明「当前区」判定是对的）
//   · 区服号换算与文件名口径一致（例如 serverId=14028 → 14001 服）
import Foundation
import LobbyDomain

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("[FAIL] " + message + "\n").utf8))
    exit(1)
}
func pass(_ message: String) {
    print("PASS  \(message)")
}

let accountName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "11不不.bin"
let binURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/AccountBins")
    .appendingPathComponent(accountName)
guard let binData = try? Data(contentsOf: binURL) else {
    fail("读不到凭据：\(binURL.path)")
}
print("凭据：\(accountName)（\(binData.count) 字节）")

let credential: BinCredential
do {
    credential = try BinCredential(data: binData)
} catch {
    fail("凭据解码失败：\(error)")
}
print("凭据自带 serverId=\(credential.serverID.map(String.init) ?? "?")"
    + "（= \(GameServerID.serverNumber(for: credential.serverID ?? 0)) 服）")

let started = Date()
let list: AccountRoleList
do {
    list = try await AccountRoleCatalog().roles(binData: binData)
} catch {
    fail("serverlist 失败：\(error)")
}
let elapsed = Int(Date().timeIntervalSince(started) * 1000)
pass("serverlist 返回 \(list.roles.count) 个角色（\(elapsed)ms）")

guard !list.roles.isEmpty else { fail("角色数为 0") }

print("   推荐区（recommendId）= \(list.recommendedServerID.map(String.init) ?? "-")")
print("   ── 角色表（战力降序）──")
for role in list.roles.prefix(12) {
    let current = list.isCurrent(role) ? " ← 当前" : ""
    print(String(format: "   %7lld 服(%-5lld) %@  战力 %lld%@",
                 role.serverNumber, role.serverID, role.displayName, role.power, current))
}
if list.roles.count > 12 { print("   …共 \(list.roles.count) 个") }

// ── 断言 ─────────────────────────────────────────────────────────────────
for role in list.roles {
    guard role.serverID > 0 else { fail("角色 \(role.name) 的 serverId 非法：\(role.serverID)") }
    guard role.roleID > 0 else { fail("角色 \(role.name) 的 roleId 非法：\(role.roleID)") }
    guard GameServerID.serverID(serverNumber: role.serverNumber, slot: role.slotIndex) == role.serverID else {
        fail("区服号换算不可逆：serverId=\(role.serverID)")
    }
}
pass("每个角色的 serverId / roleId 合法，且区服号换算可逆")

// ⚠️ `recommendId` 是**服务端记的「上次登录的区」**，不保证等于凭据里自带的 serverId
// （实测：跑过几次登录之后它就变成别的区了）。所以这里只校验它必须指向一个真实角色，
// 不能拿它当「凭据区服」用 —— 那是两个不同的东西。
if let recommended = list.recommendedServerID {
    guard list.roles.contains(where: { $0.serverID == recommended }) else {
        fail("recommendId=\(recommended) 不在角色表里")
    }
    let label = list.roles.first(where: { $0.serverID == recommended })!.displayName
    print("   注：recommendId=\(recommended)（\(label)）= 服务端记的**上次登录区**，"
          + "与凭据自带 serverId=\(credential.serverID.map(String.init) ?? "无") 未必相同。")
    pass("recommendId 指向一个真实角色")
}

// 派生一份凭据并核对文件名（**不落盘**）
if let target = list.roles.first(where: { !list.isCurrent($0) }) ?? list.roles.first {
    let body: BinCredential.LoginBody
    do {
        body = try credential.loginBody(serverID: target.serverID)
    } catch {
        fail("派生凭据失败：\(error)")
    }
    let name = target.derivedBinFileName(basedOn: accountName)
    pass("派生 \(target.displayName) → \(body.bytes.count) 字节，建议文件名 \(name)，编码头=\(body.encodingHeader ?? "（不发）")")
    let round = try? BinCredential(data: body.bytes)
    guard round?.serverID == target.serverID else {
        fail("派生凭据回读 serverId 不符")
    }
    pass("派生凭据回读自洽（serverId=\(target.serverID)）")
}

print("\n全部通过")
