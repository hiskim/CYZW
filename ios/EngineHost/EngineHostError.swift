import Foundation

enum EngineHostError: Error, Equatable, Sendable, LocalizedError {
    case invalidConfiguration(String)
    case invalidState(expected: String, actual: EngineState)
    case resourceUnavailable(ResourceRef)
    case snapshotUnavailable
    case notMultiInstanceSupported
    case hostClosed
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .invalidState(let expected, let actual):
            return "Expected \(expected), received \(actual)."
        case .resourceUnavailable:
            return "The requested resource is unavailable."
        case .snapshotUnavailable:
            return "A snapshot cannot be taken in the current state."
        case .notMultiInstanceSupported:
            return "This engine supports only one active instance."
        case .hostClosed:
            return "The engine host has already been closed."
        case .operationFailed(let message):
            return message
        }
    }
}
