import Combine
import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject {
    enum RootTab: Hashable {
        case accounts
        case workspace
        case plugins
        case settings
    }

    @Published var selectedTab: RootTab = .accounts
    let workspace = WorkspaceViewModel()
    @Published var legacyCocosPresentation: LegacyCocosPresentation = .shell
    private var legacyCocosStateObserver: NSObjectProtocol?

    init() {
        legacyCocosStateObserver = NotificationCenter.default.addObserver(
            forName: LegacyCocosLaunch.stateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let state = notification.userInfo?[LegacyCocosLaunch.stateKey] as? String
            let message = notification.userInfo?[LegacyCocosLaunch.messageKey] as? String
            Task { @MainActor [weak self, state, message] in
                self?.handleLegacyCocosState(state: state, message: message)
            }
        }
    }

    private func handleLegacyCocosState(state: String?, message: String?) {
        switch state {
        case "game-ready":
            legacyCocosPresentation = .game
        case "failed":
            guard case let .loggingIn(account) = legacyCocosPresentation else { return }
            legacyCocosPresentation = .failed(account, message ?? "登录失败，请重新打开应用后重试。")
        default:
            break
        }
    }

    func showWorkspace() {
        selectedTab = .workspace
    }

    func launchLegacyCocos(account: Account) {
        legacyCocosPresentation = .loggingIn(account)
        LegacyCocosLaunch.request(binFileName: account.fileName)
    }
}

struct ShellRootView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        let tokens = DesignTokens.shared
        ZStack {
            if coordinator.legacyCocosPresentation != .game {
                shellTabs(tokens: tokens)
            } else {
                Color.clear
            }

            switch coordinator.legacyCocosPresentation {
            case let .loggingIn(account):
                LegacyCocosLoginView(account: account, message: "正在验证账号并准备游戏场景…", isFailure: false)
            case let .failed(account, message):
                LegacyCocosLoginView(account: account, message: message, isFailure: true)
            case .shell, .game:
                EmptyView()
            }
        }
        .background(Color.clear)
    }

    @ViewBuilder
    private func shellTabs(tokens: DesignTokens) -> some View {
        NavigationView {
            TabView(selection: $coordinator.selectedTab) {
                AccountLibraryView { account in
                    coordinator.launchLegacyCocos(account: account)
                }
                .tabItem {
                    Label("账号库", systemImage: "person.2")
                        .font(tokens.font(.sm, weight: .medium))
                }
                .tag(AppCoordinator.RootTab.accounts)

                WorkspaceView(viewModel: coordinator.workspace)
                    .tabItem {
                        Label("多开", systemImage: "square.grid.2x2")
                            .font(tokens.font(.sm, weight: .medium))
                    }
                    .tag(AppCoordinator.RootTab.workspace)

                PluginPanelView(workspace: coordinator.workspace)
                    .tabItem {
                        Label("插件", systemImage: "puzzlepiece")
                            .font(tokens.font(.sm, weight: .medium))
                    }
                    .tag(AppCoordinator.RootTab.plugins)

                SettingsView()
                    .tabItem {
                        Label("设置", systemImage: "gearshape")
                            .font(tokens.font(.sm, weight: .medium))
                    }
                    .tag(AppCoordinator.RootTab.settings)
            }
            .tint(tokens.color(.accent))
            .background(tokens.color(.canvas))
        }
        .navigationViewStyle(.stack)
    }
}

private struct LegacyCocosLoginView: View {
    let account: Account
    let message: String
    let isFailure: Bool

    var body: some View {
        let tokens = DesignTokens.shared

        VStack(spacing: tokens.spacing(.lg)) {
            if !isFailure {
                ProgressView()
                    .tint(tokens.color(.accent))
                    .controlSize(.large)
            }
            Text(isFailure ? "登录未完成" : "正在登录")
                .font(tokens.font(.xxl, weight: .semibold))
                .foregroundStyle(tokens.color(.textPrimary))
            Text(account.nickname)
                .font(tokens.font(.xl, weight: .medium))
                .foregroundStyle(tokens.color(.textSecondary))
            Text(message)
                .font(tokens.font(.md))
                .foregroundStyle(isFailure ? tokens.color(.danger) : tokens.color(.textSecondary))
                .multilineTextAlignment(.center)
        }
        .padding(tokens.spacing(.xl))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.color(.canvas))
    }
}
