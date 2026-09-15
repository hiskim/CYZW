import AppKit
import Foundation
import LobbyDomain
import WebKit

/// HSDK（游戏 SDK 桥）响应器。
///
/// 游戏页面经 `jsb.reflection.callStaticMethod` 发起 SDK 调用，由引导脚本路由到
/// 页面桥（`type: 'hsdk'`），这里按 action 语义应答。应答通过
/// `window.HSDK.onMessage('sdk', <JSON 字符串>)` 送回页面。
///
/// 关键语义（与真机 `loginForSDK` 对齐）：
/// - 登录类 action 先发 `sdk-get-userId`（监听器事件），再 resolve 登录 Promise；
/// - 事件 / 监听器注册类 action（`app-activity-pause` 等）**不能**立即应答——
///   那等于在启动期把事件当已触发广播给监听器；
/// - `report_log_post` 是纯上报类调用（一次点击连发二十来个），合并到下一个
///   主 RunLoop 批量回发，省掉几十次跨进程往返。
@MainActor
public final class HSDKResponder {
    /// 纯上报类 action：页面发出去就不管了，攒一批一起回。
    private static let batchableActions: Set<String> = ["report_log_post"]

    /// 页面 JS 派发通道（由视口实例注入，避免协议 sendability 纠缠）。
    private let dispatchJS: @MainActor (String) -> Void
    private let identityProvider: @MainActor () -> String

    private var pendingCalls: [String] = []
    private var flushScheduled = false

    public init(dispatchJS: @escaping @MainActor (String) -> Void,
                identityProvider: @escaping @MainActor () -> String) {
        self.dispatchJS = dispatchJS
        self.identityProvider = identityProvider
    }

    /// 处理一条 HSDK 请求（requestJSON 为页面桥原样转发的消息体）。
    public func handle(requestJSON: String) {
        guard let data = requestJSON.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = request["action"] as? String else { return }
        let extra = request["extra"] as? [String: Any] ?? [:]
        LobbyLog.debug("[hsdk] request: %@", action)
        let identity = identityProvider()

        let responseExtra: [String: Any]
        switch action {
        case "game-init":
            responseExtra = ["gameID": LobbyConfiguration.gameID, "env": 0,
                             "gameVersion": LobbyConfiguration.manifestVersion,
                             "channel": "AppStore", "distinctId": identity,
                             "deviceInfo": Self.deviceInfo(identity: identity)]
        case "user_login_show_dialog", "user-tokenlogin", "user-multi-platform-login":
            // .bin 在实例创建前已完成认证。与 iOS loginForSDK 一致：
            // 先发布监听器事件，再 resolve SDK 登录 Promise。
            send(action: "sdk-get-userId",
                 extra: ["userId": identity, "uniqueId": identity], errorCode: 0)
            send(action: action, extra: [:], errorCode: 0)
            return
        case "user-logout":
            send(action: action, extra: [:], errorCode: 0)
            send(action: "user-logout-from-sdk", extra: [:], errorCode: 0)
            return
        case "sdk-get-device-info":
            responseExtra = ["deviceUniqueId": identity, "gameId": LobbyConfiguration.gameID,
                             "gameTp": "ios", "uniqueId": identity,
                             "sysInfo": Self.deviceInfo(identity: identity)]
        case "sdk-get-userId", "user-getuserinfo":
            responseExtra = ["userId": identity, "uniqueId": identity]
        case "get-check-switchs":
            let switchIDs = extra["switchIdList"] as? [Any] ?? []
            let values = switchIDs.map { value -> Int in
                guard let switchID = value as? String else { return 0 }
                return ["ChatWorldSwitch", "PaySwitch", "FasterSubPage", "ControllerSubPage"].contains(switchID) ? 1 : 0
            }
            responseExtra = ["sequence": extra["sequence"] as? NSNumber ?? 0, "data": values]
        case "sdk-sync-passbord":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString((extra["text"] as? String) ?? (extra["data"] as? String) ?? "",
                                           forType: .string)
            responseExtra = [:]
        case "sdk-get-passbord":
            responseExtra = ["text": NSPasteboard.general.string(forType: .string) ?? ""]
        case "game_addiction_quit", "send-url-param", "app-activity-resume", "app-activity-pause", "sdk-app-back":
            // 事件 / 监听器注册：立即应答会在启动期把监听器当已触发调用。
            LobbyLog.debug("[hsdk] listener registered: %@", action)
            return
        default:
            responseExtra = [:]
        }
        send(action: action, extra: responseExtra, errorCode: 0)
    }

    // MARK: - 应答

    private func send(action: String, extra: [String: Any], errorCode: Int) {
        let payload: [String: Any] = ["action": action, "meta": ["errCode": errorCode], "extra": extra]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let message = String(data: data, encoding: .utf8),
              // JSONSerialization 拒绝顶层 Swift String（会抛 Obj-C 异常，try? 接不住）；
              // JSONEncoder 安全地产出 HSDK.onMessage 需要的带引号 JS 字符串字面量。
              let messageData = try? JSONEncoder().encode(message),
              let argument = String(data: messageData, encoding: .utf8) else { return }
        let call = "window.HSDK.onMessage('sdk',\(argument));"
        guard Self.batchableActions.contains(action) else {
            dispatch(calls: [call], singleAction: action)
            return
        }
        pendingCalls.append(call)
        scheduleFlush()
    }

    /// 合并窗口取下一个主 RunLoop：通常不到 1ms，够把同一波点击里连续的
    /// 上报攒到一起，又不明显拖住等 Promise 的调用。
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            guard !self.pendingCalls.isEmpty else { return }
            let calls = self.pendingCalls
            self.pendingCalls.removeAll()
            self.dispatch(calls: calls, singleAction: nil)
        }
    }

    private func dispatch(calls: [String], singleAction: String?) {
        guard !calls.isEmpty else { return }
        let script = """
        if(window.HSDK&&typeof window.HSDK.onMessage==='function'){\(calls.joined())}\
        else{throw new Error('HSDK.onMessage is unavailable while responding to HSDK');}
        """
        dispatchJS(script)
        if let singleAction {
            LobbyLog.debug("[hsdk] response sent: %@", singleAction)
        } else {
            LobbyLog.debug("[hsdk] batch response sent: %ld call(s)", calls.count)
        }
    }

    private static func deviceInfo(identity: String) -> [String: String] {
        ["deviceSystem": "macOS", "deviceModel": "Mac", "deviceBrand": "Apple",
         "deviceVersion": ProcessInfo.processInfo.operatingSystemVersionString,
         "hortorSDKVersion": "1.4.0", "deviceName": Host.current().localizedName ?? "Mac",
         "deviceUniqueId": identity]
    }
}

