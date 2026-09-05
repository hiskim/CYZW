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

        addChild(shellController)
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

    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }

    public override var prefersStatusBarHidden: Bool {
        false
    }
}
