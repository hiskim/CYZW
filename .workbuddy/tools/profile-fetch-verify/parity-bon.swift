// BON 编解码器的字节级对拍：拿助手仓的参考实现当基准。
//
// 产物与参考实现**逐字符/逐字节**比较：
//   ① authuser.bin        解码 → authuser.ref.dump
//   ② roleinfo.bin        解码外层 → roleinfo.ref.dump
//   ③ 外层.body           再解码内层 → roleinfo-inner.ref.dump
//   ④ 固定参数报文        编码 → request.ref.hex
//
// 规范化的口径必须与 make-vectors.mjs 的 `canon()` 完全一致：
//   · 键排序；字符串按 JSON.stringify 的转义规则；
//   · 整数不带小数点（含「整数取值的浮点」，对齐 JS 的 Number.isInteger 判断）；
//   · 非整数浮点固定 6 位；二进制打 <binary:N>；
//   · datetime 在 JS 里是 Date 对象、canon 后是 `{}` —— 这里也照打 `{}`。
import Foundation

var failures = 0
var checks = 0
func check(_ name: String, _ pass: Bool, _ detail: String = "") {
    checks += 1
    if !pass { failures += 1 }
    print("\(pass ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  → " + detail)")
}

func jsonEscaped(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}

func integralText(_ value: Double) -> String {
    // 对齐 JS：Number.isInteger 为真就打整数，否则固定 6 位小数。
    if value.rounded() == value, abs(value) < 1e18 {
        return String(Int64(value))
    }
    return String(format: "%.6f", value)
}

func canon(_ value: BonValue) -> String {
    switch value {
    case .null:
        return "null"
    case .int(let number):
        return String(number)
    case .long(let number):
        return String(number)
    case .float(let number):
        return integralText(Double(number))
    case .double(let number):
        return integralText(number)
    case .string(let text):
        return jsonEscaped(text)
    case .bool(let flag):
        return flag ? "true" : "false"
    case .binary(let data):
        return "<binary:\(data.count)>"
    case .array(let items):
        return "[" + items.map(canon).joined(separator: ",") + "]"
    case .object(let object):
        let sorted = object.fields.sorted { $0.key < $1.key }
        return "{" + sorted.map { jsonEscaped($0.key) + ":" + canon($0.value) }.joined(separator: ",") + "}"
    case .date:
        // 参考实现里 tag 10 返回 JS Date，canon() 看到的是「无自有可枚举键的对象」→ `{}`
        return "{}"
    }
}

func read(_ name: String) -> Data? {
    try? Data(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/" + name))
}

func text(_ name: String) -> String? {
    read(name).map { String(decoding: $0, as: UTF8.self) }
}

func compareDump(_ vector: String, _ actual: String) {
    guard let raw = text(vector) else {
        check("\(vector) 读取", false, "找不到基准文件")
        return
    }
    // 基准文件是 `canon(...) + "\n"` 写出来的，比较前去掉尾换行
    let expected = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
    if expected == actual {
        check("\(vector) 逐字符一致", true, "\(actual.count) 字符")
        return
    }
    // 找出第一个不一致的位置，否则一行 19 万字符的 diff 没法看
    let lhs = Array(expected), rhs = Array(actual)
    var index = 0
    while index < lhs.count, index < rhs.count, lhs[index] == rhs[index] { index += 1 }
    let pad = max(0, index - 40)
    let tail = { (chars: [Character]) -> String in
        String(chars[min(chars.count, pad)..<min(chars.count, pad + 120)])
    }
    check("\(vector) 逐字符一致", false,
          "首个差异在第 \(index) 字符\n      参考: …\(tail(lhs))\n      本实现: …\(tail(rhs))")
}

// ① authuser 响应
// 注意比对的是**内层 body**：参考实现 `g_utils.parse(raw).getData()` 取的是
// `bon.decode(outer.body)`，不是外层报文。
if let data = read("authuser.bin") {
    do {
        let outer = try Bon.decode(data)
        if case .binary(let body)? = outer.objectValue?["body"] {
            compareDump("authuser.ref.dump", canon(try Bon.decode(body)))
        } else {
            check("authuser 外层 body 是 binary", false, "取不到 body")
        }
    } catch {
        check("authuser.bin 解码", false, String(describing: error))
    }
} else {
    check("authuser.bin 读取", false, "先跑 make-vectors.mjs")
}

// ②③ WSS 响应（外层 + 内层）
if let data = read("roleinfo.bin") {
    do {
        let outer = try Bon.decode(data)
        compareDump("roleinfo.ref.dump", canon(outer))
        if case .binary(let body)? = outer.objectValue?["body"] {
            compareDump("roleinfo-inner.ref.dump", canon(try Bon.decode(body)))
        } else {
            check("外层 body 是 binary", false, "取不到 body")
        }
    } catch {
        check("roleinfo.bin 解码", false, String(describing: error))
    }
} else {
    check("roleinfo.bin 读取", false, "先跑 make-vectors.mjs")
}

// ④ 编码：固定参数的外层报文，应当逐字节等于参考实现
let requestBody = Bon.encode(.object(BonObject([
    .init("clientVersion", .string("2.10.3-f10a39eaa0c409f4-wx")),
    .init("inviteUid", .int(0)),
    .init("platform", .string("hortor")),
    .init("platformExt", .string("mix")),
    .init("scene", .string("")),
])))
let request = Bon.encode(.object(BonObject([
    .init("cmd", .string("role_getroleinfo")),
    .init("ack", .int(0)),
    .init("seq", .int(1)),
    .init("time", .long(1_758_000_000_000)),
    .init("body", .binary(requestBody)),
])))
let hex = request.map { String(format: "%02x", $0) }.joined()
if let expected = text("request.ref.hex")?.trimmingCharacters(in: .whitespacesAndNewlines) {
    check("request.ref.hex 逐字节一致", expected == hex,
          expected == hex ? "\(request.count) 字节" : "\n      参考: \(expected)\n      本实现: \(hex)")
} else {
    check("request.ref.hex 读取", false, "先跑 make-vectors.mjs")
}

print("\n\(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
