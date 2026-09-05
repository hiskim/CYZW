import Foundation

@MainActor
protocol EngineHost: AnyObject {
    var id: UUID { get }
    var state: EngineState { get }
    var events: AsyncStream<EngineEvent> { get }

    func start(config: EngineConfig) async throws
    func pause() async
    func resume() async
    func snapshot() async throws -> Snapshot
    func inject(resource: ResourceRef) async throws
    func close() async
}

extension EngineHost {
    var isActive: Bool {
        switch state {
        case .starting, .running, .paused, .snapshotting:
            return true
        case .idle, .closing, .failed:
            return false
        }
    }
}
