import Foundation

enum EngineEvent: Equatable, Sendable {
    case ready
    case paused
    case resumed
    case snapshotTaken(Snapshot)
    case resourceInjected(ResourceRef)
    case bridgeMessage(name: String, payload: [String: String])
    case closed
    case errorOccurred(EngineHostError)
}
