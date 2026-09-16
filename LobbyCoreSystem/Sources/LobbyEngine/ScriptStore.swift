import Combine
import Foundation
import LobbyDomain
import OSLog

// MARK: - JS 脚本管理（对齐上一代 ios/Shell/ScriptManager.swift 的语义）

/// 脚本作用域（持久化字段）。
/// - `single`：仅单开生效（新导入脚本的默认状态）
/// - `singleAndMulti`：单开 + 多开都生效
public enum ScriptScope: String, Codable, Sendable {
    case single
    case singleAndMulti
}

/// 脚本运行状态的展示枚举（禁用 / 单开生效 / 单多开生效，三态互斥）。
public enum ScriptRunState: Equatable, Sendable {
    case disabled
    case singleOnly
    case singleAndMulti

    public var title: String {
        switch self {
        case .disabled: return "禁用"
        case .singleOnly: return "单开生效"
        case .singleAndMulti: return "单多开生效"
        }
    }

    /// 胶囊标签短文案（给脚本名称让宽度）。
    public var shortTitle: String {
        switch self {
        case .disabled: return "禁用"
        case .singleOnly: return "单开"
        case .singleAndMulti: return "单多开"
        }
    }
}

/// 单个脚本的持久化记录。
public struct ScriptRecord: Identifiable, Codable, Equatable, Sendable {
    public var name: String
    public var isEnabled: Bool
    public var scope: ScriptScope
    public var size: Int?

    public var id: String { name }

    public init(name: String, isEnabled: Bool, scope: ScriptScope, size: Int? = nil) {
        self.name = name
        self.isEnabled = isEnabled
        self.scope = scope
        self.size = size
    }

    /// 当前标签状态（禁用 / 单开生效 / 单多开生效，三态互斥）。
    public var runState: ScriptRunState {
        isEnabled ? (scope == .singleAndMulti ? .singleAndMulti : .singleOnly) : .disabled
    }
}

/// JS 脚本管理器（上一代 ScriptManager 的移植）。
///
/// 职责：
/// 1. `Application Support/IOS2Scripts` 目录下 .js 文件的导入 / 删除 / 枚举
///    （与上一代同目录，旧大厅已导入的脚本开箱即用）；
/// 2. 每脚本状态（启用开关 + 作用域）与两个全局开关的 UserDefaults 持久化；
/// 3. 注入集合计算：总开关关闭 → 空集合；多开环境再过「多开全局门禁」；
///    总开关只做门闸，**不修改任何脚本的子开关状态**（重开总开关后按原状态恢复）。
public final class ScriptStore: ObservableObject, @unchecked Sendable {
    /// 全部脚本记录（磁盘扫描 + 状态合并后的快照）。
    @Published public private(set) var scripts: [ScriptRecord] = []

    /// JS 引擎总开关。默认开启。关闭时不注入任何脚本，也不修改各脚本的启用状态。
    @Published public var isGlobalEnabled: Bool {
        didSet { UserDefaults.standard.set(isGlobalEnabled, forKey: LobbyConfiguration.PreferenceKey.scriptsGlobalEnabled) }
    }

    /// 多开全局门禁。默认关闭。关闭时多开矩阵实例不注入任何脚本，
    /// 避免误操作导致多开封号。
    @Published public var isMultiOpenGateEnabled: Bool {
        didSet { UserDefaults.standard.set(isMultiOpenGateEnabled, forKey: LobbyConfiguration.PreferenceKey.scriptsMultiGate) }
    }

    /// 给 UI 展示的操作结果提示（导入 / 删除 / 文件异常）。
    @Published public var lastMessage: String?

    private let logger = Logger(subsystem: LobbyLog.subsystem, category: "ScriptStore")
    private let fileManager = FileManager.default
    /// 串行化「拷贝 / 删除」写操作，避免与扫描枚举竞态。
    private let ioQueue = DispatchQueue(label: "com.xyzw.gamelobby.scriptstore.io")

    /// 脚本目录（与上一代共用）。
    public let scriptsDirectoryURL: URL

    public init(scriptsDirectoryURL: URL = LobbyConfiguration.scriptsDirectory) {
        self.scriptsDirectoryURL = scriptsDirectoryURL
        try? fileManager.createDirectory(at: scriptsDirectoryURL, withIntermediateDirectories: true)

        let defaults = UserDefaults.standard
        isGlobalEnabled = defaults.object(forKey: LobbyConfiguration.PreferenceKey.scriptsGlobalEnabled) as? Bool ?? true
        isMultiOpenGateEnabled = defaults.bool(forKey: LobbyConfiguration.PreferenceKey.scriptsMultiGate)

        scripts = Self.loadPersistedRecords()
        refresh()
    }

    // MARK: - 磁盘同步

    /// 重新扫描脚本目录并与当前状态合并。
    /// 新出现的 .js 文件默认「启用 + 单开生效」。
    public func refresh() {
        let files = (try? fileManager.contentsOfDirectory(
            at: scriptsDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let stateByName = Dictionary(scripts.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var merged: [ScriptRecord] = []
        for url in files where url.pathExtension.lowercased() == "js" {
            let name = url.lastPathComponent
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
            if let saved = stateByName[name] {
                merged.append(ScriptRecord(name: name, isEnabled: saved.isEnabled,
                                           scope: saved.scope, size: size))
            } else {
                merged.append(ScriptRecord(name: name, isEnabled: true, scope: .single, size: size))
            }
        }
        // 文件名排序保证列表稳定。
        merged.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        scripts = merged
        persistRecords()
    }

    /// 导入 .js 文件（拷贝进库目录，同名自动改名），返回成功导入的数量。
    @discardableResult
    public func importFiles(from urls: [URL]) -> Int {
        var imported = 0
        var failed = 0
        for url in urls where url.pathExtension.lowercased() == "js" {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                try ioQueue.sync { [self] in
                    try fileManager.createDirectory(at: scriptsDirectoryURL, withIntermediateDirectories: true)
                    let destination = destinationURL(forPreferredName: url.lastPathComponent)
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    try fileManager.copyItem(at: url, to: destination)
                }
                imported += 1
                logger.info("script imported: \(url.lastPathComponent, privacy: .public)")
            } catch {
                failed += 1
                logger.error("script import failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        refresh()
        if imported > 0, failed > 0 {
            lastMessage = "已导入 \(imported) 个脚本，\(failed) 个失败"
        } else if imported > 0 {
            lastMessage = "已导入 \(imported) 个脚本（默认单开生效）"
        } else {
            lastMessage = failed > 0 ? "脚本导入失败" : "未选择 .js 脚本文件"
        }
        return imported
    }

    /// 删除脚本（文件 + 状态记录）。文件已不存在视为删除成功（幂等）。
    public func delete(named name: String) {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent else { return }
        ioQueue.sync { [self] in
            let target = scriptsDirectoryURL.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: target.path) else { return }
            try? fileManager.removeItem(at: target)
        }
        scripts.removeAll { $0.name == name }
        persistRecords()
        lastMessage = "已删除 \(name)"
        logger.info("script deleted: \(name, privacy: .public)")
    }

    // MARK: - 状态变更（全部只改自身，不触碰总开关）

    /// 卡片右侧主开关：关 = 禁用；开 = 恢复该脚本已保存的作用域（默认单开）。
    public func setEnabled(_ enabled: Bool, for name: String) {
        guard let index = scripts.firstIndex(where: { $0.name == name }) else { return }
        scripts[index].isEnabled = enabled
        persistRecords()
    }

    /// 胶囊标签点击：在 单开生效 ⇄ 单多开生效 之间切换（禁用状态下点击不生效）。
    public func cycleScope(for name: String) {
        guard let index = scripts.firstIndex(where: { $0.name == name }),
              scripts[index].isEnabled else { return }
        scripts[index].scope = scripts[index].scope == .single ? .singleAndMulti : .single
        persistRecords()
    }

    /// 直接设置脚本运行状态（单开生效 / 单多开生效 / 禁用）。
    public func setRunState(_ state: ScriptRunState, for name: String) {
        guard let index = scripts.firstIndex(where: { $0.name == name }) else { return }
        switch state {
        case .disabled:
            scripts[index].isEnabled = false
        case .singleOnly:
            scripts[index].isEnabled = true
            scripts[index].scope = .single
        case .singleAndMulti:
            scripts[index].isEnabled = true
            scripts[index].scope = .singleAndMulti
        }
        persistRecords()
    }

    // MARK: - 注入集合计算

    /// 计算允许注入的脚本集合。调用方（引擎）按实例环境传参：
    /// - 单开环境：`allowMulti = true`（「单开生效 + 单多开生效」都注入）；
    /// - 多开环境：`allowMulti = isMultiOpenGateEnabled`（门禁放行时仅注入
    ///   「单多开生效」，门禁关闭 → 空集合）。
    /// 总开关关闭 → 恒为空集合（只做门闸，不改子开关状态）。
    public func enabledScripts(allowMulti: Bool) -> [ScriptRecord] {
        guard isGlobalEnabled else { return [] }
        return scripts.filter { record in
            guard record.isEnabled, !record.name.isEmpty else { return false }
            return allowMulti || record.scope == .single
        }
    }

    /// 读取 WebRuntime 内置的脚本兼容层源码（`ios2-script-runtime.js`）。
    /// 它为第三方脚本提供 DOM 垫片、WebSocket 捕获（window.ws + sendAsync）、
    /// __require 模块桥与 g_utils/ROLE 别名——用户脚本必须在它 install 之后
    /// 才能真正操作游戏。
    public func scriptRuntimeSource() -> String? {
        guard let root = LobbyConfiguration.webRuntimeRoot else { return nil }
        let url = root.appendingPathComponent("src/ios2-script-runtime.js")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 读取某个脚本的源码（UTF-8）。读取失败返回 nil，调用方跳过该脚本。
    public func scriptSource(named name: String) -> String? {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent else { return nil }
        guard let data = try? Data(contentsOf: scriptsDirectoryURL.appendingPathComponent(name)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 私有实现

    private func persistRecords() {
        guard let data = try? JSONEncoder().encode(scripts) else { return }
        UserDefaults.standard.set(data, forKey: LobbyConfiguration.PreferenceKey.scriptsRecords)
    }

    private static func loadPersistedRecords() -> [ScriptRecord] {
        guard let data = UserDefaults.standard.data(forKey: LobbyConfiguration.PreferenceKey.scriptsRecords),
              let records = try? JSONDecoder().decode([ScriptRecord].self, from: data) else { return [] }
        return records
    }

    /// 同名冲突自动改名：`name-2.js`、`name-3.js` …，保证导入永不互相覆盖。
    private func destinationURL(forPreferredName preferredName: String) -> URL {
        let safeName = (preferredName as NSString).lastPathComponent
        let initial = scriptsDirectoryURL.appendingPathComponent(safeName)
        guard fileManager.fileExists(atPath: initial.path) else { return initial }
        let base = (safeName as NSString).deletingPathExtension
        for counter in 2...999 {
            let candidate = scriptsDirectoryURL.appendingPathComponent("\(base)-\(counter).js")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return scriptsDirectoryURL.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8)).js")
    }
}
