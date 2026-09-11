#if os(macOS)
import Foundation
import OSLog

// MARK: - 模型（对齐 iOS 版 ios2-script-page.js 的数据结构）

/// 脚本运行环境：与 iOS 版 `getEnabledScripts('single' | 'multi')` 语义对齐。
/// - single: 独立窗口登录（账号库单独启动一个账号）
/// - multi:  多开矩阵里的实例
enum ScriptEnvironment: String {
    case single
    case multi
}

/// 脚本作用域（持久化字段，rawValue 与 iOS 版 ios2.scripts 记录对齐）。
enum ScriptScope: String, Codable {
    /// 仅单开生效（新导入脚本的默认状态）
    case single
    /// 单开 + 多开都生效
    case singleAndMulti = "multi"
}

/// 单个脚本的持久化记录。
struct ScriptRecord: Identifiable, Codable, Equatable {
    var name: String
    var isEnabled: Bool
    var scope: ScriptScope
    var size: Int?

    var id: String { name }

    /// 当前标签状态（禁用 / 单开生效 / 单多开生效，三态互斥、颜色各不相同）。
    var runState: ScriptRunState {
        isEnabled ? (scope == .singleAndMulti ? .singleAndMulti : .singleOnly) : .disabled
    }
}

/// 脚本运行状态的展示枚举（与 iOS 弹窗四个选项中的前三项对应，删除是动作不是状态）。
enum ScriptRunState: Equatable {
    case disabled
    case singleOnly
    case singleAndMulti

    var title: String {
        switch self {
        case .disabled: return "禁用"
        case .singleOnly: return "单开生效"
        case .singleAndMulti: return "单多开生效"
        }
    }

    /// 卡片胶囊标签用的短文案：304pt 侧栏里给脚本名称让出宽度；
    /// 全称仍用于操作弹窗与辅助功能标签。
    var shortTitle: String {
        switch self {
        case .disabled: return "禁用"
        case .singleOnly: return "单开"
        case .singleAndMulti: return "单多开"
        }
    }
}

// MARK: - 管理器

/// macOS 版 JS 脚本管理器（iOS 版 IOS2Native listScriptFiles + ios2.scripts.* 存储的移植）。
///
/// 职责：
/// 1. 沙盒 `Application Support/IOS2Scripts` 目录下 .js 文件的导入 / 删除 / 枚举；
/// 2. 每脚本状态（启用开关 + 作用域）与两个全局开关的 UserDefaults 持久化；
/// 3. 注入集合计算：总开关关闭 → 空集合；多开环境再过「多开全局门禁」；
///    总开关只做门闸，**不修改任何脚本的子开关状态**（重开总开关后按原状态恢复）。
@MainActor
final class ScriptManager: ObservableObject {
    static let shared = ScriptManager()

    private let logger = Logger(subsystem: "com.xyzw.ios2", category: "ScriptManager")

    /// 全部脚本记录（磁盘扫描 + 状态合并后的快照）。
    @Published private(set) var scripts: [ScriptRecord] = []

    /// JS 引擎总开关。默认开启（与 iOS 版 `ios2.scripts.globalEnabled !== '0'` 缺省一致）。
    /// 关闭时不注入任何脚本，也不修改各脚本的启用状态。
    @Published var isGlobalEnabled: Bool {
        didSet { defaults.set(isGlobalEnabled, forKey: Self.globalEnabledKey) }
    }

    /// 多开全局门禁。默认关闭（与 iOS 版 `ios2.scripts.multiGate === '1'` 缺省一致）。
    /// 关闭时多开矩阵实例不注入任何脚本，避免误操作导致多开封号。
    @Published var isMultiOpenGateEnabled: Bool {
        didSet { defaults.set(isMultiOpenGateEnabled, forKey: Self.multiGateKey) }
    }

    /// 给 UI 展示的操作结果提示（导入 / 删除 / 文件异常）。
    @Published var lastMessage: String?

    static let globalEnabledKey = "macos.scripts.globalEnabled"
    static let multiGateKey = "macos.scripts.multiGate"
    private static let recordsKey = "macos.scripts.records"

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    /// 串行化「拷贝 / 删除」写操作，避免与扫描枚举竞态。
    private let ioQueue = DispatchQueue(label: "com.xyzw.ios2.scriptmanager.io")

    /// 沙盒内脚本目录：`Application Support/IOS2Scripts`（与 AccountBins 同级同策略）。
    let scriptsDirectoryURL: URL

    private init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        scriptsDirectoryURL = appSupport.appendingPathComponent("IOS2Scripts", isDirectory: true)
        try? fileManager.createDirectory(at: scriptsDirectoryURL, withIntermediateDirectories: true)

        isGlobalEnabled = defaults.object(forKey: Self.globalEnabledKey) as? Bool ?? true
        isMultiOpenGateEnabled = defaults.bool(forKey: Self.multiGateKey)

        // 启动恢复持久化状态，再与磁盘实况合并（磁盘上被手动删掉的文件会被剔除）。
        scripts = Self.loadPersistedRecords(defaults: defaults)
        refresh()
    }

    // MARK: - 磁盘同步

    /// 重新扫描脚本目录并与当前状态合并。
    /// 新出现的 .js 文件默认「启用 + 单开生效」（新脚本默认单开生效状态）。
    func refresh() {
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

    /// 导入 .js 文件（拷贝进沙盒，同名自动改名），返回成功导入的数量。
    @discardableResult
    func importFiles(from urls: [URL]) -> Int {
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
    func delete(named name: String) {
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
    func setEnabled(_ enabled: Bool, for name: String) {
        guard let index = scripts.firstIndex(where: { $0.name == name }) else { return }
        scripts[index].isEnabled = enabled
        persistRecords()
    }

    /// 胶囊标签点击：在 单开生效 ⇄ 单多开生效 之间切换（禁用状态下点击不生效）。
    func cycleScope(for name: String) {
        guard let index = scripts.firstIndex(where: { $0.name == name }),
              scripts[index].isEnabled else { return }
        scripts[index].scope = scripts[index].scope == .single ? .singleAndMulti : .single
        persistRecords()
    }

    /// 弹窗动作：直接设置脚本运行状态（单开生效 / 单多开生效 / 禁用）。
    func setRunState(_ state: ScriptRunState, for name: String) {
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

    // MARK: - 注入集合计算（iOS 版 _enabledScriptRecords 的移植）

    /// 计算某环境下应注入的脚本集合：
    /// 1) 总开关关闭 → 空集合（不加载全部脚本，也不修改子开关状态）；
    /// 2) 多开环境还要过「多开全局门禁」，门禁关闭 → 空集合；
    /// 3) 再按脚本自身状态过滤：单开环境取「单开生效 + 单多开生效」，
    ///    多开环境仅取「单多开生效」；「禁用」任何环境都不加载。
    func enabledScripts(for environment: ScriptEnvironment) -> [ScriptRecord] {
        guard isGlobalEnabled else { return [] }
        if environment == .multi, !isMultiOpenGateEnabled { return [] }
        return scripts.filter { record in
            guard record.isEnabled, !record.name.isEmpty else { return false }
            return environment == .single || record.scope == .singleAndMulti
        }
    }

    /// 读取某个脚本的源码（UTF-8）。读取失败返回 nil，调用方跳过该脚本。
    func scriptSource(named name: String) -> String? {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent else { return nil }
        guard let data = try? Data(contentsOf: scriptsDirectoryURL.appendingPathComponent(name)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 私有实现

    private func persistRecords() {
        guard let data = try? JSONEncoder().encode(scripts) else { return }
        defaults.set(data, forKey: Self.recordsKey)
    }

    private static func loadPersistedRecords(defaults: UserDefaults) -> [ScriptRecord] {
        guard let data = defaults.data(forKey: recordsKey),
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
#endif
