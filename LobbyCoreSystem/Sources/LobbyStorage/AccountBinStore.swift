import Foundation
import LobbyDomain
import OSLog

/// `.bin` 账号文件的统一存储管理器。
///
/// 设计要点：
/// - 用户经 NSOpenPanel / 拖拽选中的 .bin 会在**导入瞬间**被物理拷贝进
///   `Application Support/AccountBins`；此后所有读写只针对库内副本，
///   重启、无授权状态都能直接访问，不依赖安全书签的临时授权。
/// - 与上一代宿主共用同一目录（见 LobbyConfiguration.accountBinsDirectory），
///   用户已导入的账号在新大厅开箱即用。
///
/// 线程安全：写操作（导入 / 删除）由串行队列互斥；读操作依赖 FileManager
/// 原生原子性。全部可变状态为空，属性均为 `let`。
public final class AccountBinStore: AccountStoring, @unchecked Sendable {
    private let logger = Logger(subsystem: LobbyLog.subsystem, category: "AccountBinStore")
    private let ioQueue = DispatchQueue(label: "com.xyzw.gamelobby.accountbins.io")
    private let directoryURL: URL

    /// 同名冲突处理策略。
    public enum ConflictResolution: Sendable {
        /// 保留两者：新文件自动改名（`name-2.bin`、`name-3.bin`…）。默认策略。
        case rename
        /// 覆盖库内同名旧文件。
        case overwrite
    }

    public enum StoreError: LocalizedError, Sendable {
        case invalidFileType
        case unreadableFile
        case storageUnavailable
        case copyFailed(underlying: String)

        public var errorDescription: String? {
            switch self {
            case .invalidFileType: return "只能导入 .bin 账号文件。"
            case .unreadableFile: return "无法读取所选的 .bin 文件。"
            case .storageUnavailable: return "无法访问存储目录（Application Support/AccountBins）。"
            case .copyFailed(let underlying): return "无法将 .bin 文件拷贝到存储目录：\(underlying)"
            }
        }
    }

    public init(directoryURL: URL = LobbyConfiguration.accountBinsDirectory) {
        self.directoryURL = directoryURL
    }

    // MARK: - 导入（拷贝入库）

    /// 把用户选中的 .bin 文件物理拷贝进库目录。
    ///
    /// - Parameters:
    ///   - sourceURL: NSOpenPanel / 拖拽来源 URL。方法内部自行处理
    ///     `startAccessingSecurityScopedResource`，调用方无需关心。
    ///   - conflict: 同名冲突策略，默认自动重命名。
    /// - Returns: 库内实际保存的文件名（= 账号稳定 ID）。
    @discardableResult
    public func importBin(from sourceURL: URL,
                          conflict: ConflictResolution = .rename) throws -> String {
        guard sourceURL.pathExtension.lowercased() == "bin" else {
            throw StoreError.invalidFileType
        }

        // 安全作用域授权只覆盖「本次选择」，必须在同一作用域内完成拷贝。
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        // 源文件可读性预检（大小 > 0），避免拷贝一个空壳。
        let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        if (attributes?[.size] as? UInt64) == 0 {
            throw StoreError.unreadableFile
        }

        return try ioQueue.sync { [self] in
            try ensureDirectory()
            let preferredName = Self.safeBinName(sourceURL.lastPathComponent)
            let destination = destinationURL(forPreferredName: preferredName, conflict: conflict)
            do {
                if conflict == .overwrite, FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            } catch {
                logger.error("import copy failed: \(error.localizedDescription, privacy: .public)")
                throw StoreError.copyFailed(underlying: error.localizedDescription)
            }
            logger.info("bin imported: \(destination.lastPathComponent, privacy: .public)")
            return destination.lastPathComponent
        }
    }

    // MARK: - AccountStoring

    /// 协议便捷入口：默认冲突策略（自动重命名）导入。
    @discardableResult
    public func importBin(from sourceURL: URL) throws -> String {
        try importBin(from: sourceURL, conflict: .rename)
    }

    /// 枚举库内全部 .bin 文件。排序：修改时间新 → 旧，再按文件名字典序，保证稳定。
    public func listAccountFiles() throws -> [AccountBinFileInfo] {
        try ensureDirectory()
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.pathExtension.lowercased() == "bin" }
            .sorted { lhs, rhs in
                let leftDate = (try? lhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                let rightDate = (try? rhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                if leftDate != rightDate { return leftDate > rightDate }
                return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
            }
            .map { url in
                let values = try? url.resourceValues(forKeys: keys)
                return AccountBinFileInfo(
                    fileName: url.lastPathComponent,
                    creationDate: values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
                    modificationDate: values?.contentModificationDate ?? .distantPast
                )
            }
    }

    /// 某个 .bin 的完整 URL。
    public func binURL(for fileName: String) -> URL {
        directoryURL.appendingPathComponent(Self.safeBinName(fileName))
    }

    public func readBinData(for fileName: String) throws -> Data {
        try Data(contentsOf: binURL(for: fileName))
    }

    /// 删除账号文件。文件已不存在时视为删除成功（幂等）。
    public func deleteBin(named fileName: String) throws {
        let safeName = Self.safeBinName(fileName)
        guard safeName == fileName else { throw StoreError.invalidFileType }
        try ioQueue.sync { [self] in
            let target = directoryURL.appendingPathComponent(safeName)
            guard FileManager.default.fileExists(atPath: target.path) else { return }
            try FileManager.default.removeItem(at: target)
            logger.info("bin deleted: \(safeName, privacy: .public)")
        }
    }

    public func contains(fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: binURL(for: fileName).path)
    }

    // MARK: - 内部

    private func ensureDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            logger.error("create AccountBins failed: \(error.localizedDescription, privacy: .public)")
            throw StoreError.storageUnavailable
        }
    }

    /// 根据冲突策略解析目标 URL。
    private func destinationURL(forPreferredName preferredName: String, conflict: ConflictResolution) -> URL {
        let initial = directoryURL.appendingPathComponent(preferredName)
        guard conflict == .rename, FileManager.default.fileExists(atPath: initial.path) else {
            return initial
        }
        let base = (preferredName as NSString).deletingPathExtension
        for counter in 2...999 {
            let candidate = directoryURL.appendingPathComponent("\(base)-\(counter).bin")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        // 编号耗尽的极端情况退化为随机后缀，保证导入永不失败。
        return directoryURL.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8)).bin")
    }

    /// 文件名清洗：只保留末段路径成分、强制 .bin 扩展名、替换非法字符。
    private static func safeBinName(_ rawName: String) -> String {
        let candidate = (rawName as NSString).lastPathComponent
        let withExtension = (candidate as NSString).pathExtension.lowercased() == "bin"
            ? candidate
            : "\(candidate).bin"
        let invalid = CharacterSet(charactersIn: "/\\").union(.controlCharacters)
        let sanitized = withExtension.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }.joined()
        return (sanitized.isEmpty || sanitized == "." || sanitized == "..") ? "account.bin" : sanitized
    }
}
