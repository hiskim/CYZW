import CryptoKit
import Foundation

// MARK: - 引擎层协议与结果契约
//
// 领域层只定义「是什么」，实现放在 Storage（文件 / 缓存）与 Engine（流程编排）。
// UI 与 App 壳通过协议注入依赖，保证各模块可以独立替换与测试。

/// 认证结果：登录成功后注入页面的全部凭据与版本信息。
public struct AuthResult: Sendable {
    /// 认证服务原始响应（base64，注入页面后由 XHR 拦截器喂给游戏的登录请求）。
    public let authResponseBase64: String
    /// 账号 SDK 身份（前缀 + bin 内容 SHA256，跨启动稳定）。
    public let accountID: String
    /// 资源清单 JSON 原文（注入页面供 WebRuntime 使用）。
    public let manifestJSON: String
    /// bundle 名 → 版本号（方案处理器改写 bundle URL 用）。
    public let bundleVersions: [String: String]

    public init(authResponseBase64: String, accountID: String,
                manifestJSON: String, bundleVersions: [String: String]) {
        self.authResponseBase64 = authResponseBase64
        self.accountID = accountID
        self.manifestJSON = manifestJSON
        self.bundleVersions = bundleVersions
    }
}

/// CDN 资源清单。
public struct ResourceManifest: Sendable, Equatable {
    /// 服务端返回的 body JSON 原文。
    public let json: String
    /// bundle 名 → 版本号。
    public let bundleVersions: [String: String]

    public init(json: String, bundleVersions: [String: String]) {
        self.json = json
        self.bundleVersions = bundleVersions
    }
}

/// 账号凭据文件存取协议（实现：LobbyStorage.AccountBinStore）。
public protocol AccountStoring: Sendable {
    /// 把外部选中的 .bin 文件物理拷贝入库，返回库内实际保存的文件名。
    /// 实现内部自行处理安全作用域授权与同名冲突（默认自动重命名）。
    @discardableResult
    func importBin(from sourceURL: URL) throws -> String
    /// 枚举库内全部账号文件（修改时间新 → 旧，再按文件名字典序）。
    func listAccountFiles() throws -> [AccountBinFileInfo]
    /// 读取某个账号 .bin 的原始内容（登录认证使用）。
    func readBinData(for fileName: String) throws -> Data
    /// 删除账号文件（幂等）。
    func deleteBin(named fileName: String) throws
    /// 是否已存在同名文件。
    func contains(fileName: String) -> Bool
}

/// CDN 资源提供协议（实现：LobbyStorage.CDNAssetStore）。
public protocol ResourceProviding: Sendable {
    /// 拉取最新资源清单（网络失败时回退持久化副本）。
    func latestManifest() async throws -> ResourceManifest
    /// 取资源数据：内存 → 磁盘缓存 → 合并下载。
    /// - Parameter source: "game"（实例在途请求，高优先级短超时）或 "prefetch"。
    func data(for remoteURL: URL, source: String) async throws -> Data
    /// 启动预热：清单 + 核心 bundle。失败不致命（实例可惰性重试）。
    func prepareForLaunch() async -> ResourceManifest?
    /// 游戏会话开始 / 结束（预取调度参考）。async 以便 actor 实现直接满足。
    func beginGameSession() async
    func endGameSession() async
}

/// 账号认证协议（实现：LobbyEngine.AccountAuthenticator）。
public protocol GameAuthenticating: Sendable {
    func authenticate(account: GameAccount, manifest: ResourceManifest?) async throws -> AuthResult
}

/// 分组持久化协议（实现：LobbyStorage.AccountGroupStore）。
public protocol GroupStoring: Sendable {
    /// 自定义分组定义（不含伪分组）。
    func loadDefinitions() -> [AccountGroup]
    /// 账号 ID → 分组 ID 归属表。
    func loadAssignments() -> [String: String]
    /// 伪分组展开状态。
    func loadExpansions() -> [String: Bool]
    /// 分组内账号拖拽排序表：分组 ID → 有序账号 ID 列表。
    func loadOrders() -> [String: [String]]
    /// 多开矩阵的窗口排列表（账号 ID 序；缺席账号按分组序追加在尾部）。
    func loadMatrixOrder() -> [String]
    /// 全量保存。
    func save(definitions: [AccountGroup], assignments: [String: String],
              expansions: [String: Bool], orders: [String: [String]],
              matrixOrder: [String])
}

/// 认证错误。
public enum AuthenticationError: LocalizedError, Sendable {
    case missingBinFile
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingBinFile: return "找不到账号 .bin 文件。"
        case .invalidResponse(let detail): return detail
        }
    }
}

// MARK: - 稳定标识符

/// 由字符串种子确定性派生 UUID（同一账号每次启动拿到同一个存储区）。
public enum StableIdentifier {
    /// SHA256 前 16 字节 → RFC 4122 v4 位域，保证跨启动稳定且形似随机。
    public static func uuid(from seed: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40   // version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        let bridged = bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) }
        return UUID(uuidString: bridged.uuidString) ?? UUID()
    }

    /// 账号 SDK 身份：前缀 + bin 内容 SHA256（与上一代宿主口径一致）。
    public static func identity(forBinData data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return LobbyConfiguration.identityPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 认证完成前的兜底身份：前缀 + 文件名 SHA256。
    public static func fallbackIdentity(forFileName fileName: String) -> String {
        let digest = SHA256.hash(data: Data(fileName.utf8))
        return LobbyConfiguration.identityPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 用户偏好枚举

/// 游戏内存储策略（WKWebsiteDataStore 选型）。
///
/// - `isolatedPerAccount`（规格 2.0 默认）：每账号 `WKWebsiteDataStore(forIdentifier:)`
///   独占容器，磁盘与内存层面绝对隔离，彻底杜绝串号。
/// - `sharedAcrossAccounts`：所有账号共用一份存储。游戏自身按 uid 区分角色数据，
///   全局设置（音量、省电）一处修改全账号生效——与真机「一个 App 一份存储」语义一致。
/// - `ephemeral`：不持久化（排障用），配置由原生镜像层兜底。
public enum GameStoragePolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    case isolatedPerAccount
    case sharedAcrossAccounts
    case ephemeral

    public var id: String { rawValue }

    public static let fallback: GameStoragePolicy = .isolatedPerAccount

    public var label: String {
        switch self {
        case .isolatedPerAccount: return "账号隔离"
        case .sharedAcrossAccounts: return "全局共享"
        case .ephemeral: return "不持久化"
        }
    }

    public var summary: String {
        switch self {
        case .isolatedPerAccount: return "每账号独立存储容器，互不串号（推荐）"
        case .sharedAcrossAccounts: return "所有账号共用一份游戏内配置"
        case .ephemeral: return "关闭窗口即丢弃 WebKit 侧数据（排障用）"
        }
    }

    public static func current() -> GameStoragePolicy {
        guard let raw = UserDefaults.standard.string(forKey: LobbyConfiguration.PreferenceKey.storagePolicy),
              let policy = GameStoragePolicy(rawValue: raw) else { return fallback }
        return policy
    }
}

/// 渲染画质档位（低 / 中 / 高）。
/// 最终被 WebRuntime 换算成画布 backing store 像素比：
/// 低 = 1x，中 = min(1.5, 屏幕缩放)，高 = min(2, 屏幕缩放)。
/// 档位在实例启动时读取，改档需重启实例。
public enum RenderQuality: String, CaseIterable, Identifiable, Codable, Sendable {
    case low, medium, high

    public var id: String { rawValue }
    public static let fallback: RenderQuality = .high

    public var label: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }

    public var pixelRatioLabel: String {
        switch self {
        case .low: return "1x"
        case .medium: return "1.5x"
        case .high: return "≤2x"
        }
    }

    public static func current() -> RenderQuality {
        guard let raw = UserDefaults.standard.string(forKey: LobbyConfiguration.PreferenceKey.renderQuality),
              let quality = RenderQuality(rawValue: raw) else { return fallback }
        return quality
    }
}

/// 目标帧率档位。与 WebRuntime 的 `preferredFrameRate()` 白名单严格对齐：
/// `[15, 24, 30, 45, 60, 90, 120]`，白名单外的值会被页面丢弃回退到 60。
/// 注意 20 **不在**白名单内——规格中的「失焦 20 FPS」在本引擎映射为最省电的 15。
public enum TargetFrameRate: Int, CaseIterable, Identifiable, Codable, Sendable {
    case fps15 = 15
    case fps24 = 24
    case fps30 = 30
    case fps45 = 45
    case fps60 = 60
    case fps90 = 90
    case fps120 = 120

    public var id: Int { rawValue }
    public static let fallback: TargetFrameRate = .fps60
    /// 非焦点实例的省电帧率（白名单内最低档）。
    public static let idleFallback: TargetFrameRate = .fps15

    public static func current() -> TargetFrameRate {
        let stored = UserDefaults.standard.integer(forKey: LobbyConfiguration.PreferenceKey.frameRate)
        return TargetFrameRate(rawValue: stored) ?? fallback
    }
}
