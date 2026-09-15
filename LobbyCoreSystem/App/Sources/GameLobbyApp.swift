import AppKit
import LobbyDomain
import LobbyEngine
import LobbyStorage
import LobbyUI
import SwiftUI

/// 装配根：把存储层 / 引擎层 / 表现层接在一起。
/// 唯一知道全部具体类型的地方；其余模块只依赖领域协议。
enum LobbyComposition {
    /// 组装会话门面（窗口级单例）。主线程执行（实例池 / 会话门面均为 MainActor 类型）。
    @MainActor
    static func makeSession() -> LobbySessionModel {
        let bins = AccountBinStore()
        let cdn = CDNAssetStore.shared
        let mirror = GameSettingsMirror()
        let groups = AccountGroupStore()
        let sync = InputSyncController()
        let scripts = ScriptStore()
        let authenticator = AccountAuthenticator(bins: bins)
        let pool = GameInstancePool { account, environment in
            GameViewportInstance(account: account,
                                 environment: environment,
                                 authenticator: authenticator,
                                 resources: cdn,
                                 settingsMirror: mirror,
                                 sync: sync,
                                 scripts: scripts)
        }
        return LobbySessionModel(bins: bins, pool: pool, sync: sync,
                                 groupStore: groups, scripts: scripts)
    }

    /// 启动预热：CDN 清单 + 核心 bundle。失败不致命（游戏窗口可惰性重试）。
    static func warmUp() async {
        _ = await CDNAssetStore.shared.prepareForLaunch()
    }
}

@main
struct GameLobbyApp: App {
    @StateObject private var session: LobbySessionModel

    init() {
        // @main App 的 init 保证在主线程执行；编译器无法证明，用 assumeIsolated
        // 显式声明，让 MainActor 隔离的装配代码（实例池 / 会话门面）合法构造。
        _session = StateObject(wrappedValue: MainActor.assumeIsolated {
            LobbyComposition.makeSession()
        })
    }

    var body: some Scene {
        WindowGroup(id: "MainLobby") {
            LobbyRootView(session: session)
                // 宽度下限 880：低于此侧栏与矩阵区会挤在一起；
                // 高度下限 640：再矮侧栏控件组 + 矩阵卡片会被压扁。
                .frame(minWidth: 880, minHeight: 640)
                .preferredColorScheme(.dark)
                .task {
                    MacAppNapGuard.begin()
                    await LobbyComposition.warmUp()
                }
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        // 沉浸式无框窗口：隐藏标题栏文字，让毛玻璃材质延伸到交通灯区域
        // （配合 LobbyRootView 里的 .ignoresSafeArea()）。
        .windowStyle(.hiddenTitleBar)
    }
}

/// 关掉 App Nap，避免游戏进程被系统降档。
///
/// WebKit 自己会申请 RunningBoard 的 `WebKit Media Playback` 断言防挂起，
/// 但没有对应 entitlement 时申请失败（控制台里的
/// `Failed to acquire RBS assertion 'WebKit Media Playback'`），
/// WebContent 完全没有防挂起保护。窗口一段时间没有操作后系统把整个 App
/// 降优先级，下一次点击要先等调度恢复——表现为「点一下顿一下」。
///
/// 在 App 侧声明一个 user-initiated 活动即可抑制 App Nap。代价是耗电；
/// 若要关闭，删掉 `MacAppNapGuard.begin()` 这一行即可，没有别的依赖。
enum MacAppNapGuard {
    private static var token: NSObjectProtocol?

    static func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "游戏实例运行中，避免系统降档导致操作响应变慢"
        )
    }
}
