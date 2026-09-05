import Foundation
import Combine

@MainActor
final class MockEngineHost: EngineHost, ObservableObject {
    let id: UUID
    @Published private(set) var state: EngineState = .idle
    let events: AsyncStream<EngineEvent>

    var nextStartError: EngineHostError?

    private let continuation: AsyncStream<EngineEvent>.Continuation
    private var hasClosed = false

    init(id: UUID = UUID()) {
        self.id = id
        var localContinuation: AsyncStream<EngineEvent>.Continuation?
        events = AsyncStream { localContinuation = $0 }
        continuation = localContinuation!
    }

    func start(config: EngineConfig) async throws {
        guard !hasClosed else { throw EngineHostError.hostClosed }
        guard !config.bundleIdentifier.isEmpty else {
            let error = EngineHostError.invalidConfiguration("A bundle identifier is required.")
            state = .failed(error)
            continuation.yield(.errorOccurred(error))
            throw error
        }
        guard case .idle = state else {
            let error = EngineHostError.invalidState(expected: "idle", actual: state)
            continuation.yield(.errorOccurred(error))
            throw error
        }
        if let nextStartError {
            self.nextStartError = nil
            state = .failed(nextStartError)
            continuation.yield(.errorOccurred(nextStartError))
            throw nextStartError
        }

        state = .starting
        state = .running
        continuation.yield(.ready)
    }

    func pause() async {
        guard case .running = state else { return }
        state = .paused
        continuation.yield(.paused)
    }

    func resume() async {
        guard case .paused = state else { return }
        state = .running
        continuation.yield(.resumed)
    }

    func snapshot() async throws -> Snapshot {
        let previousState = state
        guard previousState == .running || previousState == .paused else {
            let error = EngineHostError.snapshotUnavailable
            continuation.yield(.errorOccurred(error))
            throw error
        }

        state = .snapshotting
        let snapshot = Snapshot(
            engineID: id,
            capturedAt: Date(),
            renderState: previousState == .paused ? .paused : .running,
            camera: .init(x: 0, y: 0, z: 0, zoom: 1),
            scrollPosition: .init(horizontal: 0, vertical: 0),
            metadata: ["source": "mock"]
        )
        state = previousState
        continuation.yield(.snapshotTaken(snapshot))
        return snapshot
    }

    func inject(resource: ResourceRef) async throws {
        guard !resource.isEmpty else {
            let error = EngineHostError.resourceUnavailable(resource)
            continuation.yield(.errorOccurred(error))
            throw error
        }
        guard !hasClosed else { throw EngineHostError.hostClosed }
        continuation.yield(.resourceInjected(resource))
    }

    func close() async {
        guard !hasClosed else { return }
        hasClosed = true
        state = .closing
        continuation.yield(.closed)
        continuation.finish()
    }
}

private extension ResourceRef {
    var isEmpty: Bool {
        switch self {
        case .local(let path): return path.isEmpty
        case .remote(let url): return url.absoluteString.isEmpty
        case .bundled(let assetName): return assetName.isEmpty
        }
    }
}
