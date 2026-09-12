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

/// Keep coordinator state at the window boundary. WindowGroup can then create
/// independent shell windows on macOS (and independent scenes on iPadOS).
private struct ShellWindowRootView: View {
    @StateObject private var coordinator = AppCoordinator()

    var body: some View {
        ShellRootView(coordinator: coordinator)
            .preferredColorScheme(.dark)
            .task {
#if os(macOS)
                _ = await MacCDNResourceManager.shared.prepareForLaunch()
#endif
            }
    }
}
