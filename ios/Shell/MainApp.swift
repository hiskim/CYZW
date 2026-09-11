import SwiftUI

@main
struct MainApp: App {
    var body: some Scene {
        WindowGroup(id: "MainLobby") {
            ShellWindowRootView()
                // 宽度下限 1000。高度必须显式 minHeight: 0：
                // .windowResizability(.contentMinSize) 会把窗口最小高度绑定到
                // 内容固有最小高度（侧栏固定控件约 400pt，压不扁），
                // 不覆盖的话高度拖到那里就会卡住。
                // 高度过矮时底部内容由窗口边缘自然裁剪。
                .frame(minWidth: 1000, minHeight: 0)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
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
#if os(macOS)
                _ = await MacCDNResourceManager.shared.prepareForLaunch()
#endif
            }
    }
}
