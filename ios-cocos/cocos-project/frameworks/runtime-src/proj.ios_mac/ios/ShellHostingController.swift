import SwiftUI
import UIKit

/// UIKit-owned entry point for the SwiftUI shell. The existing Objective-C
/// application delegate remains responsible for application lifecycle events.
@objc(ShellHostingController)
public final class ShellHostingController: UIViewController {
    private let coordinator = AppCoordinator()
    private lazy var shellController: UIHostingController<AnyView> = UIHostingController(
        rootView: AnyView(
            ShellRootView(coordinator: coordinator)
                .preferredColorScheme(.dark)
        )
    )

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        addChild(shellController)
        shellController.view.backgroundColor = .clear
        shellController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shellController.view)
        NSLayoutConstraint.activate([
            shellController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            shellController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            shellController.view.topAnchor.constraint(equalTo: view.topAnchor),
            shellController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        shellController.didMove(toParent: self)
    }

    /// The shell stays above Cocos while native authentication is in flight.
    @objc(installCocosController:)
    public func installCocosController(_ controller: UIViewController) {
        guard controller.parent == nil else { return }

        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(controller.view, belowSubview: shellController.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controller.didMove(toParent: self)
    }

    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }

    public override var prefersStatusBarHidden: Bool {
        false
    }
}
