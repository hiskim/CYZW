import Foundation
import UIKit

/// The Objective-C++ Cocos target supplies this adapter around its CCView and Director.
/// Cocos Creator 2.4 currently exposes CCEAGLView; a future Metal CCView can conform
/// without changing the EngineHost surface.
@MainActor
protocol CocosRuntimeAdapting: AnyObject {
    var ccView: UIView { get }

    func loadSceneBundle(identifier: String) throws
    func startDirector(sceneName: String, authenticationToken: String) throws
    func pauseDirector()
    func resumeDirector()
    func captureFrame(completion: @escaping (UIImage?, Error?) -> Void)
    func evaluateJSB(_ script: String) throws
    func endDirector()
}

@MainActor
final class CocosBridge: NSObject {
    typealias EventHandler = (String, [String: String]) -> Void

    private let runtime: any CocosRuntimeAdapting
    private var eventHandler: EventHandler?

    init(runtime: any CocosRuntimeAdapting) {
        self.runtime = runtime
        super.init()
    }

    var ccView: UIView { runtime.ccView }

    func setEventHandler(_ handler: @escaping EventHandler) {
        eventHandler = handler
    }

    func loadSceneBundle(identifier: String) throws {
        try runtime.loadSceneBundle(identifier: identifier)
    }

    func startDirector(sceneName: String, authenticationToken: String) throws {
        try runtime.startDirector(sceneName: sceneName, authenticationToken: authenticationToken)
    }

    func pauseDirector() {
        runtime.pauseDirector()
    }

    func resumeDirector() {
        runtime.resumeDirector()
    }

    func captureFrame() async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            runtime.captureFrame { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? EngineHostError.snapshotUnavailable)
                }
            }
        }
    }

    func inject(resource: ResourceRef) throws {
        let payload = try resourcePayload(for: resource)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let json = String(data: data, encoding: .utf8) else {
            throw EngineHostError.resourceUnavailable(resource)
        }
        try runtime.evaluateJSB(
            "globalThis.EngineHostBridge?.injectResource(\(json));"
        )
    }

    func endDirector() {
        runtime.endDirector()
        eventHandler = nil
    }

    /// Called by the Objective-C++ JSB adapter on the main thread.
    @objc func receiveJSBEvent(_ name: String, payloadJSON: String) {
        let payload = Self.decodePayload(payloadJSON)
        eventHandler?(name, payload)
    }

    private func resourcePayload(for resource: ResourceRef) throws -> [String: String] {
        switch resource {
        case .local(let path):
            return ["kind": "local", "value": path]
        case .remote(let url):
            return ["kind": "remote", "value": url.absoluteString]
        case .bundled(let assetName):
            return ["kind": "bundled", "value": assetName]
        }
    }

    private static func decodePayload(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dictionary.reduce(into: [String: String]()) { result, item in
            result[item.key] = String(describing: item.value)
        }
    }
}
