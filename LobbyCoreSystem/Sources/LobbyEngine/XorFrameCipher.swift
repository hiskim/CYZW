import Foundation

// MARK: - 游戏私有协议的「x」帧信封
//
// 游戏 WebSocket 的收发帧都在 BON 明文外面套了这一层。移植自助手仓的
// `bonProtocol.js` 的 `x` 方案（`registry.set("x", x)`）。
//
// 格式（`px` = 0x70 0x78 开头）：
//
//   seal:   4 字节随机头 + 明文 → 整体与随机字节 r(2...249) 逐字节 XOR
//           → 令 [0]=0x70 [1]=0x78
//           → 把 r 的 8 个 bit 塞进 [2][3] 的 bit6/4/2/0（先与 0b10101010 清位）
//   open:   从 [2][3] 反解出 r → 下标 4 起 XOR 回去 → 丢弃前 4 字节
//
// ⚠️ **这不是加密，是混淆**：密钥就藏在报文的头 4 个字节里，任何能看到报文的人
// 都能还原。写在这里是为了说清「我们不是在实现密码学」，而不是暗示它安全。
//
// ⚠️ 另外两套方案在本路径上没有出现过（实测收发都是 `px`）：
//   · `lx`（0x70 0x6C）＝ lz4 压缩 + 头部掩码，需要 lz4js 那种 LZ4 块解压；
//   · `xtm`（0x70 0x74）＝ 依赖全局 XXTEA。
// 所以这里**只实现 x**，其它前缀一律明确报错，而不是猜着解——
// 猜错的表现是「解出一堆乱码然后 BON 解析出 null」，比直接报错难查得多。
public enum XorFrameCipher {
    public enum Error: Swift.Error, CustomStringConvertible {
        case tooShort(Int)
        case unsupportedScheme(String)

        public var description: String {
            switch self {
            case .tooShort(let count):
                return "帧太短（\(count) 字节，至少要 5）"
            case .unsupportedScheme(let magic):
                return "不支持的帧信封：\(magic)（本实现只处理 px）"
            }
        }
    }

    /// XOR 密钥的取值范围（与参考实现一致：2...249，避开 0/1/250+ 这些会退化的值）。
    private static let keyRange: ClosedRange<UInt8> = 2...249

    /// 加信封。`key` 传 nil 时随机取（正常路径）；测试里可固定以复现字节。
    static func seal(_ plain: Data, key: UInt8? = nil) -> Data {
        let r = key ?? UInt8.random(in: keyRange)
        var frame = Data(capacity: plain.count + 4)
        frame.append(contentsOf: (0..<4).map { _ in UInt8.random(in: 0...255) })
        frame.append(plain)
        for index in frame.indices { frame[index] ^= r }
        frame[frame.startIndex] = 0x70
        frame[frame.startIndex + 1] = 0x78
        // r 的高 4 位进 [2] 的 bit6/4/2/0，低 4 位进 [3] 的同名位。
        frame[frame.startIndex + 2] = (frame[frame.startIndex + 2] & 0b1010_1010)
            | (((r >> 7) & 1) << 6) | (((r >> 6) & 1) << 4)
            | (((r >> 5) & 1) << 2) | ((r >> 4) & 1)
        frame[frame.startIndex + 3] = (frame[frame.startIndex + 3] & 0b1010_1010)
            | (((r >> 3) & 1) << 6) | (((r >> 2) & 1) << 4)
            | (((r >> 1) & 1) << 2) | (r & 1)
        return frame
    }

    /// 去信封，返回 BON 明文。
    public static func open(_ frame: Data) throws -> Data {
        guard frame.count >= 5 else { throw Error.tooShort(frame.count) }
        let base = frame.startIndex
        guard frame[base] == 0x70 else {
            throw Error.unsupportedScheme(String(format: "0x%02x 开头", frame[base]))
        }
        switch frame[base + 1] {
        case 0x78:
            break
        case 0x6C:
            throw Error.unsupportedScheme("pl（lx / lz4 方案）")
        case 0x74:
            throw Error.unsupportedScheme("pt（xtm / XXTEA 方案）")
        default:
            throw Error.unsupportedScheme(String(format: "0x%02x 0x%02x",
                                                frame[base], frame[base + 1]))
        }
        let key = (((frame[base + 2] >> 6) & 1) << 7)
            | (((frame[base + 2] >> 4) & 1) << 6)
            | (((frame[base + 2] >> 2) & 1) << 5)
            | ((frame[base + 2] & 1) << 4)
            | (((frame[base + 3] >> 6) & 1) << 3)
            | (((frame[base + 3] >> 4) & 1) << 2)
            | (((frame[base + 3] >> 2) & 1) << 1)
            | (frame[base + 3] & 1)
        var plain = Data(capacity: frame.count - 4)
        for index in (base + 4)..<frame.endIndex { plain.append(frame[index] ^ key) }
        return plain
    }

    /// 是否是我们认识的信封（用于日志里区分「服务端改了协议」和「数据坏了」）。
    public static func isSealed(_ frame: Data) -> Bool {
        frame.count >= 2 && frame[frame.startIndex] == 0x70 && frame[frame.startIndex + 1] == 0x78
    }
}
