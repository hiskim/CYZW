import SwiftUI

@main
struct MainApp: App {
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            ShellRootView(coordinator: coordinator)
                .preferredColorScheme(.dark)
        }
    }
}
