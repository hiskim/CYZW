import Foundation

/// WebKit 游戏画质档位（低 / 中 / 高）。
///
/// 与 ios-cocos WebRuntime 的 `renderPixelRatio(quality, devicePixelRatio,
/// multiOpen)` 同源：档位最终被换算成游戏画布的 backing store 像素比——
/// 低 = 1x，中 = min(1.5, 屏幕缩放)，高 = min(2, 屏幕缩放)（多开口径）。
/// 档位越低，画布 backing store 越小，多开时的 GPU / IOSurface 占用越低。
///
/// 该值在**实例启动时**注入 `__IOS2_GAME_INSTANCE__` 读取一次，因此对已经在
/// 跑的游戏窗口不生效，需要重新启动实例。
enum MacRenderQuality: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    /// 默认档位，与 iOS 侧 `renderQualitySingle` 的默认口径一致。
    static let fallback: MacRenderQuality = .high

    /// UserDefaults 持久化键：设置面板写入，WebKit 启动注入时读取。
    static let defaultsKey = "ios2.renderQuality"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }

    /// 面向用户的档位说明：说清"省什么、糊多少"。
    var summary: String {
        switch self {
        case .low: return "1x 渲染分辨率，显存占用最低，画面偏糊"
        case .medium: return "1.5x 渲染分辨率，清晰度与占用均衡"
        case .high: return "最高渲染分辨率（≤2x），画面最清晰"
        }
    }

    /// 多开口径下的渲染像素比标签，与 WebRuntime 的 renderPixelRatio 口径一致
    /// （低 = 1x，中 = 1.5x，高 = min(2, 屏幕缩放)）。
    var pixelRatioLabel: String {
        switch self {
        case .low: return "1x"
        case .medium: return "1.5x"
        case .high: return "≤2x"
        }
    }

    /// 读取当前持久化档位，缺失或非法值回退到默认档位。
    static func current() -> MacRenderQuality {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let quality = MacRenderQuality(rawValue: raw) else { return fallback }
        return quality
    }
}
