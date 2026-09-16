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
        default:
            return .unknown(type: type)
        }
    }

    private static func stringified(_ value: Any?) -> String {
        String(describing: value ?? "?")
    }
}
