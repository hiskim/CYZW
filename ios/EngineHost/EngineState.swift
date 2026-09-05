import Foundation

indirect enum EngineState: Equatable, Sendable {
    case idle
    case starting
    case running
    case paused
    case snapshotting
    case closing
    case failed(EngineHostError)
}
