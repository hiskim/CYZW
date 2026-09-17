import Foundation
import LobbyDomain
import LobbyIPC

// MARK: - 不启动游戏，直接从服务端取账号资料
//
// 链路（移植自助手仓 `/Users/gg/code/xyzw_web_helper`，实测 ~300ms/账号）：
//
//   .bin 原字节 ──POST──> /login/authuser?_seq=1  →  { roleToken, roleId }
//                                                        │
//        wss://xxz-xyzw.hortorgames.com/agent?p=<token>&e=x&lang=chinese
//                                                        │
//                        发 role_getroleinfo  ────────>  │
//                        收 Role_GetRoleInfoResp <──────┘  → role.headImg / power / levelId / name
//
// 报文的 body 是**内层再 BON 编码**的字节串，所以要解两层（见 `decodeRoleInfo`）。
//
// ⚠️ **它会建立一次游戏会话。** 调用方必须先确认该账号**没有正在运行的实例**，
// 否则很可能把大厅里那个窗口顶掉。这条约束在 `LobbySessionModel` 侧落地。
//
// ⚠️ 与 `AccountAuthenticator` 打的是同一个 `/login/authuser`：那边只把响应原样
// 交给页面（游戏自己解），这边要**自己解析**出 roleToken。端点定义收在
// `LobbyConfiguration` 里，改端点时两处一起改。
//
// ⚠️ 超时不靠 Task 取消：`URLSessionWebSocketTask.receive()` 未必响应协作式取消，
// 所以用一个 watchdog **主动 cancel socket**，让 receive 立刻抛错退出（确定性）。
public final class AccountProfileFetcher: Sendable {
    public enum FetchError: Swift.Error, CustomStringConvertible {
        case httpStatus(Int)
        case malformedAuthResponse(String)
        case badWebSocketURL
        case malformedFrame(String)
        case roleInfoMissing(keys: [String])
        case socketClosed(code: Int, reason: String)
        case timedOut

        public var description: String {
            switch self {
            case .httpStatus(let code):
                return "authuser 返回 HTTP \(code)"
            case .malformedAuthResponse(let detail):
                return "authuser 响应结构异常：\(detail)"
            case .badWebSocketURL:
                return "拼不出合法的 WebSocket 地址"
            case .malformedFrame(let detail):
                return "报文结构异常：\(detail)"
            case .roleInfoMissing(let keys):
                return "响应里没有角色数据（字段：\(keys.joined(separator: ","))）"
            case .socketClosed(let code, let reason):
                return "连接被关闭：code=\(code)\(reason.isEmpty ? "" : " reason=\(reason)")"
            case .timedOut:
                return "等待 role_getroleinfo 超时"
            }
        }
    }

    /// 单次 fetch 的总预算：实测 300ms 级，20s 已经非常宽松（弱网也够）。
    private static let overallTimeout: TimeInterval = 20
    /// authuser 的预算。
    private static let authTimeout: TimeInterval = 10
    /// 连上之后等响应的预算。
    private static let receiveTimeout: TimeInterval = 12

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.authTimeout
        // 会话是临时的（不带 cookie / 缓存）：我们只是问一次资料，不需要任何持久状态。
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// 取一次角色资料。
    ///
    /// - Parameter binData: `.bin` 凭据文件的**原始字节**（原样 POST，不做任何转换）。
    public func fetch(binData: Data) async throws -> AccountProfileSnapshot {
        let credentials = try await authenticate(binData: binData)
        return try await roleInfo(roleToken: credentials.roleToken, roleId: credentials.roleId)
    }

    /// 只用一对已有的凭据去问角色资料（不再打 authuser）。
    ///
    /// 用途：验证一份「现算出来的」认证响应到底落在哪个角色上——
    /// 登录代理（`LoginProxy`）换服之后就靠它确认结果（`roleId` 是账号 uid，
    /// 与区服无关，**不能**拿它判换服是否生效）。
    public func roleInfo(roleToken: String, roleId: Int64) async throws -> AccountProfileSnapshot {
        try await requestRoleInfo(roleToken: roleToken, roleId: roleId)
    }

    /// 从一份 `/login/authuser` 的**原始响应字节**里取出 `roleToken` / `roleId`。
    ///
    /// 换服之后要确认「真的到了目标角色」，就得能把响应解回凭据。
    ///
    /// ⚠️ 响应可能**自带信封**：编码跟随请求的 `O4e-Encoding`——宿主发 `lx`
    /// 就收回 `70 6c` 开头的 LZ4 载荷，不发头就收回裸 BON（两种都实测过）。
    /// 所以先按「可能带信封」解一次，再按裸 BON 兜底。
    public static func credentials(fromAuthResponse data: Data) throws -> (roleToken: String, roleId: Int64) {
        let plain = (try? BinCredential.plaintext(of: data).bytes) ?? data
        let outer = try Bon.decode(plain)
        guard case .binary(let bodyBytes)? = outer.objectValue?["body"] else {
            throw FetchError.malformedAuthResponse(
                "外层没有 body（字段：\(outer.objectValue?.keys.joined(separator: ",") ?? "-")）")
        }
        let inner = try Bon.decode(bodyBytes)
        guard let token = inner.objectValue?["roleToken"]?.stringValue, !token.isEmpty else {
            throw FetchError.malformedAuthResponse(
                "没有 roleToken（字段：\(inner.objectValue?.keys.joined(separator: ",") ?? "-")）")
        }
        guard let roleId = inner.objectValue?["roleId"]?.intValue else {
            throw FetchError.malformedAuthResponse("没有 roleId")
        }
        return (token, roleId)
    }

    // MARK: - 第一步：authuser

    private struct Credentials {
        let roleToken: String
        let roleId: Int64
    }

    private func authenticate(binData: Data) async throws -> Credentials {
        guard let url = URL(string: LobbyConfiguration.gameServerURL.absoluteString
                            + LobbyConfiguration.profileAuthUserPath) else {
            throw FetchError.badWebSocketURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = binData
        request.timeoutInterval = Self.authTimeout

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError.httpStatus(http.statusCode)
        }
        let outer = try Bon.decode(data)
        guard case .binary(let bodyBytes)? = outer.objectValue?["body"] else {
            throw FetchError.malformedAuthResponse(
                "外层没有 body（字段：\(outer.objectValue?.keys.joined(separator: ",") ?? "-")）")
        }
        let inner = try Bon.decode(bodyBytes)
        guard let token = inner.objectValue?["roleToken"]?.stringValue, !token.isEmpty else {
            throw FetchError.malformedAuthResponse(
                "没有 roleToken（字段：\(inner.objectValue?.keys.joined(separator: ",") ?? "-")）")
        }
        guard let roleId = inner.objectValue?["roleId"]?.intValue else {
            throw FetchError.malformedAuthResponse("没有 roleId")
        }
        return Credentials(roleToken: token, roleId: roleId)
    }

    // MARK: - 第二步：WSS + role_getroleinfo

    private func requestRoleInfo(roleToken: String, roleId: Int64) async throws -> AccountProfileSnapshot {
        guard let url = Self.webSocketURL(roleToken: roleToken, roleId: roleId) else {
            throw FetchError.badWebSocketURL
        }
        let socket = session.webSocketTask(with: url)
        socket.resume()
        // watchdog：到点直接 cancel socket，让在等的 receive() 立刻失败退出。
        let watchdog = Task { [receiveTimeout = Self.receiveTimeout] in
            try? await Task.sleep(nanoseconds: UInt64(receiveTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer {
            watchdog.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
        }

        try await socket.send(.data(Self.roleInfoRequestFrame()))
        let deadline = Date().addingTimeInterval(Self.receiveTimeout)
        while Date() < deadline {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                // watchdog 主动关闭 / 服务端关闭都会走到这里 —— 统一按超时回报，
                // 因为对调用方来说区分这两者没有意义（都是「没拿到资料，可以下次再试」）。
                throw FetchError.timedOut
            }
            switch message {
            case .data(let frame):
                if let snapshot = try decodeRoleInfo(frame) { return snapshot }
            case .string(let text):
                // 正常情况下服务端只发二进制；收到文本说明协议变了，记一条便于取证。
                LobbyLog.debug("[profile] 非二进制帧（%ld 字符）：%@", text.count,
                               String(text.prefix(120)))
            @unknown default:
                break
            }
        }
        throw FetchError.timedOut
    }

    /// 拼 WSS 地址：`…/agent?p=<token>&e=x&lang=chinese`。
    private static func webSocketURL(roleToken: String, roleId: Int64) -> URL? {
        guard var components = URLComponents(url: LobbyConfiguration.profileWebSocketBaseURL,
                                             resolvingAgainstBaseURL: false) else { return nil }
        let token = tokenJSON(roleToken: roleToken, roleId: roleId)
        // ⚠️ 用 `percentEncodedQuery` 而不是 `queryItems`：`queryItems` 会把已经编码过的
        // `%` 再编一次（`%2B` → `%252B`），服务端拿到的就是另一串东西。
        // ⚠️ 字符集必须**只放 ASCII 字母数字**：token 里是 base64，含 `+` 与 `/`，
        // 而 query 里的裸 `+` 会被服务端解成空格 → roleToken 直接损坏。
        // 多编几个 `-_.~` 无害（任何解析器都会正确还原），漏编 `+` 是致命的。
        guard let encoded = token.addingPercentEncoding(withAllowedCharacters: Self.tokenAllowed) else {
            return nil
        }
        components.percentEncodedQuery = "p=\(encoded)&e=x&lang=chinese"
        return components.url
    }

    private static let tokenAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    /// 与助手 `transformToken` 产物同构：
    /// `JSON.stringify({ ...authuserData, sessId, connId, isRestore: 0 })`。
    /// 手写而非 `JSONSerialization`，是为了**字段顺序与数字格式**都可控（便于对拍）。
    private static func tokenJSON(roleToken: String, roleId: Int64) -> String {
        let milliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        let sessionID = milliseconds * 100 + Int64.random(in: 0..<100)
        let connectionID = milliseconds + Int64.random(in: 0..<10)
        let escaped = roleToken
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"roleToken\":\"\(escaped)\",\"roleId\":\(roleId),"
            + "\"sessId\":\(sessionID),\"connId\":\(connectionID),\"isRestore\":0}"
    }

    /// `role_getroleinfo` 的完整帧（BON 编码 → x 信封）。
    static func roleInfoRequestFrame() -> Data {
        let body = Bon.encode(.object(BonObject([
            .init("clientVersion", .string(LobbyConfiguration.profileClientVersion)),
            .init("inviteUid", .int(0)),
            .init("platform", .string("hortor")),
            .init("platformExt", .string("mix")),
            .init("scene", .string("")),
        ])))
        let message = BonValue.object(BonObject([
            .init("cmd", .string("role_getroleinfo")),
            .init("ack", .int(0)),
            .init("seq", .int(1)),
            // 毫秒时间戳超过 Int32 → 必须走 int64 分支（对齐参考实现的 encodeNumber）。
            .init("time", .long(Int64(Date().timeIntervalSince1970 * 1000))),
            .init("body", .binary(body)),
        ]))
        return XorFrameCipher.seal(Bon.encode(message))
    }

    // MARK: - 解包

    /// 解一帧。返回 nil 表示「不是我们等的那个包」（例如心跳 ack），继续等下一帧。
    private func decodeRoleInfo(_ frame: Data) throws -> AccountProfileSnapshot? {
        let plain = try XorFrameCipher.open(frame)
        let outer = try Bon.decode(plain)
        let command = (outer.objectValue?["cmd"]?.stringValue ?? "").lowercased()
        guard command.contains("getroleinfo") else { return nil }

        guard case .binary(let bodyBytes)? = outer.objectValue?["body"] else {
            throw FetchError.malformedFrame("响应没有 body（cmd=\(command)）")
        }
        let inner = try Bon.decode(bodyBytes)
        guard let role = inner.objectValue?["role"]?.objectValue else {
            throw FetchError.roleInfoMissing(keys: inner.objectValue?.keys ?? [])
        }

        let headImg = role["headImg"]?.stringValue ?? ""
        guard !headImg.isEmpty else {
            throw FetchError.roleInfoMissing(keys: role.keys)
        }
        // `levelId` 是角色等级；`level` 在同族接口里恒为 1（实测），只作兜底。
        let level = role["levelId"]?.intValue ?? role["level"]?.intValue ?? 0
        return AccountProfileSnapshot(
            headImg: headImg,
            name: role["name"]?.stringValue ?? "",
            power: Int(max(0, role["power"]?.intValue ?? 0)),
            level: Int(max(0, level)),
            vip: Int(max(0, role["vip"]?.intValue ?? 0))
        )
    }
}
