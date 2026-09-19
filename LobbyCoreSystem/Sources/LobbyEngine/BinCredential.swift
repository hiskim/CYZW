import Foundation
import LobbyDomain

// MARK: - `.bin` 凭据的编解码与换服改写
//
// 实测（2026-09-17，见仓库根 `BIN登录认证优化方案.md` §2.1）：
//
//   `.bin` 明文**就是一次 `login_authuser` 的请求参数对象**：
//     { platform: "hortor", platformExt: "mix", info: <encryptCombUser>,
//       serverId: 14028, scene: 0, referrerInfo: "" }
//
//   · `serverId` 决定落在哪个区服的角色：区服号 = `serverId - 27`，
//     `>= 1_000_000 / 2_000_000` 表示第 1 / 2 个小号位（口径与助手仓一致）；
//   · 外层信封是 `lx`（`70 6c`）= **LZ4 帧 + 头部掩码**，见 `Lz4Frame`。
//
// ⚠️ **只改 `serverId` 就能换服**（实测 4/5 逐字段命中目标角色），
// 但**绝不能**顺手把 `info` 重新序列化：实测 `.bin` 里 `info` 存在
// 「BON 对象」与「JSON 字符串」两种形态，统一成字符串会改变凭据语义。
// 所以这里的改写是**逐字段原样搬运**，只置换目标字段。
//
// ⚠️ 实测的另一个坑：`/login/authuser` 响应里的 `roleId` 是**账号 uid**，
// 与区服无关（同账号恒为同一个值）。判「换服是否生效」只能看 WSS
// `role_getroleinfo` 的 `role.name` / `role.roleId`——拿响应里的 `roleId` 判会得出
// 「服务端忽略 serverId」的完全错误结论。
public struct BinCredential: Sendable {
    /// 外层信封方案。
    public enum Scheme: String, Sendable {
        /// `70 6c`：LZ4 帧 + 头部掩码（`.bin` 的实际形态）。
        case lx
        /// `70 78`：4 字节随机头 + 单字节 XOR（游戏 HTTP/WS 请求体的形态）。
        case x
        /// 没有信封，直接就是 BON（防御性分支，正常不会遇到）。
        case plain

        /// 用于 `O4e-Encoding` 的值。
        ///
        /// ⚠️ 只有 `lx` 有确定的值。`x` / `plain` 一律**不发这个头**：
        /// 「`x` 体 + `lx` 头」会被服务端拒（实测无 roleToken），
        /// 而不发头时服务端按首字节自动识别（实测两类体都能过）。
        var encodingHeader: String? {
            self == .lx ? LobbyConfiguration.payloadEncodingLX : nil
        }
    }

    /// 一次登录要发出去的东西：字节 + 与之匹配的编码标记头。
    public struct LoginBody: Sendable {
        public let bytes: Data
        /// nil = 不发 `O4e-Encoding` 头。
        public let encodingHeader: String?
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case unsupportedEnvelope(String)
        case compression(Lz4Frame.Error)
        case notAnObject(tag: String, keys: [String])
        case missingServerID(keys: [String])

        public var description: String {
            switch self {
            case .unsupportedEnvelope(let detail):
                return "不认识的凭据信封：\(detail)"
            case .compression(let error):
                return "凭据解压失败：\(error)"
            case .notAnObject(let tag, let keys):
                return "凭据明文不是对象（首 tag=\(tag)，字段：\(keys.joined(separator: ","))）"
            case .missingServerID(let keys):
                return "凭据里没有 serverId（字段：\(keys.joined(separator: ","))）"
            }
        }
    }

    /// 明文对象（**保序**，改写时按原顺序搬运）。
    public let payload: BonObject
    /// 原始字节（直通路径原样使用）。
    public let original: Data
    public let scheme: Scheme

    // MARK: - 解码

    public init(data: Data) throws {
        let opened = try Self.plaintext(of: data)
        let value = try Bon.decode(opened.bytes)
        guard let object = value.objectValue else {
            throw Error.notAnObject(tag: Self.tagName(value), keys: [])
        }
        self.payload = object
        self.original = data
        self.scheme = opened.scheme
    }

    private init(payload: BonObject, original: Data, scheme: Scheme) {
        self.payload = payload
        self.original = original
        self.scheme = scheme
    }

    /// 剥信封，拿到 BON 明文。
    public static func plaintext(of data: Data) throws -> (bytes: Data, scheme: Scheme) {
        guard data.count >= 2 else {
            throw Error.unsupportedEnvelope("只有 \(data.count) 字节")
        }
        let first = data[data.startIndex]
        let second = data[data.startIndex + 1]
        if first == 0x70, second == 0x6C {
            do {
                return (try XorFrameCipher.openLX(data), .lx)
            } catch let error as Lz4Frame.Error {
                throw Error.compression(error)
            } catch let error as XorFrameCipher.Error {
                throw Error.unsupportedEnvelope(error.description)
            }
        }
        if first == 0x70, second == 0x78 {
            // XorFrameCipher 只认 px，这里已经判过前缀，直接转抛即可。
            return (try XorFrameCipher.open(data), .x)
        }
        return (data, .plain)
    }

    // MARK: - 读字段

    public var serverID: Int64? { payload["serverId"]?.intValue }
    public var platform: String? { payload["platform"]?.stringValue }
    public var platformExt: String? { payload["platformExt"]?.stringValue }

    public var keys: [String] { payload.keys }

    // MARK: - 改写 / 编码

    /// 只置换 `serverId`（原位替换，保持字段顺序；缺字段才追加）。
    /// 其它字段——尤其是 `info`——逐字原样搬运。
    public func replacingServerID(_ serverID: Int64) -> BinCredential {
        var fields = payload.fields
        if let index = fields.lastIndex(where: { $0.key == "serverId" }) {
            fields[index] = BonObject.Field("serverId",
                                            Self.number(serverID, matching: fields[index].value))
        } else {
            fields.append(BonObject.Field("serverId", .long(serverID)))
        }
        return BinCredential(payload: BonObject(fields), original: original, scheme: scheme)
    }

    /// 取「登录要用的一次请求体」。
    ///
    /// - `serverID` 为 nil 或与凭据自带的相同 → **原始字节直通**（零改写，最稳）。
    /// - 否则 → 改写后按 **`lx`** 重新编码（LZ4 帧用「只存不压」实现，见
    ///   `Lz4Frame.storeFrame`），并继续声明 `O4e-Encoding: lx`。
    ///
    /// ⚠️ 改写后**必须**保持 `lx`：服务端的响应编码跟随请求的这个头，而游戏是按
    /// `lx` 解响应的。换成 `x` 会让游戏收到解不开的字节（实测踩过这个坑）。
    public func loginBody(serverID: Int64?) throws -> LoginBody {
        guard let serverID, serverID != self.serverID else {
            return LoginBody(bytes: original, encodingHeader: scheme.encodingHeader)
        }
        return LoginBody(bytes: try derivedBinData(serverID: serverID),
                         encodingHeader: Self.Scheme.lx.encodingHeader)
    }

    /// 派生一份可**落盘**的 `.bin`（换服后的完整凭据文件）。
    ///
    /// 落盘后它就是一份普通凭据：账号 ID（= 内容 SHA256）与原始 `.bin` 天然不同，
    /// 于是实例、`WKWebsiteDataStore`、localStorage、头像、分组全部自动隔离，
    /// **存储层一行都不用改**。
    public func derivedBinData(serverID: Int64) throws -> Data {
        let derived = replacingServerID(serverID)
        return Self.encodeLX(derived.payload)
    }

    /// 用 `lx` 方案编码一个 BON 对象（BON → LZ4 帧 → 头部掩码）。
    ///
    /// 与参考实现 `lx.encrypt` 逐位对齐：掩码**从 `min(100,len)-1` 一路异或到 0**
    /// （解密只从 `min(100,len)-1` 到 2，因为 `[0][1]` 会被重新写成 magic、
    /// `[2][3]` 的掩码位要先清掉再塞密钥）。
    public static func encodeLX(_ object: BonObject) -> Data {
        var frame = [UInt8](Lz4Frame.storeFrame(Bon.encode(.object(object))))
        guard frame.count > 4 else { return Data(frame) }
        let key = UInt8.random(in: 2...249)
        for index in stride(from: min(100, frame.count) - 1, through: 0, by: -1) {
            frame[index] ^= key
        }
        frame[0] = 0x70
        frame[1] = 0x6C
        frame[2] = (frame[2] & 0b1010_1010)
            | (((key >> 7) & 1) << 6) | (((key >> 6) & 1) << 4)
            | (((key >> 5) & 1) << 2) | ((key >> 4) & 1)
        frame[3] = (frame[3] & 0b1010_1010)
            | (((key >> 3) & 1) << 6) | (((key >> 2) & 1) << 4)
            | (((key >> 1) & 1) << 2) | (key & 1)
        return Data(frame)
    }

    /// 从**游戏的** `login_authuser` 请求体里取它想要的 `serverId`。
    ///
    /// 游戏（`LoginManager._authUser`）会把 `localStorage["serverId"]` 塞进参数里，
    /// 所以「换服」这件事在字节层面是可观测的：只要拿到请求体就知道它想去哪个区。
    /// 解不出来返回 nil（调用方回退到凭据自带的区服）。
    public static func requestedServerID(inRequestBody body: Data) -> Int64? {
        guard body.count >= 2,
              let opened = try? plaintext(of: body),
              let value = try? Bon.decode(opened.bytes) else { return nil }
        return value.objectValue?["serverId"]?.intValue
    }

    // MARK: - 小工具

    /// 与目标字段原有的数值 tag 保持一致：原来存的是 int32 就继续写 int32。
    /// 换标签（int32 ↔ int64）服务端未必不接受，但没有理由去试。
    private static func number(_ value: Int64, matching existing: BonValue) -> BonValue {
        switch existing {
        case .int:
            if let narrowed = Int32(exactly: value) { return .int(narrowed) }
            return .long(value)
        case .long:
            return .long(value)
        case .double:
            return .double(Double(value))
        case .string:
            return .string(String(value))
        default:
            return .long(value)
        }
    }

    private static func tagName(_ value: BonValue) -> String {
        switch value {
        case .null: return "null"
        case .int: return "int32"
        case .long: return "int64"
        case .float: return "float32"
        case .double: return "float64"
        case .string: return "string"
        case .bool: return "bool"
        case .binary(let data): return "binary(\(data.count))"
        case .object: return "object"
        case .array: return "array"
        case .date: return "datetime"
        }
    }
}
