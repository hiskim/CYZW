import Combine
import Foundation
import LobbyDomain

// MARK: - 游戏加强设置

/// 游戏加强设置快照（下发页面时用的完整口径）。
public struct GameEnhancementSettings: Equatable, Sendable {
    /// 十殿加速开关。
    public var nightmareSpeedEnabled: Bool
    /// 十殿加速倍率（始终落在 `multiplierRange` 内）。
    public var nightmareSpeedMultiplier: Int

    /// UI 加速开关（引擎全局时间倍率）。
    public var uiSpeedEnabled: Bool
    /// UI 加速倍率（始终落在 `uiSpeedRange` 内、且为 0.5 的整数倍）。
    public var uiSpeedMultiplier: Double

    /// 实例画面左上角显示实测帧率角标。
    public var fpsDisplayEnabled: Bool

    /// 战斗数据浮层（血条上方 攻/盾/血，怒气条下方 怒）。
    public var battleStatsEnabled: Bool

    /// 隐藏游戏内聊天窗口（消息列表 + 输入区整块）。默认 false = 原样显示。
    public var chatPanelHidden: Bool

    /// 默认倍率（与第三方脚本的建议值一致）。
    public static let defaultMultiplier = 100
    /// 倍率合法区间（与面板输入一致；超出即时钳制）。
    public static let multiplierRange = 1...1000
    /// 面板上的快捷倍率。
    public static let quickMultipliers = [10, 50, 100, 500]

    /// UI 加速默认倍率。取 3 而不是 1——1 等于没开，参考实现（官方 APK 运行时
    /// 的 `engineGlobalSpeed`）默认档就是 3。
    public static let defaultUISpeedMultiplier: Double = 3
    /// UI 加速合法区间。上界压到 10（参考实现允许到 50）：倍率越高，单个 tick 的
    /// `dt` 越大，越容易把补间/物理推成跳帧；10 已经足够「明显变快」。
    public static let uiSpeedRange: ClosedRange<Double> = 1...10
    /// 倍率步进。半档起步，避免用户输入出 2.37 这种没法复现的值。
    public static let uiSpeedStep: Double = 0.5
    /// 面板上的快捷档。
    public static let quickUISpeeds: [Double] = [1.5, 2, 3, 5]

    public init(nightmareSpeedEnabled: Bool,
                nightmareSpeedMultiplier: Int,
                uiSpeedEnabled: Bool = false,
                uiSpeedMultiplier: Double = GameEnhancementSettings.defaultUISpeedMultiplier,
                fpsDisplayEnabled: Bool = false,
                battleStatsEnabled: Bool = false,
                chatPanelHidden: Bool = false) {
        self.nightmareSpeedEnabled = nightmareSpeedEnabled
        self.nightmareSpeedMultiplier = Self.clamp(multiplier: nightmareSpeedMultiplier)
        self.uiSpeedEnabled = uiSpeedEnabled
        self.uiSpeedMultiplier = Self.clamp(speed: uiSpeedMultiplier)
        self.fpsDisplayEnabled = fpsDisplayEnabled
        self.battleStatsEnabled = battleStatsEnabled
        self.chatPanelHidden = chatPanelHidden
    }

    /// 钳制倍率到合法区间。0 / 负数 → 下界 1（而不是静默跳回默认值，
    /// 免得用户把输入框清成 0 之后看到倍率「跳回 100」而困惑）。
    public static func clamp(multiplier: Int) -> Int {
        min(max(multiplier, multiplierRange.lowerBound), multiplierRange.upperBound)
    }

    /// 钳制 UI 加速倍率：先量化到 0.5 步进，再收进闭区间。
    /// NaN / 无穷（输入框里粘进来的脏值）一律退回默认档。
    public static func clamp(speed: Double) -> Double {
        guard speed.isFinite else { return defaultUISpeedMultiplier }
        let stepped = (speed / uiSpeedStep).rounded() * uiSpeedStep
        return min(max(stepped, uiSpeedRange.lowerBound), uiSpeedRange.upperBound)
    }

    /// 倍率文案：整数档显示 `x3`，半档显示 `x1.5`。
    public static func describe(speed: Double) -> String {
        let value = clamp(speed: speed)
        return value == value.rounded() ? "x\(Int(value))" : "x\(value)"
    }
}

/// 游戏加强设置库（原生侧唯一真源）。
///
/// 配置只在 UserDefaults 里持久化，由实例在文档就绪时下发到页面。
///
/// 写入只走 `LobbySessionModel` 的 setter（落盘 + 广播一处完成），
/// 这里不监听自身变化，避免「改了值但没下发」的静默路径。
public final class GameEnhancementStore: ObservableObject {
    /// 十殿加速开关。默认关闭。
    @Published public var nightmareSpeedEnabled: Bool {
        didSet {
            UserDefaults.standard.set(nightmareSpeedEnabled,
                                      forKey: LobbyConfiguration.PreferenceKey.enhanceNightmareSpeedEnabled)
        }
    }

    /// 十殿加速倍率。越界值由调用方 / `settings` 读取路径钳制。
    @Published public var nightmareSpeedMultiplier: Int {
        didSet {
            UserDefaults.standard.set(nightmareSpeedMultiplier,
                                      forKey: LobbyConfiguration.PreferenceKey.enhanceNightmareSpeedMultiplier)
        }
    }

    /// 隐藏游戏内聊天窗口。
    @Published public var chatPanelHidden: Bool {
        didSet {
            UserDefaults.standard.set(chatPanelHidden,
                                      forKey: LobbyConfiguration.PreferenceKey.enhanceChatHidden)
        }
    }

    /// UI 加速开关（引擎全局时间倍率）。默认关闭。
    @Published public var uiSpeedEnabled: Bool {
        didSet {
            UserDefaults.standard.set(uiSpeedEnabled,
                                      forKey: LobbyConfiguration.PreferenceKey.enhanceUISpeedEnabled)
        }
    }

    /// UI 加速倍率。越界 / 非 0.5 步进的值由调用方 / `settings` 读取路径钳制。
    @Published public var uiSpeedMultiplier: Double {
        didSet {
            UserDefaults.standard.set(uiSpeedMultiplier,
                                      forKey: LobbyConfiguration.PreferenceKey.enhanceUISpeedMultiplier)
        }
    }

    /// 帧率角标开关。
    @Published public var fpsDisplayEnabled: Bool {
        didSet {
            UserDefaults.standard.set(fpsDisplayEnabled,
                                      forKey: LobbyConfiguration.PreferenceKey.enhanceFPSDisplay)
        }
    }

    /// 战斗数据浮层开关。
    @Published public var battleStatsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(battleStatsEnabled,
                                      forKey: LobbyConfiguration.PreferenceKey.enhanceBattleStats)
        }
    }

    /// 下发用的快照（倍率在这里兜底钳制，页面永远拿不到越界值）。
    public var settings: GameEnhancementSettings {
        GameEnhancementSettings(nightmareSpeedEnabled: nightmareSpeedEnabled,
                                nightmareSpeedMultiplier: nightmareSpeedMultiplier,
                                uiSpeedEnabled: uiSpeedEnabled,
                                uiSpeedMultiplier: uiSpeedMultiplier,
                                fpsDisplayEnabled: fpsDisplayEnabled,
                                battleStatsEnabled: battleStatsEnabled,
                                chatPanelHidden: chatPanelHidden)
    }

    // MARK: - 页面侧回执（排障用）

    /// 最近一次下发后**页面回传的诊断串**，形如
    /// `实例「小号A」：chat=1/1 skin=1/1 root=groot chatNote=chat-hidden`。
    ///
    /// 为什么要有它：结果只进日志的话，用户实测「没生效」时只能靠捞日志判断是
    /// 「代理没进页面」「没找到面板」还是「压错了层」。直接显示在配置页上，
    /// 一次截图就能定性。多实例时保留最后一个回执（够用，且不引入集合展示）。
    @Published public private(set) var lastPageReport: String?

    /// 记录一次页面回执。只认非空串；`no-handler` 也是有效信息（代理没进页面）。
    ///
    /// 顺带把回执里的帧率段登记进 `fpsReadings`（键 = 账号昵称）——设置页「目标帧率」
    /// 卡就是靠它显示实测值的，所以一处解析、一处消费。
    public func notePageReport(_ diagnostic: String, account: String) {
        let trimmed = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let reading = Self.parseFPSReading(from: trimmed) {
            let key = account.isEmpty ? "-" : account
            // 读数没变就不写：这个方法每 2s 被调一次，无脑写会一直触发 @Published 重绘。
            if let existing = fpsReadings[key],
               existing.measured == reading.measured, existing.target == reading.target {
                // 与上次相同，跳过。
            } else {
                fpsReadings[key] = reading
            }
        }
        let line = account.isEmpty ? trimmed : "\(account)：\(trimmed)"
        if lastPageReport != line { lastPageReport = line }
    }

    // MARK: - 帧率读数（供设置页「目标帧率」卡显示）

    /// 从页面回执里取帧率段 `fps=<开关>:<实测>/<目标>`，例如
    /// `fps=1:58/60`（正在采样）、`fps=1:-/60`（还没采到样）、`fps=0:0/60`（角标关着）。
    ///
    /// 格式知识留在本文件，视图只负责显示——解析规则跟 `GameEnhancementScript.status()`
    /// 是同一份契约，放在一起改不容易漏。
    public static func parseFPSReading(from report: String?) -> (measured: Int?, target: Int)? {
        guard let report, let marker = report.range(of: "fps=") else { return nil }
        var tail = report[marker.upperBound...]
        // 跳过开关位（`1:` / `0:`）。
        guard let colon = tail.firstIndex(of: ":") else { return nil }
        tail = tail[tail.index(after: colon)...]
        // 取值段：`58/60`；未采样时是 `-/60`。
        let token = tail.prefix { $0.isNumber || $0 == "/" || $0 == "-" }
        let parts = token.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let target = Int(parts[1]) else { return nil }
        return (Int(parts[0]), target)
    }

    /// 最近一次回执里的帧率读数（nil = 回执里没有 fps 段，例如代理没进页面）。
    public var lastFPSReading: (measured: Int?, target: Int)? {
        Self.parseFPSReading(from: lastPageReport)
    }

    /// 各账号最近一次的帧率读数（键 = 账号昵称）。
    ///
    /// 为什么按账号留着而不是只留最后一个：多开时每路的读数本来就不同——焦点实例跑
    /// 用户档、其余按 `idleFallback` 钉在 15 FPS。只留最后一个的话，设置页上那个数字
    /// 会在几路之间跳，看不出「我这路到底跑多少」。
    @Published public private(set) var fpsReadings: [String: (measured: Int?, target: Int)] = [:]

    /// 取某账号的帧率读数（设置页按**焦点账号**取，语义 = 「我正在看的这路跑多少」）。
    public func fpsReading(forAccount nickname: String) -> (measured: Int?, target: Int)? {
        fpsReadings[nickname]
    }

    public init() {
        let defaults = UserDefaults.standard
        nightmareSpeedEnabled = defaults.bool(
            forKey: LobbyConfiguration.PreferenceKey.enhanceNightmareSpeedEnabled)
        let stored = defaults.object(
            forKey: LobbyConfiguration.PreferenceKey.enhanceNightmareSpeedMultiplier) as? Int
        nightmareSpeedMultiplier = GameEnhancementSettings.clamp(
            multiplier: stored ?? GameEnhancementSettings.defaultMultiplier)
        chatPanelHidden = defaults.bool(
            forKey: LobbyConfiguration.PreferenceKey.enhanceChatHidden)
        uiSpeedEnabled = defaults.bool(
            forKey: LobbyConfiguration.PreferenceKey.enhanceUISpeedEnabled)
        // Double 缺省键读出来是 0，直接当倍率用会被钳到 1（等于没开）——
        // 必须按「键存不存在」判，缺省才落到默认档 3（`UserDefaults.integer`
        // 缺省返回 0 的老坑，别在新键上重演）。
        let storedSpeed = defaults.object(
            forKey: LobbyConfiguration.PreferenceKey.enhanceUISpeedMultiplier) as? Double
        uiSpeedMultiplier = GameEnhancementSettings.clamp(
            speed: storedSpeed ?? GameEnhancementSettings.defaultUISpeedMultiplier)
        fpsDisplayEnabled = defaults.bool(
            forKey: LobbyConfiguration.PreferenceKey.enhanceFPSDisplay)
        battleStatsEnabled = defaults.bool(
            forKey: LobbyConfiguration.PreferenceKey.enhanceBattleStats)
    }
}
