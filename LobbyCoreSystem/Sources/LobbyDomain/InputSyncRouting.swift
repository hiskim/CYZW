import Foundation

// MARK: - 键鼠同步（群控）纯逻辑层
//
// 与上一代 MacInputSync.swift 的语义逐条对齐：
// - 坐标一律是 0...1 归一化比例（相对各自窗口 innerWidth/innerHeight），
//   主/子窗口尺寸不同也不会错位——这是不用 CGEvent/NSEvent 物理坐标模拟的关键；
// - 混合路由：🔗「参与同步」= 收件人 + 无主控时的发言人；👑「主控」一出现就把
//   「发」的权限收归独占；
// - 路由真值表抽成纯静态函数，可脱离 WebKit 单测。

/// 群控当前的工作模式。
public enum SyncMode: Equatable, Sendable {
    /// 没人参与同步（没有主控，参与者 < 2）。
    case idle
    /// 无主控：开启同步的窗口互相同步。
    case mutual
    /// 有主控：只有主控发号施令，子窗口静默。
    case masterDriven
}

/// 一个同步分组的运行时状态。分组成员来自账号库分组，参与名单只记当前会话。
public struct SyncGroupState: Equatable, Sendable {
    public let id: String
    public var masterAccountID: String?
    public var receiverAccountIDs: Set<String> = []

    public init(id: String, masterAccountID: String? = nil, receiverAccountIDs: Set<String> = []) {
        self.id = id
        self.masterAccountID = masterAccountID
        self.receiverAccountIDs = receiverAccountIDs
    }
}

/// 路由真值表（纯函数）。
public enum InputSyncRouting {
    /// 谁能发言：主控恒可发言；有主控时其它人一律静默；无主控时参与者才可发言。
    public static func canSend(master: String?, receivers: Set<String>, sender: String) -> Bool {
        if master == sender { return true }
        guard master == nil else { return false }
        return receivers.contains(sender)
    }

    /// 谁该捕获：主控恒捕获；有主控时其它人一律不捕获；无主控时参与者捕获。
    public static func shouldCapture(master: String?, receivers: Set<String>, account: String) -> Bool {
        if master == account { return true }
        guard master == nil else { return false }
        return receivers.contains(account)
    }

    /// 一次事件的回放目标 = 参与名单 − 发言者自己 − 本组主控。不允许发言时返回空集。
    public static func routingTargets(master: String?, receivers: Set<String>, sender: String) -> Set<String> {
        guard canSend(master: master, receivers: receivers, sender: sender) else { return [] }
        var targets = receivers
        targets.remove(sender)
        if let master { targets.remove(master) }
        return targets
    }
}

/// JS ↔ Swift 之间传递的中性输入事件（Codable 载荷，字段名与上一代注入脚本一致）。
public struct InputSyncEvent: Codable, Equatable, Sendable {
    /// 事件类型：mousedown / mouseup / mousemove / contextmenu / wheel / keydown / keyup
    public var t: String
    /// 归一化横坐标。
    public var x: Double?
    public var y: Double?
    public var button: Int?
    public var buttons: Int?
    /// 修饰键掩码：1 shift · 2 ctrl · 4 alt · 8 meta
    public var mods: Int?
    public var key: String?
    public var code: String?
    public var keyCode: Int?
    /// wheel 的滚动增量。
    public var dx: Double?
    public var dy: Double?
    public var isRepeat: Bool?

    public enum CodingKeys: String, CodingKey {
        case t, x, y, button, buttons, mods, key, code, keyCode, dx, dy
        case isRepeat = "repeat"
    }

    public init(t: String, x: Double? = nil, y: Double? = nil, button: Int? = nil, buttons: Int? = nil,
                mods: Int? = nil, key: String? = nil, code: String? = nil, keyCode: Int? = nil,
                dx: Double? = nil, dy: Double? = nil, isRepeat: Bool? = nil) {
        self.t = t
        self.x = x
        self.y = y
        self.button = button
        self.buttons = buttons
        self.mods = mods
        self.key = key
        self.code = code
        self.keyCode = keyCode
        self.dx = dx
        self.dy = dy
        self.isRepeat = isRepeat
    }

    public static let mouseDown = "mousedown"
    public static let mouseUp = "mouseup"
    public static let mouseMove = "mousemove"
    public static let contextMenu = "contextmenu"
    public static let wheel = "wheel"
    public static let keyDown = "keydown"
    public static let keyUp = "keyup"

    public var isMove: Bool { t == Self.mouseMove }

    /// 从 WebKit 消息体解码（消息体是 `{type:"input", input:{...}}`）。
    public static func decode(from body: [String: Any]) -> InputSyncEvent? {
        guard let payload = body["input"] as? [String: Any] else { return nil }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? JSONDecoder().decode(InputSyncEvent.self, from: data)
    }

    /// 编码成 JS 对象字面量（注入到子窗口回放）。
    public var javaScriptLiteral: String? {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }
}
