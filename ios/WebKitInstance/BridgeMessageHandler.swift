import Foundation
import WebKit

@MainActor
protocol BridgeMessageHandling: AnyObject {
    func bridgeDidReceive(event: String, payload: [String: Any])
}

final class BridgeMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: (any BridgeMessageHandling)?

    init(delegate: (any BridgeMessageHandling)? = nil) {
        self.delegate = delegate
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "engineHost",
              let bridgeMessage = Self.decode(message.body) else { return }

        Task { @MainActor [weak self] in
            self?.delegate?.bridgeDidReceive(
                event: bridgeMessage.event,
                payload: bridgeMessage.payload
            )
        }
    }

    private static func decode(_ body: Any) -> (event: String, payload: [String: Any])? {
        if let value = body as? [String: Any], let event = value["event"] as? String {
            return (event, value["payload"] as? [String: Any] ?? [:])
        }

        guard let text = body as? String,
              let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = value["event"] as? String else {
            return nil
        }
        return (event, value["payload"] as? [String: Any] ?? [:])
    }
}
