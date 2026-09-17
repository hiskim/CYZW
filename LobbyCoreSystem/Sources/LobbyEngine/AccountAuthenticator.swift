import Foundation
import LobbyDomain
import LobbyStorage

/// 账号认证器：把 .bin 凭据原文提交给游戏认证服务。
///
/// 认证发生在 WebKit 实例创建**之前**：拿到的响应字节在页面里通过 XHR 拦截器
/// 喂给游戏的 `/login/authuser` 请求，游戏侧感知不到这个「预认证」过程——
/// 与真机 SDK 登录的时序一致。
///
/// ⚠️ **页面里 `login_authuser` 的唯一调用方是游戏自己**（`HSDK.app.min.js` 与
/// `ios2-web-*.js` 里都没有这个端点；`ios2-login.js` 那个垫片也只是纯应答）。
/// 所以这份预认证响应是「游戏的首次登录」，而它**每换一个区服就要换一份**——
/// 换服由 `LoginProxy` 在实例里按需重算（见 `GameViewportInstance`）。
public struct AccountAuthenticator: GameAuthenticating {
    private let bins: AccountStoring

    public init(bins: AccountStoring) {
        self.bins = bins
    }

    public func authenticate(account: GameAccount, manifest: ResourceManifest?) async throws -> AuthResult {
        guard let binData = try? bins.readBinData(for: account.fileName),
              !binData.isEmpty else {
            throw AuthenticationError.missingBinFile
        }
        // ⚠️ 不能用 appendingPathComponent("login/authuser?_seq=1")：它会把 `?`
        // 转义成 %3F，请求变成 /login/authuser%3F_seq=1 → 服务端 404。
        // 查询串必须用 URL(string:) 原样拼接（与 WebRuntime 页面内请求同形）。
        //
        // 编码标记头**由凭据自己决定**（`BinCredential.scheme`）：原封不动的 `.bin`
        // 是 `lx`，而「选服派生」出来的那份是重编码的 `x` —— 给后者盖上 `lx` 头会被
        // 服务端直接拒（实测无 roleToken）。以前的实现把 `lx` 写死，属于埋着的坑。
        let body: Data
        let encodingHeader: String?
        if let credential = try? BinCredential(data: binData) {
            let login = try credential.loginBody(serverID: nil)
            body = login.bytes
            encodingHeader = login.encodingHeader
        } else {
            // 解不开就当普通凭据原样提交（与历史行为一致，不至于因此登不上）。
            LobbyLog.warn("[auth] 凭据无法解析，按原字节提交：%@", account.fileName)
            body = binData
            encodingHeader = LobbyConfiguration.payloadEncodingLX
        }

        let response = try await GameEndpointClient.post(
            path: LobbyConfiguration.profileAuthUserPath,
            body: body,
            encodingHeader: encodingHeader)

        let liveManifest: ResourceManifest
        if let manifest {
            liveManifest = manifest
        } else {
            liveManifest = try await CDNAssetStore.shared.latestManifest()
        }

        return AuthResult(authResponseBase64: response.base64EncodedString(),
                          binData: binData,
                          accountID: StableIdentifier.identity(forBinData: binData),
                          manifestJSON: liveManifest.json,
                          bundleVersions: liveManifest.bundleVersions)
    }
}

/// CDNAssetStore.shared 的便捷访问（协议要求 actor 可全局寻址的场景很少，
/// 这里只为认证器的兜底路径保留一个共享实例入口）。
extension CDNAssetStore {
    /// 进程级共享实例（App 壳装配时也可自建实例并注入，二者等价）。
    public static let shared = CDNAssetStore()
}
