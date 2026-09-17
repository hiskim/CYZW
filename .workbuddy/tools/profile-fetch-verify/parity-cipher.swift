// 帧信封（x 方案）的对拍：
//   ① open(服务端真实信封) == 服务端明文       —— 解密封面对真实数据
//   ② open(seal(明文, key: k)) == 明文          —— 加/解互为逆运算（多组 key）
//   ③ 用固定 key 封一帧写到磁盘，交给 Node 侧用参考实现解 —— 真正的互操作
import Foundation

var failures = 0
var checks = 0
func check(_ name: String, _ pass: Bool, _ detail: String = "") {
    checks += 1
    if !pass { failures += 1 }
    print("\(pass ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  → " + detail)")
}

let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/")
func read(_ name: String) -> Data? { try? Data(contentsOf: dir.appendingPathComponent(name)) }

// ① 真实信封
if let envelope = read("roleinfo-envelope.bin"), let expected = read("roleinfo.bin") {
    do {
        let plain = try XorFrameCipher.open(envelope)
        check("① 解开服务端真实信封", plain == expected,
              plain == expected ? "\(plain.count) 字节" : "长度 \(plain.count) vs \(expected.count)")
    } catch {
        check("① 解开服务端真实信封", false, String(describing: error))
    }
} else {
    check("① 向量读取", false, "先跑 make-vectors.mjs")
}

// ② 自封自解（遍历若干 key，含边界值）
let payload = Data("BON 假明文 —— hello".utf8)
var roundTripOK = true
var roundTripDetail = ""
for key in [UInt8(2), 7, 128, 200, 249] {
    let sealed = XorFrameCipher.seal(payload, key: key)
    let opened = (try? XorFrameCipher.open(sealed)) ?? Data()
    if opened != payload {
        roundTripOK = false
        roundTripDetail = "key=\(key) 失败"
        break
    }
    if !XorFrameCipher.isSealed(sealed) {
        roundTripOK = false
        roundTripDetail = "key=\(key) 封出来的头不是 px"
        break
    }
}
check("② 自封自解（key 2/7/128/200/249）", roundTripOK, roundTripDetail)

// ③ 写一帧固定 key 的给 Node 侧解（互操作）
if let plainForNode = read("roleinfo.bin") {
    let sealed = XorFrameCipher.seal(plainForNode, key: 0x5A)
    try? sealed.write(to: dir.appendingPathComponent("sealed-by-swift.bin"))
    check("③ 已写出 sealed-by-swift.bin", sealed.count == plainForNode.count + 4,
          "\(sealed.count) 字节，key=0x5A")
} else {
    check("③ 向量读取", false, "缺 roleinfo.bin")
}

// ④ 拒绝不认识的信封：给出明确错误而不是解出乱码
var rejected: [String] = []
for (name, bytes) in [("pl", [UInt8(0x70), 0x6C, 0x11, 0x22, 0x33]),
                      ("pt", [UInt8(0x70), 0x74, 0x11, 0x22, 0x33]),
                      ("未知", [UInt8(0x08), 0x05, 0x03, 0x73, 0x65]),
                      ("太短", [UInt8(0x70), 0x78])] {
    do {
        _ = try XorFrameCipher.open(Data(bytes))
        rejected.append("\(name) 竟然没报错")
    } catch {
        // 期望就是抛错
    }
}
check("④ 不认识的信封一律明确报错", rejected.isEmpty, rejected.joined(separator: "; "))

print("\n\(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
