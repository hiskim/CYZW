import SwiftUI

@main
struct MainApp: App {
    var body: some Scene {
        WindowGroup {
            ShellWindowRootView()
        }
    }
}

/// Keep coordinator state at the window boundary. WindowGroup can then create
/// independent shell windows on macOS (and independent scenes on iPadOS).
private struct ShellWindowRootView: View {
    @StateObject private var coordinator = AppCoordinator()

    var body: some View {
        ShellRootView(coordinator: coordinator)
            .preferredColorScheme(.dark)
    }
}
