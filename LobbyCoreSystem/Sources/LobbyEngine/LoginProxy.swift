import Foundation
import LobbyDomain

// MARK: - 登录代理：把「换服」变成宿主侧的一次重新认证
//
// 背景（实测，见仓库根 `BIN登录认证优化方案.md` §3）：
//
//   · `/login/authuser` 在页面里的**唯一调用方是游戏自己**（cmd `login_authuser`），
//     宿主以前用一个「无状态」的 XHR 垫片把所有这类请求都回答成**开服时那一份**
//     预认证字节 —— 于是游戏内的「设置 → 服务器 → 选区」写完了
//     `localStorage.serverId`、也走了状态机重登，却永远回到原角色。
//   · 游戏的请求体里**带着它想去哪个区**（`serverId` 字段），所以这件事在字节层面
//     是可观测的：拿到请求体就知道它要换到哪。
//   · 而「换到哪」是可满足的：把凭据明文的 `serverId` 换掉、重编码、重新 POST，
//     回来的就是那个区的角色（实测 4/5 逐字段命中，见 `probe-pick-role.mjs`）。
//
// 于是这个代理做一件事：**按游戏请求里的 `serverId` 现算应答**。
//
//   请求 serverId == 凭据自带的  → 直接用预认证字节（零额外往返，首登就是这条）
//   请求给了别的 serverId        → 现算一次（~300–400ms）并缓存
//   解析不出 / 现算失败          → **退回预认证字节**（最多回到原区服，绝不让登录卡死）
//
// ⚠️ 第三条是硬约束：代理的任何失败都必须是「退化为改造前的行为」，不能是新故障点。
@MainActor
public final class LoginProxy {
    /// 一次应答。
    public struct Answer: Sendable {
        public let bytes: Data
        /// 诊断用来源：`cached` / `derived` / `fallback`。
        public let source: String
    }

    /// 缓存条目上限。凭据本身才 1KB 出头、响应几百字节，正常最多访问几个区；
    /// 超限直接清空——这里不需要 LRU，也不需要为它引入复杂度。
    private static let cacheLimit = 32

    private let credential: BinCredential
    /// 预认证字节：凭据自带 `serverId` 对应的那份。
    private let defaultResponse: Data
    private var cache: [Int64: Data] = [:]
    /// 同一 `serverId` 的并发请求合并（游戏重连时会连发同一条）。
    private var inflight: [Int64: Task<Data, Error>] = [:]

    /// 诊断计数器（进日志，也方便以后放到状态行上）。
    public private(set) var derivedCount = 0
    public private(set) var fallbackCount = 0
    public private(set) var lastSource = "-"
    public private(set) var lastServerID: Int64?

    public init(credential: BinCredential, defaultResponse: Data) {
        self.credential = credential
        self.defaultResponse = defaultResponse
    }

    /// 凭据自带的区服（预认证字节对应的那个）。
    public var credentialServerID: Int64? { credential.serverID }

    /// 按游戏请求体给出应答。
    ///
    /// - Parameter gameRequestBody: 页面侧原样上报的请求体（可能是空 —— 游戏用
    ///   `send()` 不带 body 时）。为 nil / 解析不出时按「凭据自带的区服」处理。
    public func respond(gameRequestBody: Data?) async -> Answer {
        let requested = gameRequestBody.flatMap { BinCredential.requestedServerID(inRequestBody: $0) }
        lastServerID = requested

        guard let requested, requested != credential.serverID else {
            return finish(Answer(bytes: defaultResponse, source: "cached"))
        }
        if let hit = cache[requested] {
            return finish(Answer(bytes: hit, source: "cached"))
        }
        do {
            let bytes = try await response(for: requested)
            return finish(Answer(bytes: bytes, source: "derived"))
        } catch {
            // 退化为改造前的行为：宁可回到原区服，也不能让登录失败。
            LobbyLog.warn("[login-proxy] 换服认证失败（serverId=%lld）：%@",
                          requested, error.localizedDescription)
            fallbackCount += 1
            return finish(Answer(bytes: defaultResponse, source: "fallback"))
        }
    }

    /// 诊断串（`v=` 版本号约定与 `GameEnhancementScript.status()` 保持一致）。
    public func status() -> String {
        "v=1 | cred=\(credential.serverID.map(String.init) ?? "-")"
            + " | last=\(lastSource)"
            + " | req=\(lastServerID.map(String.init) ?? "-")"
            + " | derived=\(derivedCount) fallback=\(fallbackCount) cache=\(cache.count)"
    }

    // MARK: - 内部

    private func finish(_ answer: Answer) -> Answer {
        lastSource = answer.source
        return answer
    }

    private func response(for serverID: Int64) async throws -> Data {
        if let existing = inflight[serverID] { return try await existing.value }
        let credential = self.credential
        let task = Task<Data, Error> {
            let login = try credential.loginBody(serverID: serverID)
            return try await GameEndpointClient.post(
                path: LobbyConfiguration.profileAuthUserPath,
                body: login.bytes,
                encodingHeader: login.encodingHeader)
        }
        inflight[serverID] = task
        defer { inflight[serverID] = nil }

        let data = try await task.value
        cache[serverID] = data
        if cache.count > Self.cacheLimit { cache.removeAll() }
        derivedCount += 1
        LobbyLog.info("[login-proxy] 按 serverId=%lld 现算认证应答（%ld 字节）", serverID, data.count)
        return data
    }
}
