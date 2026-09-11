import Foundation
import OSLog

/// .bin 账号文件的沙盒内统一存储管理器（单例）。
///
/// 设计目标：彻底摆脱"外部绝对路径 + 安全书签"方案。
/// 用户通过 NSOpenPanel / 拖拽选中的 .bin 会在**导入瞬间**被物理拷贝进
/// App 自身沙盒的 `Application Support/AccountBins` 目录；此后所有读写
/// 都只针对沙盒内副本，重启、重装（同容器）、无授权状态都能直接访问，
/// 不再依赖 `startAccessingSecurityScopedResource` 的临时授权。
///
/// 线程安全：全部可变状态为空，属性均为 `let`；写操作（导入/删除/迁移）
/// 由内部串行队列互斥，读操作依赖 FileManager 原生原子性。
final class AccountFileManager: @unchecked Sendable {
    static let shared = AccountFileManager()

    private let logger = Logger(subsystem: "com.xyzw.ios2", category: "AccountFileManager")

    /// 串行化写操作，避免"检查同名文件 → 拷贝"过程中的竞态。
    private let ioQueue = DispatchQueue(label: "com.xyzw.ios2.accountfilemanager.io")

    /// 旧版存储位置（Documents/ios2/bins）的一次性迁移标记。
    private let legacyMigrationKey = "ios2.accountbins.legacy-migration-v1"

    /// 同名冲突处理策略。
    enum ConflictResolution {
        /// 保留两者：新文件自动改名（`name-2.bin`、`name-3.bin`…）。默认策略。
        case rename
        /// 覆盖沙盒内同名旧文件。
        case overwrite
    }

    struct BinFileInfo {
        let fileName: String
        let creationDate: Date
        let modificationDate: Date
    }

    enum StoreError: LocalizedError {
        case invalidFileType
        case unreadableFile
        case storageUnavailable
        case copyFailed(underlying: String)

        var errorDescription: String? {
            switch self {
            case .invalidFileType:
                return "只能导入 .bin 账号文件。"
            case .unreadableFile:
                return "无法读取所选的 .bin 文件。"
            case .storageUnavailable:
                return "无法访问应用沙盒存储目录（Application Support/AccountBins）。"
            case .copyFailed(let underlying):
                return "无法将 .bin 文件拷贝到应用沙盒目录：\(underlying)"
            }
        }
    }

    /// 沙盒内 .bin 存储目录：`Application Support/AccountBins`。
    /// 沙盒环境下该路径位于 App 容器内（`~/Library/Containers/<bundle-id>/Data/Library/Application Support/AccountBins`），
    /// 永远可写，无需任何额外授权。
    let binsDirectoryURL: URL

    private init() {
        let fileManager = FileManager.default
        let appSupport: URL
        if let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            appSupport = url
        } else {
            // 理论上不可达；兜底到容器 Library 路径，保证目录解析永不返回 nil。
            let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
            appSupport = library.appendingPathComponent("Application Support", isDirectory: true)
        }
        binsDirectoryURL = appSupport.appendingPathComponent("AccountBins", isDirectory: true)

        Self.migrateLegacyBinsIfNeeded(directory: binsDirectoryURL,
                                       migrationKey: legacyMigrationKey,
                                       fileManager: fileManager,
                                       logger: logger)
    }

    // MARK: - 导入（拷贝入沙盒）

    /// 把用户选中的 .bin 文件物理拷贝进沙盒 `AccountBins` 目录。
    ///
    /// - Parameter sourceURL: NSOpenPanel / `.fileImporter` / 拖拽来源的安全作用域 URL。
    ///   方法内部自行处理 `startAccessingSecurityScopedResource`，调用方无需关心。
    /// - Parameter conflict: 同名冲突策略，默认自动重命名。
    /// - Returns: 沙盒内实际保存的文件名（作为 `Account.fileName` 持久化标识）。
    @discardableResult
    func importBin(from sourceURL: URL,
                   conflict: ConflictResolution = .rename) throws -> String {
        guard sourceURL.pathExtension.lowercased() == "bin" else {
            throw StoreError.invalidFileType
        }

        // 安全作用域授权只覆盖"本次选择"，因此必须在同一作用域内完成拷贝。
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }

        // 源文件可读性预检（大小 > 0），避免拷贝一个空壳。
        let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        if (sourceAttributes?[.size] as? UInt64) == 0 {
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

    // MARK: - 启动加载（从沙盒恢复账号列表）

    /// 枚举沙盒内全部 .bin 文件。App 启动时调用一次即可恢复左侧账号列表。
    /// 排序规则与旧实现一致：修改时间新 → 旧，再按文件名字典序，保证列表稳定。
    func loadAccountFiles() throws -> [BinFileInfo] {
        try ensureDirectory()
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: binsDirectoryURL,
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
                return BinFileInfo(
                    fileName: url.lastPathComponent,
                    creationDate: values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
                    modificationDate: values?.contentModificationDate ?? .distantPast
                )
            }
    }

    // MARK: - 读取 / 删除

    /// 沙盒内某个 .bin 文件的完整 URL（内部使用，外部请用 `readBinData`）。
    func binURL(for fileName: String) -> URL {
        binsDirectoryURL.appendingPathComponent(Self.safeBinName(fileName))
    }

    /// 读取某个账号 .bin 的内容（登录认证使用）。
    func readBinData(for fileName: String) throws -> Data {
        try Data(contentsOf: binURL(for: fileName))
    }

    /// 删除沙盒内的账号文件。文件已不存在时视为删除成功（幂等）。
    func deleteBin(named fileName: String) throws {
        let safeName = Self.safeBinName(fileName)
        guard safeName == fileName else { throw StoreError.invalidFileType }
        try ioQueue.sync { [self] in
            let target = binsDirectoryURL.appendingPathComponent(safeName)
            guard FileManager.default.fileExists(atPath: target.path) else { return }
            try FileManager.default.removeItem(at: target)
            logger.info("bin deleted: \(safeName, privacy: .public)")
        }
    }

    /// 沙盒内是否已存在同名文件。
    func contains(fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: binURL(for: fileName).path)
    }

    // MARK: - 私有实现

    /// 确保 `AccountBins` 目录存在（用户手动删掉容器内目录时也能自愈）。
    private func ensureDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: binsDirectoryURL,
                                                    withIntermediateDirectories: true)
        } catch {
            logger.error("create AccountBins failed: \(error.localizedDescription, privacy: .public)")
            throw StoreError.storageUnavailable
        }
    }

    /// 根据冲突策略解析目标 URL。
    /// `rename`：`name-2.bin`、`name-3.bin` … 递增；`overwrite`：直接使用原名。
    private func destinationURL(forPreferredName preferredName: String,
                                conflict: ConflictResolution) -> URL {
        let initial = binsDirectoryURL.appendingPathComponent(preferredName)
        guard conflict == .rename, FileManager.default.fileExists(atPath: initial.path) else {
            return initial
        }
        let base = (preferredName as NSString).deletingPathExtension
        for counter in 2...999 {
            let candidate = binsDirectoryURL.appendingPathComponent("\(base)-\(counter).bin")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        // 极端情况下编号耗尽，退化为 UUID 后缀，保证导入永不失败。
        return binsDirectoryURL.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8)).bin")
    }

    // MARK: - 旧目录一次性迁移

    /// 把旧版 `Documents/ios2/bins` 下的 .bin 一次性搬进新目录。
    /// 迁移在单例初始化时执行，通过 UserDefaults 标记保证只跑一次；
    /// 旧目录不可读（如开启沙盒后失去外部授权）时静默跳过，不影响启动。
    private static func migrateLegacyBinsIfNeeded(directory: URL,
                                                  migrationKey: String,
                                                  fileManager: FileManager,
                                                  logger: Logger) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }

        defer { defaults.set(true, forKey: migrationKey) }

        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let legacyDirectory = documents.appendingPathComponent("ios2/bins", isDirectory: true)
        guard fileManager.fileExists(atPath: legacyDirectory.path) else { return }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let legacyFiles = try fileManager.contentsOfDirectory(at: legacyDirectory,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])
                .filter { $0.pathExtension.lowercased() == "bin" }

            var migrated = 0
            for file in legacyFiles {
                let preferredName = safeBinName(file.lastPathComponent)
                let destination = uniqueDestination(preferredName: preferredName, in: directory)
                do {
                    try fileManager.copyItem(at: file, to: destination)
                    try? fileManager.removeItem(at: file)  // 拷贝成功后再清理旧文件；失败不阻断
                    migrated += 1
                } catch {
                    logger.warning("legacy bin migrate failed for \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            if migrated > 0 {
                logger.info("legacy bins migrated: \(migrated)")
            }
        } catch {
            // 旧目录列举失败（典型：沙盒开启后容器外路径不可读）→ 放弃迁移，不影响启动。
            logger.warning("legacy bins directory unreadable, skip migration: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 迁移专用：在目录内找不冲突的目标 URL。
    private static func uniqueDestination(preferredName: String, in directory: URL) -> URL {
        let initial = directory.appendingPathComponent(preferredName)
        guard FileManager.default.fileExists(atPath: initial.path) else { return initial }
        let base = (preferredName as NSString).deletingPathExtension
        for counter in 2...999 {
            let candidate = directory.appendingPathComponent("\(base)-\(counter).bin")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8)).bin")
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
