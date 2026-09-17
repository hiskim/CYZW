import Foundation
import LobbyDomain

// MARK: - 游戏服务端的最小 HTTP 通道
//
// 只做一件事：把二进制 POST 出去、把**原始响应字节**拿回来。
// 解析交给调用方（/login/\* 的响应都是「外层 BON 里再嵌一段 BON」，见 BonCodec）。
//
// ⚠️ 三个端点的编码标记头口径**不一样**，实测过：
//   · `body` 是 `.bin` 原字节（`lx` 信封）     → 发 `O4e-Encoding: lx` 或不发，都行；
//   · `body` 是改写后按 `x` 重编码的凭据       → **不能**发 `lx`（服务端直接拒，无 roleToken）；
//   · `body` 是游戏自己的 BON 参数（`x` 信封） → 同上。
// 所以头**必须与字节一致**，由 `BinCredential` 给出（`LoginBody.encodingHeader`），
// 不要在这里写死。
//
// 会话是临时的（无 cookie / 无缓存）：这些调用只是「问一次」，不该留下任何状态。
public enum GameEndpointClient {
    public enum Error: Swift.Error, CustomStringConvertible {
        case badURL(String)
        case httpStatus(Int)
        case emptyResponse(Int)

        public var description: String {
            switch self {
            case .badURL(let path):
                return "端点地址非法：\(path)"
            case .httpStatus(let code):
                return "服务端返回 HTTP \(code)"
            case .emptyResponse(let count):
                return "响应为空（\(count) 字节）"
            }
        }
    }

    private static let timeout: TimeInterval = 12

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// POST 二进制并取回原始响应字节。
    ///
    /// - Parameters:
    ///   - path: 形如 `/login/authuser?_seq=1`（查询串**自带**，不能用
    ///     `appendingPathComponent` 拼——它会把 `?` 转义成 `%3F` 让服务端 404）。
    ///   - body: 请求体原始字节。
    ///   - encodingHeader: `O4e-Encoding` 的值；nil = 不发这个头。
    public static func post(path: String, body: Data,
                            encodingHeader: String?) async throws -> Data {
        guard let url = URL(string: LobbyConfiguration.gameServerURL.absoluteString + path) else {
            throw Error.badURL(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let encodingHeader {
            request.setValue(encodingHeader,
                             forHTTPHeaderField: LobbyConfiguration.payloadEncodingHeaderName)
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw Error.httpStatus(http.statusCode)
        }
        // 4 字节以下是明确的异常（正常响应是 BON 报文，至少 5 个字节）。
        guard data.count > 4 else { throw Error.emptyResponse(data.count) }
        return data
    }

    /// 解一层「报文外壳」：`{ cmd, ack, seq, time, body }` 里的 `body` 再解一层 BON。
    ///
    /// `/login/*` 的响应都是这个形状（HTTP 响应**没有**加密信封，首字节就是 BON tag）。
    public static func decodeMessageBody(_ data: Data) throws -> BonValue {
        let outer = try Bon.decode(data)
        guard case .binary(let bodyBytes)? = outer.objectValue?["body"] else {
            // 少数响应（例如 selectserver）直接把数据放在外层；原样返回让调用方处理。
            return outer
        }
        return try Bon.decode(bodyBytes)
    }
}
