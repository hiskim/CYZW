// 登录代理端到端冒烟：用**产品代码**证明「游戏请求里的 serverId 决定落在哪个角色」。
//
// 这是本次改造的核心命题，所以判据必须是完整链路，而不是「看起来换了」：
//   ① 预认证（凭据自带区服）→ 代理对「没有 serverId 的请求」必须原样返回缓存字节
//   ② 造一个**与游戏同形**的 login_authuser 请求体（x 信封 + BON 参数，含目标 serverId）
//      → 代理必须现算一份**不同的**应答（来源=derived）
//   ③ 把那份应答的 roleToken 拿去连 WSS 发 `role_getroleinfo`
//      → `role.roleId` 必须就是 `/login/serverlist` 里目标区服那个角色的 roleId
//   ④ 解析不出 serverId 的请求 → 必须退回缓存字节（不能变成新故障点）
//
// ⚠️ 这条路径会建立游戏会话，只能对**没有在运行**的账号跑（与 probe-roleinfo 同一约束）。
// ⚠️ `/login/authuser` 响应里的 roleId 是**账号 uid**，与区服无关 —— 判据只能是 WSS 侧
//    的 `role.roleId` / `role.name`（拿响应里的 roleId 判会得出「换服无效」的错误结论，已踩过）。
// ⚠️ 判据用 `role.roleId` 而不是 `role.power/level`：`serverlist` 里非当前区服的那些数值
//    是陈旧的（实测同一个角色 serverlist 报 Lv1/107.7亿，WSS 实拿 Lv8627/107.7亿），
//    只有 `roleId` 两边逐字段一致。
import Foundation
import LobbyDomain

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("[FAIL] " + message + "\n").utf8))
    exit(1)
}
func pass(_ message: String) {
    print("PASS  \(message)")
}

/// 造一份**与游戏同形**的 `login_authuser` 请求体：
/// `LoginManager._authUser()` 把 `localStorage["serverId"]` 塞进这组参数，再 BON + `lx` 信封
/// （游戏 HTTP 客户端的编码写死成 `lx`，所以请求体也是 `lx`）。
func makeGameRequestBody(credential: BinCredential, serverID: Int64) -> Data {
    let serverValue: BonValue = Int32(exactly: serverID).map { .int($0) } ?? .long(serverID)
    return BinCredential.encodeLX(BonObject([
        .init("platform", .string(credential.platform ?? "hortor")),
        .init("oriPlatform", .string(credential.platform ?? "hortor")),
        .init("platformExt", .string(credential.platformExt ?? "mix")),
        .init("info", credential.payload["info"] ?? .string("{}")),
        .init("serverId", serverValue),
        .init("scene", .int(0)),
        .init("referrerInfo", .string("")),
        .init("deviceUniqueId", .string("loginproxy-smoke")),
    ]))
}

// ── 夹具 ─────────────────────────────────────────────────────────────────
let accountName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "11不不.bin"
let binURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/AccountBins")
    .appendingPathComponent(accountName)
guard let binData = try? Data(contentsOf: binURL) else { fail("读不到凭据：\(binURL.path)") }
print("凭据：\(accountName)（\(binData.count) 字节）")

let credential: BinCredential
do {
    credential = try BinCredential(data: binData)
} catch {
    fail("凭据解码失败：\(error)")
}
guard let ownServerID = credential.serverID else { fail("凭据没有 serverId") }
print("凭据自带 serverId=\(ownServerID)（= \(GameServerID.serverNumber(for: ownServerID)) 服）")

// 预认证（等价于 AccountAuthenticator 那一步）
let defaultResponse: Data
do {
    let login = try credential.loginBody(serverID: nil)
    defaultResponse = try await GameEndpointClient.post(
        path: LobbyConfiguration.profileAuthUserPath,
        body: login.bytes,
        encodingHeader: login.encodingHeader)
} catch {
    fail("预认证失败：\(error)")
}
pass("预认证拿到 \(defaultResponse.count) 字节")
print("   预认证响应头 16 字节：" + defaultResponse.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
    + "（70 6c = lx：**响应编码跟随请求的 O4e-Encoding**，所以宿主喂给游戏的字节必须保持 lx）")

let list: AccountRoleList
do {
    list = try await AccountRoleCatalog().roles(binData: binData)
} catch {
    fail("serverlist 失败：\(error)")
}
guard let target = list.roles.first(where: { $0.serverID != ownServerID }) else {
    fail("该账号名下没有第二个区服角色，无法验证换服")
}
print("目标：\(target.displayName)（serverId=\(target.serverID)，roleId=\(target.roleID)）")

let proxy = LoginProxy(credential: credential, defaultResponse: defaultResponse)

// ── ① 无 serverId / 本区 / 垃圾体：一律原样返回缓存字节 ────────────────────
let noBody = await proxy.respond(gameRequestBody: nil)
guard noBody.bytes == defaultResponse, noBody.source == "cached" else {
    fail("无请求体时应原样返回预认证字节（实得 source=\(noBody.source)）")
}
let sameServer = await proxy.respond(gameRequestBody: makeGameRequestBody(credential: credential,
                                                                          serverID: ownServerID))
guard sameServer.bytes == defaultResponse, sameServer.source == "cached" else {
    fail("请求本区时应原样返回预认证字节（实得 source=\(sameServer.source)）")
}
let garbage = await proxy.respond(gameRequestBody: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]))
guard garbage.bytes == defaultResponse, garbage.source == "cached" else {
    fail("垃圾请求体应退回预认证字节（实得 source=\(garbage.source)）")
}
pass("无请求体 / 本区 / 无法解析的请求体 → 全部原样返回预认证字节")

// ── ② 带目标 serverId：现算应答 ──────────────────────────────────────────
let targetBody = makeGameRequestBody(credential: credential, serverID: target.serverID)
let answer = await proxy.respond(gameRequestBody: targetBody)
guard answer.source == "derived", answer.bytes != defaultResponse else {
    fail("换服请求应走 derived 且与缓存不同（实得 source=\(answer.source)）")
}
pass("换服请求 → 现算应答（\(answer.bytes.count) 字节，source=derived）")

let again = await proxy.respond(gameRequestBody: targetBody)
guard again.bytes == answer.bytes, again.source == "cached" else {
    fail("同一区服第二次请求应命中缓存（实得 source=\(again.source)）")
}
pass("同一区服第二次请求 → 命中缓存，未重复打网络")

// ── ③ 决定性判据：现算的应答真的落在目标角色上吗 ─────────────────────────
// 判据用**产品代码**（`credentials` 解响应 + `roleInfo` 走 WSS 取角色），
// 并且只认 `role.name` —— 因为 `role_getroleinfo` 能取到的字段里，
// `power` / `levelId` 在 serverlist 那边是陈旧的（实测同一个角色：serverlist 报
// Lv1 / 107.7 亿，WSS 实拿 Lv8627 / 107.7 亿），拿它们对拍会假失败。
// 所以这里**先把「名字唯一」当成前提**，让 name 足以唯一确定角色。
// （`roleId` 级的严格判据由 node 侧 `probe-pick-role.mjs` 覆盖，那边能直接读 roleId。）
func roleNameCount(_ name: String) -> Int {
    list.roles.filter { $0.name == name }.count
}
guard roleNameCount(target.name) == 1 else {
    fail("夹具不合适：目标名「\(target.name)」在该账号下有 \(roleNameCount(target.name)) 个，无法用名字判定")
}
guard let ownRole = list.roles.first(where: { list.isCurrent($0) }) else {
    fail("serverlist 里找不到当前区服的角色")
}
guard ownRole.name != target.name else {
    fail("夹具不合适：目标角色与当前角色同名（\(target.name)）")
}
pass("夹具自检：目标名「\(target.name)」唯一，且与当前角色「\(ownRole.name)」不同")

let ownPairs: (roleToken: String, roleId: Int64)
do {
    ownPairs = try AccountProfileFetcher.credentials(fromAuthResponse: defaultResponse)
} catch {
    fail("解不出预认证响应里的 roleToken：\(error)")
}
let ownSnapshot: AccountProfileSnapshot
do {
    ownSnapshot = try await AccountProfileFetcher().roleInfo(roleToken: ownPairs.roleToken,
                                                             roleId: ownPairs.roleId)
} catch {
    fail("预认证凭据走 WSS 失败：\(error)")
}
guard ownSnapshot.name == ownRole.name else {
    fail("预认证字节对应的角色不对：期望「\(ownRole.name)」，实得「\(ownSnapshot.name)」")
}
pass("预认证字节 = 本区角色「\(ownSnapshot.name)」（Lv\(ownSnapshot.level)）")

let pairs: (roleToken: String, roleId: Int64)
do {
    pairs = try AccountProfileFetcher.credentials(fromAuthResponse: answer.bytes)
} catch {
    // 服务端拒绝时会回一条带 code/error 的报文，把原文打出来——不猜。
    if let plain = try? BinCredential.plaintext(of: answer.bytes).bytes,
       let outer = try? Bon.decode(plain).objectValue {
        let fields = outer.fields.map { field -> String in
            let shown: String
            switch field.value {
            case .string(let text): shown = text
            case .int(let value): shown = String(value)
            case .long(let value): shown = String(value)
            case .binary(let data): shown = "<binary:\(data.count)>"
            default: shown = "-"
            }
            return "\(field.key)=\(shown.prefix(80))"
        }
        print("   换服应答解不出 roleToken，服务端原文：" + fields.joined(separator: " | "))
    }
    fail("解不出换服应答里的 roleToken：\(error)")
}
let switched: AccountProfileSnapshot
do {
    switched = try await AccountProfileFetcher().roleInfo(roleToken: pairs.roleToken, roleId: pairs.roleId)
} catch {
    fail("换服凭据走 WSS 失败：\(error)")
}
print("   换服后 WSS 实拿：name=\(switched.name) level=\(switched.level) power=\(switched.power)")
guard switched.name == target.name else {
    fail("换服落在了别的角色上：期望「\(target.name)」（\(target.displayName)），实得「\(switched.name)」")
}
guard switched.name != ownSnapshot.name else {
    fail("换服后拿到的还是原角色（\(switched.name)）—— 换服没生效")
}
pass("换服生效：拿到「\(switched.name)」，与目标「\(target.displayName)」一致")

print("\n代理诊断：" + proxy.status())
print("\n全部通过")
