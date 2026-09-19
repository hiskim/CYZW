import Foundation
import LobbyDomain

// MARK: - 页面 → 原生事件契约（强类型解码）
//
// WebRuntime 页面通过 `window.webkit.messageHandlers.<webChannelName>.postMessage`
// 上报事件；消息体是 `[String: Any]`，这里统一解码成强类型枚举，
// 引擎层与表现层永不直接接触裸字典。

/// 渲染完整性采样（WebRuntime 每 12s 一次自检上报）。
/// Cocos 对「画不出来」是静默跳过的，只能靠引擎侧自检告诉我们缺了多少。
public struct RenderHealthSample: Sendable {
    public let missingTexture: Int
    public let missingMaterial: Int
    public let visible: Int
    public let contextLost: Bool
    public let reason: String

    public var missingCount: Int { missingTexture + missingMaterial }

    public init(missingTexture: Int, missingMaterial: Int, visible: Int, contextLost: Bool, reason: String) {
        self.missingTexture = missingTexture
        self.missingMaterial = missingMaterial
        self.visible = visible
        self.contextLost = contextLost
        self.reason = reason
    }
}

/// 实例启动沉降报告（场景加载完成、资源不再变动）。
public struct InstanceReadiness: Sendable {
    public let stable: Bool
    public let elapsedMs: Int

    public init(stable: Bool, elapsedMs: Int) {
        self.stable = stable
        self.elapsedMs = elapsedMs
    }
}

/// 账号在游戏里的资料（账号卡显示用）。
///
/// 来源是页面里的 `window.ROLE`（游戏 `ServerData.createServerData()` 挂到
/// globalThis 上的角色数据视图）。**原生存的是快照，不是真源**——真源永远在
/// 页面侧，这里只在页面主动上报变化时更新。
public struct AccountProfileSnapshot: Sendable, Equatable {
    /// 头像远端 URL（微信 / QQ qlogo 或游戏自建 CDN）。
    public let headImg: String
    /// 游戏内角色名。
    public let name: String
    /// 战力。
    public let power: Int
    /// 角色等级（页面侧字段名是 `levelId`）。
    public let level: Int
    /// VIP 等级。
    public let vip: Int
    /// 上报时角色所在的内部区服 id（`ROLE.serverID`）。0 = 未知（旧探针 / 字段缺失）。
    ///
    /// 为什么要有它：游戏内切服之后，页面里的 `ROLE` 是**新区**的角色，
    /// 而账号卡必须始终显示 bin 自己的区 —— 宿主据此把「切服后」的资料拦下来。
    public let serverID: Int

    public init(headImg: String, name: String, power: Int, level: Int, vip: Int,
                serverID: Int = 0) {
        self.headImg = headImg
        self.name = name
        self.power = power
        self.level = level
        self.vip = vip
        self.serverID = serverID
    }

    /// 整份资料是否为空（没有头像 URL 就没有显示价值）。
    public var isEmpty: Bool { headImg.isEmpty }
}

/// 抓包探针上报的**原始 WS 帧**（`PacketCaptureScript` 发的）。
///
/// 页面侧只做三件事：hook 原生 `WebSocket`、把字节转 base64、原样上报。
/// **不做解码、不做过滤**——px 信封 / BON 的解码统一在宿主（复用
/// `XorFrameCipher` + `Bon`），过滤条件随时可改而无需重注入页面。
public struct PacketFrame: Sendable {
    /// `"send"` = 游戏发出；`"recv"` = 游戏收到。
    public let direction: String
    /// 帧原字节（base64）。可能已被页面侧截断（`truncated == true`）。
    public let payloadBase64: String
    /// 页面侧计的原始字节数（截断前）。
    public let byteCount: Int
    /// 页面侧时间戳（毫秒，页面时钟）。
    public let timestampMs: Double
    /// `"binary"` / `"text"`（文本帧直接按 UTF-8 走同一条 base64 通道）。
    public let kind: String
    /// 单包超过页面上限被截断（详情里保留前缀字节，足以解出 cmd）。
    public let truncated: Bool
    /// 发出 / 收到该帧的 socket 编号（页面代理 v3 起分配；v2 及更早 = -1）。
    ///
    /// 为什么要有：主连接与盐场连接的 URL 都含 "agent"（实测主连接
    /// `wss://xxz-xyzw.hortorgames.com/agent?…`），按 URL 挑发送目标会撞——
    /// 盐场图表需要「从哪个 socket 学来的 war_* 命令，就把轮询帧发回哪个 socket」。
    public let socketID: Int

    public init(direction: String, payloadBase64: String, byteCount: Int,
                timestampMs: Double, kind: String, truncated: Bool, socketID: Int = -1) {
        self.direction = direction
        self.payloadBase64 = payloadBase64
        self.byteCount = byteCount
        self.timestampMs = timestampMs
        self.kind = kind
        self.truncated = truncated
        self.socketID = socketID
    }
}

/// 页面事件。
public enum PageEvent: Sendable {
    /// HSDK（游戏 SDK 桥）请求，requestJSON 为原文。
    case hsdk(requestJSON: String)
    /// 游戏内配置写入 localStorage。
    case storageSet(key: String, value: String)
    case storageRemove(key: String)
    /// 页面 console 输出（页面侧已按等级滤过一道）。
    case console(level: String, message: String)
    /// 页面 JS 错误（含堆栈）。
    case error(message: String)
    /// 启动沉降完成——实例池据此释放启动槽位。
    case ready(InstanceReadiness)
    /// 渲染完整性采样。
    case render(RenderHealthSample)
    /// WebGL 上下文丢失且未恢复（Cocos 2.4 无重建路径，只能整页重载）。
    case webGLFatal
    /// 内存采样。
    case memory(reason: String, assets: String, nodes: String)
    /// WebGL 事件告警。
    case graphics(event: String, message: String)
    /// 页面里的帧率写入（调试定位用）。
    case frameRateWrite(fps: String, stack: String)
    /// 键鼠同步：捕获器上报的中性输入事件（仅参与同步的实例会上报）。
    case input(InputSyncEvent)
    /// 键鼠同步：回放回执（页面 `__LOBBY_SYNC__.replay()` 真正派发之后回一条）。
    ///
    /// 为什么要有：同步**成功时宿主侧原本一行日志都不打**，「回放到底进没进目标窗口、
    /// 落在了哪个元素上」只能靠通读注入脚本倒推。这条回执把页面内部的事实带回来：
    /// `tagName` 不是 CANVAS 就说明事件没落到游戏画布上（游戏根本收不到）。
    case syncAck(type: String, replayed: Int, misses: Int, releases: Int,
                 downs: Int, ups: Int, capturing: Bool, tag: String, agent: Int)
    /// 脚本请求用系统浏览器打开外链（GM_openInTab 垫片的兜底路径）。
    case openURL(url: String)
    /// 脚本导出文件：页面侧的下载垫片把 `<a download>` + Blob 的内容交回原生落盘。
    /// WKWebView 不实现 HTML 的 download 属性，不做这一步脚本的「导出」就是死键。
    case downloadFile(name: String, mimeType: String, base64: String)
    /// 脚本导出的是远端 URL（`<a download href="https://…">`），由原生代下。
    case downloadURL(url: String, name: String)
    /// 账号资料上报（只读探针 `AccountProfileScript` 发的；账号卡显示用）。
    case accountProfile(AccountProfileSnapshot)
    /// 游戏的 `login_authuser` 请求需要宿主现算应答（登录代理）。
    ///
    /// 页面把原始请求体原样送上来（base64）——**体里带着游戏想去哪个区**
    /// （`serverId`），宿主据此重新认证，这是「游戏内选区」能生效的唯一依据。
    /// - `kind == "auth"`（缺省）：按 authuser 处理。
    /// - `kind == "serverList"`：宿主去取 `/login/serverlist`（页面发不出
    ///   `O4e-Encoding` 这个头，服务端会回裸 BON，游戏解不开）。
    case loginAuth(kind: String, requestID: String, bodyBase64: String)
    /// 登录链路的诊断上报（**不走 console**）。
    ///
    /// 为什么不复用 console 桥：页面 boot 之后游戏会把 `console` 整个换掉，
    /// 我们包装的那层随之失效 —— 实测「改用凭据体 / 完成：响应 N 字节」这类
    /// 关键行根本回不到宿主，排查时会被误判成「没发生」。这条通道只发一个小字符串。
    case loginDiag(message: String)
    /// 抓包探针的原始 WS 帧（`PacketCaptureScript` 上报；仅抓包开启时才有）。
    case packet(PacketFrame)
    /// 页面请求把一段文本写进系统剪贴板（游戏内「复制玩家ID」）。
    ///
    /// 为什么不让页面自己写：页面 origin 是自定义 scheme（非安全上下文），
    /// `navigator.clipboard` 根本不可用，`document.execCommand('copy')` 在 WKWebView
    /// 里也不保证成功；而「复制 ID」是个一次必须成功的动作，所以由宿主写。
    case clipboardWrite(text: String)
    /// 未识别的事件（前向兼容：新版本页面在旧宿主上运行）。
    case unknown(type: String)

    /// 从原始消息字典解码。
    public static func decode(from body: [String: Any]) -> PageEvent {
        guard let type = body["type"] as? String else { return .unknown(type: "?") }
        switch type {
        case "hsdk":
            guard let message = body["message"] as? String else { return .unknown(type: type) }
            return .hsdk(requestJSON: message)
        case "storage":
            guard let key = body["key"] as? String else { return .unknown(type: type) }
            if (body["op"] as? String) == "remove" {
                return .storageRemove(key: key)
            }
            guard let value = body["value"] as? String else { return .unknown(type: type) }
            return .storageSet(key: key, value: value)
        case "console":
            return .console(level: body["level"] as? String ?? "log",
                            message: body["message"] as? String ?? "")
        case "error":
            return .error(message: body["message"] as? String ?? "Unknown error")
        case "ready":
            return .ready(InstanceReadiness(stable: (body["stable"] as? Bool) ?? true,
                                            elapsedMs: body["elapsedMs"] as? Int ?? 0))
        case "render":
            return .render(RenderHealthSample(
                missingTexture: body["missingTexture"] as? Int ?? 0,
                missingMaterial: body["missingMaterial"] as? Int ?? 0,
                visible: body["visible"] as? Int ?? 0,
                contextLost: (body["contextLost"] as? Bool) == true,
                reason: body["reason"] as? String ?? "unknown"
            ))
        case "webgl-fatal":
            return .webGLFatal
        case "memory":
            return .memory(reason: body["reason"] as? String ?? "sample",
                           assets: stringified(body["assets"]),
                           nodes: stringified(body["nodes"]))
        case "graphics":
            return .graphics(event: body["event"] as? String ?? "event",
                             message: body["message"] as? String ?? "")
        case "frameRate":
            return .frameRateWrite(fps: stringified(body["fps"]),
                                   stack: stringified(body["stack"]))
        case "clipboard":
            // 长度封顶：剪贴板内容是页面说了算的，别让一段超长文本把系统剪贴板塞爆。
            guard let text = body["text"] as? String, !text.isEmpty else { return .unknown(type: type) }
            return .clipboardWrite(text: String(text.prefix(256)))
        case "input":
            guard let event = InputSyncEvent.decode(from: body) else { return .unknown(type: type) }
            return .input(event)
        case "syncAck":
            return .syncAck(type: body["t"] as? String ?? "?",
                            replayed: integer(body["n"]),
                            misses: integer(body["miss"]),
                            releases: integer(body["rel"]),
                            downs: integer(body["dn"]),
                            ups: integer(body["up"]),
                            capturing: (body["cap"] as? Bool) == true,
                            tag: String((body["tag"] as? String ?? "").prefix(24)),
                            agent: integer(body["agent"]))
        case "openurl":
            guard let url = body["url"] as? String else { return .unknown(type: type) }
            return .openURL(url: url)
        case "download":
            guard let name = body["name"] as? String,
                  let base64 = body["base64"] as? String else { return .unknown(type: type) }
            return .downloadFile(name: name,
                                 mimeType: body["mimeType"] as? String ?? "application/octet-stream",
                                 base64: base64)
        case "downloadurl":
            guard let url = body["url"] as? String else { return .unknown(type: type) }
            return .downloadURL(url: url, name: body["name"] as? String ?? "")
        case "avatar":
            // 没有头像 URL 的上报没有显示价值（`ROLE` 刚建、`headImg` 还没填）。
            // 这样的消息当未识别事件丢掉，不往会话层送半成品。
            guard let headImg = body["headImg"] as? String, !headImg.isEmpty else {
                return .unknown(type: type)
            }
            return .accountProfile(AccountProfileSnapshot(
                headImg: headImg,
                name: body["name"] as? String ?? "",
                power: integer(body["power"]),
                level: integer(body["level"]),
                vip: integer(body["vip"]),
                serverID: integer(body["serverID"])
            ))
        case "loginAuth":
            guard let requestID = body["requestId"] as? String else { return .unknown(type: type) }
            return .loginAuth(kind: body["kind"] as? String ?? "auth",
                              requestID: requestID,
                              bodyBase64: body["body"] as? String ?? "")
        case "loginDiag":
            return .loginDiag(message: body["message"] as? String ?? "")
        case "packet":
            // ⚠️ 宽松解码：抓包是诊断工具，个别字段异常不该让整条事件被丢弃。
            // byteCount 经 WKScriptMessage 到达时可能是 NSNumber，`as? Int` 在
            // 32 位溢出值上会失败，所以统一走 `integer(_:)`。
            let frame = PacketFrame(
                direction: body["dir"] as? String == "send" ? "send" : "recv",
                payloadBase64: body["b64"] as? String ?? "",
                byteCount: integer(body["len"]),
                timestampMs: double(body["ts"]),
                kind: body["kind"] as? String ?? "binary",
                truncated: (body["trunc"] as? Bool) == true,
                socketID: integer(body["sid"]) - 1
            )
            return .packet(frame)
        default:
            return .unknown(type: type)
        }
    }

    /// 宽松取整：页面侧可能送 Int / Double / String（`role.power` 是普通字段，
    /// 没有类型保证），任何一种都不要把整条事件判成非法。
    private static func integer(_ value: Any?) -> Int {
        if let number = value as? Int { return max(0, number) }
        if let number = value as? Double { return number.isFinite ? max(0, Int(number)) : 0 }
        if let number = value as? NSNumber { return max(0, number.intValue) }
        if let text = value as? String, let parsed = Double(text) {
            return parsed.isFinite ? max(0, Int(parsed)) : 0
        }
        return 0
    }

    private static func stringified(_ value: Any?) -> String {
        String(describing: value ?? "?")
    }

    /// 宽松取浮点（页面侧 `Date.now()` 是毫秒整数，但别让类型差异丢事件）。
    private static func double(_ value: Any?) -> Double {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String, let parsed = Double(text) { return parsed }
        return 0
    }
}
