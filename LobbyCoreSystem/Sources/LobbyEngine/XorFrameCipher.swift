import Foundation

// MARK: - 游戏私有协议的帧信封（`x` / `lx`）
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
// ⚠️ **`lx`（0x70 0x6C）＝ LZ4 帧 + 同一套头部掩码，本实现同样支持**（见 `openLX`）。
// 补它的理由：助手仓 `bonProtocol.js` 的默认解密器（passthrough）**自动识别
// lx / x / xtm**，盐场客户端用的正是 `getEnc("auto")`；战场快照又是全局最大的帧，
// 最可能走压缩信封。早先这里对 `lx` 直接抛，而盐场线的 `decode` 是
// `try? … else return nil` —— 表现就是「lx 帧被静默丢掉，连日志都没有」。
//
// ⚠️ 还剩 `xtm`（0x70 0x74）＝ 依赖全局 XXTEA，页面上没有这个符号，仍然明确报错；
// 认不出的前缀一律报错而不是猜着解——猜错的表现是「解出一堆乱码然后 BON 解析出
// null」，比直接报错难查得多。
public enum XorFrameCipher {
    public enum Error: Swift.Error, CustomStringConvertible {
        case tooShort(Int)
        case unsupportedScheme(String)
        /// `lx` 信封解出了 LZ4 帧但解压失败（掩码对了、负载坏了）。
        case decompression(Lz4Frame.Error)

        public var description: String {
            switch self {
            case .tooShort(let count):
                return "帧太短（\(count) 字节，至少要 5）"
            case .unsupportedScheme(let magic):
                return "不支持的帧信封：\(magic)（本实现处理 px / pl）"
            case .decompression(let error):
                return "lx 帧解压失败：\(error)"
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
            // `lx` = LZ4 帧 + 头部掩码。**不是可选项**：助手仓的默认解密器
            // （`bonProtocol.js` 的 passthrough）就自动识别 lx/x/xtm，盐场客户端
            // 用的正是 `getEnc("auto")`；战场快照这种大帧最可能走压缩信封。
            // 早先这里直接抛 → 盐场线 `decode` 拿到 nil 后静默返回，表现是
            // 「实时战况一直没有数据、连日志都没有」。现在走同一条解码路径。
            return try openLX(frame)
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

    // MARK: - `lx` 信封（LZ4 帧 + 头部掩码）
    //
    // 与 `px` 同一套头部掩码法，区别是负载本身是 LZ4 帧：
    //   密钥的 8 个 bit 藏在 [2][3] 的 bit6/4/2/0（低位在前），
    //   **只对前 min(100, len) 字节生效**、且**从尾部往头部** XOR，
    //   之后把前 4 字节还原成 LZ4 帧 magic（`04 22 4D 18`）再交给 `Lz4Frame`。
    //
    // 实现与助手仓 `bonProtocol.js` 的 `lx.decrypt` 逐行对齐（掩码范围、
    // XOR 方向、magic 还原位置都一致）。`open` 与 `.bin` 凭据解码共用这一份，
    // 避免两处实现各自漂移。
    public static func openLX(_ frame: Data) throws -> Data {
        var bytes = [UInt8](frame)
        guard bytes.count > 4 else {
            throw Error.unsupportedScheme("lx 只有 \(bytes.count) 字节")
        }
        let key = (((bytes[2] >> 6) & 1) << 7)
            | (((bytes[2] >> 4) & 1) << 6)
            | (((bytes[2] >> 2) & 1) << 5)
            | ((bytes[2] & 1) << 4)
            | (((bytes[3] >> 6) & 1) << 3)
            | (((bytes[3] >> 4) & 1) << 2)
            | (((bytes[3] >> 2) & 1) << 1)
            | (bytes[3] & 1)
        let limit = min(100, bytes.count)
        if limit > 2 {
            for index in stride(from: limit - 1, through: 2, by: -1) { bytes[index] ^= key }
        }
        bytes[0] = 0x04
        bytes[1] = 0x22
        bytes[2] = 0x4D
        bytes[3] = 0x18
        do {
            return try Lz4Frame.decompress(Data(bytes))
        } catch let error as Lz4Frame.Error {
            throw Error.decompression(error)
        }
    }

    /// 帧信封的可读名（诊断日志用；认不出就报首字节）。
    /// 不是「我们能否解开」的判断——`open` 才是。这里只服务于「这帧到底是什么」。
    public static func schemeName(_ frame: Data) -> String {
        guard frame.count >= 2, frame[frame.startIndex] == 0x70 else {
            return frame.isEmpty ? "空帧" : String(format: "非信封 0x%02x", frame[frame.startIndex])
        }
        switch frame[frame.startIndex + 1] {
        case 0x78: return "px"
        case 0x6C: return "pl(lx)"
        case 0x74: return "pt(xtm)"
        default: return String(format: "未知 0x70 0x%02x", frame[frame.startIndex + 1])
        }
    }

    /// 帧头前若干字节的 hex 预览（诊断日志用）。
    public static func hexPreview(_ frame: Data, limit: Int = 8) -> String {
        frame.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
