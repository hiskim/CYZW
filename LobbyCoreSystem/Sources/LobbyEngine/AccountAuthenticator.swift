import Foundation
import LobbyDomain
import LobbyStorage

/// 账号认证器：把 .bin 凭据原文提交给游戏认证服务。
///
/// 认证发生在 WebKit 实例创建**之前**：拿到的响应字节在页面里通过 XHR 拦截器
/// 喂给游戏的 `/login/authuser` 请求，游戏侧感知不到这个「预认证」过程——
/// 与真机 SDK 登录的时序一致。
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
        guard let url = URL(string: LobbyConfiguration.gameServerURL.absoluteString + "/login/authuser?_seq=1") else {
            throw AuthenticationError.invalidResponse("认证服务地址非法。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = binData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("lx", forHTTPHeaderField: "O4e-Encoding")
        request.setValue("close", forHTTPHeaderField: "Connection")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), data.count > 4 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AuthenticationError.invalidResponse("认证服务返回异常（HTTP \(status)）。")
        }

        let liveManifest: ResourceManifest
        if let manifest {
            liveManifest = manifest
        } else {
            liveManifest = try await CDNAssetStore.shared.latestManifest()
        }

        return AuthResult(authResponseBase64: data.base64EncodedString(),
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
