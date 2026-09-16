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

    /// 默认倍率（与第三方脚本的建议值一致）。
    public static let defaultMultiplier = 100
    /// 倍率合法区间（与面板输入一致；超出即时钳制）。
    public static let multiplierRange = 1...1000
    /// 面板上的快捷倍率。
    public static let quickMultipliers = [10, 50, 100, 500]

    public init(nightmareSpeedEnabled: Bool,
                nightmareSpeedMultiplier: Int) {
        self.nightmareSpeedEnabled = nightmareSpeedEnabled
        self.nightmareSpeedMultiplier = Self.clamp(multiplier: nightmareSpeedMultiplier)
    }

    /// 钳制倍率到合法区间。0 / 负数 → 下界 1（而不是静默跳回默认值，
    /// 免得用户把输入框清成 0 之后看到倍率「跳回 100」而困惑）。
    public static func clamp(multiplier: Int) -> Int {
        min(max(multiplier, multiplierRange.lowerBound), multiplierRange.upperBound)
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

    /// 下发用的快照（倍率在这里兜底钳制，页面永远拿不到越界值）。
    public var settings: GameEnhancementSettings {
        GameEnhancementSettings(nightmareSpeedEnabled: nightmareSpeedEnabled,
                                nightmareSpeedMultiplier: nightmareSpeedMultiplier)
    }

    public init() {
        let defaults = UserDefaults.standard
        nightmareSpeedEnabled = defaults.bool(
            forKey: LobbyConfiguration.PreferenceKey.enhanceNightmareSpeedEnabled)
        let stored = defaults.object(
            forKey: LobbyConfiguration.PreferenceKey.enhanceNightmareSpeedMultiplier) as? Int
        nightmareSpeedMultiplier = GameEnhancementSettings.clamp(
            multiplier: stored ?? GameEnhancementSettings.defaultMultiplier)
    }
}
