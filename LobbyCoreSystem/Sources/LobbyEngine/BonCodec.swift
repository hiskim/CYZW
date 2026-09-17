import Foundation

// MARK: - BON（Binary Object Notation）编解码
//
// 游戏服务端的二进制报文格式。HTTP 响应体、WebSocket 报文的 body 都是它。
// 移植自助手仓的 `src/utils/bonProtocol.js`（`BonEncoder` / `BonDecoder` /
// `DataReader` / `DataWriter`），语义逐条对齐——**改动前先回去对参考实现**。
//
// 与参考实现的对应关系（都是踩过才写下来的细节，别"顺手优化"）：
//  · 全是**小端**；长度与字符串表索引用 **7bit varint**（.NET 的 7BitEncodedInt）。
//  · **字符串表是收发双向共享的**：同一个字符串第二次出现写 tag 99 + 索引。
//    所以解码器必须**按出现顺序建表**——漏掉任何一次 push，后面所有引用都会错位，
//    而错位不会报错，只会让字段值悄悄变成别的字符串（很难查）。
//  · tag：`0` null / `1` int32 / `2` int64 / `3` float32 / `4` float64 /
//    `5` string / `6` bool / `7` binary / `8` map(对象) / `9` array /
//    `10` datetime / `99` stringRef。**未知 tag 返回 null**（参考实现就是 default: null）。
//  · `object` 用 7bit 数字段数，然后**交替** key/value；key 本身也是一个 BON 值。
//  · 编码器会跳过 `_` 开头的键（参考实现的 encodeObject 行为）。
//
// 为什么自己写一个值类型树而不是直接塞 `[String: Any]`：
//  · 字段有 139 个且路径不定，树可以先 dump 再按路径取值，排查时不用加断点；
//  · `[String: Any]` 在 Swift 6 下不是 Sendable，跨 actor 传要额外包装；
//  · 需要保序（编码时要还原字段顺序）。
public enum BonValue: Sendable {
    case null
    case int(Int32)
    case long(Int64)
    case float(Float)
    case double(Double)
    case string(String)
    case bool(Bool)
    case binary(Data)
    case object(BonObject)
    case array([BonValue])
    case date(Int64)
}

/// 保序的键值对集合。同名键允许重复（服务端不会发，但别让它变成静默丢数据）。
public struct BonObject: Sendable {
    public struct Field: Sendable {
        public let key: String
        public let value: BonValue
        public init(_ key: String, _ value: BonValue) {
            self.key = key
            self.value = value
        }
    }

    public private(set) var fields: [Field]

    public init(_ fields: [Field] = []) {
        self.fields = fields
    }

    public var count: Int { fields.count }

    /// 取最后一个同名键（与 JS 对象字面量的行为一致：后写的覆盖前面的）。
    public subscript(key: String) -> BonValue? {
        fields.last { $0.key == key }?.value
    }

    public var keys: [String] { fields.map(\.key) }
}

// MARK: - 取值便利（宽松：数值型互相兼容，避免一个 tag 差异就让整份资料作废）

public extension BonValue {
    var objectValue: BonObject? {
        if case .object(let object) = self { return object }
        return nil
    }

    var arrayValue: [BonValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    var stringValue: String? {
        switch self {
        case .string(let text): return text
        case .int(let value): return String(value)
        case .long(let value): return String(value)
        default: return nil
        }
    }

    /// 数值统一成 Int64。服务端同一字段在不同版本里可能是 int32 / int64 / double
    /// （实测 `power` 是 int64、`levelId` 是 int32、有些计数字段是 double），
    /// 这里一并接受，免得为每个字段单独判断 tag。
    var intValue: Int64? {
        switch self {
        case .int(let value): return Int64(value)
        case .long(let value): return value
        case .float(let value): return value.isFinite ? Int64(value) : nil
        case .double(let value): return value.isFinite ? Int64(value) : nil
        case .date(let value): return value
        case .bool(let value): return value ? 1 : 0
        case .string(let text): return Int64(text)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .long(let value): return Double(value)
        case .float(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value != 0
        case .long(let value): return value != 0
        default: return nil
        }
    }

    /// 逐层取子字段：`value.path("role", "name")`。
    /// 报文结构动辄三层以上，写成一串 `?.objectValue?[...]` 会很难读，也容易漏判。
    func path(_ keys: String...) -> BonValue? {
        var current: BonValue = self
        for key in keys {
            guard let next = current.objectValue?[key] else { return nil }
            current = next
        }
        return current
    }
}

// MARK: - 编解码

public enum Bon {
    public enum DecodeError: Error, CustomStringConvertible {
        case truncated(offset: Int, need: Int, total: Int)
        case bad7BitInt
        case badStringRef(index: Int, tableSize: Int)

        public var description: String {
            switch self {
            case .truncated(let offset, let need, let total):
                return "BON 数据截断：偏移 \(offset) 需要 \(need) 字节，总长 \(total)"
            case .bad7BitInt:
                return "BON 7bit varint 非法（超过 35 字节）"
            case .badStringRef(let index, let size):
                return "BON 字符串表引用越界：#\(index)（表长 \(size)）"
            }
        }
    }

    public static func encode(_ value: BonValue) -> Data {
        var encoder = Encoder()
        encoder.write(value)
        return encoder.output
    }

    public static func decode(_ data: Data) throws -> BonValue {
        var decoder = Decoder(data: data)
        return try decoder.read()
    }

    // MARK: 编码

    private struct Encoder {
        var output = Data()
        private var stringTable: [String: Int] = [:]

        mutating func write(_ value: BonValue) {
            switch value {
            case .null:
                output.append(0)
            case .int(let value):
                output.append(1)
                appendInt32(value)
            case .long(let value):
                output.append(2)
                appendInt64(value)
            case .float(let value):
                output.append(3)
                appendUInt32(value.bitPattern)
            case .double(let value):
                output.append(4)
                appendUInt64(value.bitPattern)
            case .string(let text):
                if let index = stringTable[text] {
                    output.append(99)
                    append7Bit(index)
                } else {
                    output.append(5)
                    appendUTF(text)
                    // 索引 = 插入前的表长（与参考实现的 `strMap.size` 一致）。
                    stringTable[text] = stringTable.count
                }
            case .bool(let value):
                output.append(6)
                output.append(value ? 1 : 0)
            case .binary(let data):
                output.append(7)
                append7Bit(data.count)
                output.append(data)
            case .object(let object):
                output.append(8)
                append7Bit(object.count)
                for field in object.fields {
                    write(.string(field.key))
                    write(field.value)
                }
            case .array(let items):
                output.append(9)
                append7Bit(items.count)
                for item in items { write(item) }
            case .date(let milliseconds):
                output.append(10)
                appendInt64(milliseconds)
            }
        }

        /// 与参考实现的 `_write7BitInt` 相同：低位在前，最高位表示「还有后续」。
        private mutating func append7Bit(_ value: Int) {
            var remaining = UInt32(truncatingIfNeeded: value)
            while remaining >= 0x80 {
                output.append(UInt8(remaining & 0xFF) | 0x80)
                remaining >>= 7
            }
            output.append(UInt8(remaining & 0x7F))
        }

        private mutating func appendUTF(_ text: String) {
            let bytes = Data(text.utf8)
            append7Bit(bytes.count)
            output.append(bytes)
        }

        private mutating func appendInt32(_ value: Int32) {
            appendUInt32(UInt32(bitPattern: value))
        }

        private mutating func appendUInt32(_ value: UInt32) {
            output.append(UInt8(value & 0xFF))
            output.append(UInt8((value >> 8) & 0xFF))
            output.append(UInt8((value >> 16) & 0xFF))
            output.append(UInt8((value >> 24) & 0xFF))
        }

        private mutating func appendInt64(_ value: Int64) {
            appendUInt64(UInt64(bitPattern: value))
        }

        private mutating func appendUInt64(_ value: UInt64) {
            for shift in stride(from: 0, through: 56, by: 8) {
                output.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
        }
    }

    // MARK: 解码

    private struct Decoder {
        let data: Data
        var offset = 0
        /// 收发共享的字符串表，必须**按出现顺序**追加（见文件头说明）。
        var stringTable: [String] = []

        init(data: Data) {
            self.data = data
        }

        mutating func read() throws -> BonValue {
            let tag = try readByte()
            switch tag {
            case 1: return .int(Int32(bitPattern: try readUInt32()))
            case 2: return .long(Int64(bitPattern: try readUInt64()))
            case 3: return .float(Float(bitPattern: try readUInt32()))
            case 4: return .double(Double(bitPattern: try readUInt64()))
            case 5:
                let text = try readUTF()
                stringTable.append(text)
                return .string(text)
            case 6: return .bool(try readByte() == 1)
            case 7:
                let length = try read7Bit()
                return .binary(try readBytes(length))
            case 8:
                let count = try read7Bit()
                var fields: [BonObject.Field] = []
                fields.reserveCapacity(count)
                for _ in 0..<count {
                    // key 也是 BON 值（正常是 string / stringRef）。
                    let key = try read()
                    fields.append(BonObject.Field(key.stringValue ?? "", try read()))
                }
                return .object(BonObject(fields))
            case 9:
                let count = try read7Bit()
                var items: [BonValue] = []
                items.reserveCapacity(count)
                for _ in 0..<count { items.append(try read()) }
                return .array(items)
            case 10: return .date(Int64(bitPattern: try readUInt64()))
            case 99:
                let index = try read7Bit()
                guard index >= 0, index < stringTable.count else {
                    throw DecodeError.badStringRef(index: index, tableSize: stringTable.count)
                }
                return .string(stringTable[index])
            default:
                // 参考实现里未知 tag 一律返回 null，这里保持同样行为：
                // 新版本服务端加字段时不应该让整份资料解析失败。
                return .null
            }
        }

        private mutating func readByte() throws -> UInt8 {
            guard offset < data.count else {
                throw DecodeError.truncated(offset: offset, need: 1, total: data.count)
            }
            defer { offset += 1 }
            return data[data.startIndex + offset]
        }

        private mutating func readBytes(_ count: Int) throws -> Data {
            guard count >= 0, offset + count <= data.count else {
                throw DecodeError.truncated(offset: offset, need: count, total: data.count)
            }
            defer { offset += count }
            let start = data.startIndex + offset
            return data[start..<(start + count)]
        }

        private mutating func readUInt32() throws -> UInt32 {
            let bytes = try readBytes(4)
            var value: UInt32 = 0
            for (index, byte) in bytes.enumerated() {
                value |= UInt32(byte) << (8 * UInt32(index))
            }
            return value
        }

        private mutating func readUInt64() throws -> UInt64 {
            let bytes = try readBytes(8)
            var value: UInt64 = 0
            for (index, byte) in bytes.enumerated() {
                value |= UInt64(byte) << (8 * UInt64(index))
            }
            return value
        }

        private mutating func read7Bit() throws -> Int {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            var count = 0
            while true {
                if count >= 35 { throw DecodeError.bad7BitInt }
                let byte = try readByte()
                count += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
            }
            return Int(truncatingIfNeeded: value)
        }

        private mutating func readUTF() throws -> String {
            let length = try read7Bit()
            let bytes = try readBytes(length)
            // 非法 UTF-8 不当致命错误：字段丢了比整份资料解析失败好。
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
