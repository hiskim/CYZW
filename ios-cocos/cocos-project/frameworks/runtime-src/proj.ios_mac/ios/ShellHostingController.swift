import SwiftUI
import UIKit

/// UIKit-owned entry point for the SwiftUI shell. The existing Objective-C
/// application delegate remains responsible for application lifecycle events.
@objc(ShellHostingController)
public final class ShellHostingController: UIViewController {
    private static let legacyCocosStateNotification = Notification.Name("com.xyzw.ios2.legacyCocosState")
    private static let legacyCocosStateKey = "state"
    private var legacyCocosStateObserver: NSObjectProtocol?
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

        // Cocos is installed below the SwiftUI shell. Once its game scene is
        // ready, the transparent hosting view must stop participating in hit
        // testing so touches reach CCEAGLView.
        legacyCocosStateObserver = NotificationCenter.default.addObserver(
            forName: Self.legacyCocosStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let state = notification.userInfo?[Self.legacyCocosStateKey] as? String else { return }
            self?.shellController.view.isUserInteractionEnabled = state != "game-ready"
        }
    }

    /// The shell stays above Cocos while native authentication is in flight.
    @objc(installCocosController:)
    public func installCocosController(_ controller: UIViewController) {
        guard controller.parent == nil else { return }

        // The login state belongs to SwiftUI until Cocos reports game-ready.
        shellController.view.isUserInteractionEnabled = true

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

    deinit {
        if let legacyCocosStateObserver {
            NotificationCenter.default.removeObserver(legacyCocosStateObserver)
        }
    }

    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }

    public override var prefersStatusBarHidden: Bool {
        false
    }
}
