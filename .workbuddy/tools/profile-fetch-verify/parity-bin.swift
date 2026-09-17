// `.bin` 凭据对拍：编译**产品代码**（Lz4Frame / BinCredential / BonCodec / XorFrameCipher）
// 直接跑真实 .bin，产出明文与派生凭据供 check-bin-vectors.mjs 双向比对。
//
// 判据（BON 是静默失败的，所以「能跑通」不算数）：
//   · 明文与参考实现**逐字节**相同（sha256 比）
//   · 派生凭据能被参考实现解开，且字段与参考产的完全一致
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("[FAIL] " + message + "\n").utf8))
    exit(1)
}

let work = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func read(_ name: String) -> Data {
    guard let data = try? Data(contentsOf: work.appendingPathComponent(name)) else {
        fail("读不到 \(name)")
    }
    return data
}
func readText(_ name: String) -> String {
    String(decoding: read(name), as: UTF8.self)
}
func write(_ name: String, _ data: Data) {
    do {
        try data.write(to: work.appendingPathComponent(name))
    } catch {
        fail("写不出 \(name)：\(error)")
    }
}
func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// 归一化 dump：键排序，与 `make-bin-vectors.mjs` 的 `canon()` 同格式。
func canon(_ value: BonValue) -> String {
    switch value {
    case .null:
        return "null"
    case .int(let v):
        return String(v)
    case .long(let v):
        return String(v)
    case .float(let v):
        return v == v.rounded() ? String(Int64(v)) : String(Double(v))
    case .double(let v):
        return v == v.rounded() ? String(Int64(v)) : String(v)
    case .bool(let v):
        return v ? "true" : "false"
    case .string(let v):
        return "\"" + escape(v) + "\""
    case .binary(let data):
        return "<binary:\(data.count)>"
    case .object(let object):
        let fields = object.fields
            .sorted { $0.key < $1.key }
            .map { "\"" + escape($0.key) + "\":" + canon($0.value) }
        return "{" + fields.joined(separator: ",") + "}"
    case .array(let items):
        return "[" + items.map(canon).joined(separator: ",") + "]"
    case .date(let ms):
        return String(ms)
    }
}

func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

let raw = read("bin.raw")

// ── ① lx 解信封 + BON 解码 ────────────────────────────────────────────────
let credential: BinCredential
do {
    credential = try BinCredential(data: raw)
} catch {
    fail("BinCredential 解码失败：\(error)")
}

let opened: (bytes: Data, scheme: BinCredential.Scheme)
do {
    opened = try BinCredential.plaintext(of: raw)
} catch {
    fail("plaintext 失败：\(error)")
}
print("① 信封方案：\(opened.scheme.rawValue)  明文 \(opened.bytes.count) 字节  sha256=\(sha256(opened.bytes).prefix(16))")
write("swift-bin-plain.bin", opened.bytes)
write("swift-bin.ref.dump", Data((canon(.object(credential.payload)) + "\n").utf8))

guard let serverID = credential.serverID else {
    fail("凭据里没有 serverId（字段：\(credential.keys.joined(separator: ","))）")
}
print("② serverId=\(serverID)（= \(GameServerID.serverNumber(for: serverID)) 服 / 第 \(GameServerID.slotIndex(for: serverID)) 小号位）")
print("   字段顺序：\(credential.keys.joined(separator: ", "))")

// ── ② 换服改写 + 编码（供参考实现反向验证）────────────────────────────────
let targets = readText("bin.targets.txt")
    .split(separator: "\n")
    .compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
guard !targets.isEmpty else { fail("bin.targets.txt 是空的") }

for target in targets {
    let body: BinCredential.LoginBody
    do {
        body = try credential.loginBody(serverID: target)
    } catch {
        fail("loginBody(serverID: \(target)) 失败：\(error)")
    }
    print("③ 派生 serverId=\(target) → \(body.bytes.count) 字节  编码头=\(body.encodingHeader ?? "（不发）")")
    write("swift-derived-\(target).bin", body.bytes)

    // 自检：自己产的凭据自己要能解回来，且只有 serverId 变了。
    do {
        let round = try BinCredential(data: body.bytes)
        guard round.serverID == target else {
            fail("派生凭据回读 serverId=\(String(describing: round.serverID))，期望 \(target)")
        }
        let expected = canon(.object(credential.replacingServerID(target).payload))
        guard canon(.object(round.payload)) == expected else {
            fail("派生凭据回读的字段与期望不一致（serverId=\(target)）")
        }
    } catch {
        fail("派生凭据回读失败（serverId=\(target)）：\(error)")
    }
}

// ── ③ 反向互操作：参考实现产的凭据（**x 信封**）我们必须也能解 ─────────────
for target in targets {
    let referenceBin = read("bin-derived-\(target).bin")
    do {
        let decoded = try BinCredential(data: referenceBin)
        guard decoded.scheme == .x else {
            fail("参考实现的派生凭据信封判定不是 x，而是 \(decoded.scheme.rawValue)")
        }
        guard decoded.serverID == target else {
            fail("解参考实现的派生凭据得到 serverId=\(String(describing: decoded.serverID))，期望 \(target)")
        }
        print("③b 解参考实现的派生凭据 serverId=\(target) ✓（信封 \(decoded.scheme.rawValue)）")
    } catch {
        fail("解参考实现的派生凭据失败（serverId=\(target)）：\(error)")
    }
}

// ── ④ 直通路径必须与原始字节完全一致（零改写才最稳）────────────────────────
do {
    let passthrough = try credential.loginBody(serverID: credential.serverID)
    guard passthrough.bytes == raw else { fail("同区服直通时没有返回原始字节") }
    print("④ 同区服直通：原样返回 \(raw.count) 字节，编码头=\(passthrough.encodingHeader ?? "（不发）")")
    let nilPath = try credential.loginBody(serverID: nil)
    guard nilPath.bytes == raw else { fail("serverID=nil 时没有返回原始字节") }
} catch {
    fail("直通路径失败：\(error)")
}

// ── ⑤ 游戏的 login_authuser 请求体里能取出 serverId（登录代理的前提）────────
do {
    let gameBody = XorFrameCipher.seal(Bon.encode(.object(BonObject([
        .init("platform", .string("hortor")),
        .init("platformExt", .string("mix")),
        .init("info", .string("{}")),
        .init("serverId", .int(9365)),
        .init("scene", .int(0)),
        .init("referrerInfo", .string("")),
        .init("deviceUniqueId", .string("x")),
    ]))))
    guard let parsed = BinCredential.requestedServerID(inRequestBody: gameBody) else {
        fail("从游戏请求体里取不出 serverId")
    }
    guard parsed == 9365 else { fail("取出的 serverId=\(parsed)，期望 9365") }
    let envelope = (try? BinCredential.plaintext(of: gameBody).scheme) ?? .plain
    guard envelope == .x else { fail("游戏请求体的信封判定不是 x，而是 \(envelope.rawValue)") }
    print("⑤ 游戏请求体解析：serverId=\(parsed)  信封=\(envelope.rawValue)（登录代理可用）")
}

// ── ⑤ 区服编号口径 ────────────────────────────────────────────────────────
let mapping: [(Int64, Int64, Int)] = [(14028, 14001, 0), (1014028, 14001, 1), (2014028, 14001, 2)]
for (id, number, slot) in mapping {
    guard GameServerID.serverNumber(for: id) == number,
          GameServerID.slotIndex(for: id) == slot,
          GameServerID.serverID(serverNumber: number, slot: slot) == id else {
        fail("服务区编号口径不符或不可逆：\(id) → \(GameServerID.serverNumber(for: id))服/第\(GameServerID.slotIndex(for: id))位")
    }
}
print("⑥ 区服编号口径：14028/1014028/2014028 → 14001 服的第 0/1/2 位（可逆）")

print("Swift 侧对拍产物已写出。")
