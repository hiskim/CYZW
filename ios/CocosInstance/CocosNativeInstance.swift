import Foundation
import UIKit

@MainActor
final class CocosNativeInstance: EngineHost {
    let id: UUID
    private(set) var state: EngineState = .idle
    let events: AsyncStream<EngineEvent>

    private static weak var activeInstance: CocosNativeInstance?

    private let bridge: CocosBridge
    private let eventContinuation: AsyncStream<EngineEvent>.Continuation
    private var snapshotImages: [UUID: UIImage] = [:]
    private var hasClosed = false

    init(id: UUID = UUID(), runtime: any CocosRuntimeAdapting) throws {
        guard Self.activeInstance == nil else {
            throw EngineHostError.notMultiInstanceSupported
        }

        self.id = id
        bridge = CocosBridge(runtime: runtime)
        var continuation: AsyncStream<EngineEvent>.Continuation?
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation!
        Self.activeInstance = self
        bridge.setEventHandler { [weak self] name, payload in
            self?.receiveCocosEvent(name: name, payload: payload)
        }
    }

    /// The Cocos-owned render surface. The current runtime provides CCEAGLView;
    /// a Metal CCView can be supplied by the same bridge protocol later.
    var ccView: UIView { bridge.ccView }

    func start(config: EngineConfig) async throws {
        guard !hasClosed else { throw EngineHostError.hostClosed }
        guard case .idle = state else {
            throw emitFailure(.invalidState(expected: "idle", actual: state))
        }
        guard case let .scene(sceneName) = config.initialTarget,
              !sceneName.isEmpty else {
            throw emitFailure(.invalidConfiguration("CocosNativeInstance requires EngineInitialTarget.scene."))
        }

        state = .starting
        do {
            try bridge.loadSceneBundle(identifier: config.bundleIdentifier)
            try bridge.startDirector(sceneName: sceneName, authenticationToken: config.authenticationToken)
            state = .running
            for resource in config.resources {
                try await inject(resource: resource)
            }
            eventContinuation.yield(.ready)
        } catch let error as EngineHostError {
            throw emitFailure(error)
        } catch {
            throw emitFailure(.operationFailed(error.localizedDescription))
        }
    }

    func pause() async {
        guard state == .running else { return }
        bridge.pauseDirector()
        state = .paused
        eventContinuation.yield(.paused)
    }

    func resume() async {
        guard state == .paused else { return }
        bridge.resumeDirector()
        state = .running
        eventContinuation.yield(.resumed)
    }

    func snapshot() async throws -> Snapshot {
        let previousState = state
        guard previousState == .running || previousState == .paused else {
            throw emitFailure(.snapshotUnavailable)
        }

        state = .snapshotting
        do {
            let image = try await bridge.captureFrame()
            let imageID = UUID()
            snapshotImages[imageID] = image
            let snapshot = Snapshot(
                engineID: id,
                capturedAt: Date(),
                renderState: previousState == .paused ? .paused : .running,
                camera: .init(x: 0, y: 0, z: 0, zoom: 1),
                scrollPosition: .init(horizontal: 0, vertical: 0),
                metadata: [
                    "source": "cocos",
                    "imageID": imageID.uuidString,
                    "imageFormat": "UIImage",
                    "imageWidth": String(Int(image.size.width * image.scale)),
                    "imageHeight": String(Int(image.size.height * image.scale))
                ]
            )
            state = previousState
            eventContinuation.yield(.snapshotTaken(snapshot))
            return snapshot
        } catch let error as EngineHostError {
            state = previousState
            throw emitFailure(error)
        } catch {
            state = previousState
            throw emitFailure(.operationFailed(error.localizedDescription))
        }
    }

    func image(for snapshot: Snapshot) -> UIImage? {
        guard let text = snapshot.metadata["imageID"], let imageID = UUID(uuidString: text) else {
            return nil
        }
        return snapshotImages[imageID]
    }

    func inject(resource: ResourceRef) async throws {
        guard !hasClosed else { throw EngineHostError.hostClosed }
        guard state == .running || state == .paused else {
            throw emitFailure(.invalidState(expected: "running or paused", actual: state))
        }
        do {
            try bridge.inject(resource: resource)
            eventContinuation.yield(.resourceInjected(resource))
        } catch let error as EngineHostError {
            throw emitFailure(error)
        } catch {
            throw emitFailure(.operationFailed(error.localizedDescription))
        }
    }

    func close() async {
        guard !hasClosed else { return }
        hasClosed = true
        state = .closing
        bridge.endDirector()
        snapshotImages.removeAll()
        if Self.activeInstance === self {
            Self.activeInstance = nil
        }
        eventContinuation.yield(.closed)
        eventContinuation.finish()
    }

    private func receiveCocosEvent(name: String, payload: [String: String]) {
        switch name {
        case "ready":
            eventContinuation.yield(.ready)
        case "paused":
            state = .paused
            eventContinuation.yield(.paused)
        case "resumed":
            state = .running
            eventContinuation.yield(.resumed)
        case "error":
            _ = emitFailure(.operationFailed(payload["message"] ?? "Cocos reported an unknown error."))
        default:
            eventContinuation.yield(.bridgeMessage(name: name, payload: payload))
        }
    }

    private func emitFailure(_ error: EngineHostError) -> EngineHostError {
        state = .failed(error)
        eventContinuation.yield(.errorOccurred(error))
        return error
    }
}
