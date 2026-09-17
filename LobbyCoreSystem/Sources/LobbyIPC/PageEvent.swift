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
        case "input":
            guard let event = InputSyncEvent.decode(from: body) else { return .unknown(type: type) }
            return .input(event)
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
}
