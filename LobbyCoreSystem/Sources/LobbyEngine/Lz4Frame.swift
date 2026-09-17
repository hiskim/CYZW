import Foundation

// MARK: - LZ4 帧（frame）解压
//
// 为什么需要它：`.bin` 凭据与游戏 `login_authuser` 的**请求体**在 `lx` 方案里包的是
// **LZ4 帧格式**——头部掩码还原之后前 4 字节是 `04 22 4D 18`，即小端 `0x184D2204`
// （LZ4 frame magic）。参考实现（lz4js 的 `decompressFrame`）走的也是这条。
//
// 只实现**解压**：宿主不需要压缩——改写后的凭据改用 `x` 信封（纯 XOR、无压缩），
// 服务端按首字节自动识别（实测有效）。少一半代码，也少一半出错面。
//
// ⚠️ 块校验和 / 内容校验和**只跳过、不校验**：它们是 XXH32，而这里的用途只是
// 「读出凭据明文」，不是完整性审计；真出问题时 BON 解码会先炸，报错更明确。
// 所以刻意不引 XXH32，避免为一条只读路径再添一个会漂移的实现。
public enum Lz4Frame {
    public enum Error: Swift.Error, CustomStringConvertible {
        case tooShort(Int)
        case badMagic(UInt32)
        case unsupportedVersion(UInt8)
        case badBlockSizeDescriptor(UInt8)
        case truncated(offset: Int, need: Int, total: Int)
        case badMatchOffset(offset: Int, produced: Int)

        public var description: String {
            switch self {
            case .tooShort(let count):
                return "LZ4 帧太短（\(count) 字节）"
            case .badMagic(let value):
                return String(format: "LZ4 帧 magic 不对（0x%08x，应为 0x184d2204）", value)
            case .unsupportedVersion(let descriptor):
                return String(format: "LZ4 帧版本位非法（FLG=0x%02x）", descriptor)
            case .badBlockSizeDescriptor(let value):
                return String(format: "LZ4 帧块尺寸描述非法（BD=0x%02x）", value)
            case .truncated(let offset, let need, let total):
                return "LZ4 帧截断：偏移 \(offset) 需要 \(need) 字节，总长 \(total)"
            case .badMatchOffset(let offset, let produced):
                return "LZ4 匹配偏移越界：offset=\(offset) 已产出 \(produced) 字节"
            }
        }
    }

    private static let magicNumber: UInt32 = 0x184D_2204
    /// 帧头 FLG 的版本位固定是 `01`（高 2 位）。
    private static let versionMask: UInt8 = 0xC0
    private static let versionValue: UInt8 = 0x40
    private static let flagBlockChecksum: UInt8 = 0x10
    private static let flagContentSize: UInt8 = 0x08
    private static let flagContentChecksum: UInt8 = 0x04
    private static let flagDictionaryID: UInt8 = 0x01
    /// 块头最高位 = 「本块未压缩，直接搬运」。
    private static let uncompressedBit: UInt32 = 0x8000_0000
    /// LZ4 的 minMatch：token 低 4 位记的是 `匹配长度 - 4`。
    private static let minMatch = 4
    /// 块上限（BD 码 7 = 4 MB，与参考实现一致）。只存不压时块越大头开销越小。
    private static let maxBlockSize = 4 * 1024 * 1024

    /// 帧头校验和（HC）的实现基础：与参考实现（lz4js `xxh32.js`）逐位对齐的 XXH32。
    ///
    /// ⚠️ 为什么必须真的算：**服务端会校验这个字节**。写成 0 的表现是
    /// `/login/authuser` 回一条 `error=指令解析错误`（HTTP 200、但拿不到 roleToken），
    /// 极难猜；实测把参考帧的 HC 原样抄过来立刻可用。
    /// 三向对照见 `.workbuddy/tools/ws-profile-probe/probe-lx-variants.mjs`。
    static func xxh32(_ bytes: [UInt8], seed: UInt32 = 0) -> UInt32 {
        let p1: UInt32 = 0x9E37_79B1
        let p2: UInt32 = 0x85EB_CA77
        let p3: UInt32 = 0xC2B2_AE3D
        let p4: UInt32 = 0x27D4_EB2F
        let p5: UInt32 = 0x1656_67B1

        func rotate(_ value: UInt32, _ bits: UInt32) -> UInt32 {
            (value << bits) | (value >> (32 - bits))
        }
        func mix(_ accumulator: UInt32, _ input: UInt32) -> UInt32 {
            rotate(accumulator &+ input &* p2, 13) &* p1
        }

        var index = 0
        var remaining = bytes.count
        var h: UInt32
        if remaining >= 16 {
            var lanes = (seed &+ p1 &+ p2, seed &+ p2, seed, seed &- p1)
            while remaining >= 16 {
                lanes.0 = mix(lanes.0, readUInt32(bytes, index))
                lanes.1 = mix(lanes.1, readUInt32(bytes, index + 4))
                lanes.2 = mix(lanes.2, readUInt32(bytes, index + 8))
                lanes.3 = mix(lanes.3, readUInt32(bytes, index + 12))
                index += 16
                remaining -= 16
            }
            h = rotate(lanes.0, 1) &+ rotate(lanes.1, 7)
                &+ rotate(lanes.2, 12) &+ rotate(lanes.3, 18)
                &+ UInt32(bytes.count)
        } else {
            h = seed &+ p5 &+ UInt32(bytes.count)
        }
        while remaining >= 4 {
            h = rotate(h &+ readUInt32(bytes, index) &* p3, 17) &* p4
            index += 4
            remaining -= 4
        }
        while remaining > 0 {
            h = rotate(h &+ UInt32(bytes[index]) &* p5, 11) &* p1
            index += 1
            remaining -= 1
        }
        h ^= h >> 15
        h = h &* p2
        h ^= h >> 13
        h = h &* p3
        h ^= h >> 16
        return h
    }

    /// 产出一个「只存不压」的 LZ4 帧。
    ///
    /// 为什么需要它：宿主有时要**自己造 `lx` 载荷**（`lx` = LZ4 帧 + 头部掩码），
    /// 而实现一个真正的 LZ4 压缩器既没必要又容易出错——帧格式本来就允许把块标记成
    /// 「未压缩」（块头最高位置 1），于是压缩这一步退化成「原样搬运 + 封帧」。
    ///
    /// ⚠️ 为什么非要 `lx`（而不是换成 `x`）：服务端的**响应编码跟随请求的
    /// `O4e-Encoding`**（实测：发 `lx` 就收回 `70 6c` 开头的响应，不发就收回裸 BON）。
    /// 而游戏的 HTTP 客户端把编码写死成 `lx`，拿到裸 BON 会解不开 —— 所以宿主喂给
    /// 游戏的认证响应必须是 `lx`，进而请求也必须声明 `lx`。
    ///
    /// FLG / BD 取值与参考实现的 `compressFrame` 对齐（BD 码 7 = 4 MB 块上限），
    /// 校验和按需真算（见 `xxh32`）。
    public static func storeFrame(_ plain: Data) -> Data {
        let flag: UInt8 = 0x40        // 版本 01；无块校验和 / 无 contentSize / 无字典
        let descriptor: UInt8 = 0x70  // 块上限 4 MB（码 7）
        var out = Data()
        out.append(contentsOf: [0x04, 0x22, 0x4D, 0x18])   // magic（小端 0x184D2204）
        out.append(flag)
        out.append(descriptor)
        out.append(UInt8((xxh32([flag, descriptor]) >> 8) & 0xFF))

        let bytes = [UInt8](plain)
        var offset = 0
        while offset < bytes.count {
            let size = min(maxBlockSize, bytes.count - offset)
            let header = UInt32(size) | uncompressedBit
            out.append(contentsOf: [
                UInt8(header & 0xFF), UInt8((header >> 8) & 0xFF),
                UInt8((header >> 16) & 0xFF), UInt8((header >> 24) & 0xFF),
            ])
            out.append(contentsOf: bytes[offset..<(offset + size)])
            offset += size
        }
        out.append(contentsOf: [0x00, 0x00, 0x00, 0x00])     // EndMark
        return out
    }

    /// 解一个完整的 LZ4 帧。
    public static func decompress(_ frame: Data) throws -> Data {
        let bytes = [UInt8](frame)
        guard bytes.count >= 7 else { throw Error.tooShort(bytes.count) }

        var index = 0
        let magic = readUInt32(bytes, index)
        index += 4
        guard magic == magicNumber else { throw Error.badMagic(magic) }

        let descriptor = bytes[index]
        index += 1
        guard descriptor & versionMask == versionValue else {
            throw Error.unsupportedVersion(descriptor)
        }
        let hasBlockChecksum = descriptor & flagBlockChecksum != 0
        let hasContentSize = descriptor & flagContentSize != 0
        let hasContentChecksum = descriptor & flagContentChecksum != 0
        let hasDictionaryID = descriptor & flagDictionaryID != 0

        let blockDescriptor = bytes[index]
        index += 1
        let blockSizeCode = (blockDescriptor >> 4) & 0x07
        // 4=64KB / 5=256KB / 6=1MB / 7=4MB。这里只做合法性判断——
        // 输出缓冲区是按需增长的，不依赖它，但明显非法的头要立刻报错。
        guard blockSizeCode >= 4, blockSizeCode <= 7 else {
            throw Error.badBlockSizeDescriptor(blockDescriptor)
        }

        if hasContentSize { index += 8 }
        if hasDictionaryID { index += 4 }
        index += 1 // 帧头校验和（XXH32 高字节），跳过

        var output = [UInt8]()
        output.reserveCapacity(max(bytes.count * 3, 64))
        while true {
            try require(bytes, offset: index, need: 4)
            let rawLength = readUInt32(bytes, index)
            index += 4
            if rawLength == 0 { break } // EndMark
            if hasBlockChecksum { index += 4 }

            let isUncompressed = rawLength & uncompressedBit != 0
            let blockLength = Int(rawLength & ~uncompressedBit)
            try require(bytes, offset: index, need: blockLength)
            if isUncompressed {
                output.append(contentsOf: bytes[index..<(index + blockLength)])
            } else {
                try inflateBlock(bytes, from: index, length: blockLength, into: &output)
            }
            index += blockLength
        }
        if hasContentChecksum { index += 4 }
        return Data(output)
    }

    // MARK: - 块解压

    /// 解一个压缩块，产出追加到 `output`。
    ///
    /// 逐字节搬运是**必须**的：LZ4 的匹配可以与前向重叠（`offset < matchLength`），
    /// 这是它表达 run 的方式。批量 `append(contentsOf:)` 会读到还没写出来的字节。
    private static func inflateBlock(_ source: [UInt8],
                                     from start: Int,
                                     length: Int,
                                     into output: inout [UInt8]) throws {
        let end = start + length
        var index = start
        while index < end {
            let token = source[index]
            index += 1

            var literalCount = Int(token >> 4)
            if literalCount == 15 {
                while true {
                    try require(source, offset: index, need: 1)
                    let extra = Int(source[index])
                    index += 1
                    literalCount += extra
                    if extra != 0xFF { break }
                }
            }
            try require(source, offset: index, need: literalCount)
            if literalCount > 0 {
                output.append(contentsOf: source[index..<(index + literalCount)])
                index += literalCount
            }
            // 末尾序列只有字面量，没有匹配段。
            if index >= end { break }

            try require(source, offset: index, need: 2)
            let matchOffset = Int(source[index]) | (Int(source[index + 1]) << 8)
            index += 2

            var matchLength = Int(token & 0x0F)
            if matchLength == 15 {
                while true {
                    try require(source, offset: index, need: 1)
                    let extra = Int(source[index])
                    index += 1
                    matchLength += extra
                    if extra != 0xFF { break }
                }
            }
            matchLength += minMatch

            guard matchOffset > 0, matchOffset <= output.count else {
                throw Error.badMatchOffset(offset: matchOffset, produced: output.count)
            }
            var readIndex = output.count - matchOffset
            for _ in 0..<matchLength {
                output.append(output[readIndex])
                readIndex += 1
            }
        }
    }

    // MARK: - 小工具

    private static func require(_ bytes: [UInt8], offset: Int, need: Int) throws {
        guard need >= 0, offset >= 0, offset + need <= bytes.count else {
            throw Error.truncated(offset: offset, need: need, total: bytes.count)
        }
    }

    /// 调用前必须已 `require` 过 4 字节。
    private static func readUInt32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        UInt32(bytes[index])
            | (UInt32(bytes[index + 1]) << 8)
            | (UInt32(bytes[index + 2]) << 16)
            | (UInt32(bytes[index + 3]) << 24)
    }
}
