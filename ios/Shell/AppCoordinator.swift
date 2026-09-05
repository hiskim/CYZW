import Observation
import SwiftUI

@MainActor
@Observable
final class AppCoordinator {
    enum RootTab: Hashable {
        case accounts
        case workspace
        case plugins
        case settings
    }

    var selectedTab: RootTab = .accounts
    var navigationPath = NavigationPath()
    let workspace = WorkspaceViewModel()

    func showWorkspace() {
        selectedTab = .workspace
    }
}

struct ShellRootView: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        let tokens = DesignTokens.shared
        NavigationStack(path: $coordinator.navigationPath) {
            TabView(selection: $coordinator.selectedTab) {
                AccountLibraryView { accounts in
                    Task {
                        await coordinator.workspace.start(accounts: accounts)
                        coordinator.showWorkspace()
                    }
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
    }
}
