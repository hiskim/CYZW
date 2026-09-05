import SwiftUI

@main
struct MainApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            ShellRootView(coordinator: coordinator)
                .preferredColorScheme(.dark)
        }
    }
}
