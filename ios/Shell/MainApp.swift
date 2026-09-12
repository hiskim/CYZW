import SwiftUI

@main
struct MainApp: App {
    var body: some Scene {
        WindowGroup(id: "MainLobby") {
            ShellWindowRootView()
                // 窗口下限由 .windowResizability(.contentMinSize) 绑定到内容固有
                // 最小尺寸，所以直接在这里给 frame 下限即可收住拖拽。
                // 宽度下限 1000：低于此侧栏与矩阵区会挤在一起。
                // 高度下限 640：再矮侧栏控件组 + 矩阵卡片的头部/缩略区会被压扁。
                // iPad 仍保留 minHeight: 0，分屏 / 台前调度下高度可能不足 640，
                // 不应强行把窗口顶开（超出部分由窗口边缘自然裁剪）。
                .frame(minWidth: LobbyWindowMetrics.minWidth,
                       minHeight: LobbyWindowMetrics.minHeight)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        #if os(macOS)
        // 沉浸式无框窗口：隐藏标题栏文字，让毛玻璃材质能一直延伸到
        // 窗口最顶部的红黄绿交通灯区域（配合大厅视图里的 .ignoresSafeArea()）。
        .windowStyle(.hiddenTitleBar)
        #endif
    }
}

/// 大厅窗口下限。macOS 上 1000×640 是侧栏 + 矩阵区都还能正常显示的临界值。
private enum LobbyWindowMetrics {
    static let minWidth: CGFloat = 880
    #if os(macOS)
    static let minHeight: CGFloat = 640
    #else
    static let minHeight: CGFloat = 0
    #endif
}

/// macOS 上关掉 App Nap，避免游戏进程被系统降档。
///
/// WebKit 自己会去申请 RunningBoard 的 `WebKit Media Playback` 断言来防止
/// WebContent 被挂起，但没有对应 entitlement 时申请失败——控制台里那串
/// `Failed to acquire RBS assertion 'WebKit Media Playback'` 就是它，
/// 于是 WebContent 完全没有防挂起保护。窗口一段时间没有操作后系统会
/// 把整个 App（含 WebContent）降优先级，下一次点击要先等调度恢复，
/// 表现为「点一下顿一下，隔几秒再点又顿」，且与帧率、画质、实例数都无关。
///
/// 在 App 侧声明一个 user-initiated 活动即可抑制 App Nap，进程内的
/// WebContent 也跟着受益。iOS 没有这套机制，所以只在 macOS 分支启用。
///
/// 代价是耗电：App 会一直维持在前台优先级。若实测无效，删掉
/// `MacAppNapGuard.begin()` 这一行即可，没有别的依赖。
private enum MacAppNapGuard {
    private static var token: NSObjectProtocol?

    static func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "游戏实例运行中，避免系统降档导致操作响应变慢"
        )
    }
}

/// Keep coordinator state at the window boundary. WindowGroup can then create
/// independent shell windows on macOS (and independent scenes on iPadOS).
private struct ShellWindowRootView: View {
    @StateObject private var coordinator = AppCoordinator()

    var body: some View {
        ShellRootView(coordinator: coordinator)
            .preferredColorScheme(.dark)
            .task {
                // 日志设置在任何日志产生之前就要就位：CDN 预热是启动期的
                // 刷屏大户，晚一步就会漏掉一整段（也方便用 defaults write 临时改）。
                MacLogSettings.shared.reload()
#if os(macOS)
                MacAppNapGuard.begin()
                MacMainThreadMonitor.shared.start()
                MacLog.info("[ios2-macos] log settings at launch: enabled=%@ level=%@ jsConsole=%@",
                            MacLogSettings.shared.isEnabled ? "yes" : "no",
                            MacLogSettings.shared.currentLevel.label,
                            MacLogSettings.shared.forwardsJSConsoleEnabled ? "yes" : "no")
                _ = await MacCDNResourceManager.shared.prepareForLaunch()
#endif
            }
    }
}
